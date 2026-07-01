/**
 * Tokenx test suite — main entry point.
 *
 * Importing the individual test files causes mocha to register their
 * describe() / it() blocks automatically.  This file adds a top-level
 * smoke test that verifies the program is deployed and reachable before
 * the domain tests run.
 */
import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { assert } from "chai";
import { Tokenx } from "../target/types/tokenx";

// Import all domain test modules — their describe blocks self-register.
import "./factory.test";
import "./identity.test";
import "./compliance.test";
import "./token.test";
import "./yield.test";
import "./bond.test";
import "./invariants.test";

describe("Tokenx — smoke test", () => {
  anchor.setProvider(anchor.AnchorProvider.env());
  const program = anchor.workspace.Tokenx as Program<Tokenx>;

  it("program is deployed and reachable", async () => {
    const info = await anchor
      .getProvider()
      .connection.getAccountInfo(program.programId);
    assert.isNotNull(info, "program account not found — is the validator running?");
    assert.isTrue(info!.executable, "program account is not executable");
  });
});
