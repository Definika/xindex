import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CHAINS, COINS, LOCAL_COINS, PRICE_IDS, coinsOf } from "../../restock/coins.mjs";
import { SHARE_PRICED_IDS } from "../../bot/config.mjs";

const read = (path) => readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8");
const addresses = read("script/MainnetAddresses.sol");
const pythIds = read("script/PythIds.sol");

test("RZ-5: every coin is the copy MainnetAddresses lists, from the home token, chain and decimals its comment names", () => {
  assert.equal(COINS.length, 14);
  for (const c of COINS) {
    const constant = new RegExp(`/// @dev ([^\\n]*)\\n\\s*address internal constant ${c.name} = (0x[0-9a-fA-F]{40});`).exec(addresses);
    assert.ok(constant, `${c.symbol}: MainnetAddresses has no ${c.name}`);
    const [, comment, address] = constant;
    assert.equal(c.copy, address.toLowerCase(), `${c.symbol}'s copy`);
    assert.match(comment, new RegExp(`Wormhole chain ${CHAINS[c.chain].wormhole}\\)`), `${c.symbol}'s home chain`);
    assert.match(comment, new RegExp(`${c.decimals} decimals\\.$`), `${c.symbol}'s decimals`);
    const home = c.chain === "algorand" ? `asset ${c.home},` : c.home;
    assert.ok(comment.toLowerCase().includes(home.toLowerCase()), `${c.symbol}'s home token ${home}`);
  }
});

test("every coin is priced at the feed PythIds names for it", () => {
  // The table names each feed after its coin's constant in MainnetAddresses. No contract reads it since the
  // oracle-free rebalance of 2026-11-10: it is this service's own price catalogue.
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

test("only BNB Chain and Algorand go without CCTP, and the gas coins are the three chains' own", () => {
  const manual = Object.entries(CHAINS).filter(([, ch]) => ch.cctpDomain === null).map(([name]) => name);
  assert.deepEqual(manual.sort(), ["algorand", "bsc"]);
  for (const c of COINS) assert.ok(CHAINS[c.chain], `${c.symbol}'s chain is known`);
  assert.deepEqual(COINS.filter((c) => c.isGas).map((c) => `${c.symbol}:${CHAINS[c.chain].gas.symbol}`), ["SUI:SUI", "APT:APT", "ALGO:ALGO"]);
});

test("a subset of the coins is chosen by symbol, and an unknown symbol is refused", () => {
  assert.deepEqual(coinsOf(null).map((c) => c.symbol), ["AVAX", "AERO"], "the served coins by default");
  assert.deepEqual(
    coinsOf(null, { uniswapx: true }).map((c) => c.symbol),
    ["AVAX", "AERO", ...LOCAL_COINS.map((c) => c.symbol)],
    "and every local coin with a UniswapX key",
  );
  assert.deepEqual(coinsOf(["NVDAON", "AVAX"]).map((c) => c.symbol), ["AVAX", "NVDAON"], "a local coin named, with or without the key");
  assert.deepEqual(coinsOf(["OP"]).map((c) => c.symbol), ["OP"], "OP, off the list since 2026-11-21, only when named");
  assert.ok(coinsOf(null).every((c) => CHAINS[c.chain].platform === "evm"), "each with its chain's adapter built");
  assert.deepEqual(coinsOf(["XRP", "SUI"]).map((c) => c.symbol), ["XRP", "SUI"]);
  assert.throws(() => coinsOf(["XRP", "DOGE"]), /unknown restock coins: DOGE/);
});
