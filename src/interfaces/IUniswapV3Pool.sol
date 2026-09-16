// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3Pool
/// @notice Minimal subset of a Uniswap V3 pool: the oracle reads the rebalance rule uses.
interface IUniswapV3Pool {
    /// @notice The pool's fee tier in hundredths of a basis point, for example 3000 for 0.3%.
    function fee() external view returns (uint24);

    /// @notice The pool's current state.
    /// @return sqrtPriceX96 Square root of the price, token1 raw units per token0 raw unit, in Q64.96.
    /// @return tick The current tick.
    /// @return observationIndex Slot of the most recent oracle observation.
    /// @return observationCardinality Oracle slots in use; the rule needs at least its MIN_OBSERVATION_CARDINALITY.
    /// @return observationCardinalityNext Oracle slots reserved; they come into use as the pool writes observations.
    /// @return feeProtocol Protocol fee setting of both tokens.
    /// @return unlocked False before initialization and while the pool is executing a call.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Tick and liquidity accumulators as of `secondsAgos[i]` seconds before the current block.
    /// @dev Reverts with "OLD" when the oldest stored observation is younger than the requested time.
    /// @param secondsAgos Ages to read, in seconds; 0 is the current block.
    /// @return tickCumulatives Sum of the tick over every second, as of each age.
    /// @return secondsPerLiquidityCumulativeX128s Sum of seconds divided by in-range liquidity (at least 1), in
    ///         Q128.128, as of each age.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
