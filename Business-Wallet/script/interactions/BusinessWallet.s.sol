// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/BusinessWallet.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Required env vars (add to .env as needed per target):
//
//    BUSINESS_WALLET_ADDRESS — deployed BusinessWallet (proxy) address
//    TOKEN_ADDRESS           — single ERC-20 token address
//    TOKEN_ADDRESSES         — comma-delimited ERC-20 list e.g. "0x...,0x..."
//    NEW_POOL                — new pool wallet address
//    EXECUTE_TARGET          — target contract address for execute()
//    EXECUTE_VALUE           — ETH amount in wei to send with execute()
//    EXECUTE_DATA            — ABI-encoded calldata hex for execute()
//    ROLE                    — bytes32 keccak256 role hash
//    ROLE_ACCOUNT            — address to grant/revoke a role to/from
// ─────────────────────────────────────────────────────────────────────────────

// ── ERC-20 Sweeps ─────────────────────────────────────────────────────────────

/**
 * @notice Permissionless ERC-20 sweep trigger for a single token.
 *         No role required — anyone can call this. Wallet must not be paused.
 *         Used by off-chain indexers when a Transfer event is detected.
 *
 * Env: BUSINESS_WALLET_ADDRESS, TOKEN_ADDRESS
 */
contract Notify is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        address token         = vm.envAddress("TOKEN_ADDRESS");

        vm.startBroadcast();
        wallet.notify(token);
        vm.stopBroadcast();

        console.log("notify() called for token:", token);
        console.log("Wallet               :", address(wallet));
    }
}

/**
 * @notice Sweep the wallet's full balance of a single token to the pool.
 *         Requires SWEEPER_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS, TOKEN_ADDRESS
 */
contract SweepToken is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        address token         = vm.envAddress("TOKEN_ADDRESS");

        vm.startBroadcast();
        wallet.sweepToken(token);
        vm.stopBroadcast();

        console.log("Token swept to pool:", wallet.poolWallet());
        console.log("Token              :", token);
    }
}

/**
 * @notice Sweep multiple ERC-20 balances to the pool in a single call.
 *         Requires SWEEPER_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS, TOKEN_ADDRESSES (comma-delimited)
 */
contract BatchSweepTokens is Script {
    function run() external {
        BusinessWallet wallet   = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        address[] memory tokens = vm.envAddress("TOKEN_ADDRESSES", ",");

        vm.startBroadcast();
        wallet.batchSweepTokens(tokens);
        vm.stopBroadcast();

        console.log("Batch swept", tokens.length, "token(s) to pool:", wallet.poolWallet());
        for (uint256 i; i < tokens.length; ++i) {
            console.log(" ", tokens[i]);
        }
    }
}

// ── ETH Sweep ─────────────────────────────────────────────────────────────────

/**
 * @notice Sweep residual ETH held in the wallet to the pool.
 *         Use when the automatic ETH forward previously failed (wallet was
 *         paused or pool reverted).  Requires SWEEPER_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS
 */
contract SweepETH is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));

        uint256 balBefore = address(wallet).balance;
        console.log("ETH balance before sweep:", balBefore);

        vm.startBroadcast();
        wallet.sweepETH();
        vm.stopBroadcast();

        console.log("ETH swept to pool:", wallet.poolWallet());
    }
}

// ── Smart-Wallet Execute ──────────────────────────────────────────────────────

/**
 * @notice Execute an arbitrary call from this wallet's address.
 *         Useful for protocol interactions, approvals, or governance actions
 *         that must originate from the business wallet itself.
 *         Requires EXECUTOR_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS, EXECUTE_TARGET, EXECUTE_VALUE, EXECUTE_DATA
 *
 * Example — call transfer(address,uint256) on an ERC-20:
 *   EXECUTE_TARGET=0x<token>
 *   EXECUTE_VALUE=0
 *   EXECUTE_DATA=$(cast calldata "transfer(address,uint256)" 0x<to> 1000000)
 */
contract Execute is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        address target        = vm.envAddress("EXECUTE_TARGET");
        uint256 value         = vm.envUint("EXECUTE_VALUE");
        bytes memory data     = vm.envBytes("EXECUTE_DATA");

        console.log("Executing call:");
        console.log("  Target :", target);
        console.log("  Value  :", value);

        vm.startBroadcast();
        bytes memory result = wallet.execute{value: value}(target, value, data);
        vm.stopBroadcast();

        console.log("Execution succeeded. Return data length:", result.length);
    }
}

// ── Wallet Admin ──────────────────────────────────────────────────────────────

/**
 * @notice Redirect future sweeps and forwards to a new pool wallet.
 *         Requires WALLET_ADMIN_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS, NEW_POOL
 */
contract SetWalletPool is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        address newPool       = vm.envAddress("NEW_POOL");

        console.log("Old pool:", wallet.poolWallet());

        vm.startBroadcast();
        wallet.setPoolWallet(newPool);
        vm.stopBroadcast();

        console.log("New pool:", wallet.poolWallet());
    }
}

/**
 * @notice Pause the wallet — halts sweeps and executions.
 *         ETH received while paused is held; call sweepETH() after unpausing.
 *         Requires PAUSER_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS
 */
contract PauseWallet is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));

        vm.startBroadcast();
        wallet.pause();
        vm.stopBroadcast();

        console.log("Wallet paused:", address(wallet));
    }
}

/**
 * @notice Unpause the wallet.
 *         Requires PAUSER_ROLE.
 *
 * Env: BUSINESS_WALLET_ADDRESS
 */
contract UnpauseWallet is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));

        vm.startBroadcast();
        wallet.unpause();
        vm.stopBroadcast();

        console.log("Wallet unpaused:", address(wallet));
    }
}

/**
 * @notice Grant a role to an address on a specific business wallet.
 *         Valid roles: WALLET_ADMIN_ROLE, SWEEPER_ROLE, EXECUTOR_ROLE, PAUSER_ROLE.
 *         Requires DEFAULT_ADMIN_ROLE on the wallet.
 *
 * Env: BUSINESS_WALLET_ADDRESS, ROLE (bytes32), ROLE_ACCOUNT
 */
contract GrantWalletRole is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        bytes32 role          = vm.envBytes32("ROLE");
        address account       = vm.envAddress("ROLE_ACCOUNT");

        vm.startBroadcast();
        wallet.grantRole(role, account);
        vm.stopBroadcast();

        console.log("Role granted to:", account, "on wallet:", address(wallet));
        console.logBytes32(role);
    }
}

/**
 * @notice Revoke a role from an address on a specific business wallet.
 *         Requires DEFAULT_ADMIN_ROLE on the wallet.
 *
 * Env: BUSINESS_WALLET_ADDRESS, ROLE (bytes32), ROLE_ACCOUNT
 */
contract RevokeWalletRole is Script {
    function run() external {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        bytes32 role          = vm.envBytes32("ROLE");
        address account       = vm.envAddress("ROLE_ACCOUNT");

        vm.startBroadcast();
        wallet.revokeRole(role, account);
        vm.stopBroadcast();

        console.log("Role revoked from:", account, "on wallet:", address(wallet));
        console.logBytes32(role);
    }
}

// ── Wallet Read ───────────────────────────────────────────────────────────────

/**
 * @notice Print all key state from a business wallet (read-only).
 *
 * Env: BUSINESS_WALLET_ADDRESS
 */
contract GetWalletInfo is Script {
    function run() external view {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));

        console.log("Address           :", address(wallet));
        console.log("Pool wallet       :", wallet.poolWallet());
        console.log("Trusted forwarder :", wallet.trustedForwarder());
        console.log("ETH balance       :", address(wallet).balance);
        console.log("Business ID       :");
        console.logBytes32(wallet.businessId());
    }
}

/**
 * @notice Check whether an address holds a given role on the wallet (read-only).
 *
 * Env: BUSINESS_WALLET_ADDRESS, ROLE (bytes32), ROLE_ACCOUNT
 */
contract CheckWalletRole is Script {
    function run() external view {
        BusinessWallet wallet = BusinessWallet(payable(vm.envAddress("BUSINESS_WALLET_ADDRESS")));
        bytes32 role          = vm.envBytes32("ROLE");
        address account       = vm.envAddress("ROLE_ACCOUNT");

        bool has = wallet.hasRole(role, account);
        console.log("Account:", account);
        console.log("Has role:", has);
        console.logBytes32(role);
    }
}

/**
 * @notice Print wallet role hashes for easy copy-paste into ROLE env var.
 */
contract PrintWalletRoles is Script {
    function run() external pure {
        console.log("DEFAULT_ADMIN_ROLE :");
        console.logBytes32(0x0000000000000000000000000000000000000000000000000000000000000000);
        console.log("WALLET_ADMIN_ROLE  :");
        console.logBytes32(keccak256("WALLET_ADMIN_ROLE"));
        console.log("SWEEPER_ROLE       :");
        console.logBytes32(keccak256("SWEEPER_ROLE"));
        console.log("EXECUTOR_ROLE      :");
        console.logBytes32(keccak256("EXECUTOR_ROLE"));
        console.log("PAUSER_ROLE        :");
        console.logBytes32(keccak256("PAUSER_ROLE"));
    }
}
