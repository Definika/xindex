// What a journalled Solana transaction's status comes to, in what needs no library, so the keeper's unit tests cover it
// and the Solana signer answers `status` with it (`solana/moves.mjs`). A Solana transaction's blockhash is valid for
// about 150 blocks: the same signed bytes may be sent again until the block height passes its `lastValidBlockHeight`,
// and once the *finalized* height has, a transaction with no confirmed status can never land (Solana's guidance on
// retrying transactions).

/// What became of a transaction whose signature has `status` (getSignatureStatuses' entry, or null) when the finalized
/// block height is `finalizedHeight` and the transaction's `lastValidBlockHeight` is `lastValidBlockHeight`:
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
