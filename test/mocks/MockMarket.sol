// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Decimals every mock feed reports, as every USD feed Xindex lists does. File-level so pure test helpers can use
///      it.
uint8 constant FEED_DECIMALS = 8;
/// @dev Staleness bound `MockMarket.configWith` gives a token, matching a one-hour heartbeat plus the policy grace.
uint32 constant DEFAULT_STALENESS = 1 hours + 30 minutes;

/// @notice WETH, USDC and a price feed per token for tests. Prices are given the way a real feed reports them: dollars
///         per whole token with FEED_DECIMALS decimals, so `3000e8` is three thousand dollars whatever the token's own
///         decimals are.
contract MockMarket {
    /// @notice Reference supply `config` gives WETH, which needs one.
    uint256 public constant ETH_SUPPLY = 120_000_000e18;
    /// @notice Reference supply `config` gives every other token, so tests can list tokens nobody has minted yet.
    uint256 public constant DEFAULT_SUPPLY = 1e30;
    /// @notice Staleness `configWith` puts in a config.
    uint32 public constant STALENESS = DEFAULT_STALENESS;

    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;

    /// @notice `token`'s feed, or zero before `config` created it.
    mapping(address token => TestAggregator) public feedOf;

    constructor() {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    /// @notice A listing config for `token` priced at `priceUsd8` dollars per whole token, with a reference supply.
    function config(address token, int256 priceUsd8) external returns (IIndexFactory.TokenConfig memory) {
        return configWith(token, priceUsd8, token == address(weth) ? ETH_SUPPLY : DEFAULT_SUPPLY);
    }

    /// @notice A listing config with an explicit supply definition. The token's feed is created on first use.
    function configWith(address token, int256 priceUsd8, uint256 referenceSupply)
        public
        returns (IIndexFactory.TokenConfig memory c)
    {
        setPrice(token, priceUsd8);
        c.feed = address(feedOf[token]);
        c.maxStaleness = DEFAULT_STALENESS;
        c.referenceSupply = referenceSupply;
    }

    /// @notice Sets `token`'s price in dollars per whole token, creating its feed if it has none.
    function setPrice(address token, int256 priceUsd8) public {
        TestAggregator feed = feedOf[token];
        if (address(feed) == address(0)) {
            feedOf[token] = new TestAggregator("MOCK / USD", FEED_DECIMALS, priceUsd8);
        } else {
            feed.setAnswer(priceUsd8);
        }
    }

    /// @notice A listing config whose feed answers in `feedDecimals` decimals rather than the usual eight. An 18-decimal
    ///         feed on an 18-decimal token makes the rule's exponent zero, so the answer is the WAD price itself: the
    ///         only way to reach a price of a few wei, or one near MAX_PRICE, that a token's own decimals cannot.
    function configWithFeed(address token, int256 answer, uint8 feedDecimals, uint256 referenceSupply)
        public
        returns (IIndexFactory.TokenConfig memory c)
    {
        feedOf[token] = new TestAggregator("MOCK / USD", feedDecimals, answer);
        c.feed = address(feedOf[token]);
        c.maxStaleness = DEFAULT_STALENESS;
        c.referenceSupply = referenceSupply;
    }

    /// @notice Multiplies `token`'s price by `numerator / denominator`, for tests that move a market rather than name
    ///         a level.
    function movePrice(address token, uint256 numerator, uint256 denominator) external {
        TestAggregator feed = feedOf[token];
        feed.setAnswer(feed.answer() * int256(numerator) / int256(denominator));
    }

    /// @notice Ages `token`'s feed, as one that has stopped publishing is.
    function setAge(address token, uint256 seconds_) external {
        feedOf[token].setAge(seconds_);
    }
}

/// @notice The USD-WAD price the rule reads for a token of `tokenDecimals` decimals whose feed answers `priceUsd8`.
function usdWad(int256 priceUsd8, uint8 tokenDecimals) pure returns (uint256) {
    return uint256(priceUsd8) * 10 ** (36 - FEED_DECIMALS - tokenDecimals);
}
