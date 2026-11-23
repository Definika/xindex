# Retirement record: Pyth's check on a fill (2026-11-22)

On 2026-11-22 the owner chose an oracle that can only refuse a rebalance fill, and Pyth as that oracle
(`design/2026-11-22-pyth-check.md`). It reverses in part the oracle-free rebalance of 2026-11-10, under which no file
in `src/` named Pyth at all (`audit/2026-11-10-oracle-retirement.md`). One contract reads Pyth again, `PythPrices`. The
factory asked Pyth one thing more until 2026-11-23, whether a feed exists, when the owner proposed one; it no longer
does, since Pyth's contract on a chain knows a feed only once an update of it was posted there.

## What went

- **V5-I4, retired in full.** `test_V5I4_noContractNamesPyth` (`test/Repo.t.sol`) required that no file in `src/` and
  no shipped ABI name Pyth by any of its names, getters, parse, pushes or price struct. Pyth is named by design now, so
  the test cannot stand. V5-I4 (`audit/2026-10-05-v5-review.md`) first kept Pyth to the hub; since 2026-11-10 its test
  allowed Pyth nowhere. No other test carries the id.

## What was narrowed

- **A7-13.** `test_A713_noContractReadsAPrice` (`test/Repo.t.sol`) still scans every file in `src/` and `abi/` for the
  common ways to read a price, and now leaves out the price reader's own files alone (`_isPriceReader`:
  `src/PythPrices.sol`, `src/interfaces/IPythPrices.sol`, `src/interfaces/IPythReader.sol`, `abi/PythPrices.json`).
  `test_A713_theScanFindsEveryPriceWord` still checks the scan itself.

## What stands in their place

- `test_onlyThePriceReaderReadsPyth` (`test/Repo.t.sol`): Pyth's reads (its stored price, its parse, its pushes)
  appear in the price reader's files alone, its question whether a feed exists included, and a new file is covered
  without being listed. The vendored Pyth interfaces stay gone: `IPythReader` is a declaration of our own.
- `test_exitsAndMintsReadNoPrice` (`test/WeightedHub.oracle.t.sol`): with Pyth answering nothing, holders still mint,
  redeem in full and skipping a leg, and collect a claim, and a rebalance still starts; only the fill stops.
- `test_aWrongPriceCannotPassAFillTheUnitsRefuse`: a price can only refuse, never pass a fill the units refuse.

The ids the record of 2026-11-10 retired with Pyth (V5-L1, V5-M1, V5R-1, DA-01, RB-3, RX-3, RX-18, RX-27, AU-2,
RZ-26) stay retired: the check of 2026-11-22 is another mechanism, a refusal on top of the units, and its tests carry
no review id. If one of those properties matters again, it gets a new id from the review of this surface.
