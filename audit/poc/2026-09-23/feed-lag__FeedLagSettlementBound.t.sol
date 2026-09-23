// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {MainnetAddresses as A} from "../../script/MainnetAddresses.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice DA-05's settlement gate values both legs at the Chainlink answers in force in the settling block and requires
///         inValue >= 0.85 * outValue. README ("Known limitations") says this makes "the worst case ... 15% of the traded
///         value", and ARCHITECTURE section 4 says the 5% allowance is "more conservative" against feeds with "a 0.5-2%
///         deviation threshold plus heartbeat lag". Both assume a published answer sits within its deviation threshold
///         of the market. Measured over 2024-07..2026-09 it does not: the wstETH/USD "Calculated" feed is driven by the
///         1%-threshold stETH/USD feed and sits >0.5% from ETH x stEthPerToken 20% of the time, SOL/USD answers stay
///         2-10% off the market for minutes, and in fast moves every feed lags by more than its threshold.
///
///         Each test replays, with vm.mockCall, the exact latestRoundData tuples every shipped proxy returned at three
///         real moments (index on target at C, permissionless snapshot at S = C + 28d, fill at t = S + 3d, i.e. exactly
///         m = 0.9), for the default 7-token CAPPED basket of `ConfigureWhitelist.defaultMainnetList` with its real
///         configs (feeds, maxStaleness, reference supplies, wstETH's on-chain supply), with the WBTC price coming from
///         a real `CompositeFeed`. The settlement passes `_checkSettlementValue`, yet at market prices at the same
///         minute the executor keeps more than 15% of what the index pays out. Market prices are taken leg by leg in the
///         direction least favourable to this claim (lower of Binance/Coinbase for what the index pays out, higher for
///         what it receives; wstETH at ETH x stEthPerToken at par for what it receives, WBTC at par for what it receives).
///         The fill is also valued at Chainlink's own answers five minutes later, which confirms the answers the gate
///         read were stale, without any exchange data.
///
///         Round tuples: proxy getRoundData on mainnet, cross-checked with archive latestRoundData at block 24,365,193
///         (2026-02-01 23:07:59 UTC). Data and scripts: scratchpad/feed-lag/.
contract FeedLagSettlementBoundPoC is Test {
    struct Round {
        uint80 id;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    /// @dev One snapshot of all eight proxies, in the order ETH, wstETH, BTC, WBTC/BTC, SOL, LINK, UNI, AAVE.
    struct Moment {
        Round[8] r;
    }

    /// @dev USD per whole token, 1e18-scaled.
    struct Market {
        uint256 ethLo;
        uint256 ethHi;
        uint256 btcLo;
        uint256 btcHi;
        uint256 solLo;
        uint256 solHi;
        uint256 linkLo;
        uint256 linkHi;
        uint256 uniLo;
        uint256 uniHi;
        uint256 aaveLo;
        uint256 aaveHi;
        uint256 wbtcBtcLo; // lower of Binance WBTCBTC last trade and the WBTC/BTC answer
        uint256 wbtcBtcHi; // higher of Binance WBTCBTC last trade and par
        uint256 stEthPerToken; // wstETH.stEthPerToken() at the settling block
        uint256 curveStEth; // Curve stETH->ETH get_dy(1e18), used only for what the index pays out
    }

    uint8 constant CAPPED = 1;
    uint256 constant WAD = 1e18;

    IndexFactory factory;
    IIndexRule rule;
    MockRebalanceExecutor executor;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");
    address world = makeAddr("restOfTheWstEthSupply");

    MockERC20[7] tok; // WETH, wstETH, WBTC, wSOL, LINK, UNI, AAVE (defaultMainnetList order)
    address[] tokens;
    TestAggregator[8] feed; // ETH, wstETH, BTC, WBTC/BTC, SOL, LINK, UNI, AAVE
    CompositeFeed wbtcFeed;

    function _deploy(Moment memory created) internal {
        factory = new IndexFactory(owner, guardian);
        rule = IIndexRule(factory.RULE());
        executor = new MockRebalanceExecutor();
        string[8] memory names =
            ["ETH / USD", "wstETH / USD Calculated", "BTC / USD", "WBTC / BTC", "SOL / USD", "LINK / USD", "UNI / USD", "AAVE / USD"];
        for (uint256 i = 0; i < 8; ++i) {
            feed[i] = new TestAggregator(names[i], 8, created.r[i].answer);
        }
        wbtcFeed = new CompositeFeed(
            IAggregatorV3(address(feed[2])), IAggregatorV3(address(feed[3])), A.STALENESS_1H, A.STALENESS_24H
        );
        tok[0] = new MockERC20("Wrapped Ether", "WETH", 18);
        tok[1] = new MockERC20("Wrapped liquid staked Ether 2.0", "wstETH", 18);
        tok[2] = new MockERC20("Wrapped BTC", "WBTC", 8);
        tok[3] = new MockERC20("SOL (Wormhole)", "SOL", 9);
        tok[4] = new MockERC20("ChainLink Token", "LINK", 18);
        tok[5] = new MockERC20("Uniswap", "UNI", 18);
        tok[6] = new MockERC20("Aave Token", "AAVE", 18);
        for (uint256 i = 0; i < 7; ++i) {
            tokens.push(address(tok[i]));
        }
        tok[1].mint(world, 1e24); // any nonzero supply for the listing check; set exactly before every read below

        // The configs of ConfigureWhitelist.defaultMainnetList, feed for feed.
        IIndexFactory.TokenConfig[7] memory c;
        c[0] = IIndexFactory.TokenConfig(address(feed[0]), A.STALENESS_1H, A.ETH_SUPPLY);
        c[1] = IIndexFactory.TokenConfig(address(feed[1]), A.STALENESS_24H, A.WSTETH_SUPPLY);
        c[2] = IIndexFactory.TokenConfig(address(wbtcFeed), A.STALENESS_24H, A.BTC_SUPPLY);
        c[3] = IIndexFactory.TokenConfig(address(feed[4]), A.STALENESS_24H, A.SOL_SUPPLY);
        c[4] = IIndexFactory.TokenConfig(address(feed[5]), A.STALENESS_1H, A.LINK_SUPPLY);
        c[5] = IIndexFactory.TokenConfig(address(feed[6]), A.STALENESS_1H, A.UNI_SUPPLY);
        c[6] = IIndexFactory.TokenConfig(address(feed[7]), A.STALENESS_1H, A.AAVE_SUPPLY);
        vm.startPrank(owner);
        for (uint256 i = 0; i < 7; ++i) {
            factory.proposeListing(tokens[i], c[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 7; ++i) {
            factory.executeListing(tokens[i]);
        }
    }

    /// @dev Every proxy answers exactly what mainnet answered at that moment.
    function _replay(Moment memory m) internal {
        for (uint256 i = 0; i < 8; ++i) {
            Round memory r = m.r[i];
            vm.mockCall(
                address(feed[i]),
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(r.id, r.answer, r.startedAt, r.updatedAt, r.id)
            );
        }
    }

    /// @dev wstETH is listed with WSTETH_SUPPLY = 0, so the rule reads its live totalSupply.
    function _setWstEthSupply(uint256 target) internal {
        uint256 total = tok[1].totalSupply();
        uint256 held = tok[1].balanceOf(world);
        if (total > target) tok[1].burn(world, total - target > held ? held : total - target);
        else tok[1].mint(world, target - total);
        assertEq(tok[1].totalSupply(), target, "wstETH supply replayed");
    }

    function _issue(IndexToken idx, uint256 shares) internal {
        uint256[] memory need = idx.previewIssue(shares);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 7; ++i) {
            tok[i].mint(alice, need[i]);
            tok[i].approve(address(idx), need[i]);
        }
        idx.issue(shares, alice);
        vm.stopPrank();
    }

    function _mktValue(uint256[] memory amounts, Market memory p, bool paidOut) internal view returns (uint256 v) {
        // What the index pays out is valued low, what it receives is valued high: both against the claim.
        uint256 eth = paidOut ? p.ethLo : p.ethHi;
        uint256[7] memory px;
        px[0] = eth;
        px[1] = paidOut ? eth * p.stEthPerToken / WAD * p.curveStEth / WAD : eth * p.stEthPerToken / WAD;
        px[2] = paidOut ? p.btcLo * p.wbtcBtcLo / WAD : p.btcHi * p.wbtcBtcHi / WAD;
        px[3] = paidOut ? p.solLo : p.solHi;
        px[4] = paidOut ? p.linkLo : p.linkHi;
        px[5] = paidOut ? p.uniLo : p.uniHi;
        px[6] = paidOut ? p.aaveLo : p.aaveHi;
        for (uint256 i = 0; i < 7; ++i) {
            v += amounts[i] * px[i] / 10 ** tok[i].decimals();
        }
    }

    struct Scenario {
        uint256 C;
        Moment atC;
        uint256 supplyC;
        Moment atS;
        uint256 supplyS;
        Moment atT;
        uint256 supplyT;
        Moment atT5;
        Market mkt;
    }

    struct Outcome {
        uint256 outFeed;
        uint256 inFeed;
        uint256 outMkt;
        uint256 inMkt;
        uint256 outLater;
        uint256 inLater;
        uint256 takeFeedBps;
        uint256 takeMktBps;
        uint256 takeLaterFeedBps;
    }

    IndexToken index;

    function _setupAndSnapshot(Scenario memory sc) internal {
        vm.warp(sc.C - 8 days);
        _deploy(sc.atC);

        // C: the index is on target at the rule's own prices (as after a previous rebalance).
        vm.warp(sc.C);
        _replay(sc.atC);
        _setWstEthSupply(sc.supplyC);
        uint256[] memory units = rule.initialUnits(tokens, CAPPED, 100e18);
        vm.prank(alice);
        index = IndexToken(factory.createIndex("Xindex Blue Chip Capped", "XBCC", tokens, units, CAPPED));
        _issue(index, 10_000e18); // a million dollars of index

        // S = C + 28d: anyone may snapshot.
        uint256 S = sc.C + index.MIN_REBALANCE_INTERVAL();
        vm.warp(S);
        _replay(sc.atS);
        _setWstEthSupply(sc.supplyS);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        assertEq(eta, S + 2 days);

        // t = eta + 24h: the auction floor, m = 0.9 exactly.
        vm.warp(eta + index.AUCTION_DURATION());
        _replay(sc.atT);
        _setWstEthSupply(sc.supplyT);
        assertEq(index.currentMultiplier(), 0.9e18, "the lone executor waited for the floor");
    }

    function _run(Scenario memory sc) internal returns (Outcome memory o) {
        _setupAndSnapshot(sc);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        (o.outFeed, o.inFeed) = rule.settlementValues(tokens, amountsOut, amountsIn);
        assertGe(o.inFeed * WAD, o.outFeed * index.MIN_SETTLEMENT_RATIO(), "DA-05 gate passes at the answers in force");
        o.takeFeedBps = (o.outFeed - o.inFeed) * 10_000 / o.outFeed;

        o.outMkt = _mktValue(amountsOut, sc.mkt, true);
        o.inMkt = _mktValue(amountsIn, sc.mkt, false);
        o.takeMktBps = (o.outMkt - o.inMkt) * 10_000 / o.outMkt;

        // The same fill valued at Chainlink's own answers five minutes later: no exchange data at all. (A view only;
        // the clock goes back to t for the settlement.)
        uint256 t = block.timestamp;
        vm.warp(t + 5 minutes);
        _replay(sc.atT5);
        (o.outLater, o.inLater) = rule.settlementValues(tokens, amountsOut, amountsIn);
        o.takeLaterFeedBps = (o.outLater - o.inLater) * 10_000 / o.outLater;
        vm.warp(t);
        _replay(sc.atT);

        // The settlement itself succeeds, at the answers in force.
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "settled");
        _backed();
        _log(o, amountsOut, amountsIn);
    }

    function _backed() internal view {
        (address[] memory t, uint256[] memory u) = index.components();
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            assertGe(MockERC20(t[i]).balanceOf(address(index)), supply * u[i] / WAD, "backed");
        }
    }

    function _log(Outcome memory o, uint256[] memory amountsOut, uint256[] memory amountsIn) internal view {
        console2.log("traded value at the gate's feeds (USD):", o.outFeed / WAD);
        console2.log("take at the gate's feeds, bps          :", o.takeFeedBps);
        console2.log("take at market (conservative), bps     :", o.takeMktBps);
        console2.log("take at Chainlink answers +5 min, bps  :", o.takeLaterFeedBps);
        console2.log("market value out / in (USD)            :", o.outMkt / WAD, o.inMkt / WAD);
        for (uint256 i = 0; i < 7; ++i) {
            if (amountsOut[i] != 0) console2.log("  sold  ", tok[i].symbol(), amountsOut[i]);
            if (amountsIn[i] != 0) console2.log("  bought", tok[i].symbol(), amountsIn[i]);
        }
    }

    function _r(uint256 id, int256 answer, uint256 startedAt, uint256 updatedAt) internal pure returns (Round memory) {
        return Round(uint80(id), answer, startedAt, updatedAt);
    }

    /// @dev 2026-02-01 23:08:00 UTC. The SOL/USD answer the gate reads is 10,453 s old and 2.6% above the market
    ///      (threshold 2%); the wstETH/USD answer is 205 s old and 2.4% above ETH x stEthPerToken (threshold 0.5%).
    ///      Both next answers (23:08:47) moved down to the market. The index is buying wstETH and wSOL.
    function test_poc_2026_02_01_calmLag_takeAbove15pct_atM090() public {
        Moment memory atC;
        atC.r[0] = _r(129127208515966884310, 298925630000, 1767305295, 1767305315);
        atC.r[1] = _r(18446744073709558037, 366171364570, 1767308432, 1767308447);
        atC.r[2] = _r(129127208515966877065, 8845230200000, 1767306811, 1767306827);
        atC.r[3] = _r(36893488147419103773, 99792140, 1767223990, 1767224003);
        atC.r[4] = _r(36893488147419105754, 12550655457, 1767298892, 1767298907);
        atC.r[5] = _r(129127208515966881951, 1255672469, 1767307954, 1767307967);
        atC.r[6] = _r(129127208515966878446, 578729283, 1767307772, 1767307787);
        atC.r[7] = _r(92233720368547775042, 14900750000, 1767308808, 1767308819);
        Moment memory atS;
        atS.r[0] = _r(129127208515966885321, 281165250000, 1769725987, 1769726003);
        atS.r[1] = _r(18446744073709558248, 344554581599, 1769722364, 1769722379);
        atS.r[2] = _r(129127208515966877887, 8428657489247, 1769725223, 1769725247);
        atS.r[3] = _r(36893488147419103802, 99805257, 1769643846, 1769643863);
        atS.r[4] = _r(36893488147419105821, 11533200000, 1769712753, 1769712839);
        atS.r[5] = _r(129127208515966883109, 1109464000, 1769726953, 1769726975);
        atS.r[6] = _r(129127208515966879261, 438108522, 1769727323, 1769727335);
        atS.r[7] = _r(92233720368547775828, 14718000000, 1769724595, 1769724611);
        Moment memory atT;
        atT.r[0] = _r(129127208515966885606, 225892000000, 1769987214, 1769987231);
        atT.r[1] = _r(18446744073709558336, 281316326694, 1769987054, 1769987075);
        atT.r[2] = _r(129127208515966878054, 7610761390887, 1769987231, 1769987255);
        atT.r[3] = _r(36893488147419103805, 99694000, 1769903103, 1769903123);
        atT.r[4] = _r(36893488147419105846, 10137700000, 1769976808, 1769976827);
        atT.r[5] = _r(129127208515966883375, 933876687, 1769987205, 1769987255);
        atT.r[6] = _r(129127208515966879393, 379824510, 1769987201, 1769987255);
        atT.r[7] = _r(92233720368547775954, 12304423983, 1769987207, 1769987255);
        Moment memory atT5;
        atT5.r[0] = _r(129127208515966885609, 224455720780, 1769987544, 1769987579);
        atT5.r[1] = _r(18446744073709558338, 274105738884, 1769987354, 1769987387);
        atT5.r[2] = _r(129127208515966878056, 7628247077340, 1769987562, 1769987579);
        atT5.r[3] = _r(36893488147419103805, 99694000, 1769903103, 1769903123);
        atT5.r[4] = _r(36893488147419105847, 9898731000, 1769987252, 1769987327);
        atT5.r[5] = _r(129127208515966883378, 931254996, 1769987565, 1769987579);
        atT5.r[6] = _r(129127208515966879395, 379880214, 1769987561, 1769987579);
        atT5.r[7] = _r(92233720368547775955, 12176334000, 1769987387, 1769987483);
        // Binance 1m close (USDT / USDCUSDT 1.0007) and Coinbase 1m close of the minute ending 23:08:00.
        Market memory mkt = Market({
            ethLo: 2240.16e18,
            ethHi: 2240.691516e18,
            btcLo: 76086e18,
            btcHi: 76106.235635e18,
            solLo: 98.7e18,
            solHi: 98.720895e18,
            linkLo: 9.313481e18,
            linkHi: 9.316e18,
            uniLo: 3.785e18,
            uniHi: 3.787349e18,
            aaveLo: 122.48e18,
            aaveHi: 122.484261e18,
            wbtcBtcLo: 0.9966e18,
            wbtcBtcHi: 1e18,
            stEthPerToken: 1225924500588614505,
            curveStEth: 999334255160074468
        });
        // wstETH.totalSupply() at the blocks of C, S and t.
        Outcome memory o = _run(
            Scenario(
                1769987280 - 31 days,
                atC,
                3192886700027334202149082,
                atS,
                3516810215704475530189990,
                atT,
                3587271963126225638126419,
                atT5,
                mkt
            )
        );
        assertLe(o.takeFeedBps, 1500, "the gate held the take to 15% at its own prices");
        assertGt(o.takeMktBps, 1500, "at market the lone executor kept more than 15% of what the index paid out");
        assertGt(o.takeLaterFeedBps, 1500, "and so do Chainlink's own answers five minutes later");
    }

    /// @dev 2025-10-10 21:14:00 UTC, as the crash starts. The AAVE/USD answer is 109 s old and 5.3% above the market
    ///      (threshold 1%), LINK/USD 2.3% above (0.5%), wstETH/USD 2.6% above (0.5%); the index is buying all three.
    function test_poc_2025_10_10_crash_takeAbove15pct_atM090() public {
        Moment memory atC;
        atC.r[0] = _r(129127208515966878987, 430937300727, 1757452159, 1757452175);
        atC.r[1] = _r(18446744073709556628, 519517121581, 1757432035, 1757432051);
        atC.r[2] = _r(129127208515966873346, 11119148463253, 1757449932, 1757449955);
        atC.r[3] = _r(36893488147419103657, 100016910, 1757369812, 1757369831);
        atC.r[4] = _r(36893488147419105307, 21625269609, 1757398301, 1757398319);
        atC.r[5] = _r(129127208515966874824, 2312298169, 1757451962, 1757451983);
        atC.r[6] = _r(129127208515966874399, 944939540, 1757450399, 1757450423);
        atC.r[7] = _r(92233720368547771344, 29782265264, 1757450289, 1757450303);
        Moment memory atS;
        atS.r[0] = _r(129127208515966879965, 451210432491, 1759871300, 1759871315);
        atS.r[1] = _r(18446744073709556848, 548262512139, 1759869823, 1759869839);
        atS.r[2] = _r(129127208515966874089, 12223266199800, 1759870334, 1759870355);
        atS.r[3] = _r(36893488147419103685, 100000000, 1759789727, 1759789739);
        atS.r[4] = _r(36893488147419105380, 22160300000, 1759849664, 1759849691);
        atS.r[5] = _r(129127208515966876066, 2209190000, 1759868915, 1759868999);
        atS.r[6] = _r(129127208515966875168, 783062997, 1759869471, 1759869491);
        atS.r[7] = _r(92233720368547772100, 27860952237, 1759869647, 1759869671);
        Moment memory atT;
        atT.r[0] = _r(129127208515966880105, 371605660742, 1760130809, 1760130827);
        atT.r[1] = _r(18446744073709556890, 469168999118, 1760130761, 1760130815);
        atT.r[2] = _r(129127208515966874198, 11030848000000, 1760130813, 1760130827);
        atT.r[3] = _r(36893488147419103688, 100008385, 1760048979, 1760048999);
        atT.r[4] = _r(36893488147419105396, 18578658000, 1760130798, 1760130815);
        atT.r[5] = _r(129127208515966876249, 1890243000, 1760130786, 1760130815);
        atT.r[6] = _r(129127208515966875276, 645164188, 1760130814, 1760130839);
        atT.r[7] = _r(92233720368547772191, 24568720000, 1760130695, 1760130731);
        Moment memory atT5;
        atT5.r[0] = _r(129127208515966880112, 359458652200, 1760131109, 1760131127);
        atT5.r[1] = _r(18446744073709556893, 458361281363, 1760131001, 1760131067);
        atT5.r[2] = _r(129127208515966874202, 10895249053896, 1760131074, 1760131091);
        atT5.r[3] = _r(36893488147419103688, 100008385, 1760048979, 1760048999);
        atT5.r[4] = _r(36893488147419105397, 18117400000, 1760130978, 1760130995);
        atT5.r[5] = _r(129127208515966876255, 1613086725, 1760131026, 1760131067);
        atT5.r[6] = _r(129127208515966875282, 500147542, 1760131114, 1760131127);
        atT5.r[7] = _r(92233720368547772198, 19261208895, 1760131055, 1760131127);
        // Binance 1m close (USDT / USDCUSDT 0.9997) and Coinbase 1m close of the minute ending 21:14:00.
        Market memory mkt = Market({
            ethLo: 3758.437531e18,
            ethHi: 3759.37e18,
            btcLo: 111991.917575e18,
            btcHi: 112021.2e18,
            solLo: 186.305892e18,
            solHi: 186.45e18,
            linkLo: 18.46554e18,
            linkHi: 18.538e18,
            uniLo: 6.603981e18,
            uniHi: 6.606e18,
            aaveLo: 232.38e18,
            aaveHi: 232.769831e18,
            wbtcBtcLo: 1.00008385e18,
            wbtcBtcHi: 1.0014e18,
            stEthPerToken: 1215988905330978494,
            curveStEth: 999666111799272136
        });
        Outcome memory o = _run(
            Scenario(
                1760130840 - 31 days,
                atC,
                3137651402134778016828522,
                atS,
                3243198240760606639227923,
                atT,
                3223429944231121119318455,
                atT5,
                mkt
            )
        );
        assertLe(o.takeFeedBps, 1500, "the gate held the take to 15% at its own prices");
        assertGt(o.takeMktBps, 1500, "at market the lone executor kept more than 15% of what the index paid out");
        assertGt(o.takeLaterFeedBps, 1500, "and so do Chainlink's own answers five minutes later");
    }
}
