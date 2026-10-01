// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {IVaultStateVerifier} from "../../src/interfaces/IVaultStateVerifier.sol";

/// @notice Stands in for a chain's state verifier in tests where the vault runs on the same EVM as the hub: it reads the
///         vault's real storage, so a hub's slot arithmetic and digests are checked against an actual vault. A proof is
///         `abi.encode(time, forge, value)`: the block time it claims, and, when `forge` is set, a value to report in
///         place of the storage, as an unsound verifier or a forged state would.
contract MockStateVerifier is IVaultStateVerifier {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values)
    {
        (uint256 time, bool forge, bytes32 value) = abi.decode(proof, (uint256, bool, bytes32));
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            values[i] = forge ? value : VM.load(account, slots[i]);
        }
        return (block.number, time, values);
    }
}
