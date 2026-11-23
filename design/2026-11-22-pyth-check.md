# Pyth's check on a fill, and an index created on its weights (2026-11-22, 2026-11-23)

## The calls

- **2026-11-22, about 01:45.** The owner: "i think we have to add prices", then, asked how strict, "there is no rules i
  am looking for best solutions to our problems". Offered the choices, the owner took **an oracle that can only
  refuse**, and **Pyth** as that oracle. It reverses "No oracle" of 2026-11-10 in part: no issue, redeem or claim reads a
  price, and the rebalance is still judged on units first (`design/2026-11-10-oracle-free-rebalance.md`); a fill must
  now also pass a check at Pyth's prices. The chosen option also promised that `createIndex` would refuse units far from
  the weights, which was not built that night.
- **2026-11-23.** Shown that a creator names each component's units when it creates an index, the owner: "i don tthink
  that correct way of calculating price". Shown the order of the work, the owner chose to finish the Pyth check first,
  in this branch, with the creation check (`feat/pyth-check`, from the Ondo lists of `384f5dd`; the work of the night of
  2026-11-22 was copied from the main checkout, which still holds it uncommitted).
- **2026-11-23, Ondo's tokens.** Most of Ondo's 352 tokens have no price on chain: Pyth prices nine of them as tokens,
  and Ondo publishes the multiplier that turns a share's price into a token's for few (below). Offered to refuse a fill
  that moves such a token, or to skip the check for it, the owner chose a third: **each Ondo token at its share's
  price**, the multiplier left out, with the guardian keeping the leg out of a rebalance around a corporate action, the
  procedure the owner approved on 2026-10-18 (`design/2026-10-18-pre-mainnet-readings.md`, section 2). Skipping the
  check for a fill that moves an unpriced token was refused because an executor could skip it at will, by moving one
  raw unit of such a token; refusing those fills would have kept a stock-heavy index from ever rebalancing its stocks.

## What a fill must do

1. **Units, as before.** Every leg inside its caps, and the weighted gain `⌊Σ w_i · L(x_i) / 10,000⌋` at or above the
   bar (`WeightedMath.settlement`). Nothing about this changed.
2. **Value, new.** At Pyth's prices the fill must bring in at least what it takes out, less a tolerance that rises
   along a straight line from nothing at the auction's first second to `MAX_ORACLE_TOLERANCE`, 2%, at its last
   (`WeightedMath.oracleCheck`, `oracleToleranceAt`; `BelowOracleValue`). A leg whose units do not change is not priced
   and counts for nothing.

The prices are read through `PythPrices`, which the factory deploys with the implementation and every index reads
(`PRICES`):

- Each value leans against the executor: a leg the fill takes out at the price plus its confidence, rounded up; a leg it
  brings in at the price less it, rounded down.
- A price older than `MAX_PRICE_AGE`, 60 seconds, not positive, or no wider than its confidence values nothing, and the
  fill that needs it reverts (`StalePrice`, `UnusablePrice`). Pyth on these chains is a pull oracle: a filler posts
  Pyth's update itself, in the fill's transaction or the one before it.
- A token's decimals are the ones its listing recorded. A token's feed is the factory's, set by the owner behind
  `LISTING_DELAY`, executable by anyone within `PROPOSAL_WINDOW`, cancellable by the owner or the guardian
  (`proposePriceFeed`, `executePriceFeed`, `cancelPriceFeed`), and of one of three kinds: `Token` (the feed prices one
  whole token), `Vault` (an ERC-4626 token whose feed prices its asset, at `convertToAssets`) and `Multiplier` (the feed
  prices a share and the token reports `multiplier()` shares, as Coinbase's stock tokens on Base do). A token with no
  feed stops a fill that moves it (`NoPriceFeed`).
- The factory does not ask Pyth's contract whether it knows a feed (since 2026-11-23). It did, and BNB Chain's fork
  suite found that Pyth's contract knows a feed only once someone has posted an update of it on that chain: BNB
  Chain's had never stored 343 of the 364 feeds its list needs, ZEC's, STABLE's and most of the Ondo stocks', so none
  of those could have been proposed. A creation and a fill post their own updates, which makes the feed known there,
  and a wrong id can only refuse them. A feed of a kind other than `None` must name an id, and one of kind `None` none
  (`InvalidPriceFeed`).
- `script/PriceFeeds.sol` names every listed token's feed on the three chains, and `ConfigureWeighted` proposes them.

**What it buys.** On units alone a lone executor at the last second keeps the index's distance from its weights: 0.48%
of an index after one coin of four rose a quarter, 5.0% after one coin of two doubled, 8.7% after it tripled (the
exact model, `design/2026-11-10-oracle-free-rebalance.md`). Under the check it keeps at most the tolerance of what it
trades, measured at Pyth's prices: nothing at the auction's start and 2% at its end. Executors still compete by
filling earlier, now also against a smaller tolerance.

**What it cannot do.** It can stop a fill, as a cancel can; it can never pass a fill the units refuse
(`test_aWrongPriceCannotPassAFillTheUnitsRefuse`), and no issue, redeem or claim reads it
(`test_exitsAndMintsReadNoPrice`): a price that is stale, missing or hostile, or Pyth's keys signing a false one, can
hold a rebalance off, never take holders' funds and never block an exit.

## Ondo's tokens

- Nine are priced at Pyth's own feed of the token ("… ONDO TOKENIZED STOCK"): NVDAon, AAPLon, GOOGLon, MSFTon, TSLAon,
  HOODon, MSTRon, COINon and CRCLon. The other 343, on each of Ethereum and BNB Chain, at their share's feed, as
  `Token` (`script/PythIds.sol`, `script/PriceFeeds.sol`).
- An Ondo token tracks `sValue` shares, a multiplier that reinvested dividends raise and a split multiplies (CF-3). Ondo
  publishes it in its `SyntheticSharesOracle` (`0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` on Ethereum,
  `getSValue(token)`) for few tokens: of the first sixty of the list read on 2026-11-23, three (TSLAon at 1.0, SPYon at
  1.0095, QQQon at 1.0041), the rest `AssetNotFound`.
- At its share's price the check undervalues such a token by its multiplier, about 1% on SPYon. A leg the fill sells
  is credited that much less, so the executor may keep that much more of that leg, within the bar and the caps; a leg
  it buys must bring that much more, so such fills slow rather than lose. A split moves the multiplier tenfold: Ondo
  announces each corporate action at least 24 hours ahead, and the guardian keeps the leg out of every rebalance around
  it.

## An index created on its weights

- `createIndex`, on a factory with an oracle, values each component's units at Pyth's prices, each as arriving, and
  requires each leg's share of the new index's value to lie within `MAX_WEIGHT_DEVIATION`, 5%, of its weight, relative
  to the weight (`OffWeights(token, weight, valueShare)`). The arithmetic is exact in integers, and the allowance rounds
  down, against the creator. The creator posts Pyth's update first: a price over a minute old reverts.
- **Why 5%.** The app sizes units at its own prices, the median of several sources, which stand within a fraction of a
  percent of Pyth's for a coin and within the multiplier for an Ondo token priced at its share. Within 5% of each weight
  an index starts at a distance from its weights of the order of `0.05² / 2`, about a thousandth of its value, against
  15.5% in one fill for the 50/50 index created 90/10 that the design rule "An index created off its weights"
  describes. `test_anIndexIsCreatedOnItsWeights` pins 90/10 refused, 2.5% and exactly 5% off passing, and 5.4% refused.
- The creator gate stays: only wallets the owner approves create. The check makes the creation's starting point
  provable; the gate still answers for whom the team lets launch an index.

## What it costs in gas

- The duplicate check of `createIndex` compared every pair of components, 2.7M gas at two hundred. It now marks each
  token in transient storage (EIP-1153) and clears the marks before returning, one pass, the contracts' first inline
  assembly (`_seen`, `_unsee`; `test_aCreationLeavesNoMarkForTheNext` creates twice in one call).
- The creation's check asks the price reader once for every component (`IPythPrices.valuesWith`), with the feeds and
  the decimals the factory holds, where `valueOf` cost three calls a component.
- At two hundred components, with every touched account cold, on the mock Pyth: `createIndex` 10.25M without an
  oracle and 13.92M with the check, against the 13.98M that five sixths of EIP-7825's cap allows; the fill under the
  check 12.67M. The margin on creation is about 60k, measured on the mock; the fork suites measure it against Pyth's
  own contract.
- A fill of two hundred legs cannot also carry Pyth's update for two hundred feeds: the keeper posts the update in a
  transaction of its own, within the minute before the fill.

## What it costs to run

- Every fill needs Pyth's update from within the last minute, so the keeper fetches updates from Hermes, Pyth's price
  service, a paid plan: the key on file was entitled to none of 91 feeds when it was read on 2026-11-02. Until the
  keeper has one, no rebalance fills under the check.
- Every creation needs Pyth's update too: the app's create flow posts it before `createIndex`.

## Not done

- The keeper: its executor posting Pyth's update with a fill, its bot fetching updates from Hermes.
- The app: the update posted in the create flow; `OffWeights`, `BelowOracleValue`, `StalePrice` and `NoPriceFeed` in
  its error catalogue.
- The fork suites of this branch, on Pyth's real contracts on the three chains.
- `README.md`, `ARCHITECTURE.md` and `docs/`, which still describe the oracle-free build (CLAUDE.md follows this
  record), and the audit package.
