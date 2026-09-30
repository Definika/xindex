# Xindex v4 Stage A: contract specification

Status: **the build spec for Stage A, 2026-09-30.** It turns sections 4.1, 4.2, 4.5, 4.6 and 6.6 of
`design/2026-09-29-v4-hybrid-architecture.md` into contracts, for an index held entirely on Ethereum. Stage B adds
vaults, proofs and the mirror to the same hub. Everything here is price-free: no contract reads a price, a feed or a
pool. AGENTS.md's definition of done applies to every change.

**Waiting for the owner:** the fee model (section 7; until chosen, no fee), WBT's listing (section 8), and this spec
itself, which the build follows on the local branch `v4-stage-a` in the meantime.

## 1. What changes from v3

| v3 | Stage A |
|---|---|
| `IndexToken` | `IndexHub` (renamed; Stage B extends it) |
| `IndexRule`, `CompositeFeed`, `IAggregatorV3`, `IIndexRule`, `Methodology` | Deleted: no prices, uncapped only |
| Token config `{feed, maxStaleness, referenceSupply}` + recorded decimals | A reference supply per token, nothing else |
| `proposeConfig` per token | Weekly supply **batches**, atomic, one live at a time |
| `MAX_SUPPLY_CHANGE` = 10× | `MAX_SUPPLY_STEP` = 0.5% per update, and the hub clamps 0.5% per rebalance |
| `createIndex(name, symbol, tokens, units, methodology)` | `createIndex(name, symbol, tokens, k)`: units from supplies |
| `MAX_COMPONENTS` 20, masks uint24 | 100, masks uint256 |
| Rule targets + multiplier auction 1.5 → 0.9 + feed-valued settlement gate | The λ band auction (section 3) |
| `MIN_TURNOVER` and the shortfall start rule | `MIN_BAND` |
| `MIN_REBALANCE_INTERVAL` 28 days | 7 days |
| — | `MintRequests` (section 5) |

## 2. IndexFactory

Constants: `MAX_COMPONENTS = 100`, `LISTING_DELAY = 2 days`, `GUARDIAN_DELAY = 7 days`, `PROPOSAL_WINDOW = 7 days`,
`MAX_SUPPLY_STEP = 0.005e18`, `MAX_SUPPLY = type(uint128).max`, `MIN_RAW_UNITS = 10_000`,
`MAX_UNITS = type(uint96).max >> 10`, `K_SCALE = 1e36`.

**Reference supplies.** `referenceSupply(token)` is the supply in force, in the token's raw units: the supply of what
the token represents (Bitcoin's for WBTC, ether's for WETH). Zero means never listed. It stays after delisting, because
existing indexes still rebalance with it. `referenceSupplies(tokens)` returns several at once and reads storage only: no
call reaches a token.

**Listing.** `proposeListing(token, supply)`, owner only: the token must have code; `supply` must be non-zero and at most
`MAX_SUPPLY`; a token already carrying a supply (a relist) must propose a supply within one step of it; no listing may
be live for the token, and the token may not be in the live supply batch. Executable by anyone from `eta` for
`PROPOSAL_WINDOW` (`executeListing`), which sets the supply and whitelists the token. `cancelListing` by owner or
guardian. `delist` by owner or guardian, immediate, dropping a pending listing.

**Supply batches.** `proposeSupplies(tokens, supplies)`, owner only:
- `tokens` strictly ascending (so no duplicate), 1 to `MAX_BATCH` = 256 entries, each already carrying a supply, none
  with a live listing proposal;
- each new supply non-zero, at most `MAX_SUPPLY`, and within `MAX_SUPPLY_STEP` of the supply in force:
  `|new − old| ≤ ⌊old × MAX_SUPPLY_STEP / 1e18⌋`;
- no other batch live (an expired one is replaced);
- executable from `eta = now + LISTING_DELAY` for `PROPOSAL_WINDOW` by anyone (`executeSupplies`), all or nothing;
  `cancelSupplies` by owner or guardian.

Atomic because a stranger who could execute half a batch and start a rebalance on the half would turn a uniform
revision into a trade. Both bounds are needed: the factory step stops a slip at proposal time; the hub clamp (3.2)
bounds each rebalance however many batches landed in between.

**Creation.** `createIndex(name, symbol, tokens, k)`, permissionless:
- 1 to `MAX_COMPONENTS` whitelisted tokens, no duplicates;
- `units_i = ⌊k × referenceSupply_i / K_SCALE⌋`, each in `[MIN_RAW_UNITS, MAX_UNITS]`, else `UnitsOutOfRange`;
- CREATE2 salt over `(creator, name, symbol, tokens, units)`: the **computed units**, so the address commits to the
  basket; a batch executed between prediction and creation changes the address, never the basket at an address.
- `previewUnits(tokens, k)` and `predictIndexAddress(creator, name, symbol, tokens, k)` read the supplies in force.

`MAX_UNITS` leaves headroom for units to grow about 1.01× per rebalance for about 690 full-band rebalances.

**Unchanged from v3:** the guardian flow, `renounceOwnership` disabled, the registry (`isIndex`, `creatorOf`,
`allIndexes`), `Ownable2Step`, the `nonReentrant` on creation.

## 3. IndexHub

### 3.1 Issue, redeem, claims (as v3)

`issue` rounds up and rejects fee-on-transfer; `redeem` and `redeemSkipping` round down, claims booked to `to`
(DA-17); `claim` pays a claim; `_update` refuses the index itself and the factory as recipients (CR-I01, RT-21);
`onlyInitialized` on everything that mints, burns or rebalances; one reentrancy guard. Every `supply × units` product
goes through one private helper, `_backing(supply, units, rounding)`, so a fee model lands in one place.

Invariant, for every component `i`: `balanceOf(hub, token_i) ≥ ⌊S × u_i / 1e18⌋ + totalClaims[token_i]`.

### 3.2 The λ band auction

Constants: `MIN_REBALANCE_INTERVAL = 7 days`, `REBALANCE_DELAY = 2 days`, `AUCTION_DURATION = 24 hours`,
`MAX_SUPPLY_STEP = 0.005e18`, `MIN_BAND = 0.001e18`.

**Start** (`startRebalance(keepMask)`), with v3's gates: `MIN_REBALANCE_INTERVAL` since the last settlement, no live
auction, a keep mask that fits and does not keep every component, and strangers only with an empty mask and after
`_permissionlessAt` (CR-I02, VR-04, R16). Then, over the moving set `M` (components not kept):

```
f_i  = factory.referenceSupplies(tokens)            (kept components are not read)
a    = first index in M
R_i  = mulDiv(u_i · f_a, WAD, f_i · u_a)            R_i / R_j = ρ_i / ρ_j, ρ = u/f
c    = (min R + max R) / 2
r_i  = clamp( mulDiv(R_i, WAD, c),  WAD − STEP,  WAD + STEP )      stored as uint64
λmax = max r,  λmin = min r
```

Refused with `BandTooNarrow(λmin, λmax)` when `λmax · WAD < λmin · (WAD + MIN_BAND)`: no supply changed, a uniform
change, or a single moving component. Storage: `{eta, λmax, λmin}`, the keep mask, the ratios.

**Price.** `λ(t) = λmax − ⌊(λmax − λmin) · (t − eta) / AUCTION_DURATION⌋`, from `eta = start + REBALANCE_DELAY` to
`eta + AUCTION_DURATION`: it rounds up, towards the holders.

**Settle** (`executeRebalance(data)` and `executeRebalance(data, maxAmountsIn)`), as v3's `_settle` without the feed
gate: for each moving `i`, `u'_i = ⌈λ · u_i / r_i⌉`; kept components keep `u_i`. A component whose `u'` is below `u` is
sold: `out_i = ⌊S·u_i/1e18⌋ − ⌊S·u'_i/1e18⌋`; one above is bought: `in_i = ⌊S·u'_i/1e18⌋ − ⌊S·u_i/1e18⌋`. If no `out_i`
is non-zero at `λ(t)`, the settlement is computed at `λmax` instead, so units never depend on timing when nothing is
paid for (R14, XA-27). State is written before any transfer; the executor gets `out`, is called back, and
`_checkBacking` requires the invariant with the new units and the whole of `in` on top of what the index held.

**Why no price is needed.** At any prices the value-neutral `λ* = Σ u_i p_i / Σ (u_i/r_i) p_i` is a weighted average of
the stored `r_i`, so `λmin ≤ λ* ≤ λmax`, and a fill at `λ` leaves holders `λ/λ* ≥ λmin/λmax ≥ (1−STEP)/(1+STEP)` of the
moving value: at most 0.995% to a lone executor at the floor. Rounding units up only adds to it.

**Why anchored and centred.** Unclamped, `u_i/r_i` is `f_i` times a constant, so a full fill makes units proportional
to supplies again: keep-mask skew, clamp residue and rounding drift heal at the next rebalance. The clamp is centred, so
a wide band narrows to exactly `[1 − STEP, 1 + STEP]` and never collapses.

**Units per rebalance:** `u'/u ∈ [λmin/λmax, λmax/λmin] ⊂ [0.990, 1.0101]`, plus one raw unit of rounding;
`SafeCast.toUint96` bounds them.

**Views:** `previewBand(keepMask)` returns `(ratios, λmin, λmax)` without reverting on a narrow band;
`pendingRebalance()` returns `(eta, keepMask, λmin, λmax, ratios)`; `currentLambda()` (0 outside an auction);
`previewRebalance()` returns `(λ, units, amountsOut, amountsIn)`; `canStartRebalance()` as v3 (DA-22).

**Events:** `RebalanceStarted(proposalId, nonce, caller, keepMask, λmin, λmax, ratios, eta)`;
`Rebalanced(proposalId, nonce, executor, λ, units, amountsOut, amountsIn)`; `RebalanceCancelled` as v3.

### 3.3 What the guardian keeps

`cancelRebalance`, a keep-mask start, starting before strangers after a cancel or an expiry: as v3. The stall a hostile
guardian can cause (DA-12, RT-07) is now bounded in weeks: its replacement takes `GUARDIAN_DELAY` (7 days), and a
keep-mask fill restarts only the 7-day interval.

## 4. IndexZap

v3's zap, with `IIndexHub` for `IIndexToken` and the recipient blocklist of `FACTORY` without `RULE`. The app stops
offering it above about 35 components (EIP-7825: 16.78M gas per transaction at 265k–430k per token).

## 5. MintRequests

No owner, no upgrade, `nonReentrant` on every entry point, immutable `FACTORY`, `USDC`, `USDT`; nothing reads a price.

| Function | Who | Effect |
|---|---|---|
| `requestMint(index, stable, amount, minShares, deadline)` | anyone | Escrows `stable` (USDC or USDT) for at least `minShares` shares of `index` |
| `requestRedeem(index, shares, stable, minOut, deadline)` | anyone | Escrows `shares` for at least `minOut` of `stable` |
| `fill(id, amount)` | anyone | Mint: sends `amount ≥ minShares` shares to the requester, takes the escrowed stable. Redeem: sends `amount` of the stable to the requester, which must receive at least `minOut` (measured), takes the escrowed shares |
| `cancel(id)` | the requester | Closes an open request and returns the escrow |
| `refund(id)` | anyone, after the deadline | Returns the escrow to the requester |

- `index` must be a factory index; `deadline` in `(now, now + MAX_REQUEST_DURATION]`, 30 days; amounts and limits
  non-zero.
- Escrow is the measured balance increase, so a USDT fee cannot make the last refund revert; every payout uses
  `SafeERC20` (USDT returns nothing); the contract never calls `approve`.
- A request is closed before any token moves.
- Known: a fill pays exactly the requester's limit, so any surplus goes to the fastest filler, which is why the app
  suggests limits; if USDC or USDT freezes a requester, their refund waits on the issuer.

## 6. Scripts

`Deploy` deploys the factory (which deploys the hub implementation), the zap and `MintRequests`, with v3's owner and
guardian checks. `ConfigureWhitelist` proposes and executes listings from `token:supply` entries and, in a `SUPPLIES`
mode, the weekly batch (sorted, each within the step, entries beyond it skipped and logged), both also as Safe calldata.
`MainnetAddresses` keeps WBTC, WETH, LINK and UNI (WBT after its check), USDC, USDT, the Universal Router and the
PoolManager, with dated reference supplies.

## 7. Fees: the owner's decision

Until chosen, Stage A has no fee. Where each model lands:
- **Minter fee in shares:** `issue` pulls the basket for `shares + fee` and mints `fee` to an immutable `TREASURY`;
  redeem takes `fee` shares from the redeemer to the treasury before paying out. Only `_backing`'s callers change.
- **Management fee:** a WAD unit scale applied inside `_backing` that shrinks over time; the released backing is paid
  to the treasury. Touches every money path.
- **No fee:** nothing changes.

## 8. Stage A whitelist

WBTC, WETH, LINK, UNI, with reference supplies dated and sourced in `script/MainnetAddresses.sol`. WBT (WhiteBIT's
token) is on the floor list but waits for the owner after a check of its admin powers, its float (the issuer holds much
of it, so the reference must be the circulating supply) and its Ethereum depth. LEO fails the liquidity screen. wstETH,
wSOL and AAVE leave the v3 list: wstETH duplicates ETH, native SOL comes with Stage B, AAVE is below the floor.

## 9. Retirement

Mechanisms that go take their regression tests with them, recorded in `audit/2026-09-30-v4-stage-a-retirement.md` in
the format of `audit/2026-09-22-v3-retirement.md`: RETIRED ids never come back; RE-TARGETED ids keep a test against the
new mechanism; a retired id's test is never restored. At the end, the ids tested at `v3.0.0` minus the ids tested at
HEAD must equal the RETIRED set.
