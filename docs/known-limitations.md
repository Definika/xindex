# Known limitations

What the contracts do not protect against, and what an app built on them has to show its users.

- **A lone executor can take up to 2% of what it trades.** At the auction's end `μ` reaches `MU_MIN` (0.98), so an
  executor with no competition that waits for it delivers 98% of the value it takes, at the settling prices.
  Competition fills earlier, at the `μ` that just covers an executor's swap costs, except on an index holding one of the
  six US-hours stocks, below. What a fill trades is only the drift
  since the last rebalance, at most 20% of each component's units, at most once a week.
- **A wrong price costs at most the turnover cap.** A fill at a wrong or forged Pyth price trades the index toward
  wrong targets. The cap counts units, not value, so whatever the price says, one fill sends out at most 20% of each
  component's own units and at most doubles a component it buys, at most once every `MIN_REBALANCE_INTERVAL` (V5-M2,
  RX-15); the guardian can cancel, a confidence interval wider than 2% is refused, and so is a price more than 5% from
  the moving average Pyth publishes with it (RX-27), so a push of a few seconds on thin venues moves a fill's price by
  at most that. An issuer that mints its coin and drives its price down reaches the rest of the index only through the
  fixed weights, about its own leg's value per fill (RX-15). Pyth's contract on Ethereum is upgradeable by Pyth's
  governance and verifies updates against Pyth's own set of five signing keys, not Wormhole's guardians (OP-PIP-132).
  Three of the five suffice, for a price and for a governance message alike, so those three can
  also upgrade Pyth's contract (`design/2026-10-18-pre-mainnet-readings.md`, section 1). The app says so on every
  index.
- **Rebalancing needs Pyth's Hermes, and Hermes needs a key.** Signed updates come from Hermes, which requires an
  API key. The contract does not care who fetches an update, so one keyed service can hand updates to
  any executor, but without one no index rebalances. Pyth sells the key as a data plan: $500 a month for crypto feeds,
  Tether Gold's and the five Ondo tokens' own among them, and $2,500 and up for the share feeds twelve Ondo legs use.
  Six of Ondo's stocks (TSM, AVGO, LLY, JPM, WMT, V) have only
  US-hours feeds, so an index holding one settles only while that market is open, or with the stock kept. A start
  reads every moving feed, and the 2 hours of notice and the 4-hour auction end before the market's next open, so no
  fill lands at a reopening near `MU_MIN` (RX-3). Such an index rebalances only in a session: a start late in one
  expires unfilled, and the keeper starts it so the auction's middle falls in one. Pyth's catalogue gives all six
  regular hours only, 09:30 to 16:00 New York time on trading days, with the
  exchange's holidays and half days, and gives the same schedule to the six share feeds named "24/7" (AMZN, SPCX, META,
  SKHY, MU, AMD); until Hermes' data, which needs the key, shows those six publishing outside it, treat all twelve as
  session-limited (RX-31).
  Since OP-PIP-132 an update's previous publish time is its own less a second, so Pyth admits only the message stamped
  exactly at `priceTime()`, and the hub's window is in effect one second (RX-59).
- **Wrapped legs rest on Wormhole.** They rest on the chain each copy comes from too. Wormhole runs delegated
  guardian sets: for BNB Chain, Kaia, NEAR, Sui, Arbitrum and Monad, five of seven named guardians suffice to mint, so
  11 of the 15 listed copies and 13 of those queued rest on five keys, not 13 of 19; upgrading a copy's code still
  takes a governance message (RX-6). A copy whose home chain shuts its bridge side redeems for nothing while priced as
  its coin: BTT's and SEI's copies left the list for that (RX-28, RX-32). Wormhole's guardians (13 of 19) can forge a bridge message, minting unbacked
  wrapped tokens or upgrading every wrapped token's code at once, with no timelock; that reaches the whole of every
  wrapped leg, beyond the turnover cap. The wrapped copies have no DEX liquidity: redeem pays them, and turning them
  into the coin needs Wormhole live. The app shows every index's wrapped share of value before it is created and to
  every holder (`design/2026-10-10-one-index-wormhole-legs.md`, section 3).
- **A collapsing coin can stop the fills.** Fixed weights keep buying a coin whose price falls, and units beyond
  `uint96` stop the fill rather than wrap, until the guardian keeps it (V5-L3). The figure: a growing leg whose target
  is more than 1e18 times its units makes every fill trade nothing (`design/2026-10-29-settlement-vectors.md`,
  section 3); a collapse by a factor of fifty against the rest still fills.
- **An issuer's corporate action is not accounted for.** An index holds fixed units per share and pays out only those.
  If an issuer mints tokens to every holder, as a stock split paid in tokens would, the index's new tokens belong to no
  share; if it burns them, that leg falls below its backing. Ondo does neither: its token's balance never changes,
  and each token tracks a multiplier of shares (`sValue`) that reinvested dividends raise and a split multiplies. So the
  five Ondo legs priced at the token's own feed are priced right, and the twelve priced at the share's feed are worth
  `sValue` times what the hub thinks: a small drift from dividends, which the turnover cap bounds, and after a split a
  rebalance that cannot clear until the guardian keeps that leg. The guardian keeps an affected leg out of any
  rebalance around a corporate action, which Ondo announces at least 24 hours ahead (CF-3,
  `design/2026-10-18-pre-mainnet-readings.md`, section 2).
- **Price ids are data the owner maintains.** The contracts cannot tell a wrong price id from a right one. Check each
  listing's feed description during its 2 days, while it can still be cancelled. An index copies its ids at creation,
  so a wrong id reaches only indexes created while it stood, and the guardian can keep that component at each
  rebalance.
- **Rebalances clear only when the moving value pays for the fill.** Small indexes on mainnet rarely rebalance, and a
  fresh index cannot rebalance until its own interval, 7 to 91 days, has passed since its creation. An unfilled auction expires, and for `REBALANCE_DELAY`
  afterwards (less a second, CR-I02) only the owner and guardian can restart it. A fill that would send nothing out, as
  on an empty or dust index, settles at `MU_MAX`, so nobody is paid for it (R14, XA-27).
- **An exit sent during the auction can be overtaken by the fill.** The executor picks the block, so it can order its
  fill ahead of a redeem or a guardian cancel it sees in the public mempool. No bound moves; during the auction, use a
  private relay (RT-02). Shares minted while a rebalance is pending share the outcome of any fill that lands after
  them, whatever the ordering.
- **The guardian can stall rebalancing.** `cancelRebalance` has no window and no rate limit, so a hostile or
  compromised guardian can cancel each proposal at the last second of its auction and hold rebalancing off while the
  index drifts from its weights. It moves no funds, holders redeem throughout, and the owner ends it by replacing that
  guardian: 7 days of notice the guardian cannot cancel, since it may only cancel its own removal (DA-12). A guardian
  can also stall without a cancel: a keep-mask rebalance that leaves a pair of components moving can clear `MIN_TRADE`
  on a sliver of the index. Its fill restarts only `MIN_REBALANCE_INTERVAL` for a rebalance without a keep mask, not
  the index's own interval, so the stall can outlast the guardian's replacement by up to a week (XS-3), and by a
  keep-mask auction the outgoing guardian left pending, `REBALANCE_DELAY` + `AUCTION_DURATION` more (RX-44); the owner and
  the new guardian can start a keep-mask rebalance then too, for an index that only settles with a component kept. While a replacement is pending, the owner cancels the outgoing guardian's
  keep-mask proposals, and monitors alert on `RebalanceStarted` with a non-zero `keepMask` (RT-07). The owner has only
  `REBALANCE_DELAY`, 2 hours, to cancel one before the guardian's own executor can fill it at `eta`.
- **Issuers can freeze components, and some can burn them.** WBTC can be paused by its custodian, and so can MANA,
  CHZ, SENT, FLUID, GALA, FET, SNX, PLUME and the Ondo tokens (through Ondo's pause manager) by theirs (RX-55). After an
  issuer burns an index's balance, issue refuses until the leg is topped up, so no deposit refills the hole for earlier
  holders (RX-8). A token that blocks only its sender, as Tether Gold's does, cannot have a fill buy into a leg the index
  can no longer send: the fill reverts `CannotSendOut` and the guardian keeps the leg (RX-12). Ondo can end a stock
  token by an issuer redemption paid only to KYC'd redeemers, on at least 30 business days' notice: holders still in at
  the date lose that leg, so the app tells them to exit first (RX-29). Tether Gold and Ondo's stocks can blacklist a holder, an index included, and destroy
  its balance, and the admins of H, PLUME, SNX and SYRUP can burn or move any holder's balance without a blacklist
  (`design/2026-10-18-token-source-reading.md`); the app names them. A paused component makes `redeem`, the zap and any fill that moves it revert; `redeemSkipping`, `claim`
  and the guardian's keep mask are the recourse, and a permanently frozen component needs the keep mask at every
  rebalance. A destroyed balance is lost to the index's holders.
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
- **Fees in shares only.** Mint and redeem fees are minted as shares to the creator, the platform and a referrer; no
  fee ever moves a component, and the platform's policy is zero until the owner sets one.
- **The streaming fee is charged on the supply that was there.** Every issue, redeem, settlement and `accrueFees` first
  mints the fee accrued since the last accrual, and the clock restarts on every one of them, one that mints nothing
  included, so a dust supply left idle never charges that time to the next minter (XS-1); what that forgoes is under
  one share per call. An integer scale backs the supply by up to `supply · units / 1e36` raw units less per accrual, a
  part in the scale (1e18 at first, less as fees accrue) of a leg, which stays in the index (RX-62). A lifetime's gap is capped just under the whole index, and a second
  one, which would shrink the scale to zero, is not charged. `lastAccrual()` and `pendingStreamingFee()` show the clock
  and what an accrual now would mint.
- **The basket builder is one custody point.** Every user's escrow of a token sits in one address. An issuer that
  blacklists or pauses the builder freezes every escrow of that token until it lifts the block, and one that can
  destroy a blacklisted balance, as Tether's contracts can, can take them all. The builder sends itself one unit of a
  token before it credits an escrow of it, so a deposit, a buy or a redeem into a builder already blocked is refused
  (XS-10); a block that comes later traps what is already there. The app should check the builder's blocked status on
  Tether-pattern tokens before offering it: `isBlackListed(builder)` on USDT, and on Tether Gold its own check,
  `isBlocked`, since XAUT is not USDT and names it differently (RX-60). A holder whose exit through the builder is refused
  redeems on the index itself, with `redeemSkipping` and `claim` for a frozen leg. The probe does not catch a token
  that charges its sender a fee on transfer, which the whitelist excludes (RX-41); router strays swept back during a
  call are booked to that call (RX-45); and an escrow owner's exit ignores a blacklist on that owner, so an issuer's
  only lever over an escrow is freezing the whole builder (RX-51).
- **Airdrops, rewards and governance votes** that accrue to tokens held by an index cannot be claimed or used; by design
  there is no admin who could sweep them.
- **A hooked V4 pool cannot be routed through.** The zap rejects any V4 route whose hops carry hooks or hook data, so a
  component whose only V4 depth sits behind a hook is reachable on V3 only.
- **`PYTH` cannot be repointed.** It is an immutable of the one implementation every index clones, and on Ethereum the
  deploy accepts only `0x4305…`. If that contract stops verifying updates, rebalancing ends for good on every index;
  issue, redeem, `redeemSkipping` and claims read no price and keep working. Pyth's written confirmation that this
  address stays served is a pre-mainnet item (RX-25).
- **An executor that also builds the block sees further.** Under ePBS (EIP-7732) a builder that is also the executor
  can commit to a block and withhold its payload, seeing past `PRICE_LAG` the way V5-L1 bounds (RX-65).
- **A `tokenIn` that calls back into the zap is unsupported**, alongside fee-on-transfer currencies. The zap pre-funds
  the Universal Router with exactly a leg's cap and sweeps it back within the same `execute`; the pre-fund is the bound
  (CR-I14, RT-11). Mint and burn currencies are the user's choice, so the app should offer only USDC and USDT.
- **Zap gas grows with components and hops, and nothing on chain bounds it.** See the Gas note in [integration.md](integration.md): about 35 components is
  the zap's practical limit. The in-kind path is what fits at 100.
- The zap is pinned to **Universal Router 2.0.0** rather than the 2.1.x line, whose command inputs carry an extra
  per-hop price array. Moving to a newer router means a new zap; the hub and factory do not depend on it.
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`), which Ethereum runs. Re-check before deploying to any
  other chain.
