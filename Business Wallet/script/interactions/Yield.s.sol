// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/YieldDistributor.sol";

// ── Internal string splitter helper ────────────────────────────────────────

library YieldStringUtils {
    function split(string memory str, bytes1 delimiter)
        internal
        pure
        returns (string[] memory parts)
    {
        bytes memory b = bytes(str);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == delimiter) count++;
        }
        parts = new string[](count);
        uint256 partIdx = 0;
        uint256 start   = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == delimiter) {
                parts[partIdx] = _slice(b, start, i);
                partIdx++;
                start = i + 1;
            }
        }
        parts[partIdx] = _slice(b, start, b.length);
    }

    function _slice(bytes memory b, uint256 from, uint256 to)
        private
        pure
        returns (string memory)
    {
        bytes memory res = new bytes(to - from);
        for (uint256 i = from; i < to; i++) {
            res[i - from] = b[i];
        }
        return string(res);
    }

    function parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        uint256 start = 0;
        if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            start = 2;
        }
        require(b.length - start == 40, "YieldStringUtils: bad address length");
        uint160 result = 0;
        for (uint256 i = start; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            uint8 nibble;
            if (c >= 48 && c <= 57) {
                nibble = c - 48;
            } else if (c >= 65 && c <= 70) {
                nibble = c - 55;
            } else if (c >= 97 && c <= 102) {
                nibble = c - 87;
            } else {
                revert("YieldStringUtils: bad hex char");
            }
            result = result * 16 + nibble;
        }
        return address(result);
    }
}

// ── CreateSnapshot ──────────────────────────────────────────────────────────

contract CreateSnapshot is Script {
    using YieldStringUtils for string;

    function run() external {
        uint256 privateKey             = vm.envUint("PRIVATE_KEY");
        address yieldDistributorAddress = vm.envAddress("YIELD_DISTRIBUTOR_ADDRESS");
        string  memory investorsRaw    = vm.envString("INVESTORS");
        address payoutToken            = vm.envOr("PAYOUT_TOKEN", address(0));
        uint256 fundAmount             = vm.envUint("FUND_AMOUNT");
        uint256 reclaimAfter           = vm.envOr("RECLAIM_AFTER", uint256(2592000)); // 30 days default
        string  memory description     = vm.envOr("DESCRIPTION", string("Yield Distribution"));

        // Parse investor addresses
        string[] memory investorParts = investorsRaw.split(",");
        address[] memory investors = new address[](investorParts.length);
        for (uint256 i = 0; i < investorParts.length; i++) {
            investors[i] = YieldStringUtils.parseAddress(investorParts[i]);
        }

        YieldDistributor distributor = YieldDistributor(payable(yieldDistributorAddress));

        vm.startBroadcast(privateKey);

        uint256 snapshotId;
        if (payoutToken == address(0)) {
            // ETH payout — send msg.value
            snapshotId = distributor.createSnapshot{value: fundAmount}(
                investors,
                payoutToken,
                fundAmount,
                reclaimAfter,
                description
            );
        } else {
            // ERC-20 payout — caller must have approved distributor for fundAmount
            snapshotId = distributor.createSnapshot(
                investors,
                payoutToken,
                fundAmount,
                reclaimAfter,
                description
            );
        }

        vm.stopBroadcast();

        console.log("Snapshot created:");
        console.log("  Snapshot ID     :", snapshotId);
        console.log("  Investors       :", investors.length);
        console.log("  Payout token    :", payoutToken);
        console.log("  Fund amount     :", fundAmount);
        console.log("  Reclaim after   :", reclaimAfter, "seconds");
        console.log("  Description     :", description);
    }
}

// ── ClaimYield ──────────────────────────────────────────────────────────────

contract ClaimYield is Script {
    function run() external {
        uint256 privateKey              = vm.envUint("PRIVATE_KEY");
        address yieldDistributorAddress = vm.envAddress("YIELD_DISTRIBUTOR_ADDRESS");
        uint256 snapshotId              = vm.envUint("SNAPSHOT_ID");

        YieldDistributor distributor = YieldDistributor(payable(yieldDistributorAddress));

        vm.startBroadcast(privateKey);
        distributor.claimYield(snapshotId);
        vm.stopBroadcast();

        console.log("Yield claimed for snapshot ID:", snapshotId);
    }
}

// ── PushYield ───────────────────────────────────────────────────────────────

contract PushYield is Script {
    using YieldStringUtils for string;

    function run() external {
        uint256 privateKey              = vm.envUint("PRIVATE_KEY");
        address yieldDistributorAddress = vm.envAddress("YIELD_DISTRIBUTOR_ADDRESS");
        uint256 snapshotId              = vm.envUint("SNAPSHOT_ID");
        string  memory investorsRaw     = vm.envString("INVESTORS");

        string[] memory investorParts = investorsRaw.split(",");
        address[] memory investors = new address[](investorParts.length);
        for (uint256 i = 0; i < investorParts.length; i++) {
            investors[i] = YieldStringUtils.parseAddress(investorParts[i]);
        }

        YieldDistributor distributor = YieldDistributor(payable(yieldDistributorAddress));

        vm.startBroadcast(privateKey);
        distributor.pushYield(snapshotId, investors);
        vm.stopBroadcast();

        console.log("Yield pushed:");
        console.log("  Snapshot ID :", snapshotId);
        console.log("  Investors   :", investors.length);
    }
}

// ── ReclaimUnclaimed ────────────────────────────────────────────────────────

contract ReclaimUnclaimed is Script {
    function run() external {
        uint256 privateKey              = vm.envUint("PRIVATE_KEY");
        address yieldDistributorAddress = vm.envAddress("YIELD_DISTRIBUTOR_ADDRESS");
        uint256 snapshotId              = vm.envUint("SNAPSHOT_ID");

        YieldDistributor distributor = YieldDistributor(payable(yieldDistributorAddress));

        vm.startBroadcast(privateKey);
        distributor.reclaimUnclaimed(snapshotId);
        vm.stopBroadcast();

        console.log("Unclaimed yield reclaimed for snapshot ID:", snapshotId);
    }
}

// ── PendingYield (read-only) ────────────────────────────────────────────────

contract PendingYield is Script {
    function run() external view {
        address yieldDistributorAddress = vm.envAddress("YIELD_DISTRIBUTOR_ADDRESS");
        uint256 snapshotId              = vm.envUint("SNAPSHOT_ID");
        address investor                = vm.envAddress("INVESTOR");

        YieldDistributor distributor = YieldDistributor(payable(yieldDistributorAddress));
        uint256 amount = distributor.pendingYield(snapshotId, investor);

        console.log("Pending yield:");
        console.log("  Snapshot ID :", snapshotId);
        console.log("  Investor    :", investor);
        console.log("  Amount      :", amount);
    }
}

// ── GetSnapshot (read-only) ─────────────────────────────────────────────────

contract GetSnapshot is Script {
    function run() external view {
        address yieldDistributorAddress = vm.envAddress("YIELD_DISTRIBUTOR_ADDRESS");
        uint256 snapshotId              = vm.envUint("SNAPSHOT_ID");

        YieldDistributor distributor = YieldDistributor(payable(yieldDistributorAddress));
        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(snapshotId);

        console.log("Snapshot details:");
        console.log("  ID                    :", snap.id);
        console.log("  Block number          :", snap.blockNumber);
        console.log("  Timestamp             :", snap.timestamp);
        console.log("  Total eligible supply :", snap.totalEligibleSupply);
        console.log("  Total funds           :", snap.totalFunds);
        console.log("  Payout token          :", snap.payoutToken);
        console.log("  Reclaim deadline      :", snap.reclaimDeadline);
        console.log("  Active                :", snap.active);
        console.log("  Description           :", snap.description);
    }
}
