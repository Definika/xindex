// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IXindexErrors
/// @notice Errors that more than one Xindex contract can raise, declared once so that the factory, hub, zap and request
///         interfaces can be combined and their shared selectors can never drift apart. Each function's NatSpec says
///         when it raises one of them.
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

    /// @notice An amount or a limit is zero: zero shares, or a zero overall limit on a zap call or a request.
    error ZeroAmount();
}
