# Each chain's own DEX beside Uniswap (2026-11-26)

## The call

On 2026-11-26 the owner, told that Base's coins trade thinly on Uniswap, said that only the Uniswap rule has to
change: "ეთერიუმი იყოს უნისვაპზე მარა ყველა ჩეინს თავის დექსზე აქვს დიდი ლიკვიდობები რაც ჩვენ გვაწყობს" (let Ethereum be
on Uniswap, but every chain has deep liquidity on its own DEX, which suits us). Shown the depth below, the owner took
the recommendation: Uniswap stays on every chain, each chain adds its own DEX, and each leg names the deeper pool; and
asked that the DEXes' documentation be read first, "so we build everything correctly and safely".

It reverses the call of 2026-10-14, "the zap swaps through Uniswap's Universal Router 2.0.0 alone"
(`audit/2026-10-14-pancakeswap-retirement.md`). The ids that went with PancakeSwap then (SV-1, SV-I1, SV-I2) stay
retired; what this change finds gets ids of its own.

## What the depth said

Each pool's balance of the paired token (the wrapped gas coin or the chain's dollar), read at each chain's head on
2026-11-26, ETH at $1,691 and BNB at $552. It measures depth roughly, not a price impact.

| BNB Chain | Uniswap V3 | PancakeSwap V3 | PancakeSwap V2 |
|---|---:|---:|---:|
| WBNB | 1,605,304 | 3,742,537 | 9,489,212 |
| BTCB | 6,431,332 | 21,016,420 | 1,555,652 |
| ETH | 2,389,417 | 3,689,186 | 1,465,664 |
| XRP | 112,535 | 308,861 | 273,021 |
| ZEC | 200,851 | 188,430 | 173 |
| LTC | 7,496 | 129,682 | 306,386 |
| ASTER | 38,343 | 284,069 | 32,180 |
| STABLE | 1,896 | 353,011 | 0 |

Ondo's tokens have no pool of note on any of the three.

| Base | Uniswap V3 | Aero CL | Aero basic | Aerodrome (old) |
|---|---:|---:|---:|---:|
| WETH | 33,182,645 | 2,991,194 | 2,138,697 | 622,588 |
| cbBTC | 23,434,597 | 12,263,364 | 114,634 | 1,646,060 |
| AERO (new) | 1,306 | 3,586,528 | 11,332,390 | 0 |
| MORPHO | 348,756 | 424,788 | 0 | 154,317 |
| AAVE | 44,696 | 365,539 | 0 | 20,690 |
| cbETH | 34,794 | 730,915 | 0 | 256,333 |
| cbXRP | 24,495 | 336,693 | 0 | 11,162 |
| UNI | 115,074 | 10 | 0 | 2 |

So Uniswap is still the deepest venue for WETH, cbBTC and UNI on Base, PancakeSwap for nearly everything on BNB
Chain, and Aero for AERO, AAVE, MORPHO, cbETH and Coinbase's stocks on Base. FET, GRT, PEPE, SNX and CRV have no depth
on any of Base's venues: they are copies of Ethereum coins that barely trade there.

## The two routers, read from their deployed source

Both sources were read as verified on Sourcify (exact match), since a repository's head is not always what is
deployed: PancakeSwap's head differs from its deployment in four of the files read.

### PancakeSwap's Infinity Universal Router on BNB Chain

`0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB`, deployed at block 47,215,887, solc 0.8.26; PancakeSwap's documentation
names it the chain's Universal Router (developer.pancake.xyz, "Universal Router addresses").

- A fork of Uniswap's Universal Router. `V3_SWAP_EXACT_IN` (0x00), `V3_SWAP_EXACT_OUT` (0x01) and `SWEEP` (0x04) take
  the same inputs as Uniswap's: `(recipient, amount, limit, path, payerIsUser)` and `(token, recipient, amountMin)`.
  With `payerIsUser` false the router pays from its own balance, so the engine's pre-fund and sweep work unchanged. A
  V3 path is Uniswap's shape, the fee tier in the three bytes between tokens (100, 500, 2,500 or 10,000 on BNB Chain).
- `V2_SWAP_EXACT_IN` (0x08) and `V2_SWAP_EXACT_OUT` (0x09) take `(recipient, amount, limit, address[] path,
  payerIsUser)`, the path forward from the input. Pools are computed from PancakeSwap's factory and init code hash,
  so no route can name a pool that is not PancakeSwap's. An exact input of zero means "already paid" and swaps what a
  pair holds above its reserves: the engine never sends zero.
- An exact-output V3 swap reverts unless exactly the amount asked for arrives (`V3InvalidAmountOut`); a V2 one pays
  what `getAmountInMultihop` quotes, at most the limit.
- `receive()` accepts ether only from WETH and the Infinity vault, so a stranger's wei cannot reach the router; and
  `execute` sends nothing back after its last command. The denial of service SV-1 found in PancakeSwap's older router
  on Ethereum (an open `receive` and a refund of the router's whole ether balance) is absent here.
- `execute` is `whenNotPaused`: the router's owner, a Safe of 3 of 7 (`0xfa206DAB60c014bEb6833004D8848910165e6047`),
  can pause it, and every PancakeSwap leg then reverts. A V3 pool with an active farm notifies its `LMPool` on every
  swap (PancakeSwap's V3 FAQ); the V3 factory's owner sets those. Either can make a leg revert. Neither can take what
  a leg pre-funds: the router is swept in the same call.
- Not used: Infinity's pools, which carry hooks (the reason Uniswap V4 legs must be hookless), and StableSwap.

### Aero's Metarouter on Base

Aerodrome and Velodrome launched as Aero on 2026-10-21 (aero.xyz, "Aero launch update"), on new contracts by Dromos
Labs. The old Aerodrome router reaches only the old pools, which are emptying, so the old router is not used. The
addresses are Aero's own deployment records (`github.com/dromos-labs/metadex-public`, `deployment-addresses/`):
the Metarouter `0x0fEf9e88A7b76BCDBF451780C6774FE32965Ee98` (block 52,856,301, solc 0.8.36), the CL factory
`0x9CB220581b91b0C83223012FE69688b92aD07a76`, and the basic pools' factories, volatile
`0x8E6a9FCd1d638CC760Ffba397605Fe3355dE76D2` and stable `0x78589E876edcEbdce72ee3436ab3c9AD3a7cEF2D`.

- Commands are bytes as Uniswap's, `CL_SWAP_EXACT_IN` 0x00, `CL_SWAP_EXACT_OUT` 0x01, `V2_SWAP_EXACT_IN` 0x08,
  `V2_SWAP_EXACT_OUT` 0x09, `SWEEP` 0x04, but a swap's input is a struct that names its pools, forward from the input:
  `SwapExactInParams(pools, tokenIn, BalanceSpend amountIn, payerIsUser, minAmountOut, recipient)` and
  `SwapExactOutParams(pools, tokenIn, amountOut, payerIsUser, maxAmountIn, recipient)`. `execute` takes a deadline.
- Every pool is checked against Aero's factory registry (`targetToFactory`, then the factory's `isPool`) and its
  family (`POOL_TYPE`), and each hop's tokens are read from the pool. An exact-output CL route must deliver exactly the
  amount asked; an exact-output basic route checks the recipient's balance increase.
- With `payerIsUser` false a swap spends the router's own balance, "every other token spends its full balance", and
  the batch's closure sends the whole balance of every token it touched back to the caller. So the engine's pre-fund
  works, and what a hop left unsold comes back in the same call, a stranger's balance of that token with it, as
  Uniswap's sweep does.
- Its `receive()` takes ether only from WETH or during a batch, and the closure returns a batch's ether; delegatecalls
  are refused.
- Fees move: a CL pool's fee is `min(base fee + volatility fee, fee cap)`, set by the first trade of each block, and a
  trade whose priority fee passes a threshold pays an MEV tax on top, up to a cap (Aero's "Trading" page; neither cap is
  published there). The fee modules are Aero's, set by a Safe of 3 (`0x42255e3C2d0b71a0b006243148fdF1a71d054cE0`),
  which can also pause the basic pools. A higher fee costs a leg more within its own limits; it moves no token the
  engine has not pre-funded.

## The design

1. **One field more per leg.** `MintLeg` and `BurnLeg` get `bytes localRoute`, the route through the chain's own DEX.
   A leg names exactly one of `v3Path`, `v4Path` and `localRoute`, or none for the pass-through leg (`BadRoute`
   otherwise). Its first byte names the pool family, `0` concentrated liquidity and `1` the constant-function pools
   (PancakeSwap's V2, Aero's basic pools), and the rest is a path of Uniswap's V3 shape, `token | uint24 | token |
   ...`, in the leg's direction: from the component back to `tokenIn` for a buy, from the component to `tokenOut` for
   a sale, as `v3Path` is. The three bytes are PancakeSwap's fee tier, Aero's tick spacing, zero for a PancakeSwap V2
   pair, and `0` volatile or `1` stable for an Aero basic pool. A route names tokens, never pool addresses, so its
   endpoints are checked as a V3 path's are, and each pool is the DEX's own by construction.
2. **Which DEX is fixed per deployment.** The zap and the builder take a `LocalDex` at construction: none (Ethereum,
   Sepolia), PancakeSwap (its router) or Aero (the Metarouter and its three factories). `DeployWeighted` resolves it
   from the chain's address book and refuses any other address on chains 1, 56 and 8453, as it does Uniswap's router.
   Aero's pools are found from the factories (`getPool`), never taken from a caller.
3. **The engine's rules hold for every venue.** Each leg pre-funds the router with what it may spend and gets the rest
   back in the same call (a `SWEEP`, or the Metarouter's closure after one); nothing is approved and Permit2 is never
   used; every amount is a balance change; a buy checks delivery (`ShortFill`); a sale goes one hop at a time and hands
   each hop's unsold input to `_onUnsold`, told apart from what the router held before; `SharedBalance` holds.
4. **New recipients refused.** The chain's DEX router joins Uniswap's router and pool manager among the addresses the
   zap and the builder refuse as a recipient, and the deploy checks refuse it as a role.
5. **What is trusted, said with it.** PancakeSwap's Safe can pause its router, and its V3 factory's owner sets the
   farm contracts its pools call; Aero's Safe sets its pools' fee and MEV-tax modules and can pause its basic pools.
   Each can make that venue's legs revert or cost more, within the caller's limits; none can take a pre-funded leg.
   The app labels the venue of each leg.

## What was built

- `src/UniversalRouterSwaps.sol`: the `LocalVenue` at construction (`InvalidLocalVenue` for addresses that do not fit
  the DEX, or Uniswap's router named again), `localRoute` on both legs, a venue per leg (`_checkRoute`), PancakeSwap's
  V3 and V2 commands on its router, Aero's commands on the Metarouter with its pools from the factories, every sale one
  hop at a time. `IndexZap` and `BasketBuilder` refuse the chain's DEX router as a recipient and a local route on the
  pass-through leg. New declarations of our own: `IAeroMetarouter`, `IAeroCLFactory`, `IAeroPoolFactory`,
  `AeroCommands`, and the V2 commands in `UniversalRouterCommands`.
- `script/`: the routers and factories in the address books, `DeployChecks.pinnedLocalVenue` and `resolveLocalVenue`,
  the chain's DEX among the market contracts no role may be, and `checkDeployment`'s comparison.
- The zap's and the builder's release hashes and ABIs moved; the factory's, the math's and `MintRequests`' did not.
- Tests: `test/UniversalRouterSwaps.venues.t.sol` on `MockMetarouter` and PancakeSwap's V2 commands in
  `MockUniversalRouter`; the deploy checks on each chain; and on the real routers,
  `testFork_theZapMintsAndBurnsThroughPancakeSwap` (BNB Chain: WBNB through its V2 pair, BTCB and ETH through V3
  pools) and `testFork_theZapMintsAndBurnsThroughAero` (Base: WETH and cbBTC through CL pools, cbETH along two CL
  hops, WETH's sale through a volatile basic pool), with each router's and factory's code hash pinned. Mutants LV1 to
  LV24.

## Left out, each for a reason

- PancakeSwap's Infinity pools and Aero's old Aerodrome pools: hooks, and pools being emptied.
- A local DEX on Ethereum: the owner kept Uniswap there.
- The keeper: its executor buys through Uniswap's SwapRouter02 with its own funds; a venue per chain there is a change
  of its own, after this one.
- The app, which encodes `localRoute`, quotes each venue and shows which one a leg uses.

## Base's AERO moves to Aero's token

Base's list held the AERO of Aerodrome (`0x940181a94A35A4569E4529A3CDfB74e38FD98631`). Aero's AERO is
`0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee`, and its depth is on Aero's pools: about $15M against about $2M left on the
old pools and $0.3M on Uniswap. Asked, the owner said "კი, გადაიყვანე" (yes, move it), and the list holds Aero's since
2026-11-26. Read before it, from its verified source (Sourcify, exact match): Solady's ERC-20, no owner, pause,
blocklist or proxy; only its immutable `MINTER` mints, and only the voting escrow and the two migration contracts burn,
each its own balance. Aero's `AerodromeMigration` converts the old token one for one (`depositLiquid`), but its owner
can pause it and, paused, burn what is left of the new tokens it holds (`burnRemaining`): the conversion lasts while
Aero keeps it open.

Not moved, the owner's call: Ethereum's list holds Wormhole's copy of the old token
(`MainnetAddresses.AERO`, `0x750525C1877E30304F1E22b1b49b4C9DdE674ddF`), and the keeper's restock buys the old token on
Base and bridges it in. The copy redeems to the old token alone, whose depth is leaving and whose conversion Aero can
end.

## CAKE joins BNB Chain's list

Counted on 2026-11-27, Ethereum's CAKE (`MainnetAddresses.CAKE`, PancakeSwap's own contract there) had about $700
on Uniswap's V3 pools, and BNB Chain's CAKE was deep on PancakeSwap's V3 pools: about 2.7M CAKE and $480k of USDT in
the 0.25% pool against USDT, and 1.56M CAKE and 1,778 WBNB in the 0.25% pool against WBNB. The owner's call that day:
"cake bnb ში დავამატოთ" (let us add CAKE on BNB). BNB Chain's list is 366 since, CAKE `Native`, the thirteenth of its
coins (`BnbChainAddresses.COINS`). Ethereum's CAKE stays listed.

Read on chain 56 at block 135,919,980: "PancakeSwap Token", symbol Cake, 18 decimals, no proxy, no pause and no
blocklist. Its one power is `mint`, held by its owner, PancakeSwap's MasterChef
(`0x73feaa1eE314F8c655E354234017bE2193C9E24E`). The MasterChef mints the emissions its own owner sets, a contract
(`0x6e85689f055B6894803d5135981F7B108C9DAfd5`) answering to a Safe of 3 of 7
(`0xeCc90d54B10ADd1ab746ABE7E83abe178B72aa9E`). So PancakeSwap's signers can raise CAKE's supply, as Binance's one
key can raise each Binance-Peg coin's. Pyth's CAKE/USD feed has a price stored on BNB Chain, and `PriceFeeds` names
it.

Tests: `testFork_tokensAreWhatTheirNamesSay` and `testFork_everyBnbTokenPassesTheCheck` read CAKE, the check
recording its mint by a contract and no code a key can replace. `testFork_cakeTradesThroughPancakeSwap` mints an
index of WBNB and CAKE from USDT and burns it back through PancakeSwap alone, CAKE through the 0.25% pool against USDT.
BNB Chain's suite near its head on 2026-11-27 (block 135,920,666): 21 of 21, every Ondo token's check and the
whole-list index, now of thirteen coins, among them.
