# CLAUDE.md

Guidance for coding agents and humans working in this repository. This file is the only copy: it imports no other, and
Claude Code reads it as the project's instructions. It states the protocol and its rules as they are; what changed and
when is in `CHANGELOG.md`.

## What this is

Xindex is a Foundry project of index tokens backed in kind. An index is an ERC-20 whose every share is backed by fixed
units of each of its component tokens. Wallets the factory's owner approves create indexes. Anyone mints one with USDC
or USDT, the only two currencies, held to them on chain (`NotAStable`), through `IndexZap`, `BasketBuilder` or a limit
order in `MintRequests`, or in kind; anyone redeems for USDC, USDT or the basket itself. Swaps run through Uniswap's
Universal Router 2.0.0, on V3 or V4 pools, or through the chain's own DEX, PancakeSwap on BNB Chain and Aero on Base,
one venue per leg, chosen by the caller (`docs/design/chain-venues.md`). The web app lives in a separate repository.

An index's coins are fixed at creation, two to two hundred of them, each with a weight. The creator may change the
weights, never the coins, behind 7 days of notice (`docs/design/changeable-weights.md`). The index rebalances toward
its weights through a permissionless auction: the executor names the units it settles at, and the index accepts them
when every leg stays inside its unit caps and a weighted gain in units clears a bar that falls with time
(`docs/design/rebalance.md`). On a factory with an oracle, which every mainnet factory is, a fill must also bring in, at
Pyth's prices, what it takes out less a tolerance that grows to 2% over the auction, a check that can only refuse
(`docs/design/pyth-check.md`); an Ondo token is valued there at its share's Pyth price times the sValue Ondo's oracle
holds for it, once that sValue is settled (`docs/design/ondo-svalue.md`). A creation must sit within 5% of its weights
at Pyth's prices. No issue, redeem or claim reads a price.

**Three deployments that share nothing**, on Ethereum, BNB Chain and Base: the same contracts, each under its own owner
Safe and guardian's Safe, each holding its own chain's tokens in kind. An index lives on one chain, and on each chain
only wallets the owner approves create one.

- **Ethereum** (`script/Listings.sol`, 414 tokens). 61 coins: the issuer's own contract where Ethereum has one, Bitcoin
  as WBTC, Tether Gold, and Wormhole's copies of SOL and AVAX, labelled Bridged (`docs/design/wormhole-legs.md`). And
  Ondo's 353 tokenized US stocks and ETFs, every one Pyth has a feed for (`docs/design/ondo-stocks.md`). 26 more
  Wormhole copies wait for an attestation, and FIL's waits for a reading of its Binance-Peg source
  (`docs/design/pre-mainnet-readings.md`, section 3).
- **BNB Chain** (`script/BnbChainAddresses.sol`, 366 tokens): 13 coins, nine of them Binance-Peg and labelled
  Custodial, and the same 353 Ondo tokens (`docs/design/bnb-chain.md`). `V5_WHITELIST=bnb`, `CHECK=bnb`,
  `test/fork/BnbChainAddresses.fork.t.sol`.
- **Base** (`script/BaseAddresses.sol`, 32 tokens): WETH, AERO and ZRO, which Base issues; thirteen copies Base's own
  bridge mints of coins on Ethereum's list, each proven on chain and labelled Bridged; and Coinbase's six wrapped coins
  and ten stock tokens, Custodial (`docs/design/base.md`, `docs/design/coinbase-on-base.md`). `V5_WHITELIST=base`,
  `CHECK=base`, `test/fork/BaseAddresses.fork.t.sol` and `test/fork/BaseStocks.fork.t.sol`. Coinbase's stock tokens are
  precompiles of Base that the pinned Foundry cannot execute, so their suite runs an index of them on Base's own node
  (`eth_simulateV1`).
- **Solana, in development** (`solana/`, an Anchor workspace, program `xindex`; `docs/design/solana.md`). Its address
  book is Ondo's 353 tokens, Ethereum's Ondo list, each a Token-2022 mint read on chain that carries its share
  multiplier itself (`solana/listing/ondo.json`, written by `solana/listing/read_ondo.py`). The program carries the
  EVM design rule for rule, each path that touches every leg split over transactions, since two hundred legs fit no
  Solana transaction: the configuration and its roles, listings with an extension check and Pyth feeds, approved
  creators, creation in four steps on the weights at Pyth's prices, issue and redeem in kind through tickets, fees in
  shares and the streaming fee's scale, the creator role, the gate and the mint pause, and the rebalance: the clock,
  the keep mask, the cancel, the quote, changeable weights, and a fill through a ticket that the executor pays into
  first, judged on units by the EVM arithmetic (replayed against every settlement vector) and refused by the quote
  or Pyth's prices, each a `PriceUpdateV2` of Pyth's receiver, an Ondo leg at its share's price times the mint's
  settled multiplier; and limit orders, each request escrowing in an account of its own. A buy or a sale is the app's
  transaction composing Jupiter's swap with a deposit or a claim, so no zap or builder program is needed. Not built:
  the listing transactions for the Safe and the deployment, the keeper and the app on Solana, CI. Its tests run on LiteSVM, with Ondo's mint accounts as read and
  Pyth's accounts as the receiver writes them, not on a fork of Solana.

Who an index relies on beyond its holders: the issuer of each component; Wormhole's guardians for the whole of each
wrapped leg, and Base's bridge for each of its copies, which the app shows as an index's bridged share of value; Pyth's
keys and Ondo's oracle, which can refuse a fill or loosen Pyth's check toward the bar's own bound, never past it; and
the DEXes a leg names. Nothing crosses a chain inside a protocol contract: the app and the fillers bridge. The keeper's
executor, a filler's, holds no role.

Nothing is deployed on a mainnet. Sepolia runs the oracle-free build of `5b7635f` under a 2-of-3 test Safe
(`docs/deployment.md`); this branch's build is not deployed there.

## Where it stands

Built and gated: the factory, the hub and its math, `PythPrices`, the zap, the basket builder and `MintRequests`; the
deploy, configure and admission scripts with an address book per chain; and the keeper (`keeper/`): its bot and
executor, the restock service and the invariant checker. On the current build: 662 tests without an RPC, coverage 100%
on every file, the mutation gate's 379 mutants all killed, Aderyn and Wake silent, the settlement vectors replayed and
`test/vectors/proofs.py` passing; the keeper's 97 Solidity tests, 263 unit tests and 15 harness tests. The fork suites
of all three chains pass near each head, save what needs an archive node (below) and `IndexZap.fork`'s
`testFork_mintWithUSDC`, whose $100 sanity floor the basket misses at today's prices.

Before any mainnet:
- An external audit, from the brief `audits/audit-package.md`; then `DeployWeighted`'s release hashes fixed at the
  audited commit (CF-5). Every review so far is internal; Pyth's check has had no reviewer from outside the team.
- A Hermes plan: every fill under Pyth's check, and every creation, posts an update of Pyth's.
- On each chain: the owner Safe and the guardian's Safe, the price feeds, and the approved creators.
- A Sepolia deployment of this build, and the app moved to it: `createAndIssue` with Pyth's update, the weights
  interface, `localRoute`, `SValueUnavailable`, both pauses.
- Runs on an archive node: `WeightedHub.fork`'s two whole-list tests, `CheckToken.fork` and the keeper's end-to-end
  test, which outrun a public node's window.
- On Ethereum, Ondo's oracle holds 10 of the 353 Ondo tokens: the other 336 can neither be created into an index nor
  moved by a fill until Ondo registers them there.
- The 26 attestations and RAY's update; the platform's fee policy (its fee, the referrer's share, its streaming rate,
  and with them self-referral, RY-3 and RW-4); counsel's legal reading.
- The factory's init code is 447 bytes under EIP-3860: the next change that needs room there moves `PythPrices` out of
  it, as `WeightedMath` is.

The two Universal Router files `IndexZap` and `BasketBuilder` compile, `IUniversalRouter` and `UniversalRouterCommands`,
are declarations of our own, so every file the four contracts compile is ours or MIT-licensed (`NOTICE`).

For more:
- `audits/audit-package.md`: the external auditors' brief: the candidate commit, the scope, the roles, the
  properties, where to look first, and every earlier review's open ids.
- `docs/design/rebalance.md`: the rebalance's spec: the rule, why it is safe, the auction, what a fill can take.
- `docs/design/pyth-check.md`, `docs/design/ondo-svalue.md` and `docs/design/changeable-weights.md`: Pyth's check,
  creation on the weights, Ondo's sValue, and the weights' notice.
- `docs/design/rebalance-state-machine.md`: the rebalance's eight states, the transition matrix, the clock's
  boundaries and the invariants, with the test and the mutants that pin each cell.
- `docs/design/settlement-vectors.md` and `docs/design/settlement-proofs.md`: the exact model, its vectors and the
  proofs' method, which the current model keeps.
- `audits/internal/consolidated-audit-ca.md`: the consolidated audit, every finding with its verdict, what was fixed,
  what was left and why, and what changed for integrators.
- `audits/retired/`: the review ids that went with each retired design, and every re-targeted test.
- `docs/design/wormhole-legs.md`, `docs/design/wide-asset-support.md` and `docs/design/token-admission.md`: the
  lists, the trust table and the admission check.
- `docs/design/stage-a-spec.md` and `ARCHITECTURE.md`: the in-kind design `WeightedHub` keeps.
- `README.md`: the overview. `docs/`: integration, known limitations, assets, decisions, deployment and development.
  `docs/product-brief.md`: the brief the product was built from. `CHANGELOG.md`: the history and every product
  decision as it was made.

## Commands

```bash
forge build --sizes --deny warnings  # compile as CI does: a compiler warning fails it; lint findings print but pass
forge lint -D notes          # lint gate CI runs: fails on any warning or note
forge fmt                    # format; CI runs `forge fmt --check`
forge test                   # unit + fuzz + invariant tests, no RPC needed; forge auto-loads .env, and a MAINNET_RPC_URL
                             # there makes the fork suites run too (archive node, or FORK_BLOCK, or --no-match-path 'test/fork/*');
                             # an RPC that cannot serve the pinned block fails with that sentence, not a raw fork error
forge coverage               # must stay at 100% for every file (lines, statements, branches, functions)
python3 -I test/vectors/settlement.py > test/vectors/settlement.json  # after a change to WeightedMath: regenerates the exact
                             # model's vectors, which test/WeightedMath.vectors.t.sol replays; commit the model, the vectors and the change together
python3 -I test/vectors/proofs.py  # the proof's chain behind the settlement, checked in exact rationals (11 s, no dependency):
                             # rerun it after any change to the model
aderyn .                     # Aderyn on src/, configured by aderyn.toml: must report nothing; CI does not run it
python3 -I test/mutants/run.py  # the mutation gate: every mutant of test/mutants/mutants.json must be killed (CI runs it);
                             # --only M3,V8 runs some, --check only that every edit still applies; a mutant with
                             # "runner": "node" names a keeper/test/unit suite instead of a forge one
for c in IndexZap BasketBuilder MintRequests WeightedIndexFactory WeightedHub PythPrices; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change
forge test --root keeper     # the keeper's executor, its own Foundry project; CI also runs its fmt, build and lint
node --test keeper/test/unit/*.test.mjs  # the keeper bot's arithmetic, unit naming, settings, Hermes client and tx tracker (no dependency)
node --test keeper/test/harness/*.test.mjs  # the request filler against a fake chain; needs `npm ci` in keeper/ and the executor's build; not in CI
UNISWAPX_E2E_RPC_URL=https://ethereum-rpc.publicnode.com npm run e2e:uniswapx --prefix keeper  # the restock's UniswapX buys
                             # on a fork near the head, the real reactor and a faked API; needs `npm ci` in keeper/ and both builds

# mainnet fork tests (real tokens, Universal Router, V3 and V4 pools); skipped when the env var is unset.
# A rate-limited RPC throttles five suites in parallel: add -j 1.
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# public non-archive RPCs only serve recent state: pin near the head
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/*'

# the BNB Chain deployment's fork suite (real tokens, Universal Router, V3 pools); skipped when the env var is unset
BNB_RPC_URL=https://bsc-rpc.publicnode.com BNB_FORK_BLOCK=$(( $(cast block-number --rpc-url https://bsc-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/BnbChainAddresses.fork.t.sol'

# the Base deployment's fork suite, the same way
BASE_RPC_URL=https://base-rpc.publicnode.com BASE_FORK_BLOCK=$(( $(cast block-number --rpc-url https://base-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/BaseAddresses.fork.t.sol'

# the Solana program (solana/): build it, then its unit, vector and LiteSVM tests, formatting and lint; Anchor 1.2, and
# the toolchain solana/rust-toolchain.toml pins for the host
(cd solana && anchor build && cargo test && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings)
python3 -I test/mutants/run.py --table solana/mutants.json  # the Solana program's mutants, each built and run (about 10 min)
# Solana's address book of Ondo's tokens, read again from Ondo's pages and Solana's chain (standard library only)
python3 -I solana/listing/read_ondo.py

# the admission check, read-only, before any listing: one report per token for the Safe's signers
CHECK=wide forge script script/CheckToken.s.sol --fork-url $MAINNET_RPC_URL
CHECK=bnb forge script script/CheckToken.s.sol --fork-url $BNB_RPC_URL
CHECK=base forge script script/CheckToken.s.sol --fork-url $BASE_RPC_URL
```

Deployment, once on each chain, Ethereum, BNB Chain and Base: `script/DeployWeighted.s.sol`, which gives the guardian role
to that chain's guardian's Safe,
then `script/ConfigureWeighted.s.sol`, which lists each coin of `script/Listings.sol`; the owner then approves the
wallets that create indexes (`setApprovedCreator`), and nobody can create one before. `script/CheckToken.s.sol` reports on every token before its first
listing; `V5_WHITELIST=default` is the first four coins and `V5_WHITELIST=wide` the rest, 414 in all, on Ethereum;
`V5_WHITELIST=bnb` is BNB Chain's 366 and `V5_WHITELIST=base` Base's thirty-two. On chains 1, 56 and 8453 the deploy script resolves the router and the
stablecoins from that chain's address book and refuses any other address
(`DeployChecks.isPinnedChain`). Sepolia first needs its test market from
`script/testnet/SetupTestMarket.s.sol`.

## Definition of done for any change

1. `forge fmt --check` clean.
2. `forge build` clean, including `forge lint` (zero warnings and notes). Lint config lives in
   `foundry.toml` `[lint]`; each excluded rule has its reason in the comment block above the list. Do not
   add exclusions without a reason there. Prefer fixing code; use `// forge-lint: disable-next-line(<rule>)`
   or `disable-next-item(<rule>)` only for verified false positives, deliberate behaviour, or vendored code, with a
   one-line reason on the line above. The lint reads OpenZeppelin's internal `Math.mulDiv` as an external call.
   CI builds with `--deny warnings`, so a compiler warning fails it (A7-17).
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
   A change to an ABI or a struct the keeper reads (`MintRequests`, the hub, the factory, the builder) also runs the
   keeper's gates, as CI does: `forge fmt --check`, `forge build --deny warnings`, `forge lint -D notes` and
   `forge test` under `--root keeper`, and `node --test keeper/test/unit/*.test.mjs`. A draft of RW-7 that removed
   `fill(id, amount)` passed every gate of the root project and broke the keeper's build.
4. Fork tests green if the change touches `IndexZap`, the hub's rebalancing, routes, token behaviour, or anything
   router- or pool-related. Their summary must list the five Ethereum
   `test/fork/` suites and 0 skipped. `WeightedHub.fork.t.sol` alone took about an hour at a 91-coin list (its whole-list index is
   capped at `MAX_COMPONENTS`) on an archive RPC
   (Alchemy, Tenderly), nearly all of it the admission quotes on a cold RPC cache; a public endpoint prunes the state
   before it ends. They are also required when the deploy checks or `script/MainnetAddresses.sol` change, which
   `MainnetAddresses.fork.t.sol` and `Security.fork.t.sol` exercise. A change to the deploy checks, the zap, the swap
   engine or `script/BnbChainAddresses.sol` also needs the BNB Chain suite, `test/fork/BnbChainAddresses.fork.t.sol`,
   run with `BNB_RPC_URL`: CI runs it only once that secret exists, so until then it is run by hand. The same change,
   or one to `script/BaseAddresses.sol`, needs Base's suite, `test/fork/BaseAddresses.fork.t.sol`, run with
   `BASE_RPC_URL` under the same rule, and with it `test/fork/BaseStocks.fork.t.sol`, which needs a node that serves
   `eth_simulateV1`. With all three variables set, `forge test --match-path 'test/fork/*'` lists eight suites.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the documented suppressions are on the `redeem` call in `IndexZap._burnBasket`, the `permit` call in
   `IndexZap._tryPermit`, the `redeem` call in `BasketBuilder.redeem`, and the clone's `initialize` call in
   `WeightedIndexFactory._initializeIndex`, which the creation fee's transfer now follows. v5 adds the executor callback in `WeightedHub`.
   RW-6 adds the `accrueFees` call in `WeightedIndexFactory.acceptCreator`, as a block (`wake-disable reentrancy` to
   `wake-enable reentrancy`), since forge lint's marker has to sit directly above that call and Aderyn's at its end.
   Aderyn (Cyfrin's analyzer, `aderyn .`, and its VS Code extension) reports nothing on `src/` either. `aderyn.toml`
   excludes the rules the design rejects, each with its reason, as `foundry.toml` does for lint; a verified false
   positive is marked where it stands with `// aderyn-fp-next-line(<detector>)` and its reason on the line above, or
   `// aderyn-fp(<detector>)` at the end of the line when forge lint's own suppression must stay directly above it. CI
   does not run Aderyn yet: run it before pushing.
6. Every testable finding of the security reviews keeps its regression test passing, named after its id. A test that
   covers two findings carries both ids. The id families:
   - v1 findings: by their v1 id.
   - v2 rebalancing findings: `R01`..`R23`.
   - The whole-repo audit: `XA..` (`audits/internal/whole-repo-audit-xa.md`, triaged in
     `audits/internal/whole-repo-audit-xa-triage.md`).
   - The first logic review: `LR..` (`audits/internal/logic-review-lr.md`).
   - The deep audit: `DA..` (`audits/internal/deep-audit-da.md`, triaged in
     `audits/internal/deep-audit-da-triage.md`).
   - The verification review: `VR..` (`audits/internal/verification-review-vr.md`).
   - The first security audit: `CR-M01`, `CR-L01`..`CR-L08` and `CR-I01`..`CR-I41`
     (`audits/internal/security-audit-cr.md`, triaged in `audits/internal/security-audit-cr-triage.md`). These ids keep the review's
     prefix because M01, L03, L06, L08, I02, I03 and I09 to I12 are already v1 ids, so a CR test is named
     `test_CRM01_...`, `test_CRL03_...` or `test_CRI25_...`.
   - The first red team: `RT-01`..`RT-25` (`audits/internal/red-team-rt.md`), a test named `test_RT01_...`.
   - The red team of Stage A: `SA-01`..`SA-15` (`audits/internal/red-team-stage-a-sa.md`), a test
     named `test_SA01_...`. SA-08 to SA-15 were fixed or recorded by documentation alone and have no test.
   - The review of v5's weighted index: `V5-M1`, `V5-M2`, `V5-L1`..`V5-L3` and `V5-I1`..`V5-I4`
     (`audits/internal/v5-review.md`), a test named `test_V5M1_...`. The record's status column names every test, and
     the ids fixed or recorded by documentation alone, which have none.
   - The logic review of v5's core: `V5R-1`, `V5R-I1` and `V5R-I2` (`audits/internal/v5-logic-review.md`), a test
     named `test_V5R1_...` in `test/WeightedHub.rebalance.t.sol`. The informational ids are recorded by documentation;
     V5R-I1 is retired with Stage B.
   - The security audit of the v5 deployment and keeper: `CF-1`..`CF-8` (`audits/internal/security-audit-cf.md`). CF-1's tests are
     `test_CF1_...` in `keeper/test/KeeperExecutor.t.sol`; CF-4's `test_CF4_...` in `test/CheckToken.t.sol` and
     `testFork_CF4_...` in `test/fork/CheckToken.fork.t.sol`; CF-5's
     `test_CF5_...` in `test/Scripts.t.sol`; CF-6's `test_CF6_...` in `test/Repo.t.sol`; CF-7's the node test named
     `CF-7: ...` in `keeper/test/unit/math.test.mjs`. CF-3 is recorded by documentation alone. CF-2 and CF-8 are
     retired with THORChain.
   - The security audit of the fee, cadence and builder engine: `XS-1`..`XS-18` (`audits/internal/security-audit-xs.md`), a test named
     `test_XS1_...`. The record's status column names every test: the hub's in `test/WeightedHub.fees.t.sol`,
     `test/WeightedHub.rebalance.t.sol` and `test/WeightedHub.invariant.t.sol`, the builder's in
     `test/BasketBuilder.t.sol`, XS-17's in `test/Repo.t.sol`, the keeper's in `keeper/test/KeeperExecutor.t.sol` and
     the node tests named `XS-5: ...` and so on in `keeper/test/unit/`. XS-18 is recorded by documentation and the R11
     test's entry points, thirteen of them.
   - The red team of v5: `RX-1`..`RX-67` (`audits/internal/red-team-rx.md`), a test named `test_RX8_...`, and a
     node test named `RX-1: ...` in `keeper/test/unit/`. The record's "Status of the fixes" names every test; the ids
     fixed by documentation alone, the listing calls and the off-chain readings have none.
   - The review of the restock change: `RS-…` (`audits/internal/restock-review-rs.md`), a test named
     `test_RS1_...` in `keeper/test/KeeperExecutor.t.sol` and a node test named `RS-1: ...` in `keeper/test/unit/`. The
     record's status table names every test.
   - The rebalance review: `RB-1`..`RB-5` (`audits/internal/rebalance-review-rb.md`), a test named
     `test_RB1_...` in `test/CheckToken.t.sol`, and `test_RB2_RX12_...` and `test_RB3_...` in
     `test/WeightedHub.rebalance.t.sol`. RB-4 is fixed by documentation alone; RB-5's test is
     `test_RB5_noIndexIsAValidZapRecipient` in `test/IndexZap.t.sol`.
   - The review of the gate, the preview and the redeem fill: `AU-1`..`AU-3` (`audits/internal/review-au.md`), a test named `test_AU1_...` in
     `test/WeightedHub.fees.t.sol`, and `test_AU3_...` in `keeper/test/KeeperExecutor.t.sol`; AU-2's tests went with the
     Pyth-priced rebalance.
   - The two red teams of the Pyth-priced build: `RY-1`..`RY-9` (`audits/internal/red-team-ry.md`) and `RZ-1`..`RZ-33`
     (`audits/internal/red-team-rz.md`), both drafted with `RT` ids, which the first red team holds. A test
     named `test_RY1_...` in `test/IndexZap.t.sol`, `test_RZ23_...` in `keeper/test/KeeperExecutor.t.sol`,
     `test_RZ24_...` in `test/Scripts.t.sol` (RZ-26's, in `test/GuardianRelay.t.sol` and `test/Scripts.t.sol`, went
     with the relay), and node tests named `RY-6, RZ-1: ...`, `RZ-2, RZ-22: ...`, `RZ-5: ...`,
     `RZ-6: ...`, `RZ-8: ...`, `RZ-10: ...`, `RZ-11: ...`, `RZ-15: ...`, `RZ-16: ...`, `RZ-19: ...`, `RZ-20: ...`,
     `RZ-21: ...` and `RY-8: ...` in `keeper/test/unit/` (RZ-26's went with the relay too; RZ-13's is in the
     harness, which CI does not run), RY-8's with its mutants Y1 and Y2, and the later fixes with Z1 to Z13. Each record's
     "Status of the fixes" names every test; the ids fixed by documentation, the open ones and the keeper's wiring
     without a unit harness have none.
   - The protocol documentation review: `PD-1`..`PD-14` (`audits/internal/protocol-docs-review-pd.md`).
     PD-9, PD-10 and PD-12 keep node tests named `PD-10: ...` in `keeper/test/unit/` (the restock's journal,
     attestation and advance suites), with their mutants among P15 to P20; PD-14, a dashboard setting, is fixed by
     documentation alone. The other ten went with the non-EVM signers
     (`audits/retired/non-evm-restock.md`).
   - The red team of the oracle-free mechanism: `RW-1`..`RW-10` (`audits/internal/red-team-rw.md`), a test named `test_RW1_...`:
     RW-1's and RW-8's in `test/WeightedHub.rebalance.t.sol`, RW-6's in `test/WeightedHub.fees.t.sol`, RW-2's and
     RW-7's in `test/MintRequests.t.sol`, RW-9's in `test/IndexZap.t.sol` and, for the builder's half, in
     `test/BasketBuilder.t.sol`, where RW-10's are too, with their mutants W1 to W29. The record's "Status of the
     fixes" names every test; RW-4 and RW-5 are recorded by documentation alone, and RW-3 has `test_RW3_...` in `test/WeightedHub.rebalance.t.sol` since the hub fixed it, with mutants RS1
     to RS3.
   - The consolidated audit: `CA-H1`, `CA-H2`, `CA-M1`..`CA-M19`, `CA-L1`..`CA-L12`, `CA-R2-01`..`CA-R2-20` and
     `CA-S01`..`CA-S08` (`audits/internal/consolidated-audit-ca.md`). The ids are the reports' own under the prefix
     `CA`, kept for the reason the CR ids keep theirs. A test is named `test_CAH1_...`, `test_CAM4_...`,
     `test_CAS01_...` or `test_CAR215_...`, and a node test `CA-M7: ...`: CA-H1's and CA-M6's in
     `keeper/test/KeeperExecutor.t.sol`; CA-H2's and CA-M1's in `test/MintRequests.t.sol`, CA-H2's builder half,
     CA-R2-15's and CA-R2-16's in `test/BasketBuilder.t.sol`; CA-S01's in `test/WeightedHub.t.sol`, CA-S02's in
     `test/WeightedHub.rebalance.t.sol` and `test/WeightedHub.states.t.sol`; CA-H2's and CA-M1's on mainnet
     Tether in `test/fork/Security.fork.t.sol` (`test_CAH2_CAM1_...`, `test_CAH2_...`); CA-M4's in `test/Scripts.t.sol`;
     CA-R2-17's and CA-R2-18's in `test/CheckToken.t.sol`; the bot's, the restock's and the checker's in
     `keeper/test/unit/`, with their mutants C1 to C42 (C43 to C51 went with the non-EVM signers,
     and CA-M14, CA-R2-12, CA-R2-13, CA-L7 and CA-L8 with them). The record's "Status of the fixes" names every test, the
     ids fixed by documentation alone, the ones left as they are, and the wiring fixes that have no unit suite
     (CA-M8, CA-R2-04, CA-R2-11, CA-R2-20, CA-L12).
   - The two attack replays: `HK-1`..`HK-20` (`audits/internal/attack-replay.md`) and
     `HK-21`..`HK-26` (`audits/internal/attack-replay-ii.md`, its tests in `test/UniversalRouterSwaps.venues.t.sol`,
     `test/Attacks.t.sol`, `test/WeightedHub.oracle.t.sol` (HK-25) and, for HK-22, `testFork_HK22_...` in the BNB
     Chain and Base suites, its mutants HK8 to HK12), a test named
     `test_HK01_...` in `test/Attacks.t.sol`, HK-1's in `keeper/test/KeeperExecutor.attacks.t.sol`, and node tests
     named `HK-01: ...` in `keeper/test/unit/executor-source.test.mjs`, with their mutants HK1 to HK7. Only HK-16
     was a finding; the rest are replays that found nothing, kept as regression tests. HK-7, HK-11, HK-17, HK-19
     and HK-20 are replayed by earlier suites' tests, which the record names, and HK-18 does not apply.
   - The skills audit: `A7-08`, `A7-12`, `A7-13`, `A7-17`, `A7-18`, `A7-22`, `A1a-05` and `A1a-06`, the
     eight of its findings that reached `main`, all fixed (`audits/internal/skills-audit-a7.md`), a
     test named `test_A708_...` or `test_A1a05_...`. The record's status table names every test.
   - Stage B's families are retired in full with Stage B (`audits/retired/stage-b.md`): the Stage B red
     team's `VLT`, `HUB`, `MOD`, `BNB`, `FAC` and `SOL` ids, the TRON review's `TRN`, the logic review of Stage B's
     `LG`, and `BLS-1`. No test carries them, and none may be restored.
   - The swap-venue review's `SV` ids (`audits/internal/swap-venues-review-sv.md`) are retired in full:
     SV-I3 and SV-I4 with THORChain (`audits/retired/thorchain.md`), SV-1, SV-I1 and SV-I2 with
     PancakeSwap (`audits/retired/pancakeswap-zap-venue.md`). No test carries them, and none may be restored.

   Find a test by its id. Most v1 and R tests are in `test/Security.t.sol` and `test/fork/Security.fork.t.sol`, on
   `WeightedHub` indexes. The hub and factory ids `audits/retired/v4.md` re-targets are in the weighted
   suites (`test/WeightedHub.t.sol`, `test/WeightedHub.rebalance.t.sol`, `test/WeightedIndexFactory.t.sol`), the R
   tests that drive the auction directly (R04, R08, R10, R11, R14 to R16, R21) among them. Some ids no contract test
   can reach:
   - L06 and FR06 are `test_L06_checkOwner` and `test_FR06_checkGuardian`, in `test/Scripts.t.sol`, with the other
     deploy-script ids (XA-07, XA-25, XA-38, XA-39, XA-47, SA-06, CR-I36, CR-I37, A7-08) and RT-25; FR05 is
     `test_FR05_*` and A7-22 `test_A722_*`, in `test/ConfigureWeighted.t.sol`.
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

   Ten records list the ids whose mechanism is gone, with the test that went and the property, if any, that survives:
   - `audits/retired/v3.md`: the move from Uniswap V3 prices to Chainlink.
   - `audits/retired/v4-stage-a.md`: Stage A's removal of every price. It retires 31 tested ids in full,
     retires CR-I36, CR-L08 and VR-06 in part, and names the test of every re-targeted id.
   - `audits/retired/v4.md`: the deletion of v4's market-cap hub and factory for v5. It retires 13 tested
     ids in full (the band's and the supply batches'), retires LR-04, LR-05 and RT-15 in part, and names the v5 test
     of every re-targeted id. A second section retires six more with `ConfigureWhitelist`, CR-M01 among them.
   - `audits/retired/stage-b.md`: the deletion of Stage B. It retires 31 ids with a Solidity test in
     full, the Rust and Move tests of the vault chains with them, V5R-I1, and RT-24 in part.
   - `audits/retired/thorchain.md`: the removal of the THORChain planner. It retires CF-2 and CF-8, whose
     node tests went with it, and SV-I3 and SV-I4, recorded by documentation.
   - `audits/retired/pancakeswap-zap-venue.md`: the removal of the zap's PancakeSwap legs. It retires SV-1, whose
     unit and fork tests went with them, and SV-I1 and SV-I2, recorded by documentation.
   - `audits/retired/oracle.md`: the removal of Pyth for the oracle-free rebalance. It retires V5-L1,
     V5-M1, V5R-1, DA-01, RB-3, RX-3, RX-18, RX-27, AU-2 and RZ-26 in full, and names the test of every re-targeted id
     (V5-I4, V5-M2, V5-L2, RX-15, R04, R14, R08 and their neighbours).
   - `audits/retired/zap-ether.md`: the withdrawal of the zap's ether entry points. It retires none in
     full, and RY-1 in part.
   - `audits/retired/pyth-check.md`: Pyth's check on a fill. It retires V5-I4, which forbade naming Pyth.
   - `audits/retired/non-evm-restock.md`: the deletion of the restock's Solana, Sui, Aptos and Algorand
     signers and of the Wormhole copies off the list. It retires PD-1 to PD-8, PD-11, PD-13, CA-M14, CA-R2-12,
     CA-R2-13, CA-L7 and CA-L8.

   The ids tested at `v3.0.0`, less those tested at Stage A, are exactly the ids the Stage A record retires in full;
   the ids tested at `8e6148b`, less those tested at `4f40b67`, the v4 record's first section; those at `22d532a`,
   less those tested after it, its second; those at `04e936b`, less those tested after it, the Stage B record's; and
   those at `922da1d`, less those tested after the oracle-free rebalance, the oracle record's ten. A
   change that removes an id's last test adds its row to a retirement record in the same commit. Do not restore a
   retired id's test against the new design; if the property matters here, it gets a new id from the review of this
   surface.

CI enforces items 1 to 5, Aderyn aside: fmt, build, `forge lint -D notes`, tests, 100% coverage on every file and
`wake detect all src`. It also fails on a committed file that names a path on its author's machine. The fork suites run
on every push from this repository, because the test step passes the `MAINNET_RPC_URL` secret unconditionally. On `main`
and on pull requests into it the secret is also required, so a missing one fails the run rather than letting the suites
skip. Check a run's test summary rather than assuming. Run everything locally before pushing. A pull request from a
forked repository gets no secrets, so its fork suites skip, and a maintainer re-runs them before merging.

## Layout

`ls` and each file's header comments show what lives where, and README.md's Repository structure gives the tour. Three things
the tree does not say: `solana/` is the Solana program, an Anchor workspace of its own that shares no code with `src/`
and that CI does not build yet; `script/testnet/` (the Sepolia test market) never deploys to a mainnet; and `keeper/` is the keeper bot with its executor contract, a Foundry project of
its own with its own tests (`keeper/README.md`): it starts and fills auctions, fills `MintRequests` requests at their
limits, serves coins without a Uniswap route from the executor's stock, and holds no role in the
protocol. Anyone may run one; its key is the keeper's own hot key, never
the owner's or the guardian's. Its restock service (`keeper/restock.mjs`, `keeper/restock/`) runs beside it with the
treasury's key, also never the owner's or the guardian's. Its invariant checker (`keeper/invariants.mjs`,
`keeper/invariants/`) holds no key: it reads every index, `MintRequests`
and the basket builder each round and reports any property that does not hold, the hub's invariant on the recorded
units and scale it reads from storage (`HUB_STATE_SLOTS`, pinned by `test_theCheckersHubSlotsAreTheHubs`) among them.

Deleted as unused, and recoverable from git at `f83dcab`: the v4 hackathon demo (`demo/`), the reviews'
PoC tests (`audit/poc/`, which the audit records still cite), v4's market-cap analysis scripts (`design/analysis/`), the
v4 architecture PDF with its builder (`design/build_pdf.py`), the BNB Chain deployment (`script/BnbChainAddresses.sol`,
its list and fork suite), and the design records of retired designs and research (v4's hybrid architecture, Stage B's
spec and interfaces, Stage C, the chain and L2 research, the hackathon plan, the two-chain decision), which the audit
records also cite. Deleted for the same reason, and recoverable from git at `922da1d`: the probes of the
RY and RZ red teams (`audit/poc/`, which their records cite) and the source of the flow video (`docs/video/`).

## Design rules that must not be broken

- **A price can only refuse.** One contract reads a price, `PythPrices`, and only two things ask it: a rebalance fill
  and a creation (`docs/design/pyth-check.md`). No issue,
  redeem or claim reads one (`test_exitsAndMintsReadNoPrice`, `test_A713_noContractReadsAPrice`,
  `test_onlyThePriceReaderReadsPyth`), so no feed can block an exit or misprice a mint. A fill must pass the units'
  check first and the price's check after it: at Pyth's prices it brings in at least what it takes out, less a
  tolerance from nothing at the auction's start to `MAX_ORACLE_TOLERANCE`, 2%, at its end (`WeightedMath.oracleCheck`,
  `BelowOracleValue`), each price no older than `MAX_PRICE_AGE`, fifteen seconds, and leaning against the executor by
  its confidence; a creation's check reads prices of the last minute (`MAX_CREATION_PRICE_AGE`). The executor picks
  which price a fill reads: it posts Pyth's update itself, so of the prices Pyth signed in the last fifteen seconds
  and newer than the one stored, it reads the one that suits it, and the tolerance is counted at that price. Say so
  wherever the tolerance is described (HK-25). So a price that is wrong, stale, missing or hostile, Pyth's keys included, can stop a fill as a cancel can and never pass
  one the units refuse (`test_aWrongPriceCannotPassAFillTheUnitsRefuse`). Keep it that way: never let a price accept
  what the bar refuses, replace the bar, or reach an issue, a redeem or a claim. A token's feed is the owner's to set
  behind `LISTING_DELAY` (`proposePriceFeed`); a token with none stops a fill that moves it (`NoPriceFeed`). The id
  is not asked of Pyth's contract, which knows a feed on a chain only once someone has posted an update of it there,
  as BNB Chain's Pyth has not for most of the feeds its list needs, ZEC's and most Ondo stocks'.
  `script/PriceFeeds.sol`'s table and its tests are the check, and a wrong id can only refuse. Ondo's
  tokens are priced at their share's Pyth price times the sValue Ondo's oracle holds for them, save the nine Pyth prices
  as tokens (`FeedKind.SharesOracle`, `docs/design/ondo-svalue.md`): only a settled sValue counts, so from the moment
  Ondo schedules a corporate action until twenty minutes after its sValue lands, a fill that moves such a leg, and a
  creation that holds it, waits (`SValueUnavailable`). Keep the settle rule: Ondo writes a split's sValue by hand, at a
  moment Pyth's share price need not match. Pyth is a pull oracle: every fill needs an update from the last fifteen seconds, which the keeper
  buys from Hermes. Valuing an index for display is still the app's job, off chain. The zap swaps, but reads no price: it
  enforces the limits its caller sets.
- **A quote can only refuse.** The one place a price enters a contract is the quote the owner or guardian may post
  with a start (`startRebalance(keepMask, prices, tolerance)`, after Reserve's price ranges): prices of the caller's own, fixed at the start, never read from anywhere. A fill of that proposal must
  clear the bar as any fill and must also bring in, at those prices, at least `1 − tolerance` of what it takes out
  (`WeightedMath.quoteCheck`, `BelowQuote`). Both checks must pass, so a quote that is wrong, stale or hostile can
  stop its own proposal from filling, which a cancel already can; it can make no fill worse than a start
  without one allows. Keep it that way: never let a quote accept a fill the bar refuses, replace the bar, outlive
  its proposal (mutant Q2), or reach an issue, a redeem or a claim. What it buys: a lone executor keeps at most the
  tolerance of what it trades, not the index's distance from its weights. That is counted at the quote's prices,
  which are fixed at the start: after the market moves, an accepted fill can cost the index the tolerance and that
  move on top, never more than the bar allows. Say so wherever the tolerance is described (CA-M5). Its limits: a stranger's start carries
  none, so the guardian replaces such a proposal within its six hours; the tolerance has to cover six hours of
  market, or the proposal expires unfilled (the spec's section 10); and one thing it can do that a cancel cannot: a
  quote that refuses every trade worth making still passes a fill that shrinks no leg, so the role that posted it
  can settle a sliver and restart the index's whole interval, up to 91 days, for strangers; the owner or the
  guardian may start again a week later (RW-3).
- **The executor names the units, and the index checks a gain.** `executeRebalance(newUnits, data)` settles at the
  units its caller names. `WeightedMath` accepts them when every leg is inside its unit caps and
  `⌊Σ w_i · L(x_i) / 10,000⌋ ≥ bar`, with `x_i` the leg's relative change in units, rounded down, and
  `L(x) = x − x²/2 + x³/3 − 3x⁴/10`, rounded down. `L(x) ≤ ln(1 + x)` on `[−0.2, 1]`, so an accepted fill never
  lowers the weighted product of the units, and at any prices the index is worth at least `e^(bar − D)` times what
  it was, `D` its distance from its weights at those prices (`docs/design/rebalance.md`, section
  3). Do not replace `L` by anything that can exceed the logarithm on the capped range, nor widen the caps past the
  range the lemma covers: the margin at `x = −0.2` is three millionths. `L` is not the logarithm, so the fill that
  scores highest is close to the one that puts the index on its weights, not exactly it: do not write that it is
  (CA-S07). The keeper names its units on `L` itself, by its slope, for the same reason (CA-M7).
- **The bar is on the whole index's gain.** It starts at `BAR_MAX` (a half), halves every `BAR_HALF_LIFE` (12
  minutes) along a straight line, rounds up, and never reaches zero. Do not turn it into a premium on the traded
  amount: with the executor choosing the trade, a premium is won by the smallest trade, and the index would never
  rebalance. A fill that changes nothing has no gain, so none can restart the rebalance interval for free (V5-L2).
- **A fair price needs a bidder; the price check caps what a lone one keeps.** Executors compete by filling earlier,
  at a higher bar and a smaller tolerance. With an honest one bidding, ours first, holders lose only its costs. On
  units alone a lone executor at the last second would take the index's distance from its weights: 0.48% of an index
  after one coin of four rose a quarter, 5.0% after one coin of two doubled, 8.7% after it tripled (the spec's
  Theorem 2, on the exact model). Under Pyth's check it keeps at most the tolerance of what it trades, measured at
  Pyth's prices: up to 2% at the last second, an Ondo leg counted at its share's price times its settled sValue.
  Say so wherever
  the design is described: do not call a lone executor harmless, and do not claim the price is fair without a bidder.
- **An index is created on its weights, and only approved wallets create.** A creator names each component's units
  and weight; on units alone one that named units far from the weights could let others mint and fill its own
  auction at the last second: 15.5% of a 50/50 index created 90/10 by value in one fill. So
  `createIndex`, on a factory with an oracle, values every leg's units at Pyth's prices and refuses a leg whose share
  of value lies more than `MAX_WEIGHT_DEVIATION`, 5%, from its weight, relative to it (`OffWeights`;
  `test_anIndexIsCreatedOnItsWeights`): an index starts about a thousandth of its value or less from its weights, and
  the fill check bounds what any later distance yields. The creator posts Pyth's update first. The gate stays:
  `createIndex` is open only to wallets the owner approved; do not reopen creation without
  the owner's call. A factory without an oracle (Sepolia, tests) checks no weights at creation.
- **A creation may carry the index's first issue, and it is an issue like any other.** `createAndIssue` has the new
  index issue its first shares inside its initializer (`FirstIssue`): the same `_issue`, under the same guard, with
  every check an issue runs (the gate, the fee, each component's arrival, RX-8's backing, RW-8's probe), and a check
  it fails reverts the creation, so no index is left that its own creator could not back. One thing differs: the
  payer is the account the factory names, its own caller, since the factory is the hub's caller. That is the only
  time the hub pulls from an account other than `msg.sender`, and what makes it safe is two lines: only the factory
  calls `initialize`, once per clone, and the factory names `msg.sender` (mutants FB1 and FB5). The creator approves
  the address before it exists; only this factory can deploy there and only for that creator, since the salt names
  it (`test_theFirstIssuePullsFromItsCreatorAlone`). The initializer is `nonReentrant`: an index reads as
  initialized while its initializer runs, so without the guard a component that calls back could issue or redeem
  in the middle of the first issue (FB3). The factory still calls no token. Do not add a standing way for the
  factory, or anyone, to have the hub pull from a named account.
- **Constituents are fixed at creation; weights change only behind a notice.** Two to two hundred components, so no
  listing or delisting reaches an existing index. The CREATE2 salt commits to every component's token, units and
  weight, and to the index's config: its fee rates, referral share and rebalance interval
  (LR-05: never switch back to CREATE), so an index's address names the weights it was created with.
  The index's creator may propose new weights for the coins it holds (`proposeWeights`,
  `docs/design/changeable-weights.md`), each at least one basis point and summing to `TOTAL_WEIGHT`;
  anyone applies them from `WEIGHTS_DELAY`, 7 days, after the proposal to `PROPOSAL_WINDOW` after that
  (`executeWeights`), and the creator, the owner or the guardian cancels one (`cancelWeights`). A proposal replaces
  the one pending. Only a factory with an oracle takes one (`NoOracle`): a change opens a distance between the units
  and the weights, which on units alone the creator could take through its own auction, and Pyth's check bounds to
  its tolerance per fill. No change applies during a live rebalance (`RebalancePending`), and only the factory writes
  the hub's weights (`setWeights`, `NotFactory`). Nothing moves at the change: the next rebalance moves the units,
  under the bar and the caps, a leg at most a fifth down and double up per fill. Do not allow a weight of zero (such
  a leg earns nothing in the units' check, so only a price would guard it, against "A price can only refuse"), nor a
  coin the index does not hold (the owner's refusal: its entry could be judged only at a price). The gate and the listing flag are not terms of the index and not in the salt.
  A component starts with at least `MIN_RAW_UNITS` and at most `maxUnitsOf(token)`: `MAX_WHOLE_TOKENS` (1e9) whole
  tokens per share, never above `MAX_UNITS`, so a wei-share backs a negligible amount and no fee's rounding to whole
  wei-shares is worth anything (RX-5).
- **The caps count units, never value.** A fill leaves a component with at least `1 − MAX_TURNOVER` (four fifths)
  of its own units, rounded up, and at most `1 + MAX_GROWTH` (twice) of them, whatever the executor offers. So a coin
  anyone can mint for nothing draws a bounded share of the other legs per fill (a 10% coin, at most 5.8% of the
  rest), and nothing a market does widens a cap (V5-M2, RX-15). A kept leg keeps its units exactly.
- **The settlement's rounding.** Every rounding goes against the executor: a leg's change and its score round down
  (toward minus infinity), the gain rounds down, the bar and the lower cap round up, an amount rounds down when it
  leaves and up when it comes back. The mutants worth rerunning are committed (`test/mutants/mutants.json`, V1 to
  V24 and the hub's H): each rounding flipped, each cap dropped, the bar's rounding, start and half-life, the
  score's terms, the empty supply, and the backing post-check's (the claims dropped from the backing term, only the
  bought legs re-read, a shrinking leg paid as a difference of floored backings). The settlement vectors
  (`test/WeightedMath.vectors.t.sol`) kill the arithmetic's; run them again after any change to `WeightedMath`.
- **An index under one whole share does not rebalance.** Below `SHARE_UNIT` of supply a fill reverts
  `NothingToRebalance`, and the preview with it, so nobody moves an empty or a dust index's units for nothing (R14,
  XA-27, RW-1). A fill's gain reads the units alone while its amounts scale with the supply, so on a few raw
  shares every amount going out floored to zero, and a fill that doubled a leg cost one raw unit. The line is one
  share because the factory sizes its unit bounds per whole share. What is left is a known limitation: whoever
  holds an index's whole supply, a share or more, pays every fill to itself and can still walk the units over
  several intervals, its own basket locked in the index, since no contract reads a price. The app answers by
  showing an index's coins against its weights, and `MintRequests` by filling a request only at the basket it was
  made on (RW-2). Do not lower the line: a fill's cost falls with it.
- **A collapsing coin is still bought.** Fixed weights keep buying it, at most doubling its units per fill (RX-15),
  and units beyond `uint96` stop the fill rather than wrap, the preview with it (RX-61), until the guardian keeps it
  (V5-L3, a known limitation).
- **An issuer's corporate action is not accounted for.** Units are fixed per share and amounts come only from supply
  and units, so tokens an issuer mints to holders, as a split paid in tokens would be, stay in the index owned by no
  share, and a burn leaves that leg below its backing; a token that stops being one share misprices a leg priced at the
  share's feed (CF-3, a known limitation), which is why an Ondo leg is valued at its sValue in Pyth's check. Do not add a path that pays out balances to cover it. What the hub does
  check: issue refuses while a leg's balance is below the backing of the shares already issued plus its open claims, as
  after an issuer burned the index's balance, so no new deposit refills the hole for earlier holders (RX-8); and a fill
  that grows a leg must leave the index able to send that leg, measured by sending itself one raw unit, so a token that
  blocks only its sender, as Tether Gold's does, cannot have good legs moved into a leg nobody can take out (RX-12).
  An issue makes the same probe on every leg it pulls (`_checkCanSendOut`, RW-8, once the app's alone, RZ-25): a deposit into a leg the index can no longer send reverts `CannotSendOut` instead of becoming
  a claim nobody can pay. So a token that refuses a transfer to oneself, or charges for one, can be neither bought
  by a fill nor issued. After a burn the index still pays amounts: redeems and claims on that leg are paid in full,
  first come, first served, until what is left runs out, and no part of it is set aside for the claims recorded
  before the burn (CA-M3, a known limitation: sharing a loss out would need a share of a balance). A claim larger
  than what is left is collected in part (`claim(token, to, amount)`, CA-S01).
- **The notice is 2 hours.** `WeightedHub`'s `REBALANCE_DELAY` is 2 hours: the notice is for executors, not for
  holders' exits. `AUCTION_DURATION` is 4 hours, the bar's twenty halvings; the math's must equal the hub's
  (`test_theMathConstantsAreTheHubs`). The
  rebalance interval is the index's own, chosen at creation within [`MIN_REBALANCE_INTERVAL`, `MAX_REBALANCE_INTERVAL`]
  = [7, 91] days (the website's weekly to quarterly cadences; V5R-I2 set the floor). A fill with a keep mask restarts
  only `MIN_REBALANCE_INTERVAL`, for any start (`earliestRebalance()`, XS-3): a guardian's sliver behind a mask cannot
  hold the index off for a quarter, and a keep can be renewed a week on. The owner or guardian may
  also start `MIN_REBALANCE_INTERVAL` after any fill, with or without a mask, while a stranger waits out the
  index's interval (`test_theOwnerOrGuardianRestartsAWeekAfterAnyFill`, RW-3, mutants RS1 to RS3): a fill restarts
  the whole interval however little it traded, so a sliver at an auction's last second, or one under a quote that
  refuses every real trade, held an index off its weights for up to 91 days with nobody able to reopen it. Do not
  give that start to strangers or to the creator: for them the interval is the index's cadence.
  The cost, accepted: the owner or
  guardian can start a rebalance weekly on a quarterly index once it has had a fill, with a mask or without, each
  fill within the unit caps and above the bar; a hostile one can so settle a sliver every week and keep strangers'
  clock from running out, which is its stall by another road, ended as the cancel's is, by the owner replacing it.
  Before an index's first fill nobody starts early (mutant RS4). A cancel, or an auction that
  expired unfilled, holds strangers off for `REBALANCE_DELAY`, so the owner and guardian get the first restart;
  `canStartRebalance` answers whether strangers may, and false for a clone that was never initialized (DA-22; CR-I02
  for the second after an expiry).
- **Value-bearing amounts are in-kind.** The hub only ever moves amounts derived from supply and units: issue, redeem,
  claims and rebalance settlements. Never compute an amount from balances (balances only verify), and never add a
  share price to the hub. `_backing(shares, units, scale, rounding)` is the one place that turns shares and units
  into an amount. No share can be sent to the index itself or its factory: `_update` refuses both (CR-I01, RT-21).
- **Fees are shares, never components** (`docs/design/fees-builder-requests.md`, section 5.6). An index charges its creator's rate
  (0 to `MAX_CREATOR_FEE_BPS`, 100, the creator's choice) plus the platform's (0 to `MAX_PLATFORM_FEE_BPS`, 25, the
  factory's policy when the index was created) on every issue and every redeem, in basis points of the shares. A
  minter's deposit backs the fee's shares on top of its own (`previewIssue` sizes for the gross, rounded up); a burner's
  fee is minted to the recipients out of the shares it burns and it is paid the net backing, rounded down. Every share
  stays backed by the deposit that minted it, so the invariant is untouched. The recipients come from the factory at
  each call (`feeTerms`): the index's creator (`creatorOf`, which the creator can offer on and the new creator must
  accept, RX-22) and the platform recipient;
  a referrer named at mint takes `referralShareBps` of the platform's part, so a self-referral discounts only the
  platform's (RY-3, RW-4: open, the fee policy's question). Only an issue and a redeem charge these: a fill that
  grows every leg adds to the index for no entry fee and passes no gate, which is worth doing only to a holder of
  nearly the whole supply, since the rest is shared with the others (RW-5, recorded).
  A recipient that could not hold shares is replaced (the creator by the call's `to`, the platform's part
  folded into the creator's), so no recipient can block a mint or an exit. Rates are fixed per index; the policy
  reaches only later indexes, and a creator names the highest platform fee it accepts (`PlatformFeeTooHigh`). The
  creation fee, in ether, is forwarded whole in the same call.
- **A streaming fee is a unit scale** (the record's option B). An index charges its creator's yearly
  rate (0 to `MAX_CREATOR_STREAMING_BPS`, 500, the creator's choice) plus the platform's (0 to
  `MAX_PLATFORM_STREAMING_BPS`, 100, the policy when the index was created; a creator names the highest it accepts,
  `PlatformStreamingFeeTooHigh`), in basis points of the index's value per year, and in shares: every issue, redeem,
  settlement and `accrueFees` first mints the fee accrued since the last accrual, `supply · f / (1 − f)` shares for
  `f` the rate times the elapsed part of a year, split by the two rates and never to a referrer, and lowers `_scale`,
  the factor every share's recorded units carry, by `supply / (supply + minted)`; both round down, so the invariant
  holds and the dust stays with the holders. Nothing moves: the fee is ownership. `_backing(shares, units, scale,
  rounding)` is `shares · units · scale / 1e36`, and the previews and `components()` report at the scale an accrual
  now would leave (`pendingStreamingFee`). A settlement works on the recorded units, moves each leg's backing at the
  scale (`IWeightedMath.settlement` takes it), and writes units that carry the scale as the old ones did; no settlement
  resets the scale, since folding it in floored every leg and stranded up to `supply / 1e18` raw units of each, kept
  legs included, at every fill (XS-2). Do not bring the fold back. The scale therefore only shrinks, and an accrual
  that would shrink it to zero is not charged. Every accrual restarts the clock (`lastAccrual()`), one that mints
  nothing included: a clock kept on a supply too small for one share of fee charged the whole idle time to the next
  minter's deposit (XS-1); what the restart forgoes is under one share per call. A gap long enough for `f` to reach
  one is capped just under it, so the arithmetic answers and the last holder can leave.
  The creator is read at each accrual, so `acceptCreator` accrues the index before it writes the new one: what the
  role earned up to the handover goes to the creator who held it (RW-6). A change of the platform's recipient
  accrues nothing first, both recipients being the platform's.
  The scale pushed the settlement arithmetic out of the hub's EIP-170 budget into `WeightedMath`, a stateless contract
  the hub calls by STATICCALL (`MATH`); its constants are the hub's (`test_theMathConstantsAreTheHubs`), and the
  optimizer runs are 100 for the same reason. It is deployed on its own and the factory takes its
  address at construction (`NotAContract` for an address without code), since the factory's init code, which
  carries the hub's, passed EIP-3860's 49,152 bytes with the weights change; `DeployWeighted` deploys it first and
  checks its code hash.
- **A gated index issues only to its creator and allowed recipients.** The factory keeps the gate (`isGated`) and the
  allowlist (`isAllowedMinter`), both the creator's; the creator mints without an entry, a right that moves with the
  role (`test_theCreatorMintsItsOwnGatedIndex`); the creator can open the gate for good (`openMinting`), never close it.
  The minter names the referrer, so the gate holds for it too: a referrer the gate would refuse as `to` is named
  nobody and the platform keeps its part (AU-1). The platform recipient takes its fee shares whatever the gate.
  Transfers and burns never read the gate, so the token stays an ERC-20 the zap and `MintRequests` can handle. The
  creator has one other power, a change of weights behind a notice of 7 days (above), and none over components, rates,
  or anyone's shares. A pending change of weights goes with the role: `acceptCreator` cancels it, so no creator's
  proposal takes effect under the next (HK-16).
- **Invariant:** for every component `i`,
  `token_i.balanceOf(index) >= floor(totalSupply * units_i * scale / 1e36) + totalClaims[token_i]`, with `scale` the
  streaming fee's factor (1e18 until a fee accrues). Rounding always goes the
  holders' way: issue rounds up and redeem rounds down; new units round up (DA-01); a claim is recorded only for an
  amount that stayed in the index; a rebalance moves each leg's change in required backing, rounded down when it
  leaves and up when it comes back, so an executor never collects rounding dust (SA-07). The rebalance post-check is the
  invariant with the new units, plus the whole of `amountsIn` on top of what the index held, so surplus from rounding
  or a donation stays with the holders. The invariant suite enforces this; keep it passing.
- **Holders can always leave.** `redeemSkipping` must keep working when any subset of components is frozen, claims must
  be payable once transfers resume, and neither the notice nor the auction ever freezes issue or redeem. A claim is
  booked to `to`, who receives every other component of that redemption, and `ClaimRecorded` names `to`, so a router
  redeeming on a holder's behalf does not strand the skipped components (DA-17). A claim is collected whole
  (`claim(token, to)`) or in part (`claim(token, to, amount)`, CA-S01), so what an issuer's burn left of a component
  can still be taken. There is no speed limit and no cap on a burn anywhere: a holder burns any amount at any
  time. The pause of minting (below) is read by an issue alone, so it stops no exit.
- **No admin power over funds, no rebalancing key.**
  - The factory owner proposes listings (behind `LISTING_DELAY`, 2 days) and guardian changes (behind
    `GUARDIAN_DELAY`, 7 days). Anyone can execute a proposal, but only within `PROPOSAL_WINDOW` (7 days) after its
    delay. The owner also delists, transfers ownership, and sets the fee policy (`setFeePolicy`: the platform's rate,
    the referral share, the recipient, the creation fee), which reaches only indexes created afterwards; the recipient
    can be neither zero, the factory nor an index.
  - The owner approves which wallets may create an index (`setApprovedCreator`, at once); `createIndex` from any
    other reverts `CreatorNotApproved`. The approval is read at creation and nowhere else: an approved wallet is
    bound by the whitelist and the fee caps, it has no power over an index's funds, and withdrawing an approval
    reaches no index that exists. The creator role of an index still moves to any account, approved or not
    (`test_theCreatorRoleMovesToAnAccountThatWasNeverApproved`). Do not let the approval gate an issue, a redeem, a
    rebalance or the handoff.
  - The guardian can: cancel pending listings; delist; cancel a rebalance; start one with a keep mask; start one before
    strangers may; cancel a pending change of an index's weights, as the owner can; and cancel a guardian change that
    would remove the role. It cannot block its own replacement.
  - A Safe cancels a rebalance by its id. `cancelRebalance(proposalId)` reverts `StaleProposal` unless the index's
    latest proposal is still that one; `cancelRebalance()` cancels whichever is pending when it lands. A Safe's
    transaction lands hours after it is signed, when the other role may have replaced the proposal its signers read
    with a start of its own, which a plain cancel then removed (CA-S02). The runbook's batches use the bound one.
  - The guardian is the guardian's Safe itself: a start is a plain call, which a Safe lands as any transaction. The
    guardian relay of the Pyth-priced build (RZ-26) is deleted.
  - There is no pause of an exit, no upgrade, no sweep, no renounce, no instant guardian change, and no keeper or bot
    role. Keep it that way.
  - **Minting can be paused, and nothing else.** The owner or guardian stops the
    issue of new shares with the factory's `pauseMinting(index)`, on one index or, with the zero address, on every
    index; only the owner lifts it (`resumeMinting`), each on its own. It is the brake for an index or a build found
    to have a fault, so that no new deposit enters it, and it is the one thing short of an upgrade key the design
    takes: the code of an index stays fixed. It lives in the factory alone: `feeTerms` answers `allowed` false while
    either pause holds, and the hub, which already asks before an issue, reverts `NotAllowedMinter`; the hub's code
    did not change. Only an issue reads `allowed`. A redeem, `redeemSkipping`, a claim, a transfer, a fee accrual
    and a rebalance never do (`test_aPauseStopsIssuesAndNoExitNorARebalance`, mutant MP6): never make any of them
    read it, and never add a pause the hub itself holds. What it costs: a hostile or compromised guardian can stop
    every mint until the owner lifts the pause, and pause again, until the owner replaces it after
    `GUARDIAN_DELAY`; it moves no funds and holders redeem throughout. A creation with a first issue is an issue
    and is stopped with the rest; `createIndex` is not.
  - `cancelRebalance` has no window and no rate limit. A hostile or compromised guardian can cancel each auction at its
    last second and hold rebalancing off while the index drifts from its weights. That stall is bounded by the owner
    replacing the guardian, which takes `GUARDIAN_DELAY` and which the guardian cannot cancel. It moves no funds, and
    holders redeem throughout. A cancel budget was considered and rejected (DA-12). A keep-mask start that leaves only
    a sliver moving can also restart `MIN_REBALANCE_INTERVAL` for everyone (XS-3 made that the bound: before, the
    sliver restarted the index's interval, up to 91 days), so the stall can outlast the guardian's replacement by up
    to `MIN_REBALANCE_INTERVAL`. A start with a quote and no mask stalls the same week and no longer: its sliver
    fill restarts the index's whole interval for strangers, and the owner and the new guardian start again
    `MIN_REBALANCE_INTERVAL` after it (RW-3).
    While a replacement is pending, the owner cancels the outgoing guardian's keep-mask
    starts, and monitors watch `RebalanceStarted` with a non-zero `keepMask` (RT-07). The owner has only
    `REBALANCE_DELAY`, 2 hours, to cancel one before the guardian's own executor can fill it at `eta`, so that cancel
    needs signers on call.
  - An expired proposal leaves `pendingGuardian`, `pendingGuardianEta` and `listingEta` set. The views that say
    whether a proposal is still executable are `guardianChangePending()` and `listingPending(token)` (DA-16).
  - **Listings.** A listing records a token's decimals, read from the token when it is proposed; they bound the
    units an index may start with (`maxUnitsOf`) and scale the token's Pyth price in every check. A relisting reads
    them anew: the bound reaches only indexes created after it, but Pyth's check reads the factory's record at each
    fill, so a relisting's decimals reach every index's check from then on. A live listing excludes a second for the same token (`ListingPending`).
- **Only initialized clones issue, redeem or rebalance.** Keep the `onlyInitialized` guard on every function that mints,
  burns or touches a rebalance.
- **Executors are untrusted.** Tokens and the callback go only to `msg.sender`, every mutating entry point shares the
  reentrancy guard, and state is written before any rebalance transfer. `executeRebalance(newUnits, data)` settles
  the units named at whatever the supply in the settling block requires. The
  `executeRebalance(newUnits, data, maxAmountsIn)` overload bounds that, and
  reverts `RebalanceMovedOn` when the settlement has grown past what the caller will deliver. Issue stays open through
  notice and auction, so a dust issue can grief an executor sized from an off-chain simulation: the callback arguments
  are authoritative (DA-13). At `MAX_COMPONENTS` (200), every path of the hub and the factory fits a transaction under
  EIP-7825's 2^24 gas cap on mock tokens (`test_theMostComponentsFitOneTransaction`): `createIndex` about 10.2M,
  `redeemSkipping` with every component skipped 10.2M, `issue` 8.9M, a fill under a quote 8.8M with an executor that
  holds the tokens, `redeem` 7.5M, and a start with a quote 2.7M. Under Pyth's check
  (`test_theMostComponentsFillUnderPythsCheckInOneTransaction`, on a mock Pyth) `createIndex` costs 13.9M, about 60k
  under five sixths of the cap, and the fill 12.7M; a fill that wide posts Pyth's update in a transaction of its own. Real tokens transfer dearer (an index of 171 of
  Ethereum's listed coins issues in kind for 10.5M and redeems for 7.0M on a fork, which
  `testFork_everyCoinIssuesRebalancesAndRedeems` requires to fit), and swaps for that many legs do not fit, so an
  atomic fill that wide needs an executor that already holds the tokens, or names new units for some legs only.
- **Two hundred is what the contracts carry, with a sixth to spare.** `MAX_COMPONENTS` is bounded by a transaction's
  gas, not by taste. Creation marks each token in transient storage in one pass, 10.2M at 200 (comparing every pair
  would grow with the square of the count: 13.3M at 200, past the cap near 234), and on a factory with an oracle
  values every leg at Pyth's prices, 13.9M at 200, which is what bounds creation. At 500 issue, redeem and the fill each pass the cap too. The gas test lets no path at `MAX_COMPONENTS` pass five sixths of the cap: an index that
  exists must keep an exit that fits a transaction when a token transfers dearer than a mock or gas is repriced, as
  EIP-8037 reprices new storage on Sepolia (measured at commit `20ed37a`, not merged: `redeemSkipping` of
  100 with every component skipped needed a limit of 23.1M there). Do not raise the limit without measuring every
  path again, never past the margin, and never past 256: a keep mask is one word. More than that needs creation,
  issue, redeem and the fill spread over several transactions, which is another design. An index too wide to issue
  with its own real tokens can be created and never minted, so its creator simulates `issue` first.
- **Keep mask.** Only the owner or guardian can pass one. A kept component must keep its units exactly: no fill of
  that rebalance may move it, which is the guardian's answer to a coin being minted without limit. An executor
  needs no mask to leave a component alone: it names that component's current units. Either way `executeRebalance`
  reads `balanceOf` only on a component that sends or receives something, so a component whose `transfer` or
  `balanceOf` reverts, or whose contract no longer answers at all, is skipped (DA-14, RT-01).
- **Leaving.** Once the auction is live, an executor watching the mempool can order its fill ahead of a public redeem
  or guardian cancel. An exit sent then pays that holder's share of the executor's take, like every other holder's, and
  no nonce can undo a haircut that landed first. Shares issued while a rebalance is pending share the haircut of any
  fill that lands after them, however the two are ordered (RT-02).
- **The hub takes no ether.** None of its entry points is payable, a start and both fills included
  (`test_noRebalanceEntryPointTakesEther`): nobody is paid for a price.
- **The zap is stateless and replaceable.** New UX features (aggregators, mixed-venue legs) go in a new or
  extended zap, never in the hub or factory. The app caps a zap basket at about 35 components, which is where 16.78M gas
  runs out. The zap's swaps run through `UniversalRouterSwaps`, the engine it shares with the basket
  builder: the venue, command, payment, spend-bound, unsold-input, V4-route and check rules below are the engine's,
  and the swap errors both raise are declared in `IXindexErrors`.
  - **USDC and USDT only.** A
    mint's `tokenIn` and a burn's `tokenOut` must be the zap's `USDC` or `USDT`, construction arguments
    `DeployWeighted` resolves from the chain's address book, else `NotAStable` before anything moves; the builder's
    buy and sell take the same two. No entry point is payable and the zap has no `receive()`. Do not bring back an
    ether path or a payout in any other token without the owner's call: an app that offers ether swaps it to a
    stablecoin outside the zap. The pass-through leg is then a stablecoin the index holds itself, which no listed
    index does (A7-22), and the rule stays for an index that would.
  - **Permits.** `mintWithTokenPermit` and `burnToTokenWithPermit` try an EIP-2612 permit for the whole amount
    pulled and accept one already submitted; USDT has none. Fiat and other-chain entry stay app-side and undecided.
  - **Venue.** It swaps through Uniswap's Universal Router, pinned to the 2.0.0 deployment, and through the chain's
    own DEX, which the deployment fixes (`LOCAL_DEX`, `docs/design/chain-venues.md`): PancakeSwap's Infinity Universal Router on BNB Chain (its V3 and V2 pools),
    Aero's Metarouter on Base (its CL and basic pools, found in the three factories the deployment pins), none on
    Ethereum. Each leg names exactly one venue: a packed `v3Path`, a hookless `PathKey[] v4Path`, or a `localRoute`
    (a family byte, `0` concentrated or `1` constant-function, then a path of V3's shape whose three bytes are the
    DEX's fee tier, tick spacing, or zero and one for PancakeSwap's pair and Aero's volatile or stable pool), never two
    and never none, else `BadRoute(i)`; the pass-through leg names none. A local route names tokens, never pools: no
    caller can point the engine at a pool that is not the DEX's. Every rule below holds for every venue: the
    Metarouter, like a Universal Router, spends its own balance when the payer is not the user and returns it in
    the same call. `DeployWeighted` takes the chain's DEX from its address book alone (`pinnedLocalVenue`), and
    `checkDeployment` refuses a zap and a builder that name different ones, or, on a pinned chain, not the book's.
    What it costs, said to the owner: PancakeSwap's Safe can pause its router and its V3 factory's owner sets the
    farm contracts its pools call; Aero's Safe sets its pools' fee and MEV-tax modules and can pause its basic pools.
    Each can make that venue's legs revert or cost more, within the caller's limits; none can take a pre-funded leg.
    Not used: PancakeSwap's Infinity pools and Uniswap V4's hooked pools (hooks), PancakeSwap's StableSwap, and the
    old Aerodrome router, which reaches only the pools Aero's launch is emptying.
  - **Commands.** The zap builds every command and every action itself and forwards nothing a caller supplied. The
    router's command set includes `TRANSFER` and `PERMIT2_TRANSFER_FROM`, which move a payer's funds, so passing
    calldata through would hand a caller the router's permissions.
  - **Payment.** It pays by pre-funding the router and appending `SWEEP` back to itself in the same `execute`, so
    nothing it sent can be left where anyone could take it. There is no Permit2 approval and no allowance to reset.
  - **Spend bound.** The sweep's minimum is zero, so it never fails a call. What bounds a leg's spend is the amount
    pre-funded. That is also the only bound on a V4 exact-output route that revisits `tokenIn`, since the pinned
    periphery does not hold such a route to its `amountInMaximum` (upstream #564; CR-I06, CR-I14).
  - **Unsold input.** The sweep returns the router's whole balance of the token, a stray one included. So what a hop
    brought back is measured as `balance + given - before`, never as what was spent (CR-L02), and the router's
    balance read before the pre-fund tells the stray from the hop's own unsold input (RW-9). The builder credits
    both to the seller's escrow (RX-45). The zap offers both to the recipient in one transfer; if the token refuses
    it, the zap sends the unsold part alone, which is the recipient's and must still arrive, and keeps the stray,
    which nothing can move again. So one raw unit a stranger left in the router no longer reverts the burn of a
    recipient the token will not pay.
  - **One balance, one address.** Every amount is a balance change read at one address. A pre-fund that lowers the
    balance a swap is about to be measured against (a sale hop's output or its leg's `tokenOut`, a buy's component)
    means two addresses write one ledger, and the swap reverts `SharedBalance` (RW-10): measured both ways the same
    tokens counted twice, and the builder paid the difference out of other users' escrows. Two shapes no probe
    sees, which the listing rule excludes: a buy leg with a budget of zero pre-funds nothing, and an index naming
    both addresses of one ledger is credited twice by `BasketBuilder.redeem`.
  - **V4 routes.** A V4 route must be hookless (`hooks == 0` and empty `hookData`). A hookless key cannot carry the
    dynamic-fee flag, so that one equality covers the flag bits too. `address(0)` is allowed only as an intermediate,
    because native ether must never reach the zap through a swap: it has no `receive()`, and takes ether from nobody.
  - **Checks.** The zap must: validate every route's endpoints; honour every leg's limit, including the pass-through
    leg (DA-15); check `expectedNonce`; measure what the user pays and receives as balance changes inside the call,
    never using tokens already in the zap; check each mint leg's delivered component balance against what the index
    needs (`ShortFill`), which is load-bearing, since the pinned periphery does not itself check exact-output delivery.
    A burn sells what the redeem delivered, measured as the zap's balance change, never `previewRedeem`'s figure
    (A1a-05).
  - **Burn legs.** It sells a V3 burn leg one hop at a time and sends every hop's unsold input to the recipient. A V4
    burn leg is a single multi-hop action, because inside one V4 action an intermediate partial fill leaves an unsettled
    credit and the leg reverts atomically. A route that comes back to the component can leave unsold input from a later
    hop too, returned the same way (CR-I07). Unsold `tokenOut` stays in the zap and is paid out.
  - **Never.** It must revert on transfer shortfalls, and never call `redeemSkipping` or `executeRebalance`. With
    `redeemSkipping` the zap receives the basket, so the claim would be booked to the zap and could never be collected.
- **The basket builder is the zap's stateful sibling** (`src/BasketBuilder.sol`, the self-serve path for any size). The legs of a basket too wide for one transaction are bought over several `buy`
  calls into an escrow per caller and token (`escrowOf`), then issued in one `mint`; selling mirrors it: `redeem`
  into the escrow, `sell` the legs over several calls, `withdraw` what has no route, and `deposit` what has none to
  begin with. It has no owner, no upgrade and nothing to configure; a token in an escrow moves only on its owner's
  call; every amount is measured where it lands (a deposit and a redeem credit the balance increase, a buy what the
  engine measured delivered, a sale debits what it gave the router and credits back what the sweep returned), so the
  builder's balance of every token covers the escrows. A buy is sized by `previewIssue` at the call less the escrow, a
  stale quote reverts `StaleRebalanceNonce`, and a leg a rebalance left short is named by `InsufficientEscrow` for one
  more buy. The pass-through legs honour their limits (DA-15), the recipients are checked as the zap's (RT-21), and
  the builder never calls `redeemSkipping` or `executeRebalance` either. The widest basket, 200 legs, fits six buys
  and one mint under EIP-7825 (`test_theWidestBasketFitsInSixBuysAndAMint`, on mock pools).
  - **The escrows' total.** `totalEscrow[token]` is the sum of every user's escrow of a token, moved with each
    credit and debit. Only the token's issuer can put the builder's balance under it, by taking part of the
    balance. While it is under, a deposit, a bought leg or a redeemed leg of that token reverts `Underbacked`, so a
    newcomer's coins never pay an earlier escrow (CA-H2, RX-8's rule); what is left still leaves by withdrawal, sale
    or mint, first come, first served. A leg that is the paying stablecoin itself is checked again once the buy's
    refund has left, since the call's unspent stablecoin hid a shortfall from the check made at the credit. A
    sale's unsold input goes back to the escrow it left in the same call with no check. A withdrawal or a sale is
    never paid to the paid token itself (CA-R2-15), and a deposit that delivered nothing reverts (CA-R2-16).
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
  - A request fills only at the basket it was made on. It records the index's `rebalanceNonce`, and a fill reverts
    `StaleRebalanceNonce` once the index has settled a rebalance, for both kinds: a limit in shares set before a
    settlement buys another basket, and the filler of a redeem request would pay for shares the settlement
    re-denominated (RW-2). `cancel` and `refund` read no nonce, so a stale request's escrow always comes back.
  - A filler may name the request it priced. `fill(id, amount, expected)` reverts `RequestChanged` unless
    `keccak256(abi.encode(request))` is `expected`; `requestHash(id)` reports it, and it leaves the id out, so it
    follows a request a re-org renumbered. A filler hashes the request it priced: calling `requestHash` at fill
    time proves nothing. `fill(id, amount)` stays for a caller that reads the request in the same call, as the
    keeper's executor does (RW-7). Reading it there binds nothing by itself: the executor compares what it read
    with the hash its keeper priced, for a single fill and, folded in order, for a batch (CA-M6).
  - A requester may name the basket it priced. `requestMint(..., expectedNonce)` and
    `requestRedeem(..., expectedNonce)` revert `StaleRebalanceNonce` when the index has settled since the limit was
    set, before anything is escrowed; a request otherwise records whatever nonce the index reads when it lands,
    and its own fill check then lets it fill (CA-M1). The unbound two stay; the app uses the bound ones.
  - No request is taken into an uncovered escrow. `totalEscrow[token]` is the sum of the open escrows in a token,
    and a request reverts `Underbacked` while the contract holds less: after an issuer destroyed part of the
    balance, the deposit would pay the cancels and refunds of the requests whose own escrow is gone (CA-H2,
    RX-8's rule). Nothing but the issuer can lower the balance under the total, and only making the balance whole,
    by anyone, reopens that token. The requests the burn caught are refunded whole or not at all: do not add a
    partial refund without deciding who bears the rest.
  - The invariant suite holds the contract's balance of each token at exactly its open escrows plus donations, and
    `totalEscrow` at exactly its open escrows, under any interleaving with Tether's fee switch.
- **Checks-effects-interactions.** Emit events and write state before external calls where the data is available; make
  the call into a user-supplied address the last interaction when possible.
- **Standard ERC-20s only as components** (whitelist policy). `issue` rejects fee-on-transfer tokens by checking the
  received amount, and a token that refuses or charges a transfer of one raw unit to oneself by making it (RW-8). A
  token whose ledger two addresses write, a proxy beside a legacy address, is never listed: the engine refuses a swap
  measured across the two, but not an index that names both (RW-10).
  Do not whitelist USDC/USDT as components in scripts or docs; they are fine as mint/burn currencies.
  `ConfigureWeighted` refuses the deployment's own, `V5_USDC` and `V5_USDT` off Ethereum, as well as Ethereum's (A7-22).
  The policy wants 6 to 18 decimals, which matter only to display and to the unit cap at creation. The admission check is
  `CheckToken`, and the WBT rule (a token that can both blacklist a holder and destroy its balance is refused) stays its
  default. A blacklist is no bar to listing, by the owner's ruling, which admits Tether Gold, which the rule
  refuses, and Ondo's stock tokens, whose compliance contract and burner role amount to the same power. A token whose
  balances move without a transfer, a rebasing one, is never a component; an Ondo token's balance never moves, and the
  shares it tracks carry a multiplier (`sValue`, CF-3). The wide check (`testFork_theWideTokensPassTheCheck_*`, a
  hundred tokens a test) pins Tether Gold as the one refused entry and GALA, whose blocklist sits
  beside a `burnFrom`, as the one for review (CF-4). SAND, whose two admins' operators move any holder's balance, and
  RLB, whose code is unverified, are off the list after the source reading
  (`docs/design/token-source-reading.md`); `testFork_CF4_sandGoesToReviewWithItsAdmin` still
  pins SAND as review. Pausable components such as WBTC, MANA, CHZ, SENT, FLUID, GALA, FET, SNX, PLUME and the Ondo
  tokens (their pause manager, RX-55)
  must be labelled in the app, and so must every other issuer a component adds: BitGo for WBTC, Binance for BTCB and
  every Binance-Peg coin, Tether for Tether Gold, Ondo for every `<ticker>on` stock and ETF, Wormhole for every wrapped copy,
  and both Binance and Wormhole for a copy wrapped from a Binance-Peg coin.

## Conventions

- **Licenses.** Our own files carry `// SPDX-License-Identifier: BUSL-1.1` (`LICENSE`), except the interfaces of our
  own under `src/interfaces`, which carry `MIT` so integrators can build against them. A file copied from another project
  keeps its upstream header and license, names its source and commit, and is listed in `NOTICE`.
- `pragma solidity 0.8.28;` in `src/` and `script/`; tests use `^0.8.24`. The compiler is pinned to 0.8.28 in
  `foundry.toml`, and CI pins Foundry v1.8.1 and eth-wake 4.22.1 in `.github/workflows/test.yml`.
- **Paths start at the repository root** (`test/Repo.t.sol`), and a file in an agent's scratchpad is written
  `.../scratchpad/...`. Never write a path on your machine: a home folder names its user, a temporary folder belongs to
  one machine, and an agent's folder is named after its owner's home folder. CI fails on one
  (`Check no committed file names a local path`), and `test/Repo.t.sol` pins that step.

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
  private function (`test_A1a06_modifierLogicIsPrivate`).
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
  `WeightedHub` are listed under the settlement's rounding above; the arithmetic's are killed by the settlement
  vectors (`test/WeightedMath.vectors.t.sol`) and the rebalance's by `test/WeightedHub.states.t.sol`, each record
  listing its mutants. Every one of them is committed as exact edits in `test/mutants/mutants.json`, which CI's
  mutation gate runs (`test/mutants/run.py`): a fix to a finding adds its mutant there, with the suite that kills it,
  and a change to the code a mutant edits updates that mutant's edit in the same commit, since a stale edit fails the
  gate. Apply a mutant to a byte copy and restore the copy, never `git checkout` (the runner does both); grep a
  failing test as `\[FAIL.*\] (test_\w+)\(\)`, since a failure's message can print a bracketed number; and build
  once after.
- **Tests.**
  - One `*.t.sol` per contract; the hub's rebalancing, its rebalance state machine (`test/WeightedHub.states.t.sol`,
    the matrix of `docs/design/rebalance-state-machine.md`) and its invariants have their own files, and so do
    the invariants of `MintRequests`.
  - The settlement vectors live under `test/vectors/`: `settlement.py` is the exact model and the seeded generator,
    `settlement.json` its output, and `test/WeightedMath.vectors.t.sol` replays it through `vm.readFile` (the folder
    is in `fs_permissions`), never `ffi`. A change to `WeightedMath` regenerates the file in the same commit, and a
    change to the arithmetic's rules changes the model first, then reruns `proofs.py`, which checks the proof's
    chain on the model in exact rationals (`docs/design/rebalance.md`, section 3). `test/WeightedMath.halmos.t.sol` is a Halmos harness: its
    `check_` functions are symbolic and only Halmos runs them; forge runs them at the concrete points of its one
    `test_` function, which keeps the file at CI's 100% coverage.
  - Mocks go under `test/mocks/`. Mainnet constants live in `script/MainnetAddresses.sol`, re-exported with test-only
    ones by `test/fork/ForkAddresses.sol`.
  - New behaviour needs a unit test, and a new revert path needs a test hitting the exact error
    (`vm.expectRevert(abi.encodeWithSelector(...))`).
  - Listing in tests goes through `WeightedTest._list(token)` or, in the zap, `MintRequests` and security
    suites, `XindexTest._listWith(token)`: `proposeListing`, a
    `vm.warp` past `LISTING_DELAY`, then `executeListing`. A test's executor names its fill by the market the test
    knows: `WeightedTest._onWeights(index, prices)` is the fair fill, and `_warpToFirstFill` the second it clears. `XindexTest._createIndex` builds an index from explicit
    units with the weights shared equally.
  - Compute every argument before `vm.prank`: an external call in the arguments consumes the prank.
  - Foundry clears transient storage between a test's own calls. A test of what one transaction carries over in
    transient storage makes its calls from one contract call (`BatchCreator` in `test/Attacks.t.sol`,
    `FillThenCallBack` in the keeper's), or it passes with the property broken (mutant HK1).
  - Measure gas with every touched account cooled first (`vm.cool`), so a call pays the cold reads a transaction of its
    own would.
  - `foundry.toml`'s `fs_permissions` lists, read-only, exactly the files and folders `test/Repo.t.sol` reads: add the
    path a new check needs, never the root, so no test, script or dependency reads `.env` or the broadcast records
    (A7-18, `test_A718_noCheatcodeReadsTheEnvFile`).
  - An invariant handler comes with deterministic walks (`test_XS16_handlerReachesEveryPath...`) that take every line
    and branch of the handler on their own, so CI's 100% coverage does not depend on the fuzz seed. Check a new path
    with `forge coverage --report lcov --match-test <walk>` alone; never pin the seed instead (XS-16).
  - CI's workflow and both Foundry configs are pinned whole by their hashes (A7-12,
    `test_A712_theCiConfigIsPinnedWhole`): a change to one updates its hash in `test/Repo.t.sol` in the same commit
    (the failing test prints it), after a review of the whole change; the step pins there still hold every gate.
- **Scripts.** They keep their logic in public functions that take explicit arguments, so tests can call them without
  environment variables: `DeployWeighted.deploy`, which deploys the factory (and through it the `WeightedHub`
  implementation), the zap and `MintRequests`; `ConfigureWeighted.propose`, `execute`, `safeCalldata` and `status`;
  and `CheckToken.check`, which reports on one token. Environment variables are process-global and tests run in
  parallel, so each variable name is set by exactly one test (see `test/Scripts.t.sol`). In tests, script broadcasts
  come from `DEFAULT_SENDER`.
- **Deployment rules.**
  - Deployments never use raw private keys: `--account` keystores or `--ledger`.
  - `OWNER` and `GUARDIAN` are required, on each chain. `GUARDIAN` is the guardian's Safe, which holds the role
    itself; the guardian rules below read it.
  - On a mainnet the guardian must be a Safe that needs at least `MIN_GUARDIAN_THRESHOLD` (2) signatures: a key, an
    EIP-7702 delegated account, any other contract and a Safe of one signature are refused (`GuardianMustBeASafe`,
    `GuardianThresholdTooLow`, CA-M4). A key has no signers to compare with the owner's, so it passed every other
    check. The figure is the audit record's reading of "the guardian's Safe", and the owner's to change.
  - On a mainnet the owner must be a contract that is not an EIP-7702 delegated account. A Safe owner must need at least
    `MIN_OWNER_THRESHOLD` (3) signatures, the design's 3-of-5, and have no enabled
    module. Any other contract, such as a timelock, is refused unless the operator sets `OWNER_IS_NOT_A_SAFE` to that
    owner's address (A7-08): the script cannot tell who signs for it. An acknowledgment names its owner, so a stale one
    acknowledges no other, and none lowers a Safe rule.
  - When the owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers (SA-06).
  - Neither role may be a market contract: the router and the PoolManager, and on a mainnet every token and mint
    currency in the address book (CR-I37).
  - On chains 1, 56 and 8453 the market addresses are that chain's address book's and nothing else (`MainnetOverride`);
    elsewhere they come from the environment. A pinned chain's own id decides its book: 56 is BNB Chain and 1 is
    Ethereum, whatever code stands at either router's address, because both routers are CREATE2 deployments anyone
    can replay onto the other chain (Ethereum's stands on BNB Chain). Under any other id, a chain-id override
    included, BNB Chain's router having code names BNB Chain and is asked before Ethereum's (RX-23). Never tell a
    real chain 1 or 56 by code alone (mutants N1, N2 and N5). Base is told by its id, 8453, and by nothing else:
    all three routers' addresses have code on the other two chains, so no router's code names Base, and BNB Chain's
    standing there would read a deployment on Base as BNB Chain's (mutants N6 and N7). A run against
    Base's state under another id stays pinned, to BNB Chain's book, and stops at its USDC address.
  - On chains 1, 56 and 8453 `deploy` broadcasts only the build `DeployWeighted`'s `FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH`,
    `BUILDER_INITCODE_HASH`, `REQUESTS_INITCODE_HASH` and `MATH_INITCODE_HASH` record
    (`BuildNotReleased`, CF-5). A change to `src/`, a dependency or the compiler settings, a comment included, since the
    metadata carries the source's hash, fails `test_CF5_theReleaseHashesAreThisBuilds` until those five are set to the
    values it prints, in the same commit. The test stops at the first mismatch; `cast keccak` of each artifact's
    `bytecode.object` gives all five. `foundry.toml` keeps `auto_detect_remappings = false`: the detected remappings
    carry the checkout's absolute path into the metadata, so the hashes differed between machines and CI. After
    changing `foundry.toml`, rebuild with `forge build --force`, since the cache can keep the old artifacts.
- **Mainnet addresses** are verified on-chain before being committed: tokens by symbol and decimals, and the router
  and the PoolManager by their runtime code hashes, since every Universal Router build answers `poolManager()` alike
  (CR-I35). `test/fork/MainnetAddresses.fork.t.sol` checks `script/MainnetAddresses.sol` that way and lists both lists
  on a fresh factory, and `test_CRL08_theListsAreTheReleaseRecord` pins every list's addresses
  against a table written independently of them. The WBTC
  address is `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one. A Wormhole copy of a
  Binance-Peg coin the app labels Custodial. `script/PythIds.sol` holds each coin's Pyth id for the keeper alone,
  which prices its own trades off chain; no contract or script reads it. BNB Chain's addresses are
  `script/BnbChainAddresses.sol`, checked the same way by `test/fork/BnbChainAddresses.fork.t.sol`, its list pinned by
  `test_CRL08_theBnbListIsTheReleaseRecord`.

## Product decisions already made (do not re-litigate silently)

Each is the owner's, and stands until the owner changes it. `CHANGELOG.md` keeps each as it was made: the owner's
words, what was weighed, and what it replaced. If a change would alter any of these, say so explicitly.

**Who creates, and what an index is**
- **Only approved wallets create.** The factory refuses `createIndex` and `createAndIssue` from any wallet its owner has
  not approved, on every chain, and the site lists the team's indexes. A partner is a wallet the owner approves, or the
  team creates the index and hands the partner the creator role with its fee (`transferCreator`, `acceptCreator`).
  Open creation is refused for its cost: with no price behind a creator's units, a creator could make an index off its
  weights and drain it through its own auctions. Reopening it needs an answer to that first. It makes the team the
  issuer and gatekeeper of every index, which counsel's reading must cover.
- **Creating is buying.** `createAndIssue` creates an index and issues its first shares in one call, the basket pulled
  from the creator. Paying for a creation in USDC or USDT is the app's to compose, with no new contract.
- **Custom percentages, fixed coins.** Creators choose each coin and its weight. The coins never change: a new list is a
  new index, which the app's move to a successor index answers (not built). The weights change behind the creator's
  proposal and 7 days of notice, which the owner or guardian can cancel; a weight is never zero, so a coin is phased
  out to one basis point; and a change is refused on a factory without an oracle.
- **Up to 200 coins in one index**, the most every path carries with a sixth of a transaction to spare (the design rule
  "Two hundred is what the contracts carry"). Such an index mints in kind, through the builder or through
  `MintRequests`, never through the zap, which stops near 35. More needs another design, with creation, issue, redeem
  and the fill each spread over several transactions; not taken.
- **A mint pause, and no upgrade.** The owner or guardian pauses new shares on one index or on all, and only the owner
  resumes; no exit reads it. Upgradeable indexes are refused: they would put every index behind one key.
- **Fees in shares**, the platform's policy at zero until the owner sets it: its fee, the referrer's share and its
  streaming rate are not decided (self-referral, RY-3 and RW-4, waits on them). The cadence menu is {7, 14, 30, 91}
  days; a private index is unlisted and, if its creator chooses, mint-gated; the creation fee is zero; Xindex runs the
  first filler; the basket builder ships at launch.

**Prices and the rebalance**
- **The rebalance is judged on units.** No contract reads a price to settle a rebalance, issue, redeem or claim: the
  executor names the units, and the index checks a gain in units against a falling bar. The owner's reason: security
  against oracle attacks. Replacing the rebalance with fixed amounts per token is not taken.
- **A price can only refuse.** On every mainnet factory a fill must also hold at Pyth's prices, and a creation must sit
  within 5% of its weights there. Pyth is the one price source; Chainlink is refused. A Hermes plan is the cost.
- **Ondo's tokens at Pyth's price times their sValue**, read from Ondo's `SyntheticSharesOracle` once settled; Ondo's
  oracle gives no price, only the shares one token stands for. On Ethereum it holds 10 of the 353 tokens, so the
  others can neither be created into an index nor moved by a fill there until Ondo registers them.
- **A quote with a start**: the owner or guardian may post prices of their own with a start, which can only refuse a
  fill. A hot key that narrows prices before each auction is not taken.
- **The owner or guardian may restart a rebalance a week after any fill**, never before an index's first.
- **Not built, for what each would add to go wrong**: fills open at any time at Pyth's price, an index holding other
  indexes, gasless signed orders.

**Chains, venues and currencies**
- **Three deployments, each holding its chain's coins in kind**: Ethereum, BNB Chain and Base, sharing nothing. An index
  lives on one chain, so a buyer who wants two chains' coins buys two tokens. Vaults of our own, proofs and any bridge
  of our own stay refused. A fourth, on Solana, is in development: its program carries the whole design, the
  rebalance and Pyth's check included, and is not yet deployed, run in CI or audited (`docs/design/solana.md`).
- **USDC and USDT are the only currencies**, held to them in the contracts (`NotAStable`); no entry point takes ether.
  Fiat and other-chain entry are the app's, and undecided.
- **Swap venues**: Uniswap's Universal Router 2.0.0, V3 or V4 per leg, on every chain, and each chain's own DEX beside
  it, PancakeSwap on BNB Chain and Aero on Base, each leg naming the deeper pool. Ethereum stays on Uniswap alone.
  THORChain is refused. The keeper's restock buys the nine Ondo stocks with their own Pyth feed through UniswapX on
  Ethereum; the zap, which settles in one transaction, cannot use UniswapX.

**The listings**
- **The admission rule is the WBT rule** (`CheckToken`: a token that can both blacklist a holder and destroy its balance
  is refused), waived token by token where the owner admits an issuer: Tether Gold, Ondo's tokens, Coinbase's. A
  blacklist alone is no bar to listing.
- **Ethereum**: the issuer's own contract where Ethereum has one; Bitcoin as WBTC (do not reopen it); a coin Ethereum
  lacks as Wormhole's copy, labelled Bridged (Custodial too from a Binance-Peg source), Wormhole being the one bridge
  accepted for wrapping. Every Wormhole copy and every copy of Base's bridge on the lists stays, each labelled Bridged:
  thin depth is no mark of a copy. A copy whose home chain is served in kind by BNB Chain's deployment is not listed on
  Ethereum.
- **Ondo's stocks and ETFs**: every one with a Pyth feed, on Ethereum and BNB Chain, ANTon among them; none on Base.
  Backed's xStocks are not listed. USDY and OUSG, Ondo's cash tokens, are not. Ondo's mint and redeem desk serves
  eligible non-US users only, and the legal question of offering stocks is the owner's and counsel's.
- **Base**: the tokens Base issues (WETH, AERO, ZRO), the copies Base's own bridge mints of coins on Ethereum's list,
  and every token Coinbase issues there, its six wrapped coins and ten stock tokens. Base's AERO is Aero's token.
  Coinbase offers its stocks outside the United States only.
- **BNB Chain**: its twelve coins of the first list, CAKE, and Ondo's tokens. Binance-Peg coins are listable, labelled
  Custodial.
- **Not listed**: OKB, BGB, GT, GRAM and NIGHT; memecoins, save SHIB and PEPE; DOGE, whose one listable form was
  Wormhole's copy of a Binance-Peg proxy one key can rewrite; SAND and RLB, after their source reading; BTT, SEI's
  copy and OP's copy, for want of a bridge or a market; JUP, PYTH, SUI, APT and ALGO's copies, which no Ethereum pool
  trades; TRX; Ethereum's AERO copy. The queue drops stablecoins, exchange tokens and Sonic's S, and holds FIL until its
  Binance-Peg source passes a reading.
- **Labels the app shows**: every issuer a component adds (BitGo, Binance, Tether, Ondo, Coinbase, Wormhole, Base's
  bridge), Pausable where an issuer can pause, and each admin's powers where the source reading named them (H, PLUME,
  SNX, SYRUP, GALA, MANA).
- **ATOM is listed, and the restock does not serve it**: its copy is minted only from Binance-Peg ATOM, which has almost
  no market, and buying it on an exchange is refused. An index holding ATOM fills only from stock an operator adds.

**Unchanged across versions:** an owner Safe of at least three signatures; no protocol bots or hot keys; a component
whitelist; the burner chooses the exit stablecoin, USDC or USDT, or exits in kind; the mint currency is not tracked
per holder.

## Not built (candidate backlog)

- Constituent changes (a new list is a new index).
- Mixed-venue legs (a single leg splitting across V3 and V4, or across Uniswap and the chain's own DEX).
- Per-pair partial-fill auctions.
- A backstop for auctions too small to pay: the keeper in `keeper/` fills only what pays, unless its operator sets a
  subsidy (`MIN_PROFIT_USD` below zero).
- An aggregator or Universal Router 2.1 zap.
- V4 pools on Sepolia, so the V4 legs get a testnet rehearsal rather than only fork and mock coverage.
- A deployment on another L2: Base is built, and no other is planned.
- PancakeSwap's Infinity pools and StableSwap on BNB Chain: the zap reaches its V3 and V2 pools alone.
