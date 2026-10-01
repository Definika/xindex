// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRiscZeroVerifier, Receipt} from "../../src/interfaces/IRiscZeroVerifier.sol";

/// @notice Stands in for RISC Zero's Groth16 verifier: a "seal" is `keccak256(abi.encode(imageId, journalDigest))`, so a
///         test can prove exactly the journal it means to and nothing else.
contract MockRiscZeroVerifier is IRiscZeroVerifier {
    error Rejected();

    function verify(bytes calldata seal, bytes32 imageId, bytes32 journalDigest) external pure {
        if (keccak256(seal) != keccak256(abi.encode(keccak256(abi.encode(imageId, journalDigest))))) revert Rejected();
    }

    function verifyIntegrity(Receipt calldata) external pure {
        revert Rejected();
    }

    /// @notice How RISC Zero's Groth16 verifier 3.0.0 names itself, which `DeployVault` checks.
    string public constant VERSION = "3.0.0";
    bytes4 public constant SELECTOR = 0x73c457ba;

    /// @notice The seal this mock accepts for `journal` under `imageId`: the journal's SHA-256 digest, as P2 passes it.
    function prove(bytes32 imageId, bytes memory journal) external pure returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(imageId, sha256(journal))));
    }
}
