# External audit package

The brief for the external auditors: what to audit, at which commit, how to build it, what the system promises, who
is trusted with what, where we want the most attention, and what every earlier review found. It replaces
`audits/archive/audit-package-oracle-free.md`, which described the oracle-free candidate (`e2508f7`,
packaged at `7a1d9c2`) and is kept as written. It points to the repository's own records rather than repeating them;
`CLAUDE.md` is the full rule book, and every rule there that says "must" or "never" is a property we expect the audit
to try to break.

Every earlier review in this repository is internal, the work of agents and of the team. None is an external audit.

## 1. Commit

The candidate is the branch `feat/pyth-check` at `532fff3`, the commit that adds the sValue check and the
keeper's local DEX to `b747070`. Read it against `7a1d9c2`, whose `src/` is the oracle-free candidate's:
`git diff 7a1d9c2 532fff3 -- src keeper/src script`. The commits between them that change `src/` or `keeper/src/`:

| Commit | What it changed | Record |
|---|---|---|
| `19eb583` | Pyth's check on every fill (`src/PythPrices.sol`, `WeightedMath.oracleCheck`, a feed per token on the factory behind `LISTING_DELAY`); a creation held to its weights at Pyth's prices (`OffWeights`); weights the creator changes behind 7 days; `createAndIssue`, whose first issue the hub makes in its initializer; the owner's or guardian's start a week after any fill (RW-3); the mint pause; `WeightedMath` deployed on its own; RB-5 in the zap; HK-16 in `acceptCreator`. In `keeper/src/`: `KeeperExecutor.fill` posts Pyth's update | `docs/design/pyth-check.md`, `docs/design/changeable-weights.md`, `audits/internal/attack-replay.md` |
| `737689f` | `keeper/src/` only: `KeeperExecutor.depositStock`, the treasury's deposit of an Ondo stock bought through UniswapX | `docs/design/uniswapx-restock.md` |
| `3a6a516` | The swap engine reaches each chain's own DEX beside Uniswap: PancakeSwap's Infinity Universal Router on BNB Chain, Aero's Metarouter on Base (`LocalVenue`, `localRoute`) | `docs/design/chain-venues.md` |
| `b747070` | A fill reads Pyth's prices of the last 15 seconds, a creation's check those of the last 60 (`MAX_PRICE_AGE`, `MAX_CREATION_PRICE_AGE`; HK-25) | `audits/internal/attack-replay-ii.md` |
| `532fff3` | Feed kind `SharesOracle`: an Ondo token valued at its share's Pyth price times the settled sValue of Ondo's `SyntheticSharesOracle` (`SValueUnavailable`), the factory's fifth constructor argument, `src/interfaces/ISyntheticSharesOracle.sol`. In `keeper/src/`: the executor reaches PancakeSwap's SmartRouter and Aero's CL SwapRouter (`LOCAL_ROUTER`, `LOCAL_KIND`, `LOCAL_ROUTE`) | `docs/design/ondo-svalue.md`, `docs/design/keeper-chain-venues.md` |

The other commits in that range (`e1fc80cd`, `bcb3d0f`, `384f5dd`, `914b262`, `e2493ad`) change the lists, the
scripts, the docs and the keeper's bot, and no contract. `src/MintRequests.sol` is unchanged since `7a1d9c2`; its release
hash moves all the same, since its metadata carries the source of the interfaces it imports, whose comments changed.

Solidity 0.8.28, EVM `cancun`, optimizer on at 100 runs, no via-IR (`foundry.toml`). CI pins Foundry v1.8.1 and
eth-wake 4.22.1 (`.github/workflows/test.yml`). The gates, run on the candidate:

| Gate | Result on `532fff3` |
|---|---|
| `forge fmt --check`, `forge build --sizes --deny warnings`, `forge lint -D notes`, for the repository and for `keeper/` | no findings |
| `forge test`, fork suites aside | 663 passing, none failing |
| `forge coverage` | 62 of 62 files at 100% of lines, statements, branches and functions |
| The mutation gate, `python3 -I test/mutants/run.py` | 379 of 379 mutants killed |
| `python3 -I test/vectors/proofs.py` | no failed check |
| Aderyn (`aderyn .`) and `wake detect all src` | no finding, no detection |
| Ethereum's five fork suites, near the head on a public node | `MainnetAddresses.fork` 10 of 10, `Security.fork` 11 of 11, `IndexZap.fork` 11 of 12, `WeightedHub.fork` 4 of 6, `CheckToken.fork` 8 of 10; none skipped. The five failures are not the code's: `testFork_mintWithUSDC`'s $100 sanity floor misses the basket's $86 at the head's prices, and the other four read state a public node no longer serves (HTTP 403). An archive node at the pins settles them. |
| BNB Chain's fork suite, near the head | 23 of 23 |
| Base's two fork suites, near the head | `BaseAddresses.fork` 16 of 17, its Pyth test written against the pin's price batch failing at the head; `BaseStocks.fork` 2 of 2, on Base's node (`eth_simulateV1`) |
| `forge test --root keeper`, with its two fork suites | 97 passing without an RPC; the Ethereum fork suite 3 of 3, the chains' 3 of 3 on BNB Chain and on Base |
| `node --test keeper/test/unit/*.test.mjs`, and the request filler's harness | 263 passing, and 15 |
| The keeper's end-to-end test (`keeper/test/e2e/run.mjs`), on a mainnet fork | not run on the candidate: it needs an archive node; its last run, on `914b262`, passed 45 of 45 |

The release hashes `script/DeployWeighted.s.sol` records for this build:

```
FACTORY_INITCODE_HASH  = 0x9a54a994ddbaddd3d1029aae9093d1b7b15c2de7054219954f6df1eea8ceb134
ZAP_INITCODE_HASH      = 0x60f9c309573c60e3f6eda263ba8d3fe2c2597de837299bb6210295d18ffcbdeb
BUILDER_INITCODE_HASH  = 0x9a8ce967c7c8c8cb1e491ebbef48035d4c1882507feaa2bf12de62abde00f753
MATH_INITCODE_HASH     = 0xb48e9de439b7b1827eef243bb9efc852ba937d59a1ed93bcb82ba1352b66c932
REQUESTS_INITCODE_HASH = 0x7d785e10a45709eb9ac85a6ffe06e18464bd0e5a5467d41ce10790aa8c800ce3
```

They are the build's, not yet the release: the frozen commit is the one they are fixed at after this audit (CF-5). On
chains 1, 56 and 8453 the deploy script broadcasts no other build (`BuildNotReleased`), and
`test_CF5_theReleaseHashesAreThisBuilds` (`test/Scripts.t.sol`) fails on any change to `src/`, a dependency or the
compiler settings, a comment included, until the five are set again. What can still change `src/` before the freeze:

1. Any fix this audit asks for.
2. The next change that needs room in the factory's init code, 447 bytes under EIP-3860
   (`docs/design/ondo-svalue.md`, section 3): it would move `PythPrices` out of the factory, as
   `WeightedMath` is.

Findings against the candidate carry over: we re-read each against the frozen commit.

## 2. Scope

### Primary: the contracts that hold, move or value users' funds

nSLOC counts non-blank lines outside comments.

| File | nSLOC | Holds, moves or decides |
|---|---:|---|
| `src/WeightedHub.sol` | 669 | Each index: an ERC-20 clone that holds its components in kind; issue, redeem, `redeemSkipping`, claims whole or in part, fees in shares, the streaming fee's unit scale, the rebalance's notice and auction, the settlement at the units its executor names, the quote's check and Pyth's (`_checkValues`), the first issue in `initialize` (`FirstIssue`), `setWeights` for the factory alone, the restart rule (`_restartsEarly`) |
| `src/WeightedIndexFactory.sol` | 528 | Listings and price feeds behind a timelock, the wallets approved to create, creation by CREATE2 clone with the check on the weights (`_checkOnWeights`) and the duplicate check in transient storage (`_seen`, `_unsee`), `createAndIssue`, changes of weights (`proposeWeights`, `cancelWeights`, `executeWeights`), the mint pause, the guardian's timelocked change, the fee policy, the creator role, gates and allowlists. It deploys `PythPrices` and the hub's implementation, and takes `WeightedMath` and Ondo's oracle as constructor arguments |
| `src/PythPrices.sol` | 107 | Values a raw unit of a token at Pyth's stored price, leaning against the executor by the confidence, through its feed's kind (`Token`, `Vault`, `Multiplier`, `SharesOracle`), at most 15 seconds old for a fill and 60 for a creation. Views only |
| `src/WeightedMath.sol` | 139 | Stateless, called by STATICCALL: the unit caps, the gain `Σ w · L(x)`, the bar, the amounts, the quote's check and Pyth's (`oracleCheck`, `oracleToleranceAt`) |
| `src/IndexZap.sol` | 173 | Stateless: mints from and burns to USDC or USDT, and nothing else, through the swap engine; permits |
| `src/UniversalRouterSwaps.sol` | 365 | The swap engine the zap and the builder share: Uniswap's Universal Router (V3 and V4) and the chain's own DEX, every command built in-house, pre-funding and a sweep or the Metarouter's closure |
| `src/BasketBuilder.sol` | 218 | Stateful: per-user escrows for baskets too wide for one transaction (buy over several calls, then issue; redeem, then sell) |
| `src/MintRequests.sol` | 183 | Escrowed limit orders (stablecoin for shares, shares for stablecoin) that anyone fills before a deadline. Unchanged since `7a1d9c2` |
| `src/libraries/*.sol` | 62 | Path packing, V4 types, Uniswap's and PancakeSwap's command bytes (`UniversalRouterCommands`), Aero's (`AeroCommands`) |
| `src/interfaces/*.sol` | 710 | Declarations, all our own, those of the parties we call among them: `IPythReader` (Pyth), `ISyntheticSharesOracle` (Ondo), `IAeroMetarouter`, `IAeroCLFactory`, `IAeroPoolFactory` (Aero), `IMultiplierToken` (Coinbase's stock tokens), `IUniversalRouter` |

2,444 nSLOC of implementation, 3,154 with the interfaces. New since `7a1d9c2`: `src/PythPrices.sol`,
`src/libraries/AeroCommands.sol` and seven interfaces (`IPythPrices`, `IPythReader`, `IMultiplierToken`,
`ISyntheticSharesOracle`, `IAeroMetarouter`, `IAeroCLFactory`, `IAeroPoolFactory`). Dependencies, pinned as submodules
and in `foundry.lock`: OpenZeppelin Contracts v5.7.0 (`cab19933c3`: `Ownable2Step`, `Clones`, `SafeERC20`,
`ReentrancyGuard`, `Math`, `SafeCast`, `Address`, `IERC4626`) and OpenZeppelin Contracts Upgradeable v5.7.0
(`14f52c54d3`: `Initializable`, `ERC20Upgradeable`, `ERC20PermitUpgradeable`). No proxy is upgradeable: indexes are
minimal clones of one implementation. One contract reads a price, `PythPrices`, and only a fill and a creation ask it.
No contract of the protocol is payable but the factory's two creation entry points, for the creation fee.

Deployed sizes (`forge build --sizes`): `WeightedHub` 22,872 bytes, `WeightedIndexFactory` 19,096 (its init code, which
carries the hub's and `PythPrices`', 48,705 of EIP-3860's 49,152), `BasketBuilder` 21,018, `IndexZap` 19,042,
`PythPrices` 5,147, `MintRequests` 5,889, `WeightedMath` 3,869.

### Secondary: what makes a deployment correct

| File | Why |
|---|---|
| `script/DeployWeighted.s.sol`, `script/DeployChecks.sol` | Deploy the math, then the factory, the zap, the builder and `MintRequests`. Refuse a weak owner (a Safe below 3 signatures, with a module, an EIP-7702 account), a guardian that is not a Safe of at least 2 (CA-M4), overlapping roles, a market contract as a role, any market address but the chain's own book on chains 1, 56 and 8453, Pyth's contract, Ondo's oracle (`resolveSharesOracle`) and the chain's DEX (`pinnedLocalVenue`) included, and any build but the released one; `checkDeployment` compares each |
| `script/MainnetAddresses.sol`, `script/BnbChainAddresses.sol`, `script/BaseAddresses.sol`, `script/Listings.sol` | The three address books and the lists: 414 on Ethereum (61 coins and Ondo's 353 stocks and ETFs), 366 on BNB Chain (13 coins and the same 353), 32 on Base. `test_CRL08_theListsAreTheReleaseRecord`, `test_CRL08_theBnbListIsTheReleaseRecord` and `test_CRL08_theBaseListIsTheReleaseRecord` pin them against tables written independently |
| `script/PriceFeeds.sol` | Every listed token's Pyth feed and kind, which the owner proposes: on Ethereum 344 `SharesOracle` and 70 `Token`, on BNB Chain 344 and 22, on Base 22 `Token` and 10 `Multiplier`; no listed token is of kind `Vault`. `test/ConfigureWeighted.t.sol` pins each entry |
| `script/ConfigureWeighted.s.sol`, `script/ScriptLists.sol`, `script/ScriptUtils.sol` | Propose and execute the listings and feeds through the owner's Safe |

### Optional: the keeper's executor

`keeper/src/KeeperExecutor.sol` (652 nSLOC) and its interfaces (`IPyth`, `IV3SwapRouter`, `IAeroSwapRouter`,
`ITokenBridge`) are the executor the reference keeper uses. It holds no protocol role and only its operator's funds:
a USDC float, a stock of coins without a route, and a stock of index shares. An attacker who breaks it takes the
operator's money, not holders'. Its bounds are the allowances its owner sets (stock per coin and per index, the float
a request fill may spend, restock per coin), and the consolidated audit found the one place a stated bound did not
hold (`CA-H1`, fixed). Since `7a1d9c2`: `fill` takes one `AuctionFill` and is payable, posting Pyth's update to the
Pyth contract the index's own reader names, for exactly Pyth's fee (`WrongPythFee`, `NoOracle`); `depositStock`, the
treasury's deposit, credited within the restock allowance as a bridged arrival is; and the chain's own DEX
(`LOCAL_ROUTER`, `LOCAL_KIND`, a route behind the byte `LOCAL_ROUTE`), approved for one purchase's bound and set back
to zero after it. Worth a read if time allows: `fill`, `fillMint`, `fillRedeem`, `fillBatch`, `redeemBridged`,
`depositStock`, `bridgeOut` and `_venueOf`.

### Out of scope

The keeper bot, restock service and invariant checker (`keeper/*.mjs`, Node), `script/CheckToken.s.sol` (a read-only
report), `script/PythIds.sol` (the keeper's catalogue, which no contract reads), `script/testnet/`, tests and mocks,
the web app (its own repository), and the third-party contracts the system calls (Pyth's contract, Ondo's oracle,
Uniswap's, PancakeSwap's and Aero's routers and pools, the tokens), except where they meet ours.

## 3. Build and run

In a clone made with `git clone --recurse-submodules`:

```bash
git checkout 532fff3
forge build --sizes --deny warnings
forge lint -D notes
forge test --no-match-path 'test/fork/*'   # unit, fuzz and invariant tests, no RPC
forge coverage                             # 100% on every file is the gate
python3 -I test/mutants/run.py             # the mutation gate
python3 -I test/vectors/proofs.py          # the proof's chain behind the arithmetic, in exact rationals
forge test --root keeper                   # the executor's suite
node --test keeper/test/unit/*.test.mjs    # the keeper bot's unit suites
```

The fork suites run when their variable is set and skip otherwise. With `MAINNET_RPC_URL`, `BNB_RPC_URL` and
`BASE_RPC_URL` set to archive nodes, `forge test --match-path 'test/fork/*'` lists eight suites: Ethereum's five
(`IndexZap.fork`, `WeightedHub.fork`, `CheckToken.fork`, `MainnetAddresses.fork`, `Security.fork`), BNB Chain's
`BnbChainAddresses.fork`, and Base's `BaseAddresses.fork` and `BaseStocks.fork`, the last of which needs a node that
serves `eth_simulateV1`, since Coinbase's stock tokens are precompiles of Base that the pinned Foundry cannot execute.
`WeightedHub.fork.t.sol` is slow on a cold archive node, nearly all of it admission quotes; a public endpoint prunes the
state before it ends. `forge` loads `.env`, so a `MAINNET_RPC_URL` there runs the fork suites with `forge test`.
`docs/development.md` and `CLAUDE.md`'s "Commands" have the rest.

## 4. The system in one page

Three deployments share nothing: Ethereum, BNB Chain and Base, each under its own owner Safe and guardian's Safe, each
holding its own chain's tokens in kind. An index lives on one chain.

- **Creation.** A wallet the factory's owner approved calls `createIndex` with two to two hundred listed coins, each
  with its units per share and its weight, plus its fee rates and rebalance interval (7 to 91 days). On a factory with
  an oracle, which the deploy script requires on every chain it pins, the factory values every leg's units at Pyth's
  prices of the last minute and refuses a leg whose share of the value lies more than 5% from its weight, relative to
  it (`MAX_WEIGHT_DEVIATION`, `OffWeights`). It clones the hub at a CREATE2 address whose salt commits to all of it.
  `createAndIssue` does the same and has the new index issue its first shares inside its initializer, the basket
  pulled from the creator, who approved the predicted address first (`predictIndexAddress`).
- **Issue** takes each component's backing for the shares (rounded up) and mints them; **redeem** burns shares and pays
  each component's backing (rounded down). Neither reads a price. `redeemSkipping` leaves named components in the
  index as claims booked to the recipient, so a frozen token cannot trap the rest; a claim is collected whole or in
  part.
- **Fees** are shares, never components: a mint and a burn fee to the creator, the platform and a referrer, and a
  yearly streaming fee charged by lowering a unit scale every share's units carry.
- **Rebalancing.** Once the interval has passed anyone starts one; after a 2-hour notice a 4-hour auction runs. An
  executor names every component's new units (`executeRebalance(newUnits, data)`). The index accepts them when three
  checks pass, in this order. The units': each leg stays inside its caps (at least four fifths of its own units, at
  most twice) and `⌊Σ w_i · L(x_i) / 10,000⌋` is at or above the bar, which starts at a half and halves every twelve
  minutes, with `L(x) = x − x²/2 + x³/3 − 3x⁴/10` at most `ln(1 + x)` on the capped range. A quote's, when the owner or
  guardian posted one with the start. Pyth's: at Pyth's prices the fill brings in at least what it takes out, less a
  tolerance that rises from nothing at the auction's first second to 2% at its last (`oracleCheck`); a leg whose units
  do not change is not priced. The executor posts Pyth's update itself, so it chooses which price of the last 15
  seconds the fill reads (HK-25). The index then calls the executor back with what it sends out and what it must
  receive, and checks the backing invariant after.
- **Prices.** A token's feed is the owner's to set, behind `LISTING_DELAY` (2 days) and the guardian's cancel, and of
  one of four kinds: `Token` (the feed prices the token), `Vault` (an ERC-4626 token at `convertToAssets`),
  `Multiplier` (the feed prices a share, the token reports `multiplier()` shares: Coinbase's stocks on Base) and
  `SharesOracle` (the feed prices a share, Ondo's `SyntheticSharesOracle` holds the token's sValue, used only once
  settled).
- **Weights.** The creator may propose new weights for the coins the index holds, never a new coin, each at least one
  basis point. Anyone applies them from 7 days after the proposal to 7 days after that; the creator, the owner or the
  guardian cancels one; none applies during a live rebalance. The units follow at the next rebalance, under the three
  checks above.
- **The clock's roles.** A stranger waits out the index's interval after every fill. The owner or guardian may start
  a week after any fill once one has settled, with a keep mask, a quote or neither.
- **The mint pause.** The owner or guardian stops new issues on one index or all (`pauseMinting`); the owner alone
  resumes them. Only an issue reads it.
- The **zap**, the **basket builder** and **`MintRequests`** sit outside the hub and use only issue and redeem. The zap
  and the builder take and pay the deployment's USDC and USDT alone, and swap through Uniswap's Universal Router 2.0.0
  and, on BNB Chain and Base, through the chain's own DEX, each leg naming one venue.

`ARCHITECTURE.md` (its section 3 on Pyth's check), `docs/design/rebalance.md` (the units' rule and
its proof), `docs/design/pyth-check.md` and `docs/design/rebalance-state-machine.md` (eight states, every
transition) say more.

## 5. Roles and trust

| Party | Can | Cannot |
|---|---|---|
| Owner (a Safe of at least 3 signatures, 3-of-5 by design) | Propose listings and price feeds (2 days) and guardian changes (7 days); delist; approve the wallets that create indexes; set the fee policy for later indexes; cancel a rebalance, a pending listing, a pending feed or a pending change of weights; start a rebalance early, with a keep mask or a quote, and a week after any fill; pause and resume minting; transfer ownership in two steps | Touch any index's funds, units, coins or rates; propose an index's weights; pause an exit; upgrade; sweep |
| Guardian (a Safe of at least 2 signatures, holding the role itself) | Cancel a rebalance, a pending listing, a pending feed or a pending change of weights; delist; start a rebalance early, with a keep mask or a quote, and a week after any fill; pause minting; cancel a guardian change that would remove the role | Move funds; resume minting; propose listings, feeds or weights; block its own replacement |
| Approved creator | Create an index of listed coins within 5% of its weights at Pyth's prices, naming units, weights, rates and interval within the caps; buy its first shares in the same call (`createAndIssue`) | Anything on an index that exists; the approval is read at creation alone |
| Creator of an index | Propose new weights for its coins, behind 7 days and cancellable; gate minting and open it for good; hand the role on in two steps, which cancels its pending weights (HK-16); earn its fees | Change components or rates, add a coin, set a weight of zero, or touch anyone's shares |
| Executor (anyone) | Fill an auction at units of its own naming that clear the caps, the bar, any quote and Pyth's check; choose the block and, by posting Pyth's update itself, which price of the last 15 seconds the fill reads | Take beyond the tolerance of what it trades at that price, plus the most a coin moved within those seconds; where a price is wrong, beyond the units' bound: the index's distance from its weights at the market's prices |
| Pyth (its publishers, its signers, and the keys that upgrade its contract on each chain; on Ethereum three of its five keys sign any price and any upgrade, `docs/design/pre-mainnet-readings.md`) | Stop every fill and creation that needs a price, by publishing none or an unusable one; by a wrong price, loosen the check on a leg toward the units' bound, or refuse a fair fill | Reach an issue, a redeem or a claim; pass a fill the units refuse; change state during a read: every read is a view, called by STATICCALL |
| Ondo, as issuer | Block and burn a holder's tokens (its compliance contract and burner role), pause them (its pause manager, RX-55), upgrade every one of a chain's tokens through that chain's beacon, and change the shares a token tracks (`sValue`, CF-3): the whole value of those legs (353 of Ethereum's 414 listings, 353 of BNB Chain's 366) | Reach any other leg |
| Ondo, as the oracle of sValues (its admin adds and removes assets and schedules corporate actions; its setter raises an sValue within the drift, 1% a day on Ethereum and 3% on BNB Chain) | Refuse every fill that moves a `SharesOracle` leg and every creation that holds one; by a wrong sValue, loosen the check on that leg toward the units' bound | Reach an issue, a redeem or a claim, or pass a fill the units refuse |
| Coinbase | Mint, pause and block an address on each of its sixteen tokens on Base, upgrade the five coins it issues there (one account each), move a stock token's balance a policy does not exempt, and set each stock's multiplier, which values the leg and which Pyth's check reads | Reach any other leg |
| Base's bridge, and the keys that upgrade Base | Mint a copy, burn it out of any holder's balance, or upgrade either half of the bridge: the whole value of that leg (13 of Base's 32 listings, and cbETH) | Reach any other leg, or anything on Ethereum or BNB Chain |
| Wormhole's guardians (13 of 19) | Mint a wrapped copy's token or upgrade its bridge: the whole value of that leg (SOL's and AVAX's copies on Ethereum) | Reach any other leg |
| Other token issuers and bridges | Pause, blacklist, and for some burn a holder's balance or mint without a bound: Binance for nine of BNB Chain's thirteen coins, BitGo for WBTC, Tether for Tether Gold, PancakeSwap's MasterChef for CAKE on BNB Chain, the bridges and minters of Ethereum's other tokens of tier `Bridged` (`Listings.tier`; ICP's copy is minted by one key, `script/MainnetAddresses.sol`), each labelled in the app | Reach other legs: `redeemSkipping` leaves the frozen one behind, and a free-minted leg draws at most a bounded share of the rest per fill |
| The chain's DEX operators: PancakeSwap's Safe (3 of 7) and its V3 factory's owner on BNB Chain; Aero's Safe (3) on Base | Pause PancakeSwap's Infinity Universal Router; set the farm contracts PancakeSwap's V3 pools call on every swap; set Aero's fee and MEV-tax modules and pause its basic pools: make that venue's legs revert or cost more, within the caller's limits | Take a leg's pre-fund, which the router returns in the same call, or reach an index |
| Circle and Tether | Freeze or pause USDC and USDT, and Tether destroy a blacklisted balance, `MintRequests`' and the builder's included (`docs/known-limitations.md`) | Reach a component of an index |
| The keeper's keys (its hot key, the restock's treasury key, the executor's owner) | Spend the operator's float and stock within the allowances the executor's owner sets | Anything in the protocol: there is no keeper or bot role |

There is no keeper or bot role, no pause of an exit, no upgrade, no sweep and no renounce. `CLAUDE.md` ("No admin
power over funds, no rebalancing key") and `docs/decisions.md`'s Governance row record why each power is where it is.
`audits/internal/attack-replay.md`, section 3 (HK-4), shows what every role's key takes together.

## 6. Properties we expect to hold

Each has tests named in `CLAUDE.md`; we want each tried.

1. **Backing.** For every component `i`:
   `balanceOf(index) >= floor(totalSupply · units_i · scale / 1e36) + totalClaims[i]`, after every call, every
   interleaving, and every rounding (issue up, redeem down, a leaving leg's amount down, an arriving leg's up). The
   one way under it is an issuer destroying the index's balance; issue then refuses that index (RX-8).
2. **Holders can always leave.** `redeem` and `redeemSkipping` work in every rebalance state, with any subset of
   components frozen, with minting paused, and with Pyth and Ondo's oracle answering nothing
   (`test_exitsAndMintsReadNoPrice`, `test_aPauseStopsIssuesAndNoExitNorARebalance`). Claims are payable once
   transfers resume. No speed limit, no cap on a burn.
3. **A price can only refuse.** Only `PythPrices` reads a price, and only a fill and a creation ask it
   (`test_onlyThePriceReaderReadsPyth`, `test_A713_noContractReadsAPrice`); no issue, redeem or claim reads one. A fill
   passes the units' check before Pyth's, and no price, feed, kind, multiplier or sValue passes a fill the units
   refuse (`test_aWrongPriceCannotPassAFillTheUnitsRefuse`). A stale, missing or unusable price, a token with no feed
   (`NoPriceFeed`) and an unsettled sValue (`SValueUnavailable`) stop only the fills that move that leg and the
   creations that hold it.
4. **What a fill can take.** On units, an accepted fill never lowers the weighted product of the units: `L(x) ≤ ln(1 +
   x)` on `[−0.2, 1]`, every rounding goes against the executor, and the caps count units, never value. So at any
   prices the index is worth at least `e^(bar − D)` times what it was, `D` its distance from its weights at those
   prices (the spec's section 3 and Theorem 2). Under Pyth's check it also brings in, at the prices it reads, at least
   what it takes out less the tolerance of the fill's second; each value leans against the executor by Pyth's
   confidence, and the floor rounds up (`_valueFloor`).
5. **A quote can only refuse.** No quote accepts a fill the bar refuses, replaces the bar, outlives its proposal, or
   reaches an issue, a redeem or a claim.
6. **An index starts on its weights.** On a factory with an oracle, `createIndex` and `createAndIssue` refuse a leg
   whose share of the index's value at Pyth's prices lies more than 5% from its weight, relative to it, the arithmetic
   exact in integers and the allowance rounded down (`test_anIndexIsCreatedOnItsWeights`,
   `test_anOndoLegIsCreatedOnItsTrueWeight`). Only approved wallets create.
7. **An Ondo leg is valued only at a settled sValue**: one Ondo's oracle holds, with no corporate action scheduled or
   under way, unchanged for `MIN_SVALUE_AGE`, twenty minutes (`test_onlyASettledSValueValuesAnOndoLeg`); a reader
   with no oracle values no Ondo leg (`test_aReaderWithoutOndosOracleValuesNoOndoLeg`).
8. **The first issue pulls from its creator alone.** It is the one time the hub pulls from an account other than its
   caller: `FirstIssue.from` is the factory's `msg.sender`, only the factory calls `initialize`, once per clone, under
   the reentrancy guard, and the first issue runs every check an issue runs, a failed one reverting the creation
   (`test_theFirstIssuePullsFromItsCreatorAlone`, mutants FB1 to FB7).
9. **Weights change only behind their notice, and coins never.** Only the creator proposes, on a factory with an
   oracle; nothing applies before `WEIGHTS_DELAY` or after `PROPOSAL_WINDOW` past it, or during a live rebalance
   (`RebalancePending`); only the factory writes the hub's weights (`NotFactory`); no weight is zero; a handover
   cancels a pending change (HK-16). Nothing moves at the change.
10. **The clock.** A stranger waits out the index's interval after every fill, or `MIN_REBALANCE_INTERVAL` after a
    fill with a keep mask (XS-3). The owner and guardian wait `MIN_REBALANCE_INTERVAL` after any fill, and nobody
    starts early before an index's first fill (`test_theOwnerOrGuardianRestartsAWeekAfterAnyFill`,
    `test_RW3_aSliverUnderAQuoteHoldsTheRolesOffAWeekNotAQuarter`, `test_theRebalanceIntervalIsTheIndexs`). The
    rebalance is in exactly one of eight states, and every action from each does what the matrix says
    (`docs/design/rebalance-state-machine.md`, `test/WeightedHub.states.t.sol`).
11. **The pause stops issues alone.** No redeem, `redeemSkipping`, claim, transfer, accrual or rebalance reads it.
12. **Executors are untrusted.** Tokens and the callback go only to `msg.sender`; every mutating entry point shares
    the reentrancy guard; state is written before any rebalance transfer.
13. **No power over funds.** No role moves a component except through issue, redeem, claims and settlements. The
    approval to create gates creation alone. A feed reaches every index that holds its token from its execution, and
    like any price can only refuse a fill or loosen its check toward the units' bound.
14. **The zap and the builder take nothing, on every venue.** Every amount is measured as a balance change inside the
    call, at one address; a caller's calldata never reaches a router; no router ever holds an approval from either
    (`test_HK21_noRouterEverHoldsAnApproval`); a route names tokens, never pools, so no caller points the engine at a
    pool the DEX did not make (`test_HK22_aRouteCannotNameAPoolTheDexDidNotMake`); a leg's limit binds, the
    pass-through leg's included; no currency but the two stablecoins is taken or paid; no router of either venue is a
    valid recipient.
15. **`MintRequests` holds exactly its open escrows** (plus donations), `totalEscrow` is exactly their sum, under any
    interleaving with USDT's fee switch; a request fills only at the basket it was made on; nothing is taken into a
    token the contract holds less of than it owes. The builder's escrows hold the same.
16. **The salt commits to every term at creation**, the weights included, so no two configurations share an address
    and no relisting reaches an existing index's terms. After a change of weights the address still names the
    creation's.
17. **The scale only shrinks**, no settlement folds it into the units, and every accrual restarts the clock.
18. **The hub takes no ether** (`test_noRebalanceEntryPointTakesEther`); a creation's fee, the only ether in the
    protocol, is checked against the call's value and forwarded whole (HK-14).

## 7. Where we want the most attention

In order:

1. **Pyth's check** (`src/PythPrices.sol`, `WeightedMath.oracleCheck` and `oracleToleranceAt`, the hub's
   `_checkValues`). No reviewer outside the team has read it. Its reviews so far are its author's (the read as an
   attacker and the two attack replays, HK-1 to HK-26), and a reviewer agent that had not seen the author's
   reasoning read the work that builds on it (`CHANGELOG.md`). We want tried:
   - `_valueAt`: the exponent's bounds (`SCALE_DIGITS`, `MAX_DIGITS`), a price at or under its confidence, the
     confidence's direction for a leg that leaves and one that arrives, the rounding, the refusal of a value of zero or
     above `MAX_VALUE`, and whether any price Pyth can store reaches `oracleCheck` with sums that overflow;
   - which entry uses which age: `legValues` and `valueOf` 15 seconds, `valuesWith` (creation) 60;
   - the filler's choice of price within those 15 seconds (HK-25), a newer update posted by someone else ahead of a
     fill, and a fill too wide to carry its own update (two hundred legs post it in a transaction of their own) on
     Ethereum's 12-second blocks;
   - feeds: the owner's per token, executable by anyone in the window, reaching every existing index that holds the
     token; a feed of the wrong kind for its token; and `decimalsOf`, which the reader reads for every fill, while a
     relisting rewrites it;
   - the `Vault` kind, which no listed token uses, and the `Multiplier` kind, which meets real Coinbase stock tokens
     only in `test/fork/BaseStocks.fork.t.sol`, on Base's node;
   - the interplay with a quote and a keep mask, both of which may apply to the same fill.
2. **The `SharesOracle` kind** (`PythPrices._settledSValue`, `src/interfaces/ISyntheticSharesOracle.sol`): the field
   order the getter is declared in, the three conditions, the reliance on Ondo writing `lastUpdate` at every change of
   an sValue (as the interface reads Ondo's source), what an asset Ondo removes or re-adds does, and a split's sValue
   landing at a moment Pyth's share price does not match.
3. **Creation**: `_checkOnWeights` (the exact arithmetic, a value up to 2^214 by its own comment, the allowance's
   rounding), the duplicate check in transient storage keyed by each token's address (`_seen`, `_unsee`, the
   contracts' only inline assembly, HK-2), and `createAndIssue`: the pull from `FirstIssue.from` inside `initialize`, an
   approval given to an address before it exists (`predictIndexAddress`), a component that calls back during the
   first issue (mutant FB3), and the creation fee's transfer after it.
4. **Changeable weights** (`proposeWeights`, `cancelWeights`, `executeWeights`, `WeightedHub.setWeights`): a change
   against a proposal started just before or just after it, the window's edges, the handover (HK-16), and what a
   creator who proposes a sharp change and fills its own auction keeps, which the record bounds by the tolerance per
   fill (`docs/design/changeable-weights.md`).
5. **The clock's roles and the pause**: `_restartsEarly` and `_permissionlessAt` against the eight states, a hostile
   guardian's weekly slivers in the window the restart rule opens (`docs/known-limitations.md`, "The guardian can
   stall rebalancing"), and `pauseMinting` reaching an issue and nothing else, `feeTerms` being the one place it is
   read.
6. **The engine's local venues** (`src/UniversalRouterSwaps.sol` since `3a6a516`): `_checkRoute` and
   `_checkLocalRoute` (a family byte, then a path of V3's shape whose three bytes are a fee tier, a tick spacing, or
   zero and one), PancakeSwap's V3 and V2 commands on its Infinity Universal Router (an exact input of zero means
   "already paid" there), Aero's Metarouter with its pools looked up in the three pinned factories (`_aeroPool`,
   `_forwardAeroPools`) and its closure, which returns the whole balance of every token a batch touched, each sale one
   hop at a time, the stray and the unsold input told apart (RW-9), `SharedBalance` (RW-10), and the chain's router
   refused as a recipient. `InvalidLocalVenue` and the deploy checks fix one DEX per deployment.
7. **The gain's arithmetic** (`WeightedMath`): that `L` never exceeds the logarithm on the capped range (the margin at
   `x = −0.2` is three millionths), each rounding's direction, the caps at their edges, the bar's schedule and its
   rounding, units at the `uint96` edge, `quoteCheck` and `oracleCheck`. An exact model written from the spec
   generates 455 settlement vectors, 77 quote vectors and 85 oracle vectors that the contract replays word for word
   (`test/vectors/settlement.json`), and `test/vectors/proofs.py` checks the proof's chain in exact rationals. Nothing
   has proven the contract itself: a Halmos harness exists (`test/WeightedMath.halmos.t.sol`) and no run of it is part
   of the gates; Certora was not run.
8. **What a fill can take.** The claims are Theorem 2 on units, and the tolerance under Pyth's check. We want them
   attacked: a sequence of fills across intervals, a fill against a pending issue or redeem, a fill behind a keep
   mask, a holder of the whole supply (a known limitation above one share, closed below it, RW-1), and every role's
   key together (HK-4: a fifth of a leg a week, after a week's notice, with the guardian silent).
9. **The settlement in the hub**: `_backing` as the one place shares and units become an amount, the post-check with
   the whole of `amountsIn` on top of what the index held, the executor's callback, the probes that a leg a fill grows
   or an issue pulls can leave again (RX-12, RW-8), the partial claim (CA-S01), and what holders are owed after an
   issuer's burn (first come, first served, CA-M3).
10. **Fees and the scale**: the mint and burn fee shares, recipient replacement (a recipient that cannot hold shares
    is swapped so none can block a mint or an exit), the referrer under a gate (AU-1), the streaming accrual's clock
    (XS-1, HK-24), the scale never folded into units (XS-2), and the creator's handover (RW-6).
11. **The zap on Uniswap, the escrows and the factory's lifecycle**: command construction, the sweep, V4 routes that
    revisit `tokenIn`, permits; `BasketBuilder` and `MintRequests` across every call, `totalEscrow` and `Underbacked`
    (CA-H2), the nonce a request binds (CA-M1) and the hash a fill binds (RW-7); listing and feed proposals and their
    windows, delisting, the guardian change, the approval to create, clone initialization, CREATE2 salt collisions.
12. **The tokens the lists hold**: Ondo's beacon proxies, whose transfers pass a compliance check and can be paused,
    USDT's fee switch, tokens that refuse or charge a transfer to oneself, a ledger two addresses write, and CAKE on
    BNB Chain, whose supply PancakeSwap's MasterChef mints.
13. **Gas at `MAX_COMPONENTS`, 200**, under EIP-7825's 2^24 cap, as `CLAUDE.md` records it on mock tokens
    (`test_theMostComponentsFitOneTransaction`, `test_theMostComponentsFillUnderPythsCheckInOneTransaction`,
    `test_aCreationWithItsFirstIssueFitsOneTransaction`): `createIndex` 13.9M under Pyth's check, about 60k under five
    sixths of the cap, and 10.2M without it; a fill under the check 12.7M; `redeemSkipping` with every component
    skipped 10.2M, `issue` 8.9M, `redeem` 7.5M; `createAndIssue` about 110,000 gas a component, 13.4M at 125 and past
    the cap at 200. The creation's measurement uses feeds of kind `Token`; a `SharesOracle` leg adds a read of Ondo's
    oracle per leg, which it does not include. We want the margin tried: a token that transfers dearer, a repricing of
    gas (EIP-8037's state gas, live on Sepolia), and whether any holder of a 200-coin index can be left without an
    exit that fits a transaction.

## 8. Accepted risks and known limitations

`docs/known-limitations.md` is the list, each entry with its bound. In short:

- **A lone executor keeps a margin.** Under Pyth's check it keeps at most the tolerance of what it trades, up to 2% at
  the auction's last second, counted at the price it chose among the last 15 seconds', so the tolerance plus the most
  a coin moved in those seconds (HK-25). Where Pyth is wrong or hostile the units are the bound: the index's distance
  from its weights, 0.3 to 0.6% in an ordinary week and 5.0% in one fill after one coin of two doubled. A fair price
  needs a bidder.
- **Pyth is a pull oracle and a dependency of liveness.** Every fill needs an update of the last 15 seconds and every
  creation one of the last minute, which the keeper buys from Hermes, a paid plan; a newer update posted ahead of a
  fill can revert one named at the edge of the tolerance. While Pyth is stale or missing no fill that moves the
  affected coins lands, and no creation that holds them. Exits are untouched.
- **Ondo's tokens wait on Ondo's oracle.** Ethereum's `SyntheticSharesOracle` holds 10 of the 353 Ondo
  tokens, and near the head the reader valued 8 of the 344 `SharesOracle` legs, so on Ethereum an index holding one of the other 336
  cannot be created and a fill that moves one waits, until Ondo registers it there; on BNB Chain it valued 340 and
  refused 4 (`docs/design/ondo-svalue.md`). Around each corporate action, from its scheduling until twenty
  minutes after its sValue lands, the same wait holds.
- **An approved creator's index, and its weights.** Creation is held to 5% of the weights at Pyth's prices on a
  factory with an oracle; a factory without one (tests, Sepolia) checks nothing, and the deploy script refuses one on
  every chain it pins. A creator who changes the weights opens a distance on purpose: a lone fill keeps the tolerance
  of what it trades, each interval, and holders have the 7 days' notice to leave.
- **Every key together** (the owner's Safe and an index's creator, the guardian silent or replaced) takes up to a
  fifth of a leg a week, after seven days of public notice, every exit open throughout (HK-4). The owner's pending
  listings, feeds and guardian change survive a transfer of ownership (HK-16's record, left as it is).
- **Two hundred coins, and little room left.** An index holds up to 200 coins because one transaction carries no
  more. A wide index is never minted through the zap; `createAndIssue` was measured inside five sixths of the cap at
  125 legs and past the cap at 200, so the widest indexes are created and then issued; and a fill that wide fits a
  transaction only for an executor that already holds the coins. The factory's init code is 447 bytes under
  EIP-3860.
- Whoever holds an index's whole supply, a share or more, can walk its units.
- **The guardian can stall rebalancing** with cancels until it is replaced, and by settling a sliver every week in the
  window the restart rule gives it; a hostile guardian can also pause every mint until the owner replaces it. Neither
  moves funds or stops an exit.
- Fixed weights keep buying a collapsing coin until the guardian keeps it.
- **An issuer's corporate action is not accounted for in the units** (CF-3), and after an issuer's burn redeems and
  claims are paid first come, first served (CA-M3). Ondo can end a stock by a redemption paid only to its KYC'd
  redeemers. A Coinbase stock token is not one share.
- **Wrapped and bridged legs rest on their bridge or issuer**: Wormhole for its copies, Base's bridge for thirteen of
  Base's coins and cbETH, Ondo for every stock and ETF, Binance for every Binance-Peg coin, and the minters of
  Ethereum's other bridged tokens.
- **The chain's DEX adds its operators**, who can make that venue's legs revert or cost more; a leg can always name
  Uniswap instead.
- Small indexes rarely rebalance; an exit sent during an auction can be overtaken by the fill (RT-02); a request's
  surplus goes to the fastest filler; a minter can name itself referrer (RY-3, RW-4); a holder can top an index up
  through a fill (RW-5).
- The basket builder is one custody point; airdrops to an index are stranded; hooked V4 pools cannot be routed; zap
  gas grows with components and nothing on chain bounds it; the zap is pinned to Universal Router 2.0.0; the bytecode
  targets Cancun.

## 9. Earlier reviews

Every review of this code line since v5, all internal. Each record has a status table naming the regression
test of every testable finding; `CLAUDE.md`'s definition of done, item 6, lists every id family and where its tests
are.

| Record | Ids | Scope | Findings | Open |
|---|---|---|---:|---|
| `audits/internal/v5-review.md` | `V5-M1`, `V5-M2`, `V5-L1`..`V5-L3`, `V5-I1`..`V5-I4` | The weighted hub and factory | 9 | none; V5-L1 and V5-M1 retired with the Pyth-priced rebalance, V5-I4 with Pyth's check |
| `audits/internal/v5-logic-review.md` | `V5R-1`, `V5R-I1`, `V5R-I2` | The settlement's logic | 3 | none; V5R-1 retired with the Pyth-priced rebalance, V5R-I1 with Stage B |
| `audits/internal/security-audit-cf.md` | `CF-1`..`CF-8` | Whole repository | 8 | none; CF-3 is a known limitation, CF-2 and CF-8 retired with THORChain |
| `audits/internal/security-audit-xs.md` | `XS-1`..`XS-18` | Fees, scale, builder, keeper | 18 | none |
| `audits/internal/red-team-rx.md` | `RX-1`..`RX-67` | Whole system, adversarial | 67 | none; RX-3, RX-18 and RX-27 retired with the Pyth-priced rebalance |
| `audits/internal/restock-review-rs.md` | `RS-…` | The restock service and executor | 15 | none in code; RS-15's residue, a fee spike above twice the base fee, is the owner's call in the restock |
| `audits/internal/skills-audit-a7.md` | `A7-…`, `A1a-…` | The eight findings of the skills audit still open then | 8 | none |
| `audits/internal/rebalance-review-rb.md` | `RB-1`..`RB-5` | Rebalancing | 5 | none; RB-5 fixed (`test_RB5_noIndexIsAValidZapRecipient`), RB-3 retired with the Pyth-priced rebalance |
| `audits/internal/review-au.md` | `AU-1`..`AU-3` | Whole system | 3 | none; AU-2 retired with the Pyth-priced rebalance |
| `audits/internal/red-team-ry.md` | `RY-1`..`RY-9` | Whole system, adversarial | 9 | RY-3 (waits on the fee policy) |
| `audits/internal/red-team-rz.md` | `RZ-1`..`RZ-33` | Whole system, adversarial | 33 | none in code; RZ-17, RZ-26 and RZ-27 retired with the Pyth-priced rebalance |
| `audits/internal/protocol-docs-review-pd.md` | `PD-1`..`PD-14` | Every protocol used, against its own docs | 14 | none; ten retired with the non-EVM signers |
| `audits/internal/red-team-rw.md` | `RW-1`..`RW-10` | `src/` alone: the oracle-free mechanism, by reviewers who did not design it | 10 | RW-4, which is RY-3; RW-3 fixed in the hub |
| `audits/internal/consolidated-audit-ca.md` | `CA-…` | Whole repository at `5b7635f`, three passes and a follow-up | 61 | seventeen left as they are, each with its reason (below) |
| `audits/internal/attack-replay.md` | `HK-1`..`HK-20` | Twenty classes of attack, against the build of `19eb583`, by its author | 1 | none; HK-16 fixed |
| `audits/internal/attack-replay-ii.md` | `HK-21`..`HK-26` | The exploits since and the chain's own DEX, by its author | 1 | none; HK-25's bound narrowed in `src/` |

Two reads of the Pyth-check build carry no ids; `CHANGELOG.md` records both. The author's read of the price reader and
the weight changes as an attacker found that a multiplier or a vault rate of zero valued a leg at nothing, so a leg
that left counted as free; such a value is `UnusablePrice` now (mutant PY28). It left four stated bounds as they are:
a wrong feed lowers the check on its token to the units', a creator's change of weights opens a distance its own fill
turns into at most the tolerance, the executor picks which update to post (narrowed to fifteen seconds by HK-25), and
a newer update posted ahead can revert a fill at the edge. A reviewer agent that had not seen the author's reasoning
found no critical or high finding; its fixes are the restart rule needing a settled fill (mutant RS4), and in the
keeper the weights read every round, a wider margin inside the tolerance (`ORACLE_LAG`) and stale comments.

Still open:

- **RY-3, RW-4** (informational, policy): a minter may name itself as referrer and take the referral share of the
  platform's fee. Deferred to the fee policy; a check on chain is dodged by a second wallet.
- **Of the consolidated audit**, seventeen left as they are, with their reasons in its record. Four are in the
  contracts of the primary scope: CA-M2 (the builder's `mint` takes the basket at the call, with no nonce), CA-S03 (a
  settlement during a builder's call, which needs a component that calls back), CA-S04 (a `cancel(id)` after a
  re-org closing another of the same requester's requests) and CA-S05 (a direct caller of `issue` or `redeem` cannot
  bind the amounts it previewed). The other thirteen are in the keeper, the restock, the checker and the scripts:
  CA-M9, CA-M11, CA-M15, CA-M19, CA-L3, CA-L4, CA-L5, CA-R2-01, CA-R2-05, CA-R2-06, CA-R2-07, CA-R2-08, CA-R2-19.
- Fixed since the oracle-free candidate's package: RW-3 and RB-5 (in `src/`), RZ-8, RZ-10, RZ-11, RZ-20 and RZ-21
  (keeper and restock), XA-34 and RZ-33. Retired since: V5-I4
  (`audits/retired/pyth-check.md`), and PD-1 to PD-8, PD-11, PD-13, CA-M14, CA-R2-12, CA-R2-13, CA-L7
  and CA-L8 with the restock's non-EVM signers (`audits/retired/non-evm-restock.md`).

The reviews before v5 read v1 to v4: the v1 findings and the v2 rebalancing findings `R01`..`R23`, which have no
record of their own in `audits/` and live on as test names; the whole-repo audit (`XA..`,
`audits/internal/whole-repo-audit-xa.md`, triaged in `audits/internal/whole-repo-audit-xa-triage.md`); the first logic review (`LR..`); the deep audit
(`DA..`, triaged in `audits/internal/deep-audit-da-triage.md`); the verification review (`VR..`); the first security
audit (`CR-M01`, `CR-L..`, `CR-I..`, triaged in `audits/internal/security-audit-cr-triage.md`); the first red team
(`RT-01`..`RT-25`); and the red team of Stage A (`SA-01`..`SA-15`). Each id that still applies keeps a
regression test named after it. Stage B's families (`VLT`, `HUB`, `MOD`, `BNB`, `FAC`, `SOL`, `TRN`, `LG`, `BLS-1`)
and the swap-venue review's `SV` ids are retired in full, and no test may carry them. Ten retirement records list the
ids whose mechanism is gone, with the test that went and the property that survives: `audits/retired/v3.md`,
`audits/retired/v4-stage-a.md`, `audits/retired/v4.md`, `audits/retired/stage-b.md`,
`audits/retired/thorchain.md`, `audits/retired/pancakeswap-zap-venue.md`, `audits/retired/oracle.md`,
`audits/retired/zap-ether.md`, `audits/retired/pyth-check.md` and
`audits/retired/non-evm-restock.md`.

## 10. Assurance already done

- **Tests.** 663 unit, fuzz and invariant tests without an RPC, and the fork suites on all three chains' real
  tokens, Universal Routers, Pyth's contracts, Ondo's oracles and the chains' own DEXes (section 1's table). CI's gate
  is 100% of lines, statements, branches and functions on every file, mocks and scripts included. Invariant suites for
  the hub (the backing invariant under random issue, redeem, fees, claims, rebalances and freezes), `MintRequests` and
  the keeper's executor. Price-check suites: `test/WeightedHub.oracle.t.sol` and `test/PythPrices.t.sol`. Attack
  suites: `test/Attacks.t.sol`, `test/UniversalRouterSwaps.venues.t.sol` and
  `keeper/test/KeeperExecutor.attacks.t.sol`.
- **The state machine.** `test/WeightedHub.states.t.sol` takes every cell of the transition matrix.
- **The exact model.** `test/vectors/settlement.py` (written from the spec, standard library only) generates 455
  settlement vectors, 77 quote vectors and 85 oracle vectors that `test/WeightedMath.vectors.t.sol` replays against
  the contract word for word, and the keeper's port of the arithmetic replays too; `test/vectors/proofs.py` checks the
  proof's chain on the model in exact rationals.
- **Mutation gate.** 379 mutants as exact edits (`test/mutants/mutants.json`), all 379 killed, in CI. Each fix since
  `7a1d9c2` added its own: PY1 to PY28 (the reader), CW1 to CW12 (weights), FB1 to FB7 (the first issue), RS1 to RS4
  (the restart), MP1 to MP7 (the pause), LV1 to LV24 (the local venues), OV1 to OV10 (the sValue), HK1 to HK12 (the
  replays), and the keeper's.
- **Static analysis.** `forge lint` with notes denied, Wake (`wake detect all src`, in CI) and Aderyn (run by hand)
  report nothing on `src/`; each suppression carries its reason where it stands.
- **End to end.** The keeper as its own process on an anvil fork of Ethereum, its factory on Pyth's real contract,
  every fill carrying Pyth's update and paying exactly its fee, a creation off its weights refused (`OffWeights`),
  requests filled in one batch against real pools: 45 of 45 checks on `914b262`, not yet run on the candidate. The
  restock's UniswapX buy, settled through the real V2 reactor with Uniswap's API, its cosigner and its filler faked
  (`keeper/test/e2e/uniswapx.mjs`), is not run on the candidate either.
- **Deployment rehearsal.** This candidate has not been deployed anywhere; `docs/deployment.md` records what runs on
  Sepolia, an earlier build.

What has not been done: an external audit; a formal proof of the hub or of `WeightedMath` itself; a deployment of this
candidate on a testnet; a mainnet deployment; the keeper's end-to-end test on the candidate's changes, which needs
an archive node (`docs/design/keeper-chain-venues.md`); the keeper's auction path on BNB Chain and on Base,
which needs a factory with an oracle on the fork and Pyth's update signed for it; Base's fill under Pyth's check at
the suite's pin, which waits for an archive run there (`audits/internal/attack-replay-ii.md`, section 6); a Hermes
plan, without which no fill under the check lands; a reading of who mints Base's USDT and can replace its code; Ondo
registering the other 336 tokens in Ethereum's oracle; the restock's UniswapX buy against Uniswap's live API; and the
app's move to this candidate, which posts Pyth's update before a creation, encodes `localRoute` and decodes the new
errors. `CLAUDE.md`'s "Before any mainnet" lists the rest.
