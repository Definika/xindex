// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Wrapped ether, as the canonical WETH9 contract declares it: `deposit` takes the call's ether and credits the
///         sender the same amount of WETH. The Sepolia test market wraps the ether its pools are seeded with. No
///         contract in `src/` names it, when the zap's ether entry points went.
interface IWETH9 is IERC20 {
    /// @notice Credits the sender `msg.value` of WETH.
    function deposit() external payable;
}
