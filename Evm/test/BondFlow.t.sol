// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

// Minimal ERC-20 used for coupon and principal payouts in tests.
contract MockUSDC {
    string public name   = "Mock USDC";
    string public symbol = "USDC";
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

/**
 * @title BondFlowTest
 * @notice End-to-end tests for the bond lifecycle:
 *           1. Factory deploys the suite + sealed BondTerms via deployBond.
 *           2. AGENT mints tokens to investors.
 *           3. createScheduledCoupon pays the contractually-required coupon
 *              (rate * face * period) and advances nextCouponDate.
 *           4. Investors claim or are pushed their pro-rata share.
 *           5. At maturity, redeemAtMaturity burns tokens and pays principal.
 *           6. flagDefault is permissionless after grace.
 */
contract BondFlowTest is BaseTest {
    receive() external payable {}

    TokenizationFactory factory;

    MockUSDC usdc;

    address admin      = address(this);
    address tokenAdmin = address(this);
    address alice      = address(0xA11CE);
    address bob        = address(0xB0B);
    address charlie    = address(0xC4A);
    address nobody     = address(0xDEAD);

    uint16 constant COUNTRY_NG = 566;

    uint256 ISSUE;
    uint256 MATURITY;
    uint256 FIRST_COUPON;
    uint256 constant COUPON_PERIOD = 90 days;
    uint256 constant RATE_BPS      = 500;          // 5.00%
    // `principal = balance * faceValuePerToken / 1e18`. balance is 18-dec ERC20,
    // so faceValuePerToken must be denominated in the payoutToken's decimals.
    // For USDC (6 decimals), $100 face → 100e6.
    uint256 constant FACE          = 100e6;

    // Deployed suite (populated in setUp)
    IdentityRegistry  registry;
    ComplianceModule  compliance;
    SecurityToken     token;
    YieldDistributor  distributor;
    BondTerms         terms;
    TokenizationFactory.ComplianceParams noLimits = TokenizationFactory.ComplianceParams({
        maxShareholders: 0,
        maxTokensPerInvestor: 0,
        lockUpDuration: 0
    });

    function setUp() public {
        vm.warp(1_700_000_000);
        ISSUE        = block.timestamp;
        MATURITY     = ISSUE + 5 * 365 days;
        FIRST_COUPON = ISSUE + COUPON_PERIOD;

        _deployBeacons();
        factory = _makeFactory(admin);
        usdc = new MockUSDC();

        _deployBond("BOND-001");
    }

    // ── Helpers ────────────────────────────────────────────────────

    function _bondParams() internal view returns (BondTerms.InitParams memory) {
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
            admin:                tokenAdmin
        });
    }

    function _deployBond(string memory issuerId) internal {
        (address t, address bt) = factory.deployBond(
            issuerId,
            "Acme Bond 5y",
            "ACMB5",
            address(0),
            tokenAdmin,
            noLimits,
            _bondParams()
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment(issuerId);
        token       = SecurityToken(payable(t));
        terms       = BondTerms(bt);
        registry    = IdentityRegistry(rec.identityRegistry);
        compliance  = ComplianceModule(rec.compliance);
        distributor = YieldDistributor(payable(rec.yieldDistributor));
    }

    function _registerThree() internal {
        registry.registerIdentity(alice,   address(0x1001), COUNTRY_NG);
        registry.registerIdentity(bob,     address(0x1002), COUNTRY_NG);
        registry.registerIdentity(charlie, address(0x1003), COUNTRY_NG);
    }

    function _mintAll(uint256 a, uint256 b, uint256 c) internal {
        if (a > 0) token.mint(alice,   a);
        if (b > 0) token.mint(bob,     b);
        if (c > 0) token.mint(charlie, c);
    }

    function _investorList() internal view returns (address[] memory) {
        address[] memory list = new address[](3);
        list[0] = alice;
        list[1] = bob;
        list[2] = charlie;
        return list;
    }

    // ── Factory: deployBond happy path ─────────────────────────────

    function test_deployBond_recordCorrect() public view {
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("BOND-001");
        assertEq(rec.token,            address(token));
        assertEq(rec.bondTerms,        address(terms));
        assertEq(rec.yieldDistributor, address(distributor));
        assertEq(rec.compliance,       address(compliance));
        assertEq(rec.identityRegistry, address(registry));
        assertEq(uint256(rec.tokenType), uint256(TokenizationFactory.TokenType.BOND));
    }

    function test_deployBond_wiresBondTermsIntoConsumers() public view {
        assertEq(address(token.bondTerms()),       address(terms));
        assertEq(address(distributor.bondTerms()), address(terms));
        assertEq(terms.securityToken(),            address(token));
        assertEq(terms.yieldDistributor(),         address(distributor));
    }

    function test_deployBond_termsSealed() public view {
        assertEq(terms.annualRateBps(),     RATE_BPS);
        assertEq(terms.maturityDate(),      MATURITY);
        assertEq(terms.faceValuePerToken(), FACE);
        assertEq(terms.nextCouponDate(),    FIRST_COUPON);
    }

    function test_deployBond_factoryRoleRenounced() public view {
        // Factory should have given up roles on all four contracts
        bytes32 ADMIN = token.DEFAULT_ADMIN_ROLE();
        assertFalse(token.hasRole(ADMIN, address(factory)));
        assertFalse(distributor.hasRole(ADMIN, address(factory)));
        assertFalse(compliance.hasRole(ADMIN, address(factory)));
        assertTrue(token.hasRole(ADMIN, tokenAdmin));
    }

    function testRevert_deployToken_bondTypeRejected() public {
        vm.expectRevert("Factory: use deployBond for BOND");
        factory.deployToken(
            TokenizationFactory.TokenType.BOND,
            "ROGUE-BOND", "X", "X", address(0), tokenAdmin, noLimits
        );
    }

    function testRevert_deployBond_invalidParams() public {
        BondTerms.InitParams memory bad = _bondParams();
        bad.maturityDate = bad.issueDate;
        vm.expectRevert("BT: maturity <= issue");
        factory.deployBond("BAD-BOND", "X", "X", address(0), tokenAdmin, noLimits, bad);
    }

    // ── setBondTerms guards ────────────────────────────────────────

    function testRevert_setBondTerms_alreadySet() public {
        vm.expectRevert("ST: bond terms already set");
        token.setBondTerms(address(terms));
    }

    function testRevert_setBondTerms_zeroAddress() public {
        // Deploy a standalone SecurityToken to verify the zero-check
        SecurityToken fresh = _makeST("F", "F", address(registry), address(compliance), admin);
        vm.expectRevert("ST: zero bond terms");
        fresh.setBondTerms(address(0));
    }

    // ── createScheduledCoupon: timing gates ────────────────────────

    function testRevert_createScheduledCoupon_beforeDue() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);
        vm.expectRevert("YD: coupon not due");
        distributor.createScheduledCoupon(_investorList(), address(usdc), 30 days, "C1");
    }

    function testRevert_createScheduledCoupon_noBondTerms() public {
        // Deploy a YIELD_BEARING (no bond) suite — should reject scheduled coupons
        address t = factory.deployToken(
            TokenizationFactory.TokenType.YIELD_BEARING,
            "YB-001", "Yieldy", "YB", address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("YB-001");
        YieldDistributor yd = YieldDistributor(payable(rec.yieldDistributor));
        IdentityRegistry  ir2 = IdentityRegistry(rec.identityRegistry);
        ir2.registerIdentity(alice, address(0x1001), COUNTRY_NG);
        SecurityToken(payable(t)).mint(alice, 100 ether);

        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectRevert("YD: no bond terms");
        yd.createScheduledCoupon(list, address(usdc), 30 days, "X");
    }

    // ── createScheduledCoupon: success path ────────────────────────

    function test_createScheduledCoupon_paysCorrectAmount_usdc() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);  // 1000 ether eligible
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        vm.warp(FIRST_COUPON);
        uint256 perToken     = terms.couponPerToken();
        uint256 totalCoupon  = perToken * 1000 ether / 1e18;

        uint256 distributorBalBefore = usdc.balanceOf(address(distributor));
        uint256 snapshotId = distributor.createScheduledCoupon(
            _investorList(), address(usdc), 30 days, "C1"
        );

        // Distributor received exactly the required amount
        assertEq(usdc.balanceOf(address(distributor)) - distributorBalBefore, totalCoupon);

        // Snapshot is recorded as scheduled
        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(snapshotId);
        assertTrue(snap.scheduled);
        assertEq(snap.totalFunds,          totalCoupon);
        assertEq(snap.totalEligibleSupply, 1000 ether);

        // nextCouponDate advanced
        assertEq(terms.nextCouponDate(), FIRST_COUPON + COUPON_PERIOD);
    }

    function test_createScheduledCoupon_ethPayout_requiresExactMsgValue() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);

        vm.warp(FIRST_COUPON);
        uint256 perToken    = terms.couponPerToken();
        uint256 totalCoupon = perToken * 1000 ether / 1e18;

        // Too little
        vm.deal(admin, totalCoupon * 2);
        vm.expectRevert("YD: wrong ETH amount");
        distributor.createScheduledCoupon{value: totalCoupon - 1}(
            _investorList(), address(0), 30 days, "C1"
        );

        // Too much
        vm.expectRevert("YD: wrong ETH amount");
        distributor.createScheduledCoupon{value: totalCoupon + 1}(
            _investorList(), address(0), 30 days, "C1"
        );

        // Exact
        distributor.createScheduledCoupon{value: totalCoupon}(
            _investorList(), address(0), 30 days, "C1"
        );
        assertEq(address(distributor).balance, totalCoupon);
    }

    function testRevert_createScheduledCoupon_ethSentForErc20() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        vm.warp(FIRST_COUPON);
        vm.deal(admin, 1 ether);
        vm.expectRevert("YD: ETH not allowed");
        distributor.createScheduledCoupon{value: 1}(_investorList(), address(usdc), 30 days, "C1");
    }

    function test_createScheduledCoupon_emitsScheduledEvent() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        vm.warp(FIRST_COUPON);
        uint256 perToken = terms.couponPerToken();
        // Constrain by emitter — the tx emits multiple events (USDC Transfer,
        // CouponAdvanced, SnapshotCreated, YieldDeposited, ScheduledCouponCreated)
        // so we have to filter on the distributor's address.
        vm.expectEmit(true, false, false, true, address(distributor));
        emit YieldDistributor.ScheduledCouponCreated(1, perToken, FIRST_COUPON);
        distributor.createScheduledCoupon(_investorList(), address(usdc), 30 days, "C1");
    }

    function testRevert_createScheduledCoupon_afterDefault() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        // Skip first coupon and flag default
        vm.warp(FIRST_COUPON + 8 days);
        distributor.flagDefault();

        // After default isCouponDue() returns false, so the first guard trips.
        // Either revert message is acceptable — both express "coupons stopped".
        vm.expectRevert("YD: coupon not due");
        distributor.createScheduledCoupon(_investorList(), address(usdc), 30 days, "C1");
    }

    // ── flagDefault ────────────────────────────────────────────────

    function test_flagDefault_permissionless() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);

        vm.warp(FIRST_COUPON + 8 days);
        vm.prank(nobody);
        distributor.flagDefault();
        assertTrue(terms.defaulted());
    }

    function test_flagDefault_emitsEvent() public {
        vm.warp(FIRST_COUPON + 8 days);
        uint256 ts = block.timestamp;
        vm.expectEmit(false, false, false, true);
        emit YieldDistributor.IssuerDefaulted(ts);
        distributor.flagDefault();
    }

    function testRevert_flagDefault_beforeGraceElapses() public {
        vm.warp(FIRST_COUPON + 1 days);
        vm.expectRevert("YD: grace not breached");
        distributor.flagDefault();
    }

    function testRevert_flagDefault_atFirstCoupon() public {
        vm.warp(FIRST_COUPON);
        vm.expectRevert("YD: grace not breached");
        distributor.flagDefault();
    }

    function testRevert_flagDefault_twice() public {
        vm.warp(FIRST_COUPON + 8 days);
        distributor.flagDefault();
        vm.expectRevert("YD: grace not breached");
        distributor.flagDefault();
    }

    function testRevert_flagDefault_noBondTerms() public {
        // Same drill: a non-bond yield distributor doesn't support flagDefault
        factory.deployToken(
            TokenizationFactory.TokenType.YIELD_BEARING,
            "YB-FD", "Y", "Y", address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("YB-FD");
        YieldDistributor yd = YieldDistributor(payable(rec.yieldDistributor));
        vm.expectRevert("YD: no bond terms");
        yd.flagDefault();
    }

    // ── Allowlist intersect with payouts ───────────────────────────

    function test_createScheduledCoupon_skipsNonAllowlistedInvestor() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        // Turn on wallet allowlist, only allow alice and charlie
        compliance.setWalletAllowed(alice,   true);
        compliance.setWalletAllowed(charlie, true);
        compliance.setWalletAllowlistEnabled(true);

        vm.warp(FIRST_COUPON);
        uint256 perToken    = terms.couponPerToken();
        // bob (300 ether) excluded → eligible supply = 700 ether
        uint256 expected    = perToken * 700 ether / 1e18;

        uint256 snapId = distributor.createScheduledCoupon(_investorList(), address(usdc), 30 days, "C1");
        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(snapId);
        assertEq(snap.totalEligibleSupply, 700 ether);
        assertEq(snap.totalFunds,          expected);
    }

    // ── Coupon claim flow ──────────────────────────────────────────

    function test_couponClaim_aliceGetsProRataShare() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether);  // 1000 ether eligible
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        vm.warp(FIRST_COUPON);
        uint256 snapId = distributor.createScheduledCoupon(_investorList(), address(usdc), 30 days, "C1");

        uint256 perToken    = terms.couponPerToken();
        uint256 totalCoupon = perToken * 1000 ether / 1e18;
        uint256 aliceShare  = totalCoupon * 500 ether / 1000 ether;

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        distributor.claimYield(snapId);
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, aliceShare);
    }

    // ── redeemAtMaturity ───────────────────────────────────────────

    function testRevert_redeemAtMaturity_notMatured() public {
        _registerThree();
        _mintAll(100 ether, 0, 0);
        vm.expectRevert("ST: not matured");
        token.redeemAtMaturity(alice, address(usdc));
    }

    function testRevert_redeemAtMaturity_zeroBalance() public {
        _registerThree();
        _mintAll(0, 100 ether, 0);
        vm.warp(MATURITY);
        vm.expectRevert("ST: zero balance");
        token.redeemAtMaturity(alice, address(usdc));
    }

    function testRevert_redeemAtMaturity_holderNotEligible() public {
        _registerThree();
        _mintAll(100 ether, 0, 0);

        // Enable wallet allowlist with alice not included
        compliance.setWalletAllowlistEnabled(true);

        vm.warp(MATURITY);
        vm.expectRevert("ST: holder not eligible");
        token.redeemAtMaturity(alice, address(usdc));
    }

    function testRevert_redeemAtMaturity_noBondTerms() public {
        // Use a non-bond suite that has no BondTerms wired
        factory.deployToken(
            TokenizationFactory.TokenType.YIELD_BEARING,
            "YB-NOBT", "Y", "Y", address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("YB-NOBT");
        SecurityToken    nonBondToken = SecurityToken(payable(rec.token));
        IdentityRegistry ir2          = IdentityRegistry(rec.identityRegistry);
        ir2.registerIdentity(alice, address(0x1001), COUNTRY_NG);
        nonBondToken.mint(alice, 10 ether);

        vm.expectRevert("ST: no bond terms");
        nonBondToken.redeemAtMaturity(alice, address(usdc));
    }

    function test_redeemAtMaturity_payoutCorrect_usdc() public {
        _registerThree();
        _mintAll(10 ether, 0, 0);
        usdc.mint(address(token), 100_000e6);

        vm.warp(MATURITY);
        uint256 expectedPrincipal = 10 ether * FACE / 1e18;  // 10 * 100 = 1000 (scaled to 1e18)
        uint256 aliceBalBefore    = usdc.balanceOf(alice);
        uint256 paid              = token.redeemAtMaturity(alice, address(usdc));

        assertEq(paid, expectedPrincipal);
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, expectedPrincipal);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_redeemAtMaturity_emitsPrincipalRedeemed() public {
        _registerThree();
        _mintAll(10 ether, 0, 0);
        usdc.mint(address(token), 100_000e6);

        vm.warp(MATURITY);
        uint256 expectedPrincipal = 10 ether * FACE / 1e18;
        // Tx also emits Transfer (burn) and USDC Transfer — filter on token.
        vm.expectEmit(true, false, false, true, address(token));
        emit SecurityToken.PrincipalRedeemed(alice, 10 ether, expectedPrincipal);
        token.redeemAtMaturity(alice, address(usdc));
    }

    function test_redeemAtMaturity_lastHolderSealsBond() public {
        _registerThree();
        _mintAll(10 ether, 0, 0);
        usdc.mint(address(token), 100_000e6);

        vm.warp(MATURITY);
        token.redeemAtMaturity(alice, address(usdc));
        // totalSupply == 0 → BondTerms.markPrincipalRepaid called
        assertEq(token.totalSupply(), 0);
        assertTrue(terms.principalRepaid());
    }

    function test_redeemAtMaturity_intermediateHolderDoesNotSealBond() public {
        _registerThree();
        _mintAll(10 ether, 5 ether, 0);
        usdc.mint(address(token), 100_000e6);

        vm.warp(MATURITY);
        token.redeemAtMaturity(alice, address(usdc));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(),    5 ether);  // bob still holds
        assertFalse(terms.principalRepaid());
    }

    // ── batchRedeemAtMaturity ──────────────────────────────────────

    function test_batchRedeemAtMaturity_allHolders_sealsBond() public {
        _registerThree();
        _mintAll(10 ether, 5 ether, 2 ether);
        usdc.mint(address(token), 100_000e6);

        vm.warp(MATURITY);
        token.batchRedeemAtMaturity(_investorList(), address(usdc));

        assertEq(token.balanceOf(alice),   0);
        assertEq(token.balanceOf(bob),     0);
        assertEq(token.balanceOf(charlie), 0);
        assertEq(token.totalSupply(),      0);
        assertTrue(terms.principalRepaid());

        assertEq(usdc.balanceOf(alice),   10 ether * FACE / 1e18);
        assertEq(usdc.balanceOf(bob),      5 ether * FACE / 1e18);
        assertEq(usdc.balanceOf(charlie),  2 ether * FACE / 1e18);
    }

    function test_batchRedeemAtMaturity_skipsIneligible() public {
        _registerThree();
        _mintAll(10 ether, 5 ether, 2 ether);
        usdc.mint(address(token), 100_000e6);

        // Allowlist alice + charlie only — bob skipped silently
        compliance.setWalletAllowed(alice,   true);
        compliance.setWalletAllowed(charlie, true);
        compliance.setWalletAllowlistEnabled(true);

        vm.warp(MATURITY);
        token.batchRedeemAtMaturity(_investorList(), address(usdc));

        assertEq(token.balanceOf(alice),   0);
        assertEq(token.balanceOf(bob),     5 ether);   // still holds, not redeemed
        assertEq(token.balanceOf(charlie), 0);
        // totalSupply > 0 because bob still holds → bond not sealed
        assertFalse(terms.principalRepaid());
    }

    function test_batchRedeemAtMaturity_skipsZeroBalance() public {
        _registerThree();
        _mintAll(10 ether, 0, 2 ether);  // bob has no tokens but is in the list
        usdc.mint(address(token), 100_000e6);

        vm.warp(MATURITY);
        token.batchRedeemAtMaturity(_investorList(), address(usdc));

        assertEq(token.totalSupply(),       0);
        assertTrue(terms.principalRepaid());
    }

    // ── Full happy-path lifecycle ──────────────────────────────────

    function test_endToEnd_oneCouponThenMaturity() public {
        _registerThree();
        _mintAll(10 ether, 5 ether, 2 ether);
        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        // 1. First scheduled coupon
        vm.warp(FIRST_COUPON);
        uint256 snapId = distributor.createScheduledCoupon(
            _investorList(), address(usdc), 30 days, "C1"
        );
        assertTrue(distributor.getSnapshot(snapId).scheduled);

        // 2. Investors claim
        vm.prank(alice);
        distributor.claimYield(snapId);
        vm.prank(bob);
        distributor.claimYield(snapId);
        vm.prank(charlie);
        distributor.claimYield(snapId);

        // 3. Warp to maturity and redeem principal in one batch
        usdc.mint(address(token), 100_000e6);
        vm.warp(MATURITY);
        token.batchRedeemAtMaturity(_investorList(), address(usdc));

        assertEq(token.totalSupply(),  0);
        assertTrue(terms.principalRepaid());
        // After principal repayment the bond is fully closed
        assertFalse(terms.isMatured());  // false because principalRepaid is now true
    }

    // ── Gap 1: secondary transfer mid-lifecycle ────────────────────
    //
    // Alice sells half her tokens to Dave before the coupon snapshot.
    // The snapshot must reflect the post-transfer balances so Dave
    // receives his pro-rata share and Alice's share shrinks accordingly.

    function test_endToEnd_secondaryTransferAffectsAllocation() public {
        address dave = address(0xDABE);
        registry.registerIdentity(alice,   address(0x1001), COUNTRY_NG);
        registry.registerIdentity(bob,     address(0x1002), COUNTRY_NG);
        registry.registerIdentity(dave,    address(0x1003), COUNTRY_NG);

        token.mint(alice, 600 ether);
        token.mint(bob,   400 ether);

        // Alice transfers 200 tokens to Dave on the secondary market
        vm.prank(alice);
        token.transfer(dave, 200 ether);

        // Balances at snapshot time: alice=400, bob=400, dave=200 → total=1000
        address[] memory investors = new address[](3);
        investors[0] = alice;
        investors[1] = bob;
        investors[2] = dave;

        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        vm.warp(FIRST_COUPON);
        uint256 snapId = distributor.createScheduledCoupon(investors, address(usdc), 30 days, "C1");

        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(snapId);
        assertEq(snap.totalEligibleSupply, 1000 ether);

        vm.prank(alice);   distributor.claimYield(snapId);
        vm.prank(bob);     distributor.claimYield(snapId);
        vm.prank(dave);    distributor.claimYield(snapId);

        // Alice and Bob hold equal balances → equal payouts
        assertEq(usdc.balanceOf(alice), usdc.balanceOf(bob));
        // Dave holds half of Alice's balance → half the payout
        assertApproxEqAbs(usdc.balanceOf(dave) * 2, usdc.balanceOf(alice), 1);
        // All funds distributed
        assertApproxEqAbs(
            usdc.balanceOf(alice) + usdc.balanceOf(bob) + usdc.balanceOf(dave),
            snap.totalFunds,
            2
        );

        // Full lifecycle continues to maturity
        usdc.mint(address(token), 100_000e6);
        vm.warp(MATURITY);
        token.batchRedeemAtMaturity(investors, address(usdc));

        assertEq(token.totalSupply(), 0);
        assertTrue(terms.principalRepaid());
    }

    // ── Gap 2: suspension after snapshot ──────────────────────────
    //
    // Investor is suspended (setVerified false) after the coupon
    // snapshot is taken.  The eligibility check runs at claim time,
    // so the suspended investor cannot claim until reinstated.

    function test_endToEnd_suspendedInvestorBlockedThenRestored() public {
        registry.registerIdentity(alice, address(0x1001), COUNTRY_NG);
        registry.registerIdentity(bob,   address(0x1002), COUNTRY_NG);

        token.mint(alice, 600 ether);
        token.mint(bob,   400 ether);

        usdc.mint(admin, 100_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        address[] memory investors = new address[](2);
        investors[0] = alice;
        investors[1] = bob;

        vm.warp(FIRST_COUPON);
        uint256 snapId = distributor.createScheduledCoupon(investors, address(usdc), 30 days, "C1");

        // Suspend Alice after snapshot — her balance was captured but eligibility
        // is re-evaluated at claim time
        registry.setVerified(alice, false);

        vm.prank(alice);
        vm.expectRevert("YD: not eligible");
        distributor.claimYield(snapId);

        // Bob is unaffected
        vm.prank(bob);
        distributor.claimYield(snapId);
        assertGt(usdc.balanceOf(bob), 0);

        // Reinstate Alice — she can now claim
        registry.setVerified(alice, true);
        vm.prank(alice);
        distributor.claimYield(snapId);
        assertGt(usdc.balanceOf(alice), 0);
    }

    // ── Gap 3: multi-coupon sequence ──────────────────────────────
    //
    // Run three consecutive coupons, verifying nextCouponDate
    // advances correctly after each and all investors claim each time.
    // Ends with a full batch redemption at maturity.

    function test_endToEnd_multiCouponSequence() public {
        _registerThree();
        _mintAll(500 ether, 300 ether, 200 ether); // total 1000 ether

        usdc.mint(admin, 1_000_000e6);
        usdc.approve(address(distributor), type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(FIRST_COUPON + i * COUPON_PERIOD);

            assertEq(terms.nextCouponDate(), FIRST_COUPON + i * COUPON_PERIOD);
            assertTrue(terms.isCouponDue());

            uint256 snapId = distributor.createScheduledCoupon(
                _investorList(), address(usdc), 30 days, string(abi.encodePacked("C", i + 1))
            );

            vm.prank(alice);   distributor.claimYield(snapId);
            vm.prank(bob);     distributor.claimYield(snapId);
            vm.prank(charlie); distributor.claimYield(snapId);

            // nextCouponDate must have advanced
            assertEq(terms.nextCouponDate(), FIRST_COUPON + (i + 1) * COUPON_PERIOD);
        }

        assertEq(distributor.snapshotCount(), 3);

        // Redeem principal at maturity
        usdc.mint(address(token), 1_000_000e6);
        vm.warp(MATURITY);
        token.batchRedeemAtMaturity(_investorList(), address(usdc));

        assertEq(token.totalSupply(), 0);
        assertTrue(terms.principalRepaid());
    }

    // ── Gap 4: native currency (ETH) end-to-end ───────────────────
    //
    // Deploy a bond with ETH-denominated face value (1 ETH per token).
    // Pay the coupon in ETH via msg.value, and redeem principal in ETH
    // by sending ETH directly to the SecurityToken contract.

    function test_endToEnd_nativeCurrencyPayout() public {
        // Deploy a fresh bond suite with ETH-denominated face value
        BondTerms.InitParams memory ethParams = _bondParams();
        ethParams.faceValuePerToken = 0.01 ether; // 0.01 ETH par value per token

        (address t, address bt) = factory.deployBond(
            "ETH-BOND-001", "ETH Bond 5y", "ETHB5",
            address(0), tokenAdmin, noLimits, ethParams
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("ETH-BOND-001");

        SecurityToken   ethToken = SecurityToken(payable(t));
        BondTerms       ethTerms = BondTerms(bt);
        YieldDistributor ethDist = YieldDistributor(payable(rec.yieldDistributor));
        IdentityRegistry ethReg  = IdentityRegistry(rec.identityRegistry);

        ethReg.registerIdentity(alice, address(0x1001), COUNTRY_NG);
        ethReg.registerIdentity(bob,   address(0x1002), COUNTRY_NG);

        ethToken.mint(alice, 10 ether);
        ethToken.mint(bob,   10 ether); // total 20 ether tokens

        address[] memory investors = new address[](2);
        investors[0] = alice;
        investors[1] = bob;

        // ── Coupon in ETH ─────────────────────────────────────────
        vm.warp(FIRST_COUPON);
        uint256 perToken    = ethTerms.couponPerToken();
        uint256 totalCoupon = perToken * 20 ether / 1e18;

        vm.deal(admin, totalCoupon * 2);
        uint256 aliceEthBefore = alice.balance;
        uint256 bobEthBefore   = bob.balance;

        ethDist.createScheduledCoupon{value: totalCoupon}(
            investors, address(0), 30 days, "C1-ETH"
        );

        vm.prank(alice); ethDist.claimYield(1);
        vm.prank(bob);   ethDist.claimYield(1);

        assertGt(alice.balance, aliceEthBefore);
        assertGt(bob.balance,   bobEthBefore);
        assertApproxEqAbs(alice.balance - aliceEthBefore, bob.balance - bobEthBefore, 1);

        // ── Principal in ETH at maturity ──────────────────────────
        uint256 totalPrincipal = 20 ether * ethParams.faceValuePerToken / 1e18;
        // Simulate issuer depositing principal into the token contract
        vm.deal(address(ethToken), totalPrincipal);

        vm.warp(MATURITY);
        aliceEthBefore = alice.balance;
        bobEthBefore   = bob.balance;

        ethToken.batchRedeemAtMaturity(investors, address(0));

        assertEq(ethToken.totalSupply(), 0);
        assertTrue(ethTerms.principalRepaid());
        assertGt(alice.balance, aliceEthBefore);
        assertGt(bob.balance,   bobEthBefore);
    }
}
