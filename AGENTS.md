# AGENTS.md

Guidance for coding agents and humans working in this repository. Codex reads this file; Claude Code reads it through
`CLAUDE.md`, which imports it, so this is the only copy to edit.

## What this is

Xindex smart contracts, v4 Stage A: a Foundry project where users create crypto index tokens (ERC-20) backed in kind,
mint them with USDC/USDT, and burn them into any token through Uniswap's Universal Router, which reaches both V3 and V4
pools. An index's constituents are fixed at creation. Its units follow its components' reference supplies, circulating
supplies the factory owner maintains behind a timelock, so an index holds each component in proportion to its supply:
market-cap weighting without a price. Supplies change in weekly batches of at most half a percent each. After a change,
anyone can trigger a rebalance, which settles through a price-free λ auction. No contract reads a price. Stage A runs on
Ethereum only. Stages B and C add native coins of other chains, held in ownerless vaults
(`design/2026-09-29-v4-hybrid-architecture.md`). v4 replaces v3, which priced through Chainlink and offered a capped
methodology; v3 is tagged `v3.0.0` and never ships on mainnet. The web app lives in a separate repo. For more:
- `ARCHITECTURE.md`: the design as built.
- `design/2026-09-30-v4-stage-a-spec.md`: the Stage A spec.
- `README.md`: the product brief, frontend integration notes and deployment.

## Commands

```bash
forge build --sizes          # compile (must print "Compiler run successful!"); it prints lint findings but still succeeds
forge lint -D notes          # lint gate CI runs: fails on any warning or note
forge fmt                    # format; CI runs `forge fmt --check`
forge test                   # unit + fuzz + invariant tests, no RPC needed; forge auto-loads .env, and a MAINNET_RPC_URL
                             # there makes the fork suites run too (archive node, or FORK_BLOCK, or --no-match-path 'test/fork/*');
                             # an RPC that cannot serve the pinned block fails with that sentence, not a raw fork error
forge coverage               # must stay at 100% for every file (lines, statements, branches, functions)
for c in IndexFactory IndexHub IndexZap MintRequests; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change

# mainnet fork tests (real tokens, Universal Router, V3 and V4 pools); skipped when the env var is unset.
# A rate-limited RPC throttles four suites in parallel: add -j 1.
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# public non-archive RPCs only serve recent state: pin near the head
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/*'
```

Deployment: `script/Deploy.s.sol` then `script/ConfigureWhitelist.s.sol` (see README). Sepolia first needs its test
market from `script/testnet/SetupTestMarket.s.sol`.

## Definition of done for any change

1. `forge fmt --check` clean.
2. `forge build` clean, including `forge lint` (zero warnings and notes). Lint config lives in
   `foundry.toml` `[lint]`; each excluded rule has its reason in the comment block above the list. Do not
   add exclusions without a reason there. Prefer fixing code; use `// forge-lint: disable-next-line(<rule>)`
   or `disable-next-item(<rule>)` only for verified false positives, deliberate behaviour, or vendored code, with a
   one-line reason on the line above. The lint reads OpenZeppelin's internal `Math.mulDiv` as an external call, which
   is the reason for the suppression in `IndexFactory.createIndex`.
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
4. Fork tests green if the change touches `IndexZap`, the hub's rebalancing, routes, token behaviour, or anything
   router- or pool-related. Their summary must list the four `test/fork/` suites and 0 skipped.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the three documented suppressions are on the `redeem` call in `IndexZap._burnBasket`, the `permit` call in
   `IndexZap.burnToTokenWithPermit`, and the executor callback in `IndexHub._settle`. Two more, on
   `VaultMessages.VaultMessage` and `VaultMessages.encode`, cover the half of the Stage B message format that only the
   Ethereum side uses; they go when that side is built.
6. Every testable finding of the security reviews keeps its regression test passing, named after its id. A test that
   covers two findings carries both ids. The id families:
   - v1 findings: by their v1 id.
   - v2 rebalancing findings: `R01`..`R23`.
   - The whole-repo audit of 2026-09-16: `XA..` (`audit/2026-09-16-whole-repo-audit.md`, triaged in
     `audit/triage.md`).
   - The logic review of 2026-09-18: `LR..` (`audit/2026-09-18-logic-review.md`).
   - The deep audit of 2026-09-19: `DA..` (`audit/2026-09-19-deep-audit.md`, triaged in
     `audit/2026-09-19-triage.md`).
   - The verification review of 2026-09-21: `VR..` (`audit/2026-09-21-verification-review.md`).
   - The security audit of 2026-09-23: `CR-M01`, `CR-L01`..`CR-L08` and `CR-I01`..`CR-I41`
     (`audit/2026-09-23-security-audit.md`, triaged in `audit/2026-09-23-triage.md`). These ids keep the review's
     prefix because M01, L03, L06, L08, I02, I03 and I09 to I12 are already v1 ids, so a CR test is named
     `test_CRM01_...`, `test_CRL03_...` or `test_CRI25_...`.
   - The red team of 2026-09-24: `RT-01`..`RT-25` (`audit/2026-09-24-red-team.md`), a test named `test_RT01_...`.
   - The internal red team of Stage A on 2026-09-30: `SA-01`..`SA-15` (`audit/2026-09-30-stage-a-red-team.md`), a test
     named `test_SA01_...`. SA-08 to SA-15 were fixed or recorded by documentation alone and have no test.

   Find a test by its id. Most v1 and R tests are in `test/Security.t.sol` and `test/fork/Security.fork.t.sol`. The R
   tests that drive the λ auction directly (R04, R08, R14, R17, R19, R22) are in `test/IndexHub.rebalance.t.sol`,
   some beside a `test/Security.t.sol` twin. Some ids no contract test can reach:
   - L06 and FR06 are `test_L06_checkOwner` and `test_FR06_checkGuardian`, and FR05 is the two `test_FR05_*` tests,
     all in `test/Scripts.t.sol`.
   - I09, I10, I11, L08 and FR04 are in `test/Repo.t.sol`: the known-limitations section, the pinned compiler, the
     pinned CI toolchain and required fork RPC, and the dependency lock against `.gitmodules`. CI also compares the
     committed submodule commits, which needs git.

   Every XA, LR, DA, VR, CR, RT and SA test sits in the suite of what it checks, and in `test/Repo.t.sol` when what it
   checks is a repository file.

   Some ids have no test of their own; each report's triage gives the evidence:
   - XA-19 to XA-21, XA-32 to XA-37, XA-41, XA-63 and XA-65 changed only tests and mocks, or refactored without
     changing behaviour.
   - DA-12, DA-21 and DA-23 have no code fix.
   - Findings fixed by documentation alone have none, among them VR-05, RT-02, RT-07, RT-08, RT-09, RT-11 and RT-18.
     RT-20 was already a known limitation.

   Two records list the ids whose mechanism is gone, with the test that went and the property, if any, that survives:
   - `audit/2026-09-22-v3-retirement.md`: the move from Uniswap V3 prices to Chainlink.
   - `audit/2026-09-30-v4-stage-a-retirement.md`: Stage A's removal of every price. It retires 31 tested ids in full,
     retires CR-I36, CR-L08 and VR-06 in part, and names the test of every re-targeted id.

   The ids tested at `v3.0.0`, less those tested now, are exactly the ids that record retires in full. A change that
   removes an id's last test adds its row to a retirement record in the same commit. Do not restore a retired id's test
   against the new design; if the property matters here, it gets a new id from the review of this surface.

CI enforces items 1 to 5: fmt, build, `forge lint -D notes`, tests, 100% coverage on every file and `wake detect all
src`. The fork suites run on every push from this repository, because the test step passes the `MAINNET_RPC_URL` secret
unconditionally. On `main` and on pull requests into it the secret is also required, so a missing one fails the run
rather than letting the suites skip. Check a run's test summary rather than assuming. Run everything locally before
pushing. A pull request from a forked repository gets no secrets, so its fork suites skip, and a maintainer re-runs
them before merging.

## Layout

```
src/IndexHub.sol              index implementation (ERC20 + permit + in-kind issue, redeem, redeemSkipping, claim, the λ rebalance auction), cloned
src/IndexFactory.sol          listings, reference supplies and weekly supply batches, guardian, registry, CREATE2 clone deployer with units from k
src/IndexZap.sol              stateless Universal Router mint/burn router, a venue per leg, per-leg limits, nonce check
src/MintRequests.sol          ownerless escrow of USDC/USDT-for-shares requests at the requester's own limit, filled by anyone
src/interfaces/               IIndexHub, IIndexFactory, IIndexZap, IMintRequests, IXindexErrors (shared errors), IRebalanceExecutor, IUniversalRouter,
                              and for Stage B IXindexVault and IEthereumEventVerifier
src/libraries/PathLib.sol     V3 packed path decoding (shared with test mocks)
src/libraries/UniversalRouterCommands.sol  the router command bytes the zap emits, vendored with their input layouts
src/libraries/UniswapV4Types.sol           V4 actions, PathKey and the swap params, vendored from v4-periphery (MIT)
src/libraries/VaultMessages.sol            Stage B: the one encoding of the messages Ethereum sends a vault
src/vault/XindexVault.sol     Stage B: the ownerless vault on an EVM chain, native coin per index, speed limit, freeze (not deployed)
test/*.t.sol                  unit / fuzz / invariant / script tests
test/XindexTest.sol           state and listing helpers the factory, hub, zap and security suites share
test/Security.t.sol           regression tests for the security review findings (see gate 6 for ids tested elsewhere)
test/Repo.t.sol               repository facts findings rest on: pinned compiler, CI gates and toolchain, dependency lock, ABIs, no price, docs
test/mocks/                   mock tokens, WETH, a strict Universal Router, V3 pools for the testnet script, the market fixture (+ Mocks.t.sol)
test/fork/                    test-only mainnet addresses, end-to-end fork tests, a V3 rebalance executor, fork security regressions
script/                       Deploy, ConfigureWhitelist, MainnetAddresses (the one copy of mainnet addresses and dated reference supplies)
script/interfaces/            the Safe, WETH and Uniswap setup calls the scripts make
script/testnet/               SetupTestMarket and FaucetToken: the Sepolia test market (never deploy on mainnet)
abi/                          generated ABIs the web app decodes with; CI regenerates them and fails on a diff
design/                       the v4 design and its PDF, the Stage A and Stage B specs, the prototype record, the PDF builder, and the analysis scripts (their data is not committed)
audit/                        review reports, their triages, and the two retirement records
prototype/                    the proving prototype: an SP1 workspace and its own Foundry project (via-IR); the gates skip it and Wake excludes it
```

## Design rules that must not be broken

- **No price in any contract.** No contract reads a price, a feed or a pool's state to size, gate or value anything.
  Amounts come from supply and units, and units come from reference supplies. `test_noContractReadsAPrice` in
  `test/Repo.t.sol` fails if `src/` or `abi/` names an oracle or a pool's price. Valuing an index is the app's job,
  off-chain. The zap swaps, but it reads no price either: it enforces the limits its caller sets.
- **Value-bearing amounts are in-kind.** `IndexHub` only ever moves amounts derived from supply and units: issue,
  redeem, claims and rebalance settlements. Never compute an amount from balances (balances only verify), and never
  add a share price to the hub. `_backing(shares, units, rounding)` is the one place that turns shares and units into an
  amount, and the seam a fee model would change. Stage A has no fee (the owner's call on 2026-09-30, design §13.1), so
  no fee code goes in; a fee, if one comes, arrives with a later index version through this seam. No
  share can be sent to the index itself or its factory: `_update` refuses both, because neither can ever move a share
  on (CR-I01, RT-21).
- **No admin power over funds, no rebalancing key.**
  - The factory owner proposes three things: listings and supply batches (each behind `LISTING_DELAY`, 2 days) and
    guardian changes (behind `GUARDIAN_DELAY`, 7 days). Anyone can execute a proposal, but only within
    `PROPOSAL_WINDOW` (7 days) after its delay. The owner also delists and transfers ownership.
  - The guardian can: cancel pending listings and supply batches; delist; cancel a rebalance; start one with a keep
    mask; start one before strangers may; and cancel a guardian change that would remove the role. It cannot block its
    own replacement.
  - There is no pause, no upgrade, no sweep, no renounce, no instant guardian change, and no keeper or bot role. Keep
    it that way.
  - The owner's power over supplies is data, not custody. A batch moves each supply at most `MAX_SUPPLY_STEP` (0.5%),
    visibly, behind the delay and the guardian's `cancelSupplies`. Every change then passes through the λ band. A
    hostile owner with a colluding lone executor therefore takes at most the band per rebalance, 0.995% of the moving
    value, and a rebalance comes at most every 9 days: about 33% a year, and only if nobody ever competes and the
    guardian never cancels. The owner can also cancel rebalances as the guardian can, which adds nothing a hostile
    owner could not do by no longer revising supplies.
  - `cancelRebalance` has no window and no rate limit. A hostile or compromised guardian can cancel each auction at its
    last second and hold rebalancing off while the units drift from the supplies. That stall is bounded by the owner
    replacing the guardian, which takes `GUARDIAN_DELAY` and which the guardian cannot cancel. It moves no funds, and
    holders redeem throughout. A cancel budget was considered and rejected: it would trade that bounded stall for the
    guardian's ability to stop a second bad snapshot in a row, which is the power's whole purpose. This is a trust
    assumption of the role, stated among the guardian's powers and the known limitations, not an oversight to close
    silently (DA-12).
  - The guardian can also stall without a cancel. A keep-mask rebalance that leaves a pair of components moving can
    clear `MIN_BAND` on a sliver of the index, and its fill restarts `MIN_REBALANCE_INTERVAL` for everyone. The stall
    can therefore outlast the guardian's replacement by up to a week. While a replacement is pending, the owner cancels
    the outgoing guardian's keep-mask proposals, and monitors watch `RebalanceStarted` with a non-zero `keepMask`
    (RT-07).
  - An expired proposal leaves `pendingGuardian`, `pendingGuardianEta`, `listingEta` and a batch's `eta` set. The views
    that say whether a proposal is still executable are `guardianChangePending()`, `listingPending(token)` and
    `suppliesPending()` (DA-16).
- **Fixed constituents, supply-following units.** The token list is immutable after `initialize`.
  - **At creation**, `createIndex(name, symbol, tokens, k)` sets each component's units to `⌊k · supply / 1e36⌋` from
    the reference supplies in force. Each must lie in `[MIN_RAW_UNITS, MAX_UNITS]`, else `UnitsOutOfRange`. The floor
    is 10,000 raw units, so no component starts coarse (DA-09). The ceiling is `uint96.max >> 10`, which leaves room
    for about 690 full-band rebalances of growth.
  - **After creation**, units change only in `executeRebalance`, by the λ auction.
  - **Start.** A permissionless `startRebalance` snapshots the band once `MIN_REBALANCE_INTERVAL` (7 days) has passed.
    The auction opens after `REBALANCE_DELAY` (2 days) of notice and runs for `AUCTION_DURATION` (24 hours).
  - **The band.** For each moving component, ρ = units / supply, taken relative to the first moving component, which
    cancels that component's own figures exactly. Each ratio `r` is ρ divided by the midpoint of the smallest and
    largest ρ, clamped to `1 ± MAX_SUPPLY_STEP`. `λmax` is the largest `r` and `λmin` the smallest. Centring before
    clamping means a wide band narrows to exactly `[1 − STEP, 1 + STEP]` and never collapses, so no gap between supplies
    and units can stall it. That is what replaced RT-04's shortfall.
  - **Refusal.** A start reverts `BandTooNarrow` when `λmax < λmin · (1 + MIN_BAND)`, with `MIN_BAND` 0.1%. This
    covers nothing changed, every supply changed alike, and a single moving component (R19).
  - **Settlement.** λ falls linearly from `λmax` to `λmin` over the auction. The decrement rounds down, so λ rounds up,
    towards the holders. New units are `⌈λ · units / r⌉`, and each leg's change in backing is rounded the holders' way,
    down when it leaves and up when it comes back (SA-07). A settlement that would send nothing out settles at `λmax`,
    so nobody is paid for an empty or dust index (R14, XA-27).
  - **The bound.** At any prices, a fill leaves holders at least `λmin / λmax` of the moving value, at most 0.995%
    below it. The break-even `λ* = Σ u·p / Σ (u/r)·p` is a weighted average of the ratios, so it stays inside the
    band whatever prices do between start and fill (DA-05's successor). The factory's step per batch and the hub's
    clamp per rebalance make the bound together; neither suffices alone. Without the clamp, batches landing between
    rebalances would widen the band past the step. Without the step, one batch could move a supply by any factor.
  - **Whole-moving-value exposure.** The bound applies to the whole moving value, not the traded value. A 0.5% revision
    of a 1% component trades 0.005% of the index but opens a 0.5% band. That is inherent to a price-free scalar
    auction, and the README states it among the known limitations.
  - **Extremes first.** The clamp heals the extremes first: while one component's ratio sits more than the band away
    from the rest, every other moving component is pinned at the opposite bound, and its own revision waits until the
    far one has converged. It takes nothing beyond the band. With weekly steps of half a percent and a band of up to
    1% per cycle, a component can stay ahead only if something else moved it, such as a keep mask (SA-08).
  - **Re-anchoring.** Every fill re-anchors the units to the supplies, so keep-mask skew and rounding drift heal rather
    than compound (`testFuzz_repeatedFillsConvergeToTheSupplies`).
  - **Leaving.** Holders who dislike a pending rebalance leave during the notice. Once the auction is live, an executor
    watching the mempool can order its fill ahead of a public redeem or guardian cancel. An exit sent then pays that
    holder's share of the executor's take, like every other holder's, and no nonce can undo a haircut that landed
    first. Shares issued while a rebalance is pending share the haircut of any fill that lands after them, however the
    two are ordered (RT-02).
  - **Restarts.** A cancel, or an auction that expired unfilled, holds strangers off for `REBALANCE_DELAY`, so the owner
    and guardian get the first restart; the trigger stays permissionless after that. `canStartRebalance` answers
    whether strangers may start. After an expiry the hold-off runs from the auction's last fillable second, so it is a
    second shorter (CR-I02). `canStartRebalance` answers false for a clone that was never initialized (DA-22). It does
    not read the band, so a start can still revert `BandTooNarrow`; `previewBand` answers that.
  - **Keep mask.** Only the owner or guardian can pass one, and it routes around a component that cannot be moved.
    A kept component's supply is not read, its ratio takes no part in the band's centre, and its units stay exactly as
    they were. `executeRebalance` reads `balanceOf` only on a component that sends or receives something, so a
    component whose `transfer` or `balanceOf` reverts, or whose contract no longer answers at all, is skipped (DA-14,
    RT-01).
- **Supplies are timelocked data, moved in steps.**
  - **Listing.** A listing sets a token's first reference supply, non-zero and at most `MAX_SUPPLY`
    (`SupplyOutOfRange`). A relisting takes exactly the supply the token still carries (`RelistChangesSupply`), since
    delisting keeps the supply in force: relistings execute one token at a time, so one that moved a supply would let a
    stranger split a revision that moves every supply alike, and trades nothing, into halves that each open a band
    (SA-02, extending DA-18 and CR-L03).
  - **Batches.** After listing, a supply changes only through a batch:
    - `proposeSupplies(tokens, supplies)`: owner only, one batch live at a time, tokens strictly ascending, at most
      `MAX_BATCH` (200) of them, the most a first batch fits in a transaction with every slot cold (SA-03). Each token,
      listed or delisted, must carry a supply and have no live listing, and each new supply must stay within
      `MAX_SUPPLY_STEP` of the one in force. The batch comes due `LISTING_DELAY` later, and never sooner than
      `MIN_SUPPLY_INTERVAL` (7 days) after the last batch executed (SA-04).
    - `executeSupplies`: anyone, within the window. It applies the whole batch or nothing.
    - `cancelSupplies`: the owner or the guardian.
  - **Exclusion.** A live listing and a live batch exclude each other (`ListingPending`, `TokenInBatch`), so nothing a
    listing was checked against can change during its notice.
  - **Nothing live.** Nothing reads a token's own `totalSupply` or any balance to find its supply. Anything read live
    inside a start's transaction could be moved there, as wstETH's supply could with a free flash loan, or as an
    exclusion list's balances could (CR-M01, DA-10).
  - **Pace.** At most one executed batch a week, enforced on chain, so a supply moves at most half a percent a week
    whoever holds the owner key; that follows supply growth of up to about 30% a year.
- **Invariant:** for every component `i`,
  `token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]`. Rounding always goes the
  holders' way:
  - issue rounds up and redeem rounds down;
  - new units round up, so a settled basket is never worth less than the band allows (DA-01);
  - a claim is recorded only for an amount that stayed in the index;
  - a rebalance moves each leg's change in required backing, rounded down when it leaves and up when it comes back,
    so an executor never collects rounding dust, even on a supply under one index token (SA-07).

  The rebalance post-check is the invariant with the new units, plus the whole of `amountsIn` on top of what the index
  held. So surplus from rounding or a donation stays with the holders instead of paying for part of a fill. The
  invariant test enforces this; keep it passing.
- **Holders can always leave.** `redeemSkipping` must keep working when any subset of components is frozen, claims must
  be payable once transfers resume, and neither the notice nor the auction ever freezes issue or redeem. A claim is
  booked to `to`, who receives every other component of that redemption, and `ClaimRecorded` names `to`, so a router
  redeeming on a holder's behalf does not strand the skipped components (DA-17).
- **Index addresses commit to their contents.** Clones are CREATE2-deployed from a salt over the creator, the name, the
  symbol, the token list and the computed units, not `k` (LR-05). Do not switch back to CREATE.
- **Only initialized clones issue, redeem or rebalance.** Keep the `onlyInitialized` guard on every function that mints,
  burns or touches a rebalance.
- **Executors are untrusted.** Tokens and the callback go only to `msg.sender`, every mutating entry point shares the
  reentrancy guard, and state is written before any rebalance transfer. `executeRebalance(bytes)` settles whatever the
  supply in the settling block requires. The `executeRebalance(bytes, uint256[] maxAmountsIn)` overload bounds that, and
  reverts `RebalanceMovedOn` when the settlement has grown past what the caller will deliver. Issue stays open through
  notice and auction, so a dust issue can grief an executor sized from an off-chain simulation: the callback arguments
  are authoritative (DA-13). At `MAX_COMPONENTS` (100), the hub's own paths fit a transaction under EIP-7825's 2^24 gas
  cap with room to spare, the largest being redeem at about 3.7M gas (`test_aHundredComponentsFitOneTransaction`). Swaps
  for 100 legs do not fit, so an atomic fill that wide needs an executor that already holds the tokens.
- **The zap is stateless and replaceable.** New UX features (ETH in/out, aggregators, mixed-venue legs) go in a new or
  extended zap, never in the hub or factory. The app caps a zap basket at about 35 components, which is where 16.78M gas
  runs out.
  - **Venue.** It swaps through Uniswap's Universal Router, pinned to the 2.0.0 deployment. Each leg names exactly one
    venue: a packed `v3Path` or a hookless `PathKey[] v4Path`, never both and never neither, else `BadRoute(i)`.
  - **Commands.** The zap builds every command and every action itself and forwards nothing a caller supplied. The
    router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`, which move a payer's funds, so passing
    calldata through would hand a caller the router's permissions.
  - **Payment.** It pays by pre-funding the router and appending `SWEEP` back to itself in the same `execute`, so
    nothing it sent can be left where anyone could take it. There is no Permit2 approval and no allowance to reset.
  - **Spend bound.** The sweep's minimum is zero, so it never fails a call. What bounds a leg's spend is the amount
    pre-funded. That is also the only bound on a V4 exact-output route that revisits `tokenIn`, since the pinned
    periphery does not hold such a route to its `amountInMaximum` (upstream #564; CR-I06, CR-I14).
  - **Unsold input.** The sweep returns the router's whole balance of the token, a stray one included. So a hop's unsold
    input is measured as what came back, `balance + given - before`, never as what was spent. Measured the other way, a
    stray larger than the spend underflowed, and anyone could revert a public burn for gas (CR-L02).
  - **V4 routes.** A V4 route must be hookless (`hooks == 0` and empty `hookData`). A hookless key cannot carry the
    dynamic-fee flag, so that one equality covers the flag bits too. `address(0)` is allowed only as an intermediate,
    because native ether must never reach the zap, which has no `receive()`.
  - **Checks.** The zap must:
    - validate every route's endpoints;
    - honour every leg's limit, including the pass-through leg, whose component is already `tokenOut` on a burn or
      `tokenIn` on a mint (DA-15);
    - check `expectedNonce`;
    - measure what the user pays and receives as balance changes inside the call, never using tokens already in the
      zap;
    - check each mint leg's delivered component balance against what the index needs (`ShortFill`). This is
      load-bearing, not defensive: the pinned periphery does not itself check exact-output delivery.
  - **Burn legs.** It sells a V3 burn leg one hop at a time and sends every hop's unsold input to the recipient. A V4
    burn leg is a single multi-hop action, because inside one V4 action an intermediate partial fill leaves an unsettled
    credit and the leg reverts atomically. As a rule only its first hop can leave unsold input, which `SWEEP` returns
    and the zap forwards. A route that comes back to the component can leave some from a later hop too, returned the
    same way (CR-I07). Unsold `tokenOut` stays in the zap and is paid out.
  - **Never.** It must revert on transfer shortfalls, and never call `redeemSkipping` or `executeRebalance`. With
    `redeemSkipping` the zap receives the basket, so the claim would be booked to the zap and could never be collected.
  - **Errors.** Swap failures reach the caller unchanged. The router wraps a command in `ExecutionFailed` only when it
    dispatched it with a low-level call. Swaps are internal calls, so what surfaces is the pool's own revert:
    `V3TooMuchRequested`, `V4TooLittleReceived` and their neighbours. That was verified against the pinned deployment
    on a fork, which is why `IUniversalRouter` does not declare `ExecutionFailed` at all.
- **MintRequests holds only open escrows.** A requester escrows USDC or USDT for at least `minShares` of a factory
  index, or shares for at least `minOut` of a stablecoin. Anyone fills before the deadline, and the requester's limit is
  the only valuation: nothing reads a price.
  - No owner, no upgrade, nothing to configure. Every entry point shares one reentrancy guard. The contract never calls
    `approve`, and a filler pays the requester directly.
  - Every amount is measured where it lands. An escrow is the balance increase its request caused, so a USDT fee
    switched on at any time can never leave the last refund short. A fill must put at least the limit into the
    requester's balance, fee included. Each request is closed before any token moves.
  - The requester may `cancel` at any time. After the deadline, which is at most `MAX_REQUEST_DURATION` (30 days) away,
    anyone may `refund` the escrow to the requester. A fill pays exactly what the filler sends, so any surplus over the
    limit goes to the fastest filler, which is why the app suggests limits. Stray tokens sent to the contract stay
    there, since nothing may take them.
  - The invariant suite holds the contract's balance of each token at exactly its open escrows plus donations, under
    any interleaving with Tether's fee switch.
- **Checks-effects-interactions.** Emit events and write state before external calls where the data is available; make
  the call into a user-supplied address the last interaction when possible.
- **Standard ERC-20s only as components** (whitelist policy). `issue` rejects fee-on-transfer tokens by checking the
  received amount. How a component's supply is minted does not matter, since nothing reads it (CR-M01). Do not
  whitelist USDC/USDT as components in scripts or docs; they are fine as mint/burn currencies. The script's policy
  also wants 6 to 18 decimals, which now matter only to display. Pausable components such as WBTC must be labelled in
  the app, and so must every other issuer a component adds, starting with WBTC's custodian.

## Conventions

- `pragma solidity 0.8.28;` in `src/` and `script/`; tests use `^0.8.24`. The compiler is pinned to 0.8.28 in
  `foundry.toml`, and CI pins Foundry v1.8.1 and eth-wake 4.22.1 in `.github/workflows/test.yml`.
- **Wake config.** CI generates its Wake config from `foundry.toml` and adds `audit/` and `prototype/` to its excluded
  folders: the PoC tests in `audit/` only compile inside `test/poc/` of the audited commit, and `prototype/evm` is a
  separate Foundry project that needs via-IR, so either would stop Wake before any detector runs. The Wake VS Code extension reads `.vscode/settings.json` instead, which holds three things:
  - its copy of `forge remappings` (paste the new output there whenever a dependency or remapping changes);
  - the optimizer settings of `foundry.toml` (without them the factory's initcode looks too large to deploy);
  - Wake's default excluded folders plus `audit/` and `prototype/`.
- OpenZeppelin v5.7.0 and forge-std v1.16.2, pinned in `foundry.lock`; the staged submodule commits must match
  it, and CI checks that. The hub uses the upgradeable ERC20 because clones skip constructors, and the
  storage-based `ReentrancyGuard` because its zeroed slot is "not entered" in a clone.
- **Vendored code** keeps its license header and names its source commit:
  - `IUniversalRouter` and `UniversalRouterCommands` come from Uniswap's universal-router (GPL-3.0-or-later) at
    `3663f6db6e2fe121753cd2d899699c2dc75dca86`, which is tag 2.0.0 and the deployment the zap is pinned to.
  - `UniswapV4Types` comes from v4-periphery (MIT) at `444c526b77d804590f0d7bc5a481af5a3277c952`, the commit that
    router was built against.

  A vendored struct may retype `Currency` and `IHooks` to `address`, which is ABI-identical. Change vendored code only
  to replace a dependency, never to restyle. Both router libraries record the input layout of every command and action
  they name, from `Dispatcher.sol` and `Actions.sol` at those commits, because that layout is what the zap encodes
  against.
- Custom errors, not revert strings. An error that more than one contract raises is declared once, in
  `src/interfaces/IXindexErrors.sol`, which the factory, hub and zap interfaces extend. Tests name it
  `IXindexErrors.<Error>.selector`, because Solidity does not resolve an inherited error through
  `IIndexFactory.<Error>`. Immutables in SCREAMING_SNAKE_CASE. Loop counters initialised explicitly (`uint256 i = 0`).
  Modifier logic lives in a private function.
- `foundry.toml` keeps `dynamic_test_linking = false`. With forge's default, a test function ends at the first
  `vm.expectRevert` followed by `new` of a `src/` contract, reported as a pass, and every check after it is skipped
  (LR-01). It also keeps `[invariant] fail_on_revert = true`: the handler only makes calls that must succeed, so a
  handler action that can legitimately revert has to check its precondition first (`canStartRebalance()`,
  `previewBand`, a live batch, a non-zero balance).
- **A regression test has to fail without its fix.** Check it against the old code or a mutant before relying on it.
  The logic review found tests that passed either way: mocked return values instead of the real flow, prices that never
  moved between two snapshots, a salt whose fields were never varied one at a time. Mutants worth rerunning on the
  hub: plain arithmetic in place of the band's `mulDiv`, a floor in place of the ceiling on new units, no clamp, and λ
  rounded down.
- **Tests.**
  - One `*.t.sol` per contract; the hub's rebalancing and invariants have their own files.
  - Mocks go under `test/mocks/`. Mainnet constants live in `script/MainnetAddresses.sol`, re-exported with test-only
    ones by `test/fork/ForkAddresses.sol`.
  - New behaviour needs a unit test, and a new revert path needs a test hitting the exact error
    (`vm.expectRevert(abi.encodeWithSelector(...))`).
  - Listing in tests goes through `XindexTest._listWith(token, supply)`: `proposeListing`, a `vm.warp` past
    `LISTING_DELAY`, then `executeListing`. Supply changes go through `XindexTest._revise`, a one-batch
    `proposeSupplies` then `executeSupplies`.
  - Compute every argument before `vm.prank`: an external call in the arguments consumes the prank.
  - Measure gas with every touched account cooled first (`vm.cool`), so a call pays the cold reads a transaction of its
    own would.
- **Scripts.** They keep their logic in public functions that take explicit arguments, so tests can call them without
  environment variables: `Deploy.deploy`, which deploys the factory, the zap and `MintRequests`, and
  `ConfigureWhitelist.propose`, `execute`, `proposeSupplies` and `executeSupplies`. Environment variables are process-global and tests run in parallel, so each variable name is
  set by exactly one test (see `test/Scripts.t.sol`). In tests, script broadcasts come from `DEFAULT_SENDER`.
- **Deployment rules.**
  - Deployments never use raw private keys: `--account` keystores or `--ledger`.
  - `OWNER` and `GUARDIAN` are required.
  - On mainnet the owner must be a contract that is not an EIP-7702 delegated account. A Safe owner must need at least
    `MIN_OWNER_THRESHOLD` (3) signatures, the design's 3-of-5 (the owner's call on 2026-09-30), and have no enabled
    module.
  - When the owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers (SA-06).
  - Neither role may be a market contract: the router and its PoolManager, and on chain 1 every token and mint
    currency in `script/MainnetAddresses.sol` (CR-I37).
- **Mainnet addresses** are verified on-chain before being committed: tokens by symbol and decimals, and the router and
  the PoolManager by their runtime code hashes, since every Universal Router build answers `poolManager()` alike
  (CR-I35). `test/fork/MainnetAddresses.fork.t.sol` checks `script/MainnetAddresses.sol` that way. It also lists the
  default whitelist on a fresh factory, and `test_CRL08_theDefaultListIsTheReleaseRecord` pins the default list against
  a table written independently of it. Every reference supply carries its source and date in a comment beside it. The
  WBTC address is `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one.

## Product decisions already made (do not re-litigate silently)

**v4 replaces v3** (the owner's call on 2026-09-30). v3 stays at the `v3.0.0` tag and on Sepolia and never launches on
mainnet. Its recorded decisions were Chainlink USD feeds, the capped 30/20 methodology, a monthly cadence, the seven-token
launch whitelist and `MAX_COMPONENTS` of 20. Each is superseded as follows, and `audit/2026-09-30-v4-stage-a-retirement.md`
records what went with them:

- **Prices.** No contract reads a price (the design of 2026-09-29, revised after the external review). Units follow
  reference supplies, which is market-cap weighting without a price. The uncapped methodology is the only one; capped
  30/20 is gone, and so is the settlement ratio. The index price is still the basket's value in dollars, not a divisor
  level, but the app computes it off-chain.
- **Cadence.** Weekly supply batches, each supply within 0.5% of the one in force, and `MIN_REBALANCE_INTERVAL` of
  7 days (the owner's call on 2026-09-30). There are 2 days of notice and a 24-hour auction that falls from `λmax` to
  `λmin`. Monthly updates would have followed only about 6.7% a year of supply growth.
- **Components.** Up to `MAX_COMPONENTS` (100) per index. The flagship follows the design's weight floor (§2.1): it
  holds only tokens whose weight in the holdable universe is at least 0.2% and that pass the liquidity screen, daily
  volume of at least 0.1% of market cap, which drops LEO. A coin joins at 0.2% and leaves only below 0.1%, so borderline
  coins do not churn between versions (the floor buffer, the owner's call on 2026-09-30).
- **Stage A whitelist.** WETH, WBTC, LINK and UNI, each with a dated reference supply (`script/MainnetAddresses.sol`).
  WBT stays off: a single key can blacklist any holder and destroy its balance, and no Uniswap pool holds it on
  Ethereum (`design/2026-09-30-wbt-check.md`, the owner's call on 2026-09-30). The whitelist follows from the floor,
  the screen, the listing check and the
  owner's preference for native coins in vaults over wrapped ones. Bitcoin is held as WBTC only (the owner's call on
  2026-09-29; do not reopen it).
- **Fees.** None in Stage A: audits, the bounty and watchers are funded from outside (the owner's call on 2026-09-30,
  over a minter fee in shares or a management fee, design §13.1). A later version could add one; only `_backing` and
  its callers would change.
- **Stage B and C limits.** `SPEED_LIMIT` and `MINT_CAP` are 4% a day (the owner's call on 2026-09-30). The guardian's
  freeze expires. Ethereum verifiers rotate every 30 days. Script-only chains are out.

Unchanged from v3:
- Ethereum mainnet first.
- Execution through Uniswap's Universal Router 2.0.0, with the venue chosen per leg by the caller. That decision of
  2026-09-22 superseded SwapRouter02 and QuoterV2 (`audit/2026-09-22-v3-retirement.md`).
- Fixed constituents; no protocol bots or hot keys; component whitelist only.
- The burner chooses the exit token, and the mint currency is not tracked per holder.

If a change would alter any of these, say so explicitly.

## Not in Stage A (candidate backlog)

- A fee, in a later index version.
- `mintWithETH` / `burnToETH`, `createAndMint`, `mintWithTokenPermit` for USDC.
- Creator fees (attribute them by `creatorOf`, never by name).
- Constituent changes.
- Mixed-venue legs (a single leg splitting across V3 and V4).
- Per-pair partial-fill auctions.
- A backstop executor or trigger reminder.
- An aggregator or Universal Router 2.1 zap.
- V4 pools on Sepolia, so the V4 legs get a testnet rehearsal rather than only fork and mock coverage.
- Everything multichain: vaults, proofs, the mirror and the rest of Stages B and C.
