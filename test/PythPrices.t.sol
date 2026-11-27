// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {WeightedMath} from "../src/WeightedMath.sol";
import {Test} from "forge-std/Test.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {PythPrices} from "../src/PythPrices.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IPythPrices} from "../src/interfaces/IPythPrices.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockSharesOracle} from "./mocks/MockPricedTokens.sol";
import {OndoSValues} from "./fork/OndoSValues.sol";
import {PriceFeeds} from "../script/PriceFeeds.sol";

/// @notice The factory's price feeds and the reader it deploys. A feed is the owner's to propose, behind the listing
///         delay, the guardian's to cancel and anyone's to execute within the window; a factory without an oracle has
///         no feeds to set.
contract PythPricesTest is Test {
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");
    bytes32 constant FEED = keccak256("ETH/USD");

    MockPyth pyth;
    WeightedIndexFactory factory;
    MockERC20 token;

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new MockPyth();
        pyth.addFeed(FEED);
        factory = new WeightedIndexFactory(owner, guardian, address(pyth), address(new WeightedMath()), address(0));
        token = new MockERC20("Ether", "ETH", 18);
    }

    function _feed(bytes32 id, IPythPrices.FeedKind kind) internal pure returns (IPythPrices.PriceFeed memory) {
        return IPythPrices.PriceFeed({id: id, kind: kind});
    }

    /// @dev The factory deploys the reader with the chain's Pyth and itself, and the implementation every index clones
    ///      reads it; a factory built without Pyth has neither, and its implementation reads nothing.
    function test_theFactoryDeploysItsReader() public {
        PythPrices prices = PythPrices(factory.PRICES());
        assertEq(prices.PYTH(), address(pyth));
        assertEq(prices.FACTORY(), address(factory));
        assertEq(prices.SHARES_ORACLE(), address(0), "a factory built without Ondo's oracle reads no sValue");
        address sharesOracle = makeAddr("sharesOracle");
        WeightedIndexFactory withOndo =
            new WeightedIndexFactory(owner, guardian, address(pyth), address(new WeightedMath()), sharesOracle);
        assertEq(
            PythPrices(withOndo.PRICES()).SHARES_ORACLE(), sharesOracle, "one built with it hands it to its reader"
        );
        assertEq(WeightedHub(factory.IMPLEMENTATION()).PRICES(), address(prices));

        WeightedIndexFactory bare =
            new WeightedIndexFactory(owner, guardian, address(0), address(new WeightedMath()), address(0));
        assertEq(bare.PRICES(), address(0));
        assertEq(WeightedHub(bare.IMPLEMENTATION()).PRICES(), address(0));
        vm.prank(owner);
        vm.expectRevert(IWeightedIndexFactory.NoOracle.selector);
        bare.proposePriceFeed(address(token), _feed(FEED, IPythPrices.FeedKind.Token));

        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new PythPrices(address(0), address(0));
    }

    /// @dev A feed goes through the listing delay: proposed by the owner alone, executable by anyone from its eta and
    ///      within the window, recorded with its kind, and announced at each step.
    function test_aFeedIsSetBehindTheListingDelay() public {
        IPythPrices.PriceFeed memory feed = _feed(FEED, IPythPrices.FeedKind.Vault);
        vm.prank(stranger);
        vm.expectRevert();
        factory.proposePriceFeed(address(token), feed);

        uint256 eta = block.timestamp + factory.LISTING_DELAY();
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.PriceFeedProposed(address(token), FEED, IPythPrices.FeedKind.Vault, eta);
        vm.prank(owner);
        factory.proposePriceFeed(address(token), feed);
        (IPythPrices.PriceFeed memory pending, uint256 pendingEta) = factory.pendingPriceFeed(address(token));
        assertEq(pending.id, FEED);
        assertEq(uint8(pending.kind), uint8(IPythPrices.FeedKind.Vault));
        assertEq(pendingEta, eta);
        assertEq(uint8(factory.priceFeedOf(address(token)).kind), uint8(IPythPrices.FeedKind.None), "not yet");

        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.PriceFeedNotReady.selector, address(token), eta));
        factory.executePriceFeed(address(token));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.PriceFeedPending.selector, address(token), eta));
        factory.proposePriceFeed(address(token), feed);

        vm.warp(eta);
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.PriceFeedSet(address(token), FEED, IPythPrices.FeedKind.Vault);
        vm.prank(stranger);
        factory.executePriceFeed(address(token));
        IPythPrices.PriceFeed memory set = factory.priceFeedOf(address(token));
        assertEq(set.id, FEED);
        assertEq(uint8(set.kind), uint8(IPythPrices.FeedKind.Vault));
        (, pendingEta) = factory.pendingPriceFeed(address(token));
        assertEq(pendingEta, 0, "the proposal is spent");
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingPriceFeed.selector, address(token)));
        factory.executePriceFeed(address(token));
    }

    /// @dev A proposal left past its window expires: it executes no more, and a new one may replace it.
    function test_anUnexecutedFeedExpires() public {
        vm.prank(owner);
        factory.proposePriceFeed(address(token), _feed(FEED, IPythPrices.FeedKind.Token));
        uint256 deadline = block.timestamp + factory.LISTING_DELAY() + factory.PROPOSAL_WINDOW();
        vm.warp(deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedIndexFactory.PriceFeedExpired.selector, address(token), deadline)
        );
        factory.executePriceFeed(address(token));
        vm.prank(owner);
        factory.proposePriceFeed(address(token), _feed(FEED, IPythPrices.FeedKind.Multiplier));
    }

    /// @dev The owner or the guardian cancels a pending feed, nobody else, and only one that is pending.
    function test_theOwnerOrGuardianCancelsAFeed() public {
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingPriceFeed.selector, address(token)));
        vm.prank(guardian);
        factory.cancelPriceFeed(address(token));

        vm.prank(owner);
        factory.proposePriceFeed(address(token), _feed(FEED, IPythPrices.FeedKind.Token));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.Unauthorized.selector, stranger));
        factory.cancelPriceFeed(address(token));
        vm.expectEmit(address(factory));
        emit IWeightedIndexFactory.PriceFeedCancelled(address(token));
        vm.prank(guardian);
        factory.cancelPriceFeed(address(token));
        (, uint256 eta) = factory.pendingPriceFeed(address(token));
        assertEq(eta, 0);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.NoPendingPriceFeed.selector, address(token)));
        factory.executePriceFeed(address(token));
    }

    /// @dev A feed names an id, and kind `None`, which removes a feed, names none. The id is not asked of Pyth's
    ///      contract, which on a pull oracle knows a feed only once an update of it has been posted on the chain.
    function test_aFeedNamesAnIdAndNoneNamesNone() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidPriceFeed.selector, bytes32(0)));
        factory.proposePriceFeed(address(token), _feed(bytes32(0), IPythPrices.FeedKind.Token));
        vm.expectRevert(abi.encodeWithSelector(IWeightedIndexFactory.InvalidPriceFeed.selector, FEED));
        factory.proposePriceFeed(address(token), _feed(FEED, IPythPrices.FeedKind.None));
        factory.proposePriceFeed(address(token), _feed(bytes32(0), IPythPrices.FeedKind.None));
        // An id Pyth's contract has never stored a price for is taken: on a pull oracle a feed exists on a chain only
        // once someone has posted an update of it there, which a creation or a fill does itself.
        vm.stopPrank();
        bytes32 unposted = keccak256("a feed nobody has posted here");
        assertFalse(pyth.priceFeedExists(unposted));
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(owner);
        factory.proposePriceFeed(address(other), _feed(unposted, IPythPrices.FeedKind.Token));
        (IPythPrices.PriceFeed memory pending,) = factory.pendingPriceFeed(address(other));
        assertEq(pending.id, unposted);
    }

    /// @dev The fork suites' Ondo check (`test/fork/OndoSValues.sol`), run against mocks: of Ethereum's 344 legs of kind
    ///      `SharesOracle`, the one an oracle holds settled is valued at the stand-in price times its sValue, and one
    ///      held but changed a minute ago, one under a scheduled action and every one it does not hold are refused.
    function test_theForkSuitesOndoCheckIsChecked() public {
        MockSharesOracle ondo = new MockSharesOracle();
        (address[] memory tokens, IPythPrices.PriceFeed[] memory feeds) = PriceFeeds.table(1);
        address[3] memory picked;
        uint256 found = 0;
        for (uint256 i = 0; i < tokens.length && found < 3; ++i) {
            if (feeds[i].kind == IPythPrices.FeedKind.SharesOracle) picked[found++] = tokens[i];
        }
        ondo.set(picked[0], 10e18, block.timestamp - 1 days, 0, 0);
        ondo.set(picked[1], 2e18, block.timestamp - 1 minutes, 0, 0);
        ondo.set(picked[2], 1e18, block.timestamp - 1 days, block.timestamp + 1 days, 5e18);
        (uint256 valued, uint256 refused) = OndoSValues.check(1, address(pyth), address(ondo));
        assertEq(valued, 1, "the one held and settled");
        assertEq(refused, 343, "every other");
    }
}
