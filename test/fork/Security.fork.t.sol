// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

interface IWbtcAdmin {
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
}

interface IUsdtAdmin {
    function owner() external view returns (address);
    function setParams(uint256 newBasisPoints, uint256 newMaxFee) external;
}

/// @notice Security-review regression tests against the real mainnet tokens and router.
///         Skips when MAINNET_RPC_URL is unset.
contract SecurityForkTest is Test {
    using SafeERC20 for IERC20;

    IndexFactory factory;
    IndexZap zap;
    address user = makeAddr("user");

    uint24 constant F500 = 500;
    uint24 constant F3000 = 3000;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, vm.envOr("FORK_BLOCK", A.FORK_BLOCK));
        factory = new IndexFactory(address(this), address(0));
        zap = new IndexZap(factory, ISwapRouter02(A.SWAP_ROUTER_02));

        factory.proposeListing(A.WBTC);
        factory.proposeListing(A.WETH);
        factory.proposeListing(A.LINK);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.WBTC);
        factory.executeListing(A.WETH);
        factory.executeListing(A.LINK);
    }

    function _create(address a, uint256 ua, address b, uint256 ub) internal returns (IndexToken idx) {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = a;
        t[1] = b;
        u[0] = ua;
        u[1] = ub;
        idx = IndexToken(factory.createIndex("Fork Security", "FSEC", t, u));
    }

    function _issue(IndexToken idx, uint256 shares) internal {
        address[] memory t = idx.componentTokens();
        uint256[] memory need = idx.previewIssue(shares);
        for (uint256 i = 0; i < t.length; ++i) {
            deal(t[i], user, need[i]);
        }
        vm.startPrank(user);
        for (uint256 i = 0; i < t.length; ++i) {
            IERC20(t[i]).forceApprove(address(idx), need[i]);
        }
        idx.issue(shares, user);
        vm.stopPrank();
    }

    function test_M01_realWbtcPause_redeemSkippingFreesWethAndClaimPaysLater() public {
        IndexToken idx = _create(A.WBTC, 10_000, A.WETH, 1e15);
        _issue(idx, 1e18);
        address wbtcController = IWbtcAdmin(A.WBTC).owner();
        vm.prank(wbtcController);
        IWbtcAdmin(A.WBTC).pause();

        vm.startPrank(user);
        vm.expectRevert();
        idx.redeem(1e18, user);

        idx.redeemSkipping(1e18, user, 1 << 0);
        assertEq(IERC20(A.WETH).balanceOf(user), 1e15, "WETH comes out while WBTC is paused");
        assertEq(idx.claimOf(user, A.WBTC), 10_000);

        vm.expectRevert();
        idx.claim(A.WBTC, user);
        vm.stopPrank();

        vm.prank(wbtcController);
        IWbtcAdmin(A.WBTC).unpause();
        vm.prank(user);
        idx.claim(A.WBTC, user);
        assertEq(IERC20(A.WBTC).balanceOf(user), 10_000, "WBTC is paid once the custodian unpauses");
        assertEq(idx.totalClaims(A.WBTC), 0);
    }

    function test_I02_realUsdtFeeSwitch_zapRevertsWithTransferShortfall() public {
        IndexToken idx = _create(A.WBTC, 10_000, A.WETH, 1e15);
        _issue(idx, 1e18);

        vm.prank(IUsdtAdmin(A.USDT).owner());
        IUsdtAdmin(A.USDT).setParams(10, 5); // Tether switches on a 0.10% transfer fee

        IndexZap.BurnLeg[] memory burnLegs = new IndexZap.BurnLeg[](2);
        burnLegs[0] = IndexZap.BurnLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT), minAmountOut: 0});
        burnLegs[1] = IndexZap.BurnLeg({path: abi.encodePacked(A.WETH, F500, A.USDT), minAmountOut: 0});
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.TransferShortfall.selector, A.USDT));
        zap.burnToToken(
            IndexZap.BurnParams({
                index: address(idx),
                shares: 1e18,
                tokenOut: A.USDT,
                minAmountOut: 1,
                legs: burnLegs,
                to: user,
                deadline: block.timestamp
            })
        );
        idx.redeem(1e18, user); // the in-kind exit still works
        vm.stopPrank();
        assertEq(IERC20(A.WBTC).balanceOf(user), 10_000);

        // Minting with fee-charging USDT stops before any swap.
        deal(A.USDT, user, 100e6);
        IndexZap.MintLeg[] memory mintLegs = new IndexZap.MintLeg[](2);
        mintLegs[0] = IndexZap.MintLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT), maxAmountIn: 0});
        mintLegs[1] = IndexZap.MintLeg({path: abi.encodePacked(A.WETH, F500, A.USDT), maxAmountIn: 0});
        vm.startPrank(user);
        IERC20(A.USDT).forceApprove(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.TransferShortfall.selector, A.USDT));
        zap.mintWithToken(
            IndexZap.MintParams({
                index: address(idx),
                tokenIn: A.USDT,
                maxAmountIn: 100e6,
                shares: 1e17,
                legs: mintLegs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_I03_strayRouterEthIsRefundedNotLocked() public {
        IndexToken idx = _create(A.WBTC, 10_000, A.LINK, 1e18);
        IndexZap.MintLeg[] memory legs = new IndexZap.MintLeg[](2);
        legs[0] = IndexZap.MintLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH), maxAmountIn: 0});
        legs[1] = IndexZap.MintLeg({path: abi.encodePacked(A.LINK, F3000, A.WETH), maxAmountIn: 0});

        vm.deal(A.SWAP_ROUTER_02, 10 ether); // stray ETH sitting in SwapRouter02
        uint256 maxIn = 1 ether;
        deal(A.WETH, user, maxIn);
        vm.startPrank(user);
        IERC20(A.WETH).forceApprove(address(zap), maxIn);
        uint256 spent = zap.mintWithToken(
            IndexZap.MintParams({
                index: address(idx),
                tokenIn: A.WETH,
                maxAmountIn: maxIn,
                shares: 1e18,
                legs: legs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertEq(idx.balanceOf(user), 1e18);
        assertEq(spent, 0, "the router paid both pools with its own ETH");
        assertEq(IERC20(A.WETH).balanceOf(user), maxIn, "so the user's WETH comes back in full");
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0, "and nothing is left in the zap");
        assertLt(A.SWAP_ROUTER_02.balance, 10 ether);
    }

    function test_FR01_strayRouterEthNoLongerBlocksBurns() public {
        IndexToken idx = _create(A.WBTC, 10_000, A.WETH, 1e15);
        _issue(idx, 1e18);

        IndexZap.BurnLeg[] memory legs = new IndexZap.BurnLeg[](2);
        legs[0] = IndexZap.BurnLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC), minAmountOut: 0});
        legs[1] = IndexZap.BurnLeg({path: abi.encodePacked(A.WETH, F500, A.USDC), minAmountOut: 0});

        vm.deal(A.SWAP_ROUTER_02, 10 ether); // a griefer, or a careless user, leaves ETH in the router
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(
            IndexZap.BurnParams({
                index: address(idx),
                shares: 1e18,
                tokenOut: A.USDC,
                minAmountOut: 1,
                legs: legs,
                to: user,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(IERC20(A.USDC).balanceOf(user), out);
        assertEq(IERC20(A.WETH).balanceOf(user), 1e15, "the WETH the router never pulled comes back to the user");
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0);
        assertLt(A.SWAP_ROUTER_02.balance, 10 ether, "the router's ETH paid for the swap");
    }
}
