# Retirement of the non-EVM restock and of the Wormhole copies off the list

On 2026-11-25 the owner asked for the repository's leftovers to be found and deleted. Told that the code was clean
and that what was left over was kept by earlier calls "for a relisting", and asked whether those are needed, the
owner approved the deletion recommended: "კი, წაშალე" (yes, delete). So:

- **The restock's signers for Solana, Sui, Aptos and Algorand** went. They served the Wormhole copies of JUP, PYTH,
  SUI, APT and ALGO, which left Ethereum's list on 2026-11-18 (the owner's call, no Ethereum pool trading them,
  `docs/design/bridged-coins.md`), and had never sent a transaction. With them went the owner's
  attestation tool (`node keeper/restock.mjs --attest <chain> <token>`, PD-7), which ran on those signers: the 26
  copies still to attest would meet the same bar as the five that left, and Wormhole's own SDK attests a token should
  one be wanted. About 13,000 lines, none of them run by any index.
- **The Wormhole copies off the list**: XRP, ADA, LTC, DOT, ATOM and BNB (off since 2026-11-13: BNB Chain's deployment
  holds those coins in kind) and JUP, PYTH, SUI, APT and ALGO left `script/MainnetAddresses.sol` and the restock's
  coin table. The restock's BNB Chain home went with the six, its only coins. OP's copy stays, the owner having taken
  it off "for now" on 2026-11-21, and so does the restock's Optimism home.

Their addresses, for a relisting, as the bridge's `wrappedAsset` gave them on 2026-10-10 and 2026-10-18:

| Copy | Address | Source |
| --- | --- | --- |
| XRP | `0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535` | Binance-Peg XRP, BNB Chain (Wormhole chain 4) |
| ADA | `0x8EfFbF747d4A60Bc6b68D9A1bE4c4188bA8A3a0b` | Binance-Peg ADA, BNB Chain |
| LTC | `0x1cA1Ef3fB8Ff4a480C0ae7eea5f91A24a5BB3344` | Binance-Peg LTC, BNB Chain |
| DOT | `0x1839a38E59536D88C25e8E6e0D0f59e05b143ab2` | Binance-Peg DOT, BNB Chain |
| ATOM | `0x7845167B54253269624dBA0cA5Fee87933107b34` | Binance-Peg ATOM, BNB Chain |
| BNB | `0x418D75f65a02b3D53B2418FB8E1fe493759c7605` | WBNB, BNB Chain |
| JUP | `0x8687a10BCa6F139B25eb31020FCABB5782214764` | Solana (chain 1) |
| PYTH | `0xeFc0CED4B3D536103e76a1c4c74F0385C8F4Bdd3` | Solana |
| SUI | `0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6` | Sui (chain 21) |
| APT | `0x8CDf7AF57E4c8B930e1B23c477c22f076530585e` | Aptos (chain 22) |
| ALGO | `0xe31Cfcd36FeD044ae4Cf9405B577fe875762194F` | Algorand (chain 8) |

`test/ConfigureWeighted.t.sol` still names each of the eleven, as it names DOGE's copy, to hold them off the list.
`script/PythIds.sol` keeps their feeds: BNB Chain's list prices XRP, ADA, LTC, DOT, ATOM and BNB at them.

What went:

- `keeper/restock/solana/`, `sui/`, `aptos/`, `algorand/`, and `solana.mjs`, `sui.mjs`, `aptos.mjs`, `algorand.mjs`,
  `signer-home.mjs`, `signer-protocol.mjs`, `solana-sending.mjs`, `inflight.mjs`, `bounds.mjs` and `attest.mjs`.
- In `keeper/restock.mjs`: the non-EVM homes, `--attest`, the reclaim of a Solana burn's rent and the signers' close.
- In the restock's shared modules: `CHAINS.bsc` and the four non-EVM chains (`coins.mjs`), their settings and gas
  minimums (`config.mjs`), BNB Chain's market (`evm.mjs`), the gas-coin reserve (`plan.mjs` `spendable`, which only
  SUI, APT and ALGO had), the hand top-up of a float without CCTP (every home chain left runs CCTP), the journal's
  `rentToReclaim` and `find`, and `attestMetaOf` (`attestations.mjs`).
- The tests: `keeper/test/unit/restock-solana.test.mjs`, `restock-sui.test.mjs`, `restock-aptos.test.mjs`,
  `restock-attest.test.mjs`, `restock-signer-home.test.mjs` and `restock-inflight.test.mjs`; the CA-R2-13 test of
  `restock-journal.test.mjs`, the CA-M14 test of `restock-plan.test.mjs` and the PD-7 test of
  `restock-attestations.test.mjs`; the copies' token and bridge checks in `test/fork/MainnetAddresses.fork.t.sol`.
- Mutants P1 to P14, P19, P21 to P24, T3, C43 to C51.

What stands in their place: the restock's tests that used XRP on BNB Chain, or SUI, as their example coin run on AERO
on Base and AVAX on Avalanche (`restock-plan`, `restock-config`, `restock-coins`, `restock-advance`), and the
executor's bridge fork test (`keeper/test/KeeperExecutor.fork.t.sol`) on AVAX's copy, whose source is Avalanche's
WAVAX. `restock-coins.test.mjs` pins that every home chain left is an EVM chain that runs CCTP.

This file says which past findings went, in the form of `audits/retired/zap-ether.md`. **RETIRED** means
the mechanism the finding lived in is gone. A retired id is not free to reuse, and its test must not be restored
against a new design.

| Id | Finding (`audits/internal/protocol-docs-review-pd.md`, `audits/internal/consolidated-audit-ca.md`) | Status |
| --- | --- | --- |
| PD-1 | Jupiter's other routes and the wallet's other token accounts in the Solana simulation | RETIRED |
| PD-2 | Jupiter's on-chain minimum, read by its IDL | RETIRED |
| PD-3 | Cetus's aggregator package and Sui's floor | RETIRED |
| PD-4 | Aptos's expiry on a node behind | RETIRED |
| PD-5 | Sui's gas coin read as gone on any error | RETIRED |
| PD-6 | A signer's transaction in flight from its signing | RETIRED |
| PD-7 | The owner's attestation of the copies still to attest | RETIRED |
| PD-8 | Solana's null signature status | RETIRED |
| PD-11 | A signer's stdin without an error listener | RETIRED |
| PD-13 | Panora's splits and integrator fee | RETIRED |
| CA-M14 | A chain's own gas coin sold or bridged to nothing | RETIRED |
| CA-R2-12 | A signer's minimum buy held to the float's value | RETIRED |
| CA-R2-13 | A Solana burn's rent pruned before its reclaim | RETIRED |
| CA-L7 | The signers left running after the restock's loop | RETIRED |
| CA-L8 | A signer launched by its URL's pathname | RETIRED |

PD-9, PD-10, PD-12 and PD-14 keep their tests or their documentation: they live in the journal, the CCTP receipt and
Iris's fee, which the EVM homes still use.

The check behind this file: the ids that name a test in `keeper/test/` before this change, less the ids that name one
after it, are the fifteen above.
