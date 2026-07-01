use anchor_lang::prelude::*;
use crate::{
    constants::*,
    errors::TokenxError,
    state::{BondTerms, TokenSuite},
};

/// Permissionless instruction — any signer can flag the bond as defaulted once
/// the grace period has elapsed past a missed coupon date.
///
/// Mirrors YieldDistributor.flagDefault() on EVM (permissionless by design so
/// investors can trigger it without the issuer's cooperation).
pub fn handler(ctx: Context<FlagDefault>) -> Result<()> {
    let bt  = &ctx.accounts.bond_terms;
    let now = Clock::get()?.unix_timestamp;

    require!(!bt.defaulted,        TokenxError::BondDefaulted);
    require!(!bt.principal_repaid, TokenxError::BondClosed);
    require!(bt.is_in_grace_breach(now), TokenxError::GraceNotBreached);

    ctx.accounts.bond_terms.defaulted = true;
    Ok(())
}

#[derive(Accounts)]
pub struct FlagDefault<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(
        mut,
        seeds     = [SEED_BOND_TERMS, suite.key().as_ref()],
        bump      = bond_terms.bump,
        constraint = bond_terms.suite == suite.key(),
    )]
    pub bond_terms: Account<'info, BondTerms>,

    /// Any signer can trigger default once grace period is breached.
    pub caller: Signer<'info>,
}
