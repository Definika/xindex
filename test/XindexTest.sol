// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice State and helpers the zap, MintRequests and security suites share: a weighted factory over a stand-in Pyth,
///         and indexes built from explicit units with the weights shared equally. Nothing these suites drive reads a
///         weight before a rebalance, so the units alone shape every basket.
abstract contract XindexTest is Test {
    MockMarket market;
    MockPyth pyth;
    WeightedIndexFactory factory;
    address owner = makeAddr("owner");

    /// @dev Deploys the stand-in Pyth and a weighted factory owned by `owner`, with `guardian` (zero for none).
    function _deployFactory(address guardian) internal {
        pyth = new MockPyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth));
    }

    /// @dev The Pyth price id `token` is listed under: one per token, so no two components share a feed (V5-M1).
    function _priceId(address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(token));
    }

    /// @dev Lists `token` under its own price id, through the full listing delay.
    function _listWith(address token) internal {
        vm.prank(owner);
        factory.proposeListing(token, _priceId(token));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    /// @dev `tokens` at `units` per whole index token, the weights shared equally, the remainder to the first.
    function _specs(address[] memory tokens, uint256[] memory units)
        internal
        view
        returns (IWeightedIndexFactory.ComponentSpec[] memory specs)
    {
        uint256 n = tokens.length;
        uint256 total = factory.TOTAL_WEIGHT();
        specs = new IWeightedIndexFactory.ComponentSpec[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 weight = total / n + (i == 0 ? total % n : 0);
            specs[i] = IWeightedIndexFactory.ComponentSpec({token: tokens[i], weight: weight, units: units[i]});
        }
    }

    /// @dev No creator fee, any platform fee the policy charges, the shortest interval, open and listed.
    function _params() internal pure returns (IWeightedIndexFactory.IndexParams memory) {
        return IWeightedIndexFactory.IndexParams({
            creatorFeeBps: 0,
            creatorStreamingBps: 0,
            maxPlatformFeeBps: 25,
            maxPlatformStreamingBps: 100,
            rebalanceInterval: 7 days,
            gated: false,
            listed: true
        });
    }

    /// @dev Creates an index of `tokens` at `units`, from this contract.
    function _createIndex(string memory name, string memory symbol, address[] memory tokens, uint256[] memory units)
        internal
        returns (WeightedHub)
    {
        return WeightedHub(factory.createIndex(name, symbol, _specs(tokens, units), _params()));
    }

    /// @dev Two-element arrays, for the many two-component indexes the suites build.
    function _pair(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        (t[0], t[1]) = (a, b);
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory u) {
        u = new uint256[](2);
        (u[0], u[1]) = (a, b);
    }
}
