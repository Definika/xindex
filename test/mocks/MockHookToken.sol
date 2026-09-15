// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenReceiverHook {
    function onTokenReceived(address from, uint256 amount) external;
}

/// @notice ERC-777-style token that notifies contract recipients after every transfer. It exists only to
///         show why callback tokens must stay off the whitelist.
contract MockHookToken is ERC20 {
    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to.code.length != 0) {
            try ITokenReceiverHook(to).onTokenReceived(from, value) {} catch {}
        }
    }
}
