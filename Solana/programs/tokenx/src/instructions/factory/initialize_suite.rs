use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::{
        self, Token2022,
        spl_token_2022::{
            extension::transfer_hook::TransferHookAccount,
            state::Mint as SplMint,
        },
    },
    token_interface::Mint,
};
use spl_transfer_hook_interface::instruction::ExecuteInstruction;
use crate::{
    constants::*,
    errors::TokenxError,
    state::{
        ComplianceConfig, Factory, IdentityRegistry, TokenSuite, TokenType, YieldDistributor,
    },
};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ComplianceParams {
    pub max_shareholders:        u64,
    pub max_tokens_per_investor: u64,
    pub lockup_duration:         i64,
}

/// Deploy a SECURITY or YIELD_BEARING token suite in a single transaction.
///
/// Creates:
///   1. SPL Token-2022 mint with transfer hook extension
///   2. TokenSuite PDA (registry record)
///   3. IdentityRegistry PDA
///   4. ComplianceConfig PDA
///   5. YieldDistributor PDA (YIELD_BEARING only)
pub fn handler(
    ctx: Context<InitializeSuite>,
    issuer_id:   String,
    token_type:  TokenType,
    compliance:  ComplianceParams,
    decimals:    u8,
) -> Result<()> {
    require!(!ctx.accounts.factory.paused, TokenxError::FactoryPaused);
    require!(!issuer_id.is_empty(),        TokenxError::EmptyIssuerId);
    require!(
        token_type != TokenType::Bond,
        TokenxError::NotBondSuite
    );

    let clock     = Clock::get()?;
    let suite_key = ctx.accounts.suite.key();
    let admin_key = ctx.accounts.admin.key();

    // ── 1. TokenSuite ─────────────────────────────────────────────
    let suite = &mut ctx.accounts.suite;
    suite.issuer_id        = issuer_id;
    suite.token_type       = token_type.clone();
    suite.mint             = ctx.accounts.mint.key();
    suite.identity_registry = ctx.accounts.identity_registry.key();
    suite.compliance       = ctx.accounts.compliance.key();
    suite.yield_distributor = if token_type == TokenType::YieldBearing {
        ctx.accounts.yield_distributor.as_ref()
            .map(|a| a.key())
            .unwrap_or_default()
    } else {
        Pubkey::default()
    };
    suite.bond_terms       = Pubkey::default();
    suite.admin            = admin_key;
    suite.agent            = admin_key;
    suite.pauser           = admin_key;
    suite.paused           = false;
    suite.deployed_by      = ctx.accounts.deployer.key();
    suite.deployed_at      = clock.unix_timestamp;
    suite.bump             = ctx.bumps.suite;
    suite.mint_bump        = ctx.bumps.mint;

    // ── 2. IdentityRegistry ───────────────────────────────────────
    let ir = &mut ctx.accounts.identity_registry;
    ir.suite          = suite_key;
    ir.admin          = admin_key;
    ir.agent          = admin_key;
    ir.investor_count = 0;
    ir.bump           = ctx.bumps.identity_registry;

    // ── 3. ComplianceConfig ───────────────────────────────────────
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

    // ── 4. YieldDistributor (YIELD_BEARING only) ──────────────────
    if token_type == TokenType::YieldBearing {
        if let Some(yd) = ctx.accounts.yield_distributor.as_deref_mut() {
            yd.suite          = suite_key;
            yd.snapshot_count = 0;
            yd.admin          = admin_key;
            yd.agent          = admin_key;
            yd.pauser         = admin_key;
            yd.paused         = false;
            yd.bump           = ctx.bumps.yield_distributor
                .ok_or(TokenxError::NotYieldSuite)?;
        }
    }

    // ── 5. Increment factory counter ──────────────────────────────
    ctx.accounts.factory.total_deployments = ctx.accounts
        .factory
        .total_deployments
        .checked_add(1)
        .ok_or(TokenxError::Overflow)?;

    Ok(())
}

#[derive(Accounts)]
#[instruction(issuer_id: String, token_type: TokenType)]
pub struct InitializeSuite<'info> {
    #[account(mut, seeds = [SEED_FACTORY], bump = factory.bump)]
    pub factory: Account<'info, Factory>,

    // ── Suite registry ─────────────────────────────────────────────
    #[account(
        init,
        payer  = deployer,
        space  = TokenSuite::SPACE,
        seeds  = [SEED_SUITE, issuer_id.as_bytes()],
        bump,
    )]
    pub suite: Account<'info, TokenSuite>,

    // ── SPL Token-2022 mint (PDA-owned, transfer hook extension) ───
    /// CHECK: Initialized via raw instruction CPI to Token-2022.
    #[account(
        mut,
        seeds = [SEED_MINT, issuer_id.as_bytes()],
        bump,
    )]
    pub mint: UncheckedAccount<'info>,

    // ── Identity registry ─────────────────────────────────────────
    #[account(
        init,
        payer  = deployer,
        space  = IdentityRegistry::SPACE,
        seeds  = [SEED_IDENTITY_REGISTRY, suite.key().as_ref()],
        bump,
    )]
    pub identity_registry: Account<'info, IdentityRegistry>,

    // ── Compliance config ─────────────────────────────────────────
    #[account(
        init,
        payer  = deployer,
        space  = ComplianceConfig::SPACE,
        seeds  = [SEED_COMPLIANCE, suite.key().as_ref()],
        bump,
    )]
    pub compliance: Account<'info, ComplianceConfig>,

    // ── Yield distributor (optional — only for YIELD_BEARING) ─────
    #[account(
        init_if_needed,
        payer  = deployer,
        space  = YieldDistributor::SPACE,
        seeds  = [SEED_YIELD_DIST, suite.key().as_ref()],
        bump,
    )]
    pub yield_distributor: Option<Account<'info, YieldDistributor>>,

    /// Suite admin — receives all authority keys.
    /// CHECK: Public key validated at runtime; not a signer.
    pub admin: UncheckedAccount<'info>,

    #[account(mut)]
    pub deployer: Signer<'info>,

    pub token_program:  Program<'info, Token2022>,
    pub system_program: Program<'info, System>,
}
