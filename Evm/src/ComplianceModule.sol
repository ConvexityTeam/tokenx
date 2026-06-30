// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./IERC3643.sol";

/**
 * @title ComplianceModule
 * @notice ERC-3643 compliance enforcement — upgradeable via BeaconProxy.
 *
 *   EIP-2771: COMPLIANCE_ADMIN and DEFAULT_ADMIN functions resolve the
 *   caller through _msgSender(), enabling gasless compliance management.
 *   The onlyToken modifier keeps a raw msg.sender check — the token
 *   contract itself calls transferred/created/destroyed, never through
 *   the forwarder.
 */
contract ComplianceModule is ICompliance, AccessControl, Initializable {

    bytes32 public constant COMPLIANCE_ADMIN = keccak256("COMPLIANCE_ADMIN");

    // ── EIP-2771 ──────────────────────────────────────────────────
    address public trustedForwarder;

    // ── State ─────────────────────────────────────────────────────
    address public token;
    uint256 public maxShareholders;
    uint256 public maxTokensPerInvestor;
    uint256 public lockUpDuration;

    mapping(uint16  => bool)    public blockedCountries;
    uint256                     public shareholderCount;
    mapping(address => uint256) public holderBalance;
    mapping(address => uint256) public lockUpEnd;

    bool                        public walletAllowlistEnabled;
    mapping(address => bool)    public walletAllowlist;
    bool                        public countryAllowlistMode;
    mapping(uint16  => bool)    public allowedCountries;

    // ── Upgrade safety ────────────────────────────────────────────
    // solhint-disable-next-line var-name-mixedcase
    uint256[38] private __gap;

    event MaxShareholdersUpdated(uint256 oldMax, uint256 newMax);
    event MaxTokensPerInvestorUpdated(uint256 oldMax, uint256 newMax);
    event LockUpDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event CountryBlocked(uint16 indexed country);
    event CountryUnblocked(uint16 indexed country);
    event WalletAllowlistEnabled(bool enabled);
    event WalletAllowlisted(address indexed wallet, bool allowed);
    event CountryAllowlistModeSet(bool enabled);
    event CountryAllowed(uint16 indexed country, bool allowed);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        uint256 _maxShareholders,
        uint256 _maxTokensPerInvestor,
        uint256 _lockUpDuration,
        address trustedForwarder_
    ) external initializer {
        require(admin != address(0), "Compliance: zero admin");
        trustedForwarder     = trustedForwarder_;
        maxShareholders      = _maxShareholders;
        maxTokensPerInvestor = _maxTokensPerInvestor;
        lockUpDuration       = _lockUpDuration;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN,   admin);
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

    // ── ICompliance ───────────────────────────────────────────────

    function bindToken(address _token) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token == address(0), "Compliance: already bound");
        require(_token != address(0), "Compliance: zero token");
        token = _token;
        emit TokenBound(_token);
    }

    function canTransfer(address from, address to, uint256 amount)
        external view override returns (bool)
    {
        if (to == address(0)) return true;
        if (!_passesHoldChecks(to)) return false;

        if (maxTokensPerInvestor > 0) {
            if (holderBalance[to] + amount > maxTokensPerInvestor) return false;
        }
        if (maxShareholders > 0) {
            if (holderBalance[to] == 0) {
                if (from == address(0)) {
                    if (shareholderCount + 1 > maxShareholders) return false;
                } else {
                    uint256 senderAfter = holderBalance[from] > amount
                        ? holderBalance[from] - amount : 0;
                    uint256 projected = shareholderCount + 1 - (senderAfter > 0 ? 0 : 1);
                    if (projected > maxShareholders) return false;
                }
            }
        }
        if (from != address(0)) {
            if (block.timestamp < lockUpEnd[from]) return false;
        }
        return true;
    }

    function canHold(address user) external view override returns (bool) {
        if (user == address(0)) return false;
        return _passesHoldChecks(user);
    }

    function _passesHoldChecks(address user) internal view returns (bool) {
        if (walletAllowlistEnabled && !walletAllowlist[user]) return false;
        if (token != address(0)) {
            IIdentityRegistry ir = IERC3643(token).identityRegistry();
            uint16 country = ir.investorCountry(user);
            if (countryAllowlistMode) {
                if (!allowedCountries[country]) return false;
            } else {
                if (blockedCountries[country]) return false;
            }
        }
        return true;
    }

    // raw msg.sender — called by the token contract itself, never through forwarder
    modifier onlyToken() {
        require(msg.sender == token, "Compliance: caller not token");
        _;
    }

    function transferred(address from, address to, uint256 amount) external override onlyToken {
        if (from != address(0)) {
            holderBalance[from] = holderBalance[from] >= amount
                ? holderBalance[from] - amount : 0;
            if (holderBalance[from] == 0 && shareholderCount > 0) shareholderCount--;
        }
        if (to != address(0)) {
            if (holderBalance[to] == 0) shareholderCount++;
            holderBalance[to] += amount;
        }
    }

    function created(address to, uint256 amount) external override onlyToken {
        if (holderBalance[to] == 0) shareholderCount++;
        holderBalance[to] += amount;
        if (lockUpDuration > 0) lockUpEnd[to] = block.timestamp + lockUpDuration;
    }

    function destroyed(address from, uint256 amount) external override onlyToken {
        holderBalance[from] = holderBalance[from] >= amount
            ? holderBalance[from] - amount : 0;
        if (holderBalance[from] == 0 && shareholderCount > 0) shareholderCount--;
    }

    // ── Admin ─────────────────────────────────────────────────────

    function setMaxShareholders(uint256 newMax) external onlyRole(COMPLIANCE_ADMIN) {
        emit MaxShareholdersUpdated(maxShareholders, newMax);
        maxShareholders = newMax;
    }

    function setMaxTokensPerInvestor(uint256 newMax) external onlyRole(COMPLIANCE_ADMIN) {
        emit MaxTokensPerInvestorUpdated(maxTokensPerInvestor, newMax);
        maxTokensPerInvestor = newMax;
    }

    function setLockUpDuration(uint256 newDuration) external onlyRole(COMPLIANCE_ADMIN) {
        emit LockUpDurationUpdated(lockUpDuration, newDuration);
        lockUpDuration = newDuration;
    }

    function blockCountry(uint16 country) external onlyRole(COMPLIANCE_ADMIN) {
        blockedCountries[country] = true;
        emit CountryBlocked(country);
    }

    function unblockCountry(uint16 country) external onlyRole(COMPLIANCE_ADMIN) {
        blockedCountries[country] = false;
        emit CountryUnblocked(country);
    }

    function setWalletAllowlistEnabled(bool enabled) external onlyRole(COMPLIANCE_ADMIN) {
        walletAllowlistEnabled = enabled;
        emit WalletAllowlistEnabled(enabled);
    }

    function setWalletAllowed(address wallet, bool allowed) external onlyRole(COMPLIANCE_ADMIN) {
        walletAllowlist[wallet] = allowed;
        emit WalletAllowlisted(wallet, allowed);
    }

    function batchSetWalletAllowed(address[] calldata wallets, bool allowed)
        external onlyRole(COMPLIANCE_ADMIN)
    {
        for (uint256 i = 0; i < wallets.length; i++) {
            walletAllowlist[wallets[i]] = allowed;
            emit WalletAllowlisted(wallets[i], allowed);
        }
    }

    function setCountryAllowlistMode(bool enabled) external onlyRole(COMPLIANCE_ADMIN) {
        countryAllowlistMode = enabled;
        emit CountryAllowlistModeSet(enabled);
    }

    function setCountryAllowed(uint16 country, bool allowed) external onlyRole(COMPLIANCE_ADMIN) {
        allowedCountries[country] = allowed;
        emit CountryAllowed(country, allowed);
    }
}
