// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/SecurityToken.sol";

// ── Internal string splitter helper ────────────────────────────────────────

library StringUtils {
    /// @dev Split a string by a single-byte delimiter. Returns array of parts.
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

    /// @dev Parse a decimal string to uint256.
    function parseUint(string memory s) internal pure returns (uint256 result) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 digit = uint8(b[i]) - 48;
            require(digit <= 9, "StringUtils: invalid digit");
            result = result * 10 + digit;
        }
    }

    /// @dev Parse a hex address string (with or without 0x prefix) to address.
    function parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        uint256 start = 0;
        if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            start = 2;
        }
        require(b.length - start == 40, "StringUtils: bad address length");
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
                revert("StringUtils: bad hex char");
            }
            result = result * 16 + nibble;
        }
        return address(result);
    }
}

// ── MintTokens ──────────────────────────────────────────────────────────────

contract MintTokens is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address mintTo       = vm.envAddress("MINT_TO");
        uint256 amount       = vm.envUint("AMOUNT");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.mint(mintTo, amount);
        vm.stopBroadcast();

        console.log("Minted", amount, "tokens to", mintTo);
    }
}

// ── BurnTokens ──────────────────────────────────────────────────────────────

contract BurnTokens is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address burnFrom     = vm.envAddress("BURN_FROM");
        uint256 amount       = vm.envUint("AMOUNT");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.burn(burnFrom, amount);
        vm.stopBroadcast();

        console.log("Burned", amount, "tokens from", burnFrom);
    }
}

// ── TransferTokens ──────────────────────────────────────────────────────────

contract TransferTokens is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address to           = vm.envAddress("TO");
        uint256 amount       = vm.envUint("AMOUNT");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.transfer(to, amount);
        vm.stopBroadcast();

        console.log("Transferred", amount, "tokens to", to);
    }
}

// ── ForcedTransfer ──────────────────────────────────────────────────────────

contract ForcedTransfer is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address from         = vm.envAddress("FROM");
        address to           = vm.envAddress("TO");
        uint256 amount       = vm.envUint("AMOUNT");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        bool success = token.forcedTransfer(from, to, amount);
        vm.stopBroadcast();

        console.log("Forced transfer:");
        console.log("  From    :", from);
        console.log("  To      :", to);
        console.log("  Amount  :", amount);
        console.log("  Success :", success);
    }
}

// ── RecoverAddress ──────────────────────────────────────────────────────────

contract RecoverAddress is Script {
    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address tokenAddress      = vm.envAddress("TOKEN_ADDRESS");
        address lostWallet        = vm.envAddress("LOST_WALLET");
        address newWallet         = vm.envAddress("NEW_WALLET");
        address investorOnchainId = vm.envAddress("INVESTOR_ONCHAIN_ID");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        bool success = token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
        vm.stopBroadcast();

        console.log("Address recovery:");
        console.log("  Lost wallet         :", lostWallet);
        console.log("  New wallet          :", newWallet);
        console.log("  Investor OnchainID  :", investorOnchainId);
        console.log("  Success             :", success);
    }
}

// ── FreezeAddress ───────────────────────────────────────────────────────────

contract FreezeAddress is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address user         = vm.envAddress("USER");
        bool    freeze       = vm.envBool("FREEZE");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.setAddressFrozen(user, freeze);
        vm.stopBroadcast();

        console.log("Address freeze set:");
        console.log("  User   :", user);
        console.log("  Frozen :", freeze);
    }
}

// ── FreezePartial ───────────────────────────────────────────────────────────

contract FreezePartial is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address user         = vm.envAddress("USER");
        uint256 amount       = vm.envUint("AMOUNT");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.freezePartialTokens(user, amount);
        vm.stopBroadcast();

        console.log("Partial tokens frozen:");
        console.log("  User   :", user);
        console.log("  Amount :", amount);
    }
}

// ── UnfreezePartial ─────────────────────────────────────────────────────────

contract UnfreezePartial is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address user         = vm.envAddress("USER");
        uint256 amount       = vm.envUint("AMOUNT");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.unfreezePartialTokens(user, amount);
        vm.stopBroadcast();

        console.log("Partial tokens unfrozen:");
        console.log("  User   :", user);
        console.log("  Amount :", amount);
    }
}

// ── PauseToken ──────────────────────────────────────────────────────────────

contract PauseToken is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.pause();
        vm.stopBroadcast();

        console.log("Token paused:", tokenAddress);
    }
}

// ── UnpauseToken ────────────────────────────────────────────────────────────

contract UnpauseToken is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.unpause();
        vm.stopBroadcast();

        console.log("Token unpaused:", tokenAddress);
    }
}

// ── SetIdentityRegistry ─────────────────────────────────────────────────────

contract SetIdentityRegistry is Script {
    function run() external {
        uint256 privateKey   = vm.envUint("PRIVATE_KEY");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address newRegistry  = vm.envAddress("NEW_REGISTRY");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.setIdentityRegistry(newRegistry);
        vm.stopBroadcast();

        console.log("Identity registry updated to:", newRegistry);
    }
}

// ── SetCompliance ───────────────────────────────────────────────────────────

contract SetCompliance is Script {
    function run() external {
        uint256 privateKey     = vm.envUint("PRIVATE_KEY");
        address tokenAddress   = vm.envAddress("TOKEN_ADDRESS");
        address newCompliance  = vm.envAddress("NEW_COMPLIANCE");

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.setCompliance(newCompliance);
        vm.stopBroadcast();

        console.log("Compliance updated to:", newCompliance);
    }
}

// ── BatchMint ───────────────────────────────────────────────────────────────

contract BatchMint is Script {
    using StringUtils for string;

    function run() external {
        uint256 privateKey        = vm.envUint("PRIVATE_KEY");
        address tokenAddress      = vm.envAddress("TOKEN_ADDRESS");
        string  memory recipientsRaw = vm.envString("RECIPIENTS");
        string  memory amountsRaw    = vm.envString("AMOUNTS");

        string[] memory recipientParts = recipientsRaw.split(",");
        string[] memory amountParts    = amountsRaw.split(",");
        require(recipientParts.length == amountParts.length, "BatchMint: length mismatch");

        address[] memory recipients = new address[](recipientParts.length);
        uint256[] memory amounts    = new uint256[](amountParts.length);

        for (uint256 i = 0; i < recipientParts.length; i++) {
            recipients[i] = StringUtils.parseAddress(recipientParts[i]);
            amounts[i]    = StringUtils.parseUint(amountParts[i]);
        }

        SecurityToken token = SecurityToken(payable(tokenAddress));

        vm.startBroadcast(privateKey);
        token.batchMint(recipients, amounts);
        vm.stopBroadcast();

        console.log("Batch mint complete. Recipients:", recipientParts.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            console.log("  ->", recipients[i], ":", amounts[i]);
        }
    }
}

// ── GetBalance (read-only) ──────────────────────────────────────────────────

contract GetBalance is Script {
    function run() external view {
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address wallet       = vm.envAddress("WALLET");

        SecurityToken token = SecurityToken(payable(tokenAddress));
        uint256 balance = token.balanceOf(wallet);

        console.log("Balance of", wallet, ":", balance);
    }
}
