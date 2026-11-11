# Xindex Architecture

Xindex turns a portfolio of tokens into a single ERC-20 index token. A wallet the factory's owner approved creates an
index and chooses each coin's percentage, anyone can mint it with USDC or USDT, and anyone can burn it back into USDC,
USDT or any other token with Uniswap V3 or V4 liquidity. Every index is fully backed, in kind, by the tokens it holds.
Its constituents and its creator's percentages never change; it rebalances back toward them through a permissionless
auction in which the executor names the units each coin is to have and the index checks a gain in units. No contract
reads a price, a feed or an oracle, for any of it. The one place a price enters is a quote the owner or guardian may
post with a start: their own figures, used only to refuse a fill (section 3.9). No admin can touch user funds, and no
protocol key or bot is involved in rebalancing.

**Xindex is one deployment, on Ethereum, and one index holds up to 100 coins of the top 300** (the owner's decision of
2026-10-10, `design/2026-10-10-one-index-wormhole-legs.md`). An index holds Ethereum ERC-20s in kind: the issuer's own
contract where Ethereum has one, and otherwise the copy Wormhole's token bridge wraps from the chain that has it.
Nothing crosses a chain inside a protocol contract: the app and the fillers bridge, the keeper's own executor among
them (section 5). There is no vault, no proof and no bridge of ours. The BNB Chain deployment of 2026-10-07 was shelved
on 2026-10-10 and deleted on 2026-10-13.

This file describes the contracts **as built**: `WeightedIndexFactory`, the `WeightedHub` it clones, `WeightedMath`,
`IndexZap`, `BasketBuilder` and `MintRequests`. The rebalance is the oracle-free one of 2026-11-10
(`design/2026-11-10-oracle-free-rebalance.md`, the "spec"), which replaced the Pyth-priced settlement of v5;
`audit/2026-11-10-oracle-retirement.md` records what went with it. The rest of v5 stands
(`design/2026-10-05-custom-weights.md`, the "v5 spec", whose sections on Pyth describe the design that was replaced).
`WeightedHub` keeps the issue, redeem, claims, recipient checks and backing post-check of v4 Stage A
(`design/2026-09-30-v4-stage-a-spec.md`); v4's market-cap hub and factory, Stage B's vaults and proofs, and v5's oracle
are history (section 11). Internal reviews of v5: `audit/2026-10-05-v5-review.md` and
`audit/2026-10-07-v5-logic-review.md`. The oracle-free mechanism has not yet been red-teamed by reviewers who did not
design it. Nothing has had an external audit, and nothing is deployed on a mainnet.

## 1. Goals and constraints

| Requirement (from the product brief) | How the contracts meet it |
|---|---|
| Create a portfolio as one ERC-20, any name/symbol | `WeightedIndexFactory.createIndex(name, symbol, components, params)` deploys a `WeightedHub` clone with free-form name and symbol; only a wallet the factory's owner approved creates one (`setApprovedCreator`) |
| Choose each coin's percentage | Each component carries a weight in basis points, the weights summing to 10,000, fixed at creation with the coin list |
| Others can mint the same index | `issue`, `mintWithToken` and `requestMint` are permissionless |
| Decentralized | No custody, no pause, no upgrade, no rebalancing key; listings take effect after a public 2-day delay with a guardian veto, guardian changes after 7 days |
| Mint and burn | In-kind `issue` / `redeem` on the hub; USDC/USDT through the zap, or at a limit through `MintRequests` |
| Trade the index into other coins | Standard ERC-20 (transferable, listable) plus `burnToToken` into any token |
| USDC/USDT in, USDC/USDT out | The zap mints from either stable; the burner chooses the payout token |
| Rebalancing and index price | The units are brought back toward the weights through an auction, at most once per the index's interval (7 to 91 days): an executor names the units, and the index accepts them when a weighted gain in units clears a bar that falls with time (section 3). The owner or guardian may post a quote with a start, which can only refuse a fill. No contract reads a price of its own; the index price is the basket's value, computed off chain |
| Layer-1 coins | Ethereum tokens, Bitcoin as WBTC, and the coins Ethereum lacks as Wormhole-wrapped copies: SOL, XRP, ADA, AVAX and others |

Constraints kept from v3 and v4: in-kind backing, CREATE2 addresses that commit to their contents, fixed constituents,
reentrancy-guarded untrusted executors, standard ERC-20s only, no admin over funds, and an owner Safe of at least three
signatures. Added on 2026-10-14 (`design/2026-10-14-mainnet-engine-research.md`): fees in shares, a rebalance interval
per index and gated indexes, each described below; on 2026-10-16 the streaming fee, as a unit scale. Changed by the owner's calls of 2026-10-05: creators choose
fixed percentages, and the market-cap index is retired. Changed by the owner's call of 2026-11-10: no oracle. Pyth,
which v5's settlement read, is gone from the protocol.

## 2. Components

```
               createIndex(name, symbol, components, params)
   creator ────────────────────────────────► WeightedIndexFactory ──CREATE2 clone──► WeightedHub (ERC-20)
                                              │ listings: a token and its            │ holds the basket
                                              │ decimals (2-day delay)               │ issue / redeem in kind
                                              │ guardian, registry                   │ redeemSkipping / claim
                                                                                     │
   anyone ── startRebalance(keepMask) ─────────────────────────────────────────────► │ 2 h notice, 4 h auction
   executor ── executeRebalance(newUnits, data) ───────────────────────────────────► │ gain ≥ bar(t) ─► WeightedMath
            ◄── amountsOut, then the onXindexRebalance callback ──────────────────── │ backing check

   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ──► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── minter (holds or issues shares)
             ◄─ shares, at least minShares ─────  (escrow)    ── the USDC ──►
```

### WeightedHub (`src/WeightedHub.sol`)

The index itself: an EIP-1167 clone of one implementation, which the factory deploys in its constructor, using
OpenZeppelin's upgradeable ERC20 and ERC20Permit (clones skip constructors, so name and symbol are set in
`initialize`). `FACTORY` and `MATH` are immutables of the implementation, so every clone sees them; `MATH` is the
`WeightedMath` the factory deployed with it.

- **State:** `Component[] {address token; uint96 units}` and beside it each component's weight in basis points
  (`uint16[]`), both set at `initialize`. Only `executeRebalance` changes units, and nothing changes the weights.
  `units_i` is the recorded amount of component `i` (in that token's own decimals) per whole index token (`1e18`
  shares); times `_scale / 1e18` it is the raw amount backing one whole index token. `_scale` is the streaming fee's
  factor (1e18 = one, lowered by each accrual and by nothing else; no fill resets it, XS-2), beside which `_lastAccrual`
  is the fee's clock (`lastAccrual()`), restarted by every accrual, one that mints nothing included (XS-1), and
  `_maskedFill`, whether the last fill had a keep mask (XS-3). Open claims live in `claimOf[account][token]`, their sum
  per token in `totalClaims[token]`. A pending rebalance is its `eta` and keep mask, and, when its start posted one, a
  quote: a price per component (`uint128`), a tolerance and the proposal it belongs to; beside them `proposalCount`,
  `rebalanceNonce`, `lastRebalance` (creation, then each fill) and `restartAllowedAt`.
- **initialize(name, symbol, components, config):** `FACTORY` only, once. 2 to 100 components, each with a non-zero token,
  non-zero units within `uint96` and a weight from 1 to `TOTAL_WEIGHT`; the weights sum to `TOTAL_WEIGHT` (10,000),
  and no two components share a token. Anything else is `InvalidComponents`. Fee rates, a referral share or an
  interval outside the hub's own outer bounds are `InvalidConfig`; the factory bounds each more tightly.
- **issue(shares, to):** computes `ceil(shares × units_i × scale / 1e36)` per component, mints, emits, then pulls each
  component from `msg.sender` and reverts `TransferAmountMismatch` unless the balance grew by at least that amount
  (rejects fee-on-transfer tokens). **redeem(shares, to):** computes `floor(shares × units_i × scale / 1e36)`, burns, emits,
  then pushes every component. Neither reads a price.
- **redeemSkipping(shares, to, skipMask):** the same, except each component whose bit is set stays in the index and is
  booked as a claim for `to`, the account that receives every other component (DA-17), before any token moves.
  **claim(token, to)** pays `msg.sender`'s claim on `token` and clears it.
- **startRebalance(keepMask)**, **startRebalance(keepMask, prices, tolerance)**, **cancelRebalance()** and the two
  **executeRebalance** overloads: section 3.
- **Views:** `components()`, `componentTokens()`, `componentCount()`, `componentWeights()`, `recordedUnits()` (the units
  a fill's `newUnits` are compared with, without the scale), `config()`, `previewIssue`, `previewRedeem`, `claimOf`,
  `totalClaims`, `pendingStreamingFee()`, `lastAccrual()`, `earliestRebalance()`, `pendingRebalance()`, `currentBar()`,
  `rebalanceQuote()` (the pending proposal's prices and tolerance, empty and zero when it has none),
  `canStartRebalance()`, and `previewRebalance(newUnits)`, which returns the bar, the gain and the amounts a fill of
  those units in this block would settle, and reverts as the fill would. No function values the index. The only
  prices any function takes or returns are a quote's, the owner's or guardian's own (section 3.9).
- **Access:** `issue`, `redeem`, `redeemSkipping`, both `startRebalance` overloads, `cancelRebalance` and both
  `executeRebalance` overloads revert `NotInitialized` on anything but an initialized clone; the implementation has
  initializers disabled. A recipient can never be zero, the hub itself or its factory, and that includes a plain ERC-20
  `transfer` or `transferFrom` of shares, since neither could ever move a share on (CR-I01, RT-21). These and `claim`
  share the storage-based `ReentrancyGuard`, whose zeroed slot reads as "not entered" in a clone; the ERC-20 entry
  points are deliberately unguarded.
- **Ether:** none of the hub's entry points is payable, both starts and both fills included
  (`test_noRebalanceEntryPointTakesEther`, `test_aQuotedStartTakesNoEther`): nobody is paid for a price, and the hub
  never holds ether.

### WeightedIndexFactory (`src/WeightedIndexFactory.sol`)

- The constructor takes the owner and the guardian (zero means none) and deploys `WeightedMath` and, with the math's
  address fixed in it, the `WeightedHub` implementation. The factory stores no price and reads none, and it depends on
  no Uniswap contract.
- **Listing.** `proposeListing(token)`, owner only: the token must have code (`NotAContract`), its decimals are read
  now and must be at most 18 (`InvalidDecimals`), and the token must be neither listed (`AlreadyListed`) nor under a
  live listing (`ListingPending`). A listing is a token and its decimals and nothing else: no listing carries a price
  id. The decimals only bound the units an index may start with (`maxUnitsOf`); they are read once, so the figure is
  public before it counts, and the factory calls no token after that (RT-01). `executeListing` is permissionless from
  `eta = now + LISTING_DELAY` (2 days) for `PROPOSAL_WINDOW` (7 days); it records the decimals (`TokenDecimalsSet`) and
  whitelists the token. `cancelListing` and `delist` are owner or guardian; delisting is immediate, keeps the token's
  decimals, and affects only indexes created afterwards. A relisting reads the decimals anew and reaches only indexes
  created after it (`test_aRelistingReachesOnlyNewIndexes`).
- **Creation.** `createIndex(name, symbol, components, params)`, open only to a wallet the owner approved
  (`CreatorNotApproved` otherwise) and payable for the policy's creation fee, with `params` the creator's fee rate, the
  highest platform fee it accepts, the rebalance interval (7 to 91 days), the gate and the listing flag; each component
  a `ComponentSpec {token, weight, units}`: a non-empty name and symbol, 2 to 100 whitelisted components, units in
  `[MIN_RAW_UNITS, maxUnitsOf(token)]` (`UnitsOutOfRange`), weights of at least one basis point summing to exactly
  10,000 (`InvalidWeights`) and no token twice (`DuplicateToken`). The floor, 10,000 raw units, is DA-09's granularity
  rule. The ceiling is `MAX_WHOLE_TOKENS` (1e9) whole tokens per index token at the token's listed decimals, so a
  wei-share backs a negligible amount (RX-5), and never above `MAX_UNITS`, `(2^96 − 1) >> 10`, which leaves a 2^10
  margin below `uint96` for units to grow (V5-L3). The clone is deployed with CREATE2 from a salt over the creator, the
  name, the symbol, every component's token, units and weight, and the config: fee and streaming rates, referral share
  and rebalance interval (LR-05); the gate and the listing flag are not in it. The clone is registered (`isIndex`,
  `creatorOf`, `allIndexes`), announced (`IndexCreated`) and initialized in one transaction; `predictIndexAddress` gives
  the address first. No unit is checked against a price: the app derives the units from the percentages at its own
  prices, and rebalances, the first possible after the index's own interval (7 to 91 days), close any gap within the
  caps, paying it to whoever fills them: hence the approval below.
- **Approved creators.** `setApprovedCreator(account, approved)`, owner only, takes effect at once and emits
  `CreatorApprovalSet`; `isApprovedCreator(account)` reads it. Neither the owner nor the guardian is approved by being
  a role (`test_onlyAnApprovedCreatorCreatesAnIndex`, `test_onlyTheOwnerApprovesCreators`). The reason is that nothing
  reads a price: no contract can compare the units a creator names with its weights, and an index created off its
  weights carries that distance from its first day and loses it to whoever fills its auctions (section 3.7). The
  approval is what keeps a stranger from creating such an index; the team creates on the weights at the app's prices.
  It is read at creation and nowhere else: an approved wallet is bound by the whitelist and the fee caps, it has no
  power over any index's funds, and withdrawing an approval reaches no index that exists
  (`test_aWithdrawnApprovalStopsCreationAndReachesNoIndex`). An index's creator role still moves to any account,
  approved or not, through `transferCreator` and `acceptCreator`, which is how a partner takes over an index the team
  made (`test_theCreatorRoleMovesToAnAccountThatWasNeverApproved`).
- **Guardian and ownership.** `proposeGuardian` is owner only (zero removes the role) and replaces any pending change;
  `executeGuardianChange` is permissionless from `GUARDIAN_DELAY` (7 days) for `PROPOSAL_WINDOW`. The owner can cancel
  any guardian change, the guardian only its own removal, never its replacement (XA-61). `isOwnerOrGuardian(account)`
  tells hubs who may cancel a rebalance, pass a keep mask or start before strangers. The guardian `DeployWeighted`
  installs is the guardian's Safe itself: every guardian call, a start with a keep mask included, is a plain call a
  Safe can send. Ownership moves in OpenZeppelin's
  two steps and takes effect the moment the new owner accepts: the one admin change with no delay and no guardian veto.
  `renounceOwnership` always reverts. An expired proposal leaves `listingEta`, `pendingGuardian` and
  `pendingGuardianEta` set, so `listingPending(token)` and `guardianChangePending()` say whether one can still run
  (DA-16).
- Neither role can pause, upgrade, set units or weights, or touch funds held by any index.

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
  its own limit too (DA-15). `burnToTokenWithPermit(BurnParams, v, r, s)` runs the same checks before the permit, and
  `mintWithTokenPermit(MintParams, v, r, s)` does the same for a `tokenIn` with an EIP-2612 permit, USDC among them;
  a permit is tried, never required, so one already submitted is accepted. `mintWithEth(MintParams)`,
  `burnToEth(BurnParams)` and `burnToEthWithPermit` (built 2026-10-29) are the same calls with WETH as the token: the
  zap wraps `msg.value`, which must equal `maxAmountIn`, refunds the unspent part as ether, and unwraps a burn's
  proceeds for `to`. `WETH` is a construction argument, resolved by the deploy script like the stablecoins.
- **One venue per leg.** A `MintLeg` or `BurnLeg` carries exactly one non-empty route, a packed `v3Path` or a
  `PathKey[] v4Path`, or `BadRoute(i)`; both empty is valid only for the pass-through leg. A V4 route must be hookless (`hooks` zero and
  `hookData` empty), which also rules out the dynamic-fee flag. `address(0)` is native ether and may appear only as an
  intermediate; the zap's `receive()` takes ether from WETH alone, which `withdraw` sends back, and refuses every
  other sender.
- **Every command is the zap's own.** Each swap is one `execute(commands, inputs)` built here, and nothing a caller
  supplied is forwarded, because the router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`. The commands
  and V4 actions are declared with their input layouts in `src/libraries/`. The zap never encodes a swap amount of
  zero, which the pinned V4 router reads as "the full debt" (CR-I05).
- **Pre-fund and sweep, not Permit2.** The zap sends the router what a leg may spend and appends `SWEEP` back to itself
  in the same `execute`, so no allowance survives a call. The pre-fund is the operative bound on a leg's spend, because
  the pinned V4 router does not hold an exact-output route that revisits `tokenIn` to its `amountInMaximum` (upstream
  v4-periphery #564; CR-I06, CR-I14). After a mint leg, `ShortFill` checks the component balance gained against what
  the index needs, since the pinned V4 periphery does not check exact-output delivery.
- **Burn legs.** A V3 leg is swapped one hop at a time, each hop's unsold input going to the recipient; a V4 leg is one
  action, where an intermediate partial fill reverts the leg (CR-I07). What a hop returns is measured as what its sweep
  brought back, a stray router balance included, so a stray can never revert a burn (CR-L02).
  Each leg sells what the redeem delivered, measured as the zap's balance change rather than read off `previewRedeem`,
  so a component paying less than it was sent is sold as it arrived and the zap's own tokens never are (A1a-05).
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
  buy completes a basket a rebalance changed. A gated index issues only to its creator or a `to` its creator allows.
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
fills requests at their limits (`fillMint`, `fillRedeem`, and several at once with `fillBatch`, which passes a
seller's shares to a buyer and trades one basket for the difference), and anyone else may.

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

## 3. Rebalancing without a price

An index holds amounts of coins, and a weight is a share of value, so bringing the units back to the weights takes
someone who knows what the coins are worth. That someone is the executor, never the index: the executor names the units
each component is to have, and the index judges them on units alone. No contract reads a price, a feed, a pool's price
or an oracle, for a rebalance or for anything else (`test_V5I4_noContractNamesPyth`, `test_A713_noContractReadsAPrice`),
so no feed can block an exit, misprice a mint or set the terms of a rebalance. The one place a price enters is a quote
the owner or guardian may post with a start: their own figures, fixed at the start, and used only to refuse a fill the
rule accepts (section 3.9). The spec is `design/2026-11-10-oracle-free-rebalance.md`. Until 2026-11-10 the settlement
was priced by Pyth (section 11).

Notation: `u_i` a component's recorded units, `v_i` the units the executor names for it, `w_i` its weight (basis points
on chain, summing to 10,000), `σ` the index's scale after the settlement's own accrual (1e18 = one),
`S = totalSupply()` in the settling block, and `e` the seconds since the auction opened. A leg's change `x`, its score
`L`, the gain, the bar, `MAX_TURNOVER` and `MAX_GROWTH` are fractions held to 18 decimals (`W = 1e18`). `⌊ ⌋` rounds
toward minus infinity and `⌈ ⌉` up.

### 3.1 Start, notice and auction

`startRebalance(keepMask)` is open to anyone once the index's own rebalance interval, 7 to 91 days chosen at creation,
has passed since the last fill or the creation (`RebalanceTooSoon`, `earliestRebalance()`), while no proposal is pending
or in its auction (`RebalancePending`). A non-zero keep mask, and any start before strangers may, needs the factory
owner or guardian (`Unauthorized`, R16). The mask must fit the components and leave at least two moving
(`InvalidKeepMask`, V5-L2), since one moving component alone has nothing to trade against. After a fill with a keep
mask, a start without one waits only `MIN_REBALANCE_INTERVAL`, so a sliver the guardian fills cannot hold everyone else
off for a quarter; a start with a mask may start then too, so the guardian can renew a keep around a frozen component
(XS-3). The start stores `eta = now + REBALANCE_DELAY` and the mask, and emits `RebalanceStarted`. It is a plain call:
it takes no ether and no data, reads no price and calls nothing on any component.

`startRebalance(keepMask, prices, tolerance)` is the same start with a quote posted, for the owner or guardian only,
under the same clock and keep-mask rules (section 3.9). The plain start is unchanged by it.

`REBALANCE_DELAY` is 2 hours. The notice is for executors to prepare, not for holders' exits: the units a fill settles
at are named at the fill, so nothing a holder would leave over is fixed at the start. The auction runs from `eta` to
`eta + AUCTION_DURATION` (4 hours), the twenty halvings of its bar (section 3.5). Nothing on chain waits for a market to
be open: an executor that cannot value a coin leaves it alone, naming its units unchanged, and trades the rest.

`cancelRebalance()`, owner or guardian, clears a pending proposal. Cancelling during the notice or the auction holds
strangers off for `REBALANCE_DELAY` from the cancel (`restartAllowedAt`, R15); cancelling one that already expired only
clears it, and the hold-off the expiry granted stands (VR-04). An auction that expires unfilled holds strangers off
until `eta + AUCTION_DURATION + REBALANCE_DELAY`, so the owner and guardian get the first restart (XA-02, XA-16,
CR-I02). `canStartRebalance()` is the whole timing condition for a stranger, false on an uninitialized clone (DA-22).
The eight states this makes (uninitialized, interval, cooldown, open, notice, auction, expired and held, expired and
open), every action from each and the exact second of every transition are tabulated in
`design/2026-10-29-rebalance-state-machine.md`, and `test/WeightedHub.states.t.sol` takes every cell.

### 3.2 The rule

`executeRebalance(newUnits, data)` settles the pending rebalance at the units its caller names, one entry per component
in component order. They are recorded units: like the ones they replace (`recordedUnits()`), they carry the index's
scale. The arithmetic is `WeightedMath.settlement`, which the hub reaches by STATICCALL; it is pure, and no price
enters it. A fill is accepted when every leg is inside its unit caps (section 3.4) and its weighted gain clears the
auction's bar (section 3.5):

```
x_i  = ⌊(v_i − u_i) · W / u_i⌋                                    a leg's relative change in units
L(x) = ⌊(30·x·W³ − 15·x²·W² + 10·x³·W − 9·x⁴) / (30·W³)⌋          x − x²/2 + x³/3 − 3x⁴/10, divided once
gain = ⌊Σ w_i · L(x_i) / 10,000⌋ ≥ bar(e)                         or GainBelowBar(gain, bar)
```

A leg left alone has `x = 0` and scores nothing. So a fill that changes nothing has no gain, and since the bar never
reaches zero, none can restart the rebalance interval for free (V5-L2,
`test_V5L2_aFillThatChangesNothingCannotRestartTheInterval`); no minimum trade is needed. On an index without shares
the settlement reverts `NothingToRebalance`: an empty index has nothing to trade, and nobody moves its units for nothing
(R14, XA-27, `test_R14_XA27_anEmptyIndexDoesNotRebalance`). A fill of a proposal whose start posted a quote must hold
the quote as well (section 3.9).

### 3.3 Why it is safe

`L(x) ≤ ln(1 + x)` on the capped range `[−0.2, 1]`. Above zero the logarithm's series alternates with shrinking terms,
so stopping after `−x⁴/4` is a lower bound, and `−3x⁴/10` is lower still. Below zero every term of the series is
negative, and the terms after `x³/3` sum to at most `3x⁴/10` while `|x| ≤ 0.2`. The margin is thinnest at the turnover
cap: `L(−0.2) = −0.2231467` against `ln 0.8 = −0.2231436`, three millionths. So `L` may not be replaced by anything
that can exceed the logarithm on the capped range, and the caps may not be widened past the range the lemma covers. Two
results follow (the spec, section 3):

- **An accepted fill never lowers the weighted product of the units.** `Σ w_i · ln(v_i / u_i) ≥ Σ w_i · L(x_i) ≥ bar >
  0`, so `Π v_i^w_i ≥ e^bar · Π u_i^w_i`, with the weights as fractions summing to one. That product is the invariant
  of a constant-weight pool.
- **At any prices whatever, the index is worth at least `e^(bar − D)` times what it was.** Take any positive prices.
  Let `f_i` be component `i`'s share of the index's value at them before the fill, and `D = Σ w_i · ln(w_i / f_i)`,
  which is zero when the index sits on its weights at those prices and positive otherwise. The bound follows from the
  weighted inequality of arithmetic and geometric means. Nobody has to say what the prices are: it holds for every set
  of them at once.

So an index that sits on its weights at the market's prices cannot lose value to any fill. Off them, the most a fill
can take is the distance `D`, which comes out of the holders' value (section 3.7 has its size). And whoever
fills, and however, the holders own at least what a fee-less constant-weight pool with the same weights would hold. The
rounding keeps both results: `x` and `L` round down and the logarithm grows with `x`, so a leg's computed score is at
most `ln(v_i / u_i)`, and the gain is floored once more.

What checks it:
- The lemma: by hand, and again in exact rationals by `test/vectors/proofs.py` (standard library only), which also
  checks that `x` and the score round down inside the lemma's range, every second of the bar, and that the amounts keep
  the backing.
- The two results: by hand, in the spec.
- That the contract computes exactly this rule: the exact model (`test/vectors/settlement.py`) and its 426 vectors,
  replayed word for word by `test/WeightedMath.vectors.t.sol`.
- The bound on the weights: `testFuzz_R04_onItsWeightsNoFillTakesValue`, any units, any second. Off them:
  `test_aLoneExecutorKeepsAtMostTheDistanceFromTheWeights`, the greediest fill at the auction's last second.
- The Halmos harness (`test/WeightedMath.halmos.t.sol`) states the integer properties; Halmos has not been run on it.

### 3.4 The unit caps

```
lowest_i  = ⌈u_i · (1 − MAX_TURNOVER)⌉          MAX_TURNOVER = 0.2: a leg keeps at least four fifths of its units
highest_i = u_i + ⌊u_i · MAX_GROWTH⌋            MAX_GROWTH = 1: a leg at most doubles
kept:       lowest_i = highest_i = u_i
```

A `v_i` outside `[lowest_i, highest_i]` reverts `LegOutOfBounds(i, v_i, lowest_i, highest_i)`, and one above the 96 bits
the hub records reverts `SafeCastOverflowedUintDowncast(96, v_i)`, in the preview as in the fill (RX-61). The caps count
units, never value, so nothing a market does can widen them, whatever the executor offers (V5-M2,
`test_V5M2_aFillTakesAtMostAFifthOfALegsUnits`, `testFuzz_V5M2_noFillTakesMoreThanAFifthOfALeg`; RX-15,
`test_RX15_aFillAtMostDoublesALeg`). They also keep every `x` inside the range where `L` is below the logarithm, and
they keep units above zero. `WeightedMath`'s `MAX_TURNOVER` and `AUCTION_DURATION` equal the hub's
(`test_theMathConstantsAreTheHubs`).

### 3.5 The auction: bar(e)

```
bar(e) = ⌈BAR_MAX · (2H − e mod H) / (2H · 2^⌊e/H⌋)⌉          BAR_MAX = 0.5, H = BAR_HALF_LIFE = 12 minutes
```

The bar starts at a half, halves every twelve minutes along a straight line within each, and rounds up, towards the
holders. After the twenty halvings of the four-hour auction it ends at 476,837,158,204 in 1e18ths, 4.77e-7 of the
index. It never reaches zero. `currentBar()` returns it, and 0 outside an auction
(`test_theBarHalvesEveryTwelveMinutesRoundedUp`).

- It starts above what any trade offers. Only a fill that doubles every component, a gift, clears the first second:
  `L(1) = 0.5333` (`test_onlyAGiftClearsTheBarsFirstSecond`).
- It falls about 1.1% of itself per block, so the price of a fill is found to a hundredth of what is at stake.
- **The bar is on the whole index's gain, not a premium on what is traded.** With the executor choosing the trade, a
  premium on the traded amount is won by the smallest trade: the first profitable fill would move a sliver, restart the
  interval and leave the index where it was. A bar on the whole index's gain can only be paid out of the whole distance
  from the weights, so the first fill that can afford it is the one that closes that distance.
- **A fair price needs a bidder; safety does not.** The distance `D` is the prize. Executors compete by filling
  earlier, at a higher bar, which leaves more with the holders. With an honest executor bidding, the team's keeper
  first, the holders keep the distance less the executor's costs. With none, a lone executor waits for the last second
  and takes it, out of the holders' value. Competition decides how much of the distance the holders keep; section 3.3
  bounds what they can lose either way.

### 3.6 Settlement

Each leg's amount is its change in required backing at the units named, rounded the holders' way on its own:

```
shrinking, v_i < u_i:   out_i = ⌊S · (u_i − v_i) · σ / 1e36⌋
growing,   v_i > u_i:   in_i  = ⌈S · (v_i − u_i) · σ / 1e36⌉
left alone, v_i = u_i:  nothing moves, and the component is not read
```

Every rounding goes against the executor: a leg's change and its score round down, the gain rounds down, the bar and
the lower cap round up, an amount rounds down when it leaves and up when it comes back. The amounts come from supply
and units alone, so the index never pays out rounding dust or a donation (SA-07).

In order, `executeRebalance`:

1. accrues the streaming fee, when the index charges one (asking the factory's `feeTerms` who receives it);
2. checks that an auction is open (`NoPendingRebalance`, `RebalanceNotReady`, `RebalanceExpired`);
3. has `WeightedMath` check the units named and compute the amounts at `S` and `σ` in this block: one entry per
   component (`LengthMismatch`), a supply above zero (`NothingToRebalance`), each leg's caps in component order
   (`LegOutOfBounds`, then the 96-bit limit), then the gain against the bar (`GainBelowBar`), and last, when the
   proposal's start posted a quote, the quote (`BelowQuote`, section 3.9);
4. for the bounded overload, checks `maxAmountsIn` (`RebalanceMovedOn`);
5. reads what the index holds of each component that sends or receives something, and of no other, not even its
   balance (DA-14);
6. writes the new units, notes whether the rebalance had a keep mask, bumps `rebalanceNonce`, sets `lastRebalance`,
   clears the proposal and emits `Rebalanced` with the bar, the gain, the units and the amounts;
7. sends each `out_i` to `msg.sender` and calls `IRebalanceExecutor.onXindexRebalance(amountsOut, amountsIn, data)` on
   it, so only a contract can execute;
8. requires, for every component that moved, a balance of at least the larger of `⌊S · v_i · σ / 1e36⌋ + totalClaims`
   and what it held before, less `out_i`, plus the whole of `in_i` (`RebalanceUnderfunded`), and, for every component
   it bought, that it can still send that token, a one-unit transfer to itself, measured (`CannotSendOut`, RX-12).

Surplus the index already held, from rounding or a donation, therefore stays with the holders instead of paying for
part of the fill (R21, XA-28).

The amounts are recomputed from `totalSupply()` in the settling block, and issue stays open through the auction, so
anyone can enlarge a fill with a dust issue after an executor's simulation. `executeRebalance(newUnits, data)` settles
whatever the supply then requires; the callback's arguments are authoritative.
`executeRebalance(newUnits, data, maxAmountsIn)` takes one bound per component (`LengthMismatch` otherwise; an empty
array is the unbounded fill) and reverts `RebalanceMovedOn` when the index needs more than the caller will deliver
(DA-13, `test_DA13_aMintBeforeTheFillMovesItPastTheBound`). `previewRebalance(newUnits)` returns the bar, the gain and
the amounts a fill of those units in this block would settle, after the accrual the fill would make, and reverts as
the fill would (`test_previewMatchesTheFill`).

### 3.7 What a fill can take

**On its weights, nothing.** Whatever units an executor names and whatever the prices, a fill of an index that sits on
its weights at the market's prices leaves it worth at least what it was.

**Off them, at most the distance, and a lone executor keeps it.** The spec's example (section 6): an index of ETH 50%,
BTC 30% and USD 20%, with ETH up 25%, is 0.62% of its value from its weights. The fair fill, the one that puts it on its
weights, has a gain of 0.6201%, which the bar reaches 4,618 seconds into the auction; executors who compete fill near
there, and the holders keep the distance less the executors' costs. A lone executor that waits for the last second keeps
0.6166% of the index, and no more (`test_aLoneExecutorKeepsAtMostTheDistanceFromTheWeights`). In an ordinary week the
distance is 0.3 to 0.6% of an index, up to about 1.8% after a week in which a tenth of the index halved, and 5.0% in one
fill after one coin of two doubled. It comes out of the holders' value: it is what a fee-less constant-weight pool loses
to arbitrage. So a fair price needs an executor bidding, the team's keeper first, where a price feed gave one whoever
filled. Without a bidder, nothing on chain makes the price fair unless the start posted a quote, which caps a lone
executor at its tolerance of what it trades (section 3.9). An index created off its weights carries its distance from
its first day, and its creator can take it: 15.5% of a 50/50 index created 90/10 by value in one fill, at the worst a
fifth of an index per fill. No contract can compare units with weights without a price. That is why only wallets the
factory's owner approved create an index (section 2): the team creates on the weights, at the app's prices, and the app
shows an index's coins against its weights (`docs/known-limitations.md`).

**No price can be wrong.** No key signs a price and no feed reports one, so there is none to forge or to stop. What is
left is a coin that turns worthless and free to mint, by its issuer or through a forged bridge message. The caps and
the gain rule bound what it draws: a coin at 10% of an index, at most 5.8% of the other components per fill, at most
once every `MIN_REBALANCE_INTERVAL`, until the guardian keeps it (section 3.8).

**Why the caps count units, not value (V5-M2).** A cap in value needs prices, and the index has none. Counted in
units, a fill sends out at most a fifth of each component and at most doubles one, whatever anything is worth. A value
cap must not come back.

**One fill may not land on the weights.** The caps bound a fill, and `L` is a little under the logarithm, so the last
few percent are not worth an executor's while. In the spec's simulation of the executor's best fill (20 equal coins,
each moving 11% a week on its own) the index lands 96% of the way to its weights; after a quarter's drift (each coin
moving 40%) the caps bind and one fill goes about half the way. The next rebalance takes the rest.

**A fill near the weights can be forced.** When the distance is under an executor's costs, nobody honest fills, and
anyone may fill at the last second with a gift of at least the bar's floor, 4.77e-7 of the index, restarting the
interval. It costs the filler, pays the holders, and delays the next rebalance by the interval.

### 3.8 Keep mask and known limits

A kept component must keep its units exactly: both its caps are its current units, so no fill of that rebalance may
move it. Only the owner or guardian can pass a mask. It is the guardian's answer to a coin being minted without limit,
and to a component that is paused or blacklists the hub. An executor needs no mask to leave a component alone: it names
that component's current units. Either way, a component that neither sends nor receives is not transferred and not
read, not even its balance, so a fill works around one whose `transfer` or `balanceOf` reverts, or whose contract no
longer answers at all (`test_R08_DA14_RT01_aComponentLeftAloneIsNotRead`). The limits:

- **A collapsing coin is still bought.** Fixed weights keep buying it, at most doubling its units per fill (RX-15).
  Units beyond `uint96` stop the fill rather than wrap (`test_V5L3_RX61_unitsBeyondUint96StopTheFill`), until the
  guardian keeps the coin (V5-L3). A two-component index cannot keep one, since a mask must leave two moving.
- **A dust index's units can be walked.** Each fill must gain, but on a supply worth nothing a gain costs nothing. So
  whoever holds a dust index's shares can move its units off its weights over several intervals. A later minter
  deposits at those units, in kind and fairly, and the next auction pays the distance to whoever fills first. The app
  shows an index's components against its weights before it offers a mint.

### 3.9 The quote

The owner or guardian may post a quote with a start: `startRebalance(keepMask, prices, tolerance)`, for those two roles
only (`Unauthorized` otherwise), under the same clock and keep-mask rules as `startRebalance(keepMask)`, which is
unchanged and still open to anyone once the waits are over.

- `prices`: one per component, in component order (`LengthMismatch` otherwise). Each is the price of one raw unit of
  the token in any one unit of account, from 1 to 2^128 − 1 for a component the mask leaves moving; only their ratios
  matter. A kept component's entry is ignored and recorded as zero.
- `tolerance`: how far under the quoted value a fill may bring in, 1e18 = 100%. It must be under 1e18. A price out of
  range or a tolerance of 1e18 or more reverts `InvalidQuote`.
- The start emits `RebalanceQuoted(proposalId, prices, tolerance)`, and `rebalanceQuote()` returns the pending
  proposal's prices and tolerance, empty and zero when it has none.

A fill of that proposal must clear the bar as any fill does, and must also bring in, at those prices, at least
`1 − tolerance` of the value it takes out:

```
valueOut = Σ p_i · (u_i − v_i)      over the legs that shrink
valueIn  = Σ p_i · (v_i − u_i)      over the legs that grow
valueIn ≥ ⌈valueOut · (1e18 − tolerance) / 1e18⌉          or BelowQuote(valueIn, floor)
```

The check is `WeightedMath.quoteCheck`, exact in integers, with the floor rounded up, against the executor. It runs
after the settlement's own checks, in `previewRebalance` as in the fill. A component whose units do not change counts
for nothing, whatever its price.

**The index still reads no price of its own.** No feed, no oracle, no pool: these prices are the caller's, a
governance input fixed at the start. The quote is the one place a price enters a contract, and it enters only to
refuse.

**It can only tighten.** A fill must pass both checks, so a quote that is wrong, stale or hostile can stop its own
proposal from filling, which a cancel already can, and can make no fill worse than a start without a quote allows
(`test_aQuoteOnlyRefusesWhatTheBarWouldAccept`, `test_aWrongQuoteStopsItsProposalAndNothingElse`). A compromised
owner or guardian gains nothing over funds from it.

**What it buys.** An executor alone at the auction's last second keeps at most `tolerance` of what it trades, where
without a quote it keeps the index's whole distance from its weights (0.48% of an index after one coin of four rose a
quarter, 5.0% after one coin of two doubled). In `test_aQuoteCapsWhatALoneExecutorKeeps`, with the market's prices
posted and half a percent of tolerance, the fill that kept 0.6166% of the index is refused and the most a fill keeps is
under 0.06%.

**Its limits.**

- It protects only a proposal whose start posted one, and it ends with that proposal: a later start without one is
  bound by the bar alone (`test_aQuoteEndsWithItsProposal`).
- A stranger may still start without a quote once the waits are over. The guardian then has the two hours of notice
  and the four of auction to cancel that proposal and start one with a quote, in one Safe transaction.
- A quote is hours old by the time the auction ends, so its tolerance has to cover the market's move over about six
  hours, or nothing fills and the proposal expires.

It is modelled on Reserve's Index DTFs, where a rebalance manager posts price ranges; here it is optional and sits on
top of the rule that needs no price. The keeper reads `rebalanceQuote()` and names units that hold it. The exact
model's `quote_floor` (`test/vectors/settlement.py`) generates the 77 vectors under `quotes`, which
`test/WeightedMath.vectors.t.sol` replays, and `test/WeightedHub.quote.t.sol` holds the hub's ten tests.

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
rounded down, unless the index is gated and the gate would refuse it as `to` (AU-1). A recipient that could not hold shares is replaced, so no fee can block a mint or an exit
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
through its `MATH` immutable, because the scale pushed the hub past EIP-170; the hub still reads every balance, and the
math holds nothing and reads nothing. No price enters either.

## 5. Flows

`docs/integration.md` walks through each flow for an app. In short:

- **Create.** A wallet the owner approved picks 2 to 100 listed coins and their percentages; the app derives the units
  at current prices and shows the address and the index's wrapped share of value, and the wallet creates. A partner
  asks the team, which creates the index and hands on its creator role, fee included (`transferCreator`,
  `acceptCreator`).
- **Mint and burn** through the zap (up to about 35 components, on coins with a route), through the basket builder
  over several transactions (any size, on coins with a route, the rest deposited in kind), in kind (up to 100), or at
  a limit through `MintRequests`, filled by anyone who holds or can issue the shares.
- **Rebalance.** At most once per the index's interval, 7 to 91 days: anyone starts, a plain call, or the owner or
  guardian starts with a quote (section 3.9); 2 hours of notice; then a 4-hour auction in which an executor names the
  units from its own prices, previews the fill with `previewRebalance(newUnits)`, and settles once its gain clears the
  bar, preferably through the bounded overload. The bot in `keeper/` is one such executor and holds no role; anyone may
  run one. Its bidding, and any other honest executor's, is what makes the price fair (section 3.5). It prices its own
  trades off chain, from Pyth's prices served by Hermes, which needs an API key since 2026-08-26; no contract waits on
  that.
- **Restock.** A coin no Ethereum pool sells, most Wormhole copies among them, reaches an executor's fill only from its
  stock. Beside the keeper runs its restock service (`keeper/restock.mjs`, since 2026-10-19), under a key of its own,
  the treasury, which the executor's owner pins: it buys such a copy on its home chain's DEX, bridges it into the
  executor through Wormhole's Token Bridge (`redeemBridged`), and bridges spare stock back out (`bridgeOut`), only to
  the home-chain wallets the executor's owner pins, to sell there; USDC for the buys moves by CCTP. What arrives earns
  the keeper stock allowance only within the restock allowance the executor's owner sets per coin, so restocking never
  raises what a stolen keeper key can deliver (RS-1), and the treasury holds at most the owner's figure of USDC off the
  float (RS-2). It serves the eight EVM-homed coins with a market, XRP, ADA, LTC, DOT and BNB on BNB Chain, AVAX, OP and
  AERO; ATOM has none, and JUP, PYTH, SUI, APT and ALGO wait for their chains' adapters (`keeper/README.md`,
  `audit/2026-10-25-restock-review.md`). None of it is a protocol contract or role: the hub sees an executor that
  delivers.
- **Leaving.** Issue and redeem stay open through notice and auction. Once the auction is live an executor can order
  its fill ahead of a public exit, and shares issued while a rebalance is pending share its haircut (RT-02).
- **Frozen component.** `redeemSkipping` and `claim` for holders, the keep mask for rebalances.
- **Valuation** is off chain: `value per share = Σ units_i × price_i` from the app's own prices.

## 6. Key design decisions and rationale

**In-kind core, swap layer on top.** Splitting custody (the hub) from convenience (the zap) keeps the part that holds
funds small and admin-free, and lets the swap layer be replaced without touching any index.

**Nothing reads a price.** v3 read Chainlink feeds to shape targets and to gate each settlement, which made a stale
feed a halt and could only approximate a bound at market prices (CR-L06). v4 Stage A removed every price and held a
market-cap rule by keeping units proportional to supplies the owner maintained. v5 brought one back for a creator's
percentages, which are shares of value: its settlement read Pyth, and three of Pyth's five signing keys could then
take up to a fifth of each component per fill. Since 2026-11-10 (the owner's call: "we have to cut off oracles
somehow and keep rebalance safely") the executor names the units and the index checks a gain in units (section 3). So
no feed and no price signer is trusted, and nobody's keys stand between the holders and their coins. In `src/` and
`abi/`, `test_V5I4_noContractNamesPyth` fails if any file names Pyth's contract, parse, getters, pushes or price ids
(V5-I4), and `test_A713_noContractReadsAPrice` if any file names a Chainlink feed, a pool's price or any other common
price source (A7-13). The cost is the one section 3.5 states: a fair price needs an executor bidding, where a price
feed gave one whoever filled. Do not bring a price back into a contract, as a check, a bound or a hint: the design's
safety is that it needs none. The one exception is the quote the owner or guardian may post with a start (section
3.9): a governance input no contract fetches, which can only refuse a fill the bar accepts. The rule holds without it.

**Fixed weights and constituents.** Nobody, the creator included, changes them; new weights or a new list mean a new
index. An index holds its own units and weights from creation, so no relisting or delisting reaches it, and its address
commits to every component's token, units and weight and to its config, so a front-runner's copy lands at its own
address (LR-05).

**Only approved wallets create an index.** No contract reads a price, so none can compare the units a creator names with
its weights. An index created off its weights carries that distance from its first day and loses it to whoever fills its
auctions: on the exact model, one last-second fill takes 15.5% of a 50/50 index created 90/10 by value, and at the worst
a fifth of an index per fill. So `createIndex` reverts `CreatorNotApproved` for any wallet the factory's owner has not
approved (`setApprovedCreator`), and the team creates on the weights at the app's prices. The approval is read at
creation and nowhere else: it gates no issue, redeem, rebalance or handoff of the creator role, it reaches no index that
exists, and it gives no power over funds.

**One deployment, the missing coins wrapped.** About 71 of the top-300 candidates exist on Ethereum through their
issuer; held on BNB Chain instead, the same universe would have wrapped 71 legs. Wormhole is the one bridge accepted for
wrapping: anyone attests a coin on its home chain and the bridge deploys the copy on Ethereum. The cost is a new trusted
party over every wrapped leg (section 7). The list (`script/Listings.sol`) stands at 91, 15 of them Wormhole copies:
SOL, listed first, 12 added on 2026-10-10, and BNB and SUI, whose copies the count of that day missed, added on
2026-10-18; a 13th of 2026-10-10, DOGE's, left on 2026-10-14 on the owner's call, since Pyth, which then priced the
rebalance, prices DOGE and not the copy. SAND and RLB left on 2026-10-18 after the source reading, and on 2026-10-19 BTT
and SEI's copy, added with BNB's and SUI's, their bridges closed or closing (RX-28, RX-32), the owner's calls; ZK is
tiered Bridged, ZKsync's bridge copy of a token issued on ZKsync Era (RX-19). Tether Gold and the 17 Ondo stocks do not
count toward the hundred, so 73 coins of the top 300 are listed; 26 more copies await an attestation on Wormhole's
Portal, and FIL's waits for a reading of its Binance-Peg source (`design/2026-10-10-one-index-wormhole-legs.md`, section
2a, and `design/2026-10-18-pre-mainnet-readings.md`, section 3).

**Up to 100 components.** Every path of the hub and the factory fits EIP-7825's per-transaction cap of 2^24 gas at
100, measured on mock tokens with every account cold (`test_aHundredComponentsFitOneTransaction`):

| Operation at 100 components | Gas |
|---|---|
| `createIndex` | about 5.3M |
| `issue` | about 3.6M |
| `startRebalance` | about 94k |
| `startRebalance` with a quote, which stores a price per component | about 1.4M |
| `executeRebalance`, an executor that already holds the bought tokens | about 4.2M |
| the same fill under a quote | about 4.4M |
| `redeem` | about 3.7M |
| `redeemSkipping`, every component skipped | about 5.1M |
| `claim` | about 53k |

The hub is 21,315 bytes, 3,261 under EIP-170. Real tokens transfer dearer than mocks. The fork suite that issues,
rebalances and redeems every coin forge-std can fund in one index (`test/fork/WeightedHub.fork.t.sol`) is rewritten
for this rebalance and has not run on it yet, so no figure on real tokens is recorded for this build; the Pyth-priced
build's are in section 11.

A fill that swaps inside the call costs an estimated 150k a leg on top (v4's hybrid design, section 9.1), so swaps
inside a 100-leg fill do not fit, and a fill that wide needs an executor with inventory. The zap stops near 35
components (section 2).

## 7. Security model

- **Trust.**
  - The factory owner (a Safe), who proposes listings and guardian changes behind public delays, approves which wallets
    may create an index, at once, and hands over ownership in two steps with no delay; the guardian, who can cancel
    listings and rebalances, delist, start a rebalance with a keep mask, with a quote or before strangers may, and
    cancel its own removal but not its replacement. The guardian is the guardian's Safe itself.
  - No price feed and no price signer. Nothing reads a price, so no publisher, signing key or oracle's governance is
    trusted with anything, Pyth's included. What took their place is not a party but a condition on the price: a fill
    is safe whoever makes it (section 3.3), and its price is fair when an honest executor bids, the team's keeper
    first. A lone executor takes the index's distance from its weights out of the holders' value: 0.3 to 0.6% of an
    index in an ordinary week, 5.0% after one coin of two doubled, and up to a fifth per fill of an index its creator
    made off its weights (section 3.7), which is why only wallets the owner approved create one. The one price a
    contract takes is a quote the owner or guardian may post with a start, and it can only refuse a fill: a wrong,
    stale or hostile one stops its own proposal, which a cancel already can, and gives a compromised role nothing over
    funds. With one posted, a lone executor keeps at most its tolerance of what it trades (section 3.9).
  - Wormhole's guardians, for the wrapped legs: a quorum (13 of 19) can forge a bridge message, minting unbacked copies
    or upgrading every wrapped token's code at once, with no timelock. Since April 2026, for the chains on delegated
    guardian sets (BNB Chain, Kaia, NEAR, Sui, Arbitrum, Monad), five of seven named guardians suffice to mint, so most
    listed copies rest on five keys (RX-6). The chain a copy comes from is a party too: a copy whose home side closes
    its bridge redeems for nothing (RX-28, RX-32). Their reach is the whole of every wrapped leg, and through a fill
    the bounded share of the rest that a worthless coin can draw (section 3.7), so the app shows every index's wrapped
    share of value. Redeem always pays the copies out; turning them into the coin needs Wormhole live.
  - The whitelisted tokens and their issuers, each labelled in the app: BitGo for WBTC, Tether for Tether Gold, Ondo
    for every stock token, and both Binance and Wormhole for a copy wrapped from a Binance-Peg coin.
  - For the zap only: Uniswap's Universal Router and the V4 PoolManager.

  Executors and the account that starts a rebalance are untrusted. Users trust no one with custody.
- **What can move a basket's shape or value.** Only a fill: units move to what its executor names, each component
  keeping at least `1 − MAX_TURNOVER` of its units and at most `1 + MAX_GROWTH` of them (V5-M2, RX-15), the weighted
  product of the units never falling, at most once every `MIN_REBALANCE_INTERVAL`. On its weights an index loses
  nothing to a fill; off them a lone executor keeps at most the distance from the weights (section 3.7). Weights and
  constituents are fixed at creation. Rounding goes the holders' way everywhere.
- **The guardian's stalls.** `cancelRebalance` has no window and no rate limit, so a hostile or compromised guardian can
  cancel every auction at its last second until the owner replaces it, after `GUARDIAN_DELAY`, which the guardian cannot
  cancel: a trust assumption of the role (DA-12). A quote no fill can hold stalls its own proposal in the same way, and
  does nothing else. A keep-mask rebalance that leaves a pair of small components moving can also be filled with a gift
  to that sliver, and its fill restarts `MIN_REBALANCE_INTERVAL` for a start without a mask rather than the index's
  interval (XS-3), so the stall can outlast the replacement by up to a week, and by a keep-mask auction the outgoing
  guardian left pending, `REBALANCE_DELAY` + `AUCTION_DURATION` more (RX-44). While a replacement is pending the owner
  cancels the outgoing guardian's keep-mask proposals, within the 2 hours of `REBALANCE_DELAY`, and monitors watch
  `RebalanceStarted` with a non-zero `keepMask` (RT-07). Neither stall moves funds; holders redeem throughout.
- **Reentrancy.** `nonReentrant` on the hub's eleven entry points that mint, burn, pay, accrue or rebalance
  (`test_R11_everyEntryPointIsGuardedDuringTheCallback` re-enters ten of them; the quoted start shares the guard), on
  `createIndex`, on the zap's seven (CR-I26), on every entry point of `BasketBuilder` and on every entry point of
  `MintRequests`. The new units, the nonce and the cleared proposal are written before any rebalance transfer, and the
  callback goes only to `msg.sender`. Wake's reentrancy detector does not model the guard; its documented suppressions
  are the `redeem` call in `IndexZap._burnBasket`, the `permit` call in `IndexZap._tryPermit`, the `redeem` call in
  `BasketBuilder.redeem`, the clone's `initialize` call in `WeightedIndexFactory._initializeIndex`, and the executor
  callback in `WeightedHub`. Inside `issue`, `redeem` and `executeRebalance`, supply, units and balances change at
  different moments, so integrators value an index from `components()` and independent prices, never from
  `balanceOf(index)` and `totalSupply()` (VR-05).
- **Clone safety.** The implementation has initializers disabled; `initialize` is `FACTORY`-only and runs in the same
  transaction as the clone; uninitialized instances cannot issue, redeem or rebalance; `isIndex` is the only trusted
  registry, and the zap and `MintRequests` check it.
- **Token behaviour.** `issue` verifies received amounts. A paused or blacklisting component does not freeze the rest of
  a basket: `redeemSkipping`, `claim` and the keep mask route around it. Policy: standard ERC-20s, 6 to 18 decimals, no
  fee-on-transfer, rebasing or callback tokens; stables are mint currencies, not components. The admission check is
  `script/CheckToken.s.sol`, whose default WBT rule refuses a token that can both blacklist a holder and destroy its
  balance; on 2026-10-10 the owner admitted Tether Gold and Ondo's stocks over that rule.
- **Arithmetic.** Units below `2^96` (`SafeCast`), and at most `maxUnitsOf(token)`, never above `MAX_UNITS`, at
  creation. A leg's change `x` lies in `[−0.2, 1]` at 1e18 once the caps hold, so the score's numerator stays below
  7e73, inside `int256`, and a hundred weighted scores fit with room to spare. Every product of shares and units, and
  each cap, goes through 512-bit `mulDiv`. Units beyond `uint96` stop a fill rather than wrap (V5-L3, RX-61).
- **Operations.** `script/DeployWeighted.s.sol` deploys the factory (and through it the math and the hub's
  implementation), the zap, the basket builder and `MintRequests`. `OWNER` and `GUARDIAN`, the guardian's Safe, are
  required and must differ. On chain 1 the router, WETH and the stablecoins come from `script/MainnetAddresses.sol` and
  nothing else is accepted (`MainnetOverride`), and the script broadcasts only the build its four release hashes
  record (CF-5). There the owner must be a contract that is not an EIP-7702 delegated account, and a Safe must need at
  least three signatures and have no enabled module; neither the guardian nor the broadcasting key may be one of its
  signers (SA-06). Neither role may be the router, the PoolManager, or any token or mint currency in the chain's
  address book (XA-39, CR-I37).
  Any other contract owner, such as a timelock, needs the operator's `OWNER_IS_NOT_A_SAFE`, set to its address (A7-08).
  After the listings the owner approves the wallets that create indexes (`setApprovedCreator`); nobody can create one
  before.
- **Known limitations** are listed in `docs/known-limitations.md`, linked from the README.

## 8. Verification

- **Unit and fuzz tests per contract:** `test/WeightedHub.t.sol`, `test/WeightedHub.fees.t.sol`,
  `test/WeightedHub.rebalance.t.sol` (exact settlements, the bar, the unit caps, the bound on and off the weights, keep
  masks, reentrancy, a hundred components), `test/WeightedHub.states.t.sol` (the rebalance state machine's transition
  matrix, section 3.1), `test/WeightedHub.quote.t.sol` (the quote of section 3.9: who may post one, what it must
  contain, the cap it puts on a lone executor, that it only refuses, that a wrong one stops its own proposal and nothing
  else, and that it ends with its proposal), `test/WeightedMath.vectors.t.sol` (426 settlements and 77 quote checks
  replayed against the exact-rational model of `test/vectors/settlement.py`, written from the spec;
  `test/vectors/proofs.py` checks the safety proof's chain in exact rationals with the standard library alone, section
  3.3; the method is that of `design/2026-10-29-settlement-vectors.md`), `test/WeightedMath.halmos.t.sol` (the integer
  properties stated for Halmos, which has not been run on it), `test/WeightedIndexFactory.t.sol`, `test/IndexZap.t.sol`,
  `test/WeightedZap.t.sol`, `test/BasketBuilder.t.sol`, `test/MintRequests.t.sol`, `test/Security.t.sol`, the scripts'
  suites, `test/Repo.t.sol` and the mocks' own tests in `test/mocks/Mocks.t.sol`. `MockWeightedExecutor` fills honestly,
  short, not at all, or reentrantly.
- **Invariant suites.** `test/WeightedHub.invariant.t.sol` runs random issue, redeem, `redeemSkipping`, claim, transfer,
  donate, moves of the test market's prices, time jumps, starts, cancels, and honest, bounded and short fills. It
  asserts that every component stays backed including open claims, supply and claims add up, the nonce counts fills, a
  short fill never settles, `canStartRebalance` is right, a fill settles exactly its preview, an accepted fill's gain is
  at least its bar and the bar is never zero (`gainBroken`), no fill sends out more than `MAX_TURNOVER` of a component's
  units (`turnoverBroken`) or more than doubles them (`growthBroken`), and the weights never change.
  `test/MintRequests.invariant.t.sol` is described in section 2.
- **Security regression tests,** named after their ids, as `CLAUDE.md` gate 6 requires. v5's own that still bind:
  V5-M2, V5-L2, V5-L3 and V5-I4, re-targeted to the oracle-free rule; V5-M1, V5-L1, V5R-1 and V5-I1 went with Pyth;
  V5-I2, V5-I3 and V5R-I2 are recorded by documentation, and V5R-I1 is retired with Stage B. The older ids that bind
  (R04, R08, R10, R11, R14 to R16, R21, DA-13, DA-14, DA-17, DA-22, SA-07, CR-I01, RT-01, RT-21 and others) are in the
  weighted suites, as `audit/2026-10-06-v4-retirement.md` and `audit/2026-11-10-oracle-retirement.md` list. Seven
  records say which ids lost their test when a mechanism went: `audit/2026-09-22-v3-retirement.md`,
  `audit/2026-09-30-v4-stage-a-retirement.md`, `audit/2026-10-06-v4-retirement.md`,
  `audit/2026-10-07-stage-b-retirement.md`, `audit/2026-10-14-thorchain-retirement.md`,
  `audit/2026-10-14-pancakeswap-retirement.md` and `audit/2026-11-10-oracle-retirement.md`. A retired id's test is
  never restored against the new design.
- **The mutation gate.** `test/mutants/mutants.json` holds the mutants as exact edits, the arithmetic's and the hub's
  among them (each rounding flipped, each cap dropped, the bar's rounding, start and half-life, the score's terms),
  and `test/mutants/run.py` requires each one's suite to fail.
- **Mainnet fork tests,** five Ethereum suites on real tokens and routers: the zap on V3 and V4 legs
  (`IndexZap.fork`); the address book, the code hashes of the router, the PoolManager and the V3 factory, the
  Wormhole copies against the bridge, and the lists on a fresh factory (`MainnetAddresses.fork`); the admission check
  on every listed token (`CheckToken.fork`); the WBTC pause exit, USDT's fee switch, stray router balances,
  `MintRequests` on the real stablecoins and the deploy script against real Safes (`Security.fork`); and the hub:
  every coin forge-std can fund issued, rebalanced and redeemed in one index, the liquid ones through the zap and a
  Uniswap-routed executor, and four drills, a WBTC pause, an executor that leaves a coin alone, a fill that reaches
  for more than a fifth of a leg and an auction nobody fills (`WeightedHub.fork`). The suites are rewritten for the
  oracle-free rebalance and have not run on it yet: they wait for an archive RPC.
- **Gates,** enforced in CI: the submodule check against `foundry.lock`, the check that no committed file names a path
  on its author's machine, `forge fmt --check`, `forge build --deny warnings`, `forge lint -D notes`, the ABI diff of
  the five committed ABIs, `forge test` (fork suites required on pushes to `main` and on pull requests into it from this
  repository), the keeper's executor and bot suites, 100% coverage on every file, the Wake detectors clean on `src/`,
  and the mutation gate, the workflow pinned whole by `test/Repo.t.sol` (A7-12). Aderyn reports nothing on `src/`
  (`aderyn.toml` gives each excluded rule its reason); CI does not run it yet.

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
| Uniswap Universal Router 2.0.0 | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap V3 factory (`CheckToken`'s depth report) | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| Uniswap QuoterV2 (fork tests) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Wormhole token bridge (Portal) | `0x3ee18B2214AFF97000D974cf647E7C347E8fa585` |
| WeightedIndexFactory / WeightedHub implementation / WeightedMath / IndexZap / BasketBuilder / MintRequests | not deployed |

Every listed token, with the source of each Wormhole copy, is in `script/MainnetAddresses.sol`, and the list with each
token's tier in `script/Listings.sol`. Only the tokens and the router are called by the protocol's contracts, and no
oracle is: the V3 factory and the quoter serve scripts and tests, and no protocol contract calls the Wormhole bridge.
The keeper's executor, which holds no role, calls its Token Bridge to restock (section 5). `script/PythIds.sol` is
the keeper's catalogue of each coin's Pyth id, for the prices it values its own trades at; no contract or script
reads it.

## 10. Roadmap

**What remains before a mainnet**, in the order of `design/2026-10-10-one-index-wormhole-legs.md`, section 5, as
`design/2026-10-18-pre-mainnet-readings.md`, section 7, and the spec, section 9, update it: the 26 Wormhole copies still
to attest, and FIL's source reading, each then through `CheckToken` and onto the lists, and RAY's `updateWrapped` from
Solana; a run of the fork suites, rewritten for the oracle-free rebalance, on an archive RPC; a red team of the
oracle-free mechanism by reviewers who did not design it, and a run of the Halmos harness; the platform's fee policy and
the legal reading; the external audit, then `DeployWeighted`'s release hashes fixed at the audited commit (CF-5); the
owner Safe (3 of 5) and the guardian's Safe on Ethereum, then `DeployWeighted` and `ConfigureWeighted` over the list,
and the owner's approval of the wallets that create indexes; a new Sepolia deployment, since the one live there is the
Pyth-priced build (`docs/deployment.md`); and the app side: `previewRebalance(newUnits)` and the listings as they now
are, Wormhole Connect for bridging in and out, the wrapped share and the Bridged and Custodial labels on every index, an
index's coins shown against its weights, and a filler for `MintRequests`. No Pyth plan, parameter replay or settlement
on a Hermes update is needed any more: the keeper's Hermes key is the keeper's own, for its own prices.

**Backlog.** `createAndMint`, mixed-venue legs that split one leg across V3 and V4, per-pair partial-fill auctions, a backstop for auctions too small to pay (the keeper fills only what
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
  grown to 93; the fork run of 92 coins in one index; the end-to-end run of 2026-10-12 against Pyth's real contract on
  an anvil fork, where a fill of 93 legs cost 7.26M gas, Pyth's parse 2.34M of it; the keeper bot with its executor
  (`keeper/`); and on 2026-10-13 the deletion of the BNB Chain deployment, the v4 demo, the review PoCs and the records
  of retired designs, all recoverable from git at `f83dcab`. On 2026-10-14 the owner removed THORChain and the zap's
  PancakeSwap legs: users come with USDC or USDT, and the zap swaps through Uniswap alone.
- **The oracle-free rebalance** (2026-11-10): the owner's call to cut the oracle and keep the rebalance. Until then v5's
  settlement was priced by Pyth. The hub fixed the second its prices belonged to, an executor brought a signed update
  for it, the targets came from those prices, and the auction ran on a multiplier μ that fell from 1.02 to 0.98. From
  2026-10-26 a start read every moving feed (RX-3), and from 2026-11-02 a `GuardianRelay` held the guardian role,
  because a start's update was valid for one slot, which a Safe cannot land (RZ-26). Three of Pyth's five signing keys
  could take up to a fifth of each component per fill. All of that went: the executor names the units, and the index
  checks a gain in units against a falling bar (section 3, `design/2026-11-10-oracle-free-rebalance.md`).
  `audit/2026-11-10-oracle-retirement.md` lists the review ids that went with Pyth and the test of every re-targeted
  one. What it cost: a fair price now needs an executor bidding, where Pyth gave one whoever filled. The same day
  creation was limited to wallets the factory's owner approves (`setApprovedCreator`), since no contract can check a
  creator's units against its weights. A quote the owner or guardian may post with a start was added the same day
  (section 3.9).
