// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SP1 Verifier Interface
/// @author Succinct Labs
/// @notice Vendored from succinctlabs/sp1-contracts (MIT) at d3629729c3216eb51bd4859d027a8eb729399fa4,
///         `contracts/src/ISP1Verifier.sol`, with the pragma pinned: the interface of SP1's Groth16 verifier, which a
///         P1 verifier calls.
interface ISP1Verifier {
    /// @notice Verifies a proof with given public values and vkey.
    /// @dev It is expected that the first 4 bytes of proofBytes must match the first 4 bytes of
    /// target verifier's VERIFIER_HASH.
    /// @param programVKey The verification key for the RISC-V program.
    /// @param publicValues The public values encoded as bytes.
    /// @param proofBytes The proof of the program execution the SP1 zkVM encoded as bytes.
    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view;
}
