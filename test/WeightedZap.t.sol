// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IndexZap} from "../src/IndexZap.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexZap} from "../src/interfaces/IIndexZap.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";
import {IWeightedHub} from "../src/interfaces/IWeightedHub.sol";
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

    function _legs() internal view returns (IUniversalRouterSwaps.MintLeg[] memory legs) {
        legs = new IUniversalRouterSwaps.MintLeg[](3);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path(address(eth), address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[1] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path(address(btc), address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0
        });
        legs[2] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path(address(usd), address(usdc)), v4Path: new PathKey[](0), maxAmountIn: 0
        });
    }

    function _mint(uint256 shares, uint256 nonce) internal returns (uint256 spent) {
        return _mintOn(index, shares, nonce, address(0));
    }

    function _mintOn(WeightedHub idx, uint256 shares, uint256 nonce, address referrer)
        internal
        returns (uint256 spent)
    {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 1000e6);
        spent = zap.mintWithToken(
            IIndexZap.MintParams({
                index: address(idx),
                expectedNonce: nonce,
                tokenIn: address(usdc),
                maxAmountIn: 1000e6,
                shares: shares,
                legs: _legs(),
                to: alice,
                deadline: block.timestamp,
                referrer: referrer
            })
        );
        vm.stopPrank();
    }

    /// @dev The zap sizes its legs by the index's preview, fee included, and names the referrer the caller gave.
    function test_theZapBuysTheFeeAndNamesTheReferrer() public {
        address platform = makeAddr("platform");
        address referrer = makeAddr("referrer");
        vm.prank(owner);
        factory.setFeePolicy(25, 0, 5000, platform, 0);
        IWeightedIndexFactory.IndexParams memory p = _params();
        p.creatorFeeBps = 100;
        WeightedHub feeIndex = _create(_defaultSpecs(), p);

        uint256 plain = _mint(1e18, 0);
        usdc.mint(alice, 1000e6);
        vm.prank(alice);
        usdc.approve(address(zap), 1000e6);
        IIndexZap.MintParams memory p2 = IIndexZap.MintParams({
            index: address(feeIndex),
            expectedNonce: 0,
            tokenIn: address(usdc),
            maxAmountIn: 1000e6,
            shares: 1e18,
            legs: _legs(),
            to: alice,
            deadline: block.timestamp,
            referrer: referrer
        });
        vm.prank(alice);
        vm.expectEmit(true, false, false, false, address(feeIndex));
        emit IWeightedHub.FeeSharesMinted(referrer, address(0), address(0), 0, 0, 0);
        uint256 withFee = zap.mintWithToken(p2);

        assertEq(feeIndex.balanceOf(alice), 1e18);
        assertGt(feeIndex.balanceOf(referrer), 0, "the referrer took its share");
        assertGt(feeIndex.balanceOf(creator), feeIndex.balanceOf(platform), "the creator's part is the larger");
        assertGt(withFee, plain, "the fee's shares were bought too");
        assertEq(feeIndex.totalSupply(), uint256(1e18 * 10_000 + 9874) / 9875);
    }

    function test_theZapMintsAndBurnsAWeightedIndex() public {
        uint256 spent = _mint(2e18, 0);
        assertEq(index.balanceOf(alice), 2e18);
        assertApproxEqRel(spent, 200e6, 0.01e18, "two $100 tokens");

        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](3);
        legs[0] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path(address(eth), address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[1] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path(address(btc), address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0
        });
        legs[2] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path(address(usd), address(usdc)), v4Path: new PathKey[](0), minAmountOut: 0
        });
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
        index.startRebalance(0, pyth.liveUpdates(index, 0));
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + index.AUCTION_DURATION() / 2);
        MockWeightedExecutor executor = new MockWeightedExecutor();
        executor.execute(index, "", _updates(index, _ids3(), _prices3(4000e8, BTC_PRICE, USD_PRICE)));
        assertEq(index.rebalanceNonce(), 1);

        vm.expectRevert(abi.encodeWithSelector(IXindexErrors.StaleRebalanceNonce.selector, 0, 1));
        this.mintAsAlice(1e18, 0);
        _mint(1e18, 1);
        assertEq(index.balanceOf(alice), 2e18);
    }

    function mintAsAlice(uint256 shares, uint256 nonce) external {
        _mint(shares, nonce);
    }

    function test_theZapRefusesAnIndexOfAnotherFactory() public {
        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](0);
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
                deadline: block.timestamp,
                referrer: address(0)
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
