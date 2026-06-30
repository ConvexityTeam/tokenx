// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

// ── Minimal ERC-20 for ERC-20 payout tests ───────────────────────────────────

contract MockERC20 {
    string public name   = "Mock USD";
    string public symbol = "MUSD";
    uint8  public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to]  += amount;
        totalSupply    += amount;
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

// ─────────────────────────────────────────────────────────────────────────────

contract YieldDistributorTest is BaseTest {
    receive() external payable {}

    IdentityRegistry registry;
    ComplianceModule compliance;
    SecurityToken    token;
    YieldDistributor distributor;
    MockERC20        usdc;

    address admin   = address(this);
    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address charlie = address(0xC4A);
    address nobody  = address(0xDEAD);

    uint16 constant COUNTRY_NG = 566;
    uint16 constant COUNTRY_US = 840;

    function setUp() public {
        _deployBeacons();
        registry    = _makeIR(admin);
        compliance  = _makeCM(admin, 0, 0, 0);
        token       = _makeST("Share Token", "SHR", address(registry), address(compliance), admin);
        compliance.bindToken(address(token));
        distributor = _makeYD(address(token), admin);
        usdc        = new MockERC20();

        registry.registerIdentity(alice,   address(0x1001), COUNTRY_NG);
        registry.registerIdentity(bob,     address(0x1002), COUNTRY_US);
        registry.registerIdentity(charlie, address(0x1003), COUNTRY_NG);

        token.mint(alice,   500 ether);
        token.mint(bob,     300 ether);
        token.mint(charlie, 200 ether);

        usdc.mint(admin, 100_000e6);
        vm.deal(admin, 100 ether);
    }

    // ── initialize validation ─────────────────────────────────────

    function testRevert_initialize_zeroToken() public {
        vm.expectRevert("YD: zero token");
        _makeYD(address(0), admin);
    }

    function testRevert_initialize_zeroAdmin() public {
        vm.expectRevert("YD: zero admin");
        _makeYD(address(token), address(0));
    }

    // ── createSnapshot: ETH ───────────────────────────────────────

    function test_createSnapshot_ETH_success() public {
        address[] memory investors = _allInvestors();

        vm.expectEmit(true, false, false, false);
        emit YieldDistributor.SnapshotCreated(1, block.number, 1000 ether, "Q1 2025");

        uint256 id = distributor.createSnapshot{value: 1 ether}(
            investors, address(0), 0, 30 days, "Q1 2025"
        );

        assertEq(id, 1);
        assertEq(distributor.snapshotCount(), 1);

        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(1);
        assertTrue(snap.active);
        assertEq(snap.totalFunds, 1 ether);
        assertEq(snap.payoutToken, address(0));
        assertEq(snap.totalEligibleSupply, 1000 ether);
        assertEq(bytes(snap.description).length > 0, true);
    }

    function testRevert_createSnapshot_ETH_noEthSent() public {
        address[] memory investors = _allInvestors();
        vm.expectRevert("YD: no ETH sent");
        distributor.createSnapshot{value: 0}(investors, address(0), 0, 30 days, "test");
    }

    // ── createSnapshot: ERC-20 ────────────────────────────────────

    function test_createSnapshot_ERC20_success() public {
        usdc.approve(address(distributor), 1000e6);
        address[] memory investors = _allInvestors();

        uint256 id = distributor.createSnapshot(
            investors, address(usdc), 1000e6, 30 days, "Q2 2025"
        );

        assertEq(id, 1);
        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(1);
        assertEq(snap.totalFunds, 1000e6);
        assertEq(snap.payoutToken, address(usdc));
    }

    function testRevert_createSnapshot_ERC20_zeroFundAmount() public {
        address[] memory investors = _allInvestors();
        vm.expectRevert("YD: zero fund amount");
        distributor.createSnapshot(investors, address(usdc), 0, 30 days, "test");
    }

    function testRevert_createSnapshot_noEligibleHolders() public {
        registry.setVerified(alice, false);
        registry.setVerified(bob, false);
        registry.setVerified(charlie, false);

        address[] memory investors = _allInvestors();
        vm.expectRevert("YD: no eligible holders");
        distributor.createSnapshot{value: 1 ether}(investors, address(0), 0, 30 days, "test");
    }

    function testRevert_createSnapshot_allFrozen() public {
        token.setAddressFrozen(alice, true);
        token.setAddressFrozen(bob, true);
        token.setAddressFrozen(charlie, true);

        address[] memory investors = _allInvestors();
        vm.expectRevert("YD: no eligible holders");
        distributor.createSnapshot{value: 1 ether}(investors, address(0), 0, 30 days, "test");
    }

    function testRevert_createSnapshot_notAgent() public {
        address[] memory investors = _allInvestors();
        vm.deal(nobody, 5 ether);
        vm.prank(nobody);
        vm.expectRevert();
        distributor.createSnapshot{value: 1 ether}(investors, address(0), 0, 30 days, "test");
    }

    function testRevert_createSnapshot_paused() public {
        distributor.pause();
        address[] memory investors = _allInvestors();
        vm.expectRevert("Pausable: paused");
        distributor.createSnapshot{value: 1 ether}(investors, address(0), 0, 30 days, "test");
    }

    // ── claimYield: ETH ───────────────────────────────────────────

    function test_claimYield_ETH_success() public {
        _createETHSnapshot(1 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        distributor.claimYield(1);

        assertEq(alice.balance - aliceBefore, 0.5 ether);
        assertTrue(distributor.claimed(1, alice));
    }

    function test_claimYield_ERC20_success() public {
        usdc.approve(address(distributor), 1000e6);
        address[] memory investors = _allInvestors();
        distributor.createSnapshot(investors, address(usdc), 1000e6, 30 days, "Q1");

        vm.prank(alice);
        distributor.claimYield(1);

        assertEq(usdc.balanceOf(alice), 500e6);
    }

    function testRevert_claimYield_alreadyClaimed() public {
        _createETHSnapshot(1 ether);
        vm.prank(alice);
        distributor.claimYield(1);

        vm.prank(alice);
        vm.expectRevert("YD: already claimed");
        distributor.claimYield(1);
    }

    function testRevert_claimYield_notEligible() public {
        _createETHSnapshot(1 ether);
        registry.setVerified(alice, false);

        vm.prank(alice);
        vm.expectRevert("YD: not eligible");
        distributor.claimYield(1);
    }

    function testRevert_claimYield_noBalanceAtSnapshot() public {
        _createETHSnapshot(1 ether);
        registry.registerIdentity(nobody, address(0x9999), COUNTRY_NG);

        vm.prank(nobody);
        vm.expectRevert("YD: no balance at snapshot");
        distributor.claimYield(1);
    }

    function testRevert_claimYield_inactiveSnapshot() public {
        _createETHSnapshot(1 ether);
        vm.warp(block.timestamp + 30 days + 1);
        distributor.reclaimUnclaimed(1);

        vm.prank(alice);
        vm.expectRevert("YD: snapshot inactive");
        distributor.claimYield(1);
    }

    // ── pushYield ─────────────────────────────────────────────────

    function test_pushYield_success() public {
        _createETHSnapshot(1 ether);

        uint256 aliceBefore = alice.balance;
        address[] memory investors = _allInvestors();
        distributor.pushYield(1, investors);

        assertTrue(distributor.claimed(1, alice));
        assertTrue(distributor.claimed(1, bob));
        assertTrue(distributor.claimed(1, charlie));
        assertGt(alice.balance, aliceBefore);
    }

    function test_pushYield_skipsAlreadyClaimed() public {
        _createETHSnapshot(1 ether);

        vm.prank(alice);
        distributor.claimYield(1);

        address[] memory investors = _allInvestors();
        distributor.pushYield(1, investors);
        assertTrue(distributor.claimed(1, alice));
    }

    function test_pushYield_skipsNotEligible_emitsEvent() public {
        _createETHSnapshot(1 ether);
        registry.setVerified(alice, false);

        address[] memory investors = new address[](1);
        investors[0] = alice;

        vm.expectEmit(true, true, false, false);
        emit YieldDistributor.InvestorSkipped(1, alice, "not eligible at payout time");

        distributor.pushYield(1, investors);
        assertFalse(distributor.claimed(1, alice));
    }

    function testRevert_pushYield_notAgent() public {
        _createETHSnapshot(1 ether);
        address[] memory investors = _allInvestors();
        vm.prank(nobody);
        vm.expectRevert();
        distributor.pushYield(1, investors);
    }

    function testRevert_pushYield_inactiveSnapshot() public {
        _createETHSnapshot(1 ether);
        vm.warp(block.timestamp + 30 days + 1);
        distributor.reclaimUnclaimed(1);

        address[] memory investors = _allInvestors();
        vm.expectRevert("YD: snapshot inactive");
        distributor.pushYield(1, investors);
    }

    // ── reclaimUnclaimed ──────────────────────────────────────────

    function test_reclaimUnclaimed_success() public {
        _createETHSnapshot(1 ether);
        vm.warp(block.timestamp + 30 days + 1);

        uint256 before = admin.balance;
        distributor.reclaimUnclaimed(1);
        assertGt(admin.balance, before);
    }

    function testRevert_reclaimUnclaimed_deadlineNotReached() public {
        _createETHSnapshot(1 ether);
        vm.expectRevert("YD: deadline not reached");
        distributor.reclaimUnclaimed(1);
    }

    function testRevert_reclaimUnclaimed_alreadyReclaimed() public {
        _createETHSnapshot(1 ether);
        vm.warp(block.timestamp + 30 days + 1);
        distributor.reclaimUnclaimed(1);

        vm.expectRevert("YD: already reclaimed");
        distributor.reclaimUnclaimed(1);
    }

    function testRevert_reclaimUnclaimed_nothingToReclaim() public {
        _createETHSnapshot(1 ether);
        address[] memory investors = _allInvestors();
        distributor.pushYield(1, investors);

        vm.warp(block.timestamp + 30 days + 1);
        vm.expectRevert("YD: nothing to reclaim");
        distributor.reclaimUnclaimed(1);
    }

    // ── pendingYield ──────────────────────────────────────────────

    function test_pendingYield_correctAmount() public {
        _createETHSnapshot(1 ether);
        assertEq(distributor.pendingYield(1, alice), 0.5 ether);
    }

    function test_pendingYield_zeroIfClaimed() public {
        _createETHSnapshot(1 ether);
        vm.prank(alice);
        distributor.claimYield(1);
        assertEq(distributor.pendingYield(1, alice), 0);
    }

    function test_pendingYield_zeroIfNoBalance() public {
        _createETHSnapshot(1 ether);
        assertEq(distributor.pendingYield(1, nobody), 0);
    }

    // ── getSnapshot ───────────────────────────────────────────────

    function test_getSnapshot_returnsCorrectStruct() public {
        _createETHSnapshot(2 ether);
        YieldDistributor.Snapshot memory snap = distributor.getSnapshot(1);

        assertEq(snap.id, 1);
        assertEq(snap.totalFunds, 2 ether);
        assertEq(snap.payoutToken, address(0));
        assertTrue(snap.active);
        assertEq(snap.totalEligibleSupply, 1000 ether);
    }

    // ── pause / unpause ───────────────────────────────────────────

    function test_pause_success() public {
        distributor.pause();
        assertTrue(distributor.paused());
    }

    function test_unpause_success() public {
        distributor.pause();
        distributor.unpause();
        assertFalse(distributor.paused());
    }

    function testRevert_pause_nonPauser() public {
        vm.prank(nobody);
        vm.expectRevert();
        distributor.pause();
    }

    function testRevert_unpause_nonPauser() public {
        distributor.pause();
        vm.prank(nobody);
        vm.expectRevert();
        distributor.unpause();
    }

    // ── receive() ────────────────────────────────────────────────

    function test_receive_canReceiveETH() public {
        (bool ok,) = address(distributor).call{value: 1 ether}("");
        assertTrue(ok);
    }

    // ── Helpers ───────────────────────────────────────────────────

    function _allInvestors() internal view returns (address[] memory investors) {
        investors    = new address[](3);
        investors[0] = alice;
        investors[1] = bob;
        investors[2] = charlie;
    }

    function _createETHSnapshot(uint256 amount) internal returns (uint256) {
        address[] memory investors = _allInvestors();
        return distributor.createSnapshot{value: amount}(
            investors, address(0), 0, 30 days, "Test Snapshot"
        );
    }
}
