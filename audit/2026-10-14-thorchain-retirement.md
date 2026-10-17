# Retirement of THORChain: the swap rail's planner

On 2026-10-14 the owner removed THORChain from Xindex: "remove everything related to thorchain we dont need it". Users
come with USDC or USDT on Ethereum, and the zap buys every component, WBTC included, through Uniswap or PancakeSwap.
THORChain served only a user holding coins on another chain (native BTC, LTC, BCH or DOGE), as an app-side way into
USDC before a mint and back out after a burn. No contract ever called it, so no contract changes.

The last commit with it is `9021f1c`. Deleted:
- `swaprail/`: the planner `thorchain.mjs`, its tests `thorchain.test.mjs`, their fixtures, and the read-only live
  check `check-live.mjs`;
- CI's step that ran the planner's tests;
- THORChain's place in `AGENTS.md`, `README.md` (the swaps row, the frontend note, the known limitation, the router
  address, the command and the layout) and `ARCHITECTURE.md`.

The records that describe it stay as they were written: `design/2026-10-06-swap-venues.md` (with a dated note),
`audit/2026-10-06-swap-venues-review.md` and `audit/2026-10-13-security-audit.md`. PancakeSwap, the other half of the
swap-venue decision, is unchanged, and SV-1, SV-I1 and SV-I2 keep their tests and records.

This file says which past findings went with THORChain, in the form of `audit/2026-10-07-stage-b-retirement.md`.
**RETIRED** means the mechanism the finding lived in is gone; the evidence names the tests that were removed. A retired
id is not free to reuse, and its test must not be restored against a new design.

The check behind this file: the audit ids that name a test at `9021f1c`, less the ids that name one after this change,
are exactly CF-2 and CF-8, both node tests. No Solidity test went.

## The swap-venue review of 2026-10-06 (`audit/2026-10-06-swap-venues-review.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| SV-I3 | INFO | A THORChain deposit made inside a contract can be ignored and lost | RETIRED | Recorded by documentation; no test went. Nothing in Xindex deposits to THORChain. |
| SV-I4 | INFO | THORNode's quote endpoint quotes what it is asked, with no limit or refund address | RETIRED | Recorded by documentation and covered by the planner's tests, removed with `swaprail/thorchain.test.mjs`. |

## The security audit of 2026-10-13 (`audit/2026-10-13-security-audit.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| CF-2 | LOW | One THORNode endpoint alone set a THORChain plan's limit, expiry and fee check | RETIRED | The node test `CF-2: every node quotes; one endpoint alone sets neither the limit, the expiry nor the fee check` removed with `swaprail/thorchain.test.mjs`. |
| CF-8 | — | A Bitcoin-side memo's ticker was never proven by the quote | RETIRED | The node test `CF-8: a memo that names a ticker goes out only once every node resolves that ticker to the asset` removed with `swaprail/thorchain.test.mjs`. |

Unaffected: every other CF id (CF-1 and CF-4 to CF-7 keep their tests, CF-3 its documentation), and every id of the
contracts, the keeper and the scripts.
