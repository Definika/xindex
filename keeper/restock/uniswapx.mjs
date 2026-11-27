// Buying a coin Ethereum issues itself, which no pool sells, through UniswapX (`coins.mjs` LOCAL_COINS): the treasury
// asks Uniswap's Trading API for an order spending USDC on the coin, checks every field of it that its signature will
// commit to, and signs only what passed, over its own encoding of those fields. A filler, Ondo's minting desk among
// them, then settles it through UniswapX's reactor, which pulls the USDC through Permit2 with that signature and pays
// the coin to the treasury in the same transaction; the treasury deposits it into the executor (`depositStock`).
//
// Nothing the API says is trusted. The order's reactor, swapper, input, outputs, recipient, deadline and validation
// contract are checked here, the coin's least amount against Pyth's price within ROUTE_MAX_LOSS_BPS, and the typed data
// signed is built from the checked fields, never taken from the API: an order the API altered after the check fails
// its signature on chain and moves nothing. The reactor lets the order's cosigner improve the amounts and set the
// decay's times, never worsen them, so the signed bounds hold whatever the cosigner does. Whether an order filled is
// read from Permit2's nonce bitmap, not from the API. No dependencies, so the unit tests run without `npm install`.

/// Permit2, the same on every chain.
export const PERMIT2 = "0x000000000022d473030f116ddee9f6b43ac78ba3";
/// UniswapX's V2 Dutch order reactor on Ethereum, the one reactor the service signs for: the Trading API's DUTCH_V2
/// orders settle there, Ondo's stocks among them (read on chain: ten AAPLon and NVDAon fills in 9,000 blocks, and
/// none through the V3 reactor). Its `permit2()` is PERMIT2, which restock.mjs checks before it serves a local coin.
export const REACTOR = "0x00000011f84b9aa48e5f8aa8b9897600006289be";
/// The routing the Trading API names that reactor's orders by.
export const ROUTING = "DUTCH_V2";
/// The soonest and the latest an order's deadline may be, in seconds from now: long enough for a filler to settle it,
/// short enough that the USDC it may take is not tied up for long.
export const MIN_ORDER_SECONDS = 30;
export const MAX_ORDER_SECONDS = 900;
/// How long after its deadline an order that has not filled is given up: Ethereum's finality, after which no block that
/// could still settle it is undone.
export const EXPIRY_MARGIN_SECONDS = 900;

const ZERO = "0x0000000000000000000000000000000000000000";
const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
const min = (a, b) => (a < b ? a : b);
const max = (a, b) => (a > b ? a : b);

/// The most USDC `order` can take: its input's larger amount. The reactor pays out the input's decayed amount, which
/// Permit2 caps at the end amount, and a cosigner may only lower the start.
export const inputMax = (order) => max(order.baseInput.startAmount, order.baseInput.endAmount);
/// The least of the coin `order` can pay its one output's recipient: the output's smaller amount. Its amount decays
/// between the two, and a cosigner may only raise the start.
export const outputMin = (order) => min(order.baseOutputs[0].startAmount, order.baseOutputs[0].endAmount);

/// Why the service must not sign `order` (a V2 Dutch order, as `uniswapx-chain.mjs` decodes the API's encodedOrder),
/// or null when it may. `want`: `swapper` (the treasury), `tokenIn` (USDC), `tokenOut` (the coin), `maxIn` (the most
/// USDC the buy may spend), `minOut` (the least of the coin it must bring, the plan's bound at Pyth), `now` (the chain's
/// time, in seconds) and `openNonces` (the Permit2 nonces of the orders still open).
export function refusal(order, { swapper, tokenIn, tokenOut, maxIn, minOut, now, openNonces = [] }) {
  const { info, baseInput, baseOutputs } = order;
  if (!same(info.reactor, REACTOR)) return `its reactor is ${info.reactor}, not UniswapX's V2 reactor`;
  if (!same(info.swapper, swapper)) return `its swapper is ${info.swapper}, not the treasury`;
  if (!same(info.additionalValidationContract, ZERO) || info.additionalValidationData !== "0x") {
    return "it names a validation contract";
  }
  if (info.deadline < BigInt(now + MIN_ORDER_SECONDS) || info.deadline > BigInt(now + MAX_ORDER_SECONDS)) {
    return `its deadline is ${info.deadline - BigInt(now)} s away, outside ${MIN_ORDER_SECONDS} to ${MAX_ORDER_SECONDS}`;
  }
  if (openNonces.some((n) => n === info.nonce)) return `its nonce ${info.nonce} is an open order's`;
  if (!same(baseInput.token, tokenIn)) return `it spends ${baseInput.token}, not USDC`;
  if (baseInput.startAmount === 0n || baseInput.endAmount === 0n) return "it spends nothing";
  if (inputMax(order) > maxIn) return `it may spend ${inputMax(order)}, above the ${maxIn} allowed`;
  if (baseOutputs.length !== 1) return `it has ${baseOutputs.length} outputs, not one`;
  const [out] = baseOutputs;
  if (!same(out.token, tokenOut)) return `it pays ${out.token}, not the coin`;
  if (!same(out.recipient, swapper)) return `it pays ${out.recipient}, not the treasury`;
  if (outputMin(order) < minOut) return `it may pay ${outputMin(order)}, below the ${minOut} the loss bound allows`;
  return null;
}

/// The EIP-712 typed data the swapper signs for `order` on chain `chainId`: Permit2's PermitWitnessTransferFrom, with
/// the order as its witness, as UniswapX's V2 reactor checks it (V2DutchOrderLib, Permit2Lib): the permit is for the
/// input's end amount, to the reactor, under the order's nonce and deadline. Built from the order's checked fields.
export function permitTypedData(order, chainId) {
  const { info, cosigner, baseInput, baseOutputs } = order;
  return {
    domain: { name: "Permit2", chainId, verifyingContract: PERMIT2 },
    primaryType: "PermitWitnessTransferFrom",
    types: {
      PermitWitnessTransferFrom: [
        { name: "permitted", type: "TokenPermissions" },
        { name: "spender", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "witness", type: "V2DutchOrder" },
      ],
      TokenPermissions: [
        { name: "token", type: "address" },
        { name: "amount", type: "uint256" },
      ],
      V2DutchOrder: [
        { name: "info", type: "OrderInfo" },
        { name: "cosigner", type: "address" },
        { name: "baseInputToken", type: "address" },
        { name: "baseInputStartAmount", type: "uint256" },
        { name: "baseInputEndAmount", type: "uint256" },
        { name: "baseOutputs", type: "DutchOutput[]" },
      ],
      OrderInfo: [
        { name: "reactor", type: "address" },
        { name: "swapper", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "additionalValidationContract", type: "address" },
        { name: "additionalValidationData", type: "bytes" },
      ],
      DutchOutput: [
        { name: "token", type: "address" },
        { name: "startAmount", type: "uint256" },
        { name: "endAmount", type: "uint256" },
        { name: "recipient", type: "address" },
      ],
    },
    message: {
      permitted: { token: baseInput.token, amount: baseInput.endAmount },
      spender: info.reactor,
      nonce: info.nonce,
      deadline: info.deadline,
      witness: {
        info,
        cosigner,
        baseInputToken: baseInput.token,
        baseInputStartAmount: baseInput.startAmount,
        baseInputEndAmount: baseInput.endAmount,
        baseOutputs,
      },
    },
  };
}

/// Where Permit2 records nonce `nonce` as used: the word of its owner's bitmap (`nonceBitmap(owner, word)`) and the bit
/// in it.
export const nonceSlot = (nonce) => ({ word: nonce >> 8n, bit: nonce & 0xffn });
/// Whether bit `bit` of a nonce bitmap word is set: the nonce is spent, its order settled.
export const nonceUsed = (bitmap, bit) => ((bitmap >> bit) & 1n) === 1n;

/// Uniswap's Trading API, as the service uses it: a quote for an exact USDC spend routed through UniswapX, and the
/// signed order posted back for its fillers. `fetch` is injected for the tests. Every answer is data to check.
export function createUniswapXApi({ url, apiKey, fetch = globalThis.fetch, timeoutMs = 15_000 }) {
  const base = url.replace(/\/+$/, "");
  async function call(path, body) {
    const response = await fetch(`${base}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json", "x-api-key": apiKey },
      body: JSON.stringify(body, (_, v) => (typeof v === "bigint" ? v.toString() : v)),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await response.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {}
    return { status: response.status, json, text };
  }
  return {
    /// An order spending exactly `amount` of `tokenIn` on `tokenOut` for `swapper` on chain `chainId`, through
    /// UniswapX: `{routing, quote}`, or null when the API offers none (no route, an amount below its minimum, a token
    /// it does not serve: its 404s). Any other failure throws.
    async quote({ tokenIn, tokenOut, amount, swapper, chainId }) {
      const r = await call("/quote", {
        type: "EXACT_INPUT",
        amount,
        tokenIn,
        tokenOut,
        tokenInChainId: chainId,
        tokenOutChainId: chainId,
        swapper,
        routingPreference: "BEST_PRICE",
        protocols: ["UNISWAPX_V2"],
      });
      if (r.status === 404) return null;
      if (r.status !== 200 || typeof r.json?.routing !== "string" || typeof r.json?.quote !== "object" || r.json.quote === null) {
        throw new Error(`UniswapX quote: HTTP ${r.status}: ${r.text.slice(0, 300)}`);
      }
      return { routing: r.json.routing, quote: r.json.quote };
    },
    /// Posts `signature` for `quote`, as the API returned it, for its fillers. Throws when the API does not take it;
    /// the order may still have reached a filler, so the caller waits for its deadline either way.
    async post({ signature, quote, routing }) {
      const r = await call("/order", { signature, quote, routing });
      if (r.status < 200 || r.status > 299) throw new Error(`UniswapX order: HTTP ${r.status}: ${r.text.slice(0, 300)}`);
      return r.json;
    },
  };
}
