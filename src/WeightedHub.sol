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
// Named only by `@inheritdoc IIndexHub`, which solc refuses without the import.
// aderyn-fp-next-line(unused-import)
import {IIndexHub} from "./interfaces/IIndexHub.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "./interfaces/IWeightedIndexFactory.sol";
import {IRebalanceExecutor} from "./interfaces/IRebalanceExecutor.sol";
import {IPyth} from "./interfaces/pyth/IPyth.sol";
import {PythStructs} from "./interfaces/pyth/PythStructs.sol";

/// @title WeightedHub
/// @notice Fully collateralized index token with fixed constituents and fixed weights, rebalanced to those weights at
///         Pyth prices. See {IWeightedHub}.
/// @dev Deployed as an EIP-1167 clone by {WeightedIndexFactory}. The implementation is deployed from the factory
///      constructor, so `FACTORY` and `PYTH` can be immutables (immutables live in bytecode, which clones delegate to,
///      so every clone sees the same values).
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
///      Prices. Issue, redeem and claims never read one, so a price feed that stops or lies can never block an exit or
///      misprice a mint: both stay in kind. Only a settlement reads prices, and only the moving components', from a
///      signed Pyth update its executor brings. The hub fixes the second the prices belong to ({priceTime}), one slot
///      before the settling block, and Pyth's `parsePriceFeedUpdatesUnique` returns, for each feed, only its first
///      update at or after that second, so an executor has exactly one price per component in each block and cannot
///      choose among many; what it can still choose is whether to fill in a block, seeing that price PRICE_LAG ahead
///      (V5-L1). No two components share a price id, since Pyth fills only the first of two equal ids (V5-M1). Pyth's
///      contract is upgradeable by its DAO, and the uniqueness of the update is Pyth's to keep. A price is taken as
///      USD per raw unit scaled by 1e36, `price * 10 ** (36 + expo - decimals)`, with the decimals the factory recorded
///      at listing: no component is ever called to price it.
///
///      Rebalancing. Once MIN_REBALANCE_INTERVAL has passed, anyone can start one; after REBALANCE_DELAY of notice an
///      auction runs for AUCTION_DURATION. At settlement, the moving components' value V = Σ u·p is shared out by
///      weight: each target is t = w · V / (W · p), where W sums the moving weights, rounded up. Shrinking legs move to
///      their targets and growing legs move μ times their gap, with μ falling linearly from MU_MAX to MU_MIN over the
///      auction, rounded up. At the settling prices the executor therefore receives S and delivers μ · S, so a lone
///      executor at the end keeps at most (1 − MU_MIN) of the traded value. The cap does not trust the prices: when a
///      shrinking leg would give up more than MAX_TURNOVER of its own units, every leg moves the same smaller share of
///      the way, so one fill sends out at most MAX_TURNOVER of each component it sells, whatever a price says (V5-M2).
///      A fill that would trade less than MIN_TRADE of the moving value at its prices reverts, so a fill that changes
///      nothing cannot restart MIN_REBALANCE_INTERVAL (V5-L2). Transfer amounts come from supply and units alone, and
///      the settlement stands only if the invariant holds with the new units and the whole of `amountsIn` arrived on
///      top of what the index held.
// Every payable entry point forwards the whole of msg.value to Pyth as its fee in the same call, so no ether stays here
// (`test_theFeeGoesToPyth`).
// aderyn-fp-next-line(contract-locks-ether)
contract WeightedHub is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ReentrancyGuard, IWeightedHub {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;
    uint256 public constant MIN_COMPONENTS = 2;
    uint256 public constant MAX_COMPONENTS = 100;
    uint256 public constant TOTAL_WEIGHT = 1e4;
    uint256 public constant REBALANCE_DELAY = 2 hours;
    uint256 public constant MIN_REBALANCE_INTERVAL = 7 days;
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant MU_MAX = 1.02e18;
    uint256 public constant MU_MIN = 0.98e18;
    uint256 public constant MAX_TURNOVER = 0.2e18;
    uint256 public constant MIN_TRADE = 0.001e18;
    uint256 public constant MAX_CONFIDENCE = 0.02e18;
    uint256 public constant PRICE_LAG = 12;
    uint256 public constant MAX_PRICE = 1e45;
    int256 public constant MIN_EXPO = -18;
    address public immutable FACTORY;
    address public immutable PYTH;

    uint256 private constant WAD = 1e18;
    /// @dev Decimals of a price in USD per raw unit. With an exponent of at least MIN_EXPO and at most MAX_DECIMALS
    ///      decimals, the power of ten a Pyth price is scaled by, PRICE_DECIMALS + expo - decimals, is never negative.
    uint256 private constant PRICE_DECIMALS = 36;
    uint256 private constant MAX_DECIMALS = 18;

    struct Component {
        address token;
        uint96 units;
    }

    /// @dev What the creator fixed for a component: its Pyth price id, its weight and its decimals.
    struct Terms {
        bytes32 priceId;
        uint16 weight;
        uint8 decimals;
    }

    /// @dev One settlement, kept in memory for the stack: the multiplier, the second its prices belong to, the prices,
    ///      the new units and what each leg moves.
    struct Settlement {
        uint256 mu;
        uint256 time;
        uint256[] prices;
        uint256[] units;
        uint256[] amountsOut;
        uint256[] amountsIn;
    }

    Component[] private _components;
    Terms[] private _terms;

    /// @inheritdoc IWeightedHub
    mapping(address account => mapping(address token => uint256 amount)) public claimOf;

    /// @inheritdoc IWeightedHub
    mapping(address token => uint256 amount) public totalClaims;

    /// @dev Start of the pending auction; zero when no rebalance is pending.
    uint256 private _eta;
    uint256 private _keepMask;

    /// @inheritdoc IWeightedHub
    uint256 public proposalCount;

    /// @inheritdoc IIndexHub
    uint256 public rebalanceNonce;

    /// @inheritdoc IWeightedHub
    uint256 public lastRebalance;

    /// @inheritdoc IWeightedHub
    uint256 public restartAllowedAt;

    modifier onlyInitialized() {
        _checkInitialized();
        _;
    }

    constructor(address pyth) {
        if (pyth == address(0)) revert ZeroAddress();
        FACTORY = msg.sender;
        PYTH = pyth;
        _disableInitializers();
    }

    /// @inheritdoc IWeightedHub
    function initialize(string calldata name_, string calldata symbol_, ComponentInit[] calldata components_)
        external
        initializer
    {
        if (msg.sender != FACTORY) revert NotFactory();
        uint256 n = components_.length;
        if (n < MIN_COMPONENTS || n > MAX_COMPONENTS) revert InvalidComponents();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            ComponentInit calldata c = components_[i];
            if (
                c.token == address(0) || c.units == 0 || c.weight == 0 || c.weight > TOTAL_WEIGHT
                    || c.priceId == bytes32(0) || c.decimals > MAX_DECIMALS
            ) revert InvalidComponents();
            // Pyth fills only the first of two equal ids, so an index whose components shared one could never settle
            // (V5-M1); the factory refuses both, and so does this, for a clone it did not check.
            for (uint256 j = 0; j < i; ++j) {
                if (components_[j].token == c.token || components_[j].priceId == c.priceId) revert InvalidComponents();
            }
            total += c.weight;
            _components.push(Component({token: c.token, units: SafeCast.toUint96(c.units)}));
            _terms.push(Terms({priceId: c.priceId, weight: SafeCast.toUint16(c.weight), decimals: c.decimals}));
        }
        if (total != TOTAL_WEIGHT) revert InvalidComponents();
        // Set once at creation, in the same transaction as the factory's IndexCreated event.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        lastRebalance = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Issue / redeem / claim
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexHub
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

    /// @inheritdoc IIndexHub
    function redeem(uint256 shares, address to) external nonReentrant onlyInitialized {
        _redeem(shares, to, 0);
    }

    /// @inheritdoc IWeightedHub
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external nonReentrant onlyInitialized {
        if (skipMask == 0 || skipMask >> _components.length != 0) revert InvalidSkipMask(skipMask);
        _redeem(shares, to, skipMask);
    }

    /// @inheritdoc IWeightedHub
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
                // Booked to `to`, which receives every other component of this redemption, so a router redeeming on
                // a holder's behalf does not strand the skipped components (DA-17).
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

    /// @inheritdoc IWeightedHub
    function startRebalance(uint256 keepMask) external nonReentrant onlyInitialized {
        uint256 earliest = lastRebalance + MIN_REBALANCE_INTERVAL;
        if (block.timestamp < earliest) revert RebalanceTooSoon(earliest);
        uint256 pendingEta = _eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) {
            revert RebalancePending(pendingEta + AUCTION_DURATION);
        }
        uint256 n = _components.length;
        if (keepMask >> n != 0 || n - _bits(keepMask) < MIN_COMPONENTS) revert InvalidKeepMask(keepMask);
        if (
            // A view on the factory, by STATICCALL: nothing it reaches can change state, so nothing re-enters.
            // aderyn-fp-next-line(reentrancy-state-change)
            (keepMask != 0 || block.timestamp < _permissionlessAt(pendingEta))
                && !IWeightedIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)
        ) {
            revert Unauthorized(msg.sender);
        }

        uint256 eta = block.timestamp + REBALANCE_DELAY;
        _eta = eta;
        _keepMask = keepMask;
        uint256 proposalId = ++proposalCount;
        // The call above is a view on the factory; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceStarted(proposalId, rebalanceNonce + 1, msg.sender, keepMask, eta);
    }

    /// @dev How many bits `mask` sets. A single moving component already sits on its weight among the moving ones, so a
    ///      keep mask must leave two (V5-L2).
    function _bits(uint256 mask) private pure returns (uint256 count) {
        count = 0;
        while (mask != 0) {
            mask &= mask - 1;
            ++count;
        }
    }

    /// @dev First moment anyone may start a rebalance. A cancel holds strangers off for REBALANCE_DELAY, and so does an
    ///      auction that expired unfilled (`pendingEta` is then the expired proposal's): that gives the owner and the
    ///      guardian the first move after an expiry. The owner and guardian are never held off.
    function _permissionlessAt(uint256 pendingEta) private view returns (uint256) {
        uint256 afterExpiry = pendingEta == 0 ? 0 : pendingEta + AUCTION_DURATION + REBALANCE_DELAY;
        return Math.max(restartAllowedAt, afterExpiry);
    }

    /// @inheritdoc IWeightedHub
    function cancelRebalance() external nonReentrant onlyInitialized {
        uint256 eta = _eta;
        if (eta == 0) revert NoPendingRebalance();
        // A view on the factory, by STATICCALL: nothing it reaches can change state, so nothing re-enters.
        // aderyn-fp-next-line(reentrancy-state-change)
        if (!IWeightedIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
        // Cancelling an auction that already expired only clears the stale proposal: its expiry already holds
        // strangers off until its own deadline plus REBALANCE_DELAY, and re-arming from here would push that out for
        // nothing (VR-04).
        uint256 restartAt =
            block.timestamp <= eta + AUCTION_DURATION ? block.timestamp + REBALANCE_DELAY : _permissionlessAt(eta);
        _clearPending();
        restartAllowedAt = restartAt;
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceCancelled(proposalCount, msg.sender, restartAt);
    }

    /// @inheritdoc IWeightedHub
    function executeRebalance(bytes calldata data, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        onlyInitialized
    {
        _settle(data, priceUpdate, new uint256[](0));
    }

    /// @inheritdoc IWeightedHub
    function executeRebalance(bytes calldata data, bytes[] calldata priceUpdate, uint256[] calldata maxAmountsIn)
        external
        payable
        nonReentrant
        onlyInitialized
    {
        _settle(data, priceUpdate, maxAmountsIn);
    }

    function _settle(bytes calldata data, bytes[] calldata priceUpdate, uint256[] memory maxAmountsIn) private {
        Settlement memory settlement = _priced(priceUpdate);
        _checkBounds(settlement.amountsIn, maxAmountsIn);
        uint256[] memory held = _held(settlement.amountsOut, settlement.amountsIn);

        // Effects: the new units, the nonce and the cleared proposal are in place before any token moves.
        uint256 proposalId = proposalCount;
        uint256 id = _applyRebalance(settlement.units);
        // Only Pyth's parse, which the guard covers, precedes this event; the transfers and the executor callback
        // come after it.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Rebalanced(
            proposalId,
            id,
            msg.sender,
            settlement.mu,
            settlement.time,
            settlement.prices,
            settlement.units,
            settlement.amountsOut,
            settlement.amountsIn
        );

        uint256 n = settlement.units.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 out = settlement.amountsOut[i];
            if (out != 0) IERC20(_components[i].token).safeTransfer(msg.sender, out);
        }
        // The executor has to be called back to deliver the growing components, so this cannot be the last interaction.
        // Every function that mints, burns, pays a claim or rebalances shares the guard, and the backing check below
        // reads only the final state. Wake's reentrancy detector does not model the guard, hence the suppression.
        // wake-disable-next-line reentrancy
        IRebalanceExecutor(msg.sender).onXindexRebalance(settlement.amountsOut, settlement.amountsIn, data);
        _checkBacking(settlement.units, settlement.amountsOut, settlement.amountsIn, held);
    }

    /// @dev The settlement for this block: the auction checked open, the prices read through Pyth at {priceTime}, and
    ///      the amounts at the supply now.
    function _priced(bytes[] calldata priceUpdate) private returns (Settlement memory settlement) {
        uint256 mu = _openMu();
        settlement.time = _priceTime();
        settlement.prices = _readPrices(priceUpdate, settlement.time);
        (settlement.mu, settlement.units, settlement.amountsOut, settlement.amountsIn) =
            _settlement(mu, settlement.prices, totalSupply());
    }

    /// @dev Settlement amounts scale with the supply at execution time, and issue stays open through the auction, so a
    ///      stranger can enlarge them between an executor's quote and its transaction. An executor that funded itself
    ///      from a simulation binds the fill to what it quoted (DA-13); passing nothing keeps the open settlement.
    function _checkBounds(uint256[] memory amountsIn, uint256[] memory maxAmountsIn) private view {
        uint256 bounds = maxAmountsIn.length;
        if (bounds == 0) return;
        if (bounds != amountsIn.length) revert LengthMismatch();
        for (uint256 i = 0; i < bounds; ++i) {
            if (amountsIn[i] > maxAmountsIn[i]) {
                revert RebalanceMovedOn(_components[i].token, amountsIn[i], maxAmountsIn[i]);
            }
        }
    }

    /// @dev What the index holds before it pays out, so the check afterwards can require the whole of `amountsIn` back:
    ///      surplus from rounding or a donation belongs to the holders, not to the executor. A component that neither
    ///      sends nor receives anything is not read at all, which keeps a keep mask working around a component whose
    ///      `balanceOf` reverts (DA-14).
    function _held(uint256[] memory amountsOut, uint256[] memory amountsIn)
        private
        view
        returns (uint256[] memory held)
    {
        uint256 n = amountsOut.length;
        held = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            held[i] = IERC20(_components[i].token).balanceOf(address(this));
        }
    }

    /// @dev Reads the moving components' prices at `time` from `priceUpdate`, forwarding the whole of msg.value to Pyth
    ///      as its fee. Pyth returns each feed's first update published at or after `time` and before this block, or
    ///      reverts; the order and the window are checked again here rather than trusted.
    function _readPrices(bytes[] calldata priceUpdate, uint256 time) private returns (uint256[] memory prices) {
        uint256 n = _components.length;
        uint256 keepMask = _keepMask;
        uint256 moving = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) ++moving;
        }
        bytes32[] memory ids = new bytes32[](moving);
        uint256 k = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) ids[k++] = _terms[i].priceId;
        }

        uint256 last = time + PRICE_LAG - 1;
        // Pyth is a fixed, trusted dependency, and the guard covers anything it could call back into.
        // wake-disable-next-line reentrancy
        PythStructs.PriceFeed[] memory feeds = IPyth(PYTH).parsePriceFeedUpdatesUnique{value: msg.value}(
            priceUpdate, ids, SafeCast.toUint64(time), SafeCast.toUint64(last)
        );
        if (feeds.length != moving) revert PriceMismatch(bytes32(0), 0);

        prices = new uint256[](n);
        k = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            PythStructs.PriceFeed memory feed = feeds[k];
            uint256 published = feed.price.publishTime;
            if (feed.id != ids[k] || published < time || published > last) revert PriceMismatch(feed.id, published);
            prices[i] = _price(feed.price, i);
            ++k;
        }
    }

    /// @dev `p` as USD per raw unit of component `i`, scaled by 1e36: `price * 10 ** (36 + expo - decimals)`, with the
    ///      decimals recorded at listing. A non-positive price, an exponent outside [MIN_EXPO, 0], a result above
    ///      MAX_PRICE or a confidence interval wider than MAX_CONFIDENCE of the price is refused.
    function _price(PythStructs.Price memory p, uint256 i) private view returns (uint256) {
        int256 expo = p.expo;
        if (p.price <= 0 || expo > 0 || expo < MIN_EXPO) revert PriceOutOfRange(_components[i].token, p.price, p.expo);
        // Positive, checked above, so the cast keeps the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(int256(p.price));
        if (uint256(p.conf) * WAD > price * MAX_CONFIDENCE) {
            revert PriceUncertain(_components[i].token, p.price, p.conf);
        }
        // At least PRICE_DECIMALS + MIN_EXPO - MAX_DECIMALS = 0, and at most PRICE_DECIMALS: expo lies in [MIN_EXPO, 0]
        // and the decimals were checked at most MAX_DECIMALS at initialization.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 exponent = uint256(int256(PRICE_DECIMALS) + expo) - _terms[i].decimals;
        // Below 2^63 * 10^36, so the product fits.
        uint256 value = price * 10 ** exponent;
        if (value > MAX_PRICE) revert PriceOutOfRange(_components[i].token, p.price, p.expo);
        return value;
    }

    function _applyRebalance(uint256[] memory units) private returns (uint256 id) {
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            _components[i].units = SafeCast.toUint96(units[i]);
        }
        id = ++rebalanceNonce;
        lastRebalance = block.timestamp;
        _clearPending();
    }

    function _clearPending() private {
        delete _eta;
        delete _keepMask;
    }

    /// @dev The backing invariant with the new units, and the whole of `amountsIn` on top of what the index held
    ///      before it paid out, checked after the executor has returned.
    function _checkBacking(
        uint256[] memory units,
        uint256[] memory amountsOut,
        uint256[] memory amountsIn,
        uint256[] memory held
    ) private view {
        uint256 supply = totalSupply();
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            // Nothing moved and nothing was required to: see the note in `_settle` (DA-14).
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            address token = _components[i].token;
            uint256 required = _backing(supply, units[i], Math.Rounding.Floor) + totalClaims[token];
            uint256 delivered = held[i] - amountsOut[i] + amountsIn[i];
            if (delivered > required) required = delivered;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < required) revert RebalanceUnderfunded(token, balance, required);
        }
    }

    /// @dev μ in this block, after checking that an auction is open. The decrement rounds down, so μ rounds up, towards
    ///      the holders.
    function _openMu() private view returns (uint256) {
        uint256 eta = _eta;
        if (eta == 0) revert NoPendingRebalance();
        if (block.timestamp < eta) revert RebalanceNotReady(eta);
        if (block.timestamp > eta + AUCTION_DURATION) revert RebalanceExpired(eta + AUCTION_DURATION);
        return MU_MAX - Math.mulDiv(MU_MAX - MU_MIN, block.timestamp - eta, AUCTION_DURATION);
    }

    /// @dev The settlement at `mu`, or at MU_MAX when it would send nothing out, as on an empty index or one so small
    ///      that every shrinking leg rounds to zero: nobody is paid for an empty or dust index (R14, XA-27).
    function _settlement(uint256 mu, uint256[] memory prices, uint256 supply)
        private
        view
        returns (uint256, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        bool sells;
        (units, amountsOut, amountsIn, sells) = _settlementAt(mu, prices, supply);
        if (!sells && mu != MU_MAX) {
            mu = MU_MAX;
            (units, amountsOut, amountsIn,) = _settlementAt(mu, prices, supply);
        }
        return (mu, units, amountsOut, amountsIn);
    }

    /// @dev New units and the amounts each leg moves, at multiplier `mu` and the moving components' `prices`. Targets
    ///      round up, so a shrinking leg keeps more and a growing leg asks more. The share of the way every leg moves,
    ///      `s`, rounds down; a shrinking leg's step rounds down and a growing leg's rounds up. Each leg's amount is its
    ///      change in required backing, rounded down when it leaves and up when it comes back (SA-07).
    function _settlementAt(uint256 mu, uint256[] memory prices, uint256 supply)
        private
        view
        returns (uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn, bool sells)
    {
        uint256 n = _components.length;
        uint256 keepMask = _keepMask;
        units = new uint256[](n);
        amountsOut = new uint256[](n);
        amountsIn = new uint256[](n);
        sells = false;

        (uint256[] memory targets, uint256 share) = _targets(keepMask, prices);
        uint256 growth = Math.mulDiv(mu, share, WAD, Math.Rounding.Ceil);
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = _components[i].units;
            uint256 target = targets[i];
            if ((keepMask & (1 << i)) != 0 || target == current) {
                units[i] = current;
                continue;
            }
            if (target < current) {
                uint256 step = Math.mulDiv(current - target, share, WAD);
                units[i] = current - step;
                uint256 out = _backing(supply, step, Math.Rounding.Floor);
                amountsOut[i] = out;
                if (out != 0) sells = true;
            } else {
                uint256 step = Math.mulDiv(target - current, growth, WAD, Math.Rounding.Ceil);
                units[i] = current + step;
                amountsIn[i] = _backing(supply, step, Math.Rounding.Ceil);
            }
        }
    }

    /// @dev Each moving component's target units, w · V / (W · p) rounded up, and the share of the way to them every
    ///      leg moves: all of it, or less, so that no shrinking leg gives up more than MAX_TURNOVER of its own units,
    ///      rounded down. The cap counts units, not value, so a wrong price cannot widen it: the prices it guards against
    ///      would otherwise measure it (V5-M2). Reverts NothingToRebalance when what the shrinking legs release, after
    ///      the cap, is worth less than MIN_TRADE of V: measured before the cap, a fill could trade a fifth of that and
    ///      still restart the interval (V5R-1). Values are units times prices: below 2^96 · MAX_PRICE each, so a hundred
    ///      of them fit 256 bits.
    function _targets(uint256 keepMask, uint256[] memory prices)
        private
        view
        returns (uint256[] memory targets, uint256 share)
    {
        uint256 n = _components.length;
        uint256 value = 0;
        uint256 weight = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            value += _components[i].units * prices[i];
            weight += _terms[i].weight;
        }
        targets = new uint256[](n);
        share = WAD;
        uint256 released = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            uint256 target = Math.mulDiv(value, _terms[i].weight, weight * prices[i], Math.Rounding.Ceil);
            targets[i] = target;
            uint256 current = _components[i].units;
            if (target >= current) continue;
            released += (current - target) * prices[i];
            uint256 limit = Math.mulDiv(current, MAX_TURNOVER, current - target);
            if (limit < share) share = limit;
        }
        // What the fill trades is the release scaled by the cap, so the minimum is checked on that (V5R-1).
        if (Math.mulDiv(released, share, WAD) < Math.mulDiv(value, MIN_TRADE, WAD, Math.Rounding.Ceil)) {
            revert NothingToRebalance();
        }
    }

    /// @dev The second whose prices a settlement in this block reads: one slot back, PRICE_LAG before the block, so Pyth
    ///      has published it, and the executor sees it at most a slot ahead. It was the start of the previous minute,
    ///      known up to two minutes ahead, which gave an executor two minutes of the market to choose its fill against
    ///      (V5-L1).
    function _priceTime() private view returns (uint256) {
        return block.timestamp - PRICE_LAG;
    }

    function _checkInitialized() private view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (_isTrap(to)) revert InvalidRecipient(to);
    }

    /// @dev Shares sent to the index itself or its factory could never leave again, so every transfer and
    ///      `transferFrom` refuses them, as issue, redeem and claim do (CR-I01, RT-21).
    function _update(address from, address to, uint256 value) internal override {
        if (_isTrap(to)) revert InvalidRecipient(to);
        super._update(from, to, value);
    }

    function _isTrap(address to) private view returns (bool) {
        return to == address(this) || to == FACTORY;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedHub
    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    /// @inheritdoc IIndexHub
    function componentTokens() external view returns (address[] memory tokens) {
        uint256 n = _components.length;
        tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
    }

    /// @inheritdoc IWeightedHub
    function components() external view returns (address[] memory tokens, uint256[] memory units) {
        uint256 n = _components.length;
        tokens = new address[](n);
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
            units[i] = _components[i].units;
        }
    }

    /// @inheritdoc IWeightedHub
    function componentTerms()
        external
        view
        returns (uint256[] memory weights, bytes32[] memory priceIds, uint8[] memory decimals)
    {
        uint256 n = _terms.length;
        weights = new uint256[](n);
        priceIds = new bytes32[](n);
        decimals = new uint8[](n);
        for (uint256 i = 0; i < n; ++i) {
            Terms memory terms = _terms[i];
            weights[i] = terms.weight;
            priceIds[i] = terms.priceId;
            decimals[i] = terms.decimals;
        }
    }

    /// @inheritdoc IIndexHub
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn) {
        return _amounts(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IIndexHub
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        return _amounts(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IWeightedHub
    function priceTime() external view returns (uint256) {
        return _priceTime();
    }

    /// @inheritdoc IWeightedHub
    function pendingRebalance() external view returns (uint256 eta, uint256 keepMask) {
        return (_eta, _keepMask);
    }

    /// @inheritdoc IWeightedHub
    function currentMu() external view returns (uint256) {
        uint256 eta = _eta;
        if (eta == 0 || block.timestamp < eta || block.timestamp > eta + AUCTION_DURATION) return 0;
        return _openMu();
    }

    /// @inheritdoc IWeightedHub
    function canStartRebalance() external view returns (bool) {
        // The implementation and any clone deployed outside the factory hold no components and cannot rebalance at
        // all (DA-22).
        if (_getInitializedVersion() != 1) return false;
        if (block.timestamp < lastRebalance + MIN_REBALANCE_INTERVAL) return false;
        uint256 pendingEta = _eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) return false;
        return block.timestamp >= _permissionlessAt(pendingEta);
    }

    /// @inheritdoc IWeightedHub
    function previewRebalance(PythStructs.Price[] calldata prices)
        external
        view
        returns (uint256 mu, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        uint256 n = _components.length;
        if (prices.length != n) revert PriceCountMismatch(prices.length);
        mu = _openMu();
        uint256 keepMask = _keepMask;
        uint256[] memory read = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) read[i] = _price(prices[i], i);
        }
        return _settlement(mu, read, totalSupply());
    }

    /// @dev Raw amount of every component corresponding to `shares`, with the given rounding.
    function _amounts(uint256 shares, Math.Rounding rounding) private view returns (uint256[] memory amounts) {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = _backing(shares, _components[i].units, rounding);
        }
    }

    /// @dev The one place a share count turns into an amount of a component: issue, redeem, the settlement and its
    ///      backing check all go through it.
    function _backing(uint256 shares, uint256 units, Math.Rounding rounding) private pure returns (uint256) {
        return Math.mulDiv(shares, units, SHARE_UNIT, rounding);
    }

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
