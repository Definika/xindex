// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISwapRouter02} from "./ISwapRouter02.sol";
import {PathLib} from "../../src/libraries/PathLib.sol";

/// @notice Fixed-price stand-in for SwapRouter02. Every token has a USD price (1e18 scaled);
///         swaps are settled by value using only the first and last tokens of the path.
///         Output liquidity must be minted to the router by the test.
contract MockSwapRouter is ISwapRouter02 {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    mapping(address => uint256) public priceUsd; // 1e18 = $1

    function setPrice(address token, uint256 price) external {
        priceUsd[token] = price;
    }

    /// @dev amountOut = amountIn * pIn / 10^dIn * 10^dOut / pOut
    function quoteOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 num = amountIn * priceUsd[tokenIn] * 10 ** IERC20Metadata(tokenOut).decimals();
        uint256 den = priceUsd[tokenOut] * 10 ** IERC20Metadata(tokenIn).decimals();
        return num / den;
    }

    /// @dev amountIn = ceil(amountOut * pOut / 10^dOut * 10^dIn / pIn)
    function quoteIn(address tokenIn, address tokenOut, uint256 amountOut) public view returns (uint256) {
        uint256 num = amountOut * priceUsd[tokenOut] * 10 ** IERC20Metadata(tokenIn).decimals();
        uint256 den = priceUsd[tokenIn] * 10 ** IERC20Metadata(tokenOut).decimals();
        return Math.ceilDiv(num, den);
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        require(p.path.isValidShape(), "MockRouter: path");
        address tokenIn = p.path.firstToken();
        address tokenOut = p.path.lastToken();
        require(priceUsd[tokenIn] != 0 && priceUsd[tokenOut] != 0, "MockRouter: no price");
        amountOut = quoteOut(tokenIn, tokenOut, p.amountIn);
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(tokenOut).safeTransfer(p.recipient, amountOut);
    }

    function exactOutput(ExactOutputParams calldata p) external payable returns (uint256 amountIn) {
        require(p.path.isValidShape(), "MockRouter: path");
        // exact-output paths are reversed: first = tokenOut, last = tokenIn
        address tokenOut = p.path.firstToken();
        address tokenIn = p.path.lastToken();
        require(priceUsd[tokenIn] != 0 && priceUsd[tokenOut] != 0, "MockRouter: no price");
        amountIn = quoteIn(tokenIn, tokenOut, p.amountOut);
        require(amountIn <= p.amountInMaximum, "Too much requested");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(p.recipient, p.amountOut);
    }
}
