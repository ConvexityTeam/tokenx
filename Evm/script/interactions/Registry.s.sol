// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/IdentityRegistry.sol";

// ── RegisterIdentity ────────────────────────────────────────────────────────

contract RegisterIdentity is Script {
    function run() external {
        uint256 privateKey       = vm.envUint("PRIVATE_KEY");
        address registryAddress  = vm.envAddress("REGISTRY_ADDRESS");
        address wallet           = vm.envAddress("WALLET");
        address onchainId        = vm.envOr("ONCHAIN_ID", address(0));
        uint16  country          = uint16(vm.envUint("COUNTRY"));

        IdentityRegistry registry = IdentityRegistry(registryAddress);

        vm.startBroadcast(privateKey);
        registry.registerIdentity(wallet, onchainId, country);
        vm.stopBroadcast();

        console.log("Identity registered:");
        console.log("  Wallet     :", wallet);
        console.log("  OnchainID  :", onchainId);
        console.log("  Country    :", country);
    }
}

// ── DeleteIdentity ──────────────────────────────────────────────────────────

contract DeleteIdentity is Script {
    function run() external {
        uint256 privateKey      = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address wallet          = vm.envAddress("WALLET");

        IdentityRegistry registry = IdentityRegistry(registryAddress);

        vm.startBroadcast(privateKey);
        registry.deleteIdentity(wallet);
        vm.stopBroadcast();

        console.log("Identity deleted for wallet:", wallet);
    }
}

// ── UpdateCountry ───────────────────────────────────────────────────────────

contract UpdateCountry is Script {
    function run() external {
        uint256 privateKey      = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address wallet          = vm.envAddress("WALLET");
        uint16  country         = uint16(vm.envUint("COUNTRY"));

        IdentityRegistry registry = IdentityRegistry(registryAddress);

        vm.startBroadcast(privateKey);
        registry.updateCountry(wallet, country);
        vm.stopBroadcast();

        console.log("Country updated:");
        console.log("  Wallet  :", wallet);
        console.log("  Country :", country);
    }
}

// ── UpdateIdentity ──────────────────────────────────────────────────────────

contract UpdateIdentity is Script {
    function run() external {
        uint256 privateKey      = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address wallet          = vm.envAddress("WALLET");
        address newOnchainId    = vm.envAddress("NEW_ONCHAIN_ID");

        IdentityRegistry registry = IdentityRegistry(registryAddress);

        vm.startBroadcast(privateKey);
        registry.updateIdentity(wallet, newOnchainId);
        vm.stopBroadcast();

        console.log("Identity updated:");
        console.log("  Wallet        :", wallet);
        console.log("  New OnchainID :", newOnchainId);
    }
}

// ── SetVerified ─────────────────────────────────────────────────────────────

contract SetVerified is Script {
    function run() external {
        uint256 privateKey      = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address wallet          = vm.envAddress("WALLET");
        bool    verified        = vm.envBool("VERIFIED");

        IdentityRegistry registry = IdentityRegistry(registryAddress);

        vm.startBroadcast(privateKey);
        registry.setVerified(wallet, verified);
        vm.stopBroadcast();

        console.log("Verified flag set:");
        console.log("  Wallet   :", wallet);
        console.log("  Verified :", verified);
    }
}

// ── IsVerified (read-only) ──────────────────────────────────────────────────

contract IsVerified is Script {
    function run() external view {
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address wallet          = vm.envAddress("WALLET");

        IdentityRegistry registry = IdentityRegistry(registryAddress);
        bool result = registry.isVerified(wallet);

        console.log("isVerified check:");
        console.log("  Wallet   :", wallet);
        console.log("  Verified :", result);
    }
}
