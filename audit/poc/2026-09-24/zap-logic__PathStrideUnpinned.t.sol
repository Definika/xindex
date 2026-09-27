// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {PathLib} from "../../src/libraries/PathLib.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMarket} from "../mocks/MockMarket.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";

/// @dev The zap's V3 endpoint check exactly as it stands, and the same check without the stride term, so the two can
///      be compared on one input. Everything else in `_checkRoute` is unchanged.
contract RouteCheckHarness {
    using PathLib for bytes;

    function strict(bytes calldata path, address component, address userToken) external pure returns (bool) {
        return path.isValidShape() && path.firstToken() == component && path.lastToken() == userToken;
    }

    /// @dev `isValidShape` without `(path.length - ADDR_SIZE) % HOP_SIZE == 0`, which is the surviving mutant.
    function loose(bytes calldata path, address component, address userToken) external pure returns (bool) {
        return path.length >= PathLib.ADDR_SIZE + PathLib.HOP_SIZE && path.firstToken() == component
            && path.lastToken() == userToken;
    }

    /// @dev How Universal Router 2.0.0 reads a V3 path (`V3Path.sol` / `BytesLib.sol` at 3663f6db): a second pool
    ///      exists only when `length >= 66`, and the pool in hand is always the first 43 bytes. So the token it pays
    ///      with on a one-pool exact-output path is bytes [23, 43), not the last 20 bytes the zap validated.
    function routerSinglePoolInput(bytes calldata path) external pure returns (bool multiplePools, address tokenIn) {
        multiplePools = path.length >= 66;
        tokenIn = address(bytes20(path[23:43]));
    }
}

/// @notice Test-suite gap: nothing in the repository pins the stride half of `PathLib.isValidShape`.
///         A mutation sweep of `src/IndexZap.sol` and `src/libraries/PathLib.sol` (67 mutants against the whole
///         offline suite, `forge test --no-match-path 'test/{fork,redteam}/*'`) killed 63; deleting
///         `&& (path.length - ADDR_SIZE) % HOP_SIZE == 0` survived with all 445 tests passing. The only malformed path
///         the suite tries is 40 bytes long (`test_mint_revertsBadPaths`, "missing fee"), which the length term
///         already rejects.
///         The stride term is load-bearing: it is what makes the zap's endpoint check and the router's decoding
///         read the same tokens. Without it, a 64-byte mint path `component | fee | X | 1 junk byte | tokenIn`
///         passes the zap's check (first = component, last 20 bytes = tokenIn) while the router, which walks the
///         path in 23-byte strides, sees one pool (component, X) and pays with X: the endpoint validation the zap
///         documents ("a malformed route cannot leave funds in a third token") is bypassed. A burn leg with the
///         same shape would pass validation and then revert with an out-of-range calldata slice in `_sellV3`.
///         These tests pass on the real code and would fail on that mutant, so they are the missing kill-tests.
contract PathStrideUnpinnedTest is Test {
    RouteCheckHarness h;
    IndexFactory factory;
    MockMarket market;
    MockUniversalRouter router;
    IndexZap zap;
    IndexToken index;
    MockERC20 wbtc;
    MockERC20 weth;
    MockERC20 usdc;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function _list(address token) internal {
        IIndexFactory.TokenConfig memory config = market.config(token, 1e8);
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function setUp() public {
        h = new RouteCheckHarness();
        market = new MockMarket();
        factory = new IndexFactory(owner, address(0));
        router = new MockUniversalRouter(makeAddr("poolManager"));
        zap = new IndexZap(factory, router);
        weth = market.weth();
        usdc = market.usdc();
        wbtc = new MockERC20("WBTC", "WBTC", 8);
        router.setPrice(address(wbtc), 110_000e18, 8);
        router.setPrice(address(weth), 3_000e18, 18);
        router.setPrice(address(usdc), 1e18, 6);
        wbtc.mint(address(router.inventory()), 1_000e8);
        weth.mint(address(router.inventory()), 1_000e18);
        usdc.mint(address(router.inventory()), 1e15);
        _list(address(wbtc));
        _list(address(weth));
        address[] memory t = new address[](2);
        uint256[] memory u = new uint256[](2);
        (t[0], t[1]) = (address(wbtc), address(weth));
        (u[0], u[1]) = (100_000, 1e16);
        index = IndexToken(factory.createIndex("Two", "TWO", t, u, 0));
    }

    /// @dev component | fee | X | one junk byte | userToken: 64 bytes, 64 - 20 = 44, not a multiple of 23.
    function _misStrided(address component, address x, address userToken) internal pure returns (bytes memory) {
        return abi.encodePacked(component, uint24(500), x, bytes1(0xff), userToken);
    }

    function test_theStrideTermIsWhatKeepsTheZapAndTheRouterOnTheSameTokens() public view {
        bytes memory path = _misStrided(address(wbtc), address(weth), address(usdc));
        assertEq(path.length, 64);
        // The shipped check refuses it; the check without the stride term accepts it...
        assertFalse(h.strict(path, address(wbtc), address(usdc)), "shipped check refuses the path");
        assertTrue(h.loose(path, address(wbtc), address(usdc)), "without the stride term it is accepted");
        // ...while the router would treat it as one pool paid in WETH, not the USDC the zap validated and pre-funded.
        (bool multiple, address routerPaysWith) = h.routerSinglePoolInput(path);
        assertFalse(multiple);
        assertEq(routerPaysWith, address(weth), "the router pays with a token the zap never checked");
    }

    /// @notice Kill-test for the surviving mutant: a mis-strided mint leg must be BadRoute.
    function test_killTest_aMisStridedMintPathIsABadRoute() public {
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(zap), 1_000e6);
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](2);
        legs[0].v3Path = _misStrided(address(wbtc), address(weth), address(usdc));
        legs[1].v3Path = abi.encodePacked(address(weth), uint24(500), address(usdc));
        IIndexZap.MintParams memory p = IIndexZap.MintParams({
            index: address(index),
            expectedNonce: 0,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6,
            shares: 1e18,
            legs: legs,
            to: alice,
            deadline: block.timestamp
        });
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadRoute.selector, 0));
        zap.mintWithToken(p);
    }

    /// @notice Kill-test for the surviving mutant: a mis-strided burn leg must be BadRoute, not a bare revert.
    function test_killTest_aMisStridedBurnPathIsABadRoute() public {
        // Give alice one share, in kind.
        wbtc.mint(address(this), 100_000);
        weth.mint(address(this), 1e16);
        wbtc.approve(address(index), 100_000);
        weth.approve(address(index), 1e16);
        index.issue(1e18, alice);
        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](2);
        legs[0].v3Path = _misStrided(address(wbtc), address(weth), address(usdc));
        legs[1].v3Path = abi.encodePacked(address(weth), uint24(500), address(usdc));
        IIndexZap.BurnParams memory p = IIndexZap.BurnParams({
            index: address(index),
            expectedNonce: 0,
            shares: 1e18,
            tokenOut: address(usdc),
            minAmountOut: 1,
            legs: legs,
            to: alice,
            deadline: block.timestamp
        });
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IIndexZap.BadRoute.selector, 0));
        zap.burnToToken(p);
        vm.stopPrank();
    }
}
