// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";

/// @notice r3 git-history lens. At 85a3443 the pairing of a whitelist entry with its price source was protected twice:
///         on-chain, `IndexRule._checkPool` required `getPool(token, WETH, fee) == pool`, which refused another token's
///         genuine pool and a look-alike (`test_R02_lookAlikePoolIsRejected`, `test_checkConfig_pools`), and in the
///         fork suite `testFork_XA13_XA24_defaultWhitelistMatchesMainnet` pinned every default entry's pool by address
///         (`assertEq(config.pool, pools[i], "the fee tier names the verified pool")`). Commit 640e57a removed both.
///         The rule can no longer check pairing (documented), but the docs name "a fork test pinning each shipped feed"
///         as part of "the whole defence". That fork test pins each `MainnetAddresses` feed CONSTANT to a description;
///         nothing checks WHICH constant each `defaultMainnetList` entry uses, nor its staleness bound.
///
///         Run: forge test --match-path test/audit/DefaultListPairing.t.sol -vv (uses a public mainnet RPC).
contract DefaultListPairingPoC is Test {
    ConfigureWhitelist configure;
    CompositeFeed wbtcFeed;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, forkBlock);
        configure = new ConfigureWhitelist();
        wbtcFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );
    }

    // ---------------------------------------------------------------------
    // PoC: a mis-paired default list passes the whole acceptance path the repository ships
    // ---------------------------------------------------------------------

    /// @dev The mutant is applied in memory here (LINK <-> UNI feeds swapped, LINK's bound widened to 24.5 h), then the
    ///      body of `testFork_XA13_XA24_defaultWhitelistMatchesMainnet` is replayed step for step. Every step passes, and
    ///      the rule ends up pricing LINK with UNI's answer. The same two edits made to `ConfigureWhitelist.s.sol`
    ///      itself leave all 362 offline tests and all 25 fork tests green (mutants M1 and M3 in the report).
    function test_poc_aMisPairedDefaultListPassesEveryShippedCheck() public {
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(address(wbtcFeed));
        uint256 linkAt = _indexOf(list, M.LINK);
        uint256 uniAt = _indexOf(list, M.UNI);
        (list[linkAt].feed, list[uniAt].feed) = (list[uniAt].feed, list[linkAt].feed);
        list[linkAt].maxStaleness = M.STALENESS_24H; // a 1-hour feed given a 24.5-hour bound

        // The shipped acceptance path, verbatim.
        IndexFactory factory = new IndexFactory(address(this), address(0));
        IIndexRule rule = IIndexRule(factory.RULE());
        configure.checkWbtcFeed(address(wbtcFeed));
        assertEq(list.length, 7);
        for (uint256 i = 0; i < list.length; ++i) {
            IIndexFactory.TokenConfig memory config = configure.configFor(list[i]);
            rule.checkConfig(list[i].token, config);
            factory.proposeListing(list[i].token, config);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        _refreshFeeds();
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
            assertTrue(factory.isWhitelisted(list[i].token));
            assertGt(rule.price(list[i].token), 0);
        }

        // And the consequence: LINK is now priced from UNI/USD, and UNI from LINK/USD.
        (, int256 linkUsd,,,) = IAggregatorV3(M.LINK_USD_FEED).latestRoundData();
        (, int256 uniUsd,,,) = IAggregatorV3(M.UNI_USD_FEED).latestRoundData();
        assertEq(rule.price(M.LINK), uint256(uniUsd) * 1e10, "LINK is priced at UNI's answer");
        assertEq(rule.price(M.UNI), uint256(linkUsd) * 1e10, "and UNI at LINK's");
        uint256 ratio = uint256(linkUsd) * 1e18 / uint256(uniUsd);
        emit log_named_decimal_uint("LINK/USD over UNI/USD at the fork block", ratio, 18);
        assertTrue(ratio != 1e18, "two different assets, two different prices");
        assertEq(factory.tokenConfig(M.LINK).maxStaleness, M.STALENESS_24H, "and LINK's 1-hour feed has a 24.5 h bound");
    }

    // ---------------------------------------------------------------------
    // Kill test: fails under M1 / M3, passes on canonical
    // ---------------------------------------------------------------------

    /// @dev The check the base fork test made with `pools[i]`, restated for feeds: every default entry, keyed by its
    ///      TOKEN rather than by position, names the feed whose own `description()` is that token's pair, with the
    ///      staleness bound its heartbeat policy gives. The expected table is independent of `defaultMainnetList`.
    function test_killer_everyDefaultEntryNamesItsOwnTokensFeedAndBound() public view {
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(address(wbtcFeed));
        assertEq(list.length, 7);
        for (uint256 i = 0; i < list.length; ++i) {
            (string memory pair, uint32 bound) = _expected(list[i].token);
            assertEq(IAggregatorV3(list[i].feed).description(), pair, "the entry names its own token's feed");
            assertEq(list[i].maxStaleness, bound, "with the bound its heartbeat policy gives");
        }
    }

    function _expected(address token) internal pure returns (string memory pair, uint32 bound) {
        if (token == M.WETH) return ("ETH / USD", M.STALENESS_1H);
        if (token == M.WSTETH) return ("wstETH / USD Calculated", M.STALENESS_24H);
        if (token == M.WBTC) return ("BTC / USD * WBTC / BTC", M.STALENESS_24H);
        if (token == M.WSOL) return ("SOL / USD", M.STALENESS_24H);
        if (token == M.LINK) return ("LINK / USD", M.STALENESS_1H);
        if (token == M.UNI) return ("UNI / USD", M.STALENESS_1H);
        if (token == M.AAVE) return ("AAVE / USD", M.STALENESS_1H);
        revert("unexpected default entry");
    }

    function _indexOf(ConfigureWhitelist.Entry[] memory list, address token) internal pure returns (uint256) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i].token == token) return i;
        }
        revert("not in the list");
    }

    /// @dev As the shipped fork test does: re-date every shipped feed to now, keeping its real answer.
    function _refreshFeeds() internal {
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
