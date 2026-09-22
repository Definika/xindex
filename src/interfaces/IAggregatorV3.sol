// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAggregatorV3
/// @notice Minimal subset of Chainlink's AggregatorV3Interface: the reads the rebalance rule uses.
/// @dev Every shipped feed is a proxy in front of the aggregator that currently serves it, so `decimals` is read on
///      every call rather than cached: answer and decimals then come from the same aggregator in the same block, and a
///      proxy repointed to one with other decimals cannot misprice. `roundId` and `answeredInRound` are not read: they
///      are vestiges of the pre-OCR aggregators, where comparing them detected a carried-over answer, and OCR reports
///      carry no such relation. Staleness is judged from `updatedAt` alone.
interface IAggregatorV3 {
    /// @notice Decimals of `answer`. Eight for every USD feed Xindex lists.
    function decimals() external view returns (uint8);

    /// @notice Human-readable pair, for example "BTC / USD". Off-chain checks pin it; nothing on-chain reads it.
    function description() external view returns (string memory);

    /// @notice The latest answer and when it was written.
    /// @return roundId Round the answer belongs to. Not read by Xindex.
    /// @return answer Price of the base asset in the quote asset, scaled by {decimals}.
    /// @return startedAt When the round started.
    /// @return updatedAt When the answer was last written. Xindex measures staleness from this.
    /// @return answeredInRound Round the answer was computed in. Not read by Xindex.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
