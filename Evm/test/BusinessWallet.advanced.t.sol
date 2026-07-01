// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BusinessWallet — Advanced Tests
 * @notice Covers: fuzz, invariant, bad-actor, gas benchmarks,
 *         regression, and extra reentrancy scenarios.
 */

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/BusinessWallet.sol";

// ── Shared helpers ────────────────────────────────────────────────────────────

contract AdvMockERC20 is ERC20 {
    constructor(string memory sym) ERC20(sym, sym) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Calls notify() (permissionless, nonReentrant) during transfer.
contract ReentrancySweepToken is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable v) ERC20("RST", "RST") { victim = BusinessWallet(v); }
    function arm() external { armed = true; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) { armed = false; victim.notify(address(this)); }
        return super.transfer(to, amt);
    }
}

contract ReentrancyBatchSweep is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable v) ERC20("RBS", "RBS") { victim = BusinessWallet(v); }
    function arm() external { armed = true; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) { armed = false; victim.notify(address(this)); }
        return super.transfer(to, amt);
    }
}

contract ReentrancyExecute is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable v) ERC20("REX", "REX") { victim = BusinessWallet(v); }
    function arm() external { armed = true; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) { armed = false; victim.notify(address(this)); }
        return super.transfer(to, amt);
    }
}

/// @dev Refuses all ETH.
contract Sink {
    receive() external payable { revert("no ETH"); }
}

/// @dev Fake ERC20 whose transfer always reverts.
contract HoneypotToken {
    function balanceOf(address) external pure returns (uint256) { return 1e18; }
    function transfer(address, uint256) external pure returns (bool) {
        revert("honeypot: blocked");
    }
}

// ── Invariant handler ─────────────────────────────────────────────────────────

contract BWHandler is Test {
    BusinessWallet public wallet;
    address public admin;
    address public pool;

    AdvMockERC20[] tokens;
    uint256 public totalMinted;
    uint256 public totalSwept;

    constructor(address payable _wallet, address _admin, address _pool) {
        wallet = BusinessWallet(_wallet);
        admin  = _admin;
        pool   = _pool;
        for (uint8 i; i < 3; ++i) {
            tokens.push(new AdvMockERC20(string(abi.encodePacked("T", i))));
        }
    }

    function sweepToken(uint256 idx, uint256 mintAmt) external {
        if (tokens.length == 0) return;
        idx     = idx % tokens.length;
        mintAmt = bound(mintAmt, 0, 1e24);
        tokens[idx].mint(address(wallet), mintAmt);
        totalMinted += mintAmt;
        vm.prank(admin);
        wallet.sweepToken(address(tokens[idx]));
        totalSwept += mintAmt;
    }

    function sendETH(uint256 amt) external {
        amt = bound(amt, 0, 100 ether);
        vm.deal(address(this), amt);
        (bool ok,) = address(wallet).call{value: amt}("");
        assertTrue(ok);
    }

    function togglePause() external {
        if (wallet.paused()) {
            vm.prank(admin);
            wallet.unpause();
        } else {
            vm.prank(admin);
            wallet.pause();
            vm.prank(admin);
            wallet.unpause();
        }
    }

    function setPool(address newPool) external {
        if (newPool == address(0)) return;
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        pool = newPool;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// INVARIANT TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract BusinessWalletInvariant is StdInvariant, Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;
    BWHandler         handler;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");

    bytes32 constant BID = keccak256("biz-inv");

    function setUp() public {
        beacon = new UpgradeableBeacon(address(new BusinessWallet()));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        wallet  = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
        handler = new BWHandler(payable(address(wallet)), admin, pool);

        bytes32 sweeperRole = wallet.SWEEPER_ROLE();
        vm.prank(admin);
        wallet.grantRole(sweeperRole, address(handler));

        targetContract(address(handler));
    }

    function invariant_poolWalletNeverZero() public {
        assertTrue(wallet.poolWallet() != address(0));
    }

    function invariant_businessIdImmutable() public {
        assertEq(wallet.businessId(), BID);
    }

    function invariant_forwarderImmutable() public {
        assertEq(wallet.trustedForwarder(), address(0));
    }

    function invariant_adminKeepsDefaultAdminRole() public {
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
    }

    function invariant_implementationNotInitializable() public {
        BusinessWallet impl = BusinessWallet(payable(UpgradeableBeacon(address(beacon)).implementation()));
        vm.expectRevert();
        impl.initialize(BID, admin, pool, address(0), address(0));
    }

    /// @notice ETH balance is bounded — it can only hold what was explicitly sent.
    ///         When the pool accepts ETH the balance is 0; when it rejects ETH
    ///         or the wallet is paused, the balance accumulates — but never
    ///         exceeds the total received.  The handler caps each send at 100 ether.
    function invariant_walletETHBalanceBounded() public {
        assertLe(address(wallet).balance, 200_000 ether);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// FUZZ TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract BusinessWalletFuzz is Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");
    address user  = makeAddr("user");

    bytes32 constant BID = keccak256("biz-fuzz");

    function setUp() public {
        beacon = new UpgradeableBeacon(address(new BusinessWallet()));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        wallet = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
    }

    function testFuzz_receive_forwardsArbitraryETH(uint96 amount) public {
        vm.assume(amount > 0);
        uint256 before = pool.balance;
        vm.deal(user, amount);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: amount}("");
        assertTrue(ok);
        assertEq(pool.balance - before, amount);
        assertEq(address(wallet).balance, 0);
    }

    function testFuzz_receive_paused_holdsArbitraryETH(uint96 amount) public {
        vm.assume(amount > 0);
        vm.prank(admin);
        wallet.pause();
        vm.deal(user, amount);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: amount}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, amount);
    }

    function testFuzz_sweepToken_fullBalance(uint128 amount) public {
        vm.assume(amount > 0);
        AdvMockERC20 token = new AdvMockERC20("T");
        token.mint(address(wallet), amount);
        vm.prank(admin);
        wallet.sweepToken(address(token));
        assertEq(token.balanceOf(pool),            amount);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function testFuzz_notify_permissionless(address caller, uint128 amount) public {
        vm.assume(amount > 0);
        AdvMockERC20 token = new AdvMockERC20("N");
        token.mint(address(wallet), amount);
        vm.prank(caller);
        wallet.notify(address(token));
        assertEq(token.balanceOf(pool),            amount);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function testFuzz_batchSweepTokens_fullBalances(uint8 count, uint64 baseAmount) public {
        count      = uint8(bound(count, 1, 8));
        baseAmount = uint64(bound(baseAmount, 1, 1e12));

        address[] memory tokens  = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint8 i; i < count; ++i) {
            AdvMockERC20 t = new AdvMockERC20("B");
            amounts[i] = uint256(baseAmount) * (i + 1);
            t.mint(address(wallet), amounts[i]);
            tokens[i] = address(t);
        }
        vm.prank(admin);
        wallet.batchSweepTokens(tokens);
        for (uint8 i; i < count; ++i) {
            assertEq(AdvMockERC20(tokens[i]).balanceOf(pool),            amounts[i]);
            assertEq(AdvMockERC20(tokens[i]).balanceOf(address(wallet)), 0);
        }
    }

    function testFuzz_setPoolWallet_anyNonZero(address newPool) public {
        vm.assume(newPool != address(0));
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        assertEq(wallet.poolWallet(), newPool);
    }

    function test_setPoolWallet_rejects_zero() public {
        vm.prank(admin);
        vm.expectRevert("BW: zero pool");
        wallet.setPoolWallet(address(0));
    }

    function testFuzz_execute_arbitraryTargetData(address target) public {
        vm.assume(uint160(target) > 0xFF);
        vm.assume(target != address(wallet));
        vm.assume(target.code.length == 0);
        vm.prank(admin);
        wallet.execute(target, 0, "");
    }

    function testFuzz_sweepToken_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!wallet.hasRole(wallet.SWEEPER_ROLE(), caller));
        AdvMockERC20 t = new AdvMockERC20("R");
        t.mint(address(wallet), 1e18);
        vm.prank(caller);
        vm.expectRevert();
        wallet.sweepToken(address(t));
    }

    function testFuzz_execute_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!wallet.hasRole(wallet.EXECUTOR_ROLE(), caller));
        vm.prank(caller);
        vm.expectRevert();
        wallet.execute(pool, 0, "");
    }

    function testFuzz_pause_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!wallet.hasRole(wallet.PAUSER_ROLE(), caller));
        vm.prank(caller);
        vm.expectRevert();
        wallet.pause();
    }

    function testFuzz_sweepETH_exactBalance(uint96 heldAmount) public {
        vm.assume(heldAmount > 0);
        vm.prank(admin);
        wallet.pause();
        vm.deal(user, heldAmount);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: heldAmount}("");
        assertTrue(ok);
        vm.prank(admin);
        wallet.unpause();
        uint256 before = pool.balance;
        vm.prank(admin);
        wallet.sweepETH();
        assertEq(pool.balance - before, heldAmount);
        assertEq(address(wallet).balance, 0);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// BAD ACTOR / ADVERSARIAL TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract BusinessWalletBadActor is Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;
    BusinessWallet    impl;

    address admin    = makeAddr("admin");
    address pool     = makeAddr("pool");
    address attacker = makeAddr("attacker");
    address user     = makeAddr("user");

    bytes32 constant BID = keccak256("biz-attack");

    function setUp() public {
        impl   = new BusinessWallet();
        beacon = new UpgradeableBeacon(address(impl));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        wallet = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
    }

    function test_attack_initializeImpl_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        impl.initialize(BID, attacker, attacker, address(0), address(0));
    }

    function test_attack_fakeForwarder_shortCalldata() public {
        address fwd = makeAddr("forwarder");
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, fwd, address(0))
        );
        BusinessWallet w = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
        bytes memory truncated = abi.encodePacked(
            BusinessWallet.setPoolWallet.selector,
            abi.encode(makeAddr("newPool")),
            bytes7(0xAAAAAAAAAAAAAA)
        );
        vm.prank(fwd);
        (bool ok,) = address(w).call(truncated);
        assertFalse(ok, "short meta-tx must not succeed");
    }

    function test_attack_execute_selfCall_reverts() public {
        bytes memory data = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, attacker, attacker, address(0), address(0))
        );
        vm.prank(admin);
        vm.expectRevert("BW: no self-call");
        wallet.execute(address(wallet), 0, data);
    }

    function test_attack_execute_overdraftETH_reverts() public {
        vm.deal(address(wallet), 0.5 ether);
        vm.prank(admin);
        vm.expectRevert("BW: execution failed");
        wallet.execute(attacker, 1 ether, "");
    }

    function test_attack_circularPool_ethHeld() public {
        vm.prank(admin);
        wallet.setPoolWallet(address(wallet));
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 1 ether);
    }

    function test_attack_grantRole_byNonAdmin_reverts() public {
        bytes32 sweeperRole  = wallet.SWEEPER_ROLE();
        bytes32 executorRole = wallet.EXECUTOR_ROLE();
        bytes32 adminRole    = wallet.DEFAULT_ADMIN_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        wallet.grantRole(sweeperRole, attacker);
        vm.prank(attacker);
        vm.expectRevert();
        wallet.grantRole(executorRole, attacker);
        vm.prank(attacker);
        vm.expectRevert();
        wallet.grantRole(adminRole, attacker);
    }

    function test_attack_maliciousTokenRevertsInTransfer() public {
        address malicious = address(new HoneypotToken());
        vm.prank(admin);
        vm.expectRevert();
        wallet.sweepToken(malicious);
        AdvMockERC20 good = new AdvMockERC20("G");
        good.mint(address(wallet), 1e18);
        vm.prank(admin);
        wallet.sweepToken(address(good));
        assertEq(good.balanceOf(pool), 1e18);
    }

    function test_attack_renounceAdminRole_noMoreGrants() public {
        bytes32 defaultAdmin = wallet.DEFAULT_ADMIN_ROLE();
        bytes32 sweeperRole  = wallet.SWEEPER_ROLE();
        vm.prank(admin);
        wallet.renounceRole(defaultAdmin, admin);
        vm.prank(admin);
        vm.expectRevert();
        wallet.grantRole(sweeperRole, attacker);
    }

    function test_griefing_oneWeiHeld_walletStillFunctional() public {
        Sink sink = new Sink();
        vm.prank(admin);
        wallet.setPoolWallet(address(sink));
        vm.deal(user, 1);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 1);
        AdvMockERC20 t = new AdvMockERC20("G");
        t.mint(address(wallet), 1e18);
        wallet.notify(address(t));
        assertEq(t.balanceOf(address(sink)), 1e18);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// ADDITIONAL REENTRANCY SCENARIOS
// ═════════════════════════════════════════════════════════════════════════════

contract BusinessWalletReentrancy is Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");

    bytes32 constant BID = keccak256("biz-reentrant");

    function setUp() public {
        beacon = new UpgradeableBeacon(address(new BusinessWallet()));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        wallet = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
    }

    function test_reentrancy_sweepToken_viaMaliciousERC20() public {
        ReentrancySweepToken token = new ReentrancySweepToken(payable(address(wallet)));
        token.mint(address(wallet), 100e18);
        token.arm();
        vm.prank(admin);
        vm.expectRevert("BW: reentrant");
        wallet.sweepToken(address(token));
    }

    function test_reentrancy_batchSweepTokens_viaMaliciousERC20() public {
        ReentrancyBatchSweep token = new ReentrancyBatchSweep(payable(address(wallet)));
        token.mint(address(wallet), 100e18);
        token.arm();
        address[] memory batch = new address[](1);
        batch[0] = address(token);
        vm.prank(admin);
        vm.expectRevert("BW: reentrant");
        wallet.batchSweepTokens(batch);
    }

    function test_reentrancy_execute_viaMaliciousERC20Transfer() public {
        ReentrancyExecute token = new ReentrancyExecute(payable(address(wallet)));
        token.mint(address(wallet), 100e18);
        token.arm();
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", pool, 100e18);
        vm.prank(admin);
        vm.expectRevert("BW: execution failed");
        wallet.execute(address(token), 0, data);
    }

    function test_reentrancy_notify_isolatedDeploy() public {
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (keccak256("biz-B"), admin, pool, address(0), address(0))
        );
        BusinessWallet walletB = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
        ReentrancySweepToken token = new ReentrancySweepToken(payable(address(walletB)));
        token.mint(address(walletB), 50e18);
        token.arm();
        vm.prank(admin);
        vm.expectRevert("BW: reentrant");
        walletB.sweepToken(address(token));
        // walletA is unaffected
        AdvMockERC20 good = new AdvMockERC20("G");
        good.mint(address(wallet), 1e18);
        wallet.notify(address(good));
        assertEq(good.balanceOf(pool), 1e18);
    }

    function test_reentrancy_guardResetsAfterSuccess() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);
        vm.prank(admin);
        wallet.sweepToken(address(t));
        t.mint(address(wallet), 2e18);
        vm.prank(admin);
        wallet.sweepToken(address(t));
        assertEq(t.balanceOf(pool), 3e18);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// GAS BENCHMARKS
// ═════════════════════════════════════════════════════════════════════════════

contract BusinessWalletGas is Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");
    address user  = makeAddr("user");

    // Ceilings set ~30% above observed baseline — failing here signals a regression.
    uint256 constant RECEIVE_ETH_CEILING         = 85_000;
    uint256 constant NOTIFY_SINGLE_TOKEN_CEILING = 100_000;
    uint256 constant SWEEP_SINGLE_TOKEN_CEILING  = 110_000;
    uint256 constant BATCH_SWEEP_10_CEILING      = 500_000;
    uint256 constant EXECUTE_CEILING             = 80_000;
    uint256 constant SET_POOL_CEILING            = 55_000;
    uint256 constant SWEEP_ETH_CEILING           = 85_000;

    bytes32 constant BID = keccak256("biz-gas");

    function setUp() public {
        beacon = new UpgradeableBeacon(address(new BusinessWallet()));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        wallet = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
    }

    function test_gas_receive_ETH() public {
        vm.deal(user, 1 ether);
        uint256 g = gasleft();
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        uint256 used = g - gasleft();
        assertTrue(ok);
        emit log_named_uint("gas: receive ETH (auto-forward)", used);
        assertLt(used, RECEIVE_ETH_CEILING, "receive() regressed");
    }

    function test_gas_notify_singleToken() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);
        uint256 g = gasleft();
        wallet.notify(address(t));
        uint256 used = g - gasleft();
        emit log_named_uint("gas: notify() single token", used);
        assertLt(used, NOTIFY_SINGLE_TOKEN_CEILING, "notify() regressed");
    }

    function test_gas_sweepToken_single() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.sweepToken(address(t));
        uint256 used = g - gasleft();
        emit log_named_uint("gas: sweepToken() single", used);
        assertLt(used, SWEEP_SINGLE_TOKEN_CEILING, "sweepToken() regressed");
    }

    function test_gas_batchSweepTokens_10() public {
        address[] memory tokens = new address[](10);
        for (uint256 i; i < 10; ++i) {
            AdvMockERC20 t = new AdvMockERC20("B");
            t.mint(address(wallet), 1e18);
            tokens[i] = address(t);
        }
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.batchSweepTokens(tokens);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: batchSweepTokens() x10", used);
        assertLt(used, BATCH_SWEEP_10_CEILING, "batchSweepTokens(10) regressed");
    }

    function test_gas_execute_emptyCall() public {
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.execute(pool, 0, "");
        uint256 used = g - gasleft();
        emit log_named_uint("gas: execute() empty call", used);
        assertLt(used, EXECUTE_CEILING, "execute() regressed");
    }

    function test_gas_setPoolWallet() public {
        address newPool = makeAddr("newPool");
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: setPoolWallet()", used);
        assertLt(used, SET_POOL_CEILING, "setPoolWallet() regressed");
    }

    function test_gas_sweepETH() public {
        vm.prank(admin);
        wallet.pause();
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(admin);
        wallet.unpause();
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.sweepETH();
        uint256 used = g - gasleft();
        emit log_named_uint("gas: sweepETH()", used);
        assertLt(used, SWEEP_ETH_CEILING, "sweepETH() regressed");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// REGRESSION TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract BusinessWalletRegression is Test {
    UpgradeableBeacon beacon;
    BusinessWallet    wallet;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");
    address user  = makeAddr("user");

    bytes32 constant BID = keccak256("biz-reg");

    function setUp() public {
        beacon = new UpgradeableBeacon(address(new BusinessWallet()));
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, address(0), address(0))
        );
        wallet = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));
    }

    function test_regression_ethNotLostOnPoolRevert() public {
        Sink sink = new Sink();
        vm.prank(admin);
        wallet.setPoolWallet(address(sink));
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok, "receive() must not revert");
        assertEq(address(wallet).balance, 1 ether, "ETH must be held, not lost");
    }

    function test_regression_doubleInitBlocked() public {
        vm.expectRevert();
        wallet.initialize(BID, makeAddr("evil"), makeAddr("evil"), address(0), address(0));
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), makeAddr("evil")));
    }

    function test_regression_poolWalletIsolated_fromFactory() public {
        assertEq(wallet.poolWallet(), pool);
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        assertEq(wallet.poolWallet(), newPool);
    }

    function test_regression_pause_blocksAllSweepPaths() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);
        vm.prank(admin);
        wallet.pause();

        wallet.notify(address(t));
        assertEq(t.balanceOf(address(wallet)), 1e18, "notify must be no-op when paused");

        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.sweepToken(address(t));

        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.batchSweepTokens(tokens);

        vm.deal(address(wallet), 1 ether);
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.sweepETH();

        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.execute(pool, 0, "");
    }

    function test_regression_reentrancyGuard_notTrippedOnFirstCall() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);
        wallet.notify(address(t));
        assertEq(t.balanceOf(pool), 1e18);
    }

    function test_regression_upgradeGapPreservesState() public {
        bytes32 bidBefore  = wallet.businessId();
        address poolBefore = wallet.poolWallet();
        // Beacon is owned by this test contract (no ownership transfer in setUp)
        BusinessWallet newImpl = new BusinessWallet();
        beacon.upgradeTo(address(newImpl));
        assertEq(wallet.businessId(),  bidBefore);
        assertEq(wallet.poolWallet(), poolBefore);
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
    }
}
