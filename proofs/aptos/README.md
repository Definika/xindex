# The Aptos state proof

A vault's state on Aptos, proven to Ethereum (`../../design/2026-10-04-four-chains-interfaces.md`): SP1 proofs that
`../../src/verifiers/AptosStateVerifier.sol` checks. The vault is a Move package (`../../aptos/`); a slot is proven as
NEAR's and Stellar's are, by a successful `attest(slots, values)`, which aborts unless every slot holds its value and
emits one module event `<package>::vault::Attested { record }`. Its own workspace, as `../vechain` and `../cometbft`
are.

| Crate | What |
|---|---|
| `statement` | `xindex-aptos`: the statement in plain Rust, tested natively on mainnet's own data, with `testkit` for test chains |
| `program` | the SP1 program: reads an input, checks it, commits the public values |
| `script` | the host, `aptos`: `execute` (execute mode, prover gas), `vkey`, and `prove` on a GPU or the prover network |
| `fixtures` | `generate.py`, which fetches `mainnet.json` from Aptos Labs' public backup and REST API and builds `synthetic.json`, checked with a separate Python implementation (`aptos_py.py`, `bls_py.py`, `keccak.py`) |

## What Aptos's finality rests on, and how it is followed

**AptosBFT.** A block is committed once validators holding more than two thirds of the epoch's voting power sign a
`LedgerInfo` naming it: one BLS12-381 aggregate, min-pk with `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, the beacon
chain's ciphersuite and `../../src/libraries/Bls12381.sol`'s, over `sha3_256("APTOS::LedgerInfo") ++ bcs(ledger_info)`,
its signers a bitmask over the epoch's validators in order (aptos-core's `ValidatorVerifier::verify_multi_signatures`,
quorum `total * 2 / 3 + 1`). The statement reuses P1's BLS code (`../finality/src/bls.rs`), whose hash to G2 RFC 9380's
vectors pin. Keys are given as uncompressed points and checked against the compressed keys the ledger infos carry, as
P1 checks the beacon registry's; like Aptos's own aggregation, no key's subgroup is checked, since each validator proved
possession of its key on chain, which checks it.

**Epochs.** The ledger info that ends an epoch carries `next_epoch_state`: the next epoch's number and validators. A
chain of epoch-ending ledger infos, each signed by the set the one before named, follows the validators from a set the
verifier trusts (`EpochChangeProof::verify`). Epochs last two hours; every set the verifier uses, the trusted one
included, was named less than a day before (`MAX_LAG`): Aptos does not slash, so keys retired or leaked later could
sign at no cost. One proof may cross several epochs.

**State.** A ledger info commits to the transaction accumulator (`executed_state_id`) over every transaction's
`TransactionInfo` up to its version: SHA3-256 under `TransactionAccumulator`, an empty subtree the literal
`ACCUMULATOR_PLACEHOLDER_HASH`. A transaction info carries its status and `event_root_hash`, the same accumulator under
`EventAccumulator` over its events' hashes (`ContractEvent`). The statement writes the info with the status `Success`
and the root of the events given, so the path proves both; it writes the vault's event itself, `ContractEvent::V2` of
type `<package>::vault::Attested` with the record `abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestamp, slots,
values)`; and it requires exactly one event of that type among the transaction's, reading each event's type only as a
prefix where its variant puts it (a type tag's BCS is prefix-free). Only the vault's module can make an `Attested`, and
`attest` is an entry function, so a successful transaction holds at most one.

Every preimage is written from typed fields (`statement/src/bcs.rs`); the tests check that what it writes is mainnet's
own BCS byte for byte.

## The statement

Two claims, each from a set the verifier trusts, kept by its epoch (`statement/src/lib.rs`), and `hops`, epoch-ending
ledger infos each signed by the set before it:

- **update**: at least one hop; the verifier then trusts the last set named, dated by the ledger info that named it.
- **slots**: a ledger info of the epoch the hops reach, signed by its set; under its root the transaction at a version
  at or before its own, successful, with exactly one `Attested` of `package`, whose record the statement writes from
  the chain id, the vault id, the time and the slots and values. The claim gives the transaction's version and the
  vault's time.

**Public values.** One program, two claims, told apart by the first word:

```text
update: abi.encode(UPDATE, trustedEpoch, trustedSet, epoch, set, time)                                      6 words
slots:  abi.encode(SLOTS, chainId, trustedEpoch, trustedSet, package, vaultId, version, timestamp,
                   keccak256(abi.encode(slots, values)))                                                    9 words
```

`UPDATE = keccak256("xindex.v4.aptos.update")`, `SLOTS = keccak256("xindex.v4.aptos.slots")`; a set is `keccak256` of
its `ValidatorVerifier` BCS; times are Aptos's microseconds; `chainId` is the registry id the vault writes in its
record (`aptos:1`'s, 549304973309166888, on mainnet). The contract checks the claim, the trusted set (the latest for
an update, any it trusts for slots) and its age, that no time is after its own block, the chain, the package and the
vault, and the slots and values the caller gives. It returns the version as the block number and the vault's time in
seconds.

## Where the data is, and what a prover must do

Aptos's REST API serves transactions, their infos and events, and on-chain resources at any version, but no ledger
info's signatures and no accumulator proof. Those are in **Aptos Labs' public database backups**, the ones `aptos node
bootstrap-db` restores from (`aptos-labs/aptos-networks`, `mainnet/backups/gcs.yaml` and `testnet/backups/gcs.yaml`):
Google Cloud Storage buckets `aptos-mainnet-backup-usce1` and `aptos-testnet-backup-usce1`, folder `e1`, read
anonymously over HTTPS (`fixtures/rpc.py`). The S3 copy the documentation also names is gone.

- **Epoch-ending ledger infos**, with their signatures: `metadata/epoch_ending_<e>-<e>.meta`, its manifest, then a
  chunk of records, each a big-endian `u32` length and a `LedgerInfoWithSignatures`' BCS. Written minutes after each
  epoch ends (measured on 4 October 2026).
- **A ledger info over a transaction, and its path**: `metadata/transaction_<first>-<last>.meta` covers a million
  versions, written about every two hours. Each chunk of its manifest has the transactions, each record
  `(Transaction, PersistedAuxiliaryInfo, TransactionInfo, events, WriteSet)` in BCS, and a proof file: the chunk's
  `TransactionAccumulatorRangeProof` and the ledger info it reaches, the latest of the chunk's last epoch when the
  backup ran. With every transaction info of the chunk the range proof gives the root, and any transaction's
  single-leaf path (`aptos_py.range_to_leaf`).
- **Events**: in the same records, or from the REST API's BCS (`/transactions/by_version/<v>`, `application/x-bcs`).

So a vault's `attest` can be proven once its range is backed up, two to four hours after it ran. The backups are a
convenience, not a trust: every byte is checked against the signatures. Should Aptos Labs stop publishing them, a
prover runs its own fullnode, whose backup service (`storage.backup_service_address`, `127.0.0.1:6186` by default)
serves the same data. Testnet's epochs last an hour. A prover, or anyone keeping the verifier, must:

- **Update daily**: an update from the latest trusted set within a day of the ledger info that named it, or the
  verifier stops for good; one proof crosses the twelve epochs a day holds.
- **Prove slots** from any trusted set named less than a day before, crossing the epochs to the one whose ledger info
  covers the `attest`.

The fixture generator does both from public data alone: it reads every transaction info of a backup chunk (each
confirmed by its events' root and its write set's hash), checks the range proof against the ledger info's root,
derives one transaction's path, and checks the trusted set against the chain's own `0x1::stake::ValidatorSet` and
`0x1::reconfiguration::Configuration` at the version that named it. A prover's input builder for production would do
the same with aptos-core's own types; it is not built here.

## Build and test

Rust stable (`rust-toolchain`), SP1's toolchain (`sp1up`, SP1 6.8.1) and `protoc`, as `../README.md`. Gently:

```bash
cd proofs/aptos
CARGO_BUILD_JOBS=1 cargo test --release -p xindex-aptos           # the statement, natively: mainnet's data and test chains
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings
CARGO_BUILD_JOBS=1 cargo build --release -p xindex-aptos-script   # builds the program for SP1 too
./target/release/aptos execute                                     # both synthetic claims, in execute mode
./target/release/aptos execute fixtures/mainnet.json               # mainnet's update, 85 validators, two epochs
./target/release/aptos vkey                                        # AptosStateVerifier's PROGRAM_KEY
SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... ./target/release/aptos prove slots input.json proof.json
```

`fixtures/generate.py` needs only Python 3's standard library:

- `generate.py mainnet` reads the latest transaction backup's smallest chunk, its range proof and ledger info, and the
  two epoch-ending ledger infos before it with the set they start from; finds a successful transaction with a module
  event besides `FeeStatement`, which stands in for `Attested` (no vault exists on Aptos yet); and records each ledger
  info's signers and their share of the power, and each signer's point.
- `generate.py synthetic` builds both claims end to end on a SYNTHETIC chain: 25 validators with test keys, signed by
  `bls_py.py` (RFC 9380's hash to G2, checked on import against the RFC's vectors), two epoch changes, one of them
  signed by a bare quorum, the vault's `attest` at a mainnet-sized version, and the public values the program must
  commit, which `test/AptosStateVerifier.t.sol` uses.
- `generate.py anchor <out.json> [mainnet|testnet]` writes a deployment's first set: the epoch in force, its set's
  hash and when it was named, read from the chain's own resources and, on mainnet, checked against the backup's
  epoch-ending ledger info.

The tests break each check on mainnet's data and on test chains (`testkit`): a quorum of exactly two thirds, a signer
added or dropped, a bitmask a byte long or short or with a bit past the set, points swapped or negated, every signed
field, hops skipped or swapped, a ledger info that ends no epoch, the transaction's path, version, info, events and
their order, a failed status, two `Attested` events or none, one as a handle event, another package's, and each
field of the record. 25 mutants of the statement are each killed by one.

## Measured

On mainnet's data of 4 October 2026 (85 validators; epochs 17518 to 17520; a ledger info at version 7,481,031,397
signed by 56 of them with 74.5% of the power; a chunk of 18,621 transactions whose range proof reaches it; a path of 33
levels) every ledger info's aggregate, the trusted set against the chain's own `ValidatorSet`, and the stand-in
transaction and its events verify natively. SP1 6.8.1's execute mode ran mainnet's update across two epochs in 9.36
million instructions (9.90 million prover gas), and the synthetic update and slots claims, two epochs over 25
validators, in 8.17 and 12.18 million (8.62 and 12.82 million), committing exactly the public values `generate.py`
computed. A day's twelve epochs would cost about 55 million (extrapolated, not measured). On Ethereum, with the Groth16 check mocked, a two-slot
`verifySlots` costs 44,982 gas as a transaction (16,822 of it execution) and an `update` 86,275 (62,087); SP1's
Groth16 verifier adds about 230,000 to each. The key a local build prints is the tests'; a deployment's comes from SP1's
reproducible Docker build.
