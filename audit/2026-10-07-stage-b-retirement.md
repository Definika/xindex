# Retirement of Stage B: the vaults, the proofs and the hybrid index

On 2026-10-07 the owner decided that Xindex ships without vaults of its own: "we don't need our own vaults and proofs
anymore". The weighted index is deployed twice, on Ethereum and on BNB Chain, each holding the tokens of its own
chain in kind, and nothing crosses between them (`design/2026-10-07-two-chain-deployment.md`). The coins the vaults
were built to hold natively come in as Binance-Peg tokens on BNB Chain, labelled Custodial, or not at all.

Stage B leaves the tree in full. The last commit with it is `04e936b`, tagged `stage-b-2026-10-07`. Deleted:
- `src/HybridHub.sol`, `src/HybridIndexFactory.sol`, `src/hybrid/`, `src/vault/`, `src/verifiers/`, their
  interfaces, and the libraries only they used (`VaultMessages`, `RlpReader`, `MerklePatricia`, `Bls12381`,
  `Bls12381MinSig`, `Blake2b`, `SuiBcs`, `WeightedPricing`), with the vendored `ISP1Verifier` and `IRiscZeroVerifier`;
- `script/Deploy.s.sol` (the hybrid factory's), `DeployVault`, `DeployStateVerifier`, `ConfigureChains`, `VaultCoins`
  and the two Groth16 identity interfaces; `DeployWeighted` is the one deploy script;
- `abi/HybridIndexFactory.json`, `abi/IHybridIndex.json`, `abi/XindexVault.json`;
- the vault chains' own code: `solana/`, `near/`, `stellar/`, `sui/`, `aptos/`, `tron/`, `vechain/`,
  `crates/xindex-core`; the proof systems `proofs/` (P1, P2, and the state proofs of NEAR, Stellar, Injective, VeChain
  and Aptos) and `prototype/`; `vendor/`; the keeper's cross-chain filler and chain adapters;
- every Stage B suite, mock, harness and fixture under `test/`, and the Stage B half of `test/Scripts.t.sol`;
- `foundry.toml`'s skip list, which held the hybrid suites, is empty again: every suite in the tree runs.

This file says which past findings went with Stage B, in the form of `audit/2026-10-06-v4-retirement.md`. It does not
restate the findings; the reports named in `AGENTS.md` gate 6 hold the originals.

- **RETIRED:** the mechanism the finding lived in is gone. The evidence names the tests that were removed.
- **RETIRED (in part):** part of the finding's mechanism is gone and its tests with it; the rest stands, tested under
  the same id.
- **UNAFFECTED:** everything not listed. Every finding against `WeightedHub`, `WeightedIndexFactory`, `IndexZap`,
  `MintRequests` and the scripts that remain keeps its test; the deploy and test-market tests of `test/Scripts.t.sol`
  (L06, FR06, XA-07, XA-25, XA-26, XA-38, XA-39, XA-47, SA-06, CR-I36, CR-I37) were re-targeted from the deleted
  hybrid `Deploy` to `DeployWeighted` unchanged in what they check, and RT-25's label test now runs through
  `ConfigureWeighted.safeCalldata`, the one place `ScriptUtils.symbolOf` is still used by a script.

A retired id is not free to reuse and its test must not be restored against the new design.

The check behind this file: the audit ids that name a Solidity test at `04e936b`, less the ids that name one after this
change, are exactly the 31 ids marked RETIRED with a Solidity test below. The Rust and Move tests named by id
(`test_lg1_…`, `test_sol1_…`, `test_vlt2_…`) went with their programs; they are listed under their ids.

## The Stage B red team of 2026-09-30 (`audit/2026-09-30-stage-b-red-team.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| VLT-1 | CRITICAL | A snapshot claim read any hub slot as "the component" | RETIRED | `test_VLT1_aTokenClaimReadsOnlyInsideTheArray`, `test_VLT1_theComponentMustLieInsideTheArray` removed with `test/XindexVault.t.sol`; `test_vlt1_…` with the Solana, NEAR and Stellar vaults. |
| VLT-2 | HIGH | Both proofs broken forged governance at once | RETIRED | `test_VLT2_aLooseningWaitsAndTheFreezerCanStopIt`, `test_VLT2_aTokensFirstCapWaitsAndTheFreezerCanStopIt`, `test_vlt2_…` removed. |
| VLT-3 | MEDIUM | A message after the last checkpoint could run, and the snapshot paid the holder again | RETIRED | `test_VLT3_aMessageAfterTheCheckpointWaitsForIt`, `test_VLT3_aTokenBurnWaitsForTheCheckpoint`, `test_vlt3_…` removed. |
| VLT-4 | LOW | Governance messages applied in delivery order | RETIRED | `test_VLT4_anOlderGovernanceMessageCannotUndoANewerOne`, `test_FAC2_VLT4_anOlderCapUpdateDeliveredLastDoesNotUndoANewerOne`, `test_vlt4_…` removed. |
| VLT-5 | LOW | The factory's `FREEZE` still ran after the snapshot | RETIRED | `test_VLT5_noFreezeAfterTheSnapshot`, `test_vlt5_…` removed. |
| VLT-I3 | INFO | A recovery address with its top bits set blocked a snapshot claim | RETIRED | `test_VLTI3_aMalformedRecoveryAddressCountsAsNone` removed. |
| VLT-I6, MOD-I1 | INFO | Evidence after an exit misfired | RETIRED | `test_VLTI6_MODI1_noEvidenceAfterTheExit` removed with `test/HybridHub.exit.t.sol`. |
| VLT-I1, VLT-I2, VLT-I4, VLT-I5 | INFO | Recorded by documentation | RETIRED | With the vault and the Stage B spec's known limitations. |
| HUB-1, MOD-1, BNB-1 | — | Every evidence proof is bounded below by a deadline or a freeze | RETIRED | `test_HUB1_MOD1_BNB1_aProofFromBeforeTheDeadlineIsNoEvidence`, `test_HUB1_MOD1_BNB1_anHonestEmptyIntakeIsNoEvidence` removed with `test/HybridHub.rebalance.t.sol`. |
| HUB-2 | MEDIUM | Anyone could seed an empty index with a one-wei order | RETIRED | `test_HUB2_onlyTheCreatorSeedsAnEmptyIndex` removed with `test/HybridHub.t.sol`. |
| HUB-3 | LOW | A locked order a freeze held was stuck with its escrow | RETIRED | `test_HUB3_theMinterMayGiveUpAnOrderAFreezeHolds` removed. |
| HUB-4, HUB-I1, HUB-I2, HUB-I3 | — | Recorded by documentation | RETIRED | With the hybrid hub. |
| MOD-2 | MEDIUM | Migration minted without the new index's mint cap | RETIRED | `test_MOD2_migrationRespectsTheNewIndexsMintCap` removed with `test/HybridHub.migration.t.sol`. |
| MOD-3 | LOW | A kept component that stopped answering blocked settlement | RETIRED | `test_MOD3_aKeptComponentThatNoLongerAnswersDoesNotBlockSettlement` removed. The property it regressed, DA-14 and RT-01, stays tested on `WeightedHub` (`test/WeightedHub.rebalance.t.sol`). |
| MOD-4 | LOW | A sold vault leg with a zero recipient was stranded | RETIRED | `test_MOD4_aSoldVaultLegWithoutARecipientIsTheExecutorsClaim` removed. |
| MOD-5, MOD-I2 to MOD-I6 | — | Recorded by documentation | RETIRED | With the module and the extension. |
| BNB-2 | MEDIUM | A verifier left behind could be forked by an old set | RETIRED | `test_BNB2_aStaleSetDoesNotNameTheNextOne`, `test_BNB2_noBlockMoreThanADayOld` removed with `test/BnbStateVerifier.t.sol`. |
| BNB-I1 to BNB-I4 | INFO | Recorded by documentation | RETIRED | With the BNB verifier and the chain freeze. |
| FAC-1 | MEDIUM | A new state verifier for a registered chain waited only 2 days | RETIRED | `test_FAC1_aNewStateVerifierWaitsTheRotationDelay` removed with `test/HybridIndexFactory.t.sol`, `test_FAC1_configureChainsRotatesAVerifierOnlyWhenNamed` with `ConfigureChains`. |
| FAC-2 | LOW | The factory's side of VLT-4 | RETIRED | With VLT-4 above. |
| SOL-1 to SOL-5, SOL-9 | — | The Solana vault's and stub's findings | RETIRED | `test_sol1_…` to `test_sol5_…` and `test_sol9_…` removed with `solana/`. |
| SOL-6, SOL-7, SOL-8, SOL-10 | INFO | Recorded by documentation | RETIRED | With `solana/`. |

## The TRON review of 2026-10-01 (`audit/2026-10-01-tron-review.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| TRN-1 | HIGH | A producer could write a header the verifier could not hash | RETIRED | `test_TRN1_aPoisonedHeaderIsStillWritten`, `test_TRN1_headerHash_writesANegativeVersionAndUnknownFields` removed with `test/TronStateVerifier.t.sol`. |
| TRN-2 | HIGH | The block after a maintenance was learned as a round's start | RETIRED | `test_TRN2_theBlockAfterTheMaintenanceIsNotLearned` removed. |
| TRN-3 | MEDIUM | Vouching needed 19 of the old list at once | RETIRED | `test_TRN3_vouchersMaySignLater` removed. |
| TRN-4 | MEDIUM | Only the old list vouches | RETIRED | `test_TRN4_onlyTheOldListVouches` removed. |
| TRN-5 | MEDIUM | A producer is learned with the key that signed | RETIRED | `test_TRN5_learnsEachProducerWithItsOwnKey` removed. |
| TRN-9 | INFO | A halt after a maintenance stopped the verifier for good | RETIRED | `test_TRN9_passesOverAPeriodOnTheGrid` removed. |
| TRN-6, TRN-7, TRN-8 | LOW | Recorded by documentation | RETIRED | With the TRON verifier. |

## The logic review of 2026-10-02 (`audit/2026-10-02-logic-review.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| LG-1 | HIGH | A message could be made undeliverable; any message can be sent again | RETIRED | `test_LG1_anyoneSendsAMessageAgain`, `test_LG1_anyoneSendsAFactoryMessageAgain`, `test_lg1_…` removed. |
| LG-2 | MEDIUM | A stale checkpoint lapsed the successor and reset the vetoes | RETIRED | `test_LG2_aStaleCheckpointKeepsTheSuccessorAndTheVetoes`, `test_lg2_…` removed. |
| LG-3 | LOW | One-proof messages set `lastMessage` | RETIRED | `test_LG3_aOneProofMessageIsNotTheLastMessage`, `test_lg3_…` removed. |
| LG-4 | LOW | P1 and P2 had no wall-clock bound | RETIRED | `test_LG4_aVerifierLeftADayBehindStopsForGood` removed with `test/EthereumFinalityVerifier.t.sol`, `test_LG4_deployVaultRefusesAnAnchorTheVerifiersCannotAdvance` with `DeployVault`, `test_lg4_…` with the Solana verifier. |
| LG-5 | LOW | An exited chain took evidence | RETIRED | `test_LG5_anExitedVaultsHonestStateIsNoEvidence`, `test_LG5_noSlashOnAVaultInItsExit` removed. |
| LG-6 | LOW | The finality statement's two cases | RETIRED | `test_lg6_…` removed with `proofs/finality`. |
| LG-I2 | INFO | The justification's source precedes `C1` | RETIRED | `test_lgi2_…` removed with `proofs/finality`. |
| LG-I1, LG-I3, LG-I4 | INFO | Recorded by documentation | RETIRED | With the proofs and the Stage B spec. |

## Later findings

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| BLS-1 | CRITICAL | `Bls12381.verify` passed unchecked lengths to the pairing precompile | RETIRED | `test_BLS1_aKeyOrSignatureOfAnyOtherLengthIsRefused` removed with `test/Bls12381.t.sol`, `test_BLS1_aLongSignatureCannotForgeAHeader` with `test/BnbStateVerifier.t.sol`. No contract in the tree calls a BLS precompile. |
| V5R-I1 | INFO | A 24-decimal vault coin could not be priced from a feed with an exponent below −12 | RETIRED | `WeightedPricing` is gone, and `WeightedIndexFactory` lists only ERC-20s of at most 18 decimals, which any Pyth exponent in [−18, 0] scales. Recorded by documentation; no test went. |
| RT-24 | INFO | A token named twice in a list made the Safe batch revert | RETIRED (in part) | `test_RT24_chainsAndCoinsNamedTwiceAreRefused` and `test_RT24_capsNamedTwiceAreRefused` removed with `ConfigureChains`. `test_RT24_V5M1_aListNamingATokenOrAnIdTwiceIsRefused` stands in `test/ConfigureWeighted.t.sol`. |

Unaffected, and worth saying so: every id re-targeted to `WeightedHub` by `audit/2026-10-06-v4-retirement.md` keeps
its test there; DA-14 and RT-01 (a component that stops answering is skipped) stay tested on the hub, where MOD-3 had
regressed them; and the swap-venue review's SV ids, the v5 reviews' V5 and V5R ids (but V5R-I1) and the Stage A red
team's SA ids are untouched.
