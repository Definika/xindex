// The restock service's home on Solana: a signer home (`signer-home.mjs`) whose signer is `solana/signer.mjs`, the one
// process that holds the Solana key and loads the Solana libraries (D3 of design/2026-11-01-non-evm-restock.md).

import { CHAINS } from "./coins.mjs";
import { createSignerHome } from "./signer-home.mjs";

const SIGNER = new URL("./solana/signer.mjs", import.meta.url).pathname;

/// The Solana signer's whole environment, from the chain's settings (`config.mjs`): never this process's, which holds
/// the treasury's key.
export function signerEnv(settings) {
  const env = { PATH: process.env.PATH ?? "", SOLANA_RPC_URL: settings.rpcUrl, SOLANA_KEY: settings.key, JUPITER_API_KEY: settings.jupiterApiKey };
  const optional = { JUPITER_URL: settings.jupiterUrl, JUPITER_PROGRAMS: settings.jupiterPrograms, SOLANA_MAX_UNIT_PRICE: settings.maxUnitPrice };
  for (const [key, value] of Object.entries(optional)) if (value) env[key] = value;
  return env;
}

/// The home on Solana for `coins`, with the chain's `settings`; `verifyVaa` is Ethereum's core check (D5).
export function createSolanaHome({ settings, coins, journal, cfg, verifyVaa, signerPath = SIGNER }) {
  return createSignerHome({
    name: "solana",
    def: CHAINS.solana,
    signerPath,
    env: signerEnv(settings),
    coins,
    floatId: CHAINS.solana.float.id,
    journal,
    cfg,
    verifyVaa,
  });
}
