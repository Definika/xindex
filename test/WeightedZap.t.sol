// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IndexZap} from "../src/IndexZap.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {IXindexErrors} from "../src/interfaces/IXindexErrors.sol";
import {PathKey} from "../src/libraries/UniswapV4Types.sol";
import {WeightedTest} from "./WeightedTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockWeightedExecutor} from "./mocks/MockWeightedExecutor.sol";

/// @notice v5 reuses `IndexZap` and `MintRequests` unchanged: deployed against the weighted factory, they mint, burn
///         and escrow weighted indexes through the functions those share with `IndexHub`, and the zap's nonce check
///         sees a weighted rebalance.
contract WeightedZapTest is WeightedTest {
    IndexZap zap;
    MintRequests requests;
    MockUniversalRouter router;
    MockERC20 usdc;
    MockERC20 usdt;
    WeightedHub index;

    uint24 constant FEE = 500;

    function setUp() public {
        _deploy();
        _listAll();
        index = _create(_defaultSpecs());

        router = new MockUniversalRouter(makeAddr("poolManager"));
        zap = new IndexZap(IIndexFactory(address(factory)), router);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        requests = new MintRequests(address(factory), address(usdc), address(usdt));

        router.setPrice(address(eth), 2000e18, 18);
        router.setPrice(address(btc), 60_000e18, 8);
        router.setPrice(address(usd), 1e18, 6);
        router.setPrice(address(usdc), 1e18, 6);
        eth.mint(address(router.inventory()), 1000e18);
        btc.mint(address(router.inventory()), 100e8);
        usd.mint(address(router.inventory()), 1_000_000e6);
        usdc.mint(address(router.inventory()), 1_000_000e6);
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b);
    }

    function _mint(uint256 shares, uint256 nonce) internal returns (uint256 spent) {
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](3);
        legs[0] =
            IIndexZap.MintLeg({v3Path: _path(address(eth), address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0});
        legs[1] =
            IIndexZap.MintLeg({v3Path: _path(address(btc), address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0});
        legs[2] =
            IIndexZap.MintLeg({v3Path: _path(address(usd), address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0});
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 1000e6);
        spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(index),
                expectedNonce: nonce,
                tokenIn: address(usdc),
                maxAmountIn: 1000e6,
                shares: shares,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_theZapMintsAndBurnsAWeightedIndex() public {
        uint256 spent = _mint(2e18, 0);
        assertEq(index.balanceOf(alice), 2e18);
        assertApproxEqRel(spent, 200e6, 0.01e18, "two $100 tokens");

        IIndexZap.BurnLeg[] memory legs = new IIndexZap.BurnLeg[](3);
        legs[0] =
            IIndexZap.BurnLeg({v3Path: _path(address(eth), address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0});
        legs[1] =
            IIndexZap.BurnLeg({v3Path: _path(address(btc), address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0});
        legs[2] =
            IIndexZap.BurnLeg({v3Path: _path(address(usd), address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0});
        vm.startPrank(alice);
        index.approve(address(zap), 1e18);
        uint256 out = zap.burnToToken(
            IIndexZap.BurnParams({
                index: address(index),
                expectedNonce: 0,
                shares: 1e18,
                tokenOut: address(usdc),
                minAmountOut: 1,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertApproxEqRel(out, 100e6, 0.01e18);
        assertEq(index.balanceOf(alice), 1e18);
    }

    /// @dev A quote from before a rebalance no longer fits after it: the zap reads the weighted index's nonce.
    function test_theZapSeesAWeightedRebalance() public {
        _mint(1e18, 0);
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 12 hours);
        MockWeightedExecutor executor = new MockWeightedExecutor();
        executor.execute(index, "", _updates(index, _ids3(), _prices3(4000e8, BTC_PRICE, USD_PRICE)));
        assertEq(index.rebalanceNonce(), 1);

        vm.expectRevert(abi.encodeWithSelector(IIndexZap.StaleRebalanceNonce.selector, 0, 1));
        this.mintAsAlice(1e18, 0);
        _mint(1e18, 1);
        assertEq(index.balanceOf(alice), 2e18);
    }

    function mintAsAlice(uint256 shares, uint256 nonce) external {
        _mint(shares, nonce);
    }

    function test_theZapRefusesAnIndexOfAnotherFactory() public {
        IIndexZap.MintLeg[] memory legs = new IIndexZap.MintLeg[](0);
        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(usdc)));
        zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(usdc),
                expectedNonce: 0,
                tokenIn: address(usdc),
                maxAmountIn: 1,
                shares: 1,
                legs: legs,
                to: alice,
                deadline: block.timestamp
            })
        );
    }

    function test_mintRequestsEscrowForAWeightedIndex() public {
        usdc.mint(stranger, 100e6);
        vm.startPrank(stranger);
        usdc.approve(address(requests), 100e6);
        uint256 id = requests.requestMint(address(index), address(usdc), 100e6, 1e18, block.timestamp + 1 days);
        vm.stopPrank();

        _issue(index, alice, 1e18);
        vm.startPrank(alice);
        index.approve(address(requests), 1e18);
        requests.fill(id, 1e18);
        vm.stopPrank();
        assertEq(index.balanceOf(stranger), 1e18);
        assertEq(usdc.balanceOf(alice), 100e6);

        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.NotIndex.selector, address(eth)));
        vm.prank(stranger);
        requests.requestMint(address(eth), address(usdc), 1, 1, block.timestamp + 1 days);
    }

    function test_theFactoryAnswersTheZapsQuestion() public view {
        assertTrue(IIndexFactory(address(factory)).isIndex(address(index)));
        assertEq(address(zap.FACTORY()), address(factory));
        IWeightedIndexFactory weighted = IWeightedIndexFactory(address(zap.FACTORY()));
        assertEq(weighted.creatorOf(address(index)), creator);
    }
}
