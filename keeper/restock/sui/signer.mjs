#!/usr/bin/env node
// The restock service's Sui signer (`design/2026-11-01-non-evm-restock.md`, D3): restock.mjs starts it as a child
// process with an environment of its own, so the Sui libraries and the Sui key never share a process with the
// treasury's key, which this process never sees. It answers the requests of `moves.mjs` through `signer-protocol.mjs`.
//
// Its environment: SUI_RPC_URL, a Sui gRPC fullnode (https://fullnode.mainnet.sui.io:443); SUI_KEY, the wallet's
// `suiprivkey1...` secret key.

import { quietConsole, required, serve } from "../signer-protocol.mjs";

quietConsole();

const { SuiGrpcClient } = await import("@mysten/sui/grpc");
const { Ed25519Keypair } = await import("@mysten/sui/keypairs/ed25519");
const { createMoves } = await import("./moves.mjs");

const keypair = Ed25519Keypair.fromSecretKey(required("SUI_KEY"));
const client = new SuiGrpcClient({ network: "mainnet", baseUrl: required("SUI_RPC_URL") });
const moves = createMoves({ client, keypair });

serve(moves, { wallet: keypair.toSuiAddress() });
