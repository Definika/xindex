// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {BasketBuilder} from "../src/BasketBuilder.sol";
import {IBasketBuilder} from "../src/interfaces/IBasketBuilder.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {PathKey} from "../src/libraries/UniswapV4Types.sol";

/// @notice The basket builder: an escrow per caller that the legs of a basket are bought into over several calls and
///         issued out of in one, and the mirror of it for selling. Routes and prices come from the mock router the
///         zap's suite uses; every amount expected here is a balance the test can see.
contract BasketBuilderTest is XindexTest {
    BasketBuilder builder;
    MockUniversalRouter router;
    address poolManager;
    WeightedHub index;
    WeightedHub stableIndex;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 link; // 18
    MockERC20 usdc; // 6

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // 0.001 WBTC ($60) + 0.01 WETH ($30) + 1 LINK ($15) = $105 per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_LINK = 1e18;
    uint256 constant U_USDC = 50e6;
    uint24 constant FEE = 500;
    uint256 constant TX_GAS_CAP = 1 << 24;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(address(0));
        poolManager = makeAddr("poolManager");
        router = new MockUniversalRouter(poolManager);
        builder = new BasketBuilder(IIndexFactory(address(factory)), router);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = market.usdc();

        router.setPrice(address(wbtc), 60_000e18, 8);
        router.setPrice(address(weth), 3_000e18, 18);
        router.setPrice(address(link), 15e18, 18);
        router.setPrice(address(usdc), 1e18, 6);
        wbtc.mint(address(router.inventory()), 1_000e8);
        weth.mint(address(router.inventory()), 100_000e18);
        link.mint(address(router.inventory()), 10_000_000e18);
        usdc.mint(address(router.inventory()), 1_000_000_000e6);

        _listWith(address(wbtc));
        _listWith(address(weth));
        _listWith(address(link));
        _listWith(address(usdc));

        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(wbtc), address(weth), address(link));
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (U_WBTC, U_WETH, U_LINK);
        index = _createIndex("Blue Chip", "BLUE", t, u);
        stableIndex = _createIndex("Stable", "STB", _pair(address(weth), address(usdc)), _pair(U_WETH, U_USDC));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _noV4() internal pure returns (PathKey[] memory) {
        return new PathKey[](0);
    }

    function _hop(address currency) internal pure returns (PathKey memory) {
        return PathKey({intermediateCurrency: currency, fee: FEE, tickSpacing: 10, hooks: address(0), hookData: ""});
    }

    function _v4Path1(address other) internal pure returns (PathKey[] memory path) {
        path = new PathKey[](1);
        path[0] = _hop(other);
    }

    function _path2(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b);
    }

    function _path3(address a, address b, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b, FEE, c);
    }

    function _mintLeg(bytes memory v3Path) internal pure returns (IUniversalRouterSwaps.MintLeg memory) {
        return IUniversalRouterSwaps.MintLeg({v3Path: v3Path, v4Path: _noV4(), maxAmountIn: 0});
    }

    function _burnLeg(bytes memory v3Path, uint256 minOut)
        internal
        pure
        returns (IUniversalRouterSwaps.BurnLeg memory)
    {
        return IUniversalRouterSwaps.BurnLeg({v3Path: v3Path, v4Path: _noV4(), minAmountOut: minOut});
    }

    /// @dev The index's three legs from usdc: WBTC through WETH, WETH, LINK through WETH.
    function _legFor(uint256 component) internal view returns (IUniversalRouterSwaps.MintLeg memory) {
        if (component == 0) return _mintLeg(_path3(address(wbtc), address(weth), address(usdc)));
        if (component == 1) return _mintLeg(_path2(address(weth), address(usdc)));
        return _mintLeg(_path3(address(link), address(weth), address(usdc)));
    }

    function _one(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _buyParams(WeightedHub idx, uint256 shares, address tokenIn, uint256 maxIn, uint256[] memory components)
        internal
        view
        returns (IBasketBuilder.BuyParams memory p)
    {
        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](components.length);
        for (uint256 k = 0; k < components.length; ++k) {
            legs[k] = _legFor(components[k]);
        }
        p = IBasketBuilder.BuyParams({
            index: address(idx),
            expectedNonce: 0,
            shares: shares,
            tokenIn: tokenIn,
            maxAmountIn: maxIn,
            components: components,
            legs: legs,
            deadline: block.timestamp
        });
    }

    function _sellParams(address tokenOut, uint256 minOut, address[] memory tokens, address to)
        internal
        view
        returns (IBasketBuilder.SellParams memory p)
    {
        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](tokens.length);
        for (uint256 k = 0; k < tokens.length; ++k) {
            legs[k] = tokens[k] == address(weth)
                ? _burnLeg(_path2(address(weth), tokenOut), 0)
                : _burnLeg(_path3(tokens[k], address(weth), tokenOut), 0);
        }
        p = IBasketBuilder.SellParams({
            tokenOut: tokenOut,
            minAmountOut: minOut,
            tokens: tokens,
            amounts: new uint256[](tokens.length),
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    /// @dev Buys the named legs for `who` with `maxIn` usdc and returns what it spent.
    function _buyFor(address who, uint256 shares, uint256 maxIn, uint256[] memory components)
        internal
        returns (uint256 spent)
    {
        usdc.mint(who, maxIn);
        vm.startPrank(who);
        usdc.approve(address(builder), maxIn);
        spent = builder.buy(_buyParams(index, shares, address(usdc), maxIn, components));
        vm.stopPrank();
    }

    function _all() internal pure returns (uint256[] memory components) {
        components = new uint256[](3);
        (components[0], components[1], components[2]) = (0, 1, 2);
    }

    /// @dev Puts the whole basket for `shares` into `who`'s escrow by deposit.
    function _depositBasket(address who, uint256 shares) internal {
        address[] memory tokens = index.componentTokens();
        uint256[] memory need = index.previewIssue(shares);
        vm.startPrank(who);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            MockERC20(tokens[i]).approve(address(builder), need[i]);
            builder.deposit(tokens[i], need[i]);
        }
        vm.stopPrank();
    }

    /// @dev Mints `shares` of the index straight to `who`.
    function _issueTo(address who, uint256 shares) internal {
        address[] memory tokens = index.componentTokens();
        uint256[] memory need = index.previewIssue(shares);
        vm.startPrank(who);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, need[i]);
            MockERC20(tokens[i]).approve(address(index), need[i]);
        }
        index.issue(shares, who);
        vm.stopPrank();
    }

    /// @dev Redeems `shares` of the index from `who` into its escrow.
    function _redeemFor(address who, uint256 shares) internal {
        _issueTo(who, shares);
        vm.startPrank(who);
        index.approve(address(builder), shares);
        builder.redeem(address(index), shares);
        vm.stopPrank();
    }

    function _assertCovered(address token) internal view {
        assertGe(
            IERC20(token).balanceOf(address(builder)),
            builder.escrowOf(alice, token) + builder.escrowOf(bob, token),
            "the builder holds every escrow"
        );
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_constructorWiresTheRouterAndRefusesZeroes() public {
        assertEq(address(builder.FACTORY()), address(factory));
        assertEq(address(builder.ROUTER()), address(router));
        assertEq(builder.POOL_MANAGER(), poolManager);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new BasketBuilder(IIndexFactory(address(0)), router);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new BasketBuilder(IIndexFactory(address(factory)), IUniversalRouter(address(0)));
    }

    // ---------------------------------------------------------------------
    // Escrow
    // ---------------------------------------------------------------------

    function test_depositCreditsWhatArrived() public {
        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(builder), 1e18);
        vm.expectEmit(address(builder));
        emit IBasketBuilder.Deposited(alice, address(weth), 1e18);
        builder.deposit(address(weth), 1e18);
        assertEq(builder.escrowOf(alice, address(weth)), 1e18);

        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.deposit(address(weth), 0);
        vm.stopPrank();

        // A fee-on-transfer token credits what came, not what was sent.
        MockFeeToken fot = new MockFeeToken();
        fot.mint(alice, 100e18);
        vm.startPrank(alice);
        fot.approve(address(builder), 100e18);
        builder.deposit(address(fot), 100e18);
        vm.stopPrank();
        assertEq(builder.escrowOf(alice, address(fot)), 99e18);
        assertEq(fot.balanceOf(address(builder)), 99e18);
    }

    function test_withdrawTakesPartOrAll() public {
        weth.mint(alice, 3e18);
        vm.startPrank(alice);
        weth.approve(address(builder), 3e18);
        builder.deposit(address(weth), 3e18);

        vm.expectEmit(address(builder));
        emit IBasketBuilder.Withdrawn(alice, address(weth), bob, 1e18);
        builder.withdraw(address(weth), 1e18, bob);
        assertEq(weth.balanceOf(bob), 1e18);
        assertEq(builder.escrowOf(alice, address(weth)), 2e18);

        vm.expectRevert(abi.encodeWithSelector(IBasketBuilder.InsufficientEscrow.selector, address(weth), 2e18, 3e18));
        builder.withdraw(address(weth), 3e18, alice);

        builder.withdraw(address(weth), 0, alice);
        assertEq(weth.balanceOf(alice), 2e18);
        assertEq(builder.escrowOf(alice, address(weth)), 0);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.withdraw(address(weth), 0, alice);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(builder)), 0);
    }

    function test_withdrawRefusesTrapRecipients() public {
        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(builder), 1e18);
        builder.deposit(address(weth), 1e18);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        builder.withdraw(address(weth), 1, address(0));
        address[5] memory traps = [address(builder), address(router), poolManager, address(factory), address(index)];
        for (uint256 i = 0; i < traps.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, traps[i]));
            builder.withdraw(address(weth), 1, traps[i]);
        }
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Buying
    // ---------------------------------------------------------------------

    function test_buyBuysTheNamedLegsIntoTheEscrowAndRefundsTheRest() public {
        uint256[] memory need = index.previewIssue(1e18);
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(builder), 200e6);
        vm.expectEmit(true, true, false, false, address(builder));
        emit IBasketBuilder.Bought(alice, address(index), address(usdc), 0, 1e18);
        uint256 spent = builder.buy(_buyParams(index, 1e18, address(usdc), 200e6, _pair(0, 1)));
        vm.stopPrank();

        assertEq(builder.escrowOf(alice, address(wbtc)), need[0]);
        assertEq(builder.escrowOf(alice, address(weth)), need[1]);
        assertEq(builder.escrowOf(alice, address(link)), 0);
        assertGt(spent, 0);
        assertEq(usdc.balanceOf(alice), 200e6 - spent, "the unspent part came back");
        assertEq(usdc.balanceOf(address(builder)), 0);
        assertEq(usdc.balanceOf(address(router)), 0, "the router is swept clean");
        assertEq(wbtc.balanceOf(address(builder)), need[0]);
        assertEq(weth.balanceOf(address(builder)), need[1]);

        // The third leg in a second call, then the basket is complete.
        uint256 more = _buyFor(alice, 1e18, 200e6, _one(2));
        assertEq(builder.escrowOf(alice, address(link)), need[2]);
        assertGt(more, 0);
        assertEq(usdc.balanceOf(alice), 400e6 - spent - more);
    }

    function test_buyALegTheEscrowCoversIsSkipped() public {
        _buyFor(alice, 1e18, 200e6, _all());
        uint256[] memory need = index.previewIssue(1e18);
        uint256 before = usdc.balanceOf(alice);
        uint256 spent = _buyFor(alice, 1e18, 200e6, _all());
        assertEq(spent, 0, "nothing to buy, nothing spent");
        assertEq(usdc.balanceOf(alice), before + 200e6, "all of it came back");
        assertEq(builder.escrowOf(alice, address(wbtc)), need[0]);
        assertEq(builder.escrowOf(alice, address(weth)), need[1]);
        assertEq(builder.escrowOf(alice, address(link)), need[2]);
    }

    function test_buyTopsUpALegTheEscrowPartlyCovers() public {
        uint256[] memory need = index.previewIssue(1e18);
        uint256 half = need[2] / 2;
        link.mint(alice, half);
        vm.startPrank(alice);
        link.approve(address(builder), half);
        builder.deposit(address(link), half);
        vm.stopPrank();

        uint256 full = _buyFor(bob, 1e18, 200e6, _one(2));
        uint256 topUp = _buyFor(alice, 1e18, 200e6, _one(2));
        assertEq(builder.escrowOf(alice, address(link)), need[2]);
        assertGt(topUp, 0);
        assertLt(topUp, full, "only the missing half was bought");
        _assertCovered(address(link));
    }

    function test_buyKeepsTheTokenInComponentOutOfTheRefund() public {
        uint256[] memory need = stableIndex.previewIssue(1e18);
        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](2);
        legs[0] = _mintLeg(_path2(address(weth), address(usdc)));
        legs[1] = _mintLeg("");
        IBasketBuilder.BuyParams memory p = _buyParams(stableIndex, 1e18, address(usdc), 200e6, _pair(0, 1));
        p.legs = legs;

        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(builder), 200e6);
        uint256 spent = builder.buy(p);
        assertEq(builder.escrowOf(alice, address(usdc)), need[1]);
        assertEq(builder.escrowOf(alice, address(weth)), need[0]);
        assertEq(usdc.balanceOf(address(builder)), need[1], "the basket's own usdc stays, the rest went back");
        assertEq(spent, need[1] + router.quoteIn(address(usdc), address(weth), need[0]));
        assertEq(usdc.balanceOf(alice), 200e6 - spent);

        // The pass-through leg names no route and honours its own cap and the overall one (DA-15).
        builder.withdraw(address(usdc), 0, alice);
        usdc.mint(alice, 200e6);
        usdc.approve(address(builder), 200e6);
        p.legs[1] = _mintLeg(_path2(address(usdc), address(usdc)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        builder.buy(p);
        p.legs[1] = _mintLeg("");
        p.legs[1].maxAmountIn = need[1] - 1;
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientBudget.selector, need[1], need[1] - 1));
        builder.buy(p);
        p.legs[1].maxAmountIn = 0;
        p.maxAmountIn = need[1] - 1;
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientBudget.selector, need[1], need[1] - 1));
        builder.buy(p);
        vm.stopPrank();
    }

    function test_buyChecksTheCall() public {
        IBasketBuilder.BuyParams memory p = _buyParams(index, 1e18, address(usdc), 200e6, _all());
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(builder), 200e6);

        p.deadline = block.timestamp - 1;
        vm.expectRevert(IXindexErrors.Expired.selector);
        builder.buy(p);
        p.deadline = block.timestamp;

        p.index = address(weth);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(weth)));
        builder.buy(p);
        p.index = address(index);

        p.expectedNonce = 1;
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 1, 0));
        builder.buy(p);
        p.expectedNonce = 0;

        p.tokenIn = address(0);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        builder.buy(p);
        p.tokenIn = address(usdc);

        p.shares = 0;
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.buy(p);
        p.shares = 1e18;
        p.maxAmountIn = 0;
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.buy(p);
        p.maxAmountIn = 200e6;

        p.components = _pair(0, 1);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        builder.buy(p);
        p.components = _all();
        p.components[2] = 3;
        vm.expectRevert(abi.encodeWithSelector(IBasketBuilder.ComponentOutOfRange.selector, 3));
        builder.buy(p);
        vm.stopPrank();
    }

    function test_buyRefusesAFeeOnTransferTokenIn() public {
        MockFeeToken fot = new MockFeeToken();
        router.setPrice(address(fot), 1e18, 18);
        fot.mint(alice, 300e18);
        IBasketBuilder.BuyParams memory p = _buyParams(index, 1e18, address(fot), 300e18, _one(1));
        p.legs[0] = _mintLeg(_path2(address(weth), address(fot)));
        vm.startPrank(alice);
        fot.approve(address(builder), 300e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TransferShortfall.selector, address(fot)));
        builder.buy(p);
        vm.stopPrank();
    }

    function test_buyRevertsOnAShortFillAndABadRoute() public {
        uint256[] memory need = index.previewIssue(1e18);
        IBasketBuilder.BuyParams memory p = _buyParams(index, 1e18, address(usdc), 200e6, _all());
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(builder), 200e6);

        router.setMode(MockUniversalRouter.Mode.UnderDeliverExactOut);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.ShortFill.selector, 0, need[0] - 1, need[0]));
        builder.buy(p);
        router.setMode(MockUniversalRouter.Mode.Normal);

        // Both venues, neither, the wrong far end, a hooked V4 route: each named by the leg's position in the call.
        p.legs[1].v4Path = _v4Path1(address(usdc));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        builder.buy(p);
        p.legs[1] = _mintLeg("");
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        builder.buy(p);
        p.legs[1] = _mintLeg(_path2(address(weth), address(link)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        builder.buy(p);
        p.legs[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), maxAmountIn: 0});
        p.legs[1].v4Path[0].hooks = address(1);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        builder.buy(p);

        // A leg's own cap binds the router's pre-fund, so a cap too small cannot complete the swap.
        p.legs[1] = _mintLeg(_path2(address(weth), address(usdc)));
        p.legs[1].maxAmountIn = 1;
        vm.expectRevert();
        builder.buy(p);
        vm.stopPrank();
    }

    function test_buyWithAV4Leg() public {
        uint256[] memory need = index.previewIssue(1e18);
        IBasketBuilder.BuyParams memory p = _buyParams(index, 1e18, address(usdc), 200e6, _one(1));
        p.legs[0] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), maxAmountIn: 0});
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(builder), 200e6);
        uint256 spent = builder.buy(p);
        vm.stopPrank();
        assertEq(builder.escrowOf(alice, address(weth)), need[1]);
        assertEq(spent, router.quoteIn(address(usdc), address(weth), need[1]));
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------

    function test_mintIssuesOutOfTheEscrowAndLeavesTheRest() public {
        _depositBasket(alice, 2e18);
        uint256[] memory need = index.previewIssue(1e18);
        uint256[] memory held = index.previewIssue(2e18);

        vm.prank(alice);
        vm.expectEmit(address(builder));
        emit IBasketBuilder.Minted(alice, address(index), bob, 1e18);
        builder.mint(address(index), 1e18, bob, address(0), block.timestamp);

        assertEq(index.balanceOf(bob), 1e18);
        assertEq(builder.escrowOf(alice, address(wbtc)), held[0] - need[0]);
        assertEq(builder.escrowOf(alice, address(weth)), held[1] - need[1]);
        assertEq(builder.escrowOf(alice, address(link)), held[2] - need[2]);
        assertEq(wbtc.allowance(address(builder), address(index)), 0, "the index pulled exactly what was approved");
        _assertCovered(address(wbtc));
        _assertCovered(address(weth));
        _assertCovered(address(link));

        // The rest issues too, and then the escrow is empty.
        vm.prank(alice);
        builder.mint(address(index), 1e18, alice, address(0), block.timestamp);
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(builder.escrowOf(alice, address(link)), 0);
        assertEq(link.balanceOf(address(builder)), 0);
    }

    function test_mintNamesTheShortLeg() public {
        _buyFor(alice, 1e18, 200e6, _pair(0, 1));
        uint256[] memory need = index.previewIssue(1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBasketBuilder.InsufficientEscrow.selector, address(link), 0, need[2]));
        builder.mint(address(index), 1e18, alice, address(0), block.timestamp);

        // One more buy completes it.
        _buyFor(alice, 1e18, 200e6, _one(2));
        vm.prank(alice);
        builder.mint(address(index), 1e18, alice, address(0), block.timestamp);
        assertEq(index.balanceOf(alice), 1e18);
    }

    function test_mintChecksTheCall() public {
        _depositBasket(alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.Expired.selector);
        builder.mint(address(index), 1e18, alice, address(0), block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(weth)));
        builder.mint(address(weth), 1e18, alice, address(0), block.timestamp);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.mint(address(index), 0, alice, address(0), block.timestamp);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        builder.mint(address(index), 1e18, address(0), address(0), block.timestamp);
        address[5] memory traps =
            [address(builder), address(router), poolManager, address(factory), address(stableIndex)];
        for (uint256 i = 0; i < traps.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, traps[i]));
            builder.mint(address(index), 1e18, traps[i], address(0), block.timestamp);
        }
        vm.stopPrank();
    }

    function test_mintPassesTheReferrerAndRespectsTheGate() public {
        address platform = makeAddr("platform");
        address referrer = makeAddr("referrer");
        vm.prank(owner);
        factory.setFeePolicy(25, 0, 5000, platform, 0);
        IWeightedIndexFactory.IndexParams memory params = _params();
        params.gated = true;
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(wbtc), address(weth), address(link));
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (U_WBTC, U_WETH, U_LINK);
        WeightedHub gated = WeightedHub(factory.createIndex("Gated", "GATE", _specs(t, u), params));

        uint256[] memory need = gated.previewIssue(1e18);
        vm.startPrank(alice);
        for (uint256 i = 0; i < t.length; ++i) {
            MockERC20(t[i]).mint(alice, need[i]);
            MockERC20(t[i]).approve(address(builder), need[i]);
            builder.deposit(t[i], need[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(IWeightedHub.NotAllowedMinter.selector, alice));
        builder.mint(address(gated), 1e18, alice, referrer, block.timestamp);
        vm.stopPrank();

        factory.setAllowedMinter(address(gated), alice, true);
        vm.prank(alice);
        builder.mint(address(gated), 1e18, alice, referrer, block.timestamp);
        assertEq(gated.balanceOf(alice), 1e18);
        assertGt(gated.balanceOf(referrer), 0, "the referrer took its share of the platform's fee");
        assertEq(gated.balanceOf(referrer), gated.balanceOf(platform));
    }

    // ---------------------------------------------------------------------
    // Redeeming and selling
    // ---------------------------------------------------------------------

    function test_redeemCreditsEveryComponentAsItArrives() public {
        _issueTo(alice, 2e18);
        uint256[] memory got = index.previewRedeem(1e18);
        vm.startPrank(alice);
        index.approve(address(builder), 1e18);
        vm.expectEmit(address(builder));
        emit IBasketBuilder.Redeemed(alice, address(index), 1e18);
        builder.redeem(address(index), 1e18);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(builder.escrowOf(alice, address(wbtc)), got[0]);
        assertEq(builder.escrowOf(alice, address(weth)), got[1]);
        assertEq(builder.escrowOf(alice, address(link)), got[2]);
        assertEq(wbtc.balanceOf(address(builder)), got[0]);

        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.redeem(address(index), 0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(weth)));
        builder.redeem(address(weth), 1e18);
    }

    function test_sellSellsTheNamedLegsAndPaysTheRecipient() public {
        _redeemFor(alice, 1e18);
        uint256[] memory got = index.previewRedeem(1e18);
        IBasketBuilder.SellParams memory p = _sellParams(address(usdc), 1, _pair(address(wbtc), address(weth)), bob);
        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(builder));
        emit IBasketBuilder.Sold(alice, bob, address(usdc), 0);
        uint256 amountOut = builder.sell(p);
        assertGt(amountOut, 0);
        assertEq(usdc.balanceOf(bob), amountOut);
        assertEq(builder.escrowOf(alice, address(wbtc)), 0);
        assertEq(builder.escrowOf(alice, address(weth)), 0);
        assertEq(builder.escrowOf(alice, address(link)), got[2], "the leg not named stays");
        assertEq(usdc.balanceOf(address(builder)), 0);
        assertEq(wbtc.balanceOf(address(router)), 0);

        // The leg left sells on its own, against the overall minimum.
        p = _sellParams(address(usdc), type(uint256).max, _one(address(link)), bob);
        vm.prank(alice);
        vm.expectRevert();
        builder.sell(p);
        p.minAmountOut = 1;
        vm.prank(alice);
        amountOut = builder.sell(p);
        assertEq(usdc.balanceOf(bob), usdc.balanceOf(bob));
        assertEq(builder.escrowOf(alice, address(link)), 0);
        assertEq(link.balanceOf(address(builder)), 0);
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function test_sellPartOfALeg() public {
        _redeemFor(alice, 1e18);
        uint256 held = builder.escrowOf(alice, address(weth));
        IBasketBuilder.SellParams memory p = _sellParams(address(usdc), 1, _one(address(weth)), alice);
        p.amounts[0] = held / 2;
        vm.prank(alice);
        uint256 amountOut = builder.sell(p);
        assertEq(amountOut, router.quoteOut(address(weth), address(usdc), held / 2));
        assertEq(builder.escrowOf(alice, address(weth)), held - held / 2);
        _assertCovered(address(weth));
    }

    function test_sellPaysAPassThroughLegAsItIs() public {
        _redeemFor(alice, 1e18);
        uint256[] memory got = index.previewRedeem(1e18);
        IBasketBuilder.SellParams memory p = _sellParams(address(weth), 1, _pair(address(wbtc), address(weth)), bob);
        p.legs[0] = _burnLeg(_path2(address(wbtc), address(weth)), 0);
        p.legs[1] = _burnLeg("", got[1]);
        vm.prank(alice);
        uint256 amountOut = builder.sell(p);
        assertEq(amountOut, got[1] + router.quoteOut(address(wbtc), address(weth), got[0]));
        assertEq(weth.balanceOf(bob), amountOut);
        assertEq(builder.escrowOf(alice, address(weth)), 0);

        // The pass-through leg names no route and honours its own minimum (DA-15).
        _redeemFor(alice, 1e18);
        p.legs[1] = _burnLeg(_path2(address(weth), address(weth)), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        builder.sell(p);
        p.legs[1] = _burnLeg("", got[1] + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientOutput.selector, got[1], got[1] + 1));
        builder.sell(p);
    }

    function test_sellCreditsUnsoldInputBackToTheEscrow() public {
        _redeemFor(alice, 1e18);
        uint256 held = builder.escrowOf(alice, address(wbtc));
        router.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        IBasketBuilder.SellParams memory p = _sellParams(address(usdc), 1, _one(address(wbtc)), bob);
        vm.prank(alice);
        vm.expectEmit(address(builder));
        emit IBasketBuilder.Unsold(alice, address(wbtc), held - held / 2);
        uint256 amountOut = builder.sell(p);
        assertGt(amountOut, 0);
        assertEq(builder.escrowOf(alice, address(wbtc)), held - held / 2, "what the hop did not take is hers again");
        assertEq(wbtc.balanceOf(address(builder)), held - held / 2);
        assertEq(wbtc.balanceOf(address(router)), 0);
        _assertCovered(address(wbtc));
    }

    function test_sellAV4Leg() public {
        _redeemFor(alice, 1e18);
        uint256 held = builder.escrowOf(alice, address(weth));
        IBasketBuilder.SellParams memory p = _sellParams(address(usdc), 1, _one(address(weth)), bob);
        p.legs[0] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), minAmountOut: 0});
        vm.prank(alice);
        uint256 amountOut = builder.sell(p);
        assertEq(amountOut, router.quoteOut(address(weth), address(usdc), held));
        assertEq(usdc.balanceOf(bob), amountOut);
        assertEq(builder.escrowOf(alice, address(weth)), 0);
    }

    function test_sellChecksTheCall() public {
        _redeemFor(alice, 1e18);
        IBasketBuilder.SellParams memory p = _sellParams(address(usdc), 1, _one(address(weth)), bob);
        vm.startPrank(alice);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(IXindexErrors.Expired.selector);
        builder.sell(p);
        p.deadline = block.timestamp;

        p.to = address(0);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        builder.sell(p);
        p.to = address(index);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        builder.sell(p);
        p.to = bob;

        p.tokenOut = address(0);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        builder.sell(p);
        p.tokenOut = address(usdc);

        p.minAmountOut = 0;
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.sell(p);
        p.minAmountOut = 1;

        p.amounts = new uint256[](2);
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        builder.sell(p);
        p.amounts = new uint256[](1);
        p.tokens = _pair(address(weth), address(wbtc));
        vm.expectRevert(IXindexErrors.LengthMismatch.selector);
        builder.sell(p);
        p.tokens = _one(address(weth));

        p.amounts[0] = builder.escrowOf(alice, address(weth)) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketBuilder.InsufficientEscrow.selector,
                address(weth),
                builder.escrowOf(alice, address(weth)),
                builder.escrowOf(alice, address(weth)) + 1
            )
        );
        builder.sell(p);
        p.amounts[0] = 0;

        p.tokens = _one(address(usdc));
        p.legs[0] = _burnLeg("", 0);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        builder.sell(p);
        vm.stopPrank();
    }

    function test_sellRefusesAFeeOnTransferPayout() public {
        MockFeeToken fot = new MockFeeToken();
        router.setPrice(address(fot), 1e18, 18);
        fot.mint(address(router.inventory()), 1_000_000e18);
        _redeemFor(alice, 1e18);
        IBasketBuilder.SellParams memory p = _sellParams(address(fot), 1, _one(address(weth)), bob);
        p.legs[0] = _burnLeg(_path2(address(weth), address(fot)), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TransferShortfall.selector, address(fot)));
        builder.sell(p);
    }

    // ---------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------

    function test_theGuardHoldsThroughAWithdrawal() public {
        MockHookToken hook = new MockHookToken();
        BuilderReenterer probe = new BuilderReenterer(builder);
        hook.mint(address(probe), 2e18);
        probe.deposit(hook, 2e18);
        assertEq(builder.escrowOf(address(probe), address(hook)), 2e18);

        probe.run(
            abi.encodeCall(IBasketBuilder.withdraw, (address(hook), 1e18, address(probe))),
            abi.encodeCall(IBasketBuilder.withdraw, (address(hook), 1e18, address(probe)))
        );
        assertTrue(probe.armedAndFired(), "the callback reached the probe inside the outer call");
        assertFalse(probe.nestedSucceeded(), "the nested call did not run");
        assertEq(bytes4(probe.nestedError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(builder.escrowOf(address(probe), address(hook)), 1e18, "only the outer withdrawal happened");
    }

    // ---------------------------------------------------------------------
    // Gas
    // ---------------------------------------------------------------------

    /// @dev A hundred-leg basket, beyond what one zap transaction can swap, is bought in three calls and issued in
    ///      one, each under EIP-7825's cap with every account cold. The mock router swaps for far less than a real
    ///      pool, so the buys' figures are a floor; the mint's is the builder's own work and the index's.
    function test_aHundredLegBasketFitsInThreeBuysAndAMint() public {
        uint256 n = 100;
        address[] memory tokens = new address[](n);
        uint256[] memory units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            tokens[i] = address(token);
            units[i] = 1e18;
            router.setPrice(address(token), 1e18, 18);
            token.mint(address(router.inventory()), 1_000_000e18);
            _listWith(address(token));
        }
        WeightedHub wide = _createIndex("Wide", "WIDE", tokens, units);

        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(builder), 1_000e6);
        uint256 from = 0;
        uint256[3] memory batch = [uint256(34), 33, 33];
        for (uint256 b = 0; b < 3; ++b) {
            uint256[] memory components = new uint256[](batch[b]);
            IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](batch[b]);
            for (uint256 k = 0; k < batch[b]; ++k) {
                components[k] = from + k;
                legs[k] = _mintLeg(_path2(tokens[from + k], address(usdc)));
            }
            from += batch[b];
            IBasketBuilder.BuyParams memory p = IBasketBuilder.BuyParams({
                index: address(wide),
                expectedNonce: 0,
                shares: 2e18,
                tokenIn: address(usdc),
                maxAmountIn: 300e6,
                components: components,
                legs: legs,
                deadline: block.timestamp
            });
            bytes memory data = abi.encodeCall(IBasketBuilder.buy, (p));
            _coolAll(tokens, address(wide));
            uint256 before = gasleft();
            vm.prank(alice);
            (bool ok,) = address(builder).call(data);
            uint256 used = before - gasleft();
            assertTrue(ok, "buy");
            assertLt(used, TX_GAS_CAP, "buy");
        }
        for (uint256 i = 0; i < n; ++i) {
            assertEq(builder.escrowOf(alice, tokens[i]), 2e18);
        }

        bytes memory mintData =
            abi.encodeCall(IBasketBuilder.mint, (address(wide), 2e18, alice, address(0), block.timestamp));
        _coolAll(tokens, address(wide));
        uint256 start = gasleft();
        vm.prank(alice);
        (bool minted,) = address(builder).call(mintData);
        uint256 mintGas = start - gasleft();
        assertTrue(minted, "mint");
        assertLt(mintGas, TX_GAS_CAP, "mint");
        assertEq(wide.balanceOf(alice), 2e18);
    }

    function _coolAll(address[] memory tokens, address hub) private {
        for (uint256 i = 0; i < tokens.length; ++i) {
            vm.cool(tokens[i]);
        }
        vm.cool(address(factory));
        vm.cool(address(builder));
        vm.cool(address(router));
        vm.cool(address(usdc));
        if (hub != address(0)) vm.cool(hub);
    }
}

/// @dev Holds a hook token's escrow and, when a withdrawal to it fires the token's callback, tries one more call on
///      the builder from inside it.
contract BuilderReenterer is ITokenReceiverHook {
    BasketBuilder internal immutable BUILDER;
    bytes internal _nested;
    bool internal _armed;
    bool public armedAndFired;
    bool public nestedSucceeded;
    bytes public nestedError;

    constructor(BasketBuilder builder) {
        BUILDER = builder;
    }

    function deposit(IERC20 token, uint256 amount) external {
        token.approve(address(BUILDER), amount);
        BUILDER.deposit(address(token), amount);
    }

    function run(bytes calldata outer, bytes calldata nested) external {
        _nested = nested;
        _armed = true;
        Address.functionCall(address(BUILDER), outer);
    }

    function onTokenReceived(address from, uint256) external {
        if (!_armed || from != address(BUILDER)) return;
        _armed = false;
        armedAndFired = true;
        (nestedSucceeded, nestedError) = address(BUILDER).call(_nested);
    }
}
