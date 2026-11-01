// The restock service's home on Aptos: a signer home (`signer-home.mjs`) whose signer is `aptos/signer.mjs`, the one
// process that holds the Aptos key and loads the Aptos libraries (D3 of design/2026-11-01-non-evm-restock.md).

import { CHAINS } from "./coins.mjs";
import { createSignerHome } from "./signer-home.mjs";

const SIGNER = new URL("./aptos/signer.mjs", import.meta.url).pathname;

/// The Aptos signer's whole environment, from the chain's settings (`config.mjs`): never this process's, which holds the
/// treasury's key.
export function signerEnv(settings) {
  const env = { PATH: process.env.PATH ?? "", APTOS_RPC_URL: settings.rpcUrl, APTOS_KEY: settings.key, PANORA_API_KEY: settings.panoraApiKey };
  if (settings.panoraUrl) env.PANORA_URL = settings.panoraUrl;
  return env;
}

/// The home on Aptos for `coins`, with the chain's `settings`; `verifyVaa` is Ethereum's core check (D5).
export function createAptosHome({ settings, coins, journal, cfg, verifyVaa, signerPath = SIGNER }) {
  return createSignerHome({ name: "aptos", def: CHAINS.aptos, signerPath, env: signerEnv(settings), coins, floatId: CHAINS.aptos.float.id, journal, cfg, verifyVaa });
}
