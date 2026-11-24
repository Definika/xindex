# The restock buys Ondo's stocks through UniswapX (2026-11-24)

The owner's call that day, asked whether the keeper's restock should buy Ondo stock through UniswapX after the owner
pointed out that Ondo's tokenized assets trade there: "კეეპერში ჩააშენე" (build it into the keeper). No contract
under `src/` changed; the keeper's executor gained one entry point, and the restock service a venue.

## 1. What UniswapX is, for this

- Since 2026-06-30 Ondo's 430+ stocks and ETFs are tradable on Ethereum and BNB Chain "via Uniswap and the UniswapX
  API" (Ondo's announcement, "Tokenized Stocks Are Live on Uniswap"). UniswapX has no pools: a swapper signs an order
  (a Permit2 witness transfer), and fillers compete to settle it through a reactor contract, paying the output to the
  order's recipient and taking the input in the same transaction.
- Read on chain on 2026-11-24 (block 26,486,480, a public node): in the last 9,000 blocks UniswapX's V2 Dutch order
  reactor on Ethereum (`0x00000011F84B9aa48e5f8aA8B9897600006289Be`, whose `permit2()` is Permit2) settled ten fills
  that moved AAPLon or NVDAon, and its V3 reactor (`0x0000000015757c461808EA25Eb309638B62681cf`) none. In one of them
  a swapper paid 950 USDT and received 5.745 NVDAon, $165.3 each, and the filler minted the NVDAon it paid: Ondo's own
  desk fills these orders at its mint.
- Uniswap's docs (developers.uniswap.org, read that day): the Trading API is `https://trade-api.gateway.uniswap.org/v1`
  with an `x-api-key`; Ethereum serves UniswapX V2 orders and BNB Chain V3 ones; an order is routed through UniswapX
  when worth more than about 300 USDC or when it beats the pools by 0.2%; a smart-contract swapper is verified by
  EIP-1271. The quote and order schemas themselves were not reachable, so the service relies on two fields of a quote
  (`routing` and `quote.encodedOrder`) and posts the quote back as it came.

## 2. What the restock does

- **Which coins.** The nine Ondo stocks whose Pyth feed prices the token itself (NVDAon, AAPLon, GOOGLon, MSFTon,
  TSLAon, HOODon, MSTRon, COINon, CRCLon; `keeper/restock/coins.mjs` `LOCAL_COINS`). The keeper values only those: the
  other 343 are share-priced (`SHARE_PRICED_IDS`, RX-2), so it names no units for them and delivers none from stock,
  and stock of them would serve no fill. They are served by default once the operator sets `UNISWAP_API_KEY`.
- **The plan** (`restock/plan.mjs`). A local coin has no home chain: the treasury is its wallet and the treasury's USDC
  its float. A shortfall against the keeper's needs and their buffer, within the owner's restock allowance, is bought
  by an exact USDC spend, its worth at Pyth, for at least that worth less `ROUTE_MAX_LOSS_BPS` of the coin. The day's
  budget is charged that worth alone, since an exact spend costs no more. What the treasury holds of the coin goes into
  the executor, needed or not, when worth `RESTOCK_MIN_USD` or the cover of a shortfall. Nothing sells a local coin or
  takes it out; spare stock waits in the executor for the next need or the owner. The treasury draws from the executor
  what the orders need before they are signed, plans fundings of the home chains from what the orders leave, and
  repays nothing while an order is planned.
- **The order** (`restock/uniswapx.mjs`, `restock.mjs` `placeOrder`). The treasury asks the API for an exact-input
  quote routed through UniswapX V2. It refuses anything but a `DUTCH_V2` order and decodes the order itself
  (`restock/uniswapx-chain.mjs`). It signs only when every field its signature commits to is what the plan allows:
  - the reactor is UniswapX's V2 reactor on Ethereum, and the swapper the treasury;
  - no validation contract, and no validation data;
  - a deadline 30 seconds to 15 minutes away, and a nonce no open order has and Permit2 shows unspent;
  - the input is USDC, and its larger amount is at most the plan's;
  - one output, the coin, paid to the treasury, whose smaller amount is at least the plan's least.
- **What the signature binds.** The typed data signed is built from those checked fields, never taken from the API:
  Permit2's `PermitWitnessTransferFrom` of the input's end amount to the reactor, under the order's nonce and deadline,
  with the order as its witness, laid out as the reactor's `V2DutchOrderLib` hashes it. The reactor lets the order's
  cosigner override only to improve (a lower input, higher outputs) and set the decay's times within the deadline, and
  the decay runs between the signed start and end amounts, so the bounds hold whatever the cosigner, the API or the
  filler does. An order the API altered after the check fails its signature on chain and moves nothing.
- **The approval.** Permit2 may take exactly what the open orders and the new one may spend, set before each order;
  Permit2 moves it only with a signature of the treasury's.
- **Settling** (`restock/advance.mjs`, `restock/journal.mjs`). An order is journalled before it is posted, posted
  again until the API takes it, and done once Permit2's nonce bitmap shows its nonce spent, which only the reactor's
  settlement with the treasury's signature does: the API's word is not asked. An order not settled 15 minutes past its
  deadline, by the chain's clock, is dropped, the USDC it could have taken untouched: a filler may hold a signature the
  API refused, so nothing earlier gives it up, and 15 minutes is Ethereum's finality, after which no block that could
  still settle it is undone. While an order is open the treasury plans no other order, draw, repayment or funding.
- **The deposit.** `KeeperExecutor.depositStock(token, amount)`, treasury only, takes the coin from the treasury and
  credits what arrived, never what was asked, to the coin's stock allowance within the owner's restock allowance and
  what the stock allowance can still hold, as `redeemBridged` credits a bridged arrival (RS-1, RS-6; the two share
  `_creditRestock`). It refuses USDC, which the treasury repays instead (`NotStock`).

## 3. What it costs and what it does not bound

- The bounds of the keys are unchanged. A stolen keeper key delivers from stock only what the owner allowed (CF-1,
  RS-1). A stolen treasury key holds at most the owner's figure of USDC off the float (RS-2), which an order it signs
  spends as any of its USDC could be; a deposit takes nothing out, and the treasury still has no path that takes
  stock from the executor but the bridge to its pinned home wallets.
- A price within the loss bound is still the operator's to accept: an order fills at no worse than Pyth less
  `ROUTE_MAX_LOSS_BPS`, the bound every restock trade has.
- Ondo offers these assets to eligible users only, never US persons: the operator and the treasury must be eligible,
  which no code checks.
- A coin's feed is fresh only while Pyth publishes it, so no order is placed while that feed is quiet.
- An order of less than about 300 USDC may be routed to the pools, which the service does not sign.
- BNB Chain's UniswapX orders are V3 orders, through another reactor; the restock runs on Ethereum alone, so BNB
  Chain's Ondo stock is still the operator's to add.

## 4. Evidence

- Executor: `test/KeeperExecutor.t.sol` (`test_RS1_depositedStockEarnsAllowanceOnlyWithinTheOwnersRestockAllowance`,
  `test_aDepositOfUsdcIsRefused`, `test_aDepositCreditsWhatArrivedNotWhatWasAsked`,
  `test_RS6_aStockAllowanceAtItsMostDoesNotBlockADeposit`, `test_depositedStockServesAFillWithinItsCredit`, and the
  treasury-only check), and the restock invariant handler's deposits (`test/KeeperExecutor.invariant.t.sol`).
- Restock: `keeper/test/unit/restock-uniswapx.test.mjs` (every refusal, the typed data, the nonce bitmap, the API
  client), and the local-coin cases of `restock-plan`, `restock-journal`, `restock-advance`, `restock-config` and
  `restock-coins`. HK-03's source check counts the executor's second pull, also from its caller.
- Mutants UX1 to UX28 (`test/mutants/mutants.json`), all killed; Z5 follows the rewritten `movedOn`.
- End to end (`keeper/test/e2e/uniswapx.mjs`, `npm run e2e:uniswapx`), on an anvil fork of Ethereum near its head on
  2026-11-24 (block 26,486,575), with UniswapX's real V2 reactor, Permit2, USDC and NVDAon, the API, its cosigner and
  its filler faked: 28 of 28. The treasury drew 1,584 USDC, signed and posted an order, and the real reactor settled
  it, paying 8.7793 NVDAon for exactly the 1,584 USDC; the next rounds read it filled from Permit2 and deposited it,
  credited to the wei and spending the restock allowance by as much. A second order nobody filled was held inside the
  finality margin and dropped past it, its nonce unspent and the USDC untouched; an order paying someone else, and one
  paying half the coin, were refused with their reasons and never posted.
- Not run against Uniswap's live API, for want of a key.
