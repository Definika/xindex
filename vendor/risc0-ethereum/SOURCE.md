# RISC Zero's Groth16 verifier, vendored

Unchanged from [risc0/risc0-ethereum](https://github.com/risc0/risc0-ethereum) (Apache-2.0, `LICENSE`) at
`365e7b2db4f620fa256580c27558d2623362b9ae`, tag v3.0.1, the release matching the zkVM P2 is built with
(`proofs/p2`, RISC Zero 3.0.6), and the commit `src/interfaces/IRiscZeroVerifier.sol` names:

- `src/groth16/RiscZeroGroth16Verifier.sol`, `src/groth16/Groth16Verifier.sol`, `src/groth16/ControlID.sol`: the
  verifier P2's `RiscZeroFinalityVerifier` calls on every vault chain, deployed with `ControlID.CONTROL_ROOT` and
  `ControlID.BN254_CONTROL_ID`. P2 binds one such deployment, never RISC Zero's owned router (Stage B spec, section 11).
- `src/IRiscZeroVerifier.sol`, `src/IRiscZeroSelectable.sol`, `src/StructHash.sol`, `src/Util.sol`: what it imports.
- `test/TestReceiptV3_0.sol`: RISC Zero's own v3.0 receipt, a real seal, which `tron/` verifies on TRON's VM.

The files import OpenZeppelin as `openzeppelin/contracts/`, which maps to `lib/openzeppelin-contracts/contracts/`. They
sit outside `src/`, so the repository's gates (coverage, lint, Wake, Aderyn) do not run on them: they are RISC Zero's,
audited with their release, and change only by replacing them with another release's files.
