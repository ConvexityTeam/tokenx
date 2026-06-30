// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/ComplianceModule.sol";

// ── SetMaxShareholders ──────────────────────────────────────────────────────

contract SetMaxShareholders is Script {
    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address complianceAddress = vm.envAddress("COMPLIANCE_ADDRESS");
        uint256 maxShareholders   = vm.envUint("MAX_SHAREHOLDERS");

        ComplianceModule compliance = ComplianceModule(complianceAddress);

        vm.startBroadcast(privateKey);
        compliance.setMaxShareholders(maxShareholders);
        vm.stopBroadcast();

        console.log("Max shareholders set to:", maxShareholders);
    }
}

// ── SetMaxTokensPerInvestor ─────────────────────────────────────────────────

contract SetMaxTokensPerInvestor is Script {
    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address complianceAddress = vm.envAddress("COMPLIANCE_ADDRESS");
        uint256 maxTokens         = vm.envUint("MAX_TOKENS");

        ComplianceModule compliance = ComplianceModule(complianceAddress);

        vm.startBroadcast(privateKey);
        compliance.setMaxTokensPerInvestor(maxTokens);
        vm.stopBroadcast();

        console.log("Max tokens per investor set to:", maxTokens);
    }
}

// ── SetLockUpDuration ───────────────────────────────────────────────────────

contract SetLockUpDuration is Script {
    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address complianceAddress = vm.envAddress("COMPLIANCE_ADDRESS");
        uint256 lockupDuration    = vm.envUint("LOCKUP_DURATION");

        ComplianceModule compliance = ComplianceModule(complianceAddress);

        vm.startBroadcast(privateKey);
        compliance.setLockUpDuration(lockupDuration);
        vm.stopBroadcast();

        console.log("Lock-up duration set to:", lockupDuration, "seconds");
    }
}

// ── BlockCountry ────────────────────────────────────────────────────────────

contract BlockCountry is Script {
    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address complianceAddress = vm.envAddress("COMPLIANCE_ADDRESS");
        uint16  country           = uint16(vm.envUint("COUNTRY"));

        ComplianceModule compliance = ComplianceModule(complianceAddress);

        vm.startBroadcast(privateKey);
        compliance.blockCountry(country);
        vm.stopBroadcast();

        console.log("Country blocked:", country);
    }
}

// ── UnblockCountry ──────────────────────────────────────────────────────────

contract UnblockCountry is Script {
    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address complianceAddress = vm.envAddress("COMPLIANCE_ADDRESS");
        uint16  country           = uint16(vm.envUint("COUNTRY"));

        ComplianceModule compliance = ComplianceModule(complianceAddress);

        vm.startBroadcast(privateKey);
        compliance.unblockCountry(country);
        vm.stopBroadcast();

        console.log("Country unblocked:", country);
    }
}

// ── CanTransfer (read-only) ─────────────────────────────────────────────────

contract CanTransfer is Script {
    function run() external view {
        address complianceAddress = vm.envAddress("COMPLIANCE_ADDRESS");
        address from              = vm.envAddress("FROM");
        address to                = vm.envAddress("TO");
        uint256 amount            = vm.envUint("AMOUNT");

        ComplianceModule compliance = ComplianceModule(complianceAddress);
        bool result = compliance.canTransfer(from, to, amount);

        console.log("canTransfer check:");
        console.log("  From   :", from);
        console.log("  To     :", to);
        console.log("  Amount :", amount);
        console.log("  Result :", result);
    }
}
