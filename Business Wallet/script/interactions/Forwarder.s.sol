// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/TokenxForwarder.sol";

// ── GrantRelayerRole ────────────────────────────────────────────────────────

contract GrantRelayerRole is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");
        address account = vm.envAddress("RELAYER_ADDRESS");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));
        bytes32 relayerRole = fwd.RELAYER_ROLE();

        vm.startBroadcast();
        fwd.grantRole(relayerRole, account);
        vm.stopBroadcast();

        console.log("RELAYER_ROLE granted to:", account);
    }
}

// ── RevokeRelayerRole ──────────────────────────────────────────────────────

contract RevokeRelayerRole is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");
        address account = vm.envAddress("RELAYER_ADDRESS");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));
        bytes32 relayerRole = fwd.RELAYER_ROLE();

        vm.startBroadcast();
        fwd.revokeRole(relayerRole, account);
        vm.stopBroadcast();

        console.log("RELAYER_ROLE revoked from:", account);
    }
}

// ── TransferOwnership ───────────────────────────────────────────────────────
// Grants DEFAULT_ADMIN_ROLE + RELAYER_ROLE to NEW_ADMIN_ADDRESS, then
// renounces the caller's own roles.  NEW_ADMIN must be confirmed first.

contract TransferOwnership is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");
        address newAdmin = vm.envAddress("NEW_ADMIN_ADDRESS");

        require(newAdmin != address(0), "NEW_ADMIN_ADDRESS not set");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));
        bytes32 defaultAdminRole = fwd.DEFAULT_ADMIN_ROLE();
        bytes32 relayerRole = fwd.RELAYER_ROLE();

        address caller = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast();

        // 1. Grant all roles to the new admin
        fwd.grantRole(defaultAdminRole, newAdmin);
        fwd.grantRole(relayerRole, newAdmin);

        // 2. Renounce caller's own roles (DEFAULT_ADMIN_ROLE last)
        fwd.renounceRole(relayerRole, caller);
        fwd.renounceRole(defaultAdminRole, caller);

        vm.stopBroadcast();

        console.log("Forwarder ownership transferred");
        console.log("  New admin :", newAdmin);
        console.log("  Old admin :", caller);
    }
}

// ── GrantAdminRole ──────────────────────────────────────────────────────────
// Grants DEFAULT_ADMIN_ROLE to an address without revoking the caller's role.
// Use when adding a co-admin or staging a safe two-step transfer.

contract GrantAdminRole is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");
        address account = vm.envAddress("NEW_ADMIN_ADDRESS");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));

        vm.startBroadcast();
        fwd.grantRole(fwd.DEFAULT_ADMIN_ROLE(), account);
        vm.stopBroadcast();

        console.log("DEFAULT_ADMIN_ROLE granted to:", account);
    }
}

// ── RenounceAdminRole ───────────────────────────────────────────────────────
// Caller renounces their own DEFAULT_ADMIN_ROLE + RELAYER_ROLE.
// Run this after confirming the new admin has taken over (step 2 of a
// two-step transfer started with GrantAdminRole).

contract RenounceAdminRole is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));

        address caller = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast();
        fwd.renounceRole(fwd.RELAYER_ROLE(), caller);
        fwd.renounceRole(fwd.DEFAULT_ADMIN_ROLE(), caller);
        vm.stopBroadcast();

        console.log("All forwarder roles renounced by:", caller);
    }
}

// ── PauseForwarder ──────────────────────────────────────────────────────────

contract PauseForwarder is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));

        vm.startBroadcast();
        fwd.pause();
        vm.stopBroadcast();

        console.log("Forwarder paused:", forwarder);
    }
}

// ── UnpauseForwarder ────────────────────────────────────────────────────────

contract UnpauseForwarder is Script {
    function run() external {
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        TokenxForwarder fwd = TokenxForwarder(payable(forwarder));

        vm.startBroadcast();
        fwd.unpause();
        vm.stopBroadcast();

        console.log("Forwarder unpaused:", forwarder);
    }
}
