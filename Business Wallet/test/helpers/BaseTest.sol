// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../../src/IdentityRegistry.sol";
import "../../src/ComplianceModule.sol";
import "../../src/SecurityToken.sol";
import "../../src/YieldDistributor.sol";
import "../../src/BondTerms.sol";
import "../../src/TokenizationFactory.sol";

/**
 * @title BaseTest
 * @notice Shared helpers for deploying upgradeable contracts via BeaconProxy.
 *
 *   All implementation contracts now call _disableInitializers() in their
 *   constructors, so they cannot be initialized directly.  Every test that
 *   needs a live contract instance must go through a BeaconProxy.
 *
 *   Usage in a test contract:
 *
 *     contract MyTest is BaseTest {
 *         function setUp() public {
 *             _deployBeacons();
 *             registry = _makeIR(admin);
 *         }
 *     }
 */
abstract contract BaseTest is Test {

    UpgradeableBeacon public beaconIR;
    UpgradeableBeacon public beaconCM;
    UpgradeableBeacon public beaconST;
    UpgradeableBeacon public beaconYD;
    UpgradeableBeacon public beaconBT;

    /// @dev Deploy all five implementation contracts and their beacons.
    ///      Call this once in setUp() before using any _make* helper.
    function _deployBeacons() internal {
        beaconIR = new UpgradeableBeacon(address(new IdentityRegistry()));
        beaconCM = new UpgradeableBeacon(address(new ComplianceModule()));
        beaconST = new UpgradeableBeacon(address(new SecurityToken()));
        beaconYD = new UpgradeableBeacon(address(new YieldDistributor()));
        beaconBT = new UpgradeableBeacon(address(new BondTerms()));
    }

    // ── Per-contract proxy factories ──────────────────────────────

    function _makeIR(address admin) internal returns (IdentityRegistry) {
        return _makeIR(admin, address(0));
    }

    function _makeIR(address admin, address fwd) internal returns (IdentityRegistry) {
        return IdentityRegistry(address(new BeaconProxy(
            address(beaconIR),
            abi.encodeCall(IdentityRegistry.initialize, (admin, fwd))
        )));
    }

    function _makeCM(address admin, uint256 maxS, uint256 maxT, uint256 lockup)
        internal returns (ComplianceModule)
    {
        return _makeCM(admin, maxS, maxT, lockup, address(0));
    }

    function _makeCM(address admin, uint256 maxS, uint256 maxT, uint256 lockup, address fwd)
        internal returns (ComplianceModule)
    {
        return ComplianceModule(address(new BeaconProxy(
            address(beaconCM),
            abi.encodeCall(ComplianceModule.initialize, (admin, maxS, maxT, lockup, fwd))
        )));
    }

    function _makeST(
        string memory name,
        string memory sym,
        address ir,
        address cm,
        address admin
    ) internal returns (SecurityToken) {
        return _makeST(name, sym, address(0), ir, cm, admin, address(0));
    }

    function _makeST(
        string memory name,
        string memory sym,
        address onchainID,
        address ir,
        address cm,
        address admin,
        address fwd
    ) internal returns (SecurityToken) {
        return SecurityToken(payable(address(new BeaconProxy(
            address(beaconST),
            abi.encodeCall(SecurityToken.initialize, (name, sym, onchainID, ir, cm, admin, fwd))
        ))));
    }

    function _makeYD(address token, address admin) internal returns (YieldDistributor) {
        return _makeYD(token, admin, address(0));
    }

    function _makeYD(address token, address admin, address fwd) internal returns (YieldDistributor) {
        return YieldDistributor(payable(address(new BeaconProxy(
            address(beaconYD),
            abi.encodeCall(YieldDistributor.initialize, (token, admin, fwd))
        ))));
    }

    function _makeBT(BondTerms.InitParams memory p) internal returns (BondTerms) {
        return _makeBT(p, address(0));
    }

    function _makeBT(BondTerms.InitParams memory p, address fwd) internal returns (BondTerms) {
        return BondTerms(address(new BeaconProxy(
            address(beaconBT),
            abi.encodeCall(BondTerms.initialize, (p, fwd))
        )));
    }

    function _makeFactory(address admin) internal returns (TokenizationFactory) {
        return new TokenizationFactory(
            admin,
            address(beaconIR),
            address(beaconCM),
            address(beaconST),
            address(beaconYD),
            address(beaconBT),
            address(0)
        );
    }

    function _makeFactory(address admin, address fwd) internal returns (TokenizationFactory) {
        return new TokenizationFactory(
            admin,
            address(beaconIR),
            address(beaconCM),
            address(beaconST),
            address(beaconYD),
            address(beaconBT),
            fwd
        );
    }
}
