// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title BondTerms
 * @notice Economic terms for a tokenized bond — upgradeable via BeaconProxy.
 *
 *   The yield rate (annualRateBps) can be updated by the bond admin.
 *   All other terms are sealed at initialization.
 *
 *   EIP-2771: setAnnualRate resolves the caller through _msgSender() so
 *   the bond admin can update rates via a relayer without holding ETH.
 *   advanceCoupon / markDefaulted / markPrincipalRepaid keep raw
 *   msg.sender — they are called by bound contracts, never by users.
 */
contract BondTerms is Initializable {

    enum DayCount { ACT_365, ACT_360, THIRTY_360 }

    // ── EIP-2771 ──────────────────────────────────────────────────
    address public trustedForwarder;

    // ── Admin ─────────────────────────────────────────────────────
    address public admin;

    // ── Yield ─────────────────────────────────────────────────────
    uint256 public annualRateBps;

    struct RateEntry {
        uint256 rateBps;
        uint256 effectiveAt;
    }
    RateEntry[] public rateHistory;
    uint256   public couponPeriodSeconds;
    DayCount  public dayCount;

    // ── Tenor ─────────────────────────────────────────────────────
    uint256 public issueDate;
    uint256 public maturityDate;
    uint256 public firstCouponDate;

    // ── Principal ─────────────────────────────────────────────────
    uint256 public faceValuePerToken;

    // ── Optional ──────────────────────────────────────────────────
    uint256 public gracePeriodSeconds;
    bool    public callable;
    uint256 public callDate;

    // ── Runtime flags ─────────────────────────────────────────────
    uint256 public nextCouponDate;
    bool    public defaulted;
    bool    public principalRepaid;

    address public yieldDistributor;
    address public securityToken;

    // ── Upgrade safety ────────────────────────────────────────────
    // solhint-disable-next-line var-name-mixedcase
    uint256[30] private __gap;

    // ── Events ────────────────────────────────────────────────────
    event TermsSealed(
        uint256  annualRateBps,
        uint256  couponPeriodSeconds,
        DayCount dayCount,
        uint256  issueDate,
        uint256  maturityDate,
        uint256  firstCouponDate,
        uint256  faceValuePerToken
    );
    event RateChanged(uint256 oldRateBps, uint256 newRateBps, uint256 effectiveAt);
    event ConsumersBound(address indexed securityToken, address indexed yieldDistributor);
    event CouponAdvanced(uint256 previousCouponDate, uint256 newNextCouponDate);
    event Defaulted(uint256 atTimestamp);
    event PrincipalRepaid(uint256 atTimestamp);

    struct InitParams {
        uint256  annualRateBps;
        uint256  couponPeriodSeconds;
        DayCount dayCount;
        uint256  issueDate;
        uint256  maturityDate;
        uint256  firstCouponDate;
        uint256  faceValuePerToken;
        uint256  gracePeriodSeconds;
        bool     callable;
        uint256  callDate;
        address  admin;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p, address trustedForwarder_) external initializer {
        require(p.maturityDate > p.issueDate,                           "BT: maturity <= issue");
        require(p.couponPeriodSeconds > 0,                              "BT: zero coupon period");
        require(p.firstCouponDate > p.issueDate,                        "BT: first coupon <= issue");
        require(p.firstCouponDate <= p.maturityDate,                    "BT: first coupon > maturity");
        require(p.annualRateBps <= 10_000,                              "BT: rate > 100%");
        require(p.faceValuePerToken > 0,                                "BT: zero face value");
        require(p.admin != address(0),                                  "BT: zero admin");
        require(
            (p.maturityDate - p.issueDate) >= p.couponPeriodSeconds,    "BT: tenor shorter than one coupon"
        );
        if (p.callable) {
            require(
                p.callDate > p.issueDate && p.callDate < p.maturityDate, "BT: bad call date"
            );
        }

        trustedForwarder     = trustedForwarder_;
        admin                = p.admin;
        annualRateBps        = p.annualRateBps;
        couponPeriodSeconds  = p.couponPeriodSeconds;
        dayCount             = p.dayCount;
        issueDate            = p.issueDate;
        maturityDate         = p.maturityDate;
        firstCouponDate      = p.firstCouponDate;
        faceValuePerToken    = p.faceValuePerToken;
        gracePeriodSeconds   = p.gracePeriodSeconds;
        callable             = p.callable;
        callDate             = p.callDate;
        nextCouponDate       = p.firstCouponDate;

        rateHistory.push(RateEntry({ rateBps: p.annualRateBps, effectiveAt: block.timestamp }));

        emit TermsSealed(
            p.annualRateBps, p.couponPeriodSeconds, p.dayCount,
            p.issueDate, p.maturityDate, p.firstCouponDate, p.faceValuePerToken
        );
    }

    // ── EIP-2771 context ──────────────────────────────────────────

    function _msgSender() internal view returns (address sender) {
        if (
            msg.sender == trustedForwarder &&
            trustedForwarder != address(0) &&
            msg.data.length >= 20
        ) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    // ── One-shot consumer wiring ──────────────────────────────────

    function bindConsumers(address _securityToken, address _yieldDistributor) external {
        require(
            securityToken == address(0) && yieldDistributor == address(0), "BT: already bound"
        );
        require(
            _securityToken != address(0) && _yieldDistributor != address(0), "BT: zero consumer"
        );
        securityToken    = _securityToken;
        yieldDistributor = _yieldDistributor;
        emit ConsumersBound(_securityToken, _yieldDistributor);
    }

    // ── Rate management ───────────────────────────────────────────

    function setAnnualRate(uint256 newRateBps) external {
        require(_msgSender() == admin, "BT: not admin");
        require(!defaulted,            "BT: bond defaulted");
        require(!principalRepaid,      "BT: bond closed");
        require(newRateBps > 0,        "BT: zero rate");
        require(newRateBps <= 10_000,  "BT: rate > 100%");

        uint256 old = annualRateBps;
        annualRateBps = newRateBps;
        rateHistory.push(RateEntry({ rateBps: newRateBps, effectiveAt: block.timestamp }));
        emit RateChanged(old, newRateBps, block.timestamp);
    }

    function getRateHistoryLength() external view returns (uint256) {
        return rateHistory.length;
    }

    // ── Coupon math ───────────────────────────────────────────────

    function couponPerToken() public view returns (uint256) {
        uint256 daysInYear = dayCount == DayCount.ACT_360 ? 360 :
                             dayCount == DayCount.THIRTY_360 ? 360 : 365;
        return (faceValuePerToken * annualRateBps * couponPeriodSeconds)
             / (10_000 * daysInYear * 86_400);
    }

    function isCouponDue() external view returns (bool) {
        return !principalRepaid
            && !defaulted
            && nextCouponDate <= block.timestamp
            && nextCouponDate <= maturityDate;
    }

    function isInGraceBreach() external view returns (bool) {
        return !principalRepaid
            && !defaulted
            && nextCouponDate + gracePeriodSeconds < block.timestamp
            && nextCouponDate <= maturityDate;
    }

    function isMatured() external view returns (bool) {
        return !principalRepaid && block.timestamp >= maturityDate;
    }

    // ── Consumer-only mutators ────────────────────────────────────
    // Raw msg.sender — called by bound contracts directly, not by users.

    function advanceCoupon() external {
        require(msg.sender == yieldDistributor, "BT: only distributor");
        require(!principalRepaid && !defaulted,  "BT: bond closed");
        uint256 prev = nextCouponDate;
        uint256 next = prev + couponPeriodSeconds;
        if (next > maturityDate) next = maturityDate;
        nextCouponDate = next;
        emit CouponAdvanced(prev, next);
    }

    function markDefaulted() external {
        require(
            msg.sender == yieldDistributor || msg.sender == securityToken, "BT: not consumer"
        );
        require(!defaulted && !principalRepaid, "BT: bond closed");
        defaulted = true;
        emit Defaulted(block.timestamp);
    }

    function markPrincipalRepaid() external {
        require(msg.sender == securityToken, "BT: only token");
        require(!principalRepaid, "BT: already repaid");
        principalRepaid = true;
        emit PrincipalRepaid(block.timestamp);
    }
}
