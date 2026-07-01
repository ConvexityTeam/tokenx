use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{ComplianceConfig, HolderState, TokenSuite}};

/// Set the `wallet_allowed` flag on a holder's state account.
/// Only meaningful when `compliance.wallet_allowlist_enabled == true`.
pub fn handler(ctx: Context<SetWalletAllowed>, allowed: bool) -> Result<()> {
    require!(
        ctx.accounts.admin.key() == ctx.accounts.compliance.admin,
        TokenxError::NotAdmin
    );
    ctx.accounts.holder_state.wallet_allowed = allowed;
    Ok(())
}

#[derive(Accounts)]
pub struct SetWalletAllowed<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_COMPLIANCE, suite.key().as_ref()], bump = compliance.bump)]
    pub compliance: Account<'info, ComplianceConfig>,

    /// HolderState is created lazily at first mint — must already exist.
    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), holder_state.wallet.as_ref()],
        bump  = holder_state.bump,
        constraint = holder_state.suite == suite.key(),
    )]
    pub holder_state: Account<'info, HolderState>,

    pub admin: Signer<'info>,
}
