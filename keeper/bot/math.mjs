// The keeper's arithmetic and decisions, pure and dependency-free. Token amounts, gas and wei are BigInt throughout;
// dollars are floats, used only to decide, and turned into USDC's raw units by rounding toward the bot's safety.

const BPS = 10_000n;
const GWEI = 1_000_000_000n;

const ceilDiv = (a, b) => (a + b - 1n) / b;
export const min = (a, b) => (a < b ? a : b);
export const max = (a, b) => (a > b ? a : b);

/// `x` plus `bps` basis points, rounded up: a bound that must not fall short.
export const withTolerance = (x, bps) => ceilDiv(x * (BPS + BigInt(bps)), BPS);

/// Dollars as USDC's raw units (6 decimals), rounded up: used for floors, which must not fall below the decision.
export function usdToUsdcCeil(usd) {
  if (!Number.isFinite(usd)) throw new Error(`not a dollar amount: ${usd}`);
  return BigInt(Math.ceil(usd * 1e6));
}

/// A Pyth price (`{price, expo}`) in dollars per whole token.
export const priceUsd = (p) => Number(p.price) * 10 ** Number(p.expo);

/// The dollar value of `amount` raw units of a token with `decimals`, at Pyth price `p`.
export const amountUsd = (amount, decimals, p) => (Number(amount) / 10 ** Number(decimals)) * priceUsd(p);

/// An index's dollar value: `supply` shares, each backed by `units[i]` raw units of component i per 1e18 shares, at
/// the Pyth prices `prices` (one per component, in component order). A component with no price counts as nothing.
export function tvlUsd({ supply, units, decimals, prices }) {
  let tvl = 0;
  units.forEach((u, i) => {
    if (prices[i]) tvl += amountUsd((supply * u) / 10n ** 18n, decimals[i], prices[i]);
  });
  return tvl;
}

/// The open auctions worth evaluating this block: an index with shares, worth at least `minTvlUsd`, richest first, at
/// most `cap` of them. Anyone can open an auction on an empty index for the gas of a start, so an index's worth, not
/// its auction's existence, decides what the bot spends Hermes requests and simulations on (CF-7).
export const auctionsToEvaluate = (candidates, minTvlUsd, cap) =>
  candidates
    .filter((c) => c.supply > 0n && c.tvl >= minTvlUsd)
    .sort((a, b) => b.tvl - a.tvl)
    .slice(0, cap);

/// The open-auction rule the hub applies at the fill's own timestamp `T` (WeightedHub `_openMu`).
export const auctionOpen = (eta, T, duration) => eta !== 0n && eta <= T && T <= eta + duration;

/// How an inventory leg changes the executor's stock: an unrouted coin the index sells is kept, and a coin the index
/// needs comes from stock first. Routed sales go straight to USDC, so they leave stock unchanged.
export const inventoryDelta = ({ out, in: need, held, routed }) => (routed ? 0n : out) - min(held, need);

/// What a kept coin is worth to the bot: its value at Pyth, or the best quote the route search found for selling it,
/// in USDC's raw units, when that is lower (XS-5). A coin whose pools pay too far below Pyth for any route is exactly
/// the coin the bot keeps, so its Pyth value is the one it could not get. A coin whose pools exist but quoted nothing
/// (their sell side emptied, as a depegged copy's is) has a quote of 0n and counts as nothing. Only a coin with no
/// pool at all, `quoteUsdc` null, counts at Pyth.
export const keptUsd = (pythUsd, quoteUsdc) =>
  quoteUsdc === null || quoteUsdc === undefined ? pythUsd : Math.min(pythUsd, Number(quoteUsdc) / 1e6);

/// The dollar change one leg makes to the executor's stock: a coin the index sends out and no route sells is kept, at
/// {keptUsd}, and a coin the index needs comes out of stock first, at Pyth price `price`. `quoteUsdc` is the best
/// quote for selling `out`, or null.
export function stockChangeUsd({ out, in: need, held, routed, decimals, price, quoteUsdc = null }) {
  const delivered = amountUsd(inventoryDelta({ out: 0n, in: need, held, routed }), decimals, price);
  const kept = routed ? 0n : out;
  return kept > 0n ? delivered + keptUsd(amountUsd(kept, decimals, price), quoteUsdc) : delivered;
}

/// Calldata tokens as EIP-7623 counts them: a zero byte is one token, any other byte four.
export function calldataTokens(hex) {
  const body = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (body.length % 2 !== 0) throw new Error("odd-length hex");
  let zeros = 0n;
  let nonzeros = 0n;
  for (let i = 0; i < body.length; i += 2) {
    if (body[i] === "0" && body[i + 1] === "0") zeros++;
    else nonzeros++;
  }
  return zeros + 4n * nonzeros;
}

/// What a transaction with `data` costs when its call uses `inner` gas: EIP-7623 charges the larger of the standard
/// calldata cost plus execution and the calldata floor. `overhead` covers execution outside the measured call.
export function txGasUsed(inner, data, overhead = 30_000n) {
  const tokens = calldataTokens(data);
  return 21_000n + max(4n * tokens + inner + overhead, 10n * tokens);
}

/// The gas limit to send with: 20% above what the simulation used.
export const gasLimitFor = (used) => ceilDiv(used * 12n, 10n);

/// EIP-1559's base fee for the block after `block` ({baseFeePerGas, gasUsed, gasLimit}).
export function nextBaseFee({ baseFeePerGas, gasUsed, gasLimit }) {
  const target = gasLimit / 2n;
  if (target === 0n || gasUsed === target) return baseFeePerGas;
  if (gasUsed > target) {
    return baseFeePerGas + max(1n, (baseFeePerGas * (gasUsed - target)) / target / 8n);
  }
  return baseFeePerGas - (baseFeePerGas * (target - gasUsed)) / target / 8n;
}

/// Fees for a transaction aimed at the next block: twice its base fee as the ceiling, so it stays includable.
export function feesFor(nextBase, priorityFeeGwei) {
  const tip = gweiToWei(priorityFeeGwei);
  return { maxFeePerGas: 2n * nextBase + tip, maxPriorityFeePerGas: tip };
}

/// Fees that may replace `prev` on the same nonce: both fields up by at least 12.5% (geth wants 10%), and the ceiling
/// above what the next block charges, neither above `feeCap` (MAX_FEE_GWEI in wei) when one is given (XS-13). At the
/// cap a replacement no longer rises, and the node refuses it as underpriced: the bump stops there.
export function replacementFees(prev, nextBase, feeCap = null) {
  const bump = (x) => max(ceilDiv(x * 1125n, 1000n), x + 1n);
  const cap = (x) => (feeCap === null ? x : min(x, feeCap));
  const tip = cap(bump(prev.maxPriorityFeePerGas));
  return { maxFeePerGas: cap(max(bump(prev.maxFeePerGas), 2n * nextBase + tip)), maxPriorityFeePerGas: tip };
}

export function gweiToWei(gwei) {
  if (!Number.isFinite(gwei) || gwei < 0) throw new Error(`not a gwei amount: ${gwei}`);
  return BigInt(Math.round(gwei * 1e9));
}

export const weiToGwei = (wei) => Number(wei) / Number(GWEI);

/// The dollars a fill earns: the float's change, the stock's change at Pyth prices, less gas.
export const profitUsd = ({ usdcDelta, inventoryUsd, gasUsd }) => Number(usdcDelta) / 1e6 + inventoryUsd - gasUsd;

/// The float's floor for the fill the bot decided on: never below what the decision needs, and otherwise the
/// simulated outcome less slippage on the volume the routes trade. A sandwich can take nothing below it.
export function usdcFloor({ simDelta, minProfitUsd, gasUsd, inventoryUsd, routedVolumeUsdc, slippageBps }) {
  const decision = usdToUsdcCeil(minProfitUsd + gasUsd - inventoryUsd);
  const slack = ceilDiv(routedVolumeUsdc * BigInt(slippageBps), BPS);
  return max(decision, simDelta - slack);
}

/// How many basis points a route loses against Pyth: a sale that returns `usdc` for coins worth `fairUsd`, or a
/// purchase that costs `usdc` for them. Negative when the route beats Pyth.
export function routeLossBps(side, usdc, fairUsd) {
  if (!(fairUsd > 0)) return Infinity;
  const got = Number(usdc) / 1e6;
  const loss = side === "sell" ? (fairUsd - got) / fairUsd : (got - fairUsd) / fairUsd;
  return loss * 10_000;
}

// ---------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------

/// Open requests simulated per block, the largest in dollars first and at most half of them on one side, as CF-7
/// bounds the auction checks.
export const MAX_REQUEST_CHECKS = 8;

/// A request's escrow and limit in dollars (XS-7): a mint escrows a stablecoin, counted at 6 decimals and one dollar,
/// for shares; a redemption escrows shares for a stablecoin. `shareUsd` is one share's worth at Pyth.
export function requestUsd(request, shareUsd) {
  const stable = (x) => Number(x) / 1e6;
  const shares = (x) => (Number(x) / 1e18) * shareUsd;
  return request.isMint
    ? { escrowUsd: stable(request.escrow), limitUsd: shares(request.limit) }
    : { escrowUsd: shares(request.escrow), limitUsd: stable(request.limit) };
}

/// The open requests worth simulating at second T on an index this bot serves (XS-7). `info` maps a lowercased index
/// to `{shareUsd, mintAllowed}`: one share's worth at Pyth (null when unpriced) and whether the index would issue to
/// the executor (null when unread). A request is skipped before any simulation when its index is unpriced, when it is
/// a mint the index's gate would refuse the executor, or when its limit is worth more than its escrow, which no fill
/// at Pyth prices meets. The rest are ranked by their escrow's dollars, not its raw amount, which is in a stablecoin's
/// units for a mint and in shares for a redemption; each side keeps half of the `cap` slots, so one side's requests
/// cannot crowd out the other's, and slots one side leaves go to the other. Returns `{chosen, skipped}`, the chosen
/// entries with `usd` added, the skipped ones as `{id, reason}`.
export function fillableRequests(entries, T, indexes, info, cap = MAX_REQUEST_CHECKS) {
  const served = new Set(indexes.map((a) => a.toLowerCase()));
  const skipped = [];
  const ranked = [];
  for (const entry of entries) {
    const r = entry.request;
    if (!r.open || BigInt(r.deadline) < T || !served.has(r.index.toLowerCase())) continue;
    const at = info.get(r.index.toLowerCase());
    if (!at || at.shareUsd === null) {
      skipped.push({ id: entry.id, reason: "no Pyth value for its index yet" });
      continue;
    }
    if (r.isMint && at.mintAllowed !== true) {
      skipped.push({ id: entry.id, reason: "its index is gated and does not issue to the executor" });
      continue;
    }
    const { escrowUsd, limitUsd } = requestUsd(r, at.shareUsd);
    if (limitUsd > escrowUsd) {
      skipped.push({ id: entry.id, reason: `its limit, worth ${limitUsd.toFixed(2)} USD, is above its escrow's ${escrowUsd.toFixed(2)} USD` });
      continue;
    }
    ranked.push({ ...entry, usd: escrowUsd });
  }
  ranked.sort((a, b) => b.usd - a.usd);
  const half = Math.floor(cap / 2);
  const first = [...ranked.filter((e) => e.request.isMint).slice(0, cap - half), ...ranked.filter((e) => !e.request.isMint).slice(0, half)];
  const chosen = [...first, ...ranked.filter((e) => !first.includes(e)).slice(0, cap - first.length)].sort((a, b) => b.usd - a.usd);
  for (const e of ranked) if (!chosen.includes(e)) skipped.push({ id: e.id, reason: `past the ${cap} largest open requests` });
  return { chosen, skipped };
}

/// Folds a scan's reads into `known`, the open requests by id (XS-11). `ids` are the ids read, `results` their
/// multicall entries, `count` the requests made so far and `scanned` the last id read before. A read that failed is
/// unknown, not closed: a known request stays known, and `scanned` advances only past the ids from `scanned + 1` read
/// without a gap, so a failed one is read again at the next scan. Returns `{scanned, failed, closed}`.
export function applyScan({ known, scanned, count, ids, results, T }) {
  const read = new Set();
  const failed = [];
  const closed = [];
  ids.forEach((id, k) => {
    const r = results[k];
    if (r?.status !== "success") {
      failed.push(id);
      return;
    }
    read.add(id);
    if (r.result.open && BigInt(r.result.deadline) >= T) known.set(id, r.result);
    else if (known.delete(id)) closed.push(id);
  });
  let next = scanned;
  while (next < count && read.has(next + 1n)) next++;
  return { scanned: next, failed, closed };
}

/// Whether a request's stablecoin needs a route to or from USDC, and which side of the quote that is: the escrow of a
/// mint request is sold into USDC, the payment of a redeem request bought with it.
export function stableLeg(request, usdc) {
  if (request.stable.toLowerCase() === usdc.toLowerCase()) return null;
  return request.isMint
    ? { token: request.stable, side: "sell", amount: request.escrow }
    : { token: request.stable, side: "buy", amount: request.limit };
}
