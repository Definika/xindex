# Logic review of the unreviewed Stage B surface (2026-10-02)

Four reviewers each read one part of `main` at `4043fb9` that no earlier review had covered, or that had changed since
its review, without changing it:
- P1 on Solana (`solana/programs/ethereum-verifier`) and how the Solana vault calls it, against its EVM twin;
- the EVM finality verifiers (`FinalityVerifier`, `EthereumFinalityVerifier`, `RiscZeroFinalityVerifier`), the state
  reader, and the vault's checkpoint, recovery and snapshot exit (`XindexVault`, `VaultSnapshot`);
- every change to the hybrid hub, module, extension, storage and factory since the Stage B red team's `c2f919c`;
- the finality statement both zkVMs prove (`proofs/finality`), the P1 and P2 guests, and the one-epoch argument.

Each finding below has a concrete failure scenario. None lets anyone take coins: the worst is a message made
permanently undeliverable on one chain. Their tests are in `audit/poc/2026-10-02/`. **Status: all open, none fixed.**

| Id | Severity | Status | Where |
|---|---|---|---|
| LG-1 | High | open | `solana/programs/ethereum-verifier` (`rlp.rs`, `event.rs`, `mpt.rs`) |
| LG-2 | Medium | open | `XindexVault.advanceCheckpoint`, `vetoSuccessor` |
| LG-3 | Low | open | `XindexVault.deliver` (`lastMessage`) |
| LG-4 | Low | open | `FinalityVerifier.update` |
| LG-5 | Low | open | `HybridHubModule.voidOrder`, `slashRebalance`; `HybridHubExtension.reportOutflow`, `reportForgedDeposit` |
| LG-6 | Low | open | `proofs/finality/src/statement.rs`, `registry.rs` |
| LG-I1 to LG-I4 | Info | open | documentation and an optional hardening |

## LG-1 (High, confirmed): a message the EVM twin accepts can be made undeliverable on Solana, by anyone

P1 on Solana collects every item of an RLP list into a `Vec` (`rlp.rs` `Item::items`, called on a receipt's whole
logs list in `event.rs` and on every trie node in `mpt.rs`) under the default bump allocator, which is fixed at 32 KiB
and never frees. A receipt of more than 512 logs exhausts it ("memory allocation failed"), whatever heap frame the
transaction requests. `event.rs` also stores a trie node's length as a `u16`, so a receipt leaf over 65,535 bytes
cannot be encoded. `EthereumFinalityVerifier` accepts both.

Whoever sends an Ethereum transaction shapes its receipt. Several message-emitting calls are permissionless
(`HybridHubModule.failIntake`, `HybridHub.failOrder` after its grace, `claimOrder`, `settleRebalance`,
`HybridIndexFactory.executeVaultProposal`), and nothing on Ethereum emits a message again. So for about 216,000 gas (512
empty logs) an attacker can make an `INTAKE_FAILED` undeliverable, and the depositors' SOL can never be refunded; an
`INTAKE_SETTLED` undeliverable, so the index's last burners stay owed; or a `VERIFIER_ROTATION` undeliverable, again at
each 30-day attempt.

Evidence: `solana_receipt_size.rs` (LiteSVM: 511 padding logs verify, 512 and more panic; a 70,503-byte leaf cannot be
encoded) and `EvmTwinReceiptSize.t.sol` (the unmodified EVM verifier accepts 513 logs and a 70,406-byte leaf).

To check when fixing: TRON caps a transaction's size and its CPU time (80 ms), so a large enough receipt may be
undeliverable there too; BNB Chain is unlikely to be affected.

Fix: walk RLP lists lazily in the Solana verifier, as `RlpReader.at` does, and widen the node length to `u32`. Since any
verifier has some size ceiling, also let anyone emit a recorded message again from Ethereum in a clean transaction (the
vault's used mark makes a second delivery harmless); the module has 426 bytes to spare, so that code goes in the
extension. Regression tests: a 513-log receipt and a leaf over 64 KB, on both verifiers.

## LG-2 (Medium, confirmed): a stale checkpoint lapses the successor and resets the vetoes while the vault stays stalled

`advanceCheckpoint` lapses a proposed successor on any accepted checkpoint, and `vetoSuccessor` keys its count to the
checkpoint's block. `_checkNewer` asks only for a newer block, not a recent one. After a stall begins, the old pair can
still prove blocks up to where it broke, so anyone can advance the vault one stale block at a time, each time lapsing
the successor while `stalled()` stays true. Recovery is then denied until the snapshot exit, and the freezer can veto
more than `MAX_RECOVERY_VETOES` times in one stall, breaking the documented 37 to 97 days.

Evidence: `VaultRecoveryPoC.t.sol` (`test_poc_staleAdvanceLapsesTheSuccessorWhileStillStalled`,
`test_poc_staleAdvanceResetsTheVetoCount`, `test_poc_recoveryDeniedUntilTheSnapshot`: six proposals lapsed).

Fix: lapse the successor and reset the vetoes only when the new checkpoint ends the stall; key the vetoes to the stall,
reset them in `adoptSuccessor`, and drop `_vetoStall`. Stale advances must stay allowed: during a stall they deliver
burns sent just before the break (VLT-3).

## LG-3 (Low, confirmed): one-proof messages set `lastMessage`

`deliver` sets `lastMessage` for every message, a `FREEZE` or a lowered cap carried on one proof included, and
`proposeSuccessor` requires both new verifiers to prove `lastMessage`. With one proof system broken, a forged one-proof
`FREEZE` sets `lastMessage` to a message never sent on Ethereum, and no honest successor can prove it.

Evidence: `VaultRecoveryPoC.t.sol` (`test_poc_aForgedOneProofFreezeBlocksAnHonestSuccessor`).

Fix: set `lastMessage` only for a message on both proofs.

## LG-4 (Low, confirmed on the contract): P1 and P2 have no wall-clock bound

`FinalityVerifier.update` checks no time, and the statement bounds only the epoch gap from the anchor (225 epochs), so
a verifier left behind does not stop for good, as the README and spec section 10 say ("as the BNB one is"): anyone can
advance it from an anchor of any age. Old stake that has since exited could then sign a forged finality at no risk.
Bounded by the stall window and the exit churn, but BNB-2 closed the same gap on the BNB verifier.

Evidence: `VaultRecoveryPoC.t.sol` (`test_poc_finalityVerifierTakesAProofFromAYearOldAnchor`).

Fix: store the network's genesis time and refuse `update` past `GENESIS + anchorEpoch * 384 + MAX_LAG`; or, if honest
catch-up is wanted, correct the documents.

## LG-5 (Low, confirmed): an exited chain's honest state still counts as evidence

After a vault's snapshot, its `resolveIntake` honestly fails every intake the hub had not marked settled. `voidOrder`
and `slashRebalance` do not check `_exitedAt`, and `reportOutflow` and `reportForgedDeposit` check only this index's own
`_exitedAt`, which stays zero until someone calls `recordExit` on it. So honest state can void an order and freeze the
chain at the factory for every index, against the rule that an exited chain takes no evidence. Nothing further can be
lost, since the vault is already in its snapshot, but monitors read the events as a broken proof system.

Evidence: `ExitEvidence.t.sol` (two tests: after `recordExit` through `voidOrder`, before it through
`reportForgedDeposit`).

Fix: refuse `voidOrder` and `slashRebalance` on an exited chain; and have each evidence proof also read the vault's
snapshot slot (`VAULT_SNAPSHOT_ROOT_SLOT`) in the same `verifySlots` call, refusing the evidence when it is set.

## LG-6 (Low, partly confirmed): the statement's margin does not bound the registry's drift in two cases

- Electra activates any backlog at once when finality returns. Validators pending at the anchor count nowhere in the
  anchor's records but count on the real chain at C1. After about 224 epochs of non-finality, up to about 57,000 ETH can
  activate within C1's first epochs, more than a one-epoch margin covers.
- C1's block can be older than C1's epoch (empty epochs before the boundary), and the statement never checks that
  block's slot, so the next proof's records can be several epochs old, not one.

Either way an attacker still needs about 66.5% of the stake; it breaks the margin's documented guarantee, not practical
soundness. Evidence: `finality_probes.rs` (`probe_validator_pending_at_the_anchor_counts_nowhere`,
`probe_checkpoint_block_older_than_its_epoch`).

Fix: count eligible-but-inactive validators in the active total but never in signed stake; carry the registry's own
epoch (`header.slot / 32`) in the anchor and compute the margin from it, or require `header.slot / 32 + 1 >= c1.epoch`.

## Informational

- **LG-I1.** Spec section 10's margin reasoning: each of deposits and exits has its own churn, so drift per epoch is the
  balance churn plus 256 ETH, and "over twice the churn" holds only up to about 50M ETH staked. What makes a forged
  signature free is a slashing after the anchor, which no churn limits, not an exit. Correct the text.
- **LG-I2.** The justification link's source is unconstrained (`statement.rs`): not unsound, since two thirds of target
  votes for C1 plus the C1→C2 link suffice, but `first.source.epoch < c1.epoch` is a cheap hardening.
- **LG-I3.** The one-epoch finality argument holds under its stated assumption, but the prototype record's closing claim
  that "the full rule fails as well" does not follow: with two thirds faulty, the one-epoch rule lets a coalition forge
  at the cost of an epoch's rewards, while the full rule forces a double or surround vote. Not adopting it was right;
  correct the record's sentence.
- **LG-I4.** With the real P1 on Solana, a day without `update` ends P1 for good (the 225-epoch gap), and replacing it
  needs a `VERIFIER_ROTATION` delivered on both proofs, P1's included, while the Solana vault has no stall recovery
  (SOL-7). The documents should not say P1 there "stops and is rotated".

## Checked and found correct

The reviewers report as correct, among the rest: the Groth16 checks on both verifiers (key constants, public inputs,
pairing layout, curve and subgroup checks), the public-values layout between the statement and `FinalityVerifier`, the
headers tree, the receipt proofs (MPT and RLP) on both, the anchor and epoch-gap checks, delivery on both proofs, the
checkpoint rule (VLT-3), the snapshot exit and `deliverRecorded`, the speed limit, governance delays, the mint cap and
seed (MOD-2, HUB-2), the hub's book, the bond and slash rules (MOD-1, HUB-1), the `_sentMessages` and `_settledIntakes`
marks, the storage layout shared by the hub's three parts, the statement's threshold, its counting of each validator
once, its signing domains and fork constants, its BLS hash to G2, and its Merkle positions.
