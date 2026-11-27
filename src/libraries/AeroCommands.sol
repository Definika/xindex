// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title AeroCommands
/// @notice The command bytes the engine sends Aero's Metarouter on Base, and the input each takes.
/// @dev Read from the Metarouter's verified source (`V3/src/metarouter/libraries/Commands.sol` and `Metarouter.sol` of
///      Dromos Labs' `metadex-public`). The bytes are Uniswap's numbers, but a swap's input is a struct naming its
///      pools ({IAeroMetarouter}). After its last command the Metarouter returns the whole balance of every token the
///      batch touched to the caller, which is the engine.
library AeroCommands {
    /// @notice Exact-input swap through CL pools. Input: `abi.encode(IAeroMetarouter.SwapExactInParams)`.
    uint8 internal constant CL_SWAP_EXACT_IN = 0x00;
    /// @notice Exact-output swap through CL pools. Input: `abi.encode(IAeroMetarouter.SwapExactOutParams)`; the
    ///         pool must deliver exactly `amountOut`.
    uint8 internal constant CL_SWAP_EXACT_OUT = 0x01;
    /// @notice Sends the router's whole balance of a token to a recipient, reverting below a minimum. Input:
    ///         `abi.encode(address token, address recipient, uint256 amountMin)`; the recipient is never the router.
    uint8 internal constant SWEEP = 0x04;
    /// @notice Exact-input swap through basic pools, volatile or stable. Input:
    ///         `abi.encode(IAeroMetarouter.SwapExactInParams)`.
    uint8 internal constant V2_SWAP_EXACT_IN = 0x08;
    /// @notice Exact-output swap through basic pools. Input: `abi.encode(IAeroMetarouter.SwapExactOutParams)`; the
    ///         pools quote the input backwards and the recipient's balance must rise by `amountOut`.
    uint8 internal constant V2_SWAP_EXACT_OUT = 0x09;
}
