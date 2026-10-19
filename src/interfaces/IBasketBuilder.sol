// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IUniversalRouterSwaps} from "./IUniversalRouterSwaps.sol";

/// @title IBasketBuilder
/// @notice Builds a basket too wide for one transaction.
///         - Minting: buy the legs over several calls into an escrow the caller owns here, then issue in one call.
///         - Burning: redeem into the escrow, then sell the legs over several calls.
///         Apps encode calls against this interface. Legs use the same format as the zap's.
/// @dev Nobody else is needed: no filler, no owner, no upgrade. Every amount is measured where it lands. The escrow is
///      per caller and per token, and only its owner's call moves a token in it.
///
///      Errors the builder raises, of the shared ones:
///      - NotIndex: an index the factory did not deploy.
///      - ZeroAddress: a zero factory, router, `tokenIn`, `tokenOut` or recipient.
///      - InvalidRecipient: a recipient that is the builder, the router, the PoolManager, the factory or an index
///        (RT-21).
///      The one-unit send-out probe runs on every credit that brings a token in, by deposit, buy or redeem; a sale's
///      unsold input, credited back, is a token the builder just sent out (RX-43).
///      - LengthMismatch: routes that do not pair with their legs.
///      - The engine's swap errors.
interface IBasketBuilder is IUniversalRouterSwaps {
    /// @param index Index whose basket the legs buy; must be registered in the factory.
    /// @param expectedNonce The index's `rebalanceNonce` when the legs were quoted.
    /// @param shares The shares the basket is for. Each leg buys what `previewIssue(shares)` needs of its component,
    ///        minus what the caller's escrow already holds (nothing, if the escrow already covers it).
    /// @param tokenIn Token the caller pays with. The full `maxAmountIn` is pulled first and the unspent part refunded.
    /// @param maxAmountIn Most `tokenIn` the whole call may spend; non-zero.
    /// @param components The position in the index's `componentTokens` of each leg's component.
    /// @param legs One route per entry of `components`, in the zap's mint-leg format. A leg whose component is
    ///        `tokenIn` names no route; the amount is taken from `tokenIn` directly.
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
    /// @param legs One route per token, in the zap's burn-leg format. A token that is `tokenOut` names no route; it is
    ///        paid out as is, checked against its leg's minimum.
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
    /// @notice A sale hop sold less of `token` than `user` gave it, and `amount` went back to its escrow.
    ///         - `token` is the input of the hop that was not filled; on a multi-hop leg it can be a middle token.
    ///         - `amount` includes any balance of it the router already held, which anyone could have swept.
    event Unsold(address indexed user, address indexed token, uint256 amount);

    /// @notice A leg names a component position at or beyond the index's component count.
    error ComponentOutOfRange(uint256 component);
    /// @notice The caller's escrow holds `held` of `token`, less than the `needed` the call takes from it.
    error InsufficientEscrow(address token, uint256 held, uint256 needed);

    /// @notice Factory whose registry proves an address is an index.
    function FACTORY() external view returns (IIndexFactory);

    /// @notice What `user` holds of `token` here.
    function escrowOf(address user, address token) external view returns (uint256);

    /// @notice Moves `amount` of `token` from the caller into its escrow. The caller must have approved the builder.
    ///         What arrives is what is credited, so a fee-on-transfer token credits less.
    function deposit(address token, uint256 amount) external;

    /// @notice Sends `amount` of `token` from the caller's escrow to `to`, or the whole escrow when `amount` is 0.
    function withdraw(address token, uint256 amount, address to) external;

    /// @notice Buys the named legs of `p.index`'s basket for `p.shares` into the caller's escrow, spending at most
    ///         `p.maxAmountIn` of `p.tokenIn` (which the caller must have approved). Call it as many times as the gas
    ///         cap requires, about 35 legs at a time, then call {mint}.
    /// @param p The legs; see {BuyParams}.
    /// @return amountSpent `tokenIn` used: the swaps' input plus any `tokenIn` the basket itself holds.
    function buy(BuyParams calldata p) external returns (uint256 amountSpent);

    /// @notice Issues `shares` of `index` to `to` out of the caller's escrow. The escrow must hold what `previewIssue`
    ///         needs of every component; anything left over stays in it. A gated index issues only to a `to` its
    ///         creator allows.
    /// @param referrer Takes the referral share of the platform's part of the index's fee; zero names nobody.
    /// @param deadline Last timestamp at which the call is valid.
    function mint(address index, uint256 shares, address to, address referrer, uint256 deadline) external;

    /// @notice Redeems `shares` of `index` from the caller into its escrow. The caller must have approved the builder.
    ///         Each component the index pays out is credited as measured on arrival.
    function redeem(address index, uint256 shares) external;

    /// @notice Sells the named legs of the caller's escrow into `p.tokenOut`, and pays `p.to` at least
    ///         `p.minAmountOut` of it. What a hop did not sell goes back to the escrow, with an Unsold event. Call it
    ///         as many times as the gas cap requires, then {withdraw} whatever has no route.
    /// @param p The legs; see {SellParams}.
    /// @return amountOut `tokenOut` delivered.
    function sell(SellParams calldata p) external returns (uint256 amountOut);
}
