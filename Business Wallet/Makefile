-include .env
export

# ── Network selection ──────────────────────────────────────────────────────
# Override with: make <target> NETWORK=sepolia
NETWORK ?= local
CHAIN_ID := $(or $(CHAIN_ID),            $(error CHAIN_ID not set))

ETHERSCAN_API_KEY = ""

# ── Required addresses ─────────────────────────────────────────────────────
ADMIN_ADDRESS    := $(or $(ADMIN_ADDRESS),    $(error ADMIN_ADDRESS not set))
FACTORY_ADDRESS  := $(or $(FACTORY_ADDRESS),  $(error FACTORY_ADDRESS not set))

# ── Beacon addresses (set after deploy-factory) ───────────────────────────
# Output by deploy-factory. Used for upgrade-beacon and verify-* targets.
BEACON_IDENTITY_REGISTRY  := $(or $(BEACON_IDENTITY_REGISTRY),  $(error BEACON_IDENTITY_REGISTRY not set))
BEACON_COMPLIANCE_MODULE  := $(or $(BEACON_COMPLIANCE_MODULE),  $(error BEACON_COMPLIANCE_MODULE not set))
BEACON_SECURITY_TOKEN     := $(or $(BEACON_SECURITY_TOKEN),     $(error BEACON_SECURITY_TOKEN not set))
BEACON_YIELD_DISTRIBUTOR  := $(or $(BEACON_YIELD_DISTRIBUTOR),  $(error BEACON_YIELD_DISTRIBUTOR not set))
BEACON_BOND_TERMS         := $(or $(BEACON_BOND_TERMS),         $(error BEACON_BOND_TERMS not set))

# ── Implementation addresses (set after deploy-factory) ───────────────────
# Each beacon.implementation() returns one of these. Used for verify-* only.
IMPL_IDENTITY_REGISTRY   := $(or $(IMPL_IDENTITY_REGISTRY),   $(error IMPL_IDENTITY_REGISTRY not set))
IMPL_COMPLIANCE_MODULE   := $(or $(IMPL_COMPLIANCE_MODULE),   $(error IMPL_COMPLIANCE_MODULE not set))
IMPL_SECURITY_TOKEN      := $(or $(IMPL_SECURITY_TOKEN),      $(error IMPL_SECURITY_TOKEN not set))
IMPL_YIELD_DISTRIBUTOR   := $(or $(IMPL_YIELD_DISTRIBUTOR),   $(error IMPL_YIELD_DISTRIBUTOR not set))
IMPL_BOND_TERMS          := $(or $(IMPL_BOND_TERMS),          $(error IMPL_BOND_TERMS not set))

FORWARDER_ADDRESS := $(or $(FORWARDER_ADDRESS), $(error FORWARDER_ADDRESS not set))

ifeq ($(NETWORK),sepolia)
  RPC := $(SEPOLIA_RPC_URL)
else ifeq ($(NETWORK),mainnet)
  RPC := $(MAINNET_RPC_URL)
else ifeq ($(NETWORK),polygon)
  RPC := $(POLYGON_RPC_URL)
else ifeq ($(NETWORK),base)
  RPC := $(BASE_RPC_URL)
else ifeq ($(NETWORK),base-sepolia)
  RPC := $(BASE_SEPOLIA_RPC_URL)
else ifeq ($(NETWORK),arbitrum)
  RPC := $(ARBITRUM_RPC_URL)
else
  RPC := http://localhost:8545
endif

ACCOUNT=deployer

.PHONY: \
	build clean test fmt \
	anvil \
	deploy-factory deploy-bond deploy-token deploy-security-token deploy-yield-token \
	upgrade-beacon deploy-and-upgrade-beacon \
	ir-register ir-delete ir-update-country ir-update-identity ir-set-verified ir-is-verified \
	comp-set-max-shareholders comp-set-max-tokens comp-set-lockup \
	comp-block-country comp-unblock-country comp-can-transfer \
	token-mint token-burn token-transfer token-forced-transfer token-recover \
	token-freeze token-freeze-partial token-unfreeze-partial \
	token-pause token-unpause token-set-registry token-set-compliance \
	token-batch-mint token-balance \
	yield-snapshot yield-claim yield-push yield-reclaim yield-pending yield-get-snapshot \
	factory-get-deployment factory-get-by-index factory-total-deployments \
	factory-pause factory-unpause factory-grant-deployer factory-revoke-deployer \
	factory-transfer-ownership factory-grant-admin factory-renounce-admin \
	verify-factory \
	verify-identity-registry verify-compliance-module verify-security-token \
	verify-yield-distributor verify-bond-terms verify-forwarder verify-all \
	help

## ─── Build ───────────────────────────────────────────────────────────────────

build: ## forge build
	forge build

clean: ## forge clean
	forge clean

test: ## forge test -vvv
	forge test -vvv

fmt: ## forge fmt
	forge fmt

## ─── Local node ──────────────────────────────────────────────────────────────

anvil: ## start local anvil node
	anvil

## ─── Deploy ──────────────────────────────────────────────────────────────────

deploy-factory: ## deploy impls → beacons → forwarder → TokenizationFactory
	forge script script/Deploy.s.sol:DeployFactory \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		--slow \
		-vvvv

deploy-bond: ## deploy a bond suite via factory (ISSUER_ID, ANNUAL_RATE_BPS, MATURITY_DATE, etc.)
	forge script script/Deploy.s.sol:DeployBond \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		-vvvv

deploy-token: ## deploy a token suite via factory (TOKEN_TYPE, ISSUER_ID, etc.)
	forge script script/DeployToken.s.sol:DeployToken \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		-vvvv

deploy-security-token: ## shortcut: deploy a SECURITY token suite
	TOKEN_TYPE=SECURITY $(MAKE) deploy-token

deploy-yield-token: ## shortcut: deploy a YIELD_BEARING token suite
	TOKEN_TYPE=YIELD_BEARING $(MAKE) deploy-token

## ─── Upgrade ─────────────────────────────────────────────────────────────────

upgrade-beacon: ## point a beacon at a new already-deployed impl (BEACON_ADDRESS, NEW_IMPL_ADDRESS)
	forge script script/Upgrade.s.sol:UpgradeBeacon \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		-vvvv

deploy-and-upgrade-beacon: ## deploy new impl + upgrade beacon atomically (BEACON_ADDRESS, CONTRACT_TYPE)
	forge script script/Upgrade.s.sol:DeployAndUpgradeBeacon \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		-vvvv

## ─── Verify ──────────────────────────────────────────────────────────────────

VERIFY_FLAGS = \
	--verifier etherscan \
	--verifier-url https://api.etherscan.io/v2/api?chainid=84532 \
	--etherscan-api-key $(ETHERSCAN_API_KEY) \
	--chain-id 84532 \
	-vvvv

verify-factory: ## verify TokenizationFactory on Base Sepolia
	forge verify-contract $(FACTORY_ADDRESS) \
		src/TokenizationFactory.sol:TokenizationFactory \
		--constructor-args $$(cast abi-encode \
			"constructor(address,address,address,address,address,address,address)" \
			$(ADMIN_ADDRESS) \
			$(BEACON_IDENTITY_REGISTRY) \
			$(BEACON_COMPLIANCE_MODULE) \
			$(BEACON_SECURITY_TOKEN) \
			$(BEACON_YIELD_DISTRIBUTOR) \
			$(BEACON_BOND_TERMS) \
			$(FORWARDER_ADDRESS)) \
		$(VERIFY_FLAGS)

verify-identity-registry: ## verify IdentityRegistry implementation on Base Sepolia
	forge verify-contract $(IMPL_IDENTITY_REGISTRY) \
		src/IdentityRegistry.sol:IdentityRegistry \
		$(VERIFY_FLAGS)

verify-compliance-module: ## verify ComplianceModule implementation on Base Sepolia
	forge verify-contract $(IMPL_COMPLIANCE_MODULE) \
		src/ComplianceModule.sol:ComplianceModule \
		$(VERIFY_FLAGS)

verify-security-token: ## verify SecurityToken implementation on Base Sepolia
	forge verify-contract $(IMPL_SECURITY_TOKEN) \
		src/SecurityToken.sol:SecurityToken \
		$(VERIFY_FLAGS)

verify-yield-distributor: ## verify YieldDistributor implementation on Base Sepolia
	forge verify-contract $(IMPL_YIELD_DISTRIBUTOR) \
		src/YieldDistributor.sol:YieldDistributor \
		$(VERIFY_FLAGS)

verify-bond-terms: ## verify BondTerms implementation on Base Sepolia
	forge verify-contract $(IMPL_BOND_TERMS) \
		src/BondTerms.sol:BondTerms \
		$(VERIFY_FLAGS)

verify-forwarder: ## verify TokenxForwarder on Base Sepolia
	forge verify-contract $(FORWARDER_ADDRESS) \
		src/TokenxForwarder.sol:TokenxForwarder \
		--constructor-args $$(cast abi-encode "constructor(address)" $(ADMIN_ADDRESS)) \
		$(VERIFY_FLAGS)

verify-all: ## verify all contracts on Base Sepolia
	$(MAKE) verify-identity-registry
	$(MAKE) verify-compliance-module
	$(MAKE) verify-security-token
	$(MAKE) verify-yield-distributor
	$(MAKE) verify-bond-terms
	$(MAKE) verify-forwarder
	$(MAKE) verify-factory

## ─── Identity Registry ───────────────────────────────────────────────────────

ir-register: ## register identity (WALLET, ONCHAIN_ID, COUNTRY)
	forge script script/interactions/Registry.s.sol:RegisterIdentity \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

ir-delete: ## delete identity (WALLET)
	forge script script/interactions/Registry.s.sol:DeleteIdentity \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

ir-update-country: ## update country (WALLET, COUNTRY)
	forge script script/interactions/Registry.s.sol:UpdateCountry \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

ir-update-identity: ## update onchain ID (WALLET, NEW_ONCHAIN_ID)
	forge script script/interactions/Registry.s.sol:UpdateIdentity \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

ir-set-verified: ## set verified flag (WALLET, VERIFIED)
	forge script script/interactions/Registry.s.sol:SetVerified \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

ir-is-verified: ## check if verified (WALLET) [read-only]
	forge script script/interactions/Registry.s.sol:IsVerified \
		--rpc-url $(RPC) -vvvv

## ─── Compliance ──────────────────────────────────────────────────────────────

comp-set-max-shareholders: ## set max shareholders
	forge script script/interactions/Compliance.s.sol:SetMaxShareholders \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

comp-set-max-tokens: ## set max tokens per investor
	forge script script/interactions/Compliance.s.sol:SetMaxTokensPerInvestor \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

comp-set-lockup: ## set lock-up duration
	forge script script/interactions/Compliance.s.sol:SetLockUpDuration \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

comp-block-country: ## block country (COUNTRY)
	forge script script/interactions/Compliance.s.sol:BlockCountry \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

comp-unblock-country: ## unblock country (COUNTRY)
	forge script script/interactions/Compliance.s.sol:UnblockCountry \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

comp-can-transfer: ## check canTransfer (FROM, TO, AMOUNT) [read-only]
	forge script script/interactions/Compliance.s.sol:CanTransfer \
		--rpc-url $(RPC) -vvvv

## ─── Token ───────────────────────────────────────────────────────────────────

token-mint: ## mint tokens (MINT_TO, AMOUNT)
	forge script script/interactions/Token.s.sol:MintTokens \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-burn: ## burn tokens (BURN_FROM, AMOUNT)
	forge script script/interactions/Token.s.sol:BurnTokens \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-transfer: ## transfer tokens (TO, AMOUNT)
	forge script script/interactions/Token.s.sol:TransferTokens \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-forced-transfer: ## forced transfer (FROM, TO, AMOUNT)
	forge script script/interactions/Token.s.sol:ForcedTransfer \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-recover: ## recover address (LOST_WALLET, NEW_WALLET, INVESTOR_ONCHAIN_ID)
	forge script script/interactions/Token.s.sol:RecoverAddress \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-freeze: ## freeze/unfreeze address (USER, FREEZE)
	forge script script/interactions/Token.s.sol:FreezeAddress \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-freeze-partial: ## freeze partial tokens (USER, AMOUNT)
	forge script script/interactions/Token.s.sol:FreezePartial \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-unfreeze-partial: ## unfreeze partial tokens (USER, AMOUNT)
	forge script script/interactions/Token.s.sol:UnfreezePartial \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-pause: ## pause token
	forge script script/interactions/Token.s.sol:PauseToken \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-unpause: ## unpause token
	forge script script/interactions/Token.s.sol:UnpauseToken \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-set-registry: ## set identity registry (NEW_REGISTRY)
	forge script script/interactions/Token.s.sol:SetIdentityRegistry \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-set-compliance: ## set compliance (NEW_COMPLIANCE)
	forge script script/interactions/Token.s.sol:SetCompliance \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-batch-mint: ## batch mint (RECIPIENTS, AMOUNTS)
	forge script script/interactions/Token.s.sol:BatchMint \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

token-balance: ## get balance (WALLET) [read-only]
	forge script script/interactions/Token.s.sol:GetBalance \
		--rpc-url $(RPC) -vvvv

## ─── Yield Distributor ───────────────────────────────────────────────────────

yield-snapshot: ## create snapshot + deposit (INVESTORS, PAYOUT_TOKEN, FUND_AMOUNT, RECLAIM_AFTER, DESCRIPTION)
	forge script script/interactions/Yield.s.sol:CreateSnapshot \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

yield-claim: ## claim yield (SNAPSHOT_ID)
	forge script script/interactions/Yield.s.sol:ClaimYield \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

yield-push: ## push yield to investors (SNAPSHOT_ID, INVESTORS)
	forge script script/interactions/Yield.s.sol:PushYield \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

yield-reclaim: ## reclaim unclaimed (SNAPSHOT_ID)
	forge script script/interactions/Yield.s.sol:ReclaimUnclaimed \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

yield-pending: ## check pending yield (SNAPSHOT_ID, INVESTOR) [read-only]
	forge script script/interactions/Yield.s.sol:PendingYield \
		--rpc-url $(RPC) -vvvv

yield-get-snapshot: ## get snapshot details (SNAPSHOT_ID) [read-only]
	forge script script/interactions/Yield.s.sol:GetSnapshot \
		--rpc-url $(RPC) -vvvv

## ─── Factory ─────────────────────────────────────────────────────────────────

factory-get-deployment: ## get deployment by issuerId (ISSUER_ID) [read-only]
	forge script script/interactions/Factory.s.sol:GetDeployment \
		--rpc-url $(RPC) -vvvv

factory-get-by-index: ## get deployment by index (INDEX) [read-only]
	forge script script/interactions/Factory.s.sol:GetDeploymentByIndex \
		--rpc-url $(RPC) -vvvv

factory-total-deployments: ## get total deployments [read-only]
	forge script script/interactions/Factory.s.sol:TotalDeployments \
		--rpc-url $(RPC) -vvvv

factory-pause: ## pause factory
	forge script script/interactions/Factory.s.sol:PauseFactory \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

factory-unpause: ## unpause factory
	forge script script/interactions/Factory.s.sol:UnpauseFactory \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

factory-grant-deployer: ## grant deployer role (NEW_ADMIN_ADDRESS)
	forge script script/interactions/Factory.s.sol:GrantDeployerRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

factory-revoke-deployer: ## revoke deployer role (ACCOUNT)
	forge script script/interactions/Factory.s.sol:RevokeDeployerRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

factory-transfer-ownership: ## transfer all factory roles to new admin (NEW_ADMIN_ADDRESS)
	forge script script/interactions/Factory.s.sol:TransferOwnership \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		--slow \
		-vvvv

factory-grant-admin: ## grant DEFAULT_ADMIN_ROLE without revoking caller (NEW_ADMIN_ADDRESS, step 1 of 2)
	forge script script/interactions/Factory.s.sol:GrantAdminRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

factory-renounce-admin: ## renounce caller's DEFAULT_ADMIN_ROLE + all roles (step 2 of 2)
	forge script script/interactions/Factory.s.sol:RenounceAdminRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

## ─── Forwarder ──────────────────────────────────────────────────────────────

forwarder-grant-relayer: ## grant RELAYER_ROLE to address (RELAYER_ADDRESS)
	forge script script/interactions/Forwarder.s.sol:GrantRelayerRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

forwarder-revoke-relayer: ## revoke RELAYER_ROLE from address (RELAYER_ADDRESS)
	forge script script/interactions/Forwarder.s.sol:RevokeRelayerRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

forwarder-transfer-ownership: ## transfer all forwarder roles to new admin (NEW_ADMIN_ADDRESS)
	forge script script/interactions/Forwarder.s.sol:TransferOwnership \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		--slow \
		-vvvv

forwarder-grant-admin: ## grant DEFAULT_ADMIN_ROLE without revoking caller (NEW_ADMIN_ADDRESS, step 1 of 2)
	forge script script/interactions/Forwarder.s.sol:GrantAdminRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

forwarder-renounce-admin: ## renounce caller's DEFAULT_ADMIN_ROLE + RELAYER_ROLE (step 2 of 2)
	forge script script/interactions/Forwarder.s.sol:RenounceAdminRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

forwarder-pause: ## pause forwarder
	forge script script/interactions/Forwarder.s.sol:PauseForwarder \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

forwarder-unpause: ## unpause forwarder
	forge script script/interactions/Forwarder.s.sol:UnpauseForwarder \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

## ─── Help ────────────────────────────────────────────────────────────────────

help: ## print this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m [NETWORK=local|sepolia|mainnet|polygon|base|arbitrum]\n"} \
	/^[a-zA-Z_0-9-]+:.*##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } \
	/^## ─/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 4) }' $(MAKEFILE_LIST)
