/**
 * Identity tests
 *
 * Coverage:
 *   ✔ register_identity   — agent happy path; verified = true by default
 *   ✔ register_identity   — non-agent rejected
 *   ✔ register_identity   — duplicate wallet rejected
 *   ✔ update_identity     — agent changes onchain_id
 *   ✔ update_identity     — non-agent rejected
 *   ✔ update_country      — agent changes country
 *   ✔ update_country      — non-agent rejected
 *   ✔ delete_identity     — agent closes PDA; investor_count decrements
 *   ✔ delete_identity     — non-agent rejected
 *   ✔ set_verified false  — agent revokes KYC
 *   ✔ set_verified true   — agent restores KYC
 *   ✔ set_verified        — non-agent rejected
 *   ✔ investor_count      — increments on register, decrements on delete
 *
 * Access-control matrix:
 *   Caller      | register | update | update_country | delete | set_verified
 *   ────────────|──────────|────────|────────────────|────────|─────────────
 *   agent/admin |  PASS    |  PASS  |      PASS      |  PASS  |    PASS
 *   random      |  FAIL    |  FAIL  |      FAIL      |  FAIL  |    FAIL
 */
import * as anchor from "@coral-xyz/anchor";
import { Keypair, SystemProgram, PublicKey } from "@solana/web3.js";
import { TOKEN_2022_PROGRAM_ID } from "@solana/spl-token";
import { Program, BN } from "@coral-xyz/anchor";
import { assert } from "chai";
import { Tokenx } from "../target/types/tokenx";
import {
  factoryPDA,
  buildSuiteFixture,
  investorIdentityPDA,
  identityRegistryPDA,
  holderStatePDA,
  ZERO_COMPLIANCE,
  TokenType,
  assertFails,
  assertEq,
  airdrop,
} from "./helpers/setup";

describe("Identity", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program   = anchor.workspace.Tokenx as Program<Tokenx>;
  const programId = program.programId;
  const conn      = provider.connection;

  const admin      = Keypair.generate();
  const nonAgent   = Keypair.generate();
  const investor1  = Keypair.generate();
  const investor2  = Keypair.generate();
  const onchainId1 = Keypair.generate().publicKey;
  const onchainId2 = Keypair.generate().publicKey;

  const ISSUER_ID = "IDENTITY-TEST-SUITE";
  let   fixture: ReturnType<typeof buildSuiteFixture>;
  const [factory] = factoryPDA(programId);

  before(async () => {
    await Promise.all([
      airdrop(conn, admin.publicKey),
      airdrop(conn, nonAgent.publicKey),
      airdrop(conn, investor1.publicKey),
      airdrop(conn, investor2.publicKey),
    ]);

    // Initialize factory.
    await program.methods
      .ixInitializeFactory()
      .accounts({ factory, admin: admin.publicKey, systemProgram: SystemProgram.programId })
      .signers([admin])
      .rpc();

    // Deploy a security suite.
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
  });

  // ── A: Happy paths ─────────────────────────────────────────────────────────

  it("A1: agent registers investor with verified=true and investor_count increments", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await program.methods
      .ixRegisterIdentity(onchainId1, 840) // 840 = USA
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        wallet:           investor1.publicKey,
        agent:            admin.publicKey,
        systemProgram:    SystemProgram.programId,
      })
      .signers([admin])
      .rpc();

    const id = await program.account.investorIdentity.fetch(investorIdentity);
    assert.equal(id.wallet.toBase58(),    investor1.publicKey.toBase58());
    assert.equal(id.onchainId.toBase58(), onchainId1.toBase58());
    assert.equal(id.country,             840);
    assert.equal(id.verified,            true);

    const ir = await program.account.identityRegistry.fetch(fixture.identityRegistry);
    assertEq(ir.investorCount, 1, "investor_count after first register");
  });

  it("A2: agent registers a second investor; investor_count becomes 2", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor2.publicKey, programId);

    await program.methods
      .ixRegisterIdentity(onchainId2, 566) // 566 = Nigeria
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        wallet:           investor2.publicKey,
        agent:            admin.publicKey,
        systemProgram:    SystemProgram.programId,
      })
      .signers([admin])
      .rpc();

    const ir = await program.account.identityRegistry.fetch(fixture.identityRegistry);
    assertEq(ir.investorCount, 2, "investor_count after second register");
  });

  it("A3: agent updates investor ONCHAINID", async () => {
    const newId = Keypair.generate().publicKey;
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await program.methods
      .ixUpdateIdentity(newId)
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        agent:            admin.publicKey,
      })
      .signers([admin])
      .rpc();

    const id = await program.account.investorIdentity.fetch(investorIdentity);
    assert.equal(id.onchainId.toBase58(), newId.toBase58());
  });

  it("A4: agent updates investor country", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await program.methods
      .ixUpdateCountry(276) // 276 = Germany
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        agent:            admin.publicKey,
      })
      .signers([admin])
      .rpc();

    const id = await program.account.investorIdentity.fetch(investorIdentity);
    assert.equal(id.country, 276);
  });

  it("A5: agent sets verified=false, then restores to true", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await program.methods
      .ixSetVerified(false)
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        agent:            admin.publicKey,
      })
      .signers([admin])
      .rpc();

    let id = await program.account.investorIdentity.fetch(investorIdentity);
    assert.equal(id.verified, false, "should be unverified");

    await program.methods
      .ixSetVerified(true)
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        agent:            admin.publicKey,
      })
      .signers([admin])
      .rpc();

    id = await program.account.investorIdentity.fetch(investorIdentity);
    assert.equal(id.verified, true, "should be re-verified");
  });

  it("A6: agent deletes investor; investor_count decrements and PDA is closed", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor2.publicKey, programId);

    await program.methods
      .ixDeleteIdentity()
      .accounts({
        suite:            fixture.suite,
        identityRegistry: fixture.identityRegistry,
        investorIdentity,
        agent:            admin.publicKey,
        systemProgram:    SystemProgram.programId,
      })
      .signers([admin])
      .rpc();

    const ir = await program.account.identityRegistry.fetch(fixture.identityRegistry);
    assertEq(ir.investorCount, 1, "investor_count after delete");

    // PDA account should be closed (null).
    const accountInfo = await conn.getAccountInfo(investorIdentity);
    assert.isNull(accountInfo, "closed PDA should not exist");
  });

  // ── B: Rejection / sad paths ───────────────────────────────────────────────

  it("B1: non-agent cannot register an investor", async () => {
    const investor3  = Keypair.generate();
    const onchainId3 = Keypair.generate().publicKey;
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor3.publicKey, programId);

    await assertFails(
      program.methods
        .ixRegisterIdentity(onchainId3, 826) // 826 = UK
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity,
          wallet:           investor3.publicKey,
          agent:            nonAgent.publicKey,
          systemProgram:    SystemProgram.programId,
        })
        .signers([nonAgent])
        .rpc(),
      "NotAgent"
    );
  });

  it("B2: registering the same wallet twice is rejected", async () => {
    // investor1 is already registered from A1.
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await assertFails(
      program.methods
        .ixRegisterIdentity(onchainId1, 840)
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity,
          wallet:           investor1.publicKey,
          agent:            admin.publicKey,
          systemProgram:    SystemProgram.programId,
        })
        .signers([admin])
        .rpc(),
      /already in use/i
    );
  });

  it("B3: non-agent cannot update identity", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await assertFails(
      program.methods
        .ixUpdateIdentity(Keypair.generate().publicKey)
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity,
          agent:            nonAgent.publicKey,
        })
        .signers([nonAgent])
        .rpc(),
      "NotAgent"
    );
  });

  it("B4: non-agent cannot update country", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await assertFails(
      program.methods
        .ixUpdateCountry(840)
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity,
          agent:            nonAgent.publicKey,
        })
        .signers([nonAgent])
        .rpc(),
      "NotAgent"
    );
  });

  it("B5: non-agent cannot delete identity", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await assertFails(
      program.methods
        .ixDeleteIdentity()
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity,
          agent:            nonAgent.publicKey,
          systemProgram:    SystemProgram.programId,
        })
        .signers([nonAgent])
        .rpc(),
      "NotAgent"
    );
  });

  it("B6: non-agent cannot set verified flag", async () => {
    const [investorIdentity] = investorIdentityPDA(fixture.suite, investor1.publicKey, programId);

    await assertFails(
      program.methods
        .ixSetVerified(false)
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity,
          agent:            nonAgent.publicKey,
        })
        .signers([nonAgent])
        .rpc(),
      "NotAgent"
    );
  });

  // ── Regression: investor_count stays consistent after partial deletes ───────

  it("REG: investor_count remains consistent after mixed register/delete", async () => {
    const extras = [Keypair.generate(), Keypair.generate(), Keypair.generate()];

    for (const kp of extras) {
      await airdrop(conn, kp.publicKey, 2);
      const [id] = investorIdentityPDA(fixture.suite, kp.publicKey, programId);
      await program.methods
        .ixRegisterIdentity(Keypair.generate().publicKey, 250)
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity: id,
          wallet:           kp.publicKey,
          agent:            admin.publicKey,
          systemProgram:    SystemProgram.programId,
        })
        .signers([admin])
        .rpc();
    }

    let ir = await program.account.identityRegistry.fetch(fixture.identityRegistry);
    const countAfterAdd = ir.investorCount.toNumber();

    // Delete two of the three extras.
    for (const kp of extras.slice(0, 2)) {
      const [id] = investorIdentityPDA(fixture.suite, kp.publicKey, programId);
      await program.methods
        .ixDeleteIdentity()
        .accounts({
          suite:            fixture.suite,
          identityRegistry: fixture.identityRegistry,
          investorIdentity: id,
          agent:            admin.publicKey,
          systemProgram:    SystemProgram.programId,
        })
        .signers([admin])
        .rpc();
    }

    ir = await program.account.identityRegistry.fetch(fixture.identityRegistry);
    assertEq(ir.investorCount, countAfterAdd - 2, "investor_count after two deletes");
  });
});
