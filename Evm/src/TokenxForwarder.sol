// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// EIP-2771: https://eips.ethereum.org/EIPS/eip-2771
// This forwarder holds zero privileges. Security comes entirely from ECDSA
// signature verification — the relayer can submit but never forge requests.

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TokenxForwarder
 * @notice EIP-2771 meta-transaction forwarder.
 *
 *   Flow:
 *     1. Admin/issuer signs a ForwardRequest off-chain (no ETH needed).
 *     2. A funded relayer wallet calls execute() and pays gas.
 *     3. This contract verifies the ECDSA signature, enforces sequential
 *        nonces, prevents replay, then calls the target with the signer's
 *        address appended to calldata (EIP-2771 convention).
 *     4. SecurityToken reads _msgSender() which extracts the real signer —
 *        so role checks (AGENT_ROLE, DEFAULT_ADMIN_ROLE) pass correctly.
 *
 *   Only addresses with RELAYER_ROLE may call execute(). This is optional
 *   extra hardening — the signature already prevents forgery, but restricting
 *   relayers limits who can front-run or selectively censor requests.
 */
contract TokenxForwarder is EIP712, AccessControl, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    struct ForwardRequest {
        address from;    // signer — the admin/issuer/agent
        address to;      // target contract (SecurityToken, etc.)
        uint256 value;   // ETH to forward (usually 0)
        uint256 gas;     // gas limit for the inner call
        uint256 nonce;   // must equal current on-chain nonce for `from`
        bytes   data;    // calldata to forward
    }

    bytes32 private constant _TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    mapping(address => uint256) private _nonces;

    event MetaTxExecuted(
        address indexed relayer,
        address indexed signer,
        address indexed to,
        bool            success
    );

    constructor(address admin) EIP712("TokenxForwarder", "1") {
        require(admin != address(0), "Forwarder: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RELAYER_ROLE,       admin);
    }

    // ── View ──────────────────────────────────────────────────────

    function getNonce(address from) external view returns (uint256) {
        return _nonces[from];
    }

    /**
     * @notice Verify a ForwardRequest signature off-chain before submitting.
     * @return true if the signature is valid and the nonce matches.
     */
    function verify(ForwardRequest calldata req, bytes calldata signature)
        public view returns (bool)
    {
        address signer = _hashTypedDataV4(
            keccak256(abi.encode(
                _TYPEHASH,
                req.from,
                req.to,
                req.value,
                req.gas,
                req.nonce,
                keccak256(req.data)
            ))
        ).recover(signature);

        return signer == req.from && req.nonce == _nonces[req.from];
    }

    // ── Execution ─────────────────────────────────────────────────

    /**
     * @notice Submit a signed ForwardRequest. Only RELAYER_ROLE may call.
     * @dev Appends req.from (20 bytes) to calldata per EIP-2771 so the
     *      recipient can recover the true sender via _msgSender().
     */
    function execute(ForwardRequest calldata req, bytes calldata signature)
        external payable
        onlyRole(RELAYER_ROLE)
        whenNotPaused
        nonReentrant
        returns (bool success, bytes memory returndata)
    {
        require(verify(req, signature), "Forwarder: invalid sig or nonce");

        _nonces[req.from] = req.nonce + 1;

        // Ensure enough gas is forwarded (63/64 rule, EIP-150).
        require(gasleft() >= (req.gas * 64) / 63, "Forwarder: insufficient gas");

        // Append signer address per EIP-2771.
        (success, returndata) = req.to.call{gas: req.gas, value: req.value}(
            abi.encodePacked(req.data, req.from)
        );

        emit MetaTxExecuted(msg.sender, req.from, req.to, success);
    }

    // ── Admin ─────────────────────────────────────────────────────

    function pause()   external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    receive() external payable {}
}
