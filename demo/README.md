# Xindex hackathon demonstration (testnets only)

One index token on Sepolia holding demo WETH on Ethereum, SOL in the vault program on Solana devnet, and HYPE in the EVM
vault on HyperEVM testnet. It mints with coins deposited on each chain and redeems with each coin paid on its own chain,
within the 4%-a-day speed limit. No contract reads a price. The plan is `../design/2026-09-30-hackathon-plan.md`.

> **Stubs, not proofs.** Messages between the chains are vouched for by relayer keys, not by the proof systems of the
> design (P1 and P2, and each chain's state proof), which are not built yet:
> - `src/StubEventVerifier.sol` stands in for P1 and P2 on HyperEVM;
> - `../solana/programs/stub-verifier` stands in for them on Solana;
> - `src/StubStateVerifier.sol` stands in for each vault chain's state verifier on Sepolia.
>
> Whoever holds the relayer keys can move the demo's coins. Everything else is the real code: the factory, the hub and
> its two modules, both vaults. Nothing in this folder may be deployed to a mainnet.

## What is here

| Path | What |
|---|---|
| `src/` | the three stubs and `DemoToken`, a freely minted demo WETH |
| `test/DemoFlow.t.sol` | the whole flow on one EVM, signed as the relayer signs |
| `script/Demo.s.sol` | the testnet deployment, one step per timelock |
| `relayer/` | the relayer and the demo's command line (TypeScript) |
| `deployments/` | what each step deployed, read by the next step and the relayer |

## The calendar

The factory's timelocks are real: a chain waits 2 days before it is registered, and a coin's listing 2 days after that.
So the index exists 4 days after the first deployment, and a mint takes its order window plus the 24-hour lock. Start
early.

| Day | Step | Chain |
|---|---|---|
| 0 | `npm run cli -- solana-vault` (prints `SOLANA_VAULT`); deploy the Solana programs | Solana devnet |
| 0 | `forge script script/Demo.s.sol --sig "sepolia0()"` | Sepolia |
| 0 | `forge script script/Demo.s.sol --sig "hyperevm0()"` | HyperEVM testnet |
| 0 | `forge script script/Demo.s.sol --sig "sepolia0b()"`; `npm run cli -- solana-init` | Sepolia, Solana |
| 2 to 9 | `forge script script/Demo.s.sol --sig "sepolia2()"` | Sepolia |
| 4 to 11 | `forge script script/Demo.s.sol --sig "sepolia4()"`; `npm run cli -- register` | all three |
| 4 on | `npm run cli -- relay` in its own terminal, left running | all three |
| 4 on | `open 10 30`, `deposit <order>`, after 30 minutes `settle <order>` | all three |
| 5 on | `claim <order>`, then `redeem 4 <HyperEVM address> <Solana address>` | all three |

Each `forge script` also takes `--rpc-url <chain> --broadcast` and your wallet (`--account <keystore>` or `--browser`).
The broadcaster is the factory's owner on the testnet.

## Setting up

```bash
cd demo
forge build                           # the relayer reads its ABIs from out/
cd relayer && npm install && cp .env.example .env    # then fill .env in
```

The `forge script` steps read these variables:

| Variable | Meaning |
|---|---|
| `GUARDIAN` | the factory's guardian on Sepolia |
| `STATE_RELAYER` | the address of `STATE_RELAYER_KEY` |
| `SOLANA_VAULT` | printed by `solana-vault` |
| `RELAYER1`, `RELAYER2` | the addresses of `RELAYER1_KEY` and `RELAYER2_KEY` |
| `FREEZER`, `RECOVERY` | the HyperEVM vault's freeze key and emergency multisig (plain addresses on a testnet) |

Solana, from `../solana` (see `../solana/README.md`):

```bash
anchor build --no-idl && cargo build-sbf --manifest-path programs/stub-verifier/Cargo.toml
solana program deploy target/deploy/xindex_vault.so --program-id target/deploy/xindex_vault-keypair.json --url devnet
solana program deploy target/deploy/stub_verifier.so --program-id p1.json --url devnet   # P1
solana program deploy target/deploy/stub_verifier.so --program-id p2.json --url devnet   # P2
```

**HyperEVM.** The vault is about 23KB, larger than a small HyperEVM block takes, so it deploys in a big block. The
deployer must first opt into big blocks, which Hyperliquid does with the `evmUserModify` action (`usingBigBlocks`).
Check Hyperliquid's documentation for the current way.

## The relayer's commands

`npm run cli -- <command>` in `relayer/`:

| Command | What it does |
|---|---|
| `solana-vault` | prints the Solana vault's 32-byte id for `sepolia0` |
| `solana-init` | sets both Solana stubs' relayer keys and initializes the vault (from its upgrade authority) |
| `register` | registers the index on both vaults with its CREATE2 salt |
| `relay [--once]` | carries every message the factory and its indexes emit, from Sepolia's finalized head, to its vault; keeps the HyperEVM vault's checkpoint current |
| `open <shares> <minutes>` | mints demo WETH, approves, and opens an order with its deposit deadline |
| `deposit <order>` | deposits the order's HYPE and SOL from the demo wallets |
| `settle <order>` | after the deadline: reads both intakes, has the state relayer sign them, settles the order |
| `claim <order>` | after the 24-hour lock: mints the shares; the relayer carries the settle messages |
| `redeem <shares> <hyperevm> <solana>` | WETH at once; HYPE and SOL burned toward the two recipients |
| `status` | the deployment and the Solana addresses |

A Solana recipient must already exist: a payout below the rent-exempt minimum to a new account fails, and the burn
waits.

## Rehearsed

The whole flow was rehearsed on 30 September against two local anvil chains (as Sepolia and HyperEVM, the first
started four days back so its timelocks could be skipped) and a local Solana validator running the built programs:
deployment, registration, an order, deposits on both chains, settlement on both stub state proofs, the claim, delivery
of the settle messages, a redemption, and the burns paid on both chains.
