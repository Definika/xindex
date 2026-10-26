# Version history

| Version | Design | Record |
|---|---|---|
| v2 | A market-cap index with on-chain rebalancing, priced from Uniswap V3 pool averages. | |
| v3 | Prices from Chainlink USD feeds; swaps through Uniswap's Universal Router. Tagged `v3.0.0`. | [`audit/2026-09-22-v3-retirement.md`](../audit/2026-09-22-v3-retirement.md) |
| v4 Stage A | No prices at all: units proportional to reference supplies, so an index trades only when a supply changes. | [`audit/2026-09-30-v4-stage-a-retirement.md`](../audit/2026-09-30-v4-stage-a-retirement.md), [`audit/2026-10-06-v4-retirement.md`](../audit/2026-10-06-v4-retirement.md) |
| v4 Stage B | Other chains' native coins in ownerless vaults driven by proofs of Ethereum's finality. Tagged `stage-b-2026-10-07`. | [`audit/2026-10-07-stage-b-retirement.md`](../audit/2026-10-07-stage-b-retirement.md) |
| v5 | Creator-chosen weights, rebalanced at Pyth prices through a Dutch auction; one deployment on Ethereum, other chains' coins held as Wormhole copies. The current design. | [`design/2026-10-05-custom-weights.md`](../design/2026-10-05-custom-weights.md), [`design/2026-10-10-one-index-wormhole-legs.md`](../design/2026-10-10-one-index-wormhole-legs.md) |

`WeightedHub` keeps v4's in-kind issue, redeem, claims and backing check; the zap and `MintRequests` carried over
unchanged. Each retirement record lists the review findings that went with the retired code and where the rest are
tested now. The brief Xindex was built from is in [`design/product-brief.md`](../design/product-brief.md).
