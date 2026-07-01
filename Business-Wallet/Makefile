-include .env
export

# ── Network selection ──────────────────────────────────────────────────────
# Override with: make <target> NETWORK=base-sepolia
NETWORK ?= local
CHAIN_ID := $(or $(CHAIN_ID), $(error CHAIN_ID not set))

ETHERSCAN_API_KEY = ""

# ── Required addresses ─────────────────────────────────────────────────────
ADMIN_ADDRESS   := $(or $(ADMIN_ADDRESS),   $(error ADMIN_ADDRESS not set))
FACTORY_ADDRESS := $(or $(FACTORY_ADDRESS), $(error FACTORY_ADDRESS not set))

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

ACCOUNT = deployer

.PHONY: \
	build clean test fmt anvil \
	deploy-factory \
	verify-factory \
	bw-create-wallet bw-create-wallet-det bw-predict-address \
	bw-sweep-eth-factory bw-sweep-tokens-factory \
	bw-set-factory-pool bw-deactivate-wallet \
	bw-grant-factory-role bw-revoke-factory-role \
	bw-pause-factory bw-unpause-factory \
	bw-get-wallet bw-wallet-of bw-total-wallets bw-list-wallets bw-factory-roles \
	bw-notify bw-sweep-token bw-batch-sweep bw-sweep-eth \
	bw-execute bw-set-pool \
	bw-pause-wallet bw-unpause-wallet \
	bw-grant-role bw-revoke-role \
	bw-info bw-check-role bw-wallet-roles \
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

deploy-factory: ## deploy BusinessWallet impl + WalletFactory beacon
	forge script script/DeployWalletFactory.s.sol:DeployWalletFactory \
		--rpc-url $(RPC) \
		--broadcast \
		--account $(ACCOUNT) \
		--slow \
		-vvvv

## ─── Verify ──────────────────────────────────────────────────────────────────

VERIFY_FLAGS = \
	--verifier etherscan \
	--verifier-url https://api.etherscan.io/v2/api?chainid=84532 \
	--etherscan-api-key $(ETHERSCAN_API_KEY) \
	--chain-id 84532 \
	-vvvv

verify-factory: ## verify WalletFactory on Base Sepolia
	forge verify-contract $(FACTORY_ADDRESS) \
		src/WalletFactory.sol:WalletFactory \
		--constructor-args $$(cast abi-encode \
			"constructor(address,address,address,address)" \
			$(ADMIN_ADDRESS) \
			$(BUSINESS_WALLET_IMPL) \
			$(POOL_WALLET) \
			$(FORWARDER_ADDRESS)) \
		$(VERIFY_FLAGS)

## ─── Business Wallet — Factory ───────────────────────────────────────────────

bw-create-wallet: ## create a standard BusinessWallet (BUSINESS_ID, WALLET_ADMIN)
	forge script script/interactions/Factory.s.sol:CreateWallet \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-create-wallet-det: ## create a deterministic (CREATE2) BusinessWallet (BUSINESS_ID, WALLET_ADMIN, SALT)
	forge script script/interactions/Factory.s.sol:CreateWalletDeterministic \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-predict-address: ## predict CREATE2 wallet address without deploying (BUSINESS_ID, WALLET_ADMIN, SALT) [read-only]
	forge script script/interactions/Factory.s.sol:PredictWalletAddress \
		--rpc-url $(RPC) -vvvv

bw-sweep-eth-factory: ## sweep residual ETH from a wallet via factory (BUSINESS_ID)
	forge script script/interactions/Factory.s.sol:SweepWalletETH \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-sweep-tokens-factory: ## sweep ERC-20 tokens from a wallet via factory (BUSINESS_ID, TOKEN_ADDRESSES)
	forge script script/interactions/Factory.s.sol:SweepWalletTokens \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-set-factory-pool: ## update pool wallet on factory for future deployments (NEW_POOL)
	forge script script/interactions/Factory.s.sol:SetFactoryPoolWallet \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-deactivate-wallet: ## deactivate a wallet record in the factory registry (BUSINESS_ID)
	forge script script/interactions/Factory.s.sol:DeactivateWallet \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-grant-factory-role: ## grant a factory role (ROLE, ROLE_ACCOUNT)
	forge script script/interactions/Factory.s.sol:GrantFactoryRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-revoke-factory-role: ## revoke a factory role (ROLE, ROLE_ACCOUNT)
	forge script script/interactions/Factory.s.sol:RevokeFactoryRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-pause-factory: ## pause the factory
	forge script script/interactions/Factory.s.sol:PauseFactory \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-unpause-factory: ## unpause the factory
	forge script script/interactions/Factory.s.sol:UnpauseFactory \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-get-wallet: ## get wallet record by businessId (BUSINESS_ID) [read-only]
	forge script script/interactions/Factory.s.sol:GetWallet \
		--rpc-url $(RPC) -vvvv

bw-wallet-of: ## get wallet address for a business (BUSINESS_ID) [read-only]
	forge script script/interactions/Factory.s.sol:WalletOf \
		--rpc-url $(RPC) -vvvv

bw-total-wallets: ## print total wallets deployed [read-only]
	forge script script/interactions/Factory.s.sol:TotalWallets \
		--rpc-url $(RPC) -vvvv

bw-list-wallets: ## list wallets with pagination (OFFSET, LIMIT) [read-only]
	forge script script/interactions/Factory.s.sol:GetWallets \
		--rpc-url $(RPC) -vvvv

bw-factory-roles: ## print factory role hashes [read-only]
	forge script script/interactions/Factory.s.sol:PrintRoles \
		--rpc-url $(RPC) -vvvv

## ─── Business Wallet — Direct ────────────────────────────────────────────────

bw-notify: ## permissionless ERC-20 sweep trigger (BUSINESS_WALLET_ADDRESS, TOKEN_ADDRESS)
	forge script script/interactions/BusinessWallet.s.sol:Notify \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-sweep-token: ## sweep single ERC-20 to pool (BUSINESS_WALLET_ADDRESS, TOKEN_ADDRESS)
	forge script script/interactions/BusinessWallet.s.sol:SweepToken \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-batch-sweep: ## sweep multiple ERC-20 tokens to pool (BUSINESS_WALLET_ADDRESS, TOKEN_ADDRESSES)
	forge script script/interactions/BusinessWallet.s.sol:BatchSweepTokens \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-sweep-eth: ## sweep residual ETH from wallet to pool (BUSINESS_WALLET_ADDRESS)
	forge script script/interactions/BusinessWallet.s.sol:SweepETH \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-execute: ## execute arbitrary call from wallet (BUSINESS_WALLET_ADDRESS, EXECUTE_TARGET, EXECUTE_VALUE, EXECUTE_DATA)
	forge script script/interactions/BusinessWallet.s.sol:Execute \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-set-pool: ## update pool wallet on a specific wallet (BUSINESS_WALLET_ADDRESS, NEW_POOL)
	forge script script/interactions/BusinessWallet.s.sol:SetWalletPool \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-pause-wallet: ## pause a wallet (BUSINESS_WALLET_ADDRESS)
	forge script script/interactions/BusinessWallet.s.sol:PauseWallet \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-unpause-wallet: ## unpause a wallet (BUSINESS_WALLET_ADDRESS)
	forge script script/interactions/BusinessWallet.s.sol:UnpauseWallet \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-grant-role: ## grant a wallet role (BUSINESS_WALLET_ADDRESS, ROLE, ROLE_ACCOUNT)
	forge script script/interactions/BusinessWallet.s.sol:GrantWalletRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-revoke-role: ## revoke a wallet role (BUSINESS_WALLET_ADDRESS, ROLE, ROLE_ACCOUNT)
	forge script script/interactions/BusinessWallet.s.sol:RevokeWalletRole \
		--rpc-url $(RPC) --broadcast --account $(ACCOUNT) -vvvv

bw-info: ## print wallet state (BUSINESS_WALLET_ADDRESS) [read-only]
	forge script script/interactions/BusinessWallet.s.sol:GetWalletInfo \
		--rpc-url $(RPC) -vvvv

bw-check-role: ## check if address has role on wallet (BUSINESS_WALLET_ADDRESS, ROLE, ROLE_ACCOUNT) [read-only]
	forge script script/interactions/BusinessWallet.s.sol:CheckWalletRole \
		--rpc-url $(RPC) -vvvv

bw-wallet-roles: ## print wallet role hashes [read-only]
	forge script script/interactions/BusinessWallet.s.sol:PrintWalletRoles \
		--rpc-url $(RPC) -vvvv

## ─── Help ────────────────────────────────────────────────────────────────────

help: ## print this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m [NETWORK=local|sepolia|mainnet|polygon|base|base-sepolia|arbitrum]\n"} \
	/^[a-zA-Z_0-9-]+:.*##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } \
	/^## ─/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 4) }' $(MAKEFILE_LIST)
