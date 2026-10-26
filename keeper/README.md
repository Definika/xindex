# Xindex keeper

Starts and fills `WeightedHub` auctions on Ethereum, and fills `MintRequests` requests, through its own executor,
`src/KeeperExecutor.sol`. It holds **no role in the protocol**: starting a rebalance, filling an auction and filling a
request are open to anyone, and anyone may run a keeper. Its key is the keeper's own hot key, not the owner's or the
guardian's. A second process, the restock service (`restock.mjs`, see [Restock](#restock)), keeps the executor stocked
with the coins Ethereum has only as Wormhole copies, buying them on their home chains.

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
   24/7 the same schedule (RX-31). Refresh the schedule string each year from the catalogue. Since 2026-10-26 the hub
   itself refuses a start while a moving feed is shut and ends every auction 6 hours after its start, so the schedule
   only keeps the keeper from starting an auction that would expire unfilled at the close. The start carries the
   Hermes update its check priced, for the next block, with Pyth's fee, and is sent only after a call at that block with
   its own gas limit passes and while the block it was priced on is still the head; a start that missed is checked
   again at the next block. The 4 richest ready indexes are simulated per round, side by side, their routes kept until
   the next (RX-34).
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
executor's **stock**: a coin the index sells is kept, and a coin it needs is delivered from stock, which the restock
service keeps filled for the Wormhole copies it serves ([Restock](#restock)), and the operator for the rest. A coin
leaves stock only within the **stock allowance** `OWNER` sets for it (`setStockAllowance(token, amount)`), and what the
restock service bridges in adds to, which every delivery from stock spends; with none, nothing is served from stock.
With `NEEDS_FILE` set, the keeper writes there every coin a fill, a start or a request is short of, with the whole of it
that fill needs, for the restock service to bring in.

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

## Restock

`restock.mjs` keeps the executor stocked with the Wormhole copies no Ethereum pool sells, without anyone stepping in:
it buys each on its home chain, bridges it to the executor through Wormhole's Token Bridge, and brings home and sells
what nobody needs. It is a separate process with its own key, the **treasury**, a hot key `OWNER` pins
(`setTreasury`), and its own loop, every `RESTOCK_INTERVAL_SECONDS`:

1. Every move in its journal (`JOURNAL_FILE`) goes one step further: a transaction mined, a transfer signed by
   Wormhole's guardians (fetched from Wormholescan) or a CCTP burn attested by Circle (from Iris), then redeemed or
   received on the other side. A move is recorded signed, the journal flushed to the disk, before it is broadcast, so
   a restart, or a power cut, sends the same transaction again rather than a second one; an empty or unreadable journal
   stops the service rather than starting it afresh (RS-13). Redeeming and receiving are counted once by the contracts
   that do them, and a signed transfer or an attestation is stored for a move only when it is the move's own and the
   receiving chain's contract accepts it, so a wrong answer is fetched again rather than kept (RS-14). A signed move
   whose nonce another transaction took is dropped only when a look a minute after the first still finds no receipt,
   and a receipt lookup that fails is never taken for a missing receipt (RS-5).
2. It reads the keeper's `NEEDS_FILE`, the executor's stock and allowances, the treasury's USDC, each home wallet's
   coins, float and gas, and Pyth's prices, and plans (`restock/plan.mjs`). A board that is missing, unreadable or not
   written for 15 minutes is unknown, not empty: no coin is bought, sold or bridged until the keeper writes it again,
   where an empty one would send every coin home (RS-8).
   - a coin whose usable stock and transfers on their way fall short of the needs is bought on its home chain, up to
     the needs and `RESTOCK_BUFFER_BPS` more, counted to the wei, at least `RESTOCK_MIN_USD` of it unless the coins
     already at home cover the needs (RS-3), and bridged in. The executor's `redeemBridged` completes the transfer,
     which carries a payload so that only the executor can complete it, and adds what arrived to the coin's allowance
     as far as the owner's restock allowance for the coin goes (`setRestockAllowance`), which the credit spends
     (RS-1). A coin whose restock allowance is spent is neither bought nor brought in, and the service names the call;
   - a covered coin's coins at home first top the stock up to the needs and the buffer, as far as the restock
     allowance goes, and only the rest is sold (RS-10); stock the executor holds beyond the needs, the buffer and
     `RESTOCK_KEEP_USD`, not counting what is on its way (RS-9), is bridged out to the treasury's wallet on its home
     chain (`bridgeOut`, to the recipient `OWNER` pinned there with `setHomeRecipient`; the allowance is then capped at
     what is left), and what reaches the home wallet is sold for the float;
   - a buy short of float waits for USDC: on a chain CCTP serves, the treasury draws it from the executor
     (`drawUsdc`, within the most the owner lets it hold off the float, `setTreasuryUsdcAllowance`) and sends it
     there; float above twice `RESTOCK_FLOAT_TARGET_USD`, counted after the round's buys (RS-4), comes back, and the
     treasury repays what it holds beyond twice `RESTOCK_TREASURY_TARGET_USD` (`repayUsdc`, which lowers what it holds
     off the float, down to zero, and never raises the owner's figure: RS-2).
3. Every trade is priced against Pyth through the route search the keeper uses (`bot/routes.mjs`, on each chain's
   Uniswap V3 fork), and refused beyond `ROUTE_MAX_LOSS_BPS`; a buy too large for the pool is halved until it fits or
   falls below `RESTOCK_MIN_USD`, so a thin pool restocks in batches. Buys stop at `RESTOCK_DAILY_USD` a day, the last
   one cut to what is left of it (RS-7), and each trade or cross-chain transfer, CCTP's sweeps included (RS-11), at
   `RESTOCK_MAX_TRANSFER_USD`, under Wormhole's Governor's large-transfer delay.
4. It sends one transaction at a time on each chain: nothing is signed while one of the treasury's is pending there,
   each may pay twice the base fee and the tip, as the keeper's, so it stays includable through six full blocks of
   rising fees, and each approval is for what its call takes, never unlimited (RS-12, RS-15). A transaction a longer
   spike outprices waits for it, and the chain's next ones wait behind it. **Never speed one up by hand:** after a
   restart a speed-up cannot be told from a cancel, and a move whose funds moved would be dropped. To clear one stuck
   for good, cancel it (a 0-value transfer to itself on its nonce): the service drops the move and plans it afresh.

The coins, their chains and their venues (`restock/coins.mjs`, whose copies, home tokens and feeds
`test/unit/restock-coins.test.mjs` pins against `script/MainnetAddresses.sol` and `script/PythIds.sol`); every home
address was read on its chain on 2026-10-19:

| Home chain | Coins | Venue | Float |
|---|---|---|---|
| BNB Chain | XRP, ADA, LTC, DOT | PancakeSwap v3 | USDT, topped up by hand (CCTP mints no USDC there) |
| Avalanche | AVAX (WAVAX) | Uniswap v3 | USDC, by CCTP |
| Optimism | OP | Uniswap v3 | USDC, by CCTP |
| Base | AERO | Uniswap v3 | USDC, by CCTP |

Depth read on 2026-10-19, selling $3,000: LTC 88 bps, DOT 73, OP 88; selling $10,000: XRP 26, ADA 102, AVAX 19,
AERO 46. **ATOM is not served** (the owner's call of 2026-10-20): Binance-Peg ATOM, the only source its copy redeems
for, has almost no market on BNB Chain (selling $500 lost 305 bps on PancakeSwap v3, $1,000 lost 22% on v2), and
Ethereum's other ATOM tokens, Gravity Bridge's and Axelar's, are other bridges with no Uniswap market. An index holding
ATOM fills only from stock the operator adds, within its stock allowance. JUP, PYTH (Solana), SUI, APT and ALGO
wait for their chains' adapters; the service refuses to start with them in `RESTOCK_COINS`.

**Setup, once, by `OWNER`:** deploy the executor with Wormhole's Token Bridge; `setTreasury(<treasury address>)`;
`setHomeRecipient(<Wormhole chain id>, <treasury address, left-padded to 32 bytes>)` for each home chain (BNB Chain 4,
Avalanche 6, Optimism 24, Base 30): the treasury's key is the same on every EVM chain; `setTreasuryUsdcAllowance`, the
most USDC the treasury may hold off the float, what it holds counted; and `setRestockAllowance(<copy>, <amount>)` for
each coin served, the restocking you allow until you next look: what arrives through the bridge earns the keeper stock
allowance only within it (RS-1). Then send the treasury gas on each chain and Ethereum, and USDT to its
BNB Chain wallet. The service checks every pin at startup and names the call that is missing.

**What still needs a person:** gas on each chain (the service logs `gas below its minimum` and leaves that chain alone),
the BNB Chain USDT float (`top up its USDT float by hand`), the owner's allowances, the restock allowance of each coin
among them (the service logs `restock allowance ... is spent` and names the call), the keeper's `NEEDS_FILE` (`missing,
unreadable or stale`), and a transaction stuck past a fee spike for good (`still pending`: cancel it). A stolen keeper
key alone can deliver from stock only what the owner allowed, restocked coins included (CF-1, RS-1). A stolen treasury
key can bridge stock only to the pinned recipients, which are its own wallets, and hold no more USDC off the float than
the owner's figure (RS-2): with the keeper's key it can lose the working capital the owner handed both, the floats on
each chain and the stock, and nothing beyond it.

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | required | Ethereum JSON-RPC. |
| `EXECUTOR` | required | The `KeeperExecutor` this service restocks. |
| `TREASURY_KEY` | required | The treasury's key (32-byte hex), pinned by `setTreasury`; also its key on each EVM home chain. Never the keeper's. |
| `PYTH_API_KEY` | required | Hermes' API key. |
| `HERMES_URL` | `https://pyth.dourolabs.app/hermes` | |
| `NEEDS_FILE` | required | The keeper's `NEEDS_FILE`, which the keeper must be set to write: missing or stale, nothing moves (RS-8). |
| `JOURNAL_FILE` | required | Where the service keeps its moves, on the disk before each is sent. Keep it: it is what a restart resumes from, and the service refuses to start on one empty or unreadable (RS-13). |
| `RESTOCK_COINS` | every coin | Comma-separated symbols to serve. |
| `BSC_RPC_URL`, `AVALANCHE_RPC_URL`, `OPTIMISM_RPC_URL`, `BASE_RPC_URL` | required for their coins | Each home chain's JSON-RPC. |
| `RESTOCK_BUFFER_BPS` | `1000` | How far above the needs a buy fills. |
| `RESTOCK_MIN_USD` | `200` | Smallest trade or transfer worth its fees. |
| `RESTOCK_DAILY_USD` | `20000` | Most the buys of a day may cost; the last one is cut to what is left (RS-7). |
| `RESTOCK_KEEP_USD` | `1000` | Stock of each coin kept in the executor when nobody needs it. |
| `RESTOCK_MAX_TRANSFER_USD` | `25000` | Largest single trade or cross-chain transfer, Wormhole's or CCTP's; at least `RESTOCK_MIN_USD`. Draws and repayments, between the executor and the treasury, are bounded by the owner's figure instead. |
| `RESTOCK_FLOAT_TARGET_USD` | `5000` | Float kept on each home chain. |
| `RESTOCK_TREASURY_TARGET_USD` | `10000` | USDC kept by the treasury on Ethereum. |
| `ROUTE_MAX_LOSS_BPS` | `100` | Most a trade may lose against Pyth. |
| `RESTOCK_INTERVAL_SECONDS` | `60` | How often it looks. |

## Running

From the repo root:

    forge build                          # the hub and factory ABIs come from abi/, the executor's from keeper/out
    forge build --root keeper
    # deploy src/KeeperExecutor.sol: (SwapRouter02, USDC, FACTORY, MintRequests, Wormhole's Token Bridge, OWNER, keeper
    # address); send it a USDC float

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
| `NEEDS_FILE` | none | Where to write what fills are short of, for the restock service. |

## Tests

- `forge test --root keeper` (from the repo root): the executor against the real hub, factory and request escrow with
  mocks, request fills included.
- `node --test keeper/test/unit/*.test.mjs`: arithmetic, settings, the route search, the request filter and scan, the
  back-offs, the Hermes client and the transaction tracker; the needs board; and the restock's coin table (pinned
  against `script/MainnetAddresses.sol` and `script/PythIds.sol`), planner, journal, settings and attestation clients;
  no install.
- `forge test --root keeper` with `MAINNET_RPC_URL` also runs `test/KeeperExecutor.fork.t.sol`: `redeemBridged` and
  `bridgeOut` against Wormhole's real Token Bridge, with a test guardian installed in Wormhole's core on the fork.
- `MAINNET_RPC_URL=<archive> npm run e2e` (in `keeper/`): an anvil fork with the real Pyth contract verifying updates
  this test signs, real pools and tokens, and `keeper.mjs` as its own process. It covers a start held back by a quiet
  feed and by missing stock, an index never started, fills only once profitable, stock kept and delivered, a two-hop
  buy, and a fill mined a slot late reverting early and being sent again. On a cold RPC cache a start check can outlast
  the keeper's 15-second RPC timeout and the test then fails on timing; `FORK_BLOCK` at a block already run keeps the
  cache warm.
- `MAINNET_RPC_URL=<archive> npm run e2e:restock` (in `keeper/`): anvil forks of Ethereum, BNB Chain, Base, Optimism and
  Avalanche with the real Wormhole bridges and cores, CCTP V2 contracts, pools and tokens; a test guardian and a test
  attester installed on each fork; fake Wormholescan, Iris and Hermes; and `restock.mjs` as its own process, round by
  round. For each chain's coin: bought, bridged in and redeemed for a need, then bridged out and sold once the need is
  gone; on the CCTP chains the float starts empty, so the treasury draws, funds by CCTP, sweeps back and repays; after
  each chain's flows no allowance is left standing (RS-12). Then a move signed but never broadcast is resumed once, and
  one whose nonce went elsewhere is kept at the first look and dropped a minute later (RS-5). All four chains passed on
  2026-10-20 (75 checks), before the review of 2026-10-25; after it, Base passed its 29 on 2026-10-25, the other three
  not yet run again.
