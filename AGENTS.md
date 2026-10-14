# AGENTS.md

Guidance for coding agents and humans working in this repository. Codex reads this file; Claude Code reads it through
`CLAUDE.md`, which imports it, so this is the only copy to edit.

## What this is

Xindex smart contracts, v5: a Foundry project where users create crypto index tokens (ERC-20) backed in kind, mint
them with USDC/USDT, and burn them into any token through Uniswap's Universal Router, which reaches both V3 and V4
pools. Creators choose each coin's percentage, fixed at creation with the coin list, and the index
rebalances back to those percentages at Pyth prices, through a permissionless auction. Only that settlement reads a
price; issue, redeem and claims never do. The web app lives in a separate repo.

**Xindex is one deployment, on Ethereum, and one index holds up to 100 coins of the top 300** (the owner's decision
of 2026-10-10, `design/2026-10-10-one-index-wormhole-legs.md`). `WeightedIndexFactory`, `WeightedHub`, `IndexZap` and
`MintRequests` hold Ethereum ERC-20s in kind: the issuer's own contract where Ethereum has one (71 candidates of the
top 300 today), and otherwise a copy wrapped by Wormhole's token bridge from the chain that has it (17 from BNB Chain,
nine of them Binance-Peg; 31 from Solana, Sui, Aptos, Base and the other chains Wormhole serves), priced at the coin's
Pyth feed and labelled Bridged, Custodial as well when the source is Binance-Peg. The list stands at 93
(`script/PythIds.sol`), 14 of them Wormhole copies, with 34 more copies to attest. The wrapping adds Wormhole's
guardians as a party whose reach is the whole of each wrapped leg, and the app shows every index's wrapped share of
value. They do not sign Pyth's prices: since Pyth's OP-PIP-132 of 2026-08-26, Pyth's contract on Ethereum verifies
updates against Pyth's own set of five keys (read on chain on 2026-10-12). Nothing crosses a chain inside a contract:
the app and the fillers bridge. The BNB Chain deployment of 2026-10-07, shelved on 2026-10-10, was deleted on
2026-10-13 with its address book, list and fork suite. No vault, no proof, no
bridge of our own, no speed limit and no freezer exist any more: Stage B (six vaults, eight state verifiers, the P1
and P2 proofs of Ethereum's finality, the hybrid index) is tagged `stage-b-2026-10-07` and deleted, and
`audit/2026-10-07-stage-b-retirement.md` records what went with it. Earlier: v3 (Chainlink prices, tagged `v3.0.0`),
v4's market-cap index (reference supplies and a price-free λ auction, deleted on 2026-10-06,
`audit/2026-10-06-v4-retirement.md`). Nothing is deployed on a mainnet yet.

Where it stands (2026-10-13):
- The weighted index is built and reviewed twice (`audit/2026-10-05-v5-review.md`, `audit/2026-10-07-v5-logic-review.md`).
- The Ethereum deployment's scripts are built: `DeployWeighted`, `ConfigureWeighted` over `PythIds`, `CheckToken`.
- The hundred-coin list is built as far as Ethereum holds it: 93 listed on 2026-10-10 (the 49 of before, 31 more
  Ethereum-issued coins and 13 Wormhole copies that already existed, every one through `CheckToken` on a fork), 75 of
  them coins that count toward the hundred. 34 copies await an attestation on Wormhole's Portal, a transaction on each
  home chain the owner sends (section 2a of the 2026-10-10 record lists them with the procedure); each then goes
  through the check and the lists. A hundred-coin index is minted in kind or through `MintRequests`, since the zap
  stops near 35 legs. On a fork of 2026-10-11, the 92 coins forge-std can fund issue, rebalance with real transfers
  and redeem in one index, and 45 of them trade through the zap within 2% on $1,000; SNX is out of that test only
  because its balances live in its `TokenState`, beyond forge-std's `deal`. That test's 14.9M gas for the fill counts
  its executor's own `deal` calls; on an anvil fork of 2026-10-12, with Pyth's real contract verifying an update signed
  by keys the test installed in Pyth's receiver, a fill of 93 legs cost 7.26M, Pyth's parse 2.34M of it.
- The keeper bot is built (`keeper/`, the keeper's own Foundry project and Node bot, with unit and end-to-end tests):
  it starts and fills auctions, serves coins without a Uniswap route from its executor's stock, and holds no role.
- The security audit of 2026-10-13 (`audit/2026-10-13-security-audit.md`, Cloudflare's security-audit skill, ids
  `CF-1`..`CF-8`) found no exploitable path in the four contracts that hold index funds; its findings in the keeper,
  CheckToken, the deploy script and CI are fixed, CF-3 is a known limitation below, and CF-2 and CF-8 went with the
  THORChain planner on 2026-10-14 (`audit/2026-10-14-thorchain-retirement.md`).
- Before any mainnet: Pyth's parameter replay (`design/2026-10-05-custom-weights.md`, section 8), a settlement on a
  real update from Hermes (which needs Pyth's API key), a reading of OP-PIP-132 for what it means for Pyth on Ethereum,
  Ondo's corporate-action mechanism for its stock tokens (CF-3), the owner's reading of the verified source of the 44
  tokens listed on 2026-10-10, SAND's first, which `CheckToken` alone admitted (CF-4), the five fork suites run again
  (CF-4 re-pins SAND as review without a fork run), and an external audit; then `DeployWeighted`'s release hashes
  fixed at the audited commit (CF-5).

For more:
- `design/2026-10-05-custom-weights.md`: the v5 spec.
- `design/2026-10-10-one-index-wormhole-legs.md`: the one-index decision, the count of the top 300, the trust table
  and the steps to mainnet.
- `design/2026-10-05-wide-asset-support.md` and `design/2026-10-05-token-admission-report.md`: the lists and the
  admission check.
- `design/2026-09-30-v4-stage-a-spec.md` and `ARCHITECTURE.md`: the Stage A design `WeightedHub` keeps.
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
aderyn .                     # Aderyn on src/, configured by aderyn.toml: must report nothing; CI does not run it
for c in IndexZap MintRequests WeightedIndexFactory WeightedHub; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change
forge test --root keeper     # the keeper's executor, its own Foundry project; CI also runs its fmt, build and lint
node --test keeper/test/unit/*.test.mjs  # the keeper bot's arithmetic, settings, Hermes client and tx tracker (no dependency)

# mainnet fork tests (real tokens, Universal Router, V3 and V4 pools); skipped when the env var is unset.
# A rate-limited RPC throttles five suites in parallel: add -j 1.
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# public non-archive RPCs only serve recent state: pin near the head
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/*'

# the admission check, read-only, before any listing: one report per token for the Safe's signers
CHECK=wide forge script script/CheckToken.s.sol --fork-url $MAINNET_RPC_URL
```

Deployment, once, on Ethereum: `script/DeployWeighted.s.sol`, then `script/ConfigureWeighted.s.sol`, which lists each
coin with its Pyth price id (`script/PythIds.sol`). `script/CheckToken.s.sol` reports on every token before its first
listing; `V5_WHITELIST=default` is the first four coins and `V5_WHITELIST=wide` the rest, 93 in all. On chain 1 the
deploy script resolves Pyth, the router and the stablecoins from the address book and refuses any other address
(`DeployChecks.isPinnedChain`). Sepolia first needs its test market from
`script/testnet/SetupTestMarket.s.sol`.

## Definition of done for any change

1. `forge fmt --check` clean.
2. `forge build` clean, including `forge lint` (zero warnings and notes). Lint config lives in
   `foundry.toml` `[lint]`; each excluded rule has its reason in the comment block above the list. Do not
   add exclusions without a reason there. Prefer fixing code; use `// forge-lint: disable-next-line(<rule>)`
   or `disable-next-item(<rule>)` only for verified false positives, deliberate behaviour, or vendored code, with a
   one-line reason on the line above. The lint reads OpenZeppelin's internal `Math.mulDiv` as an external call.
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
4. Fork tests green if the change touches `IndexZap`, the hub's rebalancing, routes, token behaviour, or anything
   router- or pool-related, `WeightedHub` and its price ids included. Their summary must list the five Ethereum
   `test/fork/` suites and 0 skipped. `WeightedHub.fork.t.sol` alone takes about an hour at 93 coins on an archive RPC
   (Alchemy, Tenderly), nearly all of it the admission quotes on a cold RPC cache; a public endpoint prunes the state
   before it ends. They are also required when the deploy checks or `script/MainnetAddresses.sol` change, which
   `MainnetAddresses.fork.t.sol` and `Security.fork.t.sol` exercise.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the two documented suppressions are on the `redeem` call in `IndexZap._burnBasket` and the `permit` call in
   `IndexZap.burnToTokenWithPermit`. v5 adds the executor callback and Pyth's parse in `WeightedHub`, and the two
   events of the vendored `IPythEvents`, which only Pyth emits.
   Aderyn (Cyfrin's analyzer, `aderyn .`, and its VS Code extension) reports nothing on `src/` either. `aderyn.toml`
   excludes the rules the design rejects, each with its reason, as `foundry.toml` does for lint; a verified false
   positive is marked where it stands with `// aderyn-fp-next-line(<detector>)` and its reason on the line above, or
   `// aderyn-fp(<detector>)` at the end of the line when forge lint's own suppression must stay directly above it. CI
   does not run Aderyn yet: run it before pushing.
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
   - The internal review of v5's weighted index on 2026-10-05: `V5-M1`, `V5-M2`, `V5-L1`..`V5-L3` and `V5-I1`..`V5-I4`
     (`audit/2026-10-05-v5-review.md`), a test named `test_V5M1_...`. The record's status column names every test, and
     the ids fixed or recorded by documentation alone, which have none.
   - The logic review of 2026-10-07: `V5R-1`, `V5R-I1` and `V5R-I2` (`audit/2026-10-07-v5-logic-review.md`), a test
     named `test_V5R1_...` in `test/WeightedHub.rebalance.t.sol`. The informational ids are recorded by documentation;
     V5R-I1 is retired with Stage B.
   - The security audit of 2026-10-13: `CF-1`..`CF-8` (`audit/2026-10-13-security-audit.md`). CF-1's tests are
     `test_CF1_...` in `keeper/test/KeeperExecutor.t.sol`; CF-4's `test_CF4_...` in `test/CheckToken.t.sol`; CF-5's
     `test_CF5_...` in `test/Scripts.t.sol`; CF-6's `test_CF6_...` in `test/Repo.t.sol`; CF-7's the node test named
     `CF-7: ...` in `keeper/test/unit/math.test.mjs`. CF-3 is recorded by documentation alone. CF-2 and CF-8 are
     retired with THORChain.
   - Stage B's families are retired in full with Stage B (`audit/2026-10-07-stage-b-retirement.md`): the Stage B red
     team's `VLT`, `HUB`, `MOD`, `BNB`, `FAC` and `SOL` ids, the TRON review's `TRN`, the logic review of 2026-10-02's
     `LG`, and `BLS-1`. No test carries them, and none may be restored.
   - The swap-venue review of 2026-10-06's `SV` ids (`audit/2026-10-06-swap-venues-review.md`) are retired in full:
     SV-I3 and SV-I4 with THORChain (`audit/2026-10-14-thorchain-retirement.md`), SV-1, SV-I1 and SV-I2 with
     PancakeSwap (`audit/2026-10-14-pancakeswap-retirement.md`). No test carries them, and none may be restored.

   Find a test by its id. Most v1 and R tests are in `test/Security.t.sol` and `test/fork/Security.fork.t.sol`, on
   `WeightedHub` indexes. The hub and factory ids `audit/2026-10-06-v4-retirement.md` re-targets are in the weighted
   suites (`test/WeightedHub.t.sol`, `test/WeightedHub.rebalance.t.sol`, `test/WeightedIndexFactory.t.sol`), the R
   tests that drive the auction directly (R04, R08, R10, R11, R14 to R16, R21) among them. Some ids no contract test
   can reach:
   - L06 and FR06 are `test_L06_checkOwner` and `test_FR06_checkGuardian`, in `test/Scripts.t.sol`, with the other
     deploy-script ids (XA-07, XA-25, XA-38, XA-39, XA-47, SA-06, CR-I36, CR-I37) and RT-25; FR05 is `test_FR05_*` in
     `test/ConfigureWeighted.t.sol`.
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

   Six records list the ids whose mechanism is gone, with the test that went and the property, if any, that survives:
   - `audit/2026-09-22-v3-retirement.md`: the move from Uniswap V3 prices to Chainlink.
   - `audit/2026-09-30-v4-stage-a-retirement.md`: Stage A's removal of every price. It retires 31 tested ids in full,
     retires CR-I36, CR-L08 and VR-06 in part, and names the test of every re-targeted id.
   - `audit/2026-10-06-v4-retirement.md`: the deletion of v4's market-cap hub and factory for v5. It retires 13 tested
     ids in full (the band's and the supply batches'), retires LR-04, LR-05 and RT-15 in part, and names the v5 test
     of every re-targeted id. A second section retires six more with `ConfigureWhitelist`, CR-M01 among them.
   - `audit/2026-10-07-stage-b-retirement.md`: the deletion of Stage B. It retires 31 ids with a Solidity test in
     full, the Rust and Move tests of the vault chains with them, V5R-I1, and RT-24 in part.
   - `audit/2026-10-14-thorchain-retirement.md`: the removal of the THORChain planner. It retires CF-2 and CF-8, whose
     node tests went with it, and SV-I3 and SV-I4, recorded by documentation.
   - `audit/2026-10-14-pancakeswap-retirement.md`: the removal of the zap's PancakeSwap legs. It retires SV-1, whose
     unit and fork tests went with them, and SV-I1 and SV-I2, recorded by documentation.

   The ids tested at `v3.0.0`, less those tested at Stage A, are exactly the ids the Stage A record retires in full;
   the ids tested at `8e6148b`, less those tested at `4f40b67`, the v4 record's first section; those at `22d532a`,
   less those tested after it, its second; and those at `04e936b`, less those tested after it, the Stage B record's. A
   change that removes an id's last test adds its row to a retirement record in the same commit. Do not restore a
   retired id's test against the new design; if the property matters here, it gets a new id from the review of this
   surface.

CI enforces items 1 to 5, Aderyn aside: fmt, build, `forge lint -D notes`, tests, 100% coverage on every file and
`wake detect all src`. The fork suites run on every push from this repository, because the test step passes the
`MAINNET_RPC_URL` secret unconditionally. On `main` and on pull requests into it the secret is also required, so a
missing one fails the run rather than letting the suites skip. Check a run's test summary rather than assuming. Run
everything locally before pushing. A pull request from a forked repository gets no secrets, so its fork suites skip,
and a maintainer re-runs them before merging.

## Layout

`ls` and each file's header comments show what lives where, and README.md's Layout section gives the tour. Two things
the tree does not say: `script/testnet/` (the Sepolia test market) never deploys to a mainnet; and `keeper/` is the keeper bot with its executor contract, a Foundry project of
its own with its own tests (`keeper/README.md`): it starts and fills auctions, serves coins without a Uniswap route from
the executor's stock, and holds no role in the protocol. Anyone may run one; its key is the keeper's own hot key, never
the owner's or the guardian's.

Deleted on 2026-10-13 as unused, and recoverable from git at `f83dcab`: the v4 hackathon demo (`demo/`), the reviews'
PoC tests (`audit/poc/`, which the audit records still cite), v4's market-cap analysis scripts (`design/analysis/`), the
v4 architecture PDF with its builder (`design/build_pdf.py`), the BNB Chain deployment (`script/BnbChainAddresses.sol`,
its list and fork suite), and the design records of retired designs and research (v4's hybrid architecture, Stage B's
spec and interfaces, Stage C, the chain and L2 research, the hackathon plan, the two-chain decision), which the audit
records also cite.

## Design rules that must not be broken

- **One place reads a price.** Only `WeightedHub`'s settlement reads one, from Pyth, and only for the moving
  components. Issue, redeem, `redeemSkipping` and claims never read a price, so no feed can block an exit or misprice a
  mint (`test_issueAndRedeemNeverCallPyth`). The factory stores price ids and never calls Pyth;
  `test_V5I4_onlyTheWeightedHubReadsAPrice` fails if any other file names Pyth's contract, parse, getters, pushes or
  price struct. No Chainlink feed or pool price anywhere (`test_noContractReadsAPrice`). Valuing an index is the app's
  job, off-chain. The zap swaps, but it reads no price either: it enforces the limits its caller sets.
- **One price per block.** The hub, never the executor, fixes the second the prices belong to: one slot back,
  `PRICE_LAG` (12 seconds) before the block (`priceTime()`), and Pyth's `parsePriceFeedUpdatesUnique` returns each
  feed's first update at or after it, published before the block. The hub checks the ids and publish times Pyth
  returns. Do not let a caller name the time or widen the window; the minute first pinned was known two minutes ahead
  (V5-L1). That the update is the first is Pyth's to keep, since Pyth does not return the previous publish time
  (V5-I1).
- **No two components on one price id.** Pyth fills only the first of two equal ids, so such an index could never
  settle; the factory and the hub's initializer both refuse it (V5-M1). Test any change to the parse against Pyth's own
  fill loop, which `MockPyth` follows.
- **Prices are scaled from recorded decimals.** A price is `price · 10^(36 + expo − decimals)` with the decimals the
  factory read when the listing was proposed; no component is called to price it (RT-01). Refused: a non-positive
  price, an exponent outside [-18, 0], a result above `MAX_PRICE`, a confidence interval wider than `MAX_CONFIDENCE`.
- **Weights and constituents are fixed at creation,** two to a hundred components, and an index copies its price ids
  and decimals then, so no relisting reaches an existing index. The CREATE2 salt commits to every component's token,
  units, weight, price id and decimals (LR-05: never switch back to CREATE).
- **The cap counts units, never value.** A fill sends out at most `MAX_TURNOVER` (20%) of each component's own units,
  every leg moving the same share of the way, so a wrong or malicious price takes at most that, once a week. A value
  cap measured in the reported prices let two wrong feeds take 89% of an index far from its weights (V5-M2); do not
  bring one back as the only cap.
- **A fill must trade.** One whose release, after the turnover cap, is worth less than `MIN_TRADE` (0.1%) of the
  moving value reverts `NothingToRebalance`, and a keep mask must leave two components moving, so a fill that changes
  nothing cannot restart `MIN_REBALANCE_INTERVAL` (V5-L2). The minimum is checked on the capped release: checked before
  the cap, a fill could trade a fifth of it (V5R-1). The guardian's cancel remains the trust assumption DA-12 records.
- **The settlement's rounding.** Targets round up; a shrinking leg's step rounds down; a growing leg's rounds up, by the
  factor `μ · s` rounded up, with `μ` falling from `MU_MAX` to `MU_MIN` and rounding up. At the settling prices the
  executor delivers at least `μ` times what it takes. A fill that sends nothing out settles at `MU_MAX`. The mutants
  worth rerunning: each of those roundings flipped, no unit cap, no `MIN_TRADE` or one measured before the cap, a keep
  mask leaving one, a wider window or the minute, no confidence or publish-time check, a kept feed read, the
  duplicate-id checks removed, and the backing post-check's: the claims dropped from the backing term, only the bought
  legs re-read, and a shrinking leg paid as a difference of floored backings.
- **A collapsing coin can stop the fills.** Fixed weights keep buying it, and units beyond `uint96` stop the fill rather
  than wrap, until the guardian keeps it (V5-L3, a known limitation).
- **An issuer's corporate action is not accounted for.** Units are fixed per share and amounts come only from supply
  and units, so tokens an issuer mints to holders, as a split paid in tokens would be, stay in the index owned by no
  share, and a burn leaves that leg below its backing; a token that stops being one share misprices a leg priced at the
  share's feed (CF-3, a known limitation). Do not add a path that pays out balances to cover it.
- **The notice is 2 hours.** `WeightedHub`'s `REBALANCE_DELAY` is 2 hours: targets come from the settlement's prices,
  so the notice is for executors, not for holders' exits (the spec's section 8). `AUCTION_DURATION` is 24 hours and
  `MIN_REBALANCE_INTERVAL` 7 days (V5R-I2). A cancel, or an auction that expired unfilled, holds strangers off for
  `REBALANCE_DELAY`, so the owner and guardian get the first restart; `canStartRebalance` answers whether strangers
  may, and false for a clone that was never initialized (DA-22; CR-I02 for the second after an expiry).
- **Value-bearing amounts are in-kind.** The hub only ever moves amounts derived from supply and units: issue, redeem,
  claims and rebalance settlements. Never compute an amount from balances (balances only verify), and never add a
  share price to the hub. `_backing(shares, units, rounding)` is the one place that turns shares and units into an
  amount, and the seam a fee model would change. There is no fee (the owner's call on 2026-09-30), so no fee code goes
  in. No share can be sent to the index itself or its factory: `_update` refuses both (CR-I01, RT-21).
- **Invariant:** for every component `i`,
  `token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]`. Rounding always goes the
  holders' way: issue rounds up and redeem rounds down; new units round up (DA-01); a claim is recorded only for an
  amount that stayed in the index; a rebalance moves each leg's change in required backing, rounded down when it
  leaves and up when it comes back, so an executor never collects rounding dust (SA-07). The rebalance post-check is the
  invariant with the new units, plus the whole of `amountsIn` on top of what the index held, so surplus from rounding
  or a donation stays with the holders. The invariant suite enforces this; keep it passing.
- **Holders can always leave.** `redeemSkipping` must keep working when any subset of components is frozen, claims must
  be payable once transfers resume, and neither the notice nor the auction ever freezes issue or redeem. A claim is
  booked to `to`, who receives every other component of that redemption, and `ClaimRecorded` names `to`, so a router
  redeeming on a holder's behalf does not strand the skipped components (DA-17). There is no speed limit and no cap on
  a burn anywhere: a holder burns any amount at any time.
- **No admin power over funds, no rebalancing key.**
  - The factory owner proposes listings (behind `LISTING_DELAY`, 2 days) and guardian changes (behind
    `GUARDIAN_DELAY`, 7 days). Anyone can execute a proposal, but only within `PROPOSAL_WINDOW` (7 days) after its
    delay. The owner also delists and transfers ownership.
  - The guardian can: cancel pending listings; delist; cancel a rebalance; start one with a keep mask; start one before
    strangers may; and cancel a guardian change that would remove the role. It cannot block its own replacement.
  - There is no pause, no upgrade, no sweep, no renounce, no instant guardian change, and no keeper or bot role. Keep
    it that way.
  - `cancelRebalance` has no window and no rate limit. A hostile or compromised guardian can cancel each auction at its
    last second and hold rebalancing off while the index drifts from its weights. That stall is bounded by the owner
    replacing the guardian, which takes `GUARDIAN_DELAY` and which the guardian cannot cancel. It moves no funds, and
    holders redeem throughout. A cancel budget was considered and rejected (DA-12). A keep-mask start that leaves only
    a sliver moving can also restart the interval for everyone, so the stall can outlast the guardian's replacement by
    up to `MIN_REBALANCE_INTERVAL`. While a replacement is pending, the owner cancels the outgoing guardian's keep-mask
    starts, and monitors watch `RebalanceStarted` with a non-zero `keepMask` (RT-07). The owner has only
    `REBALANCE_DELAY`, 2 hours, to cancel one before the guardian's own executor can fill it at `eta`, so that cancel
    needs signers on call.
  - An expired proposal leaves `pendingGuardian`, `pendingGuardianEta` and `listingEta` set. The views that say
    whether a proposal is still executable are `guardianChangePending()` and `listingPending(token)` (DA-16).
  - **Listings.** A listing records a token's Pyth price id and its decimals, read from the token then; a relisting
    takes new terms, which reach only indexes created after it. A live listing excludes a second for the same token
    (`ListingPending`).
- **Only initialized clones issue, redeem or rebalance.** Keep the `onlyInitialized` guard on every function that mints,
  burns or touches a rebalance.
- **Executors are untrusted.** Tokens and the callback go only to `msg.sender`, every mutating entry point shares the
  reentrancy guard, and state is written before any rebalance transfer. `executeRebalance(bytes)` settles whatever the
  supply in the settling block requires. The `executeRebalance(bytes, uint256[] maxAmountsIn)` overload bounds that, and
  reverts `RebalanceMovedOn` when the settlement has grown past what the caller will deliver. Issue stays open through
  notice and auction, so a dust issue can grief an executor sized from an off-chain simulation: the callback arguments
  are authoritative (DA-13). At `MAX_COMPONENTS` (100), every path of the hub and the factory fits a transaction under
  EIP-7825's 2^24 gas cap on mock tokens (`test_aHundredComponentsFitOneTransaction`): `createIndex` about 13.1M,
  `redeemSkipping` with every component skipped 5.1M, the settlement's own work 4.8M with Pyth's parse mocked. With
  real tokens and Pyth's real contract, a fill of 93 legs cost 7.26M on an anvil fork of 2026-10-12, the parse 2.34M
  of it for a 30.9 KB update signed by keys the test installed; the fork suite's 14.9M for 92 legs counts its
  executor's `deal` calls. A real Hermes update is still to be measured. Swaps for 100 legs do not fit, so an atomic
  fill that wide needs an executor that already holds the tokens.
- **Keep mask.** Only the owner or guardian can pass one, and it routes around a component that cannot be moved. A kept
  component is neither priced nor read, and its units stay exactly as they were. `executeRebalance` reads `balanceOf`
  only on a component that sends or receives something, so a component whose `transfer` or `balanceOf` reverts, or
  whose contract no longer answers at all, is skipped (DA-14, RT-01).
- **Leaving.** Once the auction is live, an executor watching the mempool can order its fill ahead of a public redeem
  or guardian cancel. An exit sent then pays that holder's share of the executor's take, like every other holder's, and
  no nonce can undo a haircut that landed first. Shares issued while a rebalance is pending share the haircut of any
  fill that lands after them, however the two are ordered (RT-02).
- **Every payable path forwards the whole of `msg.value` to Pyth;** the hub never holds ether.
- **The zap is stateless and replaceable.** New UX features (ETH in/out, aggregators, mixed-venue legs) go in a new or
  extended zap, never in the hub or factory. The app caps a zap basket at about 35 components, which is where 16.78M gas
  runs out.
  - **Venue.** It swaps through Uniswap's Universal Router, pinned to the 2.0.0 deployment, and nothing else (the
    owner's call on 2026-10-14). Each leg names exactly one venue: a packed `v3Path` or a hookless `PathKey[] v4Path`,
    never both and never neither, else `BadRoute(i)`; the pass-through leg names none.
  - **Commands.** The zap builds every command and every action itself and forwards nothing a caller supplied. The
    router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`, which move a payer's funds, so passing
    calldata through would hand a caller the router's permissions.
  - **Payment.** It pays by pre-funding the router and appending `SWEEP` back to itself in the same `execute`, so
    nothing it sent can be left where anyone could take it. There is no Permit2 approval and no allowance to reset.
  - **Spend bound.** The sweep's minimum is zero, so it never fails a call. What bounds a leg's spend is the amount
    pre-funded. That is also the only bound on a V4 exact-output route that revisits `tokenIn`, since the pinned
    periphery does not hold such a route to its `amountInMaximum` (upstream #564; CR-I06, CR-I14).
  - **Unsold input.** The sweep returns the router's whole balance of the token, a stray one included. So a hop's unsold
    input is measured as what came back, `balance + given - before`, never as what was spent (CR-L02).
  - **V4 routes.** A V4 route must be hookless (`hooks == 0` and empty `hookData`). A hookless key cannot carry the
    dynamic-fee flag, so that one equality covers the flag bits too. `address(0)` is allowed only as an intermediate,
    because native ether must never reach the zap, which has no `receive()`.
  - **Checks.** The zap must: validate every route's endpoints; honour every leg's limit, including the pass-through
    leg (DA-15); check `expectedNonce`; measure what the user pays and receives as balance changes inside the call,
    never using tokens already in the zap; check each mint leg's delivered component balance against what the index
    needs (`ShortFill`), which is load-bearing, since the pinned periphery does not itself check exact-output delivery.
  - **Burn legs.** It sells a V3 burn leg one hop at a time and sends every hop's unsold input to the recipient. A V4
    burn leg is a single multi-hop action, because inside one V4 action an intermediate partial fill leaves an unsettled
    credit and the leg reverts atomically. A route that comes back to the component can leave unsold input from a later
    hop too, returned the same way (CR-I07). Unsold `tokenOut` stays in the zap and is paid out.
  - **Never.** It must revert on transfer shortfalls, and never call `redeemSkipping` or `executeRebalance`. With
    `redeemSkipping` the zap receives the basket, so the claim would be booked to the zap and could never be collected.
  - **Errors.** Swap failures reach the caller unchanged. The router wraps a command in `ExecutionFailed` only when it
    dispatched it with a low-level call; swaps are internal calls, so what surfaces is the pool's own revert
    (`V3TooMuchRequested`, `V4TooLittleReceived` and their neighbours), which is why `IUniversalRouter` does not declare
    `ExecutionFailed`.
- **MintRequests holds only open escrows.** A requester escrows USDC or USDT for at least `minShares` of a factory
  index, or shares for at least `minOut` of a stablecoin. Anyone fills before the deadline, and the requester's limit is
  the only valuation: nothing reads a price.
  - No owner, no upgrade, nothing to configure. Every entry point shares one reentrancy guard. The contract never calls
    `approve`, and a filler pays the requester directly.
  - Every amount is measured where it lands. An escrow is the balance increase its request caused, so a USDT fee
    switched on at any time can never leave the last refund short. A fill must put at least the limit into the
    requester's balance, fee included. Each request is closed before any token moves. Nothing assumes a currency's
    decimals.
  - The requester may `cancel` at any time. After the deadline, which is at most `MAX_REQUEST_DURATION` (30 days) away,
    anyone may `refund` the escrow to the requester. A fill pays exactly what the filler sends, so any surplus over the
    limit goes to the fastest filler, which is why the app suggests limits. Stray tokens sent to the contract stay
    there, since nothing may take them.
  - The invariant suite holds the contract's balance of each token at exactly its open escrows plus donations, under
    any interleaving with Tether's fee switch.
- **Checks-effects-interactions.** Emit events and write state before external calls where the data is available; make
  the call into a user-supplied address the last interaction when possible.
- **Standard ERC-20s only as components** (whitelist policy). `issue` rejects fee-on-transfer tokens by checking the
  received amount. Do not whitelist USDC/USDT as components in scripts or docs; they are fine as mint/burn currencies.
  The policy wants 6 to 18 decimals, which matter only to display and to Pyth's scaling. The admission check is
  `CheckToken`, and the WBT rule (a token that can both blacklist a holder and destroy its balance is refused) stays its
  default. On 2026-10-10 the owner ruled that a blacklist is no bar to listing and admitted Tether Gold, which the rule
  refuses, and Ondo's stock tokens, whose compliance contract and burner role amount to the same power;
  `testFork_everyWideTokenPassesTheCheck` pins Tether Gold as the one refused entry and SAND, whose admin's super
  operators move any holder's balance, as the one for review (CF-4). Pausable components such as WBTC
  must be labelled in the app, and so must every other issuer a component adds: BitGo for WBTC, Binance for BTCB and
  every Binance-Peg coin, Tether for Tether Gold, Ondo for every `<ticker>on` stock, Wormhole for every wrapped copy,
  and both Binance and Wormhole for a copy wrapped from a Binance-Peg coin.

## Conventions

- `pragma solidity 0.8.28;` in `src/` and `script/`; tests use `^0.8.24`. The compiler is pinned to 0.8.28 in
  `foundry.toml`, and CI pins Foundry v1.8.1 and eth-wake 4.22.1 in `.github/workflows/test.yml`.
- **Wake config.** CI generates its Wake config from `foundry.toml` and adds `keeper/` to its excluded folders, since
  it would stop Wake before a detector runs: the keeper's executor is a separate Foundry project whose `xindex/`
  remapping only it knows. The Wake VS Code extension reads `.vscode/settings.json` instead,
  which holds four things:
  - `wake.configuration.use_toml_if_present` set to false. The extension otherwise prefers a `wake.toml` in the
    workspace root, and a local `wake detect` or `wake init config` leaves one there, gitignored. A stale one
    replaces the whole committed config;
  - its copy of `forge remappings` (paste the new output there whenever a dependency or remapping changes);
  - the optimizer settings of `foundry.toml` (without them the factory's initcode looks too large to deploy);
  - Wake's default excluded folders plus `keeper/`.
- **Gas in tests.** Foundry 1.8 runs every call a test makes as its own transaction (`isolate = true`), so a measured
  call already carries the 21,000 and its calldata, EIP-7623's floor included. Build the calldata before measuring,
  and send it without Solidity's `call`, which first copies it to the top of the test's memory and pays for that
  expansion.
- OpenZeppelin v5.7.0 and forge-std v1.16.2, pinned in `foundry.lock`; the staged submodule commits must match
  it, and CI checks that. The hub uses the upgradeable ERC20 because clones skip constructors, and the
  storage-based `ReentrancyGuard` because its zeroed slot is "not entered" in a clone.
- **Vendored code** keeps its license header and names its source commit:
  - `IUniversalRouter` and `UniversalRouterCommands` come from Uniswap's universal-router (GPL-3.0-or-later) at
    `3663f6db6e2fe121753cd2d899699c2dc75dca86`, which is tag 2.0.0 and the deployment the zap is pinned to.
  - `UniswapV4Types` comes from v4-periphery (MIT) at `444c526b77d804590f0d7bc5a481af5a3277c952`, the commit that
    router was built against.
  - `IPyth`, `IPythEvents` and `PythStructs` come from pyth-network/pyth-crosschain (Apache-2.0) at
    `2bb0eb54b2b3af8854d0c26f3884c28a0fce0802`, `target_chains/ethereum/sdk/solidity/`, with the pragma pinned and the
    whitespace `forge fmt` writes; their plain imports and Pyth's own events carry the suppressions of vendored code.

  A vendored struct may retype `Currency` and `IHooks` to `address`, which is ABI-identical. Change vendored code only
  to replace a dependency, never to restyle. Both router libraries record the input layout of every command and action
  they name, from `Dispatcher.sol` and `Actions.sol` at those commits, because that layout is what the zap encodes
  against.
- Custom errors, not revert strings. An error that more than one contract raises is declared once, in
  `src/interfaces/IXindexErrors.sol`, which the factory, hub and zap interfaces extend. Tests name it
  `IXindexErrors.<Error>.selector`, because Solidity does not resolve an inherited error through
  `IWeightedIndexFactory.<Error>`; for the same reason a test names `issue`, `redeem`, the previews, `componentTokens`,
  `rebalanceNonce` and `isIndex` through `IIndexHub` and `IIndexFactory`, which the weighted interfaces extend.
  Immutables in SCREAMING_SNAKE_CASE. Loop counters initialised explicitly (`uint256 i = 0`). Modifier logic lives in a
  private function.
- Foundry runs any test-contract function whose name starts with `table` as a table test: name none so, nor any
  function a test suite inherits.
- `foundry.toml` keeps `dynamic_test_linking = false`. With forge's default, a test function ends at the first
  `vm.expectRevert` followed by `new` of a `src/` contract, reported as a pass, and every check after it is skipped
  (LR-01). It also keeps `[invariant] fail_on_revert = true`: the handler only makes calls that must succeed, so a
  handler action that can legitimately revert has to check its precondition first (`canStartRebalance()`, a non-zero
  balance).
- **A regression test has to fail without its fix.** Check it against the old code or a mutant before relying on it.
  The logic review found tests that passed either way: mocked return values instead of the real flow, prices that never
  moved between two snapshots, a salt whose fields were never varied one at a time. The mutants worth rerunning on
  `WeightedHub` are listed under the settlement's rounding above.
- **Tests.**
  - One `*.t.sol` per contract; the hub's rebalancing and invariants have their own files, and so do the invariants of
    `MintRequests`.
  - Mocks go under `test/mocks/`. Mainnet constants live in `script/MainnetAddresses.sol`, re-exported with test-only
    ones by `test/fork/ForkAddresses.sol`.
  - New behaviour needs a unit test, and a new revert path needs a test hitting the exact error
    (`vm.expectRevert(abi.encodeWithSelector(...))`).
  - Listing in tests goes through `WeightedTest._list(token, priceId)` or, in the zap, `MintRequests` and security
    suites, `XindexTest._listWith(token)`, which lists a token under a price id of its own: `proposeListing`, a
    `vm.warp` past `LISTING_DELAY`, then `executeListing`. `XindexTest._createIndex` builds an index from explicit
    units with the weights shared equally.
  - Compute every argument before `vm.prank`: an external call in the arguments consumes the prank.
  - Measure gas with every touched account cooled first (`vm.cool`), so a call pays the cold reads a transaction of its
    own would.
- **Scripts.** They keep their logic in public functions that take explicit arguments, so tests can call them without
  environment variables: `DeployWeighted.deploy`, which deploys the factory (and through it the `WeightedHub`
  implementation), the zap and `MintRequests`; `ConfigureWeighted.propose`, `execute`, `safeCalldata` and `status`;
  and `CheckToken.check`, which reports on one token. Environment variables are process-global and tests run in
  parallel, so each variable name is set by exactly one test (see `test/Scripts.t.sol`). In tests, script broadcasts
  come from `DEFAULT_SENDER`.
- **Deployment rules.**
  - Deployments never use raw private keys: `--account` keystores or `--ledger`.
  - `OWNER` and `GUARDIAN` are required, on each chain.
  - On a mainnet the owner must be a contract that is not an EIP-7702 delegated account. A Safe owner must need at least
    `MIN_OWNER_THRESHOLD` (3) signatures, the design's 3-of-5 (the owner's call on 2026-09-30), and have no enabled
    module.
  - When the owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers (SA-06).
  - Neither role may be a market contract: the router and the PoolManager, Pyth, and on a mainnet every token and mint
    currency in the address book (CR-I37).
  - On chain 1 the market addresses are the address book's and nothing else (`MainnetOverride`); elsewhere they come
    from the environment.
  - On chain 1 `deploy` broadcasts only the build `DeployWeighted`'s `FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH` and
    `REQUESTS_INITCODE_HASH` record (`BuildNotReleased`, CF-5). A change to `src/`, a dependency or the compiler
    settings fails `test_CF5_theReleaseHashesAreThisBuilds` until those three are set to the values it prints, in the
    same commit.
- **Mainnet addresses** are verified on-chain before being committed: tokens by symbol and decimals, and the router
  and the PoolManager by their runtime code hashes, since every Universal Router build answers `poolManager()` alike
  (CR-I35). `test/fork/MainnetAddresses.fork.t.sol` checks `script/MainnetAddresses.sol` that way and lists both lists
  on a fresh factory over Pyth, and `test_CRL08_theListsAreTheReleaseRecord` pins every list, address and price id,
  against a table written independently of them. Every price id carries its feed's description beside it. The WBTC
  address is `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one. A Wormhole copy of a
  Binance-Peg coin is priced at its coin's feed, and the app labels it Custodial.

## Product decisions already made (do not re-litigate silently)

**One index on Ethereum, the missing coins as Wormhole-wrapped legs** (the owner's decision of 2026-10-10,
`design/2026-10-10-one-index-wormhole-legs.md`): one deployment, on Ethereum; an index holds up to 100 coins of the top
300 in kind; a coin Ethereum lacks is listed as the copy Wormhole's token bridge wraps from its home chain, attested by
anyone, priced at the coin's Pyth feed, labelled Bridged (and Custodial from a Binance-Peg source). Wormhole is the one
bridge accepted for wrapping, because its token bridge is permissionless and its SOL copy was already listed. The
record's third reason, that its guardians sign Pyth's updates, no longer holds on chain: since 2026-08-26 Pyth on
Ethereum verifies with its own five keys, so wrapped legs add Wormhole as a party of its own. The BNB Chain deployment
it shelved was deleted on 2026-10-13 (the owner's call). Own vaults, own proofs and any other bridge stay refused. The
listing rules below (memecoins, exchange tokens, NIGHT, the WBT rule) are unchanged.

**No vaults** (the owner's decision of 2026-10-07): Stage B's vaults, proofs and verifiers are retired. Other chains'
coins come in only as tokens that exist on Ethereum and pass `CheckToken`; Binance-Peg sources are listable, labelled
Custodial. The same decision added a BNB Chain deployment, which the one-index decision shelved and the owner deleted on
2026-10-13. Not planned: a Solana deployment (a Rust rewrite for about 3% of coverage), L2 deployments (about 0.2% of
coverage; at most one later, for cheap minting). Tokenized stocks, once on this list, were admitted on 2026-10-10
(below).

**v5 replaces v4's market-cap index** (the owner's calls on 2026-10-05). Creators choose each coin's percentage; the
weights are fixed at creation; the index rebalances to them at Pyth prices. Pyth is the only oracle: Chainlink alone,
and Chainlink as a second check on the coins it covers, were both refused. v5 is custom percentages only. Its
parameters (section 8 of the spec) wait on a replay of Pyth's history, and Hermes needs a paid API key, an operating
cost the owner weighs before launch.

**The listings** (the owner's calls on 2026-10-06):
- No team index at launch: creators make every index, so "flagship" names no product.
- The admission rule stays the WBT rule; Binance-Peg coins stay listable, labelled Custodial.
- The v5 Ethereum list is 27 coins: no OKB, BGB, GT or GRAM. NIGHT is refused. INJ, SHIB and PEPE joined on
  2026-10-10, from CoinGecko's top 100; SHIB and PEPE on the owner's call lifting the memecoin exclusion for those
  two. The same day SOL moved to Ethereum as Wormhole's copy and left BNB Chain's list (the owner's rule: a
  Binance-Peg coin with a listable Ethereum copy is held on Ethereum), making 31 on Ethereum and 16 on BNB Chain,
  whose list went with its deployment on 2026-10-13.
- **Real-world assets** (the owner's call on 2026-10-10): Tether Gold and Ondo's tokens for the 17 of
  CoinMarketCap's top-20 real-world assets that Ondo issues (Berkshire has none; silver has no listable token), making
  49 on Ethereum, labelled Custodial. The owner accepted three costs: the issuers can block and burn holders; most have
  no Uniswap liquidity, so they mint in kind or through `MintRequests` and a rebalance needs an executor that holds or
  mints them, against the 2026-10-06 rule that refused BGB and GT for want of a route; and six (TSM, AVGO, LLY, JPM,
  WMT, V) have only US-hours Pyth feeds, so an index holding one can settle a rebalance only while that market is
  open, or with the stock kept. The legal question of offering stocks is the owner's.
- TRX was held as the BEP-20 TRX of TRON's closed BTTC bridge, on BNB Chain; with that deployment deleted it is not
  listed, and its Ethereum copy is not either.
- Bitcoin is held as WBTC (the owner's call on 2026-09-29; do not reopen it).

**Swap venues** (the owner's call on 2026-10-14): the zap swaps through Uniswap's Universal Router 2.0.0 alone, V3 or
V4 per leg, chosen by the caller. PancakeSwap's v3 Universal Router, a third venue per leg since 2026-10-06 (chiefly
for CAKE), and THORChain, an app-side rail added the same day (`design/2026-10-06-swap-venues.md`), were both removed on
2026-10-14: users come with USDC or USDT. CAKE stays listed; its legs route through Uniswap's pools, or it mints in
kind or through `MintRequests`.

**Unchanged from earlier versions:** no fee (the owner's call on 2026-09-30; audits, the bounty and watchers are
funded from outside; a later version could add one through `_backing`); an owner Safe of at least three signatures;
fixed constituents; no protocol bots or hot keys; component whitelist only; the burner chooses the exit token; the
mint currency is not tracked per holder; up to `MAX_COMPONENTS` (100) per index.

If a change would alter any of these, say so explicitly.

## Not built (candidate backlog)

- A fee, in a later index version.
- `mintWithETH` / `burnToETH`, `createAndMint`, `mintWithTokenPermit` for USDC.
- Creator fees (attribute them by `creatorOf`, never by name).
- Constituent changes (a new list is a new index).
- Mixed-venue legs (a single leg splitting across V3 and V4).
- Per-pair partial-fill auctions.
- A backstop for auctions too small to pay: the keeper in `keeper/` fills only what pays, unless its operator sets a
  subsidy (`MIN_PROFIT_USD` below zero).
- An aggregator or Universal Router 2.1 zap.
- V4 pools on Sepolia, so the V4 legs get a testnet rehearsal rather than only fork and mock coverage.
- One L2 deployment, if cheap minting for small buyers matters after the two launches.
