// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title BusinessWallet
 * @notice Smart wallet for a single business on the Tokenx platform.
 *
 *   ETH
 *   ───
 *   Incoming ETH is auto-forwarded to `poolWallet` in receive().
 *   The only on-chain work is one external call — gas cost is minimal.
 *   If the pool reverts or the wallet is paused, ETH is held and
 *   ETHReceived is emitted; call sweepETH() to retry.
 *
 *   ERC-20
 *   ──────
 *   EVM has no receive hook for ERC-20, so sweeps are triggered
 *   externally:
 *
 *     • notify(token)  — permissionless; no role or key required.
 *       Your off-chain indexer watches Transfer events and calls this
 *       for each token that arrives.  One line in your indexer,
 *       no signing needed.
 *
 *     • sweepToken / batchSweepTokens — SWEEPER_ROLE gated fallback
 *       for manual or batched operations.
 *
 *   Smart-wallet
 *   ────────────
 *   execute() lets EXECUTOR_ROLE make arbitrary calls from this wallet
 *   address (protocol interactions, approvals, governance, etc.).
 *
 *   Upgradeability
 *   ──────────────
 *   Deployed as a BeaconProxy by WalletFactory.  Upgrading the beacon
 *   upgrades every business wallet instantly.  New storage variables
 *   must be added before __gap; shrink __gap by the same slot count.
 *
 *   EIP-2771
 *   ────────
 *   Role-gated functions resolve the caller via _msgSender(), so an
 *   agent with no ETH can sign a ForwardRequest and have a relayer
 *   submit it via TokenxForwarder.
 */
contract BusinessWallet is Initializable, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────────────────

    bytes32 public constant WALLET_ADMIN_ROLE = keccak256("WALLET_ADMIN_ROLE");
    bytes32 public constant SWEEPER_ROLE      = keccak256("SWEEPER_ROLE");
    bytes32 public constant EXECUTOR_ROLE     = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");

    // ── State ─────────────────────────────────────────────────────────────────────

    /// @dev EIP-2771 trusted forwarder — resolves msg.sender for meta-txs.
    address public trustedForwarder;

    /// @dev Unique identifier for this business (set once at init).
    bytes32 public businessId;

    /// @dev Destination for all forwarded / swept funds.
    address public poolWallet;

    /// @dev Proxy-safe reentrancy guard: 0 = unlocked (proxy default), 2 = locked.
    uint256 private _reentrancyStatus;
    uint256 private constant _ENTERED = 2;

    // ── Upgrade safety ────────────────────────────────────────────────────────────
    // solhint-disable-next-line var-name-mixedcase
    uint256[45] private __gap;

    // ── Events ────────────────────────────────────────────────────────────────────

    /// @notice ETH was forwarded to the pool wallet.
    event ETHForwarded(address indexed sender, uint256 amount, address indexed pool);

    /// @notice ETH arrived but was not forwarded (paused, or pool reverted).
    ///         Funds are held — call sweepETH() to retry.
    event ETHReceived(address indexed sender, uint256 amount);

    /// @notice An ERC-20 balance was swept to the pool wallet.
    event TokenSwept(address indexed token, uint256 amount, address indexed pool);

    /// @notice Pool wallet destination was updated.
    event PoolWalletUpdated(address indexed oldPool, address indexed newPool);

    /// @notice An arbitrary call was executed from this wallet.
    event Executed(address indexed target, uint256 value, bytes data, bytes result);

    // ── Modifiers ─────────────────────────────────────────────────────────────────

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "BW: reentrant");
        _reentrancyStatus = _ENTERED;
        _;
        delete _reentrancyStatus;
    }

    // ── Init ──────────────────────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /**
     * @param _businessId      Unique identifier for this business.
     * @param _admin           Address granted all roles.
     * @param _poolWallet      Destination for all forwarded / swept funds.
     * @param _forwarder       EIP-2771 forwarder. Pass address(0) to disable.
     * @param _factorySweeper  Additional SWEEPER_ROLE address — pass the factory
     *                         address so it can trigger sweeps on behalf of operators.
     */
    function initialize(
        bytes32 _businessId,
        address _admin,
        address _poolWallet,
        address _forwarder,
        address _factorySweeper
    ) external initializer {
        require(_businessId != bytes32(0), "BW: empty businessId");
        require(_admin       != address(0), "BW: zero admin");
        require(_poolWallet  != address(0), "BW: zero pool");

        businessId       = _businessId;
        poolWallet       = _poolWallet;
        trustedForwarder = _forwarder;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(WALLET_ADMIN_ROLE,  _admin);
        _grantRole(SWEEPER_ROLE,       _admin);
        _grantRole(EXECUTOR_ROLE,      _admin);
        _grantRole(PAUSER_ROLE,        _admin);

        if (_factorySweeper != address(0)) {
            _grantRole(SWEEPER_ROLE, _factorySweeper);
        }
    }

    // ── Receive / Fallback ────────────────────────────────────────────────────────

    /// @dev Forward ETH to pool on receipt. Single external call — minimal gas.
    receive() external payable {
        _handleIncomingETH(msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) _handleIncomingETH(msg.value);
    }

    // ── ETH Sweep ─────────────────────────────────────────────────────────────────

    /// @notice Sweep residual ETH to the pool. Use when auto-forward previously failed.
    function sweepETH()
        external
        onlyRole(SWEEPER_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint256 bal = address(this).balance;
        require(bal > 0, "BW: no ETH balance");
        _forwardETH(bal);
    }

    // ── ERC-20 sweep ──────────────────────────────────────────────────────────────

    /**
     * @notice Permissionless sweep trigger for a single token.
     *         No role required — your off-chain indexer calls this when it
     *         detects a Transfer event to this wallet address.
     *         Does nothing if the balance is zero or the wallet is paused.
     * @param token  ERC-20 contract address.
     */
    function notify(address token) external nonReentrant {
        if (paused()) return;
        _sweepERC20(token);
    }

    /**
     * @notice Transfer the wallet's full balance of `token` to poolWallet.
     *         Role-gated manual / batched sweep.
     * @param token  ERC-20 contract address.
     */
    function sweepToken(address token)
        external
        onlyRole(SWEEPER_ROLE)
        nonReentrant
        whenNotPaused
    {
        _sweepERC20(token);
    }

    /**
     * @notice Sweep multiple token balances to poolWallet in one call.
     * @param tokens  ERC-20 contract addresses.
     */
    function batchSweepTokens(address[] calldata tokens)
        external
        onlyRole(SWEEPER_ROLE)
        nonReentrant
        whenNotPaused
    {
        for (uint256 i; i < tokens.length; ++i) {
            _sweepERC20(tokens[i]);
        }
    }

    // ── Smart-wallet execute ──────────────────────────────────────────────────────

    /**
     * @notice Execute an arbitrary call from this wallet address.
     * @param target  Contract to call. Cannot be address(this).
     * @param value   ETH to include (must be held by this wallet).
     * @param data    Calldata.
     * @return result Return bytes from the inner call.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        payable
        onlyRole(EXECUTOR_ROLE)
        nonReentrant
        whenNotPaused
        returns (bytes memory result)
    {
        require(target != address(0),    "BW: zero target");
        require(target != address(this), "BW: no self-call");

        bool ok;
        (ok, result) = target.call{value: value}(data);
        require(ok, "BW: execution failed");

        emit Executed(target, value, data, result);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────────

    /// @notice Redirect future forwards and sweeps to a new pool wallet.
    function setPoolWallet(address newPool)
        external
        onlyRole(WALLET_ADMIN_ROLE)
    {
        require(newPool != address(0), "BW: zero pool");
        address old = poolWallet;
        poolWallet   = newPool;
        emit PoolWalletUpdated(old, newPool);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ── EIP-2771 ──────────────────────────────────────────────────────────────────

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarder;
    }

    // ── Internal ──────────────────────────────────────────────────────────────────

    function _handleIncomingETH(uint256 amount) internal {
        address pool = poolWallet;
        if (paused() || pool == address(0)) {
            emit ETHReceived(msg.sender, amount);
            return;
        }
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = pool.call{value: amount}("");
        if (ok) {
            emit ETHForwarded(msg.sender, amount, pool);
        } else {
            emit ETHReceived(msg.sender, amount);
        }
    }

    function _forwardETH(uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = poolWallet.call{value: amount}("");
        require(ok, "BW: ETH transfer failed");
        emit ETHForwarded(msg.sender, amount, poolWallet);
    }

    function _sweepERC20(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(token).safeTransfer(poolWallet, bal);
        emit TokenSwept(token, bal, poolWallet);
    }

    // ── EIP-2771 context ──────────────────────────────────────────────────────────

    function _msgSender() internal view override returns (address sender) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = super._msgSender();
        }
    }

    function _msgData() internal view override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        }
        return super._msgData();
    }
}
