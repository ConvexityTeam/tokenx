// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/BusinessWallet.sol";
import "../../src/WalletFactory.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Required env vars (add to .env as needed per target):
//
//    FACTORY_ADDRESS   — deployed WalletFactory address
//    BUSINESS_ID       — bytes32 business identifier (0x-prefixed hex)
//    WALLET_ADMIN      — address granted all roles on the new wallet
//    SALT              — bytes32 CREATE2 salt (0x-prefixed hex)
//    NEW_POOL          — new pool wallet address
//    TOKEN_ADDRESS     — single ERC-20 token address
//    TOKEN_ADDRESSES   — comma-delimited ERC-20 list e.g. "0x...,0x..."
//    ROLE_ACCOUNT      — address to grant/revoke a role to/from
//    OFFSET            — pagination start (uint256)
//    LIMIT             — pagination page size (uint256)
// ─────────────────────────────────────────────────────────────────────────────

// ── Wallet Creation ───────────────────────────────────────────────────────────

/**
 * @notice Deploy a new BusinessWallet for a business (standard CREATE).
 *         Requires DEPLOYER_ROLE.
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID, WALLET_ADMIN
 */
contract CreateWallet is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");
        address admin         = vm.envAddress("WALLET_ADMIN");

        vm.startBroadcast();
        address wallet = factory.createWallet(businessId, admin);
        vm.stopBroadcast();

        console.log("Wallet deployed :", wallet);
        console.log("Business ID     :");
        console.logBytes32(businessId);
        console.log("Admin           :", admin);
    }
}

/**
 * @notice Deploy a BusinessWallet at a deterministic CREATE2 address.
 *         Compute the address first with PredictWalletAddress.
 *         Requires DEPLOYER_ROLE.
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID, WALLET_ADMIN, SALT
 */
contract CreateWalletDeterministic is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");
        address admin         = vm.envAddress("WALLET_ADMIN");
        bytes32 salt          = vm.envBytes32("SALT");

        // Show predicted address before deploying.
        address predicted = factory.predictWalletAddress(businessId, admin, salt);
        console.log("Predicted address:", predicted);

        vm.startBroadcast();
        address wallet = factory.createWalletDeterministic(businessId, admin, salt);
        vm.stopBroadcast();

        console.log("Deployed wallet  :", wallet);
        require(wallet == predicted, "address mismatch");
    }
}

/**
 * @notice Predict the CREATE2 address without deploying (read-only).
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID, WALLET_ADMIN, SALT
 */
contract PredictWalletAddress is Script {
    function run() external view {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");
        address admin         = vm.envAddress("WALLET_ADMIN");
        bytes32 salt          = vm.envBytes32("SALT");

        address predicted = factory.predictWalletAddress(businessId, admin, salt);
        console.log("Predicted wallet address:", predicted);
    }
}

// ── Sweep via Factory ─────────────────────────────────────────────────────────

/**
 * @notice Sweep residual ETH from a business wallet to its pool.
 *         The factory holds SWEEPER_ROLE on every wallet it creates.
 *         Requires DEPLOYER_ROLE on the factory.
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID
 */
contract SweepWalletETH is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");

        vm.startBroadcast();
        factory.sweepWalletETH(businessId);
        vm.stopBroadcast();

        console.log("ETH swept for business:");
        console.logBytes32(businessId);
    }
}

/**
 * @notice Sweep ERC-20 tokens from a business wallet to its pool.
 *         Requires DEPLOYER_ROLE on the factory.
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID, TOKEN_ADDRESSES (comma-delimited)
 */
contract SweepWalletTokens is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");
        address[] memory tokens = vm.envAddress("TOKEN_ADDRESSES", ",");

        vm.startBroadcast();
        factory.sweepWalletTokens(businessId, tokens);
        vm.stopBroadcast();

        console.log("Tokens swept:", tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            console.log(" ", tokens[i]);
        }
    }
}

// ── Factory Admin ─────────────────────────────────────────────────────────────

/**
 * @notice Update the pool wallet used for all future wallet deployments.
 *         Does NOT retroactively update existing wallets.
 *         Requires POOL_MANAGER_ROLE.
 *
 * Env: FACTORY_ADDRESS, NEW_POOL
 */
contract SetFactoryPoolWallet is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        address newPool       = vm.envAddress("NEW_POOL");

        console.log("Old pool:", factory.poolWallet());

        vm.startBroadcast();
        factory.setPoolWallet(newPool);
        vm.stopBroadcast();

        console.log("New pool:", factory.poolWallet());
    }
}

/**
 * @notice Mark a business wallet as inactive in the factory registry.
 *         Does not pause or destroy the wallet itself.
 *         Requires DEFAULT_ADMIN_ROLE.
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID
 */
contract DeactivateWallet is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");

        vm.startBroadcast();
        factory.deactivateWallet(businessId);
        vm.stopBroadcast();

        console.log("Wallet deactivated for business:");
        console.logBytes32(businessId);
    }
}

/**
 * @notice Grant a factory role to an address.
 *         Valid roles: DEPLOYER_ROLE, POOL_MANAGER_ROLE, PAUSER_ROLE.
 *         Requires DEFAULT_ADMIN_ROLE.
 *
 * Env: FACTORY_ADDRESS, ROLE (bytes32 keccak256 hash), ROLE_ACCOUNT
 */
contract GrantFactoryRole is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 role          = vm.envBytes32("ROLE");
        address account       = vm.envAddress("ROLE_ACCOUNT");

        vm.startBroadcast();
        factory.grantRole(role, account);
        vm.stopBroadcast();

        console.log("Role granted to:", account);
        console.logBytes32(role);
    }
}

/**
 * @notice Revoke a factory role from an address.
 *         Requires DEFAULT_ADMIN_ROLE.
 *
 * Env: FACTORY_ADDRESS, ROLE (bytes32 keccak256 hash), ROLE_ACCOUNT
 */
contract RevokeFactoryRole is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 role          = vm.envBytes32("ROLE");
        address account       = vm.envAddress("ROLE_ACCOUNT");

        vm.startBroadcast();
        factory.revokeRole(role, account);
        vm.stopBroadcast();

        console.log("Role revoked from:", account);
        console.logBytes32(role);
    }
}

/**
 * @notice Pause the factory — prevents new wallet creation.
 *         Requires PAUSER_ROLE.
 *
 * Env: FACTORY_ADDRESS
 */
contract PauseFactory is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));

        vm.startBroadcast();
        factory.pause();
        vm.stopBroadcast();

        console.log("Factory paused");
    }
}

/**
 * @notice Unpause the factory.
 *         Requires PAUSER_ROLE.
 *
 * Env: FACTORY_ADDRESS
 */
contract UnpauseFactory is Script {
    function run() external {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));

        vm.startBroadcast();
        factory.unpause();
        vm.stopBroadcast();

        console.log("Factory unpaused");
    }
}

// ── Factory Read ──────────────────────────────────────────────────────────────

/**
 * @notice Get the full record for a deployed wallet (read-only).
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID
 */
contract GetWallet is Script {
    function run() external view {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");

        WalletFactory.WalletRecord memory rec = factory.getWallet(businessId);
        console.log("Wallet      :", rec.wallet);
        console.log("Admin       :", rec.admin);
        console.log("Deployed by :", rec.deployedBy);
        console.log("Deployed at :", rec.deployedAt);
        console.log("Active      :", rec.active);
    }
}

/**
 * @notice Get the wallet address for a business (read-only).
 *         Returns address(0) if not deployed.
 *
 * Env: FACTORY_ADDRESS, BUSINESS_ID
 */
contract WalletOf is Script {
    function run() external view {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        bytes32 businessId    = vm.envBytes32("BUSINESS_ID");

        address wallet = factory.walletOf(businessId);
        console.log("Wallet:", wallet);
    }
}

/**
 * @notice Get the total number of deployed wallets (read-only).
 *
 * Env: FACTORY_ADDRESS
 */
contract TotalWallets is Script {
    function run() external view {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));

        uint256 total = factory.totalWallets();
        console.log("Total wallets deployed:", total);
    }
}

/**
 * @notice List wallets with pagination (read-only).
 *
 * Env: FACTORY_ADDRESS, OFFSET, LIMIT
 */
contract GetWallets is Script {
    function run() external view {
        WalletFactory factory = WalletFactory(vm.envAddress("FACTORY_ADDRESS"));
        uint256 offset        = vm.envUint("OFFSET");
        uint256 limit         = vm.envUint("LIMIT");

        WalletFactory.WalletRecord[] memory records = factory.getWallets(offset, limit);
        console.log("Records returned:", records.length);
        for (uint256 i; i < records.length; ++i) {
            console.log("-------------------------------------");
            console.log("  Wallet      :", records[i].wallet);
            console.log("  Admin       :", records[i].admin);
            console.log("  Deployed at :", records[i].deployedAt);
            console.log("  Active      :", records[i].active);
        }
    }
}

/**
 * @notice Print role hashes for easy copy-paste into ROLE env var (read-only).
 */
contract PrintRoles is Script {
    function run() external pure {
        console.log("DEFAULT_ADMIN_ROLE :");
        console.logBytes32(0x0000000000000000000000000000000000000000000000000000000000000000);
        console.log("DEPLOYER_ROLE      :");
        console.logBytes32(keccak256("DEPLOYER_ROLE"));
        console.log("POOL_MANAGER_ROLE  :");
        console.logBytes32(keccak256("POOL_MANAGER_ROLE"));
        console.log("PAUSER_ROLE        :");
        console.logBytes32(keccak256("PAUSER_ROLE"));
    }
}
