# Stage C chains: research of 1 October 2026

Five read-only research passes asked, for each Stage C chain of the design (section 14 of
`design/2026-09-29-v4-hybrid-architecture.md`): is its finality deterministic, as the design's admission rule requires;
can Ethereum verify a vault's state there without trusting anyone beyond the chain's own consensus; and can P1 and P2,
Ethereum's finality proofs, be verified on it. Each pass read primary sources and queried public endpoints only;
nothing was deployed or sent. Claims marked as inferences or estimates are the researcher's reasoning, not measurements.
Section 8 of the Stage B spec (`design/2026-09-30-v4-stage-b-spec.md`) carries the summary.

## Summary

| Chain | Deterministic finality | P1 and P2 on the chain | Its state, proven on Ethereum | Verdict |
|---|---|---|---|---|
| Avalanche C-Chain | no as written: Snowman's safety is probabilistic, though accepted blocks never revert | yes: BN254 precompiles, Cancun, 24 KB | not today: validators BLS-sign accepted blocks with Xindex's ciphersuite, but nothing on mainnet signs the validator set's changes | blocked on Ava Labs shipping P-Chain validator-set signing, and on the owner's reading of the rule |
| NEAR | yes: Doomslug's BFT finality, two consecutive heights at more than 2/3 of stake | yes: BN254 host functions, about 65 Tgas for both proofs of a 1 PGas limit | not off the shelf: ed25519 approvals per 7.2-hour epoch need a zkVM light client, which nobody has built for production | buildable: a NEAR finality statement and its zk proof, a state verifier, and a Rust vault |
| Stellar | yes: SCP externalizes once and halts rather than forks | yes: BN254 host functions since protocol 25, about 7.5% of a transaction's budget per proof (estimated) | only by zk: at least 14 ed25519 signatures and a 100-400 KB transaction set per proof; the result of a vault `attest` proves its state, verified on mainnet data | buildable, with no on-chain anchor for Tier 1's changes |
| Hedera | yes: aBFT, with deterministic safety | yes: BN254 and BLS12-381 precompiles, Prague, 15M gas a transaction | not today: TSS block signatures are switched off on mainnet until about November 2026 (v0.79), and the WRAPS format is still moving | waits on Hedera's TSS cutover, and on the owner accepting the council's trust |
| Cardano | no: Praos is probabilistic, and Peras (a proposal, aimed at Q2 2027) is too | only through an unaudited BLS12-381 wrapper of both proofs: no BN254 | not to Xindex's standard: Mithril certifies inclusion, not success or unspentness, under operator-held genesis keys | fails the rule as written |

**Decisions for the owner.**
1. **Avalanche:** whether "irreversible acceptance with a negligible probability of a safety failure" passes the
   deterministic-finality rule. Nothing can be built until Avalanche signs its validator set's changes either way.
2. **Hedera:** whether a permissioned council of about 30 known organisations is an acceptable trust, since a proof
   then needs more than a third of their stake, about 11 of them.
3. **Cardano:** the rule excludes it as written; whether to restate the rule for a stake-quorum certificate.
4. **NEAR and Stellar** pass the rule. Each needs a new zk light client, and Stellar's quorum set has no on-chain
   anchor, so its rotations would rest on a rule of Xindex's own design.

**Order of work, if the owner keeps the list.** NEAR and Stellar can be built now and need the same three pieces as
Solana: a finality statement in plain Rust, tested natively and then proven in a zkVM; a state verifier on Ethereum; and
a vault in the chain's own language. Hedera follows its TSS cutover; Avalanche follows a P-Chain release that signs
validator sets.

## Avalanche C-Chain as an Xindex vault chain: research report (as of 2026-10-01)

**Short answer:** Most of a per-block proof already exists on Avalanche. Validators BLS-sign accepted C-Chain block hashes with the same ciphersuite Xindex's `Bls12381.sol` already uses, and headers commit to an Ethereum-style state root. What is missing on mainnet is a way to follow the validator set from data signed by the previous set. So a trustless verifier cannot be built today. Snowman's safety is probabilistic by Avalanche's own description, so the chain fails the deterministic-finality rule as written.

Context that changes several answers: on 2026-09-22 the Helicon upgrade moved the C-Chain to Continuous Execution (ACP-194, asynchronous execution). It also removed the `warp` RPC namespace.
- https://build.avax.network/blog/helicon-upgrade
- https://github.com/ava-labs/avalanchego/releases/tag/v1.15.0

### 1. Finality

**Probabilistic safety, but accepted blocks are irreversible.**
- Avalanche's docs say "Snowman Consensus is probabilistically safe up to a safety threshold". They also say "acceptance/rejection are final and irreversible". https://build.avax.network/docs/primary-network/avalanche-consensus
- The Frosty paper, co-authored by Ava Labs' Buttolph and Sekniqi, proves Snowman "satisfies consistency except with small error probability" for f < n/5. It contrasts Snowman with deterministic protocols. https://arxiv.org/abs/2404.14250
- Mainnet's default parameters are K=20, AlphaPreference=15, AlphaConfidence=15, Beta=20. https://github.com/ava-labs/avalanchego/blob/master/snow/consensus/snowball/parameters.go
- ACP-194 says "Snowman ... remove[s] any distinction between safe and finalized"; there are no reorgs. https://github.com/avalanche-foundation/ACPs/blob/main/ACPs/194-continuous-execution/README.md

**Signed finality certificate: none from consensus, but there is a Warp attestation.**
- Snowman produces no quorum certificate (inferred: nothing in the consensus docs or code above defines one).
- Validators will BLS-sign a Warp `Hash` payload naming any accepted C-Chain block. The SAE C-Chain signs "Hash payloads attesting that this chain accepted a given block" once `Backend.IsAccepted` passes.
  - https://github.com/ava-labs/avalanchego/blob/master/vms/saevm/cchain/warp/README.md
  - https://github.com/ava-labs/avalanchego/blob/master/vms/saevm/cchain/warp/verifier.go
- The block ID signed is the Ethereum-style header hash: `id: ids.ID(ethBlock.Hash())`. https://github.com/ava-labs/avalanchego/blob/master/graft/coreth/plugin/evm/wrapped_block.go
- Signing is a node policy run through the ACP-118 request handler, not a consensus rule.

**Aggregate-signature API.**
- coreth had `warp_getBlockAggregateSignature(blockID, quorumNum, subnetID)`. It aggregated over the validator set at the node's current P-Chain height. https://github.com/ava-labs/avalanchego/blob/master/graft/coreth/warp/service.go
- v1.15.0 removed the `warp` namespace and `warp-api-enabled` from the C-Chain. https://github.com/ava-labs/avalanchego/releases/tag/v1.15.0
- Today the route is the standalone ICM signature-aggregator (`/aggregate-signatures`), which collects signatures over ACP-118. https://github.com/ava-labs/icm-services/blob/main/icm-contracts/tests/utils/signature_aggregator.go

**Scheme, curve and threshold.**
- BLS12-381 with public keys in G1 (48 B compressed, 96 B uncompressed) and signatures in G2 (96 B).
- The ciphersuite is `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`, with proof of possession at registration.
  - https://github.com/ava-labs/avalanchego/blob/master/utils/crypto/bls/ciphersuite.go
  - `public.go` and `signature.go` in the same directory.
- This is the same DST and layout as Xindex's `src/libraries/Bls12381.sol`, so that library is reusable.
- The signature is a `BitSetSignature` (a signer bitset plus a 96 B aggregate). The canonical set is sorted by uncompressed public key; validators sharing a key are merged; total weight counts validators without keys. https://github.com/ava-labs/avalanchego/blob/master/snow/validators/warp.go
- The threshold is chosen by the receiver. Avalanche's default is 67/100, with a minimum of 33. https://github.com/ava-labs/avalanchego/blob/master/graft/coreth/precompile/contracts/warp/config.go

### 2. Validator set

**Who signs.** The Primary Network validators sign; the C-Chain's validator set is the Primary Network's. Each registers a BLS key on the P-Chain. https://build.avax.network/docs/cross-chain/avalanche-warp-messaging/evm-integration

**Size and weights.** Live `platform.getCurrentValidators` at https://api.avax.network/ext/bc/P, 2026-10-01 19:13 UTC:
- 588 validators, all with BLS keys, 587 distinct keys.
- About 195.8M AVAX of weight, including delegations.
- The largest validator holds 1.5% of weight.
- The top 79 validators reach 67%, and 121 reach 80%.

**How the set changes.**
- P-Chain staking transactions, which start and end validations and delegations.
- Minimum stake is 2,000 AVAX. Validation lasts 48 hours (since Helicon) to 1 year. Maximum weight is min(3M AVAX, 5× own stake). https://build.avax.network/docs/primary-network/validate/how-to-stake
- ACP-236 adds auto-renewal; 13 validators use it so far (live data).
- Churn from the live data:
  - 3.2% of weight ends within 1 day, 16.3% within 7 days and 46.7% within 30 days.
  - 10% of weight started within the last 7 days.
- Avalanche has no slashing. This comes from a secondary source; I did not find it on the official staking page. https://docs.avascan.info/guide-delegation-avalanche-network/choose-validator-node-avalanche

**Can Ethereum follow the set trustlessly? Not on mainnet.**
- The released P-Chain (master and v1.15.0) signs only three ACP-77 payloads: `SubnetToL1Conversion`, `L1ValidatorRegistration` and `L1ValidatorWeight`. None of them describes the Primary Network's own set. https://github.com/ava-labs/avalanchego/blob/master/vms/platformvm/network/warp.go
- ACP-181 (activated in Granite, mainnet 2025-11-19) only fixes the P-Chain height used per roughly 5-minute epoch. It "does *not* introduce epochs to the P-Chain's VM directly", and it adds no signed commitment.
  - https://build.avax.network/docs/acps/181-p-chain-epoched-views
  - https://build.avax.network/blog/granite-upgrade
- ACP-75 (acceptance proofs: BLS proofs that a block was accepted) is still "Proposed". https://github.com/avalanche-foundation/ACPs/blob/main/ACPs/75-acceptance-proofs/README.md
- **The exact mechanism Xindex needs exists only on an unreleased branch.**
  - avalanchego commit `cf35cc4` (2026-09-10) on branch `icm-services-patch-v1.15.0` adds P-Chain ACP-118 signing of four payloads: `ValidatorSetMerkleCommitment`, `ValidatorSetState`, `ValidatorSetDiff` and `ValidatorSetMetadata`.
  - A validator signs a commitment only if it matches its own canonical set at the stated P-Chain height. https://github.com/ava-labs/avalanchego/commit/cf35cc4cbf6254b02593fbf3b0276a4f8da96272
  - icm-services runs its tests against it as "an instrumented version for testing; differs from the version in go.mod". https://github.com/ava-labs/icm-services/blob/main/scripts/versions.sh
  - I found no ACP for it.

**Existing light clients on Ethereum or other EVM chains:**
| Project | What it does | Trustless? |
|---|---|---|
| Ava Labs `MerkleValidatorSetRegistry` / `ZKValidatorSetRegistry` (SP1) in icm-services | Ethereum-side registry of Avalanche validator sets | No, not today: marked "EXAMPLE … UN-AUDITED … DO NOT USE IN PRODUCTION"; its first set is an unauthenticated constructor argument; updates need the unreleased P-Chain signing above |
| Polyhedra zkBridge | Ethereum as sender, "BNB Chain and Avalanche as the receiver chain", so it proves Ethereum, not Avalanche | Not an Avalanche light client |
| LayerZero DVNs | Operator-run verifiers. A Polyhedra DVN is deployed on Avalanche; how it verifies an Avalanche source is not documented (unverified) | Trust in DVN operators |
| Avalanche Bridge | Intel SGX plus 3-of-4 "Wardens" | No |
| Succinct | No Avalanche light client found | n/a |

Sources for the table:
- https://github.com/ava-labs/icm-services/blob/main/docs/external-interop/origin_avalanche/validator_set_registry.md
- https://github.com/ava-labs/icm-services/blob/main/icm-contracts/ethereum/MerkleValidatorSetRegistry.sol
- https://github.com/ava-labs/icm-services/blob/main/icm-contracts/ethereum/ZKValidatorSetRegistry.sol
- https://www.theblock.co/post/241003/proving-full-node-of-ethereum-in-zk
- https://docs.layerzero.network/v2/deployments/dvn-addresses
- https://medium.com/avalancheavax/avalanche-bridge-secure-cross-chain-asset-transfers-using-intel-sgx-b04f5a4c7ad1 (secondary)

### 3. State commitment

**Headers.** Headers are Ethereum-style plus extra fields.
- Since Helicon, `stateRoot` is the post-state of block `settledHeight`, an ancestor about 5 s (τ) back. It is not the block's own post-state.
- The extras include `settledHeight`, `timestampMilliseconds` and `extDataHash`; `withdrawalsHash` is removed.
  - https://github.com/ava-labs/avalanchego/blob/master/vms/saevm/cchain/README.md
  - ACP-194 §"Block settlement" (link in section 1)
- Validators must let execution catch up before judging a block valid, so the root is checked by consensus (ACP-194).
- Live block 96,550,381 carried `settledHeight` 96,550,376.

**eth_getProof works.**
- It is in the enabled `chain` API set. https://github.com/ava-labs/avalanchego/blob/master/vms/saevm/cchain/config.md
- I verified it on mainnet. `eth_getProof` at block S returned an account-proof root equal to the `stateRoot` of the later header whose `settledHeight == S` (S = 96,550,435, header 96,550,437), via https://avalanche-c-chain-rpc.publicnode.com.
- Two limits:
  - api.avax.network does not serve the method.
  - A pruned node fails 128 blocks back ("missing trie node"), so proofs need an archive node (`pruning-enabled: false`).
- How the RPC serves state under SAE: https://github.com/ava-labs/avalanchego/blob/master/vms/saevm/sae/rpc/README.md

### 4. Ethereum-side cost (my estimate, not measured)

EIP-2537 gas: G1ADD 375, G2ADD 600, MAP_FP2_TO_G2 23,800, pairing 32,600·k + 37,700. https://eips.ethereum.org/EIPS/eip-2537

Per state proof with a Merkle-root set commitment:
- **Fixed BLS part, about 160k:**
  - a 2-pair pairing check, 102,900;
  - hash-to-G2, about 52k.
- **Per signer, about 2.4k plus Merkle siblings:**
  - aggregating each key with G1ADD, about 0.7k;
  - 104 B of calldata each (96 B key and 8 B weight), about 1.7k.
- **Header and MPT account-plus-slot proof:** about 0.2–0.25M (inferred).

| Signers | Estimated total |
|---|---|
| Minimal quorum, 79 signers (needs the individual signatures) | about 0.7–0.8M gas |
| All about 588 signers, or a flat set hash | about 1.8M gas |
| Wrapped in one SP1 Groth16 proof, as Ava Labs' ZK registry does | about 0.3M, plus the MPT unless that is proven too |

For calibration, Xindex's BNB verifier asserts under 1.1M for a two-slot state proof (`test/BnbStateVerifier.t.sol`).

### 5. Chain side for P1 and P2

All of these were probed on mainnet with read-only `eth_estimateGas` and `eth_call` against https://api.avax.network/ext/bc/C/rpc, chain ID 43114.
- **BN254 precompiles 0x06–0x08 exist, at Ethereum's EIP-1108 prices.** Estimates matched 150, 6,000 and 45,000 + 34,000·k within geth's 1.5% estimate tolerance. The pairing precompile returned 1 on a trivial input.
- **Contract size limit is 24,576 bytes.** One byte more gives "max code size exceeded".
- **EVM fork:**
  - Cancun opcodes per ACP-131: TSTORE/TLOAD, MCOPY and BLOBBASEFEE all ran. Blob transactions are excluded. https://github.com/avalanche-foundation/ACPs/blob/main/ACPs/131-cancun-eips/README.md
  - No EIP-2537 precompile at 0x0b and no `requestsHash`, so not Prague.
  - CLZ (0x1e) is undefined, so not Osaka.
  - The secp256r1 precompile at 0x100 exists (ACP-204).
- **Gas limits:**
  - The block gas limit was 80,000,000 at the probed block.
  - It is dynamic: ω_B = R·τ·λ = 20·T. With targetExponent 46,516,320, T = 1M·e^(q/2^25) ≈ 4M gas/s.
    - https://github.com/avalanche-foundation/ACPs/blob/main/ACPs/176-dynamic-evm-gas-limit-and-price-discovery-updates/README.md
    - ACP-194 (link in section 1)
  - I found no per-transaction cap below the block maximum (inferred).
  - Node RPCs cap `eth_call` at 50M gas; that is an RPC setting, not a consensus rule.
- A roughly 300k-gas Groth16 verification fits easily.
- RISC Zero has Groth16 verifiers deployed on Avalanche mainnet; SP1's deployments list has no 43114 entry. Xindex deploys its own verifiers anyway.
  - https://github.com/risc0/risc0-ethereum/blob/main/contracts/deployment.toml
  - https://github.com/succinctlabs/sp1-contracts/tree/main/contracts/deployments

### 6. Verdict

**Trustless Avalanche → Ethereum verifier today: no.**
- The per-block part exists:
  - a BLS attestation of an accepted block hash;
  - a header whose `stateRoot` is consensus-checked;
  - `eth_getProof`.
- **What is missing is the hand-off of the validator set.**
  - Nothing on mainnet signs or commits to the Primary Network validator set.
  - P-Chain blocks carry no certificate, and ACP-75 is only proposed.
  - The signer for `ValidatorSetMerkleCommitment`, `ValidatorSetState` and `ValidatorSetDiff` lives only on an instrumented branch with no ACP.
- Freezing a set is unsafe: 47% of weight turns over within 30 days, validations can be as short as 48 hours, and there is no slashing (the last from a secondary source).

**If that P-Chain signer ships in a release run by a quorum of stake, here is what a verifier would do:**
1. **Store** (P-Chain height, Merkle root over the canonical (uncompressed key, weight) set, total weight).
2. **Update the set** with a Warp message from the P-Chain (network ID 1, P-Chain ID, `AddressedCall` with an empty sender and a `ValidatorSetMerkleCommitment` payload). It must be signed by at least the threshold of the stored set; signers come with a multiproof. Updates should be frequent, with a staleness bound like BNB's `MAX_LAG`.
3. **Each state proof carries:**
   - the Warp `UnsignedMessage`: codec 0, network ID 1, C-Chain ID `2q9e4r6Mu3U68nU1fYjgbR6JvwrRx36CohpAX5UQxse55x1Q5`, and a `Hash` payload naming block M;
   - signers (keys and weights) with a multiproof and the G2 aggregate;
   - M's RLP header, including the Avalanche extras;
   - parent headers back to `settledHeight` S, if the evidence's lower time bound needs S's own timestamp (inferred);
   - account and storage proofs against M's `stateRoot`.
4. **The contract checks:**
   - signer membership and that their weight meets the threshold;
   - the BLS signature;
   - the message fields;
   - that keccak(header) equals the signed hash;
   - the MPT proofs.
   It then reads the state as of block S.

A Tron-like alternative would skip the header and MPT. The vault calls the Warp precompile `sendWarpMessage` (0x0200…05) with the slot values, and Ethereum checks the signed `AddressedCall`. That is signable only after the block executes (cchain warp README); it still needs the same set tracking.

**Deterministic-finality rule: fails as written.** Avalanche and the Frosty paper describe Snowman's safety as probabilistic (ε). Unlike Cardano or Ethereum Classic, though, there is no fork choice or confirmation depth, and accepted blocks never revert. The owner should decide explicitly whether "irreversible acceptance with negligible-ε safety" counts. The Warp 67% BLS quorum is an attestation layered on consensus, not a consensus certificate. The rule is at `design/2026-09-29-v4-hybrid-architecture.md:833-835`.

**Flags:**
- The ACP repo still lists ACP-194 as Implementable and ACP-236/273 as Proposed, although v1.15.0 and the Helicon blog say all three activated on mainnet on 2026-09-22.
- The precompile prices come from `eth_estimateGas`, not traces.
- Everything in section 4 is an estimate.

## NEAR as an Xindex vault chain: research report

**Short answer:** NEAR passes the admission rule, because its BFT finality is deterministic. Ethereum → NEAR is easy: NEAR has BN254 host functions, and checking both P1 and P2 costs about 65 Tgas, well under the call limit (now 1 PGas, not 300 Tgas). NEAR → Ethereum is the hard part. No trustless NEAR light client runs on Ethereum today. The practical route is a zk proof of NEAR's ed25519 approvals, one hop per epoch, followed by SHA-256 Merkle proofs that can be checked in Solidity. Nothing reusable exists for it: the existing NEAR clients are either optimistic and admin-controlled, or abandoned prototypes.

Live figures come from read-only queries to https://rpc.mainnet.near.org on 2026-10-01 (mainnet protocol 86, nearcore 2.13.4). Anything marked **(inferred)** is my reasoning, not something I read in a source.

---

### 1. Finality

**Two kinds of finality.** NEAR's consensus is Doomslug, which records two finality levels in every header: `last_ds_final_block` and `last_final_block` (https://github.com/near/nearcore/blob/master/protocol-model/spec/consensus-finality.md).
- **Doomslug finality** takes one round of approvals. A block is ds-final when its child is at the very next height. This is the fast, optimistic level.
- **BFT finality** needs two consecutive heights: a block is final once it has a child at the next height, which itself has a child at the next height. The spec says this level is "never reverted".
- Nomicon's definition: "B is final … when … B=prev(prev(X)) and h(X)=h(prev(X))+1=h(B)+2" (https://nomicon.io/ChainSpec/Consensus).

**It is deterministic.** The safety theorem says two conflicting final blocks require that "more than 1/3 of the block producers in some epoch must have signed either conflicting endorsements or conflicting skip and endorsement" (https://nomicon.io/ChainSpec/Consensus; paper: https://discovery-domain.org/papers/doomslug.pdf). Under fewer than 1/3 Byzantine stake this is deterministic BFT finality, not probabilistic finality.

**Caveat: slashing is inactive.** nearcore's model says "Slashing is inactive … no code path produces a slash", and challenges are rejected at header validation (https://github.com/near/nearcore/blob/master/protocol-model/spec/epoch-validators-staking.md, consensus-finality.md). docs.near.org still says misbehaving validators get slashed (https://docs.near.org/protocol/network/validators); the code says otherwise. So safety is accountable but carries no economic penalty, much like Tron, which Xindex already admits **(inferred comparison)**.

**What is signed.**
- An `Approval` is `{inner: Endorsement(prev_hash) | Skip(prev_height), target_height}`. The signed bytes are `borsh(inner) ++ target_height.to_le_bytes()`. The signature does not cover `account_id`.
- Block production needs approvals from more than 2/3 of this epoch's block-producer stake, and also more than 2/3 of the next epoch's stake at boundaries (consensus-finality.md).
- The scheme is ed25519. All 411 live validator keys and every live approval I sampled are `ed25519:`. nearcore checks them with `ed25519_dalek` `verify`, the non-strict variant (https://github.com/near/nearcore/blob/master/core/crypto/src/signature.rs).

**Where the signatures appear.**
- Each header carries an `approvals: Vec<Option<Signature>>`, ordered by `get_epoch_block_approvers_ordered`.
- A light-client view takes `approvals_after_next` from the block two after B. Its builder requires the three blocks to "have sequential heights" (https://github.com/near/nearcore/blob/master/chain/chain/src/lightclient.rs).
- The light-client message is `borsh(Endorsement(next_block_hash)) ++ LE(height+2)` (https://nomicon.io/ChainSpec/LightClient).

**Timing.** I measured 0.596 s per block over the current epoch (RPC). Press reports put finality at about 1.2 s (secondary: https://cryptonews.com/news/near-announces-600-millisecond-block-time/).

### 2. Validator set

**Seats and live counts.**
- Mainnet epoch config: 100 block-producer seats, 100 chunk-producer seats, 500 chunk-validator seats, epoch length 43,200 blocks (https://github.com/near/nearcore/blob/master/core/primitives/res/epoch_configs/mainnet/85.json; confirmed by `EXPERIMENTAL_protocol_config`).
- Live: 411 validators. 100 are expected to produce blocks, 100 to produce chunks, and all 411 to endorse chunks. There are 10 shards (RPC `validators` and `protocol_config`).

**Stake.**
- Block-producer stake is 501.2M NEAR out of 551.1M total. The largest producer holds 6.34%.
- Only producers vote on finality. Today the **24 largest producers together exceed 2/3**.
- A sampled light-client block had 87 of 100 approvals present (RPC `next_light_client_block`).

**Epochs.**
- 43,200 blocks at about 0.6 s is about 7.2 h, so roughly 3.3 epochs a day **(inferred)**.
- The boundary is "finality-driven". The set for epoch T+2 is computed at the end of epoch T (epoch-validators-staking.md).

**How the next set is committed.** Each header's `inner_lite.next_bp_hash` equals `sha256(borsh(next_bps))`.

**The official light client** (https://nomicon.io/ChainSpec/LightClient) stores the head and the producer lists for the current and next epochs. `validate_and_update_head` checks six things:
1. The height is above the head's.
2. `epoch_id` is either the head's epoch or its `next_epoch_id`.
3. A block in the next epoch must carry `next_bps`.
4. Every present signature verifies against that epoch's ordered producers.
5. Approved stake is strictly above `total_stake*2//3`.
6. `sha256(borsh(next_bps)) == next_bp_hash`; if so, the client stores `next_bps` for `next_epoch_id`.

**Following epochs.** The client must verify one view per epoch and cannot skip one. Any older block is then proven against the head's `block_merkle_root`. Near a boundary, `approvals_after_next` may carry extra entries; Rainbow's code says the client ignores them (NearBridge.sol line 211).

### 3. State proofs

NEAR hashes everything with SHA-256 (https://github.com/near/nearcore/blob/master/core/primitives-core/src/hash.rs), so Ethereum's SHA-256 precompile covers both routes below.

**(a) Outcome route.**
- `EXPERIMENTAL_light_client_proof` returns `outcome_proof`, `outcome_root_proof`, `block_header_lite` and `block_proof`.
- I ran it on mainnet today and it works; `block_proof` had 17 nodes.
- Checking it is Merkle paths only: outcome leaf, then `outcome_root`, then the block hash, then the head's `block_merkle_root`. Rainbow's `NearProver.proveOutcome` does exactly this in Solidity (https://github.com/aurora-is-near/rainbow-bridge/blob/master/contracts/eth/nearprover/contracts/NearProver.sol).
- The header's outcome root covers outcomes "from the previous chunks", so it lags by one block (https://github.com/near/nearcore/blob/master/core/primitives/src/block_header.rs).

**(b) Storage route.**
- `view_state` with `include_proof: true` returns trie nodes (`ViewStateResult.proof`: https://github.com/near/nearcore/blob/master/core/primitives/src/views.rs). The public docs do not mention the flag (https://docs.near.org/api/rpc/contracts), but it works: for lockup.near it returned 17 nodes, about 2.5 kB.
- Trie format (https://github.com/near/nearcore/blob/master/protocol-model/spec/state-storage.md, trie_key.rs):
  - node hash = `sha256(borsh(RawTrieNodeWithSize))`;
  - key = `0x09 ++ account_id ++ ',' ++ key`;
  - values are referenced by their hash.
- The proof is against the shard's post-state root (`ChunkExtra`) at the queried block. A header commits only `merklize(chunk.prev_state_root)` (`compute_state_root` in https://github.com/near/nearcore/blob/master/core/primitives/src/block.rs). So the verifier must take the root from a later block's new chunk for that shard **(inferred mapping; needs a missing-chunk test)**.
- Public RPC refuses accounts above 50 kB of state: I got `TOO_LARGE_CONTRACT_STATE` for wrap.near even with a prefix. Resharding also moves accounts between shards (10 shards today, a dynamic-resharding config exists).

**Which is practical.** Route (a), mirroring Tron's `attest`. The vault would expose an `attest()` method that returns or logs its record, and the proof would use the official RPC and SHA-256 paths only **(inferred recommendation)**. The cost is that someone must send the `attest` transaction on NEAR.

**Upcoming format change.** SPICE adds `BlockHeaderInnerLiteV2` with `chunk_execution_root` and changes when state roots appear. It sits at protocol 180, behind its own feature build: it is in neither stable (88) nor nightly (157) (https://github.com/near/nearcore/blob/master/core/primitives-core/src/version.rs). When it ships, Xindex will need to rotate its verifier.

### 4. Existing NEAR → Ethereum light clients

**Rainbow's NearOnEthClient is optimistic** (https://github.com/aurora-is-near/rainbow-bridge/blob/master/contracts/eth/nearbridge/contracts/NearBridge.sol).
- `addLightClientBlock` only sums the stake of present approvals, checks the epoch and checks the `next_bps` hash. It verifies no signature.
- A bonded submitter's block can be challenged during `lockDuration` (4 h per https://docs.near.org/chain-abstraction/omnibridge/how-it-works). A challenge checks one ed25519 signature in Solidity.
- It is `AdminControlled`, so an admin can pause adding blocks and verification.
- This fails Xindex's rule: it relies on watchers and an admin.

**No fully verified client exists.**
- A secp256k1 "pessimistic" design (about 0.5–0.6M gas a block) was proposed and declined by NEAR's engineers (https://github.com/Near-One/rainbow-bridge/discussions/447). That thread also puts Rainbow's relay cost at about 700k gas a block.
- Omni Bridge, the successor, uses MPC chain signatures (`nearBridgeDerivedAddress`, https://github.com/Near-One/omni-bridge/blob/main/evm/src/omni-bridge/contracts/OmniBridge.sol). That is a committee, which also fails the rule.

**zk clients are prototypes only.**
- `near/near-light-client` "nearx" uses plonky2x on Succinct's earlier platform. Its sync circuit takes about 38 s on a Ryzen 7950X. `NearX.sol` is UUPS-upgradeable, owner-controlled, and has an `onlyOwner setCheckpointHeader`. Last push was 2024-07-16 (https://github.com/near/near-light-client).
- Electron Labs built a circom prototype: 99 signatures prove in about 16 minutes and verify for about 300k gas (https://ethresear.ch/t/verify-ed25519-signatures-cheaply-on-eth-using-zk-snarks/13139).
- I found no production zk NEAR client. That rests on searches, so it is an absence of evidence, not proof.

**Cost estimates for Xindex.**

| Approach | Cost per epoch hop | Notes |
|---|---|---|
| ed25519 in Solidity | ≈12M + ~0.7M ≈ **12.7M gas** today | ~500k gas per signature (reported in the ethresear.ch post above, not re-measured), times the 24 signatures needed. |
| Same, ~3.3 hops a day | ≈ 42M gas a day | ≈ 0.04 ETH a day at 1 gwei, illustrative only. |
| Same, all 87 present signatures | ≈ 43M gas | Above the 2^24 per-transaction cap. |
| Same, a flat stake distribution | ~67 signatures ≈ 34M gas | Also above the cap. |
| zk proof (SP1 or RISC Zero) | ~227k gas per Groth16 | Xindex's own SP1 v6 measurement (`design/2026-09-30-proving-prototype.md:220`). One proof can chain any number of epochs. |

- Both zkVMs accelerate `curve25519-dalek`: SP1 through `ED_ADD`/`ED_DECOMPRESS` syscalls (https://github.com/succinctlabs/sp1/blob/main/crates/zkvm/entrypoint/src/syscalls/ed25519.rs), RISC Zero through a patched 4.1.x (https://github.com/risc0/risc0/blob/main/website/api/zkvm/precompiles.md).
- **The proving cost per hop is unmeasured.** Each hop is up to 100 ed25519 verifications, SHA-512 inside each, and about 8 kB of `next_bps` to hash. This needs measuring.

### 5. NEAR side for P1 and P2

**BN254 host functions exist.** `alt_bn128_g1_multiexp`, `alt_bn128_g1_sum` and `alt_bn128_pairing_check` were stabilized in nearcore 1.28.0 (2022) (https://github.com/near/nearcore/blob/master/CHANGELOG.md).

**Encoding differs from EVM and Solana.** NEAR packs points little-endian, with Fq2 as (re, im), in 192-byte pairs (https://github.com/near/nearcore/blob/master/runtime/near-vm-runner/src/logic/host.rs, alt_bn128.rs). EVM and the Solana port use big-endian with the imaginary part first. The verifier's encoding must be adapted **(inferred)**.

**Live gas costs.** Pairing costs 9.686 Tgas plus 5.102 Tgas per pair. Multiexp costs 0.713 Tgas plus 0.32 Tgas per element. `g1_sum` costs 0.003 Tgas plus 0.005 Tgas per element.

**One Groth16 proof.** SP1 v6 has 5 public inputs (`prototype/evm/src/sp1/SP1VerifierGroth16.sol:74`), and so does RISC Zero (https://github.com/risc0/risc0-ethereum/blob/main/contracts/src/groth16/RiscZeroGroth16Verifier.sol).

| Step | Gas |
|---|---|
| 4-pair pairing check | 30.1 Tgas |
| 5-element multiexp | 2.3 Tgas |
| **One proof** | **≈ 32.4 Tgas** |
| **P1 + P2 together** | **≈ 65 Tgas** plus Wasm logic |

**The call limit is now 1 PGas, not 300 Tgas.** nearcore 2.11.0 says "Contract gas limit is increased from 300 TGas to 1 PGas" (https://github.com/near/nearcore/releases/tag/2.11.0), and live `max_gas_burnt` is 10^15. So both proofs fit easily. At the live gas price of 10^8 yocto per gas, that is about 0.0065 NEAR **(inferred arithmetic)**.

**Ownerless vault.**
- **Use a deterministic account.** NEP-616 `0s` accounts are derived from `keccak256(state_init)`; only the contract itself can act on such an account, and it can be referenced by `GlobalCodeHash` (https://github.com/near/NEPs/blob/master/neps/nep-0616.md). Do not use `GlobalAccountId`, which follows whatever its owner deploys next **(inferred)**.
- **Or delete every full-access key.** Deleting keys locks the account, but "a locked contract can still upgrade itself if its code exposes" a method for it (https://docs.near.org/smart-contracts/release/lock). The code must have no such method.
- **Storage staking** costs 10^19 yocto per byte (1 NEAR per 100 kB). A write fails if the balance cannot cover it, and docs warn of the "million cheap data additions" attack (https://docs.near.org/protocol/storage/storage-staking). Depositors must pay for the storage they create.
- **Plain transfers are invisible.** NEAR runs no code when a contract receives a plain transfer, and refunds arrive as separate receipts (NEP-616 §Refunds). Until protocol 87, contracts also receive 30% of burnt gas (https://github.com/near/nearcore/blob/master/core/parameters/res/runtime_configs/parameters.yaml, 87.yaml). So the vault must keep a book and never read its balance, which is already Xindex's rule.
- **Cross-contract calls are asynchronous** with no rollback (https://docs.near.org/smart-contracts/anatomy/crosscontract). The Groth16 checks should be compiled into the vault itself rather than called on a separate verifier contract **(inferred)**.

### 6. Verdict

**Admission rule: passes.** `last_final_block` (two consecutive heights, more than 2/3 of producer stake) is deterministic BFT finality. Two caveats: slashing is inactive, and only BFT-final blocks may be used, never ds-final ones.

**Can it be built trustlessly today? Not off the shelf.** Every existing NEAR → Ethereum path is optimistic, admin-controlled, MPC-based, or an abandoned prototype. Pure Solidity works only while stake stays concentrated, and costs about 13M gas per 7.2 h epoch. The viable design is zk.

**What would need to be written:**
1. **A NEAR finality statement in plain Rust**, tested natively first, like `proofs/finality`.
   - Input: a trusted (epoch_id, producer-set hash).
   - Then a chain of `LightClientBlockView`s, verified per the spec with dalek's `verify`, counting only verified stake.
   - Output: the head hash, its `block_merkle_root` and the next producer-set hash.
   - Then an SP1 program for it, and a RISC Zero twin if Xindex wants two-system symmetry.
2. **A NEAR state verifier on Ethereum** holding the checkpoint and a lag limit like `MAX_LAG`. It accepts a Groth16 proof that advances the checkpoint, then checks the attest receipt in Solidity (Borsh decoding plus SHA-256 paths, the `NearProver` pattern).
3. **Real-data fixtures and their generator**: blocks across an epoch boundary, light-client proofs, and `view_state` proofs including a missing chunk.
4. **The NEAR vault in Rust/Wasm**, twin of `XindexVault`: messages, digests, speed limit, freeze, and `attest`. It would run at a `0s` account with code fixed by hash, embed P1 and P2 Groth16 checks over little-endian alt_bn128, and port P1's Ethereum receipt verifier from `solana/programs/ethereum-verifier`.
5. **A plan for format changes**: SPICE's new header, and shorter blocks (the press reports a ~200 ms target) would mean more epochs a day, so more hops to prove.

**Open uncertainties:**
- zkVM proving cost per epoch hop (unmeasured).
- The ~500k gas per Solidity ed25519 check is reported, not re-measured.
- Mapping a state root to a header when a chunk is missing (inferred).
- `include_proof` is undocumented.
- Live figures are a single snapshot from 2026-10-01.

Context: Xindex's design already lists NEAR, at 0.28% weight, in Stage C, "each only if its finality is deterministic, its proof cost is measured…" (`design/2026-09-29-v4-hybrid-architecture.md:814`).

## Stellar (XLM) as an Xindex vault chain, with a Soroban vault


I checked the whole proof path end to end on real mainnet data: the checkpoint ending at ledger 64,719,295 (protocol 29), plus tx `36a3f043…`. I did this with a pure-Python RFC 8032 ed25519 check and SHA-256 (the researcher's scripts, not committed). Labels: **[read]** means read in a source, **[verified]** means I checked it against chain data, **[inference]** means my own reasoning.

### 1. Finality

**Deterministic? Yes.**
- A value is output when a node "confirms commit(b)" and enters EXTERNALIZE. "No two well-behaved nodes will confirm contradictory statements" when quorum intersection holds [read] (https://datatracker.ietf.org/doc/html/draft-mazieres-dinrg-scp-05).
- "SCP prioritizes fault tolerance and safety over liveness" [read] (https://developers.stellar.org/docs/learn/fundamentals/stellar-consensus-protocol). "There is no branching in SCP" [read] (https://stellar.org/blog/developers/issuer-enforced-finality-explained).
- The network halts rather than forks. It stopped for 67 minutes on 2019-05-15 [read] (https://stellar.org/blog/developers/may-15th-network-halt).
- The target close time is 5,000 ms (on-chain `ConfigSettingSCPTiming` via RPC) [verified]. Horizon showed an average of 5.0 s over the last 20 ledgers [verified].
- **Caveat [inference]:** safety depends on quorum intersection. That is a property of the configured topology, not a fixed stake threshold. Monitors report `hasQuorumIntersection: true` today [verified] (https://radar.withobsrvr.com/api/v1).

**What signs a closed ledger.**
- Each validator signs its own `SCPEnvelope` with ed25519. The signed bytes are `networkID ‖ ENVELOPE_TYPE_SCP(=1) ‖ XDR(SCPStatement)`: raw bytes, not a hash (`HerderImpl::signEnvelope`/`verifyEnvelope`; `SecretKey::sign` uses `crypto_sign_detached` and asserts ED25519) [read] (https://github.com/stellar/stellar-core/blob/master/src/herder/HerderImpl.cpp, https://github.com/stellar/stellar-core/blob/master/src/crypto/SecretKey.cpp).
- The EXTERNALIZE statement is `{SCPBallot commit{counter, value}; nH; commitQuorumSetHash}` [read] (https://github.com/stellar/stellar-xdr/blob/curr/Stellar-SCP.x).
- I checked 30 of 30 EXTERNALIZE signatures for ledger 64,719,295, with networkID = SHA-256 of the passphrase [verified].
- The externalized value is the XDR `StellarValue {txSetHash, closeTime, upgrades, ext}` (152 bytes) [read] (https://github.com/stellar/stellar-xdr/blob/curr/Stellar-ledger.x). For 64 of 64 ledgers it was byte-equal to `header.scpValue` [verified].
- The `lcValueSignature` inside it is one nominator's signature, not a quorum's.

**Portable proof.** Yes, but it has an important wrinkle.
- SCP for slot N signs only `StellarValue_N`. That commits to the tx set but **not** to header N's hash, `txSetResultHash` or `bucketListHash`.
- Header N's hash is committed through slot N+1:
  - `StellarValue_{N+1}.txSetHash = SHA-256(XDR(GeneralizedTransactionSet))` [read] (TxSetFrame.cpp line 769), verified 64 of 64.
  - That tx set's first field, `previousLedgerHash`, equals SHA-256(XDR(header N)), verified 63 of 63.
  - The header chain links through `previousLedgerHash` [verified].
- So a proof is: EXTERNALIZE envelopes for slot M, then the tx-set preimage for M, then the headers back to N.
- History archives publish what the proof needs every 64 ledgers [read] (https://github.com/stellar/stellar-core/blob/master/docs/history.md):
  - headers;
  - tx sets;
  - result sets;
  - (optionally) SCP files holding `SCPHistoryEntry {quorumSets, messages}`.
- SDF's archive file `scp-03db89bf` holds 30 EXTERNALIZE envelopes per ledger plus the quorum-set preimage [verified]. Its hash `040355b7…` matches the `quorumSetHash` of SDF 1 [verified].
- Sizes in the sample:

| Item | Size |
|---|---|
| Header | 428 B |
| Tx set | 100–396 KB, average 252 KB |
| Result set | 29–109 KB |

**Quorum structure today [verified, monitors, 2026-10-01].**
- 10 organisations × 3 validators = 30:

| | | |
|---|---|---|
| SDF | Blockdaemon | LOBSTR |
| Franklin Templeton | Public Node | Creit |
| OBSRVR | MoneyGram | Figure |
| Range | | |

- Each Tier 1 node's quorum set is 7 of 10 organisations, each organisation 2 of 3. That means at least 14 signatures. Monitors report a minimum splitting set of 4 organisations and a minimum blocking set of 4 (https://api.stellaratlas.io/v1).
- SatoshiPay is no longer in SDF 1's quorum set. In July 2025 there were 7 organisations with a target of 13 [read] (https://stellar.org/blog/developers/decentralization-double-time). SDF announced MoneyGram, Figure and Range joining [read] (https://stellar.org/press/moneygram-figure-markets-and-range-to-help-secure-the-stellar-network-by-joining-as-tier-1-validators).

**How an outside verifier decides [inference].**
- Pin a quorum set Q, the Tier 1 configuration. Accept a value when a set of signers satisfying Q (at least 7 organisations, each with at least 2 of 3 validators) signs EXTERNALIZE for the same slot and value.
- A verifier built this way has the safety of a watcher node using Q.
  - Forging a value outright needs 7 organisations.
  - A split needs 4 colluding organisations, because two 7-of-10 quorums overlap in 4 organisations.
- Spacewalk's pallet uses this rule: more than 2/3 of organisations, each with more than half of its validators [read] (https://github.com/pendulum-chain/spacewalk/blob/main/pallets/stellar-relay/src/validation.rs).

### 2. Validator set and quorum changes

**How Tier 1 changes.**
- Off-chain. "Existing Tier 1 organizations update their quorum sets to include your validators." It "is not a unilateral decision by SDF." "Never change your quorum set without discussing it with other Tier 1 organizations first." Coordination happens on Discord [read] (https://developers.stellar.org/docs/validators/tier-1-orgs).
- HIGH quality requires at least 3 validators per home domain and a history archive. The automatic thresholds are a simple majority inside an organisation and byzantine (3f+1) across organisations [read] (https://developers.stellar.org/docs/validators/admin-guide/configuring).
- There is **no on-chain validator registry, epoch or system contract**. Neither the ledger header nor `StellarValue` names the validators [read, XDR].

**Following the set from signed data: partially [inference].**
- Every EXTERNALIZE signs the signer's `commitQuorumSetHash`, and the archives carry the quorum-set preimages. A zk verifier could adopt Q′ once a slice of the current Q signs statements committing to hash(Q′). This would be a handoff in the style of a sync committee, but it is my design, not an existing mechanism.
- The hard parts:
  - Changes roll out one node at a time, so signers disagree on the hash mid-transition.
  - Organisation identity (home domain) is not in the signed data, only the inner-set structure.
  - Replacing many keys at once could leave no old slice that ever signs the new hash, which stalls the verifier.
- Spacewalk instead keeps the list behind `ensure_root` governance. Its genesis list (still including Whalestack and SatoshiPay) shows how such a list drifts [read] (https://github.com/pendulum-chain/spacewalk/blob/main/pallets/stellar-relay/src/lib.rs).

### 3. State proofs

**Storage against `bucketListHash`: impractical except for entries written within the last couple of ledgers.**
- The structure [read] (BucketListBase.cpp, BucketManager.cpp `snapshotLedger`, BucketOutputIterator.cpp, https://github.com/stellar/stellar-core/tree/master/src/bucket):
  - `bucketListHash` = SHA-256(liveBL ‖ hotArchiveBL) since protocol 23.
  - Each list = SHA-256 of 11 level hashes.
  - Each level = SHA-256(curr ‖ snap).
  - Each bucket = a flat streaming SHA-256 of the whole bucket file. **There is no Merkle tree.**
- I recomputed the hash from the archive's bucket hashes and it matches header 64,719,295 [verified].
- Compressed bucket sizes now run from level-0 `curr` at 67 KB up to level-10 `curr` at 2.45 GB [verified, HEAD requests]. So an entry's proof means hashing the whole bucket it sits in.
- CAP-0057's Merkle "archival snapshots" cover only archived entries, and that CAP is still Draft (https://github.com/stellar/stellar-protocol/blob/master/core/cap-0057.md).

**Transaction results: workable, and the natural design.**
- `txSetResultHash` = SHA-256(XDR(`TransactionResultSet`)) (LedgerManagerImpl.cpp line 1883) [read], verified 64 of 64.
- A Soroban success result carries `success = sha256(InvokeHostFunctionSuccessPreImage{SCVal returnValue; ContractEvent events<>})` [read] (Stellar-transaction.x, Stellar-ledger.x, InvokeHostFunctionOpFrame.cpp).
  - The events exclude failed calls and diagnostics (`e2e_invoke.rs` line 976).
  - Each event's `contractID` is set by the host from the running contract (`events/mod.rs` `record_contract_event`) [read].
- I recomputed the hash for mainnet tx `36a3f043…` (return value void, 1 event) and it matches the result exactly [verified].
- **Path:** EXTERNALIZE for slot M → tx set M → headers down to N → `txSetResultHash_N` → result pair → success preimage → an event emitted by the vault. A vault `attest()` that emits the requested storage values gives a state proof, exactly like Xindex's Tron design.
- Stellar does include failed transactions in ledgers [read] (https://stellar.org/blog/developers/failed-transaction-mitigation-faq). So the proof must use the result, not mere inclusion in the tx set.

### 4. Existing Stellar → Ethereum/EVM bridges

I found **no trustless Stellar → EVM light client, zk or otherwise.** I searched broadly. That is not proof that none exists.

| Project | What it does | Trust model |
|---|---|---|
| **Spacewalk (Pendulum, Substrate)** | Verifies Tier 1 SCP signatures natively in a pallet. Its relay check proves a tx is in the tx set, not its result (I did not check whether callers compensate) [read, code above]. | Closest to trustless, but not EVM, and the validator list is set by root governance. |
| **Axelar** | Amplifier gateway for Stellar (https://github.com/axelarnetwork/axelar-amplifier-stellar). | Committee: Axelar's verifier set. |
| **Allbridge Core** | Allbridge's own messenger or Wormhole, with Wormhole the default (https://docs-core.allbridge.io/product/how-does-allbridge-core-work/messaging-protocols, https://allbridge.medium.com/wormhole-becomes-default-messaging-for-allbridge-core-c4cab6f3c9fc). | Committee: 19 guardians, or Allbridge itself. |
| **Circle CCTP and LayerZero** | Reported live on Stellar in 2026 (secondary sources: https://www.crossmint.com/announcement/cctp-stellar). | Committees: Circle's attester and LayerZero's DVNs. |

### 5. The chain side for P1 and P2

**Crypto host functions** [read] (https://github.com/stellar/rs-soroban-env/blob/main/soroban-env-common/env.json; https://developers.stellar.org/docs/networks/software-versions):
- **Since the start:** sha256, keccak256, ed25519 verification and secp256k1 recovery.
- **Protocol 21:** secp256r1.
- **Protocol 22:** BLS12-381, CAP-0059 (Dec 5, 2024).
- **Protocol 25:** BN254 `g1_add`, `g1_mul` and `multi_pairing_check`, CAP-0074, plus Poseidon and Poseidon2, CAP-0075 (Jan 22, 2026).
- **Protocol 26:** `bn254_g1_msm`, Fr arithmetic and on-curve checks, CAP-0080 (May 6, 2026).
- Mainnet is now at protocol 29 according to Horizon [verified].
- **So BN254 is native.** No wrapping over BLS12-381 is needed, so I did not research that path further.

**Fit within limits.** On-chain configuration via RPC [verified]:

| Limit | Value |
|---|---|
| Instructions per tx | 400,000,000 |
| Instructions per ledger | 580,000,000 |
| Memory per tx | 40 MiB |
| Tx size | 132,096 B |
| Wasm size | 128 KiB |
| Contract data entry | 64 KiB |
| Events per tx | 16 KiB |
| Max TTL | 3,110,400 ledgers (about 180 days) |

**Groth16 cost estimate [inference].** From the mainnet cost parameters (linear terms are scaled by 128 per `model.rs`; G2 subgroup checks charged per `bn254.rs`), for a 5-public-input Groth16 proof as in SP1 v6 and RISC Zero:
- pairing over 4 pairs: 5.26M + 4 × 3.07M ≈ 17.5M;
- G2 checks: 4 × 1.71M ≈ 6.8M;
- multi-scalar multiplication of 5 points: ≈ 2.8M.

That is **≈ 27–30M instructions, about 7.5% of the per-tx limit.** A third-party crate claims about 15M (https://docs.rs/stellar-zk-risc0/latest/stellar_zk_risc0/). Measure this before relying on either figure.

**Existing verifiers.**
- SDF ships a BN254 Groth16 verifier example (https://github.com/stellar/soroban-examples/tree/main/groth16_verifier).
- Nethermind's RISC Zero verifier exists, but it is **unaudited and has a timelock admin and an emergency stop** (https://github.com/NethermindEth/stellar-risc0-verifier), so Xindex would deploy its own immutable copy.
- I found no SP1 verifier for Soroban.

**Native XLM.** The native asset has a Stellar Asset Contract. A contract's balance is a contract data entry, with no issuer, admin or clawback (https://developers.stellar.org/docs/tokens/stellar-asset-contract).

**Immutable and ownerless: yes, with caveats.**
- Code changes only if the contract itself calls `update_current_contract_wasm` (https://developers.stellar.org/docs/build/guides/conventions/upgrading-contracts). Use a plain Wasm executable, not CAP-0085's externally managed reference.
- Anyone can extend TTL or restore an archived entry (https://developers.stellar.org/docs/learn/fundamentals/contract-development/storage/state-archival), so keepers must keep the instance, the code and the SAC balance entry live.
- **Chain-level powers over the vault:**
  - **CAP-0077 (protocol 26):** a validator vote can freeze any contract-data, account or trustline key. Exempted "bypass" transactions still need normal authorization, so a freeze blocks access but does not take funds. It is already in use: 3 account keys have been frozen since ledger 63,073,409 (2026-06-17) [verified].
  - **CAP-0076:** a precedent of a protocol upgrade amending corrupted archived state.

### 6. Verdict

**Admission rule: passes.** Finality is deterministic: an externalized ledger is irreversible, about 5 s, and the network halts rather than forks. The caveat is that safety rests on quorum intersection, and there is no canonical on-chain validator set.

**Ethereum → Stellar (P1 and P2): yes, today.** Xindex would write:
- a Soroban vault, the twin of the EVM and Solana vaults;
- a Soroban P1 verifier, a Rust port of `EthereumFinalityVerifier` / `solana/programs/ethereum-verifier` using BN254 and keccak;
- an immutable Soroban RISC Zero Groth16 verifier for P2.

The Groth16 check fits easily.

**Stellar → Ethereum state verifier: buildable, but only as a zk proof.** It cannot be checked natively like BNB or Tron. Each proof needs at least 14 ed25519 signatures plus SHA-256 over a 100–400 KB tx-set preimage.
- In plain Solidity, ed25519 costs about 500K gas per signature (https://ethresear.ch/t/verify-ed25519-signatures-cheaply-on-eth-using-zk-snarks/13139).
- Calldata at EIP-7623's floor of 40 gas per non-zero byte costs about 10–16M gas for the tx set alone, against EIP-7825's 16.78M per-tx cap [inference].

What Xindex would need to write:
1. **A prover program** in SP1, which has patched sha2 and curve25519-dalek (https://docs.succinct.xyz/docs/sp1/optimizing-programs/precompiles; RISC Zero also has both: https://dev.risczero.com/api/zkvm/precompiles). It would:
   - verify EXTERNALIZE envelopes against the pinned Q;
   - open slot M's tx set to reach `previousLedgerHash`;
   - walk the headers back to N;
   - open the result set at N;
   - match the success preimage containing the vault's `attest` event. Following Xindex's Tron rule, it should write the expected event's XDR from typed fields rather than parse it.

   Public outputs: the hash of Q, N, the vault ID and the attested values.
2. **A Solidity `StellarStateVerifier`** that checks the Groth16 proof and holds the hash of Q, with a rotation rule.
3. **A vault `attest()`** that emits the values.

**Open risks [inference].**
- Rotating Tier 1, which has changed several times since 2025, has no on-chain anchor.
- XDR changes with protocol upgrades. CAP-0083 added a `StellarValue` arm in protocol 28, CAP-0088 (millisecond close times) is Accepted, and gated arms were added to stellar-xdr in August 2026. The prover can therefore stall, which falls under Xindex's "formats breaking" process.
- SDF plans to change SCP's signature scheme to a post-quantum one, with no timeline (https://stellar.org/blog/foundation-news/introducing-the-quantum-preparedness-plan).

## Hedera (HBAR) as an Xindex vault chain: research report (read-only, as of 2026-10-01)

**Short answer:** You can verify P1 and P2 on Hedera today. You cannot build a trustless Hedera → Ethereum state verifier today, because TSS block signatures are switched off on mainnet. Hedera says they arrive with v0.79 in November 2026, and that date has already slipped once. The finality rule passes. The permissioned council is a trust assumption that the owner has to accept explicitly.

Items marked **[inference]** are my own reasoning or arithmetic, not something I read in a source. Nothing was edited in the repo. The only network calls were reads: GitHub raw files, the docs, and one public mirror-node API query.

### 1. Finality
- **Deterministic: yes.**
  - Hedera says that once a transaction has a consensus timestamp it is final and cannot be reorganized. It calls this "absolute (aBFT)" finality, reached in 3 to 5 seconds (https://docs.hedera.com/evm/overview/evm-on-hedera-explained).
  - Baird's paper says members who assign an event a place in history "are guaranteed to never change it". Liveness only holds "eventually with probability 1", because the protocol uses pseudorandom coin rounds. It assumes more than 2/3 of members are honest (https://www.swirlds.com/downloads/SWIRLDS-TR-2016-01.pdf, Theorem 5.16).
  - So safety is deterministic and termination is probabilistic. The algorithm has a Rocq (Coq) proof (https://arxiv.org/abs/2102.01167).
- **What nodes sign today: RSA, not ed25519.**
  - HIP-1200 says each node signs the hash of every record file with its own RSA key (https://github.com/hiero-ledger/hiero-improvement-proposals/blob/main/HIP/hip-1200.md).
  - The scheme is RSA-3072 SHA384withRSA. In v6 a node signs both the whole-file hash and a metadata hash, which covers the version, both running hashes and the block number. Source: the community parser https://github.com/hiero-hackers/hiero-streams-rs, which is not official.
  - The public keys in address book file 0.0.102 are RSA-3072 in DER form. The live mirror API shows the `0x308201a2…rsaEncryption` prefix (https://mainnet-public.mirrornode.hedera.com/api/v1/network/nodes).
  - The mirror node accepts a file once signatures from 1/3 of the stake agree (`consensusRatio` 0.33333333333) (https://github.com/hiero-ledger/hiero-mirror-node/blob/main/docs/configuration.md).
- **The future: HIP-1056 block streams with hinTS.**
  - HIP-1056 (block streams) and HIP-1200 (hinTS) are both "Approved", not "Final".
  - hinTS is BLS on **BLS12-381** with the standard tag `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_`. Its Fiat-Shamir hash is SHA-256 (https://github.com/hiero-ledger/hiero-cryptography/blob/main/cryptography/hedera-cryptography-hints/src/main/rust/hints.rs).
  - Rotations from one roster to the next are chained by a recursive SNARK called WRAPS, bound to a ledger ID. The ledger ID is the SHA-256 hash of the genesis TSS address book.
  - The signature blob is 3432 bytes: verification key 1096, signature 1632, WRAPS proof 704. Before the first WRAPS proof exists, the network uses a 192-byte aggregate Schnorr signature instead.
  - Every block hash is SHA-384 (HIP-1056 `BlockHashAlgorithm SHA2_384`).
- **Is TSS live? No.**
  - Hedera's post of 2026-06-05 gives the plan: wrapped record blocks (HIP-1427) from July 2026 (v0.75), and the "TSS cutover" in **November 2026 (v0.79)**. The post's URL slug still says September (https://hedera.com/blog/block-streams-replace-the-record-stream-by-default-starting-september-2026-action-required-by-mirror-node-operators/).
  - The v0.77 notes (mainnet 2026-09-29) include "Mainnet and Testnet jumpstart and disable TSS" (#27033). The v0.76.1 notes say "Disable TSS" (https://docs.hedera.com/networks/release-notes/services).
  - A WRAPS issue is milestoned v0.79 (https://github.com/hiero-ledger/hiero-consensus-node/issues/27027).
  - WRAPS needs a trusted-setup ceremony run by council node operators. HIP-1398 ("Active") describes it. I could not confirm that it has been run on mainnet.
- **State proofs.** There is no dedicated state-proof HIP.
  - HIP-1056 defines three proof types: block proof, block contents proof, and state proof. A state proof against the state after block N needs block N+1's `start_of_block_state_root_hash`.
  - HIP-1081 (Approved) specifies a block-node `getStateProof`. The block node's own proto still marks it "StateProofPlaceholder until the Block Stream definition for StateProof is available" (https://github.com/hiero-ledger/hiero-block-node/blob/main/protobuf-sources/src/main/proto/block-node/api/proof_service.proto).
  - The query API answers state-proof queries with NOT_SUPPORTED (release notes).

### 2. Node set
- **Size and admission.**
  - Mainnet nodes are permissioned and run by Hedera Council members (https://docs.hedera.com/operators/consensus-node).
  - The mirror API lists **30 nodes**, from a query I ran on 2026-10-01. Each node's stake is capped at 450M HBAR and stake is recomputed daily.
  - The council has up to 39 members on limited terms. It decides by majority, and its votes include approving software updates (https://hederacouncil.org/faq).
- **How the set changes.** Under HIP-869 (Final), `NodeCreate` needs a council signature plus the node's admin key. Changes take effect at the next maintenance window or upgrade (https://github.com/hiero-ledger/hiero-improvement-proposals/blob/main/HIP/hip-869.md). Before HIP-869, the address book lived only in files 0.0.101 and 0.0.102.
- **Following it trustlessly from Ethereum.**
  - After TSS: yes, by design. The verifier keeps two constants, the ledger ID and the WRAPS verification key, and each proof carries the current roster's hinTS key with a WRAPS proof back to the ledger ID.
  - The design doc says verifiers must "validate out-of-band" that the ledger ID belongs to the network. In practice that means trusting the council roster at TSS adoption (https://github.com/hiero-ledger/hiero-consensus-node/blob/main/hedera-node/docs/exact-weight-tss.md).
  - The signing threshold is stated inconsistently:
    - 1/3 of roster weight in the design doc, in the `fraction` argument of the Rust `verify`, and in CLPR's Solidity verifier;
    - "greater than 1/2" in the HIP-1200 prose;
    - "strictly greater than 2/3" in the HIP-1200 protobuf comment;
    - "more than 1/3" in HIP-1056.
  - Xindex must pick and enforce one threshold. Requiring more than 1/3 is safe under the usual assumption that fewer than 1/3 are faulty **[inference]**.
  - Before TSS: you would have to follow the RSA keys in 0.0.102, the HIP-869 node transactions and the daily stake changes, proven out of record files. It is possible, but heavy.

### 3. State proofs
- **Contract storage.**
  - EVM storage sits in the state tree as `SlotKey{contractID, 32-byte key}` → `SlotValue{value, previous_key, next_key}` (https://github.com/hiero-ledger/hiero-consensus-node/blob/main/hapi/hedera-protobuf-java-api/src/main/proto/services/state/contract/storage_slot.proto).
  - Block streams carry slot writes as `StateChanges` items. That means a block contents proof of "slot S of the vault set to V in block N" is possible, in the same event style as the Tron `attest` approach **[inference]**.
  - The block root is a fixed 16-slot SHA-384 tree. Its leaves include:
    - the previous block hash;
    - an incremental tree of all earlier block hashes, so one signed block can prove any historical block;
    - the state root at the start of the block;
    - the input, output, state-change and trace subtrees.

    Source: https://github.com/hiero-ledger/hiero-consensus-node/blob/main/hapi/hedera-protobuf-java-api/src/main/proto/block/stream/block_proof.proto.
  - This layout was "reworked" as recently as v0.77, so the format is still moving.
- **`eth_getProof`: no.** The relay's OpenRPC spec says "Always returns UNSUPPORTED_METHOD" (https://github.com/hiero-ledger/hiero-json-rpc-relay/blob/main/docs/openrpc.json). `stateRoot` is the empty-trie root (https://docs.hedera.com/evm/differences/json-rpc-differences).
- **Block proof contents:** the block number, then one of:
  - `TssSignedBlockProof` (the 3432- or 2920-byte blob);
  - a sibling-path `StateProof` that chains up to a later signed block;
  - `SignedRecordFileProof` (RSA signatures), for wrapped historical record files.

### 4. Existing Hedera → Ethereum bridges
- **Hashport:** nine named validators sign by supermajority multisig, so it is a committee and not trustless (https://hashport-network.medium.com/meet-the-hashport-validators-bed011655c75).
- **Chainlink CCIP:** runs on Chainlink's oracle networks (https://docs.hedera.com/evm/integrations/cross-chain/chainlink-ccip). Also a committee.
- **LayerZero:** relies on its DVN verifiers (https://docs.hedera.com/evm/integrations/cross-chain/layerzero). Also a committee.
- **CLPR (Hashgraph) is the closest thing to trustless.**
  - It entered closed beta on 2026-05-04 and only links Hedera to HashSphere networks. Ethereum is "planned", initially through "a subset of nodes acting as CLPR endpoints" (https://hashgraph.com/blog/clpr-a-new-bridgeless-standard-for-cross-ledger-communication/).
  - It became a Linux Foundation Decentralized Trust lab on 2026-09-24.
  - Consensus-node PR #27029 (merged 2026-09-22) ships it with `clpr.enabled=false`.
  - Its repo (https://github.com/LFDT-CLPR/clpr-smart-contracts, Apache-2.0, audit status unknown) has an **EVM verifier for Hedera proofs**: `HieroVerifier`, `TSSVerifier` and `WRAPSVerifier`, plus `Sha384.sol`.
    - `TSSVerifier` checks hinTS on EIP-2537.
    - `WRAPSVerifier` checks the current 704-byte "Nova IVC + Groth16 decider" proof with an 8-pairing BN254 check and Poseidon.
    - `HieroVerifier` checks SHA-384 state proofs.
  - Caveat: hiero-cryptography PR #692, merged 2026-09-28, switches WRAPS to Microsoft Nova compressed by MicroSpartan, Mercury (BN254) and IPA (Grumpkin). The consensus node still pins hedera-cryptography 3.15.0 (released 2026-07-31), so the change is not deployed yet. If it is adopted, CLPR's WRAPS verifier breaks, and Grumpkin IPA has no EVM precompile.
  - Separately, `hiero-block-verifier-js` is an independent JavaScript verifier of block proofs (HIP-1056/HIP-1200), community-run and not official (https://github.com/hiero-hackers/hiero-block-verifier-js).
- I found no live zero-knowledge light client of Hedera on Ethereum.

### 5. The chain side: P1, P2 and the vault
- **BN254 precompiles: yes.**
  - 0x06–0x08 are present, along with 0x01–0x05, 0x09 and EIP-2537 at 0x0b–0x11. KZG point evaluation (0x0a) is absent (https://docs.hedera.com/evm/development/deploying).
  - The registry is Besu's `populateForPrague`, and the gas calculator extends `PragueGasCalculator` (https://github.com/hiero-ledger/hiero-consensus-node/blob/main/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/v070/V070Module.java).
  - So the costs should be EIP-1108's: a 4-pair pairing is 45,000 + 4×34,000 = 181k gas **[inference]**.
- **EVM version and limits.**
  - The EVM is Prague, with EIP-7702 switched off. The "Support for Ethereum Pectra Release" entry is in the v0.77 notes. TLOAD, TSTORE and MCOPY arrived in v0.50, PUSH0 in v0.38.
  - `block.chainid` is 295 and `block.timestamp` is the consensus timestamp.
  - A transaction is capped at 15M gas (https://docs.hedera.com/evm/development/gas-fees; default `maxGasPerTransaction` in `ContractsConfig.java`).
  - Contract size follows EIP-170 (24 KB).
  - Ordinary HAPI transactions are capped at 6 KB. Jumbo EthereumTransactions allow about 24 KB on creation and about 128 KB on calls (HIP-1086).
  - So a ~24 KB vault's initcode exceeds the jumbo creation cap. Deploy it through the file service with `ContractCreate`, or with CREATE2 from a factory **[inference]**.
- **Decimals.**
  - Inside the EVM, `msg.value`, `call{value}` and `.balance` are in tinybars (8 decimals).
  - Only the JSON-RPC relay presents 18-decimal weibars: 1 tinybar = 10^10 weibar (https://docs.hedera.com/evm/differences/hbar-decimals).
  - Ethereum-side message amounts must therefore be in tinybars.
- **`call{value}` to a missing address.**
  - It lazily creates a hollow account and charges gas for the creation. If the gas runs short, the call halts and consumes it all.
  - Long-zero addresses get `INVALID_ALIAS_KEY`. A recipient with `receiverSigRequired` makes the transfer fail with `MISSING_RECEIVER_SIGNATURE`.
  - Sources: `CustomMessageCallProcessor.java` and `DispatchingEvmFrameState.java` in hiero-consensus-node.
  - Payouts must never block, which the existing "failing never blocks a refund" rule already covers.
  - HBAR sent by a native `CryptoTransfer` does not trigger `receive()` (https://docs.hedera.com/evm/differences/native-token-transfers). Treat it like ether forced in by `selfdestruct`.
- **Immutability.**
  - A contract created without an admin key "SHALL be immutable, except for expiration and renewal" (https://github.com/hiero-ledger/hiero-consensus-node/blob/main/hapi/hedera-protobuf-java-api/src/main/proto/services/contract_create.proto).
  - Rent is "not yet enabled" but intended (https://docs.hedera.com/evm/development/rent). Once on, renewal falls back to charging the contract itself, which would drain the vault's HBAR away from its exact book. Fund a separate auto-renew account or keep extending the expiry **[inference]**.
  - The governance FAQ says the council can delete hosted smart contracts that hold illegal content (https://docs.hedera.com/support/faq/governance). The current `SystemDelete` proto marks `contractID` as unsupported. The two sources conflict.

### 6. Verdict
- **A trustless Hedera → Ethereum state verifier today: no.**
  - TSS is disabled on mainnet. What remains is per-node RSA-3072 with SHA-384. Building on it would mean following the RSA address book, the HIP-869 node transactions and the daily stakes, and verifying more than 1/3 of stake in RSA signatures through MODEXP (73,728 gas each under EIP-7883 **[inference]**).
  - It would also need SHA-384 written in Solidity, plus parsing record files. Record streams stop in November 2026, so this would be wasted work.
  - After the cutover, Xindex would need to write:
    1. a hinTS verifier on EIP-2537 (CLPR's is a reference);
    2. a WRAPS verifier, which depends on the version and needs a rewrite or a zkVM wrapper if Nova WRAPS ships;
    3. SHA-384 Merkle proofs into the 16-slot block tree, plus the historical block-hash tree;
    4. writer-style encoders for the vault's `StateChanges` slot item, in the same "written, never parsed" style as the Tron verifier.

    A rough Ethereum cost is 1–3M gas per proof **[inference, not measured]**.
  - Another route skips WRAPS: follow each hinTS key handoff through block contents proofs, the way the BNB and Tron verifiers follow theirs **[inference]**.
  - Expected timing: no earlier than v0.79 in November 2026, with the WRAPS format still moving.
- **Verifying P1 and P2 on Hedera: yes.** BN254 Groth16 verification costs about 0.2–0.3M gas against a 15M cap. Mind the deployment path and the tinybar units.
- **Admission.**
  - Deterministic finality: yes.
  - The council is the consensus. It runs 30 permissioned nodes, approves every node admission and software upgrade, would switch on rent, and claims power to delete contracts.
  - "Trustless relative to the chain's own consensus" therefore reduces to trusting about 30 known council organisations, and since TSS-signed proofs need only more than 1/3 of stake, roughly 11 of them colluding would be enough to break the bridge.
  - This is the owner's call. I recommend recording it as an explicit trust assumption rather than a pass.

## Cardano (ADA) as an Xindex vault chain: research report

This was read-only research. I edited nothing in the repo. On 2026-10-01 I made some live reads: the Mithril mainnet aggregator API, the Koios API, and the GitHub API. Claims marked **[inference]** are my own reasoning or arithmetic, not something a source states.

### 1. Finality

**Praos is probabilistic.**
- CIP-0140 says: "Under Ouroboros Praos, settlement occurs probabilistically on the Cardano blockchain…" (https://github.com/cardano-foundation/CIPs/blob/master/CIP-0140/README.md).
- The consensus glossary gives the Common Prefix bound, `a*exp(-k*b+c)`, for an adversary with less than half the stake. Because of it, "no honest Praos node will ever need to discard more than k blocks". The k-deep rule is therefore a node's local rule resting on that theorem. It is not a certificate anyone can check (https://ouroboros-consensus.cardano.intersectmbo.org/docs/references/glossary/).

**k = 2160.** Mainnet genesis sets `securityParam` 2160, `activeSlotsCoeff` 0.05 and `epochLength` 432000 (https://raw.githubusercontent.com/IntersectMBO/cardano-node/master/configuration/cardano/mainnet-shelley-genesis.json). CPS-0017 says k is "approximately 12 hours" (https://cips.cardano.org/cps/CPS-0017). The "5 days" figure seen in some articles is the epoch length, not k.

**Peras: CIP-0140, status Proposed, created 2024-08-15.**
- Parameters: rounds of 90 slots, a committee of 900 seats, a quorum of 675 (3/4), and a boost of 15 blocks (CIP-0140).
- Schedule: Intersect plans Leios as Dijkstra phase 1 (target Q4 2026). Peras is phase 2, an intra-era hard fork targeting Q2 2027. Intersect says "All targets are estimates only and not guarantees" (https://product.cardano.intersectmbo.org/hardfork-planning/dijkstra/). Peras is not on mainnet.

**Peras's signature scheme is not settled.**
- CIP-0140 signs votes with "standard KES signatures (Ed25519)", 710 bytes each. It defers the certificate format to the "Votes & Certificates on Cardano" CIP (PR #870, ALBA-based). That PR was closed unfinished on 2026-05-08 (https://github.com/cardano-foundation/CIPs/pull/870).
- The Peras design document of 2026-01-27 uses a BLS multisignature scheme "for concreteness", with these figures: certificates of 7 to 10 kB, verification in 115 to 157 ms, and a committee of 500 to 1000 seats. It notes BLS is not forward-secure, names Pixel as an alternative, and says votes "are likely going to use key-evolving signatures underneath". Pools will have to register new keys (https://tweag.github.io/cardano-peras/peras-design.pdf).
- The Jan-2025 analysis is concrete:
  - curve: BLS12-381;
  - keys: in G2 (96 B), signatures in G1 (48 B);
  - seats: Fait Accompli;
  - eligibility: a non-persistent voter proves it with a BLS signature.
  
  (https://github.com/input-output-hk/peras-design/blob/main/analytics/certificates-jan2025.md)
- The scheme is not Mithril's. The design document says it is "different from Mithril's certificates", with an effort under way to unify them.
- Leios (CIP-0164, Proposed) has pools register a BLS12-381 key with proof of possession in their pool registration. Its certificates are a bitfield plus one aggregated BLS signature, from a committee of the top pools by active stake (https://github.com/cardano-foundation/CIPs/blob/master/CIP-0164/README.md).

**Peras is still not deterministic.** CIP-0140:
- "Fast settlement occurs in the presence of adversaries with up to one-quarter of the stake, but Praos-like safety is maintained when adversaries control more"
- "Until a boost appears, blocks are at risk in Peras just as they are in Praos"
- Blocks only rarely carry a certificate; certificates spread off-chain.

**[inference] A light client could check a certificate's signatures, but not on its own.** The committee comes each epoch from the stake distribution and registered keys, which are ledger state, not header data. I found no mechanism in CIP-0140, CIP-0164 or the design document by which a certificate commits to the next committee. A light client would still need a trusted feed of each epoch's committee.

### 2. Signed data a light client could check

**Headers.** A header is `[header_body, body_signature : kes_signature]`, with the KES signature 448 bytes. The body holds:
- `issuer_vkey`, `vrf_vkey`;
- `vrf_result = [bytes, bytes .size 80]`;
- `block_body_hash`;
- `operational_cert` (a hot KES key signed by the cold Ed25519 key).

(https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/conway/impl/cddl/data/conway.cddl)

The cryptography is all Ed25519 or curve25519, which Ethereum has no precompile for:
- KES is `Sum6KES Ed25519DSIGN Blake2b_256` and the VRF is `PraosVRF` (https://github.com/IntersectMBO/cardano-ledger/blob/master/libs/cardano-protocol/src/Cardano/Protocol/Crypto.hs).
- PraosVRF is libsodium's ECVRF in the IETF draft-03 construction (https://github.com/IntersectMBO/cardano-base/blob/master/cardano-crypto-praos/src/Cardano/Crypto/VRF/Praos.hs).

**[inference]** Checking leader eligibility also needs each pool's stake from the ledger snapshot, which no header carries.

**The block body hash.** It is Blake2b-256 over four part-hashes: bodies, witnesses, auxiliary data, and the phase-2 validity flags (https://github.com/IntersectMBO/cardano-ledger/blob/master/eras/alonzo/impl/src/Cardano/Ledger/Alonzo/BlockBody/Internal.hs). There is no Merkle tree per transaction, so proving a transaction from a header takes the whole bodies segment. The block body maximum is 90,112 B.

**Mithril is a stake-based threshold multisignature on BLS12-381** (blst). The network uses the "concatenation" proof system; the SNARK systems are experimental (https://github.com/IntersectMBO/mithril/blob/main/mithril-stm/README.md).

What I read live on mainnet:
- Signed types: MithrilStakeDistribution, CardanoStakeDistribution, CardanoDatabase and CardanoTransactions; the aggregate signature type is Concatenation (https://aggregator.release-mainnet.api.mithril.network/aggregator).
- Parameters: k=1944, m=16948, phi_f=0.2, with 243 registered signers. Transactions are certified at tip−100 blocks, every 30 blocks (`/aggregator/epoch-settings`).
- Network status: "Stable (signer) / Beta (aggregator/client)" (https://mithril.network/doc/manual/getting-started/network-configurations).
- The CardanoTransactions type is "superseded by" a planned "Cardano blocks and transactions" type (https://mithril.network/doc/mithril/advanced/mithril-certification/).
- The node database type certifies immutable files only: "the ledger state… cannot be signed" (https://mithril.network/doc/mithril/advanced/mithril-certification/cardano-node-database).

**Who stands behind a certificate.**
- Registered stake is 4.19B ADA, from the certificate's AVK `total_stake`. Active stake at epoch 658 is 21.32B ADA (https://api.koios.rest/api/v1/epoch_info?_epoch_no=658). So about 20% of stake participates.
- **[inference, computed from the live distribution]** A quorum needs about 51.5% of the lottery wins expected at full participation, roughly half the registered stake. That is about 10% of active stake. Any SPO may register.

**How a verifier follows the signer set.**
- Each certificate's AVK must appear as the "next AVK" in an earlier sealed certificate, with at least one certificate per epoch, back to a genesis certificate (https://mithril.network/doc/mithril/advanced/mithril-protocol/certificates).
- The genesis key is Ed25519, plus a Schnorr/Jubjub half for the Lagrange era. The operator signs "a signed genesis certificate for the era", and a separate era-marker key switches eras (https://github.com/IntersectMBO/mithril/blob/main/mithril-stm/SNARK.md).
- Mainnet switched to the Pythagoras era at epoch 539 (https://mithril.network/doc/dev-blog/2024/12/17/era-switch-pythagoras).
- The docs I read do not name who holds the genesis key.

**Can Ethereum verify a certificate with EIP-2537? Yes.** The work, from the code:
- each winning index needs a Blake2b-512 lottery hash compared against `1-(1-phi_f)^w` (https://github.com/IntersectMBO/mithril/blob/main/mithril-stm/src/proof_system/concatenation/eligibility.rs);
- each signer's membership is checked by a batched Merkle proof;
- the BLS check aggregates keys and signatures with random scalars, then pairs once (https://github.com/IntersectMBO/mithril/blob/main/mithril-stm/src/signature_scheme/bls_multi_signature/signature.rs).

The live certificate I sampled has 52 signatures covering 1,956 indices and 54 batch-proof nodes. Cost estimate:

| Part | Gas | Basis |
|---|---|---|
| G2 MSM over 52 keys | 702k | EIP-2537 formula |
| G1 MSM over 52 signatures | 369k | EIP-2537 formula |
| Pairing check, 2 pairs | 102,900 | EIP-2537 formula |
| Hash to G1 | about 15k | estimate |
| About 1,950 Blake2b-512 lottery hashes via EIP-152 | 2–4M | estimate |
| Per-signer thresholds | 1–2.6M | estimate |
| Merkle batch | 0.1–0.4M | estimate |
| Calldata, about 35 KB | about 0.6M | estimate |
| **Total per certificate** | **5–8M** | estimate, under the 2^24 cap |

EIP-2537: https://eips.ethereum.org/EIPS/eip-2537. EIP-152: https://eips.ethereum.org/EIPS/eip-152.

Following the chain costs at least one certificate per 5-day epoch.

### 3. Facts about the vault

**What can be proven today: a transaction's inclusion.**
- The CardanoTransactions root is a Merkle forest of 15-block ranges whose leaves are transaction hashes, hashed with BLAKE2s-256, signed at a fixed 100-block offset (https://mithril.network/doc/mithril/advanced/mithril-certification/cardano-transactions).
- A verifier then takes the transaction body, checks its Blake2b-256 against the hash (EIP-152), and parses the CBOR outputs: address, value, inline datum.
- **[inference]** Ethereum has no BLAKE2s precompile, so about 30 compressions run in plain Solidity.

**Gap 1: inclusion is not success. [inference from code]** Mithril's scanner hashes every transaction from `multi_era_block.txs()` without checking `is_valid` (https://github.com/IntersectMBO/mithril/blob/main/internal/cardano-node/mithril-cardano-node-chain/src/entities/scanned_block.rs). Pallas returns every body, including phase-2-failed ones (https://github.com/txpipe/pallas/blob/main/pallas-traverse/src/support.rs).
- An attacker forfeits only collateral to get a failed transaction, with a fake vault output or datum, into the certified set.
- Under Xindex's "any different proof of the intake voids the order and freezes the chain", that is a cheap freeze, or a forged deposit if the proof is accepted.

**Gap 2: creation is not unspentness.** Neither headers nor Mithril commit to the UTxO set. `IVaultStateVerifier.verifySlots`, which returns storage values at a final block with absent slots as zero, has no eUTxO equivalent. **[inference]**

**Gap 3: the point is not final.** It is tip−100 blocks, and time resolves only to a block range.

**[inference] Workaround.** Make intake state threads that the validator closes after the deadline, and prove block-level validity flags. That needs block-hash certification: either the planned Mithril "blocks and transactions" type, whose documentation page currently returns 404, or Peras-certified blocks.

### 4. Existing Cardano → Ethereum light clients and bridges

I found no production trustless one.
- Mithril's issue for certifying block headers, motivated by Partner Chains' Minotaur bridge, was closed as not planned (https://github.com/IntersectMBO/mithril/issues/2242).
- The zkFold × Anastasia Labs Mithril ZK bridge targeted Cardano-like chains, completed 2 of 6 milestones, and is marked "Did not finish" (https://projectcatalyst.io/funds/12/cardano-use-cases-product/zkfold-x-anastasia-labs-zk-bridge-using-mithril).
- Mithril's own SNARK, recursive Halo2-KZG over BLS12-381, is experimental and research-stage (SNARK.md; https://github.com/input-output-hk/mithril-circuits). I found no EVM verifier for it.

Committee-based bridges, not trustless:
- Wanchain: Storeman MPC, where "over two-thirds of the nodes" sign (https://docs.wanchain.org/crosschain/universal-multichain-bridges).
- Milkomeda: validators on an IBFT 2.0 sidechain vote to release funds (https://milkomeda.com/docs/Milkomeda-audit-by-ArbitraryExecution.pdf).

### 5. Chain side for P1 and P2

**No BN254 on Cardano.**
- CIP-0381 (Active) adds BLS12-381 only. It rejects BN254 because its security "was reduced to 100 bits" (https://cips.cardano.org/cip/CIP-0381).
- A GitHub search of the CIPs repo for "BN254" returned nothing on 2026-10-01.
- MSM over BLS12-381 (CIP-0133) went live with the PV11 "van Rossem" hard fork on 2026-07-18. That date comes from a secondary source (https://cryptoadventure.com/cardano-activates-van-rossem-hard-fork-with-cheaper-plutus-operations/); Koios shows mainnet at PV 11.0.

**Neither zkVM can output a BLS12-381 proof.**
- SP1 wraps with gnark Groth16 or PLONK "over the BN254 curve" (https://docs.succinct.xyz/docs/sp1/security/security-model).
- RISC Zero uses Groth16 over BN254 (https://dev.risczero.com/api/security-model).
- The only route is IOG's plutus-groth16-wrapper (https://github.com/input-output-hk/plutus-groth16-wrapper):
  - it re-proves the BN254 Groth16 inside a gnark Groth16 or PLONK proof over BLS12-381;
  - it supports both SP1 and RISC Zero;
  - it is for "research and educational purposes only", unaudited, and its setup command is `unsafe-setup`.
- **[inference]** Both P1 and P2 would pass through this one wrapper (same gnark code, same setup), which weakens their independence.

**BN254 by other means is not realistic. [inference]** From the cost model, one Fp multiplication costs about 0.4M CPU. A 4-pair pairing check takes tens of thousands of them, which reaches or exceeds the whole 10B per-transaction budget. It would have to be split across several transactions, and I found no implementation.

**A BLS12-381 Groth16 fits.** The cost-model inputs (https://github.com/IntersectMBO/plutus/blob/master/plutus-core/cost-model/data/builtinCostModelC.json):
- 4 Miller loops at 254M each;
- `finalVerify` at 334M;
- point decompression and MSM.

That gives about 2.0–2.5B CPU, consistent with CIP-0381's "approximately 23%". Mainnet limits are 10B steps and 16.5M memory per transaction, 20B steps per block, and 16,384 B per transaction (https://api.koios.rest/api/v1/cli_protocol_params). **[inference]** Two proofs per message take about half a transaction's budget.

**Vault model.** The vault would be a script address with its state in an inline datum, plus a state-thread NFT against double satisfaction (https://developers.cardano.org/docs/developers/curriculum/smart-contracts/security/). Plutus V3 makes the datum optional (https://cips.cardano.org/cip/CIP-0069). **[inference]** Complications:
1. Paying to a script address runs no validator, so a deposit must go through a step the validator checks.
2. Each UTxO is spent once, so per-index state serializes every operation.
3. The 4%-a-day limit needs a counter in the datum, and the only clock is the transaction's validity bounds.
4. The validator sees only its own transaction's inputs, so balances have to be tracked in the datum or consolidated.
5. There are min-ADA, transaction size and budget limits, plus the question of the vault address's staking credential.

### 6. Verdict

**A trustless Cardano → Ethereum verifier today: not to Xindex's standard.** Ethereum can verify Mithril certificates (EIP-2537 plus EIP-152, an estimated 5–8M gas). But the verifier would inherit:
- operator-held genesis and era keys;
- an honest majority of about 20% of stake that opted in;
- a tip−100 point instead of finality;
- inclusion only, failed transactions included, and nothing about unspentness.

To build it anyway, Xindex would write:
1. A Mithril STM concatenation verifier: the lottery, Merkle membership, randomized BLS aggregation, epoch AVK and parameter roll-over, and era handling.
2. A Solidity BLAKE2s forest-proof library.
3. A Cardano CBOR transaction parser. This breaks the "written, never parsed" rule, since a transaction id hashes builder-chosen bytes.
4. A verifier interface for eUTxO in place of `verifySlots`.
5. A validity-flag proof, which waits on block-level certification.

**P1 and P2 on Cardano: yes in principle.** It works through BLS12-381 wrapping at about 23% of a transaction's budget per proof. It needs a production wrapper with a real ceremony and an audit, and it couples P1 and P2.

**The admission rule.** Cardano fails it now. Peras (Proposed, target Q2 2027) brings certified fast settlement, but by its own CIP that settlement is still probabilistic, with a fallback to Praos once an adversary holds more than a quarter of the stake. Cardano would pass only if the owner restates the rule, for example to accept a stake-quorum certificate under a stated stake bound.
