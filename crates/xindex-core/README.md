# xindex-core

What every vault chain's Rust programs share, taken from the Solana programs, which now run on it: Ethereum's
encodings and proofs, P1's and P2's Groth16 checks, the light client's rules, and the vault's messages, digests, speed
limit, checkpoint rules and snapshot reads. The rules are the Stage B spec's (`../../design/2026-09-30-v4-stage-b-spec.md`,
sections 4, 5.6, 7 and 10), the twins of `src/verifiers/FinalityVerifier.sol`, `src/vault/XindexVault.sol` and
`src/vault/VaultSnapshot.sol`.

`no_std` with `alloc`, and no dependency in an on-chain build, so the same code builds for Solana's SBF (rustc 1.89 in
platform-tools v1.54), NEAR's Wasm and Soroban's Wasm. Nothing here touches a chain's accounts, storage, coins, clock or
events: each program keeps those, passes `now` in, and gives its cryptography as a `Crypto`.

## The `Crypto` trait

A chain implements it once over its host functions, converting at that boundary where its encoding differs (NEAR packs
alt_bn128 points little-endian with the real part first; Soroban takes host objects):

| Method | Input | Output |
|---|---|---|
| `keccak256(parts)` | slices, hashed as one | 32 bytes |
| `sha256(parts)` | slices, hashed as one | 32 bytes |
| `bn254_g1_add` | `a ++ b`, two G1 points (EIP-196) | the G1 point `a + b` |
| `bn254_g1_mul` | `p ++ s`, a G1 point and a 32-byte scalar | the G1 point `s * p` |
| `bn254_pairing_check` | G1 then G2, 192 bytes a pair (EIP-197) | whether the product is one |
| `secp256k1_recover` | hash, recovery id 0 or 1, `r ++ s` | the public key `x ++ y` (64 bytes) |

A G1 point is `x ++ y` and a G2 point `x_im ++ x_re ++ y_im ++ y_re`, each coordinate 32 bytes big-endian, the point at
infinity zero: Ethereum's precompiles' encodings. Solana's implementation is `ethereum_verifier::Solana`, over its
syscalls. The `native` feature (on by default, off in every on-chain build) gives `native::Native`, over the crates
Solana's syscalls fall back to off-chain (`sha3`, `sha2`, `k256`, `solana-bn254`'s arkworks code), for host tests.

## Modules

| Module | What |
|---|---|
| `crypto` | the `Crypto` trait |
| `rlp`, `mpt` | RLP read in place, and Merkle-Patricia proofs, absence included |
| `event` | the headers tree, a receipt's log, and the proof formats P1's and P2's verifiers read |
| `light_client` | `FinalityVerifier`'s rules: the anchor's step, the day's lag (LG-4), a log's and a checkpoint's checks |
| `groth16`, `sp1`, `risc0` | BN254 Groth16 over `Crypto`, SP1 v6's check (P1) and RISC Zero v3.0's (P2), with their keys |
| `abi` | the `VaultMessages` payload, the index and intake digests, the log data, an index's CREATE2 address |
| `constants` | the vault's rules and Ethereum-side ids, byte for byte the EVM vault's |
| `speed` | the speed limit's hourly buckets |
| `checkpoint` | checkpoints, the stall, and which messages need both proofs (`_needsBoth`) |
| `state_reader` | an account's storage under a state root, from `eth_getProof` (`EthereumStateReader`) |
| `snapshot` | a holder's snapshot claim: the hub slots it reads, its share, its EIP-712 digest and signature |

## Build and test

```bash
cargo test                       # the native Crypto, on the repository's real fixtures
cargo fmt --check && cargo clippy --all-targets
cargo build --target wasm32-unknown-unknown --no-default-features   # as NEAR and Soroban build it
```

The tests read the repository's own fixtures: `test/fixtures/ethereum/receipts.json` (real mainnet receipts), SP1 v6's
Groth16 fixture (`prototype/evm/test/SP1VerifierGroth16V6.t.sol`), RISC Zero's v3.0 receipt and the vendored verifier's
constants (`vendor/risc0-ethereum`), and a real hub's storage
(`solana/programs/xindex-vault/tests/fixtures/hub.json`). The Solana programs' own suites, LiteSVM included, check that
the programs run this code unchanged in behaviour.
