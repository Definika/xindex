// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice The weighted factory: listings with price ids, creation, addresses and the guardian.
contract WeightedIndexFactoryTest is WeightedTest {
    function setUp() public {
        _deploy();
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_constructorWiresTheImplementation() public view {
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        assertEq(implementation.FACTORY(), address(factory));
        assertEq(implementation.PYTH(), address(pyth));
        assertEq(factory.PYTH(), address(pyth));
        assertEq(factory.owner(), owner);
        assertEq(factory.guardian(), guardian);
        assertEq(factory.MAX_COMPONENTS(), implementation.MAX_COMPONENTS());
        assertEq(factory.TOTAL_WEIGHT(), implementation.TOTAL_WEIGHT());
    }

    function test_constructorRefusesAPythWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotAContract.selector, address(0xbeef)));
        new WeightedIndexFactory(owner, guardian, address(0xbeef));
    }

    function test_constructorEmitsTheGuardian() public {
        vm.expectEmit();
        emit IWeightedIndexFactory.GuardianSet(address(0), guardian);
        WeightedIndexFactory deployed = new WeightedIndexFactory(owner, guardian, address(pyth));
        assertEq(deployed.guardian(), guardian);
    }

    function test_hubConstructorRefusesAZeroPyth() public {
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new WeightedHub(address(0), address(1));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new WeightedHub(address(1), address(0));
    }

    function test_aZeroGuardianIsNone() public {
        WeightedIndexFactory unguarded = new WeightedIndexFactory(owner, address(0), address(pyth));
        assertFalse(unguarded.isOwnerOrGuardian(address(0)));
        assertTrue(unguarded.isOwnerOrGuardian(owner));
    }

    // ---------------------------------------------------------------------
    // Listings
    // ---------------------------------------------------------------------

    function test_proposeListingRecordsThePriceIdAndDecimals() public {
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.ListingProposed(address(btc), block.timestamp + 2 days, BTC_ID, 8);
        vm.prank(owner);
        factory.proposeListing(address(btc), BTC_ID);

        (bytes32 id, uint8 decimals) = factory.pendingTerms(address(btc));
        assertEq(id, BTC_ID);
        assertEq(decimals, 8);
        assertEq(factory.listingEta(address(btc)), block.timestamp + 2 days);
        assertTrue(factory.listingPending(address(btc)));
        assertFalse(factory.isWhitelisted(address(btc)));
        assertEq(factory.priceIdOf(address(btc)), bytes32(0), "nothing in force before execution");
    }

    function test_proposeListingIsOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        factory.proposeListing(address(eth), ETH_ID);
    }

    function test_proposeListingRefusesAnAccountWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotAContract.selector, alice));
        vm.prank(owner);
        factory.proposeListing(alice, ETH_ID);
    }

    function test_proposeListingRefusesAZeroPriceId() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidPriceId.selector, address(eth)));
        vm.prank(owner);
        factory.proposeListing(address(eth), bytes32(0));
    }

    function test_proposeListingRefusesMoreThan18Decimals() public {
        MockERC20 wide = new MockERC20("Wide", "WIDE", 19);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidDecimals.selector, address(wide), 19));
        vm.prank(owner);
        factory.proposeListing(address(wide), ETH_ID);
    }

    function test_proposeListingRefusesAListedToken() public {
        _list(address(eth), ETH_ID);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.AlreadyListed.selector, address(eth)));
        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);
    }

    function test_proposeListingRefusesALiveListingButNotAnExpiredOne() public {
        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);
        uint256 eta = factory.listingEta(address(eth));

        vm.warp(eta + factory.PROPOSAL_WINDOW());
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.ListingPending.selector, address(eth), eta));
        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);

        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        assertFalse(factory.listingPending(address(eth)));
        vm.prank(owner);
        factory.proposeListing(address(eth), BTC_ID);
        (bytes32 id,) = factory.pendingTerms(address(eth));
        assertEq(id, BTC_ID);
    }

    function test_executeListingPutsTheTermsInForce() public {
        vm.prank(owner);
        factory.proposeListing(address(usd), USD_ID);
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.TokenTermsSet(address(usd), USD_ID, 6);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.TokenWhitelisted(address(usd), true);
        vm.prank(stranger);
        factory.executeListing(address(usd));

        assertTrue(factory.isWhitelisted(address(usd)));
        assertEq(factory.priceIdOf(address(usd)), USD_ID);
        assertEq(factory.decimalsOf(address(usd)), 6);
        assertEq(factory.listingEta(address(usd)), 0);
        (bytes32 id, uint8 decimals) = factory.pendingTerms(address(usd));
        assertEq(id, bytes32(0));
        assertEq(decimals, 0);
        assertEq(factory.whitelistedTokens().length, 1);
    }

    function test_executeListingKeepsTheDecimalsReadAtProposal() public {
        vm.prank(owner);
        factory.proposeListing(address(usd), USD_ID);
        usd.setDecimals(18);
        vm.warp(block.timestamp + 2 days);
        factory.executeListing(address(usd));
        assertEq(factory.decimalsOf(address(usd)), 6, "the proposal's figure, which the delay showed in public");
    }

    function test_executeListingChecksItsWindow() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingListing.selector, address(eth)));
        factory.executeListing(address(eth));

        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);
        uint256 eta = factory.listingEta(address(eth));

        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.ListingNotReady.selector, address(eth), eta));
        factory.executeListing(address(eth));

        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWeightedIndexFactory.ListingExpired.selector, address(eth), eta + factory.PROPOSAL_WINDOW()
            )
        );
        factory.executeListing(address(eth));
    }

    function test_executeListingOnTheLastSecondOfItsWindow() public {
        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);
        vm.warp(factory.listingEta(address(eth)) + factory.PROPOSAL_WINDOW());
        factory.executeListing(address(eth));
        assertTrue(factory.isWhitelisted(address(eth)));
    }

    function test_cancelListing() public {
        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);

        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        factory.cancelListing(address(eth));

        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.ListingCancelled(address(eth));
        vm.prank(guardian);
        factory.cancelListing(address(eth));
        assertEq(factory.listingEta(address(eth)), 0);
        (bytes32 id,) = factory.pendingTerms(address(eth));
        assertEq(id, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingListing.selector, address(eth)));
        vm.prank(owner);
        factory.cancelListing(address(eth));
    }

    function test_delistSwapsTheLastTokenIn() public {
        _listAll();
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.TokenWhitelisted(address(eth), false);
        vm.prank(guardian);
        factory.delist(address(eth));

        address[] memory listed = factory.whitelistedTokens();
        assertEq(listed.length, 2);
        assertEq(listed[0], address(usd));
        assertEq(listed[1], address(btc));
        assertFalse(factory.isWhitelisted(address(eth)));
        assertEq(factory.priceIdOf(address(eth)), ETH_ID, "delisting keeps the terms");

        vm.prank(owner);
        factory.delist(address(btc));
        listed = factory.whitelistedTokens();
        assertEq(listed.length, 1);
        assertEq(listed[0], address(usd));
    }

    /// @dev LR-05: delisting the token that swap-and-pop moved must still work.
    function test_LR05_aTokenMovedBySwapAndPopCanStillBeDelisted() public {
        _listAll(); // [eth, btc, usd]
        vm.startPrank(guardian);
        factory.delist(address(eth)); // moves usd into eth's slot: [usd, btc]
        factory.delist(address(usd)); // usd is now first, and btc moves into its slot: [btc]
        vm.stopPrank();
        address[] memory listed = factory.whitelistedTokens();
        assertEq(listed.length, 1);
        assertEq(listed[0], address(btc));
        assertFalse(factory.isWhitelisted(address(usd)));

        vm.prank(guardian);
        factory.delist(address(btc));
        assertEq(factory.whitelistedTokens().length, 0);
    }

    /// @dev CR-I33. At exactly `listingEta + PROPOSAL_WINDOW` a listing still executes, so the view has to call it
    ///      pending there, and stop a second later.
    function test_CRI33_aListingIsPendingAtTheLastMomentItCanExecute() public {
        vm.prank(owner);
        factory.proposeListing(address(eth), ETH_ID);
        uint256 deadline = factory.listingEta(address(eth)) + factory.PROPOSAL_WINDOW();

        uint256 snapshot = vm.snapshotState();
        vm.warp(deadline + 1);
        assertFalse(factory.listingPending(address(eth)), "a second later it is dead");
        vm.revertToState(snapshot);

        vm.warp(deadline);
        assertTrue(factory.listingPending(address(eth)), "the last executable moment is still pending");
        factory.executeListing(address(eth));
        assertTrue(factory.isWhitelisted(address(eth)), "and it does execute");
    }

    function test_delistChecksTheCallerAndTheToken() public {
        _list(address(eth), ETH_ID);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        factory.delist(address(eth));

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NotWhitelisted.selector, address(btc)));
        vm.prank(owner);
        factory.delist(address(btc));
    }

    /// @dev A relisting can carry a new price id, and only indexes created after it read it: every index copies its
    ///      ids at creation, so no key can repoint an existing index's prices.
    function test_aRelistingReachesOnlyNewIndexes() public {
        _listAll();
        WeightedHub before = _create(_defaultSpecs());

        vm.prank(owner);
        factory.delist(address(eth));
        bytes32 newId = keccak256("ETH/USD, another feed");
        _list(address(eth), newId);
        assertEq(factory.priceIdOf(address(eth)), newId);

        vm.prank(alice);
        WeightedHub later = WeightedHub(factory.createIndex("Weighted", "WGT", _defaultSpecs(), _params()));

        (, bytes32[] memory oldIds,) = before.componentTerms();
        (, bytes32[] memory newIds,) = later.componentTerms();
        assertEq(oldIds[0], ETH_ID);
        assertEq(newIds[0], newId);
    }

    // ---------------------------------------------------------------------
    // Creation
    // ---------------------------------------------------------------------

    function test_createIndexCopiesEverything() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        address predicted = factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params());

        IWeightedHub.ComponentInit[] memory inits = new IWeightedHub.ComponentInit[](3);
        inits[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 5000, ETH_ID, 18);
        inits[1] = IWeightedHub.ComponentInit(address(btc), BTC_UNITS, 3000, BTC_ID, 8);
        inits[2] = IWeightedHub.ComponentInit(address(usd), USD_UNITS, 2000, USD_ID, 6);
        IWeightedHub.Config memory cfg = IWeightedHub.Config({
            creatorFeeBps: 0,
            platformFeeBps: 0,
            referralShareBps: 0,
            creatorStreamingBps: 0,
            platformStreamingBps: 0,
            rebalanceInterval: 7 days
        });
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.IndexCreated(predicted, creator, "Weighted", "WGT", inits, cfg, true);
        WeightedHub index = _create(specs);

        assertEq(address(index), predicted);
        assertTrue(factory.isIndex(address(index)));
        assertEq(factory.creatorOf(address(index)), creator);
        assertEq(factory.allIndexesLength(), 1);
        assertEq(factory.allIndexes(0), address(index));
        assertEq(index.name(), "Weighted");
        assertEq(index.symbol(), "WGT");
        assertEq(index.lastRebalance(), block.timestamp);

        (address[] memory tokens, uint256[] memory units) = index.components();
        (uint256[] memory weights, bytes32[] memory ids, uint8[] memory decimals) = index.componentTerms();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(tokens[i], inits[i].token);
            assertEq(units[i], inits[i].units);
            assertEq(weights[i], inits[i].weight);
            assertEq(ids[i], inits[i].priceId);
            assertEq(decimals[i], inits[i].decimals);
        }
    }

    function test_createIndexRefusesEmptyStrings() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        vm.expectRevert(IWeightedIndexFactory.EmptyString.selector);
        factory.createIndex("", "WGT", specs, _params());
        vm.expectRevert(IWeightedIndexFactory.EmptyString.selector);
        factory.createIndex("Weighted", "", specs, _params());
    }

    function test_createIndexRefusesAnEmptyOrOversizedBasket() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidComponentCount.selector, 0));
        factory.createIndex("Weighted", "WGT", new IWeightedIndexFactory.ComponentSpec[](0), _params());

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidComponentCount.selector, 101));
        factory.createIndex("Weighted", "WGT", new IWeightedIndexFactory.ComponentSpec[](101), _params());
    }

    function test_createIndexRefusesAnUnlistedOrDelistedToken() public {
        _list(address(eth), ETH_ID);
        _list(address(btc), BTC_ID);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.TokenNotWhitelisted.selector, address(usd)));
        factory.createIndex("Weighted", "WGT", specs, _params());

        _list(address(usd), USD_ID);
        vm.prank(owner);
        factory.delist(address(btc));
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.TokenNotWhitelisted.selector, address(btc)));
        factory.createIndex("Weighted", "WGT", specs, _params());
    }

    function test_DA09_createIndexChecksTheUnits() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        uint256 min = factory.MIN_RAW_UNITS();
        uint256 max = factory.MAX_UNITS();

        specs[1].units = min - 1;
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.UnitsOutOfRange.selector, address(btc), min - 1));
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs[1].units = max + 1;
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.UnitsOutOfRange.selector, address(btc), max + 1));
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs[1].units = min;
        specs[2].units = max;
        factory.createIndex("Weighted", "WGT", specs, _params());
    }

    function test_createIndexChecksTheWeights() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();

        specs[2].weight = 0;
        specs[0].weight = 7000;
        vm.expectRevert(IWeightedIndexFactory.InvalidWeights.selector);
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs = _defaultSpecs();
        specs[0].weight = 10_001;
        vm.expectRevert(IWeightedIndexFactory.InvalidWeights.selector);
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs = _defaultSpecs();
        specs[2].weight = 1999;
        vm.expectRevert(IWeightedIndexFactory.InvalidWeights.selector);
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs[2].weight = 2001;
        vm.expectRevert(IWeightedIndexFactory.InvalidWeights.selector);
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs[2].weight = 2000;
        factory.createIndex("Weighted", "WGT", specs, _params());
    }

    function test_createIndexRefusesADuplicate() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        specs[2] = _spec(address(eth), 2000, ETH_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.DuplicateToken.selector, address(eth)));
        factory.createIndex("Weighted", "WGT", specs, _params());
    }

    /// @dev One component alone is always on its weight, so an index needs two (V5-L2).
    function test_aSingleComponentIsRefused() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](1);
        specs[0] = _spec(address(btc), 10_000, BTC_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidComponentCount.selector, 1));
        factory.createIndex("Weighted", "WGT", specs, _params());
        assertEq(factory.MIN_COMPONENTS(), WeightedHub(factory.IMPLEMENTATION()).MIN_COMPONENTS());
    }

    /// @dev V5-M1: two tokens listed on one feed, such as two wrappers of one coin, may each go in an index, never both
    ///      in one: Pyth fills only the first of two equal ids, so every fill of that index would revert.
    function test_V5M1_twoComponentsOnOneFeedAreRefused() public {
        _listAll();
        MockERC20 twin = new MockERC20("Staked Ether", "STETH", 18);
        _list(address(twin), ETH_ID);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        specs[2] = _spec(address(twin), 2000, ETH_UNITS);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.DuplicatePriceId.selector, address(twin)));
        factory.createIndex("Weighted", "WGT", specs, _params());

        specs[0] = _spec(address(twin), 5000, ETH_UNITS);
        specs[2] = _spec(address(usd), 2000, USD_UNITS);
        WeightedHub index = _create(specs);
        assertEq(index.componentTokens()[0], address(twin));
    }

    /// @dev V5-M1, the mechanism: an update fills the first requested slot with its id, so a second slot asking for
    ///      the same id is never filled, whatever the executor brings, and the parse reverts. The mock does what Pyth's
    ///      `_parseSingleMerkleUpdate` does; an earlier mock resolved each slot on its own and hid this.
    function test_V5M1_pythNeverFillsOneIdTwice() public {
        bytes[] memory data = new bytes[](2);
        data[0] = pyth.update(ETH_ID, ETH_PRICE, 0, EXPO, 100, 99);
        data[1] = pyth.update(ETH_ID, ETH_PRICE, 0, EXPO, 100, 99);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ETH_ID;
        ids[1] = ETH_ID;
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        pyth.parsePriceFeedUpdatesUnique(data, ids, 100, 111);
        ids[1] = BTC_ID;
        data[1] = pyth.update(BTC_ID, BTC_PRICE, 0, EXPO, 100, 99);
        assertEq(pyth.parsePriceFeedUpdatesUnique(data, ids, 100, 111).length, 2);
    }

    function test_createIndexRefusesTheSameIndexTwice() public {
        _listAll();
        WeightedHub index = _create(_defaultSpecs());
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.IndexAlreadyExists.selector, address(index)));
        vm.prank(creator);
        factory.createIndex("Weighted", "WGT", specs, _params());
    }

    /// @dev Each field of the salt, varied alone, moves the address: the creator, the name, the symbol, and each
    ///      component's token, weight, units, price id and decimals (LR-05's lesson, for the weighted salt).
    function test_LR05_theAddressCommitsToEveryField() public {
        _listAll();
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        _list(address(other), ETH_ID);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        address base = factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params());

        assertTrue(factory.predictIndexAddress(alice, "Weighted", "WGT", specs, _params()) != base, "creator");
        assertTrue(factory.predictIndexAddress(creator, "Weighted2", "WGT", specs, _params()) != base, "name");
        assertTrue(factory.predictIndexAddress(creator, "Weighted", "WGT2", specs, _params()) != base, "symbol");

        specs[0].token = address(other);
        assertTrue(factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()) != base, "token");

        specs = _defaultSpecs();
        specs[0].weight = 4999;
        specs[1].weight = 3001;
        assertTrue(factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()) != base, "weight");

        specs = _defaultSpecs();
        specs[0].units = ETH_UNITS + 1;
        assertTrue(factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()) != base, "units");

        specs = _defaultSpecs();
        assertEq(factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()), base, "unchanged");

        // The same token relisted under another price id moves the address.
        vm.prank(owner);
        factory.delist(address(eth));
        _list(address(eth), keccak256("ETH/USD, another feed"));
        assertTrue(factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()) != base, "price id");

        // And under its old id but other decimals, as a token that changed them would carry.
        vm.prank(owner);
        factory.delist(address(eth));
        eth.setDecimals(17);
        _list(address(eth), ETH_ID);
        assertTrue(factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()) != base, "decimals");
        eth.setDecimals(18);
        vm.prank(owner);
        factory.delist(address(eth));
        _list(address(eth), ETH_ID);
        assertEq(
            factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()), base, "back to the same terms"
        );
    }

    function test_theCloneIsTheImplementations() public {
        _listAll();
        WeightedHub index = _create(_defaultSpecs());
        bytes memory expected = address(Clones.clone(factory.IMPLEMENTATION())).code;
        assertEq(address(index).code, expected);
    }

    function test_aHundredComponents() public {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](100);
        for (uint256 i = 0; i < 100; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            _list(address(token), keccak256(abi.encode(i)));
            specs[i] = _spec(address(token), 100, 1e18);
        }
        WeightedHub index = _create(specs);
        assertEq(index.componentCount(), 100);
    }

    // ---------------------------------------------------------------------
    // Guardian
    // ---------------------------------------------------------------------

    function test_guardianChangeRunsItsDelay() public {
        address next = makeAddr("next");
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.GuardianProposed(next, block.timestamp + 7 days);
        vm.prank(owner);
        factory.proposeGuardian(next);
        assertEq(factory.pendingGuardian(), next);
        assertTrue(factory.guardianChangePending());

        vm.expectRevert(
            abi.encodeWithSelector(IWeightedIndexFactory.GuardianChangeNotReady.selector, block.timestamp + 7 days)
        );
        factory.executeGuardianChange();

        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.GuardianSet(guardian, next);
        factory.executeGuardianChange();
        assertEq(factory.guardian(), next);
        assertEq(factory.pendingGuardian(), address(0));
        assertEq(factory.pendingGuardianEta(), 0);
        assertFalse(factory.guardianChangePending());
    }

    /// @dev LR-05: the last moment of the window still executes, as the listing window's last moment does.
    function test_LR05_aGuardianChangeExecutesAtTheLastMomentOfItsWindow() public {
        address next = makeAddr("next guardian");
        vm.prank(owner);
        factory.proposeGuardian(next);
        vm.warp(factory.pendingGuardianEta() + factory.PROPOSAL_WINDOW());
        factory.executeGuardianChange();
        assertEq(factory.guardian(), next);
    }

    function test_DA16_guardianChangeExpires() public {
        vm.prank(owner);
        factory.proposeGuardian(alice);
        uint256 eta = factory.pendingGuardianEta();
        vm.warp(eta + factory.PROPOSAL_WINDOW() + 1);
        assertFalse(factory.guardianChangePending());
        vm.expectRevert(
            abi.encodeWithSelector(
                IWeightedIndexFactory.GuardianChangeExpired.selector, eta + factory.PROPOSAL_WINDOW()
            )
        );
        factory.executeGuardianChange();
    }

    function test_XA60_aNewProposalReplacesThePendingOne() public {
        vm.prank(owner);
        factory.proposeGuardian(alice);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.GuardianChangeCancelled(alice);
        vm.prank(owner);
        factory.proposeGuardian(stranger);
        assertEq(factory.pendingGuardian(), stranger);
    }

    function test_proposeGuardianIsOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        factory.proposeGuardian(alice);
    }

    function test_XA61_whoMayCancelAGuardianChange() public {
        vm.expectRevert(IWeightedIndexFactory.NoPendingGuardianChange.selector);
        factory.cancelGuardianChange();
        vm.expectRevert(IWeightedIndexFactory.NoPendingGuardianChange.selector);
        factory.executeGuardianChange();

        // The guardian cannot block its own replacement.
        vm.prank(owner);
        factory.proposeGuardian(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, guardian));
        vm.prank(guardian);
        factory.cancelGuardianChange();
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        factory.cancelGuardianChange();
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.GuardianChangeCancelled(alice);
        vm.prank(owner);
        factory.cancelGuardianChange();

        // It can cancel its own removal.
        vm.prank(owner);
        factory.proposeGuardian(address(0));
        vm.prank(guardian);
        factory.cancelGuardianChange();
        assertEq(factory.pendingGuardianEta(), 0);

        // Without a guardian, nobody but the owner cancels a removal.
        WeightedIndexFactory unguarded = new WeightedIndexFactory(owner, address(0), address(pyth));
        vm.prank(owner);
        unguarded.proposeGuardian(address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, address(0)));
        vm.prank(address(0));
        unguarded.cancelGuardianChange();
    }

    function test_removingTheGuardian() public {
        vm.prank(owner);
        factory.proposeGuardian(address(0));
        vm.warp(block.timestamp + 7 days);
        factory.executeGuardianChange();
        assertEq(factory.guardian(), address(0));
        assertFalse(factory.isOwnerOrGuardian(address(0)));
        assertFalse(factory.isOwnerOrGuardian(guardian));
    }

    function test_renounceIsDisabled() public {
        vm.expectRevert(IWeightedIndexFactory.RenounceDisabled.selector);
        vm.prank(owner);
        factory.renounceOwnership();
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(owner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), owner);
        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
        assertTrue(factory.isOwnerOrGuardian(alice));
        assertFalse(factory.isOwnerOrGuardian(owner));
    }
    // ---------------------------------------------------------------------
    // Params, fee policy and creators
    // ---------------------------------------------------------------------

    function _p(uint16 creatorFeeBps, uint16 maxPlatform, uint32 interval)
        internal
        pure
        returns (IWeightedIndexFactory.IndexParams memory p)
    {
        p = _params();
        p.creatorFeeBps = creatorFeeBps;
        p.maxPlatformFeeBps = maxPlatform;
        p.rebalanceInterval = interval;
    }

    function test_theFeeConstantsAgreeWithTheHub() public view {
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        assertEq(factory.MIN_REBALANCE_INTERVAL(), implementation.MIN_REBALANCE_INTERVAL());

        assertEq(factory.MAX_CREATOR_FEE_BPS(), 100);
        assertEq(factory.MAX_PLATFORM_FEE_BPS(), 25);
        assertEq(factory.MIN_REBALANCE_INTERVAL(), 7 days);
        assertEq(factory.MAX_REBALANCE_INTERVAL(), 91 days);
        assertEq(factory.platformFeeBps() | factory.referralShareBps() | factory.creationFee(), 0, "no policy at first");
        assertEq(factory.platformFeeRecipient(), address(0));
    }

    function test_createIndexChecksTheParams() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.CreatorFeeTooHigh.selector, 101));
        factory.createIndex("Weighted", "WGT", specs, _p(101, 25, 7 days));
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.IntervalOutOfRange.selector, 7 days - 1));
        factory.createIndex("Weighted", "WGT", specs, _p(0, 25, 7 days - 1));
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.IntervalOutOfRange.selector, 91 days + 1));
        factory.createIndex("Weighted", "WGT", specs, _p(0, 25, 91 days + 1));

        // The policy charges more than the creator accepts: the quote the creator saw no longer holds.
        vm.prank(owner);
        factory.setFeePolicy(25, 0, 0, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.PlatformFeeTooHigh.selector, 25, 24));
        factory.createIndex("Weighted", "WGT", specs, _p(0, 24, 7 days));
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.PlatformFeeTooHigh.selector, 25, 24));
        factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _p(0, 24, 7 days));

        WeightedHub a = _create(specs, _p(100, 25, 7 days));
        WeightedHub b = _create(specs, _p(0, 25, 91 days));
        assertEq(a.config().creatorFeeBps, 100);
        assertEq(a.config().platformFeeBps, 25);
        assertEq(b.config().rebalanceInterval, 91 days);
    }

    function test_setFeePolicyIsTheOwnersWithinTheCaps() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFeePolicy(25, 0, 5000, alice, 1 ether);

        vm.startPrank(owner);
        vm.expectRevert(IWeightedIndexFactory.InvalidFeePolicy.selector);
        factory.setFeePolicy(26, 0, 5000, alice, 0);
        vm.expectRevert(IWeightedIndexFactory.InvalidFeePolicy.selector);
        factory.setFeePolicy(25, 0, 10_001, alice, 0);
        vm.expectRevert(IWeightedIndexFactory.InvalidFeePolicy.selector);
        factory.setFeePolicy(25, 0, 5000, address(0), 0);
        vm.expectRevert(IWeightedIndexFactory.InvalidFeePolicy.selector);
        factory.setFeePolicy(25, 0, 5000, address(factory), 0);
        vm.stopPrank();
        _listAll();
        WeightedHub index = _create(_defaultSpecs());
        vm.prank(owner);
        vm.expectRevert(IWeightedIndexFactory.InvalidFeePolicy.selector);
        factory.setFeePolicy(25, 0, 5000, address(index), 0);

        vm.prank(owner);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.FeePolicySet(25, 0, 10_000, alice, 1 ether);
        factory.setFeePolicy(25, 0, 10_000, alice, 1 ether);
        assertEq(factory.platformFeeBps(), 25);
        assertEq(factory.referralShareBps(), 10_000);
        assertEq(factory.platformFeeRecipient(), alice);
        assertEq(factory.creationFee(), 1 ether);
        (bool allowed, address c, address p) = factory.feeTerms(address(index), stranger);
        assertTrue(allowed, "an open index issues to anyone");
        assertEq(c, creator);
        assertEq(p, alice);
    }

    function test_anIndexKeepsTheRatesOfItsCreation() public {
        _listAll();
        WeightedHub before = _create(_defaultSpecs());
        vm.prank(owner);
        factory.setFeePolicy(25, 0, 5000, alice, 0);
        IWeightedIndexFactory.IndexParams memory p = _params();
        p.listed = false;
        address predicted = factory.predictIndexAddress(creator, "Weighted", "WGT", _defaultSpecs(), p);
        IWeightedHub.Config memory cfg = IWeightedHub.Config({
            creatorFeeBps: 0,
            platformFeeBps: 25,
            referralShareBps: 5000,
            creatorStreamingBps: 0,
            platformStreamingBps: 0,
            rebalanceInterval: 7 days
        });
        IWeightedHub.ComponentInit[] memory inits = new IWeightedHub.ComponentInit[](3);
        inits[0] = IWeightedHub.ComponentInit(address(eth), ETH_UNITS, 5000, ETH_ID, 18);
        inits[1] = IWeightedHub.ComponentInit(address(btc), BTC_UNITS, 3000, BTC_ID, 8);
        inits[2] = IWeightedHub.ComponentInit(address(usd), USD_UNITS, 2000, USD_ID, 6);
        vm.prank(creator);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.IndexCreated(predicted, creator, "Weighted", "WGT", inits, cfg, false);
        WeightedHub later = WeightedHub(factory.createIndex("Weighted", "WGT", _defaultSpecs(), p));
        assertEq(address(later), predicted);
        assertTrue(address(before) != address(later), "the policy is part of the address");
        assertEq(before.config().platformFeeBps, 0);
        assertEq(before.config().referralShareBps, 0);
        assertEq(later.config().platformFeeBps, 25);
        assertEq(later.config().referralShareBps, 5000);
    }

    function test_theCreationFeeIsForwardedWhole() public {
        _listAll();
        vm.prank(owner);
        factory.setFeePolicy(0, 0, 0, alice, 0.01 ether);
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.WrongCreationFee.selector, 0, 0.01 ether));
        factory.createIndex("Weighted", "WGT", specs, _params());
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.WrongCreationFee.selector, 0.02 ether, 0.01 ether));
        factory.createIndex{value: 0.02 ether}("Weighted", "WGT", specs, _params());
        vm.prank(creator);
        factory.createIndex{value: 0.01 ether}("Weighted", "WGT", specs, _params());
        assertEq(alice.balance, 0.01 ether, "the recipient has it");
        assertEq(address(factory).balance, 0, "the factory holds no ether");
        assertEq(creator.balance, 0.99 ether);

        Refuser refuser = new Refuser();
        vm.prank(owner);
        factory.setFeePolicy(0, 0, 0, address(refuser), 0.01 ether);
        vm.prank(creator);
        vm.expectRevert(Errors.FailedCall.selector);
        factory.createIndex{value: 0.01 ether}("Weighted2", "WGT", specs, _params());
    }

    function test_theCreatorRoleCanBeHandedOn() public {
        _listAll();
        WeightedHub index = _create(_defaultSpecs());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.transferCreator(address(index), stranger);
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, alice));
        factory.transferCreator(alice, stranger);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        factory.transferCreator(address(index), address(0));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(factory)));
        factory.transferCreator(address(index), address(factory));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        factory.transferCreator(address(index), address(index));
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.CreatorTransferred(address(index), creator, alice);
        factory.transferCreator(address(index), alice);
        vm.stopPrank();
        assertEq(factory.creatorOf(address(index)), alice);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, creator));
        factory.setAllowedMinter(address(index), stranger, true);
        vm.startPrank(alice);
        factory.setAllowedMinter(address(index), stranger, true);
        assertTrue(factory.isAllowedMinter(address(index), stranger));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, stranger));
        factory.setAllowedMinter(stranger, stranger, true);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, stranger));
        factory.openMinting(stranger);
        vm.stopPrank();
    }

    function test_LR05_theAddressCommitsToTheConfig() public {
        _listAll();
        IWeightedIndexFactory.ComponentSpec[] memory specs = _defaultSpecs();
        address base = factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params());
        assertTrue(
            factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _p(1, 25, 7 days)) != base, "creator fee"
        );
        assertTrue(
            factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _p(0, 25, 8 days)) != base, "interval"
        );
        IWeightedIndexFactory.IndexParams memory p = _params();
        p.listed = false;
        p.maxPlatformFeeBps = 0;
        p.gated = true;
        assertEq(
            factory.predictIndexAddress(creator, "Weighted", "WGT", specs, p),
            base,
            "the listing, the gate and the accepted maximum are not terms of the index"
        );

        vm.prank(owner);
        factory.setFeePolicy(1, 0, 0, alice, 0);
        address withPlatform = factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params());
        assertTrue(withPlatform != base, "platform fee");
        vm.prank(owner);
        factory.setFeePolicy(1, 0, 1, alice, 0);
        address withReferral = factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params());
        assertTrue(withReferral != withPlatform, "referral share");
        vm.prank(owner);
        factory.setFeePolicy(1, 0, 1, stranger, 1 ether);
        assertEq(
            factory.predictIndexAddress(creator, "Weighted", "WGT", specs, _params()),
            withReferral,
            "the recipient and the creation fee are not terms of the index"
        );
    }
}

/// @dev Holds no `receive`, so ether sent to it fails.
contract Refuser {}
