// What a journalled Solana transaction's status comes to, in what needs no library, so the keeper's unit tests cover it
// and the Solana signer answers `status` with it (`solana/moves.mjs`). A Solana transaction's blockhash is valid for
// about 150 blocks: the same signed bytes may be sent again until the block height passes its `lastValidBlockHeight`,
// and once the *finalized* height has, a transaction with no confirmed status can never land (Solana's guidance on
// retrying transactions). But "no status" is only an answer from a node that has seen the finalized slot and keeps
// the ledger back to the send: a node behind, or one without that history, answers null for a transaction that
// landed, and dropping it on that word would lose a move that happened (PD-8).

/// The expiry a Solana signer records with a signed transaction: the block height past which it cannot land, and the
/// slot it was built at, before which it cannot have landed. An expiry that is a bare height (written before PD-8)
/// names no slot.
export function solanaExpiry(text) {
  const s = String(text);
  if (/^\d+$/.test(s)) return { lastValidBlockHeight: s, sentSlot: null };
  const { lastValidBlockHeight, sentSlot } = JSON.parse(s);
  return { lastValidBlockHeight: String(lastValidBlockHeight), sentSlot: sentSlot === null || sentSlot === undefined ? null : String(sentSlot) };
}

/// What became of a transaction whose signature has `status` (getSignatureStatuses' entry, or null), given:
/// - `finalizedHeight` and `finalizedSlot`: the finalized block height and the slot it was read at;
/// - `lastValidBlockHeight` and `sentSlot`: the transaction's expiry (`solanaExpiry`);
/// - `statusSlot`: the slot of the node that answered the status;
/// - `firstAvailableSlot`: the oldest slot that node keeps;
/// - `transaction`: getTransaction's answer when it was asked, `{err}` or null, or "unavailable" when the node keeps no
///   transaction history.
/// Returns one of:
/// - `{ sent: "success" | "reverted" }`: it landed, at confirmed commitment or better;
/// - `{ drop: reason }`: it can never land, so nothing it would have moved left the wallet;
/// - `{ resend: true }`: it may still land; send the same bytes again;
/// - `{ unknown: reason }`: its blockhash expired, but the node cannot show it did not land; ask again, or ask a node
///   that keeps the history.
export function resumeDecision({ status, transaction, finalizedHeight, finalizedSlot = null, statusSlot = null, firstAvailableSlot = null, lastValidBlockHeight, sentSlot = null }) {
  const confirmed = status && (status.confirmationStatus === "confirmed" || status.confirmationStatus === "finalized");
  if (confirmed) return { sent: status.err ? "reverted" : "success" };
  if (transaction && transaction !== "unavailable") return { sent: transaction.err ? "reverted" : "success" };
  if (BigInt(finalizedHeight) <= BigInt(lastValidBlockHeight)) return { resend: true };
  if (transaction === "unavailable") return { unknown: "the node keeps no transaction history, so it cannot show the transaction did not land" };
  if (statusSlot === null || finalizedSlot === null || BigInt(statusSlot) < BigInt(finalizedSlot)) {
    return { unknown: `the node that answered its status is behind the finalized slot ${finalizedSlot}` };
  }
  if (sentSlot === null || firstAvailableSlot === null || BigInt(firstAvailableSlot) > BigInt(sentSlot)) {
    return { unknown: `the node keeps slots from ${firstAvailableSlot} only, not from slot ${sentSlot}, when the transaction was built` };
  }
  return { drop: `its blockhash expired at block height ${lastValidBlockHeight} before it was confirmed` };
}
