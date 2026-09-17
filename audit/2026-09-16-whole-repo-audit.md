# Xindex v2: whole-repo audit

- **Scope:** `whole-repo`
- **Commit audited:** `4121049d32e3653387b0f0b596dcadc7b45a5da7` (branch `v2-onchain-rebalancing`)
- **Completed:** 2026-09-16T19:10:36Z
- **Method:** rainlanguage `audit` skill v0.35.0 (`rainlanguage/claude-audit-skills@9fefd09902d777aabc967ef6625d038e6c2101b7`), run as a Workflow fan-out: 17 reviewers, dedup, a second fresh-eyes round, adversarial verification (51 agents)
- **Dimensions run:** 0 Process, 1 Security, 3 Documentation, 4 Code quality, 5 Correctness/intent, 6 Hazard surface

## Dimension 2 (test coverage) did not run

The skill runs dimension 2 only after a recorded mutation-testing campaign.

1. **Check that failed:** file missing.
2. **Path checked:** `audit/mutation-test-scans.json`.
3. **What produces it:** an `adversarial-mutation-test` campaign.
4. **Why it matters:** that campaign proves each gap with a surviving mutant and writes the discriminating test. It covers about 90% of what this dimension would otherwise file as manual issues. Judging coverage by reading alone produces suspicion, not findings.
5. **Ways forward:** run a campaign and commit its record, or re-run the audit with the literal override `pass2-without-mutation-ledger`.

This is a fact about the run, not a finding. One verifier did run a mutation by hand: replacing `Rounding.Ceil` with `Floor` in `IndexToken._previewRebalance` still passes all 247 offline tests (see the finding on `test_executeRebalance_growingUnitsRoundUp`).

## Rules not applied

These skill rules are conventions of the rainlanguage GitHub org and conflict with this repo's documented conventions in CLAUDE.md, so they were not applied:

- `iFoo`/`sFoo` storage-class naming
- the named-returns convention
- the `^` vs `=` pragma rule
- the `src/{lib,concrete,abstract,interface}` layout
- soldeer/rainix/LibSnapshot release lifecycle
- `@main` workflow refs
- DecentraLicense naming

## Tooling baseline

- `forge build --sizes` (clean tree, Solc 0.8.28): compiler run successful, no warnings, no lint findings.
- `forge test`: 247 passed, 0 failed, 3 fork suites skipped (no RPC).
- Wake `detect all src`: no detections.
- Slither 0.11.5: 109 results. The High/Medium ones are false positives:
  - vendored TickMath arithmetic
  - `eta == 0` sentinels
  - intentionally ignored returns
  - zap balance deltas behind `nonReentrant`

Fork tests were **not** run (no RPC in the audit environment).

## Summary

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 |
| LOW | 20 |
| INFO | 44 |

No CRITICAL or HIGH finding survived verification, so the skill's security-disclosure gate withholds nothing.

| ID | Severity | Dimension | Title | Location | Verification |
|---|---|---|---|---|---|
| XA-01 | MEDIUM | Security | A distorted 30-minute TWAP at the permissionless snapshot moves value out of an index through the auction; ARCHITECTURE says this can only change shape | `src/IndexRule.sol:190-201, 313-337; src/IndexToken.sol 222-248, 327-34` | intent: confirmed -> MEDIUM; impact: partially-confirmed -> MEDIUM; reachability: confirmed -> MEDIUM |
| XA-02 | LOW | Security | A stranger can keep a rebalance from ever clearing by restarting it at a distorted snapshot; the guardian has to step in every cycle | `src/IndexToken.sol:222-237, 256-257, 319-320` | combined: partially-confirmed -> LOW |
| XA-03 | LOW | Security | A config-change proposal pending at delist time re-whitelists the delisted token when anyone executes it | `src/IndexFactory.sol:204-243` | combined: confirmed -> LOW |
| XA-04 | LOW | Security | Capped 30/20 rule lets the third-ranked component outweigh both the 30% top and the 20% second; the default 5-token list gives LINK about 35% | `src/IndexRule.sol:272-296 (and src/libraries/Methodology.sol:11-20)` | combined: confirmed -> LOW |
| XA-05 | LOW | Security | Kept components are still priced and supplied, so a keep mask cannot route a rebalance around a component whose price reverts (ZeroPrice or cap overflow) | `src/IndexRule.sol:129, 182-186, 231-247` | combined: confirmed -> LOW |
| XA-06 | LOW | Security | ConfigureWhitelist execute mode lists whatever config is pending, ignoring the WHITELIST entry it was run with | `script/ConfigureWhitelist.s.sol:180-196, 206-210` | combined: confirmed -> LOW |
| XA-07 | LOW | Security | Mainnet owner check trusts Safe getThreshold only, so a Safe with an enabled module (single-key execution path) passes | `script/Deploy.s.sol:82-96` | combined: confirmed -> LOW |
| XA-08 | LOW | Security | Unsold-part return (I12 fix) covers only the first hop; a partial fill on a later hop of a multi-hop burn leg leaves the user's intermediate tokens in SwapRouter02 | `src/IndexZap.sol:26-30, 271-296` | combined: partially-confirmed -> LOW |
| XA-09 | LOW | Hazard | MIN_OBSERVATION_CARDINALITY = 200 only covers the 30-minute TWAP while slots stay 12 seconds, and nothing ties the two together | `src/IndexRule.sol:29-31, 170-180, 190-202` | combined: partially-confirmed -> LOW |
| XA-10 | LOW | Hazard | CI does not enforce the lint-free, 100%-coverage, Wake-clean or fork-test gates that CLAUDE.md requires | `.github/workflows/test.yml:61-75` | combined: confirmed -> LOW |
| XA-11 | LOW | Hazard | ConfigureWhitelist propose/safe mode re-proposes tokens the guardian delisted, and execute re-whitelists them | `script/ConfigureWhitelist.s.sol:10-13, 200-217` | combined: confirmed -> LOW |
| XA-12 | LOW | Hazard | Only in-repo executor template (test/fork/RebalanceExecutorV3.sol), pointed to by README, lets anyone drain its float | `test/fork/RebalanceExecutorV3.sol:26-29, 35-61; README.md:350-352` | combined: partially-confirmed -> LOW |
| XA-13 | LOW | Hazard | Mainnet deploy/listing inputs are unverified literal copies of the fork-verified ForkAddresses; no fork test runs Deploy or the default whitelist | `script/ConfigureWhitelist.s.sol:52-78 (also script/Deploy.s.sol:27-30,` | combined: partially-confirmed -> LOW |
| XA-14 | LOW | Documentation | startRebalance and previewTarget NatSpec leave out restrictions and reverts | `src/interfaces/IIndexToken.sol:141-157` | not agent-verified (orchestrator spot-check) |
| XA-15 | LOW | Documentation | guardian() NatSpec leaves out the guardian's rebalance powers | `src/interfaces/IIndexFactory.sol:79-81` | not agent-verified (orchestrator spot-check) |
| XA-16 | LOW | Documentation | Frontend 'rebalance due' condition (eta == 0) hides the trigger forever after an unfilled auction | `README.md:138-141` | combined: confirmed -> LOW |
| XA-17 | LOW | Documentation | Docs claim units move at most 'half to double' per rebalance; settlement allows up to 2.5x | `ARCHITECTURE.md:167, 213-214, 226-229, 257-261` | combined: confirmed -> LOW |
| XA-18 | LOW | Documentation | Mainnet `LISTING_MODE=propose` command cannot work because the owner must be a contract | `README.md:273-274` | not agent-verified (orchestrator spot-check) |
| XA-19 | LOW | Code quality | IndexRule divides the TWAP tick delta by a second, independently written 30-minute constant | `src/IndexRule.sol:29,44,192,199-200` | not agent-verified (orchestrator spot-check) |
| XA-20 | LOW | Process | Following README's .env setup makes plain `forge test` run fork tests at an archive-only block | `README.md:258-262` | not agent-verified (orchestrator spot-check) |
| XA-21 | LOW | Process | 'One regression test per finding' claim is false for 8 v1 finding ids, and the finding list is not in the repo | `CLAUDE.md:44-45,59` | not agent-verified (orchestrator spot-check) |
| XA-22 | INFO | Security | Zap mint checks the rebalance nonce before external calls; units can change before issue | `src/IndexZap.sol:127-180, 307-314` | combined: partially-confirmed -> INFO |
| XA-23 | INFO | Security | Overflow in rule products at extreme reachable ticks reverts rebalances | `src/IndexRule.sol:245, 334, 350, 374` | combined: partially-confirmed -> INFO |
| XA-24 | INFO | Security | WHITELIST referenceSupply is parsed as raw units with no unit documentation or sanity bound, so a whole-token entry is silently accepted | `script/ConfigureWhitelist.s.sol:29-31, 114-120` | combined: partially-confirmed -> INFO |
| XA-25 | INFO | Security | Deploy does not reject the broadcasting key as guardian | `script/Deploy.s.sol:98-101` | not agent-verified (orchestrator spot-check) |
| XA-26 | INFO | Security | Test-market seed centres liquidity on the live tick of an empty pool with zero min amounts, so anyone can skew the Sepolia prices between create and seed | `script/testnet/SetupTestMarket.s.sol:283-300` | not agent-verified (orchestrator spot-check) |
| XA-27 | INFO | Security | The parity rule for an empty index is skipped when supply is dust, so the executor picks the multiplier and sets units off the rule's targets | `src/IndexToken.sol:312-350` | combined: partially-confirmed -> INFO |
| XA-28 | INFO | Security | An executor can deliver less than amountsIn and keep the index's surplus (donations, rounding dust) | `src/IndexToken.sol:283-306` | not agent-verified (orchestrator spot-check) |
| XA-29 | INFO | Security | Burn legs for components that redeem to zero are accepted without path validation, and their per-leg minimum is silently ignored | `src/IndexZap.sol:259-267` | not agent-verified (orchestrator spot-check) |
| XA-30 | INFO | Security | Recipient check rejects the zap and the index but not the SwapRouter02, where delivered tokens can be swept by anyone | `src/IndexZap.sol:307-314` | not agent-verified (orchestrator spot-check) |
| XA-31 | INFO | Correctness | WBTC is valued with the whole bitcoin supply while tBTC uses its on-chain float | `script/ConfigureWhitelist.s.sol:48-79` | not agent-verified (orchestrator spot-check) |
| XA-32 | INFO | Correctness | test_R09 says issuing 1e18+1 shares leaves dust, but the 100e18 units round exactly | `test/Security.t.sol:812-824` | not agent-verified (orchestrator spot-check) |
| XA-33 | INFO | Correctness | Windfall control test calls a 250 gap '(fair - start) times the bought value at par', which gives 500 under R04's definition | `test/Security.t.sol:1026-1035` | not agent-verified (orchestrator spot-check) |
| XA-34 | INFO | Correctness | Guardian-around-paused-WBTC fork test uses a bare expectRevert and never checks that WBTC is a shrinking leg | `test/fork/Rebalance.fork.t.sol:217-227` | not agent-verified (orchestrator spot-check) |
| XA-35 | INFO | Correctness | test_executeRebalance_growingUnitsRoundUp uses inputs that can never round, so the Ceil rounding of growing units is not checked by any test | `test/IndexToken.rebalance.t.sol:347-353` | combined: confirmed -> INFO |
| XA-36 | INFO | Correctness | Four revert tests use bare vm.expectRevert(), so they pass on any revert | `test/IndexToken.rebalance.t.sol:387-393` | not agent-verified (orchestrator spot-check) |
| XA-37 | INFO | Correctness | MockUniswapV3Pool does not model a lazily grown oracle ring, so the claim that 200 slots 'can never run out of history' is never tested and is wrong right after growth | `test/mocks/MockUniswapV3.sol:14,58-80` | not agent-verified (orchestrator spot-check) |
| XA-38 | INFO | Hazard | Deployment uses CREATE and freezes no release record (address, codehash, creation and runtime bytecode) | `script/Deploy.s.sol:57-78` | combined: partially-confirmed -> INFO |
| XA-39 | INFO | Hazard | Deploy.checkOwner accepts any mainnet contract without getThreshold, including a market address pasted as OWNER | `script/Deploy.s.sol:82-101` | combined: partially-confirmed -> INFO |
| XA-40 | INFO | Hazard | Whitelist policy checks that the rule could make cheaply (6-18 decimals, no USDC component) are enforced only socially | `src/IndexRule.sol:73-88` | not agent-verified (orchestrator spot-check) |
| XA-41 | INFO | Hazard | Zap params structs and full error/event surface have no interface or generated ABI for the separate web app | `src/IndexZap.sol:43-80, 103-113; README.md:142-177` | combined: partially-confirmed -> INFO |
| XA-42 | INFO | Hazard | Recurring operator duties (execute window, monthly trigger, keep mask, supply refresh) have no runbook, owner, or monitor | `README.md:196-199, 284-291; ARCHITECTURE.md:284-287` | not agent-verified (orchestrator spot-check) |
| XA-43 | INFO | Hazard | Broadcast records from mainnet-fork rehearsals are committed as if real; committed broadcast provenance is not checked against the README | `.gitignore:9-12 (also README.md:286-287, broadcast/SetupTestMarket.s.s` | combined: partially-confirmed -> INFO |
| XA-44 | INFO | Hazard | The web app's error, event and constant lists are hand-copied into the README with no generated ABI; the error list is already incomplete | `README.md:168-177 (also 42, 48, 132, 197, 277; ARCHITECTURE.md:58-65)` | combined: partially-confirmed -> INFO |
| XA-45 | INFO | Hazard | Cross-constant relationships are enforced only by comments (TWAP window copy, cardinality vs window, target cap vs multiplier, keepMask width vs MAX_COMPONENTS) | `src/IndexRule.sol:29-47 (also src/IndexToken.sol:55,244; src/IndexFact` | not agent-verified (orchestrator spot-check) |
| XA-46 | INFO | Hazard | AGENTS.md duplicates CLAUDE.md and Wake remappings duplicate foundry.toml, with no sync check | `AGENTS.md:1-148 (also .vscode/settings.json:2-17, foundry.toml:9-13)` | not agent-verified (orchestrator spot-check) |
| XA-47 | INFO | Hazard | Deploy accepts non-default market addresses on chain 1 without a warning, never checks the router against WETH and the Uniswap factory, and does not log the rule's immutable inputs; swapped WETH/USDC deploys cleanly | `script/Deploy.s.sol:61-78, 104-119` | combined: confirmed -> INFO |
| XA-48 | INFO | Hazard | The 'USDT: plain approve' integration note leaves out USDT's non-zero-to-non-zero approve revert, and the fork tests hide it with forceApprove | `README.md:156-157` | not agent-verified (orchestrator spot-check) |
| XA-49 | INFO | Documentation | IndexZap: immutables, events, errors, most struct fields and function params/returns are undocumented | `src/IndexZap.sol:56-213` | not agent-verified (orchestrator spot-check) |
| XA-50 | INFO | Documentation | Script public entry points, constants and errors are undocumented (Deploy, ConfigureWhitelist, SetupTestMarket, FaucetToken) | `script/Deploy.s.sol:27-57` | not agent-verified (orchestrator spot-check) |
| XA-51 | INFO | Documentation | Minimal Uniswap interfaces and PathLib helpers leave struct fields, pool getters and helpers undocumented | `src/interfaces/ISwapRouter02.sol:9-24` | not agent-verified (orchestrator spot-check) |
| XA-52 | INFO | Documentation | MAX_TARGET_UNITS NatSpec says the rule never returns larger targets, but it does for kept or already-large units | `src/interfaces/IIndexRule.sol:36-37` | not agent-verified (orchestrator spot-check) |
| XA-53 | INFO | Documentation | IIndexFactory: all events, errors and several getters are undocumented, and createIndex/predictIndexAddress lack @param/@return | `src/interfaces/IIndexFactory.sol:20-126` | not agent-verified (orchestrator spot-check) |
| XA-54 | INFO | Documentation | IIndexToken/IndexToken: events, errors, componentCount and nonces are undocumented; most functions lack @param/@return | `src/interfaces/IIndexToken.sol:18-170` | not agent-verified (orchestrator spot-check) |
| XA-55 | INFO | Documentation | IIndexRule: errors, WETH/UNISWAP_V3_FACTORY/USDC getters and return values are undocumented; price() leaves out WETH and unconfigured-token behaviour | `src/interfaces/IIndexRule.sol:15-93` | not agent-verified (orchestrator spot-check) |
| XA-56 | INFO | Documentation | navPerToken described as what a burn returns before swap costs | `ARCHITECTURE.md:193-194` | not agent-verified (orchestrator spot-check) |
| XA-57 | INFO | Documentation | ARCHITECTURE defers zap behaviour to v1 documentation that is not in the repo | `ARCHITECTURE.md:151-153, 244-245, 283` | not agent-verified (orchestrator spot-check) |
| XA-58 | INFO | Documentation | Deploy instructions use --verify, but .env.example has no ETHERSCAN_API_KEY | `.env.example:1-25` | not agent-verified (orchestrator spot-check) |
| XA-59 | INFO | Documentation | Rebalance events reuse the same id across restarts and nothing is emitted when a proposal expires, so event-driven indexers cannot tell attempts apart | `src/IndexToken.sol:226-227, 247, 260, 317-320` | not agent-verified (orchestrator spot-check) |
| XA-60 | INFO | Documentation | proposeGuardian replaces a pending guardian change without emitting a cancellation, so event-built 'pending proposals' views show two pending guardians | `src/IndexFactory.sol:252-257` | not agent-verified (orchestrator spot-check) |
| XA-61 | INFO | Documentation | The guardian check on owner config changes can be removed by the owner in 7 days, and the guardian cannot veto that; the security model presents the check as standing | `ARCHITECTURE.md:257-261 (also src/IndexFactory.sol:252-281, 16-22)` | not agent-verified (orchestrator spot-check) |
| XA-62 | INFO | Code quality | Interfaces declare the same custom errors again, so no contract or interface can inherit both | `src/interfaces/IIndexRule.sol:15-25` | not agent-verified (orchestrator spot-check) |
| XA-63 | INFO | Code quality | Test setup helpers are copied almost verbatim across test files | `test/IndexToken.t.sol:63-69` | not agent-verified (orchestrator spot-check) |
| XA-64 | INFO | Code quality | CI clones unused nested submodules its lock check never verifies, and the pinned Foundry version is not documented | `.github/workflows/test.yml:19-22,50-53` | not agent-verified (orchestrator spot-check) |
| XA-65 | INFO | Code quality | Script helpers and fee-tier constants are duplicated between ConfigureWhitelist and SetupTestMarket, and scripts depend on concrete IndexFactory | `script/ConfigureWhitelist.s.sol:6,41-42,145,162,180,230-232` | not agent-verified (orchestrator spot-check) |

## Findings

### XA-01 [MEDIUM] A distorted 30-minute TWAP at the permissionless snapshot moves value out of an index through the auction; ARCHITECTURE says this can only change shape

- **Dimension:** Security (oracle-manipulation / value-extraction)
- **Location:** `src/IndexRule.sol:190-201, 313-337; src/IndexToken.sol 222-248, 327-349; ARCHITECTURE.md 208-211, 255-263`
- **Reported by:** sec-economic (reported HIGH); also H-2
- **Touches a recorded product decision:** yes
- **Verification:** intent: confirmed -> MEDIUM; impact: partially-confirmed -> MEDIUM; reachability: confirmed -> MEDIUM

**Problem**

How it happens. Anyone can call startRebalance once 28 days have passed (IndexToken.sol:222-237). It fixes the targets from `IIndexRule(RULE).targetUnits` (IndexToken.sol:354). Those targets use `_poolPrice`, a plain arithmetic mean of the tick with no check on liquidity or outliers: `int24 tick = int24(delta / SIGNED_TWAP_WINDOW)` (IndexRule.sol:199). `_redistribute` makes the targets value-neutral at the snapshot prices P', so sum_i (u_i - t_i) * P'_i = 0. Nothing in `_previewRebalance` (IndexToken.sol:327-341) looks at prices again, and the auction always opens at `AUCTION_START_MULTIPLIER = 1.5e18` (IndexToken.sol:55, 348). The fair multiplier at true prices P is m* = sum_sold (u-t)*P / sum_bought (t-u)*P. Suppose only sold legs are misread, by a factor P'/P. Then m* = P/P' exactly, whatever the clipping. Once P'/P <= 2/3 (a mean-tick shift of 4,055 ticks), m* is at least 1.5. The first executor at `eta` then takes (m* - 1.5) * B from the index, where B is the bought value. The same works for a bought leg whose price is read 50% too high.

Cost of the distortion. The mean is arithmetic in ticks, so one outlier dominates it. A single 12-second block at MIN_TICK (or MAX_TICK when the token is token1) inside the 1,800-second window moves the mean by 887,272 * 12 / 1,800 = 5,915 ticks, so P'/P = 1.0001^-5915 = 0.553 and m* = 1.81. The attacker only needs to be the last swap of block N. Uniswap charges the extreme tick for the 12 seconds up to the first touch in block N+1, even if arbitrageurs move the price back first in N+1. startRebalance can then be called at any time in the next 30 minutes, so no consecutive block control is needed. Reaching MIN_TICK costs almost nothing once the swap is past the last initialized liquidity: with sqrtPriceLimit at MIN_SQRT_RATIO+1, a zero-liquidity stretch is crossed for 0 input. The cost is the slippage through the in-range concentrated positions (roughly 10-30% of the in-range WETH for a +/-20% range) plus fees, and arbitrage recaptures that. A full-range position blocks this route: pushing a price down 100x needs about 9x the token reserve per block, so about 13 blocks (roughly 117x the reserve) would be needed. A validator with consecutive slots pays only fees. `_checkPool` (IndexRule.sol:170-180) checks the pool's identity and a cardinality of 200. It never checks depth, and anyone can raise cardinality. The owner can also point a config at the thinnest fee tier of the same pair. That goes through the 2-day listing flow, so the guardian can cancel it unless the owner and guardian collude.

Which baskets are exposed. An uncapped basket that is on target is immune (t_i = k' * S_i). Uncapped baskets that are off target are exposed: creator-chosen units, or supply drift. Depressing an overweight sold leg lowers k' and sells more of it. Capped baskets are exposed when a component in the rest group is more than about twice its within-rest share. Components already clipped at half are still exposed, because clipping bounds B but not m*.

PoC. Test /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/sec-econ-twap/test/poc/TwapExtract.t.sol passes. It uses `setCumulatives(0, -887272*12)` for one block, then restores tick 0 before the auction. All tokens are worth 1 WETH per unit, 10 shares. (1) Uncapped, units (200,100,100,100,100), equal supplies. Honest targets are all 120. The distorted targets are all 112.16. At eta with m=1.5, the executor takes 878.44 and delivers 729.34. The index loses 149.1 WETH of 6,000, which is 2.48% (m* = 1.807). (2) Capped, units (300,200,400,100,100), supplies (30,20,5,5,5). Component 2 is pinned at its half-clip of 200 in both the honest and the distorted run. The executor still takes 2,453.75 and delivers 2,341.17, so the index loses 112.6 of 11,000, or 1.02%. On a $50M uncapped index, case (1) is about $1.24M, and it can repeat every rebalance.

Claims this breaks. ARCHITECTURE.md section 5 says: "Nothing can move value out of an index". It lists "a multi-block TWAP manipulation at the snapshot; the caller choosing the snapshot moment" as shape-only, and says the owner and guardian can "never extract". Section 4 treats a windfall as needing natural moves ("the bought legs to lose a third of their value ... within three days"). The only defence is a guardian who spots the distorted targets during the 2-day notice and cancels, or holders who leave. No document tells the guardian to check snapshot prices.

**Proposed fix (reviewer)**

1) Reject snapshots whose averaging window crossed zero or near-zero liquidity. Pools already record this in the second accumulator, which `_poolPrice` currently throws away.

src/interfaces/IUniswapV3Pool.sol, add:
```solidity
    function liquidity() external view returns (uint128);
```
src/interfaces/IIndexRule.sol, add:
```solidity
    error ThinPriceHistory(address pool, uint256 harmonicMeanLiquidity, uint256 liquidity);
```
src/IndexRule.sol:190-201:
```diff
-        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
+        (int56[] memory tickCumulatives, uint160[] memory spl) = IUniswapV3Pool(pool).observe(secondsAgos);
+        uint160 splDelta;
+        unchecked { splDelta = spl[1] - spl[0]; } // accumulator wraps like Uniswap's
+        // Harmonic mean liquidity over the window, as OracleLibrary.consult: one block at zero liquidity collapses it.
+        uint256 harmonic = (uint256(TWAP_WINDOW) * type(uint160).max) / (uint256(splDelta) << 32);
+        uint256 current = IUniswapV3Pool(pool).liquidity();
+        if (harmonic < current / MAX_LIQUIDITY_DROP) revert ThinPriceHistory(pool, harmonic, current);
         int56 delta = tickCumulatives[1] - tickCumulatives[0];
```
with `uint256 public constant MAX_LIQUIDITY_DROP = 4;`. A per-token `minLiquidity` in TokenConfig, set through the listing flow, is sturdier, because an attacker who is also a large LP cannot pull it down. Also split the window into sub-windows and reject when one sub-window's mean tick is more than N ticks from the full mean. Neither check makes a manipulation through full-range liquidity by a validator with consecutive slots impossible; they raise its cost.
MockUniswapV3Pool needs `liquidity()` and settable secondsPerLiquidity accumulators. Test: `setCumulatives(0, -887272*12)` with a secondsPerLiquidity delta of 12<<128 (12 seconds at liquidity 1) makes `startRebalance(0)` revert with `ThinPriceHistory`.

2) Correct the docs. In ARCHITECTURE.md:208-211 and 255-263, replace "Nothing can move value out of an index" and "never extract" with: "A snapshot price read low by a factor f on a sold leg (or high on a bought leg) sets the fair multiplier to 1/f. Below f = 2/3 the first executor takes (1/f - 1.5) of the bought value (PoC: one 12-second extreme-tick block took 2.5% of an off-target uncapped index). During every notice period the guardian must compare `pendingRebalance().targetUnits` with `previewTarget(0)` recomputed from independent prices, and cancel on a mismatch." Add this duty to the README's guardian section. Add a regression test with the numbers from the PoC.

**Verifier (intent): confirmed -> MEDIUM**

I could not refute the mechanism. `_poolPrice` (src/IndexRule.sol:190-201) takes a plain arithmetic mean of the ticks, `int24 tick = int24(delta / SIGNED_TWAP_WINDOW)`, and throws away the liquidity accumulator. `_checkPool` (170-180) checks only the pool's identity, its cardinality and a non-zero price. `startRebalance` (IndexToken.sol:222-248) is permissionless once 28 days have passed and stores the rule's targets. The rule sets the targets from snapshot prices so the rebalance is value-neutral at those prices (`_redistribute` at IndexRule.sol:361-373). `_previewRebalance` and `_multiplier` (IndexToken.sol:327-349) never look at prices again, and the auction always opens at 1.5e18. So if a sold leg is read low by a factor f, the fair multiplier at true prices is about 1/f. Once f < 2/3, the first executor profits at the opening multiplier.

Design-intent check. ARCHITECTURE.md:257-261 says "Nothing can move value out of an index" and lists "a multi-block TWAP manipulation at the snapshot; the caller choosing the snapshot moment" among the risks that can only change shape. Lines 262-264 do say that a price error of δ moves the fair multiplier by about δ and that a windfall needs it above 1.5. They never connect that to snapshot manipulation, never give a size, and never give the guardian a duty to check. Section 4 (lines 221-223) frames a windfall as coming only from natural price moves within three days. R18 and R22 test that prices only shape targets and never enter settlement amounts. Neither covers value leaking through the auction band. So the risk is not documented and accepted, and the docs misstate what it can do.

Why MEDIUM, not HIGH:
- **Hard to distort the price.** A mean shift of 4,055 ticks needs about 608k ticks of displacement for a single 12-second block, which means pushing the price to MIN_TICK or MAX_TICK. That is only cheap on a pool with no full-range liquidity beyond its concentrated range, or for a validator who controls many consecutive slots. Whitelisted major tokens usually have full-range liquidity in the listed pool.
- **Not every index is exposed.** The basket must be off target: an uncapped index already on target cannot be hit this way, and a capped index is exposed only when a rest-group component is well over its share.
- **The loss is bounded.** The take is (m* - 1.5) of the bought value, and the bought value is limited by turnover and by the half-to-double clip.
- **There is time to react.** The distorted targets are public for 2 days. The guardian can cancel, and holders can leave in kind.

Even so, the loss is repeatable at every rebalance and contradicts an explicit security claim.

*PoC:* I re-ran the reporter's test at /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/sec-econ-twap/test/poc/TwapExtract.t.sol. Command: `cd .../poc/sec-econ-twap && forge test --match-path 'test/poc/*' -vv`. All 47 tests pass.

Uncapped case, test_uncapped_offTarget_oneBlockExtremeTick:
- Honest targets are 120e18 each; distorted targets are 112.16e18.
- At the opening multiplier of 1.5e18, the executor takes 878.44e18 and delivers 729.34e18.
- The index was worth 6,000e18 before, so the loss is 248 bps.

Capped case, test_capped_restComponentOverweight:
- The executor takes 2,453.75e18 and delivers 2,341.17e18.
- The index was worth 11,000e18 before, so the loss is 102 bps.

In both cases `MockRebalanceExecutor.execute` settled successfully. The TWAP was back to honest before the auction, so the loss comes entirely from the stored snapshot.

*Fix assessment:* The docs part of the fix (fix 2) is correct and required. Replace "Nothing can move value out of an index" and "never extract" with the statement that a price read low by a factor f on a sold leg (or high on a bought leg) sets the fair multiplier to about 1/f, so below f = 2/3 the first executor takes (1/f - 1.5) of the bought value. Add the guardian duty to recompute targets from independent prices during the notice period and cancel on a mismatch. Add this to README and to the guardian runbook.

The code part (fix 1) points the right way but is not correct as written:
- **It breaks views.** It puts the check inside `_poolPrice`, which is shared by `navPerToken`, `price`, `checkConfig`/`_checkPool` and `weights`. A thin moment would then make the display price revert and could block listings. The check belongs only on the path that `targetUnits` takes to `startRebalance`, for example a `_snapshotPrice` wrapper used by `targetUnits`.
- **It compares against a moving baseline.** The baseline is the pool's current `liquidity()`, which an LP attacker can pull down at call time. It can also make an honest start revert whenever the price sits in a naturally thin range.
- **The sturdier alternative is compliant.** A per-token `minLiquidity` in TokenConfig, changed only through the timelocked listing flow, fits the rule "the rule is stateless and its inputs are timelocked".
- **It adds a griefing path.** Anyone can push one extreme-tick block to make `startRebalance` revert for about 30 minutes. That is acceptable, because the start is permissionless and can be retried.
- **Sub-windows help too.** Rejecting a snapshot when a sub-window's mean tick deviates beyond a bound is also compliant.
- **Both checks stay out of settlement.** Neither may be moved into `executeRebalance`: CLAUDE.md says prices never enter the value-bearing steps.
- **It is not a complete fix.** Manipulation through full-range liquidity by a validator with consecutive slots only gets more expensive. Keep the docs change either way.

*Tests a fix must add:*

- startRebalance(0) reverts with ThinPriceHistory (or the chosen error) when the averaging window holds one 12-second block at MIN_TICK or MAX_TICK with near-zero liquidity, for a token that is token0 and one that is token1
- navPerToken, price(token) and checkConfig still succeed under the same thin window (the check must not sit in the shared _poolPrice)
- a legitimate snapshot with normal liquidity still starts, including a price inside a naturally thinner range but above the configured minimum
- regression with the PoC numbers: uncapped off-target basket (200,100,100,100,100) and capped (300,200,400,100,100) with supplies (30,20,5,5,5) no longer settle at a loss to the index, or the test documents the bounded loss if only docs change
- a bought leg read high by 50% (the symmetric case) is rejected in the same way
- a guardian cancelRebalance during the notice period after a distorted snapshot, then a clean restart after the cooldown

**Verifier (impact): partially-confirmed -> MEDIUM**

I could not refute the mechanism. `_poolPrice` (src/IndexRule.sol:190-201) takes a plain arithmetic mean of ticks over 1,800 s: `int24 tick = int24(delta / SIGNED_TWAP_WINDOW)`. It throws away the secondsPerLiquidity accumulator and checks neither depth nor outliers. `_checkPool` (170-180) checks only the pool's identity, its cardinality and a nonzero price. `startRebalance` (src/IndexToken.sol:222-248) is permissionless after 28 days and stores whatever `targetUnits` returns. `_targets`/`_redistribute` keep the targets value-neutral at the snapshot prices. The auction always opens at `AUCTION_START_MULTIPLIER` 1.5 and never looks at prices again. So when a sold leg's price is read low by a factor f, the fair multiplier becomes about 1/f, and below f = 2/3 the first filler at `eta` takes value. R18 (test/Security.t.sol:932-951) only covers an uncapped index that is already on target, which is immune, and a capped index's bounds. It never checks value.

The docs misstate this. ARCHITECTURE.md:258-261 says "Nothing can move value out of an index" and lists "a multi-block TWAP manipulation at the snapshot" as shape-only. Line 262 half-concedes that "a price error of δ ... moves the fair multiplier by about δ" and that "a windfall needs the fair multiplier above 1.5". But it never ties that to snapshot manipulation, never gives a magnitude, and never tells the guardian to check the targets. So documented-accepted does not fit.

Why MEDIUM rather than HIGH:
1. **Cost depends on the pool.** One block at MIN_TICK is only cheap in a pool with no full-range liquidity. With full-range liquidity L, pushing to the extreme tick needs about L*(2^64-scale) of the token, which is infeasible. A 4,055-tick mean shift through a moderate deviation needs many blocks and survives arbitrage only for a builder or validator with consecutive slots. The cost figure of "10-30% of in-range WETH" was not checked against a real pool.
2. **The pool is chosen through a timelock.** The owner picks it behind the 2-day delay and the guardian's cancel.
3. **Not every basket is exposed.** Uncapped baskets that are on target are immune. Only off-target uncapped baskets and some capped baskets are exposed.
4. **Holders and the guardian get 2 days.** The distorted targets are public in `RebalanceStarted` and `pendingRebalance()` for 2 days. The guardian can cancel and holders can redeem.
5. **The attacker may not keep the profit.** It must win the first fill at `eta` against every other executor and builder, who see the same windfall. The profit goes mostly to MEV rather than to the manipulator, but the index loses it either way.

Loss magnitude, from the mock PoC: 2.48% of an off-target uncapped index and 1.02% of a capped one, per rebalance, and it can repeat monthly. That is a real value loss with significant preconditions and mitigations, and it contradicts a documented security claim.

*PoC:* I re-ran the reporter's test, /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/sec-econ-twap/test/poc/TwapExtract.t.sol. It sets the cumulatives to 12 s at the extreme tick for one sold token, calls `startRebalance(0)` as the attacker, restores tick 0, warps to `eta` and fills with MockRebalanceExecutor.

Command: `cd .../poc/sec-econ-twap && forge test --match-path 'test/poc/*' -vv`. Result: 47 passed, 0 failed.

Decisive lines:
- **Uncapped** (`test_uncapped_offTarget_oneBlockExtremeTick`): honest targets are 120e18 and distorted targets are 112.155e18. "multiplier 1500000000000000000", "taken (WETH at true prices) 878442685472932652750", "delivered 729343887162404082480", "index value before 6000000000000000000000", "loss bps 248".
- **Capped** (`test_capped_restComponentOverweight`): component 2 stays at 200e18. "taken 2453753085421028956130", "delivered 2341167985895300502220", "index value before 11000000000000000000000", "loss bps 102".

Limits: the pools are mocks, so the test proves the protocol-side arithmetic but not the cost of the manipulation on real Uniswap V3 liquidity. No fork test was run.

*Fix assessment:* The docs fix is correct and needed, and it complies with CLAUDE.md. Replace "Nothing can move value out" and "never extract" in ARCHITECTURE.md:258-261 with the 1/f fair-multiplier statement and its magnitude. Add a guardian duty to the README: during every notice period, compare `pendingRebalance().targetUnits` with targets recomputed from independent prices, and cancel on a mismatch.

The code fix as proposed is incomplete and can be bypassed. It compares harmonic-mean liquidity with the pool's current `liquidity()`, which the caller controls in the same transaction. The caller swaps the price into a zero- or thin-liquidity gap, calls `startRebalance`, and swaps back. `liquidity()` then reads about 0, so `harmonic < current / 4` is false and the check passes. Swaps inside the block do not change the TWAP, so this costs only fees.

Corrected fix:
1. **Absolute liquidity floor.** Add a `minHarmonicLiquidity` field to `IIndexFactory.TokenConfig`, set and changed only through the timelocked listing flow, as CLAUDE.md requires for rule inputs. `_poolPrice` (or `_price` on the `targetUnits` path only) computes the harmonic mean the way OracleLibrary.consult does, `(uint256(TWAP_WINDOW) * type(uint160).max) / (uint256(splDelta) << 32)` over an unchecked uint160 difference. It reverts `ThinPriceHistory(pool, harmonic, minimum)` when the mean is below the floor.
2. **Deviation check.** Optionally add a sub-window check, for example observe at [1800, 900, 0] and reject when the two half-window mean ticks differ by more than a constant such as 2,000 ticks. This raises the cost of one-block outliers, and the caller cannot manipulate it in the same block.
3. **Scope.** Keep `navPerToken` and `startPrice` behaviour either unchanged or explicitly covered.

Neither check stops sustained manipulation through deep liquidity by a validator with consecutive slots. The docs must still state the residual risk. The fix also touches the factory's config struct, the mocks (MockUniswapV3Pool needs settable secondsPerLiquidity accumulators) and ConfigureWhitelist.

*Tests a fix must add:*

- Regression test: one 12 s extreme-tick observation with a secondsPerLiquidity delta of 12<<128 makes startRebalance(0) revert with ThinPriceHistory (exact selector and args)
- Bypass test: a pool whose current liquidity() is 0 at call time (price parked in a gap) still reverts, proving the floor is absolute and not relative to current liquidity
- Honest pool with harmonic liquidity at or above the configured minimum still starts a rebalance (boundary: exactly equal passes, one below reverts)
- Sub-window deviation check, if added: half-window mean ticks differing by threshold+1 revert and by exactly the threshold pass
- Value-conservation test in the style of the PoC: for an off-target uncapped basket and a capped basket, a sold-leg price read low by f=0.66 is rejected (or the documented loss bound holds)
- Listing-flow test: proposing and executing a config with minHarmonicLiquidity goes through LISTING_DELAY and the guardian can cancel it
- Uint160 wraparound of the secondsPerLiquidity accumulator is handled (unchecked subtraction) without reverting

**Verifier (reachability): confirmed -> MEDIUM**

I could not refute the mechanism.
- startRebalance can be called by anyone after 28 days with keepMask 0 (IndexToken.sol:222-237), and the targets it stores come from IIndexRule.targetUnits (IndexToken.sol:353-355).
- _poolPrice (IndexRule.sol:190-201) takes the arithmetic mean tick over 1,800 s from observe(). It throws away the secondsPerLiquidity accumulator and has no check on depth or outliers. _checkPool (170-180) only checks the pool's identity, its cardinality and a non-zero price.
- _redistribute (IndexRule.sol:368-379) makes the targets value-neutral at the snapshot prices only.
- Once the auction opens, _previewRebalance / _multiplier (IndexToken.sol:327-349) never read prices, and the multiplier always opens at 1.5e18 (line 55). If a sold leg's price is read low by a factor f, the fair multiplier at true prices is 1/f. Once f < 2/3, the first executor takes (1/f - 1.5) times the bought value.

The PoC reproduces this against the real IndexToken and IndexRule: a loss of 248 bps on an off-target uncapped basket and 102 bps on a capped one.

The docs contradict it:
- ARCHITECTURE.md:257-261 says "Nothing can move value out of an index" and lists "a multi-block TWAP manipulation at the snapshot" as shape-only.
- Line 262 does admit that a price error moves the fair multiplier by about delta, and that a windfall needs it above 1.5. But the docs never connect this to snapshot manipulation, and they give the guardian no duty to check snapshots.
- It is not documented-accepted: the trust line (255) trusts listed-pool TWAPs, but the shape-vs-value bullet misstates what happens when that trust fails.

Why MEDIUM, not HIGH:
1. The cheap route (one block at MIN_TICK for fees plus recaptured slippage) needs a listed WETH pool with no full-range or wide liquidity. Moving sqrtPrice to MIN_SQRT_RATIO costs about L * 1.8e19 raw token0 for any in-range L. Even L = 1e6 needs about 1.8e7 whole 18-decimal tokens. Many mainnet V3 pools keep dust full-range positions, and any of them blocks this route. The finding itself admits that full-range liquidity forces about 13 blocks or validator control of consecutive slots.
2. The 2-day notice is public (RebalanceStarted emits the targets), the guardian can cancel (IndexToken.sol:240-250), and holders can redeem at the old units.
3. Only off-target baskets are exposed. An uncapped basket already on target is immune (R18).
4. The loss per event is a few percent of the index (the PoC shows 1-2.5%), not the whole index.
The risk can repeat every rebalance, and the protocol has no on-chain defence, so it is more than LOW.

*PoC:* I copied the reporter's test /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/sec-econ-twap/test/poc/TwapExtract.t.sol into my own copy, /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/verify-twap-extract, and ran `forge test --match-path 'test/poc/*' -vv` there. Both tests pass:
- test_uncapped_offTarget_oneBlockExtremeTick: "multiplier 1500000000000000000", "taken 878442685472932652750", "delivered 729343887162404082480", "loss bps 248".
- test_capped_restComponentOverweight: "taken 2453753085421028956130", "delivered 2341167985895300502220", "loss bps 102".

The test uses MockUniswapV3Pool.setCumulatives. The mock does not model how much it costs to reach MIN_TICK on a real pool, so the real-world cost is judged from Uniswap V3 math, not from this test.

*Fix assessment:* The documentation fix is correct and needed. ARCHITECTURE.md:257-261 and 221-223 should say that a snapshot price read low by a factor f on a sold leg (or high on a bought leg) sets the fair multiplier to 1/f, and that below f = 2/3 the first executor extracts value. The guardian's duty to compare pendingRebalance().targetUnits with independently priced targets during the notice period belongs in README and ARCHITECTURE.

Code fix 1 as proposed is incomplete: it can be bypassed. It compares the harmonic-mean liquidity with the pool's current `liquidity()`, which the caller controls in the same transaction:
1. The attacker makes the first swap of a block and moves the price into a thin range. observe(0) adds no time for the current block, so the harmonic mean does not change, but `liquidity()` drops.
2. `harmonic >= current/4` now passes.
3. The attacker calls startRebalance, then swaps back in the same transaction, paying only fees.

Corrected fix, all inside IndexRule and the listing flow, so it stays compliant with CLAUDE.md (value-bearing steps stay oracle-free, and rule inputs stay timelocked):
- (a) Add a per-token `minLiquidity` (uint128) to TokenConfig, set through proposeListing/executeListing. In _poolPrice, read both accumulators and compute the harmonic mean like OracleLibrary.consult: `(uint256(TWAP_WINDOW) * type(uint160).max) / (uint256(uint160(spl[1] - spl[0])) << 32)`, using unchecked subtraction. Revert `ThinPriceHistory(pool, harmonic, minLiquidity)` when `harmonic < config.minLiquidity`. The rule must receive the config, which _market already has.
- (b) Also split TWAP_WINDOW into sub-windows, e.g. observe([1800,1200,600,0]), and revert when any sub-window's mean tick is more than MAX_TICK_DEVIATION (say 1,000 ticks) from the full-window mean. A one-block outlier inflates its own sub-window by 3x, so this catches a single extreme block even through a full-range position.

Do not add price checks to executeRebalance: that would put prices into the settlement and break the recorded rule that prices never enter it. Neither check stops a validator that controls many consecutive slots; the docs must say so.

*Tests a fix must add:*

- startRebalance(0) reverts with ThinPriceHistory when one 12-second block at liquidity 0 (secondsPerLiquidity delta 12<<128) lies inside the window
- startRebalance(0) reverts on a sub-window tick-deviation breach when setCumulatives injects one block at MIN_TICK (token0) and at MAX_TICK (token1 orientation)
- the check cannot be bypassed by lowering in-range liquidity in the same transaction: a harmonic-mean threshold taken from config, not from pool.liquidity()
- an honest pool with stable liquidity and tick still passes _checkPool at listing and startRebalance
- a regression test in Security.t.sol with the PoC numbers (248 bps uncapped, 102 bps capped) showing the distorted snapshot now reverts
- MockUniswapV3Pool gains settable secondsPerLiquidity accumulators and per-secondsAgo tick cumulatives; Mocks.t.sol covers them to keep coverage at 100%
- a TokenConfig minLiquidity validation test in the IndexFactory listing flow, including the exact revert error

### XA-02 [LOW] A stranger can keep a rebalance from ever clearing by restarting it at a distorted snapshot; the guardian has to step in every cycle

- **Dimension:** Security (griefing / liveness)
- **Location:** `src/IndexToken.sol:222-237, 256-257, 319-320`
- **Reported by:** sec-economic (reported LOW); also H-14
- **Touches a recorded product decision:** yes
- **Verification:** combined: partially-confirmed -> LOW

**Problem**

When a rebalance expires, anyone can restart it straight away. `startRebalance` checks only `pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION` (IndexToken.sol:226). The only wait for strangers is `restartAllowedAt`, and that is set only by `cancelRebalance` (IndexToken.sol:256-257). So a griefer can win the start at day 28, and again at every expiry, using a snapshot built so the fill never clears. From SEC-1, reading a bought leg's price low by a factor f gives a fair multiplier of about f. With f < 0.9 (a mean-tick shift of 1,054 ticks, or one 12-second block about 158k ticks away through thin liquidity), no executor fills even at `AUCTION_END_MULTIPLIER`. The auction expires after 3 days (`RebalanceExpired`, IndexToken.sol:320), and the griefer starts again with the next distortion. Each attempt costs one thin-pool manipulation, and each one freezes the index's rule for 3 days. The docs say the opposite: ARCHITECTURE.md section 3 step 4 says "If nobody fills, the auction expires harmlessly and anyone can start a fresh one from new prices". The guardian can break the loop by cancelling and restarting honestly during its 2-day exclusive window. That is a manual action every cycle, and the docs name it only for frozen components.

**Proposed fix (reviewer)**

Pick one of these, or both. (a) Put strangers behind the same cooldown after an expiry that follows a cancel. In startRebalance (IndexToken.sol:225-234):
```diff
         uint256 pendingEta = _pending.eta;
         if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) {
             revert RebalancePending(pendingEta + AUCTION_DURATION);
         }
+        uint256 expiredRestart = pendingEta == 0 ? 0 : pendingEta + AUCTION_DURATION + REBALANCE_DELAY;
         ...
         if (
-            (keepMask != 0 || block.timestamp < restartAllowedAt)
+            (keepMask != 0 || block.timestamp < restartAllowedAt || block.timestamp < expiredRestart)
                 && !IIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)
         ) revert Unauthorized(msg.sender);
```
This gives the guardian a window after an expiry to start a vetted snapshot. (b) Apply the liquidity check from SEC-1, which makes an unfillable snapshot expensive. Also update ARCHITECTURE.md section 3 step 4 to name the grief and the guardian's response. Test: start with the bought leg's cumulatives set for f = 0.85, warp past eta + 24h, and show a stranger's `startRebalance(0)` reverts with `Unauthorized` while the guardian's succeeds.

**Verifier (combined): partially-confirmed -> LOW**

Reachability is confirmed in source. startRebalance (src/IndexToken.sol:222-234) blocks a stranger only while `pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION`, or while `block.timestamp < restartAllowedAt`. restartAllowedAt is written only in cancelRebalance (:256-257). An expiry does not change lastRebalance, which only _applyRebalance sets, so the MIN_REBALANCE_INTERVAL check keeps passing. A stranger can therefore restart one second after expiry. The existing test test_startRebalance_pendingThenExpiredRestart (test/IndexToken.rebalance.t.sol:152-165) does exactly this, with the comment "an expired auction can be restarted at once".

The docs understate the risk. ARCHITECTURE.md:184 says "If nobody fills, the auction expires harmlessly and anyone can start a fresh one from new prices". Section 5 accepts "a multi-block TWAP manipulation at the snapshot; the caller choosing the snapshot moment" as ways to distort a basket's shape. It says nothing about a snapshot built to be unfillable, repeated to keep the rule stalled. It names the guardian's manual response only for frozen components.

The impact is narrower than the finding says:
(1) Liveness only. No value leaves the index. Issue, redeem and claim keep working, and units stay as they were.
(2) The griefer must win the start race at each expiry and must manipulate a 30-minute TWAP every time. Moving the mean tick by about 1,054 (f≈0.9) takes roughly 158k ticks held for one block, or a smaller shift held over many blocks against arbitrage. That is realistic only for thin listed pools.
(3) An uncapped index already on target cannot be griefed this way. Its targets are u_i = s_i * sum(u_j p_j)/sum(s_j p_j), and with u = k*s that reduces to k*s_i whatever the prices (ARCHITECTURE.md:213-214 says the same). TurnoverTooLow would then block the start. Capped indexes and off-target uncapped indexes are exposed.
(4) The guardian can break any single loop: cancel, then start an honest snapshot during its exclusive 2-day window.

LOW is the right severity. This is a real but conditional liveness grief with no loss of funds.

*PoC:* Not run. The decisive runtime claim, that a stranger can restart immediately after expiry, is already shown by the passing repo test test_startRebalance_pendingThenExpiredRestart (test/IndexToken.rebalance.t.sol:152-165, part of the 247 green tests). The economic part (f < 0.9 makes the snapshot unfillable) follows from the multiplier arithmetic in _previewRebalance and from the doc's stated rule that a price error of δ moves the fair multiplier by about δ. A mock PoC would only restate the pool-manipulation assumption.

*Fix assessment:* Fix (a) is incomplete and has side effects.
(1) It does not stop the grief. The griefer simply waits out the extra REBALANCE_DELAY after each expiry and restarts if the guardian stays idle. The guardian still has to act every cycle, which is the very burden the finding complains about.
(2) The guardian's own start reads the same 30-minute TWAP, so a griefer can manipulate right before the guardian's transaction too. Nothing in the contract makes a guardian snapshot "vetted".
(3) It adds 2 days to every natural expiry. The docs estimate that 5% of auctions expire at medium volatility, so an honest restart would also need the guardian or a wait. That moves routine liveness toward a role, against the "no keeper role, permissionless trigger" rule. It is still compliant, because a stranger can restart after the wait.
(4) The diff has a nit: `expiredRestart` must be computed only when an expired pending exists. That is fine as written, because an unexpired pending already reverted.

Fix (b) (the liquidity check from SEC-1) raises the cost of each attempt and addresses the root cause better.

The minimum compliant fix is documentation. Change ARCHITECTURE.md:184 and the section 5 "Shape versus value"/"Known limitations" text to say that a snapshot manipulated so the fair multiplier falls below 0.9 cannot be filled. A griefer can repeat that at each expiry and stall a capped or off-target index. The guardian's answer is cancel, then an honest start in its 2-day window. Pools thin enough for this should not be listed. If code is wanted, combine (b) with (a).

*Tests a fix must add:*

- A stranger's startRebalance(0) right after an expired auction reverts Unauthorized when the fix (a) cooldown is active, and the guardian's call succeeds in the same block
- A stranger can restart after pendingEta + AUCTION_DURATION + REBALANCE_DELAY, so the permissionless trigger is kept
- After a cancel, the cooldown still uses restartAllowedAt and does not double-count with the expiry cooldown
- An uncapped index already on target: a price distortion at start leaves targets unchanged (TurnoverTooLow), which documents where the grief cannot apply
- Capped index: a bought-leg price read low by f=0.85 at the snapshot makes the fill revert RebalanceUnderfunded even at AUCTION_END_MULTIPLIER, and then RebalanceExpired

### XA-03 [LOW] A config-change proposal pending at delist time re-whitelists the delisted token when anyone executes it

- **Dimension:** Security (access-control / proposal lifecycle)
- **Location:** `src/IndexFactory.sol:204-243`
- **Reported by:** sec-factory (reported MEDIUM); also R1-corr-core-1, R1-docs-natspec-3, R1-docs-prose-3
- **Merged into this finding (same root cause):** R1-hazard-ops-4
- **Verification:** combined: confirmed -> LOW

**Problem**

`delist` (src/IndexFactory.sol:229-243) only clears `isWhitelisted` and the array entry. It leaves `listingEta[token]` and `_pendingConfig[token]` in place. `executeListing` (src/IndexFactory.sol:205-226) takes no caller restriction. Whether the proposal whitelists the token is decided when it is executed, not when it was proposed:

```solidity
220        if (!isWhitelisted[token]) {
221            isWhitelisted[token] = true;
222            _whitelist.push(token);
```

The docs describe a proposal for an already-listed token as a config change (IIndexFactory.sol:134-136, ARCHITECTURE.md "for a listed token it proposes a config change"). But the same pending entry becomes a relisting once the token has been delisted.

Scenario:
1. At T the owner proposes a routine config change for listed token A, for example a new referenceSupply or exclusions.
2. At T+1d A's issuer is compromised (infinite mint, malicious upgrade). The guardian calls `delist(A)`, the documented emergency response, which takes effect immediately.
3. At T+2d (eta) any account calls `executeListing(A)`. A is whitelisted again and `createIndex` accepts it, so users can be steered into minting brand-new indexes backed by the compromised token.

The guardian only avoids this by also knowing to call `cancelListing(A)`. Neither the docs nor the NatSpec say that a delist can be undone this way, and the undo stays possible for up to LISTING_DELAY + PROPOSAL_WINDOW = 9 days after the proposal. Verified with a PoC (scratchpad/poc/factory-delist-relist/test/poc/DelistRelist.t.sol, test_poc_pendingConfigChangeUndoesDelist, passes): after delist and a stranger's executeListing, `isWhitelisted(a)` is true and `createIndex` with `a` succeeds. Existing indexes are unaffected, and holders still leave in kind, which is why this is MEDIUM and not HIGH.

**Merged: R1-hazard-ops-4 — A config (reference-supply) refresh of a delisted token can only be applied by re-whitelisting it**

Hazard: delisting keeps the config that existing indexes still rebalance with (IndexFactory.sol:24-26, README:198-199), and the docs say reference supplies "drift and are refreshed with a config change". But the only way to change a config is `executeListing`, which always runs `if (!isWhitelisted[token]) { isWhitelisted[token] = true; ... emit TokenWhitelisted(token, true); }` (220-225). Scenario: WBTC was delisted but is still held by existing capped and uncapped indexes, whose monthly snapshots keep using `referenceSupply = 20_084_784e8`. Bitcoin issuance is about 3.125 BTC x 52,560 blocks, roughly 164k BTC a year (~0.8%/yr), so WBTC's market cap and weight drift low every month without end. To refresh it, the owner has to propose a listing. Once due, anyone can call `executeListing`, whenever they like, which re-whitelists WBTC. Between that call and a later `delist` by the owner or guardian, any user can `createIndex` with it. The fix therefore depends on an unstated ordering: execute and delist atomically from the Safe, never permissionlessly. Nothing in the docs or scripts records that.

*Proposed fix:*

src/IndexFactory.sol:220 applies the config without whitelisting a token that already has one:
```diff
-        if (!isWhitelisted[token]) {
+        bool hadConfig = current.pool != address(0) || current.referenceSupply != 0; // read before overwrite
+        if (!isWhitelisted[token] && !hadConfig) {
```
(compute `hadConfig` before lines 214-216 overwrite `current`). Re-listing a delisted token then goes through a separate owner-only `relist(token)` guarded by the same LISTING_DELAY. If the contract stays unchanged, document in README:196-199 that refreshing a delisted token's config means a Safe batch of `executeListing(token)` plus `delist(token)`. Test: delist, propose a config, execute, and assert `isWhitelisted == false` and `tokenConfig.referenceSupply` updated.

**Proposed fix (reviewer)**

Make delist fail closed by also dropping any pending proposal for the token, so relisting always needs a fresh LISTING_DELAY. In src/IndexFactory.sol:

```diff
     function delist(address token) external onlyOwnerOrGuardian {
         if (!isWhitelisted[token]) revert NotWhitelisted(token);
 
         isWhitelisted[token] = false;
+        if (listingEta[token] != 0) {
+            delete listingEta[token];
+            delete _pendingConfig[token];
+            emit ListingCancelled(token);
+        }
         uint256 pos = _whitelistPos[token] - 1;
```

Update IIndexFactory.sol:146 NatSpec: "Owner or guardian, effective immediately. Also cancels any pending listing or config change for `token`. Existing indexes are not affected." Add a regression test to test/IndexFactory.t.sol (and to Security.t.sol under the next id):

```solidity
function test_delist_cancelsPendingConfigChange() public {
    IIndexFactory.TokenConfig memory next = market.config(address(a), 0);
    vm.prank(owner);
    factory.proposeListing(address(a), next);
    uint256 eta = factory.listingEta(address(a));
    vm.expectEmit(true, true, true, true, address(factory));
    emit IIndexFactory.ListingCancelled(address(a));
    vm.prank(guardian);
    factory.delist(address(a));
    assertEq(factory.listingEta(address(a)), 0);
    vm.warp(eta);
    vm.expectRevert(abi.encodeWithSelector(IIndexFactory.NoPendingListing.selector, address(a)));
    factory.executeListing(address(a));
    assertFalse(factory.isWhitelisted(address(a)));
}
```

**Verifier (combined): confirmed -> LOW**

Reachability holds. `delist` (src/IndexFactory.sol:229-243) clears only `isWhitelisted`, the array entry and `_whitelistPos`. It leaves `listingEta[token]` and `_pendingConfig[token]` in place. `executeListing` (205-226) has no caller restriction, and at lines 220-225 it whitelists the token again when `!isWhitelisted[token]`. So a config-change proposal made while the token was listed becomes a relisting after a delist, and any account can execute it between eta and eta+PROPOSAL_WINDOW.

Design intent: the docs do not cover this case. The IIndexFactory.sol:146 NatSpec ("effective immediately"), ARCHITECTURE.md:136-141 and README.md:196-199 all describe delist as immediate and never mention that a pending proposal can undo it. So it is not documented-accepted.

Impact: I lower it from MEDIUM to LOW for four reasons.
1. It needs a proposal the owner already made to be pending at the moment of the emergency. It also needs the guardian not to call `cancelListing`, which it can do in the same response and is listed as a guardian power right next to delist.
2. Once someone executes the proposal, the guardian can call `delist` again right away. Exposure is limited to the gap between that execution and the second delist.
3. Only indexes created afterwards are affected. Existing indexes are unchanged, and holders can still redeem in kind.
4. Harm requires users to choose to create or mint an index that holds the compromised token. The app is the natural place to warn them.

This is a real flaw in how the emergency response works, with several mitigating factors and no direct loss of funds. LOW fits better than MEDIUM.

*PoC:* I re-ran the reporter's PoC in its private copy: scratchpad/poc/factory-delist-relist/test/poc/DelistRelist.t.sol (it extends IndexFactoryTest). The owner proposes a config change for listed token a, the guardian delists a, the test warps to eta, a stranger calls executeListing(a), and then createIndex with a succeeds. Command: cd scratchpad/poc/factory-delist-relist && forge test --match-test test_poc_pendingConfigChangeUndoesDelist -vv. Output: "[PASS] test_poc_pendingConfigChangeUndoesDelist() (gas: 744058)". The assertTrue(factory.isWhitelisted(a), "delist silently undone") check passes.

*Fix assessment:* The fix is correct and complies with CLAUDE.md. Having `delist` drop any pending proposal fails closed: relisting then always needs a fresh proposal and a full LISTING_DELAY, and nothing gives admins more power over funds. Two notes:
1. Place the new block after the `NotWhitelisted` check, and write state before emitting both events. The `ListingCancelled` then `TokenWhitelisted(false)` order is fine.
2. A new listing that is pending for a token that is not whitelisted is still not handled, because `delist` reverts with NotWhitelisted there. That is intended, since the guardian uses `cancelListing` for it.

Alternative: record at proposal time whether the proposal is a config change, and have `executeListing` never whitelist when that flag is set. This is more complex, and a stale config applied to a delisted token would still be odd, so the proposed auto-cancel is preferable.

Update IIndexFactory.sol:146 NatSpec, ARCHITECTURE.md:139-141 and README.md:198-199 to say that delist also cancels a pending proposal. Also add a Security.t.sol regression test under the next id, as CLAUDE.md requires.

*Tests a fix must add:*

- delist with a pending config change emits ListingCancelled, zeroes listingEta, and a later executeListing at eta reverts with NoPendingListing(token); isWhitelisted stays false
- delist with no pending proposal emits no ListingCancelled event (the branch where listingEta == 0), keeping 100% branch coverage
- after delist cancels a pending proposal, the owner can proposeListing again at once (no ListingPending revert) and relisting needs a full LISTING_DELAY
- delist with an expired but uncancelled proposal (listingEta != 0, past the window) also clears it
- Security.t.sol regression test under the next finding id reproducing the delist-then-executeListing scenario

### XA-04 [LOW] Capped 30/20 rule lets the third-ranked component outweigh both the 30% top and the 20% second; the default 5-token list gives LINK about 35%

- **Dimension:** Security (methodology-correctness)
- **Location:** `src/IndexRule.sol:272-296 (and src/libraries/Methodology.sol:11-20)`
- **Reported by:** sec-rule (reported MEDIUM); also R1-corr-rule-1, R1-docs-natspec-1, H-1
- **Touches a recorded product decision:** yes
- **Verification:** combined: confirmed -> LOW

**Problem**

The capped weights come from a closed formula. `_cappedWeights` (src/IndexRule.sol:283-294) computes
`secondWeight = Math.min(Math.mulDiv(CAPPED_REMAINDER, caps[second], caps[second] + rest), CAPPED_SECOND_MAX_WEIGHT); share = CAPPED_REMAINDER - secondWeight; ... w[i] = Math.mulDiv(share, caps[i], rest);`

When the second-ranked weight hits its 20% cap, ranks 3 and below share a fixed 50% by cap. Nothing limits any one of them, so rank 3 can go above both 20% and 30%. Methodology.sol:11-12 says "The largest constituent weighs 30%, the second largest at most 20%". Methodology.sol:18-20 justifies the 5-component minimum by saying that with four components "a third- or fourth-ranked constituent always exceeds 20%". Five components do not prevent this; they only make it not guaranteed.

Concrete case, the default whitelist (script/ConfigureWhitelist.s.sol:52-79 lists exactly 5 tokens: WBTC, WETH, LINK, UNI, tBTC). With reference supplies and rough prices, the caps are about $2,000B, $488B, $15B, $6B and $0.5B. A PoC calling `weightsFromCaps([2000e9,488e9,15e9,6e9,0.5e9], CAPPED)` against the compiled IndexRule returned:
- WBTC 0.300000
- WETH 0.200000
- LINK 0.348837
- UNI 0.139535
- tBTC 0.011628

So the only capped index the default list allows holds 34.9% LINK: more than the "largest at 30%" and 1.74 times the "at most 20%" second. The rebalance rule then keeps pushing units toward that shape each month. A synthetic case, caps [100,99,98,1,1], gives rank 3 a weight of 49%.

README.md:41 ("30% / at most 20% / the rest by cap") and ARCHITECTURE.md:105-107 describe the rule without this effect. Users picking "capped" for diversification get a larger single-asset concentration than the label says. No funds are extracted, but the recorded methodology's stated consequence is wrong.

**Proposed fix (reviewer)**

Option A keeps the recorded decision and corrects the docs.

src/libraries/Methodology.sol:11-12 and 18-19:
```diff
-    /// @notice The largest constituent weighs 30%, the second largest at most 20%, and the others share the rest in
-    ///         proportion to market cap.
+    /// @notice The largest constituent weighs 30%, the second largest at most 20%, and the others share the rest in
+    ///         proportion to market cap. Ranks 3 and below are not capped: when the second is capped they share 50%, so
+    ///         one of them can outweigh the first two (WBTC/WETH/LINK/UNI/tBTC gives LINK about 35%).
     uint8 internal constant CAPPED = 1;
@@
-    /// @notice Below five constituents the capped rule contradicts its own cap: with three the smallest always weighs
-    ///         at least 50%, and with four a third- or fourth-ranked constituent always exceeds 20%.
+    /// @notice Below five constituents a rank-3+ constituent always exceeds 20% (with three it weighs at least 50%).
+    ///         Five or more make that possible rather than certain; the rule does not cap ranks 3 and below.
```
Make the same correction in README.md:41 and ARCHITECTURE.md:105-107, and have the app show the resulting weights (`weights(tokens, 1)`) before creation.

Option B changes the recorded product decision and needs explicit sign-off. Cap every component after rank 1 at 20% and redistribute the excess by cap among the uncapped ones, iterating as in `_redistribute`. Add a test that `weightsFromCaps([2000e9,488e9,15e9,6e9,0.5e9], 1)[2] <= 0.2e18`.

**Verifier (combined): confirmed -> LOW**

Reachability: `_cappedWeights` (src/IndexRule.sol:274-296) gives rank 1 a fixed `CAPPED_TOP_WEIGHT` (0.3e18). Rank 2 gets `min(0.7 * cap2/(cap2+rest), 0.2)`, and each remaining component gets `share * cap_i / rest` with `share = 0.7 - secondWeight`. Nothing limits a rank-3+ weight. When rank 2 is capped, ranks 3 and below share 50%, so a large rank-3 component can outweigh both rank 1 (30%) and rank 2 (20%). The only guard is `MIN_CAPPED_COMPONENTS = 5`, and it does not prevent this. The default mainnet list in script/ConfigureWhitelist.s.sol:52-79 has exactly five tokens (WBTC, WETH, LINK, UNI, tBTC), so a capped index built from it is heavily concentrated in LINK.

Impact: I ran the PoC and it matches the reported numbers exactly. No funds are taken and the invariant still holds. The cost is portfolio concentration: a user who picks "capped" for diversification gets about 35% in the third-ranked asset, and each monthly rebalance moves units back toward that shape.

Design intent: ARCHITECTURE.md:105-107 gives the exact formula and says it "reproduces the Numbers model's formula", which CLAUDE.md records as the required methodology. So the code does what was decided. The defect is in the stated consequences, which are wrong or misleading:
- Methodology.sol:11-12 says "The largest constituent weighs 30%, the second largest at most 20%".
- Methodology.sol:18-19 justifies the minimum of 5 by saying that with four components a third- or fourth-ranked one "always exceeds 20%". That implies five or more prevent it, and they do not.
- README.md:32 and :41 give the "30% / at most 20% / the rest by cap" framing.

No doc states that ranks 3 and below are uncapped, or how large they can get. That rules out documented-accepted. Because the code matches the recorded decision and the harm is a misstatement plus user expectation, not a fund risk, I lower the severity from MEDIUM to LOW.

*PoC:* Test file: /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/verify-capped-rank3/test/poc/CappedRank3.t.sol. It extends IndexRuleTest so it can use the fixture's `rule`.

Command: `forge test --match-path 'test/poc/*' --match-test poc -vv`

Result: [PASS] test_poc_rank3(). The logs show 300000000000000000, 200000000000000000, 348837209302325581, 139534883720930232 and 11627906976744186, then "synthetic rank3 490000000000000000". The test's assertGt(w[2], w[0]) passed.

*Fix assessment:* Option A (fix the docs) is correct and follows CLAUDE.md, since it leaves the recorded Numbers-model formula alone. It should update:
- Methodology.sol:11-12 and :18-19
- README.md:32 and :41
- ARCHITECTURE.md:105-107, which should state that ranks 3 and below are uncapped and can outweigh rank 1, with the LINK example
Its number ("LINK about 35%") depends on market prices, so the docs should say it is illustrative and dated. The app-side note (show `weights(tokens, 1)` before creation) is sensible.

Option B (cap every component after rank 1 at 20% and redistribute the excess) changes a recorded product decision. It needs explicit owner sign-off and a note in ARCHITECTURE.md that it no longer reproduces the Numbers model. It also has an edge case: with 5 components, a ceiling of 20% for ranks 2 to 5 sums to at most 80%, which is enough for the 70% remainder. But if any weight in the iterative redistribution rounds to zero, the loop must still terminate and the weights must still sum to 1e18. Option B's proposed test is necessary but not sufficient.

*Tests a fix must add:*

- Option A: none are strictly required (docs-only change); an optional test records the documented behaviour: `weightsFromCaps([2000e9,488e9,15e9,6e9,0.5e9], 1)[2] > 0.3e18`
- Option B: rank-3 weight <= 0.2e18 on the default-list caps
- Option B: fuzz test that every weight after rank 1 is <= 0.2e18 and the weights sum to 1e18 (within rounding) for n >= 5
- Option B: redistribution terminates when several of ranks 2 to 5 hit the cap together (e.g. caps [100,99,98,97,1])

### XA-05 [LOW] Kept components are still priced and supplied, so a keep mask cannot route a rebalance around a component whose price reverts (ZeroPrice or cap overflow)

- **Dimension:** Security (liveness)
- **Location:** `src/IndexRule.sol:129, 182-186, 231-247`
- **Reported by:** sec-rule (reported LOW)
- **Verification:** combined: confirmed -> LOW

**Problem**

`targetUnits` calls `_market(tokens)` for every component before looking at `keepMask` (src/IndexRule.sol:129). `_market` reverts for any single component whose price or supply is unusable:
- `prices[i] = _price(tokens[i], config.pool)` reverts `ZeroPrice` when the mean-tick quote rounds to 0 (line 185).
- `if (supplies[i] == 0) revert ZeroSupply` (line 244).
- `caps[i] = supplies[i] * prices[i]` hits a checked overflow (line 245).

IndexToken.startRebalance (src/IndexToken.sol:236) calls this through `_previewTarget` for kept components too. ARCHITECTURE.md section 5 presents the guardian's keep mask as the way to rebalance around a broken component.

Failure scenario: a listed component's configured WETH pool loses all in-range liquidity, for example after a token migration. Anyone can then swap it to an extreme tick for gas only. For token0 a tick below about -414,487 makes 1e18 raw units worth under 1 wei, so `_quoteAtTick` returns 0. For token1 the same happens above +414,487. Once the 30-minute TWAP sits there, every index holding that token reverts `ZeroPrice` in `startRebalance`, with or without the keep mask. Only a timelocked (2-day) owner config change to another pool of that token restores rebalancing, and no such pool may exist with 200 observation slots.

Under UNCAPPED a kept component's price and supply cancel out of the targets:
- Its lo = hi = units, so it adds the same u*price to `value` and `totalValue` in `_redistribute`.
- Active weights are renormalised by `activeWeight` in `_targets`.

The revert is therefore unnecessary there. Under CAPPED the kept cap still matters for ranking. Holders can still redeem, so the impact is a rebalancing stall, not a loss of funds.

**Proposed fix (reviewer)**

src/IndexRule.sol: for the uncapped methodology, skip market reads for kept components. Their weight is renormalised away and their units are pinned.
```diff
@@ function targetUnits(...)
-        (uint256[] memory prices,, uint256[] memory caps) = _market(tokens);
+        (uint256[] memory prices,, uint256[] memory caps) =
+            _market(tokens, methodology == Methodology.UNCAPPED ? keepMask : 0);
@@
-    function _market(address[] calldata tokens)
+    function _market(address[] calldata tokens, uint256 skipMask)
@@
         for (uint256 i = 0; i < n; ++i) {
+            if (_kept(skipMask, i)) continue; // price 0 and cap 0: pinned, contributes 0 to value and totalValue
             IIndexFactory.TokenConfig memory config = IIndexFactory(FACTORY).tokenConfig(tokens[i]);
```
Other callers (`weights`, `initialUnits`) pass 0. `_bound` needs no change: a zero-priced kept component has value 0 and is never eligible in `_shift`. `_uncappedWeights` still reverts `DegenerateBasket` only if every active cap is 0.

Add a test: list 5 tokens, make token 4's pool TWAP quote 0, and check that guardian `startRebalance(1 << 4)` succeeds on an uncapped index while `startRebalance(0)` reverts `ZeroPrice(token4)`.

For CAPPED, state in ARCHITECTURE.md section 5 (Known limitations) that a component with an unusable price blocks rebalancing even when kept, until the owner reconfigures its pool.

**Verifier (combined): confirmed -> LOW**

Reachability: `IndexToken.startRebalance` calls `_previewTarget(keepMask)` (src/IndexToken.sol:236, 352-354), which calls `IndexRule.targetUnits`. At src/IndexRule.sol:129 that function calls `_market(tokens)` for every component before `keepMask` is read. `_market` (lines 240-246) runs `_price` for each component, and `_price` reverts `ZeroPrice` when `_poolPrice` returns 0 (line 185). It also reverts `ZeroSupply` (line 244) and does a checked `supplies[i] * prices[i]` (line 245). So the keep mask cannot get past a component whose price reads fail. `_checkPool` checks for a nonzero price only at listing (line 179), not later.

A 30-minute mean tick at an extreme stops rebalancing for every index holding the token until the owner changes its config. Extreme ticks are:
- about -414k for token0, or +414k for token1, which quote to 0;
- or near MAX_TICK, where the WAD price is about 3.4e56 and a supply of 1e27 overflows `caps`.

This is cheap to cause on a pool with no in-range liquidity. The attacker must hold the tick there for the whole TWAP window, and anyone can push it back just as cheaply. That is a real limit on the griefing.

Impact: rebalancing stalls only. Holders keep issue, redeem and redeemSkipping, so no funds are lost. LOW fits.

Design intent: ARCHITECTURE.md presents the keep mask as the way to rebalance around a broken component (the frozen-component flow near line 186, and "a keep mask rebalances around it" in Token behaviour). Known limitations cover only a permanently frozen component and say nothing about a component whose price fails. So this is not documented-accepted.

The uncapped claim holds in source. For a kept component, `_bound` sets lo = hi = u and adds u*price only to `totalValue`, not to `activeValue` or `activeWeight`. `_targets` renormalises active weights by `activeWeight`, and `_redistribute` adds the same u*price on both sides. Setting that price to 0 therefore leaves the active targets unchanged, apart from how the uncapped weights normalise (their ratios are the same). Turnover counts only sold legs, so it is unaffected too.

*PoC:* Not run. The decisive claim is a structural fact visible in source: `_market` is called unconditionally, before `keepMask` is consulted, and it reverts per component. Building a mock-pool scenario would not add evidence.

*Fix assessment:* The uncapped fix is correct and follows CLAUDE.md:
- The rule stays stateless and nothing is computed from balances.
- A skipped component gets price 0 and cap 0. `_uncappedWeights` gives it weight 0, and `_bound` then lifts that to 1 wei.
- It is pinned, so it contributes 0 to value in `_redistribute` and is never eligible in `_shift`, because lo = hi.
- `_targets` never divides by the price of a kept component, since the kept branch returns `units[i]`.

Guard to add: if every non-kept cap is 0, `DegenerateBasket` still reverts, which is fine.

The fix is incomplete for CAPPED. A kept component still needs its cap for ranking, so the proposed documentation note in ARCHITECTURE.md section 5 is required. The note should also say that `navPerToken` reverts for any index holding the token.

Alternative for both methodologies: when a component is kept, catch its failure and fall back to its last known weight. That would add state, so it is rejected; documenting the limitation is the compliant option.

Make the `_market` skip conditional on the methodology exactly as proposed, so `weights` and `initialUnits` keep strict checks by passing a mask of 0.

*Tests a fix must add:*

- Uncapped index with 5 components where token 4's pool TWAP quotes 0: guardian startRebalance(1<<4) succeeds and targets for tokens 0-3 match those from a normal price; startRebalance(0) reverts ZeroPrice(token4)
- Uncapped index where a kept component has referenceSupply 0 and circulating supply 0: startRebalance with its bit set succeeds
- Uncapped index where a kept component's cap would overflow (tick near MAX_TICK): startRebalance with its bit set succeeds
- Capped index with a kept component whose price is zero: still reverts ZeroPrice (documents the limitation)
- weights() and initialUnits() still revert ZeroPrice for a zero-priced component (mask 0 is passed)
- Uncapped index where every non-kept component has zero cap: reverts DegenerateBasket

### XA-06 [LOW] ConfigureWhitelist execute mode lists whatever config is pending, ignoring the WHITELIST entry it was run with

- **Dimension:** Security (silent-wrong-config)
- **Location:** `script/ConfigureWhitelist.s.sol:180-196, 206-210`
- **Reported by:** sec-scripts (reported LOW)
- **Verification:** combined: confirmed -> LOW

**Problem**

`execute` looks only at the token address: `uint256 eta = factory.listingEta(token); ... } else { factory.executeListing(token); console2.log("listed", token); }` (script/ConfigureWhitelist.s.sol:184-192). It never compares `factory.pendingTokenConfig(token)` with `configFor(list[i], ...)`. `_shouldPropose` also returns early with just `"already pending"` (lines 207-209) without checking whether the pending config is the one the list asks for. Failure scenario: a proposal for WBTC with a different pool or reference supply is pending. It could come from an earlier WHITELIST typo, a manual Safe transaction, or a batch built from an older list. The operator runs `LISTING_MODE=propose|safe WHITELIST=default`, which logs "already pending", then `LISTING_MODE=execute WHITELIST=default`, which logs "listed". The factory now holds a config that is not in the default list, and nothing in either run flags it. The PoC (test/poc/ScriptsSec.t.sol in a scratch copy) proposes tokenB with referenceSupply 1 while the list says 21_000_000e8. `propose` then skips it, `execute` lists it, and `tokenConfig(tokenB).referenceSupply == 1`, so tokenB's market cap and its target units become about 0 at the next rebalance. Mitigations: only the owner can propose, the 2-day delay gives the guardian time to cancel, and the event shows the config. This is why the severity is LOW rather than higher. Still, the script's own record of what was listed is misleading, and the check fails open.

**Proposed fix (reviewer)**

script/ConfigureWhitelist.s.sol: fail closed (skip and log) when the pending config differs from the entry, in both execute and _shouldPropose.

```diff
     function execute(IndexFactory factory, Entry[] memory list) public {
+        IIndexRule rule = IIndexRule(factory.RULE());
+        address weth = rule.WETH();
+        address uniswapV3Factory = rule.UNISWAP_V3_FACTORY();
         vm.startBroadcast();
         for (uint256 i = 0; i < list.length; ++i) {
             address token = list[i].token;
             uint256 eta = factory.listingEta(token);
             if (eta == 0) continue;
-            if (block.timestamp < eta) {
+            if (!_sameConfig(factory.pendingTokenConfig(token), configFor(list[i], weth, uniswapV3Factory))) {
+                console2.log("pending config differs from the entry, not executed", token);
+            } else if (block.timestamp < eta) {
```

and in `_shouldPropose`:

```diff
         if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
-            console2.log("already pending", token);
+            if (_sameConfig(factory.pendingTokenConfig(token), config)) console2.log("already pending", token);
+            else console2.log("a DIFFERENT config is pending; cancel it first", token);
             return false;
         }
```

Add a test in test/Scripts.t.sol that proposes a mismatching config directly and asserts `execute` leaves `isWhitelisted(token) == false`.

**Verifier (combined): confirmed -> LOW**

Reachability: `execute` (script/ConfigureWhitelist.s.sol:180-196) keys only on `factory.listingEta(token)` and the time window. It calls `factory.executeListing(token)` without reading `factory.pendingTokenConfig(token)`, and `IndexFactory.executeListing` (src/IndexFactory.sol:205-226) copies whatever `_pendingConfig[token]` holds. `_shouldPropose` (lines 206-210) returns false with "already pending" whenever a proposal is inside its window. It does not compare that proposal with the entry's `config`, even though the same function does compare configs for tokens that are already listed (line 211 uses `_sameConfig`). So if a different config is pending, from a typo, a manual Safe transaction or an older list, a propose run followed by an execute run with the correct list logs "already pending" and then "listed". The factory ends up holding a config that is not in the list, and neither run flags it.

Impact: bad market data (pool or reference supply) goes live for the rule's targets. Mitigations: only the owner can create the mismatching proposal, the 2-day delay lets the guardian cancel it, `ListingProposed` and `TokenConfigured` log the config, and anyone can call `executeListing` directly anyway. So this is an operator-tooling problem: a check that fails open plus a misleading log. It is not something an outsider can exploit. LOW is right.

Design intent: the README (around line 273) says propose covers "every entry that is not pending and not already listed with exactly its config". That describes the skip but not the risk that a different pending config gets executed, so the risk is not documented.

*PoC:* Not run. The decisive behaviour is plain in source: `execute` never reads the pending config, and `executeListing` copies it unconditionally. The reporter's PoC (tokenB proposed with referenceSupply 1, then propose skips it and execute lists it) matches this control flow exactly.

*Fix assessment:* The proposed fix is correct and CLAUDE.md-compliant: script-only, logic stays in public functions that take explicit arguments, and `_sameConfig` is reused. It fails closed in `execute` and warns in `_shouldPropose`. Two details:
1. In `execute`, fetch `rule`, `weth` and `uniswapV3Factory` before `vm.startBroadcast()`, as the diff does. `configFor` looks up the pool through `getPool` (a view), so it adds no broadcast.
2. Also correct the misleading comment at line 185. `eta == 0` means nothing is pending; it does not mean the token is listed with this config.

Optional: in `execute`, when `eta == 0`, `isWhitelisted` is true and the listed config differs from the entry, log "listed config differs from the entry". That would complete the "record of what was listed" goal.

*Tests a fix must add:*

- execute with a pending config whose referenceSupply differs from the entry: asserts isWhitelisted(token) == false and listingEta unchanged
- execute with a pending config whose pool (fee tier) differs from the entry: not executed
- execute with a pending config whose excluded list differs: not executed
- execute with a matching pending config still lists (regression of the happy path)
- propose/safeCalldata with a different config pending: returns no call for that token (and logs the mismatch)
- test coverage stays 100% for script/ConfigureWhitelist.s.sol including the new branches

### XA-07 [LOW] Mainnet owner check trusts Safe getThreshold only, so a Safe with an enabled module (single-key execution path) passes

- **Dimension:** Security (key-custody)
- **Location:** `script/Deploy.s.sol:82-96`
- **Reported by:** sec-scripts (reported LOW)
- **Verification:** combined: confirmed -> LOW

**Problem**

On chain 1, `checkOwner` accepts any contract whose `getThreshold()` returns 32 bytes >= 2: `(bool ok, bytes memory data) = owner.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ())); if (ok && data.length == 32) { ... if (threshold < 2) revert OwnerThresholdTooLow(...) }` (Deploy.s.sol:91-95). Safe modules bypass the threshold entirely: `execTransactionFromModule` lets an enabled module act as the Safe with no signatures. Failure scenario: an owner Safe is set to 2-of-3 but has a module enabled, such as a leftover Allowance/Roles/recovery module or one controlled by a single EOA. The script accepts it. That one key can then `proposeListing` any config, `proposeGuardian`, or `transferOwnership` without a second signature. This defeats the documented requirement that a Safe owner must need at least two signatures (CLAUDE.md, .env.example line 9, README Deploy). A contract that is not a Safe and has no `getThreshold`, such as a 1-of-1 smart-wallet forwarder, is also accepted as-is (line 88 comment). That behaviour is documented, but it means the two-signature guarantee depends on the operator.

**Proposed fix (reviewer)**

script/Deploy.s.sol, inside the `if (ok && data.length == 32)` branch, also require no enabled modules (Safe `getModulesPaginated(address(0x1), 1)` returns an empty array):

```diff
         if (ok && data.length == 32) {
             uint256 threshold = abi.decode(data, (uint256));
             if (threshold < 2) revert OwnerThresholdTooLow(owner, threshold);
+            // forge-lint: disable-next-line(low-level-calls)
+            (bool mok, bytes memory mdata) =
+                owner.staticcall(abi.encodeWithSignature("getModulesPaginated(address,uint256)", address(1), 1));
+            if (mok) {
+                (address[] memory modules,) = abi.decode(mdata, (address[], address));
+                if (modules.length != 0) revert OwnerHasModules(owner, modules[0]);
+            }
         }
```

Add `error OwnerHasModules(address owner, address module);`. Extend `MockSafe` in test/Scripts.t.sol with `getModulesPaginated` and add a test in `test_checkOwner` that expects `OwnerHasModules` for a mock Safe with one module.

**Verifier (combined): confirmed -> LOW**

Reachability: script/Deploy.s.sol:82-96 `checkOwner` on chain 1 only checks for code, rejects EIP-7702 delegation, and then, if `getThreshold()` returns one word, requires threshold >= 2. It never looks at Safe modules (or guards). A Safe's `execTransactionFromModule` lets any enabled module act as the Safe without owner signatures. So a 2-of-3 Safe with a module controlled by one EOA passes, and that key alone can run owner-only factory actions: proposeListing, proposeGuardian and transferOwnership. The timelocks still apply. Design intent: CLAUDE.md, README.md:266, ARCHITECTURE.md:285 and .env.example:9 all say "a Safe must need at least two signatures". Nothing mentions modules, so this is not documented as accepted.

Why the severity stays LOW:
- This is a deploy-time sanity check on an address the operator picks. It is not an on-chain control.
- A 2-of-3 Safe can enable a module after deployment anyway, so no deploy-time check can keep this guarantee.
- Owner actions are timelocked (LISTING_DELAY / GUARDIAN_DELAY), the guardian can cancel listings, and the owner has no direct power over funds.

*PoC:* Not run. The claim is a static fact: the function has no module check, as the source above shows. A runtime PoC would need a Safe mock with a module, which adds nothing beyond reading the function.

*Fix assessment:* The proposed fix works in principle and fits CLAUDE.md: the change is script-only, and the lint suppression comes with a reason. It is fragile, though. `abi.decode(mdata, (address[], address))` reverts with no error name if a contract returns success with short or odd data, for example through a fallback. Before decoding, require `mok && mdata.length >= 96`. Also note that the Safe sentinel is `address(0x1)`, and that pageSize 1 is enough. For completeness, also read the Safe guard slot (`getStorageAt(GUARD_STORAGE_SLOT)`), or at least say in docs that modules and guards can be added after deployment. Change the doc wording in README.md:266, ARCHITECTURE.md:285 and .env.example:9 to "a Safe must need at least two signatures and have no enabled modules at deployment; keep it that way". Without that change the fix is incomplete, because a module enabled later bypasses it.

*Tests a fix must add:*

- test_checkOwner reverts OwnerHasModules for a chain-1 mock Safe with threshold 2 and one enabled module
- test_checkOwner accepts a threshold-2 mock Safe whose getModulesPaginated returns an empty array
- test_checkOwner does not revert without a reason on a contract with getThreshold whose getModulesPaginated returns malformed/short data (define the intended behaviour)

### XA-08 [LOW] Unsold-part return (I12 fix) covers only the first hop; a partial fill on a later hop of a multi-hop burn leg leaves the user's intermediate tokens in SwapRouter02

- **Dimension:** Security (incomplete-fix / partial-fill accounting)
- **Location:** `src/IndexZap.sol:26-30, 271-296`
- **Reported by:** r2-sec-core (reported LOW)
- **Verification:** combined: partially-confirmed -> LOW

**Problem**

The zap promises (IndexZap.sol:28-30, CLAUDE.md design rule "send the unsold part of a partially filled leg to the recipient", ARCHITECTURE.md:152): "When the router takes less of a component than it was given, because a pool reached its price limit ..., the unsold part goes to the recipient instead of being stranded or blocking the burn." `_sell` measures only the component (the first token of the path):

```solidity
278 uint256 before = token.balanceOf(address(this));
280 amountOut = ROUTER.exactInput(ExactInputParams({path: leg.path, recipient: address(this), amountIn: amountIn, amountOutMinimum: leg.minAmountOut}));
289 uint256 unsold = amountIn - (before - token.balanceOf(address(this)));
```

`_checkPath` (IndexZap.sol:319-323) accepts multi-hop paths. In SwapRouter02 (V3SwapRouter.exactInput, deployed source; not vendored in lib/), each intermediate hop is swapped with `recipient = address(this)` (the router), `payer = address(this)` and `params.amountIn` set to the previous hop's output. `exactInputInternal` passes no price limit (it uses MIN/MAX_SQRT_RATIO +/- 1) and never checks that the pool took all of `amountIn`. Only `exactOutputInternal` has `require(amountOutReceived == amountOut)`, so mint legs are safe. So when hop 2 or later fills partially, what that hop did not sell stays in the router, and anyone can take it with the router's public `sweepToken(token, amountMinimum)`.

Scenario: a burn leg LINK -> WETH -> USDC. Hop 1 sells 100% of `got[i]` and the router receives 10 WETH. Hop 2 runs into a WETH/USDC pool whose in-range liquidity runs out after 6 WETH. The zap sees the LINK fully sold, so `unsold == 0` and nothing is returned. 4 WETH (~40% of the leg) stays in SwapRouter02 and a searcher sweeps it. `amountOut` counts only the 6 WETH's USDC. Outcomes: (a) the usual case: the leg or overall minimum is set near the quote, the burn reverts with "Too little received" or InsufficientOutput, and the burn is blocked. That is the outcome FR01/I12 were meant to prevent, and the user has to re-route. (b) The user set a loose tolerance (a leg minimum of 0 means "overall limit only", IndexZap.sol:23-25) that the other legs cover: the burn succeeds and the stranded intermediate tokens are lost to the sweeper, not returned as the natspec promises. Either way the loss is capped by the user's own minimums, and it needs a later-hop pool to run dry, hence LOW. The I12 regression test (test/Security.t.sol:562-588) and MockPartialFillRouter only model a single-hop partial fill (`safeTransferFrom(firstToken, used)`), so the gap is not exercised.

**Proposed fix (reviewer)**

src/IndexZap.sol:271-296. Run each hop as its own single-hop exactInput with the zap as recipient. Measure and return the unsold input of every hop. Apply the leg minimum on the final hop. Stop on a zero intermediate output, so SwapRouter02's CONTRACT_BALANCE sentinel (amountIn == 0) can never spend tokens already sitting in the router.

```diff
     function _sell(BurnParams calldata p, address component, uint256 amountIn, uint256 i)
         private
         returns (uint256 amountOut)
     {
         BurnLeg calldata leg = p.legs[i];
         _checkPath(leg.path, component, p.tokenOut, i);
-        IERC20 token = IERC20(component);
-        uint256 before = token.balanceOf(address(this));
-        token.forceApprove(address(ROUTER), amountIn);
-        amountOut = ROUTER.exactInput(
-            ISwapRouter02.ExactInputParams({
-                path: leg.path, recipient: address(this), amountIn: amountIn, amountOutMinimum: leg.minAmountOut
-            })
-        );
-        uint256 unsold = amountIn - (before - token.balanceOf(address(this)));
-        if (unsold != 0) {
-            token.forceApprove(address(ROUTER), 0);
-            emit ComponentReturned(p.index, p.to, component, unsold);
-            token.safeTransfer(p.to, unsold);
-        }
+        bytes calldata path = leg.path;
+        address hopIn = component;
+        amountOut = amountIn;
+        while (true) {
+            bool last = path.length == PathLib.ADDR_SIZE + PathLib.HOP_SIZE;
+            IERC20 token = IERC20(hopIn);
+            uint256 given = amountOut;
+            uint256 before = token.balanceOf(address(this));
+            token.forceApprove(address(ROUTER), given);
+            amountOut = ROUTER.exactInput(
+                ISwapRouter02.ExactInputParams({
+                    path: path[:PathLib.ADDR_SIZE + PathLib.HOP_SIZE],
+                    recipient: address(this),
+                    amountIn: given,
+                    amountOutMinimum: last ? leg.minAmountOut : 0
+                })
+            );
+            uint256 unsold = given - (before - token.balanceOf(address(this)));
+            if (unsold != 0) {
+                token.forceApprove(address(ROUTER), 0);
+                emit ComponentReturned(p.index, p.to, hopIn, unsold);
+                token.safeTransfer(p.to, unsold);
+            }
+            if (last) break;
+            if (amountOut == 0) revert InsufficientOutput(0, leg.minAmountOut); // never hit the CONTRACT_BALANCE sentinel
+            hopIn = address(bytes20(path[PathLib.HOP_SIZE:PathLib.HOP_SIZE + PathLib.ADDR_SIZE]));
+            path = path[PathLib.HOP_SIZE:];
+        }
     }
```
(An intermediate hop may output `tokenOut`. That is still correct, because `_burnBasket` measures the final `tokenOut` balance delta after every leg. `ComponentReturned` could be renamed or documented to cover intermediate tokens as well.)

Regression test, in test/Security.t.sol next to test_I12: add a `MockMultiHopPartialRouter` whose `exactInput` on a 2-hop path pulls all of the first token, then fills only half of the second hop and keeps the rest of the intermediate token. Burn an index through a path COMP -> WETH -> USDC with `minAmountOut` loose enough to pass. Assert that the half of the intermediate WETH the router did not sell reaches `alice` (`weth.balanceOf(alice) == expected`) and that `weth.balanceOf(address(router)) == 0`. Against the current code the test fails: alice gets 0 WETH and the router keeps it.

**Verifier (combined): partially-confirmed -> LOW**

The code does what the finding says. `_sell` (src/IndexZap.sol:271-296) only checks how much of the first token of the path, the component, left the zap: `uint256 unsold = amountIn - (before - token.balanceOf(address(this)));`. `_checkPath` (lines 319-323) only checks the path's shape and its two ends, so multi-hop burn paths are allowed. In SwapRouter02's `exactInput`, the router itself pays every hop after the first, out of its own balance. `exactInputInternal` never requires the pool to take all of `amountIn`. So an intermediate token that a later hop does not sell stays in the router, where anyone can take it with `sweepToken`. The natspec at lines 28-30 and ARCHITECTURE.md:152 promise that the unsold part of a partial fill goes to the recipient. That promise only covers the component (hop 1).

The scenario overstates how easy this is to trigger. `exactInputInternal` passes `sqrtPriceLimitX96 = 0`, which the router turns into MIN_SQRT_RATIO+1 or MAX_SQRT_RATIO-1. A V3 pool's swap loop then keeps crossing initialized ticks until the input is used up or the price hits that extreme. "In-range liquidity runs out after 6 WETH" therefore does not produce a partial fill. The swap just carries on into the liquidity at other ticks. A later hop fills partially only when the intermediate pool has no liquidity left at all on that side. The first-hop case the zap already handles needs the same condition. In practice that means a user or frontend routing through a nearly empty intermediate pool. If that happens, a leg minimum near the quote reverts the burn. With a loose minimum, the burn succeeds and the leftover intermediate tokens can be swept by anyone. The loss is capped by the user's own minimums. LOW stands, and the case is close to INFO. The docs do not mention this gap, so documented-accepted does not apply.

*PoC:* Not run. A mock router would simply build in the claim being tested, and a fork PoC would need a real pool with no liquidity left on one side. The decision rests on reading IndexZap.sol and the Uniswap V3 router and pool swap logic.

*Fix assessment:* The proposed fix (one single-hop `exactInput` per hop, returning each hop's unsold input, and applying the leg minimum on the last hop) is correct in direction. It fits the CLAUDE.md rules: the zap stays stateless, output is still measured as balance changes, and the path endpoints are still checked.

It has one gap. If an intermediate hop's input token equals `p.tokenOut`, sending that unsold amount to `p.to` lowers the zap's `tokenOut` balance change that `_burnBasket` measures. That can make the reported output wrong or make the burn revert. Fix this in one of two ways: reject paths whose intermediate tokens equal `tokenOut` or the component in `_checkPath`, or keep unsold `tokenOut` in the zap so it is counted in the payout. The fix also costs more gas per hop.

A cheaper option that is just as safe is to limit burn legs to paths where no intermediate pool can drain. That cannot be enforced on-chain, so the minimum acceptable change is to correct the natspec and ARCHITECTURE.md:152 to say that only first-hop unsold amounts are returned.

*Tests a fix must add:*

- A 2-hop burn leg (component -> WETH -> tokenOut) where hop 2 fills partially: the intermediate WETH reaches the recipient and the router's balance is 0
- An intermediate hop token equal to tokenOut: the payout accounting stays correct, or the path is rejected with BadPath
- An intermediate hop with zero output reverts instead of reaching the CONTRACT_BALANCE sentinel (amountIn == 0)
- The leg minAmountOut is applied only to the final hop's output and still reverts with the router's error or InsufficientOutput when the output is too low

### XA-09 [LOW] MIN_OBSERVATION_CARDINALITY = 200 only covers the 30-minute TWAP while slots stay 12 seconds, and nothing ties the two together

- **Dimension:** Hazard (brittle-default)
- **Location:** `src/IndexRule.sol:29-31, 170-180, 190-202`
- **Reported by:** hazard-enforce (reported MEDIUM); also H-3
- **Verification:** combined: partially-confirmed -> LOW

**Problem**

Hazard: the rule's promise that a pool 'can never run out of history' (IIndexRule.sol:30, ARCHITECTURE.md section 2 'so a 30-minute average can never run out of history') depends on the length of an Ethereum slot. That dependency is written down only in a comment. Code: `uint32 public constant TWAP_WINDOW = 30 minutes;` and `/// @dev Pools write at most one observation per 12-second block, so 200 slots always cover 40 minutes.` `uint16 public constant MIN_OBSERVATION_CARDINALITY = 200;` (IndexRule.sol:29-31). The listing check at IndexRule.sol:178 compares the ring size to this constant once, when a token is listed. `_poolPrice` (IndexRule.sol:195) then calls `observe([1800, 0])` at every `startRebalance`, `navPerToken` and `weights` call for as long as the index exists.

Shape: the constant is derived from two values, TWAP_WINDOW and the chain's slot time. Only TWAP_WINDOW is a constant in the code. The only test pins the literal (`assertEq(rule.MIN_OBSERVATION_CARDINALITY(), 200)`, test/IndexRule.t.sol:109). The mock pool (test/mocks/MockUniswapV3.sol:69) signals short history with a boolean flag, not with time, so no test re-derives the bound.

Production scenario: Uniswap V3 writes at most one observation per block. A pool touched every block with a ring of 200 covers 200 x 12 s = 2400 s today, which is enough for an 1800 s window. If slots shrink to 6 s (EIP-7782 proposes this), the ring covers 1200 s < 1800 s. `observe` then reverts with "OLD" whenever the pool traded in more than 150 of the last 300 blocks. tBTC's pool is the kind of token ARCHITECTURE.md section 5 says must be grown to 200. Any index holding such a token then hits:
- `startRebalance` reverts for every holder of the token, because `_market` prices all components.
- `navPerToken` and `initialUnits` revert.
- The listing check still passes for new pools that were grown before the change.

No funds are lost, because issue and redeem do not read prices. Rebalancing stops quietly for exactly the actively traded tokens, and on-chain config gives no hint of the cause. The fix is permissionless (`increaseObservationCardinalityNext`, about 20k gas per slot, so about 4M gas to double a ring), but nothing in the docs names it for this case.

**Proposed fix (reviewer)**

Derive the constant from an explicit, conservative slot time, and add a test that fails when either input changes.

src/IndexRule.sol:29-31
```diff
     uint32 public constant TWAP_WINDOW = 30 minutes;
-    /// @dev Pools write at most one observation per 12-second block, so 200 slots always cover 40 minutes.
-    uint16 public constant MIN_OBSERVATION_CARDINALITY = 200;
+    /// @dev Pools write at most one observation per block. Sized for 6-second slots (EIP-7782) with a third of
+    ///      headroom, so a ring that is actively written still covers TWAP_WINDOW if slot times shrink.
+    uint32 private constant MIN_SLOT_SECONDS = 6;
+    uint16 public constant MIN_OBSERVATION_CARDINALITY = uint16(TWAP_WINDOW * 4 / 3 / MIN_SLOT_SECONDS); // 400
```
test/IndexRule.t.sol (next to line 109):
```solidity
function test_cardinalityCoversTwapWindowAtShortSlots() public view {
    // 6-second slots, one observation per block, with a third of headroom
    assertGe(uint256(rule.MIN_OBSERVATION_CARDINALITY()) * 6, uint256(rule.TWAP_WINDOW()) * 4 / 3);
}
```
Update ARCHITECTURE.md section 5 'Operations' to match: when `startRebalance` reverts with "OLD", anyone can call `increaseObservationCardinalityNext` on the pool. If raising the listing requirement is not wanted, at least add the derivation test for 12 s and write the slot-time assumption into ARCHITECTURE.md section 5.

**Verifier (combined): partially-confirmed -> LOW**

I checked the source and the mechanism is real. `TWAP_WINDOW = 30 minutes` and `MIN_OBSERVATION_CARDINALITY = 200` sit at src/IndexRule.sol:29-31, and the comment there gives 12-second blocks as the reason. `_checkPool` (IndexRule.sol:170-180) compares the pool's current cardinality to 200 once, at listing. `_poolPrice` (IndexRule.sol:190-202) then calls `observe([1800, 0])` on every price read after that. Uniswap V3's Oracle.write writes at most one observation per block timestamp. So a ring of 200 covers at least 199 x 12 s, about 2388 s, which is enough today. If slot times ever fell below 9 s, a pool touched every block would fail `observe` with "OLD".

Most of the rest of the claim holds up, but the severity does not:
(1) Reachability depends entirely on a hard fork that has not been scheduled (EIP-7782 is only a proposal). Nothing can trigger this on today's mainnet, so it is a latent hazard, not a present defect.
(2) The impact is liveness only. Issue, redeem, redeemSkipping and claim never read prices, so holders keep full in-kind exit. `startRebalance`, `navPerToken` and `weights` would revert for indexes holding a busy low-cardinality token.
(3) Anyone can fix it for the affected pool by calling `increaseObservationCardinalityNext`. ARCHITECTURE.md section 5 (lines 286-287) already names this call, but only as a listing prerequisite.
(4) The docs do state the 200-slot rule. What they misstate is the guarantee: "can never run out of history" (IIndexRule.sol:30, ARCHITECTURE.md:116) is true only under the 12-second slot assumption. That assumption appears in a code comment and nowhere in the docs.
A future-fork assumption with a permissionless remedy and no risk to funds is LOW, not MEDIUM. It is not documented-accepted, because the docs claim an unconditional guarantee.

*PoC:* Not run. The failure needs block times under 9 s, and neither the mock pool (short history is a boolean flag) nor a mainnet fork (12 s slots) can model that without re-implementing Uniswap's Oracle ring buffer. The arithmetic is exact: 200 slots x 12 s is about 2388 s, which covers 1800 s; 200 slots x 6 s is about 1194 s, which does not.

*Fix assessment:* The proposed fix is only partly right.
- **Raising to 400:** this is a product and operations trade-off, not a clear improvement. It makes listing harder (tBTC-like pools would need about 200 more slots, roughly 4M gas). It also does nothing for tokens already listed against 200-slot pools, because the check runs only at listing. Pools that were grown ahead of time would still pass.
- **The new test:** it just restates the constant's own formula, so it adds almost no protection.

Corrected fix (keeps every CLAUDE.md design rule):
(a) Keep 200. Rewrite the comment at IndexRule.sol:30 and the notices at IIndexRule.sol:30 and ARCHITECTURE.md:116 to state the assumption, e.g. "covers TWAP_WINDOW while block times are at least 9 seconds (one observation per block)".
(b) Add to ARCHITECTURE.md section 5 Operations: "If `startRebalance`/`navPerToken` revert with OLD (e.g. after a slot-time reduction), anyone can call `increaseObservationCardinalityNext` on that component's pool; issue and redeem are unaffected."
(c) Optionally define `MIN_BLOCK_SECONDS = 9` and set `MIN_OBSERVATION_CARDINALITY = uint16(TWAP_WINDOW / MIN_BLOCK_SECONDS)`, which is exactly 200, so the dependency lives in code.
If the owner does choose 400, record it as a policy change in ARCHITECTURE.md, and update the tBTC note and the test at IndexRule.t.sol:109.

*Tests a fix must add:*

- If the constant is re-derived: a test asserting MIN_OBSERVATION_CARDINALITY * MIN_BLOCK_SECONDS >= TWAP_WINDOW
- If the threshold changes: `_checkPool` reverts with PoolHistoryTooShort(pool, 399) for a pool one slot below the new minimum, and accepts one at the minimum
- Existing test_ constant assertion at test/IndexRule.t.sol:109 updated to the new value

### XA-10 [LOW] CI does not enforce the lint-free, 100%-coverage, Wake-clean or fork-test gates that CLAUDE.md requires

- **Dimension:** Hazard (convention-vs-enforcement)
- **Location:** `.github/workflows/test.yml:61-75`
- **Reported by:** hazard-enforce (reported MEDIUM); also R1-process-5, R1-hazard-ops-6, H-10, R1-docs-prose-8
- **Verification:** combined: confirmed -> LOW

**Problem**

Hazard: CLAUDE.md's 'Definition of done' items 2 (lint-free build), 3 (100% coverage), 4 (fork tests when relevant) and 5 (Wake clean) are enforced only by discipline. CI runs `forge build --sizes` (test.yml:62) and `forge test -vvv` (test.yml:75), nothing else.

Shape, verified in a private copy with Forge 1.8.1 (the version pinned at test.yml:53). I added `src/LintProbe.sol` with a mixed-case variable, a mixed-case function, a low-level call and a missing zero check. `forge build --sizes` printed four lint diagnostics (1 warning, 3 notes) and exited 0. `forge lint` also exited 0. Only `forge lint -D notes` exited 1, and it exits 0 on the clean tree. So CI's 'Run Forge build' step passes with lint findings.

The workflow has no `forge coverage` step and no Wake step. The fork suites skip themselves when `MAINNET_RPC_URL` is empty (test/fork/Rebalance.fork.t.sol:45). The only guard is 'Require the fork-test RPC on main' (test.yml:64-72), which fires only on `push` to `refs/heads/main`, after merge. Pull requests from forks never receive secrets, so fork tests are skipped there.

Production scenario: a later change to IndexZap or IndexRule does one of these and still passes CI green:
- adds a `// forge-lint`-worthy pattern;
- drops a branch below 100% coverage;
- introduces a Wake reentrancy detection outside the three documented suppressions.
Its fork tests are skipped silently on the PR. The first signal is after merge, or never for lint, coverage and Wake.

**Proposed fix (reviewer)**

.github/workflows/test.yml, after 'Run Forge build' (line 62):
```diff
       - name: Run Forge build
         run: forge build --sizes
+
+      - name: Run Forge lint (fail on warnings and notes)
+        run: forge lint -D notes
```
After 'Run Forge tests' (line 75):
```diff
+      - name: Require 100% coverage
+        run: |
+          set -euo pipefail
+          forge coverage --no-match-path 'test/fork/*' --report summary | tee coverage.txt
+          if grep -E '^\|' coverage.txt | grep -v -E 'File|Total|---' | grep -v -E '100\.00% \([0-9]+/[0-9]+\) *\| *100\.00% \([0-9]+/[0-9]+\) *\| *100\.00% \([0-9]+/[0-9]+\) *\| *100\.00%'; then
+            echo "::error::coverage below 100%"; exit 1
+          fi
```
Extend the RPC guard at line 65 to pull requests from this repository:
```diff
-        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
+        if: (github.event_name == 'push' && github.ref == 'refs/heads/main') || (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository)
```
Add a Wake job (`pip install eth-wake && wake detect all src`) that fails on any detection, or record in CLAUDE.md that items 3 and 5 are manual.

**Verifier (combined): confirmed -> LOW**

The claim holds in source. .github/workflows/test.yml is the only workflow. Its steps are the submodule-lock check, `forge fmt --check` (l.59), `forge build --sizes` (l.62), an RPC-secret guard only `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` (l.65), and `forge test -vvv` (l.75). It has no coverage step, no Wake step and no lint step that can fail.

I checked the lint claim with Forge 1.8.1, the version CI pins. After adding a file with lint findings, `forge build --sizes` printed warnings (uninitialized-state, missing-zero-check) and notes, and still exited 0. `forge lint -D notes` exited 1 on the probe and 0 on the clean tree, so it works as a gate.

So CLAUDE.md "Definition of done" items 2, 3 and 5 are never checked by CI. Item 4 (fork tests) is also skipped on PRs, where the secret is not passed, and is only required after a push to main.

On documentation: README.md:249-251 accurately says CI runs only fmt, build and tests. But ARCHITECTURE.md:312-313 lists "lint-free forge build, 100% coverage on every file, Wake analyzer clean" as "Gates" and does not say they are manual. The risk is not documented as accepted.

I lowered severity from MEDIUM to LOW. This is a process or enforcement gap with no on-chain exploit path. A regression would still need a reviewer to miss it, and the fork tests are enforced on main after merge.

*PoC:* I did not write a forge test. The probe was a temporary src/LintProbe.sol in /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/lintprobe-verify, with a mixed-case variable and function, a low-level call and a missing zero check.

Commands and decisive output:
- `forge build --sizes`: printed 2 warnings and 2 notes, then EXIT=0.
- `forge lint -D notes` with the probe: probe=1.
- `forge lint -D warnings` with the probe: probeW=1.
- `forge lint -D notes` after removing the probe: clean=0.

*Fix assessment:* Mostly correct. It fits CLAUDE.md because it only touches CI and does not change any contract design rule.

- **Lint:** the `forge lint -D notes` step is correct and verified. It fails on the probe and passes on the clean tree.
- **Coverage:** grepping the summary table is fragile. The column layout changes between Forge versions, and a missing file or an empty table would pass silently. A sturdier check parses `forge coverage --report lcov` and fails when any record has LF!=LH, BRF!=BRH or FNF!=FNH. It should also fail when the lcov file is empty.
- **Coverage scope:** confirm whether 100% is reachable without the fork suites, and whether the build needs `--ir-minimum`. CLAUDE.md requires 100% on mocks and scripts too, so do not exclude them.
- **Fork tests on PRs:** the new RPC guard for same-repo PRs is fine. Add a comment that PRs from forks still skip fork tests, or require a maintainer re-run.
- **Wake:** a job running `wake detect all src` must pin the Wake version and honour the three documented inline suppressions. If that is impractical, change ARCHITECTURE.md:312-313 and CLAUDE.md to say coverage and Wake are manual pre-merge gates. That keeps the docs from overstating what CI enforces.

*Tests a fix must add:*

- The CI lint step fails when a src/ file adds a lint note or warning, and passes on the current tree.
- The CI coverage step fails when one branch in a src/, test/mocks/ or script/ file is left uncovered, and fails when the report is empty.
- The CI coverage step passes at the current commit (247 tests).
- On a same-repo pull request without MAINNET_RPC_URL, the fork-RPC guard fails instead of the fork suites skipping silently.
- The Wake job fails on a new reentrancy detection outside the three documented suppressions, and passes on the current src/.

### XA-11 [LOW] ConfigureWhitelist propose/safe mode re-proposes tokens the guardian delisted, and execute re-whitelists them

- **Dimension:** Hazard (manual-operational-steps)
- **Location:** `script/ConfigureWhitelist.s.sol:10-13, 200-217`
- **Reported by:** hazard-ops (reported MEDIUM)
- **Verification:** combined: confirmed -> LOW

**Problem**

Hazard: the script built for routine refreshes can quietly undo an emergency delist. Shape: `_shouldPropose` skips an entry only if it is pending or `factory.isWhitelisted(token) && _sameConfig(...)` (ConfigureWhitelist.s.sol:211). A delisted token has `isWhitelisted == false`, so it passes and is proposed again, even with an identical config. `IndexFactory.executeListing` then whitelists any token that is not whitelisted (IndexFactory.sol:220-225), and anyone can call it. The script header (10-13) and README:285-286 promise that "a listing the guardian cancelled stays cancelled" but say nothing about delisted tokens. Production scenario: the guardian delists WBTC after a custodian incident. Months later the owner does the documented reference-supply refresh with `LISTING_MODE=safe WHITELIST=default`. The batch contains `proposeListing(WBTC, cfg)`, which looks the same to the Safe signers as a config refresh for LINK or UNI. They sign it, the execute run 2 days later relists WBTC, and users can again create new indexes holding the token the guardian removed. The only defence left is that the guardian notices and cancels within 2 days. PoC (passes): list B through propose/execute; guardian `delist(B)`; `configure.propose(factory, list)` gives `listingEta(B) > 0`; warp 2 days; `configure.execute` gives `isWhitelisted(B) == true`. After a second delist, an identical-config propose still sets `listingEta(B) > 0`.

**Proposed fix (reviewer)**

script/ConfigureWhitelist.s.sol, inside `_shouldPropose` after the pending check (line ~210):
```diff
+        IIndexFactory.TokenConfig memory current = factory.tokenConfig(token);
+        bool everListed = current.pool != address(0) || current.referenceSupply != 0;
+        if (everListed && !factory.isWhitelisted(token) && !_relistAllowed(token)) {
+            console2.log("delisted, skipped (set RELIST to propose it again)", token);
+            return false;
+        }
-        if (factory.isWhitelisted(token) && _sameConfig(factory.tokenConfig(token), config)) return false;
+        if (factory.isWhitelisted(token) && _sameConfig(current, config)) return false;
```
where `_relistAllowed` reads an explicit comma-separated `RELIST` address list (set by exactly one test). Update the header comment and README:285 to say delisted tokens are skipped. Test in test/Scripts.t.sol: list, guardian delists, `configure.propose` leaves `listingEta == 0`, and `safeCalldata` returns length 0.

**Verifier (combined): confirmed -> LOW**

Reachability: script/ConfigureWhitelist.s.sol:206-211 in `_shouldPropose` skips an entry only if it is pending, or if `factory.isWhitelisted(token) && _sameConfig(...)`. `IndexFactory.delist` (IndexFactory.sol:229-243) sets isWhitelisted=false and keeps `_tokenConfig`, so a delisted token with the same config gets past the check. `rule.checkConfig` still accepts it, and it is proposed again. `execute` (script lines 180-195) runs `executeListing` for every due entry. `executeListing` (IndexFactory.sol:205-226) whitelists any token that is not whitelisted (`if (!isWhitelisted[token]) { isWhitelisted[token] = true; ... }`). The script header (lines 11-13) and README ("a listing the guardian cancelled stays cancelled") speak only about cancelled listings. Neither warns that a routine refresh run re-proposes delisted tokens. A second path exists too: a config-change proposal that is still pending when the guardian delists will relist the token when the execute run runs.

Impact is limited, which puts this below MEDIUM:
(a) The owner must still send or sign `proposeListing`. In safe mode the batch shows the token address in the calldata.
(b) The relist only takes effect after LISTING_DELAY = 2 days, with a public `ListingProposed` event, and the guardian can `cancelListing` during that time.
(c) Relisting only lets new indexes include the token again. Existing indexes are unaffected, per README:198 and ARCHITECTURE.md:140, and no funds are at risk directly.

The real harm is an operational footgun: an emergency delist can be quietly undone. That fits LOW.

*PoC:* File: /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/verify-hazard-ops-2/test/poc/Relist.t.sol, test `test_poc_relistAfterDelist`, in a copy of the Scripts.t.sol fixtures. Steps: list A and B through the script; the guardian delists B; run `safeCalldata`, then `propose` again with the identical list; warp LISTING_DELAY; run `execute`.
Command: cd <copy> && forge test --match-path 'test/poc/*' -vv
Decisive output: "safe calls: 1" (only B; A is skipped as already listed), "proposed 0xA4AD...828c" (B), "etaB: 345601", "listed 0xA4AD...828c". The test ends with `assertTrue(factory.isWhitelisted(B))` and passes.

*Fix assessment:* The fix points the right way but is incomplete, and one detail breaks a repo convention.
1) It only guards propose/safe mode. A config-change proposal made while the token was listed, and still pending when the guardian delists, is relisted by `execute`. `execute` needs the same guard: skip `executeListing` when the token is not whitelisted but has an existing config (`tokenConfig.pool != 0 || referenceSupply != 0`), unless it is explicitly allowed. Otherwise log "delisted, pending proposal not executed; guardian may cancelListing".
2) Reading a `RELIST` env var inside the private `_shouldPropose` breaks the CLAUDE.md convention that script logic sits in public functions taking explicit arguments. Parse `RELIST` in `run()` and pass an `address[] relist` argument to `propose`, `safeCalldata` and `execute`. Only `run` reads the env var, and only one test sets it.
3) The "ever listed" test works for WETH (pool 0, referenceSupply non-zero) and for pooled tokens. A token proposed and cancelled before it was ever listed has an empty `_tokenConfig`, so it is correctly treated as never listed.
4) Update the header comment (lines 11-13) and the README paragraph so both say delisted tokens are skipped unless named in RELIST.
Nothing here touches src/ or any design rule; it is script-only.

*Tests a fix must add:*

- propose after the guardian delists, with the identical config: listingEta stays 0 and safeCalldata returns length 0
- propose after delist with a different config (for example a new referenceSupply): still skipped unless the token is in relist
- propose with the token in the relist argument: proposed, and execute re-whitelists it
- a config-change proposal made while listed, then the guardian delists before the ETA: execute does not call executeListing and the token stays delisted unless it is in relist
- a never-listed token (empty tokenConfig) is still proposed normally, including WETH with fee 0 and a referenceSupply
- run() parses a RELIST env var set by exactly one test

### XA-12 [LOW] Only in-repo executor template (test/fork/RebalanceExecutorV3.sol), pointed to by README, lets anyone drain its float

- **Dimension:** Hazard (manual-operational-steps)
- **Location:** `test/fork/RebalanceExecutorV3.sol:26-29, 35-61; README.md:350-352`
- **Reported by:** hazard-ops (reported MEDIUM)
- **Touches a recorded product decision:** yes
- **Verification:** combined: partially-confirmed -> LOW

**Problem**

Hazard: rebalancing needs a third-party executor contract (no bots is a recorded decision, and a backstop executor is backlog), and the only executor in the repo is the one README.md:351 tells people to use ("`test/fork/RebalanceExecutorV3.sol` fills auctions through the Sepolia router"). It is unsafe to hold value. Shape: `onXindexRebalance` never checks that msg.sender is an index with a live auction. It reads `IIndexToken(msg.sender).componentTokens()` and, for every non-zero `amountsIn[i]`, calls `IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i])` (line 60). `setFee` (26-29) has no access control. Every swap uses `amountOutMinimum: 0` (44), and `amountInMaximum` is the whole WETH balance (56). Production scenario: with no protocol executor, the team or a community member deploys this template on mainnet with a WETH float so that auctions actually clear. Any account can then deploy a contract whose `componentTokens()` returns `[WETH]` and call `executor.onXindexRebalance([0], [WETH.balanceOf(executor)], "")`. The first loop skips because amountsOut is 0, and the second sends the whole float to the attacker in one transaction. Short of a full drain, a searcher can sandwich every fill (min out 0, max in = full float), or grief with `setFee(token, wrongTier)` so fills revert and auctions expire. Index holders stay backed, because the post-check protects them, but the operator loses its float and rebalancing silently stops.

**Proposed fix (reviewer)**

Either move the template out of the documented path or harden it. In test/fork/RebalanceExecutorV3.sol:
```diff
+    address public immutable OWNER = msg.sender;
+    address private _active;
-    function setFee(address token, uint24 fee) external {
+    function setFee(address token, uint24 fee) external {
+        require(msg.sender == OWNER);
@@
-    function fill(IIndexToken index) external {
-        index.executeRebalance("");
+    function fill(IIndexToken index) external {
+        require(msg.sender == OWNER);
+        _active = address(index);
+        index.executeRebalance("");
+        _active = address(0);
     }
     function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata) external {
+        require(msg.sender == _active && _active != address(0));
```
and pass per-leg `amountOutMinimum` / `amountInMaximum` limits through `data`. In README.md:351, add: "test-only; unguarded and without slippage limits, never fund it on mainnet".

**Verifier (combined): partially-confirmed -> LOW**

The code defect is real and I reproduced it. `onXindexRebalance` (test/fork/RebalanceExecutorV3.sol:35-61) never checks who is calling it. It trusts `IIndexToken(msg.sender).componentTokens()` (line 36) and, for every non-zero amountsIn, pays `IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i])` (line 60). Anyone can therefore call it from a fake index that lists WETH as its only component and take the whole float. `setFee` (26-29) also has no access control. The swaps use `amountOutMinimum: 0` (44) and `amountInMaximum = full WETH balance` (56).

The finding overstates the impact, though:
1. The file is a test fixture under test/fork/, and its NatSpec says it is for a mainnet fork. No script deploys it.
2. The one README mention (README.md:350-352) sits in the Sepolia test-market section, and that section says faucet tokens have no value. The README does not tell anyone to run it on mainnet.
3. Index holders are unaffected. The only loss is a float the operator chose to put in an unaudited test contract.
4. For this to cost real money, someone has to deploy a file from test/ on mainnet and fund it. That is an off-repo, operator-side choice.

The weakness left is in the docs. Neither the README nor the file header warns that the contract is unguarded and has no slippage limits. There is also no production executor, so an operator may copy the only template the repo has. That makes this LOW, not MEDIUM. It is not documented-accepted, because no doc states this risk.

*PoC:* File: scratchpad/poc/exec-drain/test/poc/ExecDrain.t.sol. A FakeIndex contract returns [WETH] from componentTokens() and calls onXindexRebalance([0],[100e18],"") on an executor holding 100 WETH (the router address is a dummy and is never called). Command: cd scratchpad/poc/exec-drain && forge test --match-path 'test/poc/*' -vv. Output: "[PASS] test_drain()", "executor WETH: 0", "attacker WETH: 100000000000000000000".

*Fix assessment:* The proposed fix is mostly right. Its code is test-only, so it breaks no CLAUDE.md design rule, and executors stay untrusted from the index's side. Problems with it:
1. It uses `require` without a message. CLAUDE.md asks for custom errors (strictly for src/, but keep it consistent).
2. Checking `_active` in `fill` is enough, but restricting `fill` to OWNER is not required for safety. `executeRebalance` sends the callback to msg.sender, which is the executor, so the check `msg.sender == _active` alone blocks fake indexes.
3. Passing per-leg limits through `data` changes how the fork tests call `fill`. Those call sites must be updated.

The simplest complete fix:
- Add a transient `_active` set in `fill` and checked in `onXindexRebalance`.
- Add an owner check on `setFee`.
- Add the README note at line 351: "test-only: unguarded and without slippage limits; never fund it on mainnet".
- Add the same warning to the contract's NatSpec at lines 10-11.

A docs-only fix (README plus NatSpec warning) is also acceptable, since the contract is a fixture.

*Tests a fix must add:*

- A direct external call to onXindexRebalance from a fake index listing WETH reverts and leaves the float untouched
- setFee from a non-owner reverts
- fill still settles a real auction in the existing fork rebalance tests after the _active guard is added
- The callback reverts when _active is unset, i.e. after fill returns

### XA-13 [LOW] Mainnet deploy/listing inputs are unverified literal copies of the fork-verified ForkAddresses; no fork test runs Deploy or the default whitelist

- **Dimension:** Hazard (multiple-sources-of-truth)
- **Location:** `script/ConfigureWhitelist.s.sol:52-78 (also script/Deploy.s.sol:27-30, test/fork/ForkAddresses.sol:4-31, test/Scripts.t.sol:41-44,249-257)`
- **Reported by:** hazard-truth (reported MEDIUM); also R1-quality-repo-3, R1-hazard-truth-5
- **Verification:** combined: partially-confirmed -> LOW

**Problem**

(1) Hazard: what actually gets broadcast to mainnet is a different set of literals from what is checked against mainnet. The only mainnet-checked copy is test/fork/ForkAddresses.sol, used by the fork tests. The deploy inputs live somewhere else: `Deploy.MAINNET_SWAP_ROUTER_02/WETH/UNISWAP_V3_FACTORY/USDC` (script/Deploy.s.sol:27-30) and `ConfigureWhitelist.defaultMainnetList()` (script/ConfigureWhitelist.s.sol:52-78), which holds the token addresses, fee tiers and reference supplies such as `referenceSupply: 20_084_784e8` for WBTC and `122_050_160e18` for WETH. ForkAddresses.sol:4 says it is "used by the fork tests and deploy scripts", but no script imports it. test/Scripts.t.sol:41-44 adds a third copy of the Deploy addresses. test_resolveList (Scripts.t.sol:249-257) compares `resolveList("default")` with `defaultMainnetList()`, so it compares the list with itself. No fork test calls `Deploy.deploy/resolveMarket` or `ConfigureWhitelist.propose/defaultMainnetList` (grep of test/fork finds neither). The fork tests list tokens with their own `_config(A.WBTC_WETH_500, A.BTC_SUPPLY)`.
(2) Shape: the same data is written by hand in 3 to 5 places (plus the README and ARCHITECTURE tables), and nothing compares them.
(3) Scenario: the natspec at ConfigureWhitelist.s.sol:48-50 says to "propose a config change when they drift". A maintainer refreshes the supplies: ForkAddresses.BTC_SUPPLY becomes 20_190_000e8 and the fork tests pass, but the script gets `20_190_000e18`. `IndexRule.checkConfig` (IndexRule.sol:73-88) only rejects zero supply, so propose mode accepts it and executeListing applies it 2 days later unless the guardian decodes the calldata. WBTC's market cap is now inflated 1e10 times. Under the uncapped rule its weight goes to about 100%, so every monthly rebalance doubles WBTC units and halves the others (the clip in IndexRule._bound). After 3 rebalances an index meant to be about 50% BTC holds about 8x its WBTC units and 1/8 of everything else. Value is preserved by the auction, but the basket is not the market-cap index holders bought. A wrong fee tier fails the same way: it points at a thinner pool that still has 200 slots, whose TWAP is cheaper to manipulate. The CLAUDE.md note that "an earlier draft had a wrong WBTC address" shows this has already happened once.
(4) Structural fix: keep one canonical source that the scripts import, and add a fork test that runs the real scripts on mainnet state and compares the result with that source.

**Proposed fix (reviewer)**

1) Create script/MainnetAddresses.sol (library, pragma 0.8.28) holding USDC, WETH, WBTC, LINK, UNI, TBTC, SWAP_ROUTER_02, UNISWAP_V3_FACTORY, the pools and the *_SUPPLY constants now in test/fork/ForkAddresses.sol. Make ForkAddresses re-export them (or import MainnetAddresses directly in fork tests).
2) script/Deploy.s.sol:27-30:
-    address public constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
+    address public constant MAINNET_WETH = MainnetAddresses.WETH;
(same for router, factory, USDC). script/ConfigureWhitelist.s.sol:54-77:
-            token: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, fee: POOL_FEE_LOW, referenceSupply: 20_084_784e8,
+            token: MainnetAddresses.WBTC, fee: POOL_FEE_LOW, referenceSupply: MainnetAddresses.BTC_SUPPLY,
(and likewise for the other entries). Delete the literal copies in test/Scripts.t.sol:41-44 and use the library.
3) Add test/fork/Scripts.fork.t.sol:
  function test_defaultWhitelist_matchesVerifiedMainnet() public {
    (IndexFactory f,) = new Deploy().deploy(safe, guardian, Deploy.Market(address(0),address(0),address(0),address(0)));
    assertEq(IIndexRule(f.RULE()).USD_POOL(), A.USDC_WETH_500);
    ConfigureWhitelist c = new ConfigureWhitelist();
    ConfigureWhitelist.Entry[] memory l = c.defaultMainnetList();
    vm.prank(f.owner()); c.propose(f, l);
    assertEq(f.pendingTokenConfig(A.WBTC).pool, A.WBTC_WETH_500);
    assertEq(f.pendingTokenConfig(A.WBTC).referenceSupply, A.BTC_SUPPLY);
    assertEq(f.pendingTokenConfig(A.LINK).pool, A.LINK_WETH_3000);
    assertEq(f.pendingTokenConfig(A.UNI).pool, A.UNI_WETH_3000);
    assertEq(f.pendingTokenConfig(A.WETH).referenceSupply, A.ETH_SUPPLY);
    for (uint i; i < l.length; ++i) if (l[i].referenceSupply != 0) assertLt(l[i].referenceSupply, IERC20Metadata(l[i].token).totalSupply() * 1e6); // catches decimals slips on non-wrapped tokens
  }
4) Fix the ForkAddresses.sol:4 natspec so it names the real consumers.

**Verifier (combined): partially-confirmed -> LOW**

The structural facts are right. test/fork/ForkAddresses.sol:4 says it is "used by the fork tests and deploy scripts", but grep finds no import of ForkAddresses anywhere in script/ or src/. Deploy.s.sol:27-30, ConfigureWhitelist.s.sol:52-78, Scripts.t.sol:41-44 and SetupTestMarket.s.sol:80,113 each carry their own copy of the literals. test_resolveList (Scripts.t.sol:249-257) compares resolveList("default") with defaultMainnetList(), which is the same list, plus one WETH literal. No file under test/fork references Deploy or ConfigureWhitelist.

I cross-checked every current value and they all match. Addresses: WBTC, WETH, LINK, UNI, tBTC, router, factory, USDC. Fee tiers: WBTC 500, LINK and UNI 3000, tBTC 3000. Supplies: 20_084_784e8, 122_050_160e18, 748_099_970e18, 623_212_423e18. So nothing is wrong today. The risk only appears if a later edit drifts, as in the finding's own hypothetical.

IndexRule.checkConfig (src/IndexRule.sol:73-88) really does check only that supply is non-zero, the excluded list is well formed and the pool is the genuine Uniswap one. It would accept a supply with the wrong decimals. The damage is limited by three things:
- LISTING_DELAY gives the guardian 2 days to cancel.
- For a Safe owner, the calldata is logged in safe mode and has to be signed by at least 2 signers.
- A wrong fee tier still has to pass _checkPool: the pool must be the factory's own pool with enough observation slots.

The effect is basket drift, not loss of funds, since the auction preserves value. A latent maintenance hazard with no current defect and several human checkpoints is LOW, not MEDIUM. The finding's second and third duplicates (cardinality 200, ETH supply in 3 places) are the same hazard class at the same severity.

*PoC:* Not run. This is a static claim about duplicated literals and a hypothetical future drift, not about runtime behaviour, so I checked it by grep and by reading the source. Every current value agrees across the copies, so there is no present-day failure to show.

*Fix assessment:* The direction is correct and fits CLAUDE.md: one canonical library under script/ with pragma 0.8.28, imported by Deploy, ConfigureWhitelist, Scripts.t.sol and the fork tests. Fork tests on ^0.8.24 can import it because the compiler is pinned to 0.8.28. ForkAddresses must still keep USDT, QUOTER_V2, AAVE, the TBTC/AAVE pools and FORK_BLOCK, or re-export them. Supplies must keep their source and date comments.

Three corrections to the proposed fork test:
1. `vm.prank(f.owner()); c.propose(f, l)` does not work. propose calls vm.startBroadcast, so broadcasts come from DEFAULT_SENDER and the prank is not used. On chain 1, Deploy.checkOwner also rejects DEFAULT_SENDER and any owner that is not a contract. Instead, call `c.configFor(l[i], rule.WETH(), rule.UNISWAP_V3_FACTORY())` and assert its pool and referenceSupply against the library values and against `IUniswapV3Factory.getPool`. Alternatively, check the `safeCalldata` output, or run propose with DEFAULT_SENDER as a mock-Safe owner deployed on the fork via vm.etch.
2. Deploy.deploy on the fork needs a contract owner whose getThreshold returns at least 2. Use a real Safe address or an etched stub.
3. The decimals sanity check `referenceSupply < totalSupply * 1e6` works for today's values but is a heuristic. A clearer check is `referenceSupply / 10**decimals` within a stated range, such as 1e6 to 1e12 whole tokens.

Also update ForkAddresses.sol:4 so its natspec names its real consumers.

*Tests a fix must add:*

- Fork test: Deploy.resolveMarket on chain 1 returns the canonical router, WETH, factory and USDC, and the rule's USD_POOL equals the verified USDC_WETH_500 pool
- Fork test: for each entry in defaultMainnetList, configFor(entry) gives a pool equal to the verified pool constant and a referenceSupply equal to the canonical *_SUPPLY constant
- Fork test: every defaultMainnetList entry passes rule.checkConfig on mainnet state (including the tBTC entry, whose pool had 60 observation slots on 2026-09-16, fewer than the rule's minimum, so this check is expected to fail today)
- Test that the reference supply in whole tokens (referenceSupply / 10**decimals) falls in a plausible range, to catch decimals slips

### XA-14 [LOW] startRebalance and previewTarget NatSpec leave out restrictions and reverts

- **Dimension:** Documentation (natspec-incomplete)
- **Location:** `src/interfaces/IIndexToken.sol:141-157`
- **Reported by:** docs-natspec (reported LOW)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

IIndexToken.startRebalance (src/interfaces/IIndexToken.sol:141-142): "Anyone can call it once MIN_REBALANCE_INTERVAL has passed since the last rebalance, while no unexpired rebalance is pending." The implementation (src/IndexToken.sol:222-248) has two more gates the notice omits. (1) `block.timestamp < restartAllowedAt && !isOwnerOrGuardian` reverts Unauthorized (:232-234), so after a cancel, "anyone" is false for REBALANCE_DELAY. (2) `turnover < MIN_TURNOVER` reverts TurnoverTooLow (:237). previewTarget (IIndexToken.sol:156) "Targets and turnover {startRebalance} would snapshot now with `keepMask`" is also wrong for masks startRebalance rejects. With n=3, previewTarget(8) returns targets because IndexRule._kept ignores bits >= n, but startRebalance(8) reverts InvalidKeepMask (IndexToken.sol:230). previewTarget(7) reverts DegenerateBasket, not InvalidKeepMask. An integrator who reads only the NatSpec can show a trigger that reverts.

**Proposed fix (reviewer)**

--- a/src/interfaces/IIndexToken.sol
+++ b/src/interfaces/IIndexToken.sol
@@
-    /// @notice Snapshots the rule's target units and starts the notice period. Anyone can call it once
-    ///         MIN_REBALANCE_INTERVAL has passed since the last rebalance, while no unexpired rebalance is pending.
+    /// @notice Snapshots the rule's target units and starts the notice period. Anyone can call it once
+    ///         MIN_REBALANCE_INTERVAL has passed since the last rebalance, while no unexpired rebalance is pending and
+    ///         {restartAllowedAt} has passed (before it, only the factory owner or guardian). Reverts with TurnoverTooLow
+    ///         when the targets would sell less than MIN_TURNOVER.
@@
-    /// @notice Targets and turnover {startRebalance} would snapshot now with `keepMask`.
+    /// @notice Targets and turnover {startRebalance} would snapshot now with `keepMask`. It does not check the mask or
+    ///         the caller: bits at or above {componentCount} are ignored here but make {startRebalance} revert.

### XA-15 [LOW] guardian() NatSpec leaves out the guardian's rebalance powers

- **Dimension:** Documentation (natspec-incomplete)
- **Location:** `src/interfaces/IIndexFactory.sol:79-81`
- **Reported by:** docs-natspec (reported LOW)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

src/interfaces/IIndexFactory.sol:79-80: "Address that can cancel pending listings and rebalances and delist tokens, alongside the owner." isOwnerOrGuardian (src/IndexFactory.sol:124-126) also lets the guardian call startRebalance with a non-zero keepMask, which no one else can do, and start a rebalance before restartAllowedAt (src/IndexToken.sol:231-234). IndexFactory's @dev (:20-21), README.md:48 and Deploy.s.sol:19-20 list the keep-mask power, so the getter's notice is the one incomplete description of a privileged role. A holder or reviewer who reads only the ABI docs underestimates the role: a guardian can pin components with a keep mask on any index, shaping every other component's targets.

**Proposed fix (reviewer)**

--- a/src/interfaces/IIndexFactory.sol
+++ b/src/interfaces/IIndexFactory.sol
@@
-    /// @notice Address that can cancel pending listings and rebalances and delist tokens, alongside the owner. May be
-    ///         zero.
+    /// @notice Address that, alongside the owner, can cancel pending listings and rebalances, delist tokens, start a
+    ///         rebalance with a keep mask, and start one before an index's `restartAllowedAt`. May be zero.

### XA-16 [LOW] Frontend 'rebalance due' condition (eta == 0) hides the trigger forever after an unfilled auction

- **Dimension:** Documentation (doc-accuracy)
- **Location:** `README.md:138-141`
- **Reported by:** docs-prose (reported MEDIUM); also R1-sec-token-3, R1-corr-core-2, R1-docs-natspec-2, R1-hazard-ops-1
- **Verification:** combined: confirmed -> LOW

**Problem**

README.md:138-139 tells the app to show the "rebalance due" button only when "no rebalance is pending (`pendingRebalance().eta == 0`) and `restartAllowedAt` has passed". In the code an expired auction never clears `_pending`. Only `_applyRebalance` (IndexToken.sol:293) and `cancelRebalance` (IndexToken.sol:254) delete it. `startRebalance` accepts a stale proposal: `if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) revert RebalancePending(...)` (IndexToken.sol:226-228), and `pendingRebalance()` returns the stored `eta` (IndexToken.sol:405). What goes wrong: an index is started on day 28, nobody fills it, and the auction expires on day 31. From then on `pendingRebalance().eta` stays non-zero until someone rebalances, so an app built from these notes never shows the button again. Only a direct contract call can restart the index. README.md:114 and ARCHITECTURE.md:184 say anyone can start a fresh snapshot after expiry, and the system has no bots, so the app button is the trigger. ARCHITECTURE.md:224 expects about 5% of auctions to expire, so this is not a rare case. Over time, a growing share of indexes would stop rebalancing through the UI.

**Proposed fix (reviewer)**

README.md:138-141, before:
```
- **Rebalance status.** Show `lastRebalance + MIN_REBALANCE_INTERVAL`, and a "rebalance due" button when that time has
  passed, no rebalance is pending (`pendingRebalance().eta == 0`) and `restartAllowedAt` has passed.
```
after:
```
- **Rebalance status.** Show `lastRebalance + MIN_REBALANCE_INTERVAL`, and a "rebalance due" button when that time has
  passed, no live rebalance exists (`eta == 0` or `block.timestamp > eta + AUCTION_DURATION`: an unfilled auction keeps
  its `eta` after it expires) and `restartAllowedAt` has passed.
```

**Verifier (combined): confirmed -> LOW**

The finding holds. `_pending` is cleared in only two places: `cancelRebalance` (IndexToken.sol:254) and `_applyRebalance` (IndexToken.sol:293). An auction that nobody fills keeps its `eta`. `startRebalance` still accepts a restart once `block.timestamp > pendingEta + AUCTION_DURATION` (IndexToken.sol:226-228). `pendingRebalance()` returns the stored eta as-is (IndexToken.sol:405). So the condition in README.md:138-139, "no rebalance is pending (`pendingRebalance().eta == 0`)", stays false after every expired auction until someone cancels or restarts. An app that follows the note stops showing the "rebalance due" button for that index. The interface NatSpec (IIndexToken.sol:158, "auction start (0 if none)") has the same gap. README.md:114 and ARCHITECTURE.md:184 say anyone can restart after expiry. ARCHITECTURE.md:224 says about 5% of auctions expire. No doc covers this stale-eta case.

I lower the severity from MEDIUM to LOW for three reasons:
- No funds, units or invariants are affected. `redeem` and `issue` are not affected.
- The contract path still works. Anyone can call `startRebalance(0)` directly, and the owner or guardian can call `cancelRebalance` to clear the stale proposal. That call also adds a 2-day restart delay.
- The web app is in a separate repo and may not follow the note literally.

The real consequence: indexes whose auction expired stop rebalancing through the UI. The system has no bots, so the button is the expected trigger. This is a real concern for the rule-following product, but it hits liveness and UX only.

*PoC:* Test file: scratchpad/poc/eta-stale/test/poc/EtaStale.t.sol. It extends IndexTokenRebalanceTest, starts a rebalance and warps to 30 days past the auction deadline.

Command: `cd "$D" && forge test --match-path 'test/poc/*' -vv`

Result: `[PASS] test_poc_etaStaysAfterExpiry()`. Logs: `eta after expiry: 2764801` (non-zero, still the original eta), `targets len: 5`, `currentMultiplier: 0`. In the same state a stranger's `startRebalance(0)` succeeds. The contract therefore treats the index as due while the README condition says it is not.

*Fix assessment:* The proposed README change is correct and follows CLAUDE.md: it touches docs only and changes no design rule. It is incomplete in two ways.

1. The interface NatSpec at IIndexToken.sol:158 should also say that `eta` stays non-zero after an unfilled auction expires, for example: "auction start (0 if none; an unfilled auction keeps its eta after `eta + AUCTION_DURATION`)".
2. The README condition should also require `block.timestamp >= lastRebalance + MIN_REBALANCE_INTERVAL`. The proposed text already covers this with "when that time has passed".

A better fix is an optional code change that removes the trap for integrators without touching state: have `pendingRebalance()` return `eta = 0` once `block.timestamp > eta + AUCTION_DURATION`, or add a `canStartRebalance()` view that mirrors the permissionless checks in `startRebalance`. Either change needs its own unit test. Changing `pendingRebalance()` would also change what `cancelRebalance`-based cleanup tests read, so the docs-only fix is the lower-risk option.

*Tests a fix must add:*

- After an unfilled auction expires (warp past eta + AUCTION_DURATION), check the documented 'rebalance due' predicate: it must be true, and startRebalance(0) from a stranger must succeed
- If the view is changed: pendingRebalance() returns eta 0 (or the new canStartRebalance() returns true) after expiry, and still returns the real eta at exactly eta + AUCTION_DURATION

### XA-17 [LOW] Docs claim units move at most 'half to double' per rebalance; settlement allows up to 2.5x

- **Dimension:** Documentation (doc-accuracy)
- **Location:** `ARCHITECTURE.md:167, 213-214, 226-229, 257-261`
- **Reported by:** docs-prose (reported MEDIUM); also R1-sec-token-2, R1-corr-core-3, R1-corr-tests-sec-1, R1-process-1, R1-hazard-truth-3
- **Verification:** combined: confirmed -> LOW

**Problem**

Several passages bound each rebalance to half and double a component's units:
- README.md:42: "each component moves between half and double its units per rebalance"
- ARCHITECTURE.md:167: "at most doubling or halving each time"
- ARCHITECTURE.md:226: "Each rebalance moves a component between half and double its units"
- ARCHITECTURE.md:257-258, security model: "always within half to double per component per rebalance"

Only the target is clipped to [u/2, 2u] (IndexRule.sol:360-361). The settled units come from `current + Math.mulDiv(target - current, multiplier, WAD, Math.Rounding.Ceil)` (IndexToken.sol:330-332), and the multiplier opens at `AUCTION_START_MULTIPLIER = 1.5e18` (IndexToken.sol:55). A component at u=100 with target 200 can therefore settle at 100 + 100*1.5 = 250, which is 2.5x. The comment on `MAX_TARGET_UNITS` (IndexRule.sol:33) and the invariant test ("units move between half and 2.5 times per rebalance", ARCHITECTURE.md:305; IndexToken.invariant.t.sol:177-180,350) both confirm this.

The gap matters because the security model uses this bound to limit shape distortion from manipulated prices, supplies or configs. Example: the bought leg's real price falls 40% relative to the sold legs after the snapshot. The fair multiplier is then 1/0.6 = 1.67, above 1.5, so an executor fills in the auction's first block and the component's units reach 2.5x. That is 25% more distortion than the documented worst case, and ARCHITECTURE.md:213-214 ("reacts to prices only within the per-rebalance clip") understates it too.

**Proposed fix (reviewer)**

README.md:42: replace "each component moves between half and double its units per rebalance" with "each component's target is clipped to half and double its units; a growing component settles at its extra units times the auction multiplier (1.5 to 0.9), so at most 2.5 times its units".

ARCHITECTURE.md:167: "at most doubling or halving each time" -> "at most halving, or 2.5 times (double target, times the 1.5 opening multiplier), each time".

ARCHITECTURE.md:226: "Each rebalance moves a component between half and double its units" -> "Each rebalance targets between half and double a component's units (a fill at the opening 1.5 multiplier can settle a growing one at up to 2.5 times)".

ARCHITECTURE.md:257-258: "always within half to double per component per rebalance" -> "always within half to 2.5 times per component per rebalance (targets within half to double, the growth scaled by the auction multiplier)".

**Verifier (combined): confirmed -> LOW**

The decisive claim holds in source. Only the rule's target is clipped to [u/2, 2u]: `basket.lo[i] = (u + 1) / 2; basket.hi[i] = Math.max(u, Math.min(2 * u, MAX_TARGET_UNITS));` (src/IndexRule.sol:357-358). Settlement then scales a growing component's extra units by the auction multiplier: `current + Math.mulDiv(target - current, multiplier, WAD, Math.Rounding.Ceil)` (src/IndexToken.sol:328-330). The multiplier starts at `AUCTION_START_MULTIPLIER = 1.5e18` (IndexToken.sol:55, _multiplier). So with u=100 and target=200, a first-block fill settles at 250, which is 2.5x.

The repo already knows this in three places. The MAX_TARGET_UNITS comment says "An auction can deliver 1.5 times a growing component's extra units" (IndexRule.sol:32). The invariant handler checks `afterwards*2 > before*5 + 2`, with the comment "a growing one gets at most double at par, times the 1.5 opening multiplier" (test/IndexToken.invariant.t.sol:177-180). ARCHITECTURE.md:305 says "units move between half and 2.5 times per rebalance".

Several passages still state a 2x bound: README.md:42, ARCHITECTURE.md:167, ARCHITECTURE.md:226 (the "Clip, then redistribute" rationale), ARCHITECTURE.md:257-258 (security model, "always within half to double per component per rebalance"), CLAUDE.md:78-79 (design rule "within half to double each component's units"), and the name and message of test_R17 (Security.t.sol:914, 929 "one rebalance moves at most 2x", which only checks the target). The docs contradict each other, so this is not documented-accepted.

Severity should be LOW, not MEDIUM. The extra 0.5x only happens when an executor delivers more units than the target, at a multiplier above 1. At a fair fill (multiplier about 1/(relative price of the bought leg)), the extra units make up for a price drop of the bought leg. The component's value weight at current prices therefore stays near the clipped target's value. For example, units 2.5x at price 0.6 is 1.5x the old value, not 2.5x. The "25% more distortion" is real in unit terms, but it is not an extra value or weight distortion that an attacker could steer. No value leaves the index: the settlement is supply- and unit-derived and post-checked. This is a documentation inaccuracy in the security model's stated bound, with no exploit.

*PoC:* Not run. The claim is plain arithmetic on constants I read in source (100 + (200-100)*1.5 = 250). The repo's own invariant handler (test/IndexToken.invariant.t.sol:177-180) already encodes and passes the 2.5x bound, and it would fail if units could not exceed 2x.

*Fix assessment:* The proposed doc rewording is correct in substance, but it is incomplete and the wording could be tighter.
(1) It misses CLAUDE.md:78-79. That design rule says "within the auction's multiplier band, and within half to double each component's units". It should read: "targets within half to double each component's units; settled units within half to 2.5 times (the growth scaled by the multiplier band)". CLAUDE.md is project-owned, so the maintainer should make this edit.
(2) It misses test/Security.t.sol:914 and 929. Rename test_R17_supplyInflationMovesUnitsAtMostDouble to test_R17_supplyInflationClipsTargetAtDouble. Change the message to "the rule would want 3.6x; one rebalance targets at most 2x". Optionally, execute at the opening multiplier and assert units <= 250e18.
(3) In ARCHITECTURE.md:226 and 257-258, add that the extra growth beyond 2x happens only when an executor delivers more units than the target (multiplier above 1), so the value weight stays near the clipped target at fair prices. Without that, readers could read the 2.5x as a larger attacker-steerable distortion.
None of this changes code or breaks any CLAUDE.md design rule. A code alternative would be to cap `next` at the clip bound (min(next, 2*current)). That changes auction economics: an executor at a multiplier above 1 could not be compensated in units beyond 2x, which touches a recorded decision (the 1.5 to 0.9 bought-leg auction). The docs-only fix is the right one.

*Tests a fix must add:*

- Regression test: component at units 100e18 with target 200e18 filled at eta (multiplier 1.5e18) settles at exactly 250e18, and never above, pinning the documented 2.5x bound
- Test that a shrinking component at any multiplier settles exactly at its target, never below (u+1)/2

### XA-18 [LOW] Mainnet `LISTING_MODE=propose` command cannot work because the owner must be a contract

- **Dimension:** Documentation (doc-accuracy)
- **Location:** `README.md:273-274`
- **Reported by:** docs-prose (reported LOW)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

README.md:273-274 gives the mainnet command `LISTING_MODE=propose FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <owner> --broadcast` "as the owner". The same README (line 265) and `Deploy.checkOwner` (Deploy.s.sol:84-87) require the mainnet owner to be a contract that is not an EIP-7702 delegated account: `if (code.length == 0 || _isDelegatedAccount(code)) revert OwnerMustBeContract(owner);`.

Forge cannot sign as a contract from a keystore. `proposeListing` is `onlyOwner` (IndexFactory.sol:179), so on mainnet this command either fails the sender/keystore match or reverts with `OwnableUnauthorizedAccount`. Only the `safe` mode on the next line works there. The script's header (ConfigureWhitelist.s.sol:15-17) repeats the unusable command.

**Proposed fix (reviewer)**

README.md:273-274, before:
```
# as the owner: propose every entry that is not pending and not already listed with exactly its config
LISTING_MODE=propose FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <owner> --broadcast
```
after:
```
# owner is a key you control (testnets and local forks only; on mainnet the owner is a contract, use safe mode below)
LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> forge script script/ConfigureWhitelist.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
```
Make the same change to the header comment at script/ConfigureWhitelist.s.sol:15-17.

### XA-19 [LOW] IndexRule divides the TWAP tick delta by a second, independently written 30-minute constant

- **Dimension:** Code quality (duplicated-constant)
- **Location:** `src/IndexRule.sol:29,44,192,199-200`
- **Reported by:** quality-repo (reported LOW); also R1-corr-rule-2, H-4
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

The window is written twice as separate literals: `uint32 public constant TWAP_WINDOW = 30 minutes;` (IndexRule.sol:29) and `int56 private constant SIGNED_TWAP_WINDOW = 30 minutes;` (IndexRule.sol:44). `_poolPrice` reads observations with `secondsAgos[0] = TWAP_WINDOW;` (:192) but divides with the other one: `int24 tick = int24(delta / SIGNED_TWAP_WINDOW);` and `delta % SIGNED_TWAP_WINDOW` (:199-200). Nothing ties the two together. Failure scenario: a later change sets TWAP_WINDOW = 1 hours and misses SIGNED_TWAP_WINDOW. The tick delta then covers 3600 s but is divided by 1800, so the mean tick doubles. For a token at tick -80,000 (about 3.4e-4 WETH) the rule would read tick -160,000 (about 1.1e-7 WETH), a price about 3,000 times too low. Weights, targets, navPerToken and checkConfig would all be wrong, while the constants() test would still pass on the public TWAP_WINDOW. I confirmed in a scratch copy that `int56(uint56(W))` is a legal constant expression.

**Proposed fix (reviewer)**

src/IndexRule.sol:44
-    int56 private constant SIGNED_TWAP_WINDOW = 30 minutes;
+    // Derived, so the divisor can never drift from the observation window.
+    int56 private constant SIGNED_TWAP_WINDOW = int56(uint56(TWAP_WINDOW));
(If forge lint flags unsafe-typecast here, add `// forge-lint: disable-next-line(unsafe-typecast)` with the reason "uint32 always fits int56".)

### XA-20 [LOW] Following README's .env setup makes plain `forge test` run fork tests at an archive-only block

- **Dimension:** Process (missing-operational-warning)
- **Location:** `README.md:258-262`
- **Reported by:** process (reported LOW)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

CLAUDE.md:18 says `forge test` is for 'unit + fuzz + invariant tests, no RPC needed'. CLAUDE.md:21 says fork tests are 'skipped when the env var is unset'. README.md:260 then tells the operator `cp .env.example .env   # fill MAINNET_RPC_URL, ...`. Forge loads `.env` from the project root automatically, so after that step every `forge test` sees MAINNET_RPC_URL. The fork suites then call `vm.createSelectFork(url, vm.envOr("FORK_BLOCK", A.FORK_BLOCK))` (test/fork/Security.fork.t.sol:43, IndexZap.fork.t.sol:67, Rebalance.fork.t.sol:50) at block 25_978_000 (test/fork/ForkAddresses.sol:36). That block needs an archive node. I checked this in a private copy: with `.env` containing MAINNET_RPC_URL and the shell variable unset, `forge test --match-path test/fork/Security.fork.t.sol` failed in setUp ('vm.createSelectFork: could not instantiate forked environment') instead of skipping. So a session that ran the deploy steps, or anyone using a public non-archive RPC, sees a red `forge test` (gate 3). The docs give no hint that the cause is `.env`. That invites a mistaken fix, such as editing the fork tests or the pinned block.

**Proposed fix (reviewer)**

CLAUDE.md/AGENTS.md line 18-21:
-forge test                   # unit + fuzz + invariant tests, no RPC needed
+forge test                   # unit + fuzz + invariant tests, no RPC needed. Forge auto-loads .env: if it sets
+                             # MAINNET_RPC_URL the fork suites run too (pinned block needs an archive node; set FORK_BLOCK
+                             # or run `forge test --no-match-path 'test/fork/*'`)

README.md:260:
-cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
+cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN. forge auto-loads .env, so plain
+                       # `forge test` now also runs the fork suites

.env.example line 1: append "Forge loads .env automatically, so setting this makes every `forge test` run the fork suites."

### XA-21 [LOW] 'One regression test per finding' claim is false for 8 v1 finding ids, and the finding list is not in the repo

- **Dimension:** Process (stale-fact)
- **Location:** `CLAUDE.md:44-45,59`
- **Reported by:** process (reported LOW)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

CLAUDE.md:44-45 (gate 6) says 'Every finding of the security reviews keeps its regression test passing in test/Security.t.sol (v1 findings by id, ...) or test/fork/Security.fork.t.sol'. CLAUDE.md:59 and ARCHITECTURE.md:306 say 'one regression test per security review finding'. The v1 review had M01, L01-L08, I01-I12 and FR01-FR06. The id-named tests present are M01, L01-L05, L07, FR02, FR03, I01, I02, I04-I08 and I12 in test/Security.t.sol, plus M01, I02, I03 and FR01 in test/fork/Security.fork.t.sol. No test exists for L06, L08, I09, I10, I11, FR04, FR05 or FR06, and grep finds these ids nowhere in the repo. They were never in the v1 commit f64528f either. The v1 report is an external artifact, not stored in the repo. A future session therefore cannot tell whether those findings were doc-only, are covered under other names, or lost their regression tests. It cannot check gate 6 as written, and it could delete a protective test without noticing, because nothing maps the missing ids to tests.

**Proposed fix (reviewer)**

CLAUDE.md/AGENTS.md line 44-45:
-6. Every finding of the security reviews keeps its regression test passing in `test/Security.t.sol` (v1 findings by id,
-   v2 rebalancing findings as `R01`..`R23`) or `test/fork/Security.fork.t.sol`.
+6. Every testable finding keeps its regression test passing in `test/Security.t.sol` (v1 findings by id,
+   v2 rebalancing findings as `R01`..`R23`) or `test/fork/Security.fork.t.sol`. v1 L06, L08, I09-I11 and FR04-FR06 have
+   no id-named test: <one line each: covered by <test name> / documentation-only / CI or script check>.
and line 59: `one regression test per testable security review finding (see gate 6)`. Mirror the mapping in ARCHITECTURE.md section 6.

### XA-22 [INFO] Zap mint checks the rebalance nonce before external calls; units can change before issue

- **Dimension:** Security (toctou)
- **Location:** `src/IndexZap.sol:127-180, 307-314`
- **Reported by:** orchestrator (reported LOW)
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

Orchestrator hypothesis. _checkCommon reads rebalanceNonce first; previewIssue is read in _buyBasket; then router swaps run; then issue. The index guard is not held during the swaps, so a callback from a hook token in a user or app chosen path (intermediate hop or tokenIn) could call index.executeRebalance during an auction, changing units: issue then reverts (units grew) or pulls less, stranding bought components in the zap (units shrank). Verify whether any callback path exists given whitelist policy, and the impact.

**Proposed fix (reviewer)**

Re-check the nonce right before issue in mintWithToken: uint256 nonceNow = IIndexToken(p.index).rebalanceNonce(); if (nonceNow != p.expectedNonce) revert StaleRebalanceNonce(p.expectedNonce, nonceNow); plus a test with MockHookToken as an intermediate path token that executes a rebalance mid-mint.

**Verifier (combined): partially-confirmed -> INFO**

The ordering the finding describes is real. src/IndexZap.sol:128 `_checkCommon` reads `rebalanceNonce` (lines 307-314). `_buyBasket` then reads `previewIssue(p.shares)` (line 158), runs `ROUTER.exactOutput` swaps (lines 188-192), and calls `IIndexToken(p.index).issue` (line 152). The zap's `nonReentrant` is its own guard. The index's guard is not held during the swaps, so `IndexToken.executeRebalance` (src/IndexToken.sol:264) could be entered from inside a swap. It changes units and bumps the nonce (lines 284-291).

Reachability is where the claim mostly falls apart:
(1) Something has to call into outside code in the middle of the swap. Whitelisted components must be standard ERC-20s, and the stock tokenIn is USDC/USDT. Uniswap V3 pools and SwapRouter02 never call arbitrary contracts. ERC-777-style hooks only call hooks registered by the sender or recipient, and the pool, router and zap register none. So a callback only happens if the user or app puts a hostile, attacker-written token in the path (an intermediate hop), or picks such a token as tokenIn. A path like that already hands the attacker the user's whole `maxAmountIn` through attacker-controlled pool pricing. The TOCTOU adds nothing beyond that.
(2) Someone simply front-running with a separate executeRebalance transaction is already caught: the nonce is checked at entry, and a transaction that lands first changes it.
(3) Most outcomes are harmless. If any component's units grow, `issue` rounds amounts up at the new units (IndexToken.sol:145). That amount is above the allowance the zap set with `forceApprove(p.index, need[i])` (IndexZap.sol:176), so the whole mint reverts atomically. Loss only happens when every component shrinks or stays the same, for example a rebalance with a keep mask. Then `issue` pulls less, and the difference (at most half of each leg, since units stay within half to double) sits in the zap with no way to get it out. Even in that case the precondition is the malicious path from (1).

The mechanism exists, but no exploit is reachable under the whitelist policy with honest paths. It is defense-in-depth only.

*PoC:* Not run. Everything the ruling rests on is visible in source: the only callback source is a non-standard token the caller chooses for the path. Any growing leg reverts on the exact allowance (IndexZap.sol:176 vs IndexToken.sol:145/155). A PoC would need a hostile hop token that already controls the user's budget, which shows nothing beyond the malicious-path case.

*Fix assessment:* The proposed fix is correct, cheap, and fits the CLAUDE.md rules: the zap stays stateless, and the token, rule and factory are untouched. Re-read the nonce right before `issue` in mintWithToken, after the refund and before the call at line 152:
```
+        uint256 nonceNow = IIndexToken(p.index).rebalanceNonce();
+        if (nonceNow != p.expectedNonce) revert StaleRebalanceNonce(p.expectedNonce, nonceNow);
         IIndexToken(p.index).issue(p.shares, p.to);
```
Keep the entry check too, since it saves gas on stale calls. A cleaner option is to put the re-check before the refund transfer at line 146, so it also runs before the call into the user-supplied tokenIn. For consistency, burnToToken could re-check after `redeem` as well. That path is lower risk, because redeem is in-kind and the swaps come after it. The fix changes robustness only, not severity.

*Tests a fix must add:*

- mintWithToken with a MockHookToken intermediate hop whose hook calls index.executeRebalance during the auction, where all units shrink (keep mask): expect a revert with StaleRebalanceNonce(expected, expected+1)
- The same scenario where one unit grows: shows the revert already happens today without the fix (allowance limit)
- The nonce check still passes on the normal path: a mint with an unchanged nonce succeeds and leaves the zap balance at zero

### XA-23 [INFO] Overflow in rule products at extreme reachable ticks reverts rebalances

- **Dimension:** Security (arithmetic-dos)
- **Location:** `src/IndexRule.sol:245, 334, 350, 374`
- **Reported by:** orchestrator (reported LOW)
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

Orchestrator hypothesis. caps = supplies * prices, value = u * prices, sold += delta * prices and targets * prices are unchecked-by-mulDiv products. _quoteAtTick can return up to about 3.4e56 at MAX_TICK; with a supply around 1e27 the product exceeds 2^256 and startRebalance reverts while a manipulated TWAP sits near the extreme. Verify maximum price reachable, whether realistic listed supplies overflow, and the DoS window.

**Proposed fix (reviewer)**

Compute caps and values in a normalized unit (e.g. Math.mulDiv(supply, price, WAD)) and document bounds; add a fuzz test at MIN_TICK/MAX_TICK with max plausible supplies and units.

**Verifier (combined): partially-confirmed -> INFO**

The arithmetic claim holds, but the impact does not reach LOW. The products are plain checked multiplications. In src/IndexRule.sol:245 `caps[i] = supplies[i] * prices[i];`, :334 `sold += (units[i] - targets[i]) * basket.prices[i];`, :350 `uint256 value = u * basket.prices[i];`, :374 `value += targets[i] * basket.prices[i];`, plus the sums `total += caps[i]` (:263) and `rest += caps[i]`. `_quoteAtTick` (:206-214) returns about 3.40e56 at MAX_TICK 887272, so they can overflow. The resulting 0x11 panic reverts `targetUnits`, `weights` and `initialUnits`, and through IndexToken.sol:354 `_previewTarget` it also reverts `startRebalance`.

Reachability: the rule reads the mean tick over TWAP_WINDOW = 30 minutes (:29, :190-201), not the spot price. Real listed tokens are far from the overflow point:
- A supply of 1e27 raw units (1e9 tokens at 18 decimals) needs a mean tick of at least 738,330, which is a price of about 1e32 ETH per token.
- A SHIB-like supply of 1e33 raw units, sitting near tick -184,216 today, needs a mean tick of at least 600,168.
- Moving the 30-minute mean that far means holding the spot near MAX_TICK for about 73% of the window, roughly 110+ consecutive blocks.
- Once the pool's liquidity is used up, anyone who sells the token back collects the attacker's WETH. So the attacker would have to exclude all counter-trades across many blocks, which in practice means controlling block building.

No honest market state comes near these magnitudes. The admitted supplies (6-18 decimals, fixed or governance-minted supply) are orders of magnitude too small.

Impact: while such a manipulation lasts, the call fails safe. `startRebalance` reverts, and so do the related views. No snapshot is taken and no value moves. The call is permissionless, so anyone can retry once the average normalizes. Issue, redeem, claim and the zap never call the rule (only `_previewTarget` does), so holders are not affected. ARCHITECTURE.md section 5 already accepts "a multi-block TWAP manipulation at the snapshot" as a way to distort a basket's shape. An attacker able to do that gains more from letting the snapshot succeed with skewed targets than from making it revert. So the overflow adds no new attack.

What is actually wrong: ARCHITECTURE.md:290 ("Overflow: units <= 2^96-1, targets below MAX_TARGET_UNITS, 512-bit mulDiv") suggests every rule product is bounded or goes through mulDiv. The supply*price and units*price products are not, and nothing states a bound for them. That makes this a documentation/robustness note (INFO), not an exploitable DoS.

*PoC:* Not run. The claim is deterministic checked arithmetic: the thresholds were computed in python3 (1.0001^887272*1e18 = 3.402568e56; ticks needed 738,330 and 600,168). The deciding question is how reachable the manipulated TWAP is and whether it adds anything over the accepted multi-block manipulation, which a mock-pool PoC would not settle.

*Fix assessment:* The proposed fix would work: switch the products to `Math.mulDiv(supply, price, WAD)` and the matching `mulDiv(units, price, WAD)`, applied the same way at :245, :334, :350 and :374. That keeps weights scale-invariant and moves the overflow point beyond any reachable input. It breaks no CLAUDE.md design rule, because the rule is stateless and prices only shape targets. It does have side effects:
- Scaling by WAD rounds small caps and values to zero. `_uncappedWeights` and `_cappedWeights` then revert with DegenerateBasket, and `_bound` reverts when activeValue == 0, for dust units at low prices. The zero-rounding cases would need guarding.
- `turnover` and `_redistribute`'s gap would change precision, and existing unit and R-series tests that pin exact targets would need re-checking.
- The fork tests must be re-run.

Given the INFO rating, the smaller compliant change is documentation only. Amend ARCHITECTURE.md:290 to state that supply*price and units*price are plain products, which overflow only above about 1.16e77 (a mean tick near 600k-740k for real supplies). A manipulation that extreme makes `startRebalance` revert, which is safe, rather than produce a snapshot.

*Tests a fix must add:*

- If the mulDiv change is made: a fuzz test of targetUnits with a mock pool TWAP tick at MIN_TICK/MAX_TICK and supplies up to 1e33 and units up to 2^96-1, asserting no panic 0x11 (or a defined custom error)
- If the mulDiv change is made: a test with dust units and low prices, showing normalized values do not wrongly revert DegenerateBasket
- Regression that existing exact-target tests (R01-R23) still pass after normalization
- If documentation only: a test showing startRebalance reverts (no snapshot stored, nonce unchanged) when a component's mean tick is at MAX_TICK with a 1e33 supply

### XA-24 [INFO] WHITELIST referenceSupply is parsed as raw units with no unit documentation or sanity bound, so a whole-token entry is silently accepted

- **Dimension:** Security (input-validation)
- **Location:** `script/ConfigureWhitelist.s.sol:29-31, 114-120`
- **Reported by:** sec-scripts (reported LOW); also H-8
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

`parseEntry` stores the field verbatim: `if (fields.length > 2 && bytes(fields[2]).length != 0) entry.referenceSupply = vm.parseUint(fields[2]);` (line 120). The Env docs (lines 29-31) and README line 281 describe `token:fee[:referenceSupply...]` without saying the value is in the token's raw base units. `IndexRule.checkConfig` (src/IndexRule.sol:73-88) only rejects zero and returns `referenceSupply` unchanged from `_supply` (line 222), so any magnitude passes. Failure scenario: an operator writes WBTC's bitcoin supply as whole tokens, `0x2260...:500:20084784`. The PoC confirms `parseEntry(...).referenceSupply == 20_084_784`, which is 0.2 BTC in 8-decimal raw units instead of 20_084_784e8. The proposal passes the script, the rule check and the factory. Once executed, WBTC's cap is 1e8 times too small, so its weight is about 0. The next rebalance targets would sell WBTC down to the executeRebalance floor of half its units per round. An 18-decimal token written as whole tokens is 1e18 times too small. The guardian can still cancel during LISTING_DELAY, but only if someone reads the raw number in the event.

**Proposed fix (reviewer)**

Document the unit and add a cross-check against decimals in propose/safeCalldata before a proposal is emitted. In script/ConfigureWhitelist.s.sol:

```diff
-///                 `token:fee[:referenceSupply[:excluded|excluded...]]`. `fee` is the Uniswap V3 fee tier of the token's
+///                 `token:fee[:referenceSupply[:excluded|excluded...]]`. `referenceSupply` is in the token's RAW units
+///                 (whole tokens * 10**decimals). `fee` is the Uniswap V3 fee tier of the token's
```

and in `_shouldPropose`, before `rule.checkConfig`:

```diff
+        if (config.referenceSupply != 0 && config.referenceSupply < 10 ** IERC20Metadata(token).decimals()) {
+            console2.log("skipped, referenceSupply below one whole token: raw units expected", token);
+            return false;
+        }
```

Also log `referenceSupply / 10**decimals` for every proposed entry so the operator sees whole-token figures. Mirror the unit note in README.md line 281.

**Verifier (combined): partially-confirmed -> INFO**

The mechanics are accurate. `parseEntry` (script/ConfigureWhitelist.s.sol:120) stores `vm.parseUint(fields[2])` exactly as typed. `_shouldPropose` (lines 200-218) only checks whether the token is pending, whether its config is unchanged, and `rule.checkConfig`. `IndexRule.checkConfig` (src/IndexRule.sol:73-88) rejects a zero reference supply only for WETH and a zero `_supply` otherwise, and `_supply` returns `referenceSupply` unchanged (line 222). So `0x2260...:500:20084784` would be proposed as 0.2 BTC of raw supply, which makes WBTC's market-cap weight about 1e-8 of what it should be.

The finding overstates two things.
(1) The unit is documented. `IIndexFactory.TokenConfig` says "Supply used instead of the on-chain one, in the token's raw units" (src/interfaces/IIndexFactory.sol:10). The script's own default list shows raw values with the scaling written out (`20_084_784e8`, `122_050_160e18`). Only the Env comment (lines 29-31) and README:281 leave the unit out.
(2) Reaching the bad state takes several deliberate steps. Only the owner can propose, and on mainnet the owner is a multisig needing at least two signatures. The proposal waits out LISTING_DELAY, and `ListingProposed` emits `referenceSupply`. The owner or guardian can cancel. Even after `executeListing`, units change only through a permissionless `startRebalance` after MIN_REBALANCE_INTERVAL and REBALANCE_DELAY of notice, which the guardian can also cancel. Each round is also limited to half or double a component's units.

This is an operator typo in an owner-only deployment helper, not an attacker-reachable path. A proposal can carry many other wrong values (a wrong fee tier, a stale supply) that no sanity bound catches. The only real gap is that the script's usage docs don't state the unit, so INFO fits better than LOW.

*PoC:* Not run. The claim is fully decided by pure code read above: `parseEntry` stores the typed number verbatim and `_supply` returns it unchanged. No runtime behaviour is in doubt.

*Fix assessment:* Adding "raw units (whole tokens * 10**decimals)" to the Env comment and README:281 is correct and enough for an INFO issue. The proposed `referenceSupply < 10**decimals` check is optional. It compiles with IERC20Metadata and breaks no CLAUDE.md design rule, because it lives in a script, not in the token, rule or factory. It catches only the extreme case, though: a whole-token WBTC entry (20,084,784 < 1e8) or LINK entry (748,099,970 < 1e18) is caught, but other scale slips are not. For example, writing an 18-decimal token's supply as `e8` still passes. Logging `referenceSupply / 10**decimals` next to each proposed entry, in both propose and safe modes, is the more useful safeguard because signers see whole-token figures. If the check is added, it must be skipped for WETH only if the WETH supply is written correctly: WETH's raw supply is far above 1e18, so it passes. Don't move the check into `IndexRule.checkConfig`. That would add a heuristic to the stateless rule for no protocol gain.

*Tests a fix must add:*

- If the decimals check is added: a Scripts.t.sol case where propose/safeCalldata skips an entry whose referenceSupply is below 10**decimals and logs the reason, with no ListingProposed event
- If the decimals check is added: the default mainnet list (raw values) is still proposed unchanged, and a zero referenceSupply (on-chain supply) is not skipped
- Script coverage stays at 100% for the new branch

### XA-25 [INFO] Deploy does not reject the broadcasting key as guardian

- **Dimension:** Security (key-custody)
- **Location:** `script/Deploy.s.sol:98-101`
- **Reported by:** sec-scripts (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

`checkGuardian` rejects only zero, `DEFAULT_SENDER` and the owner: `if (guardian == address(0) || guardian == DEFAULT_SENDER || guardian == owner) revert GuardianRequired();` (Deploy.s.sol:100). The real broadcaster, set with `--sender` / `--account deployer`, is never compared. Scenario: `GUARDIAN=$DEPLOYER` passes. The deploy keystore, which is often a hot key reused for `ConfigureWhitelist execute`, then holds guardian authority permanently until a 7-day `proposeGuardian`. With it the key can delist tokens, cancel every rebalance, and start rebalances with a keep mask. Funds are not at risk, but this breaks the rule that the deploy key holds no authority. On the recorded Sepolia deploy, the broadcaster 0x82cf...2053 is not the guardian 0x8cef...55a1, so this is not currently exploited.

**Proposed fix (reviewer)**

script/Deploy.s.sol line 62 (in `deploy`, where msg.sender is the script sender):

```diff
         checkOwner(owner);
         checkGuardian(owner, guardian);
+        if (owner == msg.sender || guardian == msg.sender) revert BroadcasterHoldsRole(msg.sender);
```

Add `error BroadcasterHoldsRole(address sender);` and a test that calls `deployer.deploy(owner, address(this), _market())` from `address(this)` and expects the revert.

### XA-26 [INFO] Test-market seed centres liquidity on the live tick of an empty pool with zero min amounts, so anyone can skew the Sepolia prices between create and seed

- **Dimension:** Security (testnet-integrity)
- **Location:** `script/testnet/SetupTestMarket.s.sol:283-300`
- **Reported by:** sec-scripts (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

`create` initialises each pool with no liquidity. `seed`, run in a later block, reads `(, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();` and builds the range as `rangeAround(tick, spec.fee)` (lines 290-291). The amounts come from the spec price (`tokenAmount = Math.mulDiv(wethAmount * 2, ..., spec.wethPerToken)`, line 292), and `amount0Min`/`amount1Min` are left at 0. Scenario: between the two runs, anyone swaps a dust amount in the empty pool, which moves the tick to an extreme at no cost. `seed` then places the position around that tick. The position ends up single-sided or reverts at MIN/MAX_TICK, and the rule's 30-minute price for that test token is wrong from the start. Only Sepolia is affected, because `run` is guarded by `block.chainid != SEPOLIA_CHAIN_ID`, so there is no value at risk. Testers would still see nonsensical index prices.

**Proposed fix (reviewer)**

script/testnet/SetupTestMarket.s.sol `_mintParams`: centre on the spec price instead of the live tick, and fail if the pool has drifted:

```diff
-        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
+        (uint160 current, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
+        uint160 expected = sqrtPriceX96(token, uniswap.weth, spec.decimals, spec.wethPerToken);
+        if (current > expected + expected / 100 || current + expected / 100 < expected) revert PoolPriceMoved(pool, current, expected);
```

Add `error PoolPriceMoved(address pool, uint160 current, uint160 expected);`.

### XA-27 [INFO] The parity rule for an empty index is skipped when supply is dust, so the executor picks the multiplier and sets units off the rule's targets

- **Dimension:** Security (auction-pricing)
- **Location:** `src/IndexToken.sol:312-350`
- **Reported by:** sec-token (reported LOW)
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

`_multiplier` only settles at parity when supply is exactly zero: `if (supply == 0) return WAD;` (IndexToken.sol:347). The code comment gives the reason: 'An empty index settles at parity, because nothing moves and its new units should not depend on timing' (IndexToken.sol:345). The same reasoning covers any supply small enough that nothing moves. Each amount is `Math.mulDiv(supply, current, SHARE_UNIT)` minus `Math.mulDiv(supply, next, SHARE_UNIT)` (IndexToken.sol:334-339). With supply = 1 wei and units below 1e18, every amount floors to 0. The multiplier still decays from 1.5 to 0.9, and `next = current + ceil((target - current) * multiplier)` (IndexToken.sol:330-332) is written to storage by `_applyRebalance`.

Scenario (PoC `test/poc/DustSupply.t.sol`, passing on a copy of the repo; it uses the setup of IndexToken.rebalance.t.sol with five tokens at 100e18 units, equal prices, and rule targets [200,75,75,75,75]e18):
1. Someone creates an index and issues 1 wei of shares, paying 1 raw unit of each token.
2. After 28 days a stranger calls `startRebalance(0)`.
3. At `eta` the stranger's contract calls `executeRebalance`. The multiplier is 1.5 and no tokens move.

Result: units become [250,75,75,75,75]e18 instead of the rule's value-neutral [200,75,...]e18. At equal prices the basket value per index token goes from 500 to 550 (+10%), and component 0 is 2.5x its old units. Executing at eta+24h instead gives 460 (-8%). Choosing the time costs only gas, it resets `lastRebalance` for 28 days, and the level shift carries into later rebalances because the rule keeps total value. No holder funds are lost because issue and redeem are in kind. The damage is that the rule's shape and the displayed price of a new or nearly empty index depend on who executes and when. This is the timing dependence the `supply == 0` branch was written to prevent. The same holds whenever the value at stake is below gas cost (tiny supply), where no competing bidder shows up.

**Proposed fix (reviewer)**

src/IndexToken.sol:312-350. Settle at parity whenever no shrinking component actually sends anything, not only when supply is exactly zero:

```diff
@@ function _previewRebalance(uint256 supply)
         if (block.timestamp > eta + AUCTION_DURATION) revert RebalanceExpired(eta + AUCTION_DURATION);
-        multiplier = _multiplier(eta, supply);
-
         uint256 n = _components.length;
+        // Nothing leaves the index (empty or dust supply): settle at parity so the new units do not depend on timing.
+        bool sells = false;
+        for (uint256 i = 0; i < n; ++i) {
+            uint256 cur = _components[i].units;
+            uint256 tgt = _targetUnits[i];
+            if (tgt < cur && Math.mulDiv(supply, cur, SHARE_UNIT) != Math.mulDiv(supply, tgt, SHARE_UNIT)) {
+                sells = true;
+                break;
+            }
+        }
+        multiplier = sells ? _multiplier(eta) : WAD;
@@
-    function _multiplier(uint256 eta, uint256 supply) private view returns (uint256) {
-        if (supply == 0) return WAD;
+    function _multiplier(uint256 eta) private view returns (uint256) {
         return AUCTION_START_MULTIPLIER
```
Apply the same change to `currentMultiplier` (line 418). Test in test/IndexToken.rebalance.t.sol: create an index, `_issue(dust, stranger, 1)`, `_start(dust)`, `vm.warp(eta)`, `executor.execute(dust, "")`, then `assertEq(keccak256(abi.encode(_units(dust))), keccak256(abi.encode(_expectedTargets())))`.

**Verifier (combined): partially-confirmed -> INFO**

Reachability holds. `_multiplier` returns parity only when `supply == 0` (src/IndexToken.sol:346-347). For any nonzero supply it decays from 1.5 to 0.9. `_previewRebalance` sets a growing component to `current + ceil((target-current)*multiplier)` (lines 330-332). So a lone executor on a dust-supply index can pick any multiplier in [0.9, 1.5] by choosing when it executes, and the units follow that choice.

Two parts of the finding are wrong, though.
(1) Its mechanism is misstated. With the PoC's 100e18 units, SHARE_UNIT = 1e18 and supply = 1 wei, the amounts do not floor to 0. oldRequired is 100 raw units and newRequired is 250, so 150 wei of component 0 comes in and 25 wei of each shrinking component goes out. Tokens do move, just worthless amounts.
(2) Its proposed fix does not fix its own scenario. Each shrinking leg sends 25 wei out, so `sells` is true and the multiplier still decays.

Impact: no value can be taken from anyone. Issue and redeem are in kind, and the executor pays in more at a higher multiplier. The only effect is that a near-empty index gets a level and shape set by whoever executes. ARCHITECTURE.md section 5 already says the level is set by the auction ('Level: set by the auction'). It also says small indexes rarely clear ('Rebalances clear only when the bought value covers gas and swap costs many times over'). What it does not say is that a lone executor on a worthless auction can pick the level for free. That is a documentation gap, and the shape distortion stays within the half-to-double bound. The supply == 0 comment is a boundary case of the general principle that the auction prices the level, not a separate guarantee that gets bypassed. Severity: INFO.

*PoC:* Not run. The decisive claims follow directly from the source arithmetic. At multiplier 1.5, 100 + 1.5*(200-100) = 250. The transfer amounts come out nonzero (150 wei in, 25 wei out per shrinking leg), which refutes the finding's "every amount floors to 0" and shows its fix's `sells` check would be true.

*Fix assessment:* The proposed fix is incomplete. It only applies parity when no shrinking leg moves any raw unit. In the finding's own scenario (1 wei supply, units in the 1e18+ range) every shrinking leg moves a few wei, so the multiplier still decays and the timing dependence stays. Any supply threshold would be arbitrary, and an attacker could issue just above it for trivial cost. A threshold also sets a price-free cutoff, which touches the oracle-free design only lightly, but it is still arbitrary. Recommended fix: leave the code as is and document it. In ARCHITECTURE.md section 5 'Level' (line ~261), add: "When the bought value is below gas cost (empty-ish index), a lone executor chooses the multiplier in [0.9, 1.5] for free; this sets the level and shape of a near-empty index within the half-to-double bound but moves no holder value." Update the comment at IndexToken.sol:345 to match. If a code change is still wanted, the only robust option is parity whenever supply is below a fixed minimum share amount. Its tradeoffs would need a recorded product decision.

*Tests a fix must add:*

- If a code threshold is adopted: executeRebalance with supply = 1 wei and units >= 1e18 at eta and at eta+24h gives identical units equal to the targets
- The same test just above the threshold shows the multiplier decays
- An empty index (supply 0) still settles at parity (existing behaviour)

### XA-28 [INFO] An executor can deliver less than amountsIn and keep the index's surplus (donations, rounding dust)

- **Dimension:** Security (accounting)
- **Location:** `src/IndexToken.sol:283-306`
- **Reported by:** sec-token (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

After the callback, the only check is `_checkBacking`: `required = Math.mulDiv(supply, units[i], SHARE_UNIT) + totalClaims[token]; if (balance < required) revert` (IndexToken.sol:303-305). The `amountsIn` passed to the executor are never enforced. Any balance above required (tokens sent directly to the index, ceil dust from `issue` and floor dust from `redeem`, at most 1 raw unit per component per call) can be used by the executor to under-deliver on growing components. Example: someone sends 5e18 of token 0 to the index while it needs amountsIn[0] = 10e18. The executor sends 5e18 and the rebalance still settles. The NatSpec says the index 'never sends out rounding dust or donations' (IndexToken.sol:311), and ARCHITECTURE.md §5 says 'Nothing can move value out of an index'. Both are true only for the transfer amounts: the surplus still goes to the executor, as a smaller delivery. Holders were never entitled to that surplus under the in-kind design, so this is a documentation inaccuracy, not a loss.

**Proposed fix (reviewer)**

Documentation only. In src/IndexToken.sol:309-311 change the sentence to: 'the index never sends out rounding dust or donations, but the settlement check counts them, so an executor may deliver that much less.' Add the same sentence to ARCHITECTURE.md §5 'Known limitations'. If the surplus should stay in the index, record balances before the transfers and require `balanceAfter[i] >= balanceBefore[i] - amountsOut[i] + amountsIn[i]` in addition to `_checkBacking`.

### XA-29 [INFO] Burn legs for components that redeem to zero are accepted without path validation, and their per-leg minimum is silently ignored

- **Dimension:** Security (input-validation)
- **Location:** `src/IndexZap.sol:259-267`
- **Reported by:** sec-zap (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

`_sellBasket` validates a leg only when it actually sells: `if (component == p.tokenOut) { if (p.legs[i].path.length != 0) revert BadPath(i); ... } else if (got[i] != 0) { reported += _sell(p, component, got[i], i); }` (src/IndexZap.sol:261-265). `_checkPath` runs inside `_sell` (line 276), so a leg whose `got[i]` is 0 is never checked. `got[i]` is `floor(shares * units_i / 1e18)` (IndexToken.sol:441-446, 394-396), so it is 0 for small burns. Example: WBTC units = 1e6 (0.01 BTC per index) and shares = 1e11 gives 1e11*1e6/1e18 = 0. That leg can carry any bytes, such as an empty path, a path to a different token or a malformed path, plus a non-zero `minAmountOut`, and the call still succeeds without enforcing that minimum. Mint handles the matching case more strictly: a non-empty path on the `tokenIn` leg reverts (line 173). No funds are at risk, because nothing is swapped and the overall `minAmountOut` still applies. The problem is that the zap accepts malformed input it should reject, and a caller who set a per-leg limit gets no signal that it was not applied.

**Proposed fix (reviewer)**

src/IndexZap.sol lines 264-266: validate the path even when nothing is sold.
```diff
-            } else if (got[i] != 0) {
-                reported += _sell(p, component, got[i], i);
-            }
+            } else {
+                _checkPath(p.legs[i].path, component, p.tokenOut, i);
+                if (got[i] != 0) reported += _sell(p, component, got[i], i);
+            }
```
(`_sell` can then skip its own `_checkPath`.) Add a test to test/IndexZap.t.sol: burn a share amount where one component's `previewRedeem` is 0, pass an empty path for that leg, and `vm.expectRevert(abi.encodeWithSelector(IndexZap.BadPath.selector, i))`.

### XA-30 [INFO] Recipient check rejects the zap and the index but not the SwapRouter02, where delivered tokens can be swept by anyone

- **Dimension:** Security (input-validation)
- **Location:** `src/IndexZap.sol:307-314`
- **Reported by:** sec-zap (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

`_checkCommon` rejects `to == address(0)`, `to == address(this)` and `to == index` (src/IndexZap.sol:312-313), but accepts `to == address(ROUTER)`. A burn with that recipient sends the payout (`tokenOut.safeTransfer(p.to, amountOut)`, line 248) and any unsold component (line 294) to SwapRouter02. Anyone can then take those tokens with the router's public `sweepToken(token, amountMinimum)`, which pays msg.sender. A mint with `to == ROUTER` sends the minted index shares there (line 152), where they can be swept the same way. This only happens through integrator or user error, but the zap already blocks the other two addresses that would lose funds, and the router is the only other contract the zap knows that is known to lose them.

**Proposed fix (reviewer)**

src/IndexZap.sol line 313:
```diff
-        if (to == address(this) || to == index) revert InvalidRecipient(to);
+        if (to == address(this) || to == index || to == address(ROUTER)) revert InvalidRecipient(to);
```
Add tests in test/IndexZap.t.sol that call `mintWithToken` and `burnToToken` with `to = address(router)` and expect `abi.encodeWithSelector(IndexZap.InvalidRecipient.selector, address(router))`.

### XA-31 [INFO] WBTC is valued with the whole bitcoin supply while tBTC uses its on-chain float

- **Dimension:** Correctness (methodology-consistency)
- **Location:** `script/ConfigureWhitelist.s.sol:48-79`
- **Reported by:** orchestrator (reported INFO)
- **Touches a recorded product decision:** yes
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

Orchestrator hypothesis. Both are bitcoin wrappers; an index holding both counts BTC market cap for WBTC but only the tBTC float for tBTC, so their relative weights reflect wrapper choice, not the asset. Verify the docs acknowledge it.

**Proposed fix (reviewer)**

Document the policy for multiple wrappers of one asset in ARCHITECTURE.md, or disallow listing a second wrapper of an asset that already uses a reference supply.

### XA-32 [INFO] test_R09 says issuing 1e18+1 shares leaves dust, but the 100e18 units round exactly

- **Dimension:** Correctness (test-claim-false)
- **Location:** `test/Security.t.sol:812-824`
- **Reported by:** corr-tests-sec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

test/Security.t.sol:814 `_issueRule(idx, attacker, 1e18 + 1); // issue rounds up, leaving dust in every component`. `_surgeBasket()` builds the index with `_hundreds()`, so every component has 100e18 units (line 649). previewIssue computes `Math.mulDiv(shares, units, 1e18, Ceil)` (src/IndexToken.sol:445), and (1e18+1)*100e18/1e18 = 100e18+100 with no remainder. Nothing rounds up and no component gets dust. The 'with dust' half of the test name `untouchedComponentsNeverMoveEvenWithDustOrDonations` is never tested. Only the 12,345-unit donation (line 815) checks the kept component. A regression that moved a kept component's rounding surplus, but not a donation, would not be caught here.

**Proposed fix (reviewer)**

test/Security.t.sol line 814: use a share amount that does not divide evenly, and check that it leaves dust.
```diff
-        _issueRule(idx, attacker, 1e18 + 1); // issue rounds up, leaving dust in every component
+        _issueRule(idx, attacker, 1); // 100e18 units * 1 wei share rounds up from 100 wei... see below
```
Units of 100e18 always divide evenly, so either create the basket with units such as `_five(100e18 + 1, ...)` and issue `1e18 + 1` shares, or drop 'Dust' from the name and comment. With `100e18 + 1` units, previewIssue(1e18+1) = ceil((1e18+1)*(100e18+1)/1e18) leaves 1 wei of rounding surplus. Add `assertGt(MockERC20(t[3]).balanceOf(address(idx)) - 12_345, Math.mulDiv(idx.totalSupply(), units3, 1e18))` before `_openAuction` to show the dust exists.

### XA-33 [INFO] Windfall control test calls a 250 gap '(fair - start) times the bought value at par', which gives 500 under R04's definition

- **Dimension:** Correctness (test-claim-false)
- **Location:** `test/Security.t.sol:1026-1035`
- **Reported by:** corr-tests-sec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

test/Security.t.sol:1034 `assertEq(taken - amountsIn[0] / 2, 250e18, "the gap is (fair - start) times the bought value at par");`. In test_R04 (line 763) the same suite defines 'bought value at par' as `boughtAtPar = 1_000e18` (10 shares x 100 extra units at snapshot prices). With fair = 2 and start = 1.5, (fair - start) x 1,000 = 500, not the asserted 250. The 250 is (fair - start) x the bought value at the post-move price (1,000 units x 0.5 = 500). The assertion is right, but the message states the formula readers will use for ARCHITECTURE's 'a windfall needs the fair multiplier above 1.5', and under the suite's own meaning of 'at par' it doubles the gap.

**Proposed fix (reviewer)**

test/Security.t.sol line 1034:
```diff
-        assertEq(taken - amountsIn[0] / 2, 250e18, "the gap is (fair - start) times the bought value at par");
+        assertEq(taken - amountsIn[0] / 2, 250e18, "the gap is (fair - start) times the bought value at current prices");
```

### XA-34 [INFO] Guardian-around-paused-WBTC fork test uses a bare expectRevert and never checks that WBTC is a shrinking leg

- **Dimension:** Correctness (weak-assertion)
- **Location:** `test/fork/Rebalance.fork.t.sol:217-227`
- **Reported by:** corr-tests-sec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

test/fork/Rebalance.fork.t.sol:226-227 `vm.expectRevert(); executor.fill(index); // WBTC must shrink, and its transfer fails`. The test never checks that amountsOut[0] > 0, and the bare expectRevert accepts any revert: an exactOutput `amountInMaximum` shortfall in RebalanceExecutorV3 (line 56), a Uniswap 'STF'/'Too little received', or RebalanceUnderfunded. If the rule's targets at a newer FORK_BLOCK stopped shrinking WBTC, or the first fill failed for an unrelated reason, the 'pause blocks the plain rebalance' half would still pass without showing what its comment claims. (WBTC's `whenNotPaused` reverts with empty data, which is why a bare expectRevert was used.)

**Proposed fix (reviewer)**

test/fork/Rebalance.fork.t.sol, before line 226:
```diff
         vm.warp(eta + index.AUCTION_DURATION());
+        (,, uint256[] memory amountsOut,) = index.previewRebalance();
+        assertGt(amountsOut[0], 0, "WBTC is a shrinking leg");
+        vm.prank(address(index));
+        (bool ok,) = A.WBTC.call(abi.encodeCall(IERC20.transfer, (address(1), 1)));
+        assertFalse(ok, "WBTC transfers from the index are paused");
         vm.expectRevert();
         executor.fill(index); // WBTC must shrink, and its transfer fails
```

### XA-35 [INFO] test_executeRebalance_growingUnitsRoundUp uses inputs that can never round, so the Ceil rounding of growing units is not checked by any test

- **Dimension:** Correctness (test-intent)
- **Location:** `test/IndexToken.rebalance.t.sol:347-353`
- **Reported by:** corr-tests-unit (reported LOW)
- **Verification:** combined: confirmed -> INFO

**Problem**

The test's name says growing units round up, but its inputs cannot produce a remainder. The code under test is src/IndexToken.sol:332: `: current + Math.mulDiv(target - current, multiplier, WAD, Math.Rounding.Ceil);`. The test (test/IndexToken.rebalance.t.sol:350-352) computes `uint256 exact = 100e18 * m;` and asserts `units[0] == 100e18 + exact / WAD + (exact % WAD == 0 ? 0 : 1)`. In this fixture the only growing component moves from 100e18 to 200e18, so `target - current` is 100e18, a multiple of WAD. `100e18 * m % 1e18` is always 0 for every multiplier, so the ceil branch is never reached and Ceil and Floor give the same result.

I checked this with a mutation in a private copy. I changed `Math.Rounding.Ceil` to `Math.Rounding.Floor` at IndexToken.sol:332, and all 247 unit, fuzz and invariant tests still pass. The invariant handler (IndexToken.invariant.t.sol:176-180) only checks the loose bound `afterwards*2 <= before*5 + 2`.

PoC: an index with units[0] = 100e18 + 7, started and previewed at eta + 1 (m = 1.499993055555555556e18). The base code gives units[0] = 249999305555555555618, and the PoC passes. The Floor mutant gives ...617, and the PoC fails.

Impact: if a refactor flipped the rounding, growing units would round toward the executor. Each fill would under-deliver up to supply/1e18 raw units per growing component (for example 1e6 raw units at 1e24 supply), and no test would catch it, even though the test name says it is checked.

**Proposed fix (reviewer)**

test/IndexToken.rebalance.t.sol:347-353, replace the test body so the unit change is not a multiple of WAD:

```solidity
function test_executeRebalance_growingUnitsRoundUp() public {
    uint256[] memory u = new uint256[](5);
    (u[0], u[1], u[2], u[3], u[4]) = (100e18 + 7, 100e18, 100e18, 100e18, 100e18);
    vm.prank(stranger);
    IndexToken idx = IndexToken(factory.createIndex("Odd", "ODD", tokens, u, 0));
    _issue(idx, alice, 1e18);
    uint256 eta = _start(idx);
    (,, uint256[] memory targets) = idx.pendingRebalance();
    vm.warp(eta + 1);
    (uint256 m, uint256[] memory units,,) = idx.previewRebalance();
    uint256 exact = (targets[0] - u[0]) * m;
    assertTrue(exact % WAD != 0, "the input must leave a remainder");
    assertEq(units[0], u[0] + exact / WAD + 1);
}
```
This version passes on the current code and fails when Ceil is changed to Floor (verified: 249999305555555555617 != ...618).

**Verifier (combined): confirmed -> INFO**

Confirmed in source. src/IndexToken.sol:332 rounds growing units with `Math.mulDiv(target - current, multiplier, WAD, Math.Rounding.Ceil)`. test/IndexToken.rebalance.t.sol:347-353 computes `exact = 100e18 * m`. Because 100e18 is a multiple of 1e18, `exact % WAD` is always 0. The ternary always adds 0, so the test cannot tell Ceil from Floor, even though its name says it checks rounding up. A mutation run confirms this: with Floor in place of Ceil, all 247 non-fork tests still pass. I lowered the severity to INFO. The production code is correct today, so there is no exploitable or runtime defect. The problem is a test that claims to check something it does not, which only matters if a later refactor flips the rounding. Recorded decisions are not affected.

*PoC:* Mutation test in the private copy /private/tmp/claude-501/-Users-nikolozsichinava-Xindex-v2/b204dcf3-fa74-4b31-bdbb-0d703fe0b644/scratchpad/poc/verify-ceil: changed IndexToken.sol:332 from Rounding.Ceil to Rounding.Floor, then ran `forge test --no-match-path 'test/fork/*'`. Output: "Ran 11 test suites ...: 247 tests passed, 0 failed, 0 skipped". The mutant survives. I did not rerun the reporter's proposed test; its numbers (…618 vs …617) are plausible for u0 = 100e18+7 with target 200e18.

*Fix assessment:* The proposed fix is correct and follows CLAUDE.md: it changes only a test, creates the index through the factory, and uses the existing _issue/_start helpers. Making the start units 100e18+7 makes target minus current a non-multiple of WAD. The line `assertTrue(exact % WAD != 0)` stops the test from going vacuous again, and asserting `+1` exactly kills the Floor mutant. Two things to check. First, `targets[0]` must still be above u[0] for the odd composition. The rule's target depends on the supply and prices in the mock market and not on the start units, so this should hold, but the test should also assert `targets[0] > u[0]`. Second, the CREATE2 salt for the new composition must not collide with the fixture index; different units give a different salt, so it will not.

*Tests a fix must add:*

- Growing-unit rebalance where (target - current) * multiplier % 1e18 != 0, asserting units == current + floor + 1 (kills the Ceil->Floor mutant)
- Guard assertion that the chosen inputs leave a remainder and that target > current, so the test cannot become vacuous

### XA-36 [INFO] Four revert tests use bare vm.expectRevert(), so they pass on any revert

- **Dimension:** Correctness (under-specified-revert)
- **Location:** `test/IndexToken.rebalance.t.sol:387-393`
- **Reported by:** corr-tests-unit (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

CLAUDE.md says new revert paths need a test that hits the exact error. These tests accept any revert:
- test/IndexToken.rebalance.t.sol:391 `vm.expectRevert();` in test_executeRebalance_onlyContracts
- test/IndexToken.t.sol:278 in test_issue_revertsWithoutApproval
- test/IndexToken.t.sol:375 in test_redeem_revertsInsufficientBalance
- test/IndexZap.t.sol:614 in test_burn_revertsWithoutApproval

The worst is onlyContracts. The call reverts at the high-level callback `IRebalanceExecutor(msg.sender).onXindexRebalance(...)` (IndexToken.sol:282) with empty data, because the stranger is an EOA. If a change turned that into a low-level call that ignores failure, `_checkBacking` would still revert with RebalanceUnderfunded(tokens[0], 1_000e18, 2_500e18), because amountsIn[0] = 1_500e18 at the open. The test would stay green even though it no longer checks what its name says.

The other three would also pass on unrelated reverts, for example a ZeroShares or NotIndex regression. I confirmed in a private copy that each test's actual revert matches the exact data in the proposed fix.

**Proposed fix (reviewer)**

Pin the exact revert data (all four verified passing on the current code):

test/IndexToken.rebalance.t.sol:391
- vm.expectRevert();
+ vm.expectRevert(bytes("")); // the callback to an account without code reverts with no data

test/IndexToken.t.sol:278
- vm.expectRevert();
+ vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(index), 0, need[0]));

test/IndexToken.t.sol:375
- vm.expectRevert();
+ vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 1e18 + 1));

test/IndexZap.t.sol:614
- vm.expectRevert();
+ vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(zap), 0, 1e18));

(import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol" in IndexToken.t.sol)

### XA-37 [INFO] MockUniswapV3Pool does not model a lazily grown oracle ring, so the claim that 200 slots 'can never run out of history' is never tested and is wrong right after growth

- **Dimension:** Correctness (mock-fidelity)
- **Location:** `test/mocks/MockUniswapV3.sol:14,58-80`
- **Reported by:** corr-tests-unit (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

The mock ties the cardinality it reports to how much history it has. `observationCardinality` defaults to 1_000 (line 14). `slot0` returns it (line 61). `observe` only reverts "OLD" when a test sets `historyTooShort` by hand (line 69). So a cardinality of 200 or more always comes with unlimited history.

On a real Uniswap V3 pool this is not true. Oracle.write raises `cardinality` to `cardinalityNext` in the same write that fills slot C-1. The new slots C..199 stay uninitialized until later writes fill them, and `getSurroundingObservations` falls back to `self[0]` as the oldest observation. Just after growth from C, the ring holds only about C writes. On an active pool with one write per 12 s block and C < 150, that is under 30 minutes. `observe([1800, 0])` then reverts "OLD" for up to about 150 blocks, while slot0 already reports cardinality 200.

The source and docs state the stronger guarantee: src/IndexRule.sol:30 ("200 slots always cover 40 minutes"), :168-169 and src/interfaces/IIndexRule.sol:30 ("can never run out of history"), and ARCHITECTURE.md:116. The fork test hides the gap by waiting after growth: test/fork/IndexZap.fork.t.sol:377-378 calls `_growObservations(...)` and then `vm.warp(block.timestamp + 1 hours)` before `proposeListing`.

Impact is small and temporary. `IndexRule._checkPool` (IndexRule.sol:177-179) accepts the cardinality and then reverts with the raw "OLD" string instead of `PoolHistoryTooShort` when a listing is proposed just after growth. Once `checkConfig` has succeeded, the history only grows (to at least 40 minutes once the ring is full), so listed pools are not affected. I reasoned about Oracle.sol from Uniswap v3-core. Its source is not vendored, so I could not run this against it.

**Proposed fix (reviewer)**

1) Make the docs match: src/IndexRule.sol:30 and :168-169, src/interfaces/IIndexRule.sol:30, ARCHITECTURE.md:116. Before/after:
- "so a TWAP_WINDOW average can never run out of history"
+ "so, once the ring has filled, a TWAP_WINDOW average can never run out of history; a pool whose ring was just grown can still reject the 30-minute average until enough new observations are written, and `checkConfig` then reverts with the pool's `OLD`"

2) Let the mock model limited history, in test/mocks/MockUniswapV3.sol:
```solidity
uint32 public historySeconds = type(uint32).max;
function setHistorySeconds(uint32 s) external { historySeconds = s; }
// in observe, inside the loop:
if (secondsAgos[i] > historySeconds) revert("OLD");
```
and add a test in test/IndexRule.t.sol: `pool.setObservationCardinality(200); pool.setHistorySeconds(1_200); vm.expectRevert(bytes("OLD")); rule.checkConfig(token, config);`.

3) In test/fork/IndexZap.fork.t.sol:377-378, add a comment that the 1-hour warp is needed because a just-grown ring may not hold 30 minutes yet.

### XA-38 [INFO] Deployment uses CREATE and freezes no release record (address, codehash, creation and runtime bytecode)

- **Dimension:** Hazard (hazard-cat-9)
- **Location:** `script/Deploy.s.sol:57-78`
- **Reported by:** orchestrator (reported MEDIUM); also R1-sec-scripts-5
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

Orchestrator hypothesis. new IndexFactory / new IndexZap deploy at nonce-dependent addresses; the rule and implementation follow the factory. Nothing in the repo pins deployed addresses with codehash and bytecode per release or checks them on a fork; README tables are hand-copied. The skill rates a non-deterministic production deploy path and a missing release record HIGH by default; judge the right severity for a single-chain deployment consumed by a separate web app.

**Proposed fix (reviewer)**

Deploy through the canonical CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) with a fixed salt; commit deployments/<chainId>/<version>.json with address, codehash, creation and runtime bytecode; add a fork test asserting address.code == runtime bytecode and keccak256 == codehash, and that factory.RULE()/IMPLEMENTATION() match.

**Verifier (combined): partially-confirmed -> INFO**

Confirmed: script/Deploy.s.sol:66-67 deploys with plain CREATE (`factory = new IndexFactory(...)`, `zap = new IndexZap(...)`), so the addresses depend on the deployer's nonce. Nothing in the repo stores runtime bytecode or codehash, and no fork test checks deployed code against a build.

Refuted: the claim that the repo "freezes no release record". Broadcast logs are committed on purpose (.gitignore un-ignores /broadcast and ignores only chain 31337 and dry-run). broadcast/Deploy.s.sol/11155111/run-latest.json records `commit: 8c28c7d`, the IndexFactory CREATE transaction with its full initcode (84,684 hex chars) and the IndexZap CREATE transaction (16,926 hex chars). It also records the factory address 0x3541...2cb1, the rule 0x09da...a234 and implementation 0x0eb8...a311 (as additionalContracts), the zap 0xf021...2e1f, and a status-1 receipt. The README's Sepolia table (lines 301-316) matches these addresses exactly and says "Deployed on 2026-09-16 from commit `8c28c7d`". So a record exists that ties each address to a commit and its creation code, and it can be reproduced from source. The documented command also uses `--verify`, which publishes the source on Etherscan.

Reachability and impact: CREATE is only a risk when you need the same address on several chains, or when an address is predicted before deployment and something relies on that prediction. This project deploys to one chain (Ethereum mainnet, plus a Sepolia rehearsal). The web app reads the addresses from the finished deployment's logs and broadcast file, not from a prediction. A nonce mismatch just produces a different address that gets logged and recorded; no funds or permissions are exposed. Index clones already use CREATE2 (IndexFactory), which is the only place CLAUDE.md requires address commitment. What is really missing is small: no codehash or runtime bytecode file and no automated check against a fork. That is a traceability suggestion with no direct risk, so INFO, not the MEDIUM/HIGH default. The mainnet table says "not deployed yet", so no mainnet release has gone out without a record.

*PoC:* No test run. This is a claim about deployment process and repo artifacts, not runtime behaviour. I checked it by parsing the committed broadcast/Deploy.s.sol/11155111/run-latest.json with python3 and comparing it to the README tables and .gitignore.

*Fix assessment:* The proposed fix goes further than the risk calls for, and part of it is unnecessary. Switching to the canonical CREATE2 deployer (0x4e59...956C) is compatible with CLAUDE.md but has a catch. IndexFactory's constructor sets `owner` and deploys the rule and implementation with CREATE from the factory. If the factory is deployed through the CREATE2 proxy, its address commits to the owner, guardian and market addresses through the initcode. msg.sender inside the constructor becomes the proxy, which does not matter here because the owner is passed in explicitly. The README also notes the factory initcode is close to the EIP-3860 limit, and the proxy route leaves that unchanged. None of this has security value for a single-chain deployment, so it is optional.

The useful part is cheap:
(1) Keep committing the broadcast files, as the repo already does.
(2) Optionally add deployments/<chainId>.json with the commit, the addresses, and keccak256 of each contract's runtime code (factory, RULE(), IMPLEMENTATION(), zap).
(3) Optionally add a fork test, skipped when the RPC variable is unset, that asserts `keccak256(addr.code) == recorded codehash` and `factory.RULE() == rule`, `factory.IMPLEMENTATION() == impl`, `zap.FACTORY() == factory`.
Note that runtime-code equality with local `vm.getDeployedCode` fails for contracts with immutables (IndexFactory, IndexZap and IndexRule have them), so the test must compare against the recorded on-chain codehash, not freshly compiled bytecode.

*Tests a fix must add:*

- Fork test, skipped when the RPC variable is unset: each recorded deployment address has code whose keccak256 equals the recorded codehash
- Fork test: factory.RULE() and factory.IMPLEMENTATION() equal the recorded rule and implementation addresses, and the zap's factory reference equals the recorded factory
- If the deploy moves to CREATE2: a unit test in test/Scripts.t.sol asserting that Deploy.deploy returns the address predicted from the salt and initcode

### XA-39 [INFO] Deploy.checkOwner accepts any mainnet contract without getThreshold, including a market address pasted as OWNER

- **Dimension:** Hazard (convention-vs-enforcement)
- **Location:** `script/Deploy.s.sol:82-101`
- **Reported by:** hazard-enforce (reported LOW)
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

Hazard: CLAUDE.md requires a mainnet owner that is a contract, not EIP-7702 delegated, and a Safe with at least two signatures. The script positively recognises only the Safe case. Code (Deploy.s.sol:91-95): `(bool ok, bytes memory data) = owner.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ()));` then `if (ok && data.length == 32) { ... if (threshold < 2) revert ... }`. Any other contract with code is accepted, and the test pins that on purpose: `deployer.checkOwner(address(router)); // a contract without getThreshold, such as a timelock` (test/Scripts.t.sol:126). `checkGuardian` is `pure` (Deploy.s.sol:99-101) and never compares the guardian against the market addresses.

Production scenario: the Env block puts OWNER next to WETH, USDC and SWAP_ROUTER (Deploy.s.sol:17-25). An operator sets `OWNER=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (WETH) or the USDC proxy. Both have code, are not 0xef01-prefixed, and revert or return no 32-byte word for getThreshold, so `checkOwner` passes. The same applies to a single-key ERC-4337 smart account or a timelock whose only proposer is an EOA.

The factory then deploys with an owner that can never call `proposeListing` or `transferOwnership`, and `renounceOwnership` is disabled (IndexFactory.sol:284). The deployment is dead: no token can ever be listed, and it must be redeployed. If the app or indexer was already pointed at it, the addresses must be migrated. In the single-key smart-account case, the multisig requirement is silently not met. No user funds are at risk, because nothing can be listed.

**Proposed fix (reviewer)**

script/Deploy.s.sol: reject owner and guardian addresses equal to any market address, and require positive identification of a non-Safe owner.
```diff
     function deploy(address owner, address guardian, Market memory market)
         public
         returns (IndexFactory factory, IndexZap zap)
     {
         checkOwner(owner);
         checkGuardian(owner, guardian);
         market = resolveMarket(market);
+        _checkNotMarket(owner, market);
+        _checkNotMarket(guardian, market);
@@
+    error RoleIsMarketContract(address account);
+
+    function _checkNotMarket(address account, Market memory m) private pure {
+        if (account == m.router || account == m.weth || account == m.uniswapV3Factory || account == m.usdc) {
+            revert RoleIsMarketContract(account);
+        }
+    }
```
In `checkOwner` (lines 91-95), when getThreshold gives no answer, accept the owner only if it answers `getMinDelay()` (OpenZeppelin TimelockController) with a non-zero value. Otherwise revert `OwnerMustBeContract(owner)`. Change test/Scripts.t.sol:126 to expect that revert for the router, and add a mock timelock case that passes.

**Verifier (combined): partially-confirmed -> INFO**

Reachability: confirmed in source. Deploy.s.sol:86-95 rejects only an owner with no code, an EIP-7702 delegated owner, or a contract whose getThreshold returns one word below 2. Any other contract passes, and the code does this on purpose: the comment at lines 88-89 says a contract without getThreshold "is accepted as it is", and test/Scripts.t.sol:126 checks that the router is accepted. checkGuardian (lines 99-101) is pure and only compares against zero, DEFAULT_SENDER and the owner. So OWNER=WETH or OWNER=USDC would pass the checks on chain 1.

Impact is much smaller than LOW. (1) Pasting a market address as OWNER is a typo. The operator sets that variable and gets a deploy log that prints the owner (line 74). (2) The result is a factory that holds no funds. Nothing can be listed, so no index can hold anything and no user funds are ever at risk. The first proposeListing from the intended owner reverts right away, and the fix is to redeploy, which only costs gas. Indexes can only be created after listings, so the app would have nothing to migrate. (3) The single-key ERC-4337 or timelock case does not break a stated rule. CLAUDE.md and README require "a Safe owner must need at least two signatures". That rule is about Safes, and the script enforces it. Accepting other contracts is a deliberate choice that the code comment documents, so the finding is not a missing check against a stated rule. The finding is right that the script cannot prove a non-Safe contract is multi-party, but that is a convenience limit of a deploy script, not a defect you can exploit. Design intent: this is partly documented (non-Safe contracts are accepted on purpose), but the docs do not mention a market address being accepted by mistake. That leaves an INFO-level hardening suggestion.

*PoC:* Not run. The acceptance path is already covered by the existing test/Scripts.t.sol:126 (the router contract passes checkOwner on chain 1), and WETH or USDC would take the same branch: they have code, no 0xef01 prefix, and give no 32-byte getThreshold answer. The impact (a factory that cannot list and holds no funds) follows directly from onlyOwner on proposeListing and needs no runtime proof.

*Fix assessment:* The market-address check (_checkNotMarket on owner and guardian after resolveMarket) is correct, cheap and consistent with CLAUDE.md. Two fixes to the diff: checkGuardian is called before resolveMarket, so the new check must run after `market = resolveMarket(market)`, as the diff places it. The error also needs a unit test. The second part, accepting a non-Safe owner only if getMinDelay() is non-zero, is not advisable as proposed. It would reject legitimate multi-party owners that are not an OpenZeppelin TimelockController (a Governor, a Compound Timelock with delay(), other multisig implementations), and a TimelockController whose only proposer is an EOA would still pass, so it does not deliver the multisig assurance it claims. It also reverses a behaviour the code comment deliberately documents. A better fix: keep the market-address rejection, and for a contract without getThreshold, either log a prominent console2 warning or require an explicit opt-in env flag (for example OWNER_NOT_SAFE=true, set by one test per the env-var convention). Update README/Deploy natspec to say a non-Safe contract owner is not checked for multiple signers.

*Tests a fix must add:*

- checkOwner/deploy on chain 1 with owner == MAINNET_WETH, MAINNET_USDC, router and Uniswap V3 factory reverts RoleIsMarketContract
- deploy with guardian equal to a resolved market address reverts RoleIsMarketContract
- deploy with a custom (non-default) market address as owner on a non-mainnet chain reverts
- if an opt-in flag is added: a non-Safe contract owner reverts without the flag and passes with it

### XA-40 [INFO] Whitelist policy checks that the rule could make cheaply (6-18 decimals, no USDC component) are enforced only socially

- **Dimension:** Hazard (convention-vs-enforcement)
- **Location:** `src/IndexRule.sol:73-88`
- **Reported by:** hazard-enforce (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

Hazard: the whitelist policy at IndexFactory.sol:32-35 and ARCHITECTURE.md section 5 says '6-18 decimals' and 'stables are mint currencies, not components', but nothing on-chain or in the scripts checks either rule. `checkConfig` (IndexRule.sol:73-88) validates exclusions, the pool and supply only. `ConfigureWhitelist.parseEntry` (script/ConfigureWhitelist.s.sol:115-128) accepts any address.

The rule already stores `USDC` as an immutable (IndexRule.sol:40), and its own USD_POOL passes `_checkPool` for USDC. So `proposeListing(USDC, {pool: USD_POOL, ...})` passes every check.

Production scenario for decimals: a custom `WHITELIST` entry for a 2-decimal token worth about 1 ETH ($3000) passes `checkConfig`. `initialUnits` for a $100 index at a 10% weight computes 0.33 raw units, which floors to the minimum of 1 raw unit (IndexRule.sol:160). That unit is worth $30, so the index starts at about 30% weight instead of 10%. A rebalance cannot shrink it: `lo = (1 + 1) / 2 = 1` (IndexRule.sol:360). The index is permanently mis-weighted with no revert. Only the 2-day listing delay and a reviewer would catch it.

**Proposed fix (reviewer)**

src/IndexRule.sol, in `checkConfig` before `_checkPool` (line 86):
```diff
+        if (token == USDC) revert InvalidSupplyConfig(token);
+        uint8 d = IERC20Metadata(token).decimals();
+        if (d < 6 || d > 18) revert InvalidSupplyConfig(token);
         _checkPool(token, config.pool);
```
Add `import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";`. Add a unit test that lists a 2-decimal mock and USDC and expects `InvalidSupplyConfig`. USDT is not known on-chain, so keep an assertion in test/Scripts.t.sol that `defaultMainnetList()` contains neither USDC nor USDT.

### XA-41 [INFO] Zap params structs and full error/event surface have no interface or generated ABI for the separate web app

- **Dimension:** Hazard (cross-repo-drift)
- **Location:** `src/IndexZap.sol:43-80, 103-113; README.md:142-177`
- **Reported by:** hazard-ops (reported LOW); also R1-quality-repo-5, H-12
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

Hazard: the web app lives in another repo and consumes `MintParams`/`BurnParams`/`MintLeg`/`BurnLeg` and the custom errors by selector. `src/interfaces/` has no `IIndexZap`. The structs, events and errors are declared only in the concrete IndexZap.sol, `out/` is gitignored, and no ABI is committed or published. The hand-written README list is already incomplete. It omits the zap's `NotIndex`, `Expired` and `ZeroAddress` (IndexZap.sol:103-106), which a user hits with an expired deadline, and the rule's `DegenerateBasket`, `NotIndex` and `InvalidMethodology`. Scenario: a later zap revision reorders `BurnParams`, for example to add a field. The app's hand-copied ABI still encodes the old tuple, so calls revert with an undecoded selector, or, worse, fields line up differently with the same types (`shares`/`minAmountOut` are both uint256). Nothing in either repo detects the drift.

**Proposed fix (reviewer)**

Add `src/interfaces/IIndexZap.sol` declaring the four structs, three events, eleven errors and three entry points. Make `contract IndexZap is IIndexZap, ReentrancyGuard`. Commit `abi/{IndexFactory,IndexToken,IndexRule,IndexZap}.json`, generated by `forge inspect <C> abi`, with a CI step `for c in ...; do forge inspect $c abi | diff - abi/$c.json; done`, so every ABI change is an explicit diff the web-app repo can pin.

**Verifier (combined): partially-confirmed -> INFO**

The facts in the finding are accurate. src/interfaces/ has no IIndexZap. MintLeg, BurnLeg, MintParams and BurnParams (IndexZap.sol:43-80), the three events (86-101) and the eleven errors (103-113) exist only on the concrete contract. .gitignore excludes out/, there is no abi/ directory, and no CI step checks ABIs. The README list "Errors worth handling" (README.md:~168-173) leaves out the zap's NotIndex, Expired and ZeroAddress, and the rule's DegenerateBasket, NotIndex, InvalidMethodology and LengthMismatch. The failure scenario is hypothetical, though. It needs a future zap change that reorders a struct, a redeploy at a new address (the zap is stateless and replaceable, so a change always means a new deployment the app must switch to anyway), and a web-app team that points at the new address but keeps the old hand-copied ABI. Nothing on-chain is at risk. A misencoded call cannot move funds past the zap's own checks: nonce, leg count, path endpoints, limits and balance-delta measurement all still apply. At worst, mixing up shares and minAmountOut changes the user's own slippage bound or share count in a transaction the user signs and the app simulates. That is a process and documentation hygiene point with no direct risk, so INFO rather than LOW. The README error list is incomplete, but the omitted errors revert safely; the only effect is an undecoded message in the UI.

*PoC:* Not run. The claim is about which files and docs exist, not about runtime behaviour, so I checked it with ls, grep and reading the source.

*Fix assessment:* The proposed fix is correct and fits CLAUDE.md. An IIndexZap interface holding the structs, events, errors and entry points, with `contract IndexZap is IIndexZap, ReentrancyGuard`, follows the existing pattern where IIndexToken, IIndexFactory and IIndexRule carry their errors. The contract's references to MintParams and the other types would need to resolve through inheritance, or be qualified as IIndexZap.MintParams in tests and scripts. The Solidity pragma must be 0.8.28, and forge fmt and lint must stay clean. The committed abi/*.json files with a `forge inspect | diff` CI check are optional tooling. They also need the build profile pinned so the output is stable. The cheaper essential part is completing the README "Errors worth handling" list: add IndexZap NotIndex, Expired and ZeroAddress, and IndexRule DegenerateBasket, InvalidMethodology, LengthMismatch and NotIndex. A 100% coverage requirement applies to any new interface file only in that interfaces have no executable lines.

*Tests a fix must add:*

- Compile-time check that IndexZap implements IIndexZap: a test calls mintExact and burnToToken through an IIndexZap-typed reference
- Tests expecting reverts with the IIndexZap.Expired, IIndexZap.NotIndex and IIndexZap.ZeroAddress selectors through the interface
- A CI step, if ABIs are committed, that diffs `forge inspect IndexZap abi` against abi/IndexZap.json

### XA-42 [INFO] Recurring operator duties (execute window, monthly trigger, keep mask, supply refresh) have no runbook, owner, or monitor

- **Dimension:** Hazard (manual-operational-steps)
- **Location:** `README.md:196-199, 284-291; ARCHITECTURE.md:284-287`
- **Reported by:** hazard-ops (reported INFO)
- **Touches a recorded product decision:** yes
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

Hazard: correct long-run behaviour depends on time-boxed manual steps that are scattered through prose, and none of them has an assigned party or an alert. (1) Every proposal must be executed between eta and eta + 7 days (IndexFactory.sol:208-209). A missed config change expires silently, and the old config stays in force. (2) A permanently frozen component needs the guardian to cancel and restart with a keep mask at every monthly rebalance (README:209). (3) Reference supplies are hard-coded with a date (ConfigureWhitelist.s.sol:44-47, CoinGecko 2026-09-15), and the on-chain config has no as-of timestamp, so staleness cannot be seen from chain state. (4) The guardian is expected to cancel a distorted snapshot within the 2-day notice, but nothing states what to watch (`RebalanceStarted` targets vs `previewTarget(0)`, TWAP vs spot). Scenario: the Sepolia listings proposed 2026-09-16 must be executed by 2026-09-25 13:05 UTC (README:321-322), and nothing but that sentence records the deadline. The same pattern on mainnet means a missed window, another round of Safe signatures and a 2-day delay, all silently.

**Proposed fix (reviewer)**

Add `OPERATIONS.md` with a table: duty | trigger event | deadline formula | who (Safe signers / guardian / anyone) | command. Add a `LISTING_MODE=status` branch in ConfigureWhitelist.run() that prints, per entry, `listingEta`, window end, whitelisted and config-differs, plus the age of each reference supply (a `referenceSupplyAsOf` date kept next to each Entry). Operators can then run one read-only command, for example from a scheduled CI job with the RPC secret, and fail when a window closes in under 48h.

### XA-43 [INFO] Broadcast records from mainnet-fork rehearsals are committed as if real; committed broadcast provenance is not checked against the README

- **Dimension:** Hazard (generated-artifacts-stale-detection)
- **Location:** `.gitignore:9-12 (also README.md:286-287, broadcast/SetupTestMarket.s.sol/11155111/*)`
- **Reported by:** hazard-truth (reported LOW); also R1-process-3, R1-hazard-ops-5, H-11
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

(1) Hazard: files under broadcast/ are generated deployment records that people and tools treat as the truth about what is deployed, and nothing checks them.
(2) Shape: .gitignore:10-12 un-ignores `/broadcast` and ignores only `/broadcast/*/31337/` and `**/dry-run/`. README.md:286-287 tells operators to rehearse with `anvil --fork-url $MAINNET_RPC_URL` "and run the same scripts". A mainnet fork keeps chain id 1, so a rehearsal `--broadcast` writes broadcast/Deploy.s.sol/1/run-latest.json, and git does not ignore it. The user's own notes (anvil-fork-gotchas) record this trap, but the repo does not guard against it. The committed Sepolia records already show the provenance gap. Every run's `commit` field is `8c28c7d`, yet script/testnet/SetupTestMarket.s.sol first appears in d9e4363, so those runs came from an uncommitted tree. run-1789557731926.json also records an abandoned first `create` (tUSDC 0x1bd45318671106ca3f1d4c127fc69531541aa8d4 and 4 more tokens and pools). Those tokens are not the ones in the README table (tUSDC 0x740235f5...), and nothing marks them as dead. The README Sepolia addresses do match run-1789560144365 and the Deploy run today (checked; the RULE and implementation match CREATE nonces 1 and 2 of the factory), but only because they were copied by hand.
(3) Scenario: an operator rehearses the mainnet deploy on an anvil fork from the real deployer keystore, then commits with `git add -A`. broadcast/Deploy.s.sol/1/run-latest.json now lists an IndexFactory and IndexZap at the deployer's next CREATE addresses. The web app, or an integrator following Foundry convention, reads chain 1's run-latest and points users at addresses with no code on mainnet. A user who approves USDC to that zap address before the real deploy lands creates an allowance for whatever the deployer later puts at that nonce. Separately, someone reading the Sepolia broadcast directory can pick up the orphaned faucet tokens.
(4) Structural fix: ignore chain 1 by default, so a real mainnet record needs a deliberate `git add -f`. Add a CI step that parses every committed broadcast run-latest.json and checks each contractAddress against the README tables, so a stale or rehearsal record fails CI.

**Proposed fix (reviewer)**

.gitignore:
 # Ignores development broadcast logs
 !/broadcast
 /broadcast/*/31337/
 /broadcast/**/dry-run/
+# Mainnet-fork rehearsals keep chain id 1; commit a real mainnet run with `git add -f` only
+/broadcast/*/1/

.github/workflows/test.yml, new step after checkout:
      - name: Committed deployments match README
        run: |
          set -euo pipefail
          for f in $(git ls-files 'broadcast/*/run-latest.json'); do
            for a in $(jq -r '.transactions[] | select(.transactionType=="CREATE") | .contractAddress' "$f"); do
              grep -qi "$a" README.md || { echo "::error::$f creates $a which README.md does not list"; exit 1; }
            done
          done

Delete the orphaned run broadcast/SetupTestMarket.s.sol/11155111/run-1789557731926.json (or add a note next to the README Sepolia table that the tokens in it are abandoned). README.md:287: add "delete broadcast/*/1/ after a fork rehearsal".

**Verifier (combined): partially-confirmed -> INFO**

The facts in the finding check out in source. (1) .gitignore:9-12 ignores only /broadcast/*/31337/ and dry-run folders, so chain-1 records are tracked. (2) README.md:287 tells operators to run "the same scripts" against `anvil --fork-url $MAINNET_RPC_URL`. A fork keeps chain id 1 unless --chain-id is passed, so `--broadcast` writes to broadcast/<script>/1/. (3) Every committed broadcast JSON records commit 8c28c7d, but script/testnet/SetupTestMarket.s.sol was first added in d9e4363, so the Sepolia runs came from an uncommitted tree. (4) run-1789557731926.json creates FaucetTokens at 0x1bd45318..., 0x5da617b2..., 0xd46c1fd7..., 0xb595764d... and 0x347fdd85..., none of which appear in the README. The README table (README.md:314) uses the later run's addresses (tUSDC 0x740235f5...). No doc marks the first run as abandoned. The Deploy run-latest addresses (factory 0x3541..., zap 0xf021...) do appear in the README.
Impact is overstated. No contract or on-chain value is affected. The harm needs a chain of human mistakes: an operator broadcasts a fork rehearsal, commits it with `git add -A`, and a consumer then trusts broadcast/*/1/run-latest.json over the README. Nothing in this repo reads broadcast files; the web app is a separate repo, and I found no evidence it reads them. Anyone who approves USDC to an address with no code has approved nothing a stranger can use. The allowance only matters if the same deployer later puts a contract at that nonce, and that contract would be the real zap. That is the deployer's own contract, not an attacker's. The orphaned Sepolia faucet tokens are testnet-only and worthless. This is a repo-hygiene and provenance issue, so INFO rather than LOW.

*PoC:* Not run as a Forge PoC because this is a repo-hygiene issue, not runtime behaviour. I checked it with git ls-files, jq over the committed broadcast JSON (commit field and CREATE addresses), git log --diff-filter=A, and grep against README.md.

*Fix assessment:* The .gitignore addition `/broadcast/*/1/` is correct, small and fits CLAUDE.md; a real mainnet record then needs a deliberate `git add -f`. Two cautions. First, after a real mainnet deploy, later `git add -A` runs will skip updates to run-latest.json in that tracked folder. Ignore rules do not apply to files that are already tracked, so this is fine in practice, but the README should say to force-add the first real record. Second, the proposed CI step only checks CREATE entries in run-latest.json against README.md. That passes today: the Deploy run-latest addresses are in the README, and SetupTestMarket's run-latest has only CALLs. It would not catch the orphaned timestamped run, and it misses contracts created inside a CALL (additionalContracts, such as the Uniswap pools). A shell loop `for f in $(git ls-files ...)` over paths without spaces is acceptable. A better fix also covers the Sepolia side: add a README line next to the Sepolia table saying run-1789557731926 is an abandoned first attempt, or delete that file (deleting it loses history, so a note is preferable). Also note in README.md:287 to pass `--chain-id 31337` to anvil for rehearsals, which sends broadcasts to the already-ignored 31337 folder. That is simpler and more robust than asking people to delete broadcast/*/1/ by hand. The commit-provenance gap (commit 8c28c7d on runs that needed d9e4363) cannot be fixed after the fact. The fix is procedural: deploy only from a clean, committed tree. That could be a line in the README deployment section.

*Tests a fix must add:*

- CI check that every CREATE contractAddress in committed broadcast/*/run-latest.json appears in README.md (and covers additionalContracts if pools are listed)
- git check-ignore test: broadcast/Deploy.s.sol/1/run-latest.json is ignored after the .gitignore change
- Documentation check: README Sepolia section names the abandoned run-1789557731926 or the file is removed

### XA-44 [INFO] The web app's error, event and constant lists are hand-copied into the README with no generated ABI; the error list is already incomplete

- **Dimension:** Hazard (generated-artifacts-stale-detection)
- **Location:** `README.md:168-177 (also 42, 48, 132, 197, 277; ARCHITECTURE.md:58-65)`
- **Reported by:** hazard-truth (reported LOW)
- **Verification:** combined: partially-confirmed -> INFO

**Problem**

(1) Hazard: the separate web-app repo has to mirror the contracts' ABI (errors, events, structs) and timing constants. Its only source is prose in README.md.
(2) Shape: no ABI export is committed (out/ is gitignored), and no CI job generates or diffs one. README.md:172-177 lists "Errors worth handling", and it already misses errors that users hit in normal flows. `IndexZap.Expired()` (IndexZap.sol:105) is missing, although README.md:155 tells the app to "use short deadlines". Also missing: `IndexZap.NotIndex`, `IndexToken.NoPendingRebalance` (IIndexToken.sol:52, hit when the auction button is pressed after a cancel or fill), `ZeroShares`, `TransferAmountMismatch`, `InvalidRecipient`, and `IndexRule.DegenerateBasket`, `InvalidMethodology`, `NotIndex` (IIndexRule.sol:21-25). The docs also restate the constants by hand: 28 days, 2 days, 24 hours, 1.5 to 0.9, "2 to 9 days" (README.md:277, 340, which is LISTING_DELAY + PROPOSAL_WINDOW), "Max 20 components", 200 slots, "up to 8 excluded" (README.md:132, 191), MIN_TURNOVER 0.5% (ARCHITECTURE.md:60).
(3) Scenario: a user's zap burn lands after its short deadline. The app's selector table, built from the README list, has no entry for `Expired()` (0x203d82d8), so it shows an unknown-revert message instead of "quote expired, retry". Likewise a v2.x change to, say, PROPOSAL_WINDOW updates the code and a few sentences, but not "2 to 9 days" in the README, so the app's pending-listing countdown is wrong.
(4) Structural fix: generate the interface artifacts the app consumes and check them in CI. Have the README point to the artifacts instead of enumerating them, and tell the app to read constants on-chain.

**Proposed fix (reviewer)**

Add abi/ with the output of `forge inspect <Contract> abi --json` for IndexFactory, IndexToken, IndexRule and IndexZap, and a CI step in .github/workflows/test.yml after `forge build --sizes`:
      - name: ABI artifacts are current
        run: |
          for c in IndexFactory IndexToken IndexRule IndexZap; do forge inspect $c abi --json > abi/$c.json; done
          git diff --exit-code abi/
README.md:172-177, replace the enumerated lists with: "Decode every revert with the ABIs in `abi/` (errors include `IndexZap.Expired`, `IndexToken.NoPendingRebalance`, `IndexRule.DegenerateBasket`). Read `LISTING_DELAY`, `PROPOSAL_WINDOW`, `MIN_REBALANCE_INTERVAL`, `REBALANCE_DELAY`, `AUCTION_DURATION`, `AUCTION_*_MULTIPLIER`, `MIN_TURNOVER`, `MAX_COMPONENTS` on-chain rather than hard-coding them." At minimum, add `Expired`, `NotIndex`, `NoPendingRebalance`, `ZeroShares`, `TransferAmountMismatch`, `InvalidRecipient`, `DegenerateBasket` and `InvalidMethodology` to the list.

**Verifier (combined): partially-confirmed -> INFO**

The facts hold up. README.md:172-177 ("Errors worth handling") leaves out several errors that normal use can hit. The biggest gap is `IndexZap.Expired()`, raised at IndexZap.sol:308 (`if (block.timestamp > deadline) revert Expired();`), even though README.md:155 tells the app to use short deadlines. `IndexToken.NoPendingRebalance()` is also missing; it is raised at IndexToken.sol:252 and 318 when someone cancels or executes after the pending rebalance is gone. Also missing are ZeroShares, TransferAmountMismatch, the token's InvalidRecipient, and the rule's DegenerateBasket and InvalidMethodology. No ABI files are committed (.gitignore excludes out/), and CI has no ABI step. The constants are copied by hand into the prose.

The impact is overstated, though. Nothing here touches the contracts, funds or the design rules. The header "worth handling" chooses errors rather than claiming to list them all. The contracts compile to ABIs with every custom error, so the web app can decode them from any build. If an error is missing from the list, the transaction still reverts; the app just shows a generic message. The stale-constant example is made up: "2 to 9 days" at README.md:277/340 matches LISTING_DELAY = 2 days plus PROPOSAL_WINDOW = 7 days today (IndexFactory.sol:39,41). The only real effect is how the app displays errors, so the right severity is INFO, not LOW. None of the repo's docs mention this risk, so documented-accepted does not apply.

*PoC:* Not run. This is a documentation and off-chain integration claim with no runtime behaviour to test; I checked it by grepping the error declarations and revert sites against the README list.

*Fix assessment:* The proposed fix is sound and does not break any CLAUDE.md design rule, since it changes only docs and CI and leaves src/ alone. Committing `forge inspect <C> abi --json` output with a `git diff --exit-code abi/` CI step would catch drift. It needs the same pinned solc and forge version as the build, and each `forge inspect` output must pass through the formatter, or CI will flag spurious diffs. Two smaller changes would also work: reword the README heading so the list is clearly partial ("decode all reverts from the compiled ABI; common ones are..."), then add Expired, NoPendingRebalance, ZeroShares, TransferAmountMismatch, InvalidRecipient (token), DegenerateBasket, InvalidMethodology and NotIndex. The advice to read constants on-chain is good, but "2 to 9 days" is correct today and needs no change.

*Tests a fix must add:*

- CI step that regenerates abi/*.json for IndexFactory, IndexToken, IndexRule, IndexZap and fails on git diff
- Optional doc check that every error selector in the ABIs appears in the README list (or README defers to ABIs)

### XA-45 [INFO] Cross-constant relationships are enforced only by comments (TWAP window copy, cardinality vs window, target cap vs multiplier, keepMask width vs MAX_COMPONENTS)

- **Dimension:** Hazard (multiple-sources-of-truth)
- **Location:** `src/IndexRule.sol:29-47 (also src/IndexToken.sol:55,244; src/IndexFactory.sol:37)`
- **Reported by:** hazard-truth (reported INFO)
- **Merged into this finding (same root cause):** R1-hazard-enforce-5
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

(1) Hazard: some constants must stay in a fixed relationship, but each is a separate literal. The tests pin each literal on its own (IndexRule.t.sol:108-112 `assertEq(rule.TWAP_WINDOW(), 30 minutes)`, `MIN_OBSERVATION_CARDINALITY() == 200`, `MAX_TARGET_UNITS() == uint96.max*2/3`; IndexFactory.t.sol:97 `MAX_COMPONENTS() == 20`), and no test checks the relationships.
(2) Shape: (a) `int56 private constant SIGNED_TWAP_WINDOW = 30 minutes;` (IndexRule.sol:44) repeats `TWAP_WINDOW = 30 minutes` (line 29). `_poolPrice` observes over TWAP_WINDOW but divides by SIGNED_TWAP_WINDOW (lines 192, 199). (b) The comment at line 30 says "200 slots always cover 40 minutes", which assumes MIN_OBSERVATION_CARDINALITY * 12 s >= TWAP_WINDOW. (c) The comment at line 33 says `MAX_TARGET_UNITS = uint96.max * 2 / 3` because IndexToken's `AUCTION_START_MULTIPLIER = 1.5e18` (IndexToken.sol:55), which is in a different contract. (d) `SafeCast.toUint24(keepMask)` (IndexToken.sol:244) quietly requires `IndexFactory.MAX_COMPONENTS (20) <= 24`. (e) `CAPPED_REMAINDER = 0.7e18` must equal `WAD - CAPPED_TOP_WEIGHT`.
(3) Scenario for a future version: TWAP_WINDOW goes to 1 hour to harden against manipulation. For (b), 200 slots only cover 40 minutes of busy blocks, so `observe` reverts `OLD` on the busiest pools (WETH/USDC). `startRebalance` and `navPerToken` then revert exactly when markets are active, and the mock pools in the tests would not show it. If (a) is also missed, the mean tick doubles and every price is squared. For (c), raising the opening multiplier to 2.0 overflows `SafeCast.toUint96` in `_applyRebalance` for large-unit components, so those auctions can never fill. For (d), raising MAX_COMPONENTS to 25 makes a guardian keep mask on component 24 revert.
(4) Structural fix: derive the constants from each other where possible, and add one relationship test.

**Merged: R1-hazard-enforce-5 — PendingRebalance.keepMask is uint24 while the component cap lives in the factory, and nothing pins MAX_COMPONENTS <= 24**

Hazard: the width of a stored keep mask depends on a constant defined in another contract.
- IndexToken.sol:71 declares `uint24 keepMask;`.
- Line 230 bounds the mask only by the clone's own component count: `if (keepMask >> n != 0 || ...)`.
- Line 244 narrows it: `SafeCast.toUint24(keepMask)`.
- The cap `MAX_COMPONENTS = 20` is in IndexFactory.sol:37, and the only test is `assertEq(fresh.MAX_COMPONENTS(), 20)` (test/IndexFactory.t.sol:97). No test or type ties it to 24.

Production scenario: a later version raises MAX_COMPONENTS to 32. That lives in the factory, so the token file shows no change. An index then holds WBTC at position 25, and WBTC's custodian pauses it. The guardian's documented remedy (ARCHITECTURE.md section 5: 'A permanently frozen component needs the guardian's keep mask at every rebalance') calls `startRebalance(1 << 25)`, which reverts in SafeCast. With a zero mask, `executeRebalance` reverts on the paused transfer. That index can never rebalance while the component stays paused. The eta is uint40 and the mask uint24, 64 bits together, so the slot has 192 unused bits and a wider mask costs no gas.

*Proposed fix:*

src/IndexToken.sol:69-72 and 244: widen the mask within the same slot.
```diff
     struct PendingRebalance {
         uint40 eta;
-        uint24 keepMask;
+        uint216 keepMask;
     }
@@
-        _pending = PendingRebalance({eta: SafeCast.toUint40(eta), keepMask: SafeCast.toUint24(keepMask)});
+        _pending = PendingRebalance({eta: SafeCast.toUint40(eta), keepMask: SafeCast.toUint216(keepMask)});
```
Alternatively, keep uint24 and add to test/IndexFactory.t.sol: `assertLe(factory.MAX_COMPONENTS(), 24, "IndexToken stores keepMask in uint24");`

**Proposed fix (reviewer)**

src/IndexRule.sol:44:
-    int56 private constant SIGNED_TWAP_WINDOW = 30 minutes;
+    int56 private constant SIGNED_TWAP_WINDOW = int56(uint56(TWAP_WINDOW));
src/IndexRule.sol:47:
-    uint256 private constant CAPPED_REMAINDER = 0.7e18;
+    uint256 private constant CAPPED_REMAINDER = WAD - CAPPED_TOP_WEIGHT;
Add test/Constants.t.sol:
  function test_constantRelations() public {
    assertGe(uint256(rule.MIN_OBSERVATION_CARDINALITY()) * 12, rule.TWAP_WINDOW(), "cardinality covers the TWAP window at one observation per block");
    assertLe(rule.MAX_TARGET_UNITS() * token.AUCTION_START_MULTIPLIER() / 1e18, type(uint96).max, "auction premium fits uint96");
    assertLe(factory.MAX_COMPONENTS(), 24, "keepMask is stored as uint24");
  }

### XA-46 [INFO] AGENTS.md duplicates CLAUDE.md and Wake remappings duplicate foundry.toml, with no sync check

- **Dimension:** Hazard (configuration-spread)
- **Location:** `AGENTS.md:1-148 (also .vscode/settings.json:2-17, foundry.toml:9-13)`
- **Reported by:** hazard-truth (reported INFO)
- **Merged into this finding (same root cause):** R1-process-6
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

(1) Hazard: agent guidance and analyzer configuration can drift silently.
(2) Shape: AGENTS.md and CLAUDE.md are 148-line copies that differ only in lines 1 and 3 (`diff` shows only the title and the "Codex"/"Claude Code" line). They carry the design rules, the definition of done and the recorded product decisions. The Wake remappings in .vscode/settings.json:2-17 re-list foundry.toml:9-13 plus 11 nested OpenZeppelin remappings (the `forge remappings` output). Nothing checks that either pair still agrees. CLAUDE.md's definition of done item 5 depends on Wake being clean on src/.
(3) Scenario: a new design rule is added to CLAUDE.md, for example after a finding, but not to AGENTS.md. A Codex session then follows the old rule and changes something the team had forbidden, and review misses it because the old rule still reads as authoritative. Or a remapping is added to foundry.toml when a dependency is added; Wake in VS Code can no longer resolve the import, and the "no detections" gate is met only because Wake analyzed nothing.
(4) Structural fix: keep one canonical file and a CI diff check for each pair.

**Merged: R1-process-6 — Layout omits script/interfaces and CLAUDE.md/AGENTS.md are unsynchronised copies**

CLAUDE.md:62 and AGENTS.md:62 list `script/  Deploy, ConfigureWhitelist`. They leave out script/interfaces/, which holds INonfungiblePositionManager, ISafeThreshold, IUniswapV3FactorySetup, IUniswapV3PoolSetup and IWETH9, used by the scripts and the Sepolia market setup. The v1 audit fingerprint also covered `script/interfaces/*.sol`. A session relying on the layout can miss these files when changing interfaces or recomputing that fingerprint. The two process docs are byte-identical apart from lines 1 and 3, and nothing checks that they stay in sync. PROC-1 to PROC-5 all need the same edit in both files, and an edit to one alone leaves Codex and Claude sessions following different rules.

*Proposed fix:*

CLAUDE.md/AGENTS.md line 62:
-script/                       Deploy, ConfigureWhitelist
+script/                       Deploy, ConfigureWhitelist
+script/interfaces/            minimal Safe, WETH9 and Uniswap V3 setup interfaces used by the scripts
Add a CI step: `diff <(tail -n +4 CLAUDE.md) <(tail -n +4 AGENTS.md)` to fail on drift (or make AGENTS.md a pointer to CLAUDE.md).

**Proposed fix (reviewer)**

Replace AGENTS.md with a symlink to CLAUDE.md, or make its body one line: "Follow CLAUDE.md; it is the canonical guidance for every agent." If both must stay full files, add a CI step to .github/workflows/test.yml:
      - name: Agent guidance in sync
        run: diff <(tail -n +4 CLAUDE.md) <(tail -n +4 AGENTS.md)
For Wake, add:
      - name: Wake remappings match forge
        run: diff <(forge remappings | sort) <(jq -r '."wake.compiler.solc.remappings"[]' .vscode/settings.json | sort)
(adjust the forge output format as needed), or move the remappings into a remappings.txt that both foundry.toml and wake.toml read.

### XA-47 [INFO] Deploy accepts non-default market addresses on chain 1 without a warning, never checks the router against WETH and the Uniswap factory, and does not log the rule's immutable inputs; swapped WETH/USDC deploys cleanly

- **Dimension:** Hazard (silent-wrong-config)
- **Location:** `script/Deploy.s.sol:61-78, 104-119`
- **Reported by:** r2-periphery (reported LOW)
- **Verification:** combined: confirmed -> INFO

**Problem**

On chain 1, `_resolve` swaps in the mainnet default only when a value is zero. Any non-zero override is used as long as it has code: `if (given == address(0)) { if (block.chainid != 1) revert AddressRequired(name); given = mainnetDefault; } if (given.code.length == 0) revert AddressHasNoCode(name, given); return given;` (Deploy.s.sol:112-118). Forge loads `.env` from the project root on its own, and .env.example:16-20 lists SWAP_ROUTER/WETH/UNISWAP_V3_FACTORY/USDC. So a value left in `.env` or in the shell reaches the mainnet broadcast silently.

The only on-chain check of these inputs is in the IndexRule constructor: `getPool(usdc, weth, USD_POOL_FEE)` followed by `_checkPool(usdc, usdPool)` (src/IndexRule.sol:63-64). `_checkPool` calls `getPool(token, WETH, fee) == pool` (IndexRule.sol:172), and getPool does not care about token order. If WETH and USDC are swapped, it finds the same USDC/WETH 0.05% pool, which has enough cardinality and a non-zero price, so the factory deploys.

I checked this in a private copy (test/poc/DeploySwap.t.sol). With `vm.chainId(1)`, a MockSafe with threshold 2, and `Market{weth: market.usdc(), usdc: market.weth()}`, `deployer.deploy` succeeds, and `rule.WETH() == usdc` and `rule.USD_POOL() == usdPool`. The same thing happens when WETH is replaced by any token that has a well-observed 0.05% pool against USDC, such as WBTC/USDC 0.05% on mainnet. Every price, market cap and target in the rule is then quoted in that token, and ConfigureWhitelist looks up the pools with `getPool(entry.token, weth, fee)` against it.

`resolveMarket` also never compares `market.router` with the market: SwapRouter02 exposes `WETH9()` and `factory()`, and neither is read.

After the broadcast, the log prints the router and USD pool but not WETH, UNISWAP_V3_FACTORY or USDC (Deploy.s.sol:70-77). The pool address alone does not show that its two tokens were swapped.

Impact: the rule is created inside the factory constructor and stored as an immutable. It cannot be replaced, so a mistake means redeploying and abandoning any indexes and listings already created. The zap can be replaced, but a mismatched router only shows up at the first mint.

**Proposed fix (reviewer)**

script/Deploy.s.sol: reject overrides on mainnet unless they match the defaults, cross-check the router, and log the inputs.

```diff
+interface IPeripheryImmutableState {
+    function factory() external view returns (address);
+    function WETH9() external view returns (address);
+}
@@
+    error MainnetOverride(string name, address given, address expected);
+    error RouterMarketMismatch(address router);
@@ function resolveMarket(Market memory market) public view returns (Market memory) {
         market.usdc = _resolve("USDC", market.usdc, MAINNET_USDC);
+        if (
+            IPeripheryImmutableState(market.router).WETH9() != market.weth
+                || IPeripheryImmutableState(market.router).factory() != market.uniswapV3Factory
+        ) revert RouterMarketMismatch(market.router);
         return market;
     }
@@ function _resolve(string memory name, address given, address mainnetDefault) private view returns (address) {
         if (given == address(0)) {
             if (block.chainid != 1) revert AddressRequired(name);
             given = mainnetDefault;
+        } else if (block.chainid == 1 && given != mainnetDefault) {
+            revert MainnetOverride(name, given, mainnetDefault);
         }
@@ function deploy(...)
         console2.log("Swap router:             ", market.router);
+        console2.log("WETH:                    ", IIndexRule(factory.RULE()).WETH());
+        console2.log("USDC:                    ", IIndexRule(factory.RULE()).USDC());
+        console2.log("Uniswap V3 factory:      ", IIndexRule(factory.RULE()).UNISWAP_V3_FACTORY());
```
Add `WETH9()`/`factory()` to MockSwapRouter, returning the market's addresses. In test/Scripts.t.sol, add a test that sets `vm.chainId(1)`, etches the mainnet defaults, passes `usdc = MAINNET_WETH, weth = MAINNET_USDC`, and expects `MainnetOverride("WETH", MAINNET_USDC, MAINNET_WETH)`. Add a second test that expects `RouterMarketMismatch` for a router whose WETH9 differs.

**Verifier (combined): confirmed -> INFO**

Every source claim checks out. script/Deploy.s.sol:112-118 `_resolve` uses the mainnet default only when the value is zero. Any non-zero override is accepted on chain 1 as long as it has code. `resolveMarket` (104-110) never reads the router's `WETH9()` or `factory()`. The log (70-77) prints the router and USD_POOL but not WETH, USDC or UNISWAP_V3_FACTORY. The IndexRule constructor (src/IndexRule.sol:63-64) calls `getPool(usdc, weth, 500)` and then `_checkPool`, which calls `getPool(token, WETH, fee) == pool` (line 172). The real Uniswap V3 factory fills getPool for both token orders, so swapping WETH and USDC resolves to the same 0.05% pool and passes the cardinality and non-zero price checks. The rule is immutable in the factory.

I am lowering the severity to INFO for three reasons:
- **Nobody else can cause it.** The deployer would have to set WETH and USDC deliberately, and swap them, in their own env or .env. The defaults are correct and the documented flow sets neither variable on mainnet. .env.example keeps them commented out and says "Required off mainnet only".
- **Nothing is at stake when it happens.** A fresh factory holds no funds. A token needs `LISTING_DELAY` before listing, and ConfigureWhitelist would look up pools against the wrong WETH. A wrong rule shows up before any user money is exposed, and the fix is to redeploy. No funds are lost.
- **It is not an attack.** Nobody can exploit it. It is a missing sanity check in an operator script.

It is still a fair hardening point, because README:266-268 only promises that the constructor checks the USDC/WETH pool can serve a price, and that check does not catch swapped addresses.

*PoC:* Not re-run. The claims are static and fully decided by the source lines above, plus Uniswap V3's documented getPool filling both token orders. The reporter's PoC (test/poc/DeploySwap.t.sol with swapped weth/usdc on chainId 1) matches that trace.

*Fix assessment:* The proposed fix is broadly correct and complies with CLAUDE.md, since it only touches the script. Two caveats:
1. `MainnetOverride` makes the env overrides useless on chain 1. That is acceptable, but a local anvil mainnet fork with other contracts would also be blocked, so the docs (Deploy.s.sol header, README:266, .env.example) should say that overrides are rejected on chain 1.
2. The router cross-check calls `WETH9()` and `factory()` on every chain. Sepolia's SwapRouter02 has both, so this is fine, but MockSwapRouter has to implement them, and every existing test in Scripts.t.sol that builds a Market has to pass consistent addresses. Otherwise the 100% coverage and green-test requirements break.

A lighter alternative that keeps overrides working on chain 1 is to require `IUniswapV3Pool(USD_POOL).token0/token1` ordering to match `usdc < weth`. Either way, log WETH, USDC and UNISWAP_V3_FACTORY.

*Tests a fix must add:*

- On chainId 1, a non-default WETH or USDC override (including swapped WETH and USDC) reverts with MainnetOverride and the exact args
- A router whose WETH9() differs from market.weth reverts with RouterMarketMismatch
- A router whose factory() differs from market.uniswapV3Factory reverts with RouterMarketMismatch
- On chainId 1, passing overrides equal to the defaults still resolves successfully
- A deploy on a non-mainnet chain with a consistent mock router still succeeds

### XA-48 [INFO] The 'USDT: plain approve' integration note leaves out USDT's non-zero-to-non-zero approve revert, and the fork tests hide it with forceApprove

- **Dimension:** Hazard (integration-docs)
- **Location:** `README.md:156-157`
- **Reported by:** r2-periphery (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

README.md:156-157 says: "Approvals. USDC supports `permit`; USDT does not (plain `approve`). ... Approve exact amounts." Mainnet USDT's `approve` reverts when both the current allowance and the new value are non-zero. The repo's own mock models this: `require(!(value != 0 && allowance[msg.sender][spender] != 0), "USDT: approve from non-zero")` (test/mocks/MockUSDT.sol:25).

`mintWithToken` pulls the full `maxAmountIn` only when it succeeds (IndexZap.sol:133). A mint that reverts (StaleRebalanceNonce, Expired, `Too much requested`) or is never mined therefore leaves the exact approval in place. The app's next plain `approve(zap, newMax)` for USDT then reverts, so the user pays gas for a failed approval and cannot mint until the allowance is reset to 0.

The fork tests never show this. They use `IERC20(stable).forceApprove(address(zap), maxIn)` with the comment `// USDT returns no bool` (test/fork/IndexZap.fork.t.sol:219). forceApprove resets to 0 internally, which is exactly the step the README leaves out. No funds are lost; the failure is repeated reverts in the USDT mint flow.

**Proposed fix (reviewer)**

README.md:156-157:
```diff
-- **Approvals.** USDC supports `permit`; USDT does not (plain `approve`). Index tokens support `permit`. Approve exact
-  amounts.
+- **Approvals.** USDC supports `permit`; USDT does not (plain `approve`), and USDT's `approve` reverts when changing a
+  non-zero allowance to another non-zero value: if `allowance(user, zap)` is not 0 (for example after a reverted mint),
+  send `approve(zap, 0)` first. Index tokens support `permit`. Approve exact amounts.
```

### XA-49 [INFO] IndexZap: immutables, events, errors, most struct fields and function params/returns are undocumented

- **Dimension:** Documentation (natspec-missing)
- **Location:** `src/IndexZap.sol:56-213`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

MintParams (:56-67) documents only expectedNonce and legs. index, tokenIn, maxAmountIn (the full amount is pulled up front, :133), shares, to and deadline are undocumented, and so are BurnParams' index, shares, tokenOut, minAmountOut (must be non-zero, :304), to and deadline (:69-80). No NatSpec on FACTORY (:82), ROUTER (:83), events ZapMint (:85), ComponentReturned (:93) or ZapBurn (:94), or errors NotIndex, StaleRebalanceNonce, Expired, ZeroAddress, ZeroAmount, InvalidRecipient, LegCountMismatch, BadPath, InsufficientBudget, InsufficientOutput, TransferShortfall (:103-113). mintWithToken (:125-127) does not say the shares go to `p.to` and has no @return for amountSpent. burnToToken (:203-205) does not say that unsold component remainders also go to `p.to` (:289-295). Its @return amountOut is undocumented, and burnToTokenWithPermit has no @param v/r/s.

**Proposed fix (reviewer)**

e.g.

-    /// @notice Buys exactly `p.shares` of `p.index` spending at most `p.maxAmountIn` of `p.tokenIn`.
-    ///         Unspent `tokenIn` is refunded to msg.sender.
+    /// @notice Buys exactly `p.shares` of `p.index` for `p.to`, spending at most `p.maxAmountIn` of `p.tokenIn`.
+    ///         The whole `p.maxAmountIn` is pulled first; unspent `tokenIn` is refunded to msg.sender.
+    /// @return amountSpent `tokenIn` used, including any held directly by the basket.
@@
-    ///         and delivers at least `p.minAmountOut` of `p.tokenOut` to `p.to`.
+    ///         and delivers at least `p.minAmountOut` of `p.tokenOut` to `p.to`. Any part of a component a pool did not
+    ///         take also goes to `p.to` (ComponentReturned).
+    /// @return amountOut `tokenOut` delivered.

plus @param tags for every struct field and @notice lines on the immutables, events and errors.

### XA-50 [INFO] Script public entry points, constants and errors are undocumented (Deploy, ConfigureWhitelist, SetupTestMarket, FaucetToken)

- **Dimension:** Documentation (natspec-missing)
- **Location:** `script/Deploy.s.sol:27-57`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

script/Deploy.s.sol: run() (:47) and deploy(owner, guardian, market) (:57) have no NatSpec. deploy is the public function tests and operators call; it validates owner/guardian, resolves the market and broadcasts both contracts, and none of that is documented. Also undocumented: MAINNET_SWAP_ROUTER_02/WETH/UNISWAP_V3_FACTORY/USDC (:27-30), Market's fields, errors OwnerRequired, OwnerMustBeContract, OwnerThresholdTooLow, GuardianRequired, AddressRequired, AddressHasNoCode (:40-45), and the @param tags of checkOwner/checkGuardian/resolveMarket. script/ConfigureWhitelist.s.sol: run() (:81), POOL_FEE_LOW/POOL_FEE_MEDIUM (:41-42) and errors UnknownMode, DefaultListOnlyOnMainnet, MalformedEntry (:44-46) have no NatSpec; propose/execute/safeCalldata/configFor/parseEntry/resolveList have no @param/@return. execute's notice ("Executes every proposal that is due") also does not warn that it executes whatever config is pending for a listed entry's token, which may differ from the entry. script/testnet/SetupTestMarket.s.sol: run() (:154), sepoliaUniswap() (:147), POOL_FEE_LOW/MEDIUM, TICK_SPACING_LOW/MEDIUM, STANDARD_DECIMALS, SEPOLIA_CHAIN_ID, DEFAULT_USD_POOL_WETH, DEFAULT_TOKEN_POOL_WETH (:62-82) and all errors (:84-89) are undocumented. script/testnet/FaucetToken.sol: COOLDOWN (:11) and DripTooSoon (:20) are undocumented.

**Proposed fix (reviewer)**

e.g. in script/Deploy.s.sol:

+    /// @notice Reads OWNER, GUARDIAN and the optional market addresses from the environment and calls {deploy}.
     function run() external returns (IndexFactory factory, IndexZap zap) {
+    /// @notice Checks `owner` and `guardian`, resolves `market`, and broadcasts the factory (with its rule and token
+    ///         implementation) and the zap.
+    /// @param owner Factory owner, see {checkOwner}.
+    /// @param guardian Initial guardian, see {checkGuardian}.
+    /// @param market External addresses; zero fields take mainnet defaults on chain 1.
+    /// @return factory The deployed factory.
+    /// @return zap The deployed zap.
     function deploy(...)

and in script/ConfigureWhitelist.s.sol:179:

-    /// @notice Any account. Executes every proposal that is due and skips everything else.
+    /// @notice Any account. Executes every due proposal for the listed tokens, whatever config it carries, and skips
+    ///         everything else. Check `pendingTokenConfig` first.

plus one-line @notice tags for the constants and errors listed.

### XA-51 [INFO] Minimal Uniswap interfaces and PathLib helpers leave struct fields, pool getters and helpers undocumented

- **Dimension:** Documentation (natspec-missing)
- **Location:** `src/interfaces/ISwapRouter02.sol:9-24`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

src/interfaces/ISwapRouter02.sol: struct fields of ExactInputParams (:9-14) and ExactOutputParams (:16-21) have no @param, and exactInput/exactOutput have no @param/@return. src/interfaces/IUniswapV3Pool.sol: fee() (:7) and slot0() (:9-20) have no NatSpec; slot0's observationCardinality is what IndexRule checks against MIN_OBSERVATION_CARDINALITY. observe (:24) has no @param/@return. src/libraries/PathLib.sol: constants ADDR_SIZE, FEE_SIZE, HOP_SIZE (:7-9) and internal functions firstToken (:16) and lastToken (:20) are undocumented. lastToken and firstToken assume a length the caller has already checked with isValidShape; otherwise they panic on out-of-range slices.

**Proposed fix (reviewer)**

e.g. in src/interfaces/IUniswapV3Pool.sol:

+    /// @notice The pool's fee tier in hundredths of a bip.
     function fee() external view returns (uint24);
+    /// @notice Current price, tick and oracle state; `observationCardinality` is the number of populated oracle slots.
     function slot0() ...

and in src/libraries/PathLib.sol:

+    /// @notice First token of `path`. Call only after {isValidShape}.
     function firstToken(bytes calldata path) internal pure returns (address) {
+    /// @notice Last token of `path`. Call only after {isValidShape}.
     function lastToken(bytes calldata path) internal pure returns (address) {

### XA-52 [INFO] MAX_TARGET_UNITS NatSpec says the rule never returns larger targets, but it does for kept or already-large units

- **Dimension:** Documentation (natspec-inaccurate)
- **Location:** `src/interfaces/IIndexRule.sol:36-37`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

src/interfaces/IIndexRule.sol:36: "Largest target units the rule returns, so an auction's premium still fits the index's uint96 units." IndexRule._bound sets `hi = Math.max(u, Math.min(2 * u, MAX_TARGET_UNITS))` (src/IndexRule.sol:361), and kept components return `units[i]` unchanged (:322-323). createIndex accepts units up to type(uint96).max (src/IndexFactory.sol:140). A component created with units = 2^96-1 therefore gets a target of 2^96-1, above MAX_TARGET_UNITS = 2/3 of that. Nothing overflows, because such a target is never above current units and the multiplier applies only to growth. The sentence is still false as written.

**Proposed fix (reviewer)**

--- a/src/interfaces/IIndexRule.sol
+++ b/src/interfaces/IIndexRule.sol
@@
-    /// @notice Largest target units the rule returns, so an auction's premium still fits the index's uint96 units.
+    /// @notice Largest target units the rule moves a component up to, so an auction's premium still fits the index's
+    ///         uint96 units. A component whose current units already exceed it keeps them as its upper bound.

### XA-53 [INFO] IIndexFactory: all events, errors and several getters are undocumented, and createIndex/predictIndexAddress lack @param/@return

- **Dimension:** Documentation (natspec-missing)
- **Location:** `src/interfaces/IIndexFactory.sol:20-126`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

No NatSpec on events IndexCreated (:20), ListingProposed (:29), ListingCancelled (:32), TokenConfigured (:33), TokenWhitelisted (:34), GuardianProposed (:35), GuardianChangeCancelled (:36), GuardianSet (:37). No NatSpec on errors EmptyString (:39), InvalidComponentCount (:40), LengthMismatch (:41), TokenNotWhitelisted (:42), DuplicateToken (:43), InvalidUnits (:44), InvalidMethodology (:45), TooFewComponentsForCapped (:46), IndexAlreadyExists (:47), NotAContract (:48), ListingPending (:49), NoPendingListing (:50), ListingNotReady (:51), ListingExpired (:52), NotWhitelisted (:53), NoPendingGuardianChange (:54), GuardianChangeNotReady (:55), GuardianChangeExpired (:56), Unauthorized (:57), RenounceDisabled (:58). No NatSpec on getters MAX_COMPONENTS (:60), IMPLEMENTATION (:74), isWhitelisted (:92), whitelistedTokens (:93; its order changes on delist through swap-and-pop, src/IndexFactory.sol:235-240, which should be stated), isIndex (:105), creatorOf (:106), allIndexes (:107), allIndexesLength (:108). IndexFactory.sol:292 and :306 add no text, so these have no documentation anywhere. createIndex (:126) has no @param for name/symbol and no @return index, and does not mention that units must fit uint96 (InvalidUnits, IndexFactory.sol:140). predictIndexAddress (:111) and the propose/cancel/execute functions have no @param. The ABI docs integrators generate therefore say nothing about these reverts and events.

**Proposed fix (reviewer)**

Add a one-line @notice to each event and error, and @param tags for non-obvious fields, e.g.

+    /// @notice A new index was deployed and initialized. `units` are raw units per 1e18 shares.
     event IndexCreated(...);
+    /// @notice `units[i]` is zero or does not fit uint96.
     error InvalidUnits(address token, uint256 units);
+    /// @notice Largest number of components an index can have.
     function MAX_COMPONENTS() external view returns (uint256);
+    /// @notice Listed tokens. The order is not stable: delisting moves the last entry into the freed slot.
     function whitelistedTokens() external view returns (address[] memory);

and in createIndex add `@param name ERC-20 name, non-empty`, `@param symbol ERC-20 symbol, non-empty`, `@return index The new index clone`, plus `each at most type(uint96).max` in @param units.

### XA-54 [INFO] IIndexToken/IndexToken: events, errors, componentCount and nonces are undocumented; most functions lack @param/@return

- **Dimension:** Documentation (natspec-missing)
- **Location:** `src/interfaces/IIndexToken.sol:18-170`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

No NatSpec on events Issued (:18), Redeemed (:19), ClaimRecorded (:20), Claimed (:21), Rebalanced (:29). RebalanceStarted (:24) documents only `id`, not targetUnits/keepMask/eta. RebalanceCancelled (:28) does not document `id`, which is rebalanceNonce+1 of the cancelled proposal (IndexToken.sol:260). No NatSpec on errors NotFactory, NotInitialized, InvalidComponents, ZeroShares, ZeroAddress, InvalidRecipient, InvalidSkipMask, NothingToClaim, TransferAmountMismatch, Unauthorized, RebalanceTooSoon, RebalancePending, InvalidKeepMask, TurnoverTooLow, NoPendingRebalance, RebalanceNotReady, RebalanceExpired, RebalanceUnderfunded (:38-55). componentCount (IIndexToken.sol:115, IndexToken.sol:370) has no documentation in either file. IndexToken.nonces (src/IndexToken.sol:453) overrides two bases with no NatSpec or @inheritdoc. With two bases, solc does not inherit the docs automatically, so it has none. Missing @param: initialize name_/symbol_/tokens/units/methodology_ (:85-91; it does not say that methodology_ is not validated there or that units must fit uint96), issue/redeem shares/to (:95,:99), redeemSkipping shares/to (:104), claim token/to and @return amount (:107), executeRebalance data (:154), startRebalance/previewTarget returns (:157), and previewRebalance's four return values (:166-169).

**Proposed fix (reviewer)**

Add @notice to each event and error, e.g.

+    /// @notice `shares` were minted to `to` against `amounts` pulled from `sender`, in component order.
     event Issued(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
+    /// @param id The nonce the cancelled rebalance would have taken.
     event RebalanceCancelled(...);
+    /// @notice The executor left `token` below `required` = supply * units / 1e18 + totalClaims.
     error RebalanceUnderfunded(address token, uint256 balance, uint256 required);
+    /// @notice Number of constituents; fixed at initialization.
     function componentCount() external view returns (uint256);

In src/IndexToken.sol:453 add `/// @inheritdoc IERC20Permit` above nonces, and add @param/@return tags to the functions listed.

### XA-55 [INFO] IIndexRule: errors, WETH/UNISWAP_V3_FACTORY/USDC getters and return values are undocumented; price() leaves out WETH and unconfigured-token behaviour

- **Dimension:** Documentation (natspec-missing)
- **Location:** `src/interfaces/IIndexRule.sol:15-93`
- **Reported by:** docs-natspec (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

No NatSpec on errors ZeroAddress, InvalidPool, PoolHistoryTooShort, InvalidSupplyConfig, ZeroPrice, ZeroSupply, InvalidMethodology, TooFewComponentsForCapped, DegenerateBasket, LengthMismatch, NotIndex (:15-25), or on getters WETH (:45), UNISWAP_V3_FACTORY (:46), USDC (:47). price (:58) says "WETH wei per 1e18 raw units of `token` from its configured pool". It does not say that WETH returns 1e18 with no pool (IndexRule.sol:183), or that an unlisted token (pool == address(0)) reverts with empty data from `observe` on a codeless address rather than a named error. Missing @param/@return: checkConfig token/config, price/supply token and return, weightsFromCaps caps/methodology and return, weights `w`/`prices`/`supplies` (units not stated), targetUnits tokens/units/methodology/keepMask (the bits' meaning is described only in prose), navPerToken index and returns, initialUnits params (startPriceUsdc in raw 6-decimal USDC) and return.

**Proposed fix (reviewer)**

Add @notice to each error and getter (e.g. `/// @notice Wrapped ether; every WAD price is quoted in it.` on WETH()). Extend price():

-    /// @notice WETH wei per 1e18 raw units of `token` from its configured pool. USDC is priced from USD_POOL.
+    /// @notice WETH wei per 1e18 raw units of `token` from its configured pool. WETH is 1e18, USDC is priced from
+    ///         USD_POOL, and a token with no config reverts.
+    /// @param token Token to price.
+    /// @return WAD price.

and add @param/@return tags to the functions listed.

### XA-56 [INFO] navPerToken described as what a burn returns before swap costs

- **Dimension:** Documentation (doc-accuracy)
- **Location:** `ARCHITECTURE.md:193-194`
- **Reported by:** docs-prose (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

ARCHITECTURE.md:193-194 says of `navPerToken`: "It is what a burn returns before swap costs." The function values units at 30-minute TWAP prices: `_price` -> `_poolPrice` with `observe([TWAP_WINDOW, 0])` (IndexRule.sol:136-146, 190-201). A burn sells at spot, through the dollar pool, after floor rounding. README.md:135 and ARCHITECTURE.md:273 correctly say the value lags fast moves. Read on its own, this sentence invites the app to present the figure as the expected burn output, which after a fast move can differ by the whole move over the last 30 minutes.

**Proposed fix (reviewer)**

ARCHITECTURE.md:193-194: replace "It is what a burn returns before swap costs." with "It approximates what a burn returns before swap costs, at 30-minute average rather than spot prices."

### XA-57 [INFO] ARCHITECTURE defers zap behaviour to v1 documentation that is not in the repo

- **Dimension:** Documentation (stale-reference)
- **Location:** `ARCHITECTURE.md:151-153, 244-245, 283`
- **Reported by:** docs-prose (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

Three passages rely on v1 documentation that this repo does not contain:
- ARCHITECTURE.md:151: `mintWithToken`/`burnToToken` "work as in v1"
- ARCHITECTURE.md:244-245: "Unchanged from v1"
- ARCHITECTURE.md:283, security model: "**Zap:** as in v1, plus `expectedNonce`."

The zap's security properties never appear in this document itself: the path endpoint checks, the non-zero overall burn minimum, the permit try/catch, and returning unsold components. They exist only in IndexZap.sol:16-35 and the README integration notes.

**Proposed fix (reviewer)**

ARCHITECTURE.md:283: replace "**Zap:** as in v1, plus `expectedNonce`." with a self-contained bullet:
```
- **Zap:** stateless and ownerless; `isIndex` checked; every path's first and last token validated; per-leg and overall
  limits (overall burn minimum non-zero); payments and payouts measured as balance changes inside the call; the unsold
  part of a partial fill sent to the recipient with `ComponentReturned`; `expectedNonce` must equal `rebalanceNonce`;
  never calls `redeemSkipping` or `executeRebalance`.
```

### XA-58 [INFO] Deploy instructions use --verify, but .env.example has no ETHERSCAN_API_KEY

- **Dimension:** Documentation (deployment-docs)
- **Location:** `.env.example:1-25`
- **Reported by:** docs-prose (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

README.md:260 says `cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN`, and line 262 then runs `forge script script/Deploy.s.sol ... --broadcast --verify`. `.env.example` has no `ETHERSCAN_API_KEY`, and foundry.toml has no `[etherscan]` section. The contracts still deploy, but verification fails after the broadcast, and the operator has to verify the factory and zap by hand. Only the testnet section (README.md:344) mentions the key.

**Proposed fix (reviewer)**

.env.example, after line 6 add:
```
# Etherscan API key for --verify (mainnet and Sepolia deployments).
ETHERSCAN_API_KEY=
```
README.md:260: change the comment to `# fill MAINNET_RPC_URL, ETHERSCAN_API_KEY, OWNER (a Safe on mainnet) and GUARDIAN`.

### XA-59 [INFO] Rebalance events reuse the same id across restarts and nothing is emitted when a proposal expires, so event-driven indexers cannot tell attempts apart

- **Dimension:** Documentation (event-correctness)
- **Location:** `src/IndexToken.sol:226-227, 247, 260, 317-320`
- **Reported by:** r2-critic (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

Both `startRebalance` and `cancelRebalance` take the event id from `rebalanceNonce + 1` without changing the nonce. Start: `emit RebalanceStarted(rebalanceNonce + 1, msg.sender, targets, keepMask, eta);` (IndexToken.sol:247). Cancel: `emit RebalanceCancelled(rebalanceNonce + 1, msg.sender, restartAt);` (:260). The nonce only moves in `_applyRebalance` (:291). When an auction expires, no event is emitted. `startRebalance` simply overwrites the proposal once `block.timestamp > pendingEta + AUCTION_DURATION` (:226). The interface documents the id only as "The value rebalanceNonce takes if this rebalance executes" (IIndexToken.sol:23). README.md:168-171 lists these events for the separate web app and gives no warning that ids repeat.

Scenario, with nonce = 0 throughout:
1. Day 28: anyone starts a rebalance, emitting `RebalanceStarted(id=1, targets A)`.
2. The guardian cancels it, emitting `RebalanceCancelled(id=1)`.
3. Day 30: the guardian starts again with a keep mask, emitting `RebalanceStarted(id=1, targets B, mask)`.
4. Nobody fills that auction. On day 33 a stranger starts a third proposal, emitting `RebalanceStarted(id=1, targets C)`. No event marks the end of proposal B.

An indexer keyed on `id` sees two outcomes. Either it marks id 1 cancelled after step 2 and keeps that label while C is live, or it overwrites A with B and B with C and loses the history. Nothing on-chain says B expired unfilled. In the same way, `pendingRebalance()` keeps returning eta != 0 and B's targets after B expires (only `_applyRebalance`/`cancelRebalance` delete `_pending`). A UI built from events or from that view shows a dead proposal as pending. This is the same root cause as the known README 'rebalance due' finding, but on the event side. No funds are at risk. Holders and the app can misread which targets are live during the 2-day notice, which is the window meant for them to decide whether to exit.

**Proposed fix (reviewer)**

Give each proposal its own id and say so in the interface. Minimal change in src/IndexToken.sol:

```diff
+    /// @notice Number of rebalance proposals ever started; each RebalanceStarted/RebalanceCancelled carries it as `proposalId`.
+    uint256 public proposalCount;
@@ function startRebalance
-        emit RebalanceStarted(rebalanceNonce + 1, msg.sender, targets, keepMask, eta);
+        emit RebalanceStarted(++proposalCount, rebalanceNonce + 1, msg.sender, targets, keepMask, eta);
@@ function cancelRebalance
-        emit RebalanceCancelled(rebalanceNonce + 1, msg.sender, restartAt);
+        emit RebalanceCancelled(proposalCount, msg.sender, restartAt);
```
Make the matching event signature change in src/interfaces/IIndexToken.sol:24-28. At minimum, if the ABI must stay as it is, extend the NatSpec at IIndexToken.sol:23 and README.md:168-171:
```diff
-    /// @param id The value {rebalanceNonce} takes if this rebalance executes.
+    /// @param id The value {rebalanceNonce} takes if this rebalance executes. It is NOT unique: a cancelled or expired
+    ///        proposal and its replacement share the id, and expiry emits no event; a proposal is live only while
+    ///        block.timestamp <= eta + AUCTION_DURATION.
```
Add a unit test in test/IndexToken.rebalance.t.sol that runs start -> warp past expiry -> start and asserts that the two RebalanceStarted logs carry distinct proposal ids (or, with the doc-only fix, that they share id 1).

### XA-60 [INFO] proposeGuardian replaces a pending guardian change without emitting a cancellation, so event-built 'pending proposals' views show two pending guardians

- **Dimension:** Documentation (event-correctness)
- **Location:** `src/IndexFactory.sol:252-257`
- **Reported by:** r2-critic (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

`proposeGuardian` overwrites the pending change silently: `pendingGuardian = newGuardian; pendingGuardianEta = eta; emit GuardianProposed(newGuardian, eta);` (IndexFactory.sol:252-257). It emits `GuardianChangeCancelled` only when the owner calls `cancelGuardianChange` (:260-266). IIndexFactory.sol:143 notes that it "Replaces any pending change". README.md:162-164 tells the app to "Show pending proposals" using `GuardianProposed` plus `GUARDIAN_DELAY`.

Scenario: on day 0 the owner calls `proposeGuardian(X)`, emitting `GuardianProposed(X, day7)`. On day 3 it calls `proposeGuardian(Y)`, emitting `GuardianProposed(Y, day10)`. An app or indexer that follows the README event list shows X executable from day 7 and Y from day 10. On chain only Y can ever execute. The X entry never clears, because no `GuardianChangeCancelled(X)` is emitted. Watchers who rely on events to spot a hostile guardian swap see a wrong timeline. No funds are at risk.

**Proposed fix (reviewer)**

src/IndexFactory.sol:252-257:
```diff
     function proposeGuardian(address newGuardian) external onlyOwner {
+        if (pendingGuardianEta != 0) emit GuardianChangeCancelled(pendingGuardian);
         uint256 eta = block.timestamp + GUARDIAN_DELAY;
         pendingGuardian = newGuardian;
         pendingGuardianEta = eta;
         emit GuardianProposed(newGuardian, eta);
     }
```
Test in test/IndexFactory.t.sol: propose X, then propose Y, and `vm.expectEmit` `GuardianChangeCancelled(X)` followed by `GuardianProposed(Y, eta)`.

### XA-61 [INFO] The guardian check on owner config changes can be removed by the owner in 7 days, and the guardian cannot veto that; the security model presents the check as standing

- **Dimension:** Documentation (doc-accuracy / trust-model)
- **Location:** `ARCHITECTURE.md:257-261 (also src/IndexFactory.sol:252-281, 16-22)`
- **Reported by:** r2-critic (reported INFO)
- **Touches a recorded product decision:** yes
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

ARCHITECTURE.md:258-260 lists, as a limit on shape distortion, "the owner changing a pool, exclusions or a reference supply, behind the 2-day delay and the guardian's cancel". The guardian cannot block its own replacement. `proposeGuardian` is `onlyOwner` (IndexFactory.sol:252), `cancelGuardianChange` is `onlyOwner` (:260), and `executeGuardianChange` is permissionless (:269). A compromised or malicious owner Safe can therefore:
- day 0: `proposeGuardian(address(0))` or an address it controls;
- day 7: execute the change. The old guardian's cancel power ends here (IndexFactory.sol:19-20 only promises it lasts while the replacement is pending);
- day 7: `proposeListing(token, config)` with a chosen pool or reference supply;
- day 9: execute it. No one can cancel it now.

After that the owner shapes every holding index's next rebalances. Per rebalance this is bounded by the clip, but it compounds each month and combines with the known TWAP/auction value leak (R1-sec-economic-1). The design choice itself (no instant guardian change) is recorded. The gap is that the docs present the guardian's cancel as an independent check, when it holds only until 7 days after a public `GuardianProposed`. Holders and the app need to treat `GuardianProposed` as the real alarm, and README.md:162-164 does not say so.

**Proposed fix (reviewer)**

ARCHITECTURE.md:258-260 (and the matching trust bullet at :253-255):
```diff
-  owner changing a pool, exclusions or a reference supply, behind the 2-day delay and the guardian's cancel; a
+  owner changing a pool, exclusions or a reference supply, behind the 2-day delay and the guardian's cancel (the owner
+  can replace or remove the guardian after GUARDIAN_DELAY, and the guardian cannot block that, so a `GuardianProposed`
+  event is the earliest warning of an unchecked config change, 9 days ahead); a
```
README.md:162-164, add: "Treat `GuardianProposed` as a security alert: once it executes, config changes can no longer be cancelled by the current guardian." If a code-level check is wanted instead (this changes a recorded decision, so it needs explicit approval), let the current guardian call `cancelGuardianChange` only for a proposal that removes the role (`pendingGuardian == address(0)`).

### XA-62 [INFO] Interfaces declare the same custom errors again, so no contract or interface can inherit both

- **Dimension:** Code quality (duplicated-declarations)
- **Location:** `src/interfaces/IIndexRule.sol:15-25`
- **Reported by:** quality-repo (reported LOW)
- **Verification:** not agent-verified (orchestrator spot-check)
- **Severity note:** Orchestrator: no contract inherits two of these interfaces today, so this is a maintainability note, not a defect.

**Problem**

The same errors are declared in several places. `error ZeroAddress();` is in IIndexRule.sol:15, IIndexToken.sol:42 and IndexZap.sol:106. `error LengthMismatch();` is in IIndexFactory.sol:41 and IIndexRule.sol:24. `InvalidMethodology(uint8)` and `TooFewComponentsForCapped(uint256)` are in IIndexFactory.sol:45-46 and IIndexRule.sol:21-22. `Unauthorized(address)` is in IIndexFactory.sol:57 and IIndexToken.sol:47. `NotIndex(address)` is in IIndexRule.sol:25 and IndexZap.sol:103. `InvalidRecipient(address)` is in IIndexToken.sol:43 and IndexZap.sol:108. The methodology check is also written twice: `IndexFactory._validateMethodology` (IndexFactory.sol:147-152) and `IndexRule._weights` / `_cappedWeights` (IndexRule.sol:253-257, 276) both revert on the same conditions with separately declared errors. I verified the concrete consequence in a scratch copy: `interface IBoth is IIndexFactory, IIndexRule {}` fails to compile with `DeclarationError: Identifier already declared` at IIndexFactory.sol:46 / IIndexRule.sol:22. So an integrator or a future zap interface cannot combine these interfaces, and each copy can drift in parameters. If one side changes, for example `TooFewComponentsForCapped(uint256 count, uint256 min)`, the selectors split and an app decoding a single ABI misreads one of the two reverts.

**Proposed fix (reviewer)**

Add src/interfaces/IXindexErrors.sol and have the interfaces inherit it instead of redeclaring:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Errors shared by more than one Xindex contract.
interface IXindexErrors {
    error ZeroAddress();
    error LengthMismatch();
    error InvalidMethodology(uint8 methodology);
    error TooFewComponentsForCapped(uint256 count);
    error Unauthorized(address account);
    error NotIndex(address index);
    error InvalidRecipient(address to);
}
```
src/interfaces/IIndexFactory.sol:7  `interface IIndexFactory is IXindexErrors {` and delete lines 41, 45, 46, 57.
src/interfaces/IIndexRule.sol:14  `interface IIndexRule is IXindexErrors {` and delete lines 15, 21, 22, 24, 25.
src/interfaces/IIndexToken.sol:17  `interface IIndexToken is IERC20, IERC20Permit, IXindexErrors {` and delete lines 42, 43, 47.
src/IndexZap.sol (or a new IIndexZap, see CQ-5): inherit IXindexErrors and delete lines 103, 106, 108.
Selectors do not change, so existing `vm.expectRevert(abi.encodeWithSelector(IIndexRule.ZeroAddress.selector))` calls keep compiling through inheritance.

### XA-63 [INFO] Test setup helpers are copied almost verbatim across test files

- **Dimension:** Code quality (test-dry)
- **Location:** `test/IndexToken.t.sol:63-69`
- **Reported by:** quality-repo (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

Several test helpers exist in multiple copies:
- `function _list(address token) internal { IIndexFactory.TokenConfig memory config = market.config(token, 0); vm.prank(owner); factory.proposeListing(token, config); vm.warp(block.timestamp + factory.LISTING_DELAY()); factory.executeListing(token); }` appears identically in IndexFactory.t.sol:42-48, IndexToken.t.sol:63-69, IndexZap.t.sol:89-95 and Security.t.sol:150-156. IndexRule.t.sol:53-58 has a variant that takes the config as a parameter.
- `_mintLegs(address)` / `_burnLegs(address)` for the same wbtc/weth/link basket appear in IndexZap.t.sol:106-119 and again in Security.t.sol:172-190.
- `_config(address pool, uint256 referenceSupply)` appears in IndexZap.fork.t.sol:91, Rebalance.fork.t.sol:83 and Security.fork.t.sol:56.
- `_issue` (deal/mint, approve, issue) appears in IndexToken.rebalance.t.sol:70, Rebalance.fork.t.sol:98 and Security.fork.t.sol:71.
- `_assertBacked` over `components()` appears in IndexToken.rebalance.t.sol:98 and Rebalance.fork.t.sol:111. IndexToken.t.sol:87 has a hand-unrolled three-component version.
- The QuoterV2 interface is declared twice, as `IQuoterV2` (IndexZap.fork.t.sol:15) and `IQuoterV2ExactInput` (Rebalance.fork.t.sol:16).
- `IUniswapV3PoolOracle` (IndexZap.fork.t.sol:35) duplicates script/interfaces/IUniswapV3PoolSetup plus src IUniswapV3Pool.slot0.
CLAUDE.md sets the listing flow as the required test pattern ("proposeListing ... vm.warp past LISTING_DELAY, and executeListing"). If that flow changes, for example with a new delay or an extra step, four or more copies must be edited in step, and a missed copy fails in a confusing place. This is maintainability only; the tests pass today.

**Proposed fix (reviewer)**

Add test/utils/XindexTest.sol:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {IndexFactory} from "../../src/IndexFactory.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IndexToken} from "../../src/IndexToken.sol";

abstract contract XindexTest is Test {
    function _listWith(IndexFactory factory, address owner, address token, IIndexFactory.TokenConfig memory config) internal {
        vm.prank(owner);
        factory.proposeListing(token, config);
        vm.warp(block.timestamp + factory.LISTING_DELAY());
        factory.executeListing(token);
    }

    function _assertBacked(IndexToken idx) internal view { /* body of IndexToken.rebalance.t.sol:98-105, using IERC20 */ }
}
```
Have IndexFactory/IndexToken/IndexZap/IndexRule/Security tests inherit it, and replace each `_list(token)` body with `_listWith(factory, owner, token, market.config(token, 0));`. Move the shared `_mintLegs`/`_burnLegs` and the two QuoterV2 interfaces into `test/utils/` or `test/fork/` the same way.

### XA-64 [INFO] CI clones unused nested submodules its lock check never verifies, and the pinned Foundry version is not documented

- **Dimension:** Code quality (build-config)
- **Location:** `.github/workflows/test.yml:19-22,50-53`
- **Reported by:** quality-repo (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

The checkout uses `submodules: recursive` (test.yml:22). `git submodule status --recursive` shows this pulls 9 nested submodules that the build never uses, because foundry.toml remappings point only at the top-level lib/ paths: lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts (plus its own erc4626-tests, forge-std and halmos-cheatcodes), and forge-std v1.14.0, erc4626-tests and halmos-cheatcodes under both OZ repos. The lock-check loop reads only the top-level `.gitmodules` (`git config -f .gitmodules --get-regexp '^submodule\..*\.path$'`), so nothing verifies these nested commits. It also checks only one direction: a foundry.lock entry with no `.gitmodules` path, such as a stale or renamed dependency, passes silently. Separately, the workflow pins `version: v1.8.1` (test.yml:53), but README.md:249-250 says only "a pinned Foundry version" and CLAUDE.md's Commands section gives none. CLAUDE.md requires `forge fmt --check` and a zero-finding `forge lint` locally, and formatter and lint output change between Foundry releases, so a contributor on another version can get results that differ from CI. The nested copies also add three forge-std trees to .vscode/settings.json's Wake remappings (lines 5-14), which must be kept by hand.

**Proposed fix (reviewer)**

.github/workflows/test.yml:22
-          submodules: recursive
+          submodules: true   # only lib/*; the nested OZ test submodules are unused by the build
After the while-loop (before `exit "$failed"`), add the reverse check:
```bash
for dep in $(jq -r 'keys[]' foundry.lock); do
  if ! git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}' | grep -qxF "$dep"; then
    echo "::error::foundry.lock pins $dep but .gitmodules has no such submodule"
    failed=1
  fi
done
```
CLAUDE.md Conventions: add `Foundry v1.8.1 (the version CI pins in .github/workflows/test.yml); run fmt and lint with it.` and state the same in README.md:249-250.

### XA-65 [INFO] Script helpers and fee-tier constants are duplicated between ConfigureWhitelist and SetupTestMarket, and scripts depend on concrete IndexFactory

- **Dimension:** Code quality (duplication)
- **Location:** `script/ConfigureWhitelist.s.sol:6,41-42,145,162,180,230-232`
- **Reported by:** quality-repo (reported INFO)
- **Verification:** not agent-verified (orchestrator spot-check)

**Problem**

`uint24 public constant POOL_FEE_LOW = 500; uint24 public constant POOL_FEE_MEDIUM = 3000;` appears in ConfigureWhitelist.s.sol:41-42 and again in SetupTestMarket.s.sol:62-63. `function _same(string memory a, string memory b) private pure returns (bool) { return keccak256(bytes(a)) == keccak256(bytes(b)); }` is duplicated at ConfigureWhitelist.s.sol:230-232 and SetupTestMarket.s.sol:317-319. The version check at SetupTestMarket.s.sol:203 is a third inline copy of the same comparison. ConfigureWhitelist imports the concrete `IndexFactory` (line 6) and types `propose(IndexFactory factory, ...)`, `safeCalldata(IndexFactory ...)` and `execute(IndexFactory ...)`. Every member it uses (RULE, listingEta, PROPOSAL_WINDOW, isWhitelisted, tokenConfig, proposeListing, executeListing) is on `IIndexFactory`, so the script needlessly compiles the whole factory, rule and token and is tied to the implementation instead of the ABI. forge-std's `vm` has no string-equality cheatcode, so the shared helper belongs in a small script base or library.

**Proposed fix (reviewer)**

Add script/ScriptUtils.sol:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
library ScriptUtils {
    uint24 internal constant POOL_FEE_LOW = 500;
    uint24 internal constant POOL_FEE_MEDIUM = 3000;
    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
```
In both scripts, set the public constants from `ScriptUtils.POOL_FEE_*`, replace `_same` with `ScriptUtils.same`, and delete the private copies.
script/ConfigureWhitelist.s.sol:6
-import {IndexFactory} from "../src/IndexFactory.sol";
and change the `IndexFactory` parameter and local types at lines 82, 145, 162, 180 and 201 to `IIndexFactory` (tests passing an `IndexFactory` instance convert with `IIndexFactory(address(factory))`).

## Coverage and what was not swept

The second round still found 6 new items (all LOW/INFO), so the loop was **not dry** when it hit the 2-round cap. A third round could find more low-severity items.

- **sec-token** (4 findings): Did not read the OpenZeppelin EIP712Upgradeable/ERC20PermitUpgradeable source; clone permit safety was judged from the known v5 behaviour, where the domain separator uses address(this). IndexRule.sol and IndexFactory.sol were read only for the parts that decide IndexToken rulings (targetUnits/_targets/_bound/_redistribute, _validateComponents, delist, isOwnerOrGuardian).
- **sec-rule** (2 findings): Not run: a numeric fuzz of _redistribute residual gaps at extreme price ratios, and a fork check of the observation-ring coverage claim against live pools. Both were reviewed by reasoning only (the Oracle.write growth-at-wrap case keeps at least 200 blocks, 2400 s, of history).
- **sec-factory** (1 findings): How the rule and indexes consume a malicious-but-valid TokenConfig (for example an arbitrary referenceSupply) is left to the IndexRule reviewers. Only checkConfig was read. The guardian's rebalance powers (cancel and keep mask) were not traced beyond the isOwnerOrGuardian call sites in IndexToken.sol.
- **sec-zap** (2 findings): SwapRouter02 behaviour (the pay-WETH-from-held-ETH branch, CONTRACT_BALANCE == 0 sentinel, the exactOutput full-output require, multi-hop payer and recipient routing) was checked from knowledge of the deployed swap-router-contracts source, not from a vendored copy, because none is in lib/. IndexToken.sol was read only in its relevant ranges (lines 80-456), not in full. No PoC was run.
- **sec-economic** (2 findings): ARCHITECTURE.md sections 2-5 read in ranges (lines 40-300), not the whole file. test/Security.t.sol read in ranges (the helpers and R01-R05, R17-R23). IndexFactory config and guardian flows were not re-read line by line; owner abuse was checked only as far as it reaches the rule's inputs. The real Uniswap V3 cost of manipulation is estimated from pool mechanics, not measured on a fork.
- **sec-scripts** (6 findings): I could not check the reference supplies (CoinGecko figures from 2026-09-15) or the Sepolia addresses on-chain because this environment has no RPC. The mainnet addresses were checked against ARCHITECTURE.md, README and ForkAddresses.sol only. The state-changing scripts were not dry-run on a fork.
- **corr-rule** (2 findings): Simulation-based claims in ARCHITECTURE.md section 4 (3.7% turnover with a 0.37-0.48% executor take, 5% of auctions expiring, a single redistribution pass leaving up to 28% unplaced) were not reproduced. Also not checked: whether the capped closed form matches the external Numbers spreadsheet beyond the test vector.
- **corr-core** (3 findings): ARCHITECTURE.md and README.md were read only in the sections about these contracts (ARCHITECTURE 95-150 and 220-343, README 130-150 and 185-215), not in full. OpenZeppelin ERC20PermitUpgradeable/EIP712Upgradeable initialisation was checked from memory of OZ v5, not re-read under lib/. The SwapRouter02 partial-fill and ETH-payment behaviour cited in the IndexZap comments was not re-read in source.
- **corr-tests-sec** (4 findings): Fork tests were not run (no RPC), so fork-only claims (tBTC cardinality below 200 at FORK_BLOCK, prices within 3% of the quotes, the floor covering swap costs) were checked only against the source. The original R01-R23 finding texts are not in the repo, so for R05, R12 and R13 I could not confirm each test would fail if its specific fix were reverted, only that the test's assertions match its name. I checked that the invariant handler reaches its states with an instrumented copy (64 runs: 0 reverts, 28 runs with at least one executed rebalance, some with nonzero supply).
- **corr-tests-unit** (3 findings): Uniswap v3-core Oracle.sol and SwapRouter02 sources are not vendored under lib/, so the checks of the mocks against the real contracts (the lazily grown ring, SwapRouter02's CONTRACT_BALANCE/ETH-payment behaviour, real WBTC pause scope, real NonfungiblePositionManager partial takes) rely on knowledge of those contracts, not on source read in this repo. The fork tests could not be run (no RPC). IndexToken.sol was read only in its rebalance section (lines 215-360), plus a grep of the other functions.
- **docs-natspec** (12 findings): script/interfaces/*.sol (ISafeThreshold, INonfungiblePositionManager, IUniswapV3FactorySetup, IUniswapV3PoolSetup, IWETH9) not reviewed for NatSpec. I read only the relevant parts of README.md and ARCHITECTURE.md to check claims against the NatSpec, not their full text. I did not check that inherited OpenZeppelin functions (ERC20/Permit/Ownable2Step) have documentation.
- **docs-prose** (8 findings): Could not check against source: simulation figures in ARCHITECTURE.md (0.37-0.48% executor take, 5% expiry rate, 28% unplaced value, 27% capped overpay), the claim that navPerToken equals the Numbers-model divisor price, the rehearsal gas and ETH-cost figures (the Sepolia create/seed gas matches the broadcasts; the factory deploy receipt is missing from broadcast/Deploy.s.sol run-latest.json), the Safe proposal timestamps and 2-of-2 threshold, and on-chain figures such as WBTC's 116,132 wrapped float. Sepolia and mainnet address tables were checked against broadcast/ and ForkAddresses.sol and match. Interface NatSpec (src/interfaces) was only grepped for error and event names.
- **quality-repo** (8 findings): src/libraries/TickMath.sol was not read in full (vendored; excluded from restyling by CLAUDE.md). Test files other than MockMarket.sol and ForkAddresses.sol were mapped by grep for helper duplication, imports and local interfaces rather than read in full, so short local names and ambient-global reads inside test bodies (for example Scripts.t.sol env-var handling, Mocks.t.sol, IndexToken.invariant.t.sol handler) were not swept line by line.
- **process** (6 findings): README.md and ARCHITECTURE.md were read only in the sections the process docs reference (Development, Deploy, Testnet, Layout, Verification, and the rebalance bound). The rest of their content was not cross-checked against the code. I did not verify whether `forge build --sizes` re-runs lint on a cached build with no changes. The Wake gate was not executed.
- **hazard-truth** (7 findings): Read only in part: script/testnet/SetupTestMarket.s.sol (lines 55-90 and 215-240), test/Scripts.t.sol (lines 150-300 and grep hits), and src/IndexZap.sol (constants, events and errors only). The fork test bodies were checked by grep for script or ForkAddresses use; they were not read line by line. The web-app repo was not available, so what it actually mirrors is inferred from the README. Mainnet addresses and reference supplies were not re-checked on-chain (no RPC was used); I only checked that the repo copies agree with each other today.
- **hazard-enforce** (5 findings): Not covered:\n- Gas at MAX_COMPONENTS=20 against the EIP-7825 per-transaction cap of 2^24 gas was not measured. Fork tests only log gas for 5 components and there was no RPC, so no finding was filed.\n- script/testnet/SetupTestMarket.s.sol, FaucetToken.sol, the IIndexToken, IRebalanceExecutor and ISwapRouter02 interfaces, and the test files were read only by targeted grep, not in full.\n- Coupling between AUCTION_START_MULTIPLIER (IndexToken) and MAX_TARGET_UNITS (IndexRule) was checked by hand. With multiplier 1.5 the maximum next units are 1.25 x target, which fits in uint96. No finding.\n- The factory's EIP-3860 initcode margin (6,971 bytes) is already listed in ARCHITECTURE.md section 5 and would fail loudly at deploy, so it was not re-reported.
- **hazard-ops** (8 findings): script/testnet/SetupTestMarket.s.sol and FaucetToken.sol not read in full; committed broadcast JSONs inspected only for contract names and addresses and the commit field; whether `forge script --verify` verifies the constructor-created IndexRule/IndexToken implementation (additionalContracts) not established; no forked dry-run of the Safe batch executed.
- **r2-sec-core** (1 findings): src/libraries/TickMath.sol was not re-read (vendored, and outside the cross-contract focus). SwapRouter02's exactInput and exactOutput internals and sweepToken were judged from the deployed swap-router-contracts source as I remember it, because none of it is vendored under lib/. No PoC was run for SEC-ZAP-MH-1. OpenZeppelin ERC20PermitUpgradeable and EIP712Upgradeable were not re-read. I checked by reasoning and found nothing new in these edge states: - empty index and parity settlement - a single-component index - expired or cancelled rebalances with claims outstanding - delisted tokens in live indexes - config changes during the notice period - supply going from 0 to non-zero during a pending rebalance - WETH or USDC as a component, tokenIn or tokenOut - boundary comparisons (start/execute/listing/guardian/deadline) - termination of _redistribute/_shift and eligibleWeight never being zero - the MAX_TARGET_UNITS derivation - the storage-based reentrancy guard in clones Anything I found there was already in the known list (dust-supply parity, surplus kept by the executor, TWAP distortion and staleness, restart griefing, kept components still being priced), or it was sub-raw-unit settlement rounding dust with no economic effect. None of it was re-reported.
- **r2-periphery** (2 findings): test/mocks/Mocks.t.sol was not read. README.md was read from line 100 to the end (integration, whitelist policy, limitations, addresses, development, deploy, testnet), not lines 1-99. test/Scripts.t.sol was read only in its Deploy section (lines 100-200) plus a grep of its test names. The broadcast JSONs were checked only for tx types, gas limits and receipt counts. Fork tests were not run (no RPC), so the claims about pinned-block state (cardinalities, WBTC/USDT owner powers) were checked against source only. No real SwapRouter02 WETH9()/factory() values were read on-chain.
- **r2-critic** (3 findings): These gaps were checked by reasoning only and produced no findings, so they stay open: - EIP-712/permit in clones: checked in EIP712Upgradeable. The domain uses address(this) and the per-clone name, so it is safe. - Storage-based ReentrancyGuard at a zeroed clone slot: checked in the lib source. Zero is not ENTERED, so it is safe. - Zap rounding and refund underflow paths. - uint40 eta and keepMask widths. - Time-window boundary consistency between start/execute and propose/execute. - _redistribute termination and residual gap: at most about one raw unit per component. - Divide-by-zero in _shift. - Fee-on-transfer component on the zap burn path: on real Uniswap V3 the pool's balance check reverts, so it is not exploitable.  Not investigated: - Gas of startRebalance/executeRebalance/createIndex at MAX_COMPONENTS=20 with 8 exclusions each, against the EIP-7825 2^24 per-transaction gas cap. No measurement; the estimate is well under the cap. - A PoC run for the event findings. They rest on direct source reading. - SwapRouter02 and Uniswap v3-core Oracle source, which are not vendored: exactOutput multi-hop payer routing, ETH-payment branch, price-limit partial fills. - A fork run of any claim. - Numeric reproduction of the ARCHITECTURE simulation figures (0.37-0.48% executor take, 5% expiry, 27% capped overpay). - Whether a front-run issue/redeem that changes supply just before an executor's fill can grief executors beyond gas. - test/ files other than the two mocks listed, and ConfigureWhitelist.s.sol lines 1-39. - src/libraries/TickMath.sol (vendored). - The remaining interfaces: IIndexRule beyond lines 26-94, ISwapRouter02, IUniswapV3Pool, IUniswapV3Factory.

## Next steps

Triage (the skill's next stage) takes findings one at a time with a TDD fix for each.
For a `whole-repo` run the skill also files MEDIUM/LOW/INFO findings as GitHub issues labelled `audit`, `pass<N>` and severity. It then commits `.audit/runs.jsonl` and `.audit/scope.json` to the default branch.
Neither has been done yet: `gh` is not authenticated, and both are actions on the shared repository.
