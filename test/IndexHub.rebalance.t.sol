// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../src/interfaces/IRebalanceExecutor.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Methodology} from "../src/libraries/Methodology.sol";
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

/// @notice Rebalance lifecycle of an index: snapshot, notice, auction, settlement, cancellation.
/// @dev The basket holds five tokens worth one WETH each, 100 units apiece, while the rule wants the first at 60% and
///      the others at 10%. The first target is clipped at 200 units and the others land at 75, for 20% turnover. The
///      second component can be paused.
contract IndexHubRebalanceTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexHub index;
    MockRebalanceExecutor executor;
    MockPausableToken pausable;
    address[] tokens;
    uint256[] startUnits;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    uint256 constant WAD = 1e18;
    /// @dev A dollar per whole token, in the eight decimals a feed answers in. Every component starts here, so the
    ///      basket's shape comes from its supplies alone.
    int256 constant ONE_DOLLAR = 1e8;
    uint256 constant SHARES = 10e18;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(owner, guardian);
        executor = new MockRebalanceExecutor();

        pausable = new MockPausableToken("Pausable", "PAUSE", 18);
        uint256[5] memory parts = [uint256(6), 1, 1, 1, 1];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(i == 1 ? address(pausable) : address(new MockERC20("C", "C", 18)));
            configs[i] = market.configWith(tokens[i], ONE_DOLLAR, parts[i] * 1e24);
            startUnits.push(100e18);
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < 5; ++i) {
            factory.proposeListing(tokens[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < 5; ++i) {
            factory.executeListing(tokens[i]);
        }

        index = IndexHub(factory.createIndex("Rebalanced", "RBL", tokens, startUnits, 0));
        _issue(index, alice, SHARES);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _issue(IndexHub idx, address who, uint256 shares) internal {
        uint256[] memory need = idx.previewIssue(shares);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            vm.prank(who);
            MockERC20(tokens[i]).approve(address(idx), need[i]);
        }
        vm.prank(who);
        idx.issue(shares, who);
    }

    function _expectedTargets() internal pure returns (uint256[] memory t) {
        t = new uint256[](5);
        (t[0], t[1], t[2], t[3], t[4]) = (200e18, 75e18, 75e18, 75e18, 75e18);
    }

    /// @dev Warps to the first moment a rebalance may start and starts one as a stranger.
    function _start(IndexHub idx) internal returns (uint256 eta) {
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        idx.startRebalance(0);
        (eta,,) = idx.pendingRebalance();
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

    // ---------------------------------------------------------------------
    // start
    // ---------------------------------------------------------------------

    function test_constantsAndIdleViews() public {
        assertEq(index.REBALANCE_DELAY(), 2 days);
        assertEq(index.MIN_REBALANCE_INTERVAL(), 28 days);
        assertEq(index.AUCTION_DURATION(), 24 hours);
        assertEq(index.AUCTION_START_MULTIPLIER(), 1.5e18);
        assertEq(index.AUCTION_END_MULTIPLIER(), 0.9e18);
        assertEq(index.MIN_TURNOVER(), 0.005e18);
        assertEq(index.MIN_SETTLEMENT_RATIO(), 0.875e18);
        (uint256 eta, uint256 keepMask, uint256[] memory targets) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(keepMask, 0);
        assertEq(targets.length, 0);
        assertEq(index.currentMultiplier(), 0);
        vm.expectRevert(IIndexHub.NoPendingRebalance.selector);
        index.previewRebalance();
    }

    function test_startRebalance_snapshotsTheRuleAfterTheInterval() public {
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0);

        vm.warp(earliest);
        (uint256[] memory preview, uint256 turnover) = index.previewTarget(0);
        assertEq(turnover, 0.2e18);
        uint256 eta = block.timestamp + index.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.RebalanceStarted(1, 1, stranger, _expectedTargets(), 0, eta);
        vm.prank(stranger);
        index.startRebalance(0);

        (uint256 pendingEta, uint256 keepMask, uint256[] memory targets) = index.pendingRebalance();
        assertEq(pendingEta, eta);
        assertEq(keepMask, 0);
        assertEq(keccak256(abi.encode(targets)), keccak256(abi.encode(_expectedTargets())));
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(_expectedTargets())));
        assertEq(keccak256(abi.encode(_units(index))), keccak256(abi.encode(startUnits)), "nothing changes yet");
        assertEq(index.currentMultiplier(), 0, "no auction during the notice");
    }

    function test_startRebalance_pendingThenExpiredRestart() public {
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
        (uint256 nextEta,,) = index.pendingRebalance();
        assertEq(nextEta, block.timestamp + index.REBALANCE_DELAY());
    }

    /// @dev LR-05: no test told a fresh snapshot from the expired one, because prices never moved between the two. A
    ///      restart that kept the old targets, the stale snapshot XA-02 guards against, passed every test. XA-01, the
    ///      distorted-TWAP finding this once cited beside it, is retired with the pool oracle.
    function test_LR05_aRestartAfterAnUnfilledAuctionTakesAFreshSnapshot() public {
        uint256 eta = _start(index);
        (,, uint256[] memory first) = index.pendingRebalance();
        assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(_expectedTargets())));

        // Nobody fills, and the first component's price falls by a third before anyone restarts.
        vm.warp(eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY());
        market.movePrice(tokens[0], 2, 3);
        (uint256[] memory fresh,) = index.previewTarget(0);
        assertTrue(keccak256(abi.encode(fresh)) != keccak256(abi.encode(first)), "the rule now wants other targets");

        vm.prank(stranger);
        index.startRebalance(0);
        (,, uint256[] memory second) = index.pendingRebalance();
        assertEq(second.length, 5, "the expired targets were cleared, not appended to");
        assertEq(keccak256(abi.encode(second)), keccak256(abi.encode(fresh)), "the restart snapshots the rule again");
    }

    function test_startRebalance_keepMaskRules() public {
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

        (, uint256 keepMask, uint256[] memory targets) = index.pendingRebalance();
        assertEq(keepMask, 1 << 1);
        assertEq(targets[1], 100e18, "the kept component keeps its units");
    }

    function test_startRebalance_ownerCanPassAKeepMask() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(owner);
        index.startRebalance(1 << 4);
        (, uint256 keepMask,) = index.pendingRebalance();
        assertEq(keepMask, 1 << 4);
    }

    function test_startRebalance_rejectsTooLittleTurnover() public {
        uint256[] memory onTarget = new uint256[](5);
        (onTarget[0], onTarget[1], onTarget[2], onTarget[3], onTarget[4]) = (600e18, 100e18, 100e18, 100e18, 100e18);
        vm.prank(alice);
        IndexHub balanced = IndexHub(factory.createIndex("Balanced", "BAL", tokens, onTarget, 0));
        vm.warp(balanced.lastRebalance() + balanced.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, 0));
        balanced.startRebalance(0);
    }

    /// @dev DA-22. The test above only ever produced a turnover of zero, so replacing the MIN_TURNOVER comparison
    ///      with a plain non-zero check left the whole suite green. This pins the boundary itself: a real but
    ///      too-small move is refused, and the first move at the threshold is not.
    function test_DA22_theTurnoverGateIsTheThresholdNotMerelyNonZero() public {
        uint256[] memory nearTarget = new uint256[](5);
        (nearTarget[0], nearTarget[1], nearTarget[2], nearTarget[3], nearTarget[4]) =
        (604e18, 99e18, 99e18, 99e18, 99e18);
        vm.prank(alice);
        IndexHub drifted = IndexHub(factory.createIndex("Drifted", "DRIFT", tokens, nearTarget, 0));

        (, uint256 turnover) = drifted.previewTarget(0);
        assertGt(turnover, 0, "the basket really is off target");
        assertLt(turnover, drifted.MIN_TURNOVER(), "but by less than the gate allows");

        vm.warp(drifted.lastRebalance() + drifted.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, turnover));
        drifted.startRebalance(0);

        // The index in setUp is far enough off target to clear the same gate, so the check is a threshold.
        (, uint256 enough) = index.previewTarget(0);
        assertGe(enough, index.MIN_TURNOVER());
        _start(index);
    }

    // ---------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------

    function test_cancelRebalance_andTheRestartCooldown() public {
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

        (uint256 eta,, uint256[] memory targets) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(targets.length, 0);
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
        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        vm.prank(owner);
        index.cancelRebalance();
        (uint256 pendingEta,,) = index.pendingRebalance();
        assertEq(pendingEta, 0);
    }

    /// @dev VR-04. An auction that expired unfilled already holds strangers off until its deadline plus
    ///      REBALANCE_DELAY. Cancelling it only clears the stale proposal the views still report, so it must not
    ///      re-arm the cooldown from the moment of the cancel and push that hold-off further out. How much the old
    ///      code added depended purely on when the cancel landed: one second just after the expiry, and a full
    ///      REBALANCE_DELAY when timed at the moment strangers were about to be let in, which is the case below.
    function test_VR04_cancellingAnExpiredAuctionDoesNotExtendTheHoldOff() public {
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

    /// @dev VR-04, cancelled one second after the auction lapsed: still no extension, and the hold-off the expiry
    ///      granted is reported unchanged.
    function test_VR04_anExpiredCancelReportsTheExpirysOwnHoldOff() public {
        uint256 eta = _start(index);
        uint256 fromExpiry = eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY();
        vm.warp(eta + index.AUCTION_DURATION() + 1);
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), fromExpiry);
        assertLt(index.restartAllowedAt(), block.timestamp + index.REBALANCE_DELAY(), "nothing was added");
    }

    /// @dev VR-04, the live half: cancelling an auction that has NOT expired still arms a full REBALANCE_DELAY, and
    ///      never shortens a hold-off that already ran longer.
    function test_VR04_cancellingALiveAuctionStillArmsTheFullCooldown() public {
        uint256 eta = _start(index);
        vm.warp(eta + 1 hours);
        vm.prank(guardian);
        index.cancelRebalance();
        assertEq(index.restartAllowedAt(), block.timestamp + index.REBALANCE_DELAY(), "a live cancel costs two days");

        vm.warp(index.restartAllowedAt());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta2,,) = index.pendingRebalance();
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
        assertEq(index.currentMultiplier(), 0);
    }

    function test_executeRebalance_atTheOpen() public {
        uint256 eta = _start(index);
        vm.warp(eta);
        assertEq(index.currentMultiplier(), 1.5e18);

        uint256[] memory units = new uint256[](5);
        uint256[] memory amountsOut = new uint256[](5);
        uint256[] memory amountsIn = new uint256[](5);
        (units[0], amountsIn[0]) = (250e18, 1_500e18); // 100 + 100 * 1.5 extra units, times 10 shares
        for (uint256 i = 1; i < 5; ++i) {
            (units[i], amountsOut[i]) = (75e18, 250e18);
        }
        (uint256 m, uint256[] memory previewUnits, uint256[] memory previewOut, uint256[] memory previewIn) =
            index.previewRebalance();
        assertEq(m, 1.5e18);
        assertEq(
            keccak256(abi.encode(previewUnits, previewOut, previewIn)),
            keccak256(abi.encode(units, amountsOut, amountsIn))
        );

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.Rebalanced(1, 1, address(executor), 1.5e18, units, amountsOut, amountsIn);
        executor.execute(index, "fill");

        assertEq(keccak256(abi.encode(_units(index))), keccak256(abi.encode(units)));
        assertEq(index.rebalanceNonce(), 1);
        assertEq(index.lastRebalance(), block.timestamp);
        (uint256 pendingEta,, uint256[] memory targets) = index.pendingRebalance();
        assertEq(pendingEta, 0);
        assertEq(targets.length, 0);
        assertEq(MockERC20(tokens[1]).balanceOf(address(executor)), 250e18, "the executor keeps what it was sent");
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), 2_500e18);
        assertEq(executor.calls(), 1);
        assertEq(executor.lastData(), "fill");
        assertEq(keccak256(abi.encode(executor.lastAmountsOut())), keccak256(abi.encode(amountsOut)));
        assertEq(keccak256(abi.encode(executor.lastAmountsIn())), keccak256(abi.encode(amountsIn)));
        _assertBacked(index);

        vm.expectRevert(IIndexHub.NoPendingRebalance.selector);
        executor.execute(index, "");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceTooSoon.selector, block.timestamp + 28 days));
        index.startRebalance(0);
    }

    function test_executeRebalance_multiplierDecay() public {
        uint256 eta = _start(index);
        vm.warp(eta + 1);
        assertEq(index.currentMultiplier(), 1.5e18 - uint256(0.6e18) / 1 days, "rounds up in holders' favour");
        vm.warp(eta + 12 hours);
        assertEq(index.currentMultiplier(), 1.2e18);
        vm.warp(eta + 24 hours);
        assertEq(index.currentMultiplier(), 0.9e18);

        executor.execute(index, "");
        uint256[] memory units = _units(index);
        assertEq(units[0], 190e18, "the growing component gets 90% of its extra units at the close");
        assertEq(units[1], 75e18, "shrinking components go straight to target");
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), 1_900e18);
        _assertBacked(index);
    }

    function test_executeRebalance_growingUnitsRoundUp() public {
        uint256[] memory odd = new uint256[](5);
        (odd[0], odd[1], odd[2], odd[3], odd[4]) = (100e18 + 7, 100e18, 100e18, 100e18, 100e18);
        vm.prank(stranger);
        IndexHub idx = IndexHub(factory.createIndex("Odd", "ODD", tokens, odd, 0));
        _issue(idx, alice, SHARES);
        uint256 eta = _start(idx);
        (,, uint256[] memory targets) = idx.pendingRebalance();
        vm.warp(eta + 1);
        (uint256 m, uint256[] memory units,,) = idx.previewRebalance();
        uint256 exact = (targets[0] - odd[0]) * m;
        assertTrue(exact % WAD != 0, "the growth does not divide evenly, so the rounding shows");
        assertEq(units[0], odd[0] + exact / WAD + 1, "growing units round up, in the index's favour");
    }

    function test_executeRebalance_emptyIndexSettlesAtParity() public {
        vm.prank(stranger);
        IndexHub empty = IndexHub(factory.createIndex("Empty", "EMPTY", tokens, startUnits, 0));
        uint256 eta = _start(empty);
        vm.warp(eta + 1 hours);
        assertEq(empty.currentMultiplier(), WAD);

        executor.setMode(MockRebalanceExecutor.Mode.Noop);
        executor.execute(empty, "");
        assertEq(keccak256(abi.encode(_units(empty))), keccak256(abi.encode(_expectedTargets())));
    }

    function test_executeRebalance_revertsWhenUnderfunded() public {
        uint256 eta = _start(index);
        vm.warp(eta);
        executor.setMode(MockRebalanceExecutor.Mode.Short);
        executor.setShortComponent(0);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, tokens[0], 2_500e18 - 1, 2_500e18)
        );
        executor.execute(index, "");

        executor.setMode(MockRebalanceExecutor.Mode.Noop);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceUnderfunded.selector, tokens[0], 1_000e18, 2_500e18));
        executor.execute(index, "");
        assertEq(
            keccak256(abi.encode(_units(index))), keccak256(abi.encode(startUnits)), "a failed fill changes nothing"
        );
    }

    function test_executeRebalance_onlyContracts() public {
        uint256 eta = _start(index);
        vm.warp(eta);
        vm.prank(stranger);
        vm.expectRevert(bytes("")); // the callback to an account without code reverts with no data
        index.executeRebalance("");
    }

    function test_executeRebalance_callbackCannotReenterButIndexTransfersWork() public {
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
        uint256 eta = _start(index);
        pausable.setPaused(true);
        vm.warp(eta);
        vm.expectRevert(bytes("paused"));
        executor.execute(index, ""); // the paused component must shrink, so its transfer fails

        vm.startPrank(guardian);
        index.cancelRebalance();
        index.startRebalance(1 << 1);
        vm.stopPrank();
        (eta,,) = index.pendingRebalance();
        vm.warp(eta);
        uint256 pausedBalance = pausable.balanceOf(address(index));
        executor.execute(index, "");

        assertEq(_units(index)[1], 100e18);
        assertEq(pausable.balanceOf(address(index)), pausedBalance, "the paused component never moved");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    function test_executeRebalance_claimsSurvive() public {
        vm.prank(alice);
        index.redeemSkipping(2e18, alice, (1 << 0) | (1 << 2));
        assertEq(index.totalClaims(tokens[0]), 200e18);
        assertEq(index.totalClaims(tokens[2]), 200e18);

        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION());
        executor.execute(index, "");
        assertEq(MockERC20(tokens[0]).balanceOf(address(index)), 1_720e18, "8 shares * 190 units + the claim");
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), 800e18, "8 shares * 75 units + the claim");
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
        uint256 eta = _start(index);
        vm.warp(eta);
        (,, uint256[] memory outBefore,) = index.previewRebalance();
        MockERC20(tokens[2]).mint(address(index), 1_000e18);
        (,, uint256[] memory outAfter,) = index.previewRebalance();
        assertEq(outAfter[2], outBefore[2], "amounts come from units and supply, never balances");
        executor.execute(index, "");
        assertEq(MockERC20(tokens[2]).balanceOf(address(index)), 750e18 + 1_000e18);
    }

    // ---------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------

    function testFuzz_multiplierFallsFromStartToEnd(uint256 elapsed) public {
        uint256 eta = _start(index);
        elapsed = bound(elapsed, 0, index.AUCTION_DURATION() - 1);
        vm.warp(eta + elapsed);
        uint256 now_ = index.currentMultiplier();
        vm.warp(eta + elapsed + 1);
        uint256 next = index.currentMultiplier();
        assertLe(next, now_);
        assertLe(now_, 1.5e18);
        assertGe(next, 0.9e18);
    }

    function testFuzz_settlementKeepsBacking(uint256 extraShares, uint256 elapsed, uint256 skipped) public {
        extraShares = bound(extraShares, 1, 1_000_000e18);
        _issue(index, stranger, extraShares);
        skipped = bound(skipped, 0, SHARES);
        if (skipped != 0) {
            vm.prank(alice);
            index.redeemSkipping(skipped, alice, 1 << 0);
        }
        uint256 eta = _start(index);
        vm.warp(eta + bound(elapsed, 0, index.AUCTION_DURATION()));
        executor.execute(index, "");

        uint256[] memory units = _units(index);
        assertEq(units[1], 75e18);
        assertGe(units[0], 190e18);
        assertLe(units[0], 250e18);
        _assertBacked(index);
    }

    // ---------------------------------------------------------------------
    // 2026-09-19 deep audit
    // ---------------------------------------------------------------------

    /// @dev DA-13. Settlement amounts are recomputed from the supply in the settling block, and issue stays open
    ///      through the auction, so anyone could enlarge a fill an executor had already funded from a simulation and
    ///      make it revert for the price of gas. The bounded entry point lets an executor say what it will deliver.
    function test_DA13_aBoundedFillRefusesAnEnlargedSettlement() public {
        uint256 eta = _start(index);
        vm.warp(eta);
        (,,, uint256[] memory quoted) = index.previewRebalance();

        // A stranger issues dust into the same block, which scales every leg up.
        _issue(index, stranger, 1e14);
        (,,, uint256[] memory enlarged) = index.previewRebalance();
        assertGt(enlarged[0], quoted[0], "the settlement grew under the executor");

        vm.expectRevert(abi.encodeWithSelector(IIndexHub.RebalanceMovedOn.selector, tokens[0], enlarged[0], quoted[0]));
        executor.executeBounded(index, "", quoted);
        assertEq(index.rebalanceNonce(), 0, "the bounded fill did not settle");

        // The same executor settles once it is told the larger figure, and the open entry point never bound anything.
        executor.executeBounded(index, "", enlarged);
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    function test_DA13_aBoundedFillRejectsAMalformedBound() public {
        uint256 eta = _start(index);
        vm.warp(eta);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        executor.executeBounded(index, "", new uint256[](4));
    }

    /// @dev DA-05. `startRebalance` freezes the rule's targets and settlement happens up to three days later at the
    ///      rates those targets fix. The 1.5-to-0.9 band bounds the multiplier on the bought legs only, so whatever the
    ///      market moved in between was on top of it and unbounded: an executor filled only when the drift favoured
    ///      them, at the index's expense. The settlement now has to clear MIN_SETTLEMENT_RATIO of what it pays out,
    ///      priced with snapshot-quality prices read in the settling block.
    function test_DA05_aSettlementTheMarketMovedPastIsRefused() public {
        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION()); // the auction floor, where the drift is worth the most

        // The four components the index sells appreciate 50% against the one it buys over the notice window.
        for (uint256 i = 1; i < 5; ++i) {
            market.movePrice(tokens[i], 3, 2);
        }
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        (uint256 outValue, uint256 inValue) = IIndexRule(factory.RULE()).settlementValues(tokens, amountsOut, amountsIn);
        uint256 required = outValue * index.MIN_SETTLEMENT_RATIO() / WAD;
        assertLt(inValue, required, "the fill is worth less than the basket it takes");

        vm.expectRevert(abi.encodeWithSelector(IIndexHub.SettlementValueTooLow.selector, inValue, outValue, required));
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 0, "nothing settled at three-day-old rates");
        _assertBacked(index);

        // Back where the snapshot found them, the same fill settles.
        for (uint256 i = 1; i < 5; ++i) {
            market.setPrice(tokens[i], ONE_DOLLAR);
        }
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1);
        _assertBacked(index);
    }

    /// @dev DA-05. The guard is on the ratio between the two sides, not on either price, so a market-wide move is not
    ///      drift: every leg reprices together and the settlement it was snapshotted for still goes through. Guarding
    ///      each component's own price instead would block the routine case and leave the harmful one open.
    function test_DA05_aMarketWideMoveIsNotDrift() public {
        uint256 eta = _start(index);
        vm.warp(eta + index.AUCTION_DURATION());
        for (uint256 i = 0; i < 5; ++i) {
            market.movePrice(tokens[i], 3, 2);
        }
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "the whole market moving is not a reason to refuse a fill");
        _assertBacked(index);
    }

    /// @dev DA-14. `executeRebalance` read `balanceOf` on every component to build its backing check, so a keep mask
    ///      routed around a component that could not be transferred but not around one whose reads revert. A component
    ///      that neither sends nor receives anything is now not read at all.
    function test_DA14_aKeptComponentWithBrokenReadsDoesNotBlockSettlement() public {
        pausable.setPaused(true);
        pausable.setReadsBroken(true);
        // The component really is unreadable, so the settlement below cannot be passing for some other reason.
        vm.expectRevert(bytes("reads broken"));
        pausable.balanceOf(address(index));

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(owner);
        index.startRebalance(1 << 1); // keep the broken component
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta);

        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        assertEq(amountsOut[1], 0, "the kept component neither sends");
        assertEq(amountsIn[1], 0, "nor receives");

        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "the settlement no longer touches the kept component at all");
        assertEq(_units(index)[1], 100e18, "and its units are unchanged");
    }

    /// @dev RT-01, DA-14's capped twin. A capped snapshot prices a kept component, because its market cap sits under
    ///      every other component's weight (DA-06), and the rule read the component's decimals from the token to do
    ///      it. A component whose contract stops answering altogether, as one behind a proxy whose implementation is
    ///      withdrawn does, made every capped start revert, the keep mask's included, and no config change could
    ///      help, since `checkConfig` reads the token too. The rule now prices a listed token with the decimals the
    ///      factory recorded at listing and calls only its feed.
    function test_RT01_aCappedKeepMaskRoutesAroundAComponentThatNoLongerAnswers() public {
        IndexHub capped = IndexHub(factory.createIndex("Capped", "CAP", tokens, startUnits, Methodology.CAPPED));
        _issue(capped, alice, SHARES);
        pausable.setPaused(true);
        pausable.setReadsBroken(true);
        // No ERC-20 read of the component answers, its decimals included, so nothing below can be reading it.
        vm.expectRevert(bytes("reads broken"));
        pausable.decimals();

        vm.warp(capped.lastRebalance() + capped.MIN_REBALANCE_INTERVAL());
        vm.prank(guardian);
        capped.startRebalance(1 << 1); // keep the dead component
        (uint256 eta,,) = capped.pendingRebalance();
        vm.warp(eta);

        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = capped.previewRebalance();
        assertEq(amountsOut[1], 0, "the kept component neither sends");
        assertEq(amountsIn[1], 0, "nor receives");
        assertGt(amountsOut[0] + amountsIn[0], 0, "while the others trade");

        executor.execute(capped, "");
        assertEq(capped.rebalanceNonce(), 1, "a capped index rebalances around a component that no longer answers");
        assertEq(_units(capped)[1], 100e18, "and leaves its units alone");
    }

    /// @dev RT-01, the rule's other pricing paths. The capped start above reaches only the snapshot, and a settlement
    ///      skips a kept leg before pricing it (DA-14), so each remaining path that prices a listed token is held to
    ///      the same answer once the token stops answering: the settlement's valuation of a leg that does move, the
    ///      index price, the weights and the starting units.
    function test_RT01_everyPricingPathIgnoresTheTokenItself() public {
        IIndexRule rule = IIndexRule(factory.RULE());
        uint256 nav = rule.navPerToken(address(index));
        (uint256[] memory w,,) = rule.weights(tokens, Methodology.CAPPED);
        uint256[] memory start = rule.initialUnits(tokens, Methodology.CAPPED, 100e18);
        uint256[] memory out = new uint256[](tokens.length);
        uint256[] memory none = new uint256[](tokens.length);
        out[1] = 1e18;
        (uint256 outValue,) = rule.settlementValues(tokens, out, none);

        pausable.setReadsBroken(true);
        assertEq(rule.navPerToken(address(index)), nav, "the index price");
        (uint256[] memory w2,,) = rule.weights(tokens, Methodology.CAPPED);
        assertEq(w2, w, "the weights");
        assertEq(rule.initialUnits(tokens, Methodology.CAPPED, 100e18), start, "the starting units");
        (uint256 outValue2,) = rule.settlementValues(tokens, out, none);
        assertEq(outValue2, outValue, "and the settlement's valuation of the dead component's leg");
    }

    /// @dev RT-04, the rule's half. The fixture's rule wants the first component at 60% of the basket and holds it at
    ///      20%, so the basket sits 40% from its rule while the band lets this step trade only 20%. Keeping the first
    ///      component leaves four equal holdings the rule weighs equally, so nothing is short.
    function test_RT04_shortfallIsTheDistanceToTheRuleBeforeTheBand() public view {
        IIndexRule rule = IIndexRule(factory.RULE());
        uint256[] memory units = _units(index);
        (, uint256 turnover) = rule.targetUnits(tokens, units, 0, 0);
        assertEq(turnover, 0.2e18, "the step the band allows");
        assertEq(rule.shortfall(tokens, units, 0, 0), 0.4e18, "the distance the rule wants closed");
        assertEq(rule.shortfall(tokens, units, 0, 1 << 0), 0, "the kept component is not counted");
    }

    function test_RT04_shortfallRefusesMismatchedLengths() public {
        IIndexRule rule = IIndexRule(factory.RULE());
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        rule.shortfall(tokens, new uint256[](1), 0, 0);
    }

    /// @dev RT-04. MIN_TURNOVER measured the band-clipped step alone, and the band lets a growing component at most
    ///      double, so a step buys at most that component's own holding. An index holding 0.05% of the component its
    ///      rule wants at 60% could therefore never start a rebalance, for a stranger, the owner or the guardian, and
    ///      stayed off its rule for good. The gate now also accepts a step that trades something when the basket sits at
    ///      least MIN_TURNOVER from its rule, and each settlement doubles the component again.
    function test_RT04_aBasketFarFromItsRuleStartsThoughEachStepIsSmall() public {
        uint256[] memory units = new uint256[](5);
        (units[0], units[1], units[2], units[3], units[4]) = (0.2e18, 100e18, 100e18, 100e18, 100e18);
        IndexHub stuck = IndexHub(factory.createIndex("Stuck", "STK", tokens, units, 0));
        _issue(stuck, alice, SHARES);

        vm.warp(stuck.lastRebalance() + stuck.MIN_REBALANCE_INTERVAL());
        (, uint256 turnover) = stuck.previewTarget(0);
        assertLt(turnover, stuck.MIN_TURNOVER(), "the step alone is below the gate");
        assertGt(turnover, 0, "but it trades something");
        uint256 distance = IIndexRule(factory.RULE()).shortfall(tokens, units, 0, 0);
        assertGt(distance, 0.59e18, "while the basket sits almost 60% from its rule");

        uint256 eta = _start(stuck);
        (,, uint256[] memory targets) = stuck.pendingRebalance();
        assertEq(targets[0], 0.4e18, "the snapshot doubles the component the rule wants");
        vm.warp(eta);
        executor.execute(stuck, "");
        // Filled at the opening multiplier, the growth settles at 1.5 times: 0.2 + 1.5 * 0.2.
        assertEq(_units(stuck)[0], 0.5e18, "and the fill delivers it");
        _assertBacked(stuck);

        _start(stuck);
        (,, targets) = stuck.pendingRebalance();
        assertEq(targets[0], 1e18, "the next rebalance doubles it again");
    }

    /// @dev RT-04, reviewed. A component held at one raw unit has a floor of one raw unit and can never shrink, so an
    ///      excess it holds is a distance no rebalance closes. Measured on the growing side it kept the gate open on
    ///      every later drift: here one raw unit worth 1% of the index against a 0.2% weight, then a routine 0.4% supply
    ///      refresh, let a stranger start a 0.1% step the gate exists to refuse. The distance is measured on the side
    ///      that sells, over components the band can still shrink, which leaves the stuck unit out.
    function test_RT04_aComponentStuckAtOneRawUnitDoesNotHoldTheGateOpen() public {
        address[] memory coarse = new address[](3);
        coarse[0] = _listNew(6, 10_000e8, 400_800); // one raw unit is a cent; 0.2% of the rule
        coarse[1] = _listNew(18, 1e8, 1e24);
        coarse[2] = _listNew(18, 1e8, 1e24);
        uint256[] memory units = new uint256[](3);
        (units[0], units[1], units[2]) = (1, 0.495e18, 0.495e18);
        IndexHub idx = IndexHub(factory.createIndex("Coarse", "CRS", coarse, units, Methodology.UNCAPPED));
        IIndexRule rule = IIndexRule(factory.RULE());

        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        market.setPrice(coarse[0], 10_000e8);
        market.setPrice(coarse[1], 1e8);
        market.setPrice(coarse[2], 1e8);
        (, uint256 turnover) = idx.previewTarget(0);
        assertEq(turnover, 0, "the only excess sits in a unit that cannot shrink");
        assertEq(rule.shortfall(coarse, units, Methodology.UNCAPPED, 0), 0, "and the distance leaves it out");

        // A routine refresh moves one weight by 0.4%: a small step between the two free components, which the gate
        // refuses, as it did before RT-04, since nothing the band can close sits 0.5% from the rule.
        IIndexFactory.TokenConfig memory refresh = market.configWith(coarse[1], 1e8, 1.004e24);
        vm.prank(owner);
        factory.proposeConfig(coarse[1], refresh);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(coarse[1]);
        market.setPrice(coarse[0], 10_000e8);
        market.setPrice(coarse[2], 1e8);
        (, turnover) = idx.previewTarget(0);
        assertGt(turnover, 0, "the step trades something");
        assertLt(turnover, idx.MIN_TURNOVER(), "but less than the gate");
        assertLt(rule.shortfall(coarse, units, Methodology.UNCAPPED, 0), idx.MIN_TURNOVER(), "as does the distance");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, turnover));
        idx.startRebalance(0);
    }

    /// @dev RT-04, reviewed. The distance a keep-mask start is measured by leaves the kept component out, as its targets
    ///      do. Measured over the whole basket instead, a far-off kept component would let a guardian start any sliver:
    ///      here the kept component sits 40% from its rule while the rebalanced four sit 0.075% from theirs.
    function test_RT04_aKeepMaskStartIsMeasuredOverTheRebalancedComponentsOnly() public {
        uint256[] memory units = new uint256[](5);
        (units[0], units[1], units[2], units[3], units[4]) = (100e18, 100e18, 100e18, 100e18, 100.4e18);
        IndexHub idx = IndexHub(factory.createIndex("Kept", "KPT", tokens, units, Methodology.UNCAPPED));
        _issue(idx, alice, SHARES);
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        (, uint256 turnover) = idx.previewTarget(1 << 0);
        assertGt(turnover, 0, "the rebalanced four trade a little");
        assertLt(IIndexRule(factory.RULE()).shortfall(tokens, units, 0, 1 << 0), idx.MIN_TURNOVER());
        assertGt(
            IIndexRule(factory.RULE()).shortfall(tokens, units, 0, 0), idx.MIN_TURNOVER(), "the whole basket does not"
        );
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, turnover));
        idx.startRebalance(1 << 0);
    }

    /// @dev RT-04, reviewed. Under the capped methodology a kept component still weighs in the snapshot, so the distance
    ///      is the rebalanced components' distance from their weights renormalised over those components, which the
    ///      uncapped case, whose kept caps are zeroed before weighting, could not tell apart from weights over the whole.
    ///      The fixture's capped weights are 30% and 17.5% four times; keeping the second leaves 30% against 52.5%.
    function test_RT04_aCappedKeepMaskRenormalisesTheWeights() public view {
        IIndexRule rule = IIndexRule(factory.RULE());
        uint256[] memory units = _units(index);
        (uint256[] memory w,,) = rule.weights(tokens, Methodology.CAPPED);
        uint256 activeWeight = 0;
        uint256 activeValue = 0;
        for (uint256 i = 0; i < 5; ++i) {
            if (i == 1) continue;
            activeWeight += w[i];
            activeValue += units[i] * rule.price(tokens[i]);
        }
        uint256 over = 0;
        for (uint256 i = 0; i < 5; ++i) {
            if (i == 1) continue;
            uint256 want = Math.mulDiv(activeValue, w[i], activeWeight);
            uint256 held = units[i] * rule.price(tokens[i]);
            if (held > want) over += held - want;
        }
        uint256 expected = Math.mulDiv(over, WAD, activeValue);
        assertApproxEqAbs(rule.shortfall(tokens, units, Methodology.CAPPED, 1 << 1), expected, 1e3);
        assertApproxEqAbs(expected, 0.113636363636363636e18, 1e3, "three of 100 against 84.85 each, over 400");
    }

    /// @dev RT-04, reviewed. Under the uncapped methodology a kept component is not read at all, so a kept component
    ///      whose feed went stale blocks neither the targets nor the distance.
    function test_RT04_anUncappedKeptComponentWithAStaleFeedIsNotRead() public {
        IIndexRule rule = IIndexRule(factory.RULE());
        uint256[] memory units = _units(index);
        market.setAge(tokens[1], uint256(market.STALENESS()) + 1);
        vm.expectRevert();
        rule.price(tokens[1]);
        rule.targetUnits(tokens, units, 0, 1 << 1);
        // The kept cap is zeroed, so the rule wants 6/9 of the 400 in the first and 1/9 in each other: the three hold 100
        // each against 44.4, 166.7 over 400.
        assertEq(rule.shortfall(tokens, units, 0, 1 << 1), uint256(5e18) / 12, "three of 100 held against 44.4");
    }

    function _listNew(uint8 decimals, int256 price8, uint256 referenceSupply) internal returns (address token) {
        token = address(new MockERC20("N", "N", decimals));
        IIndexFactory.TokenConfig memory config = market.configWith(token, price8, referenceSupply);
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    /// @dev RT-04's gate at its edges, with the rule's answers fixed by mocked calls. A step under MIN_TURNOVER starts
    ///      when the basket's distance from its rule is exactly MIN_TURNOVER and not a wei under it, and a step that
    ///      trades nothing is refused however far the basket sits, since it would certify value that is not traded
    ///      (DA-08).
    function test_RT04_DA08_theDistanceGateAtItsEdges() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (uint256[] memory targets,) = index.previewTarget(0);
        address rule = factory.RULE();
        uint256 threshold = index.MIN_TURNOVER();
        bytes memory snapshot = abi.encodeWithSelector(IIndexRule.targetUnits.selector);
        bytes memory distance = abi.encodeWithSelector(IIndexRule.shortfall.selector);

        vm.mockCall(rule, snapshot, abi.encode(targets, 0));
        vm.mockCall(rule, distance, abi.encode(1e18));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, 0));
        index.startRebalance(0);

        vm.mockCall(rule, snapshot, abi.encode(targets, 1));
        vm.mockCall(rule, distance, abi.encode(threshold - 1));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, 1));
        index.startRebalance(0);

        vm.mockCall(rule, distance, abi.encode(threshold));
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        assertGt(eta, 0, "a one-wei step on a basket exactly MIN_TURNOVER from its rule starts");
        vm.clearMockedCalls();
    }

    // ---------------------------------------------------------------------
    // Security audit of 2026-09-23
    // ---------------------------------------------------------------------

    /// @dev Starts a rebalance as a stranger and warps to the auction's opening, at the 1.5 multiplier.
    function _toAuction(IndexHub idx) internal {
        vm.warp(_start(idx));
    }

    /// @dev CR-I28 and CR-L06. DA-05's own test reads its expected floor back from `MIN_SETTLEMENT_RATIO()` and from
    ///      `settlementValues`, so it agreed with whatever the code said: any ratio from 0.600000000000000001 to 0.9
    ///      passed the suite, and so did a floor rounded up. With the rule's valuation fixed by a mocked call, the fill
    ///      here sits one wei under the floor and then exactly on it, and the second floor carries a remainder, so the
    ///      ratio, the comparison and the rounding are each pinned.
    function test_DA05_CRI28_theSettlementFloorSitsExactlyOnTheRatio() public {
        assertEq(index.MIN_SETTLEMENT_RATIO(), 0.875e18, "87.5% of what the index pays out (CR-L06)");
        _toAuction(index);
        address rule = factory.RULE();
        bytes memory valuation = abi.encodeWithSelector(IIndexRule.settlementValues.selector);

        vm.mockCall(rule, valuation, abi.encode(1_000e18, 875e18 - 1));
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.SettlementValueTooLow.selector, 875e18 - 1, 1_000e18, 875e18));
        executor.execute(index, "");

        // 87.5% of 1,000e18 + 1 is 875e18 + 0.875: the floor rounds down, so a fill worth exactly 875e18 clears it.
        vm.mockCall(rule, valuation, abi.encode(1_000e18 + 1, 875e18));
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "a fill exactly on the rounded-down floor settles");
        vm.clearMockedCalls();
        _assertBacked(index);
    }

    /// @dev CR-I28, the rule's half of the gate's arithmetic: each leg is valued rounded down, so neither side is ever
    ///      credited with value it does not carry. At a WAD price of 1.5e18 one raw unit is worth 1.5 wei and three
    ///      are worth 4.5; rounded down, 1 and 4.
    function test_CRI28_eachLegOfASettlementIsValuedRoundedDown() public {
        market.setPrice(tokens[0], 1.5e8); // a dollar and a half per whole 18-decimal token: a WAD price of 1.5e18
        address[] memory one = new address[](1);
        uint256[] memory out = new uint256[](1);
        uint256[] memory into = new uint256[](1);
        (one[0], out[0], into[0]) = (tokens[0], 1, 3);
        (uint256 outValue, uint256 inValue) = IIndexRule(factory.RULE()).settlementValues(one, out, into);
        assertEq(outValue, 1, "one raw unit, worth 1.5 wei, counts as 1");
        assertEq(inValue, 4, "three, worth 4.5 wei, count as 4");
    }

    /// @dev CR-L06. At the old ratio of 0.85, a lone executor waiting for the 0.9 floor could fill after the legs the
    ///      index buys had lost up to 5.9% against the legs it sells, and it kept more than 15% of the traded value at
    ///      market prices whenever the feeds also trailed a fast market. Here the four sold legs rise 4% against the
    ///      bought one: at the floor the fill is worth 86.5% of what it takes, which 0.85 let through and 0.875 refuses.
    ///      An hour earlier, at a multiplier of 0.925, the same drift leaves it at 88.9% and it settles: the ratio moves
    ///      a lone executor's fill up the auction, toward the holders, rather than stopping it.
    function test_CRL06_aDriftTheOldRatioLetThroughIsRefusedAtTheFloor() public {
        uint256 eta = _start(index);
        for (uint256 i = 1; i < 5; ++i) {
            market.movePrice(tokens[i], 104, 100);
        }
        uint256 beforeTheFloor = vm.snapshotState();

        vm.warp(eta + index.AUCTION_DURATION()); // the floor, 0.9
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = index.previewRebalance();
        (uint256 outValue, uint256 inValue) = IIndexRule(factory.RULE()).settlementValues(tokens, amountsOut, amountsIn);
        assertEq(outValue, 1_040e18, "1,000 units sold, now worth 4% more");
        assertEq(inValue, 900e18, "900 units bought at the floor");
        assertGt(inValue, outValue * 0.85e18 / WAD, "the old ratio let this through");
        uint256 required = outValue * 0.875e18 / WAD;
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.SettlementValueTooLow.selector, inValue, outValue, required));
        executor.execute(index, "");

        vm.revertToState(beforeTheFloor);
        vm.warp(eta + 23 hours); // a multiplier of 0.925
        executor.execute(index, "");
        assertEq(index.rebalanceNonce(), 1, "earlier in the auction the same drift still clears");
        _assertBacked(index);
    }

    /// @dev CR-I30. For a whitelisted token the backing term in `_checkBacking` never binds, because what the index
    ///      held plus what it asks back always covers the new backing; VR-06 kept its `+ totalClaims` for the same
    ///      reason, as a net against a component that can take balance back from a holder, and nothing pinned either.
    ///      Here the bought component's issuer claws one raw unit out of the index during the auction, and an honest
    ///      fill that delivers exactly `amountsIn` has to be refused: settling would leave the index a unit short of
    ///      its own backing. Asking only for what the index held plus `amountsIn` would have let it through.
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

    /// @dev CR-I30 and VR-06: the `+ totalClaims` in the backing term, which VR-06 kept as a safety net and could not
    ///      pin. With a claim open on the bought component, a clawed unit there is caught only if the claim is counted:
    ///      without it the backing term falls below what the index held plus `amountsIn`, which is exactly the clawed
    ///      balance the index would be left with.
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
    ///      Nothing inside Xindex can lower a sold leg's balance while the executor holds control, but a component whose
    ///      issuer can claw a balance back can; checking only the legs that received something would let the index
    ///      settle a unit short.
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

    /// @dev CR-I33. Only the unbounded settlement was ever called on an uninitialized instance. The bounded overload is
    ///      a separate entry point with its own guard; without it the call still reverts, but with NoPendingRebalance,
    ///      as though an instance with no components could have a rebalance pending.
    function test_CRI33_theBoundedSettlementRefusesAnUninitializedInstance() public {
        IndexHub impl = IndexHub(factory.IMPLEMENTATION());
        IndexHub rogue = IndexHub(Clones.clone(address(impl)));
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        executor.executeBounded(rogue, "", new uint256[](0));
        vm.expectRevert(IIndexHub.NotInitialized.selector);
        executor.executeBounded(impl, "", new uint256[](0));
    }

    /// @dev A second index over the fixture's tokens whose pausable component carries one raw unit a share, so any
    ///      redemption of less than a whole share owes nothing of it.
    function _dustIndex() internal returns (IndexHub idx) {
        uint256[] memory units = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            units[i] = i == 1 ? 1 : 100e18;
        }
        vm.prank(alice);
        idx = IndexHub(factory.createIndex("Dust", "DUST", tokens, units, 0));
        _issue(idx, alice, 3e18);
    }

    /// @dev CR-I33. `_redeem` skips a component it owes nothing of, both when it pays out and when it books claims.
    ///      Without the first skip, a frozen component would be sent a transfer of zero, which a paused token refuses as
    ///      it refuses any other, and a redemption owing nothing of it could not exit; without the second,
    ///      `redeemSkipping` would record a claim of nothing.
    function test_CRI33_aRedemptionOwingNothingOfAFrozenComponentNeverTouchesIt() public {
        IndexHub idx = _dustIndex();
        pausable.setPaused(true);
        assertEq(idx.previewRedeem(0.5e18)[1], 0, "half a share owes nothing of the one-raw-unit component");
        vm.prank(alice);
        idx.redeem(0.5e18, alice);
        assertEq(idx.balanceOf(alice), 2.5e18, "a plain redeem still exits while that component is frozen");

        vm.recordLogs();
        vm.prank(alice);
        idx.redeemSkipping(0.5e18, alice, 1 << 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IIndexHub.ClaimRecorded.selector, "no claim of nothing is recorded");
        }
        assertEq(idx.claimOf(alice, address(pausable)), 0);
    }

    /// @dev CR-I33, at the MIN_TURNOVER threshold itself. DA-22's test moved below the threshold and well above it,
    ///      never onto it, so a gate that refused a turnover exactly equal to MIN_TURNOVER passed. The rule's answer is
    ///      fixed with a mocked call so the turnover lands one wei under the threshold and then on it. Since RT-04 a
    ///      step under the threshold still starts when the basket's distance from its rule clears it, so that distance
    ///      is fixed under the threshold too, which leaves this test on the traded turnover's own boundary.
    function test_DA22_CRI33_aTurnoverExactlyAtTheThresholdStarts() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (uint256[] memory targets,) = index.previewTarget(0);
        address rule = factory.RULE();
        bytes memory snapshot = abi.encodeWithSelector(IIndexRule.targetUnits.selector);
        uint256 threshold = index.MIN_TURNOVER();
        vm.mockCall(rule, abi.encodeWithSelector(IIndexRule.shortfall.selector), abi.encode(threshold - 1));

        vm.mockCall(rule, snapshot, abi.encode(targets, threshold - 1));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexHub.TurnoverTooLow.selector, threshold - 1));
        index.startRebalance(0);

        vm.mockCall(rule, snapshot, abi.encode(targets, threshold));
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        assertGt(eta, 0, "a turnover exactly at MIN_TURNOVER clears the gate");
        vm.clearMockedCalls();
    }

    /// @dev CR-I33. `canStartRebalance` was checked well before the interval ends and exactly when it does, never a
    ///      second before, where `startRebalance` still reverts RebalanceTooSoon and the view has to say so.
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

    /// @dev CR-I33. `currentMultiplier` answers 0 at every moment outside the auction, the last second of the notice
    ///      included, where `previewRebalance` reverts RebalanceNotReady; an app polling the view must not see a revert.
    function test_CRI33_theMultiplierIsZeroTheSecondBeforeTheAuction() public {
        uint256 eta = _start(index);
        vm.warp(eta - 1);
        assertEq(index.currentMultiplier(), 0, "no auction yet");
        vm.warp(eta);
        assertEq(index.currentMultiplier(), index.AUCTION_START_MULTIPLIER());
    }

    /// @dev CR-I03. A growing component's extra units are multiplied and rounded up, so settled units lie within half to
    ///      2.5 times the holding plus one raw unit of rounding, not within 2.5 times exactly: a component held at a
    ///      single raw unit, targeted at two and filled at the 1.5 opening multiplier, settles at three. The executor
    ///      delivers that extra unit, so no holder pays for it. Documented rather than fixed.
    function test_CRI03_aSingleRawUnitCanSettleAtThreeTimesItself() public {
        // Ten million whole tokens at ten thousand dollars: a market cap that dwarfs the other component's, so the rule
        // wants the coarse component far above the one raw unit an index token holds, and clips it at double.
        MockERC20 coarse = new MockERC20("Coarse", "CRS", 6);
        IIndexFactory.TokenConfig memory config = market.configWith(address(coarse), 10_000e8, 10_000_000e6);
        vm.prank(owner);
        factory.proposeListing(address(coarse), config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(coarse));

        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        (t[0], t[1], u[0], u[1]) = (address(coarse), tokens[2], 1, 1e16); // a cent of each per index token
        IndexHub idx = IndexHub(factory.createIndex("Coarse", "CRS", t, u, 0));
        uint256[] memory need = idx.previewIssue(1e24);
        for (uint256 i = 0; i < 2; ++i) {
            MockERC20(t[i]).mint(alice, need[i]);
            vm.prank(alice);
            MockERC20(t[i]).approve(address(idx), need[i]);
        }
        vm.prank(alice);
        idx.issue(1e24, alice);

        vm.warp(_start(idx)); // the opening multiplier, 1.5
        (,, uint256[] memory targets) = idx.pendingRebalance();
        assertEq(targets[0], 2, "the target doubles, the most one rebalance allows");
        executor.execute(idx, "");
        assertEq(_units(idx)[0], 3, "one raw unit plus the growth of one times 1.5, rounded up: three times itself");
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

    /// @dev Holds one leg of a settlement to the change in its required backing, the floor of the new backing less the
    ///      floor of the old, and says whether the floor of the change in units comes out differently, which is when
    ///      holding it there shows anything.
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
    ///      less the floor of the old, not the floor of the change in units, which can be a raw unit lower. Every other
    ///      rebalance test uses supplies and units whose products have no remainder, where the two agree, so either
    ///      side could have been rounded the other way unnoticed. A growing leg asking a unit less is paid out of the
    ///      holders' rounding surplus, or reverts an honest fill on an index backed exactly; a shrinking leg sending a
    ///      unit less leaves it behind. Here the units, the supply and the multiplier all leave remainders, the amounts
    ///      are held to the floors of the backing, and each leg's surplus is compared across an honest fill.
    function test_RT12_aFillMovesExactlyTheChangeInBackingWhenTheProductsHaveRemainders() public {
        uint256[] memory odd = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            odd[i] = 100e18 + 1_234_567_891 * (i + 1);
        }
        vm.prank(stranger);
        IndexHub idx = IndexHub(factory.createIndex("Odd", "ODD", tokens, odd, 0));
        _issue(idx, alice, 3_333_333_333_333_333_350);
        uint256 supply = idx.totalSupply();
        uint256[] memory surplus = _surpluses(idx);

        vm.warp(_start(idx) + 7 hours + 13 minutes); // a multiplier with a remainder
        (, uint256[] memory next, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        bool[2] memory shows; // whether the rounding shows on a shrinking leg, and on a growing one
        for (uint256 i = 0; i < 5; ++i) {
            if (_assertLegIsTheChangeInBacking(supply, odd[i], next[i], amountsOut[i], amountsIn[i])) {
                shows[next[i] < odd[i] ? 0 : 1] = true;
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

    /// @dev RT-15. `RebalanceStarted` carries the keep mask, the one on-chain record of which components a start routes
    ///      around until `pendingRebalance` is read. Its only full check was a stranger's start with a mask of zero, so
    ///      an event that always reported zero passed. Here the guardian keeps the second component.
    function test_RT15_aGuardianStartReportsItsKeepMask() public {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        (uint256[] memory targets,) = index.previewTarget(1 << 1);
        assertEq(targets[1], 100e18, "the kept component keeps its units");
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexHub.RebalanceStarted(1, 1, guardian, targets, 1 << 1, block.timestamp + index.REBALANCE_DELAY());
        vm.prank(guardian);
        index.startRebalance(1 << 1);
    }
}
