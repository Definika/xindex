# Bridged coins in a rebalance (2026-11-18)

The owner asked how an index rebalances a coin no Ethereum pool trades, the Wormhole copies above all, now that a
buyer buys the index itself rather than its coins one by one. Then: "do all this", of the steps below, and, on
learning that the Solana, Sui, Aptos and Algorand restock had never run, to take those five coins off the list.

## 1. The answer

The keeper's executor holds those coins as stock, and the restock service carries only the net through each coin's
home chain, apart from the fill. No contract changes.

- **A mint and a redeem net; a rebalance does not.** Batch fills (`design/2026-11-11-batch-fills.md`) pass a seller's
  shares to a buyer, so no coin moves, and only the difference buys a basket. A rebalance moves every index the same
  way at once: when AVAX rises against the rest, every index holding it sells AVAX. Nothing on Ethereum takes the
  other side, so the coin has to go home to be sold. No design avoids the trip; it can be kept out of the fill, and
  made rare.
- **The fill never waits on a bridge** (`keeper/README.md`, "Stock"). A copy the index sells goes into the
  executor's stock, which needs no pool; a copy the index buys is delivered from stock, within the owner's stock
  allowance. The restock buys at home, bridges in through Wormhole's Token Bridge, sends what nobody needs home to be
  sold, and moves USDC by CCTP.
- **Stock nets over time.** A copy an index sells in one rebalance serves the next mint basket, or the next
  rebalance after the coin falls. Only a trend that lasts goes home.
- **The amounts are the drift.** In a $1M index holding AVAX at 10%, AVAX rising 30% against the rest leaves the
  index selling about $27k of it. A fill takes at most a fifth of a leg's units (`MAX_TURNOVER`).
- **The holders pay the trip through the bar.** A keeper fills once the gain left covers the home market's spread
  and the bridges' fees: on 2026-10-19, selling $10k lost 19 bps on Avalanche's AVAX pool and 46 bps on AERO's, and
  $3k lost 88 bps on OP's. A copy rebalances dearer than a coin with an Ethereum pool. SOL's copy has one, and needs
  no stock.

Refused, with the reason:

- **A pool of our own for each copy.** It holds the same capital as stock, but anyone trades against it at a stale
  price, only someone who bridges can correct it, and it needs the same trip home to rebalance itself.
- **The guardian's keep mask on the copies.** The index drifts off its weights; it is for an emergency.
- **Buying on Binance.** The owner turned that down on 2026-10-19.
- **Holding the copies' coins on their home chains, as BNB Chain's deployment does.** That needs a deployment on
  Solana, Sui and Aptos; Solana's was refused (a rewrite in Rust).

## 2. Stock ahead of the auction (built)

The restock buys only for a need on the keeper's board, and the board carried an auction only while the index could
be started and while its auction was open. Two costs followed:

- A first auction waited for the restock: the keeper does not start an auction its usable stock cannot cover.
- **The notice was a gap.** For the two hours between a start and its auction's opening, no check read the index, so
  its entry lapsed after `NEEDS_MAX_AGE_SECONDS` (15 minutes). The restock could then send home, beyond its keep, the
  stock it had just brought in for that fill: RZ-3's failure, at another stage.

What the keeper does now (`keeper/keeper.mjs`, `bestCase` and `prestock`; `M.startStage`):

- Beside the start checks, every 25 blocks, the keeper takes the richest four indexes whose auction is coming:
  - a proposal in its notice, whatever the lead;
  - an index it may start within `PRESTOCK_LEAD_SECONDS`, a day by default;
  - an index past its interval that a cancel or an expiry holds off strangers.
- Each is simulated as a start is, at its auction's last second. What stock would serve goes on the board when that
  fill could pay `MIN_PROFIT_USD` (RY-8), under the key the fill will carry: the proposal's own in the notice, and
  otherwise the one a start would open.
- So one entry stands from a day before the start to the fill.
- An index on its weights names no units that clear the bar and asks for nothing, so the stock follows the drift
  there is. A proposal's quote is left out of the simulation, as `mayPay` leaves it out. Nothing is sent.
- Only a keeper that writes a board (`NEEDS_FILE`) runs these checks.

Why a lead and not a standing stock per coin, a share of what the indexes hold: a standing stock parks capital in
every copy whether an auction needs it or not, and its share is a guess. The lead brings in what the next auction
would need at the prices of the moment, a day early, and nothing for an index on its weights. A day covers the
restock's own pace: one batch crosses in well under an hour, and `RESTOCK_DAILY_USD` ($20k by default) is the day's
budget.

Tests: `startStage: ready, in its notice, startable within the lead, or none` (`keeper/test/unit/math.test.mjs`) and
`PRESTOCK_LEAD_SECONDS is a whole number of seconds...` (`keeper/test/unit/config.test.mjs`); mutants K1 to K3 in
`test/mutants/mutants.json`. The keeper's main loop has no unit harness: its end-to-end test (`keeper/test/e2e/run.mjs`)
is what runs the wiring. It now writes a board and checks it: MIX's NVDAon at the start check, through its notice,
nothing three days ahead and the next auction's half a day ahead. It passed 29 of 29 on a mainnet fork at block
26,441,062 on 2026-11-18. On the way, NVDAon turned out to have a Uniswap USDC pool since the test was written, asking
about $161 under the test's $180, so the keeper bought it and the stock scenario never ran; the test now prices it at
$100, far under its pool, so that no pool mainnet grows can undo the scenario.

## 3. The non-EVM coins leave the list

The signers for JUP and PYTH (Solana), SUI, APT and ALGO were written on 2026-11-01 from each protocol's docs and
reviewed against them (PD-1 to PD-14), but none has run end to end, nor sent a transaction
(`design/2026-11-01-non-evm-restock.md`, section 6). A local chain cannot prove them: Sui and Aptos cannot fork
mainnet, and their venues, Cetus's aggregator and Panora, cannot run on a chain of our own. Only a live run with
funded wallets can.

Their copies barely trade on Ethereum and are scarce there. Supply read on 2026-11-18: 11 JUP, 27 AERO, 445 ALGO,
6,493 APT, 20,014 SUI, 283,409 PYTH, held by whoever bridged them, with no pool selling any. So more can come only by
bridging.

The owner's call the same day: "for now, let's just remove" them. The team creates every index and tells partners
what an index can hold, so no one is offered them. They left `script/Listings.sol`, which lists 80 coins. Their
addresses stay in `MainnetAddresses` and their signers in `keeper/restock/`, for a relisting once a live run has
proven them.

What stays:
- **SOL's copy.** It trades on Uniswap V3 against WETH at the market: read the same day, 1 SOL paid $74.63 against
  OKX's $74.76, and a sale of 300 SOL ($22k) came out 0.5% worse a coin than one.
- **AVAX, OP and AERO.** The EVM restock serves them, and its end-to-end test passed (94/0, 2026-11-02).

The 26 copies still to attest meet the same bar: each needs an Ethereum pool or a restock that has run from its home
chain before it is listed.

Asked before the call, the owner weighed a token that tracks the coins' prices without holding them, which would make
rebalancing a matter of numbers. It was not taken. It needs a price feed, which "No oracle" (2026-11-10) removed, and
a counterparty to pay every gain, which makes it a derivative rather than an index. And its holder could no longer
redeem for the coins.

## 3a. How Reserve does it

Reserve's Index DTFs rebalance by Dutch auction too. Each auction runs over every pair of a token in surplus and a
token in deficit at once, its price falling from optimistic to pessimistic, and since release 4.0.0 CoW Swap's
solvers may bid in it. LCAP names MEV Capital as its execution and liquidity operator. The bidders bring the tokens
from wherever they hold them, which is what our keeper and its restock do. Reserve does not bridge inside an
auction; it picks collateral that trades where the DTF lives. LCAP, on Base, holds cbBTC and uXRP and uSOL, wrappers
that trade on Base's exchanges; its DTFs on BNB Chain hold that chain's own tokens. Our list now follows the same
rule.

## 4. The stock's price is the operator's

Stock rises and falls with its coin until a fill delivers it or the restock sells it. The owner's call: accepted at
launch sizes, with no hedge (`keeper/README.md`, "Stock carries the coin's price"). The restock's bounds bound it, and
a shorter lead holds it for less time. A hedge, a short position sized to the stock, waits until the stock grows past
what the operator will carry.
