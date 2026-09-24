# Xindex

Xindex lets investors package a whole crypto portfolio into a single ERC-20 token. Anyone can create an index (any
name, any symbol, any mix of whitelisted tokens, a weighting rule), anyone can mint it with USDC or USDT, and anyone
can burn it back into USDC, USDT, WBTC or any other token. Every index is a plain ERC-20, fully backed in kind by the
tokens it represents, and rebalanced monthly by an on-chain market-cap rule that anyone can trigger.

This repository holds the smart contracts (Foundry). The web app lives elsewhere.

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

v2 added the rebalancing and index-price methodology from the team's Numbers model (`index_MODEL.numbers`): market-cap
weights, uncapped or capped with the largest coin at 30% and every other coin at most 20%, sharing the remaining 70% by
market cap. The coins in that model were examples; the methodology is the requirement. (The model capped only the second
coin; a third-ranked coin could then outweigh both, so the cap now applies to every coin below the largest.)

v3, on 2026-09-22, changed where prices and execution come from, and nothing else: the rule prices from Chainlink USD
feeds instead of Uniswap V3 pool averages, and the zap swaps through Uniswap's Universal Router, which reaches both V3
and V4 pools, instead of SwapRouter02. Uniswap V4 carries no oracle, so following the liquidity there meant leaving
Uniswap for prices; the Universal Router still reaches V3 depth, so execution could follow the liquidity without giving
up the pools that are still deeper. `IndexToken`'s executable code was unchanged by the move itself, every in-kind
guarantee with it; its one behavioural change in v3 was VR-04, merged with the verification review. (An earlier version
of this paragraph called it byte-identical, which the bytecode never was: its metadata moves with every comment,
CR-I20.) It is a new set of contracts rather than an upgrade, because a factory builds its rule in its own constructor
and holds it immutably. `audit/2026-09-22-v3-retirement.md` says what the change retired from the earlier security
reviews.

The security audit of 2026-09-23 (`audit/2026-09-23-security-audit.md`, triaged in `audit/2026-09-23-triage.md`) found
no way to take funds and one Medium: a config without a reference supply made the rule read the token's live
`totalSupply`, which for wstETH anyone could move with a free flash loan around the permissionless `startRebalance`.
Every token now carries a timelocked reference supply and the rule reads no supply live. The same pass made the capped
methodology's top ceiling follow the leader's lead, from 20% at a tie to 30% at twice the runner-up, so two near-tied
leaders no longer swap ten points on a one-wei move; raised the settlement's value floor from 85% to 87.5%; refused
share transfers to an index itself; and stopped a stray router balance from reverting a zap burn.

## Design decisions (v3)

| Topic | Decision |
|---|---|
| Chain | Ethereum mainnet |
| Swaps | Uniswap's Universal Router 2.0.0, which reaches both V3 and V4 pools. Each leg names one venue, chosen by the caller: a packed V3 path or a hookless V4 route. Quotes via QuoterV2 for V3 legs and the V4 Quoter for V4 legs. Aggregators remain a drop-in replacement for the zap later. |
| Composition | Constituents fixed at creation. Units follow the index's methodology: `0` uncapped market cap, `1` capped market cap (every component at most 20%, except the largest, which may reach 30% once its market cap is twice the runner-up's -- 20% at a tie, rising linearly in between; at least 5 components). |
| Rebalancing | On-chain rule, no bots or keys. Anyone starts a rebalance 28 days after the last one; 2 days of notice; a 24-hour auction that any contract can fill; each target lies between half and double a component's units, and a growing component settles at its extra units times the auction multiplier, so between half and 2.5 times per rebalance. |
| Prices | One Chainlink USD feed per token, named in that token's timelocked config together with the oldest answer the rule will accept (`maxStaleness`; the policy is the feed's heartbeat plus 30 minutes). WBTC, which has no USD feed, is priced through a `CompositeFeed` over BTC/USD and WBTC/BTC, which also catches a depeg of the wrapper. Snapshots and display views take the same path: during a feed outage the rule reverts rather than answering. |
| Supplies | A timelocked reference supply for every token, and nothing read live: a total supply read inside a snapshot's own transaction could be moved there, as wstETH's could by unwrapping flash-borrowed wstETH (CR-M01). Wrapped and bridged assets carry the supply of what they wrap. |
| Index price | The basket's value per index token in dollars, `IndexRule.navPerToken`, as a WAD (1e18 = $1). For an uncapped index it equals the Numbers model's divisor price; for a capped index it replaces it. Display only. |
| Fees | None in v3. |
| Layer-1 coins | Only tokens that exist on mainnet can be components (WBTC, WETH, LINK, ...). Coins with no credible wrapper (ADA, XRP, ...) are out of scope until one exists. |
| Stable in / out | Mint with USDC or USDT. The burner chooses USDC, USDT or any other token at exit. Index tokens are fungible, so the protocol cannot know which stable a given holder used; economically the two are equivalent. |
| Decentralization | No admin can move an index's funds, mint or burn its shares, pause or upgrade it, or set its units by hand. What the roles do hold: the owner proposes listings and token data configs, which take effect after a public 2-day delay, and guardian changes, which take 7 days; a proposal not executed within 7 days of becoming ready expires. Owner and guardian both cancel a pending listing, delist a token, cancel a rebalance on any index, and start one with a keep mask or before strangers may; the guardian can also cancel a change that would remove it, but not one that replaces it. Ownership is handed over in two steps that take effect at once, with no delay and no guardian veto, and it cannot be renounced. A token config reshapes the targets of every index holding that token at its next rebalance, and the power to cancel a rebalance has no window and no rate limit, so it can hold rebalancing off until the owner replaces that guardian (see "Known limitations"). |
| Frozen components | If a component's issuer pauses or blacklists transfers, holders take every other component out with `redeemSkipping` and collect the frozen one later with `claim`; the guardian rebalances around it with a keep mask. A kept component is neither transferred nor read for its balance, but under the capped methodology its feed is still read, because its market cap enters every other component's weight. Its token contract is never called, so the keep mask also routes around a component whose contract stops answering altogether, as one behind a withdrawn proxy implementation would (RT-01). |

## Architecture

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
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4  │
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                              │
                                      └──────── issue() / redeem() ───────────────────────────────┘
```

- `IndexToken` (`src/IndexToken.sol`) only ever moves amounts derived from supply and units. `issue(shares)` pulls
  `ceil(shares * units_i / 1e18)` of every component and mints; `redeem(shares)` burns and pushes `floor(shares *
  units_i / 1e18)`; `redeemSkipping` leaves chosen components as claims for the recipient. `startRebalance`,
  `cancelRebalance` and `executeRebalance` run the rebalance: a snapshot of the rule's targets, a notice period, and an
  auction whose settlement stands only if every component still backs the new units. No amount in any of these steps
  comes from a price, there is no share price, and nothing is computed from balances, so there is no first-depositor /
  inflation attack and nothing for an admin to touch. Prices reach only the rebalance: the snapshot's targets, and a
  value check on the fill at feed prices, which can refuse a settlement but never sizes one (earlier text said no oracle
  entered these steps at all, CR-I11). Share transfers to the index itself, its factory or its rule are refused, since
  none of them could ever move a share on (CR-I01, RT-21). Only initialized clones can issue, redeem or rebalance.
  Supports EIP-2612 `permit`.
- `IndexRule` (`src/IndexRule.sol`) is a stateless, view-only contract: token supplies, Chainlink USD prices, the
  uncapped and capped weights, rebalance targets, starting units and the index price. It has one price path, used by
  snapshots and display alike, and it depends on no Uniswap contract at all. `CompositeFeed` (`src/CompositeFeed.sol`)
  is an immutable, ownerless adapter that multiplies two feeds into one with a staleness bound per leg, which is how
  WBTC is priced; it is not part of the protocol's ABI set.
- `IndexFactory` (`src/IndexFactory.sol`) is permissionless `createIndex`, a curated token whitelist where every token
  carries its market-data config behind a 2-day delay (`Ownable2Step` owner plus a guardian whose replacement takes 7
  days), and the registry (`isIndex`, `creatorOf`, `allIndexes`). Indexes are EIP-1167 clones deployed with CREATE2 from
  a salt over the creator, the starting composition and the methodology; `predictIndexAddress` returns the address
  before the transaction is sent.
- `IndexZap` (`src/IndexZap.sol`) is a stateless convenience router over Uniswap's Universal Router. `mintWithToken`
  buys exactly the basket with exact-output swaps; `burnToToken` redeems and sells every component into the chosen
  token; `burnToTokenWithPermit` does it in one transaction. Every route is checked, each leg can carry its own limit,
  amounts are measured as balance changes, and every call names the index's `rebalanceNonce` so a quote from before a
  rebalance cannot fill. It builds every router command itself and forwards nothing a caller supplied, pays by
  pre-funding the router and sweeping it clean in the same call rather than through Permit2, and holds no approval
  between calls. It is the only contract here that knows about Uniswap; the token, rule and factory do not.

Invariant, for every component `i` of every index, forever:

```
token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
```

## How the flows work

**Create.** The creator picks whitelisted tokens, a methodology and a starting price in the UI. The app calls
`IndexRule.initialUnits(tokens, methodology, startPriceUsd)` for units that already follow the rule (like the model's
1,000), shows `predictIndexAddress`, and calls `createIndex`. Name and symbol are free-form and not unique; the UI must
show the index address and `creatorOf` to avoid spoofing.

Pick the starting price so that one index token is worth at least roughly 10,000 raw units of every component. For WBTC,
whose raw unit is a satoshi, that is about 11 dollars a token at BTC 110k; for an 18-decimal component it binds on
nothing. The coarser the index token, the larger a share of it one raw unit of a component is: a rebalance target rounds
up into whole raw units, so a growing component can ask for up to one raw unit per index token more than the rule wants,
and on a coarse enough index that overshoot eats the auction's margin and the rebalance stops clearing.
`IndexRule.initialUnits` reverts `StartPriceTooLow(token, startPriceUsd)` when a price is so low that a component's
units round away entirely.

**Mint with USDC/USDT.** For each leg the app picks a venue, quotes it (QuoterV2 `quoteExactOutput` for a V3 leg, the
V4 Quoter for a V4 one), sets per-leg limits and the overall `maxAmountIn`, reads `rebalanceNonce()`, and calls
`mintWithToken(MintParams)`. Exact `shares` are minted; unspent USDC comes back.

**Burn to USDC/USDT/anything.** The app quotes each leg the same way in the exact-input direction, sets per-leg
minimums and a non-zero overall `minAmountOut`, passes `rebalanceNonce()`, and calls `burnToToken(BurnParams)` or
`burnToTokenWithPermit`.

**Rebalance.**
1. 28 days after an index's creation or last rebalance, anyone calls `startRebalance(0)`. The index stores the rule's
   targets. For 2 days nothing changes; holders who disagree can leave, and this notice is the window to do it in:
   once the auction opens, a public redeem can be overtaken by a fill (see step 2).
2. A 24-hour auction follows. An executor contract calls `executeRebalance(data)`: it receives what the index no longer
   needs of each shrinking component and, inside its `onXindexRebalance` callback, must send back what the growing
   components need. The growing components' extra units are multiplied by a factor that falls from 1.5 to 0.9, so
   executors compete the fill toward fair value; a lone executor that waits for the floor keeps 10% of the bought value
   at the snapshot's rate. Both sides are recomputed from `totalSupply()` in the block that settles, and issue and
   redeem stay open throughout, so an executor sizes itself from the callback's arguments, never from an earlier
   simulation: a stranger's dust `issue` is enough to make a fill funded from `previewRebalance()` fall short.
   `executeRebalance(data, maxAmountsIn)` is the same settlement with a bound on that, reverting
   `RebalanceMovedOn(token, required, maxAmountIn)` when the index has come to need more of a component than the caller
   said it would deliver. The fill can land in any block of the auction, and whoever holds shares in that block pays
   its haircut, so an executor watching the mempool can put its fill ahead of a public redeem or guardian cancel. An
   exit sent during the auction then pays that holder's share of the executor's take, the same as every holder at
   settlement; the zap's `expectedNonce` makes such a burn revert, but only after the fill already landed. Leave
   during the notice, or send the transaction through a private relay (RT-02). A mint is the other way round: shares
   issued while a rebalance is pending, in the notice or the auction, share the haircut of any fill that lands after
   them, however it is ordered, and a relay does not change that.
3. If nobody fills, the auction expires. The owner or guardian can start a fresh snapshot at once; anyone else can
   2 days after the auction's last second.
4. The owner or guardian can cancel a rebalance. Cancelling a live one makes others wait 2 days from the cancel to
   restart; cancelling one that already expired only clears it from the views, and the wait the expiry started stands
   (VR-04).

The settlement trades at the snapshot's relative prices, and the snapshot is up to three days old by the time it
settles: 2 days of notice and a 24-hour auction. The 1.5-to-0.9 band bounds the multiplier on the bought legs at those
prices, and not how far the market moved in between. Settlement therefore values both sides again in the block it
happens in: what the index receives has to reach 87.5% of what it pays out, at prices read the way a snapshot reads
them. The test is a ratio, so a market-wide move changes nothing; only drift between the legs sold and the legs bought
can fail it, and it can only refuse a fill: mostly it moves a lone executor's fill earlier in the auction, to a
multiplier the drift has not eaten. A fill no multiplier can clear expires, and a fresh snapshot follows 2 days later.
The guardian's check during the notice period still stands behind it.

**Rebalance around a frozen component.** The guardian cancels and starts again with the component's bit in `keepMask`;
that component keeps its units and is never transferred.

**Exit while a component is frozen.** If, say, WBTC is paused, `redeem` and the zap revert. The holder calls
`redeemSkipping(shares, to, skipMask)` with the WBTC bit set: every other component arrives now and the WBTC amount is
recorded in `claimOf(holder, WBTC)`. Once WBTC transfers resume, `claim(WBTC, to)` pays it.

**Trade.** An index is a normal ERC-20 so it can be transferred or listed on any DEX. The burn path is the guaranteed exit.

**Direct, without the zap.** `issue`, `redeem`, `redeemSkipping` and `claim` on the index itself work for anyone who
already holds the components or shares.

## Frontend integration notes

- **Starting units.** `IndexRule.initialUnits(tokens, methodology, startPriceUsd)`, with the price as a USD WAD
  (1,000 dollars is `1000e18`). Units must be `> 0` and `<= 2^96 - 1`. Max 20 components; keep it around 10 for gas.
  The capped methodology needs at least 5. A price so low that a component would hold less than one whole raw unit
  reverts `StartPriceTooLow(token, startPriceUsd)`; the starting price the create flow recommends above is far clear
  of that floor. Like every other rule view, it reverts `StalePrice` while any component's feed is out.
- **Names and symbols are not unique.** `createIndex` requires only that they are non-empty, so two indexes can present
  identically in an app or an explorer while holding different baskets. The CREATE2 salt commits to the creator, the
  composition and the methodology, so their addresses differ: key every index by its address, show `creatorOf`, and
  mark a name or symbol an existing index already uses.
- **Index price.** `IndexRule.navPerToken(index)` returns one number, the basket's value per whole index token as a
  USD WAD (1e18 = $1), from the same Chainlink prices a snapshot uses. Show it as the index price. It moves in the
  steps its feeds publish, so it lags fast moves by up to a heartbeat; never use it, or a thin DEX pool of the index
  token, as an oracle. It reverts `StalePrice(token, updatedAt)` when any component's feed is stale, so the app needs
  a display state for "price unavailable" rather than a zero or a cached figure passed off as current.
- **Weights.** `IndexRule.weights(tokens, methodology)` returns current target weights (1e18 = 100%), prices as USD
  WADs and supplies. Show them before a capped index is created: under the cap several components can sit at exactly
  20%, and the largest reaches its full 30% only once its market cap is twice the runner-up's (CR-L01). The supplies
  are the reference figures the configs name, not the tokens' own total supplies.
- **Rebalance status.** Show `lastRebalance + MIN_REBALANCE_INTERVAL`, and a "rebalance due" button when
  `canStartRebalance()` is true. That one view answers the whole predicate: the interval has passed, no auction is
  live (an auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`, so `pendingRebalance().eta == 0` on
  its own is the wrong test), and the waits after a cancel and after an unfilled auction are over. Those waits hold
  off everyone but the owner and guardian: `REBALANCE_DELAY` from the cancel of a live auction, and `REBALANCE_DELAY`
  from an unfilled auction's last fillable second, `eta + AUCTION_DURATION`, so after an expiry the owner and guardian
  have the start to themselves for `REBALANCE_DELAY` less one second (CR-I02). Cancelling an auction that already
  expired keeps that hold-off rather than restarting it (VR-04). Read `canStartRebalance()` or the `restartAllowedAt`
  that `RebalanceCancelled` carries rather than computing either wait, and note that `restartAllowedAt()` alone
  reflects cancels only (RT-08, RT-09). Before starting, `previewTarget(0)` shows the targets and turnover, the value
  the step trades. A turnover below `MIN_TURNOVER` reverts unless it is non-zero and the basket sits at least
  `MIN_TURNOVER` from its rule, which `IndexRule.shortfall(tokens, units, methodology, keepMask)` reports: the band
  lets a component at most double per rebalance, so an index far from its rule can move only in small steps (RT-04). A
  snapshot also reverts any of whose feeds has not published within that token's `maxStaleness` (`StalePrice(token,
  updatedAt)`, or WBTC's adapter's own `StaleLeg(feed, updatedAt)` when one of its legs is the late one). Nobody can
  cause that and nobody can clear it: wait for the feed, or, under the uncapped methodology only, keep that component.
  During the notice, show `pendingRebalance()` and the auction start; during the auction, `currentMultiplier()` and
  `previewRebalance()`. While a rebalance is pending, warn before a mint that the new shares share the coming
  settlement's haircut, whatever the ordering; during the auction, also warn before a burn that the fill can be
  ordered ahead of it, so the user shares the haircut, and that a private relay is the protection (RT-02).
  `previewRebalance()` prices nothing, so it answers even when `executeRebalance` would revert `SettlementValueTooLow`
  or on a stale feed; `IndexRule.settlementValues` values the two sides it returns.
- **Rebalance events.** `RebalanceStarted`, `RebalanceCancelled` and `Rebalanced` carry `proposalId` (`proposalCount`,
  counting every attempt on that index) as their first topic, so cancelled, expired and settled attempts can be told
  apart; `RebalanceStarted` and `Rebalanced` also carry `id`, the `rebalanceNonce` the settlement takes. Nothing is
  emitted when an auction expires unfilled: the next `RebalanceStarted`, with a new `proposalId`, is the first sign.
- **Guardian duty.** During every notice period, compare `pendingRebalance()` targets with targets computed from
  independent prices and the configs in force, and cancel a snapshot that disagrees. A snapshot price read low by a
  factor f on a sold component hands the first executor about (1/f - 1.5) of the bought value. Against Chainlink the
  likely cause of a disagreement is not a manipulated price but a feed that has drifted from the market, or one the
  listing named wrongly; check the feed's `description()` against docs.chain.link when a target looks off. Watch for a
  config that fell due around the snapshot as well: whoever executes a due config first decides which of two reviewed
  configs the snapshot and the settlement read (CR-I09).
- **Zap calls take a params struct.** `MintParams {index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to,
  deadline}` with `MintLeg {v3Path, v4Path, maxAmountIn}`, and `BurnParams {index, expectedNonce, shares, tokenOut,
  minAmountOut, legs, to, deadline}` with `BurnLeg {v3Path, v4Path, minAmountOut}`. `legs` has one entry per component,
  in component order. `expectedNonce` is `rebalanceNonce()` when the legs were quoted; after a rebalance, re-quote.
- **One venue per leg.** A leg carries a packed `v3Path` **or** a `v4Path`, never both. Both empty means "no swap",
  which is only valid for the pass-through leg, the one whose component already is the stable on a mint or `tokenOut`
  on a burn. Anything else is `BadRoute(i)`. There are no mixed-venue legs: a single leg cannot split across V3 and V4.
- **V3 routes.** Packed paths, as before: `token(20) | fee(3) | token(20) [| fee(3) | token(20)]`. For **mint** the
  path is exact-output encoded, starting with the component and ending with the stable (e.g. `WBTC 500 WETH 500
  USDC`). For **burn** it is exact-input encoded, starting with the component and ending with `tokenOut`.
- **V4 routes.** An array of `PathKey {address intermediateCurrency, uint24 fee, int24 tickSpacing, address hooks,
  bytes hookData}`, one per hop. Every hop must be hookless: `hooks` zero and `hookData` empty, or `BadRoute(i)`. Each
  entry carries the pool of the hop it closes, and pairs `intermediateCurrency` with whatever the previous step held.
  The **burn** direction is the natural one — the router walks it forwards from the component, so the last entry names
  `tokenOut`. The **mint** direction is walked backwards from the component, so the *first* entry names the stable and
  the list is the burn route reversed. Getting that the wrong way round is `BadRoute(i)`; getting a pool wrong fails in
  the swap. Live V4 pools for these components are paired against **native ether**, which is `address(0)`, so a V4
  route usually crosses it as an intermediate. It may only ever be an intermediate: native ether never reaches the zap,
  which has no `receive()`. Example, USDC to LINK: burn `[{ETH, 3000, 60}, {USDC, 500, 10}]`, mint `[{USDC, 500, 10},
  {ETH, 3000, 60}]`. Keep a route from visiting the same currency twice. On a mint, the pinned periphery does not hold
  a V4 exact-output route that revisits `tokenIn` to its `amountInMaximum` (upstream issue #564), so the zap's
  pre-funding is then the only bound on that leg; on a burn, a route that revisits the component can fill a later hop
  partially and return the unsold component instead of reverting (CR-I06, CR-I07).
- **A zero-amount burn leg.** A leg whose amount rounds to zero sells nothing, but its route is still validated and its
  minimum must be 0, or the burn reverts with `InsufficientOutput`.
- **Slippage.** Set a limit on every leg, not only the total; every leg is checked, including the pass-through leg that
  carries no swap. A leg limit of 0 means "overall limit only", and the overall burn limit must be non-zero. Legs that
  cross the same pool interact, so summed per-leg quotes are optimistic: a little on mainnet, several percent on thin
  pools such as the Sepolia test market. An `eth_call` of the whole zap call returns the exact amount.
- **Check quotes against an independent price.** Compare each quote with a reference price and refuse to sign when
  they diverge beyond a threshold. Send transactions through a private relay and use short deadlines.
- **Pick the venue per leg, and re-check it.** V3 and V4 depth for the same pair move independently, and neither
  contract nor script prefers one: the app is what decides. Of the seven launch components only LINK is currently
  deeper on V4. Re-measure before relying on a route.
- **Approvals.** USDC supports `permit`; USDT does not (plain `approve`), and USDT's `approve` reverts when it changes a
  non-zero allowance to another non-zero value: if `allowance(user, zap)` is not 0 (for example after a mint that
  reverted), send `approve(zap, 0)` first. Index tokens support `permit`. Approve exact amounts.
- **Fee-charging currencies are unsupported.** Zap calls revert with `TransferShortfall`. Simulate every transaction
  first and offer the direct `redeem` or `redeemSkipping` exit.
- **Label pausable components and every other issuer.** WBTC can be paused by its custodian; wstETH is Lido's; wSOL is
  Wormhole's bridged claim on an asset that lives on another chain. Show that on every index that holds one, and
  surface `redeemSkipping` plus any pending `claimOf` balance. Label the double claim too: an index holding both WETH
  and wstETH holds two claims on ether, and the staked ether behind wstETH is counted in both components' market caps.
- **Claims follow the recipient.** `redeemSkipping(shares, to, skipMask)` books the skipped components to `to`, the
  address that receives every other component, and `ClaimRecorded` names `to`. Read `claimOf(to, token)`, not
  `claimOf(msg.sender, token)`, and have a contract that redeems for a holder pass the holder as `to`, or the claim is
  the contract's and the holder never collects it.
- **Show pending proposals.** A token or config change becomes effective only between `ListingProposed` plus
  `LISTING_DELAY` and 7 days after that (`pendingTokenConfig` shows it, and `pendingTokenDecimals` the decimals it
  pinned, RT-23; `pendingIsListing` and the event's `listing`
  flag say whether it whitelists the token), and a new guardian only after `GuardianProposed` plus `GUARDIAN_DELAY`.
  Ask `listingPending(token)` and `guardianChangePending()` whether a proposal can still be executed: one that passed
  its window is dead but leaves `listingEta`, `pendingGuardian` and `pendingGuardianEta` set, so those fields on their
  own read as pending forever, and an operator watching them believes a guardian was replaced when it never was. A
  config change reshapes future rebalances of every index holding the token. `delist` also emits `ListingCancelled` when
  it drops a pending listing proposal. Treat `GuardianProposed` as a security alert: once it executes, the owner's
  config changes no longer face the old guardian's veto, so it is the earliest warning, 9 days ahead, of an unchecked
  change.
- **Returned components.** Whenever the router takes less than it was given, the unsold part goes to the recipient
  with a `ComponentReturned` event. A V3 burn leg is swapped one hop at a time, so this covers every hop, whether the
  unsold token is the component or an intermediate. A V4 burn leg is a single action, where an intermediate partial
  fill leaves an unsettled delta and the whole leg reverts, so as a rule only its first hop returns anything; a route
  that comes back to the component can return it from a later hop too (CR-I07). The sweep hands back the router's
  whole balance of the token, so a returned amount includes anything a stranger had left on the router, and a stray
  balance can never make a burn revert (CR-L02). Unsold `tokenOut` is paid out with the rest instead. Show them on the
  receipt.
- **Value an index from units, not balances.** Never derive a price from `balanceOf(index)` and `totalSupply()`.
- **ABIs.** `abi/IndexFactory.json`, `abi/IndexToken.json`, `abi/IndexRule.json` and `abi/IndexZap.json` are committed
  and regenerated by CI, which fails on a diff, so they always match the contracts; decode every event and revert with
  them (`forge inspect <contract> abi --json` reproduces them, and the interfaces in `src/interfaces/` carry the
  NatSpec). Read the timing constants (`LISTING_DELAY`, `PROPOSAL_WINDOW`, `MIN_REBALANCE_INTERVAL`, `REBALANCE_DELAY`,
  `AUCTION_DURATION`, the auction multipliers, `MIN_TURNOVER`, `MAX_COMPONENTS`, `MAX_FEED_STALENESS`) on chain rather
  than hard-coding them. The lists below are a summary as of 2026-09-24. `CompositeFeed` is not in the set: it is an
  adapter a config points at, not a contract the app calls. Errors that several contracts raise
  (`ZeroAddress`, `LengthMismatch`, `InvalidMethodology`, `TooFewComponentsForCapped`, `Unauthorized`, `NotIndex`,
  `InvalidRecipient`) are declared once, in `IXindexErrors`, which the factory, rule, token and zap interfaces extend.
- **Events.** `IndexFactory`: `IndexCreated`, `ListingProposed`, `ListingCancelled`, `TokenConfigured`,
  `TokenDecimalsRecorded` (RT-23), `TokenWhitelisted`, `GuardianProposed`, `GuardianChangeCancelled`, `GuardianSet`,
  `OwnershipTransferStarted`, `OwnershipTransferred`. `IndexToken`: `Issued`, `Redeemed`, `ClaimRecorded`, `Claimed`,
  `RebalanceStarted`, `RebalanceCancelled`, `Rebalanced`. `IndexZap`: `ZapMint`, `ZapBurn`, `ComponentReturned`.
- **Watch the ownership handover.** `transferOwnership(new owner)` emits `OwnershipTransferStarted` and
  `acceptOwnership()` emits `OwnershipTransferred`. It is the one admin change with no delay and no guardian veto: the
  second call takes effect in the block it lands in, and the new owner holds every proposal power from that moment.
  Surface both events as they happen, alongside `owner()` and `pendingOwner()`.
- **Errors.** `IndexZap`: `NotIndex`, `StaleRebalanceNonce`, `Expired`, `ZeroAddress`, `ZeroAmount`,
  `InvalidRecipient` (the zap, the index, the Universal Router, the PoolManager, the factory or the rule, RT-21),
  `LegCountMismatch`, `BadRoute(i)`, `ShortFill(i, received, required)`, `InsufficientBudget` (over `maxAmountIn`, or
  over the pass-through leg's own `maxAmountIn` when it sets one), `InsufficientOutput`, `TransferShortfall`.
  `IndexToken`: `NotFactory`, `NotInitialized`, `InvalidComponents`, `ZeroShares`, `ZeroAddress`, `InvalidRecipient`
  (also for a share transfer to the index itself, its factory or its rule, CR-I01 and RT-21), `InvalidSkipMask`,
  `NothingToClaim`, `TransferAmountMismatch`, `Unauthorized`, `RebalanceTooSoon`, `RebalancePending`,
  `InvalidKeepMask`, `TurnoverTooLow`, `NoPendingRebalance`, `RebalanceNotReady`, `RebalanceExpired`,
  `RebalanceUnderfunded`, `RebalanceMovedOn`, `SettlementValueTooLow(inValue, outValue, required)`, the rule's price
  errors (`startRebalance` and `executeRebalance` both price the moving legs), and OpenZeppelin's ERC-20 and ERC-2612
  errors. `IndexFactory`: `EmptyString`, `InvalidComponentCount`, `LengthMismatch`, `TokenNotWhitelisted`,
  `DuplicateToken`, `InvalidUnits`, `InvalidMethodology`, `TooFewComponentsForCapped`, `IndexAlreadyExists`,
  `NotAContract`, `NotConfigured`, `SupplyChangeTooLarge(token, inForce, proposed)`, `ListingPending`,
  `NoPendingListing`, `ListingNotReady`, `ListingExpired`, `NotWhitelisted`, `DecimalsChanged(token, proposed,
  current)` (RT-23), `NoPendingGuardianChange`, `GuardianChangeNotReady`, `GuardianChangeExpired`, `Unauthorized`,
  `RenounceDisabled`, and the rule's config errors, since proposing and executing a config both run `checkConfig`.
  `IndexRule`: `ZeroAddress`, `InvalidFeed(token, feed)` (a feed that is zero or has no code; one that has code but
  does not answer as an aggregator reverts with its own error or none, CR-I10), `InvalidStaleness(token,
  maxStaleness)`, `InvalidDecimals(token, tokenDecimals, feedDecimals)`, `InvalidPrice(token, answer)`,
  `StalePrice(token, updatedAt)`, `PriceTooHigh(token, answer)`, `ZeroSupply` (a config with no reference supply),
  `StartPriceTooLow`, `InvalidMethodology`, `TooFewComponentsForCapped`, `DegenerateBasket`, `LengthMismatch`,
  `NotIndex`. `CompositeFeed`, which a config may point at: `ZeroAddress`, `NonPositiveAnswer(feed, answer)`,
  `StaleLeg(feed, updatedAt)`, `InvalidLegStaleness(maxAge)`.
- **Swap failures arrive unwrapped.** The Universal Router wraps a command in `ExecutionFailed` only when it dispatched
  it with a low-level call, and swaps are internal calls, so what the app decodes is the pool's own error:
  `V3TooMuchRequested()`, `V3TooLittleReceived()`, `V4TooMuchRequested(uint256,uint256)`,
  `V4TooLittleReceived(uint256,uint256)`, `CurrencyNotSettled()`, or another PoolManager error. These replace the
  `STF` / `Too much requested` / `Too little received` strings SwapRouter02 raised. Decode them against the router's
  own ABI; they are not in `abi/IndexZap.json`, which carries only the zap's own errors.

## Whitelist policy

Standard ERC-20s only: no fee-on-transfer, rebasing, or ERC-777/callback tokens; 6-18 decimals; the address must be a
contract. `issue` verifies the received amount. How a token's supply is minted does not matter to the rule, which never
reads a token's own `totalSupply` (see **Supply** below), so a wrapper or a liquid-staking token whose supply anyone can
mint and burn is acceptable. A component that can be paused or blacklisted, such as WBTC, must be labelled in the app.
USDC and USDT are fine to mint *with* but should not be *components*.

Every listed token carries a config that the rule validates:

- **Feed:** a Chainlink-shaped USD aggregator — a contract answering `latestRoundData()` and `decimals()` — whose
  answer, scaled by the token's own decimals, is the token's price in dollars. WBTC has no USD feed, so it is listed
  with a `CompositeFeed` over BTC/USD and WBTC/BTC; that product is also what prices a depeg of the wrapper against
  the coin it wraps. Both the feed's and the token's decimals must be at most 18. The feed's are read live on every
  call, never cached, so a benign proxy repoint is absorbed rather than turned into a halt. The token's are read live
  only by the listing check and recorded when the config comes into force (`tokenDecimals`), so pricing a listed token
  never calls it, and a component whose contract stops answering is still priced from its feed (RT-01).
- **Maximum staleness:** the oldest answer the rule will price the token from, in seconds, at most
  `MAX_FEED_STALENESS` (2 days). The policy is the feed's heartbeat plus half an hour: 5,400 for a 1-hour feed and
  88,200 for a 24-hour one. What bounds how far a 24-hour feed's answer can be from the market is its deviation
  threshold, not its heartbeat — a Chainlink feed also publishes whenever the price moves past that threshold — so the
  0.5% feeds are the ones worth a long bound, and the figure should be the feed's own, not a round number.
- **Supply:** a reference supply, in the token's raw units, which every config must carry (`checkConfig` reverts
  `ZeroSupply` without one). The rule never reads a token's own `totalSupply`. It once did for a config with no
  reference figure, and wstETH was listed that way: anyone could flash-borrow a third of all wstETH at no fee, unwrap
  it, call the permissionless `startRebalance` and wrap it back, all in one transaction, and the snapshot then priced a
  supply that never existed, forcing a rebalance the rule would refuse or suppressing one that was due (CR-M01). A
  figure in the config cannot move inside a transaction. Wrapped and bridged assets use the underlying's circulating
  supply: on-chain WBTC is the wrapped float, not bitcoin's supply, and wSOL on Ethereum is the bridged float, not
  solana's. Reference supplies drift and are refreshed with a config change, which may move one by at most
  `MAX_SUPPLY_CHANGE` (an order of magnitude) at a time. Only a token's first config is unbounded; every later one,
  a relisting's included, is measured against the figure in force (CR-L03). A config once carried a list of excluded
  holders, whose balances the rule subtracted with a live `balanceOf` inside the rebalance snapshot; one exclusion a
  third party could fund and drain would have made that token's market cap manipulable within a single transaction, so
  the list is gone. A reference supply within the bound is accepted as given, so a figure that is stale or mistyped by
  less than an order of magnitude sends that component to its floor at the next rebalance: check the number while the
  proposal is still cancellable.
- WETH is an ordinary entry, with ETH/USD and ether's supply as its reference figure. Nothing is special-cased any
  more.

A feed's identity cannot be checked on-chain: `description()` is just a string the aggregator returns, so nothing in
the contracts stops a proposal from naming an aggregator that reports the wrong asset, or one under someone else's
control. What guards it is procedure — the 2-day listing delay, the guardian's veto, `ConfigureWhitelist` logging each
feed's `description()` at propose time for the signers to read against docs.chain.link, a fork test that pins every
shipped feed's description, decimals, freshness and circuit-breaker bounds, and a second one that pins, token by token,
which feed and staleness bound each default entry names, against a table written independently of the list (CR-L08).
WBTC's `CompositeFeed` is checked by its code rather than by what it reports: `checkWbtcFeed` compares its runtime
code, less the compiler's metadata tail, with a genuine adapter built over the same two feeds and bounds, because a
lookalike or a proxy answers every getter identically (CR-L04). Treat a listing proposal as a trust decision about a
feed, and verify the address itself, not the string it reports.

Listings and config changes take two steps: the owner calls `proposeListing(token, config)` to list a token (or change a
listed token's config), or `proposeConfig(token, config)` to change the config of a listed or delisted token without
listing it, and from `LISTING_DELAY` (2 days) until a further `PROPOSAL_WINDOW` (7 days) anyone can call
`executeListing`; after that the proposal expires. Until then the owner or the guardian can `cancelListing` it, and
either can `delist` a token at any time. Delisting only affects indexes created afterwards, keeps the config existing
indexes rebalance with, and cancels a pending `proposeListing` proposal, so a delisted token is listed again only
through a fresh proposal and delay.

## Default list: feeds and execution depth

Seven components, chosen on 2026-09-22: one wrapper per underlying asset where one exists, nothing issued by Coinbase,
and a Chainlink USD feed for each. Five is the minimum the capped methodology takes, so seven leaves room to drop one.

| Token | Feed | Heartbeat / deviation | Category | `maxStaleness` | Reference supply |
|---|---|---|---|---|---|
| WETH | ETH / USD | 1h / 0.5% | low | 5,400 | ether's circulating supply |
| wstETH | wstETH / USD Calculated (STETH / USD x `stEthPerToken`) | 24h / 0.5%, input 1h / 1% | custom (input medium) | 88,200 | its own supply on 2026-09-23 |
| WBTC | BTC / USD x WBTC / BTC, through `CompositeFeed` | 1h / 0.5% and 24h / 0.5% | low and medium | 88,200 (legs 5,400 and 88,200) | bitcoin's circulating supply |
| wSOL | SOL / USD (no peg leg) | 24h / 2% | low | 88,200 | solana's circulating supply |
| UNI | UNI / USD | 1h / 1% | low | 5,400 | circulating |
| LINK | LINK / USD | 1h / 0.5% | low | 5,400 | circulating |
| AAVE | AAVE / USD | 1h / 1% | low | 5,400 | circulating |

Addresses are in `script/MainnetAddresses.sol`, each feed with its heartbeat, deviation and Chainlink category in a
comment; `test/fork/MainnetAddresses.fork.t.sol` checks every address on-chain and pins which feed and bound each entry
of the list names. The category is Chainlink's own risk label, read from its reference data directory on 2026-09-23. It
lives off chain, so no test can pin it: read it again before a config is renewed. Every supply is a dated reference
figure, including wstETH's, whose own `totalSupply` anyone can move inside a transaction (CR-M01).

- **Prices and execution are now separate problems.** A component needs a feed to be *priced* and a pool to be
  *traded*, and the two no longer have to be the same venue or even the same protocol. That is what makes the list
  above short by choice rather than by pool depth: the binding constraint on adding a token is now whether enough
  depth exists to mint and burn it at size, and whether it has a feed at all.
- **Depth, measured on 2026-09-22.** Of the seven, only LINK is deeper on V4 than V3 (about 6.6x). WBTC (0.26x), UNI
  (0.66x) and AAVE (0.86x) are deeper on V3; that ratio is why the zap routes through the Universal Router, which
  reaches both, rather than committing to one. The app picks per leg. Live V4 pools for these components are paired
  against native ether, not WETH; the WETH-paired V4 pools hold nothing.
- **Left out and why.** ONDO, ENA, MORPHO, ETHFI, PENDLE, OHM, SYRUP, CRV and LDO: the user dropped them from the
  launch list on 2026-09-22. Their pools were thin (25 to 87 WETH, one twentieth to one hundredth of LINK's) and
  several have no Chainlink USD feed, so both halves of the problem bound them. tBTC: one BTC wrapper is enough, and
  WBTC's pools are far deeper. weETH and mETH: restaking derivatives. Their feeds' category does not set them apart,
  since wstETH's own feed is a calculated one in Chainlink's custom category too. Tokens of other chains without a
  mainnet wrapper remain out of scope entirely.
- **wstETH's feed is calculated, not a market feed.** Each answer is Chainlink's STETH/USD answer times the on-chain
  `stEthPerToken`, republished about a round later, so it moves in the 1% steps of its input and sits 1% to 1.5% from
  ether's price times `stEthPerToken` as a matter of routine, not the 0.5% its own threshold suggests. It prices the
  stETH peg on the way (CR-I17).
- **wSOL is a bridged asset, priced at par.** Wormhole's wrapper, symbol `SOL`, 9 decimals. Holding it means holding
  Wormhole bridge risk on top of market risk; the app labels that, as it labels WBTC's custodian and Lido. Unlike
  WBTC, which is priced through its WBTC/BTC leg, wSOL has no peg leg, because no feed prices Wormhole's SOL against
  SOL on Ethereum: in a bridge failure the rule still values wSOL at SOL's price, and a rebalance that buys wSOL would
  take unbacked tokens at that price for real components, within the clip and past the settlement check, which values
  both sides with the same feed. The guardian's answer is a keep mask or a cancel, then a delist; see the runbook
  (CR-L05). wSOL is also the thin one on the launch list: about a million dollars of Uniswap depth on Ethereum
  against a bridged float of about $37M, while a capped index can give it the full 20% (CR-I39). The app should
  size wSOL legs, and say so, before an index holding a large share of it is minted or burned at size.
- **Two ETH wrappers double-count.** WETH carries ether's whole supply and wstETH carries its own, so the staked ether
  behind wstETH counts in both market caps. Under the capped methodology the 30% cap bounds what that can do to an
  index; under uncapped it does not. Deliberate, and labelled.

## Known limitations

- Airdrops, rewards and governance votes that accrue to tokens held by an index cannot be claimed or used; by design
  there is no admin who could sweep them.
- A rebalance clears only when the value it trades covers gas and swap costs many times over, so small indexes on
  mainnet rarely rebalance. An unfilled auction expires, and for `REBALANCE_DELAY` afterwards only the owner and
  guardian can restart it, so a griefer who distorts every snapshot so that even 0.9 does not pay an executor cannot
  take every restart. The cost is that an honest restart after an expiry also waits those two days (less a second,
  CR-I02) unless the owner or guardian starts it. A stranger can no longer distort a snapshot through the rule's
  inputs: prices come from feeds, and every supply is a reference figure in the config, which nothing inside a
  transaction can move. That was not true of the version audited on 2026-09-23, which read a live `totalSupply` for a
  config without a reference figure; wstETH was listed that way, and its supply could be unwrapped around a snapshot
  with free flash-borrowed wstETH (CR-M01). What the hold-off guards against now is a stranger restarting at whichever
  published round suits it.
- An index with so little supply that a settlement moves no raw unit at all is priced at parity, so its units follow the
  rule whoever executes. One that still moves a few wei does decay with the auction, and a lone executor can then pick
  the multiplier in [0.9, 1.5] for next to nothing: it sets the level of a near-empty index within the half-to-2.5-times
  bound but moves no holder's value. What it can move is bounded by the rounding of `amountsIn`, under one raw unit of
  each growing component; before VR-03 a second truncation in the rule's own targets stacked on top of that, and an
  executor delivering nothing at all settled and kept 1.98 raw units per growing component. The same rounding is why
  the settled units' bound is 2.5 times plus one raw unit: a component held at a single raw unit can settle at three
  (CR-I03).
- Without competing executors, a filler can wait for the 0.9 floor and settle 10% under the snapshot's rate; the notice
  period also lets traders position ahead of a public rebalance. The band bounds that multiplier on the bought legs at
  the snapshot's prices and nothing else, and settlement is a fixed-rate trade against targets up to three days old. The
  settlement-time ratio check is what bounds the rest: the index has to receive at least 87.5% of what it pays out at
  the feeds' answers in the settling block (`MIN_SETTLEMENT_RATIO`), so the worst case is 12.5% of the traded value
  at those answers rather than the band plus whatever the market did over three days. At market prices it is 12.5%
  plus about 0.875 times the gap between how far the bought legs' answers sit from the market and how far the sold
  legs' do, since a feed's answer trails the market by up to its deviation threshold between rounds and, during a
  fast move, by a round's minute or two of latency beyond it. The ratio was 85% until 2026-09-23: replaying 26 months
  of feed answers against exchange prices, the audit measured takes above the documented 15% in about 4% of auctions,
  up to about 21%, and on the same data a ratio of 0.87 to 0.88 cut those to a few hundredths of a percent without
  expiring an auction a competitive executor would have filled (CR-L06).
  Sold components appreciating against bought ones over two or three days is ordinary for crypto constituents, and
  past that point the auction simply expires unfilled. The guardian's check during the notice period still catches a
  snapshot the market has left behind before it reaches the auction.
- A stale feed halts the money path for every index holding that token. `startRebalance`, `price`, `navPerToken`,
  `weights`, `initialUnits` and `checkConfig` all revert `StalePrice(token, updatedAt)`, and under the capped
  methodology a keep mask cannot route around it, because a kept component's market cap still scales every other
  component's weight. Issue, redeem, `redeemSkipping` and `claim` keep working throughout — they read no price at all
  — so holders can always leave; what stops is rebalancing and every displayed price. The 24-hour feeds are the
  exposure: wstETH/USD, SOL/USD and the WBTC/BTC leg, where a settlement may be valued on an answer up to 24.5 hours
  old. What makes that tolerable is the deviation threshold rather than the heartbeat, since a feed also publishes
  whenever the price moves past it: 0.5% for WBTC/BTC, 2% for SOL, and for wstETH the 1% of the STETH/USD feed it is
  calculated from, which leaves it 1% to 1.5% from the market as a matter of routine (CR-I17). A threshold is not a
  bound on how far an answer sits from the market during a fast move, which is what the settlement bound above
  allows for (CR-L06). Nobody can cause the outage and nobody can clear it, which is the trade against a pool oracle,
  where a third party could grief a snapshot but anyone could also fix it by trading.
- **Chainlink is now a trusted dependency**, and a different one from the old trust in pool depth. A feed owner can
  repoint or deprecate an aggregator; that direction fails closed, because a dead feed goes stale and a repointed one
  is read live for its decimals. What does not fail closed is an aggregator that reports a wrong answer: there is no
  second price source, so the rule would use it, bounded only by `MAX_PRICE` and by the guardian noticing during the
  notice period. A second source is not in v3.
- **A feed stuck at a circuit-breaker bound** is not caught at runtime. The LUNA/Venus failure — an aggregator pinned
  at its `minAnswer` while the market fell far below — would read as a valid, fresh answer. The rule does not check
  those bounds on every call, because they are a property of a feed rather than something a third party can move.
  Instead the fork test refuses a feed whose circuit-breaker bounds sit within a hundredfold of its current answer,
  which catches the setup before it ships; every shipped feed has its breaker disabled, and clears that margin by
  dozens of orders of magnitude. Operationally, `cancelRebalance` and a delist are the escapes afterwards.
- **A feed's identity cannot be verified on-chain.** `description()` is a string the aggregator returns, so nothing in
  the contracts distinguishes the real LINK/USD feed from a contract that returns the same string. The listing delay,
  the guardian's veto and the signers' own check of the address against docs.chain.link are the whole on-chain
  defence; off chain, the fork tests pin which feed each default entry names (CR-L08), and the listing script checks
  WBTC's adapter by its code (CR-L04).
- **wSOL is priced at par with SOL.** No feed prices Wormhole's SOL against SOL on Ethereum, so a bridge failure goes
  unpriced: the rule keeps valuing wSOL at SOL's price, and the settlement check cannot tell, because it values both
  sides with the same feeds. A rebalance that buys wSOL during a depeg takes unbacked tokens for real components,
  within the clip. The guardian's answer is a keep mask or a cancel, then a delist (CR-L05); see the runbook. wSOL
  stays on the launch list, labelled, with that recourse: the owner's call on 2026-09-23, after the audit suggested
  reconsidering it.
- A component whose feed is deprecated or stuck takes no config at all, because the listing check prices it. Delisting
  and, under the uncapped methodology, the keep mask are the escapes. Unlike a thin pool, nothing recovers by itself:
  a deprecated feed needs a replacement config through the listing flow. A component whose token contract stops
  answering takes no config either, since the check reads its decimals, but needs none: while its feed answers, the
  keep mask routes around it under both methodologies (RT-01).
- **A token's decimals are recorded at listing.** A component whose `decimals()` changes afterwards, which only an
  upgradeable token such as wSOL or AAVE could do, is priced at the recorded decimals, wrong by a power of ten, until
  a config refresh records the new ones: propose the same config again, which the supply bound allows and which the
  listing script proposes when the token is named in `LIST` and the recorded and live decimals disagree, and cancel
  any snapshot in between. If
  the token rescaled its raw balances as well, its reference supply has to move too, in steps within
  `MAX_SUPPLY_CHANGE` (RT-01, RT-22). The decimals are pinned when a config is proposed, and `executeListing` refuses
  one whose token's decimals moved since (`DecimalsChanged`), so the record only ever changes to what was on show
  during the delay and the guardian's veto, and `TokenDecimalsRecorded` announces every change (RT-23). That also
  stops a token's admin from repricing it through `decimals()` just before a snapshot, which a live read allowed.
- **An exit sent during the auction can be overtaken by the fill.** Whoever holds shares in the block that settles
  pays the auction's haircut, and the executor picks that block, so it can order its fill ahead of a redeem or a
  guardian cancel it sees in the public mempool. No bound moves: the exiting holder pays the same per-share take as
  every other holder, within the settlement bound above, though the executor's total grows by that holder's share. But
  the notice is the only reliable window to leave before a snapshot settles; during the auction, use a private relay
  (RT-02). Shares minted while a rebalance is pending share the haircut of any fill that lands after them, whatever
  the ordering, and a relay does not avoid that.
- **A hooked V4 pool cannot be routed through.** The zap rejects any V4 route whose hops carry hooks or hook data, so
  a component whose only V4 depth sits behind a hook is reachable on V3 only. Every live pool for the seven is
  hookless. Relaxing this means deciding which hooks are safe to call inside a swap, which is a larger question than
  the zap should answer.
- **A `tokenIn` that calls back into the zap is unsupported**, alongside fee-on-transfer currencies. The zap pre-funds
  the Universal Router with exactly a leg's cap and sweeps it back within the same `execute`. The sweep's minimum is
  zero, so it bounds nothing: the pre-fund is the bound (CR-I14, RT-11). A currency that hands control to the user
  mid-transfer is outside what was reasoned about. Mint and burn currencies are the user's choice, so the app should
  offer only the ones on the list.
- `executeListing` is permissionless and runs the rule's config check again on the stored config before applying it,
  so a feed that went stale or was deprecated during the notice is not whitelisted on a check up to nine days old.
  Nobody can grief that: unlike a pool, a live feed cannot be made to fail the check by a third party. The flip side
  of permissionless execution is that whoever acts first after a config's eta decides when it takes effect, so between
  the eta and its execution the first caller chooses which of two reviewed configs prices a snapshot or a settlement.
  Both were reviewed, which bounds it; execute a due config promptly (CR-I09).
- A reference supply is accepted as given within its bound, so a figure stale or mistyped by less than an order of
  magnitude drives that component toward its floor at the next rebalance and hands the difference to the auction. It is
  owner-only, behind the 2-day listing delay and the guardian's veto, which makes it an operational hazard rather than
  an attack. A token's first config has no figure to be measured against, so its first reference supply is bounded
  only by review; the bound applies to every config after it, a relisting's included (CR-L03).
- `cancelRebalance` has no window and no rate limit, so a hostile or compromised guardian can cancel each proposal at
  the last second of its auction and hold rebalancing off, with the units drifting from the rule meanwhile. It moves no
  funds and takes nothing, holders redeem throughout, and the owner ends it by replacing that guardian: 7 days of
  notice the guardian cannot cancel, since it may only cancel its own removal and not its replacement. Rate-limiting
  the cancel would trade that bounded stall for the guardian's ability to stop a second distorted snapshot in a row,
  which is what the power is for; this is a trust assumption of the guardian role. A guardian can also stall without
  cancelling: a keep-mask rebalance that leaves only a pair of components active can clear `MIN_TURNOVER` on a sliver
  of the index, and once filled it restarts `MIN_REBALANCE_INTERVAL` for everyone, so the stall can outlast the
  guardian's replacement by up to a month and never shows as a cancel. While a guardian replacement is pending, the
  owner cancels every keep-mask proposal the outgoing guardian starts during its notice, and monitors alert on
  `RebalanceStarted` with a non-zero `keepMask`, not only on `RebalanceCancelled` (RT-07).
- A permanently frozen component needs the guardian's keep mask at every rebalance, and under the capped methodology
  its feed must still be fresh, because its market cap scales every other component's weight; its `balanceOf` need
  not be readable.
- A multi-hop **V3** burn leg costs one router call per hop, and a hop that sells nothing reverts the burn instead of
  leaving the next hop to spend the zap's balance. A **V4** burn leg is one call whatever its length, which is not
  only cheaper: inside a single V4 action an intermediate partial fill leaves an unsettled delta and the leg reverts
  atomically, so nothing can be stranded mid-route. The cost is that a V4 leg is all-or-nothing where a V3 leg
  degrades hop by hop. The one exception is a route that comes back to the component, whose later hop can fill
  partially and return the unsold component instead of reverting; that outcome is safe (CR-I07).
- **Zap gas grows with hop count, and nothing on chain bounds it.** A V3 burn leg swaps every hop in its own router
  call, so at `MAX_COMPONENTS` (20) a zap burn stays under EIP-7825's per-transaction cap of 2^24 gas only while its
  routes stay within about eight hops a leg through shared pools, or five through pools nothing else in the call
  touches. The app should keep routes to three or four hops, and refuse or reroute through V4 any zap call whose
  simulated gas exceeds about 14M (CR-I08). `redeem` and `redeemSkipping` stay under 1M gas at the same size, so the
  in-kind exit always fits.
- The zap is pinned to **Universal Router 2.0.0** rather than the 2.1.x line, whose command inputs carry an extra
  per-hop price array and which shipped a change its own authors later reverted. Moving to a newer router means a new
  zap, which is what "the zap is stateless and replaceable" is for; the token, rule and factory do not depend on it.
- The capped methodology's 30% and 20% are ceilings, and the top ceiling itself follows the lead: 20% at a tie between
  the two largest market caps, rising in proportion to the lead to the full 30% once the largest is twice the
  runner-up. A crossing between the two therefore moves weight only in proportion to how far apart they were: nothing
  at a tie, and at most 10 percentage points, which takes a doubling of one against the other to reach. Before VR-01
  the 30% was assigned outright and any crossing moved 10 to 12.5 points however close the caps were; VR-01 made the
  two figures ceilings, but the top one still went to whichever cap was larger, so two leaders both above 20% still
  swapped 10 points on a one-wei move (CR-L01). A one-basis-point move on one price could then put a tenth of an
  on-methodology index up for auction from any address. The continuous top ceiling closes that, and is a change to
  the methodology (see "Product decisions" in `AGENTS.md`).
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`). The factory's deployment code is close to the EIP-3860
  initcode limit. Re-check both before deploying to any other chain.

## Mainnet addresses

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
| Chainlink ETH / USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink wstETH / USD Calculated | `0x164b276057258d81941e97B0a900D4C7B358bCe0` |
| Chainlink BTC / USD | `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c` |
| Chainlink WBTC / BTC | `0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23` |
| Chainlink SOL / USD | `0x4ffC43a60e009B551865A93d232E33Fce9f01507` |
| Chainlink UNI / USD | `0x553303d460EE0afB37EdFf9bE42922D8FF63220e` |
| Chainlink LINK / USD | `0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c` |
| Chainlink AAVE / USD | `0x547a514d5e3769680Ce22B2361c10Ea13619e8a9` |
| Uniswap Universal Router 2.0.0 | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap QuoterV2 (V3 quotes) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Uniswap V4 Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Uniswap V4 StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| IndexFactory / IndexRule / IndexZap / WBTC `CompositeFeed` | not deployed yet |

All feeds are 8-decimal aggregator proxies. The scripts read mainnet addresses, feeds and reference supplies from
`script/MainnetAddresses.sol`, which `test/fork/MainnetAddresses.fork.t.sol` checks on-chain — tokens by symbol and
decimals, feeds by `description` and `decimals`, the router by its `poolManager()`. The quoters and the V3 pools the
fork tests use are in `test/fork/ForkAddresses.sol` and `ARCHITECTURE.md`; no contract reads them.

## Development

```bash
forge build --sizes
forge fmt
forge test                      # unit, fuzz, invariant and security regression tests, no RPC needed
forge coverage                  # 100% on every file

# end-to-end against the real Universal Router, V3 and V4 pools, Chainlink feeds, USDC and USDT
# (skipped when the env var is unset)
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# non-archive RPCs only serve recent state; override the pinned block:
MAINNET_RPC_URL=https://... FORK_BLOCK=<recent block> forge test --match-path 'test/fork/*'
```

CI (`.github/workflows/test.yml`) checks that every submodule commit matches `foundry.lock`, then runs fmt, build,
`forge lint -D notes`, tests, 100% coverage on every file (offline suites) and the Wake detectors on `src/`, with pinned
Foundry and Wake versions. Pushes to `main` and pull requests into it from this repository fail until a
`MAINNET_RPC_URL` repository secret exists, so the fork tests always run there; it needs an archive node for the pinned
fork block. Pull requests from forks get no secrets and skip the fork suites, so re-run them before merging.

### Deploy

Never put a private key in `.env`. Import the deployer key once into an encrypted keystore, or use a hardware
wallet with `--ledger`:

```bash
cast wallet import deployer --interactive
cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
# forge loads .env by itself: with MAINNET_RPC_URL set, plain `forge test` also runs the fork suites (see FORK_BLOCK)
source .env
forge script script/Deploy.s.sol --rpc-url mainnet --account deployer --sender <deployer address> --broadcast --verify
```

`OWNER` and `GUARDIAN` are required and must differ. On mainnet the owner must be a contract that is not an EIP-7702
delegated account, and a Safe must need at least two signatures and have no enabled module, because a module acts as the
Safe without signatures (keep it that way after deployment; the script cannot see later changes). The guardian must not
be the broadcasting key, which must hold no role, and neither role may be one of the market contracts: the router and
its PoolManager everywhere, and on chain 1 also every token, mint currency and feed in `script/MainnetAddresses.sol`,
since a role pasted from the wrong line of an address list is the slip this catches (CR-I37). `UNIVERSAL_ROUTER`
defaults to the mainnet deployment on chain 1, where any other value is rejected, and is required anywhere else; it is
the script's only market address, because the rule and factory now depend on no Uniswap contract at all. On chain 1
the script also deploys the WBTC `CompositeFeed` over BTC/USD and WBTC/BTC and logs it as `WBTC_FEED`, with its runtime
code hash: record both, because `ConfigureWhitelist` needs the address for the default list and, before proposing it,
compares its code, less the compiler's metadata tail, with an adapter it builds over the same two feeds and bounds.
Reading the adapter's getters is not enough: a proxy or a lookalike answers every one of them identically, and its
controller would then price WBTC for every index (CR-L04).

**Deployment record.** `forge script --broadcast` writes `broadcast/Deploy.s.sol/<chain id>/run-latest.json`: the git
commit, each transaction with its init code, and the factory, rule, implementation and zap addresses. Broadcast from a
clean, committed tree so the recorded commit is the deployed source, commit the record with the README address table (on
mainnet with `git add -f`: `.gitignore` keeps chain-1 records out, because fork rehearsals keep chain id 1), and verify
the source on the explorer (`--verify` needs `ETHERSCAN_API_KEY`). Anyone can then rebuild that commit with `forge
build` and compare `cast code <address>` with the build's runtime code (immutables differ only in their slots). The
deploy log ends with the runtime code hash of the factory, the rule, the implementation and the zap: record them with
the addresses, and `Deploy.checkDeployment(factory, zap)` re-reads them later (it also refuses a factory and a zap that
are not one deployment) so a deployment can be checked against its record at any time.
Addresses come from the deployer's nonce, not CREATE2: the owner and guardian are constructor arguments, so a
deterministic address would still change with them, and nothing pins the factory address across chains.

Listing components takes two runs of `script/ConfigureWhitelist.s.sol`, or the equivalent calls through the Safe:

```bash
# owner is a key you hold (testnets and local forks only; a contract owner such as the mainnet Safe cannot sign, and
# propose mode then reverts with OwnerIsContract: use safe mode below):
# propose every entry that is not pending and not already listed with exactly its config; a token never listed only
# when LIST names it
LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> LIST=<tokens to list> forge script script/ConfigureWhitelist.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
# owner is a Safe: print the same proposals as calldata to sign in the Safe app (any account, nothing is broadcast);
# LIST=all on the launch run only, and unset on every later run
LISTING_MODE=safe FACTORY=0x... WBTC_FEED=0x... WHITELIST=default LIST=all forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account: execute every proposal that is due
LISTING_MODE=execute FACTORY=0x... WBTC_FEED=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`WHITELIST` is `default` for the mainnet list, or comma-separated entries `token:feed:maxStaleness:referenceSupply`,
all four required, where `feed` is the token's Chainlink-shaped USD aggregator or a `CompositeFeed` over two of them,
`maxStaleness` is the oldest answer the rule will price the token from in seconds, and `referenceSupply` is in the
token's raw units and non-zero. The fourth field used to be optional, and an entry without it meant the token's own
supply, so a routine feed refresh written as three fields moved WBTC's supply 173-fold in one step, past the bound
that exists to catch exactly that slip (CR-L03); a three-field entry now reverts `MalformedEntry`. The default list is
the seven components of "Default list: feeds and execution depth" above, and needs `WBTC_FEED` set to the
`CompositeFeed` that `Deploy` logged: the script compares its code with a genuine adapter over both legs and their
staleness bounds, reverting `WrongCompositeFeed` on any other contract. Reference supplies are CoinGecko's
circulating figures from 2026-09-22, except wstETH's, which is its own supply at block 26,039,211 on 2026-09-23.

Propose mode skips any entry the rule would reject, any entry outside the whitelist policy the script can check (a token
with code, 6 to 18 decimals, no USDC or USDT, a feed with code, a reference supply), and any entry that moves a
reference supply in force by more than `MAX_SUPPLY_CHANGE`, which the factory would refuse; it logs why. Safe mode
applies the same checks, because a Safe batch sends every proposal in one transaction and one the factory refuses takes
the rest down with it (CR-I38). It logs each token's symbol beside its feed's `description()` (a token whose `symbol()`
is not an ABI string, such as a bytes32, shows as `?` rather than stopping the run, RT-25), and each reference supply
in whole tokens, where a decimals slip shows — read both before signing, because the `description()` is the only
human-readable evidence of what a feed address actually reports, and the contracts cannot check it. A token never listed
gets a first-listing proposal only when it is named in `LIST=<token>[,<token>...]`, or `LIST=all` for every entry of the
run's `WHITELIST`; any other never-listed entry is skipped with its reason. Nothing on chain records that the guardian
cancelled a first listing, so a routine refresh with the same list used to propose the vetoed listing again, unlabelled
among the refreshes, and one missed veto window let anyone's execute run list it (RT-06). Set `LIST` only on the run
that lists a token, and leave it unset on a routine refresh, so a cancelled first listing stays cancelled until the
operator names it again. `LIST` never relists a token: one the guardian delisted gets only `proposeConfig` changes;
set `RELIST=<token>[,<token>...]` to propose listing it again, and if a config-only proposal for that token is already
pending, propose mode says so and the relisting waits until it is cancelled. A `WHITELIST` that names a token twice
reverts `DuplicateEntry` in every mode, because safe mode decides every entry against the same state and the second
proposal would revert the whole Safe batch (RT-24). Propose and safe mode also propose the config in force again for a
token whose `decimals()` no longer matches the factory's record, which the rule prices it with until a config for it
is executed, when `LIST` names the token: like a first listing, no entry field asks for it and nothing on chain
records a veto of the last one, so a routine run skips it, and its label reads `proposeConfig (records decimals 18 ->
17)` (RT-22). Execute mode never proposes anything. It executes only a proposal whose pending config is exactly
the entry's, and reports a config change that leaves the token delisted as what it is rather than as a listing. It asks
the rule first and skips, with the reason, a due config the rule now rejects, such as one whose feed went stale during
the notice, and a due proposal whose token changed its decimals since it was proposed, which the factory refuses with
`DecimalsChanged` (`pendingTokenDecimals` shows what was pinned) and which has to be cancelled and proposed again, so
one such entry no longer aborts the run and leaves every other due proposal unexecuted (CR-I38, RT-22, RT-23).
`LISTING_MODE=status` is read-only: for every entry it logs whether the token is listed with the entry's config and
any pending proposal with its window, and flags an entry whose recorded, live or pinned decimals disagree; `status()`
returns all three in its report. For a local stack: `anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against
`http://127.0.0.1:8545`; the fork keeps chain id 1, and `.gitignore` keeps those rehearsal records out of git. A
rehearsal on a Sepolia fork keeps chain id 11155111 in the same way, and `.gitignore` keeps those out too, so a real
Sepolia record is added with `git add -f` (CR-I40). An ignore rule does not cover a file git already tracks: a
rehearsal still overwrites the committed `run-latest.json` files, so check `git status` after one and restore them
with `git checkout -- broadcast/`.

In the Safe app, safe mode's output becomes one Transaction Builder batch. Safe mode prints each proposal as a label
line, `proposeListing` or `proposeConfig` with the token's symbol and address, followed by its calldata line; each
calldata line is one transaction to the factory with value 0 and that line as custom data. Read the labels before
signing: a `proposeListing` line in a routine refresh is a listing (RT-06). Two signers sign it, and one executes it.

### Operations runbook

No bot runs Xindex, so these duties have owners and deadlines. Watch the events that start each clock.

| Duty | Starts with | Deadline | Who | How |
|---|---|---|---|---|
| Execute a listing or config change | `ListingProposed` | `eta + PROPOSAL_WINDOW` (2 to 9 days after proposing), or it expires silently | anyone, owner signers first | `LISTING_MODE=execute` at the eta, not days later: until it runs, whoever executes first picks the moment the new config takes over, and with it whether a snapshot or a settlement in between reads the old config or the new one (CR-I09). Check with `LISTING_MODE=status`, and `listingPending(token)` for whether a proposal can still be executed. A proposal whose token changed its decimals since it was proposed is skipped (`DecimalsChanged`): cancel it and propose it again |
| Veto a hostile listing or config change | `ListingProposed` | before `eta` | guardian or owner | `cancelListing(token)` |
| Watch a component's decimals | `TokenDecimalsRecorded` after a first listing | before the next snapshot of an index holding the token | owner signers, guardian | a changed record means the token itself changed its `decimals()`; check the token, then cancel any snapshot priced across the change (RT-23) |
| Watch keep-mask rebalances | `RebalanceStarted` with a non-zero `keepMask` | before `eta` (2 days) | owner signers | a keep mask is a guardian lever; while a guardian replacement is pending, cancel the outgoing guardian's keep-mask proposals, which would otherwise restart `MIN_REBALANCE_INTERVAL` (RT-07) |
| Check each rebalance snapshot | `RebalanceStarted` | before `eta` (2 days) | guardian | compare `pendingRebalance()` targets with targets from independent prices and the reference supplies in force; `cancelRebalance()` on a mismatch, and on a snapshot the market has since left behind, because the settlement trades at those targets up to three days later |
| Trigger the monthly rebalance | `lastRebalance + MIN_REBALANCE_INTERVAL` | none, but indexes drift from their rule | anyone | `startRebalance(0)`; on `StalePrice(token, updatedAt)` that token's feed has not published inside its `maxStaleness`, and on WBTC's adapter's `StaleLeg(feed, updatedAt)` or `NonPositiveAnswer(feed, answer)` one of its two legs is the problem. Nobody can clear either and nobody caused it: wait for the feed, or keep the component under the uncapped methodology |
| Respond to a Wormhole incident | Wormhole pauses or reports an exploit, or wSOL trades below SOL | before any auction that buys wSOL fills | guardian | the rule keeps pricing wSOL at SOL's price, and the settlement check values both sides with the same feed, so nothing on chain notices (CR-L05). `cancelRebalance()` on every index whose pending rebalance buys wSOL, restart with a keep mask on wSOL, and delist wSOL so no new index takes it; holders keep `redeem` and `redeemSkipping` throughout |
| Rebalance around a frozen component | a paused or blacklisting component, at every rebalance | each auction | guardian | `cancelRebalance()`, then `startRebalance(keepMask)` |
| Refresh drifting reference supplies | monthly review | when a supply has moved for good | owner Safe | new `MainnetAddresses` values, dated, `LISTING_MODE=safe` with `LIST` unset, so every label in the batch reads `proposeConfig`; a single change may move a reference supply by at most an order of magnitude, and the script skips one that would not. Every token has one now, wstETH's included, whose own supply moves with every wrap and unwrap |
| Re-read feed categories | before renewing a config, and monthly | none | owner signers | Chainlink's category for each feed (`script/MainnetAddresses.sol` records them as of 2026-09-23) lives off chain, so no test can pin it; a feed moving to a riskier category is worth reading before its next config |
| Watch the feeds | continuously | before a feed's `maxStaleness` runs out | app and owner signers | Chainlink deprecates and repoints aggregators. A deprecation announcement is the warning; a replacement config goes through the same 2-day listing flow, so start it before the old feed stops. |
| Re-check venue depth per leg | monthly review, and before a large mint or burn | none | app | V3 and V4 depth for the same pair move independently; the route is the app's choice, not the contracts' |
| Watch guardian changes | `GuardianProposed` | `eta` (7 days) | owner signers, guardian, app | treat it as a security alert: once executed, the new guardian's veto replaces the old one, and config changes can no longer be cancelled by the current guardian. The guardian can cancel a change to the zero address (its own removal) but not its replacement. `guardianChangePending()` says whether the change is still executable: an expired one leaves `pendingGuardian` set |
| Hand over factory ownership | the owner's decision, then `OwnershipTransferStarted` | none: it takes effect as soon as the new owner accepts | owner signers, then the new owner | `transferOwnership(new owner)`, then `acceptOwnership()` from the new owner. The one admin change with no delay and no guardian veto, so announce it first and watch both events; the new owner has to meet the rules the deploy script checks, and ownership cannot be renounced |
| Restart an index after an unfilled auction | `eta + AUCTION_DURATION` passed with no `Rebalanced` | anyone after `REBALANCE_DELAY` more | guardian first, then anyone | `canStartRebalance()`, then `startRebalance(0)` |

### Testnet (Sepolia)

Sepolia runs the contracts and timing constants on a test market. **There is no current deployment.** The addresses
this section used to carry were made on 2026-09-16 from commit `8c28c7d`, which predates both the audit fixes and this
redesign: that factory prices from Uniswap pools and its `TokenConfig` has different fields, so nothing in this
repository can drive it any more and its pending listings are not worth executing. It is abandoned, not stale. Deploy
a fresh stack with the steps below. Its records under `broadcast/*/11155111/` are kept as history only, and one of them
is an aborted first run of `create`, in which 2 of 20 transactions landed (CR-I40).

`script/testnet/SetupTestMarket.s.sol` deploys stand-ins for USDC, WBTC, LINK, UNI and AAVE as `FaucetToken`s, where
any account can `drip()` a small amount once a day. Each gets two things, which are now separate concerns: a Uniswap V3
WETH pool at mainnet prices from 2026-09-16, which exists only so the zap has a V3 route to swap through, and a
`TestAggregator` — a settable Chainlink-shaped feed — which is what the rule prices it from. Nothing reads a pool's
oracle. Each feed answers its pool's price converted at `ETH_USD8`, 2,400 dollars an ether, the ether price the pools
are sized at, so tUSDC comes out at a dollar; the feeds used to assume 3,000 against pools at 2,400, which put the
rule's index price about a quarter above what the basket cost (CR-I41). WETH is listed with Sepolia's real Chainlink
ETH/USD feed, which moves while the pools do not, so WETH drifts from the rest. Only Sepolia ETH is needed.

**No V4 pools on this market.** The V4 legs are proven on mainnet forks and against a strict mock of the Universal
Router's encoding, not on Sepolia. Seeding V4 pools through the Sepolia position manager is a contained follow-up; until
it exists, testnet integration exercises V3 routes only.

| Sepolia contract | Address |
|---|---|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Uniswap QuoterV2 | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| Uniswap V3 factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap NonfungiblePositionManager | `0x1238536071E1c677A632429e3655c799b22cDA52` |
| Chainlink ETH / USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| IndexFactory / IndexRule / IndexToken implementation / IndexZap | not deployed |

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
DEPLOYER=$(cast wallet address --account sepolia-deployer)

# 1. tokens, feeds and priced pools, then liquidity in a later block: 0.3 WETH in the tUSDC pool, 0.1 in each other
MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
MARKET_MODE=seed MARKET_TOKENS=<logged by create> forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 2. the factory takes the router and nothing else from the market: the rule reads no pool
OWNER=<Safe> GUARDIAN=<guardian> UNIVERSAL_ROUTER=0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b \
  forge script script/Deploy.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 3. print the listing proposals and sign them as one batch in the Safe app
LISTING_MODE=safe FACTORY=<factory> WHITELIST=<logged by create> LIST=all forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia

# 4. 2 to 9 days later, from any account
LISTING_MODE=execute FACTORY=<factory> WHITELIST=<same> forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
```

A rehearsal of the old, pool-priced version on an anvil fork of Sepolia used 48.7M gas for `create`, 3.4M for `seed`,
10.2M for the deploy and 0.7M to execute the listings, plus 0.7 ETH of pool liquidity: 0.89 ETH in total at 3 gwei,
1.02 at 5 gwei, 1.33 at 10 gwei. The Safe signer who executes the listing batch pays about 0.6M gas more. Re-measure
before budgeting: the factory no longer validates pools, which makes both `create` and the listings cheaper, and
`create` now also deploys a feed per token.

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts, so testers can call `drip()` from Etherscan.
`USD_POOL_WETH` and `TOKEN_POOL_WETH` (in wei) change the liquidity `seed` adds.

- The test pools are shallow and nobody arbitrages them, while the feeds report mainnet-like prices that do not move
  when the pools do. On the old market a zap mint cost 0.6% over the basket's value at $10, 2% at $50 and 4 to 6% at
  $100, and $1,000 could not be quoted. Expect the index price and the cost of minting it to disagree on this market;
  on mainnet, arbitrage is what keeps them together, and nothing here replaces it.
- A `TestAggregator` answers with the block's own timestamp, so its answers never go stale however long the market
  sits. That is a testnet convenience and hides exactly the failure — a feed that stops publishing — that Known
  limitations calls the main operational risk. Set an age deliberately to rehearse it.
- Timing is mainnet's: listings take 2 days, and an index can start its first rebalance 28 days after creation,
  followed by 2 days of notice and a 24-hour auction. `test/fork/RebalanceExecutorV3.sol` fills auctions through
  SwapRouter02. It is a test fixture without slippage limits: never fund it on mainnet. Only its deployer can call
  `fill`, and only on an index of the factory it was built for.
- Faucet tokens have no value, and their supply grows with every drip, so their listings use fixed reference supplies.

## Layout

```
src/IndexToken.sol            index implementation (ERC20 + in-kind issue, redeem, redeemSkipping, claim, rebalance)
src/IndexRule.sol             supplies, Chainlink USD prices, weights, rebalance targets, index price (view-only)
src/CompositeFeed.sol         immutable adapter multiplying two feeds into one, with a staleness bound per leg
src/IndexFactory.sol          listing delay, token configs, guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              Universal Router mint/burn router, one venue per leg, per-leg limits
src/interfaces/               IIndexToken, IIndexFactory, IIndexRule, IIndexZap, IXindexErrors, IRebalanceExecutor, IAggregatorV3, IUniversalRouter
src/libraries/                PathLib, UniversalRouterCommands and UniswapV4Types (vendored), Methodology
test/*.t.sol                  unit, fuzz, invariant and script tests
test/Security.t.sol           regression tests for the security review findings (some ids are tested elsewhere; see AGENTS.md gate 6)
test/mocks/                   mock tokens, a strict Universal Router, V3 pools for the testnet script, the feed-backed market fixture, with their own tests
test/fork/                    mainnet fork tests: real Chainlink feeds, real V3 and V4 pools, rebalancing and security regressions on real tokens
script/                       Deploy, ConfigureWhitelist, MainnetAddresses, and the interfaces the scripts call
script/testnet/               SetupTestMarket, FaucetToken and TestAggregator for the Sepolia test market
audit/                        the security reviews, their triage, and what the move off Uniswap pricing retired
```

## Not in v3 (candidates for later)

ETH in/out (`mintWithETH` / `burnToETH`), `createAndMint` in one call, `mintWithTokenPermit` for USDC, creator or
protocol fees, constituent changes, mixed-venue legs that split one leg across V3 and V4, per-pair partial-fill
auctions, a backstop executor or trigger reminder, an aggregator or Universal Router 2.1 zap, V4 pools on the Sepolia
market, a second price source behind the Chainlink feeds, synthetic exposure for L1 coins that have no wrapper.
