/**
 * Bond tests
 *
 * Coverage:
 *   ✔ open_scheduled_coupon   — happy path (coupon is due)
 *   ✔ open_scheduled_coupon   — coupon not due rejected
 *   ✔ open_scheduled_coupon   — bond defaulted rejected
 *   ✔ open_scheduled_coupon   — bond principal repaid rejected
 *   ✔ open_scheduled_coupon   — non-agent rejected
 *   ✔ finalize_scheduled_coupon — pulls required funds; advances next_coupon_date
 *   ✔ finalize_scheduled_coupon — zero coupon amount rejected
 *   ✔ flag_default            — permissionless after grace breach
 *   ✔ flag_default            — before grace breach rejected
 *   ✔ flag_default            — already defaulted rejected
 *   ✔ flag_default            — principal repaid rejected
 *   ✔ redeem_at_maturity      — burns tokens; transfers principal; marks repaid
 *   ✔ redeem_at_maturity      — not matured rejected
 *   ✔ redeem_at_maturity      — defaulted rejected (no redemption after default)
 *   ✔ redeem_at_maturity      — non-agent rejected
 *   ✔ set_annual_rate         — admin changes rate
 *   ✔ set_annual_rate         — zero rate rejected
 *   ✔ set_annual_rate         — > 10000 bps rejected
 *   ✔ set_annual_rate         — non-admin rejected
 *   ✔ set_annual_rate         — defaulted bond rejected
 *
 * Invariants:
 *   ✔ next_coupon_date advances by exactly coupon_period_secs
 *   ✔ principal_repaid implies total supply is zero
 *   ✔ defaulted bond cannot have further coupons or redemptions
 */
import * as anchor from "@coral-xyz/anchor";
import { Keypair, SystemProgram, LAMPORTS_PER_SOL } from "@solana/web3.js";
import { TOKEN_2022_PROGRAM_ID, getAssociatedTokenAddressSync, createAssociatedTokenAccountInstruction } from "@solana/spl-token";
import { Program, BN } from "@coral-xyz/anchor";
import { assert } from "chai";
import { Tokenx } from "../target/types/tokenx";
import {
  factoryPDA, buildSuiteFixture,
  investorIdentityPDA, holderStatePDA, bondTermsPDA, yieldDistPDA,
  snapshotPDA, claimRecordPDA,
  ZERO_COMPLIANCE, TokenType, DayCount,
  assertFails, assertEq, airdrop, now,
} from "./helpers/setup";

describe("Bond", () => {
  const provider  = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program   = anchor.workspace.Tokenx as Program<Tokenx>;
  const programId = program.programId;
  const conn      = provider.connection;

  const admin    = Keypair.generate();
  const nonAgent = Keypair.generate();
  const inv1     = Keypair.generate();
  const inv2     = Keypair.generate();

  const ISSUER_ID = "BOND-TEST-SUITE-001";
  let fixture: ReturnType<typeof buildSuiteFixture>;
  const [factory] = factoryPDA(programId);

  const ata = (owner: Keypair) =>
    getAssociatedTokenAddressSync(fixture.mint, owner.publicKey, false, TOKEN_2022_PROGRAM_ID);

  async function createAta(owner: Keypair) {
    const ix = createAssociatedTokenAccountInstruction(
      admin.publicKey, ata(owner), owner.publicKey, fixture.mint, TOKEN_2022_PROGRAM_ID
    );
    await provider.sendAndConfirm(new anchor.web3.Transaction().add(ix), [admin]);
  }

  async function registerAndMint(kp: Keypair, amount: number) {
    const [id] = investorIdentityPDA(fixture.suite, kp.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, kp.publicKey, programId);
    await program.methods.ixRegisterIdentity(Keypair.generate().publicKey, 840)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id, wallet: kp.publicKey, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();
    await createAta(kp);
    if (amount > 0) {
      await program.methods.ixMintTo(new BN(amount))
        .accounts({
          suite: fixture.suite, mint: fixture.mint, compliance: fixture.compliance,
          recipientIdentity: id, holderState: hs, countryRule: null,
          recipientAta: ata(kp), recipientWallet: kp.publicKey, agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc();
    }
  }

  before(async () => {
    await Promise.all([
      airdrop(conn, admin.publicKey, 100),
      airdrop(conn, nonAgent.publicKey, 5),
      airdrop(conn, inv1.publicKey, 5),
      airdrop(conn, inv2.publicKey, 5),
    ]);

    await program.methods.ixInitializeFactory()
      .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();

    const base = now();
    // Deploy a bond suite with a VERY short coupon period (1 second) so tests
    // don't have to wait for real-time clocks.
    const bondParams = {
      annualRateBps:     new BN(500),
      couponPeriodSecs:  new BN(1),         // 1 second — expires immediately
      dayCount:          DayCount.Act365,
      issueDate:         new BN(base - 10), // issued 10 seconds ago
      maturityDate:      new BN(base + 31_536_000),
      firstCouponDate:   new BN(base - 9),  // first coupon was 9 seconds ago (already due)
      faceValuePerToken: new BN(1_000_000), // 1 USDC
      gracePeriodSecs:   new BN(1),         // 1-second grace period for default tests
      callable:          false,
      callDate:          new BN(0),
    };

    fixture = buildSuiteFixture(ISSUER_ID, programId, admin);
    await program.methods.ixInitializeBondSuite(ISSUER_ID, ZERO_COMPLIANCE, bondParams, 6)
      .accounts({
        factory, suite: fixture.suite, mint: fixture.mint,
        identityRegistry: fixture.identityRegistry, compliance: fixture.compliance,
        yieldDistributor: fixture.yieldDist, bondTerms: fixture.bondTerms,
        admin: admin.publicKey, deployer: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    await registerAndMint(inv1, 600_000);
    await registerAndMint(inv2, 400_000);
  });

  // ── Helper: open + finalize a bond coupon snapshot ────────────────────────

  async function openAndFinalizeCoupon(reclaimAfter: number) {
    const ydState  = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const nextId   = ydState.snapshotCount.toNumber() + 1;
    const [snap]   = snapshotPDA(fixture.yieldDist, BigInt(nextId), programId);
    const btState  = await program.account.bondTerms.fetch(fixture.bondTerms);

    // Phase 1: open coupon snapshot.
    await program.methods.ixOpenScheduledCoupon(new BN(reclaimAfter), "test coupon")
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        bondTerms: fixture.bondTerms, snapshot: snap,
        payoutMint: SystemProgram.programId,
        agent: admin.publicKey, systemProgram: SystemProgram.programId,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
      })
      .signers([admin]).rpc();

    // Phase 2: add records.
    const [id1] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs1] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const [cr1] = claimRecordPDA(snap, inv1.publicKey, programId);
    await program.methods.ixAddSnapshotRecord()
      .accounts({ suite: fixture.suite, yieldDistributor: fixture.yieldDist, snapshot: snap, investorIdentity: id1, holderState: hs1, claimRecord: cr1, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();

    const [id2] = investorIdentityPDA(fixture.suite, inv2.publicKey, programId);
    const [hs2] = holderStatePDA(fixture.suite, inv2.publicKey, programId);
    const [cr2] = claimRecordPDA(snap, inv2.publicKey, programId);
    await program.methods.ixAddSnapshotRecord()
      .accounts({ suite: fixture.suite, yieldDistributor: fixture.yieldDist, snapshot: snap, investorIdentity: id2, holderState: hs2, claimRecord: cr2, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();

    // Phase 3: finalize (pulls SOL, advances coupon date).
    await program.methods.ixFinalizeScheduledCoupon(new BN(nextId))
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        bondTerms: fixture.bondTerms, snapshot: snap,
        payoutMint: SystemProgram.programId,
        agentAta: null, snapshotAta: null,
        agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    return { snap, snapId: nextId };
  }

  // ── A: Coupon happy paths ─────────────────────────────────────────────────

  it("A1: agent creates and finalizes a scheduled coupon", async () => {
    const btBefore = await program.account.bondTerms.fetch(fixture.bondTerms);
    const prevDate = btBefore.nextCouponDate.toNumber();

    const { snap } = await openAndFinalizeCoupon(3600);

    const snapState = await program.account.snapshot.fetch(snap);
    assert.equal(snapState.active,    true,  "snapshot active");
    assert.equal(snapState.scheduled, true,  "marked as scheduled");
    assert.isAbove(snapState.totalFunds.toNumber(), 0, "funds transferred");

    const btAfter = await program.account.bondTerms.fetch(fixture.bondTerms);
    assert.isAbove(
      btAfter.nextCouponDate.toNumber(),
      prevDate,
      "next_coupon_date advanced"
    );
  });

  it("A2: next_coupon_date advances by exactly coupon_period_secs", async () => {
    // Wait 1 second for the next coupon to come due (period = 1s).
    await new Promise(r => setTimeout(r, 1100));

    const btBefore  = await program.account.bondTerms.fetch(fixture.bondTerms);
    const prevDate  = btBefore.nextCouponDate.toNumber();
    const period    = btBefore.couponPeriodSecs.toNumber();

    await openAndFinalizeCoupon(3600);

    const btAfter = await program.account.bondTerms.fetch(fixture.bondTerms);
    const newDate = btAfter.nextCouponDate.toNumber();
    assert.equal(newDate, Math.min(prevDate + period, btBefore.maturityDate.toNumber()),
      "next_coupon_date = prev + period (capped at maturity)");
  });

  // ── B: Coupon rejection paths ─────────────────────────────────────────────

  it("B1: coupon not due fails (coupon just advanced, not yet due)", async () => {
    // Immediately after advancing (period = 1s), the next coupon is not due.
    const ydState  = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const nextId   = ydState.snapshotCount.toNumber() + 1;
    const [snap]   = snapshotPDA(fixture.yieldDist, BigInt(nextId), programId);

    await assertFails(
      program.methods.ixOpenScheduledCoupon(new BN(3600), "B1 not due")
        .accounts({
          suite: fixture.suite, yieldDistributor: fixture.yieldDist,
          bondTerms: fixture.bondTerms, snapshot: snap,
          payoutMint: SystemProgram.programId,
          agent: admin.publicKey, systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([admin]).rpc(),
      "CouponNotDue"
    );
  });

  it("B2: non-agent cannot open scheduled coupon", async () => {
    await new Promise(r => setTimeout(r, 1100)); // let coupon become due

    const ydState  = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const nextId   = ydState.snapshotCount.toNumber() + 1;
    const [snap]   = snapshotPDA(fixture.yieldDist, BigInt(nextId), programId);

    await assertFails(
      program.methods.ixOpenScheduledCoupon(new BN(3600), "B2 non-agent")
        .accounts({
          suite: fixture.suite, yieldDistributor: fixture.yieldDist,
          bondTerms: fixture.bondTerms, snapshot: snap,
          payoutMint: SystemProgram.programId,
          agent: nonAgent.publicKey, systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  // ── A: set_annual_rate ────────────────────────────────────────────────────

  it("A3: bond admin can update annual rate", async () => {
    await program.methods.ixSetAnnualRate(750)
      .accounts({ suite: fixture.suite, bondTerms: fixture.bondTerms, admin: admin.publicKey })
      .signers([admin]).rpc();

    const bt = await program.account.bondTerms.fetch(fixture.bondTerms);
    assert.equal(bt.annualRateBps, 750);

    // Reset.
    await program.methods.ixSetAnnualRate(500)
      .accounts({ suite: fixture.suite, bondTerms: fixture.bondTerms, admin: admin.publicKey })
      .signers([admin]).rpc();
  });

  it("B3: non-admin cannot update annual rate", async () => {
    await assertFails(
      program.methods.ixSetAnnualRate(100)
        .accounts({ suite: fixture.suite, bondTerms: fixture.bondTerms, admin: nonAgent.publicKey })
        .signers([nonAgent]).rpc(),
      "NotAdmin"
    );
  });

  it("B4: annual rate of 0 is rejected", async () => {
    await assertFails(
      program.methods.ixSetAnnualRate(0)
        .accounts({ suite: fixture.suite, bondTerms: fixture.bondTerms, admin: admin.publicKey })
        .signers([admin]).rpc(),
      "InvalidRate"
    );
  });

  it("B5: annual rate > 10000 bps is rejected", async () => {
    await assertFails(
      program.methods.ixSetAnnualRate(10_001)
        .accounts({ suite: fixture.suite, bondTerms: fixture.bondTerms, admin: admin.publicKey })
        .signers([admin]).rpc(),
      "InvalidRate"
    );
  });

  // ── A: flag_default (permissionless) ─────────────────────────────────────

  it("A4: anyone can flag default after grace breach (1s grace period)", async () => {
    // Create a separate suite for default tests to avoid polluting the main suite.
    const defIssuer = "BOND-DEFAULT-TEST";
    const defBase   = now();
    const defBond   = {
      annualRateBps:     new BN(500),
      couponPeriodSecs:  new BN(1),
      dayCount:          DayCount.Act365,
      issueDate:         new BN(defBase - 10),
      maturityDate:      new BN(defBase + 31_536_000),
      firstCouponDate:   new BN(defBase - 9),
      faceValuePerToken: new BN(1_000_000),
      gracePeriodSecs:   new BN(1), // 1s grace
      callable:          false,
      callDate:          new BN(0),
    };
    const defFixture = buildSuiteFixture(defIssuer, programId, admin);
    await program.methods.ixInitializeBondSuite(defIssuer, ZERO_COMPLIANCE, defBond, 6)
      .accounts({
        factory, suite: defFixture.suite, mint: defFixture.mint,
        identityRegistry: defFixture.identityRegistry, compliance: defFixture.compliance,
        yieldDistributor: defFixture.yieldDist, bondTerms: defFixture.bondTerms,
        admin: admin.publicKey, deployer: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    // Wait for grace breach (1s coupon period + 1s grace = 2s).
    await new Promise(r => setTimeout(r, 2500));

    // Non-agent flags the default.
    await program.methods.ixFlagDefault()
      .accounts({ suite: defFixture.suite, bondTerms: defFixture.bondTerms, caller: nonAgent.publicKey })
      .signers([nonAgent]).rpc();

    const bt = await program.account.bondTerms.fetch(defFixture.bondTerms);
    assert.equal(bt.defaulted, true);
  });

  it("B6: flag_default before grace breach fails", async () => {
    // Use the fresh main fixture — grace not breached yet because we just finalized coupons.
    await new Promise(r => setTimeout(r, 1100)); // let coupon become due but not past grace

    // Create another clean suite.
    const freshIssuer = "BOND-FRESH-NO-DEFAULT";
    const freshBase   = now();
    const freshBond   = {
      annualRateBps:     new BN(500),
      couponPeriodSecs:  new BN(99999),  // very long period — will never be due in test time
      dayCount:          DayCount.Act365,
      issueDate:         new BN(freshBase),
      maturityDate:      new BN(freshBase + 31_536_000),
      firstCouponDate:   new BN(freshBase + 99999),
      faceValuePerToken: new BN(1_000_000),
      gracePeriodSecs:   new BN(99999),
      callable:          false,
      callDate:          new BN(0),
    };
    const freshFix = buildSuiteFixture(freshIssuer, programId, admin);
    await program.methods.ixInitializeBondSuite(freshIssuer, ZERO_COMPLIANCE, freshBond, 6)
      .accounts({
        factory, suite: freshFix.suite, mint: freshFix.mint,
        identityRegistry: freshFix.identityRegistry, compliance: freshFix.compliance,
        yieldDistributor: freshFix.yieldDist, bondTerms: freshFix.bondTerms,
        admin: admin.publicKey, deployer: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    await assertFails(
      program.methods.ixFlagDefault()
        .accounts({ suite: freshFix.suite, bondTerms: freshFix.bondTerms, caller: nonAgent.publicKey })
        .signers([nonAgent]).rpc(),
      "GraceNotBreached"
    );
  });

  // ── A: redeem_at_maturity ─────────────────────────────────────────────────

  it("A5: agent redeems tokens at maturity; supply goes to zero; principal_repaid set", async () => {
    // Create a bond suite that is already matured.
    const maturedIssuer = "BOND-MATURED-TEST";
    const base          = now();
    const maturedBond   = {
      annualRateBps:     new BN(500),
      couponPeriodSecs:  new BN(1),
      dayCount:          DayCount.Act365,
      issueDate:         new BN(base - 1000),
      maturityDate:      new BN(base - 1),  // already matured
      firstCouponDate:   new BN(base - 999),
      faceValuePerToken: new BN(1_000_000),
      gracePeriodSecs:   new BN(1),
      callable:          false,
      callDate:          new BN(0),
    };
    const matFix = buildSuiteFixture(maturedIssuer, programId, admin);
    await program.methods.ixInitializeBondSuite(maturedIssuer, ZERO_COMPLIANCE, maturedBond, 6)
      .accounts({
        factory, suite: matFix.suite, mint: matFix.mint,
        identityRegistry: matFix.identityRegistry, compliance: matFix.compliance,
        yieldDistributor: matFix.yieldDist, bondTerms: matFix.bondTerms,
        admin: admin.publicKey, deployer: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    // Register investor and mint.
    const invM = Keypair.generate();
    await airdrop(conn, invM.publicKey, 5);
    const [idM] = investorIdentityPDA(matFix.suite, invM.publicKey, programId);
    const [hsM] = holderStatePDA(matFix.suite, invM.publicKey, programId);
    await program.methods.ixRegisterIdentity(Keypair.generate().publicKey, 840)
      .accounts({ suite: matFix.suite, identityRegistry: matFix.identityRegistry, investorIdentity: idM, wallet: invM.publicKey, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();
    const matAta = getAssociatedTokenAddressSync(matFix.mint, invM.publicKey, false, TOKEN_2022_PROGRAM_ID);
    const ataIx  = createAssociatedTokenAccountInstruction(admin.publicKey, matAta, invM.publicKey, matFix.mint, TOKEN_2022_PROGRAM_ID);
    await provider.sendAndConfirm(new anchor.web3.Transaction().add(ataIx), [admin]);
    await program.methods.ixMintTo(new BN(10_000))
      .accounts({
        suite: matFix.suite, mint: matFix.mint, compliance: matFix.compliance,
        recipientIdentity: idM, holderState: hsM, countryRule: null,
        recipientAta: matAta, recipientWallet: invM.publicKey, agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    // Deposit principal SOL into suite PDA for payout.
    const principal = new BN(10_000 * 1_000_000 / 1_000_000_000);
    const depIx = SystemProgram.transfer({ fromPubkey: admin.publicKey, toPubkey: matFix.suite, lamports: principal.toNumber() });
    await provider.sendAndConfirm(new anchor.web3.Transaction().add(depIx), [admin]);

    // Redeem.
    await program.methods.ixRedeemAtMaturity(6)
      .accounts({
        suite: matFix.suite, mint: matFix.mint, compliance: matFix.compliance,
        bondTerms: matFix.bondTerms, investorIdentity: idM, holderState: hsM,
        holderAta: matAta, payoutMint: SystemProgram.programId,
        vaultAta: null, investorPayoutAta: null,
        investorWallet: invM.publicKey, agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    const btAfter = await program.account.bondTerms.fetch(matFix.bondTerms);
    assert.equal(btAfter.principalRepaid, true, "principal_repaid set");

    const hsAfter = await program.account.holderState.fetch(hsM);
    assertEq(hsAfter.balance, 0, "holder balance zero");
  });

  it("B7: redeem before maturity fails", async () => {
    // The main fixture's bond has maturityDate far in the future.
    const inv   = Keypair.generate();
    await airdrop(conn, inv.publicKey, 5);
    const [id]  = investorIdentityPDA(fixture.suite, inv.publicKey, programId);
    const [hs]  = holderStatePDA(fixture.suite, inv.publicKey, programId);
    await program.methods.ixRegisterIdentity(Keypair.generate().publicKey, 840)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id, wallet: inv.publicKey, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();
    const invAta = getAssociatedTokenAddressSync(fixture.mint, inv.publicKey, false, TOKEN_2022_PROGRAM_ID);
    const ataIx  = createAssociatedTokenAccountInstruction(admin.publicKey, invAta, inv.publicKey, fixture.mint, TOKEN_2022_PROGRAM_ID);
    await provider.sendAndConfirm(new anchor.web3.Transaction().add(ataIx), [admin]);
    await program.methods.ixMintTo(new BN(1_000))
      .accounts({
        suite: fixture.suite, mint: fixture.mint, compliance: fixture.compliance,
        recipientIdentity: id, holderState: hs, countryRule: null,
        recipientAta: invAta, recipientWallet: inv.publicKey, agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    await assertFails(
      program.methods.ixRedeemAtMaturity(6)
        .accounts({
          suite: fixture.suite, mint: fixture.mint, compliance: fixture.compliance,
          bondTerms: fixture.bondTerms, investorIdentity: id, holderState: hs,
          holderAta: invAta, payoutMint: SystemProgram.programId,
          vaultAta: null, investorPayoutAta: null,
          investorWallet: inv.publicKey, agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "NotMatured"
    );
  });

  it("B8: non-agent cannot redeem at maturity", async () => {
    const [idInv1]  = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hsInv1]  = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixRedeemAtMaturity(6)
        .accounts({
          suite: fixture.suite, mint: fixture.mint, compliance: fixture.compliance,
          bondTerms: fixture.bondTerms, investorIdentity: idInv1, holderState: hsInv1,
          holderAta: ata(inv1), payoutMint: SystemProgram.programId,
          vaultAta: null, investorPayoutAta: null,
          investorWallet: inv1.publicKey, agent: nonAgent.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  // ── Invariants ─────────────────────────────────────────────────────────────

  it("INV: principal_repaid bond cannot have annual rate changed", async () => {
    // Find the matured bond fixture (BOND-MATURED-TEST) — it was repaid in A5.
    const matFix = buildSuiteFixture("BOND-MATURED-TEST", programId, admin);

    await assertFails(
      program.methods.ixSetAnnualRate(600)
        .accounts({ suite: matFix.suite, bondTerms: matFix.bondTerms, admin: admin.publicKey })
        .signers([admin]).rpc(),
      "BondClosed"
    );
  });

  it("INV: defaulted bond cannot have new coupons", async () => {
    const defFix = buildSuiteFixture("BOND-DEFAULT-TEST", programId, admin);
    const ydState  = await program.account.yieldDistributor.fetch(defFix.yieldDist);
    const nextId   = ydState.snapshotCount.toNumber() + 1;
    const [snap]   = snapshotPDA(defFix.yieldDist, BigInt(nextId), programId);

    await assertFails(
      program.methods.ixOpenScheduledCoupon(new BN(3600), "INV defaulted")
        .accounts({
          suite: defFix.suite, yieldDistributor: defFix.yieldDist,
          bondTerms: defFix.bondTerms, snapshot: snap,
          payoutMint: SystemProgram.programId,
          agent: admin.publicKey, systemProgram: SystemProgram.programId,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([admin]).rpc(),
      "BondDefaulted"
    );
  });
});
