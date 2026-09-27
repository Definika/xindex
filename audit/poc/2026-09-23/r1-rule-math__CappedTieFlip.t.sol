// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexRule} from "../../src/IndexRule.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";

/// @notice VR-01 is documented as having removed the rank-one step: "nothing at a tie, and at most 10 percentage
///         points where both constituents are already past the 20% cap, which takes a doubling of one against the
///         other to reach" (ARCHITECTURE.md section 5), and "a one-tick move no longer clears MIN_TURNOVER". That holds
///         only while the two largest caps sit at or under the 20% ceiling. On a top-heavy capped basket -- the shape
///         the capped methodology exists for -- two tied leaders are both past their ceilings, `_top` hands 30% to one
///         and 20% to the other, and a one-basis-point move that reorders them moves the full 10 points.
contract CappedTieFlipTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexRule rule;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");
    uint8 constant CAPPED = 1;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IndexRule(factory.RULE());
    }

    function _five(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    function test_weightsFromCaps_aTieBetweenTwoLeadersIsATenPointStep() public view {
        uint256[] memory w = rule.weightsFromCaps(_five(400e9, 400e9, 60e9, 50e9, 40e9), CAPPED);
        assertEq(w[0], 0.3e18, "tied: the lower position takes the 30% ceiling");
        assertEq(w[1], 0.2e18, "and the other the 20% one");
        uint256[] memory v = rule.weightsFromCaps(_five(400e9, 400e9 + 1, 60e9, 50e9, 40e9), CAPPED);
        assertEq(v[0], 0.2e18, "one wei of cap later the first has lost 10 points");
        assertEq(v[1], 0.3e18, "and the second has gained them");
        for (uint256 i = 2; i < 5; ++i) {
            assertEq(v[i], w[i]);
        }
    }

    function test_aBasisPointMoveOnATopHeavyCappedIndexStillClearsMinTurnover() public {
        // Five tokens at a dollar with reference supplies in the ratio 400 : 400 : 60 : 50 : 40 (two leaders tied).
        uint256[] memory parts = _five(400, 400, 60, 50, 40);
        address[] memory tokens = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens[i] = address(new MockERC20("T", "T", 18));
            IIndexFactory.TokenConfig memory c = market.configWith(tokens[i], 1e8, parts[i] * 1e27);
            vm.prank(owner);
            factory.proposeListing(tokens[i], c);
        }
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(tokens[i]);
        }

        uint256[] memory units = rule.initialUnits(tokens, CAPPED, 1_000e18);
        (uint256[] memory w,,) = rule.weights(tokens, CAPPED);
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.2e18);
        IndexToken idx = IndexToken(factory.createIndex("Top heavy", "TOP", tokens, units, CAPPED));
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());

        (, uint256 onRule) = idx.previewTarget(0);
        assertLt(onRule, idx.MIN_TURNOVER(), "on its methodology: nothing to rebalance");

        // The second leader's feed ticks up by one basis point.
        market.movePrice(tokens[1], 10_001, 10_000);
        (uint256[] memory t, uint256 turnover) = idx.previewTarget(0);
        emit log_named_uint("turnover after a 1bp move (1e18 = 100%)", turnover);
        assertGt(turnover, 0.099e18, "about 10% of the basket is put up for auction");
        assertApproxEqRel(t[0] * 3, units[0] * 2, 1e15, "the first leader is cut from 30% to 20%");
        assertApproxEqRel(t[1] * 2, units[1] * 3, 1e15, "the second raised from 20% to 30%");

        vm.prank(stranger);
        idx.startRebalance(0); // anyone
        (uint256 eta,,) = idx.pendingRebalance();
        assertGt(eta, 0);
    }
}
