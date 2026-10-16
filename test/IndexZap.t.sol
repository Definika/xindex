// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IIndexHub} from "../src/interfaces/IIndexHub.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {PathLib} from "../src/libraries/PathLib.sol";
import {PathKey, V4ExactInputParams, V4ExactOutputParams} from "../src/libraries/UniswapV4Types.sol";

contract IndexZapTest is XindexTest {
    IndexZap zap;
    MockUniversalRouter router;
    address poolManager;
    WeightedHub index;

    MockERC20 wbtc; // 8
    MockERC20 weth; // 18
    MockERC20 link; // 18
    MockERC20 usdc; // 6
    MockUSDT usdt; // 6

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // 0.001 WBTC ($60) + 0.01 WETH ($30) + 1 LINK ($15) = $105 per index token
    uint256 constant U_WBTC = 100_000;
    uint256 constant U_WETH = 1e16;
    uint256 constant U_LINK = 1e18;
    uint256 constant NAV_USD6 = 105e6;
    /// @dev USDC's units in the suite's dollar indexes.
    uint256 constant U_USDC = 50e6;
    /// @dev The smallest holding an index may start with, the factory's `MIN_RAW_UNITS`: 0.01 USDC.
    uint256 constant U_DUST = 1e4;

    uint24 constant FEE = 500;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(address(0));
        // A plain address stands in for the V4 singleton: the zap only ever reads it, to keep it off the recipient
        // list, and the mock router never settles against it.
        poolManager = makeAddr("poolManager");
        router = new MockUniversalRouter(poolManager);
        zap = new IndexZap(IIndexFactory(address(factory)), router);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = market.usdc();
        usdt = new MockUSDT();

        router.setPrice(address(wbtc), 60_000e18, 8);
        router.setPrice(address(weth), 3_000e18, 18);
        router.setPrice(address(link), 15e18, 18);
        router.setPrice(address(usdc), 1e18, 6);
        router.setPrice(address(usdt), 1e18, 6);

        wbtc.mint(address(router.inventory()), 1_000e8);
        weth.mint(address(router.inventory()), 100_000e18);
        link.mint(address(router.inventory()), 10_000_000e18);
        usdc.mint(address(router.inventory()), 1_000_000_000e6);
        usdt.mint(address(router.inventory()), 1_000_000_000e6);

        _listWith(address(wbtc));
        _listWith(address(weth));
        _listWith(address(link));
        _listWith(address(usdc));

        address[] memory t = new address[](3);
        t[0] = address(wbtc);
        t[1] = address(weth);
        t[2] = address(link);
        uint256[] memory u = new uint256[](3);
        (u[0], u[1], u[2]) = (U_WBTC, U_WETH, U_LINK);
        index = _createIndex("Blue Chip", "BLUE", t, u);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// @dev An empty V4 route, for a leg that names a V3 path.
    /// @dev A swap's revert reaches the caller unchanged: the router dispatches swaps as internal calls, so the
    ///      pool's own slippage error is what surfaces, not the router's `ExecutionFailed` wrapper.
    function _wrapped(string memory innerSignature) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(innerSignature);
    }

    function _noV4() internal pure returns (PathKey[] memory) {
        return new PathKey[](0);
    }

    /// @dev A hookless two-hop V4 route for a burn: the router walks it forwards from the component, so `mid` comes
    ///      first and the payout last.
    function _v4BurnPath(address mid, address tokenOut) internal pure returns (PathKey[] memory path) {
        path = new PathKey[](2);
        path[0] = _hop(mid);
        path[1] = _hop(tokenOut);
    }

    /// @dev The same route for a mint, which the router walks backwards from the component, so what the user pays
    ///      with comes first and `mid` last. Getting this the wrong way round is what BadRoute catches.
    function _v4MintPath(address stable, address mid) internal pure returns (PathKey[] memory path) {
        path = new PathKey[](2);
        path[0] = _hop(stable);
        path[1] = _hop(mid);
    }

    function _hop(address currency) internal pure returns (PathKey memory) {
        return PathKey({intermediateCurrency: currency, fee: FEE, tickSpacing: 10, hooks: address(0), hookData: ""});
    }

    /// @dev A single-hop hookless V4 route. One hop reads the same either way round.
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

    /// @dev mint legs: component -> ... -> stable (exact-output encoding, reversed), no per-leg limit
    function _mintLegs(address stable) internal view returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path3(address(wbtc), address(weth), stable), v4Path: _noV4(), maxAmountIn: 0
        });
        legs[1] =
            IUniversalRouterSwaps.MintLeg({v3Path: _path2(address(weth), stable), v4Path: _noV4(), maxAmountIn: 0});
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path3(address(link), address(weth), stable), v4Path: _noV4(), maxAmountIn: 0
        });
    }

    /// @dev burn legs: component -> ... -> tokenOut (exact-input encoding), no per-leg limit
    function _burnLegs(address tokenOut) internal view returns (IUniversalRouterSwaps.BurnLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path3(address(wbtc), address(weth), tokenOut), v4Path: _noV4(), minAmountOut: 0
        });
        legs[1] =
            IUniversalRouterSwaps.BurnLeg({v3Path: _path2(address(weth), tokenOut), v4Path: _noV4(), minAmountOut: 0});
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path3(address(link), address(weth), tokenOut), v4Path: _noV4(), minAmountOut: 0
        });
    }

    function _mintParams(
        address idx,
        address tokenIn,
        uint256 maxIn,
        uint256 shares,
        IUniversalRouterSwaps.MintLeg[] memory legs,
        address to
    ) internal view returns (IIndexZap.MintParams memory) {
        return IIndexZap.MintParams({
            index: idx,
            expectedNonce: 0,
            tokenIn: tokenIn,
            maxAmountIn: maxIn,
            shares: shares,
            legs: legs,
            to: to,
            deadline: block.timestamp,
            referrer: address(0)
        });
    }

    function _burnParams(
        address idx,
        uint256 shares,
        address tokenOut,
        uint256 minOut,
        IUniversalRouterSwaps.BurnLeg[] memory legs,
        address to
    ) internal view returns (IIndexZap.BurnParams memory) {
        return IIndexZap.BurnParams({
            index: idx,
            expectedNonce: 0,
            shares: shares,
            tokenOut: tokenOut,
            minAmountOut: minOut,
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    function _mintFor(address who, uint256 shares, uint256 maxIn) internal returns (uint256 spent) {
        usdc.mint(who, maxIn);
        vm.startPrank(who);
        usdc.approve(address(zap), maxIn);
        spent =
            zap.mintWithToken(_mintParams(address(index), address(usdc), maxIn, shares, _mintLegs(address(usdc)), who));
        vm.stopPrank();
    }

    /// @dev 0.01 WETH + 50 USDC, so USDC is both the mint currency and a component.
    function _mixedIndex() internal returns (WeightedHub idx) {
        idx = _createIndex("Mixed", "MIX", _pair(address(weth), address(usdc)), _pair(U_WETH, U_USDC));
    }

    /// @dev A whole WETH a token beside USDC's smallest holding, `MIN_RAW_UNITS`: a basket whose one swapped leg is
    ///      WETH, since an index holds at least two components. USDC is paid out as it is on a burn to USDC.
    function _etherIndex() internal returns (WeightedHub idx) {
        idx = _createIndex("Ether", "ETH1", _pair(address(weth), address(usdc)), _pair(1e18, U_DUST));
    }

    /// @dev Issues one token of `_etherIndex` to `who`, in kind.
    function _issueEther(WeightedHub idx, address who) internal {
        weth.mint(who, 1e18);
        usdc.mint(who, U_DUST);
        vm.startPrank(who);
        weth.approve(address(idx), 1e18);
        usdc.approve(address(idx), U_DUST);
        idx.issue(1e18, who);
        vm.stopPrank();
    }

    /// @dev Burn legs for `_etherIndex` into USDC: WETH along the given route, USDC passed through.
    function _etherBurnLegs(bytes memory v3Path, PathKey[] memory v4Path)
        internal
        pure
        returns (IUniversalRouterSwaps.BurnLeg[] memory legs)
    {
        legs = new IUniversalRouterSwaps.BurnLeg[](2);
        legs[0] = IUniversalRouterSwaps.BurnLeg({v3Path: v3Path, v4Path: v4Path, minAmountOut: 0});
        legs[1] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: new PathKey[](0), minAmountOut: 0});
    }

    function _mixedLegs() internal view returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](2);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path2(address(weth), address(usdc)), v4Path: _noV4(), maxAmountIn: 0
        });
        legs[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _noV4(), maxAmountIn: 0});
    }

    function _assertZapEmpty() internal view {
        assertEq(wbtc.balanceOf(address(zap)), 0, "zap wbtc");
        assertEq(weth.balanceOf(address(zap)), 0, "zap weth");
        assertEq(link.balanceOf(address(zap)), 0, "zap link");
        assertEq(usdc.balanceOf(address(zap)), 0, "zap usdc");
        assertEq(usdt.balanceOf(address(zap)), 0, "zap usdt");
        assertEq(index.balanceOf(address(zap)), 0, "zap index");
    }

    function _permitSig(uint256 pk, address signer, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(zap),
                value,
                index.nonces(signer),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", index.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    // ---------------------------------------------------------------------
    // constructor
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(address(zap.FACTORY()), address(factory));
        assertEq(address(zap.ROUTER()), address(router));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexZap(IIndexFactory(address(0)), router);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(address(0)));
    }

    // ---------------------------------------------------------------------
    // mint
    // ---------------------------------------------------------------------

    function test_mint_withUSDC_exactSharesAndRefund() public {
        uint256 maxIn = 110e6;
        usdc.mint(alice, maxIn);
        vm.startPrank(alice);
        usdc.approve(address(zap), maxIn);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ZapMint(address(index), alice, alice, address(usdc), NAV_USD6, 1e18);
        uint256 spent =
            zap.mintWithToken(_mintParams(address(index), address(usdc), maxIn, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();

        assertEq(spent, NAV_USD6);
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(usdc.balanceOf(alice), maxIn - NAV_USD6, "refund");
        assertEq(wbtc.balanceOf(address(index)), U_WBTC);
        assertEq(weth.balanceOf(address(index)), U_WETH);
        assertEq(link.balanceOf(address(index)), U_LINK);
        assertEq(usdc.allowance(address(zap), address(router)), 0, "router allowance cleared");
        _assertZapEmpty();
    }

    function test_mint_toOtherAddress() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), bob));
        vm.stopPrank();
        assertEq(index.balanceOf(bob), 1e18);
        assertEq(index.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 200e6 - NAV_USD6);
    }

    function test_mint_withUSDT_nonStandardToken() public {
        usdt.mint(alice, 300e6);
        vm.startPrank(alice);
        usdt.approve(address(zap), 300e6);
        uint256 spent =
            zap.mintWithToken(_mintParams(address(index), address(usdt), 300e6, 2e18, _mintLegs(address(usdt)), alice));
        usdt.mint(alice, 300e6);
        usdt.approve(address(zap), 300e6);
        zap.mintWithToken(_mintParams(address(index), address(usdt), 300e6, 1e18, _mintLegs(address(usdt)), alice));
        vm.stopPrank();

        assertEq(spent, 2 * NAV_USD6);
        assertEq(index.balanceOf(alice), 3e18);
        assertEq(usdt.balanceOf(alice), 600e6 - 3 * NAV_USD6);
        _assertZapEmpty();
    }

    function test_mint_fractionalShares() public {
        uint256 shares = 123456789012345678;
        uint256[] memory need = index.previewIssue(shares);
        uint256 expectedSpend = router.quoteIn(address(usdc), address(wbtc), need[0])
            + router.quoteIn(address(usdc), address(weth), need[1])
            + router.quoteIn(address(usdc), address(link), need[2]);

        uint256 spent = _mintFor(alice, shares, 100e6);
        assertEq(spent, expectedSpend);
        assertEq(index.balanceOf(alice), shares);
        _assertZapEmpty();
    }

    function test_mint_tokenInIsComponent() public {
        WeightedHub idx = _mixedIndex();
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        uint256 spent = zap.mintWithToken(_mintParams(address(idx), address(usdc), 100e6, 1e18, _mixedLegs(), alice));
        vm.stopPrank();

        assertEq(spent, 30e6 + 50e6);
        assertEq(idx.balanceOf(alice), 1e18);
        assertEq(usdc.balanceOf(address(idx)), 50e6);
        assertEq(weth.balanceOf(address(idx)), U_WETH);
        assertEq(usdc.balanceOf(alice), 20e6);
        assertEq(usdc.balanceOf(address(zap)), 0);

        // The swap budget excludes the USDC the basket itself holds.
        usdc.mint(alice, 79e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 79e6);
        vm.expectRevert(_wrapped("V3TooMuchRequested()"));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 79e6, 1e18, _mixedLegs(), alice));
        vm.stopPrank();
    }

    function test_mint_revertsInsufficientBudget() public {
        WeightedHub idx = _mixedIndex();
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientBudget.selector, 50e6, 10e6));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 10e6, 1e18, _mixedLegs(), alice));
        vm.stopPrank();
    }

    function test_mint_revertsTokenInComponentWithNonEmptyPath() public {
        WeightedHub idx = _mixedIndex();
        IUniversalRouterSwaps.MintLeg[] memory legs = _mixedLegs();
        legs[1].v3Path = _path2(address(usdc), address(usdc));
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 100e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_mint_revertsWhenMaxAmountInTooLow() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert(_wrapped("V3TooMuchRequested()"));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 100e6, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_mint_legCapsWithinBudgetSucceed() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = 60e6;
        legs[1].maxAmountIn = 30e6;
        legs[2].maxAmountIn = 15e6;
        usdc.mint(alice, 110e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 110e6);
        uint256 spent = zap.mintWithToken(_mintParams(address(index), address(usdc), 110e6, 1e18, legs, alice));
        vm.stopPrank();
        assertEq(spent, NAV_USD6);
    }

    function test_mint_legCapStopsOverpayingOneLeg() public {
        uint256 maxIn = NAV_USD6 + NAV_USD6 / 100; // 1% overall
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = 60_600_000; // 1% per leg
        legs[1].maxAmountIn = 30_300_000;
        legs[2].maxAmountIn = 15_150_000;
        usdc.mint(alice, maxIn);
        vm.prank(alice);
        usdc.approve(address(zap), maxIn);

        router.setPrice(address(link), 16.05e18, 18); // a sandwich moves only the LINK leg, by 7%

        vm.prank(alice);
        vm.expectRevert(_wrapped("V3TooMuchRequested()"));
        zap.mintWithToken(_mintParams(address(index), address(usdc), maxIn, 1e18, legs, alice));
    }

    function test_mint_legCapAboveBudgetFallsBackToBudget() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = type(uint256).max;
        legs[1].maxAmountIn = type(uint256).max;
        legs[2].maxAmountIn = type(uint256).max;
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert(_wrapped("V3TooMuchRequested()"));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 100e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_mint_revertsBadPaths() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);

        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].v3Path = _path3(address(link), address(weth), address(usdc)); // should start with wbtc
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 0));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs = _mintLegs(address(usdc));
        legs[2].v3Path = _path3(address(link), address(weth), address(usdt)); // should end with usdc
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs = _mintLegs(address(usdc));
        legs[1].v3Path = abi.encodePacked(address(weth), address(usdc)); // missing fee
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs[1].v3Path = "";
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_mint_revertsChecks() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        IIndexZap.MintParams memory p =
            _mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), alice);

        p.deadline = block.timestamp - 1;
        vm.expectRevert(IXindexErrors.Expired.selector);
        zap.mintWithToken(p);

        p.deadline = block.timestamp;
        p.index = address(usdc);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(usdc)));
        zap.mintWithToken(p);

        p.index = address(index);
        p.legs = new IUniversalRouterSwaps.MintLeg[](2);
        vm.expectRevert(IIndexZap.LegCountMismatch.selector);
        zap.mintWithToken(p);
        vm.stopPrank();
    }

    function test_mint_revertsStaleRebalanceNonce() public {
        IIndexZap.MintParams memory p =
            _mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), alice);
        p.expectedNonce = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 1, 0));
        zap.mintWithToken(p);
    }

    function test_mint_revertsZeroAmounts() public {
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 100e6, 0, _mintLegs(address(usdc)), alice));
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 0, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    function test_mint_revertsInvalidRecipients() public {
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 1, 1e18, _mintLegs(address(usdc)), address(0)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(zap)));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 1, 1e18, _mintLegs(address(usdc)), address(zap)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 1, 1e18, _mintLegs(address(usdc)), address(index)));
        vm.stopPrank();
    }

    function test_mint_rejectsFeeOnTransferTokenIn() public {
        MockFeeToken fot = new MockFeeToken();
        router.setPrice(address(fot), 1e18, 18);
        fot.mint(alice, 200e18);
        vm.startPrank(alice);
        fot.approve(address(zap), 200e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TransferShortfall.selector, address(fot)));
        zap.mintWithToken(_mintParams(address(index), address(fot), 200e18, 1e18, _mintLegs(address(fot)), alice));
        vm.stopPrank();
    }

    function test_mint_leavesStrayTokenInUntouched() public {
        usdc.mint(address(zap), 1_000e6);
        uint256 spent = _mintFor(alice, 1e18, 110e6);
        assertEq(spent, NAV_USD6);
        assertEq(usdc.balanceOf(alice), 110e6 - NAV_USD6);
        assertEq(usdc.balanceOf(address(zap)), 1_000e6);
    }

    // ---------------------------------------------------------------------
    // burn
    // ---------------------------------------------------------------------

    function test_burn_toUSDT() public {
        _mintFor(alice, 2e18, 300e6);
        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ZapBurn(address(index), alice, alice, address(usdt), 2e18, 2 * NAV_USD6);
        uint256 out = zap.burnToToken(
            _burnParams(address(index), 2e18, address(usdt), 2 * NAV_USD6, _burnLegs(address(usdt)), alice)
        );
        vm.stopPrank();

        assertEq(out, 2 * NAV_USD6);
        assertEq(usdt.balanceOf(alice), 2 * NAV_USD6);
        assertEq(index.balanceOf(alice), 0);
        assertEq(index.totalSupply(), 0);
        assertEq(wbtc.balanceOf(address(index)), 0);
        _assertZapEmpty();
    }

    function test_burn_partial_toOtherAddress() public {
        _mintFor(alice, 2e18, 300e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), bob));
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), NAV_USD6);
        assertEq(index.balanceOf(alice), 1e18);
        assertEq(wbtc.balanceOf(address(index)), U_WBTC);
    }

    function test_burn_toWBTC_componentIsTokenOut() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: _noV4(), minAmountOut: 0});
        legs[1] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path2(address(weth), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path3(address(link), address(weth), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });

        // $105 of WBTC at $60k = 0.00175 BTC = 175_000 sats
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(_burnParams(address(index), 1e18, address(wbtc), 175_000, legs, alice));
        vm.stopPrank();

        assertEq(out, 175_000);
        assertEq(wbtc.balanceOf(alice), 175_000);
        _assertZapEmpty();
    }

    /// @dev DA-15. The leg whose component is already `tokenOut` carries no swap, and its `minAmountOut` was never
    ///      read, so the one limit the NatSpec, the README and AGENTS.md all promise applies to every leg silently did
    ///      not apply to that one. The mint side had the same hole for `maxAmountIn` on the `tokenIn` leg.
    function test_DA15_thePassThroughLegHonoursItsOwnLimit() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](3);
        // The pass-through leg can only hand over the WBTC the index held, 100,000 sats a share: ask for one more.
        legs[0] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: _noV4(), minAmountOut: 100_001});
        legs[1] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path2(address(weth), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path3(address(link), address(weth), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientOutput.selector, 100_000, 100_001));
        zap.burnToToken(_burnParams(address(index), 1e18, address(wbtc), 1, legs, alice));

        // Exactly what it can give is accepted.
        legs[0].minAmountOut = 100_000;
        zap.burnToToken(_burnParams(address(index), 1e18, address(wbtc), 1, legs, alice));
        vm.stopPrank();
        _assertZapEmpty();
    }

    function test_DA15_theMintPassThroughLegHonoursItsBudget() public {
        // WETH is a component and also the token paid in, so its leg carries no swap.
        uint256[] memory need = index.previewIssue(1e18);
        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](3);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path2(address(wbtc), address(weth)), v4Path: _noV4(), maxAmountIn: 0
        });
        legs[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _noV4(), maxAmountIn: need[1] - 1});
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path2(address(link), address(weth)), v4Path: _noV4(), maxAmountIn: 0
        });

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientBudget.selector, need[1], need[1] - 1));
        zap.mintWithToken(_mintParams(address(index), address(weth), 1e18, 1e18, legs, alice));

        legs[1].maxAmountIn = need[1];
        zap.mintWithToken(_mintParams(address(index), address(weth), 1e18, 1e18, legs, alice));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
        _assertZapEmpty();
    }

    function test_burn_revertsComponentIsTokenOutWithNonEmptyPath() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path2(address(wbtc), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });
        legs[1] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path2(address(weth), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path3(address(link), address(weth), address(wbtc)), v4Path: _noV4(), minAmountOut: 0
        });
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 0));
        zap.burnToToken(_burnParams(address(index), 1e18, address(wbtc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_burn_revertsInsufficientOutput() public {
        _mintFor(alice, 1e18, 200e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientOutput.selector, NAV_USD6, NAV_USD6 + 1));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), NAV_USD6 + 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
    }

    function test_burn_legMinimumEnforced() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2].minAmountOut = 15_000_001; // the LINK leg returns exactly 15 USDC
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(_wrapped("V3TooLittleReceived()"));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_burn_revertsBadPath() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[1].v3Path = _path2(address(weth), address(usdt));
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_burn_tinySharesSkipsZeroLegs() public {
        _mintFor(alice, 1e18, 200e6);
        // 1e12 shares: the WBTC leg floors to 0 and sells nothing, but its path is still checked
        vm.startPrank(alice);
        index.approve(address(zap), 1e12);
        uint256 out =
            zap.burnToToken(_burnParams(address(index), 1e12, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(out, 30 + 15);
        assertEq(index.balanceOf(alice), 1e18 - 1e12);
    }

    /// @dev LR-05: a leg's minimum is in `tokenOut` and applies to the last hop only. No test told that from a minimum
    ///      on every hop, because the intermediate amounts were always the larger numbers. Here 1 LINK sells for 25,000
    ///      raw WBTC and then 15,000,000 raw USDC, so a USDC minimum on the first hop could never be met.
    function test_LR05_aLegMinimumAppliesToTheLastHopOnly() public {
        _mintFor(alice, 2e18, 400e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path3(address(link), address(wbtc), address(usdc)), v4Path: _noV4(), minAmountOut: 15e6
        });
        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        assertEq(zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice)), NAV_USD6);

        legs[2].minAmountOut = 15e6 + 1; // and on the last hop it binds
        vm.expectRevert(_wrapped("V3TooLittleReceived()"));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_XA29_zeroLegsAreStillValidatedAndTheirMinimumsApply() public {
        _mintFor(alice, 1e18, 200e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e12);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[0].v3Path = ""; // the WBTC leg sells nothing for 1e12 shares, yet a malformed path is rejected
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 0));
        zap.burnToToken(_burnParams(address(index), 1e12, address(usdc), 1, legs, alice));

        legs = _burnLegs(address(usdc));
        legs[0].minAmountOut = 1; // a minimum on a leg that sells nothing cannot be met
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientOutput.selector, 0, 1));
        zap.burnToToken(_burnParams(address(index), 1e12, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    /// @dev XA-30, and CR-I23, which found the PoolManager half of it untested: the v3 retirement ledger said this
    ///      test covered both, but it only ever named the router, and dropping `to == POOL_MANAGER` passed every test.
    ///      Tokens delivered to the Universal Router can be swept by anyone, and anything sent to the PoolManager is a
    ///      donation to it, so neither may receive a mint's shares or a burn's payout.
    function test_XA30_CRI23_neitherTheRouterNorThePoolManagerIsAValidRecipient() public {
        address[2] memory sinks = [address(router), poolManager];
        vm.startPrank(alice);
        for (uint256 i = 0; i < sinks.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, sinks[i]));
            zap.mintWithToken(_mintParams(address(index), address(usdc), 1, 1e18, _mintLegs(address(usdc)), sinks[i]));
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, sinks[i]));
            zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), sinks[i]));
        }
        vm.stopPrank();
    }

    /// @dev RT-21, the zap's half. The factory can never move a token on, so a burn's payout sent to it was lost; a mint
    ///      to it already reverted in the index, and now reverts here first. (The v3 rule, the other trap, is gone.)
    function test_RT21_theFactoryIsNotAValidZapRecipient() public {
        address[1] memory traps = [address(factory)];
        vm.startPrank(alice);
        for (uint256 i = 0; i < traps.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, traps[i]));
            zap.mintWithToken(_mintParams(address(index), address(usdc), 1, 1e18, _mintLegs(address(usdc)), traps[i]));
            vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, traps[i]));
            zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), traps[i]));
        }
        vm.stopPrank();
    }

    function test_XA22_mintRechecksTheRebalanceNonceBeforeIssuing() public {
        uint256 maxIn = 110e6;
        usdc.mint(alice, maxIn);
        vm.prank(alice);
        usdc.approve(address(zap), maxIn);
        IIndexZap.MintParams memory p =
            _mintParams(address(index), address(usdc), maxIn, 1e18, _mintLegs(address(usdc)), alice);
        // A callback during the swaps settles a rebalance: the check on entry reads 0, the read before issue reads 1.
        bytes[] memory nonces = new bytes[](2);
        nonces[0] = abi.encode(uint256(0));
        nonces[1] = abi.encode(uint256(1));
        vm.mockCalls(address(index), abi.encodeWithSelector(IIndexHub.rebalanceNonce.selector), nonces);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        zap.mintWithToken(p);
    }

    /// @dev LR-05: the XA-22 test above only proves the nonce is read twice, so a recheck moved in front of the swaps
    ///      passed it. Here a rebalance really settles in the middle of a mint: the minter pays with a callback token,
    ///      and its hook fills the auction when the zap refunds it, after the swaps and before `issue`. Only a check
    ///      placed right before `issue` sees the new nonce; without one, `issue` would pull the new basket against
    ///      approvals sized for the old one and fail with an allowance error instead.
    function test_LR05_aRebalanceSettledDuringTheRefundStopsTheMint() public {
        _mintFor(alice, 1e18, 200e6);
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta);

        // At the router's prices the basket holds $60, $30 and $15 against equal weights, so the fill trades.
        bytes[] memory updates = new bytes[](3);
        uint64 time = uint64(index.priceTime());
        updates[0] = pyth.update(_priceId(address(wbtc)), 60_000e8, 0, -8, time, time - 1);
        updates[1] = pyth.update(_priceId(address(weth)), 3_000e8, 0, -8, time, time - 1);
        updates[2] = pyth.update(_priceId(address(link)), 15e8, 0, -8, time, time - 1);

        MockHookToken hook = new MockHookToken();
        router.setPrice(address(hook), 1e18, 18);
        RebalancingMinter minter = new RebalancingMinter(zap, index, new MockWeightedExecutor(), updates);
        hook.mint(address(minter), 200e18);

        IIndexZap.MintParams memory p =
            _mintParams(address(index), address(hook), 200e18, 1e18, _mintLegs(address(hook)), address(minter));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        minter.mint(p);
        assertEq(index.rebalanceNonce(), 0, "the whole mint unwound, the settlement with it");
    }

    function test_burn_revertsWithoutApproval() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(zap), 0, 1e18));
        zap.burnToToken(p);
    }

    function test_burn_revertsZeroAmounts() public {
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        zap.burnToToken(_burnParams(address(index), 0, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.expectRevert(IXindexErrors.ZeroAmount.selector);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 0, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    function test_burn_revertsInvalidRecipients() public {
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(0)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(zap)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(zap)));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(index)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(index)));
        vm.stopPrank();
    }

    function test_burn_revertsChecks() public {
        _mintFor(alice, 1e18, 200e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice);

        p.deadline = block.timestamp - 1;
        vm.expectRevert(IXindexErrors.Expired.selector);
        zap.burnToToken(p);

        p.deadline = block.timestamp;
        p.index = address(weth);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(weth)));
        zap.burnToToken(p);

        p.index = address(index);
        p.legs = new IUniversalRouterSwaps.BurnLeg[](1);
        vm.expectRevert(IIndexZap.LegCountMismatch.selector);
        zap.burnToToken(p);
        vm.stopPrank();
    }

    function test_burn_revertsStaleRebalanceNonce() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice);
        p.expectedNonce = 7;
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 7, 0));
        zap.burnToToken(p);
        vm.stopPrank();
    }

    function test_burn_rejectsFeeOnTransferPayout() public {
        MockFeeToken fot = new MockFeeToken();
        router.setPrice(address(fot), 1e18, 18);
        fot.mint(address(router.inventory()), 1_000_000e18);
        _mintFor(alice, 1e18, 200e6);

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.TransferShortfall.selector, address(fot)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(fot), 1, _burnLegs(address(fot)), alice));
        vm.stopPrank();
    }

    function test_burn_partialFillReturnsUnsoldComponent() public {
        WeightedHub idx = _etherIndex();
        _issueEther(idx, alice);
        vm.startPrank(alice);
        idx.approve(address(zap), 1e18);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _etherBurnLegs(_path2(address(weth), address(usdc)), _noV4());

        // The pool stops at its price limit and takes half the input.
        router.setMode(MockUniversalRouter.Mode.PartialFirstHop);

        // An overall minimum above what half the basket sells for still reverts.
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientOutput.selector, 1_500e6 + U_DUST, 2_970e6));
        zap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 2_970e6, legs, alice));

        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ComponentReturned(address(idx), bob, address(weth), 5e17);
        uint256 out = zap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1_000e6, legs, bob));
        vm.stopPrank();

        assertEq(out, 1_500e6 + U_DUST, "half the WETH sold, and the USDC held as it is");
        assertEq(usdc.balanceOf(bob), 1_500e6 + U_DUST);
        assertEq(weth.balanceOf(bob), 5e17, "the unsold half goes to the recipient");
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(router)), 0, "and nothing is left in the router to be swept by anyone");
    }

    function test_burn_leavesStrayTokenOutUntouched() public {
        _mintFor(alice, 1e18, 200e6);
        usdc.mint(address(zap), 1_000e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out =
            zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(out, NAV_USD6);
        assertEq(usdc.balanceOf(address(zap)), 1_000e6);
    }

    // ---------------------------------------------------------------------
    // V4 legs and route validation
    // ---------------------------------------------------------------------

    /// @dev The bytes the zap hands the router for a V4 mint leg: the command and action bytes as literals, the
    ///      settle, take and sweep inputs, and the direction of the route. It decodes the swap parameters with the
    ///      zap's own `V4ExactOutputParams`, so it cannot see a field of that struct out of place -- a mock written
    ///      against the same declaration agrees with the mistake. The field order is pinned against upstream's layout,
    ///      declared independently of src, by the CR-I36 tests below (CR-I36).
    function test_route_v4MintEncodesTheActionsTheRouterDecodes() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: "", v4Path: _v4MintPath(address(usdc), address(weth)), maxAmountIn: 0
        });
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));
        vm.stopPrank();

        // The LINK leg is the last swap, so the recorded call is its own: a V4 swap then a sweep.
        assertEq(zap.ROUTER().poolManager(), poolManager);
        assertEq(router.lastCommands(), abi.encodePacked(uint8(0x10), uint8(0x04)), "V4_SWAP then SWEEP");

        (bytes memory actions, bytes[] memory params) = abi.decode(router.lastInput(0), (bytes, bytes[]));
        assertEq(actions, abi.encodePacked(uint8(0x09), uint8(0x0b), uint8(0x0e)), "swap exact out, settle, take");

        V4ExactOutputParams memory swap = abi.decode(params[0], (V4ExactOutputParams));
        assertEq(swap.currencyOut, address(link), "the zap names the component, never the caller");
        assertEq(
            swap.path[0].intermediateCurrency,
            address(usdc),
            "walked backwards, so entry zero is what the user pays with"
        );
        assertEq(swap.path[1].intermediateCurrency, address(weth));

        (address settleCurrency, uint256 settleAmount, bool payerIsUser) =
            abi.decode(params[1], (address, uint256, bool));
        assertEq(settleCurrency, address(usdc));
        assertEq(settleAmount, 0, "OPEN_DELTA: settle the whole debt");
        assertFalse(payerIsUser, "the router pays from what the zap pre-funded, never from the caller");

        (address takeCurrency, address takeRecipient, uint256 takeAmount) =
            abi.decode(params[2], (address, address, uint256));
        assertEq(takeCurrency, address(link));
        assertEq(takeRecipient, address(zap));
        assertEq(takeAmount, 0, "OPEN_DELTA: take the whole credit");

        (address sweepToken, address sweepTo, uint256 sweepMin) =
            abi.decode(router.lastInput(1), (address, address, uint256));
        assertEq(sweepToken, address(usdc));
        assertEq(sweepTo, address(zap), "nothing is left in the router for anyone to sweep");
        assertEq(sweepMin, 0);
    }

    function test_mint_v4LegBuysTheSameBasketAsV3() public {
        IUniversalRouterSwaps.MintLeg[] memory v4 = _mintLegs(address(usdc));
        v4[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: "", v4Path: _v4MintPath(address(usdc), address(weth)), maxAmountIn: 0
        });
        v4[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), maxAmountIn: 0});
        v4[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: "", v4Path: _v4MintPath(address(usdc), address(weth)), maxAmountIn: 0
        });

        usdc.mint(alice, 300e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 300e6);
        uint256 spent = zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, v4, alice));
        vm.stopPrank();

        assertEq(spent, NAV_USD6, "a V4 leg buys the same basket for the same money");
        assertEq(index.balanceOf(alice), 1e18);
        _assertZapEmpty();
    }

    function test_mixedBasket_v3AndV4Legs() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), maxAmountIn: 0});

        usdc.mint(alice, 300e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 300e6);
        uint256 spent = zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, legs, alice));

        IUniversalRouterSwaps.BurnLeg[] memory out = _burnLegs(address(usdc));
        out[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4BurnPath(address(weth), address(usdc)), minAmountOut: 0
        });
        index.approve(address(zap), 1e18);
        uint256 back = zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, out, alice));
        vm.stopPrank();

        assertEq(spent, NAV_USD6);
        assertEq(back, NAV_USD6, "one basket, two venues, the same round trip");
        _assertZapEmpty();
    }

    function test_burn_v4LegSellsThroughOneAction() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        // The last leg, so the call the router recorded is this one's.
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4BurnPath(address(weth), address(usdc)), minAmountOut: 0
        });

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
        assertEq(out, NAV_USD6);

        (bytes memory actions, bytes[] memory params) = abi.decode(router.lastInput(0), (bytes, bytes[]));
        assertEq(actions, abi.encodePacked(uint8(0x07), uint8(0x0b), uint8(0x0e)), "swap exact in, settle, take");
        V4ExactInputParams memory swap = abi.decode(params[0], (V4ExactInputParams));
        assertEq(swap.path[swap.path.length - 1].intermediateCurrency, address(usdc), "the route ends at the payout");
    }

    /// @dev A leg names one venue. Both would be ambiguous; neither is only ever right for the pass-through leg,
    ///      which is handled before a route is read at all.
    function test_route_rejectsBothVenuesOrNeither() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[2].v4Path = _v4MintPath(address(usdc), address(weth)); // now carries a V3 path as well
        usdc.mint(alice, 300e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 300e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, legs, alice));

        legs[2] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _noV4(), maxAmountIn: 0}); // neither
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    /// @dev A hook is arbitrary code running inside the swap, able to move the very deltas the zap measures. Rejecting
    ///      any hook is one equality, and it also rules out a dynamic fee, which only a hooked pool can carry.
    function test_route_rejectsHookedHopsAndHookData() public {
        usdc.mint(alice, 600e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 600e6);

        IUniversalRouterSwaps.MintLeg[] memory hooked = _mintLegs(address(usdc));
        PathKey[] memory path = _v4MintPath(address(usdc), address(weth));
        path[0].hooks = makeAddr("hook");
        hooked[2] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: path, maxAmountIn: 0});
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, hooked, alice));

        IUniversalRouterSwaps.MintLeg[] memory withData = _mintLegs(address(usdc));
        PathKey[] memory dataPath = _v4MintPath(address(usdc), address(weth));
        dataPath[1].hookData = hex"01";
        withData[2] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: dataPath, maxAmountIn: 0});
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, withData, alice));
        vm.stopPrank();
    }

    /// @dev The component end of a V4 route is the zap's own argument, so only the far end can be wrong. Which entry
    ///      that is depends on the direction the router walks the route.
    function test_route_v4FarEndpointIsChecked() public {
        usdc.mint(alice, 600e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 600e6);

        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        // An exact-output route is walked backwards, so entry zero has to name what the user pays with.
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: "",
            v4Path: _v4BurnPath(address(weth), address(usdc)), // the burn ordering, which a mint route may not use
            maxAmountIn: 0
        });
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, legs, alice));

        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, _mintLegs(address(usdc)), alice));

        IUniversalRouterSwaps.BurnLeg[] memory out = _burnLegs(address(usdc));
        // An exact-input route is walked forwards, so the last entry has to name the payout.
        out[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4MintPath(address(usdc), address(weth)), minAmountOut: 0
        });
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, out, alice));
        vm.stopPrank();
    }

    /// @dev The V4 router at the pinned version does not check that an exact-output swap delivered what it promised.
    ///      Without the zap's own check a short fill would surface as an opaque balance failure inside `issue`.
    function test_ShortFill_anExactOutputThatUnderDeliversReverts() public {
        router.setMode(MockUniversalRouter.Mode.UnderDeliverExactOut);
        usdc.mint(alice, 300e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 300e6);
        uint256[] memory need = index.previewIssue(1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.ShortFill.selector, 0, need[0] - 1, need[0]));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    /// @dev A V4 leg is one swap, so an intermediate hop that fills short leaves the pool manager with a delta it
    ///      refuses to close and the whole leg reverts, rather than stranding a middle token in the zap.
    function test_burn_v4IntermediateShortfallRevertsTheLeg() public {
        _mintFor(alice, 1e18, 200e6);
        router.setMode(MockUniversalRouter.Mode.CurrencyNotSettled);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4BurnPath(address(weth), address(usdc)), minAmountOut: 0
        });

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(MockUniversalRouter.CurrencyNotSettledError.selector));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    /// @dev The zap never leaves the router holding anything and never gives it an allowance, so nothing it touched
    ///      can be swept by the next caller.
    function test_router_neverPullsAndNeverKeeps() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[1] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: _v4Path1(address(usdc)), minAmountOut: 0});
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();

        address[4] memory touched = [address(wbtc), address(weth), address(link), address(usdc)];
        for (uint256 i = 0; i < touched.length; ++i) {
            assertEq(IERC20(touched[i]).balanceOf(address(router)), 0, "the router keeps nothing");
            assertEq(IERC20(touched[i]).allowance(address(zap), address(router)), 0, "and is never approved");
        }
    }

    /// @dev The analogue of I03 for the Universal Router: a balance it happened to be holding comes back with the
    ///      sweep and enlarges the refund. On a mint it is never a shortfall, which is why the spend arithmetic
    ///      saturates; the burn side measures what the sweep brought back instead, and the CR-L02 tests below cover it.
    function test_strayRouterBalanceIsRefundedNotStranded() public {
        usdc.mint(address(router), 500e6); // a donation anyone could have swept
        usdc.mint(alice, 200e6);
        uint256 before = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        uint256 spent =
            zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();

        assertEq(spent, 0, "the stray covered the basket, so this mint spent nothing of its own");
        assertEq(usdc.balanceOf(alice), before + 500e6 - NAV_USD6, "and the rest reached the caller");
        assertEq(usdc.balanceOf(address(router)), 0);
        _assertZapEmpty();
    }

    function test_zeroTokenInOrOutReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        zap.mintWithToken(_mintParams(address(index), address(0), 1, 1, _mintLegs(address(usdc)), alice));
        vm.expectRevert(IXindexErrors.ZeroAddress.selector);
        zap.burnToToken(_burnParams(address(index), 1, address(0), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // burn with permit
    // ---------------------------------------------------------------------

    function test_burnWithPermit_oneTransaction() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        _mintFor(signer, 1e18, 200e6);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), NAV_USD6, _burnLegs(address(usdc)), signer);
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, signer, 1e18, p.deadline);

        vm.prank(signer);
        uint256 out = zap.burnToTokenWithPermit(p, v, r, s);
        assertEq(out, NAV_USD6);
        assertEq(usdc.balanceOf(signer), 200e6);
        assertEq(index.nonces(signer), 1);
        assertEq(index.allowance(signer, address(zap)), 0);
    }

    function test_burnWithPermit_frontRunPermitStillBurns() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        _mintFor(signer, 1e18, 200e6);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), NAV_USD6, _burnLegs(address(usdc)), signer);
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, signer, 1e18, p.deadline);

        vm.prank(bob); // someone copies the signature from the mempool and submits it first
        index.permit(signer, address(zap), 1e18, p.deadline, v, r, s);

        vm.prank(signer);
        assertEq(zap.burnToTokenWithPermit(p, v, r, s), NAV_USD6);
    }

    function test_burnWithPermit_invalidSignatureWithoutAllowanceReverts() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnParams memory p =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice);
        vm.prank(alice);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        zap.burnToTokenWithPermit(p, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_burnWithPermit_checksBeforePermit() public {
        IIndexZap.BurnParams memory p =
            _burnParams(address(usdc), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(usdc)));
        zap.burnToTokenWithPermit(p, 27, bytes32(0), bytes32(0));

        p.index = address(index);
        p.expectedNonce = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 1, 0));
        zap.burnToTokenWithPermit(p, 27, bytes32(0), bytes32(0));
    }

    // ---------------------------------------------------------------------
    // CR: the security audit of 2026-09-23
    // ---------------------------------------------------------------------

    /// @dev CR-L02. A burn hop measured what the router sold as `inBefore - balanceAfter`, a checked subtraction inside
    ///      the saturating one, but the sweep returns the router's whole balance of the hop's input, including anything
    ///      it held beforehand. A stray above what the hop sold made that subtraction underflow and the whole burn
    ///      revert with Panic(0x11): anyone could donate to the router ahead of a public burn, watch it fail, and sweep
    ///      the donation back, for gas. The hop now measures what the sweep brought back, which only ever adds to the
    ///      balance, and forwards all of it, stray included, to the recipient.
    function test_CRL02_aStrayAboveAComponentHopsSaleIsReturnedNotABlockedBurn() public {
        _mintFor(alice, 1e18, 200e6);
        link.mint(address(router), 2e18); // twice the one LINK the burn sells
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ComponentReturned(address(index), bob, address(link), 2e18);
        uint256 out =
            zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), bob));
        vm.stopPrank();

        assertEq(out, NAV_USD6, "the burn sold its whole basket");
        assertEq(link.balanceOf(bob), 2e18, "and the stray reached the recipient beside the payout");
        assertEq(link.balanceOf(address(router)), 0, "nothing is left in the router");
        _assertZapEmpty();
    }

    /// @dev CR-L02 on an intermediate hop, which is where a griefer would aim: WETH sits in the middle of nearly every
    ///      route, and the WBTC leg's second hop sells only the 0.02 WETH its first hop bought. A stray below that was
    ///      already returned; one above it reverted the burn. Both reach the recipient now.
    function test_CRL02_aStrayOnAnIntermediateHopIsReturnedWhateverItsSize() public {
        _mintFor(alice, 2e18, 400e6);
        vm.startPrank(alice);
        index.approve(address(zap), 2e18);

        weth.mint(address(router), 1e15); // below the 2e16 WETH the WBTC leg's second hop sells
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ComponentReturned(address(index), bob, address(weth), 1e15);
        assertEq(
            zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), bob)),
            NAV_USD6
        );

        weth.mint(address(router), 1e18); // fifty times that sale, where the old arithmetic underflowed
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ComponentReturned(address(index), bob, address(weth), 1e18);
        assertEq(
            zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), bob)),
            NAV_USD6
        );
        vm.stopPrank();

        assertEq(weth.balanceOf(bob), 1e18 + 1e15, "both strays reached the recipient");
        assertEq(weth.balanceOf(address(router)), 0);
        _assertZapEmpty();
    }

    /// @dev CR-L02 on a V4 leg: the same measurement had the same underflow, and has the same fix.
    function test_CRL02_aStrayAboveAV4LegsSaleIsReturnedNotABlockedBurn() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4BurnPath(address(weth), address(usdc)), minAmountOut: 0
        });
        link.mint(address(router), 3e18); // three times the one LINK the V4 leg sells
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ComponentReturned(address(index), bob, address(link), 3e18);
        uint256 out = zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, bob));
        vm.stopPrank();

        assertEq(out, NAV_USD6);
        assertEq(link.balanceOf(bob), 3e18, "the stray reached the recipient");
        assertEq(link.balanceOf(address(router)), 0);
        _assertZapEmpty();
    }

    /// @dev A reenterer holding `shares` of the index and `usdcAmount` of USDC, both approved to the zap.
    function _reenterer(uint256 shares, uint256 usdcAmount) internal returns (ZapReenterer probe) {
        probe = new ZapReenterer(zap);
        if (shares != 0) _mintFor(address(probe), shares, shares * 200e6 / 1e18);
        usdc.mint(address(probe), usdcAmount);
        probe.approve(IERC20(address(index)), type(uint256).max);
        probe.approve(IERC20(address(usdc)), type(uint256).max);
    }

    function _assertTheGuardStoppedTheNestedCall(ZapReenterer probe) internal view {
        assertTrue(probe.armedAndFired(), "the callback reached the probe inside the outer call");
        assertFalse(probe.nestedSucceeded(), "the nested zap call did not run");
        assertEq(
            bytes4(probe.nestedError()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "it was stopped by the outer call's guard"
        );
    }

    /// @dev CR-I26. ARCHITECTURE lists all three zap entry points as guarded, and the reentrancy suppressions in the zap
    ///      rest on it, but no test re-entered the zap, so any `nonReentrant` could be deleted with the suite green. A
    ///      mint paid in a callback token hands the payer control at the refund; from there a fully valid burn of a
    ///      share the payer already holds now fails on the outer call's guard, and ran to completion without it.
    function test_CRI26_aMintHoldsTheGuardThroughItsRefund() public {
        MockHookToken hook = new MockHookToken();
        router.setPrice(address(hook), 1e18, 18);
        ZapReenterer probe = _reenterer(1e18, 0);
        hook.mint(address(probe), 200e18);
        probe.approve(IERC20(address(hook)), type(uint256).max);

        IIndexZap.MintParams memory outer =
            _mintParams(address(index), address(hook), 200e18, 1e18, _mintLegs(address(hook)), address(probe));
        IIndexZap.BurnParams memory nested =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(probe));
        probe.run(abi.encodeCall(IIndexZap.mintWithToken, (outer)), abi.encodeCall(IIndexZap.burnToToken, (nested)));

        assertEq(index.balanceOf(address(probe)), 2e18, "the outer mint completed and the held share was not burnt");
        _assertTheGuardStoppedTheNestedCall(probe);
    }

    /// @dev CR-I26, burnToToken: the payout in a callback token hands the recipient control, and a fully valid mint made
    ///      from there fails on the outer burn's guard.
    function test_CRI26_aBurnHoldsTheGuardThroughItsPayout() public {
        MockHookToken hook = new MockHookToken();
        router.setPrice(address(hook), 1e18, 18);
        hook.mint(address(router.inventory()), 1_000e18);
        ZapReenterer probe = _reenterer(1e18, 200e6);

        IIndexZap.BurnParams memory outer =
            _burnParams(address(index), 1e18, address(hook), 1, _burnLegs(address(hook)), address(probe));
        IIndexZap.MintParams memory nested =
            _mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), address(probe));
        probe.run(abi.encodeCall(IIndexZap.burnToToken, (outer)), abi.encodeCall(IIndexZap.mintWithToken, (nested)));

        assertEq(index.balanceOf(address(probe)), 0, "the outer burn completed and nothing was minted inside it");
        assertEq(hook.balanceOf(address(probe)), 105e18, "the payout arrived");
        _assertTheGuardStoppedTheNestedCall(probe);
    }

    /// @dev CR-I26, burnToTokenWithPermit: the same payout, and a second permit burn from inside it, which fails on the
    ///      outer call's guard. The probe approved the zap beforehand, so the garbage permits are tolerated, by design.
    function test_CRI26_aPermitBurnHoldsTheGuardThroughItsPayout() public {
        MockHookToken hook = new MockHookToken();
        router.setPrice(address(hook), 1e18, 18);
        hook.mint(address(router.inventory()), 1_000e18);
        ZapReenterer probe = _reenterer(2e18, 0);

        IIndexZap.BurnParams memory outer =
            _burnParams(address(index), 1e18, address(hook), 1, _burnLegs(address(hook)), address(probe));
        IIndexZap.BurnParams memory nested =
            _burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(probe));
        probe.run(
            abi.encodeCall(IIndexZap.burnToTokenWithPermit, (outer, 27, bytes32(0), bytes32(0))),
            abi.encodeCall(IIndexZap.burnToTokenWithPermit, (nested, 27, bytes32(0), bytes32(0)))
        );

        assertEq(index.balanceOf(address(probe)), 1e18, "the outer burn completed and the second share is untouched");
        _assertTheGuardStoppedTheNestedCall(probe);
    }

    /// @dev CR-I27. Only the V3 partial fill was tested, so deleting `_sellV4`'s `_returnUnsold` passed every test,
    ///      although a V4 leg that stops short would then leave the user's unsold component in the zap, which counts
    ///      only balance changes and would never pay it to anyone. The mock's partial mode halves a V4 exact input too.
    function test_CRI27_aV4BurnLegReturnsItsUnsoldInputToTheRecipient() public {
        WeightedHub idx = _etherIndex();
        _issueEther(idx, alice);
        vm.startPrank(alice);
        idx.approve(address(zap), 1e18);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _etherBurnLegs("", _v4Path1(address(usdc)));
        router.setMode(MockUniversalRouter.Mode.PartialFirstHop);

        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ComponentReturned(address(idx), bob, address(weth), 5e17);
        uint256 out = zap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, legs, bob));
        vm.stopPrank();

        assertEq(out, 1_500e6 + U_DUST, "half the WETH sold, and the USDC held as it is");
        assertEq(weth.balanceOf(bob), 5e17, "the unsold half reached the recipient");
        assertEq(weth.balanceOf(address(zap)), 0, "none of it is stranded in the zap");
        assertEq(weth.balanceOf(address(router)), 0, "or in the router");
    }

    /// @dev CR-I27, the other side: a burn whose every hop fills returns nothing, so it announces nothing. Without the
    ///      `unsold == 0` check every hop emitted a zero ComponentReturned and called `transfer(to, 0)`, which a paused
    ///      or zero-refusing component would turn into a failed burn.
    function test_CRI27_aCompletelyFilledBurnReturnsNothing() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4BurnPath(address(weth), address(usdc)), minAmountOut: 0
        });
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.recordLogs();
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 burns = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(zap)) continue;
            assertTrue(logs[i].topics[0] != IIndexZap.ComponentReturned.selector, "nothing was left unsold");
            if (logs[i].topics[0] == IIndexZap.ZapBurn.selector) ++burns;
        }
        assertEq(burns, 1, "the burn itself is still announced, across V3 and V4 legs alike");
    }

    /// @dev CR-I31. A leg names exactly one venue, and the pass-through leg names none. The committed tests only ever
    ///      put a V3 path on it, so dropping the V4 half of the check passed them and a V4 route was silently ignored.
    function test_CRI31_aPassThroughLegCarryingAV4RouteIsABadRoute() public {
        WeightedHub idx = _mixedIndex();
        IUniversalRouterSwaps.MintLeg[] memory mintLegs = _mixedLegs();
        mintLegs[1].v4Path = _v4Path1(address(weth)); // USDC is the component and the currency: no swap belongs here
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 100e6, 1e18, mintLegs, alice));

        zap.mintWithToken(_mintParams(address(idx), address(usdc), 100e6, 1e18, _mixedLegs(), alice));
        IUniversalRouterSwaps.BurnLeg[] memory burnLegs = new IUniversalRouterSwaps.BurnLeg[](2);
        burnLegs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path2(address(weth), address(usdc)), v4Path: _noV4(), minAmountOut: 0
        });
        burnLegs[1] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: _v4Path1(address(weth)), minAmountOut: 0});
        idx.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1, burnLegs, alice));
        vm.stopPrank();
    }

    /// @dev CR-I31: a budget that exactly covers the part of the basket that already is `tokenIn` is enough, as
    ///      InsufficientBudget's "needs more than" says; a `>=` there refused it and passed every committed test. An
    ///      index holds two components at least, so such a budget passes the check and runs out at the swap that buys
    ///      the other one, with the pool's own error; the refusal it must not meet is `InsufficientBudget`.
    function test_CRI31_aBudgetExactlyCoveringThePassThroughLegIsEnough() public {
        WeightedHub idx = _mixedIndex(); // 0.01 WETH, bought for 30 USDC, and 50 USDC held as it is
        usdc.mint(alice, U_USDC);
        vm.startPrank(alice);
        usdc.approve(address(zap), U_USDC);
        vm.expectRevert(abi.encodeWithSignature("V3TooMuchRequested()"));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), U_USDC, 1e18, _mixedLegs(), alice));

        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InsufficientBudget.selector, U_USDC, U_USDC - 1));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), U_USDC - 1, 1e18, _mixedLegs(), alice));
        vm.stopPrank();
    }

    /// @dev CR-I31: a mint that spends its whole budget owes no refund and sends none. Refunding unconditionally sent
    ///      `transfer(msg.sender, 0)`, which a currency that refuses zero transfers turns into a failed mint.
    function test_CRI31_anExactSpendMintSendsNoZeroRefund() public {
        WeightedHub idx = _mixedIndex(); // 0.01 WETH, bought for 30 USDC, and 50 USDC held as it is
        usdc.mint(alice, 80e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 80e6);
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.transfer, (alice, 0)), 0);
        uint256 spent = zap.mintWithToken(_mintParams(address(idx), address(usdc), 80e6, 1e18, _mixedLegs(), alice));
        vm.stopPrank();
        assertEq(spent, 80e6, "the whole budget was spent");
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(idx.balanceOf(alice), 1e18);
    }

    /// @dev Command and action bytes of Universal Router 2.0.0 (`Commands.sol` at 3663f6db) and v4-periphery
    ///      (`Actions.sol` and `ActionConstants.sol` at 444c526b), written out here rather than read from src, so a
    ///      constant that moved in src would stop matching instead of moving the mock along with it.
    bytes1 internal constant UPSTREAM_V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant UPSTREAM_V3_SWAP_EXACT_OUT = 0x01;
    bytes1 internal constant UPSTREAM_SWEEP = 0x04;
    bytes1 internal constant UPSTREAM_V4_SWAP = 0x10;
    bytes1 internal constant UPSTREAM_SWAP_EXACT_IN = 0x07;
    bytes1 internal constant UPSTREAM_SWAP_EXACT_OUT = 0x09;
    bytes1 internal constant UPSTREAM_SETTLE = 0x0b;
    bytes1 internal constant UPSTREAM_TAKE = 0x0e;

    /// @dev CR-I36. The mock router dispatches on the zap's own command constants, so swapping V3_SWAP_EXACT_IN with
    ///      V3_SWAP_EXACT_OUT in src moved the zap and the mock together and every offline test stayed green; only the
    ///      fork suites, which skip without an RPC, would notice. A V3 mint leg is command 0x01 then 0x04, with the
    ///      pinned Dispatcher's input layout: recipient, amountOut, amountInMax, path, payerIsUser.
    function test_CRI36_aV3MintLegIsUpstreamCommand01ThenSweep() public {
        _mintFor(alice, 1e18, 200e6);
        assertEq(router.lastCommands(), abi.encodePacked(UPSTREAM_V3_SWAP_EXACT_OUT, UPSTREAM_SWEEP));
        (address recipient, uint256 amountOut, uint256 amountInMax, bytes memory path, bool payerIsUser) =
            abi.decode(router.lastInput(0), (address, uint256, uint256, bytes, bool));
        assertEq(recipient, address(zap));
        assertEq(amountOut, U_LINK, "amountOut: the LINK the basket needs, the last leg's");
        assertEq(amountInMax, 200e6 - 60e6 - 30e6, "amountInMax: the budget the first two legs left");
        assertEq(path, _path3(address(link), address(weth), address(usdc)));
        assertFalse(payerIsUser);
    }

    /// @dev CR-I36: a V3 burn hop is command 0x00 then 0x04, and its input carries the hop's own sale and, on the
    ///      leg's last hop, the leg's minimum.
    function test_CRI36_aV3BurnHopIsUpstreamCommand00ThenSweep() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2].minAmountOut = 7e6;
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();

        assertEq(router.lastCommands(), abi.encodePacked(UPSTREAM_V3_SWAP_EXACT_IN, UPSTREAM_SWEEP));
        (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser) =
            abi.decode(router.lastInput(0), (address, uint256, uint256, bytes, bool));
        assertEq(recipient, address(zap));
        assertEq(amountIn, 5e15, "amountIn: the WETH the LINK leg's first hop bought");
        assertEq(amountOutMin, 7e6, "amountOutMin: the leg's minimum, on its last hop");
        assertEq(path, _path2(address(weth), address(usdc)), "the last hop of the last leg");
        assertFalse(payerIsUser);
    }

    /// @dev CR-I36. `test_route_v4MintEncodesTheActionsTheRouterDecodes` decodes the swap parameters with the zap's own
    ///      struct, so swapping `amountOut` with `amountInMaximum` in src -- both uint128 -- passed every offline test,
    ///      and the real router would have read the cap as the amount to buy. Decoded here with upstream's
    ///      `IV4Router.ExactOutputParams`, the leg's need and its cap sit in the fields upstream reads them from.
    function test_CRI36_aV4MintLegMatchesTheUpstreamLayout() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: "", v4Path: _v4MintPath(address(usdc), address(weth)), maxAmountIn: 20e6
        });
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));
        vm.stopPrank();

        assertEq(router.lastCommands(), abi.encodePacked(UPSTREAM_V4_SWAP, UPSTREAM_SWEEP));
        (bytes memory actions, bytes[] memory params) = abi.decode(router.lastInput(0), (bytes, bytes[]));
        assertEq(actions, abi.encodePacked(UPSTREAM_SWAP_EXACT_OUT, UPSTREAM_SETTLE, UPSTREAM_TAKE));
        UpstreamExactOutputParams memory swap = abi.decode(params[0], (UpstreamExactOutputParams));
        assertEq(swap.currencyOut, address(link));
        assertEq(uint256(swap.amountOut), U_LINK, "the third field is the exact output, the LINK the basket needs");
        assertEq(uint256(swap.amountInMaximum), 20e6, "the fourth is the input cap, the leg's own");
        assertEq(swap.path.length, 2);
        assertEq(swap.path[0].intermediateCurrency, address(usdc));
        assertEq(uint256(swap.path[0].fee), FEE);
        assertEq(int256(swap.path[0].tickSpacing), 10);
    }

    /// @dev CR-I36, the burn side: decoded with upstream's `IV4Router.ExactInputParams`, the component the redemption
    ///      released and the leg's minimum sit in the fields upstream reads them from.
    function test_CRI36_aV4BurnLegMatchesTheUpstreamLayout() public {
        _mintFor(alice, 1e18, 200e6);
        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: "", v4Path: _v4BurnPath(address(weth), address(usdc)), minAmountOut: 14e6
        });
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();

        assertEq(router.lastCommands(), abi.encodePacked(UPSTREAM_V4_SWAP, UPSTREAM_SWEEP));
        (bytes memory actions, bytes[] memory params) = abi.decode(router.lastInput(0), (bytes, bytes[]));
        assertEq(actions, abi.encodePacked(UPSTREAM_SWAP_EXACT_IN, UPSTREAM_SETTLE, UPSTREAM_TAKE));
        UpstreamExactInputParams memory swap = abi.decode(params[0], (UpstreamExactInputParams));
        assertEq(swap.currencyIn, address(link));
        assertEq(uint256(swap.amountIn), U_LINK, "the third field is the exact input, the LINK the redemption released");
        assertEq(uint256(swap.amountOutMinimum), 14e6, "the fourth is the leg's minimum");
        assertEq(swap.path[1].intermediateCurrency, address(usdc), "the route ends at the payout");
    }

    // ---------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------

    function _roundTrip(uint256 shares) internal returns (uint256 spent, uint256 out) {
        uint256 budget = shares * NAV_USD6 / 1e18 + 10e6;
        spent = _mintFor(alice, shares, budget);
        assertEq(index.balanceOf(alice), shares);

        vm.startPrank(alice);
        index.approve(address(zap), shares);
        out = zap.burnToToken(_burnParams(address(index), shares, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();

        assertEq(index.totalSupply(), 0);
        _assertZapEmpty();
    }

    function testFuzz_mintThenBurn_exactUnits(uint256 k) public {
        // multiples of 1e13 shares map to whole raw units of every component (1 sat of WBTC),
        // so the only loss is the router's per-leg ceil on the quote: at most 1 unit per leg.
        uint256 shares = bound(k, 1, 100_000_000) * 1e13;
        (uint256 spent, uint256 out) = _roundTrip(shares);
        assertLe(spent - out, 3);
    }

    function testFuzz_mintThenBurn_arbitraryShares(uint256 shares) public {
        // issue rounds each component up and redeem rounds down, so up to 1 raw unit of each
        // component stays in the index. 1 sat of WBTC is worth 600 raw USDC here.
        shares = bound(shares, 1e12, 1_000e18);
        (uint256 spent, uint256 out) = _roundTrip(shares);
        assertLe(spent - out, 600 + 1 + 1 + 3);
    }

    // ---------------------------------------------------------------------
    // Red team of 2026-09-24, mutation gaps
    // ---------------------------------------------------------------------

    /// @dev RT-10. A V3 path is a first token followed by whole hops of a fee and a token: 20 + 23k bytes, k at least
    ///      one. The zap checks only the two ends, so the whole-hops term is what makes those ends the tokens the
    ///      router swaps: the Universal Router walks a path in 23-byte strides and reads a lone pool from its first 43
    ///      bytes. The suite tried only a 40-byte path, which the length term refuses anyway, so dropping the stride
    ///      term, or joining the two terms with `||`, passed every test. Each length either side of a whole number of
    ///      hops is refused here, and so is a lone token, which is a whole number of hops only by counting none.
    function test_RT10_aPathIsAFirstTokenAndWholeHops() public {
        PathShapeProbe probe = new PathShapeProbe();
        uint256[8] memory lengths = [uint256(20), 42, 43, 44, 64, 65, 66, 89];
        bool[8] memory valid = [false, false, true, false, false, false, true, true];
        for (uint256 i = 0; i < lengths.length; ++i) {
            assertEq(probe.isValidShape(new bytes(lengths[i])), valid[i], vm.toString(lengths[i]));
        }
    }

    /// @dev RT-10, through a mint. Each path has the right two ends and a body that is not whole hops: a middle token
    ///      with a stray byte after it (64 bytes), and a stray byte after the fee (44 bytes). The router would read the
    ///      first as one pool paid in WETH, not the USDC the zap checked and pre-funded, and the mock router, which
    ///      reads only the ends, would fill both; only the shape check names them as bad routes.
    function test_RT10_aMintLegWhoseBodyIsNotWholeHopsIsABadRoute() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);

        IUniversalRouterSwaps.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].v3Path = abi.encodePacked(address(wbtc), FEE, address(weth), bytes1(0xff), address(usdc));
        assertEq(legs[0].v3Path.length, 64);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 0));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs = _mintLegs(address(usdc));
        legs[1].v3Path = abi.encodePacked(address(weth), FEE, bytes1(0x42), address(usdc));
        assertEq(legs[1].v3Path.length, 44);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 1));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));
        vm.stopPrank();
        assertEq(index.totalSupply(), 0, "nothing was minted");
    }

    /// @dev RT-10, through a burn. The same shapes on a burn leg are bad routes too, where without the stride term the
    ///      first passed the check and then failed in `_sellV3` on an out-of-range slice, with no reason given.
    function test_RT10_aBurnLegWhoseBodyIsNotWholeHopsIsABadRoute() public {
        _mintFor(alice, 1e18, 200e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);

        IUniversalRouterSwaps.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[0].v3Path = abi.encodePacked(address(wbtc), FEE, address(weth), bytes1(0xff), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 0));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));

        legs = _burnLegs(address(usdc));
        legs[2].v3Path = abi.encodePacked(address(link), FEE, bytes1(0x42), address(usdc));
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.BadRoute.selector, 2));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18, "the shares are still alice's");
    }

    /// @dev RT-15. `ZapMint` and `ZapBurn` name the caller, who paid or whose shares burned, apart from the recipient.
    ///      Every test of them had the two the same, so an event that swapped them passed. Here alice mints for bob and
    ///      bob burns for alice.
    function test_RT15_zapEventsNameTheCallerAndTheRecipientApart() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ZapMint(address(index), alice, bob, address(usdc), NAV_USD6, 1e18);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), bob));
        vm.stopPrank();

        vm.startPrank(bob);
        index.approve(address(zap), 1e18);
        vm.expectEmit(true, true, true, true, address(zap));
        emit IIndexZap.ZapBurn(address(index), bob, alice, address(usdc), 1e18, NAV_USD6);
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 200e6, "alice paid the basket's price and was paid it back");
    }

    /// @dev RT-16. A mint leg's delivery is the change in the zap's balance of the component, and ShortFill is
    ///      load-bearing because the pinned V4 router does not check exact-output delivery. Its test ran with the zap
    ///      holding none of the component, where the balance afterwards is the change itself, so adding the balance
    ///      before the swap, or reading the balance alone, passed. Either lets a stray of the component, which anyone
    ///      can send the zap, hide a short fill that `issue` then covers out of the stray. Here one raw WBTC sits in
    ///      the zap and the router delivers one short.
    function test_RT16_aStrayOfTheComponentDoesNotHideAShortFill() public {
        wbtc.mint(address(zap), 1);
        router.setMode(MockUniversalRouter.Mode.UnderDeliverExactOut);
        uint256[] memory need = index.previewIssue(1e18);
        usdc.mint(alice, 300e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 300e6);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.ShortFill.selector, 0, need[0] - 1, need[0]));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 300e6, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();
    }
}

/// @dev `PathLib` reads calldata, so its shape check is reached through an external call.
contract PathShapeProbe {
    function isValidShape(bytes calldata path) external pure returns (bool) {
        return PathLib.isValidShape(path);
    }
}

/// @dev Mints through the zap with a callback token and, when the zap refunds it, fills the index's auction with the
///      price updates it was given.
contract RebalancingMinter is ITokenReceiverHook {
    IndexZap internal immutable ZAP;
    WeightedHub internal immutable INDEX;
    MockWeightedExecutor internal immutable EXECUTOR;
    bytes[] internal _updates;

    constructor(IndexZap zap, WeightedHub index, MockWeightedExecutor executor, bytes[] memory updates) {
        ZAP = zap;
        INDEX = index;
        EXECUTOR = executor;
        for (uint256 i = 0; i < updates.length; ++i) {
            _updates.push(updates[i]);
        }
    }

    function mint(IIndexZap.MintParams calldata p) external {
        MockHookToken(p.tokenIn).approve(address(ZAP), p.maxAmountIn);
        ZAP.mintWithToken(p);
    }

    function onTokenReceived(address from, uint256) external {
        if (from == address(ZAP)) EXECUTOR.execute(INDEX, "", _updates);
    }
}

/// @dev Makes one call to the zap, and when a callback token the zap sends reaches it inside that call, makes a second,
///      fully valid zap call and records how it ended. Holds whatever it pays with or burns, so it is the caller the
///      outer call pulls from and, on a burn, the recipient the payout reaches.
contract ZapReenterer is ITokenReceiverHook {
    IndexZap internal immutable ZAP;
    bytes internal _nested;
    bool internal _armed;
    bool public armedAndFired;
    bool public nestedSucceeded;
    bytes public nestedError;

    constructor(IndexZap zap) {
        ZAP = zap;
    }

    function approve(IERC20 token, uint256 amount) external {
        token.approve(address(ZAP), amount);
    }

    /// @notice Makes `outer` on the zap, armed to make `nested` from the first callback the zap's transfer triggers.
    ///         A failure of `outer` reverts with the zap's own error.
    function run(bytes calldata outer, bytes calldata nested) external {
        _nested = nested;
        _armed = true;
        Address.functionCall(address(ZAP), outer);
    }

    function onTokenReceived(address from, uint256) external {
        if (!_armed || from != address(ZAP)) return;
        _armed = false;
        armedAndFired = true;
        (nestedSucceeded, nestedError) = address(ZAP).call(_nested);
    }
}

/// @dev One hop of a V4 route as upstream declares it: v4-periphery `PathKey` at 444c526b, with `Currency` and `IHooks`
///      written as the addresses they are. Declared here rather than imported from src, so a test decoding with it
///      checks the zap's encoding against upstream's layout instead of against itself (CR-I36).
struct UpstreamPathKey {
    address intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
    bytes hookData;
}

/// @dev v4-periphery `IV4Router.ExactInputParams` at 444c526b.
struct UpstreamExactInputParams {
    address currencyIn;
    UpstreamPathKey[] path;
    uint128 amountIn;
    uint128 amountOutMinimum;
}

/// @dev v4-periphery `IV4Router.ExactOutputParams` at 444c526b.
struct UpstreamExactOutputParams {
    address currencyOut;
    UpstreamPathKey[] path;
    uint128 amountOut;
    uint128 amountInMaximum;
}
