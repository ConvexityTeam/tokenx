// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

/**
 * @title AllowlistTest
 * @notice Covers ComplianceModule wallet + country allowlists and the
 *         `canHold` view that yield/redemption flows consult.
 *
 *         The denylist and rule-cap behaviors are covered in
 *         ComplianceModule.t.sol — this file focuses on the new allowlist
 *         knobs and their interaction with canTransfer / canHold.
 */
contract AllowlistTest is BaseTest {
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
    uint16 constant COUNTRY_GH = 288;
    uint16 constant COUNTRY_IR = 364;

    function setUp() public {
        _deployBeacons();
        registry   = _makeIR(admin);
        compliance = _makeCM(admin, 0, 0, 0);
        token      = _makeST("Test", "TT", address(registry), address(compliance), admin);
        compliance.bindToken(address(token));

        registry.registerIdentity(alice,   address(0x1001), COUNTRY_NG);
        registry.registerIdentity(bob,     address(0x1002), COUNTRY_US);
        registry.registerIdentity(charlie, address(0x1003), COUNTRY_GH);
    }

    // ── Wallet allowlist: enable/disable ──────────────────────────

    function test_walletAllowlist_defaultOff() public view {
        assertFalse(compliance.walletAllowlistEnabled());
        // When off, canHold returns true even for un-allowlisted wallets
        assertTrue(compliance.canHold(alice));
        assertTrue(compliance.canHold(bob));
    }

    function test_setWalletAllowlistEnabled_flipsOn() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceModule.WalletAllowlistEnabled(true);
        compliance.setWalletAllowlistEnabled(true);
        assertTrue(compliance.walletAllowlistEnabled());
    }

    function test_setWalletAllowlistEnabled_flipsOff() public {
        compliance.setWalletAllowlistEnabled(true);
        compliance.setWalletAllowlistEnabled(false);
        assertFalse(compliance.walletAllowlistEnabled());
    }

    function testRevert_setWalletAllowlistEnabled_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setWalletAllowlistEnabled(true);
    }

    // ── Wallet allowlist: enforcement via canHold ─────────────────

    function test_canHold_returnsFalseWhenEnabledAndNotListed() public {
        compliance.setWalletAllowlistEnabled(true);
        assertFalse(compliance.canHold(alice));
        assertFalse(compliance.canHold(bob));
    }

    function test_canHold_returnsTrueWhenAllowlisted() public {
        compliance.setWalletAllowlistEnabled(true);
        compliance.setWalletAllowed(alice, true);
        assertTrue(compliance.canHold(alice));
        assertFalse(compliance.canHold(bob));
    }

    function test_canHold_zeroAddressFalse() public view {
        assertFalse(compliance.canHold(address(0)));
    }

    // ── Wallet allowlist: enforcement via canTransfer ─────────────

    function test_canTransfer_blockedWhenRecipientNotAllowlisted() public {
        compliance.setWalletAllowlistEnabled(true);
        compliance.setWalletAllowed(alice, true);  // sender allowlisted
        // bob is not allowlisted — transfer rejected
        assertFalse(compliance.canTransfer(alice, bob, 100));
    }

    function test_canTransfer_allowedWhenRecipientAllowlisted() public {
        compliance.setWalletAllowlistEnabled(true);
        compliance.setWalletAllowed(alice, true);
        compliance.setWalletAllowed(bob,   true);
        assertTrue(compliance.canTransfer(alice, bob, 100));
    }

    function test_canTransfer_mintRespectsAllowlist() public {
        compliance.setWalletAllowlistEnabled(true);
        // alice not allowlisted, minting to alice should fail
        assertFalse(compliance.canTransfer(address(0), alice, 100));
        compliance.setWalletAllowed(alice, true);
        assertTrue(compliance.canTransfer(address(0), alice, 100));
    }

    function test_canTransfer_burnAlwaysPasses() public {
        compliance.setWalletAllowlistEnabled(true);
        // alice not allowlisted, but burns (to zero) still pass
        assertTrue(compliance.canTransfer(alice, address(0), 100));
    }

    // ── setWalletAllowed ─────────────────────────────────────────

    function test_setWalletAllowed_addAndRemove() public {
        vm.expectEmit(true, false, false, true);
        emit ComplianceModule.WalletAllowlisted(alice, true);
        compliance.setWalletAllowed(alice, true);
        assertTrue(compliance.walletAllowlist(alice));

        vm.expectEmit(true, false, false, true);
        emit ComplianceModule.WalletAllowlisted(alice, false);
        compliance.setWalletAllowed(alice, false);
        assertFalse(compliance.walletAllowlist(alice));
    }

    function test_setWalletAllowed_pre_populateBeforeEnable() public {
        // You can stage the allowlist before enabling enforcement
        compliance.setWalletAllowed(alice, true);
        assertTrue(compliance.walletAllowlist(alice));
        assertFalse(compliance.walletAllowlistEnabled());
        // canHold passes because enforcement is off
        assertTrue(compliance.canHold(alice));
    }

    function testRevert_setWalletAllowed_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setWalletAllowed(alice, true);
    }

    // ── batchSetWalletAllowed ────────────────────────────────────

    function test_batchSetWalletAllowed_addsAll() public {
        address[] memory list = new address[](3);
        list[0] = alice;
        list[1] = bob;
        list[2] = charlie;

        compliance.batchSetWalletAllowed(list, true);

        assertTrue(compliance.walletAllowlist(alice));
        assertTrue(compliance.walletAllowlist(bob));
        assertTrue(compliance.walletAllowlist(charlie));
    }

    function test_batchSetWalletAllowed_removesAll() public {
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        compliance.batchSetWalletAllowed(list, true);

        compliance.batchSetWalletAllowed(list, false);

        assertFalse(compliance.walletAllowlist(alice));
        assertFalse(compliance.walletAllowlist(bob));
    }

    function test_batchSetWalletAllowed_emitsPerWallet() public {
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;

        vm.expectEmit(true, false, false, true);
        emit ComplianceModule.WalletAllowlisted(alice, true);
        vm.expectEmit(true, false, false, true);
        emit ComplianceModule.WalletAllowlisted(bob, true);
        compliance.batchSetWalletAllowed(list, true);
    }

    function testRevert_batchSetWalletAllowed_nonAdmin() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(nobody);
        vm.expectRevert();
        compliance.batchSetWalletAllowed(list, true);
    }

    // ── Country allowlist: mode toggle ───────────────────────────

    function test_countryAllowlistMode_defaultOff() public view {
        assertFalse(compliance.countryAllowlistMode());
    }

    function test_setCountryAllowlistMode_flipsOn() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceModule.CountryAllowlistModeSet(true);
        compliance.setCountryAllowlistMode(true);
        assertTrue(compliance.countryAllowlistMode());
    }

    function testRevert_setCountryAllowlistMode_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setCountryAllowlistMode(true);
    }

    // ── Country allowlist: emptiness blocks everyone ──────────────

    function test_countryAllowlist_emptyBlocksEveryone() public {
        compliance.setCountryAllowlistMode(true);
        // No countries allowed — every verified investor is rejected
        assertFalse(compliance.canHold(alice));
        assertFalse(compliance.canHold(bob));
        assertFalse(compliance.canHold(charlie));
        assertFalse(compliance.canTransfer(alice, bob, 100));
    }

    // ── Country allowlist: enforcement ────────────────────────────

    function test_setCountryAllowed_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ComplianceModule.CountryAllowed(COUNTRY_NG, true);
        compliance.setCountryAllowed(COUNTRY_NG, true);
        assertTrue(compliance.allowedCountries(COUNTRY_NG));
    }

    function test_countryAllowlist_permitsListedCountry() public {
        compliance.setCountryAllowed(COUNTRY_NG, true);
        compliance.setCountryAllowlistMode(true);
        assertTrue(compliance.canHold(alice));    // NG
        assertFalse(compliance.canHold(bob));     // US (not allowed)
        assertFalse(compliance.canHold(charlie)); // GH (not allowed)
    }

    function test_countryAllowlist_multipleCountries() public {
        compliance.setCountryAllowed(COUNTRY_NG, true);
        compliance.setCountryAllowed(COUNTRY_GH, true);
        compliance.setCountryAllowlistMode(true);
        assertTrue(compliance.canHold(alice));    // NG
        assertTrue(compliance.canHold(charlie));  // GH
        assertFalse(compliance.canHold(bob));     // US
    }

    function test_countryAllowlist_removeCountryBlocksHolders() public {
        compliance.setCountryAllowed(COUNTRY_NG, true);
        compliance.setCountryAllowlistMode(true);
        assertTrue(compliance.canHold(alice));

        compliance.setCountryAllowed(COUNTRY_NG, false);
        assertFalse(compliance.canHold(alice));
    }

    function testRevert_setCountryAllowed_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        compliance.setCountryAllowed(COUNTRY_NG, true);
    }

    // ── Mode-switching: denylist ↔ allowlist ──────────────────────

    function test_modeSwitch_denylistThenAllowlist() public {
        // Start in denylist mode: block IR
        compliance.blockCountry(COUNTRY_IR);
        assertTrue(compliance.canHold(alice));   // NG: not blocked
        assertTrue(compliance.canHold(bob));     // US: not blocked

        // Flip to allowlist mode — every country needs explicit allow
        compliance.setCountryAllowlistMode(true);
        assertFalse(compliance.canHold(alice));
        assertFalse(compliance.canHold(bob));

        // Allow NG only
        compliance.setCountryAllowed(COUNTRY_NG, true);
        assertTrue(compliance.canHold(alice));
        assertFalse(compliance.canHold(bob));

        // Flip back to denylist — alice was the only one blocked by allowlist;
        // now only IR is blocked again
        compliance.setCountryAllowlistMode(false);
        assertTrue(compliance.canHold(alice));
        assertTrue(compliance.canHold(bob));
    }

    function test_blockedCountriesNotConsultedInAllowlistMode() public {
        // Block NG (denylist) but also allow NG (allowlist). Allowlist mode wins
        // because in allowlist mode the denylist isn't consulted.
        compliance.blockCountry(COUNTRY_NG);
        compliance.setCountryAllowed(COUNTRY_NG, true);
        compliance.setCountryAllowlistMode(true);
        assertTrue(compliance.canHold(alice));
    }

    // ── Composition: wallet + country allowlists together ─────────

    function test_both_walletAndCountryAllowlists_required() public {
        compliance.setWalletAllowlistEnabled(true);
        compliance.setCountryAllowlistMode(true);
        compliance.setCountryAllowed(COUNTRY_NG, true);

        // alice is NG but not wallet-allowlisted → rejected
        assertFalse(compliance.canHold(alice));

        // wallet-allowlist alice → still need country pass (NG already allowed)
        compliance.setWalletAllowed(alice, true);
        assertTrue(compliance.canHold(alice));

        // wallet-allowlist bob but US isn't on country allowlist → rejected
        compliance.setWalletAllowed(bob, true);
        assertFalse(compliance.canHold(bob));
    }

    // ── canTransfer: combined wallet + country gates ──────────────

    function test_canTransfer_walletAllowlistBlocksTransfer() public {
        compliance.setWalletAllowlistEnabled(true);
        compliance.setWalletAllowed(alice, true);
        // bob not allowlisted → transfer to bob fails even though everything else passes
        assertFalse(compliance.canTransfer(alice, bob, 100));
        compliance.setWalletAllowed(bob, true);
        assertTrue(compliance.canTransfer(alice, bob, 100));
    }
}
