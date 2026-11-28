// The coins the keeper's fills are short of, written for the restock service (keeper/restock.mjs) to bring in. The
// keeper reports each fill, start and request it checks; the restock service reads the board and adds what each coin
// needs. No dependencies, so the unit tests run without `npm install`.

import { existsSync, readFileSync } from "node:fs";

/// A report older than this is dropped: whatever it was for was filled, expired, or stopped being checked.
export const NEEDS_MAX_AGE_SECONDS = 900;

/// The board. `write(text)` stores it (the keeper writes a file, atomically); `now()` is the clock, in seconds.
/// `report(key, source, coins)` replaces what `key` (a fill's `index:proposal`, a start's, or `request:id`) needs, an
/// empty `coins` clearing it; each coin is `{token, amount}`, the whole of that coin the fill needs, not the part stock
/// lacks, since one stock serves every fill. `flush({observed})` drops stale reports and writes the board.
///
/// The board is dated by the keeper's last round that looked at everything it reports on (`observed`), not by the
/// last time it was written. A round that failed, or that stopped behind a transaction in flight, saw no need and
/// proved none absent: flushed as fresh, its board would read as "nothing is needed" once the reports of the rounds
/// before it lapsed, and the restock would send the stock home. Dated by the last observation, such a board goes
/// stale instead, which the reader takes for unknown (CA-R2-02, RS-8). Before the first observation nothing is
/// written, so a board left by an earlier run stands until it lapses.
export function createNeeds({ write, now = () => Math.floor(Date.now() / 1000) }) {
  const board = new Map(); // key -> {source, coins, seenAt}
  let observedAt = null;
  return {
    report(key, source, coins) {
      if (coins.length === 0) board.delete(key);
      else board.set(key, { source, coins, seenAt: now() });
    },
    flush({ observed = true } = {}) {
      const t = now();
      if (observed) observedAt = t;
      for (const [key, entry] of board) if (t - entry.seenAt > NEEDS_MAX_AGE_SECONDS) board.delete(key);
      if (observedAt === null) return;
      const needs = [];
      for (const [key, { source, coins, seenAt }] of board) {
        for (const { token, amount } of coins) needs.push({ key, source, token: token.toLowerCase(), amount: amount.toString(), seenAt });
      }
      write(`${JSON.stringify({ updatedAt: observedAt, needs })}\n`);
    },
  };
}

/// How far ahead of the reader's clock a board's times may run before the board is refused: the keeper and the
/// restock run on one machine, or two that keep time.
export const NEEDS_MAX_SKEW_SECONDS = 60;
const TOKEN = /^0x[0-9a-f]{40}$/;
const AMOUNT = /^(0|[1-9][0-9]*)$/;
const isTime = (x, nowSeconds) => Number.isInteger(x) && x >= 0 && x <= nowSeconds + NEEDS_MAX_SKEW_SECONDS;

/// What each coin needs across every fresh report on the board `text`, by lowercased token: the sum of the reports,
/// from which the restock service subtracts the usable stock and what is already on its way. A board that is
/// unreadable, or that the keeper has not dated for NEEDS_MAX_AGE_SECONDS, is unknown: null, never an empty board,
/// which would send every coin home (RS-8). So is a board any part of which is not what the keeper writes: a time
/// that is no whole second or lies ahead of the clock, a token that is no address, an amount that is no whole number.
/// Read loosely, such an entry counted as fresh for ever or dropped out of the sum, and a real need read as none
/// (CA-L6).
export function totalNeeds(text, nowSeconds) {
  let board;
  try {
    board = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isTime(board?.updatedAt, nowSeconds) || !Array.isArray(board.needs)) return null;
  if (nowSeconds - board.updatedAt > NEEDS_MAX_AGE_SECONDS) return null;
  const total = new Map();
  for (const n of board.needs) {
    if (!isTime(n?.seenAt, nowSeconds) || typeof n.token !== "string" || typeof n.amount !== "string") return null;
    const token = n.token.toLowerCase();
    if (!TOKEN.test(token) || !AMOUNT.test(n.amount)) return null;
    if (nowSeconds - n.seenAt > NEEDS_MAX_AGE_SECONDS) continue;
    total.set(token, (total.get(token) ?? 0n) + BigInt(n.amount));
  }
  return total;
}

/// The board in `file`, as {totalNeeds} reads it; null, unknown, when the keeper has not written it (RS-8).
export function readNeeds(file, nowSeconds) {
  return existsSync(file) ? totalNeeds(readFileSync(file, "utf8"), nowSeconds) : null;
}
