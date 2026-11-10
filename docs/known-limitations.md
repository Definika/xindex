# Known limitations

What the contracts do not protect against, and what an app built on them has to show its users.

- **A lone executor keeps the index's distance from its weights.** No contract reads a price: the executor names
  the units a rebalance settles at, and the index accepts them when their weighted gain clears a bar that falls
  through the auction. Executors compete by filling earlier, at a higher bar, which leaves more with the holders. With
  an honest executor bidding, the keeper first, holders keep the whole distance less its costs. With none, an
  executor waits for the auction's last second and takes it out of the holders' value: 0.3 to 0.6% of the index in
  an ordinary week, up to about 1.8% after a week in which a tenth of the index halved, 5.0% in one fill after one
  coin of two doubled, 8.7% after it tripled. It is what a fee-less constant-weight pool loses to arbitrage, and no
  fill can take more; on its weights an index has nothing to take
  (`design/2026-11-10-oracle-free-rebalance.md`, sections 3 and 6). A fair price therefore needs a bidder, where a
  price feed gave one whoever filled. An index created off its weights carries its distance from its first day:
  units and weights are the creator's to name, and no contract can compare them without a price. A creator could name
  units far from the weights, let others mint, and fill its own auction: 15.5% of a 50/50 index created 90/10 by
  value in one fill, at the worst a fifth of an index per fill. That is why only wallets the factory's owner approved
  create an index (`setApprovedCreator`): the team creates on the weights, at the app's prices, and the app shows
  every index's coins against its weights.
- **No contract reads a price.** Nothing checks what a coin is worth, and nothing needs to: a fill is judged on
  units. Whatever the executor offers, one fill sends out at most 20% of each component's own units and at most
  doubles a component (V5-M2, RX-15), at most once every `MIN_REBALANCE_INTERVAL`, and it must raise the weighted
  product of the units. So a coin that is worthless and free to mint, by its issuer or through a forged bridge
  message, takes a bounded share of the rest per fill: a coin at 10% of an index, at most 5.8% of the other
  components. Valuing an index is the app's job, from sources of its own.
- **One fill may not land on the weights.** The unit caps bound a fill, and the gain an executor is credited with is
  a little under what the market pays it for the last few percent, so a fill lands about 96% of the way in an
  ordinary week and about half the way after a quarter's drift. The next rebalance takes the rest.
- **Wrapped legs rest on Wormhole.** They rest on the chain each copy comes from too. Wormhole runs delegated
  guardian sets: for BNB Chain, Kaia, NEAR, Sui, Arbitrum and Monad, five of seven named guardians suffice to mint, so
  11 of the 15 listed copies and 13 of those queued rest on five keys, not 13 of 19; upgrading a copy's code still
  takes a governance message (RX-6). A copy whose home chain shuts its bridge side redeems for nothing:
  BTT's and SEI's copies left the list for that (RX-28, RX-32). Wormhole's guardians (13 of 19) can forge a bridge message, minting unbacked
  wrapped tokens or upgrading every wrapped token's code at once, with no timelock; that reaches the whole of every
  wrapped leg, and through a fill the bounded share of the rest described above. The wrapped copies have no DEX liquidity: redeem pays them, and turning them
  into the coin needs Wormhole live. The app shows every index's wrapped share of value before it is created and to
  every holder (`design/2026-10-10-one-index-wormhole-legs.md`, section 3).
- **A collapsing coin is still bought.** Fixed weights keep buying a coin whose price falls: an executor is paid to
  deliver it, at most doubling its units per fill (RX-15). Units beyond `uint96` stop a fill rather than wrap
  (RX-61). The guardian stops the buying by starting a rebalance with the coin kept (V5-L3). A two-component index
  cannot keep one, since a keep mask must leave two moving. Holders redeem in kind throughout.
- **An issuer's corporate action is not accounted for.** An index holds fixed units per share and pays out only those.
  If an issuer mints tokens to every holder, as a stock split paid in tokens would, the index's new tokens belong to no
  share; if it burns them, that leg falls below its backing. Ondo does neither: its token's balance never changes,
  and each token tracks a multiplier of shares (`sValue`) that reinvested dividends raise and a split multiplies. No
  contract prices an Ondo token, so nothing misprices it: executors price the token the market trades. The guardian
  still keeps an affected leg out of any rebalance around a corporate action, which Ondo announces at least 24 hours
  ahead (CF-3, `design/2026-10-18-pre-mainnet-readings.md`, section 2).
- **Rebalances clear only when the distance pays for the fill.** An executor fills when the index's distance from its
  weights covers its gas and its swaps, so small indexes on mainnet rarely rebalance, and a
  fresh index cannot rebalance until its own interval, 7 to 91 days, has passed since its creation. An unfilled auction expires, and for `REBALANCE_DELAY`
  afterwards (less a second, CR-I02) only the owner and guardian can restart it. When the distance is under an
  executor's costs, anyone may still fill at the auction's last second with a gift of the bar's floor, 4.77e-7 of
  the index, which pays the holders and restarts the interval.
- **A dust index's units can be walked.** An index without shares does not rebalance (R14, XA-27). On a supply
  worth nothing, though, a fill's gain costs nothing, so whoever holds a dust index's shares can move its units off
  its weights over several intervals. A later minter deposits at those units, in kind and fairly, and the next
  auction pays the distance to whoever fills first. The app shows an index's components against its weights before
  it offers a mint.
- **An exit sent during the auction can be overtaken by the fill.** The executor picks the block, so it can order its
  fill ahead of a redeem or a guardian cancel it sees in the public mempool. No bound moves; during the auction, use a
  private relay (RT-02). Shares minted while a rebalance is pending share the outcome of any fill that lands after
  them, whatever the ordering.
- **The guardian can stall rebalancing.** `cancelRebalance` has no window and no rate limit, so a hostile or
  compromised guardian can cancel each proposal at the last second of its auction and hold rebalancing off while the
  index drifts from its weights. It moves no funds, holders redeem throughout, and the owner ends it by replacing that
  guardian: 7 days of notice the guardian cannot cancel, since it may only cancel its own removal (DA-12). A guardian
  can also stall without a cancel: a keep-mask rebalance that leaves a pair of small components moving can be
  filled with a gift to that sliver. Its fill restarts only `MIN_REBALANCE_INTERVAL` for a rebalance without a keep mask, not
  the index's own interval, so the stall can outlast the guardian's replacement by up to a week (XS-3), and by a
  keep-mask auction the outgoing guardian left pending, `REBALANCE_DELAY` + `AUCTION_DURATION` more (RX-44); the owner and
  the new guardian can start a keep-mask rebalance then too. While a replacement is pending, the owner cancels the outgoing guardian's
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
  rebalance. A destroyed balance is lost to the index's holders. Issue does not test that the index can still send each
  leg, as a fill does (RX-12): a minter can deposit into a leg a sender-blocking blacklist has already frozen for the
  index, and hold a claim on it that cannot be paid until the issuer lifts it (RZ-25). The owner's call of 2026-11-02
  leaves the hub as it is, since a probe on every issue costs gas on every leg and code the hub's 98 spare bytes may not
  hold: the app checks first, simulating a send of each coin from the index before it offers a mint, and a direct
  caller checks for itself.
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
  and what an accrual now would mint. The yearly rate is a ceiling: each accrual charges the rate for the time since
  the last one, on what is left, and anyone can call `accrueFees`, so the more often it runs the less a year takes: at
  500 basis points, 5.00% with one accrual a year and 4.88% with one a day. Holders never pay more than the rate.
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
- **A `tokenIn` that calls back into the zap is unsupported**, alongside fee-on-transfer currencies. The zap pre-funds
  the Universal Router with exactly a leg's cap and sweeps it back within the same `execute`; the pre-fund is the bound
  (CR-I14, RT-11). Mint and burn currencies are the user's choice, so the app should offer only USDC and USDT.
- **Zap gas grows with components and hops, and nothing on chain bounds it.** See the Gas note in [integration.md](integration.md): about 35 components is
  the zap's practical limit. The in-kind path is what fits at 100.
- The zap is pinned to **Universal Router 2.0.0** rather than the 2.1.x line, whose command inputs carry an extra
  per-hop price array. Moving to a newer router means a new zap; the hub and factory do not depend on it.
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`), which Ethereum runs. Re-check before deploying to any
  other chain.
