// The keeper's request filler: `MintRequests` requests the executor can fill now, each simulated exactly as block L+1
// would run it, as the auction fills are. A mint request is filled with exactly its limit in shares, bought from stock
// and along routes; a redeem request is paid exactly its limit in its stablecoin, the escrowed shares redeemed and
// their basket sold. Any surplus over a limit is the filler's, which is why the app suggests limits. Requests are
// ranked by dollars and pre-checked against their limit and their index's gate before any simulation, and one whose
// simulation reverts is backed off (XS-7). Nothing on chain reads a price, so every price a fill is valued at is the
// keeper's own: Hermes' latest, verified through Pyth's contract and refused when stale or wide (RX-1, RX-9). A coin
// outside the keeper's price catalogue has none, and a request on an index holding one is not filled. What a fill may
// spend of the float is bounded on chain by the executor's request allowance.
//
// Several requests on one index in one stablecoin are filled together when that pays better (`fillBatch`): the shares
// the redeem requests escrowed go to the mint requests, the executor's own stock of the index's shares covers what
// they do not, as far as SHARE_STOCK_USD and the owner's stock allowance for that index go, and one basket is
// bought or sold for the difference. A request too small to pay for a basket of its own is filled this way, since
// the batch as a whole has to pay MIN_PROFIT_USD, not each request (design/2026-11-11-batch-fills.md).

import { encodeFunctionData } from "viem";
import { failedRequests, revertedRequestFills, skippedRequests } from "./backoff.mjs";
import { ABI, revertReason } from "./chain.mjs";
import { FRESH_SECONDS, MAX_CONF_BPS, SHARE_PRICED_IDS, TX_GAS_CAP } from "./config.mjs";
import { priceKey } from "./hermes.mjs";
import * as M from "./math.mjs";

const INT256_MIN = -(2n ** 255n);
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
    const verified = await hermes.trusted(ids, Date.now() + HERMES_MS, {
      read: chain.read,
      call: chain.call,
      pyth,
      abi: ABI.pyth,
      blockNumber: L.number,
    });
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
    // A batch's reasons are kept by its requests' ids, which change as requests come and go: said again each scan.
    for (const k of [...said.keys()]) if (typeof k === "string") said.delete(k);
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
    for (const r of live) for (const id of (await staticsOf(r.index, L.number)).ids) if (id) priceIds.add(id);
    const latest = live.length ? await trustedLatest([...priceIds], L) : new Map();
    info.clear();
    for (const r of live) {
      const st = await staticsOf(r.index, L.number);
      const prices = st.ids.map((id) => (id ? latest.get(priceKey(id)) : undefined));
      const priced = r.units !== null && prices.every(Boolean);
      const shareUsd = priced ? M.tvlUsd({ supply: 10n ** 18n, units: r.units, decimals: st.decimals, prices }) : null;
      info.set(r.index.toLowerCase(), { shareUsd, mintAllowed: r.mintAllowed });
    }
  }

  const down = (x) => (x * (10_000n - BigInt(cfg.slippageBps))) / 10_000n;

  /// The routes, stock change and routed dollars of buying (`isMint`) or selling the basket `amounts` of an index, or
  /// `short` naming coins the executor can neither buy nor deliver from stock. Each routed leg carries a bound at its
  /// quote plus SLIPPAGE_BPS, so a pool pushed against the fill stops it at that leg (RX-10). `key` names the fill in
  /// the route cache.
  async function basket(key, isMint, st, amounts, L) {
    const latest = await trustedLatest(st.ids.filter(Boolean), L);
    const held = await chain.multicall(
      st.tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [cfg.executor] })),
      L.number,
    );
    const allowed = await chain.multicall(
      st.tokens.map((t) => ({ address: cfg.executor, abi: ABI.executor, functionName: "stockAllowance", args: [t] })),
      L.number,
    );
    // A stock read that failed is not an empty stock: valued as one, the fill would deliver stock it never counted
    // and overstate its profit by that stock's value. The check is made again next block (RY-9).
    if ([...held, ...allowed].some((r) => r.status !== "success")) throw new Error("a stock read failed");
    const routeOf = st.tokens.map(() => "0x");
    const legLimits = st.tokens.map(() => 0n);
    const short = [];
    const stocked = []; // every leg stock serves, for the restock's board (RZ-3)
    let inventoryUsd = 0;
    let routedUsd = 0;
    for (let i = 0; i < st.tokens.length; i++) {
      const token = st.tokens[i];
      const amount = amounts[i];
      if (amount === 0n || same(token, cfg.chain.usdc)) continue; // a USDC leg is the float itself
      const p = st.ids[i] ? latest.get(priceKey(st.ids[i])) : undefined;
      if (!p) return { skip: `no fresh, verified price for ${token}` };
      const dec = st.decimals[i];
      const shared = sharePriced(st.ids[i]);
      const h = M.min(held[i].result, allowed[i].result);
      let route = null;
      if (isMint) {
        if (M.deliversSharePricedStock({ need: amount, held: h, sharePriced: shared })) {
          return { skip: `would deliver share-priced stock of ${token}, which the bot cannot value: set its stock allowance to zero` };
        }
        if (amount > h) {
          const shortfall = amount - h;
          route = await routes.best({ key, token, side: "buy", amount: shortfall, fairUsd: M.amountUsd(shortfall, dec, p), blockNumber: L.number });
          if (route) {
            routedUsd += M.amountUsd(shortfall, dec, p);
            const cost = routes.quoteOf({ key, token, side: "buy", amount: shortfall });
            if (cost) legLimits[i] = M.withTolerance(cost, cfg.slippageBps);
          }
        }
        if (!route) {
          // Stock serves this leg: the board carries all of it, covered yet or not, so the need stays until the fill
          // lands rather than leaving the moment the restock's coins do (RZ-3).
          stocked.push({ token, amount });
          if (amount > h) {
            short.push({ token, amount });
            continue;
          }
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
    return { routes: routeOf, legLimits, inventoryUsd, routedUsd, short, stocked };
  }

  /// The route of one stablecoin leg (`{token, side, amount}`), its bound at the quote plus SLIPPAGE_BPS (RX-10) and
  /// its dollars, or null when no route joins that stablecoin and USDC.
  async function stableQuote(key, stable, L) {
    const fairUsd = Number(stable.amount) / 1e6;
    const route = await routes.best({ key, ...stable, fairUsd, blockNumber: L.number });
    if (!route) return null;
    const q = routes.quoteOf({ key, token: stable.token, side: stable.side, amount: stable.amount });
    const limit = !q ? 0n : stable.side === "sell" ? down(q) : M.withTolerance(q, cfg.slippageBps);
    return { route, limit, fairUsd };
  }

  /// The routes, stock change and routed volume of filling `r`, or `short` naming coins the executor can neither buy
  /// nor deliver from stock, with `stableRoute` for a stablecoin other than USDC.
  async function legs(id, r, st, amounts, L) {
    const key = `request:${id}`;
    const b = await basket(key, r.isMint, st, amounts, L);
    if (b.skip) return b;
    let stableRoute = "0x";
    let stableLimit = 0n;
    let routedUsd = b.routedUsd;
    const stable = M.stableLeg(r, cfg.chain.usdc);
    if (stable) {
      const s = await stableQuote(key, stable, L);
      if (!s) return { skip: `no route between ${stable.token} and USDC` };
      stableRoute = s.route;
      stableLimit = s.limit;
      routedUsd += s.fairUsd;
    }
    return { routes: b.routes, legLimits: b.legLimits, stableRoute, stableLimit, inventoryUsd: b.inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd), short: b.short, stocked: b.stocked };
  }

  /// One fill, simulated as block L+1 would run it and priced: `fill(minUsdcDelta)` builds the argument of
  /// `functionName` at a floor. Returns its profit after gas and the transaction to send, or why not. A request fill
  /// is never subsidised: a negative MIN_PROFIT_USD applies to auctions only (RX-16).
  async function price(functionName, fill, { inventoryUsd, routedVolumeUsdc }, L, ethUsd, tip, feeCap) {
    const T = L.timestamp + 12n;
    const minProfitUsd = Math.max(cfg.minProfitUsd, 0);
    const over = { block: { number: L.number + 1n, time: T } };
    const args = [fill(INT256_MIN)];
    let usdcDelta;
    let inner;
    try {
      [usdcDelta, inner] = await chain.call({ to: cfg.executor, abi: ABI.executor, functionName, args }, L.number, over);
    } catch (error) {
      // Only a revert is a failed simulation; an RPC error is retried next block without a strike (RZ-12).
      return { skip: `${functionName} would revert: ${revertReason(error)}`, failed: chain.isRevert(error) };
    }
    const used = M.txGasUsed(inner, encodeFunctionData({ abi: ABI.executor, functionName, args }));
    if (used > TX_GAS_CAP) return { skip: `${functionName} needs ${used} gas, above EIP-7825's cap`, declined: true };
    const nextBase = M.nextBaseFee(L);
    if (nextBase + tip > feeCap) return { skip: `base fee ${M.weiToGwei(nextBase)} gwei above MAX_FEE_GWEI` };
    const gasUsd = M.fillCostUsd({ used, nextBase, tip, ethUsd });
    const profit = M.profitUsd({ usdcDelta, inventoryUsd, gasUsd });
    if (profit < minProfitUsd) return { skip: `waiting: profit ${profit.toFixed(2)} USD below MIN_PROFIT_USD`, declined: true };
    const floor = M.usdcFloor({ simDelta: usdcDelta, minProfitUsd, gasUsd, inventoryUsd, routedVolumeUsdc, slippageBps: cfg.slippageBps });
    const gas = M.min(M.gasLimitFor(used), TX_GAS_CAP);
    const sent = [fill(floor)];
    // The call again, with the limit the transaction will carry: a fill that fits only the node's default limit, or
    // whose 1/64 reserve at the hub runs out, is skipped instead of sent (RX-21, RX-36).
    try {
      await chain.call({ to: cfg.executor, abi: ABI.executor, functionName, args: sent, gas }, L.number, over);
    } catch (error) {
      return { skip: `${functionName} does not fit its gas limit of ${gas}: ${revertReason(error)}`, failed: chain.isRevert(error) };
    }
    const tx = {
      to: cfg.executor,
      data: encodeFunctionData({ abi: ABI.executor, functionName, args: sent }),
      value: 0n,
      gas,
      maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
      maxPriorityFeePerGas: tip,
    };
    return { profit, usdcDelta, gasUsd, inventoryUsd, tx };
  }

  /// Request `id`, as a fill this bot could send now: its profit after gas and the transaction, or why not. With
  /// `probe` the request reports no need to the restock's board: it is checked only to find which request of a
  /// batch stopped the batch's simulation, and may pay nothing alone (RY-8).
  async function evaluate(id, r, L, ethUsd, tip, feeCap, { probe = false } = {}) {
    if (ethUsd === null) return { skip: "no ETH price to value gas" };
    const T = L.timestamp + 12n;
    const st = await staticsOf(r.index, L.number);
    const functionName = r.isMint ? "fillMint" : "fillRedeem";
    const amount = r.limit; // exactly the limit: the surplus over it would be the requester's
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
    if (!probe) needs?.report(`request:${id}`, "request", leg.stocked);
    if (leg.short.length) {
      return { skip: `restock: no route and too little stock of ${leg.short.map((s) => s.token).join(", ")}`, declined: true };
    }
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
    const priced = await price(functionName, fill, leg, L, ethUsd, tip, feeCap);
    return priced.skip ? priced : { id, ...priced };
  }

  /// Group `g` (`M.batchGroups`), as one `fillBatch` this bot could send now: its profit after gas and the
  /// transaction, or why not. Every request is filled at exactly its limit. The shares the redeem requests escrowed
  /// go to the mint requests; with SHARE_STOCK_USD set, the executor's stock of the index's shares covers what they
  /// do not, within the owner's allowance, and keeps what is left up to that many dollars; one basket is bought or
  /// sold for the rest (`M.planBatch`). An index holding a share-priced leg has shares the bot cannot value, so it
  /// keeps and delivers none of them (RX-2).
  async function evaluateBatch(g, L, ethUsd, tip, feeCap) {
    if (ethUsd === null) return { skip: "no ETH price to value gas" };
    const T = L.timestamp + 12n;
    const st = await staticsOf(g.index, L.number);
    const unit = 10n ** 18n;
    // The requests again, at this block: one closed since the last scan would stop the whole batch (XS-6).
    const read = await chain.multicall(
      [
        { address: g.index, abi: ABI.hub, functionName: "rebalanceNonce" },
        { address: g.index, abi: ABI.hub, functionName: "previewIssue", args: [unit] },
        { address: g.index, abi: ABI.hub, functionName: "previewRedeem", args: [unit] },
        { address: g.index, abi: ABI.erc20, functionName: "balanceOf", args: [cfg.executor] },
        { address: cfg.executor, abi: ABI.executor, functionName: "stockAllowance", args: [g.index] },
        ...g.members.map((m) => ({ address: requests, abi: ABI.requests, functionName: "getRequest", args: [m.id] })),
      ],
      L.number,
    );
    // A read that failed says nothing: the batch is checked again next block, without a strike.
    if (read.some((r) => r.status !== "success")) return { skip: "a read of its index or its requests failed" };
    const [nonce, oneIssued, oneRedeemed, held, allowed] = read.slice(0, 5).map((r) => r.result);
    const live = (k) => read[5 + k].result.open && BigInt(read[5 + k].result.deadline) >= T;
    const stale = g.members.filter((m, k) => !live(k)).map((m) => m.id);
    if (stale.length) return { skip: `request ${stale.join(", ")} closed since the last scan`, stale };
    const members = g.members;
    const mints = members.filter((m) => m.request.isMint);
    const redeems = members.filter((m) => !m.request.isMint);

    // One share's worth each way, at Pyth: what issuing it costs and what redeeming it brings, the index's fee in both.
    const latest = await trustedLatest(st.ids.filter(Boolean), L);
    const prices = st.ids.map((id) => (id ? latest.get(priceKey(id)) : undefined));
    const worth = (amounts) => amounts.reduce((sum, a, i) => sum + M.amountUsd(a, st.decimals[i], prices[i]), 0);
    const stockable = cfg.shareStockUsd > 0 && prices.every(Boolean) && !st.ids.some((id) => id && sharePriced(id));
    const shareWorth = stockable ? { buyUsd: worth(oneIssued), sellUsd: worth(oneRedeemed) } : null;
    const plan = M.planBatch({
      mints,
      redeems,
      held: stockable ? held : 0n,
      allowed: stockable ? allowed : 0n,
      target: stockable ? M.sharesFor(cfg.shareStockUsd, shareWorth.sellUsd) : 0n,
    });

    let leg = { routes: st.tokens.map(() => "0x"), legLimits: [], inventoryUsd: 0, routedUsd: 0, short: [], stocked: [] };
    if (plan.issue > 0n || plan.redeem > 0n) {
      let amounts;
      try {
        amounts =
          plan.issue > 0n
            ? await chain.read(g.index, ABI.hub, "previewIssue", [plan.issue], L.number)
            : await chain.read(g.index, ABI.hub, "previewRedeem", [plan.redeem], L.number);
      } catch (error) {
        return { skip: `no preview: ${revertReason(error)}`, declined: true };
      }
      leg = await basket(g.key, plan.issue > 0n, st, amounts, L);
      if (leg.skip) return { ...leg, declined: true };
    }
    needs?.report(g.key, "request", leg.stocked);
    if (leg.short.length) {
      return { skip: `restock: no route and too little stock of ${leg.short.map((s) => s.token).join(", ")}`, declined: true };
    }

    // One path serves the stablecoin both ways: what the mint requests escrowed is sold along it, and what the redeem
    // requests are paid is bought along it, read backwards. With both in one batch the sale's route is the one
    // searched, and the purchase is bounded by the batch's floor alone.
    let stableRoute = "0x";
    let stableMaxIn = 0n;
    let stableMinOut = 0n;
    let routedUsd = leg.routedUsd;
    if (!same(g.stable, cfg.chain.usdc)) {
      const taken = mints.reduce((sum, m) => sum + m.request.escrow, 0n);
      const paid = redeems.reduce((sum, m) => sum + m.request.limit, 0n);
      const stable = taken > 0n ? { token: g.stable, side: "sell", amount: taken } : { token: g.stable, side: "buy", amount: paid };
      const s = await stableQuote(g.key, stable, L);
      if (!s) return { skip: `no route between ${g.stable} and USDC`, declined: true };
      stableRoute = s.route;
      if (taken > 0n) stableMinOut = s.limit;
      else stableMaxIn = s.limit;
      routedUsd += s.fairUsd + (taken > 0n ? Number(paid) / 1e6 : 0);
    }

    const inventoryUsd = leg.inventoryUsd + (stockable ? M.shareStockUsd(plan.stockDelta, shareWorth, cfg.slippageBps) : 0);
    const fill = (minUsdcDelta) => ({
      index: g.index,
      stable: g.stable,
      mintIds: plan.mintIds,
      mintShares: plan.mintShares,
      redeemIds: plan.redeemIds,
      redeemPay: plan.redeemPay,
      issue: plan.issue,
      redeem: plan.redeem,
      routes: leg.routes,
      maxIn: plan.issue > 0n ? leg.legLimits : [],
      minOut: plan.redeem > 0n ? leg.legLimits : [],
      stableRoute,
      stableMaxIn,
      stableMinOut,
      expectedNonce: nonce,
      minUsdcDelta,
      deadline: T,
    });
    const priced = await price("fillBatch", fill, { inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd) }, L, ethUsd, tip, feeCap);
    return priced.skip ? priced : { ids: members.map((m) => m.id), ...priced };
  }

  /// The strike keys of request `id`: the request, its requester and its index, so a requester cannot start over with
  /// a new request id, nor many requests on one index each cost a reverted fill (RX-10).
  const strikeKeys = (id) => M.requestStrikeKeys(id, known.get(id));

  /// The most profitable fill this block, if any pays: a batch (`{ids, ...}`) or a single request (`{id, ...}`). A
  /// request backed off after a failed simulation, after a fill that reverted on chain (its own, its requester's or
  /// its index's), or after checks that kept declining it, is not checked until its wait is over (XS-7, RX-10,
  /// RX-24).
  ///
  /// Batches are checked first, over every request not struck or failed: one a single check keeps declining, as one
  /// too small to pay for its own basket is, still belongs in a batch. A request in a batch that pays is not checked
  /// alone. When a batch's simulation reverts, each of its requests is checked alone that block, so the one whose own
  /// fill reverts is found and backed off, and the batch forms again without it.
  async function best(L, indexes, ethUsd, tip, feeCap) {
    const entries = [];
    const batchable = [];
    for (const [id, request] of known) {
      const key = `request:${id}`;
      const struck = strikeKeys(id).find((k) => reverts.blocked(k, L.number));
      if (struck) say(id, `backing off after ${reverts.failures(struck)} fills reverted on chain (${struck.split(":")[0]})`);
      else if (failed.blocked(key, L.number)) say(id, `backing off after ${failed.failures(key)} failed simulations`);
      else {
        batchable.push({ id, request });
        if (!skips.blocked(key, L.number)) entries.push({ id, request });
      }
    }
    // A request is never subsidised, so one that cannot pay MIN_PROFIT_USD at its limit is not simulated (RY-8).
    const minProfitUsd = Math.max(cfg.minProfitUsd, 0);
    const T = L.timestamp + 12n;

    // With a share stock one request is a batch too: the stock may fill it without a basket.
    const groups = M.batchGroups(batchable, T, indexes, info, { minSize: cfg.shareStockUsd > 0 ? 1 : 2, minProfitUsd }).filter(
      (g) => !failed.blocked(M.batchKey(g), L.number) && !skips.blocked(M.batchKey(g), L.number),
    );
    const batches = await Promise.all(
      groups.map((g) => evaluateBatch(g, L, ethUsd, tip, feeCap).catch((error) => ({ skip: `check failed: ${revertReason(error)}`, failed: chain.isRevert(error) }))),
    );
    const inBatch = new Set();
    const suspects = [];
    batches.forEach((b, k) => {
      const g = groups[k];
      if (!b.skip) return b.ids.forEach((id) => inBatch.add(id));
      // Closed for good, as read at this block: the batch forms again without them next block.
      if (b.stale) b.stale.forEach(forget);
      if (b.failed) {
        failed.fail(M.batchKey(g), L.number);
        routes.forgetKey(g.key); // its routes are searched again (RX-13)
        suspects.push(...g.members);
      }
      if (b.declined) skips.fail(M.batchKey(g), L.number);
      sayBatch(g, b.skip);
    });

    const alone = entries.filter((e) => !inBatch.has(e.id) && known.has(e.id));
    const { chosen: candidates, skipped } = M.fillableRequests(alone, T, indexes, info, M.MAX_REQUEST_CHECKS, minProfitUsd);
    for (const { id, reason } of skipped) {
      needs?.report(`request:${id}`, "request", []); // nor does it hold stock on the restock's board (RY-8)
      say(id, `not simulated: ${reason}`);
    }
    // The requests of a batch whose simulation reverted, each alone, unless it is being checked alone anyway.
    const probes = suspects.filter((m) => !candidates.some((c) => c.id === m.id)).map((m) => ({ ...m, probe: true }));
    const checks = [...candidates, ...probes];
    const priced = await Promise.all(
      checks.map(({ id, request, probe }) =>
        evaluate(id, request, L, ethUsd, tip, feeCap, { probe }).catch((error) => ({ skip: `check failed: ${revertReason(error)}`, failed: chain.isRevert(error) })),
      ),
    );
    priced.forEach((p, k) => {
      if (!p.skip) return;
      const id = checks[k].id;
      if (p.failed) {
        failed.fail(`request:${id}`, L.number);
        routes.forgetKey(`request:${id}`); // its routes are searched again (RX-13)
      }
      // A probe that pays nothing alone is no decoy: it waits for its batch, not for a check slot (RX-24).
      if (p.declined && !checks[k].probe) skips.fail(`request:${id}`, L.number);
      say(id, p.skip);
    });
    const fills = [...batches.filter((b) => !b.skip), ...priced.filter((p) => !p.skip)];
    return fills.sort((a, b) => b.profit - a.profit)[0] ?? null;
  }

  /// Logs why a batch was not sent, once per reason.
  function sayBatch(g, reason) {
    const key = M.batchKey(g);
    if (said.get(key) === reason) return;
    said.set(key, reason);
    log(`batch ${g.members.map((m) => m.id).join(",")}`, reason);
  }

  /// The route keys of the requests still known, and of the batches they could form, for the route cache to keep.
  function keys() {
    const batches = new Set([...known.values()].map((r) => `batch:${r.index.toLowerCase()}:${r.stable.toLowerCase()}`));
    return [...[...known.keys()].map((id) => `request:${id}`), ...batches];
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

  /// A batch of requests `ids` reverted on chain at block `block`, after its simulation passed. Which request
  /// stopped it is not known, so each one, each requester and each index is struck once, as after a single fill
  /// (RX-10), whatever the number of requests that share a requester or the index. Returns the strike that waits
  /// longest, `{failures, until, stopped}`.
  function revertedBatch(ids, block) {
    const struck = new Set(ids.flatMap((id) => strikeKeys(id)));
    for (const r of new Set(ids.map((id) => known.get(id)).filter(Boolean).map((r) => `batch:${r.index.toLowerCase()}:${r.stable.toLowerCase()}`))) {
      routes.forgetKey(r);
    }
    let worst = { failures: 0, until: 0, stopped: false };
    for (const k of struck) {
      const b = reverts.fail(k, block);
      if (b.stopped || b.until > worst.until) worst = { ...b, stopped: worst.stopped || b.stopped };
    }
    return worst;
  }

  return { scan, best, keys, forget, reverted, revertedBatch };
}
