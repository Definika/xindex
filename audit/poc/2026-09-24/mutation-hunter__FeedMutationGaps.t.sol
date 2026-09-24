// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";

/// @notice Killing tests for CompositeFeed mutants that survive the whole offline suite (mutation-hunter, 2026-09-24).
contract FeedMutationGapsTest is Test {
    /// @dev MH-CF. Every CompositeFeed test builds both legs with 8 decimals, so which leg's decimals the product
    ///      divides by and which leg's decimals `decimals()` reports are never observed: the mutants
    ///      `10 ** FEED_A.decimals()` in `latestRoundData` and `FEED_B.decimals()` in `decimals()` survive. The adapter
    ///      is generic, and the common Chainlink shape for a token without a USD feed is TOKEN/ETH (18 decimals) times
    ///      ETH/USD (8 decimals). With FEED_A = ETH/USD and FEED_B = TOKEN/ETH, the shipped code answers in 8 decimals;
    ///      either mutant misprices the token by 1e10, which `_price` accepts (it is far below MAX_PRICE), so a
    ///      listing of such an adapter would put almost all of a capped index's weight on that token.
    function test_MHCF_aProductOfFeedsWithDifferentDecimalsKeepsTheFirstLegsScale() public {
        vm.warp(30 days);
        TestAggregator ethUsd = new TestAggregator("ETH / USD", 8, 4_000e8);
        TestAggregator tokEth = new TestAggregator("TOK / ETH", 18, 0.005e18); // TOK = 0.005 ETH = $20
        CompositeFeed composite = new CompositeFeed(ethUsd, tokEth, 1 hours, 24 hours);

        assertEq(composite.decimals(), 8, "the product is quoted in the first leg's decimals");
        (, int256 answer,,,) = composite.latestRoundData();
        assertEq(answer, 20e8, "$20 in eight decimals: the second leg's 18 decimals are divided back out");
    }
}
