# Ondo's stocks and ETFs, and no xStocks (2026-11-22)

## The call

On 2026-11-22 the owner asked which issuer of tokenized stocks covers more, Ondo or Backed's xStocks, and on the answer
said: "delete everything releated to xtokcs and leave only ondo".

It reverses the call of 2026-11-21 ("use xstock 100 percent and delte ondo", made for the collaboration the team
planned with Backed) and restores the call of 2026-11-19: every Ondo stock and ETF that Pyth has a feed for is listed,
on Ethereum and on BNB Chain. The listing of 2026-11-19 was built that day and committed unmerged as `3f5cf5e` on
`feat/ondo-stocks`; this change brings it onto the release candidate, without the xStocks.

## What the owner was told before it

- **Coverage.** Ondo: 352 tokens with a Pyth feed on each of Ethereum and BNB Chain. xStocks: 109 on Ethereum and 104
  on BNB Chain, the wrappers whose share has a feed. 87 of the 109 are on both; 22 are on xStocks alone (Berkshire
  Hathaway B, AstraZeneca, Booking, Honeywell, Comcast, eBay, Expedia, Danaher, Medtronic, Monster, Philip Morris,
  Roblox, Target, Lululemon and a few smaller names, and the funds IJR, SCHF and VT). 265 are on Ondo alone, among them
  the commodity funds: oil (USO, BNO), gold (GLD, IAU), silver (SLV), platinum (PPLT) and copper (CPER), and inverse
  funds (SQQQ, PSQ, SOXS).
- **What one token is.** An Ondo token's balance never changes; each tracks a number of shares through a multiplier
  (`sValue`) that reinvested dividends raise and a split multiplies (CF-3). No contract prices it.
- **The keeper.** It cannot read `sValue`, so it values only the 9 Ondo tokens Pyth prices directly (NVDA, AAPL,
  GOOGL, MSFT, TSLA, HOOD, MSTR, COIN, CRCL) and leaves the other 343 alone (`SHARE_PRICED_IDS`, RX-2): it
  names no new units for them, delivers none from stock and fills no request priced at them. Those legs mint in kind
  or through `MintRequests`, and a rebalance moves them only through an executor that values them itself.
- **Liquidity.** Ondo's tokens trade mostly on centralized exchanges and through Ondo's own mint and redeem desk, which
  serves eligible non-US users only; few have a Uniswap pool.
- **The reason for xStocks** was the collaboration with Backed, not coverage.

## What changed

- `script/Listings.sol`: Ethereum's list is 414, the 62 coins of the candidate and Ondo's 352 (`3f5cf5e`'s 415 less OP,
  whose copy left on 2026-11-21). `script/BnbChainAddresses.sol`: 364, the twelve coins and Ondo's 352.
  `script/MainnetAddresses.sol`, `script/PythIds.sol`, the CRL-08 tables and both chains' fork suites follow.
  `test/fork/CheckToken.fork.t.sol` checks the wide list a hundred tokens a test.
  `test/fork/WeightedHub.fork.t.sol`'s whole-list index takes the first `MAX_COMPONENTS` coins `deal` can fund, and
  BNB Chain's whole-list tests the list's twelve coins, since neither list fits one index any more.
- Removed: every xStock address and Pyth id, the wrapper tests of both chains' fork suites, the keeper's valuation of a
  wrapper at its feed times `convertToAssets` (`keeper/bot/rates.mjs`, `MAINNET_WRAPPED`, `WRAPPED_TOKENS`,
  `M.atRate`, `M.rateWad`, `M.rateSteady`), its unit and harness tests, the end-to-end test's WRP index, mutants X1
  to X16 and `design/2026-11-21-xstocks.md`. All of it is recoverable at `7a1d9c2`.
- Kept from the same commits: the keeper's fixes of RZ-13, RZ-15 and RZ-16, the request batch in its end-to-end test,
  and `Security.fork`'s two tests on mainnet Tether.
- No contract under `src/` changed, and the release hashes did not move.

## Two feeds corrected the same day

Moving the web app to this build showed two of the eleven Ondo tokens the listing of 2026-11-19 priced at "the
token's own feed" priced at a namesake's: AT&T's (`Ton`) at Crypto.TON/USD, Toncoin's, and Li Auto's (`LIon`) at
Crypto.LION/USD, a token called Loaded Lions. Pyth's own Ondo feeds are nine (each "... ONDO TOKENIZED STOCK"). Both
are now priced at their share's feed (Equity.US.T/USD and Equity.US.LI/USD) and are share-priced legs the keeper
leaves alone, so the keeper values 9 and leaves 343. No contract reads a price, so no index was at risk; the keeper
would have valued those two legs at another asset's price. `keeper/test/unit/config.test.mjs` now requires every
"own feed" to be Pyth's feed of that Ondo token.

## Who holds what

Each chain's Ondo tokens are one `GMToken` implementation behind one beacon (Ethereum's
`0x985462C9aA4D6c3Ad59Ae6e1e9c0C11347ED1598`, BNB Chain's `0xc046b05A920e4B412815934DD8E58904dDA73315`, read on
2026-11-19). Ondo can block and burn a holder's tokens through its compliance contract and burner role, the power the
WBT rule refuses and the owner admitted on 2026-10-10; a pause manager pauses them (RX-55); and Ondo announces a
corporate action at least 24 hours ahead, around which the guardian keeps an affected leg out of a rebalance (CF-3,
`design/2026-10-18-pre-mainnet-readings.md`, section 2).

## Anthropic, 2026-11-25

The owner asked whether Anthropic's stock is supported, Ondo having added it, then: "both to eth and bnb". Ondo issued
ANTon for Anthropic's IPO after the list above was read on 2026-11-19, so it was not on either list. Read that day:

- Ethereum `0x43a0943893474F246aA58e9921d975aD60Adee59`, created at block 26,407,686; BNB Chain
  `0x343ccbc9f8409f862008b7abebFFf20ECf935C75`, first active at block 135,500,512. Both addresses come from Ondo's app
  (its asset page names each chain's), and each is `ANTon`, "Anthropic (Ondo Tokenized)", 18 decimals, behind its
  chain's Ondo beacon with the same proxy code as NVDAon there.
- Pyth has no feed for the token. It has two for the share, `Equity.US.ANT/USD` and `Equity.Index.ANT/USD` ("PYTH PRICE
  IN USD FOR ANTHROPIC 24/7"), and by the list's rule ANTon takes the second, as AMDon takes AMD's; the catalogue gives
  it the regular-hours schedule, as it gives the other "24/7" share feeds (RX-31). So ANTon is a share-priced leg the
  keeper leaves alone (344 of them now), and the price check of a creation or a fill that holds it may wait for the
  US session. No exit reads a price.

Ethereum's list is 415 and BNB Chain's 365, 353 Ondo tokens on each. The BNB Chain suite's pin moved to a block after
ANTon's first, since `testFork_tokensAreWhatTheirNamesSay` reads every listed token at the pin; Ethereum's list pin
(26,464,080) already follows ANTon's creation.

## Ondo's sValue in the keeper, 2026-11-25

Asked whether Ondo's own way of pricing could be used ("we can use their formula yes?"), after reading how Ondo prices
its Intelligent Portfolios (each constituent's price times the quantity held, plus cash in transit, over the tokens
outstanding), the owner chose the keeper first. The formula is the index's value the keeper already computes; what
Ondo adds is the sValue, the shares one token is worth, which a share's feed leaves out.

- **Where it is.** Ondo's `SyntheticSharesOracle`, one per chain (Ethereum `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6`,
  BNB Chain `0xF4Fd8a1B412633e10527454137A29Db7Aa35F15e`, both named in Ondo's documentation, verified source), keyed
  by the token's address: `assetData(token)` gives the sValue (1e18 = one share), the last change and any corporate
  action's pause. Its notes say it is "intended to be combined with a stock price oracle". Small updates rise by at
  most the asset's allowed drift (100 bps on Ethereum, 300 on BNB Chain) once a day; a split or another large change
  is scheduled as a pause, at least 30 minutes long, which an operator of Ondo's lifts by hand, the new sValue landing
  then.
- **What it holds, read on 2026-11-25.** BNB Chain's: 349 of the list's 353 Ondo tokens, ANTon among them (not NTRAon,
  INSMon, TWSTon or CAIon); 190 of them away from one, from 0.10 (SOXSon, a reverse split) to 10.04 (KLACon), NFLXon
  and PPLTon at 10, SNDKon at 8, NOWon, CVNAon and PALLon at 5, CRWDon and IWFon at 4. Ethereum's: 10 (SPYon 1.0095,
  STRCon 1.0733, HYGon 1.0655 and seven more), each the same figure as BNB Chain's for the same ticker. The multiplier
  is the asset's, not the chain's: Ondo's app shows one for each asset (NFLXon's is 10 on every chain, its token at
  $581.10 against a share near $58), and the 10 both oracles hold agree to the wei.
- **What the keeper does** (`keeper/bot/svalues.mjs`). A share-priced Ondo leg is valued at its share's price times its
  sValue, read from the chain's oracle at the round's block, once settled (`M.sValueUsable`): held, no pause scheduled
  or under way, last changed at least `SVALUE_SETTLE_SECONDS` (twenty minutes) ago. One read per round for every
  index, on any node. A leg without a settled sValue stays share-priced, as before. Run against both oracles that day
  through the keeper's own chain client: BNB Chain values all but the 4 its oracle does not hold, Ethereum 8 of 344.
  Unit tests in `keeper/test/unit/svalues.test.mjs`, mutants OS1 to OS8.
- **Not done.** Ethereum's other 336: Ondo's API serves every asset's multiplier (`/v1/assets/{symbol}/shares-multiplier`,
  an API key of Ondo's), and BNB Chain's oracle holds the same figures by ticker; either would value them, each a
  source the keeper does not read today, so the choice is the owner's. The restock still buys only the nine priced at
  their own feeds.

**Found with it: the Pyth check prices these legs without the multiplier.** `PythPrices` values an Ondo leg at its
share's feed as a `Token` (the owner's call of 2026-11-23: the multiplier left out, the guardian keeping a leg around a
corporate action). A split's multiplier does not pass with the action: NFLXon has been worth ten shares since its
split, so the check values it at a tenth. On Ethereum's list that is fifteen legs off by a factor of 2 to 10 (NFLXon,
KLACon, PPLTon, SNDKon, NOWon, CVNAon, PALLon, CRWDon, IWFon, SOXXon, ITAon, EFVon, APHon, ETHAon, SOXSon) and
more off by a dividend's few percent (STRCon 7.3%, HYGon 6.5%). Nothing reads a price on an exit, so no holder's
exit is at risk, and the bar still bounds a fill. But creation's 5% check (`OffWeights`) refuses an index that
holds such a leg on its true weights, and passes one whose units were named at the share's price, which is off its
weights at the market; and a fill's check is weakened for such a leg. Answers, the owner's to choose: read Ondo's oracle in the
price reader for an Ondo leg (BNB Chain holds 349; on Ethereum only 10 until Ondo registers the rest), or hold
those legs out of new indexes until it can.

## Left

- The app: its asset list, Ondo's logos and the asset classes (commodities among them) follow when it moves to this
  build.
- A keeper that reads `sValue` on Ethereum too (Ondo's app API gives `sharesMultiplier` per asset), so the 336 left there can be valued and
  filled; until then an operator adds their stock by hand.
- Ondo's 127 stocks and ETFs without a Pyth feed, which join as Pyth publishes one.
