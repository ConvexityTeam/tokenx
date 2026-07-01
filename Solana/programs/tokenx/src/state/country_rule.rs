use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-country compliance rule for one suite.
///
/// Seeds: [SEED_COUNTRY_RULE, suite.key(), country.to_le_bytes()]
///
/// The account is created on first use and can be closed when no longer needed.
/// In block-list mode (`compliance.country_allowlist_mode == false`) only
/// `blocked` is consulted. In allow-list mode only `allowed` is consulted.
#[account]
pub struct CountryRule {
    pub suite:   Pubkey,
    pub country: u16,
    /// True = this country is blocked in block-list mode.
    pub blocked: bool,
    /// True = this country is permitted in allow-list mode.
    pub allowed: bool,
    pub bump:    u8,
}

impl CountryRule {
    pub const SPACE: usize = 8 + COUNTRY_RULE_SIZE;
}
