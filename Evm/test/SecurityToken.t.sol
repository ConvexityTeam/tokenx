// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";

contract SecurityTokenTest is BaseTest {
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

    // Local helpers wrapping BaseTest beacon-based deployers
    function _makeRegistry(address a)  internal returns (IdentityRegistry)  { return _makeIR(a); }
    function _makeCompliance(address a) internal returns (ComplianceModule)  { return _makeCM(a, 0, 0, 0); }

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

    // ── initialize validation ─────────────────────────────────────

    function testRevert_initialize_zeroAdmin() public {
        vm.expectRevert("ST: zero admin");
        _makeST("T", "T", address(0), address(registry), address(compliance), address(0), address(0));
    }

    function testRevert_initialize_zeroRegistry() public {
        vm.expectRevert("ST: zero registry");
        _makeST("T", "T", address(0), address(0), address(compliance), admin, address(0));
    }

    function testRevert_initialize_zeroCompliance() public {
        vm.expectRevert("ST: zero compliance");
        _makeST("T", "T", address(0), address(registry), address(0), admin, address(0));
    }

    function test_initialize_setsState() public view {
        assertEq(address(token.identityRegistry()), address(registry));
        assertEq(address(token.compliance()), address(compliance));
        assertEq(token.onchainID(), address(0));
        assertFalse(token.paused());
    }

    // ── mint ──────────────────────────────────────────────────────

    function test_mint_success() public {
        token.mint(alice, 1000);
        assertEq(token.balanceOf(alice), 1000);
    }

    function testRevert_mint_notVerified() public {
        vm.expectRevert("ST: recipient not verified");
        token.mint(nobody, 1000);
    }

    function testRevert_mint_complianceRejected() public {
        compliance.setMaxShareholders(0);
        compliance.setMaxTokensPerInvestor(100);
        token.mint(alice, 100);
        vm.expectRevert("ST: compliance rejected");
        token.mint(bob, 200);
    }

    function testRevert_mint_notAgent() public {
        vm.prank(nobody);
        vm.expectRevert();
        token.mint(alice, 1000);
    }

    function testRevert_mint_paused() public {
        token.pause();
        vm.expectRevert("Pausable: paused");
        token.mint(alice, 1000);
    }

    // ── burn ──────────────────────────────────────────────────────

    function test_burn_success() public {
        token.mint(alice, 1000);
        token.burn(alice, 400);
        assertEq(token.balanceOf(alice), 600);
    }

    function testRevert_burn_insufficientUnfrozen() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 800);
        vm.expectRevert("ST: insufficient unfrozen");
        token.burn(alice, 500);
    }

    function testRevert_burn_notAgent() public {
        token.mint(alice, 1000);
        vm.prank(nobody);
        vm.expectRevert();
        token.burn(alice, 100);
    }

    function testRevert_burn_paused() public {
        token.mint(alice, 1000);
        token.pause();
        vm.expectRevert("Pausable: paused");
        token.burn(alice, 100);
    }

    // ── transfer ─────────────────────────────────────────────────

    function test_transfer_success() public {
        token.mint(alice, 1000);
        vm.prank(alice);
        token.transfer(bob, 300);
        assertEq(token.balanceOf(alice), 700);
        assertEq(token.balanceOf(bob), 300);
    }

    function testRevert_transfer_frozenSender() public {
        token.mint(alice, 1000);
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert("ST: wallet frozen");
        token.transfer(bob, 100);
    }

    function testRevert_transfer_frozenRecipient() public {
        token.mint(alice, 1000);
        token.setAddressFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert("ST: wallet frozen");
        token.transfer(bob, 100);
    }

    function testRevert_transfer_senderNotVerified() public {
        token.mint(alice, 1000);
        registry.setVerified(alice, false);
        vm.prank(alice);
        vm.expectRevert("ST: sender not verified");
        token.transfer(bob, 100);
    }

    function testRevert_transfer_recipientNotVerified() public {
        token.mint(alice, 1000);
        registry.setVerified(bob, false);
        vm.prank(alice);
        vm.expectRevert("ST: recipient not verified");
        token.transfer(bob, 100);
    }

    function testRevert_transfer_complianceFailed() public {
        token.mint(alice, 1000);
        token.mint(bob, 400);
        compliance.setMaxTokensPerInvestor(400);
        vm.prank(alice);
        vm.expectRevert("ST: compliance check failed");
        token.transfer(bob, 1);
    }

    function testRevert_transfer_paused() public {
        token.mint(alice, 1000);
        token.pause();
        vm.prank(alice);
        vm.expectRevert("Pausable: paused");
        token.transfer(bob, 100);
    }

    function testRevert_transfer_insufficientUnfrozen() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 900);
        vm.prank(alice);
        vm.expectRevert("ST: insufficient unfrozen balance");
        token.transfer(bob, 200);
    }

    // ── transferFrom ──────────────────────────────────────────────

    function test_transferFrom_success() public {
        token.mint(alice, 1000);
        vm.prank(alice);
        token.approve(bob, 500);

        vm.prank(bob);
        token.transferFrom(alice, bob, 300);

        assertEq(token.balanceOf(alice), 700);
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.allowance(alice, bob), 200);
    }

    function testRevert_transferFrom_frozenSender() public {
        token.mint(alice, 1000);
        vm.prank(alice);
        token.approve(bob, 500);
        token.setAddressFrozen(alice, true);

        vm.prank(bob);
        vm.expectRevert("ST: wallet frozen");
        token.transferFrom(alice, bob, 100);
    }

    function testRevert_transferFrom_senderNotVerified() public {
        token.mint(alice, 1000);
        vm.prank(alice);
        token.approve(bob, 500);
        registry.setVerified(alice, false);

        vm.prank(bob);
        vm.expectRevert("ST: sender not verified");
        token.transferFrom(alice, bob, 100);
    }

    function testRevert_transferFrom_recipientNotVerified() public {
        token.mint(alice, 1000);
        vm.prank(alice);
        token.approve(bob, 500);
        registry.setVerified(bob, false);

        vm.prank(bob);
        vm.expectRevert("ST: recipient not verified");
        token.transferFrom(alice, bob, 100);
    }

    function testRevert_transferFrom_paused() public {
        token.mint(alice, 1000);
        vm.prank(alice);
        token.approve(bob, 500);
        token.pause();

        vm.prank(bob);
        vm.expectRevert("Pausable: paused");
        token.transferFrom(alice, bob, 100);
    }

    // ── forcedTransfer ────────────────────────────────────────────

    function test_forcedTransfer_success() public {
        token.mint(alice, 1000);
        token.forcedTransfer(alice, bob, 400);
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
    }

    function testRevert_forcedTransfer_recipientNotVerified() public {
        token.mint(alice, 1000);
        vm.expectRevert("ST: recipient not verified");
        token.forcedTransfer(alice, nobody, 100);
    }

    function testRevert_forcedTransfer_insufficientUnfrozen() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 900);
        vm.expectRevert("ST: insufficient unfrozen balance");
        token.forcedTransfer(alice, bob, 500);
    }

    function testRevert_forcedTransfer_notAgent() public {
        token.mint(alice, 1000);
        vm.prank(nobody);
        vm.expectRevert();
        token.forcedTransfer(alice, bob, 100);
    }

    function testRevert_forcedTransfer_paused() public {
        token.mint(alice, 1000);
        token.pause();
        vm.expectRevert("Pausable: paused");
        token.forcedTransfer(alice, bob, 100);
    }

    // ── recoveryAddress ───────────────────────────────────────────

    function test_recoveryAddress_success() public {
        address newAlice = address(0xA2);
        registry.registerIdentity(newAlice, address(0x1001), COUNTRY_NG);

        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 200);

        bool ok = token.recoveryAddress(alice, newAlice, address(0x1001));
        assertTrue(ok);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(newAlice), 1000);
        assertEq(token.getFrozenTokens(newAlice), 200);
        assertEq(token.getFrozenTokens(alice), 0);
    }

    function testRevert_recoveryAddress_newWalletUnregistered() public {
        token.mint(alice, 1000);
        // nobody has no identity registered → identity(nobody) == 0 mismatches 0x1001
        vm.expectRevert("ST: new wallet mismatch");
        token.recoveryAddress(alice, nobody, address(0x1001));
    }

    function testRevert_recoveryAddress_newWalletMismatch() public {
        address newAlice = address(0xA2);
        registry.registerIdentity(newAlice, address(0x9999), COUNTRY_NG);

        token.mint(alice, 1000);
        vm.expectRevert("ST: new wallet mismatch");
        token.recoveryAddress(alice, newAlice, address(0x1001));
    }

    function testRevert_recoveryAddress_lostWalletMismatch() public {
        address newAlice = address(0xA2);
        registry.registerIdentity(newAlice, address(0x1001), COUNTRY_NG);
        token.mint(alice, 1000);
        // alice's registered onchainID is 0x1001, but caller passes 0x9999
        vm.expectRevert("ST: lost wallet mismatch");
        token.recoveryAddress(alice, newAlice, address(0x9999));
    }

    function testRevert_recoveryAddress_zeroOnchainID() public {
        token.mint(alice, 1000);
        vm.expectRevert("ST: zero onchainID");
        token.recoveryAddress(alice, alice, address(0));
    }

    function testRevert_recoveryAddress_newWalletNotVerified() public {
        address newAlice = address(0xA2);
        registry.registerIdentity(newAlice, address(0x1001), COUNTRY_NG);
        registry.setVerified(newAlice, false);

        token.mint(alice, 1000);
        vm.expectRevert("ST: new wallet not verified");
        token.recoveryAddress(alice, newAlice, address(0x1001));
    }

    function testRevert_recoveryAddress_notAgent() public {
        address newAlice = address(0xA2);
        registry.registerIdentity(newAlice, address(0x1001), COUNTRY_NG);
        token.mint(alice, 1000);

        vm.prank(nobody);
        vm.expectRevert();
        token.recoveryAddress(alice, newAlice, address(0x1001));
    }

    // ── setAddressFrozen ──────────────────────────────────────────

    function test_setAddressFrozen_true() public {
        token.setAddressFrozen(alice, true);
        assertTrue(token.isFrozen(alice));
    }

    function test_setAddressFrozen_false() public {
        token.setAddressFrozen(alice, true);
        token.setAddressFrozen(alice, false);
        assertFalse(token.isFrozen(alice));
    }

    function testRevert_setAddressFrozen_notAgent() public {
        vm.prank(nobody);
        vm.expectRevert();
        token.setAddressFrozen(alice, true);
    }

    // ── freezePartialTokens ───────────────────────────────────────

    function test_freezePartialTokens_success() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 300);
        assertEq(token.getFrozenTokens(alice), 300);
    }

    function testRevert_freezePartialTokens_exceedsBalance() public {
        token.mint(alice, 1000);
        vm.expectRevert("ST: freeze exceeds balance");
        token.freezePartialTokens(alice, 1001);
    }

    function testRevert_freezePartialTokens_notAgent() public {
        token.mint(alice, 1000);
        vm.prank(nobody);
        vm.expectRevert();
        token.freezePartialTokens(alice, 100);
    }

    // ── unfreezePartialTokens ─────────────────────────────────────

    function test_unfreezePartialTokens_success() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 500);
        token.unfreezePartialTokens(alice, 200);
        assertEq(token.getFrozenTokens(alice), 300);
    }

    function testRevert_unfreezePartialTokens_exceedsFrozen() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 100);
        vm.expectRevert("ST: amount exceeds frozen");
        token.unfreezePartialTokens(alice, 200);
    }

    function testRevert_unfreezePartialTokens_notAgent() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 100);
        vm.prank(nobody);
        vm.expectRevert();
        token.unfreezePartialTokens(alice, 50);
    }

    // ── pause / unpause ───────────────────────────────────────────

    function test_pause_success() public {
        token.pause();
        assertTrue(token.paused());
    }

    function test_unpause_success() public {
        token.pause();
        token.unpause();
        assertFalse(token.paused());
    }

    function testRevert_pause_nonPauser() public {
        vm.prank(nobody);
        vm.expectRevert();
        token.pause();
    }

    function testRevert_unpause_nonPauser() public {
        token.pause();
        vm.prank(nobody);
        vm.expectRevert();
        token.unpause();
    }

    // ── setIdentityRegistry / setCompliance ───────────────────────

    function test_setIdentityRegistry_success() public {
        IdentityRegistry newReg = _makeRegistry(admin);
        token.setIdentityRegistry(address(newReg));
        assertEq(address(token.identityRegistry()), address(newReg));
    }

    function testRevert_setIdentityRegistry_zeroAddress() public {
        vm.expectRevert("ST: zero registry");
        token.setIdentityRegistry(address(0));
    }

    function testRevert_setIdentityRegistry_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        token.setIdentityRegistry(address(registry));
    }

    function test_setCompliance_success() public {
        ComplianceModule newComp = _makeCompliance(admin);
        token.setCompliance(address(newComp));
        assertEq(address(token.compliance()), address(newComp));
    }

    function testRevert_setCompliance_zeroAddress() public {
        vm.expectRevert("ST: zero compliance");
        token.setCompliance(address(0));
    }

    function testRevert_setCompliance_nonAdmin() public {
        vm.prank(nobody);
        vm.expectRevert();
        token.setCompliance(address(compliance));
    }

    // ── setOnchainID ──────────────────────────────────────────────

    function test_setOnchainID_emitsEvent() public {
        address newID = address(0xBEEF);
        vm.expectEmit(false, false, false, false);
        emit SecurityToken.UpdatedTokenInformation("Test Token", "TT", 18, "1.0", newID);
        token.setOnchainID(newID);
        assertEq(token.onchainID(), newID);
    }

    // ── Batch operations ──────────────────────────────────────────

    function test_batchMint_success() public {
        address[] memory to      = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        to[0] = alice; amounts[0] = 100;
        to[1] = bob;   amounts[1] = 200;

        token.batchMint(to, amounts);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 200);
    }

    function testRevert_batchMint_lengthMismatch() public {
        address[] memory to      = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert("ST: length mismatch");
        token.batchMint(to, amounts);
    }

    function test_batchBurn_success() public {
        token.mint(alice, 500);
        token.mint(bob, 500);

        address[] memory users   = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = alice; amounts[0] = 100;
        users[1] = bob;   amounts[1] = 200;

        token.batchBurn(users, amounts);
        assertEq(token.balanceOf(alice), 400);
        assertEq(token.balanceOf(bob), 300);
    }

    function testRevert_batchBurn_lengthMismatch() public {
        address[] memory users   = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert("ST: length mismatch");
        token.batchBurn(users, amounts);
    }

    function test_batchTransfer_success() public {
        token.mint(alice, 1000);
        address[] memory to      = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        to[0] = bob;     amounts[0] = 100;
        to[1] = charlie; amounts[1] = 200;

        vm.prank(alice);
        token.batchTransfer(to, amounts);
        assertEq(token.balanceOf(alice), 700);
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.balanceOf(charlie), 200);
    }

    function testRevert_batchTransfer_lengthMismatch() public {
        address[] memory to      = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert("ST: length mismatch");
        token.batchTransfer(to, amounts);
    }

    function test_batchForcedTransfer_success() public {
        token.mint(alice, 500);
        token.mint(bob, 500);

        address[] memory froms   = new address[](2);
        address[] memory tos     = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        froms[0] = alice; tos[0] = charlie; amounts[0] = 100;
        froms[1] = bob;   tos[1] = charlie; amounts[1] = 200;

        token.batchForcedTransfer(froms, tos, amounts);
        assertEq(token.balanceOf(charlie), 300);
    }

    function testRevert_batchForcedTransfer_lengthMismatch() public {
        address[] memory froms   = new address[](2);
        address[] memory tos     = new address[](1);
        uint256[] memory amounts = new uint256[](2);
        vm.expectRevert("ST: length mismatch");
        token.batchForcedTransfer(froms, tos, amounts);
    }

    function test_batchSetAddressFrozen_success() public {
        address[] memory users  = new address[](2);
        bool[]    memory freeze = new bool[](2);
        users[0] = alice; freeze[0] = true;
        users[1] = bob;   freeze[1] = false;

        token.batchSetAddressFrozen(users, freeze);
        assertTrue(token.isFrozen(alice));
        assertFalse(token.isFrozen(bob));
    }

    function testRevert_batchSetAddressFrozen_lengthMismatch() public {
        address[] memory users  = new address[](2);
        bool[]    memory freeze = new bool[](1);
        vm.expectRevert("ST: length mismatch");
        token.batchSetAddressFrozen(users, freeze);
    }

    function test_batchFreezePartialTokens_success() public {
        token.mint(alice, 1000);
        token.mint(bob, 1000);

        address[] memory users   = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = alice; amounts[0] = 300;
        users[1] = bob;   amounts[1] = 400;

        token.batchFreezePartialTokens(users, amounts);
        assertEq(token.getFrozenTokens(alice), 300);
        assertEq(token.getFrozenTokens(bob), 400);
    }

    function testRevert_batchFreezePartialTokens_lengthMismatch() public {
        address[] memory users   = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert("ST: length mismatch");
        token.batchFreezePartialTokens(users, amounts);
    }

    function test_batchUnfreezePartialTokens_success() public {
        token.mint(alice, 1000);
        token.freezePartialTokens(alice, 500);

        address[] memory users   = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = alice; amounts[0] = 200;

        token.batchUnfreezePartialTokens(users, amounts);
        assertEq(token.getFrozenTokens(alice), 300);
    }

    function testRevert_batchUnfreezePartialTokens_lengthMismatch() public {
        address[] memory users   = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.expectRevert("ST: length mismatch");
        token.batchUnfreezePartialTokens(users, amounts);
    }

    // ── Getters ───────────────────────────────────────────────────

    function test_identityRegistry_getter() public view {
        assertEq(address(token.identityRegistry()), address(registry));
    }

    function test_compliance_getter() public view {
        assertEq(address(token.compliance()), address(compliance));
    }

    function test_isFrozen_getter() public {
        assertFalse(token.isFrozen(alice));
        token.setAddressFrozen(alice, true);
        assertTrue(token.isFrozen(alice));
    }

    function test_getFrozenTokens_getter() public {
        token.mint(alice, 1000);
        assertEq(token.getFrozenTokens(alice), 0);
        token.freezePartialTokens(alice, 400);
        assertEq(token.getFrozenTokens(alice), 400);
    }
}
