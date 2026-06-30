// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";
import "../src/TokenxForwarder.sol";

/**
 * @notice Forwarder integration tests — verifies that every EIP-2771-aware
 *         function correctly resolves _msgSender() through the forwarder so
 *         that role checks pass for a gas-less signer.
 *
 *   Covers:
 *     • SecurityToken  — burn, forcedTransfer, freeze, batchMint, batchBurn
 *     • IdentityRegistry — registerIdentity, setVerified, deleteIdentity,
 *                          updateCountry, updateIdentity
 *     • ComplianceModule — setMaxShareholders, setLockUpDuration, blockCountry,
 *                          setWalletAllowlistEnabled, setWalletAllowed
 *     • YieldDistributor — createSnapshot (ETH), pushYield
 *     • BondTerms        — setAnnualRate
 *
 *   Each test follows the same pattern:
 *     1. Signer holds the required role but has zero ETH.
 *     2. Relayer has ETH but no contract roles.
 *     3. Signer signs a ForwardRequest; relayer calls execute().
 *     4. Assert the on-chain state changed as if the signer called directly.
 */
// Minimal ERC-20 stablecoin used for the stablecoin createSnapshot test
contract MockERC20ForwarderTest {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint8   public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount; totalSupply += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

contract TokenxForwarderActionsTest is BaseTest {

    // ── Contracts ─────────────────────────────────────────────────
    TokenxForwarder      forwarder;
    IdentityRegistry     ir;
    ComplianceModule     cm;
    SecurityToken        token;
    YieldDistributor     yd;
    BondTerms            bt;
    MockERC20ForwarderTest usdc;

    // ── Wallets ───────────────────────────────────────────────────
    address relayer  = makeAddr("relayer");
    address investor = makeAddr("investor");
    address investor2 = makeAddr("investor2");

    address tokenAdmin;
    uint256 tokenAdminKey;

    // ── EIP-712 constants ─────────────────────────────────────────
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    // ─────────────────────────────────────────────────────────────
    function setUp() public {
        (tokenAdmin, tokenAdminKey) = makeAddrAndKey("tokenAdmin");

        forwarder = new TokenxForwarder(tokenAdmin);

        bytes32 relayerRole = forwarder.RELAYER_ROLE();
        vm.prank(tokenAdmin);
        forwarder.grantRole(relayerRole, relayer);

        _deployBeacons();

        ir    = _makeIR(tokenAdmin, address(forwarder));
        cm    = _makeCM(tokenAdmin, 0, 0, 0, address(forwarder));
        token = _makeST("Test", "TST", address(0), address(ir), address(cm), tokenAdmin, address(forwarder));
        yd    = _makeYD(address(token), tokenAdmin, address(forwarder));

        vm.startPrank(tokenAdmin);
        cm.bindToken(address(token));
        ir.registerIdentity(investor,  investor,  840);
        ir.registerIdentity(investor2, investor2, 840);
        vm.stopPrank();

        // Give the token admin some tokens to work with
        vm.prank(tokenAdmin);
        token.mint(investor, 1000e18);

        usdc = new MockERC20ForwarderTest();
    }

    // ─── Helpers ──────────────────────────────────────────────────

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

    function _execute(
        address from,
        uint256 fromKey,
        address to,
        bytes memory data
    ) internal returns (bool success, bytes memory ret) {
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _sign(from, fromKey, to, 0, data);
        vm.prank(relayer);
        (success, ret) = forwarder.execute(req, sig);
    }

    function _executeWithValue(
        address from,
        uint256 fromKey,
        address to,
        uint256 value,
        bytes memory data
    ) internal returns (bool success, bytes memory ret) {
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _sign(from, fromKey, to, value, data);
        vm.deal(relayer, value);
        vm.prank(relayer);
        (success, ret) = forwarder.execute{value: value}(req, sig);
    }

    // ═══════════════════════════════════════════════════════════════
    // SecurityToken — agent actions
    // ═══════════════════════════════════════════════════════════════

    function test_ST_burn_via_forwarder() public {
        assertEq(token.balanceOf(investor), 1000e18);

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(token),
            abi.encodeCall(SecurityToken.burn, (investor, 400e18))
        );
        assertTrue(ok, "burn inner call failed");
        assertEq(token.balanceOf(investor), 600e18);
    }

    function test_ST_forcedTransfer_via_forwarder() public {
        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(token),
            abi.encodeCall(SecurityToken.forcedTransfer, (investor, investor2, 300e18))
        );
        assertTrue(ok, "forcedTransfer inner call failed");
        assertEq(token.balanceOf(investor),  700e18);
        assertEq(token.balanceOf(investor2), 300e18);
    }

    function test_ST_freeze_via_forwarder() public {
        assertFalse(token.isFrozen(investor));

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(token),
            abi.encodeCall(SecurityToken.setAddressFrozen, (investor, true))
        );
        assertTrue(ok, "setAddressFrozen inner call failed");
        assertTrue(token.isFrozen(investor));
    }

    function test_ST_freezePartial_via_forwarder() public {
        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(token),
            abi.encodeCall(SecurityToken.freezePartialTokens, (investor, 200e18))
        );
        assertTrue(ok, "freezePartialTokens inner call failed");
        assertEq(token.getFrozenTokens(investor), 200e18);
    }

    function test_ST_batchMint_via_forwarder() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts    = new uint256[](2);
        recipients[0] = investor;
        recipients[1] = investor2;
        amounts[0]    = 50e18;
        amounts[1]    = 75e18;

        uint256 before1 = token.balanceOf(investor);
        uint256 before2 = token.balanceOf(investor2);

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(token),
            abi.encodeCall(SecurityToken.batchMint, (recipients, amounts))
        );
        assertTrue(ok, "batchMint inner call failed");
        assertEq(token.balanceOf(investor),  before1 + 50e18);
        assertEq(token.balanceOf(investor2), before2 + 75e18);
    }

    function test_ST_batchBurn_via_forwarder() public {
        // Give investor2 some tokens first
        vm.prank(tokenAdmin);
        token.mint(investor2, 200e18);

        address[] memory users   = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0]   = investor;
        users[1]   = investor2;
        amounts[0] = 100e18;
        amounts[1] = 50e18;

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(token),
            abi.encodeCall(SecurityToken.batchBurn, (users, amounts))
        );
        assertTrue(ok, "batchBurn inner call failed");
        assertEq(token.balanceOf(investor),  900e18);
        assertEq(token.balanceOf(investor2), 150e18);
    }

    // ═══════════════════════════════════════════════════════════════
    // IdentityRegistry — agent actions
    // ═══════════════════════════════════════════════════════════════

    function test_IR_registerIdentity_via_forwarder() public {
        address newInvestor = makeAddr("newInvestor");
        assertFalse(ir.isVerified(newInvestor));

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(ir),
            abi.encodeCall(IdentityRegistry.registerIdentity, (newInvestor, newInvestor, 566))
        );
        assertTrue(ok, "registerIdentity inner call failed");
        assertTrue(ir.isVerified(newInvestor));
        assertEq(ir.investorCountry(newInvestor), 566);
    }

    function test_IR_setVerified_false_via_forwarder() public {
        assertTrue(ir.isVerified(investor));

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(ir),
            abi.encodeCall(IdentityRegistry.setVerified, (investor, false))
        );
        assertTrue(ok, "setVerified inner call failed");
        assertFalse(ir.isVerified(investor));
    }

    function test_IR_setVerified_true_via_forwarder() public {
        // Suspend first via direct call
        vm.prank(tokenAdmin);
        ir.setVerified(investor, false);
        assertFalse(ir.isVerified(investor));

        // Reinstate via forwarder
        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(ir),
            abi.encodeCall(IdentityRegistry.setVerified, (investor, true))
        );
        assertTrue(ok, "setVerified true inner call failed");
        assertTrue(ir.isVerified(investor));
    }

    function test_IR_updateCountry_via_forwarder() public {
        assertEq(ir.investorCountry(investor), 840);

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(ir),
            abi.encodeCall(IdentityRegistry.updateCountry, (investor, 826))
        );
        assertTrue(ok, "updateCountry inner call failed");
        assertEq(ir.investorCountry(investor), 826);
    }

    function test_IR_updateIdentity_via_forwarder() public {
        address newID = makeAddr("newID");

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(ir),
            abi.encodeCall(IdentityRegistry.updateIdentity, (investor, newID))
        );
        assertTrue(ok, "updateIdentity inner call failed");
        assertEq(ir.identity(investor), newID);
    }

    function test_IR_deleteIdentity_via_forwarder() public {
        // Burn tokens first so compliance state is clean
        vm.prank(tokenAdmin);
        token.burn(investor, 1000e18);

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(ir),
            abi.encodeCall(IdentityRegistry.deleteIdentity, (investor))
        );
        assertTrue(ok, "deleteIdentity inner call failed");
        assertFalse(ir.isVerified(investor));
    }

    // ═══════════════════════════════════════════════════════════════
    // ComplianceModule — compliance admin actions
    // ═══════════════════════════════════════════════════════════════

    function test_CM_setMaxShareholders_via_forwarder() public {
        assertEq(cm.maxShareholders(), 0);

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(cm),
            abi.encodeCall(ComplianceModule.setMaxShareholders, (50))
        );
        assertTrue(ok, "setMaxShareholders inner call failed");
        assertEq(cm.maxShareholders(), 50);
    }

    function test_CM_setLockUpDuration_via_forwarder() public {
        uint256 oneYear = 365 days;

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(cm),
            abi.encodeCall(ComplianceModule.setLockUpDuration, (oneYear))
        );
        assertTrue(ok, "setLockUpDuration inner call failed");
        assertEq(cm.lockUpDuration(), oneYear);
    }

    function test_CM_blockCountry_via_forwarder() public {
        assertFalse(cm.blockedCountries(566));

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(cm),
            abi.encodeCall(ComplianceModule.blockCountry, (566))
        );
        assertTrue(ok, "blockCountry inner call failed");
        assertTrue(cm.blockedCountries(566));
    }

    function test_CM_setWalletAllowlistEnabled_via_forwarder() public {
        assertFalse(cm.walletAllowlistEnabled());

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(cm),
            abi.encodeCall(ComplianceModule.setWalletAllowlistEnabled, (true))
        );
        assertTrue(ok, "setWalletAllowlistEnabled inner call failed");
        assertTrue(cm.walletAllowlistEnabled());
    }

    function test_CM_setWalletAllowed_via_forwarder() public {
        assertFalse(cm.walletAllowlist(investor));

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(cm),
            abi.encodeCall(ComplianceModule.setWalletAllowed, (investor, true))
        );
        assertTrue(ok, "setWalletAllowed inner call failed");
        assertTrue(cm.walletAllowlist(investor));
    }

    // ═══════════════════════════════════════════════════════════════
    // YieldDistributor — agent actions
    // ═══════════════════════════════════════════════════════════════

    function test_YD_createSnapshot_ETH_via_forwarder() public {
        address[] memory investors = new address[](1);
        investors[0] = investor;

        uint256 fund = 1 ether;

        (bool ok,) = _executeWithValue(
            tokenAdmin, tokenAdminKey,
            address(yd),
            fund,
            abi.encodeCall(
                YieldDistributor.createSnapshot,
                (investors, address(0), fund, 7 days, "Q1 Dividend")
            )
        );
        assertTrue(ok, "createSnapshot inner call failed");
        assertEq(yd.snapshotCount(), 1);

        YieldDistributor.Snapshot memory snap = yd.getSnapshot(1);
        assertEq(snap.totalFunds, fund);
        assertTrue(snap.active);
    }

    // Exact flow Peter needs:
    //   agent has no ETH, holds USDC
    //   Step 1: agent signs USDC.approve(yieldDistributor, amount)  -> relayer submits
    //   Step 2: agent signs createSnapshot(investors, usdcAddress, amount, ...) -> relayer submits
    //   Step 3: investor claims yield
    function test_YD_createSnapshot_stablecoin_via_forwarder() public {
        // Fund the agent (tokenAdmin) with USDC — simulates issuer holding payout funds
        uint256 fund = 5_000e6; // $5,000 USDC
        usdc.mint(tokenAdmin, fund);

        address[] memory investors = new address[](1);
        investors[0] = investor;

        // Step 1: agent signs approve(yieldDistributor, fund) on the stablecoin
        //         msg.sender inside USDC will be the forwarder, but USDC.approve
        //         uses msg.sender directly — so we prank tokenAdmin to approve first,
        //         then show the createSnapshot goes through the forwarder.
        //
        //         Note: MockERC20 has no EIP-2771 support so approve must be direct.
        //         In production, if the stablecoin is a plain ERC-20, the agent
        //         calls approve directly with their own wallet (they DO have ETH for
        //         this one call, or use a permit signature).  Only the AGENT_ROLE
        //         contract calls need the forwarder.
        vm.prank(tokenAdmin);
        usdc.approve(address(yd), fund);

        // Step 2: agent (no ETH) signs createSnapshot -> relayer submits via forwarder
        //         _msgSender() resolves to tokenAdmin inside YieldDistributor,
        //         so safeTransferFrom pulls USDC from tokenAdmin correctly.
        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(yd),
            abi.encodeCall(
                YieldDistributor.createSnapshot,
                (investors, address(usdc), fund, 7 days, "Q1 Dividend")
            )
        );
        assertTrue(ok, "createSnapshot with stablecoin via forwarder failed");

        assertEq(yd.snapshotCount(), 1);
        YieldDistributor.Snapshot memory snap = yd.getSnapshot(1);
        assertEq(snap.totalFunds,  fund);
        assertEq(snap.payoutToken, address(usdc));
        assertTrue(snap.active);

        // Step 3: investor claims USDC — direct call, no forwarder needed
        uint256 before = usdc.balanceOf(investor);
        vm.prank(investor);
        yd.claimYield(1);
        assertEq(usdc.balanceOf(investor) - before, fund); // sole investor gets 100%
    }

    function test_YD_pushYield_via_forwarder() public {
        // Create snapshot directly as tokenAdmin (fund tokenAdmin with ETH first)
        address[] memory investors = new address[](1);
        investors[0] = investor;

        vm.deal(tokenAdmin, 1 ether);
        vm.prank(tokenAdmin);
        yd.createSnapshot{value: 1 ether}(investors, address(0), 1 ether, 7 days, "Q1");

        uint256 balBefore = investor.balance;

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(yd),
            abi.encodeCall(YieldDistributor.pushYield, (1, investors))
        );
        assertTrue(ok, "pushYield inner call failed");
        assertGt(investor.balance, balBefore);
    }

    // ═══════════════════════════════════════════════════════════════
    // BondTerms — bond admin action
    // ═══════════════════════════════════════════════════════════════

    function test_BT_setAnnualRate_via_forwarder() public {
        BondTerms.InitParams memory p = BondTerms.InitParams({
            annualRateBps:       500,
            couponPeriodSeconds: 90 days,
            dayCount:            BondTerms.DayCount.ACT_365,
            issueDate:           block.timestamp,
            maturityDate:        block.timestamp + 5 * 365 days,
            firstCouponDate:     block.timestamp + 90 days,
            faceValuePerToken:   100e18,
            gracePeriodSeconds:  7 days,
            callable:            false,
            callDate:            0,
            admin:               tokenAdmin
        });
        bt = _makeBT(p, address(forwarder));

        assertEq(bt.annualRateBps(), 500);

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(bt),
            abi.encodeCall(BondTerms.setAnnualRate, (750))
        );
        assertTrue(ok, "setAnnualRate inner call failed");
        assertEq(bt.annualRateBps(), 750);

        // Rate history must record the change
        assertEq(bt.getRateHistoryLength(), 2);
        (uint256 rateBps,) = bt.rateHistory(1);
        assertEq(rateBps, 750);
    }

    // ═══════════════════════════════════════════════════════════════
    // Role-boundary: wrong signer must be rejected
    // ═══════════════════════════════════════════════════════════════

    function test_unauthorized_signer_action_fails() public {
        // rogue has RELAYER_ROLE but not AGENT_ROLE on the token
        (, uint256 rogueKey) = makeAddrAndKey("rogue");
        address rogue = vm.addr(rogueKey);

        bytes32 relayerRole_ = forwarder.RELAYER_ROLE();
        vm.prank(tokenAdmin);
        forwarder.grantRole(relayerRole_, rogue);

        // Rogue tries to sign a mint — relayer submits it, inner call must revert
        (bool ok,) = _execute(
            rogue, rogueKey,
            address(token),
            abi.encodeCall(SecurityToken.mint, (investor, 1e18))
        );
        // forwarder.execute returns (false, revertData) — does not revert itself
        assertFalse(ok, "inner call should have reverted for missing AGENT_ROLE");
    }

    function test_wrong_contract_no_msgSender_override_rejected() public {
        // Target contract has no EIP-2771 support — appended address is harmless
        // but role check still uses raw msg.sender (the forwarder), which has no roles.
        // We verify the inner call fails gracefully.
        IdentityRegistry irNoFwd = _makeIR(tokenAdmin, address(0)); // no forwarder set

        (bool ok,) = _execute(
            tokenAdmin, tokenAdminKey,
            address(irNoFwd),
            abi.encodeCall(IdentityRegistry.registerIdentity, (makeAddr("x"), makeAddr("x"), 840))
        );
        // msg.sender inside irNoFwd will be the forwarder address, which has no AGENT_ROLE
        assertFalse(ok, "should fail when target does not recognise the forwarder");
    }
}
