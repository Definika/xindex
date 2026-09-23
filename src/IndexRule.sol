// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexRule} from "./interfaces/IIndexRule.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {Methodology} from "./libraries/Methodology.sol";

/// @title IndexRule
/// @notice Reads each token's timelocked reference supply and its Chainlink USD price and applies an index's weighting
///         rule. See {IIndexRule}.
/// @dev Deployed by the factory constructor, so `FACTORY` is the factory whose token configs it reads. It keeps no
///      state, holds no funds, and every function is a view. It reads no Uniswap pool: depth, observation rings and
///      sub-window agreement are no longer inputs to anything.
///
///      It reads no supply live either. A market cap is the reference supply the token's config names times the feed
///      price, and a zero reference supply is refused. A token's own `totalSupply` could be moved inside the very
///      transaction that snapshots it: flash-borrowed wstETH unwrapped around `startRebalance` cut its measured supply
///      by a third for two wei, forcing rebalances the rule refused and reshaping their targets (CR-M01). A supply
///      behind the listing timelock and the guardian's veto cannot be moved that way.
///
///      A WAD price is USD with 18 decimals per 1e18 raw units of a token: for a feed of `fd` decimals quoting a token
///      of `td` decimals, `answer * 10 ** (36 - fd - td)`. Both decimals are capped at 18, so the exponent never
///      underflows, and both are read live on every call rather than stored, so a proxy repointed to an aggregator with
///      other decimals cannot misprice. Units, supplies and prices are all raw, so token decimals cancel out.
///
///      A WAD price is bounded by MAX_PRICE, so the rule's products stay inside 256 bits. A market cap is supply times
///      price over WAD, floored at one wei; weights use only ratios of caps, so that scale cancels out. A holding's
///      value is units times price, exact while every price is at most MAX_EXACT_PRICE and divided by WAD above it
///      (`Basket.scale`). Ordinary baskets are therefore unchanged to the wei, and a feed reporting an absurd answer
///      yields a revert rather than an arithmetic panic.
///
///      Rebalance targets keep the value of the rebalanced components at snapshot prices. Each pass shares the value
///      not yet pinned among the components still free, `value * weight / price` each, and clips every share to
///      [units / 2, units * 2]. When the clips add more value than they remove, the shares have to come down, so a
///      component clipped up to its floor is certain to end there and is pinned; otherwise the components clipped down
///      to their ceiling are. The rest are shared out again, until a pass clips nothing. A pinned component never
///      moves again, so a component the rule wants to shrink further than its floor is never handed value back. A
///      weight that rounds to zero counts as one wei here, so no clipped value is ever left unplaced, and a share is
///      turned back into units rounded up, so the targets buy back every wei the shrinking components release.
///
///      A kept component is not read at all under the uncapped methodology. The capped methodology does read it,
///      through the same checked `_price` as every other component (DA-06). While no ceiling binds, every weight is the
///      component's own market-cap weight, so the kept cap divides out of the active set exactly as it does under the
///      uncapped methodology and cannot move anything. Where a ceiling does bind, it still shapes the components that
///      do move, because it decides which of them the excess is redistributed to and how large the top ceiling is
///      (VR-02): a keep mask is then an owner-or-guardian lever over the targets as well as over which component
///      trades. Excluding kept components from the capped weights instead would leave fewer than
///      MIN_CAPPED_COMPONENTS ranks to place the remainder in, which is the feasibility condition the capped rule
///      needs, so the ranking stays and the residue is documented.
contract IndexRule is IIndexRule {
    /// @inheritdoc IIndexRule
    /// @dev A price this high makes one raw unit of a token worth 1e20 dollars, which no market reaches; only a broken
    ///      or malicious feed gets there. Above MAX_EXACT_PRICE every value is divided by WAD (`Basket.scale`), so
    ///      MAX_COMPONENTS holdings of up to 2^96 - 1 units at this price come to about 1.6e68, well below
    ///      type(uint256).max. `Math.mulDiv` carries the undivided product, so only the divided value has to fit.
    uint256 public constant MAX_PRICE = 1e56;
    /// @inheritdoc IIndexRule
    /// @dev Twice the longest heartbeat among the feeds this ships with, so a token's own bound is always the binding
    ///      one and this is only a ceiling on what the owner can propose.
    uint32 public constant MAX_FEED_STALENESS = 2 days;
    /// @inheritdoc IIndexRule
    /// @dev An auction can deliver 1.5 times a growing component's extra units, so a raised target stays at most 2/3 of
    ///      uint96 and 1.5 times it is exactly type(uint96).max.
    uint256 public constant MAX_TARGET_UNITS = uint256(type(uint96).max) * 2 / 3;

    /// @inheritdoc IIndexRule
    address public immutable FACTORY;

    uint256 private constant WAD = 1e18;
    /// @dev Highest WAD price whose value products stay exact, with a scale of 1: MAX_COMPONENTS holdings of up to
    ///      2^96 - 1 units come to about 1.6e76, below type(uint256).max. A price this high makes one raw unit worth
    ///      1e10 dollars, which no market reaches; above it the rule divides every value by WAD (`Basket.scale`).
    uint256 private constant MAX_EXACT_PRICE = 1e46;
    /// @dev Decimals a WAD price is expressed in, so the conversion exponent is DECIMAL_BUDGET - fd - td.
    uint256 private constant DECIMAL_BUDGET = 36;
    /// @dev Most decimals either a feed or a token may report, so the exponent above never underflows.
    uint8 private constant MAX_DECIMALS = 18;
    uint256 private constant CAPPED_TOP_WEIGHT = 0.3e18;
    uint256 private constant CAPPED_MAX_WEIGHT = 0.2e18;

    /// @dev Snapshot prices, weights and per-component bounds of one rebalance, kept in one struct for the stack.
    ///      `scale` divides every value (units times price): 1 while the exact products fit, WAD above that.
    struct Basket {
        uint256[] prices;
        uint256[] weights;
        uint256[] lo;
        uint256[] hi;
        uint256 scale;
    }

    constructor() {
        FACTORY = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Configuration and market data
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexRule
    function checkConfig(address token, IIndexFactory.TokenConfig calldata config) external view {
        if (config.feed == address(0) || config.feed.code.length == 0) revert InvalidFeed(token, config.feed);
        if (config.maxStaleness == 0 || config.maxStaleness > MAX_FEED_STALENESS) {
            revert InvalidStaleness(token, config.maxStaleness);
        }
        // Every check the rule applies when it prices the token, applied once here, so a config that cannot be priced
        // is refused at the proposal and again at execution rather than discovered at the next rebalance. The price
        // itself is not wanted, only the reverts: at listing time there is nothing to compare it against.
        // forge-lint: disable-next-line(unused-return)
        // wake-disable-next-line unchecked-return-value
        _price(token, config.feed, config.maxStaleness);
        // Every token carries a reference supply. Zero once meant "read the token's own total supply", which anyone
        // who can mint or burn the token -- by wrapping, unwrapping, depositing or withdrawing -- could move inside the
        // transaction that snapshots it (CR-M01). Refusing it here also leaves the DA-18 bound with no switch of kind to
        // slip through, because the figure in force and the one proposed are always both reference supplies (CR-L03).
        if (config.referenceSupply == 0) revert ZeroSupply(token);
    }

    /// @inheritdoc IIndexRule
    /// @dev The two sides of a settlement, valued in the settling block. `IndexToken` holds them against its own floor:
    ///      the auction band fixes the multiplier on the bought legs at snapshot prices, and says nothing about how far
    ///      the market moved in the up to three days before the fill (DA-05). They gate the settlement and never size
    ///      it, so the amounts that move stay derived from supply and units alone.
    function settlementValues(address[] calldata tokens, uint256[] calldata amountsOut, uint256[] calldata amountsIn)
        external
        view
        returns (uint256 outValue, uint256 inValue)
    {
        if (amountsOut.length != tokens.length || amountsIn.length != tokens.length) revert LengthMismatch();
        // Assigned before the loop: a settlement that moves nothing on any leg is worth nothing on both sides.
        outValue = 0;
        inValue = 0;
        for (uint256 i = 0; i < tokens.length; ++i) {
            // Nothing moved on this leg, so nothing about its feed matters here (DA-14).
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(tokens[i]);
            uint256 p = _price(tokens[i], config.feed, config.maxStaleness);
            outValue += Math.mulDiv(amountsOut[i], p, WAD);
            inValue += Math.mulDiv(amountsIn[i], p, WAD);
        }
    }

    /// @inheritdoc IIndexRule
    function price(address token) external view returns (uint256) {
        IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(token);
        return _price(token, config.feed, config.maxStaleness);
    }

    /// @inheritdoc IIndexRule
    function supply(address token) external view returns (uint256) {
        return IIndexFactory(FACTORY).tokenConfig(token).referenceSupply;
    }

    // ---------------------------------------------------------------------
    // Weights, targets and prices
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexRule
    function weightsFromCaps(uint256[] calldata caps, uint8 methodology) external pure returns (uint256[] memory) {
        return _weights(caps, methodology);
    }

    /// @inheritdoc IIndexRule
    function weights(address[] calldata tokens, uint8 methodology)
        external
        view
        returns (uint256[] memory w, uint256[] memory prices, uint256[] memory supplies)
    {
        uint256[] memory caps;
        (prices, supplies, caps) = _market(tokens);
        w = _weights(caps, methodology);
    }

    /// @inheritdoc IIndexRule
    function targetUnits(address[] calldata tokens, uint256[] calldata units, uint8 methodology, uint256 keepMask)
        external
        view
        returns (uint256[] memory targets, uint256 turnover)
    {
        uint256 n = tokens.length;
        if (n != units.length) revert LengthMismatch();
        (uint256[] memory prices, uint256[] memory caps) = _snapshotMarket(tokens, methodology, keepMask);
        Basket memory basket = Basket({
            prices: prices,
            weights: _weights(caps, methodology),
            lo: new uint256[](n),
            hi: new uint256[](n),
            scale: _valueScale(prices)
        });
        return _targets(units, basket, keepMask);
    }

    /// @inheritdoc IIndexRule
    function navPerToken(address index) external view returns (uint256 usdValue) {
        if (!IIndexFactory(FACTORY).isIndex(index)) revert NotIndex(index);
        (address[] memory tokens, uint256[] memory units) = IIndexToken(index).components();
        usdValue = 0;
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(tokens[i]);
            usdValue += Math.mulDiv(units[i], _price(tokens[i], config.feed, config.maxStaleness), WAD);
        }
    }

    /// @inheritdoc IIndexRule
    function initialUnits(address[] calldata tokens, uint8 methodology, uint256 startPriceUsd)
        external
        view
        returns (uint256[] memory units)
    {
        (uint256[] memory prices,, uint256[] memory caps) = _market(tokens);
        uint256[] memory w = _weights(caps, methodology);
        uint256 n = tokens.length;
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            // A start price so low that a component's units round away entirely cannot describe the basket at all,
            // and the index that came out of it would be coarse enough for a rebalance to move less than one raw unit
            // of a component (DA-09). Floor it at one unit and the caller never learns; refuse it instead.
            units[i] = Math.mulDiv(startPriceUsd, w[i], prices[i]);
            if (units[i] == 0) revert StartPriceTooLow(tokens[i], startPriceUsd);
        }
    }

    // ---------------------------------------------------------------------
    // Market data internals
    // ---------------------------------------------------------------------

    /// @dev The one price path. A feed answer becomes USD-WAD per 1e18 raw units, after four checks that every caller
    ///      gets: the answer is positive, it is no older than this token's bound, the feed and the token each report at
    ///      most MAX_DECIMALS, and the converted price is at most MAX_PRICE. Decimals are read live, never cached, so
    ///      the answer and its scale always come from the same aggregator in the same block.
    function _price(address token, address feed, uint32 maxStaleness) private view returns (uint256) {
        if (feed == address(0)) revert InvalidFeed(token, feed);
        // Only the answer and its timestamp are read: `roundId` and `answeredInRound` are pre-OCR vestiges.
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(token, answer);
        // A timestamp in the future is not a fresh answer, it is a broken one; fail closed rather than underflow.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(token, updatedAt);
        }
        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (feedDecimals > MAX_DECIMALS || tokenDecimals > MAX_DECIMALS) {
            revert InvalidDecimals(token, tokenDecimals, feedDecimals);
        }
        uint256 scale = 10 ** (DECIMAL_BUDGET - feedDecimals - tokenDecimals);
        // Both casts are safe because `answer` was checked positive above, so the sign bit is clear.
        // Divided rather than multiplied, so an absurd answer raises this error instead of a panic.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint256(answer) > MAX_PRICE / scale) revert PriceTooHigh(token, answer);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer) * scale;
    }

    /// @dev WAD as soon as one price is too high for exact value products, 1 otherwise. One scale for the whole
    ///      basket, so values stay comparable.
    function _valueScale(uint256[] memory prices) private pure returns (uint256) {
        uint256 n = prices.length;
        for (uint256 i = 0; i < n; ++i) {
            if (prices[i] > MAX_EXACT_PRICE) return WAD;
        }
        return 1;
    }

    /// @dev Market cap in WAD-scaled dollars: supply times price over WAD, floored at one wei so a component with a
    ///      supply and a price never ranks as worthless. Weights only use ratios of caps, so the scale cancels out.
    function _cap(uint256 supply_, uint256 p) private pure returns (uint256) {
        return Math.max(Math.mulDiv(supply_, p, WAD), 1);
    }

    /// @dev Prices, supplies and caps of `tokens`. A token with no config has no feed and `_price` names that, so every
    ///      supply read here comes from a config the rule accepted, which is never zero.
    function _market(address[] calldata tokens)
        private
        view
        returns (uint256[] memory prices, uint256[] memory supplies, uint256[] memory caps)
    {
        uint256 n = tokens.length;
        prices = new uint256[](n);
        supplies = new uint256[](n);
        caps = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(tokens[i]);
            prices[i] = _price(tokens[i], config.feed, config.maxStaleness);
            supplies[i] = config.referenceSupply;
            caps[i] = _cap(supplies[i], prices[i]);
        }
    }

    /// @dev Prices and caps for a rebalance snapshot. A kept component never trades, and the uncapped methodology does
    ///      not read it (its weight is renormalised away and a zero price and cap leave the targets unchanged). The
    ///      capped methodology does read it: its cap sits in the denominator of every other component's weight, so a
    ///      stale feed there would otherwise reshape the targets and the turnover of the components that do trade
    ///      (DA-06). It is therefore priced like every other component, which narrows XA-05: under the capped
    ///      methodology a keep mask routes around a component that cannot be transferred, not around one whose feed
    ///      cannot be read. Since the ceilings became caps rather than allocations, a kept cap moves nothing while no
    ///      ceiling binds, because every weight is then the component's own; where one does bind, it still decides
    ///      which components the excess is shared with and how large the top ceiling is (VR-02). The supply is the
    ///      config's reference figure, never a live read, so nothing done inside the snapshot's transaction can move a
    ///      market cap (CR-M01).
    function _snapshotMarket(address[] calldata tokens, uint8 methodology, uint256 keepMask)
        private
        view
        returns (uint256[] memory prices, uint256[] memory caps)
    {
        uint256 n = tokens.length;
        prices = new uint256[](n);
        caps = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (_kept(keepMask, i) && methodology == Methodology.UNCAPPED) continue;
            IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(tokens[i]);
            prices[i] = _price(tokens[i], config.feed, config.maxStaleness);
            caps[i] = _cap(config.referenceSupply, prices[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Rule internals
    // ---------------------------------------------------------------------

    function _weights(uint256[] memory caps, uint8 methodology) private pure returns (uint256[] memory) {
        if (methodology == Methodology.UNCAPPED) return _uncappedWeights(caps);
        if (methodology == Methodology.CAPPED) return _cappedWeights(caps);
        revert InvalidMethodology(methodology);
    }

    function _uncappedWeights(uint256[] memory caps) private pure returns (uint256[] memory w) {
        uint256 n = caps.length;
        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            total += caps[i];
        }
        if (total == 0) revert DegenerateBasket();
        w = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            w[i] = Math.mulDiv(caps[i], WAD, total);
        }
    }

    /// @dev Market-cap weights under a per-component ceiling: the top ceiling for the largest (see `_top`), and
    ///      CAPPED_MAX_WEIGHT for every other. Each pass gives every component still under its ceiling its share of
    ///      what is left in proportion to market cap, pins the ones that reach it, and shares the rest again, so at
    ///      most one pass per component runs. The ceilings are a cap, not an allocation: a component whose market cap
    ///      does not reach its ceiling keeps its own weight and nothing is redistributed to it (VR-01).
    ///
    ///      The ceilings sum to at least one for MIN_CAPPED_COMPONENTS components: exactly 5 * 0.2 = 1.0 when the two
    ///      largest caps tie, and more for any lead. The weights in a pass sum to at most what is left, so either a
    ///      pass pins nothing, or every component reaches its ceiling and the whole weight is placed; one of the two
    ///      comes within one pass per component. A basket whose unpinned ranks all have a zero cap while weight is
    ///      still left to place has nowhere to put it and is degenerate.
    function _cappedWeights(uint256[] memory caps) private pure returns (uint256[] memory w) {
        uint256 n = caps.length;
        if (n < Methodology.MIN_CAPPED_COMPONENTS) revert TooFewComponentsForCapped(n);
        (uint256 first, uint256 topCeiling) = _top(caps);
        uint256 pool = 0;
        for (uint256 i = 0; i < n; ++i) {
            pool += caps[i];
        }
        if (pool == 0) revert DegenerateBasket();

        w = new uint256[](n);
        uint256 share = WAD;
        for (uint256 pass = 0; pass < n; ++pass) {
            (uint256 pinnedWeight, uint256 pinnedCap) = _capPass(w, caps, first, topCeiling, share, pool);
            if (pinnedWeight == 0) return w;
            share -= pinnedWeight;
            // The ceilings pinned so far add up to the whole weight: every component sits on its ceiling, as five
            // equal caps do once both leaders carry 20%. Nothing is left to share, and the pool may be empty.
            if (share == 0) return w;
            pool -= pinnedCap;
            if (pool == 0) revert DegenerateBasket();
        }
    }

    /// @dev One pass of `_cappedWeights`: every component not yet pinned gets `share` of the weight in proportion to
    ///      its part of `pool`, and one that reaches its ceiling is pinned there. Returns the weight and the cap it
    ///      pinned. A ceiling is never zero, so a pinned component is the only one whose weight equals its ceiling.
    function _capPass(
        uint256[] memory w,
        uint256[] memory caps,
        uint256 first,
        uint256 topCeiling,
        uint256 share,
        uint256 pool
    ) private pure returns (uint256 pinnedWeight, uint256 pinnedCap) {
        (pinnedWeight, pinnedCap) = (0, 0);
        uint256 n = caps.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 ceiling = i == first ? topCeiling : CAPPED_MAX_WEIGHT;
            if (w[i] == ceiling) continue;
            uint256 weight = Math.mulDiv(share, caps[i], pool);
            if (weight < ceiling) {
                w[i] = weight;
            } else {
                w[i] = ceiling;
                pinnedWeight += ceiling;
                pinnedCap += caps[i];
            }
        }
    }

    /// @dev Position of the largest cap, the lower position on a tie, and the ceiling it carries. That ceiling is
    ///      CAPPED_MAX_WEIGHT at a tie with the runner-up and rises linearly with the lead, reaching CAPPED_TOP_WEIGHT
    ///      once the largest cap is twice the second. A flat 30% for whichever leader ranked first made the weights a
    ///      step function of near-tied caps whenever both leaders sat past 20%: one wei of cap swapped ten points
    ///      between them, and a one-basis-point price move put a tenth of an on-methodology index up for auction from
    ///      any address (CR-L01, which VR-01 had closed only where the leaders were under their ceilings). With the
    ///      ceiling following the lead, both leaders carry 20% at a tie, which of them ranks first no longer matters,
    ///      and a move shifts weight in proportion to how far it moves the ratio: a full ten points takes a doubling.
    ///      A basket whose largest cap leads by a factor of two or more, as the Numbers model's does, is unchanged.
    function _top(uint256[] memory caps) private pure returns (uint256 first, uint256 ceiling) {
        first = 0;
        uint256 second = 0;
        uint256 n = caps.length;
        for (uint256 i = 1; i < n; ++i) {
            if (caps[i] > caps[first]) {
                second = caps[first];
                first = i;
            } else if (caps[i] > second) {
                second = caps[i];
            }
        }
        uint256 lead = caps[first] - second;
        // `lead >= second` also covers a runner-up with no cap at all, where the ratio is unbounded.
        ceiling = lead >= second
            ? CAPPED_TOP_WEIGHT
            : CAPPED_MAX_WEIGHT + Math.mulDiv(CAPPED_TOP_WEIGHT - CAPPED_MAX_WEIGHT, lead, second);
    }

    function _targets(uint256[] calldata units, Basket memory basket, uint256 keepMask)
        private
        pure
        returns (uint256[] memory targets, uint256 turnover)
    {
        uint256 n = units.length;
        targets = new uint256[](n);
        (uint256 activeValue, uint256 activeWeight) = _bound(units, targets, basket, keepMask);
        _fill(targets, basket, activeValue, activeWeight);

        // Turnover is what the rebalance actually trades, so it is the smaller of the two sides. Gross outflow alone
        // would certify value that leaves the basket without anything being bought back (DA-08).
        uint256 sold = 0;
        uint256 bought = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (targets[i] < units[i]) {
                sold += Math.mulDiv(units[i] - targets[i], basket.prices[i], basket.scale);
            } else if (targets[i] > units[i]) {
                bought += Math.mulDiv(targets[i] - units[i], basket.prices[i], basket.scale);
            }
        }
        turnover = Math.mulDiv(Math.min(sold, bought), WAD, activeValue);
    }

    /// @dev Fills each rebalanced component's bounds and returns their value and weight at snapshot prices. A kept
    ///      component is pinned to its current units from the start. From here on a zero weight marks a pinned
    ///      component, which no pass moves again.
    function _bound(uint256[] calldata units, uint256[] memory targets, Basket memory basket, uint256 keepMask)
        private
        pure
        returns (uint256 activeValue, uint256 activeWeight)
    {
        (activeValue, activeWeight) = (0, 0);
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 u = units[i];
            if (_kept(keepMask, i)) {
                targets[i] = u;
                basket.weights[i] = 0;
                continue;
            }
            // A weight that rounds to zero still counts as one wei, so that component can take value the clips move.
            if (basket.weights[i] == 0) basket.weights[i] = 1;
            // A value the scale rounds away still counts as one wei, so an active component is never worthless.
            activeValue += Math.max(Math.mulDiv(u, basket.prices[i], basket.scale), 1);
            activeWeight += basket.weights[i];
            basket.lo[i] = (u + 1) / 2;
            basket.hi[i] = Math.max(u, Math.min(2 * u, MAX_TARGET_UNITS));
        }
        if (activeValue == 0) revert DegenerateBasket();
    }

    /// @dev Shares `value` among the free components by weight, pass by pass. Each pass that clips a share pins at least
    ///      one component and takes its value and weight out of what is left to share, so at most one pass per
    ///      component runs. What a pass pins can exceed what is left, even while value products are exact (`scale` of
    ///      1): a ceilings pass also pins a component whose share was rounded up onto its ceiling (VR-03), and takes
    ///      that ceiling's whole value, up to one raw unit more than the share. On a coarse component that overshoot
    ///      can be larger than everything still unplaced, and a WAD scale adds its own rounding. The saturating
    ///      subtraction absorbs both, and is load-bearing rather than defensive: a checked one would panic, and with it
    ///      `startRebalance`. The overshoot only ever leaves the target basket worth more than the holding (CR-I04).
    function _fill(uint256[] memory targets, Basket memory basket, uint256 value, uint256 weight) private pure {
        uint256 n = targets.length;
        for (uint256 pass = 0; pass < n; ++pass) {
            (uint256 pinnedValue, uint256 pinnedWeight) = _share(targets, basket, value, weight);
            if (pinnedWeight == 0) return;
            value = Math.saturatingSub(value, pinnedValue);
            weight -= pinnedWeight;
        }
    }

    /// @dev One pass: gives every free component its share of `value` by weight, clipped to its bounds, and pins the
    ///      side the clips prove. The clips add `below` of value at the floors and remove `above` at the ceilings. With
    ///      `below >= above` the clipped basket is worth at least `value`, so the shares can only come down from here
    ///      and every component at its floor stays there; otherwise they can only go up and every component at its
    ///      ceiling stays there. Returns the value and weight pinned, zero when nothing was clipped. `weight` is the sum
    ///      over the free components, so it is never zero where it divides.
    function _share(uint256[] memory targets, Basket memory basket, uint256 value, uint256 weight)
        private
        pure
        returns (uint256, uint256)
    {
        uint256 below = 0;
        uint256 above = 0;
        for (uint256 i = 0; i < targets.length; ++i) {
            if (basket.weights[i] == 0) continue;
            (uint256 added, uint256 removed) = _clip(targets, basket, i, Math.mulDiv(value, basket.weights[i], weight));
            below += added;
            above += removed;
        }
        if (below == 0 && above == 0) return (0, 0);
        return _pin(targets, basket, below >= above);
    }

    /// @dev Pins every free component that sits at its floor (`floors`) or at its ceiling, and returns their value and
    ///      weight. A pass that clipped anything pins at least the component it clipped.
    function _pin(uint256[] memory targets, Basket memory basket, bool floors)
        private
        pure
        returns (uint256 pinnedValue, uint256 pinnedWeight)
    {
        (pinnedValue, pinnedWeight) = (0, 0);
        uint256 n = targets.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 w = basket.weights[i];
            if (w == 0 || targets[i] != (floors ? basket.lo[i] : basket.hi[i])) continue;
            pinnedValue += Math.mulDiv(targets[i], basket.prices[i], basket.scale);
            pinnedWeight += w;
            basket.weights[i] = 0;
        }
    }

    /// @dev Sets component `i`'s target to the units of its share of value, clipped to its bounds, and returns the value
    ///      the clip added or removed. The share is compared with the bounds as a value and only turned into units once
    ///      it lies between them: next to a price above MAX_EXACT_PRICE, the unclipped units of a component priced near
    ///      zero would not fit in 256 bits. The share rounds UP into units, so the target basket is never worth less
    ///      than the current one: a floor here dropped everything below one whole raw unit, and the settlement paid that
    ///      value to the executor for nothing (DA-01). Units from a share are still at most the ceiling, because the
    ///      share is at most the ceiling's value and the ceiling is a whole number; a WAD scale can round them under the
    ///      floor, hence the maximum.
    function _clip(uint256[] memory targets, Basket memory basket, uint256 i, uint256 share)
        private
        pure
        returns (uint256 added, uint256 removed)
    {
        (added, removed) = (0, 0);
        uint256 p = basket.prices[i];
        uint256 floorValue = Math.mulDiv(basket.lo[i], p, basket.scale);
        uint256 ceilingValue = Math.mulDiv(basket.hi[i], p, basket.scale);
        if (share < floorValue) {
            targets[i] = basket.lo[i];
            added = floorValue - share;
        } else if (share > ceilingValue) {
            targets[i] = basket.hi[i];
            removed = share - ceilingValue;
        } else {
            // Rounded up, so the targets buy back at least the value the shrinking legs release. Rounding down left a
            // residue of up to one raw unit per component that nothing reallocated, because the component it came from
            // was pinned at its floor: the index sent it out as `amountsOut` with no matching `amountsIn`, and
            // `IndexToken._checkBacking` verifies backing, not value (VR-03). Rounding up puts the residue on the
            // executor's side of the trade, where every other rounding in the system already sits. The share is at most
            // the ceiling's value, so the ceiling bounds the result; the minimum only makes that explicit.
            uint256 unclipped = Math.mulDiv(share, basket.scale, p, Math.Rounding.Ceil);
            targets[i] = Math.min(basket.hi[i], Math.max(unclipped, basket.lo[i]));
        }
    }

    function _kept(uint256 keepMask, uint256 i) private pure returns (bool) {
        return (keepMask >> i) & 1 == 1;
    }
}
