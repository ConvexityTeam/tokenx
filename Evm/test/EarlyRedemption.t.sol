// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

/**
 * @title EarlyRedemptionTest
 * @notice Full coverage for the early-redemption penalty feature:
 *
 *   BondTerms
 *     - earlyRedemptionFeeBps: init, validation, setEarlyRedemptionFee
 *     - penaltyRecipient: default, setPenaltyRecipient
 *
 *   SecurityToken.redeemEarly
 *     - Happy paths: ERC-20 payout, ETH payout
 *     - Penalty math: various bps values including edges (0%, 100%)
 *     - Penalty routing: default recipient (admin), updated recipient
 *     - Token accounting: burns, clears frozenTokens, compliance.destroyed
 *     - Event emission
 *     - All revert paths: disabled, matured, defaulted, closed, no terms,
 *       zero balance, not compliant, not agent, paused
 *     - Multi-investor sequential redemptions
 *     - markPrincipalRepaid NOT triggered by early redemption
 */
contract EarlyRedemptionTest is BaseTest {
    receive() external payable {}

    // ── mock token ────────────────────────────────────────────────
    MockToken usdc;

    // ── actors ────────────────────────────────────────────────────
    address admin      = address(this);
    address alice      = address(0xA11CE);
    address bob        = address(0xB0B);
    address treasury   = address(0x7EA5);
    address nobody     = address(0xDEAD);

    uint16 constant COUNTRY = 566;

    // ── time constants ────────────────────────────────────────────
    uint256 ISSUE;
    uint256 MATURITY;
    uint256 FIRST_COUPON;
    uint256 constant COUPON_PERIOD = 90 days;
    uint256 constant RATE_BPS      = 500;
    // face = $100 USDC (6 dec)
    uint256 constant FACE          = 100e6;
    uint256 constant EARLY_FEE_BPS = 200;   // 2% default early redemption penalty

    // ── deployed suite ────────────────────────────────────────────
    TokenizationFactory factory;
    SecurityToken       token;
    BondTerms           terms;
    IdentityRegistry    registry;
    ComplianceModule    compliance;
    YieldDistributor    distributor;

    TokenizationFactory.ComplianceParams noLimits = TokenizationFactory.ComplianceParams({
        maxShareholders: 0, maxTokensPerInvestor: 0, lockUpDuration: 0
    });

    // ═══════════════════════════════════════════════════════════════
    // setUp
    // ═══════════════════════════════════════════════════════════════

    function setUp() public {
        vm.warp(1_700_000_000);
        ISSUE        = block.timestamp;
        MATURITY     = ISSUE + 5 * 365 days;
        FIRST_COUPON = ISSUE + COUPON_PERIOD;

        _deployBeacons();
        factory = _makeFactory(admin);
        usdc    = new MockToken();

        _deployBond(EARLY_FEE_BPS);

        // Register investors
        registry.registerIdentity(alice,    address(0x1001), COUNTRY);
        registry.registerIdentity(bob,      address(0x1002), COUNTRY);
        registry.registerIdentity(treasury, address(0x1003), COUNTRY);
    }

    // ── internal helpers ──────────────────────────────────────────

    function _bondParams(uint256 feeBps) internal view returns (BondTerms.InitParams memory) {
        return BondTerms.InitParams({
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
            admin:                admin,
            earlyRedemptionFeeBps: feeBps
        });
    }

    function _deployBond(uint256 feeBps) internal {
        (address t, address bt) = factory.deployBond(
            "BOND-001", "Acme Bond 5y", "ACMB5",
            address(0), admin, noLimits, _bondParams(feeBps)
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("BOND-001");
        token       = SecurityToken(payable(t));
        terms       = BondTerms(bt);
        registry    = IdentityRegistry(rec.identityRegistry);
        compliance  = ComplianceModule(rec.compliance);
        distributor = YieldDistributor(payable(rec.yieldDistributor));
    }

    /// Mint `amount` ERC-20 tokens to `holder` and fund `token` contract with the full principal.
    function _setupHolder(address holder, uint256 tokenAmt) internal {
        token.mint(holder, tokenAmt);
        uint256 principal = tokenAmt * FACE / 1e18;
        usdc.mint(address(token), principal);
    }

    /// Expected penalty and payout given a token balance and fee bps.
    function _expected(uint256 tokenAmt, uint256 feeBps)
        internal pure returns (uint256 payout, uint256 penalty)
    {
        uint256 principal = tokenAmt * FACE / 1e18;
        penalty = principal * feeBps / 10_000;
        payout  = principal - penalty;
    }

    // ═══════════════════════════════════════════════════════════════
    // BondTerms — init: earlyRedemptionFeeBps
    // ═══════════════════════════════════════════════════════════════

    function test_BT_init_defaultFeeIsZero() public {
        BondTerms fresh = _makeBT(_bondParams(0));
        assertEq(fresh.earlyRedemptionFeeBps(), 0);
    }

    function test_BT_init_storesFeeCorrectly() public view {
        assertEq(terms.earlyRedemptionFeeBps(), EARLY_FEE_BPS);
    }

    function test_BT_init_maxFee_100pct() public {
        BondTerms fresh = _makeBT(_bondParams(10_000));
        assertEq(fresh.earlyRedemptionFeeBps(), 10_000);
    }

    function testRevert_BT_init_feeOver100pct() public {
        vm.expectRevert("BT: early fee > 100%");
        _makeBT(_bondParams(10_001));
    }

    // ═══════════════════════════════════════════════════════════════
    // BondTerms — init: penaltyRecipient defaults to admin
    // ═══════════════════════════════════════════════════════════════

    function test_BT_init_penaltyRecipientIsAdmin() public view {
        assertEq(terms.penaltyRecipient(), admin);
    }

    function test_BT_init_penaltyRecipientIsAdmin_withCustomFee() public {
        BondTerms fresh = _makeBT(_bondParams(500));
        assertEq(fresh.penaltyRecipient(), admin);
    }

    // ═══════════════════════════════════════════════════════════════
    // BondTerms — setEarlyRedemptionFee
    // ═══════════════════════════════════════════════════════════════

    function test_BT_setEarlyRedemptionFee_updatesValue() public {
        terms.setEarlyRedemptionFee(500);
        assertEq(terms.earlyRedemptionFeeBps(), 500);
    }

    function test_BT_setEarlyRedemptionFee_setToZeroDisables() public {
        terms.setEarlyRedemptionFee(0);
        assertEq(terms.earlyRedemptionFeeBps(), 0);
    }

    function test_BT_setEarlyRedemptionFee_setToMax() public {
        terms.setEarlyRedemptionFee(10_000);
        assertEq(terms.earlyRedemptionFeeBps(), 10_000);
    }

    function test_BT_setEarlyRedemptionFee_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BondTerms.EarlyRedemptionFeeSet(EARLY_FEE_BPS, 750);
        terms.setEarlyRedemptionFee(750);
    }

    function testRevert_BT_setEarlyRedemptionFee_notAdmin() public {
        vm.prank(nobody);
        vm.expectRevert("BT: not admin");
        terms.setEarlyRedemptionFee(500);
    }

    function testRevert_BT_setEarlyRedemptionFee_feeOver100pct() public {
        vm.expectRevert("BT: fee > 100%");
        terms.setEarlyRedemptionFee(10_001);
    }

    function testRevert_BT_setEarlyRedemptionFee_afterPrincipalRepaid() public {
        // mint alice tokens then redeem at maturity to flip principalRepaid = true
        token.mint(alice, 1 ether);
        usdc.mint(address(token), FACE);
        vm.warp(MATURITY);
        address[] memory holders = new address[](1);
        holders[0] = alice;
        token.batchRedeemAtMaturity(holders, address(usdc));
        assertTrue(terms.principalRepaid());

        vm.expectRevert("BT: bond closed");
        terms.setEarlyRedemptionFee(100);
    }

    // ═══════════════════════════════════════════════════════════════
    // BondTerms — setPenaltyRecipient
    // ═══════════════════════════════════════════════════════════════

    function test_BT_setPenaltyRecipient_updatesAddress() public {
        terms.setPenaltyRecipient(treasury);
        assertEq(terms.penaltyRecipient(), treasury);
    }

    function test_BT_setPenaltyRecipient_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit BondTerms.PenaltyRecipientSet(admin, treasury);
        terms.setPenaltyRecipient(treasury);
    }

    function testRevert_BT_setPenaltyRecipient_notAdmin() public {
        vm.prank(nobody);
        vm.expectRevert("BT: not admin");
        terms.setPenaltyRecipient(treasury);
    }

    function testRevert_BT_setPenaltyRecipient_zeroAddress() public {
        vm.expectRevert("BT: zero recipient");
        terms.setPenaltyRecipient(address(0));
    }

    // ═══════════════════════════════════════════════════════════════
    // SecurityToken.redeemEarly — happy paths
    // ═══════════════════════════════════════════════════════════════

    function test_redeemEarly_erc20_correctPayoutAndPenalty() public {
        uint256 tokenAmt = 10 ether;
        _setupHolder(alice, tokenAmt);

        (uint256 wantPayout, uint256 wantPenalty) = _expected(tokenAmt, EARLY_FEE_BPS);

        uint256 aliceBefore  = usdc.balanceOf(alice);
        uint256 adminBefore  = usdc.balanceOf(admin);

        token.redeemEarly(alice, address(usdc));

        assertEq(usdc.balanceOf(alice) - aliceBefore, wantPayout,  "alice payout wrong");
        assertEq(usdc.balanceOf(admin) - adminBefore, wantPenalty, "admin penalty wrong");
    }

    function test_redeemEarly_erc20_burnsAllTokens() public {
        uint256 tokenAmt = 5 ether;
        _setupHolder(alice, tokenAmt);

        assertEq(token.balanceOf(alice), tokenAmt);
        token.redeemEarly(alice, address(usdc));
        assertEq(token.balanceOf(alice), 0);
    }

    function test_redeemEarly_erc20_totalSupplyDecreases() public {
        _setupHolder(alice, 10 ether);
        _setupHolder(bob,   10 ether);

        uint256 supplyBefore = token.totalSupply();
        token.redeemEarly(alice, address(usdc));
        assertEq(token.totalSupply(), supplyBefore - 10 ether);
    }

    function test_redeemEarly_erc20_penaltyToUpdatedRecipient() public {
        terms.setPenaltyRecipient(treasury);

        uint256 tokenAmt = 8 ether;
        _setupHolder(alice, tokenAmt);
        (, uint256 wantPenalty) = _expected(tokenAmt, EARLY_FEE_BPS);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 adminBefore    = usdc.balanceOf(admin);

        token.redeemEarly(alice, address(usdc));

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, wantPenalty, "penalty to treasury");
        assertEq(usdc.balanceOf(admin),    adminBefore,                  "admin gets nothing");
    }

    function test_redeemEarly_eth_correctPayoutAndPenalty() public {
        // Deploy a new bond suite with ETH-denominated face value
        uint256 ethFace = 0.1 ether;
        BondTerms.InitParams memory p = _bondParams(EARLY_FEE_BPS);
        p.faceValuePerToken = ethFace;

        (address t,) = factory.deployBond(
            "ETH-BOND", "ETH Bond", "ETHB",
            address(0), admin, noLimits, p
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("ETH-BOND");
        SecurityToken ethToken  = SecurityToken(payable(t));
        IdentityRegistry ethReg = IdentityRegistry(rec.identityRegistry);

        ethReg.registerIdentity(alice, address(0x1001), COUNTRY);
        ethToken.mint(alice, 5 ether); // 5 tokens

        uint256 principal = 5 ether * ethFace / 1e18; // 0.5 ETH
        vm.deal(address(ethToken), principal);

        uint256 wantPenalty = principal * EARLY_FEE_BPS / 10_000;
        uint256 wantPayout  = principal - wantPenalty;

        uint256 aliceBefore = alice.balance;
        uint256 adminBefore = admin.balance;

        ethToken.redeemEarly(alice, address(0));

        assertEq(alice.balance - aliceBefore, wantPayout,  "alice ETH payout");
        assertEq(admin.balance - adminBefore, wantPenalty, "admin ETH penalty");
    }

    function test_redeemEarly_emitsEvent() public {
        uint256 tokenAmt = 10 ether;
        _setupHolder(alice, tokenAmt);

        (uint256 wantPayout, uint256 wantPenalty) = _expected(tokenAmt, EARLY_FEE_BPS);

        vm.expectEmit(true, false, true, true);
        emit SecurityToken.EarlyRedemption(alice, tokenAmt, wantPayout, wantPenalty, admin);
        token.redeemEarly(alice, address(usdc));
    }

    function test_redeemEarly_clearsFrozenTokens() public {
        _setupHolder(alice, 10 ether);
        token.freezePartialTokens(alice, 3 ether);
        assertEq(token.getFrozenTokens(alice), 3 ether);

        token.redeemEarly(alice, address(usdc));

        assertEq(token.getFrozenTokens(alice), 0);
    }

    function test_redeemEarly_multipleInvestors_independent() public {
        _setupHolder(alice, 10 ether);
        _setupHolder(bob,   20 ether);

        (uint256 alicePayout, uint256 alicePenalty) = _expected(10 ether, EARLY_FEE_BPS);
        (uint256 bobPayout,   uint256 bobPenalty)   = _expected(20 ether, EARLY_FEE_BPS);

        uint256 adminBefore = usdc.balanceOf(admin);

        token.redeemEarly(alice, address(usdc));
        token.redeemEarly(bob,   address(usdc));

        assertEq(usdc.balanceOf(alice), alicePayout,                   "alice payout");
        assertEq(usdc.balanceOf(bob),   bobPayout,                     "bob payout");
        assertEq(usdc.balanceOf(admin) - adminBefore, alicePenalty + bobPenalty, "total penalty");
        assertEq(token.totalSupply(), 0);
    }

    function test_redeemEarly_doesNotMarkPrincipalRepaid() public {
        // Even if the last token holder redeems early, principalRepaid must NOT be set.
        // The bond lifecycle is separate from early exit.
        _setupHolder(alice, 10 ether);

        token.redeemEarly(alice, address(usdc));

        assertEq(token.totalSupply(), 0);
        assertFalse(terms.principalRepaid(), "principalRepaid must stay false after early exit");
    }

    // ═══════════════════════════════════════════════════════════════
    // SecurityToken.redeemEarly — penalty math edge cases
    // ═══════════════════════════════════════════════════════════════

    function test_redeemEarly_oneBps_penalty() public {
        terms.setEarlyRedemptionFee(1);
        _setupHolder(alice, 10 ether);

        uint256 principal = 10 ether * FACE / 1e18;
        uint256 penalty   = principal * 1 / 10_000;
        uint256 payout    = principal - penalty;

        token.redeemEarly(alice, address(usdc));

        assertEq(usdc.balanceOf(alice), payout,   "payout 1bps");
        assertEq(usdc.balanceOf(admin), penalty,  "penalty 1bps");
    }

    function test_redeemEarly_9999bps_almostFullPenalty() public {
        terms.setEarlyRedemptionFee(9_999);
        _setupHolder(alice, 10 ether);

        uint256 principal = 10 ether * FACE / 1e18;
        uint256 penalty   = principal * 9_999 / 10_000;
        uint256 payout    = principal - penalty;

        token.redeemEarly(alice, address(usdc));

        assertEq(usdc.balanceOf(alice), payout,  "payout 9999bps");
        assertEq(usdc.balanceOf(admin), penalty, "penalty 9999bps");
    }

    function test_redeemEarly_100pct_penaltyPayoutIsZero() public {
        terms.setEarlyRedemptionFee(10_000);
        _setupHolder(alice, 10 ether);

        uint256 principal = 10 ether * FACE / 1e18;

        token.redeemEarly(alice, address(usdc));

        assertEq(usdc.balanceOf(alice), 0,         "investor gets nothing at 100% fee");
        assertEq(usdc.balanceOf(admin), principal, "admin gets all principal");
    }

    function test_redeemEarly_50pct_evenSplit() public {
        terms.setEarlyRedemptionFee(5_000);
        _setupHolder(alice, 10 ether);

        uint256 principal = 10 ether * FACE / 1e18;

        token.redeemEarly(alice, address(usdc));

        assertEq(usdc.balanceOf(alice), principal / 2, "alice half");
        assertEq(usdc.balanceOf(admin), principal / 2, "admin half");
    }

    // ═══════════════════════════════════════════════════════════════
    // SecurityToken.redeemEarly — revert paths
    // ═══════════════════════════════════════════════════════════════

    function testRevert_redeemEarly_noBondTerms() public {
        // Deploy a plain security token with its own isolated IR + CM (no bond terms)
        IdentityRegistry ir2 = _makeIR(admin);
        ComplianceModule cm2 = _makeCM(admin, 0, 0, 0);
        SecurityToken bare   = _makeST("BARE", "B", address(ir2), address(cm2), admin);
        cm2.bindToken(address(bare));
        ir2.registerIdentity(alice, address(0x1001), COUNTRY);
        bare.mint(alice, 10 ether);

        vm.expectRevert("ST: no bond terms");
        bare.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_earlyRedemptionDisabled() public {
        terms.setEarlyRedemptionFee(0);
        _setupHolder(alice, 10 ether);

        vm.expectRevert("ST: early redemption disabled");
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_bondMatured() public {
        _setupHolder(alice, 10 ether);
        vm.warp(MATURITY);

        vm.expectRevert("ST: use redeemAtMaturity");
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_bondDefaulted() public {
        _setupHolder(alice, 10 ether);
        vm.prank(address(distributor));
        terms.markDefaulted();

        vm.expectRevert("ST: bond defaulted");
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_bondClosed() public {
        // alice still has tokens; force-flip principalRepaid via the bound securityToken
        _setupHolder(alice, 10 ether);
        vm.prank(address(token));
        terms.markPrincipalRepaid();
        assertTrue(terms.principalRepaid());

        vm.expectRevert("ST: bond closed");
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_holderNotCompliant() public {
        _setupHolder(alice, 10 ether);

        // Enable wallet allowlist — alice is not on it, so canHold returns false
        compliance.setWalletAllowlistEnabled(true);

        vm.expectRevert("ST: holder not eligible");
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_zeroBalance() public {
        // Alice is registered but has no tokens
        vm.expectRevert("ST: zero balance");
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_notAgent() public {
        _setupHolder(alice, 10 ether);

        vm.prank(nobody);
        vm.expectRevert(); // AccessControl: missing AGENT_ROLE
        token.redeemEarly(alice, address(usdc));
    }

    function testRevert_redeemEarly_whenPaused() public {
        _setupHolder(alice, 10 ether);
        token.pause();

        vm.expectRevert("Pausable: paused");
        token.redeemEarly(alice, address(usdc));
    }

    // ═══════════════════════════════════════════════════════════════
    // Interaction: redeemEarly then redeemAtMaturity for remaining holders
    // ═══════════════════════════════════════════════════════════════

    function test_redeemEarly_thenMatureRedeemRemainingHolder() public {
        _setupHolder(alice, 10 ether);
        _setupHolder(bob,   10 ether);

        // Alice exits early
        token.redeemEarly(alice, address(usdc));
        assertEq(token.balanceOf(alice), 0);
        assertFalse(terms.principalRepaid());

        // Bond matures; Bob redeems normally — should succeed and mark repaid
        vm.warp(MATURITY);
        uint256 bobPrincipal = 10 ether * FACE / 1e18;
        usdc.mint(address(token), bobPrincipal);
        token.redeemAtMaturity(bob, address(usdc));

        assertEq(token.balanceOf(bob), 0);
        assertTrue(terms.principalRepaid(), "bond should be closed after last holder redeems");
    }

    function test_redeemEarly_thenFeeUpdated_newInvestorSeesNewFee() public {
        _setupHolder(alice, 10 ether);
        _setupHolder(bob,   10 ether);

        // Alice redeems at original fee (2%)
        (uint256 alicePayout,) = _expected(10 ether, EARLY_FEE_BPS);
        token.redeemEarly(alice, address(usdc));
        assertEq(usdc.balanceOf(alice), alicePayout);

        // Admin updates fee to 10%
        terms.setEarlyRedemptionFee(1_000);

        // Bob redeems at new fee (10%)
        uint256 bobPrincipal = 10 ether * FACE / 1e18;
        uint256 bobPenalty   = bobPrincipal * 1_000 / 10_000;
        uint256 bobPayout    = bobPrincipal - bobPenalty;

        token.redeemEarly(bob, address(usdc));
        assertEq(usdc.balanceOf(bob), bobPayout, "bob payout at new fee");
    }

    function test_redeemEarly_thenPenaltyRecipientUpdated() public {
        _setupHolder(alice, 10 ether);
        _setupHolder(bob,   10 ether);

        // Alice redeems — penalty goes to admin (default)
        (, uint256 alicePenalty) = _expected(10 ether, EARLY_FEE_BPS);
        uint256 adminBefore = usdc.balanceOf(admin);
        token.redeemEarly(alice, address(usdc));
        assertEq(usdc.balanceOf(admin) - adminBefore, alicePenalty);

        // Admin updates recipient to treasury
        terms.setPenaltyRecipient(treasury);

        // Bob redeems — penalty goes to treasury
        (, uint256 bobPenalty) = _expected(10 ether, EARLY_FEE_BPS);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        token.redeemEarly(bob, address(usdc));
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, bobPenalty, "penalty to treasury");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz
    // ═══════════════════════════════════════════════════════════════

    /// @dev Fuzz over token amount and fee bps, verify penalty + payout == principal.
    function testFuzz_redeemEarly_payoutPlusPenaltyEqualsPrincipal(
        uint256 tokenAmt,
        uint256 feeBps
    ) public {
        tokenAmt = bound(tokenAmt, 1 ether, 1_000 ether);
        feeBps   = bound(feeBps,   1,       10_000);

        terms.setEarlyRedemptionFee(feeBps);
        _setupHolder(alice, tokenAmt);

        uint256 principal = tokenAmt * FACE / 1e18;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 adminBefore = usdc.balanceOf(admin);

        token.redeemEarly(alice, address(usdc));

        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;
        uint256 adminGot = usdc.balanceOf(admin) - adminBefore;

        assertEq(aliceGot + adminGot, principal, "payout + penalty must equal principal");
        assertGe(adminGot, 0);
        assertLe(aliceGot, principal);
    }
}

// ── Minimal mock ERC-20 ───────────────────────────────────────────────────────

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
