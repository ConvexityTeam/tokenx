// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./IdentityRegistry.sol";
import "./ComplianceModule.sol";
import "./SecurityToken.sol";
import "./YieldDistributor.sol";
import "./BondTerms.sol";

/**
 * @title TokenizationFactory
 * @notice One-transaction deployer for ERC-3643 security token suites.
 *
 *   Uses EIP-1967 BeaconProxy: every deployed contract is a BeaconProxy
 *   that delegates to whichever implementation the beacon currently points
 *   to.  The beacon owner (platform admin / multisig) can call
 *   UpgradeableBeacon.upgradeTo(newImpl) to upgrade ALL tokens of a given
 *   type at once, with no per-token action needed.
 *
 *   Factory stores beacon addresses (not impl addresses).  To upgrade:
 *     1. Deploy a new implementation contract.
 *     2. Call beacon.upgradeTo(newImpl) from the beacon owner.
 *
 *   A single call to deployToken() or deployBond() deploys and wires:
 *     1. IdentityRegistry  (BeaconProxy → beaconIR)
 *     2. ComplianceModule  (BeaconProxy → beaconCM, bound to the token)
 *     3. SecurityToken     (BeaconProxy → beaconST, ERC-3643)
 *     4. YieldDistributor  (BeaconProxy → beaconYD, YIELD_BEARING / BOND only)
 *     5. BondTerms         (BeaconProxy → beaconBT, BOND only)
 */
contract TokenizationFactory is AccessControl, Pausable {

    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    // ── Beacon addresses (set once at construction) ───────────────
    // Each beacon is an UpgradeableBeacon owned by the platform admin.
    // Upgrading a beacon automatically upgrades every proxy deployed
    // through this factory.

    address public immutable beaconIR;   // IdentityRegistry beacon
    address public immutable beaconCM;   // ComplianceModule beacon
    address public immutable beaconST;   // SecurityToken beacon
    address public immutable beaconYD;   // YieldDistributor beacon
    address public immutable beaconBT;   // BondTerms beacon

    // ── EIP-2771 forwarder ────────────────────────────────────────
    // Propagated to every deployed contract during initialization.
    address public immutable trustedForwarder;

    // ── Token type ────────────────────────────────────────────────

    enum TokenType { SECURITY, YIELD_BEARING, BOND }

    // ── Compliance params ─────────────────────────────────────────

    struct ComplianceParams {
        uint256 maxShareholders;
        uint256 maxTokensPerInvestor;
        uint256 lockUpDuration;
    }

    // ── Deployment registry ───────────────────────────────────────

    struct DeploymentRecord {
        address   identityRegistry;
        address   compliance;
        address   token;
        address   yieldDistributor;
        address   bondTerms;
        address   deployedBy;
        uint256   deployedAt;
        string    issuerId;
        TokenType tokenType;
    }

    DeploymentRecord[] public deployments;
    mapping(string => uint256) public issuerDeploymentIndex; // issuerId → 1-based

    // ── Events ────────────────────────────────────────────────────

    event TokenDeployed(
        string    indexed issuerId,
        TokenType         tokenType,
        address           identityRegistry,
        address           compliance,
        address           token,
        address           yieldDistributor,
        address           bondTerms,
        address           deployedBy
    );

    // ── Constructor ───────────────────────────────────────────────

    constructor(
        address admin,
        address beaconIR_,
        address beaconCM_,
        address beaconST_,
        address beaconYD_,
        address beaconBT_,
        address trustedForwarder_
    ) {
        require(admin      != address(0), "Factory: zero admin");
        require(beaconIR_  != address(0), "Factory: zero IR beacon");
        require(beaconCM_  != address(0), "Factory: zero CM beacon");
        require(beaconST_  != address(0), "Factory: zero ST beacon");
        require(beaconYD_  != address(0), "Factory: zero YD beacon");
        require(beaconBT_  != address(0), "Factory: zero BT beacon");

        beaconIR         = beaconIR_;
        beaconCM         = beaconCM_;
        beaconST         = beaconST_;
        beaconYD         = beaconYD_;
        beaconBT         = beaconBT_;
        trustedForwarder = trustedForwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DEPLOYER_ROLE,      admin);
        _grantRole(PAUSER_ROLE,        admin);
    }

    // ── Deployment ────────────────────────────────────────────────

    /**
     * @notice Deploy a SECURITY or YIELD_BEARING token suite.
     * @return token Address of the deployed SecurityToken proxy.
     */
    function deployToken(
        TokenType     tokenType,
        string memory issuerId,
        string memory tokenName,
        string memory tokenSymbol,
        address       issuerOnchainID,
        address       tokenAdmin,
        ComplianceParams calldata compliance
    )
        external
        onlyRole(DEPLOYER_ROLE)
        whenNotPaused
        returns (address token)
    {
        require(tokenType != TokenType.BOND, "Factory: use deployBond for BOND");
        (token, ) = _deployCore(
            tokenType, issuerId, tokenName, tokenSymbol,
            issuerOnchainID, tokenAdmin, compliance, address(0)
        );
    }

    /**
     * @notice Deploy a tokenized bond suite with sealed BondTerms.
     * @return token         Address of the deployed SecurityToken proxy.
     * @return bondTermsAddr Address of the deployed BondTerms proxy.
     */
    function deployBond(
        string memory issuerId,
        string memory tokenName,
        string memory tokenSymbol,
        address       issuerOnchainID,
        address       tokenAdmin,
        ComplianceParams calldata compliance,
        BondTerms.InitParams calldata bondParams
    )
        external
        onlyRole(DEPLOYER_ROLE)
        whenNotPaused
        returns (address token, address bondTermsAddr)
    {
        // 1. Deploy and seal BondTerms first so the token can be wired to it.
        BondTerms.InitParams memory params = bondParams;
        params.admin = tokenAdmin;
        bondTermsAddr = address(new BeaconProxy(
            beaconBT,
            abi.encodeCall(BondTerms.initialize, (params, trustedForwarder))
        ));

        // 2. Deploy the rest of the suite.
        (token, ) = _deployCore(
            TokenType.BOND, issuerId, tokenName, tokenSymbol,
            issuerOnchainID, tokenAdmin, compliance, bondTermsAddr
        );
    }

    // ── Internal core ─────────────────────────────────────────────

    function _deployCore(
        TokenType     tokenType,
        string memory issuerId,
        string memory tokenName,
        string memory tokenSymbol,
        address       issuerOnchainID,
        address       tokenAdmin,
        ComplianceParams calldata compliance,
        address       bondTermsAddr
    ) internal returns (address token, address yieldDist) {
        require(bytes(issuerId).length > 0,           "Factory: empty issuerId");
        require(tokenAdmin != address(0),             "Factory: zero tokenAdmin");
        require(issuerDeploymentIndex[issuerId] == 0, "Factory: issuerId taken");

        // 1. IdentityRegistry — tokenAdmin is admin from the start
        address ir = address(new BeaconProxy(
            beaconIR,
            abi.encodeCall(IdentityRegistry.initialize, (tokenAdmin, trustedForwarder))
        ));

        // 2. ComplianceModule — factory is temporary admin so it can call bindToken
        address comp = address(new BeaconProxy(
            beaconCM,
            abi.encodeCall(ComplianceModule.initialize, (
                address(this),
                compliance.maxShareholders,
                compliance.maxTokensPerInvestor,
                compliance.lockUpDuration,
                trustedForwarder
            ))
        ));

        // 3. SecurityToken — factory is temporary admin so it can call setBondTerms
        token = address(new BeaconProxy(
            beaconST,
            abi.encodeCall(SecurityToken.initialize, (
                tokenName, tokenSymbol, issuerOnchainID,
                ir, comp, address(this), trustedForwarder
            ))
        ));

        // 4. Bind compliance to token
        ComplianceModule(comp).bindToken(token);
        ComplianceModule(comp).grantRole(ComplianceModule(comp).DEFAULT_ADMIN_ROLE(), tokenAdmin);
        ComplianceModule(comp).grantRole(keccak256("COMPLIANCE_ADMIN"), tokenAdmin);
        ComplianceModule(comp).renounceRole(ComplianceModule(comp).DEFAULT_ADMIN_ROLE(), address(this));

        // 5. YieldDistributor (YIELD_BEARING and BOND)
        yieldDist = address(0);
        if (tokenType == TokenType.YIELD_BEARING || tokenType == TokenType.BOND) {
            yieldDist = address(new BeaconProxy(
                beaconYD,
                abi.encodeCall(YieldDistributor.initialize, (token, address(this), trustedForwarder))
            ));
        }

        // 6. Wire BondTerms into its consumers (BOND only)
        if (bondTermsAddr != address(0)) {
            SecurityToken(payable(token)).setBondTerms(bondTermsAddr);
            YieldDistributor(payable(yieldDist)).setBondTerms(bondTermsAddr);
            BondTerms(bondTermsAddr).bindConsumers(token, yieldDist);
        }

        // 7. Transfer all roles to tokenAdmin, renounce factory's temporary roles
        {
            bytes32 DEFAULT_ADMIN = SecurityToken(payable(token)).DEFAULT_ADMIN_ROLE();
            bytes32 AGENT         = SecurityToken(payable(token)).AGENT_ROLE();
            bytes32 PAUSER        = SecurityToken(payable(token)).PAUSER_ROLE();

            SecurityToken(payable(token)).grantRole(DEFAULT_ADMIN, tokenAdmin);
            SecurityToken(payable(token)).grantRole(AGENT,         tokenAdmin);
            SecurityToken(payable(token)).grantRole(PAUSER,        tokenAdmin);
            SecurityToken(payable(token)).renounceRole(AGENT,         address(this));
            SecurityToken(payable(token)).renounceRole(PAUSER,        address(this));
            SecurityToken(payable(token)).renounceRole(DEFAULT_ADMIN, address(this));
        }

        if (yieldDist != address(0)) {
            YieldDistributor yd = YieldDistributor(payable(yieldDist));
            yd.grantRole(yd.DEFAULT_ADMIN_ROLE(), tokenAdmin);
            yd.grantRole(yd.AGENT_ROLE(),         tokenAdmin);
            yd.grantRole(yd.PAUSER_ROLE(),        tokenAdmin);
            yd.renounceRole(yd.AGENT_ROLE(),         address(this));
            yd.renounceRole(yd.PAUSER_ROLE(),        address(this));
            yd.renounceRole(yd.DEFAULT_ADMIN_ROLE(), address(this));
        }

        // 8. Record
        deployments.push(DeploymentRecord({
            identityRegistry: ir,
            compliance:       comp,
            token:            token,
            yieldDistributor: yieldDist,
            bondTerms:        bondTermsAddr,
            deployedBy:       msg.sender,
            deployedAt:       block.timestamp,
            issuerId:         issuerId,
            tokenType:        tokenType
        }));
        issuerDeploymentIndex[issuerId] = deployments.length;

        emit TokenDeployed(issuerId, tokenType, ir, comp, token, yieldDist, bondTermsAddr, msg.sender);
    }

    // ── Registry helpers ──────────────────────────────────────────

    function totalDeployments() external view returns (uint256) {
        return deployments.length;
    }

    function getDeployment(string calldata issuerId)
        external view returns (DeploymentRecord memory)
    {
        uint256 idx = issuerDeploymentIndex[issuerId];
        require(idx > 0, "Factory: unknown issuerId");
        return deployments[idx - 1];
    }

    function getDeploymentByIndex(uint256 index)
        external view returns (DeploymentRecord memory)
    {
        require(index < deployments.length, "Factory: out of range");
        return deployments[index];
    }

    // ── Admin ─────────────────────────────────────────────────────

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
