# Xindex

Xindex lets investors package a whole crypto portfolio into a single ERC-20 token. Anyone can create an index (any
name, any symbol, any mix of whitelisted tokens), anyone can mint it with USDC or USDT, and anyone can burn it back into
USDC, USDT, WBTC or any other token. Every index is a plain ERC-20, fully backed in kind by the tokens it represents.
Its units follow the market-cap rule `units ∝ supply`, from reference supplies the owner updates weekly behind a public
delay, and a rebalance settles through an auction on a single number, λ. **No contract reads a price.**

This repository holds the smart contracts (Foundry). The web app lives elsewhere.

**Status (2026-10-01): v4, the design that launches on mainnet; deployed nowhere yet.** v4 is one hybrid product
(`design/2026-09-29-v4-hybrid-architecture.md`): an index token on Ethereum that holds Ethereum tokens itself and other
chains' native coins in ownerless vaults. Stage A, the price-free part held on Ethereum, is built as
`design/2026-09-30-v4-stage-a-spec.md` describes it, `MintRequests` included, with the owner's decisions of 2026-09-30:
no fee, WBT off after its check, and an owner Safe of at least three signatures. Stage B, the vaults and their proofs,
is in progress (`design/2026-09-30-v4-stage-b-spec.md`). Internal red teams have reviewed both
(`audit/2026-09-30-stage-a-red-team.md`, `audit/2026-09-30-stage-b-red-team.md`, `audit/2026-10-01-tron-review.md`). It
launches as one product, on `HybridIndexFactory`, once the hybrid index is ready (the owner's call on 2026-10-01). Still
to come: the second proof system (P2), real proving, external audits and a Sepolia rehearsal. v3 stays at the git tag
`v3.0.0` and on Sepolia, and never launches on mainnet.

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
  tested now. Stages B and C add the native coins of other chains, held in vaults there (see "Roadmap" in
  `ARCHITECTURE.md`).

## Design decisions (v4 Stage A)

| Topic | Decision |
|---|---|
| Chain | Ethereum mainnet. Vaults on other chains come in Stage B. |
| Composition | Constituents fixed at creation, up to 100 per index (`MAX_COMPONENTS`). Units follow the uncapped market-cap rule, `units ∝ referenceSupply`; the capped 30/20 methodology is retired, because it trades on price moves and needs prices. |
| Creation | `createIndex(name, symbol, tokens, k)`: every component's units are `⌊k × referenceSupply / 1e36⌋`, each between `MIN_RAW_UNITS` (10,000) and `MAX_UNITS` (`(2^96 − 1) >> 10`). One whole index token holds the fraction `k / 1e36` of every component's reference supply. |
| Supplies | One reference supply per token, in its raw units: the supply of what the token represents (bitcoin's for WBTC, ether's for WETH). Nothing reads a supply live. After the first listing a supply changes only through a weekly **batch**: atomic, one live at a time, 2 days of notice with the guardian's veto, each supply within `MAX_SUPPLY_STEP` (0.5%) of the one in force. |
| Rebalancing | Anyone starts a rebalance 7 days after the last one (`MIN_REBALANCE_INTERVAL`), 2 days of notice (`REBALANCE_DELAY`), then a 24-hour auction (`AUCTION_DURATION`) in which λ falls from the top of the band to the bottom and any contract can fill. Every moving component's units move within `[λmin/λmax, λmax/λmin] ⊂ [0.990, 1.0101]` per rebalance, plus one raw unit of rounding. |
| Prices | None on chain. The app values an index off chain as the sum of units times its own prices (design section 10). |
| Swaps | Uniswap's Universal Router 2.0.0, V3 and V4, one venue per leg, chosen by the caller: as in v3. The app offers the one-click zap only up to about 35 components (EIP-7825's 16.78M gas per transaction). |
| Fees | None: Stage A is funded from outside (the owner's call on 2026-09-30, design section 13.1). Every amount the hub moves goes through one helper, `_backing`, so a fee in a later version would land in one reviewed change. |
| Layer-1 coins | Stage A holds Ethereum tokens only; Bitcoin is held as WBTC. Native coins of chains whose contracts can verify a proof about Ethereum come in vaults from Stage B. Chains that cannot (Bitcoin, XRP Ledger, Dogecoin, ...) are out of scope. |
| Stable in / out | Mint with USDC or USDT through the zap, or through `MintRequests` at a limit of the requester's own, filled by anyone who holds shares. The burner chooses USDC, USDT or any other token at exit, or asks for USDC or USDT at a limit through `MintRequests`. Index tokens are fungible, so the protocol cannot know which stable a holder used. |
| Decentralization | No admin can move an index's funds, mint or burn its shares, pause or upgrade it, or set its units by hand. The owner proposes listings and supply batches, which take effect after 2 days, and guardian changes, which take 7; a proposal not executed within 7 days of becoming ready expires. Owner and guardian both cancel pending listings and batches, delist, cancel a rebalance, and start one with a keep mask or before strangers may. The guardian can cancel a change that would remove it, not one that replaces it. Ownership moves in two steps with no delay, and cannot be renounced. |
| Frozen components | If a component's issuer pauses or blacklists transfers, holders take every other component out with `redeemSkipping` and collect the frozen one later with `claim`; the guardian rebalances around it with a keep mask, which neither transfers the component nor reads its balance or its supply. |

## Architecture

```
                  createIndex(name, symbol, tokens[], k)
   creator ─────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexHub (ERC-20)
                                                       │ listings, weekly supply      │ holds the basket
                                                       │ batches (2-day delay),       │ issue / redeem in kind
                                                       │ guardian, registry           │ redeemSkipping / claim
                                                       │                              │
   anyone ── startRebalance ─────────────────────────► │ referenceSupplies(tokens) ◄──│ start: the λ band
   executor ── executeRebalance ◄── flash-style callback ─────────────────────────────│ fill at λ(t)
                                                                                      │
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                  │
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── minter (holds or issues shares)
             ◄─ shares, at least minShares ─────  (escrow)    ── the USDC ──►
```

- `IndexHub` (`src/IndexHub.sol`) only ever moves amounts derived from supply and units. `issue(shares)` pulls
  `ceil(shares × units_i / 1e18)` of every component and mints; `redeem(shares)` burns and pushes
  `floor(shares × units_i / 1e18)`; `redeemSkipping` leaves chosen components as claims for the recipient. A rebalance
  is `startRebalance` (a snapshot of the band from the reference supplies in force), 2 days of notice, and a 24-hour
  auction whose fill stands only if every component still backs the new units. Nothing in the hub reads a price or
  computes an amount from a balance, so there is no share price to manipulate and no first-depositor attack. Share
  transfers to the hub itself or its factory are refused, since neither could move a share on (CR-I01, RT-21). Only
  initialized clones can issue, redeem or rebalance. Supports EIP-2612 `permit`.
- `IndexFactory` (`src/IndexFactory.sol`) is permissionless `createIndex`, a curated token whitelist in which every
  token carries a timelocked reference supply, the weekly supply batches, an `Ownable2Step` owner plus a guardian whose
  replacement takes 7 days, and the registry (`isIndex`, `creatorOf`, `allIndexes`). Indexes are EIP-1167 clones
  deployed with CREATE2 from a salt over the creator, the name, the symbol, the tokens and the **computed units**;
  `predictIndexAddress` returns the address before the transaction is sent.
- `IndexZap` (`src/IndexZap.sol`) is v3's stateless convenience router over Uniswap's Universal Router, unchanged but
  for its recipient check. `mintWithToken` buys exactly the basket with exact-output swaps and issues; `burnToToken`
  redeems and sells every component into the chosen token; `burnToTokenWithPermit` does it in one transaction. It is the
  only contract here that knows about Uniswap.
- `MintRequests` (`src/MintRequests.sol`) is an ownerless escrow. `requestMint(index, stable, amount, minShares,
  deadline)` escrows USDC or USDT for at least `minShares` shares; `requestRedeem(index, shares, stable, minOut,
  deadline)` escrows shares for at least `minOut` of a stablecoin. Anyone `fill`s a request before its deadline by
  sending the requester what they asked for and takes the escrow. The requester can `cancel` at any time, and anyone can
  `refund` the escrow to the requester after the deadline, at most 30 days away. Nothing reads a price: the requester's
  limit is the valuation.

Invariant, for every component `i` of every index, forever:

```
token_i.balanceOf(index) >= floor(totalSupply × units_i / 1e18) + totalClaims[token_i]
```

## How the flows work

**Create.** The creator picks whitelisted tokens and a size `k` in the UI. `k` is the fraction of each reference supply,
times 1e36, that one index token holds, so it sets the index token's value: `value per token ≈ k / 1e36 × Σ (market
cap of each component)`. The app calls `previewUnits(tokens, k)` to show the basket, `predictIndexAddress` to show the
address, and `createIndex`. Every unit has to lie in `[MIN_RAW_UNITS, MAX_UNITS]` or the call reverts
`UnitsOutOfRange(token, units)`; the component with the smallest supply in raw units sets the floor. For WBTC, whose
raw unit is a satoshi, 10,000 raw units is 0.0001 BTC, about 11 dollars a token at BTC 110k, so `k` must be at least
about 5e24; for an 18-decimal component the floor binds on nothing. Names and symbols are free-form and not unique; the
UI must show the index address and `creatorOf` to avoid spoofing.

The address commits to the units computed from the supplies in force. A supply batch executed between the preview and
the transaction changes both the units (by at most 0.5% per token) and the address, never the basket at an address.

**Mint with USDC/USDT.** For each leg the app picks a venue, quotes it (QuoterV2 `quoteExactOutput` for a V3 leg, the
V4 Quoter for a V4 one), sets per-leg limits and the overall `maxAmountIn`, reads `rebalanceNonce()`, and calls
`mintWithToken(MintParams)`. Exact `shares` are minted; unspent USDC comes back.

**Burn to USDC/USDT/anything.** The app quotes each leg in the exact-input direction, sets per-leg minimums and a
non-zero overall `minAmountOut`, passes `rebalanceNonce()`, and calls `burnToToken(BurnParams)` or
`burnToTokenWithPermit`.

**Weekly supply update.** The owner Safe proposes one batch of reference supplies a week (`proposeSupplies(tokens,
supplies)`, tokens in strictly ascending address order, each supply within 0.5% of the one in force). For 2 days the
guardian or owner can `cancelSupplies`; from then until 7 days later anyone can `executeSupplies`, which puts every
supply of the batch in force at once, or none. A larger revision goes in several weekly steps. At 0.5% a week an index
follows a token whose supply grows up to about 30% a year faster than the rest (1.005^52 − 1).

**Rebalance.**
1. Once 7 days have passed since the index's creation or last rebalance, anyone calls `startRebalance(0)`. The hub
   reads the reference supplies in force, computes each moving component's ratio `r_i` of units to supply (centred and
   clamped to `1 ± 0.5%`, see `ARCHITECTURE.md`), and stores `λmax = max r` and `λmin = min r`. If they are closer than
   `MIN_BAND` (0.1%) the call reverts `BandTooNarrow(λmin, λmax)`: the units already follow the supplies, which covers
   no supply changing, every supply changing alike, and a single moving component. A freshly created index has nothing
   to rebalance until a batch changes a supply.
2. For 2 days nothing changes. Holders who disagree can leave, and this notice is the window to do it in: once the
   auction opens, a public redeem can be overtaken by a fill (step 3). A batch executed during the notice or the
   auction does not move the pending settlement (R22).
3. A 24-hour auction follows. λ falls linearly from `λmax` to `λmin`, rounding up. An executor contract calls
   `executeRebalance(data)`: every moving component's units become `⌈λ × u / r⌉`, so a component whose ratio is above
   λ shrinks and one below λ grows. The executor receives what the index no longer needs of each shrinking component
   and, inside its `onXindexRebalance` callback, must send back what the growing components need. Both sides are
   recomputed from `totalSupply()` in the settling block, and issue and redeem stay open throughout, so an executor
   sizes itself from the callback's arguments. `executeRebalance(data, maxAmountsIn)` is the same settlement bounded:
   it reverts `RebalanceMovedOn(token, required, maxAmountIn)` when the index has come to need more of a component than
   the caller said it would deliver (DA-13). A fill that would send nothing out, as on an empty index, settles at
   `λmax`, where nothing shrinks and nobody is paid.
4. Executors compete the fill toward the break-even λ, where the index gives up exactly what it gets back at market
   prices. That λ always lies inside the band, whatever prices do. A lone executor that waits for the floor keeps
   `1 − λmin/λmax` of the moving value at most, 0.995% (see "Known limitations").
5. If nobody fills, the auction expires. The owner or guardian can start a fresh one at once; anyone else can 2 days
   after the auction's last second.
6. The owner or guardian can cancel a rebalance. Cancelling a live one makes others wait 2 days from the cancel to
   restart; cancelling one that already expired only clears it from the views, and the wait the expiry started stands
   (VR-04).

The fill can land in any block of the auction, and whoever holds shares in that block shares its outcome, so an
executor watching the mempool can put its fill ahead of a public redeem or guardian cancel; the zap's `expectedNonce`
makes such a burn revert, but only after the fill landed. Leave during the notice, or send the transaction through a
private relay (RT-02). Shares issued while a rebalance is pending share the outcome of any fill that lands after them,
however it is ordered.

**Rebalance around a frozen component.** The guardian cancels and starts again with the component's bit in `keepMask`;
that component keeps its units, its supply is not read, and the settlement neither transfers it nor reads its balance,
so the mask also routes around a component whose contract stops answering (DA-14, RT-01). The other components still
need a band of at least `MIN_BAND` between them.

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
  `Σ units_i / 10^decimals_i × price_i` from `components()` and the app's own prices: the design (section 10) uses the
  median of several exchanges and aggregators, drops sources more than about 2% from the rest, prices exactly the
  asset held (WBTC at WBTC's own market price), and marks a price older than about ten minutes as estimated. Never
  derive a price from `balanceOf(index)` and `totalSupply()`, and never use a thin DEX pool of the index token as an
  oracle.
- **Starting units.** `previewUnits(tokens, k)` returns `⌊k × referenceSupply / 1e36⌋` per token with the supplies in
  force; `createIndex` reverts `UnitsOutOfRange` unless each lies in `[MIN_RAW_UNITS, MAX_UNITS]`, and
  `InvalidComponentCount` outside 1 to `MAX_COMPONENTS` (100). Offer the one-click zap only up to about 35 components.
  Show `suppliesPending()` and the batch's eta before a creator signs: a batch that executes first changes the units
  and the address.
- **Names and symbols are not unique.** `createIndex` requires only that they are non-empty. The CREATE2 salt commits
  to the creator, the name, the symbol, the tokens and the units, so two look-alike indexes have different addresses:
  key every index by its address, show `creatorOf`, and mark a name or symbol an existing index already uses.
- **Rebalance status.** Show `lastRebalance + MIN_REBALANCE_INTERVAL`, and a "rebalance due" button when
  `canStartRebalance()` is true and `previewBand(0)` shows a band of at least `MIN_BAND`
  (`lambdaMax × 1e18 ≥ lambdaMin × (1e18 + MIN_BAND)`); a narrower band means there is nothing to rebalance and a start
  reverts `BandTooNarrow`. `canStartRebalance()` answers the whole timing predicate: the interval has passed, no auction
  is live (an auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`, so `pendingRebalance().eta == 0` on
  its own is the wrong test), and the waits after a cancel and after an unfilled auction are over. Those waits hold off
  everyone but the owner and guardian: `REBALANCE_DELAY` from the cancel of a live auction, and `REBALANCE_DELAY` from
  an unfilled auction's last fillable second, so after an expiry the owner and guardian have the start to themselves
  for `REBALANCE_DELAY` less one second (CR-I02). Read `canStartRebalance()` or the `restartAllowedAt` that
  `RebalanceCancelled` carries rather than computing either wait; `restartAllowedAt()` alone reflects cancels only
  (RT-08, RT-09).
- **During a rebalance.** In the notice, show `pendingRebalance()`, which returns `(eta, keepMask, lambdaMin,
  lambdaMax, ratios)`: a component whose ratio sits above the λ of a fill shrinks, one below grows. In the auction,
  show `currentLambda()` (0 outside an auction) and `previewRebalance()`, which returns `(lambda, units, amountsOut,
  amountsIn)` for this block. While a rebalance is pending, warn before a mint that the new shares share the coming
  settlement's outcome; during the auction, also warn before a burn that the fill can be ordered ahead of it, and that
  a private relay is the protection (RT-02).
- **Rebalance events.** `RebalanceStarted(proposalId, id, caller, keepMask, lambdaMin, lambdaMax, ratios, eta)`,
  `RebalanceCancelled(proposalId, caller, restartAllowedAt)` and `Rebalanced(proposalId, id, executor, lambda, units,
  amountsOut, amountsIn)`. `proposalId` counts every attempt on the index, so cancelled, expired and settled attempts
  can be told apart; `id` is the `rebalanceNonce` a settlement takes. Nothing is emitted when an auction expires
  unfilled: the next `RebalanceStarted` is the first sign.
- **Guardian duty.** During every notice period, recompute the band from the index's units and the reference supplies
  that were in force at the start (it should equal `pendingRebalance()`), check that the batch behind it was the one
  reviewed, and watch keep masks. The contracts cannot tell a mistyped supply from a real one; the guardian's
  `cancelSupplies` during a batch's 2 days and `cancelRebalance` during a notice are the checks.
- **Zap calls take a params struct.** `MintParams {index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to,
  deadline}` with `MintLeg {v3Path, v4Path, maxAmountIn}`, and `BurnParams {index, expectedNonce, shares, tokenOut,
  minAmountOut, legs, to, deadline}` with `BurnLeg {v3Path, v4Path, minAmountOut}`. `legs` has one entry per component,
  in component order. `expectedNonce` is `rebalanceNonce()` when the legs were quoted; after a rebalance, re-quote.
- **One venue per leg.** A leg carries a packed `v3Path` **or** a `v4Path`, never both. Both empty means "no swap",
  which is only valid for the pass-through leg, the one whose component already is the stable on a mint or `tokenOut`
  on a burn. Anything else is `BadRoute(i)`. There are no mixed-venue legs.
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
  call whose simulated gas exceeds about 14M. The in-kind path fits at 100 components (about 3.7M for `redeem`).
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
- **Show pending proposals.** A listing takes effect between `ListingProposed(token, eta, referenceSupply)`'s `eta`
  and 7 days later; a supply batch between `SuppliesProposed(batchId, eta, tokens, referenceSupplies)`'s `eta` and 7
  days later, all at once (`ReferenceSupplySet` for each token, then `SuppliesExecuted`); a new guardian after
  `GuardianProposed` plus 7 days. Ask `listingPending(token)`, `suppliesPending()` and `guardianChangePending()` whether
  a proposal can still be executed: an expired one leaves `listingEta`, the batch's eta in `pendingSupplies()`,
  `pendingGuardian` and `pendingGuardianEta` set, so those fields on their own read as pending forever (DA-16). Treat
  `GuardianProposed` as a security alert: once it executes, the owner's batches no longer face the old guardian's veto.
- **Returned components.** Whenever the router takes less than it was given, the unsold part goes to the recipient
  with a `ComponentReturned` event: every hop of a V3 burn leg, and as a rule only the first hop of a V4 burn leg,
  whose intermediate partial fill reverts the whole leg (CR-I07). A returned amount includes anything a stranger had
  left on the router, and a stray balance never makes a burn revert (CR-L02). Show them on the receipt.
- **ABIs.** `abi/IndexFactory.json`, `abi/IndexHub.json`, `abi/IndexZap.json` and `abi/MintRequests.json`, and for
  the hybrid product `abi/HybridIndexFactory.json` (the factory v4 launches on), `abi/IHybridIndex.json` (a hybrid
  index: its hub, module and extension answer at one address, so decode with this one interface) and
  `abi/XindexVault.json` (a vault on an EVM chain), are committed and regenerated by CI, which fails on a diff; decode every event and revert with them (`forge inspect <contract> abi --json` reproduces
  them, and the interfaces in `src/interfaces/` carry the NatSpec). Read the constants on chain rather than
  hard-coding them: `LISTING_DELAY`, `PROPOSAL_WINDOW`, `GUARDIAN_DELAY`, `MAX_COMPONENTS`, `MAX_BATCH`,
  `MAX_SUPPLY_STEP`, `MAX_SUPPLY`, `MIN_RAW_UNITS`, `MAX_UNITS`, `K_SCALE` on the factory, and
  `MIN_REBALANCE_INTERVAL`, `REBALANCE_DELAY`, `AUCTION_DURATION`, `MAX_SUPPLY_STEP`, `MIN_BAND` on the hub. Errors
  that several contracts raise (`ZeroAddress`, `LengthMismatch`, `Unauthorized`, `NotIndex`, `InvalidRecipient`) are
  declared once, in `IXindexErrors`.
- **Events.** `IndexFactory`: `IndexCreated`, `ListingProposed`, `ListingCancelled`, `ReferenceSupplySet`,
  `TokenWhitelisted`, `SuppliesProposed`, `SuppliesCancelled`, `SuppliesExecuted`, `GuardianProposed`,
  `GuardianChangeCancelled`, `GuardianSet`, `OwnershipTransferStarted`, `OwnershipTransferred`. `IndexHub`: `Issued`,
  `Redeemed`, `ClaimRecorded`, `Claimed`, `RebalanceStarted`, `RebalanceCancelled`, `Rebalanced`, and the ERC-20 events.
  `IndexZap`: `ZapMint`, `ZapBurn`, `ComponentReturned`.
- **Watch the ownership handover.** `transferOwnership(new owner)` emits `OwnershipTransferStarted` and
  `acceptOwnership()` emits `OwnershipTransferred`. It is the one admin change with no delay and no guardian veto.
- **Errors.** `IndexZap`: `NotIndex`, `StaleRebalanceNonce`, `Expired`, `ZeroAddress`, `ZeroAmount`, `InvalidRecipient`
  (the zap, the index, the Universal Router, the PoolManager or the factory, RT-21), `LegCountMismatch`, `BadRoute(i)`,
  `ShortFill(i, received, required)`, `InsufficientBudget`, `InsufficientOutput`, `TransferShortfall`. `IndexHub`:
  `NotFactory`, `NotInitialized`, `InvalidComponents`, `ZeroShares`, `ZeroAddress`, `InvalidRecipient` (also for a share
  transfer to the index itself or its factory), `InvalidSkipMask`, `NothingToClaim`, `TransferAmountMismatch`,
  `Unauthorized`, `RebalanceTooSoon`, `RebalancePending`, `InvalidKeepMask`, `BandTooNarrow(lambdaMin, lambdaMax)`,
  `NoPendingRebalance`, `RebalanceNotReady`, `RebalanceExpired`, `RebalanceUnderfunded`, `RebalanceMovedOn`,
  `LengthMismatch`, and OpenZeppelin's ERC-20 and ERC-2612 errors. `IndexFactory`: `EmptyString`,
  `InvalidComponentCount`, `TokenNotWhitelisted`, `DuplicateToken`, `UnitsOutOfRange(token, units)`,
  `IndexAlreadyExists`, `NotAContract`, `AlreadyListed`, `NotConfigured`, `SupplyOutOfRange(token, referenceSupply)`,
  `SupplyStepTooLarge(token, inForce, proposed)`, `ListingPending`, `NoPendingListing`, `ListingNotReady`,
  `ListingExpired`, `NotWhitelisted`, `SuppliesPending`, `TokenInBatch`, `InvalidBatch`, `NoPendingSupplies`,
  `SuppliesNotReady`, `SuppliesExpired`, `NoPendingGuardianChange`, `GuardianChangeNotReady`, `GuardianChangeExpired`,
  `Unauthorized`, `LengthMismatch`, `RenounceDisabled`, and OpenZeppelin's `Ownable` errors.
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
component that can be paused or blacklisted, such as WBTC, must be labelled in the app. How a token's own supply is
minted does not matter, since nothing reads it: a wrap, an unwrap or an issuer's mint moves nothing the hub reads
(CR-M01).

**Reference supply.** Every listed token carries one, in its raw units, from 1 to `MAX_SUPPLY` (`uint128.max`): the
circulating supply of what the token represents. WBTC carries bitcoin's and WETH ether's, because their on-chain
supply is only the wrapped float. Each figure in `script/MainnetAddresses.sol` carries its source and date.

**Listing.** `proposeListing(token, referenceSupply)`, owner only, starts `LISTING_DELAY` (2 days); from then until
`PROPOSAL_WINDOW` (7 days) later anyone can `executeListing`, which sets the supply and whitelists the token; after that
the proposal expires. Until it executes, the owner or guardian can `cancelListing` it. A listed token cannot be proposed
again (`AlreadyListed`): its supply changes only in a batch. Either role can `delist` a token at any time. Delisting
affects only indexes created afterwards and keeps the reference supply, because existing indexes still rebalance with
it; a batch can still revise it. Relisting takes a fresh proposal and delay at exactly the supply the token carries
(`RelistChangesSupply`, SA-02), and is refused while the live batch names the token (`TokenInBatch`). A first listing is
bounded only by `MAX_SUPPLY` and by review.

**Supply batches.** `proposeSupplies(tokens, supplies)`, owner only: 1 to `MAX_BATCH` (200) tokens in strictly
ascending address order, each already carrying a supply and none with a live listing, each new supply within
`MAX_SUPPLY_STEP` of the one in force (`|new − old| ≤ ⌊old × 0.005⌋`). One batch is live at a time. It executes all or
nothing, because a stranger who could execute half of a batch and start a rebalance on the half would turn a uniform
revision, which trades nothing, into a trade. A batch comes due `LISTING_DELAY` after its proposal and never sooner than
`MIN_SUPPLY_INTERVAL` (7 days) after the last batch executed, so a supply moves at most half a percent a week, on chain
and not only by policy (SA-04). `lastSupplyUpdate()` says when the last one executed.

## Stage A list: supplies and execution depth

Four components, the Ethereum tokens of the design's 0.2% weight floor that pass its liquidity screen (daily volume at
least 0.1% of market cap). `ConfigureWhitelist.defaultMainnetList()` ships them in this order:

| Token | Reference supply | Source |
|---|---|---|
| WETH | 122,070,499 ETH (`122_070_499e18`) | ether's circulating supply, CoinGecko, 2026-09-22 |
| WBTC | 20,087,871 BTC (`20_087_871e8`) | bitcoin's circulating supply, CoinGecko, 2026-09-22 |
| LINK | 748,099,970 LINK (`748_099_970e18`) | circulating, CoinGecko, 2026-09-22 |
| UNI | 620,716,422 UNI (`620_716_422e18`) | circulating, CoinGecko, 2026-09-22 |

- **WBT** (WhiteBIT's token) is on the design's floor list by weight but **stays off** (the owner's call on 2026-09-30,
  `design/2026-09-30-wbt-check.md`): its Ethereum contract lets a single key blacklist any holder and destroy its
  balance, and no Uniswap V2, V3 or V4 pool holds it. Without it the Stage A list covers 79.4% of the holdable top-100
  value at 4.2% a year of tracking error, on a backtest that held supplies constant and so understates it.
- **Left out.** v3's wstETH (a second claim on ether), wSOL (native SOL comes with Stage B) and AAVE (below the floor).
  LEO is on the floor list by weight but fails the liquidity screen.
- **Depth, measured on 2026-09-22.** LINK is deeper on V4 than V3 (about 6.6x); WBTC (0.26x) and UNI (0.66x) are
  deeper on V3. The app picks the venue per leg. Live V4 pools for these components are paired against native ether,
  not WETH.

## Known limitations

- **A lone executor can take up to the band.** A fill at λ leaves holders at least `λ / λmax` of the moving value at
  any prices, so an executor with no competition that waits for the floor keeps at most `1 − λmin/λmax` of it:
  0.995% when the clamp binds on both sides. How much of that it actually takes depends on where the break-even λ sits,
  which is a value-weighted average of the ratios: on a mainnet fork, a batch raising WBTC's supply 0.5%, cutting
  LINK's 0.5% and raising UNI's 0.3% gave a band of [0.995, 1.005] and a break-even of 0.99585 at real Uniswap quotes,
  and a fill at the floor cost the basket 0.085% (103,868.93 to 103,780.31 USDC for 1,000 index tokens). By the same
  formula, the opposite revision would put the break-even near the top, with most of the band within reach. Weekly, the
  worst case is about 0.11% a day, since a rebalance cycle takes at least 9 days; if every cycle's supplies moved the
  full step apart and no executor ever competed, about 33% a year (design section 6.6). The notice lets holders leave, the guardian can cancel a rebalance
  nobody competes for, and competition settles near the break-even.
- **A far-off component holds the others at the band's edge.** The clamp heals the extremes first: while one
  component's units sit more than the band away from its supply, every other moving component settles at the opposite
  bound, and their own revisions wait until the far one has converged. Nothing is taken beyond the band. Weekly steps
  of half a percent against up to 1% of correction a cycle keep that rare; a keep mask held over several cycles is the
  usual cause (SA-08).
- **The band covers the whole moving value, however small the trade.** A 0.5% revision of a component weighing 1% of
  an index trades about 0.005% of the index, yet opens a 0.5% band over everything that moves, so a lone executor can
  take up to about 0.5%. A price-free scalar auction cannot tell a small trade from a large one. Whether a price-free
  design can bound the exposure by the trade's size is an open question (design section 15).
- **Reference supplies are data the owner maintains.** The contracts cannot tell a mistyped or stale figure from a
  real one. What bounds a slip is the step: after a first listing a supply moves at most 0.5% per batch, each batch
  behind 2 days of notice and the guardian's veto, and each rebalance at most the clamp however many batches landed.
  The same bound makes a slip slow to undo: a figure 10% off takes about 20 weekly batches to walk back. A first
  listing is bounded only by `MAX_SUPPLY` and review, so check its figure while it can still be cancelled. Between
  updates, a token whose real supply grows faster than 30% a year relative to the rest stays underweight.
- **A due proposal takes effect when someone executes it.** Listings and batches are permissionless to execute once
  due, so between a batch's eta and its execution whoever acts first decides whether a rebalance started in between
  reads the old supplies or the new; both were reviewed, which bounds it. Execute a due batch promptly.
- **Rebalances clear only when the moving value pays for the fill.** Small indexes on mainnet rarely rebalance. An
  unfilled auction expires, and for `REBALANCE_DELAY` afterwards (less a second, CR-I02) only the owner and guardian
  can restart it. An index so small that a settlement moves no raw unit settles at `λmax` whoever executes; one that
  still moves a few raw units lets a lone executor pick λ within the band for next to nothing, which moves units within
  the band but no holder's value beyond rounding. Units per rebalance stay within `[λmin/λmax, λmax/λmin]` plus one
  raw unit, so a component held at a single raw unit can settle at two (CR-I03).
- **An exit sent during the auction can be overtaken by the fill.** The executor picks the block, so it can order its
  fill ahead of a redeem or a guardian cancel it sees in the public mempool. No bound moves, but the notice is the only
  reliable window to leave; during the auction, use a private relay (RT-02). Shares minted while a rebalance is pending
  share the outcome of any fill that lands after them, whatever the ordering.
- **The guardian can stall rebalancing.** `cancelRebalance` has no window and no rate limit, so a hostile or
  compromised guardian can cancel each proposal at the last second of its auction and hold rebalancing off while the
  units drift from the supplies. It moves no funds, holders redeem throughout, and the owner ends it by replacing that
  guardian: 7 days of notice the guardian cannot cancel, since it may only cancel its own removal (DA-12). A guardian
  can also stall without a cancel: a keep-mask rebalance that leaves a pair of components moving can clear `MIN_BAND`
  on a sliver of the index, and its fill restarts `MIN_REBALANCE_INTERVAL` for everyone, so the stall can outlast the
  guardian's replacement by up to a week. While a replacement is pending, the owner cancels the outgoing guardian's
  keep-mask proposals, and monitors alert on `RebalanceStarted` with a non-zero `keepMask` (RT-07).
- **Issuers can freeze components.** WBTC can be paused by its custodian. A paused component makes `redeem`, the zap
  and any fill that moves it revert; `redeemSkipping`, `claim` and the guardian's keep mask are the recourse, and a
  permanently frozen component needs the keep mask at every rebalance.
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
- **No fees.** Audits, a bug bounty and watchers are paid from outside (the owner's call on 2026-09-30).
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
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`). Re-check before deploying to any other chain.

## Mainnet addresses

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
| HybridIndexFactory / IndexZap / MintRequests | not deployed |

The scripts read mainnet addresses and reference supplies from `script/MainnetAddresses.sol`, which
`test/fork/MainnetAddresses.fork.t.sol` checks on-chain: tokens by symbol and decimals, the router and the PoolManager
by their runtime code hashes (every Universal Router build answers `poolManager()` alike, CR-I35), and the default list
on a fresh factory. The quoters and StateView are for apps and tests; no contract reads them.

## Development

```bash
forge build --sizes
forge fmt
forge test                      # unit, fuzz, invariant and security regression tests, no RPC needed
forge coverage                  # 100% on every file

# end-to-end against the real Universal Router, V3 and V4 pools, USDC, USDT and a real WBTC pause
# (skipped when the env var is unset)
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# non-archive RPCs only serve recent state; override the pinned block:
MAINNET_RPC_URL=https://... FORK_BLOCK=<recent block> forge test --match-path 'test/fork/*'
```

CI (`.github/workflows/test.yml`) checks that every submodule commit matches `foundry.lock`, then runs fmt, build,
`forge lint -D notes`, tests, 100% coverage on every file (offline suites), the ABI diff and the Wake detectors on
`src/`, with pinned Foundry and Wake versions. Pushes to `main` and pull requests into it from this repository fail
until a `MAINNET_RPC_URL` repository secret exists, so the fork tests always run there; it needs an archive node for the
pinned fork block. Pull requests from forks get no secrets and skip the fork suites, so re-run them before merging. A
keyed RPC may throttle four fork suites run in parallel; run them with `-j 1` when a revert appears next to an HTTP 429.

### Deploy

Nothing below has been run for v4. Never put a private key in `.env`. Import the deployer key once into an encrypted
keystore, or use a hardware wallet with `--ledger`:

```bash
cast wallet import deployer --interactive
cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
source .env
forge script script/Deploy.s.sol --rpc-url mainnet --account deployer --sender <deployer address> --broadcast --verify
```

`Deploy` deploys v4's one factory, `HybridIndexFactory`, and with it both templates: the factory deploys the `IndexHub`
implementation itself, and the `HybridHub` template, its module and its extension come first, each built for the
factory's address, which the script predicts from the broadcaster's nonce (the factory refuses a template built for any
other). An index of Ethereum tokens only is an `IndexHub` clone; one holding any vault token is a `HybridHub` clone. Then
come the zap, which mints and burns `IndexHub` clones only (a hybrid index's mints are orders, and a zap call on one
reverts with nothing moved), and `MintRequests`, which takes any index's shares. Vault chains and vault-token listings
are proposed afterwards, through the factory's timelock.

`OWNER` and `GUARDIAN` are required and must differ. On mainnet the owner must be a contract that is not an EIP-7702 delegated account, and a Safe
must need at least three signatures (`MIN_OWNER_THRESHOLD`, the design's 3-of-5) and have no enabled module, because
a module acts as the Safe without signatures
(keep it that way after deployment; the script cannot see later changes). The guardian must not be the broadcasting
key, which must hold no role; when the owner is a Safe, neither the guardian nor the broadcasting key may be one of
its signers, since the guardian is the owner's veto (SA-06); and neither role may be a market contract: the router and its PoolManager everywhere, and
on chain 1 also every token and mint currency in `script/MainnetAddresses.sol` (CR-I37). `UNIVERSAL_ROUTER`, `USDC`
and `USDT` default to mainnet's on chain 1, where any other value is rejected, and are required anywhere else; they are
the script's only market addresses, because the hub and factory depend on no Uniswap contract.

**Deployment record.** `forge script --broadcast` writes `broadcast/Deploy.s.sol/<chain id>/run-latest.json`: the git
commit, each transaction with its init code, and the addresses. Broadcast from a clean, committed tree
so the recorded commit is the deployed source, commit the record with the README address table (on mainnet with `git
add -f`: `.gitignore` keeps chain-1 records out, because fork rehearsals keep chain id 1), and verify the source on the
explorer (`--verify` needs `ETHERSCAN_API_KEY`). The deploy log ends with the runtime code hashes of the factory, the
`IndexHub` implementation, the `HybridHub` template, its module, its extension, the zap and `MintRequests`: record them
with the addresses, and
`Deploy.checkDeployment(factory, zap, requests)` re-reads them later (it also refuses a zap or a `MintRequests` that
does not point at that factory).

**A vault chain** (BNB Chain, Avalanche C-Chain, HyperEVM) is set up with `script/DeployVault.s.sol`, on that chain:
P1's verifier on SP1's Groth16 verifier, P2's on RISC Zero's, the state reader and the vault, with its `VaultSnapshot`
library. It refuses any Groth16 verifier but SP1's v6.0.0 (`VERIFIER_HASH`) and RISC Zero's 3.0.0 (`SELECTOR`
`0x73c457ba`, its published control ids), so an owned gateway, router or emergency stop is refused; it refuses a
deployment on the indexes' own chain, a missing key or anchor, a freezer or recovery multisig that is unset, shared,
the broadcasting key or, for the multisig, not a contract, and a floor above the cap. Its environment variables are
listed in the script; the anchor and P1's key come from `proofs/` (`p1-input check-state`, `p1 vkey`) and P2's image
id from `proofs/p2` (`p2 image-id`). `DeployVault.checkDeployment` re-reads the wiring and the code hashes later. TRON
is deployed with its own tooling (`tron/`), and the chain is then proposed on Ethereum (`proposeChain`).

**Listings and supply batches** go through `script/ConfigureWhitelist.s.sol`, or the equivalent calls through the Safe:

```bash
# owner is a key you hold (testnets and local forks only; a contract owner such as the mainnet Safe cannot sign, and
# the broadcasting modes then revert with OwnerIsContract: use the safe modes)
LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> LIST=<tokens to list> forge script script/ConfigureWhitelist.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
# owner is a Safe: print the listing proposals as calldata to sign in the Safe app (nothing is broadcast);
# LIST=all on the launch run only, and unset on every later run
LISTING_MODE=safe FACTORY=0x... WHITELIST=default LIST=all forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
# every week: this week's supplies as one proposeSupplies call for the Safe
LISTING_MODE=supplies-safe FACTORY=0x... WHITELIST=<this week's entries> forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account: execute every due listing, or the due batch
LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
LISTING_MODE=execute-supplies FACTORY=0x... WHITELIST=<same entries> forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`LISTING_MODE` is one of `propose`, `safe`, `execute`, `supplies`, `supplies-safe`, `execute-supplies` and `status`.
`WHITELIST` is `default` for the mainnet list above (chain 1 only), or comma-separated `token:referenceSupply` entries,
both fields required, the supply in the token's raw units; anything else reverts `MalformedEntry`, and a list that
names a token twice reverts `DuplicateEntry` in every mode (RT-24).

- **Propose and safe** propose a listing for each entry that is not listed and has no live proposal, skipping with the
  reason logged: a token never listed unless `LIST` names it (`LIST=all` for every entry), a delisted token unless
  `RELIST` names it, a token the live supply
  batch names (the factory would refuse it with `TokenInBatch`, DA-20), and any entry outside the policy the script can
  check (a token with code and 6 to 18 decimals, no USDC or USDT, a supply from 1 to `MAX_SUPPLY`). Safe mode applies
  the same checks, because a Safe batch sends every proposal in one transaction and one the factory refuses takes the
  rest down with it (CR-I38). Nothing on chain records that the guardian cancelled a first listing, so leave `LIST`
  unset on a routine run and a cancelled listing stays cancelled until the operator names it again (RT-06). Each
  proposal is logged with the token's symbol (a symbol that is not an ABI string shows as `?`, RT-25) and its supply
  in whole tokens, where a decimals slip shows: read both before signing. A relisting proposes the supply the token
  carries, whatever the entry says, and the entry's figure goes in the next batch (SA-02).
- **Supplies and supplies-safe** build the week's batch: every entry whose token carries a supply other than the
  entry's, sorted by address, skipping with the reason a token never listed, one with a live listing, one outside the
  policy, and one whose new supply is more than one step away (a larger revision goes in weekly steps). With nothing
  to batch they revert `NothingToBatch`, and while a batch is still live `BatchStillLive`, since the factory would
  refuse a second one and this week's would be measured against supplies about to change (SA-05).
- **Execute and execute-supplies** never propose. They run only a due proposal whose supply is exactly the entry's,
  and log why a pending one was left: not ready, expired, or a supply the entries do not name.
- **Status** is read-only: for every entry, whether the token is listed, whether the supply in force is the entry's,
  any pending listing with its window, and whether the live batch names it.

In the Safe app, a safe mode's output becomes one Transaction Builder batch: each calldata line is one transaction to
the factory with value 0, under a label line naming the call and the token. Two signers sign it, and one executes it.
For a local stack, `anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against `http://127.0.0.1:8545`; the
fork keeps chain id 1, and `.gitignore` keeps those rehearsal records out of git. An ignore rule does not cover a file
git already tracks, so check `git status` after a rehearsal.

### Operations runbook

No bot runs Xindex, so these duties have owners and deadlines. Watch the events that start each clock.

| Duty | Starts with | Deadline | Who | How |
|---|---|---|---|---|
| Propose the weekly supply batch | the weekly review | none, but an index drifts from real supplies meanwhile | owner Safe | new dated figures in the entries, `LISTING_MODE=supplies-safe`; each supply within 0.5% of the one in force, larger moves in weekly steps; it comes due a week after the last batch executed at the earliest |
| Veto a wrong batch or listing | `SuppliesProposed`, `ListingProposed` | before `eta` (2 days) | guardian or owner | check every figure against its source; `cancelSupplies()` or `cancelListing(token)` |
| Execute a batch or listing | its `eta` | `eta + PROPOSAL_WINDOW`, or it expires silently | anyone, owner signers first | `LISTING_MODE=execute-supplies` or `execute` at the eta; `suppliesPending()` and `listingPending(token)` say whether it can still run |
| Trigger the weekly rebalance | `lastRebalance + MIN_REBALANCE_INTERVAL`, after a batch changed a supply | none, but units drift from the supplies | anyone | `canStartRebalance()` and `previewBand(0)`, then `startRebalance(0)`; `BandTooNarrow` means there is nothing to rebalance |
| Check each rebalance | `RebalanceStarted` | before `eta` (2 days) | guardian | recompute the band from the units and the supplies in force, confirm the batch behind it was the reviewed one; `cancelRebalance()` on a mismatch |
| Watch keep-mask rebalances | `RebalanceStarted` with a non-zero `keepMask` | before `eta` | owner signers | while a guardian replacement is pending, cancel the outgoing guardian's keep-mask proposals (RT-07) |
| Fill auctions | the auction opens at `eta` | `eta + AUCTION_DURATION` | any executor contract | the protocol runs none; competition is what keeps a fill near the break-even |
| Rebalance around a frozen component | a paused or blacklisting component | each auction | guardian | `cancelRebalance()`, then `startRebalance(keepMask)` |
| Restart after an unfilled auction | `eta + AUCTION_DURATION` passed with no `Rebalanced` | anyone after `REBALANCE_DELAY` more | guardian first, then anyone | `canStartRebalance()`, then `startRebalance(0)` |
| Re-check venue depth per leg | monthly, and before a large mint or burn | none | app | V3 and V4 depth move independently; the route is the app's choice |
| Watch guardian changes | `GuardianProposed` | `eta` (7 days) | owner signers, guardian, app | a security alert: once executed, the new guardian's veto replaces the old one. `guardianChangePending()` says whether it is still executable |
| Hand over factory ownership | `OwnershipTransferStarted` | none: it takes effect as soon as the new owner accepts | owner signers, then the new owner | the one admin change with no delay and no veto; announce it first, and the new owner has to meet the rules the deploy script checks |

### Testnet (Sepolia)

**v4 is not deployed on Sepolia.** v3 runs there, deployed on 2026-09-27 from `4b4dbe4`, the commit tagged `v3.0.0`;
nothing in this branch can drive it, since its factory takes feed configs. The `broadcast/*/11155111/` records belong
to that line.

`script/testnet/SetupTestMarket.s.sol` deploys stand-ins for USDC, WBTC, LINK and UNI as `FaucetToken`s, where any
account can `drip()` a small amount once a day, each with a Uniswap V3 WETH pool at a mainnet-like price so the zap has
a V3 route to swap through. Nothing in Xindex reads those pools' prices. `create` logs the `WHITELIST` entries for
`ConfigureWhitelist`: tWBTC, WETH, tLINK and tUNI, with the mainnet reference supplies. Faucet tokens have no value and
their supply grows with every drip, which is irrelevant here because nothing reads a supply live.

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
| HybridIndexFactory / IndexHub implementation / HybridHub template, module, extension / IndexZap / MintRequests (v4) | not deployed |

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
DEPLOYER=$(cast wallet address --account sepolia-deployer)

# 1. tokens and priced pools, then liquidity in a later block: 0.3 WETH in the tUSDC pool, 0.1 in each other
MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
MARKET_MODE=seed MARKET_TOKENS=<logged by create> forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 2. the factory with both templates, the zap and MintRequests; the test market has no USDT, so USDT is any second
#    6-decimal test token,
#    a FaucetToken for instance
OWNER=<Safe> GUARDIAN=<guardian> UNIVERSAL_ROUTER=0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b \
  USDC=<tUSDC logged by create> USDT=<a second test stablecoin> \
  forge script script/Deploy.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 3. print the listing proposals and sign them as one batch in the Safe app
LISTING_MODE=safe FACTORY=<factory> WHITELIST=<logged by create> LIST=all forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia

# 4. 2 to 9 days later, from any account
LISTING_MODE=execute FACTORY=<factory> WHITELIST=<same> forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
```

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts, so testers can call `drip()` from Etherscan.
`USD_POOL_WETH` and `TOKEN_POOL_WETH` (in wei) change the liquidity `seed` adds. Timing is mainnet's: listings and
batches take 2 days, and a rebalance can start 7 days after an index's creation, once a batch has changed a supply,
followed by 2 days of notice and a 24-hour auction. The test pools are shallow and nobody arbitrages them, so zap
prices on this market say nothing about mainnet. `test/fork/RebalanceExecutorV3.sol` fills auctions through
SwapRouter02; it is a test fixture without slippage limits, so never fund it on mainnet.

## Layout

```
src/IndexHub.sol              index implementation (ERC20 + permit, in-kind issue, redeem, redeemSkipping, claim, λ rebalance), cloned
src/IndexFactory.sol          listings, reference supplies and weekly batches, guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              Universal Router mint/burn router, one venue per leg, per-leg limits, nonce check
src/MintRequests.sol          ownerless escrow of USDC/USDT-for-shares requests at the requester's own limit
src/interfaces/               IIndexHub, IIndexFactory, IIndexZap, IMintRequests, IXindexErrors, IRebalanceExecutor, IUniversalRouter
src/libraries/                PathLib, and UniversalRouterCommands and UniswapV4Types (vendored)
test/*.t.sol                  unit, fuzz, invariant, script and repository tests
test/Security.t.sol           regression tests for the security review findings (some ids are tested elsewhere; see AGENTS.md gate 6)
test/mocks/                   mock tokens, a strict Universal Router, V3 pools for the testnet script, the market fixture, with their own tests
test/fork/                    mainnet fork tests: real V3 and V4 pools, λ rebalancing and security regressions on real tokens
script/                       Deploy, ConfigureWhitelist, MainnetAddresses, ScriptUtils, and the interfaces the scripts call
script/testnet/               SetupTestMarket and FaucetToken for the Sepolia test market
design/                       the v4 design (and its PDF), the Stage A spec, the PDF builder and the analysis scripts
audit/                        the security reviews, their triage, and the two retirement records
```

## Not in Stage A (candidates for later)

Vaults and the native coins of other chains (Stage B and C, see `ARCHITECTURE.md`), a fee in a later index version, ETH in/out (`mintWithETH` / `burnToETH`), `createAndMint` in one call,
`mintWithTokenPermit` for USDC, constituent changes (a new list is a new index version), mixed-venue legs that split one
leg across V3 and V4, a backstop executor or trigger reminder, an aggregator or Universal Router 2.1 zap, V4 pools on
the Sepolia market, and an auction whose exposure scales with the trade rather than the moving value.
