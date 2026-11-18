# Batch fills: a small request does not pay for a basket of its own

2026-11-11. The owner's call, after asking why a $100 buyer pays for a swap per coin: "then build it". This is step 1
of three; steps 2 and 3 are at the end and are not built.

## The problem

An index token does not exist until its coins are in the index. A buyer who comes with USDC therefore has someone
turn that USDC into the coins, and until today that happened once per buyer:

- Through the zap, the buyer's own transaction swaps into every coin. A 35-coin mint runs to 16.78M gas.
- Through `MintRequests`, the keeper's `fillMint` bought a whole basket for each request, and its cost came out of
  the request through its limit: the bot fills a request only when the escrow covers the basket, the gas and
  `MIN_PROFIT_USD`.

Either way a $100 purchase carried the gas of a full basket. On a three-coin index with mock pools a single
`fillMint` uses 483k gas; with real pools and ten coins it is several million.

## What was built

Nothing in the protocol changed. `MintRequests.fill` already lets any filler deliver shares it holds, from any
source. What changed is the keeper's executor and bot (`keeper/`), which hold no role.

**`KeeperExecutor.fillBatch(BatchFill)`** fills several requests on one index, in one stablecoin, in one call:

1. `issue` shares are issued to the executor, their basket from stock and along the routes.
2. Each redeem request is paid its stablecoin, and its escrowed shares come to the executor.
3. Each mint request is delivered its shares, and its escrowed stablecoin comes to the executor.
4. `redeem` shares are redeemed, and their basket sold along the routes.

A stablecoin other than USDC is bought before step 2 and sold after step 3, before the redeem.

So in one batch:

- **Buyers share one basket.** Three mint requests are one issue of the sum.
- **A seller's shares go to a buyer.** A redeem request and a mint request of the same size cross: nothing is
  issued, nothing redeemed, no pool is touched and the index's supply does not move.
- **Only the difference trades.** More bought than sold issues the difference; more sold than bought redeems it.
- **The executor's own shares are stock.** Shares left over after a batch stay in the executor, and a later batch
  delivers them. That is a cross between requests made at different times.

Measured on the three-coin test index with mock pools, each touched account cold:

| Call | Gas |
|---|---|
| `fillMint`, one request | 483k |
| `fillBatch`, one mint request | 507k |
| `fillBatch`, ten mint requests | 996k |
| each further request in a batch | 56k |
| `fillBatch`, one seller crossed with one buyer | 252k |

A further request costs about 56k gas whatever the index holds, where a fill of its own costs a basket: on real
pools, one swap per coin.

**The bot** (`keeper/bot/requests.mjs`) plans batches before single fills:

- `batchGroups` groups the open requests by index and stablecoin. A request joins when its escrow is worth at least
  its limit at the keeper's prices. It need not pay `MIN_PROFIT_USD` alone, as a single fill must (RY-8): the batch
  as a whole must. That is what makes a small request fillable.
- `planBatch` fills every request at exactly its limit, passes the sellers' shares to the buyers, delivers from the
  share stock within the owner's allowance, issues only the rest, and keeps what is left up to `SHARE_STOCK_USD`,
  redeeming the remainder.
- The batch is simulated as block L+1 would run it and priced as any fill: the float's change, the stock's change,
  less gas. A request in a batch that pays is not checked alone.

`fillMint` and `fillRedeem` are unchanged and still fill a request that pays alone.

## What bounds a stolen keeper key

The executor's model is unchanged: the hot key can lose the working capital the owner handed the bot and nothing
beyond it. A batch adds one asset to that capital, the executor's stock of an index's own shares, and one bound.

- **The float.** `_requestDelta` measures the float across the whole call, as for a single fill: a batch that ends
  with less USDC than it started spends the request allowance, and reverts beyond it (RX-1, RX-9). Escrows flowing
  in during the batch cannot hide a loss, because only the net is measured and every honest requester is paid at
  least their limit.
- **Coin stock.** A batch's issue takes coins from stock through `_acquire`, which spends each coin's stock allowance
  as before (CF-1).
- **Share stock** (new). The shares a batch hands over (`mintShares` and `redeem`) beyond those it brings in (the
  redeem requests' escrows and `issue`) come out of the shares the executor held before the call. That difference
  spends `stockAllowance[index]`, the same mapping the owner sets per coin, and reverts `OverStockAllowance` beyond
  it. It is computed and spent before anything moves. Without it a stolen key could deliver the whole share stock
  to a mint request of its own for one USDC, or redeem it and sell the basket into a pool it had moved, where the
  float still rises and the request allowance sees no loss (mutants B1, B2).

Shares the executor acquires earn no allowance of their own: only the owner raises one.

A batch reverts as a whole. Every request is read before anything moves (open, not past its deadline, the side
named, on the batch's index and in its stablecoin), and so is the gate when the batch issues, so a request closed
since the simulation costs those reads and not a basket (XS-6, mutants B5, B6). A batch that tolerated a failed
fill was considered and refused: the share accounting above is exact only when every fill happens.

## Limits

- **Not instant.** A request waits until a batch pays. With a share stock a single request can be filled at once.
- **Requests must be open together to cross**, unless the operator runs a share stock.
- **A cross pays the index no fee.** Fees are charged at issue and redeem; shares passed from a seller to a buyer
  are a transfer. The streaming fee accrues as ever. An order fee is the owner's to decide, with the fee policy.
- **Batching shares gas, not pool fees.** New coins bought still pay the pools' fees and slippage. Only a cross or a
  delivery from stock avoids them.
- **A share stock is market risk.** Shares held move with the index. `SHARE_STOCK_USD` is zero by default, and then
  the bot keeps and delivers none. The bot values a share coming in at what redeeming it would bring, less
  `SLIPPAGE_BPS`, and a share going out at what issuing it again would cost, plus `SLIPPAGE_BPS`, so it never counts
  a round trip as a gain. An index holding a share-priced Ondo leg has shares the bot cannot value, and it keeps and
  delivers none of them (RX-2).
- **The bot does not build stock on its own.** Stock comes from sellers' shares the bot keeps, or from shares the
  operator sends the executor. `fillBatch` with no request can issue to stock, within the request allowance, but no
  bot policy calls it yet.
- **One request can stop its batch's simulation.** When a batch's simulation reverts, each of its requests is
  checked alone that block; the one whose own fill reverts is backed off and the batch forms again without it. A
  request that reverts only in company would hold its batch back until the batch's own back-off lapses, 2, 4, 8...
  blocks, reset at each scan.
- **A fair limit still needs a second filler.** With ours alone, the buyer relies on the limit the app suggests.

## Tests

- `keeper/test/KeeperExecutor.t.sol`, the batch section: one basket for three buyers and less gas than three fills;
  a cross with every router call reverting; the difference issued; the difference redeemed; shares kept as stock
  and delivered within the allowance; stock built and run down with no request (`test_CF1_RX1_...`); USDT both ways
  within its bounds; each leg's own bound (`test_RX10_...`); every refused call; another index or stablecoin;
  closed and expired requests and the gate before any swap (`test_XS6_...`).
- `keeper/test/unit/batch.test.mjs`: the grouping, the plan, the stock target and the stock's worth, no install.
- `keeper/test/harness/requests.test.mjs`: the request filler itself against a fake chain, every call encoded with
  the executor's real ABI. It needs the keeper's dependencies, so CI's unit step does not run it.
- Mutants B1 to B7 (the executor) and B8 to B12 (the plan) in `test/mutants/mutants.json`, all killed.

The keeper's end-to-end test passed on a mainnet fork on 2026-11-11 (24 of 24, block 26387247, Tenderly's public
archive), with the start fix below; without it every start failed. It has no request scenario, so it shows that
the auctions still start and fill beside this change, not that a batch fills against real pools. A batch scenario
there is the next proof to add.

## Found on the way: the keeper could not start an index's first auction

Running the keeper's end-to-end test for this change, every start failed with `Panic(50)`, on the committed code
too (`6c871fb`, the quote). The bot simulates a start by writing an eta into the hub, which opens an auction without
counting a proposal, and it wrote zero into the hub's `quoteProposal` slot to say "no quote". The hub holds a fill
to a quote when that slot equals `proposalCount`. On an index never started the count is zero, so zero named the
auction being simulated: its fill was held to a quote of no prices and read past the end of an empty array. An index
that had already had a proposal was not affected, which is why the slot test, which starts one first, passed.

Nothing on chain was wrong: a real start counts its proposal before any fill. But the keeper would never have
started a new index's first rebalance. The bot now writes a proposal id no index reaches (`NO_QUOTE_PROPOSAL`,
`bot/config.mjs`), and `test_theBotsNoQuoteValueBindsNoProposal` pins both the failure at zero and the fix on a
never-started index. The end-to-end test had not been run since the quote was added; on the committed code it
fails at its first start, and with the fix it passes 24 of 24.

## Not built

- **Step 2, gasless orders.** The buyer signs instead of sending an escrow transaction, and needs no ether. USDC and
  the index token have permits; USDT has none. It needs a new contract that holds authorizations, and so a review of
  its own. UniswapX's reactor might serve in its place; whether it accepts orders from our own app is not verified.
- **Step 3, a limit that improves over time.** The order's limit starts in the buyer's favour and moves toward their
  floor, so fillers compete by filling early, as the rebalance auction's executors do, and no price is read.
- A zap that buys a ready index token from a pool when that is cheaper than a mint, as Reserve's does, and a pool
  for it.
- A bot policy that builds share stock ahead of demand.
