// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
import {FinalityVerifier} from "./FinalityVerifier.sol";

/// @title EthereumFinalityVerifier
/// @notice P1 on an EVM vault chain (Stage B spec, section 10): the light client of `FinalityVerifier`, advanced with an
///         SP1 proof of the statement in `proofs/finality`, checked by SP1's Groth16 verifier.
/// @dev `SP1_VERIFIER` is one Groth16 verifier deployment, not SP1's gateway, which has an owner: nothing outside this
///      contract can change what it accepts. `PROGRAM_KEY` fixes the program, and with it Ethereum's network and fork
///      schedule.
contract EthereumFinalityVerifier is FinalityVerifier {
    ISP1Verifier public immutable SP1_VERIFIER;
    bytes32 public immutable PROGRAM_KEY;

    constructor(
        ISP1Verifier sp1Verifier,
        bytes32 programKey,
        bytes32 initialAnchor,
        uint64 initialEpoch,
        uint256 genesisTime
    ) FinalityVerifier(initialAnchor, initialEpoch, genesisTime) {
        if (address(sp1Verifier) == address(0) || programKey == bytes32(0)) revert ZeroAddress();
        SP1_VERIFIER = sp1Verifier;
        PROGRAM_KEY = programKey;
    }

    /// @dev SP1's verifier takes the public values themselves.
    function _verifyProof(bytes calldata publicValues, bytes calldata proof) internal view override {
        SP1_VERIFIER.verifyProof(PROGRAM_KEY, publicValues, proof);
    }
}
