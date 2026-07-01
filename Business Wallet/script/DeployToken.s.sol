// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/TokenizationFactory.sol";

contract DeployToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddress     = vm.envAddress("FACTORY_ADDRESS");

        // Token type — default to SECURITY
        string memory tokenTypeStr = vm.envOr("TOKEN_TYPE", string("SECURITY"));
        TokenizationFactory.TokenType tokenType;
        if (keccak256(bytes(tokenTypeStr)) == keccak256(bytes("YIELD_BEARING"))) {
            tokenType = TokenizationFactory.TokenType.YIELD_BEARING;
        } else {
            tokenType = TokenizationFactory.TokenType.SECURITY;
        }

        string  memory issuerId             = vm.envString("ISSUER_ID");
        string  memory tokenName            = vm.envString("TOKEN_NAME");
        string  memory tokenSymbol          = vm.envString("TOKEN_SYMBOL");
        address        issuerOnchainID      = vm.envOr("ISSUER_ONCHAIN_ID", address(0));
        address        tokenAdmin           = vm.envAddress("TOKEN_ADMIN");
        uint256        maxShareholders      = vm.envOr("MAX_SHAREHOLDERS",       uint256(0));
        uint256        maxTokensPerInvestor = vm.envOr("MAX_TOKENS_PER_INVESTOR", uint256(0));
        uint256        lockupDuration       = vm.envOr("LOCKUP_DURATION",        uint256(0));

        TokenizationFactory.ComplianceParams memory compParams = TokenizationFactory.ComplianceParams({
            maxShareholders:      maxShareholders,
            maxTokensPerInvestor: maxTokensPerInvestor,
            lockUpDuration:       lockupDuration
        });

        TokenizationFactory factory = TokenizationFactory(factoryAddress);

        vm.startBroadcast(deployerPrivateKey);

        address token = factory.deployToken(
            tokenType,
            issuerId,
            tokenName,
            tokenSymbol,
            issuerOnchainID,
            tokenAdmin,
            compParams
        );

        vm.stopBroadcast();

        // Fetch the deployment record to log all addresses
        TokenizationFactory.DeploymentRecord memory record = factory.getDeployment(issuerId);

        console.log("=== Token Suite Deployed ===");
        console.log("Token type          :", tokenTypeStr);
        console.log("Issuer ID           :", issuerId);
        console.log("Token name          :", tokenName);
        console.log("Token symbol        :", tokenSymbol);
        console.log("SecurityToken       :", token);
        console.log("IdentityRegistry    :", record.identityRegistry);
        console.log("ComplianceModule    :", record.compliance);
        console.log("YieldDistributor    :", record.yieldDistributor);
        console.log("Token admin         :", tokenAdmin);
        console.log("Deployed by         :", record.deployedBy);
        console.log("Deployed at (block) :", record.deployedAt);
    }
}
