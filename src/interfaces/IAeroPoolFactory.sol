// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAeroPoolFactory
/// @notice One of Aero's basic-pool factories on Base, the volatile or the stable one: one pool per token pair.
interface IAeroPoolFactory {
    /// @notice The pool of `tokenA` and `tokenB`, in either order, or zero.
    function getPool(address tokenA, address tokenB) external view returns (address);
}
