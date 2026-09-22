# Xindex Architecture

Xindex turns a portfolio of on-chain tokens into a single ERC-20 index token. Anyone can create an index, anyone can
mint it with USDC or USDT, and anyone can burn it back into USDC, USDT, WBTC, or any other token with Uniswap V3 or V4
liquidity. Every index is fully backed, in kind, by the tokens it represents. Its constituents never change; its units
follow an on-chain market-cap rule that anyone can trigger once a month. No admin can touch user funds, and no
protocol key or bot is involved in rebalancing.

## 1. Goals and constraints

| Requirement (from the product brief) | How it is met |
|---|---|
| Create a portfolio as one ERC-20, any name/symbol | `IndexFactory.createIndex` deploys an `IndexToken` clone with free-form name and symbol |
| Others can mint the same index | `issue` / `mintWithToken` are permissionless |
| Decentralized | No custody, no pause, no upgrade, no rebalancing key; listings and token data configs activate after a public 2-day delay |
| Mint and burn | In-kind `issue` / `redeem` on the token; USDC/USDT convenience via the zap |
| Trade the index into other coins | Standard ERC-20 (transferable, listable) plus `burnToToken` into any token |
| USDC/USDT in, USDC/USDT out | Zap mints from either stable; burner chooses the payout token |
| Rebalancing and index price (the Numbers model) | Uncapped or capped (30/20) market-cap weights computed on-chain from supplies and Chainlink USD prices; settlement through an oracle-free auction; the index price is the basket's value in dollars |
| Layer-1 coins | Only tokens that exist on mainnet can be components (wrapped BTC, ETH, ...) |

Decisions fixed for v3: Ethereum mainnet, Chainlink USD feeds for prices, Uniswap's Universal Router (V3 and V4) for
execution, fixed constituents with rule-rebalanced units, two methodologies, no protocol bots or hot keys, no fees,
whitelist only. The first two supersede v2's "Uniswap V3" for both jobs; section 4 says why.

## 2. Components

```
                  createIndex(name, symbol, tokens[], units[], methodology)
   creator ────────────────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexToken (ERC-20)
                                                                  │ listings + token configs      │ holds the basket
                                                                  │ (2-day delay), guardian,      │ issue / redeem in kind
                                                                  │ registry                      │ redeemSkipping / claim
                                                                  └──deploys──► IndexRule ◄───────│ start / cancel /
   anyone ── startRebalance ────────────────────────────────────────────────── (supplies,        │ executeRebalance
   executor ── executeRebalance ◄── flash-style callback ─────────────────────── Chainlink USD   │
                                                                                 prices,         │
                                                                                 weights, price) │
                                                                                      ▲          │
                                                                              Chainlink feeds    │
                                                                            (CompositeFeed for   │
                                                                             WBTC = BTC x WBTC)  │
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4  │
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                              │
                                      └──────── issue() / redeem() ───────────────────────────────┘
```

### IndexToken (`src/IndexToken.sol`)

The index itself. An EIP-1167 clone of one implementation, using OpenZeppelin's upgradeable ERC20 and ERC20Permit
(clones skip constructors, so name and symbol are set in `initialize`).

- **State:** `Component[] {address token; uint96 units}`. The token list is fixed at `initialize`; only
  `executeRebalance` changes units. `units_i` is the raw amount of component `i` (in that token's own decimals) backing
  one whole index token (`1e18` shares). Open claims live in `claimOf[account][token]`, and their sum per token in
  `totalClaims[token]`. Rebalancing adds the pending proposal (`eta`, `keepMask`), the snapshot `_targetUnits`,
  `rebalanceNonce`, `lastRebalance`, `restartAllowedAt` and the `methodology` id.
- **issue(shares, to):** computes `ceil(shares * units_i / 1e18)` per component, mints, emits, then pulls each component
  from `msg.sender` and reverts unless the balance grew by at least that amount (rejects fee-on-transfer tokens).
- **redeem(shares, to):** computes `floor(shares * units_i / 1e18)`, burns, emits, then pushes every component.
- **redeemSkipping(shares, to, skipMask):** the same, except each component whose bit is set in `skipMask` stays in the
  index and is recorded as a claim for `to`, the account that receives every other component of the same redemption.
  Claims are booked before any token moves. Booking them to `msg.sender` stranded the skipped components whenever a
  router redeemed on a holder's behalf, because only the router could ever collect them (the deep audit's DA-17,
  2026-09-19).
- **claim(token, to):** pays `msg.sender`'s claim on `token` and clears it.
- **startRebalance(keepMask):** anyone, once `MIN_REBALANCE_INTERVAL` (28 days) has passed since the last executed
  rebalance or creation and no unexpired rebalance is pending. Asks `IndexRule.targetUnits` for the snapshot, requires
  at least `MIN_TURNOVER` (0.5%) of traded value, stores the targets and opens `REBALANCE_DELAY` (2 days) of notice. A
  non-zero `keepMask`, and any start during the `REBALANCE_DELAY` cooldown that follows a cancel or an auction that
  expired unfilled, needs the factory owner or guardian. `canStartRebalance()` is that whole condition as one view, for
  apps and for anyone checking whether an index is due; it answers false on an uninitialized clone, which holds no
  components and could never rebalance.
- **cancelRebalance():** factory owner or guardian. Clears the proposal and starts a `REBALANCE_DELAY` cooldown during
  which only they can start a new one.
- **executeRebalance(data):** during the `AUCTION_DURATION` (24 hours) after the notice. The multiplier falls linearly
  from `AUCTION_START_MULTIPLIER` (1.5) to `AUCTION_END_MULTIPLIER` (0.9), rounding up; a settlement that sends nothing
  out, as on an empty index or one whose supply is too small to move a raw unit, is priced at 1 instead, because the
  auction has nothing to pay for and the new units should not depend on timing. A shrinking component moves straight to
  its target; a growing one gains its extra units times the multiplier, rounded up. Transfer amounts are the change in
  required backing, `floor(supply * units / 1e18)` before and after, so they depend only on supply and units. In order:
  read what the index holds, write the new units, bump the nonce, clear the proposal, emit `Rebalanced`, send the
  shrinking amounts to `msg.sender`, call `IRebalanceExecutor.onXindexRebalance` on it, and revert with
  `RebalanceUnderfunded` unless every component then satisfies the invariant with the new units *and* the index holds
  the whole of `amountsIn` on top of what it held before. Surplus the index already had, from rounding or a donation,
  therefore stays with the holders instead of paying for part of the fill. A component that neither sends nor receives
  anything is not read at all, not even for its balance: both amounts are the change in its required backing, so both
  being zero means the requirement and the balance are unchanged and the invariant holds from before. A keep mask
  therefore routes around a component whose `balanceOf` reverts as well as one whose `transfer` does (DA-14).
- **executeRebalance(data, maxAmountsIn):** the same settlement, bounded. It reverts `RebalanceMovedOn` when the index
  needs more of a component than the caller said it would deliver. The amounts are recomputed from `totalSupply()` in
  the block that settles, and issue stays open through the notice and the auction, so anyone can enlarge a fill with a
  dust issue between an executor's simulation and its transaction, then redeem again. An executor that sources from the
  callback's arguments is unaffected, because `amountsOut` and `amountsIn` scale together and those arguments are the
  authoritative figures; one that funded itself from an off-chain quote uses this overload (DA-13). The unbounded
  `executeRebalance(data)` is unchanged.
- **Views:** `components()`, `componentTokens()`, `componentCount()`, `previewIssue`, `previewRedeem`, `claimOf`,
  `totalClaims`, `previewTarget(keepMask)`, `pendingRebalance()`, `currentMultiplier()`, `previewRebalance()`. The token
  has no price function.
- **Access:** `initialize` is callable only by `FACTORY` and only once; the implementation has initializers disabled.
  `issue`, `redeem`, `redeemSkipping`, `startRebalance`, `cancelRebalance` and `executeRebalance` revert with
  `NotInitialized` on anything but an initialized clone. A recipient can never be the zero address or the index itself.
- **Reentrancy:** storage-based `ReentrancyGuard` on every function that mints, burns, pays a claim or changes a
  rebalance: `issue`, `redeem`, `redeemSkipping`, `claim`, `startRebalance`, `cancelRebalance` and both
  `executeRebalance` overloads. The ERC-20 entry points, `transfer`, `approve` and `permit`, are deliberately
  unguarded, as section 5 says. The guard's namespaced slot reads as "not entered" when zero, so it works in a clone
  without initialization.

Invariant, for every component, forever:

```
token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
```

Ceil-on-issue and floor-on-redeem mean rounding drift is at most one raw unit per call, always in favour of remaining
holders. A claim is recorded only for an amount that stayed in the index, and because `floor(a) + floor(b) <= floor(a +
b)`, burning shares always frees at least that much required backing, so claims never dilute anyone. A rebalance sends
out exactly `floor(S * u / 1e18) - floor(S * n / 1e18)` of a shrinking component, so the invariant with the new units
`n` holds if it held with the old units `u`, and the post-check enforces it for growing components. Nothing is computed
from balances, so there is no share price to manipulate and no first-depositor attack. Donations only add surplus that no
holder can redeem, and a rebalance executor cannot use it to cover part of a fill either: the settlement check asks for
the whole of `amountsIn` on top of what the index held. The rule rounds the same direction: a target's share of value
rounds up into whole raw units, so the basket a rebalance aims at is never worth less than the basket it replaces.

### IndexRule (`src/IndexRule.sol`)

A stateless, view-only contract the factory deploys in its constructor. It never moves funds.

- **Prices:** dollars per 1e18 raw units of a token ("WAD prices", 1e18 = $1), from the Chainlink-shaped USD feed the
  token's config names. One private `_price` is the whole path, and every caller takes it: the feed must be non-zero,
  its answer positive, its `updatedAt` neither in the future nor older than that token's `maxStaleness`, and the feed's
  and token's decimals at most 18 and read live on every call. The answer is scaled to WAD by
  `answer * 10 ** (36 - feedDecimals - tokenDecimals)` and refused above `MAX_PRICE` (1e56, which puts one raw unit at
  1e20 dollars — far past any real asset, and inside the 256-bit proof under "Overflow"). Nothing is special-cased:
  WETH is an ordinary token with ETH/USD and ether's reference supply, and the rule reads no Uniswap contract at all.
  A product of two feeds goes in `CompositeFeed`, not in the rule.
- **Supplies:** a token's reference supply, or its own total supply. A config once carried a list of excluded holders
  that the rule subtracted as live balances inside the snapshot; one exclusion a stranger could fund and drain would
  have moved that component's market cap within a single transaction, so the list is gone and a supply that has to
  leave holdings out uses a reference figure behind the listing timelock instead (DA-10). A config change may move a
  reference supply by at most `MAX_SUPPLY_CHANGE` (an order of magnitude) at a time (DA-18).
- **Weights:** a market cap is `supply * price / 1e18`, floored at one wei; only ratios of caps matter, so the scale
  cancels out. Uncapped: `cap_i / sum`. Capped (`src/libraries/Methodology.sol`, at least 5 components): the largest
  weighs 30%, and every other constituent shares the remaining 70% by cap under a 20% cap of its own. Whatever a cap
  holds back is shared again among the constituents still below it, one pass per constituent at most; with five or more
  constituents the 70% always fits (four ranks at the cap hold 80%), and with four it could not, which is why capped
  indexes need five. Ties rank by position. The Numbers model's closed form gave ranks 3 and below no cap, so one of
  them could outweigh the first two: with caps in the ratio of WBTC, WETH, LINK, UNI and tBTC in September 2026 LINK
  came out at about 35%, and it now pins at 20% (the audit's XA-04; the owner's call on 2026-09-17). The app should show
  `weights(tokens, 1)` before a capped index is created.
- **targetUnits(tokens, units, methodology, keepMask):** weights over all components; the components not kept share
  their current value at snapshot prices by weight. A snapshot price is the same `_price` the display views take, with
  the same checks: there is one price path and no looser display path, because nothing about a feed is
  third-party-griefable and a looser view would only present a stale answer as if it were current. `price`,
  `navPerToken`, `weights` and `initialUnits` therefore revert `StalePrice` during a feed outage rather than answering.
  Kept components are not read at all under the uncapped methodology, whose weights renormalise them away; the capped
  methodology reads them exactly like a component that trades, because a kept component's cap sits in the denominator
  of every other component's weight, so an unread price there would reshape the targets and the turnover of the
  components that do move (DA-06). Each target is clipped to
  `[units / 2, units * 2]` (and below `MAX_TARGET_UNITS`, so the auction's premium still fits `uint96`). Each pass
  shares the value not yet pinned among the components still free, by weight, and clips the shares: when the clips add
  more value at the floors than they remove at the ceilings, the shares can only come down, so the components at their
  floor are pinned there; otherwise those at their ceiling are. The rest are shared out again until a pass clips
  nothing, at most one pass per component. A pinned component never moves again, so the result is the water-filling of
  value by weight within the bounds: no component above its floor holds more value per unit of weight than one below its
  ceiling. A weight that rounds to zero counts as one wei, so no clipped value is left unplaced. Every share rounds up
  into units, so the target basket is never worth less than the basket it replaces. Returns the targets and the
  turnover, the smaller of the value sold and the value bought as a share of the rebalanced value.
- **checkConfig(token, config):** used by the factory before a listing or config change, and again by
  `executeListing`. It requires a feed with code that answers `latestRoundData()` and `decimals()`, a `maxStaleness`
  that is non-zero and at most `MAX_FEED_STALENESS` (2 days), a price that passes every check in `_price`, and a
  non-zero supply. Two things it does not do. It cannot verify what a feed *is*: `description()` is a string the
  aggregator returns, so an aggregator reporting the wrong asset, or one under someone else's control, passes every
  on-chain check. The listing delay, the guardian's veto, the script logging `description()` at propose time and a fork
  test pinning each shipped feed are the whole defence, and a listing proposal should be read as a trust decision about
  an address. And the supply is checked only for being non-zero and for staying within `MAX_SUPPLY_CHANGE` of the one
  in force, so a figure stale or mistyped by less than that passes and drives its component toward its floor at the
  next rebalance: a revised supply is worth reading again before the two days run out (DA-18). A token whose feed is
  deprecated or stuck takes no config at all, and unlike a thin pool nothing recovers by itself — a replacement config
  through the listing flow is the only way back.
- **navPerToken(index):** the value of one whole index token, `sum(units_i * price_i)`, as a single USD WAD. For an
  uncapped index whose units follow the rule this equals the Numbers model's divisor price at every price; for a capped
  index it is the basket's own value, which the divisor formula would misstate. Display only.
- **initialUnits(tokens, methodology, startPriceUsd):** starting units that follow the rule at a chosen USD-WAD price, like the
  model's 1,000. It reverts `StartPriceTooLow` when the price is so low that a component's units round away entirely,
  rather than flooring that component at one raw unit and leaving the caller none the wiser (DA-09). The create flow
  should aim well above that floor: one index token should be worth at least roughly 10,000 raw units of every
  component, which for WBTC at 110k dollars is about 11 dollars a token and binds on nothing for an 18-decimal
  component. The coarser the index token, the larger a share of it one raw unit of a component is.
- **weights(tokens, methodology), weightsFromCaps(caps, methodology), price(token), supply(token):** the building blocks.

### CompositeFeed (`src/CompositeFeed.sol`)

An immutable, ownerless adapter that multiplies two `IAggregatorV3` feeds into one, so the rule can keep a single feed
per token. WBTC is why it exists: there is no WBTC/USD feed, and BTC/USD times WBTC/BTC is both the price and the thing
that prices a depeg of the wrapper against the coin it wraps. It reports
`answer = a * b / 10 ** decimalsB`, `decimals()` of its first leg, `description()` as `"<A> * <B>"`, and `updatedAt` as
the older of the two, with `roundId` and `answeredInRound` zero.

Each leg carries **its own** staleness bound, given at construction, and a leg past it reverts `StaleLeg`. That is the
point of the contract: the rule sees one `maxStaleness`, and that one number has to admit the slower leg, so a shared
bound over `min(updatedAt)` would let a three-hour-stale BTC/USD pass under WBTC/BTC's 24.5-hour allowance. Reporting
the older timestamp keeps the rule's own check meaningful on top. The adapter is deployed by `Deploy` on chain 1,
logged as `WBTC_FEED`, and checked against both legs by `ConfigureWhitelist` before it is proposed. It is outside the
protocol's ABI set: a config points at it, nothing calls it.

### IndexFactory (`src/IndexFactory.sol`)

- The constructor takes the owner and the guardian, deploys the rule, then deploys the `IndexToken` implementation
  pointing at the rule. It takes no market addresses: the rule and the factory depend on no Uniswap contract, and the
  only reason the whole stack is new rather than upgraded is that the rule is built here and held immutably.
- `createIndex(name, symbol, tokens, units, methodology)`: permissionless. Validates non-empty name and symbol, `1..20`
  components, matching lengths, every token whitelisted, no duplicates, `0 < units <= 2^96-1`, a known methodology, and
  at least 5 components for the capped methodology. Deploys the clone with CREATE2 from a salt over the creator, name,
  symbol, tokens, units and methodology, registers it (`isIndex`, `creatorOf`, `allIndexes`), emits `IndexCreated`, then
  initializes it, all in one transaction. Name and symbol are only required to be non-empty, so two indexes can present
  identically in an app or a block explorer while holding different baskets; the salt commits to both, so their
  addresses differ, and an app must identify an index by its address and `creatorOf` rather than by what it calls
  itself (DA-23).
- `predictIndexAddress(creator, name, symbol, tokens, units, methodology)`: the address `createIndex` will use.
- Listings and token configs take two steps. `proposeListing(token, config)` (owner only; the token must be a contract
  with no live proposal, and the rule must accept the config) starts `LISTING_DELAY` = 2 days; for a listed token it
  proposes a config change. `proposeConfig(token, config)` does the same for a token that was listed before, listed or
  delisted, but never whitelists it, so a delisted token's config can be refreshed for the indexes still holding it.
  `executeListing(token)` is permissionless from then until `PROPOSAL_WINDOW` = 7 days later; it applies the config and,
  for a `proposeListing` proposal, whitelists the token if needed (`pendingIsListing` tells which). The owner and the
  guardian can `cancelListing` a pending or expired proposal and `delist` a token; delisting is immediate, never affects
  existing indexes, keeps the config those indexes still rebalance with, and cancels a pending `proposeListing`
  proposal, so relisting always takes a fresh proposal and delay. `executeListing` runs the rule's `checkConfig` again
  on the stored config before applying it, so a feed that went stale or was deprecated during the notice is not
  whitelisted on a check up to nine days old (DA-11). The griefing half of that finding is gone rather than
  re-targeted: a pool could be held thin by a third party, and a live feed cannot be.
- A proposal that passes its `PROPOSAL_WINDOW` is dead but leaves `listingEta`, `pendingGuardian` and
  `pendingGuardianEta` set, so those storage reads alone say "pending" forever; `listingPending(token)` and
  `guardianChangePending()` are the views that answer whether a proposal can still be executed, and operators should
  watch those (DA-16).
- Guardian changes take `GUARDIAN_DELAY` = 7 days, as in v1. `isOwnerOrGuardian(account)` tells indexes who may cancel a
  rebalance or pass a keep mask. Ownership itself moves in OpenZeppelin's two steps, `transferOwnership` and then
  `acceptOwnership` by the new owner: it takes effect the moment the new owner accepts, and it is the one admin change
  with no delay and no guardian veto. `renounceOwnership` always reverts.
- Neither role can pause, upgrade, set units or prices, or touch funds held by any index.

### IndexZap (`src/IndexZap.sol`)

The user-facing convenience layer. Stateless, ownerless, holds no funds between transactions. It is the only contract
here that knows about Uniswap.

- `mintWithToken(MintParams{index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to, deadline})` and
  `burnToToken(BurnParams{index, expectedNonce, shares, tokenOut, minAmountOut, legs, to, deadline})` work as in v2:
  route endpoints validated, per-leg limits, balance-measured accounting, shortfalls reverted, `issue` as the final
  interaction of a mint. A leg's `minAmountOut` applies to its last hop's output. The leg whose component is already
  the mint's `tokenIn` or the burn's `tokenOut` carries no swap, and it honours its own limit too, `maxAmountIn`
  against what `issue` needs and `minAmountOut` against what `redeem` returns, so every leg means what its NatSpec says
  (DA-15).
- **One venue per leg.** `MintLeg {bytes v3Path; PathKey[] v4Path; uint256 maxAmountIn}` and the matching `BurnLeg`
  carry exactly one non-empty route, or `BadRoute(i)`; both empty is valid only for the pass-through leg. There are no
  mixed-venue legs. A V3 route is validated with `PathLib` as before. A V4 route must be hookless — `hooks` zero and
  `hookData` empty — because a hookless key cannot carry the dynamic-fee flag either, so one equality subsumes the flag
  bits and the fee test; only the endpoint the zap does not already imply is checked, since `currencyOut` on a mint and
  `currencyIn` on a burn are the component. `address(0)` is native ether and may appear only as an intermediate, which
  is how every live V4 pool for these components is paired; the zap has no `receive()`, so ether never reaches it.
- **Every command is the zap's own.** Each swap is one `ROUTER.execute(commands, inputs)` built here and nothing a
  caller supplied is forwarded, because the router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`, which
  move a payer's funds: passing calldata through would hand a caller the router's permissions. The four commands the
  zap emits, with the input layout of each, are vendored in `src/libraries/UniversalRouterCommands.sol`, and the V4
  actions in `src/libraries/UniswapV4Types.sol`, from the commit the pinned router was built against. A mint leg is
  `V3_SWAP_EXACT_OUT, SWEEP` or `V4_SWAP, SWEEP`; a V3 burn hop is `V3_SWAP_EXACT_IN, SWEEP`; a V4 burn leg is
  `V4_SWAP, SWEEP`. V4 legs settle and take with `OPEN_DELTA` so the leg moves exactly what the swap moved and leaves
  the unlock nothing to revert on. The zap never emits `CONTRACT_BALANCE` or the recipient sentinels: every amount it
  encodes is one the index asked for.
- **Pre-fund and sweep, not Permit2.** The zap sends the router what a leg may spend and appends `SWEEP` back to itself
  in the same `execute`, so the router is never left holding anything and there is no standing allowance to reset. It
  is atomic: a sweep that came up short fails the swap and reverts the whole call. What is left outside the reasoning
  is a `tokenIn` that calls back mid-transfer, which is unsupported alongside fee-on-transfer currencies.
- **`ShortFill` is load-bearing.** After a mint leg the zap checks the component balance it actually gained against
  what the index needs, because the pinned V4 periphery does not itself check that an exact-output swap delivered.
  Without it a short fill would surface as an opaque failure inside `issue`.
- **Burn legs differ by venue.** A V3 leg is swapped one hop at a time, so the unsold input of any hop, not only the
  first, goes to the recipient with `ComponentReturned`, and a hop that sells nothing reverts with
  `InsufficientOutput` rather than leaving the next hop to spend the zap's balance. A V4 leg is a single multi-hop
  action, because inside one action an intermediate partial fill leaves an unsettled delta and the leg reverts
  atomically; only its first hop can leave unsold input, which `SWEEP` returns and the zap forwards. Unsold `tokenOut`
  stays in the zap and is paid out with the rest either way.
- `expectedNonce` is the index's `rebalanceNonce` when the legs were quoted, checked on entry and again right before
  `issue`. A rebalance in between reverts the call with `StaleRebalanceNonce` instead of buying or selling a different
  basket.
- `burnToTokenWithPermit(BurnParams, v, r, s)` runs the same checks before the permit.
- The zap never calls `redeemSkipping` or `executeRebalance`.
- **Swap failures arrive unwrapped.** The Universal Router wraps a command in `ExecutionFailed` only when it dispatched
  it with a low-level call, and swaps are internal calls, so the caller sees the pool's own revert:
  `V3TooMuchRequested`, `V4TooLittleReceived` and their neighbours. Verified against the pinned deployment on a
  mainnet fork, which is why `IUniversalRouter` does not declare `ExecutionFailed` at all.
- **Pinned to Universal Router 2.0.0** (`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`), not the 2.1.x line, whose
  command inputs carry an extra per-hop price array and which shipped a change its own authors later reverted. The zap
  reads `POOL_MANAGER` from the router's own `poolManager()` rather than taking it as an argument, so the two can never
  be wired to different deployments. Moving to a newer router means a new zap; the token, rule and factory do not
  depend on it.

### PathLib (`src/libraries/PathLib.sol`)

Decodes Uniswap V3 packed paths (`token(20) | fee(3) | token(20) ...`): shape check, first token, last token. V4 routes
are typed `PathKey[]` and need no decoding.

## 3. Flows

**Create.** The app calls `IndexRule.initialUnits(tokens, methodology, startPrice)` so the index starts on its rule at
the chosen price, shows `predictIndexAddress`, and calls `createIndex`. The start price should leave one index token
worth at least roughly 10,000 raw units of every component, about 11 dollars for an index holding WBTC at 110k; below
that a rebalance moves only a few raw units of the coarsest component, and the rounding that protects holders starts to
cost the auction its margin. Creator-chosen units also work; the first rebalances then move them toward the rule, at
most halving or doubling the target each time (a fill at the 1.5 opening multiplier settles a growing component at up
to 2.5 times its units).

**Mint with a stablecoin.** Pick a venue per leg, quote it (`QuoterV2.quoteExactOutput` for V3, the V4 Quoter for V4),
set per-leg and overall limits, read `rebalanceNonce()`, and call `mintWithToken`. Exact shares are minted; unspent
stable is refunded. Neither contract nor script prefers a venue: the app decides, and V3 and V4 depth for the same pair
move independently.

**Burn to any token.** Quote each leg the same way in the exact-input direction, set per-leg minimums and a non-zero
overall minimum, pass `rebalanceNonce()`, and call `burnToToken` or `burnToTokenWithPermit`.

**Rebalance.**
1. After 28 days anyone calls `startRebalance(0)`; the app offers a "rebalance due" button. The index snapshots the rule's
   targets. Nothing changes for 2 days, and holders who disagree can leave in kind.
2. The auction runs for 24 hours. An executor contract calls `executeRebalance`, receives the shrinking components,
   swaps them wherever it likes, and must return the growing components before its callback returns. Executors are
   untrusted; the post-check is the only thing that matters. The callback's `amountsOut` and `amountsIn` are the
   authoritative figures, since they are recomputed from the supply in the settling block and issue stays open
   throughout; an executor that sizes itself from an earlier simulation should use a private relay and pass
   `maxAmountsIn`, which turns a settlement that has outgrown its funding into an explicit `RebalanceMovedOn` rather
   than a fill that reverts underfunded after the transfers.
3. With competition, the fill lands near the fair multiplier, the value of the sold legs over the value of the bought legs
   at execution prices, minus swap costs. Without competition, an executor waits until the multiplier reaches 0.9 and
   keeps 10% of the bought value at the snapshot's own prices, plus whatever the market moved between the snapshot and
   the fill. The band bounds the multiplier, not that drift, and up to three days lie in between; on crypto
   constituents the drift can be the larger term by far. It cuts both ways: as often it makes the fill unattractive, and
   then the auction simply expires.
4. If nobody fills, the auction expires. For the next two days only the owner and guardian can start a fresh one; after
   that anyone can again. A snapshot whose prices are distorted so that even 0.9 does not pay an executor is never
   filled, and without that wait a griefer could win the start at every expiry and stall an index. The wait hands the
   first restart to the owner and guardian, and the cost is that an honest restart after an expiry also waits those two
   days unless one of them starts it. Under Chainlink pricing a stranger cannot distort a snapshot in the first place;
   the wait now guards against a stranger restarting at a moment that merely suits it, which is the half of XA-02 that
   survives.

**Rebalance while a component is frozen.** A paused component that has to move makes the fill revert. The guardian
cancels and starts again with that component's bit in `keepMask`: it keeps its units, the other components share their
own value by the rule's weights, and the fill never touches the frozen token. The settlement does not read it either,
not even for its balance, so the mask also routes around a component whose `balanceOf` reverts (DA-14). The rule is the
narrower part: under the uncapped methodology a kept component's feed is not read at all, but under the capped
methodology it is read like any other, because its cap scales every other component's weight. A keep mask on a capped
index therefore routes around a token that cannot be transferred, not around one whose feed is stale (DA-06).

**Exit while a component is frozen.** `redeemSkipping` with that component's bit set pays everything else now and records
the frozen amount as a claim for the recipient; `claim` pays it to that same account once transfers resume. A router
redeeming on a holder's behalf therefore leaves the claim with the holder it paid, not with itself.

**Index price.** `IndexRule.navPerToken(index)` returns the basket's value in dollars from the same feed prices a
snapshot uses. A burn instead sells at pool prices, after rounding down and swap costs, so its proceeds can differ,
especially while prices move fast; a feed moves in the steps it publishes, so between two rounds the two can disagree
by up to the feed's deviation threshold before anything is wrong. It reverts `StalePrice` during a feed outage rather
than showing a stale figure as current, so an app needs a "price unavailable" state.

**Direct.** Anyone holding the components can `issue`, and any holder can `redeem`, `redeemSkipping` and `claim`, without
the zap.

**Trade.** An index is a normal ERC-20 and can be transferred or pooled on any DEX. The burn path is the guaranteed exit.

## 4. Key design decisions and rationale

**In-kind core, swap layer on top.** Splitting custody (token) from convenience (zap) keeps the part that holds funds
small and admin-free. The swap layer can be replaced without touching any index.

**The rule runs on-chain; no key rebalances.** Market caps need supplies and prices. Supplies are on-chain (with a
reference supply for wrapped and bridged assets, whose on-chain supply is only the wrapped float), and Chainlink
publishes prices without any operator of ours. A keeper bot would have made a hot key the thing that shapes every
basket; here the only roles stay the owner Safe and the guardian, and the trigger is permissionless.

**Value-bearing steps stay oracle-free.** Prices only choose each basket's shape and where the auction starts. Issue,
redeem, claim and the settlement itself move amounts derived from supply and units, and the post-check reads balances
only to verify. An uncapped index already on target ignores price readings altogether, because its targets are
proportional to supplies; a capped index reacts to prices only within the per-rebalance clip.

**The auction scales only the bought legs.** An earlier draft scaled the whole basket, which let a lone executor keep a
share of the entire index every month. Scaling only the growing components' extra units ties the executor's take to the
turnover: on the Numbers model's own rebalance (3.7% turnover), simulated monthly, a lone executor takes 0.37% to 0.48% of
the index on average instead of 5%.

**Start above par, end below.** Starting at 1.5 means an executor first has to deliver more value than it takes, so a
competitive fill finds the fair multiplier; a windfall needs the bought legs to lose a third of their value against the
sold legs within three days, or a snapshot price that was already off by that much. A snapshot price read low by a
factor f on a component the rebalance sells, or high on one it buys, sets the fair multiplier to about 1/f, so the
snapshot itself has to be guarded: see the price checks under `targetUnits`. Ending at 0.9 covers swap costs and
ordinary drift; simulated at medium volatility, 5% of auctions expire and restart. The band bounds the multiplier on
the bought legs and nothing else. Up to three days separate the snapshot from the fill, two of notice and one of
auction, and the settlement trades at the snapshot's relative prices however far the market has moved since. Settlement
therefore values both sides again in its own block, at the same feed prices, and requires what the index receives
to reach `MIN_SETTLEMENT_RATIO` (0.85) of what it pays out: the auction's own floor, with 5% for the gap between a
published price and the spot an executor trades at. That 5% was derived for a 30-minute mean against spot; against a
feed with a 0.5–2% deviation threshold plus heartbeat lag it is more conservative than it was, so it did not change. The test is a ratio between the two sides, so a market-wide move
reprices both together and passes; only drift between the legs sold and the legs bought can fail it. It can refuse a
settlement, never enlarge one, and what it refuses expires unfilled and comes back as a fresh snapshot (DA-05). The
notice period is what makes this a choice rather than a surprise, since holders who dislike the snapshot can leave in
kind before it settles, and the guardian can cancel a snapshot the market has overtaken.

**Clip, then redistribute.** Each rebalance targets between half and double a component's units (a fill at the opening
multiplier settles a growing one at up to 2.5 times, with the executor delivering the extra), so a manipulated price,
an inflating supply or a misconfigured token can distort a basket's shape only gradually and publicly. Redistributing
the clipped value pass by pass keeps the rebalance value-neutral; a single pass left up to 28% of value unplaced on
random baskets. Each pass pins only the side its clips prove. An earlier version clipped once and then spread the gap
over every component that could still move in that direction, so a component just clipped to its floor for being
overweight was handed value back (with weights 10/50/40 and holdings 50/10/40 it returned 28/20/52 instead of
25/20/55): value-neutral and within bounds, but slower to converge than the bounds allow (the logic review's LR-02,
2026-09-18). Shares are compared with the bounds as values, so a price near zero next to one above `MAX_EXACT_PRICE`
is clipped instead of overflowing (LR-09).

**Round the targets toward the holders.** Turning a share of value into units is a division, and that division used to
floor, so everything below one whole raw unit of a component left the target basket and was never accounted for
anywhere. The settlement moves the change in required backing either way, and the token is oracle-free and has no notion
of value, so the dropped value went to whoever filled the auction, for nothing. On a coarse enough index the whole
rebalance could be that residue: at BTC 110k a satoshi is worth about a tenth of a cent, so a whole turnover can vanish
into the floor on an index token worth less than 22 cents. On one worth a fifth of a dollar the 2026-09-19 audit
measured a certified turnover of 0.55% against a growing leg that asked back 0.0125% of NAV, and the index lost 53 basis
points in one settlement for which the executor paid 2.05% of what it took (DA-01). Shares therefore round up into
units, the same direction issue and redeem already round, so the basket a rebalance aims at is never worth less than the
one it replaces. The `MIN_TURNOVER` gate counts `min(sold, bought)` over the rebalanced value for the same reason: gross
outflow certifies that value leaves the basket, not that anything is bought back, and on that reproduction the two
differed by the whole figure (DA-08). The remaining half of the problem is the index's own granularity, which is why
`initialUnits` refuses a start price at which a component's units round away entirely: with the shares rounding up, a
growing component can ask for up to one raw unit per index token more than the rule wants, and on a coarse index that
overshoot eats the auction's 10% margin and the rebalance stops clearing (DA-09).

**What the feed checks bound, and what they do not.** The rule asks four things of a price: a positive answer, an
`updatedAt` that is neither in the future nor older than that token's `maxStaleness`, decimals within 18, and a result
under `MAX_PRICE`. That is a bound on the *data*, not on a venue, and it is a much shorter list than the pool checks it
replaces because Chainlink already does the aggregation the pool checks were approximating. What it buys: no third
party can move a feed, so the griefing surface of the old design — twelve seconds of thin liquidity blocking a
component for half an hour, a listing held off by keeping a pool thin — is gone outright, and so is the manipulation
surface that made per-token liquidity floors the only real defence. What it costs: the failure mode inverts. Nobody can
break a feed, and nobody can fix one either. A pool that had not traded could be cleared by anyone trading it; a feed
that has stopped publishing can only be waited for. `startRebalance` and every displayed price revert `StalePrice`
until it returns, while issue, redeem, `redeemSkipping` and `claim` keep working throughout, because they read no price
at all.

The 24-hour feeds are where that bites: wstETH/USD, SOL/USD and the WBTC/BTC leg, where a settlement may be valued on
an answer up to 24.5 hours old. What makes that tolerable is the deviation threshold rather than the heartbeat — a feed
also publishes whenever the price moves past it — so 0.5% on wstETH and WBTC/BTC and 2% on SOL are the real bounds on
how far a priced answer can sit from the market. Under the capped methodology a keep mask cannot route around a stale
feed, because a kept component's cap scales every other weight.

What remains untouched by any of this is the trust question. There is no second price source, so an aggregator that
reports a wrong answer is believed, bounded only by `MAX_PRICE` and by the guardian cancelling during the notice
period. A feed's identity cannot be checked on-chain at all. And a feed stuck at a circuit-breaker bound — the
LUNA/Venus failure — reads as a valid, fresh answer at runtime, because a clamped answer is positive and its timestamp
is current, so nothing inside `_price` can see it; the fork test refuses a feed whose circuit-breaker bounds sit within
a hundredfold of its current answer, which catches that setup before it ships rather than after. Chainlink is a trusted dependency now, in exchange for no longer trusting pool depth. Say that plainly
wherever the old text claimed a manipulation cost.

**Fixed constituents.** Changing which tokens an index holds would need a governance decision per index. The token list
is part of the index's address; only weights follow the rule.

**The notice does not freeze issue.** The two days exist for holders to decide, so issue, redeem, the zap and claims keep
working at the old units until the fill.

**The index price is the basket's value.** The Numbers model prices an index as total market cap over a divisor. That
number equals the basket's value only for the uncapped rule; for the capped rule it prices the uncapped market, and a
buyer paying it after the top coin doubles would pay 27% more than a burn returns.

**Chainlink rather than pool oracles, and the Universal Router rather than SwapRouter02.** Both reverse the v1
decision that section 4 carried until 2026-09-22 ("Uniswap V3 rather than V4": SwapRouter02's `exactOutput(path)`, the
reference liquidity for these pairs, and V3's built-in oracle, which V4 pools do not provide). Three measurements
changed it. First, V3 depth behind the old default list is thinning: LDO down 86%, MORPHO 55% and ONDO 54% in WETH held
over twelve months, and LINK already had 6.6x more depth on V4. Second, V4 has **no oracle at all** — the deployed
PoolManager carries none of `observe`, `observations` or `increaseObservationCardinalityNext`; a V4 oracle is a hook,
and no constituent has one — so following the liquidity to V4 was not a choice between two oracles but an end to
pricing inside Uniswap. Third, the per-token `minLiquidity` floor, which DA-03 had established as the only thing
standing against a manipulation held across the whole window, cost $3–16k to defeat on the thin tail. Taken together,
the venue Xindex wanted to trade on could not price, and the venue it could price on was getting cheaper to lie to.

So the two jobs were separated. Prices come from Chainlink, which is an aggregation nobody here operates and no third
party can push. Execution goes through the Universal Router, which reaches V3 **and** V4, with the venue chosen per leg
by the caller — because committing to V4 would have been wrong for most of the list: of the seven launch components
only LINK is deeper on V4, while WBTC (0.26x), UNI (0.66x) and AAVE (0.86x) are deeper on V3. The cost of the change is
in the paragraph above, and in the one new dependency: the zap now depends on the Universal Router and the PoolManager,
which the token, rule and factory do not, because the zap is the replaceable layer. `IndexToken` is byte-identical
across the change. `audit/2026-09-22-v3-retirement.md` records which past findings the change retired.

**Burner chooses the exit token; whitelist only; no fees; skip-and-claim; public delays; balance-measured zap.**
Unchanged from v1 and described above (see the zap in section 2 and section 5). Fees are still not in v3.

**Creator-bound CREATE2 addresses.** The address commits to the creator, the constituents, the starting units and the
methodology, so it can never hold a different token list or follow a different rule, and a front-runner's copy lands at
its own address.

## 5. Security model

- **Trust:** the factory owner (Safe), who proposes listings, token configs and guardian changes behind public delays;
  the guardian, who can cancel listings and rebalances, delist, start a rebalance with a keep mask or before strangers
  may, and cancel a change that would leave the factory with no guardian, but whom the owner can *replace* after
  `GUARDIAN_DELAY` without the guardian being able to block it (an owner that wants an unchecked config change installs
  a guardian it controls, so a `GuardianProposed` event is the earliest warning, 9 days ahead); the whitelisted tokens
  and their issuers, which now include Lido for wstETH and Wormhole's bridge for wSOL alongside WBTC's custodian;
  **Chainlink**, for every listed feed, with no second source behind it; and, for the zap only, Uniswap's Universal
  Router and the V4 PoolManager. Executors and the account that starts a rebalance are untrusted. Users trust no one with custody. Two powers deserve naming on their own. The
  guardian's `cancelRebalance` has no window and no rate limit, so a hostile or compromised guardian can cancel every
  proposal at the last second of its auction and hold an index off the rule, with its units drifting further each
  month, until the owner replaces it: `GUARDIAN_DELAY` of notice that the guardian cannot cancel, because it may cancel
  only its own removal and not its replacement; that is a trust assumption of the role rather than an oversight, because the cancel
  exists to stop a distorted snapshot in the last seconds of an auction and cannot be time-boxed without giving that
  up, and the owner's answer is to replace the guardian after `GUARDIAN_DELAY` (DA-12). And ownership of the factory
  moves in two steps that take effect as soon as the new owner accepts: it is the one admin change with no delay and no
  guardian veto, so `OwnershipTransferStarted` deserves the same watch as `GuardianProposed`.
- **Shape versus value.** Issue, redeem and claims never read a price. What can distort a basket's shape, with targets
  always within half to double per component per rebalance and settled units within half to 2.5 times: an issuer
  minting supply (policy: fixed-supply or governance-minted tokens); the owner changing a feed or a reference supply,
  behind the 2-day delay and the guardian's cancel; the caller choosing the snapshot moment. A wrong snapshot price can
  also move value: read low by a factor f on a sold component, it sets the auction's fair multiplier to about 1/f, and
  below f = 2/3 the first executor takes value. Under Chainlink pricing a stranger has no way to produce that, which is
  what the move off pool oracles bought; what remains is a feed reporting a wrong answer, a feed stuck at a
  circuit-breaker bound, or a listing that named the wrong aggregator in the first place — none of which the contracts
  can detect, and all of which the guardian's duty is the answer to. That duty is unchanged: compare
  `pendingRebalance()` targets with targets from independent prices during every notice period, and cancel a snapshot
  that disagrees. What also remains is the **choice of moment**: a feed publishes in steps, so a caller may start a
  rebalance at whichever published round suits it, within that feed's deviation threshold. The owner and guardian can
  stall rebalancing or keep chosen components unchanged.
- **Level:** set by the auction. A price error of δ on a traded component moves the fair multiplier by about δ. A lone
  executor on an honest snapshot keeps `(1 - 0.9)` of the bought value at the snapshot's own prices, plus however far
  the market moved in the up to three days between the snapshot and the fill; the band does not bound that second part,
  and the settlement-time ratio check does, at 15% of what the index pays out (DA-05). A
  windfall needs the fair multiplier above 1.5. When the settlement moves no raw unit at all the multiplier is parity,
  so an empty index follows the rule exactly; when it moves a few wei, the auction still decays and a lone executor
  picks the level of a near-empty index for free, within the half-to-2.5-times bound and without moving any holder's
  value.
- **Reentrancy:** `nonReentrant` on `issue`, `redeem`, `redeemSkipping`, `claim`, `startRebalance`, `cancelRebalance`,
  both `executeRebalance` overloads, `createIndex`, `mintWithToken`, `burnToToken` and `burnToTokenWithPermit`. The
  ERC-20 entry points are not guarded and do not need to be. Checks-effects-interactions throughout; the new units,
  nonce and cleared proposal are written before any rebalance transfer. The executor callback cannot reach any guarded
  function; index-token transfers stay allowed and are harmless. Only a contract can execute, and the callback always
  goes to `msg.sender`.
- **Read-only reentrancy:** inside `issue`, `redeem` and `executeRebalance`, supply, units and balances change at
  different moments. Xindex's own views never read balances. Integrators must value an index from `components()` and
  independent prices, never from `balanceOf(index)` and `totalSupply()`.
- **Price readings:** `navPerToken` moves in the steps its feeds publish, so it lags fast moves by up to a heartbeat
  and can sit a deviation threshold away from the market without anything being wrong. It reverts during a feed outage
  rather than returning a stale figure. Nothing in Xindex reads it; a lending protocol that used it as a collateral
  oracle would be inheriting every feed in the basket plus a value derived from units, so do not.
- **Clone safety:** the implementation has initializers disabled; `initialize` is `onlyFactory` and runs in the same
  transaction as the clone; uninitialized instances cannot issue, redeem or rebalance; `isIndex` is the only trusted
  registry, and the zap and `navPerToken` check it.
- **Token behaviour:** `issue` verifies received amounts. A paused or blacklisting component does not freeze the rest of
  a basket: `redeemSkipping` exits everything else, `claim` collects the frozen part later, and a keep mask rebalances
  around it, reading neither its balance nor, under the uncapped methodology, its feed. Policy: standard ERC-20s, 6-18
  decimals, no fee-on-transfer, rebasing or callback tokens, fixed-supply or governance-minted supply, and a Chainlink
  USD feed; stables are mint currencies, not components; pausable components and every other issuer a component brings
  are labelled in the app. Enough execution depth to mint and burn at size is a separate requirement the contracts do
  not check, and the app's routing is where it is met. Two wrappers of one asset are valued by their own configs — WBTC
  with bitcoin's whole supply, wstETH with its own `totalSupply` — so an index holding WETH and wstETH counts the
  staked ether behind wstETH in both components' market caps; that is inherent to holding two claims on one asset, is
  bounded by the 30% cap under the capped methodology, and is labelled.
- **Zap:** stateless and ownerless; every route's endpoints are checked and a leg names exactly one venue; V4 routes
  must be hookless and may touch native ether only as an intermediate; per-leg and overall limits apply to every leg
  including the one that carries no swap because its component is already the mint's `tokenIn` or the burn's
  `tokenOut`; payments and payouts are measured as balance changes inside the call (tokens already in the zap are never
  used); a mint leg's delivery is checked against what the index needs (`ShortFill`), because the pinned V4 periphery
  does not check it; fee-charging currencies revert with `TransferShortfall`; a V3 burn leg is swapped hop by hop so
  every hop's unsold input goes to the recipient, while a V4 burn leg is one atomic action whose intermediate partial
  fill reverts the leg (unsold `tokenOut` is paid out instead); the zap, the index, the Universal Router and the
  PoolManager are rejected as recipients; every router command is built here and nothing a caller supplied is
  forwarded; the router is pre-funded and swept clean within the same `execute`, so no allowance and no balance
  survives a call; the permit is tried and a front-run permit is accepted; and `expectedNonce` is checked on entry and
  again right before `issue`. It never calls `redeemSkipping` or `executeRebalance`. Swap failures reach the caller
  unwrapped.
- **Operations:** `OWNER` and `GUARDIAN` are required at deploy, along with `UNIVERSAL_ROUTER`, which is the deploy
  script's only market address; on mainnet the owner must be a contract that is not an EIP-7702 delegated account, and
  a Safe must need at least two signatures and have no enabled module (a module acts as the Safe without signatures;
  the owner must keep none afterwards). On chain 1 the script also deploys WBTC's `CompositeFeed` and logs it as
  `WBTC_FEED`, which `ConfigureWhitelist` needs and checks against both legs. Reference supplies drift and need
  periodic config changes. **Feeds need watching**: Chainlink deprecates and repoints aggregators, and a replacement
  config takes the same 2-day listing flow, so a deprecation announcement is the moment to start one, not the moment
  the old feed stops. A `StalePrice` revert is not a configuration problem and not something to retry into: nobody
  caused it and nobody can clear it, so the choice is to wait for the feed or, under the uncapped methodology, to keep
  that component. Whether a proposal is still executable is read from `listingPending(token)` and
  `guardianChangePending()`, never from `listingEta` or `pendingGuardian` alone, which stay set after a proposal
  expires.
- **Gas:** `MAX_COMPONENTS = 20`; the UI should suggest about 10. `startRebalance` reads a feed, a supply and a config
  per component, which is cheaper than the pool reads it replaces; `executeRebalance` costs little beyond the
  executor's own swaps.
- **Overflow:** `units <= 2^96-1`, targets below `MAX_TARGET_UNITS`, 512-bit `mulDiv`. A WAD price is refused above
  `MAX_PRICE` (1e56), which is under the 3.4e56 ceiling the existing 256-bit proof was derived for, so that proof and
  every constant in it carry over unchanged: market caps are `supply * price / 1e18` floored at one
  wei (only ratios matter), and values are `units * price`, exact while every price is at most `MAX_EXACT_PRICE` (1e46,
  where 20 holdings of 2^96 units still fit) and divided by `1e18` above it. Ordinary baskets are unaffected to the wei,
  and a feed reporting an absurd answer yields either a `PriceTooHigh` revert or a snapshot the guardian can cancel,
  rather than a panic.
- **Known limitations:** airdrops, rewards and votes that accrue to index-held tokens are unrecoverable. Rebalances
  clear only when the bought value covers gas and swap costs many times over, so small indexes on mainnet rarely
  rebalance. A permanently frozen component needs the guardian's keep mask at every rebalance. Under the capped
  methodology a kept component is still priced, so a component whose feed is stale blocks rebalancing until the feed
  returns or the config changes; under the uncapped methodology it is not read at all. A stale feed halts every price
  and every rebalance for the indexes holding that token, which nobody can cause and nobody can clear, while issue,
  redeem, `redeemSkipping` and `claim` keep working. Chainlink is trusted outright, with no second source, and a feed's
  identity cannot be verified on-chain. A hooked V4 pool cannot be routed through, so a component whose only V4 depth
  sits behind a hook is reachable on V3 only. A `tokenIn` that calls back mid-transfer is unsupported, alongside
  fee-on-transfer currencies. The guardian can cancel a
  rebalance every time one is started, with no window and no rate limit, so an index rebalances only while its guardian
  lets it. Index names and symbols need only be non-empty, so two indexes can look identical while holding different
  baskets; only the address tells them apart. The factory's deployment bytecode is close to the EIP-3860 initcode limit.
  Bytecode targets Cancun.

## 6. Verification

- Unit and fuzz tests per contract: `IndexToken.t.sol`, `IndexToken.rebalance.t.sol`, `IndexRule.t.sol` (including the
  Numbers model's weight vector and its divisor prices), `CompositeFeed.t.sol`, `IndexFactory.t.sol`, `IndexZap.t.sol`,
  with 6/8/13/18-decimal mocks, settable feeds behind a market fixture, a strict mock of the Universal Router that
  decodes against the pinned 2.0.0 command and action layouts, and mock executors that fill honestly, short, not at
  all, or reentrantly. The mock router asserts the *bytes* the zap emits rather than accepting whatever it is given,
  and its partial-fill and under-delivery modes are what cover the paths a live pool will not reproduce on demand.
- Invariant test: random issue, redeem, redeemSkipping, claim, transfer, donate, price moves, supply changes, rebalance
  starts, cancels, honest fills, short fills and staged time jumps; asserts every component stays backed including open
  claims, supply equals the sum of holder balances, claims add up, the nonce counts executed rebalances, short fills never
  settle, units move between half and 2.5 times per rebalance, and targets exist exactly while a rebalance is pending.
- A value fuzz over the rule's targets, with units bounded from one raw unit so the coarse regime is included, asserts
  that a target basket is never worth less than the basket it replaces, allowing the wei per component that the bounds
  and the share division still round away. The earlier water-filling fuzz bounded units to whole-token magnitudes and
  checked only the shape, which is why it did not see DA-01.
- Security regression tests, named after their ids: one per testable finding of the 2026-09-15 security review, the
  2026-09-16 rebalancing design review (R01–R23), the 2026-09-16 whole-repo audit (XA ids), the 2026-09-18 logic review
  (LR ids) and the 2026-09-19 deep audit (DA ids), plus controls. Six ids lost their test on 2026-09-22 because the
  mechanism they lived in no longer exists; `audit/2026-09-22-v3-retirement.md` names each one, the test that went and
  what survives elsewhere, and a retired id's test must not be restored against the new design. The v1 and R tests are in `test/Security.t.sol` and
  its fork counterpart, except L06 and FR05–FR06 (script tests) and I09–I11, L08 and FR04 (`test/Repo.t.sol`); an XA or
  DA test sits in the suite of what it checks. AGENTS.md gate 6 maps each one.
- Mainnet fork tests, against the real Universal Router 2.0.0, the real V4 PoolManager and real Chainlink feeds: the
  zap and security cases end to end; every shipped feed checked by `description()`, `decimals()`, a positive and fresh
  answer and its circuit-breaker bounds, with the WBTC adapter's answer required to equal BTC/USD times WBTC/BTC
  exactly; the rule's USD prices against QuoterV2 quotes; uncapped and capped indexes rebalancing with a fork executor;
  a guardian keep mask around a real WBTC pause; and the V4 legs — a mixed basket minting and burning LINK through the
  native-ether-paired V4 pools while WBTC and WETH stay on V3, and a capped leg reverting with the V4 router's own
  `V4TooMuchRequested`. The V4 legs are covered on a fork rather than only in a mock on purpose: V4's flash accounting
  reverts inside `unlock` on an unsettled delta, which is precisely what the settle/take pair exists to avoid, so a
  mock that agrees with the encoder would only prove the encoder agrees with itself. Fork tests pass time by pinning
  each feed's `updatedAt` to the warped clock while keeping its real answer; that technique is stated in
  `test/fork/ForkFeeds.sol` so it is not mistaken for a shortcut.
- Script tests execute `Deploy`, `ConfigureWhitelist` and the Sepolia `SetupTestMarket` in-process.
- Gates, all enforced in CI: `forge fmt --check`, `forge build`, `forge lint -D notes`, `forge test` (fork suites
  required on `main` and on pull requests into it), 100% coverage on every file, Wake detectors clean on `src/`, and the
  submodule check against `foundry.lock`.

## 7. Mainnet addresses

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| wSOL (Wormhole, symbol `SOL`, 9 decimals) | `0xD31a59c85aE9D8edEFeC411D448f90841571b89c` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| AAVE | `0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9` |
| Chainlink ETH / USD (1h, 0.5%) | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink wstETH / USD Calculated (24h, 0.5%) | `0x164b276057258d81941e97B0a900D4C7B358bCe0` |
| Chainlink BTC / USD (1h, 0.5%) | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| Chainlink WBTC / BTC (24h, 0.5%) | `0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23` |
| Chainlink SOL / USD (24h, 2%) | `0x4ffC43a60e009B551865A93d232E33Fce9f01507` |
| Chainlink UNI / USD (1h, 1%) | `0x553303d460EE0afB37EdFf9bE42922D8FF63220e` |
| Chainlink LINK / USD (1h, 0.5%) | `0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c` |
| Chainlink AAVE / USD (1h, 1%) | `0x547a514d5e3769680Ce22B2361c10Ea13619e8a9` |
| Uniswap Universal Router 2.0.0 | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap V4 StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| Uniswap V4 Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Uniswap QuoterV2 (V3 quotes) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| IndexFactory / IndexRule / IndexZap / WBTC `CompositeFeed` | not deployed yet |

Every feed is an 8-decimal aggregator proxy, with its heartbeat and deviation threshold in the table. Only the first
group and the Universal Router are read by anything deployed: the quoters and StateView are for apps and tests, and the
PoolManager is reached through the router. The V3 pools the fork tests swap through are in
`test/fork/ForkAddresses.sol`; no contract reads them.

## 8. Roadmap candidates

ETH in/out, `createAndMint`, `mintWithTokenPermit` (USDC only), creator/protocol fees attributed by `creatorOf` with
timelocked governance, mixed-venue legs that split one leg across V3 and V4, per-pair partial-fill auctions for very
large baskets, a permissionless backstop executor and a reminder for the monthly trigger, an aggregator or Universal
Router 2.1 zap, V4 pools on the Sepolia market so the V4 legs get a testnet rehearsal, a second price source behind the
Chainlink feeds, synthetic exposure for L1 coins.
