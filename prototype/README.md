# Xindex proving prototype (Phase 2)

Measures what a proof of Ethereum finality costs in SP1, for the go/no-go thresholds in
`../design/2026-09-30-proving-prototype.md`, which also holds the results. The repository's own Foundry project, its
gates and Wake never see this directory.

It ships nothing of its own, and production code does not import it: P1 is built in `../proofs`, and BNB Chain's
verifier, from M6, in `../src/verifiers/BnbStateVerifier.sol`. One vendored part is used beyond it: `evm/src/sp1` is
SP1's Groth16 verifier v6.0.0 from sp1-contracts (`evm/src/sp1/SOURCE.md`), which P1 calls on an EVM vault chain and
on TRON. The demo deploys it on BNB testnet, `../tron` builds it with Tron's compiler, and Solana's P1
(`../solana/programs/ethereum-verifier`) takes its verifying key and checks from it. `../script/DeployVault.s.sol`
accepts only a deployment that names itself by this verifier's `VERIFIER_HASH` and version.

- `program/`: the zkVM guest. Each mode repeats one primitive of the finality proof: SHA-256, key aggregation, key
  reads, the committee shuffle, the aggregate signature check.
- `script/src/bin/main.rs` (`bench`): M1, the cost of each primitive in execute mode. It counts cycles and prover gas
  and never proves.
- `script/src/bin/slice.rs` (`slice`): M4, proves one representative slice on a GPU or the prover network.
- `script/src/bin/bsc_fixture.rs` (`bsc-fixture`): M6's input, the recorded vote checked natively and written in the
  encodings EIP-2537 takes.
- `fixtures-bsc-vote.json`: a real BNB Chain finality vote with its validators' BLS keys, for M6.
- `evm/`: a Foundry project of its own (Prague, via-IR). M5 checks SP1's Groth16 verifier on its own v6 proof
  (`test/SP1VerifierGroth16V6.t.sol`); M6 checks the BNB Chain vote with the EIP-2537 precompiles
  (`src/BscVoteVerifier.sol`) and a storage proof of WBNB's slot 0 (`src/StorageProof.sol`).

## Running

The toolchain is SP1 6.8.1 (`sp1up`, into `~/.sp1`) and `protoc` (the build of `sp1-sdk` needs it).

```bash
export PATH="$HOME/.sp1/bin:$PATH" PROTOC=/path/to/protoc
# build gently: two jobs, lowest priority
CARGO_BUILD_JOBS=2 nice -n 19 cargo build --release
# M1: a minute of two cores
RAYON_NUM_THREADS=2 SP1_PROVER=cpu nice -n 19 ./target/release/bench
```

## M4, for the owner to run

`slice` refuses the CPU prover on purpose. Choose one:

```bash
# the Succinct prover network: an account key with PROVE for fees
SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... ./target/release/slice 900000
# a rented NVIDIA GPU (Linux, CUDA 12, Docker): SP1's CUDA prover
SP1_PROVER=cuda ./target/release/slice 900000
```

It prints the slice's prover gas (about 3B at 900,000 key additions) and the seconds it took. The network's invoice
for the request gives the price. Scaling both to P1's 36.6B prover gas, measured on mainnet data (`proofs/`), answers the
$50 and 60-minute thresholds. It has not been run yet, so both stay open (the record's "Where Phase 2 stands").
