// The coins the keeper's fills are short of, written for the restock service (keeper/restock.mjs) to bring in. The
// keeper reports each fill, start and request it checks; the restock service reads the board and adds what each coin
// needs. No dependencies, so the unit tests run without `npm install`.

import { existsSync, readFileSync } from "node:fs";

/// A report older than this is dropped: whatever it was for was filled, expired, or stopped being checked.
export const NEEDS_MAX_AGE_SECONDS = 900;

/// The board. `write(text)` stores it (the keeper writes a file, atomically); `now()` is the clock, in seconds.
/// `report(key, source, coins)` replaces what `key` (a fill's `index:proposal`, a start's, or `request:id`) needs, an
/// empty `coins` clearing it; each coin is `{token, amount}`, the whole of that coin the fill needs, not the part stock
/// lacks, since one stock serves every fill. `flush()` drops stale reports and writes the board.
export function createNeeds({ write, now = () => Math.floor(Date.now() / 1000) }) {
  const board = new Map(); // key -> {source, coins, seenAt}
  return {
    report(key, source, coins) {
      if (coins.length === 0) board.delete(key);
      else board.set(key, { source, coins, seenAt: now() });
    },
    flush() {
      const t = now();
      for (const [key, entry] of board) if (t - entry.seenAt > NEEDS_MAX_AGE_SECONDS) board.delete(key);
      const needs = [];
      for (const [key, { source, coins, seenAt }] of board) {
        for (const { token, amount } of coins) needs.push({ key, source, token: token.toLowerCase(), amount: amount.toString(), seenAt });
      }
      write(`${JSON.stringify({ updatedAt: t, needs })}\n`);
    },
  };
}

/// What each coin needs across every fresh report on the board `text`, by lowercased token: the sum of the reports,
/// from which the restock service subtracts the usable stock and what is already on its way. A board that is
/// unreadable, or that the keeper, which writes it every block, has not written for NEEDS_MAX_AGE_SECONDS, is unknown:
/// null, never an empty board, which would send every coin home (RS-8).
export function totalNeeds(text, nowSeconds) {
  let board;
  try {
    board = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof board?.updatedAt !== "number" || !Array.isArray(board.needs)) return null;
  if (nowSeconds - board.updatedAt > NEEDS_MAX_AGE_SECONDS) return null;
  const total = new Map();
  for (const n of board.needs) {
    if (nowSeconds - n.seenAt > NEEDS_MAX_AGE_SECONDS) continue;
    total.set(n.token, (total.get(n.token) ?? 0n) + BigInt(n.amount));
  }
  return total;
}

/// The board in `file`, as {totalNeeds} reads it; null, unknown, when the keeper has not written it (RS-8).
export function readNeeds(file, nowSeconds) {
  return existsSync(file) ? totalNeeds(readFileSync(file, "utf8"), nowSeconds) : null;
}
