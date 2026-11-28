// Every move the restock service makes, from the moment its transaction is signed: a trade, a bridge transfer, a CCTP
// transfer, a UniswapX order or a deposit into the executor. A move is recorded signed before it is broadcast, so a restart sends that same signed transaction
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
  /// A UniswapX order (`uniswapx.mjs`): signed and recorded, posted to the API's fillers, and done once Permit2 shows its
  /// nonce spent. One that passed its deadline unfilled is dropped (`expired`).
  order: ["signed", "sent", "done"],
  /// The treasury's deposit of a coin it bought into the executor (`depositStock`).
  deposit: ["signed", "sent", "done"],
});

const DAY = 86_400;

/// `moves`, the journal's pending ones, in the order a round takes them: every signed move first, so each signer learns
/// of the transaction it may have in flight before it is asked to build anything else, a completing step included
/// (PD-9); then the rest. Each group keeps its order, oldest first.
export function resumeOrder(moves) {
  return [...moves.filter((m) => m.stage === "signed"), ...moves.filter((m) => m.stage !== "signed")];
}

/// `load()` returns the saved text or null; `save(text)` stores it; `now()` is the clock, in seconds.
/// What a move is about, as the plan names what it leaves alone: the treasury for a draw or a repayment, the chain
/// for a funding or a sweep, and the coin for a trade, a bridge transfer, an order or a deposit.
export const subjectOf = (move) =>
  move.kind === "draw" || move.kind === "repay" ? "treasury" : move.kind === "fund" || move.kind === "sweep" ? move.chain : move.coin;

/// Everything a move touches: its subject, and for a UniswapX order the treasury too, whose USDC the order may take.
const subjectsOf = (move) => (move.kind === "order" ? [move.coin, "treasury"] : [subjectOf(move)]);

/// What the plan of a round leaves alone because a move of the journal moved on in that very round: the subject of
/// each move of `before`, the moves still to settle when the round began, whose stage `stageNow(id)` no longer is
/// the one it had. Such a move may have settled a moment ago, by a transaction the round itself sent, and the state
/// the plan is made from is then read at a node's latest block: a node one block behind shows the coin still short,
/// or the float still unfunded, and the plan bought or funded it a second time (RZ-19). The next round reads it
/// settled.
export const movedOn = (before, stageNow) => new Set(before.filter((m) => stageNow(m.id) !== m.stage).flatMap(subjectsOf));

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
        maxUsd: action.maxUsd ?? action.usd ?? null,
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
    /// reverted, or its order passed its deadline unfilled, so nothing it committed left the wallet.
    drop(id, reason) {
      change((s) => {
        const m = s.moves[id];
        if (settled(m)) throw new Error(`move ${id} has settled (${m.stage})`);
        const reverted = m.stage === "sent" && m.data.status === "reverted";
        const expired = m.kind === "order" && m.data.status === "expired";
        if (m.stage !== "signed" && !reverted && !expired) {
          throw new Error(`move ${id} was sent: only an unsent, reverted or expired move is dropped`);
        }
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
    /// The coins, chains and "treasury" with a move still to settle: a trade's or a deposit's coin, an order's coin and
    /// the treasury, whose USDC it may take until it settles, a funding's or sweep's chain, a draw's or repayment's
    /// treasury, and a bridge transfer's coin until its transaction is out, after which the transfer counts as in
    /// flight instead.
    busy() {
      const busy = new Set();
      for (const m of Object.values(state.moves)) {
        if (settled(m)) continue;
        if (m.kind === "order") subjectsOf(m).forEach((x) => busy.add(x));
        else if (m.kind === "buy" || m.kind === "sell" || m.kind === "deposit") busy.add(m.coin);
        else if (m.kind === "draw" || m.kind === "repay") busy.add("treasury");
        else if (m.kind === "fund" || m.kind === "sweep") busy.add(m.chain);
        else if (m.stage === "signed") busy.add(m.coin);
      }
      return busy;
    },
    /// The most the buys of the last day may have cost, the dropped ones aside, a UniswapX order's among them: each
    /// one's worth at Pyth and the loss bound its swap was held to (`maxUsd`, CA-M13); a move recorded before that field
    /// counts at its worth.
    spentUsd() {
      const since = now() - DAY;
      let usd = 0;
      for (const m of Object.values(state.moves)) {
        if ((m.kind === "buy" || m.kind === "order") && m.stage !== "dropped" && m.at >= since) usd += m.maxUsd ?? m.usd;
      }
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

/// Whether process `pid` still runs: signal 0 reaches it, or is refused for want of permission, which only a live
/// process can answer.
function running(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

/// Takes the journal in `path` for this process: a lock file beside it that names the process, which a second
/// writer finds and stops at. Each writer loads the journal once and saves it whole after every change, so two of
/// them, a restart overlapping the process it replaces or a one-shot run beside the service, each erased the moves the
/// other had recorded (CA-M12). A lock left by a process that is gone, or by this very pid in a container that always
/// starts at the same one, is taken over. Returns `release()`, which removes the lock if it is still this process's.
export function lockJournal(path, { fs = nodeFs, pid = process.pid, alive = running } = {}) {
  const lock = `${path}.lock`;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.writeFileSync(lock, `${pid}\n`, { flag: "wx" });
      return () => {
        if (fs.existsSync(lock) && fs.readFileSync(lock, "utf8").trim() === String(pid)) fs.unlinkSync(lock);
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const holder = Number(fs.readFileSync(lock, "utf8").trim());
      if (Number.isInteger(holder) && holder > 0 && holder !== pid && alive(holder)) {
        throw new Error(
          `another restock process (pid ${holder}) holds the journal ${path}: two writers erase each other's moves. If none is running, remove ${lock}`,
        );
      }
      fs.unlinkSync(lock);
    }
  }
  throw new Error(`the journal's lock ${lock} could not be taken`);
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
