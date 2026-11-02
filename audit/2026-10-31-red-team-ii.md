# Red team II of 2026-10-31

A second red team of `spec/rebalance-state-machine` at `e9c3ad0`, with the uncommitted RY-6 fix in the keeper
(`keeper/bot/hermes.mjs`, `keeper/restock.mjs`, their tests), run on 2026-10-31 after `audit/2026-10-31-red-team.md`.
Its brief was to find bugs and broken patterns, not to prove them: no proof-of-concept tests were written, and nothing
in the repository was changed.

Method: 24 adversarial readers, one lens each, read their target files whole (`src/`, `script/`, `keeper/src/`, the
keeper and restock JS, the tests, mocks, formal artifacts and docs), then a completeness critic named ten more lenses
from their coverage gaps (fix regressions, event and error surface, invariant handlers and mocks, fork and e2e
evidence, keeper constants, keeper transaction lifecycle, keeper decision math, restock moves, executor treasury
paths, frozen-leg periphery). Five readers died on API errors and were re-run. The 137 raw findings were de-duplicated
and checked against `audit/triage.md`, `docs/known-limitations.md` and the two notes of the same day by a light triage
pass; 27 matched a recorded id and are not repeated below. The High and the four Mediums were then confirmed by hand,
by reading the lines and, for RZ-1 and RZ-4, by running the arithmetic (viem 2.21.54 from `keeper/node_modules`, and
`WeightedMath._targets` replayed in Python). Lows and Infos are the readers' findings at their lines, re-read but not
re-derived; each carries the reader's confidence.

Each id is `RZ-…`: drafted as `RT2-1` to `RT2-33`, whose test names (`test_RT21_...`) would collide with the red team
of 2026-09-24's `RT-21`, and renumbered on 2026-11-01, with the first report's `RT-` ids as `RY-`. The Fix column is
the review's; the last section gives each id's status after the fixes of 2026-11-01. A fixed finding's test carries
its id, as `AGENTS.md` gate 6 requires.

## Confirmed

| Id | Verdict | Finding | Fix |
|---|---|---|---|
| RZ-1 | Confirmed, high (keeper bot and restock service) | `keeper/bot/requests.mjs:46` and `keeper/bot/hermes.mjs:125` read Pyth's answer as `const [feeds] = await call({… functionName: "parsePriceFeedUpdates" …})`. Both `call` helpers return `decodeFunctionResult(…)`, and viem returns a function's single output unwrapped, so `feeds` is the first `PriceFeed` struct, not the array, and `M.verifiedPrices` (`keeper/bot/math.mjs:80`, `for (const feed of feeds)`) throws `TypeError: feeds is not iterable`. Verified against viem 2.21.54 with the ABI in `keeper/bot/chain.mjs:46-48`. In the bot, `trustedLatest` runs on every scan and every `best` that sees a live request (`requests.mjs:104`, `:120`), so with any open request `onBlock` throws after the auction checks and the request filler has filled nothing since the RX-9 fix landed (`514347b`, 2026-10-19); auction starts and fills, which run earlier in `onBlock`, are unaffected. In the restock, `prices()` (`restock.mjs:174`) throws on every round, so the RY-6 fix as written stops the service. The unit test is written to the bug: the mock `call` in `keeper/test/unit/hermes.test.mjs:166` returns `[[feedOf(A…), feedOf(B…)]]`, double-wrapped, so the tests pass and would fail on a correct implementation; the keeper e2e (`keeper/test/e2e/run.mjs`) deploys `MintRequests` but never makes a request, and its fake Hermes serves `/latest` without `binary`, so `trustedLatest` returned an empty map there before it could throw. | `const feeds = await …` on both lines; make the mock return the bare array; add a request scenario to the e2e and serve `binary` on `/latest` |
| RZ-2 | Confirmed, medium (restock service) | `routeFor` (`keeper/restock.mjs:217-226`) halves the amount "so a thin pool takes the restock in smaller batches rather than none", calling `r.best({ key: \`restock:${block}\`, token, side, amount: a, … })` each time. `routes.best` (`keeper/bot/routes.mjs:97-101`) keys its cache on `${key}:${token}:${side}`, identical for every iteration, and after the first refusal answers `if (c && c.route === null && amount <= c.amount && age < REQUOTE_BLOCKS) return null` for every smaller amount without quoting. The halving is dead: a coin whose full-size route fails `ROUTE_MAX_LOSS_BPS` is never bought or sold in batches, on either side. | Put the amount in the key, or `r.forgetKey` before each halving; add a unit test with a quote that passes only at half size |
| RZ-3 | Confirmed, medium (keeper bot and restock service) | The needs board carries a coin only while the fill is short of it. `legs()` pushes to `short` only when a leg has no route and `maxIn[i] > h` (`keeper/keeper.mjs:179-184`), and `needs.report(key, "fill", leg.short)` deletes the key on an empty list (`keeper/bot/needs.mjs:18`). So the moment the restock's coins land and `h >= maxIn[i]`, the board forgets the need. The planner then reads `need = 0`, `want = 0`, and `spare = balance - want` (`keeper/restock/plan.mjs:155-160`), and bridges everything above `RESTOCK_KEEP_USD` back home as soon as nothing is in flight. A fill that waits for μ to fall to its profit point, as every fill does, finds the stock gone, reports the need again, and the cycle repeats, each round trip paying two bridge fees and up to twice `ROUTE_MAX_LOSS_BPS`. The board's own comment says a report is "the whole of that coin the fill needs, not the part stock lacks, since one stock serves every fill", which `legs()` does not do. | Report every stock-served leg (no route) with `maxIn[i]`, not only the short ones, so the need stays on the board until the fill lands or expires |
| RZ-4 | Confirmed, medium (hub, documentation) | `docs/known-limitations.md:45-48` says a collapsing coin stops fills only when a target is "more than 1e18 times its units" and that "a collapse by a factor of fifty against the rest still fills". `WeightedMath._targets` caps `share` for a growing leg at `current · MAX_GROWTH / (target − current)` (line 163) and then requires the capped release to reach `MIN_TRADE` of the value (line 173). With one leg's price down k-fold, `share ≈ 1/k` and the check fails long before uint96 or `share == 0`. Replaying `_targets` exactly, for a two-leg index on its weights at equal prices: 50/50 first reverts `NothingToRebalance` at k = 999, 30/70 at 429, 10/90 at 111, 1/99 at 11; at k = 50 the 1/99 index does not fill. Every `executeRebalance` and `previewRebalance` then reverts until the price recovers or the guardian starts with that leg kept; a two-component index refuses every keep mask (`startRebalance`, `n - _countBits(keepMask) < MIN_COMPONENTS`), so it has no remedy at all. An issuer of a listed token held at 1% can freeze the permissionless rebalancing of every such index by crashing its price eleven-fold (RX-15 covered the drain direction only). Holders keep their in-kind exit. | Record the real thresholds in `docs/known-limitations.md`; consider taking `MIN_TRADE` on the release before the growth cap, or letting the owner or guardian settle a growth-capped fill below it |
| RZ-5 | Confirmed, low (restock service) | `script/PythIds.sol` and `script/MainnetAddresses.sol:238` list BNB's Wormhole copy (`0x418D75f65a02b3D53B2418FB8E1fe493759c7605`, from WBNB on chain 4) among the pool-less coins since 2026-10-18; `keeper/restock/coins.mjs` carries thirteen coins and not BNB, nor do `PRICE_IDS` or `DEFAULT_COINS`. A need for BNB on the board is silently ignored, while its home chain (`CHAINS.bsc`, PancakeSwap v3) is already configured for XRP, ADA, LTC, DOT and ATOM. | Add the BNB row and its price id |

## Low, reported by the readers

Each entry names the reader's confidence. None moves protocol funds; they are bot losses, stalls, misjudged decisions,
deploy-check gaps or tests that cannot fail.

| Id | Where | Finding (confidence) |
|---|---|---|
| RZ-6 | `keeper/bot/chain.mjs:148` | `txIo.receipt` returns `null` on every error, not only `TransactionReceiptNotFoundError`. A timeout or a lagging replica during the lookup makes `nonce.mjs:70-84` score a mined fill as `replaced: true`, so its outcome, success or revert, is dropped: the class RS-5 fixed for the restock, still in the tracker (0.8) |
| RZ-7 | `keeper/bot/hermes.mjs:123` | `trusted()` promises that a price without a carrying update is "left out", but it asks Pyth for every id in `parsed`, and Pyth reverts `PriceFeedNotFoundWithinRange` for any id its blobs lack, so one mismatched feed unprices every coin and aborts the round. The same holds for `trustedLatest`. Fail-closed, but not what the docstring and `keeper/README.md` say (0.8, two readers) |
| RZ-8 | `keeper/bot/nonce.mjs:48` | `send()` signs on `latestNonce()`. A pending transaction the bot did not send (XS-12 leaves it alone) is then either replaced by the next fill, if the fee is 10% higher, or blocks every send with `replacement transaction underpriced`, which `_submit` logs as "retrying higher next block" and nothing retries (0.7) |
| RZ-9 | `keeper/bot/nonce.mjs:60` | `send()` returns `null` when the node refuses the transaction and all three callers (`keeper.mjs:463`, `:537`, `:558`) ignore it, having already logged "filling"; a subsidised fill is charged to `SUBSIDY_BUDGET_USD` though nothing went out (0.7, two readers) |
| RZ-10 | `keeper/bot/requests.mjs:61` | `scan()` re-reads every known open request plus every new id every 25 blocks with no cap. A request needs only `amount != 0 && limit != 0` and a refundable escrow, so a stranger's one-unit requests with 30-day deadlines grow the multicall without bound (0.7) |
| RZ-11 | `keeper/bot/requests.mjs:160` | A routed leg's limit comes from `routes.quoteOf`, which scales a cached quote down but never up, and `best` keeps a route 25 blocks without re-quoting, so a shortfall that grew gets a `maxIn` below the real cost, the simulation reverts, and the request is struck (0.6) |
| RZ-12 | `keeper/bot/requests.mjs:234`, `:289` | `evaluate()` and `best()` mark any thrown error, a 429 or a timeout included, as `failed: true`, strike `failedRequests` (no lapse, no decay) and forget the routes; the auction path gates the same decision on `chain.isRevert` (0.55 and 0.85, two readers) |
| RZ-13 | `keeper/bot/requests.mjs:318` | `filler.forget(id)` runs on the first receipt with `status: success`. `scan()` reads only `known` and ids above `scanned`, so after a one-block reorg that drops the fill the request is open on chain and invisible to the bot until restart (0.75) |
| RZ-14 | `keeper/keeper.mjs:369` | `evaluateStart` compares the best-case fill's profit against `MIN_PROFIT_USD` and never nets the start's own gas (`startGasLimit`, up to 4.65M at 100 feeds) and Pyth fee, which only the bot pays (0.75 and 0.6, two readers) |
| RZ-15 | `keeper/keeper.mjs:477`, `:488` | Any reverted fill the bot sent and did not replace is a strike. A fill mined one block late reverts `Expired` (deadline `L.timestamp + 12`, for request fills too, which read no Pyth update) and is booked as a front-run; three in 300 blocks evict the bot from the auction, or back the request, its requester and its index off (0.7 and 0.8, two readers) |
| RZ-16 | `keeper/keeper.mjs:535` | `SUBSIDY_BUDGET_USD` is charged the simulated loss, while the floor each fill carries (`usdcFloor`: `max(decision, simDelta − slack)`) lets the realised loss reach `MIN_PROFIT_USD` or 30 bps more than simulated, uncounted (0.7) |
| RZ-17 | `keeper/bot/math.mjs:112` | `startGasLimit = 150_000 + 45_000 · feeds` was calibrated at 93 feeds and amortises Pyth's fixed VAA cost into the per-feed term; at 2 to 4 feeds the limit is likely below the real cost, so `fitsItsGas` refuses every such start with a misleading log. Measure the start as the fill is measured (0.45) |
| RZ-18 | `keeper/restock.mjs:120` | `advance()` redeems with `coinOf(move.coin).copy`, the current configuration, not the journal's `move.copy`, which `journal.open()` stores for exactly this. A coin dropped from `RESTOCK_COINS` while its transfer is in flight throws every round and is never redeemed (0.7) |
| RZ-19 | `keeper/restock.mjs:187` | `readState()` reads balances at `latest` right after the round's own `advance()` mined its redeems, with no block floor; a load-balanced replica one block behind shows the coin short again and the plan buys it twice (0.5) |
| RZ-20 | `keeper/restock/plan.mjs:82` | The short branch sizes on `usable = min(balance, allowance)` while bridge-out sizes on `balance`. Stock above its allowance (the normal state after an arrival beyond the restock room) is never offered to the owner as "raise the stock allowance"; the note sends them to `setRestockAllowance`, and following it buys, bridges out and sells the undeliverable stock (0.5) |
| RZ-21 | `keeper/restock/plan.mjs:91` | The short branch bridges home coins in with no `RESTOCK_MIN_USD` floor, while the covered branch applies one, so a sub-minimum home remainder costs an Ethereum redeem on its own and the buy in the same round still sizes at `minUnits` (0.75) |
| RZ-22 | `keeper/restock/plan.mjs:115` | The plan floors `minUnits` in integers and `routeFor` recomputes the dollar value in floats (`Number(a) / 10 ** decimals * price`), so a buy sized at exactly `RESTOCK_MIN_USD` lands one ulp under the gate and is refused, always for 6-decimal coins (0.75) |
| RZ-23 | `keeper/src/KeeperExecutor.sol:211` | `withdraw` moves stock out and leaves `stockAllowance` as it was; `bridgeOut` caps the allowance at what is left so "coins kept later cannot inherit an allowance the coins that left had". Stock the owner withdraws and a later fill keeps is deliverable on the old credit (0.7) |
| RZ-24 | `script/DeployChecks.sol:127` | `checkOwner` refuses an owner Safe with modules (`OwnerHasModules`, SA-06/XA-07); `checkGuardian` reads the guardian Safe's signers one level deep but never its modules, so a guardian Safe whose module is an owner signer passes the "no key on both sides" check (0.7) |
| RZ-25 | `src/WeightedHub.sol:268` | `issue()` pulls a leg without probing that the index can still send it. The three sibling custody paths probe (`_checkBacking` on every bought leg, `BasketBuilder._checkCanSendOut`, `MintRequests.requestMint`), so a minter can deposit into a leg a Tether-pattern blacklist has already frozen for the index and lose that leg to a claim that cannot pay (0.55; RX-12 and RX-60 cover the fill and builder sides) |
| RZ-26 | `src/WeightedHub.sol:562` | Since RX-3 a keep-mask start, the guardian's only recourse around a frozen leg, needs a Pyth update valid in one 12-second slot, as a fill does. The keeper lands mask-0 starts at `targetBlock L+1` and cancels on a miss; nothing in the repository does that for a Safe or a guardian key (0.5) |
| RZ-27 | `src/WeightedHub.sol:799` | Every start and fill reverts `PriceOffAverage` unless `emaPrice.price > 0` and `emaPrice.expo == price.expo`. Unverified against updates the post-OP-PIP-132 publishing stack produces for every listed feed; `PYTH` is immutable. A pre-mainnet check (0.3) |
| RZ-28 | `src/WeightedIndexFactory.sol:205` | The header promises "a policy change cannot land between its quote and its creation" and that an app can show the address before the transaction confirms. `_checkedConfig` bounds only the two platform rates; `referralShareBps` is copied from storage into the config, and the config is in the CREATE2 salt, so a policy change moves the predicted address and the referral terms (0.6 and 0.75, two readers) |
| RZ-29 | `keeper/test/KeeperExecutor.invariant.t.sol:213` | `invariant_RS1` compares `potential()` with a `ceiling` the handler resets to `potential()` after every allowance-changing call and never exercises a path that spends stock: it cannot fail (0.9) |
| RZ-30 | `keeper/test/e2e/run.mjs:235` | The e2e makes no request and its fake Hermes serves `/latest` without `binary`: `requests.mjs` has no end-to-end coverage and RZ-1 could not surface (0.8) |
| RZ-31 | `test/BasketBuilder.t.sol:519`, `:799` | The leg-cap-below-budget path and `sell`'s overall minimum are each covered by a bare `vm.expectRevert()` only (0.7) |
| RZ-32 | `test/WeightedHub.invariant.t.sol:610` | The handler checks the start hold-off one-sided: it never tries a stranger between `earliestRebalance` and `_permissionlessAt` and never asserts `canStartRebalance()` is false there (0.85) |
| RZ-33 | `test/vectors/settlement.py:136` | The settlement vectors' stated purpose is that an intermediate truncation or overflow "shows as a mismatch on some vector"; no settled vector comes near a mulDiv's 256-bit edge or the uint96 success boundary (max units 2.5e24, max product 5.3e71, n ≤ 12) (0.9) |

## Regressions of recorded fixes

- **XA-34** (`test/fork/WeightedHub.fork.t.sol:568`): the WBTC-pause drill is back to a bare `vm.expectRevert()` and never
  asserts WBTC moves; `audit/triage.md:75` still says FIXED by a test that no longer exists.
- **XA-36** (`test/WeightedHub.t.sol:379` and others): bare `vm.expectRevert()` is back in `test/` although the row records
  "No bare vm.expectRevert() is left".
- **RY-6** (this day): the fix's unit test is written to RZ-1 (`keeper/test/unit/hermes.test.mjs:166`).

## Informational

Documentation and spec drift: `ARCHITECTURE.md:105` says only `executeRebalance` is payable (`startRebalance` is too);
`ARCHITECTURE.md:125` states the units ceiling as `MAX_UNITS` where the code caps per decimals (RX-5);
`docs/integration.md:152` lists `MintParams` without `referrer`; `docs/integration.md:216-224` miss events and errors of
the newest code; `docs/integration.md:90` says `issue` works for anyone (a gated index refuses); `docs/deployment.md:57`
miscounts the wide list (91 coins, 4 default, 87 wide); `docs/video/XindexFlowVideo.swift:1051` still says
`startRebalance(0)` reads no price and the auction lasts 24 hours; `IXindexErrors.Unauthorized` and `ZeroAmount`,
`Expired`, `TransferShortfall` NatSpec name fewer raisers than exist; `FeeSharesMinted` NatSpec not updated by AU-1;
`design/2026-10-29-rebalance-state-machine.md:196` claims 19 math and 17 hub mutants with no runner or diffs committed;
`keeper/restock/coins.mjs:3` promises home-chain address checks that `checkSetup` does not make.

Events and errors: `IndexCreated` omits the gate flag; `BridgedOut` emits the requested amount, `BridgedIn` the
measured one; `stockAllowance` NatSpec says only the owner sets it (two treasury paths do) and neither it nor
`requestUsdcAllowance` emits on spend; the factory constructor emits `GuardianSet(0, 0)` without a guardian;
re-proposing an expired listing overwrites silently where `proposeGuardian` emits a cancellation; `_readPrices` reports a
feed-count mismatch as `PriceMismatch(bytes32(0), 0)` while `PriceCountMismatch` exists; `acceptCreator` on a non-index
reverts `Unauthorized` where siblings revert `NotIndex`; `BasketBuilder` escrow moves are not logged per token;
`claim()` is the one state-changing hub entry without `onlyInitialized`.

Hub, factory, zap, builder: `_tryPermit` covers the EIP-2612 shape only (DAI-style and contract-wallet signers fall back
to a prior allowance); a `buy` leg the escrow already covers skips route validation; an index token can be whitelisted
and used as a component (no `isIndex` refusal in `_proposeListing`; nothing breaks mechanically, but no feed prices it);
a gated index's gate is bypassed for any requester once its creator allowlists a request filler, since transfers are
ungated by design; the streaming accrual can overflow at absurd supply (above 3.7e65), contradicting "an exit is never
blocked"; `verifiedPrices` checks only `price`, so the `ema` carried beside a trusted price is still Hermes' unsigned JSON.

Keeper bot: auction fill simulations have no backoff (a frozen leg is re-simulated and re-fetched every block for 4 h,
where request fills back off, XS-7 pattern); `maxSupply` adds pending streaming-fee shares the executor's supply check
never sees; `worthChecking` values an auction at 0 USD for 25 blocks on a failed read (RY-9 class); the start path skips
silently when `nextBase + tip > MAX_FEE_GWEI` after a full simulation round; `send()` arms the XS-12 clearance window on
deterministic refusals; no reorg handling around a finished nonce; `PRIORITY_FEE_GWEI > MAX_FEE_GWEI` passes validation
and disables every send with a misleading message; `US_EQUITY_SCHEDULE` dated overrides carry no year; the per-block scan
is O(indexes) without `INDEXES` (CF-7 adjacent); auction fills carry no per-leg bounds where request fills do (RX-10,
README accepts the floor as the bound); a hostile requester evicts the bot from an index's requests for an hour at three
create-and-cancel pairs (RX-10, RX-26 adjacent); the keeper pays a USDT redeem exactly its limit, so a Tether fee switched
on makes every such fill revert `BelowLimit`.

Restock: `act()` logs a move as done whatever the receipt's status; no gas check or note for the treasury's ETH on
Ethereum where every home chain has one; fund actions are emitted when the treasury cannot be drawn for them (one approve
mined, burns fail at estimation every round); a bridge move stuck at `attested` has no escape (`drop()` refuses it,
`inflight` counts it forever); `treasuryUsdcOut` is bound to the role, so `setTreasury` carries a rotated-out treasury's
debt to the next one and the owner has no write-off.

Tests, mocks, formal artifacts: `MockPyth`'s fee model differs from the deployed contract (per update vs per feed plus
`transactionFeeInWei`) and `testFork_pythIsPyths` sends no fee and cannot tell `InsufficientFee` from
`PriceFeedNotFoundWithinRange`; every randomized fill in the hub invariant feeds `conf = 0`, `emaPrice == price`,
`expo = -8`, so the price gates are never randomized, and MockPyth cannot produce the confidence or EMA refusals a start
inherits; the fork and e2e suites never exercise the price checks against data a real feed could produce; the "every coin"
fork test tolerates 66 of 91 coins dropping out and its docstring describes a 49-coin list; the fork rebalance test logs
the rebalancer's profit instead of asserting it and the wrong-price drill never fills; the `MintRequests` handler's
filler-side check cannot fire; fee-policy churn is checked on totals only, never on the referral split; `test/Rogue.t.sol`
narrows its parameters so the uint96-overflow seeds never reach the exits and the referral, bounded-fill and keep-mask
restart paths are never driven; `test/WeightedMath.halmos.t.sol:44` asserts three tautologies and one real property, fixes
supply, scale, keep mask and n, and swallows every Panic, so a finished run would prove only the turnover cap;
`test/vectors/proofs.py:215` has no vacuity guard; the exact model reproduces the contract's own two-step growth rounding
and the z3 scope (n ≤ 3, no keep mask) is narrower than the hub's; `KeeperExecutor` has no test of `fill`, `fillMint` or
`fillRedeem` against a frozen component.

Scripts: `ConfigureWeighted` and `CheckToken` pin mainnet on `block.chainid == 1` only where `DeployChecks` also reads
the router's code (RX-23 applied to one script); `checkDeployment` leaves the zap's WETH, `MintRequests`' USDC and USDT
and the pinned router unverified; the off-mainnet role check omits the env-given WETH, USDC and USDT; `_signers` decodes
a Safe answer with `abi.decode` after a length check only (RT-25 shape); `ConfigureWeighted.execute()` skips
`_requireUnique` that `propose()` enforces (RT-24 adjacent); `CheckToken` detects callback tokens through ERC-1820 and
ERC-165 only, so a token calling recipient hooks without registering passes admission.

## Checked and found clean, beyond the previous round

The hub's backing invariant on every path, rounding directions, casts, the state machine's boundary seconds and
orderings, the settlement's callback surface, the zap's ether and permit paths, the engine's pre-fund bound (shown again
by induction), the builder's escrow sums, `MintRequests`' escrow measurement, the executor's allowance bounds and
transient callback gate, the factory's listing and guardian windows, the mainnet constants and price ids in
`script/MainnetAddresses.sol` and `script/PythIds.sol`, the keeper's VAA handling and the restock's recipient pinning.
No `unchecked` block exists in `src/` or `keeper/src/`.

## Gates

- `forge build` and `forge test --no-match-path 'test/fork/*'` at the start of the session: 535 tests pass. Nothing in
  the repository was changed by this review, so they were not re-run.
- RZ-1 reproduced with `node --input-type=module` in `keeper/` against the ABI of `keeper/bot/chain.mjs`: the decoded
  value is an array of two feeds; `const [feeds] = …` yields one struct; `for (const f of feeds)` throws
  `feeds is not iterable`.
- RZ-4 reproduced by replaying `_targets` in Python at the thresholds above.
- Not run: the fork suites and both end-to-end tests (no RPC in this session).

## Status of the fixes (2026-11-01)

The High and the Mediums were re-derived before any change (RZ-1 against viem 2.21.54, RZ-4 in closed form). The
keeper's Lows were judged by a second reader told to refute them, and re-read here where a fix was made. Verdicts that
differ from the table's are marked.

| Id | Verdict | Status | Test |
|---|---|---|---|
| RZ-1 | Confirmed, high | Fixed. `hermes.verified` reads the parse as `const feeds = await call(...)`, and the request filler's `trustedLatest` calls `hermes.trusted` rather than a copy of it, so one parse is left. The unit mock returns viem's shape | `RY-6, RZ-1: trusted() keeps only ...`, which fails with `feeds is not iterable` on the bug restored |
| RZ-2 | Confirmed, medium | Fixed. The halving moved beside the cache it depends on, `routes.bestBatch`, with a key per amount; `restock.mjs` `routeFor` calls it | `RZ-2, RZ-22: bestBatch quotes each halving ...` in `keeper/test/unit/routes.test.mjs`, which fails with one key |
| RZ-3 | Confirmed, medium | Fixed. Both fillers report every leg stock serves, at the whole of its bound, covered or not (`leg.stocked`); `short` still decides the skip. `keeper/README.md` says so | none: neither `legs()` has a unit harness |
| RZ-4 | Confirmed, medium; the threshold re-derived as `k > 999 · w / (1 − w)` for a leg of weight `w` fallen `k`-fold, matching the table; five of the thirty `collapsed` vectors refuse this way | Fixed, documentation: `docs/known-limitations.md` and a correction in `design/2026-10-29-settlement-vectors.md`. Open, the owner's call: whether a growth-capped fill may settle below `MIN_TRADE` (a change to the settlement's rules, its vectors and its proofs), and that a two-component index cannot keep a leg | none |
| RZ-5 | Confirmed, low | Fixed. BNB (WBNB on BNB Chain, PancakeSwap v3, Pyth's BNB/USD) is in the coin table and served by default; WBNB is an ERC-20, so it is no gas coin | `RZ-5: every coin is the copy MainnetAddresses lists ...`, pinned against `script/MainnetAddresses.sol` and `script/PythIds.sol`. Its home market was not exercised (e2e not run) |
| RZ-6 | Valid, informational (overstated: bookkeeping only) | Open | none |
| RZ-7 | Valid, documentation | Fixed: `hermes.verified` says a mismatch fails the round | none |
| RZ-8, RZ-9, RZ-10, RZ-11 | Valid, informational (overstated: a stalled or misleading log, a safe-side budget, RPC load, a re-quote two blocks later) | Open | none |
| RZ-12 | Valid, low | Fixed. Only an error `chain.isRevert` recognizes is a failed simulation, at all three sites; an RPC error is retried next block with no strike | none: no unit harness |
| RZ-13 | Valid, informational | Open | none |
| RZ-14 | Valid, low | Fixed. A start's profit nets the start's own gas, at the limit it is sent with, and Pyth's fee for its update | none: no unit harness |
| RZ-15 | Valid, low | Open: strike only a fill that landed by the block it was priced for | none |
| RZ-16 | Valid, informational (only with a subsidy, off by default) | Open | none |
| RZ-17 | Unsure, leaning not a finding: the keeper e2e started two-, three- and four-feed indexes under `startGasLimit` with real Pyth, passing on 2026-10-27 | Open: measure a small start on a real Hermes update | none |
| RZ-18 | Valid, low | Fixed. The restock redeems with the copy its journal recorded (`move.copy`) | none: `restock.mjs` has no unit harness |
| RZ-19 | Valid, low | Open: mark coins whose move advanced this round as busy for the round's plan | none |
| RZ-20, RZ-21 | Valid, informational | Open | none |
| RZ-22 | Valid, low (overstated: no coin served today has fewer than 18 decimals) | Fixed with RZ-2: only the halvings are held to `RESTOCK_MIN_USD` | `RZ-2, RZ-22: ...` |
| RZ-23 | Valid, low | Fixed. `withdraw` caps the stock allowance at what is left, as `bridgeOut` does | `test_RZ23_withdrawCapsTheAllowanceAtWhatIsLeft` in `keeper/test/KeeperExecutor.t.sol` |
| RZ-24 | Valid, low | Fixed. A Safe's enabled modules, the first 16, count among its keys on both sides and one level down | `test_RZ24_aSafesModulesCountAsItsSigners` in `test/Scripts.t.sol`, which fails with the module read removed |
| RZ-25 | Valid, low | Open, the owner's call: a send probe on every issue costs gas on every leg and code the hub's 98 spare bytes may not hold. Recorded in `docs/known-limitations.md` | none |
| RZ-26 | Valid, and medium rather than low: every privileged start, a keep mask's included, must carry an update valid for one slot, which a Safe cannot time, and the keep mask is the documented recourse around a frozen leg (V5-L3) and Ondo's corporate actions | Open, the owner's call: a guardian key with tooling that times the start as the keeper does, or a keep-mask start that skips the read RX-3 added. Recorded in `docs/known-limitations.md` | none |
| RZ-27 | Valid, a pre-mainnet check | Open: it is part of the settlement on a real Hermes update already on the pre-mainnet list | none |
| RZ-28 | Valid, documentation | Fixed: the factory's header and `maxPlatformFeeBps` say that no higher rate can land, that any policy change moves the address `predictIndexAddress` gave, and that the referral share needs no bound, since it only splits the platform's part | none |
| RZ-29 | Valid | Fixed. Treasury calls no longer reset the ceiling, so the invariant holds across any run of them; the per-call `assertLe`s were and remain the per-step checks | `invariant_RS1_...` |
| RZ-30 | Valid | Partly fixed: the keeper e2e's fake Hermes signs `/latest`, one update per publish time; the e2e passed with it on 2026-11-01 (20/0). Open: a request scenario | none |
| RZ-31 | Valid | Fixed: the two tests expect `V3TooMuchRequested()` and `InsufficientOutput(15e6, type(uint256).max)` | the two tests |
| RZ-32 | Valid | Fixed. The handler tries a stranger at the hold-off's last second and asserts it is refused and `canStartRebalance()` is false; a hub mutant that lets strangers in one second early fails `test_XS16_handlerReachesEveryPath` | the hub invariant suite |
| RZ-33 | Valid | Open: vectors near a `mulDiv`'s 256-bit edge and the `uint96` boundary need new kinds in the exact model | none |
| XA-34 | Regression, valid | Open: the WBTC drill (`test/fork/WeightedHub.fork.t.sol`) and `testFork_pythIsPyths` keep a bare `vm.expectRevert()`; pinning their revert data needs a fork run | none |
| XA-36 | Regression, valid | Fixed in the unit suites: `test_holdersLeaveWhileAComponentIsFrozen` expects the token's `"paused"`, and RZ-31's two | those tests |

The informational section is not addressed by this pass, except the moving average `verifiedPrices` now checks (RY-7).

### Gates of the fixes

- `forge fmt --check` (both projects), `forge build --sizes --deny warnings`, `forge lint -D notes`: clean. The hub stays
  98 bytes under EIP-170; the zap is 15,214 bytes.
- `forge test --no-match-path 'test/fork/*'`: 532 pass (the six probes moved out of `test/`, three tests added).
- `forge coverage --no-match-path 'test/fork/*'`: 100% of lines, statements, branches and functions in every file.
- `forge test --root keeper --no-match-path '*fork*'`: 63 pass. `node --test keeper/test/unit/*.test.mjs`: 131 pass.
- `aderyn .`: no issue. `wake detect all src`: no detections.
- Not run: the five fork suites, which the zap's change requires before merging, and both end-to-end tests. This
  session had no archive RPC.

