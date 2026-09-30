# Xindex proofs

Stage B's proof systems, in Rust. The statement of each is checked in a plain library first, so its logic is tested
natively; the zkVM program only runs that library. Foundry and Wake never see this directory.

| Crate | What |
|---|---|
| `finality` | P1's statement (Stage B spec, section 10): a checkpoint finalized by two thirds of the anchor's validators, the next registry and execution block it commits to, and the execution headers since the anchor. `testkit` builds synthetic chains of any size. |
| `p1-program` | P1's SP1 program: reads an `Input`, runs `finality::verify`, commits the public values `EthereumFinalityVerifier` decodes. |
| `p1-script` | P1's host, `p1`: execute mode, the program key, and Groth16 proving on a GPU or the prover network. |

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

`proof.json` holds the public values and the proof for `EthereumFinalityVerifier.update`. Proving refuses this
machine's CPU: a mainnet proof is about 11 billion prover gas, the owner's run on rented GPUs or the prover network.
