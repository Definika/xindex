// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @notice The Uniswap V3 pool calls the testnet market script uses to price a new pool, reserve oracle slots and size
///         a listing's minimum liquidity.
interface IUniswapV3PoolSetup {
    /// @notice Sets the starting price, as the square root of token1 raw units per token0 raw unit in Q64.96.
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Reserves observation slots; the pool starts using them at its next observation write.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    /// @notice In-range liquidity at the current price.
    function liquidity() external view returns (uint128);
}
