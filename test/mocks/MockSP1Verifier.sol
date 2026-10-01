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

    /// @notice How SP1's Groth16 verifier v6.0.0 names itself, which `DeployVault` checks.
    function VERSION() external pure returns (string memory) {
        return "v6.0.0";
    }

    function VERIFIER_HASH() external pure returns (bytes32) {
        return 0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896;
    }

    /// @notice The proof this mock accepts for `publicValues` under `programVKey`.
    function prove(bytes32 programVKey, bytes memory publicValues) external pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(programVKey, publicValues)));
    }
}
