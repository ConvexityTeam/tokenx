// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/BusinessWallet.sol";
import "../src/WalletFactory.sol";

contract MockERC20WF is ERC20 {
    constructor() ERC20("MockWF", "MWF") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract WalletFactoryTest is Test {
    BusinessWallet impl;
    WalletFactory  factory;

    address admin    = makeAddr("admin");
    address pool     = makeAddr("pool");
    address user     = makeAddr("user");
    address deployer = makeAddr("deployer");

    bytes32 constant BID  = keccak256("biz-1");
    bytes32 constant BID2 = keccak256("biz-2");
    bytes32 constant BID3 = keccak256("biz-3");

    function setUp() public {
        impl    = new BusinessWallet();
        factory = new WalletFactory(admin, address(impl), pool, address(0));
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_setsState() public {
        assertEq(factory.poolWallet(), pool);
        assertEq(factory.trustedForwarder(), address(0));
        assertTrue(factory.walletBeacon() != address(0));
    }

    function test_constructor_grantsRolesToAdmin() public {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(factory.hasRole(factory.DEPLOYER_ROLE(), admin));
        assertTrue(factory.hasRole(factory.POOL_MANAGER_ROLE(), admin));
        assertTrue(factory.hasRole(factory.PAUSER_ROLE(), admin));
    }

    function test_constructor_beaconOwnedByAdmin() public {
        assertEq(UpgradeableBeacon(factory.walletBeacon()).owner(), admin);
    }

    function test_constructor_beaconPointsToImpl() public {
        assertEq(UpgradeableBeacon(factory.walletBeacon()).implementation(), address(impl));
    }

    function test_constructor_withForwarder() public {
        address fwd = makeAddr("fwd");
        WalletFactory f = new WalletFactory(admin, address(impl), pool, fwd);
        assertEq(f.trustedForwarder(), fwd);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert("WF: zero admin");
        new WalletFactory(address(0), address(impl), pool, address(0));
    }

    function test_constructor_revert_zeroImpl() public {
        vm.expectRevert("WF: zero impl");
        new WalletFactory(admin, address(0), pool, address(0));
    }

    function test_constructor_revert_zeroPool() public {
        vm.expectRevert("WF: zero pool");
        new WalletFactory(admin, address(impl), address(0), address(0));
    }

    // ── createWallet ──────────────────────────────────────────────────────────

    function test_createWallet_deploysProxy() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        assertTrue(w != address(0));
    }

    function test_createWallet_initializedCorrectly() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        BusinessWallet bw = BusinessWallet(payable(w));
        assertEq(bw.businessId(), BID);
        assertEq(bw.poolWallet(), pool);
        assertTrue(bw.hasRole(bw.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_createWallet_factoryHasSweeper() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        BusinessWallet bw = BusinessWallet(payable(w));
        assertTrue(bw.hasRole(bw.SWEEPER_ROLE(), address(factory)));
    }

    function test_createWallet_registersRecord() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        WalletFactory.WalletRecord memory rec = factory.getWallet(BID);
        assertEq(rec.wallet, w);
        assertEq(rec.admin, admin);
        assertEq(rec.deployedBy, admin);
        assertEq(rec.businessId, BID);
        assertTrue(rec.active);
        assertEq(rec.deployedAt, block.timestamp);
    }

    function test_createWallet_emitsWalletDeployed() public {
        vm.prank(admin);
        vm.expectEmit(true, false, true, true);
        emit WalletFactory.WalletDeployed(BID, address(0), admin, admin);
        factory.createWallet(BID, admin);
    }

    function test_createWallet_incrementsTotalWallets() public {
        assertEq(factory.totalWallets(), 0);
        vm.prank(admin);
        factory.createWallet(BID, admin);
        assertEq(factory.totalWallets(), 1);
        vm.prank(admin);
        factory.createWallet(BID2, admin);
        assertEq(factory.totalWallets(), 2);
    }

    function test_createWallet_revert_notDeployer() public {
        vm.prank(user);
        vm.expectRevert();
        factory.createWallet(BID, admin);
    }

    function test_createWallet_revert_whenPaused() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        factory.createWallet(BID, admin);
    }

    function test_createWallet_revert_emptyBusinessId() public {
        vm.prank(admin);
        vm.expectRevert("WF: empty businessId");
        factory.createWallet(bytes32(0), admin);
    }

    function test_createWallet_revert_zeroAdmin() public {
        vm.prank(admin);
        vm.expectRevert("WF: zero admin");
        factory.createWallet(BID, address(0));
    }

    function test_createWallet_revert_duplicateBusinessId() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(admin);
        vm.expectRevert("WF: businessId taken");
        factory.createWallet(BID, admin);
    }

    // ── createWalletDeterministic ─────────────────────────────────────────────

    function test_createWalletDeterministic_deploysAtPredictedAddress() public {
        bytes32 salt = keccak256(abi.encode(BID, 1));
        address predicted = factory.predictWalletAddress(BID, admin, salt);
        vm.prank(admin);
        address deployed = factory.createWalletDeterministic(BID, admin, salt);
        assertEq(deployed, predicted);
    }

    function test_createWalletDeterministic_initializedCorrectly() public {
        bytes32 salt = keccak256(abi.encode(BID, 1));
        vm.prank(admin);
        address w = factory.createWalletDeterministic(BID, admin, salt);
        BusinessWallet bw = BusinessWallet(payable(w));
        assertEq(bw.businessId(), BID);
        assertEq(bw.poolWallet(), pool);
    }

    function test_createWalletDeterministic_registersRecord() public {
        bytes32 salt = keccak256(abi.encode(BID, 1));
        vm.prank(admin);
        address w = factory.createWalletDeterministic(BID, admin, salt);
        WalletFactory.WalletRecord memory rec = factory.getWallet(BID);
        assertEq(rec.wallet, w);
        assertTrue(rec.active);
    }

    function test_createWalletDeterministic_differentSalts_differentAddresses() public {
        bytes32 salt1 = keccak256(abi.encode(BID,  1));
        bytes32 salt2 = keccak256(abi.encode(BID2, 2));
        vm.prank(admin);
        address w1 = factory.createWalletDeterministic(BID, admin, salt1);
        vm.prank(admin);
        address w2 = factory.createWalletDeterministic(BID2, admin, salt2);
        assertTrue(w1 != w2);
    }

    function test_createWalletDeterministic_revert_notDeployer() public {
        vm.prank(user);
        vm.expectRevert();
        factory.createWalletDeterministic(BID, admin, bytes32(0));
    }

    function test_createWalletDeterministic_revert_whenPaused() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        factory.createWalletDeterministic(BID, admin, bytes32(0));
    }

    function test_createWalletDeterministic_revert_emptyBusinessId() public {
        vm.prank(admin);
        vm.expectRevert("WF: empty businessId");
        factory.createWalletDeterministic(bytes32(0), admin, bytes32(0));
    }

    function test_createWalletDeterministic_revert_zeroAdmin() public {
        vm.prank(admin);
        vm.expectRevert("WF: zero admin");
        factory.createWalletDeterministic(BID, address(0), bytes32(0));
    }

    function test_createWalletDeterministic_revert_duplicateBusinessId() public {
        bytes32 salt = keccak256(abi.encode(BID, 1));
        vm.prank(admin);
        factory.createWalletDeterministic(BID, admin, salt);
        vm.prank(admin);
        vm.expectRevert("WF: businessId taken");
        factory.createWalletDeterministic(BID, admin, keccak256(abi.encode(BID, 2)));
    }

    // ── predictWalletAddress ──────────────────────────────────────────────────

    function test_predictWalletAddress_matchesDeployment() public {
        bytes32 salt = keccak256(abi.encode(BID, 42));
        address predicted = factory.predictWalletAddress(BID, admin, salt);
        vm.prank(admin);
        address actual = factory.createWalletDeterministic(BID, admin, salt);
        assertEq(actual, predicted);
    }

    function test_predictWalletAddress_differentParams_differentAddresses() public {
        bytes32 salt = keccak256(abi.encode(BID, 1));
        address p1 = factory.predictWalletAddress(BID,  admin, salt);
        address p2 = factory.predictWalletAddress(BID2, admin, salt);
        assertTrue(p1 != p2);
    }

    // ── sweepWalletETH ────────────────────────────────────────────────────────

    function test_sweepWalletETH_success() public {
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
        uint256 before = pool.balance;
        vm.prank(admin);
        factory.sweepWalletETH(BID);
        assertEq(pool.balance - before, 1 ether);
    }

    function test_sweepWalletETH_revert_notDeployer() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(user);
        vm.expectRevert();
        factory.sweepWalletETH(BID);
    }

    function test_sweepWalletETH_revert_unknownBusinessId() public {
        vm.prank(admin);
        vm.expectRevert("WF: unknown businessId");
        factory.sweepWalletETH(BID);
    }

    // ── sweepWalletTokens ─────────────────────────────────────────────────────

    function test_sweepWalletTokens_success() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        MockERC20WF token = new MockERC20WF();
        token.mint(w, 500e18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        vm.prank(admin);
        factory.sweepWalletTokens(BID, tokens);
        assertEq(token.balanceOf(pool), 500e18);
    }

    function test_sweepWalletTokens_multipleTokens() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        MockERC20WF t1 = new MockERC20WF();
        MockERC20WF t2 = new MockERC20WF();
        t1.mint(w, 100e18);
        t2.mint(w, 200e18);
        address[] memory tokens = new address[](2);
        tokens[0] = address(t1);
        tokens[1] = address(t2);
        vm.prank(admin);
        factory.sweepWalletTokens(BID, tokens);
        assertEq(t1.balanceOf(pool), 100e18);
        assertEq(t2.balanceOf(pool), 200e18);
    }

    function test_sweepWalletTokens_revert_notDeployer() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        address[] memory tokens = new address[](0);
        vm.prank(user);
        vm.expectRevert();
        factory.sweepWalletTokens(BID, tokens);
    }

    function test_sweepWalletTokens_revert_unknownBusinessId() public {
        address[] memory tokens = new address[](0);
        vm.prank(admin);
        vm.expectRevert("WF: unknown businessId");
        factory.sweepWalletTokens(BID, tokens);
    }

    // ── setPoolWallet ─────────────────────────────────────────────────────────

    function test_setPoolWallet_updatesPool() public {
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        factory.setPoolWallet(newPool);
        assertEq(factory.poolWallet(), newPool);
    }

    function test_setPoolWallet_emitsEvent() public {
        address newPool = makeAddr("newPool");
        vm.expectEmit(true, true, false, false);
        emit WalletFactory.PoolWalletUpdated(pool, newPool);
        vm.prank(admin);
        factory.setPoolWallet(newPool);
    }

    function test_setPoolWallet_newWalletsUseNewPool() public {
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        factory.setPoolWallet(newPool);
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        assertEq(BusinessWallet(payable(w)).poolWallet(), newPool);
    }

    function test_setPoolWallet_revert_notPoolManager() public {
        vm.prank(user);
        vm.expectRevert();
        factory.setPoolWallet(makeAddr("newPool"));
    }

    function test_setPoolWallet_revert_zeroPool() public {
        vm.prank(admin);
        vm.expectRevert("WF: zero pool");
        factory.setPoolWallet(address(0));
    }

    // ── deactivateWallet ──────────────────────────────────────────────────────

    function test_deactivateWallet_setsInactive() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(admin);
        factory.deactivateWallet(BID);
        assertFalse(factory.getWallet(BID).active);
    }

    function test_deactivateWallet_emitsEvent() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        vm.expectEmit(true, true, false, false);
        emit WalletFactory.WalletDeactivated(BID, w);
        vm.prank(admin);
        factory.deactivateWallet(BID);
    }

    function test_deactivateWallet_revert_notAdmin() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        vm.prank(user);
        vm.expectRevert();
        factory.deactivateWallet(BID);
    }

    function test_deactivateWallet_revert_unknownBusinessId() public {
        vm.prank(admin);
        vm.expectRevert("WF: unknown businessId");
        factory.deactivateWallet(BID);
    }

    // ── pause / unpause ───────────────────────────────────────────────────────

    function test_pause_setsState() public {
        assertFalse(factory.paused());
        vm.prank(admin);
        factory.pause();
        assertTrue(factory.paused());
    }

    function test_unpause_clearsState() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(admin);
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_pause_revert_notPauser() public {
        vm.prank(user);
        vm.expectRevert();
        factory.pause();
    }

    function test_unpause_revert_notPauser() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(user);
        vm.expectRevert();
        factory.unpause();
    }

    // ── getWallet / walletOf / totalWallets ───────────────────────────────────

    function test_getWallet_returnsFullRecord() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        WalletFactory.WalletRecord memory rec = factory.getWallet(BID);
        assertEq(rec.wallet, w);
        assertEq(rec.admin, admin);
        assertEq(rec.deployedBy, admin);
        assertEq(rec.businessId, BID);
        assertTrue(rec.active);
    }

    function test_getWallet_revert_unknownBusinessId() public {
        vm.expectRevert("WF: unknown businessId");
        factory.getWallet(BID);
    }

    function test_walletOf_returnsAddressForKnown() public {
        vm.prank(admin);
        address w = factory.createWallet(BID, admin);
        assertEq(factory.walletOf(BID), w);
    }

    function test_walletOf_returnsZeroForUnknown() public {
        assertEq(factory.walletOf(BID), address(0));
    }

    function test_totalWallets_startsAtZero() public {
        assertEq(factory.totalWallets(), 0);
    }

    function test_totalWallets_incrementsOnCreate() public {
        vm.prank(admin);
        factory.createWallet(BID, admin);
        assertEq(factory.totalWallets(), 1);
        vm.prank(admin);
        factory.createWallet(BID2, admin);
        assertEq(factory.totalWallets(), 2);
    }

    // ── getWallets pagination ─────────────────────────────────────────────────

    function _deployThree() internal returns (address w1, address w2, address w3) {
        vm.startPrank(admin);
        w1 = factory.createWallet(BID,  admin);
        w2 = factory.createWallet(BID2, admin);
        w3 = factory.createWallet(BID3, admin);
        vm.stopPrank();
    }

    function test_getWallets_fullPage() public {
        (address w1, address w2, address w3) = _deployThree();
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(0, 3);
        assertEq(recs.length, 3);
        assertEq(recs[0].wallet, w1);
        assertEq(recs[1].wallet, w2);
        assertEq(recs[2].wallet, w3);
    }

    function test_getWallets_partialPage() public {
        (address w1, address w2,) = _deployThree();
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(0, 2);
        assertEq(recs.length, 2);
        assertEq(recs[0].wallet, w1);
        assertEq(recs[1].wallet, w2);
    }

    function test_getWallets_offset() public {
        (, address w2, address w3) = _deployThree();
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(1, 10);
        assertEq(recs.length, 2);
        assertEq(recs[0].wallet, w2);
        assertEq(recs[1].wallet, w3);
    }

    function test_getWallets_limitClampedToTotal() public {
        _deployThree();
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(0, 100);
        assertEq(recs.length, 3);
    }

    function test_getWallets_offsetBeyondTotal_emptyArray() public {
        _deployThree();
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(10, 5);
        assertEq(recs.length, 0);
    }

    function test_getWallets_emptyFactory_emptyArray() public {
        WalletFactory.WalletRecord[] memory recs = factory.getWallets(0, 10);
        assertEq(recs.length, 0);
    }

    // ── Role constants ────────────────────────────────────────────────────────

    function test_roleConstants() public {
        assertEq(factory.DEPLOYER_ROLE(),     keccak256("DEPLOYER_ROLE"));
        assertEq(factory.POOL_MANAGER_ROLE(), keccak256("POOL_MANAGER_ROLE"));
        assertEq(factory.PAUSER_ROLE(),       keccak256("PAUSER_ROLE"));
    }

    function test_createWallet_byGrantedDeployer() public {
        bytes32 deployerRole = factory.DEPLOYER_ROLE();
        vm.prank(admin);
        factory.grantRole(deployerRole, deployer);
        vm.prank(deployer);
        address w = factory.createWallet(BID, admin);
        assertTrue(w != address(0));
        assertEq(factory.getWallet(BID).deployedBy, deployer);
    }
}
