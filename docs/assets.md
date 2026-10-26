# Assets

## Listing policy

Components are standard ERC-20s: no fee-on-transfer, rebasing or callback tokens, 6 to 18 decimals, and the address
must be a contract. `issue` checks the amount it receives. USDC and USDT are mint and burn currencies, never components.
How a token's own supply changes does not matter, since nothing reads it.

`script/CheckToken.s.sol` reports on every token before it is listed. It refuses a token whose issuer can both blacklist
a holder and destroy its balance; Tether Gold and Ondo's stocks, whose issuers hold that power, are listed by an explicit
waiver.

## Price ids

Every listing records the token's Pyth price id and its decimals, read from the token when the listing is proposed. No
settlement asks a component for them again. A price is scaled as `price × 10^(36 + expo − decimals)`. Each id in
`script/PythIds.sol` carries its feed's description, and the feed must price the asset held: WETH takes ETH/USD, since
it redeems one for one; WBTC takes WBTC/USD, so its own depeg shows; a Wormhole copy takes its coin's feed.

## Listing process

- `proposeListing(token, priceId)`, owner only, starts a 2-day delay (`LISTING_DELAY`).
- For the next 7 days (`PROPOSAL_WINDOW`) anyone can `executeListing`; after that the proposal expires.
- Until it executes, the owner or guardian can `cancelListing`.
- Either role can `delist` a token at any time. Delisting and relisting reach only indexes created afterwards, since
  every index copies its components' price ids and decimals at creation.

## The list

`script/PythIds.sol` lists 91 assets: `default` is the first four (WETH, WBTC, LINK, UNI) and `wide` the other 87.

- 73 coins of the top 300, held as the issuer's own Ethereum contract where one exists, and otherwise as the copy
  Wormhole's token bridge wraps from the coin's home chain (15 copies, among them SOL, BNB and SUI).
- Tether Gold.
- 17 tokenized US stocks issued by Ondo.

26 more Wormhole copies wait for an attestation on Wormhole's Portal before they can be checked and listed
([`design/2026-10-10-one-index-wormhole-legs.md`](../design/2026-10-10-one-index-wormhole-legs.md), section 2a). Every
listed token passed `CheckToken` on a mainnet fork, and one fork test issues, rebalances and redeems an index holding
every coin `forge-std` can fund.

## Labels the app shows

| Label | Meaning |
|---|---|
| Native | Issued on Ethereum by the coin's own issuer. |
| Bridged | A copy wrapped by a bridge, Wormhole's for every non-Ethereum coin. ZK is ZKsync's bridge copy. |
| Custodial | Backed by a custodian: WBTC (BitGo), Tether Gold (Tether), Ondo's stocks, and any copy of a Binance-Peg coin. |
| Pausable | The issuer can pause transfers: WBTC, MANA, CHZ, SENT, FLUID, GALA, FET, SNX, PLUME and the Ondo tokens. |

## Left out

- Tokens whose issuer can blacklist a holder and destroy its balance, such as WhiteBIT's WBT.
- Exchange tokens (OKB, BGB, GT), NIGHT, and memecoins other than SHIB and PEPE.
- Coins whose only Ethereum form depends on a bridge that has closed or is closing.

## Liquidity

Most Wormhole copies and real-world assets have no Uniswap liquidity. They mint in kind or through `MintRequests`, and a
rebalance that buys them needs an executor that holds them. Six stocks (TSM, AVGO, LLY, JPM, WMT, V) have Pyth feeds
only during US market hours, so an index holding one rebalances only while that market is open, or with the stock kept.

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
| Pyth | `0x4305FB66699C3B2702D4d05CF36551390A4c69C6` |
| WeightedIndexFactory / IndexZap / BasketBuilder / MintRequests | not deployed |

The scripts read these addresses from the address book, and `test/fork/MainnetAddresses.fork.t.sol` checks it on
chain: tokens by symbol and decimals, the router and the PoolManager by their runtime code hashes (every Universal
Router build answers `poolManager()` alike, CR-I35), Pyth's proxy by its code, the Wormhole copies against the bridge,
and both lists on a fresh factory over Pyth. The quoters and StateView are for apps and tests; no contract reads
them.
