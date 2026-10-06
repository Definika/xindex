// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {NoEtherCaller} from "./mocks/NoEtherCaller.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IPancakeUniversalRouter} from "../src/interfaces/IPancakeUniversalRouter.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {PancakeRouterCommands as PCmd} from "../src/libraries/PancakeRouterCommands.sol";
import {PathKey} from "../src/libraries/UniswapV4Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockPancakeRouter} from "./mocks/MockPancakeRouter.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// @notice The zap's PancakeSwap legs (the owner's call on 2026-10-06, `design/2026-10-06-swap-venues.md`): a leg names
///         exactly one of a Uniswap V3 path, a Uniswap V4 route and a PancakeSwap V3 path, and a PancakeSwap leg runs
///         through PancakeSwap's router with the zap's usual pre-fund, sweep and measurement, ended by WRAP_ETH (SV-1).
///         The router is `MockPancakeRouter`, which follows the deployed router's source; the mainnet fork suite runs
///         the same legs against the real router and pools.
contract IndexZapPancakeTest is XindexTest {
    IndexZap zap;
    MockUniversalRouter router;
    MockPancakeRouter pancake;
    MockWETH pancakeWeth;
    WeightedHub index;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 cake; // 18
    MockERC20 usdc; // 6

    address alice = makeAddr("alice");

    // 0.001 WBTC ($60) + 0.01 WETH ($30) + 10 CAKE ($20) = $110 per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_CAKE = 10e18;
    uint24 constant UNI_FEE = 500;
    uint24 constant CAKE_FEE = 2500;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(address(0));
        router = new MockUniversalRouter(makeAddr("poolManager"));
        pancakeWeth = new MockWETH();
        pancake = new MockPancakeRouter(address(pancakeWeth));
        zap = new IndexZap(IIndexFactory(address(factory)), router, pancake);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        cake = new MockERC20("PancakeSwap Token", "Cake", 18);
        usdc = market.usdc();

        address[4] memory tokens = [address(wbtc), address(weth), address(cake), address(usdc)];
        uint256[4] memory prices = [uint256(60_000e18), 3_000e18, 2e18, 1e18];
        uint8[4] memory decimals = [8, 18, 18, 6];
        for (uint256 i = 0; i < 4; ++i) {
            router.setPrice(tokens[i], prices[i], decimals[i]);
            pancake.setPrice(tokens[i], prices[i], decimals[i]);
            MockERC20(tokens[i]).mint(address(router.inventory()), 1e30);
            MockERC20(tokens[i]).mint(address(pancake.inventory()), 1e30);
        }

        _listWith(address(wbtc));
        _listWith(address(weth));
        _listWith(address(cake));

        address[] memory t = new address[](3);
        (t[0], t[1], t[2]) = (address(wbtc), address(weth), address(cake));
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (U_WBTC, U_WETH, U_CAKE);
        index = _createIndex("Cake Chip", "CAKEC", t, u);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _uni(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, UNI_FEE, b);
    }

    function _cake(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, CAKE_FEE, b);
    }

    function _cake3(address a, address b, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, CAKE_FEE, b, CAKE_FEE, c);
    }

    function _noV4() internal pure returns (PathKey[] memory) {
        return new PathKey[](0);
    }

    function _v4(address currency) internal pure returns (PathKey[] memory path) {
        path = new PathKey[](1);
        path[0] =
            PathKey({intermediateCurrency: currency, fee: UNI_FEE, tickSpacing: 10, hooks: address(0), hookData: ""});
    }

    /// @dev Every leg through PancakeSwap: WBTC and CAKE through WETH, WETH direct.
    function _pancakeMintLegs() internal view returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](3);
        legs[0] = _mintLeg("", _cake3(address(wbtc), address(weth), address(usdc)));
        legs[1] = _mintLeg("", _cake(address(weth), address(usdc)));
        legs[2] = _mintLeg("", _cake3(address(cake), address(weth), address(usdc)));
    }

    function _pancakeBurnLegs() internal view returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](3);
        legs[0] = _burnLeg("", _cake3(address(wbtc), address(weth), address(usdc)));
        legs[1] = _burnLeg("", _cake(address(weth), address(usdc)));
        legs[2] = _burnLeg("", _cake3(address(cake), address(weth), address(usdc)));
    }

    function _mintLeg(bytes memory v3Path, bytes memory pancakePath) internal pure returns (IIndexZap.MintLeg memory) {
        return IIndexZap.MintLeg({v3Path: v3Path, v4Path: _noV4(), pancakePath: pancakePath, maxAmountIn: 0});
    }

    function _burnLeg(bytes memory v3Path, bytes memory pancakePath) internal pure returns (IIndexZap.BurnLeg memory) {
        return IIndexZap.BurnLeg({v3Path: v3Path, v4Path: _noV4(), pancakePath: pancakePath, minAmountOut: 0});
    }

    function _mintParams(uint256 maxIn, uint256 shares, IIndexZap.MintLeg[] memory legs, address to)
        internal
        view
        returns (IIndexZap.MintParams memory)
    {
        return IIndexZap.MintParams({
            index: address(index),
            expectedNonce: 0,
            tokenIn: address(usdc),
            maxAmountIn: maxIn,
            shares: shares,
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    function _burnParams(uint256 shares, uint256 minOut, IIndexZap.BurnLeg[] memory legs, address to)
        internal
        view
        returns (IIndexZap.BurnParams memory)
    {
        return IIndexZap.BurnParams({
            index: address(index),
            expectedNonce: 0,
            shares: shares,
            tokenOut: address(usdc),
            minAmountOut: minOut,
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    function _mint(IIndexZap.MintLeg[] memory legs, uint256 shares, uint256 maxIn) internal returns (uint256 spent) {
        usdc.mint(alice, maxIn);
        IIndexZap.MintParams memory p = _mintParams(maxIn, shares, legs, alice);
        vm.startPrank(alice);
        usdc.approve(address(zap), maxIn);
        spent = zap.mintWithToken(p);
        vm.stopPrank();
    }

    function _burn(IIndexZap.BurnLeg[] memory legs, uint256 shares, uint256 minOut) internal returns (uint256 out) {
        IIndexZap.BurnParams memory p = _burnParams(shares, minOut, legs, alice);
        vm.startPrank(alice);
        index.approve(address(zap), shares);
        out = zap.burnToToken(p);
        vm.stopPrank();
    }

    function _expectMintReverts(IIndexZap.MintLeg[] memory legs, address to, bytes memory reason) internal {
        usdc.mint(alice, 1_000e6);
        IIndexZap.MintParams memory p = _mintParams(1_000e6, 1e18, legs, to);
        vm.startPrank(alice);
        usdc.approve(address(zap), 1_000e6);
        vm.expectRevert(reason);
        zap.mintWithToken(p);
        vm.stopPrank();
    }

    function _expectBurnReverts(IIndexZap.BurnLeg[] memory legs, address to, bytes memory reason) internal {
        IIndexZap.BurnParams memory p = _burnParams(1e18, 1, legs, to);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(reason);
        zap.burnToToken(p);
        vm.stopPrank();
    }

    function _assertNothingLeft() internal view {
        address[4] memory tokens = [address(wbtc), address(weth), address(cake), address(usdc)];
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(MockERC20(tokens[i]).balanceOf(address(zap)), 0, "the zap keeps nothing");
            assertEq(MockERC20(tokens[i]).balanceOf(address(pancake)), 0, "the PancakeSwap router keeps nothing");
        }
        assertEq(address(pancake).balance, 0, "nor any ether");
    }

    // ---------------------------------------------------------------------
    // wiring and constants
    // ---------------------------------------------------------------------

    function test_pancakeRouterIsWired() public view {
        assertEq(address(zap.PANCAKE_ROUTER()), address(pancake));
        assertEq(address(zap.ROUTER()), address(router));
    }

    /// @dev The command bytes and sentinels, written out from the deployed router's verified source
    ///      (`contracts/libraries/Commands.sol` and `Constants.sol` at 0x65b382653f7C31bC0Af67f188122035461ec9C76),
    ///      independently of src. The mainnet fork suite checks them against the deployed router itself.
    function test_pancakeCommandsMatchTheDeployedRouter() public pure {
        assertEq(PCmd.V3_SWAP_EXACT_IN, 0x00);
        assertEq(PCmd.V3_SWAP_EXACT_OUT, 0x01);
        assertEq(PCmd.SWEEP, 0x04);
        assertEq(PCmd.WRAP_ETH, 0x0b);
        assertEq(PCmd.ADDRESS_THIS, address(2));
        assertEq(PCmd.CONTRACT_BALANCE, 0x8000000000000000000000000000000000000000000000000000000000000000);
    }

    // ---------------------------------------------------------------------
    // mint and burn through PancakeSwap
    // ---------------------------------------------------------------------

    function test_mintThroughPancakeLegs() public {
        uint256 spent = _mint(_pancakeMintLegs(), 1e18, 120e6);
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(spent, 110e6, "the basket's value");
        assertEq(usdc.balanceOf(alice), 10e6, "the rest refunded");
        assertEq(wbtc.balanceOf(address(index)), U_WBTC);
        assertEq(weth.balanceOf(address(index)), U_WETH);
        assertEq(cake.balanceOf(address(index)), U_CAKE);
        _assertNothingLeft();

        // The last leg's call, byte for byte: exact output, sweep back, wrap the router's ether in place.
        assertEq(pancake.lastCommands(), abi.encodePacked(uint8(0x01), uint8(0x04), uint8(0x0b)));
        (address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser) =
            abi.decode(pancake.lastInput(0), (address, uint256, uint256, bytes, bool));
        assertEq(recipient, address(zap));
        assertEq(amountOut, U_CAKE);
        assertEq(amountInMax, 120e6 - 60e6 - 30e6, "pre-funded with what the budget had left");
        assertEq(path, _cake3(address(cake), address(weth), address(usdc)));
        assertFalse(payerIsUser);
        assertEq(pancake.lastInput(1), abi.encode(address(usdc), address(zap), uint256(0)));
        assertEq(pancake.lastInput(2), abi.encode(address(2), uint256(1) << 255));
    }

    function test_burnThroughPancakeLegsSwapsOneHopAtATime() public {
        _mint(_pancakeMintLegs(), 2e18, 240e6);
        uint256 before = usdc.balanceOf(alice);
        uint256 out = _burn(_pancakeBurnLegs(), 1e18, 100e6);
        assertApproxEqAbs(out, 110e6, 2, "the basket's value, less each hop's rounding");
        assertEq(usdc.balanceOf(alice) - before, out);
        assertEq(index.balanceOf(alice), 1e18);
        _assertNothingLeft();
        // The last hop of CAKE's two: WETH into USDC, exact input, then the sweep and the wrap.
        assertEq(pancake.lastCommands(), abi.encodePacked(uint8(0x00), uint8(0x04), uint8(0x0b)));
        (address recipient,,, bytes memory path, bool payerIsUser) =
            abi.decode(pancake.lastInput(0), (address, uint256, uint256, bytes, bool));
        assertEq(recipient, address(zap));
        assertEq(path, _cake(address(weth), address(usdc)), "one hop per call");
        assertFalse(payerIsUser);
        assertEq(pancake.lastInput(1), abi.encode(address(weth), address(zap), uint256(0)));
    }

    /// @dev One mint, three venues: WBTC through Uniswap V3, WETH through Uniswap V4, CAKE through PancakeSwap.
    function test_oneMintAcrossAllThreeVenues() public {
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](3);
        legs[0] = _mintLeg(abi.encodePacked(address(wbtc), UNI_FEE, address(weth), UNI_FEE, address(usdc)), "");
        legs[1] = IIndexZap.MintLeg({v3Path: "", v4Path: _v4(address(usdc)), pancakePath: "", maxAmountIn: 0});
        legs[2] = _mintLeg("", _cake3(address(cake), address(weth), address(usdc)));
        assertEq(_mint(legs, 1e18, 200e6), 110e6);
        assertEq(cake.balanceOf(address(index)), U_CAKE);
        _assertNothingLeft();

        IIndexZap.BurnLeg[] memory out = new IIndexZap.BurnLeg[](3);
        out[0] = _burnLeg(_uni(address(wbtc), address(usdc)), "");
        out[1] = IIndexZap.BurnLeg({v3Path: "", v4Path: _v4(address(usdc)), pancakePath: "", minAmountOut: 0});
        out[2] = _burnLeg("", _cake(address(cake), address(usdc)));
        assertEq(_burn(out, 1e18, 1), 110e6);
        _assertNothingLeft();
    }

    function test_pancakeLegLimitsHold() public {
        IIndexZap.MintLeg[] memory legs = _pancakeMintLegs();
        legs[2].maxAmountIn = 20e6 - 1; // CAKE's leg costs $20
        _expectMintReverts(legs, alice, abi.encodeWithSignature("V3TooMuchRequested()"));

        _mint(_pancakeMintLegs(), 1e18, 120e6);
        IIndexZap.BurnLeg[] memory out = _pancakeBurnLegs();
        out[2].minAmountOut = 20e6 + 1;
        _expectBurnReverts(out, alice, abi.encodeWithSignature("V3TooLittleReceived()"));
    }

    /// @dev A PancakeSwap pool that stops at its price limit sells half; the unsold half of that hop goes to `to`.
    function test_aPartialPancakeFillReturnsTheUnsoldInput() public {
        _mint(_pancakeMintLegs(), 1e18, 120e6);
        pancake.setMode(MockPancakeRouter.Mode.PartialFill);
        IIndexZap.BurnLeg[] memory out = new IIndexZap.BurnLeg[](3);
        out[0] = _burnLeg("", _cake(address(wbtc), address(usdc)));
        out[1] = _burnLeg("", _cake(address(weth), address(usdc)));
        out[2] = _burnLeg("", _cake(address(cake), address(usdc)));
        IIndexZap.BurnParams memory p = _burnParams(1e18, 1, out, alice);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectEmit(address(zap));
        emit IIndexZap.ComponentReturned(address(index), alice, address(wbtc), U_WBTC / 2);
        vm.expectEmit(address(zap));
        emit IIndexZap.ComponentReturned(address(index), alice, address(weth), U_WETH / 2);
        vm.expectEmit(address(zap));
        emit IIndexZap.ComponentReturned(address(index), alice, address(cake), U_CAKE / 2);
        assertEq(zap.burnToToken(p), 55e6, "half of each leg sold");
        vm.stopPrank();
        assertEq(cake.balanceOf(alice), U_CAKE / 2);
        assertEq(wbtc.balanceOf(alice), U_WBTC / 2);
        assertEq(weth.balanceOf(alice), U_WETH / 2);
        _assertNothingLeft();
    }

    // ---------------------------------------------------------------------
    // SV-1: a stray wei in PancakeSwap's router
    // ---------------------------------------------------------------------

    /// @dev SV-1. PancakeSwap's router takes ether from anyone and, after its last command, sends its whole ether
    ///      balance to the caller, reverting if that fails; the zap cannot receive ether. Without the zap's closing
    ///      WRAP_ETH, one wei sent to the router would revert every PancakeSwap leg of every zap until someone else's
    ///      call carried it off. With it, the wei is wrapped and stays in the router as WETH, and the legs go through.
    function test_SV1_strayEtherInThePancakeRouterCannotBlockALeg() public {
        // The hazard is real against this router: a caller that cannot take ether, sending what the zap sends but
        // without the wrap, reverts.
        NoEtherCaller victim = new NoEtherCaller();
        vm.deal(address(this), 2 wei);
        (bool sent,) = address(pancake).call{value: 1 wei}("");
        assertTrue(sent, "anyone can send the router ether");
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(usdc), address(victim), uint256(0));
        vm.prank(address(victim));
        vm.expectRevert(bytes("ETH_TRANSFER_FAILED"));
        victim.run(pancake, abi.encodePacked(uint8(0x04)), inputs);

        // The zap's legs go through, mint and burn.
        assertEq(_mint(_pancakeMintLegs(), 1e18, 120e6), 110e6);
        assertEq(address(pancake).balance, 0, "the wei was wrapped");
        assertEq(pancakeWeth.balanceOf(address(pancake)), 1 wei, "and stays in the router");
        (sent,) = address(pancake).call{value: 1 wei}("");
        assertTrue(sent);
        assertApproxEqAbs(_burn(_pancakeBurnLegs(), 1e18, 1), 110e6, 2);
        assertEq(address(pancake).balance, 0);
        assertEq(address(zap).balance, 0, "no ether ever reaches the zap");
    }

    // ---------------------------------------------------------------------
    // routes the zap refuses
    // ---------------------------------------------------------------------

    function test_aLegNamingTwoVenuesIsRefused() public {
        IIndexZap.MintLeg[] memory legs = _pancakeMintLegs();
        legs[1].v3Path = _uni(address(weth), address(usdc)); // Uniswap V3 and PancakeSwap
        _expectMintReverts(legs, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 1));
        legs = _pancakeMintLegs();
        legs[1].v4Path = _v4(address(usdc)); // Uniswap V4 and PancakeSwap
        _expectMintReverts(legs, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 1));

        _mint(_pancakeMintLegs(), 1e18, 120e6);
        IIndexZap.BurnLeg[] memory out = _pancakeBurnLegs();
        out[2].v3Path = _uni(address(cake), address(usdc));
        _expectBurnReverts(out, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 2));
        out = _pancakeBurnLegs();
        out[2].v4Path = _v4(address(usdc));
        _expectBurnReverts(out, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 2));
    }

    function test_aPancakePathWithTheWrongEndsIsRefused() public {
        IIndexZap.MintLeg[] memory legs = _pancakeMintLegs();
        legs[2].pancakePath = _cake(address(wbtc), address(usdc)); // starts at another component
        _expectMintReverts(legs, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 2));
        legs = _pancakeMintLegs();
        legs[2].pancakePath = _cake(address(cake), address(weth)); // ends short of what the user pays
        _expectMintReverts(legs, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 2));
        legs = _pancakeMintLegs();
        legs[2].pancakePath = abi.encodePacked(address(cake), CAKE_FEE); // not a path at all
        _expectMintReverts(legs, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 2));

        _mint(_pancakeMintLegs(), 1e18, 120e6);
        IIndexZap.BurnLeg[] memory out = _pancakeBurnLegs();
        out[0].pancakePath = _cake(address(wbtc), address(weth)); // ends in a third token
        _expectBurnReverts(out, alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 0));
    }

    /// @dev The pass-through leg, whose component is already the token paid or received, names no venue at all.
    function test_thePassThroughLegNamesNoPancakePath() public {
        address[] memory t = new address[](2);
        (t[0], t[1]) = (address(cake), address(usdc));
        _listWith(address(usdc));
        uint256[] memory u = new uint256[](2);
        (u[0], u[1]) = (U_CAKE, 50e6);
        WeightedHub mixed = _createIndex("Cake Dollar", "CAKED", t, u);

        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = _mintLeg("", _cake(address(cake), address(usdc)));
        legs[1] = _mintLeg("", _cake(address(usdc), address(usdc)));
        usdc.mint(alice, 100e6);
        IIndexZap.MintParams memory p = _mintParams(100e6, 1e18, legs, alice);
        p.index = address(mixed);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadRoute.selector, 1));
        zap.mintWithToken(p);
        // Without it, the mint goes through: CAKE through PancakeSwap, USDC as it is.
        p.legs[1] = _mintLeg("", "");
        assertEq(zap.mintWithToken(p), 70e6);
        vm.stopPrank();

        IIndexZap.BurnLeg[] memory out = new IIndexZap.BurnLeg[](2);
        out[0] = _burnLeg("", _cake(address(cake), address(usdc)));
        out[1] = _burnLeg("", _cake(address(usdc), address(usdc)));
        IIndexZap.BurnParams memory b = _burnParams(1e18, 1, out, alice);
        b.index = address(mixed);
        vm.startPrank(alice);
        mixed.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadRoute.selector, 1));
        zap.burnToToken(b);
        vm.stopPrank();
    }

    /// @dev A zap deployed without PancakeSwap, as on a testnet, refuses every PancakeSwap leg and still swaps on
    ///      Uniswap.
    function test_aZapWithoutPancakeRefusesPancakeLegs() public {
        zap = new IndexZap(IIndexFactory(address(factory)), router, IPancakeUniversalRouter(address(0)));
        assertEq(address(zap.PANCAKE_ROUTER()), address(0));
        _expectMintReverts(_pancakeMintLegs(), alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 0));

        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](3);
        legs[0] = _mintLeg(_uni(address(wbtc), address(usdc)), "");
        legs[1] = _mintLeg(_uni(address(weth), address(usdc)), "");
        legs[2] = _mintLeg(_uni(address(cake), address(usdc)), "");
        assertEq(_mint(legs, 1e18, 120e6), 110e6);
        _expectBurnReverts(_pancakeBurnLegs(), alice, abi.encodeWithSelector(IIndexZap.BadRoute.selector, 0));
    }

    /// @dev Anyone can sweep a router's balance, so neither router may be paid (RT-21).
    function test_thePancakeRouterIsNeverARecipient() public {
        _expectMintReverts(
            _pancakeMintLegs(),
            address(pancake),
            abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(pancake))
        );
        _mint(_pancakeMintLegs(), 1e18, 120e6);
        _expectBurnReverts(
            _pancakeBurnLegs(),
            address(pancake),
            abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(pancake))
        );
    }

    /// @dev PancakeSwap's owner can pause its router. That stops the PancakeSwap legs and moves nobody's funds: the
    ///      mint reverts whole, and the same mint routed through Uniswap goes through.
    function test_aPausedPancakeRouterStopsOnlyItsLegs() public {
        pancake.setPaused(true);
        _expectMintReverts(_pancakeMintLegs(), alice, bytes("Pausable: paused"));
        assertEq(usdc.balanceOf(address(pancake)), 0, "nothing stranded in the router");

        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](3);
        legs[0] = _mintLeg(_uni(address(wbtc), address(usdc)), "");
        legs[1] = _mintLeg(_uni(address(weth), address(usdc)), "");
        legs[2] = _mintLeg(_uni(address(cake), address(usdc)), "");
        assertEq(_mint(legs, 1e18, 120e6), 110e6);
    }

    /// @dev The zap names itself everywhere a router could pay someone; a stray balance of `tokenIn` in the router
    ///      comes back through the sweep and enlarges the refund, as on Uniswap (CR-L02).
    function test_aStrayBalanceInThePancakeRouterIsRefunded() public {
        usdc.mint(address(pancake), 7e6);
        uint256 spent = _mint(_pancakeMintLegs(), 1e18, 120e6);
        assertEq(spent, 110e6 - 7e6, "the stray enlarged the refund");
        assertEq(usdc.balanceOf(address(pancake)), 0);
    }
}
