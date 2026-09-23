# Triage of the 2026-09-16 whole-repo audit

Findings: `audit/2026-09-16-whole-repo-audit.md`. Each finding is triaged one at a time, test first:

1. Write a test that reproduces the defect.
2. Watch it fail.
3. Fix it.
4. Watch it pass.

Dispositions follow the audit skill:

- **FIXED:** the code changed.
- **DOCUMENTED:** docs or comments changed.
- **DISMISSED:** no change, with the reason.
- **UPSTREAM:** the fix belongs elsewhere.
- **PENDING:** not decided yet.

The first pass was committed and pushed at the owner's request on 2026-09-17.

Status on 2026-09-17, first pass: all 65 findings triaged, with 37 FIXED, 27 DOCUMENTED, 1 DISMISSED and none PENDING.

Second pass, later on 2026-09-17, at the owner's request ("fix every finding"): every DOCUMENTED or DISMISSED finding
was reopened and turned into a code change wherever one was possible, XA-04 included, which the owner approved as a
change to the recorded capped methodology. Fourteen moved to FIXED (XA-02, XA-04, XA-08, XA-16, XA-18, XA-20, XA-21,
XA-23, XA-27, XA-28, XA-38, XA-44, XA-59, XA-61). The fourteen still marked DOCUMENTED are the ones whose whole subject
is documentation: the NatSpec gaps (XA-14, XA-15, XA-49 to XA-55), prose accuracy (XA-17, XA-56, XA-57), the
multiple-wrapper whitelist policy (XA-31) and the USDT approval note (XA-48). Their code was already correct; there is
nothing left to change but words, and those words changed in the first pass.

Status now: 51 FIXED, 14 DOCUMENTED, 0 DISMISSED, 0 PENDING.

Gates after every batch:

- `forge fmt --check`
- `forge build` and `forge lint`, with zero findings
- `forge test`
- `forge coverage` at 100% for every file
- fork tests, when an RPC is available

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| XA-01 | MEDIUM | Distorted TWAP at the snapshot moves value through the auction | FIXED | Per-token `minLiquidity` in `TokenConfig`, timelocked through listings. `IndexRule` rejects snapshot windows whose harmonic-mean liquidity is below it (`ThinPriceHistory`) or whose 10-minute parts differ by more than 2,000 ticks (`PriceHistoryDeviates`). Views are unchanged and prices never enter settlement. Tests: `test_XA01_*` (both failed before the fix), `test_targetUnits_snapshot*`. Docs: ARCHITECTURE §3-5, README, CLAUDE.md. Mainnet minimums: 10% of live harmonic liquidity at block 25,992,129. |
| XA-02 | LOW | Stranger restarts an unfilled auction at a distorted snapshot | FIXED | Fix (b), the snapshot price checks, landed with XA-01. Fix (a) followed on 2026-09-17: after an auction expires unfilled, `startRebalance` holds strangers off for `REBALANCE_DELAY` as a cancel does (`_permissionlessAt`), so the owner and guardian take the first restart and a griefer cannot win every one. Tests: `test_XA02_aStrangerWaitsOutAnUnfilledAuctionBeforeRestarting` (failed before), `test_XA02_anUnfillableSnapshotThroughAnEmptyRangeCannotStart`, `test_startRebalance_pendingThenExpiredRestart`. The cost, two days added to an honest restart after an expiry unless the owner or guardian starts it, is in the README's known limitations and ARCHITECTURE §3 step 4. |
| XA-03 | LOW | Pending config change relists a delisted token | FIXED | `delist` now cancels a pending `proposeListing` proposal. The new owner-only `proposeConfig` changes a listed or delisted token's config without ever whitelisting it (merged hazard: refreshing a delisted token's config no longer relists it). `pendingIsListing` and the `listing` flag on `ListingProposed` expose the intent. Tests: `test_XA03_*` (both failed before), `test_proposeConfig_replacesTheConfigWithoutListing`, `test_delist_cancelsAPendingListingProposal`. |
| XA-04 | LOW | Capped rule does not cap ranks 3+ | FIXED | Option B, on the owner's decision of 2026-09-17: `_cappedWeights` now caps every constituent below the largest at 20% and redistributes what the caps hold back, pass by pass, at most one per constituent. `_topTwo` became `_top`. Weights are unchanged wherever no rank below the second exceeded the cap, so the Numbers model's sheet still reproduces (`test_weights_matchTheModel`); the default list's LINK goes from 34.9% to 20% (`test_XA04_cappedCapsEveryRankBelowTheFirst`, `test_weights_cappedShapes`, `testFuzz_cappedWeights`, all failing before). `MIN_CAPPED_COMPONENTS = 5` now has a real reason: four ranks under the cap hold 80%, three hold only 60%. Docs: Methodology.sol, ARCHITECTURE §2, README, AGENTS.md product decisions. |
| XA-05 | LOW | Keep mask cannot route around an unreadable component | FIXED | Uncapped snapshots never read kept components. Capped snapshots rank them from the plain price, and a still-unreadable one is listed as a known limitation. Test: `test_XA05_keptComponentsNeedNoSnapshotPrice`, which fails with `OLD` when an uncapped snapshot reads a kept component again and with `ThinPriceHistory` when a kept capped component needs a snapshot price (mutation checks). |
| XA-06 | LOW | Execute mode ignores the WHITELIST entry's config | FIXED | `execute` runs only proposals whose pending config equals the entry's. Propose and safe mode log when a different config is pending. Test: `test_XA06_executeSkipsAPendingConfigThatDiffersFromTheEntry` (failed before). |
| XA-07 | LOW | Owner check ignores Safe modules | FIXED | `Deploy.checkOwner` now also reads the Safe's module list on chain 1. It rejects any enabled module (`OwnerHasModules`), because a module acts without signatures, and fails closed on a multisig whose list cannot be read (`OwnerModulesUnknown`). Test: `test_XA07_checkOwnerRejectsASafeWithModules` (failed before). README, ARCHITECTURE, `.env.example` and CLAUDE.md say the owner Safe must keep no modules. |
| XA-08 | LOW | Later-hop partial fill strands tokens; docs promise otherwise | FIXED | `_sell` swaps a burn leg one hop at a time and measures each hop's unsold input, so the promise now holds for every hop; unsold `tokenOut` stays in the zap and is paid out with the rest (the reviewer's unhandled case), and a hop that sells nothing reverts with `InsufficientOutput` instead of reaching SwapRouter02's whole-balance sentinel. The leg minimum applies to the last hop. Tests: `test_XA08_aLaterHopsUnsoldInputReachesTheRecipient`, `test_XA08_unsoldTokenOutIsPaidOutAndAnEmptyHopReverts`, `test_I12_partialFillReturnsTheUnsoldPartToTheRecipient`. Docs: IndexZap and `IIndexZap` NatSpec, ARCHITECTURE §2 and §5, README, AGENTS.md zap rule. |
| XA-09 | LOW | Cardinality 200 assumes 12-second blocks | FIXED | Kept 200. The comment and docs state the 9.05-second bound and the remedy. `test_XA09_XA45_constantsStayInTheirRelationships` enforces cardinality against the window. |
| XA-10 | LOW | CI does not enforce the CLAUDE.md gates | FIXED | The workflow adds `forge lint -D notes`; a 100%-coverage gate that parses the (hit/total) fractions of every file row and fails on an empty summary (tested locally on pass, gap and empty inputs); `wake detect all src` with pinned eth-wake 4.22.1 and a config generated from foundry.toml, with `audit/` added to its exclusions; and a fork-RPC requirement for same-repo pull requests into main. Docs: README, ARCHITECTURE §6, AGENTS.md. As first written, the Wake step could not pass: the generated config excludes only Wake's default folders, so Wake compiled the PoCs in `audit/poc/`, which import files that exist only in the audited commit, and exited 2 before running a detector (reproduced locally with 4.22.1). The step now adds `audit` to both exclusion lists and fails if the generated file's shape changes; run verbatim, it reports no detections. Test: `test_XA10_ciRunsEveryGate` (failed before the exclusion). No GitHub run has been checked, so the runner setup (pipx, Wake's solc download) is still unconfirmed. |
| XA-11 | LOW | Script re-proposes and relists delisted tokens | FIXED | Propose and safe mode give a delisted token `proposeConfig` changes only, and list it again only when it is named in the new `relist` argument (`RELIST` env var, parsed in `run`). Test: `test_XA11_proposeSkipsADelistedTokenUnlessNamedForRelisting` (failed before), `test_parseAddresses`. README updated. |
| XA-12 | LOW | Fork executor template can be drained | FIXED | `RebalanceExecutorV3` accepts the callback only from the index its own `fill` is settling (`UnexpectedCaller`), and only its deployer sets fee tiers (`NotOwner`). NatSpec and README warn it is a fixture without slippage limits. Test: `test_XA12_rebalanceExecutorV3_takesCallbacksOnlyFromTheIndexItFills` (failed before). |
| XA-13 | LOW | Mainnet script inputs are unverified literal copies | FIXED | New `script/MainnetAddresses.sol` is the one copy of mainnet addresses, reference supplies and minimum liquidities, read by `Deploy`, `ConfigureWhitelist`, `SetupTestMarket`, `ForkAddresses` and `Scripts.t.sol`. New `test/fork/MainnetAddresses.fork.t.sol` checks it on-chain: symbols and decimals, the router's factory and WETH9, `getPool` for every pool, Deploy's mainnet market, and every default entry's pool, supply range and `checkConfig`. Tests: `testFork_XA13_*` (4/4 at block 25,998,099). AGENTS.md and README point to it. |
| XA-14 | LOW | startRebalance/previewTarget NatSpec omit restrictions | DOCUMENTED | `IIndexToken.startRebalance` now lists the `restartAllowedAt` gate, `TurnoverTooLow` and the snapshot price reverts. `previewTarget` says it checks neither the caller nor the mask. |
| XA-15 | LOW | guardian() NatSpec omits rebalance powers | DOCUMENTED | `IIndexFactory.guardian` lists the keep-mask start on any index and the start before `restartAllowedAt`. |
| XA-16 | LOW | "Rebalance due" condition wrong after an unfilled auction | FIXED | New `canStartRebalance()` view mirrors the permissionless checks, so an app never has to read `eta` for this. `pendingRebalance` NatSpec keeps saying an unfilled auction keeps its `eta`. Tests: `test_XA16_theRebalanceDuePredicateSurvivesAnUnfilledAuction`, `test_startRebalance_pendingThenExpiredRestart`. README's app notes and runbook use the view. |
| XA-17 | LOW | Docs say half to double; settlement allows 2.5x | DOCUMENTED | README, ARCHITECTURE §3-5 and the CLAUDE.md design rule now say targets move half to double and settled units half to 2.5x. `test_R17` is renamed `...ClipsTheTargetAtDouble` and now fills at the 1.5 opening and asserts 250e18 (2.5x). |
| XA-18 | LOW | Mainnet propose command cannot work with a Safe owner | FIXED | `propose` reads the factory's owner and reverts with `OwnerIsContract` when it has code, naming safe mode, so the README's command cannot silently be the wrong one. Test: `test_XA18_proposeRefusesAContractOwner`. README and the script header say a contract owner must use safe mode. |
| XA-19 | LOW | Second, independent 30-minute constant | FIXED | `SIGNED_TWAP_WINDOW` removed. `_meanTick` derives the signed period from `TWAP_WINDOW` and `TWAP_SUB_WINDOWS`, and `CAPPED_REMAINDER = WAD - CAPPED_TOP_WEIGHT`. |
| XA-20 | LOW | .env setup makes `forge test` hit an archive-only fork block | FIXED | Documented as before, and the fork suites now catch a failing `createSelectFork` and fail with the reason and the remedies (archive node, `FORK_BLOCK`, or `--no-match-path 'test/fork/*'`) instead of a raw fork error. AGENTS.md, README and `.env.example` still say forge auto-loads `.env`. |
| XA-21 | LOW | "One regression test per finding" is false for 8 v1 ids | FIXED | Every v1 id now has an id-named test. `test/Repo.t.sol` checks the facts no contract test can reach: the known-limitations section (I09), the pinned compiler and every `src`/`script` pragma (I10), the pinned CI toolchain and required fork RPC (I11), and `foundry.lock` against `.gitmodules` (L08, FR04; CI still compares the committed commits, which needs git). The script tests became `test_L06_checkOwner`, `test_FR06_checkGuardian` and two `test_FR05_*`. AGENTS.md gate 6 lists where each lives. Reading those files needs the new read-only `fs_permissions` in `foundry.toml`. |
| XA-22 | INFO | Zap mint checks the nonce before the swaps | FIXED | `mintWithToken` checks the nonce again (`_checkNonce`) right before `issue`, after the swaps and the refund. `test_XA22_mintRechecksTheRebalanceNonceBeforeIssuing` settles a rebalance from a hook token's callback in the middle of a mint and expects `StaleRebalanceNonce`; it failed before the fix. |
| XA-23 | INFO | Overflow in rule products at extreme ticks | FIXED | The rule keeps its products inside 256 bits: a market cap is `supply * price / 1e18` floored at one wei (weights use only ratios), and values are exact `units * price` while every price is at most `MAX_EXACT_PRICE` (1e46) and scaled by WAD above it (`Basket.scale`). Ordinary baskets are unchanged to the wei, which the unchanged R-series and invariant fixtures show, and a mean tick near `MAX_TICK` with a 1e33 supply now returns a snapshot instead of panicking: `test_XA23_extremeTicksDoNotOverflowTheRule` (panics 0x11 without the scale). ARCHITECTURE §5 overflow bullet rewritten. |
| XA-24 | INFO | Raw-unit referenceSupply has no sanity bound | FIXED | Propose and safe modes log each reference supply in whole tokens, where a decimals slip shows. The script Env docs and README say the value is in raw units. `testFork_XA13_XA24_defaultWhitelistMatchesMainnet` bounds every default reference supply to 1e6-1e12 whole tokens. No hard bound in the rule: legitimate supplies span too many magnitudes. |
| XA-25 | INFO | Deploy does not reject the broadcaster as guardian | FIXED | `checkGuardian` is `view` and rejects `msg.sender`, the broadcasting key (`GuardianIsBroadcaster`). `test_XA25_guardianCannotBeTheBroadcastingKey`. |
| XA-26 | INFO | Test-market seed centres on a skewable tick | FIXED | `seed` checks every pool's square-root price against its spec, within 1% (`PRICE_TOLERANCE_DIVISOR`), before anything is broadcast (`PoolPriceMoved`). `test_XA26_seedRefusesAPoolWhosePriceMoved`. |
| XA-27 | INFO | Dust supply skips the parity multiplier | FIXED | Parity is no longer tied to `supply == 0`: `_previewRebalance` settles the shrinking legs first, and when none of them sends a raw unit out the multiplier is `WAD`, so nothing that moves nothing depends on timing (`currentMultiplier` reports the same). Tests: `test_XA27_aSettlementThatSendsNothingOutIsPricedAtParity` (failed before), `test_XA27_aSupplyThatStillMovesUnitsKeepsTheAuction`. The finding's own case, a dust supply that still moves a few wei, is left to the auction on purpose: any supply threshold would be arbitrary and cheap to step over. It is documented in `_multiplier`, ARCHITECTURE §5 (Level) and the README's known limitations. |
| XA-28 | INFO | Executor may use surplus to under-deliver | FIXED | `executeRebalance` records what the index holds before it pays out, and the post-check now requires the higher of the backing and `held - amountsOut + amountsIn`, so surplus from rounding or a donation stays with the holders and cannot cover part of a fill. Test: `test_XA28_anExecutorCannotDeliverLessBecauseTheIndexHoldsASurplus` (failed before); the invariant handler's short fill can no longer settle at all, and `invariant_rebalanceBookkeeping` pins that. Docs: `IRebalanceExecutor`, `_checkBacking`, `IIndexToken.RebalanceUnderfunded`, ARCHITECTURE §2, AGENTS.md invariant rule. |
| XA-29 | INFO | Zero-amount burn legs skip path validation | FIXED | `_sellBasket` validates every leg's path, including legs that redeem to zero. A non-zero leg minimum on a leg that sells nothing reverts `InsufficientOutput(0, min)`. `test_XA29_zeroLegsAreStillValidatedAndTheirMinimumsApply`; the `BurnLeg` NatSpec states both. |
| XA-30 | INFO | Recipient may be the SwapRouter02 | FIXED | `_checkCommon` rejects `to == ROUTER` with `InvalidRecipient`. `test_XA30_theRouterIsNotAValidRecipient` covers mint and burn. |
| XA-31 | INFO | WBTC and tBTC valued inconsistently | DOCUMENTED | ARCHITECTURE §5 (whitelist policy): two wrappers of one asset are weighed by their own configs, WBTC with bitcoin's supply and tBTC with its float, so a second wrapper should be listed with a reference supply that states its share. |
| XA-32 | INFO | test_R09 dust claim is false | FIXED | `test_R09` issues shares that do not divide the units evenly and asserts the kept component holds more than its required backing ("issuing rounded up and left dust") before checking it never moves. |
| XA-33 | INFO | Windfall control test comment misstates the gap | FIXED | The assertion message now reads "times the bought value at current prices". |
| XA-34 | INFO | WBTC pause fork test uses a bare expectRevert | FIXED | `testFork_guardianRebalancesAroundAPausedWbtc` asserts WBTC is a shrinking leg (`amountsOut[0] > 0`) and expects exactly WBTC's empty revert data (`bytes("")`). Passes at block 25,992,479. |
| XA-35 | INFO | Round-up test cannot detect Floor | FIXED | `test_executeRebalance_growingUnitsRoundUp` starts from 100e18 + 7 units, so the growth does not divide evenly, and asserts the ceiling. Mutation check: replacing `Ceil` with `Floor` in `_previewRebalance` fails it. |
| XA-36 | INFO | Four bare vm.expectRevert() tests | FIXED | The four tests expect exact revert data: `bytes("")` for the callback to an account without code, and OpenZeppelin's `ERC20InsufficientAllowance` / `ERC20InsufficientBalance` with their arguments. No bare `vm.expectRevert()` is left in `test/`. |
| XA-37 | INFO | Pool mock does not model a lazily grown ring | FIXED | `MockUniswapV3Pool` separates slots from history (`setObservationCardinality`, `setHistoryTooShort`, `increaseObservationCardinalityNext`). `test_checkConfig_pools` and `test_constructor_rejectsABadMarket` expect `OLD` from a pool with enough slots but too little history. The `MIN_OBSERVATION_CARDINALITY` NatSpec says a just-grown ring holds only the history written so far, and ARCHITECTURE §5 (operations) says how to grow one. |
| XA-38 | INFO | CREATE deployment, no frozen release record | FIXED | `Deploy.checkDeployment(factory, zap)` proves the two are one deployment (`WrongWiring`) and returns the runtime code hashes of the factory, rule, implementation and zap; `deploy` logs them, so every broadcast record freezes them, and the check can be re-run against a recorded deployment at any time. Test: `test_XA38_checkDeploymentFreezesTheCodeHashes`. README's deployment record says to record and re-check them. CREATE is kept, for the reasons above. |
| XA-39 | INFO | checkOwner accepts any contract | FIXED | `checkRolesAreNotMarket` rejects an owner or guardian that is a market contract (`RoleIsMarketContract`). A Safe owner must also have no enabled module (XA-07). A non-Safe contract owner such as a timelock stays accepted on purpose, as the `checkOwner` NatSpec says. `test_XA39_rolesCannotBeMarketContracts`. |
| XA-40 | INFO | Decimals/stablecoin policy only social | FIXED | In the scripts, both propose and safe mode skip, with the reason logged, a mint currency (USDC, USDT) and a token outside 6-18 decimals or without `decimals()` (`_followsPolicy`). `test_XA40_proposeSkipsTokensOutsideTheWhitelistPolicy`. The rule stays policy-free: the policy is social by design, and an owner can list a non-standard token that passes any cheap on-chain check, such as a fee-on-transfer token, so a partial check would promise more than it gives. |
| XA-41 | INFO | No IIndexZap interface or generated ABI | FIXED | New `src/interfaces/IIndexZap.sol` holds the structs, events, errors and entry points with full NatSpec; `IndexZap is ReentrancyGuard, IIndexZap`. The generated ABIs are committed under `abi/`, and CI fails when they drift from the code (XA-44). |
| XA-42 | INFO | Recurring operator duties have no runbook | FIXED | `LISTING_MODE=status` logs per entry whether the token is listed, whether the config in force is the entry's, and any pending proposal with its window (`test_XA42_statusReportsListingsAndPendingProposals`). README "Operations runbook" tabulates each recurring duty with its trigger, deadline, party and command. |
| XA-43 | INFO | Fork-rehearsal broadcasts can be committed as real | FIXED | `.gitignore` ignores `/broadcast/*/1/`, so mainnet-fork rehearsals, which keep chain id 1, are not committed; `.gitignore` and the README "Deployment record" say a real mainnet record is added with `git add -f` after checking its transactions on-chain. Test: `test_XA43_chainOneBroadcastsAreIgnored`. |
| XA-44 | INFO | README error/event lists hand-copied and incomplete | FIXED | `abi/IndexFactory.json`, `abi/IndexToken.json`, `abi/IndexRule.json` and `abi/IndexZap.json` are committed, and CI regenerates them with the pinned toolchain and fails on a diff. README points the app at them, says to read the timing constants on chain, and keeps the dated error and event summary. Test: `test_XA44_theAbisAreCommittedAndChecked`. |
| XA-45 | INFO | Cross-constant relationships enforced only by comments | FIXED | Derived constants (XA-19). `test_XA09_XA45_constantsStayInTheirRelationships` covers window/parts, cardinality/window, outlier/deviation and target cap/multiplier/uint96. `IndexFactory.t.sol` asserts `MAX_COMPONENTS <= 24` for the 24-bit keep mask. |
| XA-46 | INFO | AGENTS.md duplicates CLAUDE.md; Wake remappings duplicated | FIXED | `CLAUDE.md` is now a stub that imports `@AGENTS.md`, so the guidance has one copy. AGENTS.md says `.vscode/settings.json` holds the Wake extension's copy of `forge remappings` (identical today) and to paste the new output when remappings change; CI generates its own Wake config from `foundry.toml`. Test: `test_XA46_claudeMdOnlyImportsAgentsMd`. |
| XA-47 | INFO | Deploy does not cross-check market addresses | FIXED | On chain 1, `_resolve` rejects any market address other than the default (`MainnetOverride`), so a stray `.env` value cannot reach a mainnet broadcast, and the roles cannot be market contracts (XA-39). `test_XA47_mainnetMarketCannotBeOverridden`. `MainnetAddresses.fork.t.sol` checks the router's `factory()` and `WETH9()` against the defaults. |
| XA-48 | INFO | USDT approve note incomplete | DOCUMENTED | README (Approvals): USDT's `approve` reverts when changing one non-zero allowance to another; send `approve(zap, 0)` first. |
| XA-49 | INFO | IndexZap NatSpec gaps | DOCUMENTED | `IIndexZap` documents every struct field, event, error, getter, parameter and return. `mintWithToken` says the whole budget is pulled first, the shares go to `p.to`, and `amountSpent` includes `tokenIn` the basket holds directly. `burnToToken` says unsold components go to `p.to` with `ComponentReturned`. |
| XA-50 | INFO | Script NatSpec gaps | DOCUMENTED | NatSpec for `run`, `deploy`, `checkOwner`, `checkGuardian`, `checkRolesAreNotMarket`, `resolveMarket`, the `Market` fields, constants and errors in Deploy; `run`, `Entry` fields, constants, `Action`, errors and every public function's parameters and returns in ConfigureWhitelist (execute only runs a pending config equal to the entry's, XA-06); `Spec`/`Uniswap` fields, constants, errors and functions in SetupTestMarket; `COOLDOWN`, `DripTooSoon`, the constructor and `decimals` in FaucetToken. |
| XA-51 | INFO | Uniswap interfaces / PathLib NatSpec gaps | DOCUMENTED | `ISwapRouter02` struct fields (including the router's address(1)/address(2) recipients and the zero-amount balance flag) and returns; `IUniswapV3Pool.fee`, every `slot0` return, `observe` parameters and returns; `IUniswapV3Factory.getPool` parameters; PathLib constants, and `firstToken`/`lastToken` must follow `isValidShape`. |
| XA-52 | INFO | MAX_TARGET_UNITS NatSpec overstated | DOCUMENTED | `MAX_TARGET_UNITS` is the cap the rule raises a component to; a component already above it, or kept, keeps larger units, whose target is never above current units, and the multiplier only applies to increases. The implementation comment notes 1.5 times the cap is exactly `type(uint96).max`. |
| XA-53 | INFO | IIndexFactory NatSpec gaps | DOCUMENTED | `IIndexFactory` documents every event and error, `MAX_COMPONENTS`, `IMPLEMENTATION`, `isWhitelisted`, `whitelistedTokens` (order not stable after `delist`), `isIndex`, `creatorOf`, `allIndexes`, `allIndexesLength`, `predictIndexAddress`, `createIndex` (name, symbol, units up to uint96, return) and the propose, cancel, execute, delist and guardian parameters; the owner-only functions' `OwnableUnauthorizedAccount` is named. |
| XA-54 | INFO | IIndexToken NatSpec gaps | DOCUMENTED | `IIndexToken` documents every event (with `RebalanceStarted`, `RebalanceCancelled` and `Rebalanced` fields) and error, `componentCount`, and the parameters and returns of `initialize` (methodology validated by the factory), `issue`, `redeem`, `redeemSkipping`, `claim`, `executeRebalance`, `previewTarget` and `previewRebalance`. `IndexToken.nonces` has `@inheritdoc IERC20Permit`. |
| XA-55 | INFO | IIndexRule NatSpec gaps | DOCUMENTED | `IIndexRule` documents every error, the `WETH`, `UNISWAP_V3_FACTORY` and `USDC` getters, and the parameters and returns of `checkConfig`, `price` (WETH is 1e18, USDC from `USD_POOL`), `supply`, `weightsFromCaps`, `weights`, `targetUnits` (ignored high mask bits), `navPerToken` and `initialUnits` (raw USDC input). A token with no config reverts without a reason, pinned by `test_price_andSupplyOfATokenWithNoConfig`. The implementation's constants carrying dev notes now `@inheritdoc` the interface, so their user docs appear. |
| XA-56 | INFO | navPerToken described as burn proceeds | DOCUMENTED | ARCHITECTURE (Index price): `navPerToken` values units at 30-minute averages, while a burn sells at spot after rounding and swap costs, so proceeds can differ, especially in fast markets. |
| XA-57 | INFO | ARCHITECTURE defers zap to missing v1 docs | DOCUMENTED | ARCHITECTURE describes the zap in full where it used to defer to v1 (path endpoints, per-leg limits, balance-measured accounting, first-hop partial fills, shortfalls, `issue` last, `expectedNonce`, permit, never `redeemSkipping` or `executeRebalance`); the remaining "as in v1" mentions only note the behaviour is unchanged. |
| XA-58 | INFO | --verify without ETHERSCAN_API_KEY | FIXED | `.env.example` has `ETHERSCAN_API_KEY`, `foundry.toml` has `[etherscan]` entries for mainnet and Sepolia, and README says `--verify` needs the key. Test: `test_XA58_verificationHasItsApiKey`. |
| XA-59 | INFO | Rebalance event ids reused; no expiry event | FIXED | New `proposalCount`: every proposal gets its own id, and `RebalanceStarted`, `RebalanceCancelled` and `Rebalanced` carry it (started and settled also carry the `rebalanceNonce` they take). An indexer can now tell a cancelled, an expired and a settled attempt apart; expiry still has no event, and the next `RebalanceStarted` is the first sign of it. Test: `test_XA59_everyProposalCarriesItsOwnId`. Docs: `IIndexToken` events, README app notes. |
| XA-60 | INFO | proposeGuardian silently replaces a pending change | FIXED | `proposeGuardian` emits `GuardianChangeCancelled` for a pending change it replaces. `test_XA60_replacingAPendingGuardianChangeEmitsItsCancellation`. |
| XA-61 | INFO | Owner can remove the guardian check in 7 days | FIXED | The current guardian can now cancel a guardian change that would remove the role (`pendingGuardian == address(0)`), so the factory is never left without a guardian over its objection; it still cannot block its own replacement, because a guardian that turns hostile or loses its keys has to be replaceable. Test: `test_XA61_theGuardianCanCancelItsOwnRemoval`, plus the widened `test_cancelGuardianChange`. The remaining trust property, that an owner can install a guardian it controls after `GUARDIAN_DELAY`, is in ARCHITECTURE §5 and the README runbook, which treat `GuardianProposed` as a security alert. |
| XA-62 | INFO | Duplicate custom errors across interfaces | FIXED | New `src/interfaces/IXindexErrors.sol` declares `ZeroAddress`, `LengthMismatch`, `InvalidMethodology`, `TooFewComponentsForCapped`, `Unauthorized`, `NotIndex` and `InvalidRecipient` once; `IIndexFactory`, `IIndexRule`, `IIndexToken` and `IIndexZap` extend it. `IXindexCore` in `test/Security.t.sol` extends the factory, rule and token interfaces together, which failed to compile before (`Identifier already declared`), and `test_XA62_oneInterfaceExtendsTheFactoryRuleAndToken` uses it. The audit's note that `IIndexRule.ZeroAddress.selector` keeps compiling is wrong: Solidity does not resolve inherited errors through the derived interface, so tests name `IXindexErrors.<Error>.selector` (AGENTS.md conventions). Selectors are unchanged. |
| XA-63 | INFO | Test setup helpers duplicated | FIXED | New abstract `test/XindexTest.sol` (market, factory, owner, `_list`) is shared by the factory, token, zap and security suites instead of four copies. |
| XA-64 | INFO | CI clones unused nested submodules | FIXED | CI checks out `submodules: true` (lib/* only) and checks the lock in both directions: every `.gitmodules` path against `foundry.lock`, and every `foundry.lock` entry against `.gitmodules` (verified: a ghost lock entry fails). A build without the nested submodules passed the whole suite. AGENTS.md records the pinned Foundry v1.8.1 and eth-wake 4.22.1. Test: `test_XA64_ciChecksOutDirectSubmodulesAndTheLockBothWays`. |
| XA-65 | INFO | Script helpers duplicated | FIXED | New `script/ScriptUtils.sol` (`POOL_FEE_LOW`, `POOL_FEE_MEDIUM`, `same`) and `script/MainnetAddresses.sol` replace the copies; ConfigureWhitelist types its factory as `IIndexFactory`. |

## Final gates, 2026-09-17 (first pass)

- `forge fmt --check`: clean.
- `forge build --sizes`: clean. The factory's initcode is 45,683 bytes, 3,469 below the limit.
- `forge lint`: no findings.
- `forge test`: 277 offline tests pass.
- `forge coverage --no-match-path 'test/fork/*'`: 100% lines, statements, branches and functions on all 29 files.
- `wake detect all src` (eth-wake 4.22.1): no detections on the 16 files.
- Fork tests: 20 of 20 pass against publicnode at block 25,992,479.

## Final gates, 2026-09-17 (second pass)

- `forge fmt --check`: clean.
- `forge build --sizes`: clean. The factory's initcode is 46,688 bytes, 2,464 below the limit.
- `forge lint -D notes`: no findings.
- `forge test`: 294 offline tests pass (4 fork suites skipped without an RPC).
- `forge coverage --no-match-path 'test/fork/*'`: 100% lines, statements, branches and functions on all 29 files.
- `wake detect all src` (eth-wake 4.22.1): no detections on the 16 files.
- Fork tests: 20 of 20 pass against publicnode at block 25,996,975.
- `abi/*.json` regenerated with the pinned toolchain and committed; CI fails on a diff.

## Follow-up, 2026-09-17

Checking this ledger against the tree found three gaps, now closed:

- CI's Wake step (XA-10) could not pass, because Wake compiled the PoCs in `audit/poc/`. The Wake gates above counted
  16 files, so they ran with `audit/` left out; the config CI generates finds 32 and stops on the PoCs. The step now
  excludes `audit/`; see the XA-10 row.
- The XA-41 row still said no ABI JSON is committed, which XA-44 reversed.
- AGENTS.md gate 6 asks for a regression test named after each testable finding's id, but eleven FIXED findings had
  none. XA-05, XA-09, XA-13, XA-24 and XA-45 were covered by tests named for their behaviour, which now carry their
  ids. XA-10, XA-43, XA-44, XA-46, XA-58 and XA-64 changed repository files that no test read; `test/Repo.t.sol` now
  checks them. Gate 6 also said every XA test lives in the security suites; it now says each sits in the suite of what
  it checks, and names the findings with no test of their own because they changed only tests and mocks or
  refactored without changing behaviour.

Gates after the follow-up:

- `forge fmt --check`: clean.
- `forge build --sizes`: clean. The factory's initcode is still 46,688 bytes, 2,464 below the limit.
- `forge lint -D notes`: no findings.
- `forge test`: 300 offline tests pass (4 fork suites skipped without an RPC).
- CI's coverage step, run locally: 100% on all 29 files.
- CI's Wake step, run verbatim without its `pipx install` (eth-wake 4.22.1): no detections.
- `abi/*.json`: identical to a fresh `forge inspect`.
- Fork tests: 20 of 20 pass against publicnode at block 25,998,099.

## Corrections of 2026-09-23

The security audit of 2026-09-23 (`audit/2026-09-23-security-audit.md`, ids `CR-..`, triaged in
`audit/2026-09-23-triage.md`) found six rows here that no longer described the repository after the move to Chainlink
and the Universal Router on 2026-09-22. The rows above keep what was true on 2026-09-16; this says what changed.

- **XA-13 and XA-47.** The fork check stopped reading SwapRouter02's `factory()`, `WETH9()` and every default pool with
  the move, and checked the Universal Router's `poolManager()` instead, which every Universal Router build on mainnet
  answers alike, so it could not tell the pinned 2.0.0 build from a 2.1.x one (CR-I35).
  `testFork_XA13_CRI35_uniswapContractsAgree` now pins the router's and the PoolManager's runtime code hashes.
- **XA-24.** The whole-token range assertion this row cites was removed on 2026-09-22 from the test that kept its id
  (CR-I22). It is back, in the renamed `testFork_XA13_XA24_CRI22_defaultWhitelistMatchesMainnet`, and offline in
  `test_XA24_CRI22_everyDefaultSupplyIsAPlausibleCountOfWholeTokens`. Every default entry now carries a reference
  supply (CR-M01), so every one is bounded.
- **XA-39.** The move narrowed `checkRolesAreNotMarket` to the Universal Router alone (CR-I37). It refuses the router
  and its PoolManager everywhere again, and on chain 1 every token, mint currency and feed in
  `script/MainnetAddresses.sol`; `test_XA39_CRI37_noMarketContractCanHoldARole`.
- **XA-43.** Sepolia-fork rehearsals keep chain id 11155111, and `.gitignore` covered only chain 1's; it ignores
  `/broadcast/*/11155111/` too, and `test_CRI40_sepoliaForkBroadcastsAreIgnored` pins it (CR-I40).
- **XA-44.** The dated error summary in the README had fallen behind the ABIs: it missed `SettlementValueTooLow` and
  `SupplyChangeTooLarge` (CR-I15). The committed ABIs were never wrong, since CI regenerates them; the summary is
  brought up to date.
