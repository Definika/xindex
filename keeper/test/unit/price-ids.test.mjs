import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MAINNET_PRICE_IDS } from "../../bot/price-ids.mjs";

const read = (path) => readFileSync(new URL(`../../../script/${path}`, import.meta.url), "utf8");

test("the keeper's price ids are the list's coins, each at its address and PythIds.sol's id of the same name", () => {
  const listed = [...read("Listings.sol").matchAll(/tokens\[\d+\] = M\.(\w+);/g)].map((m) => m[1]);
  const addressOf = new Map([...read("MainnetAddresses.sol").matchAll(/address internal constant (\w+) = (0x[0-9a-fA-F]{40});/g)].map((m) => [m[1], m[2]]));
  const idOf = new Map([...read("PythIds.sol").matchAll(/bytes32 internal constant (\w+) = (0x[0-9a-f]{64});/g)].map((m) => [m[1], m[2]]));
  assert.equal(listed.length, 91);
  assert.equal(Object.keys(MAINNET_PRICE_IDS).length, 91);
  for (const name of listed) {
    assert.ok(addressOf.has(name) && idOf.has(name), `${name} has an address and an id`);
    assert.equal(MAINNET_PRICE_IDS[addressOf.get(name).toLowerCase()], idOf.get(name), name);
  }
  assert.equal(new Set(Object.values(MAINNET_PRICE_IDS)).size, 91, "no two coins share a feed");
});
