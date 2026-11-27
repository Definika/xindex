# Ondo's tokens at Pyth's price times their sValue

The owner's call that day, asked how to fix the finding of 2026-11-25 (an Ondo leg priced at its share's feed without
the token's multiplier): "Pyth × sValue". Pyth stays the one price source; Ondo's `SyntheticSharesOracle` supplies only
the number of shares one token stands for, which Pyth cannot know.

## 1. What was wrong

`PythPrices` valued an Ondo token at its share's Pyth feed as kind `Token` (the owner's call of 2026-11-23). An Ondo
token's balance never changes for a corporate action: each token stands for `sValue` shares, dividends raise it, and a
split multiplies it (CF-3, `docs/design/pre-mainnet-readings.md`, section 2). So the check valued NFLXon, ten
shares a token since its split, at a tenth of its worth. Read on 2026-11-27 from BNB Chain's oracle (349 of the 353
listed Ondo tokens): 15 legs off by a factor of 2 to 10 (NFLXon, KLACon and PPLTon 10, SNDKon 8, NOWon, CVNAon and PALLon
5, CRWDon and IWFon 4, SOXXon and ITAon 3, APHon and EFVon 2, ETHAon a third, SOXSon a tenth), and six more off by a
dividend's 5 to 7% (HYGon, STRCon, PFEon, SPGIon, TLTon, SATAon), beyond creation's 5%. No exit reads a price, so no
holder's exit was at risk, and the bar bounded every fill. But creation's check (`OffWeights`) refused an index holding
such a leg on its true weights and passed one off them by the same factor, and a fill's check was loosened for it.

## 2. What is built

- **A fifth feed kind, `SharesOracle`** (`IPythPrices.FeedKind`, value 4). The feed prices one share, and a raw unit of
  the token is worth `sValue / 1e18` raw shares, read from Ondo's oracle at the fill: the same arithmetic as the
  `Multiplier` kind of Coinbase's stock tokens, which read their multiplier from the token itself.
- **Only a settled sValue values a leg** (`_settledSValue`, `SValueUnavailable`): the oracle holds the token (its
  getter answers zeros for one it does not, and never reverts), no corporate action is scheduled or under way
  (`pauseStartTime` is zero), and the sValue has stood for `MIN_SVALUE_AGE`, twenty minutes. Any other refuses the
  fill that moves the leg, and a creation that holds it, as a stale price does. This is the rule the keeper has used
  since 2026-11-25 (`keeper/bot/math.mjs`, `M.sValueUsable`, `SVALUE_SETTLE_SECONDS`).
- **Why each condition.** Ondo schedules a split at least a day ahead as a pause and writes its sValue only when its
  operator lifts the pause by hand (`unpause`), at a moment Pyth's share price need not match: refusing from the
  schedule through twenty minutes past the landing keeps the two from being multiplied across the split. A routine
  dividend raise (`submitUpdate`, at most the asset's drift, 1% on Ethereum and 3% on BNB Chain, once a day) waits the
  same twenty minutes.
- **Where the oracle comes from.** The factory's constructor takes it as a fifth argument and hands it to the reader
  it deploys (`SHARES_ORACLE`, zero where Ondo has none, and then a `SharesOracle` feed values nothing).
  `DeployWeighted` takes the address book's on Ethereum and BNB Chain (`ONDO_SHARES_ORACLE`), zero on Base and off the
  pinned chains; nothing in the environment names it, and `checkDeployment` refuses a reader with another on a pinned
  chain. Ethereum's `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` and BNB Chain's
  `0xF4Fd8a1B412633e10527454137A29Db7Aa35F15e` are Ondo's verified source, not proxies, the same runtime code (hash
  `0x4c5b459e…a462`, pinned by `test/fork/OndoSValues.sol`). The reader declares the one getter it reads
  (`src/interfaces/ISyntheticSharesOracle.sol`), in the field order of Ondo's `Asset` struct.
- **The tables.** The 344 Ondo tokens `script/PriceFeeds.sol` prices at a share's feed are kind 4 on both chains; the
  nine Pyth prices as tokens stay kind 1. `test/ConfigureWeighted.t.sol` counts them, and the keeper's
  `price-ids.test.mjs` pins that kind 4 is exactly the keeper's share-priced ids, entry by entry, on both tables.
- **The keeper** on BNB Chain and Base takes a factory feed of kind 4 as a share-priced id, which `bot/svalues.mjs`
  already values at its sValue (`M.valuedFeedId`, mutant OV10); one whose id it does not know as a share's it leaves
  alone, as it leaves a vault's and a multiplier token's.

## 3. What it costs

- **Ethereum's oracle holds 10 of the 353 Ondo tokens.** Near Ethereum's head on 2026-11-27 the reader valued 8 of
  the 344 kind-4 legs and refused 336; on BNB Chain it valued 340 and refused 4 (NTRAon, INSMon, TWSTon, CAIon). On
  Ethereum, then, an index that holds one of the 336 cannot be created, and a fill that moves one waits, until Ondo
  registers it there. Exits are untouched: no issue, redeem or claim reads a price. Said to the owner with the choice.
- **Ondo is a party of the check.** Its admin role adds and removes assets and schedules corporate actions; its
  setter raises an sValue within the drift. A wrong sValue does to a leg what a wrong price does: it can refuse fills
  and creations, or loosen Pyth's check on that leg toward the bar's own bound, never past it. Ondo already issues the
  tokens and can block and burn holders, which the owner accepted on 2026-10-10.
- **Size.** The factory's init code embeds the reader: 48,705 bytes, 447 under EIP-3860's 49,152. The next change
  that needs room in the factory should move `PythPrices` out of it, as `WeightedMath` was on 2026-11-23. Only the
  factory's release hash moved.

## 4. Tests

- `test/WeightedHub.oracle.t.sol`: `test_anOndoTokenIsValuedAtItsShareTimesItsSValue`,
  `test_onlyASettledSValueValuesAnOndoLeg` (not held, scheduled, under way, a second short of twenty minutes, at the
  twentieth, and a creation's read alike), `test_aReaderWithoutOndosOracleValuesNoOndoLeg`,
  `test_anOndoLegIsCreatedOnItsTrueWeight` (the finding: true weights pass, the tenfold skew is refused) and
  `test_aCorporateActionStopsOnlyAFillThatMovesTheOndoLeg`, with `MockSharesOracle` in `test/mocks/MockPricedTokens.sol`.
- `test/PythPrices.t.sol` (the factory hands the oracle on), `test/Scripts.t.sol`
  (`test_resolveSharesOracle_isTheBooksWhereOndoHasOne`, the `checkDeployment` refusal).
- Fork: `testFork_ondoLegsAreValuedAtTheirShareTimesOndosSValue` in `MainnetAddresses.fork` and `BnbChainAddresses.fork`,
  each leg valued at a stand-in share price times the oracle's real sValue, or refused by name where unsettled, and
  NFLXon at ten shares on BNB Chain.
- Mutants OV1 to OV10, all killed; PY15 follows the rewritten line.
