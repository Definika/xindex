// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title IUniversalRouter
/// @notice Minimal subset of Uniswap's Universal Router: the one call the zap makes, and the one read it needs.
/// @dev Mainnet 2.0.0: 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af. The zap is pinned to that deployment rather than
///      the 2.1.x line, whose command inputs carry an extra per-hop price array and which shipped a change its own
///      authors later reverted.
interface IUniversalRouter {
    /// @notice Runs `commands`, one byte each, against `inputs`, one entry each.
    /// @dev The zap builds both itself and never forwards anything a caller supplied: the router's command set
    ///      includes sweeps and Permit2 transfers, so passing calldata through would hand a caller the router's
    ///      permissions. There is also a deadline overload; the zap enforces its own and uses this one.
    ///
    ///      A failure surfaces unchanged. The router wraps a command in `ExecutionFailed` only when it made that
    ///      command with a low-level call, and swaps are dispatched as internal calls, so what reaches the caller is
    ///      the pool's own revert: `V3TooMuchRequested`, `V4TooLittleReceived` and their neighbours. Verified against
    ///      the pinned deployment on a mainnet fork; that error is therefore not declared here.
    /// @param commands One byte per command, in order.
    /// @param inputs The abi-encoded input of each command, in the same order.
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;

    /// @notice The Uniswap V4 singleton this router settles V4 swaps against.
    function poolManager() external view returns (address);
}
