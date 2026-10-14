# Swap venues: PancakeSwap and THORChain on the swap rail

2026-10-06. The owner asked to add PancakeSwap and THORChain "only for swap rail", safely. The swap rail is the part
that turns a stablecoin into a basket and back: the zap on Ethereum, and the app around it. Nothing here touches the hub,
the factory, the vaults or the index's components. This record states what was built, what was refused and why, and what
stays open. Its review ids are `SV-*` (`audit/2026-10-06-swap-venues-review.md`).

Sources: on-chain reads at Ethereum block 26,134,263 through a public archive RPC; the verified source of PancakeSwap's
v3 Universal Router on Etherscan; THORNode's source on GitLab (`develop`); and the live THORNode API
(`gateway.liquify.com/chain/thorchain_api`; the older `thornode.ninerealms.com` no longer resolves). Where only docs
say something, it says so.

## 1. Decisions

| | Decision |
|---|---|
| PancakeSwap | A third venue per zap leg: a PancakeSwap V3 path, run through PancakeSwap's v3 Universal Router with the zap's usual pre-fund, sweep and measurement, and ended by `WRAP_ETH` (SV-1). V3 only: PancakeSwap's v4 (Infinity) is not on Ethereum. |
| THORChain | App-side only, from the user's own wallets, never from a contract. `swaprail/thorchain.mjs` is the reference planner the app adopts. No Xindex contract calls THORChain. |

This amends "Execution through Uniswap's Universal Router 2.0.0" (AGENTS.md, product decisions): Uniswap's router
stays, and PancakeSwap's joins it for the legs that name it.

## 2. PancakeSwap

### What is deployed on Ethereum

| Contract | Address | Evidence |
|---|---|---|
| v3 Universal Router | `0x65b382653f7C31bC0Af67f188122035461ec9C76` | Etherscan-verified "PancakeSwap: Universal Router"; runtime code hash `0xdb8dfdb9…d3f6`, pinned by `test/fork/MainnetAddresses.fork.t.sol` |
| V3 factory | `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` | `poolDeployer()` is the deployer below; tiers 100, 500, 2500, 10000 (no 3000) |
| V3 pool deployer | `0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9` | `factoryAddress()` is the factory |
| V3 pool init code hash | `0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2` | a router constructor argument; CREATE2 from it gives `factory.getPool(WETH, USDT, 500)` |
| QuoterV2 | `0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997` | factory, deployer and WETH match; the fork tests size legs with it |

The router's immutables (the deployer and init code hash above, PancakeSwap's own Permit2 `0x31c2…c768` and WETH) are
in its code, so the pinned code hash fixes which pools a PancakeSwap path can reach. No public repository holds this
router's version (`pancake-v3-contracts` deleted its router at `98684794`), and no audit of it was found: the deployed
source is the reference (SV-I2).

### Against Uniswap's router

The commands the zap uses have Uniswap's bytes and input layouts: `V3_SWAP_EXACT_IN` 0x00, `V3_SWAP_EXACT_OUT` 0x01,
`SWEEP` 0x04, and `payerIsUser` false pays from the router's own balance. So the zap's pattern carries over unchanged.
Its exact-output swap is stricter than Uniswap's V4: it checks `amountOutReceived == amountOut`. Four differences shape
the integration:

1. **SV-1: one wei can block every PancakeSwap leg.** The router's `receive` takes ether from anyone, and after the last
   command `execute` sends its whole ether balance to the caller with solmate's `safeTransferETH`, reverting if that
   fails. The zap has no `receive`, by rule. So one wei sent to the router reverts every PancakeSwap leg of every zap until
   another caller's transaction carries it away. Fix: every PancakeSwap call ends with `WRAP_ETH(ADDRESS_THIS,
   CONTRACT_BALANCE)`, which turns the router's ether into WETH it keeps, leaving nothing to send. Shown on the
   deployed router (`testFork_SV1_strayEtherInThePancakeRouterCannotBlockALeg`, which fails with `ETH_TRANSFER_FAILED`
   when the wrap is removed) and on the mock that follows its source.
2. **Command bytes from 0x10 up differ** (0x10 is `OWNER_CHECK_721` there, `V4_SWAP` at Uniswap), so PancakeSwap has its
   own library, `PancakeRouterCommands`, and never Uniswap's constants.
3. **No `poolManager()`.** PancakeSwap's router is a separate immutable, `PANCAKE_ROUTER`, and a refused recipient.
4. **The owner can stop it, not rob it** (SV-I1). The router is Ownable and Pausable; its owner is PancakeSwap's Safe
   `0x2183…FC02` (3 of 7), which also owns the V3 factory, and the factory can attach a liquidity-mining contract that
   every pool calls during a swap without try/catch. Either can make PancakeSwap legs revert. Neither can take a zap
   user's funds: the zap pre-funds only what a leg may spend and sweeps the rest back in the same call, so a stopped
   router reverts the whole mint or burn with nothing stranded (`testFork_pancake_aPausedRouterStopsOnlyItsLegs`). The
   app then routes through Uniswap.

PancakeSwap's SmartRouter was rejected: its exact-output swap pays only from `msg.sender` through an allowance, which the
zap never grants, and its exact-input pays from the router only for `CONTRACT_BALANCE`, which spends strays too.

### Liquidity: what it is worth

At block 26,134,263, the USD that moves the price 2% in the best pool (in-range liquidity taken as flat, so
approximate):

| Coin | PancakeSwap V3 | Uniswap V3 |
|---|---|---|
| WETH | ≈ $15.9k (USDT 0.05%) | ≈ $9.75M |
| WBTC | ≈ $6.2k (WETH 0.25%) | ≈ $2.96M |
| CAKE | **≈ $1.7k (WETH 0.25%)** | ≈ $43 |
| LINK, ENA, PENDLE, WLD, ZRO | $133 or less | from $0.8k |
| the other 19 listed coins | no pool, or no liquidity | |

PancakeSwap matters for one listed coin: **CAKE**, whose Uniswap depth is about $43, so a CAKE leg had no workable
venue before. For the rest Uniswap is hundreds of times deeper, and the app should keep routing them there. Depth
changes; the app quotes both venues per leg and picks.

## 3. THORChain

### Why not a contract

THORChain swaps across chains asynchronously: a deposit on Ethereum, the output on another chain minutes later. The zap
measures what a user receives inside its own call, so THORChain could only ever sit after a burn, as a deposit the zap
makes. That shape fails on THORChain's own rules (THORNode source, `ethereum_block_scanner.go` and
`smartcontract_log_parser.go`):

- A deposit is attributed to the transaction's signer, and one made inside any contract other than the router is read
  only while the network setting `EVMDISABLECONTRACTWHITELIST` is 1 (it is today) and only if the transaction emits at
  most 200 logs. Otherwise it is ignored, and the funds are lost (SV-I3). A burn of about 35 components exceeds 200 logs.
- The router credits whatever address is named as the vault; THORChain's six vaults rotate about every three days, so
  the caller must supply one and the zap cannot check it.
- A router migration is prepared: v6.1 is deployed on Ethereum (`0x00dc…f1d4`) and already live on AVAX and BASE. A zap
  pinned to v4.1 would break when Ethereum moves.
- Outbound into a contract is limited to about 40 whitelisted aggregators, carries ether only on Ethereum, and the docs
  say "Do not swap to smart contract addresses". A plain ERC-20 output to the zap, an index or `MintRequests` would
  arrive as a stray balance and stay there.
- Multi-week halts happen: after the threshold-signature exploit of 15 May 2026, trading stayed halted for 39 days.

### What was built: `swaprail/thorchain.mjs`

A planner the app adopts, with no dependency. It signs and sends nothing, and fails closed.

- **Exit** (`planExitFromEthereum`): after `burnToToken` pays the user USDC, USDT, ETH or WBTC, swap it from the user's
  own Ethereum account to another chain's coin at the user's own address there: BTC, or BNB or TRX to fund a vault-coin
  mint on BNB Chain or TRON. It returns the user's transactions: approve the router (reset first, as USDT needs), then
  `router.depositWithExpiry` with `tx.to` the router itself.
- **Fund** (`planFundToEthereum`): before a mint, swap BTC, LTC, BCH or DOGE to USDC, USDT, ETH or WBTC at the user's own
  Ethereum account; the user then mints with the zap.

Every plan refuses unless all of these hold:
- two distinct THORNode endpoints agree on the router, both list the quote's vault as active, and neither reports a
  halt;
- every endpoint quotes the swap, the quotes name one vault and expect outputs within `maxSpreadBps` (1%) of each
  other, so no single endpoint sets the limit, the deadline or the fee check (CF-2, audit of 2026-10-13);
- the Ethereum router is v4.1, which the module pins;
- the sender and the destination are not contracts;
- each quote resolves the output to the asset asked for, lives at least five more minutes and at most an hour, carries
  a numeric fee of at most `maxFeeBps`, and the amount clears its recommended minimum and the dust threshold.

The module writes the memo itself, `=:ASSET:DEST[/REFUND]:LIM/1/0`, rather than taking THORNode's. The limit is the
lowest expected output the endpoints quote, less `slippageBps`, so a worse fill is refunded, and from Ethereum the user
is the refund address. A Bitcoin memo must fit OP_RETURN's 80 bytes, so there the asset is written `CHAIN.TICKER`. Two
checks make that safe: every endpoint, asked to quote that very ticker, must resolve it to the full asset id (CF-8;
the first version asked about the full id only, which proved nothing about the ticker), and the refund goes to the
sending wallet. If THORNode ever stops resolving a ticker in a quote, the fund flow refuses rather than guesses; check
it against a live node with `swaprail/check-live.mjs` before relying on it.

`node --test swaprail/` runs its tests on live THORNode responses of 2026-10-06. CI runs it, and eight mutants of its
refusals were caught. `swaprail/check-live.mjs` plans both flows read-only against a live THORNode; it ran on
2026-10-06.

## 4. Open

- THORChain needs a second independent THORNode endpoint for the app: only one public endpoint answered on 2026-10-06.
  Run one, or pay for a second provider. The module refuses with fewer than two.
- When Ethereum moves to THORChain's router v6.1, review its deposit semantics before adding it to the pinned set:
  ERC-20s go straight to the vault, and an expiry of 0 means none. Until then every Ethereum plan refuses, as intended.
- PancakeSwap's router source commit and audit are unknown (SV-I2). Its code hash is pinned; a new deployment means a
  new zap.
- Liquidity was a snapshot. Re-measure before launch, as `test/fork/WeightedHub.fork.t.sol` does for Uniswap.
