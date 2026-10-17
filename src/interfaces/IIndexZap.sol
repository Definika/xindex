// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IUniversalRouterSwaps} from "./IUniversalRouterSwaps.sol";

/// @title IIndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and burn any index
///         straight into a single token, swapping through Uniswap's Universal Router. Apps encode calls against this
///         interface.
/// @dev Each leg names its own venue, in the `MintLeg` and `BurnLeg` of {IUniversalRouterSwaps}, which the basket
///      builder encodes alike. Depth still favours V3 for some components and V4 for others, so the app picks per leg
///      and the zap builds the router commands for whichever it finds. A leg carries a V3 path or a V4 route, never
///      both and never neither, except the pass-through leg whose component is already the token being paid or
///      received.
///
///      Of the shared errors, the zap raises NotIndex for an index the factory did not deploy, ZeroAddress for a zero
///      factory, router, recipient, `tokenIn` or `tokenOut`, InvalidRecipient for a recipient that is the zap, the
///      index, the router, the PoolManager or the factory (RT-21), and the swap errors StaleRebalanceNonce,
///      Expired, ZeroAmount, BadRoute, ShortFill, InsufficientBudget, InsufficientOutput and TransferShortfall, which
///      `BasketBuilder` raises too.
interface IIndexZap is IUniversalRouterSwaps {
    /// @param index Index to mint; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param tokenIn Token the caller pays with. The full `maxAmountIn` is pulled first and the unspent part refunded.
    /// @param maxAmountIn Most `tokenIn` the whole mint may spend; non-zero.
    /// @param shares Exact index shares to mint (1e18 is one index token); non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives the shares; not zero, the zap, the index, the router, the PoolManager or the factory
    ///        (RT-21).
    /// @param deadline Last timestamp at which the call is valid.
    /// @param referrer Takes the referral share of the platform's part of the index's fee; zero names nobody.
    struct MintParams {
        address index;
        uint256 expectedNonce;
        address tokenIn;
        uint256 maxAmountIn;
        uint256 shares;
        MintLeg[] legs;
        address to;
        uint256 deadline;
        address referrer;
    }

    /// @param index Index to burn; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param shares Index shares to burn from the caller, who must have approved the zap (or signed a permit).
    /// @param tokenOut Token the caller receives.
    /// @param minAmountOut Least `tokenOut` the whole burn must return; non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives `tokenOut` and any unsold component; not zero, the zap, the index, the router, the
    ///        PoolManager or the factory (RT-21).
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

    /// @notice `legs` does not have one entry per component.
    error LegCountMismatch();

    /// @notice Factory whose registry proves an address is an index.
    function FACTORY() external view returns (IIndexFactory);

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
