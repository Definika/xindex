// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IPyth
/// @notice The two calls `KeeperExecutor` makes on Pyth's price contract to post a signed update before a fill,
///         declared here rather than copied. Pyth charges a fee per update, verifies its signatures and stores a
///         price only when it is newer than the one it holds.
interface IPyth {
    /// @notice What posting `updateData` costs, in wei.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    /// @notice Verifies and stores the prices in `updateData`. `msg.value` must cover {getUpdateFee}.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}
