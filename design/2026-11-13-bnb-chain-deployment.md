# A second deployment, on BNB Chain: each chain holds its own coins in kind

2026-11-13. The owner's call, and what was built for it the same day. Nothing is deployed on a mainnet yet, on either
chain.

## 1. The call

The owner, on 2026-11-13: "we are the ones who create indexes now. lets also create bnb chain factory or whatever is
neccesery so on both sides we will have in kind tokens. we will have more little list on ETH but no problem".

It came out of two questions the same day. The first was whether an index token on Ethereum could keep its collateral
on another chain. It can, with vaults of our own on that chain and a message layer between them: Stage B, which the
owner retired on 2026-10-07, and which costs an exit in one transaction, a rebalance in one transaction, and a bridge
of our own to be hacked. The second, this call, is the other way to hold a coin where it lives: deploy the same
contracts there.

What it reverses, said to the owner before the build:

- "One index on Ethereum" of 2026-10-10 (`design/2026-10-10-one-index-wormhole-legs.md`), in part: Xindex is no longer
  one deployment, and no single index holds every coin of the list.
- The owner's refusal of a BNB Chain deployment on 2026-11-10 ("I want to stay on Ethereum").

What it restores: the two-chain decision of 2026-10-07, whose BNB Chain deployment was built that day, shelved on
2026-10-10 and deleted on 2026-10-13. The owner's reason for returning to it: the team now creates every index
(2026-11-10), so a second deployment adds indexes the team makes, not a second open surface.

What it does not change: no vault, no proof, no bridge of our own, nothing crossing a chain inside a protocol
contract, no oracle, only approved wallets creating, the listing rules, and Uniswap's Universal Router as the zap's
one venue.

## 2. What it is

Two deployments that share nothing. Each is `WeightedIndexFactory`, the `WeightedHub` it clones, `WeightedMath`,
`IndexZap`, `BasketBuilder` and `MintRequests`, the same build on both chains, each under its own owner Safe and
guardian Safe.

- **An index lives on one chain and holds that chain's tokens in kind.** An index on BNB Chain holds BEP-20 tokens; an
  index on Ethereum holds ERC-20 tokens. No index spans both.
- **A buyer who wants coins of both chains buys two index tokens,** one on each chain. The hundred-coin index of
  2026-10-10 existed only because Ethereum held the other chains' coins as Wormhole copies; if those copies leave
  Ethereum's list (section 7), the widest Ethereum index is the Ethereum-issued coins.
- **Nothing crosses.** No message, no vault, no shared state, no shared role. A fault on one chain reaches nothing on
  the other.

"In kind" on BNB Chain is not "native". Nine of the twelve coins are Binance-Peg tokens: Binance holds the coin and
one key of Binance's mints the token (section 5). What the BNB Chain deployment removes for those coins is Wormhole,
which wrapped the same Binance-Peg token a second time to bring it to Ethereum. One custodian in place of a custodian
and a bridge.

## 3. What was built

No file under `src/` changed: the contracts were chain-agnostic already, and Sepolia runs them from the environment.
The four release hashes of `DeployWeighted` (CF-5) are unchanged. What changed is the scripts and their tests.

- `script/BnbChainAddresses.sol`: BNB Chain's address book. Twelve coins with their tiers, the two mint currencies,
  Uniswap's Universal Router 2.0.0, its PoolManager and the V3 factory there. Every address was read on chain 56 on
  2026-11-13.
- `script/DeployChecks.sol`: two pinned chains. On chain 56 the router, WBNB, USDC and USDT are the book's and nothing
  else, the owner must be a Safe of at least three signatures with no module, every token of the book is a market
  contract no role may hold, and only the recorded build is broadcast, exactly as on chain 1.
- `script/ConfigureWeighted.s.sol`: `V5_WHITELIST=bnb`, on chain 56 only; BNB Chain's USDC and USDT are never proposed
  as components (A7-22), and its mint currencies are pinned to its book.
- `script/CheckToken.s.sol`: `CHECK=bnb`, and depth on BNB Chain, read against WBNB and USDT, where Uniswap's depth
  sits there.
- `script/DeployWeighted.s.sol`: unchanged but for its notes. The zap's wrapped coin on BNB Chain is WBNB, so
  `mintWithEth` and `burnToEth` take and pay BNB.
- Tests: `test/DeployChecks.t.sol`, `test/Scripts.t.sol`, `test/ConfigureWeighted.t.sol`, `test/CheckToken.t.sol`,
  and the fork suite `test/fork/BnbChainAddresses.fork.t.sol` (section 6). Mutants N1 to N5.
- CI passes `BNB_RPC_URL` to the test step; without that secret the BNB Chain fork suite skips.

### The trap found on the way

Ethereum's Universal Router address, `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`, has code on BNB Chain: Ethereum's
router byte for byte, its immutables included (the same code hash, `0x6a5f…fe7f`), so it names Ethereum's PoolManager
address and settles against no market there. BNB Chain's own router is `0x1906c1d672b88cD1B9aC7593301cA990F94Eae07`.

`DeployChecks.isPinnedChain` read "Ethereum's router has code here" as "this is Ethereum" (RX-23, so that a chain-id
override could not switch the mainnet checks off). On BNB Chain that was true, so a deployment there resolved
Ethereum's address book. It failed safe, at Ethereum's WETH address, which has no code on BNB Chain; nothing could
have been deployed wrongly. But no BNB Chain deployment could have run either, and a script that picks a chain's book
by an address someone else can replay is the wrong rule.

The first rule written that day repeated the mistake in the other direction, and the safety check of the same day
caught it (section 8): BNB Chain was told by its own router having code, asked before the chain id. Both routers are
CREATE2 deployments from the factory anyone may call (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt zero), which
is how Ethereum's came to stand on BNB Chain. BNB Chain's is already replayed on Base, and one transaction of about
4.3M gas would put it on Ethereum. From then on every deployment on Ethereum would have resolved BNB Chain's book and
stopped at WBNB's address, which is empty there: nothing deployed wrongly, and no deployment on Ethereum until the
script was changed.

The rule now. A pinned chain's own id decides wherever the script runs under one: 56 is BNB Chain and 1 is Ethereum,
whatever code stands at either router's address, so nothing anyone deploys on a real chain changes its book. Under any
other id, which is a chain-id override or another chain, BNB Chain's router having code names BNB Chain and is asked
before Ethereum's, so an override cannot unpin a run against either mainnet's state (RX-23). What is left is a run
against BNB Chain's state under an override to exactly 1: it stays pinned, resolves Ethereum's book and stops at
Ethereum's WETH address. Neither chain's WETH, USDC or USDT address has code on the other (read 2026-11-13), which is
what makes every wrong book stop. The tests: `test_RX23_aChainIdOverrideCannotUnpinEthereum`,
`test_RX23_aChainIdOverrideCannotUnpinBnbChain`, `test_bnbChainsRouterReplayedOnEthereumNamesNothing`,
`test_ethereumsRouterAddressOnBnbChainDoesNotNameEthereum`, and on the live chain
`testFork_ethereumsRouterAddressHereIsAReplayThatNamesNothing`. Mutants N1, N2 and N5.

A chain that is neither mainnet is still pinned by a replayed router, as it was before this change: Polygon, Arbitrum,
Optimism and Base hold Ethereum's router, Base holds BNB Chain's too, and a deployment there stops at the book's first
empty address. Neither router has code on Sepolia today; if one is replayed there, the Sepolia deployment script stops
the same way until the rule is changed. Not changed here: it predates this work and stops, never misdeploys.

## 4. The list

The BNB Chain list of 2026-10-07 was sixteen coins. Twelve remain, each listable under the rules as they stand; none
is new.

| Coin | Token | Tier | Who can change it |
|---|---|---|---|
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | Native | nobody: the WETH9 wrapper |
| BTCB | `0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c` | Custodial | Binance's key mints |
| ETH | `0x2170Ed0880ac9A755fd29B2688956BD959F933F8` | Custodial | Binance's key mints |
| XRP | `0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE` | Custodial | Binance's key mints |
| ZEC | `0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb` | Custodial | Binance's key mints |
| ADA | `0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47` | Custodial | Binance's key mints |
| BCH | `0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf` | Custodial | Binance's key mints |
| LTC | `0x4338665CBB7B2485A8855A139b75D5e34AB0DB94` | Custodial | Binance's key mints |
| DOT | `0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402` | Custodial | Binance's key mints |
| ATOM | `0x0Eb3a705fc54725037CC9e008bDede697f62F335` | Custodial | Binance's key mints |
| ASTER | `0x000Ae314E2A2172a039B26378814C252734f556A` | Native | nobody found: no owner, no power in the scan |
| STABLE | `0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F` | Bridged | a 3-of-5 Safe upgrades it (a LayerZero OFT) |

Binance's key is `0xF68a4b64162906efF0fF6aE34E2bB1Cd42FEf62d`, an externally owned account and each Binance-Peg
token's `owner()`. None of the nine is a proxy, so that key mints but cannot replace a token's code. `CheckToken`
found all twelve listable on 2026-11-13, their transfers exact (`testFork_everyBnbTokenPassesTheCheck`). The scan is a
heuristic; the source of each is still to be read before its listing is signed, as the Ethereum cohort's was on
2026-10-18.

Left out, each by a ruling the owner already made:

- **DOGE, AVAX, FIL.** Each is a proxy whose admin, the externally owned key
  `0xD2f93484f2D319194cBa95C5171B18C1d8cfD6C4`, can replace its code. That is why DOGE left Ethereum's list on
  2026-10-14 and FIL is held (RX-64). The read of 2026-11-13 found the same admin on all three
  (`testFork_theLeftOutProxiesAnswerToOneKey`). AVAX stays where it is, on Ethereum as Wormhole's copy from Avalanche.
- **TRX.** TRON closed its BTTC bridge on 2026-06-18 (the reason BTT left Ethereum's list, RX-28).
- **Binance-Peg SOL.** SOL is held on Ethereum as Wormhole's copy from Solana (2026-10-10).
- **NIGHT.** Refused on 2026-10-06.

The mint currencies are Binance-Peg USDT and USDC, 18 decimals each; nothing in the zap or `MintRequests` assumes a
currency's decimals. USDC there is a proxy under the same key as DOGE's. It is never a component, so that key reaches
no index; it reaches what `MintRequests` holds in open USDC escrows. USDT is no proxy.

## 5. Who is trusted on BNB Chain

- **Binance,** for nine of the twelve coins and both mint currencies: the custody of the coin behind each token, and
  one key that mints it. A Binance-Peg token that lost its backing would still be held, in kind, by every index that
  holds it; nothing on chain would see it. The app labels each Custodial.
- **Wormhole, for nothing.** No coin of the BNB Chain list is a Wormhole copy.
- **BNB Chain's validators,** in place of Ethereum's.
- **Us, for no more than on Ethereum.** The same contracts, the same roles, a Safe of its own.

## 6. The market on BNB Chain

The zap swaps through Uniswap's Universal Router alone (the owner's call of 2026-10-14), and on BNB Chain Uniswap is
the smaller venue: most depth sits on PancakeSwap, which neither the zap nor `CheckToken` reads. What the zap can
reach, read on 2026-11-13 between blocks 133,339,811 and 133,342,099 (the coin's best Uniswap V3 pool against USDT; the first figure is
the USDT that pool holds, the second the coin within 2% of its price):

| Coin | USDT in its best USDT pool | Coin within 2% | Reading |
|---|---|---|---|
| WBNB | 872,552 | 510 | deep |
| BTCB | 205,180 | 0.6, and 24.9 against WBNB | deep, through WBNB |
| ETH | 11,934 | 0.6, and 119.5 against WBNB | deep, through WBNB |
| ZEC | 246,561 | 37.7 | routable |
| XRP | 86,214 | 6,932 | routable |
| ASTER | 32,840 | 12,159 | routable |
| ADA | 6,472 | 4,861 | thin |
| LTC | 6,445 | 5.3 | thin |
| BCH | 1,572 | 0.14 | no market to speak of |
| STABLE | 1,464 | 11,283 | no market to speak of |
| ATOM | 681 | 49 | no market to speak of |
| DOT | 247 | 6, and 1,625 against WBNB | thin, through WBNB |

Six of the twelve have a Uniswap market worth routing a mint through. The other six mint in kind or through
`MintRequests`, as the coins without a route do on Ethereum, and a rebalance that buys them needs an executor that
already holds them. This is the "no pools" problem again in a smaller form, and it is said here so nobody reads the
BNB Chain deployment as its cure: a coin Binance pegs is not thereby a coin Uniswap trades. Where it is smaller than
on Ethereum: the keeper buys these coins on PancakeSwap, on the same chain as the index, and sends them to its
executor. No bridge, no attestation, no Wormhole message stands between the market and the stock.

The fork suite, on BNB Chain's real state (`BNB_RPC_URL`, 13 tests, passed 2026-11-13 at block 133,361,996; its
first eleven passed earlier that day at block 133,342,099):

- the tokens answer their symbols and decimals, and the router, PoolManager and V3 factory are the pinned builds;
- a whole deployment from the address book alone, checked as one deployment;
- the twelve list on a fresh factory and pass `CheckToken`;
- an index of all twelve issues and redeems in kind;
- the same index rebalances with real transfers: WBNB leaves, each of the other eleven coins comes in, so the index
  probes that it can send every one of them (RX-12), and the holder then leaves in kind at the new units;
- `MintRequests` escrows, fills and cancels in USDT and in USDC, each landing whole;
- the zap mints an index of WBNB, BTCB and ETH from USDT alone and burns it back to USDT through Uniswap's real pools,
  the round trip held by the zap's own limit to under 1%: the command inputs the zap encodes for Ethereum's router
  hold on BNB Chain's;
- the same in BNB, through `mintWithEth` and `burnToEth`.

## 7. Not done, and what is the owner's

- **Ethereum's list is unchanged: 91, with its 15 Wormhole copies.** The call says the list on Ethereum gets smaller.
  Which copies leave is the owner's: the six whose source is BNB Chain (XRP, ADA, LTC, DOT, ATOM, BNB), which the BNB
  Chain list now holds without Wormhole, or all fifteen. The other nine (SOL, AVAX, SUI, APT, JUP, PYTH, ALGO, OP,
  AERO) have no in-kind home on either chain: off Ethereum's list they are in no index at all. The change touches
  `script/Listings.sol`, its pinned table, the fork suites and the restock service, so it is one edit made once the
  answer is known.
- **The owner Safe and the guardian's Safe on BNB Chain.** A Safe is per chain. The deploy script refuses a Safe of
  fewer than three signatures there, as on Ethereum.
- **The `BNB_RPC_URL` secret,** an archive BNB Chain RPC, so CI runs the BNB Chain fork suite; until it exists the
  suite skips in CI and runs by hand.
- **The source reading of the twelve,** before any listing is signed.
- **The keeper on BNB Chain.** Its bot takes a chain from `CHAIN_ID` and has presets for Ethereum and Sepolia only: a
  BNB Chain preset (SwapRouter02, QuoterV2 and the V3 factory there, Pyth's contract, the twelve coins' Pyth ids), an
  executor deployed there, and a way to hold stock of the six coins without a Uniswap market. The restock service is
  mainnet-only and bridges; on BNB Chain it has nothing to bridge.
- **The app,** which serves one chain today.
- **The external audit's scope and the legal reading,** which now cover a second chain and Binance as custodian of
  most of one deployment.
- **Uniswap as the only venue on BNB Chain.** The owner removed PancakeSwap from the zap on 2026-10-14, for Ethereum,
  where it mattered to one coin. On BNB Chain it holds most of the depth. Nothing here reopens that call; the table
  above is what it costs there.

## 8. The safety check of 2026-11-13

The owner asked, the same day, whether everything was built safely. The change was read again by its author and, with
no conclusion handed over, by a second reviewer who ran no test and read the chains. One defect, fixed:

- **Anyone could have stopped the Ethereum deployment (medium, fails closed).** Section 3 has it: the rule that told
  BNB Chain by its router's code before the chain id, on a router anyone can replay onto Ethereum. Fixed by letting
  the chain id decide on chains 1 and 56, with `test_bnbChainsRouterReplayedOnEthereumNamesNothing` and mutant N5.
  Nothing an outsider did could reach funds or produce a wrong deployment either way: every wrong book stops at an
  address with no code.

Closed with it:

- The fork suite, the only check of BNB Chain's stablecoins and Uniswap addresses on chain, skips in CI until the
  `BNB_RPC_URL` secret exists. `test_CRL08_theBnbListIsTheReleaseRecord` now pins the two stablecoins, the router, the
  PoolManager and the V3 factory by hand beside the twelve tokens, so an edit to any of them fails CI without the
  secret. The secret is still wanted: only the fork suite compares the book with the chain.
- The fork suite ran no rebalance and no `MintRequests` request on real BNB Chain tokens. It does now (section 6).

Read and found sound: the Safe rules, the broadcaster check, the roles against the market, the pinned market and the
release hashes (CF-5) all hold on chain 56 by its id alone; BNB Chain's USDT and USDC are refused as components under
any chain id (A7-22); `src/` names no address, chain id or decimals; the zap's `receive()` takes the coin from WBNB
alone, and WBNB is WETH9 with the same `withdraw`; `foundry.toml` compiles for Cancun, which BNB Chain runs; BNB
Chain's block gas limit is 70M (read that day). On chain: the twelve tokens and both stablecoins answer their symbols
and 18 decimals; the nine Binance-Peg coins, WBNB, ASTER and USDT have no proxy slot set; STABLE's admin answers to
the 3-of-5 Safe; USDC's admin is the one key the book names; BNB Chain's router differs from Ethereum's only in its
immutables.

Known and not changed:

- Neither Binance-Peg stablecoin has `permit`, so `mintWithTokenPermit` adds nothing on BNB Chain: the app offers no
  one-signature mint there.
- One deployer key at the same nonce gives both chains' contracts the same addresses. No signature replays across
  them: a permit carries its chain id.
- `foundry.toml` has no `bnb` RPC alias and no explorer entry for `--verify`; the file is pinned by its hash, so they
  are added with the deployment's runbook.
- The Ethereum fork suites ran that day near the head on a public node, which cannot serve their pinned block:
  `MainnetAddresses.fork` and `Security.fork` (17 of 17), `CheckToken.fork` (7 of 7), `IndexZap.fork` (14 of 15).
  The one failure is `testFork_mintWithUSDC`'s bound that one share costs over 100 USDC, true at the pinned block and
  98.89 USDC at block 26,406,345; neither that suite nor anything it runs was changed. `WeightedHub.fork` needs an
  archive node and was not run. CI runs all five at the pinned block.
