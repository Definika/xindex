// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IAeroSwapRouter
/// @notice The two calls `KeeperExecutor` makes on Aero's concentrated-liquidity `SwapRouter` on Base, declared here
///         rather than copied: Base's `0x9Ee35Bf1bd69a03c6F0393582030fCe8Bb93D418`, which Aero's deployment record names
///         for its CL factory `0x9CB220581b91b0C83223012FE69688b92aD07a76` (Dromos Labs' `metadex-slipstream-public`,
///         `deployment-addresses/cl-base.json`), read from its verified source (Sourcify, exact match).
/// @dev Uniswap V3's router with a deadline in each call's parameters, and a path whose middle three bytes name a
///      pool's tick spacing where Uniswap's name its fee. As in Uniswap's, an exact-output path runs from the token
///      bought back to the token paid.
interface IAeroSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of the path's first token for at least `amountOutMinimum` of its last.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps at most `amountInMaximum` of the path's last token for `amountOut` of its first.
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
