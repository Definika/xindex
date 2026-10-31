// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IUniversalRouterSwaps} from "./IUniversalRouterSwaps.sol";
import {IWETH9} from "./IWETH9.sol";

/// @title IIndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) or with ether, and burn
///         any index straight into a single token or ether, swapping through Uniswap's Universal Router. Apps encode
///         calls against this interface.
/// @dev Legs
///      - Each leg names its own venue, in the `MintLeg` and `BurnLeg` of {IUniversalRouterSwaps}. The basket
///        builder uses the same format.
///      - Depth favours V3 for some components and V4 for others, so the app picks per leg.
///      - A leg carries a V3 path or a V4 route: never both, and never neither. The exception is the pass-through leg,
///        whose component is already the token being paid or received; it carries none.
///
///      Ether
///      - `mintWithEth` and `burnToEth` are `mintWithToken` and `burnToToken` with WETH as the token: the legs route
///        to or from WETH, `tokenIn` or `tokenOut` names WETH, and the zap wraps the caller's ether on the way in and
///        unwraps the refund or the payout on the way out. The events name WETH.
///      - The caller of `mintWithEth` and the `to` of `burnToEth` must take ether: one that refuses it fails the call
///        with its own revert, or with OpenZeppelin's `FailedCall` when it gives none.
///
///      Permits
///      - `mintWithTokenPermit` and the two burns with a permit take an EIP-2612 signature for the whole amount the
///        call pulls, expiring at the call's `deadline`. The permit is tried, never required: one someone already
///        submitted is accepted, and a token without `permit` (USDT) needs an approval first.
///
///      Errors the zap raises, of the shared ones:
///      - NotIndex: an index the factory did not deploy.
///      - ZeroAddress: a zero factory, router, WETH, recipient, `tokenIn` or `tokenOut`.
///      - InvalidRecipient: a recipient that is the zap, the index, the router, the PoolManager or the factory (RT-21).
///      - The swap errors, shared with `BasketBuilder`: StaleRebalanceNonce, Expired, ZeroAmount, BadRoute, ShortFill,
///        InsufficientBudget, InsufficientOutput and TransferShortfall.
interface IIndexZap is IUniversalRouterSwaps {
    /// @param index Index to mint; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param tokenIn Token the caller pays with. The full `maxAmountIn` is pulled first and the unspent part refunded.
    ///        For `mintWithEth` it is WETH, and the ether sent with the call is what is pulled.
    /// @param maxAmountIn Most `tokenIn` the whole mint may spend; non-zero. For `mintWithEth`, exactly `msg.value`.
    /// @param shares Exact index shares to mint (1e18 is one index token); non-zero.
    /// @param legs One entry per component, in component order.
    /// @param to Receives the shares; not zero, the zap, the index, the router, the PoolManager or the factory
    ///        (RT-21).
    /// @param deadline Last timestamp at which the call is valid; also the permit's deadline.
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
    /// @param tokenOut Token the caller receives. For `burnToEth` it is WETH, paid out as ether.
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
    /// @param tokenIn What was paid with; WETH for a mint paid in ether.
    /// @param amountSpent `tokenIn` spent, after the refund.
    event ZapMint(
        address indexed index,
        address indexed user,
        address indexed to,
        address tokenIn,
        uint256 amountSpent,
        uint256 shares
    );
    /// @notice The router sold less of `component` than the zap gave it, and `amount` went to `to` instead.
    ///         - `component` is the input of the hop that was not filled; on a multi-hop leg it can be a middle token.
    ///         - `amount` is everything the hop's sweep brought back. It includes any balance of that token the router
    ///           already held, which anyone could have swept.
    ///         Unsold `tokenOut` raises the payout instead, and is not reported here.
    event ComponentReturned(address indexed index, address indexed to, address indexed component, uint256 amount);
    /// @notice `user` burned `shares` of `index` and `to` received `amountOut` of `tokenOut`.
    /// @param user The caller whose shares were burned.
    /// @param tokenOut What was paid out; WETH for a burn paid in ether.
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
    /// @notice `token` is not WETH: an ether mint names WETH as `tokenIn`, an ether burn names it as `tokenOut`, and
    ///         the zap takes ether from WETH alone.
    error NotWETH(address token);
    /// @notice `mintWithEth` was sent `value` of ether, which is not the mint's `maxAmountIn`.
    error ValueMismatch(uint256 value, uint256 maxAmountIn);

    /// @notice Factory whose registry proves an address is an index.
    function FACTORY() external view returns (IIndexFactory);

    /// @notice Wrapped ether: what `mintWithEth` wraps the caller's ether into, and `burnToEth` unwraps the payout
    ///         from.
    function WETH() external view returns (IWETH9);

    /// @notice Buys exactly `p.shares` of `p.index` for `p.to`, spending at most `p.maxAmountIn` of `p.tokenIn`. The
    ///         whole `p.maxAmountIn` is pulled from msg.sender first, and the unspent part is refunded to it.
    /// @param p The mint; see {MintParams}. msg.sender must have approved the zap for `p.maxAmountIn` of `p.tokenIn`.
    /// @return amountSpent `tokenIn` used: the swaps' input plus any `tokenIn` the basket holds directly.
    function mintWithToken(MintParams calldata p) external returns (uint256 amountSpent);

    /// @notice {mintWithToken} in one transaction, using an EIP-2612 permit for exactly `p.maxAmountIn` of `p.tokenIn`
    ///         that expires at `p.deadline`. A permit someone already submitted is accepted.
    /// @param p The mint; see {MintParams}.
    /// @param v Signature recovery id.
    /// @param r Signature r value.
    /// @param s Signature s value.
    /// @return amountSpent `tokenIn` used, as {mintWithToken} reports it.
    function mintWithTokenPermit(MintParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 amountSpent);

    /// @notice {mintWithToken} paid in ether: `p.tokenIn` is WETH, `msg.value` is `p.maxAmountIn`, and what the
    ///         swaps and the basket did not take is refunded to msg.sender as ether.
    /// @param p The mint; see {MintParams}.
    /// @return amountSpent Ether used, as {mintWithToken} reports it.
    function mintWithEth(MintParams calldata p) external payable returns (uint256 amountSpent);

    /// @notice Burns `p.shares` of `p.index` and delivers at least `p.minAmountOut` of `p.tokenOut` to `p.to`. The
    ///         shares are pulled from msg.sender, which must have approved the zap. Any part of a hop's input the
    ///         router did not take also goes to `p.to`, with a ComponentReturned event.
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

    /// @notice {burnToToken} paid in ether: `p.tokenOut` is WETH, and `p.to` is paid the proceeds as ether.
    /// @param p The burn; see {BurnParams}.
    /// @return amountOut Ether delivered.
    function burnToEth(BurnParams calldata p) external returns (uint256 amountOut);

    /// @notice {burnToEth} in one transaction, using an EIP-2612 permit as {burnToTokenWithPermit} does.
    /// @param p The burn; see {BurnParams}.
    /// @param v Signature recovery id.
    /// @param r Signature r value.
    /// @param s Signature s value.
    /// @return amountOut Ether delivered.
    function burnToEthWithPermit(BurnParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        returns (uint256 amountOut);
}
