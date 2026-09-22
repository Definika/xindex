// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

/// @notice Puts mainnet's real feed answers on the fork's block clock, for the suites that warp.
/// @dev A fork test reaches a listing two days out and an auction three days past that, and a feed read at the fork
///      block is stale on the other side of those warps. Re-dating it once is not enough, because the next warp makes
///      it stale again.
///
///      So each shipped feed is replaced by a `TestAggregator` carrying that feed's own answer from the fork block,
///      reporting it as written in the current block however far the test warps. The prices are the ones mainnet
///      really published and the decimals are the ones it really reports; only the clock is synthetic. What this
///      deliberately does not stand in for is a market that moved: every answer stays put, so a test that wants drift
///      has to move it on purpose.
abstract contract ForkFeeds is Test {
    /// @dev Every feed the launch whitelist reads, directly or through the composite adapter.
    function _shippedFeeds() internal pure returns (address[8] memory) {
        return [
            A.ETH_USD_FEED,
            A.WSTETH_USD_FEED,
            A.BTC_USD_FEED,
            A.WBTC_BTC_FEED,
            A.SOL_USD_FEED,
            A.UNI_USD_FEED,
            A.LINK_USD_FEED,
            A.AAVE_USD_FEED
        ];
    }

    /// @notice Replaces every shipped feed with one that reports its real answer on the block clock.
    function _pinFeedsToTheBlockClock() internal {
        address[8] memory feeds = _shippedFeeds();
        for (uint256 i = 0; i < feeds.length; ++i) {
            _pinFeed(feeds[i]);
        }
    }

    /// @notice The same for one feed, for a suite that lists something outside the default whitelist.
    function _pinFeed(address feed) internal {
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        uint8 answerDecimals = IAggregatorV3(feed).decimals();
        // `vm.etch` copies code without storage, so the answer, the decimals and the freshness are set through the
        // etched contract rather than through its constructor.
        vm.etch(feed, address(new TestAggregator("", answerDecimals, answer)).code);
        TestAggregator(feed).setAnswer(answer);
        TestAggregator(feed).setDecimals(answerDecimals);
        TestAggregator(feed).setAge(0);
    }

    /// @notice Moves one pinned feed's price, for a test about drift rather than about time.
    function _movePinnedFeed(address feed, uint256 numerator, uint256 denominator) internal {
        TestAggregator pinned = TestAggregator(feed);
        pinned.setAnswer(pinned.answer() * int256(numerator) / int256(denominator));
    }
}
