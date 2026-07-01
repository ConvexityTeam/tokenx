use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-suite KYC registry configuration.
///
/// Seeds: [SEED_IDENTITY_REGISTRY, suite.key()]
#[account]
pub struct IdentityRegistry {
    pub suite:          Pubkey,
    pub admin:          Pubkey,
    pub agent:          Pubkey,
    pub investor_count: u64,
    pub bump:           u8,
}

impl IdentityRegistry {
    pub const SPACE: usize = 8 + IDENTITY_REGISTRY_SIZE;
}
