// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {XindexTest} from "../../test/XindexTest.sol";
import {WeightedTest} from "../../test/WeightedTest.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {IndexZap} from "../../src/IndexZap.sol";
import {IIndexZap} from "../../src/interfaces/IIndexZap.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IWETH9} from "../../src/interfaces/IWETH9.sol";
import {IWeightedIndexFactory} from "../../src/interfaces/IWeightedIndexFactory.sol";
import {IUniversalRouterSwaps} from "../../src/interfaces/IUniversalRouterSwaps.sol";
import {PathKey} from "../../src/libraries/UniswapV4Types.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockMarket} from "../../test/mocks/MockMarket.sol";
import {MockUniversalRouter} from "../../test/mocks/MockUniversalRouter.sol";
import {MockWeightedExecutor} from "../../test/mocks/MockWeightedExecutor.sol";

/// @dev Canonical WETH9 shape: a payable fallback that deposits, which `test/mocks/MockWETH.sol` lacks. The gap
///      matters for RT-1: on mainnet, ether sent to WETH's address is wrapped and credited to the sender.
contract WETH9Like is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        deposit();
    }
}

/// @dev Red-team probes of 2026-10-31 on the zap. Temporary: delete after the review.
contract RedTeamZapTest is XindexTest {
    IndexZap zap;
    MockUniversalRouter router;
    WETH9Like weth;
    MockERC20 usdc;
    MockERC20 wbtc;
    WeightedHub etherIndex;
    address alice = makeAddr("alice");
    uint24 constant FEE = 500;
    uint256 constant U_DUST = 1e4;

    function setUp() public {
        market = new MockMarket();
        _deployFactory(address(0));
        router = new MockUniversalRouter(makeAddr("poolManager"));
        weth = new WETH9Like();
        usdc = market.usdc();
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        zap = new IndexZap(IIndexFactory(address(factory)), router, IWETH9(address(weth)));

        router.setPrice(address(weth), 3_000e18, 18);
        router.setPrice(address(usdc), 1e18, 6);
        router.setPrice(address(wbtc), 60_000e18, 8);
        weth.mint(address(router.inventory()), 100_000e18);
        usdc.mint(address(router.inventory()), 1_000_000_000e6);
        wbtc.mint(address(router.inventory()), 1_000e8);
        vm.deal(address(weth), 1_000_000 ether);

        _listWith(address(weth));
        _listWith(address(usdc));
        _listWith(address(wbtc));
        etherIndex = _createIndex("Ether", "ETH1", _pair(address(weth), address(usdc)), _pair(1e18, U_DUST));
    }

    function _path2(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE, b);
    }

    function _noV4() internal pure returns (PathKey[] memory) {
        return new PathKey[](0);
    }

    function _issueEther(address who) internal {
        weth.mint(who, 1e18);
        usdc.mint(who, U_DUST);
        vm.startPrank(who);
        weth.approve(address(etherIndex), 1e18);
        usdc.approve(address(etherIndex), U_DUST);
        etherIndex.issue(1e18, who);
        etherIndex.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function _burnToEthParams(address to) internal view returns (IIndexZap.BurnParams memory p) {
        IUniversalRouterSwaps.BurnLeg[] memory legs = new IUniversalRouterSwaps.BurnLeg[](2);
        legs[0] = IUniversalRouterSwaps.BurnLeg({v3Path: "", v4Path: _noV4(), minAmountOut: 0});
        legs[1] = IUniversalRouterSwaps.BurnLeg({
            v3Path: _path2(address(usdc), address(weth)), v4Path: _noV4(), minAmountOut: 0
        });
        p = IIndexZap.BurnParams({
            index: address(etherIndex),
            expectedNonce: 0,
            shares: 1e18,
            tokenOut: address(weth),
            minAmountOut: 1,
            legs: legs,
            to: to,
            deadline: block.timestamp
        });
    }

    /// @notice RT-1 (Low). `burnToEth` accepts `to == WETH`. The payout's ether then hits WETH's fallback, which wraps
    ///         it and credits msg.sender: the zap. The holder gets nothing and the WETH sits in the zap, where the
    ///         balance-delta accounting of every later call keeps it out of reach for good. `_checkIndexCall` refuses the
    ///         zap, the index, the router, the pool manager and the factory for the same reason (RT-21), but not WETH.
    function test_RT1_burnToEthToTheWethAddressWrapsThePayoutBackIntoTheZap() public {
        _issueEther(alice);
        uint256 zapWethBefore = weth.balanceOf(address(zap));
        assertEq(zapWethBefore, 0);

        vm.prank(alice);
        uint256 amountOut = zap.burnToEth(_burnToEthParams(address(weth)));

        assertGt(amountOut, 0);
        assertEq(alice.balance, 0, "holder received no ether");
        assertEq(weth.balanceOf(address(zap)), amountOut, "payout re-wrapped into the zap");
        assertEq(address(zap).balance, 0);

        // Nobody can take it back out: a second holder's burn pays exactly its own proceeds.
        address bob = makeAddr("bob");
        _issueEther(bob);
        vm.prank(bob);
        uint256 bobOut = zap.burnToEth(_burnToEthParams(bob));
        assertEq(bob.balance, bobOut);
        assertEq(weth.balanceOf(address(zap)), amountOut, "stranded WETH untouched");
    }

    /// @notice RT-2 (Info). The zap's `receive` refuses every sender but WETH, and its comment says no stranger can
    ///         leave ether here. SELFDESTRUCT (and a block's coinbase) can. Nothing is lost by users: the forced ether is
    ///         simply stranded, and burns still pay exactly their own proceeds.
    function test_RT2_forcedEtherIsStrandedButHarmless() public {
        // What SELFDESTRUCT or a coinbase payment does: the balance arrives without calling `receive`.
        vm.deal(address(zap), address(zap).balance + 5 ether);
        assertEq(address(zap).balance, 5 ether, "forced in past receive()");

        _issueEther(alice);
        vm.prank(alice);
        uint256 amountOut = zap.burnToEth(_burnToEthParams(alice));
        assertEq(alice.balance, amountOut, "burn pays its own proceeds only");
        assertEq(address(zap).balance, 5 ether, "forced ether stays");
    }

    /// @notice RT-4 (confirms the design). Tokens already in the zap, and strays in the router, cannot be drawn on or
    ///         taken by a caller: the pre-fund bound never dips into the zap's prior balance, and router strays only
    ///         enlarge the caller's own refund (a gift from whoever left them, as RX-45 says of the builder).
    function test_RT4_zapStraysAreIsolatedFromACallersMint() public {
        WeightedHub blue = _createIndex("Blue", "BLUE", _pair(address(wbtc), address(weth)), _pair(100_000, 1e16));
        weth.mint(address(zap), 10e18); // a stray inside the zap
        weth.mint(address(router), 1e18); // a stray inside the router

        IUniversalRouterSwaps.MintLeg[] memory legs = new IUniversalRouterSwaps.MintLeg[](2);
        legs[0] = IUniversalRouterSwaps.MintLeg({
            v3Path: _path2(address(wbtc), address(weth)), v4Path: _noV4(), maxAmountIn: 0
        });
        legs[1] = IUniversalRouterSwaps.MintLeg({v3Path: "", v4Path: _noV4(), maxAmountIn: 0});
        IIndexZap.MintParams memory p = IIndexZap.MintParams({
            index: address(blue),
            expectedNonce: 0,
            tokenIn: address(weth),
            maxAmountIn: 1e18,
            shares: 10e18,
            legs: legs,
            to: alice,
            deadline: block.timestamp,
            referrer: address(0)
        });
        vm.deal(alice, 1e18);
        vm.prank(alice);
        zap.mintWithEth{value: 1e18}(p);

        // 10 shares = 0.001 WBTC ($60 = 0.02 WETH) + 0.1 WETH held = 0.3 WETH spent of the 1 sent; the router's
        // 1 WETH stray comes back with the sweep and goes to alice. The zap's own 10 WETH never move.
        assertEq(weth.balanceOf(address(zap)), 10e18, "zap strays untouched");
        assertEq(alice.balance, 1e18 - 0.3e18 + 1e18, "refund = unspent + router stray");
        assertEq(blue.balanceOf(alice), 10e18);
    }
}

/// @dev Red-team probes of 2026-10-31 on the hub. Temporary: delete after the review.
contract RedTeamHubTest is WeightedTest {
    address platform = makeAddr("platform");
    address bob = makeAddr("bob");

    function setUp() public {
        _deploy();
        _listAll();
    }

    /// @notice RT-3 (Info). Nothing stops a minter naming itself as referrer: it then takes `referralShareBps` of the
    ///         platform's fee on its own mint. At a 50% referral share the platform fee is halved for anyone who knows.
    function test_RT3_aMinterCanReferItself() public {
        vm.prank(owner);
        factory.setFeePolicy(25, 0, 5000, platform, 0);
        WeightedHub index = _create(_defaultSpecs());

        uint256 shares = 1_000e18;
        address[] memory tokens = index.componentTokens();
        uint256[] memory amounts = index.previewIssue(shares);
        vm.startPrank(alice);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(alice, amounts[i]);
            MockERC20(tokens[i]).approve(address(index), amounts[i]);
        }
        index.issue(shares, alice, alice);
        vm.stopPrank();

        uint256 gross = Math.mulDiv(shares, 1e4, 1e4 - 25, Math.Rounding.Ceil);
        uint256 fee = gross - shares;
        assertEq(index.balanceOf(alice), shares + fee / 2, "half the platform fee came back to the minter");
        assertEq(index.balanceOf(platform), fee - fee / 2);
    }

    /// @notice RT-5 (confirms the design). A holder who issues just before a fill at MU_MAX and redeems just after
    ///         captures a share of the executor's 2% overpayment; at MU_MIN the same holder loses 2% of the traded value
    ///         it was exposed to. The gain is the executor's loss, never other holders', and no executor fills at
    ///         MU_MAX unless Pyth lags the market by more than that (V5-L1), so this is the auction working as
    ///         documented, quantified.
    function test_RT5_flashIssuerAroundAFillGainsOnlyWhatTheExecutorOverpays() public {
        WeightedHub index = _create(_defaultSpecs());
        _issue(index, alice, 1_000e18);
        MockWeightedExecutor executor = new MockWeightedExecutor();

        // ETH doubles: ETH leg is now overweight and must be sold, BTC and USD bought.
        int64[] memory prices = new int64[](3);
        (prices[0], prices[1], prices[2]) = (4000e8, BTC_PRICE, USD_PRICE);
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        index.startRebalance(0, _updates(index, _ids3(), prices));
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta); // mu = MU_MAX

        // Bob flash-issues 9x alice's position: 90% of the supply.
        _issue(index, bob, 9_000e18);
        uint256[] memory bobBefore = _holdings(index, bob, 9_000e18);

        bytes[] memory update = _updates(index, _ids3(), prices);
        _fund(executor, index);
        executor.execute(index, "", update);

        vm.prank(bob);
        index.redeem(9_000e18, bob);
        uint256 valueBefore = _valueUsd(index, bobBefore, prices);
        uint256 valueAfter = _valueUsd(index, _balances(index, bob), prices);
        // Bob's gain is at most 2% of the moving value he was exposed to; the executor paid every cent of it.
        assertGt(valueAfter, valueBefore);
        assertLt(valueAfter - valueBefore, valueBefore * 2 / 100);
        // Alice's 10% of the index gained the same per share: the fill never costs the holders who stayed.
        uint256[] memory aliceNow = index.previewRedeem(1_000e18);
        assertGe(
            _valueUsd(index, aliceNow, prices), _valueUsd(index, _holdings(index, alice, 1_000e18), prices) * 999 / 1000
        );
    }

    function _holdings(WeightedHub index, address, uint256 shares) private view returns (uint256[] memory) {
        return index.previewRedeem(shares);
    }

    function _balances(WeightedHub index, address who) private view returns (uint256[] memory out) {
        address[] memory tokens = index.componentTokens();
        out = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            out[i] = IERC20(tokens[i]).balanceOf(who);
        }
    }

    /// @dev USD value of `amounts` at `prices` (expo -8), in 1e8 units, using each token's decimals.
    function _valueUsd(WeightedHub index, uint256[] memory amounts, int64[] memory prices)
        private
        view
        returns (uint256 value)
    {
        address[] memory tokens = index.componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            value += amounts[i] * uint256(int256(prices[i])) / 10 ** MockERC20(tokens[i]).decimals();
        }
    }

    /// @dev Gives the executor plenty of every component so it can deliver whatever the fill asks.
    function _fund(MockWeightedExecutor executor, WeightedHub index) private {
        address[] memory tokens = index.componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(address(executor), 1e30);
        }
    }
}
