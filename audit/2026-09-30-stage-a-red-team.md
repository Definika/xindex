# Internal red team of Stage A (2026-09-30)

Three independent reviewers read the new surface at `aea5d58` on branch `v4-stage-a`, each in its own git worktree with
proof-of-concept tests:
- the λ band auction in `IndexHub`;
- the factory, its listings and supply batches, and the scripts;
- `MintRequests` and how it composes with the hub and the zap.

None found anything Critical, High or Medium. The auction reviewer fuzzed 20,000 random rebalance cycles covering:
- 2 to 6 components, with supplies spread over 21 orders of magnitude;
- random batches, keep masks, and issues and redemptions during the notice;
- random fill times and prices.

The band bound, the backing invariant and the views held in every one. Their findings are numbered `SA-01` to `SA-15`
below. A test for a fixed finding carries its id (`test_SA02_...`), as `AGENTS.md` gate 6 requires, and was checked
to fail without its fix.

This was an internal review. The external audit of Stage A is still to come.

## Findings

| ID | Sev | Finding | Status | Evidence |
|---|---|---|---|---|
| SA-01 | LOW | Tether checks only the sender of a `transferFrom`, so a `MintRequests` it had blacklisted still accepted new USDT escrows. `cancel`, `refund` and every fill pay out with `transfer`, which Tether refuses from a blacklisted sender, so each new deposit was trapped; `destroyBlackFunds` could then zero them all. | FIXED | `requestMint` first sends the contract nothing in the named stablecoin, which fails exactly when it is blacklisted or the coin is paused, so the deposit is refused instead of trapped. `test_SA01_aBlacklistedContractTakesNoNewUsdtEscrow` in `test/MintRequests.t.sol`, and `test_SA01_realTetherFreezesAsTheMockDoes` in `test/fork/Security.fork.t.sol` against mainnet Tether. `MockUSDT` now copies Tether's freeze rules (`test_usdt_blacklistAndPause`). Tether destroying escrows already held is a known limitation in the README. |
| SA-02 | LOW | A relisting could move a supply by up to a step, and relistings execute one token at a time, so a stranger could split a revision that moves every supply alike, which trades nothing, into halves that each open a band: about 0.5% of an index to a lone executor over two rebalances. | FIXED | A relisting takes exactly the supply in force (`RelistChangesSupply`), and a batch, which delisted tokens join like any other, is the only way to revise a supply. `ConfigureWhitelist` relists at the supply in force. `test_DA18_CRL03_SA02_aRelistingKeepsTheSupplyInForce` in `test/IndexFactory.t.sol`, `test_SA02_aUniformRevisionOfDelistedComponentsCannotBeSplit` in `test/IndexHub.rebalance.t.sol`, and the factory invariant, whose handler now flags any relisting that moves a supply. |
| SA-03 | INFO | `MAX_BATCH` of 256 could not be proposed as a first batch within EIP-7825's 2^24 gas cap: about 18.9M gas with every slot cold. | FIXED | `MAX_BATCH` is 200, about 14.8M cold, which leaves room for the Safe. `test_SA03_aFullBatchFitsOneTransactionCold` in `test/IndexFactory.t.sol`. |
| SA-04 | INFO | Nothing on chain made supply updates weekly: a batch could be proposed as soon as the last one executed and come due two days later, a step every two days (both the factory and the auction reviewers). The per-rebalance loss bound did not depend on it, but the documented pace did. | FIXED | A batch comes due no sooner than `MIN_SUPPLY_INTERVAL` (7 days) after the last one executed; `lastSupplyUpdate()` reports when. `test_SA04_batchesComeDueAtMostWeekly` in `test/IndexFactory.t.sol`, and the factory invariant's cadence check. |
| SA-05 | INFO | The script's batch modes built a batch while another was live, which the factory refuses and which was measured against supplies about to change. | FIXED | `supplyBatch` and `supplyCalldata` revert `BatchStillLive(deadline)`. `test_SA05_theBatchModesRefuseWhileABatchIsLive` in `test/Scripts.t.sol`. |
| SA-06 | INFO | `Deploy` accepted a guardian, or a broadcasting key, that signs for the owner Safe, so one key could act as the owner and hold its veto. | FIXED | `checkGuardian` reads the Safe's `getOwners()` and refuses both (`GuardianSignsForOwner`, `BroadcasterSignsForOwner`); an owner that answers no signer list is accepted as before. `test_SA06_neitherTheGuardianNorTheBroadcasterSignsForTheOwner` in `test/Scripts.t.sol`. |
| SA-07 | INFO | Settlement amounts were differences of floored backings. On a supply under one index token a shrinking leg released a whole raw unit for a sub-unit change while no growing leg asked for any, so an executor that delivered nothing was paid up to a raw unit per leg. That contradicted the written claims that rounding always favours the holders and that an empty executor cannot settle a fill that buys anything (VR-03). | FIXED | Each leg's change is rounded the holders' way on its own: `⌊S·Δu/1e18⌋` out, `⌈S·Δu/1e18⌉` in. The invariant holds since `⌊a − b⌋ ≤ ⌊a⌋ − ⌊b⌋` and `⌊a + b⌋ ≤ ⌊a⌋ + ⌈b⌉`. `test_SA07_anEmptyExecutorIsPaidNothingOnASubTokenSupply`. RT-12's test is re-targeted as `test_RT12_SA07_eachLegMovesItsChangeInBackingRoundedTheHoldersWay`: a fill still never takes the holders' rounding surplus, which now never falls rather than staying exactly equal. XA-27's test now expects the growing leg of a one-wei supply to ask for its raw unit. |
| SA-08 | INFO | The centred clamp heals the extremes first: while one component's ratio sits more than the band away from the rest, every other moving component is pinned at the opposite bound and its own revision waits. | DOCUMENTED | No value is taken beyond the band. With SA-04 a supply moves at most half a percent a week against up to 1% of correction a cycle, so a lasting lag needs something else, such as a keep mask held over several cycles. `ARCHITECTURE.md` section 3.5, the README's known limitations and `AGENTS.md`. |
| SA-09 | LOW | The README said a blacklisted requester's fills and refunds revert. That holds for Circle but not Tether, which checks neither the recipient nor the caller, so a Tether-blacklisted requester is filled or refunded into a balance they cannot move and Tether can destroy. | DOCUMENTED | The README's known limitations now describe each issuer, and the app checks `isBlackListed(requester)` before showing a USDT request. Confirmed against mainnet Tether by `test_SA01_realTetherFreezesAsTheMockDoes`. |
| SA-10 | INFO | Every escrow shares one contract, so an issuer's only lever over funds a since-sanctioned requester parked there is to freeze everyone's, and a sanctioned requester's USDC escrow can still leave through an accomplice's fill at a limit set earlier. | DOCUMENTED | README known limitations. Isolating each escrow in its own clone was considered; it is left to a later version. |
| SA-11 | INFO | A Circle blacklist of `MintRequests` also stops fills of USDC redemptions, whose escrow is shares, and a pause of either stablecoin stops every fill, cancel and refund in it. | DOCUMENTED | README known limitations. Share escrows still come back through `cancel`. |
| SA-12 | INFO | A request is an option every filler holds until it closes: if a share's worth to the requester collapses after they sign, a filler can still deliver at the old limit, and a public cancel can be overtaken. | DOCUMENTED | The loss is bounded by the requester's own limit. The app defaults to short deadlines and sends cancels through a private relay (README). |
| SA-13 | INFO | USDT's approve-from-non-zero rule was documented for the zap only. | DOCUMENTED | README integration notes, Approvals. |
| SA-14 | INFO | The spec said a fill pays exactly the limit, and `IMintRequests` said every escrow leaves with its request. | FIXED | Both reworded: the requester receives what the filler sends, at least the limit, and an escrow leaves with its request unless its issuer freezes or destroys it. |
| SA-15 | INFO | Documentation figures: `MIN_BAND` was described as twice the widest rounding gap (it is ten times), the worst case was put at 0.14% a day and 41% a year on a 7-day cycle (a cycle takes at least 9 days, so 0.11% and 33%), and the owner's own `cancelRebalance` went unmentioned. | FIXED | The code comment, `ARCHITECTURE.md`, the README, `AGENTS.md`, the design document and its PDF corrected. The owner's cancel adds nothing a hostile owner could not do by no longer revising supplies. |

## Checked and found sound

- **The λ band.**
  - The break-even λ is a weighted average of the stored ratios, so the band bound holds at any prices, whatever the
    rounding.
  - An executor cannot amplify its take by issuing before a fill and redeeming after.
  - No division by zero is reachable: a supply never returns to zero, units never reach zero, and the centre is at least
    half of WAD.
  - Products stay below 2^224.
  - The views agree with what executes.
  - Batches during the notice do not move a pending settlement.
- **The factory.**
  - The step bound holds, and a batch applies whole or not at all.
  - The exclusion between a live listing and a live batch holds at every window boundary.
  - The whitelist array stays exact across delists and relists.
  - `createIndex` bounds and its salt are sound.
  - The guardian can cancel only its own removal, and ownership cannot be renounced.
  - `Deploy`'s remaining checks are sound.
- **`MintRequests`.**
  - No escrow can be taken twice, or by anyone but its filler.
  - Measured amounts cannot be inflated.
  - The USDT fee never leaves a refund short.
  - Deadlines have neither overlap nor gap.
  - A requester can never be a trap recipient of the hub.
  - Every event reports measured amounts.
