# Xindex proofs

Stage B's proof systems, in Rust. The statement of each is checked in a plain library first, so its logic is tested
natively; the zkVM program only runs that library. Foundry and Wake never see this directory.

| Crate | What |
|---|---|
| `finality` | P1's statement (Stage B spec, section 10): a checkpoint finalized by two thirds of the anchor's validators, the next registry and execution block it commits to, and the execution headers since the anchor. `testkit` builds synthetic chains of any size. |
| `p1-program` | P1's SP1 program: reads an `Input`, runs `finality::verify`, commits the public values `EthereumFinalityVerifier` decodes. |
| `p1-script` | P1's host, `p1`: execute mode, the program key, and Groth16 proving on a GPU or the prover network. |
| `p1-input` | `p1-input`: builds a real input from two checkpoint states, a beacon node and an execution node, checking each piece against the root that commits to it. |

## Toolchain

SP1 6.8.1 (`sp1up`, into `~/.sp1`) and `protoc`, which `sp1-sdk`'s build needs. Build gently: the program compiles
for SP1's RISC-V target, and the host links the SP1 SDK, which is large.

```bash
export PATH="$HOME/.sp1/bin:$PATH" PROTOC=/path/to/protoc
CARGO_BUILD_JOBS=2 nice -n 19 cargo build --release -p xindex-p1-script
```

## Gates

```bash
CARGO_BUILD_JOBS=2 nice -n 19 cargo test --release -p xindex-finality
cargo fmt --all --check && cargo clippy -p xindex-finality --all-targets
```

`finality/tests/vectors.py` rebuilds the independent test vectors (the consensus specs' `remerkleable` and `py_ecc`).

## Running P1

```bash
# execute mode on a synthetic chain: no proving, counts instructions and prover gas, and checks the public values
./target/release/p1 execute --synthetic 1000 1 64      # validators, epochs past the anchor, execution headers
./target/release/p1 execute input.bin                  # an input file (bincode of finality::Input)
./target/release/p1 vkey                               # the program key EthereumFinalityVerifier is built with
SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... ./target/release/p1 prove input.bin proof.json
SP1_PROVER=cuda ./target/release/p1 prove input.bin proof.json
```

## Building a real input

```bash
# two finalized checkpoint states, e.g. from a checkpoint-sync server, some epochs apart
curl -H "Accept: application/octet-stream" https://mainnet.checkpoint.sigp.io/eth/v2/debug/beacon/states/finalized -o a.ssz
# ... one or more epochs later
curl -H "Accept: application/octet-stream" https://mainnet.checkpoint.sigp.io/eth/v2/debug/beacon/states/finalized -o b.ssz
./target/release/p1-input check-state a.ssz            # its root, recomputed from all 38 fields
./target/release/p1-input build <beacon-url> <execution-url> a.ssz b.ssz input.bin
```

`build` recomputes each state's root and its checkpoint block's root, reads the votes for both links from the blocks of
C1's epoch and the next two, maps each aggregate's signers through the committees, rebuilds every execution header's RLP
from JSON and checks its hash, and runs the whole statement natively before writing anything.

A validator added since the anchor needs its deposit, which the builder finds in the anchor state's queue. A validator
whose deposit was made after the anchor is not there, so the builder says to prove a nearer checkpoint first; a
validator can only vote about seven epochs after it joins, so a gap of a few epochs never needs one.

Rehearsed on 1 October 2026 against mainnet: anchor epoch 479,099 (2,375,541 validators), C1 epoch 479,101 finalized
by 149 and 170 real aggregates, 63 execution headers; the statement held natively in 8 seconds.

`proof.json` holds the public values and the proof for `EthereumFinalityVerifier.update`. Proving refuses this
machine's CPU: a mainnet proof is about 11 billion prover gas, the owner's run on rented GPUs or the prover network.
