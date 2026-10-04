# Xindex

Xindex lets investors package a whole crypto portfolio into a single ERC-20 token. Anyone can create an index (any
name, any symbol, any mix of whitelisted tokens), anyone can mint it with USDC or USDT, and anyone can burn it back into
USDC, USDT, WBTC or any other token. Every index is a plain ERC-20, fully backed in kind by the tokens it represents.
Its units follow the market-cap rule `units ∝ supply`, from reference supplies the owner updates weekly behind a public
delay, and a rebalance settles through an auction on a single number, λ. **No contract reads a price.**

This repository holds the smart contracts (Foundry), and for Stage B the Solana programs (`solana/`), the proof systems
(`proofs/`) and the TRON build (`tron/`). The web app lives elsewhere.

**Status (2026-10-01): v4, the design that launches on mainnet; deployed nowhere yet.** v4 is one hybrid product
(`design/2026-09-29-v4-hybrid-architecture.md`): an index token on Ethereum that holds Ethereum tokens itself and other
chains' native coins in ownerless vaults. Stage A, the price-free part held on Ethereum, is built as
`design/2026-09-30-v4-stage-a-spec.md` describes it, `MintRequests` included, with the owner's decisions of 2026-09-30:
no fee, WBT off after its check, and an owner Safe of at least three signatures. Stage B, the vaults and their proofs
(`design/2026-09-30-v4-stage-b-spec.md`), is largely built in code: `HybridIndexFactory`, `HybridHub` with its module
and extension, the EVM vault `XindexVault` and the Solana vault program, P1 (on SP1) and P2 (on RISC Zero) for an EVM
vault chain and for Solana, and the state verifiers of BNB Chain and TRON on Ethereum.
- **BNB Chain and TRON** are complete in code in both directions, deployment included: `script/DeployVault.s.sol` for
  BNB Chain and `tron/deploy.mjs` for TRON, each with the same checks.
- **NEAR and Stellar** are complete in code in both directions (2026-10-04): their vaults (`near/`, `stellar/`) with
  P1 and P2, on the shared Rust core `crates/xindex-core`, and their state verifiers on Ethereum, `NearStateVerifier`
  and `StellarStateVerifier`, proven by SP1 programs (`proofs/near`, `proofs/stellar`). Their vaults' deploy tooling
  on their own chains is not written yet.
- **Sui** is complete in code in both directions (2026-10-04): its Move vault with P1 and P2 inside it (`sui/`), and
  `SuiStateVerifier`, which checks Sui's committee certificates on Ethereum in Solidity, with no zkVM.
- **Injective and VeChain** run `XindexVault` unchanged, and their state verifiers on Ethereum are built
  (2026-10-04): `CometBftStateVerifier` and `VeChainStateVerifier`, proven by SP1 programs (`proofs/cometbft`,
  `proofs/vechain`). VeChain adds `VeChainStakerAttester` on VeChain, and its own deployment script (`vechain/`).
- **Aptos** is complete in code in both directions (2026-10-04): its Move vault with P1 and P2 inside it (`aptos/`),
  and `AptosStateVerifier`, proven by an SP1 program (`proofs/aptos`) over Aptos Labs' public database backups.
- **Solana** is complete from Ethereum to its vault: P1, P2, and the vault's checkpoints, stall recovery and snapshot
  exit. Its state verifier on Ethereum is not built, and can ship only once Alpenglow reaches mainnet.
- **HyperEVM** cannot hold a vault while its headers' state root is zero (Stage B spec, section 8).
- **Stage C**'s other chains (Avalanche, Hedera, Cardano) were researched on 2026-10-01 and are not built
  (`design/2026-10-01-stage-c-research.md`).

Internal red teams have reviewed Stage A, and Stage B's vaults, hub, factory and BNB verifier
(`audit/2026-09-30-stage-a-red-team.md`, `audit/2026-09-30-stage-b-red-team.md`), and an internal review the TRON state
verifier (`audit/2026-10-01-tron-review.md`); no review has read P1's and P2's verifiers yet. It launches as one
product, on `HybridIndexFactory`, once the hybrid index is ready (the owner's call on 2026-10-01). Still to come: real
proving (P1 and P2 have run only in execute mode, and a proof needs rented GPUs or a prover network), external audits,
the vaults' among them, and a Sepolia rehearsal. v3 stays at the git tag `v3.0.0` and on Sepolia, and never launches
on mainnet.

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

The history, in one paragraph each:

- **v2** (2026-09-16) added on-chain rebalancing to the market-cap methodology of the team's Numbers model
  (`index_MODEL.numbers`), uncapped or capped at 30/20, priced from Uniswap V3 pool averages.
- **v3** (2026-09-22) priced from Chainlink USD feeds and swapped through Uniswap's Universal Router, which reaches V3
  and V4 pools. `audit/2026-09-22-v3-retirement.md` records what that retired.
- **v4 Stage A** (2026-09-30) removes prices from the contracts altogether. A market-cap index whose units are
  proportional to supplies never needs to trade when prices move, because prices cancel out of the weights: it trades
  only when a supply changes. So the rule, the feeds, the capped methodology (which trades on every price move and needs
  every price) and the price gates on settlement are gone, and a rebalance is an auction whose worst case holds at any
  prices. `audit/2026-09-30-v4-stage-a-retirement.md` records which past findings that retired and where the rest are
  tested now. Stages B and C add the native coins of other chains, held in vaults there (see "Roadmap" in
  `ARCHITECTURE.md`).

## Design decisions (v4 Stage A)

| Topic | Decision |
|---|---|
| Chain | Ethereum mainnet. Vaults on other chains come in Stage B. |
| Composition | Constituents fixed at creation, up to 100 per index (`MAX_COMPONENTS`). Units follow the uncapped market-cap rule, `units ∝ referenceSupply`; the capped 30/20 methodology is retired, because it trades on price moves and needs prices. |
| Creation | `createIndex(name, symbol, tokens, k)`: every component's units are `⌊k × referenceSupply / 1e36⌋`, each between `MIN_RAW_UNITS` (10,000) and `MAX_UNITS` (`(2^96 − 1) >> 10`). One whole index token holds the fraction `k / 1e36` of every component's reference supply. |
| Supplies | One reference supply per token, in its raw units: the supply of what the token represents (bitcoin's for WBTC, ether's for WETH). Nothing reads a supply live. After the first listing a supply changes only through a weekly **batch**: atomic, one live at a time, 2 days of notice with the guardian's veto, each supply within `MAX_SUPPLY_STEP` (0.5%) of the one in force. |
| Rebalancing | Anyone starts a rebalance 7 days after the last one (`MIN_REBALANCE_INTERVAL`), 2 days of notice (`REBALANCE_DELAY`), then a 24-hour auction (`AUCTION_DURATION`) in which λ falls from the top of the band to the bottom and any contract can fill. Every moving component's units move within `[λmin/λmax, λmax/λmin] ⊂ [0.990, 1.0101]` per rebalance, plus one raw unit of rounding. |
| Prices | None on chain. The app values an index off chain as the sum of units times its own prices (design section 10). |
| Swaps | Uniswap's Universal Router 2.0.0, V3 and V4, one venue per leg, chosen by the caller: as in v3. The app offers the one-click zap only up to about 35 components (EIP-7825's 16.78M gas per transaction). |
| Fees | None: Stage A is funded from outside (the owner's call on 2026-09-30, design section 13.1). Every amount the hub moves goes through one helper, `_backing`, so a fee in a later version would land in one reviewed change. |
| Layer-1 coins | Stage A holds Ethereum tokens only; Bitcoin is held as WBTC. Native coins of chains whose contracts can verify a proof about Ethereum, and whose state Ethereum can verify in turn, come in vaults from Stage B. Script-only chains, whose contracts cannot verify one (Bitcoin, XRP Ledger, Dogecoin, ...), are out of scope. |
| Stable in / out | Mint with USDC or USDT through the zap, or through `MintRequests` at a limit of the requester's own, filled by anyone who holds shares. The burner chooses USDC, USDT or any other token at exit, or asks for USDC or USDT at a limit through `MintRequests`. Index tokens are fungible, so the protocol cannot know which stable a holder used. |
| Decentralization | No admin can move an index's funds, mint or burn its shares, pause or upgrade it, or set its units by hand. The owner proposes listings and supply batches, which take effect after 2 days, and guardian changes, which take 7; a proposal not executed within 7 days of becoming ready expires. Owner and guardian both cancel pending listings and batches, delist, cancel a rebalance, and start one with a keep mask or before strangers may. The guardian can cancel a change that would remove it, not one that replaces it. Ownership moves in two steps with no delay, and cannot be renounced. |
| Frozen components | If a component's issuer pauses or blacklists transfers, holders take every other component out with `redeemSkipping` and collect the frozen one later with `claim`; the guardian rebalances around it with a keep mask, which neither transfers the component nor reads its balance or its supply. |

## Architecture

```
                  createIndex(name, symbol, tokens[], k)
   creator ─────────────────────────────────────────► IndexFactory ──CREATE2 clone──► IndexHub (ERC-20)
                                                       │ listings, weekly supply      │ holds the basket
                                                       │ batches (2-day delay),       │ issue / redeem in kind
                                                       │ guardian, registry           │ redeemSkipping / claim
                                                       │                              │
   anyone ── startRebalance ─────────────────────────► │ referenceSupplies(tokens) ◄──│ start: the λ band
   executor ── executeRebalance ◄── flash-style callback ─────────────────────────────│ fill at λ(t)
                                                                                      │
   user ── mintWithToken(USDC) ──► IndexZap ── exactOutput swaps ──► Universal Router ─► V3 / V4
        ◄─ burnToToken(USDT)  ───     │      ◄─ exactInput swaps  ──                  │
                                      └──────── issue() / redeem() ───────────────────┘

   requester ── requestMint(USDC, minShares) ──► MintRequests ◄── fill(id) ── minter (holds or issues shares)
             ◄─ shares, at least minShares ─────  (escrow)    ── the USDC ──►
```

- `IndexHub` (`src/IndexHub.sol`) only ever moves amounts derived from supply and units. `issue(shares)` pulls
  `ceil(shares × units_i / 1e18)` of every component and mints; `redeem(shares)` burns and pushes
  `floor(shares × units_i / 1e18)`; `redeemSkipping` leaves chosen components as claims for the recipient. A rebalance
  is `startRebalance` (a snapshot of the band from the reference supplies in force), 2 days of notice, and a 24-hour
  auction whose fill stands only if every component still backs the new units. Nothing in the hub reads a price or
  computes an amount from a balance, so there is no share price to manipulate and no first-depositor attack. Share
  transfers to the hub itself or its factory are refused, since neither could move a share on (CR-I01, RT-21). Only
  initialized clones can issue, redeem or rebalance. Supports EIP-2612 `permit`.
- `IndexFactory` (`src/IndexFactory.sol`) is permissionless `createIndex`, a curated token whitelist in which every
  token carries a timelocked reference supply, the weekly supply batches, an `Ownable2Step` owner plus a guardian whose
  replacement takes 7 days, and the registry (`isIndex`, `creatorOf`, `allIndexes`). Indexes are EIP-1167 clones
  deployed with CREATE2 from a salt over the creator, the name, the symbol, the tokens and the **computed units**;
  `predictIndexAddress` returns the address before the transaction is sent.
- `IndexZap` (`src/IndexZap.sol`) is v3's stateless convenience router over Uniswap's Universal Router, unchanged but
  for its recipient check. `mintWithToken` buys exactly the basket with exact-output swaps and issues; `burnToToken`
  redeems and sells every component into the chosen token; `burnToTokenWithPermit` does it in one transaction. It is the
  only contract here that knows about Uniswap.
- `MintRequests` (`src/MintRequests.sol`) is an ownerless escrow. `requestMint(index, stable, amount, minShares,
  deadline)` escrows USDC or USDT for at least `minShares` shares; `requestRedeem(index, shares, stable, minOut,
  deadline)` escrows shares for at least `minOut` of a stablecoin. Anyone `fill`s a request before its deadline by
  sending the requester what they asked for and takes the escrow. The requester can `cancel` at any time, and anyone can
  `refund` the escrow to the requester after the deadline, at most 30 days away. Nothing reads a price: the requester's
  limit is the valuation.
- `HybridIndexFactory` (`src/HybridIndexFactory.sol`), the factory v4 deploys, is `IndexFactory` plus a registry of
  vault chains, each with its vault and the verifier of its state on Ethereum, the listing of the coins those vaults
  hold, a freeze of a chain, and the choice of template: an index of Ethereum tokens only is an `IndexHub` clone,
  exactly as above, and one holding any vault coin is a `HybridHub` clone. `HybridHub` (`src/HybridHub.sol`, with its
  module and extension in `src/hybrid/`, which run on the clone's storage by DELEGATECALL) mints by order and burns by
  message. A vault (`src/vault/XindexVault.sol` on an EVM chain, `solana/` on Solana) takes its coin only as a deposit
  to an intake and pays out only on messages from Ethereum that both P1 and P2 prove, within a speed limit; Ethereum
  reads the vault's state through the chain's state verifier (`src/verifiers/`). The Stage B spec has the rules.

Invariant, for every component `i` of every index, forever:

```
token_i.balanceOf(index) >= floor(totalSupply × units_i / 1e18) + totalClaims[token_i]
```

## How the flows work

**Create.** The creator picks whitelisted tokens and a size `k` in the UI. `k` is the fraction of each reference supply,
times 1e36, that one index token holds, so it sets the index token's value: `value per token ≈ k / 1e36 × Σ (market
cap of each component)`. The app calls `previewUnits(tokens, k)` to show the basket, `predictIndexAddress` to show the
address, and `createIndex`. Every unit has to lie in `[MIN_RAW_UNITS, MAX_UNITS]` or the call reverts
`UnitsOutOfRange(token, units)`; the component with the smallest supply in raw units sets the floor. For WBTC, whose
raw unit is a satoshi, 10,000 raw units is 0.0001 BTC, about 11 dollars a token at BTC 110k, so `k` must be at least
about 5e24; for an 18-decimal component the floor binds on nothing. Names and symbols are free-form and not unique; the
UI must show the index address and `creatorOf` to avoid spoofing.

The address commits to the units computed from the supplies in force. A supply batch executed between the preview and
the transaction changes both the units (by at most 0.5% per token) and the address, never the basket at an address.

**Mint with USDC/USDT.** For each leg the app picks a venue, quotes it (QuoterV2 `quoteExactOutput` for a V3 leg, the
V4 Quoter for a V4 one), sets per-leg limits and the overall `maxAmountIn`, reads `rebalanceNonce()`, and calls
`mintWithToken(MintParams)`. Exact `shares` are minted; unspent USDC comes back.

**Burn to USDC/USDT/anything.** The app quotes each leg in the exact-input direction, sets per-leg minimums and a
non-zero overall `minAmountOut`, passes `rebalanceNonce()`, and calls `burnToToken(BurnParams)` or
`burnToTokenWithPermit`.

**Weekly supply update.** The owner Safe proposes one batch of reference supplies a week (`proposeSupplies(tokens,
supplies)`, tokens in strictly ascending address order, each supply within 0.5% of the one in force). For 2 days the
guardian or owner can `cancelSupplies`; from then until 7 days later anyone can `executeSupplies`, which puts every
supply of the batch in force at once, or none. A larger revision goes in several weekly steps. At 0.5% a week an index
follows a token whose supply grows up to about 30% a year faster than the rest (1.005^52 − 1).

**Rebalance.**
1. Once 7 days have passed since the index's creation or last rebalance, anyone calls `startRebalance(0)`. The hub
   reads the reference supplies in force, computes each moving component's ratio `r_i` of units to supply (centred and
   clamped to `1 ± 0.5%`, see `ARCHITECTURE.md`), and stores `λmax = max r` and `λmin = min r`. If they are closer than
   `MIN_BAND` (0.1%) the call reverts `BandTooNarrow(λmin, λmax)`: the units already follow the supplies, which covers
   no supply changing, every supply changing alike, and a single moving component. A freshly created index has nothing
   to rebalance until a batch changes a supply.
2. For 2 days nothing changes. Holders who disagree can leave, and this notice is the window to do it in: once the
   auction opens, a public redeem can be overtaken by a fill (step 3). A batch executed during the notice or the
   auction does not move the pending settlement (R22).
3. A 24-hour auction follows. λ falls linearly from `λmax` to `λmin`, rounding up. An executor contract calls
   `executeRebalance(data)`: every moving component's units become `⌈λ × u / r⌉`, so a component whose ratio is above
   λ shrinks and one below λ grows. The executor receives what the index no longer needs of each shrinking component
   and, inside its `onXindexRebalance` callback, must send back what the growing components need. Both sides are
   recomputed from `totalSupply()` in the settling block, and issue and redeem stay open throughout, so an executor
   sizes itself from the callback's arguments. `executeRebalance(data, maxAmountsIn)` is the same settlement bounded:
   it reverts `RebalanceMovedOn(token, required, maxAmountIn)` when the index has come to need more of a component than
   the caller said it would deliver (DA-13). A fill that would send nothing out, as on an empty index, settles at
   `λmax`, where nothing shrinks and nobody is paid.
4. Executors compete the fill toward the break-even λ, where the index gives up exactly what it gets back at market
   prices. That λ always lies inside the band, whatever prices do. A lone executor that waits for the floor keeps
   `1 − λmin/λmax` of the moving value at most, 0.995% (see "Known limitations").
5. If nobody fills, the auction expires. The owner or guardian can start a fresh one at once; anyone else can 2 days
   after the auction's last second.
6. The owner or guardian can cancel a rebalance. Cancelling a live one makes others wait 2 days from the cancel to
   restart; cancelling one that already expired only clears it from the views, and the wait the expiry started stands
   (VR-04).

The fill can land in any block of the auction, and whoever holds shares in that block shares its outcome, so an
executor watching the mempool can put its fill ahead of a public redeem or guardian cancel; the zap's `expectedNonce`
makes such a burn revert, but only after the fill landed. Leave during the notice, or send the transaction through a
private relay (RT-02). Shares issued while a rebalance is pending share the outcome of any fill that lands after them,
however it is ordered.

**Rebalance around a frozen component.** The guardian cancels and starts again with the component's bit in `keepMask`;
that component keeps its units, its supply is not read, and the settlement neither transfers it nor reads its balance,
so the mask also routes around a component whose contract stops answering (DA-14, RT-01). The other components still
need a band of at least `MIN_BAND` between them.

**Exit while a component is frozen.** If, say, WBTC is paused, `redeem` and the zap revert. The holder calls
`redeemSkipping(shares, to, skipMask)` with the WBTC bit set: every other component arrives now and the WBTC amount is
recorded in `claimOf(to, WBTC)`. Once WBTC transfers resume, `claim(WBTC, to)` pays it.

**Trade.** An index is a normal ERC-20, so it can be transferred or listed on any DEX. The burn path is the guaranteed
exit.

**Direct, without the zap.** `issue`, `redeem`, `redeemSkipping` and `claim` on the index itself work for anyone who
already holds the components or shares.

**Requests.** A holder of USDC who wants shares without swapping a basket calls `requestMint` with a limit the app
suggests from its own valuation, for example 1% under the index's value. A minter who holds shares, or can issue them in
kind, calls `fill(id, amount)`: at least `minShares` shares go from the minter to the requester, measured at the
requester, and the escrowed USDC goes to the minter. A redemption is the mirror image, and a USDT fee comes out of the
filler's delivery, so the requester still receives the limit. Unfilled, the escrow goes back on `cancel` (the requester,
at any time) or `refund` (anyone, after the deadline).

## Frontend integration notes

- **Index value is the app's job.** No contract has a price function. Value one whole index token as
  `Σ units_i / 10^decimals_i × price_i` from `components()` and the app's own prices: the design (section 10) uses the
  median of several exchanges and aggregators, drops sources more than about 2% from the rest, prices exactly the
  asset held (WBTC at WBTC's own market price), and marks a price older than about ten minutes as estimated. Never
  derive a price from `balanceOf(index)` and `totalSupply()`, and never use a thin DEX pool of the index token as an
  oracle.
- **Starting units.** `previewUnits(tokens, k)` returns `⌊k × referenceSupply / 1e36⌋` per token with the supplies in
  force; `createIndex` reverts `UnitsOutOfRange` unless each lies in `[MIN_RAW_UNITS, MAX_UNITS]`, and
  `InvalidComponentCount` outside 1 to `MAX_COMPONENTS` (100). Offer the one-click zap only up to about 35 components.
  Show `suppliesPending()` and the batch's eta before a creator signs: a batch that executes first changes the units
  and the address.
- **Names and symbols are not unique.** `createIndex` requires only that they are non-empty. The CREATE2 salt commits
  to the creator, the name, the symbol, the tokens and the units, so two look-alike indexes have different addresses:
  key every index by its address, show `creatorOf`, and mark a name or symbol an existing index already uses.
- **Rebalance status.** Show `lastRebalance + MIN_REBALANCE_INTERVAL`, and a "rebalance due" button when
  `canStartRebalance()` is true and `previewBand(0)` shows a band of at least `MIN_BAND`
  (`lambdaMax × 1e18 ≥ lambdaMin × (1e18 + MIN_BAND)`); a narrower band means there is nothing to rebalance and a start
  reverts `BandTooNarrow`. `canStartRebalance()` answers the whole timing predicate: the interval has passed, no auction
  is live (an auction nobody filled keeps its `eta` after `eta + AUCTION_DURATION`, so `pendingRebalance().eta == 0` on
  its own is the wrong test), and the waits after a cancel and after an unfilled auction are over. Those waits hold off
  everyone but the owner and guardian: `REBALANCE_DELAY` from the cancel of a live auction, and `REBALANCE_DELAY` from
  an unfilled auction's last fillable second, so after an expiry the owner and guardian have the start to themselves
  for `REBALANCE_DELAY` less one second (CR-I02). Read `canStartRebalance()` or the `restartAllowedAt` that
  `RebalanceCancelled` carries rather than computing either wait; `restartAllowedAt()` alone reflects cancels only
  (RT-08, RT-09).
- **During a rebalance.** In the notice, show `pendingRebalance()`, which returns `(eta, keepMask, lambdaMin,
  lambdaMax, ratios)`: a component whose ratio sits above the λ of a fill shrinks, one below grows. In the auction,
  show `currentLambda()` (0 outside an auction) and `previewRebalance()`, which returns `(lambda, units, amountsOut,
  amountsIn)` for this block. While a rebalance is pending, warn before a mint that the new shares share the coming
  settlement's outcome; during the auction, also warn before a burn that the fill can be ordered ahead of it, and that
  a private relay is the protection (RT-02).
- **Rebalance events.** `RebalanceStarted(proposalId, id, caller, keepMask, lambdaMin, lambdaMax, ratios, eta)`,
  `RebalanceCancelled(proposalId, caller, restartAllowedAt)` and `Rebalanced(proposalId, id, executor, lambda, units,
  amountsOut, amountsIn)`. `proposalId` counts every attempt on the index, so cancelled, expired and settled attempts
  can be told apart; `id` is the `rebalanceNonce` a settlement takes. Nothing is emitted when an auction expires
  unfilled: the next `RebalanceStarted` is the first sign.
- **Guardian duty.** During every notice period, recompute the band from the index's units and the reference supplies
  that were in force at the start (it should equal `pendingRebalance()`), check that the batch behind it was the one
  reviewed, and watch keep masks. The contracts cannot tell a mistyped supply from a real one; the guardian's
  `cancelSupplies` during a batch's 2 days and `cancelRebalance` during a notice are the checks.
- **Zap calls take a params struct.** `MintParams {index, expectedNonce, tokenIn, maxAmountIn, shares, legs, to,
  deadline}` with `MintLeg {v3Path, v4Path, maxAmountIn}`, and `BurnParams {index, expectedNonce, shares, tokenOut,
  minAmountOut, legs, to, deadline}` with `BurnLeg {v3Path, v4Path, minAmountOut}`. `legs` has one entry per component,
  in component order. `expectedNonce` is `rebalanceNonce()` when the legs were quoted; after a rebalance, re-quote.
- **One venue per leg.** A leg carries a packed `v3Path` **or** a `v4Path`, never both. Both empty means "no swap",
  which is only valid for the pass-through leg, the one whose component already is the stable on a mint or `tokenOut`
  on a burn. Anything else is `BadRoute(i)`. There are no mixed-venue legs.
- **V3 routes.** Packed paths: `token(20) | fee(3) | token(20) [| fee(3) | token(20)]`. For **mint** the path is
  exact-output encoded, starting with the component and ending with the stable (e.g. `WBTC 500 WETH 500 USDC`). For
  **burn** it is exact-input encoded, starting with the component and ending with `tokenOut`.
- **V4 routes.** An array of `PathKey {address intermediateCurrency, uint24 fee, int24 tickSpacing, address hooks,
  bytes hookData}`, one per hop. Every hop must be hookless: `hooks` zero and `hookData` empty, or `BadRoute(i)`. Each
  entry carries the pool of the hop it closes. The **burn** direction is walked forwards from the component, so the
  last entry names `tokenOut`; the **mint** direction is walked backwards from the component, so the *first* entry
  names the stable and the list is the burn route reversed. Live V4 pools for these components are paired against
  **native ether**, `address(0)`, which may only ever be an intermediate: native ether never reaches the zap, which has
  no `receive()`. Example, USDC to LINK: burn `[{ETH, 3000, 60}, {USDC, 500, 10}]`, mint `[{USDC, 500, 10}, {ETH,
  3000, 60}]`. Keep a route from visiting the same currency twice: on a mint, the pinned periphery does not hold a V4
  exact-output route that revisits `tokenIn` to its `amountInMaximum` (upstream issue #564), so the zap's pre-funding
  is then the only bound on that leg; on a burn, a route that revisits the component can fill a later hop partially
  and return the unsold component instead of reverting (CR-I06, CR-I07).
- **A zero-amount burn leg.** A leg whose amount rounds to zero sells nothing, but its route is still validated and its
  minimum must be 0, or the burn reverts with `InsufficientOutput`.
- **Slippage.** Set a limit on every leg, not only the total; every leg is checked, including the pass-through leg
  (DA-15). A leg limit of 0 means "overall limit only", and the overall burn limit must be non-zero. Legs that cross
  the same pool interact, so summed per-leg quotes are optimistic; an `eth_call` of the whole zap call returns the exact
  amount. Compare each quote with an independent price and refuse to sign when they diverge; use a private relay and
  short deadlines.
- **Gas.** The zap costs 265k to 430k gas per component (measured on a mainnet fork at 20 components in v3, CR-I08:
  a mint 5.3M to 6.2M, a burn 5.1M with two V3 hops a leg to 8.6M with four). EIP-7825 caps a transaction at 2^24
  gas, so disable the zap above about 35 components, keep routes to two or three hops, and refuse or reroute any zap
  call whose simulated gas exceeds about 14M. The in-kind path fits at 100 components (about 3.7M for `redeem`).
- **Approvals.** USDC supports `permit`; USDT does not, and its `approve` reverts when it changes a non-zero allowance
  to another non-zero value: if `allowance(user, zap)` is not 0, send `approve(zap, 0)` first. The same holds for
  `MintRequests`: a filler who lost a race, or a requester whose request reverted, keeps a non-zero USDT allowance. Index tokens support
  `permit`. Approve exact amounts.
- **Fee-charging currencies are unsupported.** Zap calls revert with `TransferShortfall`. Simulate every transaction
  first and offer the direct `redeem` or `redeemSkipping` exit.
- **Label pausable components and every issuer.** WBTC can be paused by its custodian. Show that on every index that
  holds it, and surface `redeemSkipping` plus any pending `claimOf` balance.
- **Claims follow the recipient.** `redeemSkipping(shares, to, skipMask)` books the skipped components to `to`, and
  `ClaimRecorded` names `to`. Read `claimOf(to, token)`, and have a contract that redeems for a holder pass the holder
  as `to` (DA-17).
- **Show pending proposals.** A listing takes effect between `ListingProposed(token, eta, referenceSupply)`'s `eta`
  and 7 days later; a supply batch between `SuppliesProposed(batchId, eta, tokens, referenceSupplies)`'s `eta` and 7
  days later, all at once (`ReferenceSupplySet` for each token, then `SuppliesExecuted`); a new guardian after
  `GuardianProposed` plus 7 days. Ask `listingPending(token)`, `suppliesPending()` and `guardianChangePending()` whether
  a proposal can still be executed: an expired one leaves `listingEta`, the batch's eta in `pendingSupplies()`,
  `pendingGuardian` and `pendingGuardianEta` set, so those fields on their own read as pending forever (DA-16). Treat
  `GuardianProposed` as a security alert: once it executes, the owner's batches no longer face the old guardian's veto.
- **Returned components.** Whenever the router takes less than it was given, the unsold part goes to the recipient
  with a `ComponentReturned` event: every hop of a V3 burn leg, and as a rule only the first hop of a V4 burn leg,
  whose intermediate partial fill reverts the whole leg (CR-I07). A returned amount includes anything a stranger had
  left on the router, and a stray balance never makes a burn revert (CR-L02). Show them on the receipt.
- **ABIs.** `abi/IndexFactory.json`, `abi/IndexHub.json`, `abi/IndexZap.json` and `abi/MintRequests.json`, and for
  the hybrid product `abi/HybridIndexFactory.json` (the factory v4 launches on), `abi/IHybridIndex.json` (a hybrid
  index: its hub, module and extension answer at one address, so decode with this one interface) and
  `abi/XindexVault.json` (a vault on an EVM chain), are committed and regenerated by CI, which fails on a diff; decode
  every event and revert with them (`forge inspect <contract> abi --json` reproduces them, and the interfaces in
  `src/interfaces/` carry the NatSpec). Two things a hybrid index emits are not in `abi/IHybridIndex.json`: the
  `VaultMessage` event of every message it sends, declared in `VaultMessages` and found in
  `abi/HybridIndexFactory.json`, and the OpenZeppelin errors it can raise (ERC-20, ERC-2612, ECDSA, SafeERC20, SafeCast,
  the reentrancy guard and the initializer), which OpenZeppelin's own interfaces declare (C1-08). Read the constants
  on chain rather than hard-coding them: `LISTING_DELAY`,
  `PROPOSAL_WINDOW`, `GUARDIAN_DELAY`, `MAX_COMPONENTS`, `MAX_BATCH`, `MAX_SUPPLY_STEP`, `MAX_SUPPLY`, `MIN_RAW_UNITS`,
  `MAX_UNITS`, `K_SCALE` on the factory, and `MIN_REBALANCE_INTERVAL`, `REBALANCE_DELAY`, `AUCTION_DURATION`,
  `MAX_SUPPLY_STEP`, `MIN_BAND` on the hub; on the hybrid factory also `ROTATION_DELAY` and `FREEZE_DURATION`, and on a
  hybrid index also `MINT_LOCK`, `MAX_ORDER_LIFE`, `SETTLE_GRACE`, `MINT_CAP`, `REBALANCE_BOND`, `BOND_HOLD` and
  `DELIVERY_WINDOW`. Errors that several contracts raise (`ZeroAddress`, `LengthMismatch`, `Unauthorized`, `NotIndex`,
  `InvalidRecipient`) are declared once, in `IXindexErrors`.
- **A hybrid index mints by order, not through the zap.** An index holding any vault coin is a `HybridHub` clone; a zap
  call on one reverts with nothing moved. `components()` also returns each component's chain and vault token, and
  `chains()` the vault of each chain. A vault takes deposits only for an index registered there with
  `registerIndex(index, salt)`, which anyone calls with the factory's `indexSalt(index)`. A minter calls
  `openOrder(shares, deadline)`, with the deadline at most `MAX_ORDER_LIFE` (6 hours) away, which escrows the Ethereum
  components at once (`previewOrder(shares)` gives every amount), and deposits each vault coin on its chain before the
  deadline, on an EVM chain with the vault's `deposit(index, intakeId)`. After the deadline anyone calls `settleOrder`
  with a proof of each chain's intake, which counts the shares against `MINT_CAP`, 4% of the supply in any 24 hours
  (`mintRoom()`); `MINT_LOCK` (24 hours) later `claimOrder` mints them. The minter can `failOrder` an open order at any
  time, and anyone `SETTLE_GRACE` (6 hours) after its deadline: the escrow becomes the minter's claims, and each vault
  is told to let its depositors `refund`. `redeem(shares, to, recipients, skipMask)` pays the Ethereum components to
  `to` at once and sends each vault a burn toward `recipients[j]`, a 32-byte address on the `j`-th of `chains()`; a zero
  recipient books that chain's coins as claims of `to`, which `claimToVault` burns later. The vault pays it once P1 and
  P2 prove the message, within its speed limit (4% of what it holds for the index in any 24 hours, or its floor:
  `available(index, token)`), and `release` pays any rest later. A rebalance settles in three steps, `acceptRebalance`
  with a bond, the deliveries to the vaults, and `settleRebalance` on their proof (Stage B spec, section 5.3).
- **Events.** `IndexFactory`: `IndexCreated`, `ListingProposed`, `ListingCancelled`, `ReferenceSupplySet`,
  `TokenWhitelisted`, `SuppliesProposed`, `SuppliesCancelled`, `SuppliesExecuted`, `GuardianProposed`,
  `GuardianChangeCancelled`, `GuardianSet`, `OwnershipTransferStarted`, `OwnershipTransferred`. `IndexHub`: `Issued`,
  `Redeemed`, `ClaimRecorded`, `Claimed`, `RebalanceStarted`, `RebalanceCancelled`, `Rebalanced`, and the ERC-20 events.
  `IndexZap`: `ZapMint`, `ZapBurn`, `ComponentReturned`.
- **Watch the ownership handover.** `transferOwnership(new owner)` emits `OwnershipTransferStarted` and
  `acceptOwnership()` emits `OwnershipTransferred`. It is the one admin change with no delay and no guardian veto.
- **Errors.** `IndexZap`: `NotIndex`, `StaleRebalanceNonce`, `Expired`, `ZeroAddress`, `ZeroAmount`, `InvalidRecipient`
  (the zap, the index, the Universal Router, the PoolManager or the factory, RT-21), `LegCountMismatch`, `BadRoute(i)`,
  `ShortFill(i, received, required)`, `InsufficientBudget`, `InsufficientOutput`, `TransferShortfall`. `IndexHub`:
  `NotFactory`, `NotInitialized`, `InvalidComponents`, `ZeroShares`, `ZeroAddress`, `InvalidRecipient` (also for a share
  transfer to the index itself or its factory), `InvalidSkipMask`, `NothingToClaim`, `TransferAmountMismatch`,
  `Unauthorized`, `RebalanceTooSoon`, `RebalancePending`, `InvalidKeepMask`, `BandTooNarrow(lambdaMin, lambdaMax)`,
  `NoPendingRebalance`, `RebalanceNotReady`, `RebalanceExpired`, `RebalanceUnderfunded`, `RebalanceMovedOn`,
  `LengthMismatch`, and OpenZeppelin's ERC-20 and ERC-2612 errors. `IndexFactory`: `EmptyString`,
  `InvalidComponentCount`, `TokenNotWhitelisted`, `DuplicateToken`, `UnitsOutOfRange(token, units)`,
  `IndexAlreadyExists`, `NotAContract`, `AlreadyListed`, `NotConfigured`, `SupplyOutOfRange(token, referenceSupply)`,
  `SupplyStepTooLarge(token, inForce, proposed)`, `ListingPending`, `NoPendingListing`, `ListingNotReady`,
  `ListingExpired`, `NotWhitelisted`, `RelistChangesSupply`, `SuppliesPending`, `TokenInBatch`, `InvalidBatch`,
  `NoPendingSupplies`, `SuppliesNotReady`, `SuppliesExpired`, `NoPendingGuardianChange`, `GuardianChangeNotReady`,
  `GuardianChangeExpired`, `Unauthorized`, `LengthMismatch`, `RenounceDisabled`, and OpenZeppelin's `Ownable` errors.
  The hybrid contracts' errors and events are in their ABIs and interfaces.
- **Requests.** Suggest a limit from the app's own valuation and show the deadline; a fill pays exactly what the filler
  sends, so any surplus over the limit goes to the fastest filler. Read a request with `getRequest(id)` (`requester`,
  `deadline`, `isMint`, `open`, `index`, `stable`, `escrow`, `limit`) and follow `MintRequested`, `RedeemRequested`,
  `RequestFilled(id, filler, delivered)`, `RequestCancelled` and `RequestRefunded`. `escrow` is what arrived, which is
  less than the amount asked when USDT charges a fee. Errors: `NotIndex`, `NotAStable`, `ZeroAmount`,
  `InvalidDeadline`, `NothingEscrowed`, `RequestNotOpen`, `RequestExpired`, `RequestNotExpired`,
  `BelowLimit(delivered, limit)`, `Unauthorized`.
- **Swap failures arrive unwrapped.** The Universal Router wraps a command in `ExecutionFailed` only when it dispatched
  it with a low-level call, and swaps are internal calls, so the app decodes the pool's own error:
  `V3TooMuchRequested()`, `V3TooLittleReceived()`, `V4TooMuchRequested(uint256,uint256)`,
  `V4TooLittleReceived(uint256,uint256)`, `CurrencyNotSettled()`, or another PoolManager error, against the router's
  own ABI.

## Whitelist policy

Standard ERC-20s only: no fee-on-transfer, rebasing, or ERC-777/callback tokens; 6-18 decimals; the address must be a
contract. `issue` verifies the received amount. USDC and USDT are fine to mint *with* but are not *components*. A
component that can be paused or blacklisted, such as WBTC, must be labelled in the app. How a token's own supply is
minted does not matter, since nothing reads it: a wrap, an unwrap or an issuer's mint moves nothing the hub reads
(CR-M01).

**Reference supply.** Every listed token carries one, in its raw units, from 1 to `MAX_SUPPLY` (`uint128.max`): the
circulating supply of what the token represents. WBTC carries bitcoin's and WETH ether's, because their on-chain
supply is only the wrapped float. Each figure in `script/MainnetAddresses.sol` carries its source and date.

**Listing.** `proposeListing(token, referenceSupply)`, owner only, starts `LISTING_DELAY` (2 days); from then until
`PROPOSAL_WINDOW` (7 days) later anyone can `executeListing`, which whitelists the token and, on a first listing, sets
its supply; after that the proposal expires. Until it executes, the owner or guardian can `cancelListing` it. A listed token cannot be proposed
again (`AlreadyListed`): its supply changes only in a batch. Either role can `delist` a token at any time. Delisting
affects only indexes created afterwards and keeps the reference supply, because existing indexes still rebalance with
it; a batch can still revise it. Relisting takes a fresh proposal and delay at exactly the supply the token carries
(`RelistChangesSupply`, SA-02), and is refused while the live batch names the token (`TokenInBatch`). A first listing is
bounded only by `MAX_SUPPLY` and by review.

**Supply batches.** `proposeSupplies(tokens, supplies)`, owner only: 1 to `MAX_BATCH` (200) tokens in strictly
ascending address order, each already carrying a supply and none with a live listing, each new supply within
`MAX_SUPPLY_STEP` of the one in force (`|new − old| ≤ ⌊old × 0.005⌋`). One batch is live at a time. It executes all or
nothing, because a stranger who could execute half of a batch and start a rebalance on the half would turn a uniform
revision, which trades nothing, into a trade. A batch comes due `LISTING_DELAY` after its proposal and never sooner than
`MIN_SUPPLY_INTERVAL` (7 days) after the last batch executed, so a supply moves at most half a percent a week, on chain
and not only by policy (SA-04). `lastSupplyUpdate()` says when the last one executed.

## Stage A list: supplies and execution depth

Four components, the Ethereum tokens of the design's 0.2% weight floor that pass its liquidity screen (daily volume at
least 0.1% of market cap). `ConfigureWhitelist.defaultMainnetList()` ships them in this order:

| Token | Reference supply | Source |
|---|---|---|
| WETH | 122,070,499 ETH (`122_070_499e18`) | ether's circulating supply, CoinGecko, 2026-09-22 |
| WBTC | 20,087,871 BTC (`20_087_871e8`) | bitcoin's circulating supply, CoinGecko, 2026-09-22 |
| LINK | 748,099,970 LINK (`748_099_970e18`) | circulating, CoinGecko, 2026-09-22 |
| UNI | 620,716,422 UNI (`620_716_422e18`) | circulating, CoinGecko, 2026-09-22 |

- **WBT** (WhiteBIT's token) is on the design's floor list by weight but **stays off** (the owner's call on 2026-09-30,
  `design/2026-09-30-wbt-check.md`): its Ethereum contract lets a single key blacklist any holder and destroy its
  balance, and no Uniswap V2, V3 or V4 pool holds it. Without it the Stage A list covers 79.4% of the holdable top-100
  value at 4.2% a year of tracking error, on a backtest that held supplies constant and so understates it.
- **Left out.** v3's wstETH (a second claim on ether), wSOL (native SOL comes with Stage B) and AAVE (below the floor).
  LEO is on the floor list by weight but fails the liquidity screen.
- **Depth, measured on 2026-09-22.** LINK is deeper on V4 than V3 (about 6.6x); WBTC (0.26x) and UNI (0.66x) are
  deeper on V3. The app picks the venue per leg. Live V4 pools for these components are paired against native ether,
  not WETH.

## Known limitations

- **A lone executor can take up to the band.** A fill at λ leaves holders at least `λ / λmax` of the moving value at
  any prices, so an executor with no competition that waits for the floor keeps at most `1 − λmin/λmax` of it:
  0.995% when the clamp binds on both sides. How much of that it actually takes depends on where the break-even λ sits,
  which is a value-weighted average of the ratios: on a mainnet fork, a batch raising WBTC's supply 0.5%, cutting
  LINK's 0.5% and raising UNI's 0.3% gave a band of [0.995, 1.005] and a break-even of 0.99585 at real Uniswap quotes,
  and a fill at the floor cost the basket 0.085% (103,868.93 to 103,780.31 USDC for 1,000 index tokens). By the same
  formula, the opposite revision would put the break-even near the top, with most of the band within reach. Weekly, the
  worst case is about 0.11% a day, since a rebalance cycle takes at least 9 days; if every cycle's supplies moved the
  full step apart and no executor ever competed, about 33% a year (design section 6.6). The notice lets holders leave, the guardian can cancel a rebalance
  nobody competes for, and competition settles near the break-even.
- **A far-off component holds the others at the band's edge.** The clamp heals the extremes first: while one
  component's units sit more than the band away from its supply, every other moving component settles at the opposite
  bound, and their own revisions wait until the far one has converged. Nothing is taken beyond the band. Weekly steps
  of half a percent against up to 1% of correction a cycle keep that rare; a keep mask held over several cycles is the
  usual cause (SA-08).
- **The band covers the whole moving value, however small the trade.** A 0.5% revision of a component weighing 1% of
  an index trades about 0.005% of the index, yet opens a 0.5% band over everything that moves, so a lone executor can
  take up to about 0.5%. A price-free scalar auction cannot tell a small trade from a large one. Whether a price-free
  design can bound the exposure by the trade's size is an open question (design section 15).
- **Reference supplies are data the owner maintains.** The contracts cannot tell a mistyped or stale figure from a
  real one. What bounds a slip is the step: after a first listing a supply moves at most 0.5% per batch, each batch
  behind 2 days of notice and the guardian's veto, and each rebalance at most the clamp however many batches landed.
  The same bound makes a slip slow to undo: a figure 10% off takes about 20 weekly batches to walk back. A first
  listing is bounded only by `MAX_SUPPLY` and review, so check its figure while it can still be cancelled. Between
  updates, a token whose real supply grows faster than 30% a year relative to the rest stays underweight.
- **A due proposal takes effect when someone executes it.** Listings and batches are permissionless to execute once
  due, so between a batch's eta and its execution whoever acts first decides whether a rebalance started in between
  reads the old supplies or the new; both were reviewed, which bounds it. Execute a due batch promptly.
- **Rebalances clear only when the moving value pays for the fill.** Small indexes on mainnet rarely rebalance. An
  unfilled auction expires, and for `REBALANCE_DELAY` afterwards (less a second, CR-I02) only the owner and guardian
  can restart it. An index so small that a settlement moves no raw unit settles at `λmax` whoever executes; one that
  still moves a few raw units lets a lone executor pick λ within the band for next to nothing, which moves units within
  the band but no holder's value beyond rounding. Units per rebalance stay within `[λmin/λmax, λmax/λmin]` plus one
  raw unit, so a component held at a single raw unit can settle at two (CR-I03).
- **An exit sent during the auction can be overtaken by the fill.** The executor picks the block, so it can order its
  fill ahead of a redeem or a guardian cancel it sees in the public mempool. No bound moves, but the notice is the only
  reliable window to leave; during the auction, use a private relay (RT-02). Shares minted while a rebalance is pending
  share the outcome of any fill that lands after them, whatever the ordering.
- **The guardian can stall rebalancing.** `cancelRebalance` has no window and no rate limit, so a hostile or
  compromised guardian can cancel each proposal at the last second of its auction and hold rebalancing off while the
  units drift from the supplies. It moves no funds, holders redeem throughout, and the owner ends it by replacing that
  guardian: 7 days of notice the guardian cannot cancel, since it may only cancel its own removal (DA-12). A guardian
  can also stall without a cancel: a keep-mask rebalance that leaves a pair of components moving can clear `MIN_BAND`
  on a sliver of the index, and its fill restarts `MIN_REBALANCE_INTERVAL` for everyone, so the stall can outlast the
  guardian's replacement by up to a week. While a replacement is pending, the owner cancels the outgoing guardian's
  keep-mask proposals, and monitors alert on `RebalanceStarted` with a non-zero `keepMask` (RT-07).
- **Issuers can freeze components.** WBTC can be paused by its custodian. A paused component makes `redeem`, the zap
  and any fill that moves it revert; `redeemSkipping`, `claim` and the guardian's keep mask are the recourse, and a
  permanently frozen component needs the keep mask at every rebalance.
- **A request's surplus goes to the fastest filler.** A fill delivers what the filler sends and at least the
  requester's limit, so a generous limit is value left for fillers. The app suggests limits from its own valuation.
- **Circle and Tether freeze differently, and `MintRequests` cannot tell.**
  - Circle checks the sender, the recipient and the caller of every USDC transfer. A fill that pays a blacklisted
    requester reverts, and so does a refund of their USDC escrow, until Circle lifts the blacklist.
  - Tether checks only the sender of a `transfer` and only `from` of a `transferFrom`. A requester Tether has
    blacklisted can still be filled and refunded, into a balance they cannot move and Tether can destroy. The app
    should check `USDT.isBlackListed(requester)` before showing a USDT request to fillers, and warn the requester.
  - If an issuer blacklists `MintRequests` itself, every open escrow in that stablecoin waits with it. A Circle
    blacklist also stops fills of USDC redemptions, whose escrow is shares, although `cancel` still returns those.
    Tether can go further and destroy the contract's USDT, leaving those requests open but unbacked for good. A new USDT
    mint request first sends the contract nothing, which fails while it is blacklisted or USDT is paused, so no
    deposit is taken into a contract that could not pay it out (SA-01).
  - All escrows share one contract, so an issuer's only lever over funds parked there by someone it has since
    sanctioned is to freeze everyone's. A sanctioned requester's USDC escrow can still leave through a fill by an
    accomplice at a limit set before the sanction.
  - A pause of USDC or USDT stops every fill, cancel and refund in that coin until it ends.
  - Tokens sent to `MintRequests` outside a request stay there, since it has no owner to sweep them.
- **A request is an option held by every filler until it closes.** If something changes what a share is worth to the
  requester after they sign, for instance every component pausing, a filler can still deliver at the old limit, and a
  cancel sent to the public mempool can be overtaken by a fill. The loss is bounded by the requester's own limit. The
  app should default to short deadlines and send cancels through a private relay.
- **No fees.** Audits, a bug bounty and watchers are paid from outside (the owner's call on 2026-09-30).
- **Airdrops, rewards and governance votes** that accrue to tokens held by an index cannot be claimed or used; by design
  there is no admin who could sweep them.
- **A hooked V4 pool cannot be routed through.** The zap rejects any V4 route whose hops carry hooks or hook data, so a
  component whose only V4 depth sits behind a hook is reachable on V3 only.
- **A `tokenIn` that calls back into the zap is unsupported**, alongside fee-on-transfer currencies. The zap pre-funds
  the Universal Router with exactly a leg's cap and sweeps it back within the same `execute`; the pre-fund is the bound
  (CR-I14, RT-11). Mint and burn currencies are the user's choice, so the app should offer only USDC and USDT.
- **Zap gas grows with components and hops, and nothing on chain bounds it.** See "Gas" above: about 35 components is
  the zap's practical limit. The in-kind path is what fits at 100.
- The zap is pinned to **Universal Router 2.0.0** rather than the 2.1.x line, whose command inputs carry an extra
  per-hop price array. Moving to a newer router means a new zap; the hub and factory do not depend on it.
- Bytecode targets the Cancun EVM (`evm_version = "cancun"`), which TRON has on (`tron/README.md`); `BnbStateVerifier`
  also needs Prague's BLS12-381 precompiles, which Ethereum and Sepolia have. Re-check before deploying to any other
  chain.

For an index holding vault coins (Stage B, not deployed; the Stage B spec has the full account):
- **Shares that rest on a vault proof enter at most 4% of the supply a day.** `MINT_CAP` holds an order's shares and a
  migration's alike, so after its creator's seed a new index version takes in the old one's holders at 4% of its own
  supply a day.
- **The mint cap is first come, first served.** Whoever settles an order first uses the index's 4% a day, with no
  share per minter: a holder of enough of the components can keep it full, and an order that cannot settle is failed
  by anyone `SETTLE_GRACE` after its deadline, its deposits refunded. Mints then wait until the cap frees, while holders
  redeem and trade throughout; that holder's redemptions also draw on the vaults' speed limit, which is first come too
  (A2-03).
- **A vault pays out at most 4% of what it holds for an index in any 24 hours**, or its floor. A large burn of a vault
  coin is paid in parts; the rest stays owed, and anyone can `release` it as the limit allows.
- **Every verifier must be advanced daily.** `BnbStateVerifier` and `TronStateVerifier` let a validator set or
  producer list name its successor only within `MAX_LAG` (1 day) of its start, so a verifier left a day behind (TRON's,
  about 18 hours behind a boundary) stops for good. Mints on that chain then stop until the registry replaces the
  verifier, a 30-day rotation (FAC-1); funds stay safe, and burns still pay, since they need only Ethereum's proofs.
  TRON's also stops if nine of the producers its list recorded are voted out or change keys before vouching for the
  next list (TRN-3). P1's and P2's verifiers on a vault chain keep the same pace: a proof covers at most 225 epochs, a
  day, past the verifier's anchor, and `update` refuses any proof once a day has passed since the anchor's epoch began
  (`lagEnds()`), so one left further behind stops for good and must be replaced (LG-4; Stage B spec, section 10).
  Every update must also land a checkpoint whose epoch began within 6 hours of now (`MAX_UPDATE_AGE`), so nobody can
  age a verifier to that limit by landing stale steps (B5-01); the CometBFT and VeChain verifiers hold an update's new
  head to the same age (A5-01). A day in which nobody proves still stops a verifier, so independent provers matter.
- **TRON's state rests on 19 of its 27 producers,** who could forge a proof at no cost to their stake, since TRON has
  no slashing.
- **TRON's 80 ms CPU limit leaves a proof check little room.** TRON fails a transaction past 80 ms of CPU time and burns its whole fee limit;
  the Groth16 check in a P1 or P2 `update` took about 40 ms in java-tron on the machine measured. Whoever sends
  `update` there sets a fee limit near its energy, about 300,000, and the margin is measured again on Nile, TRON's test
  network, before mainnet (`tron/README.md`).
- **P1 and P2 prove one statement.** Two zkVMs from two teams, with two Groth16 setups, guard against a broken prover,
  but a bug in the statement they share (`proofs/finality`) would break both at once (Stage B spec, section 11).
- **NEAR's and Stellar's states rest on unslashed trust.** NEAR's verifier needs more than two thirds of each epoch's
  block-producer stake honest, and NEAR slashes nobody; Stellar's needs 7 of Tier 1's 10 organisations, two validators
  each, and Stellar slashes nobody either. That is TRON's kind of trust, bounded as every chain's is by its quantity cap,
  the 24-hour lock and the mint cap. A new Tier 1 means a new Stellar verifier, through the 30-day rotation, and until
  it replaces the old one a retired or leaked Tier 1 key still counts: the verifier's one-day limit is on a ledger's
  age, and the signers write its close time.
- **A Stellar transaction holds 132 KB.** A message whose receipt proof is larger, which anyone can force by wrapping a
  permissionless call in a transaction of large logs, is delivered from the copy `resendMessage` emits in a clean one.
  Sui's 128 KB transactions are handled the same way.
- **Sui, Injective, VeChain and Aptos rest on unslashed stake too.** None of the four slashes a validator's principal
  for signing a fork: Sui's 127 validators, Injective's 45 (both its slashing fractions read 0), VeChain's 101 and
  Aptos's 85 are trusted as TRON's and Stellar's are, by more than two thirds of their stake, bounded by each coin's
  cap, the 24-hour lock and the mint cap. Each chain also keeps powers over contracts: Sui's validators can deny
  transactions to an object, as they did against the Cetus exploiter in 2025, and a stake vote once moved coins;
  VeChain's 4-of-5 Executor sets consensus parameters; Aptos's and Injective's governance can upgrade their chains.
- **VeChain's weights are attested, not proven.** Nothing public proves the Staker's storage, so a keeper sends
  `VeChainStakerAttester.attest` each round a proof needs, and a new table is trusted once more than two thirds of the
  trusted one's weight sign blocks after it, TRON's vouching rule.
- **Sui's verifier proves only the epoch in force.** Once anyone records the next committee, a proof of a checkpoint
  from the epoch before is refused, one in flight included: its prover attests again and proves under the new
  committee. Near an epoch's end that costs a re-proof, and can delay a settlement, but never loses a state (A6-05).
- **Aptos's inputs come from Aptos Labs' backups.** Signed ledger infos and accumulator proofs are not on Aptos's
  public API, only in Aptos Labs' public database backups, every byte checked against signatures. If the backups stop,
  a prover needs its own full node; a state is provable two to four hours after its `attest`.
- **A mass slashing between two proofs lowers what a forger risks.** The statement counts each signer by the anchor's
  records, up to a day old, with a margin for the churn since. A validator slashed after the anchor still counts there
  as unslashed, and can no longer be slashed for signing a forgery; no churn limits how many are slashed. Such a
  slashing would be a public attack on Ethereum itself (LG-I1; Stage B spec, section 10).

## Mainnet addresses

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
| HybridIndexFactory / IndexZap / MintRequests | not deployed |

The scripts read mainnet addresses and reference supplies from `script/MainnetAddresses.sol`, which
`test/fork/MainnetAddresses.fork.t.sol` checks on-chain: tokens by symbol and decimals, the router and the PoolManager
by their runtime code hashes (every Universal Router build answers `poolManager()` alike, CR-I35), and the default list
on a fresh factory. The quoters and StateView are for apps and tests; no contract reads them.

## Development

```bash
forge build --sizes
forge lint -D notes             # fails on any warning or note
forge fmt
forge test                      # unit, fuzz, invariant and security regression tests, no RPC needed
forge coverage                  # 100% on every file
aderyn .                        # Cyfrin's analyzer on src/, configured in aderyn.toml: reports nothing

# end-to-end against the real Universal Router, V3 and V4 pools, USDC, USDT and a real WBTC pause
# (skipped when the env var is unset)
MAINNET_RPC_URL=https://... forge test --match-path 'test/fork/*' -vvv
# non-archive RPCs only serve recent state; override the pinned block:
MAINNET_RPC_URL=https://... FORK_BLOCK=<recent block> forge test --match-path 'test/fork/*'
```

CI (`.github/workflows/test.yml`) checks that every submodule commit matches `foundry.lock`, then runs fmt, build (with
warnings denied), `forge lint -D notes`, tests, 100% coverage on every file (offline suites), the ABI diff and the Wake
detectors on `src/`, with pinned Foundry and Wake versions. Four more jobs run the Rust and Move gates of the shared core
(`crates/xindex-core`) and of NEAR's, Stellar's and Aptos's vaults (tests, formatting, clippy with warnings denied, the
Wasm builds), on Rust 1.98.1 and the Stellar and Aptos CLIs pinned by version and SHA-256. Pushes to `main` and pull requests into it from this repository fail
until a `MAINNET_RPC_URL` repository secret exists, so the fork tests always run there; it needs an archive node for the
pinned fork block. Pull requests from forks get no secrets and skip the fork suites, so re-run them before merging. A
keyed RPC may throttle four fork suites run in parallel; run them with `-j 1` when a revert appears next to an HTTP 429.
CI does not run Aderyn yet, so run it before pushing. Nor does it run Solana's programs (they need the SBF platform
tools), Sui's vault (a 1 GB release), the proof statements or the TRON and VeChain deploy tools: their builds, tests and
rehearsals are in `solana/README.md`, `sui/README.md`, `proofs/README.md` (with `proofs/near`, `proofs/stellar`,
`proofs/cometbft`, `proofs/vechain` and `proofs/aptos`), `vechain/README.md` and `tron/README.md`, and each sits beside
the gates of the ones CI does run in `crates/xindex-core/README.md`, `near/README.md`, `stellar/README.md` and
`aptos/README.md`.

### Deploy

Nothing below has been run for v4. Never put a private key in `.env`. Import the deployer key once into an encrypted
keystore, or use a hardware wallet with `--ledger`:

```bash
cast wallet import deployer --interactive
cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
source .env
forge script script/Deploy.s.sol --rpc-url mainnet --account deployer --sender <deployer address> --broadcast --verify
```

`Deploy` deploys v4's one factory, `HybridIndexFactory`, and with it both templates: the factory deploys the `IndexHub`
implementation itself, and the `HybridHub` template, its module and its extension come first, each built for the
factory's address, which the script predicts from the broadcaster's nonce (the factory refuses a template built for any
other). An index of Ethereum tokens only is an `IndexHub` clone; one holding any vault token is a `HybridHub` clone. Then
come the zap, which mints and burns `IndexHub` clones only (a hybrid index's mints are orders, and a zap call on one
reverts with nothing moved), and `MintRequests`, which takes any index's shares. Vault chains and vault-token listings
are proposed afterwards, through the factory's timelock.

`OWNER` and `GUARDIAN` are required and must differ. On mainnet the owner must be a contract that is not an EIP-7702 delegated account, and a Safe
must need at least three signatures (`MIN_OWNER_THRESHOLD`, the design's 3-of-5) and have no enabled module, because
a module acts as the Safe without signatures
(keep it that way after deployment; the script cannot see later changes). A contract that answers no Safe
`getThreshold`, such as a smart account of one key, a forwarder to a hot key or a Safe whose call reverts, shows nothing
of how many keys control it and is refused (`OwnerNotASafe`); `OWNER_IS_NOT_A_SAFE_ACK=true` accepts one that is a
multisig of another kind, such as a timelock over a multisig, on the operator's word (a Safe stays held to its
threshold and modules whatever is said), and the deploy log prints the owner's code hash either way, to review (A7-08).
The guardian must not be the broadcasting
key, which must hold no role; the role checks name the key Foundry sends from (`--account`, `--ledger`, `--sender`), which
`deploy` reads once, and not the script's own `msg.sender` (A7-19); when the owner is a Safe, neither the guardian nor the broadcasting key may be one of
its signers, since the guardian is the owner's veto (SA-06); and neither role may be a market contract: the router and its PoolManager everywhere, and
on chain 1 also every token and mint currency in `script/MainnetAddresses.sol` (CR-I37). `UNIVERSAL_ROUTER`, `USDC`
and `USDT` default to mainnet's on chain 1, where any other value is rejected, and are required anywhere else; they are
the script's only market addresses, because the hub and factory depend on no Uniswap contract.

**Deployment record.** `forge script --broadcast` writes `broadcast/Deploy.s.sol/<chain id>/run-latest.json`: the git
commit, each transaction with its init code, and the addresses. Broadcast from a clean, committed tree
so the recorded commit is the deployed source, commit the record with the README address table (on mainnet with `git
add -f`: `.gitignore` keeps chain-1 records out, because fork rehearsals keep chain id 1), and verify the source on the
explorer (`--verify` needs `ETHERSCAN_API_KEY`). The deploy log ends with the runtime code hashes of the factory, the
`IndexHub` implementation, the `HybridHub` template, its module, its extension, the zap and `MintRequests`: record them
with the addresses, and
`Deploy.checkDeployment(factory, zap, requests)` re-reads them later (it also refuses a zap or a `MintRequests` that
does not point at that factory).

**A vault chain** on an EVM is set up with `script/DeployVault.s.sol`, on that chain:
P1's verifier on SP1's Groth16 verifier, P2's on RISC Zero's, the state reader and the vault, with its `VaultSnapshot`
library. It refuses any Groth16 verifier that does not name itself SP1's v6.0.0 (`VERIFIER_HASH`) or RISC Zero's 3.0.0
(`SELECTOR` `0x73c457ba`, its published control ids), so an owned gateway, router or emergency stop, which answers neither, is
refused; it refuses a deployment on the indexes' own chain, a missing address, key or anchor, an anchor with less than 12
hours (`MIN_ANCHOR_SLACK`) of P1's and P2's day left, since the first advance needs two proofs of Ethereum's finality
and a transaction there, a native cap of zero, a floor above the cap, and roles that are not what the vault assumes: a
freezer or recovery multisig that is unset, shared, or the broadcasting key, and a recovery multisig that is not held to
the factory owner's rule, a Safe that needs at least three signatures, has no enabled module and counts neither the
freezer nor the broadcasting key among its signers (A7-09). It is the last line under a stall, since it proposes the
successor pair that only the freezer's two vetoes can stop. A recovery multisig that is not a Safe, on a chain that has
none, needs `VAULT_RECOVERY_IS_NOT_A_SAFE_ACK=true`. Its environment variables
are listed in the script; the anchor and P1's key come from `proofs/` (`p1-input check-state`, `p1 vkey`) and P2's
image id from `proofs/p2` (`p2 image-id`). `DeployVault.checkDeployment` re-reads, against the parameters the owner and
guardian approved, everything they approve before `proposeChain`: the wiring, the freezer, the source chain, P1's program
key and P2's image id, both anchors with their epochs and genesis time, and the native cap and floor, and returns the
code hashes for the release record (A7-06).

**The Groth16 verifiers are named, not proven, by the script.** `VERIFIER_HASH`/`VERSION` and `SELECTOR`/`VERSION` are
answers to view calls: they catch a wrong address, but an owned proxy over a real verifier forwards them and passes, and
so does any contract that answers them, as the repository's mocks do by design (`DeployVault`, `DeployStateVerifier`'s
NEAR, Stellar, Injective, VeChain and Aptos deployments and both JS tools take the same check). The release step that
closes the gap is the runtime code hash: before running `DeployVault` or `DeployStateVerifier`, compare `cast codehash
<address>` of each verifier with the official deployment's, or with the vendored build's (`prototype/evm/src/sp1`,
`vendor/risc0-ethereum` built as `vechain/build.mjs` builds them), and read the EIP-1967 admin and implementation slots of
the address to see that it is no proxy; record the two hashes in the release record with the others. The script cannot
pin them yet, since the official deployments' addresses and code differ by chain and none exists on some, such as
VeChain: where a chain has none, leave `VAULT_SP1_VERIFIER` and `VAULT_RISC_ZERO_VERIFIER` unset and let the TRON and
VeChain tools deploy the vendored ones themselves, which is the only path whose code the release builds (A7-01).

TRON's is deployed with `tron/deploy.mjs`, DeployVault's twin under Tron's compiler, with the same checks
(`tron/README.md`); it and `vechain/deploy.mjs` refuse a working tree that differs from its commit and any build output
compiled from other sources than the ones on disk, and record the commit and the compiler beside the addresses (A7-10). Injective runs `DeployVault` unchanged, once SP1's and RISC Zero's Groth16 verifiers are deployed
there from their own repositories; VeChain's goes up with `vechain/deploy.mjs`, which also deploys
`VeChainStakerAttester` and clears every contract's Prototype master (`vechain/README.md`). NEAR's, Stellar's, Sui's
and Aptos's vaults are deployed with their chains' own tools, which no script here drives yet: NEAR's vault, with P1
and P2 compiled in, goes to a keyless account fixed by its code and its initial state (NEP-616, `near/README.md`);
Stellar's P1, P2 and vault deploy as plain Wasm, every setting fixed in their constructors (`stellar/README.md`); Sui's
package is published and made immutable in one transaction (`sui/README.md`), and Aptos's is published with an
immutable upgrade policy (`aptos/README.md`). On Ethereum each chain is added as below by its registry id: TRON's is
728126428, Injective's 1776 and VeChain's its genesis id, and NEAR's, Stellar's, Sui's and Aptos's are the first 8 bytes
of `keccak256` of their CAIP-2 names (`design/2026-10-03-near-stellar-interfaces.md`,
`design/2026-10-04-four-chains-interfaces.md`). A chain holds a vault only once Ethereum can verify its state: today
BNB Chain, TRON, NEAR, Stellar, Sui, Injective, VeChain and Aptos, whose state verifiers are built; section 8 of the
Stage B spec has every other chain's status.

**The chain's state verifier** is deployed on Ethereum with `script/DeployStateVerifier.s.sol`, from an anchor that
the fixture generator reads off the chain: BNB Chain's newest final epoch block and its validators' keys, or TRON's
producers of the period in progress, each checked there before it is written. The anchor is all the verifier
trusts, since every later set or list is proven from it. The script deploys only on Ethereum (mainnet or Sepolia), and
refuses a BNB anchor more than an hour old or a TRON period that has ended. Someone must then `advance` the verifier
within a day of its anchor, and every day after, or it stops for good and the chain registry has to replace it.

NEAR's and Stellar's verifiers check SP1 proofs of their chain's finality, each for one vault, so their anchor files are
assembled by hand from their generators' output and the program's key (`near vkey`, `stellar-proof vkey`), and
`STATE_SP1_VERIFIER` names SP1's Groth16 verifier v6.0.0, a bare verifier:
- **NEAR's** holds `epochId`, `producersHash` and `namedAt` (nanoseconds) from the `anchor` of
  `proofs/near/fixtures/generate.py`, the vault's `account` and the registry `chainId`. A set of producers is named an
  epoch, about 7.2 hours, before it serves, so the script refuses one named more than 16 hours ago or in the future.
  Someone must then `update` the verifier to each next epoch within a day of its naming, or it stops for good.
- **Stellar's** holds the `networkId` and Tier 1's `quorumSet` XDR from `proofs/stellar`'s generator, the registry
  `chainId` and the vault's contract id as `vaultId`. The script refuses a network id that is not the hash of the
  network's passphrase. Nothing advances it: each proof carries its own ledger, at most a day old, and a new Tier 1 is
  a new verifier through the 30-day rotation.

The four chains of 4 October follow the same pattern, each anchor carrying the generator's chain data and the
deployment's own ids (`design/2026-10-04-four-chains-interfaces.md`):
- **Sui's** (`test/fixtures/sui/generate.py anchor`) is an epoch, its committee's keys and powers, and its start, with
  the vault's object id and package id. The script refuses a committee Sui's `Committee::new` would refuse (a key not
  the uncompressed form of its compressed one, keys out of order or named twice, powers not totalling 10,000) and an
  epoch begun more than 20 hours ago; the verifier then stops two days after that start unless updated.
- **Injective's** (`proofs/cometbft/fixtures/generate.py anchor`) is a header, refused when more than an hour old or on
  the wrong network (`injective-1` with 1776, `injective-888` with 1439).
- **VeChain's** (`proofs/vechain/fixtures/generate.py anchor`) is a staker table read at a finalized block, chosen after
  the vault and the attester are deployed, refused when more than 6 hours old.
- **Aptos's** (`proofs/aptos/fixtures/generate.py anchor`) is an epoch's validator set, refused when named more than 3
  hours ago.

For every chain the script refuses a registry id that does not pair with the Ethereum network: mainnet's on mainnet,
the testnet's on Sepolia.

```bash
mkdir -p anchors   # the one place the scripts may read an anchor file from (foundry.toml's fs_permissions, A7-18)
python3 test/fixtures/bnb/generate.py https://bsc-rpc.publicnode.com anchor anchors/bnb-anchor.json
STATE_CHAIN=bnb STATE_ANCHOR=anchors/bnb-anchor.json forge script script/DeployStateVerifier.s.sol --rpc-url mainnet --account deployer --sender <deployer> --broadcast
# TRON: test/fixtures/tron/generate.py https://api.trongrid.io anchor anchors/tron-anchor.json, then STATE_CHAIN=tron
# NEAR, Stellar, Injective, VeChain and Aptos: STATE_CHAIN=<chain>, STATE_ANCHOR=<the file above>, STATE_SP1_VERIFIER=0x...
# Sui: STATE_CHAIN=sui, STATE_ANCHOR=<the file above>; it checks its committee's signatures itself
```

During the chain's listing delay the owner and guardian review the verifier, whoever deployed it, since it is the trust
root for every index's mints on that chain. `DeployStateVerifier.checkBnb` and `checkTron` confirm that the verifier runs
this release's code and started from the anchor file. `checkNear`, `checkStellar`, `checkSui`, `checkInjective`,
`checkVeChain` and `checkAptos` take the arguments the verifier was built with and compare each value it trusts, its
SP1 verifier, program key, network, vault and the rest, and the anchor it holds, with them (`WrongParameter`,
`WrongAnchor`); then they compare its runtime code with a reference they build in the same run from those arguments, since
the immutables are in the code and the compiler's output cannot be compared (`WrongCode`). A verifier built from other
source, or from this source with another SP1 verifier or key, is refused though it holds the real anchor, and each helper
returns the code hash for the release record (A7-02). The anchor file itself is compared with the chain: the epoch
block's hash and its validators' registered keys, or `listwitnesses` and the period's blocks, NEAR's epoch, producers'
hash and vault account against its RPC, Stellar's quorum set's hash against Tier 1's published validators.

**Adding the chain on Ethereum** goes through `script/ConfigureChains.s.sol`, or the equivalent calls through the Safe:
`proposeChain` with the vault and the chain's state verifier, then, once the chain is registered, `proposeVaultListing`
for each coin its vault holds, with a reference supply in the coin's smallest unit. Each waits `LISTING_DELAY` and is
executed by anyone. The modes are `safe`, `propose` and `execute`, as for listings. The script skips, with the reason,
anything the factory would refuse or that is already done or pending, and reverts on an entry named twice (RT-24). A
registered chain's vault is fixed, and a new state verifier for it is a 30-day rotation (FAC-1), proposed only for a
chain named in `ROTATE`. Nothing on chain records that the guardian cancelled a chain proposal or a first listing, or
delisted a coin, so, as `ConfigureWhitelist` does (RT-06, XA-11), a routine run proposes none of them unasked: a chain
never registered only when `LIST_CHAINS` names it (`all` for every entry), a coin never listed only when `LIST_COINS`
names it (`chainId:tokenId` pairs, or `all`), and a delisted coin, which would come back at the supply in force, only when
`RELIST_COINS` names it (A7-03). A vault is exactly an address, 40 hex digits, or a 32-byte id, 64: a registered chain's
vault is fixed, so any other length, such as TRON's 21-byte form with its `0x41` prefix, would burn the chain id (A7-04). A
coin's entry is `chainId:tokenId:supply:decimals`; its listing is skipped unless the supply, shown in whole units in the log
and in the Safe's labels, is between a million and a trillion, because coins' decimals run from 6 to 24 and a first figure a
thousand times too large takes about 460 weekly batches to undo (A7-05).

```bash
# the chain, for the Safe; vaults and coin ids are hex words, left-padded
CHAIN_MODE=safe CHAINS_FACTORY=0x... CHAINS=56:<vault>:<state verifier> LIST_CHAINS=all forge script script/ConfigureChains.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account
CHAIN_MODE=execute CHAINS_FACTORY=0x... CHAINS=<same> forge script script/ConfigureChains.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
# then its native coin, 0x0, and its listing the same way
CHAIN_MODE=safe CHAINS_FACTORY=0x... CHAINS=<same> VAULT_TOKENS=56:0x0:<supply>:<decimals> LIST_COINS=all forge script script/ConfigureChains.s.sol --rpc-url mainnet
```

Once listed, a vault coin's supply is revised in the weekly batch with every other (`ConfigureWhitelist`), its entry
naming it by its Ethereum-side id, the factory's `vaultTokenId(chainId, tokenId)`. That script checks only its supply's
range, since it has no code on Ethereum, and its listing modes skip it, since `proposeVaultListing` lists it.

**Before the launch listing, refresh the reference supplies.** The first listing sets each component's supply from
`defaultMainnetList()`, whose four figures in `script/MainnetAddresses.sol` are CoinGecko's circulating supplies of
2026-09-22, each dated beside it, and a first figure can afterwards move by at most half a percent a week. The day
before `LISTING_MODE=safe ... WHITELIST=default LIST=all` is run, read each figure again from its source (LINK's and UNI's
circulating supplies move with unlocks, bitcoin's about 0.8% a year), rewrite the four constants with their new date and
source, and update `test_CRL08_theDefaultListIsTheReleaseRecord`, which pins them, then check each figure again while
the proposal can still be cancelled (A7-20). A launch run weeks after the dates lists stale
figures, and nothing in the contracts can tell.

**Listings and supply batches** go through `script/ConfigureWhitelist.s.sol`, or the equivalent calls through the Safe:

```bash
# owner is a key you hold (testnets and local forks only; a contract owner such as the mainnet Safe cannot sign, and
# the broadcasting modes then revert with OwnerIsContract: use the safe modes)
LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> LIST=<tokens to list> forge script script/ConfigureWhitelist.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
# owner is a Safe: print the listing proposals as calldata to sign in the Safe app (nothing is broadcast);
# LIST=all on the launch run only, and unset on every later run
LISTING_MODE=safe FACTORY=0x... WHITELIST=default LIST=all forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
# every week: this week's supplies as one proposeSupplies call for the Safe
LISTING_MODE=supplies-safe FACTORY=0x... WHITELIST=<this week's entries> forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account: execute every due listing, or the due batch
LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
LISTING_MODE=execute-supplies FACTORY=0x... WHITELIST=<same entries> forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`LISTING_MODE` is one of `propose`, `safe`, `execute`, `supplies`, `supplies-safe`, `execute-supplies` and `status`.
`WHITELIST` is `default` for the mainnet list above (chain 1 only), or comma-separated `token:referenceSupply` entries,
both fields required, the supply in the token's raw units; anything else reverts `MalformedEntry`, and a list that
names a token twice reverts `DuplicateEntry` in every mode (RT-24).

- **Propose and safe** propose a listing for each entry that is not listed and has no live proposal, skipping with the
  reason logged: a token never listed unless `LIST` names it (`LIST=all` for every entry), a delisted token unless
  `RELIST` names it, a token the live supply
  batch names (the factory would refuse it with `TokenInBatch`, DA-20), and any entry outside the policy the script can
  check (a token with code and 6 to 18 decimals, no mint currency, which is the deployment's own USDC and USDT, read from the
  same `USDC` and `USDT` environment variables `Deploy` takes, and mainnet's wherever it runs (A7-22), a supply from 1 to
  `MAX_SUPPLY`). Safe mode applies
  the same checks, because a Safe batch sends every proposal in one transaction and one the factory refuses takes the
  rest down with it (CR-I38). Nothing on chain records that the guardian cancelled a first listing, so leave `LIST`
  unset on a routine run and a cancelled listing stays cancelled until the operator names it again (RT-06). Each
  proposal is logged with the token's symbol (a symbol that is not an ABI string shows as `?`, RT-25) and its supply
  in whole tokens, where a decimals slip shows: read both before signing. A relisting proposes the supply the token
  carries, whatever the entry says, and the entry's figure goes in the next batch (SA-02).
- **Supplies and supplies-safe** build the week's batch: every entry whose token carries a supply other than the
  entry's, sorted by address, skipping with the reason a token never listed, one with a live listing, one outside the
  policy, and one whose new supply is more than one step away (a larger revision goes in weekly steps). With nothing
  to batch they revert `NothingToBatch`, and while a batch is still live `BatchStillLive`, since the factory would
  refuse a second one and this week's would be measured against supplies about to change (SA-05).
- **Execute and execute-supplies** never propose. They run only a due proposal whose supply is exactly the entry's,
  and log why a pending one was left: not ready, expired, or a supply the entries do not name.
- **Status** is read-only: for every entry, whether the token is listed, whether the supply in force is the entry's,
  any pending listing with its window, and whether the live batch names it.

In the Safe app, a safe mode's output becomes one Transaction Builder batch: each calldata line is one transaction to
the factory with value 0, under a label line naming the call and the token. At least three of the Safe's signers sign
it (the owner Safe's threshold, `MIN_OWNER_THRESHOLD`), and one executes it. For a local stack, `anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against `http://127.0.0.1:8545`; the
fork keeps chain id 1, and `.gitignore` keeps those rehearsal records out of git. An ignore rule does not cover a file
git already tracks, so check `git status` after a rehearsal.

### Operations runbook

No bot runs Xindex, so these duties have owners and deadlines. Watch the events that start each clock.

| Duty | Starts with | Deadline | Who | How |
|---|---|---|---|---|
| Propose the weekly supply batch | the weekly review | none, but an index drifts from real supplies meanwhile | owner Safe | new dated figures in the entries, `LISTING_MODE=supplies-safe`; each supply within 0.5% of the one in force, larger moves in weekly steps; it comes due a week after the last batch executed at the earliest |
| Veto a wrong batch or listing | `SuppliesProposed`, `ListingProposed` | before `eta` (2 days) | guardian or owner | check every figure against its source; `cancelSupplies()` or `cancelListing(token)` |
| Execute a batch or listing | its `eta` | `eta + PROPOSAL_WINDOW`, or it expires silently | anyone, owner signers first | `LISTING_MODE=execute-supplies` or `execute` at the eta; `suppliesPending()` and `listingPending(token)` say whether it can still run |
| Trigger the weekly rebalance | `lastRebalance + MIN_REBALANCE_INTERVAL`, after a batch changed a supply | none, but units drift from the supplies | anyone | `canStartRebalance()` and `previewBand(0)`, then `startRebalance(0)`; `BandTooNarrow` means there is nothing to rebalance |
| Check each rebalance | `RebalanceStarted` | before `eta` (2 days) | guardian | recompute the band from the units and the supplies in force, confirm the batch behind it was the reviewed one; `cancelRebalance()` on a mismatch |
| Watch keep-mask rebalances | `RebalanceStarted` with a non-zero `keepMask` | before `eta` | owner signers | while a guardian replacement is pending, cancel the outgoing guardian's keep-mask proposals (RT-07) |
| Fill auctions | the auction opens at `eta` | `eta + AUCTION_DURATION` | any executor contract | the protocol runs none; competition is what keeps a fill near the break-even |
| Rebalance around a frozen component | a paused or blacklisting component | each auction | guardian | `cancelRebalance()`, then `startRebalance(keepMask)` |
| Restart after an unfilled auction | `eta + AUCTION_DURATION` passed with no `Rebalanced` | anyone after `REBALANCE_DELAY` more | guardian first, then anyone | `canStartRebalance()`, then `startRebalance(0)` |
| Re-check venue depth per leg | monthly, and before a large mint or burn | none | app | V3 and V4 depth move independently; the route is the app's choice |
| Watch guardian changes | `GuardianProposed` | `eta` (7 days) | owner signers, guardian, app | a security alert: once executed, the new guardian's veto replaces the old one. `guardianChangePending()` says whether it is still executable |
| Hand over factory ownership | `OwnershipTransferStarted` | none: it takes effect as soon as the new owner accepts | owner signers, then the new owner | the one admin change with no delay and no veto; announce it first, and the new owner has to meet the rules the deploy script checks |
| Advance each chain's state verifier (Stage B) | its anchor, then each BNB Chain epoch or TRON 6-hour list | `MAX_LAG` (1 day), or it stops for good | anyone | `advance`; `DeployStateVerifier` logs the first deadline |
| Advance P1 and P2 on each vault chain, and the vault's checkpoint (Stage B) | each verifier's last anchor | `lagEnds()`, a day after the anchor's epoch began, for P1 and P2, or they stop for good; `STALL_PERIOD` (7 days) for the vault, which then takes no deposit | anyone | a proof from each system (`proofs/README.md`) to each verifier's `update`, then the vault's `advanceCheckpoint` |
| Deliver each message to its vault (Stage B) | `VaultMessage` from an index or the factory | none, but a burn is paid only once delivered | anyone | the vault's `deliver` with P1's and P2's proofs of it, then `release` for any part the speed limit held back. A message whose transaction's receipt is too large to prove there is first sent again in a transaction of its own, with the index's or the factory's `resendMessage(payload)` (LG-1) |

### Testnet (Sepolia)

**v4 is not deployed on Sepolia.** v3 runs there, deployed on 2026-09-27 from `4b4dbe4`, the commit tagged `v3.0.0`;
nothing on `main` can drive it, since its factory takes feed configs, and its deployment records are not kept here.

The Stage B scripts take Sepolia as Ethereum: `DeployStateVerifier` deploys there, `DeployVault` takes its chain id as
`VAULT_SOURCE_CHAIN_ID`, and P1 and P2 have Sepolia builds (`--features sepolia`, `proofs/README.md`). `demo/` holds
the hackathon's testnet demonstration, a Foundry project of its own: the real factory, hub and vaults, with stub
verifiers that trust relayer keys in place of some or all of the proofs, so nothing in it may reach a mainnet. No
deployment of it is recorded on a public testnet (`demo/README.md`).

`script/testnet/SetupTestMarket.s.sol` deploys stand-ins for USDC, WBTC, LINK and UNI as `FaucetToken`s, where any
account can `drip()` a small amount once a day, each with a Uniswap V3 WETH pool at a mainnet-like price so the zap has
a V3 route to swap through. Nothing in Xindex reads those pools' prices. `create` logs the `WHITELIST` entries for
`ConfigureWhitelist`: tWBTC, WETH, tLINK and tUNI, with the mainnet reference supplies. Faucet tokens have no value and
their supply grows with every drip, which is irrelevant here because nothing reads a supply live.

**No V4 pools on this market.** The V4 legs are proven on mainnet forks and against a strict mock of the Universal
Router's encoding, not on Sepolia.

| Sepolia contract | Address |
|---|---|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Uniswap QuoterV2 | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| Uniswap V3 factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap NonfungiblePositionManager | `0x1238536071E1c677A632429e3655c799b22cDA52` |
| HybridIndexFactory / IndexHub implementation / HybridHub template, module, extension / IndexZap / MintRequests (v4) | not deployed |

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
DEPLOYER=$(cast wallet address --account sepolia-deployer)

# 1. tokens and priced pools, then liquidity in a later block: 0.3 WETH in the tUSDC pool, 0.1 in each other
MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
MARKET_MODE=seed MARKET_TOKENS=<logged by create> forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 2. the factory with both templates, the zap and MintRequests; the test market has no USDT, so USDT is any second
#    6-decimal test token,
#    a FaucetToken for instance
OWNER=<Safe> GUARDIAN=<guardian> UNIVERSAL_ROUTER=0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b \
  USDC=<tUSDC logged by create> USDT=<a second test stablecoin> \
  forge script script/Deploy.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 3. print the listing proposals and sign them as one batch in the Safe app; USDC and USDT are the deployment's mint
#    currencies, which the script then never lists as components (A7-22)
USDC=<tUSDC logged by create> USDT=<a second test stablecoin> LISTING_MODE=safe FACTORY=<factory> WHITELIST=<logged by create> LIST=all forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia

# 4. 2 to 9 days later, from any account
LISTING_MODE=execute FACTORY=<factory> WHITELIST=<same> forge script script/ConfigureWhitelist.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
```

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts, so testers can call `drip()` from Etherscan.
`USD_POOL_WETH` and `TOKEN_POOL_WETH` (in wei) change the liquidity `seed` adds. Timing is mainnet's: listings and
batches take 2 days, and a rebalance can start 7 days after an index's creation, once a batch has changed a supply,
followed by 2 days of notice and a 24-hour auction. The test pools are shallow and nobody arbitrages them, so zap
prices on this market say nothing about mainnet. `test/fork/RebalanceExecutorV3.sol` fills auctions through
SwapRouter02; it is a test fixture without slippage limits, so never fund it on mainnet.

## Layout

```
src/IndexHub.sol              index implementation (ERC20 + permit, in-kind issue, redeem, redeemSkipping, claim, λ rebalance), cloned
src/IndexFactory.sol          listings, reference supplies and weekly batches, guardian, registry, CREATE2 clone deployer
src/IndexZap.sol              Universal Router mint/burn router, one venue per leg, per-leg limits, nonce check
src/MintRequests.sol          ownerless escrow of USDC/USDT-for-shares requests at the requester's own limit
src/HybridIndexFactory.sol    Stage B: IndexFactory plus the chain registry, vault-coin listings, the chain freeze and the template choice
src/HybridHub.sol             Stage B: an index of Ethereum tokens and vault coins: orders, burns, claims; delegates the rest to its module
src/hybrid/                   Stage B: the hub's module and extension (by DELEGATECALL), the storage all three share, share operations
src/vault/                    Stage B: XindexVault, the ownerless vault on an EVM chain, VaultSnapshot, its snapshot-exit library,
                              and VeChainStakerAttester, which attests VeChain's stake weights
src/verifiers/                Stage B: P1 (SP1) and P2 (RISC Zero) on an EVM vault chain, the state reader, and on
                              Ethereum the state of BNB Chain, TRON, NEAR, Stellar, Sui, Injective (CometBFT), VeChain and Aptos
src/interfaces/               every contract's interface, the shared errors (IXindexErrors), and the vendored
                              IUniversalRouter, ISP1Verifier and IRiscZeroVerifier
src/libraries/                PathLib, UniversalRouterCommands and UniswapV4Types (vendored), and Stage B's VaultMessages,
                              RlpReader, MerklePatricia, Bls12381, and for Sui Bls12381MinSig, Blake2b and SuiBcs
test/*.t.sol                  unit, fuzz, invariant, script and repository tests
test/Security.t.sol           regression tests for the security review findings (some ids are tested elsewhere; see AGENTS.md gate 6)
test/mocks/                   mock tokens, a strict Universal Router, mock verifiers, V3 pools for the testnet script, the
                              market fixture, with their own tests
test/fixtures/                real BNB Chain, Ethereum and TRON data for the Stage B verifiers, each with the generate.py that rebuilds it,
                              Sui's chain data, the test anchors of NEAR, Stellar, Sui, Injective, VeChain and Aptos for
                              DeployStateVerifier (the other chains' data is under proofs/), and
                              Solana devnet's Alpenglow certificate for EIP-2537 (proofs/solana-state's eip2537_fixture)
test/fork/                    mainnet fork tests: real V3 and V4 pools, λ rebalancing and security regressions on real tokens
script/                       Deploy, ConfigureWhitelist, DeployVault, DeployStateVerifier, ConfigureChains, MainnetAddresses, ScriptUtils
script/interfaces/            the Safe, WETH, Uniswap and Groth16-verifier calls the scripts make
script/testnet/               SetupTestMarket and FaucetToken for the Sepolia test market
abi/                          the ABIs the web app decodes with; CI regenerates them and fails on a diff
solana/                       Stage B on Solana: the vault program, P1 and P2, and a stub verifier for testnets only (solana/README.md)
near/                         NEAR's vault, with P1 and P2 compiled in, for a keyless NEP-616 account (near/README.md)
stellar/                      Stellar's vault, P1 and P2 as Soroban contracts (stellar/README.md)
sui/                          Sui's vault, with P1 and P2 as light-client objects, in one Move package (sui/README.md)
aptos/                        Aptos's vault, with P1 and P2, in one Move package (aptos/README.md)
vechain/                      VeChain's deployment script, DeployVault's twin, with the staker attester (vechain/README.md)
crates/xindex-core/           the Rust every vault chain shares (no_std): Ethereum's proofs, P1's and P2's checks, the vault's rules
proofs/                       P1's statement in plain Rust, its SP1 program, host and input builder, P2 on RISC Zero
                              in p2/, the state proofs of NEAR, Stellar, Injective, VeChain and Aptos in near/,
                              stellar/, cometbft/, vechain/ and aptos/, and Solana's researched prototype in
                              solana-state/ (proofs/README.md)
tron/                         the TRON build: the contracts under Tron's compiler, their deployment, and a rehearsal on java-tron (tron/README.md)
prototype/                    the proving prototype, with SP1's Groth16 verifier vendored unchanged in evm/src/sp1
vendor/risc0-ethereum/        RISC Zero's Groth16 verifier, vendored unchanged at v3.0.1
demo/                         the hackathon's testnet demonstration, with stub verifiers for some or all of the proofs; never for a mainnet
design/                       the v4 design (its PDF and the builder), the Stage A and B specs, the proving prototype,
                              the WBT check, the hackathon plan, the Stage C, Solana, L2 and other chains'
                              research, and the analysis scripts
audit/                        the security reviews and their PoCs, their triage, and the two retirement records
aderyn.toml                   Aderyn's configuration: the rules the design rejects, each with its reason
```

## Not in Stage A (candidates for later)

A fee in a later index version, ETH in/out (`mintWithETH` / `burnToETH`), `createAndMint` in one call,
`mintWithTokenPermit` for USDC, constituent changes (a new list is a new index version), mixed-venue legs that split one
leg across V3 and V4, a backstop executor or trigger reminder, an aggregator or Universal Router 2.1 zap, V4 pools on
the Sepolia market, and an auction whose exposure scales with the trade rather than the moving value. The native coins
of other chains are Stage B's and C's, not Stage A's: the status at the top says what is built, and "Roadmap" in
`ARCHITECTURE.md` what remains.
