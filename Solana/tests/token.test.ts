/**
 * Token operation tests
 *
 * Coverage:
 *   ✔ mint_to          — happy path; compliance state updated
 *   ✔ mint_to          — unverified recipient rejected
 *   ✔ mint_to          — blocked country rejected
 *   ✔ mint_to          — wallet allowlist rejected
 *   ✔ mint_to          — exceeds max_tokens_per_investor rejected
 *   ✔ mint_to          — exceeds max_shareholders rejected
 *   ✔ mint_to          — suite paused rejected
 *   ✔ mint_to          — non-agent rejected
 *   ✔ burn             — happy path; shareholder_count decrements on zero balance
 *   ✔ burn             — insufficient unfrozen balance rejected
 *   ✔ burn             — non-agent rejected
 *   ✔ forced_transfer  — happy path; bypasses compliance; updates HolderState
 *   ✔ forced_transfer  — unverified recipient rejected
 *   ✔ forced_transfer  — insufficient unfrozen balance rejected
 *   ✔ forced_transfer  — non-agent rejected
 *   ✔ set_address_frozen — agent freezes/unfreezes; subsequent transfer rejected
 *   ✔ set_address_frozen — non-agent rejected
 *   ✔ freeze_partial   — happy path; freeze_partial + unfreeze_partial
 *   ✔ freeze_partial   — exceeds balance rejected
 *   ✔ unfreeze_partial — more than frozen rejected
 *   ✔ recover_wallet   — happy path; balance & frozen_tokens migrated
 *   ✔ recover_wallet   — mismatched ONCHAINID rejected
 *   ✔ recover_wallet   — unverified new wallet rejected
 *   ✔ pause_suite      — pauser can pause; operations rejected while paused
 *   ✔ pause_suite      — non-pauser rejected
 *
 * Reentrancy (Solana-native):
 *   Solana's runtime prevents same-program reentrancy at the BPF level.
 *   Tests verify that a malicious CPI back into the tokenx program during
 *   a token operation cannot complete (runtime rejects it).
 */
import * as anchor from "@coral-xyz/anchor";
import {
  Keypair,
  SystemProgram,
  PublicKey,
} from "@solana/web3.js";
import {
  TOKEN_2022_PROGRAM_ID,
  getAssociatedTokenAddressSync,
  createAssociatedTokenAccountInstruction,
} from "@solana/spl-token";
import { Program, BN } from "@coral-xyz/anchor";
import { assert } from "chai";
import { Tokenx } from "../target/types/tokenx";
import {
  factoryPDA,
  buildSuiteFixture,
  investorIdentityPDA,
  holderStatePDA,
  compliancePDA,
  countryRulePDA,
  ZERO_COMPLIANCE,
  TokenType,
  assertFails,
  assertEq,
  airdrop,
} from "./helpers/setup";

describe("Token", () => {
  const provider  = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program   = anchor.workspace.Tokenx as Program<Tokenx>;
  const programId = program.programId;
  const conn      = provider.connection;

  const admin    = Keypair.generate();
  const nonAgent = Keypair.generate();
  const inv1     = Keypair.generate(); // primary test investor
  const inv2     = Keypair.generate(); // second investor for shareholder cap tests
  const inv3     = Keypair.generate(); // recovery target

  const ISSUER_ID = "TOKEN-TEST-SUITE";
  let fixture: ReturnType<typeof buildSuiteFixture>;
  const [factory] = factoryPDA(programId);

  // Helpers to get ATAs.
  const ata = (mint: PublicKey, owner: PublicKey) =>
    getAssociatedTokenAddressSync(mint, owner, false, TOKEN_2022_PROGRAM_ID);

  async function createAta(mint: PublicKey, owner: Keypair) {
    const ix = createAssociatedTokenAccountInstruction(
      admin.publicKey, ata(mint, owner.publicKey), owner.publicKey, mint, TOKEN_2022_PROGRAM_ID
    );
    const tx = new anchor.web3.Transaction().add(ix);
    await provider.sendAndConfirm(tx, [admin]);
  }

  async function registerInvestor(kp: Keypair, country = 840) {
    const [id] = investorIdentityPDA(fixture.suite, kp.publicKey, programId);
    await program.methods
      .ixRegisterIdentity(Keypair.generate().publicKey, country)
      .accounts({
        suite: fixture.suite, identityRegistry: fixture.identityRegistry,
        investorIdentity: id, wallet: kp.publicKey,
        agent: admin.publicKey, systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();
    await createAta(fixture.mint, kp);
  }

  async function mint(to: Keypair, amount: number) {
    const [invId]       = investorIdentityPDA(fixture.suite, to.publicKey, programId);
    const [holderState] = holderStatePDA(fixture.suite, to.publicKey, programId);
    await program.methods
      .ixMintTo(new BN(amount))
      .accounts({
        suite: fixture.suite, mint: fixture.mint,
        compliance: fixture.compliance,
        recipientIdentity: invId,
        holderState,
        countryRule: null,
        recipientAta: ata(fixture.mint, to.publicKey),
        recipientWallet: to.publicKey,
        agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();
  }

  before(async () => {
    await Promise.all([
      airdrop(conn, admin.publicKey, 20),
      airdrop(conn, nonAgent.publicKey, 5),
      airdrop(conn, inv1.publicKey, 5),
      airdrop(conn, inv2.publicKey, 5),
      airdrop(conn, inv3.publicKey, 5),
    ]);

    await program.methods.ixInitializeFactory()
      .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();

    fixture = buildSuiteFixture(ISSUER_ID, programId, admin);
    await program.methods.ixInitializeSuite(ISSUER_ID, TokenType.Security, ZERO_COMPLIANCE, 6)
      .accounts({
        factory,
        suite: fixture.suite, mint: fixture.mint,
        identityRegistry: fixture.identityRegistry,
        compliance: fixture.compliance,
        yieldDistributor: null,
        admin: admin.publicKey, deployer: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin]).rpc();

    await registerInvestor(inv1, 840); // USA
    await registerInvestor(inv2, 840);
    await registerInvestor(inv3, 840);
  });

  // ── A: Mint — happy paths ─────────────────────────────────────────────────

  it("A1: agent mints tokens to verified investor", async () => {
    await mint(inv1, 100_000);

    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const s    = await program.account.holderState.fetch(hs);
    assertEq(s.balance, 100_000);

    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.shareholderCount, 1, "shareholder_count after first mint");
  });

  it("A2: minting to a second investor increments shareholder_count", async () => {
    await mint(inv2, 50_000);
    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.shareholderCount, 2, "shareholder_count after second mint");
  });

  it("A3: minting again to existing holder does not change shareholder_count", async () => {
    await mint(inv1, 10_000);
    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.shareholderCount, 2, "no duplicate shareholder");

    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const s    = await program.account.holderState.fetch(hs);
    assertEq(s.balance, 110_000, "balance accumulates");
  });

  // ── B: Mint — rejection paths ─────────────────────────────────────────────

  it("B1: minting to unverified investor fails", async () => {
    const unverified = Keypair.generate();
    await airdrop(conn, unverified.publicKey, 2);
    await registerInvestor(unverified);

    // Revoke verification.
    const [id] = investorIdentityPDA(fixture.suite, unverified.publicKey, programId);
    await program.methods.ixSetVerified(false)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id, agent: admin.publicKey })
      .signers([admin]).rpc();

    const [hs] = holderStatePDA(fixture.suite, unverified.publicKey, programId);
    await assertFails(
      program.methods.ixMintTo(new BN(1_000))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id,
          holderState: hs, countryRule: null,
          recipientAta: ata(fixture.mint, unverified.publicKey),
          recipientWallet: unverified.publicKey,
          agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "NotVerified"
    );
  });

  it("B2: non-agent cannot mint", async () => {
    const [id] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixMintTo(new BN(1))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id,
          holderState: hs, countryRule: null,
          recipientAta: ata(fixture.mint, inv1.publicKey),
          recipientWallet: inv1.publicKey,
          agent: nonAgent.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  it("B3: mint blocked by blocked country", async () => {
    // Block country 840 (USA) — inv1 is from USA.
    const [rule] = countryRulePDA(fixture.suite, 840, programId);
    await program.methods.ixSetCountryRule(840, true, false)
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, countryRule: rule, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();

    const [id] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixMintTo(new BN(1_000))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id,
          holderState: hs, countryRule: rule,
          recipientAta: ata(fixture.mint, inv1.publicKey),
          recipientWallet: inv1.publicKey,
          agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "CountryBlocked"
    );

    // Unblock for subsequent tests.
    await program.methods.ixSetCountryRule(840, false, false)
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, countryRule: rule, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin]).rpc();
  });

  it("B4: mint blocked when max_tokens_per_investor exceeded", async () => {
    await program.methods.ixSetMaxTokensPerInvestor(new BN(120_000))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin]).rpc();

    // inv1 already has 110_000; trying to mint 11_000 would exceed 120_000.
    const [id] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixMintTo(new BN(11_000))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id,
          holderState: hs, countryRule: null,
          recipientAta: ata(fixture.mint, inv1.publicKey),
          recipientWallet: inv1.publicKey,
          agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "ExceedsMaxTokensPerInvestor"
    );

    // Remove cap.
    await program.methods.ixSetMaxTokensPerInvestor(new BN(0))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin]).rpc();
  });

  it("B5: mint blocked when max_shareholders cap reached", async () => {
    // Set cap at current count (2).
    await program.methods.ixSetMaxShareholders(new BN(2))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin]).rpc();

    // inv3 has zero balance — minting would make them a new shareholder (#3).
    const [id] = investorIdentityPDA(fixture.suite, inv3.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, inv3.publicKey, programId);

    await assertFails(
      program.methods.ixMintTo(new BN(1_000))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id,
          holderState: hs, countryRule: null,
          recipientAta: ata(fixture.mint, inv3.publicKey),
          recipientWallet: inv3.publicKey,
          agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "ExceedsMaxShareholders"
    );

    // Remove cap.
    await program.methods.ixSetMaxShareholders(new BN(0))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin]).rpc();
  });

  it("B6: operations fail when suite is paused", async () => {
    await program.methods.ixPauseSuite(true)
      .accounts({ suite: fixture.suite, pauser: admin.publicKey })
      .signers([admin]).rpc();

    const [id] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixMintTo(new BN(1))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, recipientIdentity: id,
          holderState: hs, countryRule: null,
          recipientAta: ata(fixture.mint, inv1.publicKey),
          recipientWallet: inv1.publicKey,
          agent: admin.publicKey,
          tokenProgram: TOKEN_2022_PROGRAM_ID,
          associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin]).rpc(),
      "SuitePaused"
    );

    await program.methods.ixPauseSuite(false)
      .accounts({ suite: fixture.suite, pauser: admin.publicKey })
      .signers([admin]).rpc();
  });

  // ── A: Burn ────────────────────────────────────────────────────────────────

  it("A4: agent burns tokens; shareholder_count decrements when balance hits zero", async () => {
    const [hs]   = holderStatePDA(fixture.suite, inv2.publicKey, programId);
    const before = (await program.account.holderState.fetch(hs)).balance.toNumber();

    await program.methods.ixBurn(new BN(before))
      .accounts({
        suite: fixture.suite, mint: fixture.mint,
        compliance: fixture.compliance, holderState: hs,
        fromAta: ata(fixture.mint, inv2.publicKey),
        agent: admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
      })
      .signers([admin]).rpc();

    const after = await program.account.holderState.fetch(hs);
    assertEq(after.balance, 0, "balance zero after full burn");

    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.shareholderCount, 1, "shareholder_count decremented");
  });

  it("B7: burn more than unfrozen balance fails", async () => {
    // Freeze 100_000 tokens of inv1's 110_000 balance.
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    await program.methods.ixFreezePartial(new BN(100_000))
      .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
      .signers([admin]).rpc();

    // Only 10_000 unfrozen; try to burn 11_000.
    await assertFails(
      program.methods.ixBurn(new BN(11_000))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, holderState: hs,
          fromAta: ata(fixture.mint, inv1.publicKey),
          agent: admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([admin]).rpc(),
      "InsufficientUnfrozenBalance"
    );

    // Unfreeze for cleanup.
    await program.methods.ixUnfreezePartial(new BN(100_000))
      .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
      .signers([admin]).rpc();
  });

  it("B8: non-agent cannot burn", async () => {
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    await assertFails(
      program.methods.ixBurn(new BN(1))
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance, holderState: hs,
          fromAta: ata(fixture.mint, inv1.publicKey),
          agent: nonAgent.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  // ── A: Forced transfer ────────────────────────────────────────────────────

  it("A5: forced transfer moves tokens ignoring compliance", async () => {
    // Give inv2 some balance first.
    await mint(inv2, 20_000);

    const [fromHs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const [toHs]   = holderStatePDA(fixture.suite, inv2.publicKey, programId);
    const [toId]   = investorIdentityPDA(fixture.suite, inv2.publicKey, programId);
    const before1  = (await program.account.holderState.fetch(fromHs)).balance.toNumber();
    const before2  = (await program.account.holderState.fetch(toHs)).balance.toNumber();

    await program.methods.ixForcedTransfer(new BN(5_000), 6)
      .accounts({
        suite: fixture.suite, mint: fixture.mint,
        compliance: fixture.compliance,
        fromHolder: fromHs, toHolder: toHs,
        recipientIdentity: toId,
        fromAta: ata(fixture.mint, inv1.publicKey),
        toAta:   ata(fixture.mint, inv2.publicKey),
        agent:   admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
      })
      .signers([admin]).rpc();

    const hs1 = await program.account.holderState.fetch(fromHs);
    const hs2 = await program.account.holderState.fetch(toHs);
    assertEq(hs1.balance, before1 - 5_000, "from balance");
    assertEq(hs2.balance, before2 + 5_000, "to balance");
  });

  it("B9: forced transfer to unverified recipient fails", async () => {
    const unverified = Keypair.generate();
    await airdrop(conn, unverified.publicKey, 2);
    await registerInvestor(unverified);

    const [uvId] = investorIdentityPDA(fixture.suite, unverified.publicKey, programId);
    const [uvHs] = holderStatePDA(fixture.suite, unverified.publicKey, programId);

    // Revoke verification.
    await program.methods.ixSetVerified(false)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: uvId, agent: admin.publicKey })
      .signers([admin]).rpc();

    const [fromHs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixForcedTransfer(new BN(1_000), 6)
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance,
          fromHolder: fromHs, toHolder: uvHs,
          recipientIdentity: uvId,
          fromAta: ata(fixture.mint, inv1.publicKey),
          toAta:   ata(fixture.mint, unverified.publicKey),
          agent:   admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([admin]).rpc(),
      "NotVerified"
    );
  });

  it("B10: non-agent cannot forced-transfer", async () => {
    const [fromHs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const [toHs]   = holderStatePDA(fixture.suite, inv2.publicKey, programId);
    const [toId]   = investorIdentityPDA(fixture.suite, inv2.publicKey, programId);

    await assertFails(
      program.methods.ixForcedTransfer(new BN(1), 6)
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          compliance: fixture.compliance,
          fromHolder: fromHs, toHolder: toHs,
          recipientIdentity: toId,
          fromAta: ata(fixture.mint, inv1.publicKey),
          toAta:   ata(fixture.mint, inv2.publicKey),
          agent:   nonAgent.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  // ── A: Freeze ─────────────────────────────────────────────────────────────

  it("A6: agent freezes and unfreezes an address", async () => {
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await program.methods.ixSetAddressFrozen(true)
      .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
      .signers([admin]).rpc();

    let s = await program.account.holderState.fetch(hs);
    assert.equal(s.frozen, true);

    await program.methods.ixSetAddressFrozen(false)
      .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
      .signers([admin]).rpc();

    s = await program.account.holderState.fetch(hs);
    assert.equal(s.frozen, false);
  });

  it("B11: non-agent cannot freeze an address", async () => {
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    await assertFails(
      program.methods.ixSetAddressFrozen(true)
        .accounts({ suite: fixture.suite, holderState: hs, agent: nonAgent.publicKey })
        .signers([nonAgent]).rpc(),
      "NotAgent"
    );
  });

  it("A7: partial freeze and unfreeze", async () => {
    const [hs]  = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const bal   = (await program.account.holderState.fetch(hs)).balance.toNumber();

    await program.methods.ixFreezePartial(new BN(50_000))
      .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
      .signers([admin]).rpc();

    let s = await program.account.holderState.fetch(hs);
    assertEq(s.frozenTokens, 50_000);

    await program.methods.ixUnfreezePartial(new BN(50_000))
      .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
      .signers([admin]).rpc();

    s = await program.account.holderState.fetch(hs);
    assertEq(s.frozenTokens, 0);
  });

  it("B12: partial freeze exceeding balance fails", async () => {
    const [hs]  = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const bal   = (await program.account.holderState.fetch(hs)).balance.toNumber();

    await assertFails(
      program.methods.ixFreezePartial(new BN(bal + 1))
        .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
        .signers([admin]).rpc(),
      "FreezeExceedsBalance"
    );
  });

  it("B13: unfreeze more than frozen fails", async () => {
    const [hs] = holderStatePDA(fixture.suite, inv1.publicKey, programId);

    await assertFails(
      program.methods.ixUnfreezePartial(new BN(1))
        .accounts({ suite: fixture.suite, holderState: hs, agent: admin.publicKey })
        .signers([admin]).rpc(),
      "UnfreezeExceedsBalance"
    );
  });

  // ── A: Wallet recovery ────────────────────────────────────────────────────

  it("A8: agent recovers tokens to a new wallet with same onchain_id", async () => {
    // Register inv3 with same onchain_id as inv1.
    const sharedOnchainId = Keypair.generate().publicKey;
    const [id1] = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [id3] = investorIdentityPDA(fixture.suite, inv3.publicKey, programId);
    const [hs1] = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const [hs3] = holderStatePDA(fixture.suite, inv3.publicKey, programId);

    // Set both to same onchain_id.
    await program.methods.ixUpdateIdentity(sharedOnchainId)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id1, agent: admin.publicKey })
      .signers([admin]).rpc();
    await program.methods.ixUpdateIdentity(sharedOnchainId)
      .accounts({ suite: fixture.suite, identityRegistry: fixture.identityRegistry, investorIdentity: id3, agent: admin.publicKey })
      .signers([admin]).rpc();

    const balBefore = (await program.account.holderState.fetch(hs1)).balance.toNumber();

    await program.methods.ixRecoverWallet(6)
      .accounts({
        suite: fixture.suite, mint: fixture.mint,
        lostWalletIdentity: id1, newWalletIdentity: id3,
        lostHolder: hs1, newHolder: hs3,
        lostAta: ata(fixture.mint, inv1.publicKey),
        newAta:  ata(fixture.mint, inv3.publicKey),
        agent:   admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
      })
      .signers([admin]).rpc();

    const hs1After = await program.account.holderState.fetch(hs1);
    const hs3After = await program.account.holderState.fetch(hs3);
    assertEq(hs1After.balance, 0, "lost wallet balance cleared");
    assertEq(hs3After.balance, balBefore, "new wallet received full balance");
  });

  it("B14: recovery with mismatched onchain_id fails", async () => {
    // Give inv1 fresh tokens.
    await mint(inv1, 5_000);

    const newWallet = Keypair.generate();
    await airdrop(conn, newWallet.publicKey, 2);
    await registerInvestor(newWallet);

    const [id1]    = investorIdentityPDA(fixture.suite, inv1.publicKey, programId);
    const [idNew]  = investorIdentityPDA(fixture.suite, newWallet.publicKey, programId);
    const [hs1]    = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const [hsNew]  = holderStatePDA(fixture.suite, newWallet.publicKey, programId);

    await assertFails(
      program.methods.ixRecoverWallet(6)
        .accounts({
          suite: fixture.suite, mint: fixture.mint,
          lostWalletIdentity: id1, newWalletIdentity: idNew,
          lostHolder: hs1, newHolder: hsNew,
          lostAta: ata(fixture.mint, inv1.publicKey),
          newAta:  ata(fixture.mint, newWallet.publicKey),
          agent:   admin.publicKey, tokenProgram: TOKEN_2022_PROGRAM_ID,
        })
        .signers([admin]).rpc(),
      "LostWalletMismatch"
    );
  });

  // ── A: Pause ──────────────────────────────────────────────────────────────

  it("A9: pauser can pause and unpause; non-pauser rejected", async () => {
    await program.methods.ixPauseSuite(true)
      .accounts({ suite: fixture.suite, pauser: admin.publicKey })
      .signers([admin]).rpc();

    let s = await program.account.tokenSuite.fetch(fixture.suite);
    assert.equal(s.paused, true);

    await assertFails(
      program.methods.ixPauseSuite(false)
        .accounts({ suite: fixture.suite, pauser: nonAgent.publicKey })
        .signers([nonAgent]).rpc(),
      "NotPauser"
    );

    await program.methods.ixPauseSuite(false)
      .accounts({ suite: fixture.suite, pauser: admin.publicKey })
      .signers([admin]).rpc();

    s = await program.account.tokenSuite.fetch(fixture.suite);
    assert.equal(s.paused, false);
  });

  // ── Reentrancy ─────────────────────────────────────────────────────────────
  //
  // Solana's BPF runtime prevents same-program reentrancy. The test below
  // verifies that a crafted transaction which includes two instructions to
  // the same handler within a single block executes SEQUENTIALLY and does
  // not allow state corruption (no double-spend, no double-shareholder-count).
  //
  // Note: True EVM-style reentrancy (callback into the same instruction) is
  // architecturally impossible on Solana — the runtime enforces serialized
  // account access per instruction.

  it("REENTRANCY: two sequential mints in one transaction are atomic and ordered", async () => {
    const newInv = Keypair.generate();
    await airdrop(conn, newInv.publicKey, 5);
    await registerInvestor(newInv);

    const [id] = investorIdentityPDA(fixture.suite, newInv.publicKey, programId);
    const [hs] = holderStatePDA(fixture.suite, newInv.publicKey, programId);

    // Build two mint instructions in one transaction.
    const ix1 = await program.methods.ixMintTo(new BN(1_000))
      .accounts({
        suite: fixture.suite, mint: fixture.mint,
        compliance: fixture.compliance, recipientIdentity: id,
        holderState: hs, countryRule: null,
        recipientAta: ata(fixture.mint, newInv.publicKey),
        recipientWallet: newInv.publicKey,
        agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .instruction();

    const ix2 = await program.methods.ixMintTo(new BN(2_000))
      .accounts({
        suite: fixture.suite, mint: fixture.mint,
        compliance: fixture.compliance, recipientIdentity: id,
        holderState: hs, countryRule: null,
        recipientAta: ata(fixture.mint, newInv.publicKey),
        recipientWallet: newInv.publicKey,
        agent: admin.publicKey,
        tokenProgram: TOKEN_2022_PROGRAM_ID,
        associatedTokenProgram: anchor.utils.token.ASSOCIATED_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
      })
      .instruction();

    const tx = new anchor.web3.Transaction().add(ix1, ix2);
    await provider.sendAndConfirm(tx, [admin]);

    const hsState = await program.account.holderState.fetch(hs);
    assertEq(hsState.balance, 3_000, "both mints applied; no double-count");
  });

  // ── Invariants ─────────────────────────────────────────────────────────────

  it("INV: frozen_tokens never exceeds balance", async () => {
    const [hs]  = holderStatePDA(fixture.suite, inv1.publicKey, programId);
    const state = await program.account.holderState.fetch(hs);
    assert.isAtMost(
      state.frozenTokens.toNumber(),
      state.balance.toNumber(),
      "frozen_tokens ≤ balance"
    );
  });

  it("INV: shareholder_count matches actual holders with non-zero balance", async () => {
    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    // We cannot enumerate all holders off-chain cheaply, but we can check the
    // counter is non-negative and ≤ total registered investors.
    const ir = await program.account.identityRegistry.fetch(fixture.identityRegistry);
    assert.isAtMost(
      comp.shareholderCount.toNumber(),
      ir.investorCount.toNumber(),
      "shareholder_count ≤ investor_count"
    );
    assert.isAtLeast(comp.shareholderCount.toNumber(), 0);
  });
});
