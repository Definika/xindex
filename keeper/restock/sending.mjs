// How the restock service sends, in what needs no chain library: the fees it allows, the approvals it gives, one
// transaction at a time on each chain, what a commit's receipt says, and what a move left signed by a restart or a
// slow chain comes to on its next look. No dependencies, so the unit tests run without `npm install`.

/// A chain's viem definition, its fees allowing twice the base fee and the tip, as the keeper's (`bot/math.mjs`
/// feesFor): a transaction stays includable through six full blocks of rising base fee and pays only what its block
/// charges, where viem's 1.2 left it stuck after two (RS-15). A legacy gas price is paid in full, so it keeps viem's.
export const withFeeHeadroom = (chain) => ({
  ...chain,
  fees: { ...chain.fees, baseFeeMultiplier: ({ block }) => (typeof block?.baseFeePerGas === "bigint" ? 2 : 1.2) },
});

/// Throws when a transaction of `address` is still pending on chain `name`: the service sends one at a time on each
/// chain, so a later one neither queues behind one a fee spike holds nor sends a move's completion again and again
/// while the first waits (RS-15). `client` needs viem's `getTransactionCount({address, blockTag})`.
export async function noPendingTransaction({ client, address, name }) {
  const [latest, pending] = await Promise.all([
    client.getTransactionCount({ address, blockTag: "latest" }),
    client.getTransactionCount({ address, blockTag: "pending" }),
  ]);
  if (pending > latest) throw new Error(`${name}: a transaction of the treasury's is still pending; waiting for it`);
}

/// Lets a spender take exactly `amount`, what the next call takes, unless it may already: no allowance stays standing
/// beyond what that call leaves unspent, a buy's slack at most, where an unlimited one left the whole wallet to any
/// flaw in a router, a bridge or CCTP (RS-12). `allowance()` reads it, `approve(x)` sets it. Returns whether it did.
export async function allowExactly({ allowance, approve, amount }) {
  if ((await allowance()) >= amount) return false;
  await approve(amount);
  return true;
}

/// What a commit's `receipt` says of move `id`, signed as `hash` for `request` ({to, data, value}). viem answers with
/// the receipt of whatever was mined on the nonce: the move's own transaction, the same call repriced, under whose
/// hash the move goes on, or another transaction, a cancel among them, when the move is dropped, since nothing it
/// committed left the wallet, and the failure thrown (RS-15). `getTransaction({hash})` reads the one mined. Returns the
/// receipt, or null when none came in time, the move left signed for its next look.
export async function settleCommit({ journal, id, hash, request, receipt, getTransaction }) {
  if (!receipt) return null;
  if (receipt.transactionHash.toLowerCase() !== hash.toLowerCase()) {
    const mined = await getTransaction({ hash: receipt.transactionHash });
    const same =
      mined.to?.toLowerCase() === request.to.toLowerCase() &&
      mined.input.toLowerCase() === request.data.toLowerCase() &&
      mined.value === (request.value ?? 0n);
    if (!same) {
      journal.drop(id, `its nonce went to another transaction, ${receipt.transactionHash}`);
      throw new Error(`move ${id}: its nonce went to another transaction, ${receipt.transactionHash}; dropped`);
    }
    journal.note(id, { hash: receipt.transactionHash, replaced: hash });
  }
  journal.advance(id, "sent", { block: receipt.blockNumber.toString(), status: receipt.status });
  return receipt;
}

/// How long a move whose nonce is spent, but whose receipt no node has served, is kept before it is dropped (RS-5).
export const ORPHAN_SECONDS = 60;

/// `client` needs viem's `getTransactionReceipt({hash})`, `getTransactionCount({address, blockTag})` and
/// `sendRawTransaction({serializedTransaction})`; `now()` is the clock, in seconds. Returns the receipt, or null.
///
/// A spent nonce alone does not drop a move: its own transaction may have spent it, on a block that the node asked for
/// the receipt has not reached yet. The move is dropped only when a look ORPHAN_SECONDS after the first that found it so
/// still finds no receipt; a lookup that fails is thrown, never taken for a missing receipt (RS-5).
export async function resumeMove({ client, address, journal, move, now = () => Math.floor(Date.now() / 1000) }) {
  const receipt = await receiptOf(client, move.data.hash);
  if (receipt) {
    journal.advance(move.id, "sent", { block: receipt.blockNumber.toString(), status: receipt.status });
    return receipt;
  }
  const nonce = await client.getTransactionCount({ address, blockTag: "latest" });
  if (nonce > move.data.nonce) {
    const since = move.data.orphanSince;
    if (since === undefined) journal.note(move.id, { orphanSince: now() });
    else if (now() - since >= ORPHAN_SECONDS) journal.drop(move.id, "its nonce was used by another transaction");
    return null;
  }
  await client.sendRawTransaction({ serializedTransaction: move.data.raw }).catch(() => {});
  return null;
}

/// The receipt of `hash`, or null when the node has none.
async function receiptOf(client, hash) {
  try {
    return await client.getTransactionReceipt({ hash });
  } catch (error) {
    if (error?.name === "TransactionReceiptNotFoundError") return null;
    throw error;
  }
}
