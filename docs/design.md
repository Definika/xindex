# Design decisions

| Topic | Decision |
|---|---|
| Chain | One deployment, on Ethereum. Nothing crosses a chain inside a contract: coins from other chains are held as the Ethereum tokens that represent them. |
| Composition | 2 to 100 components per index, fixed at creation with their weights (basis points summing to 10,000). A new list or new weights is a new index. |
| Creation | `createIndex(name, symbol, components, params)` takes one `ComponentSpec {token, weight, units}` per component. The app derives the starting units from the weights at its own prices; each lies between `MIN_RAW_UNITS` and `maxUnitsOf(token)`. The factory reads no price, and the first rebalance brings an index to its weights. Every component copies its listing's Pyth price id and decimals. |
| Rebalancing | Once the index's interval (7 to 91 days, chosen at creation) has passed, anyone starts a rebalance while every moving feed publishes. After 2 hours of notice, a 4-hour Dutch auction lets any contract settle it at Pyth prices. One fill sends out at most 20% of each component's units and must trade at least 0.1% of the moving value. |
| Prices | Pyth only, read by the hub alone: the settlement prices the moving components, and a start checks that their feeds publish. One price per block, 12 seconds before it. A price is refused if it is not positive, outside the exponent range, too uncertain (confidence above 2%) or more than 5% from its own moving average. Issue, redeem and claims read none. The app values an index off chain. |
| Swaps | Uniswap's Universal Router 2.0.0, V3 or V4 pools, one venue per leg, chosen by the caller. The zap fits about 35 components in one transaction (EIP-7825's 16.78M gas cap); the basket builder covers wider baskets over several. |
| Fees | Paid in shares, never in components. The creator's rate (0 to 1%) plus the platform's (0 to 0.25%, the policy when the index was created) on every issue and redeem; a referrer named at mint takes a share of the platform's part. An optional streaming fee (creator up to 5% a year, platform up to 1%) accrues in shares and moves no tokens. |
| Access | A gated index issues only to recipients its creator allows, until the creator opens it for good. An unlisted index is simply not shown by the app. |
| Assets | Ethereum ERC-20s: the issuer's own contract where Ethereum has one, Bitcoin as WBTC, and otherwise the copy Wormhole's token bridge wraps from the coin's home chain. Tether Gold and Ondo's tokenized stocks are listed too. The labels the app must show (Native, Bridged, Custodial, issuer powers) are in [assets.md](assets.md). |
| Stablecoins | Mint with USDC or USDT through the zap, the basket builder, or a limit order in `MintRequests`. Burn to USDC, USDT or any other token, or in kind. Index tokens are fungible, so the protocol does not track which stablecoin a holder used. |
| Governance | No admin can move an index's funds, mint or burn its shares, pause or upgrade it, or change its units or weights. The owner, a Safe that needs at least 3 signatures, proposes listings (effective after 2 days) and guardian changes (after 7), and sets the fee policy for new indexes. The guardian can cancel pending listings, delist, cancel a rebalance, and start one around a frozen component. Ownership moves in two steps and cannot be renounced. |
| Frozen components | If an issuer pauses or blacklists a component, holders take every other component out with `redeemSkipping` and claim the frozen one later. The guardian rebalances around it with a keep mask, which neither moves the component nor reads its price. |

## Not built yet

- ETH in and out (`mintWithETH`, `burnToETH`), `createAndMint` in one call, `mintWithTokenPermit` for USDC.
- Constituent changes: a new list is a new index.
- Legs that split one swap across V3 and V4, and per-pair partial-fill auctions.
- A backstop for auctions too small to pay. The keeper fills only what pays, unless its operator sets a subsidy.
- An aggregator or Universal Router 2.1 zap, and V4 pools on the Sepolia test market.
- An L2 deployment, if cheap minting for small buyers matters after launch.
