use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-suite yield distributor config.
///
/// Seeds: [SEED_YIELD_DIST, suite.key()]
#[account]
pub struct YieldDistributor {
    pub suite:          Pubkey,
    /// Running count of all snapshots created. Used as the next snapshot seed.
    pub snapshot_count: u64,
    pub admin:          Pubkey,
    pub agent:          Pubkey,
    pub pauser:         Pubkey,
    pub paused:         bool,
    pub bump:           u8,
}

impl YieldDistributor {
    pub const SPACE: usize = 8 + YIELD_DIST_SIZE;
}
