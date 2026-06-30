// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

contract IdentityRegistryTest is BaseTest {
    IdentityRegistry registry;

    address admin   = address(this);
    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address charlie = address(0xC4A);
    address nobody  = address(0xDEAD);

    address aliceID   = address(0x1001);
    address bobID     = address(0x1002);
    address charlieID = address(0x1003);

    uint16 constant COUNTRY_NG = 566;
    uint16 constant COUNTRY_US = 840;

    function setUp() public {
        _deployBeacons();
        registry = _makeIR(admin);
    }

    // ── registerIdentity ──────────────────────────────────────────

    function test_registerIdentity_success() public {
        vm.expectEmit(true, true, false, false);
        emit IIdentityRegistry.IdentityRegistered(alice, aliceID);

        registry.registerIdentity(alice, aliceID, COUNTRY_NG);

        assertEq(registry.identity(alice), aliceID);
        assertEq(registry.investorCountry(alice), COUNTRY_NG);
        assertTrue(registry.isVerified(alice));
        assertEq(registry.investorCount(), 1);
    }

    function testRevert_registerIdentity_zeroWallet() public {
        vm.expectRevert("IR: zero wallet");
        registry.registerIdentity(address(0), aliceID, COUNTRY_NG);
    }

    function testRevert_registerIdentity_alreadyRegistered() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        vm.expectRevert("IR: already registered");
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
    }

    function testRevert_registerIdentity_notAgent() public {
        vm.prank(nobody);
        vm.expectRevert();
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
    }

    // ── deleteIdentity ────────────────────────────────────────────

    function test_deleteIdentity_last() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);

        vm.expectEmit(true, true, false, false);
        emit IIdentityRegistry.IdentityRemoved(alice, aliceID);

        registry.deleteIdentity(alice);

        assertFalse(registry.isVerified(alice));
        assertEq(registry.investorCount(), 0);
        assertEq(registry.identity(alice), address(0));
    }

    function test_deleteIdentity_middle() public {
        registry.registerIdentity(alice,   aliceID,   COUNTRY_NG);
        registry.registerIdentity(bob,     bobID,     COUNTRY_US);
        registry.registerIdentity(charlie, charlieID, COUNTRY_NG);

        registry.deleteIdentity(bob);

        assertEq(registry.investorCount(), 2);
        assertFalse(registry.isVerified(bob));
        assertTrue(registry.isVerified(alice));
        assertTrue(registry.isVerified(charlie));
    }

    function test_deleteIdentity_swapAndPop_first() public {
        registry.registerIdentity(alice,   aliceID,   COUNTRY_NG);
        registry.registerIdentity(bob,     bobID,     COUNTRY_US);

        registry.deleteIdentity(alice);

        assertEq(registry.investorCount(), 1);
        assertFalse(registry.isVerified(alice));
        assertTrue(registry.isVerified(bob));
    }

    function testRevert_deleteIdentity_notRegistered() public {
        vm.expectRevert("IR: not registered");
        registry.deleteIdentity(alice);
    }

    function testRevert_deleteIdentity_notAgent() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        vm.prank(nobody);
        vm.expectRevert();
        registry.deleteIdentity(alice);
    }

    // ── updateCountry ─────────────────────────────────────────────

    function test_updateCountry_success() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);

        vm.expectEmit(true, true, false, false);
        emit IIdentityRegistry.CountryUpdated(alice, COUNTRY_US);

        registry.updateCountry(alice, COUNTRY_US);
        assertEq(registry.investorCountry(alice), COUNTRY_US);
    }

    function testRevert_updateCountry_notRegistered() public {
        vm.expectRevert("IR: not registered");
        registry.updateCountry(alice, COUNTRY_US);
    }

    function testRevert_updateCountry_notAgent() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        vm.prank(nobody);
        vm.expectRevert();
        registry.updateCountry(alice, COUNTRY_US);
    }

    // ── updateIdentity ────────────────────────────────────────────

    function test_updateIdentity_success() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        address newID = address(0x9999);

        vm.expectEmit(true, true, false, false);
        emit IIdentityRegistry.IdentityRegistered(alice, newID);

        registry.updateIdentity(alice, newID);
        assertEq(registry.identity(alice), newID);
    }

    function testRevert_updateIdentity_notRegistered() public {
        vm.expectRevert("IR: not registered");
        registry.updateIdentity(alice, address(0x9999));
    }

    function testRevert_updateIdentity_notAgent() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        vm.prank(nobody);
        vm.expectRevert();
        registry.updateIdentity(alice, address(0x9999));
    }

    // ── setVerified ───────────────────────────────────────────────

    function test_setVerified_false() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        assertTrue(registry.isVerified(alice));

        registry.setVerified(alice, false);
        assertFalse(registry.isVerified(alice));
    }

    function test_setVerified_true() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        registry.setVerified(alice, false);
        registry.setVerified(alice, true);
        assertTrue(registry.isVerified(alice));
    }

    function testRevert_setVerified_notRegistered() public {
        vm.expectRevert("IR: not registered");
        registry.setVerified(alice, false);
    }

    function testRevert_setVerified_notAgent() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        vm.prank(nobody);
        vm.expectRevert();
        registry.setVerified(alice, false);
    }

    // ── isVerified / identity / investorCountry ───────────────────

    function test_isVerified_false_unregistered() public view {
        assertFalse(registry.isVerified(alice));
    }

    function test_identity_returnsOnchainID() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        assertEq(registry.identity(alice), aliceID);
    }

    function test_investorCountry_returnsCountry() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        assertEq(registry.investorCountry(alice), COUNTRY_NG);
    }

    // ── investorCount ─────────────────────────────────────────────

    function test_investorCount_afterRegisterDelete() public {
        assertEq(registry.investorCount(), 0);
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);
        assertEq(registry.investorCount(), 1);
        registry.registerIdentity(bob, bobID, COUNTRY_US);
        assertEq(registry.investorCount(), 2);
        registry.deleteIdentity(alice);
        assertEq(registry.investorCount(), 1);
    }

    // ── getInvestors pagination ───────────────────────────────────

    function test_getInvestors_offset0() public {
        registry.registerIdentity(alice,   aliceID,   COUNTRY_NG);
        registry.registerIdentity(bob,     bobID,     COUNTRY_US);
        registry.registerIdentity(charlie, charlieID, COUNTRY_NG);

        address[] memory result = registry.getInvestors(0, 3);
        assertEq(result.length, 3);
    }

    function test_getInvestors_midOffset() public {
        registry.registerIdentity(alice,   aliceID,   COUNTRY_NG);
        registry.registerIdentity(bob,     bobID,     COUNTRY_US);
        registry.registerIdentity(charlie, charlieID, COUNTRY_NG);

        address[] memory result = registry.getInvestors(1, 2);
        assertEq(result.length, 2);
        assertEq(result[0], bob);
        assertEq(result[1], charlie);
    }

    function test_getInvestors_pastEnd_returnsEmpty() public {
        registry.registerIdentity(alice, aliceID, COUNTRY_NG);

        address[] memory result = registry.getInvestors(10, 5);
        assertEq(result.length, 0);
    }

    function test_getInvestors_limitClamps() public {
        registry.registerIdentity(alice,   aliceID,   COUNTRY_NG);
        registry.registerIdentity(bob,     bobID,     COUNTRY_US);

        address[] memory result = registry.getInvestors(0, 100);
        assertEq(result.length, 2);
    }
}
