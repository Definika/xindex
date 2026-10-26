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
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {MockTokenBridge} from "./mocks/MockTokenBridge.sol";

/// @dev The executor against the real hub and factory, MockPyth and a fixed-price router. ETH rises 20% after creation,
///      so the index sells ETH and buys BTC and USD. The router trades at the same prices Pyth reports, so each fill's
///      float change is exactly what its quotes say, which pins the direction of every swap and the inventory rule.
contract KeeperExecutorTest is WeightedTest {
    int64 constant ETH_UP = 2400e8;
    /// @dev A supply bound that binds nothing, for the fills whose test is about something else.
    uint256 constant ANY_SUPPLY = type(uint256).max;

    MockERC20 usdc;
    MockERC20 usdt;
    MockSwapRouter router;
    MintRequests requests;
    MockTokenBridge bridge;
    WeightedHub index;
    KeeperExecutor executor;
    address execOwner = makeAddr("execOwner");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");

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
        bridge = new MockTokenBridge();

        index = _create(_defaultSpecs());
        _issue(index, alice, 100e18);
        executor = _executor(address(usdc));
        usdc.mint(address(executor), 10_000e6);
        vm.prank(execOwner);
        executor.setRequestUsdcAllowance(type(uint256).max);
    }

    function _executor(address float) internal returns (KeeperExecutor) {
        return new KeeperExecutor(
            IV3SwapRouter(address(router)),
            float,
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(requests)),
            ITokenBridge(address(bridge)),
            execOwner,
            keeper
        );
    }

    /// @dev `who` escrows `amount` of `stable` for at least `minShares` shares of the index, a day away.
    /// @dev A request fill at the index's nonce `reqNonce` (no settlement in most tests), with no leg or stable limit.
    uint256 reqNonce;

    function _req(
        uint256 id,
        uint256 amount,
        bytes[] memory routes,
        bytes memory stableRoute,
        int256 minUsdcDelta,
        uint256 deadline
    ) internal view returns (KeeperExecutor.RequestFill memory) {
        return KeeperExecutor.RequestFill({
            id: id,
            amount: amount,
            routes: routes,
            legLimits: new uint256[](0),
            stableRoute: stableRoute,
            stableLimit: 0,
            expectedNonce: reqNonce,
            minUsdcDelta: minUsdcDelta,
            deadline: deadline
        });
    }

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
        bytes[] memory live = pyth.liveUpdates(index, 0);
        vm.prank(stranger);
        index.startRebalance(0, live);
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
        return ex.fill(index, update, routes, maxIn, ANY_SUPPLY, minDelta, deadline);
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
        executor.fill(index, update, routes, in_, ANY_SUPPLY, expected + 1, deadline);
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
        executor.fill(index, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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
        executor.fill(index, update, routes, maxIn, ANY_SUPPLY, type(int256).min, deadline);
    }

    /// @dev XS-4: the bot bounds the supply at its quote plus SUPPLY_TOLERANCE_BPS (10). A griefer's issue of 0.11% of
    ///      the supply ahead of the fill would have the hub revert `RebalanceMovedOn` after Pyth's parse; the
    ///      executor refuses it on the supply alone, before the hub is called. Pyth's fee is set and left unpaid, so a
    ///      fill that reached the hub would die inside the parse instead: the revert names the order.
    function test_XS4_aSupplyAboveTheQuoteRevertsBeforeTheHub() public {
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        uint256 supply = index.totalSupply();
        uint256 maxSupply = (supply * 10_010 + 9999) / 10_000;
        uint256[] memory maxIn = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            maxIn[i] = (in_[i] * 10_010 + 9999) / 10_000;
        }
        pyth.setFee(1);
        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        uint256 deadline = block.timestamp;

        // Unmoved, the bounded fill settles.
        uint256 snapshot = vm.snapshotState();
        vm.deal(keeper, 3);
        vm.prank(keeper);
        executor.fill{value: 3}(index, update, routes, maxIn, maxSupply, type(int256).min, deadline);
        assertEq(index.rebalanceNonce(), 1, "a fill within its bounds settles");
        vm.revertToState(snapshot);

        _issue(index, stranger, supply * 11 / 10_000);
        uint256 griefed = index.totalSupply();
        assertGt(griefed, maxSupply, "the issue is past the tolerance");
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.SupplyMovedOn.selector, griefed, maxSupply));
        vm.prank(keeper);
        executor.fill(index, update, routes, maxIn, maxSupply, type(int256).min, deadline);
    }

    function test_pythFeeIsForwarded() public {
        _open(index.AUCTION_DURATION());
        pyth.setFee(1);
        (, uint256[] memory in_) = _preview();
        bytes[] memory update = _update();
        bytes[] memory routes = _routes();
        uint256 deadline = block.timestamp;
        vm.deal(keeper, 3);
        vm.expectRevert(MockPyth.InsufficientFee.selector);
        vm.prank(keeper);
        executor.fill(index, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);

        vm.prank(keeper);
        executor.fill{value: 3}(index, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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
        bytes[] memory live = pyth.liveUpdates(own, 0);
        vm.prank(keeper);
        own.startRebalance(0, live);
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
        executor.fill(own, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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
        (int256 delta,) = ex.fill(index, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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
        ex.fill(index, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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
        executor.fill(IWeightedHub(target), update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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
        executor.fill(index, update, routes, in_, ANY_SUPPLY, type(int256).min, deadline);
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

    function test_constructor() public view {
        assertEq(address(executor.ROUTER()), address(router));
        assertEq(executor.USDC(), address(usdc));
        assertEq(address(executor.FACTORY()), address(factory));
        assertEq(address(executor.REQUESTS()), address(requests));
        assertEq(address(executor.TOKEN_BRIDGE()), address(bridge));
        assertEq(executor.OWNER(), execOwner);
        assertEq(executor.keeper(), keeper);
        assertEq(usdc.allowance(address(executor), address(router)), type(uint256).max, "USDC approved once");
    }

    function test_constructorRefusesZeroAddresses() public {
        IV3SwapRouter r = IV3SwapRouter(address(router));
        IWeightedIndexFactory f = IWeightedIndexFactory(address(factory));
        IMintRequests q = IMintRequests(address(requests));
        ITokenBridge b = ITokenBridge(address(bridge));
        address u = address(usdc);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(IV3SwapRouter(address(0)), u, f, q, b, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, address(0), f, q, b, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, IWeightedIndexFactory(address(0)), q, b, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, IMintRequests(address(0)), b, execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, q, ITokenBridge(address(0)), execOwner, keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, q, b, address(0), keeper);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        new KeeperExecutor(r, u, f, q, b, execOwner, address(0));
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
            ITokenBridge(address(bridge)),
            execOwner,
            keeper
        );
    }

    // ---------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------

    /// @dev A settlement lands between the bot's simulation and its fill and moves the basket's units. The fill names
    ///      the nonce it was simulated at, so it stops before any swap, instead of delivering a stock the bot never
    ///      priced (RX-4).
    function test_RX4_aSettlementSinceTheSimulationStopsARequestFill() public {
        _issue(index, stranger, 1e18);
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        _fill(executor, _routes(), in_, type(int256).min);
        assertEq(index.rebalanceNonce(), 1);

        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        KeeperExecutor.RequestFill memory f = _req(id, 2e18, _routes(), "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.StaleRebalanceNonce.selector, 0, 1));
        executor.fillMint(f);

        uint256 redeemId = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        f = _req(redeemId, 90e6, _routes(), "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.StaleRebalanceNonce.selector, 0, 1));
        executor.fillRedeem(f);

        reqNonce = 1;
        f = _req(id, 2e18, _routes(), "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        executor.fillMint(f);
        assertEq(index.balanceOf(stranger), 2e18, "at the nonce it was simulated at, the fill goes through");
    }

    /// @dev Request fills read no Pyth update, so a stale or forged price could make the bot pay out its float for a
    ///      basket worth less. What a request fill turns of the float into anything else comes out of an allowance only
    ///      the owner sets (RX-1, RX-9); a fill that gains USDC spends none.
    function test_RX1_RX9_requestFillsSpendOnlyTheirUsdcAllowance() public {
        _issue(index, stranger, 2e18);
        bytes[] memory routes = _routes();
        routes[1] = ""; // the BTC is kept, so the redemption costs the float its price
        uint256 id = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        uint256[] memory got = index.previewRedeem(1e18);
        uint256 spent = 90e6 - router.quoteOut(address(eth), address(usdc), got[0])
            - router.quoteOut(address(usd), address(usdc), got[2]);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, stranger));
        executor.setRequestUsdcAllowance(1);
        vm.prank(execOwner);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.RequestUsdcAllowanceSet(spent - 1);
        executor.setRequestUsdcAllowance(spent - 1);

        KeeperExecutor.RequestFill memory f = _req(id, 90e6, routes, "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.OverRequestAllowance.selector, spent, spent - 1));
        executor.fillRedeem(f);

        vm.prank(execOwner);
        executor.setRequestUsdcAllowance(spent + 5);
        vm.prank(keeper);
        executor.fillRedeem(f);
        assertEq(executor.requestUsdcAllowance(), 5, "the fill spent what it cost the float");

        // A mint fill above the basket's cost adds to the float and spends none of the allowance.
        uint256 mintId = _requestMint(stranger, address(usdc), 250e6, 2e18);
        f = _req(mintId, 2e18, _routes(), "", type(int256).min, block.timestamp);
        vm.prank(keeper);
        executor.fillMint(f);
        assertEq(executor.requestUsdcAllowance(), 5);
    }

    /// @dev Each leg of a request fill can carry its own bound, so a pool pushed ahead of the fill stops it at that
    ///      leg rather than after the whole basket has traded; a stablecoin leg likewise (RX-10).
    function test_RX10_aRequestFillsLegsCarryTheirOwnBounds() public {
        uint256 id = _requestMint(stranger, address(usdt), 250e6, 2e18);
        uint256[] memory need = index.previewIssue(2e18);
        KeeperExecutor.RequestFill memory f =
            _req(id, 2e18, _routes(), _stableRoute(address(usdt)), type(int256).min, block.timestamp);

        f.legLimits = new uint256[](2);
        vm.prank(keeper);
        vm.expectRevert(KeeperExecutor.LengthMismatch.selector);
        executor.fillMint(f);

        f.legLimits = new uint256[](3);
        f.legLimits[1] = router.quoteIn(address(usdc), address(btc), need[1]) - 1;
        vm.prank(keeper);
        vm.expectRevert("Too much requested");
        executor.fillMint(f);

        f.legLimits[1] = 0;
        f.stableLimit = router.quoteOut(address(usdt), address(usdc), 250e6) + 1;
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        executor.fillMint(f);

        f.stableLimit = router.quoteOut(address(usdt), address(usdc), 250e6);
        f.legLimits[1] = router.quoteIn(address(usdc), address(btc), need[1]);
        vm.prank(keeper);
        executor.fillMint(f);
        assertEq(index.balanceOf(stranger), 2e18, "at their bounds the legs fill");

        // A redemption: each sold leg's least proceeds, and the most the stablecoin may cost.
        _issue(index, stranger, 1e18);
        uint256 redeemId = _requestRedeem(stranger, 1e18, address(usdt), 90e6);
        uint256[] memory got = index.previewRedeem(1e18);
        f = _req(redeemId, 90e6, _routes(), _stableRoute(address(usdt)), type(int256).min, block.timestamp);
        f.stableLimit = router.quoteIn(address(usdc), address(usdt), 90e6) - 1;
        vm.prank(keeper);
        vm.expectRevert("Too much requested");
        executor.fillRedeem(f);

        f.stableLimit = 0;
        f.legLimits = new uint256[](3);
        f.legLimits[0] = router.quoteOut(address(eth), address(usdc), got[0]) + 1;
        vm.prank(keeper);
        vm.expectRevert("Too little received");
        executor.fillRedeem(f);

        f.legLimits[0] = router.quoteOut(address(eth), address(usdc), got[0]);
        vm.prank(keeper);
        executor.fillRedeem(f);
        assertEq(usdt.balanceOf(stranger), 90e6);
    }

    function test_fillMintBuysTheBasketIssuesAndTakesTheEscrow() public {
        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        uint256 cost = _basketCost(2e18);
        uint256 before = usdc.balanceOf(address(executor));

        vm.prank(keeper);
        (int256 delta, uint256 gasUsed) =
            executor.fillMint(_req(id, 2e18, _routes(), "", type(int256).min, block.timestamp));

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
            executor.fillMint(_req(id, 2e18, _routes(), _stableRoute(address(usdt)), type(int256).min, block.timestamp));
        assertEq(delta, _int(router.quoteOut(address(usdt), address(usdc), 250e6)) - _int(cost));
        assertEq(usdt.balanceOf(address(executor)), 0, "the USDT was sold");
        assertEq(index.balanceOf(stranger), 2e18);

        // Without the stablecoin's route, or with one for USDC, the fill is refused.
        id = _requestMint(stranger, address(usdt), 250e6, 2e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdt)));
        executor.fillMint(_req(id, 2e18, _routes(), "", type(int256).min, block.timestamp));
        id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdc)));
        executor.fillMint(_req(id, 2e18, _routes(), _stableRoute(address(usdt)), type(int256).min, block.timestamp));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdc)));
        executor.fillMint(_req(id, 2e18, _routes(), hex"1234", type(int256).min, block.timestamp));
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
        (int256 delta,) = executor.fillMint(_req(id, 2e18, routes, "", type(int256).min, block.timestamp));
        assertEq(delta, _int(250e6) - _int(cost), "half the ETH came from stock, the rest was bought");
        assertEq(eth.balanceOf(address(executor)), need[0] - need[0] / 2, "the stock beyond the allowance stayed");
        assertEq(executor.stockAllowance(address(eth)), 0, "the delivery spent the allowance");

        // With no route for a coin the stock cannot cover, nothing can be delivered.
        id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        routes[0] = "";
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(eth)));
        executor.fillMint(_req(id, 2e18, routes, "", type(int256).min, block.timestamp));
    }

    function test_fillMintChecksTheCall() public {
        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, stranger));
        vm.prank(stranger);
        executor.fillMint(_req(id, 2e18, _routes(), "", type(int256).min, block.timestamp));

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.Expired.selector, block.timestamp - 1));
        executor.fillMint(_req(id, 2e18, _routes(), "", type(int256).min, block.timestamp - 1));

        bytes[] memory two = new bytes[](2);
        vm.prank(keeper);
        vm.expectRevert(KeeperExecutor.LengthMismatch.selector);
        executor.fillMint(_req(id, 2e18, two, "", type(int256).min, block.timestamp));

        // The floor binds: the escrow less the cost is the most the fill can promise.
        int256 cost = _int(_basketCost(2e18));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(KeeperExecutor.TooCostly.selector, _int(250e6) - cost, _int(250e6) - cost + 1)
        );
        executor.fillMint(_req(id, 2e18, _routes(), "", _int(250e6) - cost + 1, block.timestamp));

        // Fewer shares than the limit: the escrow refuses the delivery.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 2e18 - 1, 2e18));
        executor.fillMint(_req(id, 2e18 - 1, _routes(), "", type(int256).min, block.timestamp));

        // A redeem request is the other side.
        _issue(index, stranger, 1e18);
        uint256 redeemId = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongSide.selector, redeemId));
        executor.fillMint(_req(redeemId, 1e18, _routes(), "", type(int256).min, block.timestamp));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongSide.selector, id));
        executor.fillRedeem(_req(id, 90e6, _routes(), "", type(int256).min, block.timestamp));
    }

    /// @dev XS-6: a mint request its requester cancelled after the bot's simulation, or one past its deadline, is
    ///      refused before the basket is bought. Every call to the router reverts here, so a fill that bought anything
    ///      would fail with the router's revert, not the escrow's error.
    function test_XS6_aClosedMintRequestRevertsBeforeAnySwap() public {
        uint256 id = _requestMint(stranger, address(usdc), 250e6, 2e18);
        uint256 late = _requestMint(stranger, address(usdc), 250e6, 2e18);
        uint256 deadline = requests.getRequest(late).deadline;
        vm.prank(stranger);
        requests.cancel(id);
        vm.mockCallRevert(address(router), bytes(""), bytes("a swap ran"));

        bytes[] memory routes = _routes();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        executor.fillMint(_req(id, 2e18, routes, "", type(int256).min, block.timestamp));

        vm.warp(deadline + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestExpired.selector, late, deadline));
        executor.fillMint(_req(late, 2e18, routes, "", type(int256).min, block.timestamp));
    }

    /// @dev XS-6, the redeem side: a USDT request, whose fill buys the stablecoin first, is refused before that swap.
    function test_XS6_aClosedRedeemRequestRevertsBeforeAnySwap() public {
        _issue(index, stranger, 2e18);
        uint256 id = _requestRedeem(stranger, 1e18, address(usdt), 90e6);
        uint256 late = _requestRedeem(stranger, 1e18, address(usdt), 90e6);
        uint256 deadline = requests.getRequest(late).deadline;
        vm.prank(stranger);
        requests.cancel(id);
        vm.mockCallRevert(address(router), bytes(""), bytes("a swap ran"));

        bytes[] memory routes = _routes();
        bytes memory stableRoute = _stableRoute(address(usdt));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestNotOpen.selector, id));
        executor.fillRedeem(_req(id, 90e6, routes, stableRoute, type(int256).min, block.timestamp));

        vm.warp(deadline + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.RequestExpired.selector, late, deadline));
        executor.fillRedeem(_req(late, 90e6, routes, stableRoute, type(int256).min, block.timestamp));
    }

    /// @dev XS-6, the gate: on a gated index that does not allow the executor, a creator who disallows it just ahead
    ///      of the fill included, the hub would refuse the issue only after every swap. The executor reads the gate
    ///      first; once the creator allows it, the same request fills.
    function test_XS6_aGatedIndexRefusesTheExecutorBeforeAnySwap() public {
        IWeightedIndexFactory.IndexParams memory params = _params();
        params.gated = true;
        params.rebalanceInterval = 8 days; // another salt than `index`'s
        WeightedHub gated = _create(_defaultSpecs(), params);
        usdc.mint(stranger, 250e6);
        vm.startPrank(stranger);
        usdc.approve(address(requests), 250e6);
        uint256 id = requests.requestMint(address(gated), address(usdc), 250e6, 2e18, block.timestamp + 1 days);
        vm.stopPrank();
        bytes[] memory routes = _routes();

        vm.mockCallRevert(address(router), bytes(""), bytes("a swap ran"));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.NotAllowedMinter.selector, address(executor)));
        executor.fillMint(_req(id, 2e18, routes, "", type(int256).min, block.timestamp));
        vm.clearMockedCalls();

        vm.prank(creator);
        factory.setAllowedMinter(address(gated), address(executor), true);
        vm.prank(keeper);
        executor.fillMint(_req(id, 2e18, routes, "", type(int256).min, block.timestamp));
        assertEq(gated.balanceOf(stranger), 2e18, "allowed, the executor fills the request");
    }

    function test_fillRedeemPaysTheStableRedeemsAndSellsTheBasket() public {
        _issue(index, stranger, 1e18);
        uint256 id = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        uint256 proceeds = _basketProceeds(1e18);
        uint256 before = usdc.balanceOf(address(executor));

        vm.prank(keeper);
        (int256 delta, uint256 gasUsed) =
            executor.fillRedeem(_req(id, 90e6, _routes(), "", type(int256).min, block.timestamp));

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
            executor.fillRedeem(_req(id, 90e6, routes, _stableRoute(address(usdt)), type(int256).min, block.timestamp));
        assertEq(delta, _int(proceeds) - _int(paid));
        assertEq(usdt.balanceOf(stranger), 90e6);
        assertEq(btc.balanceOf(address(executor)), got[1], "the unrouted BTC is stock now");

        // The floor binds here too, and a stablecoin needs its route.
        _issue(index, stranger, 1e18);
        id = _requestRedeem(stranger, 1e18, address(usdt), 90e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.BadRoute.selector, address(usdt)));
        executor.fillRedeem(_req(id, 90e6, routes, "", type(int256).min, block.timestamp));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(KeeperExecutor.TooCostly.selector, _int(proceeds) - _int(paid), _int(proceeds))
        );
        executor.fillRedeem(_req(id, 90e6, routes, _stableRoute(address(usdt)), _int(proceeds), block.timestamp));
    }

    function test_fillRedeemChecksTheCall() public {
        _issue(index, stranger, 1e18);
        uint256 id = _requestRedeem(stranger, 1e18, address(usdc), 90e6);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotKeeper.selector, stranger));
        vm.prank(stranger);
        executor.fillRedeem(_req(id, 90e6, _routes(), "", type(int256).min, block.timestamp));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.Expired.selector, block.timestamp - 1));
        executor.fillRedeem(_req(id, 90e6, _routes(), "", type(int256).min, block.timestamp - 1));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMintRequests.BelowLimit.selector, 90e6 - 1, 90e6));
        executor.fillRedeem(_req(id, 90e6 - 1, _routes(), "", type(int256).min, block.timestamp));
    }

    // ---------------------------------------------------------------------
    // The bot's view of the hub (XS-8)
    // ---------------------------------------------------------------------

    /// @dev `WeightedHub`'s `_eta` and `_keepMask` slots, which the bot overrides by `eth_call` state to see an auction
    ///      before it opens.
    uint256 constant ETA_SLOT = 6;
    uint256 constant KEEP_MASK_SLOT = 7;

    /// @dev XS-8: keeper/bot/config.mjs names these slots, and on a real hub they are the pending auction's: writing
    ///      them is what `pendingRebalance` reports, on a clone and on the implementation the bot's startup check
    ///      probes, and a live auction lands in them. The next layout change fails here rather than at the bot's
    ///      startup.
    function test_XS8_theBotsHubSlotsAreTheHubs() public {
        string memory config = vm.readFile("bot/config.mjs");
        string memory pinned = string.concat(
            "HUB_SLOTS = Object.freeze({ eta: ",
            vm.toString(ETA_SLOT),
            "n, keepMask: ",
            vm.toString(KEEP_MASK_SLOT),
            "n });"
        );
        assertTrue(vm.indexOf(config, pinned) != type(uint256).max, "config.mjs names slots 6 and 7");

        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        bytes[] memory live = pyth.liveUpdates(index, 1);
        vm.prank(guardian);
        index.startRebalance(1, live);
        (uint256 liveEta, uint256 liveMask) = index.pendingRebalance();
        assertEq(uint256(vm.load(address(index), bytes32(ETA_SLOT))), liveEta, "a live auction's eta is in slot 6");
        assertEq(uint256(vm.load(address(index), bytes32(KEEP_MASK_SLOT))), liveMask, "and its keep mask in slot 7");

        address[2] memory hubs = [address(index), factory.IMPLEMENTATION()];
        for (uint256 i = 0; i < 2; ++i) {
            vm.store(hubs[i], bytes32(ETA_SLOT), bytes32(uint256(1234)));
            vm.store(hubs[i], bytes32(KEEP_MASK_SLOT), bytes32(uint256(5)));
            (uint256 eta, uint256 keepMask) = IWeightedHub(hubs[i]).pendingRebalance();
            assertEq(eta, 1234, "the eta slot is the hub's");
            assertEq(keepMask, 5, "the keepMask slot is the hub's");
        }
    }

    // ---------------------------------------------------------------------
    // Restock
    // ---------------------------------------------------------------------

    /// @dev BTC's stand-in as a Wormhole copy, from Wormhole chain 4.
    bytes32 constant BTC_SOURCE = bytes32(uint256(0xb7c));
    uint16 constant HOME = 4;
    bytes32 constant HOME_WALLET = bytes32(uint256(0xbee));

    function _treasury() internal {
        vm.startPrank(execOwner);
        executor.setTreasury(treasury);
        executor.setHomeRecipient(HOME, HOME_WALLET);
        vm.stopPrank();
        bridge.setWrapped(HOME, BTC_SOURCE, address(btc));
    }

    /// @dev `amount` of BTC bridged to the executor, as the bridge's signed transfer.
    function _bridgedBtc(uint256 amount) internal returns (bytes memory) {
        btc.mint(address(bridge), amount);
        return bridge.vm(HOME, BTC_SOURCE, address(btc), amount, address(executor));
    }

    /// @dev The owner lets `amount` more of `token` arriving through the bridge earn stock allowance (RS-1).
    function _restock(address token, uint256 amount) internal {
        vm.prank(execOwner);
        executor.setRestockAllowance(token, amount);
    }

    function test_onlyTheOwnerPinsTheTreasuryAndTheRecipients() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, keeper));
        executor.setTreasury(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, keeper));
        executor.setTreasuryUsdcAllowance(1);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, keeper));
        executor.setHomeRecipient(HOME, HOME_WALLET);
        vm.stopPrank();

        vm.startPrank(execOwner);
        vm.expectRevert(KeeperExecutor.ZeroAddress.selector);
        executor.setTreasury(address(0));
        vm.expectEmit(address(executor));
        emit KeeperExecutor.TreasurySet(address(0), treasury);
        executor.setTreasury(treasury);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.TreasuryUsdcAllowanceSet(5);
        executor.setTreasuryUsdcAllowance(5);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.HomeRecipientSet(HOME, HOME_WALLET);
        executor.setHomeRecipient(HOME, HOME_WALLET);
        vm.stopPrank();
        assertEq(executor.treasury(), treasury);
        assertEq(executor.treasuryUsdcAllowance(), 5);
        assertEq(executor.homeRecipient(HOME), HOME_WALLET);
    }

    function test_onlyTheTreasuryRestocks() public {
        _treasury();
        bytes memory vm_ = _bridgedBtc(1e8);
        address[2] memory others = [keeper, execOwner];
        for (uint256 i = 0; i < 2; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotTreasury.selector, others[i]));
            executor.redeemBridged(vm_, address(btc));
            vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotTreasury.selector, others[i]));
            executor.bridgeOut(address(btc), 1, HOME);
            vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotTreasury.selector, others[i]));
            executor.drawUsdc(0);
            vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotTreasury.selector, others[i]));
            executor.repayUsdc(0);
            vm.stopPrank();
        }
    }

    /// @dev What a bridged transfer brings is added to the stock allowance, measured where it lands: an 18-decimal coin
    ///      crosses in eight decimals, so the transfer's own amount is not the raw amount that arrives.
    function test_aBridgedTransferAddsWhatArrivedToTheAllowance() public {
        _treasury();
        bytes32 ethSource = bytes32(uint256(0xe7));
        bridge.setWrapped(HOME, ethSource, address(eth));
        eth.mint(address(bridge), 5e18);
        bytes memory vm_ = bridge.vm(HOME, ethSource, address(eth), 5e18, address(executor));
        eth.mint(address(executor), 1e18); // a coin already held is no part of the credit
        _allow(address(eth), 2);
        _restock(address(eth), 5e18);

        vm.expectEmit(address(executor));
        emit KeeperExecutor.BridgedIn(address(eth), 5e18, 5e18);
        vm.prank(treasury);
        uint256 amount = executor.redeemBridged(vm_, address(eth));
        assertEq(amount, 5e18);
        assertEq(executor.stockAllowance(address(eth)), 5e18 + 2, "added to what was left");
        assertEq(eth.balanceOf(address(executor)), 6e18);
    }

    /// @dev The transfer names its token: a call that names another refuses it, and the transfer stays to be completed.
    function test_aBridgedTransferOfAnotherTokenIsRefused() public {
        _treasury();
        bytes memory vm_ = _bridgedBtc(1e8);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.WrongToken.selector, address(eth), address(btc)));
        vm.prank(treasury);
        executor.redeemBridged(vm_, address(eth));
        assertFalse(bridge.completed(keccak256(vm_)), "the transfer is still there to complete");
        assertEq(executor.stockAllowance(address(eth)), 0);
    }

    /// @dev An Ethereum token that comes back through the bridge is named by its own address, not a wrapped one.
    function test_anEthereumTokenComingBackIsNamedByItsAddress() public {
        _treasury();
        _restock(address(btc), 3e8);
        btc.mint(address(bridge), 3e8);
        bytes memory vm_ =
            bridge.vm(bridge.CHAIN(), bytes32(uint256(uint160(address(btc)))), address(btc), 3e8, address(executor));
        vm.prank(treasury);
        executor.redeemBridged(vm_, address(btc));
        assertEq(executor.stockAllowance(address(btc)), 3e8);
    }

    /// @dev The bridge lets only a payload transfer's recipient complete it, so no one can land the coins here ahead of
    ///      the treasury and leave them without the allowance.
    function test_noOneElseCanLandABridgedTransferHere() public {
        _treasury();
        _restock(address(btc), 1e8);
        bytes memory vm_ = _bridgedBtc(1e8);
        vm.expectRevert(MockTokenBridge.InvalidSender.selector);
        vm.prank(stranger);
        bridge.completeTransferWithPayload(vm_);
        vm.prank(treasury);
        executor.redeemBridged(vm_, address(btc));
        assertEq(executor.stockAllowance(address(btc)), 1e8);
    }

    /// @dev The whole loop on the executor's side: a coin with no route is short, the treasury bridges it in, and the
    ///      next fill delivers it from stock.
    function test_bridgedStockFillsTheAuctionItWasShortFor() public {
        _treasury();
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        bytes[] memory routes = _routes();
        routes[1] = "";
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(btc)),
            keeper,
            address(index),
            routes,
            block.timestamp
        );

        _restock(address(btc), in_[1]);
        bytes memory vm_ = _bridgedBtc(in_[1]);
        vm.prank(treasury);
        executor.redeemBridged(vm_, address(btc));
        _fill(executor, routes, in_, type(int256).min);
        assertEq(btc.balanceOf(address(executor)), 0, "what was bridged in went to the index");
        assertEq(executor.stockAllowance(address(btc)), 0);
    }

    function test_bridgeOutSendsOnlyToThePinnedRecipient() public {
        _treasury();
        btc.mint(address(executor), 5e8);
        vm.startPrank(treasury);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NoHomeRecipient.selector, uint16(21)));
        executor.bridgeOut(address(btc), 1e8, 21);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotStock.selector, address(usdc)));
        executor.bridgeOut(address(usdc), 1e6, HOME);
        vm.stopPrank();

        bridge.setMessageFee(7);
        vm.deal(treasury, 7);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.BridgedOut(address(btc), 2e8, HOME, HOME_WALLET, 0);
        vm.prank(treasury);
        uint64 sequence = executor.bridgeOut{value: 7}(address(btc), 2e8, HOME);
        assertEq(sequence, 0);
        (address token, uint256 amount, uint16 chain, bytes32 recipient, uint256 value) = bridge.last();
        assertEq(token, address(btc));
        assertEq(amount, 2e8);
        assertEq(chain, HOME);
        assertEq(recipient, HOME_WALLET, "the owner's recipient");
        assertEq(value, 7, "Wormhole's fee forwarded");
        assertEq(btc.balanceOf(address(executor)), 3e8);
        assertEq(btc.allowance(address(executor), address(bridge)), 0, "no approval left behind");

        vm.prank(execOwner);
        executor.setHomeRecipient(HOME, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NoHomeRecipient.selector, HOME));
        vm.prank(treasury);
        executor.bridgeOut(address(btc), 1e8, HOME);
    }

    /// @dev What the bridge cannot carry below eight decimals stays here, and no approval of it is left behind.
    function test_bridgeOutLeavesTheDustBelowEightDecimals() public {
        _treasury();
        eth.mint(address(executor), 1e18 + 123);
        vm.prank(treasury);
        executor.bridgeOut(address(eth), 1e18 + 123, HOME);
        assertEq(eth.balanceOf(address(executor)), 123);
        assertEq(eth.allowance(address(executor), address(bridge)), 0);
    }

    /// @dev Stock that leaves takes its allowance with it as far as the allowance would outlast the balance, so coins
    ///      kept by a later fill cannot be delivered on the credit of coins that already left.
    function test_bridgeOutCapsTheAllowanceAtWhatIsLeft() public {
        _treasury();
        btc.mint(address(executor), 10e8);
        _allow(address(btc), 10e8);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.StockAllowanceSet(address(btc), 4e8);
        vm.prank(treasury);
        executor.bridgeOut(address(btc), 6e8, HOME);
        assertEq(executor.stockAllowance(address(btc)), 4e8);

        _allow(address(btc), 1e8);
        vm.prank(treasury);
        executor.bridgeOut(address(btc), 2e8, HOME);
        assertEq(executor.stockAllowance(address(btc)), 1e8, "an allowance below the balance stays as it was");

        btc.mint(address(executor), 5e8); // kept by a later fill
        assertEq(executor.stockAllowance(address(btc)), 1e8, "and the kept coins earn none");
    }

    function test_theTreasuryDrawsAndRepaysWithinItsAllowance() public {
        _treasury();
        vm.prank(execOwner);
        executor.setTreasuryUsdcAllowance(1000e6);

        vm.startPrank(treasury);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.UsdcDrawn(600e6);
        executor.drawUsdc(600e6);
        assertEq(usdc.balanceOf(treasury), 600e6);
        assertEq(executor.treasuryUsdcAllowance(), 400e6);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.OverTreasuryAllowance.selector, 500e6, 400e6));
        executor.drawUsdc(500e6);

        usdc.approve(address(executor), 300e6);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.UsdcRepaid(300e6);
        executor.repayUsdc(300e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 300e6);
        assertEq(executor.treasuryUsdcAllowance(), 700e6, "what came back may go out again");
        assertEq(usdc.balanceOf(address(executor)), 10_000e6 - 300e6);
    }

    function test_RS1_onlyTheOwnerSetsTheRestockAllowance() public {
        _treasury();
        address[2] memory others = [keeper, treasury];
        for (uint256 i = 0; i < 2; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.NotOwner.selector, others[i]));
            vm.prank(others[i]);
            executor.setRestockAllowance(address(btc), 1);
        }
        vm.expectEmit(address(executor));
        emit KeeperExecutor.RestockAllowanceSet(address(btc), 7e8);
        vm.prank(execOwner);
        executor.setRestockAllowance(address(btc), 7e8);
        assertEq(executor.restockAllowance(address(btc)), 7e8);
    }

    /// @dev RS-1: what arrives through the bridge earns stock allowance only within the restock allowance the owner
    ///      set, which every credit spends. What arrives beyond it is kept here, and the keeper cannot deliver it until
    ///      the owner allows it, so restocking cannot raise CF-1's bound on its own.
    function test_RS1_bridgedStockEarnsAllowanceOnlyWithinTheOwnersRestockAllowance() public {
        _treasury();
        _restock(address(btc), 3e8);

        bytes memory first = _bridgedBtc(5e8);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.BridgedIn(address(btc), 5e8, 3e8);
        vm.prank(treasury);
        uint256 arrived = executor.redeemBridged(first, address(btc));
        assertEq(arrived, 5e8, "all of it arrived");
        assertEq(executor.stockAllowance(address(btc)), 3e8, "credited up to the restock allowance");
        assertEq(executor.restockAllowance(address(btc)), 0, "which the credit spent");
        assertEq(btc.balanceOf(address(executor)), 5e8, "the rest is kept here");

        bytes memory second = _bridgedBtc(1e8);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.BridgedIn(address(btc), 1e8, 0);
        vm.prank(treasury);
        executor.redeemBridged(second, address(btc));
        assertEq(executor.stockAllowance(address(btc)), 3e8, "nothing more without the owner");
        assertEq(btc.balanceOf(address(executor)), 6e8);
    }

    /// @dev RS-1, end to end: coins bridged in for an auction, beyond the owner's restock allowance, are no stock the
    ///      keeper can deliver, so the fill finds no way to the coin until the owner allows them.
    function test_RS1_bridgedStockBeyondTheRestockAllowanceFillsNothing() public {
        _treasury();
        _open(index.AUCTION_DURATION());
        (, uint256[] memory in_) = _preview();
        bytes[] memory routes = _routes();
        routes[1] = "";
        bytes memory vm_ = _bridgedBtc(in_[1]);
        vm.prank(treasury);
        executor.redeemBridged(vm_, address(btc));
        assertEq(btc.balanceOf(address(executor)), in_[1], "it arrived");
        _expectFillReverts(
            abi.encodeWithSelector(KeeperExecutor.NoRoute.selector, address(btc)),
            keeper,
            address(index),
            routes,
            block.timestamp
        );

        _allow(address(btc), in_[1]);
        _fill(executor, routes, in_, type(int256).min);
        assertEq(btc.balanceOf(address(executor)), 0, "delivered once the owner allowed it");
    }

    /// @dev RS-2: the owner's figure is the most USDC the treasury may hold off the float. A repayment lowers what it
    ///      holds, never below zero, so repaying more than it drew, from coins it sold at home, raises nothing; the
    ///      surplus joins the float.
    function test_RS2_aRepaymentBeyondWhatWasDrawnRaisesNothing() public {
        _treasury();
        vm.prank(execOwner);
        executor.setTreasuryUsdcAllowance(1000e6);
        vm.prank(treasury);
        executor.drawUsdc(600e6);
        usdc.mint(treasury, 300e6); // proceeds of stock it sold at home

        vm.startPrank(treasury);
        usdc.approve(address(executor), 900e6);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.UsdcRepaid(900e6);
        executor.repayUsdc(900e6);
        assertEq(executor.treasuryUsdcOut(), 0, "it holds nothing off the float");
        assertEq(executor.treasuryUsdcAllowance(), 1000e6, "back to the owner's figure, not above it");
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.OverTreasuryAllowance.selector, 1000e6 + 1, 1000e6));
        executor.drawUsdc(1000e6 + 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(executor)), 10_000e6 + 300e6, "the surplus joined the float");
    }

    /// @dev RS-2: the owner's figure counts what the treasury already holds off the float.
    function test_RS2_theOwnersFigureCountsWhatTheTreasuryHolds() public {
        _treasury();
        vm.prank(execOwner);
        executor.setTreasuryUsdcAllowance(1000e6);
        vm.prank(treasury);
        executor.drawUsdc(600e6);
        vm.prank(execOwner);
        executor.setTreasuryUsdcAllowance(500e6);
        assertEq(executor.treasuryUsdcAllowance(), 0, "it already holds more than the new figure");

        vm.startPrank(treasury);
        vm.expectRevert(abi.encodeWithSelector(KeeperExecutor.OverTreasuryAllowance.selector, 1, 0));
        executor.drawUsdc(1);
        usdc.approve(address(executor), 200e6);
        executor.repayUsdc(200e6);
        vm.stopPrank();
        assertEq(executor.treasuryUsdcOut(), 400e6);
        assertEq(executor.treasuryUsdcAllowance(), 100e6, "the figure less what it holds");
    }

    /// @dev RS-6: the stock allowance has no "unlimited" value, so an owner who sets it to the most a uint256 holds and
    ///      grants a restock allowance made every redemption of the coin overflow, its transfer stuck in the bridge.
    ///      The credit is what the stock allowance can still hold, and what it cannot is left to the restock allowance.
    function test_RS6_aStockAllowanceAtItsMostDoesNotBlockARedemption() public {
        _treasury();
        _restock(address(btc), 5e8);
        vm.prank(execOwner);
        executor.setStockAllowance(address(btc), type(uint256).max - 1e8);

        bytes memory transfer = _bridgedBtc(3e8);
        vm.expectEmit(address(executor));
        emit KeeperExecutor.BridgedIn(address(btc), 3e8, 1e8);
        vm.prank(treasury);
        assertEq(executor.redeemBridged(transfer, address(btc)), 3e8, "the coins arrive");
        assertEq(executor.stockAllowance(address(btc)), type(uint256).max, "the allowance fills to its most");
        assertEq(executor.restockAllowance(address(btc)), 4e8, "and spends only what it took of the restock allowance");

        bytes memory more = _bridgedBtc(2e8);
        vm.prank(treasury);
        executor.redeemBridged(more, address(btc));
        assertEq(btc.balanceOf(address(executor)), 5e8, "a full allowance takes in the next arrival too");
        assertEq(executor.restockAllowance(address(btc)), 4e8, "earning nothing from it");
    }
}
