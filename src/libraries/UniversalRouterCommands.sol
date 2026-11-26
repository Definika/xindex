// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title UniversalRouterCommands
/// @notice The Universal Router command bytes the engine emits, and the input each one takes.
/// @dev The router's command set is a protocol fact: a one-byte opcode per command, dispatched by the deployment the
///      engine is pinned to. Two deployments read it: Uniswap's universal-router tag 2.0.0, and PancakeSwap's Infinity
///      Universal Router on BNB Chain, a fork of Uniswap's whose V3 and SWEEP commands take the same inputs. The values
///      and input layouts below were read from both deployments' verified source and checked on a fork; they are
///      declared here in our own words so the engine encodes against a record in this repository rather than one a
///      reader has to look up.
///
///      The commands the engine deliberately never emits are as important as the ones it does: SWEEP's neighbours in
///      the set include TRANSFER and PERMIT2_TRANSFER_FROM, which move a payer's funds. That is why the engine builds
///      every command itself and forwards nothing a caller supplied.
library UniversalRouterCommands {
    /// @notice Exact-input swap through V3 pools: Uniswap's, or PancakeSwap's on its router.
    /// @dev Input: `abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool
    ///      payerIsUser)`. The path runs from the input token to the output token. `payerIsUser` false makes the
    ///      router pay from its own balance, which is what the engine pre-funds.
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    /// @notice Exact-output swap through V3 pools.
    /// @dev Input: `abi.encode(address recipient, uint256 amountOut, uint256 amountInMax, bytes path, bool
    ///      payerIsUser)`. The path is reversed: it runs from the output token back to the input token.
    uint8 internal constant V3_SWAP_EXACT_OUT = 0x01;
    /// @notice Sends the router's whole balance of a token to a recipient, reverting below a minimum.
    /// @dev Input: `abi.encode(address token, address recipient, uint256 amountMin)`. The engine appends this to every
    ///      swap so nothing it pre-funded can stay in the router, where anyone could sweep it.
    uint8 internal constant SWEEP = 0x04;
    /// @notice Exact-input swap through V2 pairs. Sent to PancakeSwap's router alone.
    /// @dev Input: `abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, address[] path, bool
    ///      payerIsUser)`, the path forward from the input token. An `amountIn` of zero means the first pair was
    ///      already paid, and swaps whatever it holds above its reserves: the engine never sends zero.
    uint8 internal constant V2_SWAP_EXACT_IN = 0x08;
    /// @notice Exact-output swap through V2 pairs. Sent to PancakeSwap's router alone.
    /// @dev Input: `abi.encode(address recipient, uint256 amountOut, uint256 amountInMax, address[] path, bool
    ///      payerIsUser)`, the path forward from the input token. The router quotes the input from the pairs'
    ///      reserves and pays it to the first pair.
    uint8 internal constant V2_SWAP_EXACT_OUT = 0x09;
    /// @notice Swap through Uniswap V4. Sent to Uniswap's router alone.
    /// @dev Input: `abi.encode(bytes actions, bytes[] params)`, passed straight to the V4 router's action loop. See
    ///      {UniswapV4Types} for the actions and their parameters.
    uint8 internal constant V4_SWAP = 0x10;
}
