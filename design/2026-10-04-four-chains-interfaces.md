# Sui, Aptos, Injective and VeChain: the interfaces each side builds against (4 October 2026)

These four passed the admission rule in `design/2026-10-04-chain-research.md`, and the owner asked for them to be
added (4 October 2026). Each needs a vault on its chain, P1 and P2 there, and a state verifier on Ethereum, built in
parallel; this file fixes what they share. As with NEAR and Stellar, nothing on Ethereum's hub or factory changes: a
vault chain is a registry entry, a 32-byte vault id and a state verifier.

**Safety, for every builder.** Nothing is deployed to any network, nothing is sent and nothing is spent. Public
endpoints are read only, to write fixtures. No key, mnemonic or keystore is created or read. Builds run at the lowest
priority on one job (`CARGO_BUILD_JOBS=1`, `nice -n 19` where the shell allows it), one heavy command at a time.

## Chain ids

An EVM chain's registry id is its EVM chain id, the value its `CHAINID` opcode returns, which the EVM vault compares
with every message's `destChainId`. A chain without one takes the first 8 bytes of `keccak256` of its CAIP-2 name, as a
big-endian integer, below 2^64, as NEAR's and Stellar's do (`design/2026-10-03-near-stellar-interfaces.md`).

| Chain | Vault | Registry id |
|---|---|---|
| Injective mainnet | `XindexVault` | 1776 |
| Injective testnet | `XindexVault` | the testnet EVM's chain id, checked live by its builder |
| VeChain mainnet | `XindexVault` | `uint256(0x00000000851caf3cfdb6e899cf5958bfb1ac3413d346d43539627e6be7ec1b4a)`, its genesis id, which `CHAINID` returns (checked live by its builder) |
| VeChain testnet | `XindexVault` | `uint256(0x000000000b2bce3c70bc649a02749e8687721b09ed2e15997f466536b20bb127)` |
| Sui mainnet | Move | `sui:mainnet`: 13762264207064992463 |
| Sui testnet | Move | `sui:testnet`: 10803649406359875205 |
| Aptos mainnet | Move | `aptos:1`: 549304973309166888 |
| Aptos testnet | Move | `aptos:2`: 10134113455198361380 |

Every Solidity chain id is a `uint256`, so VeChain's 224-bit id needs no change on Ethereum. A Move vault stores its id
as a `u64`.

## Vault ids, recipients and coins

- **Injective and VeChain** run `XindexVault` unchanged, as BNB Chain does: the vault id is its address, left-padded; a
  recipient is a 20-byte address in the low bytes; the coin is the native one, INJ or VET, in 18-decimal wei.
  - **VeChain** gives every contract a Prototype "master", its creator, which can move the contract's VTHO. The
    deployment clears it for every contract it creates (`Prototype.setMaster(contract, address(0))`), and a check
    confirms it.
  - **VeChain transactions are not Ethereum's** (clauses, `blockRef`, VTHO gas), so `forge script` cannot broadcast
    there. Its deployment is a script of its own, as TRON's `tron/deploy.mjs` is, with `DeployVault`'s checks.
- **Sui.** The vault is a Move package made immutable at publication (`package::make_immutable` in the publishing
  transaction). Its 32-byte id is the id of its shared state object. A recipient is a 32-byte Sui address. The coin is
  SUI in MIST (`u64`).
- **Aptos.** The vault is a Move package published with `upgrade_policy = "immutable"`. Its state lives at an object
  whose `ExtendRef` only the vault's code holds, so no account can sign for it; the vault id is that object's address.
  A recipient is a 32-byte Aptos account address. The coin is APT in octas (`u64`).
- On Sui and Aptos, an amount from Ethereum that does not fit a `u64` is refused, as on Solana.

## What each vault proves to Ethereum

The hub reads three kinds of vault storage, by the keys an EVM vault's layout gives them (`HybridHubStorage`): an
intake's digest, `keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15))))`; an index's digest,
`keccak256(abi.encode(index, 14))`; and the snapshot's state root, `bytes32(25)`. Since LG-5 every evidence proof asks
for two slots, the claim's and `bytes32(25)`, from one state.

- **Injective: a storage proof.** `XindexVault`'s own slots, in the `evm` store under `0x02 ++ vault ++ slot`, by an
  ICS-23 proof (IAVL, then the multistore) under the AppHash of header H+1, which commits the state after block H. The
  verifier returns block H's height and time.
- **VeChain: a successful `attest` transaction**, as TRON's design (Stage B spec 5.7), so no state trie proof and no
  node database is needed: a transaction whose one clause calls the vault's `attest(slots, values)` with no value, in a
  block VIP-220 has committed, with its receipt showing `reverted == false`, proven through the block's transactions
  and receipts roots. The verifier writes the clause itself and returns that block's number and time. If the builder
  finds this route unsound or its data unavailable from public endpoints, it stops and reports before choosing another.
- **Sui and Aptos: an `attest` call**, as NEAR's and Stellar's: `attest(slots, values)` aborts unless every slot holds
  its value. On success it records exactly one
  `record = abi.encode(ATTEST_DOMAIN, chainId, vaultId, timestamp, slots, values)`, with
  `ATTEST_DOMAIN = keccak256("xindex.v4.vault-attest")` and `chainId` the `u64` above, encoded as `uint256`:
  - **Sui:** `timestamp` is the `Clock` (`0x6`) in milliseconds when `attest` runs. The record is the `record` field of
    a new object of type `<vault package>::vault::Attestation`, declared `public struct Attestation has key { id: UID,
    record: vector<u8> }`, which `attest` freezes (`transfer::freeze_object`). A frozen object is written in that
    checkpoint, so it is a leaf of the checkpoint's artifacts tree (object id, version, digest). The verifier checks
    the committee's certificate on the checkpoint, the artifacts path, the object's digest over its BCS, its type and
    its immutable owner, then reads `record`. It returns the timestamp in seconds and the checkpoint's sequence number.
  - **Aptos:** `timestamp` is `timestamp::now_microseconds()` when `attest` runs. The record is the `record` field of
    one module event `<vault address>::vault::Attested { record: vector<u8> }`. The verifier checks the signed ledger
    info, the transaction's info in the accumulator with a success status, and the event under its `event_root_hash`.
    It returns the timestamp in seconds and the transaction's version.
- A failed `attest` records nothing, so a proof always proves a successful one, never mere inclusion.

## The state verifiers on Ethereum

One contract per chain, implementing `IVaultStateVerifier.verifySlots(account, slots, proof)` for one vault, as
`NearStateVerifier` and `StellarStateVerifier` do: `account` is the low 20 bytes of the vault id; the attested or
proven slots are the requested ones, in order; it returns their values, the time in seconds and the height.

| Chain | Verifier | How it follows the chain | Lag |
|---|---|---|---|
| Injective | `CometBftStateVerifier` | an SP1 statement of CometBFT light-client hops on tendermint-rs, then the ICS-23 path, over the audited crates IBC's SP1 Tendermint client uses; **every hop needs more than 2/3 of the trusted set's power**, as the BNB verifier's does, not ibc-go's third | `MAX_LAG` of 1 day from the trusted header's time |
| VeChain | `VeChainStateVerifier` | an SP1 statement of VIP-220 finality over the stake-weighted set, the proposers' secp256k1 signatures, and the transactions and receipts tries (blake2b) | 1 day |
| Sui | `SuiStateVerifier` | **in Solidity, no zkVM:** BLS12-381 min-sig (signatures in G1, keys in G2, tag `BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_`) on EIP-2537, Blake2b on EIP-152; the next committee from each end-of-epoch checkpoint the current one certifies | **2 days from the current committee's epoch start**, a trusted time: Sui's epochs last 24 hours, so a 1-day lag would lapse before the next committee exists. A signed time in the future is refused |
| Aptos | `AptosStateVerifier` | an SP1 statement of signed epoch changes (BLS12-381 min-pk with `Bls12381.sol`'s ciphersuite) and SHA3-256 accumulator and event paths | 1 day; one proof may chain several 2-hour epochs |

Each SP1 program follows the existing ones (`proofs/near`, `proofs/stellar`): the statement in plain Rust, tested
natively on real mainnet data that its fixture generator fetches read-only, then run in SP1's execute mode. Each
verifier is checked against SP1's pinned v6.0.0 Groth16 verifier, and `DeployStateVerifier` gains the chain, with its
anchor checks and a test on a real anchor. A new verifier after a format change comes through the factory's 30-day
`ROTATION_DELAY`.

## P1 and P2 on each chain

- **Injective and VeChain:** `EthereumFinalityVerifier` and `RiscZeroFinalityVerifier` as on BNB Chain, through
  `DeployVault`'s checks (or VeChain's own script). Their BN254 precompiles sit at 0x06 to 0x08, measured.
- **Sui and Aptos:** P1 and P2 are Move modules, twins of `FinalityVerifier.sol` and of `crates/xindex-core`'s light
  client: the same anchor, the same headers tree, the same receipt proof, the lag rule (LG-4) and `verify_checkpoint`,
  with SP1's and RISC Zero's Groth16 checks on the chain's native BN254 (`sui::groth16`; Aptos's `crypto_algebra`).
  Only the proof's check differs between P1 and P2.
- **The twin rule** now spans six vaults: a change to a vault's rule or to a message goes into each. The Move vaults
  keep the messages, digests, speed limit, freeze, stall, checkpoints, recovery and snapshot exit, and their tests pin
  every encoding against Solidity's, as Solana's `abi` tests do.
