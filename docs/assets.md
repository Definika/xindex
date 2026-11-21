# Assets

## Listing policy

Components are standard ERC-20s: no fee-on-transfer, rebasing or callback tokens, 6 to 18 decimals, and the address
must be a contract. `issue` checks the amount it receives and that it can leave again: a holder must be able to send
itself one raw unit at no cost, which every issue and every fill proves of the index (RW-8). A token whose ledger a
second address also writes, a proxy beside a legacy address, is never listed: the swap engine refuses a swap measured
across the two, but not an index that names both (RW-10). USDC and USDT are mint and burn currencies, never components.
How a token's own supply changes does not matter, since nothing reads it.

`script/CheckToken.s.sol` reports on every token before it is listed. It refuses a token whose issuer can both blacklist
a holder and destroy its balance; Tether Gold, whose issuer holds that power, is listed by an explicit waiver, as
Ondo's stocks were until 2026-11-21. A token whose balances move without a transfer is never listed: Backed's xStocks
report each holder's shares times a multiplier, so the list holds Backed's wrapper of each, whose balances stay fixed.

## What a listing records

A listing records the token's decimals, read from the token when the listing is proposed, and nothing else. They only
bound the units an index may start with (`maxUnitsOf`). No contract reads a price, so no listing carries a price id
(since 2026-11-10). `script/PythIds.sol` still holds each coin's Pyth id with its feed's description, as the keeper's
catalogue: the keeper prices its own trades off chain, and no contract or script reads the file.

## Listing process

- `proposeListing(token)`, owner only, starts a 2-day delay (`LISTING_DELAY`).
- For the next 7 days (`PROPOSAL_WINDOW`) anyone can `executeListing`; after that the proposal expires.
- Until it executes, the owner or guardian can `cancelListing`.
- Either role can `delist` a token at any time. Delisting and relisting reach only indexes created afterwards: an
  index's components and weights are fixed at its creation.

## The list

`script/Listings.sol` lists 171 assets with their tiers: `default` is the first four (WETH, WBTC, LINK, UNI) and `wide`
the other 167.

- 61 coins of the top 300, held as the issuer's own Ethereum contract where one exists, and otherwise as the copy
  Wormhole's token bridge wraps from the coin's home chain (3 copies: SOL, AVAX and AERO). OP's copy left the list on
  2026-11-21 (the owner's call): the restock found no route to buy OP on Optimism within its loss bound that day, its
  pools there being too thin. The copies of XRP,
  ADA, LTC, DOT, ATOM and BNB, each wrapped from BNB Chain, left the list on 2026-11-13 (the owner's call): BNB Chain's
  deployment holds those six coins in kind, below. The copies of JUP, PYTH, SUI, APT and ALGO left it on 2026-11-18
  (the owner's call): no Ethereum pool trades them, so a rebalance could buy them only from stock bridged in from
  Solana, Sui, Aptos or Algorand, whose restock has never run
  ([`design/2026-11-18-bridged-coins-in-a-rebalance.md`](../design/2026-11-18-bridged-coins-in-a-rebalance.md)).
  SOL's copy trades on Uniswap, and the restock serves AVAX's and AERO's from their EVM home chains.
- Tether Gold.
- 109 US stocks and ETFs as Backed's wrapped xStocks (`w<ticker>x`), Custodial, since 2026-11-21 (the owner's call,
  [`design/2026-11-21-xstocks.md`](../design/2026-11-21-xstocks.md)). Each is an ERC-4626 vault over one xStock;
  a dividend raises what a wrapper redeems for, never a balance. They replace the 17 Ondo stocks listed from
  2026-10-10. Every wrapper Backed has deployed is listed, less nine whose share has no Pyth feed that names it.
  Backed's 2-of-3 Safe can upgrade every wrapper and xStock, and one key of Backed's sets every xStock's multiplier.

26 more Wormhole copies wait for an attestation (`node keeper/restock.mjs --attest <chain> <token>`, since legacy
Portal closed on 2026-06-30) before they can be checked and listed
([`design/2026-10-10-one-index-wormhole-legs.md`](../design/2026-10-10-one-index-wormhole-legs.md), section 2a), and
FIL's waits for a reading of its Binance-Peg source. Every
listed token passed `CheckToken` on a mainnet fork, and one fork test issues, rebalances and redeems an index holding
every coin `forge-std` can fund.

### BNB Chain

`script/BnbChainAddresses.sol` lists 116 assets for the BNB Chain deployment (`V5_WHITELIST=bnb`), each held in kind
there and none through Wormhole:

- WBNB and ASTER, Native.
- BTCB, ETH, XRP, ZEC, ADA, BCH, LTC, DOT and ATOM, Custodial: Binance-Peg tokens, which Binance backs and one key of
  Binance's mints. None is a proxy.
- STABLE, Bridged: a LayerZero token a 3-of-5 Safe upgrades.
- 104 wrapped xStocks, Custodial, since 2026-11-21: Ethereum's 109 less AMD, MARA, OKLO, SLV and SPGI, which Backed
  has not wrapped there. Each stands at its Ethereum address, over the same xStock.

All twelve passed `CheckToken` on BNB Chain on 2026-11-13, and the 104 wrappers on 2026-11-21. Binance-Peg DOGE, AVAX and FIL are left out: each is a
proxy whose code one key can replace. Six of the twelve (WBNB, BTCB, ETH, XRP, ZEC, ASTER) have a Uniswap market the
zap can route a mint through; ADA, LTC, DOT, BCH, ATOM and STABLE trade mostly on PancakeSwap, which the zap does not
use, so they mint in kind or through `MintRequests`
([`design/2026-11-13-bnb-chain-deployment.md`](../design/2026-11-13-bnb-chain-deployment.md), section 6).

## Labels the app shows

| Label | Meaning |
|---|---|
| Native | Issued on Ethereum by the coin's own issuer. |
| Bridged | A copy wrapped by a bridge, Wormhole's for every non-Ethereum coin. ZK is ZKsync's bridge copy. |
| Custodial | Backed by a custodian: WBTC (BitGo), Tether Gold (Tether), the wrapped xStocks (Backed), and any copy of a Binance-Peg coin. |
| Pausable | The issuer can pause transfers: WBTC, MANA, CHZ, SENT, FLUID, GALA, FET, SNX, PLUME and the wrapped xStocks. |

## Left out

- Tokens whose issuer can blacklist a holder and destroy its balance, such as WhiteBIT's WBT.
- Exchange tokens (OKB, BGB, GT), NIGHT, and memecoins other than SHIB and PEPE.
- Coins whose only Ethereum form depends on a bridge that has closed or is closing.

## Liquidity

Most Wormhole copies and real-world assets have no Uniswap liquidity, and no wrapped xStock has any. They mint in kind or through `MintRequests`, and a
rebalance that buys them needs an executor that holds them. Nothing on chain waits for a market to be open: an
executor that cannot value a stock outside US hours leaves it alone, naming its units unchanged, and trades the rest.

## Ethereum addresses

From the address book, `script/MainnetAddresses.sol`:

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| Uniswap Universal Router 2.0.0 | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap QuoterV2 (V3 quotes) | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Uniswap V4 Quoter | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` |
| Uniswap V4 StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| WeightedIndexFactory / IndexZap / BasketBuilder / MintRequests | not deployed |

The scripts read these addresses from the address book, and `test/fork/MainnetAddresses.fork.t.sol` checks it on
chain: tokens by symbol and decimals, the router and the PoolManager by their runtime code hashes (every Universal
Router build answers `poolManager()` alike, CR-I35), the Wormhole copies against the bridge, and both lists on a fresh
factory. The quoters and StateView are for apps and tests; no contract reads them.
