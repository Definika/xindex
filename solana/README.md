# Xindex on Solana

The Stage B vault on Solana (`programs/xindex-vault`), a port of the EVM vault; P1's verifier
(`programs/ethereum-verifier`), a light client of Ethereum advanced by SP1 proofs; and a stub verifier for testnets
(`programs/stub-verifier`). The rules are in `../design/2026-09-30-v4-stage-b-spec.md`, sections 4, 7 and 10. The vault
was built for the hackathon demonstration of `../design/2026-09-30-hackathon-plan.md`.

> **The stub verifier is not a proof system.** It accepts any Ethereum log its relayer key signed. On the devnet it
> stands in for P1 and P2. A vault whose verifiers are stubs is only as safe as its relayer keys. Never point a mainnet
> vault at it. P1 now exists here (below). P2, the second proof system every payout also needs, is built for EVM vault
> chains (`../proofs/p2`, `RiscZeroFinalityVerifier`), but not on Solana yet: its twin of `ethereum-verifier` waits
> with the rest of the Solana work (Stage B spec, section 11).

## What the vault does

- Holds SOL for every index registered here, an index being a CREATE2 clone of the hub template by the factory on
  Ethereum.
- Takes SOL only as deposits to an intake: a mint order or a rebalance delivery.
- Pays out only on messages from Ethereum that P1 and P2 prove: burns, intakes settled or failed, migrations, and the
  factory's governance.
- Pays within 4% of an index's balance in any 24 hours, or the outflow floor; the rest stays owed. A freeze stops
  deposits and payouts for 14 days.
- Keeps two digests Ethereum proves, per index and per intake, byte for byte those of the EVM vault.

Not built yet, beside P2: a verifier of the vault's state on Ethereum, which waits on Alpenglow's mainnet launch
(Stage B spec, section 8); the stall recovery and snapshot exit, which follow it; and tokens other than SOL. On the
devnet a relayer's stub on Sepolia (`../demo/src/StubStateVerifier.sol`) stands in for the state verifier.

## P1's verifier

`programs/ethereum-verifier` is `src/verifiers/EthereumFinalityVerifier.sol` as a Solana program, behind the vault's
verifier interface. Its instructions, by first byte:
- `0`, `verify_event`: the vault's call.
- `1`, `initialize`: the program key and the first anchor, once, by the upgrade authority.
- `2`, `update`: anyone, with an SP1 proof from the stored anchor.
- `3`, `check_proof`: checks any SP1 v6 Groth16 proof.

The program's own documentation gives the layouts.
- It checks SP1 v6's Groth16 proofs on the `alt_bn128` syscalls in 96,910 compute units, measured in LiteSVM on SP1's
  own proof.
- A log's proof (1.5 to 2.2 KB) is too long for a transaction. The relayer writes it into a loader buffer
  (`solana program write-buffer`, its length as a little-endian u32 first) and passes the buffer after the range
  account, with an empty proof. Each trie node's length in the proof is a u32 too, since a receipt has no size limit
  of its own.
- It reads every RLP list in place and keeps none of its items, so the heap never bounds a receipt (LG-1). The
  transaction's 1.4M compute units do: a real receipt takes 7,600 to 9,500, one of 513 logs 41,600, and the most that
  verifies is about 19,600 logs before the message's, or 2.8 MB of log data (`lg1_limits_of_a_receipt`, the verifier
  alone: through the vault, the vault's own work and P2's share the budget). A message whose transaction was shaped
  past that is emitted again by its hub or the factory, in a transaction of its own.
- It takes a proof only until a day after the stored anchor's epoch began (`now > genesisTime + epoch * 384 + 86400`
  is refused, LG-4), as the EVM verifier does: the statement's step is 225 epochs, one day, so it must be proven at
  least daily, and once it falls behind it stops for good rather than trusting stake that may have left since.
- Deploy it as the stub: `initialize` from its upgrade authority, then make it final. The program key is `p1 vkey`'s,
  the anchor and epoch `p1-input check-state`'s (`../proofs/README.md`), and the genesis time the beacon chain's:
  1606824023 on mainnet, 1655733600 on Sepolia.

## Build and test

The toolchain: Solana CLI 4.2, Anchor 1.2, and Rust 1.98.1 (`rust-toolchain.toml`) for the host tests. Builds run at
the lowest priority on two jobs.

```bash
cd solana
CARGO_BUILD_JOBS=2 nice -n 19 anchor build --no-idl        # the vault
CARGO_BUILD_JOBS=2 nice -n 19 cargo build-sbf --manifest-path programs/stub-verifier/Cargo.toml
CARGO_BUILD_JOBS=2 nice -n 19 cargo build-sbf --manifest-path programs/ethereum-verifier/Cargo.toml
CARGO_BUILD_JOBS=2 nice -n 19 cargo test -p xindex-vault -p ethereum-verifier   # unit tests, then LiteSVM tests on the .so files
cargo fmt --all --check && cargo clippy -p xindex-vault -p stub-verifier -p ethereum-verifier --all-targets
```

- `--no-idl`, because the vault derives its accounts from the message itself, which Anchor's IDL generator cannot
  follow. Clients derive the same addresses: see `programs/xindex-vault/tests/common/mod.rs`.
- The tests load the built `.so` files, so build before testing.

## Program ids and keys

- `target/deploy/xindex_vault-keypair.json`, `target/deploy/stub_verifier-keypair.json` and
  `target/deploy/ethereum_verifier-keypair.json` hold the program keys. They are git-ignored. Back them up: `cargo
  clean` deletes them, and a new key is a new program id.
- The stub is deployed twice, as P1 and as P2, under two further keys (`solana-keygen new -o p1.json`, then
  `solana program deploy target/deploy/stub_verifier.so --program-id p1.json`). One build serves both: the stub is a
  plain Solana program with no id of its own.

## Deploying to devnet (the owner signs)

1. `solana config set --url devnet` and fund the deployer (`solana airdrop 2`).
2. Deploy the vault (`anchor deploy --no-idl`) and the stub twice.
3. Initialize each stub with its relayer's key, from the stub's upgrade authority (SOL-1): instruction `1` with the key
   as data, accounts `[state, authority (signer), system program, the stub's ProgramData]`, where `state` is the
   stub's address at the seed `"verifier"`.
4. Make each stub final: `solana program set-upgrade-authority <stub> --final`. The vault takes only verifiers nobody
   can upgrade (SOL-2).
5. Initialize the vault from its upgrade authority, with Sepolia's chain id, the Solana id the factory's registry
   assigns, the factory, the hub template, the freezer, and the cap and floor in lamports. It takes each verifier's
   ProgramData account too.
6. On Sepolia, the factory's owner proposes the chain with the vault's `config` address as its 32-byte vault, and a
   state verifier: the demo's `sepolia0` names its stub. `../script/ConfigureChains.s.sol` takes the same 32-byte
   vault, but Solana has no state verifier outside the demo.

`npm run cli -- solana-init` in `demo/relayer` does steps 3 and 5, and stops between them to print step 4's commands.

A governance message that raises the cap or the floor, changes the freezer or rotates the verifiers then waits
`GOVERNANCE_DELAY` (7 days) in `config`, as on the EVM vault. Anyone applies it with `apply_change(kind, body)`, and a
rotation names the new verifiers and their ProgramData accounts there. The freezer may drop a waiting raise or rotation
with `cancel_change(kind)`.

## Size

A burn with both stub proofs is 1,143 of a transaction's 1,232 bytes (`a_burn_fits_a_transaction`). The vault reads
the message id, the index and the emitter from the payload itself, so the message travels once. Real proofs are larger:
there, the relayer puts the static accounts in an address lookup table and, if needed, stages the proofs in a buffer
account.
