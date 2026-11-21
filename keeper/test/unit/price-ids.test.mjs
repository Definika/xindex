import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MAINNET_PRICE_IDS, MAINNET_WRAPPED } from "../../bot/price-ids.mjs";

const read = (path) => readFileSync(new URL(`../../../script/${path}`, import.meta.url), "utf8");

test("the keeper's price ids are the list's coins, each at its address and PythIds.sol's id of the same name", () => {
  const listed = [...read("Listings.sol").matchAll(/tokens\[\d+\] = M\.(\w+);/g)].map((m) => m[1]);
  const addressOf = new Map([...read("MainnetAddresses.sol").matchAll(/address internal constant (\w+) = (0x[0-9a-fA-F]{40});/g)].map((m) => [m[1], m[2]]));
  const idOf = new Map([...read("PythIds.sol").matchAll(/bytes32 internal constant (\w+) = (0x[0-9a-f]{64});/g)].map((m) => [m[1], m[2]]));
  assert.equal(listed.length, 171);
  assert.equal(Object.keys(MAINNET_PRICE_IDS).length, 171);
  for (const name of listed) {
    assert.ok(addressOf.has(name) && idOf.has(name), `${name} has an address and an id`);
    assert.equal(MAINNET_PRICE_IDS[addressOf.get(name).toLowerCase()], idOf.get(name), name);
  }
  assert.equal(new Set(Object.values(MAINNET_PRICE_IDS)).size, 171, "no two coins share a feed");
});

test("the wrapped coins are the list's wrapped xStocks: the coins PythIds.sol prices at a feed for what they wrap", () => {
  const listed = [...read("Listings.sol").matchAll(/tokens\[\d+\] = M\.(\w+);/g)].map((m) => m[1]);
  const addressOf = new Map([...read("MainnetAddresses.sol").matchAll(/address internal constant (\w+) = (0x[0-9a-fA-F]{40});/g)].map((m) => [m[1], m[2]]));
  // A wrapper's id is recorded under `/// @dev w<ticker>x: <feed>`, the xStock's own feed or the share's.
  const wrappers = new Set([...read("PythIds.sol").matchAll(/\/\/\/ @dev w[\w.]+x: [^\n]*\n(?:\s*\/\/\/[^\n]*\n)?\s*bytes32 internal constant (W\w+X) = 0x[0-9a-f]{64}/g)].map((m) => m[1]));
  assert.equal(wrappers.size, 109);
  const expected = listed.filter((name) => wrappers.has(name)).map((name) => addressOf.get(name).toLowerCase());
  assert.equal(expected.length, 109, "every wrapper PythIds.sol records is listed");
  assert.deepEqual([...MAINNET_WRAPPED], expected, "in the list's order, lowercased");
  for (const token of MAINNET_WRAPPED) assert.ok(MAINNET_PRICE_IDS[token], `${token} has a feed`);
  // No plain coin is taken for a wrapper: the catalogue's other 62 are priced at their feed alone.
  assert.equal(Object.keys(MAINNET_PRICE_IDS).filter((t) => !MAINNET_WRAPPED.includes(t)).length, 62);
});
