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

## Left

- The app: its asset list, Ondo's logos and the asset classes (commodities among them) follow when it moves to this
  build.
- A keeper that reads `sValue` (Ondo's app API gives `sharesMultiplier` per asset), so the 343 can be valued and
  filled; until then an operator adds their stock by hand.
- Ondo's 127 stocks and ETFs without a Pyth feed, which join as Pyth publishes one.
