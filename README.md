# Xindex

Xindex lets investors package a whole crypto portfolio into a single ERC-20 token. Anyone can
create an index (any name, any symbol, any mix of whitelisted tokens), anyone can mint it with
USDC or USDT, and anyone can burn it back into USDC, USDT, WBTC or any other token. Every index is
a plain ERC-20 and is fully backed, in kind, by the tokens it represents.

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

## Design decisions (v1)

| Topic | Decision |
|---|---|
| Chain | Ethereum mainnet |
| Swaps | Uniswap V3 via SwapRouter02; quotes via QuoterV2. V4 / Universal Router / aggregators are a drop-in replacement for the zap later. |
| Composition | Fixed at creation. No rebalancing in v1. |
| Fees | None in v1. |
| Layer-1 coins | Only tokens that exist on mainnet can be components (WBTC, WETH, LINK, ...). Coins with no credible wrapper (ADA, XRP, ...) are out of scope until one exists. |
| Stable in / out | Mint with USDC or USDT. The burner chooses USDC, USDT or any other token at exit. Index tokens are fungible, so the protocol cannot know which stable a given holder used; economically the two are equivalent. |
| Decentralization | No admin has any power over funds. The owner proposes component listings, which take effect only after a public 2-day delay, and guardian changes, which take 7 days; a proposal that is not executed within 7 days of becoming ready expires. The guardian can cancel a pending listing or delist a token, and keeps those powers while its replacement is pending. Neither role can pause, upgrade or touch any index, and ownership cannot be renounced. |
| Frozen components | If a component's issuer pauses or blacklists transfers, holders take every other component out with `redeemSkipping` and collect the frozen one later with `claim`. |

## Architecture

```
                 createIndex(name, symbol, tokens[], units[])
   creator ───────────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexToken (ERC-20)
                                                             │  listings (2-day delay),           │ holds the basket
                                                             │  guardian, registry                │ issue / redeem in kind
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Uniswap V3                   │ redeemSkipping / claim
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                              │
                                      └──────── issue() / redeem() ───────────────────────────────┘
```

**In-kind core, swap layer on top.**

- `IndexToken` (`src/IndexToken.sol`) only ever moves the exact basket. `issue(shares)` pulls
  `ceil(shares * units_i / 1e18)` of every component and mints; `redeem(shares)` burns and pushes
  `floor(shares * units_i / 1e18)`. `redeemSkipping(shares, to, skipMask)` does the same but leaves the
  components selected in `skipMask` in the index as a claim that the redeemer collects later with `claim`.
  No oracle, no share price, nothing computed from balances, so there is no first-depositor / inflation attack
  and nothing for an admin to touch. Only initialized clones can issue or redeem. Supports EIP-2612 `permit`.
- `IndexFactory` (`src/IndexFactory.sol`) is permissionless `createIndex`, a curated token whitelist with a
  2-day listing delay (`Ownable2Step` owner plus a guardian whose replacement takes 7 days), and the registry (`isIndex`, `creatorOf`,
  `allIndexes`). Indexes are EIP-1167 clones deployed with CREATE2 from a salt over the creator and the full
  composition, so an address always holds the basket it was created with; `predictIndexAddress` returns it
  before the transaction is sent.
- `IndexZap` (`src/IndexZap.sol`) is a stateless convenience router. `mintWithToken` buys exactly the basket
  for `shares` with exact-output swaps and refunds the unspent input in one transfer. `burnToToken` redeems and
  sells every component into the chosen token; `burnToTokenWithPermit` does it in one transaction with a permit
  signature. Every swap path is checked to start at the component and end at the user's token, each leg can
  carry its own limit, and what the user pays and receives is measured as balance changes inside the call.
  If the router sells less of a component than it was given, the unsold part goes to the recipient.
  Anyone can deploy a competing zap; the index contracts do not depend on it.

Invariant, for every component `i` of every index, forever:

```
token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
```

## How the flows work

**Create.** The creator picks whitelisted tokens and target weights in the UI. The frontend converts weights
to `units` (raw token amount, in the token's own decimals, backing one whole index token), shows the address
from `predictIndexAddress`, and calls `createIndex`. Example basket "0.001 WBTC + 0.01 WETH + 1 LINK per token"
is `units = [100000, 1e16, 1e18]`. Name and symbol are free-form and not unique; the UI must show the index
address and `creatorOf` to avoid spoofing. The same creator cannot create the exact same index twice.

**Mint with USDC/USDT.** For each component leg the frontend quotes with QuoterV2 `quoteExactOutput`, sets that
leg's `maxAmountIn` a small margin above its quote, and sets the overall `maxAmountIn` from the sum. The user
approves the zap and calls `mintWithToken(MintParams)`. Exact `shares` are minted; unspent USDC comes back.

**Burn to USDC/USDT/anything.** The frontend quotes each leg with `quoteExactInput`, sets each leg's
`minAmountOut` a margin below its quote, and sets a non-zero overall `minAmountOut`. The user either approves the
zap and calls `burnToToken(BurnParams)`, or signs a permit and calls `burnToTokenWithPermit` in one transaction.

**Exit while a component is frozen.** If, say, WBTC is paused, `redeem` and the zap revert. The holder calls
`redeemSkipping(shares, to, skipMask)` on the index with the WBTC bit set: every other component arrives now and
the WBTC amount is recorded in `claimOf(holder, WBTC)`. Once WBTC transfers resume, `claim(WBTC, to)` pays it.

**Trade.** An index is a normal ERC-20 so it can be transferred or listed on any DEX. The burn path above is the
guaranteed exit into any token that has Uniswap V3 liquidity against the components.

**Direct, without the zap.** `issue`, `redeem`, `redeemSkipping` and `claim` on the index itself work for anyone
who already holds the components or shares.

## Frontend integration notes

- **Units from weights.** `units_i = floor(w_i * targetPrice / p_i * 10^dec_i)` where `w_i` sums
  to 1, `targetPrice` is the desired USD price of one index token and `p_i` the component price.
  Units must be `> 0` and `<= 2^96 - 1`. Max 20 components; keep it around 10 for gas.
- **Zap calls take a params struct.** `MintParams {index, tokenIn, maxAmountIn, shares, legs, to, deadline}` with
  `MintLeg {path, maxAmountIn}`, and `BurnParams {index, shares, tokenOut, minAmountOut, legs, to, deadline}` with
  `BurnLeg {path, minAmountOut}`. `legs` has one entry per component, in component order.
- **Paths.** Uniswap V3 packed paths: `token(20) | fee(3) | token(20) [| fee(3) | token(20)]`.
  For **mint**, a leg's path is exact-output encoded: starts with the component, ends with the stable
  (e.g. `WBTC 500 WETH 500 USDC`; tBTC routes `tBTC 3000 WETH 500 USDC`). For **burn**, it is exact-input
  encoded: starts with the component, ends with `tokenOut`. Use an empty path when the component *is* the
  stable or `tokenOut`. Burn legs whose amount rounds to zero are skipped.
- **Slippage.** Set a limit on every leg, not only the total, so a sandwich cannot spend the whole tolerance on
  the thinnest pool. A leg limit of 0 means "overall limit only". The overall burn limit must be non-zero. Legs
  share pools (everything crosses WETH/stable), so summed per-leg quotes are a little optimistic.
- **Check quotes against an independent price.** Compare each Uniswap quote with a reference price such as
  Chainlink and refuse to sign when they diverge beyond a threshold; otherwise a quote taken from a pool someone
  just moved is accepted. Send transactions through a private relay and use short deadlines.
- **Approvals.** USDC supports `permit`; USDT does not (plain `approve`). Index tokens support `permit`, so
  `burnToTokenWithPermit` burns with one signature and one transaction. Approve exact amounts.
- **Fee-charging currencies are unsupported.** If a currency charges a transfer fee (USDT has a dormant switch),
  zap calls revert with `TransferShortfall`. Simulate every transaction first and offer the direct `redeem` or
  `redeemSkipping` exit.
- **Label pausable components.** WBTC can be paused by its custodian. Show that on every index that holds it, and
  surface `redeemSkipping` plus any pending `claimOf` balance.
- **Show pending proposals.** A token becomes usable only between `ListingProposed` plus `LISTING_DELAY` and 7 days
  after that, and a new guardian only after `GuardianProposed` plus `GUARDIAN_DELAY`. Show both, and treat indexes
  that contain a freshly listed token with extra caution.
- **Returned components.** If the router sells less of a component than the zap gave it, that part goes to the
  recipient and `ComponentReturned` is emitted. Show it on the receipt.
- **Value an index from units, not balances.** NAV is `components()` times independent prices. Never derive a
  price from `balanceOf(index)` and `totalSupply()`, and never use a thin DEX pool of the index token as an oracle.
- **Events.** `IndexFactory`: `IndexCreated`, `ListingProposed`, `ListingCancelled`, `TokenWhitelisted`,
  `GuardianProposed`, `GuardianChangeCancelled`, `GuardianSet`. `IndexToken`: `Issued`, `Redeemed`, `ClaimRecorded`,
  `Claimed`. `IndexZap`: `ZapMint`, `ZapBurn`, `ComponentReturned`.
- **Errors worth handling.** `IndexZap`: `ZeroAmount`, `InvalidRecipient`, `LegCountMismatch`, `BadPath`,
  `InsufficientBudget`, `InsufficientOutput`, `TransferShortfall`, plus the router's
  `Too much requested` / `Too little received` when a leg limit is hit. `IndexToken`: `InvalidSkipMask`,
  `NothingToClaim`.

## Whitelist policy

Standard ERC-20s only: no fee-on-transfer, rebasing, or ERC-777/callback tokens; 6-18 decimals; the address must
be a contract. `issue` verifies the received amount and reverts on any shortfall, so a misbehaving token cannot
drain an index. A component that can be paused or blacklisted, such as WBTC, no longer freezes the rest of a
basket because holders can exit with `redeemSkipping`, but it must be labelled in the app. USDC and USDT are fine
to mint *with* but should not be *components*.

Listings take two steps: the owner calls `proposeListing`, and from `LISTING_DELAY` (2 days) until a further
`PROPOSAL_WINDOW` (7 days) anyone can call `executeListing`; after that the proposal expires and must be proposed
again. Until then the owner or the guardian can `cancelListing` it, and either can `delist` a token at any time.
Delisting only affects indexes created afterwards. Replacing the guardian works the same way through
`proposeGuardian` and `executeGuardianChange` with a 7-day delay; only the owner can cancel it, and the current
guardian keeps its powers until the change executes.

## Known limitations

- Airdrops, rewards and governance votes that accrue to tokens held by an index cannot be claimed or used; by
  design there is no admin who could sweep them.
- If a multi-hop burn leg stops partway, the intermediate token stays in the Uniswap router rather than the zap;
  the leg and overall minimums still bound what the user receives.
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`). Re-check opcode support before deploying to any
  other chain.

## Mainnet addresses

| Contract | Address |
|---|---|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| LINK | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| tBTC v2 | `0x18084fbA666a33d37592fA2633fD49a74DD93a88` |
| Uniswap SwapRouter02 | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Uniswap QuoterV2 | `0x61fFE014bA17989E743c5F6cB21bF9697530B21e` |
| IndexFactory / IndexZap | not deployed yet |

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
EIP-7702 delegated account, and a Safe must need at least two signatures. `SWAP_ROUTER` is required on any chain
other than mainnet.

Listing components takes two runs of `script/ConfigureWhitelist.s.sol`, or the equivalent calls through the Safe:

```bash
# as the owner: propose every token in the list that is neither listed nor pending
LISTING_MODE=propose FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <owner> --broadcast
# 2 to 9 days later, from any account: execute every proposal that is due
LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`WHITELIST` is a comma-separated list of token addresses, or `default` for the WBTC/WETH/LINK/UNI/tBTC list on
mainnet. Execute mode never proposes anything, so a listing the guardian cancelled stays cancelled until the owner
proposes it again on purpose. When the owner is a Safe, submit `proposeListing` through the Safe; `executeListing`
is permissionless. For a local stack: `anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against
`http://127.0.0.1:8545`.

## Layout

```
src/IndexToken.sol            index implementation (ERC20 + in-kind issue, redeem, redeemSkipping, claim)
src/IndexFactory.sol          listing delay, guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              Uniswap V3 mint/burn router with per-leg limits
src/interfaces/               IIndexToken, IIndexFactory, ISwapRouter02
src/libraries/PathLib.sol     V3 path decoding
test/*.t.sol                  unit, fuzz, invariant and script tests
test/Security.t.sol           one regression test per security review finding
test/mocks/                   mock tokens and routers, with their own tests
test/fork/                    mainnet fork tests, including security regressions on real tokens
script/                       Deploy, ConfigureWhitelist
```

## Not in v1 (candidates for v1.1+)

ETH in/out (`mintWithETH` / `burnToETH`), `createAndMint` in one call, `mintWithTokenPermit` for USDC, creator or
protocol fees, rebalancing, on-chain Chainlink NAV lens, V4 / aggregator zap, synthetic exposure for L1 coins that
have no wrapper.
