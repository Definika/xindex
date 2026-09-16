// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3Pool
/// @notice Minimal subset of a Uniswap V3 pool: the oracle reads the rebalance rule uses.
interface IUniswapV3Pool {
    function fee() external view returns (uint24);

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
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
