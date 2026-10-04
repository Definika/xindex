// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVeChainStaker} from "../../src/interfaces/IVeChainStaker.sol";

/// @notice Stands in for VeChain's builtin Staker, etched at its address: an active list in order, each validator's
///         weight, and the total, which a test sets.
contract MockVeChainStaker is IVeChainStaker {
    address[] private _list;
    mapping(address validator => uint256) private _weight;
    uint256 private _total;

    /// @notice Replaces the active list, its weights and the total.
    function set(address[] calldata validators, uint256[] calldata weights, uint256 totalWeight) external {
        delete _list;
        for (uint256 i = 0; i < validators.length; ++i) {
            _list.push(validators[i]);
            _weight[validators[i]] = weights[i];
        }
        _total = totalWeight;
    }

    function totalStake() external view returns (uint256, uint256) {
        return (_total / 2, _total);
    }

    function firstActive() external view returns (address) {
        return _list.length == 0 ? address(0) : _list[0];
    }

    function next(address prev) external view returns (address) {
        for (uint256 i = 0; i + 1 < _list.length; ++i) {
            if (_list[i] == prev) return _list[i + 1];
        }
        return address(0);
    }

    function getValidation(address validator)
        external
        view
        returns (address, uint256, uint256, uint256, uint8, uint32)
    {
        return (validator, 25_000_000 ether, _weight[validator], 0, 2, type(uint32).max);
    }
}
