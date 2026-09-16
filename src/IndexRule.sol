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
///      the mean tick rounded toward negative infinity, as Uniswap's OracleLibrary does. A market cap is supply times
///      WAD price. Units, supplies and prices are all raw, so token decimals cancel out.
///
///      Rebalance targets keep the value of the rebalanced components at snapshot prices. Each target starts at
///      `value * weight / price` and is clipped to [units / 2, units * 2]. Whatever value the clip removes or adds is
///      shared among the components still inside their bounds, pass by pass, until a pass pins no new component.
///      A weight that rounds to zero counts as one wei here, so no clipped value is ever left unplaced.
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
    uint256 private constant CAPPED_TOP_WEIGHT = 0.3e18;
    uint256 private constant CAPPED_SECOND_MAX_WEIGHT = 0.2e18;
    uint256 private constant CAPPED_REMAINDER = WAD - CAPPED_TOP_WEIGHT;

    /// @dev Snapshot prices, weights and per-component bounds of one rebalance, kept in one struct for the stack.
    struct Basket {
        uint256[] prices;
        uint256[] weights;
        uint256[] lo;
        uint256[] hi;
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
        Basket memory basket =
            Basket({prices: prices, weights: _weights(caps, methodology), lo: new uint256[](n), hi: new uint256[](n)});
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
            units[i] = Math.max(Math.mulDiv(value, w[i], prices[i] * WAD), 1);
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
    ///      whose harmonic-mean liquidity reached the token's minimum and whose sub-window mean ticks agree, so the
    ///      price was neither pushed through thin or empty ranges nor dominated by a few outlier blocks.
    function _snapshotPrice(address token, IIndexFactory.TokenConfig memory config) private view returns (uint256 p) {
        if (token == WETH) return WAD;
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
        harmonicLiquidity = uint256(TWAP_WINDOW) * type(uint160).max / (uint256(liquidityDelta) << 32);
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
            caps[i] = supplies[i] * prices[i];
        }
    }

    /// @dev Prices and caps for a rebalance snapshot. Every component that can move needs a snapshot price. A kept
    ///      component never trades: the uncapped methodology does not read it at all (its weight is renormalised away
    ///      and a zero price and cap leave the targets unchanged), and the capped methodology only ranks it, from the
    ///      plain TWAP price.
    function _snapshotMarket(address[] calldata tokens, uint8 methodology, uint256 keepMask)
        private
        view
        returns (uint256[] memory prices, uint256[] memory caps)
    {
        uint256 n = tokens.length;
        prices = new uint256[](n);
        caps = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            bool kept = _kept(keepMask, i);
            if (kept && methodology == Methodology.UNCAPPED) continue;
            IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(tokens[i]);
            prices[i] = kept ? _price(tokens[i], config.pool) : _snapshotPrice(tokens[i], config);
            uint256 circulating = _supply(tokens[i], config.referenceSupply, config.excluded);
            if (circulating == 0) revert ZeroSupply(tokens[i]);
            caps[i] = circulating * prices[i];
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

    /// @dev Closed form of the model: rank 1 gets 30%; rank 2 gets 70% of its share of ranks 2 and below, at most 20%;
    ///      ranks 3 and below share the rest of the 70% in proportion to market cap.
    function _cappedWeights(uint256[] memory caps) private pure returns (uint256[] memory w) {
        uint256 n = caps.length;
        if (n < Methodology.MIN_CAPPED_COMPONENTS) revert TooFewComponentsForCapped(n);
        (uint256 first, uint256 second) = _topTwo(caps);
        uint256 rest = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (i != first && i != second) rest += caps[i];
        }
        if (rest == 0) revert DegenerateBasket();
        uint256 secondWeight =
            Math.min(Math.mulDiv(CAPPED_REMAINDER, caps[second], caps[second] + rest), CAPPED_SECOND_MAX_WEIGHT);
        uint256 share = CAPPED_REMAINDER - secondWeight;
        w = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (i == first) {
                w[i] = CAPPED_TOP_WEIGHT;
            } else if (i == second) {
                w[i] = secondWeight;
            } else {
                w[i] = Math.mulDiv(share, caps[i], rest);
            }
        }
    }

    /// @dev Positions of the largest and second-largest caps. On a tie the lower position ranks first.
    function _topTwo(uint256[] memory caps) private pure returns (uint256 first, uint256 second) {
        (first, second) = (0, 1);
        if (caps[1] > caps[0]) (first, second) = (1, 0);
        uint256 n = caps.length;
        for (uint256 i = 2; i < n; ++i) {
            if (caps[i] > caps[first]) {
                second = first;
                first = i;
            } else if (caps[i] > caps[second]) {
                second = i;
            }
        }
    }

    function _targets(uint256[] calldata units, Basket memory basket, uint256 keepMask)
        private
        pure
        returns (uint256[] memory targets, uint256 turnover)
    {
        (uint256 activeValue, uint256 activeWeight, uint256 totalValue) = _bound(units, basket, keepMask);
        uint256 n = units.length;
        targets = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            targets[i] = _kept(keepMask, i)
                ? units[i]
                : _clamp(
                    Math.mulDiv(activeValue, basket.weights[i], activeWeight * basket.prices[i]),
                    basket.lo[i],
                    basket.hi[i]
                );
        }
        _redistribute(targets, basket, totalValue);

        uint256 sold = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (targets[i] < units[i]) sold += (units[i] - targets[i]) * basket.prices[i];
        }
        turnover = Math.mulDiv(sold, WAD, activeValue);
    }

    /// @dev Fills each component's bounds and returns the value and weight of the components being rebalanced and the
    ///      value of the whole basket, all at snapshot prices. Kept components are pinned to their current units.
    function _bound(uint256[] calldata units, Basket memory basket, uint256 keepMask)
        private
        pure
        returns (uint256 activeValue, uint256 activeWeight, uint256 totalValue)
    {
        (activeValue, activeWeight, totalValue) = (0, 0, 0);
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 u = units[i];
            uint256 value = u * basket.prices[i];
            totalValue += value;
            // A weight that rounds to zero still counts as one wei, so that component can take value the clips move.
            if (basket.weights[i] == 0) basket.weights[i] = 1;
            if (_kept(keepMask, i)) {
                basket.lo[i] = u;
                basket.hi[i] = u;
            } else {
                activeValue += value;
                activeWeight += basket.weights[i];
                basket.lo[i] = (u + 1) / 2;
                basket.hi[i] = Math.max(u, Math.min(2 * u, MAX_TARGET_UNITS));
            }
        }
        if (activeValue == 0) revert DegenerateBasket();
    }

    /// @dev Restores the basket's value after clipping. Each pass that pins a component at a bound leaves at least one
    ///      fewer component to move, so at most one pass per component runs.
    function _redistribute(uint256[] memory targets, Basket memory basket, uint256 totalValue) private pure {
        uint256 n = targets.length;
        for (uint256 pass = 0; pass < n; ++pass) {
            uint256 value = 0;
            for (uint256 i = 0; i < n; ++i) {
                value += targets[i] * basket.prices[i];
            }
            bool raise = value < totalValue;
            uint256 gap = raise ? totalValue - value : value - totalValue;
            if (gap == 0 || !_shift(targets, basket, raise, gap)) return;
        }
    }

    /// @dev Moves `gap` of value onto (or off) every component that can still move in that direction, in proportion to
    ///      weight, and clips at the bounds. Returns whether any component reached a bound.
    function _shift(uint256[] memory targets, Basket memory basket, bool raise, uint256 gap)
        private
        pure
        returns (bool pinned)
    {
        pinned = false;
        uint256 n = targets.length;
        uint256 eligibleWeight = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (raise ? targets[i] < basket.hi[i] : targets[i] > basket.lo[i]) eligibleWeight += basket.weights[i];
        }
        // Never zero while a gap remains: every weight is at least one wei, and the bounds bracket the basket's value, so
        // some component can always still move in the needed direction.
        for (uint256 i = 0; i < n; ++i) {
            uint256 t = targets[i];
            if (raise ? t >= basket.hi[i] : t <= basket.lo[i]) continue;
            uint256 step = Math.mulDiv(gap, basket.weights[i], eligibleWeight * basket.prices[i]);
            if (raise && t + step >= basket.hi[i]) {
                targets[i] = basket.hi[i];
                pinned = true;
            } else if (!raise && t <= basket.lo[i] + step) {
                targets[i] = basket.lo[i];
                pinned = true;
            } else {
                targets[i] = raise ? t + step : t - step;
            }
        }
    }

    function _kept(uint256 keepMask, uint256 i) private pure returns (bool) {
        return (keepMask >> i) & 1 == 1;
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) private pure returns (uint256) {
        return x < lo ? lo : (x > hi ? hi : x);
    }
}
