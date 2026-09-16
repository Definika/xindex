// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Methodology
/// @notice Weighting rules an index can follow. The id is chosen at creation, stored on the index and hashed into its
///         CREATE2 salt, so an index address commits to its rule.
library Methodology {
    /// @notice Weights proportional to market cap.
    uint8 internal constant UNCAPPED = 0;

    /// @notice The largest constituent weighs 30%, the second largest at most 20%, and the others share the rest in
    ///         proportion to market cap.
    uint8 internal constant CAPPED = 1;

    /// @notice Number of defined methodologies; valid ids are below it.
    uint8 internal constant COUNT = 2;

    /// @notice Below five constituents the capped rule contradicts its own cap: with three the smallest always weighs
    ///         at least 50%, and with four a third- or fourth-ranked constituent always exceeds 20%.
    uint256 internal constant MIN_CAPPED_COMPONENTS = 5;
}
