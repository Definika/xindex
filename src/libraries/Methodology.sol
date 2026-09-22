// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Methodology
/// @notice Weighting rules an index can follow. The id is chosen at creation, stored on the index and hashed into its
///         CREATE2 salt, so an index address commits to its rule.
library Methodology {
    /// @notice Weights proportional to market cap.
    uint8 internal constant UNCAPPED = 0;

    /// @notice Market-cap weights under a ceiling: the largest constituent weighs at most 30% and every other at most
    ///         20%. Whatever a ceiling holds back is shared again, in proportion to market cap, among the constituents
    ///         still under theirs. A constituent that does not reach its ceiling keeps its own market-cap weight --
    ///         30% is a cap, not an allocation, so the largest is never promoted to it (VR-01).
    uint8 internal constant CAPPED = 1;

    /// @notice Number of defined methodologies; valid ids are below it.
    uint8 internal constant COUNT = 2;

    /// @notice Below five constituents the ceilings cannot hold the whole index: five sum to 30% + 4 x 20% = 110% and
    ///         leave room, but four sum to 30% + 3 x 20% = 90% and the last 10% would have nowhere to go.
    uint256 internal constant MIN_CAPPED_COMPONENTS = 5;
}
