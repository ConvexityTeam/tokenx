// ── PDA Seeds ─────────────────────────────────────────────────────────────────
pub const SEED_FACTORY:            &[u8] = b"factory";
pub const SEED_SUITE:              &[u8] = b"suite";
pub const SEED_MINT:               &[u8] = b"mint";
pub const SEED_IDENTITY_REGISTRY:  &[u8] = b"identity_registry";
pub const SEED_INVESTOR_IDENTITY:  &[u8] = b"identity";
pub const SEED_COMPLIANCE:         &[u8] = b"compliance";
pub const SEED_HOLDER_STATE:       &[u8] = b"holder";
pub const SEED_COUNTRY_RULE:       &[u8] = b"country_rule";
pub const SEED_YIELD_DIST:         &[u8] = b"yield_dist";
pub const SEED_SNAPSHOT:           &[u8] = b"snapshot";
pub const SEED_CLAIM_RECORD:       &[u8] = b"claim";
pub const SEED_BOND_TERMS:         &[u8] = b"bond_terms";

// ── Limits ────────────────────────────────────────────────────────────────────
pub const MAX_ISSUER_ID_LEN:    usize = 64;
pub const MAX_DESCRIPTION_LEN:  usize = 128;
pub const MAX_RATE_BPS:         u16   = 10_000;

// ── Space constants ───────────────────────────────────────────────────────────
// Anchor discriminator is always 8 bytes; all sizes below EXCLUDE it.

pub const FACTORY_SIZE:           usize = 32 + 1 + 8 + 1;             // 42
pub const TOKEN_SUITE_SIZE:       usize = (MAX_ISSUER_ID_LEN + 4)     // issuer_id String
    + 1                                                                 // token_type
    + 32 * 8                                                            // 8 Pubkeys
    + 1 + 8 + 1 + 1;                                                   // paused, deployed_at, bumps
pub const IDENTITY_REGISTRY_SIZE: usize = 32 + 32 + 32 + 8 + 1;      // 105
pub const INVESTOR_IDENTITY_SIZE: usize = 32 + 32 + 32 + 2 + 1 + 1;  // 100
pub const COMPLIANCE_SIZE:        usize = 32 + 8 + 8 + 8 + 8 + 1 + 1 + 32 + 1; // 101
pub const HOLDER_STATE_SIZE:      usize = 32 + 32 + 8 + 8 + 8 + 1 + 1 + 1;     // 91
pub const COUNTRY_RULE_SIZE:      usize = 32 + 2 + 1 + 1 + 1;         // 37
pub const YIELD_DIST_SIZE:        usize = 32 + 8 + 32 + 32 + 32 + 1 + 1;       // 138
pub const SNAPSHOT_SIZE:          usize = 32 + 8 + 8 + 8 + 8 + 8 + 32 + 8 + 8 + 1 + 1
    + (MAX_DESCRIPTION_LEN + 4) + 1;                                   // ~261
pub const CLAIM_RECORD_SIZE:      usize = 32 + 32 + 8 + 1 + 1;        // 74
pub const BOND_TERMS_SIZE:        usize = 32 + 32 + 2 + 8 + 1 + 8 + 8 + 8 + 8 + 8 + 8 + 1 + 8 + 1 + 1 + 1; // 135
