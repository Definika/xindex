# Attack replay II (HK-21 to HK-26)

The owner's ask that day: "რაც ჰაკი მომხდარა defi პროტოკოლებზე მინდარო ეგ ჰაკები მოიძიო და ჩვენი კოდი გატესტო მაგ
ჰაკების მიმართ თუ გაუძლებდა" (find the hacks that have happened to DeFi protocols and test our code against them).
The replay of 2026-11-23 (`audits/internal/attack-replay.md`, `HK-1` to `HK-20`) covered the classes of attack from
2016 to June 2026. This record covers what came after it:

- **The exploits of July to November 2026**, read from their post-mortems (section 5), each class aimed at the
  contract here it would hit.
- **The code added since that replay**: the chain's own DEX beside Uniswap (PancakeSwap on BNB Chain, Aero on Base;
  `docs/design/chain-venues.md`), which no replay had seen.

Ids continue the family: `HK-21` to `HK-26`. A test is named `test_HK21_...`, and a fork test `testFork_HK22_...`.
It is one more internal review by the code's author, not the external audit still owed before any mainnet.

## 1. Result

- **One bound narrowed: HK-25.** The executor chooses which Pyth price its fill is checked against. It posts Pyth's
  update itself, Pyth's contract keeps any update newer than the one it stores, and `PythPrices` accepted any price
  under `MAX_PRICE_AGE`, 60 seconds. So of the prices Pyth signed in the last minute, the filler posted the one that
  suited it. The 2% tolerance is counted at that price, so a lone executor kept up to the tolerance plus the most a
  coin moved within that minute, still inside the bar and the caps. Nothing could pass a fill the units refuse.
  It was not new: the independent review of 2026-11-23 had read it and left it as a stated bound (CLAUDE.md's bullet
  of that day, ARCHITECTURE.md's "Who posts the price"). But the passages that state the 2% (`docs/known-limitations.md`,
  `docs/integration.md`, the check's own record) did not count it. On the owner's call ("კი, 15 წამი", yes, 15
  seconds; then, told that a creation is signed by a person in a wallet, a fill's fifteen and a creation's sixty),
  a fill reads a price at most 15 seconds old, and a creation's check, at most 60 (section 3).
- **No other class took anything.** Four were replayed with new tests and refused (HK-21 to HK-24), the DEX ones on
  the real routers of BNB Chain and Base as well as on mocks. One was refused by code that already stood (HK-26).
  The rest of the period's classes are refused by tests that already exist, named in section 2.
- **Five new mutants, all killed**: HK8 and HK9 (an approval to a router), HK10 (a redeem paid before its own
  accrual), HK11 and HK12 (a fill's age back at a minute, a creation's cut to a fill's).
- **One of the replay's own tests was wrong at first**, and running it against the mutant showed it. HK-24 first
  issued 1 to 3·10⁷ wei of shares a round. The shortfall the mutant left rounded to nothing, so the mutant survived;
  HK-05 killed it instead. With shares of up to a thousand whole ones, HK-24 now kills HK10 itself, at the next
  issue (`Underbacked`).

## 2. The classes

| Id | Class, and where it took funds | Where it would hit | Result | Test |
| --- | --- | --- | --- | --- |
| HK-21 | An approval to a router, spent through the router by someone else: SushiSwap's RouteProcessor2 (April 2023); K3 Capital's sBOLD vault (November 2026), whose 1inch allowance was left behind and drained by a second swap | The zap and the builder, through every DEX: Uniswap, PancakeSwap, Aero | Refused. Neither approves any router; each leg pays by a transfer that the same call sweeps back. After a mint, a burn, a buy and a sale through each DEX, no router holds an allowance from the zap, the builder or the user | `test_HK21_noRouterEverHoldsAnApproval`; mutants HK8, HK9 |
| HK-22 | A pool the caller names, trusted by the router: RouteProcessor2's fake pool; Internet Token and a BNB Chain DEX router (September 2026), whose V3 callbacks trusted a caller's pool; Premia (November 2026), which took "the factory deployed it" as "listed" | The chain-DEX legs | Refused. A route names tokens and a fee tier or tick spacing, never a pool. PancakeSwap's router derives each pool from its own deployer, and the engine asks Aero's pinned factories for each. A hop the DEX never made names no contract, and the swap reverts before anything moves | `test_HK22_aRouteCannotNameAPoolTheDexDidNotMake` (mocks); `testFork_HK22_pancakeRefusesAFeeTierWithNoPool` (BNB Chain, 0.3%, which PancakeSwap never enabled); `testFork_HK22_aeroRefusesAPoolItsFactoriesNeverMade` (Base: tick spacing 7, and a stable cbBTC/USDC pair) |
| HK-23 | Self-aliasing, where one pool or one ledger key stands on both sides: Allbridge (July 2026), CometDEX (August 2026), Unifund (November 2026), whose cyclic WETH path was credited twice | A route that comes back to a token it passed, the component included | Refused. Each hop is measured alone, against the balance it leaves. A sale of WBTC through WETH, back to WBTC and on to USDC pays what the WBTC was worth, once: through the zap on PancakeSwap, and out of the builder's escrow on Aero, where every escrow and the builder's balances square after | `test_HK23_aRouteThatComesBackToItsTokenIsCountedOnce`; the measurement's own mutants (CR-L02, RW-9, RW-10) |
| HK-24 | A public recompute between an issue and a redeem: Set's RebalancingSetTokenV3 (October 2026), whose `actualizeFee()` rounded every share's backing up | `accrueFees`, which anyone may call, on an index with a streaming fee and no entry or exit fee | Refused. 300 rounds of issue, then zero to two accruals with a second passing every other round, then redeem. The attacker never ends a round a wei up, the index never a wei down, the scale never rises, and every share stays backed. The scale is `supply / (supply + minted)` of itself, never more | `test_HK24_recomputingTheFeeBetweenAnIssueAndARedeemPaysNothing`; mutant HK10 |
| HK-25 | A pull oracle's report of the caller's choosing: PrimeFi (September 2026) stored a verified report of any age | `PythPrices`, which reads the price the filler posted | **Narrowed.** The filler chooses its price within the reader's window, which was a minute and is fifteen seconds for a fill now; a creation's check keeps a minute (section 3) | `test_HK25_aFillReadsTheLastFifteenSecondsAndACreationTheLastMinute`, `test_aStalePriceStopsTheFill`, `testFork_aStalePythPriceStopsAFill`; mutants HK11, HK12 |
| HK-26 | An index's helper pays at units changed between its read and its pull: Index Coop's ExchangeIssuance (July 2026), where the attacker's SetToken raised its units in a pre-issue hook, so the helper's inventory paid at the new ones | The zap's mint and the builder's `mint` | Refused, by what already stood. The zap reads the rebalance nonce again just before it issues (XA-22). The builder reads the basket and issues it in one call with only `approve` between, and approves exactly what it read, so an index can never pull more. A pull of less would need a component that runs code on `approve`, which the whitelist does not list (HK-19). No index has a hook, and no index but the factory's own clone passes `isIndex` | `test_XA22_mintRechecksTheRebalanceNonceBeforeIssuing`, `test_R11_everyEntryPointIsGuardedDuringTheCallback` |

The period's other classes, each refused by code and tests that already stood:

- **A forged oracle signature**: Bonzo Lend (July 2026), where Supra's verifier accepted a zeroed BLS signature. Our
  contracts verify no oracle signature: Pyth's contract does. A wrong price, signed or forged, can only refuse a fill
  (`test_aWrongPriceCannotPassAFillTheUnitsRefuse`), and no issue, redeem or claim reads one
  (`test_exitsAndMintsReadNoPrice`). The only signatures our contracts check are the shares' permits, OpenZeppelin's
  ECDSA (HK-10).
- **A stale price that falls back to another**: Solido Money (July 2026). There is no fallback: a stale or unusable
  price refuses the fill (`test_aStalePriceStopsTheFill`, `test_anUnusablePriceStopsTheFill`).
- **An oracle's configuration**: Nostra (September 2026) took a median of two sources, one of them $0.006. The
  check has one source per token, set by the owner behind `LISTING_DELAY`, and a price can only refuse.
- **A caller's route through its own pool, with no minimum**: DeFiTuna (July 2026). A route moves only its caller's
  own funds, within the limits that caller set (`test_L03_legLimitStopsASandwichOnOneLeg`). No contract here swaps
  anyone else's funds along a route a caller chose.
- **A contract that calls itself, or trusts what its caller says of itself**: the multicall router of a Safe's
  module setup (September 2026) and FlashLoopAdapter (October 2026). No contract calls an address its caller names,
  a recipient that is the contract or one of its routers is refused (`test_RT21_theFactoryIsNotAValidZapRecipient`,
  `test_venue_theLocalRouterIsNoRecipient`), and `isIndex` is the factory's own record (HK-12).
- **V4 flash accounting netted across one unlock**: GoldPesa's hook (October 2026). Every V4 route is hookless
  (`test_route_rejectsHookedHopsAndHookData`), so no other party has a delta open in the unlock the router opens.
- **A swap check that reads the output alone**: K3 Capital. Both sides are measured as balance changes: `ShortFill`
  on what arrives, and what was given against what the sweep brought back (CR-L02). No allowance is left (HK-21).
- **A hash of packed dynamic fields**: Wanchain, Injective, Liquid (July to September 2026). No contract here hashes
  `abi.encodePacked` output. The index's address and a request's hash take `abi.encode`
  (`test_LR05_theAddressCommitsToEveryField`, `test_RW7_aBoundFillTakesOnlyTheHashOfItsRequest`).
- **`msg.sender == tx.origin` under EIP-7702**: MOKE and LULA (July and August 2026). No contract reads `tx.origin`.
  The deploy checks refuse a 7702-delegated owner or guardian.
- **Transient storage as the only initializer guard**: Startale (September 2026). An index's `initialize` is guarded
  in storage (`test_theImplementationCannotBeInitialized`). The factory's transient marks only detect duplicate
  components within one creation (HK-2).
- **A transient slot left stale**: zkLink (October 2026). It is HK-2's class, replayed then.
- **A Permit2 signature from a reverted transaction**: Vestaa (October 2026). Nothing here uses Permit2. A share's
  EIP-2612 permit names the zap as spender, and the zap pulls from its caller alone (HK-3, HK-11).
- **A sibling entry point without its modifier, and an unchecked narrowing cast**: Ankr (August 2026) and Notional
  (September 2026). Every entry point shares the guard (`test_R11_...`), and every function is held to the ABI table
  (HK-12). The raw casts in `src/` each follow the check that bounds them: the caps and the 96-bit check before a
  leg's change in `WeightedMath._gain`, and the 128-bit check before a quote's entry in the hub.
- **A retired component still counted in a valuation**: Summer.fi (July 2026). Nothing values a share by balances
  (HK-6, `test_control_donationsCannotMoveRedemptionValue`).
- **A permissionless rebalance triggered and bounded by a pool the caller moves**: Zenji (November 2026). No
  contract reads a pool's price (HK-7).
- **A rounding to zero that skips a shared update**: Biswap V3 (November 2026). An accrual that mints nothing still
  restarts the fee's clock (`test_XS1_anAccrualThatMintsNothingRestartsTheClock`).
- **A token's own arbitrary call, a trusted forwarder, BLS identity points**: The Sandbox's OFT (August 2026), Limit
  Break (September 2026), Bonzo. A share has no call-forwarding function and no ERC-2771 forwarder, and no contract
  here checks a BLS signature. A component's own functions are its issuer's: a party the tiers name (HK-4).

## 3. HK-25, the finding

The check's own words, `docs/design/pyth-check.md`: a price older than 60 seconds values nothing, and "a filler
posts Pyth's update itself". Together these let the filler choose the price. Pyth publishes several updates a
second. Pyth's contract stores any update newer than the one it holds, and the stored one is usually older than a
minute on these chains, since nobody else posts. So the filler can post, from the last minute, the price at which
what it takes is cheapest and what it brings is dearest. The check counts its 2% at that price.

What it costs: within a quiet minute, little. Across a sharp move, the tolerance plus that move, on the legs the
fill trades, inside the caps and above the bar. The two other bounds stand: the units' bar, and the caps, which no
price widens.

What changed, on the owner's call:

- `PythPrices.MAX_PRICE_AGE` is 15 seconds, and a fill (`legValues`, and `valueOf`, which the keeper reads) refuses a
  price older (`StalePrice`). The choice narrows to the last fifteen seconds. A filler posting in its own
  transaction meets it when the fill lands in the next block: 12 seconds on Ethereum, 0.45 on BNB Chain, 0.2 on
  Base. On Ethereum a fill that misses that block reverts on its price, and the keeper fills the round after.
- `MAX_CREATION_PRICE_AGE`, new, keeps a creation's check of its weights (`valuesWith`) at 60 seconds. A creator
  signs in a wallet, an Ethereum block takes 12 seconds, and only an approved wallet creates, so the choice a
  creator has within that minute moves its index at most that minute's move off its weights, inside the 5% the check
  allows.
- The docs that state the 2% count the choice: `docs/known-limitations.md`, `docs/integration.md`, `docs/decisions.md`,
  `ARCHITECTURE.md`, `README.md`, `keeper/README.md`, `docs/design/pyth-check.md` and `CLAUDE.md`'s design rule.
- The factory's release hash moved, since the factory deploys the reader, and `abi/PythPrices.json` gained
  `MAX_CREATION_PRICE_AGE()`. The fork tests that read a real batch of Pyth's fill ten seconds after it, and their
  stale cases come at sixteen.

## 4. What this does not cover

- **The incidents off chain**, which no contract answers: AFX Trade and Ostium (July 2026, a developer's machine and
  an oracle's key), the private keys of August, Bitget's tool (September), a reseller's hardware wallets (October),
  Lighter's reused nonce and Chainflip's key shares (November), and the governance captures of BonkDAO, BarnBridge
  and Term Finance. The Safes' signers and the deploy checks are this protocol's answer (HK-4).
- **The chains themselves**: Harmony, Cosmos EVM, MAYAChain, Initia, NEAR Intents.
- **The keeper's bot, the restock and the app**, whose own reviews stand apart.
- **What the post-mortems got wrong.** Several of the period's write-ups rebuild an attack from alerts on unverified
  contracts (Olympix's ledger among them), and some losses are reported at several figures. The classes here are
  what the write-ups describe.

## 5. Sources

- BlockSec's weekly reports, among them https://blocksec.com/blog/web3-security-summerfi-bonzo-lend-exploits,
  https://blocksec.com/blog/web3-security-multicall-router-nostra-exploits,
  https://blocksec.com/blog/web3-security-x100-freezer-nem-exploits,
  https://blocksec.com/blog/web3-security-allbridge-wanchain-exploits and
  https://blocksec.com/blog/web3-security-barnbridge-defituna-exploits
- Halborn, September 2026: https://www.halborn.com/blog/post/month-in-review-top-defi-hacks-of-september-2026
- Bonzo Lend: https://cryptoslate.com/how-a-zeroed-oracle-signature-unlocked-9m-from-hedera-defi-lender-bonzo-lend/
- Solido Money: https://en.cryptonomist.ch/2026/07/28/solido-money-hack-supra/
- K3 Capital: https://rekt.news/k3-capital-rekt
- Olympix's exploit ledger, https://olympix.security/exploits: Index Coop's ExchangeIssuance, Set's
  RebalancingSetTokenV3, Internet Token, PrimeFi, Premia, Startale, Vestaa, Unifund, GoldPesa, FlashLoopAdapter
- SushiSwap's RouteProcessor2 (April 2023), the public record

## 6. Status

| Id | Status | Test | Mutants |
| --- | --- | --- | --- |
| HK-21 | Replayed, refused | `test/UniversalRouterSwaps.venues.t.sol` | HK8, HK9 |
| HK-22 | Replayed, refused | `test/UniversalRouterSwaps.venues.t.sol`; `test/fork/BnbChainAddresses.fork.t.sol`, `test/fork/BaseAddresses.fork.t.sol` | None new: the DEXes' own checks, run on their real routers |
| HK-23 | Replayed, refused | `test/UniversalRouterSwaps.venues.t.sol` | The measurement's own |
| HK-24 | Replayed, refused | `test/Attacks.t.sol` | HK10 |
| HK-25 | **Narrowed in `src/`** (the owner's call) | `test/WeightedHub.oracle.t.sol`; the fork suites' Pyth tests | HK11, HK12 |
| HK-26 | Refused by earlier code | `test/IndexZap.t.sol` (XA-22), `test/WeightedHub.rebalance.t.sol` (R11) | XA-22's own |

The fork tests ran near each chain's head on 2026-11-27. HK-22: BNB Chain at block 135,929,757 and Base at
62,716,280, the CAKE and Aero round trips beside them. After HK-25's change (BNB Chain at 135,935,651, Ethereum at
26,502,690, Base at 62,729,962): BNB Chain's fill checked against Pyth's own contract, its PancakeSwap tests and both
deployments from the book pass; Ethereum's `MainnetAddresses.fork` passes 9 of 9, the reader's fifteen seconds read
on Pyth's real ETH/USD among them; on Base the stale price stops a fill at sixteen seconds and the deployment
passes. Base's fill under Pyth's check needs its four coins in one batch, which they are at the pin and no longer at
the head, so it waits for an archive run at the pin, as it did before this change. The test now reads the batch's
time from the fork rather than a constant.
