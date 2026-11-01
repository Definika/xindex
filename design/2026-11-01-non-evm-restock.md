# Restock beyond EVM: Solana first, then Sui, Aptos and Algorand

2026-11-01. The owner's call: build the restock adapters for the five coins whose home chain is not an EVM chain (JUP
and PYTH on Solana, SUI, APT, ALGO), "as Wormhole and the other bridges recommend". This record is what their docs say,
what the design takes from them, and the order of the work. Solana comes first: two coins, CCTP V2, and a local
validator that can clone mainnet's programs for a real end-to-end test.

## 1. Why the keeper needs them

The five coins exist on Ethereum only as Wormhole copies, and no Ethereum pool trades the copies. A fill that must
deliver one (an auction whose weights grow that leg, a `MintRequests` request on an index that holds it) delivers it
from the executor's stock, and nothing refills that stock for these five: the restock service (`keeper/restock.mjs`)
serves only the eight coins whose home chain is an EVM chain. Without an adapter an operator buys and bridges by hand,
as ATOM's stock is kept (the owner's call of 2026-10-20). Issue and redeem in kind, holders' exits, and fills that
sell these coins are unaffected either way.

## 2. What the docs say

**Wormhole** ([manual transfers](https://wormhole.com/docs/products/token-transfers/wrapped-token-transfers/get-started/),
[SDK example](https://github.com/wormhole-foundation/wormhole-sdk-ts/blob/main/examples/src/tokenBridge.ts),
[Solana Token Bridge client](https://github.com/wormhole-foundation/wormhole-sdk-ts/blob/main/platforms/solana/protocols/tokenBridge/src/tokenBridge.ts),
[supported networks](https://wormhole.com/blog/updates-to-wormholes-supported-networks)):

- The recommended client is the TypeScript SDK, `@wormhole-foundation/sdk` (4.14 in the docs), with one module per
  platform. A manual transfer is initiated on the source chain, the guardians' signed message (the VAA) is fetched, and
  the transfer is redeemed on the destination. The SDK fetches VAAs from Wormholescan.
- `TokenBridge.transfer(sender, recipient, token, amount, payload?)` on Solana sends a native SPL token, as JUP and PYTH
  are, with `transferNativeWithPayload` when given a payload, from the sender's associated token account (ATA), after
  approving the bridge's authority for the amount. The recipient is a 32-byte universal address. Token-2022 mints are
  refused by the manual route.
- `TokenBridge.redeem(sender, vaa)` on Solana posts the VAA, creates the redeemer's ATA for the mint when missing, and
  completes the transfer to the VAA's recipient, which on Solana is a token account, not a wallet. A transfer to a
  Solana wallet's coin is a transfer to that wallet's ATA for the coin's mint.
- The bridge carries eight decimals; it returns what lies below them to the sender ("dedust").
- Through the update of 2026-08-07, no deprecation touches Solana, Sui, Aptos or Algorand.

**Circle, CCTP** ([supported chains](https://developers.circle.com/cctp/cctp-supported-blockchains),
[Solana programs](https://developers.circle.com/cctp/references/solana-programs.md),
[Bridge Kit](https://www.circle.com/blog/introducing-bridge-kit-build-crosschain-apps-faster)):

- CCTP V2 runs on Solana, domain 5: `MessageTransmitterV2` at `CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC` and
  `TokenMessengerMinterV2` at `CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe` (Anchor programs; the docs' IDL links are
  swapped, so the IDLs are checked against the programs before use).
- A burn's `mintRecipient` on Solana is a USDC token account, and that account must exist when `receiveMessage` runs,
  or the instruction reverts. A burn from Solana writes its message to an event account the sender creates, whose rent
  can be reclaimed five days later.
- Circle's guidance has Sui (domain 8) and Aptos (domain 9) on CCTP V1 still, and lists no Algorand.
- Circle's app-level kit (`@circle-fin/bridge-kit`, `@circle-fin/adapter-solana`) runs burn, attestation and mint as one
  call. The restock signs, records and only then broadcasts every move that commits funds, so it cannot hand a whole
  move to such a call; it builds the programs' instructions itself, from Circle's IDLs.

**Jupiter** ([Swap API](https://developers.jup.ag/docs/swap-api), [build](https://developers.jup.ag/docs/swap/build)):

- The v1 Swap API ("Metis") is no longer maintained; Swap V2 replaces it. Every endpoint needs an API key, sent as
  `x-api-key`, from Jupiter's portal.
- `GET https://api.jup.ag/swap/v2/build` (`inputMint`, `outputMint`, `amount` in the input's smallest unit, `taker`,
  `slippageBps`) returns the quote and the instructions, with a recent blockhash; the caller assembles the v0
  transaction, simulates it for compute units, signs and sends it through its own RPC. `/order` and `/execute` are the
  managed path, which sends through Jupiter.

**Solana** ([retrying transactions](https://solana.com/developers/cookbook/transactions/retry.md)):

- A transaction's blockhash is valid for about 150 blocks. The same signed transaction may be sent again while its
  blockhash is valid; once the block height passes the blockhash's `lastValidBlockHeight` and the signature has no
  status, it can never land, and only then is a new one signed.

## 3. Design

**D1. The executor pins a recipient per chain and coin.** `bridgeOut` sent every coin for a chain to one
`homeRecipient[chain]`. On Solana the bridge pays a token account, one per mint, so one recipient cannot take both JUP
and PYTH. `homeRecipient[chain][token]` replaces it, set by the owner per coin: the home wallet on EVM chains, Sui,
Aptos and Algorand, the wallet's ATA for the coin's mint on Solana. Nothing is deployed on a mainnet, and the Sepolia
executor is not deployed yet, so nothing migrates.

**D2. The restock speaks to chains in moves, not in calls.** `restock.mjs` built EVM calls itself (approvals, router
paths, Token Bridge and CCTP requests). Each adapter now offers the same moves: `buy`, `sell`, `bridgeIn`, `redeem`,
`sweep`, `receive`, with `balance`, `resume`, `transferCompleted` and `cctpReceived`; the EVM adapter keeps its exact
behaviour behind them, proven by the restock's end-to-end test, unchanged in what it checks.

**D3. Solana's key and libraries live in their own process.** The service's treasury key moves stock and USDC on
Ethereum within the owner's allowances (RS-1, RS-2). Solana needs `@solana/web3.js`, Wormhole's SDK and Anchor, a
dependency tree far larger than the viem the keeper has today. They run in a child process with its own package and
lockfile (`keeper/restock/solana/`), which holds only the Solana key, read from its own file, and answers only "build
and sign this move". The parent never loads those libraries or that key; the child never sees the treasury's. The
parent sends, confirms and reads balances itself, through Solana's JSON-RPC, with no dependency.

**D4. A Solana move is journalled as Solana recommends.** The move that commits funds (a swap, a bridge transfer, a
burn) is one transaction, signed, recorded with its `lastValidBlockHeight`, then sent. After a restart it is sent again
while the finalized block height has not passed that height; past it, with no status for its signature, the move is
dropped, never re-signed in place: the EVM rule for a nonce taken elsewhere (RS-5). Completing steps (posting a VAA,
creating an ATA, completing a transfer, receiving a CCTP message) are each counted once by their program and simply
sent again until done.

**D5. Every VAA is verified on Ethereum before it is stored,** both ways: the guardian set is the same on every chain,
and Ethereum's core already checks the VAAs the service redeems there (RS-14).

**D6. Libraries pinned exactly,** with the lockfile committed, and only Wormhole's own modules for the chains served
(`@wormhole-foundation/sdk-connect`, `-solana`, `-solana-core`, `-solana-tokenbridge`), not the SDK's meta package.

## 4. Order of the work

1. D1 in `KeeperExecutor`, with its tests, and the restock's setup check per coin.
2. D2: the refactor, with the restock's end-to-end test passing as before.
3. Solana: the child signer (Jupiter, Wormhole, CCTP V2), the parent's adapter, unit tests, and an end-to-end test on
   `solana-test-validator` with mainnet's Wormhole and CCTP programs cloned and a test guardian set installed.
4. Sui (CCTP V1, its token bridge, a DEX aggregator), Aptos (CCTP V1, Panora), Algorand (no CCTP: its float is kept by
   hand, as BNB Chain's is; Tinyman). Each reads its own docs first, as this record did.

## 5. What the owner provides

A Jupiter API key; a Solana wallet for the service, with SOL for fees and rent (every ATA and CCTP event account costs
rent); the executor owner's `setHomeRecipient` per coin, the Solana ones at the wallet's ATAs, which the service prints
at startup; and a `restockAllowance` for JUP and PYTH, as for every coin.
