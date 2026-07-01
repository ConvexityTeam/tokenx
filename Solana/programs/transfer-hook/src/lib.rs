/// Tokenx Transfer Hook — SPL Token-2022 compliance enforcement.
///
/// This program is registered as the transfer hook on every Tokenx
/// Token-2022 mint.  The Token-2022 program calls `execute` on every
/// token transfer (including burns and mints that route through the normal
/// transfer path).
///
/// Compliance checks performed (mirrors SecurityToken._compliantTransfer):
///   1. Sender is not address-frozen (`HolderState.frozen`).
///   2. Recipient is not address-frozen.
///   3. Sender identity exists and is KYC-verified.
///   4. Recipient identity exists and is KYC-verified.
///   5. Sender has sufficient unfrozen balance.
///   6. Recipient's country passes block/allow rule.
///   7. Transfer would not push recipient over `max_tokens_per_investor`.
///   8. Transfer would not push shareholder count over `max_shareholders`.
///   9. Sender is not within lock-up period.
///
/// Checks 5–9 involve mutable compliance state (HolderState, ComplianceConfig).
/// The hook also updates HolderState balances and shareholder count after a
/// successful transfer.
///
/// Extra accounts required (passed via `remaining_accounts` to the Token-2022
/// execute CPI, resolved by spl-tlv-account-resolution):
///   0. token_suite          PDA [b"suite", issuer_id]
///   1. compliance_config    PDA [b"compliance", suite]
///   2. sender_identity      PDA [b"identity", suite, sender_wallet]
///   3. recipient_identity   PDA [b"identity", suite, recipient_wallet]
///   4. sender_holder        PDA [b"holder",   suite, sender_wallet]
///   5. recipient_holder     PDA [b"holder",   suite, recipient_wallet]
///   6. country_rule         PDA [b"country_rule", suite, country_le_bytes] (optional)
use anchor_lang::prelude::*;
use anchor_spl::token_2022::spl_token_2022;
use spl_transfer_hook_interface::instruction::{ExecuteInstruction, TransferHookInstruction};

declare_id!("HookXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX");

// ── Shared seeds (must match tokenx program constants) ────────────────────────
const SEED_SUITE:            &[u8] = b"suite";
const SEED_COMPLIANCE:       &[u8] = b"compliance";
const SEED_INVESTOR_IDENTITY: &[u8] = b"identity";
const SEED_HOLDER_STATE:     &[u8] = b"holder";
const SEED_COUNTRY_RULE:     &[u8] = b"country_rule";

// ── Error codes ───────────────────────────────────────────────────────────────
#[error_code]
pub enum HookError {
    #[msg("Sender is not KYC-verified")]
    SenderNotVerified,
    #[msg("Recipient is not KYC-verified")]
    RecipientNotVerified,
    #[msg("Sender wallet is frozen")]
    SenderFrozen,
    #[msg("Recipient wallet is frozen")]
    RecipientFrozen,
    #[msg("Insufficient unfrozen balance")]
    InsufficientUnfrozen,
    #[msg("Recipient country is blocked")]
    CountryBlocked,
    #[msg("Recipient country is not on the allow-list")]
    CountryNotAllowed,
    #[msg("Wallet is not on the allowlist")]
    WalletNotAllowed,
    #[msg("Transfer would exceed max tokens per investor")]
    ExceedsMaxTokensPerInvestor,
    #[msg("Transfer would exceed max shareholder cap")]
    ExceedsMaxShareholders,
    #[msg("Sender is within the lock-up period")]
    Lockup,
    #[msg("Arithmetic overflow")]
    Overflow,
}

// ── Minimal on-chain state structs (must match tokenx program layout) ─────────

/// Minimal layout of tokenx::TokenSuite needed by the hook.
#[account]
pub struct TokenSuiteHook {
    pub issuer_id:   [u8; 68], // 4 len + 64 max bytes
    pub token_type:  u8,
    pub mint:        Pubkey,
    pub identity_registry: Pubkey,
    pub compliance:  Pubkey,
    // ... remaining fields not accessed by hook
}

/// Minimal layout of tokenx::ComplianceConfig.
#[account]
pub struct ComplianceConfigHook {
    pub suite:                   Pubkey,
    pub max_shareholders:        u64,
    pub max_tokens_per_investor: u64,
    pub lockup_duration:         i64,
    pub shareholder_count:       u64,
    pub wallet_allowlist_enabled: bool,
    pub country_allowlist_mode:  bool,
    pub admin:                   Pubkey,
    pub bump:                    u8,
}

/// Minimal layout of tokenx::InvestorIdentity.
#[account]
pub struct InvestorIdentityHook {
    pub suite:      Pubkey,
    pub wallet:     Pubkey,
    pub onchain_id: Pubkey,
    pub country:    u16,
    pub verified:   bool,
    pub bump:       u8,
}

/// Minimal layout of tokenx::HolderState.
#[account]
pub struct HolderStateHook {
    pub suite:          Pubkey,
    pub wallet:         Pubkey,
    pub balance:        u64,
    pub frozen_tokens:  u64,
    pub lockup_end:     i64,
    pub frozen:         bool,
    pub wallet_allowed: bool,
    pub bump:           u8,
}

/// Minimal layout of tokenx::CountryRule.
#[account]
pub struct CountryRuleHook {
    pub suite:   Pubkey,
    pub country: u16,
    pub blocked: bool,
    pub allowed: bool,
    pub bump:    u8,
}

#[program]
pub mod transfer_hook {
    use super::*;

    /// Called by Token-2022 on every token transfer.
    ///
    /// `amount`         — the number of tokens being transferred.
    /// Extra accounts are passed as `remaining_accounts` in the order
    /// documented in the module-level doc comment.
    pub fn execute(ctx: Context<Execute>, amount: u64) -> Result<()> {
        // Remaining accounts layout:
        //   [0] token_suite          (read-only)
        //   [1] compliance_config    (writable — shareholder count updated)
        //   [2] sender_identity      (read-only)
        //   [3] recipient_identity   (read-only)
        //   [4] sender_holder        (writable — balance updated)
        //   [5] recipient_holder     (writable — balance updated)
        //   [6] country_rule         (read-only, optional)
        let remaining = &ctx.remaining_accounts;
        if remaining.len() < 6 {
            // If accounts are missing we cannot verify compliance — reject.
            return err!(HookError::SenderNotVerified);
        }

        // Deserialise accounts.
        let compliance: ComplianceConfigHook =
            ComplianceConfigHook::try_deserialize(&mut &remaining[1].data.borrow()[..])?;
        let sender_id: InvestorIdentityHook =
            InvestorIdentityHook::try_deserialize(&mut &remaining[2].data.borrow()[..])?;
        let recipient_id: InvestorIdentityHook =
            InvestorIdentityHook::try_deserialize(&mut &remaining[3].data.borrow()[..])?;
        let sender_holder: HolderStateHook =
            HolderStateHook::try_deserialize(&mut &remaining[4].data.borrow()[..])?;
        let recipient_holder: HolderStateHook =
            HolderStateHook::try_deserialize(&mut &remaining[5].data.borrow()[..])?;

        // ── Identity checks ───────────────────────────────────────
        require!(sender_id.verified,    HookError::SenderNotVerified);
        require!(recipient_id.verified, HookError::RecipientNotVerified);
        require!(!sender_holder.frozen,    HookError::SenderFrozen);
        require!(!recipient_holder.frozen, HookError::RecipientFrozen);

        // ── Unfrozen balance ──────────────────────────────────────
        let sender_free = sender_holder
            .balance
            .saturating_sub(sender_holder.frozen_tokens);
        require!(sender_free >= amount, HookError::InsufficientUnfrozen);

        // ── Wallet allowlist ──────────────────────────────────────
        if compliance.wallet_allowlist_enabled {
            require!(recipient_holder.wallet_allowed, HookError::WalletNotAllowed);
        }

        // ── Country check ─────────────────────────────────────────
        if remaining.len() > 6 {
            let rule: CountryRuleHook =
                CountryRuleHook::try_deserialize(&mut &remaining[6].data.borrow()[..])?;
            if compliance.country_allowlist_mode {
                require!(rule.allowed, HookError::CountryNotAllowed);
            } else {
                require!(!rule.blocked, HookError::CountryBlocked);
            }
        } else if compliance.country_allowlist_mode {
            // No country rule account provided — in allow-list mode country is not allowed.
            return err!(HookError::CountryNotAllowed);
        }

        // ── Max tokens per investor ───────────────────────────────
        if compliance.max_tokens_per_investor > 0 {
            let new_balance = recipient_holder
                .balance
                .checked_add(amount)
                .ok_or(HookError::Overflow)?;
            require!(
                new_balance <= compliance.max_tokens_per_investor,
                HookError::ExceedsMaxTokensPerInvestor
            );
        }

        // ── Max shareholders ──────────────────────────────────────
        if compliance.max_shareholders > 0 && recipient_holder.balance == 0 {
            // Sender will have remaining balance?
            let sender_after = sender_holder.balance.saturating_sub(amount);
            let projected    = if sender_after == 0 {
                compliance.shareholder_count // sender leaves, recipient joins → net 0
            } else {
                compliance.shareholder_count
                    .checked_add(1)
                    .ok_or(HookError::Overflow)? // sender stays, recipient joins → +1
            };
            require!(projected <= compliance.max_shareholders, HookError::ExceedsMaxShareholders);
        }

        // ── Lock-up ───────────────────────────────────────────────
        let now = Clock::get()?.unix_timestamp;
        if sender_holder.lockup_end > 0 {
            require!(now >= sender_holder.lockup_end, HookError::Lockup);
        }

        // ── Update mutable state ──────────────────────────────────
        // Write back updated HolderState for sender and recipient,
        // and updated shareholder count in ComplianceConfig.

        let sender_new_balance    = sender_holder.balance.saturating_sub(amount);
        let recipient_new_balance = recipient_holder
            .balance
            .checked_add(amount)
            .ok_or(HookError::Overflow)?;

        let sender_was_nonzero    = sender_holder.balance > 0;
        let recipient_was_zero    = recipient_holder.balance == 0;
        let sender_becomes_zero   = sender_new_balance == 0;
        let recipient_becomes_nonzero = recipient_new_balance > 0;

        // Shareholder delta.
        let mut new_count = compliance.shareholder_count;
        if sender_was_nonzero && sender_becomes_zero {
            new_count = new_count.saturating_sub(1);
        }
        if recipient_was_zero && recipient_becomes_nonzero {
            new_count = new_count.checked_add(1).ok_or(HookError::Overflow)?;
        }

        // Write sender HolderState.
        {
            let mut data = remaining[4].try_borrow_mut_data()?;
            // balance field is at offset 8 (discriminator) + 32 + 32 = 72
            let balance_offset = 8 + 32 + 32;
            data[balance_offset..balance_offset + 8]
                .copy_from_slice(&sender_new_balance.to_le_bytes());
        }

        // Write recipient HolderState.
        {
            let mut data = remaining[5].try_borrow_mut_data()?;
            let balance_offset = 8 + 32 + 32;
            data[balance_offset..balance_offset + 8]
                .copy_from_slice(&recipient_new_balance.to_le_bytes());
        }

        // Write ComplianceConfig shareholder_count.
        // shareholder_count is at offset 8 + 32 + 8 + 8 + 8 = 64.
        {
            let mut data = remaining[1].try_borrow_mut_data()?;
            let sc_offset = 8 + 32 + 8 + 8 + 8;
            data[sc_offset..sc_offset + 8].copy_from_slice(&new_count.to_le_bytes());
        }

        Ok(())
    }

    /// Called by Token-2022 when the transfer hook extension is initialized
    /// on a new mint (used to register the ExtraAccountMeta list).
    pub fn initialize_extra_account_meta_list(
        ctx: Context<InitializeExtraAccountMetaList>,
    ) -> Result<()> {
        // The extra accounts meta list is stored as TLV data in the mint's
        // ExtraAccountMetaList extension.  The client SDK (spl-tlv-account-resolution)
        // constructs and writes this data; the program only needs to exist and own the
        // correct PDA.
        Ok(())
    }
}

// ── Account contexts ──────────────────────────────────────────────────────────

#[derive(Accounts)]
pub struct Execute<'info> {
    /// CHECK: Validated by Token-2022 before calling the hook.
    pub source_account: UncheckedAccount<'info>,
    /// CHECK: Validated by Token-2022.
    pub mint: UncheckedAccount<'info>,
    /// CHECK: Validated by Token-2022.
    pub destination_account: UncheckedAccount<'info>,
    /// CHECK: Validated by Token-2022.
    pub owner: UncheckedAccount<'info>,
    /// CHECK: Validated by Token-2022 (ExtraAccountMetaList PDA).
    pub extra_account_meta_list: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct InitializeExtraAccountMetaList<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: Written by this instruction; validated by Token-2022.
    #[account(mut)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    pub mint: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}
