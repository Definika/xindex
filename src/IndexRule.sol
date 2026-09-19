// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexRule} from "./interfaces/IIndexRule.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {Methodology} from "./libraries/Methodology.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @title IndexRule
/// @notice Reads on-chain supplies and Uniswap V3 time-weighted prices and applies an index's weighting rule. See
///         {IIndexRule}.
/// @dev Deployed by the factory constructor, so `FACTORY` is the factory whose token configs it reads. It keeps no
///      state, holds no funds, and every function is a view.
///
///      A WAD price is WETH wei per 1e18 raw units of a token, from the token's WETH pool averaged over TWAP_WINDOW with
///      the mean tick rounded toward negative infinity, as Uniswap's OracleLibrary does. Units, supplies and prices are
///      all raw, so token decimals cancel out.
///
///      A WAD price reaches about 3.4e56 at MAX_TICK, so the rule's products have to be kept inside 256 bits. A market
///      cap is supply times price over WAD, floored at one wei; weights use only ratios of caps, so that scale cancels
///      out. A holding's value is units times price, exact while every price is at most MAX_EXACT_PRICE and divided by
///      WAD above it (`Basket.scale`). Ordinary baskets are therefore unchanged to the wei, and a mean tick manipulated
///      toward MAX_TICK yields a snapshot instead of an arithmetic panic.
///
///      Rebalance targets keep the value of the rebalanced components at snapshot prices. Each pass shares the value
///      not yet pinned among the components still free, `value * weight / price` each, and clips every share to
///      [units / 2, units * 2]. When the clips add more value than they remove, the shares have to come down, so a
///      component clipped up to its floor is certain to end there and is pinned; otherwise the components clipped down
///      to their ceiling are. The rest are shared out again, until a pass clips nothing. A pinned component never
///      moves again, so a component the rule wants to shrink further than its floor is never handed value back. A
///      weight that rounds to zero counts as one wei here, so no clipped value is ever left unplaced.
contract IndexRule is IIndexRule {
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint32 public constant TWAP_SUB_WINDOWS = 3;
    /// @inheritdoc IIndexRule
    /// @dev 1.0001^2000 is about 1.22. One 12-second block at an extreme tick moves the mean tick of its 10-minute part
    ///      by up to 887,272 * 12 / 600, about 17,700 ticks.
    uint256 public constant MAX_TICK_DEVIATION = 2_000;
    /// @inheritdoc IIndexRule
    /// @dev A pool writes at most one observation per block, so 200 slots cover TWAP_WINDOW while blocks are at least
    ///      1800 / 199 = 9.05 seconds apart (12-second slots give 2,388 seconds). If slots ever get shorter, anyone can
    ///      grow a pool's ring with `increaseObservationCardinalityNext`.
    uint16 public constant MIN_OBSERVATION_CARDINALITY = 200;
    /// @inheritdoc IIndexRule
    /// @dev Cardinality is the ring's capacity, not the history it holds (DA-19). When a pool's newest observation
    ///      predates the window, `observe` extrapolates every point at the pool's current tick and current liquidity:
    ///      the three sub-window means then agree exactly, so `MAX_TICK_DEVIATION` reads zero, and the harmonic-mean
    ///      liquidity is whatever was minted a moment ago. Both snapshot defences degenerate together on a quiet pool
    ///      (DA-02).
    ///
    ///      Two sub-windows is the largest bound that keeps the deviation check load-bearing, which is what makes it
    ///      the right one. Extrapolation covers the most recent `age` seconds, so an age of at most two sub-windows
    ///      leaves the oldest part, [TWAP_WINDOW, 2 * TWAP_WINDOW / 3] ago, entirely genuine history; a price held
    ///      during the extrapolated stretch therefore shows up as a spread between that part and the newest one, and
    ///      `MAX_TICK_DEVIATION` catches it. Only as the age approaches the whole window do all three parts become
    ///      equally extrapolated and the spread collapse to zero.
    ///
    ///      One sub-window was measured against mainnet on 2026-09-19 and was too strict to ship: over the most recent
    ///      250 observations of each default pool, LINK stood more than ten minutes stale 43% of the time and AAVE 25%,
    ///      against 24% and 9% at twenty minutes. Trading frequency turns out not to track depth at all, so the
    ///      stricter bound cost the deep pools as much as the thin ones.
    uint32 public constant MAX_OBSERVATION_AGE = 2 * TWAP_WINDOW / TWAP_SUB_WINDOWS;
    uint256 public constant MAX_EXCLUDED = 8;
    /// @inheritdoc IIndexRule
    /// @dev An auction can deliver 1.5 times a growing component's extra units, so a raised target stays at most 2/3 of
    ///      uint96 and 1.5 times it is exactly type(uint96).max.
    uint256 public constant MAX_TARGET_UNITS = uint256(type(uint96).max) * 2 / 3;
    uint24 public constant USD_POOL_FEE = 500;

    address public immutable FACTORY;
    address public immutable WETH;
    address public immutable UNISWAP_V3_FACTORY;
    address public immutable USDC;
    address public immutable USD_POOL;

    uint256 private constant WAD = 1e18;
    /// @dev Highest WAD price whose value products stay inside 256 bits: MAX_COMPONENTS holdings of up to 2^96 - 1
    ///      units come to about 1.6e76, below type(uint256).max. One raw unit of a token priced this high is worth 1e28
    ///      ETH, which no market reaches; only a mean tick manipulated toward MAX_TICK gets there.
    uint256 private constant MAX_EXACT_PRICE = 1e46;
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

    constructor(address weth, address uniswapV3Factory, address usdc) {
        if (weth == address(0) || uniswapV3Factory == address(0) || usdc == address(0)) revert ZeroAddress();
        FACTORY = msg.sender;
        WETH = weth;
        UNISWAP_V3_FACTORY = uniswapV3Factory;
        USDC = usdc;
        address usdPool = IUniswapV3Factory(uniswapV3Factory).getPool(usdc, weth, USD_POOL_FEE);
        _checkPool(usdc, usdPool);
        USD_POOL = usdPool;
    }

    // ---------------------------------------------------------------------
    // Configuration and market data
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexRule
    function checkConfig(address token, IIndexFactory.TokenConfig calldata config) external view {
        _checkExclusions(token, config);
        if (token == WETH) {
            if (config.pool != address(0)) revert InvalidPool(token, config.pool);
            if (config.minLiquidity != 0) revert InvalidMinLiquidity(token);
            if (config.referenceSupply == 0) revert InvalidSupplyConfig(token);
            return;
        }
        if (config.minLiquidity == 0) revert InvalidMinLiquidity(token);
        _checkPool(token, config.pool);
        (,, uint256 harmonicLiquidity) = _observe(config.pool);
        if (harmonicLiquidity < config.minLiquidity) {
            revert ThinPriceHistory(config.pool, harmonicLiquidity, config.minLiquidity);
        }
        if (_supply(token, config.referenceSupply, config.excluded) == 0) revert ZeroSupply(token);
    }

    /// @inheritdoc IIndexRule
    function price(address token) external view returns (uint256) {
        return _price(token, token == USDC ? USD_POOL : IIndexFactory(FACTORY).tokenConfig(token).pool);
    }

    /// @inheritdoc IIndexRule
    function supply(address token) external view returns (uint256) {
        IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(token);
        return _supply(token, config.referenceSupply, config.excluded);
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
    function navPerToken(address index) external view returns (uint256 wethValue, uint256 usdcValue) {
        if (!IIndexFactory(FACTORY).isIndex(index)) revert NotIndex(index);
        (address[] memory tokens, uint256[] memory units) = IIndexToken(index).components();
        wethValue = 0;
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 p = _price(tokens[i], IIndexFactory(FACTORY).tokenConfig(tokens[i]).pool);
            wethValue += Math.mulDiv(units[i], p, WAD);
        }
        usdcValue = Math.mulDiv(wethValue, WAD, _price(USDC, USD_POOL));
    }

    /// @inheritdoc IIndexRule
    function initialUnits(address[] calldata tokens, uint8 methodology, uint256 startPriceUsdc)
        external
        view
        returns (uint256[] memory units)
    {
        (uint256[] memory prices,, uint256[] memory caps) = _market(tokens);
        uint256[] memory w = _weights(caps, methodology);
        uint256 value = startPriceUsdc * _price(USDC, USD_POOL);
        uint256 n = tokens.length;
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            // A start price so low that a component's units round away entirely cannot describe the basket at all,
            // and the index that came out of it would be coarse enough for a rebalance to move less than one raw unit
            // of a component (DA-09). Floor it at one unit and the caller never learns; refuse it instead.
            units[i] = Math.mulDiv(value, w[i], prices[i] * WAD);
            if (units[i] == 0) revert StartPriceTooLow(tokens[i], startPriceUsdc);
        }
    }

    // ---------------------------------------------------------------------
    // Market data internals
    // ---------------------------------------------------------------------

    /// @dev At most MAX_EXCLUDED distinct exclusions, and none next to a reference supply.
    function _checkExclusions(address token, IIndexFactory.TokenConfig calldata config) private pure {
        uint256 n = config.excluded.length;
        if (n > MAX_EXCLUDED || (config.referenceSupply != 0 && n != 0)) revert InvalidSupplyConfig(token);
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (config.excluded[i] == config.excluded[j]) revert InvalidSupplyConfig(token);
            }
        }
    }

    /// @dev A pool must be the Uniswap V3 factory's pool for the token and WETH at its own fee tier, keep enough
    ///      observations that a TWAP_WINDOW average does not run out of history, and serve one now.
    function _checkPool(address token, address pool) private view {
        if (pool.code.length == 0) revert InvalidPool(token, pool);
        if (IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(token, WETH, IUniswapV3Pool(pool).fee()) != pool) {
            revert InvalidPool(token, pool);
        }
        // Only the observation cardinality matters here; the pool has no narrower getter for it.
        // forge-lint: disable-next-line(unused-return)
        (,,, uint16 cardinality,,,) = IUniswapV3Pool(pool).slot0();
        if (cardinality < MIN_OBSERVATION_CARDINALITY) revert PoolHistoryTooShort(pool, cardinality);
        (int24 tick,,) = _observe(pool);
        if (_quoteAtTick(tick, token < WETH) == 0) revert ZeroPrice(token);
    }

    /// @dev The window's mean tick quoted as a WAD price, for display, ranking kept components and starting units.
    function _price(address token, address pool) private view returns (uint256 p) {
        if (token == WETH) return WAD;
        (int24 tick,,) = _observe(pool);
        p = _quoteAtTick(tick, token < WETH);
        if (p == 0) revert ZeroPrice(token);
    }

    /// @dev The price of a component a rebalance moves. It is the same mean-tick price, accepted only from a window
    ///      that carries real history (DA-02), whose sub-window liquidity reached the token's minimum and whose
    ///      sub-window mean ticks agree, so the price was neither read off a pool that has not traded, nor pushed
    ///      through thin or empty ranges, nor dominated by a few outlier blocks.
    function _snapshotPrice(address token, IIndexFactory.TokenConfig memory config) private view returns (uint256 p) {
        if (token == WETH) return WAD;
        uint256 age = _newestObservationAge(config.pool);
        if (age > MAX_OBSERVATION_AGE) revert StalePriceHistory(config.pool, age);
        (int24 tick, uint256 spread, uint256 harmonicLiquidity) = _observe(config.pool);
        if (harmonicLiquidity < config.minLiquidity) {
            revert ThinPriceHistory(config.pool, harmonicLiquidity, config.minLiquidity);
        }
        if (spread > MAX_TICK_DEVIATION) revert PriceHistoryDeviates(config.pool, spread);
        p = _quoteAtTick(tick, token < WETH);
        if (p == 0) revert ZeroPrice(token);
    }

    /// @dev One read of `pool` over TWAP_WINDOW split into TWAP_SUB_WINDOWS equal parts: the window's mean tick, the
    ///      spread between the highest and lowest part's mean tick, and the window's harmonic-mean liquidity. Mean
    ///      ticks round toward negative infinity and the liquidity is computed as Uniswap's OracleLibrary.consult does.
    function _observe(address pool) private view returns (int24 tick, uint256 spread, uint256 harmonicLiquidity) {
        uint256 parts = TWAP_SUB_WINDOWS;
        uint32 part = TWAP_WINDOW / TWAP_SUB_WINDOWS;
        uint32[] memory secondsAgos = new uint32[](parts + 1);
        uint32 ago = TWAP_WINDOW;
        for (uint256 i = 0; i < parts; ++i) {
            secondsAgos[i] = ago;
            ago -= part;
        }
        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity) =
            IUniswapV3Pool(pool).observe(secondsAgos);

        tick = _meanTick(tickCumulatives[parts] - tickCumulatives[0], TWAP_WINDOW);
        int24 low = type(int24).max;
        int24 high = type(int24).min;
        for (uint256 i = 0; i < parts; ++i) {
            int24 partTick = _meanTick(tickCumulatives[i + 1] - tickCumulatives[i], part);
            if (partTick < low) low = partTick;
            if (partTick > high) high = partTick;
        }
        // Every part updates both bounds, so high >= low and the difference is never negative.
        // forge-lint: disable-next-line(unsafe-typecast)
        spread = uint256(int256(high) - int256(low));

        uint160 liquidityDelta;
        // Uniswap V3 accumulators wrap on overflow, so the difference is taken modulo 2^160 as in OracleLibrary.
        unchecked {
            liquidityDelta = secondsPerLiquidity[parts] - secondsPerLiquidity[0];
        }
        // Deliberately the harmonic mean of the whole window, which its smallest term dominates: twelve seconds at
        // liquidity one drag it under any sane minimum (XA-01). That sensitivity is also what lets one shallow block
        // block every snapshot of the component for the next half hour (DA-04). Measuring each part separately and
        // taking the middle one would shake off the griefer, but it would equally shake off a real push through an
        // empty range confined to one part, which is the attack XA-01 exists to stop; the liveness cost is the
        // cheaper of the two, and it is recoverable, since anyone may retry and the griefer must pay again every
        // thirty minutes for as long as they want the index frozen.
        harmonicLiquidity = uint256(TWAP_WINDOW) * type(uint160).max / (uint256(liquidityDelta) << 32);
    }

    /// @dev Age of the pool's newest observation. Uniswap stores observation timestamps truncated to 32 bits and
    ///      compares them with wrap-around, so the subtraction is unchecked exactly as the pool's own oracle does.
    function _newestObservationAge(address pool) private view returns (uint256 age) {
        // Only the observation index matters here; the pool has no narrower getter for it.
        // forge-lint: disable-next-line(unused-return)
        (,, uint16 observationIndex,,,,) = IUniswapV3Pool(pool).slot0();
        // Only the timestamp matters here.
        // forge-lint: disable-next-line(unused-return)
        (uint32 blockTimestamp,,,) = IUniswapV3Pool(pool).observations(observationIndex);
        unchecked {
            // Truncating to 32 bits is the point: Uniswap stores observation timestamps that way and compares them
            // with wrap-around, so the difference is right whichever side of a 2^32-second boundary the two sit on.
            // forge-lint: disable-next-line(unsafe-typecast)
            age = uint32(block.timestamp) - blockTimestamp;
        }
    }

    /// @dev Mean tick of a tick-accumulator change over `period` seconds, rounded toward negative infinity.
    function _meanTick(int56 delta, uint32 period) private pure returns (int24 tick) {
        int56 signedPeriod = int56(uint56(period));
        // The mean of ticks that Uniswap keeps within [MIN_TICK, MAX_TICK] fits in int24; TickMath rejects anything else.
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(delta / signedPeriod);
        if (delta < 0 && delta % signedPeriod != 0) --tick;
    }

    /// @dev WETH wei per 1e18 raw units of the token, as Uniswap's OracleLibrary.getQuoteAtTick computes it. The pool
    ///      price is token1 per token0, so it is inverted when the token is token1.
    function _quoteAtTick(int24 tick, bool tokenIsToken0) private pure returns (uint256) {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = sqrtPriceX96 * sqrtPriceX96;
            return tokenIsToken0 ? Math.mulDiv(ratioX192, WAD, 1 << 192) : Math.mulDiv(1 << 192, WAD, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return tokenIsToken0 ? Math.mulDiv(ratioX128, WAD, 1 << 128) : Math.mulDiv(1 << 128, WAD, ratioX128);
    }

    /// @dev The reference supply, or the total supply minus excluded balances, floored at zero. Callers reject zero.
    function _supply(address token, uint256 referenceSupply, address[] memory excluded)
        private
        view
        returns (uint256 circulating)
    {
        if (referenceSupply != 0) return referenceSupply;
        circulating = IERC20(token).totalSupply();
        uint256 n = excluded.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 held = IERC20(token).balanceOf(excluded[i]);
            circulating = circulating > held ? circulating - held : 0;
        }
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

    /// @dev Market cap in WAD-scaled WETH: supply times price over WAD, floored at one wei so a component with a
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
            prices[i] = _price(tokens[i], config.pool);
            supplies[i] = _supply(tokens[i], config.referenceSupply, config.excluded);
            if (supplies[i] == 0) revert ZeroSupply(tokens[i]);
            caps[i] = _cap(supplies[i], prices[i]);
        }
    }

    /// @dev Prices and caps for a rebalance snapshot. Every component the snapshot reads at all needs a checked price.
    ///      A kept component never trades, and the uncapped methodology does not read it (its weight is renormalised
    ///      away and a zero price and cap leave the targets unchanged). The capped methodology does read it: its cap
    ///      sits in the denominator of every other component's weight, so a plain TWAP price there would let a
    ///      manipulated pool reshape the targets and the turnover of the components that do trade (DA-06). It is
    ///      therefore taken from the snapshot price as well, which narrows XA-05: under the capped methodology a keep
    ///      mask routes around a component that cannot be transferred, not around one whose pool cannot be read.
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
            prices[i] = _snapshotPrice(tokens[i], config);
            uint256 circulating = _supply(tokens[i], config.referenceSupply, config.excluded);
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
