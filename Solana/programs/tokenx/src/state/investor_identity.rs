use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-investor KYC record for one token suite.
///
/// Seeds: [SEED_INVESTOR_IDENTITY, suite.key(), wallet.key()]
#[account]
pub struct InvestorIdentity {
    pub suite:      Pubkey,
    pub wallet:     Pubkey,
    /// Equivalent of the ONCHAINID contract address on EVM —
    /// a Solana public key that identifies the legal entity.
    pub onchain_id: Pubkey,
    /// ISO 3166-1 numeric country code.
    pub country:    u16,
    pub verified:   bool,
    pub bump:       u8,
}

impl InvestorIdentity {
    pub const SPACE: usize = 8 + INVESTOR_IDENTITY_SIZE;
}
