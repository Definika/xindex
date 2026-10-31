// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice WETH stand-in whose `deposit` wraps ether one to one and whose `withdraw` unwraps it, sending the ether
///         with `transfer`'s 2300-gas stipend as the canonical WETH9 does, so a test proves the zap's `receive` fits it.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}
