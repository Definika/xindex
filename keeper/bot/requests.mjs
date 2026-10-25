// The keeper's request filler: `MintRequests` requests the executor can fill now, each simulated exactly as block L+1
// would run it, as the auction fills are. A mint request is filled with exactly its limit in shares, bought from stock
// and along routes; a redeem request is paid exactly its limit in its stablecoin, the escrowed shares redeemed and
// their basket sold. Any surplus over a limit is the filler's, which is why the app suggests limits. Requests are
// ranked by dollars and pre-checked against their limit and their index's gate before any simulation, and one whose
// simulation reverts is backed off (XS-7). A request fill reads no Pyth update on chain, so every price it is valued at
// is Hermes' latest, verified through Pyth's own contract and refused when stale or wide (RX-1, RX-9); what a fill may
// spend of the float is bounded on chain by the executor's request allowance.

import { encodeFunctionData } from "viem";
import { failedRequests, revertedRequestFills, skippedRequests } from "./backoff.mjs";
import { ABI, revertReason } from "./chain.mjs";
import { FRESH_SECONDS, MAINNET, MAX_CONF_BPS, SHARE_PRICED_IDS, TX_GAS_CAP } from "./config.mjs";
import { priceKey } from "./hermes.mjs";
import * as M from "./math.mjs";

const INT256_MIN = -(2n ** 255n);
const UINT64_MAX = 2n ** 64n - 1n;
const HERMES_MS = 5_000;
const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const sharePriced = (id) => SHARE_PRICED_IDS.includes(id.toLowerCase());

export function createRequestFiller({ chain, cfg, hermes, routes, requests, pyth, staticsOf, log, needs }) {
  const known = new Map(); // id -> request, every request seen that was still open at the last scan
  const said = new Map(); // id -> the last reason logged, so a waiting request is not logged every block
  const info = new Map(); // lowercased index -> {shareUsd, mintAllowed}, read at the last scan (XS-7)
  const failed = failedRequests(); // `request:id` -> simulations that reverted (XS-7)
  const reverts = revertedRequestFills(); // `request:id`, `requester:a`, `index:a` -> fills that reverted (XS-7, RX-10)
  const skips = skippedRequests(); // `request:id` -> checks that declined it without a revert (RX-24)
  let scanned = 0n; // the last id read, every one before it read too

  function say(id, reason) {
    if (said.get(id) === reason) return;
    said.set(id, reason);
    log(`request ${id}`, reason);
  }

  /// Hermes' latest prices of `ids`, kept only where Pyth's contract, parsing the signed update Hermes served with
  /// them, returns the same price, and only when fresh and narrow enough to value anything at (RX-1, RX-9). A price
  /// that is missing, forged, stale or wide is left out, and callers treat its coin as unpriced.
  async function trustedLatest(ids, L) {
    const { prices, updates } = await hermes.latestSigned(ids, Date.now() + HERMES_MS);
    if (prices.size === 0 || updates.length === 0) return new Map();
    const served = ids.filter((id) => prices.has(hermes.key(id)));
    const fee = await chain.read(pyth, ABI.pyth, "getUpdateFee", [updates], L.number);
    const [feeds] = await chain.call(
      { to: pyth, abi: ABI.pyth, functionName: "parsePriceFeedUpdates", args: [updates, served, 0n, UINT64_MAX], value: fee },
      L.number,
    );
    const verified = M.verifiedPrices(prices, feeds, hermes.key);
    const fresh = new Map();
    for (const [k, p] of verified) if (M.freshPrice(p, L.timestamp, FRESH_SECONDS, MAX_CONF_BPS)) fresh.set(k, p);
    return fresh;
  }

  /// Reads every request made since the last scan, and re-reads the known open ones, dropping those closed. A read
  /// that fails keeps its request as it was and is read again next scan (XS-11). The same multicall reads, for every
  /// index served, whether it would issue to the executor and its units, which with one Hermes request value a share
  /// of each index with open requests (XS-7).
  async function scan(L, indexes) {
    const count = await chain.read(requests, ABI.requests, "requestCount", [], L.number);
    const ids = [...known.keys()];
    for (let id = scanned + 1n; id <= count; id++) if (!known.has(id)) ids.push(id);
    if (ids.length === 0) {
      scanned = count;
      return;
    }
    const read = await chain.multicall(
      [
        ...ids.map((id) => ({ address: requests, abi: ABI.requests, functionName: "getRequest", args: [id] })),
        ...indexes.flatMap((index) => [
          { address: cfg.factory, abi: ABI.factory, functionName: "feeTerms", args: [index, cfg.executor] },
          { address: index, abi: ABI.hub, functionName: "components" },
        ]),
      ],
      L.number,
    );
    const result = M.applyScan({ known, scanned, count, ids, results: read.slice(0, ids.length), T: L.timestamp });
    scanned = result.scanned;
    for (const id of result.closed) said.delete(id);
    failed.keep(keys());
    // A requester's and an index's strikes outlive the requests that earned them, until they lapse (RX-10).
    reverts.keep([...reverts.entries.keys()].filter((k) => !k.startsWith("request:") || known.has(BigInt(k.slice(8)))));
    reverts.prune(L.number);
    skips.keep(keys());
    if (result.failed.length) {
      log(`request scan: ${result.failed.length} reads failed (${result.failed.join(", ")}); kept as they were, read again next scan`);
    }

    const open = new Set([...known.values()].map((r) => r.index.toLowerCase()));
    const live = [];
    indexes.forEach((index, k) => {
      if (!open.has(index.toLowerCase())) return;
      const [terms, comps] = [read[ids.length + 2 * k], read[ids.length + 2 * k + 1]];
      live.push({
        index,
        mintAllowed: terms.status === "success" ? terms.result[0] : null,
        units: comps.status === "success" ? comps.result[1] : null,
      });
    });
    // Every read first, so a failed one leaves the last scan's values in place.
    const priceIds = new Set();
    for (const r of live) for (const id of (await staticsOf(r.index, L.number)).ids) priceIds.add(id);
    const latest = live.length ? await trustedLatest([...priceIds], L) : new Map();
    info.clear();
    for (const r of live) {
      const st = await staticsOf(r.index, L.number);
      const prices = st.ids.map((id) => latest.get(priceKey(id)));
      const priced = r.units !== null && prices.every(Boolean);
      const shareUsd = priced ? M.tvlUsd({ supply: 10n ** 18n, units: r.units, decimals: st.decimals, prices }) : null;
      info.set(r.index.toLowerCase(), { shareUsd, mintAllowed: r.mintAllowed });
    }
  }

  /// The routes, stock change and routed volume of filling `r`, or `short` naming coins the executor can neither buy
  /// nor deliver from stock, with `stableRoute` for a stablecoin other than USDC. Each routed leg, and the stablecoin's,
  /// carries a bound at its quote plus SLIPPAGE_BPS, so a pool pushed against the fill stops it at that leg (RX-10).
  async function legs(id, r, st, amounts, L) {
    const key = `request:${id}`;
    const latest = await trustedLatest(st.ids, L);
    const held = await chain.multicall(
      st.tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [cfg.executor] })),
      L.number,
    );
    const allowed = await chain.multicall(
      st.tokens.map((t) => ({ address: cfg.executor, abi: ABI.executor, functionName: "stockAllowance", args: [t] })),
      L.number,
    );
    const routeOf = st.tokens.map(() => "0x");
    const legLimits = st.tokens.map(() => 0n);
    const short = [];
    let inventoryUsd = 0;
    let routedUsd = 0;
    const down = (x) => (x * (10_000n - BigInt(cfg.slippageBps))) / 10_000n;
    for (let i = 0; i < st.tokens.length; i++) {
      const token = st.tokens[i];
      const amount = amounts[i];
      if (amount === 0n || same(token, MAINNET.usdc)) continue; // a USDC leg is the float itself
      const p = latest.get(priceKey(st.ids[i]));
      if (!p) return { skip: `no fresh, verified price for ${token}` };
      const dec = st.decimals[i];
      const shared = sharePriced(st.ids[i]);
      const h = M.min(
        held[i].status === "success" ? held[i].result : 0n,
        allowed[i].status === "success" ? allowed[i].result : 0n,
      );
      let route = null;
      if (r.isMint) {
        if (M.deliversSharePricedStock({ need: amount, held: h, sharePriced: shared })) {
          return { skip: `would deliver share-priced stock of ${token}, which the bot cannot value: set its stock allowance to zero` };
        }
        if (amount > h) {
          const shortfall = amount - h;
          route = await routes.best({ key, token, side: "buy", amount: shortfall, fairUsd: M.amountUsd(shortfall, dec, p), blockNumber: L.number });
          if (!route) {
            short.push({ token, amount });
            continue;
          }
          routedUsd += M.amountUsd(shortfall, dec, p);
          const cost = routes.quoteOf({ key, token, side: "buy", amount: shortfall });
          if (cost) legLimits[i] = M.withTolerance(cost, cfg.slippageBps);
        }
        inventoryUsd += M.amountUsd(M.inventoryDelta({ out: 0n, in: amount, held: h, routed: route !== null }), dec, p);
      } else {
        route = await routes.best({ key, token, side: "sell", amount, fairUsd: M.amountUsd(amount, dec, p), blockNumber: L.number });
        // A kept coin counts at no more than its best quote (XS-5), and a share-priced one at nothing (RX-2).
        const quoteUsdc = routes.quoteOf({ key, token, side: "sell", amount });
        if (route) {
          routedUsd += M.amountUsd(amount, dec, p);
          if (quoteUsdc) legLimits[i] = down(quoteUsdc);
        }
        inventoryUsd += M.stockChangeUsd({ out: amount, in: 0n, held: 0n, routed: route !== null, decimals: dec, price: p, quoteUsdc, sharePriced: shared });
      }
      if (route) routeOf[i] = route;
    }
    let stableRoute = "0x";
    let stableLimit = 0n;
    const stable = M.stableLeg(r, MAINNET.usdc);
    if (stable) {
      const fairUsd = Number(stable.amount) / 1e6;
      stableRoute = await routes.best({ key, ...stable, fairUsd, blockNumber: L.number });
      if (!stableRoute) return { skip: `no route between ${stable.token} and USDC` };
      routedUsd += fairUsd;
      const q = routes.quoteOf({ key, token: stable.token, side: stable.side, amount: stable.amount });
      if (q) stableLimit = stable.side === "sell" ? down(q) : M.withTolerance(q, cfg.slippageBps);
    }
    return { routes: routeOf, legLimits, stableRoute, stableLimit, inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd), short };
  }

  /// Request `id`, as a fill this bot could send now: its profit after gas and the transaction, or why not. A request
  /// is never subsidised: a negative MIN_PROFIT_USD applies to auctions only (RX-16).
  async function evaluate(id, r, L, ethUsd, tip, feeCap) {
    if (ethUsd === null) return { skip: "no ETH price to value gas" };
    const T = L.timestamp + 12n;
    const st = await staticsOf(r.index, L.number);
    const functionName = r.isMint ? "fillMint" : "fillRedeem";
    const amount = r.limit; // exactly the limit: the surplus over it would be the requester's
    const minProfitUsd = Math.max(cfg.minProfitUsd, 0);
    let amounts;
    let nonce;
    try {
      amounts = r.isMint
        ? await chain.read(r.index, ABI.hub, "previewIssue", [amount], L.number)
        : await chain.read(r.index, ABI.hub, "previewRedeem", [r.escrow], L.number);
      // The fill names the basket it was priced on: a settlement before it lands stops it (RX-4).
      nonce = await chain.read(r.index, ABI.hub, "rebalanceNonce", [], L.number);
    } catch (error) {
      return { skip: `no preview: ${revertReason(error)}`, declined: true };
    }
    const leg = await legs(id, r, st, amounts, L);
    if (leg.skip) return { ...leg, declined: true };
    needs?.report(`request:${id}`, "request", leg.short);
    if (leg.short.length) {
      return { skip: `restock: no route and too little stock of ${leg.short.map((s) => s.token).join(", ")}`, declined: true };
    }
    const over = { block: { number: L.number + 1n, time: T } };
    const fill = (minUsdcDelta) => ({
      id,
      amount,
      routes: leg.routes,
      legLimits: leg.legLimits,
      stableRoute: leg.stableRoute,
      stableLimit: leg.stableLimit,
      expectedNonce: nonce,
      minUsdcDelta,
      deadline: T,
    });
    const args = [fill(INT256_MIN)];
    let usdcDelta;
    let inner;
    try {
      [usdcDelta, inner] = await chain.call({ to: cfg.executor, abi: ABI.executor, functionName, args }, L.number, over);
    } catch (error) {
      return { skip: `${functionName} would revert: ${revertReason(error)}`, failed: true };
    }
    const used = M.txGasUsed(inner, encodeFunctionData({ abi: ABI.executor, functionName, args }));
    if (used > TX_GAS_CAP) return { skip: `${functionName} needs ${used} gas, above EIP-7825's cap`, declined: true };
    const nextBase = M.nextBaseFee(L);
    if (nextBase + tip > feeCap) return { skip: `base fee ${M.weiToGwei(nextBase)} gwei above MAX_FEE_GWEI` };
    const gasUsd = M.fillCostUsd({ used, nextBase, tip, ethUsd });
    const profit = M.profitUsd({ usdcDelta, inventoryUsd: leg.inventoryUsd, gasUsd });
    if (profit < minProfitUsd) return { skip: `waiting: profit ${profit.toFixed(2)} USD below MIN_PROFIT_USD`, declined: true };
    const floor = M.usdcFloor({
      simDelta: usdcDelta,
      minProfitUsd,
      gasUsd,
      inventoryUsd: leg.inventoryUsd,
      routedVolumeUsdc: leg.routedVolumeUsdc,
      slippageBps: cfg.slippageBps,
    });
    const gas = M.min(M.gasLimitFor(used), TX_GAS_CAP);
    const sent = [fill(floor)];
    // The call again, with the limit the transaction will carry: a fill that fits only the node's default limit, or
    // whose 1/64 reserve at the hub runs out, is skipped instead of sent (RX-21, RX-36).
    try {
      await chain.call({ to: cfg.executor, abi: ABI.executor, functionName, args: sent, gas }, L.number, over);
    } catch (error) {
      return { skip: `${functionName} does not fit its gas limit of ${gas}: ${revertReason(error)}`, failed: true };
    }
    const tx = {
      to: cfg.executor,
      data: encodeFunctionData({ abi: ABI.executor, functionName, args: sent }),
      value: 0n,
      gas,
      maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
      maxPriorityFeePerGas: tip,
    };
    return { id, profit, usdcDelta, gasUsd, inventoryUsd: leg.inventoryUsd, tx };
  }

  /// The strike keys of request `id`: the request, its requester and its index, so a requester cannot start over with
  /// a new request id, nor many requests on one index each cost a reverted fill (RX-10).
  const strikeKeys = (id) => M.requestStrikeKeys(id, known.get(id));

  /// The most profitable request fill this block, if any pays. A request backed off after a failed simulation, after a
  /// fill that reverted on chain (its own, its requester's or its index's), or after checks that kept declining it, is
  /// not checked until its wait is over (XS-7, RX-10, RX-24).
  async function best(L, indexes, ethUsd, tip, feeCap) {
    const entries = [];
    for (const [id, request] of known) {
      const key = `request:${id}`;
      const struck = strikeKeys(id).find((k) => reverts.blocked(k, L.number));
      if (struck) say(id, `backing off after ${reverts.failures(struck)} fills reverted on chain (${struck.split(":")[0]})`);
      else if (failed.blocked(key, L.number)) say(id, `backing off after ${failed.failures(key)} failed simulations`);
      else if (skips.blocked(key, L.number)) continue;
      else entries.push({ id, request });
    }
    const { chosen: candidates, skipped } = M.fillableRequests(entries, L.timestamp + 12n, indexes, info);
    for (const { id, reason } of skipped) say(id, `not simulated: ${reason}`);
    const priced = await Promise.all(
      candidates.map(({ id, request }) =>
        evaluate(id, request, L, ethUsd, tip, feeCap).catch((error) => ({ skip: `check failed: ${revertReason(error)}`, failed: true })),
      ),
    );
    priced.forEach((p, k) => {
      if (!p.skip) return;
      const id = candidates[k].id;
      if (p.failed) {
        failed.fail(`request:${id}`, L.number);
        routes.forgetKey(`request:${id}`); // its routes are searched again (RX-13)
      }
      if (p.declined) skips.fail(`request:${id}`, L.number);
      say(id, p.skip);
    });
    return priced.filter((p) => !p.skip).sort((a, b) => b.profit - a.profit)[0] ?? null;
  }

  /// The route keys of the requests still known, for the route cache to keep.
  function keys() {
    return [...known.keys()].map((id) => `request:${id}`);
  }

  function forget(id) {
    known.delete(id);
    said.delete(id);
    failed.forget(`request:${id}`);
    reverts.forget(`request:${id}`);
    skips.forget(`request:${id}`);
  }

  /// A fill of request `id` reverted on chain at block `block`, after its simulation passed: it, its requester and its
  /// index wait, and after MAX_REVERTED_REQUEST_FILLS this bot leaves them until the strikes lapse (XS-7, RX-10). Its
  /// routes are searched again (RX-13). Returns the request's `{failures, until, stopped}`.
  function reverted(id, block) {
    const [own, ...others] = strikeKeys(id);
    for (const k of others) reverts.fail(k, block);
    routes.forgetKey(own);
    return reverts.fail(own, block);
  }

  return { scan, best, keys, forget, reverted };
}
