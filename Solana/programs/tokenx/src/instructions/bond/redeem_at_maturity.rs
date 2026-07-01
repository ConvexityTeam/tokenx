use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::{burn, Burn, Token2022},
    token_interface::{transfer_checked, Mint, TokenAccount, TransferChecked},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{BondTerms, ComplianceConfig, HolderState, InvestorIdentity, TokenSuite},
};

/// Burn a holder's tokens and transfer principal = balance * face_value_per_token.
///
/// The issuer must have deposited principal funds into the suite's vault
/// (payout ATA or lamports on the suite PDA) prior to calling this.
///
/// Mirrors SecurityToken.redeemAtMaturity() on EVM.
pub fn handler(ctx: Context<RedeemAtMaturity>, decimals: u8) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );

    let bt  = &ctx.accounts.bond_terms;
    let now = Clock::get()?.unix_timestamp;
    require!(bt.is_matured(now), TokenxError::NotMatured);
    require!(!bt.defaulted,      TokenxError::BondDefaulted);

    let holder = &ctx.accounts.holder_state;
    let id     = &ctx.accounts.investor_identity;
    require!(id.verified, TokenxError::NotVerified);
    require!(holder.balance > 0, TokenxError::InsufficientUnfrozenBalance);

    let balance   = holder.balance;
    let principal = (balance as u128)
        .checked_mul(bt.face_value_per_token as u128)
        .ok_or(TokenxError::Overflow)?
        .checked_div(1_000_000_000) // normalise by 1e9 (token decimals)
        .ok_or(TokenxError::Overflow)? as u64;
    require!(principal > 0, TokenxError::ZeroCoupon);

    // ── Burn token ────────────────────────────────────────────────
    let suite_id  = ctx.accounts.suite.issuer_id.as_bytes().to_vec();
    let seeds: &[&[u8]] = &[SEED_SUITE, &suite_id, &[ctx.accounts.suite.bump]];
    burn(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            Burn {
                mint:      ctx.accounts.mint.to_account_info(),
                from:      ctx.accounts.holder_ata.to_account_info(),
                authority: ctx.accounts.suite.to_account_info(),
            },
            &[seeds],
        ),
        balance,
    )?;

    // ── Transfer principal ────────────────────────────────────────
    if ctx.accounts.payout_mint.key() == Pubkey::default() {
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &ctx.accounts.suite.key(),
            &ctx.accounts.investor_wallet.key(),
            principal,
        );
        anchor_lang::solana_program::program::invoke_signed(
            &ix,
            &[
                ctx.accounts.suite.to_account_info(),
                ctx.accounts.investor_wallet.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[seeds],
        )?;
    } else {
        let vault_ata    = ctx.accounts.vault_ata.as_ref().ok_or(TokenxError::NoBondTerms)?;
        let investor_ata = ctx.accounts.investor_payout_ata.as_ref().ok_or(TokenxError::NoBondTerms)?;
        transfer_checked(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from:      vault_ata.to_account_info(),
                    mint:      ctx.accounts.payout_mint.to_account_info(),
                    to:        investor_ata.to_account_info(),
                    authority: ctx.accounts.suite.to_account_info(),
                },
                &[seeds],
            ),
            principal,
            decimals,
        )?;
    }

    // ── Update compliance state ───────────────────────────────────
    let holder = &mut ctx.accounts.holder_state;
    holder.balance       = 0;
    holder.frozen_tokens = 0;
    ctx.accounts.compliance.shareholder_count =
        ctx.accounts.compliance.shareholder_count.saturating_sub(1);

    // If total supply is now zero mark bond principal as repaid.
    if ctx.accounts.mint.supply == 0 {
        ctx.accounts.bond_terms.principal_repaid = true;
    }

    Ok(())
}

#[derive(Accounts)]
pub struct RedeemAtMaturity<'info> {
    #[account(mut, seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,

    #[account(mut, address = suite.mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [SEED_COMPLIANCE, suite.key().as_ref()], bump = compliance.bump)]
    pub compliance: Account<'info, ComplianceConfig>,

    #[account(
        mut,
        seeds     = [SEED_BOND_TERMS, suite.key().as_ref()],
        bump      = bond_terms.bump,
        constraint = bond_terms.suite == suite.key(),
    )]
    pub bond_terms: Account<'info, BondTerms>,

    #[account(
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), investor_identity.wallet.as_ref()],
        bump  = investor_identity.bump,
        constraint = investor_identity.suite == suite.key(),
    )]
    pub investor_identity: Account<'info, InvestorIdentity>,

    #[account(
        mut,
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), investor_identity.wallet.as_ref()],
        bump  = holder_state.bump,
    )]
    pub holder_state: Account<'info, HolderState>,

    #[account(mut)]
    pub holder_ata: InterfaceAccount<'info, TokenAccount>,

    /// Payout mint for principal (pass system program for native SOL).
    pub payout_mint: InterfaceAccount<'info, Mint>,

    /// Suite's vault ATA holding deposited principal funds (SPL only).
    #[account(mut)]
    pub vault_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    /// Investor's payout ATA (SPL only).
    #[account(mut)]
    pub investor_payout_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    /// CHECK: Investor wallet; validated via investor_identity.wallet.
    #[account(mut, address = investor_identity.wallet)]
    pub investor_wallet: UncheckedAccount<'info>,

    pub agent: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
