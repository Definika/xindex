# Xindex

[![CI](https://github.com/Definika/xindex/actions/workflows/test.yml/badge.svg)](https://github.com/Definika/xindex/actions/workflows/test.yml)
[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)

Xindex is a protocol for index tokens on Ethereum, BNB Chain and Base: three deployments of the same contracts that
share nothing, each holding its own chain's tokens
([`docs/design/bnb-chain.md`](docs/design/bnb-chain.md),
[`docs/design/base.md`](docs/design/base.md)). A wallet the factory's
owner approved creates an index of 2 to 200
listed assets at weights it chooses, and anyone can mint, redeem and trade it. Each index is an ERC-20 fully backed in
kind: minting deposits the basket and redeeming returns it. A permissionless auction brings an index back toward its
weights. No mint, redeem or claim reads a price. A rebalance is judged on units first, and is then checked against
Pyth's prices, a check that can only refuse a fill ([`docs/design/pyth-check.md`](docs/design/pyth-check.md)).

## How it works

- **Create, and buy.** `WeightedIndexFactory.createAndIssue` deploys an index, a clone of `WeightedHub`, with its own
  name, symbol, components and weights, and issues its first shares in the same call: creating an index is buying
  it. The basket is pulled from the creator, who approved the index's address, which `predictIndexAddress` gives,
  before it existed. `createIndex` creates one with no shares, for an index too wide for one transaction (the two
  together fit up to about 125 components). Either way each component's units must lie within 5% of its weight at
  Pyth's prices (`OffWeights`), so an index starts on its weights. Only a wallet the factory's owner approved can
  create (`setApprovedCreator`). The components never change; the weights change only when the index's creator
  proposes new ones and 7 days pass (`proposeWeights`), and the units follow at the next rebalance. A partner takes
  over an index by its creator role, which moves to any account.
- **Mint and redeem.** `issue` takes each component in proportion to the shares minted, and `redeem` burns shares and
  pays the components out. No oracle sits on either path, so nothing can block an exit. `redeemSkipping` exits around a
  frozen component, which can be claimed later.
- **Trade with stablecoins.** `IndexZap` mints with USDC or USDT and burns to USDC or USDT in one transaction,
  through Uniswap's Universal Router (V3 and V4 pools) and, leg by leg, the chain's own DEX (PancakeSwap on BNB
  Chain, Aero on Base); a USDC permit spares the approval, so the mint is one
  transaction, signed after the permit itself. The two stablecoins are the only currencies, on each chain its own:
  no mint, burn, buy or sale takes ether. The one place ether enters is the
  factory's creation fee, zero until the owner sets one, which an approved creator pays when it creates an index.
  `BasketBuilder` does the same over several transactions for baskets too wide for one. `MintRequests` holds limit
  orders anyone can fill.
- **Rebalance.** Once an index's interval (7 to 91 days) has passed, anyone can start a rebalance. After 2 hours of
  notice, a 4-hour auction lets any contract settle it. The executor names the units each component is to have, and
  the index accepts them only if their weighted gain clears a bar that halves every twelve minutes. The bar falls
  until some executor finds the trade worth making. One fill takes at most 20% of a component and at most doubles
  one, and never lowers the weighted product of the units, a constant-weight pool's invariant. A fill the units
  accept must then bring in, at Pyth's prices of the last fifteen seconds, at least what it takes less a tolerance that rises
  from nothing to 2% over the auction: so an executor bidding alone keeps at most 2% of what it trades, and
  competition, filling earlier, returns the rest. The executor posts Pyth's update itself. The owner or guardian may
  also start a rebalance with a quote, their own prices and a tolerance, which likewise can only refuse a fill; and
  either may start again a week after any fill, so a fill that traded next to nothing does not hold an index off
  its weights for its whole interval.
- **Fees.** Creator and platform fees on mint and redeem, and an optional streaming fee, all paid in new shares. No fee
  moves a component.

```
                  createAndIssue(name, symbol, [{token, weight, units}, ...], params, shares, to)
   creator ──────────────────────────────────► WeightedIndexFactory ──CREATE2 clone───► WeightedHub (ERC-20)
                                               │ listings                             │ holds the basket
                                               │ (2-day delay), guardian,             │ issue / redeem in kind
                                               │ registry                             │ redeemSkipping / claim
                                                                                      │
   anyone ── startRebalance(keepMask) ──────────────────────────────────────────────► │ 2 hours of notice
   executor ── executeRebalance(newUnits, data) ────────────────────────────────────► │ gain ≥ bar(t), Pyth's check, callback
                                                                                      │
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                  │
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── anyone holding shares
             ◄─ at least minShares ────────────   (escrow)    ── the USDC ──►
```

## Trust model

- No upgrades, no pause of redemptions, and no admin access to funds, to shares, or to an index's components. The
  one brake: the owner or guardian can pause the minting of new shares, on one index or on all, and only the owner
  lifts it. Redeeming, claims, transfers and rebalances never read it.
- No mint, redeem or claim reads a price, so no feed can block an exit or misprice a mint. A rebalance is judged on
  units first: on its weights an index cannot lose value to a fill, and off them a fill can take at most the
  index's distance from its weights. Pyth's check then caps what a lone executor keeps at 2% of what it trades.
  Pyth can only refuse: prices that are stale or missing stop fills, and prices that are wrong or hostile can do no
  more than let through a fill the units already accept. So if Pyth fails, rebalancing stops or falls back to the
  units' bound, and holders redeem throughout.
- The owner, a Safe that needs at least 3 signatures, lists assets behind a 2-day delay, approves which wallets may
  create an index and sets fees for new indexes. The approval is read at creation only: it reaches no existing index.
- The guardian can cancel a rebalance or route one around a frozen asset. It moves no funds, and the owner can replace
  it through a 7-day delay it cannot block.

Every index holds, for each component `i`, at all times:

```
token_i.balanceOf(index) >= floor(totalSupply × units_i × scale / 1e36) + totalClaims[token_i]
```

## Contracts

| Contract | Role |
|---|---|
| [`WeightedIndexFactory`](src/WeightedIndexFactory.sol) | Lists assets, creates indexes, and holds the registry and the fee policy. |
| [`WeightedHub`](src/WeightedHub.sol) | The index token: issue, redeem, claims, fees and rebalancing. |
| [`WeightedMath`](src/WeightedMath.sol) | The rebalance settlement's arithmetic, shared by every index. |
| [`PythPrices`](src/PythPrices.sol) | Values a fill's legs at Pyth's prices, for the check that can only refuse. |
| [`IndexZap`](src/IndexZap.sol) | Mints with USDC or USDT and burns to USDC or USDT in one transaction. |
| [`BasketBuilder`](src/BasketBuilder.sol) | The same over several transactions, for baskets of any size. |
| [`MintRequests`](src/MintRequests.sol) | Limit orders in USDC or USDT, escrowed until filled, cancelled or expired. |
| [`KeeperExecutor`](keeper/src/KeeperExecutor.sol) | The keeper bot's executor. It starts and fills auctions and holds no role. |

## Deployments

**Ethereum:** not deployed yet. Mainnet follows an external audit.

**BNB Chain:** not deployed yet. Its address book, list and fork suite are built
(`script/BnbChainAddresses.sol`, `test/fork/BnbChainAddresses.fork.t.sol`); it follows the same audit.

**Base:** not deployed yet. Its address book, list and fork suites are built (`script/BaseAddresses.sol`,
`test/fork/BaseAddresses.fork.t.sol`, and `test/fork/BaseStocks.fork.t.sol` for Coinbase's stock tokens, which it
runs on Base's own node); it follows the same audit.

**Sepolia** (testnet):

| Contract | Address |
|---|---|
| WeightedIndexFactory | [`0x60b3CAA43781DE2385E3DFDb05FBfA0B9880549C`](https://sepolia.etherscan.io/address/0x60b3CAA43781DE2385E3DFDb05FBfA0B9880549C) |
| WeightedHub (implementation) | [`0x00DAadC7e118298563d85405422827c65A7A3308`](https://sepolia.etherscan.io/address/0x00DAadC7e118298563d85405422827c65A7A3308) |
| IndexZap | [`0xc915E58293f128F11Cb61A9a186aeC6f3AC390EA`](https://sepolia.etherscan.io/address/0xc915E58293f128F11Cb61A9a186aeC6f3AC390EA) |
| BasketBuilder | [`0xcf422f4C9acCeF6284C416Fbe31926db909BA398`](https://sepolia.etherscan.io/address/0xcf422f4C9acCeF6284C416Fbe31926db909BA398) |
| MintRequests | [`0x3A295af2E384FA7cdeF76651963357Bf050e994D`](https://sepolia.etherscan.io/address/0x3A295af2E384FA7cdeF76651963357Bf050e994D) |

Sepolia runs the oracle-free build of `5b7635f`, which has no Pyth check; this branch's build is not deployed there.
The test tokens, the owner and guardian, and how to use them are in [docs/deployment.md](docs/deployment.md).

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/Definika/xindex.git
cd xindex
forge build
forge test
```

Coverage, fork tests against mainnet, static analysis and the keeper's tests are in
[docs/development.md](docs/development.md).

## Repository structure

```
src/                 the protocol's contracts, their interfaces and libraries
test/                unit, fuzz, invariant and regression tests; test/fork/ runs against mainnet
script/              deployment, listing and token-check scripts, and the Sepolia test market
abi/                 the ABIs apps decode with
keeper/              the auction keeper: a bot, its executor contract and the restock service
docs/                integration, deployment and development guides; docs/design/ holds the design records
audits/              review reports, the records of what each redesign retired, and the external audit package
```

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): the contracts in depth, from the settlement math to gas.
- [Integration](docs/integration.md): how each flow works and what an app must get right.
- [Known limitations](docs/known-limitations.md): what the contracts do not protect against.
- [Assets](docs/assets.md): the listing policy, the asset list and the labels an app must show.
- [Design decisions](docs/decisions.md), and what is not built yet.
- [Deployment](docs/deployment.md): deploying, operating, and the Sepolia test deployment.
- [Development](docs/development.md): building, testing and CI.
- [Keeper](keeper/README.md): running the auction keeper.
- [Changelog](CHANGELOG.md): the version history and every decision.

## Security

Xindex has been reviewed internally and red-teamed, and every finding is fixed or documented. It has not been audited
externally yet; that comes before any mainnet deployment. See [SECURITY.md](SECURITY.md) for the reviews and for how to
report a vulnerability.

## License

Business Source License 1.1, see [LICENSE](LICENSE): non-production use is free, running the keeper against our
deployments and integrating with them is granted, and the code becomes MIT on 2030-10-28. The interfaces under
`src/interfaces` are MIT now. Files copied from Wormhole and Uniswap keep their own licenses, listed in
[NOTICE](NOTICE).
