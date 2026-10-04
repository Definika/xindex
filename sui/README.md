# Xindex vault on Sui

The Sui twin of `src/vault/XindexVault.sol` and of the Solana, NEAR and Stellar vaults, with P1 and P2, Ethereum light
clients, in the same Move package. It holds SUI for every index whose shares live on Ethereum. Coins enter only as
deposits to an intake. They leave only on messages that P1 (SP1) and P2 (RISC Zero) prove final on Ethereum, within the
4%-a-day speed limit. Ethereum learns the vault's state through `attest`, whose `Attestation` object
`SuiStateVerifier` reads from a certified checkpoint. The chain ids, the vault id, the recipient encoding, the slot map
and the `Attestation` object are fixed in `design/2026-10-04-four-chains-interfaces.md`.

Status: built and tested on Sui's Move unit-test runner (CLI 1.80.1, framework at the `Move.lock` revision). Not
published anywhere.

## Build and test

Only `sui move build` and `sui move test` are needed. The CLI asks for a client configuration even to build; give it a
throwaway directory with a keyless `client.yaml` (an empty keystore, no active address), and never let it generate a
key. The CLI fetches the Sui framework from GitHub at the revision `Move.lock` pins.

```bash
cd sui
sui move build                 # no warnings; one lint is allowed, with its reason (`refund`'s transfer to its caller)
sui move test                  # 326 tests
sui move test --coverage && sui move coverage summary
sui move test gas_ --statistics   # the gas pairs below
```

The fixtures are generated, never edited (from the repository root, with foundry):

```bash
python3 sui/tests/fixtures/generate.py   # hub.json: a real hub's storage on a local anvil (nothing leaves the machine)
python3 sui/tests/fixtures/vectors.py    # tests/fixtures.move and test/fixtures/sui/vault-attest.json
forge test --match-path 'test/SuiStateVerifier*'   # the Solidity side checks vault-attest.json
```

## Layout

| Module | What |
|---|---|
| `vault` | The vault: the shared `Vault` object, every rule, the `Attestation` object and `attest`. |
| `light_client` | P1 and P2: `LightClient`, a shared object per light client, the twin of `FinalityVerifier.sol`. |
| `proofs` | SP1 v6's and RISC Zero v3.0's Groth16 checks on `sui::groth16` (BN254), from the EVM encodings. |
| `ethereum` | The headers tree, an event proof's and a checkpoint proof's format, a receipt's log. |
| `rlp`, `mpt` | RLP read in place, Merkle-Patricia proofs (absence included). |
| `state_reader` | An account's storage under a state root, from `eth_getProof`. |
| `snapshot` | The hub slots a snapshot claim reads, a holder's share, its EIP-712 digest and signature. |
| `abi` | `VaultMessages`, the index and intake digests, the log data, CREATE2, `attest`'s record. |
| `bytes` | Big-endian words and byte slices. |

The proof formats are the Rust core's (`crates/xindex-core`), byte for byte: an event proof is `headersRoot ++ number
(u64 LE) ++ timestamp (u64 LE) ++ stateRoot ++ receiptsRoot ++ path count (u8) ++ path ++ node count (u8) ++ (length
(u32 LE) ++ node) * count ++ txIndex (u32 LE) ++ logIndex (u32 LE)`; a checkpoint proof is the header part alone; a
state proof is the account's node list, then one per slot. A relayer builds them as it builds the NEAR and Stellar ones.

## Functions

Every function is `public`, so a programmable transaction composes them. Anyone may call every one but the role-gated
ones (the freezer, the recovery proposer), which check the transaction's sender.

| Function | What it does |
|---|---|
| `light_client::new(system, key, anchor, epoch, genesis_time)` + `share` | A light client: 1 SP1 (P1) or 2 RISC Zero (P2), its program key or image id, the anchor and epoch it starts from. |
| `light_client::update(lc, public_values, proof, clock)` | Advances it with a proof from its anchor, until a day after the anchor's epoch began (LG-4). |
| `vault::create(source, chain, factory, template, p1, p2, freezer, recovery, cap, floor, clock)` | Creates and shares a vault; returns its id, the vault id Ethereum's registry names. |
| `register_index(index, salt)` | Registers a clone of the factory's `HybridHub` template, checked by the CREATE2 formula. |
| `deposit(index, intake_id, coin, clock)` | Deposits a `Coin<SUI>`. The deadline is the id's top 64 bits; within `MAX_INTAKE_LIFE`; refused over the cap, frozen or stalled. |
| `refund(index, intake_id, clock)` | The depositor takes back its deposit to a failed intake, as a coin. |
| `deliver(p1, p2, payload, block, proof1, proof2, clock)` | Runs a `VaultMessage` on P1's proof, P2's or both; an empty proof is none. |
| `release(index, id, clock)` | Pays what the speed limit now allows of an owed burn, claim or migration. |
| `freeze_vault(clock)` | Freezer only, before a snapshot: 14 days. (`freeze` is reserved in Move.) |
| `apply_change(kind, body, clock)`, `apply_rotation(body, p1, p2, clock)` | Applies a waiting cap raise or freezer change, or a rotation with the two light clients it names. |
| `cancel_change(kind)` | Freezer only: drops a waiting raise or rotation, never its own replacement. |
| `advance_checkpoint(p1, p2, block, timestamp, state_root, proof1, proof2, clock)` | A final Ethereum block both prove, newer than the last. |
| `continuity(...)` + `propose_successor(p1, p2, continuity, clock)` | Recovery proposer only, while stalled. |
| `veto_successor()`, `adopt_successor(p1, p2, block, timestamp, state_root, proof1, proof2, clock)` | The freezer's two vetoes a stall; adoption after 30 days. |
| `begin_snapshot(clock)` | 180 days into a stall: the last checkpoint becomes the snapshot; its root goes to slot 25. |
| `claim_snapshot(index, holder, component, recipient, signature, proof, clock)` | A holder's share at the snapshot, to its registered recovery address or the recipient its EIP-712 signature names. |
| `resolve_intake(index, intake_id, proof)`, `deliver_recorded(payload, proof, clock)` | After the snapshot, from the hub's `_settledIntakes` and `_sentMessages`. |
| `attest(slots, values, clock)` | Aborts unless every slot holds its value; then freezes an `Attestation` with the record. |
| Views | `vault_id`, `checkpoint`, `exit_snapshot`, `successor`, `index_state`, `intake`, `deposited`, `owed`, `used`, `slot`, `stalled`, `stall_start`, `pending`, `nonces`, and the settings. |

## The attestation

`attest` builds `abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestampMs, slots, values)`, `timestampMs` the `Clock`
(0x6) when it runs, and freezes `<package>::vault::Attestation { id, record }` in the same transaction. The struct has
`key` only, so `has_public_transfer` is false, and only `attest` packs one: a failed transaction writes no object of
this type, so a certified checkpoint holding one proves a successful `attest`. The slot map follows the EVM vault's
storage, written whenever the value changes: an intake's digest at `keccak256(abi.encode(intakeId,
keccak256(abi.encode(index, 15))))`, an index's at `keccak256(abi.encode(index, 14))`, the snapshot's root at
`bytes32(25)`; a slot never written reads zero.

`tests/vault_tests.move` makes an attestation of three slots and checks its record and its BCS (`id ++ 0xc003 ++
record`) against `test/fixtures/sui/vault-attest.json`, which `vectors.py` writes with `cast abi-encode`;
`test/SuiStateVerifier.vault.t.sol` checks that `SuiStateVerifier.attestRecord` writes the same record for Sui
testnet's id and this vault's id, and proves it end to end from a checkpoint a test committee certifies.

A programmable transaction may run `attest` between two other calls, so a record shows the vault's state at some point
of a transaction that ran at its `Clock` time. Several transactions of one consensus commit share that time, so the
vault's states at one time may already differ on NEAR and Stellar; the hub's rules on attested states take that as
given (deposits are proven only after their deadline, any different proof of an intake voids the order).

## Ownerless and immutable

- **Publish and make immutable in one transaction.** The publish command returns the package's `UpgradeCap`; the same
  programmable transaction passes it to `sui::package::make_immutable`, which destroys it. Nobody can upgrade the code
  after that. Check on chain that the package's `UpgradeCap` is gone (`tests/immutable_tests.move` runs that flow).
- **No capability.** The package has no `init`, no capability type, no one-time witness and no `Publisher`: nothing is
  created at publication. `Vault`, `LightClient` and `Attestation` have `key` only, so nothing outside this package
  can wrap or transfer them, and none can be deleted.
- **Creation.** A second transaction creates P1 and P2 (`light_client::new`, then `share`) and the vault
  (`vault::create`), which refuses what `DeployVault` refuses where Move can see it: a source chain other than Ethereum
  (1) or Sepolia, a chain id not Sui's for it (`sui:mainnet` for Ethereum, `sui:testnet` for Sepolia), a missing
  factory or template, P1 not an SP1 client or P2 not a RISC Zero one, either not of the source chain's beacon genesis,
  either past its lag, a missing, equal or creating-key freezer or recovery proposer, and a floor above the cap.
- **What Move cannot check.** That the recovery proposer is the owner's emergency multisig: a Sui multisig address is
  the hash of its keys and threshold, indistinguishable from one key's. Before Ethereum's registry names the vault,
  check off chain that the recovery proposer address is derived from the published multisig (at least three of five)
  and that the freezer is the guardian's key; and that P1's key is `p1 vkey`'s program key and P2's `p2 image-id`'s.
- Sui's validators can still change any object by a protocol upgrade or a coordinated decision; no contract can remove
  that power.

## How it differs from the EVM vault

- **P1 and P2 are objects of this package.** Each light client is a shared `LightClient`, named by its object id, as
  the EVM vault names a verifier by its address; every call that proves something passes both in, and the vault checks
  their ids. A `VERIFIER_ROTATION` names two object ids; `apply_rotation` takes the two objects, which must be one SP1
  and one RISC Zero client. Their code is this package's, which nobody can upgrade, so SOL-2 (an upgradable verifier)
  cannot arise.
- **Groth16 on Sui's native BN254.** `sui::groth16` checks `e(A, B) = e(alpha, beta) e(L, gamma) e(C, delta)` on
  arkworks' compressed encodings. `proofs` compresses the EVM's points (x, then y's sign) and negates SP1's negated
  key back. The prepared keys are constants, which the tests rebuild from the Solidity verifiers' own constants. A
  point is checked to be canonical but not to lie on the curve, since compression drops y: a proof whose y is not the
  curve's is read as the one with the curve's y, the same statement. Groth16 proofs are malleable anyway, and nothing
  keys on a proof's bytes.
- **Time is the `Clock`**, in seconds for every rule (rounded down, as the verifier rounds the record's milliseconds),
  and in milliseconds in the record. Sui's clock is the consensus commit's time, with no drift to bound (SOL-10).
- **Amounts are MIST, `u64`**; an amount from Ethereum past 64 bits is refused (`abi::EOverflow`), as on Solana. A
  snapshot share takes `shares × units` in 256 bits, as Solidity does.
- **Coins are a `Balance<SUI>` in the vault**, which only this module splits, so `held` always equals it (the tests
  check it after every step). SUI sent to the vault's address as a coin or to its address balance is stranded: nothing
  here receives it, and it counts nowhere.
- **Payouts are coins transferred to a 32-byte address**, which never fail: no callback and no owed-again path, unlike
  NEAR's, and no rent minimum, unlike Solana's (SOL-5). A burn's or claim's recipient may not be zero or the vault's
  own object (SOL-9): a coin sent there would be stranded.
- **The freezer and the recovery proposer are addresses**, checked against the transaction's sender. A freezer change's
  body is a 32-byte Sui address.
- **Refusals are abort codes**, each module numbering its own from a base: `vault` 1 to 53, `bytes` 1 and 2, `rlp` 101,
  `mpt` 111, `ethereum` 121 to 127, `light_client` 131 to 138, `state_reader` 141, `proofs` 151 to 156, `snapshot` 161
  to 165, `abi` 201 and 202. A malformed proof aborts where it is found malformed (an RLP item, a node, a receipt), as
  the EVM's do, rather than under one name. A signature whose `r` is no point's x-coordinate aborts in
  `sui::ecdsa_k1`'s recovery with its own code.
- **Storage is paid by whoever adds it**, as every Sui transaction pays its storage; nothing is ever deleted, so a
  message's used mark lasts.

## Tests

`sui move test` runs 326 tests; instruction coverage is 95% (`sui move coverage summary`), the rest being abort
branches of bounds checks no caller reaches and views. They run on:

- **Real proofs.** SP1 v6's own Groth16 fixture and RISC Zero v3.0's own receipt, both verified by `sui::groth16`;
  every refusal (another value, program, image, point, selector, length, exit code, vk root, a coordinate or input past
  its field, `-A`).
- **Real receipts.** Block 26,092,387's receipts trie (`test/fixtures/ethereum/receipts.json`): a one-byte key, a
  two-byte key and a legacy receipt, and a failed transaction, an absent receipt, a one-topic log and a malformed
  receipt, each refused.
- **A real hub.** `tests/fixtures/hub.json`: the repository's factory and hub on anvil, with Sui testnet's registry id
  and this vault's id (the shared object the tests create, deterministic in `sui::test_scenario`): two holders, one
  signing its claim with its Ethereum key and one with a recovery address on Sui, a settled and an open intake, a burn
  and a migration in flight, and storage past the components array filled as an attacker would (VLT-1).
- **Solidity's encodings.** Messages, log data, digests, slot keys, the vault token's id, CREATE2 and `attest`'s
  record, against `cast abi-encode` and `cast keccak` (`vectors.py`).

Tests named after findings:

| Test | Checks |
|---|---|
| `test_vlt1_another_component_is_refused`, `test_vlt1_the_slot_past_the_end_is_refused`, `test_vlt1_storage_past_the_end_is_refused` | A claim reads only inside the hub's components array, and only SUI there, on a real hub's storage. |
| `test_vlt2_*` (eleven) | Loosening governance needs both proofs and waits `GOVERNANCE_DELAY`; the freezer may cancel it but not its own replacement, and a freeze holds every change but that one. |
| `test_vlt3_a_message_after_the_checkpoint_waits_for_it`, `test_vlt3_a_message_runs_once_its_block_is_checkpointed` | A message moving coins waits for the checkpoint. |
| `test_vlt4_one_proof_moves_no_mark`, `test_vlt4_an_older_message_is_stale`, `test_vlt4_the_same_nonce_is_stale`, `test_sol3_an_older_freezer_change_cannot_undo_a_newer_one` | Only a message on both proofs moves a nonce mark; an older message cannot undo a newer one. |
| `test_vlt5_the_freezer_cannot_freeze_after_the_snapshot`, `test_vlt5_the_factory_cannot_freeze_after_the_snapshot`, `test_vlt5_no_message_from_after_the_snapshot` | No freeze and no later message after the snapshot. |
| `test_lg1_a_message_sent_again_runs_once`, `test_lg1_a_resent_message_runs_from_its_new_block`, `test_lg1_a_receipt_with_*_kb_of_other_logs` | A message runs once by its id, from whichever block proves it first; a receipt bloated by other logs is read (sizes below). |
| `test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes`, `test_lg2_stale_checkpoints_win_no_new_veto` | A stale advance in a stall keeps the review and the veto count. |
| `test_lg3_a_one_proof_message_is_not_the_last_message` | A one-proof message cannot keep an honest successor out. |
| `test_lg4_*` (five) | The lag ends a day after the anchor's epoch; SP1's and RISC Zero's real proofs are checked at its last second and refused a second later. |
| `test_sol9_the_vault_is_no_recipient`, `test_sol9_a_claim_never_pays_the_vault` | Neither a burn nor a claim pays the vault's own object. |

Each finding's guard, and the main rules, were checked by a mutant the tests kill: VLT-1 (both checks), VLT-2 (the
delay, the freezer's own replacement, the freeze's hold), VLT-3, VLT-4, VLT-5 (the freezer's and the factory's), the
snapshot's block bound, LG-2, LG-3, LG-4 (the lag and its last second), SOL-9 (burns and claims), the speed limit's 4%
and its 24-hour window, a frozen payout, both proofs for coins, the cap's floor in `needs_both`, `attest`'s check, the
hub's sent mark, the recovery proposer, continuity (c), the G2 coordinate order and the G1 sign flag, the intake's
deadline and life, the log's emitter, the route's vault, the index digest's fields, `held`, and the stall's hold on
deposits: 34 mutants, all killed.

## Gas

Measured with `sui move test --statistics` as the difference between a test making the call and its baseline
(`tests/gas_tests.move`), in the unit-test runner's gas units. Sui prices instructions in tiers by how many a
transaction has already run, and a unit test is one transaction, so the setups are kept small (the proofs are
precomputed); the figures are the runner's, not a mainnet receipt's.

| Call | Gas units |
|---|---|
| `deposit` | 171 |
| `deliver` of an intake settle, both proofs | 5,990 |
| `deliver` of a burn, both proofs, 40 SUI paid as a coin and 60 owed | 5,661 |
| `attest`, three slots | 187 |
| P1's proof check (SP1 v6 Groth16) / P2's (RISC Zero v3.0) | 261 / 297 |
| the rest of `update` after the check | 27 |
| one event proof, its receipt bloated by 2 / 8 / 16 / 32 KB of other logs (LG-1) | 933 / 5,971 / 45,267 / 178,276 |

The pairing is native and cheap; what costs is Move walking bytes: a proof's nodes are copied to be hashed and the log
data compared byte by byte, and the tiers make that superlinear.

## Limits

- **Package size.** 36,125 bytes of bytecode against Sui's 100 KB package limit: one package holds the vault, P1 and P2.
- **One pure argument is at most 16 KB, a transaction at most 128 KB.** A proof longer than 16 KB is assembled in the
  programmable transaction with `std::vector::append` from several arguments. `deliver` carries both proofs of a
  receipt, so a receipt whose proof passes about 60 KB cannot be delivered in one transaction, and well before that
  the byte walking above grows expensive. A message sent by a permissionless call can be bloated this way
  (`HybridHub.claimOrder` called from a contract that also emits large logs), but not stranded: the hub and the
  factory mark every message they send, and anyone may emit a marked one again, unchanged, with `resendMessage` in a
  transaction of their own (LG-1). The vault delivers that copy, whose receipt holds only the message, and runs the
  message once by its id. The bloat costs the attacker gas and a relayer one resend.
- **What the vault cannot see.** As on every chain: the recovery proposer's multisig and the light clients' keys are
  the deployment's to check (above).
