// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPancakeUniversalRouter
/// @notice The one call the zap makes on PancakeSwap's v3 Universal Router.
/// @dev Mainnet: 0x65b382653f7C31bC0Af67f188122035461ec9C76, verified source only (see `PancakeRouterCommands`). Its
///      `execute(bytes,bytes[])` has the selector of Uniswap's, and swaps it dispatches as internal calls, so a pool's
///      own revert (`V3TooMuchRequested`, `V3TooLittleReceived`, ...) reaches the caller unchanged.
///
///      Three things differ from Uniswap's router and shape how the zap uses it:
///      - It is Ownable and Pausable. Its owner, PancakeSwap's Safe, can pause it, and the same Safe owns the V3 factory,
///        which can attach a liquidity-mining contract that every pool calls during a swap. Either can stop the zap's
///        Pancake legs; neither can move a caller's funds, since the zap pre-funds only what a leg may spend and sweeps
///        the rest back in the same call. A paused router means the app routes those legs through Uniswap.
///      - It has no `poolManager()`; it carries no V4.
///      - After the last command it sends its whole ether balance to the caller and reverts if that fails, while its
///        `receive` takes ether from anyone. The zap ends every call with WRAP_ETH so nothing is left to send (SV-1).
interface IPancakeUniversalRouter {
    /// @notice Runs `commands`, one byte each, against `inputs`, one entry each.
    /// @param commands One byte per command, in order.
    /// @param inputs The abi-encoded input of each command, in the same order.
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}
