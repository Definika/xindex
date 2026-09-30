// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IStateReader} from "../../src/interfaces/IStateReader.sol";

/// @notice Stands in for the snapshot exit's state reader in tests where the index runs on the same EVM as the vault: it
///         reads the index's live storage, ignoring the root and the proof, so the vault's slot arithmetic is checked
///         against a real hub. A test takes its snapshot and then leaves the hub alone, so live storage is the state at
///         the checkpoint.
contract MockStateReader is IStateReader {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function readSlots(bytes32, address account, bytes32[] calldata slots, bytes calldata)
        external
        view
        returns (bytes32[] memory values)
    {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            values[i] = VM.load(account, slots[i]);
        }
    }
}
