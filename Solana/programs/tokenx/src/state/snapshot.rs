use anchor_lang::prelude::*;
use crate::constants::*;

/// A yield distribution snapshot for one suite.
///
/// Seeds: [SEED_SNAPSHOT, yield_distributor.key(), id.to_le_bytes()]
///
/// Each snapshot captures the eligible supply at a point in time and the
/// total funds deposited for distribution. Individual investor balances at
/// snapshot time are stored in `ClaimRecord` accounts.
#[account]
pub struct Snapshot {
    pub yield_distributor:     Pubkey,
    pub id:                    u64,
    pub slot:                  u64,
    pub timestamp:             i64,
    pub total_eligible_supply: u64,
    pub total_funds:           u64,
    /// SPL mint of the payout token; Pubkey::default() = native SOL.
    pub payout_mint:           Pubkey,
    pub reclaim_deadline:      i64,
    pub total_claimed:         u64,
    /// False once admin reclaims unclaimed funds.
    pub active:                bool,
    /// True when produced by `create_scheduled_coupon` (BondTerms-constrained).
    pub scheduled:             bool,
    pub description:           String,
    pub bump:                  u8,
}

impl Snapshot {
    pub const SPACE: usize = 8 + SNAPSHOT_SIZE;
}
