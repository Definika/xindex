# The keeper on each chain's own DEX

The protocol's zap and basket builder have reached each chain's own DEX beside Uniswap since 2026-11-26
(`docs/design/chain-venues.md`). The keeper's executor still bought and sold through Uniswap's SwapRouter02
alone, so on BNB Chain and Base it served from stock, or not at all, every leg whose depth is on PancakeSwap or Aero.
Built that day, in the keeper alone; no contract under `src/` changed for it.

## 1. The executor

- **The venue a route names.** `KeeperExecutor` keeps Uniswap's SwapRouter02 (`ROUTER`) and gains the chain's own
  DEX router (`LOCAL_ROUTER`) and how it is called (`LOCAL_KIND`): `None`, `SwapRouter02` (a router of SwapRouter02's
  V3 calls and paths, PancakeSwap's SmartRouter on BNB Chain), or `Aero` (Aero's concentrated-liquidity SwapRouter on
  Base, whose calls carry a deadline and whose paths name a tick spacing where Uniswap's name a fee). Both are
  constructor arguments, named together or not at all (`BadLocalRouter`).
- **The encoding.** A route is a path, 20 bytes and 23 more a hop, for Uniswap; a route through the local DEX is the
  same path behind one byte, `LOCAL_ROUTE` (`0x01`). A path's length less 20 is a whole number of hops, so a local
  route's length cannot be a path's: the residue tells the two apart, and the byte must then be `LOCAL_ROUTE`. Every
  route the bot sent before still means what it meant. `_checkRoutes` and `_checkStableRoute` check the path after the
  byte as they check a Uniswap path, and refuse a local route on an executor with no local DEX (`BadRoute`).
- **Approvals.** A sale approves exactly what it sells, which an exact-input swap spends whole, as before. Uniswap's
  router keeps the float's standing approval of the constructor; the local router is approved for a purchase's bound
  and set back to zero after it, so it never holds an approval of the float between swaps.
- **Not reached.** Aero's volatile and stable pools and PancakeSwap's V2 pairs have no exact-output swap, which every
  purchase of the executor is; the zap and the builder reach them, the keeper does not.
- **Addresses**, each read from its verified source (Sourcify, exact match) and on chain that day:
  - BNB Chain: PancakeSwap's SmartRouter `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` (`factory()` its V3 factory
    `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`, `WETH9()` WBNB; its `exactInput` and `exactOutput` take
    SwapRouter02's structs), and its QuoterV2 `0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997`, of Uniswap's QuoterV2
    calls.
  - Base: Aero's `SwapRouter` `0x9Ee35Bf1bd69a03c6F0393582030fCe8Bb93D418` for its CL factory
    `0x9CB220581b91b0C83223012FE69688b92aD07a76` (the protocol's `AERO_CL_FACTORY`), and its Metaquoter
    `0x1dDfeC5058180C207F55BB77D95AcDd0d8227868`, both from Aero's deployment record (Dromos Labs'
    `metadex-slipstream-public`, `deployment-addresses/cl-base.json`). The old Aerodrome router reaches only the pools
    of before 2026-10-21.
- **Size.** The executor is 23,603 bytes, 973 under EIP-170.

## 2. The bot

- **Two venues, one leg's best.** `createVenues` (`keeper/bot/routes.mjs`) runs a `createRoutes` per venue, Uniswap's
  and the local DEX's (`localMarketOf`, from the chain table's `localDex`), and gives each leg the route of the venue
  that quotes it best within `ROUTE_MAX_LOSS_BPS`, a sale the most and a purchase the least, Uniswap on a tie; a local
  route goes out behind `LOCAL_ROUTE`. `quoteOf` answers the best quote any venue found, so a kept coin is valued at
  the most any of its pools pay (XS-5). The rest of the bot is unchanged: it asks one object for routes, as before.
- **Aero's quotes.** Aero has no QuoterV2. Its Metaquoter takes a route as its pools, in order from the token paid,
  with that token, so the bot reads each hop's pool from the CL factory once and quotes a sale along the pools from the
  component and a purchase along them read backwards, from the float. Its factory takes `int24` tick spacings and its
  pools' `slot0` is one field shorter than Uniswap's, each with an ABI of its own (`keeper/bot/chain.mjs`).
- **The hop from the gas coin.** A route through the wrapped gas coin takes its deepest pool against the float there,
  `hubStep`: fee 100 on PancakeSwap ($114k of USDC against WBNB that day), tick spacing 100 on Aero ($224k against WETH).
- **The setup check** refuses an executor whose local DEX, or its kind, is not the one the chain table names.

## 3. Tests

- `keeper/test/KeeperExecutor.t.sol`: `test_aLocalRouteSwapsThroughTheChainsOwnDex`,
  `test_aeroIsCalledAtTheBlocksOwnDeadline`, `test_aLocalRouteNeedsALocalDexAndAWellFormedPath`,
  `test_theLocalDexIsNamedWithItsKind`, with `keeper/test/mocks/MockAeroSwapRouter.sol`.
- `keeper/test/KeeperExecutor.chains.fork.t.sol`: `testFork_aMintRequestIsFilledThroughTheChainsOwnDex` on BNB Chain
  (PancakeSwap's real pools) and Base (Aero's), and the chain table's check extended to the three local addresses; both
  passed near each head that day, 3 of 3 a chain.
- `keeper/test/unit/routes.test.mjs`: the venues' choice, `localMarketOf`, `hopsOf`, and Aero's quotes by pool. Run
  live against both chains that day through the bot's own code: every leg of WBNB, ETH and CAKE on PancakeSwap and of
  WETH, cbBTC and AERO on Aero quoted.
- Mutants KV1 to KV10, all killed.

## 4. Not done

- The keeper's end-to-end test on this change, which forks Ethereum at its pinned block and needs an archive node.
- The restock service, which buys on home chains through its own markets, is unchanged.
