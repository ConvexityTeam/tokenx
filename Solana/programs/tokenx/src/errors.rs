use anchor_lang::prelude::*;

#[error_code]
pub enum TokenxError {
    // ── Factory ──────────────────────────────────────────────────────
    #[msg("Factory is paused")]
    FactoryPaused,
    #[msg("Issuer ID is already taken")]
    IssuerIdTaken,
    #[msg("Issuer ID must not be empty")]
    EmptyIssuerId,

    // ── Access ───────────────────────────────────────────────────────
    #[msg("Caller is not the admin")]
    NotAdmin,
    #[msg("Caller is not an agent")]
    NotAgent,
    #[msg("Caller is not the pauser")]
    NotPauser,

    // ── Token suite ──────────────────────────────────────────────────
    #[msg("Token suite is paused")]
    SuitePaused,
    #[msg("Operation requires a yield-bearing or bond suite")]
    NotYieldSuite,
    #[msg("Operation requires a bond suite")]
    NotBondSuite,

    // ── Identity ─────────────────────────────────────────────────────
    #[msg("Wallet is not KYC-verified")]
    NotVerified,
    #[msg("Wallet is already registered")]
    AlreadyRegistered,
    #[msg("Wallet is not registered")]
    NotRegistered,
    #[msg("Lost wallet ONCHAINID does not match the investor record")]
    LostWalletMismatch,
    #[msg("New wallet ONCHAINID does not match the investor record")]
    NewWalletMismatch,

    // ── Compliance ───────────────────────────────────────────────────
    #[msg("Sender's wallet is frozen")]
    SenderFrozen,
    #[msg("Recipient's wallet is frozen")]
    RecipientFrozen,
    #[msg("Recipient's country is blocked")]
    CountryBlocked,
    #[msg("Recipient's country is not on the allow-list")]
    CountryNotAllowed,
    #[msg("Wallet is not on the allowlist")]
    WalletNotAllowed,
    #[msg("Transfer would exceed max tokens per investor")]
    ExceedsMaxTokensPerInvestor,
    #[msg("Transfer would exceed max shareholder cap")]
    ExceedsMaxShareholders,
    #[msg("Sender is within lock-up period")]
    Lockedup,
    #[msg("Insufficient unfrozen balance")]
    InsufficientUnfrozenBalance,
    #[msg("Freeze amount exceeds available balance")]
    FreezeExceedsBalance,
    #[msg("Unfreeze amount exceeds frozen balance")]
    UnfreezeExceedsBalance,

    // ── Yield ────────────────────────────────────────────────────────
    #[msg("Snapshot has no eligible holders")]
    NoEligibleHolders,
    #[msg("Snapshot is inactive")]
    SnapshotInactive,
    #[msg("Yield already claimed for this snapshot")]
    AlreadyClaimed,
    #[msg("No balance recorded at snapshot")]
    NoBalanceAtSnapshot,
    #[msg("Reclaim deadline has not been reached")]
    ReclaimDeadlineNotReached,
    #[msg("Nothing to reclaim")]
    NothingToReclaim,

    // ── Bond ─────────────────────────────────────────────────────────
    #[msg("Bond terms not bound to this suite")]
    NoBondTerms,
    #[msg("Bond terms are already bound")]
    BondTermsAlreadyBound,
    #[msg("Bond coupon is not yet due")]
    CouponNotDue,
    #[msg("Bond has defaulted")]
    BondDefaulted,
    #[msg("Bond principal has already been repaid")]
    BondClosed,
    #[msg("Bond has not matured yet")]
    NotMatured,
    #[msg("Grace period has not been breached")]
    GraceNotBreached,
    #[msg("Annual rate must be between 1 and 10000 bps")]
    InvalidRate,
    #[msg("Face value per token must be greater than zero")]
    ZeroFaceValue,
    #[msg("Maturity date must be after issue date")]
    BadMaturityDate,
    #[msg("First coupon date must be between issue and maturity")]
    BadFirstCouponDate,
    #[msg("Tenor must be at least one coupon period")]
    TenorTooShort,
    #[msg("Call date must be between issue and maturity")]
    BadCallDate,
    #[msg("Computed coupon amount is zero")]
    ZeroCoupon,
    #[msg("Wrong SOL amount sent for coupon")]
    WrongSolAmount,

    // ── Arithmetic ───────────────────────────────────────────────────
    #[msg("Arithmetic overflow")]
    Overflow,
}
