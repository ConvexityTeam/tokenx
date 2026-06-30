// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./IERC3643.sol";

/**
 * @title YieldDistributor
 * @notice Compliance-aware yield distributor for ERC-3643 security tokens (clone-compatible).
 *
 *   shareToken / identityRegistry are regular storage vars (not immutable)
 *   so this contract can be used as a clone implementation.
 */
contract YieldDistributor is AccessControl, ReentrancyGuard, Pausable, Initializable {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE  = keccak256("AGENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // EIP-2771: stored (not immutable) so clones can each have their own value.
    address public trustedForwarder;

    IERC3643          public shareToken;
    IIdentityRegistry public identityRegistry;
    ICompliance       public compliance;
    IBondTerms        public bondTerms;

    struct Snapshot {
        uint256 id;
        uint256 blockNumber;
        uint256 timestamp;
        uint256 totalEligibleSupply;
        uint256 totalFunds;
        address payoutToken;
        uint256 reclaimDeadline;
        bool    active;
        bool    scheduled;       // true if produced by createScheduledCoupon
        string  description;
    }

    uint256 public snapshotCount;
    mapping(uint256 => Snapshot) public snapshots;
    mapping(uint256 => mapping(address => uint256)) public snapshotBalance;
    mapping(uint256 => mapping(address => bool))    public claimed;
    mapping(uint256 => uint256)                     public totalClaimed;

    // ── Upgrade safety ────────────────────────────────────────────
    // solhint-disable-next-line var-name-mixedcase
    uint256[40] private __gap;

    event BondTermsBound(address indexed bondTerms);
    event YieldDeposited(uint256 indexed snapshotId, uint256 amount, address payoutToken);
    event SnapshotCreated(uint256 indexed snapshotId, uint256 blockNumber, uint256 totalEligibleSupply, string description);
    event ScheduledCouponCreated(uint256 indexed snapshotId, uint256 couponPerToken, uint256 couponDate);
    event YieldClaimed(uint256 indexed snapshotId, address indexed investor, uint256 amount);
    event YieldPushed(uint256 indexed snapshotId, address indexed investor, uint256 amount);
    event UnclaimedReclaimed(uint256 indexed snapshotId, uint256 amount);
    event InvestorSkipped(uint256 indexed snapshotId, address indexed investor, string reason);
    event IssuerDefaulted(uint256 atTimestamp);

    constructor() {
        _disableInitializers();
    }

    function initialize(address _shareToken, address admin, address trustedForwarder_) external initializer {
        require(_shareToken != address(0), "YD: zero token");
        require(admin       != address(0), "YD: zero admin");

        shareToken       = IERC3643(_shareToken);
        identityRegistry = shareToken.identityRegistry();
        compliance       = shareToken.compliance();
        trustedForwarder = trustedForwarder_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE,         admin);
        _grantRole(PAUSER_ROLE,        admin);
    }

    /// @notice One-shot bind of the bond terms contract (factory calls this).
    function setBondTerms(address terms) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(bondTerms) == address(0), "YD: bond terms already set");
        require(terms != address(0), "YD: zero bond terms");
        bondTerms = IBondTerms(terms);
        emit BondTermsBound(terms);
    }

    function createSnapshot(
        address[] calldata investors,
        address   payoutToken_,
        uint256   fundAmount,
        uint256   reclaimAfter,
        string    calldata description
    ) external payable onlyRole(AGENT_ROLE) whenNotPaused returns (uint256 snapshotId) {

        snapshotId = ++snapshotCount;

        uint256 receivedFunds;
        if (payoutToken_ == address(0)) {
            require(msg.value > 0, "YD: no ETH sent");
            receivedFunds = msg.value;
        } else {
            require(fundAmount > 0, "YD: zero fund amount");
            IERC20(payoutToken_).safeTransferFrom(_msgSender(), address(this), fundAmount);
            receivedFunds = fundAmount;
        }

        uint256 eligibleSupply;
        for (uint256 i = 0; i < investors.length; i++) {
            address inv = investors[i];
            if (!_isEligible(inv)) continue;
            uint256 bal = shareToken.balanceOf(inv);
            if (bal == 0) continue;
            snapshotBalance[snapshotId][inv] = bal;
            eligibleSupply += bal;
        }

        require(eligibleSupply > 0, "YD: no eligible holders");

        snapshots[snapshotId] = Snapshot({
            id:                   snapshotId,
            blockNumber:          block.number,
            timestamp:            block.timestamp,
            totalEligibleSupply:  eligibleSupply,
            totalFunds:           receivedFunds,
            payoutToken:          payoutToken_,
            reclaimDeadline:      block.timestamp + reclaimAfter,
            active:               true,
            scheduled:            false,
            description:          description
        });

        emit SnapshotCreated(snapshotId, block.number, eligibleSupply, description);
        emit YieldDeposited(snapshotId, receivedFunds, payoutToken_);
    }

    /// @notice Create a coupon distribution constrained by BondTerms. The
    ///         issuer must transfer in *exactly* the computed total coupon
    ///         (couponPerToken * eligibleSupply / 1e18); under/over payment
    ///         reverts. Caller must approve `requiredFunds` of payoutToken.
    function createScheduledCoupon(
        address[] calldata investors,
        address   payoutToken_,
        uint256   reclaimAfter,
        string    calldata description
    ) external payable onlyRole(AGENT_ROLE) whenNotPaused returns (uint256 snapshotId) {
        require(address(bondTerms) != address(0), "YD: no bond terms");
        require(bondTerms.isCouponDue(),          "YD: coupon not due");
        require(!bondTerms.defaulted(),           "YD: bond defaulted");
        require(!bondTerms.principalRepaid(),     "YD: bond closed");

        snapshotId = ++snapshotCount;

        uint256 eligibleSupply;
        for (uint256 i = 0; i < investors.length; i++) {
            address inv = investors[i];
            if (!_isEligible(inv)) continue;
            uint256 bal = shareToken.balanceOf(inv);
            if (bal == 0) continue;
            snapshotBalance[snapshotId][inv] = bal;
            eligibleSupply += bal;
        }
        require(eligibleSupply > 0, "YD: no eligible holders");

        uint256 perToken      = bondTerms.couponPerToken();
        uint256 requiredFunds = perToken * eligibleSupply / 1e18;
        require(requiredFunds > 0, "YD: zero coupon");

        if (payoutToken_ == address(0)) {
            require(msg.value == requiredFunds, "YD: wrong ETH amount");
        } else {
            require(msg.value == 0, "YD: ETH not allowed");
            IERC20(payoutToken_).safeTransferFrom(_msgSender(), address(this), requiredFunds);
        }

        snapshots[snapshotId] = Snapshot({
            id:                   snapshotId,
            blockNumber:          block.number,
            timestamp:            block.timestamp,
            totalEligibleSupply:  eligibleSupply,
            totalFunds:           requiredFunds,
            payoutToken:          payoutToken_,
            reclaimDeadline:      block.timestamp + reclaimAfter,
            active:               true,
            scheduled:            true,
            description:          description
        });

        uint256 couponDate = bondTerms.nextCouponDate();
        bondTerms.advanceCoupon();

        emit SnapshotCreated(snapshotId, block.number, eligibleSupply, description);
        emit YieldDeposited(snapshotId, requiredFunds, payoutToken_);
        emit ScheduledCouponCreated(snapshotId, perToken, couponDate);
    }

    /// @notice Anyone can flag the bond as defaulted once the grace period has
    ///         elapsed past a missed coupon. Permissionless on purpose:
    ///         investors should be able to trigger this without the issuer.
    function flagDefault() external {
        require(address(bondTerms) != address(0), "YD: no bond terms");
        require(bondTerms.isInGraceBreach(),      "YD: grace not breached");
        bondTerms.markDefaulted();
        emit IssuerDefaulted(block.timestamp);
    }

    function claimYield(uint256 snapshotId) external nonReentrant whenNotPaused {
        address investor = _msgSender();
        uint256 amount   = _computeClaim(snapshotId, investor);

        claimed[snapshotId][investor] = true;
        totalClaimed[snapshotId]     += amount;

        _pay(snapshots[snapshotId].payoutToken, investor, amount);
        emit YieldClaimed(snapshotId, investor, amount);
    }

    function pushYield(uint256 snapshotId, address[] calldata investors)
        external onlyRole(AGENT_ROLE) nonReentrant whenNotPaused
    {
        Snapshot storage snap = snapshots[snapshotId];
        require(snap.active, "YD: snapshot inactive");

        for (uint256 i = 0; i < investors.length; i++) {
            address inv = investors[i];
            if (claimed[snapshotId][inv]) continue;
            if (!_isEligible(inv)) {
                emit InvestorSkipped(snapshotId, inv, "not eligible at payout time");
                continue;
            }
            uint256 bal = snapshotBalance[snapshotId][inv];
            if (bal == 0) continue;
            uint256 amount = (bal * snap.totalFunds) / snap.totalEligibleSupply;
            if (amount == 0) continue;

            claimed[snapshotId][inv] = true;
            totalClaimed[snapshotId] += amount;

            _pay(snap.payoutToken, inv, amount);
            emit YieldPushed(snapshotId, inv, amount);
        }
    }

    function reclaimUnclaimed(uint256 snapshotId)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        Snapshot storage snap = snapshots[snapshotId];
        require(snap.active, "YD: already reclaimed");
        require(block.timestamp >= snap.reclaimDeadline, "YD: deadline not reached");

        uint256 unclaimed = snap.totalFunds - totalClaimed[snapshotId];
        require(unclaimed > 0, "YD: nothing to reclaim");

        snap.active = false;
        _pay(snap.payoutToken, _msgSender(), unclaimed);
        emit UnclaimedReclaimed(snapshotId, unclaimed);
    }

    function pendingYield(uint256 snapshotId, address investor) external view returns (uint256) {
        if (claimed[snapshotId][investor]) return 0;
        uint256 bal = snapshotBalance[snapshotId][investor];
        if (bal == 0) return 0;
        Snapshot storage snap = snapshots[snapshotId];
        return (bal * snap.totalFunds) / snap.totalEligibleSupply;
    }

    function getSnapshot(uint256 snapshotId) external view returns (Snapshot memory) {
        return snapshots[snapshotId];
    }

    function _isEligible(address investor) internal view returns (bool) {
        if (!identityRegistry.isVerified(investor)) return false;
        if (shareToken.isFrozen(investor))          return false;
        if (!compliance.canHold(investor))          return false;
        return true;
    }

    function _computeClaim(uint256 snapshotId, address investor) internal view returns (uint256) {
        Snapshot storage snap = snapshots[snapshotId];
        require(snap.active,                    "YD: snapshot inactive");
        require(!claimed[snapshotId][investor], "YD: already claimed");
        require(_isEligible(investor),          "YD: not eligible");
        uint256 bal = snapshotBalance[snapshotId][investor];
        require(bal > 0,                        "YD: no balance at snapshot");
        return (bal * snap.totalFunds) / snap.totalEligibleSupply;
    }

    function _pay(address payoutToken_, address to, uint256 amount) internal {
        if (payoutToken_ == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "YD: ETH transfer failed");
        } else {
            IERC20(payoutToken_).safeTransfer(to, amount);
        }
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

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    receive() external payable {}
}
