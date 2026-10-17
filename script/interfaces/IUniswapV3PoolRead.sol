// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3PoolRead
/// @notice Minimal subset of a Uniswap V3 pool: the reads the Sepolia test-market script and `CheckToken` make.
interface IUniswapV3PoolRead {
    /// @notice The pool's fee tier in hundredths of a basis point, for example 3000 for 0.3%.
    function fee() external view returns (uint24);

    /// @notice The liquidity active at the pool's current price.
    function liquidity() external view returns (uint128);

    /// @notice The pool's current state.
    /// @return sqrtPriceX96 Square root of the price, token1 raw units per token0 raw unit, in Q64.96.
    /// @return tick The current tick.
    /// @return observationIndex Slot of the most recent oracle observation.
    /// @return observationCardinality Oracle slots in use.
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
}
