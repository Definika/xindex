# Proving the Solana vault's state on Ethereum under Alpenglow (research, 3 October 2026)

Stage B spec, section 8, sketches how Ethereum could learn what the Solana vault holds once Alpenglow is live. This
document reads Alpenglow as it runs, from the source and from devnet, and turns the sketch into a build plan. The
prototype is `proofs/solana-state` (plain Rust, tested natively, no zkVM yet).

## Verdict

- **The formats are known and the certificate path is proven on real data.** A real Alpenglow certificate, devnet's
  genesis certificate, verifies under the prototype's code, with Ethereum's own BLS ciphersuite. That confirms the
  signed payload, the encodings and the bitmap. The bank hash, the lattice hash and the block id follow Agave's code
  exactly and are pinned against Agave's own vectors and its published crate.
- **It cannot be proven end to end with public infrastructure.** Public RPC serves none of a proof's inputs, the
  genesis certificate excepted: no block id, no block footer, no bank hash, no lattice hash, no finalization
  certificate, and no record of a slot's account writes. A prover must run its own Agave node and extract them.
- **It is buildable now against devnet**, which runs Agave 4.4.0-beta.0 with Alpenglow since slot 504,148,999 (25
  September). Mainnet waits for Agave 4.3, targeted for October 2026 with no date. The formats that matter are the same
  in 4.3.0 and 4.4.0-beta.0: the diffs between them are refactors.
- **It is weaker than the BNB verifier.** Forging a finalization takes 60% of the epoch's stake, and Alpenglow has no
  slashing, so such a coalition loses nothing. That is TRON's kind of trust, with Solana's larger set. On devnet the set
  is 19 keys.
- **Effort:** about three to four weeks of engineering, plus a node, plus an outside review of a new soundness argument.
  It is not a hackathon item. The spec's section 8 holds with the five corrections in "Where section 8 changes".

## Sources

| What | Version | Where |
|---|---|---|
| Agave, as mainnet's Alpenglow will ship | v4.3.0, commit `825efd18292aff6ffcf9daa0f7612f21b3531a72` | github.com/anza-xyz/agave |
| Agave, as devnet runs it (`getVersion`: 4.4.0-beta.0) | v4.4.0-beta.0, commit `98535e50e9bb38574e6b0c31ff284cd864d3ca88` | same |
| BLS | solana-bls-signatures 3.4.0 (Agave 4.3), 4.0.0 (4.4) | crates.io |
| Signer bitmaps | solana-signer-store 0.1.0 | crates.io |
| Hard forks | solana-hard-forks 3.2.0 | crates.io |
| Devnet data | `proofs/solana-state/fixtures/devnet.json`, by `fetch_devnet.py` | api.devnet.solana.com, 3 October 2026 |

Line numbers below are v4.4.0-beta.0's. Every format cited is unchanged in v4.3.0.

## 1. What Alpenglow signs, and by whom

**Votes and certificates** (`votor-messages/src/vote.rs`, `certificate.rs`, `wire.rs`):
- **A vote's signed bytes** (`VotePayloadToSign`, `wire.rs:424`; `get_vote_payload_to_sign`, `:553`) are wincode,
  fixed little-endian:
  - a tag byte: 1 notarize, 2 finalize, 3 skip, 4 notarize-fallback, 5 skip-fallback, 6 genesis;
  - then the slot (u64), and for a vote on a block, the block id (32 bytes);
  - then the cluster's **shred version** (u16).

  A notarize payload is 43 bytes; a finalize payload is 11.
- **A finalize vote names a slot only.** The block comes from the notarize certificate beside it.
- **Thresholds** (`certificate.rs:113`, `migration.rs:88`): finalize, notarize and skip need 60%; fast finalize needs
  80% of notarize votes; genesis needs 82%. Each is `signed * 100 >= total * pct` (`fraction.rs`).
- **Finality** (`runtime/src/validated_block_finalization.rs:88`, `try_from_footer`): a block `(slot, block_id)` is
  final on either:
  - slow: a finalize certificate for the slot plus a notarize certificate for the block, each at 60%;
  - fast: one notarize aggregate at 80% (`FinalizeFast`).

  Base3 bitmaps, which mix vote kinds, are refused for finality.
- **The bitmap** (solana-signer-store `lib.rs:184`): a version byte (0 for Base2), the bit count (u16 LE), then the
  bits, least significant first. Bit `r` is rank `r`.

**The ciphersuite** (solana-bls-signatures `hash.rs:11`):
- It is Ethereum's: `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, keys in G1 (48 bytes compressed), signatures in G2
  (96 bytes compressed, 192 uncompressed).
- Keys carry a proof of possession, checked by the vote program when registered (`programs/vote/src/vote_state/mod.rs:1033`,
  message `"ALPENGLOW" ++ vote account`).
- This is the suite `src/libraries/Bls12381.sol` already checks for BNB Chain on EIP-2537, and `proofs/finality/src/bls.rs`
  in a zkVM.

**The ranked set** (`runtime/src/epoch_stakes.rs:68`, `BLSPubkeyToRankMap::new`):
- **Which epoch:** a certificate for a slot in epoch `E` is checked against `epoch_stakes[E]` (`bank.rs:2543`,
  `epoch_stakes_from_slot`; `:6068`, `verify_certificate`).
- **When it is snapshotted:** `epoch_stakes[E]` is taken at the first bank of epoch `E-1`, as the leader-schedule
  epoch's stakes (`bank.rs:2766`, `update_epoch_stakes`).
- **How it is filtered:** the snapshot is VAT-filtered (SIMD-0357; `vote/src/vote_account.rs:212`):
  - only vote accounts with a BLS key, non-zero stake, and at least the admission balance (net of pending delegator
    rewards) enter;
  - beyond `MAX_ALPENGLOW_VOTE_ACCOUNTS` (2,000, `bank.rs:262`), every account with stake at or below the 2,001st's is
    dropped, ties included.
- **The rank map:**
  - it drops every account whose BLS key or node key another account shares;
  - it ranks the rest by stake, highest first, then by compressed BLS key, ascending (`epoch_stakes.rs:110`);
  - its **total is the remaining accounts' stake only**, not the epoch's total.
- **Keys change at once.** `VoterWithBLS` writes the new key into the vote account immediately (`handler.rs:106`), but
  the rank map keeps the snapshot's copy. At most one re-key per epoch is possible (`handler.rs:98`,
  `TooSoonToReauthorize`).

**Stakes from a program** (`syscalls/src/lib.rs`, `SyscallGetEpochStake`; `bank.rs:6948`):
- `sol_get_epoch_stake(vote)` returns that account's stake in `current_epoch_stakes()`, which is `epoch_stakes[E]`
  while the bank is in epoch `E-1` (`bank.rs:6054`). With a null address, it returns the total.
- So a program running during epoch `E-1` reads exactly the stakes epoch `E`'s certificates are checked against, and
  can check it listed them all: the listed stakes sum to the total.

**Where the keys are provable.** At that same first bank of epoch `E-1`, right after the snapshot,
`maybe_burn_vat_from_staked_accounts` (`bank.rs:2797`, `:2820`) debits the VAT from **every** member's vote account and
stores it. No transaction has run between the snapshot and the burn. So the first slot of each epoch writes every
member of the next epoch's set, with exactly the BLS key and node key the snapshot holds.

## 2. From a final block to an account

**The block id** (`ledger/src/blockstore.rs:2031`, `build_double_merkle_tree`; `:3722`, `get_block_id`):
- It is a "double Merkle root".
- **Leaves:** each FEC set's shred Merkle root, then `sha256(parent_slot ++ parent_block_id ++ fec_set_count (u32))`.
- **Nodes:** `sha256("\x01SOLANA_MERKLE_SHREDS_NODE" ++ left[..20] ++ right[..20])`, an odd layer's last node joined
  with itself (`ledger/src/shred/merkle_tree.rs:18`, `:111`).
- **A shred's leaf:** `sha256("\x00SOLANA_MERKLE_SHREDS_LEAF" ++ its signed bytes)`.
- Nodes are 20 bytes, so a second preimage costs 2^160.

**The footer** (`entry/src/block_component.rs:241`, `BlockFooterV1`):
- It is the block's last component. It carries the block's own **bank hash**, filled in after the bank freezes
  (`core/src/block_creation_loop.rs:544`, `:846`) and checked by every replaying validator
  (`runtime/src/block_component_processor.rs:584`, `:784`).
- It is part of the block's data, so the block id commits to it.
- It also carries a `block_final_cert` (`:300`): the finalization certificate of an earlier block, kept for rewards.
  Certificates therefore exist inside later blocks' shreds.

**The bank hash** (`runtime/src/bank.rs:5609`, `hash_internal_state`):
- `sha256(sha256(parent_bank_hash ++ signature_count (u64 LE) ++ last_blockhash) ++ accounts_lt_hash)`, where the
  lattice hash enters as all 2,048 bytes.
- It is hashed once more with the hard-fork count when a hard fork lies in `(parent_slot, slot]` (solana-hard-forks
  3.2.0, `get_hash_data`).
- So a bank hash opens to exactly one lattice hash, and to its parent's bank hash, which opens to the parent's lattice
  hash.

**The lattice hash** (SIMD-0215):
- `LtHash` is 1,024 `u16`s, combined by wrapping addition (`lattice-hash/src/lt_hash.rs:12`).
- An account's LtHash is BLAKE3's XOF, 2,048 bytes read as little-endian `u16`s, over
  `lamports (u64 LE) ++ data ++ executable (u8) ++ owner ++ pubkey`. A zero-lamport account's is the identity
  (`accounts-db/src/accounts_db.rs:3429`).
- At freeze, the bank mixes each written account's old state out and its new state in
  (`runtime/src/bank/accounts_lt_hash.rs:359`).
- Freeze also writes sysvars, fees and the incinerator (`bank.rs:3244`), and Alpenglow's footer processing writes vote
  accounts. All of these are in the slot's writes.

**So, to prove "account A held state S after slot s":**
1. Show that `(s, block_id)` is final, by certificates under epoch `epoch(s)`'s set.
2. Prove the footer's bytes into `block_id` and read the bank hash.
3. Open the bank hash and its parent's.
4. Show that the parent's lattice hash, with the slot's complete write list, gives the slot's.
5. Read A's new state from that list.

This proves only accounts **written in slot s**, which is why the vault needs `attest` (section 5).

## 3. What a prover can get (devnet, 3 October 2026)

| Input | Public RPC | Where it exists |
|---|---|---|
| Genesis certificate | `getAgGenesisCert` (`rpc/src/rpc.rs:932`) | served |
| A block's id, footer, bank hash | no method (`getBlock` returns only blockhash, parent, height, time) | the node's blockstore (shreds); repair serves double-Merkle proofs |
| Finalization certificates | no method | inside later blocks' footers; the node's consensus pool |
| The parent's lattice hash | no method | snapshots store it whole; replay advances it |
| Every account write of a slot, old and new | no method | `agave-ledger-tool verify --record-slots` (`ledger-tool/src/main.rs:625`) records each slot's written accounts with the bank-hash components (`runtime/src/bank/bank_hash_details.rs:102`); old states come from the parent bank |
| The shred version | `getClusterNodes` (7016 on devnet) | served |
| Vote accounts, BLS keys, current stakes | `getVoteAccounts`, `getMultipleAccounts` | served (25 accounts, 19 with BLS keys) |

The probes are recorded in `fixtures/devnet.json`.

**Verdict.** A prover needs its own non-voting Agave node with the ledger. It also needs a small extraction tool,
probably a ledger-tool subcommand or a Geyser plugin, that emits for a chosen slot:
- the parent's full lattice hash;
- every write, old and new;
- the block's shreds and Merkle proofs;
- a later footer's certificate.

**Size and cost:**
- Devnet traffic is light: 12 to 37 transactions and 52 to 158 written accounts per slot, sampled in `devnet.json`, plus
  the runtime's writes.
- Mainnet is not measured. It is likely thousands of written accounts per slot.
- The epoch's first slot writes every member's vote account: 2,000 at most, each 3,731 to 3,762 bytes on devnet today.
- A devnet node costs a few hundred dollars a month; a mainnet RPC-class node with 512 GB of RAM about $1,000 to $1,500 a
  month. Both are estimates, not quotes.

## 4. Soundness, link by link

1. **Certificates.**
   - **Claim:** 60% of the set's stake (80% for fast finality) signs.
   - **Assumption:** no coalition of 60% signs a block the cluster did not finalize.
   - **Alpenglow has no slashing** (no slashing code in `votor`, Agave 4.3 or 4.4), so a coalition that did would
     lose nothing. That is weaker than the BNB verifier, where conflicting finality votes are slashable, and like
     TRON's 19 of 27 producers. Alpenglow's own safety assumes under 20% byzantine stake.
   - The shred version, part of every signed payload, is a parameter the verifier must hold, and it changes when the
     cluster restarts from a hard fork.
2. **The set.**
   - A **registry program** running during epoch `E-1` records every member's stake by `sol_get_epoch_stake`, and
     refuses to close unless the listed stakes sum to the total. That makes the list complete, not chosen.
   - Members, keys and node keys come from the **epoch's first slot's** VAT-burn writes, proven like any slot. That
     makes them the snapshot's, even if a validator re-keys during `E-1`. A registry that read keys later would hold
     the wrong key for any validator that re-keyed after the snapshot. Every certificate that validator signed would
     then fail to verify: a liveness failure that any validator could trigger at will.
   - The statement then applies Agave's exclusions (shared BLS or node keys) and ordering, and verifies against that
     total.
   - **The chain of sets:** a set is anchored at deployment, as the BNB verifier's first set is. Each next set is
     accepted only from blocks the current set finalized: the registry's write slot, and the epoch's first slot.
3. **Block id to footer.**
   - The shred and double-Merkle paths give 160-bit second-preimage security.
   - **Open:** exactly which bytes of the last FEC set are the footer. The footer is the final `BlockMarker`
     component, with the last data shred flagged `LAST_SHRED_IN_SLOT`. The framing of components across data shreds
     must be written down from `ledger/src/shred` and tested on real shreds before the statement relies on it, so that
     no footer-shaped bytes inside a transaction can pass for the footer.
4. **The bank hash.** SHA-256 over the whole lattice hash; the hard-fork count is supplied and checked against a
   hard-fork list the verifier holds.
5. **The delta.**
   - The write list is the prover's. Soundness rests on LtHash's collision resistance: no list other than the real
     one, with each address once, gives the same difference.
   - That is a k-sum problem over (Z/2^16)^1024: Lewi et al., "Securing Update Propagation with Homomorphic Hashing"
     (2019), the construction SIMD-0215 adopted. Generalized-birthday attacks are far out of reach at this size.
   - This composition, "the delta of a finalized bank hash proves an account's write", is **new and unpublished** and
     needs the outside review the spec already asks for.
6. **Lag.**
   - Sets must be followed every epoch: 432,000 slots, about two days at 400 ms.
   - As the BNB verifier and, since LG-4, P1 and P2 do, the verifier must refuse a block older than `MAX_LAG` by its
     footer's producer time, and stop for good if left behind. Old stake that has since left could otherwise sign the
     past.

## 5. How it plugs into the contracts

The hub asks `IVaultStateVerifier.verifySlots(account, slots, proof)` for EVM-style storage slots of the vault:
- one slot to settle an order: the intake digest, `keccak256(intakeId . keccak256(index . 15))`;
- the index digest for `reportOutflow`: `keccak256(index . 14)`;
- slot 25, the snapshot root, for `recordExit`;
- since LG-5, a claim's slot **and** slot 25, from one state.

A Solana state verifier on Ethereum maps them so:

| Slot asked | Preimage in the proof | Solana account (vault program) | Field |
|---|---|---|---|
| intake digest | `(index, intakeId)`, rehashed and compared | PDA `["intake", index, intake_id]` | `Intake.digest` |
| index digest | `index` | PDA `["index", index]` | `IndexState.digest` |
| 25 | none | PDA `["config"]` | `Config.snapshot.state_root` |

An account the slot did not write cannot be read this way. The vault program therefore needs:
- **`attest(index, intake_id)`**: anyone, any time. It writes the intake account, the index's account and `Config`,
  for example by bumping an attest counter that no digest covers. So one slot's delta holds every account any
  `verifySlots` call can ask for, and evidence's two slots come from one state, as LG-5 requires.
  - An attest after an intake's deadline proves its final deposits.
  - The digests stay byte for byte the EVM vault's, so the twin rules hold.
  - The EVM vault's `attest(slots, values)` is a view for TRON, while Solana's writes. That difference belongs in the
    twin rules' record.
- **The timestamp** returned is the slot's `Clock` sysvar, which every slot writes. The block number returned is the
  slot.

The statement's public values would be: the set commitment in and out, the vault program and `Config` keys, the shred
version, the slot, its time, and the proven `(kind, preimage, value)` triples. The Ethereum contract recomputes each
requested slot key from its preimage and returns the values in request order.

## 6. Build plan

| # | Component | Size | Effort |
|---|---|---|---|
| 1 | Extraction tool on a devnet node: shreds, proofs and a later footer's certificate; the parent's lattice hash; every write, old and new | Rust, ledger-tool subcommand or Geyser plugin | 3–5 days, plus the node |
| 2 | Shred framing: the footer's bytes from the last FEC set, tested on real devnet shreds | Rust, in this crate | 2–3 days |
| 3 | The statement: certificates under a set; block id; footer; two bank-hash openings; the delta; field reads; the epoch transition (registry record and first-slot keys) | this crate, extended | 4–6 days |
| 4 | Registry program on Solana: `record(vote accounts…)` by `sol_get_epoch_stake`, closed when the sum meets the total, once per epoch by keepers | Anchor | 2 days |
| 5 | `attest` on the vault program | Anchor, plus twin docs | 1 day |
| 6 | zkVM program (SP1, as P1) and its host; cost measured on real slots | SP1 | 2–3 days |
| 7 | `SolanaStateVerifier.sol`: the SP1 proof, the set chain and its anchor, `MAX_LAG`, the shred version and hard forks, slot mapping by preimage | Solidity, near `TronStateVerifier`'s size | 3 days |
| 8 | Outside review of the delta argument and the set derivation | external | — |

**Order:** 1, then 2 and 3 together; 4 and 5 can run in parallel; then 6 and 7.

**Cost to prove:**
- Natively, 3,000 writes of 165 bytes take 10 ms, 216,000 BLAKE3 compressions (`tests/state.rs`, `measure_a_slot`).
- Neither zkVM accelerates BLAKE3. At roughly 1,500 cycles a compression, that is about 0.3 billion cycles for such a
  slot, before certificates. Each certificate costs two pairings plus a G1 sum over up to 2,000 keys.
- A devnet slot is about a tenth of that. The spec's 0.5 to 3 billion prover gas stands as an estimate. Real numbers
  wait on component 6.

## 7. Risks

- **No slashing:** a 60% coalition forges for free (section 4.1). It needs labelling, as TRON's 19 producers are.
- **Formats move:** Alpenglow is weeks old on devnet, and 4.4 is a beta. The vote payload, the footer and the VAT rule
  could change before or after mainnet. Each change is a new zkVM program, so a rotation (30 days).
- **Data availability:** proving depends on running and keeping a node. If the extraction falls behind, the
  epoch-following lag stops the verifier for good, as with the BNB verifier.
- **Cluster restarts:** a hard fork changes the shred version and the bank hash's extension. The verifier must learn
  both behind a delay, or stop.
- **Mainnet scale:** a heavy slot, many large accounts or a 2,000-member epoch boundary could push one proof past the
  prover's limits. The `attest` slot can be chosen; the epoch's first slot cannot.

## Where section 8 changes

1. "Finalization certificates are BLS12-381 aggregates over a block id": only fast finality's. Slow finality pairs a
   finalize certificate over the **slot** with a notarize certificate over the block. Every payload also carries the
   cluster's shred version.
2. "A small registry program records each epoch's stakes and BLS keys": stakes yes, by `sol_get_epoch_stake`, checked
   complete against the total. Keys no: they must come from the epoch's first slot, whose VAT burn writes every
   member, because a key read later can postdate the snapshot. The set is also VAT-filtered (SIMD-0357), and Agave's
   duplicate exclusions and ordering must be replicated.
3. "The vault gains an attest that seals an intake": it must also write the index's account and `Config`, so that the
   two slots LG-5's evidence reads come from one state.
4. **New:** a prover must run its own node. Public RPC serves none of the inputs.
5. **New:** Alpenglow has no slashing, so the trust is 60% of stake with nothing at risk.

The prototype's tests (`cargo test` in `proofs/solana-state`):
- `devnets_genesis_certificate_verifies` and `the_certificate_signs_nothing_else`: devnet's genesis certificate,
  11 of 17 ranks, verified under the found signer set, and refused for any other payload or set;
- `the_rank_map_is_agaves`;
- `bitmaps`;
- `finality_slow_and_fast`;
- `agaves_lattice_hash_vectors` and `as_agaves_crate_computes_it`: the lattice hash against Agave's vectors and its
  4.3.0 crate;
- `the_bank_hash_is_agaves_formula`;
- `the_slot_proves_the_intake_it_wrote` and `the_slot_proves_nothing_else`;
- `the_block_id`.
