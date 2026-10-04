# NEAR and Stellar: the interfaces each side builds against (3 October 2026)

NEAR and Stellar join as vault chains (`design/2026-10-01-stage-c-research.md`, the owner's call on 3 October 2026).
Each needs a vault on its chain, P1 and P2 there, and a state verifier on Ethereum. Those are built in parallel, so
this file fixes what they share. Nothing on Ethereum's hub or factory changes: a vault chain is a registry entry, a
32-byte vault id and a state verifier, as Solana's is.

## Chain ids

The factory's registry id of a chain without an EVM chain id is the first 8 bytes of `keccak256` of its CAIP-2 name,
as a big-endian integer. Every id is below 2^64, so a vault stores it as a `u64`, and far above any EVM chain id.

| Chain | CAIP-2 | Registry id |
|---|---|---|
| NEAR mainnet | `near:mainnet` | 339552387624818629 |
| NEAR testnet | `near:testnet` | 4078699518750379172 |
| Stellar mainnet | `stellar:pubnet` | 839718837228939926 |
| Stellar testnet | `stellar:testnet` | 17667989177921016935 |

## Vault ids and recipients

- **NEAR.** The vault runs at a deterministic `0s` account (NEP-616), its code fixed by hash, with no access key. Its
  32-byte id, which the factory registers and every message names, is `keccak256(utf8(account_id))`.
  A burn's 32-byte recipient names an implicit account. If its top 12 bytes are zero, it is the ETH-implicit account
  (NEP-518) `"0x" ++ lowercase hex of the low 20 bytes`. Otherwise it is the ed25519 implicit account
  `lowercase hex of all 32 bytes`. A named account is paid through its own implicit account.
- **Stellar.** The vault is a Soroban contract with a plain Wasm executable and no upgrade path. Its 32-byte id is the
  contract's id, the hash a `C…` address encodes. A burn's 32-byte recipient is a Stellar account's ed25519 public key
  (`G…`); contracts are not recipients.
- **Coins.** The native coin only, as on every vault chain: NEAR in yoctoNEAR (`u128`), XLM in stroops through the
  native asset's contract (`i128`). An amount from Ethereum that does not fit is refused, as on Solana. The factory's
  `MAX_SUPPLY` (2^128) holds NEAR's supply in yocto, about 1.2e33.

## What the vault proves: `attest`

The hub reads three kinds of vault storage, by the keys an EVM vault's layout gives them (`HybridHubStorage`):

| What | Slot key the hub asks for |
|---|---|
| An intake's digest | `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))` |
| An index's digest | `keccak256(abi.encode(index, 14))` |
| The snapshot's state root | `bytes32(25)` |

Each vault keeps a map from these keys to their 32-byte values, written whenever the value changes, as the EVM
vault's storage is. An absent key reads as zero. Then:

- `attest(slots: [bytes32], values: [bytes32])`: anyone. Succeeds only if every slot holds its value, and otherwise
  fails. On success it emits exactly one record, where `ATTEST_DOMAIN = keccak256("xindex.v4.vault-attest")`
  (`0xb0ec2b25fdd79b42b523d5b0e641474599bbba254460db808de33f7bc0c25d5c`):
  - on NEAR, as the receipt's return value (`SuccessValue`), with nothing logged:
    `abi.encode(ATTEST_DOMAIN, chainId, vaultId, height, timestampNs, slots, values)`, `height` and `timestampNs` being
    `env::block_height()` and `env::block_timestamp()` when `attest` runs (`uint64` each). An outcome's root lands one or
    more blocks after its receipt ran, and no light header bounds the run's time from below, so the vault states it,
    and the verifier returns it, never the time of the block that commits the outcome. Without it, an `attest` run just
    before a deadline could be reported as after it, and honest state could then pass for evidence (found by the state
    verifier's build, 3 October 2026);
  - on Stellar, as one contract event, topics `[Symbol("attest")]`, data `Bytes` of
    `abi.encode(ATTEST_DOMAIN, chainId, vaultId, slots, values)`. A Soroban transaction's result is in the very ledger
    it ran in, so that ledger's sequence and close time are the run's.

A failed `attest` emits nothing, and a state proof proves a successful one, never mere inclusion. That is TRON's
design (spec section 5.7): the vault's own check stands in for a storage proof. Since LG-5, every evidence proof asks
for two slots, the claim's and `bytes32(25)`, so one `attest` covers both.

## The state verifier on Ethereum

One contract per chain, implementing `IVaultStateVerifier.verifySlots(account, slots, proof)` for one vault:
- `account` must be the low 20 bytes of the vault's id, as the hub's `_vaultAddress` passes it;
- the proof shows a successful `attest` by that vault in a block final on its chain, under the verifier's checkpoint;
- the attested slots must be the requested ones, in order, and it returns their values;
- `timestamp` is that block's time in seconds, `blockNumber` its height, NEAR's, or ledger sequence, Stellar's.

Each verifier advances a checkpoint with a Groth16 proof of the chain's finality (SP1, on SP1's pinned v6 verifier), and
stops for good a day behind (`MAX_LAG`), as the BNB, TRON and P1 verifiers do. A chain's new verifier, after a format
change or Stellar's Tier 1 rotation, comes through the factory's 30-day `ROTATION_DELAY`.

## P1 and P2 on each chain

The vault checks Ethereum's messages with P1 and P2, as every vault does, through the shared core
(`crates/xindex-core`): SP1's and RISC Zero's Groth16 checks over the chain's BN254 host functions, the light client's
anchor, the lag rule and receipt proofs. On NEAR they are compiled into the vault, since NEAR's cross-contract calls are
asynchronous. On Stellar they may be separate contracts, since Soroban's calls are synchronous, if the vault would
otherwise pass Soroban's 128 KiB Wasm limit.
