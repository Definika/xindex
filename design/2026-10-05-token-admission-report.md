# Token admission report (5 October 2026)

This report covers the 43 coins of `design/2026-10-05-wide-asset-support.md`:
- 29 with a contract on Ethereum, checked for listing;
- 14 on BNB Chain only, recorded for their vault listings.

`script/CheckToken.s.sol` (design section 2.1) checked every token on a fork. Its reports are the source of the
transfer, hook, power and depth columns below.

## Summary

- **27 of the 29 Ethereum coins are listed,** in `ConfigureWhitelist`'s `wide` list (`WHITELIST=wide`, chain 1). The
  flagship's `default` list does not change.
- **Two are refused under the WBT rule:**
  - **LEO:** a MiniMe token. Its controller can destroy any holder's balance and must approve every transfer. The
    controller's owner can install a new controller in one transaction.
  - **WLFI:** its owner, a 3-of-5 Safe, can blacklist any holder and move any holder's balance to another address
    (`ownerReallocateFrom`, read in the verified source).
- **The 14 BNB Chain tokens all pass the check.** None is refused, and none is added to any list. Eleven are custodial
  (the 10 Binance-Peg coins and ATOM); each lets a single externally owned key mint without limit, and four can also be
  upgraded by a single key. Bridged NIGHT has very likely lost its backing (see its note).
- **Depth on Ethereum is thin for every one of the 27.**
  - The best has $0.50M of depth within 2% of the price (AAVE), against $1.5M for LINK and $1.3M for UNI measured the
    same way.
  - Most have under $50k.
  - These tokens mint through `MintRequests` in the app, and redeem in kind.
- **Five listed tokens need the owner's attention before the Safe signs.** The two most serious:
  - **GRAM (TON):** the TON bridge that backs it was reported closed on 2026-09-01.
  - **OKB:** OKX is phasing the Ethereum copy out, and a single key can upgrade it.
  - The other three, and the rest of the owner's decisions, are under "Judgment calls for the owner" below.

## How the check was run

- **Forks:**
  - Ethereum at block 26,124,000, through `ethereum-rpc.publicnode.com`.
  - BNB Chain at block 125,810,900, through `bsc-rpc.publicnode.com`.
  - The fork suites (`test/fork/CheckToken.fork.t.sol`, `test/fork/MainnetAddresses.fork.t.sol`) also pass at the
    repository's pinned block 26,033,838, through the archive RPC `eth.drpc.org`.
- **Transfers:** a test balance is written into the token's balance slot, or taken from a holder or from the token's
  pools. Then `transfer` and `transferFrom` run between made-up accounts, and every balance is compared exactly, once
  at once and again a day later.
- **Hooks:** an `ERC777Token` entry in the ERC-1820 registry, which is present on both chains, and ERC-1363 by ERC-165.
- **Admin powers:** a scan of the selectors in the token's runtime code and in its implementation's.
  - The scan is a heuristic, so I also read every token's selector list by hand. The names came from the openchain.xyz
    signature database, and I read the verified source (from Sourcify) wherever a power's reach was unclear: WLFI,
    LEO and its controller, GT, RENDER, CAKE, ONDO, SKY, ENA, MNT, ETHFI, FET, ARB and NIGHT.
  - The table in `CheckToken.powerOf` gained every admin name this review found, each line naming the token it comes
    from.
- **Depth:** each standard Uniswap V3 pool against WETH and USDC, and each hookless V4 pool against ether and USDC.
  - The figure is both sides of the pool within 2% of its price, from the liquidity active now. It is an approximation
    that ignores tick crossings.
  - Converted to dollars with CoinGecko's price on 5 October; the dollar figures are mine, derived from the token
    amounts.
- **Addresses:**
  - Each comes from CoinGecko's API and is cross-checked against CoinMarketCap's coin data and CoinPaprika's contract
    list, or the issuer's documents.
  - On Ethereum, the only gaps are OKB (CoinMarketCap lists no Ethereum contract; CoinGecko and CoinPaprika agree) and
    ICP (CoinPaprika lists none; CoinGecko, CoinMarketCap and DFINITY's OISY wallet configuration agree).
  - On BNB Chain, CoinMarketCap lists no BNB Chain contract for SOL; CoinGecko, Trust Wallet's asset list and
    PancakeSwap's token list agree.
  - Every address was read on chain by symbol and decimals. `test/fork/MainnetAddresses.fork.t.sol` pins the 27 listed
    ones.
- **Reference supplies:**
  - CoinGecko's circulating supply on 2026-10-05 (updated 04:44 to 04:56 UTC), rounded down to whole tokens.
  - Beside it, CoinMarketCap's figure at 05:00 UTC, or Blockchair's node-derived figure for DOGE.
  - Where the two agree to the token they most likely share the issuer's figure, so the agreement is not two
    independent measurements.
  - A bridged or custodial copy carries its coin's whole circulating supply, as WBTC carries bitcoin's.

**Marks used below:**
- **[v]** I verified it on chain myself (a call, a storage read or the bytecode).
- **[s]** It comes from the verified source code.
- **[w]** A website or a published source says it; I did not verify it myself.

## Ethereum: the 27 listed

Every row passed with exact transfers, no ERC-777 or ERC-1363 hooks, and no blacklist with a destroy [v].

Supplies are whole tokens; the entry is that number times 10^decimals. Powers marked [v] come from the selector scan,
which also covers each proxy's implementation; those marked [s] come from the verified source. Depth is both sides
within 2%, all standard pools together.

| Token | Address | Tier | Dec | Reference supply (CoinGecko) | CoinMarketCap (diff) | Admin powers | Who holds them [v] | Depth |
|---|---|---|---|---|---|---|---|---|
| QNT | `0x4a220E6096B25EADb88358cb44068A3248254675` | Native | 18 | 14,544,176 | 12,072,738 (+20.5%) | mint [v], callable by its crowdsale contract `0x398e…46F7` [v] | no `owner()` | $98k |
| AAVE | `0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9` | Native | 18 | 15,435,383 | 15,435,383 | upgrade [v] | proxy admin `0x86C3…b517`, a contract whose owner `0x17Dd…6957` is a contract | $499k |
| OKB | `0x75231F58b43240C9718Dd58B4967c5114342a86c` | Native | 18 | 21,000,000 | 21,000,000 | upgrade [v]; the implementation is a bridge-out token (`triggerBridge`) [v] | `proxyOwner()` `0x4A16…a981`, **a single key** | $1k |
| ENA | `0x57e114B691Db790C35207b2e685D4A43181e6061` | Native | 18 | 10,362,500,000 | same | mint, with `MAX_INFLATION` and `MINT_WAIT_PERIOD` among its selectors [v]; burnFrom needs an allowance [s] | owner `0xE8Dc…7c94`, a timelock with a 1-day delay | $190k |
| ONDO | `0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3` | Native | 18 | 4,869,330,647 | same | mint (MINTER_ROLE) [v]; tranche locks, moot now that every vesting period has passed [s][v] | AccessControl roles, not enumerable | $239k |
| SKY | `0x56072C95FAA701256059aa122697B133aDEd9279` | Native | 18 | 23,430,551,390 | 23,430,516,994 | mint (wards) [v]; `burn(from)` needs an allowance [s] | Maker-style `wards`, not enumerable | $131k |
| WLD | `0x163f8C2467924be0ae7B5347228CABF260318753` | Native | 18 | 3,798,073,016 | same | mint (`mintInflation`, `mintOnce`, `setMinter`) [v] | owner `0x59a0…B596`, **a 1-of-1 Safe** | $15k |
| MNT | `0x3c3a81e81dc49A522A592e7622A7E711c06bf354` | Native | 18 | 3,302,003,382 | same | mint, with `MINT_CAP_*` among its selectors, and upgrade [v]; burnFrom needs an allowance [s] | owner a 6-of-14 Safe `0x4e59…D40f`; proxy admin `0x0cac…9ADd`, owned by a timelock with a 1-day delay | $1k |
| MORPHO | `0x58D97B57BB95320F9a05dC918Aef65434969c2B2` | Native | 18 | 700,036,111 | 532,608,523 (+31.4%) | mint, UUPS upgrade [v] | owner `0xcBa2…9AFa`, a 6-of-10 Safe | $13k |
| BGB | `0x54D2252757e1672EEaD234D27B1270728fF90581` | Native | 18 | 699,992,029 | same | none found [v] | none | none measurable (4 pools) |
| POL | `0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6` | Native | 18 | 10,626,317,704 | 10,626,317,694 | mint (EMISSION_ROLE), with `mintPerSecondCap` among its selectors [v] | DEFAULT_ADMIN_ROLE `0x29A6…5b18`, a timelock with a 10-day delay | $4k |
| GT | `0xE66747a101bFF2dBA3697199DCcE5b743b454759` | Native | 18 | 104,663,958 | 104,663,942 | pause: `resetMode()` stops every transfer [s] | owner `0x5A0c…96dD`, **a single key** | none measurable (1 pool) |
| LIT | `0x232CE3bd40fCd6f80f3d55A522d03f25Df784Ee2` | Native | 18 | 250,000,000 | same | none found [v] | none | $49k |
| ETHFI | `0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB` | Native | 18 | 965,350,000 | same | burnFrom needs an allowance [s] | none | $29k |
| FET | `0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85` | Native | 18 | 2,311,508,384 | 2,341,485,817 (−1.3%) | mint, pause (roles) [v]; burnFrom needs an allowance [s] | DEFAULT_ADMIN_ROLE `0x8400…129B`, a 3-of-5 Safe | $48k |
| CRV | `0xD533a949740bb3306d119CC777fa900bA034cd52` | Native | 18 | 1,571,278,819 | 1,569,832,680 (+0.1%) | mint by its `minter` `0xd061…fcE0` (Curve's Minter), on the emission schedule [v] | Vyper `admin` `0x4090…9968`, a contract | $26k |
| NEXO | `0xB62132e35a6c13ee1EE0f84dC5d40bad8d815206` | Native | 18 | 1,000,000,000 | 646,145,839 (+54.8%) | none found; vesting withdrawals by the owner [v] | owner `0x5779…e1Da`, a single key | $3k |
| VIRTUAL | `0x44ff8620b8cA30902395A7bD3F2407e1A091BF73` | Native | 18 | 658,385,841 | 659,001,770 (−0.1%) | mint, with `cap()` among its selectors [v] | `owner()` is zero, so renounced [v] | $22k |
| STRK | `0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766` | Native | 18 | 7,421,949,505 | same | mint (MINTER_ROLE) [v] | AccessControl roles, not enumerable | under $1k |
| PENDLE | `0x808507121B80c02388fAd14726482e061B8da827` | Native | 18 | 173,634,059 | same | none found; emissions configured by `governance` [v] | `governance` `0x8119…6ee1`, a Safe with threshold 3 | $28k |
| GRAM (TON) | `0x582d872A1B094FC48F5DE31D3B73F2D9bE47def1` | Bridged | 9 | 2,819,616,021 | 2,819,624,866 | mint on the votes of a 9-oracle set (`voteForMinting`) [v] | the oracle set [v] | $10k |
| CRO | `0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b` | Bridged | 8 | 49,533,969,069 | 49,533,955,328 | mint, finished (`mintingFinished()` is true) [v] | owner `0x3A39…0945`, a contract | $34k |
| ICP | `0x00f3C42833C3170159af4E92dbb451Fb3F708917` | Bridged | 8 | 557,202,382 | 557,202,386 | mint and `batchMint` [v] | owner `0x70AE…192C`, **a single key** | $25k |
| ARB | `0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1` | Bridged | 18 | 6,785,574,605 | same | upgrade [v]; mint and burn of any account by Arbitrum's gateway [s]; transferAndCall [v] | proxy admin `0x5613…0678`, a contract whose owner `0x3fFF…CeDd` is a contract | $1k |
| RENDER | `0x6De037ef9aD2725EB40118Bb1702EBb27e4Aeb24` | Bridged | 18 | 518,776,241 | same | upgrade, but the proxy admin is `0x…dEaD`, so renounced [v] | owner `0xDE68…84e8`, a single key, which sets the escrow address [s] | $43k |
| CAKE | `0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898` | Bridged | 18 | 376,261,104 | same | pause, of bridging only [s]; mint on LayerZero messages from the trusted remotes the owner sets [s] | owner `0xC9D3…000b`, a contract whose owner `0x2183…FC02` is a 3-of-7 Safe | under $1k |
| ZRO | `0x6985884C4392D348587B19cb9eAAf157F13271cd` | Bridged | 18 | 353,313,325 | 399,061,088 (−11.5%) | mint on LayerZero messages from the peers the owner sets (OFT) [v] | owner `0xCDa8…4C92`, a 3-of-5 Safe | $3k |

## Ethereum: the 2 refused

| Token | Address | Dec | Reference supply (CoinGecko) | Powers | Who holds them [v] | Depth | Verdict |
|---|---|---|---|---|---|---|---|
| LEO | `0x2AF5D2aD76741191D15Dfe7bF6aC92d4Bd912Ca3` | 18 | 919,857,851 (CoinMarketCap the same) | the controller destroys any holder's balance (`destroyTokens`) and mints (`generateTokens`) [s]; every transfer asks the controller (`onTransfer`) [s]; transfers can be switched off (`enableTransfers`) [s] | controller `0xF17E…E5672` (`LEOController`) [s], owned by `0xC6CD…a828`, a contract that is neither a Safe nor a timelock [v]; `upgradeController` installs any new controller at once [s] | under $1k | **refused**, WBT rule |
| WLFI | `0xdA5e1988097297dCdc1f90D4dFE7909e847CBeF6` | 18 | 31,778,337,976 (CoinMarketCap 31,778,344,460) | `ownerSetBlacklistStatus`, `guardianSetBlacklistStatus` [s]; `ownerReallocateFrom` and `ownerBatchReallocateFrom` burn from any holder and mint to another [s]; `ownerPause` and `guardianPause` [s] | owner `0x5be9…7dBB`, a 3-of-5 Safe, which also owns the proxy admin [v]; guardians set by the owner [s] | under $1k | **refused**, WBT rule |

**Why LEO falls under the rule as written.** LEO's controller is a contract, and every transfer asks it to approve.
Today's controller (`LEOController`) approves every transfer, and destroys only its own owner's tokens [s]. But one
call by that controller's owner (`upgradeController`) installs any controller [s]. A new controller can refuse any
holder's transfers, which is a blacklist, and call `destroyTokens(holder, amount)` on any balance [s]. The key that can
do both is the controller's owner.

## BNB Chain: the 14, recorded for their vault listings

None of these is added to any list or script. Every row passed with exact transfers and no ERC-777 or ERC-1363 hooks
[v]. Depth is measured on Ethereum only, so it is not given here.

Binance-Peg tokens are listed by the native coin's circulating supply. Supplies are whole tokens; the entry is that
number times 10^decimals.

| Token | Address | Tier | Dec | Reference supply (CoinGecko) | Second source (diff) | Admin powers | Who holds them [v] | On-chain totalSupply [v] | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| XRP | `0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE` | Custodial | 18 | 63,092,975,951 | CoinMarketCap, same | mint (`mint(uint256)`, to the owner) [v] | `owner` = `getOwner` = `0xF68a…f62d`, a single key | 325,799,999 | passes |
| SOL | `0x570A5D26f7765Ecb712C0924E4De545B89fD43dF` | Custodial | 18 | 588,314,090 | CoinMarketCap 588,314,062 | mint, upgrade [v] | `getOwner` `0xA6CA…D2aA`, a single key; proxy admin `0xD2f9…C6C4`, a single key | 1,500,000 | passes |
| ZEC | `0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb` | Custodial | 18 | 16,966,725 | CoinMarketCap 16,901,419 (+0.4%) | mint [v] | `0xF68a…f62d`, a single key | 219,999 | passes |
| DOGE | `0xbA2aE424d960c26247Dd6c32edC70B295c744C43` | Custodial | **8** | 156,193,186,383 | Blockchair 156,193,796,383 | mint, upgrade [v] | `getOwner` `0xF68a…f62d`; proxy admin `0xD2f9…C6C4`; both single keys | 2,563,999,999 | passes |
| ADA | `0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47` | Custodial | 18 | 37,541,298,084 | CoinMarketCap 36,786,187,631 (+2.0%) | mint [v] | `0xF68a…f62d`, a single key | 451,907,177 | passes |
| BCH | `0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf` | Custodial | 18 | 20,098,553 | CoinMarketCap 20,098,593 | mint [v] | `0xF68a…f62d`, a single key | 96,499 | passes |
| LTC | `0x4338665CBB7B2485A8855A139b75D5e34AB0DB94` | Custodial | 18 | 77,681,660 | CoinMarketCap 77,684,523 | mint [v] | `0xF68a…f62d`, a single key | 744,999 | passes |
| AVAX | `0x1CE0c2827e2eF14D5C4f29a091d735A204794041` | Custodial | 18 | 443,237,655 | CoinMarketCap 443,237,725 | mint, upgrade [v] | `getOwner` `0xF68a…f62d`; proxy admin `0xD2f9…C6C4`; both single keys | 2,000,000 | passes |
| DOT | `0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402` | Custodial | 18 | 1,705,877,534 | CoinMarketCap 1,705,891,826 | mint [v] | `0xF68a…f62d`, a single key | 15,999,999 | passes |
| FIL | `0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153` | Custodial | 18 | 833,303,530 | CoinMarketCap, same | mint, upgrade [v] | `getOwner` `0xF68a…f62d`; proxy admin `0xD2f9…C6C4`; both single keys | 15,009,999 | passes |
| ASTER | `0x000Ae314E2A2172a039B26378814C252734f556A` | Native | 18 | 2,710,487,455 | CoinMarketCap 2,704,529,094 (+0.2%) | none found; fixed supply of 8,000,000,000 [v] | none | 8,000,000,000 | passes |
| ATOM | `0x0Eb3a705fc54725037CC9e008bDede697f62F335` | Custodial | 18 | 534,279,412 | CoinMarketCap 534,079,426 | mint [v] | `0xF68a…f62d`, a single key | 2,499,993 | passes |
| NIGHT | `0xFe930c2d63AeD9b82fC4DBC801920dD2c1a3224F` | Bridged | 18 | 16,607,399,400 | CoinMarketCap, same | mint; **`burn(account, value)` destroys any holder's balance with no allowance** [s] | owner `0x39Af…17dD` (Wanchain's token manager [w]), a contract whose owner `0x5a80…e15f` is a contract | 526,467,272 | passes (no blacklist), with the warning below |
| STABLE | `0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F` | Bridged | 18 | 26,924,041,495 | CoinMarketCap 26,923,983,196 | upgrade [v]; mint on LayerZero messages from the peers the owner sets (OFT) [v] | owner `0x2548…d2E6`, a 3-of-5 Safe, which also owns the proxy admin `0x386f…6392` | 727,292,148 | passes |

**The proxies:**
- SOL, DOGE, AVAX and FIL share one implementation, `0xBA5F…0B5C` [v]. Its `mintable()` reads true [w, read by the
  researcher].
- `0xF68a…f62d` is labelled a Binance account on BscScan, according to search results; BscScan itself could not be
  opened [w].

## Notes per token

- **GRAM (TON):**
  - On chain the token is the TON bridge's "Wrapped TON Coin", symbol `TONCOIN`, 9 decimals [v].
  - CoinGecko and CoinMarketCap now call the coin Gram (GRAM) and still list this contract [w].
  - KuCoin, Bitget and cryptoticker reported that bridge (bridge-v3.ton.org) closing for good on 2026-09-01; no ton.org
    page was found [w]. Whether the 9.29M on Ethereum can still be redeemed is unknown.
  - Treat it as an IOU whose issuer may be gone.
- **OKB:**
  - OKX said on 2025-08-13 that the Ethereum copy "will be gradually phased out", and withdrawals to Ethereum have
    ended [w].
  - Its on-chain supply is 429,064 OKB of the 21M [v].
  - A single key (`proxyOwner`) can upgrade it with no delay [v], so that key could at any time install code that
    seizes balances. This is the "upgrade with no timelock" question of design decision 3.
- **GT:**
  - A single key can stop every transfer (`resetMode`) [s]. GT also has a self-freeze anyone can apply to their own
    tokens (`freeze(uint256)`), which is not an admin power [s].
  - Whether the 2019 ERC-20 is still canonical, rather than GateChain's coin, is not documented [w].
  - About 64% of the on-chain supply sits in one untagged address [w].
- **CRO:**
  - The original 2018 ERC-20 [w].
  - Crypto.com's migration to the native coin runs one way [w], and 86.85B of the 100B ERC-20 supply sits at
    `0x…dEaD` [w, read by the researcher].
  - Minting is finished [v].
- **RENDER:**
  - Render's own upgradeable ERC-20, symbol `RNDR`; its upgrade is renounced to `0x…dEaD` [v].
  - Render calls the Solana token canonical [w]. About 455M of the 533.5M on Ethereum is locked in Wormhole's bridge,
    which backs Solana's RENDER [w].
- **ICP:**
  - Minted by the OneSec bridge (1sec.to) [w], and on chain by a single key [v].
  - That the key belongs to the bridge rests on DefiLlama's bridge adapter and DFINITY's OISY wallet configuration, not
    on an official OneSec document [w].
- **WLD:** the owner is a Safe with one signer and threshold one [v], so in effect a single key controls minting
  (`setMinter`, `mintInflation` after its unlock).
- **NEXO:** the owner is a single key [v]; no mint, pause or blacklist was found [v].
- **ARB:** Arbitrum's gateway can mint and burn any account's L1 ARB [s]. The gateway is Arbitrum's own contract, which
  burns only when a holder bridges out [w].
- **CAKE and ZRO:** LayerZero tokens that mint when a message arrives from a trusted peer. Their owners (a contract
  under a 3-of-7 Safe, and a 3-of-5 Safe) set those peers [s][v], so a peer set wrongly, or a broken verifier set, could
  mint unbacked tokens on Ethereum. CAKE's pause stops bridging, not transfers [s].
- **NIGHT (BNB Chain):**
  - On 2026-07-20 an attacker reportedly drained about 515.2M NIGHT, roughly 97.8%, of the Cardano-side treasury that
    backs BNB Chain's NIGHT. Wanchain paused the route; no restoration plan was found [w].
  - Its owner can also burn any holder's NIGHT [s].
  - Treat it as unbacked until shown otherwise. A vault listing would put NIGHT's burn power over the vault's balance.
- **Binance-Peg tokens:**
  - Binance states each is pegged 1:1 to coins in its custody [w]. Nothing on chain ties the supply to reserves, and
    one key mints [v].
  - SOL, DOGE, AVAX and FIL can also be upgraded by a single key [v].
  - DOGE has 8 decimals on BNB Chain [v].
- **Supply disagreements over 10%:**
  - NEXO +54.8%: CoinMarketCap leaves out the buyback reserve.
  - MORPHO +31.4%: CoinMarketCap leaves out the DAO's and the Morpho Association's tokens.
  - QNT +20.5%: CoinMarketCap leaves out the company treasury.
  - ZRO −11.5%: Tokenomist gave about 375.9M on 2026-09-20.
  - Each explanation is [w]. Every entry uses CoinGecko's figure, the source of the existing supplies; the owner may
    prefer the lower figures for NEXO, MORPHO and QNT.
- **Possible omission:** KCS (KuCoin Token) is CoinMarketCap #65 with an Ethereum contract,
  `0xf34960d9d60be18cC1D5Afc1A6F012A723a28811` (on chain KCS, 6 decimals [v, read by the researcher]). CoinGecko lists
  no Ethereum contract for it, so it is not among the design's 43. It was not checked.

## Judgment calls for the owner

1. **LEO is refused under the WBT rule.** Its blacklist is indirect: a controller that approves every transfer, which
   the controller's owner can replace at once. I counted that as a blacklist, because the same key can refuse any
   holder's transfers and destroy any holder's balance. Read literally as "a function named blacklist", LEO would pass.
2. **What the check refuses, and what it leaves for review.**
   - It refuses a blacklist together with a destroy, exactly the WBT rule.
   - It leaves for review (verdict `REVIEW`, never listable without a person's reading) two cases: a destroy with no
     blacklist found, since the destroy needs no gate; and a blacklist with a burn from another account, since
     OpenZeppelin's `burnFrom` needs an allowance and others do not.
   - None of the 27 hit either case.
   - NIGHT's owner can burn any balance with no blacklist. It shows as a "burn from another account", which the rule
     leaves listable. If the owner wants a destroy alone to refuse, that is a one-line change in `verdictOf`.
3. **GRAM (TON) and OKB are listed under the default rule, but I would not sign their listings.** GRAM's backing
   bridge is reported closed. OKB is being retired on Ethereum and a single key can upgrade it. Both are in the `wide`
   list because only the WBT rule refuses; leaving them out of the Safe batch is the owner's call (`LIST` names the
   tokens to propose).
4. **Tiers follow the design's grouping:** the 20 issued on Ethereum are Native, and the 7 copies are Bridged. Two are
   arguable:
   - RENDER's Ethereum token is Render's own original issuance, and the lock side of Wormhole, not a bridge's copy.
   - CRO's is the original ERC-20 of a coin that moved to its own chain.

   Both behave more like Native than Bridged, but neither is a live issuance any more; I kept the design's label.
   ZRO and CAKE stay Bridged on purpose: a LayerZero peer mints them on Ethereum.
5. **Supplies:** CoinGecko's figure throughout, including the four large disagreements above.
6. **Depth:** every listed token is far thinner than LINK or UNI. All 27 are listed, as the defaults say, and mint
   through `MintRequests`.

## What could not be verified

- **Every off-chain statement marked [w]:** bridge closures, custody claims, which address belongs to which company,
  and the reasons supplies differ.
- **Binance-Peg reserves:** Binance's collateral page loads by JavaScript and returned nothing readable.
- **BscScan:** its labels could not be read (Cloudflare blocks automated access).
- **AccessControl roles and Maker-style wards** that are not enumerable (ONDO, STRK, SKY): their holders are unknown
  without reading the role events.
- **Unnamed admin contracts:** I did not identify the governance contracts behind AAVE's, ARB's, CRO's, NIGHT's and
  LEO's admins. Each is "a contract" in the tables.
- **The selector scan** misses a power held under a name its table does not list. Every token's full selector list was
  read by hand for this report, but the script alone would not catch a new name.
