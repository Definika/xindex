# Xindex keeper

Starts and fills `WeightedHub` auctions on Ethereum, and fills `MintRequests` requests, through its own executor,
`src/KeeperExecutor.sol`. It holds **no role in the protocol**: starting a rebalance, filling an auction and filling a
request are open to anyone, and anyone may run a keeper. Its key is the keeper's own hot key, not the owner's or the
guardian's. A second process, the restock service (`restock.mjs`, see [Restock](#restock)), keeps the executor stocked
with the coins Ethereum has only as Wormhole copies, buying them on their home chains. A third, the invariant checker
(`invariants.mjs`, see [Invariant checker](#invariant-checker)), holds no key and watches that the contracts' properties
hold on chain.

## What it does

No issue, redeem or claim reads a price. A fill names the units the index settles at, and the index accepts them
when every leg is inside its unit caps and a weighted gain in units clears the auction's bar, which starts at a half
and halves every twelve minutes for four hours (`design/2026-11-10-oracle-free-rebalance.md`). On a factory with an
oracle the index then checks the fill against Pyth's prices of the last minute, a check that can only refuse
(`design/2026-11-22-pyth-check.md`); the keeper's fill posts those prices itself, below. So the keeper prices its
own trades, off chain: Pyth's prices from Hermes, each kept only where Pyth's contract confirms the signed update that
carries it, through the keeper's own catalogue of each coin's Pyth id (`bot/price-ids.mjs`, and `PRICE_IDS`).

Every block L, with T = L's timestamp + 12 (the one block a fill sent now can land in):

1. **Fills.** For each open auction on an index with shares worth at least `MIN_TVL_USD` (valued once per auction and
   again every 25 blocks, with one Hermes request for all of them), the richest 8 first:
   - It reads the index's recorded units, its weights and the bar at T, and names the units to settle at
     (`bot/units.mjs`): for every leg it can value, `λ · weight / price`, with `λ` the smallest that clears the bar.
     That is the fill that leaves the index the least value at the keeper's prices among those the index accepts, so
     it is the keeper's best at that second. What it names is checked in the hub's own arithmetic, ported word for
     word and replayed against the contracts' vectors, before anything is asked of the chain.
   - When the owner or guardian posted a quote with the proposal (`rebalanceQuote()`), the units named must hold it
     too: the bot gives the index as much more as the quote asks, and names nothing it would have to give away.
   - On a factory with an oracle (`PRICES()` on the index is not zero) the fill must also hold Pyth's check: what
     it brings in, at Pyth's prices, covers what it takes less a tolerance that rises from nothing to 2% over the
     auction. A price reaches Pyth's contract only when someone posts it, so the fill carries Pyth's signed update
     for the feeds the factory names (`priceFeedOf`) and the executor posts it first, in the same transaction, for
     Pyth's fee, which the transaction carries exactly (`WrongPythFee`) and which is counted with the gas. Before
     naming units the bot asks the hub's reader what each leg is worth once that update is posted, for a leg that
     leaves and for one that arrives (one `eth_call` through Multicall3: the update, then the questions), and names
     only units that hold the check at the tolerance of second T (`oracleOf`, replayed against the contracts' 85
     oracle vectors). The hub's preview is asked the same way, after the update. A leg without a feed, or one the
     reader cannot value even then, keeps its units. Anyone can post a newer Pyth update ahead of the fill, at prices
     a hair off the ones simulated, so the bot names its units at the tolerance of twelve minutes earlier
     (`ORACLE_LAG`), a tenth of a percent inside the check; a fill that reverts all the same counts as a strike
     against its auction, as any reverted fill does, and is simulated again once its back-off ends. The index's
     weights are read every round: its creator may change them behind a notice. The step that builds the update
     and reads the values is `bot/pyth.mjs`, tested on its own (`test/unit/pyth.test.mjs`); the calls around it
     run in the end-to-end test, against Pyth's real contract on a mainnet fork (45 of 45 on 2026-11-24).
   - A leg it cannot value keeps its units: a kept leg, a coin outside the catalogue, a share-priced Ondo leg
     (RX-2), and a coin whose price is not the signed one, is older than a minute or carries a confidence interval
     wider than 2% (RX-1, RX-9). A leg within `TRADE_COST_BPS` of its weight is not traded for its own sake.
   - It previews the settlement those units give and simulates the executor's whole fill exactly as block L+1 would
     run it (`eth_call` with block overrides), with the routes it quoted and the executor's stock. Profit = the USDC
     float's change + the stock's change valued at the keeper's prices − gas.
   - It sends the most profitable fill whose profit reaches `MIN_PROFIT_USD`, with a USDC floor no lower than that
     decision needs (a sandwich can take nothing below it), `maxAmountsIn` and the index's supply a hair above the
     preview's, and a deadline of T: a fill mined late, or after an issue that grew the supply past its bound,
     reverts in its first lines. The bar only falls, so units named for T clear it in any later block too.
   - A fill that does not pay yet waits: as the bar falls, clearing it costs less, and a fill pays once the bar is
     below the index's distance from its weights by more than the routes and gas cost. The first keeper it pays
     fills it, which is what makes the price fair; a lone keeper could wait for the last second and keep the
     distance. An index on its weights never pays: clearing any bar from there is a gift.
   - A fill that reverts on chain all the same, after its simulation passed, holds its auction off for 5 blocks, then
     10, and after the third this bot leaves that auction until the strikes lapse, 300 blocks after the last (RX-26);
     its routes are searched again. A fill mined after the block it was sent for reverts on its own deadline, which
     says nothing of the auction, and is no strike (RZ-15); one whose receipt the node could not be asked for stays
     in flight until it can (RZ-6). The chosen fill is simulated again with the gas limit it will carry before it is
     sent (RX-21), and a fill below zero profit, which only a negative `MIN_PROFIT_USD` allows, is sent only within
     `SUBSIDY_BUDGET_USD` a day (RX-16), counted at what the fill pays if its float ends at the floor it is sent
     with, not at its simulation, and only once it has gone out (RZ-9, RZ-16). An auction the bot is backed off
     from does not take one of the 8 check slots (RX-24).
2. **Starts.** Every 25 blocks, for each index anyone may restart, it simulates the auction at its last second, where
   the bar is lowest (by overriding the hub's pending slot), and starts it only when a fill then would pay after the
   start's own gas, the index is worth `MIN_TVL_USD`, and the executor can deliver every coin that fill asks for. A
   start is a plain call: it carries no update and no ether. It is sent only after a call at the next block with its
   own gas limit passes and while the block it was priced on is still the head; a start that missed is checked again
   at the next block. The 4 richest ready indexes are simulated per round, side by side, their routes kept until the
   next (RX-34). The guardian's Safe sends its own starts, keep masks included, as plain calls too; the bot fills
   them like any other auction and names a kept leg's units unchanged.
3. **Requests.** With `FILL_REQUESTS` on and nothing else to send, the open `MintRequests` requests on the indexes it
   serves are read every 25 blocks, with each index's gate and a Hermes value of one of its shares; a request whose read
   fails is kept as it was and read again. A scan reads at most 1,000 requests, the new ones from the last id read and
   the known open ones in turn, so a stranger's one-unit requests delay the reading of the others by a few scans and
   no more (RZ-10). A request is skipped before any simulation when its escrow at Pyth is worth
   less than its limit plus `MIN_PROFIT_USD`, since no fill of it could pay (RY-8), or when it is a mint on an index
   whose gate would not issue to the executor. Of the rest, the 8
   largest in dollars are simulated per block, at most 4 of them on one side while the other side has requests, and a
   request whose simulation reverts waits 2, 4, 8... blocks, at most 200, before the next; one whose fill reverts on
   chain waits 5, then 10, and is left after the third. Each is simulated as block L+1 would fill it. A mint request is
   filled with exactly its limit in shares: the basket for them comes from stock and the routes, is issued to the
   executor and delivered, and the escrowed stablecoin is taken, USDT sold into USDC along a quoted route. A redeem
   request is paid exactly its limit in its stablecoin, USDT bought with USDC: the escrowed shares are redeemed and the
   basket sold along the routes, a coin with no route kept as stock. Profit and the floor are priced as a fill's, and
   the most profitable request whose profit reaches `MIN_PROFIT_USD` is sent, never below zero: requests are not
   subsidised (RX-16). The surplus over a limit is the filler's, which is why the app suggests limits.
   - Every price a request fill is valued at is Hermes' latest, kept only where Pyth's own contract, parsing the
     signed update Hermes served with it, returns the same price, and only when it was published in the last minute
     with a confidence interval within 2% (RX-1, RX-9). A closed US-hours feed's last close therefore prices
     nothing, and a request on an index holding a coin outside the catalogue is not filled.
   - The fill names the index's `rebalanceNonce` it was simulated at, and reverts `StaleRebalanceNonce` if a settlement
     landed first (RX-4). Each routed leg carries its quote plus `SLIPPAGE_BPS` as its own bound, and so does the
     stablecoin leg, so a pool pushed ahead of the fill stops it at that leg (RX-10).
   - A fill that reverts on chain strikes the request, its requester and its index, so new request ids do not start
     over (RX-10); a request a check keeps declining without a revert is checked again 2, 4, 8... blocks later, at most
     200 (RX-24).
   - **Batches** (`fillBatch`, `design/2026-11-11-batch-fills.md`). Before the single fills, the open requests of
     each index in each stablecoin are planned as one fill, up to 16 of them: every request at exactly its limit, the
     shares the redeem requests escrowed passed to the mint requests, and one basket bought or sold for the
     difference. A request joins a batch when its escrow is worth at least its limit; it need not pay
     `MIN_PROFIT_USD` alone, since the batch as a whole must, so a request too small to pay for a basket of its own
     is filled with others. A further request costs a batch about 56k gas, whatever the index holds. A request in a
     batch that pays is not checked alone; the most profitable fill of the block, batch or single, is sent. Each
     request is read again at the batch's own block, and one closed since the scan is dropped. When a batch's
     simulation reverts, each of its requests is checked alone that block, so the one whose own fill reverts is found
     and backed off and the batch forms again without it. A batch that reverts on chain strikes each of its
     requests, each requester and the index once.
4. **One transaction in flight.** A transaction that misses its block is replaced on the same nonce by a 0-value
   transfer to itself, its fees raised each block, never above `MAX_FEE_GWEI` and at most 10 times, until something on
   that nonce is mined; after the tenth it only waits, and logs it. A nonce left pending by an earlier run is cleared
   the same way at startup, at most 4 of them, and so is one whose send failed with its outcome unknown; a pending
   nonce the RPC reports beyond those is logged and left alone, so an RPC cannot make the bot cancel every block.
   Nothing is sent over such a nonce either: the bot sends again once it is mined, and says once why it waits, where a
   fill signed on it replaced it or was refused as underpriced block after block (RZ-8).

## Inventory

The executor swaps through Uniswap V3 (SwapRouter02) along a route per coin, chosen for each auction by quoting every
`token→USDC` and `token→WETH→USDC` pool at the leg's own size; a route losing more than `ROUTE_MAX_LOSS_BPS` against
Pyth is not used. A coin without a usable route (Wormhole copies, Ondo stocks, Tether Gold) is served from the
executor's **stock**: a coin the index sells is kept, and a coin it needs is delivered from stock, which the restock
service keeps filled for the Wormhole copies it serves ([Restock](#restock)), and the operator for the rest. A coin
leaves stock only within the **stock allowance** `OWNER` sets for it (`setStockAllowance(token, amount)`), and what the
restock service bridges in adds to, which every delivery from stock spends; with none, nothing is served from stock.
With `NEEDS_FILE` set, the keeper writes there every coin a fill, a start or a request delivers from stock, with the
whole of it that fill needs, for the restock service to bring in and then keep: a coin stays on the board while its
fill waits, covered or not, so stock that has just arrived is not sent home before the fill uses it (RZ-3). The board
is dated by the keeper's last block that looked at everything it reports on, not by its last write: while the
keeper's blocks fail, or stop behind a transaction of its own, the date stands still, and after fifteen minutes the
restock reads the board as unknown and moves no coin, where a board dated by its last write read as "nothing is
needed" and sent the stock home (CA-R2-02). A request is on the board once, under its batch while it is in one
(CA-M8); one short of stock is checked again within ten minutes, so its need does not lapse while the coins are on
their way; and one its index has settled a rebalance since asks for nothing, since it can never be filled. Only a
fill that could pay `MIN_PROFIT_USD` at its best price is on the board (RY-8): an auction's, when its settlement at
its last second, where the bar is lowest, sends out that much more than it takes in at the keeper's prices, before
routes and gas; a request's,
when its escrow is worth that much more than its limit. Stock brought in for a fill that is never made would only
cost the restock its swaps and bridge fees, there and back. A holder who makes a paying auction and leaves before its
fill can still cause that, within the restock's daily and per-coin bounds.

**Ahead of the auction.** The board carries an auction before it opens, so the stock its fill wants has arrived by
then (2026-11-18). Every 25 blocks, beside the start checks, the keeper looks at the richest four indexes whose
auction is coming: a proposal waiting out its two-hour notice, and an index it may start within
`PRESTOCK_LEAD_SECONDS`, a day by default, or one past its interval that a cancel or an expiry holds off strangers. Each
is simulated as a start is, at its auction's last second, where the bar is lowest, and what stock would serve goes on
the board under the key its fill will carry, if that fill could pay `MIN_PROFIT_USD` (RY-8). So one entry stands from
a day before the start to the fill, refreshed every five minutes, where it once stood only while the index could be
started and while its auction was open: during the notice, which no check read, it lapsed after `NEEDS_MAX_AGE_SECONDS`
and the restock could send the stock home before the auction opened. An index on its weights names no units that clear
the bar and puts nothing on the board, so stock is brought in for the drift there is, at the keeper's prices of the
moment, and the restock's buffer (`RESTOCK_BUFFER_BPS`) covers what the market does by the fill. A proposal's quote is
left out of the simulation, as the restock's question about any fill leaves it out. Nothing is sent: the start is
still sent only once the index can be started and the fill pays.

**Stock carries the coin's price.** Every coin the executor holds, kept from a fill, brought in ahead of an auction or
left by the restock's keep, rises and falls with that coin until a fill delivers it or the restock sells it at home.
That risk is the operator's, as the share stock's is, and nothing hedges it: at launch sizes it is accepted (the owner's
call of 2026-11-18). What bounds it is what bounds the stock: the restock buys only for the needs on the board and their
buffer, within the owner's restock allowance per coin and `RESTOCK_DAILY_USD`, and keeps at most `RESTOCK_KEEP_USD` of
a coin nobody needs; a shorter `PRESTOCK_LEAD_SECONDS` holds it for less time. A hedge, such as a short position in the coin sized to the stock, is
for when the stock grows past what the operator will carry.

**Share stock.** An index's own shares are stock too. With `SHARE_STOCK_USD` above zero, a batch keeps the shares
its sellers bring, up to that many dollars per index, instead of redeeming them, and a later batch delivers them to
buyers without a basket: a cross between requests made at different times, and the one way a single small request is
filled at once. Shares leave that stock only within the stock allowance `OWNER` sets for the index's address
(`setStockAllowance(index, shares)`), which every batch that hands over more shares than it brings in spends; shares
the executor acquires earn no allowance of their own. The bot counts a share coming in at what redeeming it would
bring, less `SLIPPAGE_BPS`, and a share going out at what issuing it again would cost, plus `SLIPPAGE_BPS`. Shares
held move with the index: that risk is the operator's, and the default holds none. The bot builds no stock ahead of
demand; an operator who wants some sends the executor shares. An index holding a share-priced Ondo leg has shares the
bot cannot value, so it keeps and delivers none of them.

The 343 Ondo legs priced at their share's feed (every listed Ondo stock and ETF but the 9 Pyth prices directly, NVDA,
AAPL, GOOGL, MSFT, TSLA, HOOD, MSTR, COIN and CRCL; `SHARE_PRICED_IDS` in `bot/config.mjs`) are worth sValue
shares, which the bot cannot read. Keep
their stock allowance at **zero**: the bot refuses any fill that would deliver them from stock, and counts any it keeps
as worth nothing (RX-2). After a split or a reverse split the share's feed is off by the ratio. The bot logs `restock <coins>` and does not start or fill an
auction its usable stock (the lower of the balance and the allowance) cannot cover. Usable stock comes first for a
routed coin too; only the rest is bought. The executor's address must be able to hold and send every coin it stocks.

## Keys and risk

- `OWNER`, a cold key, withdraws float and stock, rotates the keeper (`setKeeper`), sets each coin's stock allowance
  (`setStockAllowance`) and the **request allowance** (`setRequestUsdcAllowance`): how much of the USDC float request
  fills may still turn into anything else, which every request fill ending with less USDC than it started spends
  (RX-1, RX-9). With none, no request fill may cost the float anything. Keep it off the bot's machine.
- `keeper`, the bot's hot key, can only `fill`, `fillMint`, `fillRedeem` and `fillBatch`, and only for an index the factory
  created, through the request escrow the executor was built with. Only a wallet the factory's owner
  approved creates a factory index (`setApprovedCreator`), so a thief cannot make one of its own. But anyone can hold
  the shares of an index that exists, or request a mint of one, so that check does not keep the stock from an index the
  key's thief holds (CF-1):
  what bounds the stock a stolen key can move is the allowance `OWNER` left, which a request fill spends like an
  auction fill, so keep each allowance to what the next fills need. A batch spends the share stock's allowance on a
  count of the shares it is to hand over and bring in, made before anything moves; after its last step that count is
  held against the shares the executor holds, and the batch reverts `ShareStockShort` if more left than was spent.
  Until 2026-11-21 nothing compared the two, and a batch that named a redeem request and paid it nothing, which is
  never filled, took the whole share stock with the allowance at zero (CA-H1). Every fill also carries the hash of
  the request, or requests, its keeper priced, and stops if another stands behind an id, as after a re-org (CA-M6). The key can also trade the USDC float badly within
  the floor it sets itself: keep the float to what fills need, and the key's ETH to a few days of gas.
- **Kept coins are adverse selection.** A coin no route takes is kept as stock, and the worse its pools pay against
  Pyth, the surer no route takes it. The bot values a kept coin at the lower of Pyth and the best quote its route
  search found, for at least the amount kept and at most 25 blocks old, so a coin trading under its feed (a depegged
  Wormhole or Binance-Peg copy) counts at what its pools pay. A coin whose pools exist but quote nothing, their sell
  side emptied as a depegged copy's is, counts as nothing; a quote the RPC failed to answer fails the check rather
  than counting. Only a coin with no pool at all counts at Pyth: that is the Wormhole copies', Ondo stocks' and Tether
  Gold's case, and a bridge incident or a copy trading under its coin's feed then turns float into a coin worth less
  than the bot booked. Only a wallet the factory's owner approved creates an index, so a stranger cannot build one to
  make the bot buy its other legs with the float; an index an approved creator built still can, up to the auction's
  turnover cap each interval, and a redeem request up to the request allowance. Keep the float and that
  allowance to what fills need, and serve such coins (`INDEXES`) only where the operator has a market for them. A kept
  coin's quote is the block's own (RX-13), and a chosen route is quoted again whenever its leg grows, so a purchase's
  bound covers the larger amount (RZ-11); the pools a coin can use are read again every 25 blocks, so one created
  after a depeg counts (RX-17), and a pool nobody initialized is no market, so it cannot zero a coin's value (RX-14).
  An initialized pool whose liquidity is gone still quotes nothing, as XS-5 intends.
- Fills go through the public mempool: anyone can see a fill and the units it names before it lands. The floor bounds
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
   stops the service rather than starting it afresh (RS-13). One process holds the journal at a time, by a lock file
   beside it: a second, a restart overlapping the one it replaces or a `--once` run beside the service, stops at
   start, where each used to erase the other's moves (CA-M12). A transfer is settled only once the receiving side
   shows it completed, read back after the completing transaction is mined: a cancel mined on that nonce completes
   nothing (CA-M10). Redeeming and receiving are counted once by the contracts
   that do them, and a signed transfer or an attestation is stored for a move only when it is the move's own and the
   receiving chain's contract accepts it, so a wrong answer is fetched again rather than kept (RS-14). A signed move
   whose nonce another transaction took is dropped only when a look a minute after the first still finds no receipt,
   and a receipt lookup that fails is never taken for a missing receipt (RS-5). A signature that goes stale while a
   move waits is renewed: Circle is asked, at most hourly, to sign again a message whose expiry passed, and a VAA a
   replaced guardian set signed is fetched again (PD-10). A round resumes every signed move before any other step, so
   no signer builds over a transaction it may have in flight (PD-9). Each CCTP burn allows the route's standard fee from
   Iris's table, zero today, and refuses a rate over 10 bps (PD-12).
2. It reads the keeper's `NEEDS_FILE`, the executor's stock and allowances, the treasury's USDC, each home wallet's
   coins, float and gas, and Pyth's prices, kept only where Pyth's contract on Ethereum, parsing the signed update Hermes
   served with them, returns the same price (RX-9, RY-6), and plans (`restock/plan.mjs`). A board that is missing, unreadable or not
   written for 15 minutes is unknown, not empty: no coin is bought, sold or bridged until the keeper writes it again,
   where an empty one would send every coin home (RS-8).
   - a coin whose usable stock and transfers on their way fall short of the needs is bought on its home chain, up to
     the needs and `RESTOCK_BUFFER_BPS` more, counted to the wei, at least `RESTOCK_MIN_USD` of it unless the coins
     already at home cover the needs (RS-3), and bridged in. The executor's `redeemBridged` completes the transfer,
     which carries a payload so that only the executor can complete it, and adds what arrived to the coin's allowance
     as far as the owner's restock allowance for the coin goes (`setRestockAllowance`), which the credit spends
     (RS-1). A coin whose restock allowance is spent is neither bought nor brought in, and the service names the call.
     Stock the executor holds beyond its stock allowance counts as held: nothing is bought for it, and the service
     asks the owner for `setStockAllowance` instead (RZ-20). Coins at home worth less than `RESTOCK_MIN_USD` wait,
     in a round that buys, for the buy's coins, and come in with them in one transfer (RZ-21). Of a coin that is its
     home chain's own gas coin (SUI, APT, ALGO), twice the chain's gas minimum stays in the wallet, never sold or
     bridged, and the signer refuses a sale or a transfer that would leave less than the minimum (CA-M14);
   - a covered coin's coins at home first top the stock up to the needs and the buffer, as far as the restock
     allowance goes, and only the rest is sold (RS-10); stock the executor holds beyond the needs, the buffer and
     `RESTOCK_KEEP_USD`, not counting what is on its way (RS-9), is bridged out to the treasury's wallet on its home
     chain (`bridgeOut`, to the recipient `OWNER` pinned for the coin there with `setHomeRecipient`; the allowance is then capped at
     what is left), and what reaches the home wallet is sold for the float;
   - a buy short of float waits for USDC: on a chain CCTP serves, the treasury draws it from the executor
     (`drawUsdc`, within the most the owner lets it hold off the float, `setTreasuryUsdcAllowance`) and sends it
     there; float above twice `RESTOCK_FLOAT_TARGET_USD`, counted after the round's buys (RS-4), comes back, and the
     treasury repays what it holds beyond twice `RESTOCK_TREASURY_TARGET_USD` (`repayUsdc`, which lowers what it holds
     off the float, down to zero, and never raises the owner's figure: RS-2).
3. Every trade is priced against Pyth through the route search the keeper uses (`bot/routes.mjs`, on each chain's
   Uniswap V3 fork), and refused beyond `ROUTE_MAX_LOSS_BPS`; a buy too large for the pool is halved until it fits or
   falls below `RESTOCK_MIN_USD`, so a thin pool restocks in batches. Buys stop at `RESTOCK_DAILY_USD` a day, the last
   one cut to what is left of it (RS-7): the figure bounds what the buys may cost, each counted at its worth at Pyth
   and the `ROUTE_MAX_LOSS_BPS` its swap may lose on top (CA-M13), and each trade or cross-chain transfer, CCTP's sweeps included (RS-11), at
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
| BNB Chain | XRP, ADA, LTC, DOT, BNB (as WBNB): off Ethereum's list since 2026-11-13, so served only when `RESTOCK_COINS` names one | PancakeSwap v3 | USDT, topped up by hand (CCTP mints no USDC there) |
| Avalanche | AVAX (WAVAX) | Uniswap v3 | USDC, by CCTP |
| Optimism | OP: off Ethereum's list since 2026-11-21, so served only when `RESTOCK_COINS` names it | Uniswap v3 | USDC, by CCTP |
| Base | AERO | Uniswap v3 | USDC, by CCTP |

OP was not bought on 2026-11-21: with OP near $0.07, Uniswap v3's deepest OP pool on Optimism held about $35,000 of
USDC, and a purchase of $1,430 cost 4.7% over the pools' price, so no route passed `ROUTE_MAX_LOSS_BPS`, at that size
or at any the halving reached (block 159,839,933; the end-to-end test's buy step and what follows it failed for
that, 17 of its 29 checks passing). On that the owner took OP's copy off Ethereum's list the same day; it stays in
the table for a relisting once the pools deepen or the restock is given another venue there. Base and Avalanche
passed the same test that day, 29 of 29 each.

Depth read on 2026-10-19, selling $3,000: LTC 88 bps, DOT 73, OP 88; selling $10,000: XRP 26, ADA 102, AVAX 19,
AERO 46. **ATOM is not served** (the owner's call of 2026-10-20): Binance-Peg ATOM, the only source its copy redeems
for, has almost no market on BNB Chain (selling $500 lost 305 bps on PancakeSwap v3, $1,000 lost 22% on v2), and
Ethereum's other ATOM tokens, Gravity Bridge's and Axelar's, are other bridges with no Uniswap market. An index holding
ATOM fills only from stock the operator adds, within its stock allowance.

**JUP and PYTH (Solana), SUI, APT and ALGO** (opt-in, named in `RESTOCK_COINS`; `design/2026-11-01-non-evm-restock.md`).
None of the five is on Ethereum's list since 2026-11-18 (the owner's call,
`design/2026-11-18-bridged-coins-in-a-rebalance.md`): their signers have never run end to end, and with no Ethereum
pool an index holding one could rebalance only from stock they bring in. The code stays for a relisting once a run
has proven it. Each chain's libraries and key live in a process of their own, its signer (`restock/solana/`, `restock/sui/`,
`restock/aptos/`, `restock/algorand/`, each with its own `package.json` and lockfile: run `npm ci --ignore-scripts` in
each one served),
which the service starts with an environment naming only that chain's RPC, its key and its venue's key, never the
treasury's (`signer-home.mjs`). Bridging goes through Wormhole's own SDK, the float through CCTP V2 (Circle's programs
on Solana, its scripts on Sui and Aptos; Algorand has no CCTP, so its USDC float is topped up by hand, as BNB Chain's
is), and swaps through Jupiter's Swap V2 (Solana), Cetus's aggregator (Sui), Panora (Aptos) and Tinyman v2's USDC/ALGO
pool (Algorand), each with its on-chain minimum at the plan's floor or above. A signer builds and signs each move and
first checks it by simulation: the wallet's coins may move only as the move says, and on Solana no delegate or close
authority may be left on its token accounts and a swap may call only Jupiter's program. The service journals the signed
move before asking the signer to send it, has it sent again while it may still land, and drops it once it cannot:
Solana's blockhash expired at finalized height, Sui's gas coin moved without it or its epoch ended, Aptos's sequence
number passed or its expiry reached, Algorand's last valid round passed. Sui's, Aptos's and Algorand's signers keep one
transaction in flight at a time, and re-send by themselves only the steps that complete a move. Solana's bridge pays a
token account, so the executor pins, for JUP and PYTH, the wallet's associated token account for each mint; Sui's,
Aptos's and Algorand's pay the wallet itself. The service prints each missing pin at startup. Each wallet needs its
chain's gas coin, and on Solana the rent of the accounts its moves open, which a burn's event account returns five days
on.

**Setup, once, by `OWNER`:** deploy the executor with Wormhole's Token Bridge; `setTreasury(<treasury address>)`;
`setHomeRecipient(<Wormhole chain id>, <copy>, <treasury address, left-padded to 32 bytes>)` for each coin served (BNB
Chain 4: XRP, ADA, LTC, DOT, BNB; Avalanche 6: AVAX; Optimism 24: OP; Base 30: AERO): the treasury's key is the same on
every EVM chain, and the executor pins a recipient per coin because Solana's bridge pays a token account per mint; `setTreasuryUsdcAllowance`, the
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
| `JOURNAL_FILE` | required | Where the service keeps its moves, on the disk before each is sent. Keep it: it is what a restart resumes from, and the service refuses to start on one empty or unreadable (RS-13), or held by another running process (`<file>.lock`, CA-M12). |
| `RESTOCK_COINS` | every coin | Comma-separated symbols to serve. |
| `BSC_RPC_URL`, `AVALANCHE_RPC_URL`, `OPTIMISM_RPC_URL`, `BASE_RPC_URL` | required for their coins | Each home chain's JSON-RPC. |
| `SOLANA_RPC_URL`, `SOLANA_KEY` | required for JUP, PYTH | Solana's JSON-RPC, and the service's Solana wallet, its 64-byte secret key in base58; both go to the signer alone. The RPC must keep transaction history: a move whose blockhash expired is dropped only on the word of a node caught up to the finalized slot that keeps the slots since it was built, and stays signed, reported unknown, otherwise (PD-8). A node that caps the accounts a simulation returns, as the public one does at 3, is asked in chunks (PD-1). |
| `JUPITER_API_KEY` | required for JUP, PYTH | Jupiter's Swap API key (its portal), which every Swap V2 call needs. |
| `JUPITER_URL`, `JUPITER_PROGRAMS`, `SOLANA_MAX_UNIT_PRICE` | `https://api.jup.ag`, none, `1000000` | Jupiter's API; more Jupiter program ids a swap may call; the most micro-lamports per compute unit a transaction bids. |
| `SUI_RPC_URL`, `SUI_KEY` | required for SUI | A Sui gRPC fullnode (`https://fullnode.mainnet.sui.io:443`) and the wallet's `suiprivkey1...` key; both go to the Sui signer alone. |
| `APTOS_RPC_URL`, `APTOS_KEY` | required for APT | An Aptos fullnode's REST API, through `/v1` (`https://api.mainnet.aptoslabs.com/v1`), and the wallet's 32-byte Ed25519 key in hex. A move whose sequence number was used is dropped only by a node at or past that version that keeps the versions since it was built (PD-4). |
| `PANORA_API_KEY`, `PANORA_URL` | required for APT, `https://api.panora.exchange` | Panora's API key (its docs publish a public one) and its API. |
| `ALGORAND_ALGOD_URL`, `ALGORAND_MNEMONIC` | required for ALGO | An algod (`https://mainnet-api.algonode.cloud`) and the wallet's 25-word mnemonic; the wallet must hold USDC (asset 31566704), opted in. |
| `ALGORAND_INDEXER_URL` | `https://mainnet-idx.algonode.cloud` | The indexer that confirms a transaction algod no longer remembers (1000 rounds). |
| `RESTOCK_BUFFER_BPS` | `1000` | How far above the needs a buy fills. |
| `RESTOCK_MIN_USD` | `200` | Smallest trade or transfer worth its fees. |
| `RESTOCK_DAILY_USD` | `20000` | Most the buys of a day may cost, each one's loss bound included (CA-M13), gas aside; the last one is cut to what is left (RS-7). |
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
    # address), each the chain's own from bot/config.mjs's CHAINS; send it a USDC float

Then in `keeper/`:

    npm install
    RPC_URL=... KEEPER_KEY=... FACTORY=... EXECUTOR=... PYTH_API_KEY=... npm start

The RPC must honour `eth_call` block overrides (Tenderly, publicnode and geth do; the bot checks at startup).

**On BNB Chain and Base** (`CHAIN_ID=56` or `8453`, since 2026-11-24) the same bot runs, one process and one
executor per chain, each under its own keeper key and with its own float. What differs, all from the chain's entry in
`bot/config.mjs`:

- **Prices.** A token's Pyth id is its feed as the factory records it (`priceFeedOf`), the very feed its hubs check a
  fill against, not a catalogue of the bot's. Only a token's own price (`FeedKind.Token`) is valued: a multiplier
  token's feed (Coinbase's stock tokens on Base) prices a share the bot cannot turn into the token's value, so such a
  leg keeps its units, as a share-priced Ondo leg does (RX-2). `PRICE_IDS` still sets or overrides a token's id.
- **Timing.** Blocks come every 450 ms on BNB Chain and 200 ms on Base (measured 2026-11-24), so a fill cannot aim at
  the next block alone. It is priced at the earliest second it can land, which is where the bar is highest and Pyth's
  tolerance narrowest, and carries a deadline three seconds on; it is replaced only once those seconds' blocks have
  passed. The windows the bot keeps in blocks (its start and request rounds, re-quotes, back-offs) are Ethereum's
  twelve-second blocks scaled to the chain, so they last the same time.
- **Money.** BNB Chain's USDC and USDT have eighteen decimals; the bot reads both stablecoins' decimals from the
  request escrow at startup and refuses a float whose decimals are not the table's. Gas is valued at the gas coin's
  price, BNB's on BNB Chain, and on Base the L1 data fee is added at GasPriceOracle's upper bound for the
  transaction's size. `MAX_FEE_GWEI` and `PRIORITY_FEE_GWEI` default to 1 and 0.1 on BNB Chain, 1 and 0.01 on Base.
- **Venue.** Uniswap V3 through SwapRouter02, as on Ethereum, with the wrapped gas coin as the routing hub. PancakeSwap
  and Aerodrome, where most of those chains' depth is, are not routed: a coin Uniswap does not trade within
  `ROUTE_MAX_LOSS_BPS` is served from the executor's stock, which the operator adds there (the restock serves Ethereum
  alone).

`test/KeeperExecutor.chains.fork.t.sol` deploys the executor on each chain's real market, checks every address the
table names against the chain, and fills a real mint request through Uniswap V3 (BNB_RPC_URL, BASE_RPC_URL).

To attest a token on Solana or Sui for its Wormhole copy on Ethereum (the owner's step before a copy can be listed,
`design/2026-10-10-one-index-wormhole-legs.md`, section 2a), with the restock service's settings:

    node restock.mjs --attest solana <mint>      # or: --attest sui <coin type>

The chain's signer attests the token, after a simulation in which no token of its wallet moves. The service then
waits for the guardians' signature, checks it on Ethereum's core, and creates the copy from the treasury, or updates
an existing copy's name and symbol (`updateWrapped`, as RAY's needs). It follows Wormhole's SDK route, the one Wormhole's
docs now give; legacy Portal's own interface closed on 2026-06-30 (PD-7).

Before Glamsterdam reaches mainnet: under EIP-8037 a transaction's state gas comes from a reservoir the GAS opcode does
not show, so the executor's `gasUsed` undercounts fills that write new slots. The bot already simulates every fill it
sends with that fill's own gas limit (RX-21), which catches the shortfall; `TX_GAS_CAP` in `bot/config.mjs` then needs
raising to what EIP-8037 allows (RX-36).

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | required | The JSON-RPC of the chain `CHAIN_ID` names. |
| `RPC_TIMEOUT_MS` | `15000` | How long one RPC request may take before the round it is in fails; longer for a slow but sound RPC, as the end-to-end test's cold fork is. |
| `KEEPER_KEY` | required | The executor's keeper key (32-byte hex). |
| `FACTORY` | required | The `WeightedIndexFactory`. |
| `EXECUTOR` | required | This bot's `KeeperExecutor`. |
| `PYTH_API_KEY` | required | Hermes' API key, sent as `Authorization: Bearer`: the keeper's own price source. No contract reads a price. |
| `HERMES_URL` | `https://pyth.dourolabs.app/hermes` | Hermes since 2026-08-26. |
| `PRICE_IDS` | none | `token=id` pairs, comma-separated: Pyth ids for coins the catalogue (`bot/price-ids.mjs`, the 414 listed coins) does not hold, a testnet's for instance, or another feed for one it does. A coin without an id is left alone. |
| `TRADE_COST_BPS` | `30` | What trading a leg is taken to cost when the bot names a fill's units: a leg within this of its weight is not traded for its own sake. |
| `INDEXES` | every index | Comma-separated indexes to serve. Only wallets the factory's owner approved create indexes, so the set is the team's; a list still caps the bot's work. |
| `MIN_PROFIT_USD` | `5` | Least profit a fill or a start must promise; negative is a subsidy the operator accepts, for auctions only and within `SUBSIDY_BUDGET_USD`. |
| `SUBSIDY_BUDGET_USD` | `0` | Most the auction fills sent below zero profit may cost in all over a rolling day; requests are never subsidised (RX-16). The day restarts with the process. |
| `MIN_TVL_USD` | `1000` | Smallest index the bot starts or simulates a fill for (anyone can open an empty one's). |
| `SLIPPAGE_BPS` | `30` | Room the floor leaves for the pools to move, on the volume the routes trade. |
| `SUPPLY_TOLERANCE_BPS` | `10` | How much an issue may grow the index's supply, and with it the settlement, before the fill reverts, in its first lines. It is also the griefing threshold: an issue of more than this share of the supply ahead of a fill makes it revert, though cheaply, and the bot leaves an auction after three such reverts. |
| `ROUTE_MAX_LOSS_BPS` | `100` | Most a route may lose against the keeper's price of the coin. |
| `MAX_FEE_GWEI` | `100` (`1` on BNB Chain and Base) | No transaction while the base fee and tip exceed this, and no replacement's fees above it. |
| `PRIORITY_FEE_GWEI` | `2` (`0.1` on BNB Chain, `0.01` on Base) | Tip. |
| `FILL_REQUESTS` | `1` | `1` fills `MintRequests` requests too, `0` serves auctions only. The escrow is the one the executor was built with. |
| `FILL_AUCTIONS` | `1` | `1` starts and fills auctions, `0` serves requests only, as on Sepolia, whose hub predates this keeper's start and preview. |
| `CHAIN_ID` | `1` | The chain whose market the bot trades: `1` Ethereum, `56` BNB Chain, `8453` Base, `11155111` Sepolia's test deployment (`bot/config.mjs`, `docs/deployment.md`). The bot refuses an RPC on any other chain. |
| `SHARE_STOCK_USD` | `0` | The dollars of each index's own shares the request filler aims to hold as stock: a batch keeps its sellers' shares up to this instead of redeeming them, and delivers them to buyers within the owner's stock allowance for that index. Zero keeps and delivers none. |
| `NEEDS_FILE` | none | Where to write what fills deliver from stock, for the restock service. |
| `PRESTOCK_LEAD_SECONDS` | `86400` | How long before an index may be started the stock its auction would need goes on `NEEDS_FILE`, so the restock brings it in before the auction rather than during it. Zero reports an auction only once it can be started. A proposal waiting out its notice is reported either way. |

## Invariant checker

`invariants.mjs` reads the chain and reports; it holds no key and sends nothing, so anyone can run one, and the beta
runs one beside the keeper (the logic-hardening plan's step 6). Every `POLL_SECONDS` it reads, at the latest block:

- **Every index of the factory.** The hub's invariant, exactly: each component's balance against
  `floor(totalSupply · units · scale / 1e36) + totalClaims`, on the recorded units and scale. No view returns those
  (`components()` reports at the scale an accrual now would leave), so it reads them from storage
  (`HUB_STATE_SLOTS` in `bot/config.mjs`, pinned by `test_theCheckersHubSlotsAreTheHubs`), and evaluates nothing on an
  index whose storage does not reproduce `components()`, `componentTokens()`, `lastAccrual()` and
  `pendingStreamingFee()`. Then the rebalance state machine's I1 to I4
  (`design/2026-10-29-rebalance-state-machine.md`, section 5) and the keep mask, and against its last round: the
  components never change, the units move only at a fill, the scale only shrinks, the counters never go back.
- **`MintRequests`**, when `REQUESTS` is set: its balance of each token covers the open requests' escrows.
- **The `BasketBuilder`**, when `BUILDER` is set: its balance of each token covers its users' escrows, the pairs found
  from its credit events since `FROM_BLOCK`.
- **The admin events monitors watch (RT-07):** every start, plain or with a keep mask, the quote posted with one, a
  cancel, and the factory's guardian, owner, listing, whitelist, creator-approval and fee-policy events, printed as
  notices (CA-L10).

Each finding prints as one JSON line when it is raised and when it clears, not every round; breaches and reader
findings (the checker could not trust a read) also go to `ALERT_WEBHOOK`. A component whose `balanceOf` reverts is a
notice: that is what the keep mask and `redeemSkipping` exist for. `--once` runs one round and exits 1 if anything but
a notice stands, for a cron job or CI.

What it does when it cannot see (the audit of 2026-11-21):
- A finding on something a round could not read stands until a read shows it gone: a failed snapshot, or a component
  that stops answering `balanceOf`, clears nothing (CA-M17). An escrow balance that could not be read is a reader
  finding, not a balance of zero (CA-L9).
- Requests and events are read forward, and a range is passed only once it has been read, so a failed read is made
  again next round (CA-M16). `MintRequests` and the builder are read apart from the indexes: one failing does not
  hide the others' findings.
- An alert stays queued until the webhook answers with a success, in order, and is sent again every round; a round
  the RPC could not serve is alerted once when the rounds start failing and once when they are served again (CA-M18).
- A latest block older than `MAX_HEAD_AGE_SECONDS` is a reader finding: a node that stopped following the chain
  answers every read from the same healthy block (CA-R2-14).
- It refuses to start on an RPC that serves another chain than `CHAIN_ID`, or with a `REQUESTS` or `BUILDER` that
  names another factory (CA-L12).
- Not covered: a re-org that replaces an index or a builder event already read (CA-M19). It reads the latest block,
  so run it beside a node you trust, and restart it after a deep re-org.

    npm install
    RPC_URL=... FACTORY=... REQUESTS=... BUILDER=... FROM_BLOCK=... ALERT_WEBHOOK=... npm run invariants

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | required | The JSON-RPC of the chain `CHAIN_ID` names; it must serve logs from `FROM_BLOCK` (publicnode prunes Sepolia's). |
| `FACTORY` | required | The `WeightedIndexFactory`. |
| `CHAIN_ID` | `1` | `1` Ethereum, `56` BNB Chain, `8453` Base, `11155111` Sepolia. |
| `REQUESTS` | none | `MintRequests`, whose escrows are checked when set. |
| `BUILDER` | none | The `BasketBuilder`, whose escrows are checked when set; needs `FROM_BLOCK`. |
| `FROM_BLOCK` | none | The deployment's first block: where the builder's events and the notices start. Unset, notices start now. |
| `POLL_SECONDS` | `60` | How often it reads. |
| `MAX_HEAD_AGE_SECONDS` | `180` | How old the RPC's latest block may be before the round counts as failed. |
| `LOG_CHUNK` | `10000` | The widest block range one `eth_getLogs` asks for; public BNB Chain and Base nodes may want less. |
| `ALERT_WEBHOOK` | none | A Slack or Discord incoming webhook. |

Its first run, on 2026-11-01 against Sepolia's deployment (block 12,040,646): four indexes, no finding. On an anvil fork
of it, with WETH9's balance slot of the first index set to 5 wei, the next round raised `backing` with the required
123,264,984,283,783 wei, one below the index's real balance, and `--once` exited 1.

## Tests

- `forge test --root keeper` (from the repo root): the executor against the real hub, factory and request escrow with
  mocks, request fills included.
- `node --test keeper/test/unit/*.test.mjs`: arithmetic, the units a fill names (the hub's rule, replayed against the
  contracts' own vectors in `test/vectors/settlement.json`), the price catalogue (pinned against `script/Listings.sol`,
  `script/MainnetAddresses.sol` and `script/PythIds.sol`), settings, the route search, the request filter and scan, the
  back-offs, the Hermes client and the transaction tracker; the needs board; and the restock's coin table (pinned
  against `script/MainnetAddresses.sol` and `script/PythIds.sol`), planner, journal, settings and attestation clients;
  and the invariant checker's properties and settings; no install.
- `node --test keeper/test/harness/*.test.mjs` (after `npm ci` in `keeper/` and `forge build --root keeper`): the
  request filler itself against a fake chain, each call it would send encoded with the executor's real ABI: a batch
  of requests too small to pay alone, a cross, the share stock, a request that reverts or closed since the scan, and
  a single fill. It imports viem, so CI's unit step, which installs nothing, does not run it.
- `forge test --root keeper` with `MAINNET_RPC_URL` also runs `test/KeeperExecutor.fork.t.sol`: `redeemBridged` and
  `bridgeOut` against Wormhole's real Token Bridge, with a test guardian installed in Wormhole's core on the fork.
- `MAINNET_RPC_URL=<archive> npm run e2e` (in `keeper/`): an anvil fork with real pools and tokens, the real Pyth
  contract confirming the keeper's prices against updates this test signs, and `keeper.mjs` as its own process. It
  covers plain starts, a start held back by missing stock, an index never started, fills only once the bar has fallen
  far enough to pay, stock kept and delivered, a two-hop buy, a fill mined a slot late reverting early and being sent
  again, and a guardian's keep-mask start whose fill leaves the kept coin's units alone. On a cold RPC cache a start check can outlast
  the keeper's 15-second RPC timeout and the test then fails on timing; `FORK_BLOCK` at a block already run keeps the
  cache warm.
- `MAINNET_RPC_URL=<archive> npm run e2e:restock` (in `keeper/`): anvil forks of Ethereum, BNB Chain, Base, Optimism and
  Avalanche with the real Wormhole bridges and cores, CCTP V2 contracts, pools and tokens; a test guardian and a test
  attester installed on each fork; fake Wormholescan, Iris and Hermes; and `restock.mjs` as its own process, round by
  round. For each chain's coin: bought, bridged in and redeemed for a need, then bridged out and sold once the need is
  gone; on the CCTP chains the float starts empty, so the treasury draws, funds by CCTP, sweeps back and repays; after
  each chain's flows no allowance is left standing (RS-12). Then a move signed but never broadcast is resumed once, and
  one whose nonce went elsewhere is kept at the first look and dropped a minute later (RS-5). All four chains passed on
  2026-10-20 (75 checks), before the review of 2026-10-25; after it, Base passed its 29 on 2026-10-25; and all four
  again on 2026-11-01 (94 checks), after the red teams' fixes, on Tenderly's public archive and the public defaults.
