// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {GuardianRelay} from "../src/GuardianRelay.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {IGuardianRelay} from "../src/interfaces/IGuardianRelay.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {WeightedTest} from "./WeightedTest.sol";

/// @notice The guardian relay (RZ-26): a factory whose guardian is a relay its Safe controls. Since RX-3 a start
///         carries a Pyth update valid for one slot, which a Safe cannot land; the Safe authorizes the start and
///         anyone sends it, with an update of their own, once.
contract GuardianRelayTest is WeightedTest {
    GuardianRelay relay;
    WeightedHub index;

    address safe = makeAddr("guardian safe");

    /// @dev Keeps the dollar leg, as around a frozen coin or a stopped feed: ETH and BTC still move.
    uint256 constant KEEP_USD = 4;

    function setUp() public {
        _deploy();
        relay = new GuardianRelay(safe);
        factory = new WeightedIndexFactory(owner, address(relay), address(pyth));
        _listAll();
        index = _create(_defaultSpecs());
        _issue(index, alice, 100e18);
        vm.warp(index.earliestRebalance());
    }

    function _authorize(uint256 keepMask, uint256 deadline) internal {
        vm.prank(safe);
        relay.authorizeStart(address(index), keepMask, deadline);
    }

    /// @dev `who` sends the authorized start, with an update for every feed the mask moves and none for a kept one.
    function _send(address who, uint256 keepMask) internal {
        bytes[] memory update = pyth.liveUpdates(index, keepMask);
        vm.prank(who);
        relay.start(address(index), update);
    }

    function _assertNoAuthorization() internal view {
        (uint256 keepMask, uint256 deadline) = relay.authorizationOf(address(index));
        assertEq(keepMask, 0, "keepMask");
        assertEq(deadline, 0, "deadline");
    }

    function test_RZ26_theSafeAuthorizesAKeepMaskStartAndAnyoneSendsIt() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectEmit(address(relay));
        emit IGuardianRelay.StartAuthorized(address(index), KEEP_USD, deadline);
        _authorize(KEEP_USD, deadline);
        (uint256 keepMask, uint256 until) = relay.authorizationOf(address(index));
        assertEq(keepMask, KEEP_USD);
        assertEq(until, deadline);

        uint256 proposalId = index.proposalCount() + 1;
        uint256 nonce = index.rebalanceNonce() + 1;
        uint256 eta = block.timestamp + index.REBALANCE_DELAY();
        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        assertEq(update.length, 2, "no update for the kept leg");
        vm.expectEmit(address(relay));
        emit IGuardianRelay.AuthorizedStartSent(address(index), KEEP_USD, stranger);
        vm.expectEmit(address(index));
        emit IWeightedHub.RebalanceStarted(proposalId, nonce, address(relay), KEEP_USD, eta);
        vm.prank(stranger);
        relay.start(address(index), update);

        (uint256 pendingEta, uint256 pendingMask) = index.pendingRebalance();
        assertEq(pendingEta, eta);
        assertEq(pendingMask, KEEP_USD);
        _assertNoAuthorization();
    }

    /// @dev The relay holds the role: the Safe itself is no guardian, and its own start is refused.
    function test_RZ26_theSafeItselfIsNotTheGuardian() public {
        assertEq(factory.guardian(), address(relay));
        assertFalse(factory.isOwnerOrGuardian(safe));
        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, safe));
        vm.prank(safe);
        index.startRebalance(KEEP_USD, update);
    }

    function test_RZ26_anAuthorizationIsSentOnce() public {
        _authorize(KEEP_USD, block.timestamp + 1 hours);
        _send(stranger, KEEP_USD);
        vm.prank(safe);
        relay.cancelRebalance(address(index));

        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        vm.expectRevert(abi.encodeWithSelector(IGuardianRelay.NoAuthorizedStart.selector, address(index)));
        vm.prank(stranger);
        relay.start(address(index), update);
    }

    function test_RZ26_anAuthorizationLastsUntilItsDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        _authorize(KEEP_USD, deadline);
        vm.warp(deadline + 1);
        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        vm.expectRevert(abi.encodeWithSelector(IGuardianRelay.NoAuthorizedStart.selector, address(index)));
        vm.prank(stranger);
        relay.start(address(index), update);

        vm.warp(deadline);
        _send(stranger, KEEP_USD);
        (, uint256 pendingMask) = index.pendingRebalance();
        assertEq(pendingMask, KEEP_USD, "sendable at its deadline");
    }

    function test_RZ26_aPastDeadlineWithdrawsAnAuthorization() public {
        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        vm.expectRevert(abi.encodeWithSelector(IGuardianRelay.NoAuthorizedStart.selector, address(index)));
        vm.prank(stranger);
        relay.start(address(index), update);

        _authorize(KEEP_USD, block.timestamp + 1 hours);
        _authorize(KEEP_USD, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(IGuardianRelay.NoAuthorizedStart.selector, address(index)));
        vm.prank(stranger);
        relay.start(address(index), update);
    }

    /// @dev A start the index refuses reverts whole, so the authorization stays for the next attempt.
    function test_RZ26_aRefusedStartKeepsItsAuthorization() public {
        uint256 deadline = block.timestamp + 1 hours;
        _authorize(KEEP_USD, deadline);
        bytes[] memory open = pyth.liveUpdates(index, 0);
        vm.prank(stranger);
        index.startRebalance(0, open);

        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        (uint256 eta,) = index.pendingRebalance();
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.RebalancePending.selector, eta + index.AUCTION_DURATION()));
        vm.prank(stranger);
        relay.start(address(index), update);
        (uint256 keepMask, uint256 until) = relay.authorizationOf(address(index));
        assertEq(keepMask, KEEP_USD);
        assertEq(until, deadline);

        vm.prank(safe);
        relay.cancelRebalance(address(index));
        _send(stranger, KEEP_USD);
        (, uint256 pendingMask) = index.pendingRebalance();
        assertEq(pendingMask, KEEP_USD);
    }

    /// @dev A cancel holds strangers off; the guardian's start, authorized and sent by anyone, is not.
    function test_RZ26_theRelayStartsBeforeStrangersMay() public {
        _send0(stranger);
        vm.prank(safe);
        relay.cancelRebalance(address(index));
        bytes[] memory open = pyth.liveUpdates(index, 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        index.startRebalance(0, open);

        _authorize(0, block.timestamp + 1 hours);
        _send(stranger, 0);
        (uint256 eta,) = index.pendingRebalance();
        assertEq(eta, block.timestamp + index.REBALANCE_DELAY());
    }

    function _send0(address who) internal {
        bytes[] memory open = pyth.liveUpdates(index, 0);
        vm.prank(who);
        index.startRebalance(0, open);
    }

    function test_RZ26_theGuardiansOtherPowersGoThroughTheRelay() public {
        _send0(stranger);
        vm.prank(safe);
        relay.cancelRebalance(address(index));
        (uint256 eta,) = index.pendingRebalance();
        assertEq(eta, 0, "rebalance cancelled");

        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(owner);
        factory.proposeListing(address(other), keccak256("OTH/USD"));
        vm.prank(safe);
        relay.cancelListing(address(factory), address(other));
        assertFalse(factory.listingPending(address(other)), "listing cancelled");

        vm.prank(safe);
        relay.delist(address(factory), address(usd));
        assertFalse(factory.isWhitelisted(address(usd)), "delisted");

        vm.prank(owner);
        factory.proposeGuardian(address(0));
        vm.prank(safe);
        relay.cancelGuardianChange(address(factory));
        assertFalse(factory.guardianChangePending(), "its removal cancelled");
        assertEq(factory.guardian(), address(relay));
    }

    function test_RZ26_onlyTheSafeAuthorizesOrUsesTheGuardiansPowers() public {
        address[2] memory others = [stranger, owner];
        for (uint256 i = 0; i < others.length; ++i) {
            bytes memory err = abi.encodeWithSelector(IGuardianRelay.NotController.selector, others[i]);
            vm.startPrank(others[i]);
            vm.expectRevert(err);
            relay.authorizeStart(address(index), KEEP_USD, block.timestamp + 1 hours);
            vm.expectRevert(err);
            relay.cancelRebalance(address(index));
            vm.expectRevert(err);
            relay.cancelListing(address(factory), address(usd));
            vm.expectRevert(err);
            relay.delist(address(factory), address(usd));
            vm.expectRevert(err);
            relay.cancelGuardianChange(address(factory));
            vm.stopPrank();
        }
        _assertNoAuthorization();
    }

    function test_RZ26_theStartsFeeGoesToPyth() public {
        _authorize(KEEP_USD, block.timestamp + 1 hours);
        pyth.setFee(1);
        bytes[] memory update = pyth.liveUpdates(index, KEEP_USD);
        vm.deal(stranger, 1 ether);
        vm.expectRevert(MockPyth.InsufficientFee.selector);
        vm.prank(stranger);
        relay.start{value: 1}(address(index), update);

        vm.prank(stranger);
        relay.start{value: 2}(address(index), update);
        assertEq(address(pyth).balance, 2);
        assertEq(address(relay).balance, 0, "nothing stays in the relay");
        assertEq(address(index).balance, 0, "nothing stays in the index");
    }

    function test_RZ26_aRelayNeedsAController() public {
        assertEq(relay.CONTROLLER(), safe);
        vm.expectRevert(IGuardianRelay.ZeroController.selector);
        new GuardianRelay(address(0));
    }
}
