import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseRestockConfig } from "../../restock/config.mjs";
import { evmWord, resumeDecision } from "../../restock/solana-sending.mjs";
import { signerEnv, startSigner } from "../../restock/solana.mjs";
import { foreignControl, slippageFor, tokenAmount, unitLimit, unitPriceOf, MAX_COMPUTE_UNITS } from "../../restock/solana/checks.mjs";

const VALID = {
  RPC_URL: "https://eth.example",
  EXECUTOR: `0x${"11".repeat(20)}`,
  TREASURY_KEY: `0x${"22".repeat(32)}`,
  PYTH_API_KEY: "key",
  NEEDS_FILE: "/var/keeper/needs.json",
  JOURNAL_FILE: "/var/keeper/restock.json",
  RESTOCK_COINS: "JUP,PYTH",
  SOLANA_RPC_URL: "https://solana.example",
  SOLANA_KEY: "3".repeat(88),
  JUPITER_API_KEY: "jup-key",
};

test("a journalled Solana transaction lands, is sent again, or is dropped once it can never land", () => {
  const at = (status, finalizedHeight, lastValidBlockHeight = "1000") => resumeDecision({ status, finalizedHeight, lastValidBlockHeight });
  assert.deepEqual(at({ confirmationStatus: "confirmed", err: null, slot: 5 }, 900), { sent: "success" });
  assert.deepEqual(at({ confirmationStatus: "finalized", err: null }, 2000), { sent: "success" }, "landed, however late we look");
  assert.deepEqual(at({ confirmationStatus: "confirmed", err: { InstructionError: [0, "Custom"] } }, 900), { sent: "reverted" });
  assert.deepEqual(at(null, 1000), { resend: true }, "at its last valid height it may still land");
  assert.deepEqual(at({ confirmationStatus: "processed", err: null }, 999), { resend: true });
  assert.match(at(null, 1001).drop, /expired at block height 1000/, "past it, never");
  assert.ok(at({ confirmationStatus: "processed", err: null }, 1001).drop, "processed on a fork that was not finalized");
  assert.deepEqual(at(null, "5000000000000", "4999999999999").drop !== undefined, true, "heights as strings, compared as integers");
});

test("an EVM address as a recipient word", () => {
  assert.equal(evmWord("0x88A5b9350c722D25579a5EF1C5C613f923460c04"), `0x${"0".repeat(24)}88a5b9350c722d25579a5ef1c5c613f923460c04`);
});

test("the slippage leaves Jupiter's on-chain minimum at the plan's floor or above", () => {
  assert.equal(slippageFor(1_000_000n, 990_000n), 100);
  assert.equal(slippageFor(1_000_000n, 1_000_000n), 0, "a quote exactly at the floor allows no slippage");
  assert.equal(slippageFor(999_999n, 1_000_000n), null, "a quote below the floor is refused");
  assert.equal(slippageFor(0n, 0n), null);
  for (const [out, min] of [[987_654_321n, 912_345_678n], [3n, 2n], [10n ** 18n, 10n ** 18n - 1n]]) {
    const bps = BigInt(slippageFor(out, min));
    assert.ok(out - (out * bps) / 10_000n >= min, `out ${out} at ${bps} bps keeps ${min}`);
  }
});

test("a compute unit price instruction is read, and nothing else is taken for one", () => {
  const price = Buffer.alloc(9);
  price[0] = 3;
  price.writeBigUInt64LE(123_456n, 1);
  assert.equal(unitPriceOf(price), 123_456n);
  const limit = Buffer.alloc(5);
  limit[0] = 2;
  assert.equal(unitPriceOf(limit), null, "SetComputeUnitLimit");
  assert.equal(unitPriceOf(Buffer.concat([price, Buffer.from([0])])), null, "a longer instruction");
  assert.equal(unitLimit(100_000), 120_000);
  assert.equal(unitLimit(100_001), 120_002, "rounded up");
  assert.equal(unitLimit(1_300_000), MAX_COMPUTE_UNITS, "within the cap");
});

test("a token account's balance, and any control of it but the wallet's", () => {
  const wallet = Buffer.alloc(32, 7);
  const account = Buffer.alloc(165);
  wallet.copy(account, 32);
  account.writeBigUInt64LE(5_000_000n, 64);
  assert.equal(tokenAmount(account), 5_000_000n);
  assert.equal(tokenAmount(null), 0n, "no account, no coins");
  assert.equal(foreignControl(account, wallet), null);
  assert.equal(foreignControl(null, wallet), null, "no account to control");
  const other = Buffer.from(account);
  Buffer.alloc(32, 9).copy(other, 32);
  assert.match(foreignControl(other, wallet), /owner/);
  const delegated = Buffer.from(account);
  delegated.writeUInt32LE(1, 72);
  assert.match(foreignControl(delegated, wallet), /delegate/, "an approval moves no balance, but is refused");
  const closable = Buffer.from(account);
  closable.writeUInt32LE(1, 129);
  assert.match(foreignControl(closable, wallet), /close authority/);
});

test("Solana's settings: its RPC, its key, and Jupiter's key; the signer's options checked", () => {
  const cfg = parseRestockConfig(VALID);
  assert.deepEqual(cfg.coins.map((c) => c.symbol), ["JUP", "PYTH"]);
  assert.equal(cfg.chains.solana.jupiterApiKey, "jup-key");
  assert.equal(cfg.chains.solana.jupiterUrl, null);
  assert.equal(cfg.chains.solana.maxUnitPrice, null);
  const { JUPITER_API_KEY, ...noJupiter } = VALID;
  assert.throws(() => parseRestockConfig(noJupiter), /JUPITER_API_KEY is required/);
  assert.throws(() => parseRestockConfig({ ...VALID, JUPITER_PROGRAMS: "JUP6,0xabc" }), /JUPITER_PROGRAMS must be base58 program ids/);
  const opts = parseRestockConfig({ ...VALID, JUPITER_PROGRAMS: `${"J".repeat(43)},${"K".repeat(43)}`, SOLANA_MAX_UNIT_PRICE: "50000", JUPITER_URL: "https://jup.example" });
  assert.equal(opts.chains.solana.maxUnitPrice, "50000");
  assert.equal(opts.chains.solana.jupiterUrl, "https://jup.example");
});

test("the signer's environment names only what it needs: never the treasury's key", () => {
  const cfg = parseRestockConfig({ ...VALID, SOLANA_MAX_UNIT_PRICE: "7" });
  const env = signerEnv(cfg.chains.solana);
  assert.deepEqual(Object.keys(env).sort(), ["JUPITER_API_KEY", "PATH", "SOLANA_KEY", "SOLANA_MAX_UNIT_PRICE", "SOLANA_RPC_URL"]);
  assert.ok(!Object.values(env).includes(VALID.TREASURY_KEY));
});

test("the signer channel: answers matched by id, stray lines skipped, an error carried, a restart after an exit", async () => {
  const dir = mkdtempSync(join(tmpdir(), "signer-"));
  const fake = join(dir, "fake-signer.mjs");
  writeFileSync(
    fake,
    `process.stdout.write("bigint: Failed to load bindings, pure JS will be used\\n");
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf("\\n")) >= 0) {
    const req = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
    if (req.op === "env") process.stdout.write(JSON.stringify({ id: req.id, ok: true, result: Object.keys(process.env).sort() }) + "\\n");
    else if (req.op === "boom") process.stdout.write(JSON.stringify({ id: req.id, ok: false, error: "no route" }) + "\\n");
    else if (req.op === "exit") process.exit(3);
    else if (req.op === "echo") setTimeout(() => process.stdout.write(JSON.stringify({ id: req.id, ok: true, result: req.args }) + "\\n"), req.args.wait);
  }
});
`,
  );
  const ask = startSigner({ env: { PATH: process.env.PATH, ONLY: "this" }, path: fake, timeoutMs: 5_000 });
  const [slow, fast] = await Promise.all([ask("echo", { wait: 50, n: 1 }), ask("echo", { wait: 0, n: 2 })]);
  assert.equal(slow.n, 1, "each answer reaches its own request");
  assert.equal(fast.n, 2);
  const keys = await ask("env");
  assert.ok(keys.includes("ONLY") && !keys.includes("TREASURY_KEY"), "the child sees only the environment it was given");
  await assert.rejects(ask("boom"), /solana: no route/);
  await assert.rejects(ask("exit"), /the Solana signer exited \(3\)/);
  assert.equal((await ask("echo", { wait: 0, n: 3 })).n, 3, "started again on the next request");
  await assert.rejects(ask("echo", { wait: 60_000 }, 100), /did not answer echo/);
  await ask("exit").catch(() => {});
});
