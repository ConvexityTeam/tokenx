// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";
import "../src/TokenxForwarder.sol";

/**
 * @title BondFlowForwarderTest
 * @notice Gap 5: full bond lifecycle executed entirely via the EIP-2771 forwarder.
 *
 *   Roles:
 *     address(this) — platform admin, owns all contracts, used only for setUp
 *     agent         — holds AGENT_ROLE on token, registry, and distributor; has NO ETH
 *     alice / bob   — investors; have NO ETH
 *     relayer       — holds ETH and RELAYER_ROLE; submits every meta-tx
 *
 *   Lifecycle:
 *     1. Agent signs registerIdentity for alice and bob   → relayer submits
 *     2. Agent signs mint for alice and bob               → relayer submits
 *     3. Warp to first coupon; agent signs createScheduledCoupon → relayer submits
 *     4. Alice signs claimYield                           → relayer submits
 *     5. Agent signs pushYield for bob                    → relayer submits
 *     6. Warp to maturity; agent signs batchRedeemAtMaturity → relayer submits
 *     7. Assert bond is closed, investors received USDC principal
 */
contract BondFlowForwarderTest is BaseTest {
    receive() external payable {}

    // ── Contracts ─────────────────────────────────────────────────
    TokenxForwarder  forwarder;
    TokenizationFactory factory;

    IdentityRegistry registry;
    ComplianceModule compliance;
    SecurityToken    token;
    YieldDistributor distributor;
    BondTerms        terms;

    // ── Minimal ERC-20 payout token ───────────────────────────────
    MockUSDC usdc;

    // ── Wallets ───────────────────────────────────────────────────
    address agent;   uint256 agentKey;
    address alice;   uint256 aliceKey;
    address bob;     uint256 bobKey;
    address relayer;

    // ── Bond timing ───────────────────────────────────────────────
    uint256 ISSUE;
    uint256 MATURITY;
    uint256 FIRST_COUPON;
    uint256 constant COUPON_PERIOD = 90 days;
    uint256 constant RATE_BPS      = 500;
    uint256 constant FACE          = 100e6; // USDC 6-decimal

    // ── EIP-712 constants ─────────────────────────────────────────
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    // ─────────────────────────────────────────────────────────────
    function setUp() public {
        vm.warp(1_700_000_000);
        ISSUE        = block.timestamp;
        MATURITY     = ISSUE + 5 * 365 days;
        FIRST_COUPON = ISSUE + COUPON_PERIOD;

        (agent,   agentKey) = makeAddrAndKey("agent");
        (alice,   aliceKey) = makeAddrAndKey("alice");
        (bob,     bobKey)   = makeAddrAndKey("bob");
        relayer             = makeAddr("relayer");

        // ── Forwarder ─────────────────────────────────────────────
        forwarder = new TokenxForwarder(address(this));
        bytes32 relayerRole = forwarder.RELAYER_ROLE();
        forwarder.grantRole(relayerRole, relayer);
        vm.deal(relayer, 10 ether);

        // ── Factory + bond suite ──────────────────────────────────
        _deployBeacons();
        factory = _makeFactory(address(this), address(forwarder));
        usdc    = new MockUSDC();

        TokenizationFactory.ComplianceParams memory noLimits =
            TokenizationFactory.ComplianceParams({ maxShareholders: 0, maxTokensPerInvestor: 0, lockUpDuration: 0 });

        BondTerms.InitParams memory bondParams = BondTerms.InitParams({
            annualRateBps:        RATE_BPS,
            couponPeriodSeconds:  COUPON_PERIOD,
            dayCount:             BondTerms.DayCount.ACT_365,
            issueDate:            ISSUE,
            maturityDate:         MATURITY,
            firstCouponDate:      FIRST_COUPON,
            faceValuePerToken:    FACE,
            gracePeriodSeconds:   7 days,
            callable:                false,
            callDate:                0,
            admin:                   address(this),
            earlyRedemptionFeeBps:   0
        });

        (address t, address bt) = factory.deployBond(
            "FWD-BOND-001", "Forwarder Bond 5y", "FWDB5",
            address(0), address(this), noLimits, bondParams
        );

        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("FWD-BOND-001");
        token      = SecurityToken(payable(t));
        terms      = BondTerms(bt);
        registry   = IdentityRegistry(rec.identityRegistry);
        compliance = ComplianceModule(rec.compliance);
        distributor = YieldDistributor(payable(rec.yieldDistributor));

        // ── Grant AGENT_ROLE to agent on all three contracts ──────
        bytes32 AGENT = token.AGENT_ROLE();
        token.grantRole(AGENT,       agent);
        distributor.grantRole(AGENT, agent);
        registry.grantRole(AGENT,    agent);

        // ── Fund agent with USDC (issuer's operational wallet) ────
        // The agent's address is resolved as _msgSender() inside
        // createScheduledCoupon, so it must own and approve the USDC.
        usdc.mint(agent, 1_000_000e6);
        vm.prank(agent);
        usdc.approve(address(distributor), type(uint256).max);
    }

    // ── Signing helpers ───────────────────────────────────────────

    function _sign(
        address from,
        uint256 fromKey,
        address to,
        uint256 value,
        bytes memory data
    ) internal view returns (TokenxForwarder.ForwardRequest memory req, bytes memory sig) {
        req = TokenxForwarder.ForwardRequest({
            from:  from,
            to:    to,
            value: value,
            gas:   600_000,
            nonce: forwarder.getNonce(from),
            data:  data
        });

        bytes32 structHash = keccak256(abi.encode(
            REQUEST_TYPEHASH,
            req.from, req.to, req.value, req.gas, req.nonce,
            keccak256(req.data)
        ));
        bytes32 domainSep = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("TokenxForwarder"),
            keccak256("1"),
            block.chainid,
            address(forwarder)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _relay(
        address from, uint256 fromKey,
        address to,
        bytes memory data
    ) internal returns (bool success) {
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _sign(from, fromKey, to, 0, data);
        vm.prank(relayer);
        (success,) = forwarder.execute(req, sig);
    }

    // ── Full gasless lifecycle ────────────────────────────────────

    function test_endToEnd_gaslessAgentFullLifecycle() public {
        // ── Step 1: agent registers investors ────────────────────
        bool ok;

        ok = _relay(agent, agentKey, address(registry),
            abi.encodeCall(IdentityRegistry.registerIdentity, (alice, address(0x1001), 566)));
        assertTrue(ok, "registerIdentity alice failed");

        ok = _relay(agent, agentKey, address(registry),
            abi.encodeCall(IdentityRegistry.registerIdentity, (bob, address(0x1002), 566)));
        assertTrue(ok, "registerIdentity bob failed");

        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isVerified(bob));

        // ── Step 2: agent mints tokens ────────────────────────────
        ok = _relay(agent, agentKey, address(token),
            abi.encodeCall(SecurityToken.mint, (alice, 600 ether)));
        assertTrue(ok, "mint alice failed");

        ok = _relay(agent, agentKey, address(token),
            abi.encodeCall(SecurityToken.mint, (bob, 400 ether)));
        assertTrue(ok, "mint bob failed");

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob),   400 ether);
        assertEq(token.totalSupply(),    1000 ether);

        // ── Step 3: agent creates scheduled coupon ────────────────
        address[] memory investors = new address[](2);
        investors[0] = alice;
        investors[1] = bob;

        vm.warp(FIRST_COUPON);
        assertTrue(terms.isCouponDue());

        ok = _relay(agent, agentKey, address(distributor),
            abi.encodeCall(YieldDistributor.createScheduledCoupon,
                (investors, address(usdc), 30 days, "C1 gasless")));
        assertTrue(ok, "createScheduledCoupon failed");

        assertEq(distributor.snapshotCount(), 1);
        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(1);
        assertTrue(snap.scheduled);
        assertEq(snap.totalEligibleSupply, 1000 ether);

        uint256 perToken    = terms.couponPerToken();
        uint256 totalCoupon = perToken * 1000 ether / 1e18;
        assertEq(snap.totalFunds, totalCoupon);

        // nextCouponDate advanced
        assertEq(terms.nextCouponDate(), FIRST_COUPON + COUPON_PERIOD);

        // ── Step 4: alice self-claims via forwarder (no ETH) ──────
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        ok = _relay(alice, aliceKey, address(distributor),
            abi.encodeCall(YieldDistributor.claimYield, (1)));
        assertTrue(ok, "claimYield alice failed");

        uint256 aliceCoupon = totalCoupon * 600 ether / 1000 ether;
        assertApproxEqAbs(usdc.balanceOf(alice) - aliceUsdcBefore, aliceCoupon, 1);

        // ── Step 5: agent pushes yield to bob ─────────────────────
        address[] memory justBob = new address[](1);
        justBob[0] = bob;

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        ok = _relay(agent, agentKey, address(distributor),
            abi.encodeCall(YieldDistributor.pushYield, (1, justBob)));
        assertTrue(ok, "pushYield bob failed");

        uint256 bobCoupon = totalCoupon * 400 ether / 1000 ether;
        assertApproxEqAbs(usdc.balanceOf(bob) - bobUsdcBefore, bobCoupon, 1);

        // ── Step 6: warp to maturity; agent batch-redeems ─────────
        // Issuer deposits USDC principal directly into the token contract
        uint256 totalPrincipal = 1000 ether * FACE / 1e18;
        usdc.mint(address(token), totalPrincipal);

        vm.warp(MATURITY);
        assertTrue(terms.isMatured());

        uint256 aliceUsdcMid = usdc.balanceOf(alice);
        uint256 bobUsdcMid   = usdc.balanceOf(bob);

        ok = _relay(agent, agentKey, address(token),
            abi.encodeCall(SecurityToken.batchRedeemAtMaturity, (investors, address(usdc))));
        assertTrue(ok, "batchRedeemAtMaturity failed");

        // ── Step 7: assertions ────────────────────────────────────
        assertEq(token.totalSupply(), 0);
        assertTrue(terms.principalRepaid());
        assertFalse(terms.isMatured()); // closed because principalRepaid = true

        // Principal paid correctly
        uint256 alicePrincipal = 600 ether * FACE / 1e18;
        uint256 bobPrincipal   = 400 ether * FACE / 1e18;
        assertEq(usdc.balanceOf(alice) - aliceUsdcMid, alicePrincipal);
        assertEq(usdc.balanceOf(bob)   - bobUsdcMid,   bobPrincipal);

        // Neither agent nor relayer holds any unexpected USDC
        assertEq(usdc.balanceOf(relayer), 0);
    }

    // ── Role boundary: agent role is enforced even via forwarder ──

    function test_forwarder_agentRoleStillEnforced_gaslessInvestor() public {
        // Register alice directly (admin call)
        registry.registerIdentity(alice, address(0x1001), 566);
        token.mint(alice, 100 ether);

        // Alice tries to mint more tokens through the forwarder — she lacks AGENT_ROLE
        bool ok = _relay(alice, aliceKey, address(token),
            abi.encodeCall(SecurityToken.mint, (alice, 100 ether)));

        assertFalse(ok, "mint should fail without AGENT_ROLE");
        assertEq(token.balanceOf(alice), 100 ether); // unchanged
    }
}

// ── Minimal ERC-20 reused from BondFlow.t.sol ─────────────────────────────────

contract MockUSDC {
    string public name    = "Mock USDC";
    string public symbol  = "USDC";
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
