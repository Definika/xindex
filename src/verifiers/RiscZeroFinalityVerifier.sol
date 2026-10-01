// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRiscZeroVerifier} from "../interfaces/IRiscZeroVerifier.sol";
import {FinalityVerifier} from "./FinalityVerifier.sol";

/// @title RiscZeroFinalityVerifier
/// @notice P2 on an EVM vault chain (Stage B spec, section 11): the light client of `FinalityVerifier`, advanced with a
///         RISC Zero proof of the same statement P1 proves, `proofs/finality`, run by `proofs/p2`, a zkVM from another
///         team with its own circuits and its own Groth16 ceremony. Its journal is P1's public values, byte for byte.
/// @dev `RISC_ZERO_VERIFIER` is one Groth16 verifier deployment, not RISC Zero's router, which has an owner: nothing
///      outside this contract can change what it accepts. `IMAGE_ID` fixes the program, and with it Ethereum's network
///      and fork schedule.
contract RiscZeroFinalityVerifier is FinalityVerifier {
    IRiscZeroVerifier public immutable RISC_ZERO_VERIFIER;
    bytes32 public immutable IMAGE_ID;

    constructor(IRiscZeroVerifier riscZeroVerifier, bytes32 imageId, bytes32 initialAnchor, uint64 initialEpoch)
        FinalityVerifier(initialAnchor, initialEpoch)
    {
        if (address(riscZeroVerifier) == address(0) || imageId == bytes32(0)) revert ZeroAddress();
        RISC_ZERO_VERIFIER = riscZeroVerifier;
        IMAGE_ID = imageId;
    }

    /// @dev RISC Zero's verifier takes the journal's SHA-256 digest; the seal is the proof.
    function _verifyProof(bytes calldata publicValues, bytes calldata proof) internal view override {
        RISC_ZERO_VERIFIER.verify(proof, IMAGE_ID, sha256(publicValues));
    }
}
