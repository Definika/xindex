# External audit package (2026-11-21)

The brief for the external auditors: what to audit, at which commit, how to build it, what the system promises, who
is trusted with what, where we want the most attention, and what every earlier review found. It replaces
`audit/2026-11-02-external-audit-package.md`, which described the build that rebalanced at Pyth's prices and is kept
as written. It points to the repository's own records rather than repeating them; `CLAUDE.md` is the full rule book,
and every rule there that says "must" or "never" is a property we expect the audit to try to break.

Every earlier review in this repository is internal, the work of agents and of the team. None is an external audit.

> **This package predates the build (noted 2026-11-23).** It describes the candidate of section 1. The working tree
> of the branch `feat/pyth-check` has since changed `src/` in ways an audit must cover, none of them committed or
> packaged yet:
>
> - Pyth's check on every fill, through a new contract, `PythPrices`, and `WeightedMath.oracleCheck`; price feeds
>   per token on the factory (`design/2026-11-22-pyth-check.md`).
> - A creation held to its weights at Pyth's prices (`OffWeights`), and weights the creator can change behind 7 days
>   of notice (`design/2026-11-23-changeable-weights.md`).
> - `createAndIssue`: a creation that issues the index's first shares in the hub's initializer, the basket pulled
>   from the creator, the one place the hub pulls from an account other than its caller.
> - The owner or guardian may start a rebalance `MIN_REBALANCE_INTERVAL` after any fill (RW-3).
> - `PythPrices` refuses a value of zero.
> - A pause of minting on the factory (`pauseMinting`, `resumeMinting`), which only an issue reads.
> - `acceptCreator` cancels a change of weights the outgoing creator left pending (HK-16,
>   `audit/2026-11-23-attack-replay.md`, a replay of twenty classes of past attacks against this build).
> - In `keeper/`: `KeeperExecutor.fill` is payable and posts Pyth's update before it fills.
>
> `CLAUDE.md`'s bullets of 2026-11-22 and 2026-11-23 describe each, with its tests and mutants. Sections 1 and 2
> below, the scope, the roles and the properties need rewriting for that build, at its commit, before this goes to
> an auditor.

## 1. Commit

The candidate is the branch `release/2026-11-21-candidate` at `e2508f71d98209ae2db5422bc1d50cd1bb9da903`. It is
`main` at `5b7635f` with five things on top: the fixes of the audit of 2026-11-21
(`audit/2026-11-21-consolidated-audit.md`), which changed all four deployed contracts; the listing of every Ondo
stock and ETF Pyth has a feed for, 352 on Ethereum and on BNB Chain (`design/2026-11-22-ondo-stocks-and-etfs.md`,
in place of Backed's wrapped xStocks, listed on 2026-11-21 and removed on 2026-11-22), which changed no contract;
`MAX_COMPONENTS` raised from 100 to
200, which moved the factory's release hash; OP's Wormhole copy off Ethereum's list; and a third deployment, on
Base (`design/2026-11-21-base-deployment.md`), an address book, a list, deploy checks and a fork suite, which
changed no contract either, with Coinbase's coins and stock tokens on its list since 2026-11-22
(`design/2026-11-22-coinbase-on-base.md`). `src/` is as it was at `720a2f7`. This file is the one commit after it.
Its gates were run where it was built, not in CI, since the branch has not been pushed:

| Gate | Result |
|---|---|
| `forge fmt --check`, `forge build --sizes --deny warnings`, `forge lint -D notes` | clean, for the repository and for `keeper/` |
| `forge test`, fork suites aside | 566 passing, none failing |
| `forge coverage` | 100% of lines, statements, branches and functions on every file |
| The mutation gate | 232 of 232 mutants killed |
| `python3 -I test/vectors/proofs.py` | every step proven |
| Aderyn, `wake detect all src` | no finding, no detection, at `720a2f7`; `src/` has not changed since |
| Ethereum's five fork suites, on an archive RPC at the pinned block 26,033,838 | `IndexZap.fork` 12 of 12, `WeightedHub.fork` 6 of 6 (170 of the 171 listed coins in one index: `issue` 10.4M gas, `redeem` 6.9M), `CheckToken.fork` 9 of 9, `MainnetAddresses.fork` 9 of 9, `Security.fork` 11 of 11; none skipped |
| BNB Chain's fork suite, at its pinned block 134,768,771 | 17 of 17 |
| Base's two fork suites, at their pinned block 60,529,140, on a public node while that block was recent | `BaseAddresses.fork` 12 of 12; `BaseStocks.fork` 2 of 2, Coinbase's stock tokens run on Base's node through `eth_simulateV1` |
| `forge test --root keeper`, with its fork suite | 86 passing |
| `node --test keeper/test/unit/*.test.mjs`, and the request filler's harness | 252 passing, and 17 |
| The keeper's end-to-end test, on a mainnet fork at block 26,441,062 | 42 of 42 checks, on the commit before the keeper fixes of `e34e921`; not run since |
| The restock's end-to-end test | Base and Avalanche 29 of 29 each; Optimism 17 of 29, OP's pools there too thin to buy |

It is a candidate, not the freeze. What can still change `src/` before the freeze:

1. **RW-3**, the owner's to decide (section 9): a fill under a quote that restarts the whole interval. Every rule
   weighed so far changes the rebalance's state machine.
2. **RB-5**, one line in `IndexZap._checkIndexCall`: the zap refused as `to` only the index it mints or burns, where
   the builder refuses every factory index. Fixed on 2026-11-23: the zap refuses every factory index too, and its
   release hash moved.
3. Any fix this audit asks for.

The frozen commit is the one `DeployWeighted`'s four release hashes (`FACTORY_INITCODE_HASH`, `ZAP_INITCODE_HASH`,
`BUILDER_INITCODE_HASH`, `REQUESTS_INITCODE_HASH`) are fixed at. On chains 1, 56 and 8453 the script deploys no other build
(`BuildNotReleased`, CF-5), and `test_CF5_theReleaseHashesAreThisBuilds` fails on any change to `src/`, a dependency
or the compiler settings until the four are set again. Findings against the candidate carry over: we re-read each
against the frozen commit.

## 2. Scope

### Primary: the contracts that hold or move users' funds

nSLOC counts non-blank lines outside comments.

| File | nSLOC | Holds or moves |
|---|---:|---|
| `src/WeightedHub.sol` | 636 | Each index: an ERC-20 clone that holds its components in kind; issue, redeem, `redeemSkipping`, claims whole or in part, fees in shares, the streaming fee's unit scale, the rebalance's notice and auction, the settlement at the units its executor names, the optional quote |
| `src/WeightedIndexFactory.sol` | 365 | Listings behind a timelock, the wallets approved to create, index creation by CREATE2 clone, the guardian's timelocked change, the fee policy, the creator role, gates and allowlists |
| `src/WeightedMath.sol` | 117 | The rebalance's arithmetic, stateless, called by STATICCALL: the unit caps, the gain `Σ w · L(x)`, the bar, the amounts, the quote's check |
| `src/IndexZap.sol` | 173 | Stateless: mints from and burns to USDC or USDT, and nothing else, through Uniswap's Universal Router; permits |
| `src/UniversalRouterSwaps.sol` | 187 | The swap engine the zap and the builder share: every router command built in-house, pre-funding and `SWEEP` |
| `src/BasketBuilder.sol` | 218 | Stateful: per-user escrows for baskets too wide for one transaction (buy over several calls, then issue; redeem, then sell) |
| `src/MintRequests.sol` | 183 | Escrowed limit orders (stablecoin for shares, shares for stablecoin) that anyone fills before a deadline |
| `src/libraries/*.sol` | 52 | Path packing, V4 types, command bytes |
| `src/interfaces/*.sol` | 531 | Declarations, all our own |

1,931 nSLOC of implementation, 2,462 with the interfaces. Solidity 0.8.28, EVM `cancun`, optimizer on at 100 runs,
no via-IR. Dependencies, pinned as submodules and in `foundry.lock`: OpenZeppelin Contracts v5.7.0 (`cab19933c3`:
`Ownable2Step`, `Clones`, `SafeERC20`, `ReentrancyGuard`, `Math`, `SafeCast`, `Address`) and OpenZeppelin Contracts
Upgradeable v5.7.0 (`14f52c54d3`: `Initializable`, `ERC20Upgradeable`, `ERC20PermitUpgradeable`). No proxy is
upgradeable: indexes are minimal clones of one implementation. No contract reads a price, a feed, a pool's price or
an oracle, and none is payable.

Deployed sizes: `WeightedHub` 21,627 bytes (2,949 under EIP-170), `BasketBuilder` 16,809, `IndexZap` 14,690,
`WeightedIndexFactory` 12,197 (its initcode, which carries the hub's and the math's, 38,498 of EIP-3860's 49,152),
`MintRequests` 5,889, `WeightedMath` 3,606.

### Secondary: what makes a deployment correct

| File | Why |
|---|---|
| `script/DeployWeighted.s.sol`, `script/DeployChecks.sol` | Refuse a weak owner (a Safe below 3 signatures, with a module, an EIP-7702 account), a guardian that is not a Safe of at least 2 signatures (CA-M4), overlapping roles, a market contract as a role, any market address but the chain's own book on chains 1, 56 and 8453, and any build but the released one |
| `script/MainnetAddresses.sol`, `script/BnbChainAddresses.sol`, `script/BaseAddresses.sol`, `script/Listings.sol` | The three address books and the lists: 414 on Ethereum, 364 on BNB Chain, thirty-two on Base. `test_CRL08_theListsAreTheReleaseRecord`, `test_CRL08_theBnbListIsTheReleaseRecord` and `test_CRL08_theBaseListIsTheReleaseRecord` pin them against tables written independently |
| `script/ConfigureWeighted.s.sol` | Proposes and executes the listings through the owner's Safe |

### Optional: the keeper's executor

`keeper/src/KeeperExecutor.sol` (555 nSLOC) is the executor the reference keeper uses. It holds no protocol role and
only its operator's funds: a USDC float, a stock of coins without a Uniswap route, and a stock of index shares. An
attacker who breaks it takes the operator's money, not holders'. Its bounds are the allowances its owner sets (stock
per coin and per index, the float a request fill may spend, restock per coin), and the audit of 2026-11-21 found the
one place a stated bound did not hold (`CA-H1`, fixed). It is worth a read if time allows: `fill`, `fillMint`,
`fillRedeem`, `fillBatch` and `redeemBridged`.

### Out of scope

The keeper bot, restock service and invariant checker (`keeper/*.mjs`, Node), `script/CheckToken.s.sol` (a read-only
report), `script/PythIds.sol` (the keeper's catalogue, which no contract reads), `script/testnet/`, tests and mocks,
and the web app (its own repository).

## 3. Build and run

```bash
git clone --recurse-submodules <repo> && cd <repo> && git checkout e2508f7
forge build --sizes --deny warnings
forge test                           # 566 tests without an RPC; the fork suites skip
MAINNET_RPC_URL=<archive RPC> forge test --match-path 'test/fork/*'   # Ethereum's five fork suites
BNB_RPC_URL=<archive RPC> forge test --match-path 'test/fork/BnbChainAddresses.fork.t.sol'
BASE_RPC_URL=<archive RPC> forge test --match-path 'test/fork/BaseAddresses.fork.t.sol'
BASE_RPC_URL=<RPC serving eth_simulateV1> forge test --match-path 'test/fork/BaseStocks.fork.t.sol'
forge coverage                       # 100% on every file
python3 -I test/mutants/run.py       # the mutation gate
python3 -I test/vectors/proofs.py    # the proof's chain behind the arithmetic, in exact rationals
forge test --root keeper             # the executor's suite
node --test keeper/test/unit/*.test.mjs
```

Foundry v1.8.1 is the version CI pins. `WeightedHub.fork.t.sol` is slow on a cold archive RPC, nearly all of it
admission quotes; a public endpoint prunes the state before it ends. `docs/development.md` has the rest.

## 4. The system in one page

A wallet the factory's owner approved calls `createIndex` with two to two hundred listed coins, each with its units per
share and its weight, fixed for the index's life, plus its fee rates and rebalance interval (7 to 91 days). The
factory clones the hub at a CREATE2 address whose salt commits to all of it. Three deployments share nothing:
Ethereum, BNB Chain and Base, each under its own Safes, each holding its own chain's tokens in kind.

- **Issue** takes each component's backing for the shares (rounded up) and mints them; **redeem** burns shares and
  pays each component's backing (rounded down). Neither reads a price. `redeemSkipping` leaves named components in
  the index as claims booked to the recipient, so a frozen token cannot trap the rest; a claim is collected whole or
  in part.
- **Fees** are shares, never components: a mint and a burn fee to the creator, the platform and a referrer, and a
  yearly streaming fee charged by lowering a unit scale every share's units carry.
- **Rebalancing** brings the index back toward its weights without a price. Once the interval has passed anyone
  starts one; after a 2-hour notice a 4-hour auction runs. An executor names every component's new units
  (`executeRebalance(newUnits, data)`). The index accepts them when each leg stays inside its unit caps (at least
  four fifths of its own units, at most twice) and `⌊Σ w_i · L(x_i) / 10,000⌋` is at or above the auction's bar,
  which starts at a half and halves every twelve minutes. `x_i` is the leg's relative change in units and
  `L(x) = x − x²/2 + x³/3 − 3x⁴/10`, which is at most `ln(1 + x)` on the capped range, so an accepted fill never
  lowers the weighted product of the units. The index then calls the executor back with what it sends out and what
  it must receive, and checks the backing invariant after.
- **A quote** is the one place a price enters a contract: the owner or guardian may post prices of their own with a
  start, and a fill of that proposal must then also bring in, at those prices, at least `1 − tolerance` of what it
  takes out. It can only refuse a fill the bar would accept.
- The **zap**, the **basket builder** and **`MintRequests`** sit outside the hub and use only issue and redeem. The
  zap and the builder take and pay the deployment's USDC and USDT alone.

`ARCHITECTURE.md`, `design/2026-11-10-oracle-free-rebalance.md` (the rebalance's spec and its proof) and
`design/2026-10-29-rebalance-state-machine.md` (eight states, every transition) say more.

## 5. Roles and trust

| Party | Can | Cannot |
|---|---|---|
| Owner (a Safe of at least 3 signatures, 3-of-5 by design) | Propose listings (2-day delay) and guardian changes (7 days); delist; approve the wallets that create indexes; set the fee policy for later indexes; cancel a rebalance; start one early, with a keep mask or with a quote; transfer ownership in two steps | Touch any index's funds, units, weights or rates; pause; upgrade; sweep |
| Guardian (a Safe of at least 2 signatures, holding the role itself) | Cancel a rebalance or a pending listing; delist; start a rebalance early, with a keep mask or with a quote; cancel a guardian change that would remove the role | Move funds; block its own replacement |
| Approved creator | Create an index of listed coins, naming its units, weights, rates and interval within the caps | Anything on an index that exists; an approval is read at creation alone |
| Creator of an index | Gate minting to an allowlist and open it for good; hand the role on in two steps; earn its fees | Change components, weights, rates, or anyone's shares |
| Executor (anyone) | Fill an auction at units of its own naming that clear the caps, the bar and any quote, and choose the block | Take beyond what the bar allows: the index's distance from its weights at the market's prices |
| Wormhole's guardians (13 of 19) | Mint a wrapped copy's token or upgrade its bridge: the whole value of that leg (3 of Ethereum's 414 listings: SOL, AVAX, AERO) | Reach any other leg |
| Coinbase | Mint, pause and block an address on each of its sixteen tokens on Base, upgrade the five coins it issues there (one account each), move a stock token's balance a policy does not exempt, and set each stock's multiplier, which values the leg | Reach any other leg |
| Base's bridge, and the keys that upgrade Base | Mint a copy, burn it out of any holder's balance, or upgrade either half of the bridge: the whole value of that leg (13 of Base's 32 listings, and cbETH) | Reach any other leg, or anything on Ethereum or BNB Chain |
| Ondo | Block and burn a holder's tokens (its compliance contract and burner role), pause them (its pause manager, RX-55), upgrade every one of a chain's tokens through that chain's beacon, and change the shares a token tracks (`sValue`, CF-3): the whole value of those legs (352 of Ethereum's 414 listings, 352 of BNB Chain's 364) | Reach any other leg |
| Other token issuers | Pause, blacklist, and for some burn a holder's balance (WBTC, Tether Gold, every Binance-Peg coin on BNB Chain and others, labelled in the app) | Reach other legs: `redeemSkipping` leaves the frozen one behind |

There is no keeper or bot role, no pause, no upgrade, no sweep and no renounce. `CLAUDE.md` ("No admin power over
funds, no rebalancing key") and `docs/design.md`'s Governance row record why each power is where it is.

## 6. Properties we expect to hold

Each has tests named in `CLAUDE.md`; we want each tried.

1. **Backing.** For every component `i`:
   `balanceOf(index) >= floor(totalSupply · units_i · scale / 1e36) + totalClaims[i]`, after every call, every
   interleaving, and every rounding (issue up, redeem down, a leaving leg's amount down, an arriving leg's up). The
   one way under it is an issuer destroying the index's balance; issue then refuses that index (RX-8).
2. **Holders can always leave.** `redeem` and `redeemSkipping` work in every rebalance state, with any subset of
   components frozen, and claims are payable once transfers resume. No speed limit, no cap on a burn.
3. **Nothing reads a price.** No contract calls a feed, a pool's price or an oracle, by any name
   (`test_V5I4_noContractNamesPyth`, `test_A713_noContractReadsAPrice`), and no entry point of the hub is payable
   (`test_noRebalanceEntryPointTakesEther`).
4. **An accepted fill never lowers the weighted product of the units.** `L(x) ≤ ln(1 + x)` on `[−0.2, 1]`, every
   rounding goes against the executor, and the caps count units, never value. So at any prices the index is worth at
   least `e^(bar − D)` times what it was, `D` its distance from its weights at those prices, and on its weights
   nothing can be taken (the spec's section 3 and Theorem 2).
5. **A quote can only refuse.** No quote accepts a fill the bar refuses, replaces the bar, outlives its proposal, or
   reaches an issue, a redeem or a claim.
6. **Executors are untrusted.** Tokens and the callback go only to `msg.sender`; every mutating entry point shares
   the reentrancy guard; state is written before any rebalance transfer.
7. **No power over funds.** No role can move a component except through issue, redeem, claims and settlements, and
   the approval to create gates creation alone.
8. **The zap and the builder take nothing.** Every amount is measured as a balance change inside the call, at one
   address; a caller's calldata never reaches the router; a leg's limit binds, the pass-through leg's included; no
   currency but the two stablecoins is taken or paid.
9. **`MintRequests` holds exactly its open escrows** (plus donations), `totalEscrow` is exactly their sum, under any
   interleaving with USDT's fee switch; a request fills only at the basket it was made on; nothing is taken into a
   token the contract holds less of than it owes. The builder's escrows hold the same.
10. **The salt commits to every term**, so no two configurations share an address and no relisting reaches an
    existing index.
11. **The scale only shrinks**, no settlement folds it into the units, and every accrual restarts the clock.
12. **The rebalance is in exactly one of eight states**, and every action from each does what the matrix says
    (`design/2026-10-29-rebalance-state-machine.md`).

## 7. Where we want the most attention

In order:

1. **The gain's arithmetic** (`WeightedMath`): that `L` never exceeds the logarithm on the capped range (the margin
   at `x = −0.2` is three millionths), each rounding's direction, the caps at their edges, the bar's schedule and its
   rounding, units at the `uint96` edge, and `quoteCheck`. An exact model written from the spec generates 431
   settlement vectors and 77 quote vectors that the contract replays word for word, and `test/vectors/proofs.py`
   checks the proof's chain in exact rationals. Nothing has proven the contract itself: a Halmos harness exists
   (`test/WeightedMath.halmos.t.sol`) and no run of it is part of the gates; Certora was not run.
2. **What a fill can take.** The claim is Theorem 2: at most the index's distance from its weights. We want it
   attacked: a sequence of fills across intervals, a fill against a pending issue or redeem, a fill behind a keep
   mask, a holder of the whole supply (a known limitation above one share, closed below it, RW-1), and an index
   created off its weights (why creation is gated).
3. **The settlement in the hub**: `_backing` as the one place shares and units become an amount, the post-check with
   the whole of `amountsIn` on top of what the index held, the executor's callback, the probes that a leg a fill
   grows or an issue pulls can leave again (RX-12, RW-8), the partial claim (CA-S01), and what holders are owed after
   an issuer's burn (first come, first served, CA-M3).
4. **Fees and the scale**: the mint and burn fee shares, recipient replacement (a recipient that cannot hold shares
   is swapped so none can block a mint or an exit), the referrer under a gate (AU-1), the streaming accrual's clock
   (XS-1), the scale never folded into units (XS-2), and the creator's handover (RW-6).
5. **The rebalance's clock and roles**: the eight states, the keep mask's one-week restart (XS-3), the cancel bound
   to a proposal (CA-S02), and RW-3.
6. **The zap and the swap engine**: command construction, balance measurement, the sweep, a router's stray against a
   hop's unsold input (RW-9), a balance two addresses write (RW-10), V4 routes that revisit `tokenIn`, the
   two-stablecoin lock, permits.
7. **The two escrows**: `BasketBuilder` across buys, redeems, sells, deposits and withdrawals, and `MintRequests`
   across requests, fills, cancels and refunds; `totalEscrow` and `Underbacked` (CA-H2); the request bound to a
   nonce (CA-M1) and the fill bound to a request's hash (RW-7).
8. **Factory lifecycle**: listing proposals and their windows, delisting, the guardian change, the approval to
   create, clone initialization (only initialized clones issue, redeem or rebalance), CREATE2 salt collisions.
9. **The tokens the lists hold**: Ondo's beacon proxies, whose transfers pass a compliance check and can be paused,
   USDT's fee switch, tokens that refuse or charge a transfer to oneself, and a ledger two addresses write.
10. **Gas at `MAX_COMPONENTS`, 200** (100 until 2026-11-21), under EIP-7825's 2^24 cap, on mock tokens
    (`test_theMostComponentsFitOneTransaction`): `createIndex` about 13.3M, which grows with the square of the
    count and bounds it, `redeemSkipping` with every component skipped 10.2M, `issue` 8.9M, a fill under a quote
    8.8M, `redeem` 7.5M, a start with a quote 2.7M. We want the margin tried: a token that transfers dearer, a
    repricing of gas (EIP-8037's state gas, live on Sepolia), and whether any holder of a 200-coin index can be left
    without an exit that fits a transaction.

## 8. Accepted risks and known limitations

`docs/known-limitations.md` is the list, each entry with its bound. In short:

- A fair rebalance price needs an executor bidding. A lone one keeps the index's distance from its weights, out of
  the holders' value: 0.3 to 0.6% in an ordinary week, 5.0% in one fill after one coin of two doubled.
- An approved creator can still create an index off its weights and drain up to a fifth of it per fill; the app
  shows every index's coins against its weights.
- An index holds up to 200 coins because one transaction carries no more: creation uses four fifths of the gas cap
  at that count. A wide index is never minted through the zap, and its fill fits a transaction only for an executor
  that already holds the coins or moves some legs only.
- Whoever holds an index's whole supply, a share or more, can walk its units.
- The guardian can stall rebalancing with cancels until it is replaced, and for up to 91 days beyond with a sliver
  filled under a quote (RW-3).
- Fixed weights keep buying a collapsing coin until the guardian keeps it.
- An issuer's corporate action is not accounted for (CF-3), and after an issuer's burn redeems and claims are paid
  first come, first served (CA-M3).
- Wrapped legs rest on their bridge or issuer: Wormhole for its copies, Ondo for every stock and ETF. An Ondo token
  tracks a number of shares its balance does not show (`sValue`), so the keeper values only the 9 Pyth prices
  directly and leaves the other 343 alone (RX-2).
- Small indexes rarely rebalance; an exit sent during an auction can be overtaken by the fill (RT-02); a request's
  surplus goes to the fastest filler; a minter can name itself referrer (RY-3, RW-4); a holder can top an index up
  through a fill (RW-5).
- The basket builder is one custody point; airdrops to an index are stranded; hooked V4 pools cannot be routed; zap
  gas grows with components and nothing on chain bounds it.

## 9. Earlier reviews

Every review of this code line since 2026-10-05, all internal. Each record has a status table naming the regression
test of every testable finding; `CLAUDE.md`'s definition of done lists the id families. Records before v5 (v1 to v4
and Stage B) are in `audit/` too; seven retirement records say which ids went with the mechanism they tested.

| Record | Ids | Scope | Findings | Open |
|---|---|---|---:|---|
| `2026-10-05-v5-review.md` | `V5-…` | The weighted hub and factory | 9 | none |
| `2026-10-07-v5-logic-review.md` | `V5R-…` | The settlement's logic | 3 | none |
| `2026-10-13-security-audit.md` | `CF-1`..`CF-8` | Whole repository | 8 | none; CF-3 is a known limitation |
| `2026-10-16-security-audit.md` | `XS-1`..`XS-18` | Fees, scale, builder, keeper | 18 | none |
| `2026-10-18-red-team.md` | `RX-1`..`RX-67` | Whole system, adversarial | 67 | none |
| `2026-10-25-restock-review.md` | `RS-…` | The restock service and executor | 15 | none |
| `2026-10-25-skills-audit-port.md` | `A7-…`, `A1a-…` | Eight findings of an earlier audit still open then | 8 | none |
| `2026-10-28-rebalance-review.md` | `RB-1`..`RB-5` | Rebalancing | 5 | RB-5 (section 1) |
| `2026-10-31-review.md` | `AU-1`..`AU-3` | Whole system | 3 | none |
| `2026-10-31-red-team.md` | `RY-1`..`RY-9` | Whole system, adversarial | 9 | RY-3 (waits on the fee policy) |
| `2026-10-31-red-team-ii.md` | `RZ-1`..`RZ-33` | Whole system, adversarial | 33 | keeper bookkeeping, below |
| `2026-11-01-protocol-docs-review.md` | `PD-1`..`PD-14` | Every protocol used, against its own docs | 14 | none |
| `2026-11-14-red-team.md` | `RW-1`..`RW-10` | `src/` alone: the oracle-free mechanism, by reviewers who did not design it | 10 | RW-3 (the owner's); RW-4 is RY-3 |
| `2026-11-21-consolidated-audit.md` | `CA-…` | Whole repository at `5b7635f`, three passes and a follow-up | 61 | 21 left as they are, each with its reason |

`audit/2026-11-10-oracle-retirement.md` records the ids that went with Pyth (V5-L1, V5-M1, V5R-1, DA-01, RB-3, RX-3,
RX-18, RX-27, AU-2, RZ-26), and `audit/2026-11-18-zap-ether-retirement.md` what went with the zap's ether entry.

Still open:

- **RW-3** (low, governance): a start with a quote that refuses every trade worth making still passes a fill that
  shrinks no leg, and that sliver restarts the index's whole interval, up to 91 days, for the owner and guardian as
  for anyone. No funds move and holders redeem throughout. Three rules were weighed and none taken: a quoted fill
  restarting one week for everyone would open every honestly quoted index to an unquoted auction a week later; the
  owner and guardian starting a week after such a fill is a power neither has today, close to what a keep mask
  already gives; a least gain before a fill restarts the interval is a tuning constant. The owner's to decide.
- **RB-5** (informational): section 1; fixed on 2026-11-23.
- **RY-3, RW-4** (informational, policy): a minter may name itself as referrer and take the referral share of the
  platform's fee. Deferred to the fee policy; a check on chain is dodged by a second wallet.
- **Of the audit of 2026-11-21**, left as they are with their reasons in its record: CA-M11, CA-M15, CA-M19,
  CA-R2-01, CA-R2-06, CA-R2-08. CA-M14, CA-L7, CA-R2-12 and CA-R2-13, left for the restock's non-EVM signers, are fixed since 2026-11-24.
  All are in the keeper, the restock or the scripts.
- **RZ-8, RZ-10, RZ-11, RZ-20, RZ-21**: keeper and restock, informational (out of scope), fixed on 2026-11-23. RZ-6,
  RZ-9, RZ-13, RZ-15, RZ-16 and RZ-19 were fixed on 2026-11-21.
- **XA-34**: one fork test kept a bare `vm.expectRevert()`; fixed on 2026-11-24.

## 10. Assurance already done

- **Tests.** 566 unit, fuzz and invariant tests without an RPC, and the fork suites on all three chains' real
  tokens, Universal Router and pools (section 1's table). Coverage 100% of lines, statements, branches and functions
  on every file, mocks and scripts included. Invariant suites for the hub (the backing invariant under random issue,
  redeem, fees, claims, rebalances and freezes) and for `MintRequests`.
- **The state machine.** `test/WeightedHub.states.t.sol` takes every cell of the transition matrix.
- **The exact model.** `test/vectors/settlement.py` (written from the spec, standard library only) generates 431
  settlement vectors and 77 quote vectors that `test/WeightedMath.vectors.t.sol` replays against the contract word
  for word; `test/vectors/proofs.py` checks the proof's chain on the model in exact rationals.
- **Mutation gate.** 232 mutants as exact edits (`test/mutants/mutants.json`), every one killed, in CI.
- **Static analysis.** `forge lint` with notes denied, Wake (`wake detect all src`) and Aderyn report nothing on
  `src/`; each suppression carries its reason where it stands.
- **End to end.** The keeper as its own process on an anvil fork of Ethereum, its prices confirmed by Pyth's real
  contract against updates signed by keys the test installs: 42 checks passed on 2026-11-21, before the keeper's
  fixes of that day and the xStocks' removal (not run since), among them auctions started and filled on the bar, a
  fill mined a slot late, a guardian's keep mask, and
  two requests filled in one batch against real pools.
- **Deployment rehearsal.** `main` at `5b7635f` has run on Sepolia since 2026-11-18. This candidate has not been
  deployed anywhere.

What has not been done: an external audit; a formal proof of the hub or of `WeightedMath` itself; a deployment of
this candidate on a testnet; a mainnet deployment; the keeper on BNB Chain and on Base; a reading of who mints
Base's USDT and can replace its code; the web app's move to this candidate; a keeper that reads Ondo's `sValue`, so
the 343 Ondo legs Pyth prices by the share can be valued.
