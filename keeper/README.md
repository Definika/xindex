# Xindex keeper

Starts and fills `WeightedHub` auctions on Ethereum through its own executor, `src/KeeperExecutor.sol`. It holds **no
role in the protocol**: starting a rebalance and filling an auction are open to anyone, and anyone may run a keeper.
Its key is the keeper's own hot key, not the owner's or the guardian's.

## What it does

Every block L, with T = L's timestamp + 12 (the one block a fill sent now can land in):

1. **Fills.** For each open auction, it fetches Pyth's update for second t_L from Hermes, previews the settlement and
   simulates the executor's whole fill exactly as block L+1 would run it (`eth_call` with block overrides), with the
   routes it quoted and the executor's stock. Profit = the USDC float's change + the stock's change valued at Pyth −
   gas. It sends the most profitable fill whose profit reaches `MIN_PROFIT_USD`, with a USDC floor no lower than that
   decision needs (a sandwich can take nothing below it), `maxAmountsIn` a hair above the preview, and a deadline of T:
   a fill mined late reverts in its first lines, before Pyth's parse.
2. **Starts.** Every 25 blocks, for each index anyone may restart, it simulates the auction at its best price
   (μ = MU_MIN, by overriding the hub's pending slot) and starts it only when that would pay, every feed has published
   in the last minute (US-hours stock feeds close), the index is worth `MIN_TVL_USD`, and the executor can deliver
   every coin the auction may ask for.
3. **One transaction in flight.** A transaction that misses its block is replaced on the same nonce by a 0-value
   transfer to itself, its fees raised each block until something on that nonce is mined; a nonce left pending by an
   earlier run is cleared the same way at startup.

## Inventory

The executor swaps through Uniswap V3 (SwapRouter02) along a route per coin, chosen for each auction by quoting every
`token→USDC` and `token→WETH→USDC` pool at the leg's own size; a route losing more than `ROUTE_MAX_LOSS_BPS` against
Pyth is not used. A coin without a usable route (Wormhole copies, Ondo stocks, Tether Gold) is served from the
executor's **stock**: a coin the index sells is kept, and a coin it needs is delivered from stock, which the operator
keeps filled, for example by bridging through Wormhole's Portal and sending the tokens to the executor. The bot logs
`restock <coins>` and does not start or fill an auction its stock cannot cover. Stock comes first for a routed coin
too; only the shortfall is bought. The executor's address must be able to hold and send every coin it stocks.

## Keys and risk

- `OWNER`, a cold key, withdraws float and stock and rotates the keeper (`setKeeper`). Keep it off the bot's machine.
- `keeper`, the bot's hot key, can only `fill`, and only an index the factory created, so it cannot point the executor
  at a contract of its own to take the stock. It can still trade the USDC float badly within the floor it sets itself:
  keep the float to what fills need, and the key's ETH to a few days of gas.
- Fills go through the public mempool: anyone can see a fill and its price update before it lands. The floor bounds
  what a sandwich can take; a copier who fills first leaves this bot's transaction to revert cheaply.

## Running

From the repo root:

    forge build                          # the hub and factory ABIs come from abi/, the executor's from keeper/out
    forge build --root keeper
    # deploy src/KeeperExecutor.sol: (SwapRouter02, USDC, FACTORY, OWNER, keeper address); send it a USDC float

Then in `keeper/`:

    npm install
    RPC_URL=... KEEPER_KEY=... FACTORY=... EXECUTOR=... PYTH_API_KEY=... npm start

The RPC must honour `eth_call` block overrides (Tenderly, publicnode and geth do; the bot checks at startup).

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | required | Ethereum JSON-RPC. |
| `KEEPER_KEY` | required | The executor's keeper key (32-byte hex). |
| `FACTORY` | required | The `WeightedIndexFactory`. |
| `EXECUTOR` | required | This bot's `KeeperExecutor`. |
| `PYTH_API_KEY` | required | Hermes' API key, sent as `Authorization: Bearer`. |
| `HERMES_URL` | `https://pyth.dourolabs.app/hermes` | Hermes since 2026-08-26. |
| `INDEXES` | every index | Comma-separated indexes to serve; anyone can create indexes, so a list caps the bot's work. |
| `MIN_PROFIT_USD` | `5` | Least profit a fill or a start must promise; negative is a subsidy the operator accepts. |
| `MIN_TVL_USD` | `1000` | Smallest index the bot starts. |
| `SLIPPAGE_BPS` | `30` | Room the floor leaves for the pools to move, on the volume the routes trade. |
| `SUPPLY_TOLERANCE_BPS` | `10` | How much an issue may grow the settlement before the fill reverts. |
| `ROUTE_MAX_LOSS_BPS` | `100` | Most a route may lose against Pyth; the auction's whole edge is 200. |
| `MAX_FEE_GWEI` | `100` | No transaction while the base fee and tip exceed this. |
| `PRIORITY_FEE_GWEI` | `2` | Tip. |

## Tests

- `forge test --root keeper` (from the repo root): the executor against the real hub and factory with mocks.
- `node --test keeper/test/unit/*.test.mjs`: arithmetic, settings, the Hermes client and the transaction tracker; no install.
- `MAINNET_RPC_URL=<archive> npm run e2e` (in `keeper/`): an anvil fork with the real Pyth contract verifying updates
  this test signs, real pools and tokens, and `keeper.mjs` as its own process. It covers a start held back by a quiet
  feed and by missing stock, an index never started, fills only once profitable, stock kept and delivered, a two-hop
  buy, and a fill mined a slot late reverting early and being sent again.
