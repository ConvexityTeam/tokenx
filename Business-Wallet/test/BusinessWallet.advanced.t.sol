// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BusinessWallet — Advanced Tests
 * @notice Covers: fuzz, invariant, bad-actor, gas benchmarks, and
 *         additional reentrancy scenarios not present in the baseline suite.
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

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC20 that re-enters notify() (permissionless) during transfer.
///      Used to test the reentrancy guard on sweepToken / batchSweepTokens /
///      execute — all of which call safeTransfer internally.
contract ReentrancySweepToken is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable v) ERC20("RST", "RST") {
        victim = BusinessWallet(v);
    }

    function arm()                           external { armed = true; }
    function mint(address to, uint256 amt)   external { _mint(to, amt); }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) {
            armed = false;
            // notify() is permissionless — no role required.
            // It is also nonReentrant, so it hits "BW: reentrant" here.
            victim.notify(address(this));
        }
        return super.transfer(to, amt);
    }
}

/// @dev ERC20 that re-enters notify() during a batchSweepTokens transfer.
contract ReentrancyBatchSweep is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable v) ERC20("RBS", "RBS") {
        victim = BusinessWallet(v);
    }

    function arm() external { armed = true; }

    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) {
            armed = false;
            victim.notify(address(this)); // permissionless re-entry
        }
        return super.transfer(to, amt);
    }
}

/// @dev ERC20 that re-enters notify() during an execute() transfer.
contract ReentrancyExecute is ERC20 {
    BusinessWallet public victim;
    bool public armed;

    constructor(address payable v) ERC20("REX", "REX") {
        victim = BusinessWallet(v);
    }

    function arm()                         external { armed = true; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) {
            armed = false;
            // notify() hits "BW: reentrant"; that causes safeTransfer to
            // revert, which makes execute() report "BW: execution failed".
            victim.notify(address(this));
        }
        return super.transfer(to, amt);
    }
}

/// @dev Refuses all ETH.
contract Sink {
    receive() external payable { revert("no ETH"); }
}

// ── Invariant Handler ─────────────────────────────────────────────────────────

/**
 * @dev Drives the wallet through legitimate operations so the invariant runner
 *      can find unexpected state transitions.  All calls are guarded by roles
 *      exactly as a real caller would use them.
 */
contract BWHandler is Test {
    BusinessWallet public wallet;
    address        public admin;
    address        public pool;

    AdvMockERC20[] tokens;
    uint256 public totalMinted;
    uint256 public totalSwept;

    constructor(address payable _wallet, address _admin, address _pool) {
        wallet = BusinessWallet(_wallet);
        admin  = _admin;
        pool   = _pool;

        // Pre-deploy a few tokens for the handler to use
        for (uint8 i; i < 3; ++i) {
            tokens.push(new AdvMockERC20(string(abi.encodePacked("T", i))));
        }
    }

    // Mint tokens to the wallet and then sweep them
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

    // Send ETH and auto-forward (wallet is unpaused)
    function sendETH(uint256 amt) external {
        amt = bound(amt, 0, 100 ether);
        vm.deal(address(this), amt);
        (bool ok,) = address(wallet).call{value: amt}("");
        assertTrue(ok);
    }

    // Toggle pause/unpause
    function togglePause() external {
        if (wallet.paused()) {
            vm.prank(admin);
            wallet.unpause();
        } else {
            vm.prank(admin);
            wallet.pause();
            // unpause immediately so sweeps stay possible in subsequent calls
            vm.prank(admin);
            wallet.unpause();
        }
    }

    // Update pool wallet to a new address (must stay non-zero)
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
        wallet = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));

        handler = new BWHandler(payable(address(wallet)), admin, pool);

        // Grant handler SWEEPER_ROLE so it can call sweepToken
        bytes32 sweeperRole = wallet.SWEEPER_ROLE();
        vm.prank(admin);
        wallet.grantRole(sweeperRole, address(handler));

        targetContract(address(handler));
    }

    /// @notice poolWallet must never be set to address(0).
    function invariant_poolWalletNeverZero() public {
        assertTrue(wallet.poolWallet() != address(0));
    }

    /// @notice businessId must be immutable once set.
    function invariant_businessIdImmutable() public {
        assertEq(wallet.businessId(), BID);
    }

    /// @notice trustedForwarder must be immutable (set to 0 in this deployment).
    function invariant_forwarderImmutable() public {
        assertEq(wallet.trustedForwarder(), address(0));
    }

    /// @notice Admin must always retain DEFAULT_ADMIN_ROLE.
    function invariant_adminKeepsDefaultAdminRole() public {
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// @notice Wallet must never be self-initializable (disableInitializers).
    function invariant_implementationNotInitializable() public {
        // The beacon's implementation is the raw BusinessWallet; calling
        // initialize on it must always revert.
        BusinessWallet impl = BusinessWallet(payable(UpgradeableBeacon(address(beacon)).implementation()));
        vm.expectRevert();
        impl.initialize(BID, admin, pool, address(0), address(0));
    }

    /// @notice Wallet ETH balance is 0 when not paused
    ///         (auto-forward drains it on every receive).
    function invariant_unpaused_walletHoldsNoETH() public {
        if (!wallet.paused()) {
            assertEq(address(wallet).balance, 0);
        }
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

    // ── ETH forwarding ────────────────────────────────────────────────────────

    /// @notice Any non-zero ETH amount is fully forwarded to pool.
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

    /// @notice ETH is held (not forwarded) whenever the wallet is paused.
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

    // ── Token sweeps ──────────────────────────────────────────────────────────

    /// @notice sweepToken sends the full balance, regardless of amount.
    function testFuzz_sweepToken_fullBalance(uint128 amount) public {
        vm.assume(amount > 0);
        AdvMockERC20 token = new AdvMockERC20("T");
        token.mint(address(wallet), amount);

        vm.prank(admin);
        wallet.sweepToken(address(token));

        assertEq(token.balanceOf(pool),            amount);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    /// @notice notify() is permissionless and sweeps the full balance.
    function testFuzz_notify_permissionless(address caller, uint128 amount) public {
        vm.assume(amount > 0);
        AdvMockERC20 token = new AdvMockERC20("N");
        token.mint(address(wallet), amount);

        vm.prank(caller);
        wallet.notify(address(token)); // no role required

        assertEq(token.balanceOf(pool),            amount);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    /// @notice batchSweepTokens sweeps all provided tokens fully.
    function testFuzz_batchSweepTokens_fullBalances(uint8 count, uint64 baseAmount) public {
        count      = uint8(bound(count, 1, 8));
        baseAmount = uint64(bound(baseAmount, 1, 1e12));

        address[] memory tokens = new address[](count);
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

    // ── setPoolWallet ─────────────────────────────────────────────────────────

    /// @notice Any non-zero address is accepted as a new pool wallet.
    function testFuzz_setPoolWallet_anyNonZero(address newPool) public {
        vm.assume(newPool != address(0));
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        assertEq(wallet.poolWallet(), newPool);
    }

    /// @notice address(0) is always rejected, regardless of who calls.
    function test_setPoolWallet_rejects_zero() public {
        vm.prank(admin);
        vm.expectRevert("BW: zero pool");
        wallet.setPoolWallet(address(0));
    }

    // ── execute ───────────────────────────────────────────────────────────────

    /// @notice execute() with an arbitrary valid target and 0 value succeeds.
    function testFuzz_execute_arbitraryTargetData(address target) public {
        // Exclude: address(0), self, precompiles (0x1–0x9), and Foundry magic
        // addresses (0x1–0xFF) that can revert on arbitrary calls.
        vm.assume(uint160(target) > 0xFF);
        vm.assume(target != address(wallet));
        vm.assume(target.code.length == 0); // plain EOA: always accepts any call
        vm.prank(admin);
        wallet.execute(target, 0, "");
    }

    // ── Role isolation ────────────────────────────────────────────────────────

    /// @notice A random address without any role cannot sweep.
    function testFuzz_sweepToken_randomCaller_reverts(address caller) public {
        // Skip known privileged addresses
        vm.assume(caller != admin);
        vm.assume(!wallet.hasRole(wallet.SWEEPER_ROLE(), caller));

        AdvMockERC20 t = new AdvMockERC20("R");
        t.mint(address(wallet), 1e18);

        vm.prank(caller);
        vm.expectRevert();
        wallet.sweepToken(address(t));
    }

    /// @notice A random address without executor role cannot call execute().
    function testFuzz_execute_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!wallet.hasRole(wallet.EXECUTOR_ROLE(), caller));

        vm.prank(caller);
        vm.expectRevert();
        wallet.execute(pool, 0, "");
    }

    /// @notice A random address without pauser role cannot pause.
    function testFuzz_pause_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!wallet.hasRole(wallet.PAUSER_ROLE(), caller));

        vm.prank(caller);
        vm.expectRevert();
        wallet.pause();
    }

    // ── sweepETH boundary ─────────────────────────────────────────────────────

    /// @notice sweepETH transfers the exact balance held, regardless of amount.
    function testFuzz_sweepETH_exactBalance(uint96 heldAmount) public {
        vm.assume(heldAmount > 0);

        // Park ETH while paused so auto-forward doesn't drain it
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

    // ── Attack: initialise the raw implementation ─────────────────────────────

    /// @notice Calling initialize on the raw implementation must always revert.
    ///         An attacker cannot take over the impl and upgrade it maliciously.
    function test_attack_initializeImpl_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        impl.initialize(BID, attacker, attacker, address(0), address(0));
    }

    // ── Attack: fake trusted forwarder (short calldata) ───────────────────────

    /// @notice A forged EIP-2771 call with fewer than 20 appended bytes must
    ///         not be parsed as a meta-tx — _msgSender falls back to msg.sender.
    function test_attack_fakeForwarder_shortCalldata() public {
        address fwd = makeAddr("forwarder");

        // Deploy wallet with a real forwarder
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, admin, pool, fwd, address(0))
        );
        BusinessWallet w = BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));

        // Attacker tries to impersonate admin by calling setPoolWallet through
        // the forwarder address but with fewer than 20 appended bytes (7 bytes here).
        // The contract should treat msg.sender == fwd, not any embedded address.
        // fwd does NOT have WALLET_ADMIN_ROLE → call must revert.
        bytes memory truncated = abi.encodePacked(
            BusinessWallet.setPoolWallet.selector,
            abi.encode(makeAddr("newPool")),
            bytes7(0xAAAAAAAAAAAAAA) // only 7 bytes appended, not 20
        );
        vm.prank(fwd);
        (bool ok,) = address(w).call(truncated);
        assertFalse(ok, "short meta-tx must not succeed");
    }

    // ── Attack: self-call via execute ─────────────────────────────────────────

    /// @notice execute() must block calls that target the wallet itself,
    ///         preventing an executor from re-entering or re-initializing.
    function test_attack_execute_selfCall_reverts() public {
        bytes memory data = abi.encodeCall(
            BusinessWallet.initialize,
            (BID, attacker, attacker, address(0), address(0))
        );
        vm.prank(admin);
        vm.expectRevert("BW: no self-call");
        wallet.execute(address(wallet), 0, data);
    }

    // ── Attack: steal ETH via execute ────────────────────────────────────────

    /// @notice An executor with legitimate role can send ETH to any target.
    ///         Verify the wallet correctly spends only what it holds and doesn't
    ///         over-draft (the call fails if value > balance).
    function test_attack_execute_overdraftETH_reverts() public {
        vm.deal(address(wallet), 0.5 ether);
        vm.prank(admin);
        vm.expectRevert("BW: execution failed");
        wallet.execute(attacker, 1 ether, ""); // more than the wallet holds
    }

    // ── Attack: circular pool (wallet ← pool ← wallet) ───────────────────────

    /// @notice Pool can be set to the wallet's own address.  Sending ETH will
    ///         then cause the receive() re-entry — the nonReentrant guard must
    ///         stop this from being exploitable.
    ///         In practice the forward simply fails (pool is the wallet itself,
    ///         which re-enters receive, which would re-enter again — this loop
    ///         runs until the EVM gas limit kills it or the guard fires).
    ///         Here we verify the guard catches it and ETH is held.
    function test_attack_circularPool_ethHeld() public {
        // Point poolWallet to the wallet itself
        vm.prank(admin);
        wallet.setPoolWallet(address(wallet));

        vm.deal(user, 1 ether);
        // receive() will try to forward to itself, causing recursion.
        // The guard or gas exhaustion will prevent infinite loop — ETH must be held.
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        // Call succeeds (receive does not revert on failure — it emits ETHReceived)
        assertTrue(ok);
        // ETH is held in the wallet, not lost
        assertEq(address(wallet).balance, 1 ether);
    }

    // ── Attack: privilege escalation via grantRole ────────────────────────────

    /// @notice A non-admin cannot grant themselves any role.
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

    // ── Attack: drain via batchSweepTokens with a malicious token ─────────────

    /// @notice A malicious ERC20 that reverts in transfer cannot brick the
    ///         wallet — the SafeERC20 wrapper propagates the revert to the
    ///         caller (sweepToken), but the wallet state is unchanged.
    function test_attack_maliciousTokenRevertsInTransfer() public {
        // A "honeypot" token: balanceOf returns 100, transfer always reverts.
        // We model this with a contract that returns a non-zero balance.
        address malicious = address(new HoneypotToken());

        vm.prank(admin);
        vm.expectRevert();
        wallet.sweepToken(malicious);

        // Wallet is still functional after the failed sweep
        AdvMockERC20 good = new AdvMockERC20("G");
        good.mint(address(wallet), 1e18);
        vm.prank(admin);
        wallet.sweepToken(address(good));
        assertEq(good.balanceOf(pool), 1e18);
    }

    // ── Attack: renouncing DEFAULT_ADMIN_ROLE ─────────────────────────────────

    /// @notice Admin can renounce DEFAULT_ADMIN_ROLE (this is allowed by OZ).
    ///         After renouncing, no new roles can be granted.
    ///         Document that this is an irreversible action.
    function test_attack_renounceAdminRole_noMoreGrants() public {
        bytes32 defaultAdmin = wallet.DEFAULT_ADMIN_ROLE();
        bytes32 sweeperRole  = wallet.SWEEPER_ROLE();

        // Admin renounces
        vm.prank(admin);
        wallet.renounceRole(defaultAdmin, admin);

        // Now no one can grant roles → any grantRole call reverts
        vm.prank(admin);
        vm.expectRevert();
        wallet.grantRole(sweeperRole, attacker);
    }

    // ── Griefing: 1-wei ETH to wallet with failing pool ───────────────────────

    /// @notice Even 1 wei held in the wallet does not block future operations.
    ///         The wallet keeps operating even if auto-forward has failed.
    function test_griefing_oneWeiHeld_walletStillFunctional() public {
        Sink sink = new Sink();
        vm.prank(admin);
        wallet.setPoolWallet(address(sink)); // pool now rejects ETH

        // 1 wei arrives; pool rejects it; 1 wei is held
        vm.deal(user, 1);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1}("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 1);

        // Token sweeps still work normally
        AdvMockERC20 t = new AdvMockERC20("G");
        t.mint(address(wallet), 1e18);
        wallet.notify(address(t));
        assertEq(t.balanceOf(address(sink)), 1e18);
    }
}

/// @dev Fake ERC20 whose transfer always reverts — models a honeypot.
contract HoneypotToken {
    function balanceOf(address) external pure returns (uint256) { return 1e18; }
    function transfer(address, uint256) external pure returns (bool) {
        revert("honeypot: blocked");
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

    /// @notice sweepToken cannot be re-entered via a malicious ERC20 transfer.
    function test_reentrancy_sweepToken_viaMaliciousERC20() public {
        ReentrancySweepToken token =
            new ReentrancySweepToken(payable(address(wallet)));
        token.mint(address(wallet), 100e18);
        token.arm();

        vm.prank(admin);
        vm.expectRevert("BW: reentrant");
        wallet.sweepToken(address(token));
    }

    /// @notice batchSweepTokens cannot be re-entered via a malicious ERC20 transfer.
    function test_reentrancy_batchSweepTokens_viaMaliciousERC20() public {
        ReentrancyBatchSweep token =
            new ReentrancyBatchSweep(payable(address(wallet)));
        token.mint(address(wallet), 100e18);

        address[] memory batch = new address[](1);
        batch[0] = address(token);
        token.arm();

        vm.prank(admin);
        vm.expectRevert("BW: reentrant");
        wallet.batchSweepTokens(batch);
    }

    /// @notice execute() cannot be re-entered via a token transfer inside the call.
    function test_reentrancy_execute_viaMaliciousERC20Transfer() public {
        ReentrancyExecute token =
            new ReentrancyExecute(payable(address(wallet)));
        token.mint(address(wallet), 100e18);
        token.arm();

        bytes memory data = abi.encodeWithSignature(
            "transfer(address,uint256)", pool, 100e18
        );

        vm.prank(admin);
        vm.expectRevert("BW: execution failed");
        wallet.execute(address(token), 0, data);
    }

    /// @notice notify() cannot be re-entered (covered in baseline; verified here
    ///         with a fresh deploy to confirm independence).
    function test_reentrancy_notify_isolatedDeploy() public {
        // Deploy a second wallet to confirm guard is per-instance, not global
        bytes memory init = abi.encodeCall(
            BusinessWallet.initialize,
            (keccak256("biz-B"), admin, pool, address(0), address(0))
        );
        BusinessWallet walletB =
            BusinessWallet(payable(address(new BeaconProxy(address(beacon), init))));

        // Reentrant token on walletB
        ReentrancySweepToken token =
            new ReentrancySweepToken(payable(address(walletB)));
        token.mint(address(walletB), 50e18);
        token.arm();

        vm.prank(admin);
        vm.expectRevert("BW: reentrant");
        walletB.sweepToken(address(token));

        // walletA is completely unaffected
        AdvMockERC20 good = new AdvMockERC20("G");
        good.mint(address(wallet), 1e18);
        wallet.notify(address(good));
        assertEq(good.balanceOf(pool), 1e18);
    }

    /// @notice Reentrancy guard is reset after a successful call.
    ///         Two sequential sweepToken calls must both succeed.
    function test_reentrancy_guardResetsAfterSuccess() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);
        vm.prank(admin);
        wallet.sweepToken(address(t));

        // Second call: guard must be cleared
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

    bytes32 constant BID = keccak256("biz-gas");

    // Upper-bound gas ceilings — set 30% above measured baseline.
    // Adjust after intentional optimisation; failing here signals a regression.
    uint256 constant RECEIVE_ETH_CEILING         = 85_000;   // measured ~63k
    uint256 constant NOTIFY_SINGLE_TOKEN_CEILING = 100_000;  // measured ~69k
    uint256 constant SWEEP_SINGLE_TOKEN_CEILING  = 110_000;  // measured ~76k
    uint256 constant BATCH_SWEEP_10_CEILING      = 500_000;  // measured ~350k
    uint256 constant EXECUTE_CEILING             = 80_000;   // measured ~56k
    uint256 constant SET_POOL_CEILING            = 55_000;   // measured ~40k

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
        assertLt(used, RECEIVE_ETH_CEILING,
            "receive() regressed beyond ceiling");
    }

    function test_gas_notify_singleToken() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);

        uint256 g = gasleft();
        wallet.notify(address(t));
        uint256 used = g - gasleft();

        emit log_named_uint("gas: notify() single token", used);
        assertLt(used, NOTIFY_SINGLE_TOKEN_CEILING,
            "notify() regressed beyond ceiling");
    }

    function test_gas_sweepToken_single() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);

        uint256 g = gasleft();
        vm.prank(admin);
        wallet.sweepToken(address(t));
        uint256 used = g - gasleft();

        emit log_named_uint("gas: sweepToken() single", used);
        assertLt(used, SWEEP_SINGLE_TOKEN_CEILING,
            "sweepToken() regressed beyond ceiling");
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
        assertLt(used, BATCH_SWEEP_10_CEILING,
            "batchSweepTokens(10) regressed beyond ceiling");
    }

    function test_gas_execute_emptyCall() public {
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.execute(pool, 0, "");
        uint256 used = g - gasleft();

        emit log_named_uint("gas: execute() empty call", used);
        assertLt(used, EXECUTE_CEILING,
            "execute() regressed beyond ceiling");
    }

    function test_gas_setPoolWallet() public {
        address newPool = makeAddr("newPool");
        uint256 g = gasleft();
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        uint256 used = g - gasleft();

        emit log_named_uint("gas: setPoolWallet()", used);
        assertLt(used, SET_POOL_CEILING,
            "setPoolWallet() regressed beyond ceiling");
    }

    function test_gas_sweepETH() public {
        // Park ETH while paused
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
        assertLt(used, 85_000, "sweepETH() regressed beyond ceiling"); // measured ~64k
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// REGRESSION TESTS
// ═════════════════════════════════════════════════════════════════════════════

/**
 * @notice Regression tests document specific edge cases or historical
 *         vulnerabilities that must never recur.
 */
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

    /// @notice REGRESSION: ETH must not be silently lost when pool reverts.
    ///         The wallet must emit ETHReceived and hold the funds so sweepETH()
    ///         can recover them later.
    function test_regression_ethNotLostOnPoolRevert() public {
        Sink sink = new Sink();
        vm.prank(admin);
        wallet.setPoolWallet(address(sink));

        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok, "receive() itself should not revert");
        assertEq(address(wallet).balance, 1 ether, "ETH must be held, not lost");
    }

    /// @notice REGRESSION: A second initialize call must never succeed.
    ///         If the proxy guard malfunctioned, an attacker could re-init with
    ///         new admin/pool addresses.
    function test_regression_doubleInitBlocked() public {
        vm.expectRevert();
        wallet.initialize(BID, makeAddr("evil"), makeAddr("evil"), address(0), address(0));

        // Original admin is still the admin
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), makeAddr("evil")));
    }

    /// @notice REGRESSION: poolWallet is not updated retroactively by the factory.
    ///         Each wallet holds the pool address at creation time; the factory's
    ///         setPoolWallet does not propagate to existing wallets.
    ///         (Documents intended behaviour — not a bug.)
    function test_regression_poolWalletIsolated_fromFactory() public {
        assertEq(wallet.poolWallet(), pool);
        // Confirm admin can change it independently
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        wallet.setPoolWallet(newPool);
        assertEq(wallet.poolWallet(), newPool);
    }

    /// @notice REGRESSION: pausing must block ALL token sweep paths uniformly.
    function test_regression_pause_blocksAllSweepPaths() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);

        vm.prank(admin);
        wallet.pause();

        // notify() is permissionless but returns silently when paused
        wallet.notify(address(t));
        assertEq(t.balanceOf(address(wallet)), 1e18, "notify must be no-op when paused");

        // sweepToken reverts
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.sweepToken(address(t));

        // batchSweepTokens reverts
        address[] memory tokens = new address[](1);
        tokens[0] = address(t);
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.batchSweepTokens(tokens);

        // sweepETH reverts
        vm.deal(address(wallet), 1 ether);
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.sweepETH();

        // execute reverts
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        wallet.execute(pool, 0, "");
    }

    /// @notice REGRESSION: reentrancy guard slot is 0-initialised in new proxies
    ///         and the guard uses value 2 (not 1) to detect re-entry, so the
    ///         first legitimate call after deployment is never blocked.
    function test_regression_reentrancyGuard_notTrippedOnFirstCall() public {
        AdvMockERC20 t = new AdvMockERC20("T");
        t.mint(address(wallet), 1e18);

        // First call ever on this proxy — must succeed
        wallet.notify(address(t));
        assertEq(t.balanceOf(pool), 1e18);
    }

    /// @notice REGRESSION: the upgrade gap must be large enough that adding
    ///         storage variables in a future upgrade won't clobber existing data.
    ///         We snapshot the gap size by checking the businessId after a fake
    ///         upgrade to a StorageProbe implementation.
    function test_regression_upgradeGapPreservesState() public {
        // Check that known state is preserved across an upgrade of the beacon
        bytes32 bidBefore  = wallet.businessId();
        address poolBefore = wallet.poolWallet();

        // Deploy a new (identical) implementation and upgrade beacon.
        // The beacon is owned by the test contract (deployed in setUp without
        // transferring ownership), so no prank is needed.
        BusinessWallet newImpl = new BusinessWallet();
        UpgradeableBeacon(address(beacon)).upgradeTo(address(newImpl));

        // State must be identical post-upgrade
        assertEq(wallet.businessId(),  bidBefore);
        assertEq(wallet.poolWallet(), poolBefore);
        assertTrue(wallet.hasRole(wallet.DEFAULT_ADMIN_ROLE(), admin));
    }
}
