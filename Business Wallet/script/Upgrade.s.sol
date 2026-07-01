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

/**
 * @notice Upgrade a beacon to a new implementation contract.
 *
 *   After calling this script, every BeaconProxy that points to BEACON_ADDRESS
 *   instantly delegates to the new implementation.  No per-token action needed.
 *
 *   Required env vars:
 *     BEACON_ADDRESS   — address of the UpgradeableBeacon to upgrade
 *     NEW_IMPL_ADDRESS — address of the already-deployed new implementation
 *
 *   The caller must be the beacon owner (set to ADMIN_ADDRESS at deploy time).
 *
 *   Example — upgrade SecurityToken beacon:
 *     NEW_IMPL_ADDRESS=$(forge create src/SecurityTokenV2.sol:SecurityTokenV2 ...)
 *     BEACON_ADDRESS=$ST_BEACON_ADDRESS forge script script/Upgrade.s.sol --broadcast
 */
contract UpgradeBeacon is Script {
    function run() external {
        address beaconAddress  = vm.envAddress("BEACON_ADDRESS");
        address newImplAddress = vm.envAddress("NEW_IMPL_ADDRESS");

        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);
        address oldImpl = beacon.implementation();

        vm.startBroadcast();
        beacon.upgradeTo(newImplAddress);
        vm.stopBroadcast();

        console.log("=== Beacon Upgraded ===");
        console.log("Beacon:       ", beaconAddress);
        console.log("Old impl:     ", oldImpl);
        console.log("New impl:     ", newImplAddress);
        console.log("All proxies pointing to this beacon now use the new implementation.");
    }
}

/**
 * @notice Deploy a new implementation and upgrade a beacon in one transaction.
 *
 *   Convenience script that compiles, deploys, and upgrades atomically.
 *   The contract to deploy is selected by CONTRACT_TYPE env var.
 *
 *   Required env vars:
 *     BEACON_ADDRESS  — address of the UpgradeableBeacon to upgrade
 *     CONTRACT_TYPE   — one of: IdentityRegistry, ComplianceModule, SecurityToken,
 *                               YieldDistributor, BondTerms
 */
contract DeployAndUpgradeBeacon is Script {
    function run() external {
        address beaconAddress = vm.envAddress("BEACON_ADDRESS");
        string memory contractType = vm.envString("CONTRACT_TYPE");

        vm.startBroadcast();

        address newImpl;
        bytes32 typeHash = keccak256(bytes(contractType));

        if (typeHash == keccak256("IdentityRegistry")) {
            newImpl = address(new IdentityRegistry());
        } else if (typeHash == keccak256("ComplianceModule")) {
            newImpl = address(new ComplianceModule());
        } else if (typeHash == keccak256("SecurityToken")) {
            newImpl = address(new SecurityToken());
        } else if (typeHash == keccak256("YieldDistributor")) {
            newImpl = address(new YieldDistributor());
        } else if (typeHash == keccak256("BondTerms")) {
            newImpl = address(new BondTerms());
        } else {
            revert("Unknown CONTRACT_TYPE");
        }

        address oldImpl = UpgradeableBeacon(beaconAddress).implementation();
        UpgradeableBeacon(beaconAddress).upgradeTo(newImpl);

        vm.stopBroadcast();

        console.log("=== Deployed & Upgraded ===");
        console.log("Contract type:", contractType);
        console.log("Beacon:       ", beaconAddress);
        console.log("Old impl:     ", oldImpl);
        console.log("New impl:     ", newImpl);
    }
}
