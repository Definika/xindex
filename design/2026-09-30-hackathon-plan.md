# Colosseum Crypto World's Fair: build plan to 12 October 2026

The hackathon is multichain (Solana, Ethereum, Hyperliquid and other tracks). It asks for:
- an MVP;
- a repository whose code was written during the hackathon;
- a pitch video and a technical demo video;
- a user acquisition plan, a monetization plan and the team.

This repository's first commit is 15 September 2026, the kickoff day.

## What the submission shows

Xindex v4 across three chains on their testnets. One index token on Ethereum holds WETH on Ethereum, SOL in a vault
on Solana, and HYPE in a vault on HyperEVM:
- it mints with coins deposited on each chain;
- it redeems with each coin paid out on its own chain, within the 4%-a-day speed limit;
- no contract reads a price.

| Piece | Chain | State on 30 September |
|---|---|---|
| Stage A: the price-free index, zap, MintRequests | Ethereum (Sepolia) | built, gated, not deployed |
| HybridIndexFactory, HybridHub, module, extension | Ethereum (Sepolia) | built, gated, not deployed |
| EVM vault | HyperEVM testnet | built, gated; deploys unchanged |
| **Solana vault program** | Solana devnet | **to build** |
| BNB Chain proven on Ethereum from its own votes | Ethereum | built, tested on real BNB data (shown as the real proof path) |
| **Relayer carrying messages between the chains** | all | **to build** |

## What is a stub, and must say so

The proofs between Ethereum and the vault chains are not ready. P1 and P2 wait on the owner's GPU run, and Solana's
proof of its own state waits on Alpenglow's certificates. For the demo:
- **Ethereum → vault.** A stub verifier accepts a message that a relayer key signed. Two relayer keys stand for P1 and
  P2.
- **Vault → Ethereum.** A stub state verifier accepts vault state a relayer key signed.

Rules for the stubs:
- Each stub implements the same interface the real verifier will. The vaults and the hub are the real code, unchanged.
- The stubs live in `demo/` (Ethereum) and `solana/programs/stub-verifier` (Solana), never in `src/` or `script/`, so
  no production deployment can pick them up. Every stub's name and first line say it is a stub.
- The submission states it plainly: "proofs: relayer stub on testnets; the real design is in the Stage B spec".

## Days

| Dates | Work | Who |
|---|---|---|
| 30 Sep to 1 Oct | This plan; the Solana vault's spec (section 7 of the Stage B spec); the program scaffolded | Claude |
| 1 to 4 Oct | The Solana vault program and the stub verifier program, with LiteSVM tests: registration, deposits, intakes, messages, burns under the speed limit, freeze, digests | Claude |
| 4 to 5 Oct | The Ethereum-side stubs in `demo/`; the testnet deploy scripts: Stage A, the hybrid factory and templates, chains registered, the index created | Claude |
| 5 to 6 Oct | Deploy to Sepolia, Solana devnet and HyperEVM testnet | the owner signs; Claude prepares every command |
| 6 to 8 Oct | The relayer: VaultMessage events on Sepolia to the vaults; vault state to Sepolia; a runbook | Claude |
| 8 to 10 Oct | End-to-end runs on the testnets: mint, redeem, speed limit, freeze; the app's demo flow | Claude; the app repo by the owner |
| 10 to 12 Oct | Pitch video, demo video, write-up, submission | the owner; Claude drafts the write-up and scripts |

Stretch goal, only if the days allow: deploy the BNB state verifier on Sepolia and prove a live BNB testnet vote. That
would be a real proof between chains running on testnets.

## What the owner provides

- **Keys:** a Sepolia deployer (MetaMask `--browser`, as for v3), a Solana devnet keypair, a HyperEVM testnet
  deployer, and the relayer keys (testnet only).
- **Test funds:** Sepolia ETH, devnet SOL (airdrop), HyperEVM testnet HYPE.
- **The app:** the app repository's demo flow.
- **The pitch:** the videos, the team section, and the monetization story. The fee decision comes later: Stage A
  charges no fee, and the pitch can present a later version's.

## Machine load

Solana builds run at the lowest priority with two jobs, as the Foundry gates do. Tests use LiteSVM, not a local
validator.
