// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Reads storage slots of an Ethereum account under a state root the caller already trusts, from Merkle-Patricia
///         proofs. It checks no consensus: a vault uses it only under the state root of a checkpoint its verifiers
///         accepted, to pay a snapshot exit from Ethereum's state at that checkpoint once they no longer work.
interface IStateReader {
    /// @notice The values of `slots` of `account` under `stateRoot`, zero for a slot or an account that is absent.
    ///         Reverts for a proof that does not match the root.
    /// @param proof `abi.encode(bytes[] accountProof, bytes[][] storageProofs)`, one storage proof per slot.
    function readSlots(bytes32 stateRoot, address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (bytes32[] memory values);
}
