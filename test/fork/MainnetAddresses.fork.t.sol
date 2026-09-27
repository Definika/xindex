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
    function poolManager() external view returns (address);
}

/// @notice The circuit-breaker bounds of a Chainlink aggregator, which live on the aggregator the proxy points at
///         rather than on the proxy itself. An answer that would fall outside them is reported clamped to the bound,
///         with a fresh timestamp and no other signal, which is what made the LUNA collapse readable as a valid price
///         long after it was not one.
interface IAggregatorBounds {
    function aggregator() external view returns (address);
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
}

/// @notice Checks the scripts' `MainnetAddresses` against mainnet, as AGENTS.md requires before addresses are
///         committed: tokens by symbol and decimals, every feed by the pair its own `description` names and by its
///         decimals, the router by the PoolManager it names and both by their runtime code hashes, and every default
///         whitelist entry against the rule, against its own token's feed and bound, and for a supply of plausibly many
///         whole tokens. Feed identity cannot be proved on-chain, so pinning `description` here is what ties each
///         shipped address to the pair it is supposed to be. Skips when MAINNET_RPC_URL is unset.
contract MainnetAddressesForkTest is Test {
    /// @dev Runtime code hash of Universal Router 2.0.0 at `MainnetAddresses.UNIVERSAL_ROUTER`, read on 2026-09-23. The
    ///      router has no proxy, and its immutables are part of its code, so the hash is the build and its wiring.
    bytes32 constant UNIVERSAL_ROUTER_CODEHASH = 0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f;
    /// @dev Runtime code hash of the V4 PoolManager at `MainnetAddresses.POOL_MANAGER`, read on 2026-09-23.
    bytes32 constant POOL_MANAGER_CODEHASH = 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;

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
        _assertBoundsAreFarFromTheAnswer(feed, answer);
    }

    /// @dev A feed pinned at a circuit-breaker bound reports a clamped answer with a fresh timestamp, so the rule
    ///      cannot tell it from a real price and neither can any check inside `_price`: freshness and positivity are
    ///      both satisfied. That is the LUNA/Venus failure, and the only place it can be caught is here, before a
    ///      feed is listed at all. The margin is deliberately coarse. It is not a claim that a hundredfold move is
    ///      impossible; it is a claim that a feed whose bound sits within one of its current answer was configured
    ///      with a live breaker, and such a feed has no place on the list. Chainlink's own convention for a disabled
    ///      breaker, `minAnswer` of 1 against a `maxAnswer` of 2^176 - 1, clears this by dozens of orders of
    ///      magnitude, so one rule covers both the disabled case and a mistakenly narrow one.
    function _assertBoundsAreFarFromTheAnswer(address feed, int256 answer) private view {
        address aggregator = IAggregatorBounds(feed).aggregator();
        int256 low = IAggregatorBounds(aggregator).minAnswer();
        int256 high = IAggregatorBounds(aggregator).maxAnswer();
        // A bound that cannot be read is not a bound that is known to be safe: fail, so someone looks at the feed.
        assertLt(low, high, "the aggregator reports usable circuit-breaker bounds");
        assertGe(answer, low * 100, "the answer sits a hundredfold above the aggregator's floor");
        assertLe(answer * 100, high, "and a hundredfold below its ceiling");
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

    /// @dev XA-13, CR-I35. The zap reads the pool manager off the router, so the pinned router has to name the pool
    ///      manager the address book does. Every Universal Router build on mainnet answers that the same way, the 2.1
    ///      line included, whose V3 inputs the zap does not encode, so the router is pinned by its code hash as well,
    ///      to the 2.0.0 build the zap was verified against, and so is the PoolManager.
    function testFork_XA13_CRI35_uniswapContractsAgree() public view {
        assertEq(IRouterImmutables(M.UNIVERSAL_ROUTER).poolManager(), M.POOL_MANAGER);
        assertEq(M.UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODEHASH, "the pinned router is the 2.0.0 build");
        assertEq(M.POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "and the PoolManager is the one it settles with");
    }

    function testFork_XA13_deployResolvesTheMainnetMarket() public {
        Deploy deployer = new Deploy();
        assertEq(deployer.resolveRouter(address(0)), M.UNIVERSAL_ROUTER);
    }

    /// @dev Every default entry, as the listing script builds it, put to the rule against live mainnet feeds. Each
    ///      reference supply is a whole number of tokens between a million and a trillion at the token's own on-chain
    ///      decimals, where a decimals slip shows: DA-18 bounds a change against the supply in force, and a first
    ///      listing has none (XA-24, CR-I22).
    function testFork_XA13_XA24_CRI22_defaultWhitelistMatchesMainnet() public {
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
            uint256 one = 10 ** uint256(IERC20Metadata(list[i].token).decimals());
            assertEq(list[i].referenceSupply % one, 0, "a whole number of tokens");
            assertGe(list[i].referenceSupply / one, 1e6, "at least a million of them");
            assertLe(list[i].referenceSupply / one, 1e12, "and at most a trillion");

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

    /// @dev CR-L08. Each feed constant is pinned to its pair above, and nothing checked which one each default entry
    ///      names: a UNI/AAVE feed swap, or a 24-hour bound on ETH/USD, passed every test. Here each entry is read as an
    ///      operator reads the run, the token's own symbol beside its feed's own description, and matched against a
    ///      table written apart from `MainnetAddresses`, bound included: the feed's heartbeat plus half an hour.
    function testFork_CRL08_eachDefaultEntryPricesItsOwnToken() public {
        ConfigureWhitelist configure = new ConfigureWhitelist();
        CompositeFeed wbtcFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(address(wbtcFeed));
        uint256 seen = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            string memory symbol = IERC20Metadata(list[i].token).symbol();
            (uint256 row, string memory pair, uint256 heartbeat) = _expectedFeed(symbol);
            assertEq(seen & (1 << row), 0, string.concat(symbol, " is on the list once"));
            seen |= 1 << row;
            assertEq(
                IAggregatorV3(list[i].feed).description(), pair, string.concat(symbol, " is priced by its own feed")
            );
            assertEq(uint256(list[i].maxStaleness), heartbeat + 30 minutes, "at its heartbeat plus half an hour");
        }
        assertEq(seen, (1 << 7) - 1, "and every token in the table is on it");
    }

    /// @dev The launch whitelist as Chainlink's directory describes it, keyed by each token's own symbol.
    function _expectedFeed(string memory symbol)
        private
        pure
        returns (uint256 row, string memory pair, uint256 heartbeat)
    {
        string[7] memory symbols = ["WETH", "wstETH", "WBTC", "SOL", "LINK", "UNI", "AAVE"];
        string[7] memory pairs = [
            "ETH / USD",
            "wstETH / USD Calculated",
            "BTC / USD * WBTC / BTC", // WBTC/BTC's heartbeat, the slower leg's, bounds the product
            "SOL / USD",
            "LINK / USD",
            "UNI / USD",
            "AAVE / USD"
        ];
        uint256[7] memory heartbeats = [uint256(1 hours), 24 hours, 24 hours, 24 hours, 1 hours, 1 hours, 1 hours];
        for (row = 0; row < symbols.length; ++row) {
            if (keccak256(bytes(symbols[row])) == keccak256(bytes(symbol))) return (row, pairs[row], heartbeats[row]);
        }
        revert(string.concat("no expectation for ", symbol));
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
