# Xindex Architecture

Xindex turns a portfolio of tokens into a single ERC-20 index token. Anyone can create an index, anyone can mint it with
USDC or USDT, and anyone can burn it back into USDC, USDT, WBTC or any other token with Uniswap V3 or V4 liquidity.
Every index is fully backed, in kind, by the tokens it represents. Its constituents never change; its units follow the
uncapped market-cap rule `units ∝ supply`, from reference supplies the owner updates weekly behind a public delay. **No
contract reads a price**: a rebalance settles through an auction on a single number, λ, whose worst case holds at any
prices. No admin can touch user funds, and no protocol key or bot is involved in rebalancing. An index can also hold
other chains' native coins, in ownerless vaults on those chains that pay out only on proofs of what happened on
Ethereum.

This file describes **v4 as built**. v4 is one hybrid product, and its stages are build order only: Stage A, the
price-free part held on Ethereum (sections 1 to 9), and Stage B, the vaults and the proofs between them (section 10),
built in code and deployed nowhere. It launches on `HybridIndexFactory` once the hybrid index is ready (the owner's
call on 2026-10-01). The multichain design is `design/2026-09-29-v4-hybrid-architecture.md` (the "design" below); the
contract specs are `design/2026-09-30-v4-stage-a-spec.md` (the "spec") and `design/2026-09-30-v4-stage-b-spec.md` (the
"Stage B spec"). Internal red teams have reviewed Stage A (`audit/2026-09-30-stage-a-red-team.md`), Stage B
(`audit/2026-09-30-stage-b-red-team.md`) and the Tron state verifier (`audit/2026-10-01-tron-review.md`); nothing has
had an external audit. Section 11 lists what remains.

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
| Layer-1 coins | Stage A: Ethereum tokens, Bitcoin as WBTC. Stage B: native coins in vaults on chains that can verify a proof of Ethereum's finality and whose state Ethereum can verify; built in code for BNB Chain and TRON, in part for Solana (section 10) |

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

The index itself, renamed from v3's `IndexToken`. Stage B leaves it unchanged: an index of Ethereum tokens only is an
`IndexHub` clone, and an index holding any vault token is a clone of a separate template, `HybridHub` (section 10.2;
Stage B spec, proposal 1). An EIP-1167 clone of one implementation, using OpenZeppelin's upgradeable ERC20 and
ERC20Permit (clones skip constructors, so name and symbol are set in `initialize`).

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
- **Templates.** Two internal hooks, `_template(tokens)` and `_initializeIndex`, choose the template a new index is a
  clone of and initialize it. Here they always give `IndexHub`. `HybridIndexFactory` (section 10.1) overrides both, and
  is the factory v4 deploys (`script/Deploy.s.sol`); everything below holds for it unchanged.
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
- **`IndexHub` clones only.** A `HybridHub` is in the factory's registry, but no part of it answers `componentTokens`,
  so a zap call on one reverts with nothing moved (`test_theZapCannotMintOrBurnAHybridIndex`). A hybrid index's mints
  are orders (section 10.2).
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
fee in shares changes issue and redeem; a management fee is a unit scale inside `_backing`. Neither is built: there is
no fee (the owner's call on 2026-09-30, design section 13.1), and a fee, if one comes, arrives with a later index
version through this seam. `HybridHub` keeps the same helper, in `HybridHubStorage`.

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
- **An index holding vault tokens** mints by order, redeems with a burn to each vault chain, and rebalances in three
  steps (section 10.2).
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
  that starts a rebalance are untrusted. Users trust no one with custody. An index holding vault tokens adds the
  trust of section 10.6.
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
- **Operations.** `OWNER` and `GUARDIAN` are required at deploy, and must differ. `UNIVERSAL_ROUTER`, and `USDC` and
  `USDT` for `MintRequests`, are the only market addresses, mainnet's by default on chain 1, where no other is accepted.
  On mainnet the owner must be a contract that is not an EIP-7702 delegated account, and a Safe must need at least
  three signatures and have no enabled module; neither the guardian nor the deploying key may be one of its signers.
  Neither role may be a market contract: the router, the PoolManager, and on chain 1 every token and mint currency in
  the address book (XA-39, CR-I37). The supplies need a weekly review against dated sources, and a due batch should be
  executed at its eta.
- **Known limitations** are listed in the README, where users read them.

## 8. Verification

- **Unit and fuzz tests per contract:** `test/IndexHub.t.sol`, `test/IndexHub.rebalance.t.sol`,
  `test/IndexFactory.t.sol`, `test/IndexZap.t.sol`, `test/MintRequests.t.sol`, `test/Scripts.t.sol` (the scripts
  in-process), `test/Repo.t.sol` (the repository facts findings rest on), `test/FaucetToken.t.sol`, and the mocks' own
  tests in `test/mocks/Mocks.t.sol`, with a strict mock of the Universal Router that decodes against the pinned 2.0.0
  command and action layouts, and mock executors that fill honestly, short, not at all, or reentrantly. The band's
  properties, with prices that exist only inside the tests:
  `testFuzz_DA01_R08_CRI03_aFillIsBoundedByTheBandAtAnyPrice` (at prices drawn per run, a fill leaves the moving value
  at least `λmin/λmax` and moves units within the band), `testFuzz_repeatedFillsConvergeToTheSupplies`,
  `testFuzz_R19_CRI33_theBandGateIsExactlyMinBand` (the gate to one wei),
  `testFuzz_lambdaFallsFromTheTopOfTheBandToTheBottom` and `testFuzz_settlementKeepsBacking`.
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
- **Mainnet fork tests,** five suites and 36 tests against the real Universal Router 2.0.0, the V4 PoolManager and real
  tokens: the zap end to end on V3 and V4 legs (`IndexZap.fork`); the address book, the router's, PoolManager's and V3
  factory's code hashes, the default list and the wide list (`MainnetAddresses.fork`); the admission check passing WBTC,
  LINK and every wide-list token and refusing WBT, LEO and WLFI (`CheckToken.fork`); a λ fill through real V3 pools, the break-even at real quotes
  and a guardian keep mask around a real WBTC pause (`Rebalance.fork`); and the WBTC pause exit, USDT's fee switch,
  stray router balances, WETH's supply moving around a start, `MintRequests` with the real USDC and USDT and Tether's
  real blacklist, and the deploy script's module check against real Safe 1.3.0 and 1.4.1 singletons (`Security.fork`).
- **Stage B** has its own suites, listed in section 10.7.
- **Gates,** all enforced in CI: `forge fmt --check`, `forge build`, `forge lint -D notes`, `forge test` (fork suites
  required on pushes to `main` and on pull requests into it from this repository), 100% coverage on every file, the ABI
  diff of all seven committed ABIs, the Wake detectors clean on `src/`, and the submodule check against
  `foundry.lock`. Aderyn reports nothing on `src/` (`aderyn.toml` gives each excluded rule its reason); CI does not run
  it yet. The Rust of `proofs/` and `solana/` has gates of its own, run locally and not in CI (`AGENTS.md`).

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
| HybridIndexFactory / IndexHub implementation / HybridHub template, module, extension / IndexZap / MintRequests | not deployed |
| State verifiers on Ethereum; vaults, P1 and P2 on vault chains | not deployed |

Only the tokens and the Universal Router are read by anything deployed: the quoters and StateView are for apps and
tests, and the PoolManager is reached through the router. The V3 pools the fork tests swap through are in
`test/fork/ForkAddresses.sol`; no contract reads them.

## 10. Stage B: vaults on other chains

Stage B is built in code and deployed nowhere. It holds other chains' native coins in vaults on those chains, and on
an EVM vault chain the tokens governance has given a cap, for indexes whose shares live on Ethereum. Coins leave a vault only on messages from Ethereum that two independent proof
systems, P1 and P2, show final there; Ethereum reads each vault's state through a verifier of that chain's own
consensus. The rules are in the Stage B spec, and `AGENTS.md` ("Stage B") lists those code must never break. This
section says what is built; the spec has the rest.

| Chain | Vault | Ethereum → vault (P1, P2) | Vault → Ethereum |
|---|---|---|---|
| BNB Chain | `XindexVault` | `EthereumFinalityVerifier`, `RiscZeroFinalityVerifier` | `BnbStateVerifier` |
| TRON | `XindexVault`, built with Tron's compiler (`tron/`) | the same two, run on TRON's VM | `TronStateVerifier` |
| Solana | `solana/programs/xindex-vault` | P1 as `solana/programs/ethereum-verifier`; P2 not built | not built: waits on Alpenglow's mainnet launch |
| HyperEVM | none | — | none: every header's state root is zero |

```
                         ETHEREUM                                     ┆                 A VAULT CHAIN
                                                                      ┆
  HybridIndexFactory   chain registry · vault-token listings ·        ┆
        │              chain freeze · governance messages             ┆
        │ CREATE2 clone, when the basket holds a vault token          ┆
        ▼                                                             ┆
  HybridHub (ERC-20)   hub, module and extension on one storage;      ┆
                       Ethereum components in its balance,            ┆
                       vault components in its book;                  ┆
                       orders · redeem · λ fills · migration ── VaultMessage, by P1 AND P2 ──► XindexVault
        ▲                                                    (FREEZE, a lowered cap: either)   one per chain, for every
        │ verifySlots: the vault's intake and index digests           ┆                        index; no owner; pays
  BnbStateVerifier / TronStateVerifier ◄──── the vault's storage, final on its chain ───────── within 4% a day
                                                                      ┆                             ▲
                                                                      ┆   minters, executors ── deposit(index, intakeId)
```

### 10.1 HybridIndexFactory (`src/HybridIndexFactory.sol`)

`IndexFactory` with its two template hooks overridden, plus a chain registry, vault-token listings, a chain freeze and
the governance messages to vaults. Stage A's flow is unchanged.

- **Templates.** An index holding any vault token is a `HybridHub` clone, initialized with each component's chain,
  token id and vault, copied once: an index's vaults never change. Its CREATE2 salt is recorded (`indexSalt`), which a
  vault's `registerIndex` checks. Any other index is an `IndexHub` clone, as in Stage A. With both templates inside
  it, the factory's initcode would pass the 48KB limit, so `script/Deploy.s.sol` deploys the `HybridHub` extension,
  module and template first, each for the factory's address predicted from the broadcaster's nonce, and then the
  factory, which refuses a template built for another factory (`NotFactoryTemplate`).
- **Chains.** `proposeChain(chainId, vault, stateVerifier)`, owner only, executable by anyone (`executeChain`) after
  `LISTING_DELAY` and within `PROPOSAL_WINDOW`, and cancellable by the owner or guardian (`cancelChain`). Chain id zero
  is refused, since zero is Ethereum's place in an index. A vault is a 32-byte id, so a Solana account fits. A chain's
  vault is fixed at its first registration (`VaultFixed`). After that only its state verifier changes, and a new one
  waits `ROTATION_DELAY` (30 days), since it decides every index's mints on that chain (FAC-1). Every index reads the
  verifier from the registry at each proof. `chain`, `stateVerifier`, `chainPending` and `chainProposal` are the views.
- **Vault tokens.** `proposeVaultListing(chainId, tokenId, supply)` lists a coin under `vaultTokenId(chainId,
  tokenId)`, a 20-byte hash that no contract holds. From its proposal on, the coin takes Stage A's listing flow,
  delisting and weekly supply batches unchanged; `vaultToken(token)` maps the id back.
- **Freeze.** `freezeChain(chainId)`, owner or guardian, stops every index's mints on the chain for `FREEZE_DURATION`
  (14 days) and sends the vault a `FREEZE`. `freezeOnEvidence(chainId, payouts)` does the same for a `HybridHub` clone
  of this factory that has checked evidence against the chain (section 10.2); it freezes the vault too only with
  `payouts`, which a hub passes only on evidence of a payout Ethereum never sent.
- **Governance messages.** A vault has no owner; its settings change only through messages the factory sends after a
  delay. Each proposal is the owner's, one live per chain and kind (and token, for caps), and executable by anyone
  (`executeVaultProposal`) within `PROPOSAL_WINDOW` after its delay:

| Proposal | Message | Delay | Cancelled by |
|---|---|---|---|
| `proposeCap(chainId, token, cap, floor)` | `CAP_UPDATE`: a quantity cap and an outflow floor | `LISTING_DELAY`, 2 days | owner or guardian |
| `proposeFreezer(chainId, freezer)` | `FREEZER_CHANGE` | `GUARDIAN_DELAY`, 7 days | owner only: the guardian cannot block its own replacement |
| `proposeRotation(chainId, p1, p2)` | `VERIFIER_ROTATION`, to two different verifiers | `ROTATION_DELAY`, 30 days | owner or guardian |

### 10.2 HybridHub (`src/HybridHub.sol`, `src/hybrid/`)

An index whose basket holds tokens on Ethereum and coins in vaults. 1e18 shares are backed by `units_i` raw units of
each component, as in Stage A: an Ethereum component in the hub's own balance, a vault component in its chain's vault,
which pays it out only on messages the hub sends. Integrators call it through `IHybridIndex` (`abi/IHybridIndex.json`).

- **Three contracts, one storage.** `HybridHub` keeps orders, redemption and claims. Its fallback reaches
  `HybridHubModule` by `DELEGATECALL` (voids, re-confirmations, stray intakes and the rebalance), and the module's
  fallback reaches `HybridHubExtension` the same way (migration, evidence, recovery addresses, the exit record and held
  orders). All three run on the clone's storage, declared once in `HybridHubStorage` and appended to, never inserted
  into (`test_theHubAndTheModuleShareOneLayout`). The module is fixed in the template's constructor and the extension in
  the module's, so this is one contract split for size, not an upgrade path. The module and the extension move shares
  through `HubShares`, on OpenZeppelin's own ERC-20 slot. The hub and the module are both near the 24KB limit.
- **The book.** A vault component is held in `vaultBacking`, the hub's own record of what the vault holds for it. It
  grows by the proven deposits of every claimed order, the deliveries of every settled fill and what a migration brings
  in, and falls by every amount burned or migrated out, all from supply and units. The invariants:

  ```
  Ethereum:  balanceOf(hub) >= floor(S × units / 1e18) + totalClaims + escrowed
  vault:     vaultBacking   >= floor(S × units / 1e18) + totalClaims
  ```

- **Orders.** Minting goes through orders, and every order spans every chain of its index.
  - `openOrder(shares, deadline)` escrows the Ethereum components and returns an intake id,
    `(deadline << 192) | orderId`, with the deadline at most `MAX_ORDER_LIFE` (6 hours) ahead. The minter deposits each
    vault component on its chain under that id.
  - `settleOrder(orderId, proofs)`, anyone: each vault's intake digest, proven through the chain's state verifier at a
    block after the deadline, when deposits are final, must cover the order. Settling applies `MINT_CAP`: at most 4% of
    the supply may become claimable over the current hour and the 24 before it. An empty index has no room, and only
    its creator may seed it, by an order or a migration (HUB-2).
  - `MINT_LOCK` (24 hours) follows. In it, `voidOrder` takes any proof of the same intake, after the deadline, showing
    a different digest: the order fails and the chain's mints freeze for every index. A freeze that began at or after
    the settlement holds the order until `reconfirmOrder` proves the intake unchanged from after the freeze.
  - `claimOrder`, anyone, after the lock: mints the shares, credits the book, marks the intake settled and sends
    `INTAKE_SETTLED` to every vault. It waits while a chain is frozen or a fill is accepted, and fails an order whose
    escrow or deposits no longer cover its shares at the units in force.
  - `failOrder`: the minter while the order is open, or anyone `SETTLE_GRACE` (6 hours) after the deadline. The escrow
    becomes the minter's claims, never a transfer, so a paused Ethereum token cannot keep vault depositors from their
    `INTAKE_FAILED`. `failIntake` fails an intake that belongs to no order and no fill, so a stray deposit is never
    stuck.
- **Redemption.** `redeem(shares, to, recipients, skipMask)` pays the Ethereum components to `to` and sends each vault
  a `BURN` toward `recipients[j]`. A skipped component, or one on a chain whose recipient is zero, is booked as a claim
  of `to`. `claim` pays an Ethereum claim, and `claimToVault` burns a vault claim toward a recipient named then. No
  freeze stops a redemption. Every `BURN` and `MIGRATE` is counted in `sentOut` and marked in the transaction that
  sends it, which a snapshot exit reads.
- **Rebalance.** The start, the band, the notice, the keep mask and the cancel are Stage A's, unchanged, over every
  component; a vault token's supply comes from the factory like any other. A fill takes three steps, since vault legs
  cannot settle in one transaction:
  1. `acceptRebalance(recipients, maxAmountsIn)`, anyone, while the auction is live, at the current λ. The executor
     posts a bond of `REBALANCE_BOND` (0.1% of the supply, in shares), pays the bought Ethereum legs in the same
     transaction, and names one recipient per vault chain for the sold vault legs. It then deposits the bought vault
     legs under the fill's intake id, `(deadline << 192) | 1 << 191 | nonce`, within `DELIVERY_WINDOW` (6 hours).
  2. `settleRebalance(proofs)`, anyone, on a proof of each delivery intake. The settlement is recomputed at the supply
     of the settling block; it writes the new units, pays the sold Ethereum legs, burns the sold vault legs toward the
     executor's recipients and sends `INTAKE_SETTLED`.
  3. The bond is held `BOND_HOLD` (24 hours), then `releaseBond` returns it. During the hold, `slashRebalance` takes a
     proof from after the delivery deadline that a delivery intake is neither open nor settled, or holds less than the
     fill recorded (an empty one only on a chain where the fill recorded a delivery; HUB-1, MOD-1): the bond is burned
     and the chain's mints freeze.

  `failRebalance` (the executor before settlement, or anyone `SETTLE_GRACE` after the delivery deadline) burns the
  bond, returns the Ethereum deliveries as the executor's claims, has every vault refund the deliveries and holds
  strangers off for `REBALANCE_DELAY`. A `cancelRebalance` by the owner or guardian unwinds an accepted fill the same
  way but returns the bond. Mint claims wait while a fill is accepted, so the supply cannot grow under a settlement
  sized for it. There is no executor callback: the hub pulls the bought Ethereum legs.
- **Migration.** `migrate(newIndex, shares, newShares, to, recipients)` moves a holder to another `HybridHub` index of
  the same factory in one Ethereum transaction. The old shares are burned; each vault token both versions hold moves
  inside its vault by a `MIGRATE`, paid within the vault's speed limit; Ethereum tokens move from index to index, and
  the holder pays what the new shares need beyond them; what the old shares back beyond the new ones goes to `to`, as a
  redemption's would. The new index's `acceptMigration` accepts only a clone whose salt the factory recorded, checks
  its backing in real balances, counts against its mint cap (MOD-2), and refuses while a fill is accepted or one of its
  chains is frozen. A vault token only the new version holds comes by order.
- **Evidence.** `reportOutflow` proves a vault's index digest showing more of a token paid out than the index ever
  sent (`sentOut`), which only P1 and P2 both broken allow; it freezes the chain's mints and the vault.
  `reportForgedDeposit` proves a claimed order's intake, after its deadline, neither open with the deposits it was
  claimed on nor settled with them; it freezes the chain's mints. A void and a slash freeze mints the same way. Every
  such freeze is the factory's, for every index on that chain. An exited chain takes no evidence: every evidence proof
  also reads the vault's snapshot root and is refused once it is set, recorded here or not, since a vault in its exit
  honestly fails what was never settled and pays holders what the index never sent (LG-5).
- **Sending again.** The index marks every message it sends (`_sentMessages`), and anyone may emit a marked one again,
  unchanged, with `resendMessage(payload)`; the factory does the same for its own. Whoever sends a transaction shapes
  its receipt, which could otherwise be made too large for a vault chain's verifier; the copy's receipt is the
  caller's, and the vault runs a message once by its id (LG-1).
- **The exit.** `setRecoveryAddress(chainId, recipient)` names where a holder that cannot sign on a vault chain, such
  as a contract, is paid at a snapshot exit. `recordExit(chainId, proof)` proves through the state verifier that the
  vault began one; the index then never mints on that chain again. `failHeldOrder` fails a locked order: anyone's
  call once the exit keeps it from its claim, or its minter's once a freeze that holds it has been over for
  `HELD_ORDER_GRACE` (7 days) without a re-confirmation (HUB-3).

### 10.3 XindexVault (`src/vault/XindexVault.sol`)

One per chain, shared by every index, with no owner and no upgrade. It holds the chain's native coin, and each token a
`CAP_UPDATE` has given a cap, in a separate balance per index and token, takes coins only as deposits to an intake,
and lets them out only on proven messages.

- **Indexes.** `registerIndex(index, salt)`, anyone, records an index once its address is the factory's CREATE2 clone
  of `HUB_IMPLEMENTATION` under `salt`. Only a registered index takes deposits or sends a message that runs.
- **Deposits.** `deposit(index, intakeId)` is payable. It is refused while the vault is frozen or stalled, after the
  intake's deadline (the id's top 64 bits), and above the coin's quantity cap across all indexes. A first deposit may
  set a deadline at most `MAX_INTAKE_LIFE` (7 days) ahead. An intake stays open until a message settles or fails it;
  nothing is withdrawn meanwhile, and the vault never refunds on a timeout. `depositToken(index, intakeId, token,
  amount)` takes a token into the same intakes, refused unless the vault's balance rose by the whole amount.
- **Tokens.** A Binance-Peg coin or a token issued on BNB Chain is held as the native coin is
  (`design/2026-10-05-wide-asset-support.md`). Its cap starts at zero, which refuses it, so it enters only after a
  `CAP_UPDATE` has waited `LISTING_DELAY` on Ethereum and `GOVERNANCE_DELAY` on the vault. Its cap, floor, speed limit,
  refunds (`refund(index, intakeId, token)`) and snapshot claims are its own, so a token that pauses or blacklists the
  vault holds back only itself: its payout reverts, and its burn stays deliverable or owed. On Ethereum it is a vault
  coin like any other, `vaultTokenId(chainId, bytes32(token))`; the hub and the state verifiers do not change. A
  stranger's deposit of another capped token into an index's intake blocks nothing: the hub proves digests by their
  whole preimage and counts only its components, so the token joins the index's vault balance as a donation the hub
  never counts (`test_aStrayTokenInAnIntakeBlocksNothing`). The other vaults hold their native coin only.
- **Messages.** `deliver(proof1, proof2)` runs one `VaultMessage` that an index or the factory emitted, with
  `id = keccak256(payload)` and a payload naming the domain, Ethereum's chain id, the kind, the vault's chain, the
  vault, the index and a nonce (`src/libraries/VaultMessages.sol`). The route, the emitter and the used mark are
  checked, and the mark is written before any coin moves.

| Kind | Emitter | Proofs | Effect |
|---|---|---|---|
| `BURN` | the index | P1 and P2 | pays the recipient within the speed limit, and owes the rest |
| `INTAKE_SETTLED`, `INTAKE_FAILED` | the index | P1 and P2 | the deposits join the index's balance, or become refundable (`refund`) |
| `MIGRATE` | the old index | P1 and P2 | pays into the new index's balance, as a burn pays |
| `CAP_UPDATE` | the factory | both to raise the cap or the floor, either to lower them | sets the coin's cap and outflow floor |
| `FREEZE` | the factory | either | freezes the vault for `FREEZE_DURATION` (14 days) |
| `FREEZER_CHANGE`, `VERIFIER_ROTATION` | the factory | P1 and P2 | a new freezer; a new pair of verifiers, which must differ |

- **What waits.** A message that moves coins or loosens a rule runs only from an Ethereum block the vault's checkpoint
  covers (VLT-3). A raised cap or floor, a new freezer and new verifiers then wait `GOVERNANCE_DELAY` (7 days) on the
  vault before anyone applies them (`applyChange`), and the freezer may cancel a waiting raise or rotation, never its
  own replacement (VLT-2); a lowered cap applies at once. Only a governance message on both proofs moves its kind's
  nonce mark (VLT-4).
- **Speed limit.** `SPEED_LIMIT` is 4%. A payout counts in its hour's bucket, and the current hour and the 24 before
  it, with the payout, must stay within 4% of the index's balance before them, or the coin's outflow floor if that is
  larger, so outflow in any 24 hours is at most 4% exactly. What the limit holds back stays owed, and `release` pays it
  later; nothing expires. `paidTotal` counts every payout, which can never exceed what the index sent.
- **Freeze.** The freezer, the guardian's freeze address on that chain, can `freeze()` for 14 days, as a `FREEZE`
  message can. A frozen vault takes no deposit and pays nothing; accepted burns stay owed. Nothing freezes a vault
  after its snapshot (VLT-5).
- **Digests.** The vault keeps two 32-byte digests for Ethereum to prove, updated whenever what they cover changes: per
  index, its balances and paid totals (`indexDigest`); per intake, its state and deposit totals (`intakeDigest`).
  `attest(slots, values)` reverts unless the slots hold the values: on TRON, whose blocks commit to no contract
  storage, a successful call of it in a final block is the proof.
- **Stall and snapshot exit.** Anyone advances the vault's checkpoint (`advanceCheckpoint`) to a final Ethereum block
  both P1 and P2 prove. A vault with no new checkpoint for `STALL_PERIOD` (7 days) is stalled and takes no deposit.
  Only then may `RECOVERY_PROPOSER`, the owner's emergency multisig on that chain, propose a successor pair, which must
  prove the last checkpoint, a recent one and the last message delivered on both proofs (LG-3), and waits
  `RECOVERY_DELAY` (30 days) with at most `MAX_RECOVERY_VETOES` (2) vetoes by the freezer in the stall. Only a
  checkpoint that ends the stall lapses the successor and restarts the count; a stale one, which the old pair can still
  prove, leaves both (LG-2). `SNAPSHOT_EXIT_DELAY` (180 days) into a stall,
  `beginSnapshot` takes the last checkpoint as the snapshot for good. Holders then claim their share of each coin
  directly (`claimSnapshot`), at the recovery address they registered on the hub or one they signed for (EIP-712), within the
  speed limit; open intakes are settled or refunded from the hub's settled marks (`resolveIntake`); and a burn or
  migration the hub marked as sent is paid by `deliverRecorded`. The vault reads the hub's storage under the
  snapshot's state root through `STATE_READER` (`EthereumStateReader`), and the claim's reading and signature check
  live in the linked library `VaultSnapshot`, which keeps the vault under EIP-170's size limit.
- **On TRON** the same source runs, built with Tron's compiler (tron-solc 0.8.28) and rehearsed on a local java-tron
  node under mainnet's VM switches and 80 ms CPU limit (`tron/`; Stage B spec, section 5.7).
- **On Solana** the vault is a twin program, `solana/programs/xindex-vault` (Anchor 1.2), with the same messages,
  digests, speed limit, freeze and governance delay, one instruction per message kind, and SOL held by a treasury
  account the program signs for. Its `abi` tests pin every encoding against Solidity's. It keeps checkpoints, stalls,
  recovers and exits as the EVM vault does (SOL-7, closed 2026-10-03), its holders signing their snapshot claim with an
  EIP-712 domain that names the vault's 32-byte id as `salt` and its registry chain id, for a `bytes32` recipient.
  `solana/programs/stub-verifier` trusts a relayer key and serves testnets only; nothing in `src/` or `script/` names
  it.
- **On NEAR** (`near/`) the vault is a near-sdk contract with P1 and P2 compiled in, since NEAR's cross-contract calls
  are asynchronous. It is published once as a global contract by its code hash and runs at a keyless NEP-616 account
  derived from its initial state, so no key and no method can change its code. It keeps yoctoNEAR in 128 bits, a book
  it never checks against its balance, pays only implicit accounts (which a transfer creates), and charges callers the
  storage they create.
- **On Stellar** (`stellar/`) the vault, P1 and P2 are three Soroban contracts with plain Wasm executables and no admin
  or upgrade path; the vault pins both verifiers' code by hash. It holds XLM through the native asset's contract, pays
  only `G…` accounts, extends every entry's TTL as it writes it, and runs within Soroban's 400M-instruction and 132 KB
  limits.
- **Both** prove their state to Ethereum by `attest`, which succeeds only if every slot the hub asks about holds its
  value (`design/2026-10-03-near-stellar-interfaces.md`), and build on `crates/xindex-core`, the vault chains' shared
  Rust: the light client, both Groth16 checks, receipt and state proofs, the message format, digests, speed limit,
  checkpoints and snapshot, over a `Crypto` trait each chain implements on its host functions.

### 10.4 From Ethereum to a vault chain: P1 and P2

A vault asks one interface, `IEthereumEventVerifier`: `verifyEvent(proof)` returns a log and its block number, and
`verifyCheckpoint(proof)` a final execution block's number, timestamp and state root. Two independent systems
implement it over the same statement, so that one broken prover can stop coins but never move them.

- **The statement** (`proofs/finality`, plain Rust tested natively): given the verifier's anchor, a checkpoint is
  finalized by Casper's two links, each signed by two thirds of the stake that the anchor's validator registry shows
  active, plus a margin for the churn since the anchor, which is at most a day old. Validators the registry holds
  queued for activation count in that stake too, never as signers, since Electra activates a whole queue at once
  (LG-6). Every signer counts by its record
  in that registry, proven against the anchor's root. The proof also commits to a root over every execution block
  since the last anchor, so a message in any of them can be proven.
- **`FinalityVerifier`** is what both share on an EVM vault chain: a light client of Ethereum with no owner, which
  anyone advances with `update(publicValues, proof)` from the stored anchor only, and which proves a message by its
  receipt, a Merkle-Patricia proof against the receipts root of a block a proof covered. The first anchor comes from
  the deployer and is checked during the chain's registration delay. `update` refuses a proof once `MAX_LAG` (1 day)
  has passed since the anchor's epoch began, dated from the beacon genesis time fixed at deployment, so a verifier left
  behind stops for good rather than take a past checkpoint from validators who have since exited (LG-4).
- **P1**, `EthereumFinalityVerifier`, checks an SP1 Groth16 proof on one SP1 verifier deployment, never SP1's
  gateway, which has an owner; `PROGRAM_KEY` fixes the program. **P2**, `RiscZeroFinalityVerifier`, checks a RISC Zero
  Groth16 proof of the same statement with the same public values, as `verify(seal, IMAGE_ID,
  sha256(publicValues))` on one RISC Zero verifier deployment, never its router. `script/DeployVault.s.sol` refuses any
  Groth16 verifier but SP1's v6.0.0 and RISC Zero's 3.0.0.
- **On Solana**, `solana/programs/ethereum-verifier` is P1, the same verifier as a program, with the same day's lag. It
  reads RLP in place, so only compute bounds a receipt, at about 19,600 logs (LG-1). P2 is
  `solana/programs/risc0-verifier`, the same core with RISC Zero's check; both answer `verify_checkpoint`.
- **On NEAR and Stellar** both run `crates/xindex-core`'s light client and Groth16 checks over the chain's BN254 host
  functions: inside the NEAR vault, about 37 Tgas for an update of both; as two Soroban contracts, about 31M
  instructions a proof.
- **On Sui** P1 and P2 are shared light-client objects in the vault's Move package (`sui/`), twins of
  `FinalityVerifier` with the same anchor, headers tree, receipt proof and lag, checking SP1's and RISC Zero's proofs on
  `sui::groth16`; about 290 and 320 gas units an update, in the unit-test runner's units. **On Aptos** they are
  light-client objects in the vault's package (`aptos/`), checking both proofs with one BN254 multi-pairing of
  `crypto_algebra`, every point checked on the curve and in its subgroup; about 2,000 gas units an update, estimated.
- **Shared risk.** A bug in either zkVM breaks one system only; a bug in the statement breaks both. That is a known
  limitation (Stage B spec, section 11).
- **Measured.** SP1's Groth16 check costs about 227k gas on an EVM and 96,910 compute units on Solana. P1's statement
  on a real mainnet input runs 36.6 billion prover gas in execute mode. No proof of either system has been generated
  yet, so the cost of a proof and the latency end to end are not measured.

### 10.5 From a vault chain to Ethereum: state verifiers

`IVaultStateVerifier.verifySlots(account, slots, proof)` returns storage slots of an account at a final block of its
chain, with the block's number and time. The registry names one verifier per chain, and the hub reads its vaults'
digests through it, refusing a state from before the deadline or freeze it must follow. Each has no owner and no
upgrade, starts from an anchor its deployer names (`script/DeployStateVerifier.s.sol`), checked during the chain's
registration delay, and proves every later step.

- **`BnbStateVerifier`** checks BNB Chain's own fast-finality votes, BLS12-381 aggregates on the EIP-2537 precompiles
  (`Bls12381`), and Merkle-Patricia storage proofs (`MerklePatricia`, `RlpReader`). BNB Chain rotates part of its
  validator set every 1,000 blocks, so the verifier follows every epoch block, each accepted only with the vote that
  finalized it under the set it replaces. A set names its successor only within `MAX_LAG` (1 day), and a proven block
  must fall within `MAX_SPAN` (15 minutes) of its epoch block and be at most a day old (BNB-2). Measured on mainnet
  data: about 462k gas an epoch at two to a transaction, 89M gas a day, and 820k for a proof of two slots.
- **`TronStateVerifier`** proves a slot by a successful top-level `attest` call to the vault in a block that 19 of the
  27 producers then built on, Tron's own rule for a solidified block. It writes every header and transaction it hashes
  from typed fields, and never parses Tron's protobuf. It follows the producer list every 6 hours, each new list
  learned from signatures and vouched for by 19 producers of the old one. Measured on mainnet blocks: about 568k gas a
  proof, and 1.3M gas a period.
- **Liveness.** A verifier not advanced in time (a day behind on BNB Chain, about 18 hours past a period boundary on
  TRON) stops for good, and the registry replaces it by a 30-day rotation. Mints on that chain wait; burns still pay,
  since they need only Ethereum's proofs.
- **`NearStateVerifier`** advances an anchor (an epoch and its block producers' hash) with an SP1 proof of NEAR's own
  light-client rule (`proofs/near`): every approval an ed25519 signature over the next block, more than two thirds of
  the epoch's producer stake, one epoch at a time, about 7.8M prover gas a hop. It then proves a vault's `attest` by
  its outcome, SHA-256 Merkle paths up to a recorded head's block Merkle root, the outcome's Borsh written from typed
  fields; the record carries the run's own height and time. About 300k gas an update, 40k to 60k a proof.
- **`StellarStateVerifier`** checks one SP1 proof per call (`proofs/stellar`): validators satisfying the pinned Tier 1
  quorum set (7 of 10 organisations, 2 of 3 validators each) externalized a ledger whose header chain reaches the
  ledger of a successful vault `attest`, its event rebuilt from typed fields. About 12M prover gas, 240k gas a call. A
  ledger more than a day old is refused, and a new Tier 1 is a new verifier.
- **`SuiStateVerifier`** checks Sui's committee certificates in Solidity, with no zkVM: BLS12-381 min-sig aggregates
  on EIP-2537 (`Bls12381MinSig`, which checks every length, BLS-1) and Blake2b on EIP-152 (`Blake2b`). It writes every
  byte it hashes or checks a signature over from typed fields (`SuiBcs`), follows each end-of-epoch checkpoint's next
  committee, and proves a vault's `attest` by the immutable `Attestation` object it wrote, a leaf of its checkpoint's
  artifacts tree. Sui's epochs last a day, so its lag is two days from its committee's epoch start. Measured at
  mainnet's 127 members: 1.35M gas an update, 1.16M a proof of two slots.
- **`CometBftStateVerifier`** (Injective) checks one SP1 proof per call (`proofs/cometbft`, on the audited tendermint-rs
  and ics23 crates): light-client hops each signed by more than two thirds of the trusted set's power, never ibc-go's
  third, then ICS-23 proofs of the vault's slots in the `evm` store under the next header's AppHash. About 7M prover gas,
  and 42k to 63k gas besides the Groth16 check.
- **`VeChainStateVerifier`** checks one SP1 proof per call (`proofs/vechain`): VIP-220 finality over stake weights that
  `VeChainStakerAttester` attests on VeChain, each new table vouched for by more than two thirds of the trusted one's
  weight, then the vault's successful `attest` transaction through the block's transactions and receipts tries. About
  34M prover gas.
- **`AptosStateVerifier`** checks one SP1 proof per call (`proofs/aptos`): epoch-change ledger infos signed by more
  than two thirds of the trusted set (BLS12-381 min-pk, `Bls12381`'s ciphersuite), then the vault's transaction in the
  SHA3 accumulator with a success status and its one `Attested` event. The inputs come from Aptos Labs' public database
  backups, every byte checked against signatures, so a state is provable two to four hours after its `attest`. About
  10M to 13M prover gas.
- **Other chains.** Solana's needs a zkVM proof of a slot's account writes and waits on Alpenglow's mainnet launch
  (`design/2026-10-03-solana-state-proof.md`); HyperEVM's headers carry no state root, so nothing there can be proven
  yet (Stage B spec, section 8).

### 10.6 Security model

- **Trust,** beyond section 7's: each vault chain's consensus, bounded by its quantity cap; at least one of P1 and P2
  sound, for coins in vaults to be safe; for mints, each chain's state verifier sound, or one watcher live within the
  24-hour lock; the Groth16 setups of both proof systems; and the owner's emergency multisig on each chain, which can
  only propose a successor during a stall (design section 8.4).
- **Bounds, as built** (design section 8.1 gives the figures for the floor list):
  - one Ethereum-side proof system broken: nothing moves, since coins leave only on both;
  - both broken: forged payouts within 4% of each index's vault balance a day, until `reportOutflow` freezes the
    vault; a raised cap, a new freezer or new verifiers wait 7 days on the vault;
  - a chain's state verifier broken: a forged deposit is contradicted by any honest proof in the 24-hour lock, or
    after it by `reportForgedDeposit`, and shares enter at most 4% of the supply a day; a forged delivery is bounded by
    the band and mostly covered by the 0.1% bond;
  - the owner Safe compromised: vaults are fixed, and a new state verifier or verifier pair waits 30 days in public,
    for the guardian to cancel it or holders to leave;
  - Ethereum's formats breaking: the vault stalls, recovery takes 37 to 97 days, and holders are paid directly from
    the snapshot after 180 days.
- **Known limits.** P1 and P2 share one statement. TRON has no slashing, so 19 colluding producers could forge its
  state at no cost to their stake. A forged delivery found after its bond's hold is bounded only by the band. At a
  snapshot, shares whose holder can neither sign nor register a recovery address, an official pool's among them, are
  unclaimable, since the look-through is not built. The Stage B red team (`audit/2026-09-30-stage-b-red-team.md`), the
  Tron review (`audit/2026-10-01-tron-review.md`) and the Stage B spec list the rest.

### 10.7 Verification

- **Unit tests per contract:** `test/HybridIndexFactory.t.sol`, `test/HybridHub.t.sol`,
  `test/HybridHub.rebalance.t.sol`, `test/HybridHub.migration.t.sol`, `test/HybridHub.exit.t.sol`,
  `test/XindexVault.t.sol`, the verifiers' `test/BnbStateVerifier.t.sol`, `test/TronStateVerifier.t.sol`,
  `test/EthereumFinalityVerifier.t.sol` (one suite, run through P1 and through P2) and
  `test/EthereumStateReader.t.sol`, and the libraries' `test/MerklePatricia.t.sol` and `test/Bls12381.t.sol`.
  `test/HybridTest.sol` runs Stage B on one EVM: a real vault standing for another chain, a state verifier reading its
  storage, and message delivery. The verifiers run on real chain data: BNB Chain's mainnet and testnet, Tron's mainnet
  blocks around a maintenance boundary, and a mainnet block's receipts, each rebuilt by a `generate.py` under
  `test/fixtures/`.
- **Invariant suites.** `test/HybridHub.invariant.t.sol` drives orders, short and whole deposits, settlements,
  claims, failures, voids on forged proofs, freezes and re-confirmations, redemptions, claims on both chains,
  migrations to a next version, supply revisions, fills with their deliveries, failures and slashes, and the clock,
  delivering every message at once. It asserts that both versions' components stay backed, the vault's balance for an
  index is the hub's book plus what the vault still owes, no vault record shows more paid than sent, the settled marks
  follow the claimed orders, the index holds of its own shares exactly a live fill's bond, and the escrow follows the
  orders. `test/XindexVault.invariant.t.sol` holds the vault's V1 to V5, for the native coin and a token alike: the vault
  holds at least what it accounts for, a message pays at most once, a burn pays at most its index's balance, outflow over any 24 hours stays within the
  limit, and each digest is the hash of what it covers.
- **Security regression tests** for the Stage B red team's and the Tron review's ids (VLT, HUB, MOD, BNB, FAC, SOL,
  TRN), named as `AGENTS.md` gate 6 sets out.
- **Outside Foundry,** run locally and not in CI: `proofs/finality` is tested natively against the consensus specs'
  libraries and real mainnet and Sepolia data, and P2 on a real input must commit what P1 commits; the Solana programs
  have LiteSVM tests and unit tests of their encodings. `demo/` is the hackathon's testnet demonstration, a Foundry
  project of its own that is never deployed to a mainnet: one index on stub verifiers, and one on BNB testnet's real
  proofs with P2 still a stub.

## 11. Roadmap

**What remains before launch.** v4 launches as one product on `HybridIndexFactory` once the hybrid index is ready
(the owner's call on 2026-10-01). What remains:
- real proving of P1 and P2: the proving prototype's verification thresholds pass (227k gas on an EVM, 96,910 compute
  units on Solana), and its cost per proof (at most $50) and time end to end (at most 60 minutes) are still open
  (`design/2026-09-30-proving-prototype.md`);
- both Groth16 setups checked against their ceremonies, and P2's image id from a reproducible build (Stage B spec,
  section 11);
- TRON's deployment settings and its deployment script (Stage B spec, section 5.7);
- external audits, a Sepolia rehearsal, and the mainnet deployment through the Safe.

**Stage B, not built.** A Solana state verifier, which waits on Alpenglow's mainnet launch; NEAR's and Stellar's
vault deploy tooling on their chains; a
vault on HyperEVM, until Hyperliquid publishes a state root; a successor's proof of descent, which stall recovery asks
for; look-through for an official pool's LPs at a snapshot; and watchers.

**Stage C.** Avalanche, NEAR, Stellar, Hedera and Cardano were researched on 2026-10-01
(`design/2026-10-01-stage-c-research.md`; Stage B spec, section 8), and none is built. NEAR and Stellar are buildable,
each needing a finality statement and its proof, a state verifier and a vault in the chain's own language. Avalanche
waits on Ava Labs and on the owner's reading of the finality rule, Hedera on its TSS cutover and on the owner accepting
its council, and Cardano fails the rule as written. A chain joins only if its finality is deterministic, its proof
cost is measured, its cap matters and its value pays for its vault, verifiers and audits.

The multichain design, its failure bounds and its parameters are in `design/2026-09-29-v4-hybrid-architecture.md`;
this file restates only what section 10 needs.

**Backlog.** A fee in a later index version, ETH in/out, `createAndMint`, `mintWithTokenPermit` (USDC only),
mixed-venue legs that split one leg across V3 and V4, a permissionless backstop executor and a reminder for the weekly
trigger, an aggregator or Universal Router 2.1 zap, V4 pools on the Sepolia market, and an auction whose exposure
scales with the trade rather than the moving value.

## 12. History

- **v1 and v2** (2026-09-15 and 2026-09-16): the in-kind core and the zap, then on-chain rule rebalancing from Uniswap
  V3 pool averages, with the Numbers model's uncapped and capped methodologies.
- **v3** (2026-09-22): prices from Chainlink USD feeds, execution through the Universal Router; the change and what it
  retired are in `audit/2026-09-22-v3-retirement.md`. v3 is tagged `v3.0.0` and runs on Sepolia; it never launches on
  mainnet.
- **v4 Stage A** (2026-09-29 to 2026-09-30): the hybrid multichain design, revised after an external review, and
  Stage A's price-free contracts. Why prices left the contracts is in design sections 6.6 and 13; what that retired is
  in `audit/2026-09-30-v4-stage-a-retirement.md`.
- **v4 Stage B** (2026-09-30 to 2026-10-01): the EVM vault, `HybridIndexFactory` and `HybridHub` with its module and
  extension, the BNB Chain and TRON state verifiers, P1 on SP1 and P2 on RISC Zero, and the Solana vault with P1 there.
  On 2026-10-01 the owner decided that v4 launches as one product, on `HybridIndexFactory`.
