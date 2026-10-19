# Before mainnet: the readings of 2026-10-18

**Status:** research record, 2026-10-18, for the owner. It takes up the steps before mainnet that `AGENTS.md` lists,
short of the external audit: OP-PIP-132 (section 1), Ondo's corporate actions (CF-3, section 2), the Wormhole copies
still to attest (section 3), the fork suites' re-run (section 4), the owner's calls of section 9 of the engine record
(section 5) and the source reading of the tokens listed on 2026-10-10 (CF-4, section 6). Section 7 lists what stays
open. Nothing here changes a contract.

**Marks:** **[v]** read on chain here (a call, a storage read or the bytecode), at Ethereum block 26,215,076 unless
another is named; **[s]** read in verified source code; **[w]** a website or a published document says it, not
verified here.

## 1. OP-PIP-132: what it means for Pyth on Ethereum

**What it did** [w] (the Pyth DAO forum, "[PASSED] OP-PIP-132: Pyth Core Deprecation (EVM)", posted 2026-08-25):
Pythnet is being sunset and Pyth Core's updates move to the Pyth Pro publishing stack. On 2026-08-26 at 16:00 UTC the
proposal repointed Pyth Core on 33 EVM deployments (19 mainnets, 14 testnets), three governance actions each: upgrade
the contract, replace the three legacy data sources with one (emitter chain 26), and point the contract at a new
receiver holding a five-guardian set. It carries no fee action: earlier proposals (OP-PIP-128 and 130) had already set
EVM update fees to zero. Pyth's blog of 2026-05-26 adds that Hermes needs an API key after 2026-07-31, at
`https://pyth.dourolabs.app/hermes`, under a data plan: "Starter", $500 a month, for crypto, NAV, redemption-rate and
crypto-index feeds at one-second updates; "Pro" bundles, $2,500 to $10,000 a month, for the other asset classes. It
calls the API "100% backward-compatible" and names no end-of-life for Pyth Core.

**What Ethereum's contract is today** [v]:
- Pyth, `0x4305FB66699C3B2702D4d05CF36551390A4c69C6`: version 1.4.6, implementation
  `0x3F38404A2e3Cb949bcDfA19a5C3bDf3fE375fEb0`, update fee 0, one valid data source, chain 26 with the emitter
  `PythnetPythnet…`, and the governance data source chain 1 (Solana), emitter `0x5635979a…2e9e`.
- Its receiver, `0x3a2DD09B4739D905183D503d594c8FB3e3D41820`, is a proxy over
  `0x8d289cdd60e7f73f352f42c8524a06ef1ad746f8`, verified as `ReceiverImplementationHalf` [s], whose quorum is
  `numGuardians / 2 + 1`: **three of the five keys** verify a message. Its current set, index 1, has the five keys
  `0x41534bB1…E638`, `0x6502987B…5B41`, `0x44A3e8F6…76C9`, `0x13Edc776…39d4` and `0x3af08885…9aF9`. Corrected on
  2026-10-19 (the red team's RX-63): set 0 held five other keys on chain until 2026-09-05, and each rotation leaves the
  old set 24 hours of power. The forum names index 0 and "a 3-of-5 quorum", which the source confirms.
- Hermes and Benchmarks, Pyth's history service, answer 401 to every request without a key, the at-time and
  historical routes included [v, on 2026-10-18]; only Benchmarks' feed catalogue answers.

**What it means for Xindex:**
1. **Who can move a price.** Every price a settlement reads is accepted on three of five keys of a set Pyth runs, not
   on 13 of Wormhole's 19 guardians. The same three keys can sign a governance message as if Pyth's council had sent
   it, since the contract checks the council's emitter inside a message those keys sign; so they can also upgrade
   Pyth's Ethereum contract, `parsePriceFeedUpdatesUnique` with it. The hub's bound is unchanged and is what holds:
   a fill sends out at most `MAX_TURNOVER` of each component's own units, so a forged price takes at most that, once
   per fill (V5-M2). The engine record's hardening "a second signature set" (section 9, item 8) answers exactly this
   concentration; it is priced with the replay.
2. **Who can fill.** An executor needs a signed update from Hermes, so a fill is open to anyone with a Pyth data
   plan, not to anyone. The owner's call of 2026-10-18 that Xindex runs the first filler (section 5) means Xindex
   holds a plan: Starter covers an index of crypto feeds, Tether Gold's and the five Ondo tokens' own feeds among
   them (all `Crypto.*`); an index holding one of the twelve Ondo legs priced at an `Equity.*` share feed needs a Pro
   bundle. The operating cost is $500 a month, or $2,500 and up with those stocks [w for the prices].
3. **The interface.** Pyth calls the upgrade backward-compatible [w]; the anvil run of 2026-10-12 verified the 1.4.6
   implementation's parse against an update signed by keys the test installed [v]. A settlement on a real Hermes
   update is still owed; it needs the key (section 7).
4. **One thing to ask Pyth.** Pyth's EVM contract-address page lists no Ethereum mainnet entry [w], while the
   contract on chain was repointed as the proposal describes [v]. Before mainnet, the owner confirms with Pyth that
   Ethereum is one of the proposal's nineteen mainnets and stays served.

## 2. Ondo's corporate actions (CF-3)

**How Ondo applies them** [w] (Chainlink's documentation of its Ondo tokenized-equity feeds; Ondo's own pages say
the effect without the mechanics): an Ondo stock token's balance never changes for a corporate action. Each token
tracks `sValue` shares of the stock, a multiplier Ondo's `SyntheticSharesOracle` publishes, and the token's price is
the share's price times `sValue`. Net dividends are reinvested by raising `sValue` (applied automatically when the
change is under 1% in a day); a 10-for-1 split takes it from 1 to 10, a reverse split down by the same factor. A
change over 1% is scheduled at least 24 hours ahead, pauses the oracle for at least ten minutes, and is confirmed by
Ondo by hand; minting and redemption may pause around it. Acquisitions follow the issuer's documents, typically a
redemption.

**What the contracts show:**
- The tokens are `GMToken` behind a beacon proxy (JPMon: proxy `0x03C1EC4C…ffaF`, implementation
  `0xebBcb2cE…2250`) [v]; the implementation has no multiplier, rebase or oracle function [s]. The multiplier lives
  outside the token.
- A `SyntheticSharesOracle` is deployed at `0x9BC39DB6fbB44B91a48b8D5A6C208B82B1741bE6` (verified source,
  `getSValue(address) → (sValue, paused)`) [v][s]. Of the 17 listed stocks only TSLAon is registered there, at
  exactly 1.0 and not paused [v at block 26,215,097]; the other 16 revert `AssetNotFound`. Their `sValue` is not on
  chain at that address, so their drift could not be measured here.

**What it does to an index:**
1. The first two harms CF-3 names, tokens minted to holders that belong to no share and burns that leave a leg below
   its backing, do not come from Ondo's corporate actions, since balances never change. They remain possible only
   through Ondo's own mint and burn powers over a holder, which the owner accepted on 2026-10-10.
2. The third does. Five legs are priced at the Ondo token's own Pyth feed ("… ONDO TOKENIZED STOCK / US DOLLAR"):
   NVDAon, AAPLon, GOOGLon, MSFTon and TSLAon. Twelve are priced at the share's feed: AMZNon, TSMon, SPCXon, METAon,
   AVGOon, SKHYon, MUon, LLYon, AMDon, JPMon, WMTon and Von. For those twelve the hub values each token at
   `1 / sValue` of its worth. Benchmarks' catalogue has no token feed for any of the twelve on 2026-10-18 [v].
3. What a mispriced leg costs, at the hub's own prices, which is where it trades:
   - Dividend drift is small, about each stock's yield for each year since Ondo issued the token, zero for the
     non-payers. If the hub sells a leg it undervalues, the executor buys it at that discount, on at most
     `MAX_TURNOVER` of the leg's units per fill: under a few percent of a fifth of the leg. If it buys one, a rational
     executor pays the discount, so fills slow rather than lose; Xindex's own keeper is not that executor unless it
     refuses to value the legs, which it now does (the red team's RX-2: it delivers none from stock and counts any it
     keeps as nothing, and its stock allowance for the twelve stays at zero).
   - A split makes the leg look ten times cheaper and far underweight, so the hub asks an executor to deliver ten
     times its value: no fill clears, and rebalancing that index stalls until the guardian keeps the leg. A reverse
     split makes it look dearer and overweight, so the hub sells it for ten times its worth: again no fill. Neither
     moves value out of the index, unless the creator weighted the leg far below its holdings, so that after a split
     it is still overweight and the hub sells it at a tenth of its worth (RX-7).
   - Ondo can also end a token: its base prospectus of 11 November 2025 (T&C XIV, "Issuer Redemption") lets it
     terminate a token on at least 30 business days' notice and pay only KYC'd redeemers, and an acquisition is
     typically a redemption. The hub moves only component tokens and has no sweep, so a payout sent to an index is
     stranded: holders still in at the date lose that leg (RX-29).
4. Nothing here adds a path that pays out balances (`AGENTS.md`'s rule).

**Procedure, until Pyth publishes a token feed for each of the twelve:**
- Price an Ondo leg at the token's own feed wherever Pyth has one; when a token feed appears, the owner relists the
  token with it, which reaches only later indexes.
- The keeper and the app watch Ondo's notices (`status.ondo.finance`, at least 24 hours ahead of a change over 1%)
  and the oracle above; the guardian keeps an affected share-priced leg in any rebalance started around the action,
  and cancels each auction of an index that cannot keep it, a two-leg index (RX-7).
- The keeper's stock allowance for the twelve stays at zero (RX-2).
- On a termination notice, the app tells holders of an index with that leg to exit before its date (RX-29).
- The app labels the twelve as priced at their share, and flags an index whose starting units and weights disagree.
- **The owner's call, 2026-10-18:** keep the twelve listed under this procedure, as recommended. The worst case is a
  stalled rebalance, not a loss, and the drift is bounded by the cap; a termination is a loss for those still in, which
  the procedure's notice exists to avoid (corrected 2026-10-19, RX-29).

## 3. The Wormhole copies still to attest

The record of 2026-10-10 counted 34 copies that did not exist on Ethereum. Asked again on 2026-10-18 through the
bridge's `wrappedAsset(chain, source)` [v, at block 26,215,050], with JUP's listed copy as a control:
- **Three already exist:** BNB as BNB Chain's WBNB (`0x418D75f65a02b3D53B2418FB8E1fe493759c7605`), SUI
  (`0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6`) and SEI (`0xf91e605af079384cc7077B3914A4a36019a89EE8`), each owned by
  the bridge with its home chain's id, 18, 9 and 6 decimals. Each passed `CheckToken` at block 26,215,111 (exact
  transfers, no hooks, the bridge's mint and burn), and they are listed from today, `Bridged`, at Pyth's BNB, SUI and
  SEI feeds; `test/fork/MainnetAddresses.fork.t.sol` checks their sources in the bridge's registry. WBNB wraps BNB
  itself, not a Binance-Peg token. Sui names a coin by its CoinMetadata object, which is how SUI's turned up; Sei's
  bridge names a native denom by its keccak256 with the first byte set to 1, as Terra 2's LUNA copy confirms; NEAR's
  names an account by its sha256, as the SWEAT copy confirms.
- **31 still need an attestation**, the owner's transactions on their home chains, as the record of 2026-10-10
  describes: TRX, ZEC, BCH, FIL, XTZ, ASTER, STABLE and TWT from BNB Chain; WAL from Sui; NEAR; KAIA; MON; S; RAIN;
  VVV and ZEN from Base; and GRASS, BP, JTO, CARDS, MET, USX, KMNO, 2Z, ORCA, META, CASH, SKR, DBR, STONK and HNT from
  Solana. RAY's copy still answers an empty symbol and waits for `updateWrapped` from Solana.

With SAND and RLB off it (section 6), the list is 93: 16 Wormhole copies, and 75 coins that count toward the
hundred. On 2026-10-19 BTT and SEI's copy left it (the red team's RX-28 and RX-32: BTTC's bridge closed in June 2026,
and SEI's copy redeems only through Sei's CosmWasm side, which Sei is shutting down), so it is 91, 15 copies and 73
that count. The queue of 31 lost USX and CASH (stablecoins), BP (an exchange's token) and S (Wormhole does not serve
Sonic), and FIL is held until its Binance-Peg source passes a reading on BNB Chain: 26 copies to attest (RX-11, RX-20,
RX-35, RX-64).

## 4. The fork suites, run again

CF-4 re-pinned SAND as review and asked for the five fork suites to run again. They ran on 2026-10-17 at `2919b2f`
(40/0/0 at block 26,033,838, Tenderly's archive), and in CI on pull request 17 and on `main` at `878199c`: 496 tests,
0 failed, 0 skipped, all five suites among them. With the three copies above, `MainnetAddresses.fork.t.sol` (9/0) and
`CheckToken.fork.t.sol` (5/0, at block 26,215,123) passed again on 2026-10-18, forked near the head of a public RPC;
with SAND and RLB off the list, again at blocks 26,215,645 (9/0) and 26,215,649 (6/0, SAND's CF-4 pin now a test of
its own). CI runs all five on the change.

## 5. The owner's calls of 2026-10-18

On the engine record's section 9:
- Taken as proposed: the cadence menu {7, 14, 30, 91} days (item 4); private indexes as unlisted plus mint-gated,
  both opt-in at creation (item 5); Xindex runs the first filler, the keeper's request filler (item 6); the basket
  builder ships at launch (item 7); the hardenings are decided by the replay (item 8); the coin pages show the listed
  set and tiers only (item 9); no Base deployment for now (item 10); and a creation fee of zero.
- Not yet decided: the platform's fee per side and the referrer's share of it (items 1 and 2), the platform's
  streaming rate (item 3), and the legal reading of a fee-earning basket that may hold tokenized stocks (item 11),
  which is counsel's. Until then the deployed policy stays at zero, as built.

On this record's own questions:
- The source reading (section 6): SAND and RLB come off the list; H, PLUME, SNX, SYRUP, GALA and MANA stay, MANA,
  CHZ, SENT and FLUID labelled Pausable.
- The twelve Ondo legs priced at their share's feed stay, under the procedure of section 2.

## 6. The source reading of the tokens listed on 2026-10-10 (CF-4)

The reading is `design/2026-10-18-token-source-reading.md`: the 31 Ethereum-issued coins and the 12 Wormhole copies,
SAND's first. No token is refused by the letter of the WBT rule; eight needed the owner's call, made the same day
(section 5): SAND and RLB off the list, the six others kept. The recommendations as given:
- **SAND:** two multisigs (3 of 5 and 2 of 3) can each move or burn any holder's SAND with no timelock, through 22
  operator contracts beside them. Recommended: delist, the rule's purpose.
- **RLB:** its implementation is unverified, and one externally owned key can upgrade it and pause it. Recommended:
  delist until its source is verified.
- **H, PLUME, SNX:** a 4-of-7 Safe can burn or seize any balance (PLUME's through a role it can grant at once).
  Recommended: keep, as for any token whose upgrader can change its code; the turnover cap does not bound this, so the
  app names the party.
- **SYRUP** (a burn behind Maple's 7-day timelocks), **GALA** (a blocklist only, no bar since 2026-10-10) and **MANA**
  (one key can pause every transfer): recommended keep; MANA, CHZ, SENT and FLUID labelled Pausable, as WBTC is.

What changed with it: `CheckToken` gained GALA's `blocklist` and SAND's `setExecutionOperator` (CF-4), so GALA now goes
to review, pinned by `testFork_everyWideTokenPassesTheCheck`, and SAND's review is pinned by
`testFork_CF4_sandGoesToReviewWithItsAdmin` now that it is off the list (both passed at block 26,215,649); the address
book's EIGEN note is corrected. The check still cannot see SNX's powers, which sit behind Synthetix's own proxy, nor
tell an owner's `burn(address,uint256)` from a bridge's: the reading is the control for both.

## 7. What stays open before mainnet

- **Pyth's API key.** The replay (the spec's section 8) and a settlement on a real Hermes update both need it; the
  owner adds `PYTH_API_KEY` to `.env`, and both run then.
- **Attestations:** the 31 copies and RAY's update (section 3), each the owner's transactions.
- **Fees:** the platform's launch policy and the legal reading (section 5).
- **Pyth:** the confirmation of section 1, item 4.
- **The external audit,** then `DeployWeighted`'s release hashes fixed at the audited commit (CF-5).
