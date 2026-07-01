use anchor_lang::prelude::*;
use crate::constants::*;

/// Per-holder per-suite state tracked by the compliance layer.
///
/// Seeds: [SEED_HOLDER_STATE, suite.key(), wallet.key()]
///
/// This mirrors the compliance mappings in the EVM ComplianceModule:
/// `holderBalance`, `lockUpEnd`, `walletAllowlist`, and the full-freeze flag.
#[account]
pub struct HolderState {
    pub suite: Pubkey,
    pub wallet: Pubkey,
    /// Compliance-tracked token balance (mirrors on-chain SPL balance for compliance math).
    pub balance: u64,
    /// Amount of tokens that are partially frozen and cannot be transferred or burned.
    pub frozen_tokens: u64,
    /// Unix timestamp after which transfers from this wallet are permitted (0 = no lockup).
    pub lockup_end: i64,
    /// If true the wallet is completely frozen — no transfers in or out.
    pub frozen: bool,
    /// Explicit wallet allowlist flag (only consulted if `wallet_allowlist_enabled`).
    pub wallet_allowed: bool,
    pub bump: u8,
}

impl HolderState {
    pub const SPACE: usize = 8 + HOLDER_STATE_SIZE;
}
