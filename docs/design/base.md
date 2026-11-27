# A third deployment, on Base

2026-11-21. The owner's call, what was read on chain for it, and what was built the same day. Nothing is deployed on a
mainnet yet, on any chain.

## 1. The call

The owner, on 2026-11-21: "we have to add base . users should be able create indexes on bnb eth and base".

- **Who creates.** Asked whether that reopens creation to anyone, the owner kept the gate: "it should be like this. we
  have to approve and give them acces to out infrastructure and index creationg". Only wallets the owner approves
  create an index, on all three chains, as since 2026-11-10; a partner is approved and given access.
- **What Base lists.** Asked first, the owner chose the coins issued on Base and nothing bridged. Read on chain, only
  WETH, AERO and ZRO are that: MORPHO and VIRTUAL, named to the owner as issued there, are copies Base's own bridge
  mints from the Ethereum token. Told so, the owner chose to add the bridge's copies: each coin of Ethereum's list
  whose copy Base's bridge mints, proven on chain, labelled Bridged, through the admission check.

What it reverses: "no Base deployment for now" of 2026-10-18. What it does not change: no contract under `src/`, so
the release hashes did not move; Uniswap's Universal Router as the zap's one venue; no oracle; the approval to create.

## 2. What was read on chain on 2026-11-21

Base, at block 60,490,874, and Ethereum's side of Base's bridge the same day.

- **Uniswap.** The Universal Router (`0x6fF5693b99212Da76ad316178A184AB56D299b43`, 19,499 bytes) answers Base's
  PoolManager (`0x498581fF718922c3f8e6A244956aF099B2652b2b`); the V3 factory is
  `0x33128a8fC17869897dcE68Ed026d694621f6FDfD`. The fork suite pins all three by their runtime code hashes.
- **Routers replayed.** Ethereum's router address and BNB Chain's both carry their own chain's router on Base, byte
  for byte, and Base's router address has code on Ethereum and on BNB Chain. No router's code tells one of these
  chains from another: only a chain's id does.
- **The stablecoins.** USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`), Circle's, and USDT
  (`0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2`), which answers "Tether USD" and names no bridge. Six decimals each.
  Who can mint that USDT and replace its code was not read.
- **Backed.** Its xStock factory and its wrapper factory stand on Base at their Ethereum addresses. None of
  Ethereum's 109 wrappers has code at its address there. That the factories "have deployed nothing" was wrong:
  the wrapper factory has deployed four wrappers of Backed's older tokens there, found on 2026-11-22
  (`docs/design/coinbase-on-base.md`, section 2).
- **The bridge's copies.** Base's bridge on Ethereum (`0x3154Cf16ccdb4C6d922629664174b904d80F2C35`) held a balance of
  18 of Ethereum's 62 listed coins. For 13 a copy was found on Base and proven: its `remoteToken()` is the coin's
  address in `MainnetAddresses`, its `bridge()` is Base's standard bridge
  (`0x4200000000000000000000000000000000000010`), and `deposits(remote, copy)` on Ethereum is at or above the copy's
  supply on Base.

| Coin | Copy on Base | Held by the bridge on Ethereum | Supply on Base |
|---|---|---:|---:|
| UNI | `0xc3De830EA07524a0761646a6a4e4be0e114a3C83` | 386,118 | 258,796 |
| AAVE | `0x63706e401c06ac8513145b7687A14804d17f814b` | 39,815 | 38,608 |
| MORPHO | `0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842` | 25,684,048 | 25,428,097 |
| FET | `0x74F804B4140ee70830B3Eef4e690325841575F89` | 2,811 | 2,811 |
| CRV | `0x8Ee73c484A26e0A5df2Ee2a4960B789967dd0415` | 2,471,495 | 2,461,320 |
| VIRTUAL | `0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b` | 497,980,341 | 497,980,297 |
| PENDLE | `0xA99F6e6785Da0F5d6fB42495Fe424BCE029Eeb3E` | 615,058 | 611,825 |
| PEPE | `0xB4fDe59a779991bfB6a52253B51947828b982be3` | 105,233,389,202 | 105,233,389,201 |
| GRT | `0x0F4d237B09Cb37d207BA60353Dc254d4530D4dF1` | 33,903 | 32,300 |
| COMP | `0x9e1028F5F1D5eDE59748FFceE5532509976840E0` | 10,011 | 9,950 |
| SNX | `0x22e6966B799c4D5B13BE962E1D117b56327FDa66` | 1,070,270 | 1,069,569 |
| 1INCH | `0xc5fecC3a29Fb57B5024eEc8a2239d4621e111CBE` | 255,611 | 252,697 |
| RSR | `0xaB36452DbAC151bE02b16Ca17d8919826072f64a` | 5,737,138,977 | 5,736,889,473 |

  Not listed: SHIB and EIGEN, whose balance the bridge holds and for which no copy was found; LINK, whose Base token
  is Chainlink's own cross-chain token and not the bridge's copy; WBTC and WETH, which the bridge holds only dust of.
  The candidates came from the Superchain token list and from Blockscout's search by symbol; the proof is the three
  readings, not the lists.
- **A transaction's gas.** In 2,449 transactions of 150 blocks none asked for more than 16,777,216 gas and one asked
  for exactly that: Base holds a transaction to the cap Ethereum does. Its block limit was 40,000,000.

## 3. The list

Sixteen coins (`script/BaseAddresses.sol`): WETH and AERO, `Native`; ZRO, LayerZero's own omnichain token, `Bridged`
as on Ethereum; and the thirteen copies above, `Bridged`. `V5_WHITELIST=base` lists them and `CHECK=base` checks
them. Every one passes `CheckToken` as listable, its transfers exact. What the check reads of them: WETH has no power
over a holder; AERO is minted by Aerodrome's Minter; a copy can be minted, and burned out of any holder's balance, by
the bridge alone; MORPHO's copy is a proxy its issuer's Safe, 5 of 9, upgrades.

## 4. What it costs, said to the owner

- **No stocks.** A Base index holds crypto only until Backed deploys wrappers there. Superseded on 2026-11-22:
  Coinbase's ten stock tokens are listed (`docs/design/coinbase-on-base.md`).
- **Base's bridge is a party to thirteen of the sixteen.** The bridge mints and burns each copy, and the keys that
  upgrade Base can upgrade both of its halves: they reach the whole of each of those legs. It is the trust Base
  itself rests on, so it adds little beyond holding anything on Base, which is why these copies are listed where a
  third bridge's would not be.
- **Uniswap is the zap's one venue**, and most of Base's depth sits on Aerodrome, which neither the zap nor
  `CheckToken` reads. WETH, AERO and VIRTUAL route through Uniswap V3 (the fork suite mints and burns them); a coin
  without a Uniswap pool there mints in kind or through `MintRequests`.
- **An index lives on one chain.** Three deployments share nothing.
- **A wide index and Base's block.** One transaction carries the same 16.78M gas there, so `MAX_COMPONENTS`' 200
  holds; the list has sixteen. Under EIP-8037, should Base adopt it, the all-skipped redeem of a 200-coin index would
  need about 46M, above Base's block of 40M: a wide index there waits for that reading.

## 5. What was built

No contract under `src/` changed.

- `script/BaseAddresses.sol`: Base's address book: the sixteen coins, each copy with the Ethereum token it names
  (`remoteOf`, `bridged`), USDC and USDT, both halves of the bridge, and Uniswap's contracts.
- `DeployChecks` pins chain 8453 by its id alone (`onBase`). Until then a deployment on Base was read as BNB Chain's,
  by BNB Chain's router standing there, and stopped at BNB Chain's USDC address. On Base the owner and guardian rules
  of a mainnet apply: an owner Safe of three signatures, a guardian's Safe of two, the recorded build alone.
- `ConfigureWeighted` lists `V5_WHITELIST=base` on chain 8453 alone, pins Base's mint currencies and never proposes
  them as components; `CheckToken` takes `CHECK=base` and reads depth against WETH and USDC.
- Tests: `test/DeployChecks.t.sol` (the pin, the replays), `test/ConfigureWeighted.t.sol` (the list against a table
  written by hand, CR-L08's rule; the mint currencies, A7-22), `test/CheckToken.t.sol` and `test/Scripts.t.sol` (a
  deployment from the book). Mutants N6 to N10, all killed; N1, N2, N4 and N5 follow the rewritten lines.
- `test/fork/BaseAddresses.fork.t.sol`, 11 of 11 on Base's state at block 60,498,455, its pin: the tokens, the
  copies' three readings on Base's side, the router's code hashes and the two replays, a deployment from the book,
  the list on a fresh factory and through `CheckToken`, an index of all sixteen issued in kind, rebalanced with real
  transfers and redeemed, `MintRequests` filled in USDC and USDT with bound requests, the zap minting and burning an
  index of WETH, AERO and VIRTUAL in USDC along two-hop routes, and ether refused.

## 6. Not done

- The owner Safe and the guardian's Safe on Base, and the wallets approved to create there.
- A `BASE_RPC_URL` secret, without which CI skips the Base suite; it is run by hand until then, and its pin needs an
  archive node once the block ages.
- The reading of Base's USDT: who mints it and who can replace its code.
- The keeper on Base: its bot assumes twelve-second blocks, and it has no preset or executor there. The restock
  already buys AERO on Base for Ethereum's copy; a Base index holds AERO itself.
- The app: a third stack, and Base in its chain filter.
- SHIB's and EIGEN's copies, if they exist; more coins issued on Base, each a listing of its own.
