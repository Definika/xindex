// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWETH9
/// @notice Wrapped ether, as the canonical WETH9 contract declares it: `deposit` takes the call's ether and credits the
///         sender the same amount of WETH, and `withdraw` burns the sender's WETH and sends the ether back to it. The
///         zap wraps on `mintWithEth` and unwraps on `burnToEth`; the Sepolia test market wraps the ether its pools are
///         seeded with.
interface IWETH9 is IERC20 {
    /// @notice Credits the sender `msg.value` of WETH.
    function deposit() external payable;

    /// @notice Burns `amount` of the sender's WETH and sends it `amount` of ether.
    function withdraw(uint256 amount) external;
}
