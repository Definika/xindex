// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IPythPrices} from "xindex/src/interfaces/IPythPrices.sol";
import {WeightedHub} from "xindex/src/WeightedHub.sol";
import {WeightedIndexFactory} from "xindex/src/WeightedIndexFactory.sol";
import {WeightedMath} from "xindex/src/WeightedMath.sol";
import {MintRequests} from "xindex/src/MintRequests.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
import {WeightedTest} from "xindex/test/WeightedTest.sol";
import {MockERC20} from "xindex/test/mocks/MockERC20.sol";
import {MockSwapRouter} from "xindex/test/mocks/MockSwapRouter.sol";
import {KeeperExecutor} from "../src/KeeperExecutor.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {MockTokenBridge} from "./mocks/MockTokenBridge.sol";
import {MockUpdatablePyth} from "./mocks/MockUpdatablePyth.sol";

/// @dev The executor on a factory with an oracle. Such an index accepts a fill only against Pyth prices of the last
///      minute, and a price reaches Pyth's contract only when someone posts it. So the keeper's fill carries Pyth's
///      signed update and posts it first, in the same transaction, for Pyth's fee. The index is created on its
///      weights at Pyth's prices; a week later ETH is up 20% at the router and at Pyth alike, so the fair fill sells
///      ETH and buys BTC and USD, as in `KeeperExecutorTest`.
contract KeeperExecutorPythTest is WeightedTest {
    uint256 constant ETH_UP = 2400;
    bytes32 constant ETH_FEED = keccak256("ETH/USD");
    bytes32 constant BTC_FEED = keccak256("BTC/USD");
    bytes32 constant USD_FEED = keccak256("USD/USD");

    MockUpdatablePyth pyth;
    MockERC20 usdc;
    MockERC20 usdt;
    MockSwapRouter router;
    WeightedHub index;
    KeeperExecutor executor;
    address execOwner = makeAddr("execOwner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new MockUpdatablePyth();
        factory = new WeightedIndexFactory(owner, guardian, address(pyth), address(new WeightedMath()), address(0));
        _approveCreator(creator);
        eth = new MockERC20("Ether", "ETH", 18);
        btc = new MockERC20("Bitcoin", "BTC", 8);
        usd = new MockERC20("Dollar", "USD", 6);
        _listAll();
        vm.startPrank(owner);
        factory.proposePriceFeed(address(eth), IPythPrices.PriceFeed({id: ETH_FEED, kind: IPythPrices.FeedKind.Token}));
        factory.proposePriceFeed(address(btc), IPythPrices.PriceFeed({id: BTC_FEED, kind: IPythPrices.FeedKind.Token}));
        factory.proposePriceFeed(address(usd), IPythPrices.PriceFeed({id: USD_FEED, kind: IPythPrices.FeedKind.Token}));
        vm.stopPrank();
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executePriceFeed(address(eth));
        factory.executePriceFeed(address(btc));
        factory.executePriceFeed(address(usd));

        // The creator posts Pyth's prices and creates the index on its weights at them.
        pyth.updatePriceFeeds{value: 21}(_update(ETH_PRICE));
        index = _create(_defaultSpecs());
        _issue(index, alice, 100e18);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        router = new MockSwapRouter();
        router.setPrice(address(eth), ETH_UP * 1e18);
        router.setPrice(address(btc), BTC_PRICE * 1e18);
        router.setPrice(address(usd), 1e18);
        router.setPrice(address(usdc), 1e18);
        eth.mint(address(router), 1000e18);
        btc.mint(address(router), 100e8);
        usd.mint(address(router), 1e12);
        usdc.mint(address(router), 1e12);
        executor = new KeeperExecutor(
            IV3SwapRouter(address(router)),
            address(usdc),
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(new MintRequests(address(factory), address(usdc), address(usdt)))),
            ITokenBridge(address(new MockTokenBridge())),
            execOwner,
            keeper,
            address(0),
            KeeperExecutor.LocalKind.None
        );
        usdc.mint(address(executor), 10_000e6);
    }

    /// @dev Pyth's update of the three feeds as of now, with ETH at `ethDollars`: one update a feed.
    function _update(uint256 ethDollars) internal view returns (bytes[] memory updates) {
        updates = new bytes[](3);
        updates[0] = _price(ETH_FEED, ethDollars);
        updates[1] = _price(BTC_FEED, BTC_PRICE);
        updates[2] = _price(USD_FEED, USD_PRICE);
    }

    function _price(bytes32 id, uint256 dollars) internal view returns (bytes memory) {
        return abi.encode(id, int64(int256(dollars * 1e8)), uint64(0), int32(-8), block.timestamp);
    }

    /// @dev Opens the index's auction and warps to its last second, a week and six hours after Pyth last heard a
    ///      price.
    function _open() internal {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION());
    }

    /// @dev The fair fill at ETH's new price, which the router and Pyth's update agree on, carrying `updates`.
    function _fill(bytes[] memory updates) internal view returns (KeeperExecutor.AuctionFill memory f) {
        bytes[] memory routes = new bytes[](3);
        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usdc));
        routes[1] = abi.encodePacked(address(btc), uint24(3000), address(eth), uint24(500), address(usdc));
        routes[2] = abi.encodePacked(address(usd), uint24(100), address(usdc));
        f = KeeperExecutor.AuctionFill({
            index: index,
            newUnits: _onWeights(index, _market(ETH_UP, BTC_PRICE, USD_PRICE)),
            routes: routes,
            maxAmountsIn: new uint256[](0),
            maxSupply: type(uint256).max,
            minUsdcDelta: type(int256).min,
            deadline: block.timestamp,
            pythUpdate: updates
        });
    }

    /// @dev Without an update the fill meets week-old prices and the index refuses it. With Pyth's update and exactly
    ///      its fee, the same fill settles: the update is posted first, the fee reaches Pyth's contract, and the
    ///      executor spends no ether of its own, even while it holds some.
    function test_aFillPostsPythsUpdateAndPaysItsFee() public {
        _open();
        KeeperExecutor.AuctionFill memory stale = _fill(new bytes[](0));
        vm.prank(keeper);
        vm.expectPartialRevert(IPythPrices.StalePrice.selector);
        executor.fill(stale);

        bytes[] memory updates = _update(ETH_UP);
        KeeperExecutor.AuctionFill memory fresh = _fill(updates);
        uint256 fee = pyth.getUpdateFee(updates);
        assertEq(fee, 21);
        uint256 held = address(pyth).balance;
        vm.deal(address(executor), 1 ether);
        vm.deal(keeper, fee);
        vm.prank(keeper);
        executor.fill{value: fee}(fresh);

        assertEq(index.rebalanceNonce(), 1, "the fill settled against the prices it posted");
        assertEq(pyth.getPriceUnsafe(ETH_FEED).price, int64(int256(ETH_UP * 1e8)), "Pyth holds the posted price");
        assertEq(address(pyth).balance, held + fee, "the fee reached Pyth's contract");
        assertEq(keeper.balance, 0);
        assertEq(address(executor).balance, 1 ether, "the executor spent none of its own ether");
    }

    /// @dev A fill carries exactly Pyth's fee for its update: a wei less or a wei more, and it stops before anything
    ///      is posted or traded.
    function test_aFillCarriesExactlyPythsFee() public {
        _open();
        bytes[] memory updates = _update(ETH_UP);
        KeeperExecutor.AuctionFill memory f = _fill(updates);
        uint256 fee = pyth.getUpdateFee(updates);
        vm.deal(keeper, 3 * fee);
        uint256[3] memory wrong = [uint256(0), fee - 1, fee + 1];
        for (uint256 i = 0; i < wrong.length; ++i) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongPythFee.selector, wrong[i], fee));
            executor.fill{value: wrong[i]}(f);
        }
        assertEq(index.rebalanceNonce(), 0);
        assertEq(pyth.getPriceUnsafe(ETH_FEED).price, int64(int256(ETH_PRICE * 1e8)), "nothing was posted");
    }
}
