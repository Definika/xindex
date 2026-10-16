// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IWeightedHub} from "xindex/src/interfaces/IWeightedHub.sol";
import {PythStructs} from "xindex/src/interfaces/pyth/PythStructs.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {WeightedHub} from "xindex/src/WeightedHub.sol";
import {WeightedIndexFactory} from "xindex/src/WeightedIndexFactory.sol";
import {MintRequests} from "xindex/src/MintRequests.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
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
    MockERC20 usdt;
    MockSwapRouter router;
    MintRequests requests;
    WeightedHub index;
    KeeperExecutor executor;
    address execOwner = makeAddr("execOwner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        _deploy();
        _listAll();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        router = new MockSwapRouter();
        router.setPrice(address(eth), 2400e18);
        router.setPrice(address(btc), 60_000e18);
        router.setPrice(address(usd), 1e18);
        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(usdt), 1e18);
        eth.mint(address(router), 1000e18);
        btc.mint(address(router), 100e8);
        usd.mint(address(router), 1e12);
        usdc.mint(address(router), 1e12);
        usdt.mint(address(router), 1e12);
        requests = new MintRequests(address(factory), address(usdc), address(usdt));

        index = _create(_defaultSpecs());
        _issue(index, alice, 100e18);
        executor = _executor(address(usdc));
        usdc.mint(address(executor), 10_000e6);
    }

    function _executor(address float) internal returns (KeeperExecutor) {
        return new KeeperExecutor(
            IV3SwapRouter(address(router)),
            float,
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(requests)),
            execOwner,
            keeper
        );
    }

    /// @dev `who` escrows `amount` of `stable` for at least `minShares` shares of the index, a day away.
    function _requestMint(address who, address stable, uint256 amount, uint256 minShares) internal returns (uint256) {
        MockERC20(stable).mint(who, amount);
        vm.startPrank(who);
        MockERC20(stable).approve(address(requests), amount);
        uint256 id = requests.requestMint(address(index), stable, amount, minShares, block.timestamp + 1 days);
        vm.stopPrank();
        return id;
    }

    /// @dev `who` escrows `shares` of the index for at least `minOut` of `stable`, a day away.
    function _requestRedeem(address who, uint256 shares, address stable, uint256 minOut) internal returns (uint256) {
        vm.startPrank(who);
        index.approve(address(requests), shares);
        uint256 id = requests.requestRedeem(address(index), shares, stable, minOut, block.timestamp + 1 days);
        vm.stopPrank();
        return id;
    }

    function _stableRoute(address stable) internal view returns (bytes memory) {
        return stable == address(usdc) ? bytes("") : abi.encodePacked(stable, uint24(100), address(usdc));
    }

    /// @dev What the basket for `shares` costs through the routes, at the router's prices.
    function _basketCost(uint256 shares) internal view returns (uint256 cost) {
        uint256[] memory need = index.previewIssue(shares);
        cost = router.quoteIn(address(usdc), address(eth), need[0])
            + router.quoteIn(address(usdc), address(btc), need[1])
            + router.quoteIn(address(usdc), address(usd), need[2]);
    }

    /// @dev What the basket of `shares` sells for through the routes, at the router's prices.
    function _basketProceeds(uint256 shares) internal view returns (uint256 proceeds) {
        uint256[] memory got = index.previewRedeem(shares);
        proceeds = router.quoteOut(address(eth), address(usdc), got[0])
            + router.quoteOut(address(btc), address(usdc), got[1])
            + router.quoteOut(address(usd), address(usdc), got[2]);
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
        WeightedHub own = WeightedHub(factory.createIndex("Own", "OWN", specs, _params()));
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
        assertEq(address(executor.REQUESTS()), address(requests));
        assertEq(executor.OWNER(), execOwner);
        assertEq(executor.keeper(), keeper);
        assertEq(usdc.allowance(address(executor), address(router)), type(uint256).max, "USDC approved once");
    }

    function test_constructorRefusesZeroAddresses() public {
        IV3SwapRouter r = IV3SwapRouter(address(router));
        IWeightedIndexFactory f = IWeightedIndexFactory(address(factory));
        IMintRequests q = IMintRequests(address(requests));
        address u = address(usdc);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(IV3SwapRouter(address(0)), u, f, q, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, address(0), f, q, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, IWeightedIndexFactory(address(0)), q, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, IMintRequests(address(0)), execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, q, address(0), keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, q, execOwner, address(0));
    }

    /// @dev A request escrow for another factory's indexes would let the keeper fill requests the factory check never
    ///      saw; the executor refuses it at construction.
    function test_constructorRefusesRequestsOnAnotherFactory() public {
        WeightedIndexFactory other = new WeightedIndexFactory(owner, guardian, address(pyth));
        MintRequests elsewhere = new MintRequests(address(other), address(usdc), address(usdt));
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.RequestsMismatch.selector, address(elsewhere)));
        new KeeperExecutor(
            IV3SwapRouter(address(router)),
            address(usdc),
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(elsewhere)),
            execOwner,
            keeper
        );
    }

    // ---------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------

    function test_fillMintBuysTheBasketIssuesAndTakesTheEscrow() public {
        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        uint256 cost = _basketCost(2e18);
        uint256 before = usdc.balanceOf(address(executor));

        vm.prank(keeper);
        (int256 delta, uint256 gasUsed) = executor.fillMint(id, 2e18, _routes(), "", type(int256).min, block.timestamp);

        assertEq(delta, _int(250e6) - _int(cost), "the escrow less the basket's cost");
        assertEq(_int(usdc.balanceOf(address(executor))) - _int(before), delta);
        assertGt(delta, 0, "a request above the basket's cost pays");
        assertGt(gasUsed, 0);
        assertEq(index.balanceOf(stranger), 2e18, "the requester got its shares");
        assertEq(index.balanceOf(address(executor)), 0, "and the executor kept none");
        assertEq(eth.balanceOf(address(executor)), 0, "nothing of the basket is left over");
        assertFalse(requests.getRequest(id).open);
        assertEq(usdc.balanceOf(address(requests)), 0, "the escrow left with the request");
    }

    function test_fillMintSellsAnEscrowedUsdtIntoTheFloat() public {
        uint256 id = _requestMint(stranger, address(usdt), 250e6, 2e18);
        uint256 cost = _basketCost(2e18);
        vm.prank(keeper);
        (int256 delta,) =
            executor.fillMint(id, 2e18, _routes(), _stableRoute(address(usdt)), type(int256).min, block.timestamp);
        assertEq(delta, _int(router.quoteOut(address(usdt), address(usdc), 250e6)) - _int(cost));
        assertEq(usdt.balanceOf(address(executor)), 0, "the USDT was sold");
        assertEq(index.balanceOf(stranger), 2e18);

        // Without the stablecoin's route, or with one for USDC, the fill is refused.
        id = _requestMint(stranger, address(usdt), 250e6, 2e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdt)));
        executor.fillMint(id, 2e18, _routes(), "", type(int256).min, block.timestamp);
        id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdc)));
        executor.fillMint(id, 2e18, _routes(), _stableRoute(address(usdt)), type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdc)));
        executor.fillMint(id, 2e18, _routes(), hex"1234", type(int256).min, block.timestamp);
    }

    function test_fillMintDeliversFromStockFirstWithinTheAllowance() public {
        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        uint256[] memory need = index.previewIssue(2e18);
        eth.mint(address(executor), need[0]);
        _allow(address(eth), need[0] / 2);
        bytes[] memory routes = _routes();
        uint256 cost = router.quoteIn(address(usdc), address(eth), need[0] - need[0] / 2)
            + router.quoteIn(address(usdc), address(btc), need[1])
            + router.quoteIn(address(usdc), address(usd), need[2]);

        vm.prank(keeper);
        (int256 delta,) = executor.fillMint(id, 2e18, routes, "", type(int256).min, block.timestamp);
        assertEq(delta, _int(250e6) - _int(cost), "half the ETH came from stock, the rest was bought");
        assertEq(eth.balanceOf(address(executor)), need[0] - need[0] / 2, "the stock beyond the allowance stayed");
        assertEq(executor.stockAllowance(address(eth)), 0, "the delivery spent the allowance");

        // With no route for a coin the stock cannot cover, nothing can be delivered.
        id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        routes[0] = "";
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(eth)));
        executor.fillMint(id, 2e18, routes, "", type(int256).min, block.timestamp);
    }

    function test_fillMintChecksTheCall() public {
        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, stranger));
        vm.prank(stranger);
        executor.fillMint(id, 2e18, _routes(), "", type(int256).min, block.timestamp);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.Expired.selector, block.timestamp - 1));
        executor.fillMint(id, 2e18, _routes(), "", type(int256).min, block.timestamp - 1);

        bytes[] memory two = new bytes[](2);
        vm.prank(keeper);
        vm.expectRevert(KeeperExecutor.LengthMismatch.selector);
        executor.fillMint(id, 2e18, two, "", type(int256).min, block.timestamp);

        // The floor binds: the escrow less the cost is the most the fill can promise.
        int256 cost = _int(_basketCost(2e18));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(KeeperExecutor.TooCostly.selector, _int(250e6) - cost, _int(250e6) - cost + 1)
        );
        executor.fillMint(id, 2e18, _routes(), "", _int(250e6) - cost + 1, block.timestamp);

        // Fewer shares than the limit: the escrow refuses the delivery.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 2e18 - 1, 2e18));
        executor.fillMint(id, 2e18 - 1, _routes(), "", type(int256).min, block.timestamp);

        // A redeem request is the other side.
        _issue(index, stranger, 1e18);
        uint256 redeemId = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongSide.selector, redeemId));
        executor.fillMint(redeemId, 1e18, _routes(), "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongSide.selector, id));
        executor.fillRedeem(id, 90e6, _routes(), "", type(int256).min, block.timestamp);
    }

    function test_fillRedeemPaysTheStableRedeemsAndSellsTheBasket() public {
        _issue(index, stranger, 1e18);
        uint256 id = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        uint256 proceeds = _basketProceeds(1e18);
        uint256 before = usdc.balanceOf(address(executor));

        vm.prank(keeper);
        (int256 delta, uint256 gasUsed) =
            executor.fillRedeem(id, 90e6, _routes(), "", type(int256).min, block.timestamp);

        assertEq(delta, _int(proceeds) - _int(90e6), "the basket's proceeds less what the requester was paid");
        assertEq(_int(usdc.balanceOf(address(executor))) - _int(before), delta);
        assertGt(delta, 0, "a request below the basket's worth pays");
        assertGt(gasUsed, 0);
        assertEq(usdc.balanceOf(stranger), 90e6, "the requester got its stable");
        assertEq(index.balanceOf(address(executor)), 0, "the shares were redeemed");
        assertEq(index.balanceOf(stranger), 0);
        assertEq(eth.balanceOf(address(executor)), 0, "every component sold");
        assertFalse(requests.getRequest(id).open);
    }

    function test_fillRedeemBuysUsdtWithTheFloatAndKeepsUnroutedCoins() public {
        _issue(index, stranger, 1e18);
        uint256 id = _requestRedeem(stranger, 1e18, address(usdt), 90e6);
        uint256[] memory got = index.previewRedeem(1e18);
        bytes[] memory routes = _routes();
        routes[1] = "";
        uint256 proceeds =
            router.quoteOut(address(eth), address(usdc), got[0]) + router.quoteOut(address(usd), address(usdc), got[2]);
        uint256 paid = router.quoteIn(address(usdc), address(usdt), 90e6);

        vm.prank(keeper);
        (int256 delta,) =
            executor.fillRedeem(id, 90e6, routes, _stableRoute(address(usdt)), type(int256).min, block.timestamp);
        assertEq(delta, _int(proceeds) - _int(paid));
        assertEq(usdt.balanceOf(stranger), 90e6);
        assertEq(btc.balanceOf(address(executor)), got[1], "the unrouted BTC is stock now");

        // The floor binds here too, and a stablecoin needs its route.
        _issue(index, stranger, 1e18);
        id = _requestRedeem(stranger, 1e18, address(usdt), 90e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdt)));
        executor.fillRedeem(id, 90e6, routes, "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(KeeperExecutor.TooCostly.selector, _int(proceeds) - _int(paid), _int(proceeds))
        );
        executor.fillRedeem(id, 90e6, routes, _stableRoute(address(usdt)), _int(proceeds), block.timestamp);
    }

    function test_fillRedeemChecksTheCall() public {
        _issue(index, stranger, 1e18);
        uint256 id = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, stranger));
        vm.prank(stranger);
        executor.fillRedeem(id, 90e6, _routes(), "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.Expired.selector, block.timestamp - 1));
        executor.fillRedeem(id, 90e6, _routes(), "", type(int256).min, block.timestamp - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 90e6 - 1, 90e6));
        executor.fillRedeem(id, 90e6 - 1, _routes(), "", type(int256).min, block.timestamp);
    }
}
