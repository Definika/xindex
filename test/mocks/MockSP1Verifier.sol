// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISP1Verifier} from "../../src/interfaces/ISP1Verifier.sol";

/// @notice Stands in for SP1's Groth16 verifier: a "proof" is `keccak256(abi.encode(programKey, publicValues))`, so a
///         test can prove exactly the public values it means to and nothing else.
contract MockSP1Verifier is ISP1Verifier {
    error Rejected();

    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external pure {
        if (keccak256(proofBytes) != keccak256(abi.encode(keccak256(abi.encode(programVKey, publicValues))))) {
            revert Rejected();
        }
    }

    /// @notice The proof this mock accepts for `publicValues` under `programVKey`.
    function prove(bytes32 programVKey, bytes memory publicValues) external pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(programVKey, publicValues)));
    }
}
