// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Methodology
/// @notice Weighting rules an index can follow. The id is chosen at creation, stored on the index and hashed into its
///         CREATE2 salt, so an index address commits to its rule.
library Methodology {
    /// @notice Weights proportional to market cap.
    uint8 internal constant UNCAPPED = 0;

    /// @notice The largest constituent weighs 30% and every other constituent weighs at most 20%: the rest share the
    ///         remaining 70% in proportion to market cap, and whatever a cap holds back is shared again among the
    ///         constituents still under it.
    uint8 internal constant CAPPED = 1;

    /// @notice Number of defined methodologies; valid ids are below it.
    uint8 internal constant COUNT = 2;

    /// @notice Below five constituents the 20% cap cannot hold: the four ranks below the largest can take 80% of the
    ///         index, but three can take only 60%, less than the 70% left over from the largest's 30%.
    uint256 internal constant MIN_CAPPED_COMPONENTS = 5;
}
