# Deployment

How to deploy Xindex, operate it once deployed, and use the Sepolia test deployment.

## Deploy

Nothing below has been run on a mainnet yet; it has run end to end on an anvil fork of Ethereum. Never put a private key
in `.env`. Import the deployer key once into an encrypted keystore, or use a hardware wallet with `--ledger`:

```bash
cast wallet import deployer --interactive
cp .env.example .env   # fill MAINNET_RPC_URL, OWNER (a Safe on mainnet) and GUARDIAN
source .env
```

`DeployWeighted` deploys `WeightedIndexFactory`, which deploys the `WeightedHub` implementation every index is a clone
of, then the zap, the basket builder and `MintRequests` for that factory. It runs once, on Ethereum. Listings follow through the factory's
timelock.

```bash
OWNER=<safe> GUARDIAN=<guardian> forge script script/DeployWeighted.s.sol --rpc-url mainnet --account deployer \
  --sender <deployer> --broadcast --verify
```

Always pass `--sender` with the signing key's address: without it the script's msg.sender is Foundry's default sender,
and on Ethereum the deploy refuses to run (RX-37). Never set a chain-id override (`--chain-id`, `FOUNDRY_CHAIN_ID`,
`chain_id` in `foundry.toml`): the mainnet checks key on chain 1 or on Ethereum's router having code, so an override
cannot switch them off against Ethereum's state (RX-23), but the run should not try. `OWNER` and `GUARDIAN` are required
and must differ. On a mainnet the owner must be a contract that is not an EIP-7702
delegated account, and a Safe must need at least three signatures (`MIN_OWNER_THRESHOLD`, the design's 3-of-5) and have
no enabled module, because a module acts as the Safe without signatures (keep it that way after deployment; the script
cannot see later changes). The guardian must not be the broadcasting key, which must hold no role; when the owner is a
Safe, neither the guardian nor the broadcasting key may be one of its signers, since the guardian is the owner's veto
(SA-06); and neither role may be a market contract: the router, the PoolManager and Pyth everywhere, and on a mainnet
also every token and mint currency in the address book (CR-I37). `PYTH`, `UNIVERSAL_ROUTER`, `USDC` and `USDT`
default to the address book's on chain 1 (`script/MainnetAddresses.sol`), where any other value is rejected, and are
required anywhere else; they are the script's only market addresses, because the hub and factory depend on no Uniswap contract.

An owner that is a contract but not a Safe, such as a timelock, is refused on Ethereum unless `OWNER_IS_NOT_A_SAFE`
names it, set to the owner's own address (A7-08): the script cannot tell who signs for such an owner, so check that
yourself; the run logs its code hash. An acknowledgment left in `.env` from an earlier run names that run's owner and
acknowledges no other, and none lowers a Safe rule.

**Deployment record.** `forge script --broadcast` writes `broadcast/DeployWeighted.s.sol/<chain id>/run-latest.json`:
the git commit, each transaction with its init code, and the addresses. Broadcast from a clean, committed tree so the
recorded commit is the deployed source, add the addresses to the README's Deployments table (on a mainnet with `git add
-f`: `.gitignore` keeps chain-1 records out, because fork rehearsals keep chain id 1), and verify the source on the
explorer (`--verify` needs `ETHERSCAN_API_KEY`). The deploy log ends with the runtime code hashes of the factory, the
`WeightedHub` implementation, the zap, the basket builder and `MintRequests`: record them with the addresses, and
`DeployWeighted.checkDeployment(factory, zap, builder, requests)` re-reads them later (it also refuses a zap, a
builder or a `MintRequests` that does not point at that factory, a builder on another router, and an implementation
reading another Pyth).

**The admission check** comes first: `script/CheckToken.s.sol` is read-only and prints one report per token for the
Safe's signers (transfers simulated on a fork, transfer hooks, admin powers and who holds them, Uniswap depth on
Ethereum, the supply), and refuses a token by the WBT rule. `design/2026-10-05-token-admission-report.md` records its
first run, on 43 coins; every coin of today's list went through it on a fork before its listing.

```bash
CHECK=wide forge script script/CheckToken.s.sol --fork-url <mainnet rpc>
CHECK=<token,...> forge script script/CheckToken.s.sol --fork-url <any evm rpc>
```

**Listings** go through `script/ConfigureWeighted.s.sol`, or the equivalent calls through the Safe: each coin with
the Pyth price id its indexes rebalance at. `V5_WHITELIST=default` is the first four coins of `script/PythIds.sol`
and `V5_WHITELIST=wide` the other 89. Safe mode labels each with its trust tier:

```bash
# owner is a key you hold (testnets and local forks only; a contract owner such as the mainnet Safe cannot sign, and
# propose then reverts with OwnerIsContract: use safe mode)
V5_MODE=propose V5_FACTORY=0x... V5_WHITELIST=<entries> V5_LIST=<tokens to list> \
  V5_USDC=<the deployment's USDC> V5_USDT=<its USDT> \
  forge script script/ConfigureWeighted.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
# owner is a Safe: print the listing proposals as calldata to sign in the Safe app (nothing is broadcast);
# V5_LIST=all on the launch run only, and unset on every later run
V5_MODE=safe V5_FACTORY=0x... V5_WHITELIST=default V5_LIST=all forge script script/ConfigureWeighted.s.sol --rpc-url mainnet
# 2 to 9 days later, from any account: execute every due listing
V5_MODE=execute V5_FACTORY=0x... V5_WHITELIST=default forge script script/ConfigureWeighted.s.sol --rpc-url mainnet --account deployer --sender <any account> --broadcast
```

`V5_MODE` is one of `propose`, `safe`, `execute` and `status`. `V5_WHITELIST` is `default` or `wide` (chain 1 only),
or comma-separated `token:priceId` entries; anything else reverts `MalformedEntry`, and a list
that names a token or a price id twice reverts in every mode (RT-24, V5-M1). Propose and safe mode never propose the
deployment's mint currencies as components: `V5_USDC` and `V5_USDT`, the `USDC` and `USDT` given to `DeployWeighted`,
required off Ethereum; on Ethereum the address book's, where nothing else is accepted (A7-22).

- **Propose and safe** propose a listing for each entry that is not listed and has no live proposal, skipping with the
  reason logged: a token never listed unless `V5_LIST` names it (`V5_LIST=all` for every entry), a delisted token
  unless `V5_RELIST` names it, a token with a different listing pending (cancel it first), and any entry outside the
  policy the script can check (a token with code and 6 to 18 decimals, no mint currency). Safe mode applies the same
  checks, because a Safe batch sends every proposal in one transaction and one the factory refuses takes the rest down
  with it (CR-I38). Nothing on chain records that the guardian cancelled a first listing, so leave `V5_LIST` unset on a
  routine run and a cancelled listing stays cancelled until the operator names it again (RT-06). Safe mode labels each
  proposal with the token's symbol (a symbol that is not an ABI string shows as `?`, RT-25), its tier, its address and
  its price id: check the id against the feed's description before signing.
- **Execute** never proposes. It runs only a due listing whose pending price id is exactly the entry's, and logs why a
  pending one was left: not ready, expired, or a different id.
- **Status** is read-only: for every entry, whether the token is listed, whether the price id in force is the entry's,
  and any pending listing with its window and whether its id is the entry's.

In the Safe app, a safe mode's output becomes one Transaction Builder batch: each calldata line is one transaction to
the factory with value 0, under a label line naming the call and the token. The Safe's threshold of signers signs it,
and one executes it. For a local stack, `anvil --fork-url $MAINNET_RPC_URL` and run the same scripts against
`http://127.0.0.1:8545`; the fork keeps chain id 1, and `.gitignore` keeps those rehearsal records out of git. An ignore
rule does not cover a file git already tracks, so check `git status` after a rehearsal.

## Operations runbook

No bot holds a role in Xindex, so these duties have owners and deadlines. Watch the events that start each clock.

| Duty | Starts with | Deadline | Who | How |
|---|---|---|---|---|
| Veto a wrong listing | `ListingProposed` | before `eta` (2 days) | guardian or owner | check the price id against its feed's description and the decimals against the token; `cancelListing(token)` |
| Execute a listing | its `eta` | `eta + PROPOSAL_WINDOW`, or it expires silently | anyone, owner signers first | `V5_MODE=execute` at the eta; `listingPending(token)` says whether it can still run |
| Keep a Hermes key | before the first rebalance | none, but without one no index rebalances | executors, or one keyed service that hands updates to them | Hermes requires an API key |
| Trigger the rebalance | `earliestRebalance()`: the index's interval after `lastRebalance`, a week after a keep-mask fill | none, but the index drifts from its weights | anyone; the keeper in `keeper/` does it when a fill would pay | `canStartRebalance()`, then `startRebalance(0, priceUpdate)` while every feed publishes; a fill ending in `NothingToRebalance` means the index is on its weights |
| Check each rebalance | `RebalanceStarted` | before the fill | guardian | watch the moving components' Pyth feeds; `cancelRebalance()` on a feed that is wrong or stopped, then a keep mask |
| Watch keep-mask rebalances | `RebalanceStarted` with a non-zero `keepMask` | before `eta` (2 hours) | owner signers | while a guardian replacement is pending, cancel the outgoing guardian's keep-mask proposals (RT-07) |
| Fill auctions | the auction opens at `eta` | `eta + AUCTION_DURATION` | any executor contract | anyone may run the keeper in `keeper/`, which holds no role; competition is what keeps a fill near break-even |
| Fill requests | a `MintRequested` or `RedeemRequested` event | the request's `deadline` | anyone who holds or can issue the shares, or the stablecoin | the keeper in `keeper/` fills at the request's limit when that pays; the surplus over the limit is the filler's |
| Restock the wrapped and real-world legs | the keeper's `restock <coins>` log | before the auction that needs them | the restock service for XRP, ADA, LTC, DOT, AVAX, OP and AERO; the keeper's operator for the rest | the service buys each on its home chain and bridges it into the executor through Wormhole's Token Bridge (`keeper/restock.mjs`); for ATOM, the copies from chains it has no adapter for, Tether Gold and the Ondo stocks, bridge through Wormhole's Portal or acquire the token, and send it to the executor |
| Keep the restock service running | its `gas below its minimum`, `top up its USDT float by hand` or `still pending` log | before the next restock | the treasury's operator | send gas to the treasury's wallet on that chain, top up the BNB Chain USDT float, or cancel the transaction stuck past a fee spike (`keeper/README.md`, Restock) |
| Renew a restock allowance | its `restock allowance ... is spent` log | before that coin's stock runs out | the executor's owner | `setRestockAllowance(<copy>, <amount>)`, or the other allowance the log names; what arrives through the bridge earns the keeper stock allowance only within it (RS-1) |
| Rebalance around a frozen component | a paused or blacklisting component, or a stopped feed | each auction | guardian | `cancelRebalance()`, then `startRebalance(keepMask, priceUpdate)` |
| Restart after an unfilled auction | `eta + AUCTION_DURATION` passed with no `Rebalanced` | anyone after `REBALANCE_DELAY` more | guardian first, then anyone | `canStartRebalance()`, then `startRebalance(0, priceUpdate)` while every feed publishes |
| Re-check venue depth per leg | monthly, and before a large mint or burn | none | app | V3 and V4 depth move independently; the route is the app's choice |
| Watch guardian changes | `GuardianProposed` | `eta` (7 days) | owner signers, guardian, app | a security alert: once executed, the new guardian's veto replaces the old one. `guardianChangePending()` says whether it is still executable |
| Hand over factory ownership | `OwnershipTransferStarted` | none: it takes effect as soon as the new owner accepts | owner signers, then the new owner | the one admin change with no delay and no veto; announce it first, and the new owner has to meet the rules the deploy script checks |

## Testnet (Sepolia)

**v5 is deployed on Sepolia** from commit `07aeae1`, the build before the RX-3 fix: its hub's
`startRebalance(keepMask)` takes no price update and its auctions run 24 hours, while `abi/` and `src/` are the fixed
build's. Its owner is a 2-of-3 test Safe and its guardian an externally owned account (a mainnet owner needs at
least 3 signatures). The four listings (tWBTC, WETH, tLINK, tUNI) are proposed and can be executed by anyone from
2026-10-28 14:01 UTC until 2026-11-04 14:01 UTC; no index can be created before then. v3 also runs there, deployed from
`4b4dbe4` (tag `v3.0.0`); nothing on `main` drives it.

Sepolia runs Glamsterdam (EIP-8037): creating contracts and storage costs two to four times what
Foundry's local simulation charges, so `forge script` broadcasts need `--gas-estimate-multiplier 900` (the factory
alone took 63.6M gas), while `cast send` takes the node's own estimate.

`script/testnet/SetupTestMarket.s.sol` deploys stand-ins for USDC, WBTC, LINK and UNI as `FaucetToken`s, where any
account can `drip()` a small amount once a day, each with a Uniswap V3 WETH pool at a mainnet-like price so the zap has
a V3 route to swap through. Nothing in Xindex reads those pools' prices. `create` logs the `V5_WHITELIST` entries for
`ConfigureWeighted`: tWBTC, WETH, tLINK and tUNI, each under its mainnet counterpart's Pyth price id, since Pyth's ids
are the same on every chain. Faucet tokens have no value and their supply grows with every drip, which nothing reads.

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
| WeightedIndexFactory (v5, blocks 11,998,381 to 11,998,385 with the next four) | `0x787139b915753F0CfFfa14708D1e665dCf5AA0bA` |
| WeightedHub implementation | `0x3ae717ffeE17D3FAd861447703F31011eB8DC609` |
| WeightedMath | `0xd22BDeF312560309686483F4983966d810f3FA85` |
| IndexZap | `0x1CC5cC8bE9553cFe952a4A330071C20cE96d9924` |
| BasketBuilder | `0xa4AB1233D1Eb2ddcA77C27579A8cB41156452E13` |
| MintRequests | `0x5b092e8A8ab29A12e2D91bE96C307759B2a12b81` |
| Owner (2-of-3 Safe) | `0x2Fb4b72C689E21D0d33Bd9D66DbEAdC60b6b0CA2` |
| Guardian | `0x8cef9aAa300aA0A1EA5A0D8593EFc9ADED7B55a1` |
| Pyth | `0xDd24F84d36BF92C65F92307595335bdFab5Bbd21` |
| tUSDC (FaucetToken, 6 decimals) | `0xD1aF4223B129071f7a1a27ED367E4D72cd7cF8D3` |
| tUSDT (FaucetToken, 6 decimals; no Uniswap pool yet, so only limit orders use it) | `0x33780f7352fA32D4736449516066DF56C7DcF1c1` |
| tWBTC / tLINK / tUNI (FaucetToken) | `0x656C9999ad6092F813996C30a2dbe89Ff2F670A9` / `0xC02F993785FC45cF48bF61c24DCbB11F9085A4E4` / `0xc34fE6c23897ae506368cF3acb0Db96d6D63Bf85` |

```bash
export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
DEPLOYER=$(cast wallet address --account sepolia-deployer)

# 1. tokens and priced pools, then liquidity in a later block: 0.3 WETH in the tUSDC pool, 0.1 in each other
MARKET_MODE=create forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast
MARKET_MODE=seed MARKET_TOKENS=<logged by create> forge script script/testnet/SetupTestMarket.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast

# 2. the factory (which deploys the WeightedHub implementation), the zap, the basket builder and MintRequests; USDT is
#    any second 6-decimal test token, a FaucetToken for instance (tUSDT above); off a mainnet PYTH is required
OWNER=<Safe> GUARDIAN=<guardian> PYTH=<Pyth's Sepolia contract> UNIVERSAL_ROUTER=0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b \
  USDC=<tUSDC logged by create> USDT=<a second test stablecoin> \
  forge script script/DeployWeighted.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast \
  --gas-estimate-multiplier 900

# 3. print the listing proposals and sign them as one batch in the Safe app
V5_MODE=safe V5_FACTORY=<factory> V5_WHITELIST=<logged by create> V5_LIST=all \
  V5_USDC=<tUSDC logged by create> V5_USDT=<the second test stablecoin> \
  forge script script/ConfigureWeighted.s.sol --rpc-url sepolia

# 4. 2 to 9 days later, from any account
V5_MODE=execute V5_FACTORY=<factory> V5_WHITELIST=<same> forge script script/ConfigureWeighted.s.sol --rpc-url sepolia --account sepolia-deployer --sender $DEPLOYER --broadcast --gas-estimate-multiplier 900
```

Add `--verify` with `ETHERSCAN_API_KEY` set to verify the contracts, so testers can call `drip()` from Etherscan.
`USD_POOL_WETH` and `TOKEN_POOL_WETH` (in wei) change the liquidity `seed` adds. Timing is mainnet's: listings take 2
days, and a rebalance can start an index's interval, at least 7 days, after its creation, followed by 2 hours of notice and a 4-hour auction
whose fill needs a signed Pyth update, as on mainnet. The test pools are shallow and nobody arbitrages them, so zap
prices on this market say nothing about mainnet. `test/fork/WeightedExecutorV3.sol` fills auctions through
SwapRouter02; it is a test fixture without slippage limits, so never fund it on mainnet.
