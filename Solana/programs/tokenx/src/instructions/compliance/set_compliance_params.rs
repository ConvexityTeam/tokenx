use anchor_lang::prelude::*;
use crate::{constants::*, errors::TokenxError, state::{ComplianceConfig, TokenSuite}};

pub fn set_max_shareholders_handler(ctx: Context<SetComplianceParam>, max: u64) -> Result<()> {
    require_admin(&ctx.accounts.admin, &ctx.accounts.compliance)?;
    ctx.accounts.compliance.max_shareholders = max;
    Ok(())
}

pub fn set_max_tokens_per_investor_handler(ctx: Context<SetComplianceParam>, max: u64) -> Result<()> {
    require_admin(&ctx.accounts.admin, &ctx.accounts.compliance)?;
    ctx.accounts.compliance.max_tokens_per_investor = max;
    Ok(())
}

pub fn set_lockup_duration_handler(ctx: Context<SetComplianceParam>, duration: i64) -> Result<()> {
    require_admin(&ctx.accounts.admin, &ctx.accounts.compliance)?;
    ctx.accounts.compliance.lockup_duration = duration;
    Ok(())
}

pub fn set_country_allowlist_mode_handler(ctx: Context<SetComplianceParam>, enabled: bool) -> Result<()> {
    require_admin(&ctx.accounts.admin, &ctx.accounts.compliance)?;
    ctx.accounts.compliance.country_allowlist_mode = enabled;
    Ok(())
}

pub fn set_wallet_allowlist_enabled_handler(ctx: Context<SetComplianceParam>, enabled: bool) -> Result<()> {
    require_admin(&ctx.accounts.admin, &ctx.accounts.compliance)?;
    ctx.accounts.compliance.wallet_allowlist_enabled = enabled;
    Ok(())
}

fn require_admin(admin: &Signer, compliance: &Account<ComplianceConfig>) -> Result<()> {
    require!(admin.key() == compliance.admin, TokenxError::NotAdmin);
    Ok(())
}

#[derive(Accounts)]
pub struct SetComplianceParam<'info> {
    pub suite: Account<'info, TokenSuite>,

    #[account(
        mut,
        seeds = [SEED_COMPLIANCE, suite.key().as_ref()],
        bump  = compliance.bump,
        constraint = compliance.suite == suite.key(),
    )]
    pub compliance: Account<'info, ComplianceConfig>,

    pub admin: Signer<'info>,
}
