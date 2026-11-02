// The restock service's home on Algorand: a signer home (`signer-home.mjs`) whose signer is `algorand/signer.mjs`, the
// one process that holds the Algorand key and loads the Algorand libraries (D3 of design/2026-11-01-non-evm-restock.md).
// Algorand has no CCTP: its USDC float is kept by hand, as BNB Chain's is.

import { CHAINS } from "./coins.mjs";
import { createSignerHome } from "./signer-home.mjs";

const SIGNER = new URL("./algorand/signer.mjs", import.meta.url).pathname;

/// The Algorand signer's whole environment, from the chain's settings (`config.mjs`): never this process's, which holds
/// the treasury's key.
export function signerEnv(settings) {
  const env = { PATH: process.env.PATH ?? "", ALGORAND_ALGOD_URL: settings.rpcUrl, ALGORAND_MNEMONIC: settings.key };
  if (settings.indexerUrl) env.ALGORAND_INDEXER_URL = settings.indexerUrl;
  return env;
}

/// The home on Algorand for `coins`, with the chain's `settings`; `verifyVaa` is Ethereum's core check (D5).
export function createAlgorandHome({ settings, coins, journal, cfg, verifyVaa, signerPath = SIGNER }) {
  return createSignerHome({ name: "algorand", def: CHAINS.algorand, signerPath, env: signerEnv(settings), coins, floatId: CHAINS.algorand.float.id, journal, cfg, verifyVaa });
}
