import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CHAINS, COINS, PRICE_IDS, coinsOf } from "../../restock/coins.mjs";

const read = (path) => readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8");
const addresses = read("script/MainnetAddresses.sol");
const pythIds = read("script/PythIds.sol");

test("every coin is the copy MainnetAddresses lists, from the home token, chain and decimals its comment names", () => {
  assert.equal(COINS.length, 13);
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

test("every coin is priced at the feed PythIds lists its copy with", () => {
  for (const c of COINS) {
    const pair = new RegExp(`\\(M\\.${c.name}, (\\w+)\\)`).exec(pythIds);
    assert.ok(pair, `${c.symbol}: PythIds does not list ${c.name}`);
    const id = new RegExp(`bytes32 internal constant ${pair[1]} = (0x[0-9a-f]{64});`).exec(pythIds);
    assert.equal(PRICE_IDS[c.symbol], id[1], `${c.symbol}'s feed`);
  }
  assert.deepEqual(Object.keys(PRICE_IDS).sort(), COINS.map((c) => c.symbol).sort());
});

test("only BNB Chain and Algorand go without CCTP, and the gas coins are the three chains' own", () => {
  const manual = Object.entries(CHAINS).filter(([, ch]) => ch.cctpDomain === null).map(([name]) => name);
  assert.deepEqual(manual.sort(), ["algorand", "bsc"]);
  for (const c of COINS) assert.ok(CHAINS[c.chain], `${c.symbol}'s chain is known`);
  assert.deepEqual(COINS.filter((c) => c.isGas).map((c) => `${c.symbol}:${CHAINS[c.chain].gas.symbol}`), ["SUI:SUI", "APT:APT", "ALGO:ALGO"]);
});

test("a subset of the coins is chosen by symbol, and an unknown symbol is refused", () => {
  assert.deepEqual(coinsOf(null).map((c) => c.symbol), ["XRP", "ADA", "LTC", "DOT", "AVAX", "OP", "AERO"], "the served coins by default");
  assert.ok(coinsOf(null).every((c) => CHAINS[c.chain].platform === "evm"), "each with its chain's adapter built");
  assert.deepEqual(coinsOf(["XRP", "SUI"]).map((c) => c.symbol), ["XRP", "SUI"]);
  assert.throws(() => coinsOf(["XRP", "DOGE"]), /unknown restock coins: DOGE/);
});
