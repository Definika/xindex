// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {BasketBuilder} from "../src/BasketBuilder.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IBasketBuilder} from "../src/interfaces/IBasketBuilder.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {IAeroMetarouter} from "../src/interfaces/IAeroMetarouter.sol";
import {AeroCommands} from "../src/libraries/AeroCommands.sol";
import {UniversalRouterCommands} from "../src/libraries/UniversalRouterCommands.sol";
import {PathKey} from "../src/libraries/UniswapV4Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockMetarouter} from "./mocks/MockAero.sol";
import {LocalVenues} from "./LocalVenues.sol";

/// @notice The chain's own DEX beside Uniswap (`docs/design/chain-venues.md`): PancakeSwap's V3 and V2 pools
///         through its Universal Router, Aero's CL and basic pools through its Metarouter, each through the zap and
///         the basket builder, with the engine's rules on every one.
contract ChainVenuesTest is XindexTest {
    MockUniversalRouter uniswap;
    MockUniversalRouter pancake;
    MockMetarouter aero;
    IndexZap plainZap;
    IndexZap pancakeZap;
    IndexZap aeroZap;
    BasketBuilder pancakeBuilder;
    BasketBuilder aeroBuilder;
    WeightedHub index;

    MockERC20 wbtc;
    MockERC20 weth;
    MockERC20 link;
    MockERC20 usdc;
    MockERC20 usdt;

    address alice = makeAddr("alice");

    uint8 constant CONCENTRATED = 0;
    uint8 constant CONSTANT_FUNCTION = 1;
    uint24 constant FEE = 2500;
    uint24 constant VOLATILE = 0;
    uint24 constant STABLE = 1;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(address(0));
        uniswap = new MockUniversalRouter(makeAddr("poolManager"));
        pancake = new MockUniversalRouter(address(0));
        pancake.setPancake(true);
        aero = new MockMetarouter();

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = market.usdc();
        usdt = new MockERC20("Tether", "USDT", 6);
        _price(address(wbtc), 60_000e18, 8);
        _price(address(weth), 3_000e18, 18);
        _price(address(link), 15e18, 18);
        _price(address(usdc), 1e18, 6);
        _price(address(usdt), 1e18, 6);

        // Aero's pools: CL wbtc/usdc at tick spacing 100, CL weth/usdc at 1, a volatile link/usdc, and the pair a
        // two-family route needs: a volatile weth/usdt and a stable usdt/usdc.
        aero.CL().create(address(wbtc), address(usdc), 100);
        aero.CL().create(address(weth), address(usdc), 1);
        aero.CL().create(address(wbtc), address(weth), 100);
        aero.VOLATILE().create(address(link), address(usdc));
        aero.VOLATILE().create(address(weth), address(usdt));
        aero.STABLE().create(address(usdt), address(usdc));

        IIndexFactory f = IIndexFactory(address(factory));
        plainZap = new IndexZap(f, uniswap, LocalVenues.none(), address(usdc), address(usdt));
        pancakeZap = new IndexZap(f, uniswap, LocalVenues.pancake(address(pancake)), address(usdc), address(usdt));
        aeroZap = new IndexZap(f, uniswap, _aeroVenue(), address(usdc), address(usdt));
        pancakeBuilder =
            new BasketBuilder(f, uniswap, LocalVenues.pancake(address(pancake)), address(usdc), address(usdt));
        aeroBuilder = new BasketBuilder(f, uniswap, _aeroVenue(), address(usdc), address(usdt));

        _listWith(address(wbtc));
        _listWith(address(weth));
        _listWith(address(link));
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(wbtc), address(weth), address(link));
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (100_000, 1e16, 1e18); // $60 + $30 + $15 a share
        index = _createIndex("Blue Chip", "BLUE", t, u);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _aeroVenue() internal view returns (IUniversalRouterSwaps.LocalVenue memory) {
        return LocalVenues.aero(address(aero), address(aero.CL()), address(aero.VOLATILE()), address(aero.STABLE()));
    }

    /// @dev Prices a token on all three routers and stocks their inventories.
    function _price(address token, uint256 usd, uint8 decimals) internal {
        uniswap.setPrice(token, usd, decimals);
        pancake.setPrice(token, usd, decimals);
        aero.setPrice(token, usd, decimals);
        uint256 stock = 1_000_000 * 10 ** decimals;
        MockERC20(token).mint(address(uniswap.inventory()), stock);
        MockERC20(token).mint(address(pancake.inventory()), stock);
        MockERC20(token).mint(address(aero.inventory()), stock);
    }

    function _local(uint8 family, bytes memory path) internal pure returns (bytes memory) {
        return abi.encodePacked(family, path);
    }

    function _hop(address a, uint24 p, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, p, b);
    }

    function _hop2(address a, uint24 p, address b, uint24 q, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, p, b, q, c);
    }

    function _mintLeg(bytes memory route) internal pure returns (IUniversalRouterSwaps.MintLeg memory) {
        return IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: new PathKey[](0), localRoute: route, maxAmountIn: 0});
    }

    function _burnLeg(bytes memory route) internal pure returns (IUniversalRouterSwaps.BurnLeg memory) {
        return IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: new PathKey[](0), localRoute: route, minAmountOut: 0});
    }

    /// @dev Every leg through PancakeSwap's V3 pools, the reverse of a sale's route as a V3 path is.
    function _pancakeMintLegs() internal view returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        legs[0] = _mintLeg(_local(CONCENTRATED, _hop2(address(wbtc), FEE, address(weth), FEE, address(usdc))));
        legs[1] = _mintLeg(_local(CONCENTRATED, _hop(address(weth), FEE, address(usdc))));
        legs[2] = _mintLeg(_local(CONSTANT_FUNCTION, _hop2(address(link), 0, address(weth), 0, address(usdc))));
    }

    function _pancakeBurnLegs() internal view returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = _burnLeg(_local(CONCENTRATED, _hop2(address(wbtc), FEE, address(weth), FEE, address(usdc))));
        legs[1] = _burnLeg(_local(CONSTANT_FUNCTION, _hop(address(weth), 0, address(usdc))));
        legs[2] = _burnLeg(_local(CONSTANT_FUNCTION, _hop2(address(link), 0, address(weth), 0, address(usdc))));
    }

    /// @dev Aero: wbtc through two CL pools, weth through a volatile and a stable basic pool, link through one
    ///      volatile pool.
    function _aeroMintLegs() internal view returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        legs[0] = _mintLeg(_local(CONCENTRATED, _hop2(address(wbtc), 100, address(weth), 1, address(usdc))));
        legs[1] =
            _mintLeg(_local(CONSTANT_FUNCTION, _hop2(address(weth), VOLATILE, address(usdt), STABLE, address(usdc))));
        legs[2] = _mintLeg(_local(CONSTANT_FUNCTION, _hop(address(link), VOLATILE, address(usdc))));
    }

    function _aeroBurnLegs() internal view returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = _burnLeg(_local(CONCENTRATED, _hop(address(wbtc), 100, address(usdc))));
        legs[1] = _burnLeg(_local(CONCENTRATED, _hop(address(weth), 1, address(usdc))));
        legs[2] = _burnLeg(_local(CONSTANT_FUNCTION, _hop(address(link), VOLATILE, address(usdc))));
    }

    function _mintParams(IUniversalRouterSwaps.MintLeg[] memory legs, address to)
        internal
        view
        returns (IIndexZap.MintParams memory)
    {
        return IIndexZap.MintParams({
            index: address(index),
            expectedNonce: 0,
            tokenIn: address(usdc),
            maxAmountIn: 200e6,
            shares: 1e18,
            legs: legs,
            to: to,
            deadline: block.timestamp,
            referrer: address(0)
        });
    }

    function _burnParams(IUniversalRouterSwaps.BurnLeg[] memory legs, address to)
        internal
        view
        returns (IIndexZap.BurnParams memory)
    {
        return IIndexZap.BurnParams({
            index: address(index),
            expectedNonce: 0,
            shares: 1e18,
            tokenOut: address(usdc),
            minAmountOut: 1,
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    function _mint(IndexZap zap, IUniversalRouterSwaps.MintLeg[] memory legs) internal returns (uint256 spent) {
        usdc.mint(alice, 200e6);
        IIndexZap.MintParams memory p = _mintParams(legs, alice);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        spent = zap.mintWithToken(p);
        vm.stopPrank();
    }

    function _burn(IndexZap zap, IUniversalRouterSwaps.BurnLeg[] memory legs) internal returns (uint256 out) {
        IIndexZap.BurnParams memory p = _burnParams(legs, alice);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        out = zap.burnToToken(p);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // wiring
    // ---------------------------------------------------------------------

    /// @dev Each DEX is named by what it uses and nothing else, in the zap and the builder alike.
    function test_venue_eachDexNamesWhatItUsesAndNothingElse() public {
        assertEq(uint8(plainZap.LOCAL_DEX()), uint8(IUniversalRouterSwaps.LocalDex.None));
        assertEq(plainZap.LOCAL_ROUTER(), address(0));
        assertEq(uint8(pancakeZap.LOCAL_DEX()), uint8(IUniversalRouterSwaps.LocalDex.PancakeSwap));
        assertEq(pancakeZap.LOCAL_ROUTER(), address(pancake));
        assertEq(pancakeZap.AERO_CL_FACTORY(), address(0));
        assertEq(uint8(aeroBuilder.LOCAL_DEX()), uint8(IUniversalRouterSwaps.LocalDex.Aero));
        assertEq(aeroBuilder.LOCAL_ROUTER(), address(aero));
        assertEq(aeroBuilder.AERO_CL_FACTORY(), address(aero.CL()));
        assertEq(aeroBuilder.AERO_VOLATILE_FACTORY(), address(aero.VOLATILE()));
        assertEq(aeroBuilder.AERO_STABLE_FACTORY(), address(aero.STABLE()));

        IUniversalRouterSwaps.LocalVenue[] memory wrong = new IUniversalRouterSwaps.LocalVenue[](7);
        wrong[0] = LocalVenues.none();
        wrong[0].router = address(pancake); // a router for no DEX
        wrong[1] = LocalVenues.pancake(address(0)); // a DEX with no router
        wrong[2] = LocalVenues.pancake(address(pancake));
        wrong[2].clFactory = address(aero.CL()); // Aero's factory on PancakeSwap
        wrong[3] = _aeroVenue();
        wrong[3].stableFactory = address(0); // Aero without one of its factories
        wrong[4] = _aeroVenue();
        wrong[4].clFactory = address(0);
        wrong[5] = _aeroVenue();
        wrong[5].volatileFactory = address(0);
        wrong[6] = LocalVenues.pancake(address(uniswap)); // Uniswap's router named twice
        IIndexFactory f = IIndexFactory(address(factory));
        for (uint256 i = 0; i < wrong.length; ++i) {
            vm.expectRevert(IUniversalRouterSwaps.InvalidLocalVenue.selector);
            new IndexZap(f, uniswap, wrong[i], address(usdc), address(usdt));
            vm.expectRevert(IUniversalRouterSwaps.InvalidLocalVenue.selector);
            new BasketBuilder(f, uniswap, wrong[i], address(usdc), address(usdt));
        }
    }

    /// @dev The command bytes and the swap structs, against values written out from the deployed routers' verified
    ///      source independently of `src`: PancakeSwap's V2 commands, and Aero's commands and structs.
    function test_venue_theCommandsAreTheDeployedRouters() public pure {
        assertEq(UniversalRouterCommands.V2_SWAP_EXACT_IN, 0x08);
        assertEq(UniversalRouterCommands.V2_SWAP_EXACT_OUT, 0x09);
        assertEq(AeroCommands.CL_SWAP_EXACT_IN, 0x00);
        assertEq(AeroCommands.CL_SWAP_EXACT_OUT, 0x01);
        assertEq(AeroCommands.SWEEP, 0x04);
        assertEq(AeroCommands.V2_SWAP_EXACT_IN, 0x08);
        assertEq(AeroCommands.V2_SWAP_EXACT_OUT, 0x09);

        address[] memory pools = new address[](2);
        (pools[0], pools[1]) = (address(0xA), address(0xB));
        IAeroMetarouter.SwapExactInParams memory ours = IAeroMetarouter.SwapExactInParams({
            pools: pools,
            tokenIn: address(0xC),
            amountIn: IAeroMetarouter.BalanceSpend({mode: IAeroMetarouter.SpendMode.Amount, value: 7}),
            payerIsUser: false,
            minAmountOut: 9,
            recipient: address(0xD)
        });
        UpstreamSwapExactInParams memory theirs = UpstreamSwapExactInParams({
            pools: pools,
            tokenIn: address(0xC),
            amountIn: UpstreamBalanceSpend({mode: 0, value: 7}),
            payerIsUser: false,
            minAmountOut: 9,
            recipient: address(0xD)
        });
        assertEq(abi.encode(ours), abi.encode(theirs));
        IAeroMetarouter.SwapExactOutParams memory oursOut = IAeroMetarouter.SwapExactOutParams({
            pools: pools,
            tokenIn: address(0xC),
            amountOut: 7,
            payerIsUser: false,
            maxAmountIn: 9,
            recipient: address(0xD)
        });
        UpstreamSwapExactOutParams memory theirsOut = UpstreamSwapExactOutParams({
            pools: pools,
            tokenIn: address(0xC),
            amountOut: 7,
            payerIsUser: false,
            maxAmountIn: 9,
            recipient: address(0xD)
        });
        assertEq(abi.encode(oursOut), abi.encode(theirsOut));
    }

    // ---------------------------------------------------------------------
    // routes
    // ---------------------------------------------------------------------

    /// @dev A leg names exactly one venue, and the chain's DEX only where the deployment has one.
    function test_venue_aLegNamesOneVenue() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _pancakeMintLegs();
        legs[1].v3Path = _hop(address(weth), 500, address(usdc)); // Uniswap and PancakeSwap both
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(pancakeZap), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        pancakeZap.mintWithToken(_mintParams(legs, alice));

        legs = _pancakeMintLegs();
        legs[2].v4Path = new PathKey[](1); // Uniswap V4 and PancakeSwap both
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        pancakeZap.mintWithToken(_mintParams(legs, alice));

        // A deployment without a DEX of its own takes no local route at all.
        usdc.approve(address(plainZap), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 0));
        plainZap.mintWithToken(_mintParams(_pancakeMintLegs(), alice));
        vm.stopPrank();
    }

    /// @dev A local route is a family PancakeSwap or Aero has, a path of V3's shape from the component to the user's
    ///      token, and on constant-function pools a parameter the DEX knows.
    function test_venue_aLocalRouteIsAFamilyAndAPath() public {
        bytes[] memory bad = new bytes[](6);
        bad[0] = _local(2, _hop(address(weth), 0, address(usdc))); // no such family, though a V2 pair has this path
        bad[1] = abi.encodePacked(CONCENTRATED, address(weth), FEE); // no second token
        bad[2] = _local(CONCENTRATED, _hop(address(link), FEE, address(usdc))); // starts at another component
        bad[3] = _local(CONCENTRATED, _hop(address(weth), FEE, address(usdt))); // ends at another token
        bad[4] = _local(CONSTANT_FUNCTION, _hop(address(weth), FEE, address(usdc))); // a V2 pair has no fee tier
        bad[5] = _local(CONSTANT_FUNCTION, _hop2(address(weth), 0, address(wbtc), 1, address(usdc)));
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(pancakeZap), 200e6);
        for (uint256 k = 0; k < bad.length; ++k) {
            IUniversalRouterSwaps.MintLeg[] memory legs = _pancakeMintLegs();
            legs[1].localRoute = bad[k];
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
            pancakeZap.mintWithToken(_mintParams(legs, alice));
        }
        // On Aero a basic pool is volatile or stable, and nothing else.
        usdc.approve(address(aeroZap), 200e6);
        IUniversalRouterSwaps.MintLeg[] memory aeroLegs = _aeroMintLegs();
        aeroLegs[2].localRoute = _local(CONSTANT_FUNCTION, _hop(address(link), 2, address(usdc)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        aeroZap.mintWithToken(_mintParams(aeroLegs, alice));
        // A pair Aero has no pool for gives zero, which the Metarouter refuses as no pool of Aero's.
        aeroLegs = _aeroMintLegs();
        aeroLegs[2].localRoute = _local(CONCENTRATED, _hop(address(link), 100, address(usdc)));
        vm.expectRevert(abi.encodeWithSelector(MockMetarouter.InvalidPool.selector, address(0)));
        aeroZap.mintWithToken(_mintParams(aeroLegs, alice));
        vm.stopPrank();
    }

    /// @dev The pass-through leg, whose component is the user's token, names no route on any venue.
    function test_venue_thePassThroughLegNamesNoLocalRoute() public {
        _listWith(address(usdc));
        WeightedHub mixed = _createIndex("Mixed", "MIX", _pair(address(weth), address(usdc)), _pair(1e16, 50e6));
        IUniversalRouterSwaps.MintLeg[] memory mintLegs = new IUniversalRouterSwaps.MintLeg[](2);
        mintLegs[0] = _mintLeg(_local(CONCENTRATED, _hop(address(weth), FEE, address(usdc))));
        mintLegs[1] = _mintLeg(_local(CONCENTRATED, _hop(address(usdc), FEE, address(usdc))));
        IIndexZap.MintParams memory p = _mintParams(mintLegs, alice);
        p.index = address(mixed);
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(pancakeZap), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        pancakeZap.mintWithToken(p);
        mintLegs[1].localRoute = "";
        pancakeZap.mintWithToken(p);

        IUniversalRouterSwaps.BurnLeg[] memory burnLegs = new IUniversalRouterSwaps.BurnLeg[](2);
        burnLegs[0] = _burnLeg(_local(CONCENTRATED, _hop(address(weth), FEE, address(usdc))));
        burnLegs[1] = _burnLeg(_local(CONCENTRATED, _hop(address(usdc), FEE, address(usdc))));
        IIndexZap.BurnParams memory b = _burnParams(burnLegs, alice);
        b.index = address(mixed);
        mixed.approve(address(pancakeZap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        pancakeZap.burnToToken(b);
        vm.stopPrank();
    }

    /// @dev Neither the zap nor the builder pays the chain's DEX router: anyone can sweep what it holds.
    function test_venue_theLocalRouterIsNoRecipient() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(pancakeZap), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(pancake)));
        pancakeZap.mintWithToken(_mintParams(_pancakeMintLegs(), address(pancake)));
        usdc.approve(address(aeroZap), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(aero)));
        aeroZap.mintWithToken(_mintParams(_aeroMintLegs(), address(aero)));

        usdc.approve(address(aeroBuilder), 1e6);
        aeroBuilder.deposit(address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(aero)));
        aeroBuilder.withdraw(address(usdc), 1e6, address(aero));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // PancakeSwap
    // ---------------------------------------------------------------------

    /// @dev A mint and a burn through PancakeSwap's V3 and V2 pools: every command goes to its router, as the bytes
    ///      and inputs its verified source decodes, and none to Uniswap's.
    function test_venue_pancakeMintsAndBurnsThroughV3AndV2() public {
        uint256 spent = _mint(pancakeZap, _pancakeMintLegs());
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(spent, 105e6);
        assertEq(usdc.balanceOf(alice), 200e6 - 105e6, "the unspent budget comes back");
        assertEq(uniswap.lastCommands(), "", "nothing went to Uniswap's router");

        // The last buy was LINK through two V2 pairs: exact output, the path forward from what is paid.
        assertEq(
            pancake.lastCommands(),
            abi.encodePacked(UniversalRouterCommands.V2_SWAP_EXACT_OUT, UniversalRouterCommands.SWEEP)
        );
        (address recipient, uint256 amountOut,, address[] memory path, bool payerIsUser) =
            abi.decode(pancake.lastInput(0), (address, uint256, uint256, address[], bool));
        assertEq(recipient, address(pancakeZap));
        assertEq(amountOut, 1e18);
        assertEq(path.length, 3);
        (address p0, address p1, address p2) = (path[0], path[1], path[2]);
        assertEq(p0, address(usdc));
        assertEq(p1, address(weth));
        assertEq(p2, address(link));
        assertFalse(payerIsUser);
        (address swept, address sweptTo, uint256 sweepMin) =
            abi.decode(pancake.lastInput(1), (address, address, uint256));
        assertEq(swept, address(usdc));
        assertEq(sweptTo, address(pancakeZap));
        assertEq(sweepMin, 0);
        // The V3 buys took the path as it is, reversed, as Uniswap's do.
        uint256[] memory prefunded = pancake.prefundedLog();
        assertEq(prefunded.length, 3, "each buy pre-funded the router");

        uint256 out = _burn(pancakeZap, _pancakeBurnLegs());
        assertEq(out, 105e6);
        assertEq(index.balanceOf(alice), 0);
        // The last sale was LINK's second V2 hop, WETH to USDC, a pair forward from its input.
        assertEq(
            pancake.lastCommands(),
            abi.encodePacked(UniversalRouterCommands.V2_SWAP_EXACT_IN, UniversalRouterCommands.SWEEP)
        );
        (, uint256 amountIn,, address[] memory pair,) =
            abi.decode(pancake.lastInput(0), (address, uint256, uint256, address[], bool));
        assertEq(amountIn, 5e15, "the second hop sells what the first produced, $15 of WETH");
        assertEq(pair.length, 2);
        (address q0, address q1) = (pair[0], pair[1]);
        assertEq(q0, address(weth));
        assertEq(q1, address(usdc));
        assertEq(uniswap.lastCommands(), "", "nothing went to Uniswap's router");
        assertEq(usdc.balanceOf(address(pancake)), 0, "the router keeps nothing");
    }

    /// @dev What a PancakeSwap V3 hop did not sell comes back to the burn's recipient, and a stranger's balance in
    ///      the router is told apart from it, as on Uniswap's.
    function test_venue_pancakeUnsoldInputAndStrayComeBackApart() public {
        _mint(pancakeZap, _pancakeMintLegs());
        wbtc.mint(address(pancake), 7); // a stranger's wei in the router
        pancake.setMode(MockUniversalRouter.Mode.PartialFirstHop);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _pancakeBurnLegs();
        legs[0].localRoute = _local(CONCENTRATED, _hop(address(wbtc), FEE, address(usdc)));
        legs[1].localRoute = _local(CONCENTRATED, _hop(address(weth), FEE, address(usdc)));
        legs[2].localRoute = _local(CONCENTRATED, _hop(address(link), FEE, address(usdc)));
        uint256 out = _burn(pancakeZap, legs);
        assertEq(out, 105e6 / 2, "each hop sold half");
        assertEq(wbtc.balanceOf(alice), 50_000 + 7, "the unsold half and the stray, offered to the recipient");
        assertEq(weth.balanceOf(alice), 5e15);
        assertEq(link.balanceOf(alice), 5e17);
        assertEq(wbtc.balanceOf(address(pancakeZap)), 0);
    }

    // ---------------------------------------------------------------------
    // Aero
    // ---------------------------------------------------------------------

    /// @dev A mint and a burn through Aero's CL and basic pools: the pools come from the deployment's factories,
    ///      forward from what is paid, the payer is the router's own balance, and the deadline is this block's.
    function test_venue_aeroMintsAndBurnsThroughCLAndBasicPools() public {
        uint256 spent = _mint(aeroZap, _aeroMintLegs());
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(spent, 105e6);
        assertEq(uniswap.lastCommands(), "", "nothing went to Uniswap's router");
        assertEq(aero.lastDeadline(), block.timestamp);

        // The last buy was LINK through one volatile basic pool.
        assertEq(aero.lastCommands(), abi.encodePacked(AeroCommands.V2_SWAP_EXACT_OUT, AeroCommands.SWEEP));
        IAeroMetarouter.SwapExactOutParams memory out =
            abi.decode(aero.lastInput(0), (IAeroMetarouter.SwapExactOutParams));
        assertEq(out.pools.length, 1);
        assertEq(out.pools[0], aero.VOLATILE().getPool(address(link), address(usdc)));
        assertEq(out.tokenIn, address(usdc));
        assertEq(out.amountOut, 1e18);
        assertFalse(out.payerIsUser);
        assertEq(out.maxAmountIn, 200e6 - 90e6, "the budget left after the first two legs");
        assertEq(out.recipient, address(aeroZap));

        uint256 proceeds = _burn(aeroZap, _aeroBurnLegs());
        assertEq(proceeds, 105e6);
        assertEq(aero.lastCommands(), abi.encodePacked(AeroCommands.V2_SWAP_EXACT_IN, AeroCommands.SWEEP));
        IAeroMetarouter.SwapExactInParams memory sale =
            abi.decode(aero.lastInput(0), (IAeroMetarouter.SwapExactInParams));
        assertEq(sale.pools[0], aero.VOLATILE().getPool(address(link), address(usdc)));
        assertEq(sale.tokenIn, address(link));
        assertEq(uint8(sale.amountIn.mode), uint8(IAeroMetarouter.SpendMode.Amount));
        assertEq(sale.amountIn.value, 1e18);
        assertFalse(sale.payerIsUser);
        assertEq(sale.recipient, address(aeroZap));
        assertEq(usdc.balanceOf(address(aero)), 0, "the router keeps nothing");
    }

    /// @dev A two-hop buy names its pools forward from what is paid: the reverse of the route's hops, each from its
    ///      family's factory, a stable pool where the hop's parameter is one.
    function test_venue_aeroNamesPoolsForwardAndByFamily() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _aeroMintLegs();
        // Run the WETH leg last, so its input is the one the mock recorded.
        IUniversalRouterSwaps.MintLeg[] memory order = new IUniversalRouterSwaps.MintLeg[](3);
        (order[0], order[1], order[2]) = (legs[0], legs[2], legs[1]);
        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(wbtc), address(link), address(weth));
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (100_000, 1e18, 1e16);
        index = _createIndex("Blue Again", "BLU2", t, u);
        _mint(aeroZap, order);
        IAeroMetarouter.SwapExactOutParams memory weths =
            abi.decode(aero.lastInput(0), (IAeroMetarouter.SwapExactOutParams));
        assertEq(weths.pools.length, 2);
        assertEq(weths.pools[0], aero.STABLE().getPool(address(usdc), address(usdt)), "first the stable pool");
        assertEq(weths.pools[1], aero.VOLATILE().getPool(address(usdt), address(weth)), "then the volatile one");
        assertEq(weths.amountOut, 1e16);
    }

    /// @dev What an Aero CL hop did not sell comes back to the burn's recipient, the stray apart, through the sweep.
    function test_venue_aeroUnsoldInputComesBack() public {
        _mint(aeroZap, _aeroMintLegs());
        aero.setPartialFill(true);
        wbtc.mint(address(aero), 3);
        uint256 proceeds = _burn(aeroZap, _aeroBurnLegs());
        assertEq(proceeds, 30e6 + 15e6 + 15e6, "the CL legs sold half, the basic one all");
        assertEq(wbtc.balanceOf(alice), 50_000 + 3);
        assertEq(weth.balanceOf(alice), 5e15);
        assertEq(link.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------------
    // the builder
    // ---------------------------------------------------------------------

    /// @dev The builder buys into an escrow and sells out of one through either DEX, as the zap does.
    function test_venue_theBuilderBuysAndSellsThroughEitherDex() public {
        uint256[] memory components = new uint256[](3);
        (components[0], components[1], components[2]) = (0, 1, 2);
        IBasketBuilder.BuyParams memory p = IBasketBuilder.BuyParams({
            index: address(index),
            expectedNonce: 0,
            shares: 1e18,
            tokenIn: address(usdc),
            maxAmountIn: 200e6,
            components: components,
            legs: _pancakeMintLegs(),
            deadline: block.timestamp
        });
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(pancakeBuilder), 200e6);
        assertEq(pancakeBuilder.buy(p), 105e6);
        assertEq(pancakeBuilder.escrowOf(alice, address(wbtc)), 100_000);
        assertEq(pancakeBuilder.escrowOf(alice, address(link)), 1e18);
        pancakeBuilder.mint(address(index), 1e18, alice, address(0), block.timestamp);
        assertEq(index.balanceOf(alice), 1e18);

        // Out again, through Aero.
        index.approve(address(aeroBuilder), 1e18);
        aeroBuilder.redeem(address(index), 1e18);
        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (address(wbtc), address(weth), address(link));
        IBasketBuilder.SellParams memory s = IBasketBuilder.SellParams({
            tokenOut: address(usdc),
            minAmountOut: 1,
            tokens: tokens,
            amounts: new uint256[](3),
            legs: _aeroBurnLegs(),
            to: alice,
            deadline: block.timestamp
        });
        assertEq(aeroBuilder.sell(s), 105e6);
        assertEq(aeroBuilder.escrowOf(alice, address(wbtc)), 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // attacks replayed on the chain's DEX (audits/internal/attack-replay-ii.md)
    // ---------------------------------------------------------------------

    /// @dev HK-21, SushiSwap's RouteProcessor2 (April 2023): whoever held an approval to the router was drained
    ///      through it. Neither the zap nor the builder approves a router, through any DEX: each leg pays by a transfer
    ///      the same call sweeps back. After a mint, a burn, a buy and a sale through PancakeSwap and Aero, no router
    ///      holds an allowance from either, and the user approved the zap and the builder alone.
    function test_HK21_noRouterEverHoldsAnApproval() public {
        _mint(pancakeZap, _pancakeMintLegs());
        _burn(pancakeZap, _pancakeBurnLegs());
        _mint(aeroZap, _aeroMintLegs());
        _burn(aeroZap, _aeroBurnLegs());
        test_venue_theBuilderBuysAndSellsThroughEitherDex();

        address[5] memory tokens = [address(wbtc), address(weth), address(link), address(usdc), address(usdt)];
        address[3] memory routers = [address(uniswap), address(pancake), address(aero)];
        address[5] memory owners =
            [address(pancakeZap), address(aeroZap), address(pancakeBuilder), address(aeroBuilder), alice];
        for (uint256 t = 0; t < tokens.length; ++t) {
            for (uint256 r = 0; r < routers.length; ++r) {
                for (uint256 o = 0; o < owners.length; ++o) {
                    assertEq(IERC20(tokens[t]).allowance(owners[o], routers[r]), 0, "no router holds an approval");
                }
            }
        }
    }

    /// @dev HK-22, RouteProcessor2 again: it called whatever pool its caller named, and a fake pool's callback took
    ///      the approvals. A route here names tokens and a parameter, never a pool. PancakeSwap's router derives each
    ///      pool from its own deployer, and the engine asks Aero's pinned factories for each, so a hop Aero never made,
    ///      a tick spacing or a basic pair with no pool, names address zero, which the Metarouter refuses before
    ///      anything moves. The real routers do the same on their chains (`testFork_HK22_...`).
    function test_HK22_aRouteCannotNameAPoolTheDexDidNotMake() public {
        IUniversalRouterSwaps.MintLeg[] memory noSpacing = _aeroMintLegs();
        noSpacing[0] = _mintLeg(_local(CONCENTRATED, _hop(address(wbtc), 7, address(usdc))));
        IUniversalRouterSwaps.MintLeg[] memory noPair = _aeroMintLegs();
        noPair[2] = _mintLeg(_local(CONSTANT_FUNCTION, _hop(address(link), STABLE, address(usdc))));
        IUniversalRouterSwaps.MintLeg[][2] memory attempts = [noSpacing, noPair];

        usdc.mint(alice, 200e6);
        for (uint256 a = 0; a < attempts.length; ++a) {
            IIndexZap.MintParams memory p = _mintParams(attempts[a], alice);
            vm.startPrank(alice);
            usdc.approve(address(aeroZap), 200e6);
            vm.expectRevert(abi.encodeWithSelector(MockMetarouter.InvalidPool.selector, address(0)));
            aeroZap.mintWithToken(p);
            vm.stopPrank();
        }
        assertEq(usdc.balanceOf(alice), 200e6, "nothing moved");
        assertEq(index.totalSupply(), 0);
    }

    /// @dev HK-23, self-aliasing: Allbridge (July 2026) took one pool as both its send and receive side, and Unifund
    ///      (November 2026) credited both legs of a cyclic WETH path to one ledger key. A route here may come back to
    ///      a token it passed, the component itself included, and each hop is measured alone against the balance it
    ///      leaves. A sale of WBTC through WETH, back to WBTC and on to USDC pays exactly what the WBTC was worth, once:
    ///      through the zap on PancakeSwap, and out of the builder's escrow on Aero, every escrow and the builder's
    ///      balances square after.
    function test_HK23_aRouteThatComesBackToItsTokenIsCountedOnce() public {
        _mint(pancakeZap, _pancakeMintLegs());
        IUniversalRouterSwaps.BurnLeg[] memory legs = _pancakeBurnLegs();
        legs[0] = _burnLeg(
            _local(
                CONCENTRATED,
                abi.encodePacked(address(wbtc), FEE, address(weth), FEE, address(wbtc), FEE, address(usdc))
            )
        );
        assertEq(_burn(pancakeZap, legs), 105e6, "the cycle pays what the coins are worth, once");
        assertEq(wbtc.balanceOf(address(pancakeZap)), 0);
        assertEq(weth.balanceOf(address(pancakeZap)), 0);
        assertEq(wbtc.balanceOf(alice), 0, "and no hop's output came back as unsold input");

        _mint(aeroZap, _aeroMintLegs());
        vm.startPrank(alice);
        index.approve(address(aeroBuilder), 1e18);
        aeroBuilder.redeem(address(index), 1e18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(wbtc);
        IUniversalRouterSwaps.BurnLeg[] memory cycle = new IUniversalRouterSwaps.BurnLeg[](1);
        cycle[0] = _burnLeg(
            _local(
                CONCENTRATED,
                abi.encodePacked(
                    address(wbtc), uint24(100), address(weth), uint24(100), address(wbtc), uint24(100), address(usdc)
                )
            )
        );
        uint256 out = aeroBuilder.sell(
            IBasketBuilder.SellParams({
                tokenOut: address(usdc),
                minAmountOut: 1,
                tokens: tokens,
                amounts: new uint256[](1),
                legs: cycle,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(out, 60e6, "the escrow's WBTC was worth $60, paid once");
        assertEq(aeroBuilder.escrowOf(alice, address(wbtc)), 0);
        assertEq(aeroBuilder.escrowOf(alice, address(weth)), 1e16, "the WETH leg's escrow is untouched");
        address[3] memory held = [address(wbtc), address(weth), address(usdc)];
        for (uint256 t = 0; t < held.length; ++t) {
            assertEq(
                IERC20(held[t]).balanceOf(address(aeroBuilder)), aeroBuilder.totalEscrow(held[t]), "escrows square"
            );
        }
    }
}

/// @dev Aero's structs as its verified source declares them, written out apart from `src`.
struct UpstreamBalanceSpend {
    uint8 mode;
    uint256 value;
}

struct UpstreamSwapExactInParams {
    address[] pools;
    address tokenIn;
    UpstreamBalanceSpend amountIn;
    bool payerIsUser;
    uint256 minAmountOut;
    address recipient;
}

struct UpstreamSwapExactOutParams {
    address[] pools;
    address tokenIn;
    uint256 amountOut;
    bool payerIsUser;
    uint256 maxAmountIn;
    address recipient;
}
