// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {XindexTest} from "./XindexTest.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexToken} from "../src/IndexToken.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IIndexToken} from "../src/interfaces/IIndexToken.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockHookToken, ITokenReceiverHook} from "./mocks/MockHookToken.sol";
import {MockRebalanceExecutor} from "./mocks/MockRebalanceExecutor.sol";
import {MockMarket} from "./mocks/MockMarket.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockPartialFillRouter} from "./mocks/MockPartialFillRouter.sol";

contract IndexZapTest is XindexTest {
    IndexZap zap;
    MockSwapRouter router;
    IndexToken index;

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

    uint24 constant FEE = 500;

    function setUp() public {
        market = new MockMarket();
        factory = new IndexFactory(
            owner, address(0), address(market.weth()), address(market.uniswapV3Factory()), address(market.usdc())
        );
        router = new MockSwapRouter();
        zap = new IndexZap(factory, router);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = market.weth();
        link = new MockERC20("Chainlink", "LINK", 18);
        usdc = market.usdc();
        usdt = new MockUSDT();

        router.setPrice(address(wbtc), 60_000e18);
        router.setPrice(address(weth), 3_000e18);
        router.setPrice(address(link), 15e18);
        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(usdt), 1e18);

        wbtc.mint(address(router), 1_000e8);
        weth.mint(address(router), 100_000e18);
        link.mint(address(router), 10_000_000e18);
        usdc.mint(address(router), 1_000_000_000e6);
        usdt.mint(address(router), 1_000_000_000e6);

        _list(address(wbtc));
        _list(address(weth));
        _list(address(link));
        _list(address(usdc));

        address[] memory t = new address[](3);
        uint256[] memory u = new uint256[](3);
        t[0] = address(wbtc);
        t[1] = address(weth);
        t[2] = address(link);
        u[0] = U_WBTC;
        u[1] = U_WETH;
        u[2] = U_LINK;
        index = IndexToken(factory.createIndex("Blue Chip", "BLUE", t, u, 0));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _path2(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b);
    }

    function _path3(address a, address b, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b, FEE, c);
    }

    /// @dev mint legs: component -> ... -> stable (exact-output encoding, reversed), no per-leg limit
    function _mintLegs(address stable) internal view returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](3);
        legs[0] = IIndexZap.MintLeg({path: _path3(address(wbtc), address(weth), stable), maxAmountIn: 0});
        legs[1] = IIndexZap.MintLeg({path: _path2(address(weth), stable), maxAmountIn: 0});
        legs[2] = IIndexZap.MintLeg({path: _path3(address(link), address(weth), stable), maxAmountIn: 0});
    }

    /// @dev burn legs: component -> ... -> tokenOut (exact-input encoding), no per-leg limit
    function _burnLegs(address tokenOut) internal view returns (IIndexZap.BurnLeg[] memory legs) {
        legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({path: _path3(address(wbtc), address(weth), tokenOut), minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({path: _path2(address(weth), tokenOut), minAmountOut: 0});
        legs[2] = IIndexZap.BurnLeg({path: _path3(address(link), address(weth), tokenOut), minAmountOut: 0});
    }

    function _mintParams(
        address idx,
        address tokenIn,
        uint256 maxIn,
        uint256 shares,
        IIndexZap.MintLeg[] memory legs,
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
            deadline: block.timestamp
        });
    }

    function _burnParams(
        address idx,
        uint256 shares,
        address tokenOut,
        uint256 minOut,
        IIndexZap.BurnLeg[] memory legs,
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
    function _mixedIndex() internal returns (IndexToken idx) {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = address(weth);
        t[1] = address(usdc);
        u[0] = U_WETH;
        u[1] = 50e6;
        idx = IndexToken(factory.createIndex("Mixed", "MIX", t, u, 0));
    }

    function _mixedLegs() internal view returns (IIndexZap.MintLeg[] memory legs) {
        legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({path: _path2(address(weth), address(usdc)), maxAmountIn: 0});
        legs[1] = IIndexZap.MintLeg({path: "", maxAmountIn: 0});
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
        new IndexZap(factory, ISwapRouter02(address(0)));
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
        IndexToken idx = _mixedIndex();
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
        vm.expectRevert("Too much requested");
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 79e6, 1e18, _mixedLegs(), alice));
        vm.stopPrank();
    }

    function test_mint_revertsInsufficientBudget() public {
        IndexToken idx = _mixedIndex();
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.InsufficientBudget.selector, 50e6, 10e6));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 10e6, 1e18, _mixedLegs(), alice));
        vm.stopPrank();
    }

    function test_mint_revertsTokenInComponentWithNonEmptyPath() public {
        IndexToken idx = _mixedIndex();
        IIndexZap.MintLeg[] memory legs = _mixedLegs();
        legs[1].path = _path2(address(usdc), address(usdc));
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 1));
        zap.mintWithToken(_mintParams(address(idx), address(usdc), 100e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_mint_revertsWhenMaxAmountInTooLow() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert("Too much requested");
        zap.mintWithToken(_mintParams(address(index), address(usdc), 100e6, 1e18, _mintLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_mint_legCapsWithinBudgetSucceed() public {
        IIndexZap.MintLeg[] memory legs = _mintLegs(address(usdc));
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
        IIndexZap.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = 60_600_000; // 1% per leg
        legs[1].maxAmountIn = 30_300_000;
        legs[2].maxAmountIn = 15_150_000;
        usdc.mint(alice, maxIn);
        vm.prank(alice);
        usdc.approve(address(zap), maxIn);

        router.setPrice(address(link), 16.05e18); // a sandwich moves only the LINK leg, by 7%

        vm.prank(alice);
        vm.expectRevert("Too much requested");
        zap.mintWithToken(_mintParams(address(index), address(usdc), maxIn, 1e18, legs, alice));
    }

    function test_mint_legCapAboveBudgetFallsBackToBudget() public {
        IIndexZap.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].maxAmountIn = type(uint256).max;
        legs[1].maxAmountIn = type(uint256).max;
        legs[2].maxAmountIn = type(uint256).max;
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 100e6);
        vm.expectRevert("Too much requested");
        zap.mintWithToken(_mintParams(address(index), address(usdc), 100e6, 1e18, legs, alice));
        vm.stopPrank();
    }

    function test_mint_revertsBadPaths() public {
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 200e6);

        IIndexZap.MintLeg[] memory legs = _mintLegs(address(usdc));
        legs[0].path = _path3(address(link), address(weth), address(usdc)); // should start with wbtc
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 0));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs = _mintLegs(address(usdc));
        legs[2].path = _path3(address(link), address(weth), address(usdt)); // should end with usdc
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 2));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs = _mintLegs(address(usdc));
        legs[1].path = abi.encodePacked(address(weth), address(usdc)); // missing fee
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 1));
        zap.mintWithToken(_mintParams(address(index), address(usdc), 200e6, 1e18, legs, alice));

        legs[1].path = "";
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 1));
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
        vm.expectRevert(IIndexZap.Expired.selector);
        zap.mintWithToken(p);

        p.deadline = block.timestamp;
        p.index = address(usdc);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(usdc)));
        zap.mintWithToken(p);

        p.index = address(index);
        p.legs = new IIndexZap.MintLeg[](2);
        vm.expectRevert(IIndexZap.LegCountMismatch.selector);
        zap.mintWithToken(p);
        vm.stopPrank();
    }

    function test_mint_revertsStaleRebalanceNonce() public {
        IIndexZap.MintParams memory p =
            _mintParams(address(index), address(usdc), 200e6, 1e18, _mintLegs(address(usdc)), alice);
        p.expectedNonce = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 1, 0));
        zap.mintWithToken(p);
    }

    function test_mint_revertsZeroAmounts() public {
        vm.startPrank(alice);
        vm.expectRevert(IIndexZap.ZeroAmount.selector);
        zap.mintWithToken(_mintParams(address(index), address(usdc), 100e6, 0, _mintLegs(address(usdc)), alice));
        vm.expectRevert(IIndexZap.ZeroAmount.selector);
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
        router.setPrice(address(fot), 1e18);
        fot.mint(alice, 200e18);
        vm.startPrank(alice);
        fot.approve(address(zap), 200e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, address(fot)));
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
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({path: "", minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({path: _path2(address(weth), address(wbtc)), minAmountOut: 0});
        legs[2] = IIndexZap.BurnLeg({path: _path3(address(link), address(weth), address(wbtc)), minAmountOut: 0});

        // $105 of WBTC at $60k = 0.00175 BTC = 175_000 sats
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(_burnParams(address(index), 1e18, address(wbtc), 175_000, legs, alice));
        vm.stopPrank();

        assertEq(out, 175_000);
        assertEq(wbtc.balanceOf(alice), 175_000);
        _assertZapEmpty();
    }

    function test_burn_revertsComponentIsTokenOutWithNonEmptyPath() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](3);
        legs[0] = IIndexZap.BurnLeg({path: _path2(address(wbtc), address(wbtc)), minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({path: _path2(address(weth), address(wbtc)), minAmountOut: 0});
        legs[2] = IIndexZap.BurnLeg({path: _path3(address(link), address(weth), address(wbtc)), minAmountOut: 0});
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 0));
        zap.burnToToken(_burnParams(address(index), 1e18, address(wbtc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_burn_revertsInsufficientOutput() public {
        _mintFor(alice, 1e18, 200e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.InsufficientOutput.selector, NAV_USD6, NAV_USD6 + 1));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), NAV_USD6 + 1, _burnLegs(address(usdc)), alice));
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 1e18);
    }

    function test_burn_legMinimumEnforced() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2].minAmountOut = 15_000_001; // the LINK leg returns exactly 15 USDC
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert("Too little received");
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_burn_revertsBadPath() public {
        _mintFor(alice, 1e18, 200e6);
        IIndexZap.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[1].path = _path2(address(weth), address(usdt));
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 1));
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
        IIndexZap.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[2] = IIndexZap.BurnLeg({path: _path3(address(link), address(wbtc), address(usdc)), minAmountOut: 15e6});
        vm.startPrank(alice);
        index.approve(address(zap), 2e18);
        assertEq(zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice)), NAV_USD6);

        legs[2].minAmountOut = 15e6 + 1; // and on the last hop it binds
        vm.expectRevert(bytes("Too little received"));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_XA29_zeroLegsAreStillValidatedAndTheirMinimumsApply() public {
        _mintFor(alice, 1e18, 200e6);
        vm.startPrank(alice);
        index.approve(address(zap), 1e12);
        IIndexZap.BurnLeg[] memory legs = _burnLegs(address(usdc));
        legs[0].path = ""; // the WBTC leg sells nothing for 1e12 shares, yet a malformed path is rejected
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadPath.selector, 0));
        zap.burnToToken(_burnParams(address(index), 1e12, address(usdc), 1, legs, alice));

        legs = _burnLegs(address(usdc));
        legs[0].minAmountOut = 1; // a minimum on a leg that sells nothing cannot be met
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.InsufficientOutput.selector, 0, 1));
        zap.burnToToken(_burnParams(address(index), 1e12, address(usdc), 1, legs, alice));
        vm.stopPrank();
    }

    function test_XA30_theRouterIsNotAValidRecipient() public {
        // Tokens delivered to SwapRouter02 can be swept by anyone.
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(router)));
        zap.mintWithToken(
            _mintParams(address(index), address(usdc), 1, 1e18, _mintLegs(address(usdc)), address(router))
        );
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.InvalidRecipient.selector, address(router)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(usdc), 1, _burnLegs(address(usdc)), address(router)));
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
        vm.mockCalls(address(index), abi.encodeWithSelector(IIndexToken.rebalanceNonce.selector), nonces);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 0, 1));
        zap.mintWithToken(p);
    }

    /// @dev LR-05: the XA-22 test above only proves the nonce is read twice, so a recheck moved in front of the swaps
    ///      passed it. Here a rebalance really settles in the middle of a mint: the minter pays with a callback token,
    ///      and its hook fills the auction when the zap refunds it, after the swaps and before `issue`. Only a check
    ///      placed right before `issue` sees the new nonce; without one, `issue` would pull the new basket against
    ///      approvals sized for the old one and fail with an allowance error instead.
    function test_LR05_aRebalanceSettledDuringTheRefundStopsTheMint() public {
        _mintFor(alice, 1e18, 200e6);
        market.setPriceTick(address(link), -7_000); // LINK halves, so the rule has a rebalance to start
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,,) = index.pendingRebalance();
        vm.warp(eta);

        MockHookToken hook = new MockHookToken();
        router.setPrice(address(hook), 1e18);
        RebalancingMinter minter = new RebalancingMinter(zap, index, new MockRebalanceExecutor());
        hook.mint(address(minter), 200e18);

        IIndexZap.MintParams memory p =
            _mintParams(address(index), address(hook), 200e18, 1e18, _mintLegs(address(hook)), address(minter));
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 0, 1));
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
        vm.expectRevert(IIndexZap.ZeroAmount.selector);
        zap.burnToToken(_burnParams(address(index), 0, address(usdc), 1, _burnLegs(address(usdc)), alice));
        vm.expectRevert(IIndexZap.ZeroAmount.selector);
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
        vm.expectRevert(IIndexZap.Expired.selector);
        zap.burnToToken(p);

        p.deadline = block.timestamp;
        p.index = address(weth);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(weth)));
        zap.burnToToken(p);

        p.index = address(index);
        p.legs = new IIndexZap.BurnLeg[](1);
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
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 7, 0));
        zap.burnToToken(p);
        vm.stopPrank();
    }

    function test_burn_rejectsFeeOnTransferPayout() public {
        MockFeeToken fot = new MockFeeToken();
        router.setPrice(address(fot), 1e18);
        fot.mint(address(router), 1_000_000e18);
        _mintFor(alice, 1e18, 200e6);

        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, address(fot)));
        zap.burnToToken(_burnParams(address(index), 1e18, address(fot), 1, _burnLegs(address(fot)), alice));
        vm.stopPrank();
    }

    function test_burn_partialFillReturnsUnsoldComponent() public {
        MockPartialFillRouter half = new MockPartialFillRouter(3_000e6);
        usdc.mint(address(half), 1_000_000e6);
        IndexZap halfZap = new IndexZap(factory, half);

        address[] memory t = new address[](1);
        uint256[] memory u = new uint256[](1);
        t[0] = address(weth);
        u[0] = 1e18;
        IndexToken idx = IndexToken(factory.createIndex("Ether", "ETH1", t, u, 0));

        weth.mint(alice, 1e18);
        vm.startPrank(alice);
        weth.approve(address(idx), 1e18);
        idx.issue(1e18, alice);
        idx.approve(address(halfZap), 1e18);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](1);
        legs[0] = IIndexZap.BurnLeg({path: _path2(address(weth), address(usdc)), minAmountOut: 0});

        // An overall minimum above what half the basket sells for still reverts.
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.InsufficientOutput.selector, 1_500e6, 2_970e6));
        halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 2_970e6, legs, alice));

        vm.expectEmit(true, true, true, true, address(halfZap));
        emit IIndexZap.ComponentReturned(address(idx), bob, address(weth), 5e17);
        uint256 out = halfZap.burnToToken(_burnParams(address(idx), 1e18, address(usdc), 1_000e6, legs, bob));
        vm.stopPrank();

        assertEq(out, 1_500e6);
        assertEq(usdc.balanceOf(bob), 1_500e6);
        assertEq(weth.balanceOf(bob), 5e17, "the unsold half goes to the recipient");
        assertEq(weth.balanceOf(address(halfZap)), 0);
        assertEq(weth.allowance(address(halfZap), address(half)), 0);
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
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 1, 0));
        zap.burnToTokenWithPermit(p, 27, bytes32(0), bytes32(0));
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
}

/// @dev Mints through the zap with a callback token and, when the zap refunds it, fills the index's auction.
contract RebalancingMinter is ITokenReceiverHook {
    IndexZap internal immutable ZAP;
    IndexToken internal immutable INDEX;
    MockRebalanceExecutor internal immutable EXECUTOR;

    constructor(IndexZap zap, IndexToken index, MockRebalanceExecutor executor) {
        ZAP = zap;
        INDEX = index;
        EXECUTOR = executor;
    }

    function mint(IIndexZap.MintParams calldata p) external {
        MockHookToken(p.tokenIn).approve(address(ZAP), p.maxAmountIn);
        ZAP.mintWithToken(p);
    }

    function onTokenReceived(address from, uint256) external {
        if (from == address(ZAP)) EXECUTOR.execute(INDEX, "");
    }
}
