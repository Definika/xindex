// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Burns 1% of every transfer. Used to prove IndexHub.issue rejects fee-on-transfer tokens.
contract MockFeeToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Burns up to FLAT_FEE raw units of every transfer between two accounts, so the whole of a smaller one, and
///         nothing of a transfer to oneself. A small deposit then delivers nothing, while the basket builder's
///         one-unit send-out probe, a transfer to itself, still passes (CA-R2-16).
contract MockFlatFeeToken is ERC20 {
    uint256 public constant FLAT_FEE = 5;

    constructor() ERC20("Flat Fee Token", "FLAT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from != to) {
            uint256 fee = value < FLAT_FEE ? value : FLAT_FEE;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
