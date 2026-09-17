// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {ForkAddresses as A, IPoolLiquidity} from "./ForkAddresses.sol";

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
        // FORK_BLOCK overrides the pin, for a non-archive RPC that only serves recent state. Forge loads .env
        // automatically, so a MAINNET_RPC_URL set there makes a plain `forge test` run these suites too.
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        factory = new IndexFactory(address(this), address(0), A.WETH, A.UNISWAP_V3_FACTORY, A.USDC);
        zap = new IndexZap(factory, ISwapRouter02(A.SWAP_ROUTER_02));

        factory.proposeListing(A.WBTC, _config(A.WBTC_WETH_500, A.BTC_SUPPLY));
        factory.proposeListing(A.WETH, _config(address(0), A.ETH_SUPPLY));
        factory.proposeListing(A.LINK, _config(A.LINK_WETH_3000, A.LINK_SUPPLY));
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(A.WBTC);
        factory.executeListing(A.WETH);
        factory.executeListing(A.LINK);
    }

    /// @dev A listing config whose minimum liquidity is a tenth of the pool's liquidity at the fork block, the policy
    ///      of the mainnet list.
    function _config(address pool, uint256 referenceSupply) internal view returns (IIndexFactory.TokenConfig memory c) {
        c.pool = pool;
        if (pool != address(0)) c.minLiquidity = IPoolLiquidity(pool).liquidity() / 10;
        c.referenceSupply = referenceSupply;
    }

    function _create(address a, uint256 ua, address b, uint256 ub) internal returns (IndexToken idx) {
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        t[0] = a;
        t[1] = b;
        u[0] = ua;
        u[1] = ub;
        idx = IndexToken(factory.createIndex("Fork Security", "FSEC", t, u, 0));
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
        vm.expectRevert(bytes("")); // WBTC's whenNotPaused reverts with no data
        idx.redeem(1e18, user);

        idx.redeemSkipping(1e18, user, 1 << 0);
        assertEq(IERC20(A.WETH).balanceOf(user), 1e15, "WETH comes out while WBTC is paused");
        assertEq(idx.claimOf(user, A.WBTC), 10_000);

        vm.expectRevert(bytes("")); // still paused
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

        IIndexZap.BurnLeg[] memory burnLegs = new IIndexZap.BurnLeg[](2);
        burnLegs[0] = IIndexZap.BurnLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT), minAmountOut: 0});
        burnLegs[1] = IIndexZap.BurnLeg({path: abi.encodePacked(A.WETH, F500, A.USDT), minAmountOut: 0});
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, A.USDT));
        zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(idx),
                expectedNonce: 0,
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
        IIndexZap.MintLeg[] memory mintLegs = new IIndexZap.MintLeg[](2);
        mintLegs[0] = IIndexZap.MintLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDT), maxAmountIn: 0});
        mintLegs[1] = IIndexZap.MintLeg({path: abi.encodePacked(A.WETH, F500, A.USDT), maxAmountIn: 0});
        vm.startPrank(user);
        IERC20(A.USDT).forceApprove(address(zap), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.TransferShortfall.selector, A.USDT));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(idx),
                expectedNonce: 0,
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
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0] = IIndexZap.MintLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH), maxAmountIn: 0});
        legs[1] = IIndexZap.MintLeg({path: abi.encodePacked(A.LINK, F3000, A.WETH), maxAmountIn: 0});

        vm.deal(A.SWAP_ROUTER_02, 10 ether); // stray ETH sitting in SwapRouter02
        uint256 maxIn = 1 ether;
        deal(A.WETH, user, maxIn);
        vm.startPrank(user);
        IERC20(A.WETH).forceApprove(address(zap), maxIn);
        uint256 spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(idx),
                expectedNonce: 0,
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

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0] = IIndexZap.BurnLeg({path: abi.encodePacked(A.WBTC, F500, A.WETH, F500, A.USDC), minAmountOut: 0});
        legs[1] = IIndexZap.BurnLeg({path: abi.encodePacked(A.WETH, F500, A.USDC), minAmountOut: 0});

        vm.deal(A.SWAP_ROUTER_02, 10 ether); // a griefer, or a careless user, leaves ETH in the router
        vm.startPrank(user);
        idx.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(idx),
                expectedNonce: 0,
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
        // The WETH leg's whole input comes back, and so does the WETH the WBTC leg's first hop bought: its second hop
        // is swapped on its own, and the router paid that one from its stray ETH too instead of pulling the WETH.
        // Before the per-hop fix (XA-08) that intermediate WETH stayed in the router for anyone to sweep.
        assertGt(IERC20(A.WETH).balanceOf(user), 1e15, "the WETH the router never pulled comes back to the user");
        assertEq(IERC20(A.WETH).balanceOf(address(zap)), 0);
        assertLt(A.SWAP_ROUTER_02.balance, 10 ether, "the router's ETH paid for the swap");
    }
}
