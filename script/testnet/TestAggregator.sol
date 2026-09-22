// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice A Chainlink-shaped price feed whose answer anyone can set, for the Sepolia test market and for unit tests.
/// @dev Never deploy this on a chain that matters: it has no owner, so anyone can move the price. `SetupTestMarket`
///      refuses to run anywhere but Sepolia, which is what keeps it off mainnet.
///
///      Two freshness modes. While `fresh` is true it reports an answer written `age` seconds ago, so a test that
///      warps weeks ahead to reach a rebalance still reads a live feed; the rule's staleness check is then exercised
///      by raising `age` past the token's bound rather than by waiting. With `fresh` false it reports the fixed
///      `updatedAt` it was given, which is what a real feed does between rounds.
contract TestAggregator is IAggregatorV3 {
    string private _description;
    uint8 private _decimals;

    /// @notice The answer {latestRoundData} reports, in `_decimals` decimals.
    int256 public answer;
    /// @notice How far behind the current block the reported timestamp sits while `fresh` is true.
    uint256 public age;
    /// @notice The reported timestamp while `fresh` is false.
    uint256 public updatedAt;
    /// @notice Whether the reported timestamp follows the block clock.
    bool public fresh = true;

    constructor(string memory pair, uint8 answerDecimals, int256 initialAnswer) {
        _description = pair;
        _decimals = answerDecimals;
        answer = initialAnswer;
    }

    /// @notice Sets the answer, leaving the freshness alone.
    function setAnswer(int256 value) external {
        answer = value;
    }

    /// @notice Ages the reported timestamp by `seconds_` behind the current block, keeping it on the block clock.
    function setAge(uint256 seconds_) external {
        age = seconds_;
        fresh = true;
    }

    /// @notice Changes the reported decimals. A real aggregator does not; a proxy repointed to another one does, and
    ///         a fixture placed with `vm.etch` needs it because etching copies code without storage.
    function setDecimals(uint8 answerDecimals) external {
        _decimals = answerDecimals;
    }

    /// @notice Pins the reported timestamp, so it stops following the block clock.
    function setUpdatedAt(uint256 timestamp) external {
        updatedAt = timestamp;
        fresh = false;
    }

    /// @inheritdoc IAggregatorV3
    function decimals() external view returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IAggregatorV3
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc IAggregatorV3
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        // Saturating, so a test that has not warped past `age` reads the start of the chain rather than panicking.
        uint256 written = fresh ? (block.timestamp > age ? block.timestamp - age : 0) : updatedAt;
        return (1, answer, written, written, 1);
    }
}
