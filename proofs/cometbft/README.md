# The CometBFT state proof

A vault's storage on a CometBFT chain with an EVM, Injective's first, proven to Ethereum
(`../../design/2026-10-04-four-chains-interfaces.md`): SP1 proofs that `../../src/verifiers/CometBftStateVerifier.sol`
checks. Injective runs `XindexVault` unchanged, so the hub reads the vault's own slots, as on BNB Chain; only the proof
of them differs. Its own workspace, as `../near` and `../stellar` are.

| Crate | What |
|---|---|
| `statement` | `xindex-cometbft`: the statement in plain Rust on tendermint-rs and ics23, tested natively on mainnet's own data |
| `program` | the SP1 program: reads an input, checks it, commits the public values |
| `script` | the host, `cometbft`: `execute` (execute mode, prover gas), `vkey`, and `prove` on a GPU or the prover network |
| `fixtures` | `generate.py`, which fetches `injective.json` from mainnet's public endpoints and checks it with a separate Python implementation (`cometbft_py.py`) |

## The statement

Two claims, each from a header the verifier already trusts (`statement/src/lib.rs`):

- **update**: light-client hops from the verifier's latest trusted header to a later one, which it then trusts;
- **slots**: hops from any trusted header to header `H+1`, then ICS-23 proofs of the vault's slots under `H+1`'s
  `app_hash`, which commits the state after block `H`. The claim gives block `H`'s height and time, as the EVM dated it.

**Hops.** Each hop is tendermint-rs's `ProdVerifier::verify_update_header`, the check IBC's SP1 Tendermint client runs,
on tendermint-rs 0.40.4, with the trust threshold raised from ibc-go's third to two thirds:

- an adjacent header's set must be the trusted header's next set, and more than two thirds of it must sign;
- a skipping header must be signed by more than two thirds of the trusted header's next set's power, and of its own
  set's. So a forged header always needs more than two thirds of a set the verifier already trusts, as the BNB
  verifier requires, never merely a third.

The rest is tendermint-rs's: the chain id is the trusted header's, heights and times rise, each validator set hashes to
what its header names (decoding checks every address against its key), the commit is for the header's hash, and each
ed25519 signature on the canonical precommit is checked and counted once. The trusted header's next set must hash to its
`next_validators_hash`, which tendermint-rs leaves to its caller, and every hop before the last must bring its next set.
The chain id must be the one the proof commits (`keccak256("injective-1")`). Each set is trusted for `MAX_LAG`, a day,
timed from the last header of the proof; the contract times the trusted header against its own clock.

**State.** Injective's `x/evm` is an Ethermint fork (`InjectiveLabs/sdk-go` `chain/evm/types/key.go`): a contract's slot
is the key `0x02 ++ address ++ slot` of the `evm` store. `abci_query` with `prove` at height `H` returns two ICS-23
operations, `ics23:iavl` (the key under the `evm` store's root) and `ics23:simple` (`evm` under the multistore root, the
`app_hash` of header `H+1`), which ics23 0.12.0 checks with `iavl_spec` and `tendermint_spec`. A present key is an
existence proof; an absent one a non-existence proof, its two neighbours adjacent; nothing else (no batch) is taken. The
keeper writes a slot as the full 32 bytes (`SetState(..., value.Bytes())`) and reads it with `common.BytesToHash`, which
the statement copies; an absent key reads as zero. `generate.py` checks every value against `eth_getStorageAt` at block
`H`, and that the EVM's block `H` is CometBFT's height `H`, dated by its header's time in whole seconds.

**Public values.** One program, two claims, told apart by the first word:

```text
update: abi.encode(UPDATE, keccak256(chainId), trustedHeight, trustedHash, trustedTime, height, hash, time)  8 words
slots:  abi.encode(SLOTS, keccak256(chainId), trustedHeight, trustedHash, trustedTime, height, time, vault,
                   keccak256(abi.encode(slots, values)))                                                    9 words
```

`UPDATE = keccak256("xindex.v4.cometbft.update")`, `SLOTS = keccak256("xindex.v4.cometbft.slots")`; times are whole
seconds; in the slots claim the height and time are block `H`'s. The contract checks the claim, the chain id, the
trusted header (the latest for an update, any it trusts for slots), its age against `MAX_LAG`, that no header is dated
after its own block, the vault, and the slots and values the caller gives.

## Trust

A forged header needs more than two thirds of a trusted set's power: of Injective's 45 permissionless validators, the
top 15 hold two thirds today. Both slashing fractions read 0 (`sentry.lcd.injective.network`, 4 October 2026; the
unbonding time is 21 days), so
signing a fork costs them nothing, as on TRON and Stellar; the day a set stays trusted bounds the keys that can sign, so
keys retired or leaked later sign nothing the verifier takes. The first header comes from the deployer and is checked
during the chain registry's delay; every later one is proven. A verifier left a day behind its latest header stops for
good, and the factory rotates in a new one behind its 30-day `ROTATION_DELAY`.

## Data, and what a prover must run

- **Headers, commits and validator sets**: `/commit` and `/validators?height=` on CometBFT's RPC. The public sentry
  (`https://sentry.tm.injective.network`) keeps about 100,000 blocks (about 17 hours at 0.6 s).
- **State proofs**: `abci_query` with `prove=true` at `H`. The sentry serves them for only about the last 100 blocks,
  Polkachu (`https://injective-rpc.polkachu.com`) for about 8 hours; an update needs none.

A prover therefore runs its own Injective node (`injectived`, CometBFT RPC on), keeping recent application state for
at least the window in which it may still need to prove a slot (a day is about 144,000 blocks of `pruning-keep-recent`;
no proof can start from a header older than a day anyway), and proves a slot soon after the block it reads. It advances
the verifier with an `update` well within each day, or the verifier stops for good. Proving runs on SP1's prover
network or a GPU (`SP1_PROVER=network` or `cuda`); the host refuses this machine's CPU, as P1's does.

## Build and test

Rust 1.98.1 (`rust-toolchain`), SP1's toolchain (`sp1up`, SP1 6.8.1) and `protoc`, as `../README.md`. Gently:

```bash
cd proofs/cometbft
CARGO_BUILD_JOBS=1 cargo test --release -p xindex-cometbft          # the statement, natively, on mainnet's data
cargo fmt --all --check && cargo clippy --all-targets
CARGO_BUILD_JOBS=1 cargo build --release -p xindex-cometbft-script  # builds the program for SP1 too
./target/release/cometbft execute                                    # both claims, in execute mode
./target/release/cometbft vkey                                       # CometBftStateVerifier's PROGRAM_KEY
SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... ./target/release/cometbft prove slots input.json proof.json
```

`fixtures/generate.py` (`uv run --with pynacl --with pycryptodome python3 generate.py`) fetches a fresh fixture
read-only: a trusted header 3,000 blocks back and its next set, a skipping hop to `H` across validator-set changes, an
adjacent hop to `H+1`, block `H`'s header, and two slots of a real contract at `H`, one present and one absent. It checks
every header hash, set hash, signature, voting power and ICS-23 path with its own implementation, and every value
against `eth_getStorageAt`, then writes the public values the statement must commit. The public endpoints keep proofs
briefly, so a regenerated fixture is a different chain; the tests read every value from the file. `generate.py anchor
<out.json>` writes a deployment's anchor: the latest header with a canonical commit, its hash checked against the commit,
its height and time, and the chain ids.

## Measured

On the fixture of 4 October 2026 (45 validators, a skipping hop of 3,000 blocks across validator-set changes, then an
adjacent hop), SP1 6.8.1's execute mode ran the update in 6.07 million instructions (6.63 million prover gas) and the
two-slot claim in 6.66 million (7.19 million), committing exactly the public values `generate.py` computed. On
Ethereum, with the Groth16 check mocked, a two-slot `verifySlots` costs 42,137 gas as a transaction (14,721 of it
execution) and an `update` 63,039 (38,139); SP1's Groth16 verifier adds about 230,000 to each. The key printed by a
local build is the tests'; a deployment's comes from SP1's reproducible Docker build.

The negative tests break each check on the real data, and on chains of generated keys (`tendermint-testgen`) where a
set can sign anything: a new set every member of which signed, but holding only two thirds of the trusted set's power,
is refused, where ibc-go's third would take it.
