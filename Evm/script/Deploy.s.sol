// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/IdentityRegistry.sol";
import "../src/ComplianceModule.sol";
import "../src/SecurityToken.sol";
import "../src/YieldDistributor.sol";
import "../src/BondTerms.sol";
import "../src/TokenizationFactory.sol";
import "../src/TokenxForwarder.sol";

/**
 * @notice Deploy the full TokenizationFactory suite with Beacon Proxy upgradeability.
 *
 *   Step 1: Deploy implementation contracts (one-time logic).
 *   Step 2: Deploy UpgradeableBeacon for each implementation, owned by ADMIN_ADDRESS.
 *   Step 3: Deploy TokenxForwarder (EIP-2771 relayer), owned by ADMIN_ADDRESS.
 *   Step 4: Deploy TokenizationFactory pointing to the beacons + forwarder.
 *
 *   To upgrade any contract type later, call beacon.upgradeTo(newImpl) from ADMIN_ADDRESS.
 *   All existing proxies instantly delegate to the new implementation.
 *
 *   Required env vars:
 *     ADMIN_ADDRESS  — address that receives all admin roles and beacon ownership
 */
contract DeployFactory is Script {
    function run() external {
        address adminAddress = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast();

        // ── 1. Deploy implementations ─────────────────────────────
        IdentityRegistry implIR = new IdentityRegistry();
        ComplianceModule implCM = new ComplianceModule();
        SecurityToken    implST = new SecurityToken();
        YieldDistributor implYD = new YieldDistributor();
        BondTerms        implBT = new BondTerms();

        // ── 2. Deploy beacons (owned by admin) ────────────────────
        UpgradeableBeacon beaconIR = new UpgradeableBeacon(address(implIR));
        UpgradeableBeacon beaconCM = new UpgradeableBeacon(address(implCM));
        UpgradeableBeacon beaconST = new UpgradeableBeacon(address(implST));
        UpgradeableBeacon beaconYD = new UpgradeableBeacon(address(implYD));
        UpgradeableBeacon beaconBT = new UpgradeableBeacon(address(implBT));

        // Transfer beacon ownership to admin (deployer owns them by default)
        beaconIR.transferOwnership(adminAddress);
        beaconCM.transferOwnership(adminAddress);
        beaconST.transferOwnership(adminAddress);
        beaconYD.transferOwnership(adminAddress);
        beaconBT.transferOwnership(adminAddress);

        // ── 3. Deploy forwarder ───────────────────────────────────
        TokenxForwarder forwarder = new TokenxForwarder(adminAddress);

        // ── 4. Deploy factory ─────────────────────────────────────
        TokenizationFactory factory = new TokenizationFactory(
            adminAddress,
            address(beaconIR),
            address(beaconCM),
            address(beaconST),
            address(beaconYD),
            address(beaconBT),
            address(forwarder)
        );

        vm.stopBroadcast();

        console.log("=== Implementations ===");
        console.log("IdentityRegistry impl: ", address(implIR));
        console.log("ComplianceModule impl: ", address(implCM));
        console.log("SecurityToken impl:    ", address(implST));
        console.log("YieldDistributor impl: ", address(implYD));
        console.log("BondTerms impl:        ", address(implBT));
        console.log("=== Beacons (owned by admin) ===");
        console.log("IdentityRegistry beacon: ", address(beaconIR));
        console.log("ComplianceModule beacon: ", address(beaconCM));
        console.log("SecurityToken beacon:    ", address(beaconST));
        console.log("YieldDistributor beacon: ", address(beaconYD));
        console.log("BondTerms beacon:        ", address(beaconBT));
        console.log("=== Core contracts ===");
        console.log("TokenxForwarder:   ", address(forwarder));
        console.log("TokenizationFactory: ", address(factory));
        console.log("Admin address:       ", adminAddress);
    }
}

/**
 * @notice Deploy a tokenized bond suite through an existing TokenizationFactory.
 *
 *   Required env vars:
 *     FACTORY_ADDRESS       — deployed TokenizationFactory
 *     ISSUER_ID             — unique bond identifier, e.g. "ACME-BOND-5Y-2025"
 *     TOKEN_NAME            — bond name
 *     TOKEN_SYMBOL          — bond ticker
 *     TOKEN_ADMIN           — wallet that controls the deployed suite
 *     ISSUER_ONCHAIN_ID     — issuer identity address (zero address if none)
 *     MAX_SHAREHOLDERS      — 0 = unlimited
 *     MAX_TOKENS_PER_INVESTOR — 0 = unlimited
 *     LOCKUP_DURATION       — seconds, 0 = none
 *     ANNUAL_RATE_BPS       — e.g. 750 = 7.50% APR
 *     COUPON_PERIOD_SECONDS — e.g. 7776000 = 90 days
 *     DAY_COUNT             — 0=ACT_365  1=ACT_360  2=THIRTY_360
 *     ISSUE_DATE            — unix timestamp
 *     MATURITY_DATE         — unix timestamp
 *     FIRST_COUPON_DATE     — unix timestamp
 *     FACE_VALUE_PER_TOKEN  — par value in payout token decimals
 *     GRACE_PERIOD_SECONDS  — e.g. 604800 = 7 days
 *     CALLABLE              — true/false
 *     CALL_DATE             — unix timestamp, 0 if not callable
 */
contract DeployBond is Script {
    function run() external {
        address factoryAddress  = vm.envAddress("FACTORY_ADDRESS");
        string  memory issuerId = vm.envString("ISSUER_ID");
        string  memory name     = vm.envString("TOKEN_NAME");
        string  memory symbol   = vm.envString("TOKEN_SYMBOL");
        address tokenAdmin      = vm.envAddress("TOKEN_ADMIN");
        address issuerOnchainID = vm.envOr("ISSUER_ONCHAIN_ID", address(0));

        TokenizationFactory.ComplianceParams memory comp = TokenizationFactory.ComplianceParams({
            maxShareholders:      vm.envOr("MAX_SHAREHOLDERS",        uint256(0)),
            maxTokensPerInvestor: vm.envOr("MAX_TOKENS_PER_INVESTOR", uint256(0)),
            lockUpDuration:       vm.envOr("LOCKUP_DURATION",         uint256(0))
        });

        BondTerms.InitParams memory bond = BondTerms.InitParams({
            annualRateBps:       vm.envUint("ANNUAL_RATE_BPS"),
            couponPeriodSeconds: vm.envUint("COUPON_PERIOD_SECONDS"),
            dayCount:            BondTerms.DayCount(vm.envOr("DAY_COUNT", uint256(0))),
            issueDate:           vm.envOr("ISSUE_DATE",   block.timestamp),
            maturityDate:        vm.envUint("MATURITY_DATE"),
            firstCouponDate:     vm.envUint("FIRST_COUPON_DATE"),
            faceValuePerToken:   vm.envUint("FACE_VALUE_PER_TOKEN"),
            gracePeriodSeconds:  vm.envOr("GRACE_PERIOD_SECONDS", uint256(0)),
            callable:                 vm.envOr("CALLABLE",    false),
            callDate:                 vm.envOr("CALL_DATE",   uint256(0)),
            admin:                    tokenAdmin,
            earlyRedemptionFeeBps:    vm.envOr("EARLY_REDEMPTION_FEE_BPS", uint256(0))
        });

        vm.startBroadcast();

        (address token, address bondTerms) = TokenizationFactory(factoryAddress).deployBond(
            issuerId, name, symbol, issuerOnchainID, tokenAdmin, comp, bond
        );

        vm.stopBroadcast();

        TokenizationFactory.DeploymentRecord memory record =
            TokenizationFactory(factoryAddress).getDeployment(issuerId);

        console.log("=== Bond Suite Deployed ===");
        console.log("Issuer ID           :", issuerId);
        console.log("SecurityToken       :", token);
        console.log("IdentityRegistry    :", record.identityRegistry);
        console.log("ComplianceModule    :", record.compliance);
        console.log("YieldDistributor    :", record.yieldDistributor);
        console.log("BondTerms           :", bondTerms);
        console.log("Token admin         :", tokenAdmin);
        console.log("Annual rate (bps)   :", bond.annualRateBps);
        console.log("Maturity date       :", bond.maturityDate);
        console.log("Face value/token    :", bond.faceValuePerToken);
    }
}
