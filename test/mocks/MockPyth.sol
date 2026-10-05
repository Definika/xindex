// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PythStructs} from "../../src/interfaces/pyth/PythStructs.sol";

/// @notice Stands in for Pyth's `parsePriceFeedUpdatesUnique` and `getUpdateFee` as the deployed contract behaves:
///         each update is one feed, `abi.encode(PriceFeed, prevPublishTime)`, and a feed is returned only from an
///         update published within [minPublishTime, maxPublishTime] whose previous update was published before
///         minPublishTime, so a caller asking for a second gets that second's first update and no other. An update fills
///         the first requested slot with its id, as Pyth's does, so two slots asking for one id never both fill. Fees are
///         `fee` per update and must be paid in full. `Tamper` lets a test make it break its own promises, so the
///         hub's checks of what Pyth returns can be shown to hold; `Reenter` calls back into a target during a parse.
contract MockPyth {
    error InsufficientFee();
    error PriceFeedNotFoundWithinRange();

    enum Tamper {
        None,
        DropLast,
        WrongId,
        LateTime
    }

    uint256 public fee;
    Tamper public tamper;
    address public reenterTarget;
    bytes public reenterCall;
    bytes public reenterResult;
    uint256 public parses;
    uint64 public lastMinPublishTime;
    uint64 public lastMaxPublishTime;
    bytes32[] internal _lastIds;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setTamper(Tamper tamper_) external {
        tamper = tamper_;
    }

    function setReenter(address target, bytes calldata call) external {
        reenterTarget = target;
        reenterCall = call;
    }

    function lastIds() external view returns (bytes32[] memory) {
        return _lastIds;
    }

    /// @notice One update: `id` at `price · 10^expo` ± `conf`, published at `publishTime`, its previous update at
    ///         `prevPublishTime`.
    function update(bytes32 id, int64 price, uint64 conf, int32 expo, uint64 publishTime, uint64 prevPublishTime)
        external
        pure
        returns (bytes memory)
    {
        PythStructs.Price memory p = PythStructs.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        PythStructs.PriceFeed memory feed = PythStructs.PriceFeed({id: id, price: p, emaPrice: p});
        return abi.encode(feed, prevPublishTime);
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return fee * updateData.length;
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds) {
        if (msg.value < fee * updateData.length) revert InsufficientFee();
        ++parses;
        lastMinPublishTime = minPublishTime;
        lastMaxPublishTime = maxPublishTime;
        _lastIds = priceIds;
        if (reenterTarget != address(0)) {
            (, bytes memory result) = reenterTarget.call(reenterCall);
            reenterResult = result;
        }

        // As Pyth's `_parseSingleMerkleUpdate` (Pyth.sol at 2bb0eb54): each update fills the FIRST requested slot with
        // its id, and only while that slot is still empty, so a second slot asking for the same id is never filled and
        // the parse reverts (V5-M1). An earlier version of this mock resolved each slot on its own, which hid that.
        uint256 n = priceIds.length;
        priceFeeds = new PythStructs.PriceFeed[](n);
        for (uint256 u = 0; u < updateData.length; ++u) {
            (PythStructs.PriceFeed memory feed, uint64 prev) =
                abi.decode(updateData[u], (PythStructs.PriceFeed, uint64));
            uint256 k = 0;
            while (k < n && priceIds[k] != feed.id) {
                ++k;
            }
            if (k == n || priceFeeds[k].id != bytes32(0)) continue;
            uint256 published = feed.price.publishTime;
            if (published >= minPublishTime && published <= maxPublishTime && prev < minPublishTime) {
                priceFeeds[k] = feed;
            }
        }
        for (uint256 k = 0; k < n; ++k) {
            if (priceFeeds[k].id == bytes32(0)) revert PriceFeedNotFoundWithinRange();
        }

        if (tamper == Tamper.DropLast) {
            PythStructs.PriceFeed[] memory shorter = new PythStructs.PriceFeed[](n - 1);
            for (uint256 k = 0; k + 1 < n; ++k) {
                shorter[k] = priceFeeds[k];
            }
            priceFeeds = shorter;
        } else if (tamper == Tamper.WrongId) {
            priceFeeds[0].id = keccak256("another feed");
        } else if (tamper == Tamper.LateTime) {
            priceFeeds[0].price.publishTime = uint256(maxPublishTime) + 1;
        }
    }
}
