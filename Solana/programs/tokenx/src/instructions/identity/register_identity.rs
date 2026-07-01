use anchor_lang::prelude::*;
use crate::{
    constants::*,
    errors::TokenxError,
    state::{IdentityRegistry, InvestorIdentity, TokenSuite},
};

pub fn handler(
    ctx: Context<RegisterIdentity>,
    onchain_id: Pubkey,
    country:    u16,
) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.identity_registry.agent
            || ctx.accounts.agent.key() == ctx.accounts.identity_registry.admin,
        TokenxError::NotAgent
    );

    let id = &mut ctx.accounts.investor_identity;
    id.suite      = ctx.accounts.suite.key();
    id.wallet     = ctx.accounts.wallet.key();
    id.onchain_id = onchain_id;
    id.country    = country;
    id.verified   = true;
    id.bump       = ctx.bumps.investor_identity;

    ctx.accounts.identity_registry.investor_count = ctx
        .accounts
        .identity_registry
        .investor_count
        .checked_add(1)
        .ok_or(TokenxError::Overflow)?;

    Ok(())
}

#[derive(Accounts)]
pub struct RegisterIdentity<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(mut, seeds = [SEED_IDENTITY_REGISTRY, suite.key().as_ref()], bump = identity_registry.bump)]
    pub identity_registry: Account<'info, IdentityRegistry>,

    #[account(
        init,
        payer  = agent,
        space  = InvestorIdentity::SPACE,
        seeds  = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), wallet.key().as_ref()],
        bump,
    )]
    pub investor_identity: Account<'info, InvestorIdentity>,

    /// CHECK: The wallet being registered — not a signer.
    pub wallet: UncheckedAccount<'info>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub system_program: Program<'info, System>,
}
