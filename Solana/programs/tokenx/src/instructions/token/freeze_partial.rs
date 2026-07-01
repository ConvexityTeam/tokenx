use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{HolderState, TokenSuite}};

/// Freeze a specific token amount without freezing the entire wallet.
pub fn freeze_partial_handler(ctx: Context<FreezePartial>, amount: u64) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );
    let holder = &mut ctx.accounts.holder_state;
    require!(
        holder.balance >= holder.frozen_tokens.checked_add(amount).ok_or(TokenxError::Overflow)?,
        TokenxError::FreezeExceedsBalance
    );
    holder.frozen_tokens = holder.frozen_tokens.checked_add(amount).ok_or(TokenxError::Overflow)?;
    Ok(())
}

/// Unfreeze a previously partially-frozen token amount.
pub fn unfreeze_partial_handler(ctx: Context<FreezePartial>, amount: u64) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );
    let holder = &mut ctx.accounts.holder_state;
    require!(holder.frozen_tokens >= amount, TokenxError::UnfreezeExceedsBalance);
    holder.frozen_tokens = holder.frozen_tokens.saturating_sub(amount);
    Ok(())
}

#[derive(Accounts)]
pub struct FreezePartial<'info> {
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
