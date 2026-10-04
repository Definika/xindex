# NEAR's state, proven on Ethereum

The statement `NearStateVerifier` (`../../src/verifiers/NearStateVerifier.sol`) records heads from, its program for SP1,
and the host that runs it. The interfaces it serves are `../../design/2026-10-03-near-stellar-interfaces.md`.

| Crate | What |
|---|---|
| `statement` | `xindex-near-finality`: the statement in plain Rust, tested natively on mainnet's own blocks |
| `program` | the SP1 program: reads an input, checks it, commits the public values |
| `script` | `near`: `execute` (execute mode, prover gas), `vkey`, and `prove` on a GPU or the prover network |
| `fixtures` | `generate.py`, which rebuilds `mainnet.json` from mainnet's RPC with a separate Python implementation |

## The statement

From a trusted epoch and its block producers, a chain of NEAR light-client blocks, each final under the producers of
its epoch, the last one the head. The rules are nearcore's light client's (`validate_and_update_head`), stated in
`statement/src/lib.rs`:
- a block's hash, the next block's, and the message the approvals sign, `borsh(Endorsement(next_hash)) ++ le(h + 2)`;
- every present approval verifies, with ed25519-dalek 2.2's `verify`, as nearcore checks it, and a key that does not
  decompress fails the block;
- strictly more than two thirds of the whole epoch's producer stake approves;
- only a block that names the next epoch's producers, `sha256(borsh(next_bps)) == next_bp_hash`, moves the statement to
  the next epoch, so every epoch's producers are learned from the one before, none skipped.

The public values are `abi.encode(epochIn, producersIn, epochOut, producersOut, namedAt, height, timestamp,
blockMerkleRoot)`: the epoch and producer-set hash the proof starts and ends at, when the set it ends at was named
(nanoseconds; zero when it names none), and the head.

## Build and test

SP1 6.8.1 and `protoc`, as `../README.md` says. Gently:

```bash
CARGO_BUILD_JOBS=1 cargo test -p xindex-near-finality
cargo fmt --all --check && cargo clippy -p xindex-near-finality --all-targets
CARGO_BUILD_JOBS=1 cargo build --release -p xindex-near-script     # builds the program into the host
./target/release/near execute                                      # mainnet's chain, in execute mode
./target/release/near vkey                                         # the key `NearStateVerifier` is built with
```

`fixtures/generate.py` (`uv run --with pynacl --with pycryptodome python3 generate.py`) fetches a fresh chain from
mainnet's RPC: epoch E-1's producers, E-1's last final block, the head, and a real receipt's outcome proof under it,
checking every signature, hash and path as it goes. It also writes a synthetic `attest` outcome for the Solidity tests.
Since the public RPC keeps only a few epochs, a regenerated fixture is a different chain; the tests read every value from
the file.
