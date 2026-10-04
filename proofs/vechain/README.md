# The VeChain state proof

A vault's storage on VeChain, proven to Ethereum (`../../design/2026-10-04-four-chains-interfaces.md`): SP1 proofs that
`../../src/verifiers/VeChainStateVerifier.sol` checks. VeChain runs `XindexVault` unchanged; a slot is proven as on
TRON, by a successful call of the vault's `attest(slots, values)`, which reverts unless every slot holds its value. Its
own workspace, as `../cometbft` and `../near` are.

| Crate | What |
|---|---|
| `statement` | `xindex-vechain`: the statement in plain Rust, tested natively on mainnet's own data, with `testkit` for synthetic chains |
| `program` | the SP1 program: reads an input, checks it, commits the public values |
| `script` | the host, `vechain`: `execute` (execute mode, prover gas), `vkey`, and `prove` on a GPU or the prover network |
| `fixtures` | `generate.py`, which fetches `mainnet.json` from mainnet's public REST API and builds `synthetic.json`, checked with a separate Python implementation (`vechain_py.py`, `secp256k1.py`, `keccak.py`) |

## What VeChain's finality rests on, and how it is followed

**VIP-220, since Hayabusa (VIP-253).** vechain/thor's `bft` package (`engine.go`, `justifier.go`): blocks come in rounds
of 180. A round is *justified* when the distinct signers of its blocks hold more than two thirds of the weight
(`Σ > total * 2 / 3`, in whole VET), and *committed* when those who voted COM in every block they signed in the round
do; a signer voting both ways in one round counts as not voting COM. At a committed round's last block thor finalizes
the checkpoint (first block) of the last justified round before it. So a block at or before the checkpoint of a
justified round `k` is final once a later round `r` is committed: the checkpoint thor finalizes then is round `k`'s or a
later one. Since Galactica a header's signing hash covers its COM vote (the extension `[alpha, COM, baseFee]`); the
statement writes every header with its base fee, so a header without one, or any field changed, links nowhere.

**The weights are the Staker's, and VeChain proves none of its state.** Each vote weighs the signer's `Weight` in the
builtin Staker (`0x…5374616b6572`), and the threshold is two thirds of its total locked weight, both read from the round
checkpoint's state. That state lives only in the Staker's storage: the REST API serves no Merkle proof, and thor's
peer protocol has no state sync, so only a node's database holds the trie nodes. Nor do events carry the weights: they
change at a round's first block, in native housekeeping that logs nothing (renewals, activations, exits, evictions after
offline tracking), so following them from receipts would mean replaying the Staker and the proposer schedule from every
receipt of every block.

**So the weights are attested, as the vault's slots are.** `../../src/vault/VeChainStakerAttester.sol`, deployed with
the vault and owned by no one, has `attest(table)`, which reverts unless the Staker's total weight and active validators
with their weights, in list order, hash to `table` (a keccak chain, below). The weights change only at a round's first
block, before its transactions run (`consensus/validator.go`: `SyncPOS`, then the transactions), so a successful
`attest` anywhere in a round attests that round's table: thor's own comment says the checkpoint's post-housekeeping
weights are each block's. The statement proves such a transaction, as it proves the vault's, and trusts the table once
blocks after it are signed by validators holding more than two thirds of the weight of a table the verifier already
trusts: an honest one of them executed the attesting block, as every VeChain node does before building on it. That is
how TRON's verifier trusts a new producer list. The simulated run on mainnet's Staker gave the hash the statement
computes from the Staker's views (`../../test/VeChainStakerAttester.t.sol` pins three real tables of 101 validators).

Every table the verifier uses, the trusted one included, is no more than a day old (`MAX_LAG`): nothing slashes a VeChain
validator, so keys retired or leaked later could sign at no cost.

## The statement

Two claims, each from a table the verifier trusts, keyed by the id of the block it was read at (`statement/src/lib.rs`).
Each starts with a chain of headers, each the parent of the next, all after the trusted block: every signer recovered
with secp256k1 from the header's blake2b signing hash (a high-`s` signature normalized, as libsecp256k1 accepts it), and
every id recomputed, `number ++ blake2b(signingHash ++ signer)[4:]`.

**The chain is not linked to the trusted block** (B6-09). "After the trusted block" is a comparison of numbers: the first
header's number must exceed the one in `trustedId`, and its parent id is compared with nothing, since the chain may begin
many blocks later. Nor is the genesis id tied to the headers beyond the transactions' chain tag (one byte) and the
trusted table's signer keys. What makes the chain VeChain's is the vouching alone: the signers of the blocks after an
attested block hold more than two thirds of the trusted table's weight, so an honest one of them executed that block
(`attested` in `statement/src/lib.rs`). The soundness argument is that quorum, with honest validators executing every
block they build on, and nothing in the statement checks a link back to the trusted block. A change that vouched from
another slice of the chain, or that counted the attesting block's own signers, would not be caught by any link check, so
it must keep the quorum over exactly the blocks after the attested one.

- **update**: a new table, attested in its block by a successful `attest(table)` call of `VeChainStakerAttester`, and
  vouched for by the trusted table: the signers of the blocks after it hold more than two thirds of the trusted weight.
  The verifier then trusts the new table, keyed by its block's id and dated by its block's time.
- **slots**: the vault's `attest(slots, values)` succeeded in block `Y`; the tables of rounds `k` and `r > k` are
  attested in those rounds and vouched for as above; round `k` is justified under its table, round `r`, whose 180 blocks
  are all in the chain, committed under its own; and `Y` lies at or before round `k`'s checkpoint. The claim gives `Y`'s
  number and time.

**A call** is proven in its block as TRON's verifier proves one, by writing it: the statement writes the transaction's
leaf (`Transaction.MarshalBinary`, legacy or type `0x51`) from typed fields with exactly one clause, the vault or the
attester, no value, and the calldata the statement computes; and the receipt's leaf, typed as the transaction, with
`reverted` false and one clause's empty outputs `[[[], []]]` (a view logs nothing). Both are found under the block's
`txsRoot` and `receiptsRoot` at the key `rlp(index)`, by Merkle-Patricia paths hashed with blake2b (`trie.DeriveRoot`).
A transaction's chain tag must be the genesis id's last byte. Only `reserved`'s features word is taken, as consensus
refuses any other reserved field.

**A table** is `h0 = keccak256(abi.encode(totalWeight))`, then `h = keccak256(abi.encode(h, validator, weight))` for each
active validator in the Staker's list order, weights in wei as the Staker returns them, each below 2^100.

**Public values.** One program, two claims, told apart by the first word:

```text
update: abi.encode(UPDATE, chain, attester, trustedId, trustedTable, id, table, time)                   8 words
slots:  abi.encode(SLOTS, chain, attester, trustedId, trustedTable, number, time, vault,
                   keccak256(abi.encode(slots, values)))                                                 9 words
```

`UPDATE = keccak256("xindex.v4.vechain.update")`, `SLOTS = keccak256("xindex.v4.vechain.slots")`; `chain` is the genesis
id (mainnet's `0x00000000851caf3c…1b4a`, which VeChain's `CHAINID` returns, checked live); times are seconds. The contract
checks the claim, the chain, the attester, the trusted table (the latest for an update, any it trusts for slots) and its
age, that no block is dated after its own, the vault, and the slots and values the caller gives.

## What a prover, and anyone keeping the verifier, must do

- **Attest the tables.** Send a transaction whose one clause is `VeChainStakerAttester.attest(table)`, with no value,
  in each round a proof uses (about 732,000 gas, simulated on mainnet: about 7.3 VTHO at its base fee of 10^13 wei a
  gas): one in a round for an update, one in each of rounds `k` and `r` for slots. Read the table first from the
  Staker's views at that block; it changes whenever a round's housekeeping changes a weight.
- **Attest the slots.** Send the vault's `attest(slots, values)` the same way, in a block of round `k - 1` or at round
  `k`'s checkpoint, then the two tables' in rounds `k` and `k + 1`; the proof can be made an hour to 90 minutes later,
  once round `k + 1` ends and enough blocks follow its table's call.
- **Update daily.** An update from the latest table within a day of its block, or the verifier stops for good.
- **Data**: headers (`/blocks/{n}?raw=true`), transactions (`/transactions/{id}?raw=true`), receipts (`/blocks/{id}?
  expanded=true`) and the Staker's views (`POST /accounts/*?revision=`), all on any public node.

## Build and test

Rust 1.98.1 (`rust-toolchain`), SP1's toolchain (`sp1up`, SP1 6.8.1) and `protoc`, as `../README.md`. Gently:

```bash
cd proofs/vechain
CARGO_BUILD_JOBS=1 cargo test --release -p xindex-vechain           # the statement, natively: mainnet's data and test chains
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings
CARGO_BUILD_JOBS=1 cargo build --release -p xindex-vechain-script   # builds the program for SP1 too
./target/release/vechain execute                                     # both synthetic claims, in execute mode
./target/release/vechain vkey                                        # VeChainStateVerifier's PROGRAM_KEY
SP1_PROVER=network NETWORK_PRIVATE_KEY=0x... ./target/release/vechain prove slots input.json proof.json
```

`fixtures/generate.py` needs only Python 3's standard library:

- `generate.py mainnet` fetches the headers from 60 blocks before the latest finalized checkpoint `k * 180` to past
  the end of round `k + 1`, re-encodes each to its own bytes, recovers its signer and recomputes its id; reads the
  Staker's tables in rounds `k - 1`, `k` and `k + 1`; checks that round `k` is justified and `k + 1` committed as thor
  counts, which is why the API finalized `k * 180`; and finds a real successful one-clause call, standing in for `attest`,
  whose transaction and receipt it proves under its block's roots. No vault or attester exists on VeChain yet.
- `generate.py synthetic` builds the claims end to end on a SYNTHETIC chain: 101 validators with test keys and weights
  of mainnet's spread, 371 blocks, the attester's and the vault's calls among other transactions, two validators voting
  both ways in round `r`, and the public values the program must commit, which `test/VeChainStateVerifier.t.sol` uses.
- `generate.py anchor <out.json>` writes a deployment's first table: the latest finalized checkpoint, its time, and the
  Staker's table there.

The tests break each check on the real data and on test chains (`testkit`): a quorum of exactly two thirds, a signer
voting both ways, the attesting block vouching for itself, the vault's call after the checkpoint, a round one block
short, a table counted in the wrong round, and more; 18 mutants of the statement are each killed by one.

## Measured

On mainnet's data of 4 October 2026 (101 validators, round `k` justified by 64 of them, round `k + 1` committed by 72 COM
voters, the three rounds' tables equal) every header, table and the stand-in call verify natively. SP1 6.8.1's execute
mode ran the synthetic update in 26.98 million instructions (33.83 million prover gas) and the slots claim in 28.02
million (34.84 million), over 371 headers each, committing exactly the public values `generate.py` computed. On
Ethereum, with the Groth16 check mocked, a two-slot `verifySlots` costs 45,221 gas as a transaction (16,809 of it
execution) and an `update` 88,376 (62,660); SP1's Groth16 verifier adds about 230,000 to each. The key a local build
prints is the tests'; a deployment's comes from SP1's reproducible Docker build.
