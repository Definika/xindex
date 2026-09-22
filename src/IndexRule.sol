// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexRule} from "./interfaces/IIndexRule.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {Methodology} from "./libraries/Methodology.sol";

/// @title IndexRule
/// @notice Reads on-chain supplies and Chainlink USD prices and applies an index's weighting rule. See {IIndexRule}.
/// @dev Deployed by the factory constructor, so `FACTORY` is the factory whose token configs it reads. It keeps no
///      state, holds no funds, and every function is a view. It reads no Uniswap pool: depth, observation rings and
///      sub-window agreement are no longer inputs to anything.
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
///      weight that rounds to zero counts as one wei here, so no clipped value is ever left unplaced.
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
    uint256 private constant CAPPED_REMAINDER = WAD - CAPPED_TOP_WEIGHT;

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
        if (_supply(token, config.referenceSupply) == 0) revert ZeroSupply(token);
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
        IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(token);
        return _supply(token, config.referenceSupply);
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

    /// @dev The reference supply, or the token's own total supply. Callers reject zero. A config once carried a list
    ///      of excluded holders whose balances this subtracted with a live `balanceOf` inside the snapshot, which made
    ///      a market cap manipulable within one transaction whenever an exclusion was an address a third party could
    ///      fund and drain; the list is gone, and a supply that has to leave holdings out uses a reference figure
    ///      behind the listing timelock instead (DA-10).
    function _supply(address token, uint256 referenceSupply) private view returns (uint256) {
        return referenceSupply != 0 ? referenceSupply : IERC20(token).totalSupply();
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
    function _cap(uint256 circulating, uint256 p) private pure returns (uint256) {
        return Math.max(Math.mulDiv(circulating, p, WAD), 1);
    }

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
            supplies[i] = _supply(tokens[i], config.referenceSupply);
            if (supplies[i] == 0) revert ZeroSupply(tokens[i]);
            caps[i] = _cap(supplies[i], prices[i]);
        }
    }

    /// @dev Prices and caps for a rebalance snapshot. A kept component never trades, and the uncapped methodology does
    ///      not read it (its weight is renormalised away and a zero price and cap leave the targets unchanged). The
    ///      capped methodology does read it: its cap sits in the denominator of every other component's weight, so an
    ///      unchecked price there would let a dead or broken feed reshape the targets and the turnover of the
    ///      components that do trade (DA-06). It is therefore priced like every other component, which narrows XA-05:
    ///      under the capped methodology a keep mask routes around a component that cannot be transferred, not around
    ///      one whose feed cannot be read.
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
            uint256 circulating = _supply(tokens[i], config.referenceSupply);
            if (circulating == 0) revert ZeroSupply(tokens[i]);
            caps[i] = _cap(circulating, prices[i]);
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

    /// @dev Rank 1 takes CAPPED_TOP_WEIGHT; every other component shares CAPPED_REMAINDER in proportion to market cap,
    ///      capped at CAPPED_MAX_WEIGHT. Each pass pins at least one component at the cap and shares what is left among
    ///      the rest, so at most one pass per component runs. MIN_CAPPED_COMPONENTS components always leave room: the
    ///      remainder is below the cap times the number of ranks below the first, so a pass that pins nothing always
    ///      comes. A basket whose unpinned ranks all have a zero cap has nowhere left to place the remainder and is
    ///      degenerate.
    function _cappedWeights(uint256[] memory caps) private pure returns (uint256[] memory w) {
        uint256 n = caps.length;
        if (n < Methodology.MIN_CAPPED_COMPONENTS) revert TooFewComponentsForCapped(n);
        uint256 first = _top(caps);
        uint256 pool = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (i != first) pool += caps[i];
        }
        if (pool == 0) revert DegenerateBasket();

        w = new uint256[](n);
        w[first] = CAPPED_TOP_WEIGHT;
        uint256 share = CAPPED_REMAINDER;
        for (uint256 pass = 0; pass < n; ++pass) {
            uint256 pinnedWeight = 0;
            uint256 pinnedCap = 0;
            for (uint256 i = 0; i < n; ++i) {
                if (i == first || w[i] == CAPPED_MAX_WEIGHT) continue;
                uint256 weight = Math.mulDiv(share, caps[i], pool);
                if (weight < CAPPED_MAX_WEIGHT) {
                    w[i] = weight;
                } else {
                    w[i] = CAPPED_MAX_WEIGHT;
                    pinnedWeight += CAPPED_MAX_WEIGHT;
                    pinnedCap += caps[i];
                }
            }
            if (pinnedWeight == 0) return w;
            share -= pinnedWeight;
            pool -= pinnedCap;
            if (pool == 0) revert DegenerateBasket();
        }
    }

    /// @dev Position of the largest cap. On a tie the lower position ranks first.
    function _top(uint256[] memory caps) private pure returns (uint256 first) {
        first = 0;
        uint256 n = caps.length;
        for (uint256 i = 1; i < n; ++i) {
            if (caps[i] > caps[first]) first = i;
        }
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
    ///      component runs. While value products are exact (`scale` of 1), what is left always covers the floors of the
    ///      components still free; only the rounding of a WAD scale can leave it a few wei short, which the saturating
    ///      subtraction absorbs.
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
            targets[i] = Math.max(Math.mulDiv(share, basket.scale, p, Math.Rounding.Ceil), basket.lo[i]);
        }
    }

    function _kept(uint256 keepMask, uint256 i) private pure returns (bool) {
        return (keepMask >> i) & 1 == 1;
    }
}
