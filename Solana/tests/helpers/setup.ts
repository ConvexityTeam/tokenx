/**
 * Shared test setup, PDA helpers, and fixture factories.
 *
 * Every test file imports from here so account derivation is consistent
 * and key assertions about program state are co-located.
 */
import * as anchor from "@coral-xyz/anchor";
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  LAMPORTS_PER_SOL,
} from "@solana/web3.js";
import {
  TOKEN_2022_PROGRAM_ID,
  getAssociatedTokenAddressSync,
  createAssociatedTokenAccountInstruction,
  getMint,
} from "@solana/spl-token";
import { Program, BN } from "@coral-xyz/anchor";
import { assert } from "chai";

// ── Seeds (must match programs/tokenx/src/constants.rs) ─────────────────────
export const SEED_FACTORY           = Buffer.from("factory");
export const SEED_SUITE             = Buffer.from("suite");
export const SEED_MINT              = Buffer.from("mint");
export const SEED_IDENTITY_REGISTRY = Buffer.from("identity_registry");
export const SEED_INVESTOR_IDENTITY = Buffer.from("identity");
export const SEED_COMPLIANCE        = Buffer.from("compliance");
export const SEED_HOLDER_STATE      = Buffer.from("holder");
export const SEED_COUNTRY_RULE      = Buffer.from("country_rule");
export const SEED_YIELD_DIST        = Buffer.from("yield_dist");
export const SEED_SNAPSHOT          = Buffer.from("snapshot");
export const SEED_CLAIM_RECORD      = Buffer.from("claim");
export const SEED_BOND_TERMS        = Buffer.from("bond_terms");

// ── PDA derivation helpers ───────────────────────────────────────────────────

export function factoryPDA(programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync([SEED_FACTORY], programId);
}

export function suitePDA(issuerId: string, programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_SUITE, Buffer.from(issuerId)],
    programId
  );
}

export function mintPDA(issuerId: string, programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_MINT, Buffer.from(issuerId)],
    programId
  );
}

export function identityRegistryPDA(suite: PublicKey, programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_IDENTITY_REGISTRY, suite.toBuffer()],
    programId
  );
}

export function investorIdentityPDA(
  suite: PublicKey,
  wallet: PublicKey,
  programId: PublicKey
): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_INVESTOR_IDENTITY, suite.toBuffer(), wallet.toBuffer()],
    programId
  );
}

export function compliancePDA(suite: PublicKey, programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_COMPLIANCE, suite.toBuffer()],
    programId
  );
}

export function holderStatePDA(
  suite: PublicKey,
  wallet: PublicKey,
  programId: PublicKey
): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_HOLDER_STATE, suite.toBuffer(), wallet.toBuffer()],
    programId
  );
}

export function countryRulePDA(
  suite: PublicKey,
  country: number,
  programId: PublicKey
): [PublicKey, number] {
  const countryBuf = Buffer.alloc(2);
  countryBuf.writeUInt16LE(country);
  return PublicKey.findProgramAddressSync(
    [SEED_COUNTRY_RULE, suite.toBuffer(), countryBuf],
    programId
  );
}

export function yieldDistPDA(suite: PublicKey, programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_YIELD_DIST, suite.toBuffer()],
    programId
  );
}

export function snapshotPDA(
  yieldDist: PublicKey,
  snapshotId: bigint,
  programId: PublicKey
): [PublicKey, number] {
  const idBuf = Buffer.alloc(8);
  idBuf.writeBigUInt64LE(snapshotId);
  return PublicKey.findProgramAddressSync(
    [SEED_SNAPSHOT, yieldDist.toBuffer(), idBuf],
    programId
  );
}

export function claimRecordPDA(
  snapshot: PublicKey,
  wallet: PublicKey,
  programId: PublicKey
): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_CLAIM_RECORD, snapshot.toBuffer(), wallet.toBuffer()],
    programId
  );
}

export function bondTermsPDA(suite: PublicKey, programId: PublicKey): [PublicKey, number] {
  return PublicKey.findProgramAddressSync(
    [SEED_BOND_TERMS, suite.toBuffer()],
    programId
  );
}

// ── Token types (match Rust enum) ─────────────────────────────────────────────
export const TokenType = {
  Security:     { security:     {} },
  YieldBearing: { yieldBearing: {} },
  Bond:         { bond:         {} },
};

export const DayCount = {
  Act365:    { act365:    {} },
  Act360:    { act360:    {} },
  Thirty360: { thirty360: {} },
};

// ── Default compliance params ─────────────────────────────────────────────────
export const ZERO_COMPLIANCE = {
  maxShareholders:       new BN(0),
  maxTokensPerInvestor:  new BN(0),
  lockupDuration:        new BN(0),
};

// ── Default bond params (far-future dates for non-time-sensitive tests) ───────
export const now = () => Math.floor(Date.now() / 1000);

export function defaultBondParams(overrides: Partial<{
  annualRateBps:     number;
  couponPeriodSecs:  number;
  issueDate:         number;
  maturityDate:      number;
  firstCouponDate:   number;
  faceValuePerToken: BN;
  gracePeriodSecs:   number;
  callable:          boolean;
  callDate:          number;
}> = {}) {
  const base = now();
  return {
    annualRateBps:     500,
    couponPeriodSecs:  new BN(7_776_000),          // 90 days
    dayCount:          DayCount.Act365,
    issueDate:         new BN(base),
    maturityDate:      new BN(base + 31_536_000),  // +1 year
    firstCouponDate:   new BN(base + 7_776_000),   // +90 days
    faceValuePerToken: new BN(1_000_000),           // 1 USDC (6 dec)
    gracePeriodSecs:   new BN(604_800),             // 7 days
    callable:          false,
    callDate:          new BN(0),
    ...overrides,
  };
}

// ── Airdrop helper ────────────────────────────────────────────────────────────
export async function airdrop(
  connection: Connection,
  pubkey: PublicKey,
  sol = 10
): Promise<void> {
  const sig = await connection.requestAirdrop(pubkey, sol * LAMPORTS_PER_SOL);
  await connection.confirmTransaction(sig, "confirmed");
}

// ── Error assertion helpers ───────────────────────────────────────────────────

/** Assert that a transaction fails with an anchor error matching `codeOrMsg`. */
export async function assertFails(
  promise: Promise<unknown>,
  codeOrMsg: string | RegExp
): Promise<void> {
  try {
    await promise;
    assert.fail("Expected transaction to fail but it succeeded");
  } catch (err: any) {
    const msg: string =
      err?.error?.errorMessage ??
      err?.message ??
      err?.toString() ??
      "";
    if (typeof codeOrMsg === "string") {
      assert.include(msg, codeOrMsg, `Expected error "${codeOrMsg}" but got: ${msg}`);
    } else {
      assert.match(msg, codeOrMsg, `Error did not match ${codeOrMsg}: ${msg}`);
    }
  }
}

/** Assert a number field equals expected value (handles BN and number). */
export function assertEq(actual: BN | number, expected: number, label = ""): void {
  const a = actual instanceof BN ? actual.toNumber() : actual;
  assert.equal(a, expected, label);
}

// ── Suite fixture ─────────────────────────────────────────────────────────────

export interface SuiteFixture {
  issuerId:         string;
  suite:            PublicKey;
  mint:             PublicKey;
  identityRegistry: PublicKey;
  compliance:       PublicKey;
  yieldDist:        PublicKey;
  bondTerms:        PublicKey;
  admin:            Keypair;
  agent:            Keypair;
  pauser:           Keypair;
}

/**
 * Create a minimal security suite fixture.
 * Returns the PDA addresses and role keypairs without executing any instructions.
 */
export function buildSuiteFixture(
  issuerId: string,
  programId: PublicKey,
  admin: Keypair
): SuiteFixture {
  const [suite]            = suitePDA(issuerId, programId);
  const [mint]             = mintPDA(issuerId, programId);
  const [identityRegistry] = identityRegistryPDA(suite, programId);
  const [compliance]       = compliancePDA(suite, programId);
  const [yieldDist]        = yieldDistPDA(suite, programId);
  const [bondTerms]        = bondTermsPDA(suite, programId);

  return {
    issuerId,
    suite,
    mint,
    identityRegistry,
    compliance,
    yieldDist,
    bondTerms,
    admin,
    agent:  admin,   // admin == agent == pauser by default (matches on-chain initialize)
    pauser: admin,
  };
}

/**
 * Derive all account addresses for one investor in a suite.
 */
export function investorAccounts(
  fixture: SuiteFixture,
  wallet: PublicKey,
  programId: PublicKey
) {
  const [investorIdentity] = investorIdentityPDA(fixture.suite, wallet, programId);
  const [holderState]      = holderStatePDA(fixture.suite, wallet, programId);
  const investorAta        = getAssociatedTokenAddressSync(
    fixture.mint,
    wallet,
    false,
    TOKEN_2022_PROGRAM_ID
  );
  return { investorIdentity, holderState, investorAta };
}

// ── Solana-specific reentrancy note ───────────────────────────────────────────
//
// Solana's runtime prevents same-program reentrancy: if instruction A calls
// instruction B via CPI, B cannot re-invoke A in the same call chain.
// The runtime enforces this at the bpf level (AccountNotRentExempt /
// InvalidReentrancy errors).  Tests verify this boundary by attempting
// nested CPIs that would require reentrancy and asserting they fail.
