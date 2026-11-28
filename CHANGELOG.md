# Changelog

What changed in Xindex, and when. The documentation describes the protocol as it is; this file keeps the history: the
versions, what each step built, found and fixed, and every product decision with the words it was made in. Newer
entries come last in each section. Each design record under `docs/design/` and each review under `audits/` is cited
where it was made.

## Versions

| Version | Design | Record |
|---|---|---|
| v2 | A market-cap index with on-chain rebalancing, priced from Uniswap V3 pool averages. | |
| v3 | Prices from Chainlink USD feeds; swaps through Uniswap's Universal Router. Tagged `v3.0.0`. | [`audits/retired/v3.md`](audits/retired/v3.md) |
| v4 Stage A | No prices at all: units proportional to reference supplies, so an index trades only when a supply changes. | [`audits/retired/v4-stage-a.md`](audits/retired/v4-stage-a.md), [`audits/retired/v4.md`](audits/retired/v4.md) |
| v4 Stage B | Other chains' native coins in ownerless vaults driven by proofs of Ethereum's finality. Tagged `stage-b-2026-10-07`. | [`audits/retired/stage-b.md`](audits/retired/stage-b.md) |
| v5 | Creator-chosen weights, rebalanced at Pyth prices through a Dutch auction; one deployment on Ethereum, other chains' coins held as Wormhole copies. Its issue, redeem, fees and listings are the current design's. | [`docs/design/custom-weights.md`](docs/design/custom-weights.md), [`docs/design/wormhole-legs.md`](docs/design/wormhole-legs.md) |
| A second deployment | Since 2026-11-13 the same contracts are deployable on BNB Chain as on Ethereum, each chain holding its own tokens in kind and sharing nothing with the other. The BNB Chain deployment of 2026-10-07, deleted on 2026-10-13, restored without Pyth. | [`docs/design/bnb-chain.md`](docs/design/bnb-chain.md) |
| A third deployment | Since 2026-11-21 the same contracts are deployable on Base: sixteen coins, thirteen of them copies Base's own bridge mints of coins on Ethereum's list. It reverses "no Base deployment for now" of 2026-10-18. | [`docs/design/base.md`](docs/design/base.md) |
| Oracle-free rebalance | Since 2026-11-10 no contract reads a price: an executor names the units a rebalance settles at, and the index accepts them when a weighted gain in units clears a bar that falls with time. Pyth left the protocol, and came back on 2026-11-22 only as a check that can refuse a fill (the row below). The units' rule is still the current design's. | [`docs/design/rebalance.md`](docs/design/rebalance.md), [`audits/retired/oracle.md`](audits/retired/oracle.md) |
| Pyth's check, creation on the weights, changeable weights | Since 2026-11-22 a fill the units accept must also hold at Pyth's prices, a check that can only refuse; since 2026-11-23 an index is created within 5% of its weights at those prices, its creator can change the weights behind 7 days of notice, creating an index can issue its first shares in the same call (`createAndIssue`), and the owner or guardian may restart a rebalance a week after any fill. No mint, redeem or claim reads a price. The current design. | [`docs/design/pyth-check.md`](docs/design/pyth-check.md), [`docs/design/changeable-weights.md`](docs/design/changeable-weights.md) |
| A fourth deployment, in development | Since 2026-11-28 a Solana program, `solana/`, issues and redeems indexes in kind through tickets, its list to be Ondo's Token-2022 tokens. It reverses "Not planned: a Solana deployment" of 2026-10-07. The rebalance and the rest are not ported yet. | [`docs/design/solana.md`](docs/design/solana.md) |

`WeightedHub` keeps v4's in-kind issue, redeem, claims and backing check; the zap and `MintRequests` carried over
unchanged. Each retirement record lists the review findings that went with the retired code and where the rest are
tested now. The brief Xindex was built from is in [`docs/product-brief.md`](docs/product-brief.md).

## History

Each entry describes the build as it then was: those before the oracle-free rebalance describe the Pyth-priced
rebalance it replaced, and the later ones what was built on it and found in it.
- The weighted index is built and reviewed twice (`audits/internal/v5-review.md`, `audits/internal/v5-logic-review.md`).
- The Ethereum deployment's scripts are built: `DeployWeighted`, `ConfigureWeighted` over `PythIds`, `CheckToken`.
- The hundred-coin list is built as far as Ethereum holds it: 93 listed on 2026-10-10 (the 49 of before, 31 more
  Ethereum-issued coins and 13 Wormhole copies that already existed, every one through `CheckToken` on a fork), and
  93 since DOGE's copy left on 2026-10-14, and on 2026-10-18 the copies of BNB, SUI and SEI, found already attested,
  joined and SAND and RLB left; on 2026-10-19 BTT and SEI's copy left, 91 in all, 73 of them coins that count toward
  the hundred; on 2026-11-13 the six copies wrapped from BNB Chain left, 85 in all; on 2026-11-18 the copies of JUP,
  PYTH, SUI, APT and ALGO left, 80 in all, 62 of them coins that count toward the hundred. 26 copies await an attestation on Wormhole's Portal (the queue of 31 less USX and CASH, stablecoins,
  BP, an exchange's token, S, which Wormhole does not serve, and FIL, held until its Binance-Peg source passes a
  source reading: RX-11, RX-20, RX-35, RX-64), a
  transaction on each home chain the owner sends (section 2a of the 2026-10-10 record lists them with the procedure,
  section 3 of `docs/design/pre-mainnet-readings.md` what is left); each then goes through the check and the
  lists. A hundred-coin index is minted in kind or through `MintRequests`, since the zap
  stops near 35 legs. On a fork of 2026-10-11, the 92 coins forge-std can fund issue, rebalance with real transfers
  and redeem in one index, and 45 of them trade through the zap within 2% on $1,000; SNX is out of that test only
  because its balances live in its `TokenState`, beyond forge-std's `deal`. That test's 14.9M gas for the fill counts
  its executor's own `deal` calls; on an anvil fork of 2026-10-12, with Pyth's real contract verifying an update signed
  by keys the test installed in Pyth's receiver, a fill of 93 legs cost 7.26M, Pyth's parse 2.34M of it.
- The engine the website needs was built on 2026-10-14 from the clean-sheet research record
  (`docs/design/fees-builder-requests.md`): fees in shares (creator, platform, referrer), a rebalance interval
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
  AERO); ATOM has none on BNB Chain, and JUP, PYTH, SUI, APT and ALGO wait for their chains' adapters. Since
  2026-11-13 it serves AVAX, OP and AERO by default: the five BNB Chain coins' copies left Ethereum's list that day.
- The security audit of 2026-10-13 (`audits/internal/security-audit-cf.md`, Cloudflare's security-audit skill, ids
  `CF-1`..`CF-8`) found no exploitable path in the four contracts that hold index funds; its findings in the keeper,
  CheckToken, the deploy script and CI are fixed, CF-3 is a known limitation below, and CF-2 and CF-8 went with the
  THORChain planner on 2026-10-14 (`audits/retired/thorchain.md`).
- The security audit of 2026-10-16 (`audits/internal/security-audit-xs.md`, ids `XS-1`..`XS-18`) reviewed the engine
  of 2026-10-14 to 16. Its findings are fixed: the streaming fee's clock restarts on every accrual (XS-1), a settlement
  keeps the scale rather than folding it into floored units (XS-2), a keep-mask fill restarts only
  `MIN_REBALANCE_INTERVAL` for a start without a mask (XS-3), the builder checks its way out before crediting an escrow
  (XS-10), and the keeper's five medium findings and three low ones are fixed in `keeper/`.
- The readings of 2026-10-18 (`docs/design/pre-mainnet-readings.md`): OP-PIP-132 is read (three of Pyth's
  five keys sign any price and any upgrade of its contract, and Hermes is a paid data plan), Ondo's corporate-action
  mechanism is read (CF-3: a multiplier of shares, never a balance change), the five fork suites ran again (CF-4's
  SAND pin among them), and the tokens listed on 2026-10-10 had their source read
  (`docs/design/token-source-reading.md`, CF-4). The owner's calls on it: SAND and RLB delisted, H, PLUME, SNX,
  SYRUP, GALA and MANA kept, and the twelve Ondo legs priced at their share's feed kept under the procedure of CF-3.
- The red team of 2026-10-18 (`audits/internal/red-team-rx.md`, ids `RX-1`..`RX-67`) found no path that takes funds
  from holders or escrows outside the documented bounds. Its findings were fixed on 2026-10-19, the owner's call to
  "fix every finding": in the hub a leg's growth per fill is capped (RX-15), a price far from its own moving average
  is refused (RX-27), a leg a fill buys must be able to leave (RX-12), and issue refuses a leg below its backing
  (RX-8); in the factory units are capped in whole tokens (RX-5) and the creator role is handed on in two steps
  (RX-22); in the keeper, request fills are verified, bounded and pinned (RX-1, RX-2, RX-4, RX-9, RX-10), and the rest
  are documented. RX-3, documented then, was fixed in the hub on 2026-10-26 after an outside reviewer raised it again
  (the owner's call): a start reads every moving feed, and the auction is 4 hours (`test_RX3_...`).
- The review of 2026-10-31 (`audits/internal/review-au.md`, ids `AU-1`..`AU-3`) found no high or medium finding. Its
  three are fixed: a gated index no longer pays a referrer its gate would refuse (AU-1), `previewRebalance` takes
  Pyth's feeds and refuses a price far from its average, as the fill does (AU-2, an ABI change the keeper bot follows),
  and the keeper's redeem fill reads balances after paying the stablecoin (AU-3). The hub is 98 bytes under EIP-170.
- The red teams of 2026-10-31 (`audits/internal/red-team-ry.md`, ids `RY-1`..`RY-9`; `audits/internal/red-team-rz.md`,
  ids `RZ-1`..`RZ-33`) found no path that takes holders' funds. Fixed on 2026-11-01: the request filler had valued
  nothing since RX-9's fix, and the restock's RY-6 fix would have stopped it, because viem returns Pyth's parse
  unwrapped (RZ-1); the restock's halving never quoted (RZ-2); stock left the needs board the moment it landed (RZ-3);
  the keeper values only prices Pyth's contract confirms, previews included (RY-7); the zap refuses WETH and the
  call's own token as recipients (RY-1; its WETH half went with the ether entry points on 2026-11-18); BNB joined the restock (RZ-5). The owner's calls of 2026-11-02 on the four
  left open:
  - A start must land in one slot, which a Safe cannot time (RZ-26): the guardian is a `GuardianRelay` its Safe
    controls, which `DeployWeighted` deploys; the Safe authorizes a start and anyone, the keeper first, sends it.
  - A collapsed leg stops the fills far sooner than was documented (RZ-4): the stop stays.
  - Issue does not probe a frozen leg (RZ-25): the app checks before it offers a mint; the hub is unchanged. (The
    hub makes the probe itself since 2026-11-14, RW-8.)
  - A need reaches the restock only for a fill that could pay `MIN_PROFIT_USD` at its best price (RY-8).
  - RY-3's self-referral waits for the fee policy (found again as RW-4 on 2026-11-14, and still waiting).

  The fork suites ran on the zap's change in CI on 2026-11-02 (`f2f4c18`): the five suites' 45 tests, 0 skipped.
- The protocol documentation review of 2026-11-01 (`audits/internal/protocol-docs-review-pd.md`, ids `PD-1`..`PD-14`)
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
- The rebalance state machine is written down (`docs/design/rebalance-state-machine.md`, 2026-10-29, step 1
  of the logic-hardening plan): eight states, the matrix of every action from each, the clock's boundaries and six
  invariants, with `test/WeightedHub.states.t.sol` taking every cell and 17 mutants of the hub checked against it.
  The hub did not change. Step 3 followed the same day (`docs/design/settlement-vectors.md`): an exact-rational
  model of the settlement written from the spec (`test/vectors/settlement.py`, standard library only) generates
  375 vectors (`test/vectors/settlement.json`) that `test/WeightedMath.vectors.t.sol` replays against
  `WeightedMath.settlement` word for word, every outcome and every cap among them; the 19 mutants of the math all die, two of them only on legs priced at
  one quantum of value. The math
  did not change either. Step 2 the same day (`docs/design/settlement-proofs.md`): Halmos could not finish the
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
- The zap took ether and permits from 2026-10-29 (the owner's call): `mintWithEth`, `burnToEth`,
  `burnToEthWithPermit` and `mintWithTokenPermit`, the backlog's ETH in and out and one-signature USDC mint, with `WETH`
  a construction argument the deploy script resolved. Sepolia's zap serves them since its redeploy alone on
  2026-11-03. The ether entry points were withdrawn on 2026-11-18 (below); the permits stay.
- Only wallets the owner approves create an index (the owner's calls of 2026-11-09 and 2026-11-10, under "Product
  decisions"): the factory's `setApprovedCreator` and `isApprovedCreator`, `CreatorNotApproved` from `createIndex`,
  and mutants F1 and F2. The gate was removed for some hours on 2026-11-10, on the owner's call to reopen creation,
  and restored the same day once it was clear what open creation costs without a price on chain (the design rule "An
  index created off its weights"). The website's create page, and a new Sepolia deployment, since a new factory is a
  whole new deployment, follow.
- **The oracle-free rebalance** was built on 2026-11-10 (the owner's call: "we have to cut off oracles somehow and
  keep rebalance safely"; `docs/design/rebalance.md` is the spec). What it is:
  - The executor names every component's new units (`executeRebalance(uint256[] newUnits, bytes data)`). The hub reads
    no price. `WeightedMath` checks each leg's unit caps and the weighted gain `Σ w · L(Δunits / units)` against the
    auction's bar, which falls from a half by half every twelve minutes for four hours.
  - `L` is a lower bound of the logarithm, so an accepted fill never lowers the weighted product of the units, a
    constant-weight pool's invariant. At any prices the index is then worth at least `e^(bar − D)` times what it was,
    `D` its distance from its weights there. On its weights nothing can be taken.
  - Gone: Pyth's contract and interfaces, every price id, the price window, the confidence and moving-average checks,
    `μ`, `MIN_TRADE`, every payable entry point of the hub, and `GuardianRelay` (the Safe holds the guardian role
    itself again, since a start carries no update). `audits/retired/oracle.md` retires V5-L1, V5-M1,
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
    mechanism by reviewers who did not design it (it ran on 2026-11-14, below); the Halmos harness; a new Sepolia
    deployment.
    `test/vectors/proofs.py` is rewritten for the new arithmetic: it checks the proof's chain in exact rationals
    (the derivative identity behind `L(x) ≤ ln(1 + x)`, the margin at the cap, every rounding, every second of the
    bar, the amounts), standard library only.
- **Batch fills** were built on 2026-11-11 (the owner's call, after asking why a $100 buyer pays for a swap per
  coin: "then build it"; `docs/design/batch-fills.md`). No protocol contract changed; the keeper's executor and
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
- **The BNB Chain deployment** was built on 2026-11-13 (the owner's call; `docs/design/bnb-chain.md`).
  No contract under `src/` changed, and the release hashes did not move.
  - `script/BnbChainAddresses.sol` is BNB Chain's address book: twelve coins (WBNB, BTCB, ETH, XRP, ZEC, ADA, BCH, LTC,
    DOT, ATOM, ASTER, STABLE), the list of 2026-10-07 less SOL, DOGE, AVAX, FIL and TRX, each left out by a ruling
    already made; Binance-Peg USDT and USDC, 18 decimals each; and Uniswap's Universal Router 2.0.0 there, the same
    build as Ethereum's.
  - `DeployChecks` pins chain 56 as it pins chain 1; `ConfigureWeighted` lists `V5_WHITELIST=bnb`; `CheckToken` takes
    `CHECK=bnb` and reads depth against WBNB and USDT. The zap's wrapped coin there was WBNB, so its ether entry points
    took and paid BNB, until they went on 2026-11-18.
  - Found on the way: Ethereum's router address has code on BNB Chain, a byte-identical replay of Ethereum's
    deployment, and `isPinnedChain` read that as "this is Ethereum", so a deployment on BNB Chain resolved Ethereum's
    book and stopped at its WETH address. Nothing could have been deployed wrongly. The first fix that day told
    BNB Chain by its own router's code before the chain id; the safety check of the same day found that anyone can
    replay that router onto Ethereum (both routers are CREATE2 deployments from a public factory, and BNB Chain's
    already stands on Base), which would have stopped every deployment on Ethereum at WBNB's address. A pinned
    chain's own id decides now, and a router's code only under any other id (mutants N1, N2 and N5; the record's
    sections 3 and 8).
  - The fork suite passed on BNB Chain's state on 2026-11-13 (13 of 13, block 133,361,996): a deployment from the
    book, the twelve listed and through `CheckToken`, an index of all twelve issued, rebalanced with real transfers
    and redeemed in kind, `MintRequests` filled in USDT and USDC, and the zap minting and burning an index of WBNB,
    BTCB and ETH in USDT and in BNB on Uniswap's real pools (in BNB no longer since 2026-11-18: the suite shows a
    payment in WBNB refused instead).
  - What it costs, said to the owner: no index spans both chains; nine of the twelve are in Binance's custody; and
    Uniswap, the zap's one venue, has a market worth routing for six of the twelve (PancakeSwap holds the rest), so
    the other six mint in kind or through `MintRequests`.
  - Ethereum's list lost the six copies wrapped from BNB Chain the same day (85 coins, `script/Listings.sol`).
  - Not done: the owner Safe and the guardian's
    Safe on BNB Chain; the `BNB_RPC_URL` secret, without which CI skips the BNB Chain suite; the source reading of
    the twelve; the keeper's BNB Chain preset, executor and stock; the app.
- **The red team of 2026-11-14** (`audits/internal/red-team-rw.md`, ids `RW-1`..`RW-10`) read `src/` alone: the red
  team of the oracle-free mechanism by reviewers who did not design it. It found no path that takes funds at rest
  from an index with real, dispersed supply, from a zap user, or from a builder escrow of an ordinary token, and one
  chain that took a requester's stablecoins on a dust index (RW-1 with RW-2). Six of the ten were already recorded
  here, which a reading of `src/` alone could not know; the record says which. Fixed the same day:
  - An index under one whole share does not rebalance (RW-1), which closes the free walk of a dust index, a known
    limitation since 2026-11-10. The holder of a whole supply of a share or more can still walk the units.
  - `MintRequests` fills a request only at the `rebalanceNonce` it was made at (RW-2), and a filler may bind its
    fill to the request it priced (`fill(id, amount, expected)`, `requestHash`, RW-7). `fill(id, amount)` stays and
    the keeper's executor is unchanged: a draft that removed it broke the keeper's build, seen only at the port.
  - `acceptCreator` accrues the streaming fee to the outgoing creator first (RW-6).
  - Issue probes that each leg it pulls can leave again (RW-8). RZ-25's call of 2026-11-02 had left that check to
    the app, so this one is the owner's to confirm. The hub is 21,341 bytes, 3,235 under EIP-170.
  - The engine tells a router's stray from a hop's unsold input, and the zap offers the stray where it forced it
    (RW-9); a swap measured against a balance two addresses write reverts `SharedBalance` (RW-10).
  - Recorded by documentation: a sliver fill, which a quote can make certain (RW-3), self-referral (RW-4, which is
    RY-3) and a holder's top-up through a fill (RW-5).
  - `getRequest` returns one more field and all four release hashes moved, so every decoder of a `Request` follows
    and a new deployment is a whole one. The vectors are 431; the suite has 555 tests, twenty-three of them named
    `test_RW..`; the mutants W1 to W29 are all killed.
  - Not done: the fork suites, Ethereum's five and BNB Chain's, for want of an RPC where it was built. Gate 4
    requires them for RW-1 (the hub's rebalancing), RW-8 (issue's probe, which has met no real token), RW-9 and
    RW-10 (the zap and the engine), and they are what runs `MintRequests` on the real stablecoins (RW-2, RW-7).
    Also not done: the app and the backend; a Sepolia deployment, without which the keeper of this build decodes
    no request there (`docs/deployment.md`).
- **USDC and USDT are the only currencies** since 2026-11-18 (the owner's call: "lets leave payments with only stable
  coins usdt and usdc", and, asked how strict, the lock on chain rather than in the app alone;
  `audits/retired/zap-ether.md`). On both chains:
  - `IndexZap` takes and pays its `USDC` and `USDT` alone: every entry point reverts `NotAStable(token)` on any
    other `tokenIn` or `tokenOut` before anything moves. `mintWithEth`, `burnToEth`, `burnToEthWithPermit`, the zap's
    `WETH`, its `receive()`, `NotWETH` and `ValueMismatch` are gone; no entry point is payable. The burn no longer
    pays out a component or any other token either.
  - `BasketBuilder.buy` and `sell` take the builder's `USDC` and `USDT` alone; `deposit` and `withdraw` still move
    any token in kind. Both constructors are `(factory, router, usdc, usdt)`, and `NotAStable` moved from
    `IMintRequests` to `IXindexErrors`.
  - `DeployWeighted` takes no `WETH`; it gives the zap, the builder and `MintRequests` the same two, and
    `checkDeployment` refuses a zap or builder whose pair is not `MintRequests'`. `DeployChecks.pinnedWeth` is gone,
    and `IWETH9` is back in `script/interfaces` for the Sepolia test market alone.
  - Mutants S1 to S7, all killed; the release hashes moved. The pass-through leg's tests (DA-15) run on an index
    holding USDC; tests whose currency was a token of their own build a zap or builder with it as its USDT.
  - Fork suites, on public RPCs pinned near the head on 2026-11-18: BNB Chain's 13 of 13 (`testFork_theZapRefusesBnb`
    among them), `Security.fork` 9 of 9, `MainnetAddresses.fork` 8 of 8 (its wide count, stale at 87 since `4e4751f`,
    is 81), `IndexZap.fork` 11 of 12 and `WeightedHub.fork`'s four drills. Left: `IndexZap.fork`'s
    `testFork_mintWithUSDC`, whose sanity floor of $100 the basket's $91 at the head misses (price, not code);
    `WeightedHub.fork`'s two whole-list tests, which the public node refused for archive state; `CheckToken.fork`. An
    archive run at the pinned block settles all four. Not done either: the app's ether paths (the app repository's
    site and API still offer ETH), which go with its move to this build.
- **Bridged coins in a rebalance** (2026-11-18, `docs/design/bridged-coins.md`). Asked how an
  index rebalances a coin no Ethereum pool trades, the answer kept: the keeper's executor holds it as stock and the
  restock carries only the net through its home chain, since every index rebalances a coin the same way at once and
  nothing on Ethereum nets it. Built on it, in the keeper alone:
  - An auction's needs go on the restock's board before it opens: a proposal through its two-hour notice, which no
    check had read, so its entry lapsed after 15 minutes and the restock could send its stock home; and an index the
    keeper may start within `PRESTOCK_LEAD_SECONDS`, a day by default (`bestCase`, `prestock`, `M.startStage`,
    mutants K1 to K3). The keeper's end-to-end test checks the board at a start, through a notice and a day ahead,
    and passed 29 of 29 on a mainnet fork that day (block 26,441,062), with NVDAon priced under the Uniswap pool it
    has grown since, so that stock still serves it.
  - The stock's price is the operator's, accepted at launch sizes with no hedge (the owner's call).
  - The copies of JUP, PYTH, SUI, APT and ALGO left Ethereum's list (the owner's call, below): 80 coins. Their
    restock signers stayed, unrun, until 2026-11-25, when they were deleted (the owner's call, below).
- **The audit of 2026-11-21** (`audits/internal/consolidated-audit-ca.md`, ids `CA-H1`, `CA-H2`, `CA-M1`..`CA-M19`,
  `CA-L1`..`CA-L12`, `CA-R2-01`..`CA-R2-20` and `CA-S01`..`CA-S08`: the reports' own ids under a prefix, since v1
  already holds `M01`, `L06` and their neighbours). An agent's audit of `main` at `5b7635f`, in three passes and a
  follow-up, 61 numbered findings, handed over that day; not the external audit asked for below. It found no path
  that takes holders' funds from an index. The owner's call was to fix everything confirmed, the changes to `src/`
  among them. Thirty-three are fixed in code, seven by documentation, and twenty-one are left as they are, each
  with its reason in the record.
  - **`CA-H1`, the one real break of a stated bound.** `KeeperExecutor.fillBatch` spent the share stock's allowance
    on a count of the shares it was to bring in, and a redeem side paid nothing is never filled: with a stolen
    keeper key the whole share stock left with the allowance at zero. The count is now held against the shares the
    executor holds after the batch (`ShareStockShort`). Every fill also carries the hash of the request its keeper
    priced (`expected`, `RequestChanged`, `RequestsChanged`; CA-M6).
  - **In `src/`**, all four release hashes moved:
    - `MintRequests` and `BasketBuilder` keep `totalEscrow[token]` and take nothing into a token they hold less of
      than they owe (`Underbacked`, now in `IXindexErrors`; CA-H2, which is RX-8's rule on the two escrows).
    - `requestMint` and `requestRedeem` each have an overload naming the nonce the limit was set at (CA-M1).
    - The hub has `claim(token, to, amount)` (CA-S01) and `cancelRebalance(proposalId)` (CA-S02). It is 21,627
      bytes, 2,949 under EIP-170.
    - The builder refuses the paid token itself as a recipient (CA-R2-15) and a deposit that delivered nothing
      (CA-R2-16).
  - **The keeper's bot** names its units on the hub's own score, where it solved for the logarithm's optimum and took
    an eighth less in the tested case (CA-M7); dates the needs board by its last block that looked, not its last
    write (CA-R2-02); reports a request's need once (CA-M8); reads only the legs a fill moves (CA-R2-03); and leaves
    out one index whose tokens cannot be read instead of failing the round (CA-R2-04).
  - **The restock** runs again: on `main` it read `PYTH()` from the factory, which has had none since 2026-11-10. It
    also reads a transfer's completion back before settling it (CA-M10), locks its journal to one process (CA-M12),
    holds the day's budget to what the buys may cost (CA-M13), funds what the buys wait for before the float's
    target (CA-R2-10), sends no stock to a chain without gas (CA-R2-09) and leaves out a chain whose node is down
    (CA-R2-11).
  - **The invariant checker** no longer clears a breach it could not read (CA-M17), skips a range whose read failed
    (CA-M16), loses an alert the webhook refused (CA-M18) or trusts a head that stopped moving (CA-R2-14).
  - **The scripts**: on chains 1 and 56 the guardian must be a Safe of at least two signatures (CA-M4, the figure
    this record's reading and the owner's to change); `CheckToken` counts the admin role's holders and never prints
    an unread owner list as a count (CA-R2-17, CA-R2-18); CI's coverage gate fails a row cut short (CA-L11).
  - Mutants C1 to C43, all killed; B1 and B2 follow the rewritten line. The suite has 555 tests, the executor's 83,
    the bot's 232.
  - Fork suites, on public RPCs pinned near the head on 2026-11-21: `Security.fork` 9 of 9, `MainnetAddresses.fork`
    8 of 8, `WeightedHub.fork`'s four drills, BNB Chain's 13 of 13, the executor's 3 of 3, and `IndexZap.fork` 11 of
    12 (`testFork_mintWithUSDC` misses its $100 floor at the head's prices, as on 2026-11-18). Left for an archive
    run: `WeightedHub.fork`'s two whole-list tests and `CheckToken.fork`.
  - Not done: the keeper's end-to-end tests on this change; a new Sepolia deployment, the
    executor included; the app and the backend (the bound request calls, `cancelRebalance(proposalId)` in the Safe
    batches, `Underbacked` as a state to show); and before the non-EVM signers run, CA-M14, CA-L7, CA-R2-12 and
    CA-R2-13 (fixed on 2026-11-24, the bullet "The last open findings and the keeper's dependency", and retired with
    the signers on 2026-11-25).
- **Backed's wrapped xStocks, listed 2026-11-21 and removed 2026-11-22.** On 2026-11-21 the owner replaced the 17
  Ondo stocks with 109 of Backed's wrapped xStocks on Ethereum and 104 on BNB Chain, and the keeper learned to value a
  wrapper at its feed times its `convertToAssets`. On 2026-11-22, shown that Ondo covers about three times as much
  (352 against 109, 87 of them on both), the owner reversed it: "delete everything releated to xtokcs and leave only
  ondo". Every xStock address, id, test, keeper path (`keeper/bot/rates.mjs`, `MAINNET_WRAPPED`, `WRAPPED_TOKENS`,
  `M.atRate`), mutant (X1 to X16) and the design record went; all are recoverable at `7a1d9c2`. The keeper's fixes made
  beside it stay: RZ-13, RZ-15 and RZ-16, the request batch in its end-to-end test, and `Security.fork`'s two Tether tests.
  The fork suites passed on archive RPCs that day: `MainnetAddresses.fork` 8 of 8 (every one of the 414 read on
  chain), `CheckToken.fork` 10 of 10 (the wide list a hundred a test), `IndexZap.fork` 12 of 12, `Security.fork` 11
  of 11, `WeightedHub.fork` 6 of 6 at block 26,464,080 (200 of the 414 in one index: `issue` 14.7M, a fill 14.2M,
  `redeem` 9.6M, the test's executor funded before the fill), and BNB Chain's 17 of 17 (all 352 Ondo tokens through
  `CheckToken`). Not run on it: the mutation gate and the keeper's end-to-end test.
- **The release candidate of 2026-11-21** (branch `release/2026-11-21-candidate`;
  `audits/archive/audit-package-oracle-free.md` is its brief for external auditors, and replaces the package of
  2026-11-02, which described the Pyth-priced build). The owner's ask that day: "I need complete Xindex with all
  problems solved", ready for the audit that comes before it holds funds. What the candidate is, and what ran on it:
  - The audit's fixes and, since 2026-11-22, Ondo's stocks and ETFs (the xStocks listing of 2026-11-21 is gone, above).
  - `MAX_COMPONENTS` is 200, where it was 100 (the owner's call that day, under "Product decisions"; the design
    rule "Two hundred is what the contracts carry"). It is the one change to `src/` since the audit branch, and it
    moves the factory's release hash alone. The whole-list fork test now holds all but one of Ethereum's listed
    coins in one index, 170 of 171 since OP left, and requires its issue and its redeem to fit a transaction: 10.4M
    and 6.9M.
  - The fork suites on archive RPCs at their pinned blocks, which settles what the runs of 2026-11-18 and
    2026-11-21 left for an archive node: Ethereum's five and BNB Chain's, 62 tests, none failed or skipped
    (`IndexZap.fork` 12 of 12 with `testFork_mintWithUSDC`, `WeightedHub.fork` 6 of 6 with its two whole-list
    tests, `CheckToken.fork` 9 of 9, `MainnetAddresses.fork` 9 of 9, `Security.fork` 9 of 9, BNB Chain's 17 of 17),
    and the executor's 3 of 3. They ran again on the raised limit: 64 tests, none failed or skipped.
  - Two fork tests added that day drive the audit's escrow rule on mainnet Tether, whose owner destroys the
    contract's USDT on the fork: no newcomer's request or deposit pays for it (`Security.fork` 11 of 11).
  - The keeper's end-to-end test, 42 of 42 on a mainnet fork at block 26,441,062, before the keeper fixes below and
    not run since (its check that a fill mined past its deadline counts no strike has never run): the 29 checks of
    2026-11-18; WRP, an index of WETH and wGOOGLx wrapped the real way, started and filled, the wrapper kept and booked at its feed times its
    rate of 78.9; and the first requests any run has filled against real pools, a bound mint and a bound redeem
    request on one index in one `fillBatch`, each at its limit. Two faults of the test itself were found on the
    way. viem's wait for a receipt reads it again only when the block number moves, and a chain that mines on
    arrival moves it once, so a receipt missed at that one look timed the run out on a mined transaction: the test
    polls the receipt itself. And a run that is killed leaves its anvil on the port, which later runs then
    silently talked to: the test refuses to start while something answers there.
  - Six keeper findings of the red team of 2026-10-31, open since, fixed the same day
    (`audits/internal/red-team-rz.md`): a fill mined after the block it was sent for strikes nothing (RZ-15); a
    receipt the node could not be asked for leaves the fill in flight instead of scoring it replaced (RZ-6); a
    request forgotten on its fill is read once more, so a re-org that dropped the fill does not hide it (RZ-13);
    the subsidy budget is charged what a fill's floor lets it lose, and only for a fill that went out (RZ-16,
    RZ-9); and what a restock move that moved on within a round is about is left out of that round's plan, which
    is made from a node that may be a block behind (RZ-19). Mutants Z1 to Z6. The record's last five, RZ-8, RZ-10,
    RZ-11, RZ-20 and RZ-21, informational, were fixed on 2026-11-23 (below).
  - The restock's end-to-end test on the audit's changes: Base and Avalanche 29 of 29 each. Optimism 17 of 29: no
    route bought $1,430 of OP within `ROUTE_MAX_LOSS_BPS`, Uniswap v3's deepest OP pool there holding about
    $35,000 of USDC with OP near $0.07, so the buy and what follows it failed, on depth and not on code. Until
    the pools deepen or the restock has another venue there, OP's stock is the operator's to add. On that the
    owner took OP's copy off Ethereum's list the same day ("remove op for now"): 171 coins, its address kept in
    `MainnetAddresses` for a relisting, and the restock serves AVAX and AERO by default.
  - Gates on the candidate: 555 forge tests without an RPC, coverage 100% on every file, the mutation gate's
    218 mutants all killed, Aderyn and Wake silent, the executor's 86 tests with its fork suite, the bot's 251 unit
    tests and the filler's 17 in its harness.
  - RW-3 is not fixed, and the hub is unchanged. The rule noted on 2026-11-19 as the one to build, a fill under a
    quote restarting only `MIN_REBALANCE_INTERVAL`, is the first of the two the red team's record had withdrawn:
    every honestly quoted rebalance would then open its index to an unquoted auction a week later. The other
    rules, the owner and guardian, or the owner alone, starting a week after such a fill, give a role a start the
    state machine does not have today. Which rule, or none, is the owner's to choose. (Chosen on 2026-11-23, under
    the owner's delegation: the owner and guardian start a week after any fill; see that day's bullet.)
  - The candidate's head is Coinbase's listing on Base, `e2508f7` (2026-11-22), after the Base deployment's `fd3ef11`;
    `src/` is as it was at `720a2f7`. On it the whole mutation gate ran again: 232 of 232 killed.
  - Not done: a push (the branch is local, so CI has not run on it); the app, which is pinned to the build
    Sepolia runs, `5b7635f`, and moves with a Sepolia deployment of this candidate, the deployer's keystore being
    the owner's; the keeper on BNB Chain, whose bot assumes a float of six decimals and twelve-second blocks; the
    external audit.
- **The Base deployment** was built on 2026-11-21 (the owner's call; `docs/design/base.md`). No
  contract under `src/` changed, and the release hashes did not move.
  - `script/BaseAddresses.sol` is Base's address book: sixteen coins (WETH, AERO, ZRO, and the copies Base's standard
    bridge mints of UNI, AAVE, MORPHO, FET, CRV, VIRTUAL, PENDLE, PEPE, GRT, COMP, SNX, 1INCH and RSR), each copy
    with the Ethereum token it names (`remoteOf`, `bridged`); USDC and USDT, six decimals each; both halves of the
    bridge; and Uniswap's Universal Router, PoolManager and V3 factory there.
  - How a copy was proven, each of three readings on chain: its `remoteToken()` is the coin's address in
    `MainnetAddresses`, its `bridge()` is Base's standard bridge, and the bridge's other half on Ethereum holds at
    least the copy's supply (`deposits(remote, copy)`). SHIB and EIGEN, which the bridge holds and for which no copy
    was found, LINK, whose Base token is Chainlink's own, and cbBTC are not listed.
  - `DeployChecks` pins chain 8453 by its id alone (`onBase`); `ConfigureWeighted` lists `V5_WHITELIST=base` there
    and nowhere else and pins its mint currencies; `CheckToken` takes `CHECK=base` and reads depth against WETH and
    USDC.
  - Found on the way: BNB Chain's router address has code on Base, so until this change the checks read a
    deployment on Base as BNB Chain's and stopped at BNB Chain's USDC address. Nothing could have been deployed
    wrongly. Mutants N6 to N10, all killed; N1, N2, N4 and N5 follow the rewritten lines (223 mutants in all).
  - The fork suite passed on Base's state that day, 11 of 11 at block 60,498,455, its pin: the tokens, every copy's
    two readings on Base's side, the three code hashes, the two replayed routers naming nothing, a deployment from
    the book, the list on a fresh factory, every coin through `CheckToken` as listable, an index of all sixteen
    issued in kind, rebalanced with real transfers and redeemed, `MintRequests` filled in USDC and USDT through
    bound requests, the zap minting and burning an index of WETH, AERO and VIRTUAL in USDC along two-hop routes on
    Uniswap's pools, and ether refused. Ethereum's five suites and BNB Chain's ran with it on archive nodes at their
    pins: 64 tests, none failed or skipped. The suite has 561 tests without an RPC, coverage 100% on every file.
  - CI passes `BASE_RPC_URL` to the test step; without that secret the Base suite skips. The archive key the other
    suites ran on has Base switched off, so the suite ran on a public node, which serves its pin only while the
    block is recent.
  - What it costs, said to the owner: Base has no stock; Base's bridge is a party to thirteen of the sixteen coins;
    Uniswap routes few of them, Aerodrome holding most of Base's depth; an index lives on one chain.
  - Not done: the owner Safe and the guardian's Safe on Base; the `BASE_RPC_URL` secret; a reading of who mints
    Base's USDT and can replace its code; the keeper on Base, which has no preset or executor there; the app.
- **Coinbase's coins and stocks on Base** (2026-11-22, the owner's calls: "add stocks on base also", then "add all
  coinbase wrapped tokens in base"; `docs/design/coinbase-on-base.md`). No contract under `src/` changed.
  - Base's list is thirty-two: the sixteen of 2026-11-21, the six Coinbase Wrapped coins (cbBTC, cbETH, cbXRP,
    cbDOGE, cbLTC, cbADA) and Coinbase's ten stock tokens (NVDAc, METAc, AAPLc, GOOGLc, AMZNc, MSFTc, MSTRc, SNDKc,
    SPCXc, TSLAc), all sixteen Custodial. cbBTC, refused the day before, is listed.
  - A stock token is a B20 token, a precompile of Base whose code is the byte `0xef`: Foundry before v1.8.4, this
    repository's pin among them, cannot execute one. `test/fork/BaseStocks.fork.t.sol` therefore asks the node: one
    `eth_simulateV1` deploys the factory of this build, lists WETH and the ten, creates an index of all eleven,
    issues it from real holders' tokens, rebalances it through an executor and redeems it, every balance exact.
    `CheckToken` sends such a token for review unread; `ConfigureWeighted` takes its decimals from the book on Base.
  - One token redeems for `multiplier()` shares, 1.0005 for NVDAc and 8 for SNDKc that day: whoever values a leg
    reads it, as a wrapper's rate.
  - Corrected: Backed's wrapper factory has deployed four wrappers on Base (wbCOIN, wbMSTR, wbNVDA, wbTSLA, over its
    older tokens), which the record of 2026-11-21 missed; they stay off the list, as on Ethereum, for want of a
    Pyth feed that names their tokens.
  - Found on the way: `CHECK=base` had never run. A `forge script` run on an OP Stack chain fails a call or a
    creation by an account without ether, so the check reverted before it read a token, and then read every
    transfer as failed; and a read of a token's symbol or decimals was unbounded in gas and size. Fixed in the
    scripts (`script/ScriptLists.sol`, `ScriptUtils`), mutants N11 to N19. The script run on Base then did not end
    within ten minutes on a public node, for a reason not found; the fork suite prints the same reports.
  - Fork suites on Base at block 60,529,140: `BaseAddresses.fork` 12 of 12, an index of the twenty-two other tokens
    among them, and `BaseStocks.fork` 2 of 2.
  - Not done: the stock tokens' roles read from the chain; a stock through the builder, `MintRequests` or the zap;
    the node-run suite in CI; the keeper and the app on Base; the legal reading (Coinbase offers the stocks outside
    the United States only).
- **Pyth's check on a fill, creation on the weights, and changeable weights** (2026-11-22 and 2026-11-23, branch
  `feat/pyth-check` from
  the Ondo lists of `384f5dd`; `docs/design/pyth-check.md`, `audits/retired/pyth-check.md`). The
  owner's calls: an oracle that can only refuse, Pyth as that oracle, and, on 2026-11-23, "i don tthink that correct
  way of calculating price" of a creator naming units, Ondo's tokens at their share's price, and the work finished in
  this branch. The night's work was copied from the main checkout, which still holds it uncommitted.
  - `src/PythPrices.sol` values a fill's moving legs at Pyth's prices (feed kinds Token, Vault, Multiplier; a minute's
    freshness, fifteen seconds for a fill since 2026-11-27 (HK-25); confidence against the executor), and `WeightedMath.oracleCheck` requires what a fill brings in to cover
    what it takes less a tolerance rising to 2% over the auction. Feeds are the owner's per token, behind
    `LISTING_DELAY`; `script/PriceFeeds.sol` names all 415 of Ethereum's, 365 of BNB Chain's and 32 of Base's, built
    once per call (`table`, `find`), since 414 lookups that each built the table ran out of memory.
  - `createIndex` refuses a leg more than 5% off its weight at Pyth's prices (`MAX_WEIGHT_DEVIATION`, `OffWeights`),
    asking the reader once for every leg (`valuesWith`); its duplicate check is one pass over transient storage, the
    contracts' first inline assembly, where comparing pairs cost 2.7M at two hundred.
  - Changeable weights (the owner's calls of 2026-11-23: "index is unchangable after deployment even bitcoin is
    changable so that unchangeability is very bad", then "fix both", the creator proposing, 7 days, and no coin added;
    `docs/design/changeable-weights.md`). The factory's `proposeWeights`, `cancelWeights` and `executeWeights`,
    `WEIGHTS_DELAY`, and the hub's `setWeights`, which only the factory calls and which emits `WeightsChanged`. The
    units follow at the next rebalance, under the bar and Pyth's check; the math, its model and its vectors did not
    change.
  - `WeightedMath` is deployed on its own since the same day and the factory takes its address: with the weights the
    factory's init code, which carries the hub's, passed EIP-3860's 49,152 bytes (50,693). It is 46,867 now.
    `DeployWeighted` records a fifth release hash, `MATH_INITCODE_HASH`, and `checkDeployment` reports the math's code
    hash. The hub is 22,568 bytes, 2,008 under EIP-170; the factory 18,259.
  - Gates: 601 tests without an RPC, coverage 100% on every file, 256 mutants (PY1 to PY27 and CW1 to CW12 among them;
    H8, PY20 and M3 follow rewritten lines), Aderyn and Wake silent (three verified false positives marked where they
    stand, one return initialized), the keeper's 83 and 239, its two end-to-end scripts deploying the math first.
  - The whole branch, with the three changes below, ran every gate together on 2026-11-23, on a copy of the tree
    taken once nothing was writing to it (the two sessions that built the branch shared one worktree, and a run while
    the other wrote had failed for that reason alone): 618 tests without an RPC, coverage 100% on every file, the
    mutation gate's 291 mutants all killed, Aderyn and Wake silent, the keeper's 86 contract tests and 247 unit tests,
    and the eight fork suites, none failed: Ethereum's five 48 of 48 (`WeightedHub.fork`'s two whole-list tests
    among them) on an archive node at their pins, BNB Chain's 18 of 18 on an archive node, Base's 14 of 14 and
    `BaseStocks.fork` 2 of 2 on a public node at their pin.
  - Found by BNB Chain's fork suite: the factory refused a feed Pyth's contract had never stored, and on BNB Chain
    that is 343 of the 364 (ZEC's, STABLE's and most Ondo stocks'), so the owner could not have set them. It no
    longer asks; a feed of a kind other than `None` must name an id (`InvalidPriceFeed`, mutant PY20 rewritten).
    The fork suites' tests that are not about prices give each listed token its feed and date Pyth's stored price
    to their clock, a dollar where none is stored, since a test cannot sign an update; the tests of Pyth's check read
    the stored prices as they are, and now create their indexes within 5% of the weights.
  - Not done: the keeper posting
    Pyth's update with each fill (built on 2026-11-23, its wiring unrun: the bullet after next; the Hermes plan is
    still the operator's to buy); the app posting it before `createIndex`, decoding the new
    errors, showing and proposing a change of weights, and moving holders to a successor index; the audit package. The
    release hashes moved.
- **Creating an index is buying it, and the owner's or guardian's restart** (2026-11-23, the same branch, uncommitted
  on top of the work above). The owner's calls that day: "creation should be buying. Buying should create that
  index", then "Yes, build it"; and, for everything still open, "you decide every archiectural thing but i need only
  safest i mean the safest solution to everything", under which the second rule below was taken.
  - `WeightedIndexFactory.createAndIssue(name, symbol, components, params, shares, to)` creates an index as
    `createIndex` does and has it issue its first shares in the same call. `WeightedHub.initialize` takes a
    `FirstIssue` (`from`, `shares`, `to`) and runs the ordinary issue with the creator as payer, under the
    reentrancy guard; the creator approves every component to the address `predictIndexAddress` gives before the
    call. It has a name of its own: as an overload it made every `abi.encodeCall(IWeightedIndexFactory.createIndex,
    ...)` ambiguous. The approval check is `_checkApprovedCreator()`, which both creations call first, and the
    hub's `_issue` hands its transfers to `_pullBasket`, for the compiler's stack.
  - One call costs about 110,000 gas a component on mock tokens, under Pyth's check: 13.4M at 125 components, under
    five sixths of the cap, and 22.4M at 200, past the cap itself
    (`test_aCreationWithItsFirstIssueFitsOneTransaction`). So the widest indexes are still created with
    `createIndex` and issued afterwards.
  - What it does not do: an index can still be emptied, since every holder can redeem, so the one-share rule stays;
    and paying in USDC or USDT is the app's to compose (swap into the creator's wallet, approve, `createAndIssue`),
    with no new contract.
  - Once an index has had a fill, the owner or guardian may start a rebalance `MIN_REBALANCE_INTERVAL` after any
    fill, where a fill without a keep mask held them off for the index's whole interval, up to 91 days; a stranger
    still waits it out, and so do they before the first fill. It fixes RW-3
    in the hub, by the second of the rules the red team's record had set aside for the owner's choice
    (`audits/internal/red-team-rw.md`, `docs/design/rebalance-state-machine.md`, section 3).
  - The hub is 22,849 bytes, 1,727 under EIP-170; the factory 18,439, its init code 47,335, 1,817 under EIP-3860.
    The factory's and the math's release hashes moved (the math imports the hub's interface).
  - Gates: 613 tests without an RPC, coverage 100% on all 58 files, Aderyn and Wake silent, the keeper's 83 and
    239. Mutants FB1 to FB7 (the first issue) and RS1 to RS3 (the restart), all killed, with F1, M3 and M17 on the
    lines they share; 266 in all, every edit applying.
  - Not done: the app, which predicts the address, asks the approvals and posts Pyth's update before `createAndIssue`; the keeper, which
    reads no new call.
- **The keeper posts Pyth's update with each fill** (2026-11-23, the same branch, uncommitted; under the owner's
  delegation of that day). On a factory with an oracle the keeper could fill no auction: its fill posted no price,
  and its preview of the hub met whatever stale price Pyth's contract held.
  - `KeeperExecutor.fill` takes one `AuctionFill` struct (the eight arguments did not fit the compiler's stack) and
    is payable: `pythUpdate`, when it is not empty, is posted to the Pyth contract the index's own reader names
    (`index.PRICES()`, then `PYTH()`) before the fill, for Pyth's fee, which the call must carry exactly
    (`WrongPythFee`); with no update the call carries no ether, and an update for an index without an oracle is
    refused (`NoOracle`). The executor forwards the caller's ether and never its own. A stolen keeper key gains
    nothing by it: the destination is not the caller's to choose, and the ether is its own.
    `keeper/src/interfaces/IPyth.sol` declares the two calls; `keeper/test/KeeperExecutor.pyth.t.sol` runs the
    executor on a factory with an oracle against `MockUpdatablePyth`. Mutants KP1 to KP5.
  - The bot ports Pyth's check (`oracleToleranceAt`, `oracleOf`, `legValuesOf` in `keeper/bot/units.mjs`, replayed
    against the model's 85 oracle vectors) and `nameUnits` takes it as it takes a quote, so the units it names hold
    the check at the tolerance of the fill's second. Mutants UO1 to UO5.
  - The bot's wiring: each index's reader and Pyth are read once (`staticsOf`); for the legs it may move it reads
    the factory's feeds, takes Hermes' signed update for them, and asks the reader each leg's value after that
    update, in one `eth_call` through Multicall3 (`pythFor` in `keeper/bot/pyth.mjs`, a module of its own with
    no dependency, tested against a fake chain and a fake Hermes: `keeper/test/unit/pyth.test.mjs`, mutants PW1 to
    PW6); the hub's preview is asked the same way; the fill is simulated and sent with the update and its fee,
    which is counted with the gas (`preview` and `priceFill` in `keeper/keeper.mjs`, `callAfter` in
    `keeper/bot/chain.mjs`).
  - Gates: the keeper's 86 contract tests and 247 unit tests, its fmt, build and lint; the sixteen mutants above,
    all killed.
  - **Not run:** `callAfter`, the oracle branch of `preview`, and `priceFill`, which need viem. `keeper/node_modules`
    is absent where this was built, so `keeper.mjs` and `chain.mjs` were only parsed (`node --check`), and neither
    the request harness nor the end-to-end test ran then. Run on 2026-11-24, after `npm ci` (the owner's yes): the
    request harness 15 of 15, and the end-to-end test 45 of 45 on a mainnet fork at block 26,480,113, its factory
    on Pyth's real contract: feeds proposed and executed, an update before each creation, a creation off its
    weights refused (`OffWeights`), and every fill carrying Pyth's update and paying exactly Pyth's fee for it, zero
    on all three chains that day. The runs before it failed on the fork's cold reads alone, which `RPC_TIMEOUT_MS`
    and the test's own waits now allow for.
- **A read of the price reader and the weight changes as an attacker** (2026-11-23, by the session that built the
  three changes above, so not an independent review). One finding, fixed: `PythPrices` valued a leg at zero when a
  stock token's multiplier or a vault's rate read zero, or a price was too small for the scale, and a leg that
  leaves at zero is free to take by Pyth's measure, which left that leg to the units' check alone; an index of legs
  that all valued at zero also passed creation's weights check. A value of zero is now `UnusablePrice`, both ways
  (mutant PY28; PY16 follows the rewritten line). The factory's init code is 47,344 bytes, 1,808 under EIP-3860.
  Read and left as they are, each a stated bound and not a hole: an owner who sets a wrong feed, behind
  `LISTING_DELAY` and the guardian's cancel, lowers Pyth's check on that token to the units' check; a creator who
  changes weights opens a distance its own last-second fill turns into at most the tolerance of what it trades,
  every interval, which holders have the 7 days' notice to leave before; an executor picks which Pyth update of
  the last minute to post; and anyone can post a newer update ahead of a fill, which can make a fill named at the
  edge of the tolerance revert.
- **A pause of minting** (2026-11-23, the same branch, uncommitted; the owner's call that day, under "Product
  decisions"). `WeightedIndexFactory.pauseMinting(index)`, for the owner or guardian, and `resumeMinting(index)`,
  for the owner alone; the zero address names every index; `mintingPaused(index)` reports; `MintingPaused` and
  `MintingResumed`. `feeTerms` answers `allowed` false while either pause holds, so the hub's issue reverts
  `NotAllowedMinter` with no change to the hub's code. Tests: the section "Pausing mints" in
  `test/WeightedIndexFactory.t.sol` and `test_aPauseStopsIssuesAndNoExitNorARebalance` in
  `test/WeightedHub.rebalance.t.sol`; mutants MP1 to MP7. The factory is 18,974 bytes and its init code 47,902,
  1,250 under EIP-3860: there is room for little more. Not done: the app, which reads both pauses before it offers
  a mint; the keeper, whose request fills that issue shares will revert on a paused index and be skipped as any
  reverting simulation is.
- **The attack replay of 2026-11-23** (`audits/internal/attack-replay.md`, ids `HK-1`..`HK-20`; the owner's ask
  that day: "see every hack that happend in crypto and than attack our contract"). Twenty classes of attack that
  took funds from 2016 to June 2026, each aimed at the contract here it would hit. An internal review by the code's
  author, not the external audit.
  - One finding, low, fixed (HK-16): a creator's pending change of weights outlived a handover of the creator role
    and took effect under the new creator. `acceptCreator` cancels it (`WeightsCancelled`). No funds were at risk.
  - Refused or not applicable, each with its test: a callback that does not ask who calls and a transient mark left
    behind (HK-1, HK-2), a standing approval spent by someone else (HK-3), rounding repeated on dust (HK-5), the
    first depositor's inflation on a creation that is its own first buy (HK-6), reentrancy from inside a fill
    through the factory and the request escrow (HK-8), an empty slot passing for a real one (HK-9), a permit replayed
    on a twin index or another chain (HK-10), every state-changing function called by a stranger, the tables held to
    the ABIs (HK-12), a mint nothing backs (HK-13), forced ether (HK-14), a vault's rate raised by a donation
    (HK-15). Five classes were already replayed by earlier suites, which the record names, and one, a vote bought
    with a flash loan, does not apply.
  - The bound a stolen key has, shown rather than asserted (HK-4): no key moves a token, changes an index's terms or
    blocks an exit; through an index's own auction the owner's key and its creator's together take up to a fifth of
    a leg a week, after seven days of public notice and with the guardian silent or replaced.
  - New: `test/Attacks.t.sol` (16 tests), `keeper/test/KeeperExecutor.attacks.t.sol` (2),
    `keeper/test/unit/executor-source.test.mjs` (3), mutants HK1 to HK7. Two of the replay's own tests proved
    nothing at first: Foundry clears transient storage between a test's own calls, so "the same transaction" must
    be one contract call; mutant HK1 caught it.
  - The factory is 19,096 bytes and its init code 48,024, 1,128 under EIP-3860. Its release hash moved; no ABI did.
  - Not covered, and said so in the record: anything off chain (a signer's machine, the app, the bot's host), the
    compiler and libraries, economics.
- **The attack replay of 2026-11-27** (`audits/internal/attack-replay-ii.md`, ids `HK-21`..`HK-26`; the owner's ask
  that day: find the hacks DeFi protocols suffered and test our code against them). The exploits of July to November
  2026, and the chain's own DEX of 2026-11-26, which no replay had seen. An internal review by the code's author.
  - One bound narrowed (HK-25, the owner's call that day: "კი, 15 წამი", then a fill's fifteen and a creation's
    sixty): the executor chooses which Pyth price its fill is checked against, since it posts the update itself, and
    the 2% tolerance is counted at the one that suits it. That was a stated bound since 2026-11-23, but the passages
    that state the 2% did not count it. `PythPrices.MAX_PRICE_AGE` is 15 seconds for a fill now, and a new
    `MAX_CREATION_PRICE_AGE` keeps a creation's check, which a person signs in a wallet, at 60. The factory's release
    hash and `abi/PythPrices.json` moved (`test_HK25_...`, mutants HK11 and HK12).
  - Replayed and refused: no router ever holds an approval from the zap or the builder (HK-21, RouteProcessor2, K3
    Capital); a route cannot name a pool the DEX never made, on mocks and on PancakeSwap's and Aero's real routers
    (HK-22); a route that comes back to its own token is counted once (HK-23, Allbridge, Unifund); `accrueFees`
    between an issue and a redeem pays nothing (HK-24, Set's `actualizeFee`). Index Coop's helper class is refused
    by the zap's nonce recheck and the builder's exact approvals (HK-26). The period's other classes are refused by
    tests that already stood, which the record names.
  - New: five tests in `test/UniversalRouterSwaps.venues.t.sol`, `test/Attacks.t.sol` and
    `test/WeightedHub.oracle.t.sol`, two fork tests, mutants HK8 to HK12, all killed. The one contract change is the
    reader's two ages.
- **The six findings left open, fixed on 2026-11-23** (the owner's call: "Fix six findings"). Each has a test that
  fails without its fix and a mutant (RB5, Z7 to Z13), all killed; the records' status tables say what changed.
  - RB-5, in `src/`: the zap refuses every factory index as a recipient, not only the index of the call, as the
    builder does. The zap's release hash moved; no ABI did.
  - RZ-8: the keeper sends nothing over a pending nonce it is not following, and says once why it waits.
  - RZ-10: a request scan reads at most 1,000 requests, the known ones in turn, so a stranger's one-unit requests
    cannot grow every scan.
  - RZ-11: a chosen route is quoted again when its leg grows, so a purchase's bound covers the larger amount.
  - RZ-20: the restock counts stock held beyond its stock allowance as held, buys nothing for it, and asks the
    owner for `setStockAllowance`.
  - RZ-21: in a round that buys, coins at home below `RESTOCK_MIN_USD` wait to come in with the buy's coins.
  - Gates: fmt, build and lint clean for both projects; 635 tests without an RPC; coverage 100% on all 59 files;
    the mutation gate, 306 of 306 killed; Aderyn and Wake silent; the keeper's 88 contract tests and 255 unit tests.
    Fork suites on public nodes at the head: Ethereum at block 26,479,875, `IndexZap.fork` 11 of 12 (the known
    $100 floor, the basket at $88.29), `MainnetAddresses.fork` 9 of 9 and `Security.fork` 11 of 11, both deploying
    through the new zap hash; BNB Chain at block 135,326,394, 18 of 18; Base at block 61,360,828, 14 of 16, the two
    Pyth tests written against the batch at Base's pin failing as before, and `BaseStocks.fork` 2 of 2. Not run:
    the hub's whole-list tests and `CheckToken.fork` (archive node), the keeper's end-to-end test (`npm ci`).
- **XA-34 and RZ-33, fixed on 2026-11-24.** The WBTC pause drill expects WBTC's own refusal, a revert with no data the
  hub relays unchanged, read from the drill's trace on a fork (it passed at Ethereum's head that day). The settlement
  vectors are 455: 24 of a generator of their own (`edges()`) settle through products past 2^256 with a leg at exactly
  `UINT96_MAX`, or overflow one raw unit past it; mutant V25, a backing in 256 bits, survives the 431 before them and
  dies on these. `proofs.py` passes on the model unchanged.
- **The keeper on BNB Chain and Base** (2026-11-24, the owner's call to complete the code that day). The bot and its
  executor ran on Ethereum alone: a float of six decimals, twelve-second blocks, gas valued at ETH, a chain table of
  Ethereum and Sepolia. No contract changed. `CHAIN_ID=56` and `8453` now run the same bot, one process and executor
  per chain (`keeper/bot/config.mjs`, each address read on chain that day and pinned against the address books by
  `keeper/test/unit/chains.test.mjs`):
  - Prices: a token's id is its feed as the factory records it (`priceFeedOf`), the one its hubs check a fill
    against; a multiplier token's (Coinbase's stocks on Base) is left alone, as a share-priced leg is.
  - Timing: blocks every 450 ms (BNB Chain) and 200 ms (Base), measured that day. A fill is priced at the earliest
    second it can land (`M.landing`), where the bar is highest and Pyth's tolerance narrowest, with a deadline three
    seconds on, and replaced only after those seconds' blocks; every window kept in blocks is Ethereum's, scaled to
    the chain (`M.blockScale`), so it lasts the same time. On Ethereum nothing changes: the next block is both.
  - Money: the float's and the request stablecoins' decimals (eighteen on BNB Chain) are the chain's, checked at
    startup; gas is valued at the gas coin (BNB's price on BNB Chain); Base's L1 data fee is added at GasPriceOracle's
    upper bound. Gas defaults are each chain's own (1 and 0.1 gwei on BNB Chain, 1 and 0.01 on Base).
  - Venue: Uniswap V3 alone, as on Ethereum; a coin it does not route is served from the operator's stock (the
    restock serves Ethereum alone). PancakeSwap and Aerodrome hold most of those chains' depth and are not routed.
  - Proof: the bot's unit suites (264), the request harness with a BNB Chain case (15), mutants CH1 to CH8, and
    `keeper/test/KeeperExecutor.chains.fork.t.sol`, which on each chain's real market deploys the executor, checks
    every address the table names, and fills a real mint request through Uniswap V3: BNB Chain 2 of 2 and Base 2 of
    2 at the heads that day; the end-to-end test on Ethereum, 45 of 45, runs the changed bot there. Not run: a keeper
    end-to-end test on either new chain, and the bot's auction path there, which needs an oracle factory on the fork
    and Pyth's update signed for it.
- **The last open findings and the keeper's dependency** (2026-11-24, the same day's call). No contract changed.
  - The audit's four left for the non-EVM signers, fixed in the restock (`audits/internal/consolidated-audit-ca.md`,
    "Status of the fixes"): a home wallet keeps twice its chain's gas minimum of a coin that is its own gas coin, SUI,
    APT and ALGO, which the plan never sells or bridges and the signer refuses to (CA-M14, `spendable` in
    `keeper/restock/plan.mjs`, `keepGas` in `keeper/restock/signer-home.mjs`); a buy the plan sized at
    `RESTOCK_MIN_USD` is held to the minimum in the coin's units, not by its value recomputed in floats (CA-R2-12);
    a received Solana burn stays in the journal until its event account's rent is reclaimed (CA-R2-13,
    `rentToReclaim`); and the signers end with the run, so `--once` exits (CA-L7, `ask.close`). Tests named
    `CA-M14: ...`, `CA-R2-12: ...`, `CA-R2-13: ...` and `CA-L7: ...` in `keeper/test/unit/`, mutants C44 to C51.
    The signers themselves never sent a transaction: their coins left the list on 2026-11-18, and the signers, with
    these four fixes, went on 2026-11-25 (`audits/retired/non-evm-restock.md`).
  - RZ-17 and RZ-27, which the red team's record still showed open, were retired with Pyth on 2026-11-10
    (`audits/retired/oracle.md` says so); their rows say so now. The price reader of 2026-11-22 reads no
    moving average, and a start carries no update.
  - The keeper's viem moved from 2.21.54 to 2.57.7, the app's version (published 2026-10-14): the older one pulled in
    a `ws` with two advisories (GHSA-58qx-3vcg-4xpx, GHSA-96hv-2xvq-fx4p), over a transport the keeper does not use.
    `npm audit` finds none now. On it the request harness passed 15 of 15 and the end-to-end test 45 of 45 again, at
    block 26,480,113.
  - Gates: the keeper's 269 unit tests; every one of the mutation gate's 323 edits applies, C44 to C51 killed.
- **The restock buys Ondo's stocks through UniswapX** (2026-11-24, the owner's call: "კეეპერში ჩააშენე", build it into
  the keeper, after the owner pointed out that Ondo's assets trade there; `docs/design/uniswapx-restock.md`). No
  contract under `src/` changed, and the zap still swaps through Uniswap's router alone.
  - Since 2026-06-30 Ondo's stocks trade on Ethereum through UniswapX: a swapper signs an order and fillers, Ondo's
    minting desk among them, settle it through UniswapX's V2 Dutch order reactor (read on chain that day: ten AAPLon
    and NVDAon fills in 9,000 blocks, none through the V3 reactor).
  - The restock serves the nine Ondo stocks whose feed prices the token, the only ones the keeper values (RX-2), once
    `UNISWAP_API_KEY` is set (`LOCAL_COINS` in `keeper/restock/coins.mjs`). For a shortfall it asks Uniswap's Trading
    API for an order spending an exact amount of the treasury's USDC, and signs it only when every field its
    signature commits to is what the plan allows (`keeper/restock/uniswapx.mjs` `refusal`): the reactor, the treasury
    as swapper and sole recipient, USDC in at most the plan's amount, the coin out at no less than Pyth less
    `ROUTE_MAX_LOSS_BPS` at any point of its decay, no validation contract, a deadline 30 s to 15 minutes away and an
    unspent nonce. It signs typed data it builds from those fields, never the API's.
  - An order is done once Permit2's nonce bitmap shows it spent, and dropped only 15 minutes past its deadline by the
    chain's clock; while one is open the treasury plans nothing else. What it bought goes into the executor through
    `KeeperExecutor.depositStock`, treasury only, credited within the restock allowance as `redeemBridged` credits
    (RS-1, RS-6, `_creditRestock`); nothing sells a local coin or takes it out but the owner's `withdraw`.
  - Tests: the executor's deposit cases and the restock invariant's deposits, `restock-uniswapx.test.mjs` and the
    local cases of the plan, journal, advance, config and coin suites; HK-03's source check counts the executor's
    second pull, also from its caller. Mutants UX1 to UX28, all killed (351 in all). The end-to-end test
    (`keeper/test/e2e/uniswapx.mjs`) settled a signed order through the real V2 reactor on a fork near the head, the
    API, its cosigner and its filler faked: 28 of 28, an unfilled order dropped untouched, an altered one never
    signed.
  - Not done: a run against Uniswap's live API, which needs a key; BNB Chain, whose UniswapX orders are V3 orders
    through another reactor and whose restock does not run; the eligibility Ondo asks of a buyer (no US person),
    which the operator and the treasury must meet.
- **An independent review of the work of 2026-11-23** (a reviewer agent that had not seen the author's reasoning,
  reading only; no critical or high finding). Fixed the same day:
  - The keeper kept an index's weights from its first read, and weights can change since 2026-11-23: it would have
    named units against weights the index no longer had, so been absent from exactly the auction a change of
    weights opens. It reads them every round now (`weightsOf` in `keeper/keeper.mjs`; wiring, no unit suite).
  - The restart rule let the owner or guardian start a week after an index's creation too, wider than its purpose.
    It needs a fill to have settled now (`_restartsEarly`, mutant RS4; `test_theRebalanceIntervalIsTheIndexs` pins
    a fresh index again), and the records say what it gives a hostile role.
  - A newer Pyth update posted ahead of the keeper's fill can push a fill named at the edge of the tolerance over
    it, and each revert is a strike against the auction: the bot's margin inside the tolerance is a tenth of a
    percent (`ORACLE_LAG`, twelve minutes), where the first draft's was half that. Telling such a revert from any
    other, so it is no strike, needs the revert's reason and is not built.
  - Stale comments in the bot and its end-to-end script.
  Answered in part: nothing executed the bot's Pyth wiring, so its one step with indexing to get wrong, `pythFor`,
  was moved into a module and given tests and mutants; the rest still needs viem to run (above).
- **The gates on the work of 2026-11-23, taken together** (run where it was built: nothing is committed or pushed,
  so CI has not seen it).
  - `forge fmt --check`, `forge build --sizes --deny warnings` and `forge lint -D notes`: clean, for the repository
    and for `keeper/`. 613 tests without an RPC; coverage 100% on all 58 files; the mutation gate, 277 of 277
    killed, before the review's fixes, and 278 of 278 after them; PW1 to PW6 since, 284 in all, every edit
    applying; Aderyn and Wake
    silent; `test/vectors/proofs.py` passes; the six ABI files are the build's; the keeper's 86 contract tests and
    247 unit tests. The hub is 22,872 bytes, 1,704 under EIP-170; the factory's init code 47,367, 1,785 under
    EIP-3860. Of the fork suites below, `Security.fork` (11 of 11) and the hub's four drills ran again after the
    review's fix to the restart rule, at block 26,477,148; the rest ran before it.
  - After the mint pause: 618 tests, coverage 100%, the mutation gate 291 of 291, both analyzers silent, the six
    ABI files the build's; Ethereum at block 26,477,737: `Security.fork` 11 of 11, `MainnetAddresses.fork` 9 of 9,
    the hub's four drills, `IndexZap.fork` 11 of 12 (the same $100 floor, the basket at $87.72); Base at its pin,
    14 of 14 and 2 of 2.
  - After the attack replay, which is the state of the tree: 634 tests without an RPC; coverage 100% on all 59
    files; the mutation gate, 298 of 298 killed; Aderyn and Wake silent; `test/vectors/proofs.py` passes; no ABI
    file moved; the keeper's 88 contract tests and 250 unit tests, its format, build and lint clean. The hub is
    22,872 bytes; the factory 19,096, its init code 48,024, 1,128 under EIP-3860. `Security.fork` 11 of 11 and
    `MainnetAddresses.fork` 9 of 9 ran again on the factory's new release hash, at block 26,477,914; the other fork
    suites were not rerun, the change being to `acceptCreator` alone.
  - Fork suites, on public nodes. Ethereum at the head, block 26,476,791 (the hub's drills at 26,476,807):
    `Security.fork` 11 of 11, `MainnetAddresses.fork` 9 of 9, `WeightedHub.fork`'s four drills, and `IndexZap.fork`
    11 of 12, where `testFork_mintWithUSDC` misses its $100 sanity floor at the head's prices, the basket costing
    $87.88 (price, not code). BNB Chain at the head, block 135,244,315: 18 of 18. Base at its pin, block 60,529,140:
    `BaseAddresses.fork` 14 of 14 and `BaseStocks.fork` 2 of 2; at Base's head two of its tests fail, the two
    written against the batch Pyth's contract held at the pin (`COINBASE_BATCH`).
  - Not run: `WeightedHub.fork`'s two whole-list tests and `CheckToken.fork`, which need an archive node; the
    keeper's end-to-end test and its request harness, for want of `keeper/node_modules`; CI.
  - Weighed and not built, each for the reason the product decision of that day gives: fills open at any time, an
    index holding other indexes, gasless signed orders, and, the same way, a request limit that improves over time
    (a change to a contract that holds escrows, which the keeper, the app and every decoder would have to follow,
    for a better price and no safer one).
- **Anthropic's ANTon, and Ondo's sValue in the keeper** (2026-11-25, the owner's calls: "both to eth and bnb", then
  "Yes, keeper first"; `docs/design/ondo-stocks.md`, its last two sections). No contract under `src/`
  changed.
  - ANTon is listed on both chains (415 on Ethereum, 365 on BNB Chain), at Pyth's 24/7 share feed. BNB Chain's fork
    pin moved to 135,655,351, past ANTon's first block there; the suite passed there 18 of 18, and Ethereum's
    `MainnetAddresses.fork` 9 of 9, `Security.fork` 11 of 11 and the token check's last hundred at block 26,492,263.
  - The keeper values a share-priced Ondo leg at its share's price times the sValue Ondo's `SyntheticSharesOracle`
    on its chain holds for it, once settled: held, no corporate action scheduled or under way, unchanged for twenty
    minutes (`keeper/bot/svalues.mjs`, `M.sValueUsable`, `SVALUE_SETTLE_SECONDS`, mutants OS1 to OS8). BNB Chain's
    oracle holds 349 of the 353 Ondo tokens and Ethereum's 10, so 336 of Ethereum's legs are still left alone, until
    the owner picks a source for them (Ondo's API or BNB Chain's oracle by ticker).
  - Found with it: Pyth's check priced an Ondo leg at its share's feed without the multiplier, and a split's
    multiplier stays after the action, so fifteen of Ethereum's listed Ondo legs were valued off by a factor of 2 to
    10 (NFLXon at a tenth) and more by a dividend's few percent. Creation's 5% check refused such a leg on its true
    weight; no exit reads a price. Fixed on 2026-11-27, the owner's call (below): the check reads the sValue.
- **Each chain's own DEX beside Uniswap** (2026-11-26, the owner's call, under "Product decisions";
  `docs/design/chain-venues.md`). The zap and the builder swap through Uniswap's Universal Router and, on BNB
  Chain and Base, through that chain's DEX, a leg naming one venue:
  - The engine (`src/UniversalRouterSwaps.sol`) takes a `LocalVenue` at construction, `LocalDex.None`, `PancakeSwap`
    or `Aero` with the addresses each uses and no other (`InvalidLocalVenue`), and a leg gets `bytes localRoute`. A
    PancakeSwap leg runs on its Infinity Universal Router, whose V3 and SWEEP commands are Uniswap's and whose V2
    commands are declared beside them (`UniversalRouterCommands`); an Aero leg runs on the Metarouter
    (`IAeroMetarouter`, `AeroCommands`), its pools looked up in Aero's factories (`IAeroCLFactory`,
    `IAeroPoolFactory`) forward from what is paid. A sale goes one hop at a time on every venue; each pre-fund,
    sweep, measurement and `SharedBalance` rule holds as on Uniswap. The chain's DEX router is no valid recipient.
  - Read first, the owner's ask: both routers' deployed source, verified on Sourcify as exact matches (PancakeSwap's
    repository head differs from its deployment in four of the files read), Aero's deployment records and both
    DEXes' documentation. PancakeSwap's router takes ether only from WETH and its vault and refunds none, so SV-1's
    denial of service does not return; Aero's returns a batch's ether to the caller and checks every pool against
    its factory registry.
  - `DeployWeighted` takes the chain's DEX from its book (`BnbChainAddresses.PANCAKE_UNIVERSAL_ROUTER`,
    `BaseAddresses.AERO_METAROUTER` and Aero's three factories), never from the environment; the deploy checks hold
    those addresses as market contracts no role may be, and `checkDeployment` compares them. The zap's and the
    builder's release hashes moved; the factory's, the math's and `MintRequests`' did not, the new error living in
    `IUniversalRouterSwaps`. Both ABIs moved: every encoder of a leg, the app's, follows.
  - Tests: `test/UniversalRouterSwaps.venues.t.sol` (both DEXes, both families, the zap and the builder),
    `MockMetarouter` and PancakeSwap's V2 commands in `MockUniversalRouter`, the deploy checks' per-chain DEX, and on
    real pools `testFork_theZapMintsAndBurnsThroughPancakeSwap` (BNB Chain, V2 and V3) and
    `testFork_theZapMintsAndBurnsThroughAero` (Base, CL along one and two hops and a volatile basic pool), with each
    router's and factory's code hash pinned. Mutants LV1 to LV24.
  - Gates: 651 tests without an RPC, coverage 100% on all 61 files, fmt, build and lint clean, Aderyn and Wake
    silent (Wake had flagged a router call through an address computed at the call; each router is now called
    through its immutable); mutants LV1 to LV24 and the 31 older ones on the files this change touched all killed,
    every one of the 354 applying (RB5 follows its rewritten line); the keeper's 93 contract tests and 258 unit
    tests. On the real routers near each chain's head on 2026-11-26: the PancakeSwap round trip on BNB Chain and the
    Aero round trip on Base, both passing, with the routers' code pins.
  - Base's AERO is Aero's token since the same day (the owner's call), read from its verified source: no owner,
    pause, blocklist or proxy. BNB Chain's suite near its head that day: 20 of 20, both PancakeSwap tests, every
    Ondo token's check and the whole-list index among them. Base's suites on it near the head (block 62,653,143): `BaseAddresses.fork` 14 of 16,
    the token check, both zap round trips and the whole-list index among the passing, the two Pyth tests written
    against the pin's batch failing at the head as before; `BaseStocks.fork` 2 of 2. Ethereum's near its head (block
    26,501,376): `MainnetAddresses.fork` 9 of 9, `Security.fork` 11 of 11, `IndexZap.fork` 11 of 12, its $100 sanity
    floor missed at the head's prices as before (the basket at $86.89).
  - Ethereum's Wormhole copy of Aerodrome's AERO left the list the same day (the owner's call, "კი, ამოიღე"): 414
    coins, the copy's address kept in `MainnetAddresses` for a relisting, its feed out of `PriceFeeds`, its entry out
    of the keeper's catalogue, and the restock serving AVAX alone by default, AERO's row kept for `RESTOCK_COINS`.
  - CAKE joined BNB Chain's list on 2026-11-27 (the owner's call, under "Product decisions"): PancakeSwap's own
    token, `Native`, 366 in all. Ethereum's CAKE has about $700 on Uniswap; BNB Chain's has about $4M on
    PancakeSwap's V3 pool against USDT. `BnbChainAddresses.COINS` (13) is where the Ondo tokens start, and the fork
    suite reads it. `testFork_cakeTradesThroughPancakeSwap` mints and burns an index of WBNB and CAKE through
    PancakeSwap alone. BNB Chain's suite near its head (block 135,920,666): 21 of 21.
    On it: 651 tests without an RPC, coverage 100% on all 61 files, the keeper's 258 unit tests, and near Ethereum's
    head (block 26,501,620) `MainnetAddresses.fork` 9 of 9, the 410 of the wide list listed on a fresh factory, and
    `Security.fork` 11 of 11. `CheckToken.fork` outran the public node's window and needs an archive node.
  - Not done: the keeper, whose executor still bought through Uniswap's SwapRouter02 alone (built on 2026-11-27,
    below); the app, which encodes `localRoute`, quotes each venue and shows which one a leg uses.
- **Ondo's tokens at Pyth's price times their sValue** (2026-11-27, the owner's call, "Pyth × sValue", under "Product
  decisions"; `docs/design/ondo-svalue.md`). It fixes the finding of 2026-11-25 above:
  - `PythPrices` has a fifth feed kind, `SharesOracle`: a token worth its share's Pyth price times the sValue Ondo's
    `SyntheticSharesOracle` holds for it, read at the fill (`SHARES_ORACLE`, the factory's fifth constructor argument,
    which `DeployWeighted` takes from the address book on Ethereum and BNB Chain and leaves zero on Base and off the
    pinned chains, and which `checkDeployment` pins). Only a settled sValue is used: held, with no corporate action
    scheduled or under way, unchanged for `MIN_SVALUE_AGE` (twenty minutes), the keeper's rule since 2026-11-25; any
    other refuses the fill that moves the leg, and a creation that holds it (`SValueUnavailable`).
  - The 344 Ondo tokens priced at a share's feed are of that kind on both chains (`script/PriceFeeds.sol`); the nine
    Pyth prices as tokens are not. Read that day near each head: BNB Chain's oracle values 340 of them and refuses 4;
    Ethereum's holds 10 of the 353 tokens and values 8, so on Ethereum an index holding one of the other 336 cannot be
    created, and a fill that moves one waits, until Ondo registers it there. No exit reads a price.
  - Ondo's oracle is its verified source, not a proxy, the same code on both chains (its code hash pinned by the fork
    suites); its admin and setter can refuse a leg or loosen the check on it toward the bar's bound, as a wrong price
    can, never past it. The factory's init code is 48,705 bytes, 447 under EIP-3860: the next change that needs room
    there moves `PythPrices` out of it, as `WeightedMath` was. Only the factory's release hash moved.
  - The keeper on BNB Chain and Base takes a factory feed of kind 4 as the share-priced id it already values at its
    sValue (`M.valuedFeedId`). Tests in `test/WeightedHub.oracle.t.sol`, `test/PythPrices.t.sol`, `test/Scripts.t.sol`
    and the Ethereum and BNB Chain fork suites (`test/fork/OndoSValues.sol`); mutants OV1 to OV10.
- **The keeper on each chain's own DEX** (2026-11-27, `docs/design/keeper-chain-venues.md`). No contract under
  `src/` changed:
  - `KeeperExecutor` reaches the chain's own DEX beside Uniswap's SwapRouter02 (`LOCAL_ROUTER`, `LOCAL_KIND`, two more
    constructor arguments): PancakeSwap's SmartRouter on BNB Chain, of SwapRouter02's calls, and Aero's
    concentrated-liquidity SwapRouter on Base, whose calls carry a deadline. A route through it is its path behind one
    byte, `LOCAL_ROUTE`; every Uniswap route means what it meant. The local router is approved for a purchase's bound
    and set back to zero after it. Aero's volatile and stable pools and PancakeSwap's V2 pairs, which have no
    exact-output swap, stay the zap's alone. The executor is 23,603 bytes, 973 under EIP-170.
  - The bot quotes each leg on both venues and takes the better within `ROUTE_MAX_LOSS_BPS` (`createVenues`,
    `localMarketOf`), Aero's through its Metaquoter by pool; its setup check refuses an executor whose local DEX is not
    the chain table's.
  - Tests: four in `keeper/test/KeeperExecutor.t.sol`, a fill through each chain's own DEX on its real pools in
    `keeper/test/KeeperExecutor.chains.fork.t.sol` (3 of 3 on each chain near its head), the route suite's; mutants
    KV1 to KV10. Not done: the keeper's end-to-end test on this change, which needs an archive node.
- **Solana, the first slice** (2026-11-28, `docs/design/solana.md`). No contract under `src/` changed. `solana/` is an
  Anchor workspace (Anchor 1.2.0), program `xindex`:
  - What was read first: Ondo's NVDAon is a Token-2022 mint with a scaled-UI multiplier, a pause, an empty
    transfer-hook slot and a freeze authority, and no permanent delegate, so on Solana Ondo can freeze or pause a leg
    but not move or burn it.
  - Built: the configuration, initialized by the upgrade authority only, with the owner's two-step handover and the
    guardian's delayed change; listings behind `LISTING_DELAY` that refuse a transfer fee, a permanent delegate, a
    non-transferable mint, accounts frozen by default, a set transfer hook and more than 9 decimals; approved
    creators; an index created in three steps, its address committing to the SHA-256 of its terms; issue through a
    ticket, deposits leg by leg checked against the vault's obligations (`Underbacked`) and what it received
    (`ShortDeposit`); redeem into a ticket that touches no leg, and claims leg by leg, whole or in part.
  - The index is a zero-copy header with its legs read in place: a Borsh copy of two hundred legs ran out of the
    32 KB heap when sealed, and an error built eagerly in a loop (`ok_or(error!(..))`) ran a redeem of two hundred
    legs out of it too.
  - Measured on LiteSVM with mainnet's features: an account's creation takes six of a transaction's 64
    instruction-trace entries, so nine deposits that create their vaults fit a transaction (701k compute units) and
    eighteen once the vaults exist (850k, 63 accounts of 64); a redeem of two hundred legs costs 65k.
  - Tests: 4 unit and 21 LiteSVM tests on Token-2022 mints built with Ondo's extensions, each revert its exact error;
    seven mutants (the backing check, the delivery check, the issue's rounding, the terms check, the seal's approval,
    the hook check, the redeem's booking) each killed by its test. Not run: a fork of Solana, a transaction's byte
    size with address lookup tables, CI.
  - The address book the same day (`solana/listing/ondo.json`, `solana/listing/read_ondo.py`): Ethereum's 353 Ondo
    tokens, every one with a Solana mint on Ondo's page, the page's Ethereum address matching the keeper's catalogue for
    all 353. Each mint read at slot 474,725,877: Token-2022, 9 decimals, its metadata naming the symbol, a scaled-UI
    multiplier, no permanent delegate, no hook, no pause; one mint authority for all, two freeze keys. Each at
    Ethereum's Pyth feed, nine at the token's own and 344 at the share's; 21 multipliers stand more than 5% from one.
    `programs/xindex/tests/ondo_book.rs` lists all 353 as their accounts were read and creates an index of two hundred.

## Product decisions, as they were made

**Solana** (the owner's calls of 2026-11-26 and 2026-11-28). On 2026-11-26 the owner asked for Solana, its large
non-meme coins and "everything Ondo supports"; the answer then was a design record and a measurement first. On
2026-11-28, told that investor material could not call Solana ready while no code existed, the owner: "მოდი დაამატე
მაშინ სოლანა კოდში", with Ondo's tokens on the Solana chain as its list. It reverses "Not planned: a Solana deployment"
of 2026-10-07. Said with it: a Solana transaction carries about eighteen legs, so creation, issue and redeem run over
several transactions; a Solana program is upgradeable until its authority is dropped; and until the rebalance, fees and
Pyth's check are ported, Solana is in development, not ready.

**A pause of minting, and no upgrade** (the owner's calls of 2026-11-23). Reading a line that said each index is a
fixed clone nobody can upgrade, the owner: "we changed, so clones could be upgradable ... it's bad actually if it's
not upgradable. It has many security risks. What if something happens? Upgrading will be better for security". What
had changed that day was the weights, not the code. Told that an upgrade key is a key that can replace the code of
every index at once, which is how the incident in that same line happened, and that the real gap was narrower,
nothing could stop new deposits into an index found to have a fault, the owner chose: "Add a mint pause". So the
owner or guardian pauses the issue of new shares, on one index or on all, only the owner resumes it, and no redeem,
claim, transfer or rebalance reads it. It amends "no pause" of every earlier version in that one respect: there is
still no pause of an exit. Not taken: upgradeable indexes. They would need another kind of clone, a timelock long
enough for holders to leave, and a full review, and would put every index behind one key.

**Creating an index is buying it, and what was decided under the owner's delegation** (the owner's calls of
2026-11-23). Of the product: "he chooses percentages, tokens that he wants to be in that index, just types in his
name, makes that index name, its logo, and then create it. And creation should be buying. Buying should create that
index"; offered the build, "Yes, build it". So `createAndIssue` creates an index and issues its first shares in one
call, the basket pulled from the creator. Then, the same day: "complete whole protocol ... you decide every
archiectural thing but i need only safest i mean the safest solution to everything". Decided under it, each of them
the owner's to reverse:
- The owner or guardian may start a rebalance a week after any fill, never before an index's first (RW-3's open
  choice). Safest of the three rules weighed: it reopens an index a sliver closed. What it adds to a hostile role's
  weekly keep-mask fills is a start without a mask, and so the same stall on an index of two components.
- Paying for a creation in USDC or USDT stays the app's to compose, with no new contract: a helper that created on a
  creator's behalf would have to hold the creator role or a consent scheme, both new surface.
- A factory without an oracle stays possible in the contract, since the deploy script refuses it on every chain it
  pins; removing the branch would rewrite the unit suites for no change on a real deployment.
- Not built, each because it widens what can go wrong more than it protects: fills open at any time at Pyth's price
  (every quote and every request bound to `rebalanceNonce` would become anyone's to invalidate); an index holding
  other indexes (a new feed kind that values a token by another contract's units); gasless signed orders (a new
  contract holding approvals).
It does not make an index impossible to empty: every holder can redeem, and the one-share rule stays.

**Changeable weights, fixed coins** (the owner's calls of 2026-11-23, `docs/design/changeable-weights.md`). Told
that an index's coins and percentages were fixed at creation: "index is unchangable after deployment even bitcoin is
changable so that unchangeability is very bad", then, offered changes in the contracts, a move to a new index in the
app, or both, "fix both". Asked who proposes, how long the notice is, and whether a coin the index does not hold may
join, the owner chose the index's creator, 7 days, and "lets not do that adding new coin after creationg that index
dosnot holds". So the weights change behind the notice, which holders can exit through, and the coins never do. It
amends the design rule on what is fixed at creation; "fixed constituents" below stands, and a new list is still a new
index, which the app's move to a successor index answers (not built yet). Said with it: a change opens a distance
between the units and the weights, which under Pyth's check a lone executor turns into at most the tolerance of what
it trades, so the change is refused on a factory without an oracle; and a weight cannot be zero, so a coin is phased
out to one basis point.

**Ondo's tokens at Pyth's price times their sValue** (the owner's call of 2026-11-27: "Pyth × sValue";
`docs/design/ondo-svalue.md`). Shown that an Ondo token priced at its share's feed is off by a split's
factor (NFLXon at a tenth), the owner chose to read each token's sValue from Ondo's `SyntheticSharesOracle` beside
Pyth's share price, over taking the split legs off the list. Asked first whether Pyth is still the oracle: it is, and
Ondo's oracle gives no price, only the shares one token stands for. It supersedes "the multiplier left out" of
2026-11-23 below. Said with it: Ethereum's oracle held 10 of the 353 tokens that day, so on Ethereum the others can
neither be created into an index nor moved by a fill until Ondo registers them; BNB Chain's held 349.

**A price that can only refuse, and an index created on its weights** (the owner's calls of 2026-11-22 and 2026-11-23,
`docs/design/pyth-check.md`). On 2026-11-22: "i think we have to add prices", then "there is no rules i am
looking for best solutions to our problems"; offered the choices, the owner took an oracle that can only refuse a fill,
and Pyth. On 2026-11-23, of a creator naming each component's units: "i don tthink that correct way of calculating
price", so `createIndex` checks the units against the weights at Pyth's prices. Offered three answers for Ondo's tokens
without an on-chain price, the owner chose their share's price, the multiplier left out, under the guardian's procedure
of 2026-10-18 around a corporate action (superseded on 2026-11-27, above: the sValue is read on chain); refusing a fill that moves one would have kept stock indexes from rebalancing,
and skipping the check for it would have let an executor skip it at will. It amends "No oracle" of 2026-11-10 below in
part: no issue, redeem or claim reads a price, and the units' check still comes first. What it costs, said to the
owner: a Hermes plan for the keeper, since every fill needs Pyth's update from the last fifteen seconds (a minute until
2026-11-27), and an update with every creation.

**Coinbase's coins and stocks on Base** (the owner's calls of 2026-11-22: "add stocks on base also", then, told that
Base's stock tokens are Coinbase's and that Backed has deployed only four wrappers of older tokens there, "add all
coinbase wrapped tokens in base"; `docs/design/coinbase-on-base.md`). Read as every token Coinbase issues on
Base: the six Coinbase Wrapped coins and its ten stock tokens, all Custodial. It reverses, for Base, the refusal of
cbBTC of 2026-11-21, and brings DOGE back on Base as Coinbase's own cbDOGE. The feed rule of 2026-11-19 is not applied
to Coinbase's stocks: the owner named them. Said with it: Coinbase can block and pause all sixteen and upgrade the
five coins it issues there; no stock token is one share; the stocks' evidence is a simulation by Base's node, not a
local fork test; and Coinbase offers the stocks outside the United States only.

**A third deployment, on Base** (the owner's call of 2026-11-21: "we have to add base . users should be able create
indexes on bnb eth and base"; `docs/design/base.md`). It reverses "no Base deployment for now" of
2026-10-18. Asked whether "users create" reopens creation, the owner kept the gate: "it should be like this. we have
to approve and give them acces to out infrastructure and index creationg", so "Only the team creates indexes" below
stands on every chain, a partner being a wallet the owner approves. Asked what Base lists, the owner first chose the
coins issued there; told that only WETH, AERO and ZRO are, MORPHO and VIRTUAL being copies of Base's own bridge, the
owner chose to add those copies: each coin of Ethereum's list whose copy Base's standard bridge mints, proven on
chain by the Ethereum token and the bridge the copy names and by the backing the bridge holds on Ethereum, labelled
Bridged, thirteen that day. It bends "Wormhole is the one bridge accepted for wrapping" for Base alone, said to the
owner: Base's bridge is run by the keys that secure Base itself, so it adds little trust beyond using Base at all.
Said with it: Base has no stock, Backed having deployed no wrapper there; Uniswap, the zap's one venue, routes a few
of the sixteen, Aerodrome holding most of Base's depth; cbBTC, a custodian the lists do not have, is not listed; and
an index lives on one chain.

**Up to 200 coins in one index** (the owner's call of 2026-11-21). The owner asked for 1,000, then 500, then, told
why neither can work, for "as much as our contracts support". Measured that day: Ethereum caps a transaction at
16.78M gas, and BNB Chain and Base show the same cap in their blocks; at 500 coins creating an index costs 56M and
minting, redeeming and rebalancing 18.5M to 22M each, so such an index could be neither created nor left. Creation
passes the cap near 234, and the limit is 200, the most that leaves every path a sixth of a transaction to spare (the
design rule "Two hundred is what the contracts carry"). It replaces "up to 100 per index", unchanged since v1. What it
gives: one index can hold all of Ethereum's list, 171 coins, or all of BNB Chain's 116. What it costs, said to the
owner: the factory's release hash moves; a 200-coin index is minted in kind, through the builder in six buys, or
through `MintRequests`, never through the zap, which stops near 35; and a fill of that many legs fits a transaction
only for an executor that already holds the coins. 500 or 1,000 stays possible only as another design, with
creation, issue, redeem and the fill each spread over several transactions; not taken.

**Two deployments, each holding its chain's coins in kind** (the owner's call of 2026-11-13: "we are the ones who
create indexes now. lets also create bnb chain factory or whatever is neccesery so on both sides we will have in kind
tokens. we will have more little list on ETH but no problem"; `docs/design/bnb-chain.md`). Ethereum
and BNB Chain each get the same contracts under their own Safes; nothing crosses, and an index lives on one chain.
It came after the owner asked whether an Ethereum index could keep its collateral on another chain: it can only with
vaults of our own, which stay refused. It reverses the owner's refusal of a BNB Chain deployment on 2026-11-10 and,
in part, "One index on Ethereum" of 2026-10-10 below: no single index holds every listed coin any more. Said to the
owner with it: a buyer who wants both chains' coins buys two tokens; nine of BNB Chain's twelve coins are Binance's
custody, with Wormhole no party there; and Uniswap, still the zap's only venue, has a market for six of the twelve.
Decided the same day (the owner: "we have to delete bnb ones and that bnb ones should be on bnb chain that we built
today"): the six Wormhole copies wrapped from BNB Chain (XRP, ADA, LTC, DOT, ATOM, BNB) leave Ethereum's list, and
those coins are held on BNB Chain in kind; the nine copies from other chains stay on Ethereum, since neither chain has
an in-kind home for them (asked whether all fifteen should go, the owner kept them). Their addresses stay recorded in
`script/MainnetAddresses.sol` for a relisting, and the keeper's restock serves AVAX, OP and AERO by default. Not
decided then: PancakeSwap as a venue on BNB Chain, which the owner took on 2026-11-26 ("Each chain's own DEX beside
Uniswap", below).

**USDC and USDT are the only currencies** (the owner's call of 2026-11-18: "lets leave payments with only stable coins
usdt and usdc"). Asked whether the contracts should enforce it or the app alone, the owner chose the contracts: the zap
and the basket builder take and pay the deployment's USDC and USDT and revert `NotAStable` on anything else, and no
entry point takes ether. It reverses the ether entry of 2026-10-29, and narrows the burn, which had paid out any token
the caller named. `MintRequests` already took the two alone. The app's ether paths follow when it moves to this build
(asked the same day, the owner kept this change to the contracts for now).

**The leftovers deleted** (the owner's call of 2026-11-25: asked to find and delete the repository's leftovers, then,
told that what was left over was kept by earlier calls for a relisting and asked whether it is needed, "კი, წაშალე",
yes, delete). The restock's Solana, Sui, Aptos and Algorand signers (about 13,000 lines, never run), the owner's
attestation tool that ran on them, the Wormhole copies of XRP, ADA, LTC, DOT, ATOM, BNB, JUP, PYTH, SUI, APT and ALGO
in `MainnetAddresses` and the restock's table, and the restock's BNB Chain home went
(`audits/retired/non-evm-restock.md`, which keeps their addresses). The restock's home chains are
Avalanche, Optimism and Base. OP's copy stays, the call of 2026-11-21 having taken it off "for now". A Wormhole copy
still to attest is attested through Wormhole's own SDK; one with no Ethereum pool has no restock to serve it. The
local worktrees of the xStocks and Ondo branches went too; the branches stay.

**Anthropic's Ondo token on both chains** (the owner's call of 2026-11-25: "both to eth and bnb", after asking "do we
support anthropics stock? it is added in ondo stocks"). ANTon, Ondo's token of Anthropic PBC, which Ondo issued for
Anthropic's IPO after the list of 2026-11-19 was read, is listed on Ethereum (`0x43a0943893474F246aA58e9921d975aD60Adee59`)
and on BNB Chain (`0x343ccbc9f8409f862008b7abebFFf20ECf935C75`), Custodial, each read from Ondo's app and on chain
behind its chain's Ondo beacon with NVDAon's proxy code. Pyth has no feed for the token, so it is priced at Pyth's 24/7
price for the share (`Equity.Index.ANT/USD`), by the list's rule, and is one of the share-priced legs the keeper leaves
alone. Said to the owner with it: Pyth's catalogue gives that feed the regular-hours schedule, so a creation or a fill
that needs its price may wait for the US session, while no exit reads a price; and the BNB Chain suite's pin moved
past ANTon's first block there.

**Ondo's stocks and ETFs, and no xStocks** (the owner's call of 2026-11-22: "delete everything releated to xtokcs and
leave only ondo", after asking "which has more coverage ondo or xstocks"). Every Ondo stock and ETF with a Pyth feed is
listed on Ethereum and on BNB Chain, 352 on each (USDY and OUSG, cash tokens, are not; the 127 without a feed join as
Pyth publishes one), including the oil, gold, silver, platinum and copper funds the owner asked about the same day.
Backed's wrapped xStocks, listed on 2026-11-21 in place of Ondo's 17 stocks ("use xstock 100 percent and delte ondo"),
are gone, and the call of 2026-11-19 to list every Ondo stock and ETF stands again. Said to the owner before it: Ondo
covers about three times as much (87 of the 109 xStocks are on both; 22, Berkshire among them, are on xStocks alone);
an Ondo token tracks shares through a multiplier its balance never shows, so the keeper values only the 9 with a feed
of their own and leaves the other 343 alone (RX-2): they mint in kind or through `MintRequests`; Ondo's mint and redeem
desk serves eligible non-US users only; and the collaboration the team planned with Backed was the reason for the call
of 2026-11-21 (`docs/design/ondo-stocks.md`).

**OP's copy off the list** (the owner's call of 2026-11-21: "remove op for now"). The restock's end-to-end test
could not buy OP on Optimism that day: with OP near $0.07, Uniswap v3's deepest OP pool there held about $35,000 of
USDC, and $1,430 of OP cost 4.7% over the pools' price, past `ROUTE_MAX_LOSS_BPS` at every size the halving reached.
No Ethereum pool trades the copy, so an index holding it would rebalance it from an operator's stock alone. It left
`script/Listings.sol`, the keeper's catalogue and the restock's default coins; its address stays in
`MainnetAddresses` and its row in the restock's table, for a relisting once its pools deepen or the restock has
another venue there. AVAX's and AERO's copies, which the same test bought and bridged that day, stay, and SOL's.

**Five Wormhole copies off the list** (the owner's call of 2026-11-18: "for now, let's just remove" them, since the
team creates every index and tells partners what it holds). JUP, PYTH, SUI, APT and ALGO left `script/Listings.sol`:
no Ethereum pool trades their copies, so a rebalance buys them only from stock bridged in from Solana, Sui, Aptos or
Algorand, and that restock has never sent a transaction; the local chains cannot run their venues, so proving it
would take a live run with funded wallets. SOL's copy stays, which a Uniswap V3 pool against WETH trades at the
market (read that day: $74.63 a coin against OKX's $74.76, a $22k sale 0.5% worse than one coin), and so do AVAX,
OP and AERO, which the EVM restock serves. The addresses stayed in `MainnetAddresses` and the signers in
`keeper/restock/`, for a relisting once a live run had proven them, until 2026-11-25 (below). Asked before it, the owner weighed a token that
tracks prices without holding the coins; it was not taken, since it needs a price feed and a counterparty to every
gain, the opposite of "No oracle" below.

**No oracle** (the owner's call of 2026-11-10: "we have to cut off oracles somehow and keep rebalance safely", then
"yes build oracle free rebalance"). No contract reads a price. An index still rebalances toward its fixed percentages,
through an auction in which the executor names the units and the index checks a gain in units against a falling bar
(`docs/design/rebalance.md`). The owner's reason: "there are too many hacks nowadays", and this
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
`docs/design/wormhole-legs.md`): one deployment, on Ethereum; an index holds up to 100 coins of the top
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
  open, or with the stock kept. The legal question of offering stocks is the owner's. The 17 Ondo stocks left on
  2026-11-21 for Backed's wrapped xStocks and came back on 2026-11-22 with every other Ondo stock and ETF (above);
  Tether Gold stays.
- TRX was held as the BEP-20 TRX of TRON's closed BTTC bridge, on BNB Chain; with that deployment deleted it is not
  listed, and its Ethereum copy is not either.
- Bitcoin is held as WBTC (the owner's call on 2026-09-29; do not reopen it).
- DOGE is off the list for now (the owner's call on 2026-10-14). Its only listable form was Wormhole's copy of
  Binance-Peg DOGE, and Pyth prices DOGE, not the copy: a broken peg or bridge would leave the copy priced as DOGE.
  Binance-Peg DOGE is a proxy whose admin, one externally owned key on BNB Chain, can replace its code (read that
  day). The copy's address stays recorded in `script/MainnetAddresses.sol` for a relisting. XRP, whose Binance-Peg
  source answers `mint(uint256)` to one key but cannot change its code, stays listed.
- The owner's calls of 2026-10-18 on the source reading (`docs/design/token-source-reading.md`): SAND and RLB
  are off the list. SAND's two multisig admins and 22 operator contracts can move or burn any holder's balance with no
  timelock, which the WBT rule exists to stop even without a blacklist; RLB's implementation is unverified and one
  externally owned key can upgrade it. H, PLUME, SNX, SYRUP, GALA and MANA stay, their admins' powers named by the app;
  MANA, CHZ, SENT and FLUID are labelled Pausable. Wormhole's copies of BNB, SUI and SEI joined the list the same day.
- The twelve Ondo legs priced at their share's feed stay (the owner's call of 2026-10-18), under the procedure of
  `docs/design/pre-mainnet-readings.md`, section 2: the guardian keeps an affected leg around a corporate action,
  and a leg is relisted at its token's own feed once Pyth publishes one. The procedure also has the guardian cancel each
  auction of an index that cannot keep such a leg around a split (a two-leg index), the keeper's stock allowance for
  those legs stays at zero, and Ondo's terminations, paid only to KYC'd redeemers, are a loss for holders still in at
  the date, so the app tells them to exit first (RX-2, RX-7, RX-29). Moot since 2026-11-21, when the Ondo legs left
  the list; it applies again to any relisting.
- The owner's calls of 2026-10-19 on the red team (`audits/internal/red-team-rx.md`): BTT and SEI's Wormhole copy are off
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

**UniswapX in the keeper's restock, not the zap** (the owner's call of 2026-11-24, "კეეპერში ჩააშენე"). The restock
buys the nine Ondo stocks the keeper values through UniswapX's orders on Ethereum and deposits them into the executor
(`docs/design/uniswapx-restock.md`). Said with it: UniswapX has no pools, so the zap, which settles a basket in
one transaction, cannot use it, and the swap venues below are unchanged; Ondo's 343 share-priced stocks gain nothing,
since the keeper never delivers them from stock; and Ondo sells them to eligible users only.

**Each chain's own DEX beside Uniswap** (the owner's call of 2026-11-26: "ეთერიუმი იყოს უნისვაპზე მარა ყველა ჩეინს
თავის დექსზე აქვს დიდი ლიკვიდობები რაც ჩვენ გვაწყობს", let Ethereum be on Uniswap, but every chain has deep liquidity
on its own DEX; then, shown the depth, "Uniswap stays on every chain, each chain adds its DEX, each leg names the
deeper pool", and "read their docs first"; `docs/design/chain-venues.md`). BNB Chain adds PancakeSwap, Base
adds Aero, Ethereum stays on Uniswap alone. It reverses the call of 2026-10-14 below for BNB Chain and Base. Read
before the build: both routers' verified source on Sourcify (exact matches), Aero's deployment records, PancakeSwap's
and Aero's documentation. Measured that day: PancakeSwap is the deeper venue for nearly every coin on BNB Chain
(BTCB $21M against Uniswap's $6.4M); on Base Uniswap stays the deeper for WETH and cbBTC and Aero for AERO, AAVE,
MORPHO, cbETH and Coinbase's stocks, which is why Uniswap was kept there. Asked next, the owner moved Base's AERO to
Aero's token ("კი, გადაიყვანე", yes, move it): Base's list holds `0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee` since
2026-11-26, where Aerodrome's `0x940181a9...8631` stood, which Aero's migration converts one for one while Aero keeps it
open. Then Ethereum's Wormhole copy of the old token left Ethereum's list ("კი, ამოიღე", yes, take it out): it
redeems to the old token alone, whose depth is leaving and whose conversion Aero can end. Its address stays in
`MainnetAddresses` and its row in the restock's table, for a relisting, as OP's do. Then CAKE joined BNB Chain's list
on 2026-11-27 ("cake bnb ში დავამატოთ", let us add CAKE on BNB), once the liquidity count showed Ethereum's CAKE with
about $700 on Uniswap and BNB Chain's CAKE deep on PancakeSwap. Ethereum's CAKE stays listed.

**The bridged copies stay** (the owner's call of 2026-11-27: "ყველა დარჩეს", let them all stay). The owner first asked
to list only tokens issued on each chain, then asked whether the copies cause any problem. Counted that day on
Uniswap's V3 pools, Ethereum's 61 coins outside Ondo were 5 near zero, 21 thin, 12 moderate and 23 deep, natives and
copies alike, and Ondo's stocks have no pool on any chain: thin depth is no mark of a copy, and such a leg mints in
kind, through `MintRequests` or from stock. Removing ICP's and AVAX's copies alone was offered and not taken. Every
Wormhole copy and every copy of Base's bridge stays listed, each labelled Bridged.

**Swap venues** (the owner's call on 2026-10-14, reversed for BNB Chain and Base on 2026-11-26, above): the zap swaps
through Uniswap's Universal Router 2.0.0 alone, V3 or V4 per leg, chosen by the caller. PancakeSwap's v3 Universal Router, a third venue per leg since 2026-10-06 (chiefly
for CAKE), and THORChain, an app-side rail added the same day (`docs/design/retired/swap-venues-pancakeswap-thorchain.md`), were both removed on
2026-10-14: users come with USDC or USDT (from 2026-10-29 to 2026-11-18 also with ether, through the zap's
`mintWithEth` and `burnToEth`; fiat and other-chain entry stay app-side and undecided). CAKE stays listed; its legs route through Uniswap's pools, or it mints in
kind or through `MintRequests`.

**Fees, cadence and private indexes** (built 2026-10-14 on the research record's defaults): fees in shares with the
platform's policy at zero until the owner sets one, so the no-fee call of 2026-09-30 survives as a configuration; a
rebalance interval per index from 7 to 91 days; a private index is one the app does not list plus, if the creator
chose it, a mint allowlist the creator keeps. The owner's calls of 2026-10-18 on the record's section 9: the cadence
menu is {7, 14, 30, 91} days; private indexes are unlisted and mint-gated, both opt-in; Xindex runs the first filler;
the basket builder ships at launch; the replay decides the hardenings; the coin pages show the listed set and tiers;
no Base deployment for now (reversed on 2026-11-21, above); the creation fee is zero. The platform's fee, the referrer's share and the platform's
streaming rate are not decided yet; the legal reading is counsel's.

**Unchanged from earlier versions:** an owner Safe of at least three signatures; fixed constituents; no protocol bots
or hot keys; component whitelist only; the burner chooses the exit stablecoin, USDC or USDT, or exits in kind; the mint
currency is not tracked per holder.

If a change would alter any of these, say so explicitly.
