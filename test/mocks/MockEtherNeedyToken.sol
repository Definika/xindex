// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token that moves only for a caller that holds ether. It stands in for a `forge script` run against an OP
///         Stack chain, which fails a state-changing call from an account without ether before the call runs: a test
///         run has no such rule, and `CheckToken`'s probes must pass under it.
contract MockEtherNeedyToken is ERC20 {
    constructor() ERC20("Ether Needy", "ENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || msg.sender.balance != 0, "no ether");
        super._update(from, to, value);
    }
}
