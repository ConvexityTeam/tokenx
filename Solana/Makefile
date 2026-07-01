# Tokenx Solana — Makefile
#
# Usage: make <target> [NETWORK=localnet|devnet|mainnet-beta] [KEYPAIR=~/.config/solana/id.json]

NETWORK  ?= localnet
KEYPAIR  ?= ~/.config/solana/id.json
ANCHOR   := anchor
SOLANA   := solana

# ── Build ─────────────────────────────────────────────────────────────────────

.PHONY: build
build: ## Build all programs
	$(ANCHOR) build

.PHONY: clean
clean: ## Remove build artifacts
	$(ANCHOR) clean
	rm -rf target/

.PHONY: idl
idl: ## Generate IDL files
	$(ANCHOR) build --idl

# ── Test ──────────────────────────────────────────────────────────────────────

.PHONY: test
test: ## Run all tests against a local validator
	$(ANCHOR) test --provider.cluster $(NETWORK)

.PHONY: test-skip-deploy
test-skip-deploy: ## Run tests without re-deploying (validator must be running)
	$(ANCHOR) test --skip-deploy --provider.cluster $(NETWORK)

# ── Local validator ───────────────────────────────────────────────────────────

.PHONY: localnet
localnet: ## Start a local Solana test validator
	solana-test-validator --reset --quiet &

.PHONY: localnet-stop
localnet-stop: ## Stop the local validator
	pkill -f solana-test-validator || true

# ── Deploy ────────────────────────────────────────────────────────────────────

.PHONY: deploy
deploy: build ## Deploy both programs to $(NETWORK)
	$(ANCHOR) deploy --provider.cluster $(NETWORK) --provider.wallet $(KEYPAIR)

.PHONY: deploy-hook
deploy-hook: ## Deploy only the transfer-hook program
	$(ANCHOR) deploy --program-name transfer_hook \
		--provider.cluster $(NETWORK) --provider.wallet $(KEYPAIR)

.PHONY: deploy-tokenx
deploy-tokenx: ## Deploy only the tokenx program
	$(ANCHOR) deploy --program-name tokenx \
		--provider.cluster $(NETWORK) --provider.wallet $(KEYPAIR)

# ── Factory ───────────────────────────────────────────────────────────────────

.PHONY: factory-init
factory-init: ## Initialise the global factory PDA
	$(ANCHOR) run factory-init --provider.cluster $(NETWORK)

.PHONY: factory-pause
factory-pause: ## Pause the factory (PAUSED=true|false)
	PAUSED=$(PAUSED) $(ANCHOR) run factory-pause --provider.cluster $(NETWORK)

# ── Suite deployment ──────────────────────────────────────────────────────────

.PHONY: deploy-suite
deploy-suite: ## Deploy a SECURITY or YIELD_BEARING suite
	ISSUER_ID=$(ISSUER_ID) \
	TOKEN_TYPE=$(TOKEN_TYPE) \
	TOKEN_NAME=$(TOKEN_NAME) \
	TOKEN_SYMBOL=$(TOKEN_SYMBOL) \
	TOKEN_ADMIN=$(TOKEN_ADMIN) \
	MAX_SHAREHOLDERS=$(or $(MAX_SHAREHOLDERS),0) \
	MAX_TOKENS_PER_INVESTOR=$(or $(MAX_TOKENS_PER_INVESTOR),0) \
	LOCKUP_DURATION=$(or $(LOCKUP_DURATION),0) \
	DECIMALS=$(or $(DECIMALS),6) \
	$(ANCHOR) run deploy-suite --provider.cluster $(NETWORK)

.PHONY: deploy-security
deploy-security: ## Shortcut: deploy a SECURITY suite
	TOKEN_TYPE=Security $(MAKE) deploy-suite

.PHONY: deploy-yield
deploy-yield: ## Shortcut: deploy a YIELD_BEARING suite
	TOKEN_TYPE=YieldBearing $(MAKE) deploy-suite

.PHONY: deploy-bond
deploy-bond: ## Deploy a BOND suite (includes BondTerms)
	ISSUER_ID=$(ISSUER_ID) \
	TOKEN_NAME=$(TOKEN_NAME) \
	TOKEN_SYMBOL=$(TOKEN_SYMBOL) \
	TOKEN_ADMIN=$(TOKEN_ADMIN) \
	ANNUAL_RATE_BPS=$(ANNUAL_RATE_BPS) \
	COUPON_PERIOD_SECS=$(COUPON_PERIOD_SECS) \
	DAY_COUNT=$(or $(DAY_COUNT),0) \
	ISSUE_DATE=$(ISSUE_DATE) \
	MATURITY_DATE=$(MATURITY_DATE) \
	FIRST_COUPON_DATE=$(FIRST_COUPON_DATE) \
	FACE_VALUE_PER_TOKEN=$(FACE_VALUE_PER_TOKEN) \
	GRACE_PERIOD_SECS=$(or $(GRACE_PERIOD_SECS),604800) \
	CALLABLE=$(or $(CALLABLE),false) \
	CALL_DATE=$(or $(CALL_DATE),0) \
	DECIMALS=$(or $(DECIMALS),6) \
	$(ANCHOR) run deploy-bond --provider.cluster $(NETWORK)

# ── Identity ──────────────────────────────────────────────────────────────────

.PHONY: ir-register
ir-register: ## Register an investor (SUITE= WALLET= ONCHAIN_ID= COUNTRY=)
	SUITE=$(SUITE) WALLET=$(WALLET) ONCHAIN_ID=$(ONCHAIN_ID) COUNTRY=$(COUNTRY) \
	$(ANCHOR) run ir-register --provider.cluster $(NETWORK)

.PHONY: ir-set-verified
ir-set-verified: ## Set verified flag (SUITE= WALLET= VERIFIED=true|false)
	SUITE=$(SUITE) WALLET=$(WALLET) VERIFIED=$(VERIFIED) \
	$(ANCHOR) run ir-set-verified --provider.cluster $(NETWORK)

.PHONY: ir-update-country
ir-update-country: ## Update investor country (SUITE= WALLET= COUNTRY=)
	SUITE=$(SUITE) WALLET=$(WALLET) COUNTRY=$(COUNTRY) \
	$(ANCHOR) run ir-update-country --provider.cluster $(NETWORK)

.PHONY: ir-delete
ir-delete: ## Delete investor identity (SUITE= WALLET=)
	SUITE=$(SUITE) WALLET=$(WALLET) \
	$(ANCHOR) run ir-delete --provider.cluster $(NETWORK)

# ── Compliance ────────────────────────────────────────────────────────────────

.PHONY: comp-set-max-shareholders
comp-set-max-shareholders: ## Set max shareholders (SUITE= MAX=)
	SUITE=$(SUITE) MAX=$(MAX) $(ANCHOR) run comp-set-max-shareholders --provider.cluster $(NETWORK)

.PHONY: comp-set-max-tokens
comp-set-max-tokens: ## Set max tokens per investor (SUITE= MAX=)
	SUITE=$(SUITE) MAX=$(MAX) $(ANCHOR) run comp-set-max-tokens --provider.cluster $(NETWORK)

.PHONY: comp-set-lockup
comp-set-lockup: ## Set lockup duration in seconds (SUITE= DURATION=)
	SUITE=$(SUITE) DURATION=$(DURATION) $(ANCHOR) run comp-set-lockup --provider.cluster $(NETWORK)

.PHONY: comp-block-country
comp-block-country: ## Block a country in block-list mode (SUITE= COUNTRY=)
	SUITE=$(SUITE) COUNTRY=$(COUNTRY) $(ANCHOR) run comp-block-country --provider.cluster $(NETWORK)

.PHONY: comp-unblock-country
comp-unblock-country: ## Unblock a country (SUITE= COUNTRY=)
	SUITE=$(SUITE) COUNTRY=$(COUNTRY) $(ANCHOR) run comp-unblock-country --provider.cluster $(NETWORK)

.PHONY: comp-allow-country
comp-allow-country: ## Allow a country in allow-list mode (SUITE= COUNTRY=)
	SUITE=$(SUITE) COUNTRY=$(COUNTRY) $(ANCHOR) run comp-allow-country --provider.cluster $(NETWORK)

# ── Token operations ──────────────────────────────────────────────────────────

.PHONY: token-mint
token-mint: ## Mint tokens (SUITE= TO= AMOUNT=)
	SUITE=$(SUITE) TO=$(TO) AMOUNT=$(AMOUNT) \
	$(ANCHOR) run token-mint --provider.cluster $(NETWORK)

.PHONY: token-burn
token-burn: ## Burn tokens (SUITE= FROM= AMOUNT=)
	SUITE=$(SUITE) FROM=$(FROM) AMOUNT=$(AMOUNT) \
	$(ANCHOR) run token-burn --provider.cluster $(NETWORK)

.PHONY: token-forced-transfer
token-forced-transfer: ## Forced transfer (SUITE= FROM= TO= AMOUNT=)
	SUITE=$(SUITE) FROM=$(FROM) TO=$(TO) AMOUNT=$(AMOUNT) \
	$(ANCHOR) run token-forced-transfer --provider.cluster $(NETWORK)

.PHONY: token-freeze
token-freeze: ## Freeze/unfreeze wallet (SUITE= WALLET= FROZEN=true|false)
	SUITE=$(SUITE) WALLET=$(WALLET) FROZEN=$(FROZEN) \
	$(ANCHOR) run token-freeze --provider.cluster $(NETWORK)

.PHONY: token-freeze-partial
token-freeze-partial: ## Freeze partial amount (SUITE= WALLET= AMOUNT=)
	SUITE=$(SUITE) WALLET=$(WALLET) AMOUNT=$(AMOUNT) \
	$(ANCHOR) run token-freeze-partial --provider.cluster $(NETWORK)

.PHONY: token-recover
token-recover: ## Recover wallet (SUITE= LOST= NEW=)
	SUITE=$(SUITE) LOST=$(LOST) NEW=$(NEW) \
	$(ANCHOR) run token-recover --provider.cluster $(NETWORK)

.PHONY: token-pause
token-pause: ## Pause token suite (SUITE= PAUSED=true|false)
	SUITE=$(SUITE) PAUSED=$(PAUSED) \
	$(ANCHOR) run token-pause --provider.cluster $(NETWORK)

# ── Yield distributor ─────────────────────────────────────────────────────────

.PHONY: yield-open-snapshot
yield-open-snapshot: ## Open a yield snapshot (SUITE= FUND_AMOUNT= RECLAIM_AFTER= DESCRIPTION=)
	SUITE=$(SUITE) FUND_AMOUNT=$(FUND_AMOUNT) RECLAIM_AFTER=$(RECLAIM_AFTER) \
	DESCRIPTION=$(DESCRIPTION) \
	$(ANCHOR) run yield-open-snapshot --provider.cluster $(NETWORK)

.PHONY: yield-add-record
yield-add-record: ## Add one investor record to open snapshot (SUITE= SNAPSHOT_ID= INVESTOR=)
	SUITE=$(SUITE) SNAPSHOT_ID=$(SNAPSHOT_ID) INVESTOR=$(INVESTOR) \
	$(ANCHOR) run yield-add-record --provider.cluster $(NETWORK)

.PHONY: yield-finalize
yield-finalize: ## Finalise snapshot (SUITE= SNAPSHOT_ID=)
	SUITE=$(SUITE) SNAPSHOT_ID=$(SNAPSHOT_ID) \
	$(ANCHOR) run yield-finalize --provider.cluster $(NETWORK)

.PHONY: yield-claim
yield-claim: ## Investor claims yield (SUITE= SNAPSHOT_ID=)
	SUITE=$(SUITE) SNAPSHOT_ID=$(SNAPSHOT_ID) \
	$(ANCHOR) run yield-claim --provider.cluster $(NETWORK)

.PHONY: yield-push
yield-push: ## Agent pushes yield to investor (SUITE= SNAPSHOT_ID= INVESTOR=)
	SUITE=$(SUITE) SNAPSHOT_ID=$(SNAPSHOT_ID) INVESTOR=$(INVESTOR) \
	$(ANCHOR) run yield-push --provider.cluster $(NETWORK)

.PHONY: yield-reclaim
yield-reclaim: ## Admin reclaims unclaimed yield (SUITE= SNAPSHOT_ID=)
	SUITE=$(SUITE) SNAPSHOT_ID=$(SNAPSHOT_ID) \
	$(ANCHOR) run yield-reclaim --provider.cluster $(NETWORK)

# ── Bond ──────────────────────────────────────────────────────────────────────

.PHONY: bond-open-coupon
bond-open-coupon: ## Open a scheduled coupon snapshot (SUITE= RECLAIM_AFTER= DESCRIPTION=)
	SUITE=$(SUITE) RECLAIM_AFTER=$(RECLAIM_AFTER) DESCRIPTION=$(DESCRIPTION) \
	$(ANCHOR) run bond-open-coupon --provider.cluster $(NETWORK)

.PHONY: bond-finalize-coupon
bond-finalize-coupon: ## Finalise coupon, pull funds, advance coupon date (SUITE= SNAPSHOT_ID=)
	SUITE=$(SUITE) SNAPSHOT_ID=$(SNAPSHOT_ID) \
	$(ANCHOR) run bond-finalize-coupon --provider.cluster $(NETWORK)

.PHONY: bond-flag-default
bond-flag-default: ## Flag bond as defaulted (permissionless after grace breach) (SUITE=)
	SUITE=$(SUITE) $(ANCHOR) run bond-flag-default --provider.cluster $(NETWORK)

.PHONY: bond-redeem
bond-redeem: ## Redeem one holder's tokens for principal at maturity (SUITE= HOLDER=)
	SUITE=$(SUITE) HOLDER=$(HOLDER) \
	$(ANCHOR) run bond-redeem --provider.cluster $(NETWORK)

.PHONY: bond-set-rate
bond-set-rate: ## Update bond annual rate in bps (SUITE= RATE_BPS=)
	SUITE=$(SUITE) RATE_BPS=$(RATE_BPS) \
	$(ANCHOR) run bond-set-rate --provider.cluster $(NETWORK)

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Print all targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
