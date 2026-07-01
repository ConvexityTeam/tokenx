# Tokenx — Backend Contract Interface Reference

This document lists every callable function across all five contracts, written for backend engineers integrating via ethers.js or a similar library. Each entry covers the function name, arguments, return values, who is allowed to call it, and what errors to handle.

---

## Table of Contents

1. [TokenizationFactory](#1-tokenizationfactory)
2. [SecurityToken](#2-securitytoken)
3. [IdentityRegistry](#3-identityregistry)
4. [ComplianceModule](#4-compliancemodule)
5. [YieldDistributor](#5-yielddistributor)
6. [BondTerms](#6-bondterms)
7. [TokenxForwarder](#7-tokenxforwarder)
8. [Upgradeability](#8-upgradeability)
9. [Roles Reference](#9-roles-reference)
10. [Data Structures](#10-data-structures)
11. [Events Reference](#11-events-reference)
12. [Integration Checklist](#12-integration-checklist)

---

## 1. TokenizationFactory

The platform entry point. Deploy once. All token issuances are created through this contract.

**Architecture:** The factory deploys every contract as a **BeaconProxy** (EIP-1967). Each contract type has a corresponding `UpgradeableBeacon` that the platform admin owns. Calling `beacon.upgradeTo(newImpl)` upgrades every proxy of that type instantly — no per-token action needed. See [Upgradeability](#8-upgradeability).

---

### `deployToken`

Creates a complete token issuance — deploys the token, compliance module, identity registry, and (optionally) yield distributor all in one call. Returns the token address. Call `getDeployment(issuerId)` afterwards to retrieve all contract addresses.

```
deployToken(tokenType, issuerId, tokenName, tokenSymbol, issuerOnchainID, tokenAdmin, compliance)
→ address token
```

| Argument                          | Type               | Description                                                                       |
| --------------------------------- | ------------------ | --------------------------------------------------------------------------------- |
| `tokenType`                       | `number`           | `0` = standard (no yield), `1` = yield-bearing. Use `deployBond` for `2` = bond.  |
| `issuerId`                        | `string`           | Unique identifier for this issuance, e.g. `"ACME-EQUITY-2025"`. Cannot be reused. |
| `tokenName`                       | `string`           | Full name of the token, e.g. `"Acme Corporate Equity"`                            |
| `tokenSymbol`                     | `string`           | Short ticker, e.g. `"ACME"`                                                       |
| `issuerOnchainID`                 | `string (address)` | Issuer identity address. Pass zero address if not applicable.                     |
| `tokenAdmin`                      | `string (address)` | The wallet that will control all deployed contracts. Cannot be zero.              |
| `compliance.maxShareholders`      | `number`           | Max number of distinct holders. `0` = unlimited.                                  |
| `compliance.maxTokensPerInvestor` | `number`           | Max token balance per wallet. `0` = unlimited.                                    |
| `compliance.lockUpDuration`       | `number`           | Seconds newly minted tokens are locked before transfer. `0` = no lock-up.         |

**Returns:** `address` of the deployed token contract.

**Required role:** `DEPLOYER_ROLE`

**Errors:**

- `"Factory: empty issuerId"` — issuerId was blank
- `"Factory: zero tokenAdmin"` — tokenAdmin was zero address
- `"Factory: issuerId taken"` — issuerId already used
- `"Factory: use deployBond for BOND"` — `tokenType` was `2`; call `deployBond` instead
- `"Pausable: paused"` — factory is paused
- Access control error — caller does not have deployer permission

---

### `deployBond`

Deploy a tokenized bond — same suite as `deployToken` plus a `BondTerms` contract holding rate, tenor, coupon schedule, and face value. Always deploys a `YieldDistributor` and wires it to BondTerms. The `tokenAdmin` wallet is automatically set as the BondTerms admin and can update the yield rate for future coupons via `BondTerms.setAnnualRate()`. All other terms (maturity, face value, coupon period, etc.) are sealed at deployment and cannot change.

```
deployBond(issuerId, tokenName, tokenSymbol, issuerOnchainID, tokenAdmin, compliance, bondParams)
→ (address token, address bondTerms)
```

| Argument          | Type                   | Description                                                                                              |
| ----------------- | ---------------------- | -------------------------------------------------------------------------------------------------------- |
| `issuerId`        | `string`               | Unique identifier, e.g. `"ACME-BOND-5Y-2025"`. Cannot be reused.                                         |
| `tokenName`       | `string`               | Full bond name, e.g. `"Acme 5y 7.5% Senior Unsecured"`                                                   |
| `tokenSymbol`     | `string`               | Short ticker, e.g. `"ACMB5"`                                                                             |
| `issuerOnchainID` | `string (address)`     | Issuer's ONCHAINID. Pass zero address if not applicable.                                                 |
| `tokenAdmin`      | `string (address)`     | The wallet that will control all deployed contracts. Cannot be zero.                                     |
| `compliance`      | `ComplianceParams`     | Same shape as for `deployToken`.                                                                         |
| `bondParams`      | `BondTerms.InitParams` | Yield rate, tenor, coupon schedule, face value, callability — see [Data Structures](#10-data-structures). |

**Returns:** `(token, bondTerms)` — both addresses. Call `getDeployment(issuerId)` to retrieve registry, compliance, and yield distributor too.

**Required role:** `DEPLOYER_ROLE`

**Errors:**

- Same as `deployToken`, plus:
- `"BT: maturity <= issue"` / `"BT: zero coupon period"` / `"BT: first coupon <= issue"` / `"BT: first coupon > maturity"` / `"BT: rate > 100%"` / `"BT: zero face value"` / `"BT: zero admin"` / `"BT: tenor shorter than one coupon"` / `"BT: bad call date"` — `bondParams` failed validation. See [BondTerms](#6-bondterms).

**Important:** `bondParams.issueDate` is typically `block.timestamp` at the time of the call. All other dates must be in the future and consistent with the coupon period.

---

### `getDeployment`

Retrieve all contract addresses for an issuance by its ID.

```
getDeployment(issuerId)
→ DeploymentRecord
```

| Argument   | Type     | Description                               |
| ---------- | -------- | ----------------------------------------- |
| `issuerId` | `string` | The ID used when the issuance was created |

**Returns:** `DeploymentRecord` — see [Data Structures](#10-data-structures).

**Errors:** `"Factory: unknown issuerId"` — ID not found.

---

### `getDeploymentByIndex`

Retrieve a deployment by its sequential position (0-based).

```
getDeploymentByIndex(index)
→ DeploymentRecord
```

**Errors:** `"Factory: out of range"` — index exceeds total deployments.

---

### `totalDeployments`

```
totalDeployments()
→ number
```

Returns the total number of issuances deployed through this factory.

---

### `pause` / `unpause`

```
pause()
unpause()
```

Pauses or resumes the factory. While paused, no new deployments can be created.

**Required role:** `PAUSER_ROLE`

---

### `grantRole` / `revokeRole` / `hasRole`

```
grantRole(role, account)
revokeRole(role, account)
hasRole(role, account) → bool
```

Manage who is allowed to call restricted functions. See [Roles Reference](#9-roles-reference) for role identifiers.

**Required role for grant/revoke:** `DEFAULT_ADMIN_ROLE`

---

## 2. SecurityToken

The token contract for a specific issuance. Every mint, burn, and transfer is gated by identity verification and compliance rules.

**Address:** from `DeploymentRecord.token`.

---

### `mint`

Issue new tokens to an investor.

```
mint(to, amount)
```

| Argument | Type               | Description                                                                 |
| -------- | ------------------ | --------------------------------------------------------------------------- |
| `to`     | `string (address)` | Recipient wallet — must be registered and verified in the identity registry |
| `amount` | `BigNumber`        | Amount to mint (18 decimal places)                                          |

**Required role:** `AGENT_ROLE`

**Errors:**

- `"ST: recipient not verified"` — recipient is not KYC-verified
- `"ST: compliance rejected"` — blocked by compliance rules (cap reached, country blocked, etc.)
- `"Pausable: paused"`

---

### `burn`

Destroy tokens held by an investor.

```
burn(from, amount)
```

| Argument | Type               | Description                                                    |
| -------- | ------------------ | -------------------------------------------------------------- |
| `from`   | `string (address)` | Wallet to burn from                                            |
| `amount` | `BigNumber`        | Amount to burn — must not exceed the wallet's unfrozen balance |

**Required role:** `AGENT_ROLE`

**Errors:** `"ST: insufficient unfrozen"` — amount exceeds the transferable balance.

---

### `batchMint`

Mint tokens to multiple investors in one call.

```
batchMint(toList, amounts)
```

| Argument  | Type          | Description                                             |
| --------- | ------------- | ------------------------------------------------------- |
| `toList`  | `string[]`    | Array of recipient addresses                            |
| `amounts` | `BigNumber[]` | Corresponding amounts — must be same length as `toList` |

**Required role:** `AGENT_ROLE`

**Errors:** `"ST: length mismatch"` — arrays have different lengths.

---

### `batchBurn`

Burn tokens from multiple investors in one call.

```
batchBurn(users, amounts)
```

**Required role:** `AGENT_ROLE`

---

### `transfer`

Transfer tokens from the caller's wallet to another.

```
transfer(to, amount)
→ bool
```

**Errors:**

- `"ST: wallet frozen"` — sender or recipient is frozen
- `"ST: sender not verified"` / `"ST: recipient not verified"` — KYC check failed
- `"ST: insufficient unfrozen balance"` — sender's transferable balance is too low
- `"ST: compliance check failed"` — blocked by compliance rules
- `"Pausable: paused"`

---

### `transferFrom`

Transfer tokens on behalf of another wallet using a pre-approved allowance.

```
transferFrom(from, to, amount)
→ bool
```

Same checks as `transfer`, plus spends the allowance that `from` granted to the caller.

---

### `approve`

Grant another address permission to spend tokens on your behalf.

```
approve(spender, amount)
→ bool
```

---

### `batchTransfer`

Transfer tokens from the caller's wallet to multiple recipients in one call.

```
batchTransfer(toList, amounts)
```

Subject to the same compliance checks as `transfer` for each recipient.

**Errors:** `"ST: length mismatch"`

---

### `forcedTransfer`

Admin-initiated transfer that moves tokens regardless of standard compliance rules. Used for regulatory enforcement or error correction. Recipient still must be identity-verified.

```
forcedTransfer(from, to, amount)
→ bool
```

**Required role:** `AGENT_ROLE`

**Errors:**

- `"ST: recipient not verified"`
- `"ST: insufficient unfrozen balance"`

---

### `batchForcedTransfer`

Forced transfer for multiple wallets in one call.

```
batchForcedTransfer(fromList, toList, amounts)
```

**Required role:** `AGENT_ROLE`

---

### `recoveryAddress`

Move all tokens from a lost wallet to a new wallet belonging to the same investor. The new wallet must already be registered to the same investor identity.

```
recoveryAddress(lostWallet, newWallet, investorOnchainID)
→ bool
```

| Argument            | Type               | Description                                                                        |
| ------------------- | ------------------ | ---------------------------------------------------------------------------------- |
| `lostWallet`        | `string (address)` | The wallet that lost access                                                        |
| `newWallet`         | `string (address)` | The replacement wallet — must be verified and linked to the same investor identity |
| `investorOnchainID` | `string (address)` | The investor's identity address                                                    |

**Required role:** `AGENT_ROLE`

**Errors:**

- `"ST: zero onchainID"` — `investorOnchainID` was zero address; recovery requires a real identity reference
- `"ST: lost wallet mismatch"` — the lost wallet's registered identity does not match `investorOnchainID`
- `"ST: new wallet mismatch"` — the new wallet's registered identity does not match `investorOnchainID` (e.g. not registered, or registered to a different investor)
- `"ST: new wallet not verified"` — the new wallet is registered to the right identity but `verified` is `false`

---

### `setAddressFrozen`

Freeze or unfreeze a wallet entirely. A frozen wallet cannot send or receive tokens.

```
setAddressFrozen(user, freeze)
```

| Argument | Type               | Description                           |
| -------- | ------------------ | ------------------------------------- |
| `user`   | `string (address)` | Target wallet                         |
| `freeze` | `bool`             | `true` to freeze, `false` to unfreeze |

**Required role:** `AGENT_ROLE`

---

### `freezePartialTokens`

Lock a specific token amount in a wallet. Those tokens cannot be transferred but still show in the balance.

```
freezePartialTokens(user, amount)
```

**Required role:** `AGENT_ROLE`

**Errors:** `"ST: freeze exceeds balance"` — would exceed current balance.

---

### `unfreezePartialTokens`

Release a previously locked token amount.

```
unfreezePartialTokens(user, amount)
```

**Required role:** `AGENT_ROLE`

**Errors:** `"ST: amount exceeds frozen"`

---

### `batchSetAddressFrozen`

```
batchSetAddressFrozen(users, freeze)
```

**Required role:** `AGENT_ROLE`

---

### `batchFreezePartialTokens` / `batchUnfreezePartialTokens`

```
batchFreezePartialTokens(users, amounts)
batchUnfreezePartialTokens(users, amounts)
```

**Required role:** `AGENT_ROLE`

---

### `setIdentityRegistry`

Replace the identity registry used by this token.

```
setIdentityRegistry(address)
```

**Required role:** `DEFAULT_ADMIN_ROLE`

---

### `setCompliance`

Replace the compliance module used by this token.

```
setCompliance(address)
```

**Required role:** `DEFAULT_ADMIN_ROLE`

---

### `setOnchainID`

Update the issuer identity address stored on the token.

```
setOnchainID(address)
```

**Required role:** `DEFAULT_ADMIN_ROLE`

---

### `setBondTerms`

One-shot binding of the `BondTerms` contract to this token. Called automatically by `TokenizationFactory.deployBond` — backends will rarely call this directly. Once set, cannot be changed.

```
setBondTerms(bondTermsAddress)
```

**Required role:** `DEFAULT_ADMIN_ROLE`

**Errors:**

- `"ST: bond terms already set"`
- `"ST: zero bond terms"`

---

### `redeemAtMaturity`

Burn a single holder's tokens and pay them their principal at face value. Requires that BondTerms is set and `block.timestamp >= maturityDate`. The token contract must already hold sufficient `payoutToken` funds (issuer deposits them ahead of redemption).

```
redeemAtMaturity(holder, payoutToken)
→ BigNumber (principal paid)
```

| Argument      | Type               | Description                                                                                              |
| ------------- | ------------------ | -------------------------------------------------------------------------------------------------------- |
| `holder`      | `string (address)` | Investor wallet to redeem                                                                                |
| `payoutToken` | `string (address)` | Zero address for native currency, or ERC-20 contract address. Must match the funds the issuer deposited. |

**Computation:** `principal = balanceOf(holder) * bondTerms.faceValuePerToken() / 1e18`

**Required role:** `AGENT_ROLE`

**Errors:**

- `"ST: no bond terms"` — token has no BondTerms attached (not a bond)
- `"ST: not matured"` — `block.timestamp < bondTerms.maturityDate`
- `"ST: holder not eligible"` — compliance allowlist excludes the holder
- `"ST: zero balance"` — holder has nothing to redeem
- `"ST: zero principal"` — face value math rounded to zero
- `"ST: ETH transfer failed"` — native payout failed

**Side effect:** when `totalSupply()` reaches zero, calls `bondTerms.markPrincipalRepaid()`, sealing the bond.

---

### `batchRedeemAtMaturity`

Redeem many holders in one call. Wallets that are ineligible or hold zero tokens are silently skipped (no event for skipped). Use this for end-of-life cleanup.

```
batchRedeemAtMaturity(holders, payoutToken)
```

| Argument      | Type               | Description                |
| ------------- | ------------------ | -------------------------- |
| `holders`     | `string[]`         | Investor wallets to redeem |
| `payoutToken` | `string (address)` | Zero address or ERC-20     |

**Required role:** `AGENT_ROLE`

**Errors:** `"ST: no bond terms"`, `"ST: not matured"`.

**Side effect:** marks principal repaid on BondTerms if `totalSupply()` reaches zero by the end of the call.

---

### `pause` / `unpause`

```
pause()
unpause()
```

**Required role:** `PAUSER_ROLE`

---

### Read-only

```
balanceOf(wallet)           → BigNumber   // total balance (includes frozen)
totalSupply()               → BigNumber
allowance(owner, spender)   → BigNumber
isFrozen(wallet)            → bool
getFrozenTokens(wallet)     → BigNumber   // amount locked
identityRegistry()          → address
compliance()                → address
bondTerms()                 → address     // zero address unless deployed via deployBond
name()                      → string
symbol()                    → string
decimals()                  → number      // always 18
onchainID()                 → address
paused()                    → bool
trustedForwarder()          → address     // EIP-2771 forwarder address
isTrustedForwarder(address) → bool
```

---

## 3. IdentityRegistry

Stores the KYC status of every investor: wallet address → identity + country + verified flag. The token checks this on every transfer.

**Address:** from `DeploymentRecord.identityRegistry`.

**EIP-2771:** All `AGENT_ROLE` functions resolve the caller through `_msgSender()`. An agent wallet with no ETH can sign a `ForwardRequest` and have the relayer submit it via `TokenxForwarder.execute()`.

---

### `registerIdentity`

Register a new investor.

```
registerIdentity(wallet, onchainID, country)
```

| Argument    | Type               | Description                                                                     |
| ----------- | ------------------ | ------------------------------------------------------------------------------- |
| `wallet`    | `string (address)` | Investor's wallet address                                                       |
| `onchainID` | `string (address)` | Investor's identity address. Pass zero address if not applicable.               |
| `country`   | `number`           | ISO 3166-1 numeric country code (e.g. `566` = Nigeria, `840` = USA, `826` = UK) |

**Required role:** `AGENT_ROLE`

**Errors:**

- `"IR: zero wallet"`
- `"IR: already registered"`

---

### `deleteIdentity`

Remove an investor from the registry. Their tokens will become non-transferable.

```
deleteIdentity(wallet)
```

**Required role:** `AGENT_ROLE`

**Errors:** `"IR: not registered"`

---

### `updateCountry`

Change an investor's country code.

```
updateCountry(wallet, country)
```

**Required role:** `AGENT_ROLE`

---

### `updateIdentity`

Change an investor's identity address.

```
updateIdentity(wallet, newOnchainID)
```

**Required role:** `AGENT_ROLE`

---

### `setVerified`

Suspend or reinstate an investor without removing them. Use this when an investor needs re-KYC — set to `false` to block transfers, `true` to restore access.

```
setVerified(wallet, verified)
```

**Required role:** `AGENT_ROLE`

**Errors:** `"IR: not registered"`

---

### Read-only

```
isVerified(wallet)          → bool
identity(wallet)            → address     // onchainID
investorCountry(wallet)     → number      // ISO country code
investorCount()             → number
getInvestors(offset, limit) → address[]   // paginated list
trustedForwarder()          → address     // EIP-2771 forwarder address
isTrustedForwarder(address) → bool
```

**`getInvestors` pagination:**

| Argument | Description                     |
| -------- | ------------------------------- |
| `offset` | Start position, 0-based         |
| `limit`  | Max number of results to return |

Returns an empty array if `offset >= investorCount()`.

---

## 4. ComplianceModule

Enforces offering rules on every token movement. The token calls this automatically — your backend only needs to interact with it to adjust rules or read current state.

**Address:** from `DeploymentRecord.compliance`.

**EIP-2771:** All `COMPLIANCE_ADMIN` and `DEFAULT_ADMIN_ROLE` functions resolve the caller through `_msgSender()`. The `onlyToken` modifier keeps a raw `msg.sender` check — the token contract calls `transferred`/`created`/`destroyed` directly and never goes through the forwarder.

---

### `setMaxShareholders`

Set the maximum number of distinct token holders. Pass `0` for no limit.

```
setMaxShareholders(newMax)
```

**Required role:** `COMPLIANCE_ADMIN`

---

### `setMaxTokensPerInvestor`

Set the maximum token balance any single wallet may hold. Pass `0` for no limit.

```
setMaxTokensPerInvestor(newMax)
```

**Required role:** `COMPLIANCE_ADMIN`

---

### `setLockUpDuration`

Set how long newly minted tokens are locked (in seconds). Pass `0` to remove the lock-up.

```
setLockUpDuration(newDuration)
```

**Required role:** `COMPLIANCE_ADMIN`

---

### `blockCountry`

Block all transfers to investors in a given country.

```
blockCountry(country)
```

| Argument  | Type     | Description                     |
| --------- | -------- | ------------------------------- |
| `country` | `number` | ISO 3166-1 numeric country code |

**Required role:** `COMPLIANCE_ADMIN`

---

### `unblockCountry`

```
unblockCountry(country)
```

**Required role:** `COMPLIANCE_ADMIN`

---

### `setWalletAllowlistEnabled`

Turn the per-wallet allowlist on or off. When **off** (default), any KYC-verified wallet can hold the token. When **on**, only wallets explicitly added via `setWalletAllowed` can receive or hold tokens.

```
setWalletAllowlistEnabled(enabled)
```

| Argument  | Type   | Description                                                         |
| --------- | ------ | ------------------------------------------------------------------- |
| `enabled` | `bool` | `true` = allowlist enforced, `false` = open to all verified wallets |

**Required role:** `COMPLIANCE_ADMIN`

**Note:** Applies to **both** transfers (`canTransfer`) and yield/redemption eligibility (`canHold`). A wallet removed from the allowlist mid-tenor will not receive coupons or be redeemable at maturity until re-added.

---

### `setWalletAllowed`

Add or remove a single wallet from the allowlist. Independent of whether the allowlist is currently enabled — you can populate it before flipping the switch.

```
setWalletAllowed(wallet, allowed)
```

**Required role:** `COMPLIANCE_ADMIN`

---

### `batchSetWalletAllowed`

Set the same allowlist value for many wallets in one call.

```
batchSetWalletAllowed(wallets, allowed)
```

| Argument  | Type       | Description                              |
| --------- | ---------- | ---------------------------------------- |
| `wallets` | `string[]` | Wallets to set                           |
| `allowed` | `bool`     | `true` to add all, `false` to remove all |

**Required role:** `COMPLIANCE_ADMIN`

---

### `setCountryAllowlistMode`

Toggle whether the country list operates as an **allowlist** (only listed countries can hold) or a **denylist** (only listed countries are blocked, default).

```
setCountryAllowlistMode(enabled)
```

| Argument  | Type   | Description                                                                                                               |
| --------- | ------ | ------------------------------------------------------------------------------------------------------------------------- |
| `enabled` | `bool` | `true` = allowlist mode (use `setCountryAllowed`), `false` = denylist mode (use `blockCountry`/`unblockCountry`, default) |

**Required role:** `COMPLIANCE_ADMIN`

**Important:** When you flip to allowlist mode, the country set is initially empty — all transfers will fail until you call `setCountryAllowed` for each allowed country.

---

### `setCountryAllowed`

Add or remove a country from the country allowlist (only used when `countryAllowlistMode` is `true`).

```
setCountryAllowed(country, allowed)
```

| Argument  | Type     | Description                         |
| --------- | -------- | ----------------------------------- |
| `country` | `number` | ISO 3166-1 numeric country code     |
| `allowed` | `bool`   | `true` to permit, `false` to remove |

**Required role:** `COMPLIANCE_ADMIN`

---

### Read-only

```
canTransfer(from, to, amount)    → bool
canHold(wallet)                  → bool      // allowlist + country pass, no transfer-specific gates
token()                          → address
maxShareholders()                → number
maxTokensPerInvestor()           → number
lockUpDuration()                 → number    // seconds
shareholderCount()               → number
holderBalance(wallet)            → BigNumber
lockUpEnd(wallet)                → number    // unix timestamp — 0 if no lockup active
blockedCountries(countryCode)    → bool
walletAllowlistEnabled()         → bool
walletAllowlist(wallet)          → bool
countryAllowlistMode()           → bool
allowedCountries(countryCode)    → bool
trustedForwarder()               → address   // EIP-2771 forwarder address
isTrustedForwarder(address)      → bool
```

**`canTransfer` usage:**

- To check a standard transfer: pass both `from` and `to` as real addresses
- To simulate a mint: pass `from` as zero address
- To simulate a burn: pass `to` as zero address (always returns `true`)

**`canHold` usage:**

- Returns `true` if `wallet` passes the wallet allowlist (if enabled) and the country rules (denylist or allowlist depending on mode).
- Used internally by `YieldDistributor` and `SecurityToken.redeemAtMaturity` to decide payout eligibility.
- Does **not** consult the identity registry or freeze state — combine with `identityRegistry.isVerified(wallet)` and `securityToken.isFrozen(wallet)` for a complete picture.

---

## 5. YieldDistributor

Handles yield and dividend payouts for yield-bearing token issuances. Supports both native currency (ETH/MATIC) and stablecoin payouts.

**Address:** from `DeploymentRecord.yieldDistributor`. Only present for `tokenType = 1` (yield-bearing). Will be zero address for standard tokens.

---

### `setBondTerms`

One-shot binding of the `BondTerms` contract to this distributor. Called automatically by `TokenizationFactory.deployBond`. Backends will rarely call this directly. Once set, cannot be changed.

```
setBondTerms(bondTermsAddress)
```

**Required role:** `DEFAULT_ADMIN_ROLE`

**Errors:** `"YD: bond terms already set"`, `"YD: zero bond terms"`.

---

### `createSnapshot`

Record a snapshot of all eligible investor balances at this moment and deposit the dividend pool. Returns a snapshot ID used for all subsequent operations. **Issuer-discretionary** — caller picks `fundAmount`. For _contractually scheduled coupons on a bond_, use `createScheduledCoupon` instead.

```
createSnapshot(investors, payoutToken, fundAmount, reclaimAfter, description)
→ number (snapshotId)
```

| Argument       | Type               | Description                                                                                                                                           |
| -------------- | ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `investors`    | `string[]`         | List of investor wallet addresses to include. Build this from `identityRegistry.getInvestors()`.                                                      |
| `payoutToken`  | `string (address)` | Zero address for native currency payout, or a stablecoin contract address for ERC-20 payout                                                           |
| `fundAmount`   | `BigNumber`        | Total payout pool. For native currency: ignored — send as transaction value instead. For stablecoin: pre-approve this contract for this amount first. |
| `reclaimAfter` | `number`           | Seconds from now before unclaimed funds can be recovered by admin                                                                                     |
| `description`  | `string`           | Label for this round, e.g. `"Q1 2025 Dividend"`                                                                                                       |

**Returns:** `number` — snapshot ID. Store this — it's needed for all claim/push/reclaim calls.

**Required role:** `AGENT_ROLE`

**Stablecoin payout:** call `stablecoin.approve(yieldDistributorAddress, fundAmount)` before this call.  
**Native currency payout:** send the funds as transaction value (`msg.value`).

**Eligibility:** an investor is eligible if `identityRegistry.isVerified(inv)` is true, `securityToken.isFrozen(inv)` is false, **and** `compliance.canHold(inv)` is true (the compliance allowlist applies to payouts).

**Errors:**

- `"YD: no ETH sent"` — native payout but no value sent
- `"YD: zero fund amount"` — stablecoin payout but amount was 0
- `"YD: no eligible holders"` — none of the provided investors were eligible
- `"Pausable: paused"`

---

### `createScheduledCoupon`

Create a coupon distribution constrained by `BondTerms`. The amount per token is computed on-chain from rate, day-count, and coupon period — under- or over-paying reverts. Advances `nextCouponDate` on BondTerms. Only callable when BondTerms is bound and a coupon is due.

```
createScheduledCoupon(investors, payoutToken, reclaimAfter, description)
→ number (snapshotId)
```

| Argument       | Type               | Description                                                     |
| -------------- | ------------------ | --------------------------------------------------------------- |
| `investors`    | `string[]`         | List of investor wallets to include                             |
| `payoutToken`  | `string (address)` | Zero address for ETH or ERC-20 address (typically a stablecoin) |
| `reclaimAfter` | `number`           | Seconds from now until unclaimed funds can be reclaimed         |
| `description`  | `string`           | Label, e.g. `"Coupon 3 — Q3 2026"`                              |

**Required role:** `AGENT_ROLE`

**Funds:** the issuer must supply _exactly_ `bondTerms.couponPerToken() * eligibleSupply / 1e18`.

- **ETH:** send as `msg.value` — must equal the computed amount exactly.
- **ERC-20:** call `payoutToken.approve(yieldDistributorAddress, computedAmount)` first; no ETH allowed.

To preview the required amount: read `bondTerms.couponPerToken()`, sum eligible balances off-chain, multiply, divide by `1e18`.

**Errors:**

- `"YD: no bond terms"` — no BondTerms is bound to this distributor (call `deployBond`, not `deployToken`)
- `"YD: coupon not due"` — `bondTerms.nextCouponDate() > block.timestamp` or past maturity
- `"YD: bond defaulted"` / `"YD: bond closed"` — bond state forbids further coupons
- `"YD: no eligible holders"` — none of the provided investors were eligible
- `"YD: zero coupon"` — coupon math rounded to zero
- `"YD: wrong ETH amount"` — `msg.value != requiredFunds` for ETH payout
- `"YD: ETH not allowed"` — `msg.value > 0` for ERC-20 payout

---

### `flagDefault`

**Permissionless.** Anyone can flag the bond as defaulted once the issuer is past the grace period on a missed coupon. Once flagged, no further scheduled coupons can be created.

```
flagDefault()
```

**Required role:** none — open to all callers.

**Errors:** `"YD: no bond terms"`, `"YD: grace not breached"`.

---

### `claimYield`

An investor calls this to collect their share of a snapshot's payout.

```
claimYield(snapshotId)
```

| Argument     | Type     | Description                     |
| ------------ | -------- | ------------------------------- |
| `snapshotId` | `number` | ID returned by `createSnapshot` |

**Called by:** the investor themselves — no special role required.

**Errors:**

- `"YD: snapshot inactive"` — funds have already been reclaimed
- `"YD: already claimed"` — investor already claimed for this snapshot
- `"YD: not eligible"` — investor was frozen or de-verified after the snapshot
- `"YD: no balance at snapshot"` — investor held no tokens at snapshot time

---

### `pushYield`

Push payouts to a list of investors in one call. Wallets that are ineligible or have already claimed are silently skipped (an `InvestorSkipped` event is emitted for each skipped wallet).

```
pushYield(snapshotId, investors)
```

| Argument     | Type       | Description             |
| ------------ | ---------- | ----------------------- |
| `snapshotId` | `number`   | The snapshot to pay out |
| `investors`  | `string[]` | Wallets to pay          |

**Required role:** `AGENT_ROLE`

**Errors:** `"YD: snapshot inactive"`

---

### `reclaimUnclaimed`

Recover any unclaimed funds from a snapshot after the reclaim deadline has passed.

```
reclaimUnclaimed(snapshotId)
```

**Required role:** `DEFAULT_ADMIN_ROLE`

**Errors:**

- `"YD: already reclaimed"`
- `"YD: deadline not reached"`
- `"YD: nothing to reclaim"` — all funds were claimed

---

### `pause` / `unpause`

```
pause()
unpause()
```

**Required role:** `PAUSER_ROLE`

---

### Read-only

```
pendingYield(snapshotId, investor)  → BigNumber   // 0 if already claimed or not eligible
getSnapshot(snapshotId)             → Snapshot
snapshotCount()                     → number
claimed(snapshotId, investor)       → bool
totalClaimed(snapshotId)            → BigNumber
snapshotBalance(snapshotId, wallet) → BigNumber   // balance at snapshot time
shareToken()                        → address
identityRegistry()                  → address
compliance()                        → address
bondTerms()                         → address     // zero address unless deployed via deployBond
paused()                            → bool
```

---

## 6. BondTerms

Holds the economic terms of a tokenized bond: yield rate, tenor, coupon schedule, face value. The annual yield rate (`annualRateBps`) can be updated by the bond admin after deployment — all other terms are sealed at `initialize()` and cannot change. The only other post-init writes are three runtime flags (`nextCouponDate`, `defaulted`, `principalRepaid`) that the bound `SecurityToken` and `YieldDistributor` flip during normal lifecycle operations.

**Rate changes and old profits:** changing the rate only affects the _next_ `createScheduledCoupon` call. Past snapshots have their `totalFunds` locked at creation time and are never retroactively repriced. Every rate change is appended to the public `rateHistory` array for full auditability.

**Address:** from `DeploymentRecord.bondTerms`. Zero address for non-bond issuances.

**Deployed via:** `TokenizationFactory.deployBond` only. There is no standalone deploy path in the production flow.

---

### `setAnnualRate`

Update the yield rate for all future coupon distributions. Has no effect on snapshots already created.

```
setAnnualRate(newRateBps)
```

| Argument     | Type     | Description                                    |
| ------------ | -------- | ---------------------------------------------- |
| `newRateBps` | `number` | New annual rate in basis points. `1`–`10_000`. |

**Required role:** BondTerms `admin` (the `tokenAdmin` set at deployment).

**EIP-2771:** `setAnnualRate` resolves the caller through `_msgSender()`. The bond admin can sign a `ForwardRequest` and have the relayer pay gas. `advanceCoupon`, `markDefaulted`, and `markPrincipalRepaid` keep raw `msg.sender` — they are called by the bound contracts, not by users.

**Errors:**

- `"BT: not admin"` — caller is not the bond admin
- `"BT: bond defaulted"` — bond is in default; rate changes are blocked
- `"BT: bond closed"` — principal has been repaid; bond is over
- `"BT: zero rate"` — `newRateBps` was 0
- `"BT: rate > 100%"` — `newRateBps` exceeds `10_000`

**Side effect:** appends a `RateEntry { rateBps, effectiveAt }` to `rateHistory`. Emits `RateChanged`.

---

### Read-only

```
admin()                      → address
annualRateBps()              → number     // current rate, e.g. 500 = 5.00% APR
couponPeriodSeconds()        → number
dayCount()                   → number     // 0 = ACT_365, 1 = ACT_360, 2 = THIRTY_360
issueDate()                  → number     // unix timestamp
maturityDate()               → number     // unix timestamp
firstCouponDate()            → number
faceValuePerToken()          → BigNumber  // par value per token, scaled to 1e18
gracePeriodSeconds()         → number
callable()                   → bool
callDate()                   → number     // 0 if not callable
nextCouponDate()             → number     // advances after each scheduled coupon
defaulted()                  → bool
principalRepaid()            → bool
yieldDistributor()           → address
securityToken()              → address
couponPerToken()             → BigNumber  // computed from current annualRateBps: face * rate * period / (10000 * daysInYear * 86400)
isCouponDue()                → bool       // nextCouponDate <= block.timestamp and bond is live
isInGraceBreach()            → bool       // nextCouponDate + grace < block.timestamp
isMatured()                  → bool       // block.timestamp >= maturityDate and not yet repaid
getRateHistoryLength()       → number     // total number of rate entries (including initial)
rateHistory(index)           → { rateBps: number, effectiveAt: number }
```

**Reading rate history:**

```js
const len = await bondTerms.getRateHistoryLength();
for (let i = 0; i < len; i++) {
  const { rateBps, effectiveAt } = await bondTerms.rateHistory(i);
}
// rateHistory[0] is the initial rate set at deployment
```

---

### Mutators (consumer-only)

These are called by the bound `YieldDistributor` and `SecurityToken` only — backends should not call them directly.

```
advanceCoupon()           // only yieldDistributor — advances nextCouponDate
markDefaulted()           // only yieldDistributor or securityToken
markPrincipalRepaid()     // only securityToken — called when totalSupply reaches 0
bindConsumers(token, yieldDistributor)  // factory-only, one-shot wiring
```

---

### Validation rules

`initialize` enforces these on the supplied `InitParams`. Any failure reverts and the bond is never deployed:

| Rule                                                             | Error                                 |
| ---------------------------------------------------------------- | ------------------------------------- |
| `maturityDate > issueDate`                                       | `"BT: maturity <= issue"`             |
| `couponPeriodSeconds > 0`                                        | `"BT: zero coupon period"`            |
| `firstCouponDate > issueDate`                                    | `"BT: first coupon <= issue"`         |
| `firstCouponDate <= maturityDate`                                | `"BT: first coupon > maturity"`       |
| `annualRateBps <= 10_000`                                        | `"BT: rate > 100%"`                   |
| `faceValuePerToken > 0`                                          | `"BT: zero face value"`               |
| `admin != address(0)`                                            | `"BT: zero admin"`                    |
| `maturityDate - issueDate >= couponPeriodSeconds`                | `"BT: tenor shorter than one coupon"` |
| if `callable`: `callDate > issueDate && callDate < maturityDate` | `"BT: bad call date"`                 |

---

## 7. TokenxForwarder

EIP-2771 meta-transaction forwarder. Allows admins, agents, and investors to sign operations off-chain and have a funded **relayer** pay the gas on-chain. One forwarder serves the entire platform — its address is wired into every contract at deploy time.

**Address:** returned by `DeployFactory` script; stored in `.env` as `FORWARDER_ADDRESS`.

---

### `execute`

Submit a signed `ForwardRequest`. Only addresses with `RELAYER_ROLE` may call.

```
execute(req, signature)
→ (bool success, bytes returndata)
```

| Argument    | Type            | Description                                                   |
| ----------- | --------------- | ------------------------------------------------------------- |
| `req`       | `ForwardRequest`| See structure below                                           |
| `signature` | `bytes`         | EIP-712 ECDSA signature by `req.from` over the request struct |

**`ForwardRequest` structure:**

| Field   | Type      | Description                                                         |
| ------- | --------- | ------------------------------------------------------------------- |
| `from`  | `address` | Signer — the admin/agent/investor paying no gas                     |
| `to`    | `address` | Target contract (SecurityToken, YieldDistributor, IdentityRegistry, etc.) |
| `value` | `uint256` | ETH to forward — usually `0`                                        |
| `gas`   | `uint256` | Gas limit for the inner call                                        |
| `nonce` | `uint256` | Must equal `getNonce(from)` exactly — prevents replay               |
| `data`  | `bytes`   | Encoded function call, e.g. `token.mint.encode(investor, amount)`   |

**Required role:** `RELAYER_ROLE`

**Errors:**

- `"Forwarder: invalid sig or nonce"` — signature doesn't match or nonce is wrong
- `"Pausable: paused"` — forwarder is paused

**Note:** The return values `(success, returndata)` reflect the inner call. If `success` is `false`, the inner call reverted. The forwarder does **not** revert — check `success` in your relayer backend.

---

### `verify`

Validate a request before submitting — useful for pre-flight checks in the relayer backend.

```
verify(req, signature)
→ bool
```

Returns `true` if the signature is valid and `req.nonce == getNonce(req.from)`.

---

### `getNonce`

```
getNonce(address)
→ uint256
```

Returns the current sequential nonce for an address. Always pass this as `req.nonce` when building a request.

---

### `grantRole` / `revokeRole`

```
grantRole(RELAYER_ROLE, relayerWallet)
revokeRole(RELAYER_ROLE, relayerWallet)
```

Manage which wallets can relay transactions. Only `DEFAULT_ADMIN_ROLE` can call.

---

### `pause` / `unpause`

```
pause()
unpause()
```

Emergency stop. When paused, all `execute` calls revert. Plain calls to contracts still work.

**Required role:** `DEFAULT_ADMIN_ROLE`

---

### Signing a ForwardRequest (ethers.js v6)

```js
const domain = {
  name: "TokenxForwarder",
  version: "1",
  chainId: await provider.getNetwork().then(n => n.chainId),
  verifyingContract: FORWARDER_ADDRESS,
};

const types = {
  ForwardRequest: [
    { name: "from",  type: "address" },
    { name: "to",    type: "address" },
    { name: "value", type: "uint256" },
    { name: "gas",   type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "data",  type: "bytes"   },
  ],
};

const nonce = await forwarder.getNonce(signerAddress);

const req = {
  from:  signerAddress,
  to:    TOKEN_ADDRESS,
  value: 0n,
  gas:   200_000n,
  nonce,
  data:  token.interface.encodeFunctionData("mint", [investor, amount]),
};

const signature = await signer.signTypedData(domain, types, req);

// Relayer submits:
await forwarder.connect(relayerWallet).execute(req, signature);
```

---

## 8. Upgradeability

All five contract types (`IdentityRegistry`, `ComplianceModule`, `SecurityToken`, `YieldDistributor`, `BondTerms`) are deployed as **BeaconProxy** instances. Each type has one `UpgradeableBeacon` owned by the platform admin.

**To upgrade a contract type:**

```
1. Deploy a new implementation (inherits from the current one, only appends storage).
2. Call beacon.upgradeTo(newImpl) from the beacon owner wallet.
   → Every proxy of that type immediately delegates to the new implementation.
   → No per-token action, no migration scripts, no reinitialization needed.
```

**Beacon addresses** are printed by `make deploy-factory` and must be stored in `.env`:

```
BEACON_IDENTITY_REGISTRY=0x...
BEACON_COMPLIANCE_MODULE=0x...
BEACON_SECURITY_TOKEN=0x...
BEACON_YIELD_DISTRIBUTOR=0x...
BEACON_BOND_TERMS=0x...
```

**Makefile shortcuts:**

```bash
# Upgrade using an already-deployed new impl:
BEACON_ADDRESS=$BEACON_SECURITY_TOKEN NEW_IMPL_ADDRESS=0x... make upgrade-beacon

# Deploy a new impl and upgrade in one step:
BEACON_ADDRESS=$BEACON_SECURITY_TOKEN CONTRACT_TYPE=SecurityToken make deploy-and-upgrade-beacon
```

**Storage safety rules** — must be followed when writing a new implementation:

| Rule | Why |
|------|-----|
| Never remove or reorder existing state variables | Proxy storage slots are positional — reordering corrupts data |
| Never change the type of an existing variable | Same reason |
| Always add new variables before `__gap` | `__gap` is the reserved buffer; shrink it by the number of slots added |
| Inherited contracts must not change their storage layout | OZ is pinned to `4.9.6` — do not upgrade the library version without audit |

---

## 9. Roles Reference

Each contract manages its own access. The `tokenAdmin` address passed to `deployToken` is granted all roles on every deployed contract.

To grant a role to another address, call `contract.grantRole(ROLE_IDENTIFIER, address)` from the admin wallet.

| Contract         | Role name                                       | Who has it by default                      |
| ---------------- | ----------------------------------------------- | ------------------------------------------ |
| Factory          | `DEFAULT_ADMIN_ROLE`                            | Admin wallet passed to factory constructor |
| Factory          | `DEPLOYER_ROLE`                                 | Admin wallet                               |
| Factory          | `PAUSER_ROLE`                                   | Admin wallet                               |
| SecurityToken    | `DEFAULT_ADMIN_ROLE`                            | `tokenAdmin`                               |
| SecurityToken    | `AGENT_ROLE`                                    | `tokenAdmin`                               |
| SecurityToken    | `PAUSER_ROLE`                                   | `tokenAdmin`                               |
| IdentityRegistry | `DEFAULT_ADMIN_ROLE`                            | `tokenAdmin`                               |
| IdentityRegistry | `AGENT_ROLE`                                    | `tokenAdmin`                               |
| ComplianceModule | `DEFAULT_ADMIN_ROLE`                            | `tokenAdmin`                               |
| ComplianceModule | `COMPLIANCE_ADMIN`                              | `tokenAdmin`                               |
| YieldDistributor | `DEFAULT_ADMIN_ROLE`                            | `tokenAdmin`                               |
| YieldDistributor | `AGENT_ROLE`                                    | `tokenAdmin`                               |
| YieldDistributor | `PAUSER_ROLE`                                   | `tokenAdmin`                               |
| BondTerms        | `admin` (plain address, not AccessControl role) | `tokenAdmin` passed to `deployBond`        |

**Role identifiers for ethers.js:**

```js
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000";
const DEPLOYER_ROLE = ethers.utils.id("DEPLOYER_ROLE");
const AGENT_ROLE = ethers.utils.id("AGENT_ROLE");
const PAUSER_ROLE = ethers.utils.id("PAUSER_ROLE");
const COMPLIANCE_ADMIN = ethers.utils.id("COMPLIANCE_ADMIN");
```

---

## 10. Data Structures

### `DeploymentRecord`

Returned by `getDeployment` and `getDeploymentByIndex`.

| Field              | Type      | Description                                                        |
| ------------------ | --------- | ------------------------------------------------------------------ |
| `identityRegistry` | `address` | IdentityRegistry contract for this issuance                        |
| `compliance`       | `address` | ComplianceModule contract for this issuance                        |
| `token`            | `address` | SecurityToken contract for this issuance                           |
| `yieldDistributor` | `address` | YieldDistributor contract — zero address for standard tokens       |
| `bondTerms`        | `address` | BondTerms contract — zero address unless deployed via `deployBond` |
| `deployedBy`       | `address` | Wallet that called `deployToken` / `deployBond`                    |
| `deployedAt`       | `number`  | Unix timestamp of deployment                                       |
| `issuerId`         | `string`  | The ID used at deployment                                          |
| `tokenType`        | `number`  | `0` = standard, `1` = yield-bearing, `2` = bond                    |

---

### `ComplianceParams`

Passed as the last argument to `deployToken`.

| Field                  | Type     | Description                |
| ---------------------- | -------- | -------------------------- |
| `maxShareholders`      | `number` | `0` = unlimited            |
| `maxTokensPerInvestor` | `number` | `0` = unlimited            |
| `lockUpDuration`       | `number` | Seconds. `0` = no lock-up. |

---

### `Snapshot`

Returned by `getSnapshot(snapshotId)`.

| Field                 | Type        | Description                                                            |
| --------------------- | ----------- | ---------------------------------------------------------------------- |
| `id`                  | `number`    | Snapshot ID                                                            |
| `blockNumber`         | `number`    | Block at which snapshot was taken                                      |
| `timestamp`           | `number`    | Unix timestamp of snapshot                                             |
| `totalEligibleSupply` | `BigNumber` | Sum of all eligible holder balances at snapshot time                   |
| `totalFunds`          | `BigNumber` | Total payout pool deposited                                            |
| `payoutToken`         | `address`   | Zero address = native currency; otherwise stablecoin address           |
| `reclaimDeadline`     | `number`    | Unix timestamp after which admin can reclaim unclaimed funds           |
| `active`              | `bool`      | `false` after funds have been reclaimed                                |
| `scheduled`           | `bool`      | `true` if created by `createScheduledCoupon`; `false` if discretionary |
| `description`         | `string`    | Label set at creation                                                  |

---

### `BondTerms.InitParams`

Passed as the last argument to `deployBond`. Most fields are sealed at deployment and cannot change. The `annualRateBps` field sets the _initial_ rate; it can later be updated via `BondTerms.setAnnualRate()`.

> **Note:** the `admin` field does not need to be set manually — `TokenizationFactory.deployBond` automatically injects `tokenAdmin` as the bond admin before calling `initialize`. If calling `BondTerms.initialize` directly (non-factory path), you must supply it.

| Field                 | Type        | Description                                                                                                                                                                                                                                                                                 |
| --------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `annualRateBps`       | `number`    | Initial annual coupon rate in basis points. `500` = 5.00%, `1200` = 12.00%. Capped at `10_000` (100%). Updatable post-deploy via `setAnnualRate`.                                                                                                                                           |
| `couponPeriodSeconds` | `number`    | Seconds between coupons. `7_776_000` = 90 days, `15_552_000` = 180 days. **Sealed.**                                                                                                                                                                                                        |
| `dayCount`            | `number`    | `0` = ACT_365, `1` = ACT_360, `2` = THIRTY_360. **Sealed.**                                                                                                                                                                                                                                 |
| `issueDate`           | `number`    | Unix timestamp of issuance. Typically `block.timestamp` at deployment. **Sealed.**                                                                                                                                                                                                          |
| `maturityDate`        | `number`    | Unix timestamp of maturity. Must be strictly after `issueDate`. **Sealed.**                                                                                                                                                                                                                 |
| `firstCouponDate`     | `number`    | First coupon payment date. Can be shorter or longer than one period. **Sealed.**                                                                                                                                                                                                            |
| `faceValuePerToken`   | `BigNumber` | Par value paid per token at maturity. Formula: `principal = balance * faceValuePerToken / 1e18`. Must be denominated in the **payout token's decimals**: for USDC (6 decimals), `$100 face` → `100 * 10**6`; for an 18-decimal stablecoin or ETH, `$100 face` → `100 * 10**18`. **Sealed.** |
| `gracePeriodSeconds`  | `number`    | Seconds after a missed coupon before `flagDefault()` is allowed. `0` = immediate default. **Sealed.**                                                                                                                                                                                       |
| `callable`            | `bool`      | `true` if the issuer reserves the right to redeem early (off-chain disclosure only). **Sealed.**                                                                                                                                                                                            |
| `callDate`            | `number`    | Earliest call date if `callable` is true. Must satisfy `issueDate < callDate < maturityDate`. **Sealed.**                                                                                                                                                                                   |
| `admin`               | `address`   | Address allowed to call `setAnnualRate`. Auto-injected by the factory — do not set manually when using `deployBond`.                                                                                                                                                                        |

---

## 11. Events Reference

Listen to these events to track activity in your backend.

### TokenxForwarder

| Event             | When fired                                   | Key fields                        |
| ----------------- | -------------------------------------------- | --------------------------------- |
| `MetaTxExecuted`  | A signed request was forwarded on-chain      | `relayer`, `signer`, `to`, `success` |

### TokenizationFactory

| Event           | When fired                    | Key fields                                                                                                        |
| --------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `TokenDeployed` | A new token suite is deployed | `issuerId`, `tokenType`, `token`, `identityRegistry`, `compliance`, `yieldDistributor`, `bondTerms`, `deployedBy` |

### SecurityToken

| Event                   | When fired                                             | Key fields                                     |
| ----------------------- | ------------------------------------------------------ | ---------------------------------------------- |
| `Transfer`              | Any token movement (mint, burn, transfer)              | `from`, `to`, `value`                          |
| `Approval`              | Allowance set                                          | `owner`, `spender`, `value`                    |
| `AddressFrozen`         | Wallet frozen or unfrozen                              | `userAddress`, `isFrozen`                      |
| `TokensFrozen`          | Partial tokens locked                                  | `userAddress`, `amount`                        |
| `TokensUnfrozen`        | Partial tokens released                                | `userAddress`, `amount`                        |
| `RecoverySuccess`       | Wallet recovery completed                              | `lostWallet`, `newWallet`, `investorOnchainID` |
| `IdentityRegistryAdded` | Registry address updated                               | `identityRegistry`                             |
| `ComplianceAdded`       | Compliance address updated                             | `compliance`                                   |
| `BondTermsBound`        | Bond terms wired to this token (one-time, deploy-time) | `bondTerms`                                    |
| `PrincipalRedeemed`     | A holder redeemed principal at maturity                | `investor`, `tokenAmount`, `principalAmount`   |

### IdentityRegistry

| Event                | When fired                                  | Key fields                    |
| -------------------- | ------------------------------------------- | ----------------------------- |
| `IdentityRegistered` | New investor registered or identity updated | `investorAddress`, `identity` |
| `IdentityRemoved`    | Investor deleted                            | `investorAddress`, `identity` |
| `CountryUpdated`     | Country code changed                        | `investorAddress`, `country`  |
| `InvestorVerified`   | Verified flag toggled                       | `investorAddress`, `verified` |

### ComplianceModule

| Event                         | When fired                                         | Key fields                   |
| ----------------------------- | -------------------------------------------------- | ---------------------------- |
| `MaxShareholdersUpdated`      | Cap changed                                        | `oldMax`, `newMax`           |
| `MaxTokensPerInvestorUpdated` | Per-investor cap changed                           | `oldMax`, `newMax`           |
| `LockUpDurationUpdated`       | Lock-up duration changed                           | `oldDuration`, `newDuration` |
| `CountryBlocked`              | Country added to block list                        | `country`                    |
| `CountryUnblocked`            | Country removed from block list                    | `country`                    |
| `WalletAllowlistEnabled`      | Wallet allowlist toggled on/off                    | `enabled`                    |
| `WalletAllowlisted`           | Wallet added to or removed from allowlist          | `wallet`, `allowed`          |
| `CountryAllowlistModeSet`     | Country mode flipped between allowlist/denylist    | `enabled`                    |
| `CountryAllowed`              | Country added to or removed from country allowlist | `country`, `allowed`         |

### YieldDistributor

| Event                    | When fired                                                   | Key fields                                                        |
| ------------------------ | ------------------------------------------------------------ | ----------------------------------------------------------------- |
| `SnapshotCreated`        | New snapshot taken (discretionary or scheduled)              | `snapshotId`, `blockNumber`, `totalEligibleSupply`, `description` |
| `ScheduledCouponCreated` | A bond coupon snapshot is created                            | `snapshotId`, `couponPerToken`, `couponDate`                      |
| `YieldDeposited`         | Funds deposited for a snapshot                               | `snapshotId`, `amount`, `payoutToken`                             |
| `YieldClaimed`           | Investor pulled their payout                                 | `snapshotId`, `investor`, `amount`                                |
| `YieldPushed`            | Agent pushed payout to investor                              | `snapshotId`, `investor`, `amount`                                |
| `InvestorSkipped`        | Investor skipped during push                                 | `snapshotId`, `investor`, `reason`                                |
| `UnclaimedReclaimed`     | Admin reclaimed unclaimed funds                              | `snapshotId`, `amount`                                            |
| `BondTermsBound`         | Bond terms wired to this distributor (one-time, deploy-time) | `bondTerms`                                                       |
| `IssuerDefaulted`        | `flagDefault()` flipped the bond into defaulted state        | `atTimestamp`                                                     |

### BondTerms

| Event             | When fired                                               | Key fields                                                                                                              |
| ----------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `TermsSealed`     | At deployment — initial bond economics emitted in full   | `annualRateBps`, `couponPeriodSeconds`, `dayCount`, `issueDate`, `maturityDate`, `firstCouponDate`, `faceValuePerToken` |
| `RateChanged`     | Admin updates the annual yield rate                      | `oldRateBps`, `newRateBps`, `effectiveAt`                                                                               |
| `ConsumersBound`  | Token + distributor wired (one-time, by factory)         | `securityToken`, `yieldDistributor`                                                                                     |
| `CouponAdvanced`  | `nextCouponDate` rolled forward after a scheduled coupon | `previousCouponDate`, `newNextCouponDate`                                                                               |
| `Defaulted`       | Bond marked defaulted                                    | `atTimestamp`                                                                                                           |
| `PrincipalRepaid` | Bond closed after final redemption                       | `atTimestamp`                                                                                                           |

---

## 12. Integration Checklist

### Launch a new token issuance (standard or yield-bearing)

```
1. factory.deployToken(tokenType, ...)        // tokenType 0 or 1
2. Save DeploymentRecord from factory.getDeployment(issuerId)
3. Store all four contract addresses against the issuerId in your DB
```

### Launch a bond issuance

```
1. Compose bondParams:
   {
     annualRateBps:        500,                   // 5.00% APR (initial rate — can be changed later)
     couponPeriodSeconds:  90 days,               // quarterly — sealed at deploy
     dayCount:             0,                     // ACT_365 — sealed at deploy
     issueDate:            block.timestamp,
     maturityDate:         block.timestamp + 5 * 365 days,
     firstCouponDate:      block.timestamp + 90 days,
     faceValuePerToken:    100 * 10**6,           // $100 par per token, USDC-scaled (6 dec)
     gracePeriodSeconds:   7 days,
     callable:             false,
     callDate:             0,
     // admin: auto-injected by factory from tokenAdmin — do not set manually
   }
   // For an 18-decimal payout token (DAI, ETH), use 100 * 10**18 instead.
2. factory.deployBond(issuerId, name, symbol, issuerOnchainID, tokenAdmin, compliance, bondParams)
   → returns (tokenAddress, bondTermsAddress)
3. Store all five contract addresses against the issuerId in your DB
4. Tenor, coupon period, face value, and day-count are sealed — only annualRateBps can change
```

### Update the yield rate on a live bond

```
// Only the tokenAdmin (bond admin) can do this.
// Safe to call at any time before default or final redemption.
// Does NOT affect past snapshots — only the next createScheduledCoupon call.

1. bondTerms.setAnnualRate(newRateBps)
   // e.g. newRateBps = 700 to change from 5% to 7%
2. Verify: await bondTerms.annualRateBps() === newRateBps
3. Check history: await bondTerms.getRateHistoryLength()
   // rateHistory(i) → { rateBps, effectiveAt } for each change
```

### Onboard an investor

```
1. identityRegistry.registerIdentity(wallet, onchainID, country)
   — or —
   identityRegistry.registerIdentity(wallet, zeroAddress, country)  // if no onchainID
```

### Issue tokens to an investor

```
1. Confirm identityRegistry.isVerified(wallet) === true
2. Optionally check complianceModule.canTransfer(zeroAddress, wallet, amount)
3. securityToken.mint(wallet, amount)
```

### Check if a transfer is allowed before submitting

```
1. identityRegistry.isVerified(from) && identityRegistry.isVerified(to)
2. complianceModule.canTransfer(from, to, amount)
3. securityToken.balanceOf(from) - securityToken.getFrozenTokens(from) >= amount
4. !securityToken.isFrozen(from) && !securityToken.isFrozen(to)
```

### Distribute yield (yield-bearing tokens only)

```
1. addresses = identityRegistry.getInvestors(0, investorCount)
   — paginate if count is large —
2. Approve stablecoin spend OR prepare native currency value
3. yieldDistributor.createSnapshot(addresses, payoutToken, amount, deadline, label)
   → save snapshotId
4a. Let investors self-claim: yieldDistributor.claimYield(snapshotId)
4b. Or push to all:          yieldDistributor.pushYield(snapshotId, addresses)
5. After deadline:           yieldDistributor.reclaimUnclaimed(snapshotId)  // if needed
```

### Suspend an investor (pending re-KYC)

```
identityRegistry.setVerified(wallet, false)
// transfers blocked immediately
// re-enable:
identityRegistry.setVerified(wallet, true)
```

### Freeze a wallet (regulatory hold)

```
securityToken.setAddressFrozen(wallet, true)
// or freeze only a portion:
securityToken.freezePartialTokens(wallet, amount)
```

### Pay a scheduled bond coupon

```
1. Read bondTerms.isCouponDue()                       // false → don't call yet
   Read bondTerms.couponPerToken()                    // per-token coupon amount
2. addresses  = identityRegistry.getInvestors(0, n)
   eligible   = addresses.filter(canHold && isVerified && !frozen)
   required   = bondTerms.couponPerToken() * sum(balanceOf(eligible)) / 1e18
3. stablecoin.approve(yieldDistributor, required)    // or send ETH as msg.value
4. yieldDistributor.createScheduledCoupon(addresses, payoutToken, deadline, label)
   → returns snapshotId; advances bondTerms.nextCouponDate by couponPeriodSeconds
5. Pay out via claimYield / pushYield as for any snapshot
```

### Redeem principal at maturity

```
1. Wait until bondTerms.maturityDate is reached (bondTerms.isMatured() === true)
2. Compute total principal off-chain:
     principal = sum(balanceOf(holder) * bondTerms.faceValuePerToken()) / 1e18
3. Issuer transfers principal funds into the SecurityToken contract
   (direct ERC-20 transfer or send ETH — the token's receive() accepts it)
4. agent → securityToken.batchRedeemAtMaturity(holders, payoutToken)
   // each holder's tokens are burned, principal is paid out
   // when totalSupply hits zero, the bond auto-closes (PrincipalRepaid event)
```

### Flag an issuer default

```
// Permissionless — any wallet can call once grace has elapsed past a missed coupon
yieldDistributor.flagDefault()
// After this, createScheduledCoupon reverts with "YD: bond defaulted"
```

### Restrict the wallet allowlist

```
1. complianceModule.batchSetWalletAllowed([w1, w2, w3, ...], true)   // populate first
2. complianceModule.setWalletAllowlistEnabled(true)                  // then turn on
// Removing a wallet:
complianceModule.setWalletAllowed(walletToRemove, false)
// Disabling the allowlist entirely:
complianceModule.setWalletAllowlistEnabled(false)
```

### Restrict countries via allowlist mode

```
// Default is denylist mode (blockCountry / unblockCountry).
// To switch to allowlist mode:
1. complianceModule.setCountryAllowed(566, true)   // Nigeria
   complianceModule.setCountryAllowed(826, true)   // UK
2. complianceModule.setCountryAllowlistMode(true)  // flip last — empty allowlist would block everyone
// To switch back to denylist:
complianceModule.setCountryAllowlistMode(false)
```

---

### Submit a gasless meta-transaction (EIP-2771)

```js
// Works for any AGENT_ROLE, DEFAULT_ADMIN_ROLE, COMPLIANCE_ADMIN, or investor operation.

const nonce = await forwarder.getNonce(signerAddress);

const req = {
  from:  signerAddress,
  to:    TOKEN_ADDRESS,          // or IDENTITY_REGISTRY_ADDRESS, etc.
  value: 0n,
  gas:   200_000n,
  nonce,
  data:  token.interface.encodeFunctionData("mint", [investor, amount]),
};

// Signer signs (no ETH needed):
const signature = await signer.signTypedData(domain, types, req);

// Relayer submits and pays gas:
const [success] = await forwarder.connect(relayerWallet).execute.staticCall(req, signature);
if (!success) throw new Error("Inner call reverted");
await forwarder.connect(relayerWallet).execute(req, signature);
```

---

### Upgrade a contract type (platform admin)

```
// Example: upgrade SecurityToken with a new implementation.
// All existing token proxies get the new logic instantly.

1. Deploy new implementation:
     forge create src/SecurityTokenV2.sol:SecurityTokenV2 --account admin

2. Upgrade the beacon (via Makefile):
     BEACON_ADDRESS=$BEACON_SECURITY_TOKEN \
     NEW_IMPL_ADDRESS=<new-impl-address> \
     make upgrade-beacon NETWORK=base-sepolia

   Or in one step (deploy + upgrade):
     BEACON_ADDRESS=$BEACON_SECURITY_TOKEN \
     CONTRACT_TYPE=SecurityToken \
     make deploy-and-upgrade-beacon NETWORK=base-sepolia

3. Verify: existing proxies now return new logic.
   New proxies deployed via factory also use the new impl automatically.
```

