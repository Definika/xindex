# Xindex v5: creators choose the percentages, Pyth prices the rebalance

Status, 2026-10-05: phase 1 built on branch `v5-custom-weights` (uncommitted), deployed nowhere. The internal review of
the new surface is recorded in `audit/2026-10-05-v5-review.md` (ids `V5-…`), and its findings are fixed. The parameter
replay (section 8) and an external audit come before any deployment.

## 1. The decision this records

v5 offers one product: indexes whose creators choose each coin's percentage, rebalanced back to those percentages on
their own (the owner's calls on 2026-10-05: "we move to custom chosen percentages", and custom percentages only, the
market-cap index retired from new deployments as v3 was). That needs prices: an index holds amounts of coins, a
percentage is a share of value, and only a price turns one into the other. A price-free auction cannot do it, because
with targets that move with the market its band has to be as wide as the market's moves, and a lone executor keeps the
band.

It changes three recorded decisions, and says so:

- **"No price in any contract"** becomes "no price in any contract but `WeightedHub`'s settlement". The factory, the zap,
  `MintRequests` and the vaults stay price-free, and so do an index's issue, redeem and claims.
- **"Uncapped market-cap weighting is the only methodology"** is replaced: v5's only methodology is the creator's fixed
  weights. The v4 market-cap code stays in the tree until its retirement record (section 11).
- **v4 replaced v3's Chainlink pricing.** v5 brings an oracle back, for a different mechanism (section 5), learning from
  what v3's audits measured (section 7).

Settled with the owner on 2026-10-05:
- Weights are fixed at creation, like the coin list. Nobody, the creator included, can change them later; new weights
  mean a new index.
- Pyth is the one oracle. Chainlink alone was considered and refused for its coverage (11 of the 52 coins), and so
  was Chainlink as a second check on the coins it covers, which would have refused a fill when the two disagreed.
- Phase 1 holds Ethereum ERC-20s; vault coins follow (section 9).

## 2. The oracle: Pyth, because Chainlink covers too few coins

Chainlink's Ethereum feeds (its directory, read 2026-10-05) cover 11 of the 52 coins on the approved list: ETH, BTC
(WBTC through WBTC/BTC), UNI, LINK, AAVE, SKY, CRV, ARB, BNB, SOL and AVAX, and MATIC but not POL. A custom-weight
product on Chainlink alone could offer a fifth of the list.

Pyth's catalogue (Hermes, read 2026-10-05) has a USD feed for all 52 by symbol. Pyth is live on Ethereum at
`0x4305FB66699C3B2702D4d05CF36551390A4c69C6`: an ERC-1967 proxy, version 1.4.6, Wormhole chain id 2, update fee 0, read
on chain on 2026-10-05 (`MainnetAddresses.PYTH`; `testFork_pythIsPyths` pins the proxy's code and checks the parse
answers).

Pyth is a pull oracle: nobody pushes prices to Ethereum (the stored BTC/USD answer was 74 days old), so whoever settles
a rebalance brings a signed update and pays its fee. That suits this design, which reads prices only in the settling
transaction.

**Access.** Since Pyth's Core upgrade of 2026-08-26, Hermes, the service that hands out signed updates, needs an API key
(a free trial, then a paid plan), and so does its Benchmarks history. The contract does not care where a signed update
comes from, so one keyed service, the app's backend for instance, can fetch updates and hand them to any executor. But
a rebalance now needs someone with a key; that is an operating cost and a dependency the owner should weigh.

**What holders then trust.** Pyth's publishers (exchanges and trading firms) feed its aggregate, Pyth's own set of five
signing keys signs it across (since OP-PIP-132 of 2026-08-26; Wormhole's guardians did before), and the Pyth contract
on Ethereum is upgradeable by Pyth's DAO, which upgraded it in place on 2026-08-26. The app says so on every index, as it labels WBTC's custodian. Section 6 bounds what a broken price can cost.

**Per coin, before listing.** Each coin's price id is checked like its address: the feed's description names the
asset. Read on 2026-10-05, every id names its coin, with two choices and one open question:
- WETH takes ETH/USD: WETH redeems one for one on chain, and ETH/USD is the deepest feed.
- WBTC takes WBTC/USD, not BTC/USD: it is custodial, so its own price is what catches a depeg.
- GRAM is open: Pyth has both "GRAM / US DOLLAR" and "TONCOIN / US DOLLAR", and our GRAM token is bridged Toncoin.
  It stays out of the table until the owner confirms which feed is Toncoin.

## 3. Where it lives: its own factory

v5 is custom-only, so it has its own factory, `WeightedIndexFactory`, which clones one template, `WeightedHub`. Its
governance is `IndexFactory`'s without the reference supplies: the owner proposes listings and guardian changes behind
`LISTING_DELAY` (2 days) and `GUARDIAN_DELAY` (7 days), anyone executes within `PROPOSAL_WINDOW` (7 days), the
guardian cancels listings, delists and cancels its own removal, and ownership cannot be renounced.

The factory stores data, never prices. A listing carries the token's Pyth price id, and its decimals are read once,
when the listing is proposed, so the delay shows them in public before they count and no index ever calls a token to
price it (RT-01). An index copies its ids and decimals at creation, so a later relisting reaches only new indexes and no
key can repoint an existing index's prices.

`IndexZap` and `MintRequests` are v4's, unchanged, deployed against this factory: they reach an index only through
`isIndex` and the functions every index shares (`test/WeightedZap.t.sol` mints, burns and escrows a weighted index
through them). `script/DeployWeighted.s.sol` deploys the three, with `Deploy`'s checks on the owner, the guardian and
the market, now shared in `script/DeployChecks.sol`, and refuses Pyth as either role.

Sizes: `WeightedHub` 22.0 KB, `WeightedIndexFactory` 8.7 KB.

## 4. Creating an index

`createIndex(name, symbol, components)`, each component `{token, weight, units}`:
- 2 to 100 distinct whitelisted tokens, no two on one Pyth price id: Pyth fills only the first of two equal ids, so
  such an index could never settle (V5-M1);
- weights in basis points, each at least 1, summing to exactly 10,000;
- units each in `[MIN_RAW_UNITS, MAX_UNITS]`, as v4;
- the CREATE2 salt commits to the creator, the name, the symbol and every component's token, units, weight, price id
  and decimals, so the address commits to its contents (`test_LR05_theAddressCommitsToEveryField` varies each alone).

The app computes the starting units from the chosen percentages at current prices. The factory does not check them
against a price, so creation never depends on an oracle. An index whose units do not match its weights is visible as
such in the app, and the first rebalance brings it to its weights, within the turnover cap.

## 5. `WeightedHub`

Issue, redeem, `redeemSkipping`, claims, the backing invariant, the recipient checks, the reentrancy guard and the
`onlyInitialized` guard are `IndexHub`'s, unchanged. **Issue, redeem and claims never read a price**
(`test_issueAndRedeemNeverCallPyth` runs them with Pyth's code replaced by an invalid opcode), so an oracle outage or a
wrong price can never block an exit or misprice a mint: minting stays in kind.

Rebalancing keeps `IndexHub`'s shape (start, notice, falling auction, executor callback, backing post-check, keep
mask, guardian cancel and restart hold-off) and replaces the band with prices read at settlement:

1. **Start.** Anyone, once `MIN_REBALANCE_INTERVAL` (7 days) has passed since the last fill; the owner or guardian
   also with a keep mask, or earlier than strangers after a cancel or expiry, as v4. A start reads no price.
2. **Notice.** `REBALANCE_DELAY` (2 hours), then the auction runs `AUCTION_DURATION` (24 hours).
3. **Prices at the fill.** `executeRebalance(data, priceUpdate[, maxAmountsIn])` is payable and forwards its whole
   value to Pyth as the fee. The hub fixes the moment, `priceTime()`: T is one slot back, `PRICE_LAG` (12 seconds)
   before the block, and it asks Pyth's `parsePriceFeedUpdatesUnique` for each moving feed's update published in
   [T, T + 11]. Pyth returns an update only when the one before it was published before T
   (`minAllowedPublishTime > prevPublishTime`, read in Pyth's source on 2026-10-05), so an executor has one price per
   component in each block and cannot pick among many; it still chooses whether to fill in a block, seeing that price a
   slot ahead. The minute this first pinned was known two minutes ahead (V5-L1). The hub
   checks the ids and publish times Pyth returns rather than trusting them. A price is refused if it is not positive,
   if its exponent is outside [-18, 0], if it comes to more than `MAX_PRICE`, or if its confidence interval is wider
   than `MAX_CONFIDENCE` of the price. A price is used as USD per raw unit scaled by 1e36,
   `price · 10^(36 + expo − decimals)`.
4. **Targets.** For the moving set M, value `V = Σ u_i·p_i`, and each target is `t_i = ⌈w_i · V / (W_M · p_i)⌉`, where
   `W_M` is the moving weights' sum. Kept components are neither priced nor read, and keep their units.
5. **Turnover cap, in units.** If a shrinking leg would give up more than `MAX_TURNOVER` of its own units, every leg
   moves the same share `s = min_i ⌊MAX_TURNOVER · u_i / (u_i − t_i)⌋` of the way. A fill never sends out more than a
   fifth of any component, whatever any price says. The first cap was 20% of the moving value at the settling prices,
   which the prices it guards against measured: two wrong feeds on an index far from its weights took 89% of it (V5-M2).
   A fill whose release, after the cap, is worth less than `MIN_TRADE` (0.1%) of the moving value reverts
   `NothingToRebalance`, so a fill that changes nothing cannot restart the interval; a keep mask must leave two
   components moving (V5-L2). The minimum is checked on `s` times the release: checked before the cap, a capped fill
   could trade a fifth of it and still restart the interval (V5R-1, `audit/2026-10-07-v5-logic-review.md`).
6. **The auction.** A shrinking leg moves `⌊s · (u − t)⌋`; a growing leg `⌈μ · s · (t − u)⌉`, with the factor `μ · s`
   itself rounded up. `μ` falls linearly from `MU_MAX` to `MU_MIN` and rounds up. At the settling prices the executor
   therefore delivers at least `μ` times the value it takes (`testFuzz_R04_theExecutorDeliversMuTimesWhatItTakes` and the
   invariant suite check exactly that). Starting above 1 means that when Pyth lags the market in the executor's favour,
   competing executors hand that gain to the holders. A lone executor keeps at most `(1 − MU_MIN)` of the traded value,
   plus the gap between Pyth and the market. A fill that would send nothing out, as on an empty index, settles at
   `MU_MAX`.
7. **Rounding** goes the holders' way, as in `IndexHub` (SA-07): what leaves rounds down, what comes in rounds up, and
   the settlement stands only if the backing invariant holds with the new units and the whole of `amountsIn` arrived on
   top of what the index held.

After a fill below `μ = 1`, the growing legs sit slightly under target; the next rebalance closes the gap, so drift
heals and does not compound (`test_repeatedFillsFollowThePrices`).

`previewRebalance(prices)` lets an executor simulate a fill from Pyth prices it read off chain; only the payable path
reads Pyth.

## 6. What a wrong price can cost

- **A lagging price** (the market moved, Pyth has not yet): bounded by the auction. With competition the fill lands
  where the market is; a lone executor gains the lag on the traded value only. An executor also holds a free option of
  a slot: it sees each block's price twelve seconds before it chooses whether to fill in it (V5-L1).
- **A wrong price on one coin of an index on its weights** trades against itself: the index sells what a price
  overstates and buys what it understates. Off its weights it need not (V5-M2), which is why the cap counts units.
- **A broken or malicious feed set** (a compromised publisher set, guardian set or Pyth upgrade): one fill sends out at
  most a fifth of each component it sells, one fill a week, and the index may receive little for it. The guardian
  can cancel an auction, but a bad price can be used in its first block, so the bound, not the guardian, is the
  protection. Holders redeem in kind throughout, since redeem reads no price.
- **No price** (a feed stops, confidence too wide): the fill waits. The owner or guardian starts a rebalance that keeps
  the dead component; nothing else is affected.
- **A collapsing coin**: fixed weights keep buying it, so its units grow; a coin that falls about a thousand times
  from units near `MAX_UNITS` asks for more than `uint96` holds, and the fill stops rather than wraps until the
  guardian keeps it (V5-L3, a known limitation).
- **A 24-decimal coin needs an exponent of at least −12.** `WeightedPricing` scales a price by
  `10^(36 + expo − decimals)` and refuses one that would need a negative power, so a vault coin with 24 decimals,
  NEAR's, cannot be priced from a feed whose exponent falls to −13 or lower. Pyth's crypto feeds use −8. Should one
  fall that far, every fill of an index holding the coin reverts until the guardian keeps it, as with a collapsing
  coin (V5R-I1, a known limitation).
- **Uniqueness is Pyth's.** The hub checks the ids and the window Pyth returns, but Pyth does not return the previous
  publish time, so that the update was the first is Pyth's to keep (V5-I1).

## 7. What v3's audits measured, and what changed

- **L-06** (2026-09-23): Chainlink answers sat 14 to 24% off the market for UNI, LINK and AAVE during crashes, so v3's
  settlement floor, 0.875 of value at feed prices, let a lone executor keep more than its documented 15%. Here the
  executor's take is bounded by `MU_MIN` on the traded value and by the turnover cap on the index, and a Pyth price
  updates several times a second instead of on a 0.5 to 2% deviation threshold.
- **DA-05** (2026-09-19): v3 snapshotted targets at the start and settled up to three days later, so price drift
  between the two went unbounded. Here targets come from prices one slot before the settling block.
- **RT-01**: no component's contract is called to price it; decimals are recorded at listing.
- Selective prices: a pull oracle lets the caller choose which signed update to bring. The pinned slot removes the
  choice among updates; the choice of block remains (V5-L1).

## 8. Parameters (to be checked by a replay study before launch)

| Constant | Value | Why |
| --- | --- | --- |
| `MIN_REBALANCE_INTERVAL` | 7 days | As v4 |
| `REBALANCE_DELAY` | 2 hours | Targets come from settlement prices, so notice is for executors, not for holders' exits |
| `AUCTION_DURATION` | 24 hours | As v4 |
| `MU_MAX` / `MU_MIN` | 1.02 / 0.98 | 2% for swap costs and Pyth's lag either way |
| `MAX_TURNOVER` | 20% of each component's units | A coin doubling at a 50% weight sheds a quarter, so two fills; a lying feed takes at most this |
| `MIN_TRADE` | 0.1% of moving value | Below it the index is on its weights; v4's `MIN_BAND` |
| `MAX_CONFIDENCE` | 2% of price | Refuses prices Pyth itself is unsure of |
| `PRICE_LAG` | 12 seconds | One Ethereum slot: one price per block, seen at most a slot ahead |
| `MIN_COMPONENTS` | 2 | One component alone is always on its weight |

Before launch, a replay of Pyth's history against market minute closes on the listed coins (as v3's L-06 replay did
with Chainlink) sets `MU_MIN`, `MAX_TURNOVER` and `MAX_CONFIDENCE` from evidence. It needs a Pyth API key.

## 9. Phase 2: vault coins

Pyth covers BNB, TRX, SUI and the other vault coins. Holding them needs the three-step hybrid fill (Stage B spec) with
prices; the vaults, proofs and state verifiers carry over unchanged.

## 10. What a mainnet fork showed (2026-10-06)

`test/fork/WeightedHub.fork.t.sol` runs v5 on a fork near the chain head, with real tokens and real Uniswap pools and
only Pyth stood in. It lists the coins of `script/PythIds.sol`: 30 when this was measured, 27 since the owner's calls
of 2026-10-06 dropped OKB, BGB and GT, the three below that no fill can trade or that are being retired.

- **Every coin works in kind.** All 30 issue into one index, rebalance with real transfers of every token, and redeem
  to the last unit. A 30-coin fill cost 4.6M gas, before Pyth's own verification.
- **24 of the 30 trade on Uniswap.** That many sell $1,000 within 2% of a $10 sale, along the route that pays best for
  the size; most are within 0.5%, and ENA, ONDO and SKY within 0.03%. Six do not:
  - OKB, STRK, ARB and CAKE are too thin, which the admission report's depth column already showed;
  - BGB and GT have no Uniswap V3 route at all.

  An index holding any of these is minted in kind or through `MintRequests`, not through the zap, and rebalanced by
  executors that hold inventory; the app says so when a creator picks one.
- **The zap works on a weighted index.** On a 24-coin index, minting two tokens with USDC cost $2,023.67 and burning them
  returned $2,004.91, about 0.9% for the round trip.
- **Filling pays.** A Uniswap rebalancer filling a $52,000 index at the auction's end, at the pools' own prices, kept
  $13.55 after fees and slippage, so rebalances get filled without anyone being paid to.
- **The drills hold on real tokens:**
  - WBTC paused by its real owner: holders leave with the rest and a claim, the guardian rebalances around it, and the
    claim pays once it is unpaused;
  - a feed going silent stops the fill until the guardian keeps that coin;
  - a price a hundred times low sends out at most a fifth of each coin, and the guardian cancels;
  - an unfilled auction expires and the owner restarts it.

## 11. What is done and what remains

Done (2026-10-05):
- `src/WeightedHub.sol`, `src/WeightedIndexFactory.sol`, their interfaces and ABIs; Pyth's interface vendored at
  `2bb0eb54b2b3af8854d0c26f3884c28a0fce0802`.
- Tests: the factory (42), the hub (25), its rebalance (41: exact settlements pinned to the raw unit, every price
  refusal, the pinned slot, the unit cap under wrong prices, keep masks, reentrancy through the executor and through
  Pyth, a hundred components), an invariant suite (backing, claims, the μ bound, the unit cap, preview against fill),
  the zap and `MintRequests` against a weighted index (5), and the deploy script (5). Coverage 100% on every new file;
  21 mutants (floors for ceilings, no cap, μ rounded down, a wider window or the old minute, no confidence or
  publish-time check, a kept feed read, each review fix removed) each fail a test.
- The internal review (`audit/2026-10-05-v5-review.md`): 2 medium, 3 low, 4 informational, each fixed or documented.
- `test_V5I4_onlyTheWeightedHubReadsAPrice`: no other file names Pyth's contract or its parse.
- forge fmt, build, lint, Aderyn and Wake clean.

Remaining before any deployment:
- The fork suite settles against a stand-in Pyth; settling against Pyth's real contract on a real signed update, and
  its real gas, need a Pyth API key.
- The parameter replay (section 8).
- `script/ConfigureWeighted.s.sol`, the listing script over `script/PythIds.sol`, and GRAM's feed.
- AGENTS.md, README and ARCHITECTURE rewritten for v5. The v4 retirement record is written
  (`audit/2026-10-06-v4-retirement.md`): `IndexHub`, `IndexFactory` and their ABIs were deleted on 2026-10-06, and the
  docs carry a note until they are rewritten.
- External audit.
