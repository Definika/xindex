// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWeightedHub} from "xindex/src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IRebalanceExecutor} from "xindex/src/interfaces/IRebalanceExecutor.sol";
import {IMintRequests} from "xindex/src/interfaces/IMintRequests.sol";
import {WeightedHub} from "xindex/src/WeightedHub.sol";
import {MintRequests} from "xindex/src/MintRequests.sol";
import {Vm} from "forge-std/Vm.sol";
import {WeightedTest} from "xindex/test/WeightedTest.sol";
import {MockERC20} from "xindex/test/mocks/MockERC20.sol";
import {MockSwapRouter} from "xindex/test/mocks/MockSwapRouter.sol";
import {ISwapRouter02} from "xindex/test/mocks/ISwapRouter02.sol";
import {KeeperExecutor} from "../src/KeeperExecutor.sol";
import {IV3SwapRouter} from "../src/interfaces/IV3SwapRouter.sol";
import {ITokenBridge} from "../src/interfaces/ITokenBridge.sol";
import {MockTokenBridge} from "./mocks/MockTokenBridge.sol";

/// @notice A router that swaps honestly and, in the middle of every swap, calls its caller's rebalance callback as
///         an index would, asking for `bait` of `wanted`. It answers `componentTokens` as an index does, so an
///         executor that did not ask who was calling would read the list and pay. It stands for anything an executor
///         calls during a fill: a pool, or a token on the route.
contract BaitingRouter {
    struct Outcome {
        bool opened;
        bytes answer;
    }

    MockSwapRouter internal immutable INNER;
    address[] internal _tokens;
    uint256[] internal _wanted;
    Outcome[] internal _outcomes;

    constructor(MockSwapRouter inner, address[] memory tokens, uint256[] memory wanted) {
        INNER = inner;
        _tokens = tokens;
        _wanted = wanted;
    }

    function componentTokens() external view returns (address[] memory) {
        return _tokens;
    }

    function outcomes() external view returns (Outcome[] memory) {
        return _outcomes;
    }

    function exactInput(ISwapRouter02.ExactInputParams calldata p) external payable returns (uint256) {
        _bait();
        address tokenIn = address(bytes20(p.path[:20]));
        _take(tokenIn, p.amountIn);
        return INNER.exactInput(p);
    }

    function exactOutput(ISwapRouter02.ExactOutputParams calldata p) external payable returns (uint256) {
        _bait();
        // An exact-output path runs backwards: the token paid is its last.
        address tokenIn = address(bytes20(p.path[p.path.length - 20:]));
        _take(tokenIn, INNER.quoteIn(tokenIn, address(bytes20(p.path[:20])), p.amountOut));
        return INNER.exactOutput(p);
    }

    function _take(address token, uint256 amount) private {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(address(INNER), amount);
    }

    function _bait() private {
        uint256[] memory nothing = new uint256[](_tokens.length);
        bytes memory routes = abi.encode(new bytes[](_tokens.length));
        (bool opened, bytes memory answer) =
            msg.sender.call(abi.encodeCall(IRebalanceExecutor.onXindexRebalance, (nothing, _wanted, routes)));
        _outcomes.push(Outcome(opened, answer));
    }
}

/// @notice The executor's keeper, as a contract: it sends a fill and then, in the same call and so in the same
///         transaction, has `index` call the executor's callback. Foundry clears transient storage between a test's
///         own calls, so only a contract shows what a fill leaves behind for the rest of its transaction.
contract FillThenCallBack {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run(KeeperExecutor executor, KeeperExecutor.AuctionFill calldata f, uint256[] calldata wanted)
        external
        returns (bool opened, bytes memory answer)
    {
        executor.fill(f);
        uint256[] memory nothing = new uint256[](wanted.length);
        bytes memory routes = abi.encode(new bytes[](wanted.length));
        VM.prank(address(f.index));
        (opened, answer) =
            address(executor).call(abi.encodeCall(IRebalanceExecutor.onXindexRebalance, (nothing, wanted, routes)));
    }
}

/// @notice The hacks that took a bot's funds through its own callback, replayed against the keeper's executor
///         (`audit/2026-11-23-attack-replay.md`, HK-01): Augustus V6 in March 2024, whose swap callback never asked
///         who was calling, the arbitrage bots baited through theirs, and SIR.trading in March 2025, whose check of
///         the caller read a transient slot that a later step of the same transaction had overwritten.
contract KeeperExecutorAttacksTest is WeightedTest {
    uint256 constant ETH_UP = 2400;
    uint256 constant STOCK = 5e18;

    MockERC20 usdc;
    MockERC20 usdt;
    MockSwapRouter market;
    MintRequests requests;
    MockTokenBridge bridge;
    WeightedHub index;
    address execOwner = makeAddr("execOwner");
    address keeper = makeAddr("keeper");

    function setUp() public {
        _deploy();
        _listAll();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        market = new MockSwapRouter();
        market.setPrice(address(eth), ETH_UP * 1e18);
        market.setPrice(address(btc), BTC_PRICE * 1e18);
        market.setPrice(address(usd), 1e18);
        market.setPrice(address(usdc), 1e18);
        eth.mint(address(market), 1000e18);
        btc.mint(address(market), 100e8);
        usd.mint(address(market), 1e12);
        usdc.mint(address(market), 1e12);
        requests = new MintRequests(address(factory), address(usdc), address(usdt));
        bridge = new MockTokenBridge();
        index = _create(_defaultSpecs());
        _issue(index, alice, 100e18);
    }

    /// @dev An executor on `router`, with a float and `STOCK` of ETH the owner allows it to deliver: what a caller of
    ///      the callback would ask for.
    function _executor(address router, address keeper_) internal returns (KeeperExecutor executor) {
        executor = new KeeperExecutor(
            IV3SwapRouter(router),
            address(usdc),
            IWeightedIndexFactory(address(factory)),
            IMintRequests(address(requests)),
            ITokenBridge(address(bridge)),
            execOwner,
            keeper_
        );
        usdc.mint(address(executor), 10_000e6);
        eth.mint(address(executor), STOCK);
        vm.prank(execOwner);
        executor.setStockAllowance(address(eth), STOCK);
    }

    function _routes() internal view returns (bytes[] memory routes) {
        routes = new bytes[](3);
        routes[0] = abi.encodePacked(address(eth), uint24(500), address(usdc));
        routes[1] = abi.encodePacked(address(btc), uint24(3000), address(eth), uint24(500), address(usdc));
        routes[2] = abi.encodePacked(address(usd), uint24(100), address(usdc));
    }

    /// @dev What a caller posing as the index asks for: the executor's whole stock of ETH, for nothing.
    function _wanted() internal pure returns (uint256[] memory wanted) {
        wanted = new uint256[](3);
        wanted[0] = STOCK;
    }

    /// @dev Opens the index's auction, halfway through, and returns the fill at the market's prices.
    function _auction() internal returns (KeeperExecutor.AuctionFill memory) {
        vm.warp(index.lastRebalance() + index.MIN_REBALANCE_INTERVAL());
        vm.prank(stranger);
        index.startRebalance(0);
        (uint256 eta,) = index.pendingRebalance();
        vm.warp(eta + 2 hours);
        return KeeperExecutor.AuctionFill({
            index: IWeightedHub(address(index)),
            newUnits: _onWeights(index, _market(ETH_UP, BTC_PRICE, USD_PRICE)),
            routes: _routes(),
            maxAmountsIn: new uint256[](0),
            maxSupply: type(uint256).max,
            minUsdcDelta: type(int256).min,
            deadline: block.timestamp,
            pythUpdate: new bytes[](0)
        });
    }

    /// @dev While the executor is inside a fill its callback is open, to the index it is filling and to nobody else.
    ///      Every swap of the fill calls the callback as an index would and asks for the stock: each call is refused
    ///      by name, the fill goes through, and the stock and its allowance are untouched.
    function test_HK01_aSwapInsideAFillCannotCallTheCallbackAsTheIndex() public {
        address[] memory tokens = index.componentTokens();
        BaitingRouter router = new BaitingRouter(market, tokens, _wanted());
        KeeperExecutor executor = _executor(address(router), keeper);

        KeeperExecutor.AuctionFill memory f = _auction();
        vm.prank(keeper);
        executor.fill(f);

        assertEq(index.rebalanceNonce(), 1, "the fill did not settle");
        BaitingRouter.Outcome[] memory outcomes = router.outcomes();
        assertEq(outcomes.length, 3, "one sale of ETH and a purchase of each of the other two");
        bytes memory refusal = abi.encodeWithSelector(KeeperExecutor.UnexpectedCaller.selector, address(router));
        for (uint256 i = 0; i < outcomes.length; ++i) {
            assertFalse(outcomes[i].opened, "the callback answered a caller that is not the index being filled");
            assertEq(outcomes[i].answer, refusal);
        }
        assertEq(eth.balanceOf(address(executor)), STOCK, "the stock left");
        assertEq(executor.stockAllowance(address(eth)), STOCK);
        assertEq(eth.balanceOf(address(router)), 0);
    }

    /// @dev The mark that opens the callback is cleared when its fill ends, so it opens nothing later in the same
    ///      transaction: not to the index that was just filled, whose own code never calls it then, and so not to
    ///      anything that could make a call come from that address.
    function test_HK01_theCallbackClosesWhenItsFillEnds() public {
        FillThenCallBack sequence = new FillThenCallBack();
        KeeperExecutor executor = _executor(address(market), address(sequence));

        (bool opened, bytes memory answer) = sequence.run(executor, _auction(), _wanted());

        assertEq(index.rebalanceNonce(), 1, "the fill did not settle");
        assertFalse(opened, "the callback answered after its fill had ended");
        assertEq(answer, abi.encodeWithSelector(KeeperExecutor.UnexpectedCaller.selector, address(index)));
        assertEq(eth.balanceOf(address(executor)), STOCK, "the stock left");
        assertEq(executor.stockAllowance(address(eth)), STOCK);
    }
}
