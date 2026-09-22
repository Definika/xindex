// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUSDT} from "./MockUSDT.sol";
import {MockSwapRouter} from "./MockSwapRouter.sol";
import {MockPausableToken} from "./MockPausableToken.sol";
import {MockPartialFillRouter} from "./MockPartialFillRouter.sol";
import {MockMarket, usdWad} from "./MockMarket.sol";
import {TestAggregator} from "../../script/testnet/TestAggregator.sol";
import {CompositeFeed} from "../../src/CompositeFeed.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IXindexErrors} from "../../src/interfaces/IXindexErrors.sol";
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

    /// @dev The mock pool records its starting price once, as the real one does.
    function test_uniswapPool_initializesOnlyOnce() public {
        MockUniswapV3Factory f = new MockUniswapV3Factory();
        MockUniswapV3Pool p = MockUniswapV3Pool(f.createPool(address(1), address(2), 500));
        p.initialize(1 << 96);
        assertEq(p.sqrtPriceX96(), 1 << 96);
        vm.expectRevert(bytes("AI"));
        p.initialize(2 << 96);
    }

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
    // MockMarket, TestAggregator and CompositeFeed
    // ---------------------------------------------------------------------

    function test_market_pricesAndConfigs() public {
        vm.warp(30 days);
        MockMarket m = new MockMarket();
        address mWeth = address(m.weth());

        IIndexFactory.TokenConfig memory c = m.config(mWeth, 3_000e8);
        assertEq(c.feed, address(m.feedOf(mWeth)), "the feed is created on first use");
        assertEq(c.maxStaleness, m.STALENESS());
        assertEq(c.referenceSupply, m.ETH_SUPPLY());
        assertEq(m.feedOf(mWeth).answer(), 3_000e8);

        MockERC20 token = new MockERC20("T", "T", 18);
        c = m.config(address(token), 42e8);
        assertEq(c.referenceSupply, m.DEFAULT_SUPPLY(), "anything but WETH gets the default supply");
        address feed = c.feed;

        IIndexFactory.TokenConfig memory again = m.configWith(address(token), 7e8, 0);
        assertEq(again.feed, feed, "the feed is created once");
        assertEq(again.referenceSupply, 0);
        assertEq(m.feedOf(address(token)).answer(), 7e8);

        m.movePrice(address(token), 3, 2);
        assertEq(m.feedOf(address(token)).answer(), 10.5e8);

        m.setAge(address(token), 900);
        (,,, uint256 updatedAt,) = m.feedOf(address(token)).latestRoundData();
        assertEq(updatedAt, block.timestamp - 900);

        assertEq(usdWad(1e8, 18), 1e18, "a dollar on an 18-decimal token");
        assertEq(usdWad(30_000e8, 8), 3e32);
    }

    /// @dev The two freshness modes: one that follows the block clock, so a test can warp weeks ahead and still read a
    ///      live feed, and one that pins a timestamp, as a real feed does between rounds.
    function test_testAggregator_bothFreshnessModes() public {
        vm.warp(30 days);
        TestAggregator feed = new TestAggregator("T / USD", 8, 5e8);
        assertEq(feed.description(), "T / USD");
        assertEq(feed.decimals(), 8);
        assertTrue(feed.fresh());

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 5e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredIn, 1);

        feed.setAnswer(6e8);
        feed.setAge(60);
        vm.warp(block.timestamp + 30 days);
        (, answer,, updatedAt,) = feed.latestRoundData();
        assertEq(answer, 6e8);
        assertEq(updatedAt, block.timestamp - 60, "still on the block clock after a long warp");

        feed.setUpdatedAt(1_000);
        assertFalse(feed.fresh());
        (,,, updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 1_000, "and pinned once a test says so");
    }

    function test_compositeFeed_multipliesAndBoundsEachLeg() public {
        vm.warp(30 days);
        TestAggregator a = new TestAggregator("BTC / USD", 8, 86_000e8);
        TestAggregator b = new TestAggregator("WBTC / BTC", 8, 0.9995e8);
        CompositeFeed composite = new CompositeFeed(a, b, 1 hours, 24 hours);

        assertEq(composite.decimals(), 8, "the first leg's decimals");
        assertEq(composite.description(), "BTC / USD * WBTC / BTC");
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            composite.latestRoundData();
        assertEq(answer, int256(86_000e8) * 0.9995e8 / 1e8);
        assertEq(roundId, 0, "two legs have no common round");
        assertEq(answeredIn, 0);
        assertEq(startedAt, updatedAt);

        // The older of the two timestamps is reported, so the rule's own bound still reaches the staler leg.
        b.setAge(600);
        (,,, updatedAt,) = composite.latestRoundData();
        assertEq(updatedAt, block.timestamp - 600);

        // Each leg is bounded where it is read: the fast leg's hour does not stretch to the slow leg's day.
        a.setAge(1 hours + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, address(a), block.timestamp - 1 hours - 1)
        );
        composite.latestRoundData();
        a.setAge(0);
        b.setAge(24 hours + 1);
        vm.expectRevert(
            abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, address(b), block.timestamp - 24 hours - 1)
        );
        composite.latestRoundData();
        b.setAge(0);

        // A future timestamp is a broken feed, not a fresh one.
        a.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.StaleLeg.selector, address(a), block.timestamp + 1));
        composite.latestRoundData();
        a.setAge(0);

        a.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.NonPositiveAnswer.selector, address(a), int256(0)));
        composite.latestRoundData();
        a.setAnswer(86_000e8);
        b.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.NonPositiveAnswer.selector, address(b), int256(-1)));
        composite.latestRoundData();
    }

    function test_compositeFeed_constructorChecks() public {
        TestAggregator a = new TestAggregator("BTC / USD", 8, 1e8);
        TestAggregator b = new TestAggregator("WBTC / BTC", 8, 1e8);
        uint32 tooLong = 2 days + 1;

        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new CompositeFeed(IAggregatorV3(address(0)), b, 1 hours, 1 hours);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new CompositeFeed(a, IAggregatorV3(address(0)), 1 hours, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, uint32(0)));
        new CompositeFeed(a, b, 0, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, tooLong));
        new CompositeFeed(a, b, tooLong, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, uint32(0)));
        new CompositeFeed(a, b, 1 hours, 0);
        vm.expectRevert(abi.encodeWithSelector(CompositeFeed.InvalidLegStaleness.selector, tooLong));
        new CompositeFeed(a, b, 1 hours, tooLong);
    }

    // ---------------------------------------------------------------------
    // RebalanceExecutorV3 (used by the fork tests), driven through the mock router
    // ---------------------------------------------------------------------

    function test_rebalanceExecutorV3_sellsBuysAndSettlesThroughARouter() public {
        MockMarket m = new MockMarket();
        IndexFactory f = new IndexFactory(address(this), address(0));
        MockERC20 shrinking = new MockERC20("Shrinking", "SHR", 18);
        MockERC20 growing = new MockERC20("Growing", "GRO", 18);
        MockERC20 mWeth = m.weth();
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(shrinking), address(mWeth), address(growing));

        // WETH and the growing token weigh ten times the shrinking one: it halves, and the other two gain 25% each.
        f.proposeListing(t[0], m.configWith(t[0], 1e8, 12e24));
        f.proposeListing(t[1], m.config(t[1], 1e8));
        f.proposeListing(t[2], m.configWith(t[2], 1e8, 120e24));
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
        IndexFactory f = new IndexFactory(address(this), address(0));
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
