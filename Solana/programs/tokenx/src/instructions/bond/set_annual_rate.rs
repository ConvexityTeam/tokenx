use anchor_lang::prelude::*;
use crate::{
    constants::*,
    errors::TokenxError,
    state::{BondTerms, TokenSuite},
};

/// Update the bond's annual coupon rate (in basis points).
/// Only the bond terms admin may call this, and only while the bond is live.
pub fn handler(ctx: Context<SetAnnualRate>, new_rate_bps: u16) -> Result<()> {
    require!(
        ctx.accounts.admin.key() == ctx.accounts.bond_terms.admin,
        TokenxError::NotAdmin
    );
    require!(
        new_rate_bps > 0 && new_rate_bps <= MAX_RATE_BPS,
        TokenxError::InvalidRate
    );

    let bt = &mut ctx.accounts.bond_terms;
    require!(!bt.defaulted,        TokenxError::BondDefaulted);
    require!(!bt.principal_repaid, TokenxError::BondClosed);

    bt.annual_rate_bps = new_rate_bps;
    Ok(())
}

#[derive(Accounts)]
pub struct SetAnnualRate<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(
        mut,
        seeds     = [SEED_BOND_TERMS, suite.key().as_ref()],
        bump      = bond_terms.bump,
        constraint = bond_terms.suite == suite.key(),
    )]
    pub bond_terms: Account<'info, BondTerms>,

    pub admin: Signer<'info>,
}
