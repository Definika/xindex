// The keeper's request filler: `MintRequests` requests the executor can fill now, each simulated exactly as block L+1
// would run it, as the auction fills are. A mint request is filled with exactly its limit in shares, bought from stock
// and along routes; a redeem request is paid exactly its limit in its stablecoin, the escrowed shares redeemed and
// their basket sold. Any surplus over a limit is the filler's, which is why the app suggests limits.

import { encodeFunctionData } from "viem";
import { ABI, revertReason } from "./chain.mjs";
import { MAINNET, TX_GAS_CAP } from "./config.mjs";
import { priceKey } from "./hermes.mjs";
import * as M from "./math.mjs";

const INT256_MIN = -(2n ** 255n);
const HERMES_MS = 5_000;
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

export function createRequestFiller({ chain, cfg, hermes, routes, requests, staticsOf, log }) {
  const known = new Map(); // id -> request, every request seen that was still open at the last scan
  const said = new Map(); // id -> the last reason logged, so a waiting request is not logged every block
  let scanned = 0n; // the last id read

  function say(id, reason) {
    if (said.get(id) === reason) return;
    said.set(id, reason);
    log(`request ${id}`, reason);
  }

  /// Reads every request made since the last scan, and re-reads the known open ones, dropping those closed.
  async function scan(L) {
    const count = await chain.read(requests, ABI.requests, "requestCount", [], L.number);
    const ids = [...known.keys()];
    for (let id = scanned + 1n; id <= count; id++) ids.push(id);
    scanned = count;
    if (ids.length === 0) return;
    const read = await chain.multicall(
      ids.map((id) => ({ address: requests, abi: ABI.requests, functionName: "getRequest", args: [id] })),
      L.number,
    );
    ids.forEach((id, k) => {
      const r = read[k];
      if (r.status === "success" && r.result.open && BigInt(r.result.deadline) >= L.timestamp) known.set(id, r.result);
      else {
        known.delete(id);
        said.delete(id);
      }
    });
  }

  /// The routes, stock change and routed volume of filling `r`, or `short` naming coins the executor can neither buy
  /// nor deliver from stock, with `stableRoute` for a stablecoin other than USDC.
  async function legs(id, r, st, amounts, L) {
    const key = `request:${id}`;
    const latest = await hermes.latest(st.ids, Date.now() + HERMES_MS);
    const held = await chain.multicall(
      st.tokens.map((t) => ({ address: t, abi: ABI.erc20, functionName: "balanceOf", args: [cfg.executor] })),
      L.number,
    );
    const allowed = await chain.multicall(
      st.tokens.map((t) => ({ address: cfg.executor, abi: ABI.executor, functionName: "stockAllowance", args: [t] })),
      L.number,
    );
    const routeOf = st.tokens.map(() => "0x");
    const short = [];
    let inventoryUsd = 0;
    let routedUsd = 0;
    for (let i = 0; i < st.tokens.length; i++) {
      const token = st.tokens[i];
      const amount = amounts[i];
      if (amount === 0n || same(token, MAINNET.usdc)) continue; // a USDC leg is the float itself
      const p = latest.get(priceKey(st.ids[i]));
      if (!p) return { skip: `no price for ${token}` };
      const dec = st.decimals[i];
      const h = M.min(
        held[i].status === "success" ? held[i].result : 0n,
        allowed[i].status === "success" ? allowed[i].result : 0n,
      );
      let route = null;
      if (r.isMint) {
        if (amount > h) {
          const shortfall = amount - h;
          route = await routes.best({ key, token, side: "buy", amount: shortfall, fairUsd: M.amountUsd(shortfall, dec, p), blockNumber: L.number });
          if (!route) {
            short.push(token);
            continue;
          }
          routedUsd += M.amountUsd(shortfall, dec, p);
        }
        inventoryUsd += M.amountUsd(M.inventoryDelta({ out: 0n, in: amount, held: h, routed: route !== null }), dec, p);
      } else {
        route = await routes.best({ key, token, side: "sell", amount, fairUsd: M.amountUsd(amount, dec, p), blockNumber: L.number });
        if (route) routedUsd += M.amountUsd(amount, dec, p);
        inventoryUsd += M.amountUsd(M.inventoryDelta({ out: amount, in: 0n, held: 0n, routed: route !== null }), dec, p);
      }
      if (route) routeOf[i] = route;
    }
    let stableRoute = "0x";
    const stable = M.stableLeg(r, MAINNET.usdc);
    if (stable) {
      const fairUsd = Number(stable.amount) / 1e6;
      stableRoute = await routes.best({ key, ...stable, fairUsd, blockNumber: L.number });
      if (!stableRoute) return { skip: `no route between ${stable.token} and USDC` };
      routedUsd += fairUsd;
    }
    return { routes: routeOf, stableRoute, inventoryUsd, routedVolumeUsdc: M.usdToUsdcCeil(routedUsd), short };
  }

  /// Request `id`, as a fill this bot could send now: its profit after gas and the transaction, or why not.
  async function evaluate(id, r, L, ethUsd, tip, feeCap) {
    if (ethUsd === null) return { skip: "no ETH price to value gas" };
    const T = L.timestamp + 12n;
    const st = await staticsOf(r.index, L.number);
    const functionName = r.isMint ? "fillMint" : "fillRedeem";
    const amount = r.limit; // exactly the limit: the surplus over it would be the requester's
    let amounts;
    try {
      amounts = r.isMint
        ? await chain.read(r.index, ABI.hub, "previewIssue", [amount], L.number)
        : await chain.read(r.index, ABI.hub, "previewRedeem", [r.escrow], L.number);
    } catch (error) {
      return { skip: `no preview: ${revertReason(error)}` };
    }
    const leg = await legs(id, r, st, amounts, L);
    if (leg.skip) return leg;
    if (leg.short.length) return { skip: `restock: no route and too little stock of ${leg.short.join(", ")}` };
    const over = { block: { number: L.number + 1n, time: T } };
    const args = [id, amount, leg.routes, leg.stableRoute, INT256_MIN, T];
    let usdcDelta;
    let inner;
    try {
      [usdcDelta, inner] = await chain.call({ to: cfg.executor, abi: ABI.executor, functionName, args }, L.number, over);
    } catch (error) {
      return { skip: `${functionName} would revert: ${revertReason(error)}` };
    }
    const used = M.txGasUsed(inner, encodeFunctionData({ abi: ABI.executor, functionName, args }));
    if (used > TX_GAS_CAP) return { skip: `${functionName} needs ${used} gas, above EIP-7825's cap` };
    const nextBase = M.nextBaseFee(L);
    if (nextBase + tip > feeCap) return { skip: `base fee ${M.weiToGwei(nextBase)} gwei above MAX_FEE_GWEI` };
    const gasUsd = (Number(used * (nextBase + tip)) / 1e18) * ethUsd;
    const profit = M.profitUsd({ usdcDelta, inventoryUsd: leg.inventoryUsd, gasUsd });
    if (profit < cfg.minProfitUsd) return { skip: `waiting: profit ${profit.toFixed(2)} USD below MIN_PROFIT_USD` };
    const floor = M.usdcFloor({
      simDelta: usdcDelta,
      minProfitUsd: cfg.minProfitUsd,
      gasUsd,
      inventoryUsd: leg.inventoryUsd,
      routedVolumeUsdc: leg.routedVolumeUsdc,
      slippageBps: cfg.slippageBps,
    });
    const data = encodeFunctionData({ abi: ABI.executor, functionName, args: [id, amount, leg.routes, leg.stableRoute, floor, T] });
    const tx = {
      to: cfg.executor,
      data,
      value: 0n,
      gas: M.min(M.gasLimitFor(used), TX_GAS_CAP),
      maxFeePerGas: M.min(2n * nextBase + tip, feeCap),
      maxPriorityFeePerGas: tip,
    };
    return { id, profit, usdcDelta, gasUsd, inventoryUsd: leg.inventoryUsd, tx };
  }

  /// The most profitable request fill this block, if any pays.
  async function best(L, indexes, ethUsd, tip, feeCap) {
    const candidates = M.fillableRequests([...known].map(([id, request]) => ({ id, request })), L.timestamp + 12n, indexes);
    const priced = await Promise.all(
      candidates.map(({ id, request }) =>
        evaluate(id, request, L, ethUsd, tip, feeCap).catch((error) => ({ skip: `check failed: ${revertReason(error)}` })),
      ),
    );
    priced.forEach((p, k) => {
      if (p.skip) say(candidates[k].id, p.skip);
    });
    return priced.filter((p) => !p.skip).sort((a, b) => b.profit - a.profit)[0] ?? null;
  }

  /// The route keys of the requests still known, for the route cache to keep.
  const keys = () => [...known.keys()].map((id) => `request:${id}`);

  return { scan, best, keys, forget: (id) => known.delete(id) && said.delete(id) };
}
