// Run: node --test swaprail/
// Fixtures are live THORNode responses of 2026-10-06 (gateway.liquify.com/chain/thorchain_api): inbound addresses,
// the Asgard vaults (trimmed to status, addresses and routers), and two quotes: 1,000 USDC to BTC, 0.1 BTC to USDC.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  planExitFromEthereum,
  planFundToEthereum,
  swapMemo,
  toThorUnits,
  encodeDeposit,
  networkState,
  RailError,
  MIN_QUOTE_LIFE,
} from "./thorchain.mjs";

const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), "utf8"));
const NODES = ["https://node-a.example", "https://node-b.example"];
const USER = "0x7a093cebfa77403672d68e1c22d0681400a36682";
const BTC_DEST = "bc1q6527vxxqjpq80la2l0sw7hay3lj6dz07zs6gzl";
const USDC = "ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48";
const ROUTER = "0xd37bbe5744d730a1d98d8dc97c42f0ca46ad7146";

/// A fetch that serves the fixtures, optionally edited per node.
function fakeFetch({ edit = () => {}, quote } = {}) {
  return async (url) => {
    const u = new URL(url);
    const node = `${u.protocol}//${u.host}`;
    let body;
    if (u.pathname === "/thorchain/inbound_addresses") body = fixture("inbound_addresses");
    else if (u.pathname === "/thorchain/vaults/asgard") body = fixture("vaults_asgard");
    else if (u.pathname === "/thorchain/quote/swap") {
      body = quote ?? fixture(u.searchParams.get("from_asset") === "BTC.BTC" ? "quote_btc_to_usdc" : "quote_usdc_to_btc");
    } else return { ok: false, status: 404 };
    edit(node, u.pathname, body);
    return { ok: true, status: 200, json: async () => body };
  };
}

const exitArgs = (over = {}) => ({
  nodes: NODES,
  fetchImpl: fakeFetch(),
  from: USER,
  sellAsset: USDC,
  amount: 1_000_000_000n, // 1,000 USDC
  buyAsset: "BTC.BTC",
  destination: BTC_DEST,
  now: 1791302639 - 900,
  isContract: async () => false,
  ...over,
});

const fundArgs = (over = {}) => ({
  nodes: NODES,
  fetchImpl: fakeFetch(),
  sellAsset: "BTC.BTC",
  amount: 10_000_000n, // 0.1 BTC
  buyAsset: USDC,
  destination: USER,
  now: 1791302651 - 900,
  isContract: async () => false,
  ...over,
});

const refuses = async (promise, pattern) => {
  await assert.rejects(promise, (e) => e instanceof RailError && pattern.test(e.message));
};

test("THORChain amounts are 1e8 units whatever the decimals", () => {
  assert.equal(toThorUnits(1_000_000_000n, 6), 100_000_000_000n);
  assert.equal(toThorUnits(10n ** 18n, 18), 100_000_000n);
  assert.equal(toThorUnits(12_345n, 8), 12_345n);
});

test("the deposit's calldata matches cast's encoding of depositWithExpiry", () => {
  const memo = `=:BTC.BTC:${BTC_DEST}/${USER}:1137580/1/0`;
  const expected =
    "0x44bc937b000000000000000000000000d16e79edc37cae2019ae049bbc37587a94405960000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000006ac51bef000000000000000000000000000000000000000000000000000000000000006b3d3a4254432e4254433a6263317136353237767878716a707138306c61326c30737737686179336c6a36647a30377a7336677a6c2f3078376130393363656266613737343033363732643638653163323264303638313430306133363638323a313133373538302f312f30000000000000000000000000000000000000000000";
  const data = encodeDeposit(
    "0xd16e79edc37cae2019ae049bbc37587a94405960",
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    1_000_000_000n,
    memo,
    1791302639n,
  );
  assert.equal(data, expected);
});

test("a memo uses the full asset id when it fits, the ticker when it must, and refuses past the limit", () => {
  assert.equal(swapMemo({ asset: USDC, destination: USER, limit: 5n, sourceChain: "ETH" }), `=:${USDC}:${USER}:5/1/0`);
  assert.equal(swapMemo({ asset: USDC, destination: USER, limit: 5n, sourceChain: "BTC" }), `=:ETH.USDC:${USER}:5/1/0`);
  assert.throws(() => swapMemo({ asset: USDC, destination: USER, refund: BTC_DEST, limit: 5n, sourceChain: "BTC" }), RailError);
  assert.throws(() => swapMemo({ asset: USDC, destination: USER, limit: 0n, sourceChain: "ETH" }), RailError);
});

test("exit: 1,000 USDC to BTC from the user's own account, through the pinned router", async () => {
  const plan = await planExitFromEthereum(exitArgs());
  assert.equal(plan.router, ROUTER);
  assert.equal(plan.vault, "0xd16e79edc37cae2019ae049bbc37587a94405960");
  assert.equal(plan.expectedOut, 1_156_814n);
  assert.equal(plan.limit, 1_145_245n, "the expected output less 1%");
  assert.equal(plan.memo, `=:BTC.BTC:${BTC_DEST}/${USER}:1145245/1/0`, "the user is the refund address");
  assert.equal(plan.transactions.length, 3);
  const [reset, approve, deposit] = plan.transactions;
  assert.equal(reset.to, "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
  assert.ok(reset.data.endsWith("0".repeat(64)), "the allowance is reset first, as USDT requires");
  assert.ok(approve.data.endsWith((1_000_000_000n).toString(16).padStart(64, "0")), "then exactly the amount");
  assert.equal(deposit.to, ROUTER, "the user's own transaction to the router");
  assert.equal(deposit.value, 0n);
  assert.equal(
    deposit.data,
    encodeDeposit(plan.vault, "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 1_000_000_000n, plan.memo, 1791302639n),
  );
});

test("exit: ether is sent as value, with no approval", async () => {
  const plan = await planExitFromEthereum(exitArgs({ sellAsset: "ETH.ETH", amount: 10n * 10n ** 18n }));
  assert.equal(plan.transactions.length, 1);
  assert.equal(plan.transactions[0].value, 10n * 10n ** 18n);
});

test("fund: 0.1 BTC to USDC at the user's Ethereum account, the memo short enough for OP_RETURN", async () => {
  const plan = await planFundToEthereum(fundArgs());
  assert.equal(plan.vault, "bc1qvx2krgnwyehcrjmz25t9vyt39fvxkthz38uuy8");
  assert.equal(plan.memo, `=:ETH.USDC:${USER}:849922128495/1/0`);
  assert.ok(new TextEncoder().encode(plan.memo).length <= 80);
});

test("refusals: contracts, wrong assets and wrong directions", async () => {
  await refuses(planExitFromEthereum(exitArgs({ isContract: async (_, a) => a === USER })), /externally owned/);
  await refuses(
    planExitFromEthereum(exitArgs({ buyAsset: "BSC.BNB", destination: "0x1111111111111111111111111111111111111111", isContract: async (c) => c === "BSC" })),
    /not a contract/,
  );
  await refuses(planFundToEthereum(fundArgs({ isContract: async () => true })), /own account/);
  await refuses(planExitFromEthereum(exitArgs({ buyAsset: USDC })), /belongs on the zap/);
  await refuses(planExitFromEthereum(exitArgs({ sellAsset: "ETH.LINK-0X514910771AF9CA656AF840DFF83E8264ECF986CA" })), /not an Ethereum asset/);
  await refuses(planFundToEthereum(fundArgs({ sellAsset: "BSC.BNB" })), /UTXO/);
  await refuses(planFundToEthereum(fundArgs({ buyAsset: "ETH.AAVE-0X7FC66500C84A76AD7E9C93437BFC5AC33E2DDAE9" })), /zap mints with/);
  await refuses(planFundToEthereum(fundArgs({ destination: BTC_DEST })), /Ethereum address/);
  await refuses(planExitFromEthereum(exitArgs({ isContract: undefined })), /isContract/);
  await refuses(planExitFromEthereum(exitArgs({ amount: 0n })), /nothing/);
});

test("refusals: the network's state", async () => {
  await refuses(planExitFromEthereum(exitArgs({ nodes: [NODES[0]] })), /two independent/);
  const halt = (chain, field) => (node, path, body) => {
    if (path === "/thorchain/inbound_addresses") body.find((c) => c.chain === chain)[field] = true;
  };
  await refuses(planExitFromEthereum(exitArgs({ fetchImpl: fakeFetch({ edit: halt("ETH", "halted") }) })), /halted or paused/);
  await refuses(planExitFromEthereum(exitArgs({ fetchImpl: fakeFetch({ edit: halt("BTC", "chain_trading_paused") }) })), /halted or paused/);
  await refuses(planFundToEthereum(fundArgs({ fetchImpl: fakeFetch({ edit: halt("ETH", "global_trading_paused") }) })), /halted or paused/);
  const otherRouter = (node, path, body) => {
    if (node === NODES[1] && path === "/thorchain/inbound_addresses") body.find((c) => c.chain === "ETH").router = "0x00dc6100103BC402d490aEE3F9a5560cBd91f1d4";
  };
  await refuses(planExitFromEthereum(exitArgs({ fetchImpl: fakeFetch({ edit: otherRouter }) })), /disagree/);
  const retired = (node, path, body) => {
    if (node === NODES[1] && path === "/thorchain/vaults/asgard") {
      for (const v of body) if (v.addresses.some((a) => a.address === "0xd16e79edc37cae2019ae049bbc37587a94405960")) v.status = "RetiringVault";
    }
  };
  await refuses(planExitFromEthereum(exitArgs({ fetchImpl: fakeFetch({ edit: retired }) })), /not an active vault/);
  const failing = async () => ({ ok: false, status: 503 });
  await refuses(planExitFromEthereum(exitArgs({ fetchImpl: failing })), /THORNode 503/);
  await assert.rejects(networkState(NODES, fakeFetch(), ["XYZ"]), /lists no XYZ/);
});

test("refusals: the quote", async () => {
  const q = () => fixture("quote_usdc_to_btc");
  const withQuote = (edit) => {
    const quote = q();
    edit(quote);
    return exitArgs({ fetchImpl: fakeFetch({ quote }) });
  };
  await refuses(planExitFromEthereum(withQuote((x) => (x.router = "0x00dc6100103BC402d490aEE3F9a5560cBd91f1d4"))), /not pinned/);
  await refuses(planExitFromEthereum(withQuote((x) => (x.inbound_address = "0x0000000000000000000000000000000000000bad"))), /not an active vault/);
  await refuses(planExitFromEthereum(withQuote((x) => (x.fees.asset = "BTC.FAKE"))), /resolves the output/);
  await refuses(planExitFromEthereum(withQuote((x) => (x.expiry = 1791302639 - 900 + MIN_QUOTE_LIFE - 1))), /expires too soon/);
  await refuses(planExitFromEthereum(withQuote((x) => (x.fees.total_bps = 101))), /fees of 101/);
  await refuses(planExitFromEthereum(withQuote((x) => (x.recommended_min_amount_in = "100000000001"))), /recommended minimum/);
  await refuses(planExitFromEthereum(withQuote((x) => (x.expected_amount_out = "0"))), /expects nothing/);
  await refuses(planExitFromEthereum(exitArgs({ amount: 1n })), /recommended minimum|dust/);
  // A router that is pinned but is not the one the network names.
  const edited = (node, path, body) => {
    if (path === "/thorchain/inbound_addresses") body.find((c) => c.chain === "ETH").router = "0x00dc6100103BC402d490aEE3F9a5560cBd91f1d4";
  };
  await refuses(planExitFromEthereum(exitArgs({ fetchImpl: fakeFetch({ edit: edited }) })), /not the network's/);
});
