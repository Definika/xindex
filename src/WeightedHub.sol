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
import {IWeightedMath} from "./interfaces/IWeightedMath.sol";
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
///      Fees. An index charges its creator's rate and the platform's, both fixed at creation, on every issue and
///      every redeem, in shares and never in components. A minter's deposit backs the fee's shares on top of the ones
///      it receives, and a burner's fee is minted to the recipients out of the shares it burns, so every share is
///      backed by the deposit that minted it and the invariant is untouched. The recipients, the index's creator and
///      the platform, are the factory's answer at each call; the platform's part goes to the creator when the
///      factory names none or one that could not hold shares, and the creator's to the call's own `to` in the same
///      case, so no recipient can ever block a mint or an exit. A referrer named at mint takes the referral share of
///      the platform's part. A gated index issues only to recipients the factory allows for it, until its creator
///      opens it there.
///
///      Rebalancing. Once the index's rebalance interval has passed, anyone can start one; after REBALANCE_DELAY of
///      notice an auction runs for AUCTION_DURATION. At settlement, the moving components' value V = Σ u·p is shared out by
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
    uint256 private constant MAX_FEE_BPS = 125;
    uint256 private constant MAX_STREAMING_BPS = 600;
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
    address public immutable MATH;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 1e4;
    uint256 private constant YEAR = 365 days;
    /// @dev The scale of units that carry no streaming fee yet: one, in the storage width the scale is kept in.
    uint128 private constant SCALE_ONE = 1e18;
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
    Config private _config;
    /// @dev The factor every component's recorded units carry since the last settlement folded the streaming fee in,
    ///      1e18 = one, and when the fee was last accrued.
    uint128 private _scale;
    uint40 private _lastAccrual;

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

    constructor(address pyth, address math) {
        if (pyth == address(0) || math == address(0)) revert ZeroAddress();
        FACTORY = msg.sender;
        PYTH = pyth;
        MATH = math;
        _disableInitializers();
    }

    /// @inheritdoc IWeightedHub
    function initialize(
        string calldata name_,
        string calldata symbol_,
        ComponentInit[] calldata components_,
        Config calldata config_
    ) external initializer {
        if (msg.sender != FACTORY) revert NotFactory();
        uint256 n = components_.length;
        if (n < MIN_COMPONENTS || n > MAX_COMPONENTS) revert InvalidComponents();
        // The factory checks each rate and the interval against its own bounds; this keeps the two sums that every
        // fee divides by inside what the arithmetic assumes, and the interval at least the floor, for a clone it did
        // not check.
        if (
            uint256(config_.creatorFeeBps) + config_.platformFeeBps > MAX_FEE_BPS
                || uint256(config_.creatorStreamingBps) + config_.platformStreamingBps > MAX_STREAMING_BPS
                || config_.referralShareBps > BPS || config_.rebalanceInterval < MIN_REBALANCE_INTERVAL
        ) revert InvalidConfig();
        _config = config_;
        _scale = SCALE_ONE;
        // The streaming fee's clock starts here; the Initialized event the modifier emits records the moment.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        _lastAccrual = SafeCast.toUint40(block.timestamp);

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
        _issue(shares, to, address(0));
    }

    /// @inheritdoc IIndexHub
    function issue(uint256 shares, address to, address referrer) external nonReentrant onlyInitialized {
        _issue(shares, to, referrer);
    }

    /// @dev Mints `shares` to `to` and the fee's shares to the recipients, then pulls the basket that backs them all.
    function _issue(uint256 shares, address to, address referrer) private {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);
        (bool allowed, address creator, address platform) = _feeTerms(to);
        if (!allowed) revert NotAllowedMinter(to);
        Config memory cfg = _config;
        _accrue(to, creator, platform, cfg);

        // Effects and event first, then pull the basket. The transfer check below makes the
        // mint conditional on receiving every component in full.
        uint256 gross = _grossShares(shares, cfg);
        uint256[] memory amounts = _amounts(gross, _scale, Math.Rounding.Ceil);
        _mint(to, shares);
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Issued(msg.sender, to, shares, amounts);
        _mintFeeShares(
            gross - shares,
            _part(gross - shares, cfg.platformFeeBps, cfg.creatorFeeBps),
            to,
            referrer,
            creator,
            platform
        );

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

    /// @dev Burns first, mints the fee's shares to the recipients out of what was burned, books every skipped component
    ///      as a claim, then transfers the rest: the backing of the burned shares less the fee's.
    function _redeem(uint256 shares, address to, uint256 skipMask) private {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);
        Config memory cfg = _config;
        uint256 feeShares = _feeShares(shares, cfg);
        address creator = address(0);
        address platform = address(0);
        if (feeShares != 0 || _streaming(cfg) != 0) (, creator, platform) = _feeTerms(to);
        _accrue(to, creator, platform, cfg);

        uint256[] memory amounts = _amounts(shares - feeShares, _scale, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, shares, amounts);
        if (feeShares != 0) {
            _mintFeeShares(
                feeShares, _part(feeShares, cfg.platformFeeBps, cfg.creatorFeeBps), to, address(0), creator, platform
            );
        }

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
    // Fees
    // ---------------------------------------------------------------------

    /// @dev Shares the deposit for `shares` must back: the fee's shares on top, rounded up, so every share minted, the
    ///      fee's included, is backed by what the minter pays.
    function _grossShares(uint256 shares, Config memory cfg) private pure returns (uint256) {
        uint256 fee = uint256(cfg.creatorFeeBps) + cfg.platformFeeBps;
        return fee == 0 ? shares : Math.mulDiv(shares, BPS, BPS - fee, Math.Rounding.Ceil);
    }

    /// @dev Whether `to` may be issued shares, and who the recipients are, as the factory answers now.
    function _feeTerms(address to) private view returns (bool allowed, address creator, address platform) {
        // A view on the factory, by STATICCALL: nothing it reaches can change state, so nothing re-enters.
        // aderyn-fp-next-line(reentrancy-state-change)
        return IWeightedIndexFactory(FACTORY).feeTerms(address(this), to);
    }

    /// @dev The fee's shares on a redeem of `shares`, rounded down: what the recipients are minted out of the burn.
    function _feeShares(uint256 shares, Config memory cfg) private pure returns (uint256) {
        return Math.mulDiv(shares, uint256(cfg.creatorFeeBps) + cfg.platformFeeBps, BPS);
    }

    /// @dev The platform's part of `feeShares`: its rate's share of the two rates' sum, rounded down; nothing of
    ///      nothing when both rates are zero.
    function _part(uint256 feeShares, uint256 platformBps, uint256 creatorBps) private pure returns (uint256) {
        uint256 total = platformBps + creatorBps;
        return total == 0 ? 0 : Math.mulDiv(feeShares, platformBps, total);
    }

    /// @dev The two streaming rates' sum, in basis points per year.
    function _streaming(Config memory cfg) private pure returns (uint256) {
        return uint256(cfg.creatorStreamingBps) + cfg.platformStreamingBps;
    }

    /// @dev The same, read from storage, for the views.
    function _storedStreaming() private view returns (uint256) {
        return uint256(_config.creatorStreamingBps) + _config.platformStreamingBps;
    }

    /// @dev Mints the streaming fee accrued since the last accrual and shrinks every share's units by the same factor,
    ///      so the recipients come to own that share of the index and nothing else changes. An empty index accrues
    ///      nothing and restarts the clock; a supply too small for one share of fee keeps it, so the fee is not lost to
    ///      rounding on every call.
    function _accrue(address to, address creator, address platform, Config memory cfg) private {
        uint256 rate = _streaming(cfg);
        if (rate == 0) return;
        (uint256 scale, uint256 feeShares) = _pending(rate);
        if (feeShares == 0) {
            if (totalSupply() == 0) _lastAccrual = SafeCast.toUint40(block.timestamp);
            return;
        }
        _scale = SafeCast.toUint128(scale);
        _lastAccrual = SafeCast.toUint40(block.timestamp);
        // Only a view on the factory, in the caller, precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit StreamingFeeAccrued(feeShares, scale);
        _mintFeeShares(
            feeShares,
            _part(feeShares, cfg.platformStreamingBps, cfg.creatorStreamingBps),
            to,
            address(0),
            creator,
            platform
        );
    }

    /// @dev The scale and the fee's shares an accrual now would leave: the time since the last accrual, as a part of
    ///      a year, times `rate`, is the share `f` of the index the recipients are owed, so they are minted
    ///      `supply · f / (1 − f)` shares and every share's units shrink to `supply / (supply + minted)` of what they
    ///      were, both rounded down. A gap of a lifetime is capped just under the whole, so the arithmetic always
    ///      answers and an exit is never blocked.
    function _pending(uint256 rate) private view returns (uint256 scale, uint256 feeShares) {
        scale = _scale;
        uint256 supply = totalSupply();
        uint256 part = rate * (block.timestamp - _lastAccrual);
        uint256 whole = YEAR * BPS;
        if (supply == 0 || part == 0) return (scale, 0);
        if (part >= whole) part = whole - 1;
        feeShares = Math.mulDiv(supply, part, whole - part);
        scale = Math.mulDiv(scale, supply, supply + feeShares);
    }

    /// @dev The scale the previews and {components} use: what an accrual now would leave.
    function _pendingScale() private view returns (uint256 scale) {
        (scale,) = _pending(_storedStreaming());
    }

    /// @inheritdoc IWeightedHub
    function accrueFees() external nonReentrant onlyInitialized {
        Config memory cfg = _config;
        if (_streaming(cfg) == 0) return;
        (, address creator, address platform) = _feeTerms(msg.sender);
        _accrue(msg.sender, creator, platform, cfg);
    }

    /// @dev Mints `feeShares` to the recipients: `platformShares` to the platform, of which `referrer`, when named and
    ///      able to hold shares, takes the referral share, rounded down; the creator takes the rest. A platform that
    ///      could not hold shares hands its part to the creator, and a creator that could not hands its part to `to`,
    ///      so no recipient can ever block a mint or an exit.
    function _mintFeeShares(
        uint256 feeShares,
        uint256 platformShares,
        address to,
        address referrer,
        address creator,
        address platform
    ) private {
        if (feeShares == 0) return;
        uint256 referrerShares = 0;
        if (referrer != address(0) && !_isTrap(referrer)) {
            referrerShares = Math.mulDiv(platformShares, _config.referralShareBps, BPS);
            platformShares -= referrerShares;
        } else {
            referrer = address(0);
        }
        if (creator == address(0) || _isTrap(creator)) creator = to;
        if (platform == address(0) || _isTrap(platform)) (platform, platformShares) = (address(0), 0);
        uint256 creatorShares = feeShares - platformShares - referrerShares;
        if (creatorShares != 0) _mint(creator, creatorShares);
        if (platformShares != 0) _mint(platform, platformShares);
        if (referrerShares != 0) _mint(referrer, referrerShares);
        // The factory call before this is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeeSharesMinted(referrer, creator, platform, creatorShares, platformShares, referrerShares);
    }

    // ---------------------------------------------------------------------
    // Rebalance
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedHub
    function startRebalance(uint256 keepMask) external nonReentrant onlyInitialized {
        uint256 earliest = lastRebalance + _config.rebalanceInterval;
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
        // The streaming fee first, so the settlement works on the units every share carries after it, scale folded in,
        // and writes new units that carry none.
        Config memory cfg = _config;
        if (_streaming(cfg) != 0) {
            (, address creator, address platform) = _feeTerms(msg.sender);
            _accrue(msg.sender, creator, platform, cfg);
        }
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
            _settlement(mu, settlement.prices, totalSupply(), _unitsAt(_scale));
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

    /// @dev Records the settlement's units, which carry the scale folded in, so the scale starts from one again.
    function _applyRebalance(uint256[] memory units) private returns (uint256 id) {
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            _components[i].units = SafeCast.toUint96(units[i]);
        }
        _scale = SCALE_ONE;
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
            uint256 required = _backing(supply, units[i], WAD, Math.Rounding.Floor) + totalClaims[token];
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

    /// @dev The settlement for these prices at the supply and units given, by STATICCALL into the arithmetic the
    ///      factory deployed with this implementation ({IWeightedMath}): the weights go along, the keep mask too.
    function _settlement(uint256 mu, uint256[] memory prices, uint256 supply, uint256[] memory currentUnits)
        private
        view
        returns (uint256, uint256[] memory, uint256[] memory, uint256[] memory)
    {
        uint256 n = currentUnits.length;
        uint256[] memory weights = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            weights[i] = _terms[i].weight;
        }
        return IWeightedMath(MATH).settlement(mu, prices, supply, currentUnits, weights, _keepMask);
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
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
        units = _unitsAt(_pendingScale());
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
        Config memory cfg = _config;
        return _amounts(_grossShares(shares, cfg), _pendingScale(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IIndexHub
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        Config memory cfg = _config;
        return _amounts(shares - _feeShares(shares, cfg), _pendingScale(), Math.Rounding.Floor);
    }

    /// @inheritdoc IWeightedHub
    function config() external view returns (Config memory) {
        return _config;
    }

    /// @inheritdoc IWeightedHub
    function pendingStreamingFee() external view returns (uint256 feeShares, uint256 scale) {
        (scale, feeShares) = _pending(_storedStreaming());
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
        if (block.timestamp < lastRebalance + _config.rebalanceInterval) return false;
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
        // As the fill will see it: the streaming fee accrued and its scale folded into the units.
        (uint256 pendingScale, uint256 feeShares) = _pending(_storedStreaming());
        return _settlement(mu, read, totalSupply() + feeShares, _unitsAt(pendingScale));
    }

    /// @dev Every component's units with `scale` applied, rounded down: the units a settlement works on once the
    ///      scale is folded in, and what {components} reports.
    function _unitsAt(uint256 scale) private view returns (uint256[] memory units) {
        uint256 n = _components.length;
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            units[i] = scale == WAD ? _components[i].units : Math.mulDiv(_components[i].units, scale, WAD);
        }
    }

    /// @dev Raw amount of every component corresponding to `shares` at `scale`, with the given rounding.
    function _amounts(uint256 shares, uint256 scale, Math.Rounding rounding)
        private
        view
        returns (uint256[] memory amounts)
    {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = _backing(shares, _components[i].units, scale, rounding);
        }
    }

    /// @dev The one place a share count turns into an amount of a component, at `scale` (1e18 = the units as
    ///      recorded; the settlement works at that, having folded the scale in): issue, redeem, the settlement and its
    ///      backing check all go through it.
    function _backing(uint256 shares, uint256 units, uint256 scale, Math.Rounding rounding)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(shares, units * scale, SHARE_UNIT * WAD, rounding);
    }

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
