// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/TokenizationFactory.sol";

// ── GetDeployment (read-only) ───────────────────────────────────────────────

contract GetDeployment is Script {
    function run() external view {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        string memory issuerId = vm.envString("ISSUER_ID");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);
        TokenizationFactory.DeploymentRecord memory record = factory
            .getDeployment(issuerId);

        console.log("Deployment record for issuer:", issuerId);
        console.log("  IdentityRegistry  :", record.identityRegistry);
        console.log("  Compliance        :", record.compliance);
        console.log("  Token             :", record.token);
        console.log("  YieldDistributor  :", record.yieldDistributor);
        console.log("  Deployed by       :", record.deployedBy);
        console.log("  Deployed at       :", record.deployedAt);
        console.log("  Token type        :", uint256(record.tokenType));
    }
}

// ── GetDeploymentByIndex (read-only) ────────────────────────────────────────

contract GetDeploymentByIndex is Script {
    function run() external view {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        uint256 index = vm.envOr("INDEX", uint256(0));

        TokenizationFactory factory = TokenizationFactory(factoryAddress);
        TokenizationFactory.DeploymentRecord memory record = factory
            .getDeploymentByIndex(index);

        console.log("Deployment record at index:", index);
        console.log("  Issuer ID         :", record.issuerId);
        console.log("  IdentityRegistry  :", record.identityRegistry);
        console.log("  Compliance        :", record.compliance);
        console.log("  Token             :", record.token);
        console.log("  YieldDistributor  :", record.yieldDistributor);
        console.log("  Deployed by       :", record.deployedBy);
        console.log("  Deployed at       :", record.deployedAt);
        console.log("  Token type        :", uint256(record.tokenType));
    }
}

// ── TotalDeployments (read-only) ────────────────────────────────────────────

contract TotalDeployments is Script {
    function run() external view {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);
        uint256 total = factory.totalDeployments();

        console.log("Total deployments:", total);
    }
}

// ── PauseFactory ────────────────────────────────────────────────────────────

contract PauseFactory is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);

        vm.startBroadcast(privateKey);
        factory.pause();
        vm.stopBroadcast();

        console.log("Factory paused:", factoryAddress);
    }
}

// ── UnpauseFactory ──────────────────────────────────────────────────────────

contract UnpauseFactory is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);

        vm.startBroadcast(privateKey);
        factory.unpause();
        vm.stopBroadcast();

        console.log("Factory unpaused:", factoryAddress);
    }
}

// ── GrantDeployerRole ───────────────────────────────────────────────────────

contract GrantDeployerRole is Script {
    function run() external {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address account = vm.envAddress("NEW_ADMIN_ADDRESS");
        vm.startBroadcast();
        TokenizationFactory factory = TokenizationFactory(factoryAddress);
        bytes32 deployerRole = factory.DEPLOYER_ROLE();

        factory.grantRole(deployerRole, account);
        vm.stopBroadcast();

        console.log("DEPLOYER_ROLE granted to:", account);
    }
}

// ── RevokeDeployerRole ──────────────────────────────────────────────────────

contract RevokeDeployerRole is Script {
    function run() external {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address account = vm.envAddress("ACCOUNT");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);
        bytes32 deployerRole = factory.DEPLOYER_ROLE();

        vm.startBroadcast();
        factory.revokeRole(deployerRole, account);
        vm.stopBroadcast();

        console.log("DEPLOYER_ROLE revoked from:", account);
    }
}

// ── TransferOwnership ───────────────────────────────────────────────────────
// Grants DEFAULT_ADMIN_ROLE + all operational roles to NEW_ADMIN, then
// renounces the caller's own roles.  NEW_ADMIN must be confirmed first.

contract TransferOwnership is Script {
    function run() external {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address newAdmin = vm.envAddress("NEW_ADMIN_ADDRESS");

        require(newAdmin != address(0), "NEW_ADMIN_ADDRESS not set");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);
        bytes32 defaultAdminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 deployerRole = factory.DEPLOYER_ROLE();
        bytes32 pauserRole = factory.PAUSER_ROLE();

        address caller = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast();

        // 1. Grant all roles to the new admin
        factory.grantRole(defaultAdminRole, newAdmin);
        factory.grantRole(deployerRole, newAdmin);
        factory.grantRole(pauserRole, newAdmin);

        // 2. Renounce caller's own roles (DEFAULT_ADMIN_ROLE last)
        factory.renounceRole(pauserRole, caller);
        factory.renounceRole(deployerRole, caller);
        factory.renounceRole(defaultAdminRole, caller);

        vm.stopBroadcast();

        console.log("Factory ownership transferred");
        console.log("  New admin :", newAdmin);
        console.log("  Old admin :", caller);
    }
}

// ── GrantAdminRole ──────────────────────────────────────────────────────────
// Grants DEFAULT_ADMIN_ROLE to an address without revoking the caller's role.
// Use when adding a co-admin or staging a safe two-step transfer.

contract GrantAdminRole is Script {
    function run() external {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address account = vm.envAddress("NEW_ADMIN_ADDRESS");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);

        vm.startBroadcast();
        factory.grantRole(factory.DEFAULT_ADMIN_ROLE(), account);
        vm.stopBroadcast();

        console.log("DEFAULT_ADMIN_ROLE granted to:", account);
    }
}

// ── RenounceAdminRole ───────────────────────────────────────────────────────
// Caller renounces their own DEFAULT_ADMIN_ROLE + operational roles.
// Run this after confirming the new admin has taken over (step 2 of a
// two-step transfer started with GrantAdminRole).

contract RenounceAdminRole is Script {
    function run() external {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

        TokenizationFactory factory = TokenizationFactory(factoryAddress);

        address caller = vm.envAddress("ADMIN_ADDRESS");

        vm.startBroadcast();
        factory.renounceRole(factory.PAUSER_ROLE(), caller);
        factory.renounceRole(factory.DEPLOYER_ROLE(), caller);
        factory.renounceRole(factory.DEFAULT_ADMIN_ROLE(), caller);
        vm.stopBroadcast();

        console.log("All factory roles renounced by:", caller);
    }
}
