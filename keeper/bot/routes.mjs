// Uniswap V3 routes between a component and USDC, chosen by quoting each leg at its own size. A route is an
// exact-input path from the component to USDC; read as an exact-output path, the same bytes buy the component. A leg
// whose best route loses more than ROUTE_MAX_LOSS_BPS against Pyth gets none, and the executor's inventory serves it.

import { encodePacked } from "viem";
import { ABI } from "./chain.mjs";
import { MAINNET } from "./config.mjs";
import { routeLossBps } from "./math.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const DIRECT_FEES = [100, 500, 3000, 10000];
const VIA_WETH_FEES = [500, 3000, 10000];
const WETH_USDC_FEE = 500;

const path = (...hops) => encodePacked(hops.map((_, i) => (i % 2 ? "uint24" : "address")), hops);

export function createRoutes(chain, cfg) {
  const candidatesOf = new Map(); // token -> paths whose pools exist (pools are never removed)
  const chosen = new Map(); // `${index}:${proposal}:${token}:${side}` -> path | null, for one auction

  async function candidates(token, blockNumber) {
    const t = token.toLowerCase();
    if (candidatesOf.has(t)) return candidatesOf.get(t);
    const options = DIRECT_FEES.map((fee) => ({ pool: [token, MAINNET.usdc, fee], path: path(token, fee, MAINNET.usdc) }));
    if (t !== MAINNET.weth.toLowerCase()) {
      for (const fee of VIA_WETH_FEES) {
        options.push({ pool: [token, MAINNET.weth, fee], path: path(token, fee, MAINNET.weth, WETH_USDC_FEE, MAINNET.usdc) });
      }
    }
    const pools = await chain.multicall(
      options.map((o) => ({ address: MAINNET.v3Factory, abi: ABI.v3Factory, functionName: "getPool", args: o.pool })),
      blockNumber,
    );
    const found = options.filter((_, i) => pools[i].status === "success" && pools[i].result !== ZERO).map((o) => o.path);
    candidatesOf.set(t, found);
    return found;
  }

  async function quote(side, route, amount, blockNumber) {
    const functionName = side === "sell" ? "quoteExactInput" : "quoteExactOutput";
    try {
      const [usdc] = await chain.call(
        { to: MAINNET.quoterV2, abi: ABI.quoter, functionName, args: [route, amount] },
        blockNumber,
      );
      return usdc;
    } catch {
      return null; // no liquidity along this path
    }
  }

  /// The route for selling (`side` "sell") or buying ("buy") `amount` of `token`, worth `fairUsd` at Pyth, in the
  /// auction `key`; null when none loses at most ROUTE_MAX_LOSS_BPS. Chosen once per auction.
  async function best({ key, token, side, amount, fairUsd, blockNumber }) {
    const k = `${key}:${token.toLowerCase()}:${side}`;
    if (chosen.has(k)) return chosen.get(k);
    let pick = null;
    let pickUsdc = null;
    for (const route of await candidates(token, blockNumber)) {
      const usdc = await quote(side, route, amount, blockNumber);
      if (usdc === null) continue;
      if (pickUsdc === null || (side === "sell" ? usdc > pickUsdc : usdc < pickUsdc)) {
        pick = route;
        pickUsdc = usdc;
      }
    }
    const result = pick !== null && routeLossBps(side, pickUsdc, fairUsd) <= cfg.routeMaxLossBps ? pick : null;
    chosen.set(k, result);
    return result;
  }

  /// Forgets the routes of auctions that are over.
  function forget(keepKeys) {
    for (const k of chosen.keys()) if (!keepKeys.some((key) => k.startsWith(`${key}:`))) chosen.delete(k);
  }

  return { best, forget };
}
