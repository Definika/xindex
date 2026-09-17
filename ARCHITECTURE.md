# Xindex Architecture

Xindex turns a portfolio of on-chain tokens into a single ERC-20 index token. Anyone can create an index, anyone can
mint it with USDC or USDT, and anyone can burn it back into USDC, USDT, WBTC, or any other token with Uniswap V3
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
| Rebalancing and index price (the Numbers model) | Uncapped or capped (30/20) market-cap weights computed on-chain from supplies and Uniswap V3 time-weighted prices; settlement through an oracle-free auction; the index price is the basket's value |
| Layer-1 coins | Only tokens that exist on mainnet can be components (wrapped BTC, ETH, ...) |

Decisions fixed for v2: Ethereum mainnet, Uniswap V3, fixed constituents with rule-rebalanced units, two methodologies,
no protocol bots or hot keys, no fees, whitelist only.

## 2. Components

```
                  createIndex(name, symbol, tokens[], units[], methodology)
   creator ────────────────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexToken (ERC-20)
                                                                  │ listings + token configs      │ holds the basket
                                                                  │ (2-day delay), guardian,      │ issue / redeem in kind
                                                                  │ registry                      │ redeemSkipping / claim
                                                                  └──deploys──► IndexRule ◄───────│ start / cancel /
   anyone ── startRebalance ────────────────────────────────────────────────── (supplies,       │ executeRebalance
   executor ── executeRebalance ◄── flash-style callback ─────────────────────── V3 TWAPs,       │
                                                                                 weights, price)│
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Uniswap V3                   │
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
  index and is recorded as a claim for `msg.sender`. Claims are booked before any token moves.
- **claim(token, to):** pays `msg.sender`'s claim on `token` and clears it.
- **startRebalance(keepMask):** anyone, once `MIN_REBALANCE_INTERVAL` (28 days) has passed since the last executed
  rebalance or creation and no unexpired rebalance is pending. Asks `IndexRule.targetUnits` for the snapshot, requires
  at least `MIN_TURNOVER` (0.5%), stores the targets and opens `REBALANCE_DELAY` (2 days) of notice. A non-zero
  `keepMask`, and any start during the `REBALANCE_DELAY` cooldown that follows a cancel or an auction that expired
  unfilled, needs the factory owner or guardian. `canStartRebalance()` is that whole condition as one view, for apps
  and for anyone checking whether an index is due.
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
  therefore stays with the holders instead of paying for part of the fill.
- **Views:** `components()`, `componentTokens()`, `componentCount()`, `previewIssue`, `previewRedeem`, `claimOf`,
  `totalClaims`, `previewTarget(keepMask)`, `pendingRebalance()`, `currentMultiplier()`, `previewRebalance()`. The token
  has no price function.
- **Access:** `initialize` is callable only by `FACTORY` and only once; the implementation has initializers disabled.
  `issue`, `redeem`, `redeemSkipping`, `startRebalance`, `cancelRebalance` and `executeRebalance` revert with
  `NotInitialized` on anything but an initialized clone. A recipient can never be the zero address or the index itself.
- **Reentrancy:** storage-based `ReentrancyGuard` on every state-changing entry point. Its namespaced slot reads as "not
  entered" when zero, so it works in a clone without initialization.

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
holder can redeem; a rebalance executor may use it to cover part of a fill.

### IndexRule (`src/IndexRule.sol`)

A stateless, view-only contract the factory deploys in its constructor. It never moves funds.

- **Prices:** WETH wei per 1e18 raw units of a token ("WAD prices"), from the token's Uniswap V3 WETH pool averaged
  over `TWAP_WINDOW` (30 minutes). The mean tick rounds toward negative infinity and is quoted like Uniswap's
  `OracleLibrary.getQuoteAtTick`, with `getSqrtPriceAtTick` vendored from Uniswap v4-core (MIT) in
  `src/libraries/TickMath.sol`. WETH is `1e18`; USDC is read from the USDC/WETH 0.05% pool (`USD_POOL`).
- **Supplies:** a token's reference supply, or its total supply minus the balances of excluded addresses.
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
  their current value at snapshot prices by weight. A snapshot price is the same mean-tick price, accepted only when the
  pool's harmonic-mean liquidity over the window reaches the token's `minLiquidity` (else `ThinPriceHistory`) and the
  mean ticks of the window's three 10-minute parts lie within `MAX_TICK_DEVIATION` (2,000 ticks, about 22%) of each
  other (else `PriceHistoryDeviates`). Kept components are not read at all under the uncapped methodology, whose weights
  renormalise them away; the capped methodology still ranks them, from the plain price; each target is clipped to
  `[units / 2, units * 2]` (and below `MAX_TARGET_UNITS`, so the auction's premium still fits `uint96`); whatever value
  the clips remove or add is shared among components still inside their bounds, pass by pass, until a pass pins no new
  component; a weight that rounds to zero counts as one wei, so no clipped value is left unplaced. Returns the targets
  and the turnover, the sold value as a share of the rebalanced value.
- **checkConfig(token, config):** used by the factory before a listing or config change. WETH needs a reference supply,
  no pool and no minimum liquidity. Any other token needs the Uniswap V3 factory's own pool for the token and WETH at
  the pool's fee tier, at least `MIN_OBSERVATION_CARDINALITY` (200) observation slots (a pool writes at most one
  observation per block, so 200 slots cover 30 minutes while blocks are at least 9.05 seconds apart), a pool that serves
  that average now, a non-zero `minLiquidity` that the pool's current window meets, a non-zero supply, and at most
  `MAX_EXCLUDED` (8) distinct exclusions, none next to a reference supply. The mainnet policy for `minLiquidity` is a
  tenth of the pool's harmonic-mean liquidity when it is proposed.
- **navPerToken(index):** the value of one whole index token, `sum(units_i * price_i)`, in WETH and in USDC. For an
  uncapped index whose units follow the rule this equals the Numbers model's divisor price at every price; for a capped
  index it is the basket's own value, which the divisor formula would misstate. Display only.
- **initialUnits(tokens, methodology, startPriceUsdc):** starting units that follow the rule at a chosen price, like the
  model's 1,000.
- **weights(tokens, methodology), weightsFromCaps(caps, methodology), price(token), supply(token):** the building blocks.

### IndexFactory (`src/IndexFactory.sol`)

- The constructor takes the owner, guardian, WETH, the Uniswap V3 factory and USDC, deploys the rule (which validates the
  USD pool), then deploys the `IndexToken` implementation pointing at the rule.
- `createIndex(name, symbol, tokens, units, methodology)`: permissionless. Validates non-empty name and symbol, `1..20`
  components, matching lengths, every token whitelisted, no duplicates, `0 < units <= 2^96-1`, a known methodology, and
  at least 5 components for the capped methodology. Deploys the clone with CREATE2 from a salt over the creator, name,
  symbol, tokens, units and methodology, registers it (`isIndex`, `creatorOf`, `allIndexes`), emits `IndexCreated`, then
  initializes it, all in one transaction.
- `predictIndexAddress(creator, name, symbol, tokens, units, methodology)`: the address `createIndex` will use.
- Listings and token configs take two steps. `proposeListing(token, config)` (owner only; the token must be a contract
  with no live proposal, and the rule must accept the config) starts `LISTING_DELAY` = 2 days; for a listed token it
  proposes a config change. `proposeConfig(token, config)` does the same for a token that was listed before, listed or
  delisted, but never whitelists it, so a delisted token's config can be refreshed for the indexes still holding it.
  `executeListing(token)` is permissionless from then until `PROPOSAL_WINDOW` = 7 days later; it applies the config and,
  for a `proposeListing` proposal, whitelists the token if needed (`pendingIsListing` tells which). The owner and the
  guardian can `cancelListing` a pending or expired proposal and `delist` a token; delisting is immediate, never affects
  existing indexes, keeps the config those indexes still rebalance with, and cancels a pending `proposeListing`
  proposal, so relisting always takes a fresh proposal and delay.
- Guardian changes take `GUARDIAN_DELAY` = 7 days, as in v1. `isOwnerOrGuardian(account)` tells indexes who may cancel a
  rebalance or pass a keep mask. `renounceOwnership` always reverts.
- Neither role can pause, upgrade, set units or prices, or touch funds held by any index.

### IndexZap (`src/IndexZap.sol`)

The user-facing convenience layer. Stateless, ownerless, holds no funds between transactions.

- `mintWithToken(MintParams{index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to, deadline})` and
  `burnToToken(BurnParams{index, expectedNonce, shares, tokenOut, minAmountOut, legs, to, deadline})` work as in v1:
  path endpoints validated, per-leg limits, balance-measured accounting, shortfalls reverted, `issue` as the final
  interaction of a mint. A burn leg is swapped one hop at a time, so the unsold input of any hop, not only the first,
  goes to the recipient with `ComponentReturned`; unsold `tokenOut` stays in the zap and is paid out with the rest, and
  a hop that sells nothing reverts with `InsufficientOutput` rather than leaving the next hop to spend the zap's
  balance. A leg's `minAmountOut` applies to its last hop's output.
- `expectedNonce` is the index's `rebalanceNonce` when the legs were quoted. A rebalance in between reverts the call with
  `StaleRebalanceNonce` instead of buying or selling a different basket.
- `burnToTokenWithPermit(BurnParams, v, r, s)` runs the same checks before the permit.
- The zap never calls `redeemSkipping` or `executeRebalance`.

### PathLib (`src/libraries/PathLib.sol`)

Decodes Uniswap V3 packed paths (`token(20) | fee(3) | token(20) ...`): shape check, first token, last token.

## 3. Flows

**Create.** The app calls `IndexRule.initialUnits(tokens, methodology, startPrice)` so the index starts on its rule at
the chosen price, shows `predictIndexAddress`, and calls `createIndex`. Creator-chosen units also work; the first
rebalances then move them toward the rule, at most halving or doubling the target each time (a fill at the 1.5 opening
multiplier settles a growing component at up to 2.5 times its units).

**Mint with a stablecoin.** Quote each leg with `QuoterV2.quoteExactOutput`, set per-leg and overall limits, read
`rebalanceNonce()`, and call `mintWithToken`. Exact shares are minted; unspent stable is refunded.

**Burn to any token.** Quote each leg with `quoteExactInput`, set per-leg minimums and a non-zero overall minimum, pass
`rebalanceNonce()`, and call `burnToToken` or `burnToTokenWithPermit`.

**Rebalance.**
1. After 28 days anyone calls `startRebalance(0)`; the app offers a "rebalance due" button. The index snapshots the rule's
   targets. Nothing changes for 2 days, and holders who disagree can leave in kind.
2. The auction runs for 24 hours. An executor contract calls `executeRebalance`, receives the shrinking components,
   swaps them wherever it likes, and must return the growing components before its callback returns. Executors are
   untrusted; the post-check is the only thing that matters.
3. With competition, the fill lands near the fair multiplier, the value of the sold legs over the value of the bought legs
   at execution prices, minus swap costs. Without competition, an executor waits until the multiplier reaches 0.9 and
   keeps at most 10% of the bought value.
4. If nobody fills, the auction expires. For the next two days only the owner and guardian can start a fresh one; after
   that anyone can again. A snapshot whose prices are distorted so that even 0.9 does not pay an executor is never
   filled, and without that wait a griefer could win the start at every expiry and stall an index. The snapshot price
   checks make each attempt expensive, the wait hands the first restart to the owner and guardian, and the cost is that
   an honest restart after an expiry also waits those two days unless one of them starts it.

**Rebalance while a component is frozen.** A paused component that has to move makes the fill revert. The guardian
cancels and starts again with that component's bit in `keepMask`: it keeps its units, the other components share their
own value by the rule's weights, and the fill never touches the frozen token.

**Exit while a component is frozen.** `redeemSkipping` with that component's bit set pays everything else now and records
the frozen amount; `claim` pays it once transfers resume.

**Index price.** `IndexRule.navPerToken(index)` returns the basket's value in WETH and USDC from the same 30-minute
prices: units valued at 30-minute averages. A burn instead sells at spot prices, after rounding down and swap costs,
so its proceeds can differ, especially while prices move fast.

**Direct.** Anyone holding the components can `issue`, and any holder can `redeem`, `redeemSkipping` and `claim`, without
the zap.

**Trade.** An index is a normal ERC-20 and can be transferred or pooled on any DEX. The burn path is the guaranteed exit.

## 4. Key design decisions and rationale

**In-kind core, swap layer on top.** Splitting custody (token) from convenience (zap) keeps the part that holds funds
small and admin-free. The swap layer can be replaced without touching any index.

**The rule runs on-chain; no key rebalances.** Market caps need supplies and prices. Supplies are on-chain (with a
reference supply for wrapped assets, whose on-chain supply is only the wrapped float), and Uniswap V3 keeps
time-weighted prices without any operator. A keeper bot would have made a hot key the thing that shapes every basket;
here the only roles stay the owner Safe and the guardian, and the trigger is permissionless.

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
ordinary drift; simulated at medium volatility, 5% of auctions expire and restart.

**Clip, then redistribute.** Each rebalance targets between half and double a component's units (a fill at the opening
multiplier settles a growing one at up to 2.5 times, with the executor delivering the extra), so a manipulated price,
an inflating supply or a misconfigured token can distort a basket's shape only gradually and publicly. Redistributing
the clipped value pass by pass keeps the rebalance value-neutral; a single pass left up to 28% of value unplaced on
random baskets.

**Fixed constituents.** Changing which tokens an index holds would need a governance decision per index. The token list
is part of the index's address; only weights follow the rule.

**The notice does not freeze issue.** The two days exist for holders to decide, so issue, redeem, the zap and claims keep
working at the old units until the fill.

**The index price is the basket's value.** The Numbers model prices an index as total market cap over a divisor. That
number equals the basket's value only for the uncapped rule; for the capped rule it prices the uncapped market, and a
buyer paying it after the top coin doubles would pay 27% more than a burn returns.

**Uniswap V3 rather than V4.** Unchanged from v1: SwapRouter02's `exactOutput(path)` and on-chain path validation, the
reference liquidity for these pairs, and V3's built-in oracle, which V4 pools do not provide by default.

**Burner chooses the exit token; whitelist only; no fees; skip-and-claim; public delays; balance-measured zap.**
Unchanged from v1 and described above (see the zap in section 2 and section 5). Fees are still not in v2.

**Creator-bound CREATE2 addresses.** The address commits to the creator, the constituents, the starting units and the
methodology, so it can never hold a different token list or follow a different rule, and a front-runner's copy lands at
its own address.

## 5. Security model

- **Trust:** the factory owner (Safe), who proposes listings, token configs and guardian changes behind public delays;
  the guardian, who can cancel listings and rebalances, delist, start a rebalance with a keep mask or before strangers
  may, and cancel a change that would leave the factory with no guardian, but whom the owner can *replace* after
  `GUARDIAN_DELAY` without the guardian being able to block it (an owner that wants an unchecked config change installs
  a guardian it controls, so a `GuardianProposed` event is the earliest warning, 9 days ahead); the whitelisted
  tokens and their issuers; Uniswap V3, including the time-weighted prices of listed pools. Executors and the account
  that starts a rebalance are untrusted. Users trust no one with custody.
- **Shape versus value.** Issue, redeem and claims never read a price. What can distort a basket's shape, with targets
  always within half to double per component per rebalance and settled units within half to 2.5 times: an issuer minting
  supply (policy: fixed-supply or governance-minted tokens); the owner changing a pool, a minimum liquidity, exclusions
  or a reference supply, behind the 2-day delay and the guardian's cancel; the caller choosing the snapshot moment. A
  distorted snapshot price can also move value: read low by a factor f on a sold component, it sets the auction's fair
  multiplier to about 1/f, and below f = 2/3 the first executor takes value (the 2026-09-16 audit measured 2.48% of an
  off-target uncapped index from one 12-second block at an extreme tick in an empty range). Rebalance snapshots
  therefore reject windows whose harmonic-mean liquidity fell below the token's minimum or whose 10-minute parts
  disagree by more than 2,000 ticks. What remains is manipulation sustained over the whole window through deep
  liquidity, for example by a validator holding many consecutive slots; the guardian's duty is to compare
  `pendingRebalance()` targets with targets from independent prices during every notice period and cancel a distorted
  snapshot. The owner and guardian can stall rebalancing or keep chosen components unchanged.
- **Level:** set by the auction. A price error of δ on a traded component moves the fair multiplier by about δ. A lone
  executor on an honest snapshot keeps at most `(1 - 0.9)` of the bought value. A windfall needs the fair multiplier
  above 1.5. When the settlement moves no raw unit at all the multiplier is parity, so an empty index follows the rule
  exactly; when it moves a few wei, the auction still decays and a lone executor picks the level of a near-empty index
  for free, within the half-to-2.5-times bound and without moving any holder's value.
- **Reentrancy:** `nonReentrant` on `issue`, `redeem`, `redeemSkipping`, `claim`, `startRebalance`, `cancelRebalance`,
  `executeRebalance`, `createIndex`, `mintWithToken`, `burnToToken` and `burnToTokenWithPermit`. Checks-effects-
  interactions throughout; the new units, nonce and cleared proposal are written before any rebalance transfer. The
  executor callback cannot reach any guarded function; index-token transfers stay allowed and are harmless. Only a
  contract can execute, and the callback always goes to `msg.sender`.
- **Read-only reentrancy:** inside `issue`, `redeem` and `executeRebalance`, supply, units and balances change at
  different moments. Xindex's own views never read balances. Integrators must value an index from `components()` and
  independent prices, never from `balanceOf(index)` and `totalSupply()`.
- **Price readings:** `navPerToken` lags fast moves by design and can be nudged by multi-block manipulation. Nothing in
  Xindex reads it; lending protocols must not use it as a collateral oracle.
- **Clone safety:** the implementation has initializers disabled; `initialize` is `onlyFactory` and runs in the same
  transaction as the clone; uninitialized instances cannot issue, redeem or rebalance; `isIndex` is the only trusted
  registry, and the zap and `navPerToken` check it.
- **Token behaviour:** `issue` verifies received amounts. A paused or blacklisting component does not freeze the rest of
  a basket: `redeemSkipping` exits everything else, `claim` collects the frozen part later, and a keep mask rebalances
  around it. Policy: standard ERC-20s, 6-18 decimals, no fee-on-transfer, rebasing or callback tokens, fixed-supply or
  governance-minted supply, a WETH pool with at least 200 observation slots; stables are mint currencies, not components;
  pausable components are labelled in the app. Two wrappers of one asset are valued by their own configs: WBTC with
  bitcoin's whole supply, tBTC with its on-chain float, so an index holding both weighs them by wrapper, not by bitcoin;
  list a second wrapper with a reference supply that states which share of the asset it should represent.
- **Zap:** stateless and ownerless; every path's endpoints are checked, legs sell nothing into a third token, per-leg
  and overall limits apply, payments and payouts are measured as balance changes inside the call (tokens already in
  the zap are never used), fee-charging currencies revert with `TransferShortfall`, a burn leg is swapped hop by hop so
  every hop's unsold input goes to the recipient (unsold `tokenOut` is paid out instead), the zap, the index and the router are rejected as recipients, the permit is tried and a
  front-run permit is accepted, and `expectedNonce` is checked on entry and again right before `issue`. It never calls
  `redeemSkipping` or `executeRebalance`.
- **Operations:** `OWNER` and `GUARDIAN` are required at deploy; on mainnet the owner must be a contract that is not an
  EIP-7702 delegated account, and a Safe must need at least two signatures and have no enabled module (a module acts as
  the Safe without signatures; the owner must keep none afterwards). Reference supplies drift and need periodic
  config changes, and so do minimum liquidities when a pool's liquidity moves for good: a minimum above the pool's
  liquidity makes every snapshot of that component revert until the config changes. A pool with fewer than 200
  observation slots, such as tBTC/WETH 0.3% on 2026-09-16, must be grown with `increaseObservationCardinalityNext` and
  trade until the ring grows before its token can be listed. If block times ever fall below 9.05 seconds, a busy pool's
  200 slots no longer cover 30 minutes and `startRebalance` and `navPerToken` revert with `OLD` until someone grows the
  ring; issue and redeem are unaffected.
- **Gas:** `MAX_COMPONENTS = 20`; the UI should suggest about 10. `startRebalance` reads a pool, a supply and a config
  per component; `executeRebalance` costs little beyond the executor's own swaps.
- **Overflow:** `units <= 2^96-1`, targets below `MAX_TARGET_UNITS`, 512-bit `mulDiv`. A WAD price reaches about 3.4e56
  at `MAX_TICK`, so the rule keeps its products inside 256 bits: market caps are `supply * price / 1e18` floored at one
  wei (only ratios matter), and values are `units * price`, exact while every price is at most `MAX_EXACT_PRICE` (1e46,
  where 20 holdings of 2^96 units still fit) and divided by `1e18` above it. Ordinary baskets are unaffected to the wei,
  and a mean tick manipulated toward `MAX_TICK` yields a snapshot the guardian can cancel rather than a panic.
- **Known limitations:** airdrops, rewards and votes that accrue to index-held tokens are unrecoverable. Rebalances
  clear only when the bought value covers gas and swap costs many times over, so small indexes on mainnet rarely
  rebalance. A permanently frozen component needs the guardian's keep mask at every rebalance. Under the capped
  methodology a kept component is still ranked, so a component whose pool cannot be read blocks rebalancing until its
  config changes. The factory's deployment bytecode is close to the EIP-3860 initcode limit. Bytecode targets Cancun.

## 6. Verification

- Unit and fuzz tests per contract: `IndexToken.t.sol`, `IndexToken.rebalance.t.sol`, `IndexRule.t.sol` (including the
  Numbers model's weight vector and its divisor prices), `TickMath.t.sol` (exact values), `IndexFactory.t.sol`,
  `IndexZap.t.sol`, with 6/8/13/18-decimal mocks, mock Uniswap V3 pools and factory, and mock executors that fill
  honestly, short, not at all, or reentrantly.
- Invariant test: random issue, redeem, redeemSkipping, claim, transfer, donate, price moves, supply changes, rebalance
  starts, cancels, honest fills, short fills and staged time jumps; asserts every component stays backed including open
  claims, supply equals the sum of holder balances, claims add up, the nonce counts executed rebalances, short fills never
  settle, units move between half and 2.5 times per rebalance, and targets exist exactly while a rebalance is pending.
- Security regression tests, named after their ids: one per testable finding of the 2026-09-15 security review, the
  2026-09-16 rebalancing design review (R01–R23) and the 2026-09-16 whole-repo audit (XA ids), plus controls. The v1 and
  R tests are in `test/Security.t.sol` and its fork counterpart, except L06 and FR05–FR06 (script tests) and I09–I11,
  L08 and FR04 (`test/Repo.t.sol`); an XA test sits in the suite of what it checks. AGENTS.md gate 6 maps each one.
- Mainnet fork tests: v1's zap and security cases on the v2 contracts; the rule's prices against QuoterV2; uncapped and
  capped indexes rebalancing through real Uniswap V3 swaps with a fork executor; a guardian keep mask around a real WBTC
  pause; tBTC's short-history pool rejected until its observation ring is grown.
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
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| AAVE | `0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9` |
| tBTC v2 | `0x18084fbA666a33d37592fA2633fD49a74DD93a88` |
| Uniswap SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Uniswap QuoterV2 | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Uniswap V3 factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| USDC/WETH 0.05% pool (USD prices) | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |
| WBTC/WETH 0.05% pool | `0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0` |
| LINK/WETH 0.3% pool | `0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8` |
| UNI/WETH 0.3% pool | `0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801` |
| AAVE/WETH 0.3% pool | `0x5aB53EE1d50eeF2C1DD3d5402789cd27bB52c1bB` |
| tBTC/WETH 0.3% pool | `0x97944213D2caeeA773DA1c9B11B0525F25b749CC` |
| IndexFactory / IndexRule / IndexZap | not deployed yet |

## 8. Roadmap candidates

ETH in/out, `createAndMint`, `mintWithTokenPermit` (USDC only), creator/protocol fees attributed by `creatorOf` with
timelocked governance, a Chainlink price adapter for tokens with thin pools, per-pair partial-fill auctions for very
large baskets, a permissionless backstop executor and a reminder for the monthly trigger, Universal Router / V4 /
aggregator zap, synthetic exposure for L1 coins.
