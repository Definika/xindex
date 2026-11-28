# A fourth deployment, on Solana

The owner's call, what was read on chain for it, the design that carries the index to Solana, and what is built. Nothing
is deployed on a mainnet, on any chain.

## 1. The call

- **2026-11-26.** The owner asked for Solana, its large non-meme coins and "everything Ondo supports". It reverses "Not
  planned: a Solana deployment" of 2026-10-07. The answer then was a design record and a measurement first.
- **2026-11-28.** Shown that the investor material could not call Solana ready while no code existed, the owner: "მოდი
  დაამატე მაშინ სოლანა კოდში", with Ondo's tokens as Solana's list (read as "only Ondo's tokens on the Solana chain").
  This record and `solana/` are that start.

What it does not change: the three EVM deployments, their contracts and their release hashes. Solana shares nothing with
them, as they share nothing with one another: its own program, its own owner and guardian, its own list, and an index
lives on one chain.

## 2. What was read on chain, 2026-11-28

Ondo's NVDAon on Solana, `gEGtLTPNQ7jcg25zTetkbmF7teoDLcrfTnQfmn2ondo`, read through `getAccountInfo` on the public
mainnet node:

- **A Token-2022 mint**, 9 decimals, owned by `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`.
- **Extensions:** `scaledUiAmountConfig` (multiplier 1.0017152487959897, which reinvested dividends raise and a split
  multiplies: the sValue of Ondo's EVM tokens, carried by the mint itself), `pausableConfig` (not paused),
  `transferHook` with no program set, `confidentialTransferMint` (auto-approve off), `defaultAccountState`
  (initialized: a new account is not frozen), `metadataPointer` and `tokenMetadata`.
- **Authorities:** one address, `9foMHsSDq7nMg4WPusSz9eY7tyxyukqborA8GyU5cUxD`, is the mint authority and the
  authority of every extension; another, `51QVCuHfL1FeNjd8BDeffCKhCcAYoULnVB3yjNhShiuK`, freezes accounts. The first
  holds no account on chain; whether it is a key or a program's address was not read.
- **No permanent delegate.** On Solana Ondo cannot move or burn a holder's balance, which it can on Ethereum and BNB
  Chain. It can freeze any token account, the index's vault included; pause every transfer; set a transfer hook
  program, after which every transfer needs that program's accounts; change the multiplier; and mint.
- **Solana's list** is section 5's address book, read the same day: the public node refuses `getProgramAccounts`
  (HTTP 403), so the mints come from Ondo's own pages, as the EVM lists did, each then read on chain.

## 3. What a transaction can carry

A Solana transaction is at most 1,232 bytes, locks at most 64 accounts and spends at most 1.4M compute units. Moving one
leg of an index takes three accounts (the mint, the holder's token account and the index's vault), so 18 legs fit a
transaction once address lookup tables carry the keys, and 9 while the first deposits create the vaults (section 7). An index of two hundred legs cannot be created, issued or
redeemed in one transaction, as it can on the EVM chains. So every path that touches every leg is split:

- **Creation in three steps.** `begin_index` takes the hash of the terms and the leg count, `add_legs` adds the legs a
  few at a time, and `seal_index` checks the whole and opens the index.
- **Issue through a ticket.** `open_issue` records what each leg needs for the shares asked, `deposit` moves one leg into
  the index's vault (several per transaction), and `finalize_issue` mints the shares once every leg is in. Until then
  `withdraw_deposit` returns a leg and `cancel_issue` closes an empty ticket.
- **Redeem through a ticket.** `redeem` burns the shares and books what each leg owes the holder, in one instruction
  that touches no leg at all, and `claim` pays a leg out, whole or in part. Every redeem is a `redeemSkipping`: a frozen
  or paused leg waits in the ticket, and never stands between a holder and the other legs.

## 4. The design, mapped from the EVM contracts

- **The index's address commits to its terms** (LR-05). The index account is the program address derived from
  `["index", creator, terms_hash]`, `terms_hash` the SHA-256 of the leg count and every leg's mint, units and weight;
  `seal_index` recomputes it from the legs added and refuses another. Its share mint is derived from `["shares", index]`.
- **Shares are an SPL token**, 9 decimals, minted and burned only by the index's address, with no freeze authority. A
  leg's units are its raw units per whole share (`SHARE_UNIT`, 1e9 raw shares).
- **Amounts come from supply and units alone.** An issue needs `⌈shares · units / SHARE_UNIT⌉` of each leg and a redeem
  owes `⌊shares · units / SHARE_UNIT⌋`; balances only verify.
- **The invariant, per leg:** the vault holds at least `⌊supply · units / SHARE_UNIT⌋ + owed + pending`, `owed` the legs
  open redeem tickets wait to claim and `pending` the deposits open issue tickets hold. A deposit refuses a vault below
  that line before it moves anything (`Underbacked`, RX-8's rule), and credits exactly what the vault received: a
  transfer that delivers less reverts (`ShortDeposit`). What the vault holds beyond the line stays with the holders.
- **Listings.** The owner proposes a mint, which records its decimals; anyone executes it from `LISTING_DELAY` (2 days)
  for `PROPOSAL_WINDOW` (7 days); the owner or the guardian cancels a proposal or delists. A listing reaches only
  indexes created after it. The listing refuses a mint whose accounting an index in kind cannot hold: a transfer fee, a
  permanent delegate (the power to move or burn any balance, which the WBT rule exists to refuse), a non-transferable
  mint, accounts frozen by default, a transfer hook with a program set, and more than 9 decimals. Ondo's mints pass.
- **Creators.** Only wallets the owner approves begin and seal an index (`CreatorNotApproved`), the gate of the EVM
  factories and for the same reason: no contract can tell units from weights without a price.
- **Roles.** The owner hands its role on in two steps; a guardian change waits `GUARDIAN_DELAY` (7 days), executable by
  anyone within the window, cancellable by the owner, and by the guardian only when it would remove the role. The
  configuration is initialized once, by the program's upgrade authority, so nobody can claim it between the deployment
  and its first instruction.
- **No upgrade.** A Solana program is upgradeable by default. The mainnet deployment drops its upgrade authority once
  the build is audited (`solana program set-upgrade-authority --final`), the equivalent of the EVM contracts having no
  upgrade; until then the authority is the owner's Safe, Squads on Solana.
- **Holders can always leave.** `redeem` reads no price, touches no leg and has no pause; a claim on a frozen leg is paid
  once the leg moves again.

## 5. The address book

`solana/listing/ondo.json`, written by `solana/listing/read_ondo.py` on 2026-11-28 (slot 474,725,877), with the mint
accounts it read in `solana/listing/ondo-mints.json`:

- **The list is Ethereum's.** Every Ondo token the Ethereum deployment lists, each one Pyth has a feed for: 353. Ondo's
  asset list (`app.ondo.finance/api/v2/assets`) names 482 assets; its page of each listed one names the token's address
  on Ethereum, BNB Chain and Solana. Every one of the 353 has a Solana mint, and the page's Ethereum address is the one
  `keeper/bot/price-ids.mjs` holds for it, for all 353.
- **Each mint was read on chain** and is a Token-2022 mint of 9 decimals, as Ondo's page gives them, whose token
  metadata names the symbol, with a scaled-UI multiplier, no permanent delegate, no transfer hook program and no pause
  set. All 353 have one mint authority, `9foMHsSDq7nMg4WPusSz9eY7tyxyukqborA8GyU5cUxD`; two keys freeze accounts,
  `51QVCuHfL1FeNjd8BDeffCKhCcAYoULnVB3yjNhShiuK` for 307 of them and `Chm9dcASBc9C54FGxcSRGv9qC998TueQqr5XzGZkEVCc`
  for 46.
- **Each entry's Pyth feed is Ethereum's**: the token's own feed for the nine Pyth prices as tokens (NVDAon, AAPLon,
  GOOGLon, MSFTon, TSLAon, HOODon, MSTRon, COINon, CRCLon, `"feedKind": "token"`), the share's feed for the other 344
  (`"share"`), to be multiplied by the mint's multiplier. 21 multipliers stand more than 5% from one, the splits and
  dividends the EVM sValue readings found (NFLXon, KLACon and PPLTon 10, SNDKon 8, NOWon, CVNAon and PALLon 5, CRWDon
  and IWFon 4, ETHAon a third, SOXSon a tenth among them): priced at the share alone, those legs would be off by that
  factor.
- **The tests list every one.** `programs/xindex/tests/ondo_book.rs` writes each of the 353 mint accounts into the
  test chain as it was read, proposes and executes its listing through the program's check, and creates an index of
  the first two hundred.

## 6. Ondo's tokens in an index

- **Their balances never move for a corporate action.** A Token-2022 scaled-UI multiplier changes only what wallets
  display: raw balances, which every amount here is counted in, stay put. So an index holds an Ondo token as it holds
  any fixed-balance token, and the multiplier matters only to valuing it.
- **The value of one raw unit is Pyth's share price times the multiplier** the mint itself carries, read from the mint
  at the fill, with no oracle of Ondo's beside it. A multiplier scheduled to change (`newMultiplierEffectiveTimestamp`)
  is the Solana form of the EVM rule that only a settled sValue values a leg.
- **Ondo's powers are named to every holder**: freeze the index's vault, pause transfers, set a transfer hook. Each can
  hold one leg in the vault; none can take it, since no permanent delegate exists.

## 7. Built

`solana/`, an Anchor workspace (Anchor 1.2, `solana/rust-toolchain.toml` pinning the host's Rust), program `xindex`:

- **The configuration and its roles** (`instructions/config.rs`): initialized once, by the upgrade authority only;
  the owner's two-step handover; the guardian's change behind `GUARDIAN_DELAY`.
- **Listings, price feeds and approvals** (`instructions/listing.rs`): the extension check of section 4, run at the
  proposal and again at the execution, since a mint's authority can set a transfer hook in between; each listing's
  Pyth feed behind `LISTING_DELAY` (section 8.2).
- **Creation** (`instructions/create.rs`): two to two hundred legs, in four steps, the creator paying the index
  account's growth, the terms its address commits to including the fee rates and the interval, and the seal's check
  on weights at Pyth's prices.
- **Issue and redeem** (`instructions/issue.rs`, `instructions/redeem.rs`): through tickets, the invariant checked at
  every deposit, fees in shares and the streaming fee's scale (`instructions/fees.rs`, section 8.1), the gate and the
  mint pause read by an issue alone.
- **The rebalance** (`instructions/rebalance.rs`, `instructions/fill.rs`, `instructions/weights.rs`; section 8.3): the
  clock, the keep mask, the cancel and the quote; a fill through its ticket; changeable weights.
- **Limit orders** (`instructions/requests.rs`, section 8.5): a request per account, its escrow its own.
- **The arithmetic** (`math.rs`, `settlement.rs`, `pyth.rs`): the EVM's settlement, replayed against every vector of
  `test/vectors/settlement.json` (455 settlements, 77 quotes, 85 of Pyth's checks, `tests/vectors.rs`) at the EVM's
  share unit and largest units; the backing in 128-bit words, held to the 256-bit arithmetic on four thousand points;
  Pyth's price and the mint's multiplier, read exactly.
- **The index account is a zero-copy header with its legs read in place** (`state.rs`). A Borsh copy of two hundred
  legs ran out of a program's 32 KB heap when the index was sealed, since Borsh grows a vector by doubling and the heap
  never frees. An error value built eagerly in a loop (`ok_or(error!(..))`, an allocation every iteration) ran a redeem
  of two hundred legs out of it too; every error is built lazily now. A fill ticket of two hundred legs is 9,776 bytes,
  under the 10,240 an account created by a program may start with.

Measured on LiteSVM with mainnet's features, at two hundred legs:

| Step | Per transaction | Compute units |
|---|---|---:|
| Deposits that create their vaults | 9 (an account's creation takes 6 of the 64 instruction-trace entries) | 701,403 |
| Deposits into vaults that exist | 18 (63 accounts of 64) | 850,326 |
| A redeem of every leg | 1 | 64,998 |
| Naming fifty legs' units in a fill, or pricing ten | 50 or 10 | 808,843 at most |
| The commit of a fill of every leg | 1 | 254,608 |

A first commit that summed the scores and values of two hundred legs itself ran past 1.4M compute units, which is why
naming the units and pricing the legs keep the sums.

Tests: 67 in all. 13 unit tests of the arithmetic and the price reader; the vectors' replay (3); 51 LiteSVM tests
(`programs/xindex/tests/`): the configuration, listings, creation, issue and redeem (`index.rs`, 21), fees, the
creator role, the gate, the pause, the price feeds and the creation's check on weights (`fees.rs`, 9), the rebalance
(`rebalance.rs`, 15), limit orders (`requests.rs`, 4) and the address book (`ondo_book.rs`, 2), on Token-2022 mints built with Ondo's extensions, plain Token-2022 and classic SPL mints, Pyth price
accounts written as the receiver writes them, and the address book's 353 mint accounts as read, listed with their
real feeds and made into a two-hundred-leg index on its weights. Every revert is required to be its exact error. The
mutation gate's Solana table, `solana/mutants.json` (57 mutants, run by `test/mutants/run.py --table`), edits each rule
once: the bar, the caps, the sums, each price check, each clock rule, each rounding, the fees, the gate, the pause, the
creator's handover, the weights' notice, the listing check and each limit-order rule. One mutant survived its first
run, a ticket committing under a proposal it was not opened for: no test had started a second proposal under an old
ticket, and one does now.

Not checked: a transaction's size in bytes, which at eighteen legs needs an address lookup table; a fork of Solana's
mainnet, beyond Ondo's mint accounts as read and one Pyth price account's layout; and CI, which does not build
`solana/` yet. `ShortDeposit` is reached only by a test that writes a listing directly: no listable mint delivers less
than it sends.

## 8. Fees, the pause, the rebalance and Pyth's check, on Solana

Each EVM rule as the program carries it; where Solana forces a different shape, the reason is given.

### 8.1 Terms, fees and roles

- **The terms an index's address commits to** grow by its config, as the EVM salt does (LR-05): the creator's fee and
  streaming rates, the platform's two rates and the referral share the policy gave at creation, and the rebalance
  interval, `MIN_REBALANCE_INTERVAL` to `MAX_REBALANCE_INTERVAL` (7 to 91 days). `begin_index` takes them and refuses
  platform rates other than the policy's (`PolicyChanged`): a creator names the rates it signs for exactly, where the
  EVM factory takes a ceiling. The gate is chosen at `begin_index` and is not a term.
- **Fees are shares, never legs.** An issue of `shares` needs the backing of `⌈shares · 10,000 / (10,000 − fee)⌉` gross
  shares; `finalize_issue` mints `shares` to the recipient and the rest to the creator role, the platform's recipient and
  a referrer, as `_mintFeeShares` does. A redeem burns `shares`, mints `⌊shares · fee / 10,000⌋` to the recipients and
  books the backing of the rest. The recipients are share accounts at the addresses the ATA program gives the creator
  role and the platform's recipient (`config.platform_recipient`), read at each call; a client creates a missing one
  with the ATA program's idempotent create, which anyone may, so no recipient blocks a mint or an exit. A platform
  recipient left at the default key folds the platform's part into the creator's.
- **The streaming fee is a unit scale** (`index.scale`, 1e18 = one, a `u64` since it only shrinks): every
  `finalize_issue`, `redeem`, `commit_fill`, `accept_creator` and `accrue_fees` first mints `supply · f / (1 − f)` shares,
  `f` the rate times the elapsed part of a year, and lowers the scale by `supply / (supply + minted)`, both rounded
  down; every accrual restarts the clock (XS-1). Every amount is `shares · units · scale / (SHARE_UNIT · 1e18)`, in
  256-bit arithmetic. `open_issue` sizes the ticket at the scale an accrual then would leave, which is at least the one
  `finalize_issue` meets, so the deposit over-backs by the fee's few seconds, and that stays with the holders.
- **The creator role** is the index's `creator_role`, offered on (`transfer_creator`) and accepted (`accept_creator`),
  which accrues the streaming fee to the outgoing holder first (RW-6) and cancels a pending change of weights (HK-16).
  The `creator` in the index's address never changes.
- **A gated index** issues only to its creator role and to wallets it allows (`allow_minter`, an account per wallet);
  `open_minting` opens it for good. A referrer the gate would refuse is named nobody (AU-1).
- **The mint pause.** The owner or the guardian pauses issue on one index (`pause_minting`) or on all
  (`config.mint_paused_all`); only the owner resumes. `open_issue`, `deposit` and `finalize_issue` read it; a withdrawal,
  a cancel, a redeem, a claim and every step of a rebalance never do.

### 8.2 Prices: Pyth's receiver and the mint's own multiplier

- **A listing carries its feed** (`propose_price_feed`, behind `LISTING_DELAY`, cancellable by the owner or the
  guardian): Pyth's feed id and its kind, `Token` (the feed prices a whole token) or `Multiplier` (it prices a whole
  share, and the mint's scaled-UI multiplier says how many shares a whole token is, Ondo's sValue on Solana).
- **A price is a `PriceUpdateV2` account of Pyth's receiver** (`rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ`), read
  in place (its layout read from a live account, SOL/USD's, 134 bytes): owned by the receiver, fully
  verified, the listing's feed id, a positive price above its confidence. Anyone posts one, so the executor picks
  which signed price a fill reads, as on the EVM chains (HK-25).
- **A value** is one raw unit's worth times 1e36, the EVM reader's: `(price ± conf) · 10^(36 + expo)`, times the
  multiplier for a `Multiplier` feed, over `10^decimals`, leaning against the executor, nothing and anything past
  `u128` refused (`UnusablePrice`). The multiplier is an `f64` on the mint; its mantissa and exponent are read
  exactly, so its rounding goes against the executor too. **Only a settled multiplier counts**: the extension's
  `new_multiplier_effective_timestamp` is the moment of the last change or the one scheduled, so a leg is refused
  (`MultiplierUnsettled`) from the moment a change is scheduled until `MIN_SVALUE_AGE`, twenty minutes, after it took
  effect, the EVM rule for Ondo's sValue.
- **A creation is checked on its weights** (`MAX_WEIGHT_DEVIATION`, 5%, relative): `price_legs` records each leg's
  value, as arriving, in a price sheet (an account of the creator's), a few legs a transaction, and `seal_index`
  requires every price no older than `MAX_CREATION_PRICE_AGE` (60 seconds) at the seal and every leg's share of value
  within 5% of its weight (`OffWeights`).

### 8.3 The rebalance

- **Starting, cancelling and the clock** are the hub's, rule for rule: anyone starts once the interval has passed;
  `REBALANCE_DELAY`'s notice, then `AUCTION_DURATION`'s auction; a keep mask (256 bits) and a start before strangers may
  are the owner's or the guardian's; a fill under a mask restarts only `MIN_REBALANCE_INTERVAL` (XS-3); the owner or the
  guardian may start `MIN_REBALANCE_INTERVAL` after any fill, never before the first (RW-3); a cancel, by the proposal's
  id or whichever is pending (CA-S02), holds strangers off for `REBALANCE_DELAY`; an index under one whole share does
  not rebalance (RW-1).
- **A fill spans transactions, so it is a ticket, and the executor pays first.** Two hundred legs fit no one
  transaction, and a fill that paid the executor before it delivered could stop halfway with the index short. So:
  `open_fill` binds a ticket to the pending proposal and the index's nonce; `set_fill_units` names new units, a range
  at a time; `price_fill` records Pyth's value of each moving leg; `deposit_fill` moves what a growing leg will need
  into its vault, counted as `pending` there, exactly as an issue's deposit, `Underbacked` and `ShortDeposit` included;
  `commit_fill`, one instruction that touches no leg, settles: it accrues the streaming fee, compares the gain with
  the bar, computes each leg's amount at the supply then, requires every growing leg's deposit to cover it
  (`RebalanceMovedOn`), checks the quote and Pyth's prices, and writes the new units, moving what each shrinking leg
  gives out into `owed`, as a redeem books it.
- **The sums are kept as the fill is built.** Two hundred legs' scores and values fit no one instruction, so
  `set_fill_units` refuses a leg outside its caps as it is named (`LegOutOfBounds`, `UnitsOverflow`) and moves the
  ticket's weighted score `Σ w · L(x)` by that leg's change, and `price_fill` adds the leg's value at its price to the
  value in or out, taking out any it had; a leg whose units change loses its price. The leg's units, its weight and
  the keep mask cannot change under a live ticket (the nonce binds the first, a live proposal the other two), so the
  sums are exactly what the commit would have summed: the EVM arithmetic (`settlement.rs`, the vectors' replay)
  term by term. `claim_fill` then pays the executor what it bought and what it deposited
  beyond the need. Until the commit, `withdraw_fill` returns any deposit, and a ticket whose proposal is gone commits
  nothing.
- **The invariant holds at every step without reading a balance at the commit.** Before it, deposits are `pending`;
  at it, what a growing leg needed leaves `pending` for the backing, and what a shrinking leg gives leaves the backing
  for `owed`; so `vault ≥ ⌊supply · units · scale⌋ + owed + pending` holds with the new units. Every balance was
  measured where it landed, and a listed mint has no permanent delegate, so no balance moves but by the program.
  The EVM probe that a bought leg can leave (RX-12) has no Solana form to probe: a freeze, a pause or a hook stops a
  transfer in as well as out, so a leg that cannot leave cannot be deposited.
- **Pyth's check** at the commit: every moving leg priced no more than `MAX_PRICE_AGE`, fifteen seconds, before it,
  and the value in at least the value out less a tolerance from nothing to `MAX_ORACLE_TOLERANCE`, 2%, over the
  auction (`BelowOracleValue`). A price can only refuse: the units' check comes first and stands whatever the prices
  say.
- **The quote** of a start (`write_quote` in ranges, then `start_rebalance` with a tolerance binds it to the new
  proposal): checked at the commit of that proposal alone (`BelowQuote`), never written again while it binds one.
- **Changeable weights**: the creator role proposes (`propose_weights`), anyone applies them `WEIGHTS_DELAY`, 7 days,
  later within `PROPOSAL_WINDOW`, never during a live rebalance (`RebalancePending`); the creator role, the owner or
  the guardian cancels.

### 8.4 Buying and selling

- **A buy is the buyer's own transaction, and needs no program of ours.** The EVM zap exists because an account there
  makes one call at a time; a Solana transaction carries many instructions, so the app composes Jupiter's swap of USDC
  or USDT into each leg with that leg's `deposit`, a few legs a transaction, and the ticket is the escrow between them,
  as the EVM basket builder's is. Jupiter's minimum out and the deposit's exact amount are the limits. A sale is a
  `claim` followed by Jupiter's swap the same way.
- **Limit orders** are the EVM's `MintRequests` (section 8.5).

### 8.5 Limit orders

- **A request escrows in an account of its own.** `request_mint` escrows USDC or USDT for at least `min_shares` of an
  index, `request_redeem` shares for at least `min_out` of a stablecoin, each until a deadline at most
  `MAX_REQUEST_DURATION`, 30 days, away. The two stablecoins are the configuration's, set once at its initialization;
  any other is refused (`NotAStable`). Each request is an account at `["request", requester, id]`, `id` the
  requester's own number, and its escrow is a token account that account owns, credited with what it received.
  So no request's escrow is another's: the EVM contract's `totalEscrow` and `Underbacked` (CA-H2), which stop a
  newcomer's escrow from paying for an issuer's burn of a shared balance, have nothing to guard here, since no balance
  is shared, and a burn of one escrow is that request's alone.
- **A fill pays first, then takes the escrow.** `fill_request` requires what the filler sends to land in the
  requester's own account, measured there, at or above the limit, and only then pays the filler the whole escrow and
  closes the request; nothing reads a price, the limit is the requester's. A request fills only at the basket it was
  made on: it records the index's rebalance nonce, and a fill refuses another (`StaleRebalanceNonce`, RW-2); a
  requester may name the nonce it priced at (CA-M1), and a filler the request's hash it priced (`RequestChanged`,
  RW-7).
- **A requester's escrow always comes back.** `cancel_request` by the requester at any time, `refund_request` by
  anyone after the deadline, neither reading a nonce.

## 9. Not built

1. The listing transactions for the owner's Squads Safe from the address book, and the deployment with the upgrade
   authority's handover.
2. CI for `solana/`: the job needs Solana's Linux release and Anchor pinned by checksum, as Foundry is.
3. The keeper on Solana (it posts Pyth's updates, names the units, opens and commits fills), and the app's Jupiter
   composition.
4. A run on a fork of Solana's mainnet, an external audit of the program, and the authority dropped.
