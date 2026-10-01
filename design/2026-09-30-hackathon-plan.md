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

| Piece | Chain | State on 1 October |
|---|---|---|
| Stage A: the price-free index, zap, MintRequests | Ethereum (Sepolia) | built, gated, not deployed |
| HybridIndexFactory, HybridHub, module, extension | Ethereum (Sepolia) | built, gated, not deployed |
| EVM vault | HyperEVM testnet | built, gated, not deployed; deploys unchanged, in a big block (`demo/README.md`) |
| Solana vault program and its stub verifier | Solana devnet | built on 30 September, with LiteSVM tests; not deployed |
| BNB Chain proven on Ethereum from its own votes | Ethereum | built, tested on real BNB data; a second demo index runs on it (below); not deployed |
| Relayer carrying messages between the chains | all | built on 30 September (`demo/relayer`), rehearsed on local chains; not run on the testnets |

## What is a stub, and must say so

The proofs between Ethereum and Solana or HyperEVM are not ready. P1 and P2 are built since (Stage B spec, sections 10
and 11), but neither has generated a proof yet: proving needs a prover network or a GPU, which the owner provides, and
P2 is not built on Solana. Solana's proof of its own state waits on Alpenglow's mainnet launch, and HyperEVM has no
state root to prove against (Stage B spec, section 8). For the demo:
- **Ethereum → vault.** A stub verifier accepts a message that a relayer key signed. Two relayer keys stand for P1 and
  P2.
- **Vault → Ethereum.** A stub state verifier accepts vault state a relayer key signed.

Rules for the stubs:
- Each stub implements the same interface the real verifier will. The vaults and the hub are the real code, unchanged.
- The stubs live in `demo/` (the EVM chains) and `solana/programs/stub-verifier` (Solana), never in `src/` or
  `script/`, so no production deployment can pick them up. Every stub's name and first line say it is a stub.
- The submission states it plainly: "proofs: relayer stub on testnets; the real design is in the Stage B spec".

## Days

| Dates | Work | Who | State on 1 October |
|---|---|---|---|
| 30 Sep to 1 Oct | This plan; the Solana vault's spec (section 7 of the Stage B spec); the program scaffolded | Claude | done |
| 1 to 4 Oct | The Solana vault program and the stub verifier program, with LiteSVM tests: registration, deposits, intakes, messages, burns under the speed limit, freeze, digests | Claude | done on 30 September: 29 LiteSVM tests and 7 encoding tests |
| 4 to 5 Oct | The Ethereum-side stubs in `demo/`; the testnet deploy scripts: Stage A, the hybrid factory and templates, chains registered, the index created | Claude | done on 30 September: `demo/src`, `demo/script/Demo.s.sol` |
| 5 to 6 Oct | Deploy to Sepolia, Solana devnet and HyperEVM testnet | the owner signs; Claude prepares every command | to do: the commands are in `demo/README.md`, and `demo/deployments` is empty |
| 6 to 8 Oct | The relayer: VaultMessage events on Sepolia to the vaults; vault state to Sepolia; a runbook | Claude | done on 30 September: `demo/relayer`, and the runbook in `demo/README.md` |
| 8 to 10 Oct | End-to-end runs on the testnets: mint, redeem, speed limit, freeze; the app's demo flow | Claude; the app repo by the owner | rehearsed on 30 September on local chains, a mint and a redemption across all three (`demo/README.md`, "Rehearsed"); the testnet runs wait on the deployment; the app is not in this repository |
| 10 to 12 Oct | Pitch video, demo video, write-up, submission | the owner; Claude drafts the write-up and scripts | to do: no draft is in this repository |

Stretch goal, only if the days allow: deploy the BNB state verifier on Sepolia and prove a live BNB testnet vote. That
would be a real proof between chains running on testnets.

**Built on 1 October, beyond the stretch goal:** a second demo index, of WETH and BNB, on real proofs both ways but
P2's. BNB testnet's vault state reaches Sepolia through `BnbStateVerifier` from the chain's own votes, and Sepolia's
messages reach BNB testnet through P1, built for Sepolia (`proofs/`, `--features sepolia`). Both directions were
rehearsed against live chain data (`demo/README.md`, "Rehearsed"). Running P1 on the testnets needs a prover: Succinct's
network or a CUDA GPU, at about 358 million prover gas a Sepolia proof. P2 has been built since, with a Sepolia build of
its own (`proofs/p2`, `RiscZeroFinalityVerifier`), but the demo still deploys the stub in its place. Nothing of this
index is deployed on the testnets yet.

## What remains (1 October)

- **Deploying** on Sepolia, Solana devnet and HyperEVM testnet, and on BNB testnet if the second index is deployed,
  the owner signing, by `demo/README.md`'s calendar. The timelocks put the first claim five days after the first
  deployment: 2 days to register a chain, 2 more to list its coin, then an order and its 24-hour lock. For a claim and
  a redemption before 12 October, the first deployment goes out by 6 October.
- **Keeping the relayer running:** from day 4 for the first index, and from day 0 for the second, whose
  `BnbStateVerifier` stops for good a day behind BNB testnet and whose P1 the relayer proves hourly.
- **The end-to-end runs** on the testnets, the app's demo flow, the videos, the write-up and the submission.

## What the owner provides

- **Keys:** a Sepolia deployer (MetaMask `--browser`, as for v3), a Solana devnet keypair, a HyperEVM testnet
  deployer, and the relayer keys (testnet only).
- **Test funds:** Sepolia ETH, devnet SOL (airdrop), HyperEVM testnet HYPE.
- **For the second index, if it is deployed:** a BNB testnet deployer, tBNB for the deposit and the relayer, and a
  prover for P1: a funded key for Succinct's network, or a CUDA GPU (`demo/README.md`).
- **The app:** the app repository's demo flow.
- **The pitch:** the videos, the team section, and the monetization story. The fee decision comes later: Stage A
  charges no fee, and the pitch can present a later version's.

## Machine load

Solana builds run at the lowest priority with two jobs, as the Foundry gates do. Tests use LiteSVM, not a local
validator.
