// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {PathLib} from "../../src/libraries/PathLib.sol";

/// @notice Sells only half of `amountIn`, like a Uniswap V3 pool that reaches its price limit before the
///         whole input is sold. Pays `outPerWholeIn` of the last path token per 1e18 input units.
contract MockPartialFillRouter is ISwapRouter02 {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    uint256 public immutable outPerWholeIn;

    constructor(uint256 outPerWholeIn_) {
        outPerWholeIn = outPerWholeIn_;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        uint256 used = p.amountIn / 2;
        amountOut = used * outPerWholeIn / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        IERC20(p.path.firstToken()).safeTransferFrom(msg.sender, address(this), used);
        IERC20(p.path.lastToken()).safeTransfer(p.recipient, amountOut);
    }

    function exactOutput(ExactOutputParams calldata) external payable returns (uint256) {
        revert("MockPartialFillRouter: exactOutput unsupported");
    }
}
