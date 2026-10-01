# Internal review of the Tron state verifier (2026-10-01)

One reviewer read `TronStateVerifier` at `75c36bc`, without changing it:
- the verifier and its interface;
- the vault's `attest`;
- the tests and `test/fixtures/tron/generate.py`;
- section 5.7 of the Stage B spec.

It checked them against java-tron's source at `b33eed8`.

**Result.** No way to forge a proof, but:
- 2 high findings, each a way for one producer to stall the verifier for good;
- 3 medium;
- 3 low;
- 1 informational.

Each finding's id is `TRN-n`, and a test for a fixed finding is named `test_TRNn_...`, as `AGENTS.md` gate 6 requires.
Each fix was checked against mutants:
- 14 on the revised verifier, both of the reviewer's forging mutants among them;
- one more on the 27-slot round's boundary.

| Id | Severity | Finding | Status |
|---|---|---|---|
| TRN-1 | High | A producer could write its own header so the verifier could not hash it, and stall the verifier for good. Two ways: a negative `version` (an int32 Tron never checks, which Java writes in ten bytes), or an unknown field in `BlockHeader.raw`, which Tron keeps and hashes (`sanitize` strips unknown fields only from `Block` and `BlockHeader`). The round must link through that producer's block. | Fixed: `version` is an `int32`, sign-extended as Java writes it, and a header carries its unknown fields as `extra`, appended as they are. Every field the verifier reads comes before `extra` and delimits itself, so the hash still fixes them. `test_TRN1_aPoisonedHeaderIsStillWritten`, `test_TRN1_headerHash_writesANegativeVersionAndUnknownFields`. |
| TRN-2 | High | The block after a maintenance is scheduled two slots behind, so its producer comes round again in a round counted from the next block. By changing its witness-permission key in between, it would sign the round with two keys, and no list could be learned. | Fixed: the round starts where the prover chooses, at least two blocks into its period, so that block is never learned, and a round of 27 slots names each producer once. `test_TRN2_theBlockAfterTheMaintenanceIsNotLearned`. |
| TRN-3 | Medium | Vouching needs 19 producers of the old list with their recorded keys. Nine voted out, nine changing keys, or nine absent for the next period would stop it for good. | Partly fixed: vouchers may sign in any later block, so absence delays the next list rather than stopping it (`test_TRN3_vouchersMaySignLater`). Nine producers voted out or changing keys before vouching still stall it until the 30-day rotation, while funds stay safe and burns still pay. A faster recovery path is the owner's decision (spec section 5.7). |
| TRN-4 | Medium | No test pinned that only the old list vouches: with the new list vouching, a fabricated round would vouch for itself. | Fixed in tests: a newcomer at its own index in the next list is refused. `test_TRN4_onlyTheOldListVouches`. |
| TRN-5 | Medium | No test pinned the key check on the round: with the witness checked alone, any key could be learned under a real witness. | Fixed in tests: a real witness listed with a key that did not sign its block is refused. `test_TRN5_learnsEachProducerWithItsOwnKey`. |
| TRN-6 | Low | The first valid `advance` for a period is final, so a front-runner could record a round that leaves out producers who missed a slot in it, narrowing TRN-3's margin. | Documented. A round of 27 slots leaves out only producers that missed their slot, and the next list can be learned from any later period. |
| TRN-7 | Low | The producer of the block holding an `attest` can make that transaction unprovable: Tron's peers check only `ret[0].contractRet`, so the producer can change the rest of the result or add unsigned unknown fields. | Documented: the keeper sends `attest` again, to be packed by another producer, which matters only near a deadline. |
| TRN-8 | Low | A key rotated out, often because it leaked, stays valid in its recorded list: for proofs until the period ends, and for a day, and for vouching for the next list. | Documented: the trust assumption counts recorded keys, not current producers. |
| TRN-9 | Info | A halt that left the period after a maintenance without a full round and its vouching stopped the verifier for good, since every header had to fall in the next period. | Fixed by TRN-2's change: the round may lie in any later period on the grid. `test_TRN9_passesOverAPeriodOnTheGrid`. |

**Checked and sound,** as the reviewer reported:
- encoding mismatches only fail closed;
- the transaction tree;
- the result check;
- `verifySlots`' binding of the vault, the slots and the values;
- the block time;
- the signatures;
- the period arithmetic;
- that nothing overflows.

**Speculative, as Tron's own.** Nineteen producers building on a block show that it was valid on a chain an honest
producer built on, not that it can never be reorganized. A partition plus fewer than 19 colluders could orphan it, as
it could Tron's own solid block.
