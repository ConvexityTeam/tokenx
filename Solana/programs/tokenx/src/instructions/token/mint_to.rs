use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token_2022::{mint_to, MintTo, Token2022},
    token_interface::{Mint, TokenAccount},
};
use crate::{
    constants::*,
    errors::TokenxError,
    state::{ComplianceConfig, CountryRule, HolderState, InvestorIdentity, TokenSuite},
};

/// Mint tokens to a KYC-verified, compliant recipient.
///
/// Compliance checks (mirrors SecurityToken.mint + ComplianceModule.canTransfer):
///   1. Suite must not be paused.
///   2. Caller must hold AGENT_ROLE (suite.agent or suite.admin).
///   3. Recipient must be KYC-verified.
///   4. Recipient must pass wallet allowlist (if enabled).
///   5. Recipient's country must not be blocked / must be allowed.
///   6. Mint would not push recipient over maxTokensPerInvestor.
///   7. Mint would not push shareholder count over maxShareholders.
///
/// HolderState is initialized lazily on first mint.
pub fn handler(ctx: Context<MintToCtx>, amount: u64) -> Result<()> {
    require!(!ctx.accounts.suite.paused, TokenxError::SuitePaused);
    require!(
        ctx.accounts.agent.key() == ctx.accounts.suite.agent
            || ctx.accounts.agent.key() == ctx.accounts.suite.admin,
        TokenxError::NotAgent
    );

    let recipient_id = &ctx.accounts.recipient_identity;
    require!(recipient_id.verified, TokenxError::NotVerified);

    let compliance  = &ctx.accounts.compliance;
    let holder      = &ctx.accounts.holder_state;

    // Wallet allowlist
    if compliance.wallet_allowlist_enabled {
        require!(holder.wallet_allowed, TokenxError::WalletNotAllowed);
    }

    // Country check
    if let Some(rule) = ctx.accounts.country_rule.as_ref() {
        if compliance.country_allowlist_mode {
            require!(rule.allowed, TokenxError::CountryNotAllowed);
        } else {
            require!(!rule.blocked, TokenxError::CountryBlocked);
        }
    } else if compliance.country_allowlist_mode {
        // No rule account means country is not explicitly allowed.
        return err!(TokenxError::CountryNotAllowed);
    }

    // Max tokens per investor
    if compliance.max_tokens_per_investor > 0 {
        require!(
            holder.balance.checked_add(amount).ok_or(TokenxError::Overflow)?
                <= compliance.max_tokens_per_investor,
            TokenxError::ExceedsMaxTokensPerInvestor
        );
    }

    // Max shareholders
    let is_new_holder = holder.balance == 0;
    if compliance.max_shareholders > 0 && is_new_holder {
        require!(
            compliance.shareholder_count.checked_add(1).ok_or(TokenxError::Overflow)?
                <= compliance.max_shareholders,
            TokenxError::ExceedsMaxShareholders
        );
    }

    // ── SPL Token-2022 mint CPI ───────────────────────────────────
    let suite_key = ctx.accounts.suite.issuer_id.as_bytes().to_vec();
    let seeds: &[&[u8]] = &[SEED_SUITE, &suite_key, &[ctx.accounts.suite.bump]];
    mint_to(
        CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            MintTo {
                mint:      ctx.accounts.mint.to_account_info(),
                to:        ctx.accounts.recipient_ata.to_account_info(),
                authority: ctx.accounts.suite.to_account_info(),
            },
            &[seeds],
        ),
        amount,
    )?;

    // ── Update compliance state ───────────────────────────────────
    let holder = &mut ctx.accounts.holder_state;
    if holder.balance == 0 && amount > 0 {
        ctx.accounts.compliance.shareholder_count = ctx
            .accounts
            .compliance
            .shareholder_count
            .checked_add(1)
            .ok_or(TokenxError::Overflow)?;
    }
    holder.balance = holder.balance.checked_add(amount).ok_or(TokenxError::Overflow)?;

    // Apply lockup if configured
    if compliance.lockup_duration > 0 {
        let now = Clock::get()?.unix_timestamp;
        holder.lockup_end = now.checked_add(compliance.lockup_duration).unwrap_or(i64::MAX);
    }

    Ok(())
}

#[derive(Accounts)]
pub struct MintToCtx<'info> {
    #[account(mut, seeds = [SEED_SUITE, suite.issuer_id.as_bytes()], bump = suite.bump)]
    pub suite: Account<'info, TokenSuite>,

    #[account(mut, address = suite.mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(mut, seeds = [SEED_COMPLIANCE, suite.key().as_ref()], bump = compliance.bump)]
    pub compliance: Account<'info, ComplianceConfig>,

    /// Recipient's KYC record — must be verified.
    #[account(
        seeds = [SEED_INVESTOR_IDENTITY, suite.key().as_ref(), recipient_identity.wallet.as_ref()],
        bump  = recipient_identity.bump,
        constraint = recipient_identity.suite == suite.key(),
    )]
    pub recipient_identity: Account<'info, InvestorIdentity>,

    /// Compliance-tracking account for the recipient, created on first mint.
    #[account(
        init_if_needed,
        payer  = agent,
        space  = HolderState::SPACE,
        seeds  = [SEED_HOLDER_STATE, suite.key().as_ref(), recipient_identity.wallet.as_ref()],
        bump,
    )]
    pub holder_state: Account<'info, HolderState>,

    /// Optional: country rule for recipient's country (may not exist).
    #[account(
        seeds = [
            SEED_COUNTRY_RULE,
            suite.key().as_ref(),
            &recipient_identity.country.to_le_bytes(),
        ],
        bump  = country_rule.bump,
    )]
    pub country_rule: Option<Account<'info, CountryRule>>,

    /// Recipient's associated token account — created if needed.
    #[account(
        init_if_needed,
        payer             = agent,
        associated_token::mint      = mint,
        associated_token::authority = recipient_wallet,
        associated_token::token_program = token_program,
    )]
    pub recipient_ata: InterfaceAccount<'info, TokenAccount>,

    /// CHECK: Recipient wallet public key; must match recipient_identity.wallet.
    #[account(address = recipient_identity.wallet)]
    pub recipient_wallet: UncheckedAccount<'info>,

    #[account(mut)]
    pub agent: Signer<'info>,

    pub token_program:        Program<'info, Token2022>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program:       Program<'info, System>,
}
