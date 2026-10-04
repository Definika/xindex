// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {HybridTest} from "./HybridTest.sol";
import {MockPausableToken} from "./mocks/MockPausableToken.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HubSharesHarness} from "./mocks/HubSharesHarness.sol";

/// @notice The rebalance of an index holding vault tokens: Stage A's start and band, then a fill in three steps
///         (accept with a bond and the Ethereum deliveries, vault deliveries, settle on their proofs), the bond held
///         and released or slashed, failures and cancels, and orders that live across a fill.
contract HybridHubRebalanceTest is HybridTest {
    IHybridIndex hub;
    address executor = makeAddr("executor");
    bytes32 execRecipient = bytes32(uint256(uint160(makeAddr("executor on the vault chain"))));

    function setUp() public {
        _deployStageB();
        hub = _createHybrid();
        _mint(hub, minter, 100e18); // the seed
        vm.prank(minter);
        hub.transfer(executor, 1e18); // enough for a 0.1% bond
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev Moves one token's reference supply by half a percent, up, in a supply batch.
    function _revise(address token, uint256 supply) internal {
        address[] memory tokens = new address[](1);
        uint256[] memory supplies = new uint256[](1);
        (tokens[0], supplies[0]) = (token, supply + supply / 200);
        vm.prank(owner);
        factory.proposeSupplies(tokens, supplies);
        vm.warp(block.timestamp + 2 days);
        factory.executeSupplies();
    }

    /// @dev A band live halfway through its auction: native's supply up, so native is bought and WETH sold.
    function _liveAuction(bool buyNative) internal {
        if (buyNative) _revise(native, BNB_SUPPLY);
        else _revise(address(weth), ETH_SUPPLY);
        vm.warp(block.timestamp + 7 days);
        hub.startRebalance(0);
        vm.warp(block.timestamp + hub.REBALANCE_DELAY() + 12 hours);
    }

    function _accept() internal returns (uint256[] memory deliveries) {
        (,,, uint256[] memory amountsIn) = hub.previewRebalance();
        weth.mint(executor, amountsIn[0]);
        vm.startPrank(executor);
        weth.approve(address(hub), amountsIn[0]);
        bytes32[] memory r = new bytes32[](1);
        r[0] = execRecipient;
        hub.acceptRebalance(r, new uint256[](0));
        vm.stopPrank();
        (, deliveries,) = hub.fillAmounts();
    }

    function _deliver(uint256 amount) internal {
        uint256 intakeId = hub.fillIntakeId();
        vm.deal(executor, executor.balance + amount);
        _fresh();
        vm.prank(executor);
        vault.deposit{value: amount}(address(hub), intakeId);
    }

    function _proofOf(uint256 total) internal view returns (IHybridHubTypes.ChainProof[] memory p) {
        p = _chainProof(block.timestamp, total);
    }

    function _checkBacking() internal view {
        (, uint256[] memory units,,) = hub.components();
        uint256 supply = hub.totalSupply();
        assertGe(
            weth.balanceOf(address(hub)),
            supply * units[0] / 1e18 + hub.totalClaims(address(weth)) + hub.escrowed(address(weth)),
            "Ethereum backing"
        );
        assertGe(hub.vaultBacking(native), supply * units[1] / 1e18 + hub.totalClaims(native), "vault backing");
    }

    // ---------------------------------------------------------------------
    // the fill
    // ---------------------------------------------------------------------

    /// @dev A vault leg bought: the executor delivers on the vault chain, is booked the sold WETH as its claim on
    ///      Ethereum once the delivery is proven, and gets its bond back after the hold.
    function test_fill_buysAVaultLeg() public {
        _liveAuction(true);
        (, uint256[] memory unitsBefore,,) = hub.components();
        uint256 supplyBefore = hub.totalSupply();
        uint256[] memory deliveries = _accept();
        assertEq(deliveries[0], 0, "WETH is sold, not bought");
        assertGt(deliveries[1], 0, "native is bought");
        IHybridHubTypes.Fill memory f = hub.fill();
        assertEq(uint256(f.status), uint256(IHybridHubTypes.FillStatus.Accepted));
        assertEq(f.bond, 0.1e18, "0.1% of the supply");
        assertEq(hub.balanceOf(address(hub)), 0.1e18, "the bond is held as the index's own shares");
        assertEq(hub.totalSupply(), supplyBefore, "holding a bond mints nothing");

        _deliver(deliveries[1]);
        uint256 intakeId = hub.fillIntakeId();
        assertFalse(hub.intakeSettled(intakeId));
        vm.recordLogs();
        hub.settleRebalance(_proofOf(deliveries[1]));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _deliverAll(logs);
        assertTrue(hub.intakeSettled(intakeId), "marked with its settle message, for a snapshot exit");

        (, uint256[] memory unitsAfter,,) = hub.components();
        assertLt(unitsAfter[0], unitsBefore[0]);
        assertGt(unitsAfter[1], unitsBefore[1]);
        assertGt(hub.claimOf(executor, address(weth)), 0, "the sold WETH, booked as the executor's claim");
        assertEq(hub.vaultBacking(native), 140e18 + deliveries[1]);
        assertEq(vault.balance(address(hub), address(0)), hub.vaultBacking(native), "the vault agrees with the book");
        assertEq(hub.rebalanceNonce(), 1);
        assertEq(hub.lastRebalance(), block.timestamp);
        _checkBacking();

        f = hub.fill();
        assertEq(uint256(f.status), uint256(IHybridHubTypes.FillStatus.Settled));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotYet.selector, block.timestamp + 24 hours));
        hub.releaseBond();
        vm.warp(block.timestamp + 24 hours);
        hub.releaseBond();
        assertEq(hub.balanceOf(executor), 1e18, "the bond is back");
        assertEq(hub.balanceOf(address(hub)), 0);
        assertEq(uint256(hub.fill().status), uint256(IHybridHubTypes.FillStatus.None));
        assertEq(hub.fillIntakeId(), 0);
    }

    /// @dev A vault leg sold: the executor delivers WETH at acceptance, and is paid on the vault chain by a burn.
    function test_fill_sellsAVaultLeg() public {
        _liveAuction(false);
        uint256[] memory deliveries = _accept();
        assertGt(deliveries[0], 0, "WETH is bought");
        assertEq(deliveries[1], 0);
        assertEq(hub.escrowed(address(weth)), deliveries[0], "held apart until settlement");
        vm.recordLogs();
        hub.settleRebalance(_oneEmpty()); // no vault leg is bought: nothing to prove
        _deliverAll(vm.getRecordedLogs());
        assertGt(address(uint160(uint256(execRecipient))).balance, 0, "paid on the vault chain");
        assertEq(hub.escrowed(address(weth)), 0);
        assertEq(vault.balance(address(hub), address(0)), hub.vaultBacking(native));
        _checkBacking();
    }

    function _oneEmpty() internal pure returns (IHybridHubTypes.ChainProof[] memory p) {
        p = new IHybridHubTypes.ChainProof[](1);
    }

    /// @dev Settlement is sized at the supply of the settling block: redemptions during the window shrink it, and the
    ///      delivery's excess stays with the holders.
    function test_fill_settlesAtTheSettlingSupply() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        vm.prank(minter);
        hub.redeem(50e18, minter, new bytes32[](1), 0); // half the supply leaves, its vault part as a claim
        hub.settleRebalance(_proofOf(deliveries[1]));
        assertEq(hub.vaultBacking(native), 140e18 + deliveries[1], "the whole delivery joins");
        _checkBacking();
    }

    // ---------------------------------------------------------------------
    // refusals
    // ---------------------------------------------------------------------

    function test_start_refusals() public {
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.RebalanceTooSoon.selector, hub.lastRebalance() + 7 days));
        hub.startRebalance(0);
        vm.warp(block.timestamp + 7 days);
        (, uint256 lo, uint256 hi) = hub.previewBand(0);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.BandTooNarrow.selector, lo, hi));
        hub.startRebalance(0); // nothing changed
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.InvalidKeepMask.selector, 3));
        hub.startRebalance(3);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(this)));
        hub.startRebalance(1);
        assertTrue(hub.canStartRebalance());
        _revise(native, BNB_SUPPLY);
        hub.startRebalance(0);
        assertFalse(hub.canStartRebalance(), "an auction is pending");
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.RebalancePending.selector, block.timestamp + 2 days + 24 hours)
        );
        hub.startRebalance(0);
        (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios) =
            hub.pendingRebalance();
        assertEq(eta, block.timestamp + 2 days);
        assertEq(keepMask, 0);
        assertLt(lambdaMin, lambdaMax);
        assertEq(ratios.length, 2);
        assertEq(hub.proposalCount(), 1);
    }

    function test_accept_refusals() public {
        bytes32[] memory r = new bytes32[](1);
        r[0] = execRecipient;
        vm.startPrank(executor);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.acceptRebalance(new bytes32[](0), new uint256[](0));
        vm.expectRevert(IHybridHubTypes.NoPendingRebalance.selector);
        hub.acceptRebalance(r, new uint256[](0));
        vm.stopPrank();

        _revise(native, BNB_SUPPLY);
        vm.warp(block.timestamp + 7 days);
        hub.startRebalance(0);
        uint256 eta = block.timestamp + 2 days;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.RebalanceNotReady.selector, eta));
        vm.prank(executor);
        hub.acceptRebalance(r, new uint256[](0));
        vm.warp(eta + 12 hours);

        (,,, uint256[] memory amountsIn) = hub.previewRebalance();
        uint256[] memory tight = new uint256[](2);
        tight[1] = amountsIn[1] - 1;
        vm.startPrank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.RebalanceMovedOn.selector, native, amountsIn[1], amountsIn[1] - 1)
        );
        hub.acceptRebalance(r, tight);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.acceptRebalance(r, new uint256[](1));
        vm.stopPrank();

        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, 0.1e18));
        hub.acceptRebalance(r, new uint256[](0));

        vm.prank(guardian);
        factory.freezeChain(chainId);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.ChainIsFrozen.selector, chainId, block.timestamp + 14 days)
        );
        hub.acceptRebalance(r, new uint256[](0));

        vm.warp(eta + 24 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.RebalanceExpired.selector, eta + 24 hours));
        vm.prank(executor);
        hub.acceptRebalance(r, new uint256[](0));
    }

    function test_accept_onlyOnce() public {
        _liveAuction(true);
        _accept();
        assertFalse(hub.canStartRebalance(), "a fill is in progress");
        bytes32[] memory r = new bytes32[](1);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.Accepted)
        );
        hub.acceptRebalance(r, new uint256[](0));
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.RebalancePending.selector, hub.fill().deadline + 6 hours)
        );
        hub.startRebalance(0);
    }

    function test_settle_refusals() public {
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.None)
        );
        hub.settleRebalance(_oneEmpty());
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1] - 1);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        hub.settleRebalance(new IHybridHubTypes.ChainProof[](0));
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.DeliveryShort.selector, native, deliveries[1] - 1, deliveries[1])
        );
        hub.settleRebalance(_proofOf(deliveries[1] - 1));
        // A preimage claiming the full delivery does not hash to the vault's digest (C1-06: the very error, no other).
        vm.expectPartialRevert(IHybridHubTypes.DigestMismatch.selector);
        hub.settleRebalance(_proofOf(deliveries[1]));
    }

    // ---------------------------------------------------------------------
    // failure, cancel, slash
    // ---------------------------------------------------------------------

    /// @dev An executor abandoning its fill loses its bond, which raises every remaining share's backing; its
    ///      deliveries come back.
    function test_fail_byTheExecutorBurnsTheBond() public {
        _liveAuction(false); // WETH bought: an Ethereum delivery to return
        uint256[] memory deliveries = _accept();
        uint256 supply = hub.totalSupply();
        vm.recordLogs();
        vm.prank(executor);
        hub.failRebalance();
        _deliverAll(vm.getRecordedLogs());
        assertEq(hub.totalSupply(), supply - 0.1e18, "the bond is burned");
        assertEq(hub.claimOf(executor, address(weth)), deliveries[0]);
        assertEq(hub.escrowed(address(weth)), 0);
        assertEq(uint256(hub.fill().status), uint256(IHybridHubTypes.FillStatus.None));
        assertEq(hub.restartAllowedAt(), block.timestamp + 2 days);
        _checkBacking();
    }

    function test_fail_byAnyoneAfterTheGrace() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        uint256 intakeId = hub.fillIntakeId();
        uint256 openTo = hub.fill().deadline + 6 hours;
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotYet.selector, openTo));
        hub.failRebalance();
        vm.warp(openTo + 1);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.IntakeOfARebalance.selector, intakeId));
        hub.failIntake(chainId, intakeId);
        vm.recordLogs();
        hub.failRebalance();
        _deliverAll(vm.getRecordedLogs());
        vm.prank(executor);
        vault.refund(address(hub), intakeId);
        assertEq(executor.balance, deliveries[1], "the delivery comes back on the vault chain");
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.None)
        );
        hub.failRebalance();
    }

    /// @dev The guardian can cancel an accepted fill; the executor did nothing wrong, so its bond comes back.
    function test_cancel_anAcceptedFillReturnsTheBond() public {
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(this)));
        hub.cancelRebalance();
        vm.prank(guardian);
        vm.expectRevert(IHybridHubTypes.NoPendingRebalance.selector);
        hub.cancelRebalance();
        _liveAuction(true);
        _accept();
        vm.prank(guardian);
        hub.cancelRebalance();
        assertEq(hub.balanceOf(executor), 1e18);
        assertEq(hub.restartAllowedAt(), block.timestamp + 2 days);

        // A proposal not yet taken is cancelled as in Stage A; one whose auction expired holds strangers off from it.
        vm.warp(block.timestamp + 2 days);
        hub.startRebalance(0);
        vm.prank(owner);
        hub.cancelRebalance();
        vm.warp(block.timestamp + 2 days);
        hub.startRebalance(0);
        uint256 eta = block.timestamp + 2 days;
        vm.warp(eta + 1 days + 1);
        vm.prank(guardian);
        hub.cancelRebalance();
        assertEq(hub.restartAllowedAt(), eta + 1 days + 2 days);
    }

    /// @dev During the bond's hold, a proof that a delivery intake is not what the settlement recorded burns the bond
    ///      and freezes the chain's mints.
    function test_slash_aForgedDelivery() public {
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.None)
        );
        hub.slashRebalance(chainId, 2, _oneEmpty()[0]);
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        vm.recordLogs();
        hub.settleRebalance(_proofOf(deliveries[1]));
        _deliverAll(vm.getRecordedLogs());
        uint256 intakeId = hub.fillIntakeId();
        vm.warp(hub.fill().deadline + 1);

        // The honest state now: settled, with the whole delivery.
        IHybridHubTypes.ChainProof memory honest = _proofOf(deliveries[1])[0];
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        hub.slashRebalance(chainId, 2, honest);
        // An open intake's preimage does not hash to the settled digest (C1-06: the very error, no other).
        vm.expectPartialRevert(IHybridHubTypes.DigestMismatch.selector);
        hub.slashRebalance(chainId, 1, honest);

        // A forged state: the same intake, settled, a wei short.
        IHybridHubTypes.ChainProof memory short = _proofOf(deliveries[1] - 1)[0];
        short.proof = _forged(block.timestamp, _digestOf(intakeId, 2, deliveries[1] - 1));
        uint256 supply = hub.totalSupply();
        hub.slashRebalance(chainId, 2, short);
        assertEq(hub.totalSupply(), supply - 0.1e18, "the bond is burned");
        (, uint256 until) = hub.chainFreeze(chainId);
        assertEq(until, block.timestamp + 14 days);
        assertEq(uint256(hub.fill().status), uint256(IHybridHubTypes.FillStatus.None));
    }

    function test_slash_anIntakeTheVaultNeverHadOrFailed() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));
        uint256 intakeId = hub.fillIntakeId();
        vm.warp(hub.fill().deadline + 1);
        IHybridHubTypes.ChainProof memory failed = _proofOf(deliveries[1])[0];
        failed.proof = _forged(block.timestamp, _digestOf(intakeId, 3, deliveries[1]));
        uint256 snap = vm.snapshotState();
        hub.slashRebalance(chainId, 3, failed);
        vm.revertToState(snap);
        IHybridHubTypes.ChainProof memory never = _proofOf(0)[0];
        never.proof = _forged(block.timestamp, bytes32(0));
        hub.slashRebalance(chainId, 0, never);
        vm.warp(block.timestamp + 24 hours);
        never.proof = _forged(block.timestamp, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.None)
        );
        hub.slashRebalance(chainId, 0, never);
    }

    /// @dev LG-5: a vault in its snapshot exit fails a delivery intake the hub never marked settled, honestly: no
    ///      evidence, so no bond burns and nothing freezes. The vault's snapshot root is set directly here, in the slot
    ///      the evidence proof reads, as a vault that began its exit holds it.
    function test_LG5_noSlashOnAVaultInItsExit() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));
        uint256 intakeId = hub.fillIntakeId();
        vm.warp(hub.fill().deadline + 1);
        vm.store(address(vault), bytes32(uint256(25)), keccak256("the snapshot's state root"));
        assertEq(vault.snapshot().stateRoot, keccak256("the snapshot's state root"));
        IHybridHubTypes.ChainProof memory failed = _proofOf(deliveries[1])[0];
        failed.proof = _forged(block.timestamp, _digestOf(intakeId, 3, deliveries[1]));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ChainExited.selector, chainId));
        hub.slashRebalance(chainId, 3, failed);
        assertEq(uint256(hub.fill().status), uint256(IHybridHubTypes.FillStatus.Settled), "the bond is still held");
        assertEq(factory.chainFreeze(chainId).start, 0);
    }

    /// @dev Once the hold is over, a slash is refused with an error that says so, never the one that means too early
    ///      (A2-10).
    function test_A210_slash_notAfterTheHold() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));
        uint256 release = hub.fill().bondRelease;
        vm.warp(release);
        IHybridHubTypes.ChainProof memory never = _proofOf(0)[0];
        never.proof = _forged(block.timestamp, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.HoldOver.selector, release));
        hub.slashRebalance(chainId, 0, never);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 9));
        vm.warp(release - 1);
        hub.slashRebalance(9, 0, never);
    }

    /// @dev HUB-1, MOD-1 and BNB-1: a chain the fill bought nothing on honestly shows no intake until its settle message lands. An honest
    ///      proof of that is no evidence: it burns no bond and freezes nothing.
    function test_HUB1_MOD1_BNB1_anHonestEmptyIntakeIsNoEvidence() public {
        _liveAuction(false); // WETH bought, the vault's coin sold
        _accept();
        hub.settleRebalance(_oneEmpty());
        vm.warp(hub.fill().deadline + 1);
        IHybridHubTypes.ChainProof memory p = _oneEmpty()[0];
        p.proof = _honest(block.timestamp);
        uint256 supply = hub.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        hub.slashRebalance(chainId, 0, p);
        assertEq(hub.totalSupply(), supply, "the bond stands");
        (, uint256 until) = hub.chainFreeze(chainId);
        assertEq(until, 0, "no freeze");
    }

    /// @dev HUB-1, MOD-1 and BNB-1: state verifiers prove old final blocks, and a state from before the deliveries is honestly short, so
    ///      evidence must come from after the delivery deadline.
    function test_HUB1_MOD1_BNB1_aProofFromBeforeTheDeadlineIsNoEvidence() public {
        _liveAuction(true);
        uint256 accepted = block.timestamp;
        uint256[] memory deliveries = _accept();
        vm.warp(block.timestamp + 1 hours);
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));
        uint256 deadline = hub.fill().deadline;
        vm.warp(deadline + 1);
        IHybridHubTypes.ChainProof memory stale = _proofOf(0)[0];
        stale.proof = _forged(accepted, bytes32(0)); // the slot as it truly was at acceptance
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ProofTooEarly.selector, chainId, accepted, deadline));
        hub.slashRebalance(chainId, 0, stale);
        stale.proof = _forged(deadline, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.ProofTooEarly.selector, chainId, deadline, deadline));
        hub.slashRebalance(chainId, 0, stale);
    }

    function _digestOf(uint256 intakeId, uint8 state, uint256 total) internal view returns (bytes32) {
        address[] memory tokens = new address[](1);
        uint256[] memory totals = new uint256[](1);
        totals[0] = total;
        return keccak256(
            abi.encode(
                keccak256("xindex.v4.vault.intake-digest"),
                chainId,
                address(vault),
                address(hub),
                intakeId,
                state,
                tokens,
                totals
            )
        );
    }

    // ---------------------------------------------------------------------
    // orders across a fill, the bond after the next fill
    // ---------------------------------------------------------------------

    /// @dev Mint claims wait while a fill is accepted; after it settles, an order whose deposit no longer covers its
    ///      shares at the new units fails at its claim, and one with room to spare claims.
    function test_ordersAcrossAFill() public {
        vm.warp(block.timestamp + 25 hours); // the seed's mint window is over
        uint256 tight = _settledOrder(hub, minter, 1e18); // deposits exactly what 1e18 needs at today's units
        uint256[] memory amounts = hub.previewOrder(1e18);
        weth.mint(holder, amounts[0]);
        vm.startPrank(holder);
        weth.approve(address(hub), amounts[0]);
        (uint256 roomy, uint256 roomyIntake) = hub.openOrder(1e18, block.timestamp + 1 hours);
        vm.deal(holder, 2e18);
        _fresh();
        vault.deposit{value: 2e18}(address(hub), roomyIntake);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        hub.settleOrder(roomy, _chainProof(block.timestamp, 2e18));

        _revise(native, BNB_SUPPLY);
        vm.warp(block.timestamp + 7 days);
        hub.startRebalance(0);
        vm.warp(block.timestamp + 2 days + 12 hours);
        uint256[] memory deliveries = _accept();
        vm.expectRevert(IHybridHubTypes.RebalanceInProgress.selector);
        hub.claimOrder(tight);
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));

        vm.recordLogs();
        hub.claimOrder(tight);
        assertEq(_message(vm.getRecordedLogs()).kind, VaultMessages.INTAKE_FAILED);
        assertEq(uint256(hub.order(tight).status), uint256(IHybridHubTypes.OrderStatus.Failed));
        assertEq(hub.claimOf(minter, address(weth)), 1.2e18, "its escrow is the minter's claim");
        hub.claimOrder(roomy);
        assertEq(uint256(hub.order(roomy).status), uint256(IHybridHubTypes.OrderStatus.Claimed));
        _checkBacking();
    }

    /// @dev The next fill finds the last one's hold long over and returns its bond on the way.
    function test_theNextFillReleasesTheLastBond() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));
        _revise(address(weth), ETH_SUPPLY);
        vm.warp(block.timestamp + 7 days);
        hub.startRebalance(0);
        vm.warp(block.timestamp + 2 days + 12 hours);
        _accept();
        assertEq(hub.fill().nonce, 2);
        assertEq(hub.balanceOf(executor), 1e18 - hub.fill().bond, "the first bond came back");
    }

    /// @dev The module moves the index's own shares: what it does shows in the hub's balances, supply and events.
    function test_moduleSharesAreTheHubsShares() public {
        _liveAuction(true); // native bought: nothing to approve, so the bond's is the first transfer
        bytes32[] memory r = new bytes32[](1);
        r[0] = execRecipient;
        vm.expectEmit(address(hub));
        emit IERC20.Transfer(executor, address(hub), 0.1e18);
        vm.prank(executor);
        hub.acceptRebalance(r, new uint256[](0));
        assertEq(hub.balanceOf(executor), 0.9e18);
        assertEq(hub.balanceOf(address(hub)), 0.1e18);
        vm.expectEmit(address(hub));
        emit IERC20.Transfer(address(hub), address(0), 0.1e18);
        vm.prank(executor);
        hub.failRebalance();
        assertEq(hub.totalSupply(), 99.9e18);
    }

    function test_views() public {
        assertEq(hub.MIN_REBALANCE_INTERVAL(), 7 days);
        assertEq(hub.AUCTION_DURATION(), 24 hours);
        assertEq(hub.MAX_SUPPLY_STEP(), 0.005e18);
        assertEq(hub.MIN_BAND(), 0.001e18);
        assertEq(hub.REBALANCE_BOND(), 0.001e18);
        assertEq(hub.BOND_HOLD(), 24 hours);
        assertEq(hub.DELIVERY_WINDOW(), 6 hours);
        _liveAuction(true);
        (uint256 lambda, uint256[] memory units,,) = hub.previewRebalance();
        _accept();
        IHybridHubTypes.Fill memory f = hub.fill();
        assertEq(f.executor, executor);
        assertEq(f.lambda, lambda);
        assertEq(f.nonce, 1);
        (uint256[] memory fillUnits,,) = hub.fillAmounts();
        assertEq(fillUnits[1], units[1]);
        assertEq(hub.fillIntakeId() >> 192, f.deadline);
        assertEq(hub.fillIntakeId() & ((1 << 192) - 1), (1 << 191) | 1);
    }

    function test_theModuleAloneIsInert() public {
        assertFalse(IHybridIndex(address(module)).canStartRebalance());
        vm.expectRevert(IHybridHubTypes.NotInitialized.selector);
        IHybridIndex(address(module)).startRebalance(0);
        assertEq(module.FACTORY(), address(factory));
    }

    // ---------------------------------------------------------------------
    // edges
    // ---------------------------------------------------------------------

    function test_theLastHoldIsAlwaysOverByTheNextAuction() public view {
        assertGt(hub.MIN_REBALANCE_INTERVAL() + hub.REBALANCE_DELAY(), hub.BOND_HOLD());
    }

    function test_releaseBond_needsASettledFill() public {
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.None)
        );
        hub.releaseBond();
    }

    /// @dev A fill that would send nothing out, here on an index everyone left, is taken at λmax.
    function test_aFillSendingNothingIsTakenAtLambdaMax() public {
        vm.prank(minter);
        hub.redeem(99e18, minter, new bytes32[](1), 0);
        vm.prank(executor);
        hub.redeem(1e18, executor, new bytes32[](1), 0);
        assertEq(hub.totalSupply(), 0);
        _liveAuction(true);
        (,,, uint256 lambdaMax,) = hub.pendingRebalance();
        _accept();
        assertEq(hub.fill().lambda, lambdaMax);
        assertEq(hub.fill().bond, 0);
        hub.settleRebalance(_oneEmpty());
        assertEq(hub.rebalanceNonce(), 1);
    }

    /// @dev A2-02: an empty index whose creator's seed is locked takes no fill. There a fill posts no bond and owes no
    ///      delivery, so a stranger could take one for free and hold the seed's claim behind it, or move the units the
    ///      seed was priced at. Once the seed is claimed, the index is no longer empty and fills as any other.
    function test_A202_anEmptyIndexTakesNoFillWhileItsSeedIsLocked() public {
        vm.prank(minter);
        hub.redeem(99e18, minter, new bytes32[](1), 0);
        vm.prank(executor);
        hub.redeem(1e18, executor, new bytes32[](1), 0);
        _liveAuction(true);
        _settledOrder(hub, minter, 50e18);
        assertEq(hub.totalSupply(), 0);
        bytes32[] memory r = new bytes32[](1);
        r[0] = execRecipient;
        vm.prank(executor);
        vm.expectRevert(IHybridHubTypes.ZeroShares.selector);
        hub.acceptRebalance(r, new uint256[](0));
    }

    /// @dev A2-05 with A2-02: an index below one share whose creator's new seed is locked takes no fill either, since
    ///      its bond, a thousandth of the dust, is as good as none.
    function test_A205_A202_aDustIndexTakesNoFillWhileItsSeedIsLocked() public {
        vm.prank(minter);
        hub.redeem(99e18, minter, new bytes32[](1), 0);
        vm.prank(executor);
        hub.redeem(1e18 - 1, executor, new bytes32[](1), 0);
        _liveAuction(true);
        _settledOrder(hub, minter, 50e18);
        assertEq(hub.totalSupply(), 1);
        bytes32[] memory r = new bytes32[](1);
        r[0] = execRecipient;
        vm.prank(executor);
        vm.expectRevert(IHybridHubTypes.ZeroShares.selector);
        hub.acceptRebalance(r, new uint256[](0));
    }

    /// @dev Three revisions of one supply open a band wider than the step (two leave the centred ratio at 1.004988,
    ///      inside it): it is clamped to [1 − STEP, 1 + STEP].
    function test_aWideBandIsClamped() public {
        for (uint256 k = 0; k < 3; ++k) {
            _revise(native, factory.referenceSupply(native));
            vm.warp(block.timestamp + 7 days);
        }
        hub.startRebalance(0);
        (,, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios) = hub.pendingRebalance();
        assertEq(lambdaMax, 1.005e18);
        assertEq(lambdaMin, 0.995e18);
        assertEq(ratios[0], 1.005e18);
        assertEq(ratios[1], 0.995e18);
    }

    /// @dev The owner or guardian can keep a component out of a rebalance: its units stay exactly as they were.
    function test_aKeptComponentKeepsItsUnits() public {
        MockERC20 link = new MockERC20("Chainlink", "LINK", 18);
        vm.prank(owner);
        factory.proposeListing(address(link), 1e27);
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(address(link));
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), native, address(link));
        vm.prank(minter);
        IHybridIndex three = IHybridIndex(factory.createIndex("Three", "THR", tokens, K));
        vault.registerIndex(address(three), factory.indexSalt(address(three)));
        uint256[] memory amounts = three.previewOrder(10e18);
        link.mint(minter, amounts[2]);
        vm.prank(minter);
        link.approve(address(three), amounts[2]);
        _mint(three, minter, 10e18);
        vm.prank(minter);
        three.transfer(executor, 1e18);

        _revise(native, BNB_SUPPLY);
        vm.warp(block.timestamp + 7 days);
        vm.prank(guardian);
        three.startRebalance(4); // keep LINK
        vm.warp(block.timestamp + 2 days + 12 hours);
        (, uint256[] memory before,,) = three.components();
        (, uint256[] memory units,, uint256[] memory amountsIn) = three.previewRebalance();
        assertEq(units[2], before[2], "LINK is kept");
        bytes32[] memory r = new bytes32[](1);
        vm.startPrank(executor);
        three.acceptRebalance(r, new uint256[](0));
        vm.deal(executor, amountsIn[1]);
        _fresh();
        vault.deposit{value: amountsIn[1]}(address(three), three.fillIntakeId());
        vm.stopPrank();
        three.settleRebalance(_proofOf(amountsIn[1]));
        (, uint256[] memory afterUnits,,) = three.components();
        assertEq(afterUnits[2], before[2]);
    }

    /// @dev MOD-4: a sold vault leg with no recipient becomes the executor's claim, as in `redeem`, rather than a burn no
    ///      vault could ever pay.
    function test_MOD4_aSoldVaultLegWithoutARecipientIsTheExecutorsClaim() public {
        _liveAuction(false); // the vault's coin sold
        (,, uint256[] memory amountsOut,) = hub.previewRebalance();
        (,,, uint256[] memory amountsIn) = hub.previewRebalance();
        weth.mint(executor, amountsIn[0]);
        vm.startPrank(executor);
        weth.approve(address(hub), amountsIn[0]);
        hub.acceptRebalance(new bytes32[](1), new uint256[](0));
        vm.stopPrank();
        vm.recordLogs();
        hub.settleRebalance(_oneEmpty());
        assertEq(hub.claimOf(executor, native), amountsOut[1]);
        assertEq(_message(vm.getRecordedLogs()).kind, VaultMessages.INTAKE_SETTLED, "no burn");
        _checkBacking();
    }

    /// @dev MOD-3: DA-14 and RT-01 on the hybrid hub: a kept component whose token no longer answers even a read does
    ///      not block the settlement, which reads only the legs that move.
    function test_MOD3_aKeptComponentThatNoLongerAnswersDoesNotBlockSettlement() public {
        MockPausableToken wbtc = new MockPausableToken("Wrapped BTC", "WBTC", 8);
        vm.prank(owner);
        factory.proposeListing(address(wbtc), 1e27);
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(address(wbtc));
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(weth), native, address(wbtc));
        vm.prank(minter);
        IHybridIndex three = IHybridIndex(factory.createIndex("Three", "THR", tokens, K));
        vault.registerIndex(address(three), factory.indexSalt(address(three)));
        uint256[] memory amounts = three.previewOrder(10e18);
        wbtc.mint(minter, amounts[2]);
        vm.prank(minter);
        wbtc.approve(address(three), amounts[2]);
        _mint(three, minter, 10e18);
        vm.prank(minter);
        three.transfer(executor, 1e18);

        _revise(native, BNB_SUPPLY);
        vm.warp(block.timestamp + 7 days);
        vm.prank(guardian);
        three.startRebalance(4); // keep WBTC
        wbtc.setReadsBroken(true);
        vm.warp(block.timestamp + 2 days + 12 hours);
        (,,, uint256[] memory amountsIn) = three.previewRebalance();
        bytes32[] memory r = new bytes32[](1);
        vm.startPrank(executor);
        three.acceptRebalance(r, new uint256[](0));
        vm.deal(executor, amountsIn[1]);
        _fresh();
        vault.deposit{value: amountsIn[1]}(address(three), three.fillIntakeId());
        vm.stopPrank();
        three.settleRebalance(_proofOf(amountsIn[1]));
        assertEq(three.rebalanceNonce(), 1);
    }

    /// @dev A2-01: a sold Ethereum leg is booked as the executor's claim, never sent at settlement, so a component
    ///      paused after acceptance cannot keep the fill from settling, which would cost its executor the bond. The
    ///      executor collects once transfers resume.
    function test_A201_aPausedSoldLegStillSettles() public {
        MockPausableToken wbtc = new MockPausableToken("Wrapped BTC", "WBTC", 8);
        IHybridIndex idx = _indexWith(address(wbtc), 1e27);
        _revise(native, BNB_SUPPLY); // native bought, WBTC sold
        vm.warp(block.timestamp + 7 days);
        idx.startRebalance(0);
        vm.warp(block.timestamp + 2 days + 12 hours);
        (,, uint256[] memory amountsOut, uint256[] memory amountsIn) = idx.previewRebalance();
        assertGt(amountsOut[0], 0, "WBTC is sold");
        vm.startPrank(executor);
        idx.acceptRebalance(new bytes32[](1), new uint256[](0));
        vm.deal(executor, amountsIn[1]);
        _fresh();
        vault.deposit{value: amountsIn[1]}(address(idx), idx.fillIntakeId());
        vm.stopPrank();
        uint256 held = wbtc.balanceOf(address(idx));

        wbtc.setPaused(true);
        idx.settleRebalance(_proofOf(amountsIn[1]));
        assertEq(uint256(idx.fill().status), uint256(IHybridHubTypes.FillStatus.Settled));
        assertEq(idx.claimOf(executor, address(wbtc)), amountsOut[0], "booked, not sent");
        assertEq(idx.totalClaims(address(wbtc)), amountsOut[0]);
        assertEq(wbtc.balanceOf(address(idx)), held, "nothing left the index");

        wbtc.setPaused(false);
        vm.prank(executor);
        idx.claim(address(wbtc), executor);
        assertEq(wbtc.balanceOf(executor), amountsOut[0]);
        assertEq(idx.totalClaims(address(wbtc)), 0);
    }

    /// @dev A2-11: new units past their type are refused when the fill is accepted, before anything is delivered, not
    ///      only at settlement, where every attempt would revert until anyone could fail the fill and burn the bond.
    function test_A211_unitsPastTheirTypeAreRefusedAtAcceptance() public {
        // Both components' units at the type's ceiling, in their ratio, as only about 690 full-band raises bring them.
        uint256 base = uint256(keccak256(abi.encode(uint256(0)))); // `_components`, slot 0
        uint256 nativeUnits = type(uint96).max;
        vm.store(address(hub), bytes32(base), bytes32(nativeUnits * 6 / 7 << 160 | uint160(address(weth))));
        vm.store(address(hub), bytes32(base + 1), bytes32(nativeUnits << 160 | uint160(native)));
        _liveAuction(true); // native bought: its units rise past the ceiling
        (, uint256[] memory units,,) = hub.previewRebalance();
        assertGt(units[1], type(uint96).max);
        bytes32[] memory r = new bytes32[](1);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, units[1]));
        vm.prank(executor);
        hub.acceptRebalance(r, new uint256[](0));
    }

    /// @dev A1b-02: the band and the settlement exist twice, in Stage A's IndexHub and in the hybrid module, with
    ///      nothing else tying them together. One index of three Ethereum tokens, an IndexHub clone, and one of the
    ///      same three and the vault's coin, a HybridHub, start from the same units and supply. For any supply batches
    ///      and keep mask, the coin always kept on the hybrid side, both give the same band and, at the same moment of
    ///      the auction, the same λ, and the same units and amounts on every Ethereum leg.
    function testFuzz_A1b02_bothHubsAgreeOnTheBandAndTheSettlement(int8[6] memory steps, uint8 keep, uint32 into)
        public
    {
        (IIndexHub stageA, IHybridIndex hybrid, address[] memory eth) = _twins();
        // Two weekly batches of the three supplies, each moving each by at most the step, in hundredths of a percent:
        // a spread of up to 2%, so the clamp binds as well.
        for (uint256 b = 0; b < 2; ++b) {
            uint256[] memory supplies = factory.referenceSupplies(eth);
            for (uint256 i = 0; i < 3; ++i) {
                int256 bps = int256(steps[3 * b + i]) % 51;
                supplies[i] = uint256(int256(supplies[i]) + int256(supplies[i]) * bps / 10_000);
            }
            _batch(eth, supplies);
            vm.warp(block.timestamp + 7 days);
        }

        uint256 mask = keep % 7; // never all three kept
        if (!_sameBand(stageA, hybrid, mask)) return; // too narrow for both
        vm.startPrank(guardian);
        stageA.startRebalance(mask);
        hybrid.startRebalance(mask | 8);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days + into % (24 hours + 1));
        _sameSettlement(stageA, hybrid);
    }

    /// @dev An IndexHub index of WETH and two more Ethereum tokens, and a HybridHub index of the same three and the
    ///      vault's coin, 10 shares of each, with the same units.
    function _twins() internal returns (IIndexHub stageA, IHybridIndex hybrid, address[] memory eth) {
        eth = new address[](3);
        eth[0] = address(weth);
        eth[1] = _listed("Token A", 1e27);
        eth[2] = _listed("Token B", 5e25);
        address[] memory withCoin = new address[](4);
        (withCoin[0], withCoin[1], withCoin[2], withCoin[3]) = (eth[0], eth[1], eth[2], native);
        vm.prank(minter);
        stageA = IIndexHub(factory.createIndex("Ethereum", "ETH3", eth, K));
        vm.prank(minter);
        hybrid = IHybridIndex(factory.createIndex("Hybrid", "HYB4", withCoin, K));
        vault.registerIndex(address(hybrid), factory.indexSalt(address(hybrid)));
        _issueBoth(stageA, hybrid, eth, 10e18);
        (, uint256[] memory unitsA) = stageA.components();
        (, uint256[] memory unitsB,,) = hybrid.components();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(unitsA[i], unitsB[i], "the same units");
        }
    }

    /// @dev Both hubs' bands for `mask`, the coin kept on the hybrid side, agree; true if they are wide enough to
    ///      start.
    function _sameBand(IIndexHub stageA, IHybridIndex hybrid, uint256 mask) internal view returns (bool) {
        (uint256[] memory ratiosA, uint256 minA, uint256 maxA) = stageA.previewBand(mask);
        (uint256[] memory ratiosB, uint256 minB, uint256 maxB) = hybrid.previewBand(mask | 8);
        assertEq(minA, minB, "lambda min");
        assertEq(maxA, maxB, "lambda max");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(ratiosA[i], ratiosB[i], "ratio");
        }
        return maxA * 1e18 >= minA * (1e18 + hub.MIN_BAND());
    }

    /// @dev Both hubs' settlements now agree on λ and on every Ethereum leg, and the hybrid keeps the coin's units.
    function _sameSettlement(IIndexHub stageA, IHybridIndex hybrid) internal view {
        (uint256 lambdaA, uint256[] memory unitsA, uint256[] memory outA, uint256[] memory inA) =
            stageA.previewRebalance();
        (uint256 lambdaB, uint256[] memory unitsB, uint256[] memory outB, uint256[] memory inB) =
            hybrid.previewRebalance();
        assertEq(lambdaA, lambdaB, "lambda");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(unitsA[i], unitsB[i], "units");
            assertEq(outA[i], outB[i], "out");
            assertEq(inA[i], inB[i], "in");
        }
        (, uint256[] memory before,,) = hybrid.components();
        assertEq(unitsB[3], before[3], "the coin is kept");
    }

    /// @dev A new MockERC20 listed at `supply`.
    function _listed(string memory name, uint256 supply) internal returns (address token) {
        token = address(new MockERC20(name, name, 18));
        vm.prank(owner);
        factory.proposeListing(token, supply);
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(token);
    }

    /// @dev `shares` of each index, the Stage A one issued and the hybrid one seeded by its creator.
    function _issueBoth(IIndexHub stageA, IHybridIndex hybrid, address[] memory eth, uint256 shares) internal {
        uint256[] memory amountsA = stageA.previewIssue(shares);
        uint256[] memory amountsB = hybrid.previewOrder(shares);
        vm.startPrank(minter);
        for (uint256 i = 0; i < 3; ++i) {
            MockERC20(eth[i]).mint(minter, amountsA[i] + amountsB[i]);
            MockERC20(eth[i]).approve(address(stageA), amountsA[i]);
            MockERC20(eth[i]).approve(address(hybrid), amountsB[i]);
        }
        stageA.issue(shares, minter);
        (uint256 orderId, uint256 intakeId) = hybrid.openOrder(shares, block.timestamp + 1 hours);
        vm.deal(minter, amountsB[3]);
        _fresh();
        vault.deposit{value: amountsB[3]}(address(hybrid), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours + 1);
        hybrid.settleOrder(orderId, _chainProof(block.timestamp, amountsB[3]));
        vm.warp(block.timestamp + hybrid.MINT_LOCK());
        hybrid.claimOrder(orderId);
        assertEq(IERC20(address(stageA)).totalSupply(), hybrid.totalSupply(), "the same supply");
    }

    /// @dev One supply batch of `tokens`, in ascending address order as the factory takes them.
    function _batch(address[] memory tokens, uint256[] memory supplies) internal {
        uint256 n = tokens.length;
        address[] memory sorted = new address[](n);
        uint256[] memory sortedSupplies = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 rank = 0;
            for (uint256 j = 0; j < n; ++j) {
                if (tokens[j] < tokens[i]) ++rank;
            }
            (sorted[rank], sortedSupplies[rank]) = (tokens[i], supplies[i]);
        }
        vm.prank(owner);
        factory.proposeSupplies(sorted, sortedSupplies);
        vm.warp(block.timestamp + 2 days);
        factory.executeSupplies();
    }

    /// @dev An Ethereum delivery must arrive whole: a component that starts taking a fee refuses the fill.
    function test_accept_refusesAFeeOnTheDelivery() public {
        (MockUSDT usdt, IHybridIndex idx) = _usdtIndex();
        _revise(address(usdt), 1e17); // USDT bought
        vm.warp(block.timestamp + 7 days);
        idx.startRebalance(0);
        vm.warp(block.timestamp + 2 days + 12 hours);
        (,,, uint256[] memory amountsIn) = idx.previewRebalance();
        usdt.mint(executor, amountsIn[0] * 2);
        usdt.setParams(10, 50e6); // Tether's fee, switched on
        vm.startPrank(executor);
        usdt.approve(address(idx), amountsIn[0] * 2);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.TransferAmountMismatch.selector, address(usdt)));
        idx.acceptRebalance(new bytes32[](1), new uint256[](0));
        vm.stopPrank();
    }

    /// @dev Settlement checks the backing it leaves: an issuer that destroys the index's balance of a component in the
    ///      window stops it.
    function test_settle_refusesWhatTheBackingNoLongerHolds() public {
        (MockUSDT usdt, IHybridIndex idx) = _usdtIndex();
        _revise(address(usdt), 1e17);
        vm.warp(block.timestamp + 7 days);
        idx.startRebalance(0);
        vm.warp(block.timestamp + 2 days + 12 hours);
        (,,, uint256[] memory amountsIn) = idx.previewRebalance();
        usdt.mint(executor, amountsIn[0]);
        vm.startPrank(executor);
        usdt.approve(address(idx), amountsIn[0]);
        idx.acceptRebalance(new bytes32[](1), new uint256[](0));
        vm.stopPrank();
        usdt.addBlackList(address(idx));
        usdt.destroyBlackFunds(address(idx));
        (uint256[] memory units,,) = idx.fillAmounts();
        uint256 required = idx.totalSupply() * units[0] / 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.RebalanceUnderfunded.selector, address(usdt), 0, required)
        );
        idx.settleRebalance(_oneEmpty());
    }

    /// @dev An index of Tether and the vault's native coin, seeded with 10 shares, 1 of them the executor's.
    function _usdtIndex() internal returns (MockUSDT usdt, IHybridIndex idx) {
        usdt = new MockUSDT();
        idx = _indexWith(address(usdt), 1e17);
    }

    /// @dev An index of `token`, listed at `supply`, and the vault's native coin, seeded with 10 shares, 1 of them the
    ///      executor's. `token` mints as the mocks do, and is called through MockUSDT's interface, whose `approve`
    ///      returns nothing, so a token returning a bool works too.
    function _indexWith(address token, uint256 supply) internal returns (IHybridIndex idx) {
        vm.prank(owner);
        factory.proposeListing(token, supply);
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(token);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (token, native);
        vm.prank(minter);
        idx = IHybridIndex(factory.createIndex("Two", "TWO", tokens, K));
        vault.registerIndex(address(idx), factory.indexSalt(address(idx)));
        uint256[] memory amounts = idx.previewOrder(10e18);
        MockUSDT(token).mint(minter, amounts[0]);
        vm.startPrank(minter);
        MockUSDT(token).approve(address(idx), amounts[0]);
        (uint256 orderId, uint256 intakeId) = idx.openOrder(10e18, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        _fresh();
        vault.deposit{value: amounts[1]}(address(idx), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        idx.settleOrder(orderId, _chainProof(block.timestamp, amounts[1]));
        vm.warp(block.timestamp + 1 days);
        idx.claimOrder(orderId);
        vm.prank(minter);
        idx.transfer(executor, 1e18);
    }

    /// @dev HubShares mints, moves, burns and reads exactly what OpenZeppelin's token keeps, refusing what a balance
    ///      lacks and a supply past 2^256.
    function test_hubSharesAreOpenZeppelinsShares() public {
        HubSharesHarness h = new HubSharesHarness();
        h.mint(minter, 10e18);
        h.move(minter, holder, 3e18);
        assertEq(h.balanceOf(minter), 7e18);
        assertEq(h.balanceOf(holder), 3e18);
        h.burnFrom(holder, 1e18);
        assertEq(h.balanceOf(holder), 2e18);
        assertEq(h.totalSupply(), 9e18);
        assertEq(h.shareSupply(), 9e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 2e18, 3e18));
        h.move(holder, minter, 3e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 2e18, 3e18));
        h.burnFrom(holder, 3e18);

        vm.expectEmit(address(h));
        emit IERC20.Transfer(address(0), holder, 5e18);
        h.mintShares(holder, 5e18);
        assertEq(h.balanceOf(holder), 7e18);
        assertEq(h.totalSupply(), 14e18);
        h.mint(minter, 1e18); // OpenZeppelin's own mint reads the same supply
        assertEq(h.shareSupply(), 15e18);
        vm.expectRevert(stdError.arithmeticError);
        h.mintShares(holder, type(uint256).max);
    }
}
