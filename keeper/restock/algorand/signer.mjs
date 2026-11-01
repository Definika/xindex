#!/usr/bin/env node
// The restock service's Algorand signer (`design/2026-11-01-non-evm-restock.md`, D3): restock.mjs starts it as a child
// process with an environment of its own, so the Algorand libraries and the Algorand key never share a process with
// the treasury's key, which this process never sees. It answers the requests of `moves.mjs` through
// `signer-protocol.mjs`.
//
// Its environment: ALGORAND_ALGOD_URL (https://mainnet-api.algonode.cloud); ALGORAND_MNEMONIC, the wallet's 25-word
// mnemonic; optionally ALGORAND_INDEXER_URL (https://mainnet-idx.algonode.cloud), which confirms what algod no longer
// remembers.

import { quietConsole, required, serve } from "../signer-protocol.mjs";

quietConsole();

const { default: algosdk } = await import("algosdk");
const { createMoves } = await import("./moves.mjs");

const account = algosdk.mnemonicToSecretKey(required("ALGORAND_MNEMONIC"));
const algod = new algosdk.Algodv2("", required("ALGORAND_ALGOD_URL"), "");
const indexerUrl = process.env.ALGORAND_INDEXER_URL?.trim() || "https://mainnet-idx.algonode.cloud";
const moves = createMoves({ algod, indexerUrl, account });

serve(moves, { wallet: account.addr });
