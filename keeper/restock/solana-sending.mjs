// How the restock service sends on Solana, in what needs no library: what a journalled transaction's status comes to,
// and when it is sent again or given up. A Solana transaction's blockhash is valid for about 150 blocks: the same
// signed bytes may be sent again until the block height passes its `lastValidBlockHeight`, and once the *finalized*
// height has, a transaction with no confirmed status can never land (Solana's guidance on retrying transactions).
// No dependencies, so the unit tests run without `npm install`.

/// What to do with a move signed as a transaction whose signature has `status` (getSignatureStatuses' entry, or null)
/// when the finalized block height is `finalizedHeight` and the transaction's `lastValidBlockHeight` is
/// `lastValidBlockHeight`:
/// - `{ sent: "success" | "reverted" }`: it landed, at confirmed commitment or better;
/// - `{ drop: reason }`: it can never land, so nothing it would have moved left the wallet;
/// - `{ resend: true }`: it may still land; send the same bytes again.
export function resumeDecision({ status, finalizedHeight, lastValidBlockHeight }) {
  const confirmed = status && (status.confirmationStatus === "confirmed" || status.confirmationStatus === "finalized");
  if (confirmed) return { sent: status.err ? "reverted" : "success" };
  if (BigInt(finalizedHeight) > BigInt(lastValidBlockHeight)) {
    return { drop: `its blockhash expired at block height ${lastValidBlockHeight} before it was confirmed` };
  }
  return { resend: true };
}

/// The JSON-RPC client of a Solana node at `url`, with native fetch: `call(method, params)` answers the result, or
/// throws the node's error.
export function createSolanaRpc({ url, fetchImpl = fetch, timeoutMs = 30_000 }) {
  let id = 0;
  return async function call(method, params = []) {
    const response = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(`Solana RPC ${response.status} on ${method}`);
    const body = await response.json();
    if (body.error) throw new Error(`Solana RPC ${method}: ${body.error.message ?? JSON.stringify(body.error)}`);
    return body.result;
  };
}

/// A 20-byte EVM address as a 32-byte word, as the bridges encode a recipient.
export const evmWord = (address) => `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;
