// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/BusinessWallet.sol";
import "../src/WalletFactory.sol";

/**
 * @notice Deploy the WalletFactory + BusinessWallet beacon.
 *
 *   Deployment order
 *   ────────────────
 *   1. Deploy BusinessWallet implementation (logic contract — not used directly).
 *   2. Deploy WalletFactory:
 *        • internally creates an UpgradeableBeacon pointing to the impl
 *        • transfers beacon ownership to ADMIN_ADDRESS
 *        • sets POOL_WALLET as the fund destination for all wallets
 *        • wires in FORWARDER_ADDRESS for EIP-2771 meta-transactions
 *
 *   To upgrade all wallets later:
 *     1. Deploy a new BusinessWallet implementation.
 *     2. Call UpgradeableBeacon(factory.walletBeacon()).upgradeTo(newImpl)
 *        from ADMIN_ADDRESS.  Every wallet proxy instantly delegates to the
 *        new logic.
 *
 *   Required env vars
 *   ─────────────────
 *     ADMIN_ADDRESS      — granted all platform roles and beacon ownership
 *     POOL_WALLET        — destination for all forwarded / swept funds
 *     FORWARDER_ADDRESS  — EIP-2771 forwarder (use address(0) to disable)
 */
contract DeployWalletFactory is Script {
    function run() external {
        address adminAddress  = vm.envAddress("ADMIN_ADDRESS");
        address poolWallet    = vm.envAddress("POOL_WALLET");
        address forwarder     = vm.envOr("FORWARDER_ADDRESS", address(0));

        vm.startBroadcast();

        // ── 1. Deploy BusinessWallet implementation ───────────────
        BusinessWallet impl = new BusinessWallet();
        console.log("BusinessWallet impl :", address(impl));

        // ── 2. Deploy WalletFactory ───────────────────────────────
        WalletFactory factory = new WalletFactory(
            adminAddress,
            address(impl),
            poolWallet,
            forwarder
        );
        console.log("WalletFactory       :", address(factory));
        console.log("Wallet beacon       :", factory.walletBeacon());
        console.log("Pool wallet         :", factory.poolWallet());

        vm.stopBroadcast();

        // ── Env snippet for .env / CI ─────────────────────────────
        console.log("\n# Add to .env:");
        console.log("WALLET_FACTORY=", address(factory));
        console.log("BEACON_BUSINESS_WALLET=", factory.walletBeacon());
    }
}
