# Every top-100 coin with a contract on Ethereum or BNB Chain: design (5 October 2026)

The owner asked for a design that brings into Xindex every top-100 coin with a contract on Ethereum or BNB Chain. Of
CoinMarketCap's top 100 on 5 October 2026, less 14 stablecoins and gold tokens and 7 memecoins (the owner's call on 4
October), that is 43 coins:

| Class | Coins | Share of the universe | Which |
|---|---|---|---|
| Issued on Ethereum | 22 | 1.53% | LEO, QNT, AAVE, OKB, ENA, ONDO, SKY, WLD, MNT, WLFI, MORPHO, BGB, POL, GT, LIT, ETHFI, FET, CRV, NEXO, VIRTUAL, STRK, PENDLE |
| A bridged copy on Ethereum | 7 | 0.52% | TON (as GRAM), CRO, ICP, ARB, RENDER, CAKE, ZRO |
| On BNB Chain only | 14 | 9.18% | XRP, SOL, ZEC, DOGE, ADA, BCH, LTC, AVAX, DOT and FIL as Binance-Peg tokens; ASTER, ATOM, NIGHT and STABLE as BNB Chain tokens |

The universe is the top 100 less stablecoins and memecoins: 79 coins, $2,604B, so the 0.2% floor is $5.21B. Xindex
covers 86.26% of it today (BTC as WBTC, ETH, LINK and UNI listed; BNB, TRX, XLM, NEAR, SUI, INJ, VET and APT through
vaults). The 43 would take it to 97.50%. Eight of them clear the floor: XRP 3.68%, SOL 2.76%, ZEC 0.88%, DOGE 0.58%,
ADA 0.36%, LEO 0.32% (which fails the liquidity screen), BCH 0.25% and LTC 0.21%.

Sources: CoinMarketCap's listing for the ranks and caps; CoinGecko's coin list for every chain's contract, where
Binance-Peg tokens are separate coins; read-only calls on Ethereum and BNB Chain for the contracts checked below.

## Summary

- **Ethereum's 29 need no contract change.** Each is a Stage A listing: the owner's Safe proposes it with a dated
  reference supply, and anyone executes it two days later. What they need is an admission check per token, written once
  as a script, because listing is the whole of the vetting.
- **BNB Chain's 14 need one contract change:** `XindexVault` takes and pays tokens, not only the native coin. Its
  storage, speed limit, caps and payouts are already per token; four code paths assume the native coin. The hub, the
  factory and `BnbStateVerifier` do not change.
- **Most of the value is a trust decision, not code.** The coins worth most in the BNB class (XRP, SOL, DOGE, ADA, ZEC,
  BCH, LTC) are Binance-Peg tokens: Binance holds the coins, and one key mints the tokens, with nothing on chain tying
  new tokens to reserves. The design therefore adds **trust tiers**, shown with every listing, so each index's creator
  chooses what it holds and the flagship keeps a stated policy.
- **Effort.** The listing check: a few days. The vault change: one to two weeks, then an external audit before mainnet,
  as every vault already needs.

## 1. Trust tiers

Every listed token carries one of three tiers, written in the listing's record and shown by the app beside every index
that holds it.

| Tier | What backs it | Who can break it | Examples |
|---|---|---|---|
| **Native** | The coin itself: issued on Ethereum, or a vault chain's native coin proven by that chain's consensus | The issuer's own contract rules (mint, pause, blacklist, upgrade), recorded per token | LINK, UNI, AAVE; BNB, TRX in their vaults |
| **Bridged** | A bridge's copy of a coin issued on another chain | The bridge's validators or committee, and its upgrade keys | ARB (Arbitrum's canonical bridge), GRAM (TON's bridge), ICP, CAKE, the TRX at `0x5032…7ab5` (a 3-of-5 Safe upgrades its bridge with no timelock) |
| **Custodial** | A company holding the coins off chain and minting a token against them | The custodian, and its minting key | WBTC (BitGo), Binance-Peg LTC (`0x4338…db94` on BNB Chain: one externally owned key mints; no pause, blacklist or upgrade) |

- **Why tiers rather than a yes or no.** Index constituents are fixed per index, so a token that fails hurts only the
  indexes that chose it, by its weight. A creator can build a native-only index or an index of pegged coins; holders
  see which before they buy.
- **What a failure costs.** A depegged custodial token loses at most its weight in each index that holds it. Holders can
  still redeem every other component in kind; `redeemSkipping` and claims cover a token that freezes transfers.
- **On chain or off chain.** The tier lives in `ConfigureWhitelist`'s entry and the app, not in the factory: adding a
  field to the factory's listing changes a Stage A contract and its ABI for a label the contracts never read.

## 2. Ethereum: 29 listings, no contract change

### 2.1 The admission check

`ConfigureWhitelist` already refuses a token outside the policy it can see: no code, decimals outside 6 to 18, USDC or
USDT, a supply outside 1 to `MAX_SUPPLY`. Listing 29 tokens at once needs the rest of the review written down and
mostly automated, in a new read-only script, `script/CheckToken.s.sol`, run against a mainnet RPC before each proposal:

| Check | How | Refuses or records |
|---|---|---|
| Standard transfers | Simulate `transfer` and `transferFrom` on a fork; compare balances | refuses fee-on-transfer and rebasing (the hub's `issue` would refuse them anyway) |
| Hooks | ERC-777 or ERC-1363 registry entries, `tokensReceived` hooks | refuses |
| Admin powers | Bytecode selectors and verified source: mint, burn from others, pause, blacklist, upgrade (EIP-1967, older proxy slots), owner and its type (key, Safe and threshold, timelock) | records; refuses a key that can both blacklist and destroy a balance, as WBT was refused |
| Depth | Uniswap V3 and V4 pools against WETH and USDC: reserves within 2% of the mid price | records; below a threshold the token is marked "mint by MintRequests" in the app |
| Reference supply | The coin's circulating supply from two sources, dated; a bridged or custodial copy carries the coin's supply, as WBTC carries bitcoin's | records, in the entry's comment |

The script prints one report per token for the Safe's signers, and the entries for `ConfigureWhitelist`.

### 2.2 What the 29 look like in practice

- **Depth is thin for many.** Measured on 4 October: OKB about $0.17M of Uniswap depth on Ethereum, POL $0.13M, ARB
  $0.08M, against about $50M for UNI or LINK. The zap cannot route size through such pools. Those coins mint through
  `MintRequests`, where a filler sells shares at the requester's limit, and redeem in kind, which always works.
- **Exchange tokens** (LEO, OKB, BGB, GT) are controlled by their exchanges; WLFI can blacklist holders. Each gets its
  admin powers recorded, and the WBT rule decides.
- **The flagship.** Of the 29 only LEO clears the floor, and it fails the liquidity screen. So these listings serve
  creators' indexes; the flagship's list changes only if the owner admits the bridged tier.

### 2.3 Process

One `ConfigureWhitelist` run in `safe` mode prints the proposals for all 29 as one Safe batch; two to nine days later
anyone executes them. Supplies then follow the weekly batch with every other token. No timelock, cap or code changes.

## 3. BNB Chain: token support in the EVM vault

### 3.1 What already works

`XindexVault` keeps per token: `balance`, `paidTotal`, `held`, `cap`, `outflowFloor`, intakes and deposits, and the
4%-a-day speed limit's buckets. A burn's or migration's owed payout names its token, and `CAP_UPDATE` messages set a
token's cap and floor. On Ethereum, the factory names a vault coin by `vaultTokenId(chainId, tokenId)` for any 32-byte
`tokenId`, and the hub's digests carry each intake's token list. `BnbStateVerifier` proves storage slots, whatever they
hold.

### 3.2 The change

Four code paths assume the native coin. Each gains the token case:

| Path | Today | With tokens |
|---|---|---|
| `deposit` | payable, native only | `depositToken(index, intakeId, token, amount)`: `transferFrom`, the amount **measured** as the vault's balance increase, as `MintRequests` measures escrows |
| `refund` | the native deposit | the caller's deposit of each token in the intake |
| `_send` | `call{value}` | `SafeERC20.safeTransfer` for a token; a revert keeps the amount owed, as a refused native payout does |
| snapshot claim | owes the native coin | owes the component's token |

Rules that go with it:
- **A token is accepted only once it has a cap.** Cap zero means refused. A cap comes only by `CAP_UPDATE`, which the
  factory sends after `LISTING_DELAY` and the vault applies after `GOVERNANCE_DELAY`: no token enters a vault faster
  than a listing does, and the freezer can cancel it.
- **A paused or blacklisting token stalls only itself.** Its payouts stay owed; the speed limit, balances and payouts of
  every other token are separate.
- **Fee-on-transfer and rebasing tokens are refused** by the admission check (2.1), run against BNB Chain.
- **The listing.** `proposeVaultListing(56, bytes32(uint256(uint160(token))), supply)` on Ethereum, then the
  `CAP_UPDATE`, through `ConfigureChains`.

### 3.3 The twin rule

The other vaults (Solana, NEAR, Stellar, Sui, Aptos) hold native coins only and refuse other tokens, as today. Token
support is an EVM vault capability, which Injective's and VeChain's vaults, the same contract, also gain. The twin rule
is restated: every vault keeps the same messages and rules for the coins it holds; which coins a vault can hold differs
by chain. A Solana vault holding SPL tokens, for instance, would be a separate change.

### 3.4 Tests and review

- A unit test per path and per refusal; the vault's invariant suite extended to tokens (held equals the sum of
  balances and open deposits, per token); a mock pausing and blacklisting token; a fee-on-transfer token refused.
- A regression of every vault finding that touches payouts (VLT-1 to VLT-5) on a token as well as the native coin.
- `BnbStateVerifier`'s fork test proving a token intake's digest from real BNB Chain storage.
- The change goes to the external audit with the vaults.

## 4. The flagship

The flagship today holds native coins and WBTC. The 43 change it only through the owner's policy:

| Policy | The flagship adds | Coverage |
|---|---|---|
| Native only (today) | nothing above the floor | 86.26% |
| Native and bridged | none above the floor | 86.26% |
| Native, bridged and custodial | XRP, SOL, ZEC, DOGE, ADA, BCH and LTC, as Binance-Peg tokens | about 95% |

- **The custodial tier in the flagship** would make Binance's honesty and key security a part of about 8.7% of the
  flagship's value. WBTC is the precedent for one custodian; Binance would be a second, holding more weight.
- **SOL specifically** has a native route: the Tower BFT verifier (`design/2026-10-05-solana-hyperevm-research.md`).
  A Binance-Peg SOL listing could bridge the gap until it ships, then be replaced at a rebalance.

## 5. Order of work

1. **The admission check** (`script/CheckToken.s.sol`) and the 29 Ethereum entries: a few days. No contract change.
2. **Token support in `XindexVault`**, with tests: one to two weeks, then the audit.
3. **BNB Chain listings**: the 14 tokens through `ConfigureChains` and their caps, after the vault change is deployed.

None of this blocks the hackathon demo, and none of it should go before it.

## 6. Decisions for the owner

1. **The tiers.** Accept bridged and custodial tokens as listable at all, labelled as above.
2. **The flagship's policy.** Native only (recommended), or with the custodial tier.
3. **The WBT rule's reach.** Which admin powers refuse a token outright: a key that can blacklist and destroy (WBT),
   a single key that can mint unbacked tokens (Binance-Peg), an upgrade with no timelock (the bridged TRX).
4. **Token support in the EVM vault**, and the restated twin rule.
5. **Depth.** Whether a token too thin for the zap is listed, minted only through `MintRequests`.
