// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title ISwapRouter02
/// @notice Minimal subset of Uniswap's SwapRouter02 (swap-router-contracts IV3SwapRouter).
/// @dev Unlike SwapRouter (v1), the params carry no deadline; callers enforce their own.
///      Mainnet: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps `amountIn` of the first token in `path` for as much as possible of the last one.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @notice Swaps as little as possible of the last token in `path` for exactly `amountOut` of the first.
    /// @dev `path` is encoded in reverse (output token first).
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
