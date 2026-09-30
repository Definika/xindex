// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {XindexTest} from "./XindexTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";

/// @notice Fills honestly, then burns one raw unit of a chosen component back out of the index while it still holds
///         control, as an issuer clawing a balance back would. Outside the whitelist policy: it stands in for a balance
///         that can fall while a settlement runs, which nothing inside Xindex can cause.
contract ClawingExecutor is IRebalanceExecutor {
    uint256 internal immutable CLAWED;

    constructor(uint256 clawed) {
        CLAWED = clawed;
    }

    function execute(IIndexHub index) external {
        index.executeRebalance("");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IIndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) MockERC20(t[i]).mint(msg.sender, amountsIn[i]);
        }
        MockERC20(t[CLAWED]).burn(msg.sender, 1);
    }
}

/// @notice Settles from tokens it already holds, the way an executor with inventory fills a basket too wide for swaps
///         inside one transaction: no swap and no bookkeeping, one transfer per bought leg.
contract InventoryExecutor is IRebalanceExecutor {
    function fill(IIndexHub index) external {
        index.executeRebalance("");
    }

    function onXindexRebalance(uint256[] calldata, uint256[] calldata amountsIn, bytes calldata) external {
        address[] memory t = IIndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < t.length; ++i) {
            if (amountsIn[i] != 0) MockERC20(t[i]).transfer(msg.sender, amountsIn[i]);
        }
    }
}

/// @notice The λ band auction: snapshot, notice, auction, settlement, cancellation.
/// @dev Five 18-decimal components, the second pausable, each listed with a reference supply of 100e18 and created at
///      k = 1e36, so every unit starts at 100e18 and units are exactly proportional to supplies. `_bandFixture` then
///      raises the first component's supply by the full 0.5% step, which opens a band: the first component's ratio sits
///      below parity and the four others above it, so a fill buys the first and sells the rest.
contract IndexHubRebalanceTest is XindexTest {
    IndexHub index;
    MockRebalanceExecutor executor;
    MockPausableToken pausable;
    address[] tokens;

    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    uint256 constant WAD = 1e18;
    uint256 constant K = 1e36;
    uint256 constant SUPPLY = 100e18;
    uint256 constant SHARES = 10e18;
    uint256 constant STEP = 0.005e18;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        executor = new MockRebalanceExecutor();

        pausable = new MockPausableToken("Pausable", "PAUSE", 18);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(i == 1 ? address(pausable) : address(new MockERC20("C", "C", 18)));
            _listWith(tokens[i], SUPPLY);
        }
        index = IndexHub(factory.createIndex("Rebalanced", "RBL", tokens, K));
        _issue(index, alice, SHARES);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _issue(IndexHub idx, address who, uint256 shares) internal {
        (address[] memory t,) = idx.components();
        uint256[] memory need = idx.previewIssue(shares);
        for (uint256 i = 0; i < t.length; ++i) {
            MockERC20(t[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(t[i]).approve(address(idx), need[i]);
        }
        vm.prank(who);
        idx.issue(shares, who);
    }

    /// @dev Raises the first component's supply by the full step, which opens a band of about 0.5%.
    function _bandFixture() internal {
        _revise(tokens[0], SUPPLY + SUPPLY * STEP / WAD);
    }

    /// @dev Warps to the first moment a rebalance may start and starts one as a stranger.
    function _start(IndexHub idx) internal returns (uint256 eta) {
        uint256 due = idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL();
        if (block.timestamp < due) vm.warp(due);
        vm.prank(stranger);
        idx.startRebalance(0);
        (eta,,,,) = idx.pendingRebalance();
    }

    /// @dev Opens the fixture's band, starts, and warps to the middle of the auction, where the first component is
    ///      bought and the four others are sold.
    function _toAuction(IndexHub idx) internal {
        _bandFixture();
        uint256 eta = _start(idx);
        vm.warp(eta + idx.AUCTION_DURATION() / 2);
    }

    function _units(IndexHub idx) internal view returns (uint256[] memory units) {
        (, units) = idx.components();
    }

    function _assertBacked(IndexHub idx) internal view {
        (address[] memory t, uint256[] memory u) = idx.components();
        uint256 supply = idx.totalSupply();
        for (uint256 i = 0; i < t.length; ++i) {
            uint256 required = supply * u[i] / WAD + idx.totalClaims(t[i]);
            assertGe(MockERC20(t[i]).balanceOf(address(idx)), required, "component under-backed");
        }
    }

    /// @dev The band computed here from its definition, independently of the hub: ρ = units / supply over the moving
    ///      components, ρ relative to the first moving one, centred on the midpoint of the extremes and clamped to the
    ///      step.
    function _expectedBand(uint256[] memory units, uint256[] memory supplies, uint256 keepMask)
        internal
        pure
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax)
    {
        uint256 n = units.length;
        ratios = new uint256[](n);
        uint256 a = n;
        uint256 low = type(uint256).max;
        uint256 high = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask >> i) & 1 == 1) continue;
            if (a == n) a = i;
            ratios[i] = Math.mulDiv(units[i] * supplies[a], WAD, supplies[i] * units[a]);
            low = Math.min(low, ratios[i]);
            high = Math.max(high, ratios[i]);
        }
        uint256 centre = (low + high) / 2;
        lambdaMin = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask >> i) & 1 == 1) continue;
            ratios[i] = Math.max(WAD - STEP, Math.min(WAD + STEP, Math.mulDiv(ratios[i], WAD, centre)));
            lambdaMin = Math.min(lambdaMin, ratios[i]);
            lambdaMax = Math.max(lambdaMax, ratios[i]);
        }
    }

    function _supplies() internal view returns (uint256[] memory) {
        return factory.referenceSupplies(tokens);
    }

    // ---------------------------------------------------------------------
    // constants and start
    // ---------------------------------------------------------------------

    function test_constantsAndIdleViews() public {
        assertEq(index.REBALANCE_DELAY(), 2 days);
        assertEq(index.MIN_REBALANCE_INTERVAL(), 7 days);
        assertEq(index.AUCTION_DURATION(), 24 hours);
        assertEq(index.MAX_SUPPLY_STEP(), 0.005e18);
        assertEq(index.MAX_SUPPLY_STEP(), factory.MAX_SUPPLY_STEP(), "the hub clamps to the factory's step");
        assertEq(index.MIN_BAND(), 0.001e18);
        (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios) =
            index.pendingRebalance();
        assertEq(eta + keepMask + lambdaMin + lambdaMax + ratios.length, 0, "nothing is pending");
        assertEq(index.currentLambda(), 0);
        vm.expectRevert(IIndexHub.NoPendingRebalance.selector);
        index.previewRebalance();
    }

    function test_startRebalance_snapshotsTheBandAfterTheInterval() public {
        _bandFixture();
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0);

        vm.warp(earliest);
        (uint256[] memory expected, uint256 lambdaMin, uint256 lambdaMax) = _expectedBand(_units(index), _supplies(), 0);
        (uint256[] memory preview, uint256 previewMin, uint256 previewMax) = index.previewBand(0);
        assertEq(preview, expected, "the band follows its definition");
        assertEq(previewMin, lambdaMin);
        assertEq(previewMax, lambdaMax);
        assertLt(expected[0], WAD, "the component whose supply grew is below parity");
        for (uint256 i = 1; i < 5; ++i) {
            assertGt(expected[i], WAD, "the others above it");
            assertEq(expected[i], lambdaMax);
        }
        assertEq(expected[0], lambdaMin);

        uint256 eta = block.timestamp + index.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.RebalanceStarted(1, 1, stranger, 0, lambdaMin, lambdaMax, expected, eta);
        vm.prank(stranger);
        index.startRebalance(0);

        (uint256 pendingEta, uint256 keepMask, uint256 pendingMin, uint256 pendingMax, uint256[] memory ratios) =
            index.pendingRebalance();
        assertEq(pendingEta, eta);
        assertEq(keepMask, 0);
        assertEq(pendingMin, lambdaMin);
        assertEq(pendingMax, lambdaMax);
        assertEq(ratios, expected);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(_units(index)[i], SUPPLY, "nothing changes yet");
        }
        assertEq(index.currentLambda(), 0, "no auction during the notice");
    }

    /// @dev R19, re-targeted: a snapshot that would trade nothing does not start. Without supply changes the band is
    ///      empty; a change every supply shares moves every ratio alike, and the centred ratios are then all parity; a
    ///      single moving component has nothing to trade against.
    function test_R19_aStepThatTradesNothingIsRefused() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, WAD, WAD));
        index.startRebalance(0);

        uint256[] memory supplies = new uint256[](5);
        address[] memory sorted = _sortedTokens();
        for (uint256 i = 0; i < 5; ++i) {
            supplies[i] = SUPPLY + SUPPLY * STEP / WAD;
        }
        _revise(sorted, supplies);
        (, uint256 low, uint256 high) = index.previewBand(0);
        assertEq(low, high, "a uniform change moves no ratio apart");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, low, high));
        index.startRebalance(0);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, WAD, WAD));
        index.startRebalance(0x1e); // a single moving component has nothing to trade against
    }

    /// @dev R19 and CR-I33, at the MIN_BAND boundary: whatever the step, a start succeeds exactly when the band it would
    ///      snapshot is at least MIN_BAND wide, and it is refused with that band otherwise.
    function testFuzz_R19_CRI33_theBandGateIsExactlyMinBand(uint256 raise) public {
        raise = bound(raise, 0, SUPPLY * STEP / WAD);
        if (raise != 0) _revise(tokens[0], SUPPLY + raise);
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (, uint256 lambdaMin, uint256 lambdaMax) = index.previewBand(0);
        bool wide = lambdaMax * WAD >= lambdaMin * (WAD + index.MIN_BAND());
        if (!wide) vm.expectRevert(abi.encodeWithSelector(IIndexHub.BandTooNarrow.selector, lambdaMin, lambdaMax));
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,,,) = index.pendingRebalance();
        assertEq(eta != 0, wide);
    }

    /// @dev R04 and R17, re-targeted: the band is bounded by the hub's clamp, not by how the factory's supplies were
    ///      reached. Six batches move the first supply 3% while the index waits, and the band is still the clamp's.
    function test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded() public {
        uint256 supply = SUPPLY;
        for (uint256 i = 0; i < 6; ++i) {
            supply += supply * STEP / WAD;
            _revise(tokens[0], supply);
        }
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax) = index.previewBand(0);
        assertEq(lambdaMin, WAD - STEP, "the stretched ratio is clamped to the step");
        assertEq(lambdaMax, WAD + STEP, "and so is its counterpart");
        assertEq(ratios[0], lambdaMin);
        assertLe(lambdaMax * (WAD - STEP), lambdaMin * (WAD + STEP), "the band never exceeds (1+STEP)/(1-STEP)");
        vm.prank(stranger);
        index.startRebalance(0);
    }

    function test_startRebalance_pendingThenExpiredRestart() public {
        _bandFixture();
        uint256 eta = _start(index);
        uint256 deadline = eta + index.AUCTION_DURATION();
        vm.warp(deadline);
        assertFalse(index.canStartRebalance());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalancePending.selector, deadline));
        index.startRebalance(0);

        // An auction nobody filled holds strangers off for REBALANCE_DELAY more, so the guardian gets the first
        // restart; afterwards anyone can start again from a fresh snapshot.
        vm.warp(deadline + 1);
        assertFalse(index.canStartRebalance());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.startRebalance(0);

        vm.warp(deadline + index.REBALANCE_DELAY());
        assertTrue(index.canStartRebalance());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 nextEta,,,,) = index.pendingRebalance();
        assertEq(nextEta, block.timestamp + index.REBALANCE_DELAY());
    }

    /// @dev LR-05, re-targeted: a restart after an unfilled auction takes a fresh snapshot of the supplies in force,
    ///      not the expired one's band.
    function test_LR05_aRestartAfterAnUnfilledAuctionTakesAFreshSnapshot() public {
        _bandFixture();
        uint256 eta = _start(index);
        (,,,, uint256[] memory first) = index.pendingRebalance();

        vm.warp(eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY());
        _revise(tokens[2], SUPPLY - SUPPLY * STEP / WAD / 2); // a second supply moves before anyone restarts
        (uint256[] memory fresh,,) = index.previewBand(0);
        assertTrue(keccak256(abi.encode(fresh)) != keccak256(abi.encode(first)), "the supplies now give another band");

        vm.prank(stranger);
        index.startRebalance(0);
        (,,,, uint256[] memory second) = index.pendingRebalance();
        assertEq(second.length, 5, "the expired ratios were cleared, not appended to");
        assertEq(second, fresh, "the restart snapshots the supplies again");
    }

    function test_startRebalance_keepMaskRules() public {
        _bandFixture();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.startRebalance(1);

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.InvalidKeepMask.selector, 1 << 5));
        index.startRebalance(1 << 5);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.InvalidKeepMask.selector, 31));
        index.startRebalance(31);
        index.startRebalance(1 << 1);
        vm.stopPrank();

        (, uint256 keepMask,,, uint256[] memory ratios) = index.pendingRebalance();
        assertEq(keepMask, 1 << 1);
        assertEq(ratios[1], 0, "a kept component has no ratio");
    }

    function test_startRebalance_ownerCanPassAKeepMask() public {
        _bandFixture();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(owner);
        index.startRebalance(1 << 4);
        (, uint256 keepMask,,,) = index.pendingRebalance();
        assertEq(keepMask, 1 << 4);
    }

    /// @dev R22, re-targeted: what the factory changes after a start moves nothing the pending settlement uses, since
    ///      the band is stored at the start. A batch executed during the notice leaves the ratios and the fill alone.
    function test_R22_aBatchDuringTheNoticeDoesNotMoveThePendingSettlement() public {
        _bandFixture();
        uint256 eta = _start(index);
        (,,,, uint256[] memory before) = index.pendingRebalance();
        _revise(tokens[3], SUPPLY + SUPPLY * STEP / WAD);
        (,,,, uint256[] memory later) = index.pendingRebalance();
        assertEq(later, before, "the stored band is the start's");
        vm.warp(eta);
        (uint256 lambda,,,) = index.previewRebalance();
        (,, uint256 lambdaMax,,) = _pendingBand();
        assertEq(lambda, lambdaMax);
    }

    function _pendingBand()
        internal
        view
        returns (uint256 eta, uint256 lambdaMin, uint256 lambdaMax, uint256 keepMask, uint256[] memory ratios)
    {
        (eta, keepMask, lambdaMin, lambdaMax, ratios) = index.pendingRebalance();
    }

    // ---------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------

    function test_cancelRebalance_andTheRestartCooldown() public {
        _bandFixture();
        vm.prank(guardian);
        vm.expectRevert(IIndexHub.NoPendingRebalance.selector);
        index.cancelRebalance();

        _start(index);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.cancelRebalance();

        uint256 restartAt = block.timestamp + index.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.RebalanceCancelled(1, guardian, restartAt);
        vm.prank(guardian);
        index.cancelRebalance();

        (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios) =
            index.pendingRebalance();
        assertEq(eta + keepMask + lambdaMin + lambdaMax + ratios.length, 0, "the proposal is cleared");
        assertEq(index.restartAllowedAt(), restartAt);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.startRebalance(0);

        vm.prank(owner);
        index.startRebalance(0); // the owner or guardian can restart at once
        vm.prank(owner);
        index.cancelRebalance();

        vm.warp(index.restartAllowedAt());
        vm.prank(stranger);
        index.startRebalance(0);
    }

    function test_cancelRebalance_cleansUpAnExpiredAuction() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        vm.prank(owner);
        index.cancelRebalance();
        (uint256 pendingEta,,,,) = index.pendingRebalance();
        assertEq(pendingEta, 0);
    }

    /// @dev VR-04. An auction that expired unfilled already holds strangers off until its deadline plus
    ///      REBALANCE_DELAY. Cancelling it only clears the stale proposal the views still report, so it must not
    ///      re-arm the cooldown from the moment of the cancel and push that hold-off further out.
    function test_VR04_cancellingAnExpiredAuctionDoesNotExtendTheHoldOff() public {
        _bandFixture();
        uint256 eta = _start(index);
        uint256 fromExpiry = eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();

        vm.warp(fromExpiry);
        assertTrue(index.canStartRebalance(), "the expiry alone has already let strangers in");

        vm.expectEmit(true, true, false, true, address(index));
        emit IIndexHub.RebalanceCancelled(index.proposalCount(), owner, fromExpiry);
        vm.prank(owner);
        index.cancelRebalance();

        assertEq(index.restartAllowedAt(), fromExpiry, "the expiry's own hold-off stands, not a fresh two days");
        assertTrue(index.canStartRebalance(), "so the cancel costs a stranger nothing");
        vm.prank(stranger);
        index.startRebalance(0);
    }

    /// @dev VR-04, cancelled one second after the auction lapsed: still no extension.
    function test_VR04_anExpiredCancelReportsTheExpirysOwnHoldOff() public {
        _bandFixture();
        uint256 eta = _start(index);
        uint256 fromExpiry = eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), fromExpiry);
        assertLt(index.restartAllowedAt(), block.timestamp + index.REBALANCE_DELAY(), "nothing was added");
    }

    /// @dev VR-04, the live half: cancelling an auction that has NOT expired still arms a full REBALANCE_DELAY.
    function test_VR04_cancellingALiveAuctionStillArmsTheFullCooldown() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta + 1 hours);
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), block.timestamp + index.REBALANCE_DELAY(), "a live cancel costs two days");

        vm.warp(index.restartAllowedAt());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta2,,,,) = index.pendingRebalance();
        vm.warp(eta2 - 1);
        vm.prank(owner);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), block.timestamp + index.REBALANCE_DELAY());
    }

    function test_uninitializedClonesCannotRebalance() public {
        IndexHub rogue = IndexHub(Clones.clone(factory.IMPLEMENTATION()));
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        rogue.startRebalance(0);
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        rogue.cancelRebalance();
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        executor.execute(rogue, "");
    }

    // ---------------------------------------------------------------------
    // execute
    // ---------------------------------------------------------------------

    function test_executeRebalance_windowChecks() public {
        vm.expectRevert(IIndexHub.NoPendingRebalance.selector);
        executor.execute(index, "");

        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceNotReady.selector, eta));
        executor.execute(index, "");
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceNotReady.selector, eta));
        index.previewRebalance();

        uint256 deadline = eta + index.AUCTION_DURATION();
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceExpired.selector, deadline));
        executor.execute(index, "");
        assertEq(index.currentLambda(), 0);
    }

    /// @dev At the open, λ is the largest ratio: no component shrinks, so the executor only delivers. A fill here
    ///      gives the holders the whole band.
    function test_executeRebalance_atTheOpenNothingIsSold() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta);
        (,, uint256 lambdaMax,, uint256[] memory ratios) = _pendingBand();
        assertEq(index.currentLambda(), lambdaMax);

        (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            index.previewRebalance();
        assertEq(lambda, lambdaMax);
        assertEq(units[0], Math.mulDiv(lambdaMax, SUPPLY, ratios[0], Math.Rounding.Ceil), "ceil(lambda * u / r)");
        assertGt(units[0], SUPPLY, "the first component is bought");
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(amountsOut[i], 0, "nothing leaves at the open");
            if (i != 0) assertEq(units[i], SUPPLY, "a component at the top of the band keeps its units");
        }
        assertEq(amountsIn[0], SHARES * units[0] / WAD - SHARES * SUPPLY / WAD);

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.Rebalanced(1, 1, address(executor), lambda, units, amountsOut, amountsIn);
        executor.execute(index, "fill");

        assertEq(_units(index), units);
        assertEq(index.rebalanceNonce(), 1);
        assertEq(index.lastRebalance(), block.timestamp);
        (uint256 pendingEta,,,,) = index.pendingRebalance();
        assertEq(pendingEta, 0);
        assertEq(executor.calls(), 1);
        assertEq(executor.lastData(), "fill");
        assertEq(executor.lastAmountsOut(), amountsOut);
        assertEq(executor.lastAmountsIn(), amountsIn);
        _assertBacked(index);

        vm.expectRevert(IIndexHub.NoPendingRebalance.selector);
        executor.execute(index, "");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceTooSoon.selector, block.timestamp + 7 days));
        index.startRebalance(0);
    }

    /// @dev At the floor, λ is the smallest ratio: the first component keeps its units and the four others shrink, so
    ///      the executor only receives. This is the most a lone executor can take: λmin / λmax of the moving value.
    function test_executeRebalance_atTheFloorNothingIsBought() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION());
        (, uint256 lambdaMin, uint256 lambdaMax,, uint256[] memory ratios) = _pendingBand();
        (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            index.previewRebalance();
        assertEq(lambda, lambdaMin);
        assertEq(units[0], SUPPLY, "the bottom of the band keeps its units");
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(units[i], Math.mulDiv(lambdaMin, SUPPLY, ratios[i], Math.Rounding.Ceil));
            assertLt(units[i], SUPPLY);
            assertEq(amountsOut[i], SHARES * SUPPLY / WAD - SHARES * units[i] / WAD);
            assertEq(amountsIn[i], 0);
        }
        assertEq(amountsIn[0] + amountsOut[0], 0);
        // At equal prices the holders keep 4 of 5 components at λmin/λmax and the first whole.
        assertGe(
            units[1] * lambdaMax, SUPPLY * lambdaMin, "each sold leg keeps at least lambdaMin / lambdaMax of itself"
        );
        executor.execute(index, "");
        _assertBacked(index);
    }

    function test_executeRebalance_lambdaFallsLinearlyAndRoundsUp() public {
        _bandFixture();
        uint256 eta = _start(index);
        (, uint256 lambdaMin, uint256 lambdaMax,,) = _pendingBand();
        uint256 width = lambdaMax - lambdaMin;
        vm.warp(eta + 1);
        assertEq(index.currentLambda(), lambdaMax - width / 1 days, "rounds up in holders' favour");
        vm.warp(eta + 12 hours);
        assertEq(index.currentLambda(), lambdaMax - width / 2);
        vm.warp(eta + 24 hours);
        assertEq(index.currentLambda(), lambdaMin);
    }

    /// @dev R14 and XA-27, re-targeted: a settlement that sends nothing out is taken at λmax, so the units never depend
    ///      on when an empty index is filled.
    function test_R14_XA27_anEmptyIndexSettlesAtLambdaMaxAtAnyTime() public {
        vm.prank(stranger);
        IndexHub empty = IndexHub(factory.createIndex("Empty", "EMPTY", tokens, K));
        _bandFixture();
        uint256 eta = _start(empty);
        (,,, uint256 lambdaMax,) = empty.pendingRebalance();
        vm.warp(eta + 20 hours);
        assertEq(empty.currentLambda(), lambdaMax, "nothing is paid for, so the price is the band's top");

        executor.setMode(MockRebalanceExecutor.Mode.Noop);
        executor.execute(empty, "");
        assertGt(_units(empty)[0], SUPPLY, "the units are the open's");
    }

    /// @dev R14, the dust half: a supply so small that every shrinking leg rounds to zero settles at λmax too.
    function test_R14_aDustSupplyWhoseSoldLegsRoundToZeroSettlesAtLambdaMax() public {
        // Every unit at MIN_RAW_UNITS, so 1e13 shares owe a tenth of a raw unit of each component, rounded up to one.
        uint256 k = factory.MIN_RAW_UNITS() * K / SUPPLY;
        vm.prank(stranger);
        IndexHub dust = IndexHub(factory.createIndex("Dust", "DUST", tokens, k));
        _issue(dust, alice, 1e13);
        _bandFixture();
        uint256 eta = _start(dust);
        vm.warp(eta + index.AUCTION_DURATION());
        (,,, uint256 lambdaMax,) = dust.pendingRebalance();
        (uint256 lambda,, uint256[] memory amountsOut,) = dust.previewRebalance();
        assertEq(lambda, lambdaMax);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(amountsOut[i], 0);
        }
    }

    function test_executeRebalance_revertsWhenUnderfunded() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta);
        (,,, uint256[] memory amountsIn) = index.previewRebalance();
        uint256 required = MockERC20(tokens[0]).balanceOf(address(index)) + amountsIn[0];
        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(0);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, tokens[0], required - 1, required)
        );
        executor.execute(index, "");

        executor.setMode(MockRebalanceExecutor.Mode.Noop);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndexHub.RebalanceUnderfunded.selector, tokens[0], required - amountsIn[0], required
            )
        );
        executor.execute(index, "");
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(_units(index)[i], SUPPLY, "a failed fill changes nothing");
        }
    }

    function test_executeRebalance_onlyContracts() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(bytes("")); // the callback to an account without code reverts with no data
        index.executeRebalance("");
    }

    function test_executeRebalance_callbackCannotReenterButIndexTransfersWork() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.prank(alice);
        index.transfer(address(executor), 1e18);
        vm.warp(eta);
        executor.setMode(MockRebalanceExecutor.Mode.Reentrant);
        executor.execute(index, "");

        bytes[] memory errors = executor.reentryErrors();
        assertEq(errors.length, 8, "both executeRebalance entry points are guarded too");
        for (uint256 i = 0; i < errors.length; ++i) {
            assertEq(bytes4(errors[i]), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        }
        assertTrue(executor.indexTransferSucceeded());
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    function test_executeRebalance_keepMaskAroundAPausedComponent() public {
        _bandFixture();
        uint256 eta = _start(index);
        pausable.setPaused(true);
        vm.warp(eta + index.AUCTION_DURATION());
        vm.expectRevert(bytes("paused"));
        executor.execute(index, ""); // the paused component must shrink, so its transfer fails

        vm.startPrank(guardian);
        index.cancelRebalance();
        index.startRebalance(1 << 1);
        vm.stopPrank();
        (eta,,,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
        uint256 pausedBalance = pausable.balanceOf(address(index));
        executor.execute(index, "");

        assertEq(_units(index)[1], SUPPLY);
        assertEq(pausable.balanceOf(address(index)), pausedBalance, "the paused component never moved");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    function test_executeRebalance_claimsSurvive() public {
        vm.prank(alice);
        index.redeemSkipping(2e18, alice, (1 << 0) | (1 << 2));
        assertEq(index.totalClaims(tokens[0]), 200e18);
        assertEq(index.totalClaims(tokens[2]), 200e18);

        _toAuction(index);
        executor.execute(index, "");
        uint256[] memory units = _units(index);
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), 8e18 * units[0] / WAD + 200e18, "backing + claim");
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), 8e18 * units[2] / WAD + 200e18, "backing + claim");
        _assertBacked(index);

        vm.startPrank(alice);
        index.claim(tokens[0], alice);
        index.claim(tokens[2], alice);
        vm.stopPrank();
        assertEq(MockERC20(tokens[0]).balanceOf(alice), 200e18);
        assertEq(MockERC20(tokens[2]).balanceOf(alice), 200e18);
        _assertBacked(index);
    }

    function test_executeRebalance_donationsStayLocked() public {
        _toAuction(index);
        (,, uint256[] memory outBefore,) = index.previewRebalance();
        MockERC20(tokens[2]).mint(address(index), 1_000e18);
        (,, uint256[] memory outAfter,) = index.previewRebalance();
        assertEq(outAfter[2], outBefore[2], "amounts come from units and supply, never balances");
        uint256 held = MockERC20(tokens[2]).balanceOf(address(index));
        executor.execute(index, "");
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), held - outBefore[2], "the donation stayed");
    }

    // ---------------------------------------------------------------------
    // properties
    // ---------------------------------------------------------------------

    function testFuzz_lambdaFallsFromTheTopOfTheBandToTheBottom(uint256 elapsed) public {
        _bandFixture();
        uint256 eta = _start(index);
        (, uint256 lambdaMin, uint256 lambdaMax,,) = _pendingBand();
        elapsed = bound(elapsed, 0, index.AUCTION_DURATION() - 1);
        vm.warp(eta + elapsed);
        uint256 now_ = index.currentLambda();
        vm.warp(eta + elapsed + 1);
        uint256 next = index.currentLambda();
        assertLe(next, now_);
        assertLe(now_, lambdaMax);
        assertGe(next, lambdaMin);
    }

    function testFuzz_settlementKeepsBacking(uint256 extraShares, uint256 elapsed, uint256 skipped) public {
        extraShares = bound(extraShares, 1, 1_000_000e18);
        _issue(index, stranger, extraShares);
        skipped = bound(skipped, 0, SHARES);
        if (skipped != 0) {
            vm.prank(alice);
            index.redeemSkipping(skipped, alice, 1 << 0);
        }
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta + bound(elapsed, 0, index.AUCTION_DURATION()));
        executor.execute(index, "");
        _assertBacked(index);
    }

    /// @dev DA-01, R08 and CR-I03, re-targeted to the band. For any prices, which exist only inside this test, a fill
    ///      at λ leaves the moving components worth at least λ / λmax of what they were, never less than λmin / λmax:
    ///      each new unit is at least λ·u/r and every r is at most λmax, and units round up. Each unit also moves by no
    ///      more than the band either way, plus one raw unit of rounding.
    function testFuzz_DA01_R08_CRI03_aFillIsBoundedByTheBandAtAnyPrice(
        uint256[5] memory prices,
        uint256 raise,
        uint256 elapsed,
        uint256 keepMask
    ) public {
        _revise(tokens[0], SUPPLY + bound(raise, SUPPLY / 1000, SUPPLY * STEP / WAD));
        keepMask = bound(keepMask, 0, 30) & ~uint256(1); // the first component always moves
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (, uint256 lowCheck, uint256 highCheck) = index.previewBand(keepMask);
        vm.assume(highCheck * WAD >= lowCheck * (WAD + index.MIN_BAND()));
        vm.prank(guardian);
        index.startRebalance(keepMask);
        (uint256 eta,,,,) = index.pendingRebalance();
        vm.warp(eta + bound(elapsed, 0, index.AUCTION_DURATION()));
        _assertUnitsWithinTheBand(keepMask);
        _assertValueWithinTheBand(prices, keepMask);
    }

    function _assertUnitsWithinTheBand(uint256 keepMask) internal view {
        (,, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios) = index.pendingRebalance();
        (, uint256[] memory units,,) = index.previewRebalance();
        for (uint256 i = 0; i < 5; ++i) {
            if ((keepMask >> i) & 1 == 1) {
                assertEq(units[i], SUPPLY, "a kept component never moves");
                continue;
            }
            assertGe(ratios[i], lambdaMin);
            assertLe(ratios[i], lambdaMax);
            assertGe(ratios[i], WAD - STEP);
            assertLe(ratios[i], WAD + STEP);
            assertLe(units[i] * lambdaMin, SUPPLY * lambdaMax + lambdaMin, "grows at most by the band, plus a unit");
            assertGe(units[i] * lambdaMax, SUPPLY * lambdaMin, "shrinks at most by the band");
        }
    }

    function _assertValueWithinTheBand(uint256[5] memory prices, uint256 keepMask) internal view {
        (,, uint256 lambdaMin, uint256 lambdaMax,) = index.pendingRebalance();
        (uint256 lambda, uint256[] memory units,,) = index.previewRebalance();
        uint256 before = 0;
        uint256 later = 0;
        for (uint256 i = 0; i < 5; ++i) {
            if ((keepMask >> i) & 1 == 1) continue;
            uint256 price = bound(prices[i], 1, 1e24);
            before += SUPPLY * price;
            later += units[i] * price;
        }
        assertGe(later * lambdaMax, before * lambda, "worth at least lambda / lambdaMax of what it was");
        assertGe(later * lambdaMax, before * lambdaMin, "and never less than lambdaMin / lambdaMax");
    }

    /// @dev A full fill re-anchors units to supplies, so repeated rebalances converge: every moving ratio's spread
    ///      shrinks by the band each time, until the band is narrower than MIN_BAND.
    function testFuzz_repeatedFillsConvergeToTheSupplies(uint256 spread, uint256 elapsed) public {
        // Five steps of revisions, far wider than one band, stretch the first component's ratio from the others'.
        uint256 supply = SUPPLY;
        uint256 steps = bound(spread, 1, 5);
        for (uint256 i = 0; i < steps; ++i) {
            supply += supply * STEP / WAD;
            _revise(tokens[0], supply);
        }
        uint256 fills = 0;
        while (true) {
            vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
            (, uint256 lambdaMin, uint256 lambdaMax) = index.previewBand(0);
            if (lambdaMax * WAD < lambdaMin * (WAD + index.MIN_BAND())) break;
            uint256 eta = _start(index);
            vm.warp(eta + bound(uint256(keccak256(abi.encode(elapsed, fills))), 0, index.AUCTION_DURATION()));
            executor.execute(index, "");
            ++fills;
            assertLe(fills, steps + 2, "converges within one fill per step, plus the rounding");
        }
        _assertBacked(index);
    }

    // ---------------------------------------------------------------------
    // 2026-09-19 deep audit
    // ---------------------------------------------------------------------

    /// @dev DA-13. Settlement amounts are recomputed from the supply in the settling block, and issue stays open
    ///      through the auction, so anyone could enlarge a fill an executor had already funded from a simulation and
    ///      make it revert for the price of gas. The bounded entry point lets an executor say what it will deliver.
    function test_DA13_aBoundedFillRefusesAnEnlargedSettlement() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta);
        (,,, uint256[] memory quoted) = index.previewRebalance();
        // A stranger issues dust into the same block, which scales every leg up.
        _issue(index, stranger, 1e17);
        (,,, uint256[] memory enlarged) = index.previewRebalance();
        assertGt(enlarged[0], quoted[0], "the settlement grew under the executor");

        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceMovedOn.selector, tokens[0], enlarged[0], quoted[0]));
        executor.executeBounded(index, "", quoted);
        assertEq(index.rebalanceNonce(), 0, "the bounded fill did not settle");

        executor.executeBounded(index, "", enlarged);
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    function test_DA13_aBoundedFillRejectsAMalformedBound() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        executor.executeBounded(index, "", new uint256[](4));
    }

    /// @dev DA-14. A kept component is not read at settlement, so one whose `balanceOf` reverts does not block it.
    function test_DA14_aKeptComponentWithBrokenReadsDoesNotBlockSettlement() public {
        _bandFixture();
        pausable.setPaused(true);
        pausable.setReadsBroken(true);
        vm.expectRevert(bytes("reads broken"));
        pausable.balanceOf(address(index));

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(owner);
        index.startRebalance(1 << 1); // keep the broken component
        (uint256 eta,,,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());

        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        assertEq(amountsOut[1], 0, "the kept component neither sends");
        assertEq(amountsIn[1], 0, "nor receives");

        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "the settlement no longer touches the kept component at all");
        assertEq(_units(index)[1], SUPPLY, "and its units are unchanged");
    }

    /// @dev RT-01, re-targeted: nothing on the rebalance path calls a component to price or size it. A component whose
    ///      contract stops answering altogether is kept out of a start and a settlement by the keep mask, because the
    ///      band reads only the moving components' reference supplies from the factory, and the settlement reads only
    ///      legs that move (DA-14).
    function test_RT01_aKeepMaskRoutesAroundAComponentThatNoLongerAnswers() public {
        _bandFixture();
        pausable.setPaused(true);
        pausable.setReadsBroken(true);
        vm.expectRevert(bytes("reads broken"));
        pausable.decimals();

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(guardian);
        index.startRebalance(1 << 1);
        (uint256 eta,,,,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() / 2);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        assertEq(amountsOut[1] + amountsIn[1], 0, "the dead component neither sends nor receives");
        assertGt(amountsOut[2] + amountsIn[0], 0, "while the others trade");
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "an index rebalances around a component that no longer answers");
    }

    // ---------------------------------------------------------------------
    // Security audit of 2026-09-23
    // ---------------------------------------------------------------------

    function test_CRI30_aSettlementStillDemandsTheBackingItOwes() public {
        _toAuction(index);
        (, uint256[] memory units,, uint256[] memory amountsIn) = index.previewRebalance();
        assertGt(amountsIn[0], 0, "the first component is bought");
        MockERC20(tokens[0]).burn(address(index), 1); // the issuer's clawback
        uint256 required = SHARES * units[0] / WAD;
        vm.expectRevert(
            abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, tokens[0], required - 1, required)
        );
        executor.execute(index, "");
    }

    /// @dev CR-I30 and VR-06: the `+ totalClaims` in the backing term. With a claim open on the bought component, a
    ///      clawed unit there is caught only if the claim is counted.
    function test_VR06_CRI30_theBackingTermCountsOpenClaims() public {
        vm.prank(alice);
        index.redeemSkipping(1e18, alice, 1 << 0); // leaves 100 units of the first component as alice's claim
        assertEq(index.totalClaims(tokens[0]), 100e18);
        _toAuction(index);
        (, uint256[] memory units,, uint256[] memory amountsIn) = index.previewRebalance();
        assertGt(amountsIn[0], 0);
        MockERC20(tokens[0]).burn(address(index), 1);
        uint256 required = index.totalSupply() * units[0] / WAD + index.totalClaims(tokens[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, tokens[0], required - 1, required)
        );
        executor.execute(index, "");
    }

    /// @dev CR-I30, the sold legs. `_checkBacking` reads again every leg that moved, including one the index only sold.
    function test_CRI30_aSoldLegIsCheckedAgainAfterTheCallback() public {
        _toAuction(index);
        (, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        assertGt(amountsOut[2], 0, "the third component is sold");
        assertEq(amountsIn[2], 0, "and receives nothing");
        uint256 required = SHARES * units[2] / WAD;
        ClawingExecutor clawing = new ClawingExecutor(2);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, tokens[2], required - 1, required)
        );
        clawing.execute(index);
    }

    /// @dev CR-I33. The bounded overload is a separate entry point with its own guard.
    function test_CRI33_theBoundedSettlementRefusesAnUninitializedInstance() public {
        IndexHub impl = IndexHub(factory.IMPLEMENTATION());
        IndexHub rogue = IndexHub(Clones.clone(address(impl)));
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        executor.executeBounded(rogue, "", new uint256[](0));
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        executor.executeBounded(impl, "", new uint256[](0));
    }

    /// @dev CR-I33. `_redeem` skips a component it owes nothing of, both when it pays out and when it books claims. The
    ///      pausable component is held at MIN_RAW_UNITS here, so a redemption of under 1e14 shares owes nothing of it.
    function test_CRI33_aRedemptionOwingNothingOfAFrozenComponentNeverTouchesIt() public {
        MockPausableToken coarse = new MockPausableToken("Coarse", "CRS", 18);
        _listWith(address(coarse), factory.MIN_RAW_UNITS());
        address[] memory t = new address[](2);
        (t[0], t[1]) = (tokens[0], address(coarse));
        // tokens[0] carries a supply of about 100e18; k = 1e36 puts coarse at exactly MIN_RAW_UNITS.
        vm.prank(alice);
        IndexHub idx = IndexHub(factory.createIndex("Dust", "DUST", t, K));
        _issue(idx, alice, 3e18);
        coarse.setPaused(true);
        assertEq(idx.previewRedeem(0.5e14)[1], 0, "the redemption owes nothing of the coarse component");
        vm.prank(alice);
        idx.redeem(0.5e14, alice);

        vm.recordLogs();
        vm.prank(alice);
        idx.redeemSkipping(0.5e14, alice, 1 << 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IIndexHub.ClaimRecorded.selector, "no claim of nothing is recorded");
        }
        assertEq(idx.claimOf(alice, address(coarse)), 0);
    }

    /// @dev CR-I33. `canStartRebalance` a second before the interval ends, where `startRebalance` still reverts.
    function test_CRI33_theDuePredicateAgreesWithStartRebalanceASecondEarly() public {
        uint256 due = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(due - 1);
        assertFalse(index.canStartRebalance(), "not due yet");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceTooSoon.selector, due));
        index.startRebalance(0);
        vm.warp(due);
        assertTrue(index.canStartRebalance(), "due on the dot");
    }

    /// @dev CR-I33. `currentLambda` answers 0 at every moment outside the auction, the last second of the notice
    ///      included, where `previewRebalance` reverts RebalanceNotReady; an app polling the view must not see a revert.
    function test_CRI33_lambdaIsZeroTheSecondBeforeTheAuction() public {
        _bandFixture();
        uint256 eta = _start(index);
        vm.warp(eta - 1);
        assertEq(index.currentLambda(), 0, "no auction yet");
        vm.warp(eta);
        (,,, uint256 lambdaMax,) = index.pendingRebalance();
        assertEq(index.currentLambda(), lambdaMax);
    }

    /// @dev CR-I03, re-targeted: a component held at MIN_RAW_UNITS settles within the band plus one raw unit of
    ///      rounding, which the executor delivers, so no holder pays for it.
    function test_CRI03_aSmallHoldingMovesAtMostTheBandPlusOneRawUnit() public {
        MockERC20 coarse = new MockERC20("Coarse", "CRS", 6);
        _listWith(address(coarse), factory.MIN_RAW_UNITS());
        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(coarse), tokens[2]);
        IndexHub idx = IndexHub(factory.createIndex("Coarse", "CRS", t, K));
        _issue(idx, alice, 1e24);
        _revise(address(coarse), factory.MIN_RAW_UNITS() + 50); // +0.5%
        uint256 eta = _start(idx);
        vm.warp(eta);
        (,, uint256 lambdaMin, uint256 lambdaMax,) = idx.pendingRebalance();
        executor.execute(idx, "");
        uint256 settled = _units(idx)[0];
        assertGt(settled, 10_000, "the coarse component was bought at the open");
        assertLe(settled * lambdaMin, 10_000 * lambdaMax + lambdaMin, "within the band plus one raw unit");
        _assertBacked(idx);
    }

    // ---------------------------------------------------------------------
    // Red team of 2026-09-24, mutation gaps
    // ---------------------------------------------------------------------

    /// @dev What `idx` holds of each component above its backing: the holders' rounding surplus.
    function _surpluses(IndexHub idx) internal view returns (uint256[] memory surplus) {
        (address[] memory t, uint256[] memory u) = idx.components();
        uint256 supply = idx.totalSupply();
        surplus = new uint256[](t.length);
        for (uint256 i = 0; i < t.length; ++i) {
            surplus[i] = MockERC20(t[i]).balanceOf(address(idx)) - supply * u[i] / WAD - idx.totalClaims(t[i]);
        }
    }

    /// @dev Holds one leg of a settlement to the change in its required backing, and says whether the floor of the
    ///      change in units comes out differently, which is when holding it there shows anything.
    function _assertLegIsTheChangeInBacking(uint256 supply, uint256 current, uint256 next, uint256 out, uint256 into)
        internal
        pure
        returns (bool roundingShows)
    {
        if (next < current) {
            assertEq(out, supply * current / WAD - supply * next / WAD, "a shrinking leg sends the change in backing");
            assertEq(into, 0);
            return supply * (current - next) / WAD != out;
        }
        assertEq(into, supply * next / WAD - supply * current / WAD, "a growing leg asks for the change in backing");
        assertEq(out, 0);
        return supply * (next - current) / WAD != into;
    }

    /// @dev RT-12. A settlement moves exactly the change in required backing on every leg: the floor of the new backing
    ///      less the floor of the old, not the floor of the change in units. Here the units, the supply and λ all leave
    ///      remainders, and each leg's surplus is compared across an honest fill.
    function test_RT12_aFillMovesExactlyTheChangeInBackingWhenTheProductsHaveRemainders() public {
        address[] memory odd = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            odd[i] = address(new MockERC20("O", "O", 18));
            _listWith(odd[i], 100e18 + 1_234_567_891 * (i + 1));
        }
        vm.prank(stranger);
        IndexHub idx = IndexHub(factory.createIndex("Odd", "ODD", odd, K));
        _issue(idx, alice, 3_333_333_333_333_333_350);
        uint256 supply = idx.totalSupply();
        uint256[] memory surplus = _surpluses(idx);
        uint256[] memory before = _units(idx);

        _revise(odd[0], factory.referenceSupply(odd[0]) + factory.referenceSupply(odd[0]) * STEP / WAD);
        vm.warp(_start(idx) + 7 hours + 13 minutes); // a λ with a remainder
        (, uint256[] memory next, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        bool[2] memory shows; // whether the rounding shows on a shrinking leg, and on a growing one
        for (uint256 i = 0; i < 5; ++i) {
            if (_assertLegIsTheChangeInBacking(supply, before[i], next[i], amountsOut[i], amountsIn[i])) {
                shows[next[i] < before[i] ? 0 : 1] = true;
            }
        }
        assertTrue(shows[0] && shows[1], "the rounding shows on a shrinking leg and on a growing one");

        executor.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 1, "the fill settled");
        uint256[] memory settled = _surpluses(idx);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(settled[i], surplus[i], "the holders' rounding surplus did not move");
        }
    }

    /// @dev RT-15. `RebalanceStarted` carries the keep mask. Here the guardian keeps the second component.
    function test_RT15_aGuardianStartReportsItsKeepMask() public {
        _bandFixture();
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax) = index.previewBand(1 << 1);
        assertEq(ratios[1], 0, "the kept component has no ratio");
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.RebalanceStarted(
            1, 1, guardian, 1 << 1, lambdaMin, lambdaMax, ratios, block.timestamp + index.REBALANCE_DELAY()
        );
        vm.prank(guardian);
        index.startRebalance(1 << 1);
    }

    // ---------------------------------------------------------------------
    // helpers, continued
    // ---------------------------------------------------------------------

    /// @dev The fixture's tokens in ascending address order, as a supply batch needs them.
    /// @dev XA-23, re-targeted: the arithmetic that sizes a rebalance does not overflow at the extremes of its inputs.
    ///      It was the rule's prices; it is now units and supplies, which the band multiplies across components
    ///      (units below 2^96, supplies below 2^128). One index holds a component at MAX_UNITS with a supply of
    ///      MAX_SUPPLY beside one at the unit floor, and another holds a supply of a single raw unit beside a component at
    ///      MAX_UNITS: each starts, settles mid-auction and stays backed.
    function test_XA23_theBandHoldsAtTheExtremesOfUnitsAndSupplies() public {
        uint256 maxSupply = factory.MAX_SUPPLY();
        uint256 maxUnits = factory.MAX_UNITS();
        uint256[] memory supplies = new uint256[](3);
        (supplies[0], supplies[1], supplies[2]) = (maxSupply, 1e17, 1e30);
        IndexHub top = _extremeIndex(supplies, maxUnits * K / maxSupply);
        assertLe(_units(top)[0], maxUnits, "a component at the unit ceiling");
        assertGe(_units(top)[0], maxUnits - maxUnits / 1e12, "to within the rounding of k");
        assertGe(_units(top)[1], factory.MIN_RAW_UNITS(), "beside one near the floor");
        _settleExtreme(top);

        (supplies[0], supplies[1], supplies[2]) = (1, maxUnits / 1e4, 1e10);
        IndexHub bottom = _extremeIndex(supplies, 1e4 * K);
        assertEq(_units(bottom)[0], 1e4, "a supply of one raw unit, at the unit floor");
        assertGe(_units(bottom)[1], maxUnits - 1e4, "beside a component at the unit ceiling");
        _settleExtreme(bottom);
    }

    function _extremeIndex(uint256[] memory supplies, uint256 k) internal returns (IndexHub idx) {
        address[] memory t = new address[](supplies.length);
        for (uint256 i = 0; i < t.length; ++i) {
            t[i] = address(new MockERC20("X", "X", 18));
            _listWith(t[i], supplies[i]);
        }
        idx = IndexHub(factory.createIndex("Extreme", "XTR", t, k));
        _issue(idx, alice, WAD);
    }

    /// @dev Revises the last component up by the step, starts, and settles in the middle of the auction.
    function _settleExtreme(IndexHub idx) internal {
        (address[] memory t, uint256[] memory unitsBefore) = idx.components();
        uint256 last = t.length - 1;
        uint256 supply = factory.referenceSupply(t[last]);
        _revise(t[last], supply + supply * STEP / WAD);
        uint256 eta = _start(idx);
        (,, uint256 lambdaMin, uint256 lambdaMax,) = idx.pendingRebalance();
        assertGe(lambdaMax * WAD, lambdaMin * (WAD + idx.MIN_BAND()), "the band opens");
        vm.warp(eta + idx.AUCTION_DURATION() / 2);
        executor.execute(idx, "");
        assertEq(idx.rebalanceNonce(), 1);
        _assertBacked(idx);
        uint256[] memory unitsAfter = _units(idx);
        for (uint256 i = 0; i < t.length; ++i) {
            assertLe(unitsAfter[i], type(uint96).max, "units still fit their slot");
            assertLe(unitsAfter[i] * WAD, unitsBefore[i] * (WAD + 2 * STEP) + WAD, "and moved within the band");
        }
    }

    // ---------------------------------------------------------------------
    // capacity
    // ---------------------------------------------------------------------

    /// @dev EIP-7825 caps a transaction at 2^24 gas, and an index of MAX_COMPONENTS has to fit every path through the
    ///      hub inside one: issue, a rebalance's start and a fill by an executor that already holds the tokens,
    ///      redeem, a redemption skipping a component, and the claim that follows. Every account a call touches is
    ///      cooled first, so each pays the cold reads a transaction of its own would, and INTRINSIC covers the
    ///      transaction's base cost and calldata with room to spare.
    function test_aHundredComponentsFitOneTransaction() public {
        uint256 n = factory.MAX_COMPONENTS();
        address[] memory t = new address[](n);
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(new MockERC20("C", "C", 18));
            factory.proposeListing(t[i], SUPPLY);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(t[i]);
        }
        IndexHub big = IndexHub(factory.createIndex("Hundred", "HND", t, K));
        uint256[] memory need = big.previewIssue(SHARES);
        InventoryExecutor inventory = new InventoryExecutor();
        vm.startPrank(alice);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20(t[i]).mint(alice, need[i]);
            MockERC20(t[i]).approve(address(big), need[i]);
            MockERC20(t[i]).mint(address(inventory), need[i]);
        }
        vm.stopPrank();

        _cool(big, t);
        uint256 before = gasleft();
        vm.prank(alice);
        big.issue(SHARES, alice);
        _assertFits("issue", before - gasleft());

        // One supply revised by the step moves every component: the first is bought and the other 99 sold mid-auction.
        _revise(t[0], SUPPLY + SUPPLY * STEP / WAD);
        vm.warp(big.lastRebalance() + big.MIN_REBALANCE_INTERVAL());
        _cool(big, t);
        before = gasleft();
        vm.prank(stranger);
        big.startRebalance(0);
        _assertFits("startRebalance", before - gasleft());
        (uint256 eta,,,,) = big.pendingRebalance();
        vm.warp(eta + big.AUCTION_DURATION() / 2);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = big.previewRebalance();
        uint256 moving = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (amountsOut[i] != 0 || amountsIn[i] != 0) ++moving;
        }
        assertEq(moving, n, "every component moves");
        _cool(big, t);
        vm.cool(address(inventory));
        before = gasleft();
        inventory.fill(big);
        _assertFits("executeRebalance, inventory fill", before - gasleft());
        _assertBacked(big);

        _cool(big, t);
        before = gasleft();
        vm.prank(alice);
        big.redeem(SHARES / 2, alice);
        _assertFits("redeem", before - gasleft());
        _cool(big, t);
        before = gasleft();
        vm.prank(alice);
        big.redeemSkipping(SHARES / 2, alice, 1 << (n - 1));
        _assertFits("redeemSkipping", before - gasleft());
        _cool(big, t);
        before = gasleft();
        vm.prank(alice);
        big.claim(t[n - 1], alice);
        _assertFits("claim", before - gasleft());
        assertEq(big.totalSupply(), 0, "everything issued came back out");
    }

    uint256 constant INTRINSIC = 100_000;
    uint256 constant TX_GAS_CAP = 2 ** 24;

    function _cool(IndexHub idx, address[] memory t) internal {
        vm.cool(address(idx));
        vm.cool(address(factory));
        for (uint256 i = 0; i < t.length; ++i) {
            vm.cool(t[i]);
        }
    }

    function _assertFits(string memory what, uint256 used) internal pure {
        console2.log(what, used);
        assertLe(used + INTRINSIC, TX_GAS_CAP, what);
    }

    function _sortedTokens() internal view returns (address[] memory sorted) {
        sorted = tokens;
        for (uint256 i = 1; i < sorted.length; ++i) {
            for (uint256 j = i; j > 0 && sorted[j - 1] > sorted[j]; --j) {
                (sorted[j - 1], sorted[j]) = (sorted[j], sorted[j - 1]);
            }
        }
    }
}
