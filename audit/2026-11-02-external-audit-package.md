# External audit package (2026-11-02)

The brief for the external auditors, step 5 of the logic-hardening plan: what to audit, at which commit, how to build
it, what the system promises, who is trusted with what, where we want the most attention, and what every earlier
review found. It points to the repository's own records rather than repeating them; `AGENTS.md` is the full rule
book, and every rule there that says "must" or "never" is a property we expect the audit to try to break.

## 1. Commit

The candidate is `main` at `f2f4c18c9015292702bce18151f26eb1ae3dbafb` (2026-11-02), whose CI passed: 590 forge
tests with the five Ethereum fork suites (0 skipped), coverage 100% of lines, statements, branches and functions on
every file, the mutation gate (87 mutants, every one killed), and the keeper's forge and node suites.

It is a candidate, not the freeze. Three things can still change `src/` before the freeze, and each is listed in
section 9:

1. Pyth's parameter replay sizes `MAX_EMA_DEVIATION` and `MAX_GROWTH` (and confirms `MU_MIN`, `MAX_TURNOVER` and
   `MAX_CONFIDENCE`). They are constants of `WeightedHub` and `WeightedMath`, so a new value is new bytecode.
2. RB-5, a one-line hardening of `IndexZap._checkIndexCall`, waits on the owner's call.
3. Any fix this audit asks for.

The frozen commit is the one `DeployWeighted`'s five release hashes (`FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH`,
`BUILDER_INITCODE_HASH`, `REQUESTS_INITCODE_HASH`, `RELAY_INITCODE_HASH`) are fixed at; on chain 1 the script deploys
no other build (CF-5). Findings against the candidate carry over: we re-read each against the frozen commit.

## 2. Scope

### Primary: the contracts that hold or move users' funds

nSLOC counts non-blank lines outside comments.

| File | nSLOC | Holds or moves |
|---|---:|---|
| `src/WeightedHub.sol` | 681 | Each index: an ERC-20 clone that holds its components in kind; issue, redeem, `redeemSkipping`, claims, fees in shares, the streaming fee's unit scale, the rebalance auction and its settlement at Pyth prices |
| `src/WeightedIndexFactory.sol` | 379 | Listings behind a timelock, index creation by CREATE2 clone, the guardian's timelocked change, the fee policy, the creator role, gates and allowlists |
| `src/WeightedMath.sol` | 132 | The settlement arithmetic, stateless, called by STATICCALL (moved out of the hub for EIP-170) |
| `src/IndexZap.sol` | 204 | Stateless: mints from and burns to USDC, USDT or ether through Uniswap's Universal Router; permits |
| `src/UniversalRouterSwaps.sol` | 177 | The swap engine the zap and the builder share: every router command built in-house, pre-funding and `SWEEP` |
| `src/BasketBuilder.sol` | 189 | Stateful: per-user escrows for baskets too wide for one transaction (buy over several calls, then issue; redeem, then sell) |
| `src/MintRequests.sol` | 117 | Escrowed limit orders (stablecoin for shares, shares for stablecoin) that anyone fills before a deadline |
| `src/GuardianRelay.sol` | 42 | Holds the guardian role for a Safe; lets anyone send a start the Safe authorized (RZ-26) |
| `src/libraries/*.sol` | 52 | Path packing, V4 types, command bytes |
| `src/interfaces/*.sol` | 624 | Declarations; `pyth/` is copied from Pyth (Apache-2.0, `NOTICE`) |

1,973 nSLOC of implementation, 2,597 with the interfaces. Solidity 0.8.28, EVM `cancun`, optimizer on at 100 runs,
no via-IR. Dependencies, pinned as submodules and in `foundry.lock`: OpenZeppelin Contracts at `cab19933c3`
(`Ownable2Step`, `Clones`, `SafeERC20`, `ReentrancyGuard`, `Math`, `SafeCast`, `Address`) and OpenZeppelin Contracts
Upgradeable v5.7.0 (`Initializable`, `ERC20Upgradeable`). No proxy is upgradeable: indexes are minimal clones of one
implementation.

### Secondary: what makes a deployment correct

| File | Why |
|---|---|
| `script/DeployWeighted.s.sol`, `script/DeployChecks.sol` | Refuse a weak owner (a Safe below 3 signatures, with a module, an EIP-7702 account), overlapping roles, a market contract as a role, unpinned market addresses on chain 1, and any build but the released one |
| `script/MainnetAddresses.sol`, `script/PythIds.sol` | The address book and the 91 listings with their Pyth price ids; `test_CRL08_theListsAreTheReleaseRecord` pins them against an independent table |
| `script/ConfigureWeighted.s.sol` | Proposes and executes the listings through the owner's Safe |

### Optional: the keeper's executor

`keeper/src/KeeperExecutor.sol` (415 nSLOC) is the executor the reference keeper uses. It holds no protocol role and
only its operator's funds (a USDC float and a stock of coins without a Uniswap route); an attacker who breaks it takes
the operator's money, not holders'. Its bounds (stock and restock allowances the operator's owner sets, RS-1) are worth
a read if time allows.

### Out of scope

The keeper bot and restock service (`keeper/*.mjs`, Node), the invariant checker, `script/CheckToken.s.sol` (a
read-only report), `script/testnet/`, tests and mocks, and the web app (its own repository).

## 3. Build and run

```bash
git clone --recurse-submodules <repo> && cd <repo> && git checkout f2f4c18
forge build --sizes --deny warnings
forge test                           # 545 tests without an RPC; the fork suites skip
MAINNET_RPC_URL=<archive RPC> forge test --match-path 'test/fork/*'   # the five fork suites, 45 tests
forge coverage                       # 100% on every file
python3 -I test/mutants/run.py       # the mutation gate, about two minutes
forge test --root keeper             # the executor's suite
```

Foundry v1.8.1 is the version CI pins. `WeightedHub.fork.t.sol` takes about an hour on a cold archive RPC (Alchemy,
Tenderly), nearly all of it admission quotes; a public endpoint prunes the state before it ends. `docs/development.md`
has the rest.

## 4. The system in one page

A creator calls `createIndex` with two to a hundred listed coins, each with its units per share and its weight, fixed
for the index's life, plus its fee rates and rebalance interval (7 to 91 days). The factory clones the hub at a CREATE2
address whose salt commits to all of it.

- **Issue** takes each component's backing for the shares (rounded up) and mints them; **redeem** burns shares and
  pays each component's backing (rounded down). Neither reads a price. `redeemSkipping` leaves named components in
  the index as claims booked to the recipient, so a frozen token cannot trap the rest.
- **Fees** are shares, never components: a mint and a burn fee to the creator, the platform and a referrer, and a
  yearly streaming fee charged by lowering a unit scale every share's units carry.
- **Rebalancing** brings the index back to its weights at Pyth prices. Once the interval has passed anyone starts one
  (`startRebalance`, which parses every moving feed's update in the start's own window and keeps no price, only proof
  that every market is open); after a 2-hour notice a 4-hour Dutch auction runs, `μ` falling from `MU_MAX` to `MU_MIN`
  (0.98). An executor fills it with a Pyth update for the second the hub fixes (`priceTime()`, one slot back); the
  hub prices each moving leg, computes the trade with `WeightedMath`, calls the executor back with what it sends out
  and what it must deliver, and checks the backing invariant after. A fill moves each leg at most `MAX_TURNOVER`
  (20%) of its units out, or `μ · MAX_GROWTH` (100%) of its units in, so a wrong price takes a bounded share, at most
  once per interval.
- The **zap**, the **basket builder** and **`MintRequests`** sit outside the hub and use only issue and redeem.

`ARCHITECTURE.md`, `design/2026-10-05-custom-weights.md` (the spec) and
`design/2026-10-29-rebalance-state-machine.md` (eight states, every transition) say more.

## 5. Roles and trust

| Party | Can | Cannot |
|---|---|---|
| Owner (a Safe of at least 3 signatures, 3-of-5 by design) | Propose listings (2-day delay) and guardian changes (7 days); delist; set the fee policy for later indexes; transfer ownership in two steps | Touch any index's funds, units, weights or rates; pause; upgrade; sweep |
| Guardian (a Safe, through `GuardianRelay`) | Cancel a rebalance or a pending listing; delist; start a rebalance early or with a keep mask (a coin left out); cancel a guardian change that would remove it | Move funds; block its own replacement |
| Creator of an index | Gate minting to an allowlist and open it for good; hand the role on in two steps | Change components, rates, or anyone's shares |
| Executor (anyone) | Fill an auction at the hub's prices within the caps, and choose the block | Name the price time, widen the window, or take beyond the caps |
| Pyth (three of its five keys, OP-PIP-132) | Sign any price, or upgrade Pyth's contract | Move a fill beyond the caps, or touch issue, redeem or claims |
| Wormhole's guardians (13 of 19) | Mint a wrapped leg's token or upgrade its bridge: the whole value of that leg (15 of the 91 listings are wrapped) | Reach Ethereum-issued legs |
| Token issuers | Pause, blacklist, and for some burn a holder's balance (WBTC, Tether Gold, Ondo's stocks and others, labelled in the app) | Reach other legs: `redeemSkipping` leaves the frozen one behind |

There is no keeper or bot role, no pause, no upgrade, no sweep and no renounce. `AGENTS.md` ("No admin power over
funds, no rebalancing key") and `docs/design.md`'s Governance row record why each power is where it is.

## 6. Properties we expect to hold

Each has tests named in `AGENTS.md`; we want each tried.

1. **Backing.** For every component `i`:
   `balanceOf(index) >= floor(totalSupply · units_i · scale / 1e36) + totalClaims[i]`, after every call, every
   interleaving, and every rounding (issue up, redeem down, new units up, a leaving leg's step down).
2. **Holders can always leave.** `redeem` and `redeemSkipping` work in every rebalance state, with any subset of
   components frozen, and claims are payable once transfers resume. No speed limit, no cap on a burn.
3. **Only the settlement and the start read a price.** The hub calls Pyth at one site, the parse both share; issue,
   redeem, claims and every preview never call it (`previewRebalance` takes feeds its caller parsed), and no other
   contract names Pyth (`test_V5I4_onlyTheWeightedHubReadsAPrice`).
4. **One price per block.** The hub fixes the second; Pyth's `parsePriceFeedUpdatesUnique` returns each feed's first
   update at or after it, published before the block; ids and publish times are checked; a price is refused when
   non-positive, outside the exponent range, above `MAX_PRICE`, with a confidence wider than `MAX_CONFIDENCE`, or
   further than `MAX_EMA_DEVIATION` (5%) from the moving average in the same update.
5. **The caps count units.** Whatever the prices, a fill sends out at most 20% of each leg's units and adds at most
   `μ` times its units to a growing leg; a fill worth less than `MIN_TRADE` (0.1%) of the moving value reverts.
6. **Executors are untrusted.** Tokens and the callback go only to `msg.sender`; every mutating entry point shares
   the reentrancy guard; state is written before any rebalance transfer.
7. **No power over funds.** No role can move a component except through issue, redeem, claims and settlements.
8. **The zap and the builder take nothing.** Every amount is measured as a balance change inside the call; a caller's
   calldata never reaches the router; a leg's limit binds, the pass-through leg's included.
9. **`MintRequests` holds exactly its open escrows** (plus donations), under any interleaving with USDT's fee switch.
10. **The salt commits to every term**, so no two configurations share an address and no relisting reaches an
    existing index.

## 7. Where we want the most attention

In order:

1. **The settlement arithmetic** (`WeightedMath.settlement`, the hub's `_settle`): the turnover and growth caps, the
   `μ` bound, the roundings, the scale, units at the `uint96` edge (RX-61) and `mulDiv` near 256 bits (RZ-33). The
   exact model's 375 vectors replay word for word and z3 proves the model's properties for two legs, and for three
   all but the `μ` bound's last step, done by hand (`design/2026-10-29-settlement-proofs.md`); Halmos could not finish
   the contract itself, and Certora was not run.
2. **The price path**: the window, the uniqueness of the update, the EMA and confidence bounds, the decimals scaling
   (`price · 10^(36 + expo − decimals)`), the start's read of every moving feed (RX-3), and what a malicious executor
   can choose (the block, the update bytes, the order against exits).
3. **Fees and the scale**: the mint and burn fee shares, recipient replacement (a recipient that cannot hold shares is
   swapped so none can block a mint or an exit), the referrer under a gate (AU-1), the streaming accrual's clock
   (XS-1), and the scale never folded into units (XS-2).
4. **Issue's guards**: the backing check that refuses a mint while a leg is below its backing (RX-8), the one-wei
   self-transfer that proves a grown leg can leave (RX-12), fee-on-transfer detection.
5. **The zap and the builder**: command construction, balance measurement, the sweep, V4 routes that revisit
   `tokenIn`, unsold input, ether in and out, permits, the builder's escrow accounting across buys, redeems and sells.
6. **`GuardianRelay`**: that a start it sends is exactly the one the Safe authorized, once, before its deadline, and
   that the relay adds no power the guardian lacks.
7. **Factory lifecycle**: listing proposals and their windows, delisting, the guardian change, clone initialization
   (only initialized clones issue, redeem or rebalance), CREATE2 salt collisions.
8. **Gas at 100 components** under EIP-7825's 2^24 cap: `createIndex` about 10.7M, `redeemSkipping` with every
   component skipped 5.1M, a 93-leg fill 7.26M with Pyth's real contract on a fork.

## 8. Accepted risks and known limitations

`docs/known-limitations.md` is the list, each entry with its bound. In short: a lone executor can take up to 2% of
what it trades (`MU_MIN`); a wrong price costs at most the turnover cap; rebalancing needs Pyth's paid Hermes;
wrapped legs rest on Wormhole and their home chains; a collapsing coin can stop the fills until the guardian keeps it
(V5-L3, RZ-4); an issuer's corporate action is not accounted for (CF-3); price ids are owner-maintained data; small
indexes rarely rebalance; an exit sent during an auction can be overtaken by the fill (RT-02); the guardian can stall
rebalancing (DA-12, bounded by its replacement); issuers can freeze and some can burn components; a request's
surplus goes to the fastest filler; fees are shares only; the basket builder is one custody point; airdrops to an
index are stranded; hooked V4 pools cannot be routed; `PYTH` cannot be repointed; a builder that is also the executor
sees further under ePBS; zap gas grows with components and nothing on chain bounds it.

## 9. Earlier reviews

Every review of v5's code since 2026-10-05, all internal. Each record has a status table naming the regression test
of every testable finding; `AGENTS.md`'s definition of done lists the id families. Records before v5 (v1 to v4 and
Stage B) are in `audit/` too; the retirement records say which of their ids went with the mechanism they tested.

| Record | Ids | Scope | Findings | Open |
|---|---|---|---:|---|
| `2026-10-05-v5-review.md` | `V5-…` | The weighted hub and factory | 9 | none |
| `2026-10-07-v5-logic-review.md` | `V5R-…` | The settlement's logic | 3 | none |
| `2026-10-13-security-audit.md` | `CF-1`..`CF-8` | Whole repository (Cloudflare's security-audit skill) | 8 | none; CF-3 is a known limitation |
| `2026-10-16-security-audit.md` | `XS-1`..`XS-18` | The engine of 2026-10-14 to 16: fees, scale, builder, keeper | 18 | none |
| `2026-10-18-red-team.md` | `RX-1`..`RX-67` | Whole system, adversarial | 67 | none |
| `2026-10-25-restock-review.md` | `RS-…` | The restock service and executor | 15 | none |
| `2026-10-25-skills-audit-port.md` | `A7-…`, `A1a-…` | The skills audit's eight findings still open | 8 | none |
| `2026-10-28-rebalance-review.md` | `RB-1`..`RB-5` | Rebalancing | 5 | RB-5 (owner's call, section 1) |
| `2026-10-31-review.md` | `AU-1`..`AU-3` | Whole system | 3 | none |
| `2026-10-31-red-team.md` | `RY-1`..`RY-9` | Whole system, adversarial | 9 | RY-3 (policy, waits on the fee policy) |
| `2026-10-31-red-team-ii.md` | `RZ-1`..`RZ-33` | Whole system, adversarial | 33 | keeper and test items, below |
| `2026-11-01-protocol-docs-review.md` | `PD-1`..`PD-14` | Every protocol used, against its own docs | 14 | none |

Still open, none of them in the primary scope's code:

- **RB-5** (informational): the zap refuses as `to` only the index it mints or burns, while the builder refuses
  every factory index. One line; it moves the release hashes, so it is decided before the freeze.
- **RY-3** (informational, policy): a minter may name itself as referrer and take the referral share of the
  platform's fee. Deferred by the owner to the fee policy; a check on chain is dodged by a second wallet.
- **RZ-6, RZ-13, RZ-15, RZ-16, RZ-19**: keeper and restock bookkeeping (out of scope).
- **RZ-17, RZ-27**: a start's gas and a settlement measured on a real Hermes update, part of the pre-mainnet list.
- **RZ-33**: settlement vectors near a `mulDiv`'s 256-bit edge and the `uint96` boundary need new kinds in the model.
- **XA-34**: two fork tests keep a bare `vm.expectRevert()`; pinning their revert data needs a fork run.

## 10. Assurance already done

- **Tests.** 545 unit, fuzz and invariant tests without an RPC, and 45 in five fork suites on Ethereum's real tokens,
  Universal Router, V3 and V4 pools and Pyth's contract; coverage 100% on every file, mocks and scripts included.
  Invariant suites for the hub (the backing invariant under random issue, redeem, fees, claims, rebalances and
  freezes) and for `MintRequests`.
- **The state machine.** `test/WeightedHub.states.t.sol` takes every cell of the transition matrix.
- **The exact model.** `test/vectors/settlement.py` (written from the spec, standard library only) generates 375
  vectors that `test/WeightedMath.vectors.t.sol` replays against the contract word for word.
- **Proofs.** z3 on the model (`test/vectors/proofs.py`): two legs in full, three legs but one hand step.
- **Mutation gate.** 87 mutants as exact edits (`test/mutants/mutants.json`), every one killed, in CI.
- **Static analysis.** `forge lint` with notes denied, Wake (`wake detect all src`) and Aderyn report nothing on
  `src/`; each suppression carries its reason where it stands.
- **End to end.** The keeper on an anvil fork of Ethereum with Pyth's real contract verifying updates signed by keys
  the test installs: 23 checks pass (2026-11-02), the guardian relay's start among them.
- **Deployment rehearsal.** v5 has run on Sepolia since 2026-10-26, from `07aeae1`, a build before the RX-3 fix.

What has not been done: an external audit, a formal proof of the hub itself, a settlement on a real Hermes update
(it waits on a paid Pyth plan), and a mainnet deployment.
