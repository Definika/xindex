import { test } from "node:test";
import assert from "node:assert/strict";
import {
  EXPIRY_MARGIN_SECONDS,
  MAX_ORDER_SECONDS,
  MIN_ORDER_SECONDS,
  PERMIT2,
  REACTOR,
  ROUTING,
  createUniswapXApi,
  inputMax,
  nonceSlot,
  nonceUsed,
  outputMin,
  permitTypedData,
  refusal,
} from "../../restock/uniswapx.mjs";

const TREASURY = "0x1111111111111111111111111111111111111111";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const NVDA = "0x2d1f7226bd1f780af6b9a49dcc0ae00e8df4bdee";
const COSIGNER = "0x2222222222222222222222222222222222222222";
const ZERO = "0x0000000000000000000000000000000000000000";
const NOW = 1_764_000_000;
const E18 = 10n ** 18n;

/// An order as the API would build one for 1,980 USDC of NVDAon, 10.89 at the least, decoded.
function order(over = {}) {
  const o = {
    info: {
      reactor: REACTOR.toUpperCase().replace("0X", "0x"),
      swapper: TREASURY,
      nonce: 1_993_353n,
      deadline: BigInt(NOW + 120),
      additionalValidationContract: ZERO,
      additionalValidationData: "0x",
    },
    cosigner: COSIGNER,
    baseInput: { token: USDC, startAmount: 1_980_000_000n, endAmount: 1_980_000_000n },
    baseOutputs: [{ token: NVDA, startAmount: 11n * E18, endAmount: 1090n * 10n ** 16n, recipient: TREASURY }],
    cosignerData: { decayStartTime: 0n, decayEndTime: 0n, exclusiveFiller: ZERO, exclusivityOverrideBps: 0n, inputAmount: 0n, outputAmounts: [0n] },
    cosignature: "0x",
  };
  return {
    ...o,
    ...over,
    info: { ...o.info, ...over.info },
    baseInput: { ...o.baseInput, ...over.baseInput },
    baseOutputs: over.baseOutputs ?? o.baseOutputs,
  };
}
const WANT = { swapper: TREASURY, tokenIn: USDC, tokenOut: NVDA, maxIn: 1_980_000_000n, minOut: 1089n * 10n ** 16n, now: NOW, openNonces: [] };

test("an order the plan allows is signed: its reactor, swapper, input, one output to the treasury and its least amount", () => {
  assert.equal(refusal(order(), WANT), null);
  assert.equal(inputMax(order()), 1_980_000_000n);
  assert.equal(outputMin(order()), 1090n * 10n ** 16n, "the output's end amount, where it decays to");
  assert.equal(refusal(order({ baseOutputs: [{ token: NVDA, startAmount: 1089n * 10n ** 16n, endAmount: 12n * E18, recipient: TREASURY }] }), WANT), null, "a rising output is bounded by its start");
});

test("an order is refused for any field its signature commits to that the plan did not allow", () => {
  const out = (o) => ({ baseOutputs: [{ token: NVDA, startAmount: 11n * E18, endAmount: 1090n * 10n ** 16n, recipient: TREASURY, ...o }] });
  const cases = [
    [{ info: { reactor: "0x0000000015757c461808EA25Eb309638B62681cf" } }, /its reactor is 0x0000000015757c461808EA25Eb309638B62681cf, not UniswapX's V2 reactor/],
    [{ info: { swapper: COSIGNER } }, /its swapper is .*, not the treasury/],
    [{ info: { additionalValidationContract: COSIGNER } }, /it names a validation contract/],
    [{ info: { additionalValidationData: "0x01" } }, /it names a validation contract/],
    [{ info: { deadline: BigInt(NOW + MIN_ORDER_SECONDS - 1) } }, /its deadline is 29 s away, outside 30 to 900/],
    [{ info: { deadline: BigInt(NOW + MAX_ORDER_SECONDS + 1) } }, /its deadline is 901 s away/],
    [{ baseInput: { token: NVDA } }, /it spends 0x2d1f.*, not USDC/],
    [{ baseInput: { startAmount: 0n } }, /it spends nothing/],
    [{ baseInput: { endAmount: 1_980_000_001n } }, /it may spend 1980000001, above the 1980000000 allowed/],
    [{ baseInput: { startAmount: 1_980_000_001n } }, /it may spend 1980000001/],
    [{ baseOutputs: [] }, /it has 0 outputs, not one/],
    [{ baseOutputs: [...order().baseOutputs, { token: NVDA, startAmount: 1n, endAmount: 1n, recipient: COSIGNER }] }, /it has 2 outputs, not one/],
    [out({ token: USDC }), /it pays 0xA0b8.*, not the coin/],
    [out({ recipient: COSIGNER }), /it pays 0x2222.*, not the treasury/],
    [out({ endAmount: 1089n * 10n ** 16n - 1n }), /it may pay 10889999999999999999, below the 10890000000000000000 the loss bound allows/],
    [out({ startAmount: 1089n * 10n ** 16n - 1n, endAmount: 12n * E18 }), /below the 10890000000000000000/],
  ];
  for (const [over, why] of cases) assert.match(refusal(order(over), WANT) ?? "signed", why);
  assert.match(refusal(order(), { ...WANT, openNonces: [5n, 1_993_353n] }), /its nonce 1993353 is an open order's/);
});

test("the typed data signed is Permit2's witness transfer of the input's end amount to the reactor, the checked order its witness", () => {
  const o = order({ baseInput: { startAmount: 1_900_000_000n } });
  const t = permitTypedData(o, 1);
  assert.deepEqual(t.domain, { name: "Permit2", chainId: 1, verifyingContract: PERMIT2 });
  assert.equal(t.primaryType, "PermitWitnessTransferFrom");
  // The field order of each type is the reactor's (V2DutchOrderLib, OrderInfoLib, DutchOrderLib): any other hashes to
  // another order, whose signature fails on chain.
  const names = (type) => t.types[type].map((f) => `${f.type} ${f.name}`).join(",");
  assert.equal(names("PermitWitnessTransferFrom"), "TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,V2DutchOrder witness");
  assert.equal(names("V2DutchOrder"), "OrderInfo info,address cosigner,address baseInputToken,uint256 baseInputStartAmount,uint256 baseInputEndAmount,DutchOutput[] baseOutputs");
  assert.equal(names("OrderInfo"), "address reactor,address swapper,uint256 nonce,uint256 deadline,address additionalValidationContract,bytes additionalValidationData");
  assert.equal(names("DutchOutput"), "address token,uint256 startAmount,uint256 endAmount,address recipient");
  assert.equal(names("TokenPermissions"), "address token,uint256 amount");
  assert.deepEqual(t.message.permitted, { token: USDC, amount: 1_980_000_000n });
  assert.equal(t.message.spender, o.info.reactor);
  assert.equal(t.message.nonce, o.info.nonce);
  assert.equal(t.message.deadline, o.info.deadline);
  assert.deepEqual(t.message.witness, {
    info: o.info,
    cosigner: COSIGNER,
    baseInputToken: USDC,
    baseInputStartAmount: 1_900_000_000n,
    baseInputEndAmount: 1_980_000_000n,
    baseOutputs: o.baseOutputs,
  });
  assert.ok(!("cosignerData" in t.message.witness), "the cosigner's data is not the swapper's to sign");
});

test("Permit2's nonce bitmap says whether an order's nonce is spent", () => {
  assert.deepEqual(nonceSlot(0n), { word: 0n, bit: 0n });
  assert.deepEqual(nonceSlot(1_993_353n), { word: 7786n, bit: 137n });
  assert.equal(nonceUsed(0n, 137n), false);
  assert.equal(nonceUsed(1n << 137n, 137n), true);
  assert.equal(nonceUsed((1n << 137n) - 1n, 137n), false, "the bits below it are other nonces");
  assert.equal(nonceUsed(1n << 138n, 137n), false);
});

test("the constants: one reactor, one routing, and a finality margin before an order is given up", () => {
  assert.equal(REACTOR, "0x00000011f84b9aa48e5f8aa8b9897600006289be");
  assert.equal(PERMIT2, "0x000000000022d473030f116ddee9f6b43ac78ba3");
  assert.equal(ROUTING, "DUTCH_V2");
  assert.ok(EXPIRY_MARGIN_SECONDS >= 900, "past Ethereum's finality");
  assert.ok(MIN_ORDER_SECONDS < MAX_ORDER_SECONDS);
});

/// A stand-in for fetch that records each request and answers `status` with `body`.
function fakeFetch(answers) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, ...init, body: JSON.parse(init.body) });
    const [status, body] = answers.shift();
    return { status, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) };
  };
  return { fetch, calls };
}

test("the API is asked for an exact USDC spend through UniswapX's V2 orders, with the key, and a 404 is no offer", async () => {
  const quote = { encodedOrder: "0x00", orderId: "0xab" };
  const { fetch, calls } = fakeFetch([
    [200, { routing: ROUTING, quote, permitData: {} }],
    [404, { errorCode: "NoRouteFoundError" }],
    [500, "upstream down"],
    [200, { routing: ROUTING }],
  ]);
  const api = createUniswapXApi({ url: "https://ux.example/v1/", apiKey: "ux-key", fetch });
  const ask = { tokenIn: USDC, tokenOut: NVDA, amount: 1_980_000_000n, swapper: TREASURY, chainId: 1 };
  assert.deepEqual(await api.quote(ask), { routing: ROUTING, quote });
  assert.equal(calls[0].url, "https://ux.example/v1/quote");
  assert.equal(calls[0].method, "POST");
  assert.equal(calls[0].headers["x-api-key"], "ux-key");
  assert.equal(calls[0].headers["content-type"], "application/json");
  assert.deepEqual(calls[0].body, {
    type: "EXACT_INPUT",
    amount: "1980000000",
    tokenIn: USDC,
    tokenOut: NVDA,
    tokenInChainId: 1,
    tokenOutChainId: 1,
    swapper: TREASURY,
    routingPreference: "BEST_PRICE",
    protocols: ["UNISWAPX_V2"],
  });
  assert.equal(await api.quote(ask), null, "no route, an amount below the API's minimum: no offer");
  await assert.rejects(api.quote(ask), /UniswapX quote: HTTP 500: upstream down/);
  await assert.rejects(api.quote(ask), /HTTP 200/, "an answer without a quote is no offer to take");
});

test("a signed order is posted with the quote as the API returned it, and a refusal throws", async () => {
  const quote = { encodedOrder: "0x00", orderId: "0xab", extra: { kept: true } };
  const { fetch, calls } = fakeFetch([
    [201, { orderId: "0xab", orderStatus: "open" }],
    [400, { errorCode: "InputValidationError", detail: "Onchain validation failed: InvalidSignature" }],
  ]);
  const api = createUniswapXApi({ url: "https://ux.example/v1", apiKey: "k", fetch });
  assert.deepEqual(await api.post({ signature: "0xsig", quote, routing: ROUTING }), { orderId: "0xab", orderStatus: "open" });
  assert.equal(calls[0].url, "https://ux.example/v1/order");
  assert.deepEqual(calls[0].body, { signature: "0xsig", quote, routing: ROUTING }, "the quote untouched");
  await assert.rejects(api.post({ signature: "0xsig", quote, routing: ROUTING }), /UniswapX order: HTTP 400: .*InvalidSignature/);
});
