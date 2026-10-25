# Review of the restock change, 2026-10-25

The restock change of 2026-10-19 (`keeper/restock.mjs`, `keeper/restock/`, `keeper/bot/needs.mjs`, the treasury's
functions in `KeeperExecutor` and their tests), uncommitted on branch `restock` on top of `b12b7ce`, was reviewed before
its first commit: the executor's diff line by line against Wormhole's Token Bridge
(`ethereum/contracts/bridge/Bridge.sol`), an invariant suite written for it, the restock end-to-end test on forks, and
two read-only reviewers, one on the service's sending, journal and attestations (their findings A1 to A4), one on its
planning (B1 to B6). Every claim was checked against the code, and reproduced, before it was recorded here.

**Result.** No path to protocol funds: the executor holds no role in the protocol, and the restock change adds none.
Fifteen findings are confirmed and fixed below: three in the executor, two where the bot's own flows raised the caps the
owner sets on its hot keys (RS-1, RS-2) and one where an owner's figure refused the restocked coins (RS-6), and twelve
in the service. Each costs the operator's working capital at most, and none needs anything but the operator's own keys
to recover. The one medium in the service, RS-8, turned any 15 minutes of keeper downtime into a round trip of the whole
stock.

Each id is `RS-…`. A fixed finding's test carries its id, as `AGENTS.md` gate 6 requires, and each fix was checked
against mutants that remove it: every one of them fails its test.

| Id | Verdict | Finding | Status |
|---|---|---|---|
| RS-1 | Confirmed, medium | Restocking raised the keeper's stock allowance by figures no owner set, undoing CF-1's bound | Fixed: the owner's `restockAllowance` bounds what arrivals earn, and the planner stays within it. `test_RS1_*`, node `RS-1: ...` |
| RS-2 | Confirmed, low | The treasury could hold more USDC off the float than the owner's figure | Fixed: `treasuryUsdcOut` counts what it holds, and the owner's figure caps it. `test_RS2_*` |
| RS-3 | Confirmed, low | A buy landed short by floating point, and its dust bought `RESTOCK_MIN_USD` more, sold the round after | Fixed: buys counted in the coin's units, and the buffer's remainder below the minimum waits while home covers the need. Node `RS-3: ...` |
| RS-4 | Confirmed, low | A sweep counted the float a buy in the same round spends | Fixed: the sweep counts what the round's buys leave. Node `RS-4: ...` |
| RS-5 | Confirmed, low | A mined move could be dropped as never sent, on a failed or lagging receipt lookup (also A1) | Fixed: `restock/sending.mjs` resumeMove. Node `RS-5: ...` |
| RS-6 | Confirmed, low | An owner's stock allowance at its most made every redemption of the coin overflow | Fixed: the credit is bounded by what the stock allowance can still hold. `test_RS6_*`, `KeeperExecutor.invariant.t.sol` |
| RS-7 | Confirmed, low | A buy larger than what was left of the day's budget was dropped, not cut: with the defaults, no shortfall of $20,000 or more was ever bought (B1) | Fixed: cut to the budget; the config refuses a transfer cap below the smallest trade. Node `RS-7: ...` |
| RS-8 | Confirmed, medium | A missing, unreadable or stale needs board read as no needs, so the service sold and bridged home the whole stock (B2) | Fixed: such a board is unknown, and nothing moves until the keeper writes it. Node `RS-8: ...` |
| RS-9 | Confirmed, low | Spare stock counted transfers still on their way, so stock the fills needed went home (B3) | Fixed: spare is what the executor holds. Node `RS-9: ...` |
| RS-10 | Confirmed, low | Coins at home were sold as soon as the need was met, the buffer ignored, then bought back (B4) | Fixed: they top the stock up to the buffer first. Node `RS-10: ...` |
| RS-11 | Confirmed, low | A sweep ignored `RESTOCK_MAX_TRANSFER_USD` (B5; its other half is RS-4) | Fixed: capped. Node `RS-11: ...` |
| RS-12 | Confirmed, low | Every approval was unlimited and never reset, to routers, bridges, CCTP and the executor (B6) | Fixed: exact approvals. Node `RS-12: ...`, end-to-end allowances |
| RS-13 | Confirmed, low | The journal was not flushed before a broadcast, an empty one started afresh, and a change whose save failed was kept (A3) | Fixed: `restock/journal.mjs` fileStore and change. Node `RS-13: ...` |
| RS-14 | Confirmed, low | A VAA, a CCTP message or a sequence was taken without checking it was the move's, and a wrong one was stored for good (A4) | Fixed: each checked against the move, and verified on the receiving chain before it is stored. Node `RS-14: ...` |
| RS-15 | Confirmed, low | Commits priced at 1.2 times the base fee got stuck and queued the chain's next transactions; a replacement's receipt was taken for the move's (A2) | Fixed: twice the base fee, one transaction at a time per chain, replacements told apart. Node `RS-15: ...` |

## RS-1: restocking raised what a stolen keeper key can take (confirmed, medium)

CF-1 (`audit/2026-10-13-security-audit.md`): anyone can create a factory index and hold all its shares, so the keeper
key can deliver the executor's stock into an index it owns and redeem it; the fix made the owner's stock allowance the
bound, spent by every delivery from stock. `redeemBridged` added every arrival to that allowance (`stockAllowance[token]
+= amount`), and the service buys again whenever stock falls short of the keeper's needs. So restocked coins earned
allowance no owner had set: a stolen keeper key could deliver every coin the treasury bridged in, and the service would
buy the next ones, bounded only by the treasury's USDC and `RESTOCK_DAILY_USD`. The bot operator's working capital, as
CF-1's; no protocol funds.

Reproduced before the fix: with no restock allowance granted,
`test_RS1_bridgedStockBeyondTheRestockAllowanceFillsNothing` filled an auction from bridged-in stock (`next call did not
revert as expected`), and `test_RS1_bridgedStockEarnsAllowanceOnlyWithinTheOwnersRestockAllowance` saw 5e8 credited
against a grant of 3e8.

**Fix.** `restockAllowance[token]`, which only the owner sets (`setRestockAllowance`), is how much more of a coin
arriving through the bridge may earn stock allowance; each credit spends it. An arrival beyond it stays in the executor
as stock the keeper cannot deliver until the owner allows it, and `BridgedIn` now reports what arrived and what it
earned. The planner (`restock/plan.mjs`) brings in and buys only within what is left of it, counts transfers on their
way only as far as it goes, and names the owner's call when it is spent or below `RESTOCK_MIN_USD`. Without that, a
spent allowance would have kept the coin short and the service buying coins that earn nothing until each day's budget
ran out. Everything the keeper can deliver from stock, restocked coins included, is again a figure the owner set.

Tests: `test_RS1_bridgedStockEarnsAllowanceOnlyWithinTheOwnersRestockAllowance`,
`test_RS1_bridgedStockBeyondTheRestockAllowanceFillsNothing` (CF-1's path, end to end) and
`test_RS1_onlyTheOwnerSetsTheRestockAllowance` in `keeper/test/KeeperExecutor.t.sol`; five node tests `RS-1: ...` in
`keeper/test/unit/restock-plan.test.mjs`; `testFork_aBridgedTransferArrivesAndIsCredited` spends the owner's grant on
Wormhole's real Token Bridge; the restock end-to-end test checks the grant spent by exactly what arrived.

## RS-2: the treasury could hold more USDC than the owner's figure (confirmed, low)

`setTreasuryUsdcAllowance` was documented as "the most USDC the treasury may hold off the float" (`keeper/README.md`),
but it set what the treasury could still draw, and `repayUsdc` added back everything repaid. Two ways past the figure: a
repayment beyond what was drawn, which the service makes from the proceeds of stock sold at home whenever the treasury
holds more than twice `RESTOCK_TREASURY_TARGET_USD`, raised the allowance above it (figure 1,000, draw 600, repay 900:
allowance 1,300); and setting the figure while the treasury held some ignored what it held.

**Fix.** `treasuryUsdcOut` counts what the treasury holds off the float: each draw adds to it, and each repayment takes
off what arrived, down to zero. The owner's figure is now `treasuryUsdcCap`, and `treasuryUsdcAllowance()` is the cap
less what the treasury holds, so the service reads it unchanged. What the treasury repays beyond what it drew joins the
float and raises nothing.

Tests: `test_RS2_aRepaymentBeyondWhatWasDrawnRaisesNothing` and `test_RS2_theOwnersFigureCountsWhatTheTreasuryHolds`;
`test_theTreasuryDrawsAndRepaysWithinItsAllowance` is unchanged and passes.

## RS-3: a buy landed short by floating point, and its dust bought more (confirmed, low)

The planner priced every buy through USD and back, `amountOut = unitsOf(usdOf(rest))`: an amount of some 2e21 wei
through a JavaScript number, so an exact-output buy landed up to a few hundred thousand wei off what was missing. The
restock end-to-end test on a fork of Base caught it: AERO's need of 1,876.76 and its 10%, at $0.6927, was bought 393,216
wei short (`FAIL the home wallet holds 2064.43 AERO: the need and its 10% buffer`). The next round, bringing those coins
in, found the dust still missing, and since every shortfall bought at least `RESTOCK_MIN_USD`, it bought $200 more AERO,
which the round after, the need covered, sold (`AERO bought 200 USD on base`, then `AERO sold 200 USD on base`): two
swaps' fees and loss and two transactions' gas for nothing, whenever the round trip lands short.

**Fix.** The buy is counted in the coin's units: what is missing, raised to the minimum trade, capped by
`RESTOCK_MAX_TRANSFER_USD` and by what the restock allowance has left; its USD follows from it. A remainder below the
minimum trade is not bought when the coins at home, with the usable stock and what is on its way, already cover the
need: it is only the buffer, which is there so that a need that grows a little starts no new buy. A shortfall of the
need itself still buys at least `RESTOCK_MIN_USD`.

Tests: `RS-3: a buy is for exactly what the need and its buffer lack, not that amount through floating point` (the end-
to-end test's numbers, to the wei) and `RS-3: coins at home that cover the need are brought in, and the buffer's last
wei starts no buy` in `keeper/test/unit/restock-plan.test.mjs`; `a small shortfall still buys RESTOCK_MIN_USD, so fees
do not eat it` is unchanged and passes.

## RS-4: a sweep counted the float a buy in the same round spends (confirmed, low)

The planner reserved a buy's `maxIn` from the float but decided the sweep from the float read before the round
(`home.floats`), and the buy runs first. In the end-to-end test the round that received the funding bought AERO with it,
then tried to send back 1,444.30 of the 1,944.30 USDC the buy had spent (`base sweep failed: Error(ERC20: transfer
amount exceeds balance)`, refused at gas estimation, so nothing was signed). Had the buy found no route within
`ROUTE_MAX_LOSS_BPS`, the sweep would have sent the float the buy waits for back to Ethereum, for the next round to draw
and fund it again: a CCTP round trip, with Ethereum gas, for as long as the pool stays thin. With a little more float
the sweep goes through after the buy and leaves the float below its target: 12,000 USDC, a buy of up to 3,333 and a
sweep of 7,000 leave 1,667 of a 5,000 target.

**Fix.** The sweep counts what the round's buys leave of the float. Test: `RS-4: a sweep in the same round as a buy
counts the float the buy may spend`; `idle float above twice its target comes home to the treasury, ...` is unchanged
and passes.

## RS-5: a mined move could be dropped as never sent (confirmed, low)

A move left signed, its receipt not in within three minutes or the service restarted, is looked at again each round: its
receipt if it was mined; otherwise its transaction is sent again or, its nonce spent, the move is dropped. The receipt
lookup swallowed every error (`.catch(() => null)`), so a lookup that failed (a 429 from a public RPC, a timeout), or a
node behind the one that counted the nonce, made a move whose own transaction had spent the nonce look orphaned, and it
was dropped, logged as `its nonce was used by another transaction`. The journal stopped counting it as on its way and
the service never redeemed or received it: a transfer into the executor waited for its VAA to be redeemed by hand while
the planner, counting nothing on its way, bought and bridged the coins again, and a CCTP burn waited to be received by
hand. The funds stay recoverable by the operator. The first reviewer found it too, on its own (A1), and rated it medium;
low here, since it needs a receipt that did not come in three minutes, or a restart mid-commit, before a lookup fails.

**Fix.** `keeper/restock/sending.mjs` (resumeMove), without dependencies so the unit tests reach it: only viem's
`TransactionReceiptNotFoundError` means no receipt, and any other failure is thrown, for the round to look again. A move
whose nonce is spent but whose receipt no node serves is dropped only when a look `ORPHAN_SECONDS` (60) after the first
that found it so still finds none; a receipt served meanwhile settles it.

Tests: three node tests `RS-5: ...` in `keeper/test/unit/restock-sending.test.mjs`, against a fake client, and the
restock end-to-end test, which now looks twice, a minute apart, before it drops the move whose nonce another transaction
took.

## RS-6: an owner's stock allowance at its most refused every restocked coin (confirmed, low)

The stock allowance has no unlimited value: each delivery from stock subtracts from it (`stockAllowance[token] -=
fromStock`). An owner who set it to the most a uint256 holds, the natural way to say no limit, and granted a restock
allowance made `redeemBridged` overflow on `stockAllowance[token] += credited` (panic 0x11) for every transfer of the
coin: the coins stayed in the bridge until the owner changed a figure, while the service retried the redemption each
round. The line the RS-1 fix replaced, `stockAllowance[token] += amount`, overflowed the same way. The invariant suite
below found it in its first runs and shrank it to two calls: `setStockAllowance(2^256 - 1)`, then a redemption of 500
coins.

**Fix.** The credit is also bounded by what the stock allowance can still hold, and what it cannot take stays in the
restock allowance, so an arrival never changes the two together.

Tests: `test_RS6_aStockAllowanceAtItsMostDoesNotBlockARedemption` (an allowance 1e8 short of its most: 3e8 arrive, 1e8
is credited and 4e8 of the restock allowance kept; a second arrival is taken in and earns nothing), the invariant
suite's `test_handlerReachesEveryPath`, and its invariants.

## RS-7: a buy larger than the day's budget left was dropped, not cut (confirmed, low)

The planner skipped any buy that cost more than what was left of `RESTOCK_DAILY_USD` (`if (usd > budget) continue`)
instead of cutting it. With the defaults, a day's budget (20,000) below the largest transfer (25,000), a coin short of
$20,000 or more, its buffer counted, was never bought, every round noting `past RESTOCK_DAILY_USD for the day` on a day
with nothing spent; the second reviewer's run: XRP at $2 and a need of 15,000, $33,000 short, no action. On a day partly
spent, a shortfall above what was left waited for the next day rather than buying what was left. Restocking failed at
its job for every large need; no funds were at risk.

**Fix.** A buy is cut to what is left of the day's budget, after the transfer cap and the restock allowance, and none is
made only when what is left is below `RESTOCK_MIN_USD`. Since every buy is now cut to `RESTOCK_MAX_TRANSFER_USD` as
well, the configuration refuses one below `RESTOCK_MIN_USD`.

Tests: `RS-7: a buy larger than what is left of the day's budget is cut to it, not skipped` (the defaults: $20,000 of
the $33,000 bought; $15,000 spent, $5,000 bought; $50 left, none), in `keeper/test/unit/restock-plan.test.mjs`, and
`RS-7: a transfer cap below the smallest trade is refused, ...` in `restock-config.test.mjs`. `transfers and buys are
cut to RESTOCK_MAX_TRANSFER_USD, ...` asserted the skip itself, nothing bought with $5,000 of the budget left; it now
asserts the $5,000 buy.

## RS-8: a needs board the keeper stopped writing sent the whole stock home (confirmed, medium)

The keeper writes its board of needs every block; the restock service read it with `totalNeeds`, which took an
unreadable board, and a missing file (`existsSync ? ... : new Map()`), for no needs, and dropped every report older than
15 minutes without asking when the board itself was written: the board's `updatedAt` was written and never read. Any
keeper outage longer than 15 minutes, a crash, a deploy, an RPC down, therefore read as no fill needing anything, and
the planner, every coin covered, sold every coin at home and bridged out all the stock beyond `RESTOCK_KEEP_USD`,
$25,000 a transfer, round after round. The second reviewer's run: 50,000 XRP in the executor and 3,000 at home; all
3,000 sold and 12,499.99999999 XRP bridged out in the first round. When the keeper came back, the service bought it all
again at `RESTOCK_DAILY_USD` a day (and, before RS-7, not at all for a large need): each round trip cost up to
`ROUTE_MAX_LOSS_BPS` twice, gas on two chains and Wormhole's fees, spent the owner's restock allowance again, and left
the fills short for days. A keeper not set to write `NEEDS_FILE`, which is optional in its own configuration, did the
same from the start. Medium: the trigger is routine, and the loss is real and scales with the stock.

**Fix.** A board that is missing, unreadable, without the time it was written or not written for `NEEDS_MAX_AGE_SECONDS`
is unknown, null rather than empty (`bot/needs.mjs` totalNeeds and readNeeds), and the planner, needs unknown, buys,
sells and bridges nothing, noting `the keeper's NEEDS_FILE is missing, unreadable or stale`. Moves already under way
still go on.

Tests: `RS-8: a board that is unreadable, or that the keeper stopped writing, is unknown, not empty` and `RS-8: a board
the keeper never wrote is unknown too` in `keeper/test/unit/needs.test.mjs`, and `RS-8: with the keeper's needs unknown,
no coin is bought, sold or bridged out` in `restock-plan.test.mjs`. `an unreadable board needs nothing` asserted the
finding itself and is replaced. The end-to-end test writes the board before each round, as the keeper does each block.

## RS-9: spare stock counted what was still on its way (confirmed, low)

The planner took the stock to spare as what the executor holds plus what is crossing the bridge toward it, less what the
needs want (`spare = balance + coming - want`), and bridged out of what it holds now. With a need met by what is held
and more on its way, stock the fills needed went home: XRP at $2, a need of 1,000 met by 1,000 held, 1,100 on their way:
750 bridged out, the fills short until the transfer landed, after which more went out. With the need gone and 1,100 on
their way, all 600 held went out, the keep included.

**Fix.** Spare is what the executor holds beyond the needs, their buffer and the keep; what lands goes home in its turn
if it is still spare then. Test: `RS-9: spare stock is what the executor holds beyond the need and the keep, not what is
on its way`.

## RS-10: coins at home were sold as soon as the need was met, then bought back (confirmed, low)

Buys aim at the needs and `RESTOCK_BUFFER_BPS` more, so that a need that grows a little starts no new buy. But once the
stock met the needs, without the buffer, the coins at home were sold whole: the second reviewer's run sold 300 XRP for
at least 594 USDT, and the round after, the need up by one coin, bought 101.1 XRP for $202.20: two trades' loss and gas,
and a bridge transfer's wait, for nothing.

**Fix.** A covered coin's coins at home first top the stock up to the needs and the buffer, as far as the restock
allowance goes and when worth `RESTOCK_MIN_USD` to move, and only the rest is sold; with the restock allowance spent,
none is brought in to earn nothing. Test: `RS-10: coins at home top a covered coin up to its buffer before any is sold`.

## RS-11: a sweep ignored the transfer cap (confirmed, low)

`RESTOCK_MAX_TRANSFER_USD` is documented as the largest single trade or transfer, and funding by CCTP kept to it, but a
sweep did not: a float of 100,000 USDC on Base went home in one burn of 95,000. The reviewer's other half of this
finding, a sweep counting float a buy of the same round spends, is RS-4.

**Fix.** A sweep is cut to the cap, the rest following in later rounds. Draws and repayments move USDC within Ethereum,
between the executor and the treasury, bounded by the owner's figure (RS-2); the README now says so. Test: `RS-11: a
sweep is cut to RESTOCK_MAX_TRANSFER_USD, the rest following in later rounds`.

## RS-12: every approval was unlimited (confirmed, low)

`allow` approved the most a uint256 holds whenever an allowance fell short: the float and every coin to PancakeSwap's
and Uniswap's routers, the coins to Wormhole's Token Bridges, which guardian governance can upgrade, USDC to Circle's
TokenMessengerV2, an upgradeable proxy, and to the executor. Every balance of the hot wallets, present and future, stood
open to a flaw in any of them; a router exploited through its approvals is a known way to lose a wallet. The executor
itself resets its own approval of the bridge to zero.

**Fix.** Each approval is for exactly what its call takes (`restock/sending.mjs` allowExactly): a sale, a bridge
transfer, a burn and a repayment take it all, and a buy leaves at most its slack, the bound it did not need. Tests:
`RS-12: an approval is for exactly what the next call takes, and none when it may already`, and the end-to-end test,
which checks, after each chain's flows, no allowance left to the router, the bridge, CCTP or the executor, and the
float's to the router within a buy's slack.

## RS-13: the journal could lose a move already sent, or forget them all (confirmed, low)

The journal was written to a temporary file and renamed into place, never flushed to the disk. A power cut in the
moments after a broadcast could lose the entry of a transaction already sent, its funds then untracked and planned
again; on file systems that do not order a file's data before its rename, the journal could come back empty, which the
service read as no journal at all (`saved ? JSON.parse(saved) : ...`), forgetting every move in flight. And a save that
failed, a full disk, left the move in memory: the next round resumed it and broadcast a transaction the disk did not
hold.

**Fix.** `restock/journal.mjs`: `fileStore` writes the temporary file, flushes it, renames it into place and flushes the
folder, before the transaction it records is sent; a journal that is empty or unreadable stops the service rather than
starting it afresh; and every change is made to a copy, kept only once it is saved.

Tests: `RS-13: an empty or unreadable journal stops the service, never starts it afresh`, `RS-13: a change whose save
fails is not kept, ...` and `RS-13: the journal reaches the disk before the transaction it records is sent` (the order
of the calls, on a real folder) in `keeper/test/unit/restock-journal.test.mjs`.

## RS-14: an attestation was taken without checking it was the move's (confirmed, low)

Wormholescan's VAA and the first message Iris listed were taken as the move's without a look at what they were, and the
sequence by which a VAA is fetched was read from any log in the form of the core's `LogMessagePublished`, not only the
core's own. A wrong answer, validly signed, was stored at `attested` and never fetched again: a transfer in reverted at
every redemption, for good; a transfer out completed someone else's, which anyone may complete, marked the move done and
left its own waiting; a CCTP move received another message. Nothing could be stolen, since the chains verify the
signatures, payload 3 binds the recipient and the rest mint to their own recipients. A VAA from the right emitter that
the receiving chain refuses, corrupt or signed by a guardian set it no longer accepts, was stored the same way, for
good.

**Fix.** `restock/attestations.mjs`: a VAA's emitter chain, emitter and sequence must be the move's; a CCTP message's
domains, mint recipient, sender and amount must be, the move's picked among the messages Iris lists; the sequence comes
only from the log of the core the Token Bridge names; and before either is stored, the receiving chain accepts it: the
core's `parseAndVerifyVM`, or a simulated `receiveMessage` (a message received already counts). Anything else is thrown,
and the next round fetches again. Against Ethereum's real core, `parseAndVerifyVM` answered `valid=false`, `guardian set
has expired`, for a VAA of junk.

Tests: six node tests `RS-14: ...` in `keeper/test/unit/restock-attestations.test.mjs`, with VAAs and CCTP V2 messages
laid out as the guardians and Iris give them; the end-to-end test redeems and receives only what passes them.

## RS-15: a stuck commit held its chain, and a replacement's receipt passed for its own (confirmed, low)

Commits took viem's fees, the base fee times 1.2 plus the tip: two full blocks of rising base fee (26.6%) left one
unincludable until the fee came back down. Meanwhile each round sent more on that chain, queued behind it: a redemption
of the same transfer every round, each timing out after three minutes, all mined once the spike passed, the redundant
ones reverting. An operator who replaced the stuck one by hand was tracked wrongly: viem's `waitForTransactionReceipt`
answers with the receipt of whatever was mined on the nonce, which `commit` recorded as the move's own. A cancel's
receipt made a bridge move `sent` with no Wormhole message, its transfer counted on its way for good; a sped-up CCTP
burn was looked up on Iris by a hash never mined.

**Fix.** Fees allow twice the base fee plus the tip, as the keeper's (`bot/math.mjs` feesFor), so a transaction stays
includable through six full blocks of rising fees and still pays only what its block charges; a legacy gas price, paid
in full, keeps viem's margin. Read on the live chains: Ethereum, base fee 32,552,914 wei, viem's 39,063,496 and now
65,105,828, twice the base fee and the tip; Base the same. Nothing is signed on a chain while a transaction of the
treasury's is pending there. A receipt for another hash is told apart: the same call, repriced, and the move goes on
under the hash mined; another call, a cancel among them, and the move is dropped, since nothing it committed left the
wallet, and the failure thrown (`restock/sending.mjs` settleCommit).

Kept by design, and documented: a transaction a longer spike outprices waits it out, the chain's next ones behind it;
and the treasury's transactions are never sped up by hand, since after a restart a speed-up cannot be told from a
cancel. A cancel by hand, to clear one stuck for good, is handled.

Tests: five node tests `RS-15: ...` in `keeper/test/unit/restock-sending.test.mjs`.

## Status of the fixes (2026-10-25)

Gates, on the working tree:

- `forge fmt --check --root keeper` and `forge fmt --check`: clean. `forge build --root keeper --force`: "Compiler run
  successful!", no warning; the warning that `test_constructor` could be `view`, there before the restock change, fixed.
  `forge lint --root keeper -D notes`: nothing.
- `forge test --root keeper` with `MAINNET_RPC_URL` at Tenderly's public archive: 64 passed, 0 failed, 0 skipped: the
  executor's 59, the invariant suite (64 runs of 32 calls, no revert) and its `test_handlerReachesEveryPath`, and the
  fork suite's three on Wormhole's real Token Bridge. The invariants also ran 512 runs of 64 calls, 32,768 calls, none
  failing.
- `node --test keeper/test/unit/*.test.mjs`: 126 passed, 0 failed. `forge test --match-path test/Repo.t.sol`: 16 passed.
- The restock end-to-end test, `MAINNET_RPC_URL=<Tenderly's public archive> RESTOCK_E2E_CHAINS=base npm run
  e2e:restock`, on a frozen copy of the tree: 29 passed, 0 failed, Ethereum forked at block 26,268,086 and Base at
  53,061,362. AERO, a need of 1,908.28 at $0.6812: the float drawn from the executor and sent by CCTP, 2,099.11 bought,
  the need and its buffer, and bridged in once, with no buy of dust after it (RS-3) and no failed sweep (RS-4); bridged
  out down to the $300 keep and sold at home; the float swept home and the treasury's excess repaid; no allowance left
  standing (RS-12); a signed move resumed once, and one whose nonce another transaction took kept at the first look and
  dropped a minute later (RS-5). Its first run, before RS-3 and RS-4, passed 24 of 25 and showed both. BNB Chain,
  Optimism and Avalanche were not run again after the review.
- `keeper/test/KeeperExecutor.invariant.t.sol`, new: the treasury's arrivals of any size, bridging out, draws and
  repayments, more than it drew when sales at home brought it more, and the owner's three figures at any value up to
  2^256 - 1, in any order, each call required to succeed (`fail_on_revert`, set for the keeper as at the root). Each
  step is checked where it happens: an arrival earns exactly what arrived within both allowances and raises nothing,
  bridging out raises nothing, and after a draw the treasury holds no more USDC than the owner's figure; and after every
  call, what the executor counts as held covers what the treasury holds and stays within the most the owner ever set.
  RED before the RS-6 fix (the overflow, shrunk to two calls).

Mutants, each in a copy of the tree, each failing a test named after its finding:

- The executor: crediting the whole arrival, a credit that leaves the restock allowance unspent, a repayment that raises
  the cap, a figure that ignores what is held, a draw not counted as held (RS-1, RS-2); each undone again against the
  invariant suite, with no bound to what the stock allowance can hold and a bound to zero (RS-6); and, for the
  treasury's guards the change added, each of its four `_checkTreasury` calls removed, no check of the token carried,
  crediting the transfer's stated amount rather than what arrived, no check of USDC or of a pinned recipient, the
  bridge's approval left, the allowance not capped after a transfer out, Wormhole's fee not forwarded and a zero bridge
  or treasury accepted.
- The planner: five of RS-1's, six of RS-3's and RS-4's, three of RS-7's, five of RS-8's (the board's reader and the
  planner), one of RS-9's, three of RS-10's, one of RS-11's. RS-1's second, a gap that ignores the restock allowance,
  survived until the test of coins brought in from home beyond it was added.
- The sending, the journal and the attestations: five of RS-5's, two of RS-12's, nine of RS-15's, six of RS-13's (no
  flush of the file, none of the folder, a rename before the flush among them) and seventeen of RS-14's. RS-14's length
  check of a VAA's body survived until the test of a VAA cut short after its sequence was added.

Open, the owner's call:

- A transaction outpriced by a fee spike above twice the base fee it was signed at waits the spike out (RS-15). The
  keeper replaces its own stuck transactions on the same nonce, its fees raised each block within `MAX_FEE_GWEI`
  (XS-13); the restock service could do the same, at the cost of a fee cap of its own and gas spent in spikes.
- The restock end-to-end test runs on forks with a test guardian and a test attester. Wormhole's and Circle's real
  signatures, and the real Wormholescan and Iris, are checked only by a run on the live chains, with the operator's keys
  and funds.
