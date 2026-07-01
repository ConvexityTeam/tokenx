// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title WalletFactory — Advanced Tests
 * @notice Covers: fuzz, invariant, bad-actor, gas benchmarks, regression.
 */

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/BusinessWallet.sol";
import "../src/WalletFactory.sol";

contract WFMockERC20 is ERC20 {
    constructor() ERC20("WFT", "WFT") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

// ── Invariant handler ─────────────────────────────────────────────────────────

contract WFHandler is Test {
    WalletFactory public factory;
    address       public admin;
    address       public pool;

    bytes32[] public deployed;
    uint256   public nonce;

    constructor(address _factory, address _admin, address _pool) {
        factory = WalletFactory(_factory);
        admin   = _admin;
        pool    = _pool;
    }

    function createWallet(address walletAdmin) external {
        if (walletAdmin == address(0)) walletAdmin = admin;
        bytes32 bid = keccak256(abi.encode("wf-inv", nonce++));
        vm.prank(admin);
        factory.createWallet(bid, walletAdmin);
        deployed.push(bid);
    }

    function deactivateWallet(uint256 idx) external {
        if (deployed.length == 0) return;
        idx = idx % deployed.length;
        bytes32 bid = deployed[idx];
        WalletFactory.WalletRecord memory rec = factory.getWallet(bid);
        if (!rec.active) return;
        vm.prank(admin);
        factory.deactivateWallet(bid);
    }

    function setPoolWallet(address newPool) external {
        if (newPool == address(0)) return;
        vm.prank(admin);
        factory.setPoolWallet(newPool);
        pool = newPool;
    }

    function togglePause() external {
        if (factory.paused()) {
            vm.prank(admin);
            factory.unpause();
        } else {
            vm.prank(admin);
            factory.pause();
            vm.prank(admin);
            factory.unpause();
        }
    }

    function deployedCount() external view returns (uint256) { return deployed.length; }
    function deployedAt(uint256 i) external view returns (bytes32) { return deployed[i]; }
}

// ═════════════════════════════════════════════════════════════════════════════
// INVARIANT TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract WalletFactoryInvariant is StdInvariant, Test {
    WalletFactory factory;
    BusinessWallet impl;
    WFHandler     handler;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");

    function setUp() public {
        impl    = new BusinessWallet();
        factory = new WalletFactory(admin, address(impl), pool, address(0));
        handler = new WFHandler(address(factory), admin, pool);
        targetContract(address(handler));
    }

    function invariant_poolWalletNeverZero() public {
        assertTrue(factory.poolWallet() != address(0));
    }

    function invariant_totalWalletsMatchesHandler() public {
        assertEq(factory.totalWallets(), handler.deployedCount());
    }

    function invariant_everyDeployedWalletHasAddress() public {
        uint256 count = handler.deployedCount();
        for (uint256 i; i < count; ++i) {
            WalletFactory.WalletRecord memory rec = factory.getWallet(handler.deployedAt(i));
            assertTrue(rec.wallet != address(0));
        }
    }

    function invariant_factoryIsSweeper() public {
        uint256 count = handler.deployedCount();
        for (uint256 i; i < count; ++i) {
            WalletFactory.WalletRecord memory rec = factory.getWallet(handler.deployedAt(i));
            BusinessWallet w = BusinessWallet(payable(rec.wallet));
            assertTrue(w.hasRole(w.SWEEPER_ROLE(), address(factory)));
        }
    }

    function invariant_adminKeepsDefaultAdminRole() public {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
    }

    function invariant_beaconIsImmutable() public {
        assertTrue(factory.walletBeacon() != address(0));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// FUZZ TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract WalletFactoryFuzz is Test {
    BusinessWallet impl;
    WalletFactory  factory;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");
    address user  = makeAddr("user");

    function setUp() public {
        impl    = new BusinessWallet();
        factory = new WalletFactory(admin, address(impl), pool, address(0));
    }

    function testFuzz_createWallet_validArgs(bytes32 bid, address walletAdmin) public {
        vm.assume(bid != bytes32(0));
        vm.assume(walletAdmin != address(0));
        vm.prank(admin);
        address w = factory.createWallet(bid, walletAdmin);
        assertTrue(w != address(0));
        assertEq(factory.walletOf(bid), w);
    }

    function testFuzz_createWallet_rejects_emptyId(address walletAdmin) public {
        vm.assume(walletAdmin != address(0));
        vm.prank(admin);
        vm.expectRevert("WF: empty businessId");
        factory.createWallet(bytes32(0), walletAdmin);
    }

    function testFuzz_createWallet_rejects_zeroAdmin(bytes32 bid) public {
        vm.assume(bid != bytes32(0));
        vm.prank(admin);
        vm.expectRevert("WF: zero admin");
        factory.createWallet(bid, address(0));
    }

    function testFuzz_createWallet_rejects_duplicate(bytes32 bid, address walletAdmin) public {
        vm.assume(bid != bytes32(0));
        vm.assume(walletAdmin != address(0));
        vm.prank(admin);
        factory.createWallet(bid, walletAdmin);
        vm.prank(admin);
        vm.expectRevert("WF: businessId taken");
        factory.createWallet(bid, walletAdmin);
    }

    function testFuzz_predictWalletAddress_alwaysMatches(
        bytes32 bid,
        address walletAdmin,
        bytes32 salt
    ) public {
        vm.assume(bid != bytes32(0));
        vm.assume(walletAdmin != address(0));
        address predicted = factory.predictWalletAddress(bid, walletAdmin, salt);
        vm.prank(admin);
        address deployed = factory.createWalletDeterministic(bid, walletAdmin, salt);
        assertEq(deployed, predicted);
    }

    function testFuzz_predictWalletAddress_differentSalts(
        bytes32 bid,
        address walletAdmin,
        bytes32 salt1,
        bytes32 salt2
    ) public {
        vm.assume(bid != bytes32(0));
        vm.assume(walletAdmin != address(0));
        vm.assume(salt1 != salt2);
        address p1 = factory.predictWalletAddress(bid, walletAdmin, salt1);
        address p2 = factory.predictWalletAddress(bid, walletAdmin, salt2);
        assertTrue(p1 != p2);
    }

    function testFuzz_setPoolWallet_anyNonZero(address newPool) public {
        vm.assume(newPool != address(0));
        vm.prank(admin);
        factory.setPoolWallet(newPool);
        assertEq(factory.poolWallet(), newPool);
    }

    function testFuzz_getWallets_paginationBounds(
        uint8 total,
        uint256 offset,
        uint256 limit
    ) public {
        total = uint8(bound(total, 0, 10));
        limit = bound(limit, 0, 20);
        for (uint256 i; i < total; ++i) {
            bytes32 bid = keccak256(abi.encode("fuzz-page", i));
            vm.prank(admin);
            factory.createWallet(bid, admin);
        }
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(offset, limit);
        if (offset >= total) {
            assertEq(recs.length, 0);
        } else {
            uint256 expectedLen = (offset + limit > total) ? total - offset : limit;
            assertEq(recs.length, expectedLen);
        }
    }

    function testFuzz_createWallet_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!factory.hasRole(factory.DEPLOYER_ROLE(), caller));
        vm.prank(caller);
        vm.expectRevert();
        factory.createWallet(keccak256("x"), admin);
    }

    function testFuzz_setPoolWallet_randomCaller_reverts(address caller) public {
        vm.assume(caller != admin);
        vm.assume(!factory.hasRole(factory.POOL_MANAGER_ROLE(), caller));
        vm.prank(caller);
        vm.expectRevert();
        factory.setPoolWallet(makeAddr("p"));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// BAD ACTOR / ADVERSARIAL TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract WalletFactoryBadActor is Test {
    BusinessWallet impl;
    WalletFactory  factory;

    address admin    = makeAddr("admin");
    address pool     = makeAddr("pool");
    address attacker = makeAddr("attacker");

    bytes32 constant BID = keccak256("biz-wf-attack");

    function setUp() public {
        impl    = new BusinessWallet();
        factory = new WalletFactory(admin, address(impl), pool, address(0));
    }

    function test_attack_createWhilePaused_reverts() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        factory.createWallet(BID, admin);
    }

    function test_attack_saltCollision_sameBusinessId_reverts() public {
        bytes32 salt = keccak256("same-salt");
        vm.prank(admin);
        factory.createWalletDeterministic(BID, admin, salt);
        vm.prank(admin);
        vm.expectRevert("WF: businessId taken");
        factory.createWalletDeterministic(BID, admin, salt);
    }

    function test_attack_grantDeployerRole_byAttacker_reverts() public {
        bytes32 deployerRole = factory.DEPLOYER_ROLE();
        vm.prank(attacker);
        vm.expectRevert();
        factory.grantRole(deployerRole, attacker);
    }

    function test_attack_setPoolWallet_byAttacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setPoolWallet(attacker);
    }

    function test_attack_deactivateWallet_byAttacker_reverts() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(attacker);
        vm.expectRevert();
        factory.deactivateWallet(BID);
    }

    function test_attack_pause_byAttacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.pause();
    }

    function test_attack_sweepWalletETH_byAttacker_reverts() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(attacker);
        vm.expectRevert();
        factory.sweepWalletETH(BID);
    }

    function test_attack_sweepUnknownWallet_reverts() public {
        vm.prank(admin);
        vm.expectRevert("WF: unknown businessId");
        factory.sweepWalletETH(keccak256("ghost"));
    }

    function test_attack_upgradeBeacon_byAttacker_reverts() public {
        UpgradeableBeacon beacon = UpgradeableBeacon(factory.walletBeacon());
        BusinessWallet newImpl  = new BusinessWallet();
        vm.prank(attacker);
        vm.expectRevert();
        beacon.upgradeTo(address(newImpl));
    }

    function test_attack_doubleDeactivate_noRevert() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(admin);
        factory.deactivateWallet(BID);
        vm.prank(admin);
        factory.deactivateWallet(BID);
        assertFalse(factory.getWallet(BID).active);
    }

    function test_attack_getWallet_unknownId_reverts() public {
        vm.expectRevert("WF: unknown businessId");
        factory.getWallet(bytes32(0));
    }

    function test_attack_walletOf_undeployed_returnsZero() public {
        assertEq(factory.walletOf(keccak256("ghost")), address(0));
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// GAS BENCHMARKS
// ═════════════════════════════════════════════════════════════════════════════

contract WalletFactoryGas is Test {
    BusinessWallet impl;
    WalletFactory  factory;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");
    address user  = makeAddr("user");

    uint256 constant CREATE_WALLET_CEILING               = 700_000;
    uint256 constant CREATE_WALLET_DETERMINISTIC_CEILING = 700_000;
    uint256 constant PREDICT_ADDRESS_CEILING             = 18_000;
    uint256 constant SWEEP_WALLET_ETH_CEILING            = 80_000;
    uint256 constant SWEEP_WALLET_TOKENS_CEILING         = 100_000;
    uint256 constant SET_POOL_CEILING                    = 40_000;
    uint256 constant DEACTIVATE_CEILING                  = 30_000;

    bytes32 constant BID = keccak256("gas-bench");

    function setUp() public {
        impl    = new BusinessWallet();
        factory = new WalletFactory(admin, address(impl), pool, address(0));
    }

    function test_gas_createWallet() public {
        uint256 g = gasleft();
        vm.prank(admin);
        factory.createWallet(BID, admin);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: createWallet()", used);
        assertLt(used, CREATE_WALLET_CEILING, "createWallet() regressed");
    }

    function test_gas_createWalletDeterministic() public {
        bytes32 salt = keccak256("salt-1");
        uint256 g = gasleft();
        vm.prank(admin);
        factory.createWalletDeterministic(BID, admin, salt);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: createWalletDeterministic()", used);
        assertLt(used, CREATE_WALLET_DETERMINISTIC_CEILING, "createWalletDeterministic() regressed");
    }

    function test_gas_predictWalletAddress() public {
        bytes32 salt = keccak256("salt-2");
        uint256 g = gasleft();
        factory.predictWalletAddress(BID, admin, salt);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: predictWalletAddress()", used);
        assertLt(used, PREDICT_ADDRESS_CEILING, "predictWalletAddress() regressed");
    }

    function test_gas_sweepWalletETH() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        BusinessWallet bw = BusinessWallet(payable(w));
        vm.prank(admin);
        bw.pause();
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = w.call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(admin);
        bw.unpause();
        uint256 g = gasleft();
        vm.prank(admin);
        factory.sweepWalletETH(BID);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: sweepWalletETH()", used);
        assertLt(used, SWEEP_WALLET_ETH_CEILING, "sweepWalletETH() regressed");
    }

    function test_gas_sweepWalletTokens_single() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        WFMockERC20 token = new WFMockERC20();
        token.mint(w, 1e18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256 g = gasleft();
        vm.prank(admin);
        factory.sweepWalletTokens(BID, tokens);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: sweepWalletTokens() x1", used);
        assertLt(used, SWEEP_WALLET_TOKENS_CEILING, "sweepWalletTokens() regressed");
    }

    function test_gas_setPoolWallet() public {
        address newPool = makeAddr("newPool");
        uint256 g = gasleft();
        vm.prank(admin);
        factory.setPoolWallet(newPool);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: setPoolWallet()", used);
        assertLt(used, SET_POOL_CEILING, "setPoolWallet() regressed");
    }

    function test_gas_deactivateWallet() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        uint256 g = gasleft();
        vm.prank(admin);
        factory.deactivateWallet(BID);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: deactivateWallet()", used);
        assertLt(used, DEACTIVATE_CEILING, "deactivateWallet() regressed");
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// REGRESSION TESTS
// ═════════════════════════════════════════════════════════════════════════════

contract WalletFactoryRegression is Test {
    BusinessWallet impl;
    WalletFactory  factory;

    address admin = makeAddr("admin");
    address pool  = makeAddr("pool");

    bytes32 constant BID  = keccak256("biz-reg-1");
    bytes32 constant BID2 = keccak256("biz-reg-2");

    function setUp() public {
        impl    = new BusinessWallet();
        factory = new WalletFactory(admin, address(impl), pool, address(0));
    }

    function test_regression_setPoolWallet_doesNotRetroactivelyUpdate() public {
        vm.prank(admin);
        address w1 = factory.createWallet(BID, admin);
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        factory.setPoolWallet(newPool);
        vm.prank(admin);
        address w2 = factory.createWallet(BID2, admin);
        assertEq(BusinessWallet(payable(w1)).poolWallet(), pool,    "existing wallet pool unchanged");
        assertEq(BusinessWallet(payable(w2)).poolWallet(), newPool, "new wallet uses new pool");
    }

    function test_regression_adminKeepsRole() public {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_regression_beaconOwnedByAdmin_notFactory() public {
        UpgradeableBeacon beacon = UpgradeableBeacon(factory.walletBeacon());
        assertEq(beacon.owner(), admin);
        assertTrue(beacon.owner() != address(factory));
    }

    function test_regression_businessIdFrozen() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        assertEq(BusinessWallet(payable(w)).businessId(), BID);
    }

    function test_regression_factoryIsSweeper_multipleWallets() public {
        bytes32[] memory bids = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            bids[i] = keccak256(abi.encode("multi-sweep", i));
            vm.prank(admin);
            factory.createWallet(bids[i], admin);
        }
        for (uint256 i; i < 5; ++i) {
            BusinessWallet bw = BusinessWallet(payable(factory.walletOf(bids[i])));
            assertTrue(bw.hasRole(bw.SWEEPER_ROLE(), address(factory)));
        }
    }

    function test_regression_failedDeploy_doesNotIncrementCounter() public {
        assertEq(factory.totalWallets(), 0);
        vm.prank(admin);
        vm.expectRevert("WF: zero admin");
        factory.createWallet(BID, address(0));
        assertEq(factory.totalWallets(), 0);
    }

    function test_regression_getWallets_zeroLimit_returnsEmpty() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(0, 0);
        assertEq(recs.length, 0);
    }

    function test_regression_beaconUpgrade_preservesWalletState() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        BusinessWallet bw = BusinessWallet(payable(w));
        bytes32 bidBefore  = bw.businessId();
        address poolBefore = bw.poolWallet();
        UpgradeableBeacon beacon = UpgradeableBeacon(factory.walletBeacon());
        // Deploy new impl before setting prank — CREATE would consume it otherwise.
        address newImplAddr = address(new BusinessWallet());
        vm.prank(admin);
        beacon.upgradeTo(newImplAddr);
        assertEq(bw.businessId(),  bidBefore);
        assertEq(bw.poolWallet(), poolBefore);
        assertTrue(bw.hasRole(bw.DEFAULT_ADMIN_ROLE(), admin));
    }
}
