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
- **Listings and approvals** (`instructions/listing.rs`): the extension check of section 4, run at the proposal and
  again at the execution, since a mint's authority can set a transfer hook in between.
- **Creation** (`instructions/create.rs`): two to two hundred legs, in three steps, the creator paying the index
  account's growth.
- **Issue and redeem** (`instructions/issue.rs`, `instructions/redeem.rs`): through tickets, the invariant checked at
  every deposit.
- **The index account is a zero-copy header with its legs read in place** (`state.rs`). A Borsh copy of two hundred
  legs ran out of a program's 32 KB heap when the index was sealed, since Borsh grows a vector by doubling and the heap
  never frees. An error value built eagerly in a loop (`ok_or(error!(..))`, an allocation every iteration) ran a redeem
  of two hundred legs out of it too; every error is built lazily now.

Measured on LiteSVM with mainnet's features, at two hundred legs:

| Step | Per transaction | Compute units |
|---|---|---:|
| Deposits that create their vaults | 9 (an account's creation takes 6 of the 64 instruction-trace entries) | 701,403 |
| Deposits into vaults that exist | 18 (63 accounts of 64) | 850,326 |
| A redeem of every leg | 1 | 64,998 |

Tests: 4 unit tests of the arithmetic, 21 LiteSVM tests (`programs/xindex/tests/`) on Token-2022 mints built with
Ondo's extensions (scaled UI, pausable, an empty hook slot, accounts initialized by default, a metadata pointer), a
plain Token-2022 mint and a classic SPL mint, and the 2 tests of the address book on Ondo's own mint accounts (section
5). Every revert is required to be its exact error. Seven mutants of the
program were run against their tests and each was killed: the deposit's backing check, its delivery check, the issue's
rounding up, the seal's terms check, the seal's approval, the listing's hook check and the redeem's booking of what is
owed. An eighth, the listing check refusing a scaled-UI multiplier, is killed by the address book's test.

Not checked: a transaction's size in bytes, which at eighteen legs needs an address lookup table; a fork of Solana's
mainnet, beyond Ondo's mint accounts as read; and CI, which does not build `solana/` yet. `ShortDeposit` and `StaleRebalanceNonce`
are reached only by tests that write an account directly: no listable mint delivers less than it sends, and nothing
moves the nonce until the rebalance is built.

## 8. Not built

In the order they would come:

1. The listing transactions for the owner's Safe from the address book, and the deployment with the upgrade
   authority's handover.
2. Fees in shares, the creator role's handover, the streaming fee's unit scale, gated indexes, and the mint pause the
   EVM indexes have (the owner or the guardian stops new issues; no exit is ever paused).
3. The rebalance: the auction, the settlement arithmetic ported from `WeightedMath` and replayed against
   `test/vectors/settlement.json`, the bar, the caps, and Pyth's check through its Solana receiver with the
   multiplier; the creation check on weights; changeable weights.
4. A buy and a sale in USDC or USDT through Jupiter, the venue that holds Solana's depth, and limit orders as
   `MintRequests`.
5. CI for `solana/`, the keeper on Solana, the app, an audit of the program, and the authority dropped.
