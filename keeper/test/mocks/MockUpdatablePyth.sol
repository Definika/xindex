// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MockPyth} from "xindex/test/mocks/MockPyth.sol";

/// @notice Pyth's contract as the keeper's executor uses it: an update is posted for a fee and stores its prices.
///         Here an update is the ABI encoding of one price, unsigned, where Pyth's carries its signers' signatures.
contract MockUpdatablePyth is MockPyth {
    /// @notice Pyth's own error for a call that carries less than {getUpdateFee}.
    error InsufficientFee();

    /// @notice What one update costs to post, in wei.
    uint256 public constant FEE_PER_UPDATE = 7;

    function getUpdateFee(bytes[] calldata updateData) public pure returns (uint256) {
        return FEE_PER_UPDATE * updateData.length;
    }

    /// @notice Stores each update's price when it is newer than the one held, as Pyth does.
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        if (msg.value < getUpdateFee(updateData)) revert InsufficientFee();
        for (uint256 i = 0; i < updateData.length; ++i) {
            (bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) =
                abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint256));
            if (publishTime <= _prices[id].publishTime) continue;
            _exists[id] = true;
            _live[id] = false;
            _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        }
    }
}
