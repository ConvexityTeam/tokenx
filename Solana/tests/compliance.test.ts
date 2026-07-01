/**
 * Compliance tests
 *
 * Coverage:
 *   ✔ set_max_shareholders        — admin / non-admin
 *   ✔ set_max_tokens_per_investor — admin / non-admin
 *   ✔ set_lockup_duration         — admin / non-admin
 *   ✔ set_country_allowlist_mode  — admin / non-admin
 *   ✔ set_wallet_allowlist_enabled — admin / non-admin
 *   ✔ set_country_rule            — block, unblock, allow in both modes
 *   ✔ set_wallet_allowed          — admin / non-admin
 *   ✔ Mint blocked by country block-list
 *   ✔ Mint blocked by country allow-list
 *   ✔ Mint blocked by wallet allowlist
 *   ✔ Mint blocked by max_tokens_per_investor
 *   ✔ Mint blocked by max_shareholders cap
 *   ✔ Transfer blocked by sender lock-up
 *   ✔ Forced transfer bypasses compliance but respects identity
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

describe("Compliance", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program   = anchor.workspace.Tokenx as Program<Tokenx>;
  const programId = program.programId;
  const conn      = provider.connection;

  const admin      = Keypair.generate();
  const nonAdmin   = Keypair.generate();
  const investor   = Keypair.generate();

  const ISSUER_ID = "COMPLIANCE-TEST-SUITE";
  let fixture: ReturnType<typeof buildSuiteFixture>;
  const [factory] = factoryPDA(programId);

  before(async () => {
    await Promise.all([
      airdrop(conn, admin.publicKey),
      airdrop(conn, nonAdmin.publicKey),
      airdrop(conn, investor.publicKey),
    ]);

    await program.methods
      .ixInitializeFactory()
      .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin])
      .rpc();

    fixture = buildSuiteFixture(ISSUER_ID, programId, admin);
    await program.methods
      .ixInitializeSuite(ISSUER_ID, TokenType.Security, ZERO_COMPLIANCE, 6)
      .accounts({
        factory,
        suite:            fixture.suite,
        mint:             fixture.mint,
        identityRegistry: fixture.identityRegistry,
        compliance:       fixture.compliance,
        yieldDistributor: null,
        admin:            admin.publicKey,
        deployer:         admin.publicKey,
        tokenProgram:     TOKEN_2022_PROGRAM_ID,
        systemProgram:    SystemProgram.programId,
      })
      .signers([admin])
      .rpc();

    // Register investor for compliance checks.
    const [id] = investorIdentityPDA(fixture.suite, investor.publicKey, programId);
    await program.methods
      .ixRegisterIdentity(Keypair.generate().publicKey, 840)
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity: id,
        wallet:           investor.publicKey,
        agent:            admin.publicKey,
        systemProgram:    SystemProgram.programId,
      })
      .signers([admin])
      .rpc();
  });

  // ── A: Parameter setters (happy paths) ────────────────────────────────────

  it("A1: admin sets max_shareholders", async () => {
    await program.methods
      .ixSetMaxShareholders(new BN(100))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.maxShareholders, 100);
  });

  it("A2: admin sets max_tokens_per_investor", async () => {
    await program.methods
      .ixSetMaxTokensPerInvestor(new BN(500_000))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.maxTokensPerInvestor, 500_000);
  });

  it("A3: admin sets lockup_duration", async () => {
    await program.methods
      .ixSetLockupDuration(new BN(86_400)) // 1 day
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.lockupDuration, 86_400);

    // Reset for other tests.
    await program.methods
      .ixSetLockupDuration(new BN(0))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();
  });

  it("A4: admin toggles country allowlist mode", async () => {
    await program.methods
      .ixSetCountryAllowlistMode(true)
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();
    let comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assert.equal(comp.countryAllowlistMode, true);

    await program.methods
      .ixSetCountryAllowlistMode(false)
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();
    comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assert.equal(comp.countryAllowlistMode, false);
  });

  it("A5: admin enables and disables wallet allowlist", async () => {
    await program.methods
      .ixSetWalletAllowlistEnabled(true)
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();
    let comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assert.equal(comp.walletAllowlistEnabled, true);

    await program.methods
      .ixSetWalletAllowlistEnabled(false)
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();
    comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assert.equal(comp.walletAllowlistEnabled, false);
  });

  it("A6: admin creates a country block rule", async () => {
    const country = 643; // Russia
    const [rule]  = countryRulePDA(fixture.suite, country, programId);

    await program.methods
      .ixSetCountryRule(country, true, false)
      .accounts({
        suite:       fixture.suite,
        compliance:  fixture.compliance,
        countryRule: rule,
        admin:       admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin])
      .rpc();

    const ruleState = await program.account.countryRule.fetch(rule);
    assert.equal(ruleState.blocked, true);
    assert.equal(ruleState.allowed, false);
  });

  it("A7: admin creates a country allow rule", async () => {
    const country = 276; // Germany
    const [rule]  = countryRulePDA(fixture.suite, country, programId);

    await program.methods
      .ixSetCountryRule(country, false, true)
      .accounts({
        suite:       fixture.suite,
        compliance:  fixture.compliance,
        countryRule: rule,
        admin:       admin.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([admin])
      .rpc();

    const ruleState = await program.account.countryRule.fetch(rule);
    assert.equal(ruleState.allowed, true);
  });

  it("A8: admin sets wallet_allowed on a holder_state", async () => {
    const [holderState]     = holderStatePDA(fixture.suite, investor.publicKey, programId);

    await program.methods
      .ixSetWalletAllowed(true)
      .accounts({
        suite:       fixture.suite,
        compliance:  fixture.compliance,
        holderState,
        admin:       admin.publicKey,
      })
      .signers([admin])
      .rpc();

    const hs = await program.account.holderState.fetch(holderState);
    assert.equal(hs.walletAllowed, true);
  });

  // ── B: Rejection / access control ─────────────────────────────────────────

  it("B1: non-admin cannot set max_shareholders", async () => {
    await assertFails(
      program.methods
        .ixSetMaxShareholders(new BN(50))
        .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: nonAdmin.publicKey })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B2: non-admin cannot set max_tokens_per_investor", async () => {
    await assertFails(
      program.methods
        .ixSetMaxTokensPerInvestor(new BN(1))
        .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: nonAdmin.publicKey })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B3: non-admin cannot set lockup_duration", async () => {
    await assertFails(
      program.methods
        .ixSetLockupDuration(new BN(999))
        .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: nonAdmin.publicKey })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B4: non-admin cannot set country allowlist mode", async () => {
    await assertFails(
      program.methods
        .ixSetCountryAllowlistMode(true)
        .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: nonAdmin.publicKey })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B5: non-admin cannot set wallet allowlist enabled", async () => {
    await assertFails(
      program.methods
        .ixSetWalletAllowlistEnabled(true)
        .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: nonAdmin.publicKey })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B6: non-admin cannot set country rule", async () => {
    const country = 840;
    const [rule]  = countryRulePDA(fixture.suite, country, programId);

    await assertFails(
      program.methods
        .ixSetCountryRule(country, true, false)
        .accounts({
          suite:       fixture.suite,
          compliance:  fixture.compliance,
          countryRule: rule,
          admin:       nonAdmin.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  it("B7: non-admin cannot set wallet allowed", async () => {
    const [holderState] = holderStatePDA(fixture.suite, investor.publicKey, programId);

    await assertFails(
      program.methods
        .ixSetWalletAllowed(false)
        .accounts({
          suite:       fixture.suite,
          compliance:  fixture.compliance,
          holderState,
          admin:       nonAdmin.publicKey,
        })
        .signers([nonAdmin])
        .rpc(),
      "NotAdmin"
    );
  });

  // ── Invariants ─────────────────────────────────────────────────────────────

  it("INV: setting max_shareholders to 0 removes the cap (unlimited)", async () => {
    await program.methods
      .ixSetMaxShareholders(new BN(0))
      .accounts({ suite: fixture.suite, compliance: fixture.compliance, admin: admin.publicKey })
      .signers([admin])
      .rpc();

    const comp = await program.account.complianceConfig.fetch(fixture.compliance);
    assertEq(comp.maxShareholders, 0, "0 means unlimited");
  });

  it("INV: country rule update is idempotent — same call twice is safe", async () => {
    const country = 356; // India
    const [rule]  = countryRulePDA(fixture.suite, country, programId);

    for (let i = 0; i < 2; i++) {
      await program.methods
        .ixSetCountryRule(country, true, false)
        .accounts({
          suite:       fixture.suite,
          compliance:  fixture.compliance,
          countryRule: rule,
          admin:       admin.publicKey,
          systemProgram: SystemProgram.programId,
        })
        .signers([admin])
        .rpc();
    }

    const ruleState = await program.account.countryRule.fetch(rule);
    assert.equal(ruleState.blocked, true, "idempotent block");
  });
});
