// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {MainnetAddresses as A} from "../../script/MainnetAddresses.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

interface IWstEth {
    function stEthPerToken() external view returns (uint256);
}

/// @notice Independent verification of the "feed lag exceeds DA-05's 15% bound" finding.
///
///         Unlike the reporter's PoC, no Chainlink tuple is hard-coded: every answer is read with latestRoundData from
///         the real mainnet proxies on an ARCHIVE fork at the exact block (C, S = C + 28d, t = S + 3d, and t + 60s), as
///         is wstETH's live totalSupply and stEthPerToken. The default 7-token CAPPED basket is then replayed with its
///         shipped configs. At t (m = 0.9 exactly) the gate passes at the answers in force. The control then sets
///         every feed to the Coinbase USD 1m close of that same minute (wstETH at ETH x stEthPerToken, i.e. at par to
///         ETH, which overvalues what the index receives) and the very same fill is REFUSED by the gate with
///         SettlementValueTooLow: the lag is what let a >15% fill through.
contract VerifyFeedLagBound is Test {
    string constant RPC = "https://eth.drpc.org"; // archive-capable public endpoint
    uint8 constant CAPPED = 1;
    uint256 constant WAD = 1e18;

    struct Snap {
        uint80[8] id;
        int256[8] answer;
        uint256[8] updatedAt;
        uint256 ts;
        uint256 wstSupply;
        uint256 stEthPerToken;
    }

    /// @dev USD, 8 decimals: ETH, BTC, SOL, LINK, UNI, AAVE (Coinbase 1m close of the minute ending at t + 1s).
    struct Mkt {
        int256 eth;
        int256 btc;
        int256 sol;
        int256 link;
        int256 uni;
        int256 aave;
    }

    address[8] proxies = [
        A.ETH_USD_FEED,
        A.WSTETH_USD_FEED,
        A.BTC_USD_FEED,
        A.WBTC_BTC_FEED,
        A.SOL_USD_FEED,
        A.LINK_USD_FEED,
        A.UNI_USD_FEED,
        A.AAVE_USD_FEED
    ];

    IndexFactory factory;
    IIndexRule rule;
    IndexToken index;
    MockRebalanceExecutor executor;
    TestAggregator[8] feed;
    CompositeFeed wbtcFeed;
    MockERC20[7] tok;
    address[] tokens;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");
    address world = makeAddr("world");

    function _read(uint256 blockNo) internal returns (Snap memory s) {
        vm.createSelectFork(RPC, blockNo);
        s.ts = block.timestamp;
        for (uint256 i = 0; i < 8; ++i) {
            (uint80 id, int256 ans,, uint256 upd,) = IAggregatorV3(proxies[i]).latestRoundData();
            s.id[i] = id;
            s.answer[i] = ans;
            s.updatedAt[i] = upd;
        }
        s.wstSupply = IERC20(A.WSTETH).totalSupply();
        s.stEthPerToken = IWstEth(A.WSTETH).stEthPerToken();
    }

    function _apply(Snap memory s) internal {
        for (uint256 i = 0; i < 8; ++i) {
            feed[i].setAnswer(s.answer[i]);
            feed[i].setUpdatedAt(s.updatedAt[i]);
        }
        uint256 total = tok[1].totalSupply();
        if (total > s.wstSupply) tok[1].burn(world, total - s.wstSupply);
        else tok[1].mint(world, s.wstSupply - total);
    }

    function _applyMarket(Snap memory t, Mkt memory m) internal {
        int256[8] memory px;
        px[0] = m.eth;
        px[1] = int256(uint256(m.eth) * t.stEthPerToken / WAD); // wstETH at par to ETH
        px[2] = m.btc;
        px[3] = t.answer[3]; // WBTC/BTC left at its own answer (~par)
        px[4] = m.sol;
        px[5] = m.link;
        px[6] = m.uni;
        px[7] = m.aave;
        for (uint256 i = 0; i < 8; ++i) {
            feed[i].setAnswer(px[i]);
            feed[i].setUpdatedAt(block.timestamp);
        }
    }

    function _deploy(Snap memory c) internal {
        vm.warp(c.ts - 3 days);
        factory = new IndexFactory(owner, guardian);
        rule = IIndexRule(factory.RULE());
        executor = new MockRebalanceExecutor();
        for (uint256 i = 0; i < 8; ++i) {
            feed[i] = new TestAggregator("feed", 8, c.answer[i]); // fresh mode for the listing only
        }
        wbtcFeed = new CompositeFeed(
            IAggregatorV3(address(feed[2])), IAggregatorV3(address(feed[3])), A.STALENESS_1H, A.STALENESS_24H
        );
        tok[0] = new MockERC20("WETH", "WETH", 18);
        tok[1] = new MockERC20("wstETH", "wstETH", 18);
        tok[2] = new MockERC20("WBTC", "WBTC", 8);
        tok[3] = new MockERC20("SOL", "SOL", 9);
        tok[4] = new MockERC20("LINK", "LINK", 18);
        tok[5] = new MockERC20("UNI", "UNI", 18);
        tok[6] = new MockERC20("AAVE", "AAVE", 18);
        for (uint256 i = 0; i < 7; ++i) {
            tokens.push(address(tok[i]));
        }
        tok[1].mint(world, c.wstSupply);
        // Shipped configs (ConfigureWhitelist.defaultMainnetList).
        IIndexFactory.TokenConfig[7] memory cfg;
        cfg[0] = IIndexFactory.TokenConfig(address(feed[0]), A.STALENESS_1H, A.ETH_SUPPLY);
        cfg[1] = IIndexFactory.TokenConfig(address(feed[1]), A.STALENESS_24H, A.WSTETH_SUPPLY);
        cfg[2] = IIndexFactory.TokenConfig(address(wbtcFeed), A.STALENESS_24H, A.BTC_SUPPLY);
        cfg[3] = IIndexFactory.TokenConfig(address(feed[4]), A.STALENESS_24H, A.SOL_SUPPLY);
        cfg[4] = IIndexFactory.TokenConfig(address(feed[5]), A.STALENESS_1H, A.LINK_SUPPLY);
        cfg[5] = IIndexFactory.TokenConfig(address(feed[6]), A.STALENESS_1H, A.UNI_SUPPLY);
        cfg[6] = IIndexFactory.TokenConfig(address(feed[7]), A.STALENESS_1H, A.AAVE_SUPPLY);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 7; ++i) {
            factory.proposeListing(tokens[i], cfg[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 7; ++i) {
            factory.executeListing(tokens[i]);
        }
    }

    function _logSnap(Snap memory t, Snap memory nx) internal pure {
        string[8] memory n = ["ETH", "wstETH", "BTC", "WBTC/BTC", "SOL", "LINK", "UNI", "AAVE"];
        for (uint256 i = 0; i < 8; ++i) {
            console2.log(n[i]);
            console2.log("   answer@t, age s, answer@next:", uint256(t.answer[i]), t.ts - t.updatedAt[i]);
            console2.log("                                ", uint256(nx.answer[i]), nx.updatedAt[i]);
        }
        console2.log("stEthPerToken@t", t.stEthPerToken);
    }

    function _takeBps() internal view returns (uint256 bps, uint256 outV, uint256 inV) {
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        (outV, inV) = rule.settlementValues(tokens, amountsOut, amountsIn);
        bps = (outV - inV) * 10_000 / outV;
    }

    function _scenario(uint256 bC, uint256 bS, uint256 bT, uint256 bNext, Mkt memory m)
        internal
        returns (uint256 feedBps, uint256 mktBps, uint256 nextBps)
    {
        Snap memory c = _read(bC);
        Snap memory s = _read(bS);
        Snap memory t = _read(bT);
        Snap memory nx = _read(bNext);
        assertEq(s.ts, c.ts + 28 days, "S = C + 28d");
        assertEq(t.ts, s.ts + 3 days, "t = S + 3d");

        _deploy(c);

        // C: index created on target at the live answers, $1M issued.
        vm.warp(c.ts);
        _apply(c);
        uint256[] memory units = rule.initialUnits(tokens, CAPPED, 100e18);
        vm.prank(alice);
        index = IndexToken(factory.createIndex("Xindex", "XBCC", tokens, units, CAPPED));
        uint256[] memory need = index.previewIssue(10_000e18);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 7; ++i) {
            tok[i].mint(alice, need[i]);
            tok[i].approve(address(index), need[i]);
        }
        index.issue(10_000e18, alice);
        vm.stopPrank();

        // S: an unprivileged stranger snapshots.
        vm.warp(s.ts);
        _apply(s);
        vm.prank(stranger);
        index.startRebalance(0);

        // t = eta + 24h: the floor.
        vm.warp(t.ts);
        _apply(t);
        assertEq(index.currentMultiplier(), 0.9e18, "m = 0.9");

        uint256 outF;
        uint256 inF;
        (feedBps, outF, inF) = _takeBps();
        console2.log("traded value at the gate's answers, USD:", outF / WAD);
        console2.log("take at answers in force (gate), bps  :", feedBps);

        _logSnap(t, nx);
        // Control: the same fill valued at the market of that minute. The gate refuses it.
        _applyMarket(t, m);
        (mktBps,,) = _takeBps();
        console2.log("take at Coinbase close, bps           :", mktBps);
        // Precisely the gate's error.
        try executor.execute(index, "") {
            revert("control should revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IIndexToken.SettlementValueTooLow.selector, "refused by the DA-05 gate at market");
        }

        // Chainlink's own next reports (state after a block ~60 s later), same amounts, no exchange data involved.
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        vm.warp(nx.ts);
        _apply(nx);
        {
            (uint256 o2, uint256 i2) = rule.settlementValues(tokens, amountsOut, amountsIn);
            nextBps = (o2 - i2) * 10_000 / o2;
        }
        console2.log("take at Chainlink answers ~60s later  :", nextBps);

        // Back to t: at the answers actually in force the gate lets the fill through and it settles.
        vm.warp(t.ts);
        _apply(t);
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "settled at the lagging answers");
    }

    /// @dev 2026-02-01 23:07:59 UTC (block 24,365,193). Coinbase 1m close of the 23:07 candle.
    function test_verify_2026_02_01() public {
        Mkt memory m = Mkt({
            eth: 2240.16e8,
            btc: 76086e8,
            sol: 98.70e8,
            link: 9.316e8,
            uni: 3.785e8,
            aave: 122.48e8
        });
        (uint256 f, uint256 k, uint256 n) = _scenario(24142965, 24343697, 24365193, 24365198, m);
        assertLe(f, 1500, "gate passes at the answers in force");
        assertGt(k, 1500, "at market the lone executor keeps > 15% of what the index pays out");
        assertGt(n, 1500, "Chainlink's next reports agree");
    }

    /// @dev 2025-10-10 21:13:59 UTC (block 23,549,938). Coinbase 1m close of the 21:13 candle.
    function test_verify_2025_10_10() public {
        Mkt memory m = Mkt({
            eth: 3759.37e8,
            btc: 112021.2e8,
            sol: 186.45e8,
            link: 18.538e8,
            uni: 6.606e8,
            aave: 232.38e8
        });
        (uint256 f, uint256 k, uint256 n) = _scenario(23328159, 23528492, 23549938, 23549943, m);
        assertLe(f, 1500, "gate passes at the answers in force");
        assertGt(k, 1500, "at market the lone executor keeps > 15% of what the index pays out");
        console2.log("(next-report take logged only)", n);
    }
}
