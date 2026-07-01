use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::Token2022,
    token_interface::{transfer_checked, Mint, TokenAccount, TransferChecked},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{
        BondTerms, ClaimRecord, HolderState, InvestorIdentity, Snapshot, TokenSuite,
        YieldDistributor,
    },
};

/// Create a BondTerms-constrained coupon distribution snapshot.
///
/// Mirrors YieldDistributor.createScheduledCoupon() on EVM:
///   - Validates that a coupon is currently due.
///   - Computes the required fund amount = coupon_per_token * eligible_supply.
///   - Pulls exactly that amount from the agent's ATA / lamports.
///   - Records per-investor balances in ClaimRecord PDAs.
///   - Advances bond_terms.next_coupon_date.
///
/// Like create_snapshot, this uses a two-phase pattern:
///   1. open_scheduled_coupon  — validates BondTerms, opens Snapshot.
///   2. add_snapshot_record    — reused from yield_dist module.
///   3. finalize_coupon        — sets active = true, advances coupon date.
pub fn open_handler(
    ctx:         Context<OpenScheduledCoupon>,
    reclaim_after_secs: i64,
    description: String,
) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.yield_distributor.agent
            || ctx.accounts.agent.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAgent
    );

    let bt = &ctx.accounts.bond_terms;
    let now = Clock::get()?.unix_timestamp;
    require!(!bt.defaulted,        TokenxError::BondDefaulted);
    require!(!bt.principal_repaid, TokenxError::BondClosed);
    require!(bt.is_coupon_due(now), TokenxError::CouponNotDue);

    // Open snapshot in inactive state; finalize_coupon will set it active.
    let yd      = &mut ctx.accounts.yield_distributor;
    let snap_id = yd.snapshot_count.checked_add(1).ok_or(TokenxError::Overflow)?;
    yd.snapshot_count = snap_id;

    let clock = Clock::get()?;
    let snap  = &mut ctx.accounts.snapshot;
    snap.yield_distributor     = ctx.accounts.yield_distributor.key();
    snap.id                    = snap_id;
    snap.slot                  = clock.slot;
    snap.timestamp             = clock.unix_timestamp;
    snap.total_eligible_supply = 0;
    snap.total_funds           = 0; // computed in finalize_coupon after all records added
    snap.payout_mint           = ctx.accounts.payout_mint.key();
    snap.reclaim_deadline      = clock.unix_timestamp
        .checked_add(reclaim_after_secs)
        .unwrap_or(i64::MAX);
    snap.total_claimed         = 0;
    snap.active                = false;
    snap.scheduled             = true;
    snap.description           = description;
    snap.bump                  = ctx.bumps.snapshot;

    Ok(())
}

/// Finalise a scheduled coupon: compute required funds, pull them in, advance coupon date.
pub fn finalize_handler(ctx: Context<FinalizeScheduledCoupon>, snapshot_id: u64) -> Result<()> {
    require!(
        ctx.accounts.agent.key() == ctx.accounts.yield_distributor.agent
            || ctx.accounts.agent.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAgent
    );

    let snap = &ctx.accounts.snapshot;
    require!(!snap.active, TokenxError::SnapshotInactive);
    require!(snap.total_eligible_supply > 0, TokenxError::NoEligibleHolders);

    let bt           = &ctx.accounts.bond_terms;
    let per_token    = bt.coupon_per_token().ok_or(TokenxError::Overflow)?;
    require!(per_token > 0, TokenxError::ZeroCoupon);

    let required: u64 = (per_token as u128)
        .checked_mul(snap.total_eligible_supply as u128)
        .ok_or(TokenxError::Overflow)?
        .checked_div(1_000_000_000) // face value normalised by 1e9
        .ok_or(TokenxError::Overflow)? as u64;
    require!(required > 0, TokenxError::ZeroCoupon);

    // Pull funds.
    if snap.payout_mint == Pubkey::default() {
        require!(ctx.accounts.agent.lamports() >= required, TokenxError::WrongSolAmount);
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &ctx.accounts.agent.key(),
            &ctx.accounts.snapshot.key(),
            required,
        );
        anchor_lang::solana_program::program::invoke(
            &ix,
            &[
                ctx.accounts.agent.to_account_info(),
                ctx.accounts.snapshot.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;
    } else {
        let agent_ata = ctx.accounts.agent_ata.as_ref().ok_or(TokenxError::WrongSolAmount)?;
        let snap_ata  = ctx.accounts.snapshot_ata.as_ref().ok_or(TokenxError::WrongSolAmount)?;
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from:      agent_ata.to_account_info(),
                    mint:      ctx.accounts.payout_mint.to_account_info(),
                    to:        snap_ata.to_account_info(),
                    authority: ctx.accounts.agent.to_account_info(),
                },
            ),
            required,
            ctx.accounts.payout_mint.decimals,
        )?;
    }

    // Advance coupon date in BondTerms.
    let bt = &mut ctx.accounts.bond_terms;
    let prev = bt.next_coupon_date;
    let next = prev
        .checked_add(bt.coupon_period_secs)
        .unwrap_or(bt.maturity_date)
        .min(bt.maturity_date);
    bt.next_coupon_date = next;

    // Activate snapshot.
    let snap = &mut ctx.accounts.snapshot;
    snap.total_funds = required;
    snap.active      = true;

    Ok(())
}

// ── Account contexts ──────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct OpenScheduledCoupon<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(
        mut,
        seeds     = [SEED_YIELD_DIST, suite.key().as_ref()],
        bump      = yield_distributor.bump,
        constraint = yield_distributor.suite == suite.key(),
    )]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        seeds     = [SEED_BOND_TERMS, suite.key().as_ref()],
        bump      = bond_terms.bump,
        constraint = bond_terms.suite == suite.key(),
    )]
    pub bond_terms: Account<'info, BondTerms>,

    #[account(
        init,
        payer  = agent,
        space  = Snapshot::SPACE,
        seeds  = [
            SEED_SNAPSHOT,
            yield_distributor.key().as_ref(),
            &(yield_distributor.snapshot_count + 1).to_le_bytes(),
        ],
        bump,
    )]
    pub snapshot: Account<'info, Snapshot>,

    pub payout_mint: InterfaceAccount<'info, Mint>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub system_program: Program<'info, System>,
    pub token_program:  Program<'info, Token2022>,
}

#[derive(Accounts)]
#[instruction(snapshot_id: u64)]
pub struct FinalizeScheduledCoupon<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_YIELD_DIST, suite.key().as_ref()], bump = yield_distributor.bump)]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        mut,
        seeds     = [SEED_BOND_TERMS, suite.key().as_ref()],
        bump      = bond_terms.bump,
        constraint = bond_terms.suite == suite.key(),
    )]
    pub bond_terms: Account<'info, BondTerms>,

    #[account(
        mut,
        seeds = [SEED_SNAPSHOT, yield_distributor.key().as_ref(), &snapshot_id.to_le_bytes()],
        bump  = snapshot.bump,
    )]
    pub snapshot: Account<'info, Snapshot>,

    pub payout_mint: InterfaceAccount<'info, Mint>,

    #[account(mut)]
    pub agent_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut)]
    pub snapshot_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
