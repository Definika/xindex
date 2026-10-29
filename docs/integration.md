# Integration

How each flow works, and what an app needs to get right when it builds on the contracts.

## Flows

**Create.** The creator picks whitelisted tokens, a weight for each in basis points summing to 10,000, and the value
one index token should start at. The app turns each weight into starting units at its own prices, `units_i = w_i /
10,000 × value / price_i` in the token's raw units, calls `predictIndexAddress` to show the address, and calls
`createIndex`. The factory reads no price, so units a little off the weights cost nothing: the first rebalance, the
index's interval after creation, brings the index to its weights. Every unit has to lie in `[MIN_RAW_UNITS,
maxUnitsOf(token)]` or the call reverts `UnitsOutOfRange(token, units)`; `maxUnitsOf` is `MAX_WHOLE_TOKENS` (1e9) whole
tokens per index token, never above `MAX_UNITS`, so a wei-share stays worth nothing (RX-5). The floor binds hardest on
Tether Gold, whose 10,000 raw units are 0.01 oz, about $30, so an index token worth $100 can hold it at 30% or more;
for WBTC, 0.0001 BTC, about $11, at 11% or more on a $100 token; for an 18-decimal component the floor binds on nothing
(RX-38). Names and symbols are free-form and not unique; the UI must show the index address and `creatorOf` to avoid
spoofing. The creator role is handed on in two steps: `transferCreator` offers it and the new creator takes it with
`acceptCreator`, so `creatorOf` only ever names an account that agreed (RX-22).

The address commits to every component's token, units, weight, price id and decimals. A relisting that executes
between the preview and the transaction with a new price id changes the address, never the terms at an address.

**Mint with USDC/USDT.** For each leg the app picks a venue, quotes it (QuoterV2 `quoteExactOutput` for a V3 leg, the
V4 Quoter for a V4 one), sets per-leg limits and the overall `maxAmountIn`, reads `rebalanceNonce()`, and calls
`mintWithToken(MintParams)`. Exact `shares` are minted; unspent USDC comes back. With a USDC EIP-2612 permit for
`maxAmountIn` expiring at `deadline`, `mintWithTokenPermit(MintParams, v, r, s)` needs no approval transaction; a permit
someone already submitted is accepted, and USDT has none.

**Mint with ether, burn to ether.** `mintWithEth(MintParams)` takes `tokenIn = WETH`, `maxAmountIn = msg.value` and
legs that end at WETH, with WETH itself a pass-through leg when the index holds it; the zap wraps, buys, and refunds
the unspent ether. `burnToEth(BurnParams)` and `burnToEthWithPermit` take `tokenOut = WETH` and legs that end at WETH,
and pay `to` in ether. A caller or `to` that cannot receive ether reverts the call. The events name WETH.

**Burn to USDC/USDT/anything.** The app quotes each leg in the exact-input direction, sets per-leg minimums and a
non-zero overall `minAmountOut`, passes `rebalanceNonce()`, and calls `burnToToken(BurnParams)` or
`burnToTokenWithPermit`.

**Rebalance.**
1. Once the index's interval has passed since its creation or last rebalance (`earliestRebalance()`; a week after a
   guardian's keep-mask fill, XS-3), anyone calls `startRebalance(0, priceUpdate)` with Pyth's fee as `msg.value`. It
   reads every moving component's feed at `priceTime()`, as a fill does, and keeps no price: a feed that does not publish
   then, as a US-hours stock's does not while its market is shut, refuses the start (RX-3). It calls no component and
   only sets the auction's start, `eta`, 2 hours ahead.
2. For 2 hours nothing changes. The targets come from the settlement's own prices, so the notice is for executors to
   ready their stock, routes and price update, not a window holders need. Issue and redeem stay open throughout.
3. A 4-hour auction follows, with `μ` falling linearly from `MU_MAX` (1.02) to `MU_MIN` (0.98), rounding up. The notice
   and the auction together, 6 hours, are shorter than any closure of a market a feed follows (17.5 hours overnight for
   the US-hours stocks), so an auction started while every feed publishes ends before the next open (RX-3). An
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

## Integration notes

- **Index value is the app's job.** No contract has a price function. Value one whole index token as
  `Σ units_i / 10^decimals_i × price_i` from `components()`, `componentTerms()` and the app's own prices: take the
  median of several exchanges and aggregators, drop sources more than about 2% from the rest, price exactly the asset
  held (WBTC at WBTC's own market price), and mark a price older than about ten minutes as estimated. Never derive a
  price from `balanceOf(index)` and `totalSupply()`, and never use a thin DEX pool of the index token as an oracle.
- **Starting units.** The app derives them from the creator's weights at its own prices (see "Create"); the factory
  takes them as given. `createIndex` reverts `UnitsOutOfRange` unless each lies in `[MIN_RAW_UNITS, maxUnitsOf(token)]`,
  `InvalidComponentCount` outside 2 to `MAX_COMPONENTS` (100), `InvalidWeights` unless every weight is non-zero and
  they sum to 10,000, and `DuplicatePriceId` when two components share a Pyth price id, since Pyth fills only the first
  of two equal ids and such an index could never settle (V5-M1). Offer the one-click zap only up to about 35
  components; a larger index mints in kind, through `MintRequests`, or through the basket builder over several
  transactions.
- **Names and symbols are not unique.** `createIndex` requires only that they are non-empty. The CREATE2 salt commits
  to the creator, the name, the symbol, every component's token, units, weight, price id and decimals, and the config
  (fee and streaming rates, referral share, rebalance interval), so two
  look-alike indexes have different addresses: key every index by its address, show `creatorOf`, which only an account
  that accepted the role can be (RX-22), and mark a name or symbol an existing index already uses. Flag an index whose
  starting units and weights disagree by more than a rebalance would fix: a creator can weight a share-priced Ondo leg
  far below its holdings, so that after a split the hub sells it at a fraction of its worth (RX-7).
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
  **native ether**, `address(0)`, which may only ever be an intermediate: native ether never reaches the zap through a
  swap, whose `receive()` takes ether from WETH alone. Example, USDC to LINK: burn `[{ETH, 3000, 60}, {USDC, 500, 10}]`, mint `[{USDC, 500, 10}, {ETH,
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
