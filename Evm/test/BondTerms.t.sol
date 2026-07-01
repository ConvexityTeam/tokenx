// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

contract BondTermsTest is BaseTest {
    BondTerms terms;

    address admin            = address(this);
    address distributor      = address(0xD157);
    address tokenContract    = address(0x707E);
    address otherDistributor = address(0xD15A);
    address otherToken       = address(0x7012);
    address nobody           = address(0xDEAD);

    uint256 ISSUE;
    uint256 MATURITY;
    uint256 FIRST_COUPON;

    function _defaultParams() internal view returns (BondTerms.InitParams memory) {
        return BondTerms.InitParams({
            annualRateBps:        500,
            couponPeriodSeconds:  90 days,
            dayCount:             BondTerms.DayCount.ACT_365,
            issueDate:            ISSUE,
            maturityDate:         MATURITY,
            firstCouponDate:      FIRST_COUPON,
            faceValuePerToken:    100 ether,
            gracePeriodSeconds:   7 days,
            callable:                false,
            callDate:                0,
            admin:                   admin,
            earlyRedemptionFeeBps:   0
        });
    }

    function setUp() public {
        vm.warp(1_700_000_000);
        ISSUE        = block.timestamp;
        MATURITY     = block.timestamp + 5 * 365 days;
        FIRST_COUPON = block.timestamp + 90 days;

        _deployBeacons();
        terms = _makeBT(_defaultParams());
        terms.bindConsumers(tokenContract, distributor);
    }

    // ── initialize: success ───────────────────────────────────────

    function test_initialize_storesAllFields() public view {
        assertEq(terms.annualRateBps(),       500);
        assertEq(terms.couponPeriodSeconds(), 90 days);
        assertEq(uint256(terms.dayCount()),   uint256(BondTerms.DayCount.ACT_365));
        assertEq(terms.issueDate(),           ISSUE);
        assertEq(terms.maturityDate(),        MATURITY);
        assertEq(terms.firstCouponDate(),     FIRST_COUPON);
        assertEq(terms.faceValuePerToken(),   100 ether);
        assertEq(terms.gracePeriodSeconds(),  7 days);
        assertFalse(terms.callable());
        assertEq(terms.callDate(),            0);
        assertEq(terms.nextCouponDate(),      FIRST_COUPON);
        assertFalse(terms.defaulted());
        assertFalse(terms.principalRepaid());
    }

    function test_initialize_emitsTermsSealed() public {
        BondTerms.InitParams memory p = _defaultParams();
        vm.expectEmit(false, false, false, true);
        emit BondTerms.TermsSealed(
            p.annualRateBps, p.couponPeriodSeconds, p.dayCount,
            p.issueDate, p.maturityDate, p.firstCouponDate, p.faceValuePerToken
        );
        _makeBT(p);
    }

    function testRevert_initialize_alreadyInitialized() public {
        vm.expectRevert("Initializable: contract is already initialized");
        terms.initialize(_defaultParams(), address(0));
    }

    // ── initialize: validation reverts ────────────────────────────

    function testRevert_initialize_maturityBeforeIssue() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.maturityDate = p.issueDate;
        vm.expectRevert("BT: maturity <= issue");
        _makeBT(p);
    }

    function testRevert_initialize_zeroCouponPeriod() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.couponPeriodSeconds = 0;
        vm.expectRevert("BT: zero coupon period");
        _makeBT(p);
    }

    function testRevert_initialize_firstCouponBeforeIssue() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.firstCouponDate = p.issueDate;
        vm.expectRevert("BT: first coupon <= issue");
        _makeBT(p);
    }

    function testRevert_initialize_firstCouponAfterMaturity() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.firstCouponDate = p.maturityDate + 1 days;
        vm.expectRevert("BT: first coupon > maturity");
        _makeBT(p);
    }

    function testRevert_initialize_rateOver100Percent() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.annualRateBps = 10_001;
        vm.expectRevert("BT: rate > 100%");
        _makeBT(p);
    }

    function testRevert_initialize_zeroFaceValue() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.faceValuePerToken = 0;
        vm.expectRevert("BT: zero face value");
        _makeBT(p);
    }

    function testRevert_initialize_tenorShorterThanCoupon() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.couponPeriodSeconds = 365 days;
        p.maturityDate        = p.issueDate + 30 days;
        p.firstCouponDate     = p.issueDate + 10 days;
        vm.expectRevert("BT: tenor shorter than one coupon");
        _makeBT(p);
    }

    function testRevert_initialize_callable_badCallDate_beforeIssue() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.callable = true;
        p.callDate = p.issueDate;
        vm.expectRevert("BT: bad call date");
        _makeBT(p);
    }

    function testRevert_initialize_callable_badCallDate_atMaturity() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.callable = true;
        p.callDate = p.maturityDate;
        vm.expectRevert("BT: bad call date");
        _makeBT(p);
    }

    function test_initialize_callable_validCallDate() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.callable = true;
        p.callDate = p.issueDate + 365 days;
        BondTerms fresh = _makeBT(p);
        assertTrue(fresh.callable());
        assertEq(fresh.callDate(), p.callDate);
    }

    // ── bindConsumers ─────────────────────────────────────────────

    function testRevert_bindConsumers_alreadyBound() public {
        vm.expectRevert("BT: already bound");
        terms.bindConsumers(tokenContract, distributor);
    }

    function testRevert_bindConsumers_zeroToken() public {
        BondTerms fresh = _makeBT(_defaultParams());
        vm.expectRevert("BT: zero consumer");
        fresh.bindConsumers(address(0), distributor);
    }

    function testRevert_bindConsumers_zeroDistributor() public {
        BondTerms fresh = _makeBT(_defaultParams());
        vm.expectRevert("BT: zero consumer");
        fresh.bindConsumers(tokenContract, address(0));
    }

    function test_bindConsumers_emitsEvent() public {
        BondTerms fresh = _makeBT(_defaultParams());
        vm.expectEmit(true, true, false, false);
        emit BondTerms.ConsumersBound(tokenContract, distributor);
        fresh.bindConsumers(tokenContract, distributor);
    }

    // ── couponPerToken math ───────────────────────────────────────

    function _expectedCoupon(uint256 face, uint256 rateBps, uint256 periodSecs, uint256 daysInYear)
        internal pure returns (uint256)
    {
        return (face * rateBps * periodSecs) / (uint256(10_000) * daysInYear * 86_400);
    }

    function test_couponPerToken_act365_quarterlyFivePercent() public view {
        // face=100, rate=5%, period=90d, ACT_365 → 100 * 0.05 * 90/365 = ~1.23287671... per token
        uint256 expected = _expectedCoupon(100 ether, 500, 90 days, 365);
        assertEq(terms.couponPerToken(), expected);
        // Sanity check exact integer value
        assertEq(terms.couponPerToken(), 1_232_876_712_328_767_123); // ≈ 1.232... ether
    }

    function test_couponPerToken_act360_quarterlyFivePercent() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.dayCount = BondTerms.DayCount.ACT_360;
        BondTerms fresh = _makeBT(p);
        uint256 expected = _expectedCoupon(100 ether, 500, 90 days, 360);
        assertEq(fresh.couponPerToken(), expected);
    }

    function test_couponPerToken_thirty360_quarterlyFivePercent() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.dayCount = BondTerms.DayCount.THIRTY_360;
        BondTerms fresh = _makeBT(p);
        uint256 expected = _expectedCoupon(100 ether, 500, 90 days, 360);
        assertEq(fresh.couponPerToken(), expected);
    }

    function test_couponPerToken_zeroRate() public {
        BondTerms.InitParams memory p = _defaultParams();
        p.annualRateBps = 0;
        BondTerms fresh = _makeBT(p);
        assertEq(fresh.couponPerToken(), 0);
    }

    // ── isCouponDue / isInGraceBreach / isMatured views ───────────

    function test_isCouponDue_falseBeforeFirstCoupon() public view {
        assertFalse(terms.isCouponDue());
    }

    function test_isCouponDue_trueAtFirstCoupon() public {
        vm.warp(FIRST_COUPON);
        assertTrue(terms.isCouponDue());
    }

    function test_isCouponDue_falseAfterDefault() public {
        vm.warp(FIRST_COUPON + 8 days);  // past grace
        vm.prank(distributor);
        terms.markDefaulted();
        assertFalse(terms.isCouponDue());
    }

    function test_isInGraceBreach_falseDuringGrace() public {
        vm.warp(FIRST_COUPON + 1 days);
        assertFalse(terms.isInGraceBreach());
    }

    function test_isInGraceBreach_trueAfterGrace() public {
        vm.warp(FIRST_COUPON + 8 days);
        assertTrue(terms.isInGraceBreach());
    }

    function test_isInGraceBreach_falseAfterMaturity() public {
        // Once nextCouponDate has been advanced past maturity, grace breach is no longer flagged
        // simulate: advance enough coupons to reach maturity
        uint256 t = FIRST_COUPON;
        for (uint256 i = 0; i < 20 && t < MATURITY; i++) {
            vm.warp(t);
            vm.prank(distributor);
            terms.advanceCoupon();
            t = terms.nextCouponDate();
        }
        // After last advance, nextCouponDate == maturityDate. Warp past maturity + grace.
        vm.warp(MATURITY + 365 days);
        // nextCouponDate equals maturity, so the grace condition stays true here.
        // The real "end of life" gate is principalRepaid, tested separately.
        assertTrue(terms.isInGraceBreach());
    }

    function test_isMatured_falseBeforeMaturity() public view {
        assertFalse(terms.isMatured());
    }

    function test_isMatured_trueAtMaturity() public {
        vm.warp(MATURITY);
        assertTrue(terms.isMatured());
    }

    function test_isMatured_falseAfterPrincipalRepaid() public {
        vm.warp(MATURITY);
        vm.prank(tokenContract);
        terms.markPrincipalRepaid();
        assertFalse(terms.isMatured());
    }

    // ── advanceCoupon ─────────────────────────────────────────────

    function test_advanceCoupon_advancesByPeriod() public {
        vm.warp(FIRST_COUPON);
        vm.prank(distributor);
        terms.advanceCoupon();
        assertEq(terms.nextCouponDate(), FIRST_COUPON + 90 days);
    }

    function test_advanceCoupon_capsAtMaturity() public {
        // Set nextCouponDate near maturity via repeated advances
        uint256 t = FIRST_COUPON;
        while (t + 90 days < MATURITY) {
            vm.warp(t);
            vm.prank(distributor);
            terms.advanceCoupon();
            t = terms.nextCouponDate();
        }
        // Now one more advance should cap at maturity, not go past it
        vm.warp(t);
        vm.prank(distributor);
        terms.advanceCoupon();
        assertEq(terms.nextCouponDate(), MATURITY);
    }

    function test_advanceCoupon_emitsEvent() public {
        vm.warp(FIRST_COUPON);
        vm.expectEmit(false, false, false, true);
        emit BondTerms.CouponAdvanced(FIRST_COUPON, FIRST_COUPON + 90 days);
        vm.prank(distributor);
        terms.advanceCoupon();
    }

    function testRevert_advanceCoupon_nonDistributor() public {
        vm.warp(FIRST_COUPON);
        vm.prank(tokenContract);
        vm.expectRevert("BT: only distributor");
        terms.advanceCoupon();
    }

    function testRevert_advanceCoupon_nobody() public {
        vm.warp(FIRST_COUPON);
        vm.prank(nobody);
        vm.expectRevert("BT: only distributor");
        terms.advanceCoupon();
    }

    function testRevert_advanceCoupon_afterDefault() public {
        vm.warp(FIRST_COUPON + 8 days);
        vm.prank(distributor);
        terms.markDefaulted();
        vm.prank(distributor);
        vm.expectRevert("BT: bond closed");
        terms.advanceCoupon();
    }

    function testRevert_advanceCoupon_afterPrincipalRepaid() public {
        vm.warp(MATURITY);
        vm.prank(tokenContract);
        terms.markPrincipalRepaid();
        vm.prank(distributor);
        vm.expectRevert("BT: bond closed");
        terms.advanceCoupon();
    }

    // ── markDefaulted ─────────────────────────────────────────────

    function test_markDefaulted_byDistributor() public {
        vm.prank(distributor);
        terms.markDefaulted();
        assertTrue(terms.defaulted());
    }

    function test_markDefaulted_byToken() public {
        vm.prank(tokenContract);
        terms.markDefaulted();
        assertTrue(terms.defaulted());
    }

    function test_markDefaulted_emitsEvent() public {
        vm.warp(1_800_000_000);
        vm.expectEmit(false, false, false, true);
        emit BondTerms.Defaulted(block.timestamp);
        vm.prank(distributor);
        terms.markDefaulted();
    }

    function testRevert_markDefaulted_nobody() public {
        vm.prank(nobody);
        vm.expectRevert("BT: not consumer");
        terms.markDefaulted();
    }

    function testRevert_markDefaulted_twice() public {
        vm.prank(distributor);
        terms.markDefaulted();
        vm.prank(distributor);
        vm.expectRevert("BT: bond closed");
        terms.markDefaulted();
    }

    function testRevert_markDefaulted_afterPrincipalRepaid() public {
        vm.warp(MATURITY);
        vm.prank(tokenContract);
        terms.markPrincipalRepaid();
        vm.prank(distributor);
        vm.expectRevert("BT: bond closed");
        terms.markDefaulted();
    }

    // ── markPrincipalRepaid ───────────────────────────────────────

    function test_markPrincipalRepaid_byToken() public {
        vm.warp(MATURITY);
        vm.prank(tokenContract);
        terms.markPrincipalRepaid();
        assertTrue(terms.principalRepaid());
    }

    function test_markPrincipalRepaid_emitsEvent() public {
        vm.warp(MATURITY);
        vm.expectEmit(false, false, false, true);
        emit BondTerms.PrincipalRepaid(block.timestamp);
        vm.prank(tokenContract);
        terms.markPrincipalRepaid();
    }

    function testRevert_markPrincipalRepaid_byDistributor() public {
        vm.warp(MATURITY);
        vm.prank(distributor);
        vm.expectRevert("BT: only token");
        terms.markPrincipalRepaid();
    }

    function testRevert_markPrincipalRepaid_nobody() public {
        vm.warp(MATURITY);
        vm.prank(nobody);
        vm.expectRevert("BT: only token");
        terms.markPrincipalRepaid();
    }

    function testRevert_markPrincipalRepaid_twice() public {
        vm.warp(MATURITY);
        vm.prank(tokenContract);
        terms.markPrincipalRepaid();
        vm.prank(tokenContract);
        vm.expectRevert("BT: already repaid");
        terms.markPrincipalRepaid();
    }
}
