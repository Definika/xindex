// The restock service's home on Sui: a signer home (`signer-home.mjs`) whose signer is `sui/signer.mjs`, the one
// process that holds the Sui key and loads the Sui libraries (D3 of design/2026-11-01-non-evm-restock.md).

import { CHAINS } from "./coins.mjs";
import { createSignerHome } from "./signer-home.mjs";

const SIGNER = new URL("./sui/signer.mjs", import.meta.url).pathname;

/// The Sui signer's whole environment, from the chain's settings (`config.mjs`): never this process's, which holds the
/// treasury's key.
export const signerEnv = (settings) => ({ PATH: process.env.PATH ?? "", SUI_RPC_URL: settings.rpcUrl, SUI_KEY: settings.key });

/// The home on Sui for `coins`, with the chain's `settings`; `verifyVaa` is Ethereum's core check (D5).
export function createSuiHome({ settings, coins, journal, cfg, verifyVaa, signerPath = SIGNER }) {
  return createSignerHome({ name: "sui", def: CHAINS.sui, signerPath, env: signerEnv(settings), coins, floatId: CHAINS.sui.float.id, journal, cfg, verifyVaa });
}
