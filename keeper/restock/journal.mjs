// Every move the restock service makes, from the moment its transaction is signed: a trade, a bridge transfer or a
// CCTP transfer. A move is recorded signed before it is broadcast, so a restart sends that same signed transaction
// again, which a chain counts once, rather than signing a second one. Each move then only moves forward through its
// stages until it settles or is dropped (a signed transaction that expired unsent). The whole journal is saved after
// every change through an injected store. No dependencies.

import * as nodeFs from "node:fs";
import { dirname } from "node:path";

/// Each kind's stages, in order; the last one settles the move.
export const STAGES = Object.freeze({
  buy: ["signed", "sent", "done"],
  sell: ["signed", "sent", "done"],
  draw: ["signed", "sent", "done"],
  repay: ["signed", "sent", "done"],
  bridgeIn: ["signed", "sent", "attested", "redeemed"],
  bridgeOut: ["signed", "sent", "attested", "redeemed"],
  fund: ["signed", "sent", "attested", "received"],
  sweep: ["signed", "sent", "attested", "received"],
});

const DAY = 86_400;

/// `load()` returns the saved text or null; `save(text)` stores it; `now()` is the clock, in seconds.
export function createJournal({ load, save, now = () => Math.floor(Date.now() / 1000) }) {
  let state = parse(load());
  const settled = (m) => m.stage === "dropped" || m.stage === STAGES[m.kind].at(-1);
  /// Applies `mutate` to a copy of the journal and keeps the copy only once it is saved: a change whose save fails is
  /// not kept, so no move the disk does not hold is ever resumed and sent (RS-13). Returns what `mutate` returns.
  const change = (mutate) => {
    const next = structuredClone(state);
    const out = mutate(next);
    save(`${JSON.stringify(next, null, 1)}\n`);
    state = next;
    return out;
  };

  return {
    /// Records `action` (a plan's) as signed, with `data` (the signed transaction and its hash), and returns its id.
    open(action, data) {
      if (!STAGES[action.kind]) throw new Error(`unknown move kind ${action.kind}`);
      const amount = action.amount ?? action.amountIn;
      return change((s) => {
        const id = String(s.next++);
        s.moves[id] = {
        id,
        kind: action.kind,
        coin: action.coin ?? null,
        copy: action.copy ?? null,
        chain: action.chain ?? null,
        amount: amount === undefined ? null : amount.toString(),
        usd: action.usd ?? null,
        stage: "signed",
        data,
        at: now(),
        updatedAt: now(),
      };
        return id;
      });
    },
    /// Moves `id` forward to `stage`, merging `data` into what it holds.
    advance(id, stage, data = {}) {
      change((s) => {
        const m = s.moves[id];
        const stages = STAGES[m.kind];
        if (settled(m)) throw new Error(`move ${id} has settled (${m.stage})`);
        if (stages.indexOf(stage) <= stages.indexOf(m.stage)) throw new Error(`move ${id} cannot go from ${m.stage} to ${stage}`);
        Object.assign(m, { stage, data: { ...m.data, ...data }, updatedAt: now() });
      });
    },
    /// Adds `data` to `id` without moving it on: what a later step learned, such as a redeeming transaction's hash.
    note(id, data) {
      change((s) => {
        const m = s.moves[id];
        Object.assign(m, { data: { ...m.data, ...data }, updatedAt: now() });
      });
    },
    /// Drops `id`, which can never complete: its signed transaction expired before any chain took it, or was mined and
    /// reverted, so nothing it committed left the wallet.
    drop(id, reason) {
      change((s) => {
        const m = s.moves[id];
        if (settled(m)) throw new Error(`move ${id} has settled (${m.stage})`);
        const reverted = m.stage === "sent" && m.data.status === "reverted";
        if (m.stage !== "signed" && !reverted) throw new Error(`move ${id} was sent: only an unsent or reverted move is dropped`);
        Object.assign(m, { stage: "dropped", data: { ...m.data, reason }, updatedAt: now() });
      });
    },
    get: (id) => state.moves[id],
    /// The moves still to settle, oldest first.
    pending: () => Object.values(state.moves).filter((m) => !settled(m)),
    /// What is crossing the bridge, by copy address: `in` toward the executor, `out` away from it.
    inflight() {
      const total = new Map();
      for (const m of Object.values(state.moves)) {
        if (settled(m) || (m.kind !== "bridgeIn" && m.kind !== "bridgeOut")) continue;
        const t = total.get(m.copy) ?? { in: 0n, out: 0n };
        if (m.kind === "bridgeIn") t.in += BigInt(m.amount);
        else t.out += BigInt(m.amount);
        total.set(m.copy, t);
      }
      return total;
    },
    /// USDC on its way to each home chain.
    funding() {
      const total = new Map();
      for (const m of Object.values(state.moves)) {
        if (!settled(m) && m.kind === "fund") total.set(m.chain, (total.get(m.chain) ?? 0n) + BigInt(m.amount));
      }
      return total;
    },
    /// The coins, chains and "treasury" with a move still to settle: a trade's coin, a funding's or sweep's chain, a
    /// draw's or repayment's treasury, and a bridge transfer's coin until its transaction is out, after which the
    /// transfer counts as in flight instead.
    busy() {
      const busy = new Set();
      for (const m of Object.values(state.moves)) {
        if (settled(m)) continue;
        if (m.kind === "buy" || m.kind === "sell") busy.add(m.coin);
        else if (m.kind === "draw" || m.kind === "repay") busy.add("treasury");
        else if (m.kind === "fund" || m.kind === "sweep") busy.add(m.chain);
        else if (m.stage === "signed") busy.add(m.coin);
      }
      return busy;
    },
    /// What the buys of the last day cost, the dropped ones aside.
    spentUsd() {
      const since = now() - DAY;
      let usd = 0;
      for (const m of Object.values(state.moves)) if (m.kind === "buy" && m.stage !== "dropped" && m.at >= since) usd += m.usd;
      return usd;
    },
    /// Forgets moves that settled more than `days` ago; a day's buys stay, for the budget.
    prune(days = 7) {
      const before = now() - Math.max(days, 1) * DAY;
      const old = Object.values(state.moves).filter((m) => settled(m) && m.updatedAt < before);
      if (old.length) change((s) => old.forEach((m) => delete s.moves[m.id]));
    },
  };
}

/// The saved journal `text`, or a fresh journal where there is none (null). Text that is empty or unreadable throws:
/// starting afresh would forget every move still in flight, and send again what it already sent (RS-13).
function parse(text) {
  if (text === null) return { next: 1, moves: {} };
  let state = null;
  try {
    state = JSON.parse(text);
  } catch {}
  if (typeof state?.next !== "number" || typeof state.moves !== "object" || state.moves === null) {
    throw new Error(
      "the journal is empty or unreadable: restore it from a copy, or move it away to start afresh, which forgets every move in it, those in flight among them",
    );
  }
  return state;
}

/// The journal kept in the file `path`, durably: written to a temporary file and flushed to the disk, renamed into
/// place, and the folder flushed, which makes the rename last, all before the transaction it records is sent, so a
/// power cut loses neither the entry nor the journal (RS-13). `fs` is node's, or a stand-in for tests.
export function fileStore(path, fs = nodeFs) {
  const tmp = `${path}.tmp`;
  const flushed = (file, flags, write = () => {}) => {
    const fd = fs.openSync(file, flags);
    try {
      write(fd);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  };
  return {
    load: () => (fs.existsSync(path) ? fs.readFileSync(path, "utf8") : null),
    save: (text) => {
      flushed(tmp, "w", (fd) => fs.writeFileSync(fd, text));
      fs.renameSync(tmp, path);
      flushed(dirname(path), "r");
    },
  };
}
