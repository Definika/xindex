// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice The quote the owner or guardian may post with a start: prices of their own, fixed at the start, which a
///         fill of that proposal must also meet. The index reads no price; a quote can only refuse a fill the bar
///         accepts, and it ends with its proposal.
contract WeightedHubQuoteTest is WeightedTest {
    uint256 constant SHARES = 100e18;
    /// @dev Half a percent: how far under the quoted value a fill may bring in.
    uint256 constant TOLERANCE = 0.005e18;

    WeightedHub index;
    MockWeightedExecutor executor;

    function setUp() public {
        _deploy();
        _listAll();
        index = _create(_defaultSpecs());
        _issue(index, alice, SHARES);
        executor = new MockWeightedExecutor();
    }

    /// @dev The guardian starts a rebalance with `prices` and `tolerance` once the interval has passed, and the clock
    ///      moves `into` seconds into its auction.
    function _openQuoted(uint256 keepMask, uint256[] memory prices, uint256 tolerance, uint256 into) internal {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(guardian);
        index.startRebalance(keepMask, prices, tolerance);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + into);
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory u) {
        u = new uint256[](3);
        (u[0], u[1], u[2]) = (a, b, c);
    }

    /// @dev What a fill from `units` to `next` takes out and brings in, at `prices`.
    function _values(uint256[] memory units, uint256[] memory next, uint256[] memory prices)
        internal
        pure
        returns (uint256 valueOut, uint256 valueIn)
    {
        for (uint256 i = 0; i < units.length; ++i) {
            if (next[i] < units[i]) valueOut += (units[i] - next[i]) * prices[i];
            else valueIn += (next[i] - units[i]) * prices[i];
        }
    }

    /// @dev The market with ETH a quarter up, which leaves the default index 0.62% from its weights.
    function _moved() internal pure returns (uint256[] memory) {
        return _market(2500, BTC_PRICE, USD_PRICE);
    }

    /// @dev The fill that keeps the index's whole distance from its weights at the auction's last second: 0.6166% of
    ///      it (`test_aLoneExecutorKeepsAtMostTheDistanceFromTheWeights`).
    function _greedy() internal pure returns (uint256[] memory) {
        return _three(0.0225e18, 55_556, 22_222_762);
    }

    // ---------------------------------------------------------------------
    // Posting a quote
    // ---------------------------------------------------------------------

    function test_onlyTheOwnerOrGuardianPostsAQuote() public {
        uint256[] memory prices = _moved();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        assertTrue(index.canStartRebalance(), "a stranger may start, without a quote");
        address[2] memory others = [stranger, creator];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, others[i]));
            index.startRebalance(0, prices, TOLERANCE);
        }
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner);
        index.startRebalance(0, prices, TOLERANCE);
        vm.revertToState(snapshot);
        vm.prank(guardian);
        index.startRebalance(0, prices, TOLERANCE);
        assertEq(index.proposalCount(), 1);
    }

    function test_aQuotedStartObeysTheClockAndRecordsItsQuote() public {
        uint256[] memory prices = _moved();
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0, prices, TOLERANCE);
        (uint256[] memory none, uint256 noTolerance) = index.rebalanceQuote();
        assertEq(none.length, 0);
        assertEq(noTolerance, 0);

        vm.warp(earliest);
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceStarted(1, 1, guardian, 0, earliest + 2 hours);
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceQuoted(1, prices, TOLERANCE);
        vm.prank(guardian);
        index.startRebalance(0, prices, TOLERANCE);
        (uint256[] memory posted, uint256 tolerance) = index.rebalanceQuote();
        assertEq(posted, prices);
        assertEq(tolerance, TOLERANCE);

        uint256 deadline = earliest + 2 hours + index.AUCTION_DURATION();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, deadline));
        index.startRebalance(0, prices, TOLERANCE);
    }

    function test_aQuoteNeedsAPriceForEveryMovingComponentAndATolerance() public {
        uint256[] memory prices = _moved();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.startPrank(guardian);

        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (prices[0], prices[1]);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        index.startRebalance(0, two, TOLERANCE);

        vm.expectRevert(IWeightedHub.InvalidQuote.selector);
        index.startRebalance(0, prices, 1e18);

        uint256 kept = prices[1];
        prices[1] = 0;
        vm.expectRevert(IWeightedHub.InvalidQuote.selector);
        index.startRebalance(0, prices, TOLERANCE);
        prices[1] = uint256(type(uint128).max) + 1;
        vm.expectRevert(IWeightedHub.InvalidQuote.selector);
        index.startRebalance(0, prices, TOLERANCE);

        // The top price and the widest tolerance are both a quote.
        prices[1] = type(uint128).max;
        index.startRebalance(0, prices, 1e18 - 1);
        (uint256[] memory posted, uint256 tolerance) = index.rebalanceQuote();
        assertEq(posted[1], type(uint128).max);
        assertEq(tolerance, 1e18 - 1);
        prices[1] = kept;
        vm.stopPrank();
    }

    /// @dev A kept component moves in no fill of the proposal, so its entry is ignored and recorded as zero.
    function test_aKeptComponentHasNoPlaceInAQuote() public {
        uint256[] memory prices = _moved();
        prices[2] = type(uint256).max;
        uint256[] memory recorded = _moved();
        recorded[2] = 0;
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceQuoted(1, recorded, TOLERANCE);
        vm.prank(guardian);
        index.startRebalance(4, prices, TOLERANCE);
        (uint256[] memory posted,) = index.rebalanceQuote();
        assertEq(posted, recorded);

        // ETH and BTC trade against each other at the quote; the kept dollars stay where they were.
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        uint256[] memory units = index.recordedUnits();
        uint256[] memory fair = _onWeights(index, recorded, 4);
        assertEq(fair[2], units[2]);
        executor.execute(index, fair, "");
        assertEq(index.recordedUnits()[2], units[2]);
        assertEq(index.rebalanceNonce(), 1);
    }

    // ---------------------------------------------------------------------
    // What a quote does to a fill
    // ---------------------------------------------------------------------

    /// @dev Without a quote, an executor alone at the last second keeps the index's distance from its weights. With
    ///      the market's prices posted at the start, it keeps at most the tolerance of what it trades.
    function test_aQuoteCapsWhatALoneExecutorKeeps() public {
        uint256[] memory prices = _moved();
        _openQuoted(0, prices, TOLERANCE, index.AUCTION_DURATION());
        uint256[] memory units = index.recordedUnits();

        uint256[] memory greedy = _greedy();
        (uint256 greedyOut, uint256 greedyIn) = _values(units, greedy, prices);
        uint256 greedyFloor = Math.mulDiv(greedyOut, 1e18 - TOLERANCE, 1e18, Math.Rounding.Ceil);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.BelowQuote.selector, greedyIn, greedyFloor));
        index.previewRebalance(greedy);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.BelowQuote.selector, greedyIn, greedyFloor));
        executor.execute(index, greedy, "");

        // The most a fill may keep now: it sells what the fair fill sells, and buys the tolerance less of each coin.
        uint256[] memory fair = _onWeights(index, prices);
        uint256[] memory least = _three(fair[0], 0, 0);
        for (uint256 i = 1; i < 3; ++i) {
            least[i] = units[i] + Math.mulDiv(fair[i] - units[i], 1e18 - TOLERANCE, 1e18, Math.Rounding.Ceil);
        }
        (uint256 bar, int256 gain,,) = index.previewRebalance(least);
        assertGe(gain, int256(bar));
        executor.execute(index, least, "");

        (uint256 valueOut, uint256 valueIn) = _values(units, least, prices);
        assertLe((valueOut - valueIn) * 1e18, valueOut * TOLERANCE, "it kept at most the tolerance of what it traded");
        uint256 worth = units[0] * prices[0] + units[1] * prices[1] + units[2] * prices[2];
        assertLt((valueOut - valueIn) * 1e6 / worth, 600, "under 0.06% of the index, against 0.6166% without a quote");
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev A quote is a second condition, never a replacement: a fill under the bar is refused as it always is, and
    ///      a quote so wide that it asks for nothing leaves exactly the fills the bar accepts.
    function test_aQuoteOnlyRefusesWhatTheBarWouldAccept() public {
        uint256[] memory prices = _moved();
        _openQuoted(0, prices, 1e18 - 1, index.AUCTION_DURATION());

        uint256[] memory greedy = _greedy();
        greedy[1] -= 1;
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        index.previewRebalance(greedy);
        greedy[1] += 1;
        executor.execute(index, greedy, "");
        assertEq(index.rebalanceNonce(), 1, "the widest quote refuses nothing the bar accepts");
    }

    /// @dev A quote that is wrong stops its own proposal and touches nothing else: holders mint and leave as ever, the
    ///      guardian cancels it, and the next start is free of it.
    function test_aWrongQuoteStopsItsProposalAndNothingElse() public {
        // ETH posted at ten times its price: the ETH the index sells looks worth ten times what any fill brings in.
        uint256[] memory wrong = _market(25_000, BTC_PRICE, USD_PRICE);
        _openQuoted(0, wrong, TOLERANCE, index.AUCTION_DURATION());
        uint256[] memory fair = _onWeights(index, _moved());
        vm.expectPartialRevert(IWeightedHub.BelowQuote.selector);
        executor.execute(index, fair, "");

        _issue(index, alice, 1e18);
        vm.prank(alice);
        index.redeem(1e18, alice);

        vm.prank(guardian);
        index.cancelRebalance();
        (uint256[] memory none, uint256 noTolerance) = index.rebalanceQuote();
        assertEq(none.length, 0, "a cancelled proposal has no quote");
        assertEq(noTolerance, 0);

        vm.prank(guardian);
        index.startRebalance(0, _moved(), TOLERANCE);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        executor.execute(index, fair, "");
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev The quote belongs to the proposal it was posted with. A later start without one is bound by the bar
    ///      alone, though the old prices are still in storage.
    function test_aQuoteEndsWithItsProposal() public {
        _openQuoted(0, _moved(), TOLERANCE, index.AUCTION_DURATION() + 1);
        // Expired unfilled: strangers wait out the hold-off, then one starts, with no quote.
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY());
        vm.prank(stranger);
        index.startRebalance(0);
        assertEq(index.proposalCount(), 2);
        (uint256[] memory none, uint256 noTolerance) = index.rebalanceQuote();
        assertEq(none.length, 0);
        assertEq(noTolerance, 0);

        (eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        executor.execute(index, _greedy(), "");
        assertEq(index.rebalanceNonce(), 1, "the fill the old quote refused settles under the bar alone");
    }

    /// @dev A second quote overwrites the first, entry for entry, a kept component's with zero.
    function test_aSecondQuoteReplacesTheFirst() public {
        _openQuoted(0, _moved(), TOLERANCE, index.AUCTION_DURATION() + 1);
        uint256[] memory later = _market(3000, 70_000, USD_PRICE);
        vm.prank(guardian);
        index.startRebalance(1, later, 0.01e18);
        later[0] = 0;
        (uint256[] memory posted, uint256 tolerance) = index.rebalanceQuote();
        assertEq(posted, later);
        assertEq(tolerance, 0.01e18);
        assertEq(index.proposalCount(), 2);
    }

    /// @dev The quoted start is the plain start with a quote: it takes no ether either.
    function test_aQuotedStartTakesNoEther() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.deal(guardian, 1 ether);
        vm.prank(guardian);
        (bool started,) = address(index).call{value: 1}(
            abi.encodeWithSignature("startRebalance(uint256,uint256[],uint256)", 0, _moved(), TOLERANCE)
        );
        assertFalse(started);
    }
}
