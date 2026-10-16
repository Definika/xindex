// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IUniversalRouterSwaps} from "./IUniversalRouterSwaps.sol";

/// @title IBasketBuilder
/// @notice Builds a basket too wide for one transaction: the legs are bought over several calls into an escrow the
///         caller owns here, then issued in one; selling mirrors it, a redeem into the escrow and the legs sold over
///         several calls. Apps encode calls against this interface, with the legs encoded as the zap's.
/// @dev Nobody else is needed: no filler, no owner, no upgrade. Every amount is measured where it lands, the escrow is
///      per caller and per token, and a token in it is only ever moved by its owner's call. Of the shared errors, the
///      builder raises NotIndex for an index the factory did not deploy, ZeroAddress for a zero factory, router,
///      `tokenIn` or `tokenOut`, InvalidRecipient for a recipient that is the builder, the router, the PoolManager,
///      the factory, an index or zero, LengthMismatch for routes that do not pair with their legs, and the engine's
///      swap errors (RT-21).
interface IBasketBuilder is IUniversalRouterSwaps {
    /// @param index Index whose basket the legs buy; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param shares The shares the basket is for: each leg buys what `previewIssue(shares)` needs of its component
    ///        beyond what the caller's escrow already holds, and buys nothing when the escrow already covers it.
    /// @param tokenIn Token the caller pays with. The full `maxAmountIn` is pulled first and the unspent part refunded.
    /// @param maxAmountIn Most `tokenIn` the whole call may spend; non-zero.
    /// @param components The position in the index's `componentTokens` of each leg's component.
    /// @param legs One route per entry of `components`, as the zap's mint legs. A leg whose component is `tokenIn`
    ///        names no route and keeps the amount out of `tokenIn` instead.
    /// @param deadline Last timestamp at which the call is valid.
    struct BuyParams {
        address index;
        uint256 expectedNonce;
        uint256 shares;
        address tokenIn;
        uint256 maxAmountIn;
        uint256[] components;
        MintLeg[] legs;
        uint256 deadline;
    }

    /// @param tokenOut Token the proceeds are paid in.
    /// @param minAmountOut Least `tokenOut` the whole call must pay; non-zero.
    /// @param tokens The escrowed tokens to sell.
    /// @param amounts How much of each, or 0 for the whole escrow of it.
    /// @param legs One route per token, as the zap's burn legs. A token that is `tokenOut` names no route and is paid
    ///        out as it is, against its leg's minimum.
    /// @param to Receives the proceeds.
    /// @param deadline Last timestamp at which the call is valid.
    struct SellParams {
        address tokenOut;
        uint256 minAmountOut;
        address[] tokens;
        uint256[] amounts;
        BurnLeg[] legs;
        address to;
        uint256 deadline;
    }

    /// @notice `user` put `amount` of `token` into its escrow, measured as what arrived.
    event Deposited(address indexed user, address indexed token, uint256 amount);
    /// @notice `user` took `amount` of `token` out of its escrow, to `to`.
    event Withdrawn(address indexed user, address indexed token, address indexed to, uint256 amount);
    /// @notice `user` paid `amountSpent` of `tokenIn` for legs of `index`'s basket for `shares`, now in its escrow.
    event Bought(address indexed user, address indexed index, address tokenIn, uint256 amountSpent, uint256 shares);
    /// @notice `user` issued `shares` of `index` to `to` out of its escrow.
    event Minted(address indexed user, address indexed index, address indexed to, uint256 shares);
    /// @notice `user` redeemed `shares` of `index` into its escrow.
    event Redeemed(address indexed user, address indexed index, uint256 shares);
    /// @notice `user` sold legs of its escrow and `to` received `amountOut` of `tokenOut`.
    event Sold(address indexed user, address indexed to, address tokenOut, uint256 amountOut);
    /// @notice A sale hop sold less of `token` than `user` gave it; `amount` went back to its escrow. `token` is the
    ///         input of the hop that was not filled, so on a multi-hop leg it can be an intermediate token, and the
    ///         amount includes any balance of it the router was already holding, which anyone could have swept.
    event Unsold(address indexed user, address indexed token, uint256 amount);

    /// @notice A leg names a component position at or beyond the index's component count.
    error ComponentOutOfRange(uint256 component);
    /// @notice The caller's escrow holds `held` of `token`, less than the `needed` the call takes from it.
    error InsufficientEscrow(address token, uint256 held, uint256 needed);

    /// @notice Factory whose registry proves an address is an index.
    function FACTORY() external view returns (IIndexFactory);

    /// @notice What `user` holds of `token` here.
    function escrowOf(address user, address token) external view returns (uint256);

    /// @notice Puts `amount` of `token` from the caller, which must have approved the builder, into its escrow. What
    ///         arrived is what is credited, so a fee-on-transfer token credits less.
    function deposit(address token, uint256 amount) external;

    /// @notice Sends `amount` of `token` from the caller's escrow to `to`, or the whole escrow when `amount` is 0.
    function withdraw(address token, uint256 amount, address to) external;

    /// @notice Buys the named legs of `p.index`'s basket for `p.shares` into the caller's escrow, spending at most
    ///         `p.maxAmountIn` of `p.tokenIn`, which the caller must have approved. Call it as many times as the gas
    ///         cap needs, about 35 legs at a time, then {mint}.
    /// @param p The legs; see {BuyParams}.
    /// @return amountSpent `tokenIn` used: the swaps' input plus any `tokenIn` the basket itself holds.
    function buy(BuyParams calldata p) external returns (uint256 amountSpent);

    /// @notice Issues `shares` of `index` to `to` out of the caller's escrow, which must hold what `previewIssue`
    ///         needs of every component; what is left stays in the escrow. A gated index issues only to a `to` its
    ///         creator allows.
    /// @param referrer Takes the referral share of the platform's part of the index's fee; zero names nobody.
    /// @param deadline Last timestamp at which the call is valid.
    function mint(address index, uint256 shares, address to, address referrer, uint256 deadline) external;

    /// @notice Redeems `shares` of `index` from the caller, which must have approved the builder, into its escrow:
    ///         every component the index pays out, measured as it arrives.
    function redeem(address index, uint256 shares) external;

    /// @notice Sells the named legs of the caller's escrow into `p.tokenOut` and pays `p.to` at least
    ///         `p.minAmountOut` of it. What a hop did not sell goes back to the escrow, with an Unsold event. Call it
    ///         as many times as the gas cap needs, then {withdraw} whatever has no route.
    /// @param p The legs; see {SellParams}.
    /// @return amountOut `tokenOut` delivered.
    function sell(SellParams calldata p) external returns (uint256 amountOut);
}
