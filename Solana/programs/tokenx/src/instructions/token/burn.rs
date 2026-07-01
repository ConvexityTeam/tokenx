use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::{burn, Burn, Token2022},
    token_interface::{Mint, TokenAccount},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{ComplianceConfig, HolderState, TokenSuite},
};

pub fn handler(ctx: Context<BurnCtx>, amount: u64) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );

    let holder = &ctx.accounts.holder_state;
    let available = holder.balance.saturating_sub(holder.frozen_tokens);
    require!(available >= amount, TokenxError::InsufficientUnfrozenBalance);

    // ── SPL Token-2022 burn CPI ───────────────────────────────────
    let suite_key = ctx.accounts.suite.issuer_id.as_bytes().to_vec();
    let seeds: &[&[u8]] = &[SEED_SUITE, &suite_key, &[ctx.accounts.suite.bump]];
    burn(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Burn {
                mint:      ctx.accounts.mint.to_account_info(),
                from:      ctx.accounts.from_ata.to_account_info(),
                authority: ctx.accounts.suite.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;

    // ── Update compliance state ───────────────────────────────────
    let holder = &mut ctx.accounts.holder_state;
    holder.balance = holder.balance.saturating_sub(amount);
    if holder.balance == 0 {
        ctx.accounts.compliance.shareholder_count =
            ctx.accounts.compliance.shareholder_count.saturating_sub(1);
    }

    Ok(())
}

#[derive(Accounts)]
pub struct BurnCtx<'info> {
    #[account(mut, seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,

    #[account(mut, address = suite.mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [SEED_COMPLIANCE, suite.key().as_ref()], bump = compliance.bump)]
    pub compliance: Account<'info, ComplianceConfig>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), holder_state.wallet.as_ref()],
        bump  = holder_state.bump,
        constraint = holder_state.suite == suite.key(),
    )]
    pub holder_state: Account<'info, HolderState>,

    #[account(mut)]
    pub from_ata: InterfaceAccount<'info, TokenAccount>,

    pub agent: Signer<'info>,

    pub token_program: Program<'info, Token2022>,
}
