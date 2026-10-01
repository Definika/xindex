# Proof-of-concept tests of the logic review (2026-10-02)

The reviewers' tests behind `audit/2026-10-02-logic-review.md`, as they ran against `4043fb9`. They compile only where
they were written in that commit's tree, and they pass there because the findings are still open; once a finding is
fixed, its test fails by design and becomes the model for its regression test.

- `solana_receipt_size.rs`: LG-1, in `solana/programs/ethereum-verifier/tests/` (LiteSVM, the built program).
- `EvmTwinReceiptSize.t.sol`: LG-1's EVM side, in a scratch Foundry project holding copies of the unmodified verifier
  and its libraries.
- `VaultRecoveryPoC.t.sol`: LG-2, LG-3 and LG-4, in `test/poc/`.
- `ExitEvidence.t.sol`: LG-5, in `test/poc/`, on `test/HybridTest.sol`.
- `finality_probes.rs`: LG-6 and LG-I2, in `proofs/finality/tests/`.
