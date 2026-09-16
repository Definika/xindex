// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap V3 pool stand-in for the rebalance rule. Its tick is constant over time, so any time-weighted
///         average returns exactly that tick; tests can also set the two accumulators directly, cap the observation
///         cardinality, or make `observe` revert as a pool with too little history does.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    int24 public tick;
    uint16 public observationCardinality = 1_000;
    bool public historyTooShort;
    bool public rawCumulatives;
    int56 public olderCumulative;
    int56 public newerCumulative;

    constructor(address tokenA, address tokenB, uint24 fee_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
    }

    /// @notice Pool tick: log base 1.0001 of token1 raw units per token0 raw unit.
    function setTick(int24 tick_) external {
        tick = tick_;
        rawCumulatives = false;
    }

    /// @notice Makes `observe` return these accumulators for the older and newer point.
    function setCumulatives(int56 older, int56 newer) external {
        olderCumulative = older;
        newerCumulative = newer;
        rawCumulatives = true;
    }

    function setObservationCardinality(uint16 cardinality) external {
        observationCardinality = cardinality;
    }

    function setHistoryTooShort(bool tooShort) external {
        historyTooShort = tooShort;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, tick, 0, observationCardinality, observationCardinality, 0, true);
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
        for (uint256 i = 0; i < n; ++i) {
            if (rawCumulatives) {
                tickCumulatives[i] = i == 0 ? olderCumulative : newerCumulative;
            } else {
                tickCumulatives[i] = int56(tick) * (1_000_000_000 - int56(uint56(secondsAgos[i])));
            }
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
