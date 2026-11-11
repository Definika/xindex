# CLAUDE.md

Guidance for coding agents and humans working in this repository. This file is the only copy: it imports no other, and
Claude Code reads it as the project's instructions.

## What this is

Xindex smart contracts: a Foundry project where wallets the owner approves create crypto index tokens (ERC-20)
backed in kind (the Xindex team's), and
users mint them with USDC/USDT, and burn them into any token
through Uniswap's Universal Router, which reaches both V3 and V4 pools. Creators choose each coin's percentage, fixed
at creation with the coin list, and the index rebalances back toward those percentages through a permissionless
auction. **No contract reads a price** (since 2026-11-10, the owner's call, `design/2026-11-10-oracle-free-rebalance.md`):
the executor names the units a rebalance settles at, and the index accepts them only if a weighted gain in units
clears a bar that falls with time. Pyth, which priced the rebalance until then, is gone from the protocol. The web app
lives in a separate repo.

**Xindex is one deployment, on Ethereum, and one index holds up to 100 coins of the top 300** (the owner's decision
of 2026-10-10, `design/2026-10-10-one-index-wormhole-legs.md`). `WeightedIndexFactory`, `WeightedHub`, `IndexZap` and
`MintRequests` hold Ethereum ERC-20s in kind: the issuer's own contract where Ethereum has one (71 candidates of the
top 300 today), and otherwise a copy wrapped by Wormhole's token bridge from the chain that has it (17 from BNB Chain,
nine of them Binance-Peg; 31 from Solana, Sui, Aptos, Base and the other chains Wormhole serves), labelled Bridged,
Custodial as well when the source is Binance-Peg. The list stands at 91
(`script/Listings.sol`), 15 of them Wormhole copies, with 26 more copies to attest and FIL's held; DOGE's copy left it on
2026-10-14 (the owner's call, below); on 2026-10-18 the copies of BNB, SUI and SEI, which the count of 2026-10-10
missed, joined it, and SAND and RLB left it after the source reading (the owner's call); on 2026-10-19 BTT and SEI's
copy left it, their bridges closed or closing, and ZK moved to Bridged (the owner's calls on the red team's RX-28,
RX-32 and RX-19). The wrapping adds Wormhole's
guardians as a party whose reach is the whole of each wrapped leg, and the app shows every index's wrapped share of
value. Pyth's five keys, three of which signed any price (`design/2026-10-18-pre-mainnet-readings.md`), are no party
since 2026-11-10: nothing reads them. Nothing crosses a chain inside a protocol
contract: the app and the fillers bridge. The keeper's own executor, which is a filler's and holds no role, calls
Wormhole's Token Bridge to restock (2026-10-19). The BNB Chain deployment of 2026-10-07, shelved on 2026-10-10, was deleted on
2026-10-13 with its address book, list and fork suite. No vault, no proof, no
bridge of our own, no speed limit and no freezer exist any more: Stage B (six vaults, eight state verifiers, the P1
and P2 proofs of Ethereum's finality, the hybrid index) is tagged `stage-b-2026-10-07` and deleted, and
`audit/2026-10-07-stage-b-retirement.md` records what went with it. Earlier: v3 (Chainlink prices, tagged `v3.0.0`),
v4's market-cap index (reference supplies and a price-free λ auction, deleted on 2026-10-06,
`audit/2026-10-06-v4-retirement.md`). Nothing is deployed on a mainnet yet.

Where it stands (2026-11-10). The bullets below are a history: those written before 2026-11-10 describe the
Pyth-priced rebalance as it then was, and the last one says what replaced it.
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
  after the fixes of the audit of 2026-10-16, again on 2026-11-01 (20/0) after the red teams' fixes, with the
  restock's (94/0), and on 2026-11-02 (23/0, on an archive RPC) with the guardian relay's start the keeper sends
  (RZ-26). Since 2026-10-19 (the owner's call: "we need everything automated") a
  restock service (`keeper/restock.mjs`) keeps that stock filled for the Wormhole copies: it buys a coin on its home
  chain's DEX, bridges it in through Wormhole's Token Bridge into the executor, whose `redeemBridged` adds what arrived
  to the coin's stock allowance within the restock allowance the owner sets per coin, so restocking never raises what
  a stolen keeper key can deliver beyond the owner's figures (RS-1), and bridges spare stock back out, only to
  home-chain wallets the executor's owner pins, to sell there; USDC moves by CCTP, the treasury holding at most the
  owner's figure off the float (RS-2). It runs under a key of its own, the treasury, which the owner pins. Built for
  the eight EVM-homed coins with a market (XRP, ADA, LTC, DOT and, since 2026-11-01, BNB on BNB Chain; AVAX, OP,
  AERO); ATOM has none on BNB Chain, and JUP, PYTH, SUI, APT and ALGO wait for their chains' adapters.
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
- The red teams of 2026-10-31 (`audit/2026-10-31-red-team.md`, ids `RY-1`..`RY-9`; `audit/2026-10-31-red-team-ii.md`,
  ids `RZ-1`..`RZ-33`) found no path that takes holders' funds. Fixed on 2026-11-01: the request filler had valued
  nothing since RX-9's fix, and the restock's RY-6 fix would have stopped it, because viem returns Pyth's parse
  unwrapped (RZ-1); the restock's halving never quoted (RZ-2); stock left the needs board the moment it landed (RZ-3);
  the keeper values only prices Pyth's contract confirms, previews included (RY-7); the zap refuses WETH and the
  call's own token as recipients (RY-1); BNB joined the restock (RZ-5). The owner's calls of 2026-11-02 on the four
  left open:
  - A start must land in one slot, which a Safe cannot time (RZ-26): the guardian is a `GuardianRelay` its Safe
    controls, which `DeployWeighted` deploys; the Safe authorizes a start and anyone, the keeper first, sends it.
  - A collapsed leg stops the fills far sooner than was documented (RZ-4): the stop stays.
  - Issue does not probe a frozen leg (RZ-25): the app checks before it offers a mint; the hub is unchanged.
  - A need reaches the restock only for a fill that could pay `MIN_PROFIT_USD` at its best price (RY-8).
  - RY-3's self-referral waits for the fee policy.

  The fork suites ran on the zap's change in CI on 2026-11-02 (`f2f4c18`): the five suites' 45 tests, 0 skipped.
- The protocol documentation review of 2026-11-01 (`audit/2026-11-01-protocol-docs-review.md`, ids `PD-1`..`PD-14`)
  read every protocol Xindex uses in its own docs. The contracts that hold index funds follow them all; every finding
  is in the restock service. It found three ways a compromised aggregator answer could take more than the bounds, all
  in the non-EVM swaps of 2026-11-01, which had never run:
  - Jupiter's other routes (PD-1), and its on-chain minimum, which lives in instruction bytes nobody read (PD-2);
  - Cetus's API-chosen package with no floor of ours (PD-3).

  The fourteen were fixed on 2026-11-02, the owner's call:
  - Jupiter's swap is read by its own IDL, from the front.
  - Every token account of the wallet is held in the simulation.
  - Sui's floor is split on chain.
  - The expiry rules no longer drop a move on a node behind.
  - A transaction is in flight only once sent.
  - Stale Circle signatures and VAAs are renewed.
  - Burns allow Iris's standard fee, at most 10 bps.
  - Panora's splits and integrator fee are checked.
  - `node keeper/restock.mjs --attest <chain> <token>` replaces legacy Portal, closed on 2026-06-30, for the copies
    still to attest (PD-7).

  The mutation gate runs the keeper's node suites since.
- v5 was deployed on Sepolia on 2026-10-26 from `07aeae1`, the build before the RX-3 fix, under a 2-of-3 test Safe;
  its four listings were executed on 2026-10-28, and its zap alone was redeployed on 2026-11-03 from `70ffa6f`, with
  the ether and permit entry points (`docs/deployment.md`, with the addresses). Sepolia runs Glamsterdam
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
  Step 4 followed on 2026-10-31: the mutation gate. `test/mutants/mutants.json` holds 54 mutants as exact edits (the
  state machine's 16, the math's 20, the hub's ten this file lists and eight of the later fixes', the keeper's
  AU-3 among them), `test/mutants/run.py` applies each and requires its suite to fail, and CI's `Mutation gate` job
  runs them all, in about two minutes here. Every one is killed.
- The zap takes ether and permits since 2026-10-29 (the owner's call): `mintWithEth`, `burnToEth`,
  `burnToEthWithPermit` and `mintWithTokenPermit`, the backlog's ETH in and out and one-signature USDC mint, with `WETH`
  a construction argument the deploy script resolves (`abi/IndexZap.json`, the zap's unit and fork suites). Sepolia's
  zap serves them since its redeploy alone on 2026-11-03.
- Only wallets the owner approves create an index (the owner's calls of 2026-11-09 and 2026-11-10, under "Product
  decisions"): the factory's `setApprovedCreator` and `isApprovedCreator`, `CreatorNotApproved` from `createIndex`,
  and mutants F1 and F2. The gate was removed for some hours on 2026-11-10, on the owner's call to reopen creation,
  and restored the same day once it was clear what open creation costs without a price on chain (the design rule "An
  index created off its weights"). The website's create page, and a new Sepolia deployment, since a new factory is a
  whole new deployment, follow.
- **The oracle-free rebalance** was built on 2026-11-10 (the owner's call: "we have to cut off oracles somehow and
  keep rebalance safely"; `design/2026-11-10-oracle-free-rebalance.md` is the spec). What it is:
  - The executor names every component's new units (`executeRebalance(uint256[] newUnits, bytes data)`). The hub reads
    no price. `WeightedMath` checks each leg's unit caps and the weighted gain `Σ w · L(Δunits / units)` against the
    auction's bar, which falls from a half by half every twelve minutes for four hours.
  - `L` is a lower bound of the logarithm, so an accepted fill never lowers the weighted product of the units, a
    constant-weight pool's invariant. At any prices the index is then worth at least `e^(bar − D)` times what it was,
    `D` its distance from its weights there. On its weights nothing can be taken.
  - Gone: Pyth's contract and interfaces, every price id, the price window, the confidence and moving-average checks,
    `μ`, `MIN_TRADE`, every payable entry point of the hub, and `GuardianRelay` (the Safe holds the guardian role
    itself again, since a start carries no update). `audit/2026-11-10-oracle-retirement.md` retires V5-L1, V5-M1,
    V5R-1, DA-01, RB-3, RX-3, RX-18, RX-27, AU-2 and RZ-26 in full and names every re-targeted test.
  - The exact model was rewritten from the spec (426 vectors), the rebalance, state-machine, invariant and security
    suites with it, and the mutants (the arithmetic's 24, the hub's 13): every contract mutant is killed. The hub is
    19,861 bytes, 4,715 under EIP-170. At a hundred coins `createIndex` costs 5.3M gas and a fill 4.2M.
  - The keeper follows. Its executor: `fill(index, newUnits, routes, maxAmountsIn, maxSupply, minUsdcDelta, deadline)`,
    not payable, its suite at 67 passing (`keeper/test/KeeperExecutor.t.sol`). Its bot names the units of its own
    fills (`keeper/bot/units.mjs`: the hub's arithmetic ported word for word and replayed against the 426 vectors,
    and `nameUnits`, the units that clear the bar while leaving the index the least), sends plain starts, leaves alone
    every leg it cannot value, and prices its own trades off chain at Pyth's prices from Hermes, each confirmed by
    Pyth's contract, through a coin-to-id catalogue of its own (`keeper/bot/price-ids.mjs`). Mutants U1 to U4.
  - The fork suites ran in CI on 2026-11-10 (559 tests, none skipped, `a9802b6`, merged as `e93c6b3`), and the
    keeper's end-to-end test passed on a mainnet fork the same day (24 of 24): plain starts, fills on the bar, a late
    fill, stock, the guardian's keep mask.
  - A quote the owner or guardian may post with a start was added the same day (the design rule "A quote can only
    refuse", the spec's section 10): `startRebalance(keepMask, prices, tolerance)`, `rebalanceQuote()`,
    `RebalanceQuoted`, `BelowQuote`, `InvalidQuote`, `WeightedMath.quoteCheck`, 77 vectors in the model, the suite
    `test/WeightedHub.quote.t.sol`, mutants Q1 to Q7 and the keeper's U5. The hub is 21,315 bytes, 3,261 under
    EIP-170.
  - Not done: the app's move to this build (it is converted to `5bbaf3e`, on a branch); a red team of the
    mechanism by reviewers who did not design it; the Halmos harness; a new Sepolia deployment.
    `test/vectors/proofs.py` is rewritten for the new arithmetic: it checks the proof's chain in exact rationals
    (the derivative identity behind `L(x) ≤ ln(1 + x)`, the margin at the cap, every rounding, every second of the
    bar, the amounts), standard library only.
- **Batch fills** were built on 2026-11-11 (the owner's call, after asking why a $100 buyer pays for a swap per
  coin: "then build it"; `design/2026-11-11-batch-fills.md`). No protocol contract changed; the keeper's executor and
  bot did:
  - `KeeperExecutor.fillBatch` fills several requests on one index, in one stablecoin, in one call: the shares the
    redeem requests escrowed go to the mint requests, the executor's own stock of the index's shares covers what they
    do not, and one basket is bought or sold for the difference. A further request costs about 56k gas on the
    three-coin test index, where a fill of its own costs a basket. `fillMint` and `fillRedeem` are unchanged.
  - Shares a batch hands over beyond those it brings in spend `stockAllowance[index]`, which only the owner raises,
    so a stolen keeper key takes no more of the share stock than the owner's figure (CF-1's bound, mutants B1 and
    B2); the float's request allowance measures the batch as a whole, as a single fill's.
  - The bot plans batches before single fills (`batchGroups`, `planBatch`): a request need not pay `MIN_PROFIT_USD`
    alone, the batch must. `SHARE_STOCK_USD`, zero by default, is the share stock it aims to hold per index.
  - Tests: the executor's batch section (78 passing in the suite), `keeper/test/unit/batch.test.mjs`, and
    `keeper/test/harness/requests.test.mjs`, which drives the request filler against a fake chain and is not in CI
    because it imports viem; mutants B1 to B12, all killed.
  - Found on the way, in the bot since the quote (`6c871fb`): its start simulation wrote zero into the hub's
    `quoteProposal` slot, which on an index never started names the auction being simulated, so every first start
    failed with `Panic(50)` and the keeper would not have started a new index's first rebalance. It writes
    `NO_QUOTE_PROPOSAL` now (`test_theBotsNoQuoteValueBindsNoProposal`). Nothing on chain was wrong. With it the
    keeper's end-to-end test passed on a mainnet fork on 2026-11-11 (24 of 24); on `6c871fb` it fails at its first
    start.
  - Not done: the keeper's end-to-end test has no request scenario, so no batch has filled against real pools;
    gasless signed orders and a limit that improves over time (the record's steps 2 and 3); a bot policy that builds
    share stock ahead of demand.
- Before any mainnet: a Hermes plan that serves the keeper its feeds (its price source is its own business now, and
  no contract waits on it); a run of the fork suites; a red
  team of the oracle-free mechanism and an external audit, then `DeployWeighted`'s release hashes fixed at the
  audited commit (CF-5); the 26 attestations and RAY's update; the platform's fee policy and the legal reading. No
  Pyth plan, replay or Hermes settlement is needed any more. The two Universal Router
  files `IndexZap` and `BasketBuilder` compile, `IUniversalRouter` and `UniversalRouterCommands`, are declarations
  of our own since 2026-10-28 (they were copied under GPL-3.0 until then), so every file the four contracts compile
  is ours or MIT-licensed (`NOTICE`).

For more:
- `design/2026-11-10-oracle-free-rebalance.md`: the rebalance's spec since 2026-11-10: the rule, why it is safe,
  the auction, what a fill can take, and what is left.
- `audit/2026-11-10-oracle-retirement.md`: the review ids that went with Pyth, and every re-targeted test.
- `design/2026-10-05-custom-weights.md`: the v5 spec; its sections on Pyth describe the design that was replaced.
- `audit/2026-11-02-external-audit-package.md`: the external auditors' brief: the candidate commit, the scope, the
  roles, the properties, where to look first, and every earlier review's open ids.
- `design/2026-10-29-rebalance-state-machine.md`: the rebalance's eight states, the transition matrix, the clock's
  boundaries and the invariants, with the test and the mutants that pin each cell.
- `design/2026-10-29-settlement-vectors.md` and `design/2026-10-29-settlement-proofs.md`: the model, vectors and
  z3 proofs of the arithmetic that priced by Pyth, retired on 2026-11-10; the method is the one the new model keeps.
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
python3 -I test/vectors/proofs.py  # the proof's chain behind the settlement, checked in exact rationals (11 s, no dependency):
                             # rerun it after any change to the model
aderyn .                     # Aderyn on src/, configured by aderyn.toml: must report nothing; CI does not run it
python3 -I test/mutants/run.py  # the mutation gate: every mutant of test/mutants/mutants.json must be killed (CI runs it);
                             # --only M3,V8 runs some, --check only that every edit still applies; a mutant with
                             # "runner": "node" names a keeper/test/unit suite instead of a forge one
for c in IndexZap BasketBuilder MintRequests WeightedIndexFactory WeightedHub; do forge inspect $c abi --json > abi/$c.json; done  # after an ABI change
forge test --root keeper     # the keeper's executor, its own Foundry project; CI also runs its fmt, build and lint
node --test keeper/test/unit/*.test.mjs  # the keeper bot's arithmetic, unit naming, settings, Hermes client and tx tracker (no dependency)
node --test keeper/test/harness/*.test.mjs  # the request filler against a fake chain; needs `npm ci` in keeper/ and the executor's build; not in CI

# mainnet fork tests (real tokens, Universal Router, V3 and V4 pools); skipped when the env var is unset.
# A rate-limited RPC throttles five suites in parallel: add -j 1.
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# public non-archive RPCs only serve recent state: pin near the head
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=$(( $(cast block-number --rpc-url https://ethereum-rpc.publicnode.com) - 8 )) forge test --match-path 'test/fork/*'

# the admission check, read-only, before any listing: one report per token for the Safe's signers
CHECK=wide forge script script/CheckToken.s.sol --fork-url $MAINNET_RPC_URL
```

Deployment, once, on Ethereum: `script/DeployWeighted.s.sol`, which gives the guardian role to the guardian's Safe,
then `script/ConfigureWeighted.s.sol`, which lists each coin of `script/Listings.sol`; the owner then approves the
wallets that create indexes (`setApprovedCreator`), and nobody can create one before. `script/CheckToken.s.sol` reports on every token before its first
listing; `V5_WHITELIST=default` is the first four coins and `V5_WHITELIST=wide` the rest, 91 in all. On chain 1 the
deploy script resolves the router, WETH and the stablecoins from the address book and refuses any other address
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
   router- or pool-related. Their summary must list the five Ethereum
   `test/fork/` suites and 0 skipped. `WeightedHub.fork.t.sol` alone takes about an hour at the 91-coin list on an archive RPC
   (Alchemy, Tenderly), nearly all of it the admission quotes on a cold RPC cache; a public endpoint prunes the state
   before it ends. They are also required when the deploy checks or `script/MainnetAddresses.sol` change, which
   `MainnetAddresses.fork.t.sol` and `Security.fork.t.sol` exercise.
5. The Wake VS Code analyzer reports no errors or warnings on `src/`. Its reentrancy detector does not model reentrancy
   guards; the documented suppressions are on the `redeem` call in `IndexZap._burnBasket`, the `permit` call in
   `IndexZap._tryPermit`, the `redeem` call in `BasketBuilder.redeem`, and the clone's `initialize` call in
   `WeightedIndexFactory._initializeIndex`, which the creation fee's transfer now follows. v5 adds the executor callback in `WeightedHub`.
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
     test's eleven entry points.
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
     `test/WeightedHub.fees.t.sol`, and `test_AU3_...` in `keeper/test/KeeperExecutor.t.sol`; AU-2's tests went with Pyth
     on 2026-11-10.
   - The red teams of 2026-10-31: `RY-1`..`RY-9` (`audit/2026-10-31-red-team.md`) and `RZ-1`..`RZ-33`
     (`audit/2026-10-31-red-team-ii.md`), both drafted with `RT` ids, which the red team of 2026-09-24 holds. A test
     named `test_RY1_...` in `test/IndexZap.t.sol`, `test_RZ23_...` in `keeper/test/KeeperExecutor.t.sol`,
     `test_RZ24_...` in `test/Scripts.t.sol` (RZ-26's, in `test/GuardianRelay.t.sol` and `test/Scripts.t.sol`, went
     with the relay on 2026-11-10), and node tests named `RY-6, RZ-1: ...`, `RZ-2, RZ-22: ...`, `RZ-5: ...` and
     `RY-8: ...` in `keeper/test/unit/` (RZ-26's went with the relay too), RY-8's with its mutants Y1 and Y2. Each record's
     "Status of the fixes" names every test; the ids fixed by documentation, the open ones and the keeper's wiring
     without a unit harness have none.
   - The protocol documentation review of 2026-11-01: `PD-1`..`PD-14` (`audit/2026-11-01-protocol-docs-review.md`),
     node tests named `PD-1: ...` in `keeper/test/unit/` (the restock's Solana, Sui, Aptos, in-flight, journal,
     attestation, advance, attest and signer-home suites), each with its mutants P1 to P24 in
     `test/mutants/mutants.json`. The record's "Status of the fixes" names every test; PD-14, a dashboard setting, is
     fixed by documentation alone.
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

   Seven records list the ids whose mechanism is gone, with the test that went and the property, if any, that survives:
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
   - `audit/2026-11-10-oracle-retirement.md`: the removal of Pyth for the oracle-free rebalance. It retires V5-L1,
     V5-M1, V5R-1, DA-01, RB-3, RX-3, RX-18, RX-27, AU-2 and RZ-26 in full, and names the test of every re-targeted id
     (V5-I4, V5-M2, V5-L2, RX-15, R04, R14, R08 and their neighbours).

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

`ls` and each file's header comments show what lives where, and README.md's Repository structure gives the tour. Two things
the tree does not say: `script/testnet/` (the Sepolia test market) never deploys to a mainnet; and `keeper/` is the keeper bot with its executor contract, a Foundry project of
its own with its own tests (`keeper/README.md`): it starts and fills auctions, fills `MintRequests` requests at their
limits (since 2026-10-16), serves coins without a Uniswap route from the executor's stock, and holds no role in the
protocol. Anyone may run one; its key is the keeper's own hot key, never
the owner's or the guardian's. Its restock service (`keeper/restock.mjs`, `keeper/restock/`) runs beside it with the
treasury's key, also never the owner's or the guardian's. Its invariant checker (`keeper/invariants.mjs`,
`keeper/invariants/`, since 2026-11-01, the logic-hardening plan's step 6) holds no key: it reads every index, `MintRequests`
and the basket builder each round and reports any property that does not hold, the hub's invariant on the recorded
units and scale it reads from storage (`HUB_STATE_SLOTS`, pinned by `test_theCheckersHubSlotsAreTheHubs`) among them.

Deleted on 2026-10-13 as unused, and recoverable from git at `f83dcab`: the v4 hackathon demo (`demo/`), the reviews'
PoC tests (`audit/poc/`, which the audit records still cite), v4's market-cap analysis scripts (`design/analysis/`), the
v4 architecture PDF with its builder (`design/build_pdf.py`), the BNB Chain deployment (`script/BnbChainAddresses.sol`,
its list and fork suite), and the design records of retired designs and research (v4's hybrid architecture, Stage B's
spec and interfaces, Stage C, the chain and L2 research, the hackathon plan, the two-chain decision), which the audit
records also cite. Deleted on 2026-11-09 for the same reason, and recoverable from git at `922da1d`: the probes of the
red teams of 2026-10-31 (`audit/poc/`, which their records cite) and the source of the flow video (`docs/video/`).

## Design rules that must not be broken

- **Nothing reads a price.** No contract reads a feed, a pool's price or an oracle, by any name: not a
  rebalance, not an issue, a redeem or a claim (`test_V5I4_noContractNamesPyth`, `test_A713_noContractReadsAPrice`).
  A rebalance is safe on units alone. So no feed can block an exit, misprice a mint or set the terms of a
  rebalance, and nobody's keys stand between the holders and their coins. Do not make the design's safety depend on
  a price: it needs none. Valuing an index is the app's job, off-chain. The zap swaps, but it reads no price either:
  it enforces the limits its caller sets.
- **A quote can only refuse.** The one place a price enters a contract is the quote the owner or guardian may post
  with a start (`startRebalance(keepMask, prices, tolerance)`, the owner's call of 2026-11-10, after Reserve's price
  ranges): prices of the caller's own, fixed at the start, never read from anywhere. A fill of that proposal must
  clear the bar as any fill and must also bring in, at those prices, at least `1 − tolerance` of what it takes out
  (`WeightedMath.quoteCheck`, `BelowQuote`). Both checks must pass, so a quote that is wrong, stale or hostile can
  only stop its own proposal from filling, which a cancel already can; it can make no fill worse than a start
  without one allows. Keep it that way: never let a quote accept a fill the bar refuses, replace the bar, outlive
  its proposal (mutant Q2), or reach an issue, a redeem or a claim. What it buys: a lone executor keeps at most the
  tolerance of what it trades, not the index's distance from its weights. Its limits: a stranger's start carries
  none, so the guardian replaces such a proposal within its six hours; and the tolerance has to cover six hours of
  market, or the proposal expires unfilled (the spec's section 10).
- **The executor names the units, and the index checks a gain.** `executeRebalance(newUnits, data)` settles at the
  units its caller names. `WeightedMath` accepts them when every leg is inside its unit caps and
  `⌊Σ w_i · L(x_i) / 10,000⌋ ≥ bar`, with `x_i` the leg's relative change in units, rounded down, and
  `L(x) = x − x²/2 + x³/3 − 3x⁴/10`, rounded down. `L(x) ≤ ln(1 + x)` on `[−0.2, 1]`, so an accepted fill never
  lowers the weighted product of the units, and at any prices the index is worth at least `e^(bar − D)` times what
  it was, `D` its distance from its weights at those prices (`design/2026-11-10-oracle-free-rebalance.md`, section
  3). Do not replace `L` by anything that can exceed the logarithm on the capped range, nor widen the caps past the
  range the lemma covers: the margin at `x = −0.2` is three millionths.
- **The bar is on the whole index's gain.** It starts at `BAR_MAX` (a half), halves every `BAR_HALF_LIFE` (12
  minutes) along a straight line, rounds up, and never reaches zero. Do not turn it into a premium on the traded
  amount: with the executor choosing the trade, a premium is won by the smallest trade, and the index would never
  rebalance. A fill that changes nothing has no gain, so none can restart the rebalance interval for free (V5-L2).
- **A fair price needs a bidder, and without one the holders lose the distance.** Executors compete by filling
  earlier, at a higher bar. With an honest one bidding, ours first, holders lose only its costs. A lone executor at
  the last second takes the index's distance from its weights out of the holders' value: what a fee-less
  constant-weight pool loses to arbitrage, and no more (the spec's Theorem 2). On the exact model that is 0.48% of an
  index after one coin of four rose a quarter, 5.0% in one fill after one coin of two doubled, 8.7% after it tripled.
  Say so wherever the design is described: do not call it harmless or "never the holders' principal", as the first
  records of 2026-11-10 did, and do not claim the price is fair without a bidder.
- **An index created off its weights can be drained by its creator, so only approved wallets create.** Units and
  weights are the creator's to name, and no contract can compare them without a price. A creator can name units far
  from the weights, let others mint, and fill its own auction at the last second: 15.5% of a 50/50 index created
  90/10 by value in one fill, and at the worst a fifth of an index per fill, every interval. On chain only
  `MAX_TURNOVER` bounds it. That is why `createIndex` is open only to wallets the owner approved (restored on
  2026-11-10 for this reason): do not reopen creation without an answer to this. The team creates on the weights, at
  the app's prices, and the app still shows every index's coins against its weights: an approved wallet that named
  units off them would make such an index all the same.
- **Weights and constituents are fixed at creation,** two to a hundred components, so no listing or delisting
  reaches an existing index. The CREATE2 salt commits to every component's token, units and weight, and to the
  index's config: its fee rates, referral share and rebalance interval
  (LR-05: never switch back to CREATE). The gate and the listing flag are not terms of the index and not in the salt.
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
- **An empty index does not rebalance.** Without shares a fill has nothing to trade and reverts
  `NothingToRebalance`, so nobody moves an empty index's units for nothing (R14, XA-27). A dust index's units can
  still be walked by whoever holds its shares, each fill a gain that costs nothing on a supply worth nothing: a
  known limitation, which the app answers by showing an index's coins against its weights.
- **A collapsing coin is still bought.** Fixed weights keep buying it, at most doubling its units per fill (RX-15),
  and units beyond `uint96` stop the fill rather than wrap, the preview with it (RX-61), until the guardian keeps it
  (V5-L3, a known limitation).
- **An issuer's corporate action is not accounted for.** Units are fixed per share and amounts come only from supply
  and units, so tokens an issuer mints to holders, as a split paid in tokens would be, stay in the index owned by no
  share, and a burn leaves that leg below its backing; a token that stops being one share misprices a leg priced at the
  share's feed (CF-3, a known limitation). Do not add a path that pays out balances to cover it. What the hub does
  check: issue refuses while a leg's balance is below the backing of the shares already issued plus its open claims, as
  after an issuer burned the index's balance, so no new deposit refills the hole for earlier holders (RX-8); and a fill
  that grows a leg must leave the index able to send that leg, measured by sending itself one raw unit, so a token that
  blocks only its sender, as Tether Gold's does, cannot have good legs moved into a leg nobody can take out (RX-12).
- **The notice is 2 hours.** `WeightedHub`'s `REBALANCE_DELAY` is 2 hours: the notice is for executors, not for
  holders' exits. `AUCTION_DURATION` is 4 hours, the bar's twenty halvings; the math's must equal the hub's
  (`test_theMathConstantsAreTheHubs`). The
  rebalance interval is the index's own, chosen at creation within [`MIN_REBALANCE_INTERVAL`, `MAX_REBALANCE_INTERVAL`]
  = [7, 91] days (the website's weekly to quarterly cadences; V5R-I2 set the floor). A fill with a keep mask restarts
  only `MIN_REBALANCE_INTERVAL`, for any start (`earliestRebalance()`, XS-3): a guardian's sliver cannot hold the index
  off for a quarter, and a keep can be renewed a week on. The cost, accepted: the owner or
  guardian can run keep-mask fills weekly on a quarterly index, each within the unit caps and above the bar. A cancel, or an auction that
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
  - The owner approves which wallets may create an index (`setApprovedCreator`, at once); `createIndex` from any
    other reverts `CreatorNotApproved`. The approval is read at creation and nowhere else: an approved wallet is
    bound by the whitelist and the fee caps, it has no power over an index's funds, and withdrawing an approval
    reaches no index that exists. The creator role of an index still moves to any account, approved or not
    (`test_theCreatorRoleMovesToAnAccountThatWasNeverApproved`). Do not let the approval gate an issue, a redeem, a
    rebalance or the handoff.
  - The guardian can: cancel pending listings; delist; cancel a rebalance; start one with a keep mask; start one before
    strangers may; and cancel a guardian change that would remove the role. It cannot block its own replacement.
  - The guardian is the guardian's Safe itself. `GuardianRelay` (RZ-26, 2026-11-02) existed because a start carried
    a Pyth update valid for one slot, which a Safe cannot land; a start is a plain call since 2026-11-10, and the
    relay is deleted.
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
  - **Listings.** A listing records a token's decimals, read from the token when it is proposed; they only bound
    the units an index may start with (`maxUnitsOf`). A relisting reads them anew and reaches only indexes created
    after it. A live listing excludes a second for the same token (`ListingPending`).
- **Only initialized clones issue, redeem or rebalance.** Keep the `onlyInitialized` guard on every function that mints,
  burns or touches a rebalance.
- **Executors are untrusted.** Tokens and the callback go only to `msg.sender`, every mutating entry point shares the
  reentrancy guard, and state is written before any rebalance transfer. `executeRebalance(newUnits, data)` settles
  the units named at whatever the supply in the settling block requires. The
  `executeRebalance(newUnits, data, maxAmountsIn)` overload bounds that, and
  reverts `RebalanceMovedOn` when the settlement has grown past what the caller will deliver. Issue stays open through
  notice and auction, so a dust issue can grief an executor sized from an off-chain simulation: the callback arguments
  are authoritative (DA-13). At `MAX_COMPONENTS` (100), every path of the hub and the factory fits a transaction under
  EIP-7825's 2^24 gas cap on mock tokens (`test_aHundredComponentsFitOneTransaction`): `createIndex` about 5.3M,
  `redeemSkipping` with every component skipped 5.1M, a fill 4.2M with an executor that holds the tokens; a start
  with a quote 1.4M, and a fill under one 4.4M. Real tokens
  transfer dearer, and swaps for 100 legs do not fit, so an atomic fill that wide needs an executor that already
  holds the tokens.
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
    undecided. Sepolia's zap serves these entry points since its redeploy alone on 2026-11-03.
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
  The policy wants 6 to 18 decimals, which matter only to display and to the unit cap at creation. The admission check is
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
  listing its mutants. Every one of them is committed as exact edits in `test/mutants/mutants.json`, which CI's
  mutation gate runs (`test/mutants/run.py`): a fix to a finding adds its mutant there, with the suite that kills it,
  and a change to the code a mutant edits updates that mutant's edit in the same commit, since a stale edit fails the
  gate. Apply a mutant to a byte copy and restore the copy, never `git checkout` (the runner does both); grep a
  failing test as `\[FAIL.*\] (test_\w+)\(\)`, since a failure's message can print a bracketed number; and build
  once after.
- **Tests.**
  - One `*.t.sol` per contract; the hub's rebalancing, its rebalance state machine (`test/WeightedHub.states.t.sol`,
    the matrix of `design/2026-10-29-rebalance-state-machine.md`) and its invariants have their own files, and so do
    the invariants of `MintRequests`.
  - The settlement vectors live under `test/vectors/`: `settlement.py` is the exact model and the seeded generator,
    `settlement.json` its output, and `test/WeightedMath.vectors.t.sol` replays it through `vm.readFile` (the folder
    is in `fs_permissions`), never `ffi`. A change to `WeightedMath` regenerates the file in the same commit, and a
    change to the arithmetic's rules changes the model first, then reruns `proofs.py`, which checks the proof's
    chain on the model in exact rationals (`design/2026-11-10-oracle-free-rebalance.md`, section 3). `test/WeightedMath.halmos.t.sol` is a Halmos harness: its
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
  - `OWNER` and `GUARDIAN` are required, on each chain. `GUARDIAN` is the guardian's Safe, which controls the relay the
    script deploys as the factory's guardian; the guardian rules below read it.
  - On a mainnet the owner must be a contract that is not an EIP-7702 delegated account. A Safe owner must need at least
    `MIN_OWNER_THRESHOLD` (3) signatures, the design's 3-of-5 (the owner's call on 2026-09-30), and have no enabled
    module. Any other contract, such as a timelock, is refused unless the operator sets `OWNER_IS_NOT_A_SAFE` to that
    owner's address (A7-08): the script cannot tell who signs for it. An acknowledgment names its owner, so a stale one
    acknowledges no other, and none lowers a Safe rule.
  - When the owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers (SA-06).
  - Neither role may be a market contract: the router and the PoolManager, and on a mainnet every token and mint
    currency in the address book (CR-I37).
  - On chain 1 the market addresses are the address book's and nothing else (`MainnetOverride`); elsewhere they come
    from the environment.
  - On chain 1 `deploy` broadcasts only the build `DeployWeighted`'s `FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH`,
    `BUILDER_INITCODE_HASH` and `REQUESTS_INITCODE_HASH` record (`BuildNotReleased`, CF-5). A
    change to `src/`, a dependency or the compiler settings fails `test_CF5_theReleaseHashesAreThisBuilds` until those
    four are set to the values it prints, in the same commit. The test stops at the first mismatch; `cast keccak` of
    each artifact's `bytecode.object` gives all four. `foundry.toml` keeps `auto_detect_remappings = false`: the detected remappings
    carry the checkout's absolute path into the metadata, so the hashes differed between machines and CI. After
    changing `foundry.toml`, rebuild with `forge build --force`, since the cache can keep the old artifacts.
- **Mainnet addresses** are verified on-chain before being committed: tokens by symbol and decimals, and the router
  and the PoolManager by their runtime code hashes, since every Universal Router build answers `poolManager()` alike
  (CR-I35). `test/fork/MainnetAddresses.fork.t.sol` checks `script/MainnetAddresses.sol` that way and lists both lists
  on a fresh factory, and `test_CRL08_theListsAreTheReleaseRecord` pins every list's addresses
  against a table written independently of them. The WBTC
  address is `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`; an earlier draft had a wrong one. A Wormhole copy of a
  Binance-Peg coin the app labels Custodial. `script/PythIds.sol` holds each coin's Pyth id for the keeper alone,
  which prices its own trades off chain; no contract or script reads it.

## Product decisions already made (do not re-litigate silently)

**No oracle** (the owner's call of 2026-11-10: "we have to cut off oracles somehow and keep rebalance safely", then
"yes build oracle free rebalance"). No contract reads a price. An index still rebalances toward its fixed percentages,
through an auction in which the executor names the units and the index checks a gain in units against a falling bar
(`design/2026-11-10-oracle-free-rebalance.md`). The owner's reason: "there are too many hacks nowadays", and this
"will be really big step towards security". What it removes: three of Pyth's five keys could take a fifth of every
index per fill. What it costs, said to the owner before the build: a fair price now needs an honest executor bidding, ours first, where Pyth gave one whoever filled;
a lone executor keeps the index's distance from its weights (0.3 to 0.6% in an ordinary week), which was described
then as the rebalance's proceeds and never the holders' principal. That description was wrong, and was corrected the
same day: the distance comes out of the holders' value, and it is about 5% after one coin of two doubles (the design
rule above has the figures). It supersedes "Pyth is the only oracle" of 2026-10-05 and "leave
rebalance as it is" of 2026-11-10, both below, and with them the guardian relay of 2026-11-02, the Pyth plan, the
replay and the US-hours limits on stock legs. Dropping rebalancing for fixed amounts per token stays not taken.

**A quote with a start** (the owner's call of 2026-11-10, after reading how Reserve's Index DTFs rebalance: "lets add
it to our contracts"). The owner or guardian may post prices of their own with a start, and a fill of that proposal
must then also bring in at least `1 − tolerance` of what it takes out at those prices. It amends "No oracle" above in
one respect, said to the owner before the build: a price now enters a contract, from the owner or guardian and only to
refuse a fill; no feed, oracle or pool is read, and the index's safety still rests on units alone, since a fill must
pass both checks. What it buys: a lone executor keeps at most the tolerance of what it trades. What it does not: a
stranger's plain start carries no quote, and a quote goes stale over the six hours of a proposal. A hot key that
narrows prices before each auction, as Reserve's launcher does, was not taken.

**Only the team creates indexes** (the owner's calls of 2026-11-09 and 2026-11-10): the factory refuses `createIndex`
from any wallet its owner has not approved, and the site lists the team's indexes. The call was made twice. First on
2026-11-09 and 2026-11-10, because open creation was hard to manage and a risk to the name: a stranger's look-alike
index under our factory, served by our zap at the fee caps; a guardian and a keeper whose work grows with every index
anyone makes; and creation spam at a creation fee of zero. Reserve's way, an open contract behind a curated app, was
considered and refused once it was clear strangers could still create on chain. On the afternoon of 2026-11-10 the
owner reopened creation ("everyone can create an index on our website"), and the gate was removed. That evening a
fourth cost was put to the owner, found only after the oracle-free rebalance was built: with no price on chain, a
creator can make an index far from its weights and drain it through its own auctions, up to a fifth a fill. The
owner's answer: "that mean everyone creating index is bad. ok lets move to our old plan that only xindex team can
create and list indexes on our website". The gate is back, and reopening creation needs an answer to that cost first.
A partner asks the team: the site's create page is the wizard for approved wallets and a contact link for everyone
else. The team creates the index and hands the partner the creator role, with its fee (`transferCreator`,
`acceptCreator`). It changes nothing about funds, token issuers, Wormhole or the rebalance; it makes the team the
issuer and gatekeeper of every index, which counsel's reading must cover. It supersedes "no team index" of
2026-10-06, below. Dropping rebalancing for fixed amounts per token, discussed on 2026-11-10, was not taken.

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
weights are fixed at creation; the index rebalances to them. Its oracle, Pyth, was removed on 2026-11-10 (above); what
follows in this paragraph is the call as it was made. Pyth is the only oracle: Chainlink alone,
and Chainlink as a second check on the coins it covers, were both refused. v5 is custom percentages only. Its
parameters (section 8 of the spec) wait on a replay of Pyth's history, and Hermes needs a paid API key, an operating
cost the owner weighs before launch.

**The listings** (the owner's calls on 2026-10-06):
- No team index at launch: creators make every index, so "flagship" names no product. Superseded on 2026-11-10: the
  team creates every index (above).
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
