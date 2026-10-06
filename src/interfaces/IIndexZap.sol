// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IPancakeUniversalRouter} from "./IPancakeUniversalRouter.sol";
import {IUniversalRouter} from "./IUniversalRouter.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {PathKey} from "../libraries/UniswapV4Types.sol";

/// @title IIndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and burn any index
///         straight into a single token, swapping through Uniswap's Universal Router and, leg by leg, PancakeSwap's.
///         Apps encode calls against this interface.
/// @dev Each leg names its own venue. Depth favours Uniswap V3 for some components, V4 for others and PancakeSwap V3
///      for a few (CAKE above all), so the app picks per leg and the zap builds the router commands for whichever it
///      finds. A leg carries exactly one of a Uniswap V3 path, a Uniswap V4 route and a PancakeSwap V3 path, except the
///      pass-through leg whose component is already the token being paid or received, which carries none.
///
///      Of the shared errors, the zap raises NotIndex for an index the factory did not deploy, ZeroAddress for a zero
///      factory, router, recipient, `tokenIn` or `tokenOut`, and InvalidRecipient for a recipient that is the zap, the
///      index, either router, the PoolManager, the factory or the rule (RT-21).
interface IIndexZap is IXindexErrors {
    /// @param v3Path Exact-output Uniswap V3 path from the component back to `tokenIn`. Empty for any other leg and
    ///        for the pass-through leg whose component is `tokenIn` itself.
    /// @param v4Path Uniswap V4 route, whose first entry names `tokenIn` because an exact-output route is walked from
    ///        the component backwards. Empty for any other leg and for the pass-through leg. Native ether may appear as
    ///        an intermediate currency but never as an endpoint, and every hop must be hookless.
    /// @param pancakePath Exact-output PancakeSwap V3 path from the component back to `tokenIn`, in Uniswap's packed
    ///        format (PancakeSwap's tiers are 100, 500, 2500 and 10000). Empty for any other leg and for the
    ///        pass-through leg, and refused when the zap was deployed without a PancakeSwap router.
    /// @param maxAmountIn Most `tokenIn` this leg may spend, or 0 for the overall limit only.
    struct MintLeg {
        bytes v3Path;
        PathKey[] v4Path;
        bytes pancakePath;
        uint256 maxAmountIn;
    }

    /// @param v3Path Exact-input Uniswap V3 path from the component to `tokenOut`. Empty for any other leg and for the
    ///        pass-through leg whose component is `tokenOut` itself. Checked even when the component redeems to zero.
    ///        Each hop is swapped on its own, so the unsold input of any hop, not only the first, comes back to `to`;
    ///        an intermediate hop that sells nothing reverts with InsufficientOutput.
    /// @param v4Path Uniswap V4 route, whose last entry names `tokenOut`. Empty for any other leg and for the
    ///        pass-through leg. The whole route is one swap, so an intermediate hop that fills short leaves the pool manager
    ///        unsettled and reverts the leg, unless that hop's input is the component or `tokenOut` again: a route that
    ///        revisits the component nets the leftover against the leg's debt, and it comes back to `to`, while a
    ///        leftover `tokenOut` is paid out. On a route that revisits neither, only the first hop can leave unsold
    ///        input, which comes back to `to`.
    /// @param pancakePath Exact-input PancakeSwap V3 path from the component to `tokenOut`. Empty for any other leg and
    ///        for the pass-through leg. Swapped one hop at a time, as a Uniswap V3 path is, with the same returns.
    /// @param minAmountOut Least `tokenOut` this leg must return, or 0 for the overall limit only. It applies to the
    ///        leg's final output. A non-zero minimum on a leg whose redeemed amount rounds to zero reverts, and so does
    ///        an intermediate V3 hop that produces nothing, whatever the minimum (RT-11).
    struct BurnLeg {
        bytes v3Path;
        PathKey[] v4Path;
        bytes pancakePath;
        uint256 minAmountOut;
    }

    /// @param index Index to mint; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param tokenIn Token the caller pays with. The full `maxAmountIn` is pulled first and the unspent part refunded.
    /// @param maxAmountIn Most `tokenIn` the whole mint may spend; non-zero.
    /// @param shares Exact index shares to mint (1e18 is one index token); non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives the shares; not zero, the zap, the index, either router, the PoolManager, the factory or
    ///        the rule (RT-21).
    /// @param deadline Last timestamp at which the call is valid.
    struct MintParams {
        address index;
        uint256 expectedNonce;
        address tokenIn;
        uint256 maxAmountIn;
        uint256 shares;
        MintLeg[] legs;
        address to;
        uint256 deadline;
    }

    /// @param index Index to burn; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param shares Index shares to burn from the caller, who must have approved the zap (or signed a permit).
    /// @param tokenOut Token the caller receives.
    /// @param minAmountOut Least `tokenOut` the whole burn must return; non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives `tokenOut` and any unsold component; not zero, the zap, the index, either router,
    ///        the PoolManager, the factory or the rule (RT-21).
    /// @param deadline Last timestamp at which the call is valid; also the permit's deadline.
    struct BurnParams {
        address index;
        uint256 expectedNonce;
        uint256 shares;
        address tokenOut;
        uint256 minAmountOut;
        BurnLeg[] legs;
        address to;
        uint256 deadline;
    }

    /// @notice `user` paid `amountSpent` of `tokenIn` and `to` received `shares` of `index`.
    /// @param user The caller who paid.
    /// @param to The recipient of the shares.
    /// @param amountSpent `tokenIn` spent, after the refund.
    event ZapMint(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenIn,
        uint256 amountSpent,
        uint256 shares
    );
    /// @notice The router sold less of `component` than the zap gave it; `amount` went to `to` instead. `component`
    ///         is the input of the hop that was not filled, so on a multi-hop leg it can be an intermediate token.
    ///         `amount` is everything the hop's sweep brought back, so it also includes any balance of that token the
    ///         router was already holding, which anyone could have swept. Unsold `tokenOut` raises the payout instead
    ///         and is not reported here.
    event ComponentReturned(address indexed index, address indexed to, address indexed component, uint256 amount);
    /// @notice `user` burned `shares` of `index` and `to` received `amountOut` of `tokenOut`.
    /// @param user The caller whose shares were burned.
    /// @param amountOut `tokenOut` delivered to `to`.
    event ZapBurn(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenOut,
        uint256 shares,
        uint256 amountOut
    );

    /// @notice The index rebalanced since the legs were quoted; quote again.
    error StaleRebalanceNonce(uint256 expected, uint256 actual);
    /// @notice The deadline has passed.
    error Expired();
    /// @notice Zero shares, or a zero overall limit.
    error ZeroAmount();
    /// @notice `legs` does not have one entry per component.
    error LegCountMismatch();
    /// @notice Leg `i` names no venue or more than one, has a malformed path, one with the wrong endpoints, a hooked V4
    ///         pool, a path where none belongs, or a PancakeSwap path on a zap deployed without PancakeSwap's router.
    error BadRoute(uint256 i);
    /// @notice A leg's swap delivered less of the component than the basket needs. The V4 router at the version this
    ///         zap is pinned to does not check an exact-output swap's delivery itself, so the zap measures it.
    error ShortFill(uint256 i, uint256 received, uint256 required);
    /// @notice The basket's own `tokenIn` component needs more than is available for it: more than `maxAmountIn`, or
    ///         more than that leg's own `maxAmountIn` when it sets one (DA-15). `available` is whichever limit binds.
    error InsufficientBudget(uint256 needed, uint256 available);
    /// @notice The burn, or a leg that sells nothing, returns less than its minimum.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    /// @notice A transfer delivered less `token` than it should (a fee-on-transfer token).
    error TransferShortfall(address token);

    /// @notice Factory whose registry proves an address is an index.
    function FACTORY() external view returns (IIndexFactory);

    /// @notice Uniswap's Universal Router, through which every Uniswap V3 and V4 leg runs.
    function ROUTER() external view returns (IUniversalRouter);

    /// @notice PancakeSwap's v3 Universal Router, through which every PancakeSwap leg runs; zero when this zap was
    ///         deployed without one, which refuses every PancakeSwap leg. Never a valid recipient: anyone can sweep a
    ///         router's balance.
    function PANCAKE_ROUTER() external view returns (IPancakeUniversalRouter);

    /// @notice The Uniswap V4 singleton the router settles V4 legs against, read from the router at construction. It
    ///         is never a valid recipient: anything sent there is a donation to the protocol.
    function POOL_MANAGER() external view returns (address);

    /// @notice Buys exactly `p.shares` of `p.index` for `p.to`, spending at most `p.maxAmountIn` of `p.tokenIn`. The
    ///         whole `p.maxAmountIn` is pulled from msg.sender first, and the unspent part is refunded to it.
    /// @param p The mint; see {MintParams}. msg.sender must have approved the zap for `p.maxAmountIn` of `p.tokenIn`.
    /// @return amountSpent `tokenIn` used: the swaps' input plus any `tokenIn` the basket holds directly.
    function mintWithToken(MintParams calldata p) external returns (uint256 amountSpent);

    /// @notice Burns `p.shares` of `p.index` (pulled from msg.sender, which must have approved the zap) and delivers at
    ///         least `p.minAmountOut` of `p.tokenOut` to `p.to`. Any part of a hop's input the router did not take also
    ///         goes to `p.to`, with a ComponentReturned event.
    /// @param p The burn; see {BurnParams}.
    /// @return amountOut `tokenOut` delivered.
    function burnToToken(BurnParams calldata p) external returns (uint256 amountOut);

    /// @notice {burnToToken} in one transaction, using an EIP-2612 permit for exactly `p.shares` that expires at
    ///         `p.deadline`. A permit someone already submitted is accepted.
    /// @param p The burn; see {BurnParams}.
    /// @param v Signature recovery id.
    /// @param r Signature r value.
    /// @param s Signature s value.
    /// @return amountOut `tokenOut` delivered.
    function burnToTokenWithPermit(BurnParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 amountOut);
}
