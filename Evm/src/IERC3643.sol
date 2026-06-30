// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIdentityRegistry
 * @notice Minimal ERC-3643 identity registry interface.
 *         Maps investor wallet → ONCHAINID contract + country code.
 */
interface IIdentityRegistry {
    function isVerified(address _userAddress) external view returns (bool);
    function identity(address _userAddress) external view returns (address);
    function investorCountry(address _userAddress) external view returns (uint16);
    function registerIdentity(address _userAddress, address _identity, uint16 _country) external;
    function deleteIdentity(address _userAddress) external;
    function updateCountry(address _userAddress, uint16 _country) external;
    function updateIdentity(address _userAddress, address _identity) external;

    event IdentityRegistered(address indexed investorAddress, address indexed identity);
    event IdentityRemoved(address indexed investorAddress, address indexed identity);
    event CountryUpdated(address indexed investorAddress, uint16 indexed country);
}

/**
 * @title ICompliance
 * @notice ERC-3643 compliance module interface.
 *         Called by the token on every transfer to enforce offering rules.
 */
interface ICompliance {
    function canTransfer(address _from, address _to, uint256 _amount) external view returns (bool);
    function canHold(address _user) external view returns (bool);
    function transferred(address _from, address _to, uint256 _amount) external;
    function created(address _to, uint256 _amount) external;
    function destroyed(address _from, uint256 _amount) external;
    function bindToken(address _token) external;

    event TokenBound(address indexed token);
}

/**
 * @title IBondTerms
 * @notice Minimal read interface of the BondTerms contract for cross-contract use.
 */
interface IBondTerms {
    function maturityDate() external view returns (uint256);
    function faceValuePerToken() external view returns (uint256);
    function nextCouponDate() external view returns (uint256);
    function gracePeriodSeconds() external view returns (uint256);
    function couponPerToken() external view returns (uint256);
    function isCouponDue() external view returns (bool);
    function isInGraceBreach() external view returns (bool);
    function isMatured() external view returns (bool);
    function defaulted() external view returns (bool);
    function principalRepaid() external view returns (bool);
    function advanceCoupon() external;
    function markDefaulted() external;
    function markPrincipalRepaid() external;
}

/**
 * @title IERC3643
 * @notice Core ERC-3643 token interface.
 */
interface IERC3643 {
    // ── ERC-20 base ──────────────────────────────────────────────
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address _account) external view returns (uint256);
    function transfer(address _to, uint256 _amount) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool);

    // ── ERC-3643 extensions ───────────────────────────────────────
    function identityRegistry() external view returns (IIdentityRegistry);
    function compliance() external view returns (ICompliance);
    function paused() external view returns (bool);
    function isFrozen(address _userAddress) external view returns (bool);
    function getFrozenTokens(address _userAddress) external view returns (uint256);

    function setIdentityRegistry(address _identityRegistry) external;
    function setCompliance(address _compliance) external;
    function pause() external;
    function unpause() external;
    function setAddressFrozen(address _userAddress, bool _freeze) external;
    function freezePartialTokens(address _userAddress, uint256 _amount) external;
    function unfreezePartialTokens(address _userAddress, uint256 _amount) external;

    function mint(address _to, uint256 _amount) external;
    function burn(address _userAddress, uint256 _amount) external;
    function forcedTransfer(address _from, address _to, uint256 _amount) external returns (bool);
    function recoveryAddress(address _lostWallet, address _newWallet, address _investorOnchainID) external returns (bool);

    function batchTransfer(address[] calldata _toList, uint256[] calldata _amounts) external;
    function batchForcedTransfer(address[] calldata _fromList, address[] calldata _toList, uint256[] calldata _amounts) external;
    function batchMint(address[] calldata _toList, uint256[] calldata _amounts) external;
    function batchBurn(address[] calldata _userAddresses, uint256[] calldata _amounts) external;
    function batchSetAddressFrozen(address[] calldata _userAddresses, bool[] calldata _freeze) external;
    function batchFreezePartialTokens(address[] calldata _userAddresses, uint256[] calldata _amounts) external;
    function batchUnfreezePartialTokens(address[] calldata _userAddresses, uint256[] calldata _amounts) external;

    event UpdatedTokenInformation(string indexed newName, string indexed newSymbol, uint8 newDecimals, string newVersion, address indexed newOnchainID);
    event IdentityRegistryAdded(address indexed identityRegistry);
    event ComplianceAdded(address indexed compliance);
    event RecoverySuccess(address indexed lostWallet, address indexed newWallet, address indexed investorOnchainID);
    event AddressFrozen(address indexed userAddress, bool indexed isFrozen, address indexed owner);
    event TokensFrozen(address indexed userAddress, uint256 amount);
    event TokensUnfrozen(address indexed userAddress, uint256 amount);
    event Paused(address indexed userAddress);
    event Unpaused(address indexed userAddress);
}
