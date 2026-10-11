# One index on Ethereum: a hundred coins of the top 300, the missing ones as Wormhole-wrapped legs

**Status:** the owner's decision of 2026-10-10. It supersedes the second half of the two-chain decision of 2026-10-07
(`design/2026-10-07-two-chain-deployment.md`): Xindex ships as one deployment, on Ethereum, and the BNB Chain
deployment is shelved. Its scripts, address book and fork suite stay in the tree; no deploy there is planned.

## 1. The decision

The product is one ERC-20 index that holds up to `MAX_COMPONENTS` (100) coins of the top 300 by market cap, on
Ethereum, in kind, at fixed weights, rebalanced to them at Pyth prices through the permissionless auction. The
contracts are the ones in `src/` today: `WeightedIndexFactory`, `WeightedHub`, `IndexZap`, `MintRequests`. Nothing
in them changes for this decision. No vault, no proof, no bridge of our own, and nothing crosses a chain inside a
contract: the app and the fillers bridge, as they already do with THORChain.

**Everything happens on the website** (the owner's rule of 2026-10-11). A buyer with USDC never touches a bridge: the
zap swaps for a copy where Ethereum has a pool for it, and otherwise `MintRequests` escrows the USDC and a filler
delivers the basket, wrapped copies included, and bridges on its own account. A seller gets USDC the same two ways.
A user who brings a coin from its home chain, or who wants the coin itself back after a burn, bridges through
Wormhole's token bridge from inside the app, with Wormhole Connect embedded, signing from their own wallet; that
transaction goes to Wormhole's contracts, never to ours, and the user never leaves the site.

The listing universe is every coin that meets three conditions:
1. Pyth publishes a price feed for it. The settlement cannot price a coin without one.
2. It exists on Ethereum as an ERC-20: the issuer's own contract, the issuer's own bridged copy (GRAM, CRO, ICP,
   RENDER, CAKE, ZRO, INJ today), or a copy wrapped by Wormhole's token bridge (Portal) from the chain that has it.
3. It passes `CheckToken` (`CHECK=wide`), the admission check of `design/2026-10-05-token-admission-report.md`.

Wormhole is the one bridge accepted for wrapping, for three reasons. Its token bridge is permissionless: anyone
attests a token on its home chain and the bridge deploys the wrapped ERC-20 on Ethereum, so no listing waits on a
third party. Its guardians (13 of 19) already sign every Pyth price update the hub settles on, so it adds no party
to the trust set. And its SOL copy is already listed (`MainnetAddresses.SOL`, the owner's call of 2026-10-10). A
wrapped copy is listed at its coin's Pyth feed, as Binance-Peg copies are, in the tier `Bridged`; one wrapped from a
Binance-Peg BEP-20 carries Binance's custody too and is labelled Custodial as well. The app names Wormhole on every
wrapped leg.

The listing rules of 2026-10-06 and 2026-10-10 stand: no exchange tokens (OKB, BGB, GT; HTX falls under the same
rule), no NIGHT, no memecoins beyond SHIB, PEPE and DOGE, the WBT rule waived only where the owner has said so.
Stablecoins, gold and tokenized stocks do not count toward the hundred; Tether Gold and Ondo's stocks stay listed on
their own terms.

## 2. The count on 2026-10-10

CoinGecko's top 300 by market cap, read on 2026-10-10, less stablecoins, gold, tokenized stocks, and wrapped or
staked derivatives, less the coins the listing rules refuse, keeping only coins with a Pyth crypto feed:

| How Ethereum holds it | Coins |
|---|---|
| The issuer's own contract or own bridged copy on Ethereum | 71 |
| BNB Chain only, wrapped by Wormhole: XRP, DOGE, ADA, LTC, BCH, ZEC, DOT, XTZ, FIL as Binance-Peg copies; TRX, NEAR, AVAX, ASTER, ATOM, STABLE, TWT, SOL | 17 |
| Another chain Wormhole serves (Solana, Sui, Aptos, Base, Arbitrum, Optimism, Sei, Algorand, Kaia, Monad, Sonic): SUI, APT, SEI, ALGO, KAIA, MON, S, OP, JUP, RAY, PYTH, JTO, HNT, WAL and 17 more | 31 |
| Reachable in all | 119 |
| On no chain Wormhole serves: XMR, XLM, HBAR, TAO, KAS, VET, TIA, ETC and 26 more | 34 |
| On Ethereum or a Wormhole chain but without a Pyth feed | 47 |

The 119 are candidates, not listings: none has passed `CheckToken` yet, and some will fail it. The margin of 19
over the hundred is what absorbs that. The same universe held on BNB Chain instead would have wrapped 71 legs and
held ETH as a Binance-Peg copy, which is why Ethereum is the home chain.

## 2a. What landed on 2026-10-10

The 119 candidates were taken through the steps of section 5 the same day, as far as the chain allows without a
transaction:

- **Already on Ethereum.** 70 of the 71 answered their symbol and decimals on chain (HTX was dropped under the
  exchange-token rule). Of the 40 not yet listed, `CheckToken` on a fork at block 26,163,788 refused three: LDO (the
  WBT rule: its MiniMe controller destroys any balance, as LEO's does), ZAMA (ERC-1363 transfer callbacks) and NEAR's
  Rainbow bridge copy (24 decimals). Four are left for the owner's call: Binance's 2017 BNB ERC-20, which only
  Binance redeems and whose Uniswap depth is a few coins; U (United Stables), which may be a stablecoin; EDGE and
  BEAM, whose Pyth feeds ("EDGEX", "BEAM") may name other coins. LEO, WLFI and GRAM stay out under the earlier calls.
  The other 31 are listed: FF, BTT, GNO, OHM, GRT, SYRUP, ENS, JASMY, COMP, EIGEN, AXS, SAND, BAT, CVX, MANA, IMX,
  FLUID, CHZ, ZK, APE, SENT, SNX, 1INCH, GLM, ATH, H, PLUME, GALA, RLB, W, RSR.
- **Wormhole copies that already exist.** The bridge's `wrappedAsset(chain, source)` answered a copy for 15 of the
  48: XRP, DOGE, ADA, LTC, DOT and ATOM from their Binance-Peg BEP-20s; AVAX (as WAVAX), JUP, ALGO, AERO, APT, PYTH,
  OP and RAY from their home chains; and a second SOL from BNB Chain's Binance-Peg SOL, which is not used, since
  Solana's own is listed. All 14 passed `CheckToken`. 13 are listed; RAY's copy answers an empty symbol and name, which
  a fresh attestation on Solana (the bridge's `updateWrapped`) corrects, and it waits for that.
- **The list** is 93: the 49 of before, the 31 and the 13. Less Tether Gold and the 17 Ondo stocks, which do not count
  toward the hundred, that is 75 coins of the top 300 an index can hold today.
- **To attest.** 34 copies do not exist yet. Each needs one transaction on its home chain and one on Ethereum, by
  anyone; they are the owner's to send, since no key is held here. Attested, checked and listed, they take the
  universe to about 109 coins.

| Coin | Home chain (Wormhole id) | Source token | |
|---|---|---|---|
| BNB | BNB Chain (4) | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` (WBNB) | |
| TRX | BNB Chain (4) | `0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3` | BTTC's bridge |
| ZEC | BNB Chain (4) | `0x1ba42e5193dfa8b03d15dd1b86a3113bbbef8eeb` | Binance-Peg |
| BCH | BNB Chain (4) | `0x8ff795a6f4d97e7887c79bea79aba5cc76444adf` | Binance-Peg |
| FIL | BNB Chain (4) | `0x0d8ce2a99bb6e3b7db580ed848240e4a0f9ae153` | Binance-Peg |
| XTZ | BNB Chain (4) | `0x16939ef78684453bfdfb47825f8a5f714f12623a` | Binance-Peg |
| ASTER | BNB Chain (4) | `0x000ae314e2a2172a039b26378814c252734f556a` | |
| STABLE | BNB Chain (4) | `0x011ebe7d75e2c9d1e0bd0be0bef5c36f0a90075f` | |
| TWT | BNB Chain (4) | `0x4b0f1812e5df2a09796481ff14017e6005508003` | |
| SUI | Sui (21) | `0x2::sui::SUI` | |
| WAL | Sui (21) | `0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL` | |
| NEAR | NEAR (15) | `wrap.near` | |
| SEI | Sei (32) | `usei` | |
| KAIA | Kaia (13) | `0x19Aac5f612f524B754CA7e7c41cbFa2E981A4432` (WKAIA) | |
| MON | Monad (48) | `0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701` (WMON) | |
| S | Sonic (52) | `0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38` (wS) | |
| RAIN | Arbitrum (23) | `0x25118290e6a5f4139381d072181157035864099d` | |
| VVV | Base (30) | `0xacfe6019ed1a7dc6f7b508c02d1b04ec88cc21bf` | |
| ZEN | Base (30) | `0xf43eb8de897fbc7f2502483b2bef7bb9ea179229` | |
| GRASS | Solana (1) | `Grass7B4RdKfBCjTKgSqnXkqjwiGvQyFbuSCUJr3XXjs` | |
| BP | Solana (1) | `BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy` | |
| JTO | Solana (1) | `jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL` | |
| CARDS | Solana (1) | `CARDSccUMFKoPRZxt5vt3ksUbxEFEcnZ3H2pd3dKxYjp` | |
| MET | Solana (1) | `METvsvVRapdj9cFLzq4Tr43xK4tAjQfwX76z3n6mWQL` | |
| USX | Solana (1) | `6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG` | |
| KMNO | Solana (1) | `KMNo3nJsBXfcpJTVhZcXLW7RmTwTt4GVFE7suUBo9sS` | |
| 2Z | Solana (1) | `J6pQQ3FAcJQeWPPGppWRb4nM8jU3wLyYbRrLh7feMfvd` | |
| ORCA | Solana (1) | `orcaEKTdK7LKz57vaAYr9QeNsVEPfiu6QeMU1kektZE` | |
| META | Solana (1) | `METAwkXcqyXKy1AtsSgJ8JiUHwGCafnZL38n3vYmeta` | |
| CASH | Solana (1) | `CASHx9KJUStyftLFWGvEVf59SGeG9sh5FfcnZMVPCASH` | |
| SKR | Solana (1) | `SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3` | |
| DBR | Solana (1) | `DBRiDgJAMsM95moTzJs7M9LnkGErpbv9v6CUR1DXnUu5` | |
| STONK | Solana (1) | `6GmAFSYs4gk3FDao5FzzySQpPZaWsa4rUJHacpMpUNgx` | |
| HNT | Solana (1) | `hntyVP6YFm1Hg25TN9WGLqM12b8TQmcknKrdu1oxWux` | |

How an attestation goes, in order. First, on the home chain, call the token bridge's `attestToken(token, nonce)`
(on BNB Chain the bridge is `0xB6F6D86a8f9879A9c87f643768d9efc38c1Da6E7`; on Solana, Sui and Aptos, Portal's own
interface does the same). Second, wait for the guardians to sign the attestation, which Wormholescan shows as a VAA.
Third, on Ethereum, call `createWrapped(vaa)` on `MainnetAddresses.WORMHOLE_TOKEN_BRIDGE`; the copy then answers at
`wrappedAsset(chain, source)`. Fourth, run `CheckToken` on the copy, add it to the address book and to `PythIds` with
its coin's feed, and extend `testFork_theWormholeCopiesAreTheBridges` with its source. The Binance-Peg sources are
listed `Custodial`, the rest `Bridged`. Nothing here needs a key of ours beyond gas.

**Fork results, 2026-10-11** (`test/fork/WeightedHub.fork.t.sol` on Alchemy's archive node, blocks 26,167,826 and
26,168,132): the 92 coins forge-std's `deal` can fund issue, rebalance with real transfers of every token and redeem
to the last unit in one index, and the fill of 92 legs costs 14.9M gas with Pyth's parse mocked, under EIP-7825's
16.78M. 45 coins trade through the zap within 2% slippage on $1,000, and an index of them mints through the zap and
rebalances through a Uniswap-routed executor. SNX is the one coin out of the first test: its balances live in its
`TokenState` contract, which forge-std's slot finder cannot reach; the hub holds it like any other ERC-20. Two earlier
runs of that test ran for one and two hours before the network dropped, both inside RSR: forge-std's `deal` probes
every slot `balanceOf` reads with `type(uint256).max`, one of RSR's is the length of its `origins` set, and its
`balanceOf` then walks that many empty slots, one fork read each. The suite now caps every `deal` at 32M gas
(`DEAL_GAS`), which ends the walk after about 10,000 reads.

## 3. The trust, stated for the app

| Party | What it can do | Reach |
|---|---|---|
| The Xindex contracts | A bug | Everything. Reviewed internally twice; the external audit is before any mainnet. |
| Wormhole's guardians, 13 of 19 | Forge a bridge message: mint unbacked wrapped tokens, or upgrade every wrapped token's code at once, with no timelock | Every wrapped leg at once. Also a forged Pyth price, which the turnover cap bounds to 20% of a leg per fill, once a week, and the guardian can cancel. |
| Binance | Stop honouring a Binance-Peg coin | That leg. Nine coins carry Binance and Wormhole both. |
| BitGo, Ondo, Tether, every other issuer | Pause, blacklist or burn its token | That leg. |
| Pyth's publishers | A wrong price | Bounded as above. |
| The owner Safe and the guardian | Nothing over funds; the guardian can stall rebalances | Drift, no loss. |
| Executors, anyone | Nothing beyond the capped auction | Bounded by design. |

Xindex v5 already trusted Wormhole's guardians through Pyth, bounded to the turnover cap. This decision widens that
one party's reach from a capped haircut to the whole of each wrapped leg. An index whose value sits mostly in the
first row of section 2 carries little of it; an equal-weighted hundred carries about half its value on the
guardians. The app shows a creator the wrapped share of value before the index is created, and shows every holder
the same figure.

The wrapped copies have no DEX liquidity. Redeem always works and pays the wrapped tokens; turning them into the
coin needs Wormhole live. A Wormhole halt locks that value, it does not take it.

## 4. What it costs

- Mint. A hundred-leg basket cannot be bought through `IndexZap` in one transaction: EIP-7825's 16.78M gas cap stops
  the zap near 35 legs. A hundred-coin index is minted in kind, or through `MintRequests` by a filler who assembles
  the basket. A multi-transaction zap that accumulates legs before issuing is a later feature, in a new zap.
- Fills. A rebalance executor must hold the wrapped legs it delivers, bridged ahead of the auction; swaps for a
  hundred legs do not fit a transaction. Nothing in the hub changes; this is the executor's operation.
- Attestations. Each wrapped ERC-20 that does not exist yet is created once through Portal: one transaction on the
  home chain, one on Ethereum. Permissionless and reversible by nobody.
- Gas. A hundred components fit every hub path in one transaction (`test_aHundredComponentsFitOneTransaction`, about
  3.7M for redeem). The settlement's parse of a hundred Pyth feeds through the real contract is measured on the fork
  before mainnet (section 5).

## 5. The steps to mainnet, in order

1. Attest the 34 missing wrapped tokens on Portal (the table of section 2a) and record every wrapped address, with
   its home-chain source, in `script/MainnetAddresses.sol`. Done for the 13 copies that already existed.
2. Run `CHECK=wide` on every candidate on a fork; list the ones that pass in `script/PythIds.sol` with its Pyth id,
   decimals and tier; `testFork_everyWideTokenPassesTheCheck`, `test_CRL08_theListsAreTheReleaseRecord` and
   `testFork_theWormholeCopiesAreTheBridges` pin the result. Done for everything on Ethereum on 2026-10-10: the list
   is 93.
3. Measure a hundred-feed settlement against Pyth's real contract on a real signed update (a Hermes key), which the
   v5 spec's section 8 already requires.
4. Pyth's parameter replay (`design/2026-10-05-custom-weights.md`, section 8).
5. The external audit.
6. The owner Safe (3 of 5) and the guardian on Ethereum; `DeployWeighted`, then `ConfigureWeighted` over the list.
7. The app side, in the web app's repository: Wormhole Connect embedded for bridging in and out, the wrapped share
   and the Wormhole and Custodial labels on every index, and a filler for `MintRequests`. No filler exists:
   `keeper/` is a draft that fills rebalance auctions only. Until the owner runs one or market makers fill, a buyer
   with only USDC waits for a fill or cancels.

## 6. What does not change

Every design rule of `AGENTS.md` stands: in-kind backing, the invariant, one place reads a price, the turnover cap,
no admin power over funds, no rebalancing key, the zap stateless, `MintRequests` holding only open escrows, the
admission rule and the listing flow. No fee. Fixed constituents and weights. The retirement records stand: Stage B's
ids stay retired, and this decision restores none of its code.
