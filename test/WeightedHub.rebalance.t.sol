// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IWeightedMath} from "../src/interfaces/IWeightedMath.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockSenderBlockToken} from "./mocks/MockAdminTokens.sol";
import {MockSelfLosingToken} from "./mocks/MockSelfTransferTokens.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice Delivers what a fill asks for, then claws one raw unit of a component back out of the index, as an issuer's
///         clawback inside the callback would.
contract ClawingExecutor is IRebalanceExecutor {
    uint256 internal immutable CLAWED;

    constructor(uint256 clawed) {
        CLAWED = clawed;
    }

    function execute(IWeightedHub index, uint256[] calldata newUnits) external {
        index.executeRebalance(newUnits, "");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IWeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) MockERC20(t[i]).mint(msg.sender, amountsIn[i]);
        }
        MockERC20(t[CLAWED]).burn(msg.sender, 1);
    }
}

/// @notice Delivers what a fill asks for out of the tokens it already holds and keeps no record of its own, so a measured
///         fill costs the hub's work and the token transfers alone.
contract HoldingExecutor is IRebalanceExecutor {
    using SafeERC20 for IERC20;

    function execute(IWeightedHub index, uint256[] calldata newUnits) external {
        index.executeRebalance(newUnits, "");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IWeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) IERC20(t[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}

/// @notice The weighted hub's rebalance: start, notice, auction, the fill an executor names, and cancellation. No
///         price is read anywhere: only the tests know what the market says, as an executor would.
/// @dev The default index (ETH 50%, BTC 30%, USD 20%, $100 a token) with 100 tokens issued. In most tests the market
///      has taken ETH to $2,500, which makes a token worth $112.50. The fair fill, the one a competitive executor
///      names, puts it on its weights without changing its value there: 0.0225 ETH, 0.0005625 BTC and 22.5 USD a
///      token, selling a tenth of the ETH units and buying an eighth more of the other two. Its weighted gain is
///      0.62%, the index's distance from its weights, which the bar falls to 4,618 seconds into the auction. At the
///      starting prices the index is on its weights, and no fill that takes value there is accepted.
contract WeightedHubRebalanceTest is WeightedTest {
    WeightedHub index;
    MockWeightedExecutor executor;

    uint256 constant SHARES = 100e18;
    uint256 constant WAD = 1e18;
    /// @dev The fair fill's gain with ETH at $2,500, from the exact model (`test/vectors/settlement.py`).
    int256 constant FAIR_GAIN = 6_200_983_072_916_666;
    /// @dev The first second of the auction at which the bar is at or under that gain.
    uint256 constant FAIR_SECOND = 4618;
    /// @dev The bar at the auction's last second.
    uint256 constant BAR_FLOOR = 476_837_158_204;

    function setUp() public {
        _deploy();
        _listAll();
        index = _create(_defaultSpecs());
        _issue(index, alice, SHARES);
        executor = new MockWeightedExecutor();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Starts a rebalance once the interval has passed and warps `into` seconds into its auction.
    function _open(uint256 keepMask, uint256 into) internal {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        if (keepMask != 0) vm.prank(guardian);
        index.startRebalance(keepMask);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + into);
    }

    /// @dev Halfway through the auction, where the bar has halved ten times: 0.049%.
    function _midpoint() internal view returns (uint256) {
        return index.AUCTION_DURATION() / 2;
    }

    /// @dev The fair fill with ETH at $2,500 and the rest where it was.
    function _fair() internal view returns (uint256[] memory) {
        return _onWeights(index, _market(2500, BTC_PRICE, USD_PRICE));
    }

    function _units() internal view returns (uint256[] memory units) {
        (, units) = index.components();
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory u) {
        u = new uint256[](3);
        (u[0], u[1], u[2]) = (a, b, c);
    }

    /// @dev What `units` of the default components are worth at `prices`, at the prices' scale.
    function _value(uint256[] memory units, uint256[] memory prices) internal pure returns (uint256 value) {
        for (uint256 i = 0; i < units.length; ++i) {
            value += units[i] * prices[i];
        }
    }

    // ---------------------------------------------------------------------
    // Start
    // ---------------------------------------------------------------------

    function test_startWaitsForTheInterval() public {
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        assertFalse(index.canStartRebalance());
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0);

        vm.warp(earliest);
        assertTrue(index.canStartRebalance());
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceStarted(1, 1, stranger, 0, earliest + 2 hours);
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta, uint256 keepMask) = index.pendingRebalance();
        assertEq(eta, earliest + 2 hours);
        assertEq(keepMask, 0);
        assertEq(index.proposalCount(), 1);
        assertFalse(index.canStartRebalance());
    }

    function test_startRefusesWhileAnAuctionIsLive() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, eta + index.AUCTION_DURATION()));
        vm.prank(guardian);
        index.startRebalance(0);
    }

    function test_startChecksTheKeepMask() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 8));
        index.startRebalance(8);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 7));
        index.startRebalance(7);
        index.startRebalance(4);
        vm.stopPrank();
        (, uint256 keepMask) = index.pendingRebalance();
        assertEq(keepMask, 4);
    }

    /// @dev V5-L2: a keep mask must leave two components moving. One alone has nothing to trade against, so a fill of
    ///      it could only restart MIN_REBALANCE_INTERVAL: a stall for the guardian.
    function test_V5L2_aKeepMaskMustLeaveTwoMoving() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 6));
        index.startRebalance(6);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 3));
        index.startRebalance(3);
        index.startRebalance(1);
        vm.stopPrank();
    }

    function test_R16_onlyTheOwnerOrGuardianPassesAKeepMask() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(1);
        vm.prank(owner);
        index.startRebalance(1);
    }

    /// @dev A rebalance pays nobody for a price, so none of its entry points takes ether and the index never holds
    ///      any: a start, a fill and a bounded fill sent with a wei all revert.
    function test_noRebalanceEntryPointTakesEther() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.deal(address(this), 3);
        (bool started,) = address(index).call{value: 1}(abi.encodeCall(IWeightedHub.startRebalance, (0)));
        assertFalse(started, "a start takes no ether");
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + _midpoint());
        uint256[] memory fair = _fair();
        (bool filled,) =
            address(index).call{value: 1}(abi.encodeWithSignature("executeRebalance(uint256[],bytes)", fair, ""));
        assertFalse(filled, "a fill takes no ether");
        (bool bounded,) = address(index).call{value: 1}(
            abi.encodeWithSignature("executeRebalance(uint256[],bytes,uint256[])", fair, "", new uint256[](0))
        );
        assertFalse(bounded, "nor does a bounded fill");
        assertEq(address(index).balance, 0);
    }

    // ---------------------------------------------------------------------
    // Cancel and restart
    // ---------------------------------------------------------------------

    function test_R15_VR04_cancelHoldsStrangersOff() public {
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        vm.prank(guardian);
        index.cancelRebalance();

        _open(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.cancelRebalance();

        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceCancelled(1, guardian, block.timestamp + 2 hours);
        vm.prank(guardian);
        index.cancelRebalance();
        (uint256 eta,) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(index.restartAllowedAt(), block.timestamp + 2 hours);

        assertFalse(index.canStartRebalance());
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(0);
        vm.prank(owner);
        index.startRebalance(0);
        vm.prank(owner);
        index.cancelRebalance();

        vm.warp(block.timestamp + 2 hours);
        assertTrue(index.canStartRebalance());
        vm.prank(stranger);
        index.startRebalance(0);
    }

    function test_XA02_XA16_VR04_anExpiredAuctionHoldsStrangersOffUntilItsDelayPasses() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        uint256 end = eta + index.AUCTION_DURATION();

        vm.warp(end + 1);
        uint256[] memory fair = _fair();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, end));
        executor.execute(index, fair, "");
        assertEq(index.currentBar(), 0);
        assertFalse(index.canStartRebalance());
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(0);

        // A cancel of the expired proposal neither shortens nor extends the hold-off.
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), end + 2 hours);

        vm.warp(end + 2 hours);
        assertTrue(index.canStartRebalance());
        vm.prank(stranger);
        index.startRebalance(0);
    }

    function test_theOwnerRestartsAtOnceAfterAnExpiry() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        vm.prank(owner);
        index.startRebalance(0);
        assertEq(index.proposalCount(), 2);
    }

    // ---------------------------------------------------------------------
    // The auction's clock and its bar
    // ---------------------------------------------------------------------

    function test_executeChecksTheAuctionIsOpen() public {
        uint256[] memory fair = _fair();
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        executor.execute(index, fair, "");
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        index.previewRebalance(fair);

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceNotReady.selector, eta));
        executor.execute(index, fair, "");
        assertEq(index.currentBar(), 0, "not open yet");
    }

    /// @dev The bar starts at a half, halves every twelve minutes along a straight line within each, and rounds up.
    ///      It never reaches zero, so a fill always has to gain something.
    function test_theBarHalvesEveryTwelveMinutesRoundedUp() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(index.currentBar(), 0.5e18);
        vm.warp(eta + 12 minutes);
        assertEq(index.currentBar(), 0.25e18);
        vm.warp(eta + 6 minutes);
        assertEq(index.currentBar(), 0.375e18, "halfway through a halving, three quarters of where it began");
        vm.warp(eta + 2 hours);
        assertEq(index.currentBar(), 488_281_250_000_000, "ten halvings: 0.5 / 1,024");
        vm.warp(eta + 4 hours);
        assertEq(index.currentBar(), BAR_FLOOR, "twenty halvings, 476,837,158,203.125, rounded up");
        vm.warp(eta + 4 hours - 1);
        assertEq(index.currentBar(), 477_499_432_034);
        // One second in: 0.5e18 * 1,439 / 1,440 = 499,652,777,777,777,777.78, rounded up.
        vm.warp(eta + 1);
        assertEq(index.currentBar(), 499_652_777_777_777_778);

        IWeightedMath math = IWeightedMath(index.MATH());
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.AuctionOver.selector, 4 hours + 1));
        math.barAt(4 hours + 1);
    }

    // ---------------------------------------------------------------------
    // The fill
    // ---------------------------------------------------------------------

    /// @dev The fair fill, to the raw unit: the executor names the units, the index sends a tenth of its ETH, asks for
    ///      an eighth more BTC and USD, and records exactly the units named.
    function test_aFairFillSettlesToTheUnit() public {
        _open(0, _midpoint());
        uint256[] memory fair = _fair();
        assertEq(fair, _three(0.0225e18, 0.0005625e8, 22.5e6));
        uint256[] memory out = _three(0.0025e18 * 100, 0, 0);
        uint256[] memory in_ = _three(0, 0.0000625e8 * 100, 2.5e6 * 100);

        vm.expectEmit(address(index));
        emit IWeightedHub.Rebalanced(1, 1, address(executor), 488_281_250_000_000, FAIR_GAIN, fair, out, in_);
        executor.execute(index, fair, "");

        assertEq(executor.lastAmountsOut(), out);
        assertEq(executor.lastAmountsIn(), in_);
        assertEq(index.recordedUnits(), fair);
        assertEq(eth.balanceOf(address(executor)), 0.25e18, "the executor was paid the ETH");
        assertEq(eth.balanceOf(address(index)), 2.25e18);
        assertEq(btc.balanceOf(address(index)), 0.05625e8);
        assertEq(usd.balanceOf(address(index)), 2250e6);
        assertEq(index.rebalanceNonce(), 1);
        assertEq(index.lastRebalance(), block.timestamp);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(index.currentBar(), 0);
    }

    /// @dev The bar decides when a fill clears: the fair fill is refused a second before the bar reaches its gain, and
    ///      accepted the second it does. Whoever is ready then settles; nobody has to say what ETH is worth.
    function test_theBarDecidesWhenAFillClears() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        uint256[] memory fair = _fair();
        IWeightedMath math = IWeightedMath(index.MATH());

        vm.warp(eta + FAIR_SECOND - 1);
        uint256 bar = math.barAt(FAIR_SECOND - 1);
        assertGt(int256(bar), FAIR_GAIN);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.GainBelowBar.selector, FAIR_GAIN, bar));
        index.previewRebalance(fair);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.GainBelowBar.selector, FAIR_GAIN, bar));
        executor.execute(index, fair, "");

        _warpToFirstFill(index, fair);
        assertEq(block.timestamp, eta + FAIR_SECOND);
        (uint256 barNow, int256 gain,,) = index.previewRebalance(fair);
        assertEq(gain, FAIR_GAIN);
        assertLe(int256(barNow), FAIR_GAIN);
        executor.execute(index, fair, "");
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev A fill that gives every component twice its units, the most one fill may add, gains more than the bar's
    ///      first second asks: the auction starts above anything a trade could offer, and falls to meet it.
    function test_onlyAGiftClearsTheBarsFirstSecond() public {
        _open(0, 0);
        uint256[] memory fair = _fair();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.GainBelowBar.selector, FAIR_GAIN, 0.5e18));
        executor.execute(index, fair, "");

        uint256[] memory doubled = _three(2 * ETH_UNITS, 2 * BTC_UNITS, 2 * USD_UNITS);
        (, int256 gain, uint256[] memory out,) = index.previewRebalance(doubled);
        assertEq(gain, 533_333_333_333_333_333, "L(1) = 1 - 1/2 + 1/3 - 3/10");
        assertEq(out, _three(0, 0, 0), "the executor is paid nothing");
        executor.execute(index, doubled, "");
        assertEq(index.recordedUnits(), doubled);
    }

    /// @dev V5-L2: a fill that changes nothing has no gain, so it cannot restart the interval, at any second of the
    ///      auction; nor can one that takes more than it gives.
    function test_V5L2_aFillThatChangesNothingCannotRestartTheInterval() public {
        _open(0, index.AUCTION_DURATION());
        uint256 last = index.lastRebalance();
        uint256[] memory unchanged = index.recordedUnits();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.GainBelowBar.selector, int256(0), BAR_FLOOR));
        index.previewRebalance(unchanged);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.GainBelowBar.selector, int256(0), BAR_FLOOR));
        executor.execute(index, unchanged, "");

        // The fair fill run backwards buys the ETH the market sells dear and pays in what it holds cheap: a loss of
        // weighted units, refused whatever the second.
        uint256[] memory backwards = _three(0.0275e18, 44_444, 17_777_777);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.GainBelowBar.selector, int256(-11_244_803_736_091_740), BAR_FLOOR)
        );
        executor.execute(index, backwards, "");
        assertEq(index.lastRebalance(), last);
        assertEq(index.rebalanceNonce(), 0);
    }

    /// @dev V5-M2: the cap counts units. Whatever the executor offers in return, a fill leaves a component with at
    ///      least four fifths of its units: one raw unit under that is refused, and exactly that is the most it takes.
    function test_V5M2_aFillTakesAtMostAFifthOfALegsUnits() public {
        _open(0, index.AUCTION_DURATION());
        uint256 lowest = 0.02e18;
        uint256[] memory greedy = _three(lowest - 1, 2 * BTC_UNITS, 2 * USD_UNITS);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.LegOutOfBounds.selector, 0, lowest - 1, lowest, 2 * ETH_UNITS)
        );
        executor.execute(index, greedy, "");

        greedy[0] = lowest;
        executor.execute(index, greedy, "");
        assertEq(eth.balanceOf(address(executor)), 0.005e18 * 100, "a fifth of the ETH, to the raw unit");
        assertEq(index.recordedUnits()[0], lowest);
    }

    /// @dev RX-15: a fill at most doubles a component's units. So a coin anyone can mint for nothing, whatever it is
    ///      worth, cannot be poured into the index without limit to draw the other components out.
    function test_RX15_aFillAtMostDoublesALeg() public {
        _open(0, index.AUCTION_DURATION());
        uint256[] memory flooded = _three(ETH_UNITS, BTC_UNITS, 2 * USD_UNITS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.LegOutOfBounds.selector, 2, 2 * USD_UNITS + 1, 16e6, 2 * USD_UNITS)
        );
        executor.execute(index, flooded, "");

        // Doubled, the worthless leg's gain pays for a tenth of the other two at most: 0.2 * L(1) against 0.8 * L(x).
        flooded = _three(0.0225e18, 0.00045e8, 2 * USD_UNITS);
        (, int256 gain,,) = index.previewRebalance(flooded);
        assertGt(gain, 0);
        flooded = _three(0.02e18, 0.0004e8, 2 * USD_UNITS);
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        index.previewRebalance(flooded);
    }

    /// @dev Units already near the top of the 96 bits the hub records stop the fill rather than wrap, and the math
    ///      itself stops, so a preview never accepts units a fill could not write (V5-L3, RX-61).
    function test_V5L3_RX61_unitsBeyondUint96StopTheFill() public {
        uint256 top = type(uint96).max;
        uint256[] memory units = new uint256[](2);
        units[0] = top / 2;
        units[1] = top * 9 / 10;
        uint256[] memory next = new uint256[](2);
        next[0] = top / 2;
        next[1] = top + 1;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        IWeightedMath math = IWeightedMath(index.MATH());
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, top + 1));
        math.settlement(4 hours, 1e18, 1e18, units, next, weights, 0);
    }

    /// @dev R14 and XA-27: nobody is paid for an empty index, and nobody moves its units for nothing either. Without
    ///      shares a fill has nothing to trade, so the units a first minter deposits are the ones the creator set.
    function test_R14_XA27_anEmptyIndexDoesNotRebalance() public {
        vm.prank(creator);
        WeightedHub empty = WeightedHub(factory.createIndex("Empty", "EMP", _defaultSpecs(), _params()));
        vm.warp(empty.lastRebalance() + empty.MIN_REBALANCE_INTERVAL());
        empty.startRebalance(0);
        (uint256 eta,) = empty.pendingRebalance();
        vm.warp(eta);
        uint256[] memory doubled = _three(2 * ETH_UNITS, 2 * BTC_UNITS, 2 * USD_UNITS);
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        empty.previewRebalance(doubled);
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        executor.execute(empty, doubled, "");
        assertEq(empty.recordedUnits(), _three(ETH_UNITS, BTC_UNITS, USD_UNITS));
    }

    /// @dev The settlement arithmetic lives in `WeightedMath`, deployed by the factory with the implementation and
    ///      fixed in it; the constants the two share are the same, which every executor reads from the hub.
    function test_theMathConstantsAreTheHubs() public view {
        IWeightedMath math = IWeightedMath(index.MATH());
        assertEq(index.MATH(), WeightedHub(factory.IMPLEMENTATION()).MATH());
        assertGt(index.MATH().code.length, 0);
        assertEq(math.MAX_TURNOVER(), index.MAX_TURNOVER());
        assertEq(math.AUCTION_DURATION(), index.AUCTION_DURATION());
        assertEq(math.MAX_GROWTH(), 1e18);
        assertEq(math.BAR_MAX(), 0.5e18);
        assertEq(math.BAR_HALF_LIFE(), 12 minutes);
        assertEq(math.AUCTION_DURATION(), 20 * math.BAR_HALF_LIFE(), "twenty halvings");
    }

    function test_previewMatchesTheFill() public {
        _open(0, 0);
        uint256[] memory fill = _onWeights(index, _market(2345, 71_234, 1));
        _warpToFirstFill(index, fill);
        (uint256 bar, int256 gain, uint256[] memory out, uint256[] memory in_) = index.previewRebalance(fill);
        assertEq(bar, index.currentBar());
        vm.expectEmit(address(index));
        emit IWeightedHub.Rebalanced(1, 1, address(executor), bar, gain, fill, out, in_);
        executor.execute(index, fill, "");
        assertEq(executor.lastAmountsOut(), out);
        assertEq(executor.lastAmountsIn(), in_);
        assertEq(index.recordedUnits(), fill);
    }

    /// @dev A fill names one unit count per component: fewer or more is refused, in the preview and in the fill.
    function test_aFillNamesEveryComponent() public {
        _open(0, _midpoint());
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (ETH_UNITS, BTC_UNITS);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        index.previewRebalance(two);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        executor.execute(index, two, "");
        uint256[] memory four = new uint256[](4);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        executor.execute(index, four, "");
    }

    function test_executorDataPassesThrough() public {
        _open(0, _midpoint());
        executor.execute(index, _fair(), "hello");
        assertEq(executor.lastData(), "hello");
    }

    // ---------------------------------------------------------------------
    // Keep mask
    // ---------------------------------------------------------------------

    /// @dev A kept component is not read and not moved; the others trade among themselves. An executor needs no mask
    ///      to leave a component alone: naming its current units does it, and that component is not read either, so a
    ///      fill works around one whose `balanceOf` reverts.
    function test_R08_DA14_RT01_aComponentLeftAloneIsNotRead() public {
        MockPausableToken frozen = new MockPausableToken("Frozen", "FRZ", 18);
        _list(address(frozen));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(btc), 3000, BTC_UNITS);
        specs[2] = _spec(address(frozen), 2000, 20e18);
        vm.prank(creator);
        WeightedHub three = WeightedHub(factory.createIndex("Three", "THR", specs, _params()));
        _issue(three, alice, SHARES);
        frozen.setReadsBroken(true);

        vm.warp(three.lastRebalance() + three.MIN_REBALANCE_INTERVAL());
        vm.prank(guardian);
        three.startRebalance(4);
        (uint256 eta,) = three.pendingRebalance();
        vm.warp(eta + three.AUCTION_DURATION() / 2);

        // ETH at $2,400: ETH $60 and BTC $30 share $90 at 5:3, so ETH 56.25 / 2,400 and BTC 33.75 / 60,000.
        uint256[] memory fill = _three(0.0234375e18, 0.0005625e8, 20e18);
        uint256 snapshot = vm.snapshotState();
        executor.execute(three, fill, "");
        assertEq(three.recordedUnits(), fill);
        assertEq(three.recordedUnits()[2], 20e18, "untouched");

        // The kept component may not move, by a raw unit either way.
        vm.revertToState(snapshot);
        fill[2] = 20e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.LegOutOfBounds.selector, 2, 20e18 + 1, 20e18, 20e18));
        executor.execute(three, fill, "");
        fill[2] = 20e18 - 1;
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.LegOutOfBounds.selector, 2, 20e18 - 1, 20e18, 20e18));
        executor.execute(three, fill, "");

        // Without a mask: a stranger's rebalance, and an executor that names the frozen component's own units.
        vm.prank(guardian);
        three.cancelRebalance();
        vm.warp(three.restartAllowedAt());
        vm.prank(stranger);
        three.startRebalance(0);
        (eta,) = three.pendingRebalance();
        vm.warp(eta + three.AUCTION_DURATION() / 2);
        fill[2] = 20e18;
        executor.execute(three, fill, "");
        assertEq(three.recordedUnits(), fill);
    }

    // ---------------------------------------------------------------------
    // Executors
    // ---------------------------------------------------------------------

    function test_R10_aShortDeliveryReverts() public {
        _open(0, _midpoint());
        executor.setMode(MockWeightedExecutor.Mode.Short);
        executor.setShortComponent(2);
        uint256[] memory fair = _fair();
        uint256 required = 22.5e6 * 100;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(usd), required - 1, required)
        );
        executor.execute(index, fair, "");
    }

    /// @dev Surplus the index already held stays with the holders: an executor cannot deliver that much less.
    function test_R21_XA28_aDonationDoesNotPayForTheFill() public {
        _open(0, _midpoint());
        usd.mint(address(index), 5e6);
        executor.setMode(MockWeightedExecutor.Mode.Short);
        executor.setShortComponent(2);
        uint256[] memory fair = _fair();
        uint256 required = 22.5e6 * 100 + 5e6;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(usd), required - 1, required)
        );
        executor.execute(index, fair, "");
    }

    function test_VR03_aNoopExecutorReverts() public {
        _open(0, _midpoint());
        executor.setMode(MockWeightedExecutor.Mode.Noop);
        uint256[] memory fair = _fair();
        vm.expectRevert(
            abi.encodeWithSelector(
                IWeightedHub.RebalanceUnderfunded.selector, address(btc), BTC_UNITS * 100, 0.0005625e8 * 100
            )
        );
        executor.execute(index, fair, "");
    }

    function test_DA13_theBoundedFill() public {
        _open(0, _midpoint());
        uint256[] memory fair = _fair();
        uint256[] memory bounds = new uint256[](2);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        executor.executeBounded(index, fair, "", bounds);

        bounds = new uint256[](3);
        bounds[1] = 0.0000625e8 * 100;
        bounds[2] = 2.5e6 * 100 - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceMovedOn.selector, address(usd), 2.5e6 * 100, bounds[2])
        );
        executor.executeBounded(index, fair, "", bounds);

        bounds[2] = 2.5e6 * 100;
        executor.executeBounded(index, fair, "", bounds);
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev DA-13: issue stays open through the auction, and a fill's amounts follow the supply of its own block. A
    ///      mint that lands first enlarges what the executor owes; the bounded fill refuses rather than pay it.
    function test_DA13_aMintBeforeTheFillMovesItPastTheBound() public {
        _open(0, _midpoint());
        uint256[] memory fair = _fair();
        (,,, uint256[] memory bounds) = index.previewRebalance(fair);
        _issue(index, stranger, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceMovedOn.selector, address(btc), 0.0000625e8 * 101, bounds[1])
        );
        executor.executeBounded(index, fair, "", bounds);
        executor.execute(index, fair, "");
        assertEq(executor.lastAmountsIn()[2], 2.5e6 * 101, "the unbounded fill settles at the supply it finds");
    }

    function test_R11_everyEntryPointIsGuardedDuringTheCallback() public {
        _open(0, _midpoint());
        executor.setMode(MockWeightedExecutor.Mode.Reentrant);
        executor.execute(index, _fair(), "");
        bytes[] memory errors = executor.reentryErrors();
        assertEq(errors.length, 10, "every entry point that mints, burns, pays, accrues or rebalances (XS-18)");
        for (uint256 i = 0; i < errors.length; ++i) {
            assertEq(errors[i], abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        }
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev Tether Gold blocks only its sender. Once it blocks the index, the index's XAUT cannot leave, yet an executor
    ///      can still deliver more of it. A fill that grows that leg would move good legs into a leg no holder can take
    ///      out, so it reverts; the executor leaves the leg alone, or the guardian keeps it (RX-12).
    function test_RX12_aFillCannotBuyALegTheIndexCannotSend() public {
        MockSenderBlockToken gold = new MockSenderBlockToken(owner);
        _list(address(gold));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(btc), 3000, BTC_UNITS);
        specs[2] = _spec(address(gold), 2000, 20e18);
        vm.prank(creator);
        WeightedHub three = WeightedHub(factory.createIndex("Gold", "GLD", specs, _params()));
        _issue(three, alice, SHARES);
        gold.addBlackList(address(three));

        vm.warp(three.lastRebalance() + three.MIN_REBALANCE_INTERVAL());
        three.startRebalance(0);
        (uint256 eta,) = three.pendingRebalance();
        vm.warp(eta + three.AUCTION_DURATION() / 2);
        // ETH at $2,200 and gold at 90 cents: the fair fill sells ETH and buys BTC and gold.
        uint256[] memory prices = new uint256[](3);
        (prices[0], prices[1], prices[2]) = (22_000, 600_000e10, 9);
        uint256[] memory fill = _onWeights(three, prices);
        assertGt(fill[2], 20e18, "gold is bought");
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.CannotSendOut.selector, address(gold)));
        executor.execute(three, fill, "");

        // Unblocked, the same fill settles.
        gold.removeBlackList(address(three));
        executor.execute(three, fill, "");
        assertEq(three.rebalanceNonce(), 1);
    }

    /// @dev The probe reads the balance again after its transfer. A token whose transfer to oneself answers true but
    ///      loses the unit would otherwise pass as a leg the index can send (RX-12, RB-2). Sold, the leg leaves as any
    ///      other.
    function test_RB2_RX12_theProbeReadsTheBalanceAfterItsTransfer() public {
        MockSelfLosingToken losing = new MockSelfLosingToken();
        _list(address(losing));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(losing), 5000, 50e18);
        WeightedHub two = _create(specs);
        _issue(two, alice, SHARES);

        vm.warp(two.lastRebalance() + two.MIN_REBALANCE_INTERVAL());
        two.startRebalance(0);
        (uint256 eta,) = two.pendingRebalance();
        vm.warp(eta + two.AUCTION_DURATION() / 2);
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (2500, 1); // ETH shrinks, so the fill buys the losing leg
        uint256[] memory fill = _onWeights(two, prices);
        assertGt(fill[1], 50e18);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.CannotSendOut.selector, address(losing)));
        executor.execute(two, fill, "");

        prices[0] = 1500; // ETH grows, so the fill sells the losing leg
        fill = _onWeights(two, prices);
        assertLt(fill[1], 50e18);
        executor.execute(two, fill, "");
        assertEq(two.rebalanceNonce(), 1);
    }

    // ---------------------------------------------------------------------
    // The backing post-check and each leg's rounding, carried from v4's hub
    // ---------------------------------------------------------------------

    /// @dev CR-I30: the post-check reads again every leg that moved. A raw unit of a bought component clawed from the
    ///      index before the fill leaves it a unit short of the backing it owes, whatever the executor delivers.
    function test_CRI30_aSettlementStillDemandsTheBackingItOwes() public {
        _open(0, _midpoint());
        uint256[] memory fair = _fair();
        (,,, uint256[] memory in_) = index.previewRebalance(fair);
        assertGt(in_[1], 0, "BTC is bought");
        btc.burn(address(index), 1); // the issuer's clawback
        uint256 required = SHARES * fair[1] / WAD;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(btc), required - 1, required)
        );
        executor.execute(index, fair, "");
    }

    /// @dev CR-I30 and VR-06: the `+ totalClaims` in the backing term. With a claim open on the bought component, a
    ///      clawed unit there is caught only if the claim is counted.
    function test_VR06_CRI30_theBackingTermCountsOpenClaims() public {
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 1 << 1); // leaves a token's BTC in the index as alice's claim
        assertEq(index.totalClaims(address(btc)), BTC_UNITS);
        _open(0, _midpoint());
        uint256[] memory fair = _fair();
        (,,, uint256[] memory in_) = index.previewRebalance(fair);
        assertGt(in_[1], 0);
        btc.burn(address(index), 1);
        uint256 required = index.totalSupply() * fair[1] / WAD + index.totalClaims(address(btc));
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(btc), required - 1, required)
        );
        executor.execute(index, fair, "");
    }

    /// @dev CR-I30, the sold legs: the post-check reads again a leg the index only sold.
    function test_CRI30_aSoldLegIsCheckedAgainAfterTheCallback() public {
        _open(0, _midpoint());
        uint256[] memory fair = _fair();
        (,, uint256[] memory out, uint256[] memory in_) = index.previewRebalance(fair);
        assertGt(out[0], 0, "ETH is sold");
        assertEq(in_[0], 0, "and receives nothing");
        uint256 required = SHARES * fair[0] / WAD;
        ClawingExecutor clawing = new ClawingExecutor(0);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(eth), required - 1, required)
        );
        clawing.execute(index, fair);
    }

    /// @dev RT-12 and SA-07. On a supply under one index token a leg's change in backing is a fraction of a raw unit. As
    ///      a difference of floored backings a shrinking leg released its whole raw unit while no growing leg asked for
    ///      one, so an executor that delivered nothing was paid. Each leg rounds its own change the holders' way:
    ///      nothing leaves, and each growing leg asks for its raw unit, which an empty executor cannot deliver.
    function test_RT12_SA07_anEmptyExecutorIsPaidNothingOnASubTokenSupply() public {
        vm.prank(creator);
        WeightedHub dust = WeightedHub(factory.createIndex("Dust", "DUST", _defaultSpecs(), _params()));
        // Forty wei of shares: exactly one raw unit of ETH, and one of BTC and USD, rounded up. A tenth of the ETH
        // leaves, which as a difference of floored backings, 1 - 0, was the whole raw unit.
        _issue(dust, alice, 40);
        assertEq(eth.balanceOf(address(dust)), 1);
        vm.warp(dust.lastRebalance() + dust.MIN_REBALANCE_INTERVAL());
        dust.startRebalance(0);
        (uint256 eta,) = dust.pendingRebalance();
        vm.warp(eta + 2 hours);

        uint256[] memory fair = _three(0.0225e18, 0.0005625e8, 22.5e6);
        (,, uint256[] memory out, uint256[] memory in_) = dust.previewRebalance(fair);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(out[i], 0, "no leg releases a raw unit for a fraction of one");
        }
        assertEq(in_[1], 1, "BTC grows, asking for its raw unit, rounded up");
        assertEq(in_[2], 1);

        executor.setMode(MockWeightedExecutor.Mode.Noop);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(btc), 1, 2));
        executor.execute(dust, fair, "");
        executor.setMode(MockWeightedExecutor.Mode.Honest);
        executor.execute(dust, fair, "");
        assertEq(eth.balanceOf(address(executor)), 0, "an honest executor is paid nothing either");
        assertEq(dust.rebalanceNonce(), 1);
    }

    // ---------------------------------------------------------------------
    // What a fill can take
    // ---------------------------------------------------------------------

    /// @dev R04, without a price in the contract. The index starts on its weights at the market's prices. Whatever
    ///      units an executor names, at any second of the auction, a fill the index accepts leaves it worth more at
    ///      those prices than it was: on its weights there is nothing to take, and nobody had to tell the index what
    ///      the prices are.
    function testFuzz_R04_onItsWeightsNoFillTakesValue(
        uint256 ethUnits,
        uint256 btcUnits,
        uint256 usdUnits,
        uint256 into
    ) public {
        uint256[] memory fill = _three(
            bound(ethUnits, 0.02e18, 2 * ETH_UNITS),
            bound(btcUnits, 0.0004e8, 2 * BTC_UNITS),
            bound(usdUnits, 16e6, 2 * USD_UNITS)
        );
        _open(0, bound(into, 0, index.AUCTION_DURATION()));
        uint256[] memory prices = _market(ETH_PRICE, BTC_PRICE, USD_PRICE);
        uint256 worth = _value(index.recordedUnits(), prices);
        try index.previewRebalance(fill) returns (uint256 bar, int256 gain, uint256[] memory, uint256[] memory) {
            assertGe(gain, int256(bar));
            assertGt(_value(fill, prices), worth, "an accepted fill adds value on the weights");
            executor.execute(index, fill, "");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IWeightedHub.GainBelowBar.selector, "inside the caps, only the bar refuses");
        }
    }

    /// @dev V5-M2 and RX-15: whatever units an executor names, an accepted fill sends out at most a fifth of what the
    ///      index holds of each component, and at most doubles one.
    function testFuzz_V5M2_noFillTakesMoreThanAFifthOfALeg(uint256 ethUnits, uint256 btcUnits, uint256 usdUnits)
        public
    {
        uint256[] memory fill = _three(
            bound(ethUnits, 1, 4 * ETH_UNITS), bound(btcUnits, 1, 4 * BTC_UNITS), bound(usdUnits, 1, 4 * USD_UNITS)
        );
        _open(0, index.AUCTION_DURATION());
        uint256[3] memory held =
            [eth.balanceOf(address(index)), btc.balanceOf(address(index)), usd.balanceOf(address(index))];
        try index.previewRebalance(fill) returns (uint256, int256, uint256[] memory out, uint256[] memory) {
            for (uint256 i = 0; i < 3; ++i) {
                assertLe(out[i] * 5, held[i], "at most a fifth of the leg");
            }
            assertLe(fill[0], 2 * ETH_UNITS);
            assertLe(fill[1], 2 * BTC_UNITS);
            assertLe(fill[2], 2 * USD_UNITS);
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            assertTrue(
                selector == IWeightedHub.LegOutOfBounds.selector || selector == IWeightedHub.GainBelowBar.selector,
                "a fill is refused for a cap or for the bar"
            );
        }
    }

    /// @dev What a lone executor can keep. With ETH at $2,500 the index sits 0.62% from its weights. At the auction's
    ///      last second, with nobody bidding against it, an executor names the fair ETH and as little BTC and USD as
    ///      still clears the bar: it keeps 0.6166% of the index's value at the market's prices, and no more. That
    ///      distance is the whole of what competition returns to the holders, and the most its absence costs them.
    function test_aLoneExecutorKeepsAtMostTheDistanceFromTheWeights() public {
        _open(0, index.AUCTION_DURATION());
        uint256[] memory prices = _market(2500, BTC_PRICE, USD_PRICE);
        uint256 worth = _value(index.recordedUnits(), prices);

        uint256[] memory greedy = _three(0.0225e18, 55_556, 22_222_762);
        (uint256 bar, int256 gain,,) = index.previewRebalance(greedy);
        assertEq(bar, BAR_FLOOR);
        assertEq(gain, 485_064_338_774, "just over the bar");
        greedy[1] -= 1;
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        index.previewRebalance(greedy);
        greedy[1] += 1;
        greedy[2] -= 2;
        vm.expectPartialRevert(IWeightedHub.GainBelowBar.selector);
        index.previewRebalance(greedy);
        greedy[2] += 2;

        executor.execute(index, greedy, "");
        uint256 left = _value(index.recordedUnits(), prices);
        assertApproxEqAbs((worth - left) * 1e6 / worth, 6165, 1, "0.6166% of the index, the distance from its weights");
    }

    /// @dev Fair fills through a price path land on the weights each time rather than drift from them.
    function test_repeatedFillsFollowThePrices() public {
        uint256[5] memory path = [uint256(2400), 1900, 2300, 2000, 2200];
        for (uint256 k = 0; k < path.length; ++k) {
            _open(0, _midpoint());
            executor.execute(index, _onWeights(index, _market(path[k], BTC_PRICE, USD_PRICE)), "");
        }
        uint256[] memory units = _units();
        uint256[] memory prices = _market(path[4], BTC_PRICE, USD_PRICE);
        assertApproxEqRel(units[0] * prices[0] * 2, _value(units, prices), 1e14);
        assertEq(index.rebalanceNonce(), 5);
    }

    // ---------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------

    /// @dev EIP-7825's cap on a transaction's gas.
    uint256 constant TX_GAS_CAP = 1 << 24;

    /// @dev Every hub path at a hundred components fits EIP-7825's 2^24 cap, each measured as the transaction Foundry
    ///      makes of the call, with every account it touches cold. The settlement is measured with an executor that
    ///      already holds the tokens, so its figure is the hub's own work and the transfers: the listed tokens transfer
    ///      dearer than MockERC20, and a fill that swaps a hundred legs does not fit, so an atomic fill that wide needs
    ///      an executor that holds the tokens.
    function test_aHundredComponentsFitOneTransaction() public {
        uint256 n = 100;
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](n);
        address[] memory tokens = new address[](n);
        uint256[] memory prices = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            tokens[i] = address(token);
            _list(address(token));
            specs[i] = _spec(address(token), 100, 1e18);
            prices[i] = i % 2 == 0 ? 110 : 90;
        }

        _coolAll(tokens, address(0));
        uint256 before = gasleft();
        vm.prank(creator);
        WeightedHub wide = WeightedHub(factory.createIndex("Wide", "WIDE", specs, _params()));
        _fits("createIndex", before - gasleft());

        uint256 shares = 2e18;
        uint256[] memory amounts = wide.previewIssue(shares);
        vm.startPrank(alice);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20(tokens[i]).mint(alice, amounts[i]);
            MockERC20(tokens[i]).approve(address(wide), amounts[i]);
        }
        vm.stopPrank();
        _coolAll(tokens, address(wide));
        before = gasleft();
        vm.prank(alice);
        wide.issue(shares, alice);
        _fits("issue", before - gasleft());

        vm.warp(wide.lastRebalance() + wide.MIN_REBALANCE_INTERVAL());
        {
            _coolAll(tokens, address(wide));
            before = gasleft();
            wide.startRebalance(0);
            _fits("startRebalance", before - gasleft());
        }

        (uint256 eta,) = wide.pendingRebalance();
        vm.warp(eta + wide.AUCTION_DURATION() / 2);
        uint256[] memory fill = _onWeights(wide, prices);
        HoldingExecutor holder = new HoldingExecutor();
        for (uint256 i = 0; i < n; ++i) {
            MockERC20(tokens[i]).mint(address(holder), shares);
        }
        _coolAll(tokens, address(wide));
        vm.cool(wide.MATH());
        vm.cool(address(holder));
        before = gasleft();
        holder.execute(wide, fill);
        _fits("executeRebalance", before - gasleft());
        assertEq(wide.rebalanceNonce(), 1);

        _coolAll(tokens, address(wide));
        before = gasleft();
        vm.prank(alice);
        wide.redeem(1e18, alice);
        _fits("redeem", before - gasleft());

        uint256 everyComponent = (1 << n) - 1;
        _coolAll(tokens, address(wide));
        before = gasleft();
        vm.prank(alice);
        wide.redeemSkipping(1e18, alice, everyComponent);
        _fits("redeemSkipping, every component skipped", before - gasleft());
        assertEq(wide.totalSupply(), 0);

        uint256 owed = wide.claimOf(alice, tokens[0]);
        uint256 held = MockERC20(tokens[0]).balanceOf(alice);
        assertGt(owed, 0);
        _coolAll(tokens, address(wide));
        before = gasleft();
        vm.prank(alice);
        wide.claim(tokens[0], alice);
        _fits("claim", before - gasleft());
        assertEq(MockERC20(tokens[0]).balanceOf(alice), held + owed);
    }

    /// @dev Marks the components, the factory, its implementation and `hub` cold, as a transaction of its own finds them.
    function _coolAll(address[] memory tokens, address hub) private {
        for (uint256 i = 0; i < tokens.length; ++i) {
            vm.cool(tokens[i]);
        }
        vm.cool(address(factory));
        vm.cool(factory.IMPLEMENTATION());
        if (hub != address(0)) vm.cool(hub);
    }

    function _fits(string memory path, uint256 used) private {
        emit log_named_uint(path, used);
        assertLt(used, TX_GAS_CAP, path);
    }

    // ---------------------------------------------------------------------
    // XS-3: a keep-mask fill restarts only MIN_REBALANCE_INTERVAL for a rebalance without a mask
    // ---------------------------------------------------------------------

    /// @dev A quarterly index of three legs, BTC at 9,998 bps and two slivers, a million whole shares: a guardian's
    ///      keep-mask fill of the two slivers trades about $25 of a $100M index.
    function _xs3Index() internal returns (WeightedHub quarterly, uint256 interval) {
        interval = factory.MAX_REBALANCE_INTERVAL();
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(btc), 9998, 166_633);
        specs[1] = _spec(address(eth), 1, 5e12);
        specs[2] = _spec(address(usd), 1, 10_000);
        IWeightedIndexFactory.IndexParams memory params = _params();
        params.rebalanceInterval = SafeCast.toUint32(interval);
        quarterly = _create(specs, params);
        _issue(quarterly, alice, 1_000_000e18);
    }

    /// @dev The guardian keeps BTC and its executor fills the two slivers, doubling both, at the auction's last
    ///      second: two basis points of weight gain too little for any earlier bar. Returns the fill's time.
    function _xs3SliverFill(WeightedHub quarterly, uint256 interval) internal returns (uint256 fillTime) {
        vm.warp(quarterly.lastRebalance() + interval);
        vm.prank(guardian);
        quarterly.startRebalance(1);
        (uint256 eta,) = quarterly.pendingRebalance();
        vm.warp(eta + quarterly.AUCTION_DURATION());
        executor.execute(quarterly, _three(166_633, 2 * 5e12, 2 * 10_000), "");
        fillTime = block.timestamp;
        assertEq(quarterly.lastRebalance(), fillTime);
    }

    /// @dev After a sliver fill, anyone may start a rebalance without a mask MIN_REBALANCE_INTERVAL later, not the
    ///      index's 91 days, so the stall outlasts a guardian's replacement by at most that week, as documented.
    function test_XS3_aKeepMaskFillRestartsOnlyTheMinimumIntervalForStrangers() public {
        (WeightedHub quarterly, uint256 interval) = _xs3Index();
        uint256 fillTime = _xs3SliverFill(quarterly, interval);
        uint256 earliest = fillTime + quarterly.MIN_REBALANCE_INTERVAL();
        assertEq(quarterly.earliestRebalance(), earliest);

        vm.warp(earliest - 1);
        assertFalse(quarterly.canStartRebalance());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        quarterly.startRebalance(0);

        vm.warp(earliest);
        assertTrue(quarterly.canStartRebalance(), "a week after the sliver, not a quarter");
        vm.prank(stranger);
        quarterly.startRebalance(0);
        (uint256 eta, uint256 keepMask) = quarterly.pendingRebalance();
        assertEq(eta, earliest + quarterly.REBALANCE_DELAY());
        assertEq(keepMask, 0);
    }

    /// @dev The short restart holds for a start with a mask too, so the guardian can renew a keep around a component
    ///      that cannot move as soon as a stranger could start without one, and not a second before; a fill without a
    ///      mask then restores the index's own interval.
    function test_XS3_theGuardianCanRenewAKeepAWeekOn() public {
        (WeightedHub quarterly, uint256 interval) = _xs3Index();
        uint256 fillTime = _xs3SliverFill(quarterly, interval);
        uint256 earliest = fillTime + quarterly.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        quarterly.startRebalance(1);
        vm.warp(earliest);
        vm.prank(guardian);
        quarterly.startRebalance(1);
        (, uint256 keepMask) = quarterly.pendingRebalance();
        assertEq(keepMask, 1, "the keep is renewed a week on");
        vm.prank(guardian);
        quarterly.cancelRebalance();

        // A fill of every leg puts the index back on its own interval.
        vm.warp(block.timestamp + quarterly.REBALANCE_DELAY());
        vm.prank(stranger);
        quarterly.startRebalance(0);
        (uint256 eta,) = quarterly.pendingRebalance();
        vm.warp(eta);
        uint256[] memory units = quarterly.recordedUnits();
        for (uint256 i = 0; i < 3; ++i) {
            units[i] *= 2;
        }
        executor.execute(quarterly, units, "");
        assertEq(quarterly.earliestRebalance(), block.timestamp + interval, "a fill without a mask: the full interval");
        vm.warp(block.timestamp + quarterly.MIN_REBALANCE_INTERVAL());
        assertFalse(quarterly.canStartRebalance());
    }
}
