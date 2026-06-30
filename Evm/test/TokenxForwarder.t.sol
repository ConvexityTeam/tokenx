// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./helpers/BaseTest.sol";
import "../src/TokenxForwarder.sol";

/**
 * @notice Tests for EIP-2771 meta-transaction flow.
 *
 *   Key scenario: an admin (agent) holds AGENT_ROLE but no ETH.
 *   A relayer wallet has ETH but no contract roles.
 *   The relayer submits a signed mint request on behalf of the admin.
 */
contract TokenxForwarderTest is BaseTest {

    TokenxForwarder forwarder;
    SecurityToken   token;

    // Wallets
    address relayer = makeAddr("relayer");
    address tokenAdmin;
    uint256 tokenAdminKey;
    address investor = makeAddr("investor");

    // EIP-712 domain separator components (must match forwarder constructor)
    bytes32 constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 constant REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function setUp() public {
        (tokenAdmin, tokenAdminKey) = makeAddrAndKey("tokenAdmin");

        // Deploy forwarder — tokenAdmin is also the forwarder admin
        forwarder = new TokenxForwarder(tokenAdmin);

        // Grant relayer role to the relayer wallet
        bytes32 relayerRole = forwarder.RELAYER_ROLE();
        vm.prank(tokenAdmin);
        forwarder.grantRole(relayerRole, relayer);

        // Deploy SecurityToken with the forwarder as trusted forwarder
        _deployBeacons();
        IdentityRegistry ir = _makeIR(tokenAdmin, address(forwarder));
        ComplianceModule cm = _makeCM(tokenAdmin, 0, 0, 0, address(forwarder));
        token = _makeST("Test Token", "TST", address(0), address(ir), address(cm), tokenAdmin, address(forwarder));

        vm.startPrank(tokenAdmin);
        cm.bindToken(address(token));
        ir.registerIdentity(investor, investor, 840);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────

    function _buildAndSign(
        address from,
        uint256 fromKey,
        address to,
        bytes memory data
    ) internal view returns (TokenxForwarder.ForwardRequest memory req, bytes memory sig) {
        req = TokenxForwarder.ForwardRequest({
            from:  from,
            to:    to,
            value: 0,
            gas:   200_000,
            nonce: forwarder.getNonce(from),
            data:  data
        });

        bytes32 structHash = keccak256(abi.encode(
            REQUEST_TYPEHASH,
            req.from,
            req.to,
            req.value,
            req.gas,
            req.nonce,
            keccak256(req.data)
        ));

        bytes32 domainSep = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("TokenxForwarder"),
            keccak256("1"),
            block.chainid,
            address(forwarder)
        ));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // ── Tests ─────────────────────────────────────────────────────

    function test_metaTx_mint_success() public {
        // Admin signs a mint call but has no ETH — relayer submits it
        bytes memory data = abi.encodeCall(SecurityToken.mint, (investor, 1000e18));
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(tokenAdmin, tokenAdminKey, address(token), data);

        assertEq(token.balanceOf(investor), 0);

        vm.prank(relayer);
        (bool success,) = forwarder.execute(req, sig);
        assertTrue(success);

        assertEq(token.balanceOf(investor), 1000e18);
    }

    function test_nonce_increments_after_execution() public {
        assertEq(forwarder.getNonce(tokenAdmin), 0);

        bytes memory data = abi.encodeCall(SecurityToken.mint, (investor, 1e18));
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(tokenAdmin, tokenAdminKey, address(token), data);

        vm.prank(relayer);
        forwarder.execute(req, sig);

        assertEq(forwarder.getNonce(tokenAdmin), 1);
    }

    function test_replay_reverts() public {
        bytes memory data = abi.encodeCall(SecurityToken.mint, (investor, 1e18));
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(tokenAdmin, tokenAdminKey, address(token), data);

        vm.prank(relayer);
        forwarder.execute(req, sig);

        // Same request replayed — nonce already incremented, so verify() fails first
        vm.prank(relayer);
        vm.expectRevert("Forwarder: invalid sig or nonce");
        forwarder.execute(req, sig);
    }

    function test_wrong_nonce_reverts() public {
        bytes memory data = abi.encodeCall(SecurityToken.mint, (investor, 1e18));
        TokenxForwarder.ForwardRequest memory req = TokenxForwarder.ForwardRequest({
            from:  tokenAdmin,
            to:    address(token),
            value: 0,
            gas:   200_000,
            nonce: 99,    // wrong nonce
            data:  data
        });

        bytes32 structHash = keccak256(abi.encode(
            REQUEST_TYPEHASH,
            req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
        ));
        bytes32 domainSep = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("TokenxForwarder"),
            keccak256("1"),
            block.chainid,
            address(forwarder)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(tokenAdminKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        vm.expectRevert("Forwarder: invalid sig or nonce");
        forwarder.execute(req, sig);
    }

    function test_unauthorized_relayer_reverts() public {
        address rogue = makeAddr("rogue");
        bytes memory data = abi.encodeCall(SecurityToken.mint, (investor, 1e18));
        (TokenxForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(tokenAdmin, tokenAdminKey, address(token), data);

        vm.prank(rogue);
        vm.expectRevert();
        forwarder.execute(req, sig);
    }

    function test_forged_signature_reverts() public {
        (, uint256 rogueKey) = makeAddrAndKey("rogue");
        bytes memory data = abi.encodeCall(SecurityToken.mint, (investor, 1e18));

        TokenxForwarder.ForwardRequest memory req = TokenxForwarder.ForwardRequest({
            from:  tokenAdmin,    // claims to be admin
            to:    address(token),
            value: 0,
            gas:   200_000,
            nonce: forwarder.getNonce(tokenAdmin),
            data:  data
        });

        bytes32 structHash = keccak256(abi.encode(
            REQUEST_TYPEHASH,
            req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
        ));
        bytes32 domainSep = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256("TokenxForwarder"),
            keccak256("1"),
            block.chainid,
            address(forwarder)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(rogueKey, digest);  // signed by rogue, not admin
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        vm.expectRevert("Forwarder: invalid sig or nonce");
        forwarder.execute(req, sig);
    }

    function test_direct_call_without_forwarder_still_works() public {
        // Confirm existing direct calls are unaffected
        vm.prank(tokenAdmin);
        token.mint(investor, 500e18);
        assertEq(token.balanceOf(investor), 500e18);
    }
}
