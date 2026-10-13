// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IIndexFactory
/// @notice What every Xindex factory answers, and all that `IndexZap` and `MintRequests` call on one: whether it
///         deployed an index. `IWeightedIndexFactory` extends it, so the compiler holds the weighted factory to it. v4's
///         market-cap `IndexFactory` and the rest of its interface are deleted (audit/2026-10-06-v4-retirement.md).
interface IIndexFactory {
    /// @notice Whether this factory deployed `index`: the only proof that an address is an Xindex index.
    function isIndex(address index) external view returns (bool);
}
