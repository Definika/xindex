// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IXindexErrors
/// @notice Errors that more than one Xindex contract can raise. They are declared once, so the factory, hub, zap and
///         request interfaces can be combined, and the shared selectors can never drift apart. Each function's NatSpec
///         says when it raises one.
interface IXindexErrors {
    /// @notice A required address is zero.
    error ZeroAddress();

    /// @notice Two arrays that pair up entry by entry have different lengths.
    error LengthMismatch();

    /// @notice `account` is not allowed to make this call: it needs the factory owner, or the owner or guardian.
    error Unauthorized(address account);

    /// @notice `index` was not deployed by the factory.
    error NotIndex(address index);

    /// @notice `to` cannot receive here: tokens sent to it would be stuck or would reach the wrong party.
    error InvalidRecipient(address to);

    /// @notice The contract holds `balance` of `token`, below the `required` it already owes in it, as after the
    ///         token's issuer burned part of what was held. A deposit would then pay the earlier holders, so it is
    ///         refused until the balance is whole again. The hub's `issue` raises it for a leg below the backing of
    ///         the shares already issued plus open claims (RX-8); MintRequests and the basket builder raise it for a
    ///         token below their open escrows of it (CA-H2).
    error Underbacked(address token, uint256 balance, uint256 required);

    /// @notice `token` is neither of the two stablecoins. USDC and USDT are the only currencies the zap, the basket
    ///         builder and MintRequests take and pay (the owner's call of 2026-11-18).
    error NotAStable(address token);

    // The swap errors the zap and the basket builder share, from the engine in `UniversalRouterSwaps` and around it.

    /// @notice The index rebalanced since the legs were quoted; quote again.
    error StaleRebalanceNonce(uint256 expected, uint256 actual);
    /// @notice The deadline has passed.
    error Expired();
    /// @notice Zero shares, a zero amount, or a zero overall limit.
    error ZeroAmount();
    /// @notice Leg `i` has a malformed path, one with the wrong endpoints, or a path where none belongs.
    error BadRoute(uint256 i);
    /// @notice A leg's swap delivered less of the component than the basket needs. The pinned V4 router does not check
    ///         an exact-output swap's delivery, so the engine measures it.
    error ShortFill(uint256 i, uint256 received, uint256 required);
    /// @notice The pass-through leg (the basket's own `tokenIn` component) needs more than its limit allows: more than
    ///         `maxAmountIn`, or more than the leg's own `maxAmountIn` when it sets one (DA-15). `available` is
    ///         whichever limit binds.
    error InsufficientBudget(uint256 needed, uint256 available);
    /// @notice The sale, or a leg that sells nothing, returns less than its minimum.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    /// @notice A transfer delivered less `token` than it should (a fee-on-transfer token).
    error TransferShortfall(address token);
    /// @notice Sending `other` to the router lowered the contract's balance of `token`: one balance behind two
    ///         addresses. A swap measured against both would count the same tokens twice.
    error SharedBalance(address token, address other);
}
