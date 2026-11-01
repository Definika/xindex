// The Sui signer's decisions, with no dependency, so the keeper's unit tests cover them without installing the
// signer's libraries (keeper/test/unit/restock-sui.test.mjs): what became of a transaction in flight, and the two
// guards on a Cetus swap.

/// Whether `error`, from the Sui SDK's object read, says the object does not exist: its ObjectError for a missing
/// object (code `notExists`, reason `notFound`). Any other failure, a timeout or a rate limit, says nothing about it.
export const missingObject = (error) => error?.code === "notExists" || error?.reason === "notFound";

/// Whether `error`, from the Sui SDK's transaction read, says the node has no such transaction (TransactionError,
/// reason `notFound`).
export const missingTransaction = (error) => error?.reason === "notFound";

/// What became of transaction `digest`, signed with gas coins at their versions and valid until epoch `epoch`:
/// - `found`: the node's record of it, `{success, checkpoint}`, or null when the node has none;
/// - `coins`: each gas coin, `{objectId, version}` as signed, with `read`, the coin now (`{version,
///   previousTransaction}`) or null when it no longer exists;
/// - `epochNow`: the current epoch.
/// A gas coin that moved on without this transaction proves it can never execute; an error reading one proves nothing,
/// so the caller reads again rather than call it gone (PD-5).
export function suiFate({ digest, found, coins, epochNow, epoch }) {
  if (found) return { state: found.success ? "landed" : "reverted", at: String(found.checkpoint ?? "") };
  for (const c of coins) {
    // A gas coin this transaction moved: it executed, and the node has not served it yet.
    if (c.read?.previousTransaction === digest) return { state: "pending" };
    if (c.read === null) return { state: "expired", reason: `its gas coin ${c.objectId} no longer exists` };
    if (String(c.read.version) !== String(c.version)) return { state: "expired", reason: `its gas coin ${c.objectId} moved to another version` };
  }
  if (BigInt(epochNow) > BigInt(epoch)) return { state: "expired", reason: `its expiry epoch ${epoch} ended` };
  return { state: "pending" };
}

/// Checks the aggregator package a Cetus route names (its answer's `packages`, a Map or an object, key
/// `aggregator_v3`): the package that receives the input coin and confirms the swap. None named means the SDK's own,
/// `pinned`; another must be an upgrade of it, the same original package, which `originalOf(id)` reads on chain. A
/// package the answer chose otherwise is refused (PD-3).
export async function checkAggregator(packages, pinned, originalOf) {
  const named = packages instanceof Map ? packages.get("aggregator_v3") : packages?.aggregator_v3;
  if (named === undefined || named === null || named === pinned) return;
  const [theirs, ours] = await Promise.all([originalOf(named), originalOf(pinned)]);
  if (theirs !== ours) throw new Error(`Cetus's route names aggregator package ${named}, which is not an upgrade of ${pinned}`);
}

/// Pays the swap's `output` coin to `address` with the floor held inside the transaction: Sui's own `splitCoins`
/// aborts the whole transaction when `output` holds less than `share`, whatever the route's packages did (PD-3).
/// `tx` is the SDK's Transaction.
export function payWithFloor(tx, output, share, address) {
  const [floor] = tx.splitCoins(output, [tx.pure.u64(share)]);
  tx.transferObjects([floor, output], address);
}
