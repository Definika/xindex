// SPDX-License-Identifier: BUSL-1.1
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
/// @notice An index token fully backed by its components. The components and their weights are fixed at creation.
///         The index rebalances back to those weights at Pyth prices. See {IWeightedHub}.
/// @dev Deployment
///      - {WeightedIndexFactory} deploys each index as an EIP-1167 clone of one implementation.
///      - The factory's constructor deploys the implementation, so `FACTORY`, `PYTH` and `MATH` can be immutables.
///        Immutables live in the bytecode the clones delegate to, so every clone sees the same values.
///      - The storage-based {ReentrancyGuard} needs no initializer: its zero slot means "not entered", so it works in
///        a clone. Every function that mints, burns, pays a claim or changes a rebalance shares it.
///      - Only an initialized clone can issue, redeem or rebalance. The implementation, or a clone deployed outside
///        the factory, has no components and would mint unbacked shares.
///
///      Invariant, for every component i, with units_i as recorded and `scale` the streaming fee's factor (1e18 = one):
///          token_i.balanceOf(index) >= floor(totalSupply * units_i * scale / 1e36) + totalClaims[token_i]
///      - Issue rounds up and redeem rounds down. Each settlement leg rounds its change in backing the same way.
///        So rounding drifts at most one raw unit per leg per call, always in favour of the remaining holders.
///      - A streaming accrual's integer scale can leave at most supply * units / 1e36 more raw units, also theirs.
///      - A claim is recorded only for an amount that stayed in the index, so claims never dilute other holders.
///      - No amount is ever computed from balances. There is no share price to manipulate, and no first-depositor
///        attack.
///
///      Prices
///      - Issue, redeem and claims never read a price. A feed that stops or lies cannot block an exit or misprice a
///        mint, because both are in kind.
///      - Only a settlement reads prices, and only for the moving components. The executor brings a signed Pyth update.
///      - The hub fixes the second the prices belong to ({priceTime}): one slot before the settling block. Pyth's
///        `parsePriceFeedUpdatesUnique` returns only each feed's first update at or after that second. So an executor
///        gets exactly one price per component in each block. It can still choose whether to fill in a block,
///        seeing that price PRICE_LAG ahead (V5-L1).
///      - No two components share a price id: Pyth fills only the first of two equal ids (V5-M1).
///      - Pyth's DAO can upgrade Pyth's contract. Keeping each update unique is Pyth's job.
///      - A price is USD per raw unit scaled by 1e36: `price * 10 ** (36 + expo - decimals)`. The decimals are the
///        ones the factory recorded at listing. No component is ever called to price it.
///
///      Fees
///      - An index charges its creator's rate plus the platform's, both fixed at creation, on every issue and redeem.
///        Fees are paid in shares, never in components.
///      - A minter's deposit backs the fee's shares on top of its own. A burner's fee is minted to the recipients
///        out of the shares it burns. So every share is backed by the deposit that minted it.
///      - The factory names the recipients (the creator and the platform) at each call. A recipient that is missing or
///        cannot hold shares is replaced: the platform's part goes to the creator, and the creator's to the call's
///        `to`. So no recipient can block a mint or an exit.
///      - A referrer named at mint takes the referral share of the platform's part.
///      - A gated index issues only to recipients the factory allows, until its creator opens it.
///
///      Rebalancing
///      - Once the index's rebalance interval has passed, anyone can start a rebalance, while every moving feed
///        publishes. After REBALANCE_DELAY of notice, an auction runs for AUCTION_DURATION. The two together are
///        shorter than any closure of a market a feed follows, so no auction runs into a reopening (RX-3).
///      - At settlement, the moving components' value V = Σ u·p is shared out by weight. Each target is
///        t = w · V / (W · p), rounded up, where W sums the moving weights.
///      - Shrinking legs move to their targets. Growing legs move μ times their gap, rounded up. μ falls linearly from
///        MU_MAX to MU_MIN over the auction.
///      - At the settling prices the executor receives S and delivers μ · S. A lone executor at the end keeps at most
///        (1 − MU_MIN) of the traded value.
///      - The turnover cap does not trust prices. If a shrinking leg would give up more than MAX_TURNOVER of its own
///        units, every leg moves the same smaller share of the way. So one fill sends out at most MAX_TURNOVER of each
///        component it sells, whatever a price says (V5-M2).
///      - A fill that would trade less than MIN_TRADE of the moving value reverts. So a fill that changes nothing
///        cannot restart the rebalance interval (V5-L2).
///      - A fill with a keep mask restarts only MIN_REBALANCE_INTERVAL. A sliver the owner or guardian fills cannot
///        hold the index off for its whole interval, and a keep can be renewed a week later (XS-3).
///      - Transfer amounts come from supply and units alone. The settlement stands only if the invariant holds with
///        the new units, and the whole of `amountsIn` arrived on top of what the index held.
// Every payable entry point forwards all of msg.value to Pyth as its fee, in the same call, so no ether stays here
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
    uint256 public constant AUCTION_DURATION = 4 hours;
    uint256 public constant MU_MAX = 1.02e18;
    uint256 public constant MU_MIN = 0.98e18;
    uint256 public constant MAX_TURNOVER = 0.2e18;
    uint256 public constant MIN_TRADE = 0.001e18;
    uint256 public constant MAX_CONFIDENCE = 0.02e18;
    uint256 public constant MAX_EMA_DEVIATION = 0.05e18;
    uint256 public constant PRICE_LAG = 12;
    uint256 public constant MAX_PRICE = 1e45;
    int256 public constant MIN_EXPO = -18;
    address public immutable FACTORY;
    address public immutable PYTH;
    address public immutable MATH;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 1e4;
    uint256 private constant YEAR = 365 days;
    /// @dev The scale before any streaming fee: one, in the scale's storage width.
    uint128 private constant SCALE_ONE = 1e18;
    /// @dev Decimals of a price in USD per raw unit. A Pyth price is scaled by 10 ** (PRICE_DECIMALS + expo -
    ///      decimals). With expo >= MIN_EXPO and decimals <= MAX_DECIMALS, that power is never negative.
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

    /// @dev One settlement, grouped in memory to save stack slots: the multiplier μ, the second its prices belong to,
    ///      the prices, the new units, and what each leg sends out and takes in.
    struct Settlement {
        uint256 mu;
        uint256 priceTime;
        uint256[] prices;
        uint256[] units;
        uint256[] amountsOut;
        uint256[] amountsIn;
    }

    Component[] private _components;
    Terms[] private _terms;
    Config private _config;
    /// @dev The factor every component's recorded units carry (1e18 = one). Each streaming accrual shrinks it.
    ///      A settlement keeps it as is, so no leg's units are rounded to fold it in (XS-2).
    uint128 private _scale;
    /// @dev When the streaming fee was last accrued, including accruals that owed nothing.
    uint40 private _lastAccrual;
    /// @dev Whether the last settlement had a keep mask. If so, the next rebalance may start MIN_REBALANCE_INTERVAL
    ///      after it, instead of the index's own interval (XS-3).
    bool private _maskedFill;

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
        // The factory checks each rate and the interval. This check covers a clone the factory did not create: it
        // keeps both fee sums inside what the fee arithmetic assumes, and the interval at or above the floor.
        if (
            uint256(config_.creatorFeeBps) + config_.platformFeeBps > MAX_FEE_BPS
                || uint256(config_.creatorStreamingBps) + config_.platformStreamingBps > MAX_STREAMING_BPS
                || config_.referralShareBps > BPS || config_.rebalanceInterval < MIN_REBALANCE_INTERVAL
        ) revert InvalidConfig();
        _config = config_;
        _scale = SCALE_ONE;
        // The streaming fee's clock starts here. The modifier's Initialized event records the moment.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        _lastAccrual = SafeCast.toUint40(block.timestamp);

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        uint256 total = 0;
        // The tokens and price ids seen so far, in memory: comparing the calldata structs again for each pair cost
        // 2.8M gas at a hundred components.
        address[] memory tokens = new address[](n);
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            ComponentInit calldata c = components_[i];
            address token = c.token;
            bytes32 priceId = c.priceId;
            if (
                token == address(0) || c.units == 0 || c.weight == 0 || c.weight > TOTAL_WEIGHT || priceId == bytes32(0)
                    || c.decimals > MAX_DECIMALS
            ) revert InvalidComponents();
            // Pyth fills only the first of two equal ids, so an index whose components share one could never settle
            // (V5-M1). The factory refuses duplicates too; this covers a clone it did not check.
            for (uint256 j = 0; j < i; ++j) {
                if (tokens[j] == token || ids[j] == priceId) revert InvalidComponents();
            }
            tokens[i] = token;
            ids[i] = priceId;
            total += c.weight;
            _components.push(Component({token: token, units: SafeCast.toUint96(c.units)}));
            _terms.push(Terms({priceId: priceId, weight: SafeCast.toUint16(c.weight), decimals: c.decimals}));
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
        _accrueStreamingFee(to, creator, platform, cfg);

        // Effects and event first, then pull the basket. The checks in the loop below revert the whole mint unless
        // every leg already backs the existing supply and every component arrives in full.
        uint256 supply = totalSupply();
        uint256 scale = _scale;
        uint256 gross = _grossShares(shares, cfg);
        uint256[] memory amounts = _basketAmounts(gross, scale, Math.Rounding.Ceil);
        _mint(to, shares);
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Issued(msg.sender, to, shares, amounts);
        _mintFeeShares(
            gross - shares,
            _platformPart(gross - shares, cfg.platformFeeBps, cfg.creatorFeeBps),
            to,
            referrer,
            creator,
            platform
        );

        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            // A leg below what the existing supply needs, as after an issuer burned the index's balance, would hand
            // this deposit to earlier holders. The balance only verifies; no amount comes from it (RX-8).
            uint256 required =
                _backing(supply, _components[i].units, scale, Math.Rounding.Floor) + totalClaims[address(token)];
            if (before < required) revert Underbacked(address(token), before, required);
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            // Rejects fee-on-transfer tokens, even a listed token that starts charging a fee later.
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

    /// @dev Redeems in four steps:
    ///      1. burns `shares` from the caller;
    ///      2. mints the fee's shares to the recipients, out of the burned shares;
    ///      3. books every skipped component as a claim for `to`;
    ///      4. sends `to` the rest: the backing of the burned shares minus the fee's.
    function _redeem(uint256 shares, address to, uint256 skipMask) private {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);
        Config memory cfg = _config;
        uint256 feeShares = _redeemFeeShares(shares, cfg);
        address creator = address(0);
        address platform = address(0);
        if (feeShares != 0 || _streamingRate(cfg) != 0) (, creator, platform) = _feeTerms(to);
        _accrueStreamingFee(to, creator, platform, cfg);

        uint256[] memory amounts = _basketAmounts(shares - feeShares, _scale, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, shares, amounts);
        if (feeShares != 0) {
            _mintFeeShares(
                feeShares,
                _platformPart(feeShares, cfg.platformFeeBps, cfg.creatorFeeBps),
                to,
                address(0),
                creator,
                platform
            );
        }

        uint256 n = amounts.length;
        if (skipMask != 0) {
            for (uint256 i = 0; i < n; ++i) {
                uint256 amount = amounts[i];
                if (amount == 0 || (skipMask & (1 << i)) == 0) continue;
                address token = _components[i].token;
                // Booked to `to`, who receives every other component too. So a router redeeming for a holder does not
                // strand the skipped components (DA-17).
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

    /// @dev The shares a mint of `shares` must back: `shares` plus the fee's shares, rounded up.
    ///      So every share minted, fee shares included, is backed by what the minter pays.
    function _grossShares(uint256 shares, Config memory cfg) private pure returns (uint256) {
        uint256 fee = uint256(cfg.creatorFeeBps) + cfg.platformFeeBps;
        return fee == 0 ? shares : Math.mulDiv(shares, BPS, BPS - fee, Math.Rounding.Ceil);
    }

    /// @dev Asks the factory whether `to` may receive new shares, and who the fee recipients are.
    function _feeTerms(address to) private view returns (bool allowed, address creator, address platform) {
        // A view on the factory, by STATICCALL: nothing it reaches can change state, so nothing re-enters.
        // aderyn-fp-next-line(reentrancy-state-change)
        return IWeightedIndexFactory(FACTORY).feeTerms(address(this), to);
    }

    /// @dev The fee's shares on a redeem of `shares`, rounded down. The recipients are minted these out of the burn.
    function _redeemFeeShares(uint256 shares, Config memory cfg) private pure returns (uint256) {
        return Math.mulDiv(shares, uint256(cfg.creatorFeeBps) + cfg.platformFeeBps, BPS);
    }

    /// @dev The platform's part of `feeShares`, in proportion to its rate, rounded down. Zero when both rates are zero.
    function _platformPart(uint256 feeShares, uint256 platformBps, uint256 creatorBps) private pure returns (uint256) {
        uint256 total = platformBps + creatorBps;
        return total == 0 ? 0 : Math.mulDiv(feeShares, platformBps, total);
    }

    /// @dev The total streaming rate (creator plus platform), in basis points per year.
    function _streamingRate(Config memory cfg) private pure returns (uint256) {
        return uint256(cfg.creatorStreamingBps) + cfg.platformStreamingBps;
    }

    /// @dev {_streamingRate}, read from storage, for the views.
    function _storedStreamingRate() private view returns (uint256) {
        return uint256(_config.creatorStreamingBps) + _config.platformStreamingBps;
    }

    /// @dev Mints the streaming fee owed since the last accrual, and shrinks every share's units by the same factor.
    ///      The recipients come to own that part of the index. No token moves.
    ///      The clock restarts on every accrual, even one that mints nothing. Do not keep the old clock when nothing is
    ///      minted: on a tiny supply it charged the whole idle time to the next minter's deposit (XS-1). The restart
    ///      forgoes under one share per call.
    function _accrueStreamingFee(address to, address creator, address platform, Config memory cfg) private {
        uint256 rate = _streamingRate(cfg);
        if (rate == 0) return;
        (uint256 scale, uint256 feeShares) = _pendingAccrual(rate);
        _lastAccrual = SafeCast.toUint40(block.timestamp);
        if (feeShares == 0) return;
        _scale = SafeCast.toUint128(scale);
        // Only a view on the factory, in the caller, precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit StreamingFeeAccrued(feeShares, scale);
        _mintFeeShares(
            feeShares,
            _platformPart(feeShares, cfg.platformStreamingBps, cfg.creatorStreamingBps),
            to,
            address(0),
            creator,
            platform
        );
    }

    /// @dev The scale and the fee's shares that an accrual now would produce, both rounded down.
    ///      - `f` = `rate` × the time since the last accrual, as a fraction of a year: the part of the index owed.
    ///      - The recipients are minted `supply · f / (1 − f)` shares.
    ///      - Every share's units shrink to `supply / (supply + minted)` of what they were.
    ///      A very long gap is capped just under f = 1, so the arithmetic always answers and an exit is never blocked.
    ///      A fee that would shrink the scale to zero is not charged, so no share is ever left backed by nothing.
    function _pendingAccrual(uint256 rate) private view returns (uint256 scale, uint256 feeShares) {
        scale = _scale;
        uint256 supply = totalSupply();
        // `owedPart / wholeYear` is `f`.
        uint256 owedPart = rate * (block.timestamp - _lastAccrual);
        uint256 wholeYear = YEAR * BPS;
        if (supply == 0 || owedPart == 0) return (scale, 0);
        if (owedPart >= wholeYear) owedPart = wholeYear - 1;
        feeShares = Math.mulDiv(supply, owedPart, wholeYear - owedPart);
        uint256 next = Math.mulDiv(scale, supply, supply + feeShares);
        if (next == 0) return (scale, 0);
        scale = next;
    }

    /// @dev The scale an accrual now would leave. The previews and {components} report at this scale.
    function _pendingScale() private view returns (uint256 scale) {
        (scale,) = _pendingAccrual(_storedStreamingRate());
    }

    /// @inheritdoc IWeightedHub
    function accrueFees() external nonReentrant onlyInitialized {
        Config memory cfg = _config;
        if (_streamingRate(cfg) == 0) return;
        (, address creator, address platform) = _feeTerms(msg.sender);
        _accrueStreamingFee(msg.sender, creator, platform, cfg);
    }

    /// @dev Mints `feeShares` to the fee recipients:
    ///      - `platformShares` to the platform, minus the referral share (rounded down) for `referrer`, if named;
    ///      - the rest to the creator.
    ///      A recipient that is missing or cannot hold shares is replaced: the platform's part goes to the creator, and
    ///      the creator's to `to`. So no recipient can block a mint or an exit. A referrer a gated index's gate would
    ///      refuse as `to` is named nobody, and the platform keeps its part: the minter names the referrer, so the
    ///      gate holds for it as it does for `to`.
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
        // The gate's answer for the referrer comes from the factory, by STATICCALL, as `to`'s did ({_feeTerms}).
        bool referrerAllowed = false;
        if (referrer != address(0)) (referrerAllowed,,) = _feeTerms(referrer);
        if (referrerAllowed && !_cannotHoldShares(referrer)) {
            referrerShares = Math.mulDiv(platformShares, _config.referralShareBps, BPS);
            platformShares -= referrerShares;
        } else {
            referrer = address(0);
        }
        if (creator == address(0) || _cannotHoldShares(creator)) creator = to;
        if (platform == address(0) || _cannotHoldShares(platform)) (platform, platformShares) = (address(0), 0);
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
    function startRebalance(uint256 keepMask, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        onlyInitialized
    {
        uint256 earliest = _earliestRebalance();
        if (block.timestamp < earliest) revert RebalanceTooSoon(earliest);
        uint256 pendingEta = _eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) {
            revert RebalancePending(pendingEta + AUCTION_DURATION);
        }
        uint256 n = _components.length;
        if (keepMask >> n != 0 || n - _countBits(keepMask) < MIN_COMPONENTS) revert InvalidKeepMask(keepMask);
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
        // Every moving feed must publish now, so the market of every leg is open. Started while one is shut, the
        // auction could first be filled at the next open, near MU_MIN; and since REBALANCE_DELAY + AUCTION_DURATION
        // is shorter than any closure, an auction started now ends before the next open (RX-3).
        // The prices are dropped on purpose: the read is the check, and only a settlement uses a price.
        // wake-disable-next-line unchecked-return-value
        _readPrices(priceUpdate, _priceTime()); // aderyn-fp(unchecked-return)
    }

    /// @dev The earliest time the next rebalance may start: the index's interval after the last settlement, or only
    ///      MIN_REBALANCE_INTERVAL if that settlement had a keep mask, whatever mask the next start names (XS-3).
    ///      So a sliver fill holds the index off a week at most. And the guardian can renew a keep around a frozen
    ///      component as soon as anyone could start without one.
    function _earliestRebalance() private view returns (uint256) {
        return lastRebalance + (_maskedFill ? MIN_REBALANCE_INTERVAL : _config.rebalanceInterval);
    }

    /// @dev How many bits `mask` sets. A keep mask must leave two components moving: one alone is always on its own
    ///      weight, so there is nothing to trade (V5-L2).
    function _countBits(uint256 mask) private pure returns (uint256 count) {
        count = 0;
        while (mask != 0) {
            mask &= mask - 1;
            ++count;
        }
    }

    /// @dev The earliest time anyone, not only the owner or guardian, may start a rebalance.
    ///      A cancel holds strangers off for REBALANCE_DELAY. So does an auction that expired unfilled (`pendingEta` is
    ///      then the expired proposal's). This gives the owner and guardian the first move. They are never held off.
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
        // Cancelling an auction that already expired only clears the stale proposal. Its expiry already holds
        // strangers off until its deadline plus REBALANCE_DELAY. Restarting the delay from now would push that out
        // for no reason (VR-04).
        uint256 restartAt =
            block.timestamp <= eta + AUCTION_DURATION ? block.timestamp + REBALANCE_DELAY : _permissionlessAt(eta);
        _clearPendingRebalance();
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

    /// @dev Settles the pending rebalance: prices it, records the new units, pays the executor what the index sells,
    ///      calls it back to deliver what the index buys, then checks the backing.
    function _settle(bytes calldata data, bytes[] calldata priceUpdate, uint256[] memory maxAmountsIn) private {
        // Accrue the streaming fee first, so the settlement moves each leg's backing at the scale shares carry after
        // it. The new units carry that same scale, so nothing is rounded to fold it in (XS-2).
        Config memory cfg = _config;
        if (_streamingRate(cfg) != 0) {
            (, address creator, address platform) = _feeTerms(msg.sender);
            _accrueStreamingFee(msg.sender, creator, platform, cfg);
        }
        uint256 scale = _scale;
        Settlement memory settlement = _buildSettlement(priceUpdate, scale);
        _checkMaxAmountsIn(settlement.amountsIn, maxAmountsIn);
        uint256[] memory held = _balancesBefore(settlement.amountsOut, settlement.amountsIn);

        // Effects first: the new units, the nonce and the cleared proposal are written before any token moves.
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
            settlement.priceTime,
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
        // The executor must be called back to deliver the growing components, so this cannot be the last interaction.
        // It is safe: every function that mints, burns, pays a claim or rebalances shares the guard, and the backing
        // check below reads only the final state. Wake's reentrancy detector does not model the guard.
        // wake-disable-next-line reentrancy
        IRebalanceExecutor(msg.sender).onXindexRebalance(settlement.amountsOut, settlement.amountsIn, data);
        _checkBacking(settlement.units, scale, settlement.amountsOut, settlement.amountsIn, held);
    }

    /// @dev Builds the settlement for this block. Checks that the auction is open, reads the prices through Pyth at
    ///      {priceTime}, and computes the amounts at the current supply and `scale`.
    function _buildSettlement(bytes[] calldata priceUpdate, uint256 scale)
        private
        returns (Settlement memory settlement)
    {
        uint256 mu = _openMu();
        settlement.priceTime = _priceTime();
        settlement.prices = _readPrices(priceUpdate, settlement.priceTime);
        (settlement.mu, settlement.units, settlement.amountsOut, settlement.amountsIn) =
            _computeSettlement(mu, settlement.prices, totalSupply(), scale);
    }

    /// @dev Reverts if any leg would take in more than the executor's `maxAmountsIn`. An empty array means no bound.
    ///      Settlement amounts grow with the supply, and issue stays open during the auction. So a stranger can enlarge
    ///      them between an executor's simulation and its transaction. This lets the executor cap the fill (DA-13).
    function _checkMaxAmountsIn(uint256[] memory amountsIn, uint256[] memory maxAmountsIn) private view {
        uint256 bounds = maxAmountsIn.length;
        if (bounds == 0) return;
        if (bounds != amountsIn.length) revert LengthMismatch();
        for (uint256 i = 0; i < bounds; ++i) {
            if (amountsIn[i] > maxAmountsIn[i]) {
                revert RebalanceMovedOn(_components[i].token, amountsIn[i], maxAmountsIn[i]);
            }
        }
    }

    /// @dev The index's balance of each moving component before it pays out.
    ///      The check after the callback requires the whole of `amountsIn` on top of it. So surplus from rounding or a
    ///      donation stays with the holders, not the executor.
    ///      A component that neither sends nor receives is not read at all. So a keep mask still works around a
    ///      component whose `balanceOf` reverts (DA-14).
    function _balancesBefore(uint256[] memory amountsOut, uint256[] memory amountsIn)
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

    /// @dev Reads the moving components' prices at `time` from `priceUpdate`, and forwards all of msg.value to Pyth as
    ///      its fee. Pyth returns each feed's first update published at or after `time` and before this block, or
    ///      reverts. This function checks the ids, order and window again rather than trusting them.
    function _readPrices(bytes[] calldata priceUpdate, uint256 time) private returns (uint256[] memory prices) {
        uint256 n = _components.length;
        uint256 keepMask = _keepMask;
        // The mask never reaches past the components: startRebalance refuses one that does.
        uint256 moving = n - _countBits(keepMask);
        bytes32[] memory ids = new bytes32[](moving);
        uint256 k = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) ids[k++] = _terms[i].priceId;
        }

        uint256 latestPublishTime = time + PRICE_LAG - 1;
        // Pyth is a fixed, trusted dependency, and the guard covers anything it could call back into.
        // wake-disable-next-line reentrancy
        PythStructs.PriceFeed[] memory feeds = IPyth(PYTH).parsePriceFeedUpdatesUnique{value: msg.value}(
            priceUpdate, ids, SafeCast.toUint64(time), SafeCast.toUint64(latestPublishTime)
        );
        if (feeds.length != moving) revert PriceMismatch(bytes32(0), 0);

        prices = new uint256[](n);
        k = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            PythStructs.PriceFeed memory feed = feeds[k];
            uint256 published = feed.price.publishTime;
            if (feed.id != ids[k] || published < time || published > latestPublishTime) {
                revert PriceMismatch(feed.id, published);
            }
            prices[i] = _checkedPrice(feed, i);
            ++k;
        }
    }

    /// @dev `feed`'s price for component `i`, converted by {_scaledPrice} and refused unless it is near its moving
    ///      average ({_checkEma}): every check a fill makes on a price, which {previewRebalance} makes too.
    function _checkedPrice(PythStructs.PriceFeed memory feed, uint256 i) private view returns (uint256 price) {
        price = _scaledPrice(feed.price, i);
        _checkEma(feed.price, feed.emaPrice, i);
    }

    /// @dev Converts `p` to USD per raw unit of component `i`, scaled by 1e36: `price * 10 ** (36 + expo - decimals)`,
    ///      with the decimals recorded at listing. Reverts on any of:
    ///      - a price of zero or below;
    ///      - an exponent outside [MIN_EXPO, 0];
    ///      - a confidence interval wider than MAX_CONFIDENCE of the price;
    ///      - a result above MAX_PRICE.
    function _scaledPrice(PythStructs.Price memory p, uint256 i) private view returns (uint256) {
        int256 expo = p.expo;
        if (p.price <= 0 || expo > 0 || expo < MIN_EXPO) revert PriceOutOfRange(_components[i].token, p.price, p.expo);
        // Positive, checked above, so the cast keeps the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(int256(p.price));
        if (uint256(p.conf) * WAD > price * MAX_CONFIDENCE) {
            revert PriceUncertain(_components[i].token, p.price, p.conf);
        }
        // Never negative: expo is in [MIN_EXPO, 0] and decimals <= MAX_DECIMALS (checked at initialization), so the
        // exponent is between PRICE_DECIMALS + MIN_EXPO - MAX_DECIMALS = 0 and PRICE_DECIMALS.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 exponent = uint256(int256(PRICE_DECIMALS) + expo) - _terms[i].decimals;
        // Below 2^63 * 10^36, so the product fits.
        uint256 value = price * 10 ** exponent;
        if (value > MAX_PRICE) revert PriceOutOfRange(_components[i].token, p.price, p.expo);
        return value;
    }

    /// @dev Reverts unless `p` is within MAX_EMA_DEVIATION of `ema`, the moving average Pyth publishes in the same
    ///      update, at the same exponent. A push of a few seconds on thin venues moves the price far more than its
    ///      average, so it cannot set the price of a fill (RX-27). `p` is positive, checked by {_scaledPrice}.
    function _checkEma(PythStructs.Price memory p, PythStructs.Price memory ema, uint256 i) private view {
        // Both positive, checked here and in {_scaledPrice}, so the casts keep the values.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(int256(p.price));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 average = ema.price > 0 ? uint256(int256(ema.price)) : 0;
        uint256 gap = price > average ? price - average : average - price;
        if (ema.expo != p.expo || average == 0 || gap * WAD > average * MAX_EMA_DEVIATION) {
            revert PriceOffAverage(_components[i].token, p.price, ema.price);
        }
    }

    /// @dev Writes the settlement's new units (they carry the same scale as the old ones), records whether it had a
    ///      keep mask, bumps the nonce and clears the pending rebalance.
    function _applyRebalance(uint256[] memory units) private returns (uint256 id) {
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            _components[i].units = SafeCast.toUint96(units[i]);
        }
        _maskedFill = _keepMask != 0;
        id = ++rebalanceNonce;
        lastRebalance = block.timestamp;
        _clearPendingRebalance();
    }

    function _clearPendingRebalance() private {
        delete _eta;
        delete _keepMask;
    }

    /// @dev Runs after the executor returns. For every leg that moved, requires the index's balance to cover both:
    ///      - the backing invariant with the new units at `scale`;
    ///      - what it held before paying out, minus `amountsOut`, plus the whole of `amountsIn`.
    ///      And every leg the index bought must still be able to leave it: the index sends itself one raw unit of it,
    ///      measured. A token that blocks only its sender, as Tether Gold does, would otherwise let a fill move good
    ///      legs into a leg no holder can take out (RX-12).
    function _checkBacking(
        uint256[] memory units,
        uint256 scale,
        uint256[] memory amountsOut,
        uint256[] memory amountsIn,
        uint256[] memory held
    ) private {
        uint256 supply = totalSupply();
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            // Nothing moved, so nothing is read: see {_balancesBefore} (DA-14).
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            address token = _components[i].token;
            uint256 required = _backing(supply, units[i], scale, Math.Rounding.Floor) + totalClaims[token];
            uint256 delivered = held[i] - amountsOut[i] + amountsIn[i];
            if (delivered > required) required = delivered;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < required) revert RebalanceUnderfunded(token, balance, required);
            if (amountsIn[i] == 0) continue;
            // Under the guard, and after every check of the settlement has read its balances.
            if (!IERC20(token).trySafeTransfer(address(this), 1) || IERC20(token).balanceOf(address(this)) < balance) {
                revert CannotSendOut(token);
            }
        }
    }

    /// @dev μ in this block. Reverts unless an auction is open. The decrement rounds down, so μ rounds up, in the
    ///      holders' favour.
    function _openMu() private view returns (uint256) {
        uint256 eta = _eta;
        if (eta == 0) revert NoPendingRebalance();
        if (block.timestamp < eta) revert RebalanceNotReady(eta);
        if (block.timestamp > eta + AUCTION_DURATION) revert RebalanceExpired(eta + AUCTION_DURATION);
        return MU_MAX - Math.mulDiv(MU_MAX - MU_MIN, block.timestamp - eta, AUCTION_DURATION);
    }

    /// @dev Computes the settlement for these prices, supply and scale from the recorded units, weights and keep mask.
    ///      The arithmetic lives in {IWeightedMath}, which the factory deployed with this implementation; it is called
    ///      by STATICCALL.
    function _computeSettlement(uint256 mu, uint256[] memory prices, uint256 supply, uint256 scale)
        private
        view
        returns (uint256, uint256[] memory, uint256[] memory, uint256[] memory)
    {
        uint256 n = _components.length;
        uint256[] memory currentUnits = new uint256[](n);
        uint256[] memory weights = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            currentUnits[i] = _components[i].units;
            weights[i] = _terms[i].weight;
        }
        return IWeightedMath(MATH).settlement(mu, prices, supply, scale, currentUnits, weights, _keepMask);
    }

    /// @dev The second whose prices a settlement in this block reads: PRICE_LAG (one slot) before the block.
    ///      Pyth has published it by then, and the executor sees it at most one slot ahead. Do not widen this to a
    ///      minute: an executor could then choose its fill against two minutes of the market (V5-L1).
    function _priceTime() private view returns (uint256) {
        return block.timestamp - PRICE_LAG;
    }

    function _checkInitialized() private view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (_cannotHoldShares(to)) revert InvalidRecipient(to);
    }

    /// @dev Every transfer refuses an address that cannot hold shares, as issue, redeem and claim do (CR-I01, RT-21).
    function _update(address from, address to, uint256 value) internal override {
        if (_cannotHoldShares(to)) revert InvalidRecipient(to);
        super._update(from, to, value);
    }

    /// @dev The index itself and its factory: shares or tokens sent there could never leave again.
    function _cannotHoldShares(address to) private view returns (bool) {
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
        return _tokens();
    }

    /// @inheritdoc IWeightedHub
    function components() external view returns (address[] memory tokens, uint256[] memory units) {
        return (_tokens(), _scaledUnits(_pendingScale()));
    }

    /// @dev Every component's token, in component order.
    function _tokens() private view returns (address[] memory tokens) {
        uint256 n = _components.length;
        tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
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
        Config memory cfg = _config;
        return _basketAmounts(_grossShares(shares, cfg), _pendingScale(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IIndexHub
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        Config memory cfg = _config;
        return _basketAmounts(shares - _redeemFeeShares(shares, cfg), _pendingScale(), Math.Rounding.Floor);
    }

    /// @inheritdoc IWeightedHub
    function config() external view returns (Config memory) {
        return _config;
    }

    /// @inheritdoc IWeightedHub
    function pendingStreamingFee() external view returns (uint256 feeShares, uint256 scale) {
        (scale, feeShares) = _pendingAccrual(_storedStreamingRate());
    }

    /// @inheritdoc IWeightedHub
    function lastAccrual() external view returns (uint256) {
        return _lastAccrual;
    }

    /// @inheritdoc IWeightedHub
    function earliestRebalance() external view returns (uint256) {
        return _earliestRebalance();
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
        // The implementation, or a clone deployed outside the factory, holds no components and cannot rebalance
        // (DA-22).
        if (_getInitializedVersion() != 1) return false;
        if (block.timestamp < _earliestRebalance()) return false;
        uint256 pendingEta = _eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) return false;
        return block.timestamp >= _permissionlessAt(pendingEta);
    }

    /// @inheritdoc IWeightedHub
    function previewRebalance(PythStructs.PriceFeed[] calldata feeds)
        external
        view
        returns (uint256 mu, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        uint256 n = _components.length;
        if (feeds.length != n) revert PriceCountMismatch(feeds.length);
        mu = _openMu();
        uint256 keepMask = _keepMask;
        uint256[] memory scaledPrices = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) scaledPrices[i] = _checkedPrice(feeds[i], i);
        }
        // As the fill will see it: after the streaming fee accrues, at the scale that leaves.
        (uint256 pendingScale, uint256 feeShares) = _pendingAccrual(_storedStreamingRate());
        return _computeSettlement(mu, scaledPrices, totalSupply() + feeShares, pendingScale);
    }

    /// @dev Every component's units with `scale` applied, rounded down. {components} reports these.
    function _scaledUnits(uint256 scale) private view returns (uint256[] memory units) {
        uint256 n = _components.length;
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            units[i] = Math.mulDiv(_components[i].units, scale, WAD);
        }
    }

    /// @dev The raw amount of every component that backs `shares` at `scale`, with the given rounding.
    function _basketAmounts(uint256 shares, uint256 scale, Math.Rounding rounding)
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

    /// @dev The one place a share count becomes an amount of a component, at `scale` (1e18 = the units as recorded).
    ///      Issue, redeem and the settlement's backing check all use it. {IWeightedMath} uses the same formula.
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
