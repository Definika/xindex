# AGENTS.md

Guidance for coding agents and humans working in this repository. Codex reads this file; Claude Code reads it through
`CLAUDE.md`, which imports it, so this is the only copy to edit.

## What this is

Xindex smart contracts: a Foundry project where users create crypto index tokens (ERC-20) backed in kind, mint them with
USDC/USDT, and burn them into any token via Uniswap V3. An index's constituents are fixed at creation; its units follow
an on-chain market-cap rule (uncapped, or capped at 30/20 for ranks 1 and 2) that anyone can trigger monthly and that
settles through an auction. The web app lives in a separate repo. See `ARCHITECTURE.md` for the design and `README.md`
for the product brief, frontend integration notes, and deployment.

## Commands

```bash
forge build --sizes          # compile (must print "Compiler run successful!"); it prints lint findings but still succeeds
forge lint -D notes          # lint gate CI runs: fails on any warning or note
forge fmt                    # format; CI runs `forge fmt --check`
forge test                   # unit + fuzz + invariant tests, no RPC needed; forge auto-loads .env, and a MAINNET_RPC_URL
                             # there makes the fork suites run too (archive node, or FORK_BLOCK, or --no-match-path 'test/fork/*');
                             # an RPC that cannot serve the pinned block fails with that sentence, not a raw fork error
forge coverage               # must stay at 100% for every file (lines, statements, branches, functions)
for c in IndexFactory IndexToken IndexRule IndexZap; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change

# mainnet fork tests (real Uniswap V3 / USDC / USDT / WBTC); skipped when the env var is unset
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
   one-line reason on the line above.
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
4. Fork tests green if the change touches `IndexZap`, `IndexRule`, paths, token behaviour, rebalancing, or anything
   Uniswap-related.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the three documented suppressions are on the `redeem` call in `IndexZap._burnBasket`, the `permit` call in
   `IndexZap.burnToTokenWithPermit`, and the executor callback in `IndexToken.executeRebalance`.
6. Every testable finding of the security reviews keeps its regression test passing, named after its id (a test that
   covers two findings carries both): v1 findings by id, v2 rebalancing findings as `R01`..`R23`, whole-repo audit
   findings of 2026-09-16 as `XA..`, the logic review's findings of 2026-09-18 as `LR..`
   (`audit/2026-09-18-logic-review.md`), and the deep audit's findings of 2026-09-19 as `DA..`
   (`audit/2026-09-19-deep-audit.md`). The v1 and R tests live in `test/Security.t.sol` and
   `test/fork/Security.fork.t.sol`, except the ids a contract test cannot reach: L06 and FR06 are `test_L06_checkOwner`
   and `test_FR06_checkGuardian` and FR05 the two `test_FR05_*` tests in `test/Scripts.t.sol`, and I09, I10, I11, L08
   and FR04 are `test/Repo.t.sol` (the known-limitations section, the pinned compiler, the pinned CI toolchain and
   required fork RPC, and the dependency lock against `.gitmodules`; CI also compares the committed submodule commits,
   which needs git). An XA test sits in the suite of what it checks, `test/Repo.t.sol` for a repository file, so find it
   by id. XA-19 to XA-21, XA-32 to XA-37, XA-41, XA-63 and XA-65 have no test of their own, because they changed only
   tests and mocks or refactored without changing behaviour; neither have the findings fixed by documentation alone.
   `audit/triage.md` gives the evidence for each. A DA test sits in the suite of what it checks too, and
   `audit/2026-09-19-triage.md` gives the evidence: DA-01 and DA-08 in `test/Security.t.sol`; DA-02, DA-06, DA-09 and
   the DA-22 value fuzz in `test/IndexRule.t.sol`; DA-13, DA-14 and the DA-22 turnover test in
   `test/IndexToken.rebalance.t.sol`; DA-17 in `test/IndexToken.t.sol`, where
   `test_uninitializedInstancesCannotIssueOrRedeem` carries the DA-22 `canStartRebalance` assertion as well; DA-15 in
   `test/IndexZap.t.sol`; DA-16 and DA-11 and DA-18 in `test/IndexFactory.t.sol`; DA-20 in `test/Scripts.t.sol`;
   DA-05 in `test/IndexToken.rebalance.t.sol`, with `test_settlementValues` in `test/IndexRule.t.sol` covering the
   rule's half; DA-10 in `test/Repo.t.sol`, since deleting a struct field is only testable through the shipped ABI.
   DA-03's floors are data, checked from both sides in `test/fork/MainnetAddresses.fork.t.sol`: `checkConfig` refuses a
   floor its pool no longer meets, and `_assertFloorIsNotStale` refuses one that has fallen far under its pool's own
   window. DA-04, DA-07, DA-12, DA-19, DA-21 and DA-23 have no test, because no code fix exists for them: the reason is
   in `audit/2026-09-19-triage.md` and in the design rules below.

CI enforces items 1 to 5: fmt, build, `forge lint -D notes`, tests (fork suites required on `main` and on pull requests
into it from this repository), 100% coverage on every file and `wake detect all src`. Run them locally before pushing;
a fork's pull request skips the fork suites, so re-run them before merging.

## Layout

```
src/IndexToken.sol            index implementation (ERC20 + permit + in-kind issue, redeem, redeemSkipping, claim, rebalance), cloned
src/IndexRule.sol             stateless rule: supplies, Uniswap V3 TWAP prices, weights, rebalance targets, index price
src/IndexFactory.sol          listing delay + token configs + guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              stateless Uniswap V3 mint/burn router with per-leg limits and a rebalance nonce check
src/interfaces/               IIndexToken, IIndexFactory, IIndexRule, IIndexZap, IXindexErrors (shared errors), IRebalanceExecutor, ISwapRouter02, IUniswapV3Pool, IUniswapV3Factory
src/libraries/PathLib.sol     V3 packed path decoding (shared with test mocks)
src/libraries/TickMath.sol    getSqrtPriceAtTick vendored from Uniswap v4-core (MIT)
src/libraries/Methodology.sol methodology ids and the capped minimum
test/*.t.sol                  unit / fuzz / invariant / script tests
test/Security.t.sol           regression tests for the security review findings (see gate 6 for ids tested elsewhere)
test/Repo.t.sol               repository facts findings rest on: pinned compiler, CI gates and toolchain, dependency lock, ABIs, docs
test/mocks/                   mock tokens, WETH, routers, Uniswap V3 pools, factory and position manager, market fixture, rebalance executor (+ Mocks.t.sol)
test/fork/                    test-only mainnet addresses, end-to-end fork tests, fork rebalance executor, fork security regressions
script/                       Deploy, ConfigureWhitelist, MainnetAddresses (the one copy of mainnet addresses and market data)
abi/                          generated ABIs the web app decodes with; CI regenerates them and fails on a diff
script/interfaces/            the Safe, WETH and Uniswap setup calls the scripts make
script/testnet/               SetupTestMarket and FaucetToken: the Sepolia test market (never deploy on mainnet)
```

## Design rules that must not be broken

- **Value-bearing steps are in-kind and oracle-free.** `IndexToken` only ever moves amounts derived from supply and
  units: issue, redeem, claims and rebalance settlements. Never compute an amount from balances (balances only verify),
  never add a share price to the token. Prices from `IndexRule` only shape rebalance targets and display prices.
- **No admin power over funds, no rebalancing key.** The factory owner proposes listings and token configs
  (`LISTING_DELAY`) and guardian changes (`GUARDIAN_DELAY`), each executable only within `PROPOSAL_WINDOW` afterwards,
  delists, and transfers ownership. The guardian can cancel pending listings, delist, cancel a rebalance, start one with
  a keep mask, start one before strangers may, and cancel a guardian change that would remove the role (it cannot block
  its own replacement). No pause, no upgrade, no sweep, no renounce, no instant guardian change, and no keeper or bot
  role. Keep it that way. `cancelRebalance` has no window and no rate limit, so a hostile or compromised guardian can
  cancel each proposal at the last second of its auction and hold rebalancing off while the units drift from the rule.
  It is bounded by the owner replacing that guardian, which takes `GUARDIAN_DELAY` and which the guardian cannot cancel,
  since it may only cancel its own removal and not its replacement; it moves no funds and holders redeem throughout. A
  cancel budget was considered and rejected: it would trade that bounded stall for the guardian's ability to stop a
  second distorted snapshot in a row, which is the power's whole purpose. A trust assumption of the role, stated among
  the guardian's powers and the known limitations, not an oversight to close silently (DA-12). An expired proposal
  leaves `pendingGuardian`, `pendingGuardianEta` and `listingEta` set, so `guardianChangePending()` and
  `listingPending(token)` are the views that say whether one is still executable (DA-16).
- **Fixed constituents, rule-rebalanced units.** The token list is immutable after `initialize`. Units change only in
  `executeRebalance`, from the `IndexRule.targetUnits` snapshot that a permissionless `startRebalance` took after
  `MIN_REBALANCE_INTERVAL`, after `REBALANCE_DELAY` of notice, within the auction's multiplier band: targets lie within
  half to double each component's units, and settled units within half to 2.5 times (the growth scaled by the band). The
  band bounds the multiplier on the bought legs at the snapshot's prices, and says nothing about how far the market
  moves in the up to three days before the fill, so settlement values both sides again in the settling block and
  requires what the index receives to reach `MIN_SETTLEMENT_RATIO` of what it pays out (DA-05). That test is a ratio, so
  a market-wide move reprices both sides together and changes nothing; only drift between the legs sold and the legs
  bought can fail it, and it can only refuse a settlement, never enlarge one. Its cost is liveness: a quiet pool or a
  market that really moved makes the auction expire unfilled. An index with less than one whole token outstanding cannot
  settle at all, because every growing leg rounds to zero while a shrinking one does not. A cancel, and an auction that
  expired unfilled, hold strangers off for `REBALANCE_DELAY` (`canStartRebalance` answers it), so the owner and guardian
  get the first restart; the trigger stays permissionless after that. `canStartRebalance` also answers false for a clone
  that was never initialized and can never rebalance at all (DA-22). `MIN_TURNOVER` is measured as `min(sold, bought) /
  activeValue`, so it certifies value actually traded rather than value merely leaving (DA-08). A keep mask routes
  around a component that cannot be moved: `executeRebalance` reads `balanceOf` only on a component that sends or
  receives something, so a component whose `balanceOf` reverts is skipped as well as one whose `transfer` does (DA-14).
- **Invariant:** for every component `i`,
  `token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]`.
  Issue rounds up, redeem rounds down, the rule rounds a target's share up into units so the target basket is never
  worth less than the one it replaces (DA-01), a claim is only recorded for an amount that stayed in the index, a
  rebalance moves exactly the change in required backing, and its post-check is the invariant with the new units plus
  the whole of `amountsIn` on top of what the index held, so surplus from rounding or a donation stays with the holders
  instead of paying for part of a fill. The invariant test enforces this; keep it passing.
- **Holders can always leave.** `redeemSkipping` must keep working when any subset of components is frozen, claims must
  be payable once transfers resume, and the notice period never freezes issue or redeem. A claim is booked to `to`, who
  receives every other component of that redemption, and `ClaimRecorded` names `to`, so a router redeeming on a
  holder's behalf does not strand the skipped components (DA-17).
- **Index addresses commit to their contents.** Clones are CREATE2-deployed from a salt over the creator, the full
  starting composition and the methodology. Do not switch back to CREATE.
- **Only initialized clones issue, redeem or rebalance.** Keep the `onlyInitialized` guard on every function that mints,
  burns or touches a rebalance.
- **The rule is stateless and its inputs are timelocked.** Token configs change only through the listing flow, and
  wrapped assets use a reference supply. A pool must be the Uniswap V3 factory's own pool for the token and WETH with at
  least `MIN_OBSERVATION_CARDINALITY` slots and a non-zero `minLiquidity` it meets; that cardinality bounds the ring's
  capacity, which anyone can raise, not the history it holds (DA-19). A rebalance snapshot accepts a price only from a
  pool whose newest observation is no older than `MAX_OBSERVATION_AGE` (twenty minutes, two sub-windows, the largest age
  that still leaves the oldest part genuine history for the deviation check to compare against) and from a window whose
  harmonic-mean liquidity reaches that minimum and whose 10-minute parts agree within `MAX_TICK_DEVIATION`; views do not
  apply these checks, and prices never enter settlement. The age check is what keeps the other two meaningful: on a pool
  that has not traded inside the window Uniswap extrapolates every point at the current tick and the current liquidity,
  so the three parts agree exactly and the liquidity is whatever was minted a moment ago (DA-02). Anyone can clear that
  condition by trading the pool; until someone does, a silent component can only be kept or retried.
  `MAX_TICK_DEVIATION` is an outlier filter for a short spike, not a bound on manipulation: a push held steady across
  the whole window moves all three parts equally and reads a spread of zero, and with the spread at 2000 a single
  distorted part still moves the window mean by up to a third of its own shift, about 667 ticks or 6.9%. Comparing each
  part against the window mean instead is the same arithmetic, because that mean is the average of the parts. What is
  left against a sustained push is the per-token `minLiquidity` floor and the cost of holding a pool off-market for
  thirty minutes while arbitrageurs trade against you; claim no more than that anywhere. The floor is therefore the
  lever: the shipped floors are a third of each pool's lowest recent window, raised from a tenth on 2026-09-20, and the
  only other lever, a second price source, is not in v2 (DA-03). The harmonic mean is taken over the whole window and
  its smallest term dominates it, so twelve seconds at liquidity one blocks every snapshot of that component for the
  next thirty minutes: that sensitivity is deliberate, it is the XA-01 defence, and measuring each part separately and
  taking the middle one was rejected because it would equally shake off a real push through an empty range confined to
  one part; the grief is recoverable, because anyone may retry and the griefer has to pay again every thirty minutes
  (DA-04). Under the capped methodology a kept component is priced with the snapshot price too, because its market cap
  sits in the denominator of every other component's weight, which narrows XA-05: under capped a keep mask routes around
  a component that cannot be transferred, not around one whose pool cannot be read, while under uncapped a kept
  component is not read at all (DA-06). `executeListing` is permissionless and re-runs `checkConfig` on the stored
  config before applying it, so a pool that thinned out during the notice is not whitelisted on a validation up to nine
  days old (DA-11). That lets a griefer hold a listing off by keeping the pool thin, but only while they keep paying,
  and the proposal stays executable for the rest of `PROPOSAL_WINDOW`.
- **Executors are untrusted.** Tokens and the callback go only to `msg.sender`, every mutating entry point shares the
  reentrancy guard, and state is written before any rebalance transfer. `executeRebalance(bytes)` settles whatever the
  supply in the settling block requires; the `executeRebalance(bytes, uint256[] maxAmountsIn)` overload bounds that and
  reverts `RebalanceMovedOn` when the settlement has grown past what the caller will deliver. Issue stays open through
  notice and auction, so an executor sized from an off-chain simulation can be griefed by a dust issue: the callback
  arguments are authoritative (DA-13).
- **The zap is stateless and replaceable.** New UX features (ETH in/out, aggregators, V4) go in a new or extended zap,
  never in the token, rule or factory. The zap must validate every swap path's endpoints, honour every leg's limit
  including the pass-through leg, the one whose component is already `tokenOut` on a burn or `tokenIn` on a mint
  (DA-15), check `expectedNonce`, measure what the user pays and receives as balance changes inside the call (never
  using tokens already in the zap), swap a burn leg one hop at a time and send every hop's unsold input to the recipient
  (unsold `tokenOut` stays in the zap and is paid out), revert on transfer shortfalls, and never call `redeemSkipping`
  (the zap receives the basket, so the claim would be booked to the zap and could never be collected) or
  `executeRebalance`.
- **Checks-effects-interactions.** Emit events and write state before external calls where the data is available; make
  the call into a user-supplied address the last interaction when possible.
- **Standard ERC-20s only as components** (whitelist policy). `issue` rejects fee-on-transfer tokens by checking the
  received amount. Components need fixed-supply or governance-minted supply. Do not whitelist USDC/USDT as components in
  scripts or docs; they are fine as mint/burn currencies. Pausable components such as WBTC must be labelled in the app.
  A token's supply is its own `totalSupply` or a reference figure, and nothing else: the config's list of excluded
  holders, whose balances `IndexRule._supply` subtracted with a live `balanceOf` inside the snapshot, is gone, because
  one exclusion a third party could fund and drain would have made that component's market cap manipulable inside a
  single transaction (DA-10). A supply that has to leave holdings out uses a reference supply. A config change moves a
  reference supply by at most `MAX_SUPPLY_CHANGE` (an order of magnitude), which catches the decimals slip and the stale
  figure; a genuine re-founding goes in steps, each behind its own listing delay and guardian veto (DA-18). A component
  whose WETH pool ends with zero in-range liquidity takes no config at all: `minLiquidity` of zero is rejected as
  `InvalidMinLiquidity` and any positive value as `ThinPriceHistory`, so delisting and the keep mask are the escapes
  until the pool recovers by itself (DA-07). An index should start priced at roughly 10,000 raw units of every component
  or more, which for WBTC at 110k USD is about 11 USD a token: a coarser index token makes one raw unit of a component a
  larger share of it, and `initialUnits` reverts `StartPriceTooLow` rather than flooring a component at one raw unit
  (DA-09).

## Conventions

- `pragma solidity 0.8.28;` in `src/` and `script/`; tests use `^0.8.24`. The compiler is pinned to 0.8.28
  in `foundry.toml`, and CI pins Foundry v1.8.1 and eth-wake 4.22.1 in `.github/workflows/test.yml`. CI generates
  its Wake config from `foundry.toml` and adds `audit/` to its excluded folders, because the PoC tests there only
  compile inside `test/poc/` of the audited commit and would stop Wake before any detector runs. The Wake VS Code
  extension reads `.vscode/settings.json` instead: its copy of `forge remappings` (paste the new output there whenever
  a dependency or remapping changes), the optimizer settings of `foundry.toml` (without them the factory's initcode
  looks too large to deploy), and Wake's default excluded folders plus `audit/`.
- OpenZeppelin v5.7.0 and forge-std v1.16.2, pinned in `foundry.lock`; the staged submodule commits must match
  it, and CI checks that. The token uses the upgradeable ERC20 because clones skip constructors, and the
  storage-based `ReentrancyGuard` because its zeroed slot is "not entered" in a clone.
- Vendored code keeps its license header and names its source commit (`TickMath` from Uniswap v4-core
  `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`); change it only to replace a dependency, never to restyle.
- Custom errors, not revert strings. An error that more than one contract raises is declared once, in
  `src/interfaces/IXindexErrors.sol`, which the factory, rule, token and zap interfaces extend; tests name it
  `IXindexErrors.<Error>.selector`, because Solidity does not resolve an inherited error through
  `IIndexFactory.<Error>`. Immutables in SCREAMING_SNAKE_CASE. Loop counters initialised explicitly (`uint256 i = 0`).
  Modifier logic lives in a private function.
- `foundry.toml` keeps `dynamic_test_linking = false`: with forge's default, a test function ends, reported as a pass,
  at the first `vm.expectRevert` followed by `new` of a `src/` contract, and every check after it is skipped (LR-01).
  It also keeps `[invariant] fail_on_revert = true`: the handler only makes calls that must succeed, so a handler
  action that can legitimately revert has to check its precondition first (`canStartRebalance()`, a non-zero balance).
- A regression test has to fail without its fix. Check it against the old code or a mutant before relying on it: the
  logic review found tests that passed either way (mocked return values instead of the real flow, prices that never
  moved between two snapshots, a salt whose fields were never varied one at a time).
- Tests: one `*.t.sol` per contract (the token's rebalancing and invariants have their own files), mocks under
  `test/mocks/`, mainnet constants in `script/MainnetAddresses.sol` (re-exported with test-only ones by
  `test/fork/ForkAddresses.sol`). New behaviour needs a unit test; new revert paths
  need a test hitting the exact error (`vm.expectRevert(abi.encodeWithSelector(...))`). Whitelisting in tests goes
  through `MockMarket.config` or `configWith`, `proposeListing(token, config)` (or `proposeConfig` for a config-only
  change), a `vm.warp` past `LISTING_DELAY`, and `executeListing`. Compute a config before `vm.prank`: an external call
  in the arguments consumes the prank.
- Scripts keep their logic in public functions that take explicit arguments (`Deploy.deploy`,
  `ConfigureWhitelist.propose` and `execute`) so tests can call them without environment variables. Environment variables
  are process-global and tests run in parallel, so each variable name is set by exactly one test (see
  `test/Scripts.t.sol`). In tests, script broadcasts come from `DEFAULT_SENDER`.
- Deployments never use raw private keys: `--account` keystores or `--ledger`. `OWNER` and `GUARDIAN` are
  required. On mainnet the owner must be a contract that is not an EIP-7702 delegated account, and a Safe owner
  must need at least two signatures and have no enabled module.
- Mainnet addresses are verified on-chain before being committed: tokens by symbol, pools with the Uniswap V3 factory's
  `getPool`; `test/fork/MainnetAddresses.fork.t.sol` checks `script/MainnetAddresses.sol` that way. Reference supplies
  and minimum liquidities carry their source and date. The WBTC address is
  `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one.

## Product decisions already made (do not re-litigate silently)

Ethereum mainnet; Uniswap V3 (SwapRouter02 + QuoterV2, pool time-weighted prices for the rule); fixed constituents with
units that follow an on-chain rule; methodologies uncapped market cap and capped 30/20 (at least 5 components; the 20%
cap applies to every component below the largest, changed from the Numbers model's closed form on 2026-09-17);
rebalance targets are the water-filling of value by weight within the half-to-double bounds (a component clipped to
its floor is no longer handed value back, changed on 2026-09-18, LR-02); monthly
cadence with 2 days of notice and a 24-hour auction from 1.5 to 0.9 on the bought legs; no protocol bots or hot keys; no fees; component whitelist only (no synthetics for L1 coins without a mainnet wrapper);
burner chooses the exit token (mint currency is not tracked per holder); the index price is the basket's value, not a
divisor level. The Numbers model's tokens were examples; its methodology is the requirement. Rationale in
`ARCHITECTURE.md`. If a change would alter one of these, say so explicitly.

## Not in v2 (candidate backlog)

`mintWithETH` / `burnToETH`, `createAndMint`, `mintWithTokenPermit` for USDC, creator or protocol fees (attribute them
by `creatorOf`, never by name), constituent changes, a Chainlink price adapter for thin pools, per-pair partial-fill
auctions, a backstop executor or trigger reminder, Universal Router / V4 / aggregator zap, synthetic exposure for L1 coins.
