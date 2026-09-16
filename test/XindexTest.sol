// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// @notice State and helpers the factory, token, zap and security suites share.
abstract contract XindexTest is Test {
    MockMarket market;
    IndexFactory factory;
    address owner = makeAddr("owner");

    /// @dev Lists `token` priced at tick 0 with the market's default config, through the full listing delay.
    function _list(address token) internal {
        IIndexFactory.TokenConfig memory config = market.config(token, 0);
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }
}
