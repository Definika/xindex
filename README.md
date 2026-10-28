# Xindex

[![CI](https://github.com/Definika/xindex/actions/workflows/test.yml/badge.svg)](https://github.com/Definika/xindex/actions/workflows/test.yml)
[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-blue.svg)](LICENSE)

Xindex is a protocol for index tokens on Ethereum. Anyone can create an index of 2 to 100 listed assets at weights they
choose. Each index is an ERC-20 fully backed in kind: minting deposits the basket and redeeming returns it, so neither
reads a price. A permissionless auction brings an index back to its weights at Pyth prices.

## How it works

- **Create.** `WeightedIndexFactory.createIndex` deploys an index, a clone of `WeightedHub`, with its own name, symbol,
  components and weights. They never change.
- **Mint and redeem.** `issue` takes each component in proportion to the shares minted, and `redeem` burns shares and
  pays the components out. No oracle sits on either path, so nothing can block an exit. `redeemSkipping` exits around a
  frozen component, which can be claimed later.
- **Trade with stablecoins.** `IndexZap` mints with USDC or USDT and burns to any token in one transaction, through
  Uniswap's Universal Router (V3 and V4 pools). `BasketBuilder` does the same over several transactions for baskets too
  wide for one. `MintRequests` holds limit orders anyone can fill.
- **Rebalance.** Once an index's interval (7 to 91 days) has passed, anyone can start a rebalance while every feed
  publishes. After 2 hours of notice, a 4-hour Dutch auction lets any contract settle it at Pyth prices; the multiplier
  on what the executor must deliver falls from 1.02 to 0.98. One fill moves at most 20% of each component.
- **Fees.** Creator and platform fees on mint and redeem, and an optional streaming fee, all paid in new shares. No fee
  moves a component.

```
                  createIndex(name, symbol, [{token, weight, units}, ...], params)
   creator ──────────────────────────────────► WeightedIndexFactory ──CREATE2 clone───► WeightedHub (ERC-20)
                                               │ listings with Pyth ids               │ holds the basket
                                               │ (2-day delay), guardian,             │ issue / redeem in kind
                                               │ registry                             │ redeemSkipping / claim
                                                                                      │
   anyone ── startRebalance(keepMask, priceUpdate) ─────────────────────────────────► │ 2 hours of notice
   executor ── executeRebalance(data, priceUpdate) ─────────────────────────────────► │ fill at μ(t), with a callback
                                         Pyth ◄── parse at priceTime() ────────────── │
                                                                                      │
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                  │
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── anyone holding shares
             ◄─ at least minShares ────────────   (escrow)    ── the USDC ──►
```

## Trust model

- No upgrades, no pause, and no admin access to funds, to shares, or to an index's components and weights.
- Only rebalancing reads prices, from Pyth. One fill moves at most 20% of each component, whatever a price says.
- The owner, a Safe that needs at least 3 signatures, lists assets behind a 2-day delay and sets fees for new indexes.
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
| [`IndexZap`](src/IndexZap.sol) | Mints with and burns to stablecoins in one transaction. |
| [`BasketBuilder`](src/BasketBuilder.sol) | The same over several transactions, for baskets of any size. |
| [`MintRequests`](src/MintRequests.sol) | Limit orders in USDC or USDT, escrowed until filled, cancelled or expired. |
| [`KeeperExecutor`](keeper/src/KeeperExecutor.sol) | The keeper bot's executor. It starts and fills auctions and holds no role. |

## Deployments

**Ethereum:** not deployed yet. Mainnet follows an external audit.

**Sepolia** (testnet):

| Contract | Address |
|---|---|
| WeightedIndexFactory | [`0x787139b915753F0CfFfa14708D1e665dCf5AA0bA`](https://sepolia.etherscan.io/address/0x787139b915753F0CfFfa14708D1e665dCf5AA0bA) |
| WeightedHub (implementation) | [`0x3ae717ffeE17D3FAd861447703F31011eB8DC609`](https://sepolia.etherscan.io/address/0x3ae717ffeE17D3FAd861447703F31011eB8DC609) |
| IndexZap | [`0x1CC5cC8bE9553cFe952a4A330071C20cE96d9924`](https://sepolia.etherscan.io/address/0x1CC5cC8bE9553cFe952a4A330071C20cE96d9924) |
| BasketBuilder | [`0xa4AB1233D1Eb2ddcA77C27579A8cB41156452E13`](https://sepolia.etherscan.io/address/0xa4AB1233D1Eb2ddcA77C27579A8cB41156452E13) |
| MintRequests | [`0x5b092e8A8ab29A12e2D91bE96C307759B2a12b81`](https://sepolia.etherscan.io/address/0x5b092e8A8ab29A12e2D91bE96C307759B2a12b81) |

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
docs/                integration, deployment and development guides
design/              design records
audit/               review reports
```

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): the contracts in depth, from the settlement math to gas.
- [Integration](docs/integration.md): how each flow works and what an app must get right.
- [Known limitations](docs/known-limitations.md): what the contracts do not protect against.
- [Assets](docs/assets.md): the listing policy, the asset list and the labels an app must show.
- [Design decisions](docs/design.md), and what is not built yet.
- [Deployment](docs/deployment.md): deploying, operating, and the Sepolia test deployment.
- [Development](docs/development.md): building, testing and CI.
- [Keeper](keeper/README.md): running the auction keeper.
- [Version history](docs/history.md).

## Security

Xindex has been reviewed internally and red-teamed, and every finding is fixed or documented. It has not been audited
externally yet; that comes before any mainnet deployment. See [SECURITY.md](SECURITY.md) for the reviews and for how to
report a vulnerability.

## License

Business Source License 1.1, see [LICENSE](LICENSE): non-production use is free, running the keeper against our
deployments and integrating with them is granted, and the code becomes MIT on 2030-10-28. The interfaces under
`src/interfaces` are MIT now. Files copied from Pyth, Wormhole and Uniswap keep their own licenses, listed in
[NOTICE](NOTICE).
