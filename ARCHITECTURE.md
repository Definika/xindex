# Xindex Architecture

Xindex turns a portfolio of tokens into a single ERC-20 index token. Anyone can create an index, anyone can mint it with
USDC or USDT, and anyone can burn it back into USDC, USDT, WBTC or any other token with Uniswap V3 or V4 liquidity.
Every index is fully backed, in kind, by the tokens it represents. Its constituents never change; its units follow the
uncapped market-cap rule `units ∝ supply`, from reference supplies the owner updates weekly behind a public delay. **No
contract reads a price**: a rebalance settles through an auction on a single number, λ, whose worst case holds at any
prices. No admin can touch user funds, and no protocol key or bot is involved in rebalancing.

This file describes **v4 Stage A as built**: the price-free part of the v4 design held on Ethereum. The multichain
design is `design/2026-09-29-v4-hybrid-architecture.md` (the "design" below), and the contract spec for this stage is
`design/2026-09-30-v4-stage-a-spec.md` (the "spec"). Stage A has had an internal red team
(`audit/2026-09-30-stage-a-red-team.md`) but no external audit, and is deployed nowhere; section 10 lists what remains.

## 1. Goals and constraints

| Requirement (from the product brief) | How Stage A meets it |
|---|---|
| Create a portfolio as one ERC-20, any name/symbol | `IndexFactory.createIndex` deploys an `IndexHub` clone with free-form name and symbol |
| Others can mint the same index | `issue` and `mintWithToken` are permissionless |
| Decentralized | No custody, no pause, no upgrade, no rebalancing key; listings and supply updates take effect after a public 2-day delay with a guardian veto |
| Mint and burn | In-kind `issue` / `redeem` on the hub; USDC/USDT convenience through the zap |
| Trade the index into other coins | Standard ERC-20 (transferable, listable) plus `burnToToken` into any token |
| USDC/USDT in, USDC/USDT out | The zap mints from either stable; the burner chooses the payout token |
| Rebalancing and index price (the Numbers model) | The uncapped market-cap rule, held exactly by keeping units proportional to reference supplies; a rebalance only when a supply changes, settled by the λ auction; the index price is the basket's value, computed off chain (design section 10) |
| Layer-1 coins | Stage A: Ethereum tokens, Bitcoin as WBTC. Native coins of proof-capable chains come in vaults from Stage B (section 10) |

Constraints carried from v3: in-kind backing, CREATE2 addresses that commit to their contents, fixed constituents,
reentrancy-guarded untrusted executors, standard ERC-20s only, no admin over funds. Changed by the owner's decisions of
2026-09-29 and 2026-09-30 (design section 13): no prices in money paths, uncapped only, weekly supply updates with a
0.5% step, up to 100 components, v4 replaces v3; then no fee in Stage A, WBT off after its listing check, the floor
buffer, and an owner Safe of at least three signatures (design section 13.1, `design/2026-09-30-wbt-check.md`).

## 2. Components

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

### IndexHub (`src/IndexHub.sol`)

The index itself, renamed from v3's `IndexToken` because Stage B extends it into the hub of a multichain index. An
EIP-1167 clone of one implementation, using OpenZeppelin's upgradeable ERC20 and ERC20Permit (clones skip
constructors, so name and symbol are set in `initialize`).

- **State:** `Component[] {address token; uint96 units}`, fixed at `initialize`; only `executeRebalance` changes units.
  `units_i` is the raw amount of component `i` (in that token's own decimals) backing one whole index token (`1e18`
  shares). Open claims live in `claimOf[account][token]`, their sum per token in `totalClaims[token]`. A pending
  rebalance is `{uint40 eta; uint64 lambdaMax; uint64 lambdaMin}`, the keep mask (`uint256`) and one `uint64` ratio per
  component; beside them `proposalCount`, `rebalanceNonce`, `lastRebalance` and `restartAllowedAt`. `FACTORY` is an
  immutable of the implementation, set in its constructor, so every clone sees it.
- **issue(shares, to):** computes `ceil(shares × units_i / 1e18)` per component, mints, emits, then pulls each
  component from `msg.sender` and reverts `TransferAmountMismatch` unless the balance grew by at least that amount
  (rejects fee-on-transfer tokens).
- **redeem(shares, to):** computes `floor(shares × units_i / 1e18)`, burns, emits, then pushes every component.
- **redeemSkipping(shares, to, skipMask):** the same, except each component whose bit is set stays in the index and is
  booked as a claim for `to`, the account that receives every other component (DA-17). Claims are booked before any
  token moves.
- **claim(token, to):** pays `msg.sender`'s claim on `token` and clears it.
- **startRebalance(keepMask):** anyone, once `MIN_REBALANCE_INTERVAL` (7 days) has passed since the last settlement or
  creation and no auction is live. A non-zero `keepMask`, and any start during the `REBALANCE_DELAY` hold-off after a
  cancel or an unfilled auction, needs the factory owner or guardian (CR-I02, VR-04). The mask must fit the components
  and may not keep all of them (`InvalidKeepMask`). Computes the band (section 3), refuses one narrower than `MIN_BAND`
  (`BandTooNarrow`), stores it and opens `REBALANCE_DELAY` (2 days) of notice. `canStartRebalance()` is the whole
  timing condition as one view, and answers false on an uninitialized clone (DA-22); `previewBand(keepMask)` is the
  band a start would take, returned rather than refused when narrow.
- **cancelRebalance():** factory owner or guardian. Clears the proposal. Cancelling a live auction holds strangers off
  for `REBALANCE_DELAY` from the cancel; cancelling one that already expired only clears the stale proposal, and the
  hold-off the expiry granted stands (VR-04).
- **executeRebalance(data)** and **executeRebalance(data, maxAmountsIn):** during the `AUCTION_DURATION` (24 hours)
  after the notice; the settlement of section 3.3. The bounded overload reverts `RebalanceMovedOn` when the index needs
  more of a component than the caller will deliver, because the amounts are recomputed from `totalSupply()` in the
  settling block and issue stays open, so anyone can enlarge a fill with a dust issue between an executor's simulation
  and its transaction (DA-13).
- **Views:** `components()`, `componentTokens()`, `componentCount()`, `previewIssue`, `previewRedeem`, `claimOf`,
  `totalClaims`, `previewBand(keepMask)`, `pendingRebalance()`, `currentLambda()`, `canStartRebalance()`,
  `previewRebalance()`. There is no price function.
- **Access:** `initialize` is callable only by `FACTORY` and only once; the implementation has initializers disabled.
  `issue`, `redeem`, `redeemSkipping`, `startRebalance`, `cancelRebalance` and both `executeRebalance` overloads revert
  `NotInitialized` on anything but an initialized clone. A recipient can never be zero, the hub itself or its factory,
  and that includes a plain ERC-20 `transfer` or `transferFrom` of shares, since neither could ever move a share on
  (CR-I01, RT-21).
- **Reentrancy:** the storage-based `ReentrancyGuard` on every function that mints, burns, pays a claim or changes a
  rebalance: `issue`, `redeem`, `redeemSkipping`, `claim`, `startRebalance`, `cancelRebalance` and both
  `executeRebalance` overloads. Its namespaced slot reads as "not entered" when zero, so it works in a clone without
  initialization. The ERC-20 entry points are deliberately unguarded.

### IndexFactory (`src/IndexFactory.sol`)

- The constructor takes the owner and the guardian and deploys the `IndexHub` implementation. It takes no market
  address: the factory and the hub depend on no Uniswap contract and no price source.
- **Reference supplies.** `referenceSupply(token)` is the supply in force, in the token's raw units: the supply of what
  the token represents (bitcoin's for WBTC, ether's for WETH), from 1 to `MAX_SUPPLY` (`uint128.max`). Zero means never
  listed. It stays after delisting, because existing indexes still rebalance with it. `referenceSupplies(tokens)` reads
  several at once from storage; no call reaches a token, so no transaction can move a supply the hub reads (CR-M01).
- **Listing.** `proposeListing(token, supply)`, owner only: the token must have code (`NotAContract`), must not be
  listed (`AlreadyListed`), must have no live listing (`ListingPending`) and must not be in the live supply batch
  (`TokenInBatch`). A token that carried a supply before, as a delisted one does, is relisted only at that supply
  (`RelistChangesSupply`); a first listing is bounded only by `MAX_SUPPLY`. Relistings execute one token at a time, so
  one that moved a supply would let a stranger split a uniform revision into halves that each open a band; a batch,
  which delisted tokens join like any other, is the only way to revise a supply (SA-02, extending DA-18 and CR-L03). `executeListing` is permissionless from `eta =
  now + LISTING_DELAY` (2 days) for `PROPOSAL_WINDOW` (7 days); it sets the supply and whitelists the token.
  `cancelListing` and `delist` are owner or guardian; delisting is immediate and affects only indexes created
  afterwards.
- **Supply batches.** `proposeSupplies(tokens, supplies)`, owner only: 1 to `MAX_BATCH` (200) tokens in strictly
  ascending address order (`InvalidBatch`), each already carrying a supply (`NotConfigured`) and none with a live
  listing, each new supply from 1 to `MAX_SUPPLY` and within `MAX_SUPPLY_STEP` (0.5%) of the one in force:
  `|new − old| ≤ ⌊old × MAX_SUPPLY_STEP / 1e18⌋` (`SupplyStepTooLarge`). One batch is live at a time
  (`SuppliesPending`; an expired one is replaced). `executeSupplies` is permissionless from `eta` for `PROPOSAL_WINDOW`
  and puts every supply in force at once; `cancelSupplies` is owner or guardian. The batch is atomic because a stranger
  who could execute half of it and start a rebalance on the half would turn a uniform revision, which trades nothing,
  into a trade. While a batch is live, nothing else can change the supplies it was checked against: a listing is
  refused for a token in it, and it was refused for a token with a live listing.
- **Creation.** `createIndex(name, symbol, tokens, k)`, permissionless: non-empty name and symbol, 1 to
  `MAX_COMPONENTS` (100) whitelisted tokens with no duplicates, and `units_i = ⌊k × referenceSupply_i / K_SCALE⌋` with
  `K_SCALE = 1e36`, each in `[MIN_RAW_UNITS, MAX_UNITS]` = `[10,000, (2^96 − 1) >> 10]` (`UnitsOutOfRange`). The floor
  is DA-09's granularity rule: a coarser component would make one raw unit a large share of it. The ceiling leaves a
  2^10 margin below `uint96` for units to grow through about 690 full-band rebalances. The clone is deployed with
  CREATE2 from a salt over the creator, the name, the symbol, the tokens and the **computed units**, registered
  (`isIndex`, `creatorOf`, `allIndexes`), announced (`IndexCreated`) and initialized in one transaction. A batch
  executed between a preview and the creation changes the units and so the address, never the basket at an address.
  `previewUnits(tokens, k)` and `predictIndexAddress(creator, name, symbol, tokens, k)` read the supplies in force.
- **Guardian and ownership.** Guardian changes take `GUARDIAN_DELAY` (7 days) and expire after `PROPOSAL_WINDOW`; the
  guardian can cancel a change that would remove the role, not one that replaces it. `isOwnerOrGuardian(account)` tells
  hubs who may cancel or pass a keep mask. Ownership moves in OpenZeppelin's two steps and takes effect the moment the
  new owner accepts: the one admin change with no delay and no guardian veto. `renounceOwnership` always reverts. An
  expired proposal leaves `listingEta`, the batch's eta, `pendingGuardian` and `pendingGuardianEta` set, so
  `listingPending(token)`, `suppliesPending()` and `guardianChangePending()` are the views that say whether one can
  still run (DA-16).
- Neither role can pause, upgrade, set units, or touch funds held by any index.

### IndexZap (`src/IndexZap.sol`)

v3's user-facing convenience layer, unchanged but for its recipient check, which no longer names a rule. Stateless,
ownerless, holds no funds between transactions, and the only contract here that knows about Uniswap.

- `mintWithToken(MintParams{index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to, deadline})` and
  `burnToToken(BurnParams{index, expectedNonce, shares, tokenOut, minAmountOut, legs, to, deadline})`: route endpoints
  validated, per-leg limits, balance-measured accounting, shortfalls reverted, `issue` as the final interaction of a
  mint. The leg whose component is already the mint's `tokenIn` or the burn's `tokenOut` carries no swap and honours
  its own limit too (DA-15). `burnToTokenWithPermit(BurnParams, v, r, s)` runs the same checks before the permit.
- **One venue per leg.** A `MintLeg` or `BurnLeg` carries exactly one non-empty route, a packed `v3Path` or a
  `PathKey[] v4Path`, or `BadRoute(i)`; both empty is valid only for the pass-through leg. A V4 route must be hookless
  (`hooks` zero and `hookData` empty), which also rules out the dynamic-fee flag. `address(0)` is native ether and may
  appear only as an intermediate; the zap has no `receive()`.
- **Every command is the zap's own.** Each swap is one `ROUTER.execute(commands, inputs)` built here, and nothing a
  caller supplied is forwarded, because the router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`, which
  move a payer's funds. The commands and V4 actions are vendored, with their input layouts, in
  `src/libraries/UniversalRouterCommands.sol` and `src/libraries/UniswapV4Types.sol` from the commits the pinned router
  was built from. A mint leg is `V3_SWAP_EXACT_OUT, SWEEP` or `V4_SWAP, SWEEP`; a V3 burn hop `V3_SWAP_EXACT_IN,
  SWEEP`; a V4 burn leg `V4_SWAP, SWEEP`. The zap never encodes a swap amount of zero, which the pinned V4 router reads
  as "the full debt": a burn leg that redeems nothing is skipped, and every component's units stay at least one, so a
  mint leg always needs at least one raw unit (CR-I05).
- **Pre-fund and sweep, not Permit2.** The zap sends the router what a leg may spend and appends `SWEEP` back to itself
  in the same `execute`, so the router is never left holding anything and no allowance survives a call. The pre-fund
  is the operative bound on a leg's spend, because the pinned V4 router does not hold an exact-output route that
  revisits `tokenIn` to its `amountInMaximum` (upstream v4-periphery #564; CR-I06, CR-I14).
- **`ShortFill` is load-bearing.** After a mint leg the zap checks the component balance it gained against what the
  index needs, because the pinned V4 periphery does not itself check exact-output delivery.
- **Burn legs differ by venue.** A V3 leg is swapped one hop at a time, so every hop's unsold input goes to the
  recipient with `ComponentReturned`, and a hop that sells nothing reverts. A V4 leg is one action, where an
  intermediate partial fill leaves an unsettled delta and the leg reverts atomically, so as a rule only its first hop
  can leave unsold input; a route that comes back to the component can leave some from a later hop too (CR-I07). What
  a hop returns is measured as what its sweep brought back, a stray router balance included, so a stray can never
  revert a burn (CR-L02).
- `expectedNonce` is the index's `rebalanceNonce` when the legs were quoted, checked on entry and again right before
  `issue`, so a rebalance in between reverts the call with `StaleRebalanceNonce` instead of buying a different basket.
- Recipients: zero, the zap, the index, the Universal Router, the PoolManager and the factory are refused (RT-21).
- The zap never calls `redeemSkipping` (the claim would be booked to the zap) or `executeRebalance`.
- **Swap failures arrive unwrapped.** The Universal Router wraps a command in `ExecutionFailed` only when it dispatched
  it with a low-level call, and swaps are internal calls, so the caller sees the pool's own revert, verified against
  the pinned deployment on a fork.
- **Pinned to Universal Router 2.0.0** (`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`), not the 2.1.x line, whose
  command inputs carry an extra per-hop price array. The zap reads `POOL_MANAGER` from the router's own
  `poolManager()`, so the two can never be wired to different deployments.
- **Scale.** The zap costs 265k to 430k gas per component (v3's fork measurement at 20 components, CR-I08), so
  EIP-7825's 2^24-gas transaction cap stops it at 39 to 63 components; the app offers it up to about 35. Larger
  indexes are minted and redeemed in kind.

### MintRequests (`src/MintRequests.sol`)

An ownerless escrow for people who hold a stablecoin and want shares without swapping a basket, or the reverse. A
requester escrows USDC or USDT for at least `minShares` shares of a factory index (`requestMint`), or shares for at
least `minOut` of a stablecoin (`requestRedeem`), fillable until a deadline at most `MAX_REQUEST_DURATION` (30 days)
away. Anyone fills by sending the requester what they asked for, and takes the escrow; the requester cancels at any
time, and anyone refunds the escrow to the requester after the deadline.

The contract reads no price: the requester's own limit is the valuation, and the app suggests it. Three rules keep the
escrow exact:
- An escrow is the balance increase its request caused, so a USDT fee switched on at any time can never leave the last
  refund short.
- A fill must raise the requester's balance by at least the limit, measured where it lands, so a fee comes out of the
  filler's delivery rather than the requester's limit.
- Each request is closed before any token moves.

Fillers pay requesters directly, the contract never calls `approve`, and every entry point shares one reentrancy
guard. It has no owner and nothing to configure, so tokens sent to it outside a request stay there. The invariant suite
(`test/MintRequests.invariant.t.sol`) drives requests, fills, cancels, refunds, donations and Tether's fee switch in any
order. It holds the contract's balance of each token at exactly its open escrows plus donations, and no requester ever
below their limit. `test_mintRequestsWithTheRealStablecoins` repeats the fee cases against mainnet USDT on a fork.

### PathLib (`src/libraries/PathLib.sol`)

Decodes Uniswap V3 packed paths (`token(20) | fee(3) | token(20) ...`): shape check, first token, last token. V4 routes
are typed `PathKey[]` and need no decoding.

## 3. The λ band auction

Units proportional to supplies make prices cancel out of the weights, so a market-cap index never has to trade when
prices move. It trades only when a reference supply changes. The auction below moves the units back to proportional,
and its worst case is a number of the band alone, whatever prices do. Notation: `u_i` a component's units, `f_i` its
reference supply in force, `M` the moving components (all but the kept ones), `WAD = 1e18`, `STEP = MAX_SUPPLY_STEP =
0.005e18`.

### 3.1 Start: the band

`startRebalance(keepMask)` reads `f_i` for the moving components only (a kept component is not read at all) and
computes, with `ρ_i = u_i / f_i` the units held per unit of supply and `a` the first moving component:

```
R_i  = mulDiv(u_i · f_a, WAD, f_i · u_a)                     rounded down; R_i / R_j = ρ_i / ρ_j
c    = (min R + max R) / 2                                   rounded down
r_i  = clamp( mulDiv(R_i, WAD, c),  WAD − STEP,  WAD + STEP )   rounded down, stored as uint64
λmax = max r,   λmin = min r
```

Anchoring on `a` cancels `a`'s own figures exactly, and keeps the products in range: `u < 2^96` and `f ≤ 2^128`, so
`u · f < 2^224`, and `mulDiv` works in 512 bits. The start reverts `BandTooNarrow(λmin, λmax)` when
`λmax · WAD < λmin · (WAD + MIN_BAND)`, with `MIN_BAND = 0.001e18`: every moving component's units already follow its
supply to within rounding. That covers no supply changing, every supply changing alike, and a single moving component.
`MIN_BAND` is ten times the widest rounding gap between two freshly anchored components held at 10,000 raw units (one
raw unit in 10,000), and a tenth of the widest band.

### 3.2 The auction: λ(t)

After `REBALANCE_DELAY` (2 days) of notice, from `eta` to `eta + AUCTION_DURATION` (24 hours):

```
λ(t) = λmax − ⌊(λmax − λmin) · (t − eta) / AUCTION_DURATION⌋
```

The decrement rounds down, so λ rounds up, towards the holders. `currentLambda()` returns it, and 0 outside an auction.

### 3.3 Settlement

For every moving component, at `λ = λ(t)` and `S = totalSupply()` in the settling block:

```
u'_i  = ⌈λ · u_i / r_i⌉                                      kept components keep u_i
out_i = ⌊S·(u_i − u'_i)/1e18⌋             when u'_i < u_i    (the index pays the executor)
in_i  = ⌈S·(u'_i − u_i)/1e18⌉             otherwise          (the executor pays the index)
```

A component whose ratio is above λ shrinks; one below λ grows. Each leg's change in backing is rounded the holders' way
on its own, down when it leaves and up when it comes back, so the amounts come from supply and units alone, and the
index never pays out rounding dust or a donation. As a difference of floored backings, a shrinking leg of a sub-token
index could release a whole raw unit for a fraction of one while no growing leg asked for any, paying an executor that
delivered nothing (SA-07). The invariant survives the rounding, since `⌊a − b⌋ ≤ ⌊a⌋ − ⌊b⌋` and
`⌊a + b⌋ ≤ ⌊a⌋ + ⌈b⌉`. If no `out_i` is non-zero
at `λ(t)`, as on an empty index or one so small that every shrinking leg rounds to zero, the settlement is taken at
`λmax` instead, where nothing shrinks, so the units never depend on timing when nothing is paid for (R14, XA-27).

In order: check the window and, for the bounded overload, `maxAmountsIn`; read what the index holds of every component
that moves (a component with neither an `out` nor an `in` is not read at all, not even for its balance, DA-14); write
the new units, bump `rebalanceNonce`, set `lastRebalance`, clear the proposal, emit `Rebalanced`; send each `out_i` to
`msg.sender`; call `IRebalanceExecutor.onXindexRebalance(amountsOut, amountsIn, data)` on it; then require, for every
moving component, a balance of at least the larger of `⌊S·u'_i/1e18⌋ + totalClaims` and what it held before, less
`out_i`, plus the whole of `in_i`. Surplus the index already held, from rounding or a donation, therefore stays with the
holders instead of paying for part of the fill (`RebalanceUnderfunded`).

### 3.4 Why no price is needed

At any prices `p`, the λ that leaves the moving value unchanged is

```
λ* = Σ u_i p_i / Σ (u_i / r_i) p_i  =  Σ w_i r_i / Σ w_i,      w_i = (u_i / r_i) · p_i ≥ 0
```

a weighted average of the stored ratios, so `λmin ≤ λ* ≤ λmax` at every price vector, whatever the rounding of the
ratios. A fill at λ multiplies the moving value by `λ / λ*`, which lies in `[λ / λmax, λ / λmin]`, so holders keep at
least `λmin / λmax` of it at the floor. Rounding units up only adds to what they keep. Prices moving between the start
and the fill move λ*, never outside the band: this is what v3's settlement value gate (DA-05) and its ratio (CR-L06)
used to approximate with feeds.

| Quantity | Bound |
|---|---|
| Loss per rebalance to a lone executor at the floor | `1 − λmin/λmax ≤ 1 − (1 − STEP)/(1 + STEP)` = **0.995%** of the moving value |
| Per day, weekly cadence (a cycle takes at least 9 days: 7 between fills, then 2 of notice) | about **0.11%** |
| Per year, if every cycle's supplies moved the full step apart and no executor ever competed | about **33%** |
| Units per rebalance | `u'/u ∈ [λmin/λmax, λmax/λmin] ⊂ [0.990, 1.0101]`, plus one raw unit of rounding |

The band covers the whole moving value, however small the trade: a 0.5% revision of a component weighing 1% trades
about 0.005% of the index, yet opens a 0.5% band. A price-free scalar auction cannot tell a small trade from a large
one; competition, the notice and the guardian's cancel are the recourse (README, "Known limitations").

**Measured on a mainnet fork** (`test/fork/Rebalance.fork.t.sol`, WBTC, WETH, LINK and UNI at their reference
supplies, a batch raising WBTC's 0.5%, cutting LINK's 0.5% and raising UNI's 0.3%): the band was [0.995, 1.005], and
the break-even λ* from real Uniswap quotes was 0.99585, inside it; the settlement at the second λ(t) reaches λ* gave
back what it took to within its rounding. A fill at the floor through real V3 pools cost the basket 0.085%, which is
`(λ* − λmin) / λ*`. `startRebalance` used 178,672 gas at four components, and the fill with the executor's swaps
356,357.

### 3.5 Why the ratios are centred, and why units anchor

Unclamped, `u'_i = λ · u_i / r_i = λ · c · ρ_a · f_i`: every moving component's new units are the same constant times
its supply. So a full fill makes units exactly proportional to supplies again, and any skew a keep mask left, any clamp
residue and any rounding drift is corrected at the next rebalance instead of compounding
(`testFuzz_repeatedFillsConvergeToTheSupplies`). The clamp is taken around the centre of the ratios, so however far
supplies ran ahead of the units, a wide band narrows to exactly `[1 − STEP, 1 + STEP]` and never collapses: a start
cannot stall because the factory's figures moved more than one step since the last fill
(`test_R04_R17_theBandIsTheClampsHoweverManyBatchesLanded`).

The clamp heals the extremes first. While one component's ratio sits more than the band away from the rest, every other
moving component is clamped to the opposite bound and settles alike, so its own revision waits until the far one has
converged; nothing is taken beyond the band while it does. With supplies moving at most half a percent a week (SA-04)
and a band of up to 1% per cycle, a component stays ahead only when something else held it back, such as a keep mask
over several cycles (SA-08).

The design's first draft set `u' = λ·k·s'` with the band taken from old and new supplies. After any keep-mask fill,
units no longer equal `k·s`, so λ* could fall outside that band and a fill at the open would overpay the executor. The
units-anchored form has neither problem (design section 6.6).

### 3.6 Two bounds, neither enough alone

The factory's step bounds each supply update: at most 0.5% per token, behind 2 days of notice and the guardian's veto,
so a slip or a hostile figure is small and visible before it counts. It does not bound a rebalance, because several
batches can land between two rebalances. The hub's clamp bounds each rebalance's band to `1 ± STEP` however many
batches landed, but alone it would let one bad figure steer an index over successive rebalances. Together: no update
moves a supply more than a step, and no rebalance exposes more than the band. `MAX_SUPPLY_STEP` is the same constant in
both contracts, which `test_constantsAndIdleViews` asserts.

### 3.7 Keep mask

A kept component keeps its units, is not read from the factory, takes no part in the band's centre, and is neither
transferred nor read for its balance at settlement, so the mask routes around a component that is paused, blacklists
the hub, or whose contract no longer answers at all (DA-14, RT-01). The other moving components still need a band of
at least `MIN_BAND` between them, and the next fill without the mask re-anchors the kept one.

## 4. Accounting

Invariant, for every component, forever:

```
token_i.balanceOf(index) >= floor(totalSupply × units_i / 1e18) + totalClaims[token_i]
```

Ceil-on-issue and floor-on-redeem mean rounding drift is at most one raw unit per call, always in favour of the
remaining holders. A claim is recorded only for an amount that stayed in the index, and because `floor(a) + floor(b)
≤ floor(a + b)`, burning shares always frees at least that much required backing, so claims never dilute anyone. A
rebalance moves each leg's change in required backing rounded the holders' way (SA-07), and its post-check is the
invariant with the new units plus the whole of `amountsIn` on top of what the index held. Nothing is computed from balances, so there is no share price to
manipulate and no first-depositor attack; donations only add surplus that no holder can redeem and no executor can use.

**The fee seam.** Every conversion of shares into an amount of a component goes through one private helper,
`_backing(shares, units, rounding) = mulDiv(shares, units, 1e18, rounding)`: issue, redeem, the settlement and its
backing check. A fee model therefore changes that helper and its callers and nothing else (spec section 7): a minter
fee in shares changes issue and redeem; a management fee is a unit scale inside `_backing`. Neither is built; the
choice is the owner's.

## 5. Flows

The README's "How the flows work" walks through each flow for an app. In short:

- **Create.** `k` is the fraction of each reference supply, times 1e36, that one index token holds, so the index
  token is worth about `k / 1e36` of the basket's total market cap. The creator previews the units and the address,
  and creates.
- **Mint and burn** through the zap (up to about 35 components), in kind (up to 100), or at a limit through
  `MintRequests`, filled by anyone who holds or can issue the shares.
- **Weekly supply update.** One batch a week from the owner Safe, 2 days of notice with the guardian's veto, then
  executed by anyone. The week is enforced: a batch comes due no sooner than `MIN_SUPPLY_INTERVAL` (7 days) after the
  last one executed (SA-04). At 0.5% a week an index follows a token whose supply grows up to about 30% a year faster than the
  rest (1.005^52 − 1); monthly updates would follow only about 6.7%.
- **Rebalance.** After the batch and the 7-day interval, anyone starts; 2 days of notice, in which holders who disagree
  can leave and a batch executed meanwhile does not move the pending settlement (R22); a 24-hour auction. During the
  auction an executor can order its fill ahead of a public exit (RT-02), so the notice is the window to leave.
- **Frozen component.** `redeemSkipping` and `claim` for holders, the keep mask for rebalances.
- **Valuation** is off chain: `value per share = Σ units_i × price_i` from the app's own prices (design section 10).
  Nothing on chain depends on it.

## 6. Key design decisions and rationale

**In-kind core, swap layer on top.** Splitting custody (the hub) from convenience (the zap) keeps the part that holds
funds small and admin-free, and lets the swap layer be replaced without touching any index.

**No price anywhere.** v3 read Chainlink feeds to shape targets and to gate each settlement, which made a stale feed a
halt, made Chainlink a trusted dependency, and could only approximate a bound at market prices (CR-L06). Units
proportional to supplies need no price to be on the rule, and the λ band bounds a fill at every price vector. What
takes the feed's place is data the owner maintains, the reference supplies, behind the step, the delay and the veto.
Pricing the index moved off chain, where it can use many sources and never sizes an amount. `test/Repo.t.sol`
(`test_noContractReadsAPrice`) asserts that `src/` and `abi/` name no price interface.

**Uncapped only.** The capped 30/20 methodology trades whenever prices move, because a cap binds on value, and needs
every price to know which cap binds; a price-free index cannot offer it, so it is retired (design section 13).

**Weekly updates, a 0.5% step.** A weekly cadence follows supply growth of up to 30% a year, where monthly updates
followed only about 6.7%, leaving tokens that unlock 10% to 40% a year persistently underweight. The step keeps each
update small enough that a slip is bounded and reviewable.

**Atomic batches, one at a time.** A batch that could execute in part would let a stranger turn a uniform revision into
a trade; one live batch at a time keeps what the guardian reviews the whole of what can land.

**The address commits to the computed units.** The salt covers the units `createIndex` computes, not `k`, so an address
can never hold a different basket, even if a batch lands between a preview and the creation, and a front-runner's copy
lands at its own address (LR-05).

**Up to 100 components.** The in-kind paths fit EIP-7825's per-transaction cap of 2^24 gas at 100, measured with every
account cold (`test_aHundredComponentsFitOneTransaction`, `test_createIndex_maxComponentsOk`):

| Operation at 100 components | Gas |
|---|---|
| `createIndex` | about 4.9M |
| `issue` | about 3.6M |
| `startRebalance` | about 1.5M |
| `executeRebalance`, an executor that already holds the bought tokens | about 3.4M |
| `redeem` | about 3.7M |
| `redeemSkipping`, one component skipped | about 1.7M |
| `claim` | about 53k |

A fill that swaps inside the call costs about 150k a leg on top (design section 9.1), so an atomic fill at 100
components needs an executor with inventory. The zap stops near 35 components (section 2).

**Unchanged from v3:** the burner chooses the exit token, whitelist only, skip-and-claim, public delays, the
balance-measured zap, and fixed constituents (a new list is a new index version, design section 6.7).

## 7. Security model

- **Trust.** The factory owner (a Safe), who proposes listings, supply batches and guardian changes behind public
  delays and hands over ownership in two steps with no delay; the guardian, who can cancel listings, batches and
  rebalances, delist, start a rebalance with a keep mask or before strangers may, and cancel its own removal but not
  its replacement; the whitelisted tokens and their issuers (WBTC's custodian); and, for the zap only, Uniswap's
  Universal Router and the V4 PoolManager. No price source is trusted, because none is read. Executors and the account
  that starts a rebalance are untrusted. Users trust no one with custody.
- **What can move a basket's shape.** Only the reference supplies: the owner's figures, at most one step per update,
  each behind the delay and the veto, and each rebalance at most the clamp. Nothing a stranger does inside a
  transaction moves a supply the hub reads (`test_CRM01_wrappingEtherAroundAStartMovesNothing` wraps a million ether
  around a start on a fork, and the band does not move by a wei). A due proposal takes effect when someone executes
  it, so whoever acts first decides whether a start in between reads the old supplies or the new; both were reviewed.
- **What can move value.** A fill at λ inside the band: at most `1 − λmin/λmax` of the moving value to a lone executor,
  at any prices (section 3.4). Rounding goes the holders' way everywhere.
- **The guardian's stalls.** `cancelRebalance` has no window and no rate limit, so a hostile or compromised guardian can
  cancel every proposal at the last second of its auction until the owner replaces it: `GUARDIAN_DELAY` of notice that
  the guardian cannot cancel. That is a trust assumption of the role, because the cancel exists to stop a bad
  rebalance in its last seconds (DA-12). The guardian can also stall without a cancel: a keep-mask rebalance that
  leaves a pair of components moving can clear `MIN_BAND` on a sliver of the index, and its fill restarts
  `MIN_REBALANCE_INTERVAL` for everyone, so the stall can outlast the guardian's replacement by up to a week. While a
  replacement is pending the owner cancels the outgoing guardian's keep-mask proposals, and monitors watch
  `RebalanceStarted` with a non-zero `keepMask` (RT-07). Neither stall moves funds; holders redeem throughout.
- **Reentrancy.** `nonReentrant` on `issue`, `redeem`, `redeemSkipping`, `claim`, `startRebalance`, `cancelRebalance`,
  both `executeRebalance` overloads, `createIndex`, `mintWithToken`, `burnToToken` and `burnToTokenWithPermit`.
  Checks-effects-interactions throughout: the new units, the nonce and the cleared proposal are written before any
  rebalance transfer, and the callback goes only to `msg.sender`, which must be a contract. Wake's reentrancy detector
  does not model the guard; its three documented suppressions are the `redeem` call in `IndexZap._burnBasket`, the
  `permit` call in `burnToTokenWithPermit` and the executor callback in `executeRebalance`.
- **Read-only reentrancy.** Inside `issue`, `redeem` and `executeRebalance`, supply, units and balances change at
  different moments. Integrators must value an index from `components()` and independent prices, never from
  `balanceOf(index)` and `totalSupply()`.
- **Clone safety.** The implementation has initializers disabled; `initialize` is `FACTORY`-only and runs in the same
  transaction as the clone; uninitialized instances cannot issue, redeem or rebalance; `isIndex` is the only trusted
  registry, and the zap checks it.
- **Token behaviour.** `issue` verifies received amounts. A paused or blacklisting component does not freeze the rest
  of a basket: `redeemSkipping` exits everything else, `claim` collects the frozen part later, and a keep mask
  rebalances around it. Policy: standard ERC-20s, 6-18 decimals, no fee-on-transfer, rebasing or callback tokens;
  stables are mint currencies, not components; pausable components and their issuers are labelled in the app.
- **Zap.** As in v3: every route's endpoints checked, one venue per leg, hookless V4 routes, native ether only as an
  intermediate, per-leg and overall limits on every leg, balance-measured payments and payouts, `ShortFill` on mints,
  `TransferShortfall` on fee-charging currencies, every router command built here, the router pre-funded with exactly a
  leg's cap and swept clean within the same `execute`, `expectedNonce` checked twice, one reentrancy guard across all
  three entry points.
- **Arithmetic.** Units below `2^96` (`SafeCast`), and at most `MAX_UNITS` at creation; supplies at most `2^128`;
  ratios below `2^64`; every product through 512-bit `mulDiv`. `test_XA23_theBandHoldsAtTheExtremesOfUnitsAndSupplies`
  starts and settles an index with a component at `MAX_UNITS` and a supply of `MAX_SUPPLY` beside one at the unit
  floor, and one with a supply of one raw unit beside a component at `MAX_UNITS`; it fails with the band's `mulDiv`
  replaced by plain arithmetic.
- **Operations.** `OWNER` and `GUARDIAN` are required at deploy, with `UNIVERSAL_ROUTER` the only market address; on
  mainnet the owner must be a contract that is not an EIP-7702 delegated account, and a Safe must need at least three
  signatures and have no enabled module; neither the guardian nor the deploying key may be one of its signers. Neither role may be a market contract: the router, the PoolManager, and on
  chain 1 every token and mint currency in the address book (XA-39, CR-I37). The supplies need a weekly review against
  dated sources, and a due batch should be executed at its eta.
- **Known limitations** are listed in the README, where users read them.

## 8. Verification

- **Unit and fuzz tests per contract:** `test/IndexHub.t.sol`, `test/IndexHub.rebalance.t.sol`,
  `test/IndexFactory.t.sol`, `test/IndexZap.t.sol`, `test/Scripts.t.sol` (the scripts in-process), `test/Repo.t.sol`
  (the repository facts findings rest on), `test/FaucetToken.t.sol`, and the mocks' own tests in
  `test/mocks/Mocks.t.sol`, with a strict mock of the Universal Router that decodes against the pinned 2.0.0 command
  and action layouts, and mock executors that fill honestly, short, not at all, or reentrantly. The band's properties,
  with prices that exist only inside the tests: `testFuzz_DA01_R08_CRI03_aFillIsBoundedByTheBandAtAnyPrice` (at prices
  drawn per run, a fill leaves the moving value at least `λmin/λmax` and moves units within the band),
  `testFuzz_repeatedFillsConvergeToTheSupplies`, `testFuzz_R19_CRI33_theBandGateIsExactlyMinBand` (the gate to one
  wei), `testFuzz_lambdaFallsFromTheTopOfTheBandToTheBottom` and `testFuzz_settlementKeepsBacking`.
- **Invariant suites.** `test/IndexHub.invariant.t.sol` runs random issue, redeem, `redeemSkipping`, claim, transfer,
  donate, supply revisions through batches, shadow price moves, time jumps, starts, cancels, honest, bounded and short
  fills, and asserts that every component stays backed including open claims, supply equals the sum of holder balances,
  claims add up, the nonce counts executed rebalances, a short fill never settles, units move at most the band plus one
  raw unit, `canStartRebalance` says when a stranger may start, a fill settles exactly the units its preview showed,
  every stored ratio lies within the clamp and the band, and no fill ever left the moving value worth less than
  `λ / λmax` of what it was at the shadow prices. `test/IndexFactory.invariant.t.sol` asserts that the whitelist array
  is exactly the listed set, the supply in force is always the last executed change, no revision moved a supply more
  than a step, batches come into force whole, nothing executes outside its window, and the guardian is the last
  executed change.
- **Security regression tests,** named after their ids, as `AGENTS.md` gate 6 requires. Two records say which ids lost
  their test when a mechanism went: `audit/2026-09-22-v3-retirement.md` for the move off Uniswap pricing, and
  `audit/2026-09-30-v4-stage-a-retirement.md` for Stage A, which retired 31 tested ids (the rule, capped, the feeds,
  the price gate, the turnover gate and the decimals record) and re-targeted the rest, checked against the ids tested
  at `v3.0.0`. A retired id's test is never restored against the new design.
- **Mainnet fork tests,** four suites and 26 tests against the real Universal Router 2.0.0, the V4 PoolManager and real
  tokens: the zap end to end on V3 and V4 legs (`IndexZap.fork`); the address book, the router's and PoolManager's code
  hashes and the default list (`MainnetAddresses.fork`); a λ fill through real V3 pools, the break-even at real quotes
  and a guardian keep mask around a real WBTC pause (`Rebalance.fork`); and the WBTC pause exit, USDT's fee switch,
  stray router balances, WETH's supply moving around a start, and the deploy script's module check against real Safe
  1.3.0 and 1.4.1 singletons (`Security.fork`).
- **Gates,** all enforced in CI: `forge fmt --check`, `forge build`, `forge lint -D notes`, `forge test` (fork suites
  required on pushes to `main` and on pull requests into it from this repository), 100% coverage on every file, the ABI
  diff, the Wake detectors clean on `src/`, and the submodule check against `foundry.lock`.

## 9. Mainnet addresses

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
| Uniswap V4 StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| Uniswap V4 Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Uniswap QuoterV2 (V3 quotes) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| HybridIndexFactory / IndexZap / MintRequests | not deployed |

Only the tokens and the Universal Router are read by anything deployed: the quoters and StateView are for apps and
tests, and the PoolManager is reached through the router. The V3 pools the fork tests swap through are in
`test/fork/ForkAddresses.sol`; no contract reads them.

## 10. Roadmap

**Stage A, what remains.** The internal red team has reviewed the new surface (`audit/2026-09-30-stage-a-red-team.md`);
what remains is an external audit, a Sepolia deployment with a smoke test, and a
mainnet deployment through the Safe.

**Proving prototype.** A full-finality Ethereum proof verified on BNB Chain and on Solana, and a BNB Chain state proof
verified on Ethereum, with measured cost and latency against go/no-go thresholds the owner sets. It decides Stage B, or
the design's weaker sync-committee fallback.

**Stage B.** Ownerless vaults holding native BNB, SOL, TRX and HYPE on BNB Chain, Solana, Tron and HyperEVM, which pay
out only against proofs of what happened on Ethereum; the hub gains the mirror of vault balances, orders, burns, a
freeze that expires, migration, verifier rotation and a snapshot exit. BNB Chain goes end to end first.

**Stage C.** Avalanche, NEAR, Stellar, Hedera and Cardano, one chain at a time, each only if its finality is
deterministic, its proof cost is measured, its cap matters and its value pays for its vault, verifiers and audits.

The multichain design, its failure bounds and its parameters are in `design/2026-09-29-v4-hybrid-architecture.md`;
this file does not restate them.

**Backlog.** ETH in/out, `createAndMint`, `mintWithTokenPermit` (USDC only), mixed-venue legs that split one leg
across V3 and V4, a permissionless backstop executor and a reminder for the weekly trigger, an aggregator or Universal
Router 2.1 zap, V4 pools on the Sepolia market, and an auction whose exposure scales with the trade rather than the
moving value.

## 11. History

- **v1 and v2** (2026-09-15 and 2026-09-16): the in-kind core and the zap, then on-chain rule rebalancing from Uniswap
  V3 pool averages, with the Numbers model's uncapped and capped methodologies.
- **v3** (2026-09-22): prices from Chainlink USD feeds, execution through the Universal Router; the change and what it
  retired are in `audit/2026-09-22-v3-retirement.md`. v3 is tagged `v3.0.0` and runs on Sepolia; it never launches on
  mainnet.
- **v4** (2026-09-29 to 2026-09-30): the hybrid multichain design, revised after an external review, and Stage A's
  price-free contracts. Why prices left the contracts is in design sections 6.6 and 13; what that retired is in
  `audit/2026-09-30-v4-stage-a-retirement.md`.
