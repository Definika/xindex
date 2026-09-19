# Deep audit of 2026-09-19

A whole-repository security audit at `main` `9116cb8`, after the 2026-09-16 whole-repo audit (`audit/triage.md`) and the
2026-09-18 logic review (`audit/2026-09-18-logic-review.md`). Two rounds ran: eighteen finders across a contract x lens
matrix, each finding torn at by three independent adversarial verifiers (code reading, reproduction, intent and
precedent), then three deep-dives and a combined drain/brick sweep and a completeness critic. 31 distinct findings were
raised in round one, 3 refuted outright by a majority of verifiers; round two added 14 and refuted or downgraded several
more. The lead auditor independently reproduced the headline finding and built and tested its fix.

Baseline at the time of the audit: `forge test` gives 314 passed, 0 failed, 4 skipped (318 total); the 4 skipped are the
fork suites, which need `MAINNET_RPC_URL`. The working tree was clean at `9116cb8` before and after; every experiment ran
in a copy outside the repository.

Severity is by impact on user funds, liveness and correctness. "Reproduced" means a test was written and run that
exhibits the defect.

## Summary

| ID | Sev | Finding | Reproduced |
|---|---|---|---|
| DA-01 | HIGH | `IndexRule._clip` floors a target into whole raw units and the dropped value is paid to the executor for nothing | yes |
| DA-02 | HIGH | A pool with no observation inside the window makes the snapshot TWAP a spot read, and one block of JIT liquidity satisfies the liquidity floor | partly |
| DA-03 | MEDIUM | `MAX_TICK_DEVIATION` compares the sub-windows only with each other, so a manipulation held across the whole window reads spread 0 | no |
| DA-04 | MEDIUM | One shallow block crushes the 30-minute harmonic-mean liquidity, blocking `startRebalance` and the listing pipeline for 30 minutes | yes |
| DA-05 | MEDIUM | Settlement is a fixed-rate trade against a snapshot up to three days old; the auction band bounds the multiplier, not price drift | yes |
| DA-06 | MEDIUM | Under CAPPED a kept component is priced with the unchecked `_price`, and its cap reshapes every trading component's target | yes |
| DA-07 | MEDIUM | A pool with zero in-range liquidity locks a listed token out of every config the owner could propose | yes |
| DA-08 | LOW | `MIN_TURNOVER` gates gross outflow only; nothing checks that anything is bought back | yes |
| DA-09 | LOW | No floor on the index start price, and `initialUnits` silently floors a component at one raw unit | no |
| DA-10 | LOW | `_supply` reads excluded balances with a spot `balanceOf` inside the snapshot (latent: unused by the shipped whitelist) | yes |
| DA-11 | LOW | `executeListing` applies a config the rule validated two days earlier and never re-checks it | yes |
| DA-12 | LOW | A hostile guardian can block every rebalance indefinitely by cancelling each proposal | yes |
| DA-13 | LOW | `executeRebalance` binds a fill to nothing the executor simulated; a dust `issue` in the same block reverts a funded fill | yes |
| DA-14 | LOW | `executeRebalance` reads `balanceOf` on every component, so a keep mask cannot route around one whose `balanceOf` reverts | no |
| DA-15 | LOW | `IndexZap` ignores the per-leg limit on the leg whose component is `tokenOut` (burn) or `tokenIn` (mint) | no |
| DA-16 | LOW | An unexecuted guardian change expires silently while the factory views still report it pending | no |
| DA-17 | LOW | `redeemSkipping` books the claim to `msg.sender`, so any forwarding router strands the skipped components | no |
| DA-18 | LOW | No sanity bound on `referenceSupply`: one mistyped number drives a component to its floor at the next rebalance | yes |
| DA-19 | LOW | `MIN_OBSERVATION_CARDINALITY` checks the ring's capacity, not how much history it holds | no |
| DA-20 | LOW | `ConfigureWhitelist`: `RELIST` is silently ignored when a config-change proposal is pending | no |
| DA-21 | INFO | Documentation gaps: five statements in README/ARCHITECTURE/NatSpec that the code falsifies | n/a |
| DA-22 | INFO | Test gaps: the LR-02 fuzz cannot see value loss by construction, and three behaviours no test pins | yes |
| DA-23 | INFO | Index name and symbol are unconstrained and duplicable | no |

---

## DA-01 (HIGH) `IndexRule._clip` floors a target and the dropped value is paid to the executor

**Where.** `src/IndexRule.sol:567`, inside `_clip`'s interior branch:

```solidity
targets[i] = Math.max(Math.mulDiv(share, basket.scale, p), basket.lo[i]);
```

`Math.mulDiv` floors. The residue below one whole raw unit is not carried, not redistributed and not accounted: it
simply vanishes from the target basket. The target basket is therefore worth strictly less than the current one, and
`IndexToken` settles the difference to whoever fills the auction. Nothing downstream notices, because
`IndexToken._checkBacking` (`src/IndexToken.sol:322`) only checks per-component backing against the **new** units and has
no notion of value — by design, since the token is oracle-free.

**Reproduced.** A two-component index where one raw unit of component A is worth about 1% of the basket value per 1e18
shares. `previewTarget(0)` returned targets `[50, 98.400137e18]` against current `[50, 100e18]`, turnover
`7999656804036334` (0.7999%, clearing `MIN_TURNOVER` of 0.5%). `previewRebalance()` then returned:

```
amountsOut  [0, 15998627275034547940]
amountsIn   [0, 0]
```

A `MockRebalanceExecutor` in `Noop` mode — delivering **nothing at all** — settled the rebalance (`rebalanceNonce` 1) and
kept 15.998e18 of component B. The rule wanted A at 50.8 units; the floor took it back to 50, so the entire turnover was
value that left the basket and was never bought.

A second, realistic reproduction on a WBTC/WETH pair at BTC 110k / ETH 3k with the shipped reference supplies measured
`previewTarget(0)` turnover of 0.5499% while the growing leg asked back only 8,342,405,204 wei of WETH, worth 0.0125% of
NAV: **97.7% of the certified turnover was value that left and was never bought**, and NAV fell 53 bps in one settlement
for which the executor paid 2.05% of what it took.

**Reachability.** The loss per rebalance per component is

```
leak_i = P_i / (10^d_i * V)        fraction of NAV, where V is the index token price in USD
```

because one raw unit of `units_i` is dropped and `units_i` is denominated per 1e18 shares, i.e. one raw unit **per index
token**. The whole turnover can be absorbed into a floor when `leak_i >= MIN_TURNOVER`, that is when
`V <= 200 * P_i / 10^d_i`.

On the shipped whitelist this is a WBTC problem and only a WBTC problem. WBTC has 8 decimals, so one satoshi is about
$0.0011 at BTC 110k:

| token | decimals | one raw unit | whole turnover absorbable below | leak at V=$1 | V=$10 | V=$100 |
|---|---|---|---|---|---|---|
| **WBTC** | 8 | $1.10e-3 | **$0.22** | **0.110%** | 0.011% | 0.0011% |
| OHM | 9 | $2.5e-8 | $5.0e-6 | 2.5e-6 % | — | — |
| the other thirteen | 18 | ~1e-13 | ~1e-11 | ~1e-11 % | — | — |

`createIndex` accepts arbitrary units and `IndexRule.initialUnits` accepts any `startPriceUsdc`; **no document anywhere
recommends a starting price**, and README:96 only says the creator picks one in the UI. So a $0.20 index token holding
WBTC is a perfectly ordinary thing to create, deliberately or by accident, and it bleeds about 53 bps of NAV per
rebalance to a filler who need not deliver anything.

**Severity.** The round-two deep-dive argued MEDIUM, on the grounds that it is WBTC-only, bounded per event, and
self-limiting until ordinary BTC/ETH drift re-arms it. That is fair. It is recorded here as HIGH because the transfer is
permissionless, repeatable, needs no capital and no manipulation, the creator-chosen parameter that governs it is
unbounded and undocumented, and an attacker can create such an index deliberately. The owner should pick between the two
readings on the numbers above; the fix is one line either way.

**Fix (built and tested).** Round the share back into units toward the holders, which is the discipline the token
already follows (`IndexToken.sol:36-38`, "Issue rounds up and redeem rounds down ... always in favour of the remaining
holders"). This is the only site in the value path that rounds the other way.

```diff
--- a/src/IndexRule.sol
+++ b/src/IndexRule.sol
@@ _clip
         } else {
-            targets[i] = Math.max(Math.mulDiv(share, basket.scale, p), basket.lo[i]);
+            targets[i] = Math.max(Math.mulDiv(share, basket.scale, p, Math.Rounding.Ceil), basket.lo[i]);
         }
```

The ceiling still holds: in the interior branch `share <= ceilingValue = floor(hi*p/scale)`, so
`ceil(ceilingValue*scale/p) <= hi` because `ceilingValue*scale/p <= hi` and `hi` is an integer. `MAX_TARGET_UNITS`, the
`SafeCast.toUint96` in `startRebalance` and the `1.5 * MAX_TARGET_UNITS == type(uint96).max` headroom are all unaffected.
The `Math.max(..., lo[i])` is still required, because with a WAD `scale` the ceiling can still land under the floor
(LR-09).

Verified independently twice, in separate copies: with the fix the drain probe is rejected with
`RebalanceUnderfunded(A, 500, 520)` and **all 314 existing tests still pass, unchanged** — including the invariant
campaign, `testFuzz_LR02_targetsAreAWaterFilling` and the LR-09 extreme-tick stress fuzz.

Two alternatives were considered and rejected. Requiring a non-zero `amountsIn` whenever `amountsOut` is non-zero blocks
only the degenerate case: in the realistic WBTC reproduction `amountsIn` is non-zero and the executor still takes a
satoshi worth 49 times what it delivers. Carrying the residue between components cannot always place it, needs another
pass, and still has to floor somewhere.

**That all 314 tests pass either way is itself the finding DA-22:** no existing test detects this.

## DA-02 (HIGH) A quiet pool makes the snapshot TWAP a spot read

**Where.** `src/IndexRule.sol:248` (`_observe`) and `:234` (`_snapshotPrice`).

When a pool's newest observation predates the whole 30-minute window, Uniswap's oracle extrapolates every requested
point from that observation at the pool's **current** tick and **current** liquidity. All three sub-window means are then
equal, so `spread` reads exactly 0 and passes `MAX_TICK_DEVIATION`; and `harmonicLiquidity` reads the current liquidity
rather than anything historical, so it can be satisfied by liquidity minted moments earlier. Both of the XA-01 snapshot
defences degenerate together, on exactly the pools that need them most.

A same-block manipulation is still blocked: a swap writes an observation at the start of the call carrying the
**pre-swap** cumulative, so the attacker must hold the price across at least one block boundary. The attack is therefore
a mint of an out-of-range V3 position (which writes no observation), one swap into that band, a wait, and then
`startRebalance` — with the JIT position making the liquidity floor readable while the price was pushed through an empty
range.

**Residual uncertainty, and it is the whole likelihood term.** How often the thin default-list pools actually go 1,801
consecutive seconds with no swap and no in-range mint or burn was not measured; it needs an archive node. The owner's own
notes record that most default V3 WETH pools are thin and that only OHM and AAVE are deep, and the round-two analysis
names MORPHO (33 WETH), ETHFI (25), LDO (33), CRV (54), PENDLE (54), ONDO (77), SYRUP (86) and ENA (87) as candidates —
but that is inference from depth, not data. **Measure it before shipping**: for each default entry, walk
`observations(index)` backwards for a few days and histogram the gaps. If 30-minute gaps are rare this is MEDIUM; if they
happen several times a day it is firmly HIGH.

**Fix candidates.** Require a minimum number or age of genuine observations inside the window; compare the spot tick
against the TWAP and reject a wide divergence; or require that the oldest observation used is at least `TWAP_WINDOW` old
so no point is extrapolated.

## DA-03 (MEDIUM) `MAX_TICK_DEVIATION` does not bound a sustained manipulation

`_observe` computes `spread` as the difference between the highest and lowest of the three 10-minute sub-window mean
ticks — the sub-windows are compared only with **each other**, never with an outside reference. A manipulation held
steady across the whole 30 minutes moves all three equally and reads spread 0. The check is an outlier filter for a
single-block spike, not a bound on manipulation, and the documentation treats it as the latter.

What the check does give: with `spread <= 2000` a single distorted sub-window can shift the window mean by up to a third
of its own shift, about 667 ticks or 6.9%. What it does not give: any bound at all once the attacker is willing to hold
the price for thirty minutes and pay the arbitrageurs. Round two priced one such push against a pool at its configured
floor at roughly 7.9 WETH (~$31k) for a 22% error — a cost that is small next to the auction discount on a large index.
The cost model rests on assumptions about how liquidity is distributed around spot that were not verified against real
pools.

**Fix candidate.** Compare each sub-window mean against the window mean rather than against each other, which bounds a
uniform push as well as a spike.

## DA-04 (MEDIUM) One shallow block blocks `startRebalance` for 30 minutes

`harmonicLiquidity` is a harmonic mean, so it is dominated by its smallest term. One 12-second block at in-range
liquidity of 1 contributes 12 to a denominator to which the other 1,788 seconds contribute almost nothing, dragging the
30-minute figure to about `1800/12 = 150` regardless of how deep the pool is the rest of the time. An attacker who pushes
a thin pool past its last initialized tick for a single block — with an arbitrageur restoring it in the next — makes
`_snapshotPrice` revert `ThinPriceHistory` for the following 30 minutes on **every** index holding that component, and
makes `checkConfig` reject the token so the listing pipeline stalls too.

Rebalances can be retried, so this is griefing rather than loss; but it is cheap, repeatable, and it composes with the
`REBALANCE_DELAY` hold-off after an unfilled auction.

## DA-05 (MEDIUM) The auction band bounds the multiplier, not the price drift

`startRebalance` freezes the rule's targets; settlement happens up to `REBALANCE_DELAY + AUCTION_DURATION` = three days
later, at a rate fixed by those stale targets. The multiplier band from 1.5 to 0.9 bounds only the ratio at which the
growing legs are settled. It does not bound how far the market has moved in between, and the index trades at the old
relative prices regardless.

Reproduced on a 20%-turnover fixture: when the four sold components appreciate 50% against the bought one over the notice
period — routine for crypto constituents over two or three days — settling at the 0.9 floor costs the index far more than
the README's "up to 10% of the bought value" suggests. The README sentence should be corrected, and the exposure stated
as a function of drift over the notice window rather than of the multiplier alone.

## DA-06 (MEDIUM) A kept component's unchecked price reshapes every trading target

`_snapshotMarket` (`src/IndexRule.sol:366`) prices a kept component with `_price` under the CAPPED methodology, which
applies neither the `minLiquidity` nor the sub-window deviation check. XA-05 introduced this deliberately so a keep mask
could route around an unreadable component. What XA-05 appears to have underestimated is that the kept component's
**cap** still enters `caps[]`, and therefore sits in the denominator of every other component's weight in
`_cappedWeights`. A manipulated kept price does not merely decide a rank: it rescales the targets and the turnover of the
components that actually trade.

Five independent round-one finders raised this without seeing each other's work, which is a strong signal.

Mitigating: a non-zero keep mask requires the owner or guardian (`src/IndexToken.sol:234-237`), so this is a sandwich of
an owner or guardian transaction rather than something a stranger can trigger alone, and round two found it manufactures
a rebalance the honest rule would have rejected without itself leaking value. That is why it is MEDIUM and not higher.

**Fix candidate.** Use `_snapshotPrice` for kept components under CAPPED too, and route around an unreadable component by
some means that does not put its cap in the shared denominator.

## DA-07 (MEDIUM) A dead pool locks a token out of every config

If a component's WETH pool ends with zero in-range liquidity — its LPs withdraw, or its price is pushed permanently
outside every initialized range — the owner cannot propose any config that `checkConfig` will accept:
`minLiquidity = 0` is rejected with `InvalidMinLiquidity`, and any positive value is rejected with `ThinPriceHistory`.
The token can still be delisted and existing indexes can still use a keep mask, so this is a configuration liveness trap
rather than a loss, but there is no path back.

## DA-08 (LOW) `MIN_TURNOVER` gates gross outflow only

`_targets` accumulates `sold` over shrinking components only and returns `turnover = sold / activeValue`. There is no
matching `bought` term and no check that the target basket is worth what the current one is worth. The gate certifies
"this much value leaves the index", not "this much value is traded". In the DA-01 reproduction the two differed by the
entire figure: turnover read 0.5499% while 97.7% of it was value that left and was never bought — so the gate meant to
prevent pointless churn was precisely what made the theft worth doing.

Worth fixing independently of DA-01 as a cheap backstop against any future change to the target maths:

```solidity
bought += Math.mulDiv(targets[i] - units[i], basket.prices[i], basket.scale);   // growing components
turnover = Math.mulDiv(Math.min(sold, bought), WAD, activeValue);
```

## DA-09 (LOW) No floor on the index start price

`initialUnits` computes `units[i] = Math.max(..., 1)` for any caller-supplied `startPriceUsdc`, and `createIndex` only
rejects `units[i] == 0`. Nothing on chain or in the documentation sets or recommends a floor. This is the single
precondition that makes DA-01 reachable on the shipped whitelist, and it does not disappear once `_clip` rounds up: with
ceiling rounding a low-priced index has to **over**-deliver up to one raw unit per growing component, which for WBTC at a
$0.20 index price is 0.55% of the basket against the auction's 10% margin — so such an index may simply stop rebalancing.

Document a floor (the index token should be worth at least ~10,000 raw units of every component; for WBTC that is about
$11 a token), surface it in the create flow, and consider having `initialUnits` revert rather than silently floor at 1.

## DA-10 (LOW) `_supply` reads excluded balances as a spot `balanceOf`

`_supply` (`src/IndexRule.sol:302-314`) subtracts a live `balanceOf` of each excluded address inside the rebalance
snapshot, so a market cap is atomically manipulable whenever a config lists an excluded address a third party can fund
and drain in one transaction — flash loan in, `startRebalance`, flash loan out.

**This is latent, not live.** `_checkExclusions` forbids `excluded` alongside `referenceSupply`, and every entry in
`script/ConfigureWhitelist.s.sol` uses a reference supply with `excluded: none` (tBTC uses on-chain supply, also with no
exclusions). It becomes live the first time a token is listed with exclusions, so the constraint belongs in the listing
policy in writing.

## DA-11 (LOW) `executeListing` never re-checks the config

`IndexFactory._propose` calls `IIndexRule.checkConfig` at propose time; `executeListing` is permissionless and applies
the stored config two days later without revalidating. A pool that met its `minLiquidity` when proposed need not still
meet it when executed. The damage is bounded because `_snapshotPrice` re-checks at rebalance time, so a stale config
blocks rebalances rather than corrupting prices — which is why a majority of round-one verifiers refuted it — but the
token is whitelisted and index-creatable in the meantime.

## DA-12 (LOW) A hostile guardian can block rebalancing indefinitely

`cancelRebalance` has no window check and no rate limit. A compromised guardian can cancel each proposal at the last
second of its auction, pushing `restartAllowedAt` out by `REBALANCE_DELAY` each time; six rounds were driven in a test
with `rebalanceNonce()` still 0. The guardian's power to cancel is deliberate and documented, but its unbounded
repeatability is not, and the units drift arbitrarily far from the rule in the meantime. This is a trust assumption that
should be stated plainly rather than a code defect.

## DA-13 (LOW) A fill is bound to nothing the executor simulated

`executeRebalance(bytes calldata data)` derives the whole settlement from `totalSupply()` read at execution time and
takes no parameter binding it to what the executor quoted — no expected supply, no `maxAmountsIn`, not even the
`expectedNonce` that `IndexZap` requires for exactly this class of staleness. `issue` is deliberately open during the
auction, so anyone can move the supply between an executor's simulation and its transaction. A dust `issue` of 1e14
reverts a fill funded from `previewRebalance()`, repeatably, for the price of gas; the attacker redeems immediately
afterwards and gets everything back.

Value is not at risk — `amountsOut` and `amountsIn` scale together, so an executor sourcing from the callback arguments
is scale-invariant. The gap is that no document says so. `IIndexToken.executeRebalance`, `IRebalanceExecutor` and the
README integration notes should state that the callback arguments are authoritative, that an off-chain simulation is
not, and that executors should keep slack and use a private relay.

## DA-14 (LOW) `balanceOf` on every component defeats the keep-mask escape

`executeRebalance` reads `balanceOf` on every component to build `held[]`, including kept ones, so a keep mask cannot
route around a component whose `balanceOf` reverts — only around one whose `transfer` does. `redeemSkipping` is
unaffected and holders can still leave, so the "holders can always leave" rule holds; the "keep mask routes around a
frozen component" promise is the one that is narrower than stated.

## DA-15 (LOW) The zap ignores the per-leg limit on the pass-through leg

In `_sellBasket` the `component == p.tokenOut` branch checks only that the path is empty, adds `got[i]` to `reported` and
continues — `p.legs[i].minAmountOut` is never read. The mint path has the mirror case for `tokenIn` and `maxAmountIn`.
No funds are at risk, because no swap happens and the amount is the deterministic `previewRedeem` figure, but
`IIndexZap.BurnLeg`'s NatSpec, the README slippage guidance and AGENTS.md all say every leg honours its limit. Either
enforce it or document the exception.

## DA-16 (LOW) A guardian change expires silently

An unexecuted guardian change passes `pendingGuardianEta + PROPOSAL_WINDOW` and becomes permanently unexecutable, but
`pendingGuardian` and `pendingGuardianEta` are not cleared, so the factory views still report it as pending. An operator
watching those views believes a compromised guardian was replaced when it was not. Nothing is stuck — the owner can
re-propose or cancel — but the views should distinguish "pending" from "expired".

## DA-17 (LOW) `redeemSkipping` books the claim to `msg.sender`

`_redeem` records `claimOf[msg.sender][token] += amount` while transferring the unskipped components to `to`. Any
contract that redeems on a user's behalf keeps the claim, and if it is stateless the skipped components are stranded
forever. This is correctly documented (`IIndexToken.sol:159-160` says the claims are ones "msg.sender can collect
later") and the team already works around it — AGENTS.md forbids the zap from calling `redeemSkipping` for precisely this
reason. It is recorded as a design hazard for third-party integrators rather than a defect: the safe shape would be to
book the claim to `to`, which is who receives everything else.

## DA-18 (LOW) No sanity bound on `referenceSupply`

`checkConfig` accepts any non-zero `referenceSupply`. A stale or mistyped figure — say 1 raw unit — drives that
component straight to its floor at the next rebalance and hands the difference to the auction. Owner-only and behind the
two-day listing timelock with a guardian veto, so this is an operational hazard rather than an attack, but a config
whose supply moves by orders of magnitude from the one in force deserves a bound or at least a loud script warning.

## DA-19 (LOW) Cardinality is capacity, not history

`_checkPool` requires `slot0().observationCardinality >= 200`, which anyone can raise with
`increaseObservationCardinalityNext`. That says how many slots the ring has, not that they span 30 minutes. A pool whose
cardinality was raised to 200 passes `_checkPool` and can be listed while its real history is much shorter; `observe`
reverting `OLD` is the backstop, which turns a quality problem into a liveness one.

## DA-20 (LOW) `ConfigureWhitelist`: `RELIST` silently ignored

When a matching config-change proposal is already pending, `RELIST` is ignored and `execute` reports success while the
token stays delisted.

## DA-21 (INFO) Documentation the code falsifies

- README's "Decentralization" summary denies powers the code grants and ARCHITECTURE documents.
- The factory ownership handover — the one admin change with no delay and no guardian veto — is absent from README's
  event list, the ops runbook and ARCHITECTURE entirely.
- `IIndexRule.targetUnits`'s NatSpec still describes the pre-LR-02 redistribution and states a guarantee the shipped
  water-filling does not give. This is two days old and was missed when LR-02 landed.
- ARCHITECTURE.md:83 claims the reentrancy guard covers "every state-changing entry point" of `IndexToken`; ERC-20
  `transfer`, `approve` and `permit` are unguarded, as ARCHITECTURE.md:321 correctly states.
- `RebalanceCancelled`'s NatSpec calls the cancelled proposal "the live one", but `cancelRebalance` also cancels an
  expired auction.

## DA-22 (INFO) Test gaps

- `testFuzz_LR02_targetsAreAWaterFilling` bounds units to 1e18..1e24 ("whole-token magnitudes, so that rounding is far
  below the tolerance") and compares with a 1e-9 relative tolerance. It checks the water-filling's **shape** and never
  its value conservation, and it deliberately excludes the coarse-unit regime where DA-01 lives. That is why 20,000 fuzz
  runs plus 30,000 LR-09 stress runs left the drain in place. A companion fuzz with units bounded from 1 and the
  assertion `sum(target_i*p_i) + n >= sum(units_i*p_i)` fails on run 0 against the current rule and passes 20,000 runs
  against the fixed one.
- Replacing the `MIN_TURNOVER` gate with a plain non-zero check leaves the whole suite green.
- The difference-of-floors form of `amountsOut`/`amountsIn` is pinned by no test.
- `canStartRebalance()` answers true for an uninitialized clone that cannot rebalance at all.

## DA-23 (INFO) Names and symbols are duplicable

`createIndex` constrains name and symbol only to be non-empty. Two indexes can present identically in an app or a block
explorer while holding different baskets. The CREATE2 salt commits to both, so addresses differ; this is an app-level
display concern, worth naming in the frontend notes.

---

## Refuted or already handled

- **The 0.9 auction floor as a recurring annual transfer to fillers.** Refuted 2/3 as documented, deliberate economics.
  DA-05 records the part that is *not* covered by the documented band.
- **The keep mask not routing around a zero measured supply under CAPPED.** Refuted 2/3.
- **`executeRebalance` cannot be settled from an EOA.** Not a finding: this is by design and already pinned by
  `test_executeRebalance_onlyContracts`.
- **Same-block TWAP manipulation.** Not possible: a swap writes an observation carrying the pre-swap cumulative, so an
  attacker must hold across a block boundary. This is what makes DA-02 depend on pool quietness.

## What this audit did not cover

1. **Everything needing an archive RPC.** `MAINNET_RPC_URL` was unset, so `test/fork/*` never ran — including the
   on-chain check of all fifteen default entries and the end-to-end fork rebalances. Re-run them before merging anything.
2. **The likelihood term of DA-02 and the cost model of DA-03.** Both reduce to measurements against real pools that were
   not taken: how often the thin default pools go 30 minutes without an observation, and how liquidity is distributed
   around spot. These are the two numbers that decide whether DA-02 is HIGH or MEDIUM and whether DA-03 is cheap or
   expensive. The `minLiquidity` figures in `MainnetAddresses.sol` are themselves two days old and unre-measured.
3. **`script/testnet/SetupTestMarket.s.sol` (394 lines) and `FaucetToken.sol`** were read only at header level. They are
   testnet-only and guarded, but they are not audited.
4. **Gas at 20 components** rests on an estimate of the real cost of Uniswap's `observe`, not a measurement.
5. **`IndexZap` multi-hop paths containing a cycle** (a path that revisits a token) were raised but not driven to a
   conclusion.

## Recommended order of work

1. DA-01 — apply the one-line `_clip` fix and add the value-conservation fuzz from DA-22. Both are ready and tested.
2. DA-02 and DA-03 — take the two pool measurements, then decide on an oracle hardening. These are the findings that
   could move real money on the shipped whitelist.
3. DA-08 and DA-09 — the `min(sold, bought)` turnover gate and a documented start-price floor. Cheap, and they make
   DA-01's class of defect unprofitable even if something like it recurs.
4. DA-21 — the documentation corrections, especially `IIndexRule.targetUnits`, which is two days stale.
5. The rest in severity order.
