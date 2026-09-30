// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

/// @notice State and helpers the factory, hub, zap and security suites share.
abstract contract XindexTest is Test {
    MockMarket market;
    IndexFactory factory;
    address owner = makeAddr("owner");

    /// @dev Lists `token` with `supply`, through the full listing delay.
    function _listWith(address token, uint256 supply) internal {
        vm.prank(owner);
        factory.proposeListing(token, supply);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    /// @dev Puts `supplies` in force for `tokens` (ascending) through a supply batch and its delay.
    function _revise(address[] memory tokens, uint256[] memory supplies) internal {
        vm.prank(owner);
        factory.proposeSupplies(tokens, supplies);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
    }

    /// @dev Revises the supply of the single token `token` to `supply` through a one-entry batch.
    function _revise(address token, uint256 supply) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory supplies = new uint256[](1);
        supplies[0] = supply;
        _revise(tokens, supplies);
    }
}
