# Xindex keeper

Starts and fills `WeightedHub` auctions on Ethereum, and fills `MintRequests` requests, through its own executor,
`src/KeeperExecutor.sol`. It holds **no role in the protocol**: starting a rebalance, filling an auction and filling a
request are open to anyone, and anyone may run a keeper. Its key is the keeper's own hot key, not the owner's or the
guardian's.

## What it does

Every block L, with T = L's timestamp + 12 (the one block a fill sent now can land in):

1. **Fills.** For each open auction on an index with shares worth at least `MIN_TVL_USD` (valued once per auction and
   again every 25 blocks, with one Hermes request for all of them), the richest 8 first, it fetches Pyth's update for
   second t_L from Hermes, previews the settlement and
   simulates the executor's whole fill exactly as block L+1 would run it (`eth_call` with block overrides), with the
   routes it quoted and the executor's stock. Profit = the USDC float's change + the stock's change valued at Pyth −
   gas. It sends the most profitable fill whose profit reaches `MIN_PROFIT_USD`, with a USDC floor no lower than that
   decision needs (a sandwich can take nothing below it), `maxAmountsIn` and the index's supply a hair above the
   preview's, and a deadline of T: a fill mined late, or after an issue that grew the supply past its bound, reverts in
   its first lines, before Pyth's parse. A fill that reverts on chain all the same, after its simulation passed, holds
   its auction off for 5 blocks, then 10, and after the third this bot leaves that auction until the strikes lapse, 300
   blocks after the last (RX-26); its routes are searched again. Pyth's update fee counts against the profit like gas
   (RX-18), the chosen fill is simulated again with the gas limit it will carry before it is sent (RX-21), and a fill
   below zero profit, which only a negative `MIN_PROFIT_USD` allows, is sent only within `SUBSIDY_BUDGET_USD` a day
   (RX-16). An auction the bot is backed off from does not take one of the 8 check slots (RX-24).
2. **Starts.** Every 25 blocks, for each index anyone may restart, it simulates the auction at its best price
   (μ = MU_MIN, by overriding the hub's pending slot) and starts it only when that would pay, every feed has published
   in the last minute (US-hours stock feeds close), the index is worth `MIN_TVL_USD`, and the executor can deliver
   every coin the auction may ask for. An index holding one of the six US-hours stocks (TSM, AVGO, LLY, JPM, WMT, V) is
   started only when the auction's middle, where μ is 1, falls in a session of Pyth's own schedule for those feeds,
   holidays and half days included (`US_EQUITY_SCHEDULE`), so competition can fill it near 1 rather than at the next
   open near `MU_MIN` (RX-3). The rule covers all twelve share-priced Ondo legs: Pyth's catalogue gives the six named
   24/7 the same schedule (RX-31). Refresh the schedule string each year from the catalogue. The 4 richest ready
   indexes are simulated per round, side by side, their routes kept until the next (RX-34).
3. **Requests.** With `FILL_REQUESTS` on and nothing else to send, the open `MintRequests` requests on the indexes it
   serves are read every 25 blocks, with each index's gate and a Hermes value of one of its shares; a request whose read
   fails is kept as it was and read again. A request is skipped before any simulation when its limit is worth more than
   its escrow at Pyth, or when it is a mint on an index whose gate would not issue to the executor. Of the rest, the 8
   largest in dollars are simulated per block, at most 4 of them on one side while the other side has requests, and a
   request whose simulation reverts waits 2, 4, 8... blocks, at most 200, before the next; one whose fill reverts on
   chain waits 5, then 10, and is left after the third. Each is simulated as block L+1 would fill it. A mint request is
   filled with exactly its limit in shares: the basket for them comes from stock and the routes, is issued to the
   executor and delivered, and the escrowed stablecoin is taken, USDT sold into USDC along a quoted route. A redeem
   request is paid exactly its limit in its stablecoin, USDT bought with USDC: the escrowed shares are redeemed and the
   basket sold along the routes, a coin with no route kept as stock. Profit and the floor are priced as a fill's, and
   the most profitable request whose profit reaches `MIN_PROFIT_USD` is sent, never below zero: requests are not
   subsidised (RX-16). The surplus over a limit is the filler's, which is why the app suggests limits.
   - A request fill reads no Pyth update on chain, so every price it is valued at is Hermes' latest, kept only where
     Pyth's own contract, parsing the signed update Hermes served with it, returns the same price, and only when it
     was published in the last minute with a confidence interval within 2% (RX-1, RX-9). A closed US-hours feed's last
     close therefore prices nothing.
   - The fill names the index's `rebalanceNonce` it was simulated at, and reverts `StaleRebalanceNonce` if a settlement
     landed first (RX-4). Each routed leg carries its quote plus `SLIPPAGE_BPS` as its own bound, and so does the
     stablecoin leg, so a pool pushed ahead of the fill stops it at that leg (RX-10).
   - A fill that reverts on chain strikes the request, its requester and its index, so new request ids do not start
     over (RX-10); a request a check keeps declining without a revert is checked again 2, 4, 8... blocks later, at most
     200 (RX-24).
4. **One transaction in flight.** A transaction that misses its block is replaced on the same nonce by a 0-value
   transfer to itself, its fees raised each block, never above `MAX_FEE_GWEI` and at most 10 times, until something on
   that nonce is mined; after the tenth it only waits, and logs it. A nonce left pending by an earlier run is cleared
   the same way at startup, at most 4 of them, and so is one whose send failed with its outcome unknown; a pending
   nonce the RPC reports beyond those is logged and left alone, so an RPC cannot make the bot cancel every block.

## Inventory

The executor swaps through Uniswap V3 (SwapRouter02) along a route per coin, chosen for each auction by quoting every
`token→USDC` and `token→WETH→USDC` pool at the leg's own size; a route losing more than `ROUTE_MAX_LOSS_BPS` against
Pyth is not used. A coin without a usable route (Wormhole copies, Ondo stocks, Tether Gold) is served from the
executor's **stock**: a coin the index sells is kept, and a coin it needs is delivered from stock, which the operator
keeps filled, for example by bridging through Wormhole's Portal and sending the tokens to the executor. A coin leaves
stock only within the **stock allowance** `OWNER` sets for it (`setStockAllowance(token, amount)`), which every delivery
from stock spends; with none, nothing is served from stock.

The twelve Ondo legs priced at their share's feed (AMZNon, TSMon, SPCXon, METAon, AVGOon, SKHYon, MUon, LLYon, AMDon,
JPMon, WMTon, Von; `SHARE_PRICED_IDS` in `bot/config.mjs`) are worth sValue shares, which the bot cannot read. Keep
their stock allowance at **zero**: the bot refuses any fill that would deliver them from stock, and counts any it keeps
as worth nothing (RX-2). After a split or a reverse split the share's feed is off by the ratio. The bot logs `restock <coins>` and does not start or fill an
auction its usable stock (the lower of the balance and the allowance) cannot cover. Usable stock comes first for a
routed coin too; only the rest is bought. The executor's address must be able to hold and send every coin it stocks.

## Keys and risk

- `OWNER`, a cold key, withdraws float and stock, rotates the keeper (`setKeeper`), sets each coin's stock allowance
  (`setStockAllowance`) and the **request allowance** (`setRequestUsdcAllowance`): how much of the USDC float request
  fills may still turn into anything else, which every request fill ending with less USDC than it started spends
  (RX-1, RX-9). With none, no request fill may cost the float anything. Keep it off the bot's machine.
- `keeper`, the bot's hot key, can only `fill`, `fillMint` and `fillRedeem`, and only for an index the factory
  created, through the request escrow the executor was built with. Anyone can create a factory index and hold all its
  shares, or request a mint of one, so that check does not keep the stock from an index the key's thief owns (CF-1):
  what bounds the stock a stolen key can move is the allowance `OWNER` left, which a request fill spends like an
  auction fill, so keep each allowance to what the next fills need. The key can also trade the USDC float badly within
  the floor it sets itself: keep the float to what fills need, and the key's ETH to a few days of gas.
- **Kept coins are adverse selection.** A coin no route takes is kept as stock, and the worse its pools pay against
  Pyth, the surer no route takes it. The bot values a kept coin at the lower of Pyth and the best quote its route
  search found, for at least the amount kept and at most 25 blocks old, so a coin trading under its feed (a depegged
  Wormhole or Binance-Peg copy) counts at what its pools pay. A coin whose pools exist but quote nothing, their sell
  side emptied as a depegged copy's is, counts as nothing; a quote the RPC failed to answer fails the check rather
  than counting. Only a coin with no pool at all counts at Pyth: that is the Wormhole copies', Ondo stocks' and Tether
  Gold's case, and a bridge incident or a copy trading under its coin's feed then turns float into a coin worth less
  than the bot booked. An index's creator can build one to make the bot buy its other legs with the float, up to the
  auction's turnover cap each interval, and a redeem request up to the request allowance. Keep the float and that
  allowance to what fills need, and serve such coins (`INDEXES`) only where the operator has a market for them. A kept
  coin's quote is the block's own (RX-13); the pools a coin can use are read again every 25 blocks, so one created
  after a depeg counts (RX-17), and a pool nobody initialized is no market, so it cannot zero a coin's value (RX-14).
  An initialized pool whose liquidity is gone still quotes nothing, as XS-5 intends.
- Fills go through the public mempool: anyone can see a fill and its price update before it lands. The floor bounds
  what a sandwich can take. An auction fill whose auction a copier filled first, or that an issue past
  `SUPPLY_TOLERANCE_BPS` reached first, reverts in its first lines; so does a request fill whose request its requester
  cancelled or another filler filled first, or a mint fill on a gated index whose creator disallowed the executor
  ahead of it, before any swap. A request fill that reverts on chain all the same holds that request off for 5 blocks,
  then 10, and after the third this bot leaves it. A request fill also stops at a settlement that landed first (its
  nonce) and at a leg whose pool moved past its bound (RX-4, RX-10). On an auction fill, a pool or a stock balance that
  moves between the simulation and the block shows only at the floor, after the swaps; the floor counts the USDC
  float, not stock, which is why the allowances bound the stock.

## Running

From the repo root:

    forge build                          # the hub and factory ABIs come from abi/, the executor's from keeper/out
    forge build --root keeper
    # deploy src/KeeperExecutor.sol: (SwapRouter02, USDC, FACTORY, MintRequests, OWNER, keeper address); send it a USDC float

Then in `keeper/`:

    npm install
    RPC_URL=... KEEPER_KEY=... FACTORY=... EXECUTOR=... PYTH_API_KEY=... npm start

The RPC must honour `eth_call` block overrides (Tenderly, publicnode and geth do; the bot checks at startup).

Before Glamsterdam reaches mainnet: under EIP-8037 a transaction's state gas comes from a reservoir the GAS opcode does
not show, so the executor's `gasUsed` undercounts fills that write new slots. The bot already simulates every fill it
sends with that fill's own gas limit (RX-21), which catches the shortfall; `TX_GAS_CAP` in `bot/config.mjs` then needs
raising to what EIP-8037 allows (RX-36).

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | required | Ethereum JSON-RPC. |
| `KEEPER_KEY` | required | The executor's keeper key (32-byte hex). |
| `FACTORY` | required | The `WeightedIndexFactory`. |
| `EXECUTOR` | required | This bot's `KeeperExecutor`. |
| `PYTH_API_KEY` | required | Hermes' API key, sent as `Authorization: Bearer`. |
| `HERMES_URL` | `https://pyth.dourolabs.app/hermes` | Hermes since 2026-08-26. |
| `INDEXES` | every index | Comma-separated indexes to serve; anyone can create indexes, so a list caps the bot's work. |
| `MIN_PROFIT_USD` | `5` | Least profit a fill or a start must promise; negative is a subsidy the operator accepts, for auctions only and within `SUBSIDY_BUDGET_USD`. |
| `SUBSIDY_BUDGET_USD` | `0` | Most the auction fills sent below zero profit may cost in all over a rolling day; requests are never subsidised (RX-16). The day restarts with the process. |
| `MIN_TVL_USD` | `1000` | Smallest index the bot starts or simulates a fill for (anyone can open an empty one's). |
| `SLIPPAGE_BPS` | `30` | Room the floor leaves for the pools to move, on the volume the routes trade. |
| `SUPPLY_TOLERANCE_BPS` | `10` | How much an issue may grow the index's supply, and with it the settlement, before the fill reverts, before Pyth's parse. It is also the griefing threshold: an issue of more than this share of the supply ahead of a fill makes it revert, though cheaply, and the bot leaves an auction after three such reverts. |
| `ROUTE_MAX_LOSS_BPS` | `100` | Most a route may lose against Pyth; the auction's whole edge is 200. |
| `MAX_FEE_GWEI` | `100` | No transaction while the base fee and tip exceed this, and no replacement's fees above it. |
| `PRIORITY_FEE_GWEI` | `2` | Tip. |
| `FILL_REQUESTS` | `1` | `1` fills `MintRequests` requests too, `0` serves auctions only. The escrow is the one the executor was built with. |

## Tests

- `forge test --root keeper` (from the repo root): the executor against the real hub, factory and request escrow with
  mocks, request fills included.
- `node --test keeper/test/unit/*.test.mjs`: arithmetic, settings, the route search, the request filter and scan, the
  back-offs, the Hermes client and the transaction tracker; no install.
- `MAINNET_RPC_URL=<archive> npm run e2e` (in `keeper/`): an anvil fork with the real Pyth contract verifying updates
  this test signs, real pools and tokens, and `keeper.mjs` as its own process. It covers a start held back by a quiet
  feed and by missing stock, an index never started, fills only once profitable, stock kept and delivered, a two-hop
  buy, and a fill mined a slot late reverting early and being sent again.
