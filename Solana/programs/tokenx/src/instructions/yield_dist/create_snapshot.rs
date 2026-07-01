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

/// Create a yield snapshot and deposit payout funds.
///
/// For each investor in the `investor_wallets` list the instruction checks
/// eligibility (verified + not frozen) and records their balance at snapshot
/// time as a `ClaimRecord` PDA.  The total eligible supply is stored on the
/// `Snapshot` account.
///
/// Funds are transferred in by the agent:
///   - SOL:  lamports transferred directly from the agent account.
///   - SPL:  token transfer_checked CPI from the agent's ATA.
///
/// Note: Anchor does not support variable-length remaining-accounts patterns
/// cleanly for per-investor PDAs, so this instruction processes ONE investor
/// at a time.  Clients batch multiple `create_snapshot_record` calls after
/// the snapshot is opened with `open_snapshot`.
///
/// A simpler two-phase approach is used here:
///   1. `open_snapshot`  — creates the Snapshot PDA, records metadata,
///                         deposits funds, sets `active = false` until finalised.
///   2. `add_snapshot_record` — for each investor, creates ClaimRecord PDA.
///   3. `finalize_snapshot` — sets `active = true` once all records are added.
pub fn open_snapshot_handler(
    ctx:         Context<OpenSnapshot>,
    fund_amount: u64,
    reclaim_after_secs: i64,
    description: String,
) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.yield_distributor.agent
            || ctx.accounts.agent.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAgent
    );
    require!(
        matches!(
            ctx.accounts.suite.token_type,
            crate::state::TokenType::YieldBearing | crate::state::TokenType::Bond
        ),
        TokenxError::NotYieldSuite
    );

    let yd      = &mut ctx.accounts.yield_distributor;
    let snap_id = yd.snapshot_count.checked_add(1).ok_or(TokenxError::Overflow)?;
    yd.snapshot_count = snap_id;

    // Transfer funds into the snapshot vault (PDA-owned ATA or lamport reserve).
    require!(fund_amount > 0, TokenxError::NothingToReclaim);
    if ctx.accounts.payout_mint.key() == Pubkey::default() {
        // SOL path — transfer lamports from agent to snapshot PDA.
        let ix = anchor_lang::solana_program::system_instruction::transfer(
            &ctx.accounts.agent.key(),
            &ctx.accounts.snapshot.key(),
            fund_amount,
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
        // SPL token path.
        transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from:      ctx.accounts.agent_ata.as_ref().unwrap().to_account_info(),
                    mint:      ctx.accounts.payout_mint.to_account_info(),
                    to:        ctx.accounts.snapshot_ata.as_ref().unwrap().to_account_info(),
                    authority: ctx.accounts.agent.to_account_info(),
                },
            ),
            fund_amount,
            ctx.accounts.payout_mint.decimals,
        )?;
    }

    let clock = Clock::get()?;
    let snap  = &mut ctx.accounts.snapshot;
    snap.yield_distributor     = ctx.accounts.yield_distributor.key();
    snap.id                    = snap_id;
    snap.slot                  = clock.slot;
    snap.timestamp             = clock.unix_timestamp;
    snap.total_eligible_supply = 0; // updated by add_snapshot_record
    snap.total_funds           = fund_amount;
    snap.payout_mint           = ctx.accounts.payout_mint.key();
    snap.reclaim_deadline      = clock.unix_timestamp
        .checked_add(reclaim_after_secs)
        .unwrap_or(i64::MAX);
    snap.total_claimed         = 0;
    snap.active                = false; // finalize_snapshot sets this to true
    snap.scheduled             = false;
    snap.description           = description;
    snap.bump                  = ctx.bumps.snapshot;

    Ok(())
}

/// Add one investor's balance to an open (not yet finalized) snapshot.
pub fn add_snapshot_record_handler(ctx: Context<AddSnapshotRecord>) -> Result<()> {
    require!(!ctx.accounts.snapshot.active, TokenxError::SnapshotInactive);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.yield_distributor.agent
            || ctx.accounts.agent.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAgent
    );

    let investor_id = &ctx.accounts.investor_identity;
    let holder      = &ctx.accounts.holder_state;

    // Skip ineligible investors silently (mirrors EVM _isEligible).
    if !investor_id.verified || holder.frozen || holder.balance == 0 {
        return Ok(());
    }

    let balance = holder.balance;
    let snap    = &mut ctx.accounts.snapshot;
    snap.total_eligible_supply = snap
        .total_eligible_supply
        .checked_add(balance)
        .ok_or(TokenxError::Overflow)?;

    let record = &mut ctx.accounts.claim_record;
    record.snapshot            = snap.key();
    record.wallet              = investor_id.wallet;
    record.balance_at_snapshot = balance;
    record.claimed             = false;
    record.bump                = ctx.bumps.claim_record;

    Ok(())
}

/// Finalise a snapshot once all investor records have been added.
pub fn finalize_snapshot_handler(ctx: Context<FinalizeSnapshot>) -> Result<()> {
    require!(!ctx.accounts.snapshot.active, TokenxError::SnapshotInactive);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.yield_distributor.agent
            || ctx.accounts.agent.key() == ctx.accounts.yield_distributor.admin,
        TokenxError::NotAgent
    );
    require!(
        ctx.accounts.snapshot.total_eligible_supply > 0,
        TokenxError::NoEligibleHolders
    );
    ctx.accounts.snapshot.active = true;
    Ok(())
}

// ── Account contexts ──────────────────────────────────────────────────────────

#[derive(Accounts)]
#[instruction(fund_amount: u64, reclaim_after_secs: i64, description: String)]
pub struct OpenSnapshot<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(mut, seeds = [SEED_YIELD_DIST, suite.key().as_ref()], bump = yield_distributor.bump)]
    pub yield_distributor: Account<'info, YieldDistributor>,

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

    /// Payout mint — pass system program ID (11111…) for native SOL payouts.
    pub payout_mint: InterfaceAccount<'info, Mint>,

    /// Agent's ATA for payout mint (required for SPL payouts).
    #[account(mut)]
    pub agent_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    /// Snapshot's ATA for payout mint (required for SPL payouts).
    #[account(mut)]
    pub snapshot_ata: Option<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AddSnapshotRecord<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_YIELD_DIST, suite.key().as_ref()], bump = yield_distributor.bump)]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        mut,
        seeds = [SEED_SNAPSHOT, yield_distributor.key().as_ref(), &snapshot.id.to_le_bytes()],
        bump  = snapshot.bump,
    )]
    pub snapshot: Account<'info, Snapshot>,

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

    #[account(
        init,
        payer  = agent,
        space  = ClaimRecord::SPACE,
        seeds  = [SEED_CLAIM_RECORD, snapshot.key().as_ref(), investor_identity.wallet.as_ref()],
        bump,
    )]
    pub claim_record: Account<'info, ClaimRecord>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct FinalizeSnapshot<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_YIELD_DIST, suite.key().as_ref()], bump = yield_distributor.bump)]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        mut,
        seeds = [SEED_SNAPSHOT, yield_distributor.key().as_ref(), &snapshot.id.to_le_bytes()],
        bump  = snapshot.bump,
    )]
    pub snapshot: Account<'info, Snapshot>,

    pub agent: Signer<'info>,
}
