# Tokenx — ERC-3643 Tokenization Factory

One-transaction deployer for ERC-3643 compliant security tokens, yield-bearing tokens, and tokenized bonds.

## Overview

Tokenx is a factory-based system for issuing on-chain security tokens. A single call to `TokenizationFactory.deployToken()` or `deployBond()` deploys and wires together an `IdentityRegistry`, a `ComplianceModule`, a `SecurityToken`, and optionally a `YieldDistributor` and `BondTerms`. Every token transfer passes through two compliance gates: a KYC identity check and a rule-based compliance check (shareholder cap, per-investor concentration limit, country block/allow list, lock-up period). Contracts are deployed as `BeaconProxy` instances — the platform admin can upgrade all tokens of a given type at once by pointing the beacon to a new implementation.

## Contracts

| Contract | Description |
|---|---|
| `TokenizationFactory` | Deploys complete token suites in one transaction via BeaconProxy; maintains a registry of all deployments. |
| `SecurityToken` | ERC-3643 / ERC-20 token with compliance gates, freeze, forced transfer, wallet recovery, batch operations, and bond principal redemption. |
| `ComplianceModule` | Enforces offering rules on every transfer: max shareholders, max tokens per investor, country block/allow list, wallet allowlist, and lock-up period. |
| `IdentityRegistry` | Maps investor wallet addresses to ONCHAINID contracts and ISO 3166-1 country codes; stores the KYC verified flag. |
| `YieldDistributor` | Compliance-aware yield distributor supporting ETH and ERC-20 payouts via pull (claim) or push (agent batch); supports free-form and BondTerms-constrained scheduled coupons. |
| `BondTerms` | Sealed economic terms for a tokenized bond: coupon rate, period, day-count convention, face value, maturity, grace period, and callable option. Drives coupon scheduling and default/repayment lifecycle. |

## Token Types

### Security Token

Deployed with `TokenType.SECURITY`. Consists of `IdentityRegistry` + `ComplianceModule` + `SecurityToken`. No yield distribution contract is deployed; `DeploymentRecord.yieldDistributor` is `address(0)`.

### Yield-Bearing Token

Deployed with `TokenType.YIELD_BEARING`. Same three contracts plus a `YieldDistributor` linked to the token. The agent calls `createSnapshot()` to record investor balances and deposit funds; investors claim via `claimYield()` or the agent batches payments via `pushYield()`.

### Tokenized Bond

Deployed via `deployBond()` (`TokenType.BOND`). Full suite of five contracts: `IdentityRegistry` + `ComplianceModule` + `SecurityToken` + `YieldDistributor` + `BondTerms`. Coupon payments are constrained by `BondTerms.isCouponDue()` and dispatched through `YieldDistributor.createScheduledCoupon()`. Principal is redeemed at maturity via `SecurityToken.redeemAtMaturity()`. Either the issuer or any investor can flag a default after the grace period via `YieldDistributor.flagDefault()`.

## Compliance Gates

Every transfer (mint, burn, or move) passes two gates enforced inside `SecurityToken._compliantTransfer`:

1. **IdentityRegistry.isVerified()** — both sender and recipient must be KYC-registered and have their `verified` flag set to `true`. Mint only checks the recipient.

2. **ComplianceModule.canTransfer()** — checks in order:
   - Recipient's country is not blocked (block-list mode) or is explicitly allowed (allow-list mode).
   - Wallet allowlist is satisfied if the allowlist feature is enabled.
   - Transfer would not push recipient over `maxTokensPerInvestor` (0 = no limit).
   - Transfer would not push total shareholder count over `maxShareholders` (0 = no limit).
   - Sender's lock-up period has expired (applies to transfers only, not mints).

Forced transfers (agent-initiated) bypass the compliance module but still require the recipient to be identity-verified.

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) — install with `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- Node (optional, for scripts)
- An `.env` file — copy from `.env.example` and populate

### Install

```bash
git clone <repo-url>
cd Tokenx
forge install
```

### Build

```bash
make build
# or: forge build
```

### Test

```bash
make test
# or: forge test --via-ir -vvv
```

## Deploy

### Local (Anvil)

Start a local node:

```bash
make anvil
```

In a second terminal, deploy the factory:

```bash
export DEPLOYER_PRIVATE_KEY=<anvil-private-key>
make deploy-factory NETWORK=local
```

Export the deployed factory address, then deploy a token suite:

```bash
export FACTORY_ADDRESS=<factory-address>
export ISSUER_ID=ACME-BOND-2025
export TOKEN_NAME="Acme Bond"
export TOKEN_SYMBOL=ABND
export TOKEN_ADMIN=<admin-address>
make deploy-security-token NETWORK=local
```

Deploy a tokenized bond:

```bash
export FACTORY_ADDRESS=<factory-address>
export ISSUER_ID=ACME-BOND-2025
export TOKEN_NAME="Acme Bond"
export TOKEN_SYMBOL=ABND
export TOKEN_ADMIN=<admin-address>
export ANNUAL_RATE_BPS=500          # 5 %
export COUPON_PERIOD=7776000        # 90 days in seconds
export ISSUE_DATE=<unix-ts>
export MATURITY_DATE=<unix-ts>
export FIRST_COUPON_DATE=<unix-ts>
export FACE_VALUE_PER_TOKEN=1000000000000000000  # 1e18 = 1 USDC-unit per token
export GRACE_PERIOD=604800          # 7 days
make deploy-bond NETWORK=local
```

Register an investor:

```bash
export IDENTITY_REGISTRY=<ir-address>
export WALLET=<investor-address>
export ONCHAIN_ID=<onchainid-address>
export COUNTRY=566
make ir-register NETWORK=local
```

Mint tokens:

```bash
export TOKEN_ADDRESS=<token-address>
export MINT_TO=<investor-address>
export AMOUNT=1000000000000000000000
make token-mint NETWORK=local
```

### Testnet

```bash
cp .env.example .env
export DEPLOYER_PRIVATE_KEY=<your-key>
export SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/<key>

make deploy-factory NETWORK=sepolia

export FACTORY_ADDRESS=<deployed-factory>
export ISSUER_ID=MY-BOND-001
export TOKEN_NAME="My Bond"
export TOKEN_SYMBOL=MBND
export TOKEN_ADMIN=<admin-address>
make deploy-token NETWORK=sepolia
```

Verify on Etherscan:

```bash
export FACTORY_ADDRESS=<deployed-factory>
export ADMIN_ADDRESS=<admin>
export ETHERSCAN_API_KEY=<key>
export CHAIN_ID=11155111
make verify-factory NETWORK=sepolia
```

## Makefile Reference

| Target | Description |
|---|---|
| `build` | Compile contracts (`forge build`) |
| `clean` | Clean build artifacts |
| `test` | Run all tests (`forge test -vvv`) |
| `fmt` | Format source files |
| `anvil` | Start local Anvil node |
| `deploy-factory` | Deploy `TokenizationFactory` |
| `deploy-token` | Deploy a token suite via factory |
| `deploy-security-token` | Shortcut: deploy a `SECURITY` token |
| `deploy-yield-token` | Shortcut: deploy a `YIELD_BEARING` token |
| `deploy-bond` | Deploy a `BOND` suite (token + BondTerms + YieldDistributor) |
| `ir-register` | Register investor identity |
| `ir-delete` | Delete investor identity |
| `ir-update-country` | Update investor country |
| `ir-update-identity` | Update investor ONCHAINID |
| `ir-set-verified` | Set investor verified flag |
| `ir-is-verified` | Read investor verified flag |
| `comp-set-max-shareholders` | Set max shareholder cap |
| `comp-set-max-tokens` | Set max tokens per investor |
| `comp-set-lockup` | Set lock-up duration |
| `comp-block-country` | Block a country code |
| `comp-unblock-country` | Unblock a country code |
| `comp-can-transfer` | Read-only compliance check |
| `token-mint` | Mint tokens |
| `token-burn` | Burn tokens |
| `token-transfer` | Transfer tokens |
| `token-forced-transfer` | Agent-initiated forced transfer |
| `token-recover` | Recover tokens from lost wallet |
| `token-freeze` | Freeze/unfreeze address |
| `token-freeze-partial` | Freeze partial token amount |
| `token-unfreeze-partial` | Unfreeze partial token amount |
| `token-pause` | Pause token transfers |
| `token-unpause` | Unpause token transfers |
| `token-batch-mint` | Batch mint |
| `token-balance` | Read wallet balance |
| `yield-snapshot` | Create snapshot and deposit yield |
| `yield-claim` | Investor claims yield |
| `yield-push` | Agent pushes yield to investors |
| `yield-reclaim` | Admin reclaims unclaimed yield |
| `yield-pending` | Read pending yield for investor |
| `yield-get-snapshot` | Read snapshot details |
| `bond-coupon-create` | Create scheduled coupon (BondTerms-constrained) |
| `bond-flag-default` | Permissionlessly flag bond as defaulted after grace breach |
| `bond-redeem` | Redeem holder tokens for principal at maturity |
| `bond-batch-redeem` | Batch redeem all holders at maturity |
| `bond-set-rate` | Update bond annual rate (bps) |
| `bond-is-coupon-due` | Read whether a coupon is currently due |
| `bond-is-matured` | Read whether the bond has matured |
| `factory-get-deployment` | Get deployment record by issuer ID |
| `factory-get-by-index` | Get deployment record by index |
| `factory-total-deployments` | Get total deployment count |
| `factory-pause` | Pause factory |
| `factory-unpause` | Unpause factory |
| `factory-grant-deployer` | Grant `DEPLOYER_ROLE` to account |
| `factory-revoke-deployer` | Revoke `DEPLOYER_ROLE` from account |
| `verify-factory` | Verify factory on Etherscan |
| `help` | Print all targets with descriptions |

All targets accept `NETWORK=local|sepolia|mainnet|polygon|base|arbitrum` (default: `local`).

## Environment Variables

| Variable | Used by | Description |
|---|---|---|
| `DEPLOYER_PRIVATE_KEY` | `deploy-factory`, `deploy-token` | Private key for factory/token deployment |
| `PRIVATE_KEY` | All interaction targets | Private key for interactions |
| `FACTORY_ADDRESS` | `deploy-token`, `factory-*`, `verify-factory` | Deployed factory address |
| `ISSUER_ID` | `deploy-token`, `factory-get-deployment` | Unique token issuer identifier |
| `TOKEN_NAME` | `deploy-token` | ERC-20 token name |
| `TOKEN_SYMBOL` | `deploy-token` | ERC-20 token symbol |
| `TOKEN_TYPE` | `deploy-token` | `SECURITY`, `YIELD_BEARING`, or `BOND` |
| `TOKEN_ADMIN` | `deploy-token` | Admin address for deployed contracts |
| `ISSUER_ONCHAIN_ID` | `deploy-token` | Issuer ONCHAINID address (optional) |
| `MAX_SHAREHOLDERS` | `deploy-token` | Max shareholder cap (0 = unlimited) |
| `MAX_TOKENS_PER_INVESTOR` | `deploy-token` | Per-investor token cap (0 = unlimited) |
| `LOCKUP_DURATION` | `deploy-token` | Lock-up duration in seconds |
| `ANNUAL_RATE_BPS` | `deploy-bond` | Annual coupon rate in basis points (e.g. 500 = 5%) |
| `COUPON_PERIOD` | `deploy-bond` | Coupon period in seconds (e.g. 7776000 = 90 days) |
| `DAY_COUNT` | `deploy-bond` | Day-count convention: `0`=ACT/365, `1`=ACT/360, `2`=30/360 |
| `ISSUE_DATE` | `deploy-bond` | Bond issue date (Unix timestamp) |
| `MATURITY_DATE` | `deploy-bond` | Bond maturity date (Unix timestamp) |
| `FIRST_COUPON_DATE` | `deploy-bond` | First coupon payment date (Unix timestamp) |
| `FACE_VALUE_PER_TOKEN` | `deploy-bond` | Face value per token in payout-token decimals (e.g. 1e18) |
| `GRACE_PERIOD` | `deploy-bond` | Grace period after missed coupon before default can be flagged (seconds) |
| `CALLABLE` | `deploy-bond` | `true` if bond is callable before maturity |
| `CALL_DATE` | `deploy-bond` | Optional call date (Unix timestamp; required if CALLABLE=true) |
| `IDENTITY_REGISTRY` | `ir-*` targets | Deployed IdentityRegistry address |
| `TOKEN_ADDRESS` | `token-*`, `comp-*`, `bond-*` targets | Deployed SecurityToken address |
| `COMPLIANCE_ADDRESS` | `comp-*` targets | Deployed ComplianceModule address |
| `YIELD_DISTRIBUTOR` | `yield-*`, `bond-coupon-*` targets | Deployed YieldDistributor address |
| `BOND_TERMS` | `bond-*` targets | Deployed BondTerms address |
| `SNAPSHOT_ID` | `yield-claim`, `yield-push`, `yield-pending`, `yield-get-snapshot` | Snapshot ID |
| `WALLET` | `ir-*`, `token-*` targets | Investor wallet address |
| `SEPOLIA_RPC_URL` | `NETWORK=sepolia` | Sepolia JSON-RPC endpoint |
| `MAINNET_RPC_URL` | `NETWORK=mainnet` | Mainnet JSON-RPC endpoint |
| `POLYGON_RPC_URL` | `NETWORK=polygon` | Polygon JSON-RPC endpoint |
| `BASE_RPC_URL` | `NETWORK=base` | Base JSON-RPC endpoint |
| `ARBITRUM_RPC_URL` | `NETWORK=arbitrum` | Arbitrum JSON-RPC endpoint |
| `ETHERSCAN_API_KEY` | `verify-factory` | Etherscan API key for verification |
| `CHAIN_ID` | `verify-factory` | Chain ID for Etherscan verification |
| `ADMIN_ADDRESS` | `verify-factory` | Constructor admin address for verification |

## Security

**Role separation.** Three roles are granted to `admin` at deployment time:
- `DEFAULT_ADMIN_ROLE` — full governance; can update registry, compliance, and grant/revoke roles.
- `AGENT_ROLE` — operational: mint, burn, freeze, forced transfer, wallet recovery, snapshot creation, yield push.
- `PAUSER_ROLE` — can pause and unpause the token and yield distributor.

**Freeze.** An agent can freeze an address entirely (`setAddressFrozen`) or freeze a partial token amount (`freezePartialTokens`). Frozen tokens cannot be transferred or burned. Address-frozen wallets are excluded from yield snapshots.

**Forced transfer.** Agents can move tokens between any two verified wallets without the sender's consent. Used for court orders, error correction, or sanction enforcement.

**Lock-up.** Minted tokens are subject to a lock-up period set in the `ComplianceModule`. Holders cannot transfer tokens until the lock-up expires.

**Shareholder cap.** The `maxShareholders` setting caps the number of distinct holders. Mints and transfers that would breach the cap are rejected.

**Wallet recovery.** If an investor loses access to their wallet, an agent can call `recoveryAddress()` to move the full balance (including frozen token accounting) to a new wallet registered to the same ONCHAINID.

**Bond default.** After a coupon payment is missed and the grace period has elapsed, any party (including investors) can call `YieldDistributor.flagDefault()` permissionlessly to mark the bond defaulted. No agent or admin action is required, preventing the issuer from suppressing a default flag.

**Bond upgrades.** All contracts are `BeaconProxy` instances. Upgrading a beacon propagates to every proxy of that type without touching individual token deployments.

## License

MIT
