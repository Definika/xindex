// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";

/// @notice Rebalance lifecycle of an index: snapshot, notice, auction, settlement, cancellation.
/// @dev The basket holds five tokens worth one WETH each, 100 units apiece, while the rule wants the first at 60% and
///      the others at 10%. The first target is clipped at 200 units and the others land at 75, for 20% turnover. The
///      second component can be paused.
contract IndexTokenRebalanceTest is Test {
    MockMarket market;
    IndexFactory factory;
    IndexToken index;
    MockRebalanceExecutor executor;
    MockPausableToken pausable;
    address[] tokens;
    uint256[] startUnits;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address stranger = makeAddr("stranger");

    uint256 constant WAD = 1e18;
    uint256 constant SHARES = 10e18;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(
            owner, guardian, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
        executor = new MockRebalanceExecutor();

        pausable = new MockPausableToken("Pausable", "PAUSE", 18);
        uint256[5] memory parts = [uint256(6), 1, 1, 1, 1];
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens.push(i == 1 ? address(pausable) : address(new MockERC20("C", "C", 18)));
            configs[i] = market.configWith(tokens[i], 0, parts[i] * 1e24, new address[](0));
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

        index = IndexToken(factory.createIndex("Rebalanced", "RBL", tokens, startUnits, 0));
        _issue(index, alice, SHARES);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _issue(IndexToken idx, address who, uint256 shares) internal {
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
    function _start(IndexToken idx) internal returns (uint256 eta) {
        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        idx.startRebalance(0);
        (eta,,) = idx.pendingRebalance();
    }

    function _units(IndexToken idx) internal view returns (uint256[] memory units) {
        (, units) = idx.components();
    }

    function _assertBacked(IndexToken idx) internal view {
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
        (uint256 eta, uint256 keepMask, uint256[] memory targets) = index.pendingRebalance();
        assertEq(eta, 0);
        assertEq(keepMask, 0);
        assertEq(targets.length, 0);
        assertEq(index.currentMultiplier(), 0);
        vm.expectRevert(IIndexToken.NoPendingRebalance.selector);
        index.previewRebalance();
    }

    function test_startRebalance_snapshotsTheRuleAfterTheInterval() public {
        uint256 earliest = index.lastRebalance() + index.MIN_REBALANCE_INTERVAL();
        vm.warp(earliest - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceTooSoon.selector, earliest));
        index.startRebalance(0);

        vm.warp(earliest);
        (uint256[] memory preview, uint256 turnover) = index.previewTarget(0);
        assertEq(turnover, 0.2e18);
        uint256 eta = block.timestamp + index.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.RebalanceStarted(1, 1, stranger, _expectedTargets(), 0, eta);
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
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalancePending.selector, deadline));
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
    ///      restart that kept the old targets, the stale snapshot XA-01 and XA-02 guard against, passed every test.
    function test_LR05_aRestartAfterAnUnfilledAuctionTakesAFreshSnapshot() public {
        uint256 eta = _start(index);
        (,, uint256[] memory first) = index.pendingRebalance();
        assertEq(keccak256(abi.encode(first)), keccak256(abi.encode(_expectedTargets())));

        // Nobody fills, and the first component's price falls by about a third before anyone restarts.
        vm.warp(eta + index.AUCTION_DURATION() + index.REBALANCE_DELAY());
        market.setPriceTick(tokens[0], -4_000);
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
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidKeepMask.selector, 1 << 5));
        index.startRebalance(1 << 5);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.InvalidKeepMask.selector, 31));
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
        IndexToken balanced = IndexToken(factory.createIndex("Balanced", "BAL", tokens, onTarget, 0));
        vm.warp(balanced.lastRebalance() + balanced.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.TurnoverTooLow.selector, 0));
        balanced.startRebalance(0);
    }

    // ---------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------

    function test_cancelRebalance_andTheRestartCooldown() public {
        vm.prank(guardian);
        vm.expectRevert(IIndexToken.NoPendingRebalance.selector);
        index.cancelRebalance();

        _start(index);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        index.cancelRebalance();

        uint256 restartAt = block.timestamp + index.REBALANCE_DELAY();
        vm.expectEmit(true, true, true, true, address(index));
        emit IIndexToken.RebalanceCancelled(1, guardian, restartAt);
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

    function test_uninitializedClonesCannotRebalance() public {
        IndexToken rogue = IndexToken(Clones.clone(factory.IMPLEMENTATION()));
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.startRebalance(0);
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        rogue.cancelRebalance();
        vm.expectRevert(IIndexToken.NotInitialized.selector);
        executor.execute(rogue, "");
    }

    // ---------------------------------------------------------------------
    // execute
    // ---------------------------------------------------------------------

    function test_executeRebalance_windowChecks() public {
        vm.expectRevert(IIndexToken.NoPendingRebalance.selector);
        executor.execute(index, "");

        uint256 eta = _start(index);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceNotReady.selector, eta));
        executor.execute(index, "");
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceNotReady.selector, eta));
        index.previewRebalance();

        uint256 deadline = eta + index.AUCTION_DURATION();
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceExpired.selector, deadline));
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
        emit IIndexToken.Rebalanced(1, 1, address(executor), 1.5e18, units, amountsOut, amountsIn);
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

        vm.expectRevert(IIndexToken.NoPendingRebalance.selector);
        executor.execute(index, "");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexToken.RebalanceTooSoon.selector, block.timestamp + 28 days));
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
        IndexToken idx = IndexToken(factory.createIndex("Odd", "ODD", tokens, odd, 0));
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
        IndexToken empty = IndexToken(factory.createIndex("Empty", "EMPTY", tokens, startUnits, 0));
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
            abi.encodeWithSelector(IIndexToken.RebalanceUnderfunded.selector, tokens[0], 2_500e18 - 1, 2_500e18)
        );
        executor.execute(index, "");

        executor.setMode(MockRebalanceExecutor.Mode.Noop);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexToken.RebalanceUnderfunded.selector, tokens[0], 1_000e18, 2_500e18)
        );
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
        assertEq(errors.length, 7);
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
}
