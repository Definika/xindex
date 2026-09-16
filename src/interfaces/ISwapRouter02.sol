// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title ISwapRouter02
/// @notice Minimal subset of Uniswap's SwapRouter02 (swap-router-contracts IV3SwapRouter).
/// @dev Unlike SwapRouter (v1), the params carry no deadline; callers enforce their own.
///      Mainnet: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
interface ISwapRouter02 {
    /// @param path Packed path from the input token to the output token: token | fee | token [| fee | token]...
    /// @param recipient Receives the output. The router reads address(1) as msg.sender and address(2) as itself.
    /// @param amountIn Exact input, paid by msg.sender. Zero means the router's own balance of the input token.
    /// @param amountOutMinimum Least output, or the swap reverts ("Too little received").
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @param path Packed path from the output token back to the input token.
    /// @param recipient Receives the output. The router reads address(1) as msg.sender and address(2) as itself.
    /// @param amountOut Exact output.
    /// @param amountInMaximum Most input pulled from msg.sender, or the swap reverts ("Too much requested").
    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps `amountIn` of the first token in `path` for as much as possible of the last one.
    /// @param params The swap; see {ExactInputParams}.
    /// @return amountOut Output delivered to the recipient.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /// @notice Swaps as little as possible of the last token in `path` for exactly `amountOut` of the first.
    /// @dev `path` is encoded in reverse (output token first).
    /// @param params The swap; see {ExactOutputParams}.
    /// @return amountIn Input taken from msg.sender.
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
