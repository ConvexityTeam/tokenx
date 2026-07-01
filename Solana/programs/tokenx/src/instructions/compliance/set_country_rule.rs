use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{ComplianceConfig, CountryRule, TokenSuite}};

/// Create or update a country rule (block or allow) for a suite.
///
/// In block-list mode (`compliance.country_allowlist_mode == false`):
///   Pass `blocked = true` to block a country; `false` to unblock.
/// In allow-list mode (`compliance.country_allowlist_mode == true`):
///   Pass `allowed = true` to permit a country; `false` to deny.
pub fn handler(
    ctx:     Context<SetCountryRule>,
    country: u16,
    blocked: bool,
    allowed: bool,
) -> Result<()> {
    require!(
        ctx.accounts.admin.key() == ctx.accounts.compliance.admin,
        TokenxError::NotAdmin
    );
    let rule = &mut ctx.accounts.country_rule;
    rule.suite   = ctx.accounts.suite.key();
    rule.country = country;
    rule.blocked = blocked;
    rule.allowed = allowed;
    rule.bump    = ctx.bumps.country_rule;
    Ok(())
}

#[derive(Accounts)]
#[instruction(country: u16)]
pub struct SetCountryRule<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(seeds = [SEED_COMPLIANCE, suite.key().as_ref()], bump = compliance.bump)]
    pub compliance: Account<'info, ComplianceConfig>,

    #[account(
        init_if_needed,
        payer  = admin,
        space  = CountryRule::SPACE,
        seeds  = [SEED_COUNTRY_RULE, suite.key().as_ref(), &country.to_le_bytes()],
        bump,
    )]
    pub country_rule: Account<'info, CountryRule>,

    #[account(mut)]
    pub admin: Signer<'info>,

    pub system_program: Program<'info, System>,
}
