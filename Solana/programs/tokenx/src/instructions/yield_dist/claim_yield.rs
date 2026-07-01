use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::Token2022,
    token_interface::{transfer_checked, Mint, TokenAccount, TransferChecked},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{ClaimRecord, HolderState, InvestorIdentity, Snapshot, TokenSuite, YieldDistributor},
};

/// Investor pulls their pro-rata yield from a finalised snapshot.
///
/// Yield = (balance_at_snapshot / total_eligible_supply) * total_funds
pub fn handler(ctx: Context<ClaimYield>, snapshot_id: u64) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);

    let snap   = &ctx.accounts.snapshot;
    let record = &ctx.accounts.claim_record;
    let holder = &ctx.accounts.holder_state;
    let id     = &ctx.accounts.investor_identity;

    require!(snap.active,           TokenxError::SnapshotInactive);
    require!(!record.claimed,       TokenxError::AlreadyClaimed);
    require!(id.verified,           TokenxError::NotVerified);
    require!(!holder.frozen,        TokenxError::SenderFrozen);
    require!(record.balance_at_snapshot > 0, TokenxError::NoBalanceAtSnapshot);

    let amount = (record.balance_at_snapshot as u128)
        .checked_mul(snap.total_funds as u128)
        .ok_or(TokenxError::Overflow)?
        / snap.total_eligible_supply as u128;
    let amount = amount as u64;

    // ── Pay out ───────────────────────────────────────────────────
    pay_investor(
        &ctx.accounts.snapshot,
        &ctx.accounts.snapshot_ata,
        &ctx.accounts.investor_ata,
        &ctx.accounts.payout_mint,
        &ctx.accounts.investor_wallet,
        &ctx.accounts.token_program,
        &ctx.accounts.system_program,
        amount,
    )?;

    // ── Mark claimed ──────────────────────────────────────────────
    ctx.accounts.claim_record.claimed = true;
    ctx.accounts.snapshot.total_claimed = ctx
        .accounts
        .snapshot
        .total_claimed
        .checked_add(amount)
        .ok_or(TokenxError::Overflow)?;

    Ok(())
}

fn pay_investor<'info>(
    snapshot:      &Account<'info, Snapshot>,
    snapshot_ata:  &Option<InterfaceAccount<'info, TokenAccount>>,
    investor_ata:  &Option<InterfaceAccount<'info, TokenAccount>>,
    payout_mint:   &InterfaceAccount<'info, Mint>,
    investor_wallet: &UncheckedAccount<'info>,
    token_program: &Program<'info, Token2022>,
    system_program: &Program<'info, System>,
    amount:        u64,
) -> Result<()> {
    if snapshot.payout_mint == Pubkey::default() {
        // SOL: transfer lamports from snapshot PDA rent to investor.
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &snapshot.key(),
            &investor_wallet.key(),
            amount,
        );
        anchor_lang::solana_program::program::invoke(
            &ix,
            &[
                snapshot.to_account_info(),
                investor_wallet.to_account_info(),
                system_program.to_account_info(),
            ],
        )?;
    } else {
        // SPL token: transfer from snapshot ATA to investor ATA.
        let snap_ata = snapshot_ata.as_ref().ok_or(TokenxError::SnapshotInactive)?;
        let inv_ata  = investor_ata.as_ref().ok_or(TokenxError::SnapshotInactive)?;
        transfer_checked(
            CpiContext::new(
                token_program.to_account_info(),
                TransferChecked {
                    from:      snap_ata.to_account_info(),
                    mint:      payout_mint.to_account_info(),
                    to:        inv_ata.to_account_info(),
                    authority: snapshot.to_account_info(),
                },
            ),
            amount,
            payout_mint.decimals,
        )?;
    }
    Ok(())
}

#[derive(Accounts)]
#[instruction(snapshot_id: u64)]
pub struct ClaimYield<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_YIELD_DIST, suite.key().as_ref()], bump = yield_distributor.bump)]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        mut,
        seeds = [SEED_SNAPSHOT, yield_distributor.key().as_ref(), &snapshot_id.to_le_bytes()],
        bump  = snapshot.bump,
    )]
    pub snapshot: Account<'info, Snapshot>,

    #[account(
        mut,
        seeds = [SEED_CLAIM_RECORD, snapshot.key().as_ref(), investor_identity.wallet.as_ref()],
        bump  = claim_record.bump,
    )]
    pub claim_record: Account<'info, ClaimRecord>,

    #[account(
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), investor_identity.wallet.as_ref()],
        bump  = investor_identity.bump,
        constraint = investor_identity.suite == suite.key(),
    )]
    pub investor_identity: Account<'info, InvestorIdentity>,

    #[account(
        seeds = [SEED_HOLDER_STATE, suite.key().as_ref(), investor_identity.wallet.as_ref()],
        bump  = holder_state.bump,
    )]
    pub holder_state: Account<'info, HolderState>,

    pub payout_mint: InterfaceAccount<'info, Mint>,

    #[account(mut)]
    pub snapshot_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut)]
    pub investor_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    /// CHECK: Recipient wallet validated via investor_identity.
    #[account(mut, address = investor_identity.wallet)]
    pub investor_wallet: UncheckedAccount<'info>,

    pub investor: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
