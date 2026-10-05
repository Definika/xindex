// ABIs from the repo's own Foundry build (`forge build` at the repo root), so the bot and the filler call exactly the
// contracts this repo compiles.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cache = new Map();

export function abi(contract) {
  if (!cache.has(contract)) {
    const file = join(root, "out", `${contract}.sol`, `${contract}.json`);
    cache.set(contract, JSON.parse(readFileSync(file, "utf8")).abi);
  }
  return cache.get(contract);
}
