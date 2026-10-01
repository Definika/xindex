// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStateReader} from "../interfaces/IStateReader.sol";
import {MerklePatricia} from "../libraries/MerklePatricia.sol";

/// @title EthereumStateReader
/// @notice Reads an Ethereum account's storage under a trusted state root, from the proofs `eth_getProof` returns. See
///         {IStateReader}. It is stateless and has no owner: a vault fixes one at deployment and uses it only for a
///         snapshot exit, under the state root of the last checkpoint its verifiers accepted.
contract EthereumStateReader is IStateReader {
    error LengthMismatch();

    /// @inheritdoc IStateReader
    function readSlots(bytes32 stateRoot, address account, bytes32[] calldata slots, bytes calldata proof)
        external
        pure
        returns (bytes32[] memory values)
    {
        (bytes[] memory accountProof, bytes[][] memory storageProofs) = abi.decode(proof, (bytes[], bytes[][]));
        uint256 n = slots.length;
        if (storageProofs.length != n) revert LengthMismatch();
        values = new bytes32[](n);
        (bool exists, bytes32 root) = MerklePatricia.storageRoot(stateRoot, account, accountProof);
        // An account the root shows absent has no storage: every slot reads zero.
        if (!exists) return values;
        for (uint256 i = 0; i < n; ++i) {
            values[i] = MerklePatricia.slotAt(root, slots[i], storageProofs[i]);
        }
    }
}
