#!/usr/bin/env node
// The restock service's Aptos signer (`design/2026-11-01-non-evm-restock.md`, D3): restock.mjs starts it as a child
// process with an environment of its own, so the Aptos libraries and the Aptos key never share a process with the
// treasury's key, which this process never sees. It answers the requests of `moves.mjs` through `signer-protocol.mjs`.
//
// Its environment: APTOS_RPC_URL, an Aptos fullnode's REST API (https://api.mainnet.aptoslabs.com/v1); APTOS_KEY, the
// wallet's 32-byte Ed25519 key in hex; PANORA_API_KEY, Panora's API key; optionally PANORA_URL
// (https://api.panora.exchange).

import { quietConsole, required, serve } from "../signer-protocol.mjs";

quietConsole();

const { Account, Aptos, AptosConfig, Ed25519PrivateKey, Network } = await import("@aptos-labs/ts-sdk");
const { createMoves } = await import("./moves.mjs");

const account = Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(required("APTOS_KEY")) });
const aptos = new Aptos(new AptosConfig({ network: Network.MAINNET, fullnode: required("APTOS_RPC_URL") }));
const panora = { url: (process.env.PANORA_URL?.trim() || "https://api.panora.exchange").replace(/\/+$/, ""), apiKey: required("PANORA_API_KEY") };
const moves = createMoves({ aptos, account, panora });

serve(moves, { wallet: account.accountAddress.toStringLong() });
