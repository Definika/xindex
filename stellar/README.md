# Xindex on Stellar

The Stage B vault on Stellar and P1 and P2 there, as Soroban contracts, on the vault chains' shared Rust
(`../crates/xindex-core`). The rules are in `../design/2026-09-30-v4-stage-b-spec.md` (sections 4, 5.6, 7 and 10) and
what Stellar shares with the Ethereum side in `../design/2026-10-03-near-stellar-interfaces.md`.

| Path | What |
|---|---|
| `contracts/xindex-vault` | the vault: the twin of `src/vault/XindexVault.sol` and of Solana's vault, holding XLM |
| `contracts/p1-verifier` | P1: the light client of Ethereum advanced by SP1 proofs, the twin of `EthereumFinalityVerifier.sol` |
| `contracts/p2-verifier` | P2: the same light client advanced by RISC Zero proofs, the twin of `RiscZeroFinalityVerifier.sol` |
| `crates/xindex-soroban` | what the three share: `xindex_core::Crypto` over Soroban's host functions, and P1's and P2's light client |

## What the vault does

- Holds XLM for every index registered here, an index being a CREATE2 clone of the hub template by the factory on
  Ethereum (`register_index`).
- Takes XLM only as deposits to an intake (`deposit`), through the native asset's contract, whose address it computes
  itself. It keeps a book (`held`) and never reads its own balance.
- Pays out only on messages from Ethereum that P1 and P2 prove (`deliver`, one entry point for every kind, as on EVM):
  burns, intakes settled or failed, migrations, and the factory's governance. A message that moves coins or loosens a
  rule needs both proofs and a checkpoint covering its block (VLT-3); a freeze and a lowered cap may rest on one.
- Pays within 4% of an index's balance in any 24 hours, or the outflow floor; the rest stays owed (`release`,
  `release_migration`). A burn's or a claim's recipient is a Stellar account (`G…`) by its 32-byte key; an account that
  does not exist yet cannot take XLM, so its payout waits, as on Solana (SOL-5).
- A raised cap or floor, a new freezer and new verifiers wait `GOVERNANCE_DELAY` (7 days) before anyone applies them
  (`apply_change`), and the freezer may cancel a raise or a rotation, never its own replacement (VLT-2). Only a message
  on both proofs moves a kind's nonce mark (VLT-4).
- Keeps a checkpoint both verifiers prove (`advance_checkpoint`); a week without one stalls the vault, which then takes
  no deposit. In a stall the recovery proposer may propose a successor pair (`propose_successor`), which after 30 days
  and at most two vetoes anyone adopts (`adopt_successor`); only a checkpoint that ends the stall lapses it (LG-2), and
  the last message a successor must prove is the last on both proofs (LG-3). 180 days into a stall the last checkpoint
  becomes the snapshot (`begin_snapshot`): holders claim their share by an EIP-712 signature or to their recovery key
  (`claim_snapshot`), open intakes resolve from the hub's mark (`resolve_intake`), and burns and migrations the hub
  marked sent are paid (`deliver_recorded`), each reading the hub's storage under the snapshot's state root.
- Shows its own state to Ethereum through `attest(slots, values)`: it succeeds only if each slot of the map the hub
  reads holds its value, and emits one event, topics `[Symbol("attest")]`, data the bytes of
  `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`. A successful `attest` in a final ledger is what
  Stellar's state verifier on Ethereum proves.

## Ownerless and immutable

- The constructor fixes every setting at deployment, atomically: nobody can take the configuration in front of the
  deployer. No function replaces any contract's Wasm, and nothing has an admin.
- Deploy every contract with a plain Wasm executable, never behind an executable reference (CAP-0085), whose owner
  could change its code. Nothing on chain can tell the two apart, since an address's executable resolves through the
  reference, so check the instance entry before registering the vault.
- The vault pins P1's and P2's code by hash when it takes them, at deployment, a rotation or an adoption, and refuses a
  verifier that no longer runs it (`VerifierChanged`), whether its code was replaced or its reference moved: the twin of
  Solana's SOL-2. A verifier upgraded under the vault stalls it until a successor is adopted, rather than taking its
  coins.
- The freezer is a Stellar account (`NotAnAccount`), not the zero key, whose own signers and thresholds may make it a
  multisig; it should not be the deploying key, which the constructor cannot see. The recovery proposer must be a
  contract (`NotAContract`): a Stellar account's signers cannot be read from a contract, so an account could not be
  shown to be a multisig. An account and a contract are never one address, so the two roles are distinct by their
  kinds, with no check of their own.
- P1's and P2's refusals are numbered from 101, the vault's from 1, so a refusal that reaches a caller through the
  vault names its source.
- Two chain-level powers remain over any Soroban contract, which no contract can remove: a validator vote may freeze a
  ledger key (CAP-0077), blocking access to the vault's entries though not taking them, and a protocol upgrade may amend
  state, as CAP-0076 once did.

## Storage and TTLs

- The vault's settings and any successor under review live in its instance storage; every index, intake, deposit,
  owed payout, used message mark and attested slot in a persistent entry of its own. Nothing is temporary storage.
- Each persistent entry is extended to the network's maximum TTL when written, and the instance on every call that
  writes it. Anyone can extend any entry further, and a keeper should, as one keeps the checkpoint fresh: the instance,
  the code, the native asset's balance entry for the vault, and the entries of every live index and owed payout.
- An archived persistent entry is never lost: a transaction that reads it restores it (protocol 23's automatic
  restore), or fails. So a used mark cannot lapse into a second delivery, and nothing a holder needs is archived beyond
  restore.

## Build and test

stellar-cli 28 and its Rust (1.98.1, `rust-toolchain.toml`, with `wasm32v1-none`); soroban-sdk 28 builds a contract
only through `stellar contract build`. Builds run at the lowest priority on one job.

```bash
cd stellar
CARGO_BUILD_JOBS=1 nice -n 19 stellar contract build          # target/wasm32v1-none/release/*.wasm
CARGO_BUILD_JOBS=1 nice -n 19 cargo test                       # the real host on the built Wasm: build it first
cargo fmt --all --check && CARGO_BUILD_JOBS=1 nice -n 19 cargo clippy --all-targets -- -D warnings
```

The tests load the Wasm from `target/`, so a change to a contract needs `stellar contract build` before `cargo test`.

The tests run the built Wasm on Soroban's real host, under mainnet's invocation limits (400M instructions, 132 KB of
writes, 16 KB of events), with the native asset's own contract and accounts holding real XLM. P1 and P2 run on their
own Groth16 fixtures (SP1 v6's and RISC Zero's v3.0 receipt), real mainnet receipts, and receipts shaped as LG-1's;
the vault runs with mock verifiers, which accept a claim only with the keccak of that claim, and once against the real
P1 and P2. The snapshot exit reads a real hub's storage: `contracts/xindex-vault/tests/fixtures/generate.py` runs the
repository's factory and hub on anvil under Stellar testnet's registry id and records `eth_getProof`, and `attest.py`
computes `attest`'s record and the hub's slot keys with `cast`.

## Costs and limits

Each contract is a plain Wasm file well under the 128 KiB a contract's code may take: the vault 61,195 bytes, P1 20,443
and P2 20,832. A transaction may spend 400M instructions and be 132,096 bytes long. Measured on the host by the tests
(`--nocapture` prints them):

| Call | Instructions | Argument bytes |
|---|---|---|
| P1 `update`'s proof check (SP1 v6 Groth16) | 31.0M | 356-byte proof |
| P2 `update`'s proof check (RISC Zero v3.0 receipt) | 31.1M | 260-byte seal |
| `verify_event`, three real mainnet receipts | 0.82M to 0.94M | 1,375 to 2,157 |
| `verify_event`, 513 logs / 2,001 logs / a 70,492-byte leaf (LG-1) | 3.1M / 10.3M / 4.7M | up to 70.6 KB |
| `verify_checkpoint` | 0.53M | |
| vault `advance_checkpoint` through the real P1 and P2 | 2.1M | |
| vault `deposit`, `deliver` (mock proofs), `release`, `attest` of 3 slots | 0.9M to 2.0M | |
| vault `claim_snapshot` by signature / to a recovery key, on real hub proofs | 5.8M / 2.8M | 3.8 KB |
| vault `resolve_intake`, `deliver_recorded` | 2.0M | 1.2 to 1.4 KB |

The hub's proofs come from anvil, whose tries are shallow; mainnet's are a few times larger, still a small part of a
transaction.

One limit binds: `deliver` carries both proofs of a message's receipt, so a receipt whose proof exceeds about 65 KB
cannot be delivered in one transaction, though each verifier accepts its proof alone (LG-1's 70 KB leaf). A message
sent by a permissionless call can be made that large by anyone: `HybridHub.claimOrder`, which sends `INTAKE_SETTLED`,
called from a contract that also emits some 65 KB of log data, leaves that intake open here, its depositors unable to
take a refund. The factory's executions are permissionless too. Such a message waits on Stellar until the shared design
gives it a path of bounded size, such as the hub's own mark of the message proven in its storage at a checkpoint, as
`deliver_recorded` already reads it after a snapshot.

## Deploying

1. Deploy P1 and P2 with their constructors: P1 with `p1 vkey`'s program key, P2 with `p2 image-id`'s image id, both
   with the same anchor and epoch (`p1-input check-state`) and the beacon genesis time (1606824023 on mainnet,
   1655733600 on Sepolia). Each must then be advanced within a day, and daily after (LG-4).
2. Deploy the vault with its constructor: the indexes' chain id, Stellar's registry id
   (`design/2026-10-03-near-stellar-interfaces.md`), the factory and the hub template, the freezer's account, the
   recovery proposer's contract, XLM's cap and floor in stroops, and P1 and P2.
3. On Ethereum, the factory's owner proposes the chain with the vault's contract id as its 32-byte vault, and Stellar's
   state verifier.
