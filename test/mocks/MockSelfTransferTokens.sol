// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token that refuses a transfer to oneself, as a `require(from != to)` token does. The hub proves a bought
///         leg can leave by sending itself one raw unit (RX-12), so a fill could never buy such a leg; `CheckToken`
///         tries the same transfer and refuses the token.
contract MockSelfRefusingToken is ERC20 {
    constructor() ERC20("Self Refusing", "SRT") {}

    function _update(address from, address to, uint256 value) internal override {
        require(from != to, "self");
        super._update(from, to, value);
    }
}

/// @notice A token whose transfer to oneself answers true but burns the amount, so the sender's balance falls. The
///         hub's probe reads the balance again after the transfer, which catches it where the answer alone would not.
contract MockSelfLosingToken is ERC20 {
    constructor() ERC20("Self Losing", "SLT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, from == to ? address(0) : to, value);
    }
}
