// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexRule} from "./interfaces/IIndexRule.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {IRebalanceExecutor} from "./interfaces/IRebalanceExecutor.sol";

/// @title IndexToken
/// @notice Fully collateralized index token with fixed constituents whose units follow an on-chain weighting rule.
///         See {IIndexToken}.
/// @dev Deployed as an EIP-1167 clone by {IndexFactory}. The implementation is deployed from the factory constructor,
///      so `FACTORY` and `RULE` can be immutables (immutables live in bytecode, which clones delegate to, so every clone
///      sees the same values).
///
///      The storage-based {ReentrancyGuard} is used deliberately: its namespaced slot reads as "not entered" when zero,
///      so it needs no initializer and is safe in a clone. Every function that mints, burns, pays a claim or changes a
///      rebalance shares it.
///
///      Only an initialized clone can issue, redeem or rebalance. The implementation and any clone deployed outside the
///      factory have no components and would otherwise mint unbacked shares.
///
///      Invariant, for every component i:
///          token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
///      Issue rounds up and redeem rounds down, so rounding drift is at most one raw unit per call and is always in
///      favour of the remaining holders. A claim is recorded only for an amount that stayed in the index, so claims
///      never dilute other holders. Nothing is ever computed from balances, so there is no share price to manipulate
///      and no first-depositor attack.
///
///      Rebalancing. Once MIN_REBALANCE_INTERVAL has passed, anyone can snapshot the rule's target units. After
///      REBALANCE_DELAY of notice, an auction runs for AUCTION_DURATION. The executor receives what the index no longer
///      needs of every shrinking component, and must send back what the growing components need. The multiplier
///      scales only the growing components' extra units: it opens at AUCTION_START_MULTIPLIER, so an executor first has
///      to deliver more value than it takes, and falls linearly to AUCTION_END_MULTIPLIER. Transfer amounts come from
///      supply and units alone, and the settlement stands only if the invariant holds with the new units. Prices
///      never enter this step.
contract IndexToken is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ReentrancyGuard, IIndexToken {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;
    uint256 public constant REBALANCE_DELAY = 2 days;
    uint256 public constant MIN_REBALANCE_INTERVAL = 28 days;
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant AUCTION_START_MULTIPLIER = 1.5e18;
    uint256 public constant AUCTION_END_MULTIPLIER = 0.9e18;
    uint256 public constant MIN_TURNOVER = 0.005e18;
    /// @dev AUCTION_END_MULTIPLIER, less 5% for the gap between the rule's feed price, which moves only when the
    ///      feed publishes, and the spot an executor trades at. See _checkSettlementValue.
    uint256 public constant MIN_SETTLEMENT_RATIO = 0.85e18;
    address public immutable FACTORY;
    address public immutable RULE;

    uint256 private constant WAD = 1e18;

    struct Component {
        address token;
        uint96 units;
    }

    /// @dev `eta == 0` means no rebalance is pending.
    struct PendingRebalance {
        uint40 eta;
        uint24 keepMask;
    }

    Component[] private _components;

    /// @inheritdoc IIndexToken
    mapping(address account => mapping(address token => uint256 amount)) public claimOf;

    /// @inheritdoc IIndexToken
    mapping(address token => uint256 amount) public totalClaims;

    PendingRebalance private _pending;
    uint96[] private _targetUnits;

    /// @inheritdoc IIndexToken
    uint256 public proposalCount;

    /// @inheritdoc IIndexToken
    uint256 public rebalanceNonce;

    /// @inheritdoc IIndexToken
    uint256 public lastRebalance;

    /// @inheritdoc IIndexToken
    uint256 public restartAllowedAt;

    /// @inheritdoc IIndexToken
    uint8 public methodology;

    modifier onlyInitialized() {
        _checkInitialized();
        _;
    }

    constructor(address rule) {
        if (rule == address(0)) revert ZeroAddress();
        FACTORY = msg.sender;
        RULE = rule;
        _disableInitializers();
    }

    /// @inheritdoc IIndexToken
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology_
    ) external initializer {
        if (msg.sender != FACTORY) revert NotFactory();
        uint256 n = tokens.length;
        if (n == 0 || n != units.length) revert InvalidComponents();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == address(0) || units[i] == 0) revert InvalidComponents();
            _components.push(Component({token: tokens[i], units: SafeCast.toUint96(units[i])}));
        }
        methodology = methodology_;
        // Set once at creation, in the same transaction as the factory's IndexCreated event.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        lastRebalance = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Issue / redeem / claim
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexToken
    function issue(uint256 shares, address to) external nonReentrant onlyInitialized {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);

        // Effects and event first, then pull the basket. The transfer check below makes the
        // mint conditional on receiving every component in full.
        uint256[] memory amounts = _amounts(shares, Math.Rounding.Ceil);
        _mint(to, shares);
        // `_mint` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Issued(msg.sender, to, shares, amounts);

        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            // Rejects fee-on-transfer / deflationary tokens even if a whitelisted token changes behaviour.
            if (token.balanceOf(address(this)) - before < amounts[i]) {
                revert TransferAmountMismatch(address(token));
            }
        }
    }

    /// @inheritdoc IIndexToken
    function redeem(uint256 shares, address to) external nonReentrant onlyInitialized {
        _redeem(shares, to, 0);
    }

    /// @inheritdoc IIndexToken
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external nonReentrant onlyInitialized {
        if (skipMask == 0 || skipMask >> _components.length != 0) revert InvalidSkipMask(skipMask);
        _redeem(shares, to, skipMask);
    }

    /// @inheritdoc IIndexToken
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        amount = claimOf[msg.sender][token];
        if (amount == 0) revert NothingToClaim(token);

        delete claimOf[msg.sender][token];
        totalClaims[token] -= amount;
        emit Claimed(msg.sender, to, token, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Burns first, books every skipped component as a claim, then transfers the rest.
    function _redeem(uint256 shares, address to, uint256 skipMask) private {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);

        uint256[] memory amounts = _amounts(shares, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        // `_burn` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, shares, amounts);

        uint256 n = amounts.length;
        if (skipMask != 0) {
            for (uint256 i = 0; i < n; ++i) {
                uint256 amount = amounts[i];
                if (amount == 0 || (skipMask & (1 << i)) == 0) continue;
                address token = _components[i].token;
                // Booked to `to`, which receives every other component of this redemption. Booking it to msg.sender
                // stranded the skipped components whenever a router redeemed on a holder's behalf, because only the
                // router could ever collect them (DA-17).
                claimOf[to][token] += amount;
                totalClaims[token] += amount;
                // forge-lint: disable-next-line(reentrancy-events)
                emit ClaimRecorded(to, token, amount);
            }
        }

        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] == 0 || (skipMask & (1 << i)) != 0) continue;
            IERC20(_components[i].token).safeTransfer(to, amounts[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Rebalance
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexToken
    function startRebalance(uint256 keepMask) external nonReentrant onlyInitialized {
        uint256 earliest = lastRebalance + MIN_REBALANCE_INTERVAL;
        if (block.timestamp < earliest) revert RebalanceTooSoon(earliest);
        uint256 pendingEta = _pending.eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) {
            revert RebalancePending(pendingEta + AUCTION_DURATION);
        }
        uint256 n = _components.length;
        if (keepMask >> n != 0 || keepMask == (1 << n) - 1) revert InvalidKeepMask(keepMask);
        if (
            (keepMask != 0 || block.timestamp < _permissionlessAt(pendingEta))
                && !IIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)
        ) revert Unauthorized(msg.sender);

        (uint256[] memory targets, uint256 turnover) = _previewTarget(keepMask);
        if (turnover < MIN_TURNOVER) revert TurnoverTooLow(turnover);

        delete _targetUnits;
        for (uint256 i = 0; i < n; ++i) {
            _targetUnits.push(SafeCast.toUint96(targets[i]));
        }
        uint256 eta = block.timestamp + REBALANCE_DELAY;
        _pending = PendingRebalance({eta: SafeCast.toUint40(eta), keepMask: SafeCast.toUint24(keepMask)});
        uint256 proposalId = ++proposalCount;
        // The calls above are views on the factory and the rule; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceStarted(proposalId, rebalanceNonce + 1, msg.sender, targets, keepMask, eta);
    }

    /// @dev First moment anyone may start a rebalance. A cancel holds strangers off for REBALANCE_DELAY, and so does an
    ///      auction that expired unfilled (`pendingEta` is then the expired proposal's): that gives the owner and the
    ///      guardian the first move after an expiry, so a griefer cannot take every restart with a snapshot nobody can
    ///      fill. The owner and guardian are never held off.
    function _permissionlessAt(uint256 pendingEta) private view returns (uint256) {
        uint256 afterExpiry = pendingEta == 0 ? 0 : pendingEta + AUCTION_DURATION + REBALANCE_DELAY;
        return Math.max(restartAllowedAt, afterExpiry);
    }

    /// @inheritdoc IIndexToken
    function cancelRebalance() external nonReentrant onlyInitialized {
        if (_pending.eta == 0) revert NoPendingRebalance();
        if (!IIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
        delete _pending;
        delete _targetUnits;
        uint256 restartAt = block.timestamp + REBALANCE_DELAY;
        restartAllowedAt = restartAt;
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceCancelled(proposalCount, msg.sender, restartAt);
    }

    /// @inheritdoc IIndexToken
    function executeRebalance(bytes calldata data) external nonReentrant onlyInitialized {
        _settle(data, new uint256[](0));
    }

    /// @inheritdoc IIndexToken
    function executeRebalance(bytes calldata data, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        onlyInitialized
    {
        _settle(data, maxAmountsIn);
    }

    function _settle(bytes calldata data, uint256[] memory maxAmountsIn) private {
        (uint256 multiplier, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            _previewRebalance(totalSupply());

        // Settlement amounts scale with the supply at execution time, and issue stays open through the auction, so a
        // stranger can enlarge them between an executor's quote and its transaction. An executor that funded itself
        // from a simulation binds the fill to what it quoted (DA-13); passing nothing keeps the open settlement.
        uint256 bounds = maxAmountsIn.length;
        if (bounds != 0) {
            if (bounds != amountsIn.length) revert LengthMismatch();
            for (uint256 i = 0; i < bounds; ++i) {
                if (amountsIn[i] > maxAmountsIn[i]) {
                    revert RebalanceMovedOn(_components[i].token, amountsIn[i], maxAmountsIn[i]);
                }
            }
        }

        _checkSettlementValue(amountsOut, amountsIn);

        // What the index holds before it pays out, so the check afterwards can require the whole of `amountsIn` back:
        // surplus from rounding or a donation belongs to the holders, not to the executor.
        // A component that neither sends nor receives anything is not read at all: `amountsOut` and `amountsIn` are
        // exactly the change in its required backing, so both being zero means the requirement and the balance are
        // both unchanged and the invariant still holds from before. Skipping it keeps a keep mask working around a
        // component whose `balanceOf` reverts, not only one whose `transfer` does (DA-14).
        uint256 n = units.length;
        uint256[] memory held = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            held[i] = IERC20(_components[i].token).balanceOf(address(this));
        }

        // Effects: the new units, the nonce and the cleared proposal are in place before any token moves.
        uint256 proposalId = proposalCount;
        uint256 id = _applyRebalance(units);
        // No external call precedes this event: the transfers and the executor callback come after it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Rebalanced(proposalId, id, msg.sender, multiplier, units, amountsOut, amountsIn);

        for (uint256 i = 0; i < n; ++i) {
            if (amountsOut[i] != 0) IERC20(_components[i].token).safeTransfer(msg.sender, amountsOut[i]);
        }
        // The executor has to be called back to deliver the growing components, so this cannot be the last interaction.
        // Every function that mints, burns, pays a claim or rebalances shares the guard, and the backing check below
        // reads only the final state. Wake's reentrancy detector does not model the guard, hence the suppression.
        // wake-disable-next-line reentrancy
        IRebalanceExecutor(msg.sender).onXindexRebalance(amountsOut, amountsIn, data);
        _checkBacking(units, amountsOut, amountsIn, held);
    }

    function _applyRebalance(uint256[] memory units) private returns (uint256 id) {
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            _components[i].units = SafeCast.toUint96(units[i]);
        }
        id = ++rebalanceNonce;
        lastRebalance = block.timestamp;
        delete _pending;
        delete _targetUnits;
    }

    /// @dev The backing invariant with the new units, and the whole of `amountsIn` on top of what the index held
    ///      before it paid out, checked after the executor has returned. The second bound is the stricter one whenever
    ///      the index held a surplus, from rounding or a donation: it keeps that surplus with the holders instead of
    ///      letting the executor deliver that much less.
    function _checkBacking(
        uint256[] memory units,
        uint256[] memory amountsOut,
        uint256[] memory amountsIn,
        uint256[] memory held
    ) private view {
        uint256 supply = totalSupply();
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            // Nothing moved and nothing was required to: see the note in executeRebalance (DA-14).
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            address token = _components[i].token;
            uint256 required = Math.mulDiv(supply, units[i], SHARE_UNIT) + totalClaims[token];
            uint256 delivered = held[i] - amountsOut[i] + amountsIn[i];
            if (delivered > required) required = delivered;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < required) revert RebalanceUnderfunded(token, balance, required);
        }
    }

    /// @dev Settlement for the current block. A shrinking component moves straight to its target; a growing component
    ///      gains its extra units times the multiplier, rounded up. Amounts are the change in required backing, so they
    ///      depend only on supply and units: the index never sends out rounding dust or donations, and the executor has
    ///      to deliver every amount in full.
    function _previewRebalance(uint256 supply)
        private
        view
        returns (uint256 multiplier, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        uint256 eta = _pending.eta;
        if (eta == 0) revert NoPendingRebalance();
        if (block.timestamp < eta) revert RebalanceNotReady(eta);
        if (block.timestamp > eta + AUCTION_DURATION) revert RebalanceExpired(eta + AUCTION_DURATION);

        uint256 n = _components.length;
        units = new uint256[](n);
        amountsOut = new uint256[](n);
        amountsIn = new uint256[](n);
        // A shrinking component moves straight to its target, so what leaves the index does not depend on the
        // multiplier: it can be settled before the auction's price is known.
        bool sells = false;
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = _components[i].units;
            uint256 target = _targetUnits[i];
            if (target >= current) continue;
            units[i] = target;
            amountsOut[i] = Math.mulDiv(supply, current, SHARE_UNIT) - Math.mulDiv(supply, target, SHARE_UNIT);
            if (amountsOut[i] != 0) sells = true;
        }
        multiplier = sells ? _multiplier(eta) : WAD;

        for (uint256 i = 0; i < n; ++i) {
            uint256 current = _components[i].units;
            uint256 target = _targetUnits[i];
            if (target < current) continue;
            uint256 next = current + Math.mulDiv(target - current, multiplier, WAD, Math.Rounding.Ceil);
            units[i] = next;
            amountsIn[i] = Math.mulDiv(supply, next, SHARE_UNIT) - Math.mulDiv(supply, current, SHARE_UNIT);
        }
    }

    /// @dev The auction band fixes the multiplier on the bought legs at the snapshot's prices. Settlement happens up
    ///      to REBALANCE_DELAY + AUCTION_DURATION later, and nothing bounded how far the market moved in between, so a
    ///      fill was worth whatever three-day-old relative prices said it was and an executor filled only when the
    ///      drift favoured them (DA-05). The two sides are therefore valued again in the settling block and the fill
    ///      has to clear MIN_SETTLEMENT_RATIO of what it takes. The test is a ratio, not a price, so a market-wide
    ///      move reprices both sides together and changes nothing; only the drift between the legs sold and the legs
    ///      bought can fail it. It can only refuse a settlement, never enlarge one: the amounts still come from supply
    ///      and units, and the band still bounds them. The cost is liveness. A feed that has stopped publishing, or a
    ///      market that really has moved, makes the auction expire unfilled, and the restart hold-off then gives the
    ///      owner and the guardian the first move on a fresh snapshot.
    function _checkSettlementValue(uint256[] memory amountsOut, uint256[] memory amountsIn) private view {
        uint256 n = amountsOut.length;
        address[] memory tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
        (uint256 outValue, uint256 inValue) = IIndexRule(RULE).settlementValues(tokens, amountsOut, amountsIn);
        uint256 required = Math.mulDiv(outValue, MIN_SETTLEMENT_RATIO, WAD);
        if (inValue < required) revert SettlementValueTooLow(inValue, outValue, required);
    }

    /// @dev Linear decay from the start to the end multiplier; the decrement rounds down, so the multiplier rounds up.
    ///      A settlement that sends nothing out (an empty index, or one whose supply is so small that every shrinking
    ///      leg rounds to zero) is priced at parity instead, because the auction has nothing to pay for and the new
    ///      units should not depend on timing. A dust supply that still moves a few raw units does decay: a lone
    ///      executor then picks the multiplier in [0.9, 1.5] for next to nothing, which sets the new units within their
    ///      bounds but moves no holder's value. Any supply threshold for parity would be arbitrary and cheap to step
    ///      over.
    function _multiplier(uint256 eta) private view returns (uint256) {
        return AUCTION_START_MULTIPLIER
            - Math.mulDiv(AUCTION_START_MULTIPLIER - AUCTION_END_MULTIPLIER, block.timestamp - eta, AUCTION_DURATION);
    }

    function _previewTarget(uint256 keepMask) private view returns (uint256[] memory targets, uint256 turnover) {
        (address[] memory tokens, uint256[] memory units) = _componentArrays();
        return IIndexRule(RULE).targetUnits(tokens, units, methodology, keepMask);
    }

    function _checkInitialized() private view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient(to);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    /// @inheritdoc IIndexToken
    function componentTokens() external view returns (address[] memory tokens) {
        uint256 n = _components.length;
        tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
    }

    /// @inheritdoc IIndexToken
    function components() external view returns (address[] memory tokens, uint256[] memory units) {
        return _componentArrays();
    }

    /// @inheritdoc IIndexToken
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn) {
        return _amounts(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IIndexToken
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        return _amounts(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IIndexToken
    function previewTarget(uint256 keepMask) external view returns (uint256[] memory targetUnits, uint256 turnover) {
        return _previewTarget(keepMask);
    }

    /// @inheritdoc IIndexToken
    function pendingRebalance() external view returns (uint256 eta, uint256 keepMask, uint256[] memory targetUnits) {
        eta = _pending.eta;
        keepMask = _pending.keepMask;
        uint256 n = _targetUnits.length;
        targetUnits = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            targetUnits[i] = _targetUnits[i];
        }
    }

    /// @inheritdoc IIndexToken
    function currentMultiplier() external view returns (uint256 multiplier) {
        uint256 eta = _pending.eta;
        if (eta == 0 || block.timestamp < eta || block.timestamp > eta + AUCTION_DURATION) return 0;
        (multiplier,,,) = _previewRebalance(totalSupply());
    }

    /// @inheritdoc IIndexToken
    function canStartRebalance() external view returns (bool) {
        // The implementation and any clone deployed outside the factory hold no components and cannot rebalance at
        // all; without this they answered true, because their `lastRebalance` is zero (DA-22).
        if (_getInitializedVersion() != 1) return false;
        if (block.timestamp < lastRebalance + MIN_REBALANCE_INTERVAL) return false;
        uint256 pendingEta = _pending.eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) return false;
        return block.timestamp >= _permissionlessAt(pendingEta);
    }

    /// @inheritdoc IIndexToken
    function previewRebalance()
        external
        view
        returns (uint256 multiplier, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        return _previewRebalance(totalSupply());
    }

    function _componentArrays() private view returns (address[] memory tokens, uint256[] memory units) {
        uint256 n = _components.length;
        tokens = new address[](n);
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
            units[i] = _components[i].units;
        }
    }

    /// @dev Raw amount of every component corresponding to `shares`, with the given rounding.
    function _amounts(uint256 shares, Math.Rounding rounding) private view returns (uint256[] memory amounts) {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = Math.mulDiv(shares, _components[i].units, SHARE_UNIT, rounding);
        }
    }

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
