# Coinbase's coins and stocks on Base

2026-11-22. The owner's calls, what was read for them, and what was built the same day. It adds sixteen tokens to
Base's list, which is thirty-two, and corrects one statement of `docs/design/base.md`. No contract
under `src/` changed, and the release hashes did not move. Nothing is deployed on a mainnet yet, on any chain.

## 1. The calls

The owner, on 2026-11-22: "add stocks on base also." Told what stock tokens stand on Base (section 2), the owner
said: "add all coinbase wrapped tokens in base".

That is read here as every token Coinbase issues on Base, the reading that leaves nothing of the sentence out:

- the six **Coinbase Wrapped coins**, cbBTC, cbETH, cbXRP, cbDOGE, cbLTC and cbADA, whose names are "Coinbase
  Wrapped BTC" and so on;
- Coinbase's ten **stock tokens**, NVDAc, METAc, AAPLc, GOOGLc, AMZNc, MSFTc, MSTRc, SNDKc, SPCXc and TSLAc, which
  the request for stocks was about.

If the owner meant one of the two, the other is a list entry to drop: sections 4 and 5 keep them apart.

What the call changes in earlier calls:

- **cbBTC** was left off Base's list on 2026-11-21 as a custodian the lists did not have. It is listed.
- **Stocks on Base are Coinbase's.** "xStocks 100 percent" of 2026-11-21 stands on Ethereum and BNB Chain, where
  Backed's wrappers are. Backed has no xStock on Base.
- **DOGE** has been off every list since 2026-10-14, when its only listable form was Wormhole's copy of a
  Binance-Peg token. cbDOGE is Coinbase's own.
- The listing rule for a stock, a Pyth feed that names the token, is not applied to Coinbase's: the owner named
  them. Coinbase publishes Chainlink feeds for them; no contract reads either.

What it does not change: only wallets the owner approves create an index; an index lives on one chain; no contract
reads a price.

## 2. What stock tokens stand on Base

Read on 2026-11-22, on chain unless a line says otherwise.

- **Backed.** Its xStock factory (`0x9768D3956a850913fb74594eBf40DFf9b5b576F3`) has a nonce of 3 on Base, where
  Ethereum's stands at 1,563 for its 1,560 xStocks: it has deployed none. Its wrapper factory
  (`0x3dD6fbDeCb1dEe5ebeB883b12C6Da4d20F45f148`) has a nonce of 7: an implementation, a ProxyAdmin and four
  wrappers, each over one of Backed's older tokens, at the address the same wrapper has on Ethereum.

  | Wrapper | Address | Over | The older token's supply on Base | Wrapper's supply | Rate |
  |---|---|---|---:|---:|---:|
  | wbCOIN | `0xDEc933e2392AD908263e70A386fbF34e703Ffe8F` | bCOIN `0xbbcb0356bB9e6B3Faa5CbF9E5F36185d53403Ac9` | 13,500 | 237.25 | 1 |
  | wbMSTR | `0x1a4F71B0Ff3C22540887bcf83b50054a213c673d` | bMSTR `0xaC28C9178ACc8BA4A11A29E013a3A2627086e422` | 3,000 | 0.00085 | 1 |
  | wbNVDA | `0x7E8101A1C322D394b3961498c7D40d2DFA94C392` | bNVDA `0xA34C5e0AbE843E10461E2C9586Ea03E55Dbcc495` | 7,062.7 | 0.0011 | 1.0078 |
  | wbTSLA | `0x1f82284C1658Ad71C576f7230E6C2DEE7901c1FA` | bTSLA `0x14A5f2872396802C3Cc8942A39Ab3E4118EE5038` | 3,000 | 0 | 1 |

  A 2-of-3 Safe owns them (`0xD1966bd72695789ec9C245F0Bf5A8512B56c1d80`) and another upgrades them
  (`0x49754062E35f7591B93cc4F9915965be89643a65`, the Safe that upgrades Ethereum's). They are **not listed**: Pyth
  has no feed that names bCOIN, bMSTR, bNVDA or bTSLA, the owner's rule of 2026-11-19, which is why Ethereum's list
  leaves the same four out. Three of the four wrappers hold next to nothing. Listing them is the owner's call.

  **A correction.** `docs/design/base.md`, the address book's header and this file's neighbours
  said on 2026-11-21 that Backed's factories on Base "have deployed nothing". Only the 109 wrappers of Ethereum's
  list were looked for there, and none stands on Base; the four above were missed. The factories' nonces are the
  count.
- **Base's bridge** holds none of Ethereum's 109 wrapped xStocks: no wrapped xStock has been bridged to Base.
- **Coinbase.** Ten stock tokens, live since 2026-08-24 (Base's own registry, `base.org/stocks`, read that day; each
  address then read on chain). Section 5.

## 3. The Coinbase Wrapped coins

Each read on chain on 2026-11-22 and through `CheckToken` on a fork, at block 60,529,140.

| Coin | Address | Decimals | Supply | Upgraded by | Owner |
|---|---|---:|---:|---|---|
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 8 | 49,669 | a key, `0x42D90b3faF2287475cdc863706Bd7cc3E938C2Af` | a key, `0xbbc9b6001cf0a4FCcfFAB7bDda1ab16cafb9dB4F` |
| cbETH | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` | 18 | 98,982 | a Safe, 3 of 6, `0xd94E416cf2c7167608B2515B7e4102B41efff94f` | none |
| cbXRP | `0xcb585250f852C6c6bf90434AB21A00f02833a4af` | 6 | 158,033,451 | a key, `0x82Ce0Be66Bb58435a3C76f27F1785F171a527006` | a key, `0xe69cC1506F555Dd459266a1d3782C506Cb6e2D15` |
| cbDOGE | `0xcbD06E5A2B0C65597161de254AA074E489dEb510` | 8 | 128,517,165 | a key, `0x9c5539051551C4D21fE8284ac51259Fb09cBd52F` | a key, `0x7F40dC4045269158d83258Fd24fF624395A64F2B` |
| cbLTC | `0xcb17C9Db87B595717C857a08468793f5bAb6445F` | 8 | 70,316 | a key, `0x29e7A53cc90Ee988697ded8Ec37a59B0c059A1b0` | a key, `0x52198693f086385B5c4211002c37Dd112De46DD4` |
| cbADA | `0xcbADA732173e39521CDBE8bf59a6Dc85A9fc7b8c` | 6 | 54,557,947 | a key, `0xe3302c6BC421A06A7B59F3eB7cEFd885a4884F64` | a key, `0x5a09C8708101c2c822d2d25a928b1E3d985BeEe9` |

- **Five are issued on Base**: a proxy each, which the chain shows one externally owned account upgrading and
  another owning. What stands behind those accounts, a custody system or one person's key, the chain does not say.
  The selector scan finds a mint, a pause, a blocklist and the upgrade, and no call that destroys a holder's
  balance. Every one passes `CheckToken` as listable, its transfers exact.
- **cbETH is Base's bridge's copy** of Ethereum's cbETH (`0xBe9895146f7AF43049ca1c1AE358B0541Ea49704`), Coinbase's
  staked ether, which is not on Ethereum's list: it names that token and the bridge, and the bridge held
  98,982.42 cbETH on Ethereum against 98,982.37 minted on Base. Its value rises against ether while balances stay
  fixed, so it is a component like any other. It is tiered Custodial, with the bridge as a second party.
- Every one has Uniswap pools on Base, which `CheckToken` measures.

## 4. Coinbase's stock tokens

| Token | Of | Address | Supply | Multiplier |
|---|---|---|---:|---:|
| NVDAc | NVIDIA | `0xb20000000000000000000078ee7ce2fE4908108C` | 62,019.7 | 1.000538 |
| METAc | Meta Platforms | `0xb2000000000000000000008bC8786B856E61707C` | 9,037.5 | 1.000314 |
| AAPLc | Apple | `0xb200000000000000000000C2e324d24d7eEcd1fb` | 6,103.1 | 1.000500 |
| GOOGLc | Alphabet | `0xb2000000000000000000002D0BA3164cc74f58B7` | 37,248.3 | 1.000377 |
| AMZNc | Amazon | `0xb200000000000000000000d9192b6B456483C2E8` | 10,198.5 | 1 |
| MSFTc | Microsoft | `0xB200000000000000000000Ab99cFa739E253872B` | 2,702.7 | 1 |
| MSTRc | Strategy | `0xb2000000000000000000004884b426556b92883d` | 23,081.0 | 1 |
| SNDKc | Sandisk | `0xb200000000000000000000397293Cb8cda9a10c5` | 3,330.0 | 8 |
| SPCXc | SpaceX | `0xb2000000000000000000007b9fcbd005511aCBd5` | 30,116.6 | 1 |
| TSLAc | Tesla | `0xb2000000000000000000001e800a7f5189430cD0` | 6,527.3 | 1 |

Eight decimals each. Read on chain: the symbol, the name, the decimals, the supply, the multiplier, the code, and
that a transfer answers true.

- **A token is not a contract.** Each is a B20 token, a precompile of Base at a fixed address. Its code is the one
  byte `0xef`. Base's node runs it; an EVM without Base's precompiles runs the byte, which is no opcode, so every
  call fails there and burns the gas it was given. Foundry runs them from v1.8.4 (Base's documentation); this
  repository pins v1.8.1, whose `cast call --trace` answers `OpcodeNotFound`.
- **A token is not one share.** One token redeems for `multiplier()` shares. A dividend raises it and a split
  multiplies it, while every balance stays as it was: NVDAc stood at 1.0005 shares that day and SNDKc at 8.
  Balances that never move are what an index needs (CF-3, RX-8); the multiplier is what whoever values the leg must
  read, as with a wrapped xStock's rate.
- **What the issuer can do**, from Base's B20 specification, read that day and not from the chain, where the roles'
  holders were not read: mint and burn; block an address through a policy, so that its transfers revert; pause
  transfers; move a balance to another account (`seizeWithMemo`) unless a policy exempts the holder, and by default
  every holder is exempt; set the multiplier, with no timelock in the standard. The issuer is Coinbase's ADGM
  company and the shares are in Alpaca's custody (Coinbase's and the press's account). Coinbase offers the tokens
  to users outside the United States; minting and redeeming are for its authorized participants alone.
- **Markets.** Uniswap's V4 PoolManager on Base held about 2,640 NVDAc and 360 AAPLc that day, so Uniswap pools exist for
  at least those two; Coinbase names Aerodrome as the main venue. No route was built or tried.

## 5. The proof, on Base's own node

A fork test runs in Foundry's EVM, which cannot execute these tokens, so `test/fork/BaseStocks.fork.t.sol` executes
nothing of them locally. It asks the node:

- Every read is an `eth_call` the node answers (`vm.rpc`).
- The index's whole life is one `eth_simulateV1` request (`vm.rpcJson`), which the node runs on top of the forked
  block under the rules Base runs that day, signing for nobody:
  1. the factory of this build, deployed from its creation code;
  2. WETH and the ten stocks proposed, and, a listing delay later, executed: the proposal reads each token's
     decimals from the precompile;
  3. an index of all eleven created;
  4. an issue in kind, from tokens real holders send the minter: the index pulls each stock, sends itself one raw
     unit of it (RW-8) and holds exactly what the preview named;
  5. eight days on, a rebalance started and, two hours into its auction, filled by an executor deployed in the
     simulation: WETH leaves, each stock comes in, the units are the ones named and every balance moves by exactly
     the previewed amount, the probe that a bought leg can leave (RX-12) passing on every stock;
  6. the redeem of every share at the new units: the holder receives exactly the preview, and the index is left
     with what it held less that.
- The widest call, the factory's deployment, carries 16,000,000 gas, under what one transaction on Base may; the
  simulated blocks keep Base's own gas limit.
- The test fails when a step fails on the node: with the minter one raw unit short of a stock, it stops at "issue
  in kind".

So an account the issuer never met, a contract, receives each stock, sends it to itself and sends it on, and every
amount is exact. What the simulation is not: a transaction. It runs on one node's word, against state no block
holds, and the blocklist, the pause and a seizure are untried, as they are for every issuer's token.

## 6. What the pinned toolchain cannot do with a stock token

- **`CheckToken` does not read one.** It reports "a precompile of its chain, which this EVM cannot execute", for
  review, and judges nothing; before, it refused the token for its decimals, as if the token were at fault. The
  admission evidence for the ten is section 5.
- **`ConfigureWeighted` cannot read one's decimals.** On Base, for a stock of the address book and for nothing
  else, it takes them from the book (`STOCK_DECIMALS`, which the node-run suite pins) and builds the Safe's
  `proposeListing` all the same. The factory reads the real decimals when the proposal lands. A key that proposes
  one from the script, on a testnet, needs Foundry v1.8.4 or later: the script's own run calls the factory.
- **The local fork suites leave them out.** `BaseAddresses.fork.t.sol` lists, checks and holds the other twenty-two.
- The keeper and the app are not on Base. Each must read `multiplier()` to value a stock leg.

Moving the pin to a Foundry that runs Base's precompiles was not done: v1.8.6's schedule for Base ends at an upgrade
two behind the one Base runs (Foundry's issue 17950), so a local run would execute older rules than the node's. The
pin is the owner's to move.

## 7. Found on the way

- **`CheckToken` could not run as a script on Base.** A `forge script` run against an OP Stack chain (Foundry 1.8.1,
  seen on Base and on Optimism) fails a state-changing call, or a creation, by an account that holds no ether,
  before it runs; a run against Ethereum or BNB Chain does not, and neither does a test. Two things broke on it:
  the script created a `ConfigureWeighted` to resolve its tokens, a creation by the script contract, which holds no
  ether and may not fund itself, so every `CHECK` on Base reverted before it read a token; and its probes called
  each token as accounts without ether, so every transfer read as failed. `CHECK=base`, written into the commands
  on 2026-11-21, had not been run. The lists moved to a library both scripts carry (`script/ScriptLists.sol`), and
  the check gives an account ether before it calls as it. Mutants N11 and N12.
- A run of the script on Base then got past the transfers and did not end within ten minutes on a public node, for
  a reason not found; the same sixteen reports print from the fork suite in two minutes
  (`testFork_everyBaseTokenPassesTheCheck -vv`).
- **A read of a token's symbol or decimals was unbounded** in gas and in the size of the answer it copied. A token
  that burns the gas it is given, an old token's `throw` or a precompile the EVM cannot execute, took nearly all
  that was left, and a few such reads ended a run. A read now carries 300,000 gas and keeps 256 bytes
  (`ScriptUtils`, mutants N13 and N14).

## 8. What it costs, said to the owner

- **Coinbase is a party to sixteen of Base's thirty-two tokens.** It can block an address and pause each of them,
  and upgrade each of the five coins it issues there; the chain shows one account doing that upgrade.
- **No stock token is a share.** The app must show a stock leg at its multiplier, and whoever names a new index's
  units must read it.
- **The ten stocks rest on a proof run by Base's node**, not on the local fork tests every other token passed, and
  the admission check does not read them.
- **Coinbase offers the stocks outside the United States only.** Who may hold an index of them is the owner's and
  counsel's question.
- **The zap has no route for the stocks** that was tried: they mint in kind, through the builder or through
  `MintRequests`, and a fill needs an executor that holds them.

## 9. What was built

- `script/BaseAddresses.sol`: thirty-two tokens (`COUNT`): the sixteen of 2026-11-21, the six Coinbase Wrapped coins
  and the ten stocks, all sixteen new ones `Custodial`; `stocks()`, `isStock`, `isCoinbaseWrapped`,
  `STOCK_DECIMALS`.
- `script/ScriptLists.sol`, `script/ScriptUtils.sol`, `script/CheckToken.s.sol`, `script/ConfigureWeighted.s.sol`:
  sections 6 and 7.
- Tests: the list against a table written by hand (CR-L08's rule) and its tiers; a stock the script cannot read
  proposed on Base and nowhere else; a precompile the check cannot run sent for review; the bounded read; the
  check's callers funded and its lists resolved without a creation. Mutants N11 to N19, all killed.
- `test/fork/BaseAddresses.fork.t.sol`, 12 of 12 at block 60,529,140: the six coins by symbol and decimals, cbETH
  by the Ethereum token and the bridge it names, each of the twenty-two through `CheckToken` as listable, and an
  index of all twenty-two issued in kind, rebalanced with real transfers and redeemed.
- `test/fork/BaseStocks.fork.t.sol`, 2 of 2 at the same block: section 5.

## 10. Not done

- The roles of each stock token read from the chain: who mints, who blocks, who sets the multiplier, and whether any
  holder is seizable today.
- A stock through the basket builder or `MintRequests`, and any route for one through the zap.
- A run of the node-run suite in CI: it needs `BASE_RPC_URL` and a node that serves `eth_simulateV1`.
- Backed's four wrappers on Base, which wait for the owner's call on the feed rule.
- The keeper on Base and the app: a third stack, the multiplier, and labels for Coinbase as issuer.
- The legal reading of an index that holds Coinbase's stocks.
