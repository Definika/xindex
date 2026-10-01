# Xindex hackathon demonstration (testnets only)

One index token on Sepolia holding demo WETH on Ethereum, SOL in the vault program on Solana devnet, and HYPE in the EVM
vault on HyperEVM testnet. It mints with coins deposited on each chain and redeems with each coin paid on its own chain,
within the 4%-a-day speed limit. No contract reads a price. The plan is `../design/2026-09-30-hackathon-plan.md`.

> **Stubs, not proofs.** In the index of WETH, SOL and HYPE, messages between the chains are vouched for by relayer
> keys, not by the proof systems of the design (P1 and P2, and each chain's state proof):
> - `src/StubEventVerifier.sol` stands in for P1 and P2 on HyperEVM;
> - `../solana/programs/stub-verifier` stands in for them on Solana;
> - `src/StubStateVerifier.sol` stands in for each vault chain's state verifier on Sepolia.
>
> P1 and P2 have since been built (`../proofs`, and P1 on Solana as `../solana/programs/ethereum-verifier`), but this
> index does not use them, and neither of its vault chains has a state verifier: HyperEVM's headers carry no state root,
> and Solana's waits on Alpenglow's mainnet launch (Stage B spec, section 8). Whoever holds the relayer keys can move
> the demo's coins. Everything else is the real code: the factory, the hub and its two modules, both vaults. Nothing in
> this folder may be deployed to a mainnet.
>
> **A second index, of WETH and BNB, runs on real proofs** (see "BNB testnet: real proofs" below): BNB testnet's state
> is proven on Sepolia from its own validators' votes, and Sepolia's messages are proven on BNB testnet by P1. Only P2
> is a stub there: it has since been built (`../proofs/p2`, `RiscZeroFinalityVerifier`), and the demo does not deploy it
> yet.

## What is here

| Path | What |
|---|---|
| `src/` | the two Solidity stubs and `DemoToken`, a freely minted demo WETH |
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
| 4 to 11 | `forge script script/Demo.s.sol --sig "sepolia4()"` from `SENDER_KEY`'s account; `npm run cli -- register` | all three |
| 4 on | `npm run cli -- relay` in its own terminal, left running | all three |
| 4 on | `open 10 30`, `deposit <order>`, after 30 minutes `settle <order>` | all three |
| 5 on | `claim <order>`, then `redeem 4 <HyperEVM address> <Solana address>` | all three |

Each `forge script` also takes `--rpc-url <chain> --broadcast` and your wallet (`--account <keystore>` or `--browser`).
The broadcaster is the factory's owner on the testnet, except for `sepolia4`, which only executes and creates. Broadcast
that one from the account of `SENDER_KEY`, imported as a keystore (`cast wallet import sender --private-key ...`),
because only an index's creator may seed it and `open` sends the first order from `SENDER_KEY`.

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

Then `npm run cli -- solana-init` sets each stub's relayer key from the deployer, which only a stub's upgrade authority
may do. The vault takes only verifiers nobody can upgrade, so `solana-init` then stops and prints the command that makes
each stub final (`solana program set-upgrade-authority <stub> --final`). Run both, then `solana-init` again to
initialize the vault.

**HyperEVM.** The vault is about 24KB, larger than a small HyperEVM block takes, so it deploys in a big block. The
deployer must first opt into big blocks, which Hyperliquid does with the `evmUserModify` action (`usingBigBlocks`).
Check Hyperliquid's documentation for the current way.

## The relayer's commands

`npm run cli -- <command>` in `relayer/`:

| Command | What it does |
|---|---|
| `solana-vault` | prints the Solana vault's 32-byte id for `sepolia0` |
| `solana-init` | sets both Solana stubs' relayer keys; once they are final, initializes the vault (from its upgrade authority) |
| `register` | registers the index on both vaults with its CREATE2 salt |
| `relay [--once]` | carries every message the factory and its indexes emit, from Sepolia's finalized head, to its vault; advances the HyperEVM vault's checkpoint first where a message needs it, and hourly |
| `open <shares> <minutes>` | mints demo WETH, approves, and opens an order with its deposit deadline |
| `deposit <order>` | deposits the order's HYPE and SOL from the demo wallets |
| `settle <order>` | after the deadline: reads both intakes, has the state relayer sign them, settles the order |
| `claim <order>` | after the 24-hour lock: mints the shares; the relayer carries the settle messages |
| `redeem <shares> <hyperevm> <solana>` | WETH at once; HYPE and SOL burned toward the two recipients |
| `checkpoint` | advances the HyperEVM vault's checkpoint to Sepolia's finalized head, as `relay` does hourly |
| `balances [holder]` | the holder's shares, the index's supply, and its balance and payouts in each vault |
| `status` | the deployment and the Solana addresses |

A Solana recipient must already exist: a payout below the rent-exempt minimum to a new account fails, and the burn
waits.

## BNB testnet: real proofs

The index of WETH and BNB uses the real verifiers both ways:
- **BNB testnet → Sepolia.** `BnbStateVerifier` follows BNB testnet's validator sets from their own finality votes
  (BLS, on Sepolia's EIP-2537 precompiles) and proves the vault's intake from its storage. Nothing is signed by a
  relayer: the relayer only carries headers, votes and `eth_getProof` nodes.
- **Sepolia → BNB testnet.** P1 (`../proofs`, built with `--features sepolia`) proves a finalized Sepolia checkpoint
  and the execution blocks since the last one; `EthereumFinalityVerifier` checks it through SP1's Groth16 verifier, and
  each message by its block's place under P1's headers root and its receipt's Merkle-Patricia proof. P2's place is
  taken by the stub, signed by `RELAYER2_KEY`.

Proving P1 needs `SP1_PROVER=network` with a funded `NETWORK_PRIVATE_KEY`, or `SP1_PROVER=cuda` on an NVIDIA GPU; this
Mac's CPU is refused. A real Sepolia input of 1 October (1,997 validators, 64 execution blocks) costs 358 million
prover gas, against mainnet's 36.6 billion. P1 must move within a day of its anchor, so `relay` proves hourly.

| Day | Step | Chain |
|---|---|---|
| 0 | build `../proofs` for Sepolia; `npm run cli -- p1-anchor` (keeps P1's first anchor, prints `P1_KEY`, `P1_ANCHOR`, `P1_EPOCH`) | Sepolia |
| 0, after `sepolia0` | `forge script script/Demo.s.sol --sig "bnb0()"` with those three, `RELAYER2`, `FREEZER`, `RECOVERY` | BNB testnet |
| 0 | `npm run cli -- bnb-epoch`, then `forge script script/Demo.s.sol --sig "sepoliaBnb0()"`, then `npm run cli -- relay` left running from here on: `BnbStateVerifier` stops for good a day behind | Sepolia |
| 2 to 9, after `sepolia2` | `forge script script/Demo.s.sol --sig "sepoliaBnb2()"` | Sepolia |
| 4 to 11 | `forge script script/Demo.s.sol --sig "sepoliaBnb4()"` from `SENDER_KEY`'s account; `npm run cli -- register --bnb` | Sepolia, BNB testnet |
| 4 on | `open 10 30 --bnb`, `deposit <order> --bnb`, after 30 minutes `settle <order> --bnb` | Sepolia, BNB testnet |
| 5 on | `claim <order> --bnb`, then `redeem 4 <BNB testnet address> --bnb` | Sepolia, BNB testnet |

`SENDER_KEY`'s account needs tBNB on BNB testnet for the deposit and the relayer's transactions there. The relayer's
other commands for this path: `bnb-follow`, `p1-update`, `bnb-checkpoint`, and `balances --bnb`.

## Rehearsed

The whole flow was rehearsed on 30 September against two local anvil chains (as Sepolia and HyperEVM, the first
started four days back so its timelocks could be skipped) and a local Solana validator running the built programs:
deployment, registration, an order, deposits on both chains, settlement on both stub state proofs, the claim, delivery
of the settle messages, a redemption, and the burns paid on both chains.

The BNB path's two proofs were rehearsed on 1 October with real chain data and the real contracts, spending nothing:
- **BNB testnet → Sepolia**, on a local fork of Sepolia: the relayer's `bnb-epoch` built `BnbStateVerifier` from epoch
  134,285,000 (9 validators), `follow` recorded epoch 134,286,000 from BNB testnet's own votes, and a storage proof at
  block 134,286,038 read testnet WBNB's name through `verifySlots`.
- **Sepolia → BNB testnet**, on a local chain with BNB testnet's id: `EthereumFinalityVerifier` took the public values of
  a real Sepolia input (anchor epoch 351,927 to 351,929, blocks 11,823,123 to 11,823,186), with only the SNARK check
  mocked, and the relayer's proofs passed `verifyEvent` for real logs at the range's first, middle and last blocks
  and `verifyCheckpoint` at its last.

Neither index is recorded as deployed on a public testnet: `deployments/`, where every step writes what it deployed,
is empty, and no P1 proof has been generated yet.
