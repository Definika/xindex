// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IWeightedMath} from "../src/interfaces/IWeightedMath.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {PythStructs} from "../src/interfaces/pyth/PythStructs.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockSenderBlockToken} from "./mocks/MockAdminTokens.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice Delivers what a fill asks for, then claws one raw unit of a component back out of the index, as an issuer's
///         clawback inside the callback would.
contract ClawingExecutor is IRebalanceExecutor {
    uint256 internal immutable CLAWED;

    constructor(uint256 clawed) {
        CLAWED = clawed;
    }

    function execute(IWeightedHub index, bytes[] calldata priceUpdate) external {
        index.executeRebalance("", priceUpdate);
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

    function execute(IWeightedHub index, bytes[] calldata priceUpdate) external {
        index.executeRebalance("", priceUpdate);
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IWeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) IERC20(t[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}

/// @notice The weighted hub's rebalance: start, notice, auction, prices, settlement and cancellation.
/// @dev The default index (ETH 50%, BTC 30%, USD 20%, $100 a token) with 100 tokens issued. Most tests price ETH at
///      $2,500, which makes a token worth $112.50 and its targets 0.0225 ETH, 0.0005625 BTC and 22.5 USD: the fill sells
///      0.0025 ETH a token, $6.25 of it and a tenth of its units, and buys 0.0000625 BTC and 2.5 USD, $3.75 and $2.50.
///      At the auction's midpoint μ is exactly 1, so the settlement there is exact and pinned to the raw unit. At the
///      starting prices the index is on its weights, and a fill reverts NothingToRebalance (V5-L2).
contract WeightedHubRebalanceTest is WeightedTest {
    WeightedHub index;
    MockWeightedExecutor executor;

    uint256 constant SHARES = 100e18;
    uint256 constant WAD = 1e18;

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
        bytes[] memory live = pyth.liveUpdates(index, keepMask);
        if (keepMask != 0) vm.prank(guardian);
        index.startRebalance(keepMask, live);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + into);
    }

    function _midpoint() internal view returns (uint256) {
        return index.AUCTION_DURATION() / 2;
    }

    function _fill(int64 ethPrice, int64 btcPrice, int64 usdPrice) internal {
        executor.execute(index, "", _updates(index, _ids3(), _prices3(ethPrice, btcPrice, usdPrice)));
    }

    function _units() internal view returns (uint256[] memory units) {
        (, units) = index.components();
    }

    /// @dev Values in USD per raw unit scaled by 1e36, as the hub prices them.
    function _q(int64 price, uint8 decimals) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(int256(price)) * 10 ** (36 - 8 - uint256(decimals));
    }

    // ---------------------------------------------------------------------
    // Start
    // ---------------------------------------------------------------------

    function test_startWaitsForTheInterval() public {
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        assertFalse(index.canStartRebalance());
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0, live);

        vm.warp(earliest);
        assertTrue(index.canStartRebalance());
        bytes[] memory live2 = pyth.liveUpdates(index, 0);
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceStarted(1, 1, stranger, 0, earliest + 2 hours);
        vm.prank(stranger);
        index.startRebalance(0, live2);
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
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, eta + index.AUCTION_DURATION()));
        vm.prank(guardian);
        index.startRebalance(0, live);
    }

    function test_startChecksTheKeepMask() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        bytes[] memory live = pyth.liveUpdates(index, 8);
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 8));
        index.startRebalance(8, live);
        bytes[] memory live2 = pyth.liveUpdates(index, 7);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 7));
        index.startRebalance(7, live2);
        index.startRebalance(4, pyth.liveUpdates(index, 4));
        vm.stopPrank();
        (, uint256 keepMask) = index.pendingRebalance();
        assertEq(keepMask, 4);
    }

    /// @dev V5-L2: a keep mask must leave two components moving. One alone is on its weight among the moving ones, so a
    ///      fill of it traded nothing and only restarted MIN_REBALANCE_INTERVAL: a free stall for the guardian.
    function test_V5L2_aKeepMaskMustLeaveTwoMoving() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        bytes[] memory live = pyth.liveUpdates(index, 6);
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 6));
        index.startRebalance(6, live);
        bytes[] memory live2 = pyth.liveUpdates(index, 3);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.InvalidKeepMask.selector, 3));
        index.startRebalance(3, live2);
        index.startRebalance(1, pyth.liveUpdates(index, 1));
        vm.stopPrank();
    }

    /// @dev V5-L2: a fill on an index already on its weights reverts, so it cannot restart the interval. The reviewer's
    ///      case: ETH tripled, the guardian kept BTC, and the fill of ETH alone moved nothing yet pushed a stranger's
    ///      start a week out.
    function test_V5L2_aFillThatTradesNothingCannotRestartTheInterval() public {
        _open(0, _midpoint());
        uint256 last = index.lastRebalance();
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        index.previewRebalance(_structs3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        executor.execute(index, "", data);
        // Just under a thousandth of the moving value is still nothing: ETH up 0.4% releases $0.10 of $100.20, 0.0998%.
        data = _updates(index, _ids3(), _prices3(2008e8, BTC_PRICE, USD_PRICE));
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        executor.execute(index, "", data);
        assertEq(index.lastRebalance(), last);
        assertEq(index.rebalanceNonce(), 0);
        // Just over it trades: at $2,008.10 it releases 0.101%.
        _fill(2008.1e8, BTC_PRICE, USD_PRICE);
        assertEq(index.rebalanceNonce(), 1);
    }

    /// @dev V5R-1: the minimum trade counts what the fill releases after the turnover cap, not before it. ETH at one
    ///      basis point of the weights but 0.4% of the value must shrink to a fortieth of its units, so the cap lets it
    ///      give up a fifth: the full gap is $0.39 of $100, 0.39%, and the capped release $0.08, 0.08%. Measured before
    ///      the cap, that fill went through, traded 0.08% and restarted the interval. At $3,000 the capped release is
    ///      0.12% and the fill goes through, selling a fifth of the ETH.
    function test_V5R1_theMinimumTradeIsMeasuredAfterTheCap() public {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(eth), 1, 0.0002e18);
        specs[1] = _spec(address(btc), 6000, 0.001e8);
        specs[2] = _spec(address(usd), 3999, 39.6e6);
        WeightedHub skewed = _create(specs);
        _issue(skewed, alice, SHARES);
        vm.warp(skewed.lastRebalance() + skewed.MIN_REBALANCE_INTERVAL());
        skewed.startRebalance(0, pyth.liveUpdates(skewed, 0));
        (uint256 eta,) = skewed.pendingRebalance();
        vm.warp(eta + _midpoint());

        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        skewed.previewRebalance(_structs3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        bytes[] memory data = _updates(skewed, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        executor.execute(skewed, "", data);
        assertEq(skewed.rebalanceNonce(), 0);

        executor.execute(skewed, "", _updates(skewed, _ids3(), _prices3(3000e8, BTC_PRICE, USD_PRICE)));
        assertEq(skewed.rebalanceNonce(), 1);
        (, uint256[] memory units) = skewed.components();
        assertApproxEqAbs(units[0], 0.00016e18, 2, "a fifth of the ETH sold");
    }

    function test_R16_onlyTheOwnerOrGuardianPassesAKeepMask() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        bytes[] memory live = pyth.liveUpdates(index, 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(1, live);
        bytes[] memory live2 = pyth.liveUpdates(index, 1);
        vm.prank(owner);
        index.startRebalance(1, live2);
    }

    /// @dev RX-3: a start reads every moving feed in the fill's window, so a rebalance starts only while each leg's
    ///      market is open. A feed whose market closed hours ago, as a US-hours stock's does overnight, refuses the
    ///      start; the guardian can still start around it with a keep mask, and a kept feed is not read. Without the
    ///      read, a stranger could start in a closed window and leave the reopening as the auction's only fillable
    ///      moment, near MU_MIN.
    function test_RX3_aStartNeedsEveryMovingFeedToPublish() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        uint64 time = uint64(index.priceTime());
        bytes[] memory closed = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        closed[1] = pyth.update(BTC_ID, BTC_PRICE, 0, EXPO, time - 6 hours, time - 6 hours - 1);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        vm.prank(stranger);
        index.startRebalance(0, closed);
        assertEq(index.proposalCount(), 0);

        bytes[] memory open = pyth.liveUpdates(index, 1 << 1);
        vm.prank(guardian);
        index.startRebalance(1 << 1, open);
        assertEq(pyth.lastMinPublishTime(), time);
        assertEq(pyth.lastMaxPublishTime(), block.timestamp - 1);
        bytes32[] memory ids = pyth.lastIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], ETH_ID);
        assertEq(ids[1], USD_ID);
    }

    /// @dev RX-3: the notice and the auction together are shorter than any closure of a market a feed follows. The
    ///      shortest is the 17.5 hours overnight of Pyth's Equity.US feeds (09:30 to 16:00 ET), and an auction started
    ///      at the open ends inside the session. So even a start in a session's last second expires before the next
    ///      open: no fill lands at a reopening near MU_MIN.
    function test_RX3_noAuctionRunsIntoTheNextOpen() public {
        assertLt(index.REBALANCE_DELAY() + index.AUCTION_DURATION(), 17.5 hours);
        assertLe(index.REBALANCE_DELAY() + index.AUCTION_DURATION(), 6.5 hours);
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta - index.REBALANCE_DELAY() + 17.5 hours);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, eta + index.AUCTION_DURATION()));
        executor.execute(index, "", data);
    }

    /// @dev RX-3: a start forwards all of msg.value to Pyth as its fee, as a fill does; nothing stays in the index.
    function test_RX3_aStartPaysPythItsFee() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        pyth.setFee(1);
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.deal(stranger, 3);
        vm.expectRevert(MockPyth.InsufficientFee.selector);
        vm.prank(stranger);
        index.startRebalance{value: 2}(0, live);
        vm.prank(stranger);
        index.startRebalance{value: 3}(0, live);
        assertEq(address(pyth).balance, 3);
        assertEq(address(index).balance, 0, "nothing stays in the index");
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
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(0, live);
        bytes[] memory live2 = pyth.liveUpdates(index, 0);
        vm.prank(owner);
        index.startRebalance(0, live2);
        vm.prank(owner);
        index.cancelRebalance();

        vm.warp(block.timestamp + 2 hours);
        assertTrue(index.canStartRebalance());
        bytes[] memory live3 = pyth.liveUpdates(index, 0);
        vm.prank(stranger);
        index.startRebalance(0, live3);
    }

    function test_XA02_XA16_VR04_anExpiredAuctionHoldsStrangersOffUntilItsDelayPasses() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        uint256 end = eta + index.AUCTION_DURATION();

        vm.warp(end + 1);
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceExpired.selector, end));
        executor.execute(index, "", data);
        assertEq(index.currentMu(), 0);
        assertFalse(index.canStartRebalance());
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(0, live);

        // A cancel of the expired proposal neither shortens nor extends the hold-off.
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), end + 2 hours);

        vm.warp(end + 2 hours);
        assertTrue(index.canStartRebalance());
        bytes[] memory live2 = pyth.liveUpdates(index, 0);
        vm.prank(stranger);
        index.startRebalance(0, live2);
    }

    function test_theOwnerRestartsAtOnceAfterAnExpiry() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.prank(owner);
        index.startRebalance(0, live);
        assertEq(index.proposalCount(), 2);
    }

    // ---------------------------------------------------------------------
    // The auction's clock
    // ---------------------------------------------------------------------

    function test_executeChecksTheAuctionIsOpen() public {
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        vm.expectRevert(IWeightedHub.NoPendingRebalance.selector);
        executor.execute(index, "", data);

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0, pyth.liveUpdates(index, 0));
        (uint256 eta,) = index.pendingRebalance();
        data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceNotReady.selector, eta));
        executor.execute(index, "", data);
        assertEq(index.currentMu(), 0, "not open yet");
    }

    function test_muFallsFromMaxToMinRoundedUp() public {
        _open(0, 0);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(index.currentMu(), 1.02e18);
        vm.warp(eta + 2 hours);
        assertEq(index.currentMu(), 1e18);
        vm.warp(eta + 4 hours);
        assertEq(index.currentMu(), 0.98e18);
        // One second in, the decrement 0.04e18 / 14,400 = 2,777,777,777,777.78 rounds down, so μ rounds up.
        vm.warp(eta + 1);
        assertEq(index.currentMu(), 1.02e18 - 2_777_777_777_777);
    }

    // ---------------------------------------------------------------------
    // Prices
    // ---------------------------------------------------------------------

    /// @dev V5-L1: the hub fixes the window itself, one slot back: from twelve seconds before the block to the second
    ///      before it. It was the start of the previous minute, which an executor knew up to two minutes ahead. A mutant
    ///      that let the executor choose the time, or widened the window, fails here.
    function test_V5L1_theHubAsksPythForTheLastSlot() public {
        _open(0, _midpoint() + 17);
        uint256 time = block.timestamp - 12;
        assertEq(index.priceTime(), time);
        _fill(2500e8, BTC_PRICE, USD_PRICE);
        assertEq(pyth.lastMinPublishTime(), time);
        assertEq(pyth.lastMaxPublishTime(), block.timestamp - 1);
        bytes32[] memory ids = pyth.lastIds();
        assertEq(ids.length, 3);
        assertEq(ids[0], ETH_ID);
        assertEq(ids[1], BTC_ID);
        assertEq(ids[2], USD_ID);
    }

    /// @dev Only each feed's first update at or after the pinned second counts: an executor cannot bring a later one
    ///      it likes better, nor an earlier one.
    function test_onlyTheFirstUpdateOfThePinnedSecondCounts() public {
        _open(0, _midpoint());
        uint64 time = uint64(index.priceTime());
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));

        // A later update of the same feed, whose previous one was already inside the window.
        data[0] = pyth.update(ETH_ID, 2100e8, 0, EXPO, time + 5, time + 2);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        executor.execute(index, "", data);

        // An update from before the window.
        data[0] = pyth.update(ETH_ID, 2100e8, 0, EXPO, time - 1, time - 2);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        executor.execute(index, "", data);

        // An update from the block's own second, after the window.
        data[0] = pyth.update(ETH_ID, 2500e8, 0, EXPO, time + 12, time - 3);
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        executor.execute(index, "", data);

        // The first update at or after the second, even late in its slot, is the one.
        data[0] = pyth.update(ETH_ID, 2500e8, 0, EXPO, time + 11, time - 3);
        executor.execute(index, "", data);
        assertEq(index.rebalanceNonce(), 1);
    }

    function test_theHubChecksWhatPythReturns() public {
        _open(0, _midpoint());
        uint256 time = index.priceTime();
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));

        pyth.setTamper(MockPyth.Tamper.DropLast);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceMismatch.selector, bytes32(0), 0));
        executor.execute(index, "", data);

        pyth.setTamper(MockPyth.Tamper.WrongId);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceMismatch.selector, keccak256("another feed"), time));
        executor.execute(index, "", data);

        pyth.setTamper(MockPyth.Tamper.LateTime);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceMismatch.selector, ETH_ID, time + 12));
        executor.execute(index, "", data);
    }

    function test_theHubRefusesAPriceItCannotUse() public {
        _open(0, _midpoint());
        uint64 time = uint64(index.priceTime());
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));

        data[0] = pyth.update(ETH_ID, 0, 0, EXPO, time, time - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceOutOfRange.selector, address(eth), int64(0), EXPO));
        executor.execute(index, "", data);

        data[0] = pyth.update(ETH_ID, -1, 0, EXPO, time, time - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceOutOfRange.selector, address(eth), int64(-1), EXPO));
        executor.execute(index, "", data);

        data[0] = pyth.update(ETH_ID, 2, 0, 1, time, time - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceOutOfRange.selector, address(eth), int64(2), int32(1)));
        executor.execute(index, "", data);

        data[0] = pyth.update(ETH_ID, ETH_PRICE, 0, -19, time, time - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.PriceOutOfRange.selector, address(eth), ETH_PRICE, int32(-19))
        );
        executor.execute(index, "", data);

        // BTC has 8 decimals, so at exponent 0 a price above 1e17 comes to more than MAX_PRICE.
        data[0] = pyth.update(ETH_ID, 2500e8, 0, EXPO, time, time - 1);
        data[1] = pyth.update(BTC_ID, 1e17 + 1, 0, 0, time, time - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.PriceOutOfRange.selector, address(btc), int64(1e17 + 1), int32(0))
        );
        executor.execute(index, "", data);

        // A confidence interval just wider than 2% of the price.
        data[1] = pyth.update(BTC_ID, BTC_PRICE, 1200e8 + 1, EXPO, time, time - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.PriceUncertain.selector, address(btc), BTC_PRICE, uint64(1200e8 + 1))
        );
        executor.execute(index, "", data);

        // Exactly 2% passes, and so do the extreme exponents.
        data[1] = pyth.update(BTC_ID, BTC_PRICE, 1200e8, EXPO, time, time - 1);
        data[2] = pyth.update(USD_ID, 1e18, 0, -18, time, time - 1);
        executor.execute(index, "", data);
        assertEq(index.rebalanceNonce(), 1);
    }

    function test_thePriceAtTheCeilingIsAccepted() public {
        _open(0, _midpoint());
        PythStructs.Price[] memory prices = _structs3(ETH_PRICE, BTC_PRICE, USD_PRICE);
        prices[1] = PythStructs.Price({price: 1e17, conf: 0, expo: 0, publishTime: 0});
        // 1e17 · 10^(36 − 8) = 1e45 = MAX_PRICE: the price is accepted, not PriceOutOfRange. Every other leg would have
        // to grow a trillionfold, and a growing leg at most doubles per fill, so the fill trades too little (RX-15).
        vm.expectRevert(IWeightedHub.NothingToRebalance.selector);
        index.previewRebalance(prices);
    }

    function test_theFeeGoesToPyth() public {
        _open(0, _midpoint());
        pyth.setFee(1);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        assertEq(pyth.getUpdateFee(data), 3);

        vm.expectRevert(MockPyth.InsufficientFee.selector);
        executor.execute{value: 2}(index, "", data);

        executor.execute{value: 3}(index, "", data);
        assertEq(address(pyth).balance, 3);
        assertEq(address(index).balance, 0, "nothing stays in the index");
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    function test_aMidpointFillIsExact() public {
        _open(0, _midpoint());
        uint256 time = index.priceTime();
        uint256[] memory units = new uint256[](3);
        units[0] = 0.0225e18;
        units[1] = 0.0005625e8;
        units[2] = 22.5e6;
        uint256[] memory out = new uint256[](3);
        out[0] = 0.0025e18 * 100;
        uint256[] memory in_ = new uint256[](3);
        in_[1] = 0.0000625e8 * 100;
        in_[2] = 2.5e6 * 100;
        uint256[] memory prices = new uint256[](3);
        prices[0] = 2.5e21;
        prices[1] = 6e32;
        prices[2] = 1e30;

        vm.expectEmit(address(index));
        emit IWeightedHub.Rebalanced(1, 1, address(executor), 1e18, time, prices, units, out, in_);
        _fill(2500e8, BTC_PRICE, USD_PRICE);

        uint256[] memory now_ = _units();
        assertEq(now_[0], units[0]);
        assertEq(now_[1], units[1]);
        assertEq(now_[2], units[2]);
        assertEq(eth.balanceOf(address(executor)), out[0]);
        assertEq(btc.balanceOf(address(index)), (BTC_UNITS + 0.0000625e8) * 100);
        assertEq(usd.balanceOf(address(index)), 22.5e6 * 100);
        assertEq(index.rebalanceNonce(), 1);
        assertEq(index.lastRebalance(), block.timestamp);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(executor.calls(), 1);
    }

    function test_theAuctionEndsScaleTheBoughtLegs() public {
        _open(0, 0);
        (uint256 mu, uint256[] memory units,, uint256[] memory in_) =
            index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertEq(mu, 1.02e18);
        assertEq(units[0], 0.0225e18, "a sold leg goes exactly to its target");
        assertEq(units[1], BTC_UNITS + 6375, "1.02 x 6,250");
        assertEq(units[2], USD_UNITS + 2.55e6);
        assertEq(in_[1], 6375 * 100);

        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        (mu, units,, in_) = index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertEq(mu, 0.98e18);
        assertEq(units[1], BTC_UNITS + 6125);
        assertEq(units[2], USD_UNITS + 2.45e6);
    }

    /// @dev Rounding goes the holders' way: a growing leg's step rounds up even when μ makes it fractional.
    function test_DA01_aGrowingStepRoundsUp() public {
        _open(0, 1);
        (uint256 mu, uint256[] memory units,,) = index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        // 6,250 · μ / 1e18 = 6,374.997106…, rounded up.
        assertEq(Math.mulDiv(6250, mu, 1e18), 6374);
        assertEq(units[1], BTC_UNITS + 6375);
    }

    /// @dev The growth factor on the bought legs, μ times the share of the way, rounds up too. Two 18-decimal dollar
    ///      tokens at 50% each, 1,000 a token; X triples, so a token is worth $4,000 and X's target is 666.67: giving up
    ///      333.33 of its 1,000 units passes the 20% cap, so every leg moves 0.6 of the way. One second in, μ · 0.6 is
    ///      611,999,722,222,222,222.8e-18, so Y grows by 1,000 times its ceiling, not its floor.
    function test_theGrowthFactorRoundsUp() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        MockERC20 y = new MockERC20("Y", "Y", 18);
        _list(address(x), keccak256("X/USD"));
        _list(address(y), keccak256("Y/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(x), 5000, 1000e18);
        specs[1] = _spec(address(y), 5000, 1000e18);
        vm.prank(creator);
        WeightedHub pair = WeightedHub(factory.createIndex("Pair", "PAIR", specs, _params()));
        _issue(pair, alice, 1e18);
        vm.warp(pair.lastRebalance() + pair.MIN_REBALANCE_INTERVAL());
        pair.startRebalance(0, pyth.liveUpdates(pair, 0));
        (uint256 eta,) = pair.pendingRebalance();
        vm.warp(eta + 1);

        PythStructs.Price[] memory prices = new PythStructs.Price[](2);
        prices[0] = PythStructs.Price({price: 3e8, conf: 0, expo: EXPO, publishTime: 0});
        prices[1] = PythStructs.Price({price: 1e8, conf: 0, expo: EXPO, publishTime: 0});
        (uint256 mu, uint256[] memory units,,) = pair.previewRebalance(prices);
        assertEq(mu, 1_019_997_222_222_222_223);
        assertEq(units[1], 1000e18 + 611_998_333_333_333_334_000);
        // X moves 0.6 of its 333.33 down, rounded down, which is just under a fifth of its units.
        assertEq(units[0], 1000e18 - 199_999_999_999_999_999_999);
    }

    /// @dev V5-M2: the cap counts units. ETH at ten times its price puts its target at 0.01375 a token, 45% below its
    ///      0.025; giving up more than a fifth of its units passes the cap, so every leg moves 0.2 / 0.45 of the way,
    ///      rounded down, and ETH leaves at just under a fifth of its units.
    function test_V5M2_theTurnoverCapCountsUnits() public {
        _open(0, _midpoint());
        (, uint256[] memory units, uint256[] memory out, uint256[] memory in_) =
            index.previewRebalance(_structs3(20_000e8, BTC_PRICE, USD_PRICE));
        assertEq(units[0], 22_500_000_000_000_001, "0.025 less 0.01125 times 2/9, rounded down");
        // BTC's target is 165 / 60,000 = 0.00275, 4.5 times its units above; USD's 110, 90 above. The turnover cap
        // alone would move every leg 4/9 of the way; the growth cap lets each grower at most double, so 2/9 (RX-15).
        assertEq(units[1], 2 * BTC_UNITS);
        assertEq(units[2], 2 * USD_UNITS);
        assertLe(out[0], ETH_UNITS * 100 / 5, "never more than a fifth of the component's units");
        assertEq(out[0], (ETH_UNITS - units[0]) * 100);
        assertGt(in_[1], 0);
    }

    /// @dev V5-M2, the reviewer's case. A and B both truly $1, weights 1% and 99%, created far from them at 99 A and 1 B
    ///      a token, 100 tokens. Two feeds lie: A at $0.0333 and B at $30. The value cap, measured in those prices,
    ///      let the fill send out 89 A a token for 0.097 B, 89% of the index. The unit cap sends out at most a fifth of
    ///      A, whatever the prices say.
    function test_V5M2_wrongPricesTakeAtMostAFifthOfEachLeg() public {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        _list(address(a), keccak256("A/USD"));
        _list(address(b), keccak256("B/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(a), 100, 99e18);
        specs[1] = _spec(address(b), 9900, 1e18);
        vm.prank(creator);
        WeightedHub skewed = WeightedHub(factory.createIndex("Skewed", "SKW", specs, _params()));
        _issue(skewed, alice, 100e18);
        vm.warp(skewed.lastRebalance() + skewed.MIN_REBALANCE_INTERVAL());
        skewed.startRebalance(0, pyth.liveUpdates(skewed, 0));
        (uint256 eta,) = skewed.pendingRebalance();
        vm.warp(eta + skewed.AUCTION_DURATION());

        PythStructs.Price[] memory prices = new PythStructs.Price[](2);
        prices[0] = PythStructs.Price({price: 0.0333e8, conf: 0, expo: EXPO, publishTime: 0});
        prices[1] = PythStructs.Price({price: 30e8, conf: 0, expo: EXPO, publishTime: 0});
        (,, uint256[] memory out,) = skewed.previewRebalance(prices);
        assertLe(out[0], 99e18 * 100 / 5, "at most a fifth of A leaves");
        assertGt(out[0], 99e18 * 100 / 5 - 1e6, "and the cap is what binds");
    }

    /// @dev On an empty index nothing leaves, so nobody is paid: the fill settles at MU_MAX whatever the clock says.
    function test_R14_XA27_anEmptyIndexSettlesAtMuMax() public {
        vm.prank(alice);
        index.redeem(SHARES, alice);
        _open(0, index.AUCTION_DURATION());
        (uint256 mu, uint256[] memory units, uint256[] memory out, uint256[] memory in_) =
            index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertEq(mu, 1.02e18);
        assertEq(units[1], BTC_UNITS + 6375);
        assertEq(out[0], 0);
        assertEq(in_[1], 0);
        _fill(2500e8, BTC_PRICE, USD_PRICE);
        assertEq(_units()[1], BTC_UNITS + 6375);
    }

    /// @dev The settlement arithmetic lives in `WeightedMath`, deployed by the factory with the implementation and
    ///      fixed in it; its constants are the hub's own, which every executor reads from the hub.
    function test_theMathConstantsAreTheHubs() public view {
        IWeightedMath math = IWeightedMath(index.MATH());
        assertEq(index.MATH(), WeightedHub(factory.IMPLEMENTATION()).MATH());
        assertGt(index.MATH().code.length, 0);
        assertEq(math.MU_MAX(), index.MU_MAX());
        assertEq(math.MAX_TURNOVER(), index.MAX_TURNOVER());
        assertEq(math.MIN_TRADE(), index.MIN_TRADE());
    }

    function test_previewMatchesTheFill() public {
        _open(0, 50 minutes + 7);
        (uint256 mu, uint256[] memory units, uint256[] memory out, uint256[] memory in_) =
            index.previewRebalance(_structs3(2345e8, 71_234e8, 0.99e8));
        _fill(2345e8, 71_234e8, 0.99e8);
        assertEq(executor.lastAmountsOut(), out);
        assertEq(executor.lastAmountsIn(), in_);
        assertEq(_units(), units);
        assertLt(mu, 1.02e18);
    }

    function test_executorDataPassesThrough() public {
        _open(0, _midpoint());
        executor.execute(index, "hello", _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE)));
        assertEq(executor.lastData(), "hello");
    }

    // ---------------------------------------------------------------------
    // Keep mask
    // ---------------------------------------------------------------------

    /// @dev A kept component is not priced, not read and not moved; the others share out their own value by their own
    ///      weights.
    function test_R08_DA14_RT01_aKeptComponentIsNeitherPricedNorRead() public {
        MockPausableToken frozen = new MockPausableToken("Frozen", "FRZ", 18);
        _list(address(frozen), keccak256("FRZ/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(btc), 3000, BTC_UNITS);
        specs[2] = _spec(address(frozen), 2000, 20e18);
        vm.prank(creator);
        WeightedHub three = WeightedHub(factory.createIndex("Three", "THR", specs, _params()));
        _issue(three, alice, SHARES);
        frozen.setReadsBroken(true);

        vm.warp(three.lastRebalance() + three.MIN_REBALANCE_INTERVAL());
        bytes[] memory live = pyth.liveUpdates(three, 4);
        vm.prank(guardian);
        three.startRebalance(4, live);
        (uint256 eta,) = three.pendingRebalance();
        vm.warp(eta + three.AUCTION_DURATION() / 2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ETH_ID;
        ids[1] = BTC_ID;
        int64[] memory prices = new int64[](2);
        prices[0] = 4000e8;
        prices[1] = BTC_PRICE;
        executor.execute(three, "", _updates(three, ids, prices));

        assertEq(pyth.lastIds().length, 2, "the kept feed is not asked for");
        (, uint256[] memory units) = three.components();
        // ETH $100 and BTC $30 share $130 at 5:3: ETH 81.25 / 4,000 = 0.0203125, BTC 48.75 / 60,000 = 0.0008125.
        assertEq(units[0], 0.0203125e18);
        assertEq(units[1], 0.0008125e8);
        assertEq(units[2], 20e18, "untouched");
    }

    function test_aKeptComponentsPriceEntryIsIgnoredInThePreview() public {
        _open(4, _midpoint());
        PythStructs.Price[] memory prices = _structs3(2500e8, BTC_PRICE, 0);
        (, uint256[] memory units,,) = index.previewRebalance(prices);
        assertEq(units[2], USD_UNITS);
    }

    // ---------------------------------------------------------------------
    // Executors
    // ---------------------------------------------------------------------

    function test_R10_aShortDeliveryReverts() public {
        _open(0, _midpoint());
        executor.setMode(MockWeightedExecutor.Mode.Short);
        executor.setShortComponent(2);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        uint256 required = 22.5e6 * 100;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(usd), required - 1, required)
        );
        executor.execute(index, "", data);
    }

    /// @dev Surplus the index already held stays with the holders: an executor cannot deliver that much less.
    function test_R21_XA28_aDonationDoesNotPayForTheFill() public {
        _open(0, _midpoint());
        usd.mint(address(index), 5e6);
        executor.setMode(MockWeightedExecutor.Mode.Short);
        executor.setShortComponent(2);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        uint256 required = 22.5e6 * 100 + 5e6;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(usd), required - 1, required)
        );
        executor.execute(index, "", data);
    }

    function test_VR03_aNoopExecutorReverts() public {
        _open(0, _midpoint());
        executor.setMode(MockWeightedExecutor.Mode.Noop);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        vm.expectRevert(
            abi.encodeWithSelector(
                IWeightedHub.RebalanceUnderfunded.selector, address(btc), BTC_UNITS * 100, 0.0005625e8 * 100
            )
        );
        executor.execute(index, "", data);
    }

    function test_DA13_theBoundedFill() public {
        _open(0, _midpoint());
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        uint256[] memory bounds = new uint256[](2);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        executor.executeBounded(index, "", data, bounds);

        bounds = new uint256[](3);
        bounds[1] = 0.0000625e8 * 100;
        bounds[2] = 2.5e6 * 100 - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceMovedOn.selector, address(usd), 2.5e6 * 100, bounds[2])
        );
        executor.executeBounded(index, "", data, bounds);

        bounds[2] = 2.5e6 * 100;
        executor.executeBounded(index, "", data, bounds);
        assertEq(index.rebalanceNonce(), 1);
    }

    function test_theBoundedFillTakesValue() public {
        _open(0, _midpoint());
        pyth.setFee(1);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        uint256[] memory bounds = new uint256[](3);
        bounds[1] = type(uint256).max;
        bounds[2] = type(uint256).max;
        executor.executeBounded{value: 3}(index, "", data, bounds);
        assertEq(address(pyth).balance, 3);
    }

    function test_R11_everyEntryPointIsGuardedDuringTheCallback() public {
        _open(0, _midpoint());
        executor.setMode(MockWeightedExecutor.Mode.Reentrant);
        _fill(2500e8, BTC_PRICE, USD_PRICE);
        bytes[] memory errors = executor.reentryErrors();
        assertEq(errors.length, 10, "every entry point that mints, burns, pays, accrues or rebalances (XS-18)");
        for (uint256 i = 0; i < errors.length; ++i) {
            assertEq(errors[i], abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        }
        assertEq(index.rebalanceNonce(), 1);
    }

    function test_pythCannotReenter() public {
        _open(0, _midpoint());
        pyth.setReenter(address(index), abi.encodeCall(IIndexHub.redeem, (1, alice)));
        _fill(2500e8, BTC_PRICE, USD_PRICE);
        assertEq(pyth.reenterResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    /// @dev A price low enough to ask for more units than uint96 holds stops the fill rather than wrapping: an 18-decimal
    ///      token at exponent -18 and price 1 is worth 1e-36 dollars a raw unit.
    /// @dev V5-L3: units grow as a component's relative price falls, and fixed weights keep buying it, so a coin that
    ///      collapses far enough asks for more units than uint96 holds. That stops the fill rather than wrapping; the
    ///      guardian then keeps the component, and holders can move to a new index. A known limitation, documented.
    /// @dev A growing leg at most doubles per fill (RX-15), so no single fill takes a component created within MAX_UNITS
    ///      past 96 bits. Units already near the top still stop the fill rather than wrap, and the math itself stops,
    ///      so previewRebalance never returns units executeRebalance could not write (V5-L3, RX-61).
    function test_V5L3_RX61_unitsBeyondUint96StopTheFill() public {
        uint256 top = type(uint96).max;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 10e18;
        prices[1] = 1e18;
        uint256[] memory units = new uint256[](2);
        units[0] = top / 2;
        units[1] = top * 9 / 10;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        IWeightedMath math = IWeightedMath(index.MATH());
        uint256 mu = index.MU_MAX();
        vm.expectPartialRevert(SafeCast.SafeCastOverflowedUintDowncast.selector);
        math.settlement(mu, prices, 1e18, 1e18, units, weights, 0);
    }

    /// @dev Tether Gold blocks only its sender. Once it blocks the index, the index's XAUT cannot leave, yet an executor
    ///      can still deliver more of it. A fill that grows that leg would move good legs into a leg no holder can take
    ///      out, so it reverts; the guardian keeps the leg instead (RX-12).
    function test_RX12_aFillCannotBuyALegTheIndexCannotSend() public {
        MockSenderBlockToken gold = new MockSenderBlockToken(owner);
        _list(address(gold), keccak256("XAU/USD"));
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](3);
        specs[0] = _spec(address(eth), 5000, ETH_UNITS);
        specs[1] = _spec(address(btc), 3000, BTC_UNITS);
        specs[2] = _spec(address(gold), 2000, 20e18);
        vm.prank(creator);
        WeightedHub three = WeightedHub(factory.createIndex("Gold", "GLD", specs, _params()));
        _issue(three, alice, SHARES);
        gold.addBlackList(address(three));

        vm.warp(three.lastRebalance() + three.MIN_REBALANCE_INTERVAL());
        three.startRebalance(0, pyth.liveUpdates(three, 0));
        (uint256 eta,) = three.pendingRebalance();
        vm.warp(eta + three.AUCTION_DURATION() / 2);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = ETH_ID;
        ids[1] = BTC_ID;
        ids[2] = keccak256("XAU/USD");
        int64[] memory prices = new int64[](3);
        prices[0] = 2200e8;
        prices[1] = BTC_PRICE;
        prices[2] = 0.9e8;
        bytes[] memory data = _updates(three, ids, prices);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.CannotSendOut.selector, address(gold)));
        executor.execute(three, "", data);

        // Unblocked, the same fill settles.
        gold.removeBlackList(address(three));
        executor.execute(three, "", data);
        assertEq(three.rebalanceNonce(), 1);
    }

    /// @dev A price further than MAX_EMA_DEVIATION from the update's own moving average, as a push of a few seconds on
    ///      thin venues leaves it, cannot set a fill's price; at the bound it can (RX-27).
    function test_RX27_aPriceFarFromItsAverageIsRefused() public {
        _open(0, _midpoint());
        uint64 time = uint64(index.priceTime());
        bytes[] memory data = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, USD_PRICE));
        int64 average = 2000e8;
        int64 high = 2100e8 + 1; // 5% above the average, and one more
        data[0] = pyth.updateWithEma(ETH_ID, high, EXPO, average, EXPO, time, time - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceOffAverage.selector, address(eth), high, average));
        executor.execute(index, "", data);

        int64 low = 1900e8 - 1;
        data[0] = pyth.updateWithEma(ETH_ID, low, EXPO, average, EXPO, time, time - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceOffAverage.selector, address(eth), low, average));
        executor.execute(index, "", data);

        data[0] = pyth.updateWithEma(ETH_ID, ETH_PRICE, EXPO, ETH_PRICE, EXPO - 1, time, time - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.PriceOffAverage.selector, address(eth), ETH_PRICE, ETH_PRICE)
        );
        executor.execute(index, "", data);

        data[0] = pyth.updateWithEma(ETH_ID, ETH_PRICE, EXPO, 0, EXPO, time, time - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.PriceOffAverage.selector, address(eth), ETH_PRICE, 0));
        executor.execute(index, "", data);

        data[0] = pyth.updateWithEma(ETH_ID, 2100e8, EXPO, average, EXPO, time, time - 1);
        executor.execute(index, "", data);
        assertEq(index.rebalanceNonce(), 1, "exactly 5% off settles");
    }

    /// @dev ETH falls 90%, as a coin whose issuer mints and dumps it would. Its target is 5.5 times its units, but a
    ///      growing leg at most doubles per fill, so every leg moves 2/9 of the way: the others give up a tenth of their
    ///      units, where the turnover cap alone would have let the fill take a fifth (RX-15).
    function test_RX15_aCollapsedLegDrawsAtMostItsOwnValuePerFill() public {
        _open(0, _midpoint());
        (, uint256[] memory units, uint256[] memory out,) =
            index.previewRebalance(_structs3(200e8, BTC_PRICE, USD_PRICE));
        assertEq(units[0], 2 * ETH_UNITS, "ETH at most doubles");
        assertEq(units[1], 45_001, "BTC gives up a tenth, not a fifth");
        assertEq(units[2], 18_000_001, "USD likewise");
        assertEq(out[0], 0);
        // For 100 tokens the index gives up about the $500 of ETH it held, in micro-dollars, where the turnover cap
        // alone would have let one fill take twice that.
        uint256 valueOut = out[1] * 60_000e6 / 1e8 + out[2];
        assertApproxEqRel(valueOut, 500e6, 0.001e18);
    }

    // ---------------------------------------------------------------------
    // The backing post-check and each leg's rounding, carried from v4's hub
    // ---------------------------------------------------------------------

    /// @dev CR-I30: the post-check reads again every leg that moved. A raw unit of a bought component clawed from the
    ///      index before the fill leaves it a unit short of the backing it owes, whatever the executor delivers.
    function test_CRI30_aSettlementStillDemandsTheBackingItOwes() public {
        _open(0, _midpoint());
        (, uint256[] memory units,, uint256[] memory in_) =
            index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertGt(in_[1], 0, "BTC is bought");
        btc.burn(address(index), 1); // the issuer's clawback
        uint256 required = SHARES * units[1] / WAD;
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(btc), required - 1, required)
        );
        executor.execute(index, "", data);
    }

    /// @dev CR-I30 and VR-06: the `+ totalClaims` in the backing term. With a claim open on the bought component, a
    ///      clawed unit there is caught only if the claim is counted.
    function test_VR06_CRI30_theBackingTermCountsOpenClaims() public {
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 1 << 1); // leaves a token's BTC in the index as alice's claim
        assertEq(index.totalClaims(address(btc)), BTC_UNITS);
        _open(0, _midpoint());
        (, uint256[] memory units,, uint256[] memory in_) =
            index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertGt(in_[1], 0);
        btc.burn(address(index), 1);
        uint256 required = index.totalSupply() * units[1] / WAD + index.totalClaims(address(btc));
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(btc), required - 1, required)
        );
        executor.execute(index, "", data);
    }

    /// @dev CR-I30, the sold legs: the post-check reads again a leg the index only sold.
    function test_CRI30_aSoldLegIsCheckedAgainAfterTheCallback() public {
        _open(0, _midpoint());
        (, uint256[] memory units, uint256[] memory out, uint256[] memory in_) =
            index.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertGt(out[0], 0, "ETH is sold");
        assertEq(in_[0], 0, "and receives nothing");
        uint256 required = SHARES * units[0] / WAD;
        ClawingExecutor clawing = new ClawingExecutor(0);
        bytes[] memory data = _updates(index, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(eth), required - 1, required)
        );
        clawing.execute(index, data);
    }

    /// @dev RT-12 and SA-07. On a supply under one index token a leg's change in backing is a fraction of a raw unit. As
    ///      a difference of floored backings a shrinking leg released its whole raw unit while no growing leg asked for
    ///      one, so an executor that delivered nothing was paid. Each leg rounds its own change the holders' way:
    ///      nothing leaves, the settlement falls back to MU_MAX, and each growing leg asks for its raw unit, which an
    ///      empty executor cannot deliver.
    function test_RT12_SA07_anEmptyExecutorIsPaidNothingOnASubTokenSupply() public {
        vm.prank(creator);
        WeightedHub dust = WeightedHub(factory.createIndex("Dust", "DUST", _defaultSpecs(), _params()));
        // Forty wei of shares: exactly one raw unit of ETH, and one of BTC and USD, rounded up. A tenth of the ETH
        // leaves, which as a difference of floored backings, 1 - 0, was the whole raw unit.
        _issue(dust, alice, 40);
        assertEq(eth.balanceOf(address(dust)), 1);
        vm.warp(dust.lastRebalance() + dust.MIN_REBALANCE_INTERVAL());
        dust.startRebalance(0, pyth.liveUpdates(dust, 0));
        (uint256 eta,) = dust.pendingRebalance();
        vm.warp(eta + 2 hours);

        (uint256 mu, uint256[] memory units, uint256[] memory out, uint256[] memory in_) =
            dust.previewRebalance(_structs3(2500e8, BTC_PRICE, USD_PRICE));
        assertEq(mu, dust.MU_MAX(), "nothing leaves, so the settlement is taken at the top");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(out[i], 0, "no leg releases a raw unit for a fraction of one");
        }
        assertLt(units[0], ETH_UNITS, "ETH still shrinks");
        assertGt(units[1], BTC_UNITS, "and BTC grows");
        assertEq(in_[1], 1, "asking for its raw unit, rounded up");
        assertEq(in_[2], 1);

        bytes[] memory data = _updates(dust, _ids3(), _prices3(2500e8, BTC_PRICE, USD_PRICE));
        executor.setMode(MockWeightedExecutor.Mode.Noop);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceUnderfunded.selector, address(btc), 1, 2));
        executor.execute(dust, "", data);
        executor.setMode(MockWeightedExecutor.Mode.Honest);
        executor.execute(dust, "", data);
        assertEq(eth.balanceOf(address(executor)), 0, "an honest executor is paid nothing either");
        assertEq(dust.rebalanceNonce(), 1);
    }

    // ---------------------------------------------------------------------
    // Bounds
    // ---------------------------------------------------------------------

    /// @dev At the settling prices, the executor always delivers at least μ times the value it takes, and no fill sends
    ///      out more than MAX_TURNOVER of any component's units.
    function testFuzz_R04_theExecutorDeliversMuTimesWhatItTakes(
        uint256 ethPrice,
        uint256 btcPrice,
        uint256 usdPrice,
        uint256 into,
        uint256 shares
    ) public {
        ethPrice = bound(ethPrice, 1e8, 100_000e8);
        btcPrice = bound(btcPrice, 1000e8, 1_000_000e8);
        usdPrice = bound(usdPrice, 0.5e8, 2e8);
        into = bound(into, 0, index.AUCTION_DURATION());
        shares = bound(shares, 1, 1e24);
        _issue(index, stranger, shares);
        _open(0, into);

        // forge-lint: disable-next-line(unsafe-typecast)
        PythStructs.Price[] memory prices =
            _structs3(int64(int256(ethPrice)), int64(int256(btcPrice)), int64(int256(usdPrice)));
        uint256 mu;
        uint256[] memory out;
        uint256[] memory in_;
        try index.previewRebalance(prices) returns (
            uint256 mu_, uint256[] memory, uint256[] memory o, uint256[] memory i_
        ) {
            (mu, out, in_) = (mu_, o, i_);
        } catch (bytes memory reason) {
            // Prices this close to the starting ones leave the index on its weights.
            assertEq(bytes4(reason), IWeightedHub.NothingToRebalance.selector);
            return;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256[3] memory q =
            [_q(int64(int256(ethPrice)), 18), _q(int64(int256(btcPrice)), 8), _q(int64(int256(usdPrice)), 6)];
        uint256 valueOut = 0;
        uint256 valueIn = 0;
        uint256[] memory units = _units();
        uint256 supply = index.totalSupply();
        for (uint256 i = 0; i < 3; ++i) {
            valueOut += out[i] * q[i];
            valueIn += in_[i] * q[i];
            assertLe(out[i] * WAD, units[i] * supply / WAD * index.MAX_TURNOVER(), "a fifth of a leg's units at most");
        }
        assertGe(valueIn * WAD, valueOut * mu, "at least mu times what leaves");
    }

    /// @dev V5-M2: whatever prices Pyth reports, and however far from its weights the index sits, a fill sends out at
    ///      most MAX_TURNOVER of each component's units: what a lying feed can take is bounded in the holders' own
    ///      coins, not in its own prices.
    function testFuzz_V5M2_noPriceTakesMoreThanAFifthOfALeg(
        uint256 ethPrice,
        uint256 btcPrice,
        uint256 usdPrice,
        uint256 ethUnits,
        uint256 btcUnits
    ) public {
        ethPrice = bound(ethPrice, 1, 1e17);
        btcPrice = bound(btcPrice, 1, 1e17);
        usdPrice = bound(usdPrice, 1, 1e17);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        specs[0].units = bound(ethUnits, 1e4, 1e24);
        specs[1].units = bound(btcUnits, 1e4, 1e12);
        vm.prank(alice);
        WeightedHub skewed = WeightedHub(factory.createIndex("Skewed", "SKW", specs, _params()));
        _issue(skewed, alice, 7e18);
        vm.warp(skewed.lastRebalance() + skewed.MIN_REBALANCE_INTERVAL());
        skewed.startRebalance(0, pyth.liveUpdates(skewed, 0));
        (uint256 eta,) = skewed.pendingRebalance();
        vm.warp(eta + skewed.AUCTION_DURATION());

        // forge-lint: disable-next-line(unsafe-typecast)
        PythStructs.Price[] memory prices =
            _structs3(int64(int256(ethPrice)), int64(int256(btcPrice)), int64(int256(usdPrice)));
        try skewed.previewRebalance(prices) returns (
            uint256, uint256[] memory, uint256[] memory out, uint256[] memory
        ) {
            (, uint256[] memory units) = skewed.components();
            for (uint256 i = 0; i < 3; ++i) {
                assertLe(out[i], units[i] * 7 / 5, "a fifth of the leg's units, for 7 tokens");
            }
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IWeightedHub.NothingToRebalance.selector);
        }
    }

    /// @dev Within moves the unit cap lets one fill finish, a fill at μ = 1 leaves every weight on target to within
    ///      rounding.
    function testFuzz_aMidpointFillLandsOnTheWeights(uint256 ethPrice, uint256 btcPrice) public {
        ethPrice = bound(ethPrice, 1700e8, 2500e8);
        btcPrice = bound(btcPrice, 50_000e8, 70_000e8);
        _open(0, _midpoint());
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 e = int64(int256(ethPrice));
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 b = int64(int256(btcPrice));
        try index.previewRebalance(_structs3(e, b, USD_PRICE)) {}
        catch (bytes memory reason) {
            assertEq(bytes4(reason), IWeightedHub.NothingToRebalance.selector);
            return;
        }
        _fill(e, b, USD_PRICE);
        uint256[] memory units = _units();
        uint256[3] memory v = [units[0] * _q(e, 18), units[1] * _q(b, 8), units[2] * _q(USD_PRICE, 6)];
        uint256 total = v[0] + v[1] + v[2];
        // Within one raw unit of BTC, worth up to $0.0008 of a $100 token, of each weight.
        assertApproxEqRel(v[0] * 10_000, total * 5000, 1e14);
        assertApproxEqRel(v[1] * 10_000, total * 3000, 1e14);
        assertApproxEqRel(v[2] * 10_000, total * 2000, 1e14);
    }

    /// @dev Repeated fills at μ = 1 through a price path converge on the weights rather than drift from them.
    function test_repeatedFillsFollowThePrices() public {
        int64[5] memory path = [int64(2400e8), 1900e8, 2300e8, 2000e8, 2200e8];
        for (uint256 k = 0; k < path.length; ++k) {
            _open(0, _midpoint());
            _fill(path[k], BTC_PRICE, USD_PRICE);
        }
        uint256[] memory units = _units();
        uint256 ethValue = units[0] * _q(path[4], 18);
        uint256 total = ethValue + units[1] * _q(BTC_PRICE, 8) + units[2] * _q(USD_PRICE, 6);
        assertApproxEqRel(ethValue * 2, total, 1e14);
        assertEq(index.rebalanceNonce(), 5);
    }

    // ---------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------

    /// @dev EIP-7825's cap on a transaction's gas.
    uint256 constant TX_GAS_CAP = 1 << 24;

    /// @dev Every hub path at a hundred components fits EIP-7825's 2^24 cap, each measured as the transaction Foundry
    ///      makes of the call, with every account it touches cold. The settlement is measured as the fork suite measures
    ///      it, with Pyth's parse mocked and an executor that already holds the tokens, so its figure is the hub's own
    ///      work and the transfers: Pyth's real parse checks signatures and a Merkle proof and charges calldata for every
    ///      feed, and the listed tokens transfer dearer than MockERC20, so a fill of a hundred real legs has much less
    ///      room than this shows. It is measured against Pyth's contract on a real update before mainnet.
    function test_aHundredComponentsFitOneTransaction() public {
        uint256 n = 100;
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](n);
        address[] memory tokens = new address[](n);
        bytes32[] memory ids = new bytes32[](n);
        int64[] memory prices = new int64[](n);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            tokens[i] = address(token);
            ids[i] = keccak256(abi.encode("T", i));
            _list(address(token), ids[i]);
            specs[i] = _spec(address(token), 100, 1e18);
            prices[i] = i % 2 == 0 ? int64(1.1e8) : int64(0.9e8);
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
            bytes[] memory live = pyth.liveUpdates(wide, 0);
            _coolAll(tokens, address(wide));
            before = gasleft();
            wide.startRebalance(0, live);
            _fits("startRebalance", before - gasleft());
        }

        (uint256 eta,) = wide.pendingRebalance();
        vm.warp(eta + wide.AUCTION_DURATION() / 2);
        bytes[] memory data = _updates(wide, ids, prices);
        PythStructs.PriceFeed[] memory feeds = new PythStructs.PriceFeed[](n);
        for (uint256 i = 0; i < n; ++i) {
            (feeds[i],) = abi.decode(data[i], (PythStructs.PriceFeed, uint64));
        }
        vm.mockCall(
            address(pyth), abi.encodeWithSelector(MockPyth.parsePriceFeedUpdatesUnique.selector), abi.encode(feeds)
        );
        HoldingExecutor holder = new HoldingExecutor();
        for (uint256 i = 0; i < n; ++i) {
            MockERC20(tokens[i]).mint(address(holder), shares);
        }
        _coolAll(tokens, address(wide));
        vm.cool(address(pyth));
        vm.cool(address(holder));
        before = gasleft();
        holder.execute(wide, data);
        _fits("executeRebalance", before - gasleft());
        assertEq(wide.rebalanceNonce(), 1);
        vm.clearMockedCalls();

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

    function _fits(string memory path, uint256 used) private pure {
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

    /// @dev The guardian keeps BTC and its executor fills the two slivers at `eta`; returns the fill's time.
    function _xs3SliverFill(WeightedHub quarterly, uint256 interval) internal returns (uint256 fillTime) {
        vm.warp(quarterly.lastRebalance() + interval);
        bytes[] memory live = pyth.liveUpdates(quarterly, 1);
        vm.prank(guardian);
        quarterly.startRebalance(1, live);
        (uint256 eta,) = quarterly.pendingRebalance();
        vm.warp(eta);
        uint64 time = uint64(quarterly.priceTime());
        bytes[] memory data = new bytes[](2);
        data[0] = pyth.update(ETH_ID, 2010e8, 0, EXPO, time, time - 1);
        data[1] = pyth.update(USD_ID, USD_PRICE, 0, EXPO, time, time - 1);
        executor.execute(quarterly, "", data);
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
        bytes[] memory live = pyth.liveUpdates(quarterly, 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        quarterly.startRebalance(0, live);

        vm.warp(earliest);
        assertTrue(quarterly.canStartRebalance(), "a week after the sliver, not a quarter");
        bytes[] memory live2 = pyth.liveUpdates(quarterly, 0);
        vm.prank(stranger);
        quarterly.startRebalance(0, live2);
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
        bytes[] memory live = pyth.liveUpdates(quarterly, 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalanceTooSoon.selector, earliest));
        quarterly.startRebalance(1, live);
        vm.warp(earliest);
        bytes[] memory live2 = pyth.liveUpdates(quarterly, 1);
        vm.prank(guardian);
        quarterly.startRebalance(1, live2);
        (, uint256 keepMask) = quarterly.pendingRebalance();
        assertEq(keepMask, 1, "the keep is renewed a week on");
        vm.prank(guardian);
        quarterly.cancelRebalance();

        // A full fill, after ETH rose a thousandfold, puts the index back on its own interval.
        vm.warp(block.timestamp + quarterly.REBALANCE_DELAY());
        bytes[] memory live3 = pyth.liveUpdates(quarterly, 0);
        vm.prank(stranger);
        quarterly.startRebalance(0, live3);
        (uint256 eta,) = quarterly.pendingRebalance();
        vm.warp(eta);
        executor.execute(quarterly, "", _updates(quarterly, _ids3(), _prices3(2_010_000e8, BTC_PRICE, USD_PRICE)));
        assertEq(quarterly.earliestRebalance(), block.timestamp + interval, "a fill without a mask: the full interval");
        vm.warp(block.timestamp + quarterly.MIN_REBALANCE_INTERVAL());
        assertFalse(quarterly.canStartRebalance());
    }
}
