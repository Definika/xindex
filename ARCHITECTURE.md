# Xindex Architecture

Xindex turns a portfolio of tokens into a single ERC-20 index token. Anyone can create an index and choose each coin's
percentage, anyone can mint it with USDC or USDT, and anyone can burn it back into USDC, USDT or any other token with
Uniswap V3 or V4 liquidity. Every index is fully backed, in kind, by the tokens it holds. Its constituents
and its creator's percentages never change; it rebalances back to them at Pyth prices, through a permissionless
auction, and that settlement is the only place a contract reads a price. No admin can touch user funds, and no protocol
key or bot is involved in rebalancing.

**Xindex is one deployment, on Ethereum, and one index holds up to 100 coins of the top 300** (the owner's decision of
2026-10-10, `design/2026-10-10-one-index-wormhole-legs.md`). An index holds Ethereum ERC-20s in kind: the issuer's own
contract where Ethereum has one, and otherwise the copy Wormhole's token bridge wraps from the chain that has it, priced
at the coin's own Pyth feed. Nothing crosses a chain inside a contract: the app and the fillers bridge. There is no
vault, no proof and no bridge of ours. The BNB Chain deployment of 2026-10-07 was shelved on 2026-10-10 and deleted
on 2026-10-13.

This file describes **v5 as built**: `WeightedIndexFactory`, the `WeightedHub` it clones, `IndexZap` and
`MintRequests`. The v5 spec is `design/2026-10-05-custom-weights.md` (the "spec"). `WeightedHub` keeps the issue,
redeem, claims, recipient checks and backing post-check of v4 Stage A (`design/2026-09-30-v4-stage-a-spec.md`); v4's
market-cap hub and factory, and Stage B's vaults and proofs, are history (section 11). Internal reviews of v5:
`audit/2026-10-05-v5-review.md` and `audit/2026-10-07-v5-logic-review.md`. Nothing has had an external audit, and
nothing is deployed on a mainnet.

## 1. Goals and constraints

| Requirement (from the product brief) | How v5 meets it |
|---|---|
| Create a portfolio as one ERC-20, any name/symbol | `WeightedIndexFactory.createIndex(name, symbol, components)` deploys a `WeightedHub` clone with free-form name and symbol |
| Choose each coin's percentage | Each component carries a weight in basis points, the weights summing to 10,000, fixed at creation with the coin list |
| Others can mint the same index | `issue`, `mintWithToken` and `requestMint` are permissionless |
| Decentralized | No custody, no pause, no upgrade, no rebalancing key; listings take effect after a public 2-day delay with a guardian veto, guardian changes after 7 days |
| Mint and burn | In-kind `issue` / `redeem` on the hub; USDC/USDT through the zap, or at a limit through `MintRequests` |
| Trade the index into other coins | Standard ERC-20 (transferable, listable) plus `burnToToken` into any token |
| USDC/USDT in, USDC/USDT out | The zap mints from either stable; the burner chooses the payout token |
| Rebalancing and index price | The units are brought back to the weights at Pyth prices, at most once a week, through an auction on a multiplier μ (section 3); the index price is the basket's value, computed off chain |
| Layer-1 coins | Ethereum tokens, Bitcoin as WBTC, and the coins Ethereum lacks as Wormhole-wrapped copies priced at the coin's own feed: SOL, XRP, ADA, AVAX and others |

Constraints kept from v3 and v4: in-kind backing, CREATE2 addresses that commit to their contents, fixed constituents,
reentrancy-guarded untrusted executors, standard ERC-20s only, no admin over funds, and an owner Safe of at least three
signatures. Added on 2026-10-14 (`design/2026-10-14-mainnet-engine-research.md`): fees in shares, a rebalance interval
per index and gated indexes, each described below; on 2026-10-16 the streaming fee, as a unit scale. Changed by the owner's calls of 2026-10-05: creators choose
fixed percentages, the market-cap index is retired, and Pyth is the one oracle, read only by the settlement.

## 2. Components

```
               createIndex(name, symbol, components)
   creator ────────────────────────────────► WeightedIndexFactory ──CREATE2 clone──► WeightedHub (ERC-20)
                                              │ listings: token, Pyth id,            │ holds the basket
                                              │ decimals (2-day delay)               │ issue / redeem in kind
                                              │ guardian, registry                   │ redeemSkipping / claim
                                                                                     │
   anyone ── startRebalance(keepMask) ─────────────────────────────────────────────► │ 2 h notice, 24 h auction
   executor ── executeRebalance(data, priceUpdate) ────────────────────────────────► │ prices at priceTime() ─► Pyth
            ◄── amountsOut, then the onXindexRebalance callback ──────────────────── │ fill at μ(t), backing check

   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ──► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── minter (holds or issues shares)
             ◄─ shares, at least minShares ─────  (escrow)    ── the USDC ──►
```

### WeightedHub (`src/WeightedHub.sol`)

The index itself: an EIP-1167 clone of one implementation, which the factory deploys in its constructor, using
OpenZeppelin's upgradeable ERC20 and ERC20Permit (clones skip constructors, so name and symbol are set in
`initialize`). `FACTORY` and `PYTH` are immutables of the implementation, so every clone sees them.

- **State:** `Component[] {address token; uint96 units}` and beside it `Terms[] {bytes32 priceId; uint16 weight;
  uint8 decimals}`, both set at `initialize`. Only `executeRebalance` changes units, and nothing changes the terms.
  `units_i` is the recorded amount of component `i` (in that token's own decimals) per whole index token (`1e18`
  shares); times `_scale / 1e18` it is the raw amount backing one whole index token. `_scale` is the streaming fee's
  factor (1e18 = one, lowered by each accrual and by nothing else; no
  fill resets it, XS-2), beside which `_lastAccrual` is the fee's clock (`lastAccrual()`), restarted by every accrual,
  one that mints nothing included (XS-1), and `_maskedFill`, whether the last fill had a keep mask (XS-3). Open claims live in `claimOf[account][token]`, their sum per token
  in `totalClaims[token]`. A pending
  rebalance is its `eta` and keep mask; beside them `proposalCount`, `rebalanceNonce`, `lastRebalance` (creation, then
  each fill) and `restartAllowedAt`.
- **initialize(name, symbol, components, config):** `FACTORY` only, once. 2 to 100 components, each with a non-zero token,
  non-zero units within `uint96`, a weight from 1 to `TOTAL_WEIGHT`, a non-zero price id and at most 18 decimals; the
  weights sum to `TOTAL_WEIGHT` (10,000), and no two components share a token or a price id (V5-M1). Anything else is
  `InvalidComponents`.
- **issue(shares, to):** computes `ceil(shares × units_i × scale / 1e36)` per component, mints, emits, then pulls each
  component from `msg.sender` and reverts `TransferAmountMismatch` unless the balance grew by at least that amount
  (rejects fee-on-transfer tokens). **redeem(shares, to):** computes `floor(shares × units_i × scale / 1e36)`, burns, emits,
  then pushes every component. Neither reads a price.
- **redeemSkipping(shares, to, skipMask):** the same, except each component whose bit is set stays in the index and is
  booked as a claim for `to`, the account that receives every other component (DA-17), before any token moves.
  **claim(token, to)** pays `msg.sender`'s claim on `token` and clears it.
- **startRebalance(keepMask)**, **cancelRebalance()** and the two **executeRebalance** overloads: section 3.
- **Views:** `components()`, `componentTokens()`, `componentCount()`, `componentTerms()` (weights, price ids and
  decimals), `previewIssue`, `previewRedeem`, `claimOf`, `totalClaims`, `priceTime()`, `pendingRebalance()`,
  `currentMu()`, `canStartRebalance()`, and `previewRebalance(prices)`, which takes one Pyth price per component and
  returns the settlement a fill in this block would use, without checking publish times. No function values the index.
- **Access:** `issue`, `redeem`, `redeemSkipping`, `startRebalance`, `cancelRebalance` and both `executeRebalance`
  overloads revert `NotInitialized` on anything but an initialized clone; the implementation has initializers disabled.
  A recipient can never be zero, the hub itself or its factory, and that includes a plain ERC-20 `transfer` or
  `transferFrom` of shares, since neither could ever move a share on (CR-I01, RT-21). These and `claim` share the
  storage-based `ReentrancyGuard`, whose zeroed slot reads as "not entered" in a clone; the ERC-20 entry points are
  deliberately unguarded.
- **Ether:** only the two `executeRebalance` overloads are payable, and each forwards the whole of `msg.value` to Pyth
  as its update fee, so the hub never holds ether (`test_theFeeGoesToPyth`).

### WeightedIndexFactory (`src/WeightedIndexFactory.sol`)

- The constructor takes the owner, the guardian (zero means none) and Pyth's contract, which must have code, and deploys
  the `WeightedHub` implementation with Pyth fixed in it. The factory stores price ids and never reads a price, and it
  depends on no Uniswap contract.
- **Listing.** `proposeListing(token, priceId)`, owner only: the token must have code (`NotAContract`), its decimals are
  read now and must be at most 18 (`InvalidDecimals`), the price id must be non-zero (`InvalidPriceId`), and the token
  must be neither listed (`AlreadyListed`) nor under a live listing (`ListingPending`). The decimals are read once, so
  every price of the token is scaled by a figure that was public before it counted, and no index ever calls a token to
  price it (RT-01). `executeListing` is permissionless from `eta = now + LISTING_DELAY` (2 days) for `PROPOSAL_WINDOW`
  (7 days); it records the price id and decimals and whitelists the token. `cancelListing` and `delist` are owner or
  guardian; delisting is immediate, keeps the token's terms, and affects only indexes created afterwards. A relisting
  may carry a new price id, which reaches only indexes created after it (`test_aRelistingReachesOnlyNewIndexes`).
- **Creation.** `createIndex(name, symbol, components, params)`, permissionless and payable for the policy's creation
  fee, with `params` the creator's fee rate, the highest platform fee it accepts, the rebalance interval (7 to 91
  days), the gate and the listing flag; each component a
  `ComponentSpec {token, weight, units}`: a non-empty name and symbol, 2 to 100 whitelisted components, units in
  `[MIN_RAW_UNITS, MAX_UNITS]` = `[10,000, (2^96 − 1) >> 10]` (`UnitsOutOfRange`), weights of at least one basis point
  summing to exactly 10,000 (`InvalidWeights`), no token twice (`DuplicateToken`) and no two tokens on one price id
  (`DuplicatePriceId`, V5-M1: Pyth fills only the first of two equal ids, so such an index could never settle). The
  floor is DA-09's granularity rule; the ceiling leaves a 2^10 margin below `uint96` for units to grow (V5-L3). Each
  component copies the price id and decimals in force. The clone is deployed with CREATE2 from a salt over the creator,
  the name, the symbol, every component's token, units, weight, price id and decimals, and the config: fee and
  streaming rates, referral share and rebalance interval (LR-05), registered
  (`isIndex`, `creatorOf`, `allIndexes`), announced (`IndexCreated`) and initialized in one transaction;
  `predictIndexAddress` gives the address first. No unit is checked against a price: the app derives the units from
  the percentages at current prices, and rebalances, the first possible after the index's own interval (7 to 91 days),
  close any gap within the caps.
- **Guardian and ownership.** `proposeGuardian` is owner only (zero removes the role) and replaces any pending change;
  `executeGuardianChange` is permissionless from `GUARDIAN_DELAY` (7 days) for `PROPOSAL_WINDOW`. The owner can cancel
  any guardian change, the guardian only its own removal, never its replacement (XA-61). `isOwnerOrGuardian(account)`
  tells hubs who may cancel a rebalance, pass a keep mask or start before strangers. Ownership moves in OpenZeppelin's
  two steps and takes effect the moment the new owner accepts: the one admin change with no delay and no guardian veto.
  `renounceOwnership` always reverts. An expired proposal leaves `listingEta`, `pendingGuardian` and
  `pendingGuardianEta` set, so `listingPending(token)` and `guardianChangePending()` say whether one can still run
  (DA-16).
- Neither role can pause, upgrade, set units, weights or prices, or touch funds held by any index.

### IndexZap (`src/IndexZap.sol`)

v3's user-facing convenience layer, unchanged by v5. Stateless, ownerless, holds no funds between transactions, and,
with the basket builder, the only contract here that knows about Uniswap: since 2026-10-16 its swaps run through
`UniversalRouterSwaps` (`src/UniversalRouterSwaps.sol`), the abstract engine both inherit, which holds the exact-output
buy, the hop-by-hop V3 and one-swap V4 sales, the route checks and the pre-fund-and-sweep payment, and hands what a hop
did not sell to a hook each contract implements; the swap errors are declared once in `IXindexErrors`. PancakeSwap's legs, added on 2026-10-06, were removed on 2026-10-14,
which returned the zap to its earlier Uniswap-only build. The zap types its calls with `IIndexFactory` and `IIndexHub`, which declare exactly what it calls: `isIndex` on the factory, and
`issue`, `redeem`, the previews, `componentTokens` and `rebalanceNonce` on an index. `IWeightedIndexFactory` and
`IWeightedHub` extend them, so the compiler holds the weighted contracts to that surface.

- `mintWithToken(MintParams{index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to, deadline, referrer})` and
  `burnToToken(BurnParams{index, expectedNonce, shares, tokenOut, minAmountOut, legs, to, deadline})`: route endpoints
  validated, per-leg limits, balance-measured accounting, shortfalls reverted, `issue` as the final interaction of a
  mint. The leg whose component is already the mint's `tokenIn` or the burn's `tokenOut` carries no swap and honours
  its own limit too (DA-15). `burnToTokenWithPermit(BurnParams, v, r, s)` runs the same checks before the permit.
- **One venue per leg.** A `MintLeg` or `BurnLeg` carries exactly one non-empty route, a packed `v3Path` or a
  `PathKey[] v4Path`, or `BadRoute(i)`; both empty is valid only for the pass-through leg. A V4 route must be hookless (`hooks` zero and
  `hookData` empty), which also rules out the dynamic-fee flag. `address(0)` is native ether and may appear only as an
  intermediate; the zap has no `receive()`.
- **Every command is the zap's own.** Each swap is one `execute(commands, inputs)` built here, and nothing a caller
  supplied is forwarded, because the router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`. The commands
  and V4 actions are vendored with their input layouts in `src/libraries/`. The zap never encodes a swap amount of
  zero, which the pinned V4 router reads as "the full debt" (CR-I05).
- **Pre-fund and sweep, not Permit2.** The zap sends the router what a leg may spend and appends `SWEEP` back to itself
  in the same `execute`, so no allowance survives a call. The pre-fund is the operative bound on a leg's spend, because
  the pinned V4 router does not hold an exact-output route that revisits `tokenIn` to its `amountInMaximum` (upstream
  v4-periphery #564; CR-I06, CR-I14). After a mint leg, `ShortFill` checks the component balance gained against what
  the index needs, since the pinned V4 periphery does not check exact-output delivery.
- **Burn legs.** A V3 leg is swapped one hop at a time, each hop's unsold input going to the recipient; a V4 leg is one
  action, where an intermediate partial fill reverts the leg (CR-I07). What a hop returns is measured as what its sweep
  brought back, a stray router balance included, so a stray can never revert a burn (CR-L02).
- `expectedNonce` is the index's `rebalanceNonce` when the legs were quoted, checked on entry and, for a mint, again
  right before `issue`, so a rebalance in between reverts with `StaleRebalanceNonce` instead of buying another basket.
  Recipients: zero, the zap, the index, the router, the PoolManager and the factory are refused (RT-21). The zap
  never calls `redeemSkipping` (the claim would be booked to the zap) or `executeRebalance`.
- **Pinned to Universal Router 2.0.0** (`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`), not the 2.1.x line, whose
  command inputs carry an extra per-hop price array; `POOL_MANAGER` is read from the router's own `poolManager()`.
- **Scale.** The zap costs 265k to 430k gas per component (v3's fork measurement at 20 components, CR-I08), so
  EIP-7825's 2^24-gas cap stops it at 39 to 63 components; the app offers it up to about 35. Larger indexes, and coins
  without a route (most Wormhole copies, Tether Gold, Ondo's stocks), are minted and redeemed in kind, through
  `MintRequests`, or through the basket builder.

### BasketBuilder (`src/BasketBuilder.sol`)

The zap's stateful sibling, built on 2026-10-16 for the basket one transaction cannot swap: the legs are bought over
several calls into an escrow the caller owns here and issued in one, and selling mirrors it. Ownerless, no upgrade,
nothing to configure, and nobody else needed: no filler.

- **State:** `escrowOf[user][token]`, the only storage. A token in it moves on its owner's call alone: into an issue,
  a sale or a withdrawal.
- `deposit(token, amount)` credits the balance increase it caused, so a fee-on-transfer token credits what arrived;
  `withdraw(token, amount, to)` debits first and then transfers, `amount` 0 meaning the whole escrow.
- `buy(BuyParams{index, expectedNonce, shares, tokenIn, maxAmountIn, components, legs, deadline})` pulls the whole
  `maxAmountIn` (refusing a fee-on-transfer currency), buys each named component up to what `previewIssue(shares)`
  needs beyond the escrow through the engine, credits the escrow, keeps the basket's own `tokenIn` out of the refund,
  and refunds the rest. A component the escrow already covers is skipped; a stale quote reverts
  `StaleRebalanceNonce`. About 35 legs fit a call.
- `mint(index, shares, to, referrer, deadline)` debits exactly `previewIssue(shares)` of every component, approves
  the index for that much and no more, and issues; a leg short of it is named by `InsufficientEscrow`, so one more
  buy completes a basket a rebalance changed. A gated index issues only to a `to` its creator allows.
- `redeem(index, shares)` pulls the shares, redeems them here and credits each component's balance increase.
  `sell(SellParams{tokenOut, minAmountOut, tokens, amounts, legs, to, deadline})` debits each named leg, sells it
  through the engine or, when it is `tokenOut`, counts it toward the payout against its leg's minimum (DA-15), credits
  what a hop did not sell back to the escrow (`Unsold`), measures the payout as its `tokenOut` balance change and pays
  `to`, refusing a fee-on-transfer payout.
- **Invariant:** for every token the builder's balance covers the sum of the escrows, since every credit is a
  measured arrival and every debit precedes the transfer it pays for; what strangers send stays, as in `MintRequests`.
  Recipients are checked as the zap's, plus any index (RT-21); every entry point shares one reentrancy guard; it never
  calls `redeemSkipping` or `executeRebalance`. A hundred-leg basket fits three buys and one mint under EIP-7825
  (`test/BasketBuilder.t.sol`, on mock pools).

### MintRequests (`src/MintRequests.sol`)

An ownerless escrow for people who hold a stablecoin and want shares without swapping a basket, or the reverse. A
requester escrows USDC or USDT for at least `minShares` shares of a factory index (`requestMint`), or shares for at
least `minOut` of a stablecoin (`requestRedeem`), fillable until a deadline at most `MAX_REQUEST_DURATION` (30 days)
away. Anyone fills by sending the requester what they asked for, and takes the escrow; the requester cancels at any
time, and anyone refunds the escrow to the requester after the deadline. It is how a hundred-coin index is bought with
USDC: a filler assembles the basket, wrapped legs included, and bridges on its own account. The keeper in `keeper/`
fills requests at their limits (`fillMint`, `fillRedeem`), and anyone else may.

The contract reads no price: the requester's own limit is the valuation, and the app suggests it. Three rules keep the
escrow exact:
- An escrow is the balance increase its request caused, so a USDT fee switched on at any time can never leave the last
  refund short.
- A fill must raise the requester's balance by at least the limit, measured where it lands, so a fee comes out of the
  filler's delivery rather than the requester's limit.
- Each request is closed before any token moves.

Fillers pay requesters directly, the contract never calls `approve`, and every entry point shares one reentrancy
guard. A deposit that could not be paid back out, as from an address Tether has blacklisted, is refused (SA-01).
Nothing is configurable, so tokens sent outside a request stay there. `test/MintRequests.invariant.t.sol` holds the
balance of each token at exactly its open escrows plus donations, under any order of requests, fills, cancels, refunds,
donations and Tether's fee switch.

### PathLib (`src/libraries/PathLib.sol`)

Decodes Uniswap V3 packed paths (`token(20) | fee(3) | token(20) ...`): shape check, first token, last token. V4 routes are typed `PathKey[]` and need no decoding.

## 3. Rebalancing at Pyth prices

An index holds amounts of coins, and a weight is a share of value, so bringing the units back to the weights needs
prices. The hub reads them in one place, the settlement, from a signed Pyth update its executor brings, and only for
the moving components. Issue, redeem, `redeemSkipping` and claims never read one (`test_issueAndRedeemNeverCallPyth`),
so no feed can block an exit or misprice a mint. Notation: `u_i` a component's recorded units, `σ` the index's scale
after the settlement's own accrual (1e18 = one), `w_i` its weight, `p_i` its price
in USD per raw unit scaled by 1e36, `M` the moving components (all but the kept ones), `S = totalSupply()` in the
settling block. `s`, `μ`, `MAX_TURNOVER` and `MIN_TRADE` are fractions held to 18 decimals (`WAD = 1e18`), and `⌊ ⌋`
and `⌈ ⌉` round at that precision.

### 3.1 Start, notice and auction

`startRebalance(keepMask)` is open to anyone once the index's own rebalance interval, 7 to 91 days chosen at creation,
has passed since the last fill or the creation (`RebalanceTooSoon`, `earliestRebalance()`), while no proposal is pending or in its auction (`RebalancePending`). A non-zero keep
mask, and any start before strangers may, needs the factory owner or guardian (`Unauthorized`, R16). The mask must fit
the components and leave at least two moving (`InvalidKeepMask`, V5-L2), since a single moving component is already on
its weight among the moving ones. After a fill with a keep mask, a start without one waits only
`MIN_REBALANCE_INTERVAL`, so a sliver the guardian fills cannot hold everyone else off for a quarter; a start with a
mask may start then too, so the guardian can renew a keep around a frozen component (XS-3). A start reads no price and calls nothing on any component. It stores
`eta = now + REBALANCE_DELAY` and the mask, and emits `RebalanceStarted`.

`REBALANCE_DELAY` is 2 hours. The notice is for executors to prepare, not for holders' exits: targets come from the
prices at the fill, so nothing a holder would leave over is fixed at the start (the spec, section 8). The auction runs
from `eta` to `eta + AUCTION_DURATION` (24 hours).

`cancelRebalance()`, owner or guardian, clears a pending proposal. Cancelling during the notice or the auction holds
strangers off for `REBALANCE_DELAY` from the cancel (`restartAllowedAt`, R15); cancelling one that already expired only
clears it, and the hold-off the expiry granted stands (VR-04). An auction that expires unfilled holds strangers off
until `eta + AUCTION_DURATION + REBALANCE_DELAY`, so the owner and guardian get the first restart (XA-02, XA-16,
CR-I02). `canStartRebalance()` is the whole timing condition for a stranger, false on an uninitialized clone (DA-22).

### 3.2 The price time

The hub, never the executor, fixes the second the prices belong to: `T = priceTime()`, which is
`block.timestamp − PRICE_LAG`, one slot (12 seconds) back. The settlement asks Pyth's `parsePriceFeedUpdatesUnique` for
each moving feed's update published in `[T, T + PRICE_LAG − 1]`, at the latest the second before the block, and Pyth
returns an update only when the one before it was published before `T`. An executor therefore has exactly one price
per component in each block and cannot choose among several; it still chooses whether to fill in a block, seeing that
block's price a slot ahead. The minute first pinned was known up to two minutes ahead (V5-L1). The hub checks the
count, the ids and the publish times Pyth returns rather than trusting them (`PriceMismatch`). That the update was the
first is Pyth's to keep, since Pyth does not return the previous publish time (V5-I1).

### 3.3 Prices

Each moving component's price is used as USD per raw unit, scaled by 1e36, with the decimals the factory recorded at
listing, so no component is called to price it (RT-01):

```
p_i = price · 10^(36 + expo − decimals_i)
```

The hub refuses a price that is not positive, an exponent outside `[MIN_EXPO, 0]` = `[−18, 0]`, or a result above
`MAX_PRICE` (1e45, one raw unit worth a billion dollars), with `PriceOutOfRange`, and a confidence interval wider than
`MAX_CONFIDENCE` (2%) of the price, with `PriceUncertain`. With decimals at most 18 and the exponent in range, the power
of ten lies in [0, 36]. A kept component is neither priced nor read.

### 3.4 Targets, the turnover cap and the minimum trade

```
V    = Σ_M u_i · p_i                                   the moving value
W    = Σ_M w_i                                         the moving weights
t_i  = ⌈V · w_i / (W · p_i)⌉                           each moving component's target units
s    = min(1, min over t_i < u_i of ⌊MAX_TURNOVER · u_i / (u_i − t_i)⌋)        the share of the way every leg moves
```

Every leg moves the same share `s` of the way to its target, chosen so that no shrinking leg gives up more than
`MAX_TURNOVER` (20%) of its own units. The fill reverts `NothingToRebalance` when what the shrinking legs release, after
the cap, is worth less than `MIN_TRADE` (0.1%) of the moving value: when `⌊s · Σ (u_i − t_i) · p_i⌋`, over the
shrinking legs, is below `⌈MIN_TRADE · V⌉`. Each value `u · p` is below `2^96 · MAX_PRICE`, so a hundred of them fit
256 bits.

### 3.5 The auction: μ(t)

```
μ(t) = MU_MAX − ⌊(MU_MAX − MU_MIN) · (t − eta) / AUCTION_DURATION⌋            MU_MAX = 1.02, MU_MIN = 0.98
```

The decrement rounds down, so μ rounds up, towards the holders. `currentMu()` returns it, and 0 outside an auction.

### 3.6 Settlement

At `μ = μ(t)`:

```
growth = ⌈μ · s⌉
shrinking, t_i < u_i:   step = ⌊s · (u_i − t_i)⌋        u'_i = u_i − step    out_i = ⌊S · step · σ / 1e36⌋
growing,   t_i > u_i:   step = ⌈growth · (t_i − u_i)⌉   u'_i = u_i + step    in_i  = ⌈S · step · σ / 1e36⌉
kept, or t_i = u_i:                                     u'_i = u_i
```

Targets round up, so a shrinking leg keeps more and a growing leg asks more. Each leg's amount is its change in
required backing, rounded the holders' way on its own, down when it leaves and up when it comes back, so the amounts
come from supply and units alone and the index never pays out rounding dust or a donation. As a difference of floored
backings, a shrinking leg of a sub-token index could release a whole raw unit while no growing leg asked for any
(SA-07). Units never reach zero: a shrinking leg stops at or above its target, which is at least one. If no `out_i` is
non-zero at `μ(t)`, as on an empty index or one so small that every shrinking leg rounds to zero, the settlement is
taken at `MU_MAX` instead, so nobody is paid for an empty or dust index (R14, XA-27).

In order, `executeRebalance` first accrues the streaming fee, when the index charges one (asking the factory's
`feeTerms` who receives it); checks that an auction is open (`NoPendingRebalance`, `RebalanceNotReady`,
`RebalanceExpired`); reads the moving prices through Pyth at `priceTime()`, forwarding all of `msg.value`, and refuses
one further than `MAX_EMA_DEVIATION` from its moving average (`PriceOffAverage`, RX-27); computes the
settlement at `S` in this block; for the bounded overload, checks `maxAmountsIn`; reads what the index holds of each
component that sends or receives something, and of no other, not even its balance (DA-14); writes the new units, bumps
`rebalanceNonce`, sets `lastRebalance`, clears the proposal and emits `Rebalanced` with μ, the price time, the prices,
the units and the amounts; sends each `out_i` to `msg.sender` and calls
`IRebalanceExecutor.onXindexRebalance(amountsOut, amountsIn, data)` on it, so only a contract can execute; and then
requires, for every component that moved, a balance of at least the larger of `⌊S · u'_i · σ / 1e36⌋ + totalClaims` and
what it held before, less `out_i`, plus the whole of `in_i` (`RebalanceUnderfunded`), and, for every component it
bought, that it can still send that token, a one-unit transfer to itself, measured (`CannotSendOut`, RX-12). Surplus the index already held,
from rounding or a donation, therefore stays with the holders instead of paying for part of the fill (R21, XA-28).

The amounts are recomputed from `totalSupply()` in the settling block, and issue stays open through the auction, so
anyone can enlarge a fill with a dust issue after an executor's simulation. `executeRebalance(data, priceUpdate)`
settles whatever the supply then requires; the callback's arguments are authoritative.
`executeRebalance(data, priceUpdate, maxAmountsIn)` takes one bound per component (`LengthMismatch` otherwise; an empty
array is the unbounded fill) and reverts `RebalanceMovedOn` when the index needs more than the caller will deliver
(DA-13).

### 3.7 What a fill can cost

**At honest prices.** The shrinking legs move `s` of their gap and the growing legs `⌈μ · s⌉` of theirs, so at the
settling prices the executor delivers at least μ times the value it takes
(`testFuzz_R04_theExecutorDeliversMuTimesWhatItTakes`). A lone executor at the auction's end keeps at most `1 − MU_MIN`,
2% of the value it trades, plus the gap between Pyth and the market; starting above 1 hands a lag in the executor's
favour to the holders when executors compete. After a fill below `μ = 1` the growing legs sit slightly under target,
and the next rebalance closes the gap (`test_repeatedFillsFollowThePrices`).

**At wrong prices.** A broken or malicious feed set takes at most a fifth of each component sold, at most once every
`MIN_REBALANCE_INTERVAL`, and the index may receive little for it. A bad price can be used in the auction's first
block, before the guardian can cancel, so the bound is the protection. Holders redeem in kind throughout.

**Why the cap counts units, not value (V5-M2).** The first cap was 20% of the moving value at the settling prices, so
it was measured in the prices it was meant to guard against. On an index far from its weights, two wrong feeds took 89%
of it in one fill: A and B truly $1, weights 1% and 99%, units 99 A and 1 B; A reported at $0.0333 and B at $30 sent
out 89 A for 0.097 B, while the reported value moved stayed under the cap. Counted in units, the same fill sends out at
most a fifth of A (`test_V5M2_wrongPricesTakeAtMostAFifthOfEachLeg`, `testFuzz_V5M2_noPriceTakesMoreThanAFifthOfALeg`).
A value cap must not come back as the only cap.

**Why the minimum is checked after the cap (V5R-1).** The minimum keeps a fill that changes nothing from restarting
the rebalance interval; without it the guardian could keep all but one component and stall rebalancing at no cost
(V5-L2). Checked on the whole release before the cap, it let a capped fill trade a fifth of the minimum, since `s` falls
to about 0.2 when a target is near zero, and still restart the interval. It is checked on `s` times the release
(`test_V5R1_theMinimumTradeIsMeasuredAfterTheCap`).

### 3.8 Keep mask and known limits

A kept component keeps its units, is not priced, takes no part in `V` or `W`, and is neither transferred nor read for
its balance at settlement, so the mask routes around a component that is paused, blacklists the hub, whose feed has
stopped, or whose contract no longer answers at all (`test_R08_DA14_RT01_aKeptComponentIsNeitherPricedNorRead`). The
moving components settle to their own weights among themselves. The limits it answers:
- **A feed that stops, or a confidence interval too wide:** the fill waits until the owner or guardian starts one that
  keeps that component (`testFork_drill_aFeedGoesSilent`). Six of Ondo's stocks (TSM, AVGO, LLY, JPM, WMT and V) have
  only US-hours feeds, so an index holding one settles only while that market is open, or with the stock kept.
- **A collapsing coin:** fixed weights keep buying it. One that falls about a thousand times from units near
  `MAX_UNITS` needs more than `uint96` holds, and the fill stops rather than wraps until the guardian keeps it (V5-L3).

## 4. Accounting

Invariant, for every component, forever:

```
token_i.balanceOf(index) >= floor(totalSupply × units_i × scale / 1e36) + totalClaims[token_i]
```

with `units_i` as recorded and `scale` the streaming fee's factor. Ceil-on-issue and floor-on-redeem mean rounding drift is at most one raw unit per call and leg, and an accrual's
integer scale leaves at most `supply · units / 1e36` raw units more, all in favour of the remaining holders. A claim is recorded only for an amount that stayed in the index, and because `floor(a) + floor(b)
≤ floor(a + b)`, burning shares always frees at least that much required backing, so claims never dilute anyone. A
rebalance moves each leg's change in required backing rounded the holders' way (SA-07), and its post-check is the
invariant with the new units plus the whole of `amountsIn` on top of what the index held. Nothing is computed from
balances, so there is no share price to manipulate and no first-depositor attack; donations only add surplus that no
holder can redeem and no executor can use.

**Fees.** Every conversion of shares into an amount of a component goes through one private helper,
`_backing(shares, units, scale, rounding) = mulDiv(shares, units · scale, 1e36, rounding)`: issue, redeem, the
settlement and its backing check. The fees built on 2026-10-14 are paid in shares. `issue(shares, to, referrer)`
pulls the basket for `gross = ceil(shares · 10,000 / (10,000 − fee))`, mints `shares` to `to` and `gross − shares` to
the recipients; `redeem` burns `shares`, mints `floor(shares · fee / 10,000)` to the recipients and pays the backing of
the rest, rounded down. `fee` is the creator's rate plus the platform's, both in `config()` and fixed at creation. The
recipients come from the factory's `feeTerms(index, to)` at each call: the index's creator, who can hand the role on,
and the platform recipient of the moment; a referrer named at mint takes `referralShareBps` of the platform's part,
rounded down. A recipient that could not hold shares is replaced, so no fee can block a mint or an exit
(`test/WeightedHub.fees.t.sol`). The streaming fee built on 2026-10-16 is the `scale`: a yearly rate, the creator's (0
to 500 bps) plus the platform's (0 to 100 bps), accrues in shares before every issue, redeem and settlement, and on
`accrueFees`, as `supply · f / (1 − f)` shares for `f` the rate times the elapsed part of a year, and the scale every
share's units carry falls by `supply / (supply + minted)`, both rounded down. The previews and `components()` report
at the scale an accrual now would leave (`pendingStreamingFee`). A settlement works on the recorded units and moves
each leg's backing at the scale, and the units it writes carry the scale as the old ones did: no leg is rounded to fold
it in, so a kept leg's units stay exact and nothing is stranded (XS-2; the fold it replaced left up to `supply / 1e18`
raw units of each leg owned by no share at every fill). The scale therefore only shrinks; an accrual that would shrink
it to zero, which only a second lifetime's gap could ask, is not charged. Its integer floor leaves at most `supply ·
units / 1e36` raw units of a leg per accrual, a part in 1e18. Every accrual restarts the clock, so a dust supply cannot
carry idle time over to the next minter (XS-1). The settlement arithmetic itself lives in
`WeightedMath`, a stateless contract the factory deploys with the implementation and the hub reaches by STATICCALL
through its `MATH` immutable, because the scale pushed the hub past EIP-170; the hub still reads every price and every
balance, and the math holds nothing and reads nothing.

## 5. Flows

The README's "How the flows work" walks through each flow for an app. In short:

- **Create.** The creator picks 2 to 100 listed coins and their percentages; the app derives the units at current
  prices and shows the address and the index's wrapped share of value, and the creator creates.
- **Mint and burn** through the zap (up to about 35 components, on coins with a route), through the basket builder
  over several transactions (any size, on coins with a route, the rest deposited in kind), in kind (up to 100), or at
  a limit through `MintRequests`, filled by anyone who holds or can issue the shares.
- **Rebalance.** At most once per the index's interval, 7 to 91 days: anyone starts, 2 hours of notice, then a 24-hour auction in which an
  executor brings a signed Pyth update for `priceTime()`, previews the fill with `previewRebalance`, and settles,
  preferably through the bounded overload. Hermes, Pyth's service for signed updates, needs an API key since
  2026-08-26. The bot in `keeper/` is one such executor and holds no role; anyone may run one.
- **Leaving.** Issue and redeem stay open through notice and auction. Once the auction is live an executor can order
  its fill ahead of a public exit, and shares issued while a rebalance is pending share its haircut (RT-02).
- **Frozen component.** `redeemSkipping` and `claim` for holders, the keep mask for rebalances.
- **Valuation** is off chain: `value per share = Σ units_i × price_i` from the app's own prices.

## 6. Key design decisions and rationale

**In-kind core, swap layer on top.** Splitting custody (the hub) from convenience (the zap) keeps the part that holds
funds small and admin-free, and lets the swap layer be replaced without touching any index.

**One place reads a price, and it is Pyth.** v3 read Chainlink feeds to shape targets and to gate each settlement,
which made a stale feed a halt and could only approximate a bound at market prices (CR-L06). v4 Stage A removed every
price and held a market-cap rule by keeping units proportional to supplies the owner maintained. A creator's
percentage is a share of value, and with targets that move with the market a price-free band would have to be as wide
as the market's moves. v5 reads Pyth in the settlement alone and keeps issue, redeem and claims price-free. In `src/`
and `abi/`, `test_V5I4_onlyTheWeightedHubReadsAPrice` fails if any other file names Pyth's contract, parse, getters,
pushes or price struct (V5-I4), and `test_noContractReadsAPrice` if any file names a Chainlink feed or a pool's price.
Chainlink's Ethereum feeds covered 11 of the 52 coins on the list of 2026-10-05 and Pyth all of them; Chainlink alone,
and as a second check on the coins it covers, were both refused (the spec, sections 1 and 2).

**Fixed weights and constituents.** Nobody, the creator included, changes them; new weights or a new list mean a new
index. An index copies its price ids and decimals at creation, so no relisting or delisting reaches it, and its address
commits to every component's token, units, weight, price id and decimals and to its config, so a front-runner's copy
lands at its own address (LR-05).

**One deployment, the missing coins wrapped.** About 71 of the top-300 candidates exist on Ethereum through their
issuer; held on BNB Chain instead, the same universe would have wrapped 71 legs. Wormhole is the one bridge accepted
for wrapping: anyone attests a coin on its home chain and the bridge deploys the copy on Ethereum. The cost is a new
trusted party over every wrapped leg (section 7). The list (`script/PythIds.sol`) stands at 93, 16 of them Wormhole
copies: SOL, listed first, 12 added on 2026-10-10, and BNB, SUI and SEI, whose copies the count of that day missed,
added on 2026-10-18; a 13th of 2026-10-10, DOGE's, left on 2026-10-14 on the owner's call, since Pyth prices DOGE and
not the copy, and SAND and RLB left on 2026-10-18 after the source reading. Tether Gold and the 17 Ondo stocks do not
count toward the hundred, so 75 coins of the top 300 are listed; 31 more copies await an attestation on Wormhole's Portal (`design/2026-10-10-one-index-wormhole-legs.md`,
section 2a, and `design/2026-10-18-pre-mainnet-readings.md`, section 3).

**Up to 100 components.** Every path of the hub and the factory fits EIP-7825's per-transaction cap of 2^24 gas at
100, measured on mock tokens with every account cold (`test_aHundredComponentsFitOneTransaction`):

| Operation at 100 components | Gas |
|---|---|
| `createIndex` | about 13.1M |
| `issue` | about 3.6M |
| `startRebalance` | about 90k |
| `executeRebalance`, Pyth's parse mocked, an executor that already holds the bought tokens | about 4.8M |
| `redeem` | about 3.7M |
| `redeemSkipping`, every component skipped | about 5.1M |
| `claim` | about 53k |

The fork suite's figure of 14.9M for a fill of 92 real legs (`test/fork/WeightedHub.fork.t.sol`) overstates the fill:
it counts the test executor's own forge-std `deal` calls, which run inside the measured window, in its
`onXindexRebalance` callback. On 2026-10-12, on an anvil fork of Ethereum at block 26,176,814, with Pyth's real contract
verifying an update signed by five keys the test installed as the guardian set of Pyth's receiver, a fill of 93 legs
cost 7,259,578 gas, Pyth's parse 2.34M of it for a 30.9 KB update, under EIP-7825's 16,777,216. On the same fork
`createIndex` of 93 components cost 11.88M, `issue` 4.40M and `redeem` 4.11M. That run's driver was not committed;
`keeper/test/e2e/pnau.mjs` signs updates the same way. What stays open before mainnet is the same settlement on a real
update from Hermes, which needs the API key.

A fill that swaps inside the call costs an estimated 150k a leg on top (v4's hybrid design, section 9.1), so swaps
inside a 100-leg fill do not fit, and a fill that wide needs an executor with inventory. The zap stops near 35
components (section 2).

## 7. Security model

- **Trust.**
  - The factory owner (a Safe), who proposes listings and guardian changes behind public delays and hands over
    ownership in two steps with no delay; the guardian, who can cancel listings and rebalances, delist, start a
    rebalance with a keep mask or before strangers may, and cancel its own removal but not its replacement.
  - Pyth: its publishers' aggregate, the keys that sign its updates, and its DAO, which upgrades Pyth's contract on
    Ethereum in place. Since Pyth's OP-PIP-132 of 2026-08-26, that contract verifies updates against Pyth's own set of
    five signing keys (guardian set 1 of its receiver), not Wormhole's 19 guardians, and three of the five suffice
    (`ReceiverImplementationHalf`), for a price or for a governance message that upgrades the contract. A wrong price,
    from any of them, takes at most `MAX_TURNOVER` of each component sold, once a week (section 3.7).
  - Wormhole's guardians, for the wrapped legs: a quorum (13 of 19) can forge a bridge message, minting unbacked copies
    or upgrading every wrapped token's code at once, with no timelock. Since April 2026, for the chains on delegated
    guardian sets (BNB Chain, Kaia, NEAR, Sui, Arbitrum, Monad), five of seven named guardians suffice to mint, so most
    listed copies rest on five keys (RX-6). The chain a copy comes from is a party too: a copy whose home side closes
    its bridge redeems for nothing (RX-28, RX-32). That party is separate from Pyth's signers, and
    its reach is the whole of every wrapped leg, not a capped haircut, so the app shows every index's wrapped share of
    value. Redeem always pays the copies out; turning them into the coin needs Wormhole live.
  - The whitelisted tokens and their issuers, each labelled in the app: BitGo for WBTC, Tether for Tether Gold, Ondo
    for every stock token, and both Binance and Wormhole for a copy wrapped from a Binance-Peg coin.
  - For the zap only: Uniswap's Universal Router and the V4 PoolManager.

  Executors and the account that starts a rebalance are untrusted. Users trust no one with custody.
- **What can move a basket's shape or value.** Only a fill: units move toward fixed weights at the settling prices, at
  most `MAX_TURNOVER` of each component sold, at most `μ · MAX_GROWTH` of each one bought (RX-15), at a price within
  `MAX_EMA_DEVIATION` of its own moving average (RX-27), and at most once a week. At honest prices a lone executor keeps at most
  `1 − MU_MIN` of the traded value, plus Pyth's gap to the market (section 3.7). Weights, constituents, price ids and
  decimals are fixed at creation. Rounding goes the holders' way everywhere.
- **The guardian's stalls.** `cancelRebalance` has no window and no rate limit, so a hostile or compromised guardian can
  cancel every auction at its last second until the owner replaces it, after `GUARDIAN_DELAY`, which the guardian
  cannot cancel: a trust assumption of the role (DA-12). A keep-mask rebalance that leaves a pair moving can also clear
  `MIN_TRADE` on a sliver of the index, and its fill restarts `MIN_REBALANCE_INTERVAL` for a start without a mask
  rather than the index's interval (XS-3), so the stall can outlast the replacement by up to a week, and by a keep-mask
  auction the outgoing guardian left pending, `REBALANCE_DELAY` + `AUCTION_DURATION` more (RX-44). While a replacement is pending the owner cancels the outgoing guardian's keep-mask
  proposals, within the 2 hours of `REBALANCE_DELAY`, and monitors watch `RebalanceStarted` with a non-zero `keepMask`
  (RT-07). Neither stall moves funds; holders redeem throughout.
- **Reentrancy.** `nonReentrant` on the hub's ten entry points that mint, burn, pay, accrue or rebalance (`test_R11_everyEntryPointIsGuardedDuringTheCallback`),
  on `createIndex`, on the zap's three (CR-I26), on every entry point of `BasketBuilder` and on every entry point of
  `MintRequests`. The new units, the nonce and the cleared proposal are written before any rebalance transfer, and the
  callback goes only to `msg.sender`. Wake's reentrancy detector does not model the guard; its documented suppressions
  are the `redeem` call in `IndexZap._burnBasket`, the `permit` call in `burnToTokenWithPermit`, the `redeem` call in
  `BasketBuilder.redeem`, the clone's `initialize` call in `WeightedIndexFactory._initializeIndex`, and the executor
  callback and Pyth's parse in `WeightedHub` (RX-48). Inside `issue`, `redeem` and `executeRebalance`, supply, units and balances change at different
  moments, so integrators value an index from `components()` and independent prices, never from `balanceOf(index)`
  and `totalSupply()` (VR-05).
- **Clone safety.** The implementation has initializers disabled; `initialize` is `FACTORY`-only and runs in the same
  transaction as the clone; uninitialized instances cannot issue, redeem or rebalance; `isIndex` is the only trusted
  registry, and the zap and `MintRequests` check it.
- **Token behaviour.** `issue` verifies received amounts. A paused or blacklisting component does not freeze the rest of
  a basket: `redeemSkipping`, `claim` and the keep mask route around it. Policy: standard ERC-20s, 6 to 18 decimals, no
  fee-on-transfer, rebasing or callback tokens; stables are mint currencies, not components. The admission check is
  `script/CheckToken.s.sol`, whose default WBT rule refuses a token that can both blacklist a holder and destroy its
  balance; on 2026-10-10 the owner admitted Tether Gold and Ondo's stocks over that rule.
- **Arithmetic.** Units below `2^96` (`SafeCast`), and at most `MAX_UNITS` at creation; prices at most `MAX_PRICE`, so a
  hundred values `u · p` fit 256 bits; every product of shares and units, every target and the cap through 512-bit
  `mulDiv`. Units beyond `uint96` stop a fill rather than wrap (V5-L3).
- **Operations.** `script/DeployWeighted.s.sol` deploys the factory (and through it the hub's implementation), the zap
  and `MintRequests`. `OWNER` and `GUARDIAN` are required and must differ. On chain 1, Pyth, the router and the
  stablecoins come from `script/MainnetAddresses.sol` and nothing else is accepted (`MainnetOverride`). There the owner
  must be a contract that is not an EIP-7702 delegated account, and a Safe must need at least three signatures and have
  no enabled module; neither the guardian nor the broadcasting key may be one of its signers (SA-06). Neither role may
  be the router, the PoolManager, Pyth, or any token or mint currency in the chain's address book (XA-39, CR-I37).
- **Known limitations** are listed in the README, where users read them.

## 8. Verification

- **Unit and fuzz tests per contract:** `test/WeightedHub.t.sol`, `test/WeightedHub.rebalance.t.sol` (exact
  settlements, every price refusal, the pinned slot, the unit cap under wrong prices, keep masks, reentrancy, a hundred
  components), `test/WeightedIndexFactory.t.sol`, `test/IndexZap.t.sol`,
  `test/WeightedZap.t.sol`, `test/MintRequests.t.sol`, `test/Security.t.sol`, the scripts' suites, `test/Repo.t.sol`
  and the mocks' own tests in `test/mocks/Mocks.t.sol`. `MockPyth` fills duplicate ids as Pyth's own loop does (V5-M1);
  `MockWeightedExecutor` fills honestly, short, not at all, or reentrantly.
- **Invariant suites.** `test/WeightedHub.invariant.t.sol` runs random issue, redeem, `redeemSkipping`, claim,
  transfer, donate, price moves, time jumps, starts, cancels, and honest, bounded and short fills. It asserts that every
  component stays backed including open claims, supply and claims add up, the nonce counts fills, a short fill never
  settles, `canStartRebalance` is right, a fill settles exactly its preview, what comes in is worth at least μ times
  what leaves (`muBoundBroken`), no fill sends out more than `MAX_TURNOVER` of a component's units (`turnoverBroken`),
  and the weights never change. `test/MintRequests.invariant.t.sol` is described in section 2.
- **Security regression tests,** named after their ids, as `AGENTS.md` gate 6 requires. v5's own: V5-M1, V5-M2, V5-L1,
  V5-L2, V5-L3, V5-I4 and V5R-1; V5-I1 to V5-I3 and V5R-I2 are recorded by documentation, and V5R-I1 is retired with
  Stage B. The older ids that still bind (R04, R08, R10, R11, R14 to R16, R21, DA-01, DA-13, DA-14, DA-17, DA-22,
  SA-07, CR-I01, RT-01, RT-21 and others) are re-targeted to the weighted suites, as `audit/2026-10-06-v4-retirement.md`
  lists. Six records say which ids lost their test when a mechanism went: `audit/2026-09-22-v3-retirement.md`,
  `audit/2026-09-30-v4-stage-a-retirement.md`, `audit/2026-10-06-v4-retirement.md`,
  `audit/2026-10-07-stage-b-retirement.md`, `audit/2026-10-14-thorchain-retirement.md` and
  `audit/2026-10-14-pancakeswap-retirement.md`. A retired id's test is never restored against the new design.
- **Mainnet fork tests,** five Ethereum suites on real tokens and routers: the zap on V3 and V4 legs
  (`IndexZap.fork`); the address book, the code hashes of the routers, the PoolManager, the V3 factory and Pyth, the
  Wormhole copies against the bridge, and the lists on a fresh factory over Pyth (`MainnetAddresses.fork`); the
  admission check on every listed token (`CheckToken.fork`); the WBTC pause exit, USDT's fee switch, stray router
  balances, `MintRequests` on the real stablecoins and the deploy script against real Safes (`Security.fork`); and v5
  with Pyth's parse mocked: every coin forge-std can fund issued, rebalanced and redeemed in one index, the liquid ones
  through the zap and a Uniswap-routed executor, and four drills, a WBTC pause, a silent feed, a price a hundred times
  low and an auction nobody fills (`WeightedHub.fork`).
- **Gates,** enforced in CI: the submodule check against `foundry.lock`, `forge fmt --check`, `forge build`,
  `forge lint -D notes`, the ABI diff of the five committed ABIs, `forge test` (fork suites required on pushes to
  `main` and on pull requests into it from this repository), the swap rail's and the keeper's tests, 100% coverage on
  every file, and the Wake detectors clean on `src/`. Aderyn reports nothing on `src/` (`aderyn.toml` gives each
  excluded rule its reason); CI does not run it yet.

## 9. Mainnet addresses

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| SOL (Wormhole's copy) | `0xD31a59c85aE9D8edEFeC411D448f90841571b89c` |
| Pyth | `0x4305FB66699C3B2702D4d05CF36551390A4c69C6` |
| Uniswap Universal Router 2.0.0 | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap V3 factory (`CheckToken`'s depth report) | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| Uniswap QuoterV2 (fork tests) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Wormhole token bridge (Portal) | `0x3ee18B2214AFF97000D974cf647E7C347E8fa585` |
| WeightedIndexFactory / WeightedHub implementation / IndexZap / MintRequests | not deployed |

Every listed token, with the source of each Wormhole copy, is in `script/MainnetAddresses.sol`, each price id in
`script/PythIds.sol`. Only the tokens, Pyth and the router are called by anything deployed; the V3 factory and the
quoter serve scripts and tests, and no contract calls the Wormhole bridge.

## 10. Roadmap

**What remains before a mainnet**, in the order of `design/2026-10-10-one-index-wormhole-legs.md`, section 5, as
`design/2026-10-18-pre-mainnet-readings.md`, section 7, updates it: the 31 Wormhole copies still to attest on Portal,
each then through `CheckToken` and onto the lists; the settlement against
Pyth's real contract on a real update from Hermes, which needs the API key; Pyth's parameter replay (the spec, section
8), which sets `MU_MIN`, `MAX_TURNOVER` and `MAX_CONFIDENCE` from evidence; the external audit; the owner Safe (3 of 5)
and the guardian on Ethereum, then `DeployWeighted` and `ConfigureWeighted` over the list; and the app side: Wormhole
Connect for bridging in and out, the wrapped share and the Bridged and Custodial labels on every index, and a filler
for `MintRequests`.

**Backlog.** ETH in/out, `createAndMint`, `mintWithTokenPermit` (USDC only), mixed-venue legs that split one leg
across V3 and V4, per-pair partial-fill auctions, a backstop for auctions too small to pay (the keeper fills only what
pays unless its operator sets a subsidy), an aggregator or Universal Router 2.1 zap, V4 pools on the Sepolia market,
and one L2 deployment if cheap minting for small buyers matters after launch.

## 11. History

- **v1 and v2** (2026-09-15 and 2026-09-16): the in-kind core and the zap, then on-chain rule rebalancing from Uniswap
  V3 pool averages, with the Numbers model's uncapped and capped methodologies.
- **v3** (2026-09-22): prices from Chainlink USD feeds, execution through the Universal Router; the change and what it
  retired are in `audit/2026-09-22-v3-retirement.md`. v3 is tagged `v3.0.0` and runs on Sepolia; it never launches on
  mainnet.
- **v4 Stage A** (2026-09-29 to 2026-09-30): the hybrid multichain design, revised after an external review, and Stage
  A's price-free market-cap index: units proportional to reference supplies the owner revised in weekly batches, settled
  by a price-free auction on a band λ. What that retired is in `audit/2026-09-30-v4-stage-a-retirement.md`.
- **v4 Stage B** (2026-09-30 to 2026-10-06): ownerless vaults on BNB Chain, TRON, NEAR, Stellar, Sui, Injective,
  VeChain, Aptos and Solana, driven by two zkVM proofs of Ethereum's finality, with each chain's state verifier on
  Ethereum and the hybrid index that held their coins. Built in large part, deployed nowhere, tagged
  `stage-b-2026-10-07` and deleted on 2026-10-07 (`audit/2026-10-07-stage-b-retirement.md`).
- **v5** (2026-10-05 to 2026-10-07): creators' fixed percentages, rebalanced at Pyth prices (`WeightedHub`,
  `WeightedIndexFactory`) and reviewed (`audit/2026-10-05-v5-review.md`); the market-cap hub and factory deleted on
  2026-10-06 (`audit/2026-10-06-v4-retirement.md`); PancakeSwap legs in the zap; the logic review and V5R-1's fix on
  2026-10-07; and that day the owner's decision to deploy on Ethereum and BNB Chain, each holding its own chain's
  tokens, with no vaults.
- **One index on Ethereum** (2026-10-10 to 2026-10-13): the owner's decision to ship one deployment, on Ethereum, with
  the coins it lacks as Wormhole copies, shelving BNB Chain (`design/2026-10-10-one-index-wormhole-legs.md`); the list
  grown to 93; the fork run of 92 coins in one index; the end-to-end run against Pyth's real contract (section 6); the
  keeper bot with its executor (`keeper/`); and on 2026-10-13 the deletion of the BNB Chain deployment, the v4 demo,
  the review PoCs and the records of retired designs, all recoverable from git at `f83dcab`. On 2026-10-14 the owner
  removed THORChain and the zap's PancakeSwap legs: users come with USDC or USDT, and the zap swaps through Uniswap alone.
