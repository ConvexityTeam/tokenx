use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-suite compliance rules.
///
/// Seeds: [SEED_COMPLIANCE, suite.key()]
#[account]
pub struct ComplianceConfig {
    pub suite: Pubkey,
    /// 0 = no cap.
    pub max_shareholders:        u64,
    /// 0 = no cap, in token atoms.
    pub max_tokens_per_investor: u64,
    /// Lock-up duration in seconds applied at mint time.
    pub lockup_duration:         i64,
    /// Live count of distinct holders with a non-zero balance.
    pub shareholder_count:       u64,
    /// When true every transfer/mint must pass the wallet allowlist check.
    pub wallet_allowlist_enabled: bool,
    /// false = blocked-country mode, true = allowed-country mode.
    pub country_allowlist_mode:  bool,
    pub admin:                   Pubkey,
    pub bump:                    u8,
}

impl ComplianceConfig {
    pub const SPACE: usize = 8 + COMPLIANCE_SIZE;
}
