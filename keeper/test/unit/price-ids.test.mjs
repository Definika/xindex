import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MAINNET_PRICE_IDS } from "../../bot/price-ids.mjs";
import { SHARE_PRICED_IDS } from "../../bot/config.mjs";

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

/// A feed table of PriceFeeds.sol: its ids and its kinds, in order.
function tableOf(source, from, to) {
  const table = source.slice(source.indexOf(`function ${from}()`), to ? source.indexOf(`function ${to}()`) : undefined);
  const ids = [...table.matchAll(/bytes32\((0x[0-9a-f]{64})\)/g)].map((m) => m[1]);
  const kindsList = table.slice(table.indexOf("kinds = ["), table.indexOf("];", table.indexOf("kinds = [")));
  const kinds = [...kindsList.matchAll(/\b(?:uint8\()?([1-4])\)?(?=[,\s]|$)/g)].map((m) => Number(m[1]));
  return { ids, kinds };
}

// `IPythPrices.FeedKind`: a token's own price, and a share's times the sValue Ondo's oracle holds for the token.
const [TOKEN, SHARES_ORACLE] = [1, 4];

test("the factory's Ethereum feeds are the keeper's catalogue: each listed coin at its id, a share's at its sValue", () => {
  const { ids, kinds } = tableOf(read("PriceFeeds.sol"), "ethereum", "bnb");
  const catalogue = Object.entries(MAINNET_PRICE_IDS);
  assert.equal(ids.length, 414);
  assert.equal(kinds.length, 414);
  for (let i = 0; i < catalogue.length; ++i) {
    const [token, id] = catalogue[i];
    assert.equal(ids[i], id, `entry ${i}, ${token}, takes the catalogue's id`);
    // an Ondo token at its share's feed is worth sValue shares; every other at its own
    const kind = SHARE_PRICED_IDS.includes(id) ? SHARES_ORACLE : TOKEN;
    assert.equal(kinds[i], kind, `entry ${i}, ${token}, is priced at its kind`);
  }
  assert.equal(kinds.filter((k) => k === SHARES_ORACLE).length, SHARE_PRICED_IDS.length);
});

test("BNB Chain's feeds price a share at its sValue exactly where the id is a share's, as Ethereum's do", () => {
  const { ids, kinds } = tableOf(read("PriceFeeds.sol"), "bnb", "base");
  assert.equal(ids.length, 366);
  assert.equal(kinds.length, 366);
  ids.forEach((id, i) => assert.equal(kinds[i], SHARE_PRICED_IDS.includes(id) ? SHARES_ORACLE : TOKEN, `entry ${i}`));
  assert.equal(kinds.filter((k) => k === SHARES_ORACLE).length, SHARE_PRICED_IDS.length);
});
