// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexRule} from "../../src/IndexRule.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockRebalanceExecutor} from "../mocks/MockRebalanceExecutor.sol";

/// @notice Independent verification of "VR-01 fix is incomplete": ARCHITECTURE.md:533-537 and README.md:474-478 say a
///         crossing of the two largest capped caps moves weight "nothing at a tie, and at most 10 percentage points
///         where both constituents are already past the 20% cap, which takes a doubling of one against the other to
///         reach". The rule assigns the 30% ceiling by `_top` position, so wherever the tied leaders' effective weight
///         is above 20% the step at a tie is min(0.3, w_eff) - 0.2, not zero.
contract VerifyCappedTieFlipTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexRule rule;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");
    address alice = makeAddr("alice");
    uint8 constant CAPPED = 1;
    uint256 constant WAD = 1e18;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        rule = IndexRule(factory.RULE());
    }

    function _five(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    /// @dev Pure rule: three tie shapes. Only the flat one (the one VR-01's test covers) is step-free.
    function test_tieStepDependsOnShape() public {
        // (a) flat basket, both leaders at 20%: no step (what VR-01 tested)
        uint256[] memory w = rule.weightsFromCaps(_five(1e24, 1e24, 1e24, 1e24, 1e24), CAPPED);
        uint256[] memory v = rule.weightsFromCaps(_five(1e24, 1e24 + 1, 1e24, 1e24, 1e24), CAPPED);
        assertApproxEqAbs(v[0], w[0], 1);
        assertApproxEqAbs(v[1], w[1], 1);

        // (b) mildly top-heavy: two leaders at 10, three at 5 (natural 28.6% each). Full 10pp step at a tie.
        w = rule.weightsFromCaps(_five(10e18, 10e18, 5e18, 5e18, 5e18), CAPPED);
        v = rule.weightsFromCaps(_five(10e18, 10e18 + 1, 5e18, 5e18, 5e18), CAPPED);
        emit log_named_uint("10:10:5:5:5 tie   w0", w[0]);
        emit log_named_uint("10:10:5:5:5 +1wei w0", v[0]);
        assertEq(w[0], 0.3e18);
        assertEq(w[1], 0.2e18);
        assertEq(v[0], 0.2e18);
        assertEq(v[1], 0.3e18);

        // (c) intermediate: 25:25:20:15:15, leaders' effective weight 27.27%, step at the tie is ~7.27pp
        w = rule.weightsFromCaps(_five(25e18, 25e18, 20e18, 15e18, 15e18), CAPPED);
        v = rule.weightsFromCaps(_five(25e18, 25e18 + 1, 20e18, 15e18, 15e18), CAPPED);
        emit log_named_uint("25:25:20:15:15 tie   w0", w[0]);
        emit log_named_uint("25:25:20:15:15 +1wei w0", v[0]);
        assertApproxEqAbs(w[0] - v[0], 0.0727e18, 0.0001e18);

        // (d) the finding's own vector
        w = rule.weightsFromCaps(_five(400e9, 400e9, 60e9, 50e9, 40e9), CAPPED);
        v = rule.weightsFromCaps(_five(400e9, 400e9 + 1, 60e9, 50e9, 40e9), CAPPED);
        assertEq(w[0], 0.3e18);
        assertEq(v[0], 0.2e18);
        assertEq(v[1], 0.3e18);
    }

    /// @dev Docs: 10pp "takes a doubling of one against the other to reach". A 1.0001x ratio already does it.
    function test_tenPointsWithoutADoubling() public view {
        uint256[] memory lo = rule.weightsFromCaps(_five(10_000e18, 10_001e18, 5_000e18, 5_000e18, 5_000e18), CAPPED);
        uint256[] memory hi = rule.weightsFromCaps(_five(10_001e18, 10_000e18, 5_000e18, 5_000e18, 5_000e18), CAPPED);
        assertEq(hi[0] - lo[0], 0.1e18, "10pp moved across a 0.01% gap, not a 2x one");
    }

    function _listFive(uint256[] memory parts) internal returns (address[] memory tokens) {
        tokens = new address[](5);
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
    }

    function _nav(IndexToken idx, address[] memory tokens) internal view returns (uint256 nav) {
        (, uint256[] memory units) = idx.components();
        (, uint256[] memory prices,) = rule.weights(tokens, CAPPED);
        for (uint256 i = 0; i < units.length; ++i) {
            nav += units[i] * prices[i] / WAD;
        }
    }

    /// @dev End to end: on-methodology capped index with a mildly top-heavy tie (10:10:5:5:5). A 1bp tick certifies
    ///      ~10% turnover from a stranger, a lone end-of-auction executor keeps ~1% of NAV, and 28 days later a 2bp
    ///      tick the other way does it again.
    function test_endToEnd_flipChurnsTenPercentAndLeaksToALoneExecutor() public {
        address[] memory tokens = _listFive(_five(10, 10, 5, 5, 5));
        uint256[] memory units = rule.initialUnits(tokens, CAPPED, 1_000e18);
        IndexToken idx = IndexToken(factory.createIndex("Top heavy", "TOP", tokens, units, CAPPED));

        // alice holds 1,000 shares
        uint256 shares = 1_000e18;
        uint256[] memory need = idx.previewIssue(shares);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 5; ++i) {
            MockERC20(tokens[i]).mint(alice, need[i]);
            MockERC20(tokens[i]).approve(address(idx), need[i]);
        }
        idx.issue(shares, alice);
        vm.stopPrank();

        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        (, uint256 onRule) = idx.previewTarget(0);
        emit log_named_uint("turnover on methodology", onRule);
        assertLt(onRule, idx.MIN_TURNOVER());
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, onRule));
        vm.prank(stranger);
        idx.startRebalance(0);

        // one basis point on the second leader
        market.movePrice(tokens[1], 10_001, 10_000);
        (, uint256 turnover) = idx.previewTarget(0);
        emit log_named_uint("turnover after +1bp on leader 2", turnover);
        assertGt(turnover, 0.099e18);

        vm.prank(stranger);
        idx.startRebalance(0);
        (uint256 eta,,) = idx.pendingRebalance();

        // lone executor at the end of the auction
        uint256 navBefore = _nav(idx, tokens);
        vm.warp(eta + idx.AUCTION_DURATION());
        MockRebalanceExecutor exec = new MockRebalanceExecutor();
        exec.execute(IIndexToken(address(idx)), "");
        uint256 navAfter = _nav(idx, tokens);
        emit log_named_uint("NAV/share before (1e18=$1)", navBefore);
        emit log_named_uint("NAV/share after", navAfter);
        emit log_named_uint("NAV lost, bp", (navBefore - navAfter) * 10_000 / navBefore);
        assertGt((navBefore - navAfter) * 10_000 / navBefore, 90, "about 1% of NAV to the executor");

        // 28 days later: what turnover would be with no further move (auction residue only)
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL() + idx.REBALANCE_DELAY() + 1);
        (, uint256 residue) = idx.previewTarget(0);
        emit log_named_uint("turnover next period, no move", residue);

        // leader 2 ticks back 2bp: leader 1 is on top again
        market.movePrice(tokens[1], 9_998, 10_000);
        (, uint256 back) = idx.previewTarget(0);
        emit log_named_uint("turnover after flip back", back);
        assertGt(back, 0.09e18);
        vm.prank(stranger);
        idx.startRebalance(0);
    }
}
