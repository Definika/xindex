// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHybridHubTypes} from "../src/interfaces/IHybridHubTypes.sol";
import {IHybridIndex} from "../src/interfaces/IHybridIndex.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {VaultMessages} from "../src/libraries/VaultMessages.sol";
import {HybridTest} from "./HybridTest.sol";
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

    /// @dev A vault leg bought: the executor delivers on the vault chain, is paid WETH on Ethereum once the delivery is
    ///      proven, and gets its bond back after the hold.
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
        vm.recordLogs();
        hub.settleRebalance(_proofOf(deliveries[1]));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _deliverAll(logs);

        (, uint256[] memory unitsAfter,,) = hub.components();
        assertLt(unitsAfter[0], unitsBefore[0]);
        assertGt(unitsAfter[1], unitsBefore[1]);
        assertGt(weth.balanceOf(executor), 0, "paid the sold WETH");
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
        vm.expectRevert(); // a preimage claiming the full delivery does not hash to the vault's digest
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

        // The honest state now: settled, with the whole delivery.
        IHybridHubTypes.ChainProof memory honest = _proofOf(deliveries[1])[0];
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAContradiction.selector, chainId));
        hub.slashRebalance(chainId, 2, honest);
        vm.expectRevert(); // an open intake's preimage does not hash to the settled digest
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
        IHybridHubTypes.ChainProof memory failed = _proofOf(deliveries[1])[0];
        failed.proof = _forged(block.timestamp, _digestOf(intakeId, 3, deliveries[1]));
        uint256 snap = vm.snapshotState();
        hub.slashRebalance(chainId, 3, failed);
        vm.revertToState(snap);
        IHybridHubTypes.ChainProof memory never = _proofOf(0)[0];
        never.proof = _forged(block.timestamp, bytes32(0));
        hub.slashRebalance(chainId, 0, never);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(
            abi.encodeWithSelector(IHybridHubTypes.WrongFillStatus.selector, IHybridHubTypes.FillStatus.None)
        );
        hub.slashRebalance(chainId, 0, never);
    }

    function test_slash_notAfterTheHold() public {
        _liveAuction(true);
        uint256[] memory deliveries = _accept();
        _deliver(deliveries[1]);
        hub.settleRebalance(_proofOf(deliveries[1]));
        uint256 release = hub.fill().bondRelease;
        vm.warp(release);
        IHybridHubTypes.ChainProof memory never = _proofOf(0)[0];
        never.proof = _forged(block.timestamp, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotYet.selector, release));
        hub.slashRebalance(chainId, 0, never);
        vm.expectRevert(abi.encodeWithSelector(IHybridHubTypes.NotAVaultChain.selector, 9));
        vm.warp(release - 1);
        hub.slashRebalance(9, 0, never);
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
        vault.deposit{value: amountsIn[1]}(address(three), three.fillIntakeId());
        vm.stopPrank();
        three.settleRebalance(_proofOf(amountsIn[1]));
        (, uint256[] memory afterUnits,,) = three.components();
        assertEq(afterUnits[2], before[2]);
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
        vm.prank(owner);
        factory.proposeListing(address(usdt), 1e17);
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(address(usdt));
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdt), native);
        idx = IHybridIndex(factory.createIndex("Tether", "XUSD", tokens, K));
        vault.registerIndex(address(idx), factory.indexSalt(address(idx)));
        uint256[] memory amounts = idx.previewOrder(10e18);
        usdt.mint(minter, amounts[0]);
        vm.startPrank(minter);
        usdt.approve(address(idx), amounts[0]);
        (uint256 orderId, uint256 intakeId) = idx.openOrder(10e18, block.timestamp + 1 hours);
        vm.deal(minter, amounts[1]);
        vault.deposit{value: amounts[1]}(address(idx), intakeId);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 hours);
        idx.settleOrder(orderId, _chainProof(block.timestamp, amounts[1]));
        vm.warp(block.timestamp + 1 days);
        idx.claimOrder(orderId);
        vm.prank(minter);
        idx.transfer(executor, 1e18);
    }

    /// @dev HubShares moves, burns and reads exactly what OpenZeppelin's token keeps, refusing what a balance lacks.
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
    }
}
