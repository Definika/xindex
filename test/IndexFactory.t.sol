// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexHub} from "../src/IndexHub.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";

contract IndexFactoryTest is XindexTest {
    MockERC20 a;
    MockERC20 b;
    MockERC20 c;

    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address stranger = makeAddr("stranger");

    /// @dev With this scale a component's units equal its reference supply.
    uint256 constant K = 1e36;
    uint256 constant A_SUPPLY = 1e18;
    uint256 constant B_SUPPLY = 1e8;
    uint256 constant C_SUPPLY = 5e6;

    function setUp() public {
        market = new MockMarket();
        factory = _newFactory(owner, guardian);
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 8);
        c = new MockERC20("C", "C", 6);
        _listWith(address(a), A_SUPPLY);
        _listWith(address(b), B_SUPPLY);
    }

    function _newFactory(address owner_, address guardian_) internal returns (IndexFactory) {
        return new IndexFactory(owner_, guardian_);
    }

    function _two() internal view returns (address[] memory t) {
        t = new address[](2);
        (t[0], t[1]) = (address(a), address(b));
    }

    /// @dev Lists `n` fresh tokens within one delay, each with a supply of MIN_RAW_UNITS, so k = K gives each the
    ///      smallest units an index can start with.
    function _listed(uint256 n) internal returns (address[] memory t) {
        t = new address[](n);
        uint256 supply = factory.MIN_RAW_UNITS();
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(new MockERC20("M", "M", 18));
            factory.proposeListing(t[i], supply);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(t[i]);
        }
    }

    /// @dev `a` and `b` in ascending address order, with the supplies given for each.
    function _batch(uint256 supplyA, uint256 supplyB)
        internal
        view
        returns (address[] memory tokens, uint256[] memory supplies)
    {
        tokens = new address[](2);
        supplies = new uint256[](2);
        bool aFirst = address(a) < address(b);
        (tokens[0], tokens[1]) = aFirst ? (address(a), address(b)) : (address(b), address(a));
        (supplies[0], supplies[1]) = aFirst ? (supplyA, supplyB) : (supplyB, supplyA);
    }

    function _step(uint256 supply) internal view returns (uint256) {
        return supply * factory.MAX_SUPPLY_STEP() / 1e18;
    }

    // ---------------------------------------------------------------------
    // constructor, ownership and roles
    // ---------------------------------------------------------------------

    function test_constructor() public {
        vm.expectEmit(true, true, true, true);
        emit IIndexFactory.GuardianSet(address(0), guardian);
        IndexFactory fresh = _newFactory(owner, guardian);

        assertEq(fresh.owner(), owner);
        assertEq(fresh.guardian(), guardian);
        assertEq(fresh.MAX_COMPONENTS(), 100);
        // IndexHub stores keep and skip masks in 256 bits, one per component.
        assertLe(fresh.MAX_COMPONENTS(), 256);
        assertEq(fresh.MAX_BATCH(), 200);
        assertEq(fresh.MAX_SUPPLY_STEP(), 0.005e18);
        assertEq(fresh.MAX_SUPPLY(), type(uint128).max);
        assertEq(fresh.MIN_RAW_UNITS(), 10_000);
        assertEq(fresh.MAX_UNITS(), type(uint96).max >> 10);
        assertEq(fresh.K_SCALE(), 1e36);
        assertEq(fresh.LISTING_DELAY(), 2 days);
        assertEq(fresh.GUARDIAN_DELAY(), 7 days);
        assertEq(fresh.PROPOSAL_WINDOW(), 7 days);
        assertEq(fresh.pendingGuardian(), address(0));
        assertEq(fresh.pendingGuardianEta(), 0);
        assertEq(fresh.allIndexesLength(), 0);
        assertEq(fresh.whitelistedTokens().length, 0);
        assertEq(fresh.supplyBatchCount(), 0);
        assertFalse(fresh.suppliesPending());
        assertEq(IndexHub(fresh.IMPLEMENTATION()).FACTORY(), address(fresh));

        IndexFactory unguarded = _newFactory(owner, address(0));
        assertEq(unguarded.guardian(), address(0));
    }

    function test_isOwnerOrGuardian() public {
        assertTrue(factory.isOwnerOrGuardian(owner));
        assertTrue(factory.isOwnerOrGuardian(guardian));
        assertFalse(factory.isOwnerOrGuardian(stranger));
        assertFalse(factory.isOwnerOrGuardian(address(0)));

        IndexFactory unguarded = _newFactory(owner, address(0));
        assertFalse(unguarded.isOwnerOrGuardian(address(0)), "a missing guardian is nobody");
        assertTrue(unguarded.isOwnerOrGuardian(owner));
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(IIndexFactory.RenounceDisabled.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), owner);
    }

    function test_ownership_twoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), owner);
        assertEq(factory.pendingOwner(), newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.acceptOwnership();

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
    }

    // ---------------------------------------------------------------------
    // guardian changes
    // ---------------------------------------------------------------------

    function test_proposeGuardian_startsDelayAndKeepsCurrentGuardian() public {
        address next = makeAddr("next");
        uint256 eta = block.timestamp + factory.GUARDIAN_DELAY();
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.GuardianProposed(next, eta);
        vm.prank(owner);
        factory.proposeGuardian(next);

        assertEq(factory.pendingGuardian(), next);
        assertEq(factory.pendingGuardianEta(), eta);
        assertEq(factory.guardian(), guardian, "the current guardian keeps its powers while the change is pending");

        address later = makeAddr("later");
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        factory.proposeGuardian(later);
        assertEq(factory.pendingGuardian(), later);
        assertEq(factory.pendingGuardianEta(), block.timestamp + factory.GUARDIAN_DELAY());
    }

    function test_XA60_replacingAPendingGuardianChangeEmitsItsCancellation() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        vm.prank(owner);
        factory.proposeGuardian(first);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.GuardianChangeCancelled(first);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.GuardianProposed(second, block.timestamp + factory.GUARDIAN_DELAY());
        vm.prank(owner);
        factory.proposeGuardian(second);
        assertEq(factory.pendingGuardian(), second);
    }

    function test_proposeGuardian_onlyOwner() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.proposeGuardian(address(0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.proposeGuardian(stranger);
    }

    function test_executeGuardianChange_onlyAfterDelay_byAnyone() public {
        vm.expectRevert(IIndexFactory.NoPendingGuardianChange.selector);
        factory.executeGuardianChange();

        address next = makeAddr("next");
        vm.prank(owner);
        factory.proposeGuardian(next);
        uint256 eta = factory.pendingGuardianEta();

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.GuardianChangeNotReady.selector, eta));
        factory.executeGuardianChange();

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.GuardianSet(guardian, next);
        vm.prank(stranger);
        factory.executeGuardianChange();

        assertEq(factory.guardian(), next);
        assertEq(factory.pendingGuardian(), address(0));
        assertEq(factory.pendingGuardianEta(), 0);
    }

    function test_executeGuardianChange_expires() public {
        vm.prank(owner);
        factory.proposeGuardian(address(0));
        uint256 deadline = factory.pendingGuardianEta() + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.GuardianChangeExpired.selector, deadline));
        factory.executeGuardianChange();
        assertEq(factory.guardian(), guardian);
    }

    /// @dev DA-16. An expired proposal can never be executed but still leaves its stored fields set, so a monitor
    ///      reading those alone reports it as pending forever. The predicate views answer the question the stored
    ///      fields cannot: for a guardian change, a listing and a supply batch alike.
    function test_DA16_theViewsTellAPendingProposalFromAnExpiredOne() public {
        address next = makeAddr("next guardian");
        assertFalse(factory.guardianChangePending(), "nothing proposed");

        vm.prank(owner);
        factory.proposeGuardian(next);
        uint256 deadline = factory.pendingGuardianEta() + factory.PROPOSAL_WINDOW();
        assertTrue(factory.guardianChangePending(), "proposed and executable");

        vm.warp(deadline);
        assertTrue(factory.guardianChangePending(), "the last moment still counts");
        vm.warp(deadline + 1);
        assertFalse(factory.guardianChangePending(), "expired, though the stored fields still read as set");
        assertEq(factory.pendingGuardian(), next, "which is exactly the trap");
        assertGt(factory.pendingGuardianEta(), 0);
        assertEq(factory.guardian(), guardian, "the guardian never changed");

        MockERC20 token = new MockERC20("Late", "LATE", 18);
        assertFalse(factory.listingPending(address(token)));
        vm.prank(owner);
        factory.proposeListing(address(token), 1e30);
        assertTrue(factory.listingPending(address(token)));
        vm.warp(factory.listingEta(address(token)) + factory.PROPOSAL_WINDOW() + 1);
        assertFalse(factory.listingPending(address(token)), "expired listing");
        assertGt(factory.listingEta(address(token)), 0);

        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY, B_SUPPLY + 1);
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        (, uint256 batchEta,,) = factory.pendingSupplies();
        vm.warp(batchEta + factory.PROPOSAL_WINDOW());
        assertTrue(factory.suppliesPending(), "a batch's last moment still counts");
        vm.warp(batchEta + factory.PROPOSAL_WINDOW() + 1);
        assertFalse(factory.suppliesPending(), "an expired batch");
        (, uint256 stillSet,,) = factory.pendingSupplies();
        assertEq(stillSet, batchEta, "though its eta still reads as set");
    }

    /// @dev CR-I33. At exactly `listingEta + PROPOSAL_WINDOW` a listing still executes, so the view has to call it
    ///      pending there, and stop a second later.
    function test_CRI33_aListingIsPendingAtTheLastMomentItCanExecute() public {
        MockERC20 late = new MockERC20("Late", "LATE", 18);
        vm.prank(owner);
        factory.proposeListing(address(late), 1e30);
        uint256 deadline = factory.listingEta(address(late)) + factory.PROPOSAL_WINDOW();

        uint256 snapshot = vm.snapshotState();
        vm.warp(deadline + 1);
        assertFalse(factory.listingPending(address(late)), "a second later it is dead");
        vm.revertToState(snapshot);

        vm.warp(deadline);
        assertTrue(factory.listingPending(address(late)), "the last executable moment is still pending");
        factory.executeListing(address(late));
        assertTrue(factory.isWhitelisted(address(late)), "and it does execute");
    }

    /// @dev CR-I33. Executing a listing clears what described it, so nothing reads as a listing waiting to happen once
    ///      it has happened.
    function test_CRI33_anExecutedListingLeavesNothingPending() public {
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        assertEq(factory.pendingReferenceSupply(address(c)), C_SUPPLY);
        vm.warp(factory.listingEta(address(c)));
        factory.executeListing(address(c));
        assertEq(factory.listingEta(address(c)), 0);
        assertEq(factory.pendingReferenceSupply(address(c)), 0, "nothing is pending once the listing has executed");
        assertFalse(factory.listingPending(address(c)));
    }

    /// @dev CR-I33. With no change pending, a guardian proposal cancels nothing, so it announces nothing but itself.
    function test_CRI33_aFirstGuardianProposalCancelsNothing() public {
        assertEq(factory.pendingGuardianEta(), 0);
        vm.recordLogs();
        vm.prank(owner);
        factory.proposeGuardian(makeAddr("next"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only GuardianProposed");
        assertEq(logs[0].topics[0], IIndexFactory.GuardianProposed.selector);
    }

    /// @dev LR-05: the last moment of the window still executes, as the listing window's last moment is tested to.
    function test_LR05_aGuardianChangeExecutesAtTheLastMomentOfItsWindow() public {
        address next = makeAddr("next guardian");
        vm.prank(owner);
        factory.proposeGuardian(next);
        vm.warp(factory.pendingGuardianEta() + factory.PROPOSAL_WINDOW());
        factory.executeGuardianChange();
        assertEq(factory.guardian(), next);
    }

    function test_cancelGuardianChange() public {
        vm.prank(owner);
        vm.expectRevert(IIndexFactory.NoPendingGuardianChange.selector);
        factory.cancelGuardianChange();

        address next = makeAddr("next");
        vm.prank(owner);
        factory.proposeGuardian(next);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, guardian));
        factory.cancelGuardianChange();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelGuardianChange();

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.GuardianChangeCancelled(next);
        vm.prank(owner);
        factory.cancelGuardianChange();
        assertEq(factory.pendingGuardian(), address(0));
        assertEq(factory.pendingGuardianEta(), 0);

        vm.warp(block.timestamp + factory.GUARDIAN_DELAY());
        vm.expectRevert(IIndexFactory.NoPendingGuardianChange.selector);
        factory.executeGuardianChange();
    }

    /// @dev XA-61: the owner can replace the guardian, but it cannot remove the role over the guardian's objection.
    function test_XA61_theGuardianCanCancelItsOwnRemoval() public {
        vm.prank(owner);
        factory.proposeGuardian(address(0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelGuardianChange();

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.GuardianChangeCancelled(address(0));
        vm.prank(guardian);
        factory.cancelGuardianChange();
        assertEq(factory.pendingGuardianEta(), 0);
        assertEq(factory.guardian(), guardian, "the guardian is still there");

        vm.startPrank(owner);
        factory.proposeGuardian(address(0));
        vm.warp(block.timestamp + factory.GUARDIAN_DELAY());
        factory.executeGuardianChange();
        factory.proposeGuardian(address(0));
        vm.stopPrank();
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(0)));
        factory.cancelGuardianChange();
        vm.prank(owner);
        factory.cancelGuardianChange();
        assertEq(factory.pendingGuardianEta(), 0);
    }

    // ---------------------------------------------------------------------
    // listings
    // ---------------------------------------------------------------------

    function test_proposeListing_startsDelayWithTheSupply() public {
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingProposed(address(c), eta, C_SUPPLY);
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        assertEq(factory.listingEta(address(c)), eta);
        assertEq(factory.pendingReferenceSupply(address(c)), C_SUPPLY);
        assertFalse(factory.isWhitelisted(address(c)), "nothing is listed before the delay");
        assertEq(factory.referenceSupply(address(c)), 0);
    }

    function test_proposeListing_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.proposeListing(address(c), C_SUPPLY);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, stranger));
        factory.proposeListing(stranger, C_SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.AlreadyListed.selector, address(a)));
        factory.proposeListing(address(a), A_SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SupplyOutOfRange.selector, address(c), 0));
        factory.proposeListing(address(c), 0);
        uint256 tooMuch = factory.MAX_SUPPLY() + 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SupplyOutOfRange.selector, address(c), tooMuch));
        factory.proposeListing(address(c), tooMuch);
        factory.proposeListing(address(c), factory.MAX_SUPPLY()); // the largest supply is accepted

        uint256 eta = factory.listingEta(address(c));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingPending.selector, address(c), eta));
        factory.proposeListing(address(c), C_SUPPLY);
        vm.stopPrank();
    }

    function test_proposeListing_againAfterExpiry() public {
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        uint256 deadline = factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW();
        vm.warp(deadline + 1);
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY * 2);
        assertEq(factory.pendingReferenceSupply(address(c)), C_SUPPLY * 2, "an expired proposal is replaced");
    }

    function test_executeListing_onlyAfterDelay_byAnyone() public {
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.executeListing(address(c));

        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        uint256 eta = factory.listingEta(address(c));
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingNotReady.selector, address(c), eta));
        factory.executeListing(address(c));

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ReferenceSupplySet(address(c), 0, C_SUPPLY);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenWhitelisted(address(c), true);
        vm.prank(stranger);
        factory.executeListing(address(c));
        assertTrue(factory.isWhitelisted(address(c)));
        assertEq(factory.referenceSupply(address(c)), C_SUPPLY);
        assertEq(factory.whitelistedTokens().length, 3);
    }

    function test_executeListing_lastMomentOfWindowSucceeds() public {
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        vm.warp(factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW());
        factory.executeListing(address(c));
        assertTrue(factory.isWhitelisted(address(c)));
    }

    function test_executeListing_expires() public {
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        uint256 deadline = factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW();
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingExpired.selector, address(c), deadline));
        factory.executeListing(address(c));
        assertFalse(factory.isWhitelisted(address(c)));
    }

    function test_cancelListing() public {
        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelListing(address(c));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingCancelled(address(c));
        vm.prank(guardian);
        factory.cancelListing(address(c));
        assertEq(factory.listingEta(address(c)), 0);
        assertEq(factory.pendingReferenceSupply(address(c)), 0);

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.executeListing(address(c));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.cancelListing(address(c));

        vm.startPrank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        factory.cancelListing(address(c));
        vm.stopPrank();
        assertEq(factory.listingEta(address(c)), 0);
    }

    function test_delist_swapAndPopAndKeepsTheSupply() public {
        _listWith(address(c), C_SUPPLY);
        address[] memory list = factory.whitelistedTokens();
        assertEq(list.length, 3);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenWhitelisted(address(a), false);
        vm.prank(guardian);
        factory.delist(address(a));
        list = factory.whitelistedTokens();
        assertEq(list.length, 2);
        assertEq(list[0], address(c));
        assertEq(list[1], address(b));
        assertFalse(factory.isWhitelisted(address(a)));
        assertEq(factory.referenceSupply(address(a)), A_SUPPLY, "existing indexes still rebalance with the supply");

        vm.prank(owner);
        factory.delist(address(b));
        list = factory.whitelistedTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(c));

        _listWith(address(a), A_SUPPLY);
        list = factory.whitelistedTokens();
        assertEq(list.length, 2);
        assertEq(list[1], address(a));
    }

    /// @dev LR-05: delisting the token that swap-and-pop moved must still work.
    function test_LR05_aTokenMovedBySwapAndPopCanStillBeDelisted() public {
        _listWith(address(c), C_SUPPLY);
        vm.startPrank(guardian);
        factory.delist(address(a)); // moves c into a's slot: [c, b]
        factory.delist(address(c)); // c is now first, and b moves into its slot: [b]
        vm.stopPrank();
        address[] memory list = factory.whitelistedTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(b));
        assertFalse(factory.isWhitelisted(address(c)));

        vm.prank(guardian);
        factory.delist(address(b));
        assertEq(factory.whitelistedTokens().length, 0);
    }

    function test_delist_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.delist(address(a));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotWhitelisted.selector, address(c)));
        factory.delist(address(c));
    }

    /// @dev DA-18 and CR-L03, re-targeted: a relisting is bounded by the step from the supply the token carried, since
    ///      the indexes still holding it follow that supply; a first listing has nothing to compare against. A
    ///      whitelisted token cannot take a listing at all, so no path around a batch moves a supply.
    /// @dev DA-18, CR-L03 and SA-02: a relisting cannot move a supply at all, not even by the step a batch may take,
    ///      since relistings execute one token at a time and a stranger could order two of them around a start. The
    ///      supply in force is the only one a relisting takes, and it comes back unchanged and unannounced.
    function test_DA18_CRL03_SA02_aRelistingKeepsTheSupplyInForce() public {
        vm.prank(owner);
        factory.delist(address(a));
        uint256 step = _step(A_SUPPLY);

        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.RelistChangesSupply.selector, address(a), A_SUPPLY, A_SUPPLY * 10)
        );
        factory.proposeListing(address(a), A_SUPPLY * 10); // the decimals slip an order of magnitude would be
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.RelistChangesSupply.selector, address(a), A_SUPPLY, A_SUPPLY + step)
        );
        factory.proposeListing(address(a), A_SUPPLY + step);
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.RelistChangesSupply.selector, address(a), A_SUPPLY, A_SUPPLY - 1)
        );
        factory.proposeListing(address(a), A_SUPPLY - 1);
        factory.proposeListing(address(a), A_SUPPLY);
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.recordLogs();
        factory.executeListing(address(a));
        assertEq(factory.referenceSupply(address(a)), A_SUPPLY);
        assertTrue(factory.isWhitelisted(address(a)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IIndexFactory.ReferenceSupplySet.selector, "nothing changed to announce");
        }

        // A first listing takes any supply in range.
        vm.prank(owner);
        factory.proposeListing(address(c), 1);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(address(c));
        assertEq(factory.referenceSupply(address(c)), 1);
    }

    // ---------------------------------------------------------------------
    // supply batches
    // ---------------------------------------------------------------------

    function test_proposeSupplies_andExecuteThemAllAtOnce() public {
        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY + _step(A_SUPPLY), B_SUPPLY - _step(B_SUPPLY));
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.SuppliesProposed(1, eta, t, s);
        vm.prank(owner);
        factory.proposeSupplies(t, s);

        (uint256 id, uint256 pendingEta, address[] memory pt, uint256[] memory ps) = factory.pendingSupplies();
        assertEq(id, 1);
        assertEq(pendingEta, eta);
        assertEq(pt, t);
        assertEq(ps, s);
        assertTrue(factory.suppliesPending());
        assertEq(factory.referenceSupply(address(a)), A_SUPPLY, "nothing changes before the delay");

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SuppliesNotReady.selector, eta));
        factory.executeSupplies();

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ReferenceSupplySet(t[0], t[0] == address(a) ? A_SUPPLY : B_SUPPLY, s[0]);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ReferenceSupplySet(t[1], t[1] == address(a) ? A_SUPPLY : B_SUPPLY, s[1]);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.SuppliesExecuted(1);
        vm.prank(stranger);
        factory.executeSupplies();

        assertEq(factory.referenceSupply(address(a)), A_SUPPLY + _step(A_SUPPLY));
        assertEq(factory.referenceSupply(address(b)), B_SUPPLY - _step(B_SUPPLY));
        (, pendingEta, pt, ps) = factory.pendingSupplies();
        assertEq(pendingEta + pt.length + ps.length, 0, "the executed batch is cleared");
        assertFalse(factory.suppliesPending());
        uint256[] memory both = factory.referenceSupplies(t);
        assertEq(both, s, "the batch view reads the supplies in force");

        vm.expectRevert(IIndexFactory.NoPendingSupplies.selector);
        factory.executeSupplies();
    }

    function test_proposeSupplies_validatesEveryEntry() public {
        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY, B_SUPPLY);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.proposeSupplies(t, s);

        vm.startPrank(owner);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        factory.proposeSupplies(t, new uint256[](1));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidBatch.selector, address(0)));
        factory.proposeSupplies(new address[](0), new uint256[](0));
        uint256 tooLong = factory.MAX_BATCH() + 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidBatch.selector, address(0)));
        factory.proposeSupplies(new address[](tooLong), new uint256[](tooLong));

        // Out of order, and a repeat: both break strict ascent at the second entry.
        (address[] memory swapped, uint256[] memory swappedSupplies) = (new address[](2), new uint256[](2));
        (swapped[0], swapped[1], swappedSupplies[0], swappedSupplies[1]) = (t[1], t[0], s[1], s[0]);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidBatch.selector, t[0]));
        factory.proposeSupplies(swapped, swappedSupplies);
        swapped[1] = t[1];
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidBatch.selector, t[1]));
        factory.proposeSupplies(swapped, swappedSupplies);

        // A token that never carried a supply.
        address[] memory one = new address[](1);
        uint256[] memory oneSupply = new uint256[](1);
        (one[0], oneSupply[0]) = (address(c), C_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotConfigured.selector, address(c)));
        factory.proposeSupplies(one, oneSupply);

        // Zero, and past one step either way.
        (one[0], oneSupply[0]) = (address(a), 0);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SupplyOutOfRange.selector, address(a), 0));
        factory.proposeSupplies(one, oneSupply);
        uint256 step = _step(A_SUPPLY);
        oneSupply[0] = A_SUPPLY + step + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.SupplyStepTooLarge.selector, address(a), A_SUPPLY, oneSupply[0])
        );
        factory.proposeSupplies(one, oneSupply);
        oneSupply[0] = A_SUPPLY - step - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.SupplyStepTooLarge.selector, address(a), A_SUPPLY, oneSupply[0])
        );
        factory.proposeSupplies(one, oneSupply);
        vm.stopPrank();
    }

    /// @dev CR-I29, re-targeted: the step is exactly MAX_SUPPLY_STEP of the supply in force, rounded down, in both
    ///      directions: a supply at the edge is a revision, one raw unit past it is refused.
    function test_CRI29_theStepIsExactlyHalfAPercent() public {
        uint256 inForce = factory.referenceSupply(address(a));
        uint256 step = _step(inForce);
        assertEq(step, inForce / 200, "half a percent");
        address[] memory one = new address[](1);
        uint256[] memory supply = new uint256[](1);
        one[0] = address(a);
        uint256[2] memory edges = [inForce + step, inForce - step];
        uint256[2] memory past = [inForce + step + 1, inForce - step - 1];
        for (uint256 i = 0; i < 2; ++i) {
            supply[0] = edges[i];
            vm.prank(owner);
            factory.proposeSupplies(one, supply);
            vm.prank(owner);
            factory.cancelSupplies();

            supply[0] = past[i];
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(IIndexFactory.SupplyStepTooLarge.selector, address(a), inForce, past[i])
            );
            factory.proposeSupplies(one, supply);
        }
    }

    function test_proposeSupplies_oneBatchAtATime() public {
        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY + 1, B_SUPPLY);
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        (, uint256 eta,,) = factory.pendingSupplies();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SuppliesPending.selector, eta));
        factory.proposeSupplies(t, s);

        // Executable and then expired: still one at a time until the window closes, replaced afterwards.
        vm.warp(eta + factory.PROPOSAL_WINDOW());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SuppliesPending.selector, eta));
        factory.proposeSupplies(t, s);
        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SuppliesExpired.selector, eta + factory.PROPOSAL_WINDOW()));
        factory.executeSupplies();
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        assertEq(factory.supplyBatchCount(), 2, "the expired batch was replaced by a new one");
    }

    function test_cancelSupplies() public {
        vm.prank(guardian);
        vm.expectRevert(IIndexFactory.NoPendingSupplies.selector);
        factory.cancelSupplies();

        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY + 1, B_SUPPLY);
        vm.prank(owner);
        factory.proposeSupplies(t, s);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelSupplies();

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.SuppliesCancelled(1);
        vm.prank(guardian);
        factory.cancelSupplies();
        assertFalse(factory.suppliesPending());
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(IIndexFactory.NoPendingSupplies.selector);
        factory.executeSupplies();
        assertEq(factory.referenceSupply(address(a)), A_SUPPLY, "a cancelled batch changes nothing");

        vm.prank(owner);
        factory.proposeSupplies(t, s); // a cancelled batch leaves room for the next at once
    }

    /// @dev Nothing but the batch may change a supply the batch was checked against: a listing of a token in the live
    ///      batch waits, and a batch refuses a token with a live listing. Once the batch has executed, expired or been
    ///      cancelled, the listing is free again.
    function test_aBatchAndAListingNeverOverlapOnAToken() public {
        vm.prank(owner);
        factory.delist(address(a));
        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY + 1, B_SUPPLY);
        vm.prank(owner);
        factory.proposeSupplies(t, s);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenInBatch.selector, address(a)));
        factory.proposeListing(address(a), A_SUPPLY);

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeSupplies();
        vm.prank(owner);
        factory.proposeListing(address(a), A_SUPPLY + 1); // the batch is done, so the relisting may go ahead

        uint256 eta = factory.listingEta(address(a));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingPending.selector, address(a), eta));
        factory.proposeSupplies(t, s);

        // An expired listing no longer blocks a batch.
        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        vm.prank(owner);
        factory.proposeSupplies(t, s);
    }

    // ---------------------------------------------------------------------
    // createIndex
    // ---------------------------------------------------------------------

    function test_createIndex_success() public {
        address[] memory t = _two();
        uint256[] memory u = factory.previewUnits(t, K);
        assertEq(u[0], A_SUPPLY, "units are k times the supply over K_SCALE");
        assertEq(u[1], B_SUPPLY);
        address predicted = factory.predictIndexAddress(creator, "My Index", "MYX", t, K);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.IndexCreated(predicted, creator, "My Index", "MYX", t, u);
        vm.prank(creator);
        address index = factory.createIndex("My Index", "MYX", t, K);

        assertEq(index, predicted);
        assertTrue(factory.isIndex(index));
        assertEq(factory.creatorOf(index), creator);
        assertEq(factory.allIndexesLength(), 1);
        assertEq(factory.allIndexes(0), index);

        IndexHub it = IndexHub(index);
        assertEq(it.name(), "My Index");
        assertEq(it.symbol(), "MYX");
        assertEq(it.FACTORY(), address(factory));
        assertEq(it.lastRebalance(), block.timestamp);
        (address[] memory tt, uint256[] memory uu) = it.components();
        assertEq(tt, t);
        assertEq(uu, u);
        assertEq(it.totalSupply(), 0);
    }

    function test_createIndex_unitsFollowTheSuppliesInForce() public {
        address[] memory t = _two();
        uint256 k = 3 * K / 7; // a scale with a remainder, so the rounding shows
        uint256[] memory u = factory.previewUnits(t, k);
        assertEq(u[0], A_SUPPLY * 3 / 7, "rounded down");
        assertEq(u[1], B_SUPPLY * 3 / 7);
        vm.prank(creator);
        (, uint256[] memory created) = IndexHub(factory.createIndex("Scaled", "SCL", t, k)).components();
        assertEq(created, u);
    }

    /// @dev LR-05 and the units salt: the address commits to the creator, the name, the symbol, the token list and its
    ///      order, and the computed units, each varied on its own.
    function test_LR05_addressCommitsToEveryPartOfTheBasket() public {
        _listWith(address(c), C_SUPPLY);
        address[] memory t = _two();
        address mine = factory.predictIndexAddress(creator, "Same", "SAME", t, K);
        assertTrue(mine != factory.predictIndexAddress(stranger, "Same", "SAME", t, K), "the creator");
        assertTrue(mine != factory.predictIndexAddress(creator, "Other", "SAME", t, K), "the name");
        assertTrue(mine != factory.predictIndexAddress(creator, "Same", "OTHER", t, K), "the symbol");
        assertTrue(mine != factory.predictIndexAddress(creator, "Same", "SAME", t, 2 * K), "the units");

        address[] memory otherTokens = new address[](2);
        (otherTokens[0], otherTokens[1]) = (t[0], address(c));
        address other = factory.predictIndexAddress(creator, "Same", "SAME", otherTokens, K);
        assertTrue(mine != other, "the token list");
        (otherTokens[0], otherTokens[1]) = (t[1], t[0]);
        assertTrue(mine != factory.predictIndexAddress(creator, "Same", "SAME", otherTokens, K), "and its order");

        (otherTokens[0], otherTokens[1]) = (t[0], address(c));
        vm.startPrank(creator);
        assertEq(factory.createIndex("Same", "SAME", t, K), mine);
        assertEq(factory.createIndex("Same", "SAME", otherTokens, K), other);
        vm.stopPrank();
    }

    /// @dev The salt covers the computed units, not `k`: a supply batch that lands between a prediction and a creation
    ///      moves the address, so an address can never hold another basket than the one predicted for it.
    function test_aBatchBetweenPredictionAndCreationMovesTheAddressNotTheBasket() public {
        address[] memory t = _two();
        address predicted = factory.predictIndexAddress(creator, "Same", "SAME", t, K);
        uint256[] memory promised = factory.previewUnits(t, K);
        (address[] memory bt, uint256[] memory bs) = _batch(A_SUPPLY + _step(A_SUPPLY), B_SUPPLY);
        _revise(bt, bs);

        vm.prank(creator);
        address index = factory.createIndex("Same", "SAME", t, K);
        assertTrue(index != predicted, "a different basket lands at a different address");
        (, uint256[] memory units) = IndexHub(index).components();
        assertTrue(units[0] != promised[0]);
        assertEq(predicted.code.length, 0, "nothing was ever deployed at the predicted address");
    }

    function test_createIndex_revertsDuplicateBySameCreator() public {
        address[] memory t = _two();
        vm.prank(creator);
        address first = factory.createIndex("Same", "SAME", t, K);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.IndexAlreadyExists.selector, first));
        factory.createIndex("Same", "SAME", t, K);
    }

    function test_createIndex_delistingDoesNotAffectExisting() public {
        address[] memory t = _two();
        address index = factory.createIndex("X", "X", t, K);

        vm.prank(owner);
        factory.delist(address(a));

        (address[] memory tt,) = IndexHub(index).components();
        assertEq(tt[0], address(a));
        assertTrue(factory.isIndex(index));

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(a)));
        factory.createIndex("Y", "Y", t, K);
    }

    function test_createIndex_revertsEmptyName() public {
        address[] memory t = _two();
        vm.expectRevert(IIndexFactory.EmptyString.selector);
        factory.createIndex("", "X", t, K);
        vm.expectRevert(IIndexFactory.EmptyString.selector);
        factory.createIndex("X", "", t, K);
    }

    function test_createIndex_revertsNoComponents() public {
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidComponentCount.selector, 0));
        factory.createIndex("X", "X", new address[](0), K);
    }

    function test_createIndex_revertsTooManyComponents() public {
        uint256 n = factory.MAX_COMPONENTS() + 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidComponentCount.selector, n));
        factory.createIndex("X", "X", new address[](n), K);
    }

    /// @dev An index of MAX_COMPONENTS is created inside one transaction under EIP-7825's 2^24 cap, with the factory
    ///      and every token cooled so the call pays the cold reads a transaction of its own would, and 100,000 gas left
    ///      for the transaction's base cost and calldata.
    /// @dev SA-04. Weekly supply updates were policy only: a new batch could be proposed the moment the last one
    ///      executed and come due two days later, so a supply could move a step every two days. A batch now comes due no
    ///      sooner than MIN_SUPPLY_INTERVAL after the last one executed, so a supply moves at most a step a week.
    function test_SA04_batchesComeDueAtMostWeekly() public {
        assertEq(factory.MIN_SUPPLY_INTERVAL(), 7 days);
        assertEq(factory.lastSupplyUpdate(), 0);
        (address[] memory t, uint256[] memory s) = _batch(A_SUPPLY + _step(A_SUPPLY), B_SUPPLY);
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        (, uint256 eta,,) = factory.pendingSupplies();
        assertEq(eta, block.timestamp + factory.LISTING_DELAY(), "the first batch waits only the delay");
        vm.warp(eta);
        factory.executeSupplies();
        uint256 last = block.timestamp;
        assertEq(factory.lastSupplyUpdate(), last);

        uint256 inForce = factory.referenceSupply(address(a));
        (t, s) = _batch(inForce + _step(inForce), B_SUPPLY);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.SuppliesProposed(2, last + 7 days, t, s);
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.SuppliesNotReady.selector, last + 7 days));
        factory.executeSupplies();
        vm.warp(last + 7 days);
        factory.executeSupplies();
        assertEq(factory.referenceSupply(address(a)), inForce + _step(inForce), "a step a week");

        // Once the interval has passed, a batch again waits only the delay.
        vm.warp(block.timestamp + 10 days);
        inForce = factory.referenceSupply(address(a));
        (t, s) = _batch(inForce - _step(inForce), B_SUPPLY);
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        (, eta,,) = factory.pendingSupplies();
        assertEq(eta, block.timestamp + factory.LISTING_DELAY());
    }

    /// @dev SA-03. A batch of MAX_BATCH tokens none of which was ever batched, which writes every slot from zero, is
    ///      proposed and executed each inside one transaction under EIP-7825's 2^24 cap, with the factory cooled so the
    ///      call pays the cold reads a transaction of its own would, and 1.5M gas left for the Safe and the calldata. At
    ///      256 the proposal alone took about 18.9M.
    function test_SA03_aFullBatchFitsOneTransactionCold() public {
        uint256 n = factory.MAX_BATCH();
        address[] memory t = _listed(n);
        for (uint256 i = 1; i < n; ++i) {
            for (uint256 j = i; j > 0 && t[j - 1] > t[j]; --j) {
                (t[j - 1], t[j]) = (t[j], t[j - 1]);
            }
        }
        uint256[] memory s = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            s[i] = factory.referenceSupply(t[i]) + _step(factory.referenceSupply(t[i]));
        }
        vm.cool(address(factory));
        uint256 before = gasleft();
        vm.prank(owner);
        factory.proposeSupplies(t, s);
        uint256 used = before - gasleft();
        assertLe(used + 1_500_000, 2 ** 24, "a full first batch is proposed in one transaction");

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.cool(address(factory));
        before = gasleft();
        factory.executeSupplies();
        assertLe(before - gasleft() + 1_500_000, 2 ** 24, "and executed in one");
        assertEq(factory.referenceSupply(t[n - 1]), s[n - 1]);
    }

    function test_createIndex_maxComponentsOk() public {
        address[] memory t = _listed(factory.MAX_COMPONENTS());
        vm.cool(address(factory));
        for (uint256 i = 0; i < t.length; ++i) {
            vm.cool(t[i]);
        }
        uint256 before = gasleft();
        address index = factory.createIndex("Big", "BIG", t, K);
        uint256 used = before - gasleft();
        assertLe(used + 100_000, 2 ** 24, "createIndex fits one transaction");
        assertEq(IndexHub(index).componentCount(), t.length);
    }

    function test_createIndex_revertsNotWhitelisted() public {
        address[] memory t = new address[](1);
        t[0] = address(c);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(c)));
        factory.createIndex("X", "X", t, K);

        vm.prank(owner);
        factory.proposeListing(address(c), C_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(c)));
        factory.createIndex("X", "X", t, K);
    }

    function test_createIndex_revertsDuplicate() public {
        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(a), address(a));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.DuplicateToken.selector, address(a)));
        factory.createIndex("X", "X", t, K);
    }

    /// @dev DA-09, re-targeted: no index starts with a component coarser than MIN_RAW_UNITS, and none so large that its
    ///      units could not grow through the rebalances ahead. Both edges are inclusive.
    function test_DA09_unitsMustStartBetweenTheFloorAndTheHeadroom() public {
        address[] memory t = _two();
        uint256 floorK = factory.MIN_RAW_UNITS() * K / B_SUPPLY; // B, the smaller supply, sets the floor
        vm.expectRevert(
            abi.encodeWithSelector(IIndexFactory.UnitsOutOfRange.selector, address(b), factory.MIN_RAW_UNITS() - 1)
        );
        factory.createIndex("X", "X", t, floorK - K / B_SUPPLY);
        factory.createIndex("X", "X", t, floorK);

        uint256 maxUnits = factory.MAX_UNITS();
        uint256 ceilingK = maxUnits * K / A_SUPPLY; // A, the larger supply, sets the ceiling
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.UnitsOutOfRange.selector, address(a), maxUnits + 1));
        factory.createIndex("Y", "Y", t, ceilingK + K / A_SUPPLY);
        factory.createIndex("Y", "Y", t, ceilingK);
    }
}
