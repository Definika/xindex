# Proving prototype: plan and cost model (Phase 2)

The prototype decides Stage B. It measures what the vaults' two proof directions would cost and how long they would
take, against thresholds the owner confirmed on 2026-09-30. It ships nothing. The code lives in `prototype/`, a Rust
workspace that Foundry and Wake never see.

## The go/no-go thresholds (confirmed by the owner, 2026-09-30)

| Measure | Pass |
|---|---|
| End to end, from Ethereum finality to a vault accepting the proof | ≤ 60 minutes |
| Verification on BNB Chain | ≤ 1,000,000 gas |
| Verification on Solana, one transaction | ≤ 1,400,000 compute units |
| Proving cost on rented GPUs | ≤ $50 per proof, since one proof serves a batch of burns |

Passing all four means Stage B goes ahead as designed, with P1 as the first Ethereum-finality proof system and a
second, independent one to follow. Missing any one brings the design's sync-committee fallback (section 4.4) back to
the owner as a decision.

## What is proved

### Ethereum → vault (P1): full finality

The statement, for a vault that holds a trusted anchor, the last checkpoint it accepted:
- the anchor is an epoch `e0`, the root of its checkpoint block, and a commitment `V0` to the active validator set with
  effective balances;
- given the anchor, checkpoint `C1` at epoch `e1 > e0` is finalized.

Concretely:
1. **The validator set.** The beacon state `S1` at `C1` commits, through its SSZ root, to a validator registry. The
   commitment `V1` to that registry's active set follows from `V0` through proven churn: activations and exits are
   bounded per epoch by the churn limit.
2. **The shuffling.** The committee assignments of epochs `e1` and `e1 + 1` are the swap-or-not shuffle of the active
   indices under the RANDAO seed in `S1`. The prover supplies the permutation, and the guest recomputes the shuffle's
   hashes to check it.
3. **The signatures.** For every aggregate attestation, in the blocks of those two epochs, that names `C1` as its
   target and its predecessor as its source:
   - the attesters' public keys come from `V1`, through the committee bits and aggregation bits;
   - their aggregate BLS12-381 signature over the attestation data verifies.
4. **The supermajority.** The distinct attesters' effective balances sum to at least two thirds of the total active
   balance, for `C1` and for the checkpoint that finalizes it: Casper's two-epoch rule.
5. **The outputs.** `C1`'s root, and its execution payload's block hash, against which the vault checks a burn's
   receipt, plus the new anchor `(e1, V1)`.

The guest proves this in a zkVM. The proof is then wrapped as a BN254 Groth16 proof, which BNB Chain verifies in
Solidity and Solana verifies with its `alt_bn128` syscalls.

### Vault → Ethereum: one system per chain

BNB Chain first. Its fast finality is a BLS12-381 aggregate vote by at least two thirds of a small validator set, a
few dozen validators. Since Pectra, Ethereum has BLS12-381 precompiles (EIP-2537), so this direction may need no zkVM
at all:
- one pairing check on chain for the vote;
- a Merkle-Patricia proof of the vault's storage slot against the voted block's state root.

The prototype measures that native path first. A zkVM path is needed only if the native one breaks 1M gas.

Solana is sized on paper. Its proof is built for Alpenglow's finalization certificates (design section 6.10), and
whether Alpenglow is live on devnet decides whether a measurement is possible yet.

## Cost model

The guest's cycle count is the sum of a few primitives times their counts:

```
C ≈ N · (c_add + c_key) + A · c_pair + H · c_sha + c_fixed
```

| Symbol | What | Where the number comes from |
|---|---|---|
| `N` | active validators, about a million | the beacon API, at a recent finalized epoch |
| `A` | aggregate attestations checked, two epochs' worth | the beacon API: blocks of two epochs |
| `H` | SHA-256 compressions: the registry's SSZ merkleization, the shuffle, the state branches | counted from `N` |
| `c_add`, `c_key` | adding one public key to an aggregate; reading it from the committed set | measured (M1) |
| `c_pair` | one aggregate signature check, i.e. two Miller loops and a final exponentiation | measured (M1) |
| `c_sha` | one SHA-256 compression with the zkVM's precompile | measured (M1) |

The proving cost is `C` times the price of a proved cycle, measured on the GPU run (M4). The same run gives the
latency: proving time plus the Groth16 wrap, added to Ethereum's own finality delay of about 13 minutes.

The dominant term is expected to be the registry: merkleizing about a million validator records takes on the order of
ten million SHA-256 compressions. The obvious saving is to keep `V` as a commitment updated by churn, not re-hashed
each time. The prototype measures both.

## Measurements

| Step | What | Where | Load on this Mac |
|---|---|---|---|
| M1 | Primitive costs: `c_pair`, `c_add`, `c_key`, `c_sha` | the zkVM's execute mode, on small synthetic data | light: seconds, one core |
| M2 | Real counts: `N`, total active balance, `A` per epoch, attestation structure after EIP-7549 | a public beacon API, small JSON replies only | network only |
| M3 | The full guest on one real epoch, in execute mode, to confirm `C` | the zkVM's execute mode | moderate: minutes on one core, low priority; only if M1 and M2 say it fits |
| M4 | Proving time and price per proof | a rented GPU or a prover network | **run by the owner**; exact commands handed over |
| M5 | Verification cost: Groth16 on an EVM and on Solana | a local EVM (anvil, BSC-like settings) and `solana-test-validator` | light |
| M6 | BNB Chain → Ethereum natively: EIP-2537 pairing and a storage proof | a local EVM at the Prague hardfork, with a recorded BSC vote and proof | light |
| M7 | The sync-committee fallback, for comparison | the same as M1 and M3, with 512 keys | light |

Nothing proves locally. Builds run at low priority with two jobs, and one heavy job runs at a time (the owner asked
on 2026-09-30 that the Mac not be put under too much pressure).

## Choice of zkVM for P1

SP1 (Succinct) is the choice for P1:
- it has BLS12-381 and SHA-256 precompiles;
- it has an execute mode that counts cycles without proving;
- it has a Groth16 wrap with an existing Solidity verifier, and a Solana verifier crate.

Stage B needs a second, independent system for P2, a different zkVM from a different team. That one is chosen only if
P1 passes.

## Output

The results go in `design/2026-09-30-proving-prototype.md`, this file, under a section added when the measurements are
in: each threshold with its measured value and pass or miss, the model's inputs, and the owner's run.

## Results so far (2026-09-30)

### M2: mainnet counts, finalized epoch 478,995

| Count | Value |
|---|---|
| Active validators `N` | **883,045**, in 2,048 committees of 431 to 432 (64 a slot) |
| Aggregates carrying a slot's votes | One per slot spans all 64 committees with about **27,500 of 27,600 attesters (99.6%)**, since EIP-7549; a few small ones straggle behind it |
| Aggregates a checkpoint's supermajority needs, `A` | about **32** an epoch, so about 64 for the two epochs of the finality rule |
| Key additions `N · c_add` | about **880,000** an epoch |

### M1: zkVM cost of each primitive (SP1 6.8.1, execute mode)

"Prover gas" is SP1's own measure of proving work: its instruction count plus what each precompile costs to prove,
scaled so that equal gas means about equal GPU time. The prover network prices proofs in it.

| Primitive | Instructions | Prover gas |
|---|---|---|
| SHA-256 compression (precompile) | 250 | 835 |
| Adding a public key to an aggregate (G1 addition) | 3,359 | 3,338 |
| Reading a key uncompressed, no subgroup check, and adding it | 4,997 | 4,673 |
| Reading a key compressed, fully checked, and adding it | 44,780 | 46,343 |
| The swap-or-not shuffle, per index (90 rounds) | 942 | 900 |
| An aggregate signature check: hash to G2 and two pairings | 3,661,279 | 3,827,861 |

Keys from the committed validator set need no subgroup check (the set is committed, and every key in it was checked
when its validator was deposited), so they cost the uncompressed row. A fully checked read would cost ten times more.

### The cost model with measured inputs

Per proof of one checkpoint's finality, under the full two-epoch rule:

| Part | Count | Prover gas |
|---|---|---|
| Read the committed set and re-hash its commitment (keys and balances, about two compressions each) | 883,045 | ≈ 2.6B |
| Recompute two epochs' shuffles | 2 × 883,045 | ≈ 1.6B |
| Aggregate each slot's attesters' keys | 2 × ~880,000 | ≈ 5.9B |
| Check the aggregate signatures | ~64 to 80 | ≈ 0.3B |
| Committee bits and balance sums, estimated at 200 instructions per validator and epoch | 2 × 883,045 | ≈ 0.35B |
| **Total** | | **≈ 11B prover gas** |

For comparison, the sync-committee fallback checks 512 keys and one signature a slot: about 6M prover gas, about
1,800 times less, for a much weaker trust assumption.

Key aggregation dominates. Two ways to cut it, neither decided:
- **One epoch instead of two.** Honest validators vote only from a justified source, so a supermajority link from
  `C1` to its child may show `C1` justified, and so finalized, under the same honest-supermajority assumption the full
  rule rests on. That would halve the aggregation and the shuffle, to about 6.7B in total. It must be checked against
  Casper's accountable-safety argument before it is relied on, and it is flagged here, not adopted.
- **Keeping the commitment incremental.** `V` updated by churn, a few validators an epoch, would drop most of the
  2.6B re-hash; the model above already assumes a flat commitment rather than SSZ's full tree, which would cost about
  7.5B more.

### What M4 must measure

Dollars and minutes per unit of prover gas, which no published price fixes: the network runs an auction. The owner's
run proves a representative slice, the key-aggregation step alone at about 3B prover gas. Its measured seconds and
price per billion prover gas, scaled to about 11B (or about 6.7B), decide the $50 and 60-minute thresholds. The
commands are in `prototype/README.md`.

### M6: BNB Chain's finality vote, checked on Ethereum without a zkVM

At BNB Chain block 124,884,600, 20 of the 21 validators (bitset `0x1effff`) signed one aggregate BLS signature over
the vote for block 124,884,599. The scheme, checked natively with the reference library before any Solidity:
- the message is the keccak256 of the RLP-encoded vote data (source and target number and hash);
- the domain tag is Ethereum's proof-of-possession tag;
- voters are indexed in the order of the epoch header's validator list.

A vote 57 blocks after its epoch block did not verify against that epoch's set: a new set takes effect some blocks
after its epoch block, and the verifier has to follow that switch.

`prototype/evm/src/BscVoteVerifier.sol` checks the vote on the Prague EVM with the EIP-2537 precompiles:
- it sums the voters' keys;
- it hashes the vote to G2 as RFC 9380 prescribes, with SHA-256, the modexp precompile and `MAP_FP2_TO_G2`;
- it makes one pairing check.

| Measure (Prague EVM, optimizer with via-IR) | Gas |
|---|---|
| `verifyVote`, 20 voters: the recorded vote verifies; a different vote or a missing voter does not | **264,879** |
| `StorageProof.prove`: header hashed against the voted block hash, then the account proof (9 nodes) and the storage proof (7 nodes) of a real `eth_getProof` of WBNB's slot 0; a tampered node, a wrong header or another slot is refused | **212,780** |
| Calldata of the whole proof, about 10.6 KB (keys, signature, header of 896 bytes, proof nodes of 6,828 bytes) | about 150,000 |
| Transaction base | 21,000 |
| **Whole BNB Chain → Ethereum proof** | **about 650,000** |

Deposits proved against the same voted block share one vote check. The first version of the storage verifier built a
memory array of structs for every trie node and cost 418k gas; locating items in place halved it.

So the vault → Ethereum direction for BNB Chain needs **no zkVM and no trusted setup**, only the chain's own
signatures checked by Ethereum's precompiles, at about 650k gas against the 1M threshold.

**Correction, 2026-09-30.** This record first said the validator set needs an update "only when its membership changes,
at most about daily". That was wrong. BNB Chain rotates 4 to 5 of its 21 active validators at every epoch block, every
1,000 blocks or 7.5 minutes, drawing on the 45 validators elected each day: over one day of sampled epochs all 45 took
turns and none sat in every epoch. A verifier has to follow every rotation, because a vote can be checked only against
the exact set that was active, and nothing short of the previous set's vote on the next epoch block ties one set to the
next. The owner chose that on 2026-09-30 over a zk proof of the rotation chain, an optimistic scheme and trusting the
pool of 45. The cost is the set update, about 330k gas an epoch by this estimate and 192 epochs a day; the Stage B spec
carries the measured figure.

### M5: verifying the wrapped proof

A Groth16 proof has a constant size whatever it proves, so these figures hold for the full finality proof.

| Chain | Measure | Pass? |
|---|---|---|
| EVM (BNB Chain, HyperEVM; BN254 precompiles priced by EIP-1108 as on Ethereum) | **227,385 gas** to verify SP1 v6's own Groth16 fixture with the vendored `SP1VerifierGroth16` (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`); a tampered public value is refused | yes, under 1M |
| Solana | about **280,000 compute units**, published by Succinct for `sp1-solana` (README at `4181cae`); **not yet measured here**, because its example pulls in a second SP1 SDK build of about 2 GB | likely, under 1.4M |

Solana's figure can also be bounded from its own syscall prices. A Groth16 check with SP1 v6's five public inputs is:
- five scalar multiplications on BN254 at 3,840 compute units each;
- five additions at 334;
- one four-pair pairing, 36,364 for the first pair and 12,121 for each further one.

That is about 94,000 compute units before the program's own parsing, and Succinct's published 280,000 covers that
too. Either figure is a fifth or less of the 1.4M threshold.

Measuring it on chain needs Solana's program-test runtime, another multi-gigabyte build. That is too heavy for this
machine now (the owner's rule on load), so it moves to the Solana vault's own build in Stage B, which needs that
toolchain anyway.

### Where Phase 2 stands

| Threshold | Status |
|---|---|
| Verify ≤ 1M gas on BNB Chain | **passes**: 227k gas measured |
| Verify ≤ 1.4M CU on Solana | passes on paper: about 94k CU from Solana's syscall prices, 280k published; measured with the Solana vault |
| ≤ $50 per proof | open: about 11B prover gas (6.7B with one epoch), priced by the owner's M4 run |
| ≤ 60 minutes end to end | open: Ethereum's finality (about 13 min) plus the proving time from M4 |

The vault → Ethereum direction for BNB Chain needs no zkVM at all (M6): about 650k gas a proof, measured.

## M3 on real data: the full P1 statement in execute mode (1 October 2026)

`proofs/p1-input` built a real input from mainnet, and `p1 execute` ran the whole statement of the Stage B spec's
section 10 on it, without proving:

| Input | Value |
|---|---|
| Anchor | epoch 479,099, a registry of 2,375,541 validators, exited ones included |
| C1 | epoch 479,101, finalized by 149 and 170 real aggregates |
| Signers counted | 1,051,438 into C1 and 964,758 out of it |
| Execution headers | 63 |

| Result | Value |
|---|---|
| Instructions | 68.5 billion |
| Prover gas | **92.9 billion**, against the model's 11 billion |
| Execute time | 571 s on two threads |
| Public values | equal to the native run's |

Where the model went wrong:
- **The registry.** The statement re-hashes the whole SSZ registry to check it against the anchor, and the registry holds
  2.4 million validators, not the 0.9 million active ones the model counted. Each validator costs about 8 SHA-256 hashes,
  and SSZ's 64-byte hashes take two compressions each.
- **The keys.** Each signer's key is read and checked once per link, so about 2 million times.
- **The input.** Its 560 MB, mostly the registry, is read into the zkVM.

The cuts, in order of risk:
1. Read each signer's key once for both links, and pass keys only for signers.
2. Pass an exited validator's record as the few leaves the statement needs, with the rest as subtree hashes.
3. Replace the SSZ registry root in the anchor with a cheaper commitment kept up by the proofs, as the model assumed. That
   changes the statement's security argument and needs review.

The $50 threshold now depends on the price of a billion prover gas, which M4 measures.

## One-epoch finality: the argument, for review

The full rule proves two epochs' supermajorities: one justifying `C1`, one linking `C1` to its child `C2`. The
cheaper statement proves only the second: two thirds of the stake signed attestations with source `C1` and target
`C2`, where `C2` is `C1`'s direct child.

**The argument.** Assume, as the full rule does, that less than a third of the stake is faulty.
1. Then more than a third of the stake among the link's signers is honest.
2. An honest validator attests with its state's current justified checkpoint as the source. The protocol enforces
   this too: `process_attestation` includes an attestation only if its source equals the including state's current or
   previous justified checkpoint.
3. So `C1` was justified in some honest validator's view. That means two thirds of the stake signed target votes for
   `C1` from a justified source, as signed messages that exist whether or not we check them.
4. `C1` is therefore justified in Casper's sense, and the link `C1 → C2` finalizes it. Accountable safety carries
   over: a conflicting finalized checkpoint still needs a third of the stake to be slashable.

The one step not checked cryptographically is step 2, honest behaviour. It fails only if every signer of the link is
faulty, which means two thirds faulty, and then the full rule fails as well.

**What to check before relying on it:**
- The argument, by someone who knows Casper's safety proof.
- That the prover chooses epochs with a direct-child link; finality through the rule's two-epoch-old sources is left
  out, which only skips some finalizations.
- That the committee shuffle and the balances are those of `C2`'s epoch.

If it holds, the proof costs about 6.7B prover gas instead of 11B. It is not adopted.
