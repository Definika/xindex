// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice A plain ERC-20 with an EIP-2612 permit, as USDC and most listed tokens have.
contract MockERC20 is ERC20, ERC20Permit {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) ERC20Permit(name_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Changes the reported decimals, so a test can prove the rule reads them on every call rather than
    ///         storing them at listing. A real ERC-20 does not do this; a proxy repointed to another aggregator is the
    ///         case it stands in for.
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
