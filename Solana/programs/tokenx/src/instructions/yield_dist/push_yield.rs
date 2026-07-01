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

/// Agent-initiated push for a single investor's yield.
///
/// Called once per investor.  Clients batch multiple calls to pay all investors.
pub fn handler(ctx: Context<PushYield>, snapshot_id: u64) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.yield_distributor.agent
            || ctx.accounts.agent.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAgent
    );

    let snap   = &ctx.accounts.snapshot;
    let record = &ctx.accounts.claim_record;
    let id     = &ctx.accounts.investor_identity;
    let holder = &ctx.accounts.holder_state;

    require!(snap.active,     TokenxError::SnapshotInactive);
    require!(!record.claimed, TokenxError::AlreadyClaimed);

    // Skip ineligible investors without reverting (matches EVM pushYield behaviour).
    if !id.verified || holder.frozen || record.balance_at_snapshot == 0 {
        return Ok(());
    }

    let amount = (record.balance_at_snapshot as u128)
        .checked_mul(snap.total_funds as u128)
        .ok_or(TokenxError::Overflow)?
        / snap.total_eligible_supply as u128;
    let amount = amount as u64;
    if amount == 0 { return Ok(()); }

    // ── Pay out ───────────────────────────────────────────────────
    if snap.payout_mint == Pubkey::default() {
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &snap.key(),
            &ctx.accounts.investor_wallet.key(),
            amount,
        );
        anchor_lang::solana_program::program::invoke(
            &ix,
            &[
                ctx.accounts.snapshot.to_account_info(),
                ctx.accounts.investor_wallet.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;
    } else {
        let snap_ata = ctx.accounts.snapshot_ata.as_ref().ok_or(TokenxError::SnapshotInactive)?;
        let inv_ata  = ctx.accounts.investor_ata.as_ref().ok_or(TokenxError::SnapshotInactive)?;
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from:      snap_ata.to_account_info(),
                    mint:      ctx.accounts.payout_mint.to_account_info(),
                    to:        inv_ata.to_account_info(),
                    authority: ctx.accounts.snapshot.to_account_info(),
                },
            ),
            amount,
            ctx.accounts.payout_mint.decimals,
        )?;
    }

    ctx.accounts.claim_record.claimed = true;
    ctx.accounts.snapshot.total_claimed = ctx
        .accounts
        .snapshot
        .total_claimed
        .checked_add(amount)
        .ok_or(TokenxError::Overflow)?;

    Ok(())
}

#[derive(Accounts)]
#[instruction(snapshot_id: u64)]
pub struct PushYield<'info> {
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

    /// CHECK: Recipient wallet; validated via investor_identity.wallet.
    #[account(mut, address = investor_identity.wallet)]
    pub investor_wallet: UncheckedAccount<'info>,

    pub agent: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
