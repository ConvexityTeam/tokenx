use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::Token2022,
    token_interface::{transfer_checked, Mint, TokenAccount, TransferChecked},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{Snapshot, TokenSuite, YieldDistributor},
};

/// Admin reclaims unclaimed yield after the reclaim deadline has passed.
pub fn handler(ctx: Context<ReclaimUnclaimed>, snapshot_id: u64) -> Result<()> {
    require!(
        ctx.accounts.admin.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAdmin
    );

    let snap  = &ctx.accounts.snapshot;
    require!(snap.active, TokenxError::SnapshotInactive);

    let now = Clock::get()?.unix_timestamp;
    require!(now >= snap.reclaim_deadline, TokenxError::ReclaimDeadlineNotReached);

    let unclaimed = snap
        .total_funds
        .saturating_sub(snap.total_claimed);
    require!(unclaimed > 0, TokenxError::NothingToReclaim);

    // ── Pay unclaimed to admin ────────────────────────────────────
    if snap.payout_mint == Pubkey::default() {
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &snap.key(),
            &ctx.accounts.admin.key(),
            unclaimed,
        );
        anchor_lang::solana_program::program::invoke(
            &ix,
            &[
                ctx.accounts.snapshot.to_account_info(),
                ctx.accounts.admin.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;
    } else {
        let snap_ata  = ctx.accounts.snapshot_ata.as_ref().ok_or(TokenxError::SnapshotInactive)?;
        let admin_ata = ctx.accounts.admin_ata.as_ref().ok_or(TokenxError::SnapshotInactive)?;
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from:      snap_ata.to_account_info(),
                    mint:      ctx.accounts.payout_mint.to_account_info(),
                    to:        admin_ata.to_account_info(),
                    authority: ctx.accounts.snapshot.to_account_info(),
                },
            ),
            unclaimed,
            ctx.accounts.payout_mint.decimals,
        )?;
    }

    ctx.accounts.snapshot.active = false;
    Ok(())
}

#[derive(Accounts)]
#[instruction(snapshot_id: u64)]
pub struct ReclaimUnclaimed<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_YIELD_DIST, suite.key().as_ref()], bump = yield_distributor.bump)]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        mut,
        seeds = [SEED_SNAPSHOT, yield_distributor.key().as_ref(), &snapshot_id.to_le_bytes()],
        bump  = snapshot.bump,
    )]
    pub snapshot: Account<'info, Snapshot>,

    pub payout_mint: InterfaceAccount<'info, Mint>,

    #[account(mut)]
    pub snapshot_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut)]
    pub admin_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
