# Xindex

Xindex lets investors package a whole crypto portfolio into a single ERC-20 token. Anyone can create an index (any
name, any symbol, any mix of whitelisted tokens, a weighting rule), anyone can mint it with USDC or USDT, and anyone
can burn it back into USDC, USDT, WBTC or any other token. Every index is a plain ERC-20, fully backed in kind by the
tokens it represents, and rebalanced monthly by an on-chain market-cap rule that anyone can trigger.

This repository holds the smart contracts (Foundry). The web app lives elsewhere.

## Product brief

> we are looking to build a marketplace called xindex for investors, where they can create their
> whole crypto portfolio in one erc-20 token.
>
> 1. users come to xindex marketplace (the web app is already built, now we have to build the smart
>    contract), they choose coins that they are investing in, create a portfolio with their own logic
>    and create their whole investing logic (portfolio) in one erc-20 token. user creates a basket and
>    after that mints it, other users should also be able to mint that created index.
> 2. user should be able to name index whatever he wants and whatever symbol he decides to use, for
>    example: SYD and things like that.
> 3. we are looking to build a decentralized product.
> 4. we use minting and burning for creating and burning index.
> 5. users should be able to trade index to other coins, for example if someone created an index and
>    then wants to swap it to usdt or btc or any other coin they should be able to do that. every
>    created index is a classical erc-20 token.
> 6. usdt/usdc input, usdt/usdc output, depends on users. users will come to marketplace and create
>    their portfolio, after that they should be able to mint it with usdt or usdc. when they burn
>    their index they should get back the coin that they minted with.
> 7. we need to find a solution for layer-1 tokens.

v2 adds the rebalancing and index-price methodology from the team's Numbers model (`index_MODEL.numbers`): market-cap
weights, uncapped or capped with the largest coin at 30% and the second at most 20%. The coins in that model were
examples; the methodology is the requirement.

## Design decisions (v2)

| Topic | Decision |
|---|---|
| Chain | Ethereum mainnet |
| Swaps | Uniswap V3 via SwapRouter02; quotes via QuoterV2. V4 / Universal Router / aggregators are a drop-in replacement for the zap later. |
| Composition | Constituents fixed at creation. Units follow the index's methodology: `0` uncapped market cap, `1` capped market cap (30% / at most 20% / the rest by cap, at least 5 components). |
| Rebalancing | On-chain rule, no bots or keys. Anyone starts a rebalance 28 days after the last one; 2 days of notice; a 24-hour auction that any contract can fill; each component moves between half and double its units per rebalance. |
| Market data | Supplies on-chain (total supply minus excluded burn or lock wallets) or a timelocked reference supply for wrapped assets; prices are Uniswap V3 30-minute time-weighted averages against WETH. |
| Index price | The basket's value per index token, `IndexRule.navPerToken`, in WETH and USDC. For an uncapped index it equals the Numbers model's divisor price; for a capped index it replaces it. Display only. |
| Fees | None in v2. |
| Layer-1 coins | Only tokens that exist on mainnet can be components (WBTC, WETH, LINK, ...). Coins with no credible wrapper (ADA, XRP, ...) are out of scope until one exists. |
| Stable in / out | Mint with USDC or USDT. The burner chooses USDC, USDT or any other token at exit. Index tokens are fungible, so the protocol cannot know which stable a given holder used; economically the two are equivalent. |
| Decentralization | No admin has any power over funds, units or prices. The owner proposes listings and token data configs, which take effect after a public 2-day delay, and guardian changes, which take 7 days; a proposal not executed within 7 days of becoming ready expires. The guardian can cancel a pending listing or rebalance, start a rebalance that leaves a paused component untouched, or delist a token. Neither role can pause, upgrade or touch any index, and ownership cannot be renounced. |
| Frozen components | If a component's issuer pauses or blacklists transfers, holders take every other component out with `redeemSkipping` and collect the frozen one later with `claim`; the guardian rebalances around it with a keep mask. |

## Architecture

```
                  createIndex(name, symbol, tokens[], units[], methodology)
   creator ────────────────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexToken (ERC-20)
                                                                  │ listings + token configs      │ holds the basket
                                                                  │ (2-day delay), guardian,      │ issue / redeem in kind
                                                                  │ registry                      │ redeemSkipping / claim
                                                                  └──deploys──► IndexRule ◄───────│ start / cancel /
   anyone ── startRebalance ────────────────────────────────────────────────── (supplies,       │ executeRebalance
   executor ── executeRebalance ◄── flash-style callback ─────────────────────── V3 TWAPs,       │
                                                                                 weights, price)│
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Uniswap V3                   │
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                              │
                                      └──────── issue() / redeem() ───────────────────────────────┘
```

- `IndexToken` (`src/IndexToken.sol`) only ever moves amounts derived from supply and units. `issue(shares)` pulls
  `ceil(shares * units_i / 1e18)` of every component and mints; `redeem(shares)` burns and pushes
  `floor(shares * units_i / 1e18)`; `redeemSkipping` leaves chosen components as claims. `startRebalance`,
  `cancelRebalance` and `executeRebalance` run the rebalance: a snapshot of the rule's targets, a notice period, and an
  auction whose settlement stands only if every component still backs the new units. No oracle in any of these steps, no
  share price, nothing computed from balances, so there is no first-depositor / inflation attack and nothing for an
  admin to touch. Only initialized clones can issue, redeem or rebalance. Supports EIP-2612 `permit`.
- `IndexRule` (`src/IndexRule.sol`) is a stateless, view-only contract: token supplies, Uniswap V3 time-weighted prices,
  the uncapped and capped weights, rebalance targets, starting units and the index price.
- `IndexFactory` (`src/IndexFactory.sol`) is permissionless `createIndex`, a curated token whitelist where every token
  carries its market-data config behind a 2-day delay (`Ownable2Step` owner plus a guardian whose replacement takes 7
  days), and the registry (`isIndex`, `creatorOf`, `allIndexes`). Indexes are EIP-1167 clones deployed with CREATE2 from
  a salt over the creator, the starting composition and the methodology; `predictIndexAddress` returns the address
  before the transaction is sent.
- `IndexZap` (`src/IndexZap.sol`) is a stateless convenience router. `mintWithToken` buys exactly the basket with
  exact-output swaps; `burnToToken` redeems and sells every component into the chosen token; `burnToTokenWithPermit` does
  it in one transaction. Every path is checked, each leg can carry its own limit, amounts are measured as balance changes,
  and every call names the index's `rebalanceNonce` so a quote from before a rebalance cannot fill.

Invariant, for every component `i` of every index, forever:

```
token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
```

## How the flows work

**Create.** The creator picks whitelisted tokens, a methodology and a starting price in the UI. The app calls
`IndexRule.initialUnits(tokens, methodology, startPriceUsdc)` for units that already follow the rule (like the model's
1,000), shows `predictIndexAddress`, and calls `createIndex`. Name and symbol are free-form and not unique; the UI must
show the index address and `creatorOf` to avoid spoofing.

**Mint with USDC/USDT.** For each leg the app quotes with QuoterV2 `quoteExactOutput`, sets per-leg limits and the
overall `maxAmountIn`, reads `rebalanceNonce()`, and calls `mintWithToken(MintParams)`. Exact `shares` are minted;
unspent USDC comes back.

**Burn to USDC/USDT/anything.** The app quotes each leg with `quoteExactInput`, sets per-leg minimums and a non-zero
overall `minAmountOut`, passes `rebalanceNonce()`, and calls `burnToToken(BurnParams)` or `burnToTokenWithPermit`.

**Rebalance.**
1. 28 days after an index's creation or last rebalance, anyone calls `startRebalance(0)`. The index stores the rule's
   targets. For 2 days nothing changes; holders who disagree can leave.
2. A 24-hour auction follows. An executor contract calls `executeRebalance(data)`: it receives what the index no longer
   needs of each shrinking component and, inside its `onXindexRebalance` callback, must send back what the growing
   components need. The growing components' extra units are multiplied by a factor that falls from 1.5 to 0.9, so
   executors compete the fill toward fair value; a lone executor keeps at most 10% of the bought value.
3. If nobody fills, the auction expires and anyone can start a fresh snapshot.
4. The owner or guardian can cancel a rebalance; others must then wait 2 days to restart.

**Rebalance around a frozen component.** The guardian cancels and starts again with the component's bit in `keepMask`;
that component keeps its units and is never transferred.

**Exit while a component is frozen.** If, say, WBTC is paused, `redeem` and the zap revert. The holder calls
`redeemSkipping(shares, to, skipMask)` with the WBTC bit set: every other component arrives now and the WBTC amount is
recorded in `claimOf(holder, WBTC)`. Once WBTC transfers resume, `claim(WBTC, to)` pays it.

**Trade.** An index is a normal ERC-20 so it can be transferred or listed on any DEX. The burn path is the guaranteed exit.

**Direct, without the zap.** `issue`, `redeem`, `redeemSkipping` and `claim` on the index itself work for anyone who
already holds the components or shares.

## Frontend integration notes

- **Starting units.** `IndexRule.initialUnits(tokens, methodology, startPriceUsdc)`, with the price in raw USDC units
  (1,000 dollars is `1000e6`). Units must be `> 0` and `<= 2^96 - 1`. Max 20 components; keep it around 10 for gas.
  The capped methodology needs at least 5.
- **Index price.** `IndexRule.navPerToken(index)` returns WETH wei and raw USDC per whole index token from 30-minute
  time-weighted prices. Show it as the index price. It lags fast moves; never use it, or a thin DEX pool of the index
  token, as an oracle.
- **Weights.** `IndexRule.weights(tokens, methodology)` returns current target weights (1e18 = 100%), prices and supplies.
- **Rebalance status.** Show `lastRebalance + MIN_REBALANCE_INTERVAL`, and a "rebalance due" button when that time has
  passed, no rebalance is pending (`pendingRebalance().eta == 0`) and `restartAllowedAt` has passed. Before starting,
  `previewTarget(0)` shows the targets and turnover; a turnover below `MIN_TURNOVER` reverts. During the notice, show
  `pendingRebalance()` and the auction start; during the auction, `currentMultiplier()` and `previewRebalance()`.
- **Zap calls take a params struct.** `MintParams {index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to,
  deadline}` with `MintLeg {path, maxAmountIn}`, and `BurnParams {index, expectedNonce, shares, tokenOut, minAmountOut,
  legs, to, deadline}` with `BurnLeg {path, minAmountOut}`. `legs` has one entry per component, in component order.
  `expectedNonce` is `rebalanceNonce()` when the legs were quoted; after a rebalance, re-quote.
- **Paths.** Uniswap V3 packed paths: `token(20) | fee(3) | token(20) [| fee(3) | token(20)]`. For **mint**, a leg's path
  is exact-output encoded: starts with the component, ends with the stable (e.g. `WBTC 500 WETH 500 USDC`). For
  **burn**, it is exact-input encoded: starts with the component, ends with `tokenOut`. Use an empty path when the
  component *is* the stable or `tokenOut`. Burn legs whose amount rounds to zero are skipped.
- **Slippage.** Set a limit on every leg, not only the total. A leg limit of 0 means "overall limit only". The overall
  burn limit must be non-zero. Legs share pools, since every leg crosses the dollar currency's WETH pool, so summed
  per-leg quotes are optimistic: a little on mainnet, several percent on thin pools such as the Sepolia test market. An
  `eth_call` of the whole zap call returns the exact amount.
- **Check quotes against an independent price.** Compare each Uniswap quote with a reference price and refuse to sign
  when they diverge beyond a threshold. Send transactions through a private relay and use short deadlines.
- **Approvals.** USDC supports `permit`; USDT does not (plain `approve`). Index tokens support `permit`. Approve exact
  amounts.
- **Fee-charging currencies are unsupported.** Zap calls revert with `TransferShortfall`. Simulate every transaction
  first and offer the direct `redeem` or `redeemSkipping` exit.
- **Label pausable components.** WBTC can be paused by its custodian. Show that on every index that holds it, and surface
  `redeemSkipping` plus any pending `claimOf` balance.
- **Show pending proposals.** A token or config change becomes effective only between `ListingProposed` plus
  `LISTING_DELAY` and 7 days after that (`pendingTokenConfig` shows it), and a new guardian only after `GuardianProposed`
  plus `GUARDIAN_DELAY`. A config change reshapes future rebalances of every index holding the token.
- **Returned components.** If the router sells less of a component than the zap gave it, that part goes to the
  recipient and `ComponentReturned` is emitted. Show it on the receipt.
- **Value an index from units, not balances.** Never derive a price from `balanceOf(index)` and `totalSupply()`.
- **Events.** `IndexFactory`: `IndexCreated`, `ListingProposed`, `ListingCancelled`, `TokenConfigured`,
  `TokenWhitelisted`, `GuardianProposed`, `GuardianChangeCancelled`, `GuardianSet`. `IndexToken`: `Issued`, `Redeemed`,
  `ClaimRecorded`, `Claimed`, `RebalanceStarted`, `RebalanceCancelled`, `Rebalanced`. `IndexZap`: `ZapMint`, `ZapBurn`,
  `ComponentReturned`.
- **Errors worth handling.** `IndexZap`: `ZeroAmount`, `InvalidRecipient`, `LegCountMismatch`, `BadPath`,
  `InsufficientBudget`, `InsufficientOutput`, `TransferShortfall`, `StaleRebalanceNonce`, plus the router's
  `Too much requested` / `Too little received`. `IndexToken`: `InvalidSkipMask`, `NothingToClaim`, `RebalanceTooSoon`,
  `RebalancePending`, `TurnoverTooLow`, `InvalidKeepMask`, `Unauthorized`, `RebalanceNotReady`, `RebalanceExpired`,
  `RebalanceUnderfunded`. `IndexRule`: `InvalidPool`, `PoolHistoryTooShort`, `InvalidSupplyConfig`, `ZeroSupply`,
  `ZeroPrice`, `TooFewComponentsForCapped`.

## Whitelist policy

Standard ERC-20s only: no fee-on-transfer, rebasing, or ERC-777/callback tokens; 6-18 decimals; fixed-supply or
governance-minted supply; the address must be a contract. `issue` verifies the received amount. A component that can be
paused or blacklisted, such as WBTC, must be labelled in the app. USDC and USDT are fine to mint *with* but should not be
*components*.

Every listed token carries a config that the rule validates:

- **Pool:** the Uniswap V3 factory's own pool for the token and WETH, at the fee tier the config names, with at least 200
  observation slots. A pool below that must be prepared first: anyone can call `increaseObservationCardinalityNext(200)`,
  and the ring grows as the pool trades. On 2026-09-16 the tBTC/WETH 0.3% pool had 60 slots.
- **Supply:** on-chain total supply minus up to 8 excluded addresses (burn or lock wallets), or a reference supply.
  Wrapped assets need a reference supply: on-chain WBTC is the wrapped float (116,132 BTC on 2026-09-16), not bitcoin's
  supply. Reference supplies drift and are refreshed with a config change.
- WETH itself has no pool and needs a reference supply.

Listings and config changes take two steps: the owner calls `proposeListing(token, config)`, and from `LISTING_DELAY`
(2 days) until a further `PROPOSAL_WINDOW` (7 days) anyone can call `executeListing`; after that the proposal expires.
Until then the owner or the guardian can `cancelListing` it, and either can `delist` a token at any time. Delisting only
affects indexes created afterwards and keeps the config existing indexes rebalance with.

## Known limitations

- Airdrops, rewards and governance votes that accrue to tokens held by an index cannot be claimed or used; by design
  there is no admin who could sweep them.
- A rebalance clears only when the value it trades covers gas and swap costs many times over, so small indexes on mainnet
  rarely rebalance. Unfilled auctions expire harmlessly.
- Without competing executors, a filler can wait for the 0.9 floor and keep up to 10% of the bought value; the notice
  period also lets traders position ahead of a public rebalance.
- A permanently frozen component needs the guardian's keep mask at every rebalance.
- If a multi-hop burn leg stops partway, the intermediate token stays in the Uniswap router rather than the zap.
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`). The factory's deployment code is close to the EIP-3860
  initcode limit. Re-check both before deploying to any other chain.

## Mainnet addresses

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| AAVE | `0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9` |
| tBTC v2 | `0x18084fbA666a33d37592fA2633fD49a74DD93a88` |
| Uniswap SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Uniswap QuoterV2 | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| Uniswap V3 factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| USDC/WETH 0.05% pool | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |
| IndexFactory / IndexRule / IndexZap | not deployed yet |

Token pools used by the default whitelist and the fork tests are listed in `test/fork/ForkAddresses.sol` and
`ARCHITECTURE.md`.

## Development

```bash
forge build --sizes
forge fmt
forge test                      # unit, fuzz, invariant and security regression tests, no RPC needed
forge coverage                  # 100% on every file

# end-to-end against real Uniswap V3 / USDC / USDT / WBTC (skipped when the env var is unset)
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# non-archive RPCs only serve recent state; override the pinned block:
MAINNET_RPC_URL=https://... FORK_BLOCK=<recent block> forge test --match-path 'test/fork/*'
```

CI (`.github/workflows/test.yml`) checks that every submodule commit matches `foundry.lock`, then runs fmt,
build and tests with a pinned Foundry version. Pushes to `main` fail until a `MAINNET_RPC_URL` repository secret
exists, so the fork tests always run there; it needs an archive node for the pinned fork block.

### Deploy

Never put a private key in `.env`. Import the deployer key once into an encrypted keystore, or use a hardware
wallet with `--ledger`:

```bash
cast wallet import deployer --interactive
cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
source .env
forge script script/Deploy.s.sol --rpc-url mainnet --account deployer --sender <deployer address> --broadcast --verify
```

`OWNER` and `GUARDIAN` are required and must differ. On mainnet the owner must be a contract that is not an
EIP-7702 delegated account, and a Safe must need at least two signatures. `SWAP_ROUTER`, `WETH`, `UNISWAP_V3_FACTORY`
and `USDC` default to the mainnet contracts on chain 1 and are required anywhere else. The factory's constructor checks
that the USDC/WETH 0.05% pool can serve a 30-minute price.

Listing components takes two runs of `script/ConfigureWhitelist.s.sol`, or the equivalent calls through the Safe:

```bash
# as the owner: propose every entry that is not pending and not already listed with exactly its config
LISTING_MODE=propose FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <owner> --broadcast
# owner is a Safe: print the same proposals as calldata to sign in the Safe app (any account, nothing is broadcast)
LISTING_MODE=safe FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account: execute every proposal that is due
LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`WHITELIST` is `default` for the mainnet list, or comma-separated entries `token:fee[:referenceSupply[:excluded|excluded...]]`,
where `fee` is the fee tier of the token's WETH pool, or 0 for WETH. The default list is WBTC (0.05%, bitcoin's
supply), WETH (ether's supply), LINK and UNI (0.3%, circulating supplies), and tBTC (0.3%, on-chain supply); the
reference supplies are CoinGecko's circulating figures from 2026-09-15. Propose mode skips any entry the rule would
reject, such as tBTC while its pool has too few observation slots, and logs why. Execute mode never proposes anything,
so a listing the guardian cancelled stays cancelled until the owner proposes it again on purpose. For a local stack:
`anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against `http://127.0.0.1:8545`.

In the Safe app, safe mode's output becomes one Transaction Builder batch: one transaction per logged line, each to the
factory with value 0 and the line as custom data. Two signers sign it, and one executes it.

### Testnet (Sepolia)

Sepolia runs the mainnet contracts and timing constants on a test market. `script/testnet/SetupTestMarket.s.sol` deploys
stand-ins for USDC, WBTC, LINK, UNI and AAVE as `FaucetToken`s, where any account can `drip()` a small amount once a day,
and gives each a Uniswap V3 WETH pool at mainnet prices from 2026-09-16 with 200 oracle slots. Only Sepolia ETH is needed.
A rehearsal on an anvil fork of Sepolia used 48.7M gas for `create`, 3.4M for `seed`, 10.2M for the deploy and 0.7M to
execute the listings, plus 0.7 ETH of pool liquidity: 0.89 ETH in total at 3 gwei, 1.02 ETH at 5 gwei, 1.33 ETH at
10 gwei. The Safe signer who executes the listing batch pays about 0.6M gas more.

| Sepolia contract | Address |
|---|---|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| Uniswap SwapRouter02 | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` |
| Uniswap QuoterV2 | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| Uniswap V3 factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap NonfungiblePositionManager | `0x1238536071E1c677A632429e3655c799b22cDA52` |
| IndexFactory | `0x3541347212cc20603F6dBBC49da3fFfE75e12CB1` |
| IndexRule | `0x09DA95249a049a121B0dC072E109643fde34a234` |
| IndexToken implementation | `0x0EB86aeFd70f63B181001ff00F2bF0BC6F12a311` |
| IndexZap | `0xf021fA4D07E217a005D331ed573bF8E4a2202E1F` |
| Factory owner (Safe, 2 of 2) | `0x11a9bF6866f4a35E6Ac854C1b4AF52B3D098a719` |
| Guardian | `0x8cef9aAa300aA0A1EA5A0D8593EFc9ADED7B55a1` |
| tUSDC / its 0.05% WETH pool | `0x740235f52c8Ba428436F91a28A1A1A93B9A1907c` / `0x67347BD955E225f68F6583e09cf59e4CeA283D03` |
| tWBTC / its 0.05% WETH pool | `0x15559fc37C00e7d0608F8D8183e1D762405df30c` / `0x4cc282f213CDCB03e05dC08D10EC4Cc0f007578D` |
| tLINK / its 0.3% WETH pool | `0x7d32b6Eb66849eBFc6eaA6a957A29a7d649498ab` / `0x59999Ac1D6652e84b91F8A36583ec60ea7C693Ea` |
| tUNI / its 0.3% WETH pool | `0x48b784c154CAE3E76528EDA9Dc13F20a83C57781` / `0x59038Fbc04da127199e7A8f7e00f4B45F686eCEF` |
| tAAVE / its 0.3% WETH pool | `0x172a586996A8C495dBe3A4dD79667e63E9109D88` / `0xdf3c0aF02C9CD35c836C933bD39B39D60E8596Fe` |

Deployed on 2026-09-16 from commit `8c28c7d`, with 0.8 WETH in the tUSDC pool and 0.25 WETH in each other pool. The Safe
proposed tWBTC, WETH, tLINK, tUNI and tAAVE the same day; any account can execute the listings from 2026-09-18 13:05 UTC
until 2026-09-25 13:05 UTC.

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
DEPLOYER=$(cast wallet address --account sepolia-deployer)

# 1. tokens and priced pools, then liquidity in a later block: 0.3 WETH in the tUSDC pool, 0.1 WETH in each other
MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
MARKET_MODE=seed MARKET_TOKENS=<logged by create> forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 2. at least 30 minutes after create, so the pools can serve a 30-minute price
OWNER=<Safe> GUARDIAN=<guardian> USDC=<tUSDC logged by seed> WETH=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
  UNISWAP_V3_FACTORY=0x0227628f3F023bb0B980b67D528571c95c6DaC1c SWAP_ROUTER=0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E \
  forge script script/Deploy.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 3. print the listing proposals and sign them as one batch in the Safe app
LISTING_MODE=safe FACTORY=<factory> WHITELIST=<logged by seed> forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia

# 4. 2 to 9 days later, from any account
LISTING_MODE=execute FACTORY=<factory> WHITELIST=<same> forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
```

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts, so testers can call `drip()` from Etherscan.
`USD_POOL_WETH` and `TOKEN_POOL_WETH` (in wei) change the liquidity `seed` adds.

- The test pools are shallow and nobody arbitrages them. In the rehearsal a zap mint cost 0.6% over the basket's value
  at $10, 2% at $50 and 4 to 6% at $100, and $1,000 could not be quoted. Trades move prices, and the rule's 30-minute
  price lags them.
- Timing is mainnet's: listings take 2 days, and an index can start its first rebalance 28 days after creation, followed
  by 2 days of notice and a 24-hour auction. `test/fork/RebalanceExecutorV3.sol` fills auctions through the Sepolia
  router.
- Faucet tokens have no value, and their supply grows with every drip, so their listings use fixed reference supplies.

## Layout

```
src/IndexToken.sol            index implementation (ERC20 + in-kind issue, redeem, redeemSkipping, claim, rebalance)
src/IndexRule.sol             market data, weights, rebalance targets, index price (view-only)
src/IndexFactory.sol          listing delay, token configs, guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              Uniswap V3 mint/burn router with per-leg limits
src/interfaces/               IIndexToken, IIndexFactory, IIndexRule, IRebalanceExecutor, Uniswap subsets
src/libraries/                PathLib, TickMath (vendored from Uniswap v4-core), Methodology
test/*.t.sol                  unit, fuzz, invariant and script tests
test/Security.t.sol           one regression test per security review finding
test/mocks/                   mock tokens, routers, Uniswap V3 pools, market fixture and rebalance executor, with their own tests
test/fork/                    mainnet fork tests, including rebalancing through real Uniswap pools and security regressions on real tokens
script/                       Deploy, ConfigureWhitelist
script/testnet/               SetupTestMarket and FaucetToken for the Sepolia test market
```

## Not in v2 (candidates for later)

ETH in/out (`mintWithETH` / `burnToETH`), `createAndMint` in one call, `mintWithTokenPermit` for USDC, creator or
protocol fees, constituent changes, a Chainlink price adapter for tokens with thin pools, per-pair partial-fill auctions,
a backstop executor or trigger reminder, V4 / aggregator zap, synthetic exposure for L1 coins that have no wrapper.
