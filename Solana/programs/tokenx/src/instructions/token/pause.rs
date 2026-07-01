use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::TokenSuite};

pub fn handler(ctx: Context<PauseSuite>, paused: bool) -> Result<()> {
    require!(
        ctx.accounts.pauser.key() == ctx.accounts.suite.pauser
            || ctx.accounts.pauser.key() == ctx.accounts.suite.admin,
        TokenxError::NotPauser
    );
    ctx.accounts.suite.paused = paused;
    Ok(())
}

#[derive(Accounts)]
pub struct PauseSuite<'info> {
    #[account(mut, seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,
    pub pauser: Signer<'info>,
}
