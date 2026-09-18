// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexRule} from "../src/IndexRule.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
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

    function setUp() public {
        market = new MockMarket();
        factory = _newFactory(owner, guardian);
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 8);
        c = new MockERC20("C", "C", 6);
        _list(address(a));
        _list(address(b));
    }

    function _newFactory(address owner_, address guardian_) internal returns (IndexFactory) {
        return new IndexFactory(
            owner_, guardian_, address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
    }

    function _two() internal view returns (address[] memory t, uint256[] memory u) {
        t = new address[](2);
        u = new uint256[](2);
        t[0] = address(a);
        t[1] = address(b);
        u[0] = 1e18;
        u[1] = 1e8;
    }

    /// @dev Lists `n` fresh tokens within one delay and returns them with one raw unit each.
    function _listed(uint256 n) internal returns (address[] memory t, uint256[] memory u) {
        t = new address[](n);
        u = new uint256[](n);
        IIndexFactory.TokenConfig[] memory configs = new IIndexFactory.TokenConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            t[i] = address(new MockERC20("M", "M", 18));
            u[i] = 1;
            configs[i] = market.config(t[i], 0);
        }
        vm.startPrank(owner);
        for (uint256 i = 0; i < n; ++i) {
            factory.proposeListing(t[i], configs[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        for (uint256 i = 0; i < n; ++i) {
            factory.executeListing(t[i]);
        }
    }

    function _assertConfig(IIndexFactory.TokenConfig memory got, IIndexFactory.TokenConfig memory want) internal pure {
        assertEq(got.pool, want.pool, "pool");
        assertEq(got.minLiquidity, want.minLiquidity, "min liquidity");
        assertEq(got.referenceSupply, want.referenceSupply, "reference supply");
        assertEq(keccak256(abi.encode(got.excluded)), keccak256(abi.encode(want.excluded)), "excluded");
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
        assertEq(fresh.MAX_COMPONENTS(), 20);
        // IndexToken stores a keep mask in 24 bits, one per component.
        assertLe(fresh.MAX_COMPONENTS(), 24);
        assertEq(fresh.MIN_CAPPED_COMPONENTS(), 5);
        assertEq(fresh.LISTING_DELAY(), 2 days);
        assertEq(fresh.GUARDIAN_DELAY(), 7 days);
        assertEq(fresh.PROPOSAL_WINDOW(), 7 days);
        assertEq(fresh.pendingGuardian(), address(0));
        assertEq(fresh.pendingGuardianEta(), 0);
        assertEq(fresh.allIndexesLength(), 0);
        assertEq(fresh.whitelistedTokens().length, 0);

        IndexRule rule = IndexRule(fresh.RULE());
        assertEq(rule.FACTORY(), address(fresh));
        assertEq(rule.WETH(), address(market.weth()));
        assertEq(rule.UNISWAP_V3_FACTORY(), address(market.uniswapV3Factory()));
        assertEq(rule.USDC(), address(market.usdc()));
        assertEq(rule.USD_POOL(), address(market.usdPool()));
        assertEq(IndexToken(fresh.IMPLEMENTATION()).FACTORY(), address(fresh));
        assertEq(IndexToken(fresh.IMPLEMENTATION()).RULE(), address(rule));

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

        // A new proposal replaces the pending one and restarts the delay.
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

        // An app that builds pending proposals from events must see the first one end.
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

        // The guardian cannot block its own replacement, and nobody else can cancel at all.
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

        // A factory that already has no guardian has nobody to cancel with, and the owner is unaffected either way.
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
    // listings and token configs
    // ---------------------------------------------------------------------

    function test_proposeListing_startsDelayWithTheConfig() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingProposed(
            address(c), eta, true, config.pool, config.minLiquidity, config.referenceSupply, config.excluded
        );
        vm.prank(owner);
        factory.proposeListing(address(c), config);

        assertEq(factory.listingEta(address(c)), eta);
        assertFalse(factory.isWhitelisted(address(c)));
        _assertConfig(factory.pendingTokenConfig(address(c)), config);
        assertEq(factory.tokenConfig(address(c)).pool, address(0), "nothing is in force before execution");
    }

    function test_proposeListing_reverts() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.proposeListing(address(c), config);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, stranger));
        factory.proposeListing(stranger, config);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotAContract.selector, address(0)));
        factory.proposeListing(address(0), config);

        factory.proposeListing(address(c), config);
        uint256 eta = factory.listingEta(address(c));
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingPending.selector, address(c), eta));
        factory.proposeListing(address(c), config);
        vm.stopPrank();
    }

    function test_proposeListing_rejectsAConfigTheRuleRejects() public {
        IIndexFactory.TokenConfig memory noPool = IIndexFactory.TokenConfig({
            pool: address(0), minLiquidity: 1, referenceSupply: 1, excluded: new address[](0)
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexRule.InvalidPool.selector, address(c), address(0)));
        factory.proposeListing(address(c), noPool);
        assertEq(factory.listingEta(address(c)), 0);
    }

    function test_proposeListing_againAfterExpiry() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(owner);
        factory.proposeListing(address(c), config);
        uint256 eta = factory.listingEta(address(c));

        vm.warp(eta + factory.PROPOSAL_WINDOW()); // last moment of the window: still pending
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingPending.selector, address(c), eta));
        factory.proposeListing(address(c), config);

        vm.warp(block.timestamp + 1); // expired: it can be proposed again, with a fresh delay
        vm.prank(owner);
        factory.proposeListing(address(c), config);
        assertEq(factory.listingEta(address(c)), block.timestamp + factory.LISTING_DELAY());
    }

    function test_configChange_forAListedTokenWaitsForTheDelay() public {
        IIndexFactory.TokenConfig memory current = factory.tokenConfig(address(a));
        address[] memory excluded = new address[](1);
        excluded[0] = makeAddr("burn");
        a.mint(stranger, 1e18);
        IIndexFactory.TokenConfig memory next = market.configWith(address(a), 5, 0, excluded);

        vm.prank(owner);
        factory.proposeListing(address(a), next);
        assertTrue(factory.isWhitelisted(address(a)), "a config change does not delist");
        _assertConfig(factory.tokenConfig(address(a)), current);

        vm.warp(factory.listingEta(address(a)));
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenConfigured(address(a), next.pool, next.minLiquidity, 0, excluded);
        factory.executeListing(address(a));

        _assertConfig(factory.tokenConfig(address(a)), next);
        assertEq(factory.pendingTokenConfig(address(a)).excluded.length, 0);
        assertEq(factory.whitelistedTokens().length, 2, "the token is not listed twice");
    }

    function test_executeListing_onlyAfterDelay_byAnyone() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(owner);
        factory.proposeListing(address(c), config);
        uint256 eta = factory.listingEta(address(c));

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingNotReady.selector, address(c), eta));
        factory.executeListing(address(c));

        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenConfigured(
            address(c), config.pool, config.minLiquidity, config.referenceSupply, config.excluded
        );
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenWhitelisted(address(c), true);
        vm.prank(stranger);
        factory.executeListing(address(c));

        assertTrue(factory.isWhitelisted(address(c)));
        assertEq(factory.listingEta(address(c)), 0);
        _assertConfig(factory.tokenConfig(address(c)), config);
        assertEq(factory.pendingTokenConfig(address(c)).pool, address(0));
        address[] memory list = factory.whitelistedTokens();
        assertEq(list.length, 3);
        assertEq(list[2], address(c));

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.executeListing(address(c));
    }

    function test_executeListing_lastMomentOfWindowSucceeds() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(owner);
        factory.proposeListing(address(c), config);
        vm.warp(factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW());
        factory.executeListing(address(c));
        assertTrue(factory.isWhitelisted(address(c)));
    }

    function test_executeListing_expires() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(owner);
        factory.proposeListing(address(c), config);
        uint256 deadline = factory.listingEta(address(c)) + factory.PROPOSAL_WINDOW();

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.ListingExpired.selector, address(c), deadline));
        factory.executeListing(address(c));
        assertFalse(factory.isWhitelisted(address(c)));

        vm.prank(guardian); // an expired proposal can still be cleaned up
        factory.cancelListing(address(c));
        assertEq(factory.listingEta(address(c)), 0);
        assertEq(factory.pendingTokenConfig(address(c)).pool, address(0));
    }

    function test_cancelListing() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(owner);
        factory.proposeListing(address(c), config);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelListing(address(c));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingCancelled(address(c));
        vm.prank(guardian);
        factory.cancelListing(address(c));
        assertEq(factory.listingEta(address(c)), 0);
        assertEq(factory.pendingTokenConfig(address(c)).pool, address(0));

        vm.warp(block.timestamp + factory.LISTING_DELAY());
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.executeListing(address(c));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(c)));
        factory.cancelListing(address(c));

        vm.startPrank(owner);
        factory.proposeListing(address(c), config);
        factory.cancelListing(address(c));
        vm.stopPrank();
        assertEq(factory.listingEta(address(c)), 0);
    }

    function test_delist_swapAndPopAndKeepsTheConfig() public {
        _list(address(c));
        address[] memory list = factory.whitelistedTokens();
        assertEq(list.length, 3);
        address poolOfA = factory.tokenConfig(address(a)).pool;

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenWhitelisted(address(a), false);
        vm.prank(guardian);
        factory.delist(address(a));
        list = factory.whitelistedTokens();
        assertEq(list.length, 2);
        assertEq(list[0], address(c));
        assertEq(list[1], address(b));
        assertFalse(factory.isWhitelisted(address(a)));
        assertEq(factory.tokenConfig(address(a)).pool, poolOfA, "existing indexes still rebalance with the config");

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

    /// @dev LR-05: the test above never delists the token that swap-and-pop moved. Without the moved token's position
    ///      being updated, delisting it next panics on an out-of-bounds read, and the guardian loses that power.
    function test_LR05_aTokenMovedBySwapAndPopCanStillBeDelisted() public {
        _list(address(c));
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

    function test_proposeConfig_replacesTheConfigWithoutListing() public {
        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.proposeConfig(address(c), config);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NotConfigured.selector, address(c)));
        factory.proposeConfig(address(c), config); // c was never listed

        // A listed token: the change applies and the whitelist is untouched.
        IIndexFactory.TokenConfig memory next = market.configWith(address(a), 0, 5e24, new address[](0));
        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingProposed(
            address(a), eta, false, next.pool, next.minLiquidity, next.referenceSupply, next.excluded
        );
        vm.prank(owner);
        factory.proposeConfig(address(a), next);
        assertFalse(factory.pendingIsListing(address(a)));

        // Delisting keeps a pending config-only change; executing it leaves the token delisted.
        vm.prank(guardian);
        factory.delist(address(a));
        assertEq(factory.listingEta(address(a)), eta);
        vm.warp(eta);
        factory.executeListing(address(a));
        assertFalse(factory.isWhitelisted(address(a)));
        assertEq(factory.tokenConfig(address(a)).referenceSupply, 5e24);
        assertEq(factory.whitelistedTokens().length, 1);

        // WETH's config has no pool, only a reference supply, and can be refreshed too.
        address weth = address(market.weth());
        _list(weth);
        IIndexFactory.TokenConfig memory etherConfig = market.configWith(weth, 0, 121_000_000e18, new address[](0));
        vm.prank(owner);
        factory.proposeConfig(weth, etherConfig);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(weth);
        assertTrue(factory.isWhitelisted(weth));
        assertEq(factory.tokenConfig(weth).referenceSupply, 121_000_000e18);
    }

    function test_delist_cancelsAPendingListingProposal() public {
        IIndexFactory.TokenConfig memory next = market.config(address(a), 0);
        vm.prank(owner);
        factory.proposeListing(address(a), next);
        assertTrue(factory.pendingIsListing(address(a)));

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.TokenWhitelisted(address(a), false);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.ListingCancelled(address(a));
        vm.prank(guardian);
        factory.delist(address(a));
        assertEq(factory.listingEta(address(a)), 0);
        assertFalse(factory.pendingIsListing(address(a)));
        assertEq(factory.pendingTokenConfig(address(a)).pool, address(0));

        // Relisting needs a fresh proposal and a full delay.
        vm.prank(owner);
        factory.proposeListing(address(a), next);
        assertEq(factory.listingEta(address(a)), block.timestamp + factory.LISTING_DELAY());
        vm.prank(guardian);
        factory.cancelListing(address(a));
        assertFalse(factory.pendingIsListing(address(a)), "cancelling clears the intent too");
    }

    function test_delist_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
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
        address predicted = factory.predictIndexAddress(creator, "My Index", "MYX", t, u, 0);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IIndexFactory.IndexCreated(predicted, creator, "My Index", "MYX", t, u, 0);
        vm.prank(creator);
        address index = factory.createIndex("My Index", "MYX", t, u, 0);

        assertEq(index, predicted);
        assertTrue(factory.isIndex(index));
        assertEq(factory.creatorOf(index), creator);
        assertEq(factory.allIndexesLength(), 1);
        assertEq(factory.allIndexes(0), index);

        IndexToken it = IndexToken(index);
        assertEq(it.name(), "My Index");
        assertEq(it.symbol(), "MYX");
        assertEq(it.FACTORY(), address(factory));
        assertEq(it.methodology(), 0);
        assertEq(it.lastRebalance(), block.timestamp);
        (address[] memory tt, uint256[] memory uu) = it.components();
        assertEq(tt[0], address(a));
        assertEq(tt[1], address(b));
        assertEq(uu[0], 1e18);
        assertEq(uu[1], 1e8);
        assertEq(it.totalSupply(), 0);
    }

    function test_createIndex_addressCommitsToCreatorCompositionAndMethodology() public {
        (address[] memory t, uint256[] memory u) = _two();
        address mine = factory.predictIndexAddress(creator, "Same", "SAME", t, u, 0);
        address theirs = factory.predictIndexAddress(stranger, "Same", "SAME", t, u, 0);
        address otherRule = factory.predictIndexAddress(creator, "Same", "SAME", t, u, 1);
        u[1] = 2e8;
        address otherUnits = factory.predictIndexAddress(creator, "Same", "SAME", t, u, 0);
        assertTrue(mine != theirs);
        assertTrue(mine != otherUnits);
        assertTrue(mine != otherRule);
        assertTrue(theirs != otherUnits);

        u[1] = 1e8;
        vm.prank(creator);
        assertEq(factory.createIndex("Same", "SAME", t, u, 0), mine);
        vm.prank(stranger);
        assertEq(factory.createIndex("Same", "SAME", t, u, 0), theirs);
        assertEq(factory.creatorOf(theirs), stranger);
        assertEq(factory.allIndexesLength(), 2);
    }

    /// @dev LR-05: the address also commits to the token list, the name and the symbol, which no test varied on its
    ///      own: a salt without any one of them passed the suite.
    function test_LR05_addressCommitsToTheTokenListTheNameAndTheSymbol() public {
        _list(address(c));
        (address[] memory t, uint256[] memory u) = _two();
        address mine = factory.predictIndexAddress(creator, "Same", "SAME", t, u, 0);
        assertTrue(mine != factory.predictIndexAddress(creator, "Other", "SAME", t, u, 0), "the name");
        assertTrue(mine != factory.predictIndexAddress(creator, "Same", "OTHER", t, u, 0), "the symbol");

        address[] memory otherTokens = new address[](2);
        (otherTokens[0], otherTokens[1]) = (t[0], address(c));
        address other = factory.predictIndexAddress(creator, "Same", "SAME", otherTokens, u, 0);
        assertTrue(mine != other, "the token list, with the same units");
        (otherTokens[0], otherTokens[1]) = (t[1], t[0]);
        assertTrue(mine != factory.predictIndexAddress(creator, "Same", "SAME", otherTokens, u, 0), "and its order");

        // Both baskets can exist side by side, each at its predicted address.
        (otherTokens[0], otherTokens[1]) = (t[0], address(c));
        vm.startPrank(creator);
        assertEq(factory.createIndex("Same", "SAME", t, u, 0), mine);
        assertEq(factory.createIndex("Same", "SAME", otherTokens, u, 0), other);
        vm.stopPrank();
    }

    function test_createIndex_methodologyChecks() public {
        (address[] memory t, uint256[] memory u) = _two();
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidMethodology.selector, 2));
        factory.createIndex("X", "X", t, u, 2);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TooFewComponentsForCapped.selector, 2));
        factory.createIndex("X", "X", t, u, 1);

        (address[] memory five, uint256[] memory fiveUnits) = _listed(5);
        address[] memory four = new address[](4);
        uint256[] memory fourUnits = new uint256[](4);
        for (uint256 i = 0; i < 4; ++i) {
            four[i] = five[i];
            fourUnits[i] = fiveUnits[i];
        }
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TooFewComponentsForCapped.selector, 4));
        factory.createIndex("Capped", "CAP", four, fourUnits, 1);

        address capped = factory.createIndex("Capped", "CAP", five, fiveUnits, 1);
        assertEq(IndexToken(capped).methodology(), 1);
    }

    function test_createIndex_revertsDuplicateBySameCreator() public {
        (address[] memory t, uint256[] memory u) = _two();
        vm.prank(creator);
        address first = factory.createIndex("Same", "SAME", t, u, 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.IndexAlreadyExists.selector, first));
        factory.createIndex("Same", "SAME", t, u, 0);
    }

    function test_createIndex_delistingDoesNotAffectExisting() public {
        (address[] memory t, uint256[] memory u) = _two();
        address index = factory.createIndex("X", "X", t, u, 0);

        vm.prank(owner);
        factory.delist(address(a));

        (address[] memory tt,) = IndexToken(index).components();
        assertEq(tt[0], address(a));
        assertTrue(factory.isIndex(index));

        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(a)));
        factory.createIndex("Y", "Y", t, u, 0);
    }

    function test_createIndex_revertsEmptyName() public {
        (address[] memory t, uint256[] memory u) = _two();
        vm.expectRevert(IIndexFactory.EmptyString.selector);
        factory.createIndex("", "X", t, u, 0);
        vm.expectRevert(IIndexFactory.EmptyString.selector);
        factory.createIndex("X", "", t, u, 0);
    }

    function test_createIndex_revertsNoComponents() public {
        address[] memory t = new address[](0);
        uint256[] memory u = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidComponentCount.selector, 0));
        factory.createIndex("X", "X", t, u, 0);
    }

    function test_createIndex_revertsTooManyComponents() public {
        uint256 n = factory.MAX_COMPONENTS() + 1;
        address[] memory t = new address[](n);
        uint256[] memory u = new uint256[](n);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidComponentCount.selector, n));
        factory.createIndex("X", "X", t, u, 0);
    }

    function test_createIndex_maxComponentsOk() public {
        (address[] memory t, uint256[] memory u) = _listed(factory.MAX_COMPONENTS());
        address index = factory.createIndex("Big", "BIG", t, u, 1);
        assertEq(IndexToken(index).componentCount(), t.length);
    }

    function test_createIndex_revertsLengthMismatch() public {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](1);
        t[0] = address(a);
        t[1] = address(b);
        u[0] = 1;
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        factory.createIndex("X", "X", t, u, 0);
    }

    function test_createIndex_revertsNotWhitelisted() public {
        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(c);
        u[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(c)));
        factory.createIndex("X", "X", t, u, 0);

        IIndexFactory.TokenConfig memory config = market.config(address(c), 0);
        vm.prank(owner);
        factory.proposeListing(address(c), config);
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.TokenNotWhitelisted.selector, address(c)));
        factory.createIndex("X", "X", t, u, 0);
    }

    function test_createIndex_revertsDuplicate() public {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = address(a);
        t[1] = address(a);
        u[0] = 1;
        u[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.DuplicateToken.selector, address(a)));
        factory.createIndex("X", "X", t, u, 0);
    }

    function test_createIndex_revertsZeroUnits() public {
        (address[] memory t, uint256[] memory u) = _two();
        u[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidUnits.selector, address(b), 0));
        factory.createIndex("X", "X", t, u, 0);
    }

    function test_createIndex_revertsUnitsTooLarge() public {
        (address[] memory t, uint256[] memory u) = _two();
        u[0] = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(IIndexFactory.InvalidUnits.selector, address(a), u[0]));
        factory.createIndex("X", "X", t, u, 0);
        u[0] = type(uint96).max;
        factory.createIndex("X", "X", t, u, 0);
    }
}
