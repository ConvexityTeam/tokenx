// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "./helpers/BaseTest.sol";

// ── V2 stub for upgrade tests ─────────────────────────────────────────────────

contract IdentityRegistryV2 is IdentityRegistry {
    function version() external pure returns (string memory) { return "V2"; }
}

// ─────────────────────────────────────────────────────────────────────────────

contract TokenizationFactoryTest is BaseTest {
    TokenizationFactory factory;

    address admin      = address(this);
    address deployer   = address(0xDE91);
    address nobody     = address(0xDEAD);
    address tokenAdmin = address(0xAD1);

    TokenizationFactory.ComplianceParams noLimits = TokenizationFactory.ComplianceParams({
        maxShareholders: 0,
        maxTokensPerInvestor: 0,
        lockUpDuration: 0
    });

    function setUp() public {
        _deployBeacons();
        factory = _makeFactory(admin);
    }

    // ── Constructor ───────────────────────────────────────────────

    function testRevert_constructor_zeroAdmin() public {
        vm.expectRevert("Factory: zero admin");
        new TokenizationFactory(
            address(0),
            address(beaconIR), address(beaconCM), address(beaconST),
            address(beaconYD), address(beaconBT), address(0)
        );
    }

    function testRevert_constructor_zeroIRBeacon() public {
        vm.expectRevert("Factory: zero IR beacon");
        new TokenizationFactory(
            admin,
            address(0), address(beaconCM), address(beaconST),
            address(beaconYD), address(beaconBT), address(0)
        );
    }

    // ── deployToken: SECURITY ─────────────────────────────────────

    function test_deployToken_security_success() public {
        address token = factory.deployToken(
            TokenizationFactory.TokenType.SECURITY,
            "ACME-2025", "Acme Bond", "ACMB",
            address(0), tokenAdmin, noLimits
        );

        assertTrue(token != address(0));
        assertEq(factory.totalDeployments(), 1);

        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("ACME-2025");
        assertEq(rec.token, token);
        assertTrue(rec.identityRegistry != address(0));
        assertTrue(rec.compliance != address(0));
        assertEq(rec.yieldDistributor, address(0));
        assertEq(rec.deployedBy, admin);
        assertEq(uint256(rec.tokenType), uint256(TokenizationFactory.TokenType.SECURITY));

        ComplianceModule cm = ComplianceModule(rec.compliance);
        assertEq(cm.token(), token);
        assertTrue(cm.hasRole(cm.DEFAULT_ADMIN_ROLE(), tokenAdmin));
        assertFalse(cm.hasRole(cm.DEFAULT_ADMIN_ROLE(), address(factory)));
    }

    function test_deployToken_security_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit TokenizationFactory.TokenDeployed(
            "EVT-001",
            TokenizationFactory.TokenType.SECURITY,
            address(0), address(0), address(0), address(0), address(0), admin
        );
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY,
            "EVT-001", "Event Token", "EVT", address(0), tokenAdmin, noLimits
        );
    }

    // ── deployToken: YIELD_BEARING ────────────────────────────────

    function test_deployToken_yieldBearing_success() public {
        address token = factory.deployToken(
            TokenizationFactory.TokenType.YIELD_BEARING,
            "YIELD-001", "Yield Bond", "YBD",
            address(0), tokenAdmin, noLimits
        );

        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("YIELD-001");
        assertEq(rec.token, token);
        assertTrue(rec.yieldDistributor != address(0));
        assertEq(uint256(rec.tokenType), uint256(TokenizationFactory.TokenType.YIELD_BEARING));

        YieldDistributor yd = YieldDistributor(payable(rec.yieldDistributor));
        assertEq(address(yd.shareToken()), token);
    }

    // ── deployToken: input validation reverts ─────────────────────

    function testRevert_deployToken_emptyIssuerId() public {
        vm.expectRevert("Factory: empty issuerId");
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
    }

    function testRevert_deployToken_zeroTokenAdmin() public {
        vm.expectRevert("Factory: zero tokenAdmin");
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "ID-001", "Name", "SYM", address(0), address(0), noLimits
        );
    }

    function testRevert_deployToken_duplicateIssuerId() public {
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "DUP-001", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
        vm.expectRevert("Factory: issuerId taken");
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "DUP-001", "Name2", "SYM2", address(0), tokenAdmin, noLimits
        );
    }

    function testRevert_deployToken_notDeployer() public {
        vm.prank(nobody);
        vm.expectRevert();
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "SOME-ID", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
    }

    function testRevert_deployToken_paused() public {
        factory.pause();
        vm.expectRevert("Pausable: paused");
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "PAUSED-ID", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
    }

    function testRevert_deployToken_bondTypeRejected() public {
        vm.expectRevert("Factory: use deployBond for BOND");
        factory.deployToken(
            TokenizationFactory.TokenType.BOND, "BOND-ID", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
    }

    // ── Registry helpers ──────────────────────────────────────────

    function test_getDeploymentByIndex_success() public {
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "IDX-001", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeploymentByIndex(0);
        assertEq(rec.issuerId, "IDX-001");
    }

    function testRevert_getDeployment_unknownIssuerId() public {
        vm.expectRevert("Factory: unknown issuerId");
        factory.getDeployment("NONEXISTENT");
    }

    function testRevert_getDeploymentByIndex_outOfRange() public {
        vm.expectRevert("Factory: out of range");
        factory.getDeploymentByIndex(0);
    }

    function test_totalDeployments_incrementsCorrectly() public {
        assertEq(factory.totalDeployments(), 0);
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "T1", "Token1", "T1", address(0), tokenAdmin, noLimits
        );
        assertEq(factory.totalDeployments(), 1);
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "T2", "Token2", "T2", address(0), tokenAdmin, noLimits
        );
        assertEq(factory.totalDeployments(), 2);
    }

    // ── Pause / unpause ───────────────────────────────────────────

    function test_pause_success() public {
        factory.pause();
        assertTrue(factory.paused());
    }

    function test_unpause_success() public {
        factory.pause();
        factory.unpause();
        assertFalse(factory.paused());
    }

    function testRevert_pause_nonPauser() public {
        vm.prank(nobody);
        vm.expectRevert();
        factory.pause();
    }

    function testRevert_unpause_nonPauser() public {
        factory.pause();
        vm.prank(nobody);
        vm.expectRevert();
        factory.unpause();
    }

    // ── Role management ───────────────────────────────────────────

    function test_grantDeployerRole() public {
        factory.grantRole(factory.DEPLOYER_ROLE(), deployer);
        assertTrue(factory.hasRole(factory.DEPLOYER_ROLE(), deployer));

        vm.prank(deployer);
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "GRANTED-01", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
        assertEq(factory.totalDeployments(), 1);
    }

    function test_revokeDeployerRole() public {
        factory.grantRole(factory.DEPLOYER_ROLE(), deployer);
        factory.revokeRole(factory.DEPLOYER_ROLE(), deployer);
        assertFalse(factory.hasRole(factory.DEPLOYER_ROLE(), deployer));

        vm.prank(deployer);
        vm.expectRevert();
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "REVOKED-01", "Name", "SYM", address(0), tokenAdmin, noLimits
        );
    }

    function test_adminHasAllRoles() public view {
        assertTrue(factory.hasRole(factory.DEPLOYER_ROLE(), admin));
        assertTrue(factory.hasRole(factory.PAUSER_ROLE(),   admin));
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
    }

    // ── Upgrade tests ─────────────────────────────────────────────

    function test_upgrade_existingProxy_getsNewImplementation() public {
        // Deploy a token so there's a live IdentityRegistry proxy
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "UPG-001", "Upgrade Test", "UPG",
            address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("UPG-001");
        IdentityRegistry existingIR = IdentityRegistry(rec.identityRegistry);

        // Confirm it doesn't have version() yet
        // (low-level call returns empty on missing function)
        (bool ok, ) = address(existingIR).call(abi.encodeWithSignature("version()"));
        assertFalse(ok);

        // Deploy V2 implementation and upgrade the beacon
        IdentityRegistryV2 implV2 = new IdentityRegistryV2();
        beaconIR.upgradeTo(address(implV2));

        // Existing proxy now delegates to V2
        assertEq(IdentityRegistryV2(address(existingIR)).version(), "V2");

        // Existing state is preserved
        vm.prank(tokenAdmin);
        existingIR.registerIdentity(address(0xBEEF), address(0xCAFE), 566);
        assertEq(existingIR.investorCount(), 1);
    }

    function test_upgrade_newProxy_deploysWithNewImplementation() public {
        // Upgrade IR beacon to V2 before deploying a new token
        IdentityRegistryV2 implV2 = new IdentityRegistryV2();
        beaconIR.upgradeTo(address(implV2));

        // Deploy a new token — its IR proxy will use V2 automatically
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "UPG-002", "Post-Upgrade", "PUG",
            address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("UPG-002");

        assertEq(IdentityRegistryV2(rec.identityRegistry).version(), "V2");
    }

    function test_upgrade_doesNotAffectOtherBeacons() public {
        factory.deployToken(
            TokenizationFactory.TokenType.SECURITY, "CROSS-001", "Cross Test", "CRS",
            address(0), tokenAdmin, noLimits
        );
        TokenizationFactory.DeploymentRecord memory rec = factory.getDeployment("CROSS-001");

        // Upgrade IR beacon only
        beaconIR.upgradeTo(address(new IdentityRegistryV2()));

        // IR proxy has version(), CM proxy does NOT
        assertEq(IdentityRegistryV2(rec.identityRegistry).version(), "V2");
        (bool ok, ) = rec.compliance.call(abi.encodeWithSignature("version()"));
        assertFalse(ok);
    }
}
