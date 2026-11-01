// The owner's attestation of a token for its Wormhole copy on Ethereum (design/2026-10-10-one-index-wormhole-legs.md,
// section 2a), as Wormhole now documents it: through its TypeScript SDK, `createAttestation` on the token's home chain
// and the copy created on Ethereum from the signed attestation (wormhole.com/docs, "Attest tokens"). Portal's own
// interface for it, legacy Portal, closed on 2026-06-30 (PD-7). With no dependency, so the keeper's unit tests cover it.
// `node restock.mjs --attest <chain> <token>` runs it: the chain's signer attests, the guardians sign, the treasury
// creates the copy, or updates its name and symbol when it exists (RAY's `updateWrapped`).

import { attestMetaOf } from "./attestations.mjs";

const ZERO = /^0x0{40}$/i;

/// Attests `token` on the home `home` (a signer home with `attest` and `emitter`), whose Wormhole chain id is
/// `wormholeChain`, and creates or updates its copy on Ethereum. `wormholescan.vaa(chain, emitter, sequence, verify)`
/// fetches the signed attestation, `verifyVaa` checks it on Ethereum's core, `wrappedAsset(chain, word)` reads the
/// Token Bridge's copy for a token, and `submit(functionName, vaa)` sends `createWrapped` or `updateWrapped` from the
/// treasury. Returns `{copy, created, symbol, name, decimals}`.
export async function attestToken({ home, wormholeChain, token, wormholescan, verifyVaa, wrappedAsset, submit, log, wait = (ms) => new Promise((r) => setTimeout(r, ms)), pollMs = 15_000, timeoutMs = 45 * 60_000 }) {
  const { signature, sequence } = await home.attest(token);
  log("attest", `${token} attested on Wormhole chain ${wormholeChain} in ${signature}, sequence ${sequence}; waiting for the guardians`);
  let vaa = null;
  for (let waited = 0; !vaa; waited += pollMs) {
    if (waited > timeoutMs) throw new Error(`no signed attestation for sequence ${sequence} after ${timeoutMs / 60_000} minutes; run again later`);
    vaa = await wormholescan.vaa(wormholeChain, home.emitter, sequence, verifyVaa);
    if (!vaa) await wait(pollMs);
  }
  const meta = attestMetaOf(vaa);
  if (!meta) throw new Error("the signed message is not a token attestation");
  if (meta.tokenChain !== Number(wormholeChain)) throw new Error(`the attestation names a token of chain ${meta.tokenChain}, not ${wormholeChain}`);
  const existing = await wrappedAsset(meta.tokenChain, meta.tokenAddress);
  const created = ZERO.test(existing);
  await submit(created ? "createWrapped" : "updateWrapped", vaa);
  const copy = await wrappedAsset(meta.tokenChain, meta.tokenAddress);
  if (ZERO.test(copy)) throw new Error("the Token Bridge shows no copy after the attestation was submitted");
  log("attest", `${meta.symbol} (${meta.name}, ${meta.decimals} decimals): copy ${copy}, ${created ? "created" : "updated"}`);
  return { copy, created, symbol: meta.symbol, name: meta.name, decimals: meta.decimals };
}
