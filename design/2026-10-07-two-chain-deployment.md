# Two chains, no vaults: Xindex on Ethereum and BNB Chain

**Status:** the owner's decision of 2026-10-07. Stage B is retired (`audit/2026-10-07-stage-b-retirement.md`), and the
BNB Chain deployment's scripts are built and verified on chain (section 4); its Safe and its deploy remain.

## 1. The decision

Xindex is the weighted index (`WeightedIndexFactory`, `WeightedHub`, `IndexZap`, `MintRequests`) deployed twice: once
on Ethereum and once on BNB Chain. Each deployment holds the ERC-20s of its own chain in kind, prices its rebalances
with Pyth's contract on that chain, and swaps through Uniswap's or PancakeSwap's router there. Nothing crosses between
the two. There is no vault, no proof of Ethereum's finality, no state verifier, no bridge, no speed limit and no
freezer. Holders burn any amount at any time on either chain. "We don't need our own vaults and proofs anymore."

It reverses three recorded decisions, and says so:
- **Native coins in vaults over wrapped ones** (2026-09-29, 2026-10-01). Coins whose chains have no contracts, or
  whose native vaults were built, come in as Binance-Peg tokens on BNB Chain, labelled Custodial as AVAX, ADA and TRX
  already were (the owner's calls of 2026-10-06), or not at all.
- **The vault chains frozen at the eight built** (2026-10-06). None is deployed. The code is tagged
  `stage-b-2026-10-07` and deleted from the tree, as v3 is tagged `v3.0.0`.
- **One hybrid product on `HybridIndexFactory`** (2026-10-01). The hybrid factory, hub, module and extension are
  deleted; `DeployWeighted` is the one deploy script, run once per chain.

What does not change: Stage A's rules as `WeightedHub` keeps them (the invariant, the rounding, the claims, the
recipient traps, the guard on every mutating entry point, no admin power over funds, no rebalancing key), v5's
weighted settlement at Pyth prices, the zap, `MintRequests`, the admission rule and the listing flow.

## 2. Why

**Coverage.** CoinGecko's top 200 by market cap, read on 2026-10-07 ($2,896B in all), splits by where a coin can be
held:

| Where | Coins | Share of the top 200's value |
|---|---|---|
| BTC, ETH and BNB themselves (WBTC and WETH on Ethereum, WBNB on BNB Chain) | 3 | 72.2% |
| The issuer's own contract on Ethereum (69 on Ethereum alone, 43 on both chains) | 112 | 17.9% |
| The issuer's own contract on BNB Chain only | 11 | 0.3% |
| No own contract, but a Binance-Peg copy on BNB Chain (XRP, SOL, ZEC, DOGE, ADA, NEAR, BCH, LTC, AVAX, DOT, FIL, XTZ) | 12 | 8.0% |
| TRX, as the BTTC bridge's BEP-20 already pinned | 1 | 1.1% |
| On neither chain (HYPE, XMR, XLM, SUI, HBAR, TAO, APT, VET and 54 smaller) | 61 | about 4% |

The two chains hold about 96% of the top 200's value. The eight vault chains that were built added XLM, SUI, APT,
VET and INJ as natives, under 1% together, and made NEAR native rather than pegged.

**Cost.** Stage B was six vault implementations in five languages, eight state verifiers on Ethereum, two proof
systems to run daily on every vault chain (a floor of about 2,900 proofs a year per system, $6k to $30k a year each at
2026 prover prices), a keeper with eight chain adapters, and an audit of all of it. For a one-person team that decided
whether the product shipped this year.

**Safety.** The vaults were the safest way to hold another chain's native coin without a custodian: Ethereum's own
consensus, checked by two zkVMs, no key. They were also the only part of the design with a bridge to break. With
nothing crossing chains, the trust in each deployment is its chain, Pyth for the rebalance prices, and each token's
issuer. Binance's custody stands behind the pegged coins, and the app labels every one.

**What was considered and dropped with the vaults.** A 24-hour exit queue in place of the 4% a day speed limit, and a
third proof system: both answered a problem the vaults had, and neither has a subject without them. Tokenized stocks:
not in scope (the admission rule refuses their freeze keys, the legal question comes before any code, and Pyth's
equity feeds publish only in market hours). A Solana deployment: possible, but a Rust rewrite of the index for about
3% of coverage, not planned. Deployments on L2s: the same contracts, a configuration each, adding about 0.2% of
coverage; at most one, if cheap minting matters, after the two launches.

## 3. The product, chain by chain

- **Ethereum** holds WBTC, WETH and the Ethereum tokens: the v5 list of 27 coins plus LINK and UNI
  (`script/PythIds.sol`), minted with USDC or USDT, swapped through Uniswap's Universal Router 2.0.0 and PancakeSwap's.
- **BNB Chain** holds WBNB, BTCB, Binance-Peg ETH and the pinned BEP-20 list (`script/BnbChainAddresses.sol`): XRP,
  SOL, ZEC, DOGE, ADA, BCH, LTC, AVAX, DOT, FIL, ATOM, ASTER, STABLE and TRX, each labelled Custodial, minted with BNB
  Chain's USDT or USDC (18 decimals there), swapped through PancakeSwap's router and Uniswap's.
- An index cannot mix a coin held on Ethereum with one held on BNB Chain. A creator who wants WETH and SOL in one
  token builds it on BNB Chain with Binance-Peg ETH, custodial throughout. A buyer crosses chains in the app, with
  their own funds, through the THORChain rail (`swaprail/`); no contract crosses anything.
- The trust, stated for the app: each chain's consensus (BNB Chain's 21 validators are a smaller set than Ethereum's);
  Pyth; each issuer, Binance for every pegged coin and BTCB, BitGo for WBTC.

## 4. The BNB Chain deployment: what it needs

Each item is checked off as it lands.
- [x] `script/BnbChainAddresses.sol` repurposed (2026-10-07): Pyth's BNB Chain contract (the same proxy code as
      Ethereum's, version 1.4.6, Wormhole chain 4, fee 0), Uniswap's Universal Router 2.0.0 and PancakeSwap's v3
      Universal Router there, both Ethereum's builds byte for byte but for their immutables, each pinned by its runtime
      code hash read at block 126,305,003; USDT and USDC (18 decimals); WBNB, BTCB and Binance-Peg ETH beside the
      pinned 14, each with its Pyth price id and tier. BTCB is priced at BTC/USD, since Pyth has no BTCB feed.
- [x] `DeployWeighted` resolves chain 56's defaults as it resolves chain 1's (`DeployChecks.isPinnedChain`, the
      `pinned*` getters), refuses any other address there, requires a contract owner there as on Ethereum, and counts
      every token of the book as a market contract no role may hold.
- [x] `ConfigureWeighted` takes `V5_WHITELIST=bnb` on chain 56 only (`ListOffItsChain` otherwise), labels BNB Chain's
      tiers, and skips BNB Chain's mint currencies as components; `CheckToken` takes `CHECK=bnb` and measures Uniswap
      depth on BNB Chain (PancakeSwap's pools, where most BNB Chain depth sits, are not read).
- [x] The mint currencies' 18 decimals: nothing in the zap or `MintRequests` assumes a currency's decimals, and the
      fork suite deploys both against BNB Chain's USDT and USDC.
- [x] `CheckToken` on a BNB Chain fork: WBNB, BTCB and Binance-Peg ETH are listable with exact transfers
      (`testFork_wbnbBtcbAndEthPassTheAdmissionCheck`); the 14 passed on 2026-10-05.
- [x] `test/fork/BnbChainAddresses.fork.t.sol` (`BNB_RPC_URL`, `BNB_FORK_BLOCK`): the address book by symbol, decimals
      and code hash, Pyth's parse, a whole deployment from the book alone, and the 17 listings on a fresh factory over
      BNB Chain's Pyth, all passing against the live chain on 2026-10-07. A mint, a burn and a fill on real PancakeSwap
      pools there are not yet exercised; the zap's PancakeSwap legs are the same code the Ethereum fork suite runs.
- [ ] The owner Safe and the guardian deployed on BNB Chain, and the deploy run through them.

## 5. What remains before any mainnet

The Ethereum side as before: the safety pass, Pyth's parameter replay (section 8 of
`design/2026-10-05-custom-weights.md`), the fork test against Pyth's real contract on a real signed update (a Hermes
key), and the external audit. Then the BNB Chain configuration above and its own rehearsal. README and ARCHITECTURE
still describe v4 in places and carry a note until rewritten.
