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
}
