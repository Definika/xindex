# Xindex Architecture

Xindex turns a portfolio of on-chain tokens into a single ERC-20 index token. Anyone can create an
index, anyone can mint it with USDC or USDT, and anyone can burn it back into USDC, USDT, WBTC, or
any other token with Uniswap V3 liquidity. Every index is fully backed, in kind, by the tokens it
represents. No admin can touch user funds.

## 1. Goals and constraints

| Requirement (from the product brief) | How it is met |
|---|---|
| Create a portfolio as one ERC-20, any name/symbol | `IndexFactory.createIndex` deploys an `IndexToken` clone with free-form name and symbol |
| Others can mint the same index | `issue` / `mintWithToken` are permissionless |
| Decentralized | No custody, no pause, no upgrade; the owner can only propose component listings, which activate after a public 2-day delay |
| Mint and burn | In-kind `issue` / `redeem` on the token; USDC/USDT convenience via the zap |
| Trade the index into other coins | Standard ERC-20 (transferable, listable) plus `burnToToken` into any token |
| USDC/USDT in, USDC/USDT out | Zap mints from either stable; burner chooses the payout token |
| Layer-1 coins | Only tokens that exist on mainnet can be components (wrapped BTC, ETH, ...) |

Decisions fixed for v1: Ethereum mainnet, Uniswap V3, fixed composition, no fees, whitelist only.

## 2. Components

```
                 createIndex(name, symbol, tokens[], units[])
   creator ───────────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexToken (ERC-20)
                                                             │  listings (2-day delay),           │ holds the basket
                                                             │  guardian, registry                │ issue / redeem in kind
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Uniswap V3                   │ redeemSkipping / claim
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                              │
                                      └──────── issue() / redeem() ───────────────────────────────┘
```

### IndexToken (`src/IndexToken.sol`)

The index itself. An EIP-1167 clone of one implementation, using OpenZeppelin's upgradeable ERC20
and ERC20Permit (clones skip constructors, so name and symbol are set in `initialize`).

- **State:** `Component[] {address token; uint96 units}`, fixed at `initialize`. `units_i` is the
  raw amount of component `i` (in that token's own decimals) backing one whole index token
  (`1e18` shares). Example "0.001 WBTC + 0.01 WETH + 1 LINK" is `[100000, 1e16, 1e18]`. Open claims
  live in `claimOf[account][token]`, and their sum per token in `totalClaims[token]`.
- **issue(shares, to):** computes `ceil(shares * units_i / 1e18)` per component, mints, emits, then
  pulls each component from `msg.sender` and reverts unless the balance grew by at least that amount
  (rejects fee-on-transfer tokens).
- **redeem(shares, to):** computes `floor(shares * units_i / 1e18)`, burns, emits, then pushes every component.
- **redeemSkipping(shares, to, skipMask):** the same, except each component whose bit is set in `skipMask`
  stays in the index and is recorded as a claim for `msg.sender`. Claims are booked before any token moves.
- **claim(token, to):** pays `msg.sender`'s claim on `token` and clears it.
- **Views:** `components()`, `componentTokens()`, `componentCount()`, `previewIssue`, `previewRedeem`,
  `claimOf`, `totalClaims`.
- **Access:** `initialize` is callable only by `FACTORY` (an immutable set to `msg.sender` in the
  implementation constructor, so every clone sees the factory) and only once; the implementation itself has
  initializers disabled. `issue`, `redeem` and `redeemSkipping` revert with `NotInitialized` on anything but an
  initialized clone, so neither the implementation nor a clone deployed outside the factory can mint unbacked
  shares. A recipient can never be the zero address or the index itself.
- **Reentrancy:** storage-based `ReentrancyGuard` on every state-changing entry point. Its namespaced slot
  reads as "not entered" when zero, so it works in a clone without initialization.

Invariant, for every component, forever:

```
token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
```

Ceil-on-issue and floor-on-redeem mean rounding drift is at most one raw unit per call, always in
favour of remaining holders. A claim is recorded only for an amount that stayed in the index, and because
`floor(a) + floor(b) <= floor(a + b)`, burning shares always frees at least that much required backing, so
claims never dilute anyone. Nothing is computed from balances, so there is no share price to manipulate and
no first-depositor attack. Donations only add locked surplus.

### IndexFactory (`src/IndexFactory.sol`)

- Deploys the `IndexToken` implementation in its constructor, which also sets the initial guardian.
- `createIndex(name, symbol, tokens, units)`: permissionless. Validates non-empty name and symbol,
  `1..20` components, matching lengths, every token whitelisted, no duplicates, `0 < units <= 2^96-1`.
  Deploys the clone with CREATE2 from a salt over the creator, name, symbol, tokens and units, registers it
  (`isIndex`, `creatorOf`, `allIndexes`), emits `IndexCreated`, then initializes it, all in one transaction.
  The same creator repeating identical arguments reverts with `IndexAlreadyExists`.
- `predictIndexAddress(creator, name, symbol, tokens, units)`: the address `createIndex` will use.
- Listings take two steps. `proposeListing(token)` (owner only; the token must be a contract that is neither
  listed nor pending) starts `LISTING_DELAY` = 2 days. `executeListing(token)` is permissionless from then until
  `PROPOSAL_WINDOW` = 7 days later, after which the proposal expires and must be proposed again. The owner and the
  guardian can `cancelListing` a pending or expired proposal and `delist` a token; delisting is immediate and never
  affects existing indexes, because each token stores its own components.
- Guardian changes take `GUARDIAN_DELAY` = 7 days: `proposeGuardian(address)` (owner only; zero removes the role),
  then `executeGuardianChange()` by anyone within the same 7-day window. Only the owner can `cancelGuardianChange`,
  and the current guardian keeps its powers until the change executes, so the guardian's veto cannot be bypassed
  without a week of public notice. `renounceOwnership` always reverts.
- Name and symbol uniqueness is deliberately not enforced (decentralized). The UI shows the index
  address and `creatorOf`.
- Neither role can pause, upgrade, or touch funds held by any index.

### IndexZap (`src/IndexZap.sol`)

The user-facing convenience layer. Stateless, ownerless, holds no funds between transactions.

- `mintWithToken(MintParams{index, tokenIn, maxAmountIn, shares, legs, to, deadline})`
  1. Checks the deadline, `FACTORY.isIndex(index)`, a recipient that is not zero, the zap or the index, and
     non-zero `shares` and `maxAmountIn`.
  2. Pulls `maxAmountIn` of `tokenIn`, reverting with `TransferShortfall` if less arrives, and approves the router.
  3. If `tokenIn` is itself a component, reserves its amount (`InsufficientBudget` if that alone exceeds
     `maxAmountIn`). For every other component, validates the leg's path (well-formed, starts at the component,
     ends at `tokenIn`) and calls `exactOutput` for exactly `previewIssue(shares)[i]`, capped by the smaller of
     the leg's `maxAmountIn` and the remaining budget. Approves the index for the whole basket.
  4. Refunds this call's `tokenIn` balance change minus the reserved amount, clears the router approval, emits.
  5. `issue(shares, to)` as the final interaction.
- `burnToToken(BurnParams{index, shares, tokenOut, minAmountOut, legs, to, deadline})`
  1. The same checks, with non-zero `shares` and `minAmountOut`. Pulls the index tokens.
  2. `redeem(shares, this)`; the amounts are `previewRedeem(shares)`.
  3. For each component: counts it if it is `tokenOut`, skips it if its amount rounds to zero, and otherwise
     validates the path and calls `exactInput` with the leg's `minAmountOut`. If the router took less than the
     full amount, because a pool reached its price limit or the router paid WETH from ETH it was holding, the
     unsold part goes to the recipient and `ComponentReturned` is emitted.
  4. Measures the payout as this call's `tokenOut` balance change, reverts with `TransferShortfall` if it is
     below what the router reported and with `InsufficientOutput` if it is below `minAmountOut`, emits, transfers.
- `burnToTokenWithPermit(BurnParams, v, r, s)` runs the same checks, submits the index-token permit in a
  try/catch (a front-run permit has already set the allowance), and burns in the same transaction.
- Tokens already sitting in the zap are never used. The zap never calls `redeemSkipping`, because a claim
  recorded for the zap could never be collected.
- Slippage and MEV protection is the per-leg limits, the overall limit and `deadline`, computed off-chain with
  QuoterV2 and checked against an independent price. No oracle.

### PathLib (`src/libraries/PathLib.sol`)

Decodes Uniswap V3 packed paths (`token(20) | fee(3) | token(20) ...`): shape check, first token,
last token. Exact-output paths are encoded in reverse (output token first).

## 3. Flows

**Create.** Frontend converts the creator's target weights into units,
`units_i = floor(w_i * targetPrice / p_i * 10^dec_i)`, shows `predictIndexAddress`, and calls `createIndex`.

**Mint with a stablecoin.** Frontend quotes each leg with `QuoterV2.quoteExactOutput`, sets each leg's limit a
small margin above its quote and the overall limit from the sum, and calls `mintWithToken`. Exact shares are
minted; unspent stable is refunded.

**Burn to any token.** Frontend quotes each leg with `quoteExactInput`, sets each leg's minimum a margin below its
quote and a non-zero overall minimum, and calls `burnToToken`, or `burnToTokenWithPermit` for one signature and
one transaction.

**Exit while a component is frozen.** `redeemSkipping` with that component's bit set pays everything else now and
records the frozen amount; `claim` pays it once transfers resume.

**Direct.** Anyone holding the components can `issue`, and any holder can `redeem`, `redeemSkipping` and `claim`,
without the zap.

**Trade.** An index is a normal ERC-20 and can be transferred or pooled on any DEX. The burn path
is the guaranteed exit.

## 4. Key design decisions and rationale

**In-kind core, swap layer on top.** Splitting custody (token) from convenience (zap) keeps the
part that holds funds tiny, oracle-free, and admin-free. The swap layer can be replaced without
touching any index. This mirrors Set Protocol's basic issuance plus a permissionless router.

**Uniswap V3 rather than V4 for v1.** SwapRouter02's `exactOutput(path)` lets the zap buy exactly
the basket with a single stablecoin leftover, and lets it validate path endpoints on-chain. V4's
singleton with flash accounting and hooks has no equivalent simple call; swapping through it means
unlock callbacks or Universal Router command encoding, both far harder to validate. V3 still holds
the reference liquidity for our pairs. Because the zap is replaceable, a Universal Router (V2+V3+V4)
or aggregator zap can ship later with no change to the core.

**Exact-output mint.** Buying exact component amounts avoids multi-token dust; the only refund is
the input stable.

**Units, not weights.** USD weights drift with prices the moment after creation. What is fixed is
the raw basket per share. The UI says "fixed composition".

**Burner chooses the exit token.** Index tokens are fungible, so the protocol cannot know which
stable a given holder minted with. USDC and USDT are economically equivalent, and letting the
burner choose also delivers "swap the index into any coin".

**Whitelist only for components.** A fully collateralized index can hold only what exists on the
chain. BTC and ETH are fine via WBTC/WETH; coins with no credible mainnet wrapper (ADA, XRP, ...)
are out of scope until one exists. Oracle-priced synthetics would make the protocol the unhedged
counterparty and were rejected for v1.

**No fees, no rebalancing in v1.** Both are product questions with holder-protection implications
(timelocks, rug risk). Deferred deliberately.

**Skip-and-claim instead of all-or-nothing redemption.** A single paused component used to freeze every other
component in a basket. `redeemSkipping` lets a holder take out everything that still moves and records the rest
as a claim instead of forfeiting it, so no value shifts between holders and the backing invariant only gains a
`totalClaims` term. The zap keeps using strict `redeem`, because a claim recorded for a stateless contract could
never be collected.

**Public delays on every owner power.** Listings are the owner's only power over what users can buy, so they carry
a built-in 2-day delay that holds regardless of how the owner key is managed, and a proposal that is not executed
within 7 days of becoming ready expires. A separate guardian can cancel a proposal or delist immediately. Replacing
the guardian takes 7 days, only the owner can cancel that, and the old guardian keeps its powers meanwhile, so a
compromised owner cannot silence the guardian and list a hostile token without a public week of warning. Ownership
cannot be renounced, because that would freeze listings forever.

**Creator-bound CREATE2 addresses.** Deriving the clone address from the creator and the full composition means
an address can never hold a different basket, even across a re-org. It also lets the app show the address before
confirmation, and makes a front-runner's copy land at its own address under its own `creatorOf`.

**Balance-measured zap accounting with per-leg limits.** Measuring what the user pays and receives as balance
changes inside the call ignores stray tokens, refunds anything the router did not actually pull, and turns
fee-charging currencies into explicit reverts instead of silent losses. When the router leaves part of a component
unsold, that part goes back to the recipient, so stray ETH in the router pays for the user's swap instead of
blocking it. Per-leg limits stop a sandwich from spending the whole tolerance on the thinnest pool.

## 5. Security model

- **Trust:** the factory owner, whose powers are proposing listings (2-day delay) and guardian changes (7-day
  delay), each expiring 7 days after it becomes executable; the guardian, who can only cancel listing proposals and
  delist; the whitelisted tokens and their issuers; and Uniswap V3. Users trust
  no one with custody.
- **Reentrancy:** `nonReentrant` on `issue`, `redeem`, `redeemSkipping`, `claim`, `createIndex`, `mintWithToken`,
  `burnToToken` and `burnToTokenWithPermit`. Checks-effects-interactions throughout; claims are booked before any
  transfer, and the call into the index is the last interaction in `mintWithToken`. In `burnToToken` the redeem
  must precede the swaps; the guard covers it and the static-analyzer suppression is documented in code.
- **Read-only reentrancy:** inside `issue` and `redeem`, supply and balances change at different moments.
  Xindex's own views never read balances, so they are exact at all times. Integrators must value an index from
  `components()` and independent prices, never from `balanceOf(index)` and `totalSupply()`.
- **Clone safety:** the implementation has initializers disabled; `initialize` is `onlyFactory` and runs in the
  same transaction as the clone; uninitialized instances cannot issue or redeem; `isIndex` is the only trusted
  registry, and the zap checks it.
- **Token behaviour:** `issue` verifies received amounts, so a misbehaving token cannot drain an index. A paused
  or blacklisting component no longer freezes the rest of a basket: `redeemSkipping` exits everything else and
  `claim` collects the frozen part later. Policy: standard ERC-20s, 6-18 decimals, no fee-on-transfer, rebasing or
  callback tokens; stables are mint currencies, not components; pausable components are labelled in the app.
- **Zap:** validates path endpoints, honours per-leg and overall limits, rejects a zero output limit, measures
  payments and payouts as balance changes, returns any part of a component the router did not sell to the
  recipient, reverts on transfer shortfalls, rejects itself and the index as recipients, and keeps no storage. Tokens sent to it by mistake stay there.
- **Operations:** `OWNER` and `GUARDIAN` are required at deploy; on mainnet the owner must be a contract that is not
  an EIP-7702 delegated account, and a Safe must need at least two signatures. Deployments use encrypted keystores or
  hardware wallets. CI fails unless every submodule has a matching `foundry.lock` entry, pins the Foundry toolchain by
  commit, and requires the fork-test RPC on `main`.
- **Gas:** `MAX_COMPONENTS = 20`; the UI should suggest about 10.
- **Overflow:** `units <= 2^96-1` and 512-bit `mulDiv`; no overflow possible.
- **Known limitations:** airdrops, rewards and votes that accrue to index-held tokens are unrecoverable; bytecode
  targets Cancun.

## 6. Verification

- Unit and fuzz tests per contract with 6/8/18-decimal mocks and a USDT-like mock (no return
  values, approve-from-non-zero reverts).
- Invariant test: random issue, redeem, redeemSkipping, claim, transfer and donate sequences; asserts every
  component stays backed including open claims, supply equals the sum of holder balances, and claims add up.
- Security regression suite (`test/Security.t.sol`): one test per finding of the 2026-09-15 security review,
  asserting the fixed behaviour, plus the attacks that already failed.
- Mainnet fork tests: real Uniswap V3, USDC, USDT, WBTC, LINK and tBTC; mint with both stables, burn to USDT and to
  WBTC, per-leg limits from live quotes, slippage reverts. Fork security regressions pause the real WBTC and exit
  around it, switch on USDT's transfer fee, and leave stray ETH in the real router during a mint and during a burn.
- Script tests execute `Deploy` and `ConfigureWhitelist` in-process.
- Gates: `forge fmt --check`, lint-free `forge build`, 100% coverage on every file, Wake analyzer
  clean on `src/`, and the CI submodule check against `foundry.lock`.

## 7. Mainnet addresses

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

## 8. Roadmap candidates

ETH in/out, `createAndMint`, `mintWithTokenPermit` (USDC only), creator/protocol fees attributed by `creatorOf`
with timelocked governance, rebalancing, stateless Chainlink NAV lens, Universal Router / V4 / aggregator zap,
synthetic exposure for L1 coins.
