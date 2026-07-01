# Tokenx — Solana Security Token Program

Solana equivalent of the EVM Tokenx ERC-3643 security token system, built with Anchor and SPL Token-2022.

## Overview

Tokenx on Solana is a factory-based program for issuing compliant security tokens. A single transaction calling `ix_initialize_suite` (or `ix_initialize_bond_suite`) creates and wires all the necessary Program Derived Address (PDA) accounts for an `IdentityRegistry`, a `ComplianceConfig`, a `TokenSuite` record, and optionally a `YieldDistributor` and `BondTerms`. The token itself is an SPL Token-2022 mint with a **transfer hook** extension that enforces compliance on every token movement.

## Architecture

### EVM → Solana Mapping

| EVM Contract | Solana Equivalent |
|---|---|
| `TokenizationFactory` | `ix_initialize_suite` / `ix_initialize_bond_suite` instructions + `Factory` PDA |
| `SecurityToken` | SPL Token-2022 mint + `TokenSuite` PDA (authority & config) |
| `IdentityRegistry` | `IdentityRegistry` PDA (per suite) + `InvestorIdentity` PDA (per investor) |
| `ComplianceModule` | `ComplianceConfig` PDA + `HolderState` PDA + `CountryRule` PDA |
| `YieldDistributor` | `YieldDistributor` PDA + `Snapshot` PDA + `ClaimRecord` PDA |
| `BondTerms` | `BondTerms` PDA |
| BeaconProxy upgrade | Solana program upgrade authority (`solana program deploy`) |
| AccessControl roles | `TokenSuite.admin`, `.agent`, `.pauser` public keys |
| EIP-2771 meta-tx | Solana transaction fee payer separation (native to Solana) |

### Programs

| Program | Description |
|---|---|
| `tokenx` | Main program: factory, identity, compliance, token ops, yield, bond instructions. |
| `transfer_hook` | SPL Token-2022 transfer hook: enforces all compliance checks on every token transfer. |

### PDA Accounts

| Account | Seeds | Description |
|---|---|---|
| `Factory` | `[b"factory"]` | Global factory config. Created once. |
| `TokenSuite` | `[b"suite", issuer_id]` | Central registry record for one token suite. |
| `Mint` | `[b"mint", issuer_id]` | SPL Token-2022 mint PDA (program-owned). |
| `IdentityRegistry` | `[b"identity_registry", suite]` | KYC registry config for a suite. |
| `InvestorIdentity` | `[b"identity", suite, wallet]` | Per-investor KYC record. |
| `ComplianceConfig` | `[b"compliance", suite]` | Compliance rules for a suite. |
| `HolderState` | `[b"holder", suite, wallet]` | Per-investor compliance state (balance, freeze, lockup). |
| `CountryRule` | `[b"country_rule", suite, country_le]` | Per-country block/allow rule. Created on demand. |
| `YieldDistributor` | `[b"yield_dist", suite]` | Yield distributor config. |
| `Snapshot` | `[b"snapshot", yield_distributor, id_le]` | Per-distribution snapshot. |
| `ClaimRecord` | `[b"claim", snapshot, wallet]` | Per-investor claim record for one snapshot. |
| `BondTerms` | `[b"bond_terms", suite]` | Sealed economic terms for a tokenized bond. |

### Transfer Hook Compliance Flow

Every SPL Token-2022 transfer invokes the `transfer_hook` program's `execute` instruction. The hook receives extra accounts (passed via `ExtraAccountMetaList`) and performs:

1. Sender KYC verified check.
2. Recipient KYC verified check.
3. Sender not fully frozen.
4. Recipient not fully frozen.
5. Sender has sufficient unfrozen balance.
6. Wallet allowlist check (if enabled).
7. Country block/allow check.
8. Max tokens per investor check.
9. Max shareholders check.
10. Sender lock-up period check.

If all checks pass, the hook updates `HolderState` balances and `ComplianceConfig.shareholder_count` in-place.

## Token Types

### Security Token

Call `ix_initialize_suite` with `token_type = TokenType::Security`. Creates:
- `TokenSuite`, `Mint`, `IdentityRegistry`, `ComplianceConfig`

### Yield-Bearing Token

Call `ix_initialize_suite` with `token_type = TokenType::YieldBearing`. Creates:
- `TokenSuite`, `Mint`, `IdentityRegistry`, `ComplianceConfig`, `YieldDistributor`

### Tokenized Bond

Call `ix_initialize_bond_suite`. Creates:
- `TokenSuite`, `Mint`, `IdentityRegistry`, `ComplianceConfig`, `YieldDistributor`, `BondTerms`

## Yield Distribution — Two-Phase Snapshot

Unlike the EVM version which passes all investors in one transaction, Solana's account-per-transaction model requires a multi-phase approach:

1. **`ix_open_snapshot`** — creates the `Snapshot` PDA, deposits funds, sets `active = false`.
2. **`ix_add_snapshot_record`** (one call per investor) — creates a `ClaimRecord` PDA for each eligible investor.
3. **`ix_finalize_snapshot`** — sets `active = true` once all records are added.

Investors then call `ix_claim_yield` to pull their share, or the agent batches `ix_push_yield` calls (one per investor).

## Bond Coupon Flow

Same two-phase pattern adapted for BondTerms-constrained payouts:

1. **`ix_open_scheduled_coupon`** — validates `bond_terms.is_coupon_due()`, creates the `Snapshot` PDA.
2. **`ix_add_snapshot_record`** (one per investor) — creates `ClaimRecord` PDAs.
3. **`ix_finalize_scheduled_coupon`** — computes required funds (`coupon_per_token × eligible_supply`), pulls exact amount from agent, advances `bond_terms.next_coupon_date`.

## Prerequisites

- [Rust](https://rustup.rs/) stable toolchain
- [Solana CLI](https://docs.solana.com/cli/install-solana-cli-tools) ≥ 1.18
- [Anchor](https://www.anchor-lang.com/docs/installation) 0.32
- [Node.js](https://nodejs.org/) ≥ 18 and Yarn

```bash
# Install Anchor CLI
cargo install --git https://github.com/coral-xyz/anchor avm --locked
avm install 0.32.1
avm use 0.32.1
```

## Quick Start

### Install dependencies

```bash
cd Solana
yarn install
```

### Build

```bash
make build
# or: anchor build
```

### Test

```bash
# Terminal 1: start local validator
make localnet

# Terminal 2: run tests
make test
```

### Deploy (localnet)

```bash
# 1. Start validator
make localnet

# 2. Deploy both programs
make deploy NETWORK=localnet

# 3. Initialise the factory PDA
make factory-init NETWORK=localnet

# 4. Deploy a security token suite
make deploy-security \
  ISSUER_ID=ACME-BOND-2025 \
  TOKEN_ADMIN=<admin-pubkey> \
  NETWORK=localnet

# 5. Register an investor
make ir-register \
  SUITE=<suite-pubkey> \
  WALLET=<investor-pubkey> \
  ONCHAIN_ID=<onchainid-pubkey> \
  COUNTRY=566 \
  NETWORK=localnet

# 6. Mint tokens
make token-mint \
  SUITE=<suite-pubkey> \
  TO=<investor-pubkey> \
  AMOUNT=1000000 \
  NETWORK=localnet
```

### Deploy a bond (localnet)

```bash
make deploy-bond \
  ISSUER_ID=ACME-BOND-001 \
  TOKEN_ADMIN=<admin-pubkey> \
  ANNUAL_RATE_BPS=500 \
  COUPON_PERIOD_SECS=7776000 \
  ISSUE_DATE=<unix-ts> \
  MATURITY_DATE=<unix-ts> \
  FIRST_COUPON_DATE=<unix-ts> \
  FACE_VALUE_PER_TOKEN=1000000 \
  NETWORK=localnet
```

### Deploy to devnet

```bash
solana config set --url devnet
solana airdrop 5
make deploy NETWORK=devnet
```

## Makefile Reference

| Target | Description |
|---|---|
| `build` | Compile all programs |
| `clean` | Remove build artifacts |
| `idl` | Generate IDL files |
| `test` | Run test suite |
| `localnet` | Start local test validator |
| `deploy` | Deploy both programs |
| `deploy-hook` | Deploy only transfer-hook |
| `deploy-tokenx` | Deploy only tokenx |
| `factory-init` | Initialise global factory PDA |
| `factory-pause` | Pause/unpause factory |
| `deploy-suite` | Deploy SECURITY or YIELD_BEARING suite |
| `deploy-security` | Shortcut: SECURITY suite |
| `deploy-yield` | Shortcut: YIELD_BEARING suite |
| `deploy-bond` | Deploy BOND suite with BondTerms |
| `ir-register` | Register investor identity |
| `ir-set-verified` | Set KYC verified flag |
| `ir-update-country` | Update investor country |
| `ir-delete` | Delete investor identity |
| `comp-set-max-shareholders` | Set shareholder cap |
| `comp-set-max-tokens` | Set per-investor token cap |
| `comp-set-lockup` | Set lockup duration |
| `comp-block-country` | Block a country (block-list mode) |
| `comp-unblock-country` | Unblock a country |
| `comp-allow-country` | Allow a country (allow-list mode) |
| `token-mint` | Mint tokens to investor |
| `token-burn` | Burn tokens |
| `token-forced-transfer` | Agent forced transfer |
| `token-freeze` | Freeze/unfreeze wallet |
| `token-freeze-partial` | Freeze partial token amount |
| `token-recover` | Recover tokens from lost wallet |
| `token-pause` | Pause/unpause token suite |
| `yield-open-snapshot` | Open yield snapshot (phase 1) |
| `yield-add-record` | Add investor record (phase 2) |
| `yield-finalize` | Finalise snapshot (phase 3) |
| `yield-claim` | Investor claims yield |
| `yield-push` | Agent pushes yield to investor |
| `yield-reclaim` | Admin reclaims unclaimed yield |
| `bond-open-coupon` | Open scheduled coupon (phase 1) |
| `bond-finalize-coupon` | Finalise coupon + advance date (phase 3) |
| `bond-flag-default` | Permissionless default flag |
| `bond-redeem` | Redeem tokens for principal at maturity |
| `bond-set-rate` | Update bond annual rate |
| `help` | Print all targets |

## Environment Variables

| Variable | Used by | Description |
|---|---|---|
| `NETWORK` | All targets | `localnet`, `devnet`, or `mainnet-beta` (default: `localnet`) |
| `KEYPAIR` | `deploy*` | Path to deployer keypair (default: `~/.config/solana/id.json`) |
| `ISSUER_ID` | `deploy-suite`, `deploy-bond` | Unique issuer ID string (max 64 chars) |
| `TOKEN_TYPE` | `deploy-suite` | `Security` or `YieldBearing` |
| `TOKEN_ADMIN` | `deploy-suite`, `deploy-bond` | Admin public key |
| `DECIMALS` | `deploy-suite`, `deploy-bond` | Token decimals (default: 6) |
| `MAX_SHAREHOLDERS` | `deploy-suite`, `deploy-bond` | Max shareholder cap (0 = unlimited) |
| `MAX_TOKENS_PER_INVESTOR` | `deploy-suite`, `deploy-bond` | Per-investor token cap (0 = unlimited) |
| `LOCKUP_DURATION` | `deploy-suite`, `deploy-bond` | Lockup in seconds (0 = none) |
| `ANNUAL_RATE_BPS` | `deploy-bond` | Annual coupon rate in basis points |
| `COUPON_PERIOD_SECS` | `deploy-bond` | Coupon period in seconds |
| `DAY_COUNT` | `deploy-bond` | 0 = ACT/365, 1 = ACT/360, 2 = 30/360 |
| `ISSUE_DATE` | `deploy-bond` | Bond issue date (Unix timestamp) |
| `MATURITY_DATE` | `deploy-bond` | Bond maturity date (Unix timestamp) |
| `FIRST_COUPON_DATE` | `deploy-bond` | First coupon date (Unix timestamp) |
| `FACE_VALUE_PER_TOKEN` | `deploy-bond` | Face value per token in payout-token atoms |
| `GRACE_PERIOD_SECS` | `deploy-bond` | Grace period before default can be flagged |
| `CALLABLE` | `deploy-bond` | `true` if bond is callable before maturity |
| `CALL_DATE` | `deploy-bond` | Optional call date (Unix timestamp) |
| `SUITE` | Most interaction targets | `TokenSuite` PDA public key |
| `WALLET` | `ir-*`, `token-*` | Investor wallet public key |
| `ONCHAIN_ID` | `ir-register` | Investor ONCHAINID public key |
| `COUNTRY` | `ir-register`, `comp-*-country` | ISO 3166-1 numeric country code |
| `SNAPSHOT_ID` | `yield-*`, `bond-finalize-coupon` | Snapshot numeric ID |
| `INVESTOR` | `yield-add-record`, `yield-push`, `bond-redeem` | Investor wallet public key |
| `AMOUNT` | `token-mint`, `token-burn`, etc. | Token amount in atomic units |
| `RATE_BPS` | `bond-set-rate` | New annual rate in basis points |

## Security

**Role keys.** Each `TokenSuite` stores `admin`, `agent`, and `pauser` public keys. These are plain Pubkeys (not PDAs), so authority can be transferred by updating the suite account. For production, use a multisig (e.g. Squads) as the admin key.

**Freeze.** `HolderState.frozen = true` prevents all transfers via the transfer hook. `frozen_tokens` tracks a partial freeze; the hook enforces `balance - frozen_tokens >= amount`.

**Lock-up.** `HolderState.lockup_end` is set by the compliance layer at mint time. The hook rejects transfers where `now < lockup_end`.

**Forced transfer.** `ix_forced_transfer` bypasses compliance but still requires the recipient to be KYC-verified. Compliance `HolderState` is updated correctly.

**Wallet recovery.** `ix_recover_wallet` migrates the full balance and frozen-token accounting from a lost wallet to a new wallet registered under the same `onchain_id`.

**Bond default.** `ix_flag_default` is permissionless — any signer can trigger it once `bond_terms.is_in_grace_breach()` is true. Investors can flag without the issuer's cooperation.

**Upgrade authority.** Solana programs are upgraded by the upgrade authority keypair with `solana program deploy`. For production, transfer upgrade authority to a multisig or use `solana program set-upgrade-authority` to make programs immutable.

## License

MIT
