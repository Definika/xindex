# Internal red team of Stage B (2026-09-30)

Five reviewers each read part of Stage B at `c2f919c` on branch `v4-stage-a`, without changing it:
- the EVM vault (`XindexVault`) and its interfaces;
- `HybridHub`, its storage and its share operations;
- `HybridHubModule` and `HybridHubExtension`;
- `HybridIndexFactory`, `BnbStateVerifier` and the RLP, Merkle-Patricia and BLS libraries;
- the Solana vault program and its stub verifier.

They found:
- 1 critical (VLT-1);
- 3 high: VLT-2, and one slash bug that three reviewers reported (HUB-1, MOD-1, BNB-1);
- 6 medium;
- 12 low;
- informational notes.

Each finding's id carries its report's prefix. A test for a fixed finding carries every id it covers, for example
`test_HUB1_MOD1_BNB1_...`, as `AGENTS.md` gate 6 requires. Each was checked to fail without its fix by mutants:
- 16 on the EVM vault;
- 4 on the slash;
- 5 on the mint cap;
- 8 on the other hub fixes;
- 5 on the BNB verifier;
- 2 on the factory;
- 6 on the Solana vault.

The Solana program's tests are Rust tests named after their ids: `test_sol1_...`, and `test_vlt2_...` for an EVM finding
fixed on its twin.

This was an internal review. Stage B is not deployed, and its external audits are still to come.

## Findings

| ID | Sev | Finding | Status | Evidence |
|---|---|---|---|---|
| VLT-1 | CRITICAL | `claimSnapshot` read any hub slot as "the component": `_components` slot plus an unbounded index. A holder with a dust share who could fill some slot past the array's end, an allowance included, with the coin's id and a huge "units" would drain an index's balance within the speed limit. | FIXED | The claim reads the array's length (slot 0) and requires `component` below it. `test_VLT1_theComponentMustLieInsideTheArray` in `test/XindexVault.t.sol`. |
| VLT-2 | HIGH | With P1 and P2 both broken, governance is forged too: a raised floor lifted the speed limit at once, and a forged rotation or freezer change made the takeover permanent. | FIXED | A raised cap or floor, a new freezer and new verifiers wait `GOVERNANCE_DELAY` (7 days) on the vault, applied by anyone with `applyChange`. The freezer may `cancelChange` a raise or a rotation, never its own replacement. A freeze holds every change but that one. A lowering applies at once and drops a waiting raise. `test_VLT2_aLooseningWaitsAndTheFreezerCanStopIt`; on Solana, `test_vlt2_a_loosening_waits_and_the_freezer_can_stop_it`. Spec 5.4. |
| VLT-3 | MEDIUM | A message from an Ethereum block after the vault's last checkpoint could run, and the snapshot at that checkpoint would then pay the same holder again. | FIXED | A message that moves coins or loosens a rule runs only from a block at or before the checkpoint (`NotCheckpointed`). The relayer advances the checkpoint first. `test_VLT3_aMessageAfterTheCheckpointWaitsForIt`. Spec 5.6. |
| VLT-4 | LOW | Governance messages applied in the order delivered, not sent: an older cap raise delivered late undid a newer cut. | FIXED | Every governance message but a freeze must be newer than the last of its key (kind, and token for caps) taken on both proofs. Only a message on both proofs moves that mark, so a forged huge nonce on one proof locks nothing out. `test_VLT4_anOlderGovernanceMessageCannotUndoANewerOne`, `test_FAC2_VLT4_anOlderCapUpdateDeliveredLastDoesNotUndoANewerOne`; on Solana, `test_vlt4_one_proof_moves_no_mark`. |
| VLT-5 | LOW | The factory's `FREEZE` message still ran after the snapshot, though the freezer's own freeze did not. | FIXED | `test_VLT5_noFreezeAfterTheSnapshot`. |
| VLT-I1 | INFO | The successor's continuity test runs the proposer's own code, so it catches honest mistakes only. | DOCUMENTED | The guards are the 30-day review, the freezer's two vetoes and the lapse (spec 5.6, "Worst case"). |
| VLT-I2 | INFO | A delivered message did not lapse a pending successor. | RESOLVED | With VLT-3 no message from after the stalled checkpoint runs, and advancing the checkpoint lapses the successor. |
| VLT-I3 | INFO | A recovery address with its top bits set blocked its holder's snapshot claim by both paths. | FIXED | Such a value counts as none, so the holder signs. `test_VLTI3_aMalformedRecoveryAddressCountsAsNone`. |
| VLT-I4 | INFO | Some shares cannot claim at a snapshot: an executor's bond on the hub, shares escrowed in `MintRequests`, pool liquidity. Their coins stay in the vault. | DOCUMENTED | Spec 5.6 already lists pool liquidity as not built. The bond is at most 0.1% of supply. |
| VLT-I5 | INFO | Deposits into a registered index that holds nothing on the chain can never be failed, and count against the cap for good. More broadly, stray intakes can fill the shared cap for a week. | DOCUMENTED | The attacker locks the cap's worth of its own coin, for good in the first case. The owner raises a cap in 9 days (2 on the factory, 7 on the vault). |
| VLT-I6 | INFO | After an exit, snapshot claims raise `paidTotal` above `sentOut`, so `reportOutflow` and `reportForgedDeposit` misfired. | FIXED | Both refuse an exited chain (`ChainExited`). `test_VLTI6_MODI1_noEvidenceAfterTheExit` in `test/HybridHub.exit.t.sol`. |
| HUB-1, MOD-1, BNB-1 | HIGH | `slashRebalance` accepted a proof from any block and took an empty intake as forgery. An honest state of a chain the fill bought nothing on, or a state from before the deliveries, which the BNB verifier proves for old blocks, burned an honest executor's bond and froze the chain for every index. | FIXED | The proof must come from after the delivery deadline, which lies within the bond's 24-hour hold, and an empty intake is evidence only on a chain where the fill recorded a delivery. `test_HUB1_MOD1_BNB1_anHonestEmptyIntakeIsNoEvidence`, `test_HUB1_MOD1_BNB1_aProofFromBeforeTheDeadlineIsNoEvidence`. |
| HUB-2 | MEDIUM | Anyone could seed an empty index with a one-wei order, after which 4% of dust a day never let it grow. | FIXED | Only an index's creator may mint into it empty, by an order or a migration. `test_HUB2_onlyTheCreatorSeedsAnEmptyIndex`. |
| HUB-3 | LOW | A locked order a freeze held, never re-confirmed, was stuck with its escrow. | FIXED | Its minter may fail it `HELD_ORDER_GRACE` (7 days) after the freeze ends. `test_HUB3_theMinterMayGiveUpAnOrderAFreezeHolds`. |
| HUB-4 | LOW | A burn toward a recipient the vault can never pay, such as an EVM value with its top bits set or a contract refusing the coin, strands its coins. | DOCUMENTED | Zero recipients are already claims (and now a fill's, MOD-4). A 32-byte recipient cannot be checked in general, since Solana's are 32 bytes: the app validates recipients per chain. |
| HUB-I1, MOD-I4 | INFO | A fill settled on a proof taken before its deadline strands later deposits outside the book. | DOCUMENTED | Settlement needs each delivery in full, so only an executor's own excess is stranded, and it backs the holders. |
| HUB-I2 | INFO | A chain's registry id must equal its vault's `block.chainid`, which messages and digests both carry. | DOCUMENTED | A deployment check for every vault chain, Tron's especially (spec 8). |
| HUB-I3 | INFO | `IHybridHub.FREEZE_DURATION` said a freeze holds "this index's mints"; it holds every index's. The bond's shares cannot claim at a snapshot (VLT-I4). | FIXED | NatSpec corrected. |
| MOD-2 | MEDIUM | Migration minted without the new index's mint cap. A fresh index seeded on a forged deposit could carry that book into the flagship at once, past design 8.1's only bound on a broken deposit proof. | FIXED | `acceptMigration` counts against the new index's mint room; an empty index is seeded by migration only by its creator. A proof of the old index's vault balance would not help: the broken verifier would forge it too. `test_MOD2_migrationRespectsTheNewIndexsMintCap`. **For the owner's review:** a move to a new version fills at 4% of its supply a day after its creator's seed. |
| MOD-3 | LOW | `_checkBacking` read every component's balance after a settlement, so a kept component that stopped answering blocked it: a regression of DA-14 and RT-01. | FIXED | Settlement reads only the legs that send or receive. `test_MOD3_aKeptComponentThatNoLongerAnswersDoesNotBlockSettlement`. |
| MOD-4 | LOW | A sold vault leg with a zero recipient was burned toward nobody and stranded. | FIXED | It is booked as the executor's claim, as `redeem` does. `test_MOD4_aSoldVaultLegWithoutARecipientIsTheExecutorsClaim`. |
| MOD-5 | LOW | A fill settled after the vault's last checkpoint that ends in a snapshot has its deliveries refunded while the hub paid its Ethereum legs: a free option bounded by one rebalance's traded value. | DOCUMENTED | Like burns in flight at the snapshot. A snapshot needs 187 days of stall, and the fill's settle message now also waits for the checkpoint (VLT-3). |
| MOD-I1 | INFO | Evidence after a snapshot (VLT-I6). | FIXED | See VLT-I6. |
| MOD-I2 | INFO | `reportOutflow` catches a forged payout only once the backlog of sent but unpaid messages is paid. | DOCUMENTED | Paid totals and sent totals only grow, so the check is sound, only late. |
| MOD-I3 | INFO | `acceptMigration` never measures the Ethereum legs the old index sent. | DOCUMENTED | The backing check reads real balances, and the whitelist refuses fee-on-transfer tokens. |
| MOD-I5 | INFO | `settleRebalance` does not re-check freezes. | DOCUMENTED | The bond and the band bound a fill, as design 8.1 states. |
| MOD-I6 | INFO | `_band` reads kept components' supplies, unlike Stage A. | NO CHANGE | The factory's view cannot revert. |
| BNB-2 | MEDIUM | A verifier left behind could be forked by an old set, unbonded or unslashable for an old target, which also forged states dated in its window for readers that take old states. | FIXED | `MAX_LAG` (1 day): the latest set names the next only within it, and no proven block is older. `MAX_SPAN` 15 minutes, not an hour. `test_BNB2_aStaleSetDoesNotNameTheNextOne`, `test_BNB2_noBlockMoreThanADayOld`. A verifier left a day behind stops for good and is replaced. **For the owner's review.** |
| FAC-1 | MEDIUM | A new state verifier for a registered chain waited 2 days. It decides every index's mints there, and forged mints redeem real Ethereum tokens too, while new P1 and P2 wait 30. | FIXED | It waits `ROTATION_DELAY`. `test_FAC1_aNewStateVerifierWaitsTheRotationDelay`. **For the owner's review:** a dead verifier pauses that chain's mints for 30 days; holders redeem throughout. |
| FAC-2 | LOW | The factory's side of VLT-4. | FIXED | See VLT-4. |
| BNB-I1 | INFO | Any of the factory's clones, a stranger's included, can freeze a chain for every index on evidence. | DOCUMENTED | With HUB-1 fixed, no honest state triggers any evidence path. Any future evidence path must keep that property. |
| BNB-I2 | INFO | The guardian's freeze has no rate limit, so a hostile guardian stalls payouts until its replacement plus 14 days. | DOCUMENTED | The analogue of DA-12, a stated power of the role. |
| BNB-I3 | INFO | An account with empty storage makes `verifySlots` revert, where the interface promises zeros. | DOCUMENTED | A vault always has storage. |
| BNB-I4 | INFO | A key listed twice in a set would count twice toward quorum. | DOCUMENTED | Only a quorum-signed header can list one, and BNB's StakeHub keeps vote addresses unique. |
| SOL-1 | MEDIUM | Anyone could initialize a stub first and set its relayer key. | FIXED | Only the stub's upgrade authority initializes it. `test_sol1_only_the_deployer_initializes_a_stub`. |
| SOL-2 | MEDIUM | A verifier whose code can be upgraded was accepted as P1 or P2, bypassing the 30-day rotation. | FIXED | P1 and P2 must be programs nobody can upgrade, at initialization and at a rotation. `test_sol2_an_upgradeable_verifier_is_refused`. |
| SOL-3 | LOW | Governance messages applied in delivery order (the Solana side of VLT-4). | FIXED | Nonces per kind, moved only on both proofs. `test_sol3_an_older_freezer_change_cannot_undo_a_newer_one`, `test_vlt4_one_proof_moves_no_mark`. |
| SOL-4 | LOW | Lamports sent to a stub's state address blocked its initialization for good. | FIXED | Transfer, allocate and assign instead of create. `test_sol4_lamports_at_a_stubs_state_do_not_block_it`. |
| SOL-5 | LOW | A payout below rent to a new account failed the whole delivery. | FIXED | The payout waits as owed until the recipient holds the rent minimum. `test_sol5_a_small_burn_to_a_new_account_is_still_delivered`. |
| SOL-6 | INFO | Verifier accounts are passed read-only, so a real verifier that must write cannot run under the vault. | DOCUMENTED | A constraint on the production verifier interface. |
| SOL-7 | INFO | Without stall recovery, a rotation to a pair that cannot verify leaves the vault unable to deliver a corrective rotation. | DOCUMENTED | Spec 7: stall recovery comes with Solana's own state proof. On devnet the upgrade authority recovers. |
| SOL-8 | INFO | Message, owed, intake and deposit accounts are never closed, so relayers and depositors pay their rent. | DOCUMENTED | About 0.0027 SOL a burn. |
| SOL-9 | LOW | A burn to the treasury, `config` or another of the vault's own accounts stranded its payout. | FIXED | Such a recipient is refused. `test_sol9_the_vaults_own_accounts_are_no_recipients`. |
| SOL-10 | INFO | Solana's stake-weighted clock may run up to about 25% fast: about 5% a real day instead of 4%, and a freeze of about 11 real days. | DOCUMENTED | Bounded, and the same for every index. |

## Also fixed while reviewing

- **Wake and `demo/`.** Wake stopped on `demo/`, a Foundry project whose `xindex/` remapping only it knows, which the
  demo commit had missed. CI, the editor settings and `test_XA10_ciRunsEveryGate` now exclude it with `audit/` and
  `prototype/`.
- **The demo.** The relayer advances the HyperEVM vault's checkpoint before a message needs it. It initializes each stub
  from its deployer and the vault only once the stubs are final. `open` says so plainly when `SENDER_KEY` is not the
  empty index's creator. `demo/README.md` has the new order.

## Checked and found sound

- **The three-part hub.**
  - The only selector the hub, the module and the extension share is `FACTORY()`, and all three return the same
    factory.
  - Unknown selectors revert, and the fallbacks take no ether.
  - The module and extension, called directly, are never initialized.
  - One ERC-7201 guard and one share slot serve all three, and the layouts are pinned.
- **Fills.** Supply only shrinks during a fill, so settling at the settling supply keeps holders whole. Rounding
  favours the holders throughout, and an executor cannot escape its bond.
- **Migration.** Only the factory's clones are accepted, never the index itself. `holder` is always the old index's
  caller, and the two hubs cannot re-enter each other.
- **Evidence.** Voids, re-confirmations and forged-deposit reports are bounded by deadlines or freezes, so no honest
  state triggers them before a snapshot.
- **The vault.**
  - The EIP-712 claim signature is sound.
  - The speed limit's 25 hourly buckets are exact.
  - `held` accounts for every coin.
  - A message runs once.
- **The BNB verifier.** The RLP reader is bounds-checked, and the Merkle-Patricia walker refuses malformed nodes. The
  vote check follows bsc v1.7.8.
