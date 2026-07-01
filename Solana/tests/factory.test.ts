/**
 * Factory tests
 *
 * Coverage:
 *   ✔ initialize_factory — happy path
 *   ✔ initialize_factory — double init (account already exists)
 *   ✔ pause_factory      — admin can pause / unpause
 *   ✔ pause_factory      — non-admin rejected
 *   ✔ initialize_suite   — rejected when factory is paused
 *   ✔ initialize_suite   — SECURITY, YIELD_BEARING happy paths
 *   ✔ initialize_suite   — duplicate issuer ID rejected
 *   ✔ initialize_suite   — empty issuer ID rejected
 *   ✔ initialize_bond_suite — happy path
 *   ✔ initialize_bond_suite — bad bond params rejected (maturity ≤ issue, zero rate, etc.)
 *   ✔ total_deployments  — increments on each successful deploy
 *
 * Access-control matrix:
 *   Signer          | initialize_factory | pause_factory | initialize_suite
 *   ────────────────|────────────────────|───────────────|─────────────────
 *   factory admin   |        N/A         |     PASS      |      PASS
 *   random signer   |       PASS(once)   |     FAIL      |      PASS (deployer)
 *   non-admin       |        N/A         |     FAIL      |      N/A
 */
import * as anchor from "@coral-xyz/anchor";
import { Keypair, SystemProgram } from "@solana/web3.js";
import { TOKEN_2022_PROGRAM_ID } from "@solana/spl-token";
import { Program, BN } from "@coral-xyz/anchor";
import { assert } from "chai";
import { Tokenx } from "../target/types/tokenx";
import {
  factoryPDA,
  suitePDA,
  mintPDA,
  identityRegistryPDA,
  compliancePDA,
  yieldDistPDA,
  bondTermsPDA,
  buildSuiteFixture,
  ZERO_COMPLIANCE,
  defaultBondParams,
  TokenType,
  assertFails,
  assertEq,
  airdrop,
  now,
} from "./helpers/setup";

describe("Factory", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program   = anchor.workspace.Tokenx as Program<Tokenx>;
  const programId = program.programId;
  const conn      = provider.connection;

  // Keypairs
  const admin        = Keypair.generate();
  const nonAdmin     = Keypair.generate();
  const deployer     = Keypair.generate();

  const [factory, factoryBump] = factoryPDA(programId);

  before(async () => {
    await Promise.all([
      airdrop(conn, admin.publicKey),
      airdrop(conn, nonAdmin.publicKey),
      airdrop(conn, deployer.publicKey),
    ]);
  });

  // ── A: Happy paths ─────────────────────────────────────────────────────────

  it("A1: initializes the factory PDA", async () => {
    await program.methods
      .ixInitializeFactory()
      .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin])
      .rpc();

    const state = await program.account.factory.fetch(factory);
    assert.equal(state.admin.toBase58(), admin.publicKey.toBase58());
    assert.equal(state.paused, false);
    assertEq(state.totalDeployments, 0, "deployments");
    assert.equal(state.bump, factoryBump);
  });

  it("A2: admin can pause and unpause the factory", async () => {
    await program.methods
      .ixPauseFactory(true)
      .accounts({ factory, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    let state = await program.account.factory.fetch(factory);
    assert.equal(state.paused, true);

    await program.methods
      .ixPauseFactory(false)
      .accounts({ factory, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    state = await program.account.factory.fetch(factory);
    assert.equal(state.paused, false);
  });

  it("A3: deploys a SECURITY suite and increments total_deployments", async () => {
    const issuerId = "SECURITY-SUITE-001";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);

    await program.methods
      .ixInitializeSuite(issuerId, TokenType.Security, ZERO_COMPLIANCE, 6)
      .accounts({
        factory,
        suite:            fixture.suite,
        mint:             fixture.mint,
        identityRegistry: fixture.identityRegistry,
        compliance:       fixture.compliance,
        yieldDistributor: null,
        admin:            admin.publicKey,
        deployer:         deployer.publicKey,
        tokenProgram:     TOKEN_2022_PROGRAM_ID,
        systemProgram:    SystemProgram.programId,
      })
      .signers([deployer])
      .rpc();

    const factoryState = await program.account.factory.fetch(factory);
    assertEq(factoryState.totalDeployments, 1, "deployments after SECURITY");

    const suiteState = await program.account.tokenSuite.fetch(fixture.suite);
    assert.equal(suiteState.issuerId, issuerId);
    assert.deepEqual(suiteState.tokenType, TokenType.Security);
    assert.equal(suiteState.paused, false);
    assert.equal(suiteState.admin.toBase58(), admin.publicKey.toBase58());
  });

  it("A4: deploys a YIELD_BEARING suite with YieldDistributor PDA", async () => {
    const issuerId = "YIELD-SUITE-001";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);

    await program.methods
      .ixInitializeSuite(issuerId, TokenType.YieldBearing, ZERO_COMPLIANCE, 6)
      .accounts({
        factory,
        suite:            fixture.suite,
        mint:             fixture.mint,
        identityRegistry: fixture.identityRegistry,
        compliance:       fixture.compliance,
        yieldDistributor: fixture.yieldDist,
        admin:            admin.publicKey,
        deployer:         deployer.publicKey,
        tokenProgram:     TOKEN_2022_PROGRAM_ID,
        systemProgram:    SystemProgram.programId,
      })
      .signers([deployer])
      .rpc();

    const factoryState = await program.account.factory.fetch(factory);
    assertEq(factoryState.totalDeployments, 2, "deployments after YIELD");

    const suiteState = await program.account.tokenSuite.fetch(fixture.suite);
    assert.deepEqual(suiteState.tokenType, TokenType.YieldBearing);
    assert.notEqual(suiteState.yieldDistributor.toBase58(), SystemProgram.programId.toBase58());

    const ydState = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    assertEq(ydState.snapshotCount, 0);
  });

  it("A5: deploys a BOND suite with BondTerms PDA", async () => {
    const issuerId = "BOND-SUITE-001";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);
    const bond     = defaultBondParams();

    await program.methods
      .ixInitializeBondSuite(issuerId, ZERO_COMPLIANCE, bond, 6)
      .accounts({
        factory,
        suite:            fixture.suite,
        mint:             fixture.mint,
        identityRegistry: fixture.identityRegistry,
        compliance:       fixture.compliance,
        yieldDistributor: fixture.yieldDist,
        bondTerms:        fixture.bondTerms,
        admin:            admin.publicKey,
        deployer:         deployer.publicKey,
        tokenProgram:     TOKEN_2022_PROGRAM_ID,
        systemProgram:    SystemProgram.programId,
      })
      .signers([deployer])
      .rpc();

    const factoryState = await program.account.factory.fetch(factory);
    assertEq(factoryState.totalDeployments, 3, "deployments after BOND");

    const btState = await program.account.bondTerms.fetch(fixture.bondTerms);
    assert.equal(btState.annualRateBps, 500);
    assert.equal(btState.defaulted, false);
    assert.equal(btState.principalRepaid, false);
  });

  // ── B: Rejection / sad paths ───────────────────────────────────────────────

  it("B1: double-initializing the factory fails (account already exists)", async () => {
    await assertFails(
      program.methods
        .ixInitializeFactory()
        .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
        .signers([admin])
        .rpc(),
      /already in use/i
    );
  });

  it("B2: non-admin cannot pause the factory", async () => {
    await assertFails(
      program.methods
        .ixPauseFactory(true)
        .accounts({ factory, admin: nonAdmin.publicKey })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B3: deploying a suite when factory is paused fails", async () => {
    // Pause factory.
    await program.methods
      .ixPauseFactory(true)
      .accounts({ factory, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    const issuerId = "SHOULD-NOT-EXIST";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);

    await assertFails(
      program.methods
        .ixInitializeSuite(issuerId, TokenType.Security, ZERO_COMPLIANCE, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: null,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      "FactoryPaused"
    );

    // Unpause for subsequent tests.
    await program.methods
      .ixPauseFactory(false)
      .accounts({ factory, admin: admin.publicKey })
      .signers([admin])
      .rpc();
  });

  it("B4: duplicate issuer ID is rejected", async () => {
    const issuerId = "SECURITY-SUITE-001"; // already deployed in A3
    const fixture  = buildSuiteFixture(issuerId, programId, admin);

    await assertFails(
      program.methods
        .ixInitializeSuite(issuerId, TokenType.Security, ZERO_COMPLIANCE, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: null,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      /already in use/i // PDA already initialized
    );
  });

  it("B5: empty issuer ID is rejected", async () => {
    const issuerId = "";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);

    await assertFails(
      program.methods
        .ixInitializeSuite(issuerId, TokenType.Security, ZERO_COMPLIANCE, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: null,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      "EmptyIssuerId"
    );
  });

  it("B6: bond suite rejected when maturity ≤ issue date", async () => {
    const issuerId = "BAD-BOND-001";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);
    const base     = now();
    const badBond  = defaultBondParams({
      issueDate:    base + 1000,
      maturityDate: base,        // maturity BEFORE issue
    });

    await assertFails(
      program.methods
        .ixInitializeBondSuite(issuerId, ZERO_COMPLIANCE, badBond, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: fixture.yieldDist,
          bondTerms:        fixture.bondTerms,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      "BadMaturityDate"
    );
  });

  it("B7: bond suite rejected when annual rate is 0", async () => {
    const issuerId = "BAD-BOND-002";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);
    const badBond  = defaultBondParams({ annualRateBps: 0 });

    await assertFails(
      program.methods
        .ixInitializeBondSuite(issuerId, ZERO_COMPLIANCE, badBond, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: fixture.yieldDist,
          bondTerms:        fixture.bondTerms,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      "InvalidRate"
    );
  });

  it("B8: bond suite rejected when annual rate > 10000 bps", async () => {
    const issuerId = "BAD-BOND-003";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);
    const badBond  = defaultBondParams({ annualRateBps: 10_001 });

    await assertFails(
      program.methods
        .ixInitializeBondSuite(issuerId, ZERO_COMPLIANCE, badBond, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: fixture.yieldDist,
          bondTerms:        fixture.bondTerms,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      "InvalidRate"
    );
  });

  it("B9: bond suite rejected when first coupon date is before issue date", async () => {
    const issuerId = "BAD-BOND-004";
    const fixture  = buildSuiteFixture(issuerId, programId, admin);
    const base     = now();
    const badBond  = defaultBondParams({
      issueDate:      base + 100,
      firstCouponDate: base,     // first coupon BEFORE issue
    });

    await assertFails(
      program.methods
        .ixInitializeBondSuite(issuerId, ZERO_COMPLIANCE, badBond, 6)
        .accounts({
          factory,
          suite:            fixture.suite,
          mint:             fixture.mint,
          identityRegistry: fixture.identityRegistry,
          compliance:       fixture.compliance,
          yieldDistributor: fixture.yieldDist,
          bondTerms:        fixture.bondTerms,
          admin:            admin.publicKey,
          deployer:         deployer.publicKey,
          tokenProgram:     TOKEN_2022_PROGRAM_ID,
          systemProgram:    SystemProgram.programId,
        })
        .signers([deployer])
        .rpc(),
      "BadFirstCouponDate"
    );
  });

  // ── Invariant: total_deployments is monotone ──────────────────────────────

  it("INV: total_deployments is monotonically non-decreasing", async () => {
    const before = (await program.account.factory.fetch(factory)).totalDeployments.toNumber();

    const newId  = `SECURITY-INV-${Date.now()}`;
    const f      = buildSuiteFixture(newId, programId, admin);

    await program.methods
      .ixInitializeSuite(newId, TokenType.Security, ZERO_COMPLIANCE, 6)
      .accounts({
        factory,
        suite:            f.suite,
        mint:             f.mint,
        identityRegistry: f.identityRegistry,
        compliance:       f.compliance,
        yieldDistributor: null,
        admin:            admin.publicKey,
        deployer:         deployer.publicKey,
        tokenProgram:     TOKEN_2022_PROGRAM_ID,
        systemProgram:    SystemProgram.programId,
      })
      .signers([deployer])
      .rpc();

    const after = (await program.account.factory.fetch(factory)).totalDeployments.toNumber();
    assert.equal(after, before + 1, "total_deployments must increment by exactly 1");
  });
});
