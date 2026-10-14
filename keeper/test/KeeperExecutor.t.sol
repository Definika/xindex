// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IWeightedHub} from "xindex/src/interfaces/IWeightedHub.sol";
import {PythStructs} from "xindex/src/interfaces/pyth/PythStructs.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {WeightedHub} from "xindex/src/WeightedHub.sol";
import {WeightedTest} from "xindex/test/WeightedTest.sol";
import {MockERC20} from "xindex/test/mocks/MockERC20.sol";
import {MockPyth} from "xindex/test/mocks/MockPyth.sol";
import {MockSwapRouter} from "xindex/test/mocks/MockSwapRouter.sol";
import {KeeperExecutor} from "../src/KeeperExecutor.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";

/// @dev The executor against the real hub and factory, MockPyth and a fixed-price router. ETH rises 20% after creation,
///      so the index sells ETH and buys BTC and USD. The router trades at the same prices Pyth reports, so each fill's
///      float change is exactly what its quotes say, which pins the direction of every swap and the inventory rule.
contract KeeperExecutorTest is WeightedTest {
    int64 constant ETH_UP = 2400e8;

    MockERC20 usdc;
    MockSwapRouter router;
    WeightedHub index;
    KeeperExecutor executor;
    address execOwner = makeAddr("execOwner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        _deploy();
        _listAll();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        router = new MockSwapRouter();
        router.setPrice(address(eth), 2400e18);
        router.setPrice(address(btc), 60_000e18);
        router.setPrice(address(usd), 1e18);
        router.setPrice(address(usdc), 1e18);
        eth.mint(address(router), 1000e18);
        btc.mint(address(router), 100e8);
        usd.mint(address(router), 1e12);
        usdc.mint(address(router), 1e12);

        index = _create(_defaultSpecs());
        _issue(index, alice, 100e18);
        executor = _executor(address(usdc));
        usdc.mint(address(executor), 10_000e6);
    }

    function _executor(address float) internal returns (KeeperExecutor) {
        return new KeeperExecutor(
            IV3SwapRouter(address(router)), float, IWeightedIndexFactory(address(factory)), execOwner, keeper
        );
    }

    /// @dev Opens the auction and moves `into` seconds into it.
    function _open(uint256 into) internal {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + into);
    }

    function _routes() internal view returns (bytes[] memory routes) {
        routes = new bytes[](3);
        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usdc));
        routes[1] = abi.encodePacked(address(btc), uint24(3000), address(eth), uint24(500), address(usdc));
        routes[2] = abi.encodePacked(address(usd), uint24(100), address(usdc));
    }

    function _preview() internal view returns (uint256[] memory out, uint256[] memory in_) {
        (,, out, in_) = index.previewRebalance(_structs3(ETH_UP, BTC_PRICE, USD_PRICE));
    }

    function _update() internal view returns (bytes[] memory) {
        return _updates(index, _ids3(), _prices3(ETH_UP, BTC_PRICE, USD_PRICE));
    }

    function _fill(KeeperExecutor ex, bytes[] memory routes, uint256[] memory maxIn, int256 minDelta)
        internal
        returns (int256 delta, uint256 gasUsed)
    {
        bytes[] memory update = _update();
        uint256 deadline = block.timestamp;
        vm.prank(keeper);
        return ex.fill(index, update, routes, maxIn, minDelta, deadline);
    }

    function _int(uint256 x) internal pure returns (int256) {
        return int256(x);
    }

    function _allow(address token, uint256 amount) internal {
        vm.prank(execOwner);
        executor.setStockAllowance(token, amount);
    }

    /// @dev The float change of selling ETH and buying BTC and USD, each through its route, at the router's prices.
    function _expected(uint256[] memory out, uint256[] memory in_) internal view returns (int256) {
        return _int(router.quoteOut(address(eth), address(usdc), out[0]))
            - _int(router.quoteIn(address(usdc), address(btc), in_[1]))
            - _int(router.quoteIn(address(usdc), address(usd), in_[2]));
    }

    // ---------------------------------------------------------------------
    // Fills
    // ---------------------------------------------------------------------

    function test_fillAtMuMinSellsAndBuysAndKeepsTheGain() public {
        _open(index.AUCTION_DURATION());
        (uint256[] memory out, uint256[] memory in_) = _preview();
        assertGt(out[0], 0, "ETH goes out");
        assertGt(in_[1], 0, "BTC comes in");
        assertGt(in_[2], 0, "USD comes in");
        int256 expected = _expected(out, in_);
        uint256 before = usdc.balanceOf(address(executor));

        (int256 delta, uint256 gasUsed) = _fill(executor, _routes(), in_, type(int256).min);

        assertEq(delta, expected, "the float moves by the routes' quotes");
        assertEq(_int(usdc.balanceOf(address(executor))) - _int(before), delta, "the returned delta is the float's");
        assertGt(delta, 0, "at MU_MIN the executor keeps about 2%");
        assertGt(gasUsed, 0, "gas used is reported");
        assertEq(eth.balanceOf(address(executor)), 0, "every ETH sold");
        assertEq(btc.balanceOf(address(executor)), 0, "every BTC delivered");
        assertEq(usd.balanceOf(address(executor)), 0, "every USD delivered");
        assertEq(eth.allowance(address(executor), address(router)), 0, "the sale used its approval up");
        assertEq(index.rebalanceNonce(), 1, "the index rebalanced");
    }

    function test_fillAtMuMaxReturnsTheCost() public {
        _open(0);
        (uint256[] memory out, uint256[] memory in_) = _preview();
        int256 expected = _expected(out, in_);
        (int256 delta,) = _fill(executor, _routes(), in_, type(int256).min);
        assertEq(delta, expected, "the float moves by the routes' quotes");
        assertLt(delta, 0, "at MU_MAX the executor pays about 2%");
    }

    function test_minUsdcDeltaIsAFloor() public {
        _open(0);
        (uint256[] memory out, uint256[] memory in_) = _preview();
        int256 expected = _expected(out, in_);
        uint256 snapshot = vm.snapshotState();
        (int256 delta,) = _fill(executor, _routes(), in_, expected);
        assertEq(delta, expected, "a floor equal to the outcome passes");
        vm.revertToState(snapshot);

        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        uint256 deadline = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.TooCostly.selector, expected, expected + 1));
        vm.prank(keeper);
        executor.fill(index, update, routes, in_, expected + 1, deadline);
    }

    function test_unroutedOutIsKeptAsInventory() public {
        _open(index.AUCTION_DURATION());
        (uint256[] memory out, uint256[] memory in_) = _preview();
        bytes[] memory routes = _routes();
        routes[0] = "";
        (int256 delta,) = _fill(executor, routes, in_, type(int256).min);
        assertEq(eth.balanceOf(address(executor)), out[0], "the ETH the index sold stays in stock");
        int256 bought = _int(router.quoteIn(address(usdc), address(btc), in_[1]))
            + _int(router.quoteIn(address(usdc), address(usd), in_[2]));
        assertEq(delta, -bought, "only the buys touch the float");
    }

    function test_unroutedInComesFromInventory() public {
        _open(index.AUCTION_DURATION());
        (uint256[] memory out, uint256[] memory in_) = _preview();
        btc.mint(address(executor), in_[1] + 5);
        _allow(address(btc), in_[1]);
        bytes[] memory routes = _routes();
        routes[1] = "";
        (int256 delta,) = _fill(executor, routes, in_, type(int256).min);
        assertEq(btc.balanceOf(address(executor)), 5, "the BTC came out of stock");
        assertEq(executor.stockAllowance(address(btc)), 0, "the delivery spent the allowance");
        assertEq(
            delta,
            _int(router.quoteOut(address(eth), address(usdc), out[0]))
                - _int(router.quoteIn(address(usdc), address(usd), in_[2])),
            "no BTC was bought"
        );
    }

    function test_routedInUsesInventoryFirst() public {
        _open(index.AUCTION_DURATION());
        (uint256[] memory out, uint256[] memory in_) = _preview();
        uint256 held = in_[1] / 2;
        btc.mint(address(executor), held);
        _allow(address(btc), held);
        (int256 delta,) = _fill(executor, _routes(), in_, type(int256).min);
        assertEq(btc.balanceOf(address(executor)), 0, "stock and purchase together delivered");
        assertEq(
            delta,
            _int(router.quoteOut(address(eth), address(usdc), out[0]))
                - _int(router.quoteIn(address(usdc), address(btc), in_[1] - held))
                - _int(router.quoteIn(address(usdc), address(usd), in_[2])),
            "only the shortfall was bought"
        );
    }

    function test_unroutedInWithoutStockRevertsNoRoute() public {
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        routes[1] = "";
        uint256 deadline = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(btc)));
        vm.prank(keeper);
        executor.fill(index, update, routes, in_, type(int256).min, deadline);
    }

    function test_maxAmountsInBindsTheSettlement() public {
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        uint256[] memory maxIn = new uint256[](3);
        (maxIn[0], maxIn[1], maxIn[2]) = (in_[0], in_[1] - 1, in_[2]);
        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        uint256 deadline = block.timestamp;
        vm.expectRevert(
            abi.encodeWithSelector(IWeightedHub.RebalanceMovedOn.selector, address(btc), in_[1], in_[1] - 1)
        );
        vm.prank(keeper);
        executor.fill(index, update, routes, maxIn, type(int256).min, deadline);
    }

    function test_pythFeeIsForwarded() public {
        pyth.setFee(1);
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        uint256 deadline = block.timestamp;
        vm.deal(keeper, 3);
        vm.expectRevert(MockPyth.InsufficientFee.selector);
        vm.prank(keeper);
        executor.fill(index, update, routes, in_, type(int256).min, deadline);

        vm.prank(keeper);
        executor.fill{value: 3}(index, update, routes, in_, type(int256).min, deadline);
        assertEq(address(pyth).balance, 3, "the whole fee reached Pyth");
        assertEq(address(executor).balance, 0, "the executor kept no ether");
    }

    // ---------------------------------------------------------------------
    // Stock allowance (CF-1)
    // ---------------------------------------------------------------------

    /// @dev The exploit of CF-1: the keeper key creates an index of its own whose BTC leg is far below its weight, issues
    ///      its shares and fills it, serving BTC from the executor's stock with no route and no floor. Without an
    ///      allowance the stock cannot leave, whichever factory index asks for it.
    function test_CF1_aKeeperOwnedIndexCannotTakeTheStock() public {
        IWeightedIndexFactory.ComponentSpec[] memory specs = new IWeightedIndexFactory.ComponentSpec[](2);
        specs[0] = _spec(address(eth), 1, 1e18);
        specs[1] = _spec(address(btc), 9999, factory.MIN_RAW_UNITS());
        vm.prank(keeper);
        WeightedHub own = WeightedHub(factory.createIndex("Own", "OWN", specs));
        _issue(own, keeper, 1e18);
        btc.mint(address(executor), 1e8);

        vm.warp(own.lastRebalance() + own.MIN_REBALANCE_INTERVAL());
        vm.prank(keeper);
        own.startRebalance(0);
        (uint256 eta,) = own.pendingRebalance();
        vm.warp(eta);
        PythStructs.Price[] memory prices = new PythStructs.Price[](2);
        prices[0] = PythStructs.Price({price: ETH_PRICE, conf: 0, expo: EXPO, publishTime: 0});
        prices[1] = PythStructs.Price({price: BTC_PRICE, conf: 0, expo: EXPO, publishTime: 0});
        (,,, uint256[] memory in_) = own.previewRebalance(prices);
        assertGt(in_[1], 0, "the keeper's index asks for BTC");

        bytes32[] memory ids = new bytes32[](2);
        (ids[0], ids[1]) = (ETH_ID, BTC_ID);
        int64[] memory px = new int64[](2);
        (px[0], px[1]) = (ETH_PRICE, BTC_PRICE);
        bytes[] memory update = _updates(own, ids, px);
        bytes[] memory routes = new bytes[](2);
        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usdc));
        uint256 deadline = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(btc)));
        vm.prank(keeper);
        executor.fill(own, update, routes, in_, type(int256).min, deadline);
        assertEq(btc.balanceOf(address(executor)), 1e8, "the stock stayed");
    }

    function test_CF1_stockLeavesOnlyWithinTheAllowance() public {
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        btc.mint(address(executor), in_[1] + 100);
        bytes[] memory routes = _routes();
        routes[1] = "";

        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(btc)),
            keeper,
            address(index),
            routes,
            block.timestamp
        );
        _allow(address(btc), in_[1] - 1);
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(btc)),
            keeper,
            address(index),
            routes,
            block.timestamp
        );

        _allow(address(btc), in_[1] + 7);
        _fill(executor, routes, in_, type(int256).min);
        assertEq(btc.balanceOf(address(executor)), 100, "exactly what the index needed left the stock");
        assertEq(executor.stockAllowance(address(btc)), 7, "and was spent from the allowance");
    }

    function test_CF1_aRoutedLegBuysWhatTheAllowanceDoesNotCover() public {
        _open(index.AUCTION_DURATION());
        (uint256[] memory out, uint256[] memory in_) = _preview();
        btc.mint(address(executor), in_[1]);
        uint256 allowed = in_[1] / 3;
        _allow(address(btc), allowed);
        (int256 delta,) = _fill(executor, _routes(), in_, type(int256).min);
        assertEq(btc.balanceOf(address(executor)), in_[1] - allowed, "only the allowance came out of stock");
        assertEq(executor.stockAllowance(address(btc)), 0, "the allowance is spent");
        assertEq(
            delta,
            _int(router.quoteOut(address(eth), address(usdc), out[0]))
                - _int(router.quoteIn(address(usdc), address(btc), in_[1] - allowed))
                - _int(router.quoteIn(address(usdc), address(usd), in_[2])),
            "the rest of the BTC was bought from the float"
        );
    }

    function test_onlyTheOwnerSetsStockAllowances() public {
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, keeper));
        vm.prank(keeper);
        executor.setStockAllowance(address(btc), 1);

        vm.expectEmit(address(executor));
        emit KeeperExecutor.StockAllowanceSet(address(btc), 5e7);
        vm.prank(execOwner);
        executor.setStockAllowance(address(btc), 5e7);
        assertEq(executor.stockAllowance(address(btc)), 5e7);
    }

    // ---------------------------------------------------------------------
    // A USDC component: out of and into the float itself
    // ---------------------------------------------------------------------

    function test_usdcComponentComesInFromTheFloat() public {
        KeeperExecutor ex = _executor(address(usd));
        usd.mint(address(ex), 10_000e6);
        _open(index.AUCTION_DURATION());
        (uint256[] memory out, uint256[] memory in_) = _preview();
        bytes[] memory routes = new bytes[](3);
        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usd));
        routes[1] = abi.encodePacked(address(btc), uint24(3000), address(eth), uint24(500), address(usd));
        (int256 delta,) = _fill(ex, routes, in_, type(int256).min);
        assertEq(
            delta,
            _int(router.quoteOut(address(eth), address(usd), out[0]))
                - _int(router.quoteIn(address(usd), address(btc), in_[1])) - _int(in_[2]),
            "the USD leg is paid from the float, unswapped"
        );
    }

    function test_usdcComponentGoesOutIntoTheFloat() public {
        KeeperExecutor ex = _executor(address(usd));
        usd.mint(address(ex), 10_000e6);
        router.setPrice(address(usd), 1.25e18);
        router.setPrice(address(eth), 2000e18);
        _open(index.AUCTION_DURATION());
        (,, uint256[] memory out, uint256[] memory in_) =
            index.previewRebalance(_structs3(ETH_PRICE, BTC_PRICE, 1.25e8));
        assertGt(out[2], 0, "USD goes out");
        bytes[] memory routes = new bytes[](3);
        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usd));
        routes[1] = abi.encodePacked(address(btc), uint24(3000), address(eth), uint24(500), address(usd));
        bytes[] memory update = _updates(index, _ids3(), _prices3(ETH_PRICE, BTC_PRICE, 1.25e8));
        uint256 deadline = block.timestamp;
        vm.prank(keeper);
        (int256 delta,) = ex.fill(index, update, routes, in_, type(int256).min, deadline);
        assertEq(
            delta,
            _int(out[2]) - _int(router.quoteIn(address(usd), address(eth), in_[0]))
                - _int(router.quoteIn(address(usd), address(btc), in_[1])),
            "the USD the index sold lands in the float, unswapped"
        );
    }

    function test_aRouteOnTheUsdcComponentIsRefused() public {
        KeeperExecutor ex = _executor(address(usd));
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        bytes[] memory routes = new bytes[](3);
        routes[2] = abi.encodePacked(address(usd), uint24(100), address(usd));
        bytes[] memory update = _update();
        uint256 deadline = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usd)));
        vm.prank(keeper);
        ex.fill(index, update, routes, in_, type(int256).min, deadline);
    }

    // ---------------------------------------------------------------------
    // Refusals
    // ---------------------------------------------------------------------

    function _expectFillReverts(
        bytes memory err,
        address caller,
        address target,
        bytes[] memory routes,
        uint256 deadline
    ) internal {
        (, uint256[] memory in_) = _preview();
        bytes[] memory update = _update();
        vm.expectRevert(err);
        vm.prank(caller);
        executor.fill(IWeightedHub(target), update, routes, in_, type(int256).min, deadline);
    }

    function test_onlyTheKeeperFills() public {
        _open(index.AUCTION_DURATION());
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, stranger),
            stranger,
            address(index),
            _routes(),
            block.timestamp
        );
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, execOwner),
            execOwner,
            address(index),
            _routes(),
            block.timestamp
        );
    }

    function test_aFillPastItsDeadlineReverts() public {
        _open(index.AUCTION_DURATION());
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.Expired.selector, block.timestamp - 1),
            keeper,
            address(index),
            _routes(),
            block.timestamp - 1
        );
    }

    function test_onlyFactoryIndexesAreFilled() public {
        _open(index.AUCTION_DURATION());
        address fake = makeAddr("fake");
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NotIndex.selector, fake), keeper, fake, _routes(), block.timestamp
        );
    }

    function test_oneRoutePerComponent() public {
        _open(index.AUCTION_DURATION());
        bytes[] memory two = new bytes[](2);
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.LengthMismatch.selector), keeper, address(index), two, block.timestamp
        );
    }

    function test_badRoutesAreRefused() public {
        _open(index.AUCTION_DURATION());
        bytes memory err = abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(eth));
        bytes[] memory routes = _routes();

        routes[0] = abi.encodePacked(address(btc), uint24(500), address(usdc));
        _expectFillReverts(err, keeper, address(index), routes, block.timestamp);

        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usd));
        _expectFillReverts(err, keeper, address(index), routes, block.timestamp);

        // Right first and last tokens, but a stray byte between them: only the shape check refuses it.
        routes[0] = abi.encodePacked(address(eth), uint24(500), uint8(0), address(usdc));
        _expectFillReverts(err, keeper, address(index), routes, block.timestamp);
    }

    function test_theCallbackAnswersOnlyItsOwnFill() public {
        uint256[] memory amounts = new uint256[](3);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.UnexpectedCaller.selector, stranger));
        vm.prank(stranger);
        executor.onXindexRebalance(amounts, amounts, abi.encode(_routes()));

        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.UnexpectedCaller.selector, address(index)));
        vm.prank(address(index));
        executor.onXindexRebalance(amounts, amounts, abi.encode(_routes()));
    }

    // ---------------------------------------------------------------------
    // The owner
    // ---------------------------------------------------------------------

    function test_theOwnerRotatesTheKeeper() public {
        address next = makeAddr("nextKeeper");
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, keeper));
        vm.prank(keeper);
        executor.setKeeper(next);

        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        vm.prank(execOwner);
        executor.setKeeper(address(0));

        vm.expectEmit(address(executor));
        emit KeeperExecutor.KeeperSet(keeper, next);
        vm.prank(execOwner);
        executor.setKeeper(next);
        assertEq(executor.keeper(), next);

        _open(index.AUCTION_DURATION());
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, keeper),
            keeper,
            address(index),
            _routes(),
            block.timestamp
        );
        (, uint256[] memory in_) = _preview();
        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        uint256 deadline = block.timestamp;
        vm.prank(next);
        executor.fill(index, update, routes, in_, type(int256).min, deadline);
        assertEq(index.rebalanceNonce(), 1, "the new keeper filled");
    }

    function test_onlyTheOwnerWithdraws() public {
        address to = makeAddr("treasury");
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, keeper));
        vm.prank(keeper);
        executor.withdraw(address(usdc), to, 1);

        vm.prank(execOwner);
        executor.withdraw(address(usdc), to, 4000e6);
        assertEq(usdc.balanceOf(to), 4000e6);
        assertEq(usdc.balanceOf(address(executor)), 6000e6);
    }

    function test_constructor() public {
        assertEq(address(executor.ROUTER()), address(router));
        assertEq(executor.USDC(), address(usdc));
        assertEq(address(executor.FACTORY()), address(factory));
        assertEq(executor.OWNER(), execOwner);
        assertEq(executor.keeper(), keeper);
        assertEq(usdc.allowance(address(executor), address(router)), type(uint256).max, "USDC approved once");
    }

    function test_constructorRefusesZeroAddresses() public {
        IV3SwapRouter r = IV3SwapRouter(address(router));
        IWeightedIndexFactory f = IWeightedIndexFactory(address(factory));
        address u = address(usdc);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(IV3SwapRouter(address(0)), u, f, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, address(0), f, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, IWeightedIndexFactory(address(0)), execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, address(0), keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, execOwner, address(0));
    }
}
