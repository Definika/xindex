# Solana and HyperEVM without waiting: research of 5 October 2026

The owner asked for a way to hold native SOL and HYPE on mainnet, where both are blocked (the Stage B spec, section 8).
Two read-only research passes read primary sources and queried public endpoints; nothing was deployed or sent. Facts
checked again by hand are marked so; the researchers' reasoning is marked as inference.

## Verdict

- **Solana: buildable now, on Tower BFT, without Alpenglow.** Ethereum can verify Solana's present consensus through
  an SP1 proof of the validators' own signed votes, and the account proof of `design/2026-10-03-solana-state-proof.md`
  already works on mainnet. About three weeks, four to five with a built-in switch to Alpenglow, plus an own mainnet
  node and an outside review. It reverses the owner's call of 4 October to wait for Alpenglow.
- **HyperEVM: still blocked, but the blocker has moved.** HyperEVM's receipts root is a real Ethereum receipt trie, so a
  TRON-style `attest` proof would work, if anything quorum-signed committed to an EVM block. Since about 2 October the
  validators sign a state digest every 12 minutes, but it is undocumented and, by reverse engineering, commits to EVM
  state only as a lattice hash. Nothing rule-compliant is buildable until Hyperliquid documents or extends it.

## Solana on Tower BFT

**What validators sign.** A vote is an ordinary transaction, ed25519-signed, whose `TowerSync` instruction carries the
voted slots, the bank hash of the last one, and the voter's root. The vote program refuses a vote whose hash differs
from the slot's (`SlotHashMismatch`). So a signed vote commits to a bank hash and to a root.
https://github.com/anza-xyz/solana-sdk/blob/master/vote-interface/src/state/vote_instruction_data.rs,
https://github.com/anza-xyz/agave/blob/v4.3.0/programs/vote/src/vote_state/mod.rs

**The rule.** Agave's "finalized" is the highest slot that more than two thirds of stake has rooted. Prove that, never
optimistic confirmation, so that no state the cluster could still abandon ever counts as evidence. Forging it takes more
than two thirds of stake: **80 of 671 voting validators, checked on 5 October**, against Alpenglow's 60% (61
validators). Nothing is slashed: SIMD-0212 (slashing) was closed unmerged. That is TRON's kind of trust, which the
owner accepted. Whether a supermajority root passes "deterministic finality" is the owner's reading, as for TRON.

**The account proof is already live.** The bank hash folds in the accounts lattice hash, which activated on mainnet at
slot 347,328,000; the old delta hash was removed at slot 348,624,000 (**both checked on 5 October**). So
`proofs/solana-state`'s `lthash.rs` and `bank.rs` apply to mainnet today: a vault's `attest` writes its account, and
the slot's lattice-hash delta proves it.

**The stake set.** `sol_get_epoch_stake` is active on mainnet; a small registry program records each epoch's stakes and
voter keys during the epoch before, complete against the total, and each registry is proven under the set before it,
from an anchor, as the BNB verifier's sets are (inference, from Agave's source). About 25 to 35 record transactions an
epoch.

**Cost and inputs.**
- About 80 to 120 ed25519 vote signatures a proof, roughly 10M to 15M SP1 cycles; the lattice-hash delta dominates,
  about 0.5B cycles for a slot's 2,850 written accounts (inference, unmeasured). About 260k to 300k gas on Ethereum.
- Votes and bank hashes come from public RPC. The parent's lattice hash and a slot's full write set come from no RPC: an
  own Agave mainnet node, about $1,000 to $1,500 a month (unverified).

**Prior art.** Twine's `solana-r0-prover` proves this same statement in RISC Zero, but takes its stake set from a
database, needs a patched validator, and may not be reused ("written permission" licence). It shows the approach
works. Every other Solana light client found is archived, built on removed formats, or a single key (Polymer).

**The switch to Alpenglow.** SIMD-0384 ends Tower at a genesis block 5,000 slots after activation; Tower roots before
it stay valid. A statement with both modes avoids a gap; a rotation instead would pause SOL mints for up to the 30-day
`ROTATION_DELAY` (inference, from the SIMD).

**Alpenglow's date.** Not scheduled on mainnet. Firedancer clients, 15.5% of stake, do not support it, and activation
needs 95%. The researcher expects it no earlier than late in the fourth quarter of 2026 (inference).

**Rejected.** Wormhole's bridged SOL on Ethereum (13 of 19 guardians, upgradeable by them), and every committee.

**Decisions for the owner.** Reverse the call of 4 October; accept Tower's finalized rule, labelled as TRON's trust is;
fund a mainnet node; build the switch to Alpenglow in, or accept a pause at the switch.

## HyperEVM

**Checked on mainnet.** Every header's `stateRoot` is zero and `eth_getProof` does not exist. But the block hash is the
keccak of the RLP header, and the receipts root matches a receipt trie recomputed from the block's receipts. A deposit
must be an ordinary EVM call to be provable, since HyperCore's transfers to the EVM are not in the receipts.

**What validators sign.**
- `voteAbciDigest` and `voteL1Hash`, every 10,000 L1 heights (about 12 minutes), signed with secp256k1, public in the
  explorer since about 2 October 2026. Undocumented: the researcher could not reproduce the signed message, and
  reverse engineering says EVM state enters it only as lattice hashes, without inclusion proofs.
- The Arbitrum bridge (`Bridge2`): 4 equal hot signers, 3 needed, carrying only USDC withdrawals. Hyperliquid calls it
  legacy. Not the stake-weighted set; a dead end.

**Trust.** 27 active validators. The Foundation's five hold 47.56% of stake; with three more entities the set passes two
thirds. No automatic slashing; no published consensus specification.

**HYPE on Ethereum.** None found: Wormhole's HYPE is on Base, Unichain and Solana; cbHYPE on Base; Kraken's on Ink.

**What Hyperliquid would need to ship** (any of the first two makes a TRON-style verifier buildable on the EVM vault):
1. the EVM block hash or receipts root inside the voted digest, or a real state root with `eth_getProof`;
2. the digest's signed message and composition documented;
3. a signed validator-set handoff per epoch, or a light-client specification.

**Decisions for the owner.** Ask Hyperliquid for those, and keep HYPE out meanwhile (its weight, about 0.85%, is lost to
tracking). A committee for deposits only would break the "no trusted committee" rule; rejected by default.
