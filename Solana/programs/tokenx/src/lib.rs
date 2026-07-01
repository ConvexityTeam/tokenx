use anchor_lang::prelude::*;

pub mod constants;
pub mod errors;
pub mod instructions;
pub mod state;

use instructions::{
    // factory
    initialize_factory::{handler as initialize_factory, pause_factory, InitializeFactory, PauseFactory},
    initialize_suite::{handler as initialize_suite, ComplianceParams, InitializeSuite},
    initialize_bond_suite::{handler as initialize_bond_suite, BondParams, InitializeBondSuite},
    // identity
    register_identity::{handler as register_identity, RegisterIdentity},
    update_identity::{update_identity_handler, update_country_handler, UpdateIdentity},
    delete_identity::{handler as delete_identity, DeleteIdentity},
    set_verified::{handler as set_verified, SetVerified},
    // compliance
    set_compliance_params::{
        set_max_shareholders_handler, set_max_tokens_per_investor_handler,
        set_lockup_duration_handler, set_country_allowlist_mode_handler,
        set_wallet_allowlist_enabled_handler, SetComplianceParam,
    },
    set_country_rule::{handler as set_country_rule, SetCountryRule},
    set_wallet_allowlist::{handler as set_wallet_allowed, SetWalletAllowed},
    // token
    mint_to::{handler as mint_to, MintToCtx},
    burn::{handler as burn_tokens, BurnCtx},
    forced_transfer::{handler as forced_transfer, ForcedTransferCtx},
    set_address_frozen_handler, FreezeAccount,
    freeze_partial_handler, unfreeze_partial_handler, FreezePartial,
    recover_wallet::{handler as recover_wallet, RecoverWallet},
    pause::{handler as pause_suite, PauseSuite},
    // yield distributor
    open_snapshot_handler, add_snapshot_record_handler, finalize_snapshot_handler,
    OpenSnapshot, AddSnapshotRecord, FinalizeSnapshot,
    claim_yield::{handler as claim_yield, ClaimYield},
    push_yield::{handler as push_yield, PushYield},
    reclaim_unclaimed::{handler as reclaim_unclaimed, ReclaimUnclaimed},
    // bond
    create_scheduled_coupon::{open_handler as open_scheduled_coupon, finalize_handler as finalize_scheduled_coupon, OpenScheduledCoupon, FinalizeScheduledCoupon},
    flag_default::{handler as flag_default, FlagDefault},
    redeem_at_maturity::{handler as redeem_at_maturity, RedeemAtMaturity},
    set_annual_rate::{handler as set_annual_rate, SetAnnualRate},
};
use state::TokenType;

declare_id!("56VkagdgPEgKbkaaiAiXM9REzhCwmrUTYF8hpuYDxPVH");

#[program]
pub mod tokenx {
    use super::*;

    // ── Factory ───────────────────────────────────────────────────────────────

    /// One-time global factory initialisation.
    pub fn ix_initialize_factory(ctx: Context<InitializeFactory>) -> Result<()> {
        initialize_factory(ctx)
    }

    /// Pause or unpause the factory (admin only).
    pub fn ix_pause_factory(ctx: Context<PauseFactory>, paused: bool) -> Result<()> {
        pause_factory(ctx, paused)
    }

    /// Deploy a SECURITY or YIELD_BEARING token suite.
    pub fn ix_initialize_suite(
        ctx:        Context<InitializeSuite>,
        issuer_id:  String,
        token_type: TokenType,
        compliance: ComplianceParams,
        decimals:   u8,
    ) -> Result<()> {
        initialize_suite(ctx, issuer_id, token_type, compliance, decimals)
    }

    /// Deploy a full BOND suite (token + yield distributor + bond terms).
    pub fn ix_initialize_bond_suite(
        ctx:        Context<InitializeBondSuite>,
        issuer_id:  String,
        compliance: ComplianceParams,
        bond:       BondParams,
        decimals:   u8,
    ) -> Result<()> {
        initialize_bond_suite(ctx, issuer_id, compliance, bond, decimals)
    }

    // ── Identity ──────────────────────────────────────────────────────────────

    /// Register a new investor (creates InvestorIdentity PDA, verified = true).
    pub fn ix_register_identity(
        ctx:        Context<RegisterIdentity>,
        onchain_id: Pubkey,
        country:    u16,
    ) -> Result<()> {
        register_identity(ctx, onchain_id, country)
    }

    /// Update the ONCHAINID of a registered investor.
    pub fn ix_update_identity(ctx: Context<UpdateIdentity>, new_onchain_id: Pubkey) -> Result<()> {
        update_identity_handler(ctx, new_onchain_id)
    }

    /// Update the ISO 3166-1 country code of a registered investor.
    pub fn ix_update_country(ctx: Context<UpdateIdentity>, country: u16) -> Result<()> {
        update_country_handler(ctx, country)
    }

    /// Delete an investor's identity record (closes the PDA).
    pub fn ix_delete_identity(ctx: Context<DeleteIdentity>) -> Result<()> {
        delete_identity(ctx)
    }

    /// Set the KYC-verified flag for a registered investor.
    pub fn ix_set_verified(ctx: Context<SetVerified>, verified: bool) -> Result<()> {
        set_verified(ctx, verified)
    }

    // ── Compliance ────────────────────────────────────────────────────────────

    pub fn ix_set_max_shareholders(ctx: Context<SetComplianceParam>, max: u64) -> Result<()> {
        set_max_shareholders_handler(ctx, max)
    }

    pub fn ix_set_max_tokens_per_investor(ctx: Context<SetComplianceParam>, max: u64) -> Result<()> {
        set_max_tokens_per_investor_handler(ctx, max)
    }

    pub fn ix_set_lockup_duration(ctx: Context<SetComplianceParam>, duration: i64) -> Result<()> {
        set_lockup_duration_handler(ctx, duration)
    }

    pub fn ix_set_country_allowlist_mode(ctx: Context<SetComplianceParam>, enabled: bool) -> Result<()> {
        set_country_allowlist_mode_handler(ctx, enabled)
    }

    pub fn ix_set_wallet_allowlist_enabled(ctx: Context<SetComplianceParam>, enabled: bool) -> Result<()> {
        set_wallet_allowlist_enabled_handler(ctx, enabled)
    }

    /// Create or update a country rule (block/allow) for a suite.
    pub fn ix_set_country_rule(
        ctx:     Context<SetCountryRule>,
        country: u16,
        blocked: bool,
        allowed: bool,
    ) -> Result<()> {
        set_country_rule(ctx, country, blocked, allowed)
    }

    /// Set the wallet allowlist flag for a single holder.
    pub fn ix_set_wallet_allowed(ctx: Context<SetWalletAllowed>, allowed: bool) -> Result<()> {
        set_wallet_allowed(ctx, allowed)
    }

    // ── Token operations ──────────────────────────────────────────────────────

    /// Mint tokens to a KYC-verified recipient (compliance checked).
    pub fn ix_mint_to(ctx: Context<MintToCtx>, amount: u64) -> Result<()> {
        mint_to(ctx, amount)
    }

    /// Burn tokens from a holder (agent-only).
    pub fn ix_burn(ctx: Context<BurnCtx>, amount: u64) -> Result<()> {
        burn_tokens(ctx, amount)
    }

    /// Agent-initiated forced transfer — bypasses compliance, requires verified recipient.
    pub fn ix_forced_transfer(ctx: Context<ForcedTransferCtx>, amount: u64, decimals: u8) -> Result<()> {
        forced_transfer(ctx, amount, decimals)
    }

    /// Freeze or unfreeze an address entirely.
    pub fn ix_set_address_frozen(ctx: Context<FreezeAccount>, frozen: bool) -> Result<()> {
        set_address_frozen_handler(ctx, frozen)
    }

    /// Freeze a partial token amount.
    pub fn ix_freeze_partial(ctx: Context<FreezePartial>, amount: u64) -> Result<()> {
        freeze_partial_handler(ctx, amount)
    }

    /// Unfreeze a partial token amount.
    pub fn ix_unfreeze_partial(ctx: Context<FreezePartial>, amount: u64) -> Result<()> {
        unfreeze_partial_handler(ctx, amount)
    }

    /// Recover tokens from a lost wallet to a new wallet with the same ONCHAINID.
    pub fn ix_recover_wallet(ctx: Context<RecoverWallet>, decimals: u8) -> Result<()> {
        recover_wallet(ctx, decimals)
    }

    /// Pause or unpause a token suite.
    pub fn ix_pause_suite(ctx: Context<PauseSuite>, paused: bool) -> Result<()> {
        pause_suite(ctx, paused)
    }

    // ── Yield distributor ─────────────────────────────────────────────────────

    /// Phase 1: open a new yield snapshot and deposit funds.
    pub fn ix_open_snapshot(
        ctx:                Context<OpenSnapshot>,
        fund_amount:        u64,
        reclaim_after_secs: i64,
        description:        String,
    ) -> Result<()> {
        open_snapshot_handler(ctx, fund_amount, reclaim_after_secs, description)
    }

    /// Phase 2: add one investor's balance record to an open snapshot.
    pub fn ix_add_snapshot_record(ctx: Context<AddSnapshotRecord>) -> Result<()> {
        add_snapshot_record_handler(ctx)
    }

    /// Phase 3: finalise the snapshot (sets active = true).
    pub fn ix_finalize_snapshot(ctx: Context<FinalizeSnapshot>) -> Result<()> {
        finalize_snapshot_handler(ctx)
    }

    /// Investor claims their yield from a finalised snapshot.
    pub fn ix_claim_yield(ctx: Context<ClaimYield>, snapshot_id: u64) -> Result<()> {
        claim_yield(ctx, snapshot_id)
    }

    /// Agent pushes yield to a single investor.
    pub fn ix_push_yield(ctx: Context<PushYield>, snapshot_id: u64) -> Result<()> {
        push_yield(ctx, snapshot_id)
    }

    /// Admin reclaims unclaimed yield after the reclaim deadline.
    pub fn ix_reclaim_unclaimed(ctx: Context<ReclaimUnclaimed>, snapshot_id: u64) -> Result<()> {
        reclaim_unclaimed(ctx, snapshot_id)
    }

    // ── Bond ──────────────────────────────────────────────────────────────────

    /// Phase 1: open a BondTerms-constrained coupon snapshot.
    pub fn ix_open_scheduled_coupon(
        ctx:                Context<OpenScheduledCoupon>,
        reclaim_after_secs: i64,
        description:        String,
    ) -> Result<()> {
        open_scheduled_coupon(ctx, reclaim_after_secs, description)
    }

    /// Phase 2: add investor records (reuses ix_add_snapshot_record).

    /// Phase 3: finalise the coupon, pull required funds, advance coupon date.
    pub fn ix_finalize_scheduled_coupon(
        ctx:         Context<FinalizeScheduledCoupon>,
        snapshot_id: u64,
    ) -> Result<()> {
        finalize_scheduled_coupon(ctx, snapshot_id)
    }

    /// Permissionlessly flag the bond as defaulted after grace period breach.
    pub fn ix_flag_default(ctx: Context<FlagDefault>) -> Result<()> {
        flag_default(ctx)
    }

    /// Redeem a holder's tokens for principal at maturity.
    pub fn ix_redeem_at_maturity(ctx: Context<RedeemAtMaturity>, decimals: u8) -> Result<()> {
        redeem_at_maturity(ctx, decimals)
    }

    /// Update the bond's annual coupon rate (admin only).
    pub fn ix_set_annual_rate(ctx: Context<SetAnnualRate>, new_rate_bps: u16) -> Result<()> {
        set_annual_rate(ctx, new_rate_bps)
    }
}
