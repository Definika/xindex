import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CHAINS, COINS, LOCAL_COINS, PRICE_IDS, coinsOf } from "../../restock/coins.mjs";
import { SHARE_PRICED_IDS } from "../../bot/config.mjs";

const read = (path) => readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8");
const addresses = read("script/MainnetAddresses.sol");
const pythIds = read("script/PythIds.sol");

test("RZ-5: every coin is the copy MainnetAddresses lists, from the home token, chain and decimals its comment names", () => {
  assert.equal(COINS.length, 3);
  for (const c of COINS) {
    const constant = new RegExp(`/// @dev ([^\\n]*)\\n\\s*address internal constant ${c.name} = (0x[0-9a-fA-F]{40});`).exec(addresses);
    assert.ok(constant, `${c.symbol}: MainnetAddresses has no ${c.name}`);
    const [, comment, address] = constant;
    assert.equal(c.copy, address.toLowerCase(), `${c.symbol}'s copy`);
    assert.match(comment, new RegExp(`Wormhole chain ${CHAINS[c.chain].wormhole}\\)`), `${c.symbol}'s home chain`);
    assert.match(comment, new RegExp(`${c.decimals} decimals\\.$`), `${c.symbol}'s decimals`);
    assert.ok(comment.toLowerCase().includes(c.home.toLowerCase()), `${c.symbol}'s home token ${c.home}`);
  }
});

test("every coin is priced at the feed PythIds names for it", () => {
  // The table names each feed after its coin's constant in MainnetAddresses. No contract reads it: it is
  // this service's own price catalogue.
  for (const c of COINS) {
    const id = new RegExp(`bytes32 internal constant ${c.name} = (0x[0-9a-f]{64});`).exec(pythIds);
    assert.ok(id, `${c.symbol}: PythIds has no ${c.name}`);
    assert.equal(PRICE_IDS[c.symbol], id[1], `${c.symbol}'s feed`);
  }
  assert.deepEqual(Object.keys(PRICE_IDS).sort(), [...COINS, ...LOCAL_COINS].map((c) => c.symbol).sort());
});

test("every local coin is the Ondo token MainnetAddresses lists, priced at its token's own feed, which the keeper values", () => {
  assert.equal(LOCAL_COINS.length, 9);
  for (const c of LOCAL_COINS) {
    const constant = new RegExp(`address internal constant ${c.name} = (0x[0-9a-fA-F]{40});`).exec(addresses);
    assert.ok(constant, `${c.symbol}: MainnetAddresses has no ${c.name}`);
    assert.equal(c.copy, constant[1].toLowerCase(), `${c.symbol}'s token`);
    assert.equal(c.home, c.copy, "its home is the token itself");
    assert.equal(c.chain, "ethereum");
    assert.equal(c.local, true);
    assert.equal(c.decimals, 18);
    const id = new RegExp(`bytes32 internal constant ${c.name} = (0x[0-9a-f]{64});`).exec(pythIds);
    assert.ok(id, `${c.symbol}: PythIds has no ${c.name}`);
    assert.equal(PRICE_IDS[c.symbol], id[1], `${c.symbol}'s feed`);
    // A share-priced leg the keeper never delivers from stock (RX-2): stock of it would serve no fill.
    assert.ok(!SHARE_PRICED_IDS.includes(id[1]), `${c.symbol} is priced at its token's own feed`);
  }
  assert.ok(COINS.every((c) => !c.local), "the bridged coins are not local");
});

test("every home chain is an EVM chain that runs CCTP, and every coin's chain is one of them", () => {
  // The plan funds a home float through CCTP alone (plan.mjs): a chain without it would never be funded.
  assert.deepEqual(Object.keys(CHAINS), ["avalanche", "optimism", "base"]);
  for (const [name, ch] of Object.entries(CHAINS)) {
    assert.equal(ch.platform, "evm", name);
    assert.equal(typeof ch.cctpDomain, "number", `${name} runs CCTP`);
  }
  for (const c of COINS) assert.ok(CHAINS[c.chain], `${c.symbol}'s chain is known`);
});

test("a subset of the coins is chosen by symbol, and an unknown symbol is refused", () => {
  assert.deepEqual(coinsOf(null).map((c) => c.symbol), ["AVAX"], "the served coins by default");
  assert.deepEqual(
    coinsOf(null, { uniswapx: true }).map((c) => c.symbol),
    ["AVAX", ...LOCAL_COINS.map((c) => c.symbol)],
    "and every local coin with a UniswapX key",
  );
  assert.deepEqual(coinsOf(["NVDAON", "AVAX"]).map((c) => c.symbol), ["AVAX", "NVDAON"], "a local coin named, with or without the key");
  assert.deepEqual(coinsOf(["OP"]).map((c) => c.symbol), ["OP"], "OP, off the list, only when named");
  assert.deepEqual(coinsOf(["AERO"]).map((c) => c.symbol), ["AERO"], "AERO, off the list, only when named");
  assert.ok(coinsOf(null).every((c) => CHAINS[c.chain].platform === "evm"), "each with its chain's adapter built");
  assert.deepEqual(coinsOf(["AERO", "OP"]).map((c) => c.symbol), ["OP", "AERO"], "in the table's order");
  assert.throws(() => coinsOf(["AERO", "XRP"]), /unknown restock coins: XRP/, "a coin that left the table");
});
