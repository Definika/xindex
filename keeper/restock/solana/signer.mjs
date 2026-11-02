#!/usr/bin/env node
// The restock service's Solana signer (`design/2026-11-01-non-evm-restock.md`, D3): restock.mjs starts it as a child
// process with an environment of its own, so the Solana libraries and the Solana key never share a process with the
// treasury's key, which this process never sees. It answers the requests of `moves.mjs` through `signer-protocol.mjs`.
//
// Its environment: SOLANA_RPC_URL; SOLANA_KEY, the wallet's 64-byte secret key in base58; JUPITER_API_KEY;
// optionally JUPITER_URL (https://api.jup.ag), JUPITER_PROGRAMS (more Jupiter program ids, comma-separated) and
// SOLANA_MAX_UNIT_PRICE (the most micro-lamports per compute unit a transaction bids, 1000000).

import { quietConsole, required, serve } from "../signer-protocol.mjs";

quietConsole();

const { Connection, Keypair, PublicKey } = await import("@solana/web3.js");
const { utils } = await import("@coral-xyz/anchor");
const { createCctp } = await import("./cctp.mjs");
const { createJupiter } = await import("./jupiter.mjs");
const { createWormhole } = await import("./wormhole.mjs");
const { createMoves } = await import("./moves.mjs");

const secret = utils.bytes.bs58.decode(required("SOLANA_KEY"));
if (secret.length !== 64) throw new Error("SOLANA_KEY must be a 64-byte secret key in base58");
const wallet = Keypair.fromSecretKey(secret);
const connection = new Connection(required("SOLANA_RPC_URL"), "confirmed");
const maxUnitPrice = BigInt(process.env.SOLANA_MAX_UNIT_PRICE?.trim() || "1000000");
const programs = (process.env.JUPITER_PROGRAMS ?? "").split(",").map((s) => s.trim()).filter(Boolean).map((s) => new PublicKey(s));
const jupiter = createJupiter({
  url: process.env.JUPITER_URL?.trim() || "https://api.jup.ag",
  apiKey: required("JUPITER_API_KEY"),
  connection,
  wallet,
  programs,
});
const moves = createMoves({
  connection,
  wallet,
  jupiter,
  cctp: createCctp({ connection, wallet }),
  wormhole: createWormhole({ connection, wallet }),
  maxUnitPrice,
});

serve(moves, { wallet: wallet.publicKey.toBase58() });
