# Xindex on Solana

The Stage B vault on Solana (`programs/xindex-vault`), a port of the EVM vault, and a stub verifier for testnets
(`programs/stub-verifier`). The rules are in `../design/2026-09-30-v4-stage-b-spec.md`, sections 4 and 7. The build is
for the hackathon demonstration of `../design/2026-09-30-hackathon-plan.md`: devnet only.

> **The stub verifier is not a proof system.** It accepts any Ethereum log its relayer key signed. On the devnet it
> stands in for P1 and P2, which do not exist yet. A vault whose verifiers are stubs is only as safe as its relayer
> keys. Never point a mainnet vault at it.

## What the vault does

- Holds SOL for every index registered here, an index being a CREATE2 clone of the hub template by the factory on
  Ethereum.
- Takes SOL only as deposits to an intake: a mint order or a rebalance delivery.
- Pays out only on messages from Ethereum that P1 and P2 prove: burns, intakes settled or failed, migrations, and the
  factory's governance.
- Pays within 4% of an index's balance in any 24 hours, or the outflow floor; the rest stays owed. A freeze stops
  deposits and payouts for 14 days.
- Keeps two digests Ethereum proves, per index and per intake, byte for byte those of the EVM vault.

## Build and test

The toolchain: Solana CLI 4.2, Anchor 1.2, and Rust 1.98.1 (`rust-toolchain.toml`) for the host tests. Builds run at
the lowest priority on two jobs.

```bash
cd solana
CARGO_BUILD_JOBS=2 nice -n 19 anchor build --no-idl        # the vault
CARGO_BUILD_JOBS=2 nice -n 19 cargo build-sbf --manifest-path programs/stub-verifier/Cargo.toml
CARGO_BUILD_JOBS=2 nice -n 19 cargo test -p xindex-vault    # unit tests, then LiteSVM tests on the two .so files
cargo fmt --all --check && cargo clippy -p xindex-vault -p stub-verifier
```

- `--no-idl`, because the vault derives its accounts from the message itself, which Anchor's IDL generator cannot
  follow. Clients derive the same addresses: see `programs/xindex-vault/tests/common/mod.rs`.
- The tests load the built `.so` files, so build before testing.

## Program ids and keys

- `target/deploy/xindex_vault-keypair.json` and `target/deploy/stub_verifier-keypair.json` hold the program keys. They
  are git-ignored. Back them up: `cargo clean` deletes them, and a new key is a new program id.
- The stub is deployed twice, as P1 and as P2, under two further keys (`solana-keygen new -o p1.json`, then
  `solana program deploy target/deploy/stub_verifier.so --program-id p1.json`). One build serves both: the stub is a
  plain Solana program with no id of its own.

## Deploying to devnet (the owner signs)

1. `solana config set --url devnet` and fund the deployer (`solana airdrop 2`).
2. Deploy the vault (`anchor deploy --no-idl`) and the stub twice.
3. Initialize each stub with its relayer's key: instruction `1` with the key as data, accounts
   `[state, payer, system program]`, where `state` is the stub's address at the seed `"verifier"`.
4. Initialize the vault from the upgrade authority, with Sepolia's chain id, the Solana id the factory's registry
   assigns, the factory, the hub template, the freezer, and the cap and floor in lamports.
5. On Sepolia, the factory's owner proposes the chain with the vault's `config` address as its 32-byte vault.

## Size

A burn with both stub proofs is 1,143 of a transaction's 1,232 bytes (`a_burn_fits_a_transaction`). The vault reads
the message id, the index and the emitter from the payload itself, so the message travels once. Real proofs are larger:
there, the relayer puts the static accounts in an address lookup table and, if needed, stages the proofs in a buffer
account.
