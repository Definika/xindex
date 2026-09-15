// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract IndexFactoryTest is Test {
    IndexFactory factory;
    MockERC20 a;
    MockERC20 b;
    MockERC20 c;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address creator = makeAddr("creator");
    address stranger = makeAddr("stranger");

    function setUp() public {
        factory = new IndexFactory(owner, guardian);
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 8);
        c = new MockERC20("C", "C", 6);
        _list(address(a));
        _list(address(b));
    }

    function _list(address token) internal {
        vm.prank(owner);
        factory.proposeListing(token);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function _two() internal view returns (address[] memory t, uint256[] memory u) {
        t = new address[](2);
        u = new uint256[](2);
        t[0] = address(a);
        t[1] = address(b);
        u[0] = 1e18;
        u[1] = 1e8;
    }

    // ---------------------------------------------------------------------
    // constructor and ownership
    // ---------------------------------------------------------------------

    function test_constructor() public {
        vm.expectEmit(true, true, true, true);
        emit IIndexFactory.GuardianSet(address(0), guardian);
        IndexFactory fresh = new IndexFactory(owner, guardian);

        assertEq(fresh.owner(), owner);
        assertEq(fresh.guardian(), guardian);
        assertEq(fresh.MAX_COMPONENTS(), 20);
        assertEq(fresh.LISTING_DELAY(), 2 days);
        assertEq(fresh.GUARDIAN_DELAY(), 7 days);
        assertEq(fresh.PROPOSAL_WINDOW(), 7 days);
        assertEq(fresh.pendingGuardian(), address(0));
        assertEq(fresh.pendingGuardianEta(), 0);
        assertEq(IndexToken(fresh.IMPLEMENTATION()).FACTORY(), address(fresh));
        assertEq(fresh.allIndexesLength(), 0);
        assertEq(fresh.whitelistedTokens().length, 0);

        IndexFactory unguarded = new IndexFactory(owner, address(0));
        assertEq(unguarded.guardian(), address(0));
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

        // A new proposal replaces the pending one and restarts the delay.
        address later = makeAddr("later");
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        factory.proposeGuardian(later);
        assertEq(factory.pendingGuardian(), later);
        assertEq(factory.pendingGuardianEta(), block.timestamp + factory.GUARDIAN_DELAY());
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

    function test_cancelGuardianChange() public {
        vm.prank(owner);
        vm.expectRevert(IIndexFactory.NoPendingGuardianChange.selector);
        factory.cancelGuardianChange();

        address next = makeAddr("next");
        vm.prank(owner);
        factory.proposeGuardian(next);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
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

    // ---------------------------------------------------------------------
    // listing flow
    // ---------------------------------------------------------------------

    function test_proposeListing_startsDelay() public {
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingProposed(address(c), eta);
        vm.prank(owner);
        factory.proposeListing(address(c));

        assertEq(factory.listingEta(address(c)), eta);
        assertFalse(factory.isWhitelisted(address(c)));
    }

    function test_proposeListing_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.proposeListing(address(c));

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, stranger));
        factory.proposeListing(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, address(0)));
        factory.proposeListing(address(0));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.AlreadyWhitelisted.selector, address(a)));
        factory.proposeListing(address(a));

        factory.proposeListing(address(c));
        uint256 eta = factory.listingEta(address(c));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingPending.selector, address(c), eta));
        factory.proposeListing(address(c));
        vm.stopPrank();
    }

    function test_proposeListing_againAfterExpiry() public {
        vm.prank(owner);
        factory.proposeListing(address(c));
        uint256 eta = factory.listingEta(address(c));

        vm.warp(eta + factory.PROPOSAL_WINDOW()); // last moment of the window: still pending
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingPending.selector, address(c), eta));
        factory.proposeListing(address(c));

        vm.warp(block.timestamp + 1); // expired: it can be proposed again, with a fresh delay
        vm.prank(owner);
        factory.proposeListing(address(c));
        assertEq(factory.listingEta(address(c)), block.timestamp + factory.LISTING_DELAY());
    }

    function test_executeListing_onlyAfterDelay_byAnyone() public {
        vm.prank(owner);
        factory.proposeListing(address(c));
        uint256 eta = factory.listingEta(address(c));

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingNotReady.selector, address(c), eta));
        factory.executeListing(address(c));

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenWhitelisted(address(c), true);
        vm.prank(stranger);
        factory.executeListing(address(c));

        assertTrue(factory.isWhitelisted(address(c)));
        assertEq(factory.listingEta(address(c)), 0);
        address[] memory list = factory.whitelistedTokens();
        assertEq(list.length, 3);
        assertEq(list[2], address(c));

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.executeListing(address(c));
    }

    function test_executeListing_lastMomentOfWindowSucceeds() public {
        vm.prank(owner);
        factory.proposeListing(address(c));
        vm.warp(factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW());
        factory.executeListing(address(c));
        assertTrue(factory.isWhitelisted(address(c)));
    }

    function test_executeListing_expires() public {
        vm.prank(owner);
        factory.proposeListing(address(c));
        uint256 deadline = factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingExpired.selector, address(c), deadline));
        factory.executeListing(address(c));
        assertFalse(factory.isWhitelisted(address(c)));

        vm.prank(guardian); // an expired proposal can still be cleaned up
        factory.cancelListing(address(c));
        assertEq(factory.listingEta(address(c)), 0);
    }

    function test_cancelListing() public {
        vm.prank(owner);
        factory.proposeListing(address(c));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.Unauthorized.selector, stranger));
        factory.cancelListing(address(c));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingCancelled(address(c));
        vm.prank(guardian);
        factory.cancelListing(address(c));
        assertEq(factory.listingEta(address(c)), 0);

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.executeListing(address(c));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.cancelListing(address(c));

        vm.startPrank(owner);
        factory.proposeListing(address(c));
        factory.cancelListing(address(c));
        vm.stopPrank();
        assertEq(factory.listingEta(address(c)), 0);
    }

    function test_delist_swapAndPop() public {
        _list(address(c));
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

        vm.prank(owner);
        factory.delist(address(b));
        list = factory.whitelistedTokens();
        assertEq(list.length, 1);
        assertEq(list[0], address(c));

        _list(address(a));
        list = factory.whitelistedTokens();
        assertEq(list.length, 2);
        assertEq(list[1], address(a));
    }

    function test_delist_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.Unauthorized.selector, stranger));
        factory.delist(address(a));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotWhitelisted.selector, address(c)));
        factory.delist(address(c));
    }

    // ---------------------------------------------------------------------
    // createIndex
    // ---------------------------------------------------------------------

    function test_createIndex_success() public {
        (address[] memory t, uint256[] memory u) = _two();
        address predicted = factory.predictIndexAddress(creator, "My Index", "MYX", t, u);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.IndexCreated(predicted, creator, "My Index", "MYX", t, u);
        vm.prank(creator);
        address index = factory.createIndex("My Index", "MYX", t, u);

        assertEq(index, predicted);
        assertTrue(factory.isIndex(index));
        assertEq(factory.creatorOf(index), creator);
        assertEq(factory.allIndexesLength(), 1);
        assertEq(factory.allIndexes(0), index);

        IndexToken it = IndexToken(index);
        assertEq(it.name(), "My Index");
        assertEq(it.symbol(), "MYX");
        assertEq(it.FACTORY(), address(factory));
        (address[] memory tt, uint256[] memory uu) = it.components();
        assertEq(tt[0], address(a));
        assertEq(tt[1], address(b));
        assertEq(uu[0], 1e18);
        assertEq(uu[1], 1e8);
        assertEq(it.totalSupply(), 0);
    }

    function test_createIndex_addressCommitsToCreatorAndComposition() public {
        (address[] memory t, uint256[] memory u) = _two();
        address mine = factory.predictIndexAddress(creator, "Same", "SAME", t, u);
        address theirs = factory.predictIndexAddress(stranger, "Same", "SAME", t, u);
        u[1] = 2e8;
        address otherUnits = factory.predictIndexAddress(creator, "Same", "SAME", t, u);
        assertTrue(mine != theirs);
        assertTrue(mine != otherUnits);
        assertTrue(theirs != otherUnits);

        u[1] = 1e8;
        vm.prank(creator);
        assertEq(factory.createIndex("Same", "SAME", t, u), mine);
        vm.prank(stranger);
        assertEq(factory.createIndex("Same", "SAME", t, u), theirs);
        assertEq(factory.creatorOf(theirs), stranger);
        assertEq(factory.allIndexesLength(), 2);
    }

    function test_createIndex_revertsDuplicateBySameCreator() public {
        (address[] memory t, uint256[] memory u) = _two();
        vm.prank(creator);
        address first = factory.createIndex("Same", "SAME", t, u);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.IndexAlreadyExists.selector, first));
        factory.createIndex("Same", "SAME", t, u);
    }

    function test_createIndex_delistingDoesNotAffectExisting() public {
        (address[] memory t, uint256[] memory u) = _two();
        address index = factory.createIndex("X", "X", t, u);

        vm.prank(owner);
        factory.delist(address(a));

        (address[] memory tt,) = IndexToken(index).components();
        assertEq(tt[0], address(a));
        assertTrue(factory.isIndex(index));

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(a)));
        factory.createIndex("Y", "Y", t, u);
    }

    function test_createIndex_revertsEmptyName() public {
        (address[] memory t, uint256[] memory u) = _two();
        vm.expectRevert(IIndexFactory.EmptyString.selector);
        factory.createIndex("", "X", t, u);
        vm.expectRevert(IIndexFactory.EmptyString.selector);
        factory.createIndex("X", "", t, u);
    }

    function test_createIndex_revertsNoComponents() public {
        address[] memory t = new address[](0);
        uint256[] memory u = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidComponentCount.selector, 0));
        factory.createIndex("X", "X", t, u);
    }

    function test_createIndex_revertsTooManyComponents() public {
        uint256 n = factory.MAX_COMPONENTS() + 1;
        address[] memory t = new address[](n);
        uint256[] memory u = new uint256[](n);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidComponentCount.selector, n));
        factory.createIndex("X", "X", t, u);
    }

    function test_createIndex_maxComponentsOk() public {
        uint256 n = factory.MAX_COMPONENTS();
        address[] memory t = new address[](n);
        uint256[] memory u = new uint256[](n);
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(new MockERC20("M", "M", 18));
            u[i] = 1;
            factory.proposeListing(t[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(t[i]);
        }
        address index = factory.createIndex("Big", "BIG", t, u);
        assertEq(IndexToken(index).componentCount(), n);
    }

    function test_createIndex_revertsLengthMismatch() public {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](1);
        t[0] = address(a);
        t[1] = address(b);
        u[0] = 1;
        vm.expectRevert(IIndexFactory.LengthMismatch.selector);
        factory.createIndex("X", "X", t, u);
    }

    function test_createIndex_revertsNotWhitelisted() public {
        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(c);
        u[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(c)));
        factory.createIndex("X", "X", t, u);

        vm.prank(owner);
        factory.proposeListing(address(c));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(c)));
        factory.createIndex("X", "X", t, u);
    }

    function test_createIndex_revertsDuplicate() public {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = address(a);
        t[1] = address(a);
        u[0] = 1;
        u[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.DuplicateToken.selector, address(a)));
        factory.createIndex("X", "X", t, u);
    }

    function test_createIndex_revertsZeroUnits() public {
        (address[] memory t, uint256[] memory u) = _two();
        u[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidUnits.selector, address(b), 0));
        factory.createIndex("X", "X", t, u);
    }

    function test_createIndex_revertsUnitsTooLarge() public {
        (address[] memory t, uint256[] memory u) = _two();
        u[0] = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidUnits.selector, address(a), u[0]));
        factory.createIndex("X", "X", t, u);
        u[0] = type(uint96).max;
        factory.createIndex("X", "X", t, u);
    }
}
