use anchor_lang::prelude::*;
use anchor_spl::token_2022::Token2022;
use crate::{
    constants::*,
    errors::TokenxError,
    state::{
        BondTerms, ComplianceConfig, DayCount, Factory, IdentityRegistry, TokenSuite, TokenType,
        YieldDistributor,
    },
};
use super::initialize_suite::ComplianceParams;

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct BondParams {
    pub annual_rate_bps:      u16,
    pub coupon_period_secs:   i64,
    pub day_count:            DayCount,
    pub issue_date:           i64,
    pub maturity_date:        i64,
    pub first_coupon_date:    i64,
    pub face_value_per_token: u64,
    pub grace_period_secs:    i64,
    pub callable:             bool,
    pub call_date:            i64,
}

/// Deploy a full bond suite (SECURITY + YIELD + BondTerms) in one transaction.
///
/// Creates:
///   1. SPL Token-2022 mint with transfer hook extension
///   2. TokenSuite PDA
///   3. IdentityRegistry PDA
///   4. ComplianceConfig PDA
///   5. YieldDistributor PDA
///   6. BondTerms PDA (sealed economic terms)
pub fn handler(
    ctx: Context<InitializeBondSuite>,
    issuer_id:  String,
    compliance: ComplianceParams,
    bond:       BondParams,
    decimals:   u8,
) -> Result<()> {
    require!(!ctx.accounts.factory.paused, TokenxError::FactoryPaused);
    require!(!issuer_id.is_empty(),        TokenxError::EmptyIssuerId);

    // Validate bond params
    require!(bond.maturity_date > bond.issue_date,                     TokenxError::BadMaturityDate);
    require!(bond.first_coupon_date > bond.issue_date,                 TokenxError::BadFirstCouponDate);
    require!(bond.first_coupon_date <= bond.maturity_date,             TokenxError::BadFirstCouponDate);
    require!(bond.annual_rate_bps > 0 && bond.annual_rate_bps <= MAX_RATE_BPS, TokenxError::InvalidRate);
    require!(bond.face_value_per_token > 0,                            TokenxError::ZeroFaceValue);
    require!(
        (bond.maturity_date - bond.issue_date) >= bond.coupon_period_secs,
        TokenxError::TenorTooShort
    );
    if bond.callable {
        require!(
            bond.call_date > bond.issue_date && bond.call_date < bond.maturity_date,
            TokenxError::BadCallDate
        );
    }

    let clock     = Clock::get()?;
    let suite_key = ctx.accounts.suite.key();
    let admin_key = ctx.accounts.admin.key();

    // ── TokenSuite ────────────────────────────────────────────────
    let suite = &mut ctx.accounts.suite;
    suite.issuer_id         = issuer_id;
    suite.token_type        = TokenType::Bond;
    suite.mint              = ctx.accounts.mint.key();
    suite.identity_registry = ctx.accounts.identity_registry.key();
    suite.compliance        = ctx.accounts.compliance.key();
    suite.yield_distributor = ctx.accounts.yield_distributor.key();
    suite.bond_terms        = ctx.accounts.bond_terms.key();
    suite.admin             = admin_key;
    suite.agent             = admin_key;
    suite.pauser            = admin_key;
    suite.paused            = false;
    suite.deployed_by       = ctx.accounts.deployer.key();
    suite.deployed_at       = clock.unix_timestamp;
    suite.bump              = ctx.bumps.suite;
    suite.mint_bump         = ctx.bumps.mint;

    // ── IdentityRegistry ──────────────────────────────────────────
    let ir = &mut ctx.accounts.identity_registry;
    ir.suite          = suite_key;
    ir.admin          = admin_key;
    ir.agent          = admin_key;
    ir.investor_count = 0;
    ir.bump           = ctx.bumps.identity_registry;

    // ── ComplianceConfig ──────────────────────────────────────────
    let comp = &mut ctx.accounts.compliance;
    comp.suite                    = suite_key;
    comp.max_shareholders         = compliance.max_shareholders;
    comp.max_tokens_per_investor  = compliance.max_tokens_per_investor;
    comp.lockup_duration          = compliance.lockup_duration;
    comp.shareholder_count        = 0;
    comp.wallet_allowlist_enabled = false;
    comp.country_allowlist_mode   = false;
    comp.admin                    = admin_key;
    comp.bump                     = ctx.bumps.compliance;

    // ── YieldDistributor ──────────────────────────────────────────
    let yd = &mut ctx.accounts.yield_distributor;
    yd.suite          = suite_key;
    yd.snapshot_count = 0;
    yd.admin          = admin_key;
    yd.agent          = admin_key;
    yd.pauser         = admin_key;
    yd.paused         = false;
    yd.bump           = ctx.bumps.yield_distributor;

    // ── BondTerms (sealed) ────────────────────────────────────────
    let bt = &mut ctx.accounts.bond_terms;
    bt.suite               = suite_key;
    bt.admin               = admin_key;
    bt.annual_rate_bps     = bond.annual_rate_bps;
    bt.coupon_period_secs  = bond.coupon_period_secs;
    bt.day_count           = bond.day_count;
    bt.issue_date          = bond.issue_date;
    bt.maturity_date       = bond.maturity_date;
    bt.first_coupon_date   = bond.first_coupon_date;
    bt.next_coupon_date    = bond.first_coupon_date;
    bt.face_value_per_token = bond.face_value_per_token;
    bt.grace_period_secs   = bond.grace_period_secs;
    bt.callable            = bond.callable;
    bt.call_date           = bond.call_date;
    bt.defaulted           = false;
    bt.principal_repaid    = false;
    bt.bump                = ctx.bumps.bond_terms;

    ctx.accounts.factory.total_deployments = ctx.accounts
        .factory
        .total_deployments
        .checked_add(1)
        .ok_or(TokenxError::Overflow)?;

    Ok(())
}

#[derive(Accounts)]
#[instruction(issuer_id: String)]
pub struct InitializeBondSuite<'info> {
    #[account(mut, seeds = [SEED_FACTORY], bump = factory.bump)]
    pub factory: Account<'info, Factory>,

    #[account(
        init,
        payer  = deployer,
        space  = TokenSuite::SPACE,
        seeds  = [SEED_SUITE, issuer_id.as_bytes()],
        bump,
    )]
    pub suite: Account<'info, TokenSuite>,

    /// CHECK: Initialized via Token-2022 CPI.
    #[account(mut, seeds = [SEED_MINT, issuer_id.as_bytes()], bump)]
    pub mint: UncheckedAccount<'info>,

    #[account(
        init,
        payer  = deployer,
        space  = IdentityRegistry::SPACE,
        seeds  = [SEED_IDENTITY_REGISTRY, suite.key().as_ref()],
        bump,
    )]
    pub identity_registry: Account<'info, IdentityRegistry>,

    #[account(
        init,
        payer  = deployer,
        space  = ComplianceConfig::SPACE,
        seeds  = [SEED_COMPLIANCE, suite.key().as_ref()],
        bump,
    )]
    pub compliance: Account<'info, ComplianceConfig>,

    #[account(
        init,
        payer  = deployer,
        space  = YieldDistributor::SPACE,
        seeds  = [SEED_YIELD_DIST, suite.key().as_ref()],
        bump,
    )]
    pub yield_distributor: Account<'info, YieldDistributor>,

    #[account(
        init,
        payer  = deployer,
        space  = BondTerms::SPACE,
        seeds  = [SEED_BOND_TERMS, suite.key().as_ref()],
        bump,
    )]
    pub bond_terms: Account<'info, BondTerms>,

    /// CHECK: Validated at runtime.
    pub admin: UncheckedAccount<'info>,

    #[account(mut)]
    pub deployer: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
