use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{HolderState, TokenSuite}};

/// Freeze or unfreeze an address entirely — no transfers in or out allowed.
pub fn set_address_frozen_handler(ctx: Context<FreezeAccount>, frozen: bool) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );
    ctx.accounts.holder_state.frozen = frozen;
    Ok(())
}

#[derive(Accounts)]
pub struct FreezeAccount<'info> {
    #[account(seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), holder_state.wallet.as_ref()],
        bump  = holder_state.bump,
        constraint = holder_state.suite == suite.key(),
    )]
    pub holder_state: Account<'info, HolderState>,

    pub agent: Signer<'info>,
}
