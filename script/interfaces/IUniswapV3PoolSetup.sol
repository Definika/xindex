// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @notice The one Uniswap V3 pool call the testnet market script makes to price a new pool. Nothing in `src/` reads
///         a price at all, and these pools exist only so the Sepolia market has V3 routes for the zap to swap
///         through.
interface IUniswapV3PoolSetup {
    /// @notice Sets the starting price, as the square root of token1 raw units per token0 raw unit in Q64.96.
    function initialize(uint160 sqrtPriceX96) external;
}
