# Eleven more chains: research of 4 October 2026

The owner asked for every chain with a top-100 native coin that had not been researched, memecoin chains excepted
(MemeCore is dropped): Sui, TON, Internet Computer, Algorand, Aptos, Cronos, Injective, Bittensor, Filecoin, VeChain and
Ethereum Classic. Each was judged as the Stage C chains were (`design/2026-10-01-stage-c-research.md`), with the hub's
timing added by the L2 research of the same day (`design/2026-10-04-l2-research.md`):
1. **Finality** is deterministic, as the admission rule requires.
2. **Ethereum can follow the validator set** from data the previous set signed.
3. **The vault's state can be proven on Ethereum** within 6 hours of an order's deadline (`GRACE`), by a state verifier
   advanced at least daily (`MAX_LAG`).
4. **The chain verifies P1 and P2**, two Groth16 proofs over BN254.
5. **The vault can be ownerless and immutable** and hold the native coin itself.
6. **Trust:** who must be honest, whether misbehaviour is slashed, whether the set is permissioned.

Two read-only research passes read primary sources and queried public endpoints; nothing was deployed or sent. A claim
the research could not confirm is marked unverified, and the researchers' reasoning is marked as inference.

## Value

Market caps from the 29 September snapshot (`design/analysis/data`), over the holdable universe of `floor.py`
($2,389.1B; the 0.2% floor is $4.78B):

| Coin | Rank | Market cap | Weight | Daily volume / cap |
|---|---|---|---|---|
| SUI | 33 | $4.74B | 0.199% | 19.7% |
| GRAM (TON) | 37 | $4.38B | 0.183% | 1.0% |
| CRO | 39 | $3.51B | 0.147% | 0.8% |
| TAO | 43 | $3.00B | 0.125% | 8.0% |
| ICP | 55 | $1.90B | 0.079% | 6.1% |
| ETC | 61 | $1.45B | 0.061% | 7.2% |
| ALGO | 80 | $1.18B | 0.049% | 14.5% |
| FIL | 91 | $0.89B | 0.037% | 11.8% |
| VET | 97 | $0.78B | 0.032% | 1.2% |
| INJ | 98 | $0.75B | 0.032% | 11.8% |
| APT | 100 | $0.73B | 0.030% | 8.9% |

All eleven together are 0.98% of the universe. **None reaches the floor; SUI is a rounding error below it.** So none
enters the flagship today; a vault for one serves creators' indexes, or readiness for when a coin crosses the floor.

## Summary

| Chain | Weight | Verdict | What stands in the way |
|---|---|---|---|
| **Sui** | 0.199% | **passes, buildable now** | a lag rule for 24-hour epochs; a Move vault; validators can freeze addresses (Cetus) |
| **TON** | 0.183% | passes the rule; **P1 and P2 cannot run** | no BN254 in the TVM: a BLS12-381 wrapper, or wait |
| **Cronos** | 0.147% | passes the rule; **owner decision** | 10 invitation-only validators, one identity at 46.9%, an admin key that can censor the vault |
| **Bittensor** | 0.125% | **wait** | 20 nodes of one foundation under sudo; its precompile map breaks the pinned verifiers |
| **Internet Computer** | 0.079% | passes the rule; **owner decision** | permissioned, unstaked node providers; the NNS can uninstall canisters |
| **Ethereum Classic** | 0.061% | **fails the rule** | proof of work |
| **Algorand** | 0.049% | **owner decision on the rule** | safety "with overwhelming probability", as Avalanche; Falcon state proofs need a zkVM |
| **Filecoin** | 0.037% | **fails today** | F3, its deterministic finality, has finalized nothing since 9 March 2026 |
| **VeChain** | 0.032% | **passes, buildable** | a NEAR-sized build: secp256k1 headers and a blake2b trie in a zkVM |
| **Injective** | 0.032% | **passes, the cheapest** | nothing: `XindexVault` as is, one SP1 CometBFT statement on audited crates |
| **Aptos** | 0.030% | **passes, buildable now** | SHA3-256 paths on Ethereum; a Move vault |

**None of the eleven reaches the 0.2% floor,** so none enters the flagship today. Four pass the rule and can be built
now (Sui, Injective, Aptos, VeChain). Three pass it but need the owner's call on trust or on P1 and P2 (Cronos, ICP,
TON). One needs a ruling on the rule itself (Algorand). Two wait on their chains (Bittensor, Filecoin). One fails
(Ethereum Classic).

**Decisions for the owner.**
1. **Value.** Whether to build any vault for a coin below the floor, for creators' indexes or readiness. Every vault
   is a new audit surface.
2. **Sui.** The lag rule for 24-hour epochs: counted from the epoch's end, or `MAX_LAG` of two days. And whether the
   Cetus precedent, validators freezing addresses and a stake vote moving coins, is an acceptable chain-level power.
3. **TON.** Accept a BLS12-381 wrapper of P1 and P2, which couples the two proofs and needs a ceremony and an audit, or
   wait for BN254 in the TVM.
4. **Cronos.** Accept a 10-node permissioned set without slashing, an admin multisig whose encrypted blocklist
   consensus enforces, and IBC-backed coins.
5. **Internet Computer.** Accept a permissioned, unstaked node set under NNS governance, as Hedera's question.
6. **Algorand.** Whether safety "with overwhelming probability" passes the rule, as Avalanche's question, and whether a
   30% proven weight is enough.
7. **Injective.** Accept an unslashed stake set, as TRON's and Stellar's were; and require more than 2/3 of the trusted
   set on each light-client hop, as BNB's verifier does, rather than ibc-go's third.

**Order of work, if the owner builds any.**
1. **Sui**, when SUI crosses the floor, which it is a rounding error from. Its Ethereum side needs no new zk statement;
   the vault is Move.
2. **Injective**, the cheapest: the EVM vault as is, and a CometBFT verifier that also serves Cronos if the owner
   accepts Cronos.
3. **TON**, once the owner rules on the wrapper or the TVM gains BN254; GRAM is the other coin near the floor.
4. Aptos and VeChain only for creators' indexes; ICP and Algorand after their decisions; Bittensor and Filecoin when
   their chains change.

Nothing here is a hackathon item. Each still to be measured: the Sui verifier's gas in Solidity and Groth16's cost in
MIST, Aptos's gas for two proofs, ICP's Wasm instructions per Groth16, TON's ed25519 hop in SP1, and Algorand's Falcon
proving.

## Sui, TON, Internet Computer, Algorand and Aptos

TON's coin was renamed Gram (GRAM) on 15 June 2026, after a TON Vote passed with 81.22%; the network is still The Open
Network. https://docs.ton.org/foundations/config

| Chain | Deterministic finality | P1 and P2 on the chain | Its state, proven on Ethereum | Trust | Verdict |
|---|---|---|---|---|---|
| Sui | yes: Mysticeti BFT, checkpoints certified by more than 2/3, about 0.5 s | yes: native `sui::groth16` over BN254, routine on mainnet through zkLogin | **in Solidity, no zk:** BLS12-381 min-sig certificates on EIP-2537, Blake2b on EIP-152; the end-of-epoch checkpoint names the next committee; a per-checkpoint Merkle root of written objects is live | 127 validators, the top 18 hold a third; no principal slashing; validators froze the Cetus exploiter's addresses in 2025 and a 90.9% stake vote moved the funds | **passes; buildable now**, once the lag rule fits its 24-hour epochs |
| TON | yes: Catchain 2.0 (Simplex) since April 2026, about 0.6 s | **no: the TVM has BLS12-381 but no BN254** | in a zkVM: ed25519 masterchain signatures (about 63 of 100 by weight), then SHA-256 cell proofs a lite server serves | 380 validators, 100 on the masterchain; fines by complaint vote; a validator vote froze early-miner wallets in 2023 | the rule passes; **P1 and P2 wait** on a BLS12-381 wrapper or BN254 in the TVM |
| Internet Computer | yes: notarization and finalization at 2/3, about 1 s | only in Wasm: no pairing API; one Groth16 about 3.6B of a 40B-instruction message (inference from an unverified figure) | **in Solidity, no zk, no set to follow:** threshold-BLS certified data under an NNS delegation and a root key fixed since genesis | **permissioned:** node providers admitted by NNS vote, no stake; 9 of 13 nodes forge a subnet's state, 27 of 40 NNS nodes any delegation; the NNS can uninstall a controller-less canister and upgrades the ICP ledger | **owner decision**, of Hedera's kind |
| Algorand | **not as written:** safety holds "with overwhelming probability", committees sized for a 5×10⁻⁹ failure | yes: AVM BN254 pairing, about 42k of a pooled 190k budget per proof (estimate) | in a zkVM: Falcon-1024 state proofs every 256 rounds (about 12 minutes, about 300 KB), proven weight 30%; no account-state root, but failed calls never enter blocks | permissionless online stake, sampled committees, no slashing | **owner decision on the rule**, as Avalanche; the heaviest Ethereum side |
| Aptos | yes: AptosBFT quorum certificates at 2/3 plus one, sub-second | yes: `crypto_algebra` BN254 on mainnet, both proofs about 39% of a transaction (estimate) | mostly: **BLS12-381 with exactly `Bls12381.sol`'s ciphersuite**, and the signed epoch change names the next set; but Merkle paths are SHA3-256, which needs a zkVM or Keccak-f in Solidity | 85 validators, the top 14 hold a third; no slashing; governance upgrades the framework | **passes; buildable now** |

### Sui (SUI)

- **Finality.** Mysticeti, a DAG-based BFT protocol with quorums above 2/3; a certified checkpoint "is itself proof of
  finality", about 0.5 s. https://docs.sui.io/develop/sui-architecture/consensus
- **Validator set.** 127 validators; the top 48 reach 2/3, the top 18 a third; 7.07B SUI staked. Punished validators
  lose an epoch's rewards, never principal. The last checkpoint of each epoch carries `next_epoch_committee`, signed by
  the current committee, so the set is followed from signed data.
  https://github.com/MystenLabs/sui/blob/main/crates/sui-types/src/messages_checkpoint.rs. Signatures are
  `bls12381::min_sig`: signatures in G1, keys in G2, tag `BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_`, the
  opposite arrangement and tag to `Bls12381.sol`'s, so the library needs a min-sig twin.
- **State.** No global state root per checkpoint. `checkpoint_commitments` carries a Blake2b-256 Merkle root over every
  object written or deleted in the checkpoint, live on mainnet (checked here: the latest checkpoint carries an
  `artifactsDigest`), with inclusion proofs from the RPC. https://docs.sui.io/develop/accessing-data/authenticated-events.
  So the vault proves its state as TRON's, NEAR's and Stellar's do: an `attest(slots, values)` that aborts unless every
  value holds, and writes an object that becomes a leaf of that root (inference). Ethereum checks the committee, the
  aggregate signature (EIP-2537), Blake2b (EIP-152) and the path: 0.5 to 1M gas an update in Solidity, mostly G2 keys in
  calldata, or about 227k through one SP1 proof (estimates).
- **The lag rule.** Epochs last 24 hours exactly (epoch 1269: 86,400.01 s, checked here). A verifier that refuses an
  update a day after the current set was named, as `NearStateVerifier` does, would lapse before the next committee
  exists. Sui's lag has to run from the epoch's end, or `MAX_LAG` be two days.
- **Bridges.** The Sui Bridge is a separate committee of ECDSA bridge keys, upgradeable at 50.01% of stake: not
  Xindex's standard. `sui-light-client` is off-chain Rust. No zk light client to Ethereum was found.
  https://github.com/MystenLabs/sui/blob/main/bridge/evm/contracts/SuiBridge.sol
- **Chain side.** `sui::groth16` verifies BN254 with up to 8 public inputs (SP1 and RISC Zero use 5); proofs are
  arkworks-compressed little-endian, so the EVM encoding is converted. The vault is Sui Move, so `crates/xindex-core`
  does not carry over, and P1's receipt checks (RLP, Merkle-Patricia, keccak) are ported to Move (inference).
  `package::make_immutable` deletes the upgrade capability; SUI is held as a `Balance<SUI>` in a shared object.
  https://github.com/MystenLabs/sui/blob/main/crates/sui-framework/packages/sui-framework/sources/crypto/groth16.move
- **Chain-level power.** Each validator's node can deny transactions touching listed objects or addresses; in May 2025
  validators blocked the Cetus exploiter, and a 90.9% stake vote passed an upgrade letting a recovery address act for
  the hacker's addresses. So a third of stake could freeze the vault, and a stake vote could move its coins (inference).
  https://www.sui.io/blog/cetus-incident-response-onchain-community-vote
- **Verdict. Passes, buildable now.** The Ethereum side is smaller than NEAR's (no new zk statement); the vault side is
  larger (Move, no shared core).

### TON (GRAM)

- **Finality.** Simplex: notarize then finalize at ⌊2W/3⌋+1; "finalized chains are always consistent" for f < W/3;
  about 0.6 s, live since April 2026. https://ton-blockchain.github.io/simplex-docs/,
  https://github.com/ton-blockchain/ton/blob/master/crypto/block/signature-set.cpp
- **Validator set.** 380 validators, 100 on the masterchain; the top 63 by weight hold 2/3, the top 30 a third;
  rounds of 18.2 hours, inside `MAX_LAG`. ed25519 keys; lite servers serve the chain of key blocks with their
  signatures. Whether equivocation is fined is unverified.
  https://github.com/ton-blockchain/ton/blob/master/tl/generate/scheme/lite_api.tl
- **State.** Cells hashed with SHA-256; `getAccountState` returns the account with shard and masterchain proofs, a
  native storage proof, so no `attest` is needed. ed25519 needs a zkVM.
- **Bridges.** The official bridge is an oracle multisig. No zk light client was found.
  https://github.com/ton-blockchain/bridge-solidity
- **Chain side.** **No BN254 in the TVM** (ed25519, secp256k1, P-256, Ristretto255 and BLS12-381 only), on master and
  testnet; TON's own zk guide uses BLS12-381. https://github.com/ton-blockchain/ton/blob/master/crypto/vm/tonops.cpp.
  P1 and P2 would need a BLS12-381 wrapper of their proofs, Cardano's situation, which couples the two proofs. A vault
  without `SETCODE` is immutable, but storage rent freezes an account in debt, so the vault needs a funded reserve.
- **Verdict.** The rule passes; P1 and P2 cannot run as specified. An owner decision, or wait for BN254.

### Internet Computer (ICP)

- **Finality.** Notarization and finalization at 2/3 of a subnet, "cryptographic finality... irreversible", about
  1 s. https://docs.internetcomputer.org/concepts/protocol/consensus/
- **Node set.** 42 subnets, application subnets of 13 nodes, the NNS of 40. Node providers are admitted by NNS
  proposal with identity documents and post no stake. Certification needs n − f shares: 9 of 13, 27 of 40. The root
  key "never changes", so there is no set to follow; a long-range attack by removed nodes that kept their shares is not
  bounded by any lag (inference; erasure of old shares unverified).
  https://github.com/dfinity/ic/blob/master/rs/consensus/certification/src/verifier.rs
- **State.** A canister sets up to 32 bytes of certified data; a certificate is the subnet's BLS signature over its
  state tree root, with an NNS delegation and `/time`. The vault certifies a Merkle root of its slots; Ethereum checks
  the delegation, the subnet signature and the paths: about 0.25 to 0.35M gas, no zkVM (estimate).
  https://github.com/dfinity/portal/blob/master/docs/references/ic-interface-spec.md
- **Chain side.** No pairing API, so BN254 runs in Wasm; the vault is Rust and reuses `crates/xindex-core`, the best
  reuse of the eleven. An empty controller list makes a canister immutable, but "only the NNS can uninstall it via a
  proposal". A canister out of cycles is deleted with its state, so a keeper must fund it. ICP itself lives in the
  ledger canister, which the NNS controls and upgrades.
  https://docs.internetcomputer.org/guides/canister-management/trust-in-canisters/
- **Verdict.** The rule passes and the Ethereum side is the simplest of all, but the trust is a permissioned, unstaked
  node set under NNS governance. An owner decision of Hedera's kind.

### Algorand (ALGO)

- **Finality.** BA* with VRF-sampled committees; safety holds "with overwhelming probability", committees sized for a
  5×10⁻⁹ failure at 80% honest stake. https://eprint.iacr.org/2017/454. The same question as Avalanche's.
- **Signers.** Any online account (2.02B of 9.74B ALGO online); no slashing. State proofs every 256 rounds, signed with
  Falcon-1024 by the top 1,024 online accounts, valid at 30% of their weight, each naming the next interval's signers;
  the latest is about 306 KB. https://mainnet-api.algonode.cloud/v2/stateproofs/65658112
- **State.** Headers commit to transactions but carry no account-state root; a failed call is never written to the
  chain, so an included `attest` proves its own success. Falcon has no EVM precompile: about 123 state proofs a day to
  prove in a zkVM, cost unmeasured.
- **Chain side.** AVM BN254 opcodes fit both proofs in one group for about 0.12 ALGO (estimate); an app that refuses
  Update and Delete is immutable, and its account holds ALGO.
- **Verdict.** First an owner decision on the rule; then an easy chain side and the heaviest Ethereum side.

### Aptos (APT)

- **Finality.** AptosBFT quorum certificates at 2/3 plus one, sub-second.
  https://github.com/aptos-labs/aptos-core/blob/main/types/src/validator_verifier.rs
- **Validator set.** 85 validators, the top 14 hold a third; epochs of 2 hours; "slashing is not implemented". The
  ledger info the current set signs carries `next_epoch_state`. **Signatures are BLS12-381 min-pk with
  `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, byte for byte the ciphersuite of `Bls12381.sol`**, which is reused as
  it is. https://github.com/aptos-labs/aptos-core/blob/main/crates/aptos-crypto/src/bls12381/mod.rs
- **State.** The signed root opens through transaction info to the Jellyfish Merkle tree of state, every hash
  SHA3-256, which Ethereum lacks: a Keccak-f permutation in Solidity (cost unmeasured) or a zkVM. Argument's zk Aptos
  light client (August 2024, on their SP1 fork) is prior art, unaudited and unmaintained since December 2024.
  https://argument.xyz/blog/aptos-eth/
- **Chain side.** BN254 enabled on mainnet; both proofs about 39% of a transaction (estimate);
  `upgrade_policy = immutable`; APT's freeze capability was destroyed at genesis. Governance can upgrade the framework.
- **Verdict. Passes, buildable now**, about NEAR's effort with a Move vault, for 0.030% of the universe.

## Cronos, Injective, Bittensor, Filecoin, VeChain and Ethereum Classic

| Chain | Deterministic finality | P1 and P2 on the chain | Its state, proven on Ethereum | Trust | Verdict |
|---|---|---|---|---|---|
| Cronos EVM (Cronos POS has no contracts) | yes: CometBFT, instant, 0.46 s blocks | yes: BN254 at EIP-1108 prices, Prague, 24 KB, 60M gas a block | an ed25519 light client and an ICS-23 proof of the `evm` store key `0x02‖addr‖slot`, in SP1 | 10 invitation-only validators, no slashing; one identity holds 46.9%; a 2-of-3 admin multisig keeps an encrypted, consensus-enforced blocklist | the rule passes; **owner decision** on a permissioned set and an admin censorship key |
| Injective | yes: CometBFT, instant, 0.60 s blocks | yes: BN254 at EIP-1108 prices, Prague, 150M gas a block; native INJ is the EVM coin | the same CometBFT and ICS-23 path | 45 permissionless PoS validators; top 15 hold 2/3; slashing reads 0 (checked here) | **passes**; the cheapest of the eleven |
| Bittensor | yes: Aura and GRANDPA, about 24 s | **no with the pinned verifiers:** 0x06 is Substrate's Dispatch, ecAdd is at 0x09 | GRANDPA ed25519 (14 of 20) and a Substrate storage proof, in a zkVM | one organisation: 20 Opentensor Foundation authorities, re-keyed by sudo, with forced changes | finality passes; trust fails in substance; **wait** for its NPoS roadmap |
| Filecoin | by design yes (F3); in practice **no: F3 has finalized nothing since 9 March 2026**; Expected Consensus alone is probabilistic, 7.5 hours | yes: both proofs about 3.8B of a 10B-gas block (inference) | F3 certificates (BDN-aggregated BLS with the NUL tag, about 1,490 a day), then CBOR, HAMT and KAMT paths, in a zkVM | permissionless storage power, top 156 of 473 entries hold 2/3; no slashing | **fails today**; waits on F3 running again, and staying up |
| VeChain | yes: the VIP-220 finality gadget, live since November 2022, about 60 to 90 minutes | yes: BN254 at EIP-1108 prices, 16.7M gas a transaction | about 360 secp256k1 headers per finalization and a blake2b Merkle-Patricia trie, in a zkVM; no proof API | 101 permissionless validators since Hayabusa (December 2025), 25M VET minimum; top 42 hold 2/3; no slashing; a 4-of-5 Executor sets consensus parameters | **passes**; a NEAR-sized build |
| Ethereum Classic | **no: proof of work**; 3,000-block reorgs in 2020 | BN254 yes, but not Cancun | only a probabilistic header chain | rentable hashrate | **fails the rule** |

### Cronos (CRO)

- **Where CRO lives.** Cronos POS (`crypto-org-chain-mainnet-1`) issues CRO, 98.96B in 8-decimal `basecro`. CRO on
  Cronos EVM is an IBC voucher from POS, converted to the 18-decimal EVM coin: 1.94B CRO, about 2% of supply, backed by
  POS's transfer escrow on channel-44 (both measured). Cronos POS wires no wasm or EVM module, so **Cronos EVM is the
  only possible host**, and its vault's CRO is sound only while both chains' validators are honest (inference).
  Sources: https://github.com/crypto-org-chain/chain-main/discussions/442,
  https://github.com/crypto-org-chain/cronos/blob/main/x/cronos/keeper/ibc.go,
  https://github.com/crypto-org-chain/chain-main/blob/master/app/app.go
- **Finality.** CometBFT on both chains: a committed block is final while fewer than a third are Byzantine. Measured
  0.46 s blocks on Cronos EVM. https://docs.cosmos.network/cometbft/latest/docs/introduction/intro
- **Validator set.**
  - 10 ed25519 validators on Cronos EVM (`cronosmainnet_25-1`, cronos v1.7.9), "by invitation only", bonding a
    non-market `stake` token, with both slashing fractions 0.
  - Four of them share one Keybase identity, which lists cronos.org, and hold 46.9% of power; six dApp-named nodes
    hold the rest. 2/3 takes 7 signers.
  - Whoever holds the unbonded `stake` could install a new majority; the holder is unverified.
  - Each header commits to `NextValidatorsHash`, so changes are followed from signed data.
    https://github.com/cometbft/cometbft/blob/main/spec/light-client/verification/README.md
- **State.** Header H+1's AppHash commits the IAVL multistore; EVM storage is the `evm` store's `0x02‖addr‖slot`,
  verified live with ICS-23 proof operations. `eth_getProof` returns ICS-23 bytes. The public node keeps about 77
  minutes of proofs, so a prover needs its own node, which fits `GRACE`.
  https://docs.cronos.org/for-node-hosts/running-nodes/memiavl
- **Bridges.** Third-party committees only (LayerZero, Symbiosis). The only Cronos light client found is an open pull
  request verifying ed25519 in plain Solidity at 7.8M gas a bundle.
  https://github.com/LFDT-CLPR/clpr-smart-contracts/pull/6
- **Chain side.** BN254 at EIP-1108 prices, EIP-2537, Prague, a 24,576-byte code limit and 60M gas a block, all
  measured: `XindexVault` runs as is. **But the `cronos_admin` 2-of-3 multisig alone may store a blocklist, encrypted to
  validators, that consensus enforces on a transaction's signer and on an EVM transaction's `to`.** It can censor every
  top-level call to the vault: deposits, deliveries, checkpoints.
  https://github.com/crypto-org-chain/cronos/blob/main/x/cronos/keeper/msg_server.go,
  https://github.com/crypto-org-chain/cronos/blob/main/app/proposal.go
- **Verdict.** The rule passes. The trust is a 10-node set where one identity holds over a third, unslashed, with a
  censoring admin key and IBC-backed coins: weaker than Hedera's council. An owner decision. Once Injective's verifier
  exists, Cronos costs about what BNB Chain did.

### Injective (INJ)

- **Finality.** CometBFT, instant; measured 0.60 s blocks on `injective-1` v1.20.4.
- **Validator set.** 45 permissionless ed25519 validators, 21-day unbonding; the largest holds 8.05%, the top 15
  reach 2/3, the top 6 a third. **Both slashing fractions read 0**, checked here on `sentry.lcd.injective.network`;
  staking providers' docs still say 5%, and when it changed is unverified. Changes follow `NextValidatorsHash`.
- **State.** As Cronos: the `evm` store's `0x02‖addr‖slot` under ICS-23, checked against `eth_getStorageAt` by the CLPR
  work. Injective's sentry keeps about 100 blocks of proofs, Polkachu's about 8 hours.
- **Bridges.** Peggy, the Injective Bridge, is validator-signed with delegated Ethereum keys, and its Ethereum contract
  is a proxy whose admin is a 3-of-5 Safe; it carries tokens, not state.
  https://github.com/InjectiveLabs/peggo/blob/master/docs/ARCHITECTURE.md. IBC Eureka reaches Ethereum through the
  Cosmos Hub; its **SP1 Tendermint light client is audited (Zellic, Sherlock, 2025) and measures 553k gas per packet**,
  and is the reference design. https://github.com/cosmos/ibc-contracts/blob/main/ibc-solidity/benchmarks/README.md
- **Chain side.** Native EVM since 11 November 2025 (chain 1776): BN254 at EIP-1108 prices, EIP-2537, Prague, 150M gas
  a block, no 24 KB limit; the EVM denom is native INJ with 18 decimals, so the vault holds it itself. Deployment is
  permissionless; governance could switch on an allow-list for new deployments. No admin key over EVM contracts was
  found. https://docs.injective.network/developers-evm/network-information
- **Verdict. Passes.** Deterministic, permissionless and unslashed today, like the TRON and Stellar sets the owner
  accepted. The path: `XindexVault` with the pinned verifiers, and on Ethereum a `CometBftStateVerifier`, one SP1
  statement of CometBFT light-client steps and the ICS-23 path, on the audited tendermint-rs and ics23 crates, about
  0.3M gas a proof (estimate). Each hop should require more than 2/3 of the trusted set, as BNB's does, rather than
  ibc-go's third (inference). The vault side costs nothing new; the verifier is smaller than NEAR's, and it serves
  Cronos too.

### Bittensor (TAO)

- **Finality.** Aura and GRANDPA, deterministic, about two 12-second blocks behind the head.
  https://github.com/opentensor/subtensor/blob/main/runtime/src/lib.rs
- **Validator set.** 20 GRANDPA authorities, all Opentensor Foundation nodes; changes are root-only, and
  `schedule_grandpa_change` allows forced changes a light client cannot follow; sudo is set; no slashing. The move to
  nominated proof of stake is still open. https://github.com/opentensor/subtensor/issues/1887,
  https://github.com/opentensor/subtensor/blob/main/pallets/admin-utils/src/lib.rs
- **State.** A Substrate blake2-256 trie; EVM slots in `AccountStorages`. Justifications need an own node. On Ethereum
  this is a zkVM proof of 14 of 20 ed25519 signatures, after sp1-vector. https://github.com/succinctlabs/sp1-vector
- **Chain side.** **Its precompile map puts Dispatch at 0x06 and ecAdd at 0x09**, while SP1's and our vendored RISC
  Zero verifier call ecAdd at 0x06 (`vendor/risc0-ethereum/src/groth16/Groth16Verifier.sol:101`). The pinned P1 and P2
  break; patching them changes vendored code and `DeployVault`'s pinned-verifier rule. TAO has 9 decimals under an
  18-decimal EVM.
- **Verdict.** Finality passes; the trust is one foundation, weaker than Hedera's council. Wait for its proof-of-stake
  phases.

### Filecoin (FIL)

- **Finality.** Expected Consensus is probabilistic, with a 900-epoch (7.5-hour) soft limit. F3 (FIP-0086) adds
  deterministic finality at 2/3 of power and went live on 29 April 2025. **It has finalized nothing since 9 March
  2026**: the latest certificate ends at epoch 5,824,156 against a head of 6,426,587, and Lotus now falls back to a
  probabilistic calculator. https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0086.md,
  https://github.com/filecoin-project/lotus/issues/13544
- **Power table.** 473 storage-provider entries; each certificate signs the next power table, so the set is followed
  from signed data, about 1,490 certificates a day. Signatures are BLS12-381 under the NUL tag, not the POP tag
  `Bls12381.sol` uses, BDN-aggregated. No slashing. https://github.com/filecoin-project/go-f3/blob/main/certs/certs.go
- **State.** A certificate signs a Merkle root of tipset keys; a slot opens through CBOR headers, the actors HAMT, the
  EVM actor and a KAMT. No `eth_getProof`. https://github.com/filecoin-project/builtin-actors/blob/master/actors/evm/src/state.rs
- **Chain side.** BN254 works on chain 314. Built-in actors change only by network upgrade.
- **Verdict. Fails today**: no live deterministic finality, and 7.5 hours misses `GRACE`. If F3 resumes and stays up,
  timing passes and the trust is TRON-like, but any F3 halt longer than a day stops the verifier for good.

### VeChain (VET)

- **Finality.** VIP-220 justifies and commits checkpoints over 180-block epochs at more than 2/3 of weight, live since
  November 2022; 66.5 minutes observed. Hayabusa (VIP-253, December 2025) made it stake-weighted.
  https://github.com/vechain/VIPs/blob/master/vips/VIP-220.md, https://github.com/vechain/VIPs/blob/master/vips/VIP-253.md
- **Validator set.** 101 validators, permissionless at 25M VET since Hayabusa; the top 42 hold 2/3; one secp256k1
  signature per block, no aggregate; no slashing. https://docs.stargate.vechain.org/overview/validators
- **State.** A geth-style trie hashed with blake2b-256 and no proof API, so a prover reads a node's database. Ethereum
  would check about 360 headers per finalization: in a zkVM, about 0.3M gas (estimate).
  https://github.com/vechain/thor/blob/master/trie/hasher.go
- **Chain side.** BN254 at EIP-1108 prices, a 24 KB code limit. **Every contract gets a Prototype "master"**, its
  creator, which can move its VTHO but not its VET, code or storage; clear it at deployment. A 4-of-5 Executor sets
  consensus parameters, including a staking pause. https://github.com/vechain/thor/blob/master/builtin/gen/prototype.sol
- **Verdict. Passes.** `XindexVault` as is, with an SP1 finality statement and a blake2b trie path: a NEAR-sized build,
  for VET's 0.03%.

### Ethereum Classic (ETC)

Proof of work (Etchash), with 3,000 to 4,000-block reorgs in August 2020, and MESS off since block 19,250,000. **Fails
the rule.** https://ecips.ethereumclassic.org/ECIPs/ecip-1099,
https://www.coindesk.com/tech/2020/08/06/ethereum-classic-suffers-second-51-attack-in-a-week,
https://ecips.ethereumclassic.org/ECIPs/ecip-1110
