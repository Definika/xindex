# AGENTS.md

Guidance for coding agents and humans working in this repository. Codex reads this file; Claude Code reads it through
`CLAUDE.md`, which imports it, so this is the only copy to edit.

## What this is

Xindex smart contracts, v4: a Foundry project where users create crypto index tokens (ERC-20) backed in kind,
mint them with USDC/USDT, and burn them into any token through Uniswap's Universal Router, which reaches both V3 and V4
pools. An index's constituents are fixed at creation. Its units follow its components' reference supplies, circulating
supplies the factory owner maintains behind a timelock, so an index holds each component in proportion to its supply:
market-cap weighting without a price. Supplies change in weekly batches of at most half a percent each. After a change,
anyone can trigger a rebalance, which settles through a price-free λ auction. No contract reads a price. v4 is one hybrid
product: an index token on Ethereum that holds wrapped bitcoin, ether and other Ethereum tokens itself, and other
chains' native coins in ownerless vaults on their own chains (`design/2026-09-29-v4-hybrid-architecture.md`). The
stages are build order only: Stage A is the part held on Ethereum, Stage B the vaults and their proofs, Stage C more
chains. It launches as one product, on the hybrid factory, once the hybrid index is ready (the owner's call on
2026-10-01); Stage A does not launch on its own. v4 replaces v3, which priced through Chainlink and offered a capped
methodology; v3 is tagged `v3.0.0` and never ships on mainnet. The web app lives in a separate repo.

**v5 is replacing v4's market-cap index** (the owner's calls on 2026-10-05): creators choose each coin's percentage,
fixed at creation, and the index rebalances back to them at Pyth prices. v5 offers custom percentages only; the
market-cap hub and its supply batches are retired, as v3 was: `src/IndexHub.sol`, `src/IndexFactory.sol` and their
ABIs were deleted on 2026-10-06, and `audit/2026-10-06-v4-retirement.md` records what went with them. v5 phase 1 is
built and deployed nowhere: `WeightedIndexFactory` and its `WeightedHub` template, on branch
`v5-custom-weights`, holding Ethereum ERC-20s; vault coins are phase 2, and the vaults and proofs below carry over.
`design/2026-10-05-custom-weights.md` is its spec and records what remains before any deployment.
**Draft state (2026-10-06):** the vault-coin index (`HybridHub`, its module and extension, `HybridIndexFactory`,
`WeightedPricing`), `Deploy.s.sol`, `ConfigureChains` and the bot in `keeper/` were moved to v5 code-first, at the
owner's request; their tests come in the safety pass. Until then `foundry.toml`'s `skip` list sets aside the v4 suites
they broke, and nothing may ship while it is not empty; they still import the deleted v4 contracts. The rules below
that name `IndexHub` or `IndexFactory` describe v4's design, which `WeightedHub` and `WeightedIndexFactory` keep where
the v5 section says so ("Everything else is `IndexHub`'s"); the v5 section governs the weighted contracts.

Where the stages stand (none of v4 is deployed):
- Stage A is built.
- Stage B is built in large part: the EVM vault and the Solana vault program; P1 (SP1) and P2 (RISC Zero) on EVM vault
  chains and on Solana; BNB Chain's and TRON's state verifiers on Ethereum; and `HybridIndexFactory` with
  `HybridHub`, its module and its extension. So BNB Chain and TRON are built in both directions, and NEAR and Stellar
  too (2026-10-04): their vaults (`near/`, `stellar/`) with P1 and P2 on the shared Rust core `crates/xindex-core`,
  and their state verifiers on Ethereum (`NearStateVerifier`, `StellarStateVerifier`, proven by `proofs/near` and
  `proofs/stellar`), to the interfaces of `design/2026-10-03-near-stellar-interfaces.md`. Solana is built from
  Ethereum to its vault, the vault's checkpoints, stall recovery and snapshot exit included (2026-10-03); its state
  verifier on Ethereum is not built, and can ship only once Alpenglow reaches mainnet. Its build waits for that (the
  owner's call on 2026-10-04; `design/2026-10-03-solana-state-proof.md` has the researched plan, a native prototype in
  `proofs/solana-state`, and a real devnet certificate verified on Ethereum).
  HyperEVM waits on Hyperliquid, since every header's state root is zero. The Stage B spec's section 8 has each
  chain's status, and its section 6 the build order.
- Of Stage C, NEAR and Stellar are built (above). Avalanche, Hedera and Cardano were researched on 2026-10-01
  (`design/2026-10-01-stage-c-research.md`, summarized in the Stage B spec's section 8); none is pursued (below).
- Ethereum's L2s were researched on 2026-10-04 (`design/2026-10-04-l2-research.md`): their own tokens are about 0.6% of
  the holdable universe, none investable for the flagship, and no optimistic rollup is final on Ethereum within the
  hub's 6-hour `GRACE`. The record recommends building nothing for them.
- Eleven more chains with a top-100 coin were researched on 2026-10-04 (`design/2026-10-04-chain-research.md`;
  memecoin chains are out, the owner's call). None reaches the 0.2% floor. Sui, Injective, Aptos and VeChain pass the
  rule; Cronos, ICP and TON pass it but needed the owner's calls; Algorand needed a ruling on the rule; Bittensor and
  Filecoin wait on their chains; Ethereum Classic fails.
- **The vault chains are frozen at the eight built** (the owner's calls on 2026-10-06): BNB Chain, TRON, NEAR, Stellar,
  Sui, Injective, VeChain and Aptos, with Solana and HyperEVM when their chains allow. Another chain's coin comes in
  only as a token that already exists on Ethereum or BNB Chain and passes `CheckToken`: AVAX and ADA as Binance-Peg
  tokens, CRO and ICP on Ethereum. TON and ALGO stay out (no sound token: the TON bridge closed on 2026-09-01), HBAR
  too (only unknown issuers' wrappers). Avalanche's and Algorand's finality, the permissioned sets (Hedera, ICP's
  canisters, Cronos), TON's BLS12-381 wrapper and a restated rule for Cardano are not pursued.
- The four that pass are being added (the owner's call on 2026-10-04), to `design/2026-10-04-four-chains-interfaces.md`:
  - **Sui** is built in both directions: the vault with P1 and P2 in Move (`sui/`), and `SuiStateVerifier`, which
    checks Sui's committee certificates in Solidity, with no zkVM.
  - **Injective** and **VeChain** run `XindexVault` unchanged. Their state verifiers on Ethereum are built:
    `CometBftStateVerifier` (`proofs/cometbft`) and `VeChainStateVerifier` (`proofs/vechain`), the latter with
    `VeChainStakerAttester` on VeChain and its own deployment script (`vechain/`).
  - **Aptos** is built in both directions: the vault with P1 and P2 in Move (`aptos/`), and `AptosStateVerifier`
    (`proofs/aptos`), whose inputs come from Aptos Labs' public database backups.
- Every top-100 coin with a contract on Ethereum or BNB Chain is being added (the owner's call on 2026-10-05,
  `design/2026-10-05-wide-asset-support.md`). Built: `script/CheckToken.s.sol`, the admission check; the wide list of
  the Ethereum coins that pass it, now `V5_WHITELIST=wide` in `script/PythIds.sol` (LEO and WLFI fail the WBT rule;
  `design/2026-10-05-token-admission-report.md`); token support in `XindexVault`; and 14 BNB Chain tokens
  (Binance-Peg coins, BNB Chain tokens and TRON's bridged TRX) pinned in `script/BnbChainAddresses.sol` as
  `ConfigureChains`' `VAULT_TOKENS=bnb`, listed once that vault is deployed, each with a cap the owner sets then. The design's last
  decisions were taken on 2026-10-06 (its section 6): no team index at launch, so "flagship" names no product; the WBT
  rule unchanged; Binance-Peg coins kept, labelled Custodial; NIGHT refused; and a v5 list of 27 Ethereum coins, without
  OKB (being retired on Ethereum), BGB and GT (no Uniswap route, so no fill can rebalance them) or GRAM.

For more:
- `ARCHITECTURE.md`: the design as built, Stage A and Stage B.
- `design/2026-09-30-v4-stage-a-spec.md`: the Stage A spec.
- `design/2026-09-30-v4-stage-b-spec.md`: the Stage B spec.
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
for c in IndexZap MintRequests HybridIndexFactory IHybridIndex XindexVault WeightedIndexFactory WeightedHub; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change
node --test swaprail/        # the THORChain swap rail's planner (app-side JavaScript, no dependency); CI runs it

# mainnet fork tests (real tokens, Universal Router, V3 and V4 pools); skipped when the env var is unset.
# A rate-limited RPC throttles five suites in parallel: add -j 1.
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# public non-archive RPCs only serve recent state: pin near the head
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/*'

# the admission check, read-only, before any listing: one report per token for the Safe's signers
CHECK=wide forge script script/CheckToken.s.sol --fork-url $MAINNET_RPC_URL
```

Deployment: `script/Deploy.s.sol` then `script/ConfigureWeighted.s.sol`, which lists each coin with its Pyth price id
(`script/PythIds.sol`). `script/CheckToken.s.sol` reports on every token before its first listing; `V5_WHITELIST=default`
is the first four coins and `V5_WHITELIST=wide` the rest, 27 in all. A vault chain adds `script/DeployVault.s.sol` on that chain (P1, P2, the
state reader and the vault, Injective's included; `tron/deploy.mjs` deploys TRON's, built with Tron's compiler, and
`vechain/deploy.mjs` VeChain's with its staker attester; NEAR's, Stellar's and Sui's go up with their chains' own
tools, as `near/`, `stellar/` and `sui/` say) and `script/DeployStateVerifier.s.sol` on Ethereum (the chain's state
verifier, from an anchor the fixture generator writes, with the deployment's own ids added where it has some), then
`script/ConfigureChains.s.sol`
(`proposeChain`, then `proposeVaultListing` for each coin). Sepolia first needs its test market from
`script/testnet/SetupTestMarket.s.sol`.

## Definition of done for any change

1. `forge fmt --check` clean.
2. `forge build` clean, including `forge lint` (zero warnings and notes). Lint config lives in
   `foundry.toml` `[lint]`; each excluded rule has its reason in the comment block above the list. Do not
   add exclusions without a reason there. Prefer fixing code; use `// forge-lint: disable-next-line(<rule>)`
   or `disable-next-item(<rule>)` only for verified false positives, deliberate behaviour, or vendored code, with a
   one-line reason on the line above. The lint reads OpenZeppelin's internal `Math.mulDiv` as an external call, which
   was the reason for the suppression in v4's `IndexFactory.createIndex`.
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
4. Fork tests green if the change touches `IndexZap`, the hub's rebalancing, routes, token behaviour, or anything
   router- or pool-related, `WeightedHub` and its price ids included. Their summary must list the five `test/fork/`
   suites and 0 skipped. `WeightedHub.fork.t.sol` alone takes about fifteen minutes on a public RPC.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the two documented suppressions are on the `redeem` call in `IndexZap._burnBasket` and the `permit` call in
   `IndexZap.burnToTokenWithPermit`. One more marks `IHybridIndex`,
   which only integrators and tests use, as meant to have no user in `src/`. v5 adds the executor callback and Pyth's
   parse in `WeightedHub`, and the two events of the vendored `IPythEvents`, which only Pyth emits.
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
   - The internal red team of Stage B on 2026-09-30 (`audit/2026-09-30-stage-b-red-team.md`), each id carrying its
     report's prefix: `VLT-1`..`VLT-5` and `VLT-I1`..`VLT-I6`, `HUB-1`..`HUB-4` and `HUB-I1`..`HUB-I3`, `MOD-1`..`MOD-5`
     and `MOD-I1`..`MOD-I6`, `BNB-1`, `BNB-2`, `FAC-1`, `FAC-2` and `BNB-I1`..`BNB-I4`, and `SOL-1`..`SOL-10`. A test is
     named `test_VLT1_...` or `test_VLTI3_...`; the Solana program's are Rust tests named `test_sol1_...`, and
     `test_vlt2_...` for an EVM finding fixed on its twin. The record's status column names every test, and the ids
     fixed or recorded by documentation alone, which have none.
   - The internal review of the Tron state verifier on 2026-10-01: `TRN-1`..`TRN-9`
     (`audit/2026-10-01-tron-review.md`), a test named `test_TRN1_...`. TRN-6 to TRN-8 were recorded by documentation
     alone and have no test.
   - The logic review of 2026-10-02: `LG-1`..`LG-6` and `LG-I1`..`LG-I4` (`audit/2026-10-02-logic-review.md`), a test
     named `test_LG1_...`, and in Rust `test_lg1_...`. The record's status column names every test; the informational
     ids have none.
   - The BLS signature-length finding of 2026-10-04: `BLS-1` (`audit/2026-10-04-bls-signature-length.md`), tested by
     `test_BLS1_...` in `test/Bls12381.t.sol` and `test/BnbStateVerifier.t.sol`.
   - The internal review of v5's weighted index on 2026-10-05: `V5-M1`, `V5-M2`, `V5-L1`..`V5-L3` and `V5-I1`..`V5-I4`
     (`audit/2026-10-05-v5-review.md`), a test named `test_V5M1_...`. The record's status column names every test, and
     the ids fixed or recorded by documentation alone, which have none.
   - The swap-venue review of 2026-10-06: `SV-1` and `SV-I1`..`SV-I4` (`audit/2026-10-06-swap-venues-review.md`), a
     test named `test_SV1_...` in `test/IndexZap.pancake.t.sol` and `testFork_SV1_...` in
     `test/fork/IndexZap.fork.t.sol`. The informational ids are recorded by documentation, SV-I3 and SV-I4 with the
     planner's tests in `swaprail/`.

   Find a test by its id. Most v1 and R tests are in `test/Security.t.sol` and `test/fork/Security.fork.t.sol`, on
   `WeightedHub` indexes. The hub and factory ids `audit/2026-10-06-v4-retirement.md` re-targets are in the weighted
   suites (`test/WeightedHub.t.sol`, `test/WeightedHub.rebalance.t.sol`, `test/WeightedIndexFactory.t.sol`), the R
   tests that drive the auction directly (R04, R08, R10, R11, R14 to R16, R21) among them. Some ids no contract test
   can reach:
   - L06 and FR06 are `test_L06_checkOwner` and `test_FR06_checkGuardian`, in `test/Scripts.t.sol`, and FR05 is
     `test_FR05_*` in `test/ConfigureWeighted.t.sol`.
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

   Three records list the ids whose mechanism is gone, with the test that went and the property, if any, that survives:
   - `audit/2026-09-22-v3-retirement.md`: the move from Uniswap V3 prices to Chainlink.
   - `audit/2026-09-30-v4-stage-a-retirement.md`: Stage A's removal of every price. It retires 31 tested ids in full,
     retires CR-I36, CR-L08 and VR-06 in part, and names the test of every re-targeted id.
   - `audit/2026-10-06-v4-retirement.md`: the deletion of v4's market-cap hub and factory for v5. It retires 13 tested
     ids in full (the band's and the supply batches'), retires LR-04, LR-05 and RT-15 in part, and names the v5 test
     of every re-targeted id. A second section retires six more with `ConfigureWhitelist`, CR-M01 among them.

   The ids tested at `v3.0.0`, less those tested at Stage A, are exactly the ids the Stage A record retires in full;
   the ids tested at `8e6148b`, less those tested at `4f40b67`, the v4 record's first section; and those at `22d532a`,
   less those tested after it, its second. A change that
   removes an id's last test adds its row to a retirement record in the same commit. Do not restore a retired id's test
   against the new design; if the property matters here, it gets a new id from the review of this surface.

CI enforces items 1 to 5, Aderyn aside: fmt, build, `forge lint -D notes`, tests, 100% coverage on every file and
`wake detect all src`. The fork suites run on every push from this repository, because the test step passes the
`MAINNET_RPC_URL` secret unconditionally. On `main` and on pull requests into it the secret is also required, so a
missing one fails the run rather than letting the suites skip. Check a run's test summary rather than assuming. Run
everything locally before pushing. A pull request from a forked repository gets no secrets, so its fork suites skip,
and a maintainer re-runs them before merging.

## Layout

`ls` and each file's header comments show what lives where, and README.md's Layout section gives the tour. Two things
the tree does not say: `script/testnet/` (the Sepolia test market) and `demo/` (the hackathon demonstration, its own
Foundry project) never deploy to a mainnet, and `swaprail/` is app-side JavaScript that no contract calls: the reference
THORChain planner the web app adopts (`design/2026-10-06-swap-venues.md`).

## Design rules that must not be broken

- **No price in any v4 contract.** No v4 contract reads a price, a feed or a pool's state to size, gate or value
  anything. Amounts come from supply and units, and units come from reference supplies. `test_noContractReadsAPrice` in
  `test/Repo.t.sol` fails if `src/` or `abi/` names a Chainlink feed or a pool's price. Valuing an index is the app's
  job, off-chain. The zap swaps, but it reads no price either: it enforces the limits its caller sets. v5's
  `WeightedHub` is the one exception, and only in its settlement (the v5 section below;
  `test_V5I4_onlyTheWeightedHubReadsAPrice`).
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
  - **Venue.** It swaps through Uniswap's Universal Router, pinned to the 2.0.0 deployment, and, for the legs that name
    one, PancakeSwap's v3 Universal Router (`PANCAKE_ROUTER`, pinned by its runtime code hash; the owner's call on
    2026-10-06, `design/2026-10-06-swap-venues.md`). Each leg names exactly one venue: a packed `v3Path`, a hookless
    `PathKey[] v4Path` or a packed `pancakePath`, never two and never none, else `BadRoute(i)`; the pass-through leg
    names none. A zap deployed without PancakeSwap (zero, as on a testnet) refuses every `pancakePath`.
  - **PancakeSwap.** Its legs use the same pre-fund, sweep and measurement as Uniswap's V3 legs, with
    `PancakeRouterCommands`, never Uniswap's library: the two command sets part from 0x10 up. Every PancakeSwap call
    ends with `WRAP_ETH(ADDRESS_THIS, CONTRACT_BALANCE)`, because that router sends its whole ether balance to its caller
    after the last command and reverts if that fails, and takes ether from anyone: without the wrap, one wei sent there
    would block every PancakeSwap leg (SV-1). Never give the zap a `receive()` instead. PancakeSwap's Safe can pause the
    router and attach a contract to its pools; that stops PancakeSwap legs and moves nobody's funds (SV-I1).
  - **THORChain** never touches a contract: a deposit made inside one can be ignored and lost (SV-I3). It is the app's,
    from the user's own accounts, through `swaprail/thorchain.mjs`, which refuses contract senders and destinations,
    writes its own memo with a limit and a refund address, cross-checks two THORNode endpoints and pins the router.
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
    on a fork, which is why `IUniversalRouter` does not declare `ExecutionFailed` at all. PancakeSwap's router
    dispatches the same way; a paused one reverts with `Pausable: paused`.
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

## Stage B (in progress, not deployed)

Stage B's rules live in `design/2026-09-30-v4-stage-b-spec.md`; these are the ones code must never break.
- **Stage A stays as it is.** An index of Ethereum tokens only is an `IndexHub` clone, byte-identical to Stage A's;
  `HybridIndexFactory` reaches it only through `IndexFactory`'s two template hooks.
- **Vaults.** A chain's vault is fixed once registered, and an index copies its vaults at creation. A vault pays out
  only on messages both Ethereum-side proofs carry, and only protective messages (a freeze, a lowered cap) pass on one.
- **Tokens on an EVM vault chain.** `XindexVault` also holds a token governance has capped, a Binance-Peg coin or a
  token issued on BNB Chain (`design/2026-10-05-wide-asset-support.md`). A cap of zero refuses it, so no token enters a
  vault faster than a `CAP_UPDATE` waits out both delays. `depositToken` records the amount, then pulls it, and refuses
  a short delivery (`DepositShortfall`). A token's cap, floor, speed limit, refunds and snapshot claims are its own, so
  one that pauses or blacklists the vault holds back only its own payouts. On Ethereum it is a vault coin like any
  other, `vaultTokenId(chainId, bytes32(token))`: the hub, the factory and the state verifiers do not change.
- **The hub's book is exact.** `vaultBacking` changes only by the proven deposits of a claimed order and by burns, both
  from supply and units. Every order spans every chain of its index, and its intake id carries its deadline.
- **Nothing an order rests on can change unseen.** Deposits are proven only after their deadline. During the lock, any
  different proof of the intake voids the order and freezes the chain. A freeze that began at or after settlement holds
  the order until a proof from after the freeze re-confirms it.
- **Failing never blocks a refund.** A failed order's escrow becomes claims instead of transfers, so vault depositors
  always get their `INTAKE_FAILED`.
- **One layout, three contracts.** `HybridHub`, `HybridHubModule` and `HybridHubExtension` run on one clone's storage,
  so none declares a state variable of its own: all of it lives in `HybridHubStorage`, appended at its end, never
  inserted. `test_theHubAndTheModuleShareOneLayout` compares the three from the compiler's layouts (`extra_output` in
  `foundry.toml`). The module is fixed in the template's constructor and the extension in the module's; there is no
  way to change either.
- **Fills.** A rebalance of an index holding vault tokens settles in three steps:
  - accept, with a bond of 0.1% of the supply in shares and the Ethereum deliveries;
  - the vault deliveries, deposited under the fill's intake id;
  - settle, on a proof of them, at the supply of the settling block.

  Mint claims wait while a fill is accepted. The bond is held 24 hours after settlement, and burned if a delivery
  proves forged. It is burned on an executor's abort and returned on a guardian's cancel.
- **Every outflow is speed-limited.** A vault pays a `MIGRATE` into the new index's balance as it pays a burn: owed,
  within the 4% limit, counted in `paidTotal`. The hub counts both in `sentOut`, so a vault record showing more paid
  than sent is evidence that both Ethereum-side proofs broke.
- **Migration is atomic on Ethereum and trusts only clones.** `migrate` and `acceptMigration` accept only another
  HybridHub of this factory (a recorded salt). A vault token the new version holds must be covered by the old
  shares' backing of it; a vault token new to the version comes by order. `acceptMigration` checks the backing in real
  balances, and refuses while a fill is accepted or a chain is frozen.
- **Every share that rests on a vault proof enters within the mint cap,** 4% of the supply a day: an order's and a
  migration's alike, since the old index's book rests on proofs too (MOD-2). The one exception is the seed of an empty
  index with nothing locked, which only its creator may mint, by an order or a migration (HUB-2).
- **Evidence freezes the chain for every index,** so no honest state may ever count as evidence. A void, a slash, or a
  claimed order's deposit proven false freezes mints on the chain at the factory, and leaves the vault paying. A vault
  record paying more than was sent freezes the vault too. Every evidence proof is bounded below by a deadline or a
  freeze, since state verifiers prove old blocks: a slash's by the delivery deadline, and an empty intake is evidence
  only on a chain where the fill recorded a delivery (HUB-1). An exited chain takes no evidence: every evidence proof
  also reads the vault's snapshot root, in the same state proof, and is refused once it is set, recorded or not
  (LG-5).
- **Messages wait for the checkpoint.** A vault runs a message that moves coins or loosens a rule only from an
  Ethereum block its checkpoint covers, so the snapshot never pays a holder whose burn it paid (VLT-3). A snapshot
  claim reads a component only inside the hub's components array (VLT-1).
- **A stall is only ever Ethereum's formats breaking.** Anyone can advance a vault's checkpoint while P1 and P2 work, so
  a stall (7 days without one) cannot be manufactured. Only then may the owner's emergency multisig propose a
  successor, which must prove the last checkpoint, a recent one and the last message, and wait 30 days of review with
  at most 2 vetoes. A stalled vault takes no deposit.
  - Only a checkpoint that ends the stall lapses the successor and restarts the vetoes. A stale one, which the old pair
    can still prove, keeps both, so nobody can throw the review away a block at a time (LG-2).
  - The last message is the last on both proofs: a one-proof freeze could be forged by one broken system (LG-3).
  - P1 and P2 stop for good a day behind: `update` refuses a proof once `MAX_LAG` has passed since the anchor's epoch
    began, dated from the beacon genesis time fixed at deployment, on EVM chains and on Solana (LG-4).
- **The snapshot exit is final and speed-limited.** 180 days into a stall, the last checkpoint becomes the snapshot:
  no message from a later block runs, the freezer can no longer freeze, holders at it claim their share by signature
  or recovery address within the speed limit, and open intakes are settled or refunded from the hub's
  `_settledIntakes`. The hub marks that in the transaction that sends each settle message; keep it that way. It also
  marks every message it sends in `_sentMessages`, in the same transaction, and the vault's `deliverRecorded` pays a
  burn or migration still in flight at the snapshot from that mark. A hub that records the exit never mints on that
  chain again. `test_theHubLayoutIsPinned` pins the slots each side reads.
- **Any message can be sent again.** Whoever sends a transaction shapes its receipt, and every verifier has a ceiling.
  So the hub and the factory mark every message they send, and anyone may emit a marked one again, unchanged, with
  `resendMessage(payload)`; the vault runs a message once by its id (LG-1). Keep every `VaultMessage` going through
  that mark: the hub's `_post`, the factory's `_sendVault`.
- **Vault governance is delayed and public, twice.** The factory sends `CAP_UPDATE` only after `LISTING_DELAY`,
  `FREEZER_CHANGE` only after `GUARDIAN_DELAY` (the guardian cannot cancel it, as it cannot block its own replacement),
  and `VERIFIER_ROTATION` only after `ROTATION_DELAY` (30 days). P1 and P2 must always be two different verifiers.
  - On the vault, anything that loosens a rule then waits `GOVERNANCE_DELAY` (7 days), so P1 and P2 both broken cannot
    loosen one at once (VLT-2):
    - a raised cap or floor;
    - a new freezer;
    - new verifiers.
  - The freezer may cancel a waiting raise or rotation, never its own replacement, and a freeze holds every waiting
    change but that one.
  - Only a message on both proofs moves a kind's nonce mark (VLT-4).
  - A registered chain's new state verifier also waits `ROTATION_DELAY`, since it decides every index's mints there
    (FAC-1).
  - The BNB verifier trusts only a set from the last `MAX_LAG` (1 day), to name the next or to prove a block (BNB-2).
- **Tron is written, never parsed.** `TronStateVerifier` writes every header and transaction it hashes from typed
  fields, and writes the call itself: the vault, `attest`'s data, no value, and the result SUCCESS. Do not add a
  protobuf parser. A header's unknown fields are appended as given, after every field the verifier reads (TRN-1). A
  learned producer is the witness its block names, with the key that signed it (TRN-5), and a list's round starts at
  least two blocks into its period, past the block after the maintenance, which Tron schedules two slots behind
  (TRN-2; `test/fixtures/tron/generate.py` checks it on mainnet). Only the list before vouches (TRN-4). Section 5.7 of
  the spec has the rest.
- **Size.** The hub and the module are both near the 24KB limit; new code goes in the extension. Check
  `forge build --sizes` after any change to any of the three. `XindexVault` is near it too, with about 200 bytes to
  spare after token support; the snapshot claim's reading and signature check live in the linked `VaultSnapshot`.
- **The Solana vault is the EVM vault's twin.** `solana/programs/xindex-vault` keeps the same messages, digests, speed
  limit and freeze, and its `abi` tests pin every encoding against Solidity's. A change to either vault's rules or to a
  message goes into both. `solana/programs/stub-verifier` trusts a relayer key and exists for testnets only; nothing in
  `src/` or `script/` may name it. `solana/programs/ethereum-verifier` is P1 on Solana, the twin of
  `EthereumFinalityVerifier.sol`: the same anchor, the same headers tree, the same receipt proof, and SP1 v6's Groth16
  check on the alt_bn128 syscalls, tested on SP1's own proof and on real mainnet receipts. `solana/programs/
  risc0-verifier` is P2, the same core (`process_with`) with RISC Zero v3.0's check, tested on RISC Zero's own receipt;
  as on the EVM, only the proof's check may differ between them. The vault keeps checkpoints, stalls, recovers and
  exits as `XindexVault` does, reading the hub's storage at its snapshot, which `tests/fixtures/generate.py` captures
  from a real hub on anvil. Its gates: `anchor build --no-idl`, `cargo build-sbf` for the stub, `ethereum-verifier`
  and `risc0-verifier`, `cargo test -p xindex-vault -p ethereum-verifier -p risc0-verifier`, `cargo fmt --check` and
  `cargo clippy`, at low priority.
- **NEAR and Stellar are twins too.** `near/` and `stellar/` keep the EVM vault's rules, as Solana's program does, on
  `crates/xindex-core`, the vault chains' shared Rust (no_std, over a `Crypto` trait each chain implements; Solana's
  programs build on it through `ethereum_verifier::Solana`). A change to a vault's rule or a message goes into all four
  vaults, and into the core where the rule lives. Each proves its state by `attest`, as TRON's does: NEAR's return value
  carries the run's own height and time, since an outcome lands in a later block. Stellar's transaction holds 132 KB,
  so a message whose receipt proof is larger is delivered from its `resendMessage` copy. NEAR's Wasm needs `--cfg near`
  (`near/.cargo/config.toml`), or near-sdk's refusals trap without their names. Gates, each at low priority on one
  build job: the core's `cargo test`, `cargo fmt --check`, `cargo clippy --all-targets` and `cargo build --target
  wasm32-unknown-unknown --no-default-features`; NEAR's `cargo build -p xindex-vault-near --target
  wasm32-unknown-unknown --release`, then `cargo test -p xindex-vault-near -- --test-threads=1` (the sandbox runs the
  built Wasm), fmt and `cargo clippy --all-targets -- -D warnings`; Stellar's `stellar contract build`, then `cargo
  test`, fmt and `cargo clippy --all-targets -- -D warnings`; `proofs/near`'s `cargo test -p xindex-near-finality` and
  `proofs/stellar`'s `cargo test --release -p xindex-stellar`, each with fmt and clippy.
- **Sui, Aptos, Injective and VeChain.** The twin rule spans the EVM vault, Solana's, NEAR's, Stellar's, Sui's and
  Aptos's: a change to a vault's rule or a message goes into each, for the coins each vault holds. Which coins a vault
  can hold differs by chain: the EVM vault (BNB Chain, TRON, Injective, VeChain) holds capped tokens as well as the
  native coin, and the others hold their native coin only, so holding tokens there would be a change of its own.
  - `sui/` is the Move twin. Its `Attestation` object's bytes are pinned against `SuiStateVerifier`'s
    (`test/SuiStateVerifier.vault.t.sol`). Its gates: `sui move build` (no warnings; one lint suppressed with its reason)
    and `sui move test`, with `SUI_CONFIG_DIR` set to a throwaway directory holding a keyless `client.yaml` (an empty
    keystore, no active address, one environment). Never run `sui client`, `sui keytool` or `sui start`: the CLI
    creates a key when it finds no configuration.
  - `aptos/` is the other Move twin. Its `Attested` event is pinned against `AptosStateVerifier`'s statement
    (`proofs/aptos/fixtures/synthetic.json`). Its gates: `aptos move compile --dev --fail-on-warning` and
    `aptos move test --dev`. Never run the Aptos CLI's `init`, `account`, `key`, `publish`, `run` or `node`: they
    create keys or touch a network. The vault object belongs to `0x0`, since any owner up an object's chain could
    withdraw from its fungible store, and `attest` is an entry function only, so a transaction holds at most one
    `Attested`.
  - `SuiStateVerifier`'s lag is 2 days from its committee's epoch start, since Sui's epochs last a day; `Bls12381MinSig`
    is `Bls12381`'s min-sig twin, and checks every length (BLS-1).
  - `CometBftStateVerifier` takes a hop only when more than 2/3 of the trusted set signs it, never ibc-go's third.
    `proofs/cometbft`'s gates: `cargo test --release`, fmt and `cargo clippy --all-targets -- -D warnings`.
  - VeChain's weights live only in its Staker's storage, which nothing public proves, so `VeChainStakerAttester`, an
    ownerless view on VeChain, attests them, trusted by TRON's vouching rule (TRN-4). Every contract the VeChain
    deployment creates has its Prototype master cleared. `proofs/vechain`'s gates as `proofs/cometbft`'s, and
    `vechain/`'s `npm run deploy-test`.
- **P1 is checked in plain Rust first.** `proofs/finality` holds the whole statement, so its logic is tested natively and
  the zkVM only runs it. Its gates: `cargo test --release`, `cargo fmt --check` and `cargo clippy`, at low priority,
  each also with `--features sepolia`, the testnets' build: Sepolia's genesis and fork versions, a program key of its
  own, pinned by a real Sepolia vote (`tests/sepolia.rs`). `tests/vectors.py` rebuilds its independent vectors, and a
  regression in it needs a mutant that the tests catch. The statement must stay the same code under SP1 and RISC Zero,
  so it calls no zkVM fork's own API: its hash to G2 is composed from RFC 9380 and pinned by the RFC's vectors
  (`tests/hash_to_curve.rs`). P2 (`proofs/p2`, RISC Zero) is built with `cargo build --release -p xindex-p2-host`, and
  `p2 execute` on a real input must commit what `p1 execute` commits.

## v5: custom-weight indexes (in progress, not deployed)

`design/2026-10-05-custom-weights.md` has the spec, and `audit/2026-10-05-v5-review.md` its internal review. These are
the rules code must never break.
- **One place reads a price.** Only `WeightedHub`'s settlement reads one, from Pyth, and only for the moving
  components. Issue, redeem, `redeemSkipping` and claims never read a price, so no feed can block an exit or misprice a
  mint (`test_issueAndRedeemNeverCallPyth`). The factory stores price ids and never calls Pyth;
  `test_V5I4_onlyTheWeightedHubReadsAPrice` fails if any other file names Pyth's contract, parse, getters, pushes or
  price struct. No Chainlink feed or pool price anywhere, as in v4 (`test_noContractReadsAPrice`).
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
  units, weight, price id and decimals.
- **The cap counts units, never value.** A fill sends out at most `MAX_TURNOVER` (20%) of each component's own units,
  every leg moving the same share of the way, so a wrong or malicious price takes at most that, once a week. A value
  cap measured in the reported prices let two wrong feeds take 89% of an index far from its weights (V5-M2); do not
  bring one back as the only cap.
- **A fill must trade.** One that would release less than `MIN_TRADE` (0.1%) of the moving value reverts
  `NothingToRebalance`, and a keep mask must leave two components moving, so a fill that changes nothing cannot restart
  `MIN_REBALANCE_INTERVAL` (V5-L2). The guardian's cancel remains the trust assumption DA-12 records.
- **The settlement's rounding.** Targets round up; a shrinking leg's step rounds down; a growing leg's rounds up, by the
  factor `μ · s` rounded up, with `μ` falling from `MU_MAX` to `MU_MIN` and rounding up. At the settling prices the
  executor delivers at least `μ` times what it takes. A fill that sends nothing out settles at `MU_MAX`. The backing
  post-check is `IndexHub`'s. The mutants worth rerunning: each of those roundings flipped, no unit cap, no
  `MIN_TRADE`, a keep mask leaving one, a wider window or the minute, no confidence or publish-time check, a kept feed
  read, and the duplicate-id checks removed.
- **A collapsing coin can stop the fills.** Fixed weights keep buying it, and units beyond `uint96` stop the fill rather
  than wrap, until the guardian keeps it (V5-L3, a known limitation).
- **Everything else is `IndexHub`'s**: the invariant, rounding on issue and redeem, claims booked to `to`, the
  recipient traps, the reentrancy guard on every mutating entry point, keep masks (a kept component is neither priced
  nor read), the cancel and restart hold-offs, and the bounded fill.
- **The zap and `MintRequests` are v4's, unchanged,** deployed against the weighted factory: an index keeps the
  signatures they call (`issue`, `redeem`, the previews, `componentTokens`, `rebalanceNonce`).
- **Every payable path forwards the whole of `msg.value` to Pyth;** the hub never holds ether.

## Conventions

- `pragma solidity 0.8.28;` in `src/` and `script/`; tests use `^0.8.24`. The compiler is pinned to 0.8.28 in
  `foundry.toml`, and CI pins Foundry v1.8.1 and eth-wake 4.22.1 in `.github/workflows/test.yml`.
- **Wake config.** CI generates its Wake config from `foundry.toml` and adds `audit/`, `prototype/`, `demo/`,
  `keeper/` and `vendor/` to its excluded folders, since any of them would stop Wake before a detector runs: the PoC
  tests in `audit/` only compile inside `test/poc/` of the audited commit, `prototype/evm` is a separate Foundry project
  that needs via-IR, `demo/` and `keeper/` (the bot's executor) are ones whose `xindex/` remapping only they know, and
  `vendor/` holds third-party verifiers with their own import paths, which no gate analyzes by design. The Wake VS Code extension reads `.vscode/settings.json`
  instead, which holds four things:
  - `wake.configuration.use_toml_if_present` set to false. The extension otherwise prefers a `wake.toml` in the
    workspace root, and a local `wake detect` or `wake init config` leaves one there, gitignored. A stale one
    replaces the whole committed config, so the extension compiles `prototype/` and `demo/` and reports their errors;
  - its copy of `forge remappings` (paste the new output there whenever a dependency or remapping changes);
  - the optimizer settings of `foundry.toml` (without them the factory's initcode looks too large to deploy);
  - Wake's default excluded folders plus `audit/`, `prototype/`, `demo/`, `keeper/` and `vendor/`.
- **Prague in tests.** `src/` compiles for Cancun, but the BLS12-381 precompiles (EIP-2537) exist from Prague on,
  which Ethereum mainnet runs. A suite that calls them sets `/// forge-config: default.evm_version = "prague"` on its
  contract; `vm.setEvmVersion` inside a test does not enable them for calls already running.
- **Gas in tests.** Foundry 1.8 runs every call a test makes as its own transaction (`isolate = true`), so a measured
  call already carries the 21,000 and its calldata, EIP-7623's floor included. Build the calldata before measuring,
  and send it without Solidity's `call`, which first copies it to the top of the test's memory and pays for that
  expansion (`test_gas_followingTheChain`).
- OpenZeppelin v5.7.0 and forge-std v1.16.2, pinned in `foundry.lock`; the staged submodule commits must match
  it, and CI checks that. The hub uses the upgradeable ERC20 because clones skip constructors, and the
  storage-based `ReentrancyGuard` because its zeroed slot is "not entered" in a clone.
- **Vendored code** keeps its license header and names its source commit:
  - `IUniversalRouter` and `UniversalRouterCommands` come from Uniswap's universal-router (GPL-3.0-or-later) at
    `3663f6db6e2fe121753cd2d899699c2dc75dca86`, which is tag 2.0.0 and the deployment the zap is pinned to.
  - `UniswapV4Types` comes from v4-periphery (MIT) at `444c526b77d804590f0d7bc5a481af5a3277c952`, the commit that
    router was built against.
  - `ISP1Verifier` comes from succinctlabs/sp1-contracts (MIT) at `d3629729c3216eb51bd4859d027a8eb729399fa4`, the SP1
    v6 verifiers the prototype measured, with its pragma pinned.
  - `IRiscZeroVerifier` comes from risc0/risc0-ethereum (Apache-2.0) at `365e7b2db4f620fa256580c27558d2623362b9ae`,
    tag v3.0.1, the release that matches the zkVM P2 is built with: the interface and the `Receipt` struct it takes,
    with its pragma pinned and the file's libraries left out, since nothing here computes a claim.
  - `IPyth`, `IPythEvents` and `PythStructs` come from pyth-network/pyth-crosschain (Apache-2.0) at
    `2bb0eb54b2b3af8854d0c26f3884c28a0fce0802`, `target_chains/ethereum/sdk/solidity/`, with the pragma pinned and the
    whitespace `forge fmt` writes; their plain imports and Pyth's own events carry the suppressions of vendored code.

  - `PancakeRouterCommands` records the command bytes, sentinels and input layouts of PancakeSwap's v3 Universal Router
    (GPL-3.0-or-later) from its verified source on Etherscan at `0x65b382653f7C31bC0Af67f188122035461ec9C76`, runtime
    code hash `0xdb8dfdb9…d3f6`: no public repository holds that version, so the deployed source is the reference.
    `test/mocks/MockPancakeRouter.sol` follows the same source.

  A vendored struct may retype `Currency` and `IHooks` to `address`, which is ABI-identical. Change vendored code only
  to replace a dependency, never to restyle. Both router libraries record the input layout of every command and action
  they name, from `Dispatcher.sol` and `Actions.sol` at those commits, because that layout is what the zap encodes
  against.
- Custom errors, not revert strings. An error that more than one contract raises is declared once, in
  `src/interfaces/IXindexErrors.sol`, which the factory, hub and zap interfaces extend. Tests name it
  `IXindexErrors.<Error>.selector`, because Solidity does not resolve an inherited error through
  `IIndexFactory.<Error>`. Immutables in SCREAMING_SNAKE_CASE. Loop counters initialised explicitly (`uint256 i = 0`).
  Modifier logic lives in a private function.
- Foundry runs any test-contract function whose name starts with `table` as a table test: name none so, nor any
  function a test suite inherits (VeChain's attester calls its view `currentTable` for that reason).
- `foundry.toml` keeps `dynamic_test_linking = false`. With forge's default, a test function ends at the first
  `vm.expectRevert` followed by `new` of a `src/` contract, reported as a pass, and every check after it is skipped
  (LR-01). It also keeps `[invariant] fail_on_revert = true`: the handler only makes calls that must succeed, so a
  handler action that can legitimately revert has to check its precondition first (`canStartRebalance()`,
  `previewBand`, a live batch, a non-zero balance).
- **A regression test has to fail without its fix.** Check it against the old code or a mutant before relying on it.
  The logic review found tests that passed either way: mocked return values instead of the real flow, prices that never
  moved between two snapshots, a salt whose fields were never varied one at a time. The mutants worth rerunning on
  `WeightedHub` are listed in the v5 section, with the backing post-check's: the claims dropped from the backing term,
  only the bought legs re-read, and a shrinking leg paid as a difference of floored backings.
- **Tests.**
  - One `*.t.sol` per contract; both hubs' rebalancing and invariants have their own files, and so do a HybridHub's
    migration and snapshot exit and the invariants of the vault and `MintRequests`.
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
  - A Stage B test that moves the clock past a vault's `STALL_PERIOD` brings a fresh checkpoint before any deposit
    (`HybridTest._fresh`), as keepers keep a live vault out of a stall.
- **Scripts.** They keep their logic in public functions that take explicit arguments, so tests can call them without
  environment variables: `Deploy.deploy`, which deploys `HybridIndexFactory` with both templates, the zap and
  `MintRequests`; `DeployVault.deploy`, which deploys a vault chain's P1, P2, state reader and vault, refusing any
  Groth16 verifier but the pinned SP1 and RISC Zero ones; `DeployStateVerifier.deployBnb` and `deployTron`, which
  deploy a chain's state verifier on Ethereum from a fresh anchor; `ConfigureWeighted.propose`, `execute`,
  `safeCalldata` and `status`; `ConfigureChains.propose` and `execute`, which add a vault chain and its
  coins, and `proposeCaps` and `executeCaps`, which give a vault coin its cap; and `CheckToken.check`, which reports on
  one token. Environment variables are process-global and tests run in parallel, so each variable name is set by exactly
  one test (see `test/Scripts.t.sol`). In tests, script broadcasts come from `DEFAULT_SENDER`.
- **Deployment rules.**
  - Deployments never use raw private keys: `--account` keystores or `--ledger`.
  - `OWNER` and `GUARDIAN` are required.
  - On mainnet the owner must be a contract that is not an EIP-7702 delegated account. A Safe owner must need at least
    `MIN_OWNER_THRESHOLD` (3) signatures, the design's 3-of-5 (the owner's call on 2026-09-30), and have no enabled
    module.
  - When the owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers (SA-06).
  - Neither role may be a market contract: the router and its PoolManager, and on chain 1 every token and mint
    currency in `script/MainnetAddresses.sol` (CR-I37).
  - On a vault chain, `DeployVault` refuses the indexes' own chain, a missing factory, template, P1 key, P2 image id or
    anchor, and a floor above the cap. The freezer and the recovery proposer must be set, distinct and not the
    broadcasting key, and the recovery proposer, the owner's emergency multisig there, must be a contract that is not
    an EIP-7702 delegated account.
  - `DeployStateVerifier` deploys only on mainnet or Sepolia, from a BNB anchor at most `MAX_ANCHOR_AGE` (1 hour) old
    or the TRON period in progress. The verifier must then be advanced within `MAX_LAG` (1 day) of its anchor, and
    every day after, or it stops for good.
- **Mainnet addresses** are verified on-chain before being committed: tokens by symbol and decimals, and the router and
  the PoolManager by their runtime code hashes, since every Universal Router build answers `poolManager()` alike
  (CR-I35). `test/fork/MainnetAddresses.fork.t.sol` checks `script/MainnetAddresses.sol` that way. It also lists v5's
  lists on a fresh factory, and `test_CRL08_theListsAreTheReleaseRecord` pins both lists, address and price id, against
  a table written independently of them. Every price id carries its feed's description beside it. The WBTC address is `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one.

## Product decisions already made (do not re-litigate silently)

**v5 replaces v4's market-cap index** (the owner's calls on 2026-10-05). Creators choose each coin's percentage; the
weights are fixed at creation; the index rebalances to them at Pyth prices, which cover all 52 listed coins where
Chainlink's Ethereum feeds cover 11. Pyth is the only oracle: Chainlink alone, and Chainlink as a second check on the
coins it covers, were both refused (the owner's call on 2026-10-05). v5 is custom percentages only. Its parameters (section 8 of the spec) wait on a
replay of Pyth's history, and Hermes now needs a paid API key, an operating cost the owner weighs before launch.

**The listings and chains of v5** (the owner's calls on 2026-10-06):
- No team index at launch: creators make every index, so "flagship" names no product.
- The admission rule stays the WBT rule; Binance-Peg coins stay listable, labelled Custodial.
- The v5 Ethereum list is 27 coins: no OKB, BGB, GT or GRAM. NIGHT is refused.
- TRX is held as the BEP-20 TRX of TRON's closed BTTC bridge, in BNB Chain's vault, labelled Custodial; its Ethereum
  copy is not listed. The TRON vault stays built, and whether it is deployed too is the owner's call.
- The vault chains are the eight built, plus Solana and HyperEVM when their chains allow; any other chain's coin comes
  in only as an existing token on Ethereum or BNB Chain ("What this is" has the detail).

**Swap venues** (the owner's call on 2026-10-06, "only for swap rail", `design/2026-10-06-swap-venues.md`): the zap
gains PancakeSwap V3 legs through PancakeSwap's v3 Universal Router, beside Uniswap's 2.0.0; on Ethereum it matters
mainly for CAKE, whose Uniswap depth is negligible. THORChain is app-side only, from the user's own accounts
(`swaprail/`), and no contract calls it.

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
  2026-09-29; do not reopen it). The wide list (`V5_WHITELIST=wide`) serves creators' indexes; there is no flagship to
  hold any of it since the owner's calls of 2026-10-06.
- **Fees.** None in Stage A: audits, the bounty and watchers are funded from outside (the owner's call on 2026-09-30,
  over a minter fee in shares or a management fee, design §13.1). A later version could add one; only `_backing` and
  its callers would change.
- **Launch.** One hybrid product on one factory, `HybridIndexFactory`, launched once the hybrid index is ready: P2, real
  proving and the vaults' audits (the owner's call on 2026-10-01, which settles the one-or-two-factory question the
  owner deferred on 2026-09-30). Stage A does not launch on its own; an index of Ethereum tokens only is still an
  `IndexHub` clone of that factory. `script/Deploy.s.sol` deploys it: the `HybridHub` template's extension, module
  and template first, each built for the factory's address predicted from the broadcaster's nonce, then the factory,
  which deploys the `IndexHub` implementation, then the zap (for `IndexHub` clones only) and `MintRequests`.
- **Stage B and C limits.** `SPEED_LIMIT` and `MINT_CAP` are 4% a day (the owner's call on 2026-09-30). The guardian's
  freeze expires. Ethereum verifiers rotate every 30 days. Script-only chains are out.

Unchanged from v3:
- Ethereum mainnet first.
- Execution through Uniswap's Universal Router 2.0.0, with the venue chosen per leg by the caller. That decision of
  2026-09-22 superseded SwapRouter02 and QuoterV2 (`audit/2026-09-22-v3-retirement.md`). Since 2026-10-06 a leg may
  name PancakeSwap's v3 Universal Router instead ("Swap venues" above).
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
- Everything multichain: vaults, proofs, the mirror and the rest of Stages B and C. Stage B is built in large part and
  deployed nowhere, under its own section above; Stage C is researched, not built. "What this is" says where each
  stands.
