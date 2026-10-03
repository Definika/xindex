# The Stellar state proof

Stellar → Ethereum for a Stellar vault (`../../design/2026-10-03-near-stellar-interfaces.md`): an SP1 proof that the
vault's `attest` succeeded in a ledger that a pinned quorum set externalized, which
`../../src/verifiers/StellarStateVerifier.sol` checks. Its own workspace, as `../p2` is.

| Crate | What |
|---|---|
| `statement` | `xindex-stellar`: the statement in plain Rust, tested natively, its fixtures and their generators. |
| `program` | the SP1 program, and a measurement build that takes any event in place of the vault's `attest`. |
| `script` | the host, `stellar-proof`: execute mode, the program key, and Groth16 proving on a GPU or the network. |

## The statement

Stellar commits to no contract storage a light client can open: its bucket list hashes whole files. So a vault's slots
are proven as TRON's are, by a call that succeeds only when the vault holds them. The vault's `attest` emits one
event, topics `[Symbol("attest")]` and data `Bytes(abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values))`.
`statement/src/lib.rs` proves it:

1. Validators of the pinned quorum set signed SCP `EXTERNALIZE` for slot `M` and one value, ed25519 over
   `networkID ‖ ENVELOPE_TYPE_SCP ‖ XDR(SCPStatement)`, and the signers satisfy it at every level. Tier 1 today is 7
   of 10 organisations, each 2 of 3 validators: 14 signatures at least.
2. The value's `txSetHash` opens to ledger `M`'s transaction set, whose fixed prefix names header `M-1`.
3. Headers link back to ledger `N`.
4. Header `N`'s `txSetResultHash` opens to its result set, one pair of which is a successful `InvokeHostFunction`,
   directly or in a fee bump, whose `Success` hash is SHA-256 of its success preimage.
5. The preimage, decoded strictly and written again, holds the event the statement writes itself from the vault's id
   and the record. Never an event's bytes taken on trust: a byte string shaped like the event inside another value is
   not an event.

Public values: `abi.encode(networkId, quorumSetHash, ledger, closeTime, vaultId, keccak256(record))`. The contract
checks the network, the quorum set and the vault against its own, the ledger's age against `MAX_LAG`, and writes the
record again from the requested slots and the given values.

## Trust

A forged proof needs 7 of Tier 1's 10 organisations, two validators each, to sign a value the network never
externalized; Stellar slashes nobody, so that costs them nothing, as on TRON. Two honest validators in each of four
organisations stop it. Tier 1's membership is agreed off chain and recorded nowhere on chain, so the verifier pins its
quorum set's hash: when Tier 1 changes, a new verifier with the new hash replaces it through the factory's 30-day
`ROTATION_DELAY`, and a proof under the old set keeps working only while enough of the old validators still sign.

## Build and test

Rust stable (`rust-toolchain`) and SP1's toolchain (`sp1up`), as `../`.

```bash
cd proofs/stellar
CARGO_BUILD_JOBS=1 cargo test --release -p xindex-stellar          # the statement, natively
cargo fmt --all --check && cargo clippy -p xindex-stellar --all-targets
cargo build --release -p xindex-stellar-script                     # builds the program for SP1 too
./target/release/stellar-proof execute --synthetic 7 1            # the program, on a synthetic attest
./target/release/stellar-proof execute --mainnet statement/fixtures/mainnet.json 14
./target/release/stellar-proof vkey                                # StellarStateVerifier's PROGRAM_KEY
SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... ./target/release/stellar-proof prove input.json proof.json
```

`cargo run --release --example generate -- [checkpoint] [cache]` rebuilds `statement/fixtures/mainnet.json` from SDF's
history archive and a public Stellar RPC, read-only, checking every hash before it writes. `cargo run --example vector`
rebuilds `statement/fixtures/attest.json`, which the Solidity tests read; `tests/vector.rs` fails if it is stale.
