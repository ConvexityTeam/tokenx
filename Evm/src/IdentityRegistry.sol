// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./IERC3643.sol";

/**
 * @title IdentityRegistry
 * @notice ERC-3643 identity registry — upgradeable via BeaconProxy.
 *
 *   Storage is upgrade-safe:
 *     - Inherits from OZ's Initializable (proxy/utils) — standard layout
 *     - Own state variables listed below, followed by __gap[46]
 *     - Future versions may add variables by consuming gap slots
 *
 *   EIP-2771: All AGENT_ROLE functions resolve the caller through
 *   _msgSender() so a relayer can submit signed KYC ops on behalf of
 *   an agent who holds no ETH.
 */
contract IdentityRegistry is IIdentityRegistry, AccessControl, Initializable {

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    // ── EIP-2771 ──────────────────────────────────────────────────
    address public trustedForwarder;

    // ── Identity storage ──────────────────────────────────────────
    struct Identity {
        address onchainID;
        uint16  country;
        bool    verified;
    }

    mapping(address => Identity) private _identities;
    address[]                    private _investors;
    mapping(address => uint256)  private _investorIndex; // 1-based

    event InvestorVerified(address indexed investorAddress, bool verified);

    // ── Upgrade safety ────────────────────────────────────────────
    // solhint-disable-next-line var-name-mixedcase
    uint256[46] private __gap;

    /// @dev Prevents the implementation contract from being initialized directly.
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address trustedForwarder_) external initializer {
        require(admin != address(0), "IR: zero admin");
        trustedForwarder = trustedForwarder_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE,         admin);
    }

    // ── EIP-2771 context ──────────────────────────────────────────

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarder;
    }

    function _msgSender() internal view override returns (address sender) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    function _msgData() internal view override returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        }
        return msg.data;
    }

    // ── IIdentityRegistry ─────────────────────────────────────────

    function isVerified(address wallet) external view override returns (bool) {
        return _identities[wallet].verified;
    }

    function identity(address wallet) external view override returns (address) {
        return _identities[wallet].onchainID;
    }

    function investorCountry(address wallet) external view override returns (uint16) {
        return _identities[wallet].country;
    }

    function registerIdentity(
        address wallet,
        address onchainID,
        uint16  country
    ) external override onlyRole(AGENT_ROLE) {
        require(wallet != address(0),              "IR: zero wallet");
        require(_identities[wallet].country == 0,  "IR: already registered");

        _identities[wallet] = Identity({ onchainID: onchainID, country: country, verified: true });
        _investors.push(wallet);
        _investorIndex[wallet] = _investors.length;

        emit IdentityRegistered(wallet, onchainID);
    }

    function deleteIdentity(address wallet) external override onlyRole(AGENT_ROLE) {
        require(_identities[wallet].country != 0, "IR: not registered");

        uint256 idx  = _investorIndex[wallet] - 1;
        address last = _investors[_investors.length - 1];
        _investors[idx]       = last;
        _investorIndex[last]  = idx + 1;
        _investors.pop();
        delete _investorIndex[wallet];

        address id = _identities[wallet].onchainID;
        delete _identities[wallet];

        emit IdentityRemoved(wallet, id);
    }

    function updateCountry(address wallet, uint16 country) external override onlyRole(AGENT_ROLE) {
        require(_identities[wallet].country != 0, "IR: not registered");
        _identities[wallet].country = country;
        emit CountryUpdated(wallet, country);
    }

    function updateIdentity(address wallet, address newOnchainID) external override onlyRole(AGENT_ROLE) {
        require(_identities[wallet].country != 0, "IR: not registered");
        _identities[wallet].onchainID = newOnchainID;
        emit IdentityRegistered(wallet, newOnchainID);
    }

    function setVerified(address wallet, bool verified) external onlyRole(AGENT_ROLE) {
        require(_identities[wallet].country != 0, "IR: not registered");
        _identities[wallet].verified = verified;
        emit InvestorVerified(wallet, verified);
    }

    function investorCount() external view returns (uint256) {
        return _investors.length;
    }

    function getInvestors(uint256 offset, uint256 limit)
        external view returns (address[] memory result)
    {
        uint256 total = _investors.length;
        if (offset >= total) return result;
        uint256 end = offset + limit > total ? total : offset + limit;
        result = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = _investors[i];
        }
    }
}
