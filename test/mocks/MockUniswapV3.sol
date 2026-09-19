// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap V3 pool stand-in for the rebalance rule. Its tick and liquidity are constant over time, so any
///         time-weighted average returns exactly that tick and that liquidity. Tests can also set the tick accumulators
///         of the oldest and newest point directly, set every returned accumulator, cap the observation cardinality, or
///         make `observe` revert as a pool with too little history does. It does not model a ring that was just grown:
///         a real pool then keeps its old history until the new slots fill, which tests reproduce with
///         `setHistoryTooShort`.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    uint160 public sqrtPriceX96;
    int24 public tick;
    /// @notice In-range liquidity behind the seconds-per-liquidity accumulator; zero counts as one, as in Uniswap.
    uint128 public liquidity = 1e18;
    uint16 public observationCardinality = 1_000;
    /// @notice Largest cardinality requested through `increaseObservationCardinalityNext`.
    uint16 public observationCardinalityNext;
    bool public historyTooShort;
    bool public rawCumulatives;
    int56 public olderCumulative;
    int56 public newerCumulative;
    bool public rawObservations;
    /// @notice Age of the newest stored observation, which the rule reads to tell a traded window from an
    ///         extrapolated one. Zero means the pool traded in this block, as a busy pool does.
    uint32 public newestObservationAge;
    mapping(uint32 secondsAgo => bool) private _observed;
    mapping(uint32 secondsAgo => int56) private _tickCumulativeAt;
    mapping(uint32 secondsAgo => uint160) private _secondsPerLiquidityAt;

    constructor(address tokenA, address tokenB, uint24 fee_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
    }

    /// @notice Pool tick: log base 1.0001 of token1 raw units per token0 raw unit.
    function setTick(int24 tick_) external {
        tick = tick_;
        rawCumulatives = false;
        rawObservations = false;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    /// @notice Makes `observe` return these tick accumulators for the oldest and newest point, and values on the
    ///         straight line between them for the points in between.
    function setCumulatives(int56 older, int56 newer) external {
        olderCumulative = older;
        newerCumulative = newer;
        rawCumulatives = true;
        rawObservations = false;
    }

    /// @notice Makes `observe` return exactly these accumulators for `secondsAgo`. From then on `observe` serves only
    ///         points set this way, until `setTick` or `setCumulatives`.
    function setObservation(uint32 secondsAgo, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128)
        external
    {
        _observed[secondsAgo] = true;
        _tickCumulativeAt[secondsAgo] = tickCumulative;
        _secondsPerLiquidityAt[secondsAgo] = secondsPerLiquidityCumulativeX128;
        rawObservations = true;
        rawCumulatives = false;
    }

    function setObservationCardinality(uint16 cardinality) external {
        observationCardinality = cardinality;
    }

    function setHistoryTooShort(bool tooShort) external {
        historyTooShort = tooShort;
    }

    /// @notice Ages the newest stored observation, as a pool that has not traded for a while has.
    function setNewestObservationAge(uint32 age) external {
        newestObservationAge = age;
    }

    /// @notice The newest observation, the only slot the rule reads. `slot0` reports its index as 0. The timestamp
    ///         wraps at 2^32 as the real pool's does, so an age beyond the current block time is still well formed.
    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        unchecked {
            return (uint32(block.timestamp) - newestObservationAge, int56(tick), 0, true);
        }
    }

    /// @notice Moves the current price, as a swap through the pool would; the tick stays whatever `setTick` set.
    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    /// @notice Records the starting price once, like the real pool; the tick stays whatever `setTick` set.
    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "AI");
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next > observationCardinalityNext) observationCardinalityNext = next;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        uint16 next =
            observationCardinalityNext > observationCardinality ? observationCardinalityNext : observationCardinality;
        return (sqrtPriceX96, tick, 0, observationCardinality, next, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!historyTooShort, "OLD");
        uint256 n = secondsAgos.length;
        tickCumulatives = new int56[](n);
        secondsPerLiquidityCumulativeX128s = new uint160[](n);
        int56 oldest = int56(uint56(secondsAgos[0]));
        for (uint256 i = 0; i < n; ++i) {
            if (rawObservations) {
                require(_observed[secondsAgos[i]], "NO OBSERVATION");
                tickCumulatives[i] = _tickCumulativeAt[secondsAgos[i]];
                secondsPerLiquidityCumulativeX128s[i] = _secondsPerLiquidityAt[secondsAgos[i]];
                continue;
            }
            int56 ago = int56(uint56(secondsAgos[i]));
            uint256 elapsed = 1_000_000_000 - uint256(secondsAgos[i]);
            if (rawCumulatives) {
                tickCumulatives[i] = newerCumulative - (newerCumulative - olderCumulative) * ago / oldest;
            } else {
                tickCumulatives[i] = int56(tick) * (1_000_000_000 - ago);
            }
            secondsPerLiquidityCumulativeX128s[i] = uint160((elapsed << 128) / (liquidity == 0 ? 1 : liquidity));
        }
    }
}

/// @notice Registry of mock pools that answers `getPool` in either token order, like the real factory.
contract MockUniswapV3Factory {
    mapping(address tokenA => mapping(address tokenB => mapping(uint24 fee => address pool))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        pool = address(new MockUniswapV3Pool(tokenA, tokenB, fee));
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}
