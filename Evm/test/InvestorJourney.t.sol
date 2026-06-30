// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

/**
 * @title InvestorJourneyTest
 * @notice Models the complete on-chain experience from the investor's perspective.
 *
 *   Off-chain (not tested here - handled by the issuer's back-office):
 *     * Investor wires fiat / sends USDC to the issuer
 *     * Issuer confirms payment and completes KYC
 *
 *   On-chain investor journey (what this file tests):
 *
 *   Standard token (no yield):
 *     1. Issuer registers investor identity
 *     2. Issuer mints security tokens to investor wallet
 *     3. Investor holds tokens (read-only - balance, frozen state)
 *     4. Investor transfers tokens to another verified wallet (secondary market)
 *     5. Investor cannot transfer to an unverified wallet
 *     6. Investor's wallet is frozen by issuer (regulatory hold)
 *     7. Frozen investor cannot transfer
 *
 *   Yield-bearing token:
 *     1-2. Same as above (register + mint)
 *     3. Issuer creates a snapshot / deposits payout funds
 *     4. Investor calls claimYield - receives USDC
 *     5. Investor calls claimYield again on same snapshot - reverts (already claimed)
 *     6. Investor never calls approve - payout arrives automatically
 *
 *   Bond:
 *     1-2. Same (register + mint)
 *     3. Coupon date arrives; issuer creates scheduled coupon
 *     4. Investor claims coupon payout in USDC
 *     5. At maturity, issuer batch-redeems - USDC principal lands in investor wallet
 *     6. Investor holds zero tokens after redemption - bond is fully closed
 *
 *   Wallets:
 *     issuer / agent  = address(this)   has all admin + agent roles
 *     alice           = primary investor
 *     bob             = secondary buyer (receives tokens from alice)
 *     unverified      = wallet with no KYC - transfers to it must fail
 */
contract InvestorJourneyTest is BaseTest {
    receive() external payable {}

    // -- Payout token ----------------------------------------------
    MockStablecoin usdc;

    // -- Wallets ---------------------------------------------------
    address issuer     = address(this);
    address alice      = address(0xA11CE);
    address bob        = address(0xB0B);
    address unverified = address(0xDEAD);

    uint16 constant NIGERIA = 566;

    // -- Bond timing -----------------------------------------------
    uint256 ISSUE;
    uint256 MATURITY;
    uint256 FIRST_COUPON;
    uint256 constant COUPON_PERIOD = 90 days;
    uint256 constant RATE_BPS      = 500;   // 5% APR
    uint256 constant FACE          = 100e6; // $100 par per token (USDC 6-dec)

    TokenizationFactory factory;
    TokenizationFactory.ComplianceParams noLimits = TokenizationFactory.ComplianceParams({
        maxShareholders:      0,
        maxTokensPerInvestor: 0,
        lockUpDuration:       0
    });

    function setUp() public {
        vm.warp(1_700_000_000);
        ISSUE        = block.timestamp;
        MATURITY     = ISSUE + 5 * 365 days;
        FIRST_COUPON = ISSUE + COUPON_PERIOD;

        _deployBeacons();
        factory = _makeFactory(issuer);
        usdc    = new MockStablecoin();
    }

    // -------------------------------------------------------------
    // Helper: deploy a standard (no-yield) token suite
    // -------------------------------------------------------------
    function _deployStandard(string memory id)
        internal
        returns (SecurityToken tok, IdentityRegistry reg, ComplianceModule comp)
    {
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY,
            id, "Acme Equity", "ACME", address(0), issuer, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment(id);
        tok  = SecurityToken(payable(rec.token));
        reg  = IdentityRegistry(rec.identityRegistry);
        comp = ComplianceModule(rec.compliance);
    }

    // Helper: deploy a yield-bearing suite
    function _deployYield(string memory id)
        internal
        returns (SecurityToken tok, IdentityRegistry reg, YieldDistributor dist)
    {
        factory.deployToken(
            TokenizationFactory.TokenType.YIELD_BEARING,
            id, "Acme Yield Note", "ACMYN", address(0), issuer, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment(id);
        tok  = SecurityToken(payable(rec.token));
        reg  = IdentityRegistry(rec.identityRegistry);
        dist = YieldDistributor(payable(rec.yieldDistributor));
    }

    // Helper: deploy a bond suite
    function _deployBond(string memory id)
        internal
        returns (SecurityToken tok, IdentityRegistry reg, YieldDistributor dist, BondTerms terms)
    {
        BondTerms.InitParams memory p = BondTerms.InitParams({
            annualRateBps:        RATE_BPS,
            couponPeriodSeconds:  COUPON_PERIOD,
            dayCount:             BondTerms.DayCount.ACT_365,
            issueDate:            ISSUE,
            maturityDate:         MATURITY,
            firstCouponDate:      FIRST_COUPON,
            faceValuePerToken:    FACE,
            gracePeriodSeconds:   7 days,
            callable:             false,
            callDate:             0,
            admin:                issuer
        });
        factory.deployBond(id, "Acme Bond 5y", "ACMB5", address(0), issuer, noLimits, p);
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment(id);
        tok   = SecurityToken(payable(rec.token));
        reg   = IdentityRegistry(rec.identityRegistry);
        dist  = YieldDistributor(payable(rec.yieldDistributor));
        terms = BondTerms(rec.bondTerms);
    }

    // ===============================================================
    // Journey 1 - Standard token (no yield)
    // ===============================================================

    function test_journey_standard_receiveAndHold() public {
        (SecurityToken tok, IdentityRegistry reg,) = _deployStandard("STD-001");

        // -- Step 1: issuer registers alice (off-chain KYC confirmed) --
        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        assertTrue(reg.isVerified(alice));

        // -- Step 2: issuer mints tokens - alice pays nothing on-chain --
        tok.mint(alice, 1000e18);

        // -- Step 3: alice holds tokens --------------------------------
        assertEq(tok.balanceOf(alice), 1000e18);
        assertFalse(tok.isFrozen(alice));
        // Alice has NOT called approve or paid anything on-chain
    }

    function test_journey_standard_secondaryTransfer() public {
        (SecurityToken tok, IdentityRegistry reg,) = _deployStandard("STD-002");

        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        reg.registerIdentity(bob,   address(0x1002), NIGERIA);
        tok.mint(alice, 1000e18);

        // -- Step 4: alice sells 400 tokens to bob on the secondary market --
        // Alice signs and sends this transaction herself (she needs ETH for gas,
        // or uses the forwarder for a gasless transfer - but no approve needed
        // unless using transferFrom via a DEX)
        vm.prank(alice);
        tok.transfer(bob, 400e18);

        assertEq(tok.balanceOf(alice), 600e18);
        assertEq(tok.balanceOf(bob),   400e18);
    }

    function test_journey_standard_cannotTransferToUnverifiedWallet() public {
        (SecurityToken tok, IdentityRegistry reg,) = _deployStandard("STD-003");

        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        tok.mint(alice, 1000e18);

        // -- Step 5: transfer to an unverified wallet is blocked ----------
        // unverified has no KYC - compliance rejects the transfer
        vm.prank(alice);
        vm.expectRevert("ST: recipient not verified");
        tok.transfer(unverified, 100e18);
    }

    function test_journey_standard_frozenInvestorCannotTransfer() public {
        (SecurityToken tok, IdentityRegistry reg,) = _deployStandard("STD-004");

        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        reg.registerIdentity(bob,   address(0x1002), NIGERIA);
        tok.mint(alice, 1000e18);

        // -- Step 6: issuer freezes alice (e.g. regulatory hold) ----------
        tok.setAddressFrozen(alice, true);
        assertTrue(tok.isFrozen(alice));

        // -- Step 7: frozen alice cannot send or receive tokens ------------
        vm.prank(alice);
        vm.expectRevert("ST: wallet frozen");
        tok.transfer(bob, 100e18);

        // Issuer unfreezes - alice can transfer again
        tok.setAddressFrozen(alice, false);
        vm.prank(alice);
        tok.transfer(bob, 100e18);
        assertEq(tok.balanceOf(bob), 100e18);
    }

    // ===============================================================
    // Journey 2 - Yield-bearing token
    // ===============================================================

    function test_journey_yield_receiveTokensThenClaimDividend() public {
        (SecurityToken tok, IdentityRegistry reg, YieldDistributor dist) =
            _deployYield("YB-001");

        // -- Steps 1 & 2: register + mint (investor paid off-chain) -------
        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        reg.registerIdentity(bob,   address(0x1002), NIGERIA);
        tok.mint(alice, 600e18);
        tok.mint(bob,   400e18);

        // -- Step 3: issuer deposits dividend and creates snapshot ---------
        // Issuer approves USDC -> YieldDistributor (NOT the investor)
        uint256 dividend = 10_000e6; // $10,000 USDC total payout
        usdc.mint(issuer, dividend);
        usdc.approve(address(dist), dividend);

        address[] memory investors = new address[](2);
        investors[0] = alice;
        investors[1] = bob;

        uint256 snapId = dist.createSnapshot(
            investors,
            address(usdc),
            dividend,
            30 days,
            "Q1 2025 Dividend"
        );

        // -- Step 4: alice claims her pro-rata share -----------------------
        // Alice calls claimYield herself - no approve, no prior setup needed
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        dist.claimYield(snapId);

        // Alice holds 60% of supply -> receives 60% of dividend
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceBefore, dividend * 600 / 1000, 1);

        // -- Step 5: alice cannot claim the same snapshot twice ------------
        vm.prank(alice);
        vm.expectRevert("YD: already claimed");
        dist.claimYield(snapId);

        // Bob claims his 40%
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        dist.claimYield(snapId);
        assertApproxEqAbs(usdc.balanceOf(bob) - bobBefore, dividend * 400 / 1000, 1);
    }

    function test_journey_yield_investorNeverCallsApprove() public {
        (SecurityToken tok, IdentityRegistry reg, YieldDistributor dist) =
            _deployYield("YB-002");

        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        tok.mint(alice, 1000e18);

        uint256 dividend = 5_000e6;
        usdc.mint(issuer, dividend);
        usdc.approve(address(dist), dividend);

        address[] memory investors = new address[](1);
        investors[0] = alice;

        uint256 snapId = dist.createSnapshot(investors, address(usdc), dividend, 30 days, "Payout");

        // Alice claims - she has never called approve on anything
        // Her only on-chain action is claimYield
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        dist.claimYield(snapId);

        assertGt(usdc.balanceOf(alice), aliceBefore);
    }

    // ===============================================================
    // Journey 3 - Bond: coupon + principal redemption
    // ===============================================================

    function test_journey_bond_fullLifecycle() public {
        (SecurityToken tok, IdentityRegistry reg, YieldDistributor dist, BondTerms terms) =
            _deployBond("BOND-001");

        // -- Steps 1 & 2: issuer registers alice, mints bond tokens --------
        // Alice wired $60,000 off-chain -> issuer mints 600 bond tokens
        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        reg.registerIdentity(bob,   address(0x1002), NIGERIA);
        tok.mint(alice, 600e18);
        tok.mint(bob,   400e18);

        assertEq(tok.balanceOf(alice), 600e18);
        assertEq(tok.balanceOf(bob),   400e18);
        // Alice holds bond tokens. She has not called approve or paid on-chain.

        // -- Step 3: first coupon date arrives -----------------------------
        vm.warp(FIRST_COUPON);
        assertTrue(terms.isCouponDue());

        // Issuer calculates and deposits coupon funds
        uint256 perToken    = terms.couponPerToken();
        uint256 totalCoupon = perToken * 1000e18 / 1e18;
        usdc.mint(issuer, totalCoupon);
        usdc.approve(address(dist), totalCoupon);

        address[] memory investors = new address[](2);
        investors[0] = alice;
        investors[1] = bob;

        uint256 snapId = dist.createScheduledCoupon(
            investors, address(usdc), 30 days, "Coupon 1 - Q1 2026"
        );

        // nextCouponDate advanced automatically
        assertEq(terms.nextCouponDate(), FIRST_COUPON + COUPON_PERIOD);

        // -- Step 4: alice claims her coupon share -------------------------
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        dist.claimYield(snapId);

        uint256 aliceCoupon = totalCoupon * 600 / 1000;
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceUsdcBefore, aliceCoupon, 1);

        // Bob claims his share
        uint256 bobCoupon = totalCoupon * 400 / 1000;
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        dist.claimYield(snapId);
        assertApproxEqAbs(usdc.balanceOf(bob) - bobUsdcBefore, bobCoupon, 1);

        // -- Step 5: bond matures - issuer deposits principal --------------
        // principal = balance * faceValuePerToken / 1e18
        // alice: 600e18 * 100e6 / 1e18 = 60,000 USDC
        // bob:   400e18 * 100e6 / 1e18 = 40,000 USDC
        uint256 alicePrincipal = 600e18 * FACE / 1e18;
        uint256 bobPrincipal   = 400e18 * FACE / 1e18;
        uint256 totalPrincipal = alicePrincipal + bobPrincipal;

        usdc.mint(address(tok), totalPrincipal); // issuer sends principal to token contract

        vm.warp(MATURITY);
        assertTrue(terms.isMatured());

        // -- Step 6: issuer triggers batch redemption ----------------------
        // Tokens are burned, USDC principal lands directly in investor wallets
        // Investors do NOT call anything - agent calls batchRedeemAtMaturity
        aliceUsdcBefore = usdc.balanceOf(alice);
        bobUsdcBefore   = usdc.balanceOf(bob);

        tok.batchRedeemAtMaturity(investors, address(usdc));

        // -- Step 7: investor holds zero tokens, bond is closed ------------
        assertEq(tok.balanceOf(alice), 0);
        assertEq(tok.balanceOf(bob),   0);
        assertEq(tok.totalSupply(),    0);
        assertTrue(terms.principalRepaid());

        // Alice received exactly her principal
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, alicePrincipal);
        assertEq(usdc.balanceOf(bob)   - bobUsdcBefore,   bobPrincipal);
    }

    function test_journey_bond_investorCannotTransferAfterMaturity() public {
        (SecurityToken tok, IdentityRegistry reg,, BondTerms terms) =
            _deployBond("BOND-002");

        reg.registerIdentity(alice, address(0x1001), NIGERIA);
        reg.registerIdentity(bob,   address(0x1002), NIGERIA);
        tok.mint(alice, 100e18);

        // At maturity, tokens are redeemed - alice has zero balance
        uint256 principal = 100e18 * FACE / 1e18;
        usdc.mint(address(tok), principal);
        vm.warp(MATURITY);
        tok.redeemAtMaturity(alice, address(usdc));

        assertEq(tok.balanceOf(alice), 0);

        // Alice cannot transfer what she no longer holds
        vm.prank(alice);
        vm.expectRevert("ST: insufficient unfrozen balance");
        tok.transfer(bob, 1);
    }
}

// -- Minimal ERC-20 stablecoin for tests --------------------------------------

contract MockStablecoin {
    string public name     = "Mock USDC";
    string public symbol   = "USDC";
    uint8  public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }
}
