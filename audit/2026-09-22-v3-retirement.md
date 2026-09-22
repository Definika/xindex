# Retirement of the Uniswap V3 findings

On 2026-09-22 Xindex moved pricing from Uniswap V3 pool time-weighted means to Chainlink USD feeds, and execution from
SwapRouter02 to Uniswap's Universal Router 2.0.0, which reaches both V3 and V4 pools with the venue chosen per leg.
The reasons are in `ARCHITECTURE.md` under "Why Chainlink, and why the Universal Router"; the short version is that
Uniswap V4 carries no oracle at all, so following the liquidity to V4 meant leaving Uniswap for prices, and the
Universal Router still reaches V3 depth, so execution could follow the liquidity without giving up the pools that are
still deeper.

That is a change of mechanism, not a change of behaviour, so some past findings no longer describe anything in the
repository. This file says which, and what happened to the property each one protected. It does not restate the
findings: `audit/triage.md` (2026-09-16, `XA..`), `audit/2026-09-18-logic-review.md` (`LR..`) and
`audit/2026-09-19-triage.md` (`DA..`) still hold the originals, and the v1 and `R..` findings are in the v1 report.

Dispositions here extend the usual set with one more:

- **RETIRED:** the mechanism the finding lived in is gone. The evidence names the test that was removed and the
  property, if any, that survives elsewhere.
- **RE-TARGETED:** the finding still binds, against the new mechanism. The evidence names where its test is now and
  what changed inside it.
- **UNAFFECTED:** everything not listed. The mechanism, the fix and the test are untouched.

A retired id is not free to reuse and its test must not be restored against the new design. If the property matters
here, it gets a new id from the review of this surface.

## Retired

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| XA-01 | MEDIUM | Distorted TWAP at the snapshot moves value through the auction | RETIRED | The snapshot reads a Chainlink feed, so there is no window to distort and no `minLiquidity` floor to defeat. `test_XA01_*` removed from `test/Security.t.sol` and `test/fork/Security.fork.t.sol` with the harmonic-liquidity check itself. What replaces the defence is not a check but a different trust assumption: Chainlink's OCR round, listed under Known limitations. The cost model this finding produced — $3–16k to hold a thin pool off-market for thirty minutes — is why the migration happened, and is recorded in `ARCHITECTURE.md`. |
| XA-02 | LOW | Stranger restarts an unfilled auction at a distorted snapshot | RETIRED (in part) | Fix (b), the snapshot price checks, is retired with XA-01. Fix (a) stands and is the whole of the id now: after an unfilled auction `startRebalance` holds strangers off for `REBALANCE_DELAY`. `test_XA02_*` keeps that half in `test/Security.t.sol`; the `_extremeBlock` helper it used for the distorted half is deleted. |
| XA-09 | LOW | `MIN_OBSERVATION_CARDINALITY = 200` assumes 12-second blocks | RETIRED | The constant is gone with the pool reads. `test_XA09_XA45_constantsStayInTheirRelationships` removed from `test/IndexRule.t.sol`. |
| XA-45 | INFO | Cross-constant relationships enforced only by comments | RETIRED (in part) | Its window-and-cardinality assertions went with XA-09. The assertion that survives, the target cap against the auction's multiplier, is in `test_constants` in `test/IndexRule.t.sol`, beside new assertions on `MAX_PRICE` and `MAX_FEED_STALENESS`. |
| DA-02 | HIGH | An untraded pool passes the deviation and liquidity checks it should fail | RETIRED | The observation-age check, the sub-window deviation check and the harmonic-liquidity floor are all gone, and with them the extrapolation that made them agree on a silent pool. `test_DA02_*` removed from `test/IndexRule.t.sol`. A feed that stops updating is caught by `maxStaleness` instead, which is a bound on the data rather than on the venue, and unlike a silent pool nobody can clear it by trading. |
| DA-03 | HIGH | `MAX_TICK_DEVIATION` does not bound a sustained push; the floors are the only lever | RETIRED | Both levers are gone: there is no deviation check and no `minLiquidity`. The floors were data, and `_assertFloorIsNotStale` in `test/fork/MainnetAddresses.fork.t.sol` is deleted with them. The fork test now checks the feeds from both sides instead — `description()`, `decimals()`, a positive and fresh answer, and circuit-breaker bounds at least a hundredfold from the current answer on both sides, which is where the stuck-at-a-bound class is now caught. |
| DA-04 | INFO | A twelve-second liquidity-one dip blocks a component's snapshot for thirty minutes | RETIRED | That sensitivity was a property of the harmonic mean, which is gone. Nothing a third party can do makes a live feed fail `checkConfig` or `targetUnits`, which is the half of the griefing surface the migration closes outright. |
| DA-07 | INFO | A component whose WETH pool has zero in-range liquidity takes no config at all | RETIRED | `InvalidMinLiquidity` and `ThinPriceHistory` no longer exist. The shape recurs with a different cause and a different remedy — a deprecated or stuck feed also takes no config, because `checkConfig` runs `_price` — but unlike a pool it does not recover by itself, so the escape is a replacement config through the listing flow rather than waiting. Stated in `AGENTS.md` under the whitelist policy and in the README's Known limitations. |
| DA-19 | INFO | Cardinality bounds the ring's capacity, not the history it holds | RETIRED | There is no ring. |
| LR-08 | INFO (tests) | The fork whitelist check never validated entries whose pool has too few slots | RETIRED | `PoolHistoryTooShort` is gone, so nothing shadows the rest of `checkConfig` any more, and `_checkBehindTheSlotCount` is deleted from `test/fork/MainnetAddresses.fork.t.sol`. The property it was protecting — that every default entry is validated in full on-chain — is now structural: `defaultWhitelistMatchesMainnet` runs `rule.checkConfig` on each entry with nothing to short-circuit it. |
| R01 | — | Snapshot price manipulation through the pool | RETIRED | Same mechanism as XA-01; test removed from `test/Security.t.sol`. |
| R02 | — | Snapshot taken from a pool with too little history | RETIRED | Same mechanism as DA-02 and XA-09; test removed from `test/Security.t.sol`. |
| R03 | — | Sub-window deviation bounds the snapshot | RETIRED | The deviation check is gone; test removed from `test/Security.t.sol`. |

## Re-targeted

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| DA-01 | HIGH | A target basket may be worth less than the one it replaces | RE-TARGETED | The rounding fix is untouched; only the fixture changed. `test_DA01_*` in `test/Security.t.sol` reaches the same 2e36 : 1e18 value ratio through a coarse USD price on an 8-decimal token instead of the `COARSE_TICK` helper, which is deleted. |
| DA-06 | MEDIUM | A kept component is still priced under capped | RE-TARGETED | The property is unchanged and so is the reason: a kept component's market cap sits in every other weight's denominator. What can make it unreadable is now a stale feed rather than an unreadable pool. `test_DA06_*` in `test/IndexRule.t.sol` uses `market.setAge`. |
| XA-05 | LOW | Keep mask cannot route around an unreadable component | RE-TARGETED | Same re-targeting as DA-06, which narrowed it. `test_XA05_*` in `test/IndexRule.t.sol`. |
| DA-11 | MEDIUM | `executeListing` must re-run `checkConfig` on a stored config | RE-TARGETED (narrowed) | The re-validation stands and `test_DA11_*` in `test/IndexFactory.t.sol` keeps it, driving the config stale through the feed instead of through pool depth. The grief half of the finding is gone rather than re-targeted: a pool could be held thin by a third party, and a live feed cannot be. |
| XA-23 | INFO | Overflow in rule products at extreme prices | RE-TARGETED | The 256-bit proof is unchanged, because `MAX_PRICE = 1e56` was chosen to stay under the ceiling that proof was derived for, so `MAX_EXACT_PRICE` and `Basket.scale` keep theirs. `test_XA23_*` in `test/IndexRule.t.sol` reaches a WAD price of 5e55 through a mock feed rather than an extreme tick. |
| LR-09 | INFO | The exact-value branch is never exercised beside the scaled one | RE-TARGETED | `test_LR09_*` in `test/IndexRule.t.sol` sets an 18-decimal answer of 1 beside 5e55, which is the same pair of magnitudes the tick version produced. |
| LR-05 | MEDIUM | A restart after an unfilled auction must take a fresh snapshot | RE-TARGETED | The three `test_LR05_*` tests stand. The rule's instance moves prices with `market.setPrice` rather than by moving a tick. Its comment no longer cites XA-01 as a live defence. |
| L03 | — | The zap must not swallow a slippage revert | RE-TARGETED | What the caller sees changed: the Universal Router dispatches swaps as internal calls, so a failure surfaces as the pool's own revert rather than wrapped. `test_L03_*` in `test/Security.t.sol` expects `V3TooMuchRequested` where it once expected `Too much requested`, and a fork test asserts the same against `0x66a9…`. This was verified on the pinned deployment, which is why `IUniversalRouter` declares no `ExecutionFailed`. |
| I02 | — | A burn's output shortfall must be caught at the recipient | RE-TARGETED | The check is unchanged in property and still measured on the recipient's balance. Its tests in `test/Security.t.sol` and `test/fork/Security.fork.t.sol` drive the shortfall through `MockUniversalRouter` rather than `MockSwapRouter`. |
| I03 / FR01 | — | Stray ether in the router must not block a burn | RE-TARGETED | The Universal Router never wraps a stray balance into a swap the way SwapRouter02's `refundETH` path could, so the fork test now asserts the weaker true statement: ether sent to the router is never spent by a leg, and stray `tokenIn` is swept back to the zap and refunded. `test_I03_*` and `test_FR01_*` in `test/fork/Security.fork.t.sol`. The zap still has no `receive()`, so native ether never reaches it. |
| I12 / XA-08 | — | A partially filled hop must return the unsold input | RE-TARGETED | The promise holds on both venues, by different means. A V3 burn leg is still sold hop by hop and every hop's unsold input is forwarded. A V4 burn leg is one action, where an intermediate partial fill leaves an unsettled credit and the leg reverts atomically, so only its first hop can leave unsold input; `SWEEP` returns it and the zap forwards it. Tests in `test/Security.t.sol` through `MockUniversalRouter`'s `PartialFirstHop` mode, and in `test/IndexZap.t.sol` for the V4 half. |
| XA-30 | INFO | Delivered tokens must not be sent to a router that anyone can sweep | RE-TARGETED | `_checkCommon` now rejects `to == ROUTER` and `to == POOL_MANAGER`. `test_XA30_*` in `test/IndexZap.t.sol` covers both on mint and burn. |

## Unaffected

Everything not listed above. In particular every in-kind property of `IndexToken` is untouched: the contract's code is
byte-identical across this change, it names no price source and no venue, and `MIN_TURNOVER` and
`MIN_SETTLEMENT_RATIO` are ratios, which reprice with the market. `MIN_SETTLEMENT_RATIO`'s 5% allowance was derived
for a thirty-minute mean against spot; against a feed with a 0.5–2% deviation threshold plus heartbeat lag it is more
conservative than it was, so it did not change.

## What this does not cover

The new surface — the single price path, `CompositeFeed`, the Universal Router integration and the V4 legs — has had
no security review of its own. That review is `CR`, and it comes before the external human audit and before mainnet.
