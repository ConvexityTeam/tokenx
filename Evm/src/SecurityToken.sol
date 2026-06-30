// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./IERC3643.sol";

/**
 * @title SecurityToken
 * @notice ERC-3643 compliant generic security token (clone-compatible).
 *
 *   Clone pattern: deploy this contract once as an implementation, then use
 *   TokenizationFactory to clone + initialize for each new token.
 *
 *   name() / symbol() are stored in explicit slots (not ERC20 constructor)
 *   so they can be set inside initialize().
 */
contract SecurityToken is ERC20, AccessControl, Pausable, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE  = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ── EIP-2771 meta-transaction support ─────────────────────────
    // Stored as a regular variable (not immutable) so clones can each
    // have their own value set during initialize().
    address public trustedForwarder;

    // ── Overridden name/symbol storage ────────────────────────────
    // ERC20 base stores these in immutable-ish constructor args.
    // We shadow them here so clones can have distinct values.
    string private _tokenName;
    string private _tokenSymbol;

    IIdentityRegistry private _identityRegistry;
    ICompliance       private _compliance;

    mapping(address => bool)    private _frozen;
    mapping(address => uint256) private _frozenTokens;

    string public constant VERSION = "1.0";
    address public onchainID;

    /// @notice Optional bond terms contract. address(0) for non-bond tokens.
    IBondTerms public bondTerms;

    // ── Upgrade safety ────────────────────────────────────────────
    // solhint-disable-next-line var-name-mixedcase
    uint256[41] private __gap;

    event UpdatedTokenInformation(
        string  indexed newName,
        string  indexed newSymbol,
        uint8           newDecimals,
        string          newVersion,
        address indexed newOnchainID
    );
    event IdentityRegistryAdded(address indexed identityRegistry);
    event ComplianceAdded(address indexed compliance);
    event BondTermsBound(address indexed bondTerms);
    event RecoverySuccess(address indexed lostWallet, address indexed newWallet, address indexed investorOnchainID);
    event AddressFrozen(address indexed userAddress, bool indexed isFrozen, address indexed owner);
    event TokensFrozen(address indexed userAddress, uint256 amount);
    event TokensUnfrozen(address indexed userAddress, uint256 amount);
    event PrincipalRedeemed(address indexed investor, uint256 tokenAmount, uint256 principalAmount);

    /// @dev Disables direct initialization of the implementation contract.
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address       onchainID_,
        address       identityRegistry_,
        address       compliance_,
        address       admin,
        address       trustedForwarder_
    ) external initializer {
        require(admin             != address(0), "ST: zero admin");
        require(identityRegistry_ != address(0), "ST: zero registry");
        require(compliance_       != address(0), "ST: zero compliance");

        _tokenName    = name_;
        _tokenSymbol  = symbol_;
        onchainID         = onchainID_;
        _identityRegistry = IIdentityRegistry(identityRegistry_);
        _compliance       = ICompliance(compliance_);
        trustedForwarder  = trustedForwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE,         admin);
        _grantRole(PAUSER_ROLE,        admin);

        emit IdentityRegistryAdded(identityRegistry_);
        emit ComplianceAdded(compliance_);
        emit UpdatedTokenInformation(name_, symbol_, 18, VERSION, onchainID_);
    }

    /// @notice One-shot bind of the bond terms contract (factory calls this).
    function setBondTerms(address terms) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(bondTerms) == address(0), "ST: bond terms already set");
        require(terms != address(0), "ST: zero bond terms");
        bondTerms = IBondTerms(terms);
        emit BondTermsBound(terms);
    }

    // ── ERC20 overrides to use clone-local storage ─────────────────

    function name()   public view override returns (string memory) { return _tokenName; }
    function symbol() public view override returns (string memory) { return _tokenSymbol; }

    // ── ERC-3643 getters ──────────────────────────────────────────

    function identityRegistry() external view returns (IIdentityRegistry) { return _identityRegistry; }
    function compliance()       external view returns (ICompliance)       { return _compliance; }
    function isFrozen(address a) external view returns (bool)             { return _frozen[a]; }
    function getFrozenTokens(address a) external view returns (uint256)   { return _frozenTokens[a]; }

    // ── Admin setters ─────────────────────────────────────────────

    function setIdentityRegistry(address ir) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(ir != address(0), "ST: zero registry");
        _identityRegistry = IIdentityRegistry(ir);
        emit IdentityRegistryAdded(ir);
    }

    function setCompliance(address c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(c != address(0), "ST: zero compliance");
        _compliance = ICompliance(c);
        emit ComplianceAdded(c);
    }

    function setOnchainID(address id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        onchainID = id;
        emit UpdatedTokenInformation(name(), symbol(), 18, VERSION, id);
    }

    // ── Pause ─────────────────────────────────────────────────────

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ── Freeze ────────────────────────────────────────────────────

    function setAddressFrozen(address user, bool freeze) public onlyRole(AGENT_ROLE) {
        _frozen[user] = freeze;
        emit AddressFrozen(user, freeze, _msgSender());
    }

    function freezePartialTokens(address user, uint256 amount) public onlyRole(AGENT_ROLE) {
        require(balanceOf(user) >= _frozenTokens[user] + amount, "ST: freeze exceeds balance");
        _frozenTokens[user] += amount;
        emit TokensFrozen(user, amount);
    }

    function unfreezePartialTokens(address user, uint256 amount) public onlyRole(AGENT_ROLE) {
        require(_frozenTokens[user] >= amount, "ST: amount exceeds frozen");
        _frozenTokens[user] -= amount;
        emit TokensUnfrozen(user, amount);
    }

    // ── Mint / Burn ───────────────────────────────────────────────

    function mint(address to, uint256 amount) public onlyRole(AGENT_ROLE) whenNotPaused {
        require(_identityRegistry.isVerified(to), "ST: recipient not verified");
        require(_compliance.canTransfer(address(0), to, amount), "ST: compliance rejected");
        _mint(to, amount);
        _compliance.created(to, amount);
    }

    function burn(address from, uint256 amount) public onlyRole(AGENT_ROLE) whenNotPaused {
        require(balanceOf(from) - _frozenTokens[from] >= amount, "ST: insufficient unfrozen");
        _burn(from, amount);
        _compliance.destroyed(from, amount);
    }

    // ── Forced transfer ───────────────────────────────────────────

    function _forcedTransferInternal(address from, address to, uint256 amount) internal returns (bool) {
        require(_identityRegistry.isVerified(to), "ST: recipient not verified");
        uint256 freeBalance = balanceOf(from) - _frozenTokens[from];
        require(freeBalance >= amount, "ST: insufficient unfrozen balance");
        _transfer(from, to, amount);
        _compliance.transferred(from, to, amount);
        return true;
    }

    function forcedTransfer(address from, address to, uint256 amount)
        external onlyRole(AGENT_ROLE) whenNotPaused nonReentrant returns (bool)
    {
        return _forcedTransferInternal(from, to, amount);
    }

    // ── Recovery ──────────────────────────────────────────────────

    function recoveryAddress(address lostWallet, address newWallet, address investorOnchainID)
        external onlyRole(AGENT_ROLE) whenNotPaused nonReentrant returns (bool)
    {
        require(investorOnchainID != address(0),         "ST: zero onchainID");
        require(_identityRegistry.identity(lostWallet) == investorOnchainID, "ST: lost wallet mismatch");
        require(_identityRegistry.identity(newWallet)  == investorOnchainID, "ST: new wallet mismatch");
        require(_identityRegistry.isVerified(newWallet), "ST: new wallet not verified");
        uint256 bal = balanceOf(lostWallet);
        _transfer(lostWallet, newWallet, bal);
        _frozenTokens[newWallet] = _frozenTokens[lostWallet];
        delete _frozenTokens[lostWallet];
        _compliance.transferred(lostWallet, newWallet, bal);
        emit RecoverySuccess(lostWallet, newWallet, investorOnchainID);
        return true;
    }

    // ── Bond redemption ───────────────────────────────────────────

    /// @notice Redeem a holder's tokens for principal at maturity. The
    ///         payoutToken funds must already be in this contract (issuer
    ///         deposits them before calling). Burns the holder's tokens and
    ///         transfers principal = balance * faceValuePerToken.
    function redeemAtMaturity(address holder, address payoutToken)
        external onlyRole(AGENT_ROLE) whenNotPaused nonReentrant returns (uint256 principal)
    {
        require(address(bondTerms) != address(0), "ST: no bond terms");
        require(bondTerms.isMatured(),            "ST: not matured");
        require(_compliance.canHold(holder),      "ST: holder not eligible");

        uint256 bal = balanceOf(holder);
        require(bal > 0, "ST: zero balance");

        principal = bal * bondTerms.faceValuePerToken() / 1e18;
        require(principal > 0, "ST: zero principal");

        _burn(holder, bal);
        delete _frozenTokens[holder];
        _compliance.destroyed(holder, bal);

        if (payoutToken == address(0)) {
            (bool ok,) = payable(holder).call{value: principal}("");
            require(ok, "ST: ETH transfer failed");
        } else {
            IERC20(payoutToken).safeTransfer(holder, principal);
        }

        emit PrincipalRedeemed(holder, bal, principal);

        if (totalSupply() == 0) {
            bondTerms.markPrincipalRepaid();
        }
    }

    function batchRedeemAtMaturity(address[] calldata holders, address payoutToken)
        external onlyRole(AGENT_ROLE) whenNotPaused nonReentrant
    {
        require(address(bondTerms) != address(0), "ST: no bond terms");
        require(bondTerms.isMatured(),            "ST: not matured");

        uint256 face = bondTerms.faceValuePerToken();
        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            if (!_compliance.canHold(holder)) continue;
            uint256 bal = balanceOf(holder);
            if (bal == 0) continue;
            uint256 principal = bal * face / 1e18;
            if (principal == 0) continue;

            _burn(holder, bal);
            delete _frozenTokens[holder];
            _compliance.destroyed(holder, bal);

            if (payoutToken == address(0)) {
                (bool ok,) = payable(holder).call{value: principal}("");
                require(ok, "ST: ETH transfer failed");
            } else {
                IERC20(payoutToken).safeTransfer(holder, principal);
            }

            emit PrincipalRedeemed(holder, bal, principal);
        }

        if (totalSupply() == 0) {
            bondTerms.markPrincipalRepaid();
        }
    }

    /// @notice Accept payoutToken funds for principal repayment (or ETH).
    receive() external payable {}

    // ── Batch operations ──────────────────────────────────────────

    function batchTransfer(address[] calldata toList, uint256[] calldata amounts) external whenNotPaused {
        require(toList.length == amounts.length, "ST: length mismatch");
        address sender = _msgSender();
        for (uint256 i = 0; i < toList.length; i++) _compliantTransfer(sender, toList[i], amounts[i]);
    }

    function batchMint(address[] calldata toList, uint256[] calldata amounts)
        external onlyRole(AGENT_ROLE) whenNotPaused
    {
        require(toList.length == amounts.length, "ST: length mismatch");
        for (uint256 i = 0; i < toList.length; i++) mint(toList[i], amounts[i]);
    }

    function batchBurn(address[] calldata users, uint256[] calldata amounts)
        external onlyRole(AGENT_ROLE) whenNotPaused
    {
        require(users.length == amounts.length, "ST: length mismatch");
        for (uint256 i = 0; i < users.length; i++) burn(users[i], amounts[i]);
    }

    function batchForcedTransfer(
        address[] calldata fromList,
        address[] calldata toList,
        uint256[] calldata amounts
    ) external onlyRole(AGENT_ROLE) whenNotPaused nonReentrant {
        require(fromList.length == toList.length && toList.length == amounts.length, "ST: length mismatch");
        for (uint256 i = 0; i < fromList.length; i++) _forcedTransferInternal(fromList[i], toList[i], amounts[i]);
    }

    function batchSetAddressFrozen(address[] calldata users, bool[] calldata freeze)
        external onlyRole(AGENT_ROLE)
    {
        require(users.length == freeze.length, "ST: length mismatch");
        for (uint256 i = 0; i < users.length; i++) setAddressFrozen(users[i], freeze[i]);
    }

    function batchFreezePartialTokens(address[] calldata users, uint256[] calldata amounts)
        external onlyRole(AGENT_ROLE)
    {
        require(users.length == amounts.length, "ST: length mismatch");
        for (uint256 i = 0; i < users.length; i++) freezePartialTokens(users[i], amounts[i]);
    }

    function batchUnfreezePartialTokens(address[] calldata users, uint256[] calldata amounts)
        external onlyRole(AGENT_ROLE)
    {
        require(users.length == amounts.length, "ST: length mismatch");
        for (uint256 i = 0; i < users.length; i++) unfreezePartialTokens(users[i], amounts[i]);
    }

    // ── EIP-2771 context ──────────────────────────────────────────

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == trustedForwarder;
    }

    // When msg.sender is the trusted forwarder the real signer is appended
    // as the last 20 bytes of calldata (EIP-2771 convention).
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

    // ── ERC-20 transfer overrides ─────────────────────────────────

    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        _compliantTransfer(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        public override whenNotPaused returns (bool)
    {
        _spendAllowance(from, _msgSender(), amount);
        _compliantTransfer(from, to, amount);
        return true;
    }

    function _compliantTransfer(address from, address to, uint256 amount) internal {
        require(!_frozen[from] && !_frozen[to],      "ST: wallet frozen");
        require(_identityRegistry.isVerified(from),  "ST: sender not verified");
        require(_identityRegistry.isVerified(to),    "ST: recipient not verified");
        require(balanceOf(from) - _frozenTokens[from] >= amount, "ST: insufficient unfrozen balance");
        require(_compliance.canTransfer(from, to, amount), "ST: compliance check failed");
        _transfer(from, to, amount);
        _compliance.transferred(from, to, amount);
    }
}
