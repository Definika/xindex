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
Pyth feed and labelled Bridged, Custodial as well when the source is Binance-Peg. The list stands at 91
(`script/PythIds.sol`), 15 of them Wormhole copies, with 26 more copies to attest and FIL's held; DOGE's copy left it on
2026-10-14 (the owner's call, below); on 2026-10-18 the copies of BNB, SUI and SEI, which the count of 2026-10-10
missed, joined it, and SAND and RLB left it after the source reading (the owner's call); on 2026-10-19 BTT and SEI's
copy left it, their bridges closed or closing, and ZK moved to Bridged (the owner's calls on the red team's RX-28,
RX-32 and RX-19). The wrapping adds Wormhole's
guardians as a party whose reach is the whole of each wrapped leg, and the app shows every index's wrapped share of
value. They do not sign Pyth's prices: since Pyth's OP-PIP-132 of 2026-08-26, Pyth's contract on Ethereum verifies
updates against Pyth's own set of five keys (read on chain on 2026-10-12), three of which suffice for a price or for
an upgrade of Pyth's contract (`design/2026-10-18-pre-mainnet-readings.md`). Nothing crosses a chain inside a protocol
contract: the app and the fillers bridge. The keeper's own executor, which is a filler's and holds no role, calls
Wormhole's Token Bridge to restock (2026-10-19). The BNB Chain deployment of 2026-10-07, shelved on 2026-10-10, was deleted on
2026-10-13 with its address book, list and fork suite. No vault, no proof, no
bridge of our own, no speed limit and no freezer exist any more: Stage B (six vaults, eight state verifiers, the P1
and P2 proofs of Ethereum's finality, the hybrid index) is tagged `stage-b-2026-10-07` and deleted, and
`audit/2026-10-07-stage-b-retirement.md` records what went with it. Earlier: v3 (Chainlink prices, tagged `v3.0.0`),
v4's market-cap index (reference supplies and a price-free λ auction, deleted on 2026-10-06,
`audit/2026-10-06-v4-retirement.md`). Nothing is deployed on a mainnet yet.

Where it stands (2026-10-26):
- The weighted index is built and reviewed twice (`audit/2026-10-05-v5-review.md`, `audit/2026-10-07-v5-logic-review.md`).
- The Ethereum deployment's scripts are built: `DeployWeighted`, `ConfigureWeighted` over `PythIds`, `CheckToken`.
- The hundred-coin list is built as far as Ethereum holds it: 93 listed on 2026-10-10 (the 49 of before, 31 more
  Ethereum-issued coins and 13 Wormhole copies that already existed, every one through `CheckToken` on a fork), and
  93 since DOGE's copy left on 2026-10-14, and on 2026-10-18 the copies of BNB, SUI and SEI, found already attested,
  joined and SAND and RLB left; on 2026-10-19 BTT and SEI's copy left, 91 in all, 73 of them coins that count toward
  the hundred. 26 copies await an attestation on Wormhole's Portal (the queue of 31 less USX and CASH, stablecoins,
  BP, an exchange's token, S, which Wormhole does not serve, and FIL, held until its Binance-Peg source passes a
  source reading: RX-11, RX-20, RX-35, RX-64), a
  transaction on each home chain the owner sends (section 2a of the 2026-10-10 record lists them with the procedure,
  section 3 of `design/2026-10-18-pre-mainnet-readings.md` what is left); each then goes through the check and the
  lists. A hundred-coin index is minted in kind or through `MintRequests`, since the zap
  stops near 35 legs. On a fork of 2026-10-11, the 92 coins forge-std can fund issue, rebalance with real transfers
  and redeem in one index, and 45 of them trade through the zap within 2% on $1,000; SNX is out of that test only
  because its balances live in its `TokenState`, beyond forge-std's `deal`. That test's 14.9M gas for the fill counts
  its executor's own `deal` calls; on an anvil fork of 2026-10-12, with Pyth's real contract verifying an update signed
  by keys the test installed in Pyth's receiver, a fill of 93 legs cost 7.26M, Pyth's parse 2.34M of it.
- The engine the website needs was built on 2026-10-14 from the clean-sheet research record
  (`design/2026-10-14-mainnet-engine-research.md`): fees in shares (creator, platform, referrer), a rebalance interval
  per index, gated and unlisted indexes, a creator role in the factory, and `createIndex(..., params)`; the platform's
  policy is zero until the owner sets one. On 2026-10-16 the streaming fee was built as a unit scale, with the
  settlement arithmetic moved to `WeightedMath` for the hub's size (23.8 KB of 24.6 at 100 optimizer runs, down from
  1000 on 2026-10-14 and 200 after). The basket builder was built the same day (`src/BasketBuilder.sol`): a basket
  beyond the zap's 35 legs is bought over several transactions into an escrow of the minter's own, then issued in
  one, and sold the same way; it shares the zap's swap engine, `UniversalRouterSwaps`. On 2026-10-18 the owner took
  items 4 to 10 of the record's section 9 as proposed, with a creation fee of zero; the platform's fee, the referrer's
  share and the platform's streaming rate (items 1 to 3) are still open, so the policy stays at zero, and the legal
  reading (item 11) is counsel's.
- The keeper bot is built (`keeper/`, the keeper's own Foundry project and Node bot, with unit and end-to-end tests):
  it starts and fills auctions, fills `MintRequests` requests at their limits (the record's step 2, built 2026-10-16:
  `fillMint` and `fillRedeem` on the executor, which buys or sells the basket in the fill's own transaction, so a
  request wider than one transaction's swaps waits for stock), serves coins without a Uniswap route from its
  executor's stock, and holds no role. Its end-to-end test passed on 2026-10-17 (20/0, Tenderly's public archive)
  after the fixes of the audit of 2026-10-16. Since 2026-10-19 (the owner's call: "we need everything automated") a
  restock service (`keeper/restock.mjs`) keeps that stock filled for the Wormhole copies: it buys a coin on its home
  chain's DEX, bridges it in through Wormhole's Token Bridge into the executor, whose `redeemBridged` adds what arrived
  to the coin's stock allowance within the restock allowance the owner sets per coin, so restocking never raises what
  a stolen keeper key can deliver beyond the owner's figures (RS-1), and bridges spare stock back out, only to
  home-chain wallets the executor's owner pins, to sell there; USDC moves by CCTP, the treasury holding at most the
  owner's figure off the float (RS-2). It runs under a key of its own, the treasury, which the owner pins. Built for
  the seven EVM-homed coins with a market (XRP, ADA, LTC, DOT on BNB Chain; AVAX, OP, AERO); ATOM has none on BNB
  Chain, and JUP, PYTH, SUI, APT and ALGO wait for their chains' adapters.
- The security audit of 2026-10-13 (`audit/2026-10-13-security-audit.md`, Cloudflare's security-audit skill, ids
  `CF-1`..`CF-8`) found no exploitable path in the four contracts that hold index funds; its findings in the keeper,
  CheckToken, the deploy script and CI are fixed, CF-3 is a known limitation below, and CF-2 and CF-8 went with the
  THORChain planner on 2026-10-14 (`audit/2026-10-14-thorchain-retirement.md`).
- The security audit of 2026-10-16 (`audit/2026-10-16-security-audit.md`, ids `XS-1`..`XS-18`) reviewed the engine
  of 2026-10-14 to 16. Its findings are fixed: the streaming fee's clock restarts on every accrual (XS-1), a settlement
  keeps the scale rather than folding it into floored units (XS-2), a keep-mask fill restarts only
  `MIN_REBALANCE_INTERVAL` for a start without a mask (XS-3), the builder checks its way out before crediting an escrow
  (XS-10), and the keeper's five medium findings and three low ones are fixed in `keeper/`.
- The readings of 2026-10-18 (`design/2026-10-18-pre-mainnet-readings.md`): OP-PIP-132 is read (three of Pyth's
  five keys sign any price and any upgrade of its contract, and Hermes is a paid data plan), Ondo's corporate-action
  mechanism is read (CF-3: a multiplier of shares, never a balance change), the five fork suites ran again (CF-4's
  SAND pin among them), and the tokens listed on 2026-10-10 had their source read
  (`design/2026-10-18-token-source-reading.md`, CF-4). The owner's calls on it: SAND and RLB delisted, H, PLUME, SNX,
  SYRUP, GALA and MANA kept, and the twelve Ondo legs priced at their share's feed kept under the procedure of CF-3.
- The red team of 2026-10-18 (`audit/2026-10-18-red-team.md`, ids `RX-1`..`RX-67`) found no path that takes funds
  from holders or escrows outside the documented bounds. Its findings were fixed on 2026-10-19, the owner's call to
  "fix every finding": in the hub a leg's growth per fill is capped (RX-15), a price far from its own moving average
  is refused (RX-27), a leg a fill buys must be able to leave (RX-12), and issue refuses a leg below its backing
  (RX-8); in the factory units are capped in whole tokens (RX-5) and the creator role is handed on in two steps
  (RX-22); in the keeper, request fills are verified, bounded and pinned (RX-1, RX-2, RX-4, RX-9, RX-10), and the rest
  are documented. RX-3, documented then, was fixed in the hub on 2026-10-26 after an outside reviewer raised it again
  (the owner's call): a start reads every moving feed, and the auction is 4 hours (`test_RX3_...`).
- The review of 2026-10-31 (`audit/2026-10-31-review.md`, ids `AU-1`..`AU-3`) found no high or medium finding. Its
  three are fixed: a gated index no longer pays a referrer its gate would refuse (AU-1), `previewRebalance` takes
  Pyth's feeds and refuses a price far from its average, as the fill does (AU-2, an ABI change the keeper bot follows),
  and the keeper's redeem fill reads balances after paying the stablecoin (AU-3). The hub is 98 bytes under EIP-170.
- v5 was deployed on Sepolia on 2026-10-26 from `07aeae1`, the build before the RX-3 fix, under a 2-of-3 test Safe;
  its four listings can be executed from 2026-10-28 (`docs/deployment.md`, with the addresses). Sepolia runs Glamsterdam
  (EIP-8037): `forge script` broadcasts there need `--gas-estimate-multiplier 900`. The website and its backend, in
  their own repositories, serve it.
- The repository is under the Business Source License 1.1 since 2026-10-28 (`LICENSE`; MIT from 2026-10-26 until
  then, the owner's call to deter commercial clones): non-production use is free, the Additional Use Grant covers
  running the keeper against our deployments and integrating with them, and the Change License is MIT on
  2030-10-28. Our own `src/interfaces` stay MIT. The files copied from Pyth, Wormhole and Uniswap keep
  their own licenses (`NOTICE`).
- The rebalance state machine is written down (`design/2026-10-29-rebalance-state-machine.md`, 2026-10-29, step 1
  of the logic-hardening plan): eight states, the matrix of every action from each, the clock's boundaries and six
  invariants, with `test/WeightedHub.states.t.sol` taking every cell and 17 mutants of the hub checked against it.
  The hub did not change. Step 3 followed the same day (`design/2026-10-29-settlement-vectors.md`): an exact-rational
  model of the settlement written from the spec (`test/vectors/settlement.py`, standard library only) generates
  375 vectors (`test/vectors/settlement.json`) that `test/WeightedMath.vectors.t.sol` replays against
  `WeightedMath.settlement` word for word, every outcome and every cap among them; the 19 mutants of the math all die, two of them only on legs priced at
  one quantum of value. The math
  did not change either. Step 2 the same day (`design/2026-10-29-settlement-proofs.md`): Halmos could not finish the
  narrowest case (two 64-bit units at fixed prices) in ten minutes, since it explores every branch of `Math.mulDiv`,
  so the properties are proven on the exact model in z3 instead (`test/vectors/proofs.py`), over every integer in
  the hub's bounds: for two legs the turnover cap, the growth cap (its exact slack a quadrillionth of the leg, held
  there by the minimum trade), the `μ` bound with no slack, and the rounding directions, each reduced to lemmas
  z3 closes in seconds; for three legs all of them but the `μ` bound's last step, the multiplication of a proven
  inequality by `μ · s`, which z3 did not close and the record leaves as a hand step. Certora was not run (paid).
  Next in that plan: mutation testing as a CI gate.
- The zap takes ether and permits since 2026-10-29 (the owner's call): `mintWithEth`, `burnToEth`,
  `burnToEthWithPermit` and `mintWithTokenPermit`, the backlog's ETH in and out and one-signature USDC mint, with `WETH`
  a construction argument the deploy script resolves (`abi/IndexZap.json`, the zap's unit and fork suites). The Sepolia
  zap of 2026-10-26 predates them and needs a redeploy of the zap alone to serve them.
- Before any mainnet: Pyth's parameter replay (`design/2026-10-05-custom-weights.md`, section 8), which also sizes
  `MAX_EMA_DEVIATION` and `MAX_GROWTH`, and a settlement on a
  real update from Hermes, both waiting on Pyth's API key in `.env` (`PYTH_API_KEY`); the 26 attestations and RAY's
  update; Pyth's confirmation that Ethereum stays served; the platform's fee policy and the legal reading; and an
  external audit, then `DeployWeighted`'s release hashes fixed at the audited commit (CF-5). The two Universal Router
  files `IndexZap` and `BasketBuilder` compile, `IUniversalRouter` and `UniversalRouterCommands`, are declarations
  of our own since 2026-10-28 (they were copied under GPL-3.0 until then), so every file the four contracts compile
  is ours, MIT or Apache-2.0 (`NOTICE`).

For more:
- `design/2026-10-05-custom-weights.md`: the v5 spec.
- `design/2026-10-29-rebalance-state-machine.md`: the rebalance's eight states, the transition matrix, the clock's
  boundaries and the invariants, with the test and the mutants that pin each cell.
- `design/2026-10-29-settlement-vectors.md`: the exact-rational model of the settlement, written from the spec, the
  vectors it generates and the mutants of `WeightedMath` the replay kills.
- `design/2026-10-29-settlement-proofs.md`: the model's properties proven in z3 for two legs, and for three but the
  `μ` bound's last step, the lemmas, the growth cap's exact bound, and why Halmos could not run the contract itself.
- `design/2026-10-18-pre-mainnet-readings.md`: OP-PIP-132, Ondo's corporate actions, the copies left to attest, the
  owner's calls of 2026-10-18 and the source reading of the 2026-10-10 cohort.
- `design/2026-10-10-one-index-wormhole-legs.md`: the one-index decision, the count of the top 300, the trust table
  and the steps to mainnet.
- `design/2026-10-05-wide-asset-support.md` and `design/2026-10-05-token-admission-report.md`: the lists and the
  admission check.
- `design/2026-09-30-v4-stage-a-spec.md` and `ARCHITECTURE.md`: the Stage A design `WeightedHub` keeps.
- `README.md`: the overview. `docs/`: integration, known limitations, assets, design decisions, deployment and
  development. `design/product-brief.md`: the brief the product was built from.

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
python3 -I test/vectors/proofs.py 2 120  # proves the model's caps, mu bound and roundings in z3 for two legs (3 300 for three);
                             # needs a Python with z3, as Halmos's is; rerun after any change to the arithmetic's rules
aderyn .                     # Aderyn on src/, configured by aderyn.toml: must report nothing; CI does not run it
for c in IndexZap BasketBuilder MintRequests WeightedIndexFactory WeightedHub; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change
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
listing; `V5_WHITELIST=default` is the first four coins and `V5_WHITELIST=wide` the rest, 91 in all. On chain 1 the
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
   CI builds with `--deny warnings`, so a compiler warning fails it (A7-17).
3. `forge test` green. `forge coverage` at 100% for every file, including mocks and scripts.
4. Fork tests green if the change touches `IndexZap`, the hub's rebalancing, routes, token behaviour, or anything
   router- or pool-related, `WeightedHub` and its price ids included. Their summary must list the five Ethereum
   `test/fork/` suites and 0 skipped. `WeightedHub.fork.t.sol` alone takes about an hour at the 91-coin list on an archive RPC
   (Alchemy, Tenderly), nearly all of it the admission quotes on a cold RPC cache; a public endpoint prunes the state
   before it ends. They are also required when the deploy checks or `script/MainnetAddresses.sol` change, which
   `MainnetAddresses.fork.t.sol` and `Security.fork.t.sol` exercise.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the documented suppressions are on the `redeem` call in `IndexZap._burnBasket`, the `permit` call in
   `IndexZap._tryPermit`, the `redeem` call in `BasketBuilder.redeem`, and the clone's `initialize` call in
   `WeightedIndexFactory._initializeIndex`, which the creation fee's transfer now follows. v5 adds the executor callback and Pyth's parse in `WeightedHub`, and
   the two events of the vendored `IPythEvents`, which only Pyth emits.
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
     `test_CF1_...` in `keeper/test/KeeperExecutor.t.sol`; CF-4's `test_CF4_...` in `test/CheckToken.t.sol` and
     `testFork_CF4_...` in `test/fork/CheckToken.fork.t.sol`; CF-5's
     `test_CF5_...` in `test/Scripts.t.sol`; CF-6's `test_CF6_...` in `test/Repo.t.sol`; CF-7's the node test named
     `CF-7: ...` in `keeper/test/unit/math.test.mjs`. CF-3 is recorded by documentation alone. CF-2 and CF-8 are
     retired with THORChain.
   - The security audit of 2026-10-16: `XS-1`..`XS-18` (`audit/2026-10-16-security-audit.md`), a test named
     `test_XS1_...`. The record's status column names every test: the hub's in `test/WeightedHub.fees.t.sol`,
     `test/WeightedHub.rebalance.t.sol` and `test/WeightedHub.invariant.t.sol`, the builder's in
     `test/BasketBuilder.t.sol`, XS-17's in `test/Repo.t.sol`, the keeper's in `keeper/test/KeeperExecutor.t.sol` and
     the node tests named `XS-5: ...` and so on in `keeper/test/unit/`. XS-18 is recorded by documentation and the R11
     test's ten entry points.
   - The red team of 2026-10-18: `RX-1`..`RX-67` (`audit/2026-10-18-red-team.md`), a test named `test_RX8_...`, and a
     node test named `RX-1: ...` in `keeper/test/unit/`. The record's "Status of the fixes" names every test; the ids
     fixed by documentation alone, the listing calls and the off-chain readings have none.
   - The review of the restock change on 2026-10-25: `RS-…` (`audit/2026-10-25-restock-review.md`), a test named
     `test_RS1_...` in `keeper/test/KeeperExecutor.t.sol` and a node test named `RS-1: ...` in `keeper/test/unit/`. The
     record's status table names every test.
   - The rebalance review of 2026-10-28: `RB-1`..`RB-5` (`audit/2026-10-28-rebalance-review.md`), a test named
     `test_RB1_...` in `test/CheckToken.t.sol`, and `test_RB2_RX12_...` and `test_RB3_...` in
     `test/WeightedHub.rebalance.t.sol`. RB-4 is fixed by documentation alone; RB-5 is informational and open.
   - The review of 2026-10-31: `AU-1`..`AU-3` (`audit/2026-10-31-review.md`), a test named `test_AU1_...` in
     `test/WeightedHub.fees.t.sol`, `test_AU2_...` in `test/WeightedHub.rebalance.t.sol` with the node test named
     `AU-2: ...` in `keeper/test/unit/hermes.test.mjs`, and `test_AU3_...` in `keeper/test/KeeperExecutor.t.sol`.
   - The skills audit of 2026-10-04: `A7-08`, `A7-12`, `A7-13`, `A7-17`, `A7-18`, `A7-22`, `A1a-05` and `A1a-06`, the
     eight of its findings still open on `main`, fixed on 2026-10-25 (`audit/2026-10-25-skills-audit-port.md`), a
     test named `test_A708_...` or `test_A1a05_...`. The record's status table names every test.
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
`wake detect all src`. It also fails on a committed file that names a path on its author's machine. The fork suites run
on every push from this repository, because the test step passes the `MAINNET_RPC_URL` secret unconditionally. On `main`
and on pull requests into it the secret is also required, so a missing one fails the run rather than letting the suites
skip. Check a run's test summary rather than assuming. Run everything locally before pushing. A pull request from a
forked repository gets no secrets, so its fork suites skip, and a maintainer re-runs them before merging.

## Layout

`ls` and each file's header comments show what lives where, and README.md's Repository structure gives the tour. Two things
the tree does not say: `script/testnet/` (the Sepolia test market) never deploys to a mainnet; and `keeper/` is the keeper bot with its executor contract, a Foundry project of
its own with its own tests (`keeper/README.md`): it starts and fills auctions, fills `MintRequests` requests at their
limits (since 2026-10-16), serves coins without a Uniswap route from the executor's stock, and holds no role in the
protocol. Anyone may run one; its key is the keeper's own hot key, never
the owner's or the guardian's. Its restock service (`keeper/restock.mjs`, `keeper/restock/`) runs beside it with the
treasury's key, also never the owner's or the guardian's.

Deleted on 2026-10-13 as unused, and recoverable from git at `f83dcab`: the v4 hackathon demo (`demo/`), the reviews'
PoC tests (`audit/poc/`, which the audit records still cite), v4's market-cap analysis scripts (`design/analysis/`), the
v4 architecture PDF with its builder (`design/build_pdf.py`), the BNB Chain deployment (`script/BnbChainAddresses.sol`,
its list and fork suite), and the design records of retired designs and research (v4's hybrid architecture, Stage B's
spec and interfaces, Stage C, the chain and L2 research, the hackathon plan, the two-chain decision), which the audit
records also cite.

## Design rules that must not be broken

- **One place reads a price.** Only `WeightedHub` reads one, from Pyth, and only for the moving components: its
  settlement prices them, and its start (`startRebalance`) parses the same feeds in the same window and keeps no price,
  only proving that every feed publishes, so a rebalance starts only while each leg's market is open (RX-3, the owner's
  call of 2026-10-26). Issue, redeem, `redeemSkipping` and claims never read a price, so no feed can block an exit or
  misprice a mint (`test_issueAndRedeemNeverCallPyth`). The factory stores price ids and never calls Pyth;
  `test_V5I4_onlyTheWeightedHubReadsAPrice` fails if any other file names Pyth's contract, parse, getters, pushes or
  price struct. No Chainlink feed or pool price anywhere (`test_A713_noContractReadsAPrice`). Valuing an index is the
  app's job, off-chain. The zap swaps, but it reads no price either: it enforces the limits its caller sets.
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
  price, an exponent outside [-18, 0], a result above `MAX_PRICE`, a confidence interval wider than `MAX_CONFIDENCE`,
  and a price further than `MAX_EMA_DEVIATION` (5%) from the moving average Pyth publishes in the same update, or an
  average that is not positive or has another exponent: a push of a few seconds on thin venues cannot set a fill's
  price (RX-27). The bound reads nothing the parse does not return; the replay sizes it.
- **Weights and constituents are fixed at creation,** two to a hundred components, and an index copies its price ids
  and decimals then, so no relisting reaches an existing index. The CREATE2 salt commits to every component's token,
  units, weight, price id and decimals, and to the index's config: its fee rates, referral share and rebalance interval
  (LR-05: never switch back to CREATE). The gate and the listing flag are not terms of the index and not in the salt.
  A component starts with at least `MIN_RAW_UNITS` and at most `maxUnitsOf(token)`: `MAX_WHOLE_TOKENS` (1e9) whole
  tokens per share, never above `MAX_UNITS`, so a wei-share backs a negligible amount and no fee's rounding to whole
  wei-shares is worth anything (RX-5).
- **The cap counts units, never value.** A fill sends out at most `MAX_TURNOVER` (20%) of each component's own units,
  and adds to a growing one at most `μ` times `MAX_GROWTH` (100%, the math's) of its own units, every leg moving the
  same share of the way, so a wrong or malicious price takes at most that, at most once a week. The growth cap keeps a
  coin whose issuer mints and dumps it from drawing a fifth of every other leg into it in one fill: it draws about its
  own value at most (RX-15). The growth cap's exact slack is the growth factor's rounding, up to the leg's units over
  the share; the minimum trade keeps the share at or above `MIN_TRADE`, so the slack is at most a quadrillionth of
  the leg (`design/2026-10-29-settlement-proofs.md`, P3): do not drop the minimum without re-reading the cap. A value cap measured in the reported prices let two wrong feeds take 89% of an index far
  from its weights (V5-M2); do not bring one back as the only cap.
- **A fill must trade.** One whose release, after the turnover cap, is worth less than `MIN_TRADE` (0.1%) of the
  moving value reverts `NothingToRebalance`, and a keep mask must leave two components moving, so a fill that changes
  nothing cannot restart the rebalance interval (V5-L2). The minimum is checked on the capped release: checked before
  the cap, a fill could trade a fifth of it (V5R-1). The guardian's cancel remains the trust assumption DA-12 records.
- **The settlement's rounding.** Targets round up; a shrinking leg's step rounds down; a growing leg's rounds up, by the
  factor `μ · s` rounded up, with `μ` falling from `MU_MAX` to `MU_MIN` and rounding up. At the settling prices the
  executor delivers at least `μ` times what it takes. A fill that sends nothing out settles at `MU_MAX`. The mutants
  worth rerunning: each of those roundings flipped, no unit cap, no `MIN_TRADE` or one measured before the cap, a keep
  mask leaving one, a wider window or the minute, no confidence or publish-time check, a kept feed read, the
  duplicate-id checks removed, and the backing post-check's: the claims dropped from the backing term, only the bought
  legs re-read, and a shrinking leg paid as a difference of floored backings. The arithmetic's mutants of that list,
  the caps, the scale and a constant among them, are killed by the settlement vectors (`test/WeightedMath.vectors.t.sol`,
  `design/2026-10-29-settlement-vectors.md`, section 5); run them again after any change to `WeightedMath`.
- **A collapsing coin can stop the fills.** Fixed weights keep buying it, at most doubling its units per fill (RX-15);
  a coin that falls far enough leaves every fill below `MIN_TRADE`, and units beyond `uint96` stop the fill rather than
  wrap, the preview with it (RX-61), until the guardian keeps it (V5-L3, a known limitation).
- **An issuer's corporate action is not accounted for.** Units are fixed per share and amounts come only from supply
  and units, so tokens an issuer mints to holders, as a split paid in tokens would be, stay in the index owned by no
  share, and a burn leaves that leg below its backing; a token that stops being one share misprices a leg priced at the
  share's feed (CF-3, a known limitation). Do not add a path that pays out balances to cover it. What the hub does
  check: issue refuses while a leg's balance is below the backing of the shares already issued plus its open claims, as
  after an issuer burned the index's balance, so no new deposit refills the hole for earlier holders (RX-8); and a fill
  that grows a leg must leave the index able to send that leg, measured by sending itself one raw unit, so a token that
  blocks only its sender, as Tether Gold's does, cannot have good legs moved into a leg nobody can take out (RX-12).
- **The notice is 2 hours.** `WeightedHub`'s `REBALANCE_DELAY` is 2 hours: targets come from the settlement's prices,
  so the notice is for executors, not for holders' exits (the spec's section 8). `AUCTION_DURATION` is 4 hours (24
  until 2026-10-26): with the notice it is shorter than any closure of a market a feed follows, 17.5 hours overnight for
  the US-hours stocks, so an auction started while every feed publishes ends before the next open and no fill lands at
  a reopening near `MU_MIN` (RX-3); do not lengthen it past that, nor drop the start's read. The
  rebalance interval is the index's own, chosen at creation within [`MIN_REBALANCE_INTERVAL`, `MAX_REBALANCE_INTERVAL`]
  = [7, 91] days (the website's weekly to quarterly cadences; V5R-I2 set the floor). A fill with a keep mask restarts
  only `MIN_REBALANCE_INTERVAL`, for any start (`earliestRebalance()`, XS-3): a guardian's sliver cannot hold the index
  off for a quarter, and a keep around a frozen component can be renewed a week on. The cost, accepted: the owner or
  guardian can run keep-mask fills weekly on a quarterly index, each within the turnover cap at Pyth prices. A cancel, or an auction that
  expired unfilled, holds strangers off for `REBALANCE_DELAY`, so the owner and guardian get the first restart;
  `canStartRebalance` answers whether strangers may, and false for a clone that was never initialized (DA-22; CR-I02
  for the second after an expiry).
- **Value-bearing amounts are in-kind.** The hub only ever moves amounts derived from supply and units: issue, redeem,
  claims and rebalance settlements. Never compute an amount from balances (balances only verify), and never add a
  share price to the hub. `_backing(shares, units, scale, rounding)` is the one place that turns shares and units
  into an amount. No share can be sent to the index itself or its factory: `_update` refuses both (CR-I01, RT-21).
- **Fees are shares, never components** (built 2026-10-14, `design/2026-10-14-mainnet-engine-research.md`, section
  5.6, overturning the no-fee call of 2026-09-30 because the website charges them). An index charges its creator's rate
  (0 to `MAX_CREATOR_FEE_BPS`, 100, the creator's choice) plus the platform's (0 to `MAX_PLATFORM_FEE_BPS`, 25, the
  factory's policy when the index was created) on every issue and every redeem, in basis points of the shares. A
  minter's deposit backs the fee's shares on top of its own (`previewIssue` sizes for the gross, rounded up); a burner's
  fee is minted to the recipients out of the shares it burns and it is paid the net backing, rounded down. Every share
  stays backed by the deposit that minted it, so the invariant is untouched. The recipients come from the factory at
  each call (`feeTerms`): the index's creator (`creatorOf`, which the creator can offer on and the new creator must
  accept, RX-22) and the platform recipient;
  a referrer named at mint takes `referralShareBps` of the platform's part, so a self-referral discounts only the
  platform's. A recipient that could not hold shares is replaced (the creator by the call's `to`, the platform's part
  folded into the creator's), so no recipient can block a mint or an exit. Rates are fixed per index; the policy
  reaches only later indexes, and a creator names the highest platform fee it accepts (`PlatformFeeTooHigh`). The
  creation fee, in ether, is forwarded whole in the same call.
- **A streaming fee is a unit scale** (built 2026-10-16, the record's option B). An index charges its creator's yearly
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
  The scale pushed the settlement arithmetic out of the hub's EIP-170 budget into `WeightedMath`, a stateless contract
  the factory deploys with the implementation and the hub calls by STATICCALL (`MATH`); its constants are the hub's
  (`test_theMathConstantsAreTheHubs`), and the optimizer runs are 100 for the same reason.
- **A gated index issues only to its creator and allowed recipients.** The factory keeps the gate (`isGated`) and the
  allowlist (`isAllowedMinter`), both the creator's; the creator mints without an entry, a right that moves with the
  role (2026-10-27: on the website a private index's own creator could not buy it,
  `test_theCreatorMintsItsOwnGatedIndex`); the creator can open the gate for good (`openMinting`), never close it.
  The minter names the referrer, so the gate holds for it too: a referrer the gate would refuse as `to` is named
  nobody and the platform keeps its part (AU-1). The platform recipient takes its fee shares whatever the gate.
  Transfers and burns never read the gate, so the token stays an ERC-20 the zap and `MintRequests` can handle. The
  creator has no other power: not over components, rates, or anyone's shares.
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
  redeeming on a holder's behalf does not strand the skipped components (DA-17). There is no speed limit and no cap on
  a burn anywhere: a holder burns any amount at any time.
- **No admin power over funds, no rebalancing key.**
  - The factory owner proposes listings (behind `LISTING_DELAY`, 2 days) and guardian changes (behind
    `GUARDIAN_DELAY`, 7 days). Anyone can execute a proposal, but only within `PROPOSAL_WINDOW` (7 days) after its
    delay. The owner also delists, transfers ownership, and sets the fee policy (`setFeePolicy`: the platform's rate,
    the referral share, the recipient, the creation fee), which reaches only indexes created afterwards; the recipient
    can be neither zero, the factory nor an index.
  - The guardian can: cancel pending listings; delist; cancel a rebalance; start one with a keep mask; start one before
    strangers may; and cancel a guardian change that would remove the role. It cannot block its own replacement.
  - There is no pause, no upgrade, no sweep, no renounce, no instant guardian change, and no keeper or bot role. Keep
    it that way.
  - `cancelRebalance` has no window and no rate limit. A hostile or compromised guardian can cancel each auction at its
    last second and hold rebalancing off while the index drifts from its weights. That stall is bounded by the owner
    replacing the guardian, which takes `GUARDIAN_DELAY` and which the guardian cannot cancel. It moves no funds, and
    holders redeem throughout. A cancel budget was considered and rejected (DA-12). A keep-mask start that leaves only
    a sliver moving can also restart `MIN_REBALANCE_INTERVAL` for everyone (XS-3 made that the bound: before, the
    sliver restarted the index's interval, up to 91 days), so the stall can outlast the guardian's replacement by up
    to `MIN_REBALANCE_INTERVAL`. While a replacement is pending, the owner cancels the outgoing guardian's keep-mask
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
  EIP-7825's 2^24 gas cap on mock tokens (`test_aHundredComponentsFitOneTransaction`): `createIndex` about 10.7M
  (13.1M until 2026-10-28, when the two duplicate checks stopped re-decoding calldata structs for every pair),
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
- **Every payable path forwards the whole of `msg.value` to Pyth;** the hub never holds ether. Since 2026-10-26 that
  is `startRebalance` as well as both `executeRebalance` overloads.
- **The zap is stateless and replaceable.** New UX features (ETH in/out, aggregators, mixed-venue legs) go in a new or
  extended zap, never in the hub or factory. The app caps a zap basket at about 35 components, which is where 16.78M gas
  runs out. Since 2026-10-16 the zap's swaps run through `UniversalRouterSwaps`, the engine it shares with the basket
  builder: the venue, command, payment, spend-bound, unsold-input, V4-route and check rules below are the engine's,
  and the swap errors both raise are declared in `IXindexErrors`.
  - **Ether and permits** (built 2026-10-29, the owner's call to build the backlog's ETH entry and one-signature
    mint, which widens the 2026-10-14 "USDC or USDT" entry to ether). `mintWithEth` and `burnToEth` are
    `mintWithToken` and `burnToToken` with WETH as the token: `tokenIn` or `tokenOut` names `WETH`, a construction
    argument `DeployWeighted` resolves like the stablecoins (`WETH` in the environment, the address book's on chain
    1), `msg.value` must equal `maxAmountIn`, the zap wraps and unwraps, and a caller or `to` that refuses ether fails
    the call. `mintWithTokenPermit`, `burnToTokenWithPermit` and `burnToEthWithPermit` try an EIP-2612 permit for the
    whole amount pulled and accept one already submitted; USDT has none. Fiat and other-chain entry stay app-side and
    undecided. The Sepolia zap of 2026-10-26 predates these entry points; a redeploy of the zap alone serves them.
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
    because native ether must never reach the zap through a swap: its `receive()` takes ether from WETH alone, which
    `withdraw` sends back for `mintWithEth`'s refund and `burnToEth`'s payout, and refuses every other sender.
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
- **The basket builder is the zap's stateful sibling** (built 2026-10-16, `src/BasketBuilder.sol`, the record's
  self-serve path for any size). The legs of a basket too wide for one transaction are bought over several `buy`
  calls into an escrow per caller and token (`escrowOf`), then issued in one `mint`; selling mirrors it: `redeem`
  into the escrow, `sell` the legs over several calls, `withdraw` what has no route, and `deposit` what has none to
  begin with. It has no owner, no upgrade and nothing to configure; a token in an escrow moves only on its owner's
  call; every amount is measured where it lands (a deposit and a redeem credit the balance increase, a buy what the
  engine measured delivered, a sale debits what it gave the router and credits back what the sweep returned), so the
  builder's balance of every token covers the escrows. A buy is sized by `previewIssue` at the call less the escrow, a
  stale quote reverts `StaleRebalanceNonce`, and a leg a rebalance left short is named by `InsufficientEscrow` for one
  more buy. The pass-through legs honour their limits (DA-15), the recipients are checked as the zap's (RT-21), and
  the builder never calls `redeemSkipping` or `executeRebalance` either. A hundred-leg basket fits three buys and one
  mint under EIP-7825 (`test_aHundredLegBasketFitsInThreeBuysAndAMint`, on mock pools).
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
  `ConfigureWeighted` refuses the deployment's own, `V5_USDC` and `V5_USDT` off Ethereum, as well as Ethereum's (A7-22).
  The policy wants 6 to 18 decimals, which matter only to display and to Pyth's scaling. The admission check is
  `CheckToken`, and the WBT rule (a token that can both blacklist a holder and destroy its balance is refused) stays its
  default. On 2026-10-10 the owner ruled that a blacklist is no bar to listing and admitted Tether Gold, which the rule
  refuses, and Ondo's stock tokens, whose compliance contract and burner role amount to the same power;
  `testFork_everyWideTokenPassesTheCheck` pins Tether Gold as the one refused entry and GALA, whose blocklist sits
  beside a `burnFrom`, as the one for review (CF-4). SAND, whose two admins' operators move any holder's balance, and
  RLB, whose code is unverified, left the list on 2026-10-18 after the source reading
  (`design/2026-10-18-token-source-reading.md`), the owner's call; `testFork_CF4_sandGoesToReviewWithItsAdmin` still
  pins SAND as review. Pausable components such as WBTC, MANA, CHZ, SENT, FLUID, GALA, FET, SNX, PLUME and the Ondo
  tokens (their pause manager, RX-55)
  must be labelled in the app, and so must every other issuer a component adds: BitGo for WBTC, Binance for BTCB and
  every Binance-Peg coin, Tether for Tether Gold, Ondo for every `<ticker>on` stock, Wormhole for every wrapped copy,
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
  listing its mutants. Apply a mutant to a byte copy and restore the copy, never `git checkout`; grep a failing test
  as `\[FAIL.*\] (test_\w+)\(\)`, since a failure's message can print a bracketed number; and build once after.
- **Tests.**
  - One `*.t.sol` per contract; the hub's rebalancing, its rebalance state machine (`test/WeightedHub.states.t.sol`,
    the matrix of `design/2026-10-29-rebalance-state-machine.md`) and its invariants have their own files, and so do
    the invariants of `MintRequests`.
  - The settlement vectors live under `test/vectors/`: `settlement.py` is the exact model and the seeded generator,
    `settlement.json` its output, and `test/WeightedMath.vectors.t.sol` replays it through `vm.readFile` (the folder
    is in `fs_permissions`), never `ffi`. A change to `WeightedMath` regenerates the file in the same commit, and a
    change to the arithmetic's rules changes the model first, then reruns `proofs.py`, the model's properties in z3
    (`design/2026-10-29-settlement-proofs.md`). `test/WeightedMath.halmos.t.sol` is a Halmos harness: its
    `check_` functions are symbolic and only Halmos runs them; forge runs them at the concrete points of its one
    `test_` function, which keeps the file at CI's 100% coverage.
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
  - `OWNER` and `GUARDIAN` are required, on each chain.
  - On a mainnet the owner must be a contract that is not an EIP-7702 delegated account. A Safe owner must need at least
    `MIN_OWNER_THRESHOLD` (3) signatures, the design's 3-of-5 (the owner's call on 2026-09-30), and have no enabled
    module. Any other contract, such as a timelock, is refused unless the operator sets `OWNER_IS_NOT_A_SAFE` to that
    owner's address (A7-08): the script cannot tell who signs for it. An acknowledgment names its owner, so a stale one
    acknowledges no other, and none lowers a Safe rule.
  - When the owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers (SA-06).
  - Neither role may be a market contract: the router and the PoolManager, Pyth, and on a mainnet every token and mint
    currency in the address book (CR-I37).
  - On chain 1 the market addresses are the address book's and nothing else (`MainnetOverride`); elsewhere they come
    from the environment.
  - On chain 1 `deploy` broadcasts only the build `DeployWeighted`'s `FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH`,
    `BUILDER_INITCODE_HASH` and `REQUESTS_INITCODE_HASH` record (`BuildNotReleased`, CF-5). A change to `src/`, a
    dependency or the compiler settings fails `test_CF5_theReleaseHashesAreThisBuilds` until those four are set to the
    values it prints, in the same commit. The test stops at the first mismatch; `cast keccak` of each artifact's
    `bytecode.object` gives all four. `foundry.toml` keeps `auto_detect_remappings = false`: the detected remappings
    carry the checkout's absolute path into the metadata, so the hashes differed between machines and CI. After
    changing `foundry.toml`, rebuild with `forge build --force`, since the cache can keep the old artifacts.
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
- DOGE is off the list for now (the owner's call on 2026-10-14). Its only listable form was Wormhole's copy of
  Binance-Peg DOGE, and Pyth prices DOGE, not the copy: a broken peg or bridge would leave the copy priced as DOGE.
  Binance-Peg DOGE is a proxy whose admin, one externally owned key on BNB Chain, can replace its code (read that
  day). The copy's address stays recorded in `script/MainnetAddresses.sol` for a relisting. XRP, whose Binance-Peg
  source answers `mint(uint256)` to one key but cannot change its code, stays listed.
- The owner's calls of 2026-10-18 on the source reading (`design/2026-10-18-token-source-reading.md`): SAND and RLB
  are off the list. SAND's two multisig admins and 22 operator contracts can move or burn any holder's balance with no
  timelock, which the WBT rule exists to stop even without a blacklist; RLB's implementation is unverified and one
  externally owned key can upgrade it. H, PLUME, SNX, SYRUP, GALA and MANA stay, their admins' powers named by the app;
  MANA, CHZ, SENT and FLUID are labelled Pausable. Wormhole's copies of BNB, SUI and SEI joined the list the same day.
- The twelve Ondo legs priced at their share's feed stay (the owner's call of 2026-10-18), under the procedure of
  `design/2026-10-18-pre-mainnet-readings.md`, section 2: the guardian keeps an affected leg around a corporate action,
  and a leg is relisted at its token's own feed once Pyth publishes one. The procedure also has the guardian cancel each
  auction of an index that cannot keep such a leg around a split (a two-leg index), the keeper's stock allowance for
  those legs stays at zero, and Ondo's terminations, paid only to KYC'd redeemers, are a loss for holders still in at
  the date, so the app tells them to exit first (RX-2, RX-7, RX-29).
- The owner's calls of 2026-10-19 on the red team (`audit/2026-10-18-red-team.md`): BTT and SEI's Wormhole copy are off
  the list (BTTC's bridge closed in June 2026; the copy of SEI redeems only through Sei's CosmWasm side, which Sei is
  shutting down; RX-28, RX-32), their addresses kept in `script/MainnetAddresses.sol` for a relisting; ZK is tiered
  Bridged, ZKsync's bridge copy (RX-19); the queue drops USX and CASH (stablecoins), BP (an exchange's token) and S
  (Wormhole does not serve Sonic), and holds FIL until its Binance-Peg source passes a reading (RX-11, RX-20, RX-35,
  RX-64). An index holding one of the six US-hours stocks first becomes fillable at the next open, near `MU_MIN`: the
  app says so at creation, and the keeper times its own starts for a session (RX-3); the hub is unchanged. Superseded on
  2026-10-26, the owner's call after an outside reviewer raised RX-3 again: the hub fixes it, a start reading every
  moving feed and the auction cut to 4 hours, so no auction can reach a reopening.
- ATOM stays listed, and the restock service does not serve it (the owner's call of 2026-10-20). Its Wormhole copy is
  minted only from Binance-Peg ATOM, which has almost no market on BNB Chain (read on 2026-10-19: selling $500 lost
  305 bps on PancakeSwap v3, $1,000 lost 22% on v2). Ethereum's other ATOM tokens are no way round it: Gravity Bridge's
  (`0x8D983cb9388EaC77af0474fA441C4815500Cb7BB`, 12,069 ATOM) and Axelar's axlATOM
  (`0x27292cf0016E5dF1d8b37306B2A98588aCbD6fCA`, 979 ATOM) are other bridges, which the Wormhole-only rule refuses,
  and neither has a Uniswap market (read on 2026-10-20). An index holding ATOM fills only from stock an operator adds;
  buying it on Binance, the exchange route the owner turned down on 2026-10-19, is the one automatic source left.

**Swap venues** (the owner's call on 2026-10-14): the zap swaps through Uniswap's Universal Router 2.0.0 alone, V3 or
V4 per leg, chosen by the caller. PancakeSwap's v3 Universal Router, a third venue per leg since 2026-10-06 (chiefly
for CAKE), and THORChain, an app-side rail added the same day (`design/2026-10-06-swap-venues.md`), were both removed on
2026-10-14: users come with USDC or USDT, and since 2026-10-29 with ether through the zap's `mintWithEth` and
`burnToEth` (the owner's call to build the backlog's ETH entry; fiat and other-chain entry stay app-side and
undecided). CAKE stays listed; its legs route through Uniswap's pools, or it mints in
kind or through `MintRequests`.

**Fees, cadence and private indexes** (built 2026-10-14 on the research record's defaults): fees in shares with the
platform's policy at zero until the owner sets one, so the no-fee call of 2026-09-30 survives as a configuration; a
rebalance interval per index from 7 to 91 days; a private index is one the app does not list plus, if the creator
chose it, a mint allowlist the creator keeps. The owner's calls of 2026-10-18 on the record's section 9: the cadence
menu is {7, 14, 30, 91} days; private indexes are unlisted and mint-gated, both opt-in; Xindex runs the first filler;
the basket builder ships at launch; the replay decides the hardenings; the coin pages show the listed set and tiers;
no Base deployment for now; the creation fee is zero. The platform's fee, the referrer's share and the platform's
streaming rate are not decided yet; the legal reading is counsel's.

**Unchanged from earlier versions:** an owner Safe of at least three signatures; fixed constituents; no protocol bots
or hot keys; component whitelist only; the burner chooses the exit token; the mint currency is not tracked per holder;
up to `MAX_COMPONENTS` (100) per index.

If a change would alter any of these, say so explicitly.

## Not built (candidate backlog)

- `createAndMint`.
- Constituent changes (a new list is a new index).
- Mixed-venue legs (a single leg splitting across V3 and V4).
- Per-pair partial-fill auctions.
- A backstop for auctions too small to pay: the keeper in `keeper/` fills only what pays, unless its operator sets a
  subsidy (`MIN_PROFIT_USD` below zero).
- An aggregator or Universal Router 2.1 zap.
- V4 pools on Sepolia, so the V4 legs get a testnet rehearsal rather than only fork and mock coverage.
- One L2 deployment, if cheap minting for small buyers matters after the two launches.
