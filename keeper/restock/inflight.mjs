// The one transaction a signer has handed to its chain and that may still execute, for the chains whose transactions
// cannot overlap (Sui's gas coins, Aptos's sequence numbers, Algorand's one-at-a-time rule here), with no dependency
// so the keeper's unit tests cover it. A signer builds nothing while one may still execute.
//
// A transaction is in flight from the moment it is sent, never from the moment it is signed: a move the parent signed
// but gave up waiting for is never journalled and never sent, and must hold nothing (PD-6). A move the parent did
// journal is put back in flight when the parent asks its status after a restart (PD-9).

/// Whether `error`, thrown by sending a transaction, is the chain refusing it outright: a 4xx answer other than a
/// timeout, a conflict or a rate limit, or a gRPC status naming the transaction invalid. A refused transaction holds
/// no lock and runs only if sent again; any other failure (a timeout, a 5xx, a 429, a dropped connection) may have
/// sent it.
export function refusedOutright(error) {
  if (typeof error?.code === "string" && ["INVALID_ARGUMENT", "FAILED_PRECONDITION", "PERMISSION_DENIED", "OUT_OF_RANGE"].includes(error.code)) return true;
  const status = Number(error?.status ?? error?.response?.status ?? error?.statusCode);
  return status >= 400 && status < 500 && ![404, 408, 409, 425, 429].includes(status);
}

/// The tracker over `fate(entry)`, the chain's answer for a transaction in flight: `{state}`, one of landed, reverted,
/// pending, expired, or unknown (the node cannot tell, so it may still execute).
export function createInflight(fate) {
  let current = null;
  return {
    /// `entry` was handed to the chain: `{id, ...}`, what `fate` reads, and `resend` for a completing step this signer
    /// sends again while it may still execute (a move is the parent's to send, once it is in its journal).
    sent(entry) {
      current = entry;
    },
    /// Forgets the transaction `id` (or whatever is in flight, with none): it landed, can never execute, or was a
    /// completing step the chain refused outright, which holds nothing and runs again harmlessly if it ever does.
    clear(id = null) {
      if (id === null || current?.id === id) current = null;
    },
    current: () => current,
    /// Resolves once nothing in flight may still execute; throws while something may, after sending a completing step
    /// again.
    async idle() {
      if (!current) return;
      const s = await fate(current);
      if (s.state === "pending" || s.state === "unknown") {
        if (current.resend) await current.resend();
        throw new Error(`transaction ${current.id} may still execute (${s.state}${s.reason ? `: ${s.reason}` : ""}); waiting for it`);
      }
      current = null;
    },
  };
}
