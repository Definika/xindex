<!--
Committed verbatim on 2026-09-23 from the audit workspace (audit-work/AUDIT-REPORT.md). The repository cites its
findings as CR-M01, CR-L01 to CR-L08 and CR-I01 to CR-I41: the report's own ids with the review's prefix, since M01,
L03, L06, L08, I02, I03 and I09 to I12 are already v1 ids. Dispositions and evidence are in audit/2026-09-23-triage.md.
The PoCs its section 7 cites are in audit/poc/2026-09-23/, under the same file names; like every PoC under audit/, they
compile only against the audited commit, 855e41b. The workspace's other PoCs and its raw findings data were not
committed.
-->

# Xindex v3 — Security Audit Report

| | |
|---|---|
| **Repository** | https://github.com/Definika/xindex-v2 (`main`, commit `855e41b`, "Merge pull request #5 from Definika/v3-chainlink-router") |
| **Scope** | `src/IndexToken.sol`, `src/IndexRule.sol`, `src/IndexFactory.sol`, `src/IndexZap.sol`, `src/CompositeFeed.sol`, `src/libraries/*`, `src/interfaces/*`, `script/*` (Deploy, ConfigureWhitelist, MainnetAddresses, testnet), CI and configuration |
| **Dates** | 2026-09-22 to 2026-09-23 |
| **Auditor** | Claude (lead auditor), with 20 independent sub-auditors and 48 independent verifiers |
| **Result** | **0 Critical · 0 High · 1 Medium · 6 Low · 2 Low (unverified) · ~40 Informational** |

---

## 1. Executive summary

Xindex lets anyone create an index ERC-20 that is fully backed in kind by a fixed basket of whitelisted tokens. The basket's units follow an on-chain market-cap rule (uncapped, or capped at 30%/20%). Prices come from Chainlink, and a permissionless monthly rebalance settles through a descending auction. A stateless zap mints from, and burns to, a single token through Uniswap's Universal Router 2.0.0 on V3 and V4.

The codebase is mature. It has been through five earlier reviews, it holds 362 unit/fuzz/invariant tests and 25 mainnet-fork tests (all passing), and its value-bearing core is small and oracle-free. **We found no way to steal funds, mint unbacked shares, redeem more than a holder's backing, or break the backing invariant.** Independent stateful fuzzing campaigns, a bit-exact differential model of the rule run over 1.7M+ vectors, fork runs against the real router, PoolManager, feeds and tokens, and mutation sweeps all came back clean on those properties.

The most important result is a **Medium**:

> **M-01 — any stranger can distort a rebalance snapshot for free through wstETH's live `totalSupply()`.** The shipped whitelist gives wstETH no reference supply, so the rule reads its live supply. Anyone can flash-borrow about 35% of all wstETH at zero fee from SparkLend and Morpho, `unwrap` it, call the permissionless `startRebalance`, then `wrap` back and repay, all in one transaction. The snapshot is then computed on a supply that never existed. This forces rebalances the rule would refuse (it bypasses `MIN_TURNOVER`), reshapes targets, and can also suppress rebalances that are due. It contradicts the design's central claim that *"under Chainlink pricing a stranger cannot distort a snapshot."* **The fix is a one-line configuration change:** list wstETH with a timelocked reference supply, as WETH, WBTC and wSOL already are.

The Low findings are:

- **L-01:** an incomplete earlier fix (VR-01, the capped tie-flip).
- **L-02:** anyone can make zap burns revert for the price of gas.
- **L-03:** a bypass of the DA-18 supply-change bound.
- **L-04:** a script check that a lookalike feed can pass.
- **L-05:** wSOL has no peg leg.
- **L-06:** the documented 15% worst-case executor take is exceeded at market prices.

The Informational items are mostly places where the docs don't match the code, and critical safety checks that no test pins (their mutants survive the whole suite).

### Recommended actions, in priority order

1. **Before any mainnet listing:** give wstETH a non-zero `referenceSupply`. Better, refuse `referenceSupply == 0` in `checkConfig`/the factory, so no supply the rule reads can move inside a transaction (M-01).
2. Fix the unsold-amount arithmetic in `IndexZap._v3Hop` / `_sellV4` (L-02). It is a two-line change.
3. Bound the *effective* supply in `_checkSupplyChange`, and restore an on-chain guard that WETH, WBTC and wSOL carry a reference supply (L-03, L-07).
4. Pin the WBTC `CompositeFeed` by codehash, and pin every default-list feed pairing in a fork test (L-04, L-08).
5. Correct the docs' bounds (VR-01 tie behaviour, DA-05's 15%, "oracle-free settlement"), and add the missing kill-tests listed under Informational.

---

## 2. Methodology

1. **Manual review** of every in-scope source file by the lead auditor, plus the design docs (ARCHITECTURE.md, README.md, AGENTS.md) and all earlier audit reports (`audit/*.md`: XA, LR, DA, VR and R ids, and the v3 retirement ledger).
2. **Baseline:** `forge build`, then 362/362 offline tests passing and 25/25 fork tests passing (public RPC, recent block).
3. **Parallel lens-based hunting (3 rounds, 20 sub-auditors).** Each sub-auditor had its own copy of the repo and wrote Foundry PoCs.
   - Round 1 covered 12 lenses: token accounting · rebalance state machine · rule mathematics · price/supply inputs · zap mint + Universal Router encoding · zap burn + permit · factory governance · economics/game theory · scripts/ops/CI · real-token integration · earlier-fix regression + docs vs code · adversarial invariant campaign.
   - Rounds 2 and 3 were targeted hunts proposed by a completeness critic: upstream router fixes after the pin, feed-lag vs the settlement bound, a mutation sweep of `src/`, a cross-index/factory campaign, zap gas at scale on a fork, the wstETH lever end to end, a mutation sweep of scripts, and git-history regression archaeology.
4. **Deduplication**, then **independent verification** of every finding. Medium and above got two verifiers: one reproduced it with their *own* PoC, and one skeptic tried to refute it. Lower findings got one combined verifier. Verifier corrections are folded into the text below.
5. **Tools used:** Foundry unit/fuzz/invariant tests, mainnet forks (real Universal Router 2.0.0, V4 PoolManager, Chainlink proxies, and the WETH9, wstETH, WBTC, wSOL, LINK, UNI, AAVE, USDC and USDT implementations), a bit-exact Python port of `IndexRule` checked against exact rational references, mutation testing, `cast` on-chain checks, and upstream source diffs (universal-router `3663f6db`, v4-periphery `444c526b`).

**Limitation:** the audit was stopped early at the user's request partway through round 3. Two round-3 hunters (Medusa coverage-guided fuzzing and Halmos symbolic checks of the zap and settlement) were cut off before they reported. Round-3 findings were not independently verified; they are marked **(unverified)** below.

### Severity definitions

| Severity | Meaning |
|---|---|
| Critical | Direct theft, unbacked minting or permanent loss of user funds, exploitable by an unprivileged attacker |
| High | Loss or freezing of funds, or value extraction from holders, under realistic conditions |
| Medium | Conditional value leak; manipulation of the rule or rebalance by an unprivileged actor; DoS of a core function; bypass of a documented safety control |
| Low | Minor edge-case leak; low-impact griefing; privileged misuse beyond the documented trust model |
| Info | Doc/code mismatches, test gaps, hardening |

---

## 3. Findings summary

| ID | Title | Severity | Status |
|---|---|---|---|
| M-01 | wstETH market cap read from live `totalSupply()` is flash-manipulable inside the permissionless `startRebalance` | **Medium** | Confirmed (2/2 verifiers, both reproduced) |
| L-01 | VR-01 fix incomplete: near-tied leaders above 20% still swap 10pp on a 1-wei / 1bp move | Low | Confirmed |
| L-02 | A stray router balance makes zap burns revert with `Panic(0x11)`; anyone can grief public burns for gas | Low | Confirmed (unit + real-router fork) |
| L-03 | DA-18 `MAX_SUPPLY_CHANGE` bound skipped whenever either side is 0 ("use totalSupply") | Low | Confirmed |
| L-04 | `checkWbtcFeed` accepts a lookalike or proxy `CompositeFeed`; its controller then prices WBTC | Low | Confirmed |
| L-05 | wSOL has no peg leg: a Wormhole depeg is priced at par, and settlements accept worthless wSOL | Low | Confirmed (verifier raised from Info) |
| L-06 | DA-05's "15% worst case" executor take is exceeded at market prices (16–21% measured) | Low | Confirmed (archive-fork replay) |
| L-07 | R07's on-chain rule that WETH carry a reference supply was deleted; `test_R07` kept its id with the assertion gutted | Low | **Unverified** (round 3) |
| L-08 | Nothing checks which feed and staleness each default whitelist entry uses | Low | **Unverified** (round 3) |
| I-xx | ~40 informational items (Section 5) | Info | Confirmed |

---

## 4. Detailed findings

### M-01 — wstETH's market cap is read from its live `totalSupply()`, which any stranger can move for free inside the permissionless `startRebalance`

**Severity:** Medium · **Status:** Confirmed by both verifiers (independent fork reproduction, and a skeptic who failed to refute it) · **Relation to earlier findings:** DA-10's fix is incomplete; the rationale behind retiring XA-02 is factually wrong.

**Locations:** `script/MainnetAddresses.sol:77-81` (`WSTETH_SUPPLY = 0`), `script/ConfigureWhitelist.s.sol:121-126`, `src/IndexRule.sol:255-257` (`_supply`), `src/IndexRule.sol:302-318` (`_snapshotMarket`), `src/IndexToken.sol:231-258` (`startRebalance`). Contradicted docs: `ARCHITECTURE.md:357`, `ARCHITECTURE.md:528-545`, `README.md:399`, and the policy "fixed-supply or governance-minted supply" (`IndexFactory.sol:35`, `README.md:312`, `AGENTS.md:238`).

**Description.** When a token's config has `referenceSupply == 0`, `IndexRule._supply` returns `IERC20(token).totalSupply()`, read live inside the snapshot. The shipped default list gives wstETH exactly that. wstETH's supply is neither fixed nor governance-minted: `unwrap()` burns wstETH and `wrap()` mints it, both deterministically and at a round-trip cost of 1–2 wei. `stEthPerToken` does not change, and the Chainlink wstETH/USD answer is pushed by the DON, so **only the supply moves**. DA-10 removed exclusion lists for exactly this class of problem (a market cap that can be manipulated within one transaction) but left this path open.

Zero-fee wstETH liquidity on mainnet at the audit block:

| Source | wstETH | Fee |
|---|---|---|
| SparkLend (flash-loan bit set, `FLASHLOAN_PREMIUM_TOTAL = 0`) | ~1,108,500 | 0 |
| Morpho Blue | ~210,070 | 0 |
| Aave v3 | ~814,000 | 5 bps |
| **Total supply** | **3,724,193** | |

**Attack.** Flash-borrow from Spark and Morpho (−35.4% of supply, free), `unwrap`, call `startRebalance(0)` on *every* index holding wstETH, `wrap`, repay. Supply is restored to within 10 wei, at a net cost of about 2 wei plus gas.

**Measured on a mainnet fork, with the shipped configs and real feeds:**

| Index ($10M NAV) | Honest turnover | Forced turnover | wstETH target | Holder loss to a lone executor at m = 0.9 |
|---|---|---|---|---|
| Uncapped `[wstETH, LINK, UNI, AAVE]` | ~1e-18 (start reverts `TurnoverTooLow`) | **10.12%** | −24.2% | **$101,236 (1.01% of NAV)**; executor nets ~$89–91k after real V3 swaps |
| Capped launch-7 (WBTC, WETH, wstETH, wSOL, UNI, LINK, AAVE) | 5.5e-7 | **3.04%** | −24% | **$30,367 (0.30% of NAV)**; executor nets ~$29k |
| WETH-heavy (wstETH ≈ 3.4%) | — | 1.20% (still > 0.5% `MIN_TURNOVER`) | 0.654× rule | — |

The next honest rebalance has to undo the distortion, which costs about as much again (the uncapped case needed 9.8% turnover and cost ~97 bps).

**Further consequences (round 3, same root cause):**
- **Suppression.** Holding an unwrap sized to offset genuine drift drives the measured turnover under `MIN_TURNOVER`, so a rebalance that is due cannot start. That includes the owner's and guardian's documented restart recourse.
- **Systemic reach.** One flash loan poisons every wstETH-holding index in the same transaction.

**Verifier corrections (adopted).**
- The attacker has no timing advantage at the fill: `RebalanceStarted` is public and the auction opens only after the 2-day notice. The 10% capture therefore needs an uncontested auction, the same condition as the already-accepted lone-executor limitation. With competing executors, holders still pay swap costs and tracking error on turnover that should never have happened (~$12k per forced cycle on the $10M uncapped index, plus the same again on the undo).
- A guardian who recomputes targets at a later block with current supplies *would* see the gap. But the guardian can only cancel, and the stranger re-forces after every `REBALANCE_DELAY` until the owner's 2-day config fix lands. With a vigilant guardian the harm is repeated griefing, plus exit pressure on holders during each notice period.

**Recommendation.**
1. List wstETH with a timelocked `referenceSupply` (e.g. ≈3.724e24 raw units, dated) and refresh it with `proposeConfig`. `_checkSupplyChange` already permits the 0 → reference switch.
2. Better: remove the live-`totalSupply` path (refuse `referenceSupply == 0` in `checkConfig` or the factory). No supply read live inside a transaction can be defended against this.
3. At minimum, enforce in `ConfigureWhitelist._followsPolicy` that any token whose supply can be minted or burned permissionlessly carries a reference supply. That covers wrappers, LSTs/LRTs, ERC-4626 shares, WETH-style deposit tokens, bridged tokens, flash-mintable tokens and Xindex indexes. Add a regression test that does unwrap → `startRebalance` → wrap.
4. Correct ARCHITECTURE.md §4–5 and README.md:399, and extend the guardian runbook to recompute targets with current supplies after every `RebalanceStarted`.

**PoCs:** `pocs/r1-oracle-supply__WstethSupplyFlash.t.sol` (3 pass), independent reproduction `pocs/verify-r1-v0-reproduce.t.sol` (5 pass), `pocs/r1-rebalance-state__WstethSupplyFlashSnapshot.t.sol` (guardian can only cancel; the stranger repeats), `pocs/r1-economics__WstethSupplyFlash.t.sol` (forced undo and multi-index), `pocs/r3-wsteth-lever-endtoend-escala__Suppression.t.sol`, `pocs/r3-wsteth-lever-endtoend-escala__LeverEndToEnd.t.sol`.

---

### L-01 — VR-01 fix incomplete: near-tied leaders whose weights sit above 20% still swap 10 percentage points on a 1-wei / 1bp move

**Locations:** `src/IndexRule.sol:356`, `:370`, `:388-395`; `ARCHITECTURE.md:533-537`; `README.md:474-478`. **Earlier finding:** VR-01 (fix incomplete).

**Description.** `_cappedWeights` gives the 30% ceiling to `_top(caps)` (ties go to the lower position) and 20% to every other component. When the two leaders' effective weights are both above 20%, the rank-2 leader is pinned at 0.2 and the rank-1 leader rises to 0.3. Reordering them therefore swaps the full step. `weightsFromCaps([400,400,60,50,40], CAPPED)` returns `[0.30, 0.20, …]`; add 1 wei to the second cap and it returns `[0.20, 0.30, …]`. End to end, an on-methodology capped index moves from turnover < `MIN_TURNOVER` to **10.0% turnover after a +1bp price move**, and any address can start it.

The verifier found this is not limited to top-heavy baskets. It happens whenever c > S/3 (five components with caps c, c and a remainder S): 10:10:5:5:5 swaps the full 10pp, and 25:25:20:15:15 swaps 7.27pp. The docs' claims "nothing at a tie" and "takes a doubling" are false in this regime.

**Impact.** Whoever starts a rebalance chooses which leader gets 30% by picking the published round. Each flip turns over ~10% of NAV for no real change (up to ~1% of NAV to an uncontested executor, plus swap costs). This is latent today: no 5–7-token capped subset of the current whitelist has leaders closer than 4.9×.

**Recommendation.** Make the top ceiling continuous in c1/c2, for example by interpolating it from 20% to 30% as c1/c2 goes from 1 to 1+d. Alternatively, add hysteresis in favour of the incumbent leader. Correct the docs, and add a near-tie test on a top-heavy basket. **PoCs:** `pocs/r1-rule-math__CappedTieFlip.t.sol`, `pocs/verify-r1-v1-combined.t.sol`.

---

### L-02 — A stray router balance of a burn hop's input token makes the whole zap burn revert with `Panic(0x11)`

**Locations:** `src/IndexZap.sol:316` (`_v3Hop`) and `:346` (`_sellV4`); the contradicted design note is at `src/IndexZap.sol:41-45`. **Earlier findings:** FR01/I03 (their re-targeted tests cover stray ether only).

**Description.** Both functions compute `Math.saturatingSub(given, inBefore - token.balanceOf(address(this)))`. Only the outer subtraction saturates; the inner one is checked. The appended `SWEEP` returns the router's *entire* balance of the token, including a stray X it held before the call. So `after = inBefore − spent + X`, and when **X > spent** the inner subtraction underflows and the burn reverts. The contract's own NatSpec promises the opposite ("a refund to the caller and never a shortfall, hence the saturating arithmetic"). That promise holds only on the mint side (`:189`).

**Exploit (real Universal Router 2.0.0 on a fork).**
1. Alice broadcasts `burnToToken`.
2. A griefer front-runs by sending 1 WETH to the router. That is more than the ~0.031 WETH the WBTC leg's second hop sells.
3. Alice's burn reverts with `Panic(0x11)`.
4. The griefer back-runs with `SWEEP` (it is permissionless) and recovers the full 1 WETH.

The same works on V4 legs and on intermediate hops. The cost is gas only, and it can be repeated on every retry.

**Impact.** Any publicly broadcast zap burn can be griefed. No funds are lost. Holders can exit through `redeem`/`redeemSkipping` or a private relay. Mints are unaffected.

**Recommendation.** Measure what came back rather than what was spent:
`_returnUnsold(p, hopIn, token.balanceOf(address(this)) + given - inBefore)` and the equivalent at `:346`. A sweep only adds to the balance, so this cannot underflow. Add ERC-20 stray-balance burn tests (V3 component hop, V3 intermediate hop, V4 leg; stray below and above the spend). **PoCs:** `pocs/r1-zap-mint__StrayRouterBalanceBlocksBurn.t.sol` (6/6), `pocs/r1-zap-mint__StrayRouterBalanceBlocksBurn.fork.t.sol` (3/3 on the real router), `pocs/verify-r1-v2-combined.t.sol`.

---

### L-03 — DA-18's `MAX_SUPPLY_CHANGE` bound is skipped whenever either side is 0

**Locations:** `src/IndexFactory.sol:199-206`, `:212`; `src/IndexRule.sol:255-257`; `script/ConfigureWhitelist.s.sol:231-242`, `:422-424`. **Earlier finding:** DA-18 (fix incomplete).

**Description.** `_checkSupplyChange` returns early when `inForce == 0 || proposed == 0` ("a change of kind, not of size"). But a reference supply of 0 means the rule reads the live `totalSupply()`, so the bound applies to the stored field, not to the supply the rule actually uses. This allows:
- **R → 0** in one step. On today's mainnet floats that moves the effective supply 173× for WBTC, 1,886× for wSOL and 58.6× for WETH.
- **0 → R′** in one step, to any figure.
- **R → 0 → any value** in 4 days. The documented bound implies about 16 steps (32+ days) for the same move on WBTC.

The likeliest trigger is an operator mistake. `ConfigureWhitelist.parseEntry` turns a missing 4th field (`token:feed:88200`) into `referenceSupply = 0`, the factory accepts it, and the script logs nothing about the supply.

**Impact.** Owner-only, so Low. The owner can already repoint `feed` without bound; `MAX_SUPPLY_CHANGE` exists to catch operator slips, and those are exactly what gets past it. Example: WBTC's weight in an equal-value uncapped index falls from ~81% to ~2.5%, and half of its WBTC is auctioned every month until someone notices.

**Recommendation.** Compare *effective* supplies (`referenceSupply != 0 ? referenceSupply : totalSupply()`) whenever a config is in force. Make the 4th script field mandatory and log the effective supply. **PoCs:** `pocs/r1-factory-governance__SupplyBoundBypass.t.sol` (5/5), `pocs/r1-docs-regression__DA18SupplyBoundBypass.t.sol`, `pocs/verify-r1-v3-combined.t.sol`.

---

### L-04 — `checkWbtcFeed` only reads four getters, so a lookalike or proxy `CompositeFeed` passes and its controller then prices WBTC

**Locations:** `script/ConfigureWhitelist.s.sol:159-173`, `:215-219`; `README.md:588-589`; `ARCHITECTURE.md:219-220`.

**Description.** The check is documented as reverting "unless `feed` is a `CompositeFeed` over exactly BTC/USD and WBTC/BTC". It only calls `FEED_A()`, `FEED_B()`, `MAX_AGE_A()` and `MAX_AGE_B()`. The verifier built an upgradeable proxy whose first implementation is a genuine `CompositeFeed`. It matches every getter, `description()`, `decimals()` and `latestRoundData()`; only its codehash differs. It passes the check, gets proposed and executed, and then its controller sets WBTC's price for every index. The settlement ratio does **not** bound this (verifier correction), because both sides are valued with the same hostile feed. Only the target clip and the guardian bound it.

**Impact.** It needs the operator to be handed a malicious address (phishing, copy-paste), and the guardian can veto during the 2-day notice. Hence Low.

**Recommendation.** Require `feed.codehash` to equal the codehash of `new CompositeFeed(BTC_USD, WBTC_BTC, 5400, 88200)`, simulated in the script, and log and check that codehash in `Deploy`. **PoCs:** `pocs/r1-scripts-ops__LookalikeWbtcFeed.t.sol`, `pocs/verify-r1-v5-combined.t.sol`.

---

### L-05 — wSOL has no peg leg: a Wormhole depeg is priced at par with SOL, and settlements accept worthless wSOL

**Locations:** `script/ConfigureWhitelist.s.sol:133-138`, `script/MainnetAddresses.sol:41-57`.

**Description.** WBTC gets a `CompositeFeed` precisely so that a depeg of the wrapper is priced. wSOL is priced from SOL/USD alone, and no wSOL/SOL feed exists on Ethereum. Fork PoC with the default capped 7-token index: after a hypothetical depeg, an executor filling at the 1.5 opening multiplier delivers unbacked wSOL that the rule values at $95,999. In exchange it takes $63,999 of real WETH, wstETH, WBTC, LINK, UNI and AAVE. `_checkSettlementValue` passes, and `navPerToken` *rises*.

The verifier corrected two points. The bound is 2.5× units, not 2×. And a depeg during a live auction leaves the guardian no reaction time. Separately, Chainlink classifies wstETH/USD "Calculated" as a *custom* feed, which is the reason the README gives for excluding weETH and mETH.

**Recommendation.** Document that wSOL is priced at par, and add a runbook entry for a Wormhole incident (keep mask or cancel, then delist). Record each feed's Chainlink category and fail the fork test if it changes. Reconsider wSOL's place in the default list. **PoC:** `pocs/verify-r1-v18-combined.t.sol`.

---

### L-06 — DA-05's "15% worst case" executor take is exceeded at market prices

**Locations:** `src/IndexToken.sol:58-60`, `:438-447`; `src/IndexRule.sol:117-134`; `README.md:409-423`; `ARCHITECTURE.md:411-417`, `:459-463`, `:546-551`. **Earlier finding:** DA-05 (its rationale is factually wrong).

**Description.** The settlement gate checks `inValue ≥ 0.85·outValue` at the Chainlink answers in force when the fill settles. At market prices a lone executor can keep up to `1 − 0.85·G`, where G is the ratio of feed-to-market on the bought legs to feed-to-market on the sold legs. The docs claim the deviation thresholds bound how far an answer can sit from the market. The finder measured 26 months of answers against Binance and Coinbase 1-minute closes and found that false. wstETH/USD was more than 0.5% off in ~20% of minutes, SOL more than 2% off in 1,906 minutes, and UNI/LINK/AAVE reached 14–24% during crashes.

Replays on an archive fork with the default capped basket, a stranger's start, and m = 0.9:

| Date | Gate sees | Market take (independent verifier, Coinbase closes) |
|---|---|---|
| 2026-02-01 | 14.73% (passes) | 16.60% |
| 2025-10-10 crash | 14.12% (passes) | ~17.0% |

In a history sweep, the take exceeds 15% in ~4% of auctions (max ~21%), and on two-leg rebalances up to ~24%. The verifier noted that the excess comes from 1–2 minutes of on-chain latency during fast moves, not from long lags.

**Impact.** Holders can lose a few points more than the documented 15% of traded value to an uncontested executor. That is a fraction of a percent of NAV per rebalance.

**Recommendation.** State the bound as 15% at feed prices plus 0.85 × the feed-to-market gap. Alternatively, raise `MIN_SETTLEMENT_RATIO` to about 0.87–0.88: on this data that caused no gate-induced expiries for competitive executors, and it cut above-15% auctions from ~4.3% to ~0.04%. **PoCs:** `pocs/feed-lag__FeedLagSettlementBound.t.sol` (2 pass), `pocs/verify-r2-v0-combined.t.sol`.

---

### L-07 (unverified) — R07's on-chain guard that WETH carry a reference supply was deleted, and `test_R07` kept its id with the assertion gutted

**Locations:** `src/IndexRule.sol:98` (`checkConfig`), `src/IndexFactory.sol:199`, `test/Security.t.sol:773`, `audit/2026-09-22-v3-retirement.md:63`.

**Description.** At `85a3443`, `IndexRule.checkConfig` reverted `InvalidSupplyConfig` when WETH had `referenceSupply == 0`. Commit `640e57a` deleted that check. It also re-pointed `test_R07_wrappedAssetsCarryAReferenceSupply`'s first assertion at an unrelated `InvalidFeed` case, and R07 is absent from the retirement ledger ("unaffected"). WETH on its float is manipulable within one transaction through `deposit`/`withdraw`, the same way wstETH is in M-01. Only a script-level default-list test remains. The PoC lists WETH on its float and shows its weight falling from 30% to 11.74% after one config change. **Recommendation:** restore a factory- or rule-level guard for known wrapped assets (or adopt M-01 recommendation 2), and fix the ledger and the test. **PoC:** `pocs/r3-git-history-regression-archa__R07WethSupplyGuardLost.t.sol` (2/2, reporter's run only).

### L-08 (unverified) — Nothing checks which feed and staleness bound each default whitelist entry uses

**Locations:** `script/ConfigureWhitelist.s.sol:113`, `test/fork/MainnetAddresses.fork.t.sol:77`, `:145`.

**Description.** The docs cite "a fork test pinning each shipped feed" as part of the whole defence against a wrong feed. That test ties each `MainnetAddresses` *constant* to its `description()`. No test checks which constant each `defaultMainnetList` entry uses. The PoC swaps LINK's feed for UNI's in the list: all 362 offline and 25 fork tests still pass, and LINK is priced at UNI's answer. **Recommendation:** add a fork test keyed by token address that asserts each entry's feed `description()` and `maxStaleness` against an independently written table. **PoCs:** `pocs/r3-git-history-regression-archa__DefaultListPairing.t.sol`, `pocs/r3-mutation-sweep-scripts-and-l__DefaultListPairing.fork.t.sol`.

---

## 5. Informational findings

All of these were confirmed by a verifier unless marked otherwise.

### 5.1 Code-level observations

| ID | Location | Observation | Suggestion |
|---|---|---|---|
| I-01 | `IndexToken.sol:48` | ERC-20 `transfer` of shares to the index itself is accepted and locks those shares and their backing forever, contrary to the documented "recipient can never be the index". | Override `_update` to reject `to == address(this)`. |
| I-02 | `IndexToken.sol:235` | After an unfilled auction, the owner/guardian-only restart window is `REBALANCE_DELAY − 1` seconds, not `REBALANCE_DELAY`. | Anchor at the first expired second, or document it. |
| I-03 | `IndexToken.sol:418-425` | A component held at 1 raw unit can settle at 3× (not 2.5×), because the growth rounds up. | Document "2.5× plus one raw unit". |
| I-04 | `IndexRule.sol:449-462` | `_fill`'s saturating subtraction and `_share`'s `below >= above` tie are reachable at value scale 1, contrary to the NatSpec and VR-06. The `saturatingSub` mutant survives all tests. | Keep `saturatingSub`; fix the NatSpec; add the vectors as tests. |
| I-05 | `UniswapV4Types.sol:61-64` | `OPEN_DELTA` (0) is also a sentinel in the swap-amount position. The zap avoids it only through an unstated `units ≥ 1` invariant. | Assert `need[i] != 0` in `_buy`, or document it. |
| I-06 | `IndexZap.sol:155` | The pinned v4-periphery does not enforce `amountInMaximum` on V4 exact-output routes that revisit `tokenIn` (upstream #564). The zap's pre-fund contains it (fork PoC). | Document that the pre-fund is the real bound. |
| I-07 | `IndexZap.sol:46-49` | V4 routes that revisit the component can partially fill a later hop without reverting (the outcome is safe; the docs say it always reverts). | Qualify the wording. |
| I-08 | `IndexZap.sol:247-270` | At `MAX_COMPONENTS`, zap exits stay under EIP-7825's per-tx gas cap only while routes stay within ~8 hops per leg. Nothing documents or enforces this. | Publish measured gas; bound hops or components in the app. |
| I-09 | `IndexFactory.sol:241-270` | `executeListing` is permissionless, so whoever executes first (or fills first) chooses whether an old or a new reviewed config prices a snapshot or settlement. | Document it in §5 and the runbook. |
| I-10 | `IIndexRule.sol:24-25` | `InvalidFeed` is promised for a feed that "does not answer as an aggregator"; the code gives an empty revert. | Add a try/catch in `checkConfig`, or narrow the NatSpec. |

### 5.2 Documentation vs code mismatches

- **I-11:** Docs and NatSpec call settlement "oracle-free", but `executeRebalance` reads every moving leg's feed (DA-05), so a stale feed blocks settlement (`IndexToken.sol:45-47`).
- **I-12:** ARCHITECTURE §2 and README step 4 still say every `cancelRebalance` starts a fresh `REBALANCE_DELAY` cooldown (stale since VR-04). The "In order" settlement list omits the bound and value checks.
- **I-13:** Stale NatSpec and AGENTS text say a kept capped component gets an "unchecked / plain price" (`IndexRule.sol:39-40`).
- **I-14:** The zap docs call pre-fund/sweep atomic because "a sweep that came up short would fail the swap", but the sweep minimum is always 0 (`IndexZap.sol:30`).
- **I-15:** `IIndexZap`/README omissions: the `to` NatSpec omits the PoolManager; `InsufficientBudget`'s leg-cap trigger is undocumented; the README error lists miss `SettlementValueTooLow` and `SupplyChangeTooLarge`.
- **I-16:** Getter NatSpec still describes the DA-16 trap (`listingEta`/`pendingGuardianEta` documented as "0 when none is pending").
- **I-17:** The wstETH/USD "Calculated" feed behaves like a ~1% deviation feed driven by STETH/USD; the docs call it 0.5%.
- **I-18:** ARCHITECTURE's "5% of auctions expire" figure is not borne out on the shipped baskets.
- **I-19:** Router provenance statements are inaccurate: 2.1.x does not in general carry #491/#497, and `0x66a9…` was not compiled against `444c526b`.
- **I-20:** "IndexToken is byte-identical across the change" is false for the tree it describes *(round 3, unverified)*.
- **I-21:** The retirement ledger and AGENTS.md rows misdescribe what `640e57a`/`f94c2a4` removed *(round 3, unverified)*.

### 5.3 Test-suite gaps: safety checks no test pins

A mutation sweep of `src/` showed that each of these checks can be deleted or altered while all 362 offline and 25 fork tests still pass:

- **I-22:** XA-24's reference-supply range assertion was removed from the fork test that still carries its id, so a decimals slip in a shipped supply passes.
- **I-23:** The XA-30 PoolManager-recipient rejection has no test.
- **I-24:** DA-08's `min(sold, bought)` turnover gate is unpinned.
- **I-25:** The DA-22 `canStartRebalance` initialization check is unpinned (the test runs at a timestamp where the check is irrelevant).
- **I-26:** The zap's `nonReentrant` guards (mint, burn, burn-with-permit) are unpinned.
- **I-27:** The return of a V4 burn leg's unsold input is unpinned. Deleting it strands user tokens in the zap.
- **I-28:** The DA-05 floor (the `0.85e18` constant, its rounding, the rule's valuation rounding) is unpinned.
- **I-29:** `MAX_SUPPLY_CHANGE` is unpinned (9 or 11 passes).
- **I-30:** Two `_checkBacking` terms (backing, and the re-check of sold legs) are unpinned.
- **I-31:** Zap pass-through and budget boundaries are unpinned.
- **I-32:** `IndexRule` rounding directions beyond the scale-1 path are unpinned, and so is the feed-decimals half of the 18-decimal cap.
- **I-33:** Smaller `IndexToken` controls are unpinned (bounded-settlement clone safety, EIP-2612 domain, zero-amount skips, the exact `MIN_TURNOVER` boundary), as are view and event boundaries.
- **I-34:** `CompositeFeed` has the weakest mutation kill rate (75.6%): the older-leg timestamp, leg-age boundaries and product rounding are unpinned.
- **I-35:** The router-build pin is not tested. The XA-13 fork check passes for every Universal Router build on mainnet, 2.1.x included. Pin `UNIVERSAL_ROUTER.codehash` and `POOL_MANAGER.codehash`.
- **I-36 (unverified, round 3):** Offline router-encoding checks are circular for V3 command bytes and V4 parameter layouts. `Deploy.deploy()` never proves it runs `checkOwner`/`checkGuardian`. The XA-07 Safe module page start is unpinned. Several `ConfigureWhitelist` policy branches are unpinned. VR-03's second regression test no longer catches its bug after merge `8fab3ba`.

The finders wrote ready-made kill-tests for most of these; see `pocs/r2-mutation-sweep-src__*` and `pocs/r3-mutation-sweep-scripts-and-l__*`.

### 5.4 Operations and scripts

- **I-37:** The XA-39 fix was narrowed to the Universal Router only. The PoolManager, WETH, USDC, the Chainlink feeds and the tokens all pass as the mainnet `OWNER`/`GUARDIAN` (`Deploy.s.sol:131-146`).
- **I-38:** `ConfigureWhitelist` does not pre-check `MAX_SUPPLY_CHANGE`, so an out-of-bound entry fails a whole Safe batch. `execute` also aborts on the first failing entry.
- **I-39:** The default list gives wSOL the full 20% cap in a capped index, while Ethereum holds only ~$1M of Uniswap depth and a $36.7M float for it.
- **I-40:** `.gitignore` excludes chain-1 fork rehearsals but not Sepolia-fork ones, and the committed Sepolia history includes an aborted run.
- **I-41:** The Sepolia test market's feeds assume ETH = $3,000 while its pools are priced at 2,400 tUSDC.

---

## 6. Areas examined and found clean

These were checked by the listed method and turned up no issue beyond those above.

- **Backing invariant and share accounting** (`issue`, `redeem`, `redeemSkipping`, `claim`, settlement). Four rounding inequalities cover every path. Stateful fuzzing with quirky tokens (no-bool, false-returning, zero-transfer-reverting, balance-changing; 6/8/9/18 decimals; 1 raw unit to near-uint96 units) found no unbacked mint, no over-redemption, and no gain from a flash issue or redeem around a fill.
- **Rebalance state machine.** Every timing boundary was tested: there is no timestamp at which a start and a fill are both possible. The hold-offs after cancel and after expiry, the nonce and `lastRebalance` updates, SafeCast widths and parity-multiplier behaviour all check out. An adversarial executor re-entering every guarded function fails with `ReentrancyGuardReentrantCall`. Short fills never settle; over-delivery and donations stay with holders.
- **Rule mathematics.** A bit-exact Python port agreed with the contract on 20,000 on-chain vectors. That port was then run against exact rational water-filling and capped-weight references over 1.7M+ fuzz runs (n = 1–20, prices 1…1e56 around the `MAX_EXACT_PRICE` switch, units 1…2⁹⁶−1). Targets stayed within bounds, the target basket was never worth less than the current one beyond the documented wei tolerance, there were no panics or non-termination on reachable inputs, and turnover was correct.
- **Oracle path.** Decimals scaling, positivity, staleness and future-timestamp handling, the `MAX_PRICE` bound, and `CompositeFeed` scale agreement and per-leg staleness are all correct.
- **Universal Router encoding.** Every command id, action id, input layout, struct field order and `OPEN_DELTA` use was checked byte for byte against universal-router `3663f6db` and v4-periphery `444c526b`, and against a real-router call trace on the fork. Upstream fixes after the pin were diffed; none reachable through the zap's command subset causes loss.
- **Zap accounting.** Refund, reserved, budget and cap arithmetic on mint; `ShortFill`; the nonce re-check before `issue`; permit front-running; V4 partial fills (they fill partially rather than revert, and unsold input is returned); intermediate tokens equal to components or to `tokenOut`. The full 7-token default basket mints with USDC/USDT and burns back on a fork, leaving 0 of every component in the zap.
- **Factory governance.** `createIndex` validation, the CREATE2 salt (no squatting or front-running), whitelist array bookkeeping, listing, config and delist flows, DA-11 re-validation, guardian propose/cancel/execute rules, Ownable2Step, and `renounceOwnership` disabled. A cross-index and factory invariant campaign that predicts every outcome saw 0 unexpected reverts.
- **Real mainnet tokens.** WETH9, wstETH, WBTC (including a pause), Wormhole wSOL (BeaconProxy), LINK (ERC-677), UNI (uint96 balances), AAVE (AaveTokenV3 proxy), USDC and USDT all behave correctly through issue, redeem, skip/claim and the zap.
- **Mainnet address book.** All 9 tokens (symbol, decimals), all 8 feeds (description, decimals, aggregator, heartbeat, deviation) and the canonical Wormhole wSOL all match their stated values.
- **Earlier fixes.** Every fix-claiming XA, LR, DA and VR id was checked in the current code. Most were confirmed present and pinned by mutation (killed mutants). The exceptions are listed above as L-01, L-03, L-06, L-07 and I-22 to I-36.

---

## 7. PoC index

Every PoC is in `audit-work/pocs/` (127 files). To run one, copy it into a workspace's `test/audit/` directory. Then run `forge test --match-path test/audit/<File>.t.sol -vv`. For fork PoCs, prefix the command with `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com`. If the pinned block is unavailable, also set `FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 ))`. Some PoCs import helpers such as `QuirkyToken.sol` or `AdvExecutor.sol`; put those in the same `test/audit/` directory.

| Finding | Primary PoC | Independent verification |
|---|---|---|
| M-01 | `r1-oracle-supply__WstethSupplyFlash.t.sol` | `verify-r1-v0-reproduce.t.sol`, `r1-v0-skeptic__WstethSupplyVerify.t.sol` |
| L-01 | `r1-rule-math__CappedTieFlip.t.sol` | `verify-r1-v1-combined.t.sol` |
| L-02 | `r1-zap-mint__StrayRouterBalanceBlocksBurn{,.fork}.t.sol` | `verify-r1-v2-combined.t.sol` |
| L-03 | `r1-factory-governance__SupplyBoundBypass.t.sol` | `verify-r1-v3-combined.t.sol` |
| L-04 | `r1-scripts-ops__LookalikeWbtcFeed.t.sol` | `verify-r1-v5-combined.t.sol` |
| L-05 | — | `verify-r1-v18-combined.t.sol` |
| L-06 | `feed-lag__FeedLagSettlementBound.t.sol` | `verify-r2-v0-combined.t.sol` |
| L-07 | `r3-git-history-regression-archa__R07WethSupplyGuardLost.t.sol` | — (unverified) |
| L-08 | `r3-git-history-regression-archa__DefaultListPairing.t.sol` | — (unverified) |

The raw data behind this report is in `audit-work/audit-results.json`: every finding, every verifier verdict with its reasoning, and every sub-auditor's coverage notes.

---

*This audit is a point-in-time review of commit `855e41b`. It does not guarantee the absence of other defects. Two planned round-3 analyses (Medusa fuzzing and Halmos symbolic execution of the zap and settlement) did not complete, and round-3 findings were not independently verified.*
