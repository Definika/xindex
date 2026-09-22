// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

interface IRouterImmutables {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

/// @notice Checks the scripts' `MainnetAddresses` against mainnet, as AGENTS.md requires before addresses are
///         committed: tokens by symbol and decimals, every feed by the pair its own `description` names and by its
///         decimals, the router's own factory and WETH, and every default whitelist entry against the rule. Feed
///         identity cannot be proved on-chain, so pinning `description` here is what ties each shipped address to the
///         pair it is supposed to be. Skips when MAINNET_RPC_URL is unset.
contract MainnetAddressesForkTest is Test {
    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // FORK_BLOCK overrides the pin, for a non-archive RPC that only serves recent state. Forge loads .env
        // automatically, so a MAINNET_RPC_URL set there makes a plain `forge test` run these suites too.
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
    }

    function _assertToken(address token, string memory symbol, uint8 decimals) internal view {
        assertEq(IERC20Metadata(token).symbol(), symbol);
        assertEq(IERC20Metadata(token).decimals(), decimals);
    }

    function testFork_XA13_tokensAreWhatTheirNamesSay() public view {
        _assertToken(M.WETH, "WETH", 18);
        _assertToken(M.USDC, "USDC", 6);
        _assertToken(M.USDT, "USDT", 6);
        _assertToken(M.WSTETH, "wstETH", 18);
        _assertToken(M.WBTC, "WBTC", 8);
        _assertToken(M.WSOL, "SOL", 9); // Wormhole wrapped SOL reports the plain symbol
        _assertToken(M.LINK, "LINK", 18);
        _assertToken(M.UNI, "UNI", 18);
        _assertToken(M.AAVE, "AAVE", 18);
    }

    /// @dev The rule cannot tell one aggregator from another on-chain, so every shipped address is pinned here to the
    ///      pair its own `description` names, at the decimals the conversion assumes, with an answer that is positive
    ///      and no older than the bound the default list gives it.
    function testFork_feedsAreWhatTheirNamesSay() public view {
        _assertFeed(M.ETH_USD_FEED, "ETH / USD", M.STALENESS_1H);
        _assertFeed(M.WSTETH_USD_FEED, "wstETH / USD Calculated", M.STALENESS_24H);
        _assertFeed(M.BTC_USD_FEED, "BTC / USD", M.STALENESS_1H);
        _assertFeed(M.WBTC_BTC_FEED, "WBTC / BTC", M.STALENESS_24H);
        _assertFeed(M.SOL_USD_FEED, "SOL / USD", M.STALENESS_24H);
        _assertFeed(M.UNI_USD_FEED, "UNI / USD", M.STALENESS_1H);
        _assertFeed(M.LINK_USD_FEED, "LINK / USD", M.STALENESS_1H);
        _assertFeed(M.AAVE_USD_FEED, "AAVE / USD", M.STALENESS_1H);
    }

    function _assertFeed(address feed, string memory pair, uint32 maxStaleness) private view {
        assertEq(IAggregatorV3(feed).description(), pair, "the feed is not the pair the list names");
        assertEq(IAggregatorV3(feed).decimals(), 8, "every USD feed the list carries answers in eight decimals");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        assertGt(answer, 0, "a live answer");
        assertLe(block.timestamp - updatedAt, maxStaleness, "and one the list's bound still accepts");
    }

    /// @dev WBTC has no USD feed, so the adapter multiplies BTC/USD by WBTC/BTC. The product is checked exactly, not
    ///      approximately: a rounding difference here would mean the adapter is not doing what its name says.
    function testFork_theCompositeFeedMultipliesItsTwoLegs() public {
        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        (, int256 btc,, uint256 btcAt,) = IAggregatorV3(M.BTC_USD_FEED).latestRoundData();
        (, int256 peg,, uint256 pegAt,) = IAggregatorV3(M.WBTC_BTC_FEED).latestRoundData();

        (, int256 answer,, uint256 updatedAt,) = wbtcFeed.latestRoundData();
        assertEq(answer, btc * peg / 1e8, "the product of the two legs, at the first leg's decimals");
        assertEq(updatedAt, btcAt < pegAt ? btcAt : pegAt, "and the older of the two timestamps");
        assertEq(wbtcFeed.decimals(), 8);
        assertEq(wbtcFeed.description(), "BTC / USD * WBTC / BTC");
    }

    function testFork_XA13_uniswapContractsAgree() public view {
        assertEq(IRouterImmutables(M.SWAP_ROUTER_02).factory(), A.UNISWAP_V3_FACTORY);
        assertEq(IRouterImmutables(M.SWAP_ROUTER_02).WETH9(), M.WETH);
    }

    function testFork_XA13_deployResolvesTheMainnetMarket() public {
        Deploy deployer = new Deploy();
        assertEq(deployer.resolveRouter(address(0)), M.SWAP_ROUTER_02);
    }

    /// @dev Every default entry, as the listing script builds it, put to the rule against live mainnet feeds.
    function testFork_XA13_XA24_defaultWhitelistMatchesMainnet() public {
        IndexFactory factory = new IndexFactory(address(this), address(0));
        IIndexRule rule = IIndexRule(factory.RULE());
        ConfigureWhitelist configure = new ConfigureWhitelist();
        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        configure.checkWbtcFeed(address(wbtcFeed));

        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(address(wbtcFeed));
        assertEq(list.length, 7, "the launch list is seven components");
        for (uint256 i = 0; i < list.length; ++i) {
            IIndexFactory.TokenConfig memory config = configure.configFor(list[i]);
            rule.checkConfig(list[i].token, config);

            vm.prank(address(this));
            factory.proposeListing(list[i].token, config);
        }
        // The listing delay is two days, and a feed read at the fork block is two days stale on the other side of it.
        // Only `updatedAt` is moved forward, never the answer: the prices stay the ones mainnet really published, so
        // this stands in for time passing rather than for a market that moved.
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        _refreshFeeds();

        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
            assertTrue(factory.isWhitelisted(list[i].token));
            assertGt(rule.price(list[i].token), 0, "and the rule prices it from the feed the entry names");
        }
    }

    /// @dev Re-dates every shipped feed to the current block, keeping its real answer. The composite adapter is not
    ///      mocked: it reads its two legs, so re-dating them is enough and the product stays the real one.
    function _refreshFeeds() private {
        address[8] memory feeds = [
            M.ETH_USD_FEED,
            M.WSTETH_USD_FEED,
            M.BTC_USD_FEED,
            M.WBTC_BTC_FEED,
            M.SOL_USD_FEED,
            M.UNI_USD_FEED,
            M.LINK_USD_FEED,
            M.AAVE_USD_FEED
        ];
        for (uint256 i = 0; i < feeds.length; ++i) {
            (uint80 roundId, int256 answer,,, uint80 answeredIn) = IAggregatorV3(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeCall(IAggregatorV3.latestRoundData, ()),
                abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredIn)
            );
        }
    }
}
