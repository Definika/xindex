# The engine behind the website: can it be built for mainnet, and safely?

**Status:** research record and architecture decision proposal, 2026-10-14. The same day the owner asked for the
engine to be built without waiting on section 9, so its step 1 is built on defaults that keep every decision open:
fees in shares with the platform's policy at zero until the owner sets one (so the no-fee call survives as a
configuration), a creator fee of 0 to 100 bps per side, an interval of 7 to 91 days, private indexes as unlisted plus
an opt-in mint allowlist, and `MintRequests` unchanged; the streaming fee (5.6, B) and the basket builder (5.5) were
built on 2026-10-16. The creator role and the
allowlist live in the factory, not the hub, for the hub's size (section 6 said the hub; it ended 940 bytes over
EIP-170 that way). The request filler (step 2) was built on 2026-10-16 in `keeper/`.
**Deciders:** the owner.
**Input:** the website mockup (`Xindex UI mockups/Xindex-Website.html` and its page files, with the wireframe notes),
the contracts in `src/` at `972f962`, the public record of what index protocols shipped and lost in 2025 and 2026,
and Ethereum's state on 2026-10-14 (block 26,192,394; block gas limit 60,000,000, read from a public node).

The owner asked for a clean sheet: forget the decisions made so far, work out what the website needs, and find out
whether that can be built as mainnet smart contracts, safely. This record derives the answer from the website and the
2026 landscape, and only then compares with what exists.

## 1. The answer

Yes, with one reading of the website and not with another.

**Buildable safely:** an ERC-20 index that a creator defines once (coins and percentages), that holds its coins in
kind on Ethereum, that anyone mints and burns at any time without any price feed, that rebalances back to its
percentages on a cadence through a permissionless auction whose settlement is the only place a price is read, where a
single fill can move only a bounded share of any coin, where fees are taken as shares and never as a power over the
coins, and where no key, not the creator's, not Xindex's, can move holders' coins. Buying with USDC in one click is
atomic up to about 35 coins; above that it is a request that a filler serves, with Xindex running the first filler.

**Not buildable safely, and the website should stop implying it:**
- Coins with no form on Ethereum. Monero has none. Hedera's only Ethereum bridge, hashport, shut down on 2026-05-31
  and its wrapped tokens are unredeemable. Cardano, Litecoin, Dogecoin and XRP have Coinbase's custodial wrappers on
  Base, not on Ethereum, and Wormhole copies of Binance-Peg tokens on Ethereum; those are custodial legs, labelled,
  or nothing. "200+ coins, multiple chains" is not true of any safe design today; "every coin that lives on Ethereum
  or has an accepted wrapper, labelled by its trust" is.
- Synthetic exposure (an oracle-priced claim on a coin the index does not hold). It needs a counterparty and puts an
  oracle into every mint and redeem. Perpetual-futures rails exist (Hyperliquid's HIP-3 lets a builder list any
  market with its own oracle), but their oracle is one party's and their open interest is a deployer's business, not
  a holder's backing.
- Minting against cash at a net asset value (deposit USDC, the index values itself by oracle, buys later). It makes
  the oracle a mint-time attack surface and dilutes the in-kind holders on every mispriced mint.
- A rebalancing key, an upgradeable index, or a creator who can change the basket. Each is a power over funds.

The engine the website needs is, to about four fifths, the one in `src/` today, built fresh in 2025-26 and reviewed
five times. The clean-sheet derivation below lands on the same core, because the alternatives are the ones listed
as unsafe. What it adds: fees paid in shares with a creator, a platform and a referrer share; a rebalance cadence
chosen per index; mint-gated private indexes; a first-party filler so that a big basket is still one click; a
reconciled coin list; and three hardenings the parameter replay can price. It also overturns one recorded product
decision (no fee) and amends two others (section 8).

## 2. What the website promises

Read from the mockup and its wireframe notes. The split decides what the contracts must do.

| Promise | Where it appears | On chain or off |
|---|---|---|
| Create an "index coin", an ERC-20 for a basket, with custom proportions, name, symbol, public or private | Home, Create Index steps 1-3 | On chain: creation, weights, mint gating. Off chain: description, categories, logic summary |
| One-click Buy / Sell, price shown in USD and ETH | Index details sidebar, cards | On chain: mint and redeem through swaps. Off chain: quotes and display |
| Trading fee 0.3%, creator fee 0.1%, "Commissions $67" on a creator's index, "Platform Commission 0.5%" at creation | Index details, My Indexes, Create Index step 3 | On chain: fee rates and recipients |
| Recommendator commissions, 0.1 to 0.2% "per adoption" | Recommendations, Requests | On chain: a referrer share of the mint fee. Off chain: reputation, requests, acceptance |
| Rebalancing "Quarterly", "Monthly", "Bi-weekly", "Weekly" to maintain target allocations | Index details, enterprise index tables | On chain: a cadence per index and the mechanism |
| TVL, holders, volume, performance history, "Most indexed coins" | Everywhere | Off chain: an indexer over on-chain events |
| Contract address, Network: Ethereum, Verified by Xindex Team, Promoted | Index details, Trending | On chain: the address. Off chain: labels |
| Supported coins: BTC, ETH, SOL, LINK, DOGE, UNI, AAVE, XMR, AR, CRV; enterprise: ADA, WLFI, LTC, BNB, BCH, AVAX, HBAR; "200+ coins, multiple chains" | Coins, Enterprise, About | On chain: the listing. Several of these cannot be listed (section 5.2) |
| Enterprise: sub-accounts, master wallet, multi-sig, approval workflows, audit log, reports | Enterprise pages | Off chain, with Safes: nothing in the index contracts |
| Email login, watchlists, alerts, profiles, "Delete account" | Dashboard, Settings | Off chain |

What the contracts must therefore provide: creation with fixed weights; mint and redeem; fees with three recipients;
a referrer on mint; a cadence per index; rebalancing; mint gating for private indexes; events an indexer can rebuild
holders, TVL and volume from; and a listing process for coins.

## 3. Requirements, stated

Functional:
1. Anyone creates an index: 2 to N coins from the listed set, integer percentages summing to 100, name, symbol,
   optional mint gating, a rebalance cadence from a menu, a creator fee within a cap.
2. Anyone mints and burns at any time, in kind or through USDC/USDT, with the fees the index declares.
3. The index returns to its percentages on its cadence without any trusted party, within bounds a holder can read.
4. Fees reach the creator, the platform and, when named at mint, a referrer.
5. An indexer can compute every figure the website shows from events and views alone.

Safety (the properties that make "safely" true, each testable):
1. No exit depends on a price, a key, a bridge or a bot: `redeem` and `redeemSkipping` work in every state, and a
   frozen coin is skipped and claimable later.
2. Backing invariant: for every coin, the index holds at least `floor(totalSupply × units) + claims`.
3. One place reads a price, the rebalance settlement, and what one settlement can move is bounded in units, not in
   the value the price reports.
4. No power over funds exists: no pause, upgrade, sweep, basket change, rebalancing key, or fee that moves coins.
5. Every parameter of an index is fixed at creation; the platform's later changes reach only new indexes, except the
   platform's recipient address.
6. Every path fits a transaction under EIP-7825's cap of 2^24 gas (16,777,216) at the maximum basket size.
7. Executors, fillers and referrers are untrusted; reentrancy is guarded everywhere; standard ERC-20s only.

## 4. The 2026 landscape

### 4.1 What index protocols do today

- **Reserve's Index DTFs** (the Folio contracts, live since December 2024, version 5.0.0 current). In-kind: "a
  backed ERC-20 token that allows permissionless minting and redemption while maintaining a flexible basket", with
  no price oracle in mint or redeem. Rebalancing is role-driven: a `REBALANCE_MANAGER` (a governance timelock) starts
  a rebalance with target weight ranges and per-token price ranges of at most 100x width, an `AUCTION_LAUNCHER`
  opens Dutch auctions with exponential price decay during a restricted window, then anyone may; a TTL of at most 4
  weeks; governance can cap each auction's size; since v4.0.0 (June 2025) a trusted-filler framework whose first
  filler is CoW Swap, and since v5.0.0 the admin can disable permissionless bids entirely. Fees: a TVL fee between
  15 bps and 10% a year as share inflation, a mint fee between 15 bps and 5%, no redeem fee, with a 15 bps floor to
  Reserve's DAO on each and creator-configurable splits. Audits: Trust Security, a Cantina competition, Trail of
  Bits (v2 and v4), Pashov (v4 and later). Unsupported tokens: pausable or blocklisted, fee-on-transfer, callbacks,
  rebasing; the docs flag USDC and USDT as risky. No exploit of the Folio contracts is on record.
- **Index Coop on Set Protocol v2**: manager-driven rebalancing through an auction module where bidders are
  whitelisted, flash-mint contracts for single-transaction mints. Its INDEX token hit an all-time low in June 2026;
  the products run, the model is a managed fund, not a creator platform.
- **Spectrum** (PRISM ecosystem, 2026, Ethereum and Base): each index is an ERC-20 with its own Uniswap v4 hook and a
  pool against a yield-bearing stable; the hook routes a buy into the components at their weights and mints; a burn
  redeems in kind at NAV; a 1% fee on every mint and redemption, 30% to the creator; baskets are immutable and never
  rebalance; no audit is named. It shows the creator-platform shape the website wants, and what it leaves out.
- **Alongside's AMKT**: a 25-asset market-cap index, rebalanced monthly by its team; about 4,300 tokens in
  circulation in June 2026.

The pattern across all four: in-kind backing, mint and redeem without an oracle, and rebalancing that is either a
trusted role's job (Reserve, Set, Alongside) or absent (Spectrum). Xindex's permissionless oracle-settled auction is
the one design among these that rebalances a creator's index with no manager; the price it reads is the cost of
that, and the bound on what a fill can move is what makes the cost acceptable.

### 4.2 What was lost, and why

- **Balancer v2, 2025-11-03, about $128M**: rounding in the stable-pool invariant compounded across chained batch
  swaps, in contracts audited by four firms. Lesson: the invariant must be checked after every settlement in the
  units that matter, rounding must be proven to favour the pool, and mutants of each rounding must fail a test.
  Xindex's hub already carries both (`SA-07`, the post-check, the mutant list in the v5 spec).
- **Ostium, July 2026, about $23.75M** (reported by a vault-insurance vendor, so one source): a party with
  price-submission authority opened positions at a forged price. Lesson: whoever can submit a price is the attack
  surface. In Xindex nobody submits one; the hub pins the slot and reads Pyth's signed update for it.
- **Oracle attacks on lending protocols tripled in 2026** by the same vendor's count. Lesson: a price read on every
  user action is a surface on every user action. Reading one only at a weekly settlement, bounded, is the design.
- **Wormhole, 2022**, a signature-verification bug minted unbacked wrapped ETH. Lesson: a wrapped leg's whole value
  rests on its bridge, so the app must say so and the creator must choose it knowingly.

### 4.3 Oracles on Ethereum, October 2026

- **Pyth.** The DAO's migration from Pyth Core to Pyth Pro (OP-PIP-100) completed on 2026-08-26: the existing Core
  contract addresses on all EVM chains were upgraded in place, on-chain fees are zero (OP-PIP-128, OP-PIP-130),
  updates are signed by the five-key set of Pyth's own multisig instead of Wormhole's guardians (OP-PIP-132), and
  Hermes, the service that hands out signed updates, now requires an API key. Pyth's docs say existing integrations
  "were automatically upgraded by the DAO" and recommend the upgraded addresses for new ones. Coverage: a USD feed
  for every coin on the current list (92) and for the website's coins. Trust: five keys held by Pyth's organisation,
  and a contract Pyth's governance can upgrade. Cost: an API key, free to trial, priced by plan (the plans were not
  published where this record could read them).
- **Chainlink Data Streams.** Pull-based, signed by a decentralised oracle network, on Ethereum mainnet in early
  access since February 2025; a 2026 survey counts 122 assets across six networks. Too few for a hundred-coin
  universe; a better signer set for the coins it has.
- **RedStone Core.** Pull-based; signed data packages ride in calldata and the consumer contract checks a threshold
  of unique authorised signers and takes the median; self-reported coverage above 1,000 assets. The widest second
  source if a second signature set is ever wanted on the coins both cover.

### 4.4 Wrapped coins

- **Bitcoin**: WBTC (BitGo and BiT Global, a 2-of-3 custody split across three jurisdictions; the largest supply),
  cbBTC (Coinbase alone, can freeze and blacklist), tBTC (51-of-100 threshold signing by node operators), FBTC and
  LBTC (custodian consortia). Supply figures disagree across sources by a factor of two; any choice is a custodian
  choice, and holding two Bitcoin wrappers in one index is a creator's way to split it.
- **Solana, Avalanche, Sui, Aptos and the rest of Wormhole's chains**: Wormhole's token bridge wraps them
  permissionlessly; 13 of 19 guardians can mint or upgrade every wrapped token at once.
- **Cardano, Litecoin, Dogecoin, XRP**: Coinbase's cbADA, cbLTC, cbDOGE and cbXRP exist on Base only (June and July
  2025), backed 1:1 in Coinbase custody. BitGo's wDOGE on Ethereum has a stale listing and no depth. On Ethereum the
  only copies are Wormhole wraps of Binance-Peg BEP-20s, which stack Binance's custody on Wormhole's guardians.
- **Hedera**: hashport, the only Ethereum bridge, wound down on 2026-05-31; its `[hts]` tokens are permanently
  unredeemable. Hedera now connects through Axelar and LayerZero; no Ethereum ERC-20 for HBAR with a live
  redemption path was found.
- **Monero**: no wrapper of any kind.
- **Arweave**: no Ethereum form was found; its AO-era tokens are a different asset.

### 4.5 Ethereum itself

- EIP-7825 caps every transaction at 2^24 gas since Fusaka. The block gas limit is 60,000,000 today; the
  Foundation's 2026 goal is 100M and beyond. The cap, not the block, bounds a basket mint.
- EIP-7702 (Pectra, May 2025) lets an EOA batch calls; about 14M EOAs have signed a delegation. A batch is still one
  transaction under the cap, so it does not lift the 35-leg limit; it removes the separate approve.
- ERC-7540 (asynchronous vaults, final 2024) is the standard shape for "request now, claim later": Centrifuge runs
  it over $1.6B and OpenZeppelin shipped a reference implementation in July 2026. `MintRequests` is that shape
  without the standard's interface.
- CoW Protocol's programmatic orders let a contract place conditional orders that solvers fill; Reserve uses CoW as
  its trusted filler. A permissionless auction can expose a `bid` that a CoW solver fills, with no change to the
  auction's rules.

### 4.6 Regulation, briefly

The SEC's 2026 innovation exemption and the March 2026 SEC-CFTC taxonomy concern tokenized securities and their DeFi
trading; nothing read here addresses a creator-made basket of digital commodities. A basket that pays its creator a
fee and holds tokenized stocks (Ondo's) is closer to a fund than a basket that does neither. This is the owner's
legal question; the engine should keep fees explicit and immutable, and the app should make no claim about returns.

## 5. The decisions, derived

Each with the options a clean sheet has, the assessment, and the recommendation.

### 5.1 Backing model

| Option | Exits need a price | Who holds the coins | Covers non-Ethereum coins | Precedent |
|---|---|---|---|---|
| A. In kind: the index holds every coin | No | The index contract | Only wrapped forms | Reserve, Set, Spectrum, Xindex v5 |
| B. Synthetic: USDC collateral, oracle-priced claims | Yes, every mint and burn | A collateral pool and a counterparty | Anything with a feed | Synthetix v2 (retired), HIP-3 perps |
| C. Cash mint: USDC in at NAV, coins bought at the next rebalance | Yes, on mint | The index, with a cash leg | Only wrapped forms | Enzyme-style funds |
| D. Custody elsewhere, a receipt on Ethereum | No on chain, yes in practice | A custodian or Xindex's own vaults | Anything | Stage B (retired), ETFs |

**A.** It is the only option where safety property 1 holds by construction. Its cost is the coin universe and the
size of a basket mint. **Recommended.** B is a derivative with a counterparty; C turns every mint into an oracle
attack; D is a custodian, and Xindex building its own was tried and retired.

### 5.2 Asset universe

The engine lists any ERC-20 on Ethereum that passes the admission check and has a Pyth feed, in tiers the app shows:
Native (the issuer's own contract), Bridged (a Wormhole copy, Wormhole named), Custodial (BitGo, Coinbase, Binance,
Tether, Ondo named; both labels for a copy of a Binance-Peg coin). That is the current rule, re-derived: the trust
is per leg, so the label is per leg and the creator chooses the legs.

Against the website's lists: BTC (WBTC), ETH, SOL (Wormhole), LINK, UNI, AAVE, CRV, BNB (Wormhole copy of BNB),
AVAX (Wormhole), WLFI are listable or listed. DOGE, ADA, LTC, BCH, XRP exist only as Wormhole copies of Binance-Peg
tokens, two custodians deep, and DOGE's was delisted on 2026-10-14 because Binance-Peg DOGE's code can be replaced by
one key; XMR, HBAR and AR have no listable form. **Recommendation:** the website's coin pages show the listed set and
its tiers, nothing else; the About page's "200+ coins, multiple chains" goes.

Two wider options, for later and not for the engine:
- **A Base deployment.** Coinbase's cbADA, cbLTC, cbDOGE and cbXRP live there, gas is cents, so a hundred-leg
  one-click buy is cheap and small buyers are served. The cost is Base's sequencer and upgrade keys under every
  index, and a universe of bridged copies. The engine is chain-agnostic; this is a second deployment, decided
  separately.
- **Bridging Coinbase's wrappers from Base to Ethereum** through Base's canonical bridge (seven-day withdrawals).
  Whether an L1 representation can be deployed for an L2-native token is to be verified before it is proposed.

### 5.3 Where a price is read, and from whom

| Option | Oracle in exits | Parties trusted for the price | Bound on a wrong price |
|---|---|---|---|
| A. No price anywhere: a manager sets auction ranges (Reserve) | No | The manager, per index | The ranges the manager set |
| B. No price anywhere: a price-free band auction (Xindex v4) | No | Nobody | Unbounded drift: a band wide enough for moving targets is a gift to a lone executor |
| C. A price at settlement only, from one pull oracle (Xindex v5) | No | Pyth's five keys and its governance | The unit cap per fill, the auction floor, the guardian's cancel |
| D. As C, plus a second signature set on the coins it covers | No | Both must agree | As C, and a forged price must be forged twice |

A creator platform has no manager per index, so A reduces to a Xindex key that sets prices, the Ostium shape. B
was built and retired for the reason in the table. **C is recommended**, with Pyth, because it covers the universe and
its upgrade is done; the five-key trust is bounded by the cap and stated in the app. **D** is a contained change (one
check in one function) that the replay study can price: it costs liveness on every disagreement and gas on every
fill, and it buys a second signer set on about half the coins. Decide it after the replay, not before.

### 5.4 Rebalancing

The mechanism stays the permissionless auction settled at the pinned slot's prices, with the cap counted in units
(the derivation is the v5 spec's section 5; nothing in this record changes it). Three choices the website forces:

- **Cadence per index.** The website promises weekly, bi-weekly, monthly and quarterly. Today the interval is one
  global constant, 7 days. **Recommended:** a `rebalanceInterval` chosen at creation from a menu {7, 14, 30, 91}
  days, stored in the index, read by `canStartRebalance`. The notice, the auction length and the cap stay global.
  A quarterly index far from its weights converges over several fills; the app shows the drift.
- **Who fills.** The keeper in `keeper/` already starts and fills auctions from an executor's inventory, holds no
  role, and anyone may run one. A CoW-solver entry point (a `bid` that takes the auction's price) is a later
  addition that widens the filler set without changing the rules.
- **Hardenings the replay can price** (each a few lines, each a liveness cost):
  1. a per-coin bound on the move since the last settlement, so a price forged a hundred times off is refused
     before the cap even applies, at the cost of a fill that waits when a coin really crashes beyond the bound until
     the guardian keeps it;
  2. a lower `MAX_TURNOVER` (10% instead of 20%) halves what a forged week can take and doubles the fills a drifted
     index needs;
  3. option D of 5.3.

### 5.5 Buying and selling in one click

| Basket size | Path | What the user signs | Who else is needed |
|---|---|---|---|
| Up to about 35 coins | The atomic zap: USDC to every leg through Uniswap's Universal Router, then `issue`, in one transaction | One transaction (EIP-7702 folds the approve in) | Nobody |
| Any size, fast | A request: USDC escrowed with a minimum share count and a deadline; a filler delivers the shares and takes the USDC | One transaction, then a wait | A filler. Xindex runs the first; the keeper's inventory executor is most of it |
| Any size, self-serve | A basket builder: legs bought over several transactions into a per-user escrow, then issued | Three or four transactions, each under the cap | Nobody |

The 35-leg limit is EIP-7825's: a hundred swaps do not fit 2^24 gas, and no wallet batching changes that. Selling
mirrors buying. **Recommended:** the atomic zap and the request path at launch, with Xindex's filler serving requests
within minutes; the basket builder as a later contract if the filler's wait proves a problem (built on 2026-10-16
as `BasketBuilder`, on the zap's swap engine; whether the app offers it at launch is the owner's). A hundred-leg buy
costs the buyer roughly 15 to 20M gas across the paths that do it, so the app should show the gas beside the
basket size and steer small buyers to smaller baskets.

Minting against cash (option C of 5.1) would make every basket one click and is the only way to do so without a
filler; it is refused for the oracle it puts into mint.

### 5.6 Fees and commissions

The website names a trading fee, a creator fee, a creation commission and recommendator commissions. The design
question is where a fee is taken; the amounts are the owner's.

| Option | How it is taken | Oracle | Moves coins | Precedent |
|---|---|---|---|---|
| A. In shares at mint and burn | The minter's deposit backs more shares than the minter receives; the difference goes to the recipients. A burn mints the fee's shares to the recipients and pays the rest in kind | No | No | Reserve's mint fee, Spectrum |
| B. Streaming, as share inflation | Shares minted to recipients over time; each share's units shrink by the same factor | No | No | Reserve's TVL fee, Set's streaming fee |
| C. In the mint currency, by the zap | The zap skims USDC before swapping | No | Yes, outside the index | Aggregators |
| D. In kind from the basket | The index transfers coins out to recipients | No | Yes | Nothing reputable |

**A, recommended.** Every minted share is backed by the deposit that minted it, so the invariant holds unchanged;
recipients are ordinary holders who redeem when they like; there is no per-index accounting and no transfer the
index initiates. Mechanics:
- `issue(sharesOut, to, referrer)`: the deposit is sized for `gross = ceil(sharesOut / (1 − mintFee))`; `sharesOut`
  go to `to`, `gross − sharesOut` to the recipients. The zap and the request path size by `sharesOut`.
- `redeem(shares, to)` and `redeemSkipping`: `feeShares = floor(shares × redeemFee)` are minted to the recipients;
  the holder is paid the backing of `shares − feeShares`, rounded down as today.
- Recipients: the creator's address (the creator may change its own), the platform's address (read from the
  factory, so a Safe rotation strands nothing), and the referrer named in the call, who takes a fixed share of the
  platform's part. A self-referral is then a discount on the platform's part, never on the creator's, and needs no
  Sybil defence.
- Rates fixed at creation, within hard caps in the contract: a creator fee of 0 to 100 bps per side chosen by the
  creator; a platform fee of 0 to 25 bps per side at the factory's policy of that moment; the referrer's share of
  the platform fee at the factory's policy. The policy changes behind the listing timelock and reaches only new
  indexes, so no fee can ever be raised on a holder.
- A creation fee, flat in ETH, paid to the platform at `createIndex`; a spam bound more than revenue. The website's
  "Platform Commission 0.5%" has no base to be a percentage of at creation; a flat fee is the honest version.

**B** is the website's "Commissions" if those are meant to accrue while people hold. It touches the one seam that
turns shares into amounts (`_backing`), needs a lazy accrual on every state change, and a proof that both roundings
still favour the holders. Reserve's v4 moved its accrual from every block to every 24 hours for the gas. It is a
clean later addition, not a launch feature; the website's per-trade numbers do not need it. Built on 2026-10-16 (the
owner's "build this"): a scale on the recorded units, accrued before every issue, redeem and settlement and on
`accrueFees`, both roundings down; the creator's rate at most 500 bps a year and the platform's at most 100; the
settlement arithmetic moved to `WeightedMath` for the hub's size.

C and D are refused: C is only possible for zap mints and leaves in-kind mints free, D is a transfer the index
initiates, the kind of power this design forbids.

### 5.7 Private indexes

"Private: only accessible to you" cannot mean secret on a public chain. It can mean two things, both cheap:
- **Unlisted**: a flag in the creation event; the app does not show the index. Nothing on chain enforces it.
- **Mint-gated**: `issue` accepts only recipients on an allowlist the creator keeps. Transfers and burns stay free,
  so the token stays an ERC-20 the zap and the request path can handle, and the creator's power is over who may join,
  never over anyone's coins.
**Recommended:** both, chosen at creation; the allowlist can be opened later (a one-way change), never closed on an
index that was public.

### 5.8 Governance, admin, upgrades

Unchanged from the derivation that produced the current rules, because every alternative is a power over funds: an
owner Safe of at least three signatures that lists coins and sets fee policy behind timelocks; a guardian that can
cancel a rebalance, start one around a frozen coin, and delist; no pause, no upgrade, no sweep, no basket change,
no rebalancing key. The fee policy is the one new timelocked knob, and it reaches only indexes created after it.

### 5.9 Secondary market

The primary market is mint and redeem at the basket's value. A Uniswap v4 pool per index, seeded by its creator, is
optional and needs nothing in the contracts; arbitrage against mint and redeem anchors it, slowly for big baskets.
Spectrum's hook-based pool is the alternative; it ties the token to one venue and is unaudited. Not recommended.

### 5.10 Enterprise

Sub-accounts, roles, approval workflows and audit logs are Safes with a roles module and an indexer. The index
contracts see ordinary holders. Nothing to build in the engine.

### 5.11 Build, or deploy on Reserve

| | Xindex's engine | Reserve's Folio |
|---|---|---|
| Rebalancing | Permissionless auction, oracle at settlement, unit cap | A manager role sets weight and price ranges per rebalance; auctions, trusted fillers |
| Who is trusted for a rebalance | Pyth's keys, bounded by the cap | The manager and launcher of each DTF |
| Frozen coin | Skipped on redeem, claimable later; rebalanced around | Unsupported (pausable and blocklisted tokens excluded) |
| Fees | In shares, creator and platform and referrer, capped, fixed per index | Mint fee and TVL fee, creator splits, a 15 bps floor on each to Reserve's DAO |
| Upgrades | None | Proxies; the DTF's own governance opts into versions |
| Audits | Five internal reviews; the external audit is before mainnet | Trail of Bits, Pashov, Cantina, Trust |
| Coin universe | Any ERC-20 that passes the check, with tiers | Standard ERC-20s; USDC and USDT flagged as risky |

Deploying on Reserve would buy its audits and lose the permissionless rebalance, the frozen-coin handling, the
fee floor and the control of the universe; a creator's index would need a rebalance manager, and that manager
would be Xindex. **Build**, and borrow from Reserve the two mechanisms it proved: per-auction size caps (the unit
cap is the same idea) and a solver-fillable bid.

## 6. The architecture

Four contracts and one bot, on Ethereum:

- **`WeightedIndexFactory`** (exists; changes): lists coins with price id, decimals and tier behind the listing
  delay; creates indexes as clones with name, symbol, components (token, weight, units), the creator's fee rate, the
  cadence, the gating flag and the listed flag; holds the fee policy (platform rate, referrer share, creation fee,
  platform recipient) behind the timelock; owner and guardian as today.
- **`WeightedHub`** (exists; changes): the index. `issue(sharesOut, to, referrer)`, `redeem`, `redeemSkipping`,
  `claim`, with fee shares; the allowlist; `rebalanceInterval`; the rebalance as today.
- **`IndexZap`** (exists; small change): passes the referrer; previews include the fees.
- **`MintRequests`** (exists; small change): passes the referrer on fill.
- **`keeper/`** (exists; one addition): a request filler beside the auction filler (built 2026-10-16: `fillMint` and
  `fillRedeem` on the executor, `bot/requests.mjs` in the bot).

Invariants, all of which tests and the invariant suite enforce: the backing invariant with fee shares included in
supply; exits never read a price; a fill moves at most the unit cap and delivers at least `μ` times what it takes at
the settling prices; fee shares minted equal the fee the call declared, never more; the sum of recipients' shares
equals the fee shares; every index parameter is immutable after creation except the allowlist opening, the creator's
own recipient address and the platform recipient read from the factory.

Gas at the maximum basket (100): `createIndex` 13.1M today and a few hundred thousand more for the new fields;
`issue` and `redeem` plus one mint to each recipient; the settlement 7.26M measured on Pyth's real contract for 93
legs. All under 2^24.

What this adds to `src/`, by size: about 150 lines in the hub (fees, allowlist, interval), about 80 in the factory
(creation fields, policy), 20 in the zap and requests, their interfaces and ABIs; about 60 new tests and six new
mutants (fee shares rounded the wrong way, recipients' sum off by one, the gate skipped on the zap path, the interval
ignored, a fee raised after creation, the referrer paid from the creator's part).

## 7. Safety, as a holder would read it

| Party | Can | Reach | Bound |
|---|---|---|---|
| The contracts | Have a bug | Everything | Five reviews, the invariant suite, the mutants, the external audit before mainnet |
| Pyth's five keys, Pyth's governance | Sign or install a forged price | One fill's turnover | 20% of each moving coin's units per fill, once per cadence; the auction floor; the guardian's cancel; hardening 1 of 5.4 if adopted |
| Wormhole's guardians (13 of 19; 5 of 7 named ones to mint copies from chains on delegated guardian sets, RX-6) | Mint unbacked copies, upgrade every copy | Every Bridged leg | The creator chose the legs; the app shows the wrapped share of value and each copy's quorum |
| A custodian (BitGo, Coinbase, Binance, Tether, Ondo) | Freeze, blacklist, burn | That leg | Skipped on exit, claimable later; rebalanced around |
| The creator | Set fees at creation, keep an allowlist | Nothing over coins | Fees capped and immutable |
| The owner Safe | List coins, set future fee policy, replace the guardian, start or cancel a rebalance, delist, hand over ownership | Nothing over coins | Timelocks on listings and the guardian; three signatures for all of it; the rebalance, delist, fee-policy and ownership powers are instant (RX-49) |
| The guardian | Stall rebalances, rebalance around a coin | Drift | Replaceable behind the guardian delay |
| An executor or filler | Fill at the auction's price | Bounded by the cap and `μ` | Untrusted by construction |
| A referrer | Collect part of the platform fee | Nothing | Taken from the platform's part only |

What remains true however the parameters are set: a holder can always burn and receive the coins the index holds,
minus the declared fee, with no key, feed, bridge or bot in the way.

## 8. Decisions this record overturns or amends

- **No fee** (the owner's call of 2026-09-30): overturned by the website. Fees in shares, capped, fixed per index.
- **One global rebalance interval**: amended to a per-index cadence from a menu.
- **The coin list's claims**: the website's lists are reconciled to the listable set and its tiers; "200+ coins,
  multiple chains" is dropped.
- Kept, re-derived: in-kind backing; Pyth at the settlement only; the unit cap; Wormhole as the one wrapping bridge,
  as an opt-in tier; one deployment on Ethereum; no admin power over funds; the zap through Uniswap alone; WBTC for
  Bitcoin.

## 9. Decisions for the owner

**Update, 2026-10-18:** the owner took items 4 to 10 as proposed, the hardenings of item 8 to be decided by the replay
and no Base deployment for now, with a creation fee of zero. Items 1 to 3 (the platform's fee, the referrer's share,
the platform's streaming rate) are not yet decided, so the deployed policy stays at zero; item 11 is counsel's
(`design/2026-10-18-pre-mainnet-readings.md`, section 5).

1. Fees at launch: in shares at mint and burn (5.6 A), with the creator's rate 0 to 100 bps per side and the
   platform's rate 0 to 25 bps per side at creation; or no fee after all.
2. The platform's launch policy: its rate, the referrer's share of it (50% proposed), the creation fee in ETH.
3. A streaming fee (5.6 B): never, later, or at launch.
4. The cadence menu: {7, 14, 30, 91} days proposed.
5. Private indexes: unlisted plus mint-gated, both opt-in at creation.
6. The first filler: Xindex runs one (the keeper's request filler), or market makers are expected to.
7. The basket builder: at launch, or after the filler is measured (the contract exists since 2026-10-16).
8. Hardenings to price in the replay: the per-coin move bound, a 10% turnover cap, a second signature set.
9. The website's coin pages: the listed set and tiers only; XMR, HBAR, AR removed; ADA, LTC, BCH, XRP shown as
   Custodial and Bridged if listed at all; DOGE absent until relisted.
10. A Base deployment as the second deployment, to be designed separately, or not.
11. The legal reading of a fee-earning creator basket that may hold tokenized stocks, before any mainnet.

## 10. The plan, once decided

1. Contracts (about two weeks with tests, mutants, coverage, lint, Wake and Aderyn clean): the hub's fees, allowlist
   and interval; the factory's creation fields and policy; the zap's and requests' referrer; ABIs; the fork suites
   again, since the hub changes.
2. The keeper's request filler (about a week): watch `Requested`, quote the basket, buy the legs in as many
   transactions as the cap needs, `fill`; a subsidy setting as the auction filler has. Built on 2026-10-16: the
   executor buys the basket in the fill's own transaction, from stock and along quoted routes, so a request wider
   than one transaction's swaps waits for stock; `MIN_PROFIT_USD` below zero is the subsidy.
3. The pre-mainnet list already recorded, unchanged in substance: a Hermes key and one settlement on a real update;
   the parameter replay, now also pricing the three hardenings; the five fork suites; Ondo's corporate-action
   mechanism; the owner's read of the 44 verified sources; the external audit over the final build; the release
   hashes fixed at the audited commit.
4. The app: fees and gas shown beside every basket; the tiers and the wrapped share on every index; the referrer
   passed on mint; the indexer over the events.

## 11. Sources

Read on 2026-10-14 unless stated.

Index protocols: Reserve's Index DTF documentation, mirrored at
[rebalancing](https://mintlify.wiki/reserve-protocol/reserve-index-dtf/concepts/rebalancing),
[the Folio contract](https://mintlify.wiki/reserve-protocol/reserve-index-dtf/contracts/folio),
[FAQ](https://mintlify.wiki/reserve-protocol/reserve-index-dtf/resources/faq),
[changelog](https://mintlify.wiki/reserve-protocol/reserve-index-dtf/resources/changelog) and
[audits](https://mintlify.wiki/reserve-protocol/reserve-index-dtf/resources/audits);
[Trail of Bits on Reserve's Solana DTFs](https://trailofbits.com/library/reserve-protocol-solana-dtfs/);
[the Cantina competition](https://cantina.xyz/competitions/9dfca0bc-a7bf-482e-a3df-4eb861f55c4f);
[Reserve's Index Protocol launch](https://www.financemagnates.com/thought-leadership/reserve-launches-index-protocol-bloomberg-indices-coindesk-indices-and-marketvector/);
[Index Coop's auction module](https://hackmd.io/@indexcoop/SkuCiGDJ2) and [INDEX on DefiLlama](https://defillama.com/token/INDEX);
[Spectrum, in Zeneca's letter 117](https://www.zeneca.xyz/p/letter-117-the-prism-ecosystem);
[AMKT](https://www.coindesk.com/id/price/amkt);
[a planned basket hook on Uniswap v4](https://github.com/EqualFiLabs/statics/issues/108).

Incidents: [Coinspect on Balancer v2](https://www.coinspect.com/blog/balancer-rate-manipulation-exploit/),
[DL News on Balancer's audits](https://www.dlnews.com/articles/defi/balancer-suffers-128m-exploit-despite-multiple-audits/),
[Ostium and the oracle-attack count, a vendor's article](https://beincrypto.com/firelight-goes-live-protection-built-defi-vaults/).

Oracles: Pyth's [OP-PIP-100](https://forum.pyth.network/t/passed-op-pip-100-pyth-core-to-pyth-pro-migration/2420),
[OP-PIP-128](https://forum.pyth.network/t/passed-op-pip-128-pyth-core-sunset-fee-zeroing-balance-repatriation/2662),
[OP-PIP-132](https://forum.pyth.network/t/passed-op-pip-132-pyth-core-deprecation-evm/2672),
[OP-PIP-45](https://forum.pyth.network/t/passed-op-pip-45-assign-douro-as-the-trusted-signer-for-pyth-lazer/1895),
[the upgrade notice](https://docs.pyth.network/api-explorer) and [Hermes](https://docs.pyth.network/price-feeds/core/api-instances-and-providers/hermes);
Chainlink's [Data Streams networks](https://docs.chain.link/data-streams/supported-networks.md) and
[the February 2025 expansion](https://dev.chain.link/changelog/data-streams-expands-to-new-blockchains);
[4Pillars on the oracle landscape](https://research.4pillars.io/en/research/the-current-oracle-landscape-and-redstone);
RedStone's [architecture](https://docs.redstone.finance/docs/architecture/) and
[Veridise's SDK audit](https://veridise.com/wp-content/uploads/2025/10/VAR-Redstone-251006-Oracles-SDK-V2.pdf).

Wrapped coins: [a wrapped-Bitcoin comparison](https://www.spark.money/tools/bitcoin-wrapped-token-comparison),
[its security models](https://www.spark.money/research/wrapped-bitcoin-security-models-compared),
[Threshold on BTCFi in 2026](https://www.threshold.network/blog/bitcoin-in-defi-after-the-2026-btcfi-reset);
Coinbase's [cbXRP and cbDOGE](https://www.theblock.co/post/357087/coinbase-wrapped-xrp-doge-base) and
[cbADA and cbLTC](https://www.theblock.co/post/359792/coinbase-wrapped-ada-ltc-live-on-base) on Base,
[with addresses](https://cryptoslate.com/coinbase-to-launch-wrapped-xrp-ada-doge-and-ltc-on-base-network/);
[wDOGE](https://coinmarketcap.com/currencies/wrapped-dogecoin/);
[hashport's wind-down](https://hashport-network.medium.com/the-final-chapter-hashport-to-wind-down-operations-on-may-31-2026-12-00-utc-c2e0aa335c46) and
[SaucerSwap's bridge page](https://docs.saucerswap.finance/get-started/bridge-to-hedera).

Ethereum: [the Fusaka gas-cap update](https://blog.ethereum.org/2025/10/21/fusaka-gascap-update),
[Crypto.com's Fusaka research](https://crypto.com/en-ae/research/ethereum-fusaka-upgrade-nov-2025),
[the gas-limit trajectory](https://cointelegraph.com/news/ethereum-could-get-faster-gas-limit-rise-january);
[EIP-7702 adoption](https://eco.com/support/en/articles/14797813-eip-7702-vs-erc-4337-two-smart-wallet-paths) and
[by chain](https://www.growthepie.com/answers/most-smart-account-activity-ethereum-l2);
[OpenZeppelin's ERC-7540 implementation](https://www.openzeppelin.com/news/tokenized-vault-foundation-and-openzeppelin-bring-erc-7540-asynchronous-vaults-to-onchain-funds) and
[Centrifuge on asynchronous vaults](https://centrifuge.io/blog/asynchronous-vaults);
[CoW's programmatic orders](https://docs.cow.fi/cow-protocol/concepts/order-types/programmatic-orders).

Synthetic rails and regulation: [HIP-3](https://nansen.ai/post/what-is-hip-3-hyperliquid) and
[why exotic HIP-3 markets fail](https://medium.com/@Jsquare_co/jsquare-research-why-exotic-hip-3-markets-dont-work-87c268309db1);
[the SEC's exemption and third-party tokens](https://www.ledgerinsights.com/sec-tokenized-stock-exemption-to-cover-defi-trading-of-third-party-tokens-report/) and
[the innovation exemption](https://en.spaziocrypto.com/regulation/sec-innovation-exemption-tokenized-securities-on-chain/).
