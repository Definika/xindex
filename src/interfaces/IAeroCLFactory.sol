// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAeroCLFactory
/// @notice Aero's concentrated-liquidity pool factory on Base: one pool per token pair and tick spacing.
interface IAeroCLFactory {
    /// @notice The pool of `tokenA` and `tokenB` at `tickSpacing`, in either order, or zero.
    function getPool(address tokenA, address tokenB, uint24 tickSpacing) external view returns (address);
}
