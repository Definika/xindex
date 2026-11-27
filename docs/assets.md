# Assets

## Listing policy

Components are standard ERC-20s: no fee-on-transfer, rebasing or callback tokens, 6 to 18 decimals, and the address
must be a contract. `issue` checks the amount it receives and that it can leave again: a holder must be able to send
itself one raw unit at no cost, which every issue and every fill proves of the index (RW-8). A token whose ledger a
second address also writes, a proxy beside a legacy address, is never listed: the swap engine refuses a swap measured
across the two, but not an index that names both (RW-10). USDC and USDT are mint and burn currencies, never components.
How a token's own supply changes does not matter, since nothing reads it.

`script/CheckToken.s.sol` reports on every token before it is listed. It refuses a token whose issuer can both blacklist
a holder and destroy its balance; Tether Gold and Ondo's stocks, whose issuers hold that power, are listed by an explicit
waiver.

## What a listing records

A listing records the token's decimals, read from the token when the listing is proposed, and nothing else. They only
bound the units an index may start with (`maxUnitsOf`) and scale the token's price. A token's Pyth feed is set apart
from its listing: the owner proposes it (`proposePriceFeed(token, {id, kind})`), it takes effect
after the same 2-day delay, and the guardian can cancel it. The kind says how the feed values the token: `Token`,
the feed prices one whole token; `Vault`, the token is an ERC-4626 vault and the feed prices its asset; `Multiplier`,
one token stands for `multiplier()` shares of what the feed prices; `SharesOracle`, one token stands for the sValue
shares Ondo's `SyntheticSharesOracle` on the chain holds for it, used only once settled, as each of Ondo's tokens
Pyth prices at its share's feed is (344 of 353,
[`docs/design/ondo-svalue.md`](design/ondo-svalue.md)). Unlike a listing, a feed reaches every index from
the moment it is set, but it can only refuse: a token without a feed cannot be moved by a rebalance fill or put in a
new index, and a wrong feed can do no more than pass a fill the units already accept
([`docs/design/pyth-check.md`](design/pyth-check.md)). `script/PriceFeeds.sol` names each
chain's feeds for `ConfigureWeighted`, Ethereum's taken from `script/PythIds.sol`, which holds each coin's Pyth id
with its feed's description, as the keeper's own catalogue does.

## Listing process

- `proposeListing(token)`, owner only, starts a 2-day delay (`LISTING_DELAY`).
- For the next 7 days (`PROPOSAL_WINDOW`) anyone can `executeListing`; after that the proposal expires.
- Until it executes, the owner or guardian can `cancelListing`.
- Either role can `delist` a token at any time. Delisting and relisting reach only indexes created afterwards: an
  index's components are fixed at its creation, and its weights change only through its creator's proposal behind a
  notice of 7 days.

## The list

`script/Listings.sol` lists 414 assets with their tiers: `default` is the first four (WETH, WBTC, LINK, UNI) and `wide`
the other 410.

- 60 coins of the top 300, held as the issuer's own Ethereum contract where one exists, and otherwise as the copy
  Wormhole's token bridge wraps from the coin's home chain (2 copies: SOL and AVAX). SOL's copy trades on Uniswap,
  and the restock serves AVAX's from its EVM home chain. A copy that no Ethereum pool trades and the restock does not
  serve could be bought for a rebalance only from stock nobody brings in, so it is not listed: the copies of JUP,
  PYTH, SUI, APT and ALGO, homed off the EVM ([`docs/design/bridged-coins.md`](design/bridged-coins.md)), and OP's,
  which the restock found no route to buy on Optimism within its loss bound, its pools there being too thin. AERO's
  copy is not listed either: it is a copy of Aerodrome's AERO, which Aero replaced with a token of its own, the one
  Base's list holds. XRP, ADA, LTC, DOT, ATOM and BNB are held in kind by BNB Chain's deployment, below, and not as
  copies wrapped from BNB Chain.
- Tether Gold.
- 353 tokenized US stocks and ETFs issued by Ondo, every one Pyth has a feed for
  ([`docs/design/ondo-stocks.md`](design/ondo-stocks.md)), among them funds of
  oil, gold, silver, platinum and copper, and Anthropic's ANTon, on BNB Chain too.

26 more Wormhole copies wait for an attestation, through Wormhole's own SDK on each token's home chain (legacy
Portal is closed), before they can be checked and listed; each needs an Ethereum pool to be rebalanced, the
restock serving EVM home chains alone
([`docs/design/wormhole-legs.md`](design/wormhole-legs.md), section 2a), and
FIL's waits for a reading of its Binance-Peg source. Every
listed token passed `CheckToken` on a mainnet fork, and one fork test issues, rebalances and redeems an index holding
every coin `forge-std` can fund.

### Base

`script/BaseAddresses.sol` lists thirty-two assets for the Base deployment (`V5_WHITELIST=base`)
([`docs/design/base.md`](design/base.md),
[`docs/design/coinbase-on-base.md`](design/coinbase-on-base.md)), each held in kind there and
none through Wormhole:

- WETH and AERO, Native: ether wrapped, and Aero's token (not Aerodrome's), which only its
  immutable `MINTER` mints; it has no owner, pause or blocklist.
- ZRO, Bridged, as on Ethereum: LayerZero's own omnichain token.
- UNI, AAVE, MORPHO, FET, CRV, VIRTUAL, PENDLE, PEPE, GRT, COMP, SNX, 1INCH and RSR, Bridged: the copies Base's
  standard bridge mints of those coins on Ethereum's list. Each names its Ethereum token and the bridge on chain, and
  the bridge's other half on Ethereum held each copy's whole supply in backing when it was read. The bridge mints a
  copy and can burn it out of any holder's balance, which is how a withdrawal to Ethereum works; the keys that
  upgrade Base can upgrade both halves, so the app labels each with Base's bridge as its issuer. MORPHO's copy is a
  proxy its issuer's Safe, 5 of 9, upgrades.

- cbBTC, cbETH, cbXRP, cbDOGE, cbLTC and cbADA, Custodial: the Coinbase Wrapped coins. Five are issued on Base,
  each a proxy one account upgrades, with a mint, a pause and a blocklist. cbETH is Base's bridge's copy of
  Ethereum's cbETH, Coinbase's staked ether, whose value rises against ether while balances stay fixed.
- NVDAc, METAc, AAPLc, GOOGLc, AMZNc, MSFTc, MSTRc, SNDKc, SPCXc and TSLAc, Custodial: Coinbase's stock tokens, each
  a claim on shares in Alpaca's custody times its `multiplier()`, which a dividend raises and a split multiplies
  while balances stay fixed. Each is a B20 token, a precompile of Base: an EVM without Base's precompiles cannot
  execute one, so `CheckToken` sends it for review unread, and `test/fork/BaseStocks.fork.t.sol` runs an index of
  them on Base's own node. The issuer can block an address, pause, and move a balance no policy exempts. Coinbase
  offers them outside the United States only.

Backed's four wrappers on Base (wbCOIN, wbMSTR, wbNVDA, wbTSLA, over its older tokens) are not listed: no Pyth feed
names their tokens, the rule Ethereum's list follows. Base's mint currencies are Circle's USDC
and the token that answers USDT there, six decimals each; who can mint that USDT and replace its code is to be read
before a deployment. The zap routes Base's coins through Uniswap or Aero, per leg: Uniswap is the
deeper venue for WETH and cbBTC, Aero for AAVE, MORPHO, cbETH, cbXRP and Coinbase's stocks. The bridged copies FET,
GRT, PEPE, SNX and CRV have no depth on any of Base's venues, so they mint in kind or through `MintRequests`. The
listed AERO is Aero's (`0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee`), whose depth is on
Aero's own pools; Aerodrome's AERO converts to it one for one through Aero's migration while Aero
keeps it open.

### BNB Chain

`script/BnbChainAddresses.sol` lists 366 assets for the BNB Chain deployment (`V5_WHITELIST=bnb`), thirteen coins
and Ondo's 353 stocks and ETFs, each held in kind there and none through Wormhole:

- WBNB, ASTER and CAKE, Native. CAKE is PancakeSwap's own token, and PancakeSwap's
  MasterChef mints it.
- BTCB, ETH, XRP, ZEC, ADA, BCH, LTC, DOT and ATOM, Custodial: Binance-Peg tokens, which Binance backs and one key of
  Binance's mints. None is a proxy.
- STABLE, Bridged: a LayerZero token a 3-of-5 Safe upgrades.
- The 353 Ondo stocks and ETFs of Ethereum's list, Custodial, as Ondo issues them on BNB Chain.

The thirteen passed `CheckToken` on BNB Chain. Binance-Peg DOGE, AVAX and FIL are left out: each is a
proxy whose code one key can replace. Six of the thirteen coins (WBNB, BTCB, ETH, XRP, ZEC, ASTER) have a Uniswap
market the
zap can route a mint through. ADA, LTC, DOT, BCH, ATOM, STABLE and CAKE trade mostly on PancakeSwap, which the zap
routes through too (`docs/design/chain-venues.md`); ATOM's market there is thin
([`docs/design/bnb-chain.md`](design/bnb-chain.md), section 6).

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
