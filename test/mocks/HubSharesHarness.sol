// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {HubShares} from "../../src/hybrid/HubShares.sol";

/// @notice OpenZeppelin's ERC-20 and HubShares on one contract's storage, so a test can check that HubShares mints,
///         moves, burns and reads exactly the balances and supply OpenZeppelin's token keeps.
contract HubSharesHarness is ERC20Upgradeable, HubShares {
    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function mintShares(address to, uint256 value) external {
        _mintShares(to, value);
    }

    function move(address from, address to, uint256 value) external {
        _moveShares(from, to, value);
    }

    function burnFrom(address from, uint256 value) external {
        _burnShares(from, value);
    }

    function shareSupply() external view returns (uint256) {
        return _shareSupply();
    }
}
