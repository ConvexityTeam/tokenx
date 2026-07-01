// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/BusinessWallet.sol";

// ── Test helpers ──────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Refuses any ETH transfer — used to force pool-forward failures.
contract RejectETH {
    receive() external payable {
        revert("reject");
    }
}

/// @dev Calls sweepETH() on the victim during its receive(), triggering reentrancy.
contract EthReentrancyAttacker {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable _victim) {
        victim = BusinessWallet(_victim);
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            victim.sweepETH(); // re-enters; should revert
        }
    }
}

/// @dev Calls notify() on the victim during its transfer(), triggering reentrancy on notify.
contract ReentrancyToken is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable _victim) ERC20("Reentrant", "RENT") {
        victim = BusinessWallet(_victim);
    }

    function arm() external {
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            victim.notify(address(this)); // re-enters notify
        }
        return super.transfer(to, amount);
    }
}

/// @dev Exposes internal _msgSender / _msgData for coverage of the EIP-2771 branches.
contract BWHarness is BusinessWallet {
    function exposedMsgSender() external view returns (address) {
        return _msgSender();
    }

    function exposedMsgData() external view returns (bytes calldata) {
        return _msgData();
    }
}

// ── Main test contract ────────────────────────────────────────────────────────

contract BusinessWalletTest is Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");
    address user  = makeAddr("user");

    bytes32 constant BID = keccak256("business-1");

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _makeWallet(
        bytes32 bid,
        address _admin,
        address _pool,
        address fwd,
        address factorySweeper
    ) internal returns (BusinessWallet) {
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (bid, _admin, _pool, fwd, factorySweeper)
        );
        return BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
    }

    function setUp() public {
        beacon = new UpgradeableBeacon(address(new BusinessWallet()));
        wallet = _makeWallet(BID, admin, pool, address(0), address(0));
    }

    // ── initialize ────────────────────────────────────────────────────────────

    function test_initialize_setsState() public {
        assertEq(wallet.businessId(), BID);
        assertEq(wallet.poolWallet(), pool);
        assertEq(wallet.trustedForwarder(), address(0));
    }

    function test_initialize_grantsRolesToAdmin() public {
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(wallet.hasRole(wallet.WALLET_ADMIN_ROLE(), admin));
        assertTrue(wallet.hasRole(wallet.SWEEPER_ROLE(), admin));
        assertTrue(wallet.hasRole(wallet.EXECUTOR_ROLE(), admin));
        assertTrue(wallet.hasRole(wallet.PAUSER_ROLE(), admin));
    }

    function test_initialize_withFactorySweeper_grantsSweeper() public {
        address factorySweeper = makeAddr("factorySweeper");
        BusinessWallet w = _makeWallet(BID, admin, pool, address(0), factorySweeper);
        assertTrue(w.hasRole(w.SWEEPER_ROLE(), factorySweeper));
    }

    function test_initialize_withoutFactorySweeper_noExtraSweeper() public {
        // zero factorySweeper → only admin has SWEEPER_ROLE
        assertFalse(wallet.hasRole(wallet.SWEEPER_ROLE(), address(0)));
    }

    function test_initialize_revert_emptyBusinessId() public {
        vm.expectRevert("BW: empty businessId");
        _makeWallet(bytes32(0), admin, pool, address(0), address(0));
    }

    function test_initialize_revert_zeroAdmin() public {
        vm.expectRevert("BW: zero admin");
        _makeWallet(BID, address(0), pool, address(0), address(0));
    }

    function test_initialize_revert_zeroPool() public {
        vm.expectRevert("BW: zero pool");
        _makeWallet(BID, admin, address(0), address(0), address(0));
    }

    function test_initialize_revert_doubleInit() public {
        vm.expectRevert();
        wallet.initialize(BID, admin, pool, address(0), address(0));
    }

    // ── receive ───────────────────────────────────────────────────────────────

    function test_receive_forwardsETHToPool() public {
        uint256 before = pool.balance;
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(pool.balance - before, 1 ether);
    }

    function test_receive_emitsETHForwarded() public {
        vm.deal(user, 1 ether);
        vm.expectEmit(true, true, false, true);
        emit BusinessWallet.ETHForwarded(user, 1 ether, pool);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_receive_whenPaused_holdsETH() public {
        vm.prank(admin);
        wallet.pause();

        vm.deal(user, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit BusinessWallet.ETHReceived(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 1 ether);
    }

    function test_receive_whenPoolReverts_holdsETH() public {
        RejectETH rejector = new RejectETH();
        vm.prank(admin);
        wallet.setPoolWallet(address(rejector));

        vm.deal(user, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit BusinessWallet.ETHReceived(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 1 ether);
    }

    // ── fallback ──────────────────────────────────────────────────────────────

    function test_fallback_withValue_forwardsETH() public {
        uint256 before = pool.balance;
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}(hex"deadbeef");
        assertTrue(ok);
        assertEq(pool.balance - before, 1 ether);
    }

    function test_fallback_withoutValue_noOp() public {
        uint256 before = pool.balance;
        vm.prank(user);
        (bool ok,) = address(wallet).call(hex"deadbeef");
        assertTrue(ok);
        assertEq(pool.balance, before);
        assertEq(address(wallet).balance, 0);
    }

    // ── sweepETH ──────────────────────────────────────────────────────────────

    function _fundWalletWhilePaused(uint256 amount) internal {
        vm.prank(admin);
        wallet.pause();
        vm.deal(user, amount);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: amount}("");
        assertTrue(ok);
        vm.prank(admin);
        wallet.unpause();
    }

    function test_sweepETH_success() public {
        _fundWalletWhilePaused(2 ether);
        uint256 before = pool.balance;
        vm.prank(admin);
        wallet.sweepETH();
        assertEq(pool.balance - before, 2 ether);
        assertEq(address(wallet).balance, 0);
    }

    function test_sweepETH_emitsETHForwarded() public {
        _fundWalletWhilePaused(1 ether);
        vm.expectEmit(true, true, false, true);
        emit BusinessWallet.ETHForwarded(admin, 1 ether, pool);
        vm.prank(admin);
        wallet.sweepETH();
    }

    function test_sweepETH_revert_noBalance() public {
        vm.prank(admin);
        vm.expectRevert("BW: no ETH balance");
        wallet.sweepETH();
    }

    function test_sweepETH_revert_notSweeper() public {
        vm.deal(address(wallet), 1 ether);
        vm.prank(user);
        vm.expectRevert();
        wallet.sweepETH();
    }

    function test_sweepETH_revert_whenPaused() public {
        vm.deal(address(wallet), 1 ether);
        vm.prank(admin);
        wallet.pause();
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.sweepETH();
    }

    function test_sweepETH_revert_transferFailed() public {
        // Pool rejects ETH — sweepETH should fail
        RejectETH rejector = new RejectETH();
        vm.prank(admin);
        wallet.setPoolWallet(address(rejector));
        _fundWalletWhilePaused(1 ether);

        vm.prank(admin);
        vm.expectRevert("BW: ETH transfer failed");
        wallet.sweepETH();
    }

    // ── notify ────────────────────────────────────────────────────────────────

    function test_notify_sweepsToken() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 1000e18);

        wallet.notify(address(token));

        assertEq(token.balanceOf(pool), 1000e18);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function test_notify_emitsTokenSwept() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 500e18);

        vm.expectEmit(true, false, true, true);
        emit BusinessWallet.TokenSwept(address(token), 500e18, pool);
        wallet.notify(address(token));
    }

    function test_notify_noop_whenPaused() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 1000e18);

        vm.prank(admin);
        wallet.pause();

        wallet.notify(address(token)); // must not revert
        assertEq(token.balanceOf(address(wallet)), 1000e18);
    }

    function test_notify_noop_zeroBalance() public {
        MockERC20 token = new MockERC20();
        wallet.notify(address(token)); // no-op; must not revert
        assertEq(token.balanceOf(pool), 0);
    }

    function test_notify_revert_reentrancy() public {
        ReentrancyToken token = new ReentrancyToken(payable(address(wallet)));
        token.mint(address(wallet), 100e18);
        token.arm();

        vm.expectRevert("BW: reentrant");
        wallet.notify(address(token));
    }

    // ── sweepToken ────────────────────────────────────────────────────────────

    function test_sweepToken_success() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 100e18);

        vm.prank(admin);
        wallet.sweepToken(address(token));

        assertEq(token.balanceOf(pool), 100e18);
    }

    function test_sweepToken_noop_zeroBalance() public {
        MockERC20 token = new MockERC20();
        vm.prank(admin);
        wallet.sweepToken(address(token)); // must not revert
        assertEq(token.balanceOf(pool), 0);
    }

    function test_sweepToken_revert_notSweeper() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 100e18);

        vm.prank(user);
        vm.expectRevert();
        wallet.sweepToken(address(token));
    }

    function test_sweepToken_revert_whenPaused() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 100e18);

        vm.prank(admin);
        wallet.pause();

        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.sweepToken(address(token));
    }

    // ── batchSweepTokens ──────────────────────────────────────────────────────

    function test_batchSweepTokens_success() public {
        MockERC20 t1 = new MockERC20();
        MockERC20 t2 = new MockERC20();
        t1.mint(address(wallet), 100e18);
        t2.mint(address(wallet), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(t1);
        tokens[1] = address(t2);

        vm.prank(admin);
        wallet.batchSweepTokens(tokens);

        assertEq(t1.balanceOf(pool), 100e18);
        assertEq(t2.balanceOf(pool), 200e18);
    }

    function test_batchSweepTokens_skipsZeroBalance() public {
        MockERC20 t1 = new MockERC20();
        MockERC20 t2 = new MockERC20();
        t2.mint(address(wallet), 200e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(t1);
        tokens[1] = address(t2);

        vm.prank(admin);
        wallet.batchSweepTokens(tokens);

        assertEq(t1.balanceOf(pool), 0);
        assertEq(t2.balanceOf(pool), 200e18);
    }

    function test_batchSweepTokens_emptyArray_noOp() public {
        address[] memory tokens = new address[](0);
        vm.prank(admin);
        wallet.batchSweepTokens(tokens);
    }

    function test_batchSweepTokens_revert_notSweeper() public {
        address[] memory tokens = new address[](0);
        vm.prank(user);
        vm.expectRevert();
        wallet.batchSweepTokens(tokens);
    }

    function test_batchSweepTokens_revert_whenPaused() public {
        address[] memory tokens = new address[](0);
        vm.prank(admin);
        wallet.pause();

        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.batchSweepTokens(tokens);
    }

    // ── execute ───────────────────────────────────────────────────────────────

    function test_execute_erc20Transfer() public {
        MockERC20 token = new MockERC20();
        token.mint(address(wallet), 50e18);
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", user, 50e18);

        vm.prank(admin);
        bytes memory result = wallet.execute(address(token), 0, data);

        assertTrue(abi.decode(result, (bool)));
        assertEq(token.balanceOf(user), 50e18);
    }

    function test_execute_withETHValue() public {
        vm.deal(address(wallet), 1 ether);
        uint256 before = pool.balance;

        vm.prank(admin);
        wallet.execute(pool, 1 ether, "");

        assertEq(pool.balance - before, 1 ether);
        assertEq(address(wallet).balance, 0);
    }

    function test_execute_emitsExecuted() public {
        MockERC20 token = new MockERC20();
        bytes memory data = abi.encodeWithSignature("totalSupply()");

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit BusinessWallet.Executed(address(token), 0, data, "");
        wallet.execute(address(token), 0, data);
    }

    function test_execute_revert_notExecutor() public {
        vm.prank(user);
        vm.expectRevert();
        wallet.execute(pool, 0, "");
    }

    function test_execute_revert_whenPaused() public {
        vm.prank(admin);
        wallet.pause();

        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.execute(pool, 0, "");
    }

    function test_execute_revert_zeroTarget() public {
        vm.prank(admin);
        vm.expectRevert("BW: zero target");
        wallet.execute(address(0), 0, "");
    }

    function test_execute_revert_selfCall() public {
        vm.prank(admin);
        vm.expectRevert("BW: no self-call");
        wallet.execute(address(wallet), 0, "");
    }

    function test_execute_revert_callFailed() public {
        RejectETH rejector = new RejectETH();
        vm.deal(address(wallet), 1 ether);

        vm.prank(admin);
        vm.expectRevert("BW: execution failed");
        wallet.execute(address(rejector), 1 ether, "");
    }

    // ── setPoolWallet ─────────────────────────────────────────────────────────

    function test_setPoolWallet_updatesPool() public {
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        assertEq(wallet.poolWallet(), newPool);
    }

    function test_setPoolWallet_emitsEvent() public {
        address newPool = makeAddr("newPool");
        vm.expectEmit(true, true, false, false);
        emit BusinessWallet.PoolWalletUpdated(pool, newPool);
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
    }

    function test_setPoolWallet_revert_notAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        wallet.setPoolWallet(makeAddr("newPool"));
    }

    function test_setPoolWallet_revert_zeroPool() public {
        vm.prank(admin);
        vm.expectRevert("BW: zero pool");
        wallet.setPoolWallet(address(0));
    }

    // ── pause / unpause ───────────────────────────────────────────────────────

    function test_pause_setsState() public {
        assertFalse(wallet.paused());
        vm.prank(admin);
        wallet.pause();
        assertTrue(wallet.paused());
    }

    function test_unpause_clearsState() public {
        vm.prank(admin);
        wallet.pause();
        vm.prank(admin);
        wallet.unpause();
        assertFalse(wallet.paused());
    }

    function test_pause_revert_notPauser() public {
        vm.prank(user);
        vm.expectRevert();
        wallet.pause();
    }

    function test_unpause_revert_notPauser() public {
        vm.prank(admin);
        wallet.pause();
        vm.prank(user);
        vm.expectRevert();
        wallet.unpause();
    }

    // ── isTrustedForwarder ────────────────────────────────────────────────────

    function test_isTrustedForwarder_falseWhenNotSet() public {
        // trustedForwarder == address(0), so a non-zero address must return false
        assertFalse(wallet.isTrustedForwarder(user));
        // address(0) matches address(0) — that's expected contract behaviour
        assertTrue(wallet.isTrustedForwarder(address(0)));
    }

    function test_isTrustedForwarder_trueWhenSet() public {
        address fwd = makeAddr("forwarder");
        BusinessWallet w = _makeWallet(BID, admin, pool, fwd, address(0));
        assertTrue(w.isTrustedForwarder(fwd));
        assertFalse(w.isTrustedForwarder(user));
    }

    // ── EIP-2771 _msgSender / _msgData ────────────────────────────────────────

    function test_msgSender_nonForwarder_returnsMsgSender() public {
        BWHarness impl2 = new BWHarness();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl2));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        BWHarness harness = BWHarness(payable(address(new BeaconProxy(address(b), init))));

        vm.prank(user);
        assertEq(harness.exposedMsgSender(), user);
    }

    function test_msgSender_viaForwarder_extractsAppendedSender() public {
        address fwd = makeAddr("forwarder");
        BWHarness impl2 = new BWHarness();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl2));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, fwd, address(0))
        );
        BWHarness harness = BWHarness(payable(address(new BeaconProxy(address(b), init))));

        // EIP-2771: forwarder appends real sender as last 20 bytes
        bytes memory call_ = abi.encodeCall(BWHarness.exposedMsgSender, ());
        bytes memory metaTx = bytes.concat(call_, bytes20(admin));

        vm.prank(fwd);
        (bool ok, bytes memory ret) = address(harness).call(metaTx);
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), admin);
    }

    function test_msgData_nonForwarder_returnsFullCalldata() public {
        BWHarness impl2 = new BWHarness();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl2));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        BWHarness harness = BWHarness(payable(address(new BeaconProxy(address(b), init))));

        vm.prank(user);
        bytes memory data = harness.exposedMsgData();
        // Should equal the selector for exposedMsgData() — no stripping
        assertEq(bytes4(data), BWHarness.exposedMsgData.selector);
    }

    function test_msgData_viaForwarder_stripsLast20Bytes() public {
        address fwd = makeAddr("forwarder");
        BWHarness impl2 = new BWHarness();
        UpgradeableBeacon b = new UpgradeableBeacon(address(impl2));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, fwd, address(0))
        );
        BWHarness harness = BWHarness(payable(address(new BeaconProxy(address(b), init))));

        bytes memory innerCall = abi.encodeCall(BWHarness.exposedMsgData, ());
        bytes memory metaTx   = bytes.concat(innerCall, bytes20(admin));

        vm.prank(fwd);
        (bool ok, bytes memory raw) = address(harness).call(metaTx);
        assertTrue(ok);
        // ABI decode the return: abi.decode(raw, (bytes)) gives the returned calldata slice
        bytes memory returnedData = abi.decode(raw, (bytes));
        assertEq(returnedData.length, innerCall.length);
        assertEq(bytes4(returnedData), BWHarness.exposedMsgData.selector);
    }

    // ── EIP-2771 meta-tx for role-gated function ──────────────────────────────

    function test_eip2771_metaTx_setPoolWallet() public {
        address fwd = makeAddr("forwarder");
        BusinessWallet w = _makeWallet(BID, admin, pool, fwd, address(0));

        address newPool = makeAddr("newPool");
        bytes memory innerCall = abi.encodeCall(BusinessWallet.setPoolWallet, (newPool));
        bytes memory metaTx    = bytes.concat(innerCall, bytes20(admin));

        vm.prank(fwd);
        (bool ok,) = address(w).call(metaTx);
        assertTrue(ok);
        assertEq(w.poolWallet(), newPool);
    }

    // ── Role constants ────────────────────────────────────────────────────────

    function test_roleConstants() public {
        assertEq(wallet.WALLET_ADMIN_ROLE(), keccak256("WALLET_ADMIN_ROLE"));
        assertEq(wallet.SWEEPER_ROLE(),      keccak256("SWEEPER_ROLE"));
        assertEq(wallet.EXECUTOR_ROLE(),     keccak256("EXECUTOR_ROLE"));
        assertEq(wallet.PAUSER_ROLE(),       keccak256("PAUSER_ROLE"));
    }

    // ── Reentrancy guard (sweepETH via pool callback) ─────────────────────────

    function test_sweepETH_revert_reentrancy() public {
        EthReentrancyAttacker attacker =
            new EthReentrancyAttacker(payable(address(wallet)));

        // Cache role constant before prank — calling wallet.SWEEPER_ROLE() after
        // vm.prank would consume the prank on the view call, leaving grantRole
        // executed from the test contract address (which lacks DEFAULT_ADMIN_ROLE).
        bytes32 sweeperRole = wallet.SWEEPER_ROLE();
        vm.prank(admin);
        wallet.grantRole(sweeperRole, address(attacker));

        // Point pool to the attacker
        vm.prank(admin);
        wallet.setPoolWallet(address(attacker));
        attacker.arm();

        // Fund the wallet while paused
        _fundWalletWhilePaused(1 ether);

        // sweepETH → _forwardETH → attacker.receive → sweepETH → "BW: reentrant"
        // The inner revert makes ok=false in _forwardETH → "BW: ETH transfer failed"
        vm.prank(admin);
        vm.expectRevert("BW: ETH transfer failed");
        wallet.sweepETH();
    }
}
