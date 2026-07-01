# Tokenx — Deployment Guide

This guide takes a developer from a fresh clone to a fully deployed, verified, and operational Tokenx stack. It covers local testing, testnet deployment, mainnet deployment, and post-deploy operations.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Repository Setup](#2-repository-setup)
3. [Environment Configuration](#3-environment-configuration)
4. [Local Development (Anvil)](#4-local-development-anvil)
5. [Deploy the Factory (Testnet / Mainnet)](#5-deploy-the-factory-testnet--mainnet)
6. [Verify Contracts on a Block Explorer](#6-verify-contracts-on-a-block-explorer)
7. [Deploy a Token Issuance](#7-deploy-a-token-issuance)
8. [Deploy a Bond Issuance](#8-deploy-a-bond-issuance)
9. [Post-Deploy Operations](#9-post-deploy-operations)
10. [Supported Networks](#10-supported-networks)
11. [Contract Architecture Summary](#11-contract-architecture-summary)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| [Foundry](https://book.getfoundry.sh/getting-started/installation) | latest stable | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Git | any | system package manager |
| Node.js | 18+ | optional — only needed if using ethers.js scripts |

Verify Foundry is installed:

```bash
forge --version   # Forge 0.2.x or later
cast --version
anvil --version
```

---

## 2. Repository Setup

```bash
git clone <repo-url>
cd contracts-deployments/Tokenx

# Install dependencies (OpenZeppelin, forge-std)
forge install
```

Build all contracts:

```bash
forge build
```

Run the test suite to confirm everything passes before touching deployment:

```bash
forge test -vvv
# Expected: 307 tests passed, 0 failed
```

---

## 3. Environment Configuration

Copy the example file and fill in values:

```bash
cp .env.example .env
```

Edit `.env`:

```bash
# ── Keys ──────────────────────────────────────────────────────────────────────
# Raw hex private key (0x-prefixed or bare). Used by interaction scripts.
PRIVATE_KEY=0x...
# Same key as PRIVATE_KEY unless you want a separate deployer wallet.
DEPLOYER_PRIVATE_KEY=0x...

# ── RPC endpoints (fill the networks you intend to use) ───────────────────────
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<key>
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/<key>
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/<key>
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<key>
POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/<key>
ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/<key>

# ── Block explorer API keys ────────────────────────────────────────────────────
ETHERSCAN_API_KEY=
BASESCAN_API_KEY=
POLYGONSCAN_API_KEY=
ARBISCAN_API_KEY=

# ── Admin ──────────────────────────────────────────────────────────────────────
# The wallet that will own all factory roles (deployer, pauser, admin).
# After deployment you can grant these to separate wallets if needed.
ADMIN_ADDRESS=0x...

# ── Populated after factory deployment (step 5) ───────────────────────────────
CHAIN_ID=
FACTORY_ADDRESS=
```

> **Security:** never commit `.env` to git. The `.gitignore` already excludes it.

### Using a keystore instead of a raw key (recommended for mainnet)

Foundry supports encrypted keystores. Import your key once:

```bash
cast wallet import deployer --interactive
# Enter private key and a password
```

The `Makefile` uses `--account deployer` for `deploy-factory`. For interaction scripts that use `--private-key`, switch to `--account deployer` and remove the `PRIVATE_KEY` var from `.env`.

---

## 4. Local Development (Anvil)

Start a local node in one terminal:

```bash
make anvil
# or: anvil --chain-id 31337
```

In a second terminal, deploy the full factory stack locally:

```bash
ADMIN_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  forge script script/Deploy.s.sol:DeployFactory \
    --rpc-url http://localhost:8545 \
    --broadcast \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

The first Anvil account (`0xf39F...`) and its private key (`0xac09...`) are hardcoded defaults — safe for local use only.

Copy the printed addresses into your `.env`:

```
--- Implementations ---
IdentityRegistry impl:  0x...
ComplianceModule impl:  0x...
SecurityToken impl:     0x...
YieldDistributor impl:  0x...
BondTerms impl:         0x...
--- Factory ---
TokenizationFactory:    0x...
Admin address:          0x...
```

Set `FACTORY_ADDRESS` in `.env` and proceed to [step 7](#7-deploy-a-token-issuance).

---

## 5. Deploy the Factory (Testnet / Mainnet)

The factory deployment is a **one-time operation**. It deploys five implementation contracts and one factory — six transactions total.

### 5a. Set required env vars

In `.env`, ensure these are set:

```bash
ADMIN_ADDRESS=0x...      # your deployer/admin wallet
CHAIN_ID=84532           # Base Sepolia example — see table in section 10
```

### 5b. Run the deployment

```bash
make deploy-factory NETWORK=base-sepolia
```

What this runs under the hood:

```bash
forge script script/Deploy.s.sol:DeployFactory \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --account deployer \
  -vvvv
```

### 5c. Save the output

The script prints all six addresses. Copy them into your `.env` and your backend database:

```
--- Implementations ---
IdentityRegistry impl:  0x5678ccb4884d86dc88378e1bbb467b35fa286ae5
ComplianceModule impl:  0x692b1021f4e82f70e4d35087232ae6a11e1cb49a
SecurityToken impl:     0x1324571b1608cd050821417c6cef6fdadb63b39c
YieldDistributor impl:  0x7bbab76e624c982e87c9f33cbe48b6ea63b56476
BondTerms impl:         0x...
--- Factory ---
TokenizationFactory:    0xb34a021526c063e4637a5ba02c3c936edeb32820
Admin address:          0x...
```

Update `.env`:

```bash
FACTORY_ADDRESS=0xb34a021526c063e4637a5ba02c3c936edeb32820
```

> **Note:** implementation addresses are only needed for block explorer verification. The factory stores them internally — backends only interact with `FACTORY_ADDRESS`.

---

## 6. Verify Contracts on a Block Explorer

Verification makes source code publicly readable and enables ABI-based interaction on Etherscan/Basescan.

### Verify the factory

```bash
make verify-factory NETWORK=base-sepolia
```

This calls `forge verify-contract` with the correct constructor args auto-encoded from your `.env` values.

### Verify the implementations

Implementations have no constructor arguments, so verification is straightforward:

```bash
forge verify-contract <IMPL_IDENTITY_REGISTRY_ADDRESS> \
  src/IdentityRegistry.sol:IdentityRegistry \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY

forge verify-contract <IMPL_COMPLIANCE_MODULE_ADDRESS> \
  src/ComplianceModule.sol:ComplianceModule \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY

forge verify-contract <IMPL_SECURITY_TOKEN_ADDRESS> \
  src/SecurityToken.sol:SecurityToken \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY

forge verify-contract <IMPL_YIELD_DISTRIBUTOR_ADDRESS> \
  src/YieldDistributor.sol:YieldDistributor \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY

forge verify-contract <IMPL_BOND_TERMS_ADDRESS> \
  src/BondTerms.sol:BondTerms \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY
```

Replace `base-sepolia` with your target network. Use `--chain mainnet` / `--chain polygon` etc. as appropriate.

> **EIP-1167 clone proxies** (the per-issuance contracts) do not require separate verification — block explorers recognise them as minimal proxies and link them to the verified implementation automatically.

---

## 7. Deploy a Token Issuance

Each call to `deployToken` or `deployBond` deploys a complete suite (identity registry, compliance module, security token, and optionally yield distributor + bond terms) as cheap EIP-1167 clones.

### Standard token (no yield)

Set the token-specific vars in `.env`:

```bash
TOKEN_TYPE=SECURITY
ISSUER_ID=ACME-EQUITY-2025
TOKEN_NAME=Acme Corporate Equity
TOKEN_SYMBOL=ACME
TOKEN_ADMIN=0x...           # wallet that controls this issuance
ISSUER_ONCHAIN_ID=0x0000000000000000000000000000000000000000
MAX_SHAREHOLDERS=500        # 0 = unlimited
MAX_TOKENS_PER_INVESTOR=0   # 0 = unlimited
LOCKUP_DURATION=0           # 0 = no lockup
```

Deploy:

```bash
make deploy-token NETWORK=base-sepolia
# shortcut:
make deploy-security-token NETWORK=base-sepolia
```

### Yield-bearing token (discretionary dividends)

```bash
TOKEN_TYPE=YIELD_BEARING
ISSUER_ID=ACME-REIT-2025
TOKEN_NAME=Acme Real Estate Fund
TOKEN_SYMBOL=ACMR
TOKEN_ADMIN=0x...
```

```bash
make deploy-yield-token NETWORK=base-sepolia
```

Both commands print a full record:

```
=== Token Suite Deployed ===
Token type          : SECURITY
Issuer ID           : ACME-EQUITY-2025
Token name          : Acme Corporate Equity
Token symbol        : ACME
SecurityToken       : 0x...
IdentityRegistry    : 0x...
ComplianceModule    : 0x...
YieldDistributor    : 0x0000000000000000000000000000000000000000
Token admin         : 0x...
```

Store all addresses in your backend database keyed by `ISSUER_ID`.

---

## 8. Deploy a Bond Issuance

Bonds require additional parameters for the `BondTerms` contract. There is no dedicated `make` target yet — call the script directly with all bond env vars set.

### Set bond params in `.env`

```bash
# ── Token identity ─────────────────────────────────────────────────────────
ISSUER_ID=ACME-BOND-5Y-2025
TOKEN_NAME=Acme 5y 7.5% Senior Note
TOKEN_SYMBOL=ACMB5
TOKEN_ADMIN=0x...
ISSUER_ONCHAIN_ID=0x0000000000000000000000000000000000000000

# ── Compliance ─────────────────────────────────────────────────────────────
MAX_SHAREHOLDERS=0
MAX_TOKENS_PER_INVESTOR=0
LOCKUP_DURATION=0

# ── Bond economics ─────────────────────────────────────────────────────────
# All timestamps are Unix seconds. Use: date -d "2030-01-01" +%s
ANNUAL_RATE_BPS=750           # 7.50% APR
COUPON_PERIOD_SECONDS=7776000  # 90 days
DAY_COUNT=0                    # 0=ACT_365  1=ACT_360  2=THIRTY_360
ISSUE_DATE=1751500000          # set to block.timestamp at deploy time
MATURITY_DATE=1909266000       # ISSUE_DATE + 5 years
FIRST_COUPON_DATE=1759276000   # ISSUE_DATE + 90 days
FACE_VALUE_PER_TOKEN=100000000 # $100 par, USDC-scaled (6 decimals)
                               # For 18-dec stablecoin: 100000000000000000000
GRACE_PERIOD_SECONDS=604800    # 7 days
CALLABLE=false
CALL_DATE=0
```

> `FACE_VALUE_PER_TOKEN` must be denominated in the **payout token's decimals**.
> - USDC (6 dec): `$100` → `100 * 10**6` = `100000000`
> - DAI / ETH (18 dec): `$100` → `100 * 10**18` = `100000000000000000000`

### Call the script

There is no standalone `make deploy-bond` target — run the forge script directly (or add your own Makefile target):

```bash
forge script script/Deploy.s.sol:DeployBond \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --account deployer \
  -vvvv
```

> If `DeployBond` is not yet in `Deploy.s.sol`, you can call `deployBond` on the factory via cast or add the script. A minimal cast call:

```bash
cast send $FACTORY_ADDRESS \
  "deployBond(string,string,string,address,address,(uint256,uint256,uint256),(uint256,uint256,uint8,uint256,uint256,uint256,uint256,uint256,bool,uint256,address))" \
  "ACME-BOND-5Y-2025" "Acme 5y 7.5% Senior Note" "ACMB5" \
  0x0000000000000000000000000000000000000000 \
  $TOKEN_ADMIN \
  "(0,0,0)" \
  "($ANNUAL_RATE_BPS,$COUPON_PERIOD_SECONDS,0,$ISSUE_DATE,$MATURITY_DATE,$FIRST_COUPON_DATE,$FACE_VALUE_PER_TOKEN,$GRACE_PERIOD_SECONDS,false,0,$TOKEN_ADMIN)" \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --account deployer
```

The factory automatically:
- Deploys and seals `BondTerms` with the supplied params
- Sets `TOKEN_ADMIN` as the bond admin (can call `setAnnualRate` later)
- Deploys `YieldDistributor` and wires it to `BondTerms`
- Grants all roles to `TOKEN_ADMIN`

---

## 9. Post-Deploy Operations

After deploying a token or bond, update `.env` with the issuance addresses:

```bash
TOKEN_ADDRESS=0x...
REGISTRY_ADDRESS=0x...
COMPLIANCE_ADDRESS=0x...
YIELD_DISTRIBUTOR_ADDRESS=0x...
# bonds only:
BOND_TERMS_ADDRESS=0x...
```

All interaction scripts read these from `.env`.

### Onboard an investor

```bash
WALLET=0x...investor...
COUNTRY=566        # ISO 3166-1 numeric (566 = Nigeria, 840 = USA, 826 = UK)
ONCHAIN_ID=0x0000000000000000000000000000000000000000

make ir-register NETWORK=base-sepolia
```

The investor is registered but **not yet verified** (cannot receive tokens until verified):

```bash
WALLET=0x...investor...
VERIFIED=true

make ir-set-verified NETWORK=base-sepolia
```

### Mint tokens

```bash
MINT_TO=0x...investor...
AMOUNT=1000000000000000000000   # 1000 tokens (18 decimals)

make token-mint NETWORK=base-sepolia
```

### Distribute yield (discretionary)

```bash
SNAPSHOT_ID=                    # filled in after create
PAYOUT_TOKEN=0x...usdc...       # or 0x000...000 for native ETH
FUND_AMOUNT=5000000000          # $5000 USDC (6 dec) — pre-approve first
RECLAIM_AFTER=2592000           # 30 days
DESCRIPTION=Q2 2025 Dividend
INVESTORS=0x...inv1...,0x...inv2...

make yield-snapshot NETWORK=base-sepolia
# prints snapshotId — save it

SNAPSHOT_ID=1
make yield-push NETWORK=base-sepolia   # admin pushes to all
# or investors call:
make yield-claim NETWORK=base-sepolia  # investor claims their own
```

### Pay a scheduled bond coupon

```bash
# 1. Check if due
cast call $BOND_TERMS_ADDRESS "isCouponDue()(bool)" --rpc-url $BASE_SEPOLIA_RPC_URL

# 2. Preview the required amount
cast call $BOND_TERMS_ADDRESS "couponPerToken()(uint256)" --rpc-url $BASE_SEPOLIA_RPC_URL
# multiply by eligible supply / 1e18 off-chain

# 3. Approve the stablecoin (skip for ETH payout)
cast send $USDC_ADDRESS \
  "approve(address,uint256)" $YIELD_DISTRIBUTOR_ADDRESS $REQUIRED_AMOUNT \
  --account deployer --rpc-url $BASE_SEPOLIA_RPC_URL

# 4. Create the scheduled coupon
PAYOUT_TOKEN=0x...usdc...
RECLAIM_AFTER=2592000
DESCRIPTION="Coupon 1 — Q1 2026"
INVESTORS=0x...inv1...,0x...inv2...

make yield-snapshot NETWORK=base-sepolia
```

### Update bond yield rate

```bash
# Only callable by TOKEN_ADMIN (the bond admin set at deployment)
cast send $BOND_TERMS_ADDRESS \
  "setAnnualRate(uint256)" 800 \
  --account deployer \
  --rpc-url $BASE_SEPOLIA_RPC_URL
# 800 bps = 8.00% — takes effect on the next createScheduledCoupon call
# Past snapshots are unaffected
```

### Redeem principal at maturity

```bash
# 1. Verify bond is matured
cast call $BOND_TERMS_ADDRESS "isMatured()(bool)" --rpc-url $BASE_SEPOLIA_RPC_URL

# 2. Send principal funds to the SecurityToken contract
#    For stablecoin:
cast send $USDC_ADDRESS \
  "transfer(address,uint256)" $TOKEN_ADDRESS $TOTAL_PRINCIPAL \
  --account deployer --rpc-url $BASE_SEPOLIA_RPC_URL
#    For ETH:
cast send $TOKEN_ADDRESS --value $TOTAL_PRINCIPAL_WEI \
  --account deployer --rpc-url $BASE_SEPOLIA_RPC_URL

# 3. Batch redeem all holders
cast send $TOKEN_ADDRESS \
  "batchRedeemAtMaturity(address[],address)" \
  "[0x...inv1...,0x...inv2...]" $USDC_ADDRESS \
  --account deployer --rpc-url $BASE_SEPOLIA_RPC_URL
```

### Factory admin operations

```bash
# Pause the factory (blocks new deployments)
make factory-pause NETWORK=base-sepolia

# Grant deploy permission to another wallet
ACCOUNT=0x...newdeployer...
make factory-grant-deployer NETWORK=base-sepolia

# Look up a deployed issuance
ISSUER_ID=ACME-EQUITY-2025
make factory-get-deployment NETWORK=base-sepolia

# Count total issuances
make factory-total-deployments NETWORK=base-sepolia
```

---

## 10. Supported Networks

Set `NETWORK=<name>` on any `make` command.

| Network name | Chain ID | Explorer | RPC env var |
|---|---|---|---|
| `local` | 31337 | — | `http://localhost:8545` |
| `sepolia` | 11155111 | etherscan.io | `SEPOLIA_RPC_URL` |
| `mainnet` | 1 | etherscan.io | `MAINNET_RPC_URL` |
| `base-sepolia` | 84532 | basescan.org | `BASE_SEPOLIA_RPC_URL` |
| `base` | 8453 | basescan.org | `BASE_RPC_URL` |
| `polygon` | 137 | polygonscan.com | `POLYGON_RPC_URL` |
| `arbitrum` | 42161 | arbiscan.io | `ARBITRUM_RPC_URL` |

**Set `CHAIN_ID` in `.env`** to match your target network. It is required by the Makefile and by cast calls.

---

## 11. Contract Architecture Summary

Understanding this helps when reading deployment output or tracing transactions.

```
TokenizationFactory  ← deployed once, entry point for all issuances
│
├── deployToken()    → deploys 3 clones (SECURITY) or 4 clones (YIELD_BEARING)
│   ├── IdentityRegistry  clone  ← KYC store for this issuance
│   ├── ComplianceModule  clone  ← transfer rules (caps, lockups, countries)
│   ├── SecurityToken     clone  ← the ERC-3643 token
│   └── YieldDistributor  clone  ← only for YIELD_BEARING
│
└── deployBond()     → deploys 5 clones
    ├── IdentityRegistry  clone
    ├── ComplianceModule  clone
    ├── SecurityToken     clone
    ├── YieldDistributor  clone  ← wired to BondTerms
    └── BondTerms         clone  ← economic terms; rate updatable by token admin
```

**Clones are EIP-1167 minimal proxies** — they are ~45 bytes on-chain and delegatecall to the shared implementation. Each issuance is isolated: its identity registry, compliance rules, and token are completely independent of all others.

**Implementations are deployed once** and never called directly after factory construction. If you need to upgrade logic, deploy new implementations and a new factory — existing issuances remain on the old implementations and continue to work.

---

## 12. Troubleshooting

### `CHAIN_ID not set`
Add `CHAIN_ID=<number>` to your `.env`. The Makefile requires it.

### `ADMIN_ADDRESS not set` / `FACTORY_ADDRESS not set`
These are mandatory in `.env`. Check that `.env` is in the `Tokenx/` directory and that `make` is run from the same directory.

### `error[9755]: Wrong argument count for struct constructor`
You are passing `BondTerms.InitParams` without the `admin` field. Add `admin: tokenAdmin` to the struct (or pass `TOKEN_ADMIN` in the env). The factory injects this automatically for `deployBond` — only custom scripts need it explicitly.

### `forge script` fails with `insufficient funds`
Your deployer wallet does not have enough native token for gas. Fund it from a faucet:
- Sepolia: https://sepoliafaucet.com
- Base Sepolia: https://www.coinbase.com/faucets/base-ethereum-goerli-faucet

### `"Factory: issuerId taken"`
`ISSUER_ID` was already used in a previous deployment on this network. Choose a different value.

### `"BT: coupon not due"`
`bondTerms.nextCouponDate()` is in the future. Wait until the coupon date passes before calling `createScheduledCoupon`.

### `"YD: wrong ETH amount"` / `"YD: ETH not allowed"`
For ETH payouts, send the exact required amount as `msg.value` and pass `payoutToken = address(0)`.  
For ERC-20 payouts, do not send any ETH and pre-approve the distributor before calling.

### Verification fails with `"Contract source code already verified"`
The contract is already verified. This is not an error — check the block explorer to confirm.

### Clone proxies not resolving on block explorer
Give the explorer a few minutes. It auto-detects EIP-1167 patterns and links them to the verified implementation. No manual action needed.
