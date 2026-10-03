# Xindex vault on NEAR

The NEAR twin of `src/vault/XindexVault.sol` and of the Solana vault (`solana/programs/xindex-vault`). It holds NEAR
for every index whose shares live on Ethereum. Coins enter only as deposits to an intake. They leave only on messages
that P1 (SP1) and P2 (RISC Zero) prove final on Ethereum, within the 4%-a-day speed limit. Ethereum learns the vault's
state through `attest` and the NEAR state verifier. The chain ids, the vault id, the recipient encoding, the slot map
and `attest`'s exact output are fixed in `design/2026-10-03-near-stellar-interfaces.md`.

Status: built and tested on near-sdk's mocked runtime and on the nearcore sandbox (2.13.4, protocol 86). Not deployed
anywhere.

## Build and test

The toolchain is Rust 1.98.1 (`rust-toolchain.toml`) with the `wasm32-unknown-unknown` target. The sandbox tests fetch
nearcore's sandbox binary through near-workspaces on first use.

```bash
cd near
CARGO_BUILD_JOBS=1 cargo build -p xindex-vault-near --target wasm32-unknown-unknown --release   # the contract, first
CARGO_BUILD_JOBS=1 cargo test -p xindex-vault-near -- --test-threads=1   # unit tests, then the sandbox on that Wasm
cargo fmt --check
cargo clippy -p xindex-vault-near --all-targets -- -D warnings
cargo clippy -p xindex-vault-near --target wasm32-unknown-unknown --release -- -D warnings
```

- `.cargo/config.toml` sets `--cfg near` for the Wasm target, as `cargo near build` does. Without it, near-sdk compiles
  its off-chain fallbacks into the contract. Hashing then runs in pure Rust instead of on the host's keccak256 and
  sha256, and every refusal traps as `unreachable` with its error's name lost. The sandbox tests fail that way.
- The sandbox tests read `target/wasm32-unknown-unknown/release/xindex_vault_near.wasm`, so build it before testing.
- `cargo test -- --nocapture` prints every method's gas.

The core it builds on is `crates/xindex-core`, and its gates are in `crates/xindex-core/README.md`. A change to the
core is also checked against Solana's tests.

## Layout

- `contracts/xindex-vault/src/lib.rs`: the contract: its methods, storage and every rule.
- `src/crypto.rs`: `Near`, the core's `Crypto` over NEAR's host functions: keccak256, sha256, alt_bn128 and ecrecover.
- `src/types.rs`: arguments, views and stored records. Also `account_of` (a 32-byte recipient → its implicit account)
  and `is_implicit`.
- `src/errors.rs`: the errors, with the EVM vault's names where they exist. A refusal reads `XindexVault: <Name>`.
- `src/tests/`: unit tests on near-sdk's mocked runtime, which runs nearcore's own host functions.
- `tests/sandbox.rs`: the release Wasm on the sandbox.
- `tests/fixtures/`: `hub.json`, a real hub's storage, and `generate.py`, which writes it.

## Methods

Anyone may call every method except the role-gated ones (freezer, recovery proposer) and the vault's own callbacks. A
method that adds storage takes a deposit to pay for it and refunds the change.

| Method | What it does |
|---|---|
| `new(config)` | Initialization: P1 and P2 configurations, freezer, recovery proposer, cap and floor. Run once, or written as the initial state of a deterministic account. |
| `register_index(index, salt)` | Registers a clone of the factory's `HybridHub` template, checked by the CREATE2 formula. |
| `deposit(index, intake_id, amount)` | Attaches `amount` yoctoNEAR plus storage. The deadline is in the id's top 64 bits; the deposit must come before it and within `MAX_INTAKE_LIFE`. Refused under the cap, in a freeze or in a stall. |
| `refund(index, intake_id)` | The depositor takes back its deposit to a failed intake. |
| `deliver(payload, block, proof1, proof2)` | Runs a `VaultMessage` on P1's proof, P2's or both. Anything that moves coins or loosens a rule needs both, plus a checkpoint covering its block. |
| `release(index, id)` | Pays what the speed limit now allows of an owed burn, claim or migration. |
| `freeze()` | Freezer only, before a snapshot: freezes for 14 days. |
| `apply_change(kind, body)` / `cancel_change(kind)` | A raised cap or floor, a new freezer or new verifiers wait `GOVERNANCE_DELAY`. The freezer may cancel all but its own replacement. |
| `register_verifier(config)` | Adds an Ethereum light client, keyed by the hash of its configuration. |
| `update_verifier(id, public_values, proof)` | Advances a light client with an SP1 or RISC Zero Groth16 proof. Refused a day after the anchor's epoch (LG-4). |
| `advance_checkpoint(checkpoint, proofs)` | A final Ethereum block, proven by both P1 and P2. |
| `propose_successor(p1, p2, continuity)` | Recovery proposer only, while stalled. The new pair must prove the last checkpoint, a recent one and the last message. |
| `veto_successor()` | Freezer only, at most twice per stall. |
| `adopt_successor(checkpoint, proofs)` | After 30 days of review, on a recent checkpoint from the new pair. |
| `begin_snapshot()` | 180 days into a stall: the last checkpoint becomes the snapshot, and its state root goes to slot 25. |
| `claim_snapshot(index, holder, component, recipient, signature, proof)` | Pays a holder's share at the snapshot. Goes to the recipient its EIP-712 signature names, or to its registered recovery address. |
| `resolve_intake(index, intake_id, proof)` | Settles or fails an open intake from the hub's `_settledIntakes` at the snapshot. |
| `deliver_recorded(payload, proof)` | Runs a burn or migration in flight at the snapshot, from the hub's `_sentMessages`. |
| `attest(slots, values)` | Succeeds only if every slot holds its value. Returns `abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestampNs, slots, values)` as the receipt's value, with nothing logged. |
| `on_payout` / `on_refund` | `#[private]`: when a transfer fails, puts its amount back on the book. |
| Views | `config`, `index_state`, `intake`, `deposited`, `owed`, `verifier`, `range`, `used`, `slot`, `stalled`, `stall_start`. |

## Storage

`STATE` is the borsh of `Vault`, the settings and every scalar. Each collection sits under its own one-byte prefix
(`Key`), followed by the borsh of its key:

| Prefix | Collection | Key → value |
|---|---|---|
| 0 | `verifiers` | verifier id → light client (system, key, anchor, epoch, genesis time) |
| 1 | `ranges` | (verifier id, headers root) → the blocks a proof covered |
| 2 | `indexes` | index → balance, paid total, outflow buckets, digest |
| 3 | `intakes` | (index, intake id) → state, total, digest |
| 4 | `deposits` | (index, intake id, depositor) → yoctoNEAR |
| 5 | `owed` | (index, message or claim id) → recipient or new index, remaining |
| 6 | `used` | message ids delivered |
| 7 | `slots` | the hub's slot key → the value `attest` vouches for |

The vault never reads its own account balance, because NEAR credits plain transfers and gas rebates silently. `held`
is a book of every yoctoNEAR it accounts for.

## No owner, no key

The code has no method that deploys code, adds a key or calls the vault's own account, other than the two private
callbacks. Deployment uses NEP-616 (live since protocol 82):

1. `DeployGlobalContract` publishes the Wasm in `CodeHash` mode. Code published under its hash can never change.
2. `DeterministicStateInit` creates the account `0s` ++ hex(`keccak256(borsh(state_init))`[12..]). Its `state_init`
   names that code hash, and its data is the vault's initial storage: `STATE` and the two light clients. `Vault::build`
   computes that data exactly as `new` would.

The account is fully determined by its code and initial state, and has no access key. Nobody can sign for it, and
nothing can change its code. `tests/sandbox.rs` deploys it this way and checks that the account has no key and that its
`config().vault_id` is `keccak256("0s…")`.

The vault id, `keccak256(utf8(account_id))`, is computed from the running account each time and never stored. A
deterministic account's initial state cannot contain its own id, because the id is a hash of that state.

The recovery proposer must be the owner's emergency multisig. The vault refuses an implicit account (ed25519 or
ETH-implicit), which one key holds, and refuses the freezer. A contract cannot read another account's keys or code, so
the rest is the deployment's job. Before deploying, check over RPC that the proposer account:
- runs a known multisig contract (`view_code` hash);
- has no full-access key (`view_access_key_list`);
- has at least three confirmations configured.

## Gas

Measured on the sandbox, per call on the vault's receipt, against NEAR's 1 PGas limit per call:

| Call | Tgas |
|---|---|
| `register_index` | 2.5 |
| `deposit` | 2.7 |
| `advance_checkpoint` (real mainnet block) | 2.2 |
| `deliver`, intake settled | 3.8 |
| `deliver`, burn paid to a new implicit account | 5.0–5.1 |
| `deliver`, a real receipt refused (`NotTheLog`) | 2.3 |
| `attest`, two slots | 1.7 |
| `update_verifier` up to the Groth16 check, SP1 / RISC Zero | 37.2 / 37.2 |
| `resolve_intake` | 2.7–3.2 |
| `refund` | 3.1 |
| `deliver_recorded`, burn / migration | 4.9 / 3.1 |
| `claim_snapshot`, signature / recovery address | 4.0 / 3.5 |

The Groth16 check dominates `update_verifier`. The public values a real statement proof carries add only the light
client's own checks and one storage write.

## How it differs from the EVM vault

- **P1 and P2 are inside the vault**, because cross-contract calls on NEAR are asynchronous. Each is a light client in
  the vault's storage, named by the hash of its configuration. A rotation or a successor names two such ids, which must
  be registered and must belong to different proof systems.
- **Payouts are transfers with a callback.** A failed transfer restores the book and leaves the amount owed. Every
  recipient is an implicit account, which the first transfer creates, so no payout is stranded on a missing account.
- **Recipients are implicit accounts.** A burn's recipient and a `FREEZER_CHANGE`'s new freezer are 32-byte words. A
  named account is paid through its own implicit account (interfaces doc).
- **Callers pay storage**, as NEAR's storage staking requires.
- **Amounts are `u128` yoctoNEAR.** Digests write them as full words through the core's `*_wide` functions. A snapshot
  share computes `shares × units / 1e18` in 256 bits (`share_wide`), as Solidity does.
- **`attest` returns its record and logs nothing.** The record states the height and time of the block it ran in,
  because the outcome that proves it lands in a later block.

## Tests

`cargo test` runs 40 unit tests on the mocked runtime and 2 on the sandbox. Tests named after findings:

| Test | Checks |
|---|---|
| `test_vlt1_the_component_must_lie_inside_the_array` | A claim reads only inside the hub's components array, on a real hub's storage. |
| `test_vlt2_a_loosening_change_waits_and_the_freezer_may_drop_it` | Loosening governance waits `GOVERNANCE_DELAY`; the freezer may cancel it, but not its own replacement. |
| `test_vlt3_a_message_after_the_checkpoint_waits_for_it` | A message moving coins waits for the checkpoint. |
| `test_vlt4_one_proof_moves_no_mark` | Only a message on both proofs moves a nonce mark. |
| `test_vlt5_no_freeze_after_the_snapshot` | No freeze, by the freezer or the factory, and no later message, after the snapshot. |
| `test_lg2_a_stale_checkpoint_keeps_the_successor_and_the_vetoes` | A stale advance in a stall keeps the review and the veto count. |
| `test_lg3_a_one_proof_message_is_not_the_last_message` | A one-proof message cannot block an honest successor. |
| `test_lg4_a_verifier_takes_a_proof_only_within_a_day_of_its_anchor` | Real SP1 and RISC Zero proofs; the lag rule. |
| `test_sol9_the_vault_is_no_recipient`, `test_sol9_a_claim_never_pays_the_vault` | Neither a burn nor a claim pays the vault's own account. |

The rest cover the domains and ids against `cast`, CREATE2 registration, the intake rules, the speed limit, implicit
recipients, migrations, failed payouts, the continuity test, vetoes, the snapshot's start, signatures under
OpenZeppelin's rules, storage proofs, and `attest` byte for byte against `cast abi-encode`.

Each finding's guard was checked by a mutant that the named test kills. The mutants: the guards of LG-2, LG-3, VLT-1
to VLT-5, SOL-9 for both burns and claims, and LG-4; the speed limit; continuity (c); `attest`'s check; the hub's sent
mark; the recovery proposer's check; and the adapter's G2 order and byte order. On the sandbox, `attest`'s height and
time were mutated too. All were killed.

## Fixtures

`tests/fixtures/hub.json` is a real hub's storage at one block. It holds an index with NEAR at 3 NEAR a share, a
settled intake and an open one, a burn and a migration in flight, and two holders. The hub's chain registry names NEAR
testnet's id and this vault's id. `generate.py` is Solana's generator, copied and given NEAR's ids and amounts. It
deploys the repository's contracts on anvil and writes the proofs with `eth_getProof`. Amounts in yoctoNEAR are
written as decimal strings.

```bash
python3 near/contracts/xindex-vault/tests/fixtures/generate.py   # from the repository root; foundry, and lib/ populated
```

The fixture's vault is the named account `vault.test.near`, whose id does not depend on the code. A deterministic
account's id changes with every build.
