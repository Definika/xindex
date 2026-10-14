# Retirement of PancakeSwap: the zap's third venue

On 2026-10-14 the owner removed PancakeSwap from the zap: "delete pancake swap we dont need it anymore for swap rail
leave only uniswap". Users come with USDC or USDT on Ethereum, and the zap swaps through Uniswap's Universal Router
2.0.0 alone, V3 or V4 per leg. PancakeSwap's v3 Universal Router had been a third venue per leg since 2026-10-06
(`design/2026-10-06-swap-venues.md`), chiefly for CAKE, the one listed coin deeper there than on Uniswap. CAKE stays
listed; its legs route through Uniswap's pools, or it mints in kind or through `MintRequests`.

The last commit with it is `de7ccdf`. The zap and its interface are restored byte for byte to their build before
PancakeSwap (`4865c7e^`); nothing else had changed them since, so `abi/IndexZap.json` is that build's ABI again. The
`MintLeg` and `BurnLeg` structs lose `pancakePath`, and the zap loses `PANCAKE_ROUTER` and its constructor argument.
Deleted:
- `src/interfaces/IPancakeUniversalRouter.sol` and `src/libraries/PancakeRouterCommands.sol`;
- `script/MainnetAddresses.sol`'s `PANCAKE_UNIVERSAL_ROUTER`; `DeployChecks`' `MAINNET_PANCAKE_ROUTER`,
  `pinnedPancakeRouter`, `resolvePancakeRouter` and `checkRolesAreNotPancake`; `DeployWeighted`'s `PANCAKE_ROUTER`
  setting and argument;
- `test/IndexZap.pancake.t.sol`, `test/mocks/MockPancakeRouter.sol`, `test/mocks/NoEtherCaller.sol`, the mock's own
  test in `test/mocks/Mocks.t.sol`, the PancakeSwap tests of `test/DeployChecks.t.sol`, the router's code-hash pin in
  `test/fork/MainnetAddresses.fork.t.sol` and the PancakeSwap legs of `test/fork/IndexZap.fork.t.sol`.

The zap suites that stay (`test/IndexZap.t.sol`, `test/Security.t.sol`, `test/WeightedZap.t.sol` and the zap's fork
suites) are their pre-PancakeSwap versions plus the later changes that were not PancakeSwap's; they keep every test name
they had before PancakeSwap. `DeployWeighted`'s `ZAP_INITCODE_HASH` records the restored build (CF-5).

This file says which past findings went with PancakeSwap, in the form of `audit/2026-10-07-stage-b-retirement.md`.
**RETIRED** means the mechanism the finding lived in is gone; the evidence names the tests that were removed. A retired
id is not free to reuse, and its test must not be restored against a new design. With THORChain's two
(`audit/2026-10-14-thorchain-retirement.md`), every id of the swap-venue review is now retired.

The check behind this file: the audit ids that name a test at `de7ccdf`, less the ids that name one after this change,
are exactly SV-1.

## The swap-venue review of 2026-10-06 (`audit/2026-10-06-swap-venues-review.md`)

| ID | Sev | Finding | Disposition | Evidence |
|---|---|---|---|---|
| SV-1 | MEDIUM | One wei sent to PancakeSwap's router reverted every PancakeSwap leg of every zap | RETIRED | `test_SV1_strayEtherInThePancakeRouterCannotBlockALeg` removed with `test/IndexZap.pancake.t.sol`, `testFork_SV1_strayEtherInThePancakeRouterCannotBlockALeg` from `test/fork/IndexZap.fork.t.sol`. The zap still has no `receive()` and never takes native ether. |
| SV-I1 | INFO | PancakeSwap's Safe can pause the router or attach a contract its pools call | RETIRED | Recorded by documentation; `test_aPausedPancakeRouterStopsOnlyItsLegs` and `testFork_pancake_aPausedRouterStopsOnlyItsLegs` removed. |
| SV-I2 | INFO | No public source or audit of PancakeSwap's router at the deployed version | RETIRED | Recorded by documentation; the router's code-hash pin `testFork_thePancakeRouterIsPancakes` removed. |

Unaffected: every finding against the Uniswap legs keeps its test, among them DA-15, CR-L02, CR-I26, CR-I27, XA-22,
XA-29, XA-30 and RT-21 in the zap's suites, since those suites keep every test they had before PancakeSwap. The
PancakeSwap-only tests removed with it, beside the three named above, are `test_aLegNamingTwoVenuesIsRefused` (a leg naming
both a V3 and a V4 route stays refused, by `test_route_rejectsBothVenuesOrNeither`) and the other leg, limit, wiring and recipient tests of `test/IndexZap.pancake.t.sol`,
the deploy checks' `test_offMainnetNoPancakeRouterIsAccepted`, `test_onMainnetOnlyThePinnedRouter` and
`test_neitherRoleMayBeThePancakeRouter`, and `testFork_pancake_mintAndBurnCake`; none carried an id.
