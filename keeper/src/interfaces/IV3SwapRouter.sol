// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @dev Vendored from Uniswap's swap-router-contracts (GPL-2.0-or-later) at da73b8565a0a32ccf439ebdb00b297c033c958ad,
///      `contracts/interfaces/IV3SwapRouter.sol`: the multi-hop half only, which is what `KeeperExecutor` calls on
///      SwapRouter02 (Ethereum: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45). The pragma is pinned, the single-hop
///      functions and the swap-callback base are left out, and the comments are upstream's.

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// that may remain in the router after the swap.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
