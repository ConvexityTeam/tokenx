use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{IdentityRegistry, InvestorIdentity, TokenSuite}};

pub fn handler(ctx: Context<DeleteIdentity>) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.identity_registry.agent
            || ctx.accounts.agent.key() == ctx.accounts.identity_registry.admin,
        TokenxError::NotAgent
    );
    ctx.accounts.identity_registry.investor_count = ctx
        .accounts
        .identity_registry
        .investor_count
        .saturating_sub(1);
    // The account is closed by the `close = agent` constraint below.
    Ok(())
}

#[derive(Accounts)]
pub struct DeleteIdentity<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(mut, seeds = [SEED_IDENTITY_REGISTRY, suite.key().as_ref()], bump = identity_registry.bump)]
    pub identity_registry: Account<'info, IdentityRegistry>,

    #[account(
        mut,
        seeds  = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), investor_identity.wallet.as_ref()],
        bump   = investor_identity.bump,
        close  = agent,
    )]
    pub investor_identity: Account<'info, InvestorIdentity>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub system_program: Program<'info, System>,
}
