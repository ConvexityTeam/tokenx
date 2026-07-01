use anchor_lang::prelude::*;
use crate::constants::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq)]
pub enum DayCount {
    Act365,
    Act360,
    Thirty360,
}

/// Economic terms for a tokenized bond — sealed at initialization.
///
/// Seeds: [SEED_BOND_TERMS, suite.key()]
///
/// The annual rate can be updated by the admin. All other fields are immutable.
#[account]
pub struct BondTerms {
    pub suite:               Pubkey,
    pub admin:               Pubkey,
    /// Annual coupon rate in basis points (1 = 0.01%, 10000 = 100%).
    pub annual_rate_bps:     u16,
    /// Coupon payment interval in seconds.
    pub coupon_period_secs:  i64,
    pub day_count:           DayCount,
    pub issue_date:          i64,
    pub maturity_date:       i64,
    pub first_coupon_date:   i64,
    /// Advances by `coupon_period_secs` each time a coupon is processed.
    pub next_coupon_date:    i64,
    /// Face value per token in the payout token's atomic units.
    pub face_value_per_token: u64,
    /// Grace period after a missed coupon before default can be flagged.
    pub grace_period_secs:   i64,
    pub callable:            bool,
    /// Optional: call date before maturity (0 if not callable).
    pub call_date:           i64,
    pub defaulted:           bool,
    pub principal_repaid:    bool,
    pub bump:                u8,
}

impl BondTerms {
    pub const SPACE: usize = 8 + BOND_TERMS_SIZE;

    /// Coupon per token in payout-token atomic units.
    ///
    /// Mirrors BondTerms.couponPerToken() on EVM:
    ///   face_value_per_token * rate_bps * coupon_period / (10_000 * days_in_year * 86_400)
    pub fn coupon_per_token(&self) -> Option<u64> {
        let days_in_year: u64 = match self.day_count {
            DayCount::Act360 | DayCount::Thirty360 => 360,
            DayCount::Act365 => 365,
        };
        let numerator = (self.face_value_per_token as u128)
            .checked_mul(self.annual_rate_bps as u128)?
            .checked_mul(self.coupon_period_secs as u128)?;
        let denominator = (10_000u128)
            .checked_mul(days_in_year as u128)?
            .checked_mul(86_400u128)?;
        Some((numerator / denominator) as u64)
    }

    pub fn is_coupon_due(&self, now: i64) -> bool {
        !self.principal_repaid
            && !self.defaulted
            && self.next_coupon_date <= now
            && self.next_coupon_date <= self.maturity_date
    }

    pub fn is_in_grace_breach(&self, now: i64) -> bool {
        !self.principal_repaid
            && !self.defaulted
            && (self.next_coupon_date + self.grace_period_secs) < now
            && self.next_coupon_date <= self.maturity_date
    }

    pub fn is_matured(&self, now: i64) -> bool {
        !self.principal_repaid && now >= self.maturity_date
    }
}
