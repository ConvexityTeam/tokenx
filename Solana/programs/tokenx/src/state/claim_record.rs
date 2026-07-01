use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-investor claim record for one snapshot.
///
/// Seeds: [SEED_CLAIM_RECORD, snapshot.key(), wallet.key()]
///
/// Created lazily on first `create_snapshot` call that includes the investor
/// (or during `push_yield`). Stores the investor's balance at snapshot time
/// and whether the claim has been executed.
#[account]
pub struct ClaimRecord {
    pub snapshot:            Pubkey,
    pub wallet:              Pubkey,
    /// Token balance at snapshot time used for pro-rata yield calculation.
    pub balance_at_snapshot: u64,
    pub claimed:             bool,
    pub bump:                u8,
}

impl ClaimRecord {
    pub const SPACE: usize = 8 + CLAIM_RECORD_SIZE;
}
