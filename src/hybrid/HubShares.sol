// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title HubShares
/// @notice The three share operations the module needs, on the hub's own ERC-20 state: read the supply, move the bond,
///         burn it. OpenZeppelin's `ERC20Upgradeable` keeps that state at an ERC-7201 slot, so the module reads and
///         writes exactly what the hub's token does, without carrying the token's whole public surface, which the hub
///         already answers. Each operation is OpenZeppelin v5.7.0's `_update` for its case, event included.
/// @dev `test_moduleSharesAreTheHubsShares` pins the slot and the struct against the hub's `balanceOf` and
///      `totalSupply`.
// The one assembly here points a storage struct at OpenZeppelin's own ERC-7201 slot.
// forge-lint: disable-next-item(inline-assembly)
abstract contract HubShares {
    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20_STORAGE = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    /// @dev OpenZeppelin's `ERC20Upgradeable.ERC20Storage`, field for field.
    struct Erc20Storage {
        mapping(address account => uint256) _balances;
        mapping(address account => mapping(address spender => uint256)) _allowances;
        uint256 _totalSupply;
        string _name;
        string _symbol;
    }

    function _shares() private pure returns (Erc20Storage storage $) {
        assembly ("memory-safe") {
            $.slot := ERC20_STORAGE
        }
    }

    function _shareSupply() internal view returns (uint256) {
        return _shares()._totalSupply;
    }

    /// @dev A transfer of `value` shares from `from` to `to`, neither zero.
    function _moveShares(address from, address to, uint256 value) internal {
        Erc20Storage storage $ = _shares();
        uint256 balance = $._balances[from];
        if (balance < value) revert IERC20Errors.ERC20InsufficientBalance(from, balance, value);
        unchecked {
            // As OpenZeppelin's: value <= balance <= totalSupply, and a balance plus value is at most totalSupply.
            $._balances[from] = balance - value;
            $._balances[to] += value;
        }
        // Only views precede a share move in the module: the factory's registry and freeze records.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IERC20.Transfer(from, to, value);
    }

    /// @dev A burn of `value` shares held by `from`.
    function _burnShares(address from, uint256 value) internal {
        Erc20Storage storage $ = _shares();
        uint256 balance = $._balances[from];
        if (balance < value) revert IERC20Errors.ERC20InsufficientBalance(from, balance, value);
        unchecked {
            // As OpenZeppelin's: value <= balance <= totalSupply.
            $._balances[from] = balance - value;
            $._totalSupply -= value;
        }
        // Only views, and claims booked in storage, precede a burn in the module.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IERC20.Transfer(from, address(0), value);
    }
}
