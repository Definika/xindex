// The Solana signer's arithmetic and byte checks, with no dependency, so the keeper's unit tests cover them without
// installing the signer's libraries (keeper/test/unit/restock-solana.test.mjs).

/// The most compute a transaction may ask for.
export const MAX_COMPUTE_UNITS = 1_400_000;

/// The final compute unit limit for a transaction that consumed `units` in simulation: 1.2 times, as Jupiter's docs
/// recommend, within the cap.
export const unitLimit = (units) => Math.min(MAX_COMPUTE_UNITS, Math.ceil(units * 1.2));

/// The micro-lamports a compute budget `SetComputeUnitPrice` instruction (index 3, then a u64) sets, from its data, or
/// null for any other instruction.
export function unitPriceOf(data) {
  const bytes = Buffer.from(data);
  return bytes.length === 9 && bytes[0] === 3 ? bytes.readBigUInt64LE(1) : null;
}

export { slippageFor } from "../bounds.mjs";

/// An SPL token account's balance, from its data (the amount is the u64 at byte 64), or zero for no account.
export function tokenAmount(data) {
  if (!data || data.length < 72) return 0n;
  return Buffer.from(data).readBigUInt64LE(64);
}

/// What could let anyone but the wallet (its 32 key bytes, `wallet`) move a token account's coins later, which no
/// balance shows: an owner other than the wallet (bytes 32..64), a delegate (the COption tag at byte 72) or a close
/// authority (the tag at byte 129). Null when the account is the wallet's alone, or when there is no account.
export function foreignControl(data, wallet) {
  if (!data || data.length < 165) return null;
  const bytes = Buffer.from(data);
  if (!bytes.subarray(32, 64).equals(Buffer.from(wallet))) return "its owner is not the wallet";
  if (bytes.readUInt32LE(72) !== 0) return "it has a delegate";
  if (bytes.readUInt32LE(129) !== 0) return "it has a close authority";
  return null;
}
