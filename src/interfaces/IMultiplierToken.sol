// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMultiplierToken
/// @notice A token whose one unit stands for `multiplier()` units of what it tracks (1e18 = one), and whose balances
///         stay fixed when that changes, as Coinbase's stock tokens on Base do: a dividend raises the multiplier, a
///         split multiplies it.
interface IMultiplierToken {
    /// @notice What one unit of the token stands for, 1e18 = one.
    function multiplier() external view returns (uint256);
}
