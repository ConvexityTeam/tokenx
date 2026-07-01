use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::{transfer_checked, TransferChecked, Token2022},
    token_interface::{Mint, TokenAccount},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{ComplianceConfig, HolderState, InvestorIdentity, TokenSuite},
};

/// Agent-initiated forced transfer — bypasses compliance module but still
/// requires the recipient to be KYC-verified (mirrors forcedTransfer on EVM).
pub fn handler(ctx: Context<ForcedTransferCtx>, amount: u64, decimals: u8) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );
    require!(ctx.accounts.recipient_identity.verified, TokenxError::NotVerified);

    let from_holder = &ctx.accounts.from_holder;
    let available   = from_holder.balance.saturating_sub(from_holder.frozen_tokens);
    require!(available >= amount, TokenxError::InsufficientUnfrozenBalance);

    // ── SPL Token-2022 transfer CPI ───────────────────────────────
    let suite_id  = ctx.accounts.suite.issuer_id.as_bytes().to_vec();
    let seeds: &[&[u8]] = &[SEED_SUITE, &suite_id, &[ctx.accounts.suite.bump]];
    transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from:      ctx.accounts.from_ata.to_account_info(),
                mint:      ctx.accounts.mint.to_account_info(),
                to:        ctx.accounts.to_ata.to_account_info(),
                authority: ctx.accounts.suite.to_account_info(),
            },
            &[seeds],
        ),
        amount,
        decimals,
    )?;

    // ── Update compliance state ───────────────────────────────────
    let from = &mut ctx.accounts.from_holder;
    from.balance = from.balance.saturating_sub(amount);
    let from_balance = from.balance;

    let to = &mut ctx.accounts.to_holder;
    let to_was_zero = to.balance == 0;
    to.balance = to.balance.checked_add(amount).ok_or(TokenxError::Overflow)?;

    let comp = &mut ctx.accounts.compliance;
    if from_balance == 0 {
        comp.shareholder_count = comp.shareholder_count.saturating_sub(1);
    }
    if to_was_zero && amount > 0 {
        comp.shareholder_count = comp.shareholder_count
            .checked_add(1)
            .ok_or(TokenxError::Overflow)?;
    }

    Ok(())
}

#[derive(Accounts)]
pub struct ForcedTransferCtx<'info> {
    #[account(mut, seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,

    #[account(address = suite.mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [SEED_COMPLIANCE, suite.key().as_ref()], bump = compliance.bump)]
    pub compliance: Account<'info, ComplianceConfig>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), from_holder.wallet.as_ref()],
        bump  = from_holder.bump,
        constraint = from_holder.suite == suite.key(),
    )]
    pub from_holder: Account<'info, HolderState>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), to_holder.wallet.as_ref()],
        bump  = to_holder.bump,
        constraint = to_holder.suite == suite.key(),
    )]
    pub to_holder: Account<'info, HolderState>,

    #[account(
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), recipient_identity.wallet.as_ref()],
        bump  = recipient_identity.bump,
        constraint = recipient_identity.suite == suite.key()
            && recipient_identity.wallet == to_holder.wallet,
    )]
    pub recipient_identity: Account<'info, InvestorIdentity>,

    #[account(mut)]
    pub from_ata: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub to_ata: InterfaceAccount<'info, TokenAccount>,

    pub agent: Signer<'info>,

    pub token_program: Program<'info, Token2022>,
}
