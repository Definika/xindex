// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Methodology
/// @notice Weighting rules an index can follow. The id is chosen at creation, stored on the index and hashed into its
///         CREATE2 salt, so an index address commits to its rule.
library Methodology {
    /// @notice Weights proportional to market cap.
    uint8 internal constant UNCAPPED = 0;

    /// @notice The largest constituent weighs 30%, the second largest at most 20%, and the others share the rest in
    ///         proportion to market cap. Ranks 3 and below are not capped: when the second is capped they share 50%, so
    ///         one of them can outweigh the first two.
    uint8 internal constant CAPPED = 1;

    /// @notice Number of defined methodologies; valid ids are below it.
    uint8 internal constant COUNT = 2;

    /// @notice Below five constituents a third- or lower-ranked constituent always weighs more than the second's 20%
    ///         cap (with three the smallest weighs at least 50%). Five or more make that possible rather than certain;
    ///         the rule never caps ranks 3 and below.
    uint256 internal constant MIN_CAPPED_COMPONENTS = 5;
}
