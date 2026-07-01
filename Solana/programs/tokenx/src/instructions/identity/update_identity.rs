use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{IdentityRegistry, InvestorIdentity, TokenSuite}};

pub fn update_identity_handler(
    ctx: Context<UpdateIdentity>,
    new_onchain_id: Pubkey,
) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.identity_registry.agent
            || ctx.accounts.agent.key() == ctx.accounts.identity_registry.admin,
        TokenxError::NotAgent
    );
    ctx.accounts.investor_identity.onchain_id = new_onchain_id;
    Ok(())
}

pub fn update_country_handler(ctx: Context<UpdateIdentity>, country: u16) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.identity_registry.agent
            || ctx.accounts.agent.key() == ctx.accounts.identity_registry.admin,
        TokenxError::NotAgent
    );
    ctx.accounts.investor_identity.country = country;
    Ok(())
}

#[derive(Accounts)]
pub struct UpdateIdentity<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_IDENTITY_REGISTRY, suite.key().as_ref()], bump = identity_registry.bump)]
    pub identity_registry: Account<'info, IdentityRegistry>,

    #[account(
        mut,
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), investor_identity.wallet.as_ref()],
        bump  = investor_identity.bump,
    )]
    pub investor_identity: Account<'info, InvestorIdentity>,

    pub agent: Signer<'info>,
}
