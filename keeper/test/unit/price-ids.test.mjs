import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MAINNET_PRICE_IDS } from "../../bot/price-ids.mjs";

const read = (path) => readFileSync(new URL(`../../../script/${path}`, import.meta.url), "utf8");

test("the keeper's price ids are the list's coins, each at its address and PythIds.sol's id of the same name", () => {
  const listed = [...read("Listings.sol").matchAll(/tokens\[\d+\] = M\.(\w+);/g)].map((m) => m[1]);
  const addressOf = new Map([...read("MainnetAddresses.sol").matchAll(/address internal constant (\w+) = (0x[0-9a-fA-F]{40});/g)].map((m) => [m[1], m[2]]));
  const idOf = new Map([...read("PythIds.sol").matchAll(/bytes32 internal constant (\w+) = (0x[0-9a-f]{64});/g)].map((m) => [m[1], m[2]]));
  assert.equal(listed.length, 414);
  assert.equal(Object.keys(MAINNET_PRICE_IDS).length, 414);
  for (const name of listed) {
    assert.ok(addressOf.has(name) && idOf.has(name), `${name} has an address and an id`);
    assert.equal(MAINNET_PRICE_IDS[addressOf.get(name).toLowerCase()], idOf.get(name), name);
  }
  assert.equal(new Set(Object.values(MAINNET_PRICE_IDS)).size, 414, "no two coins share a feed");
});

test("the factory's Ethereum feeds are the keeper's catalogue: each listed coin at its id, as a token's price", () => {
  const source = read("PriceFeeds.sol");
  const table = source.slice(source.indexOf("function ethereum()"), source.indexOf("function bnb()"));
  const ids = [...table.matchAll(/bytes32\((0x[0-9a-f]{64})\)/g)].map((m) => m[1]);
  const kindsList = table.slice(table.indexOf("kinds = ["), table.indexOf("];", table.indexOf("kinds = [")));
  const kinds = [...kindsList.matchAll(/\b(?:uint8\()?([123])\)?(?=[,\s]|$)/g)].map((m) => Number(m[1]));
  const catalogue = Object.entries(MAINNET_PRICE_IDS);
  assert.equal(ids.length, 414);
  assert.equal(kinds.length, 414);
  for (let i = 0; i < catalogue.length; ++i) {
    const [token, id] = catalogue[i];
    assert.equal(ids[i], id, `entry ${i}, ${token}, takes the catalogue's id`);
    // every Ondo token too: at its own feed or its share's, the multiplier left out (the owner's call of 2026-11-23)
    assert.equal(kinds[i], 1, `entry ${i}, ${token}, is priced as a token`);
  }
});
