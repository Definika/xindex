// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title UniversalRouterCommands
/// @notice The Universal Router command bytes the zap emits, and the input each one takes.
/// @dev Vendored from Uniswap's universal-router (GPL-3.0-or-later), `contracts/libraries/Commands.sol` at commit
///      3663f6db6e2fe121753cd2d899699c2dc75dca86, which is tag 2.0.0. Only the four commands the zap builds are kept.
///      The input layouts below are from `contracts/base/Dispatcher.sol` at the same commit; they are what the zap
///      encodes against, so they are recorded here rather than left to a reader to look up.
///
///      The commands the zap deliberately never emits are as important as the ones it does: SWEEP's neighbours in the
///      set include TRANSFER and PERMIT2_TRANSFER_FROM, which move a payer's funds. That is why the zap builds every
///      command itself and forwards nothing a caller supplied.
library UniversalRouterCommands {
    /// @notice Exact-input swap through Uniswap V3.
    /// @dev Input: `abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool
    ///      payerIsUser)`. The path runs from the input token to the output token. `payerIsUser` false makes the
    ///      router pay from its own balance, which is what the zap pre-funds.
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;

    /// @notice Exact-output swap through Uniswap V3.
    /// @dev Input: `abi.encode(address recipient, uint256 amountOut, uint256 amountInMax, bytes path, bool
    ///      payerIsUser)`. The path is reversed: it runs from the output token back to the input token.
    uint8 internal constant V3_SWAP_EXACT_OUT = 0x01;

    /// @notice Sends the router's whole balance of a token to a recipient, reverting below a minimum.
    /// @dev Input: `abi.encode(address token, address recipient, uint256 amountMin)`. The zap appends this to every
    ///      swap so nothing it pre-funded can stay in the router, where anyone could sweep it.
    uint8 internal constant SWEEP = 0x04;

    /// @notice Swap through Uniswap V4.
    /// @dev Input: `abi.encode(bytes actions, bytes[] params)`, passed straight to the V4 router's action loop. See
    ///      {UniswapV4Types} for the actions and their parameters.
    uint8 internal constant V4_SWAP = 0x10;
}
