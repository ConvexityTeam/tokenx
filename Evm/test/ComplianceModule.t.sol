// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

contract ComplianceModuleTest is BaseTest {
    IdentityRegistry registry;
    ComplianceModule compliance;
    SecurityToken    token;

    address admin   = address(this);
    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address charlie = address(0xC4A);
    address nobody  = address(0xDEAD);

    uint16 constant COUNTRY_NG = 566;
    uint16 constant COUNTRY_US = 840;
    uint16 constant COUNTRY_IR = 364;

    // Local helpers wrapping BaseTest beacon-based deployers
    function _makeCompliance(address a, uint256 ms, uint256 mt, uint256 lu)
        internal returns (ComplianceModule) { return _makeCM(a, ms, mt, lu); }
    function _makeToken(string memory n, string memory s, address ir, address cm, address a)
        internal returns (SecurityToken)    { return _makeST(n, s, ir, cm, a); }

    function setUp() public {
        _deployBeacons();
        registry   = _makeIR(admin);
        compliance = _makeCM(admin, 0, 0, 0);
        token      = _makeST("Test Token", "TT", address(registry), address(compliance), admin);
        compliance.bindToken(address(token));

        registry.registerIdentity(alice,   address(0x1001), COUNTRY_NG);
        registry.registerIdentity(bob,     address(0x1002), COUNTRY_US);
        registry.registerIdentity(charlie, address(0x1003), COUNTRY_NG);
    }

    // ── bindToken ─────────────────────────────────────────────────

    function testRevert_bindToken_alreadyBound() public {
        vm.expectRevert("Compliance: already bound");
        compliance.bindToken(address(token));
    }

    function testRevert_bindToken_zeroToken() public {
        ComplianceModule fresh = _makeCompliance(admin, 0, 0, 0);
        vm.expectRevert("Compliance: zero token");
        fresh.bindToken(address(0));
    }

    function testRevert_bindToken_nonAdmin() public {
        ComplianceModule fresh = _makeCompliance(admin, 0, 0, 0);
        vm.prank(nobody);
        vm.expectRevert();
        fresh.bindToken(address(token));
    }

    function test_bindToken_success() public {
        ComplianceModule fresh = _makeCompliance(admin, 0, 0, 0);
        SecurityToken t2 = _makeToken("T2", "T2", address(registry), address(fresh), admin);
        vm.expectEmit(true, false, false, false);
        emit ICompliance.TokenBound(address(t2));
        fresh.bindToken(address(t2));
        assertEq(fresh.token(), address(t2));
    }

    // ── canTransfer: mint (from == 0) ────────────────────────────

    function test_canTransfer_mint_passes() public view {
        assertTrue(compliance.canTransfer(address(0), alice, 100));
    }

    function test_canTransfer_mint_failsMaxShareholders() public {
        compliance.setMaxShareholders(1);
        vm.prank(address(token));
        compliance.created(alice, 100);
        assertFalse(compliance.canTransfer(address(0), bob, 100));
    }

    // ── canTransfer: transfer ─────────────────────────────────────

    function test_canTransfer_transfer_passesAllChecks() public {
        vm.prank(address(token));
        compliance.created(alice, 500);
        assertTrue(compliance.canTransfer(alice, bob, 100));
    }

    function test_canTransfer_blockedCountry_rejectsRecipient() public {
        registry.registerIdentity(nobody, address(0x5555), COUNTRY_IR);
        compliance.blockCountry(COUNTRY_IR);
        assertFalse(compliance.canTransfer(alice, nobody, 100));
    }

    function test_canTransfer_maxTokensPerInvestor_rejects() public {
        compliance.setMaxTokensPerInvestor(500);
        vm.prank(address(token));
        compliance.created(bob, 400);
        assertFalse(compliance.canTransfer(alice, bob, 200));
    }

    function test_canTransfer_maxShareholders_newHolderSenderLeaves() public {
        compliance.setMaxShareholders(1);
        vm.prank(address(token));
        compliance.created(alice, 100);
        assertTrue(compliance.canTransfer(alice, bob, 100));
    }

    function test_canTransfer_maxShareholders_newHolderSenderStays() public {
        compliance.setMaxShareholders(1);
        vm.prank(address(token));
        compliance.created(alice, 200);
        assertFalse(compliance.canTransfer(alice, bob, 100));
    }

    function test_canTransfer_existingHolder_noChange() public {
        compliance.setMaxShareholders(2);
        vm.prank(address(token));
        compliance.created(alice, 200);
        vm.prank(address(token));
        compliance.created(bob, 100);
        assertTrue(compliance.canTransfer(alice, bob, 50));
    }

    function test_canTransfer_lockUp_blocksBeforeExpiry() public {
        ComplianceModule cm = _makeCompliance(admin, 0, 0, 1 days);
        SecurityToken t2 = _makeToken("LT", "LT", address(registry), address(cm), admin);
        cm.bindToken(address(t2));

        vm.prank(address(t2));
        cm.created(alice, 100);
        assertFalse(cm.canTransfer(alice, bob, 50));
    }

    function test_canTransfer_lockUp_allowsAfterExpiry() public {
        ComplianceModule cm = _makeCompliance(admin, 0, 0, 1 days);
        SecurityToken t2 = _makeToken("LT", "LT", address(registry), address(cm), admin);
        cm.bindToken(address(t2));

        vm.prank(address(t2));
        cm.created(alice, 100);
        vm.warp(block.timestamp + 1 days + 1);
        assertTrue(cm.canTransfer(alice, bob, 50));
    }

    function test_canTransfer_burn_alwaysTrue() public view {
        assertTrue(compliance.canTransfer(alice, address(0), 1000));
    }

    // ── transferred ──────────────────────────────────────────────

    function test_transferred_updatesHolderBalance() public {
        vm.startPrank(address(token));
        compliance.created(alice, 300);
        compliance.transferred(alice, bob, 100);
        vm.stopPrank();

        assertEq(compliance.holderBalance(alice), 200);
        assertEq(compliance.holderBalance(bob), 100);
    }

    function test_transferred_shareholderCount_addAndRemove() public {
        vm.startPrank(address(token));
        compliance.created(alice, 100);
        assertEq(compliance.shareholderCount(), 1);
        compliance.transferred(alice, bob, 100);
        assertEq(compliance.shareholderCount(), 1);
        vm.stopPrank();
    }

    function test_transferred_shareholderCount_senderStays() public {
        vm.startPrank(address(token));
        compliance.created(alice, 200);
        assertEq(compliance.shareholderCount(), 1);
        compliance.transferred(alice, bob, 100);
        assertEq(compliance.shareholderCount(), 2);
        vm.stopPrank();
    }

    // ── created ──────────────────────────────────────────────────

    function test_created_updatesBalanceAndCount() public {
        vm.prank(address(token));
        compliance.created(alice, 500);

        assertEq(compliance.holderBalance(alice), 500);
        assertEq(compliance.shareholderCount(), 1);
    }

    function test_created_setsLockUpEnd() public {
        ComplianceModule cm = _makeCompliance(admin, 0, 0, 7 days);
        SecurityToken t2 = _makeToken("LT", "LT", address(registry), address(cm), admin);
        cm.bindToken(address(t2));

        uint256 before = block.timestamp;
        vm.prank(address(t2));
        cm.created(alice, 100);

        assertEq(cm.lockUpEnd(alice), before + 7 days);
    }

    // ── destroyed ────────────────────────────────────────────────

    function test_destroyed_updatesBalance() public {
        vm.startPrank(address(token));
        compliance.created(alice, 500);
        compliance.destroyed(alice, 200);
        vm.stopPrank();

        assertEq(compliance.holderBalance(alice), 300);
        assertEq(compliance.shareholderCount(), 1);
    }

    function test_destroyed_decrementsShareholderCount() public {
        vm.startPrank(address(token));
        compliance.created(alice, 100);
        compliance.destroyed(alice, 100);
        vm.stopPrank();

        assertEq(compliance.holderBalance(alice), 0);
        assertEq(compliance.shareholderCount(), 0);
    }

    // ── onlyToken modifier ────────────────────────────────────────

    function testRevert_transferred_notToken() public {
        vm.prank(nobody);
        vm.expectRevert("Compliance: caller not token");
        compliance.transferred(alice, bob, 100);
    }

    function testRevert_created_notToken() public {
        vm.prank(nobody);
        vm.expectRevert("Compliance: caller not token");
        compliance.created(alice, 100);
    }

    function testRevert_destroyed_notToken() public {
        vm.prank(nobody);
        vm.expectRevert("Compliance: caller not token");
        compliance.destroyed(alice, 100);
    }

    // ── Admin setters ─────────────────────────────────────────────

    function test_setMaxShareholders_success() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceModule.MaxShareholdersUpdated(0, 100);
        compliance.setMaxShareholders(100);
        assertEq(compliance.maxShareholders(), 100);
    }

    function testRevert_setMaxShareholders_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setMaxShareholders(100);
    }

    function test_setMaxTokensPerInvestor_success() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceModule.MaxTokensPerInvestorUpdated(0, 1000);
        compliance.setMaxTokensPerInvestor(1000);
        assertEq(compliance.maxTokensPerInvestor(), 1000);
    }

    function testRevert_setMaxTokensPerInvestor_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setMaxTokensPerInvestor(1000);
    }

    function test_setLockUpDuration_success() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceModule.LockUpDurationUpdated(0, 30 days);
        compliance.setLockUpDuration(30 days);
        assertEq(compliance.lockUpDuration(), 30 days);
    }

    function testRevert_setLockUpDuration_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setLockUpDuration(30 days);
    }

    function test_blockCountry_success() public {
        vm.expectEmit(true, false, false, false);
        emit ComplianceModule.CountryBlocked(COUNTRY_IR);
        compliance.blockCountry(COUNTRY_IR);
        assertTrue(compliance.blockedCountries(COUNTRY_IR));
    }

    function testRevert_blockCountry_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.blockCountry(COUNTRY_IR);
    }

    function test_unblockCountry_success() public {
        compliance.blockCountry(COUNTRY_IR);
        vm.expectEmit(true, false, false, false);
        emit ComplianceModule.CountryUnblocked(COUNTRY_IR);
        compliance.unblockCountry(COUNTRY_IR);
        assertFalse(compliance.blockedCountries(COUNTRY_IR));
    }

    function testRevert_unblockCountry_nonAdmin() public {
        compliance.blockCountry(COUNTRY_IR);
        vm.prank(nobody);
        vm.expectRevert();
        compliance.unblockCountry(COUNTRY_IR);
    }
}
