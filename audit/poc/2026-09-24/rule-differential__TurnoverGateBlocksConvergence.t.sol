// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexRule} from "../../src/IndexRule.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice rule-differential finding: `MIN_TURNOVER` is measured on the band-clipped step the rule proposes, not on how
///         far the index sits from its rule. A component whose holding is below 0.5% of the index can at most double
///         per rebalance, so the step it asks for is worth less than 0.5% of the index, and `startRebalance` reverts
///         `TurnoverTooLow` however large that component's rule weight is. Under the uncapped methodology an index's
///         holdings and weights both move with price, so no market move creates other turnover to carry the step:
///         the index stays off its rule until that one component outperforms the rest of the basket by the factor
///         0.5% / holding. Nobody can start the rebalance, the owner and guardian included (a keep mask changes the
///         basket traded, it does not lower the gate).
///
///         Found by the python exact reference (redteam-diff/iterate.py): applying the contract's own targets at fixed
///         prices, some baskets start below the gate while the reference's unclipped distance to the rule is large.
///
///         Two reachable ways into that state, both through the real listing flow and the real factory:
///           1. the owner corrects a first listing's reference supply upward by the one 10x step MAX_SUPPLY_CHANGE
///              allows (the documented recourse for a decimals slip, DA-18), after uncapped indexes were created;
///           2. a creator picks its own starting units, which ARCHITECTURE.md section 3 says "also work; the first
///              rebalances then move them toward the rule".
contract TurnoverGateBlocksConvergence is Test {
    MockMarket market;
    IndexFactory factory;
    IndexRule rule;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address stranger = makeAddr("stranger");

    uint8 constant UNCAPPED = 0;
    uint256 constant WAD = 1e18;

    // launch list: WETH, wstETH, WBTC, wSOL, LINK, UNI, AAVE (decimals 18, 18, 8, 9, 18, 18, 18)
    address[] tokens;
    int256[7] usd8 = [int256(4000e8), 4800e8, 110_000e8, 200e8, 20e8, 10e8, 300e8];
    uint8[7] decs = [18, 18, 8, 9, 18, 18, 18];
    // script/MainnetAddresses.sol reference supplies
    uint256[7] supplies = [
        uint256(122_070_499e18),
        3_715_183e18,
        20_087_871e8,
        587_507_739e9,
        748_099_970e18,
        620_716_422e18,
        15_428_841e18
    ];
    uint256 constant SOL = 3;
    uint256 constant BTC = 2;

    function setUp() public {
        vm.warp(1_800_000_000);
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IndexRule(factory.RULE());
        string[7] memory names = ["WETH", "wstETH", "WBTC", "SOL", "LINK", "UNI", "AAVE"];
        for (uint256 i = 0; i < 7; ++i) {
            tokens.push(address(new MockERC20(names[i], names[i], decs[i])));
        }
    }

    // ------------------------------------------------------------------ helpers

    function _propose(address token, uint256 supply, bool listing) internal {
        uint256 i = _idx(token);
        IIndexFactory.TokenConfig memory c = market.configWith(token, usd8[i], supply); // computed before the prank
        vm.prank(owner);
        if (listing) factory.proposeListing(token, c);
        else factory.proposeConfig(token, c);
    }

    function _idx(address token) internal view returns (uint256) {
        for (uint256 i = 0; i < 7; ++i) {
            if (tokens[i] == token) return i;
        }
        revert("unknown");
    }

    function _listAll(uint256 solSupply) internal {
        for (uint256 i = 0; i < 7; ++i) {
            _propose(tokens[i], i == SOL ? solSupply : supplies[i], true);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 7; ++i) {
            factory.executeListing(tokens[i]);
        }
    }

    function _create(uint256[] memory units) internal returns (IndexToken index) {
        vm.prank(creator);
        index = IndexToken(factory.createIndex("Xindex Market Cap 7", "XMC7", tokens, units, UNCAPPED));
        // a holder buys 1,000 index tokens in kind
        uint256[] memory need = index.previewIssue(1000e18);
        for (uint256 i = 0; i < 7; ++i) {
            MockERC20(tokens[i]).mint(creator, need[i]);
            vm.prank(creator);
            MockERC20(tokens[i]).approve(address(index), need[i]);
        }
        vm.prank(creator);
        index.issue(1000e18, creator);
    }

    /// @dev Holding share of component `k` in the index at current feed prices (1e18 = 100%).
    function _holding(IndexToken index, uint256 k) internal view returns (uint256) {
        (, uint256[] memory units) = index.components();
        uint256 total = 0;
        uint256 mine = 0;
        for (uint256 i = 0; i < 7; ++i) {
            uint256 v = units[i] * rule.price(tokens[i]);
            total += v;
            if (i == k) mine = v;
        }
        return mine * WAD / total;
    }

    function _weight(uint256 k) internal view returns (uint256) {
        (uint256[] memory w,,) = rule.weights(tokens, UNCAPPED);
        return w[k];
    }

    function _assertNobodyCanRebalance(IndexToken index) internal {
        (, uint256 turnover) = index.previewTarget(0);
        assertLt(turnover, index.MIN_TURNOVER(), "the step the rule proposes is under the gate");
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, turnover));
        vm.prank(stranger);
        index.startRebalance(0);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, turnover));
        vm.prank(guardian);
        index.startRebalance(0);
    }

    // ------------------------------------------------------------------ path 1: owner's supply correction

    function test_supplyCorrectionLeavesUncappedIndexOffItsRule() public {
        // wSOL's first listing carries the documented decimals slip: its supply written with 8 decimals, not 9, so
        // 10x too low. The first config is unbounded, and checkConfig accepts any non-zero supply.
        _listAll(587_507_739e8);

        // An uncapped index is created on its rule at $1,000 with initialUnits, the documented create flow.
        IndexToken index = _create(rule.initialUnits(tokens, UNCAPPED, 1000e18));
        uint256 h0 = _holding(index, SOL);
        assertApproxEqRel(h0, _weight(SOL), 1e12, "created on its rule: SOL's holding equals its (mistaken) weight");

        // The owner corrects the slip in the one 10x step MAX_SUPPLY_CHANGE allows (DA-18's recourse), through the
        // listing delay and the guardian's veto. SOL's rule weight goes up about tenfold; its holding does not move.
        _propose(tokens[SOL], supplies[SOL], false);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(tokens[SOL]);

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        uint256 w = _weight(SOL);
        uint256 h = _holding(index, SOL);
        console2.log("SOL rule weight (bp)", w * 10_000 / WAD);
        console2.log("SOL holding     (bp)", h * 10_000 / WAD);
        assertGt(w, 390 * WAD / 10_000, "the rule wants about 4% SOL");
        assertLt(h, 45 * WAD / 10_000, "the index holds about 0.4%");
        // The shortfall, as a share of the index, is more than seven times the gate itself ...
        assertGt(w - h, 7 * index.MIN_TURNOVER(), "the index is off its rule by >3.5% of its value");
        // ... and the rule knows it: SOL's target is its band ceiling (double), the step is clipped.
        (uint256[] memory targets, uint256 turnover) = index.previewTarget(0);
        (, uint256[] memory units) = index.components();
        assertEq(targets[SOL], 2 * units[SOL], "SOL is clipped at double: the rule wants more than one step");
        console2.log("turnover of the clipped step (bp)", turnover * 10_000 / WAD);
        // But the gate is measured on the clipped step, which is worth only SOL's own holding: nobody can start it.
        _assertNobodyCanRebalance(index);

        // Uncapped holdings and weights both move with price, so the market never supplies other turnover to carry the
        // step. Twelve months of large moves, with SOL keeping pace with bitcoin (which is most of the basket):
        int256[7] memory move = [int256(140), 70, 125, 125, 60, 150, 80];
        for (uint256 month = 0; month < 12; ++month) {
            for (uint256 i = 0; i < 7; ++i) {
                int256 m = month % 2 == 0 ? move[i] : int256(10_000) / move[i];
                usd8[i] = usd8[i] * m / 100;
                market.setPrice(tokens[i], usd8[i]);
            }
            vm.warp(block.timestamp + 30 days);
            _assertNobodyCanRebalance(index);
        }
        // A year later the index is still ~10x short of SOL, by more than 3.5% of its value.
        assertGt(_weight(SOL) - _holding(index, SOL), 7 * index.MIN_TURNOVER(), "still off its rule a year later");

        // The gate's verdict depends on the denominator, not on the deviation: the very same SOL doubling clears it
        // once the guardian keeps WBTC out, because activeValue then drops to the ~23% of the index that is not WBTC.
        // That is the only way out, and it is a manual, guardian-only lever that has to be pulled every month.
        (uint256[] memory kt, uint256 keptTurnover) = index.previewTarget(1 << BTC);
        (, uint256[] memory u2) = index.components();
        assertEq(kt[SOL], 2 * u2[SOL], "the same step: SOL doubles");
        assertGe(keptTurnover, index.MIN_TURNOVER(), "and now it clears the gate");
        vm.prank(guardian);
        index.startRebalance(1 << BTC);
    }

    // ------------------------------------------------------------------ path 2: creator-chosen units

    function test_creatorChosenUnitsNeverConvergeToTheUncappedRule() public {
        _listAll(supplies[SOL]);
        // A creator picks its own units (allowed; ARCHITECTURE section 3: "Creator-chosen units also work; the first
        // rebalances then move them toward the rule"). It takes initialUnits at $10,000 a token and cuts WBTC to
        // 1/2000 of it (still 3,500 raw units, well clear of the coarse regime): the index is registered as "uncapped
        // market cap", and WBTC is ~77% of that rule.
        uint256[] memory units = rule.initialUnits(tokens, UNCAPPED, 10_000e18);
        units[BTC] = units[BTC] / 2000;
        IndexToken index = _create(units);

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        uint256 w = _weight(BTC);
        uint256 h = _holding(index, BTC);
        console2.log("WBTC rule weight (bp)", w * 10_000 / WAD);
        console2.log("WBTC holding     (bp)", h * 10_000 / WAD);
        assertGt(w, 7000 * WAD / 10_000, "the committed rule is ~77% WBTC");
        assertLt(h, 20 * WAD / 10_000, "the index holds under 0.2% WBTC");
        (uint256[] memory targets,) = index.previewTarget(0);
        (, uint256[] memory cur) = index.components();
        assertEq(targets[BTC], 2 * cur[BTC], "WBTC would be doubled if the rebalance could start");
        // The first rebalance never happens: the clipped step is worth WBTC's own holding, so the gate opens only once
        // that holding passes 0.5%, which takes WBTC outperforming the rest of the basket about threefold.
        _assertNobodyCanRebalance(index);
        for (uint256 month = 0; month < 12; ++month) {
            // everything moves together, or the altcoins rally against bitcoin: neither opens the gate
            for (uint256 i = 0; i < 7; ++i) {
                int256 m = i == BTC ? int256(100) : int256(105);
                usd8[i] = usd8[i] * m / 100;
                market.setPrice(tokens[i], usd8[i]);
            }
            vm.warp(block.timestamp + 30 days);
            _assertNobodyCanRebalance(index);
        }
        // (the altcoin rally took WBTC's rule weight from ~77% to ~65%; the index still holds ~0.1%)
        assertGt(_weight(BTC) - _holding(index, BTC), 6000 * WAD / 10_000, "a year on, still ~0% WBTC vs ~65%");
    }
}
