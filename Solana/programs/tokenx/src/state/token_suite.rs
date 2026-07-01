use anchor_lang::prelude::*;
use crate::constants::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq)]
pub enum TokenType {
    Security,
    YieldBearing,
    Bond,
}

/// Central registry record for one token suite.
///
/// Seeds: [SEED_SUITE, issuer_id.as_bytes()]
#[account]
pub struct TokenSuite {
    /// Unique issuer identifier — immutable after deployment.
    pub issuer_id: String,
    pub token_type: TokenType,
    /// SPL Token-2022 mint for this token.
    pub mint: Pubkey,
    /// PDA of the IdentityRegistry for this suite.
    pub identity_registry: Pubkey,
    /// PDA of the ComplianceConfig for this suite.
    pub compliance: Pubkey,
    /// PDA of the YieldDistributor; Pubkey::default() for SECURITY suites.
    pub yield_distributor: Pubkey,
    /// PDA of BondTerms; Pubkey::default() for non-BOND suites.
    pub bond_terms: Pubkey,
    /// Holds admin, agent, and pauser authority keys.
    pub admin: Pubkey,
    pub agent: Pubkey,
    pub pauser: Pubkey,
    /// When true all token operations are blocked.
    pub paused: bool,
    pub deployed_by: Pubkey,
    pub deployed_at: i64,
    pub bump: u8,
    pub mint_bump: u8,
}

impl TokenSuite {
    pub const SPACE: usize = 8 + TOKEN_SUITE_SIZE;
}
