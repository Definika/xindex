// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPythReader} from "../../src/interfaces/IPythReader.sol";

/// @notice Pyth's price contract as `PythPrices` reads it: a stored price per feed, which a test sets as a filler's
///         update would. `setBroken` makes every read revert, as a contract that stopped answering would.
contract MockPyth is IPythReader {
    /// @notice Pyth's own error for a feed that was never updated here.
    error PriceFeedNotFound();

    mapping(bytes32 id => Price price) internal _prices;
    mapping(bytes32 id => bool exists) internal _exists;
    mapping(bytes32 id => bool live) internal _live;
    bool public broken;

    /// @notice Makes feed `id` known, with no price yet.
    function addFeed(bytes32 id) external {
        _exists[id] = true;
    }

    /// @notice Stores a price for feed `id`, as an update published at `publishTime` would.
    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _exists[id] = true;
        _live[id] = false;
        _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    /// @notice Stores a price for feed `id` that reads as published at the current block, whatever the clock: what a
    ///         filler's update in its own transaction gives, for tests that move the clock across an auction.
    function setLivePrice(bytes32 id, int64 price, uint64 conf, int32 expo) external {
        _exists[id] = true;
        _live[id] = true;
        _prices[id] = Price({price: price, conf: conf, expo: expo, publishTime: 1});
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price) {
        require(!broken, "pyth is down");
        price = _prices[id];
        if (price.publishTime == 0) revert PriceFeedNotFound();
        if (_live[id]) price.publishTime = block.timestamp;
    }

    function priceFeedExists(bytes32 id) external view returns (bool) {
        require(!broken, "pyth is down");
        return _exists[id];
    }
}
