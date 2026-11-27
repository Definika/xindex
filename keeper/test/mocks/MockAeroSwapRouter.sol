// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PathLib} from "xindex/src/libraries/PathLib.sol";
import {MockSwapRouter} from "xindex/test/mocks/MockSwapRouter.sol";
import {IAeroSwapRouter} from "../../src/interfaces/IAeroSwapRouter.sol";

/// @notice Aero's concentrated-liquidity SwapRouter as `KeeperExecutor` calls it, at the fixed prices of a
///         `MockSwapRouter` it reads them from: it refuses a call past its deadline, as Aero's does, and records the
///         last deadline it was given. Output liquidity must be minted to it by the test.
contract MockAeroSwapRouter is IAeroSwapRouter {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    MockSwapRouter public immutable PRICES;
    uint256 public lastDeadline;

    constructor(MockSwapRouter prices) {
        PRICES = prices;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        require(p.path.isValidShape(), "MockAero: path");
        lastDeadline = p.deadline;
        address tokenIn = p.path.firstToken();
        address tokenOut = p.path.lastToken();
        amountOut = PRICES.quoteOut(tokenIn, tokenOut, p.amountIn);
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(tokenOut).safeTransfer(p.recipient, amountOut);
    }

    function exactOutput(ExactOutputParams calldata p) external payable returns (uint256 amountIn) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        require(p.path.isValidShape(), "MockAero: path");
        lastDeadline = p.deadline;
        // exact-output paths are reversed: first = tokenOut, last = tokenIn
        address tokenOut = p.path.firstToken();
        address tokenIn = p.path.lastToken();
        amountIn = PRICES.quoteIn(tokenIn, tokenOut, p.amountOut);
        require(amountIn <= p.amountInMaximum, "Too much requested");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(p.recipient, p.amountOut);
    }
}
