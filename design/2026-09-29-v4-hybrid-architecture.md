# Xindex v4 (hybrid multichain): Architecture

Status: **proposal, 2026-09-29, revised 2026-09-30 after an external review. On `main` as of 2026-10-01, Stage A is
built, internally reviewed, not yet externally audited or deployed; most of Stage B is built too, and deployed
nowhere; Stage C is researched only.** The Stage B spec (`design/2026-09-30-v4-stage-b-spec.md`) records what is built,
what remains, and each deviation from this design, as a proposal for the owner or a decision the owner made; the
Stage C record is `design/2026-10-01-stage-c-research.md`; section 14 sums up. `ARCHITECTURE.md` describes Stages A
and B as built (it described v3 when this was written); this document describes the design that replaces v3 (the owner's
decision of 2026-09-30: v3 stays at tag `v3.0.0` and on Sepolia and never launches on mainnet). Measurements are dated
2026-09-29 and must be re-taken before any parameter is fixed; `design/analysis/floor.py` reproduces every coverage,
tracking and capacity figure from the saved snapshot.

The revision: two proof systems only where coins leave a vault (4.4); a 0.2% weight floor, which cuts the vault chains
from 22 to 9 (2.1); upgrade prevention for vault chains as well as Ethereum (6.10); weekly supply updates (6.6); a
units-anchored rebalance formula that corrects the first draft's (6.6); the gap fixes of 6.3, 6.7, 6.8, 6.9 and 8.2;
speed limit and mint cap of 4% a day (8.1); funding set out as a decision (13.1); and the non-functional standard
renamed the bounded-loss standard. The owner's decisions of 2026-09-30: no fee in Stage A, funded from outside (13.1);
WBT stays off after its listing check (2.1); the floor buffer is adopted (6.7); and the owner Safe needs at least 3
signatures, which deployment now checks. Of 2026-10-01: v4 launches as one product, on one factory, once the hybrid
index is ready, so Stage A does not launch on its own (14).

v4 lets one ERC-20 index hold the largest crypto assets **in kind, with no custodian inside the protocol**: WBTC, WETH
and the tokens native to Ethereum sit in the index contract on Ethereum, and the native coins of smart-contract chains
(BNB, SOL, TRX, HYPE, ...) sit in ownerless vault contracts on their own chains, which pay out only against proofs of
what happened on Ethereum. Units follow market caps without any price feed, and every failure has a bound computed in
advance.

## 1. Requirements

### 1.1 Functional

| # | Requirement |
|---|---|
| F1 | Anyone can create an index of up to 100 listed tokens, living on Ethereum or on a linked vault chain; the flagship index holds the tokens above a 0.2% weight floor (2.1) |
| F2 | Every share is backed in kind: for each token, holdings ≥ shares × units, at all times |
| F3 | Anyone can buy or sell the index token with USDC/USDT without leaving Ethereum |
| F4 | Minters create and redeem shares in kind, in batches, across all chains |
| F5 | Any holder can redeem in kind, receiving each token on its own chain, and can skip any chain |
| F6 | Units follow the uncapped market-cap rule, `units ∝ supply`, with reference supplies updated weekly |
| F7 | Which tokens an index holds never changes; a new top-100 list is a new index version |
| F8 | Index value is published off-chain from public units and market prices (section 10) |

### 1.2 Non-functional: the bounded-loss standard

| # | Requirement |
|---|---|
| N1 | **Bounded single failure:** no single failure in anything v4 builds may cost holders more than about 0.5% of an index's value per day. The one accepted exception is Bitcoin's custodian (section 8.3). Double failures are bounded too, and section 8.1 states each one's number |
| N2 | **Nobody can move funds:** no key, person or company can move index coins; only code acting on proofs can |
| N3 | **Everything checkable:** anyone can recompute every balance, unit and payout from public chain data |
| N4 | **Exit always exists:** holders can always redeem the chains that work, and claims on the rest never expire |
| N5 | **No price where money moves:** no amount in any money path is computed from a price |
| N6 | **Code-enforced limits:** every bound in N1 is enforced by contracts, not by operators or process |

Operational targets: in-kind redemption in 15–30 minutes per chain; mint settlement within the order deadline plus the
24-hour lock; net mint/redeem capacity set by liquidity (section 9.3), not by the protocol.

### 1.3 Constraints

- v3's design rules carry over except where section 13 lists a change: in-kind backing, CREATE2 addresses that commit to
  contents, fixed constituents, reentrancy-guarded untrusted executors, standard ERC-20s only on Ethereum. v3's "no
  fees" was under review (13.1); the owner kept it for Stage A on 2026-09-30.
- Owner decisions of 2026-09-29: **Bitcoin is held as WBTC only for now; the guardian may freeze a vault, and the freeze
  expires by itself; vaults survive Ethereum upgrades through a 30-day verifier rotation.** Of 2026-09-30: **weekly
  supply updates with a 0.5% step; a 4% daily speed limit and mint cap; v4 replaces v3.**
- A chain is admissible only if its contracts can verify a proof about Ethereum. Script-only chains (Bitcoin, XRP
  Ledger, Dogecoin, Zcash, Monero, Bitcoin Cash, Litecoin, Kaspa, Dash) cannot hold index coins without a signer, so
  they are out of scope; Bitcoin enters through WBTC.

## 2. Scope: which assets

Measured on 2026-09-29 against the top 100 by market cap (CoinPaprika), without stablecoins, gold and wrapped or staked
copies (66 assets):

| Tier | Where coins live | Assets | Share of value |
|---|---|---|---|
| 1 | Ethereum, in the index contract | 24 (ETH, LINK, UNI, AAVE, SHIB, PEPE, ...) | 15.8% |
| 2 | A vault on their own smart-contract chain | 29 (BNB, SOL, TRX, HYPE, ADA, XLM, NEAR, AVAX, SUI, TON, ...) | 11.5% |
| 3 | Script-only chains, out of scope | 9 (BTC 65.8%, XRP, ZEC, DOGE, XMR, BCH, LTC, KAS, DASH) | 72.1% |

Bitcoin enters as WBTC (a Tier 1 token with an outside custodian). Holding everything that can be held, backtested over
the 365 days to 2026-09-29 against a cap-weighted benchmark of the same 66 assets:

| Holds | Tokens | Coverage | Tracking error/yr | Vault chains |
|---|---|---|---|---|
| WBTC + Tier 1 | 25 | 81.6% | 3.8% | 0 |
| WBTC + Tier 1 + BNB, SOL, TRX, HYPE | 29 | 90.4% | 2.7% | 4 |
| WBTC + Tier 1 + all Tier 2 | 54 | 93.1% | 2.0% | 22 |

### 2.1 The weight floor

Most of those 54 tokens weigh under 0.1%. A small weight still costs a minter a native withdrawal on its own chain, a
deposit and a proof for every mint: a $250k mint needs about $125 of the smallest coin, which exchange minimums and
fixed fees make expensive, and fewer minters means a wider spread on the index token. The flagship index therefore holds only
tokens whose weight in the holdable universe is at least **0.2%**, and which pass the listing's liquidity screen (daily
volume at least 0.1% of market cap):

| Weight floor | Tokens | Coverage | Tracking error/yr | Vault chains |
|---|---|---|---|---|
| none | 54 | 93.1% | 2.0% | 22 |
| 0.1% | 28 | 91.8% | 2.3% | 14 |
| **0.2%** | **15** | **90.2%** | **2.6%** | **9** |
| 0.5% | 6 | 87.5% | 3.2% | 4 (BNB Chain, HyperEVM, Solana, Tron) |

The 0.2% floor costs 0.6 points of tracking error against holding everything, and cuts the tokens by three quarters and
the vault chains from 22 to 9. Its list, with each token's weight in the index:

| Token | Weight | Held on | | Token | Weight | Held on |
|---|---|---|---|---|---|---|
| WBTC | 73.0% | Ethereum | | ADA | 0.42% | Cardano |
| ETH | 14.4% | Ethereum | | LEO | 0.36% | Ethereum, **fails the screen** |
| BNB | 4.4% | BNB Chain | | XLM | 0.35% | Stellar |
| SOL | 3.1% | Solana | | NEAR | 0.28% | NEAR |
| TRX | 1.4% | Tron | | UNI | 0.24% | Ethereum |
| HYPE | 0.85% | HyperEVM | | HBAR | 0.21% | Hedera |
| LINK | 0.49% | Ethereum | | AVAX | 0.21% | Avalanche |
| WBT | 0.43% | Ethereum, **fails its listing check** | | | | |

LEO trades 0.006% of its market cap a day, against the screen's 0.1%. WBT passes the screen but failed its listing check:
a single key can blacklist any holder and destroy its balance, and no Uniswap pool holds it on Ethereum
(`design/2026-09-30-wbt-check.md`; the owner kept it off on 2026-09-30). So the flagship holds **13 tokens: 89.5% of
the value at 2.6% a year**. Under the floor, the smallest coin in a $250k mint is about $530.

Staged, each stage working on its own (LEO and WBT out):

| Stage | Holds | Tokens | Coverage | Tracking error/yr | WBTC share | Vault share |
|---|---|---|---|---|---|---|
| A | WBTC, ETH, LINK, UNI | 4 | 79.4% | 4.2% | 82.9% | 0 |
| B | A + BNB, SOL, TRX, HYPE | 8 | 88.2% | 3.1% | 74.6% | 9.9% |
| C | B + ADA, XLM, NEAR, HBAR, AVAX | 13 | 89.5% | 2.6% | 73.5% | 11.3% |

"Vault share" is the part of the index held in vaults; every per-day bound in section 8 is a vault share times a daily
limit. With WBT, Stage A would hold 5 tokens and cover 79.8%.

**The backtest understates tracking error.** It held today's supplies constant, so it measures drift from price moves
only. Tokens whose supply grows through unlocks or emissions drift as well, which is what weekly supply updates follow
(6.6). A re-run with real supply histories is an open task (section 15).

## 3. High-level design

```
                                     ETHEREUM
 ┌───────────────────────────────────────────────────────────────────────────────────┐
 │  IndexFactory      lists chains and tokens (timelocked), creates indexes (CREATE2)  │
 │  IndexHub (×N)     one per index: ERC-20 shares · Tier 1 holdings · mirror of each   │
 │                    vault · mint orders · burns · rebalance auction · limits          │
 │  StateVerifiers    one per vault chain, one proof system: prove that chain's state   │
 │  MintRequests      USDC/USDT ⇄ shares, filled by minters                             │
 │  IndexZap          one-click USDC/USDT for indexes held entirely on Ethereum         │
 │  Owner Safe (3-of-5) · Guardian (veto, cancel, freeze)                               │
 └───────────────────────────────────────────────────────────────────────────────────┘
          ▲ vault state proofs, deposits and          │ Ethereum event proofs, shared by every chain
          │ shortfall evidence (the chain's system)   ▼ (coins out: P1 AND P2 · protective: P1 OR P2)
 ┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
 │ Vault · BNB Chain   │ │ Vault · Solana      │ │ Vault · Tron  · ... │   one per chain, shared by all indexes
 │ P1 + P2 Ethereum    │ │ P1 + P2 Ethereum    │ │ P1 + P2 Ethereum    │   no owner; verifiers rotatable only by
 │ verifiers           │ │ verifiers           │ │ verifiers           │   a proven message after 30 days
 │ per-index balances  │ │ per-index balances  │ │ per-index balances  │
 └─────────────────────┘ └─────────────────────┘ └─────────────────────┘

 Off-chain, permissionless: minters · provers · rebalance executors · watchers · the app (valuation)
```

### 3.1 Trust boundaries

| Party | Can do | Cannot do |
|---|---|---|
| Contracts (hub, vaults, verifiers) | Move coins exactly as proofs and invariants allow | Anything else |
| Owner Safe | List chains and tokens, update reference supplies and caps (timelocked, guardian veto); rotate a vault's Ethereum verifiers after 30 days; rotate a chain's state verifier on Ethereum through the 2-day listing timelock; after a 7-day stall, propose a successor verifier that must pass a continuity test and 30 days of review | Move funds directly; change an existing index's tokens, units rule or vault addresses; manufacture a stall |
| Guardian | Veto listings, cancel rebalances, freeze a vault (expires by itself) | Move funds; unfreeze early; extend a freeze beyond its term without a new act |
| Minters, provers, executors | Deliver coins and proofs; earn spreads and auction discounts | Receive anything they did not pay for first |
| WBTC's custodian | Hold the Bitcoin behind WBTC | — (outside the protocol; section 8.3) |

## 4. Components

### 4.1 IndexFactory (Ethereum)

- **Chain registry.** `proposeChain(chainId, vault, stateVerifier)`, executable by anyone after `LISTING_DELAY` unless
  the guardian cancels. `stateVerifier` is the Ethereum-side verifier of that chain's state (4.4). During the delay
  anyone checks the vault's code hash against the audited build and its immutable settings (the Ethereum checkpoint it
  follows, its P1 and P2 verifiers and the factory it serves). A state verifier is replaced through the same timelock
  (6.10).
- **Token registry.** `proposeListing(token, TokenConfig{chainId, tokenId, decimals, referenceSupply, quantityCap})`, as
  v3's listing flow. `tokenId` is the ERC-20 address on EVM chains and the chain's native identifier elsewhere.
  `quantityCap` is the lower of two caps (8.2).
- **Supply batches.** `proposeSupplies(tokens[], supplies[])` proposes one week's reference supplies as a single batch
  that executes all or nothing after `LISTING_DELAY`, one batch live at a time, guardian veto. Each supply moves at most
  `MAX_SUPPLY_STEP` from the figure in force. A batch is atomic so that nobody can execute half of it and start a
  rebalance on the half: a uniform revision would otherwise become a trade.
- **Creation.** `createIndex(name, symbol, tokens[], k)` sets `units_i = ⌊k × supply_i / 10^36⌋`, requires every unit to
  be at least `MIN_RAW_UNITS` and at most `MAX_UNITS = (2^96 − 1) / 2^10` (headroom for about 690 rebalances at the full
  band), copies the vault address of every chain into the index, and deploys the hub at a CREATE2 address over the
  creator, the name, the symbol, the token list and the **computed units**. A salt over `k` would not commit to the
  basket: a supply batch executed between prediction and creation would change it at the same address. No price is
  read.
- `MAX_COMPONENTS = 100`. Skip and keep masks are 256-bit.

### 4.2 IndexHub (Ethereum, one per index)

- ERC-20 with permit; the only place shares exist. Transfers never touch other chains.
- **Tier 1 holdings** in real balances, issued and redeemed atomically exactly as v3's `issue` and `redeem`, with v3's
  `redeemSkipping` and claims for a frozen or paused token (WBTC's pause included).
- **Mirror** per vault token: the last proven settled balance and paid total, plus the hub's own cumulative burned
  total (section 7).
- **Mint orders**, **burns**, the **rebalance auction**, the **mint cap**, and a per-chain **frozen** flag.

### 4.3 Vault (one per chain)

- Holds native coins and the chain's listed tokens in separate balances per index, and per order while a mint is open.
- Pays out only on proven Ethereum messages (section 5.3), within the speed limit, and marks each message used.
- Coins sent without `deposit(order)` are never credited to any index.
- Moves the coins two index versions share from one index's balance to the other's on a proven `Migrate` message
  (6.7).
- After a snapshot exit (6.9) refuses every `Burn` issued after the snapshot checkpoint.
- Immutable code. Holds a P1 and a P2 verifier reference that change only through a proven rotation message or, after a
  stall, through the continuity-tested recovery of section 6.9, and a guardian freeze address that can only freeze.
- Enforces each token's quantity cap: deposits beyond it are refused.

### 4.4 Verifiers

- **Ethereum → vault chain: two independent proof systems, P1 and P2,** from different teams and different proving
  stacks, each proving an event of a specific hub or factory in a block that has reached **full Casper finality**. The
  statement is about Ethereum alone, so the same two systems serve every chain: each vault chain runs a P1 verifier and
  a P2 verifier of the same two proofs. Neither system has a secret setup, or its setup came from a large public
  ceremony. The sync committee alone is not accepted, because its members are not slashed for signing a false header.
- **Vault chain → Ethereum: one proof system per chain,** proving the vault's per-index state (settled balance, paid
  total, order deposits) at a block that is final under that chain's own rules.
- **Why the asymmetry is safe.** Coins leave a vault only on Ethereum messages, so that is the direction a forgery pays
  in, and it keeps two systems. A forged vault state can only make a mint look backed. That is already contained by the
  24-hour lock (any honest proof of the same vault and height contradicts it), the mint cap, and the fact that a mint
  also needs every Ethereum token in real balances. Section 8.1 bounds what remains.
- **Conflicting proofs are evidence.** Two valid proofs of different states for the same vault and height prove the
  system that made them unsound. Either one, submitted by anyone, voids every order resting on either proof and freezes
  mints involving that chain.
- **Policy.** Messages that move coins out of a vault, or between indexes inside it, need P1 **and** P2. Messages that
  only protect (freeze, lower a cap) need P1 **or** P2. Breaking one Ethereum-side system can stop coins moving; it
  cannot move them.
- **Count.** Stage B needs 6 proving systems (the 2 shared Ethereum systems plus one for each of 4 chains) instead of
  about 10; the full floor list needs 11 instead of 20.
- **Fork-aware on both sides.** Each verifier accepts the current and the next announced version of its source chain's
  formats (6.9, 6.10).
- **Fallback if full-finality proofs prove impractical** (the prototype of section 14 measures them): the sync
  committee, plus a `CHALLENGE_DELAY` on every payout during which a full-finality proof or a conflicting
  committee-signed header freezes the vault, plus lower caps. This is a weaker trust assumption: the committee's 512
  members are not slashable, so a bribe to 342 of them replaces a circuit bug as the way in, and "both systems broken"
  becomes a single failure. The worst case is then 0 if anyone challenges within the delay, and 11.3% × 4% ≈ **0.45% a
  day** of the index if nobody does. Payouts also wait the delay. Adopting it is the owner's call.
- **Status, 2026-10-01:** both full-finality systems are built, P1 on SP1 and P2 on RISC Zero (Stage B spec, sections
  10 and 11), and P1's verification passes the prototype's thresholds on an EVM and on Solana. No proof of either has
  been generated yet: the cost and latency thresholds wait on the owner's GPU run, so the fallback is neither adopted
  nor ruled out (`design/2026-09-30-proving-prototype.md`, "Where Phase 2 stands").

### 4.5 MintRequests (Ethereum)

- `requestMint(stable, amount, minShares, deadline)` escrows USDC or USDT. `fill(id)` by anyone delivers at least
  `minShares` to the requester and receives the stable in the same transaction. `refund(id)` after the deadline.
- `requestRedeem(shares, stable, minOut, deadline)` is the mirror image. No price is read; the requester's own minimum
  is the limit, suggested by the app.

### 4.6 IndexZap (Ethereum)

v3's zap, unchanged in principle, for indexes held entirely on Ethereum: one transaction from USDC/USDT through the
Universal Router to `issue`. At 265k–430k gas per token, EIP-7825's 16.78M-gas transaction cap stops it at 39–63
tokens; the app disables it above about 35.

### 4.7 Off-chain actors (all permissionless)

| Actor | Job | Paid by |
|---|---|---|
| Minter | Buys the tokens anywhere (exchanges, DEXs), deposits them in kind, redeems and sells | Spread between the index token's price and its value |
| Prover | Generates P1/P2 proofs with open-source software on commodity or rented GPUs | Whoever needs the proof |
| Rebalance executor | Delivers bought tokens first, collects sold tokens after | The auction's discount |
| Watcher | Recomputes every vault against the mirror and units; submits shortfall evidence | Public good; the team runs one, anyone else can |
| App | Publishes index value, suggests request limits, routes users | — |

## 5. Data model

### 5.1 Hub storage (per index)

| Field | Meaning |
|---|---|
| `components[i] = {chainId, tokenId, decimals}` and `units[i]` | Fixed contents; units change only in a settled rebalance |
| rebalance ratios `r[i]`, `λmax`, `λmin` | The band a started rebalance settles within (6.6) |
| `vaultOf[chainId]` | Copied at creation; immutable |
| `settled[c][t]`, `paid[c][t]`, `provenAt[c]` | Last proven vault state for this index |
| `burned[c][t]`, `burnNonce[c]` | Cumulative amounts burned toward chain `c`, and the next message nonce |
| `orders[id] = {minter, shares, deadline, status, escrow[], provenAt}` | Open, Settling, Claimable, Claimed, Failed |
| `mintWindow` | Shares made claimable in the current rolling 24 hours |
| `claims[t]` | v3 claims for skipped Tier 1 tokens |
| `frozen[c] = until` | Mints involving chain `c` stop while frozen |
| rebalance state | Ratios, λ range, times, executor, bond and its release time, deliveries, status |
| `recovery[holder]` | A contract holder's recovery address for a snapshot exit (6.9) |

### 5.2 Vault storage (per chain)

| Field | Meaning |
|---|---|
| `balance[index][t]` | Settled holdings |
| `pending[order][t]`, `depositor[order]` | Deposits locked to an open mint order |
| `paidTotal[index][t]`, `used[index][nonce]` | Payouts made; each message nonce usable once |
| `outflow[index][t]` | Rolling 24-hour outflow, for the speed limit |
| `cap[t]` | Quantity cap across all indexes |
| `verifierP1`, `verifierP2`, `guardianFreezer`, `frozenUntil` | Rotatable Ethereum verifiers, freeze-only address, freeze state |
| `snapshot` | The checkpoint of a snapshot exit, if one began; later burns are refused |

### 5.3 Cross-chain messages

| Message | Direction | Proof policy | Effect |
|---|---|---|---|
| `VaultState(index, h, settled[], paidTotal[], pending[order][])` | vault → Ethereum | the chain's system | Settles a mint order, confirms rebalance deliveries, refreshes the mirror |
| `Shortfall(index, h, ...)`, or a second `VaultState` for the same vault and `h` that contradicts one already used | vault → Ethereum | the chain's system | Proves a vault holds less than the hub requires, or that the system is unsound: voids the orders resting on it and freezes the chain's mints, in the same transaction |
| `Burn(index, c, nonce, t, amount, recipient)` | Ethereum → vault | P1 AND P2 | Pays a redeemer (or a rebalance executor) |
| `OrderSettled(order)` / `OrderFailed(order)` | Ethereum → vault | P1 AND P2 | Moves pending coins into the index / refunds the depositor |
| `RebalanceFailed(id)` | Ethereum → vault | P1 AND P2 | Refunds an executor's deliveries |
| `Migrate(old, new, t, amount)` | Ethereum → vault | P1 AND P2 | Moves coins two versions share from the old index's balance to the new one's (6.7) |
| `CapUpdate(t, cap)` | Ethereum → vault | raise: AND; lower: OR | Adjusts a quantity cap |
| `Freeze(c)` | Ethereum → vault | P1 OR P2 | Freezes the vault (also directly by the guardian freezer) |
| `GuardianFreezerChange`, `VerifierRotation` | Ethereum → vault | P1 AND P2 | Timelocked governance changes |

Every message carries the source chain, the destination chain, the vault and the index, so no proof can be replayed
elsewhere.

## 6. Flows

### 6.1 Setup (once)

1. Deploy the factory, hub template, verifiers, MintRequests and zap on Ethereum, all immutable.
2. Deploy one vault per chain with its settings fixed; remove any upgrade authority (Solana, Move chains).
3. Link each chain through `proposeChain`; anyone checks code hashes and settings during the delay.
4. List tokens with dated reference supplies and quantity caps. Listing policy adds a liquidity screen: daily volume at
   least 0.1% of market cap, re-measured over 30 days.

### 6.2 Creating an index

1. The creator picks listed tokens and `k`; the factory sets `units = ⌊k × supply / 10^36⌋`, copies vault addresses,
   deploys.
2. The first mint (6.3) seeds it; the creator opens the index token's Uniswap pool with those shares and USDC/USDT. The
   official pool (index token against USDC at a fixed fee tier) has a deterministic address, fixed at creation, which
   the snapshot exit's look-through claims rely on (6.9).

### 6.3 Minting (minters, in batches)

```
 minter            IndexHub (Ethereum)              vaults                     provers
   │ openOrder(N) ───► escrow Tier 1 tokens,
   │                   compute amounts, deadline
   │ buy anywhere, withdraw natively ─────────────► deposit(order) ──► pending[order]
   │                                                                    │ VaultState proof (the chain's system)
   │                   settleOrder(proofs) ◄────────────────────────────┘
   │                   check invariant (7.2), mint cap
   │                   status = Claimable at +24h ── OrderSettled ──► pending → balance
   │ claim() after 24h ◄── shares
   │ deadline missed:  failOrder() → escrow back ─── OrderFailed ───► refund to depositor
   │ shortfall or conflicting proof in the lock: order voided at once ── OrderFailed ──►
```

- The 24-hour lock lets watchers compare the proven deposits with the chains themselves. **Voiding is automatic:** a
  `Shortfall` proof, or a second proof of the same vault and height that contradicts the one the order rests on, fails
  the order in the same transaction that proves it, returns the Ethereum escrow and sends `OrderFailed`. No guardian or
  owner act is involved, so a forged deposit never becomes a transferable share.
- **A freeze holds an order until it is re-confirmed.** An order touching a chain that froze during its lock does not
  become claimable when the freeze ends. It needs a fresh `VaultState`, at a height after the freeze ended, showing its
  deposits still in place, so an expiring freeze never releases shares by itself.

### 6.4 How users get in and out

| Path | In | Out |
|---|---|---|
| Uniswap | Swap USDC/USDT for the index token | Swap back |
| Requests | `requestMint`, filled by a minter from stock | `requestRedeem`, filled by a minter |
| Zap (Ethereum-only indexes, ≤ ~35 tokens) | One transaction | One transaction |
| In kind | Minters only (6.3) | Anyone (6.5) |

### 6.5 In-kind redemption

1. `redeem(shares, recipients[], skipMask)` burns the shares, pays Tier 1 tokens at once, and for each chain not
   skipped emits `Burn` with the next nonce and adds the amount to `burned`.
2. After Ethereum finality, anyone proves the `Burn` to that chain's vault; the vault pays the recipient within the
   speed limit and marks the nonce used. Payouts above the limit wait and stay payable.
3. A skipped or frozen chain's `Burn` can be delivered at any later time; nothing expires.

### 6.6 Rebalancing

- **Price moves need nothing:** units are proportional to supplies, so prices cancel out of the weights, and a
  market-cap index never has to trade when prices move. It trades only when a reference supply changes, or when the list
  changes (a new version, 6.7).
- **Supply updates are weekly.** The owner Safe proposes one batch of reference supplies a week (4.1: atomic,
  timelocked, guardian veto, each within `MAX_SUPPLY_STEP` = 0.5% of the figure in force). Weekly updates follow a
  token whose supply grows up to 1.005^52 − 1 ≈ **30% a year** faster than the index's average; monthly updates would
  follow only about 6.7% a year, leaving tokens that unlock 10–40% a year persistently underweight.

**The auction, anchored to units.** Let `u_i` be a component's units, `f_i` its reference supply in force, and `M` the
components that move (all but those in the keep mask).

1. After `MIN_REBALANCE_INTERVAL` (7 days), anyone calls `startRebalance`. For each `i` in `M` it computes
   `ρ_i = u_i / f_i`, the units the index holds per unit of supply, and the centred ratio

   ```
   r_i = clamp( 2·ρ_i / (ρmin + ρmax),  1 − STEP,  1 + STEP )        λmax = max r,  λmin = min r
   ```

   and stores them. If every ρ is equal, units are already proportional to supplies and there is nothing to do: a band
   narrower than `MIN_BAND` (0.1%) is refused, which covers no change, a uniform change and a single moving component.
2. After `REBALANCE_DELAY` (2 days) of notice, λ falls linearly from `λmax` to `λmin` over `AUCTION_DURATION` (24h). A
   fill at λ sets every moving component's units to `u'_i = ⌈λ · u_i / r_i⌉`; kept components keep theirs. A
   component whose `r_i` is above λ is sold, one below is bought. A fill that would send nothing out settles at `λmax`,
   so the units never depend on timing when nothing is paid for.
3. **Ethereum-only indexes** settle atomically with v3's callback (`executeRebalance`): the executor receives the sold
   tokens, delivers the bought ones inside the call, and the backing check runs after it returns. Amounts are
   each leg's change in backing, rounded down when it leaves and up when it comes back (SA-07), so they come only
   from supply and units.
4. **Indexes with vault tokens:** an executor calls `accept()` at the current λ and posts a bond in index shares
   (0.1% of supply). It delivers every bought token first: Tier 1 tokens in the same transaction, other chains'
   tokens as vault deposits under the rebalance id within `DELIVERY_WINDOW`. `settle(proofs)` checks the deliveries
   against fresh `VaultState` proofs, writes the new units, pays sold Tier 1 tokens to the executor and emits `Burn`
   messages to it for sold tokens on other chains. The bond is **held 24 hours after settlement** and burned if a
   `Shortfall` or conflicting proof shows a delivery was forged. A missed delivery window fails the rebalance: the bond
   is burned (raising every remaining share's backing), the deliveries are refunded by `RebalanceFailed`, and the
   auction may restart.

**Why no price is needed.** At any prices `p`, the value-neutral λ, the one that leaves the index's value unchanged, is

```
λ* = Σ u_i p_i / Σ (u_i / r_i) p_i
```

a weighted average of the stored `r_i` with non-negative weights `(u_i/r_i)·p_i`. So `λmin ≤ λ* ≤ λmax` at every
price vector, whatever the rounding of the stored ratios, and a fill at λ leaves holders `λ/λ* ≥ λmin/λmax` of the
moving value. Rounding units up only adds to that.

**Worst cases, stated plainly.**

| Quantity | Bound |
|---|---|
| Loss per rebalance to a lone executor who waits for the floor | `1 − λmin/λmax ≤ 1 − (1 − STEP)/(1 + STEP)` = **0.995%** |
| Per day, weekly cadence (a cycle takes at least 9 days: 7 between fills, 2 of notice) | ≈ **0.11%** |
| Per year, if every cycle's supplies moved the full step apart and no executor ever competed | ≈ **33%** (monthly: ≈ 11%) |
| Units per rebalance | `u'/u` within [0.990, 1.010], plus one raw unit of rounding |

Competition between executors settles near λ*; the last two rows describe an auction nobody but one executor
watches. The band applies to the **whole moving value, however small the trade**: a 0.5% revision of a token weighing
1% trades about 0.005% of the index, yet a lone executor at the floor can take up to about 0.5%. This is inherent to any
price-free scalar auction, which cannot tell a small trade from a large one without prices. The guardian's cancel and
the keep mask are the recourse against a rebalance nobody competes for.

**Why the clamp is centred, and why units anchor.** Unclamped, `u_i / r_i = f_i · (ρmin + ρmax)/2`, so a full fill
makes units exactly proportional to supplies again: any skew a keep mask left, any clamping residue and any rounding
drift is corrected at the next rebalance, one step at a time, instead of accumulating. The clamp is taken around the
centre of the ratios, so it narrows a wide band to exactly `[1 − STEP, 1 + STEP]` and never collapses one: a snapshot
cannot stall because the factory's figures ran ahead of the index. Two bounds together hold the worst case, and
neither alone would: the factory's step per supply update stops a slip at proposal time, and the hub's clamp per
rebalance bounds the band however many updates landed between two rebalances.

**Why not the first draft's formula.** The draft set `u' = λ·k·s'` with the band taken from old and new supplies
`s/s'`. After any keep-mask fill, units no longer equal `k·s`, so λ* could fall outside that band and a fill at the
open would overpay the executor, and keep-mask skew and rounding drift would compound forever. The units-anchored form
has neither problem.

### 6.7 Changes of membership: versions

A new top-100 list is a new index created by the factory (for example quarterly). Two buffers keep membership from
churning:

- **Rank buffer:** a coin enters a new version only if it ranks 80th or better, and a held coin leaves only if it
  falls below 120th.
- **Floor buffer (adopted by the owner on 2026-09-30):** a coin joins at a weight of 0.2% or more and leaves only below
  0.1%.
  The 0.2% floor sits near rank 32, so the rank buffer alone would never bind, and AVAX and HBAR (0.21% each) would
  flip in and out with each version.

**In-place migration.** A holder or minter migrates by burning old-version shares into the new version in one Ethereum
transaction: the old hub burns them and sends `Migrate(old, new, t, amount)` for each vault token the two versions
share, the new hub mints against those coins plus fresh deposits for the tokens only the new version holds, and each
vault moves the shared coins from the old index's balance to the new one's without them leaving the vault. Only the
differences between the two versions trade. `Migrate` moves coins between indexes, so it needs P1 and P2. The old
version stays fully backed and redeemable for everyone who does not migrate.

### 6.8 Freeze

- **Triggers:** the guardian's freezer address on the vault chain; a `Freeze` message proven by either Ethereum-side
  system; a `Shortfall` proof or a conflicting vault-state proof on Ethereum, which freezes the chain's mints
  automatically and emits `Freeze`.
- **Effect:** the vault stops payouts and new order deposits; the hub stops mints involving that chain; redemption
  continues with that chain skipped, its `Burn` messages kept for later.
- **End:** automatically after `FREEZE_DURATION`. An order that touched the chain stays unclaimable until a fresh
  `VaultState` from after the freeze re-confirms its deposits (6.3). A hostile guardian can re-freeze (delay, not loss)
  until the owner replaces it after `GUARDIAN_DELAY`, as in v3.

### 6.9 Surviving Ethereum upgrades

After a format change nobody anticipated, no fixed code can know the new rules: something has to supply them. The
design therefore prevents the break in the normal case, makes whoever supplies new rules powerless except in a real
emergency, constrains them with validator signatures even then, and guarantees coins are never stuck for good.

**Layer 1: prevention (scheduled upgrades).**
1. Verifiers are **fork-aware**: each supports the current fork and the next one, selected by the fork version that
   Ethereum's validators sign into every block, so no fork date is hard-coded.
2. The owner Safe rotates in the next pair (`ROTATION_DELAY`, 30 days, guardian may cancel, holders who object redeem)
   at least `ROTATION_LEAD` (90 days) before a scheduled upgrade, built from the upgrade's public specification. The
   executed rotation is sent as `VerifierRotation`, proven by the current verifiers (P1 and P2).
3. The lead time covers a hostile guardian: a veto, the owner replacing the guardian (`GUARDIAN_DELAY`, 7 days) and a
   second 30-day rotation all fit inside it.

**Layer 2: fail closed.** A verifier that meets a format it does not know refuses the proof. An unknown fork can stop
payouts; it can never make a vault pay the wrong person.

**Layer 3: stall-gated recovery (the unscheduled case).**
1. **Stall.** A vault enters stall mode when it has accepted no new finalized Ethereum checkpoint for `STALL_PERIOD`
   (7 days). While Ethereum's formats are unchanged anyone can keep a vault's checkpoints current, so nobody (the owner
   included) can manufacture a stall.
2. **Proposal.** Only in stall mode, the owner's emergency multisig on that chain (the owner Safe's own signers, same
   threshold) may propose a successor verifier pair. Outside stall mode this multisig can do nothing.
3. **Continuity test, on the vault's chain.** The successor is accepted for review only if it (a) verifies the last
   checkpoint the old verifiers accepted, (b) proves a chain of finalized checkpoints from there to a recent one, each
   signed by at least two thirds of the stake of the validator set known at that checkpoint, with Ethereum's churn
   limits applied to every change of that set, and (c) re-verifies a sample of messages the old verifiers accepted.
   Validator keys and signatures do not change with data formats, so a successor cannot invent blocks; the only freedom
   left to a malicious one is misreading formats under genuinely signed roots.
4. **Review.** `RECOVERY_DELAY` (30 days) of public review, during which anyone can check the successor against
   Ethereum's published specification. The guardian's freezer may veto at most `MAX_RECOVERY_VETOES` (2) times per stall,
   so a hostile guardian cannot keep a vault stuck, and the owner cannot be overruled forever.
5. **Resume.** Once adopted, every `Burn` issued during the stall becomes deliverable. Worst case without vetoes:
   7 + 30 = **37 days** of delay; with two vetoes, 97 days. No coins are lost.

**Layer 4: last resort, snapshot exit.** If no successor has been adopted `SNAPSHOT_EXIT_DELAY` (180 days) after the
stall began, the vault pays each index's balance to the holders recorded at the last checkpoint it verified:

- An externally owned account claims by signing with its Ethereum key.
- A contract (a Safe, a vault) claims through a recovery address it registered in the hub in advance.
- **Liquidity providers of the index's official Uniswap pool claim through the pool** (look-through): the pool cannot
  register anything, so each LP proves its position at the snapshot checkpoint, and is paid its position's share of
  the index tokens the pool held there. The official pool is the one the creator opened (6.2), recorded in the hub.
- **The vault refuses every `Burn` issued after the snapshot checkpoint**, permanently, so no coin is claimed both by a
  snapshot holder and by someone who redeemed later. Burns issued at or before the checkpoint stay payable, because
  their shares are no longer in the snapshot.

The hub, learning of the snapshot exit through the vault's own state proof, detaches that chain's tokens from the index
so later buyers are not charged for them. Holders who never registered a recovery address for a contract lose that
chain's part, which is why the app prompts every contract holder to register one.

### 6.10 Surviving vault-chain upgrades

The 22 candidate chains, and the 9 of the floor list, fork on their own schedules; BNB Chain and Solana upgrade several
times a year, and Solana has adopted Alpenglow, which replaces its consensus. The same prevention applies as on
Ethereum, in the other direction:

1. **Fork-aware state verifiers.** The Ethereum-side verifier of each chain accepts the chain's current and next
   announced consensus and state formats, selected by the version the chain's validators sign, not by a date.
2. **Rotated ahead through the listing timelock.** The owner proposes the next state verifier as soon as an upgrade's
   specification is public; it executes after `LISTING_DELAY` (2 days) unless the guardian cancels. A chain's upgrade
   lead time is weeks or months, so a veto and a second proposal fit inside it.
3. **Solana's proof is built for Alpenglow** (its finalization certificates), not for the vote transactions it
   replaces, so Solana's move to Alpenglow is not a rotation.
4. **Fail closed.** A state verifier that meets an unknown format refuses the proof. That stops only mints, rebalance
   deliveries and shortfall evidence involving the chain; burns still reach the vault through the Ethereum-side proofs,
   so no coin is stuck.

**A new risk: a chain upgrade breaks the vault program itself.** A vault is immutable, so a runtime change that stops it
executing (a removed syscall, an opcode's changed cost or meaning, a retired program loader) would freeze that chain's
coins until the chain restores compatibility. The worst case is the chain's whole weight: BNB 4.4%, SOL 3.1%, TRX 1.4%,
HYPE 0.85% of the index. Defenses:

- prefer chains whose upgrades keep deployed programs working, and treat a history of breaking them as a listing
  criterion;
- build vaults from long-stable features only (no deprecated syscalls or opcodes, no reliance on gas or compute
  costs);
- run every vault's test suite against each chain's release candidates and testnets before activation, and watch each
  chain's release calendar (9.4).

## 7. Accounting and invariants

### 7.1 Tier 1 (as v3)

`balanceOf(hub, t) ≥ floor(S × u_t / 1e18) + claims_t` for every Tier 1 token, checked on every mint, redeem and
settlement.

### 7.2 Vault tokens

For every token `t` on chain `c`, with `S` the total supply after the operation:

```
settled[c][t] − (burned[c][t] − paid[c][t])  ≥  floor(S × u_t / 1e18)
```

- Checked at every mint settlement against a fresh `VaultState`, so the mirror is re-anchored to proven state each
  time; a replayed or duplicated deposit cannot inflate it.
- Preserved without proofs in between: a burn lowers required backing by exactly what it adds to `burned`; a vault
  payout lowers `settled` and raises `paid` by the same amount.

### 7.3 Further invariants

| # | Invariant | Enforced by |
|---|---|---|
| I3 | A vault pays a message at most once, and never more than its balance for that index | Vault |
| I4 | Every order ends Settled-and-Claimed or Failed exactly once; every deposit counts for exactly one order | Hub, vault |
| I5 | Per rolling 24h: outflow of each index's token ≤ `SPEED_LIMIT` (4%) × its balance at the window's start | Vault |
| I6 | Per rolling 24h: shares made claimable ≤ `MINT_CAP` (4%) × supply (the seed mint is exempt up to its launch cap) | Hub |
| I9 | A rebalance fill leaves holders at least `λmin/λmax` of the moving value, and `λmax/λmin ≤ (1+STEP)/(1−STEP)` | Hub |
| I7 | No amount in any money path depends on a price | Code review, tests |
| I8 | An index's vault addresses never change | Factory, hub |

## 8. Security model

### 8.1 Every failure and its bound

Figures are for the full floor list (vault share 11.3% of the index, largest vault BNB at 4.4%) with the 4% daily speed
limit and mint cap. The Ethereum-side proofs are shared by every chain, so a failure there hits every vault at once:
that is why the daily limits are 4% and not 5% and 10%, which would give 0.56% and 1.1% a day below.

| Failure | Defense | Worst case |
|---|---|---|
| One Ethereum-side proof system broken | Coins leave a vault only on P1 and P2 | Nothing moves |
| Both Ethereum-side systems broken (double failure): forged burns on every vault at once | Speed limit, watchers, freeze | 11.3% × 4% ≈ **0.45% per day** |
| A chain's deposit proof broken: forged deposit | A mint needs every token and Tier 1 is checked in real balances, so the forger pays for the rest of the basket and gains only the forged chains' weight; any honest proof of the same vault and height contradicts it; 24h lock; mint cap | Caught in the lock: **0**. Undetected (double failure: the proof and every watcher for 24 hours): one chain 4.4% × 4% ≈ **0.18% per day**; every chain on one proving stack 11.2% × 4% ≈ **0.45% per day** |
| A chain's deposit proof broken: forged rebalance delivery | Bought legs are bounded by the band; bond held 24h and burned on proven shortfall | ≤ 1.0% × 11.3% ≈ **0.11% per rebalance**, most of it covered by the 0.1% bond |
| Sync-committee fallback (only if adopted, 4.4): the committee signs a false header | Challenge delay, lower caps | Challenged in the delay: **0**. Unchallenged: **0.45% per day** (a single failure) |
| Lone executor at the auction's floor | Competition; guardian cancel | **0.995% per rebalance**, ≈ 0.11% per day at the weekly cadence (6.6) |
| A vault chain's validators corrupted | Quantity caps below the lower of the economic and the concentration cap (8.2) | Unprofitable by construction; concentration capped separately |
| A vault-chain upgrade breaks its state verifier | Fork-aware verifiers rotated ahead through the listing timelock; fail closed (6.10) | Delay of mints on that chain |
| A vault-chain upgrade breaks the vault program | Chains that keep deployed programs working; long-stable features; tests against release candidates (6.10) | That chain's weight frozen until the chain restores compatibility: at most **4.4%** (BNB) |
| Replay, look-alike contracts, misparsed transactions | Nonces and used-marks, domain separation, exact identities, parsing inside the proof, formal verification | Code-level |
| Owner Safe compromised | Timelocks, guardian veto, fixed vault addresses; Ethereum-verifier rotation takes 30 days in public | **0** immediately; holders exit within 30 days |
| Owner Safe and guardian both compromised (double failure) | A state verifier rotated through the 2-day timelock without a veto could accept forged deposits and refuse shortfall evidence; watchers still alert holders | Forged mints bounded by the mint cap: ≤ 11.2% × 4% ≈ **0.45% per day** after 2 days |
| Guardian compromised | Freeze only, expiring; owner replaces it | Delay |
| Ethereum upgrade breaks proofs | Fork-aware verifiers rotated 90 days ahead; fail closed; stall-gated recovery with a continuity test; snapshot exit (6.9) | Scheduled: nothing. Unscheduled: 37–97 days of delay on that chain; 180 days at most before holders are paid directly |
| Provers disappear | Open-source prover anyone can run | Delay |
| A chain halts | Skip it; claims never expire | Delay |
| Liquidity disappears | In-kind exit always available | Discount on the index token, not loss |
| **WBTC custodian fails or freezes** | Accepted exception (8.3) | **73.5–82.9%** (floor list, stages C to A) |

### 8.2 Cost-to-corrupt caps

For each vault chain, set its quantity caps so that, at any price the owner reasonably expects over the cap's life,

```
value held in that chain's vault (all indexes)  ≤  α × cost of corrupting that chain's finality
```

with `α` well below one (for example 0.1). That bound assumes an economically motivated attacker. Where a few known
entities can finalize a block on their own, coercion or insider risk is not reflected in stake, so each chain also has
a **validator-concentration cap**, set from the smallest number of entities that together hold two thirds of its
finality weight and re-measured at each review. A chain's cap is the lower of the two; the concentration cap is the
lower one for BNB Chain, Tron and HyperEVM, whose validator sets are small and concentrated. Caps are quantities, so
the contracts need no price; the owner re-derives them at the supply reviews, and lowering a cap is a protective
message that either proof system can carry.

### 8.3 The Bitcoin exception

WBTC holds Bitcoin's 65.8% of the market as 70.7–80.6% of the index, behind one custodian. The owner accepted this on
2026-09-29 ("WBTC only for now"). The measured options for later:

| Bitcoin weight cap | Tracking error/yr | Loss if one custodian fails: WBTC only | WBTC/tBTC split |
|---|---|---|---|
| none | 2.0% | 70.7% | 35.4% |
| 60% | 2.5% | 60% | 30% |
| 50% | 4.1% | 50% | 25% |
| 40% | 6.0% | 40% | 20% |

The only way to bring Bitcoin inside N1 is a Bitcoin vault on a pre-signed transaction tree, where one honest signer out
of n keeps the coins safe.

### 8.4 Trust assumptions, complete

Ethereum's consensus (full finality); each vault chain's consensus, bounded by 8.2; at least one of P1 and P2 sound for
coins in vaults to be safe; for mints, each chain's deposit proof sound or one watcher live within 24 hours; the proof
systems' setup; WBTC's custodian; token issuers' own admin powers (labelled in the app);
the owner Safe for listings, caps, supplies and rotation; the guardian for freezes.

### 8.5 Keys

| Key | Holder | Power |
|---|---|---|
| Owner | Safe, 3-of-5 hardware wallets, separate people, no modules | Timelocked governance, including 30-day rotation |
| Owner emergency multisig | The owner Safe's signers, one multisig per vault chain | Nothing, unless that vault has stalled for 7 days; then only propose a successor verifier that must pass the continuity test and 30 days of review |
| Guardian | Separate signers from the owner; one freezer address per vault chain | Veto, cancel, freeze |
| Deployer | Hardware wallet or encrypted keystore | None after deployment |
| Everyone else | Gas wallets | None |

No custody provider is needed.

## 9. Scale and reliability

### 9.1 Gas (estimates to confirm with prototypes)

| Operation | Main costs |
|---|---|
| `settleOrder` | One proof verification per vault chain in the order (about 0.3–0.5M gas each) + about 50k per Tier 1 token |
| `redeem` | About 50k per Tier 1 token + about 30k per chain's `Burn` |
| `createIndex` | One clone; about 49k per component with every account cold (4.9M at 100, measured) |
| `executeRebalance` (Ethereum-only) | Inside EIP-7825's 16.78M cap at 100 components only for an executor that already holds the bought tokens; swapping inside the call (about 150k per leg) fits about 100 legs at most |
| Zap (Ethereum-only) | 265k–430k per token, which is why the app stops it near 35 tokens |

Measured since (2026-10-01, Stage B spec 5.1 and 5.7), a state proof costs more than the `settleOrder` row assumes:
about 820k gas for two storage slots of BNB Chain, and about 568k for one slot of Tron.

### 9.2 Latency

| Operation | Time |
|---|---|
| Mint | Sourcing + chain finality + proving, inside a 2h deadline; claimable 24h after settlement |
| In-kind redemption | Ethereum finality (~13 min) + proving: about 15–30 min per chain |
| Rebalance | 2-day notice + up to 24h auction + delivery window |

### 9.3 Liquidity

Daily net minting or redeeming at participation rate `p` is bounded by the least-traded token relative to its size:

```
capacity = p × (basket market cap) × min over tokens of (daily volume / market cap)
```

On 2026-09-29 at `p` = 1%, holding all 54 tokens: $1.3–1.5M per day, set by LEO ($0.5M daily volume on $8.3B) and then
WBTC ($201M daily against Bitcoin's $23.8B). With LEO removed by the liquidity screen and minters able to wrap native
Bitcoin, the bound rises to about $19M per day (M), then about $48M (GT).

**Under the 0.2% floor** the thin tail is gone: with LEO screened out, the least-traded token is BNB (0.70% of its
market cap a day), which sets the bound at about **$160M per day**, or $2.75M if minters use only WBTC's own volume.
WBTC on Uniswap V3 cost 0.4% extra at $1M and 4.1% at $10M.

### 9.4 Liveness and monitoring

- Proving is permissionless and open source; any holder can prove their own `Burn`.
- A halted chain affects only that chain's leg.
- Watchers check every block: vault state against the mirror, paid totals against burns, unit invariants, and the
  upgrade calendars of Ethereum and every vault chain. Provable problems go on-chain as `Shortfall` or a conflicting
  proof; others alert the guardian.
- Launch is guarded: low quantity caps and per-index value limits that rise over months.

## 10. Index valuation (off-chain)

`value per share = Σ units_i × price_i`. Units come from the hub; prices are the median of several exchanges and
aggregators (Chainlink where it exists), dropping sources more than ~2% from the rest, pricing exactly the asset held
(WBTC at WBTC's own market price, with Bitcoin's shown beside it as a warning light), marking any price older than ~10
minutes as estimated. A live value every ~15 seconds and an official value at 00:00 UTC; payouts still owed are
excluded. The method and code are public; nothing on-chain depends on this value.

## 11. Trade-offs and rejected alternatives

| Choice | Rejected alternative | Why |
|---|---|---|
| Ownerless proof vaults | Bonded operator multisigs | Operators can sign away coins; bounded only by bonds and speed limits |
| Hold only what can be held | Residual swap tracking the rest | Tracks rather than holds; oracle-sized payments |
| WBTC for Bitcoin (for now) | THORChain | Pools ~$70M in total, security bond ~$43M, Bitcoin halted when checked, positions half RUNE |
| One vault per chain | One vault per index | Fewer deployments and audits; per-index balances inside keep indexes separate |
| Balance proofs for the mirror | Adding up deposit events | A replayed or missed event cannot drift the books |
| Price-free units and λ bounds | Chainlink or DEX prices | No manipulation surface; most tokens have no feed |
| Minters and requests | The protocol bridging USDT and swapping on each chain | No bridge, no keeper, no multi-chain price risk for users |
| Versions for membership | Constituent changes by auction | No price needed; holders choose when to move |
| Two proof systems where coins leave a vault, one for deposits | Two everywhere | Deposits are contained by the lock, the mint cap and conflicting-proof evidence; halves the proving systems (Stage B: 6 instead of about 10) |
| Two Ethereum-side systems | One | A single circuit or verifier bug would otherwise be total |
| A 0.2% weight floor | Every holdable top-100 token | 0.6 points of tracking error buys 22 → 9 vault chains, 54 → 15 tokens and cheaper minting |
| Weekly supply updates | Monthly | Follows supply growth up to 30% a year instead of 6.7%; the per-rebalance bound is unchanged |
| Units-anchored λ with a centred clamp | Old and new supply ratios (the first draft) | Stays value-bounded after keep masks, heals drift, cannot stall |

## 12. Parameters (initial values, to tune)

| Parameter | Value |
|---|---|
| `MAX_COMPONENTS` | 100 |
| `MIN_RAW_UNITS`, `MAX_UNITS` | 10,000; (2^96 − 1) / 2^10 |
| Weight floor (flagship policy) | Join at 0.2%; leave below 0.1% (adopted) |
| Membership buffer (policy) | Enter at rank ≤ 80; leave below rank 120 |
| `ORDER_DEADLINE` | 2 hours (max 6) |
| `MINT_LOCK` | 24 hours |
| `MINT_CAP` | 4% of supply per rolling 24h |
| `SPEED_LIMIT` | 4% of an index's vault balance per token per rolling 24h |
| `FREEZE_DURATION` | 14 days |
| `ROTATION_DELAY`, `ROTATION_LEAD` | 30 days, 90 days before a scheduled upgrade |
| `STALL_PERIOD`, `RECOVERY_DELAY`, `MAX_RECOVERY_VETOES` | 7 days, 30 days, 2 per stall |
| `SNAPSHOT_EXIT_DELAY` | 180 days after a stall began |
| `LISTING_DELAY`, `PROPOSAL_WINDOW`, `GUARDIAN_DELAY` | 2 days, 7 days, 7 days (as v3) |
| `MAX_SUPPLY_STEP` | 0.5% per token per supply update (factory) and per rebalance (hub clamp) |
| `MIN_BAND` | 0.1% (`λmax/λmin − 1` below it: nothing to rebalance) |
| `MIN_REBALANCE_INTERVAL`, `REBALANCE_DELAY`, `AUCTION_DURATION`, `DELIVERY_WINDOW` | 7 days, 2 days, 24 hours, 6 hours |
| Rebalance bond | 0.1% of supply, in index shares; held 24 hours after settlement |
| `CHALLENGE_DELAY` | Only under the sync-committee fallback (4.4); set from the prototype |
| Quantity caps | Per token, from 8.2; low at launch |
| Liquidity screen (policy) | Daily volume ≥ 0.1% of market cap over 30 days |

## 13. Changes to recorded decisions (AGENTS.md)

| Recorded decision | Change |
|---|---|
| Components on Ethereum mainnet only | Tier 2 coins live in vaults on their own chains |
| Prices from Chainlink USD feeds | No prices in money paths; units from supplies |
| `MAX_COMPONENTS = 20` | 100 |
| No pause | Guardian freeze, expiring (owner decision 2026-09-29) |
| No upgrade | 30-day verifier rotation (owner decision 2026-09-29) |
| One-click mint and burn for every index | One-click only for Ethereum-only indexes up to about 35 tokens |
| Capped 30/20 methodology | Retired: it trades on every price move and needs every price, so a price-free index cannot offer it |
| Owner Safe of at least 2 signatures | 3-of-5 hardware wallets, because rotation reaches existing funds after 30 days |
| Monthly rebalancing cadence | Weekly supply updates, 7-day interval (owner decision 2026-09-30) |
| The seven-token launch whitelist (WETH, wstETH, WBTC, wSOL, UNI, LINK, AAVE) | The floor list's Ethereum tokens after the screen: WBTC, WETH, LINK, UNI, and WBT subject to its check (it stays off, 2.1); native SOL arrives with Stage B |
| v3 as the product | v4 replaces v3, which stays at tag `v3.0.0` and on Sepolia (owner decision 2026-09-30) |
| No fees | Kept for Stage A, funded from outside (13.1) |

### 13.1 Funding: no fee in Stage A

v3 decided on no fees, because minters earn spreads and executors earn auction discounts. v4 needs things that nobody
is paid for:

- two independent audits per component, plus ZK-specialist audits of every proof system;
- a bug bounty sized to the largest vault: 4.4% of the index, **$4.4M at $100M** in the index;
- watchers run continuously on every chain, and the provers' reference deployment.

Three models, each price-free and in kind:

| Model | How | Revenue at $100M | Who pays | Cost to holders |
|---|---|---|---|---|
| **Minter fee** | e.g. 5 bp on each in-kind mint and redemption, paid in index shares to a fixed treasury address (the minter delivers the basket for N shares and receives N − fee) | ≈ $100k/yr if the index turns over twice a year | Minters, who pass it into the Uniswap spread (about 5 bp wider) | 0 directly for holders who never mint or redeem |
| **Management fee** | e.g. 0.10% a year, streamed through a unit scale that shrinks over time; the released backing is paid to the treasury | ≈ $100k/yr, however much is minted | Every holder | 0.10% a year |
| **No fee** | The team or grants fund audits, the bounty and watchers | — | Outside funders | 0 |

In each case the treasury is an address fixed at creation that can receive shares or released backing and do nothing
else, so no fee model gives anyone power over index coins. Stage A's hub computes every backing amount in one place, so
either fee model lands in one reviewed change. **The owner's decision of 2026-09-30: no fee in Stage A**. Audits, the
bounty and watchers are funded from outside, and a fee, if one comes, arrives with a later index version, so the
Stage A audit reviews no fee code.

## 14. Build stages and verification

| Stage | Build | Needs no |
|---|---|---|
| A | Price-free factory and hub, supply batches, MintRequests, the λ auction (atomic), zap limit; holds WBTC, WETH, LINK, UNI | Vaults, proofs, mirror, freeze |
| Prototype | A full-finality Ethereum proof verified on BNB Chain and on Solana, and a BNB Chain state proof verified on Ethereum, with measured cost and latency; decides Stage B, or the sync-committee fallback | — |
| B | EVM vault (BNB Chain, HyperEVM, Tron), Solana vault, P1/P2 Ethereum verifiers on each, one state verifier per chain on Ethereum, mirror, orders, limits, freeze, migration, rotation, snapshot exit, watchers; BNB Chain end to end first | — |
| C | Avalanche, NEAR, Stellar, Hedera, Cardano, one at a time, each only if its finality is deterministic, its proof cost is measured, its cap matters and its value pays for its vault, verifiers and audits (all of Stage C adds 1.3 points of coverage and 0.5 of tracking error) | — |

**Status, 2026-10-01.** The stages are build order only: v4 launches as one product, on `HybridIndexFactory`, once the
hybrid index is ready, and Stage A does not launch on its own (the owner's call on 2026-10-01). On `main`, deployed
nowhere:
- **A** is built and internally reviewed (`audit/2026-09-30-stage-a-red-team.md`).
- **The prototype** has measured verification, which passes, and P1's prover gas on mainnet data; the cost and latency
  thresholds wait on the owner's GPU run (`design/2026-09-30-proving-prototype.md`).
- **B** is built in code for BNB Chain and Tron in both directions, with P1 and P2 on EVM vault chains. Solana has its
  vault and P1, but not P2 or a state verifier on Ethereum, which waits on Alpenglow's mainnet launch. HyperEVM is
  blocked: its headers carry no state root. Watchers and the testnet period are not done (Stage B spec, sections 6
  and 8).
- **C** is researched only (`design/2026-10-01-stage-c-research.md`).

Verification, per component: formal proofs of sections 7.2–7.3; 100% coverage and invariant fuzzing as v3 requires;
differential tests running P1 and P2 on the same real chain data; parser fuzzing against recorded transactions; fork
tests on every chain; a testnet period; two independent audits; a bug bounty sized to the largest vault; regression
tests named after each finding id, as gate 6 of AGENTS.md requires.

## 15. Open questions and what to revisit

- **Unscheduled Ethereum proof-format break:** solved as a delay rather than a loss by section 6.9's four layers. What
  remains open is engineering: proving a chain of full-finality checkpoints for the continuity test at acceptable cost
  on each vault chain, and a change of Ethereum's signature scheme itself (a post-quantum migration), which would defeat
  the continuity test's anchor and must be handled by Layer 1 well in advance. (2026-10-01: the vault's side of the
  stall recovery and the snapshot exit is built; a successor's proof of descent is not, Stage B spec 5.6.)
- **Bitcoin:** add tBTC and a weight cap (8.3), then a Bitcoin vault; tBTC's supply (4,177 BTC on 2026-09-29) limits
  how large a split index can grow.
- **Proving costs and times** per chain, and whether one aggregated proof per mint is practical for the 9 floor
  chains. (2026-10-01: P1 runs to 36.6 billion prover gas on mainnet data, measured in execute mode; its price and time
  wait on the owner's GPU run, `design/2026-09-30-proving-prototype.md`. BNB Chain's and Tron's state proofs need no
  prover, 9.1.)
- **The sync-committee fallback's parameters** (`CHALLENGE_DELAY`, the lower caps), if the prototype shows
  full-finality proofs are impractical.
- **Cost to corrupt** each vault chain, and its validator concentration, to set 8.2's caps; chains without
  deterministic finality stay out (Ethereum Classic is excluded). **Cardano's Ouroboros finality is probabilistic**, so
  it fails this rule as written; its Stage C gate decides whether it stays on the list. Hedera's permissioned council
  and its state-proof support get the same check. (Researched on 2026-10-01, `design/2026-10-01-stage-c-research.md`:
  Cardano fails the rule as written, Peras included; Hedera's finality passes, but its block proofs are switched off on
  mainnet until about November 2026, and its council is a trust the owner has to accept; Avalanche's probabilistic
  safety needs the owner's reading of the rule too. Those decisions are the owner's and not yet made.)
- **Real supply histories:** re-run the backtest with each token's supply over time, since constant supplies
  understate tracking error (2.1). CoinGecko's API was blocked on 2026-09-29; another source is needed.
- **A tighter auction:** the λ band exposes the whole moving value however small the trade (6.6); whether a price-free
  design can bound the exposure by the trade's size.
- **Small indexes and the speed limit:** a floor so a 4% limit does not block small redemptions. (Decided on
  2026-09-30: a quantity floor per token, set with its cap by `CAP_UPDATE`, below which a day's payouts are always
  allowed; the owner adopted it as proposal 5 of the Stage B spec, and the vault enforces it.)
- **On-chain value** for other protocols, if lending markets want the index as collateral: a time-weighted average of
  the index token's own Uniswap price, never a posted price.
- **Issuer tokens** (WBT, LEO, OKB, BGB, GT, KCS, WLFI): which ones can freeze or mint, and whether GT, KCS and ARB are
  canonical on Ethereum or belong in a vault on their home chain.
- **Regulation:** whether any market the product serves expects a named custodian.
