# Xindex

Xindex lets investors package a whole crypto portfolio into a single ERC-20 token. Anyone can create an index (any
name, any symbol, any mix of whitelisted tokens, each at the percentage the creator chooses), anyone can mint it with
USDC or USDT, and anyone can burn it back into USDC, USDT or any other token. Every index is a plain ERC-20, fully
backed in kind by the tokens it holds. It rebalances back to its creator's percentages at Pyth prices, through a
permissionless auction, and that settlement is the only place any contract reads a price.

**Xindex is one deployment, on Ethereum, and one index holds up to 100 coins of the top 300** (the owner's decision
of 2026-10-10, `design/2026-10-10-one-index-wormhole-legs.md`). `WeightedIndexFactory`, `WeightedHub`, `IndexZap` and
`MintRequests` hold Ethereum ERC-20s in kind: the issuer's own contract where Ethereum has one, and otherwise the copy
Wormhole's token bridge wraps from the chain that has it, priced at the coin's Pyth feed and labelled Bridged, or
Custodial when the source is a Binance-Peg coin. The list stands at 92 (`script/PythIds.sol`), 13 of them Wormhole
copies, with 34 more copies to attest; DOGE's copy left it on 2026-10-14, the owner's call. Nothing crosses a chain inside a contract: the app and the fillers bridge. The
BNB Chain deployment of 2026-10-07 was shelved on 2026-10-10 and deleted on 2026-10-13.

**Status (2026-10-13): v5, deployed nowhere yet.** The weighted index is built and reviewed twice
(`audit/2026-10-05-v5-review.md`, `audit/2026-10-07-v5-logic-review.md`); the Ethereum deployment's scripts are built,
and so is a keeper bot that starts and fills auctions and fills `MintRequests` requests (`keeper/`), which holds no
role in the protocol. Before any
mainnet: Pyth's parameter replay, a settlement on a real update from Pyth's Hermes service (which needs Pyth's API key),
and an external audit.

Earlier designs, and what each retirement record says went with them: v3 priced through Chainlink and is tagged
`v3.0.0` (`audit/2026-09-22-v3-retirement.md`); v4's market-cap index followed reference supplies through a price-free
λ auction and was deleted on 2026-10-06 (`audit/2026-10-06-v4-retirement.md`); v4's Stage B held other chains' native
coins in ownerless vaults driven by proofs of Ethereum's finality, was built in large part for eight chains, and is
tagged `stage-b-2026-10-07` and deleted (`audit/2026-10-07-stage-b-retirement.md`). `WeightedHub` keeps v4's issue,
redeem, claims and backing post-check, and the zap and `MintRequests` are unchanged.

## Product brief

> we are looking to build a marketplace called xindex for investors, where they can create their
> whole crypto portfolio in one erc-20 token.
>
> 1. users come to xindex marketplace (the web app is already built, now we have to build the smart
>    contract), they choose coins that they are investing in, create a portfolio with their own logic
>    and create their whole investing logic (portfolio) in one erc-20 token. user creates a basket and
>    after that mints it, other users should also be able to mint that created index.
> 2. user should be able to name index whatever he wants and whatever symbol he decides to use, for
>    example: SYD and things like that.
> 3. we are looking to build a decentralized product.
> 4. we use minting and burning for creating and burning index.
> 5. users should be able to trade index to other coins, for example if someone created an index and
>    then wants to swap it to usdt or btc or any other coin they should be able to do that. every
>    created index is a classical erc-20 token.
> 6. usdt/usdc input, usdt/usdc output, depends on users. users will come to marketplace and create
>    their portfolio, after that they should be able to mint it with usdt or usdc. when they burn
>    their index they should get back the coin that they minted with.
> 7. we need to find a solution for layer-1 tokens.

The history, in one paragraph each:

- **v2** (2026-09-16) added on-chain rebalancing to the market-cap methodology of the team's Numbers model
  (`index_MODEL.numbers`), uncapped or capped at 30/20, priced from Uniswap V3 pool averages.
- **v3** (2026-09-22) priced from Chainlink USD feeds and swapped through Uniswap's Universal Router, which reaches V3
  and V4 pools. `audit/2026-09-22-v3-retirement.md` records what that retired.
- **v4 Stage A** (2026-09-30) removes prices from the contracts altogether. A market-cap index whose units are
  proportional to supplies never needs to trade when prices move, because prices cancel out of the weights: it trades
  only when a supply changes. So the rule, the feeds, the capped methodology (which trades on every price move and needs
  every price) and the price gates on settlement are gone, and a rebalance is an auction whose worst case holds at any
  prices. `audit/2026-09-30-v4-stage-a-retirement.md` records which past findings that retired and where the rest are
  tested now.
- **v5** (2026-10-05) lets creators choose each coin's percentage and rebalances back to it at Pyth prices, read only
  in the settlement (`design/2026-10-05-custom-weights.md`). v4's market-cap hub and factory were deleted on 2026-10-06
  and Stage B on 2026-10-07. Since 2026-10-10 Xindex is one deployment, on Ethereum, holding other chains' coins as
  the copies Wormhole's token bridge wraps (`design/2026-10-10-one-index-wormhole-legs.md`).

## Design decisions (v5)

| Topic | Decision |
|---|---|
| Chain | Ethereum mainnet, one deployment (the owner's decision of 2026-10-10). The BNB Chain deployment was deleted on 2026-10-13; nothing crosses a chain inside a contract. |
| Composition | Constituents and weights fixed at creation, 2 to 100 per index (`MIN_COMPONENTS`, `MAX_COMPONENTS`). Weights are in basis points and sum to `TOTAL_WEIGHT` (10,000). A new list or new weights is a new index. |
| Creation | `createIndex(name, symbol, components)` with one `ComponentSpec {token, weight, units}` per component. The app derives the starting units from the weights at its own prices; each lies between `MIN_RAW_UNITS` (10,000) and `MAX_UNITS` (`(2^96 − 1) >> 10`). The factory reads no price, and the first rebalance brings an index to its weights. Every component copies its listing's Pyth price id and decimals. |
| Rebalancing | Anyone starts a rebalance once the index's own interval, 7 to 91 days chosen at creation, has passed since the last one or creation (`earliestRebalance()`), then 2 hours of notice (`REBALANCE_DELAY`), then a 24-hour auction (`AUCTION_DURATION`) in which any contract can fill. The fill reads Pyth's prices, sets each moving component's target from its weight, and moves every leg the same share of the way. The growing legs ask `μ` times their step, `μ` falling from `MU_MAX` (1.02) to `MU_MIN` (0.98). One fill sends out at most `MAX_TURNOVER` (20%) of each component's own units, and must trade at least `MIN_TRADE` (0.1%) of the moving value. |
| Prices | Pyth only, read only by the settlement and only for the moving components. One price per block: each feed's first update at or after `priceTime()`, 12 seconds (`PRICE_LAG`) before the block. Refused: a non-positive price, an exponent outside [-18, 0], a price above `MAX_PRICE`, a confidence interval wider than `MAX_CONFIDENCE` (2%). Issue, redeem and claims read none. The app values an index off chain. |
| Swaps | Uniswap's Universal Router 2.0.0 alone, V3 or V4, one venue per leg, chosen by the caller. PancakeSwap and THORChain were removed on 2026-10-14. The app offers the one-click zap only up to about 35 components (EIP-7825's 16.78M gas per transaction). |
| Fees | In shares, never in components: the creator's rate (0 to 100 bps, the creator's choice at creation) plus the platform's (0 to 25 bps, the factory's policy at creation) on every issue and every redeem. A minter's deposit backs the fee's shares on top of its own; a burner's fee is minted to the recipients out of what it burns. The recipients are read from the factory at each call: the index's creator and the platform recipient, and a referrer named at mint takes the policy's share of the platform's part. The policy starts at zero and reaches only indexes created after it is set. A streaming fee, the creator's yearly rate (0 to 500 bps) plus the platform's (0 to 100 bps, the policy at creation), accrues in shares at every issue, redeem, settlement and `accrueFees`, and shrinks every share's units by the same factor: it moves no tokens. |
| Cadence and gate | Each index fixes its rebalance interval at creation, 7 to 91 days. A gated index issues only to recipients its creator allows, until the creator opens it for good; the app does not list an index created unlisted. |
| Coins | Ethereum ERC-20s: the issuer's own contract where Ethereum has one, Bitcoin as WBTC, and otherwise the copy Wormhole's token bridge wraps from the coin's home chain, labelled Bridged (and Custodial from a Binance-Peg source). Tether Gold and Ondo's stock tokens are listed too, labelled Custodial. 93 are listed in `script/PythIds.sol`, 14 of them Wormhole copies (SOL and the 13 added on 2026-10-10), with 34 more copies to attest. |
| Stable in / out | Mint with USDC or USDT through the zap, through `MintRequests` at a limit of the requester's own, filled by anyone who holds shares, or, for a basket too wide for one transaction, through the basket builder, leg by leg over several transactions into an escrow of the minter's own. The burner chooses USDC, USDT or any other token at exit, sells leg by leg through the builder, or asks for USDC or USDT at a limit through `MintRequests`. Index tokens are fungible, so the protocol cannot know which stable a holder used. |
| Decentralization | No admin can move an index's funds, mint or burn its shares, pause or upgrade it, or set its units or weights. The owner proposes listings, which take effect after 2 days, and guardian changes, which take 7; a proposal not executed within 7 days of becoming ready expires. Owner and guardian both cancel pending listings, delist, cancel a rebalance, and start one with a keep mask or before strangers may. The guardian can cancel a change that would remove it, not one that replaces it. Ownership moves in two steps with no delay, and cannot be renounced. |
| Frozen components | If a component's issuer pauses or blacklists transfers, holders take every other component out with `redeemSkipping` and collect the frozen one later with `claim`; the guardian rebalances around it with a keep mask, which neither transfers the component nor reads its balance or its price. |

## Architecture

```
                  createIndex(name, symbol, [{token, weight, units}, ...])
   creator ──────────────────────────────────► WeightedIndexFactory ──CREATE2 clone───► WeightedHub (ERC-20)
                                               │ listings with Pyth ids               │ holds the basket
                                               │ (2-day delay), guardian,             │ issue / redeem in kind
                                               │ registry                             │ redeemSkipping / claim
                                                                                      │
   anyone ── startRebalance ────────────────────────────────────────────────────────► │ 2 hours of notice
   executor ── executeRebalance(data, priceUpdate) ─────────────────────────────────► │ fill at μ(t), with a callback
                                         Pyth ◄── parse at priceTime() ────────────── │
                                                                                      │
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                  │
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── minter (holds or issues shares)
             ◄─ shares, at least minShares ─────  (escrow)    ── the USDC ──►
```

- `WeightedHub` (`src/WeightedHub.sol`) only ever moves amounts derived from supply and units. `issue(shares)` pulls
  `ceil(shares × units_i × scale / 1e36)` of every component and mints; `redeem(shares)` burns and pushes
  `floor(shares × units_i × scale / 1e36)`, with `units_i` as recorded and `scale` the streaming fee's factor (1e18
  until a fee accrues; `components()` reports the units with it applied); `redeemSkipping` leaves chosen components as claims for the recipient. A rebalance
  is `startRebalance`, 2 hours of notice, and a 24-hour auction whose fill reads Pyth's prices and stands only if every
  component still backs the new units. Issue, redeem and claims read no price, and nothing computes an amount from a
  balance, so there is no share price to manipulate and no first-depositor attack. Share transfers to the hub itself or
  its factory are refused, since neither could move a share on (CR-I01, RT-21). Only initialized clones can issue,
  redeem or rebalance. Supports EIP-2612 `permit`.
- `WeightedIndexFactory` (`src/WeightedIndexFactory.sol`) is permissionless `createIndex`, a curated token whitelist
  in which every token carries the Pyth price id and decimals of its timelocked listing, an `Ownable2Step` owner plus a
  guardian whose replacement takes 7 days, and the registry (`isIndex`, `creatorOf`, `allIndexes`). Indexes are
  EIP-1167 clones deployed with CREATE2 from a salt over the creator, the name, the symbol and every component's token,
  units, weight, price id and decimals; `predictIndexAddress` returns the address before the transaction is sent. The
  factory stores price ids and never calls Pyth.
- `IndexZap` (`src/IndexZap.sol`) is v3's stateless convenience router over Uniswap's Universal Router.
  `mintWithToken` buys exactly the basket with exact-output swaps and issues; `burnToToken` redeems and sells every
  component into the chosen token; `burnToTokenWithPermit` does it in one transaction. It is the only contract here that
  knows about Uniswap.
- `BasketBuilder` (`src/BasketBuilder.sol`) is the zap's stateful sibling for baskets beyond one transaction: `buy`
  swaps the named legs into an escrow per caller and token, as many calls as the gas cap needs, `mint` issues out of
  it, and `redeem`, `sell` and `withdraw` mirror that; `deposit` puts in a coin that has no route. Both swap through
  `UniversalRouterSwaps` (`src/UniversalRouterSwaps.sol`), the engine they share, and encode a leg the same way.
- `MintRequests` (`src/MintRequests.sol`) is an ownerless escrow. `requestMint(index, stable, amount, minShares,
  deadline)` escrows USDC or USDT for at least `minShares` shares; `requestRedeem(index, shares, stable, minOut,
  deadline)` escrows shares for at least `minOut` of a stablecoin. Anyone `fill`s a request before its deadline by
  sending the requester what they asked for and takes the escrow. The requester can `cancel` at any time, and anyone can
  `refund` the escrow to the requester after the deadline, at most 30 days away. Nothing reads a price: the requester's
  limit is the valuation.

Invariant, for every component `i` of every index, forever:

```
token_i.balanceOf(index) >= floor(totalSupply × units_i × scale / 1e36) + totalClaims[token_i]
```

with `units_i` as recorded and `scale` the streaming fee's factor, 1e18 until a fee accrues. No settlement resets the
scale, so no leg's units are ever rounded to fold it in (XS-2).

## How the flows work

**Create.** The creator picks whitelisted tokens, a weight for each in basis points summing to 10,000, and the value
one index token should start at. The app turns each weight into starting units at its own prices, `units_i = w_i /
10,000 × value / price_i` in the token's raw units, calls `predictIndexAddress` to show the address, and calls
`createIndex`. The factory reads no price, so units a little off the weights cost nothing: the first rebalance, the
index's interval after creation, brings the index to its weights. Every unit has to lie in `[MIN_RAW_UNITS, MAX_UNITS]` or the call
reverts `UnitsOutOfRange(token, units)`. For WBTC, whose raw unit is a satoshi, 10,000 raw units is 0.0001 BTC, about
11 dollars at BTC 110k, so WBTC's weight times the index token's value must reach that: an index token worth $100 can
hold WBTC at 11% or more, one worth $1,000 at 1.1% or more. For an 18-decimal component the floor binds on nothing.
Names and symbols are free-form and not unique; the UI must show the index address and `creatorOf` to avoid spoofing.

The address commits to every component's token, units, weight, price id and decimals. A relisting that executes
between the preview and the transaction with a new price id changes the address, never the terms at an address.

**Mint with USDC/USDT.** For each leg the app picks a venue, quotes it (QuoterV2 `quoteExactOutput` for a V3 leg, the
V4 Quoter for a V4 one), sets per-leg limits and the overall `maxAmountIn`, reads `rebalanceNonce()`, and calls
`mintWithToken(MintParams)`. Exact `shares` are minted; unspent USDC comes back.

**Burn to USDC/USDT/anything.** The app quotes each leg in the exact-input direction, sets per-leg minimums and a
non-zero overall `minAmountOut`, passes `rebalanceNonce()`, and calls `burnToToken(BurnParams)` or
`burnToTokenWithPermit`.

**Rebalance.**
1. Once the index's interval has passed since its creation or last rebalance (`earliestRebalance()`; a week after a
   guardian's keep-mask fill, XS-3), anyone calls `startRebalance(0)`. It reads no
   price and calls no component: it only sets the auction's start, `eta`, 2 hours ahead.
2. For 2 hours nothing changes. The targets come from the settlement's own prices, so the notice is for executors to
   ready their stock, routes and price update, not a window holders need. Issue and redeem stay open throughout.
3. A 24-hour auction follows, with `μ` falling linearly from `MU_MAX` (1.02) to `MU_MIN` (0.98), rounding up. An
   executor contract calls `executeRebalance(data, priceUpdate)` with Pyth's signed update and Pyth's fee as
   `msg.value`. The hub reads each moving component's price at `priceTime()`, 12 seconds before the block: Pyth's
   first update at or after that second, published before the block. Each moving component's target is `w_i × V / (W
   × p_i)` units, where `V` is the moving components' value and `W` their weights, and every leg moves the same share
   `s` of the way to its target: all of it, or less, so that no shrinking leg gives up more than 20% of its own units.
   A shrinking leg's step goes to the executor; a growing leg asks `μ × s` of its way, so at the settling prices the
   executor delivers `μ` times the value it takes. It receives the shrinking legs and, inside its `onXindexRebalance`
   callback, must send back what the growing legs need; the fill stands only if every component then backs the new
   units, with the whole of `amountsIn` on top of what the index held. Both sides are recomputed from `totalSupply()`
   in the settling block, so an executor sizes itself from the callback's arguments. `executeRebalance(data,
   priceUpdate, maxAmountsIn)` is the same settlement bounded: it reverts `RebalanceMovedOn(token, required,
   maxAmountIn)` when the index has come to need more of a component than the caller said it would deliver (DA-13).
4. A fill whose release, after the 20% cap, is worth less than `MIN_TRADE` (0.1%) of the moving value reverts
   `NothingToRebalance`: the index is on its weights. A fill that would send nothing out, as on an empty index, settles
   at `MU_MAX`, and nobody is paid.
5. Executors compete the fill down to the `μ` that just covers their swap costs. A lone executor that waits for the
   end keeps at most `1 − MU_MIN`, 2%, of the value it trades, at the settling prices (see "Known limitations").
6. If nobody fills, the auction expires. The owner or guardian can start a fresh one at once; anyone else can 2 hours
   after the auction's last second.
7. The owner or guardian can cancel a rebalance. Cancelling a live one makes others wait 2 hours from the cancel to
   restart; cancelling one that already expired only clears it from the views, and the wait the expiry started stands
   (VR-04).

The fill can land in any block of the auction, and whoever holds shares in that block shares its outcome, so an
executor watching the mempool can put its fill ahead of a public redeem or guardian cancel; the zap's `expectedNonce`
makes such a burn revert, but only after the fill landed. Send an exit during the auction through a private relay
(RT-02). Shares issued while a rebalance is pending share the outcome of any fill that lands after them, however it is
ordered.

**Rebalance around a frozen component.** The guardian cancels and starts again with the component's bit in `keepMask`;
that component keeps its units, its price is not read, and the settlement neither transfers it nor reads its balance,
so the mask also routes around a component whose contract or price feed stops answering (DA-14, RT-01). At least two
components must stay moving (`InvalidKeepMask`).

**Exit while a component is frozen.** If, say, WBTC is paused, `redeem` and the zap revert. The holder calls
`redeemSkipping(shares, to, skipMask)` with the WBTC bit set: every other component arrives now and the WBTC amount is
recorded in `claimOf(to, WBTC)`. Once WBTC transfers resume, `claim(WBTC, to)` pays it.

**Trade.** An index is a normal ERC-20, so it can be transferred or listed on any DEX. The burn path is the guaranteed
exit.

**Direct, without the zap.** `issue`, `redeem`, `redeemSkipping` and `claim` on the index itself work for anyone who
already holds the components or shares.

**Requests.** A holder of USDC who wants shares without swapping a basket calls `requestMint` with a limit the app
suggests from its own valuation, for example 1% under the index's value. A minter who holds shares, or can issue them in
kind, calls `fill(id, amount)`: at least `minShares` shares go from the minter to the requester, measured at the
requester, and the escrowed USDC goes to the minter. A redemption is the mirror image, and a USDT fee comes out of the
filler's delivery, so the requester still receives the limit. Unfilled, the escrow goes back on `cancel` (the requester,
at any time) or `refund` (anyone, after the deadline).

## Frontend integration notes

- **Index value is the app's job.** No contract has a price function. Value one whole index token as
  `Σ units_i / 10^decimals_i × price_i` from `components()`, `componentTerms()` and the app's own prices: take the
  median of several exchanges and aggregators, drop sources more than about 2% from the rest, price exactly the asset
  held (WBTC at WBTC's own market price), and mark a price older than about ten minutes as estimated. Never derive a
  price from `balanceOf(index)` and `totalSupply()`, and never use a thin DEX pool of the index token as an oracle.
- **Starting units.** The app derives them from the creator's weights at its own prices (see "Create"); the factory
  takes them as given. `createIndex` reverts `UnitsOutOfRange` unless each lies in `[MIN_RAW_UNITS, MAX_UNITS]`,
  `InvalidComponentCount` outside 2 to `MAX_COMPONENTS` (100), `InvalidWeights` unless every weight is non-zero and
  they sum to 10,000, and `DuplicatePriceId` when two components share a Pyth price id, since Pyth fills only the first
  of two equal ids and such an index could never settle (V5-M1). Offer the one-click zap only up to about 35
  components; a larger index mints in kind, through `MintRequests`, or through the basket builder over several
  transactions.
- **Names and symbols are not unique.** `createIndex` requires only that they are non-empty. The CREATE2 salt commits
  to the creator, the name, the symbol and every component's token, units, weight, price id and decimals, so two
  look-alike indexes have different addresses: key every index by its address, show `creatorOf`, and mark a name or
  symbol an existing index already uses.
- **Rebalance status.** Show `earliestRebalance()`, the index's own interval after `lastRebalance` (a week after a
  keep-mask fill), and a "rebalance due" button when
  `canStartRebalance()` is true and the index has drifted. `previewRebalance` reverts outside an auction, so compute
  the drift off chain from `components()`, `componentTerms()` and Pyth's prices, as the settlement does: a start whose
  fill would release, after the 20% cap, less than 0.1% of the moving value ends in `NothingToRebalance`.
  `canStartRebalance()` answers the whole timing predicate: the interval has passed, no
  auction is live (an auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`, so
  `pendingRebalance().eta == 0` on its own is the wrong test), and the waits after a cancel and after an unfilled
  auction are over. Those waits hold off everyone but the owner and guardian: `REBALANCE_DELAY` from the cancel of a
  live auction, and `REBALANCE_DELAY` from an unfilled auction's last fillable second, so after an expiry the owner and
  guardian have the start to themselves for `REBALANCE_DELAY` less one second (CR-I02). Read `canStartRebalance()` or
  the `restartAllowedAt` that `RebalanceCancelled` carries rather than computing either wait; `restartAllowedAt()`
  alone reflects cancels only (RT-08, RT-09).
- **During a rebalance.** In the notice, show `pendingRebalance()`, which returns `(eta, keepMask)`. In the auction,
  show `currentMu()` (0 outside an auction) and `previewRebalance(prices)`, which returns `(mu, units, amountsOut,
  amountsIn)` for this block at the Pyth prices the app passes. Its `units` are recorded units, which carry the
  index's scale: show them as units per index token only after multiplying by the scale `pendingStreamingFee()`
  reports, divided by 1e18. While a rebalance is pending, warn before a mint that
  the new shares share the coming settlement's outcome; during the auction, also warn before a burn that the fill can
  be ordered ahead of it, and that a private relay is the protection (RT-02).
- **Rebalance events.** `RebalanceStarted(proposalId, id, caller, keepMask, eta)`, `RebalanceCancelled(proposalId,
  caller, restartAllowedAt)` and `Rebalanced(proposalId, id, executor, mu, priceTime, prices, units, amountsOut,
  amountsIn)`, whose `prices` are USD per raw unit scaled by 1e36, zero for a kept component. `proposalId` counts every
  attempt on the index, so cancelled, expired and settled attempts can be told apart; `id` is the `rebalanceNonce` a
  settlement takes. Nothing is emitted when an auction expires unfilled: the next `RebalanceStarted` is the first sign.
- **Guardian duty.** Watch every pending rebalance: its keep mask (RT-07), and the moving components' Pyth feeds, since
  a fill at a wrong price trades the index toward wrong targets, bounded per fill by the 20% cap on units;
  `cancelRebalance` is the check, and a keep mask routes around a feed that has stopped. The contracts cannot tell a
  wrong price id from a right one; the guardian's `cancelListing` during a listing's 2 days is the check.
- **Zap calls take a params struct.** `MintParams {index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to,
  deadline}` with `MintLeg {v3Path, v4Path, maxAmountIn}`, and `BurnParams {index, expectedNonce, shares, tokenOut,
  minAmountOut, legs, to, deadline}` with `BurnLeg {v3Path, v4Path, minAmountOut}`. `legs` has one entry per component,
  in component order. `expectedNonce` is `rebalanceNonce()` when the legs were quoted; after a rebalance, re-quote.
- **One venue per leg.** A leg carries exactly one of a packed `v3Path` (Uniswap V3) and a `v4Path` (Uniswap V4). Both
  empty means "no swap", which is only valid for the pass-through leg, the one whose component already is the stable on
  a mint or `tokenOut` on a burn. Anything else is `BadRoute(i)`. There are no mixed-venue legs.
- **V3 routes.** Packed paths: `token(20) | fee(3) | token(20) [| fee(3) | token(20)]`. For **mint** the path is
  exact-output encoded, starting with the component and ending with the stable (e.g. `WBTC 500 WETH 500 USDC`). For
  **burn** it is exact-input encoded, starting with the component and ending with `tokenOut`.
- **V4 routes.** An array of `PathKey {address intermediateCurrency, uint24 fee, int24 tickSpacing, address hooks,
  bytes hookData}`, one per hop. Every hop must be hookless: `hooks` zero and `hookData` empty, or `BadRoute(i)`. Each
  entry carries the pool of the hop it closes. The **burn** direction is walked forwards from the component, so the
  last entry names `tokenOut`; the **mint** direction is walked backwards from the component, so the *first* entry
  names the stable and the list is the burn route reversed. Live V4 pools for these components are paired against
  **native ether**, `address(0)`, which may only ever be an intermediate: native ether never reaches the zap, which has
  no `receive()`. Example, USDC to LINK: burn `[{ETH, 3000, 60}, {USDC, 500, 10}]`, mint `[{USDC, 500, 10}, {ETH,
  3000, 60}]`. Keep a route from visiting the same currency twice: on a mint, the pinned periphery does not hold a V4
  exact-output route that revisits `tokenIn` to its `amountInMaximum` (upstream issue #564), so the zap's pre-funding
  is then the only bound on that leg; on a burn, a route that revisits the component can fill a later hop partially
  and return the unsold component instead of reverting (CR-I06, CR-I07).
- **A zero-amount burn leg.** A leg whose amount rounds to zero sells nothing, but its route is still validated and its
  minimum must be 0, or the burn reverts with `InsufficientOutput`.
- **Slippage.** Set a limit on every leg, not only the total; every leg is checked, including the pass-through leg
  (DA-15). A leg limit of 0 means "overall limit only", and the overall burn limit must be non-zero. Legs that cross
  the same pool interact, so summed per-leg quotes are optimistic; an `eth_call` of the whole zap call returns the exact
  amount. Compare each quote with an independent price and refuse to sign when they diverge; use a private relay and
  short deadlines.
- **Gas.** The zap costs 265k to 430k gas per component (measured on a mainnet fork at 20 components in v3, CR-I08:
  a mint 5.3M to 6.2M, a burn 5.1M with two V3 hops a leg to 8.6M with four). EIP-7825 caps a transaction at 2^24
  gas, so disable the zap above about 35 components, keep routes to two or three hops, and refuse or reroute any zap
  call whose simulated gas exceeds about 14M. The in-kind paths fit at 100 components (about 3.7M for `redeem`, 5.1M
  for `redeemSkipping` with every component skipped), and so does the basket builder: three `buy` calls of about 34
  legs and one `mint` (`test_aHundredLegBasketFitsInThreeBuysAndAMint`, on mock pools, so the buys are a floor).
- **Approvals.** USDC supports `permit`; USDT does not, and its `approve` reverts when it changes a non-zero allowance
  to another non-zero value: if `allowance(user, zap)` is not 0, send `approve(zap, 0)` first. The same holds for
  `MintRequests`: a filler who lost a race, or a requester whose request reverted, keeps a non-zero USDT allowance. Index tokens support
  `permit`. Approve exact amounts.
- **Fee-charging currencies are unsupported.** Zap calls revert with `TransferShortfall`. Simulate every transaction
  first and offer the direct `redeem` or `redeemSkipping` exit.
- **Label pausable components and every issuer.** WBTC can be paused by its custodian. Show that on every index that
  holds it, and surface `redeemSkipping` plus any pending `claimOf` balance.
- **Claims follow the recipient.** `redeemSkipping(shares, to, skipMask)` books the skipped components to `to`, and
  `ClaimRecorded` names `to`. Read `claimOf(to, token)`, and have a contract that redeems for a holder pass the holder
  as `to` (DA-17).
- **Show pending proposals.** A listing takes effect between `ListingProposed(token, eta, priceId, decimals)`'s `eta`
  and 7 days later (`TokenTermsSet`, then `TokenWhitelisted`); a new guardian after `GuardianProposed` plus 7 days. Ask
  `listingPending(token)` and `guardianChangePending()` whether a proposal can still be executed: an expired one leaves
  `listingEta`, `pendingGuardian` and `pendingGuardianEta` set, so those fields on their own read as pending forever
  (DA-16). Treat `GuardianProposed` as a security alert: once it executes, the owner's listings no longer face the old
  guardian's veto.
- **Returned components.** Whenever the router takes less than it was given, the unsold part goes to the recipient
  with a `ComponentReturned` event: every hop of a V3 burn leg, and as a rule only the first hop of a V4 burn leg,
  whose intermediate partial fill reverts the whole leg (CR-I07). A returned amount includes anything a stranger had
  left on the router, and a stray balance never makes a burn revert (CR-L02). Show them on the receipt.
- **ABIs.** `abi/WeightedIndexFactory.json`, `abi/WeightedHub.json`, `abi/IndexZap.json`, `abi/BasketBuilder.json`
  and `abi/MintRequests.json` are committed and regenerated by CI, which fails on a diff; decode every event and revert with them
  (`forge inspect <contract> abi --json` reproduces them, and the interfaces in `src/interfaces/` carry the NatSpec).
  Read the constants on chain rather than hard-coding them: `LISTING_DELAY`, `PROPOSAL_WINDOW`, `GUARDIAN_DELAY`,
  `MIN_COMPONENTS`, `MAX_COMPONENTS`, `TOTAL_WEIGHT`, `MIN_RAW_UNITS`, `MAX_UNITS` on the factory, and
  `MIN_REBALANCE_INTERVAL`, `REBALANCE_DELAY`,
  `AUCTION_DURATION`, `MAX_TURNOVER`, `MIN_TRADE`, `MU_MIN`, `MU_MAX`, `MAX_CONFIDENCE` and `PRICE_LAG` on the hub.
  Errors that several contracts raise (`ZeroAddress`, `LengthMismatch`, `Unauthorized`, `NotIndex`, `InvalidRecipient`)
  are declared once, in `IXindexErrors`.
- **Events.** `WeightedIndexFactory`: `IndexCreated` (every component's token, units, weight, price id and decimals),
  `ListingProposed`, `ListingCancelled`, `TokenTermsSet`, `TokenWhitelisted`, `GuardianProposed`,
  `GuardianChangeCancelled`, `GuardianSet`, `OwnershipTransferStarted`, `OwnershipTransferred`. `WeightedHub`: `Issued`,
  `Redeemed`, `ClaimRecorded`, `Claimed`, `RebalanceStarted`, `RebalanceCancelled`, `Rebalanced`, and the ERC-20 events.
  `IndexZap`: `ZapMint`, `ZapBurn`, `ComponentReturned`. `BasketBuilder`: `Deposited`, `Withdrawn`, `Bought`, `Minted`,
  `Redeemed`, `Sold`, `Unsold`.
- **Watch the ownership handover.** `transferOwnership(new owner)` emits `OwnershipTransferStarted` and
  `acceptOwnership()` emits `OwnershipTransferred`. It is the one admin change with no delay and no guardian veto.
- **Errors.** `IndexZap`: `NotIndex`, `StaleRebalanceNonce`, `Expired`, `ZeroAddress`, `ZeroAmount`, `InvalidRecipient`
  (the zap, the index, the router, the PoolManager or the factory, RT-21), `LegCountMismatch`, `BadRoute(i)`,
  `ShortFill(i, received, required)`, `InsufficientBudget`, `InsufficientOutput`, `TransferShortfall`; the swap errors
  are declared in `IXindexErrors`, shared with `BasketBuilder`, which adds `LengthMismatch`, `ComponentOutOfRange` and
  `InsufficientEscrow(token, held, needed)`, and whose `BadRoute` and `ShortFill` name a leg by its position in the
  call. `WeightedHub`:
  `NotFactory`, `NotInitialized`, `InvalidComponents`, `ZeroShares`, `ZeroAddress`, `InvalidRecipient` (also for a share
  transfer to the index itself or its factory), `InvalidSkipMask`, `NothingToClaim`, `TransferAmountMismatch`,
  `Unauthorized`, `RebalanceTooSoon`, `RebalancePending`, `InvalidKeepMask`, `NoPendingRebalance`, `RebalanceNotReady`,
  `RebalanceExpired`, `RebalanceUnderfunded`, `RebalanceMovedOn`, `NothingToRebalance`, `PriceMismatch(id,
  publishTime)`, `PriceOutOfRange(token, price, expo)`, `PriceUncertain(token, price, conf)`, `PriceCountMismatch`
  (only from `previewRebalance`), `LengthMismatch`, OpenZeppelin's ERC-20 and ERC-2612 errors, and Pyth's own errors
  from its parse (an update that does not cover a feed in the window, or a fee too low). `WeightedIndexFactory`:
  `EmptyString`, `InvalidComponentCount`, `TokenNotWhitelisted`, `DuplicateToken`, `DuplicatePriceId`,
  `UnitsOutOfRange(token, units)`, `InvalidWeights`, `IndexAlreadyExists`, `NotAContract`, `InvalidPriceId`,
  `InvalidDecimals`, `AlreadyListed`, `ListingPending`, `NoPendingListing`, `ListingNotReady`, `ListingExpired`,
  `NotWhitelisted`, `NoPendingGuardianChange`, `GuardianChangeNotReady`, `GuardianChangeExpired`, `Unauthorized`,
  `RenounceDisabled`, and OpenZeppelin's `Ownable` errors.
- **Requests.** Suggest a limit from the app's own valuation and show the deadline; a fill pays exactly what the filler
  sends, so any surplus over the limit goes to the fastest filler. Read a request with `getRequest(id)` (`requester`,
  `deadline`, `isMint`, `open`, `index`, `stable`, `escrow`, `limit`) and follow `MintRequested`, `RedeemRequested`,
  `RequestFilled(id, filler, delivered)`, `RequestCancelled` and `RequestRefunded`. `escrow` is what arrived, which is
  less than the amount asked when USDT charges a fee. Errors: `NotIndex`, `NotAStable`, `ZeroAmount`,
  `InvalidDeadline`, `NothingEscrowed`, `RequestNotOpen`, `RequestExpired`, `RequestNotExpired`,
  `BelowLimit(delivered, limit)`, `Unauthorized`.
- **Swap failures arrive unwrapped.** The Universal Router wraps a command in `ExecutionFailed` only when it dispatched
  it with a low-level call, and swaps are internal calls, so the app decodes the pool's own error:
  `V3TooMuchRequested()`, `V3TooLittleReceived()`, `V4TooMuchRequested(uint256,uint256)`,
  `V4TooLittleReceived(uint256,uint256)`, `CurrencyNotSettled()`, or another PoolManager error, against the router's
  own ABI.

## Whitelist policy

Standard ERC-20s only: no fee-on-transfer, rebasing, or ERC-777/callback tokens; 6-18 decimals; the address must be a
contract. `issue` verifies the received amount. USDC and USDT are fine to mint *with* but are not *components*. A
component that can be paused or blacklisted, such as WBTC, must be labelled in the app, and so must every other
issuer a component adds (see "The list"). How a token's own supply is minted does not matter, since nothing reads it: a
wrap, an unwrap or an issuer's mint moves nothing the hub reads (CR-M01).

**Price id.** Every listing records the token's Pyth price id and its decimals, read from the token when the listing is
proposed; no settlement ever asks a component for them again (RT-01). A price is scaled as `price × 10^(36 + expo −
decimals)`. Each id in `script/PythIds.sol` carries its feed's description beside it, and the description must name the
asset held: WETH takes ETH/USD, since it redeems one for one on chain; WBTC takes WBTC/USD, so its own depeg shows; a
Wormhole copy or a Binance-Peg coin takes its coin's feed.

**Listing.** `proposeListing(token, priceId)`, owner only, starts `LISTING_DELAY` (2 days); from then until
`PROPOSAL_WINDOW` (7 days) later anyone can `executeListing`, which records the terms and whitelists the token; after
that the proposal expires. Until it executes, the owner or guardian can `cancelListing` it. A live listing excludes a
second for the same token (`ListingPending`), and a listed token cannot be proposed again (`AlreadyListed`). Either role
can `delist` a token at any time; delisting affects only indexes created afterwards. A relisting may carry a new price
id and decimals, and they too reach only indexes created after it, since every index copies its ids and decimals at
creation.

## The list

`script/PythIds.sol` holds 92 coins, each with its Pyth price id: `default` is the first four (WETH, WBTC, LINK, UNI)
and `wide` the other 88. 13 of them are Wormhole copies, SOL and 12 of the 13 added on 2026-10-10 (DOGE's left on
2026-10-14, the owner's call, since Pyth prices DOGE and not the copy), and 34 more copies await an
attestation on Wormhole's Portal (section 2a of `design/2026-10-10-one-index-wormhole-legs.md`). Every one went through
`CheckToken` on a fork, which refuses only Tether Gold, admitted on the owner's waiver. On a fork of 2026-10-11, the 92
coins forge-std can fund issued, rebalanced with real transfers and redeemed in one index, and 45 of them traded through
the zap within 2% on $1,000; SNX was left out only because its balances live in its `TokenState`, beyond forge-std's
`deal`.

The app labels every issuer a component adds: BitGo for WBTC, Tether for Tether Gold, Ondo for every `<ticker>on`
stock, Wormhole for every wrapped copy, and both Binance and Wormhole for a copy wrapped from a Binance-Peg coin.

- **WBT** (WhiteBIT's token) **stays off** (the owner's call on 2026-09-30, `design/2026-09-30-wbt-check.md`): its
  Ethereum contract lets a single key blacklist any holder and destroy its balance. That rule is `CheckToken`'s
  default; the owner waived it on 2026-10-10 for Tether Gold and Ondo's stocks, whose issuers hold the same power.
- **Left out** (the owner's calls of 2026-10-06 and 2026-10-10): exchange tokens (OKB, BGB, GT), NIGHT, and memecoins
  beyond SHIB, PEPE and DOGE.
- **Depth.** Most of the Wormhole copies and the real-world assets have no Uniswap liquidity: they mint in kind or
  through `MintRequests`, and a rebalance that buys them needs an executor holding them. Six stocks (TSM, AVGO, LLY,
  JPM, WMT, V) have only US-hours Pyth feeds, so an index holding one settles only while that market is open, or with
  the stock kept.

## Known limitations

- **A lone executor can take up to 2% of what it trades.** At the auction's end `μ` reaches `MU_MIN` (0.98), so an
  executor with no competition that waits for it delivers 98% of the value it takes, at the settling prices.
  Competition fills earlier, at the `μ` that just covers an executor's swap costs. What a fill trades is only the drift
  since the last rebalance, at most 20% of each component's units, at most once a week.
- **A wrong price costs at most the turnover cap.** A fill at a wrong or forged Pyth price trades the index toward
  wrong targets. The cap counts units, not value, so whatever the price says, one fill sends out at most 20% of each
  component's own units, at most once every `MIN_REBALANCE_INTERVAL` (V5-M2); the guardian can cancel, and a confidence
  interval wider than 2% is refused. Pyth's contract on Ethereum is upgradeable by Pyth's governance, which upgraded it
  in place on 2026-08-26, and since then (OP-PIP-132) verifies updates against Pyth's own set of five signing keys, not
  Wormhole's guardians. The app says so on every index.
- **Rebalancing needs Pyth's Hermes, and Hermes needs a key.** Signed updates come from Hermes, which has required an
  API key since 2026-08-26. The contract does not care who fetches an update, so one keyed service can hand updates to
  any executor, but without one no index rebalances. Six of Ondo's stocks (TSM, AVGO, LLY, JPM, WMT, V) have only
  US-hours feeds, so an index holding one settles only while that market is open, or with the stock kept.
- **Wrapped legs rest on Wormhole.** Wormhole's guardians (13 of 19) can forge a bridge message, minting unbacked
  wrapped tokens or upgrading every wrapped token's code at once, with no timelock; that reaches the whole of every
  wrapped leg, beyond the turnover cap. The wrapped copies have no DEX liquidity: redeem pays them, and turning them
  into the coin needs Wormhole live. The app shows every index's wrapped share of value before it is created and to
  every holder (`design/2026-10-10-one-index-wormhole-legs.md`, section 3).
- **A collapsing coin can stop the fills.** Fixed weights keep buying a coin whose price falls, and units beyond
  `uint96` stop the fill rather than wrap, until the guardian keeps it (V5-L3).
- **An issuer's corporate action is not accounted for.** An index holds fixed units per share and pays out only those.
  If an issuer mints tokens to every holder, as a stock split paid in tokens would, the index's new tokens belong to no
  share; if it burns them, that leg falls below its backing; and if one of Ondo's stock tokens stops being exactly one
  share, the legs priced at the share's own feed are mispriced at every rebalance. How Ondo applies splits and
  dividends is to be confirmed before mainnet; until then the guardian keeps an Ondo leg out of any rebalance around a
  corporate action (CF-3, `audit/2026-10-13-security-audit.md`).
- **Price ids are data the owner maintains.** The contracts cannot tell a wrong price id from a right one. Check each
  listing's feed description during its 2 days, while it can still be cancelled. An index copies its ids at creation,
  so a wrong id reaches only indexes created while it stood, and the guardian can keep that component at each
  rebalance.
- **Rebalances clear only when the moving value pays for the fill.** Small indexes on mainnet rarely rebalance, and a
  fresh index cannot rebalance until its own interval, 7 to 91 days, has passed since its creation. An unfilled auction expires, and for `REBALANCE_DELAY`
  afterwards (less a second, CR-I02) only the owner and guardian can restart it. A fill that would send nothing out, as
  on an empty or dust index, settles at `MU_MAX`, so nobody is paid for it (R14, XA-27).
- **An exit sent during the auction can be overtaken by the fill.** The executor picks the block, so it can order its
  fill ahead of a redeem or a guardian cancel it sees in the public mempool. No bound moves; during the auction, use a
  private relay (RT-02). Shares minted while a rebalance is pending share the outcome of any fill that lands after
  them, whatever the ordering.
- **The guardian can stall rebalancing.** `cancelRebalance` has no window and no rate limit, so a hostile or
  compromised guardian can cancel each proposal at the last second of its auction and hold rebalancing off while the
  index drifts from its weights. It moves no funds, holders redeem throughout, and the owner ends it by replacing that
  guardian: 7 days of notice the guardian cannot cancel, since it may only cancel its own removal (DA-12). A guardian
  can also stall without a cancel: a keep-mask rebalance that leaves a pair of components moving can clear `MIN_TRADE`
  on a sliver of the index. Its fill restarts only `MIN_REBALANCE_INTERVAL` for a rebalance without a keep mask, not
  the index's own interval, so the stall can outlast the guardian's replacement by up to a week (XS-3); the owner and
  the new guardian can start a keep-mask rebalance then too, for an index that only settles with a component kept. While a replacement is pending, the owner cancels the outgoing guardian's
  keep-mask proposals, and monitors alert on `RebalanceStarted` with a non-zero `keepMask` (RT-07). The owner has only
  `REBALANCE_DELAY`, 2 hours, to cancel one before the guardian's own executor can fill it at `eta`.
- **Issuers can freeze components, and some can burn them.** WBTC can be paused by its custodian. Tether Gold and
  Ondo's stocks can blacklist a holder, an index included, and destroy its balance; the owner accepted that on
  2026-10-10. A paused component makes `redeem`, the zap and any fill that moves it revert; `redeemSkipping`, `claim`
  and the guardian's keep mask are the recourse, and a permanently frozen component needs the keep mask at every
  rebalance. A destroyed balance is lost to the index's holders.
- **A request's surplus goes to the fastest filler.** A fill delivers what the filler sends and at least the
  requester's limit, so a generous limit is value left for fillers. The app suggests limits from its own valuation.
- **Circle and Tether freeze differently, and `MintRequests` cannot tell.**
  - Circle checks the sender, the recipient and the caller of every USDC transfer. A fill that pays a blacklisted
    requester reverts, and so does a refund of their USDC escrow, until Circle lifts the blacklist.
  - Tether checks only the sender of a `transfer` and only `from` of a `transferFrom`. A requester Tether has
    blacklisted can still be filled and refunded, into a balance they cannot move and Tether can destroy. The app
    should check `USDT.isBlackListed(requester)` before showing a USDT request to fillers, and warn the requester.
  - If an issuer blacklists `MintRequests` itself, every open escrow in that stablecoin waits with it. A Circle
    blacklist also stops fills of USDC redemptions, whose escrow is shares, although `cancel` still returns those.
    Tether can go further and destroy the contract's USDT, leaving those requests open but unbacked for good. A new USDT
    mint request first sends the contract nothing, which fails while it is blacklisted or USDT is paused, so no
    deposit is taken into a contract that could not pay it out (SA-01).
  - All escrows share one contract, so an issuer's only lever over funds parked there by someone it has since
    sanctioned is to freeze everyone's. A sanctioned requester's USDC escrow can still leave through a fill by an
    accomplice at a limit set before the sanction.
  - A pause of USDC or USDT stops every fill, cancel and refund in that coin until it ends.
  - Tokens sent to `MintRequests` outside a request stay there, since it has no owner to sweep them.
- **A request is an option held by every filler until it closes.** If something changes what a share is worth to the
  requester after they sign, for instance every component pausing, a filler can still deliver at the old limit, and a
  cancel sent to the public mempool can be overtaken by a fill. The loss is bounded by the requester's own limit. The
  app should default to short deadlines and send cancels through a private relay.
- **Fees in shares only.** Mint and redeem fees are minted as shares to the creator, the platform and a referrer; no
  fee ever moves a component, and the platform's policy is zero until the owner sets one.
- **The streaming fee is charged on the supply that was there.** Every issue, redeem, settlement and `accrueFees` first
  mints the fee accrued since the last accrual, and the clock restarts on every one of them, one that mints nothing
  included, so a dust supply left idle never charges that time to the next minter (XS-1); what that forgoes is under
  one share per call. An integer scale backs the supply by up to `supply · units / 1e36` raw units less per accrual, a
  part in 1e18 of a leg, which stays in the index. A lifetime's gap is capped just under the whole index, and a second
  one, which would shrink the scale to zero, is not charged. `lastAccrual()` and `pendingStreamingFee()` show the clock
  and what an accrual now would mint.
- **The basket builder is one custody point.** Every user's escrow of a token sits in one address. An issuer that
  blacklists or pauses the builder freezes every escrow of that token until it lifts the block, and one that can
  destroy a blacklisted balance, as Tether's contracts can, can take them all. The builder sends itself one unit of a
  token before it credits an escrow of it, so a deposit, a buy or a redeem into a builder already blocked is refused
  (XS-10); a block that comes later traps what is already there. The app should check `isBlackListed(builder)` on
  Tether-pattern tokens (USDT, XAUT) before offering the builder, and a holder whose exit through the builder is refused
  redeems on the index itself, with `redeemSkipping` and `claim` for a frozen leg.
- **Airdrops, rewards and governance votes** that accrue to tokens held by an index cannot be claimed or used; by design
  there is no admin who could sweep them.
- **A hooked V4 pool cannot be routed through.** The zap rejects any V4 route whose hops carry hooks or hook data, so a
  component whose only V4 depth sits behind a hook is reachable on V3 only.
- **A `tokenIn` that calls back into the zap is unsupported**, alongside fee-on-transfer currencies. The zap pre-funds
  the Universal Router with exactly a leg's cap and sweeps it back within the same `execute`; the pre-fund is the bound
  (CR-I14, RT-11). Mint and burn currencies are the user's choice, so the app should offer only USDC and USDT.
- **Zap gas grows with components and hops, and nothing on chain bounds it.** See "Gas" above: about 35 components is
  the zap's practical limit. The in-kind path is what fits at 100.
- The zap is pinned to **Universal Router 2.0.0** rather than the 2.1.x line, whose command inputs carry an extra
  per-hop price array. Moving to a newer router means a new zap; the hub and factory do not depend on it.
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`), which Ethereum runs. Re-check before deploying to any
  other chain.

## Mainnet addresses

Ethereum (`script/MainnetAddresses.sol`):

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| Uniswap Universal Router 2.0.0 | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap QuoterV2 (V3 quotes) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Uniswap V4 Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Uniswap V4 StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| Pyth | `0x4305FB66699C3B2702D4d05CF36551390A4c69C6` |
| WeightedIndexFactory / IndexZap / BasketBuilder / MintRequests | not deployed |

The scripts read these addresses from the address book, and `test/fork/MainnetAddresses.fork.t.sol` checks it on
chain: tokens by symbol and decimals, the router and the PoolManager by their runtime code hashes (every Universal
Router build answers `poolManager()` alike, CR-I35), Pyth's proxy by its code, the Wormhole copies against the bridge,
and both lists on a fresh factory over Pyth. The quoters and StateView are for apps and tests; no contract reads
them.

## Development

```bash
forge build --sizes
forge lint -D notes             # fails on any warning or note
forge fmt
forge test                      # unit, fuzz, invariant and security regression tests, no RPC needed
forge coverage                  # 100% on every file
aderyn .                        # Cyfrin's analyzer on src/, configured in aderyn.toml: reports nothing
forge test --root keeper        # the keeper's executor, a Foundry project of its own
node --test keeper/test/unit/*.test.mjs  # the keeper bot's arithmetic, settings, Hermes client and transaction tracker

# end-to-end against the real Universal Router, V3 and V4 pools, USDC, USDT and a real WBTC pause
# (skipped when the env var is unset)
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# non-archive RPCs only serve recent state; override the pinned block:
MAINNET_RPC_URL=https://... FORK_BLOCK=<recent block> forge test --match-path 'test/fork/*'
```

CI (`.github/workflows/test.yml`) checks that every submodule commit matches `foundry.lock`, then runs fmt, build,
`forge lint -D notes`, tests, 100% coverage on every file (offline suites), the ABI diff, the Wake detectors on `src/`,
the swap rail's tests and the keeper's gates, with pinned Foundry and Wake versions. Pushes to `main` and pull requests
into it from this repository fail until a `MAINNET_RPC_URL` repository secret exists, so the fork tests always run
there; it needs an archive node for the pinned fork block. Pull requests from forks get no secrets and skip the fork
suites, so re-run them before merging. A keyed RPC may throttle five fork suites run in parallel; run them with `-j 1`
when a revert appears next to an HTTP 429. CI does not run Aderyn yet, so run it before pushing.

### Deploy

Nothing below has been run on a mainnet; it has run end to end on an anvil fork of Ethereum. Never put a private key
in `.env`. Import the deployer key once into an encrypted keystore, or use a hardware wallet with `--ledger`:

```bash
cast wallet import deployer --interactive
cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
source .env
```

`DeployWeighted` deploys `WeightedIndexFactory`, which deploys the `WeightedHub` implementation every index is a clone
of, then the zap, the basket builder and `MintRequests` for that factory. It runs once, on Ethereum. Listings follow through the factory's
timelock.

```bash
OWNER=<safe> GUARDIAN=<guardian> forge script script/DeployWeighted.s.sol --rpc-url mainnet --account deployer \
  --sender <deployer> --broadcast --verify
```

`OWNER` and `GUARDIAN` are required and must differ. On a mainnet the owner must be a contract that is not an EIP-7702
delegated account, and a Safe must need at least three signatures (`MIN_OWNER_THRESHOLD`, the design's 3-of-5) and have
no enabled module, because a module acts as the Safe without signatures (keep it that way after deployment; the script
cannot see later changes). The guardian must not be the broadcasting key, which must hold no role; when the owner is a
Safe, neither the guardian nor the broadcasting key may be one of its signers, since the guardian is the owner's veto
(SA-06); and neither role may be a market contract: the router, the PoolManager and Pyth everywhere, and on a mainnet
also every token and mint currency in the address book (CR-I37). `PYTH`, `UNIVERSAL_ROUTER`, `USDC` and `USDT`
default to the address book's on chain 1 (`script/MainnetAddresses.sol`), where any other value is rejected, and are
required anywhere else; they are the script's only market addresses, because the hub and factory depend on no Uniswap contract.

**Deployment record.** `forge script --broadcast` writes `broadcast/DeployWeighted.s.sol/<chain id>/run-latest.json`:
the git commit, each transaction with its init code, and the addresses. Broadcast from a clean, committed tree so the
recorded commit is the deployed source, commit the record with the README address table (on a mainnet with `git add
-f`: `.gitignore` keeps chain-1 records out, because fork rehearsals keep chain id 1), and verify the source on the
explorer (`--verify` needs `ETHERSCAN_API_KEY`). The deploy log ends with the runtime code hashes of the factory, the
`WeightedHub` implementation, the zap, the basket builder and `MintRequests`: record them with the addresses, and
`DeployWeighted.checkDeployment(factory, zap, builder, requests)` re-reads them later (it also refuses a zap, a
builder or a `MintRequests` that does not point at that factory, a builder on another router, and an implementation
reading another Pyth).

**The admission check** comes first: `script/CheckToken.s.sol` is read-only and prints one report per token for the
Safe's signers (transfers simulated on a fork, transfer hooks, admin powers and who holds them, Uniswap depth on
Ethereum, the supply), and refuses a token by the WBT rule. `design/2026-10-05-token-admission-report.md` records its
first run, on 43 coins; every coin of today's list went through it on a fork before its listing.

```bash
CHECK=wide forge script script/CheckToken.s.sol --fork-url <mainnet rpc>
CHECK=<token,...> forge script script/CheckToken.s.sol --fork-url <any evm rpc>
```

**Listings** go through `script/ConfigureWeighted.s.sol`, or the equivalent calls through the Safe: each coin with
the Pyth price id its indexes rebalance at. `V5_WHITELIST=default` is the first four coins of `script/PythIds.sol`
and `V5_WHITELIST=wide` the other 89. Safe mode labels each with its trust tier:

```bash
# owner is a key you hold (testnets and local forks only; a contract owner such as the mainnet Safe cannot sign, and
# propose then reverts with OwnerIsContract: use safe mode)
V5_MODE=propose V5_FACTORY=0x... V5_WHITELIST=<entries> V5_LIST=<tokens to list> forge script script/ConfigureWeighted.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
# owner is a Safe: print the listing proposals as calldata to sign in the Safe app (nothing is broadcast);
# V5_LIST=all on the launch run only, and unset on every later run
V5_MODE=safe V5_FACTORY=0x... V5_WHITELIST=default V5_LIST=all forge script script/ConfigureWeighted.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account: execute every due listing
V5_MODE=execute V5_FACTORY=0x... V5_WHITELIST=default forge script script/ConfigureWeighted.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`V5_MODE` is one of `propose`, `safe`, `execute` and `status`. `V5_WHITELIST` is `default` or `wide` (chain 1 only),
or comma-separated `token:priceId` entries; anything else reverts `MalformedEntry`, and a list
that names a token or a price id twice reverts in every mode (RT-24, V5-M1).

- **Propose and safe** propose a listing for each entry that is not listed and has no live proposal, skipping with the
  reason logged: a token never listed unless `V5_LIST` names it (`V5_LIST=all` for every entry), a delisted token
  unless `V5_RELIST` names it, a token with a different listing pending (cancel it first), and any entry outside the
  policy the script can check (a token with code and 6 to 18 decimals, no USDC or USDT). Safe mode applies the same
  checks, because a Safe batch sends every proposal in one transaction and one the factory refuses takes the rest down
  with it (CR-I38). Nothing on chain records that the guardian cancelled a first listing, so leave `V5_LIST` unset on a
  routine run and a cancelled listing stays cancelled until the operator names it again (RT-06). Safe mode labels each
  proposal with the token's symbol (a symbol that is not an ABI string shows as `?`, RT-25), its tier, its address and
  its price id: check the id against the feed's description before signing.
- **Execute** never proposes. It runs only a due listing whose pending price id is exactly the entry's, and logs why a
  pending one was left: not ready, expired, or a different id.
- **Status** is read-only: for every entry, whether the token is listed, whether the price id in force is the entry's,
  and any pending listing with its window and whether its id is the entry's.

In the Safe app, a safe mode's output becomes one Transaction Builder batch: each calldata line is one transaction to
the factory with value 0, under a label line naming the call and the token. The Safe's threshold of signers signs it,
and one executes it. For a local stack, `anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against
`http://127.0.0.1:8545`; the fork keeps chain id 1, and `.gitignore` keeps those rehearsal records out of git. An ignore
rule does not cover a file git already tracks, so check `git status` after a rehearsal.

### Operations runbook

No bot holds a role in Xindex, so these duties have owners and deadlines. Watch the events that start each clock.

| Duty | Starts with | Deadline | Who | How |
|---|---|---|---|---|
| Veto a wrong listing | `ListingProposed` | before `eta` (2 days) | guardian or owner | check the price id against its feed's description and the decimals against the token; `cancelListing(token)` |
| Execute a listing | its `eta` | `eta + PROPOSAL_WINDOW`, or it expires silently | anyone, owner signers first | `V5_MODE=execute` at the eta; `listingPending(token)` says whether it can still run |
| Keep a Hermes key | before the first rebalance | none, but without one no index rebalances | executors, or one keyed service that hands updates to them | Hermes has required an API key since 2026-08-26 |
| Trigger the rebalance | `earliestRebalance()`: the index's interval after `lastRebalance`, a week after a keep-mask fill | none, but the index drifts from its weights | anyone; the keeper in `keeper/` does it when a fill would pay | `canStartRebalance()`, then `startRebalance(0)`; a fill ending in `NothingToRebalance` means the index is on its weights |
| Check each rebalance | `RebalanceStarted` | before the fill | guardian | watch the moving components' Pyth feeds; `cancelRebalance()` on a feed that is wrong or stopped, then a keep mask |
| Watch keep-mask rebalances | `RebalanceStarted` with a non-zero `keepMask` | before `eta` (2 hours) | owner signers | while a guardian replacement is pending, cancel the outgoing guardian's keep-mask proposals (RT-07) |
| Fill auctions | the auction opens at `eta` | `eta + AUCTION_DURATION` | any executor contract | anyone may run the keeper in `keeper/`, which holds no role; competition is what keeps a fill near break-even |
| Fill requests | a `MintRequested` or `RedeemRequested` event | the request's `deadline` | anyone who holds or can issue the shares, or the stablecoin | the keeper in `keeper/` fills at the request's limit when that pays; the surplus over the limit is the filler's |
| Restock the wrapped and real-world legs | the keeper's `restock <coins>` log | before the auction that needs them | the keeper's operator | bridge through Wormhole's Portal, or acquire the token, and send it to the executor |
| Rebalance around a frozen component | a paused or blacklisting component, or a stopped feed | each auction | guardian | `cancelRebalance()`, then `startRebalance(keepMask)` |
| Restart after an unfilled auction | `eta + AUCTION_DURATION` passed with no `Rebalanced` | anyone after `REBALANCE_DELAY` more | guardian first, then anyone | `canStartRebalance()`, then `startRebalance(0)` |
| Re-check venue depth per leg | monthly, and before a large mint or burn | none | app | V3 and V4 depth move independently; the route is the app's choice |
| Watch guardian changes | `GuardianProposed` | `eta` (7 days) | owner signers, guardian, app | a security alert: once executed, the new guardian's veto replaces the old one. `guardianChangePending()` says whether it is still executable |
| Hand over factory ownership | `OwnershipTransferStarted` | none: it takes effect as soon as the new owner accepts | owner signers, then the new owner | the one admin change with no delay and no veto; announce it first, and the new owner has to meet the rules the deploy script checks |

### Testnet (Sepolia)

**v5 is not deployed on Sepolia.** v3 runs there, deployed on 2026-09-27 from `4b4dbe4`, the commit tagged `v3.0.0`;
nothing on `main` can drive it, since its factory takes feed configs, and its deployment records are not kept here.

`script/testnet/SetupTestMarket.s.sol` deploys stand-ins for USDC, WBTC, LINK and UNI as `FaucetToken`s, where any
account can `drip()` a small amount once a day, each with a Uniswap V3 WETH pool at a mainnet-like price so the zap has
a V3 route to swap through. Nothing in Xindex reads those pools' prices. `create` logs the `V5_WHITELIST` entries for
`ConfigureWeighted`: tWBTC, WETH, tLINK and tUNI, each under its mainnet counterpart's Pyth price id, since Pyth's ids
are the same on every chain. Faucet tokens have no value and their supply grows with every drip, which nothing reads.

**No V4 pools on this market.** The V4 legs are proven on mainnet forks and against a strict mock of the Universal
Router's encoding, not on Sepolia.

| Sepolia contract | Address |
|---|---|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Uniswap QuoterV2 | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| Uniswap V3 factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap NonfungiblePositionManager | `0x1238536071E1c677A632429e3655c799b22cDA52` |
| WeightedIndexFactory / WeightedHub implementation / IndexZap / BasketBuilder / MintRequests (v5) | not deployed |

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
DEPLOYER=$(cast wallet address --account sepolia-deployer)

# 1. tokens and priced pools, then liquidity in a later block: 0.3 WETH in the tUSDC pool, 0.1 in each other
MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
MARKET_MODE=seed MARKET_TOKENS=<logged by create> forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 2. the factory (which deploys the WeightedHub implementation), the zap, the basket builder and MintRequests; the test market has no
#    USDT, so USDT is any second 6-decimal test token, a FaucetToken for instance; off a mainnet PYTH is required
OWNER=<Safe> GUARDIAN=<guardian> PYTH=<Pyth's Sepolia contract> UNIVERSAL_ROUTER=0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b \
  USDC=<tUSDC logged by create> USDT=<a second test stablecoin> \
  forge script script/DeployWeighted.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 3. print the listing proposals and sign them as one batch in the Safe app
V5_MODE=safe V5_FACTORY=<factory> V5_WHITELIST=<logged by create> V5_LIST=all forge script script/ConfigureWeighted.s.sol --rpc-url sepolia

# 4. 2 to 9 days later, from any account
V5_MODE=execute V5_FACTORY=<factory> V5_WHITELIST=<same> forge script script/ConfigureWeighted.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
```

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts, so testers can call `drip()` from Etherscan.
`USD_POOL_WETH` and `TOKEN_POOL_WETH` (in wei) change the liquidity `seed` adds. Timing is mainnet's: listings take 2
days, and a rebalance can start an index's interval, at least 7 days, after its creation, followed by 2 hours of notice and a 24-hour auction
whose fill needs a signed Pyth update, as on mainnet. The test pools are shallow and nobody arbitrages them, so zap
prices on this market say nothing about mainnet. `test/fork/WeightedExecutorV3.sol` fills auctions through
SwapRouter02; it is a test fixture without slippage limits, so never fund it on mainnet.

## Layout

```
src/WeightedHub.sol           v5 index implementation (ERC20 + permit, in-kind issue, redeem, redeemSkipping, claim, rebalance
                              to fixed weights at Pyth prices), cloned
src/WeightedIndexFactory.sol  v5 listings (each token with its Pyth price id), guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              mint/burn router over Uniswap's Universal Router, one venue per leg, per-leg limits, nonce check
src/BasketBuilder.sol         the zap's stateful sibling: legs bought or sold over several transactions through an escrow per caller
src/UniversalRouterSwaps.sol  the swap engine the zap and the builder share: pre-fund, swap, sweep, measure, per leg
src/MintRequests.sol          ownerless escrow of USDC/USDT-for-shares requests at the requester's own limit
src/interfaces/               every contract's interface, the shared errors (IXindexErrors), the vendored IUniversalRouter and
                              Pyth's IPyth, IPythEvents and PythStructs
src/libraries/                PathLib, UniversalRouterCommands and UniswapV4Types (vendored)
test/*.t.sol                  unit, fuzz, invariant, script and repository tests
test/Security.t.sol           regression tests for the security review findings (some ids are tested elsewhere; see AGENTS.md gate 6)
test/mocks/                   mock tokens, a strict Universal Router, a Pyth that follows Pyth's fill loop,
                              V3 pools for the testnet script, the market fixture, with their own tests
test/fork/                    mainnet fork tests: real V3 and V4 pools, settlements at Pyth prices and security regressions on real tokens
script/                       DeployWeighted, ConfigureWeighted, PythIds, CheckToken, MainnetAddresses, DeployChecks, ScriptUtils
script/interfaces/            the Safe, WETH and Uniswap calls the scripts make
script/testnet/               SetupTestMarket and FaucetToken for the Sepolia test market
abi/                          the ABIs the web app decodes with; CI regenerates them and fails on a diff
keeper/                       the keeper bot and its executor, a Foundry project of its own with its own tests; it holds
                              no role in the protocol (keeper/README.md)
design/                       the v5 spec, the one-index decision, the wide-asset and admission records, the WBT
                              check, the swap-venue record, and the Stage A spec whose issue, redeem and claims v5
                              keeps
audit/                        the security reviews, their triage, and the six retirement records (the PoCs are in git
                              history at f83dcab)
aderyn.toml                   Aderyn's configuration: the rules the design rejects, each with its reason
```

## Not built (candidates for later)

A fee in a later index version, ETH in/out (`mintWithETH` / `burnToETH`), `createAndMint` in one call,
`mintWithTokenPermit` for USDC, creator fees (attributed by `creatorOf`), constituent changes (a new list is a new
index), mixed-venue legs that split one leg across V3 and V4, per-pair partial-fill auctions, a backstop for auctions
too small to pay (the keeper in `keeper/` fills only what pays, unless its operator sets a subsidy with a negative
`MIN_PROFIT_USD`), an aggregator or Universal Router 2.1 zap, V4 pools on the Sepolia market, and one L2 deployment
if cheap minting for small buyers matters after
launch. Other chains' coins come in only as Ethereum tokens: the issuer's own, or the copy Wormhole's token bridge
wraps (`design/2026-10-10-one-index-wormhole-legs.md`).
