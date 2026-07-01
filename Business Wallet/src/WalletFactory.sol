// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "./BusinessWallet.sol";

/**
 * @title WalletFactory
 * @notice Platform-level factory that creates a BusinessWallet for every
 *         business registered on the Tokenx infrastructure.
 *
 *   Deployment model
 *   ────────────────
 *   Each business wallet is deployed as a BeaconProxy pointing to a single
 *   UpgradeableBeacon owned by the platform admin.  Calling
 *   beacon.upgradeTo(newImpl) upgrades every wallet instantly — no
 *   per-wallet action needed.
 *
 *   The factory creates the beacon in its constructor and transfers
 *   ownership to the admin.  Use `walletBeacon` to upgrade:
 *
 *     UpgradeableBeacon(factory.walletBeacon()).upgradeTo(newImpl);
 *
 *   Fund flow
 *   ─────────
 *   Every wallet is initialised with the factory's `poolWallet`.  Incoming
 *   ETH is auto-forwarded on receipt; ERC-20 tokens require a sweep call.
 *   The factory is granted SWEEPER_ROLE on every wallet it creates, so
 *   operators can call `sweepWallet()` without needing a separate key.
 *
 *   Deterministic wallets
 *   ─────────────────────
 *   `createWalletDeterministic(businessId, admin, salt)` deploys via
 *   CREATE2, giving a predictable address before deployment.  Use
 *   `predictWalletAddress()` to compute the address off-chain and share it
 *   with the business before the wallet is actually deployed.
 *
 *   Roles
 *   ─────
 *   DEFAULT_ADMIN_ROLE  — grant / revoke all other roles
 *   DEPLOYER_ROLE       — create new wallets
 *   POOL_MANAGER_ROLE   — update the pool wallet address
 *   PAUSER_ROLE         — pause / unpause the factory
 */
contract WalletFactory is AccessControl, Pausable {

    bytes32 public constant DEPLOYER_ROLE      = keccak256("DEPLOYER_ROLE");
    bytes32 public constant POOL_MANAGER_ROLE  = keccak256("POOL_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");

    // ── State ─────────────────────────────────────────────────────────────────────

    /// @notice BeaconProxy beacon shared by every BusinessWallet.
    address public immutable walletBeacon;

    /// @notice Default pool wallet propagated to every new wallet at creation.
    address public poolWallet;

    /// @notice EIP-2771 forwarder propagated to every new wallet at creation.
    address public immutable trustedForwarder;

    // ── Wallet registry ───────────────────────────────────────────────────────────

    struct WalletRecord {
        address wallet;
        address admin;
        address deployedBy;
        uint256 deployedAt;
        bytes32 businessId;
        bool    active;
    }

    mapping(bytes32 => WalletRecord) private _wallets;
    bytes32[]                        private _walletIds;

    // ── Events ────────────────────────────────────────────────────────────────────

    event WalletDeployed(
        bytes32 indexed businessId,
        address indexed wallet,
        address indexed admin,
        address         deployedBy
    );

    event WalletDeactivated(bytes32 indexed businessId, address indexed wallet);

    event PoolWalletUpdated(address indexed oldPool, address indexed newPool);

    // ── Constructor ───────────────────────────────────────────────────────────────

    /**
     * @param admin_            Address granted all platform roles.
     * @param walletImpl_       BusinessWallet implementation contract address.
     * @param poolWallet_       Destination for all forwarded funds from wallets.
     * @param trustedForwarder_ EIP-2771 forwarder shared across all wallets.
     *                          Pass address(0) if meta-transactions are not used.
     */
    constructor(
        address admin_,
        address walletImpl_,
        address poolWallet_,
        address trustedForwarder_
    ) {
        require(admin_       != address(0), "WF: zero admin");
        require(walletImpl_  != address(0), "WF: zero impl");
        require(poolWallet_  != address(0), "WF: zero pool");

        // Deploy beacon and transfer ownership to admin.
        UpgradeableBeacon beacon = new UpgradeableBeacon(walletImpl_);
        beacon.transferOwnership(admin_);
        walletBeacon     = address(beacon);

        poolWallet       = poolWallet_;
        trustedForwarder = trustedForwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(DEPLOYER_ROLE,      admin_);
        _grantRole(POOL_MANAGER_ROLE,  admin_);
        _grantRole(PAUSER_ROLE,        admin_);
    }

    // ── Wallet creation ───────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new BusinessWallet for a business.
     * @param businessId  Unique identifier for this business. Cannot be reused.
     * @param admin       Wallet granted all roles on the new BusinessWallet.
     * @return wallet     Address of the deployed BusinessWallet proxy.
     */
    function createWallet(bytes32 businessId, address admin)
        external
        onlyRole(DEPLOYER_ROLE)
        whenNotPaused
        returns (address wallet)
    {
        _validateArgs(businessId, admin);
        wallet = _deploy(businessId, admin, bytes32(0), false);
    }

    /**
     * @notice Deploy a BusinessWallet at a deterministic CREATE2 address.
     *         The address can be predicted off-chain via predictWalletAddress()
     *         before the wallet is deployed — useful for sharing a receiving
     *         address with a business ahead of on-chain setup.
     * @param businessId  Unique identifier for this business.
     * @param admin       Wallet granted all roles on the new BusinessWallet.
     * @param salt        Arbitrary salt for CREATE2. Include businessId in the
     *                    salt to prevent cross-factory collisions, e.g.:
     *                    keccak256(abi.encode(businessId, nonce)).
     * @return wallet     Address of the deployed BusinessWallet proxy.
     */
    function createWalletDeterministic(
        bytes32 businessId,
        address admin,
        bytes32 salt
    )
        external
        onlyRole(DEPLOYER_ROLE)
        whenNotPaused
        returns (address wallet)
    {
        _validateArgs(businessId, admin);
        wallet = _deploy(businessId, admin, salt, true);
    }

    /**
     * @notice Predict the CREATE2 address a wallet would be deployed to.
     *         Useful for sharing a receiving address before deployment.
     * @param businessId  The business identifier that will be used.
     * @param admin       The admin address that will be used.
     * @param salt        The same salt that will be passed to createWalletDeterministic.
     * @return predicted  The address the wallet would be deployed at.
     */
    function predictWalletAddress(
        bytes32 businessId,
        address admin,
        bytes32 salt
    ) external view returns (address predicted) {
        bytes memory initData = _buildInitData(businessId, admin);
        bytes32 initHash = keccak256(abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(walletBeacon, initData)
        ));
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            initHash
        )))));
    }

    // ── Sweep ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Sweep residual ETH from a wallet to its pool.
     *         The factory holds SWEEPER_ROLE on every wallet it creates.
     * @param businessId  Identifier of the wallet to sweep.
     */
    function sweepWalletETH(bytes32 businessId)
        external
        onlyRole(DEPLOYER_ROLE)
    {
        BusinessWallet(payable(_requireWallet(businessId))).sweepETH();
    }

    /**
     * @notice Sweep ERC-20 token balances from a wallet to its pool.
     * @param businessId  Identifier of the wallet to sweep.
     * @param tokens      ERC-20 contract addresses to sweep.
     */
    function sweepWalletTokens(bytes32 businessId, address[] calldata tokens)
        external
        onlyRole(DEPLOYER_ROLE)
    {
        BusinessWallet(payable(_requireWallet(businessId))).batchSweepTokens(tokens);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Update the pool wallet used for all future wallet deployments.
     *         Does NOT retroactively update existing wallets — call
     *         BusinessWallet.setPoolWallet(newPool) on each existing wallet
     *         separately, or grant WALLET_ADMIN_ROLE and update them in batch.
     * @param newPool  New pool wallet address.
     */
    function setPoolWallet(address newPool)
        external
        onlyRole(POOL_MANAGER_ROLE)
    {
        require(newPool != address(0), "WF: zero pool");
        address old = poolWallet;
        poolWallet   = newPool;
        emit PoolWalletUpdated(old, newPool);
    }

    /**
     * @notice Deactivate a wallet record (does not destroy or pause the wallet itself).
     *         Used to mark a business as off-boarded in the factory registry.
     */
    function deactivateWallet(bytes32 businessId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        WalletRecord storage rec = _wallets[businessId];
        require(rec.wallet != address(0), "WF: unknown businessId");
        rec.active = false;
        emit WalletDeactivated(businessId, rec.wallet);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ── Read ──────────────────────────────────────────────────────────────────────

    /**
     * @notice Retrieve the full record for a deployed wallet.
     */
    function getWallet(bytes32 businessId)
        external
        view
        returns (WalletRecord memory)
    {
        require(_wallets[businessId].wallet != address(0), "WF: unknown businessId");
        return _wallets[businessId];
    }

    /**
     * @notice Total number of wallets ever deployed through this factory.
     */
    function totalWallets() external view returns (uint256) {
        return _walletIds.length;
    }

    /**
     * @notice Paginated wallet listing (0-based index).
     * @param offset  Start position.
     * @param limit   Maximum number of records to return.
     */
    function getWallets(uint256 offset, uint256 limit)
        external
        view
        returns (WalletRecord[] memory records)
    {
        uint256 total = _walletIds.length;
        if (offset >= total) return new WalletRecord[](0);

        uint256 end   = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;

        records = new WalletRecord[](count);
        for (uint256 i; i < count; ++i) {
            records[i] = _wallets[_walletIds[offset + i]];
        }
    }

    /**
     * @notice Return the wallet address for a business without the full record.
     *         Returns address(0) if the business has no wallet.
     */
    function walletOf(bytes32 businessId) external view returns (address) {
        return _wallets[businessId].wallet;
    }

    // ── Internal ──────────────────────────────────────────────────────────────────

    function _validateArgs(bytes32 businessId, address admin) internal view {
        require(businessId != bytes32(0),                      "WF: empty businessId");
        require(admin       != address(0),                     "WF: zero admin");
        require(_wallets[businessId].wallet == address(0),     "WF: businessId taken");
    }

    function _buildInitData(bytes32 businessId, address admin)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            BusinessWallet.initialize,
            (businessId, admin, poolWallet, trustedForwarder, address(this))
        );
    }

    function _deploy(
        bytes32 businessId,
        address admin,
        bytes32 salt,
        bool    deterministic
    ) internal returns (address wallet) {
        bytes memory initData = _buildInitData(businessId, admin);

        if (deterministic) {
            wallet = address(new BeaconProxy{salt: salt}(walletBeacon, initData));
        } else {
            wallet = address(new BeaconProxy(walletBeacon, initData));
        }

        _wallets[businessId] = WalletRecord({
            wallet:     wallet,
            admin:      admin,
            deployedBy: msg.sender,
            deployedAt: block.timestamp,
            businessId: businessId,
            active:     true
        });
        _walletIds.push(businessId);

        emit WalletDeployed(businessId, wallet, admin, msg.sender);
    }

    function _requireWallet(bytes32 businessId) internal view returns (address) {
        address w = _wallets[businessId].wallet;
        require(w != address(0), "WF: unknown businessId");
        return w;
    }
}
