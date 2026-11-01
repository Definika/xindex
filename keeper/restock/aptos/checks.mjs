// The Aptos signer's decisions, with no dependency, so the keeper's unit tests cover them without installing the
// signer's libraries (keeper/test/unit/restock-aptos.test.mjs): what became of a transaction in flight, and what a
// Panora swap may carry.

/// An Aptos address as 0x and 64 lowercase hex digits.
export const normAddress = (a) => `0x${String(a).toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;

/// What became of transaction `hash`, the wallet's sequence number `sequence`, expiring at `expire` (unix seconds) and
/// built at ledger version `sentVersion` (null when its expiry names none), from two answers read in this order, each
/// with the ledger headers it carried (every Aptos answer carries its node's version, oldest kept version and time):
/// - `account`: `{sequence, ledgerVersion, ledgerTimestamp}`, the wallet's account;
/// - `byHash`: `{found, ledgerVersion, oldestVersion}`, the hash lookup, `found` being `{pending: true}`,
///   `{success, version}`, or null when that node has no such transaction.
/// A passed sequence number proves the transaction never landed only from a hash lookup on a node at or past the
/// account's version, which would hold it had it taken that number, and that still keeps the versions since it was
/// built; a node behind, the hash lookup reaching a node a moment older than the account read's, proves nothing (PD-4).
export function aptosFate({ sequence, expire, sentVersion = null, account, byHash }) {
  const found = byHash?.found;
  if (found?.pending) return { state: "pending" };
  if (found) return { state: found.success ? "landed" : "reverted", at: String(found.version ?? "") };
  if (BigInt(account.sequence) > BigInt(sequence)) {
    if (BigInt(byHash.ledgerVersion) < BigInt(account.ledgerVersion)) return { state: "pending" };
    if (sentVersion === null || BigInt(byHash.oldestVersion) > BigInt(sentVersion)) {
      return { state: "unknown", reason: `the node keeps versions from ${byHash.oldestVersion} only, not from ${sentVersion}, when the transaction was built` };
    }
    return { state: "expired", reason: `its sequence number ${sequence} went to another transaction` };
  }
  if (BigInt(account.ledgerTimestamp) >= BigInt(expire) * 1_000_000n) return { state: "expired", reason: `it expired at ${expire}` };
  return { state: "pending" };
}

/// Panora's integrator fee, as its router's last two arguments carry it when no fee is asked: 1e16, and Panora's own
/// address (read on 2026-11-02 on four swaps both ways; asking a 0.1% fee to an address set them to about 1.1e16 and
/// that address).
export const PANORA_NO_FEE = Object.freeze({
  amount: "10000000000000000",
  recipient: "0x90c588d22ee7dd42d55d73e63b50f0f9dfe7113952374040ae8c4adfd137176d",
});

/// Checks the arguments of Panora's `router_entry` (its answer's, as JSON) against the swap asked for: it pays
/// `address`, buys `to` (a metadata address), spends exactly `amountIn` across its splits (argument 16, one amount per
/// split, which may be several), and pays no integrator fee (arguments 18 and 19). Argument 17 is the minimum output,
/// which the caller sets to its floor and the router enforces (E_OUTPUT_LESS_THAN_MINIMUM_TRY_INCREASING_SLIPPAGE, read
/// by simulation on 2026-11-02) (PD-13).
export function checkPanoraArgs(args, { address, to, amountIn }) {
  if (!Array.isArray(args) || args.length !== 20) throw new Error(`Panora's swap has ${args?.length} arguments, not its router's 20`);
  if (normAddress(args[1]) !== normAddress(address)) throw new Error("Panora's swap pays someone else");
  if (normAddress(args[15]) !== normAddress(to)) throw new Error("Panora's swap buys another token");
  const splits = args[16];
  if (!Array.isArray(splits) || splits.length === 0) throw new Error("Panora's swap names no amount");
  const total = splits.reduce((sum, x) => sum + BigInt(x), 0n);
  if (total !== amountIn) throw new Error(`Panora's swap spends ${total}, not ${amountIn}`);
  if (String(args[18]) !== PANORA_NO_FEE.amount || normAddress(args[19]) !== PANORA_NO_FEE.recipient) {
    throw new Error(`Panora's swap pays an integrator fee (${args[18]} to ${args[19]})`);
  }
}
