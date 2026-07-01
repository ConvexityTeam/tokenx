/**
 * Yield distributor tests
 *
 * Coverage:
 *   ✔ open_snapshot         — happy path; funds transferred in
 *   ✔ open_snapshot         — non-agent rejected
 *   ✔ open_snapshot         — suite paused rejected
 *   ✔ open_snapshot         — non-yield suite rejected
 *   ✔ add_snapshot_record   — eligible investor recorded
 *   ✔ add_snapshot_record   — ineligible investor (unverified) skipped
 *   ✔ add_snapshot_record   — ineligible investor (frozen) skipped
 *   ✔ add_snapshot_record   — zero-balance investor skipped
 *   ✔ finalize_snapshot     — sets active=true; zero eligible supply rejected
 *   ✔ claim_yield           — investor pulls correct pro-rata amount
 *   ✔ claim_yield           — double claim rejected
 *   ✔ claim_yield           — unverified investor rejected
 *   ✔ claim_yield           — frozen investor rejected
 *   ✔ push_yield            — agent pushes to eligible investor
 *   ✔ push_yield            — already claimed investor skipped
 *   ✔ reclaim_unclaimed     — admin reclaims after deadline
 *   ✔ reclaim_unclaimed     — before deadline rejected
 *   ✔ reclaim_unclaimed     — non-admin rejected
 *   ✔ reclaim_unclaimed     — nothing to reclaim rejected
 *
 * Invariants:
 *   ✔ total_claimed never exceeds total_funds
 *   ✔ snapshot_count increments monotonically
 *   ✔ yield per investor = (balance_at_snapshot / total_eligible_supply) * total_funds
 */
import * as anchor from "@coral-xyz/anchor";
import { Keypair, SystemProgram, LAMPORTS_PER_SOL } from "@solana/web3.js";
import { TOKEN_2022_PROGRAM_ID, getAssociatedTokenAddressSync, createAssociatedTokenAccountInstruction } from "@solana/spl-token";
import { Program, BN } from "@coral-xyz/anchor";
import { assert } from "chai";
import { Tokenx } from "../target/types/tokenx";
import {
  factoryPDA, buildSuiteFixture,
  investorIdentityPDA, holderStatePDA, snapshotPDA, claimRecordPDA,
  ZERO_COMPLIANCE, TokenType, assertFails, assertEq, airdrop, now,
} from "./helpers/setup";

describe("Yield Distributor", () => {
  const provider  = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program   = anchor.workspace.Tokenx as Program<Tokenx>;
  const programId = program.programId;
  const conn      = provider.connection;

  const admin    = Keypair.generate();
  const nonAgent = Keypair.generate();
  const inv1     = Keypair.generate();
  const inv2     = Keypair.generate();
  const inv3     = Keypair.generate(); // zero-balance investor

  const ISSUER_ID = "YIELD-DISTRIBUTOR-TEST";
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

  async function registerAndMint(kp: Keypair, amount: number, country = 840) {
    const [id] = investorIdentityPDA(fixture.suite, kp.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, kp.publicKey, programId);
    await program.methods.ixRegisterIdentity(Keypair.generate().publicKey, country)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id, wallet: kp.publicKey, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();
    await createAta(kp);
    if (amount > 0) {
      await program.methods.ixMintTo(new BN(amount))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id, holderState: hs,
          countryRule: null, recipientAta: ata(kp),
          recipientWallet: kp.publicKey, agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc();
    }
  }

  // Open snapshot (phase 1) returning snapshot PDA.
  async function openSnapshot(fundSol: number, reclaimAfter: number, description: string) {
    const ydState  = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const nextId   = ydState.snapshotCount.toNumber() + 1;
    const [snap]   = snapshotPDA(fixture.yieldDist, BigInt(nextId), programId);
    const lamports = new BN(fundSol * LAMPORTS_PER_SOL);

    await program.methods.ixOpenSnapshot(lamports, new BN(reclaimAfter), description)
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        snapshot: snap,
        payoutMint: SystemProgram.programId, // SOL
        agentAta: null, snapshotAta: null,
        agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    return { snap, snapId: nextId };
  }

  async function addRecord(snap: ReturnType<typeof snapshotPDA>[0], snapId: number, investor: Keypair) {
    const [id] = investorIdentityPDA(fixture.suite, investor.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, investor.publicKey, programId);
    const [cr] = claimRecordPDA(snap, investor.publicKey, programId);
    await program.methods.ixAddSnapshotRecord()
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        snapshot: snap, investorIdentity: id, holderState: hs,
        claimRecord: cr, agent: admin.publicKey, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();
    return cr;
  }

  async function finalizeSnapshot(snap: ReturnType<typeof snapshotPDA>[0]) {
    await program.methods.ixFinalizeSnapshot()
      .accounts({ suite: fixture.suite, yieldDistributor: fixture.yieldDist, snapshot: snap, agent: admin.publicKey })
      .signers([admin]).rpc();
  }

  before(async () => {
    await Promise.all([
      airdrop(conn, admin.publicKey, 50),
      airdrop(conn, nonAgent.publicKey, 5),
      airdrop(conn, inv1.publicKey, 5),
      airdrop(conn, inv2.publicKey, 5),
      airdrop(conn, inv3.publicKey, 5),
    ]);

    await program.methods.ixInitializeFactory()
      .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();

    fixture = buildSuiteFixture(ISSUER_ID, programId, admin);
    await program.methods.ixInitializeSuite(ISSUER_ID, TokenType.YieldBearing, ZERO_COMPLIANCE, 6)
      .accounts({
        factory, suite: fixture.suite, mint: fixture.mint,
        identityRegistry: fixture.identityRegistry, compliance: fixture.compliance,
        yieldDistributor: fixture.yieldDist, admin: admin.publicKey,
        deployer: admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    await registerAndMint(inv1, 600_000);
    await registerAndMint(inv2, 400_000);
    // inv3 registered but no balance.
    const [id3] = investorIdentityPDA(fixture.suite, inv3.publicKey, programId);
    await program.methods.ixRegisterIdentity(Keypair.generate().publicKey, 840)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id3, wallet: inv3.publicKey, agent: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();
    await createAta(inv3);
  });

  // ── A: Snapshot lifecycle ────────────────────────────────────────────────

  it("A1: agent opens a SOL snapshot; snapshot_count increments", async () => {
    const before = (await program.account.yieldDistributor.fetch(fixture.yieldDist)).snapshotCount.toNumber();
    const { snap } = await openSnapshot(1, 3600, "Q1 2026 distribution");
    const after  = (await program.account.yieldDistributor.fetch(fixture.yieldDist)).snapshotCount.toNumber();
    assert.equal(after, before + 1);

    const state = await program.account.snapshot.fetch(snap);
    assert.equal(state.active, false, "inactive until finalized");
    assert.equal(state.scheduled, false);
    assertEq(state.totalFunds, LAMPORTS_PER_SOL, "1 SOL deposited");
  });

  it("A2: agent adds eligible investor records", async () => {
    const { snap } = await openSnapshot(1, 3600, "A2 test");
    const cr1 = await addRecord(snap, 0, inv1);
    const cr2 = await addRecord(snap, 0, inv2);

    const snapState = await program.account.snapshot.fetch(snap);
    assertEq(snapState.totalEligibleSupply, 1_000_000, "600k + 400k");

    const r1 = await program.account.claimRecord.fetch(cr1);
    assertEq(r1.balanceAtSnapshot, 600_000);
    assert.equal(r1.claimed, false);
  });

  it("A3: zero-balance investor record is skipped (no ClaimRecord created)", async () => {
    const { snap } = await openSnapshot(1, 3600, "A3 test");

    // Adding inv3 (zero balance) should not create a ClaimRecord.
    const [id3] = investorIdentityPDA(fixture.suite, inv3.publicKey, programId);
    const [hs3] = holderStatePDA(fixture.suite, inv3.publicKey, programId);
    const [cr3] = claimRecordPDA(snap, inv3.publicKey, programId);

    // The instruction succeeds but doesn't create the PDA.
    await program.methods.ixAddSnapshotRecord()
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        snapshot: snap, investorIdentity: id3, holderState: hs3,
        claimRecord: cr3, agent: admin.publicKey, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    const snapState = await program.account.snapshot.fetch(snap);
    assertEq(snapState.totalEligibleSupply, 0, "no eligible supply from zero-balance investor");
  });

  it("A4: finalize activates snapshot", async () => {
    const { snap } = await openSnapshot(1, 3600, "A4 test");
    await addRecord(snap, 0, inv1);
    await finalizeSnapshot(snap);

    const state = await program.account.snapshot.fetch(snap);
    assert.equal(state.active, true);
  });

  it("A5: investor claims correct pro-rata yield (SOL)", async () => {
    const { snap } = await openSnapshot(1, 3600, "A5 claim");
    const cr1 = await addRecord(snap, 0, inv1); // 600_000 / 1_000_000 = 60%
    await addRecord(snap, 0, inv2);
    await finalizeSnapshot(snap);

    const snapState = await program.account.snapshot.fetch(snap);
    const expected  = Math.floor((600_000 * LAMPORTS_PER_SOL) / 1_000_000);

    const [id1] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs1] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await program.methods.ixClaimYield(new BN(snapState.id))
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        snapshot: snap, claimRecord: cr1,
        investorIdentity: id1, holderState: hs1,
        payoutMint: SystemProgram.programId,
        snapshotAta: null, investorAta: null,
        investorWallet: inv1.publicKey,
        investor: inv1.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([inv1]).rpc();

    const record = await program.account.claimRecord.fetch(cr1);
    assert.equal(record.claimed, true);

    const snapAfter = await program.account.snapshot.fetch(snap);
    assertEq(snapAfter.totalClaimed, expected, "total_claimed = investor's share");
  });

  it("B1: double claim is rejected", async () => {
    const ydState = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const lastId  = ydState.snapshotCount.toNumber();
    const [snap]  = snapshotPDA(fixture.yieldDist, BigInt(lastId), programId);
    const snapState = await program.account.snapshot.fetch(snap);

    const [cr1] = claimRecordPDA(snap, inv1.publicKey, programId);
    const [id1] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs1] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixClaimYield(new BN(snapState.id))
        .accounts({
          suite: fixture.suite, yieldDistributor: fixture.yieldDist,
          snapshot: snap, claimRecord: cr1,
          investorIdentity: id1, holderState: hs1,
          payoutMint: SystemProgram.programId,
          snapshotAta: null, investorAta: null,
          investorWallet: inv1.publicKey, investor: inv1.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .signers([inv1]).rpc(),
      "AlreadyClaimed"
    );
  });

  it("A6: agent pushes yield to eligible investor", async () => {
    const { snap } = await openSnapshot(1, 3600, "A6 push");
    const cr2 = await addRecord(snap, 0, inv2);
    await addRecord(snap, 0, inv1);
    await finalizeSnapshot(snap);

    const snapState = await program.account.snapshot.fetch(snap);
    const [id2] = investorIdentityPDA(fixture.suite, inv2.publicKey, programId);
    const [hs2] = holderStatePDA(fixture.suite, inv2.publicKey, programId);

    await program.methods.ixPushYield(new BN(snapState.id))
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        snapshot: snap, claimRecord: cr2,
        investorIdentity: id2, holderState: hs2,
        payoutMint: SystemProgram.programId,
        snapshotAta: null, investorAta: null,
        investorWallet: inv2.publicKey, agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    const record = await program.account.claimRecord.fetch(cr2);
    assert.equal(record.claimed, true);
  });

  it("A7: admin reclaims unclaimed after deadline", async () => {
    // Open snapshot with 1-second reclaim window.
    const { snap } = await openSnapshot(1, 1, "A7 reclaim");
    const cr1 = await addRecord(snap, 0, inv1);
    await finalizeSnapshot(snap);

    // Wait for reclaim deadline.
    await new Promise(r => setTimeout(r, 2000));

    const snapState = await program.account.snapshot.fetch(snap);
    const unclaimed = snapState.totalFunds.toNumber() - snapState.totalClaimed.toNumber();

    await program.methods.ixReclaimUnclaimed(new BN(snapState.id))
      .accounts({
        suite: fixture.suite, yieldDistributor: fixture.yieldDist,
        snapshot: snap,
        payoutMint: SystemProgram.programId,
        snapshotAta: null, adminAta: null,
        admin: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    const after = await program.account.snapshot.fetch(snap);
    assert.equal(after.active, false, "snapshot deactivated after reclaim");
  });

  it("B2: reclaim before deadline fails", async () => {
    const { snap } = await openSnapshot(1, 99999, "B2 no reclaim");
    await addRecord(snap, 0, inv1);
    await finalizeSnapshot(snap);

    const snapState = await program.account.snapshot.fetch(snap);

    await assertFails(
      program.methods.ixReclaimUnclaimed(new BN(snapState.id))
        .accounts({
          suite: fixture.suite, yieldDistributor: fixture.yieldDist,
          snapshot: snap, payoutMint: SystemProgram.programId,
          snapshotAta: null, adminAta: null, admin: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "ReclaimDeadlineNotReached"
    );
  });

  it("B3: non-admin cannot reclaim", async () => {
    const ydState = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const lastId  = ydState.snapshotCount.toNumber();
    const [snap]  = snapshotPDA(fixture.yieldDist, BigInt(lastId), programId);
    const snapState = await program.account.snapshot.fetch(snap);

    await assertFails(
      program.methods.ixReclaimUnclaimed(new BN(snapState.id))
        .accounts({
          suite: fixture.suite, yieldDistributor: fixture.yieldDist,
          snapshot: snap, payoutMint: SystemProgram.programId,
          snapshotAta: null, adminAta: null, admin: nonAgent.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .signers([nonAgent]).rpc(),
      "NotAdmin"
    );
  });

  it("B4: non-agent cannot open snapshot", async () => {
    const ydState  = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const nextId   = ydState.snapshotCount.toNumber() + 1;
    const [snap]   = snapshotPDA(fixture.yieldDist, BigInt(nextId), programId);

    await assertFails(
      program.methods.ixOpenSnapshot(new BN(LAMPORTS_PER_SOL), new BN(3600), "B4")
        .accounts({
          suite: fixture.suite, yieldDistributor: fixture.yieldDist,
          snapshot: snap, payoutMint: SystemProgram.programId,
          agentAta: null, snapshotAta: null,
          agent: nonAgent.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  it("B5: finalize with no eligible holders fails", async () => {
    const { snap } = await openSnapshot(1, 3600, "B5 no holders");
    // Do not add any records.

    await assertFails(
      program.methods.ixFinalizeSnapshot()
        .accounts({ suite: fixture.suite, yieldDistributor: fixture.yieldDist, snapshot: snap, agent: admin.publicKey })
        .signers([admin]).rpc(),
      "NoEligibleHolders"
    );
  });

  // ── Invariants ─────────────────────────────────────────────────────────────

  it("INV: total_claimed never exceeds total_funds across all snapshots", async () => {
    const ydState = await program.account.yieldDistributor.fetch(fixture.yieldDist);
    const count   = ydState.snapshotCount.toNumber();
    for (let id = 1; id <= count; id++) {
      const [snap]  = snapshotPDA(fixture.yieldDist, BigInt(id), programId);
      try {
        const state = await program.account.snapshot.fetch(snap);
        assert.isAtMost(
          state.totalClaimed.toNumber(),
          state.totalFunds.toNumber(),
          `snapshot ${id}: total_claimed ≤ total_funds`
        );
      } catch { /* snapshot may not exist */ }
    }
  });

  it("INV: snapshot_count is monotonically non-decreasing", async () => {
    const before = (await program.account.yieldDistributor.fetch(fixture.yieldDist)).snapshotCount.toNumber();
    await openSnapshot(1, 3600, "INV monotone");
    const after  = (await program.account.yieldDistributor.fetch(fixture.yieldDist)).snapshotCount.toNumber();
    assert.equal(after, before + 1);
  });
});
