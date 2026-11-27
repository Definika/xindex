// The invariant checker's properties: what must hold of a WeightedHub, MintRequests and the BasketBuilder at any one
// block, evaluated on reads invariants.mjs takes at that block. No dependencies, so the unit tests run without
// `npm install`.
//
// A finding is { level, code, ...detail }:
//   breach  a property of the contracts is false: page someone.
//   reader  the checker could not trust its own reads (a storage layout that disagrees with the views): the index's
//           properties were not evaluated, which is itself worth a look.
//   notice  worth knowing, not a breach: a component whose balanceOf reverts (a frozen or dead token, which the keep
//           mask and redeemSkipping exist for), and the admin events monitors watch (RT-07).

const WAD = 10n ** 18n;
/// `_backing`'s divisor: SHARE_UNIT * WAD.
const BACKING_DIVISOR = 10n ** 36n;
const MASK_160 = (1n << 160n) - 1n;
const MASK_128 = (1n << 128n) - 1n;
const MASK_40 = (1n << 40n) - 1n;
/// A keep mask must leave this many components moving (MIN_COMPONENTS).
const MIN_MOVING = 2n;

/// An address as the checker compares it: lowercase hex.
export const lower = (address) => address.toLowerCase();

/// A `_components` element's word: the token in the low 20 bytes, the units in the 12 above.
export function componentWord(word) {
  const w = BigInt(word);
  return { token: `0x${(w & MASK_160).toString(16).padStart(40, "0")}`, units: w >> 160n };
}

/// Slot 3's word: `_scale` (uint128), `_lastAccrual` (uint40), `_maskedFill` (bool), from the low bytes up.
export function scaleWord(word) {
  const w = BigInt(word);
  return { scale: w & MASK_128, lastAccrual: (w >> 128n) & MASK_40, maskedFill: ((w >> 168n) & 0xffn) !== 0n };
}

/// How many bits `mask` sets.
export function popcount(mask) {
  let count = 0n;
  for (let m = mask; m !== 0n; m &= m - 1n) count += 1n;
  return count;
}

/// The raw amount of a component that `supply` shares require at `scale`, as `_backing` rounds it for the invariant:
/// floor(supply * units * scale / 1e36).
export const required = (supply, units, scale) => (supply * units * scale) / BACKING_DIVISOR;

/// The checks on one index at one block. `s` holds, all read at that block:
///   index, now (the block's timestamp), rebalanceDelay
///   tokens, viewUnits      componentTokens() and components()'s units (at the pending scale)
///   pendingScale           pendingStreamingFee()'s scale
///   lastAccrual            lastAccrual()
///   length, words, word3   slot 0, the component words, slot 3 (HUB_STATE_SLOTS)
///   supply                 totalSupply()
///   claims, balances       totalClaims(token) and token.balanceOf(index), per component; a balance is null when
///                          balanceOf reverted
///   eta, keepMask          pendingRebalance()
///   earliest, restartAllowedAt, proposalCount, rebalanceNonce
/// The properties are the hub's invariant (CLAUDE.md, "Invariant") and the rebalance state machine's I1 to I4
/// (docs/design/rebalance-state-machine.md, section 5).
export function checkIndex(s) {
  const at = { index: lower(s.index) };
  const n = BigInt(s.tokens.length);

  // The reads first: storage the views do not return is trusted only while it reproduces what the views do.
  const reader = (why) => [{ level: "reader", code: "layout", ...at, why }];
  if (BigInt(s.length) !== n) return reader(`slot 0 holds ${s.length} components, componentTokens() ${n}`);
  if (s.words.length !== s.tokens.length) return reader("a component word is missing");
  const recorded = s.words.map(componentWord);
  const { scale, lastAccrual } = scaleWord(s.word3);
  for (let i = 0; i < recorded.length; ++i) {
    if (recorded[i].token !== lower(s.tokens[i])) return reader(`component ${i}'s word names ${recorded[i].token}`);
  }
  if (lastAccrual !== s.lastAccrual) return reader(`slot 3's lastAccrual is ${lastAccrual}, lastAccrual() ${s.lastAccrual}`);
  if (scale === 0n || s.pendingScale > scale) return reader(`slot 3's scale ${scale} is below the pending ${s.pendingScale}`);
  for (let i = 0; i < recorded.length; ++i) {
    if ((recorded[i].units * s.pendingScale) / WAD !== s.viewUnits[i]) {
      return reader(`component ${i}'s recorded units ${recorded[i].units} do not give components()'s ${s.viewUnits[i]}`);
    }
  }

  const findings = [];
  const breach = (code, detail) => findings.push({ level: "breach", code, ...at, ...detail });

  // The invariant: every component's balance covers the recorded supply's backing at the recorded scale, plus claims.
  for (let i = 0; i < recorded.length; ++i) {
    const token = recorded[i].token;
    if (s.balances[i] === null) {
      findings.push({ level: "notice", code: "unreadable", ...at, token, why: "balanceOf reverts" });
      continue;
    }
    const need = required(s.supply, recorded[i].units, scale) + s.claims[i];
    if (s.balances[i] < need) {
      breach("backing", { token, balance: s.balances[i], required: need, shortfall: need - s.balances[i] });
    }
  }
  if (scale > WAD) breach("scale", { scale, why: "the scale only ever shrinks from 1e18" });

  // The pending auction and its clock.
  if (s.eta === 0n) {
    if (s.keepMask !== 0n) breach("keep-mask", { keepMask: s.keepMask, why: "a keep mask with no proposal" });
  } else {
    if (s.keepMask >> n !== 0n || n - popcount(s.keepMask) < MIN_MOVING) {
      breach("keep-mask", { keepMask: s.keepMask, why: "the mask reaches past the components or leaves one moving" });
    }
    // I1: a proposal exists only after the interval, which no start can skip.
    if (s.earliest + s.rebalanceDelay > s.eta) {
      breach("clock", { eta: s.eta, earliest: s.earliest, why: "I1: a proposal started before the interval ended" });
    }
    // I2: no proposal starts before the cooldown a cancel set.
    if (s.restartAllowedAt > s.eta) {
      breach("clock", { eta: s.eta, restartAllowedAt: s.restartAllowedAt, why: "I2: a proposal before the cooldown" });
    }
  }
  // I3: the cooldown and the interval never hold at once.
  if (s.restartAllowedAt > s.now && s.earliest > s.now) {
    breach("clock", { restartAllowedAt: s.restartAllowedAt, earliest: s.earliest, why: "I3: cooldown and interval" });
  }
  // I4: every fill settles a proposal.
  if (s.rebalanceNonce > s.proposalCount) {
    breach("counters", { proposalCount: s.proposalCount, rebalanceNonce: s.rebalanceNonce, why: "I4: a fill with no start" });
  }
  return findings;
}

/// What an index's recorded state, as `checkIndex` decoded it, keeps from one round to the next: `prev` and `cur` are
/// { tokens, units, scale, proposalCount, rebalanceNonce, lastRebalance }. The components never change; the units move
/// only at a fill, which raises the nonce; the scale only shrinks; the counters and the last fill never go back.
export function checkProgress(index, prev, cur) {
  const at = { level: "breach", index: lower(index) };
  const findings = [];
  if (prev.tokens.join() !== cur.tokens.join()) findings.push({ ...at, code: "components", why: "the components changed" });
  else if (cur.rebalanceNonce === prev.rebalanceNonce && prev.units.some((u, i) => u !== cur.units[i])) {
    findings.push({ ...at, code: "units", why: "the units moved without a fill" });
  }
  if (cur.scale > prev.scale) findings.push({ ...at, code: "scale", why: `the scale rose from ${prev.scale} to ${cur.scale}` });
  for (const key of ["proposalCount", "rebalanceNonce", "lastRebalance"]) {
    if (cur[key] < prev[key]) findings.push({ ...at, code: "counters", why: `${key} fell from ${prev[key]} to ${cur[key]}` });
  }
  return findings;
}

/// `escrows` is a list of { token, amount }; `balances` maps a lowercase token to the holder's balance, null where the
/// read failed. Every token's escrows must be covered by what the holder has: MintRequests' open requests, or the
/// BasketBuilder's escrows. A balance that could not be read is not a balance of zero: it is a reader finding, where
/// a zero would have reported the whole escrow as a shortfall nobody measured (CA-L9).
export function checkEscrows(code, holder, escrows, balances) {
  const owed = new Map();
  for (const { token, amount } of escrows) owed.set(lower(token), (owed.get(lower(token)) ?? 0n) + amount);
  const findings = [];
  for (const [token, amount] of owed) {
    const balance = balances.get(token) ?? null;
    if (balance === null) {
      findings.push({ level: "reader", code: "unreadable", holder: lower(holder), token, why: "balanceOf could not be read" });
      continue;
    }
    if (balance < amount) {
      findings.push({ level: "breach", code, holder: lower(holder), token, balance, owed: amount, shortfall: amount - balance });
    }
  }
  return findings;
}

/// What MintRequests holds for a request: the stablecoin of a mint request, the index's shares of a redeem request.
export const requestEscrow = (r) => ({ token: r.isMint ? r.stable : r.index, amount: r.open ? r.escrow : 0n });

/// A finding's identity across rounds, so a standing breach is reported when it appears and when it clears, not every
/// round.
export function findingKey(f) {
  return [f.code, f.index ?? f.holder ?? "", f.token ?? "", f.why ?? ""].join(":");
}

/// What a round's own findings say it could not look at: a reader finding names a contract whose properties were not
/// evaluated, and with a token, or as an unreadable component, the one balance that was not read.
const unseenBy = (findings) =>
  findings.filter((f) => f.level === "reader" || f.code === "unreadable").map((f) => ({ scope: f.index ?? f.holder ?? "", token: f.token }));

/// The findings of this round against the keys standing from the last: the ones raised and the keys cleared. A
/// standing finding on something this round could not look at is neither: no read showed it gone, so it stands until
/// one does. Dropped from the round for want of a read, it used to be announced as cleared (CA-M17).
export function diffFindings(standing, findings) {
  const now = new Map(findings.map((f) => [findingKey(f), f]));
  const unseen = unseenBy(findings);
  const held = (key) => {
    const [, scope, token] = key.split(":");
    return unseen.some((u) => u.scope === scope && (u.token === undefined || u.token === token));
  };
  const raised = [...now].filter(([key]) => !standing.has(key)).map(([, f]) => f);
  const gone = [...standing].filter((key) => !now.has(key));
  return { raised, cleared: gone.filter((key) => !held(key)), standing: new Set([...now.keys(), ...gone.filter(held)]) };
}

/// The RPC's latest block against the clock: a head older than `maxAgeSeconds` is a reader finding. A node that
/// answers but has stopped following the chain serves the same healthy block for ever, and every round on it found
/// nothing (CA-R2-14). The age is not part of the finding's identity, so a stalled head is raised once.
export function checkHead(blockTimestamp, nowSeconds, maxAgeSeconds) {
  const age = nowSeconds - Number(blockTimestamp);
  if (age <= maxAgeSeconds) return [];
  return [{ level: "reader", code: "stale-head", age, why: "the RPC's latest block is older than MAX_HEAD_AGE_SECONDS" }];
}

/// A range read forward, once: block numbers, or request ids. `step(to, read)` hands `read(from, to)` what has not
/// been read yet and moves past it only once `read` has returned. A read that throws leaves its range to the next
/// round: moved first, the cursor skipped for good every request and every event of a round whose read failed
/// (CA-M16). `first` is where the range starts; null starts it at the first `to` it is asked for, and keeps that
/// start through any number of failed reads.
export function createCursor(first = null) {
  let next = first;
  return async function step(to, read) {
    if (next === null) next = to;
    if (next > to) return undefined;
    const answer = await read(next, to);
    next = to + 1n;
    return answer;
  };
}

/// The alerts on their way to the webhook, oldest first. `send(record)` resolves true once the webhook has taken the
/// record. `flush()` sends what is queued and stops at the first the webhook does not take, which stays queued with
/// everything after it for the next round: an alert the webhook answered 503 to used to count as sent, and a breach
/// is raised only once (CA-M18). At most `limit` are kept, the oldest dropped first, which `flush` reports.
export function createAlerts({ send, limit = 500 }) {
  const queue = [];
  let dropped = 0;
  return {
    push(record) {
      queue.push(record);
      if (queue.length > limit) {
        queue.shift();
        dropped += 1;
      }
    },
    async flush() {
      while (queue.length) {
        if (!(await send(queue[0]))) break;
        queue.shift();
      }
      const lost = dropped;
      dropped = 0;
      return { queued: queue.length, dropped: lost };
    },
  };
}

/// The factory's admin events and the hubs' auction events the checker prints as notices (RT-07). Every start is
/// one, plain or masked, and so is the quote posted with one: the guardian's runbook replaces a stranger's plain
/// start, which it can only do if it sees it (CA-L10). `test/unit/invariants.test.mjs` holds each name against the
/// committed ABIs, where a renamed event used to stay on the list unnoticed.
export const FACTORY_NOTICES = Object.freeze([
  "GuardianProposed",
  "GuardianChangeCancelled",
  "GuardianSet",
  "OwnershipTransferStarted",
  "OwnershipTransferred",
  "ListingProposed",
  "ListingCancelled",
  "TokenWhitelisted",
  "TokenDecimalsSet",
  "FeePolicySet",
  "CreatorApprovalSet",
]);
export const HUB_NOTICES = Object.freeze(["RebalanceStarted", "RebalanceQuoted", "RebalanceCancelled"]);
