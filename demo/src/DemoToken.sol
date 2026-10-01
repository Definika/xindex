// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TESTNETS ONLY (design/2026-09-30-hackathon-plan.md).

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DemoToken
/// @notice A testnet stand-in for an Ethereum component, freely minted, for the hackathon demonstration only.
contract DemoToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice Anyone, on a testnet: mints `amount` to `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
