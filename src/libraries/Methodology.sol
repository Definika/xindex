// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Methodology
/// @notice Weighting rules an index can follow. The id is chosen at creation, stored on the index and hashed into its
///         CREATE2 salt, so an index address commits to its rule.
library Methodology {
    /// @notice Weights proportional to market cap.
    uint8 internal constant UNCAPPED = 0;

    /// @notice Market-cap weights under a ceiling: every constituent but the largest weighs at most 20%, and the largest
    ///         at most 30%, a ceiling it earns by its lead over the runner-up: 20% at a tie, rising linearly to the full
    ///         30% once its market cap is twice the second's (CR-L01). Whatever a ceiling holds back is shared again, in
    ///         proportion to market cap, among the constituents still under theirs. A constituent that does not reach
    ///         its ceiling keeps its own market-cap weight -- the ceilings are caps, not allocations, so the largest is
    ///         never promoted to one (VR-01). Because the top ceiling follows the lead, the weights move continuously
    ///         with market caps: which of two near-tied leaders ranks first changes nothing.
    uint8 internal constant CAPPED = 1;

    /// @notice Number of defined methodologies; valid ids are below it.
    uint8 internal constant COUNT = 2;

    /// @notice Below five constituents the ceilings cannot hold the whole index: five sum to at least 5 x 20% = 100%
    ///         (exactly that when the two largest tie) and leave room, but four sum to at most 30% + 3 x 20% = 90% and
    ///         the last 10% would have nowhere to go.
    uint256 internal constant MIN_CAPPED_COMPONENTS = 5;
}
