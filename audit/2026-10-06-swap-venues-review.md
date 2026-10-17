# Swap venues: review of PancakeSwap and THORChain on the swap rail (2026-10-06)

The review was done while integrating, by the same author, so it is not independent; an outside review of the zap's
PancakeSwap legs is still owed before launch. It covered:
- the deployed sources the integration depends on: PancakeSwap's v3 Universal Router on Ethereum
  (`0x65b382653f7C31bC0Af67f188122035461ec9C76`, verified on Etherscan), THORChain's router v4.1
  (`0xD37BbE5744D730a1d98d8DC97c42F0Ca46aD7146`, verified on Blockscout) and THORNode's observer and refund code
  (GitLab, `develop`);
- the zap's new leg (`src/IndexZap.sol`, `src/libraries/PancakeRouterCommands.sol`,
  `src/interfaces/IPancakeUniversalRouter.sol`);
- the THORChain planner, `swaprail/thorchain.mjs`.

`design/2026-10-06-swap-venues.md` has the facts and the decisions. Each id here is `SV-…`, and a test for a fixed
finding is named `test_SV1_...`, as `AGENTS.md` gate 6 requires. The zap's new checks were checked against eight mutants
(the wrap removed, two venues allowed on one leg, the router dropped from the refused recipients, a PancakeSwap leg
allowed on a zap without PancakeSwap, the wrong router, the pass-through leg's check, the wrong burn path, a PancakeSwap
path's endpoints unchecked), and the planner's refusals against eight more. Every one fails a test.

| Id | Severity | Finding | Status |
|---|---|---|---|
| SV-1 | Medium | PancakeSwap's router takes ether from anyone, and after its last command sends its whole ether balance to the caller with `safeTransferETH`, reverting if that fails. The zap cannot receive ether, by rule. One wei sent to the router would revert every PancakeSwap leg of every zap until someone else's transaction carried it away: a denial of service for the cost of a transfer, repeatable at will. Uniswap's 2.0.0 router has neither the open `receive` nor the refund. | Fixed: every PancakeSwap call the zap makes ends with `WRAP_ETH(ADDRESS_THIS, CONTRACT_BALANCE)`, which wraps the router's ether into WETH it keeps, so the refund has nothing to send and no ether reaches the zap. `test_SV1_strayEtherInThePancakeRouterCannotBlockALeg` (on the mock, which follows the deployed source) and `testFork_SV1_strayEtherInThePancakeRouterCannotBlockALeg` (on the deployed router: with the wrap removed the zap's mint reverts `ETH_TRANSFER_FAILED`). |
| SV-I1 | Info | PancakeSwap's Safe (3 of 7) can pause the router, and owns the V3 factory, which can attach a liquidity-mining contract every pool calls during a swap. Either can make PancakeSwap legs revert. Neither can take a zap user's funds: a leg is pre-funded only with what it may spend and swept back in the same call. | Documented in `IPancakeUniversalRouter`, the zap's NatSpec, the design note and the README's known limitations. `test_aPausedPancakeRouterStopsOnlyItsLegs` and `testFork_pancake_aPausedRouterStopsOnlyItsLegs` show a paused router reverting the whole mint with nothing stranded, and the same mint going through on Uniswap. |
| SV-I2 | Info | No public repository holds PancakeSwap's v3 Universal Router at the deployed version, and no audit of it was found. | Recorded. The deployed source is the reference for `PancakeRouterCommands` and `MockPancakeRouter`; the router is pinned by runtime code hash (`testFork_thePancakeRouterIsPancakes`), which also fixes its pool deployer and init code hash, and every leg the zap sends it is run on a mainnet fork. |
| SV-I3 | Info | A THORChain deposit made inside any contract but THORChain's router is read only while `EVMDISABLECONTRACTWHITELIST` is 1 and only in a transaction of at most 200 logs; otherwise THORChain ignores it and the funds are lost. Its vaults rotate, its Ethereum router is due to migrate, and outbound into a contract is limited to whitelisted aggregators carrying ether. So a zap that deposited into THORChain could lose a burn's proceeds silently. | Not built into any contract. THORChain is used app-side, from the user's own accounts, through `swaprail/thorchain.mjs`, which refuses a contract sender and a contract destination (`refusals: contracts, wrong assets and wrong directions`). |
| SV-I4 | Info | THORNode's quote endpoint quotes what it is asked: on 2026-10-06 it quoted 0.1 BTC to USDC with Uniswap's router as the destination, no refund address and a limit of 0. An app that sent THORNode's memo as given could swap with no price protection to an address that strands the output. | The planner writes its own memo with a limit and, from Ethereum, the user as refund address, refuses contract destinations, cross-checks two THORNode endpoints, pins the Ethereum router and checks that the quote resolves the asset asked for. `node --test swaprail/`; `swaprail/check-live.mjs` refuses the same destination live. |
