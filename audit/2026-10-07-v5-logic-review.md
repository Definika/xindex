# Logic review of v5's core (2026-10-07)

One reviewer read the v5 surface on branch `v5-custom-weights` at `01e3d77` for logic errors, without changing it
first: `WeightedHub`, `WeightedIndexFactory`, `WeightedPricing`, `IndexZap`, `MintRequests`, and the hybrid module's
accept, settle and price-read paths. It did not read the vaults, the proofs, the state verifiers or the Move and Rust
twins.

**Result.** No exploitable logic error. The settlement's rounding, the backing post-check, the nonce checks, the
hold-offs and the zap's measurements hold against an executor that mints before its fill, pre-funds a leg, fills from
an EOA or leaves strays in the router, and against supply changes between a quote and a fill. One low finding and two
informational ones, each with the prefix `V5R-`; the test of the fixed one is named `test_V5R1_...`.

| Id | Severity | Finding | Status |
|---|---|---|---|
| V5R-1 | Low | `MIN_TRADE` was measured before the turnover cap: `_targets` summed each shrinking leg's full gap and compared that with 0.1% of the moving value, then applied `share`. A capped fill trades `share` times the gap, and `share` bottoms out at 0.2 when a target is zero, so a fill could trade 0.02% of the moving value and still restart `MIN_REBALANCE_INTERVAL`. The spec promised 0.1%. The guarantee V5-L2 needs survived, since a capped fill is never a no-op, so the loss was the stated bound, not funds. | Fixed in `WeightedHub._targets` and `WeightedPricing.targets`: the minimum is checked on `released · share`. `test_V5R1_theMinimumTradeIsMeasuredAfterTheCap` fails on the old comparison. The spec's section 5 and `AGENTS.md` restated. |
| V5R-I1 | Informational | `WeightedPricing.price` refuses a price when `36 + expo < decimals`, correctly, so a 24-decimal vault coin (NEAR) cannot be priced from a feed whose exponent falls to −13 or lower, and every fill of an index holding it then reverts until the guardian keeps it. Pyth's crypto feeds use −8. | Recorded in the library's NatSpec, the spec's section 6 beside V5-L3, and `AGENTS.md`. |
| V5R-I2 | Informational | `AGENTS.md` stated v4's `REBALANCE_DELAY` (2 days) and said v5 inherits the hold-offs unchanged, while `WeightedHub` and the spec's table use 2 hours. The code and the spec agreed; the agent instructions did not say the v5 value. | Recorded in `AGENTS.md`'s v5 section. |

Two residual exposures are already recorded and were not reopened: the executor's one-slot look-ahead across every
block of the auction (V5-L1), and a wrong Pyth price taking up to `MAX_TURNOVER` of every other component in one
atomic fill, which no guardian can cancel in time since the weighted hub's fill has no delivery window (V5-M2).

## P1 and P2, and the parsers under fuzzing (2026-10-07)

The same reviewer then read P1's statement (`proofs/finality`), the SP1 program and the RISC Zero guest, the two
on-chain finality verifiers with their base, and the Merkle-Patricia walk, looking for a way to forge a finalized
checkpoint, a header or a receipt. None was found; the slashing gap LG-I1 and the shared statement, which makes P1 and
P2 independent only in their zkVMs, were already recorded. The vaults, the input generator, the P2 host and the Solana
twins were not read.

The parsers that read prover-supplied bytes were then fuzzed, since a parser that passed garbage or read past its input
would be the one place a review by eye misses:
- `proofs/finality/tests/parsers.rs`: 2,000 headers written by the test kit's encoder parse back to their fields with
  the right hash; 25,000 random byte strings and 10,000 mutants of real headers never panic; each malformed shape is
  refused, and non-canonical lengths are accepted on purpose, since only the hash binds a header.
- `test/fixtures/trie/generate.py` builds random tries with a reference implementation of its own, keccak included
  and checked against known digests: a root that is one leaf, extensions of every length, embedded leaves and
  branches, keccak keys and receipt keys, and absent keys that diverge at a leaf, inside an extension or at an empty
  slot. `test_get_matchesTheReferenceTries` checks the walker against all 438 verdicts and values.
- Two fuzz tests in `test/MerklePatricia.t.sol` feed `RlpReader` random bytes as one item and as a list's payload:
  it refuses them with `BadRlp` or returns children that lie inside the list and a number that matches the bytes.

All pass. No bug was found by any of them.
