# Xindex vault on Aptos

The Aptos twin of `src/vault/XindexVault.sol` and of the Solana, NEAR, Stellar and Sui vaults, with P1 and P2, Ethereum
light clients, in the same Move package. It holds APT for every index whose shares live on Ethereum. Coins enter only
as deposits to an intake. They leave only on messages that P1 (SP1) and P2 (RISC Zero) prove final on Ethereum, within
the 4%-a-day speed limit. Ethereum learns the vault's state through `attest`, whose `Attested` event
`AptosStateVerifier` (`src/verifiers/AptosStateVerifier.sol`, `proofs/aptos`) reads from a signed ledger info. The
chain ids, the vault id, the recipient encoding, the slot map and the event are fixed in
`design/2026-10-04-four-chains-interfaces.md`.

Status: built and tested on Aptos's Move unit-test runner (CLI 9.6.0, the framework at the `mainnet` branch's commit
`Move.toml` pins, aptos-node v1.39). Not published anywhere.

## Build and test

Only `aptos move compile`, `aptos move test` and `aptos move coverage` are needed, none of which reads a profile or a
key. Never run `aptos init`, `aptos account`, `aptos key`, `aptos move publish` or `aptos move run` from a checkout: they
create or use keys. The CLI fetches the framework from GitHub at the commit `Move.toml` pins.

```bash
cd aptos
aptos move compile --dev                               # the tests' address, 0xc0de
aptos move compile --named-addresses xindex_vault=0x... --fail-on-warning --included-artifacts none   # as published
aptos move test --dev                                  # 425 tests
aptos move test --dev --coverage && aptos move coverage summary --dev
python3 tests/fixtures/gas.py                          # the gas table below (needs the CLI as `aptos` or in APTOS)
```

The fixtures are generated, never edited (from the repository root, with foundry):

```bash
python3 aptos/tests/fixtures/generate.py   # hub.json: a real hub's storage on a local anvil (nothing leaves the machine)
python3 aptos/tests/fixtures/vectors.py    # tests/fixtures.move and test/fixtures/aptos/vault-attest.json
python3 aptos/tests/fixtures/events.py     # checks mainnet-events.json offline; --fetch rereads it, read-only
```

## Layout

| Module | What |
|---|---|
| `vault` | The vault: the `Vault` resource at its object, every rule, the `Attested` event and `attest`. |
| `light_client` | P1 and P2: a `LightClient` at an object per light client, the twin of `FinalityVerifier.sol`. |
| `proofs` | SP1 v6's and RISC Zero v3.0's Groth16 checks on `aptos_std::crypto_algebra` (BN254), from the EVM encodings. |
| `ethereum` | The headers tree, an event proof's and a checkpoint proof's format, a receipt's log. |
| `rlp`, `mpt` | RLP read in place, Merkle-Patricia proofs (absence included). |
| `state_reader` | An account's storage under a state root, from `eth_getProof`. |
| `snapshot` | The hub slots a snapshot claim reads, a holder's share, its EIP-712 digest and signature. |
| `abi` | `VaultMessages`, the index and intake digests, the log data, CREATE2, `attest`'s record. |
| `bytes` | Big-endian words and byte slices. |

The proof formats are the Rust core's (`crates/xindex-core`) and Sui's, byte for byte: an event proof is `headersRoot ++
number (u64 LE) ++ timestamp (u64 LE) ++ stateRoot ++ receiptsRoot ++ path count (u8) ++ path ++ node count (u8) ++
(length (u32 LE) ++ node) * count ++ txIndex (u32 LE) ++ logIndex (u32 LE)`; a checkpoint proof is the header part
alone; a state proof is the account's node list, then one per slot.

## Functions

Every function but `attest` is `public` or `public entry`, so a Move script or another module composes them. Anyone may
call every one but the role-gated ones (the freezer, the recovery proposer), which check their signer. A vault and a
light client are named by their objects' addresses.

| Function | What it does |
|---|---|
| `light_client::create(creator, seed, system, key, anchor, epoch, genesis_time)`, `create_client` | A light client at `object::create_object_address(creator, seed)`: 1 SP1 (P1) or 2 RISC Zero (P2), its program key or image id, the anchor and epoch it starts from. |
| `light_client::update(client, public_values, proof)` | Advances it with a proof from its anchor, until a day after the anchor's epoch began (LG-4). |
| `vault::create(creator, source, chain, factory, template, p1, p2, freezer, recovery, cap, floor)`, `create_vault` | Creates the vault at `object::create_object_address(creator, b"xindex.v4.vault")`; returns that address, the vault id Ethereum's registry names. |
| `register_index(vault, index, salt)` | Registers a clone of the factory's `HybridHub` template, checked by the CREATE2 formula. |
| `deposit(depositor, vault, index, intake_id, amount)` | Deposits APT from the depositor's primary store. The deadline is the id's top 64 bits; within `MAX_INTAKE_LIFE`; refused before the first checkpoint (B1-04), over the cap, frozen or stalled. |
| `deposit_asset(depositor, vault, index, intake_id, fa)` | The same with APT withdrawn elsewhere, as a `FungibleAsset`, which must be APT. |
| `refund(depositor, vault, index, intake_id)` | The depositor takes back its deposit to a failed intake, to its primary store. |
| `deliver(vault, payload, block, proof1, proof2)` | Runs a `VaultMessage` on P1's proof, P2's or both; an empty proof is none. A factory `FREEZE` carries one word, when the factory's freeze ends: it freezes until then, at most 14 days from delivery, and not at all once that end has passed (A3-03). |
| `release(vault, index, id)` | Pays what the speed limit now allows of an owed burn, claim or migration. |
| `freeze_vault(freezer, vault)` | Freezer only, before a snapshot: 14 days. (`freeze` is a builtin in Move.) |
| `apply_change(vault, kind, body)` | Applies a waiting cap raise, freezer change or rotation, a rotation's clients a pair as `create` takes one (B4-03). |
| `cancel_change(freezer, vault, kind)` | Freezer only: drops a waiting raise or rotation, never its own replacement. |
| `advance_checkpoint(vault, block, timestamp, state_root, proof1, proof2)` | A final Ethereum block both prove, newer than the last. |
| `continuity(...)` + `propose_successor(proposer, vault, p1, p2, continuity)`, `propose_successor_entry` | Recovery proposer only, while stalled; the pair as `create` takes one (B4-03). |
| `veto_successor(freezer, vault)`, `adopt_successor(vault, block, timestamp, state_root, proof1, proof2)` | The freezer's two vetoes a stall; adoption after 30 days. |
| `begin_snapshot(vault)` | 180 days into a stall: the last checkpoint becomes the snapshot; its root goes to slot 25. |
| `claim_snapshot(vault, index, holder, component, recipient, signature, proof)` | A holder's share at the snapshot, to its registered recovery address or the recipient its EIP-712 signature names (the domain below). |
| `resolve_intake(vault, index, intake_id, proof)`, `deliver_recorded(vault, payload, proof)` | After the snapshot, from the hub's `_settledIntakes` and `_sentMessages`. |
| `attest(vault, slots, values)` | Entry only. Aborts unless every slot holds its value; then emits one `Attested` with the record. |
| Views (`#[view]`) | `vault_address`, `vault_id`, `store`, `coins`, `checkpoint`, `exit_snapshot`, `successor`, `index_state`, `intake`, `deposited`, `owed`, `used`, `slot`, `stalled`, `stall_start`, `pending`, `nonces`, and the settings. |

## The attestation

`attest` builds `abi.encode(ATTEST_DOMAIN, uint256 chainId, bytes32 vaultId, uint256 timestampUs, bytes32[] slots,
bytes32[] values)`, `timestampUs` `timestamp::now_microseconds()` when it runs, `chainId` `aptos:1`'s or `aptos:2`'s
registry id, `vaultId` the vault object's address, and emits it as one module event:

```move
#[event]
struct Attested has drop, store { record: vector<u8> }
```

- **Type.** `<package>::vault::Attested`, `<package>` the address the package is published at, which is not the vault
  id: `AptosStateVerifier` takes the two apart (`PACKAGE` and `VAULT_ID`). The type tag's BCS is `07 ++ package (32
  bytes) ++ 05 "vault" ++ 08 "Attested" ++ 00`.
- **Data.** The struct's BCS, the record as a byte string: `ULEB128(len(record)) ++ record` (448 bytes of record for
  three slots: `c0 03 ++ record`).
- **On the ledger.** `ContractEvent::V2` is `01 ++ type tag ++ ULEB128(len(data)) ++ data`; its hash is
  `sha3_256(sha3_256("APTOS::ContractEvent") ++ bcs)`; a transaction info's `event_root_hash` is the accumulator over
  its events' hashes (`sha3_256("APTOS::EventAccumulator")` as the internal nodes' salt, the right-padding placeholder
  `"ACCUMULATOR_PLACEHOLDER_HASH" ++ 00000000`). `tests/fixtures/events.py` checks all three on real mainnet
  transactions of one, two and three events (`mainnet-events.json`).
- **Pinned.** `tests/vault_tests.move` rebuilds the whole `ContractEvent` from the vault's own record and its event's
  type (`type_info::type_of<vault::Attested>()`) and compares it byte for byte with the event `AptosStateVerifier`'s
  statement writes on its synthetic chain (`proofs/aptos/fixtures/synthetic.json`, another package and vault, Aptos
  mainnet's id), and with a real `attest`'s event (`test/fixtures/aptos/vault-attest.json`, from Solidity's encoder,
  with the event's hash).

Only `attest` packs an `Attested`, and a failed transaction emits no event, so a ledger holding one proves a
successful `attest`. `attest` is an entry function that is not `public`: no Move script or module can run it between two
other calls, so a transaction holds at most one `Attested` (the statement requires exactly one), and a record shows the
vault's state between two transactions. All the transactions of one block share their time, so the states of one time
may differ; the hub's rules on attested states take that as given, as on NEAR, Stellar and Sui. A slot never written
reads zero; the slot map follows the EVM vault's storage, written whenever the value changes: an intake's digest at
`keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))`, an index's at `keccak256(abi.encode(index, 14))`,
the snapshot's root at `bytes32(25)`.

## Ownerless and immutable

What nobody holds:

- **The code.** `Move.toml` sets `upgrade_policy = "immutable"`: `0x1::code` refuses any later publication of the
  package (`EUPGRADE_IMMUTABLE`) and any other package's module named as one of its (`EMODULE_NAME_CLASH`). Every module
  is in this one package; nothing is `friend` to anything outside it.
- **The vault's object.** `create` makes it a named object, moves it to `0x0`, which nobody can sign for, and makes it
  untransferable. Its signer comes only from the `ExtendRef` stored in the `Vault` resource, which only `vault`'s code
  reads; no `ConstructorRef`, `TransferRef` or `DeleteRef` is kept. Ownership matters on Aptos:
  `fungible_asset::withdraw` lets any owner up an object's chain withdraw, so a vault object owned by its creator would
  let the creator take its coins (`the_creator_cannot_withdraw_the_coins`, and the mutant that keeps the creator as
  owner is killed).
- **The coins' store.** A fungible store at a second named object, owned by the vault's object and untransferable. Only
  `vault` withdraws from it, with the vault's signer.
- **The light clients.** Each at a named object moved to `0x0` and untransferable; nothing but `light_client`'s code
  touches its state.
- **Roles.** The freezer and the recovery proposer are addresses in the vault's state, compared with the signer.

The publication flow, for a deployment script (nothing here has been run):

1. A fresh deployer account. It publishes and creates; it holds no power afterwards, and the vault refuses it as the
   freezer or the recovery proposer.
2. Publish: `aptos move publish --named-addresses xindex_vault=<deployer> --included-artifacts none` (45.5 KB, under the
   64 KB transaction limit; with `sparse` sources the payload is 87 KB and needs `--chunked-publish`). Check on chain
   that `0x1::code::PackageRegistry` at the deployer lists `xindex_vault` with `upgrade_policy.policy == 2`, and compare
   its modules' bytecode with a local build.
3. Create P1 and P2: `light_client::create_client(deployer, seed, 1, <p1 vkey>, anchor, epoch, genesis)` and the same
   with `2` and `<p2 image id>`, from the same anchor and epoch as the other vault chains' P1 and P2 at that time. Their
   addresses are `object::create_object_address(deployer, seed)`.
4. Create the vault: `vault::create_vault(deployer, source, chain, factory, template, p1, p2, freezer, recovery, cap,
   floor)`. It refuses what `DeployVault` refuses where Move can see it: a source chain other than Ethereum (1) or
   Sepolia, a chain id not Aptos's for it (`aptos:1` for Ethereum, `aptos:2` for Sepolia), a missing factory or
   template, P1 not an SP1 client or P2 not a RISC Zero one of this package, either not of the source chain's beacon
   genesis, anchored in an epoch that has not begun (B4-02) or past its lag, a missing, equal or creating-key freezer or
   recovery proposer, and a floor above the cap (B2-02); a source chain is never Aptos's own. A rotated pair and a
   successor pass the same checks of a pair, from the same function (B4-03). The vault takes no deposit until its
   first checkpoint (B1-04). Its address, the vault id, is `vault::vault_address(deployer)`.
5. Check off chain what Move cannot see: that the recovery proposer is the owner's emergency multisig (at least three of
   five; an Aptos multisig is either `0x1::multisig_account`, which a view would show, or a multi-key account, whose
   address is a hash of its keys), that the freezer is the guardian's key, and that P1's key is `p1 vkey`'s program key
   and P2's `p2 image-id`'s.
6. Measure the gas of P1's and P2's `update` before anything is registered (B4-05). The figures under "Gas" are
   estimates: the unit-test runner meters nothing, and an `update` the chain cannot run would stop P1 or P2 for good a
   day later (LG-4) and stall the vault. P1 and P2 must be advanced within a day of their anchor anyway, so their first
   `update`s on mainnet, each with a real proof (SP1's Groth16 for P1, RISC Zero's for P2) from the anchor of step 3,
   are the measurement; rehearse them on testnet first, and a `deliver` of a burn on both proofs with them. Read each
   committed transaction's `gas_used` from a full node (`GET /v1/transactions/by_hash/{hash}`) and the execution limit
   from the gas schedule then in force (`0x1::gas_schedule::GasScheduleV2`, `txn.max_execution_gas`). The vault is
   listed only if every figure fits well under that limit. Record the transactions' hashes, their `gas_used` and the
   gas schedule's feature version in the listing proposal's notes, and in the table under "Gas" in place of the
   estimates.
7. Register on Ethereum: the factory's `proposeChain(aptos:1, vaultId, AptosStateVerifier)`, the verifier built for
   `PACKAGE = <deployer>` and `VAULT_ID = <vault id>`.

Aptos's validators can still change any state or the framework by governance; no contract can remove that power.

## How it differs from the EVM vault

- **P1 and P2 are objects of this package.** Each light client is a `LightClient` at its object's address, which the
  vault names, as the EVM vault names a verifier by its address; the vault reads them by address, so no call passes
  them in. A `VERIFIER_ROTATION` names two addresses, which must hold a pair of this package as `create` takes one: P1
  the SP1 client and P2 the RISC Zero one, of the source chain's beacon genesis, anchored in an epoch that has begun and
  still within their lag (B4-03); `apply_change` applies it as the other kinds (Sui's twin needs `apply_rotation` for its
  objects). Their code is this
  package's, which nobody can upgrade, so SOL-2 (an upgradable verifier) cannot arise.
- **Groth16 on Aptos's native BN254.** `proofs` checks `e(A, B) e(C, -delta) e(alpha, -beta) e(L, -gamma) = 1` with one
  four-pair `multi_pairing`, `L` a six-point `multi_scalar_mul`. Points are read uncompressed (arkworks' form, which
  costs less gas than compressed on Aptos), every coordinate checked below q, and the algebra module checks each lies on
  the curve and in its subgroup: an off-curve point is refused (`EBadPoint`), where Sui's twin, which compresses, reads
  the curve's point at that x. The EVM's point at infinity `(0, 0)` is refused too. RISC Zero's key, which snarkjs keeps
  positive, is stored negated; `proofs_tests` rebuilds both keys from the Solidity verifiers' constants. Both features
  this needs are on on mainnet and testnet (`CRYPTOGRAPHY_ALGEBRA_NATIVES`, 12, and `BN254_STRUCTURES`, 43, read from
  `0x1::features::Features` on 4 October 2026).
- **Time is `timestamp::now_seconds()`** for every rule, and `now_microseconds()` in the record. Aptos's time is the
  block's, which validators bound (SOL-10's drift question is Aptos's consensus's, as on Sui).
- **Amounts are APT in octas, `u64`**; an amount from Ethereum past 64 bits is refused (`abi::EOverflow`), as on Solana
  and Sui, but a `CAP_UPDATE`'s cap or floor past 64 bits means `u64::MAX`, since the factory proposes them in 256 bits
  knowing no chain's width (B1-05), and so does a `FREEZE`'s end. A snapshot share takes `shares × units` in 256 bits,
  as Solidity does.
- **APT is the fungible asset at `0xa`**, the form current on mainnet (`COIN_TO_FUNGIBLE_ASSET_MIGRATION` and
  `NEW_ACCOUNTS_DEFAULT_TO_FA_STORE` on; accounts hold APT in primary fungible stores). `deposit` withdraws from the
  depositor's primary store; `deposit_asset` takes APT however withdrawn (an account still holding a `CoinStore` can
  convert with `coin::coin_to_fungible_asset`), refusing any other asset (`ENotNative`). The coins sit in the vault's own
  store, so `held` equals its balance, but for APT someone deposits there directly (`fungible_asset::deposit` is open to
  anyone), which counts nowhere; APT sent to the vault's address goes to the object's primary store, which nothing
  withdraws from.
- **Payouts are APT deposited to a 32-byte address's primary store**, created if missing. That never fails but for a
  store frozen by APT's issuer, the framework; a payout then aborts its call and stays deliverable or owed, as the EVM
  vault's to a refusing recipient. A burn's or claim's recipient may not be zero, the vault's object or its store's
  object (SOL-9): APT sent there would be stranded.
- **The freezer and the recovery proposer are addresses**, checked against the signer. A freezer change's body is a
  32-byte Aptos address.
- **The snapshot claim's signature.** A holder with no recovery address signs `SnapshotClaim(address index,address
  holder,bytes32 recipient)` under `EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)`: name `Xindex
  vault`, version `1`, `chainId` the vault's source chain, Ethereum's (1, or 11155111 for a Sepolia vault), the network
  the holder's wallet is on, and `salt` the vault's 32-byte id, which keeps the domain this vault's alone (B1-06).
  Wallets refuse to sign a domain whose chain id is not the active network's, and no EVM network carries Aptos's
  registry id. The recipient is a 32-byte Aptos address.
- **`attest` is entry-only**, so a record is a state between transactions (above), where Sui's and NEAR's may be read
  between two calls of one transaction.
- **One vault per creating account**, at a named object's address, which a deployment can compute before it creates.
- **Refusals are abort codes**, each module numbering its own as Sui's twin does: `vault` 1 to 55 (51, Sui's
  `EVerifiersRequired`, unused; 54 no vault at the address), `bytes` 1 and 2, `rlp` 101, `mpt` 111, `ethereum` 121 to
  127, `light_client` 131 to 139 (139 no client at the address), `state_reader` 141, `proofs` 151 to 157 (157 a point
  off the curve), `snapshot` 161 to 165, `abi` 201 and 202. A signature whose `r` is no point's x-coordinate recovers no
  key and is refused with `EBadSignature`.
- **Storage is paid by whoever adds it**: each new state slot costs a deposit of 400,000 octas and 400 a byte on mainnet
  today; nothing is ever deleted, so a message's used mark lasts.

## Tests

`aptos move test --dev` runs 425 tests; instruction coverage is 97.0% (`aptos move coverage summary`), the rest being
short-circuited halves of bounds checks no caller reaches, a successful `update` (no real proof's public values are this
statement's, as on Sui) and an already-untransferable store. They run on:

- **Real proofs.** SP1 v6's own Groth16 fixture and RISC Zero v3.0's own receipt, both verified on Aptos's BN254; every
  refusal (another value, program, image, nonce, point, selector, length, exit code, vk root, a coordinate or input past
  its field, `-A`, the point at infinity, B's coordinates in the other order).
- **Real receipts.** Block 26,092,387's receipts trie (`test/fixtures/ethereum/receipts.json`): a one-byte key, a
  two-byte key and a legacy receipt, and a failed transaction, an absent receipt, a one-topic log and a malformed
  receipt, each refused.
- **A real hub.** `tests/fixtures/hub.json`: the repository's factory and hub on anvil, with Aptos testnet's registry id
  and this vault's id (the named object the tests create from `0xc4ea7042`): two holders, one signing its claim with its
  Ethereum key and one with a recovery address on Aptos, a settled and an open intake, a burn and a migration in flight,
  and storage past the components array filled as an attacker would (VLT-1).
- **Solidity's encodings.** Messages, log data, digests, slot keys, the vault token's id, CREATE2 and `attest`'s record,
  against `cast abi-encode` and `cast keccak` (`vectors.py`); every kind's body but a burn's, decoded from
  `test/fixtures/vault-messages.json`, which `test/VaultMessages.fixture.t.sol` pins against `VaultMessages.encode`
  (C1-02); and the `Attested` event against `AptosStateVerifier`'s statement (above).
- **Aptos's objects.** Nobody owns the vault or can move it, the creator cannot withdraw its coins, one vault per
  creator, another fungible asset is no APT, APT sent to the store counts nowhere.

Tests named after findings:

| Test | Checks |
|---|---|
| `test_vlt1_another_component_is_refused`, `test_vlt1_the_slot_past_the_end_is_refused`, `test_vlt1_storage_past_the_end_is_refused`, `test_vlt1_the_component_inside_the_array_is_paid` | A claim reads only inside the hub's components array, and only APT there, on a real hub's storage. |
| `test_vlt2_*` (eleven) | Loosening governance needs both proofs and waits `GOVERNANCE_DELAY`; the freezer may cancel it but not its own replacement, and a freeze holds every change but that one. |
| `test_vlt3_a_message_after_the_checkpoint_waits_for_it`, `test_vlt3_a_burn_after_the_checkpoint_waits_for_it`, `test_vlt3_a_message_runs_once_its_block_is_checkpointed` | A message moving coins waits for the checkpoint. |
| `test_vlt4_one_proof_moves_no_mark`, `test_vlt4_an_older_message_is_stale`, `test_vlt4_the_same_nonce_is_stale`, `test_vlt4_a_rotation_at_the_same_nonce_is_stale`, `test_sol3_an_older_freezer_change_cannot_undo_a_newer_one` | Only a message on both proofs moves a nonce mark; an older message cannot undo a newer one. |
| `test_vlt5_the_freezer_cannot_freeze_after_the_snapshot`, `test_vlt5_the_factory_cannot_freeze_after_the_snapshot`, `test_vlt5_no_message_from_after_the_snapshot` | No freeze and no later message after the snapshot. |
| `test_lg1_a_message_sent_again_runs_once`, `test_lg1_a_resent_message_runs_from_its_new_block`, `test_lg1_a_receipt_with_*_kb_of_other_logs` | A message runs once by its id, from whichever block proves it first; a receipt bloated by other logs is read (costs below). |
| `test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes`, `test_lg2_stale_checkpoints_win_no_new_veto` | A stale advance in a stall keeps the review and the veto count. |
| `test_lg3_a_one_proof_message_is_not_the_last_message` | A one-proof message cannot keep an honest successor out. |
| `test_lg4_*` (five) | The lag ends a day after the anchor's epoch; SP1's and RISC Zero's real proofs are checked at its last second and refused a second later. |
| `test_sol9_the_vault_is_no_recipient`, `test_sol9_the_store_is_no_recipient`, `test_sol9_a_claim_never_pays_the_vault`, `test_sol9_a_claim_never_pays_the_store` | Neither a burn nor a claim pays the vault's object or its store's. |
| `test_a303_a_late_freeze_ends_with_the_factorys_freeze`, `test_a303_a_freeze_lasts_at_most_freeze_duration` | A `FREEZE` delivered after the factory's freeze ended freezes nothing; one delivered during it freezes until its end, never past 14 days. |
| `test_b404_a_freeze_body_is_one_word`, `test_b404_a_freeze_body_of_two_words_is_refused` | A `FREEZE`'s body is exactly one word. |
| `test_b104_no_deposit_before_the_first_checkpoint`, `test_b104_a_deposit_after_the_first_checkpoint_is_taken` | No deposit before the first checkpoint. |
| `test_b105_a_cap_wider_than_the_native_type_saturates` | A cap past 64 bits is `u64::MAX`, a raise like any other. |
| `test_b106_the_claim_domain_names_ethereum` | The claim's EIP-712 domain names the source chain, Ethereum's, and the vault pays on that signature. |
| `test_b202_a_floor_above_the_cap_is_refused`, `test_b202_the_vaults_own_chain_is_no_source` | `create` refuses what `DeployVault` refuses. |
| `test_b402_a_client_of_a_later_epoch_is_refused`, `test_b402_a_client_whose_epoch_begins_now_is_taken` | A light client is taken only once its anchor's epoch has begun. |
| `test_b403_*` (five), `test_b402_b403_*` (two) | A rotated pair and a successor pass `create`'s checks of a pair: the roles, the genesis, the epoch and the lag. |
| `test_c102_the_message_bodies_are_soliditys` | Every kind's body, as Solidity encodes it, decodes to its fields. |

Each finding's guard, and the main rules, were checked by a mutant the tests kill (`mutants` below): VLT-1 (both
checks), VLT-2 (the delay, the freezer's own replacement, the freeze's hold both ways), VLT-3, VLT-4 (the mark and the
stale nonce), VLT-5 (the freezer's and the factory's), the snapshot's block bound, LG-1, LG-2, LG-3, LG-4 (the lag and
its last second), SOL-9 (burns, claims, the store), the speed limit's 4%, its 24-hour window and one hour's bucket, a
frozen payout, both proofs for burns, migrations and failures, the cap's floor in `needs_both`, a freeze on one proof,
`attest`'s check, the record's layout and its microseconds, the recovery proposer, continuity (a) and (c), the G2
coordinate order, SP1's digest mask, the pairing's verdict, the intake's deadline and life, the log's emitter, the
headers range, the anchor, the receipt's status, the route's vault, the index digest's fields, `held`, the stall's hold
on deposits, the hub's sent and settled marks, APT only, the vault's owner and its untransferability, a rotation's pair,
a governance kind's emitter, the claim signature's signer and low `s`, a registered recovery address, a claim once, the
native slice and comparison, and the 2026-10-04 audit's guards: A3-03 (the end that passed and the 14-day bound), B4-04,
B1-04, B1-05, B1-06, B2-02 (the floor and the source), B4-02 (the check and its boundary) and B4-03 (the roles, the
genesis and a successor's pair): 74 mutants, all killed (`tests/fixtures/mutants.py`).

## Gas

The unit-test runner meters no gas (its `-i` bound is not enforced in CLI 9.6.0), and the commands that do
(`aptos move simulate`, `run`, `sim`) need a profile or a published package, which this work does not use. So the
figures below are estimates (`tests/fixtures/gas.py`): each pair of `tests/gas_tests.move` is run alone with
`--coverage`, whose map counts every instruction run; the difference is the call's. This package's instructions are
priced by opcode from the disassembly at mainnet's schedule (feature version 53, `gas-schedule-mainnet.json`), the
framework's at this call's own mix (low without calls, high with them), natives by the schedule's formulas (BN254's
multi-scalar multiplication, which the schedule does not price, as six scalar multiplications, an upper bound), and the
storage reads, writes and new slots each call makes by hand. Real figures need a simulation, and P1's and P2's
`update` must be measured on chain before the vault is listed (B4-05; the publication flow's step 6).

| Call | Gas units, estimated | Storage deposit (new slots) |
|---|---|---|
| `deposit`, the first into an intake | 150 to 160 | 0.0134 APT (3) |
| `deliver` of an intake settle, both proofs | 320 to 340 | 0.0044 APT (1) |
| `deliver` of a burn of 100 APT, both proofs, 40 paid and 60 owed | 350 to 370 | 0.0142 APT (3) |
| `attest`, three slots | 90 to 95 | none |
| P1's `update` (SP1 v6 Groth16) | about 1,985 | 0.0044 APT (1) |
| P2's `update` (RISC Zero v3.0 Groth16) | about 2,000 | 0.0044 APT (1) |
| one event proof, its receipt bloated by 8 / 32 KB of other logs (the walk alone) | 66 to 71 / 117 to 122 | none |

Each figure is execution, storage IO and the transaction's own charges (intrinsic, modules loaded); the deposit is APT,
apart from gas. The updates' multi-scalar multiplication is priced at its upper bound and may be up to about 160 units
less.

The proof checks dominate P1's and P2's updates: per check, the four-pair pairing (732 units) and reading 9 G1 and 4 G2
points with their subgroup checks (802). The new state slots dominate the rest, in APT: a first deposit into an intake
creates three (the intake, the deposit and the intake's slot), a burn three (its used mark, its owed entry and, the first
time, the recipient's primary store).

Byte slices of 64 bytes or more, that are not a sliver of a much longer string, are copied natively (`vector::
move_range` after a copy, a few hundred internal units a byte, against tens of thousands a byte for a loop), so a
receipt bloated by other logs costs little more than its size (LG-1): one event proof after 32 KB of other logs is about
a hundred units.

## Limits

- **Package size.** 44,839 bytes of bytecode in ten modules; 45.5 KB with its metadata and no sources, under the 64 KB
  transaction; with compressed sources (`sparse`), 87 KB, which needs a chunked publish. No module comes near the 1 MB a
  write may hold.
- **One transaction is at most 64 KB.** `deliver` carries both proofs of a receipt, so a receipt whose proof passes
  about 30 KB cannot be delivered in one transaction. A message sent by a permissionless call can be bloated this way,
  but not stranded: the hub and the factory mark every message they send, and anyone may emit a marked one again,
  unchanged, with `resendMessage` in a transaction of their own (LG-1). The vault delivers that copy, whose receipt holds
  only the message, and runs the message once by its id.
- **Execution is at most 9,200 gas units a transaction** on mainnet; the costliest call, an update, needs about 2,000 by
  the estimate above, a margin of about 4.6 that nothing has measured yet: the deployer measures it before listing
  (B4-05, the publication flow's step 6) and records the figures here.
- **What the vault cannot see.** As on every chain: the recovery proposer's multisig and the light clients' keys are
  the deployment's to check (above).
