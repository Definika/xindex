# Version history

| Version | Design | Record |
|---|---|---|
| v2 | A market-cap index with on-chain rebalancing, priced from Uniswap V3 pool averages. | |
| v3 | Prices from Chainlink USD feeds; swaps through Uniswap's Universal Router. Tagged `v3.0.0`. | [`audit/2026-09-22-v3-retirement.md`](../audit/2026-09-22-v3-retirement.md) |
| v4 Stage A | No prices at all: units proportional to reference supplies, so an index trades only when a supply changes. | [`audit/2026-09-30-v4-stage-a-retirement.md`](../audit/2026-09-30-v4-stage-a-retirement.md), [`audit/2026-10-06-v4-retirement.md`](../audit/2026-10-06-v4-retirement.md) |
| v4 Stage B | Other chains' native coins in ownerless vaults driven by proofs of Ethereum's finality. Tagged `stage-b-2026-10-07`. | [`audit/2026-10-07-stage-b-retirement.md`](../audit/2026-10-07-stage-b-retirement.md) |
| v5 | Creator-chosen weights, rebalanced at Pyth prices through a Dutch auction; one deployment on Ethereum, other chains' coins held as Wormhole copies. Its issue, redeem, fees and listings are the current design's. | [`design/2026-10-05-custom-weights.md`](../design/2026-10-05-custom-weights.md), [`design/2026-10-10-one-index-wormhole-legs.md`](../design/2026-10-10-one-index-wormhole-legs.md) |
| A second deployment | Since 2026-11-13 the same contracts are deployable on BNB Chain as on Ethereum, each chain holding its own tokens in kind and sharing nothing with the other. The BNB Chain deployment of 2026-10-07, deleted on 2026-10-13, restored without Pyth. | [`design/2026-11-13-bnb-chain-deployment.md`](../design/2026-11-13-bnb-chain-deployment.md) |
| A third deployment | Since 2026-11-21 the same contracts are deployable on Base: sixteen coins, thirteen of them copies Base's own bridge mints of coins on Ethereum's list. It reverses "no Base deployment for now" of 2026-10-18. | [`design/2026-11-21-base-deployment.md`](../design/2026-11-21-base-deployment.md) |
| Oracle-free rebalance | Since 2026-11-10 no contract reads a price: an executor names the units a rebalance settles at, and the index accepts them when a weighted gain in units clears a bar that falls with time. Pyth left the protocol, and came back on 2026-11-22 only as a check that can refuse a fill (the row below). The units' rule is still the current design's. | [`design/2026-11-10-oracle-free-rebalance.md`](../design/2026-11-10-oracle-free-rebalance.md), [`audit/2026-11-10-oracle-retirement.md`](../audit/2026-11-10-oracle-retirement.md) |

| Pyth's check, creation on the weights, changeable weights | Since 2026-11-22 a fill the units accept must also hold at Pyth's prices, a check that can only refuse; since 2026-11-23 an index is created within 5% of its weights at those prices, its creator can change the weights behind 7 days of notice, creating an index can issue its first shares in the same call (`createAndIssue`), and the owner or guardian may restart a rebalance a week after any fill. No mint, redeem or claim reads a price. The current design. | [`design/2026-11-22-pyth-check.md`](../design/2026-11-22-pyth-check.md), [`design/2026-11-23-changeable-weights.md`](../design/2026-11-23-changeable-weights.md) |

`WeightedHub` keeps v4's in-kind issue, redeem, claims and backing check; the zap and `MintRequests` carried over
unchanged. Each retirement record lists the review findings that went with the retired code and where the rest are
tested now. The brief Xindex was built from is in [`design/product-brief.md`](../design/product-brief.md).
