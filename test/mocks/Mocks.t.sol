// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUSDT} from "./MockUSDT.sol";
import {MockSwapRouter} from "./MockSwapRouter.sol";
import {MockPausableToken} from "./MockPausableToken.sol";
import {MockPartialFillRouter} from "./MockPartialFillRouter.sol";
import {MockMarket} from "./MockMarket.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./MockUniswapV3.sol";
import {MockWETH} from "./MockWETH.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {INonfungiblePositionManager} from "../../script/interfaces/INonfungiblePositionManager.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {RebalanceExecutorV3} from "../fork/RebalanceExecutorV3.sol";
import {IIndexToken} from "../../src/interfaces/IIndexToken.sol";

/// @notice Exercises the mocks' own guard rails so their behaviour in the real tests is trustworthy.
contract MocksTest is Test {
    MockSwapRouter router;
    MockERC20 usdc;
    MockERC20 weth;
    MockERC20 unpriced;
    MockUSDT usdt;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        router = new MockSwapRouter();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        unpriced = new MockERC20("No Price", "NOPE", 18);
        usdt = new MockUSDT();

        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(weth), 3_000e18);
        weth.mint(address(router), 1_000e18);
        usdc.mint(address(router), 1_000_000e6);
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(500), b);
    }

    // ---------------------------------------------------------------------
    // MockSwapRouter
    // ---------------------------------------------------------------------

    function test_router_quotesAreInverse() public view {
        // 3000 USDC -> 1 WETH, and 1 WETH costs 3000 USDC
        assertEq(router.quoteOut(address(usdc), address(weth), 3_000e6), 1e18);
        assertEq(router.quoteIn(address(usdc), address(weth), 1e18), 3_000e6);
        // ceil on exact-output: 1 wei of WETH still costs 1 unit of USDC
        assertEq(router.quoteIn(address(usdc), address(weth), 1), 1);
    }

    function test_router_exactInput_happyPath() public {
        usdc.mint(alice, 3_000e6);
        vm.startPrank(alice);
        usdc.approve(address(router), 3_000e6);
        uint256 out = router.exactInput(
            ISwapRouter02.ExactInputParams({
                path: _path(address(usdc), address(weth)), recipient: bob, amountIn: 3_000e6, amountOutMinimum: 1e18
            })
        );
        vm.stopPrank();
        assertEq(out, 1e18);
        assertEq(weth.balanceOf(bob), 1e18);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_router_exactInput_reverts() public {
        ISwapRouter02.ExactInputParams memory p = ISwapRouter02.ExactInputParams({
            path: abi.encodePacked(address(usdc), address(weth)), // no fee => malformed
            recipient: bob,
            amountIn: 1e6,
            amountOutMinimum: 0
        });
        vm.expectRevert("MockRouter: path");
        router.exactInput(p);

        p.path = _path(address(usdc), address(unpriced));
        vm.expectRevert("MockRouter: no price");
        router.exactInput(p);

        p.path = _path(address(usdc), address(weth));
        p.amountOutMinimum = type(uint256).max;
        vm.expectRevert("Too little received");
        router.exactInput(p);
    }

    function test_router_exactOutput_reverts() public {
        ISwapRouter02.ExactOutputParams memory p = ISwapRouter02.ExactOutputParams({
            path: abi.encodePacked(address(weth), address(usdc)),
            recipient: bob,
            amountOut: 1e18,
            amountInMaximum: type(uint256).max
        });
        vm.expectRevert("MockRouter: path");
        router.exactOutput(p);

        p.path = _path(address(unpriced), address(usdc));
        vm.expectRevert("MockRouter: no price");
        router.exactOutput(p);

        p.path = _path(address(weth), address(usdc));
        p.amountInMaximum = 0;
        vm.expectRevert("Too much requested");
        router.exactOutput(p);
    }

    // ---------------------------------------------------------------------
    // MockUSDT
    // ---------------------------------------------------------------------

    function test_usdt_metadataAndMint() public {
        assertEq(usdt.name(), "Tether USD");
        assertEq(usdt.symbol(), "USDT");
        assertEq(usdt.decimals(), 6);
        usdt.mint(alice, 5e6);
        assertEq(usdt.totalSupply(), 5e6);
        assertEq(usdt.balanceOf(alice), 5e6);
    }

    function test_usdt_approveFromNonZeroReverts() public {
        vm.startPrank(alice);
        usdt.approve(bob, 1);
        vm.expectRevert("USDT: approve from non-zero");
        usdt.approve(bob, 2);
        usdt.approve(bob, 0);
        usdt.approve(bob, 2);
        vm.stopPrank();
        assertEq(usdt.allowance(alice, bob), 2);
    }

    function test_usdt_transferFrom_allowanceAndInfinite() public {
        usdt.mint(alice, 10e6);

        vm.prank(bob);
        vm.expectRevert("USDT: allowance");
        usdt.transferFrom(alice, bob, 1);

        vm.prank(alice);
        usdt.approve(bob, 4e6);
        vm.prank(bob);
        usdt.transferFrom(alice, bob, 3e6);
        assertEq(usdt.allowance(alice, bob), 1e6);

        vm.prank(alice);
        usdt.approve(bob, 0);
        vm.prank(alice);
        usdt.approve(bob, type(uint256).max);
        vm.prank(bob);
        usdt.transferFrom(alice, bob, 2e6);
        assertEq(usdt.allowance(alice, bob), type(uint256).max, "infinite allowance is not decremented");
        assertEq(usdt.balanceOf(bob), 5e6);
    }

    function test_usdt_transferInsufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert("USDT: balance");
        usdt.transfer(bob, 1);
    }
    // ---------------------------------------------------------------------
    // MockPausableToken
    // ---------------------------------------------------------------------

    function test_pausableToken_blocksTransfersWhilePaused() public {
        MockPausableToken p = new MockPausableToken("Pausable BTC", "pBTC", 8);
        assertEq(p.decimals(), 8);
        p.mint(alice, 10);

        p.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        p.transfer(bob, 1);

        p.setPaused(false);
        vm.prank(alice);
        p.transfer(bob, 1);
        assertEq(p.balanceOf(bob), 1);
    }

    // ---------------------------------------------------------------------
    // MockPartialFillRouter
    // ---------------------------------------------------------------------

    function test_partialFillRouter_sellsHalf() public {
        MockPartialFillRouter half = new MockPartialFillRouter(3_000e6);
        usdc.mint(address(half), 10_000e6);
        weth.mint(alice, 1e18);

        vm.startPrank(alice);
        weth.approve(address(half), 1e18);
        ISwapRouter02.ExactInputParams memory p = ISwapRouter02.ExactInputParams({
            path: _path(address(weth), address(usdc)), recipient: alice, amountIn: 1e18, amountOutMinimum: 1_500e6 + 1
        });
        vm.expectRevert("Too little received");
        half.exactInput(p);

        p.amountOutMinimum = 1_500e6;
        assertEq(half.exactInput(p), 1_500e6);
        vm.stopPrank();
        assertEq(weth.balanceOf(alice), 5e17, "half of the input was never taken");

        vm.expectRevert("MockPartialFillRouter: exactOutput unsupported");
        half.exactOutput(
            ISwapRouter02.ExactOutputParams({path: "", recipient: alice, amountOut: 1, amountInMaximum: 1})
        );
    }

    // ---------------------------------------------------------------------
    // MockUniswapV3Pool and MockUniswapV3Factory
    // ---------------------------------------------------------------------

    function test_uniswapFactory_registersBothOrdersAndSortsTokens() public {
        MockUniswapV3Factory f = new MockUniswapV3Factory();
        address pool = f.createPool(address(weth), address(usdc), 500);
        assertEq(f.getPool(address(weth), address(usdc), 500), pool);
        assertEq(f.getPool(address(usdc), address(weth), 500), pool);
        assertEq(f.getPool(address(usdc), address(weth), 3000), address(0));

        address low = address(0x1000);
        address high = address(0xF000);
        MockUniswapV3Pool ascending = new MockUniswapV3Pool(low, high, 3000);
        MockUniswapV3Pool descending = new MockUniswapV3Pool(high, low, 3000);
        assertEq(ascending.token0(), low);
        assertEq(ascending.token1(), high);
        assertEq(descending.token0(), low);
        assertEq(descending.token1(), high);
        assertEq(descending.fee(), 3000);
    }

    function test_uniswapPool_observeSlot0AndSwitches() public {
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(weth), address(usdc), 500);
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;

        p.setTick(-120);
        (int56[] memory cumulatives, uint160[] memory perLiquidity) = p.observe(ago);
        assertEq(cumulatives[1] - cumulatives[0], -120 * 1800);
        assertEq(perLiquidity.length, 2);
        (, int24 tick,, uint16 cardinality, uint16 next,, bool unlocked) = p.slot0();
        assertEq(tick, -120);
        assertEq(cardinality, 1_000);
        assertEq(next, 1_000);
        assertTrue(unlocked);

        p.setCumulatives(-1801, 0);
        assertTrue(p.rawCumulatives());
        (cumulatives,) = p.observe(ago);
        assertEq(cumulatives[0], -1801);
        assertEq(cumulatives[1], 0);

        p.setTick(5);
        assertFalse(p.rawCumulatives());
        (cumulatives,) = p.observe(ago);
        assertEq(cumulatives[1] - cumulatives[0], 5 * 1800);

        p.setObservationCardinality(60);
        (,,, cardinality,,,) = p.slot0();
        assertEq(cardinality, 60);

        p.setHistoryTooShort(true);
        vm.expectRevert(bytes("OLD"));
        p.observe(ago);
    }

    function test_uniswapPool_liquidityInterpolationAndInjectedObservations() public {
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(weth), address(usdc), 500);
        uint32[] memory ago = new uint32[](3);
        (ago[0], ago[1]) = (1800, 600);

        (, uint160[] memory perLiquidity) = p.observe(ago);
        assertEq(p.liquidity(), 1e18);
        assertEq(perLiquidity[0], (uint256(1_000_000_000 - 1800) << 128) / 1e18);
        assertEq(perLiquidity[2], (uint256(1_000_000_000) << 128) / 1e18);
        p.setLiquidity(0); // counted as one, like Uniswap
        (, perLiquidity) = p.observe(ago);
        assertEq(perLiquidity[1], uint256(1_000_000_000 - 600) << 128);

        p.setCumulatives(0, -1800);
        (int56[] memory cumulatives,) = p.observe(ago);
        assertEq(cumulatives[0], 0);
        assertEq(cumulatives[1], -1200, "points in between lie on the straight line");
        assertEq(cumulatives[2], -1800);

        p.setObservation(1800, 7, 11);
        p.setObservation(600, 8, 12);
        vm.expectRevert(bytes("NO OBSERVATION"));
        p.observe(ago);
        p.setObservation(0, 9, 13);
        assertTrue(p.rawObservations());
        assertFalse(p.rawCumulatives());
        (cumulatives, perLiquidity) = p.observe(ago);
        assertEq(cumulatives[1], 8);
        assertEq(perLiquidity[2], 13);

        p.setCumulatives(0, 1);
        assertFalse(p.rawObservations());
        p.setObservation(0, 9, 13);
        p.setTick(3);
        assertFalse(p.rawObservations());
        (cumulatives,) = p.observe(ago);
        assertEq(cumulatives[2] - cumulatives[0], 3 * 1800);
    }

    function test_uniswapPool_initializeOnceAndReserveObservations() public {
        MockUniswapV3Pool p = new MockUniswapV3Pool(address(weth), address(usdc), 500);
        p.initialize(1 << 96);
        (uint160 sqrtPriceX96,,,,,,) = p.slot0();
        assertEq(sqrtPriceX96, 1 << 96);
        vm.expectRevert(bytes("AI"));
        p.initialize(1);

        p.setSqrtPriceX96(2 << 96); // a swap moved the price
        (sqrtPriceX96,,,,,,) = p.slot0();
        assertEq(sqrtPriceX96, 2 << 96);

        p.increaseObservationCardinalityNext(200);
        assertEq(p.observationCardinalityNext(), 200);
        (,,,, uint16 next,,) = p.slot0();
        assertEq(next, 1_000, "the larger of the active and reserved slots");
        p.increaseObservationCardinalityNext(100); // never shrinks
        assertEq(p.observationCardinalityNext(), 200);
        p.setObservationCardinality(1);
        (,,,, next,,) = p.slot0();
        assertEq(next, 200);
    }

    // ---------------------------------------------------------------------
    // MockWETH and MockPositionManager
    // ---------------------------------------------------------------------

    function test_weth_depositWrapsEther() public {
        MockWETH w = new MockWETH();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        w.deposit{value: 0.4 ether}();
        assertEq(w.balanceOf(alice), 0.4 ether);
        assertEq(address(w).balance, 0.4 ether);
    }

    function test_positionManager_takesDesiredAmountsAndRecordsThem() public {
        MockPositionManager positions = new MockPositionManager();
        weth.mint(alice, 2e18);
        usdc.mint(alice, 3_000e6);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            tickLower: -60,
            tickUpper: 60,
            amount0Desired: 3_000e6,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: bob,
            deadline: 7
        });
        vm.startPrank(alice);
        usdc.approve(address(positions), 3_000e6);
        weth.approve(address(positions), 1e18);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positions.mint(params);
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(liquidity, 1);
        assertEq(amount0, 3_000e6);
        assertEq(amount1, 1e18);
        assertEq(positions.mints(), 1);
        assertEq(usdc.balanceOf(address(positions)), 3_000e6);
        assertEq(weth.balanceOf(alice), 1e18);
        INonfungiblePositionManager.MintParams memory recorded = positions.position(1);
        assertEq(recorded.tickLower, -60);
        assertEq(recorded.tickUpper, 60);
        assertEq(recorded.recipient, bob);
        assertEq(recorded.deadline, 7);
    }

    // ---------------------------------------------------------------------
    // MockMarket
    // ---------------------------------------------------------------------

    function _tickOf(MockUniswapV3Pool pool) internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function test_market_pricesAndConfigs() public {
        MockMarket m = new MockMarket();
        address mWeth = address(m.weth());
        MockUniswapV3Pool usdPool = m.usdPool();
        assertEq(m.uniswapV3Factory().getPool(address(m.usdc()), mWeth, 500), address(usdPool));
        int24 usdTick = address(m.usdc()) < mWeth ? m.USDC_TICK() : -m.USDC_TICK();
        assertEq(_tickOf(usdPool), usdTick);

        IIndexFactory.TokenConfig memory c = m.config(mWeth, 7);
        assertEq(c.pool, address(0));
        assertEq(c.referenceSupply, m.ETH_SUPPLY());

        // A token below WETH is token0, one above is token1; the market flips the tick for the latter.
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Low", "LOW", uint8(18)), address(0x1000));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("High", "HIGH", uint8(18)), address(type(uint160).max));
        address lowToken = address(0x1000);
        address highToken = address(type(uint160).max);

        assertEq(address(m.tokenPool(lowToken)), address(0));
        c = m.config(lowToken, 42);
        assertEq(c.pool, address(m.tokenPool(lowToken)));
        assertEq(c.referenceSupply, m.DEFAULT_SUPPLY());
        assertEq(_tickOf(MockUniswapV3Pool(c.pool)), 42);

        c = m.config(highToken, 42);
        assertEq(_tickOf(MockUniswapV3Pool(c.pool)), -42);

        address[] memory excluded = new address[](1);
        excluded[0] = alice;
        IIndexFactory.TokenConfig memory again = m.configWith(lowToken, -3, 0, excluded);
        assertEq(again.pool, address(m.tokenPool(lowToken)), "the pool is created once");
        assertEq(again.referenceSupply, 0);
        assertEq(again.excluded[0], alice);
        assertEq(_tickOf(MockUniswapV3Pool(again.pool)), -3);

        m.setPriceTick(highToken, 9);
        assertEq(_tickOf(m.tokenPool(highToken)), -9);
        m.setUsdcTick(1);
        assertEq(_tickOf(usdPool), address(m.usdc()) < mWeth ? int24(1) : int24(-1));
    }

    // ---------------------------------------------------------------------
    // RebalanceExecutorV3 (used by the fork tests), driven through the mock router
    // ---------------------------------------------------------------------

    function test_rebalanceExecutorV3_sellsBuysAndSettlesThroughARouter() public {
        MockMarket m = new MockMarket();
        IndexFactory f = new IndexFactory(
            address(this), address(0), address(m.weth()), address(m.uniswapV3Factory()), address(m.usdc())
        );
        MockERC20 shrinking = new MockERC20("Shrinking", "SHR", 18);
        MockERC20 growing = new MockERC20("Growing", "GRO", 18);
        MockERC20 mWeth = m.weth();
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(shrinking), address(mWeth), address(growing));

        // WETH and the growing token weigh ten times the shrinking one: it halves, and the other two gain 25% each.
        f.proposeListing(t[0], m.configWith(t[0], 0, 12e24, new address[](0)));
        f.proposeListing(t[1], m.config(t[1], 0));
        f.proposeListing(t[2], m.configWith(t[2], 0, 120e24, new address[](0)));
        vm.warp(block.timestamp + f.LISTING_DELAY());
        for (uint256 i = 0; i < 3; ++i) {
            f.executeListing(t[i]);
        }
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (100e18, 100e18, 100e18);
        IndexToken idx = IndexToken(f.createIndex("Executor", "EXEC", t, u, 0));
        shrinking.mint(address(this), 100e18);
        mWeth.mint(address(this), 100e18);
        growing.mint(address(this), 100e18);
        shrinking.approve(address(idx), 100e18);
        mWeth.approve(address(idx), 100e18);
        growing.approve(address(idx), 100e18);
        idx.issue(1e18, address(this));

        MockSwapRouter r = new MockSwapRouter();
        r.setPrice(address(shrinking), 1e18);
        r.setPrice(address(mWeth), 1e18);
        r.setPrice(address(growing), 1e18);
        mWeth.mint(address(r), 1_000e18);
        growing.mint(address(r), 1_000e18);

        RebalanceExecutorV3 executor = new RebalanceExecutorV3(f, r, address(mWeth));
        executor.setFee(address(shrinking), 3000);
        executor.setFee(address(growing), 3000);
        assertEq(executor.feeOf(address(growing)), 3000);

        vm.warp(idx.lastRebalance() + idx.MIN_REBALANCE_INTERVAL());
        idx.startRebalance(0);
        (uint256 eta,,) = idx.pendingRebalance();
        vm.warp(eta + idx.AUCTION_DURATION());
        executor.fill(idx);

        (, uint256[] memory units) = idx.components();
        assertEq(units[0], 50e18, "the shrinking component went to target");
        assertEq(units[1], 122.5e18, "WETH gained 90% of its extra units, delivered without a swap");
        assertEq(units[2], 122.5e18, "the growing component was bought with WETH");
        assertEq(mWeth.balanceOf(address(executor)), 5e18, "sold 50, spent 22.5 on the purchase and 22.5 on delivery");
        assertEq(shrinking.balanceOf(address(r)), 50e18);
    }

    function test_XA12_rebalanceExecutorV3_takesCallbacksOnlyFromTheIndexItFills() public {
        MockERC20 mWeth = new MockERC20("Wrapped Ether", "WETH", 18);
        RebalanceExecutorV3 executor =
            new RebalanceExecutorV3(IIndexFactory(makeAddr("factory")), new MockSwapRouter(), address(mWeth));
        mWeth.mint(address(executor), 10e18); // the operator's float

        // A contract posing as an index that holds only WETH asks for the whole float.
        address fake = makeAddr("fake index");
        vm.etch(fake, hex"00");
        address[] memory onlyWeth = new address[](1);
        onlyWeth[0] = address(mWeth);
        vm.mockCall(fake, abi.encodeWithSelector(IIndexToken.componentTokens.selector), abi.encode(onlyWeth));
        uint256[] memory nothing = new uint256[](1);
        uint256[] memory everything = new uint256[](1);
        everything[0] = 10e18;
        vm.prank(fake);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.UnexpectedCaller.selector, fake));
        executor.onXindexRebalance(nothing, everything, "");
        assertEq(mWeth.balanceOf(address(executor)), 10e18, "the float stays");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.NotOwner.selector, stranger));
        executor.setFee(address(mWeth), 3000);
    }

    /// @dev LR-04: the XA-12 check trusted whatever index `fill` was pointed at, and anyone could call `fill`. A
    ///      contract posing as an index then called back from its own `executeRebalance` and asked for the whole
    ///      float, which the executor paid. Only the deployer starts a fill now, and only on one of the factory's
    ///      indexes.
    function test_LR04_rebalanceExecutorV3_fillCannotBePointedAtAFakeIndex() public {
        MockMarket m = new MockMarket();
        IndexFactory f = new IndexFactory(
            address(this), address(0), address(m.weth()), address(m.uniswapV3Factory()), address(m.usdc())
        );
        MockERC20 mWeth = m.weth();
        RebalanceExecutorV3 executor = new RebalanceExecutorV3(f, new MockSwapRouter(), address(mWeth));
        mWeth.mint(address(executor), 10e18); // the operator's float
        FakeIndex fake = new FakeIndex(address(mWeth), address(executor));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.NotOwner.selector, stranger));
        executor.fill(IIndexToken(address(fake)));

        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.NotIndex.selector, address(fake)));
        executor.fill(IIndexToken(address(fake)));
        assertEq(mWeth.balanceOf(address(executor)), 10e18, "the float stays");

        // The fake does what the finding describes: without the two checks above, this callback emptied the float.
        vm.expectRevert(abi.encodeWithSelector(RebalanceExecutorV3.UnexpectedCaller.selector, address(fake)));
        fake.executeRebalance("");
    }
}

/// @dev Poses as an index whose only component is WETH: its `executeRebalance` calls the executor back and asks for
///      everything the executor holds.
contract FakeIndex {
    address internal immutable WETH;
    address internal immutable EXECUTOR;

    constructor(address weth, address executor) {
        WETH = weth;
        EXECUTOR = executor;
    }

    function executeRebalance(bytes calldata data) external {
        uint256[] memory nothing = new uint256[](1);
        uint256[] memory everything = new uint256[](1);
        everything[0] = MockERC20(WETH).balanceOf(EXECUTOR);
        RebalanceExecutorV3(EXECUTOR).onXindexRebalance(nothing, everything, data);
    }
}
