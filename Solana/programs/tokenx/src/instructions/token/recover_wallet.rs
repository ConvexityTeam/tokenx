use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::{transfer_checked, TransferChecked, Token2022},
    token_interface::{Mint, TokenAccount},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{HolderState, InvestorIdentity, TokenSuite},
};

/// Recover tokens from a lost wallet to a new wallet registered under the
/// same ONCHAINID (legal entity identity).
///
/// Mirrors SecurityToken.recoveryAddress() on EVM.
pub fn handler(ctx: Context<RecoverWallet>, decimals: u8) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );

    let lost_id = &ctx.accounts.lost_wallet_identity;
    let new_id  = &ctx.accounts.new_wallet_identity;

    require!(
        lost_id.onchain_id == new_id.onchain_id,
        TokenxError::LostWalletMismatch
    );
    require!(new_id.verified, TokenxError::NotVerified);

    let amount = ctx.accounts.lost_holder.balance;
    if amount == 0 { return Ok(()); }

    // ── SPL Token-2022 transfer CPI ───────────────────────────────
    let suite_id  = ctx.accounts.suite.issuer_id.as_bytes().to_vec();
    let seeds: &[&[u8]] = &[SEED_SUITE, &suite_id, &[ctx.accounts.suite.bump]];
    transfer_checked(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from:      ctx.accounts.lost_ata.to_account_info(),
                mint:      ctx.accounts.mint.to_account_info(),
                to:        ctx.accounts.new_ata.to_account_info(),
                authority: ctx.accounts.suite.to_account_info(),
            },
            &[seeds],
        ),
        amount,
        decimals,
    )?;

    // ── Migrate compliance state ──────────────────────────────────
    let frozen_tokens = ctx.accounts.lost_holder.frozen_tokens;

    let lost_holder = &mut ctx.accounts.lost_holder;
    lost_holder.balance       = 0;
    lost_holder.frozen_tokens = 0;
    lost_holder.frozen        = false;

    let new_holder = &mut ctx.accounts.new_holder;
    new_holder.balance        = new_holder.balance.checked_add(amount).ok_or(TokenxError::Overflow)?;
    new_holder.frozen_tokens  = frozen_tokens;

    Ok(())
}

#[derive(Accounts)]
pub struct RecoverWallet<'info> {
    #[account(mut, seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,

    #[account(address = suite.mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), lost_wallet_identity.wallet.as_ref()],
        bump  = lost_wallet_identity.bump,
        constraint = lost_wallet_identity.suite == suite.key(),
    )]
    pub lost_wallet_identity: Account<'info, InvestorIdentity>,

    #[account(
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), new_wallet_identity.wallet.as_ref()],
        bump  = new_wallet_identity.bump,
        constraint = new_wallet_identity.suite == suite.key(),
    )]
    pub new_wallet_identity: Account<'info, InvestorIdentity>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), lost_wallet_identity.wallet.as_ref()],
        bump  = lost_holder.bump,
    )]
    pub lost_holder: Account<'info, HolderState>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), new_wallet_identity.wallet.as_ref()],
        bump  = new_holder.bump,
    )]
    pub new_holder: Account<'info, HolderState>,

    #[account(mut)]
    pub lost_ata: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub new_ata: InterfaceAccount<'info, TokenAccount>,

    pub agent: Signer<'info>,

    pub token_program: Program<'info, Token2022>,
}
