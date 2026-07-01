use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::Factory};

/// One-time instruction that creates the global Factory PDA.
/// Must be called once before any suite can be deployed.
pub fn handler(ctx: Context<InitializeFactory>) -> Result<()> {
    let factory = &mut ctx.accounts.factory;
    factory.admin              = ctx.accounts.admin.key();
    factory.paused             = false;
    factory.total_deployments  = 0;
    factory.bump               = ctx.bumps.factory;
    Ok(())
}

#[derive(Accounts)]
pub struct InitializeFactory<'info> {
    #[account(
        init,
        payer  = admin,
        space  = Factory::SPACE,
        seeds  = [SEED_FACTORY],
        bump,
    )]
    pub factory: Account<'info, Factory>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn pause_factory(ctx: Context<PauseFactory>, paused: bool) -> Result<()> {
    require!(
        ctx.accounts.admin.key() == ctx.accounts.factory.admin,
        TokenxError::NotAdmin
    );
    ctx.accounts.factory.paused = paused;
    Ok(())
}

#[derive(Accounts)]
pub struct PauseFactory<'info> {
    #[account(mut, seeds = [SEED_FACTORY], bump = factory.bump)]
    pub factory: Account<'info, Factory>,
    pub admin: Signer<'info>,
}
