import { test } from "node:test";
import assert from "node:assert/strict";
import { createJournal } from "../../restock/journal.mjs";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSignerHome, evmWord, startSigner } from "../../restock/signer-home.mjs";

const SUI_COIN = { symbol: "SUI", home: "0x2::sui::SUI", decimals: 9 };

/// A journal in memory, and a signer that answers from `script` (op -> function of args), recording every request;
/// the home serves `coins` with the plan's `cfg`.
function rig(script, { coins = [SUI_COIN], cfg = { minUsd: 100 } } = {}) {
  let text = null;
  const journal = createJournal({ load: () => text, save: (t) => (text = t) });
  const asked = [];
  const ask = async (op, args = {}) => {
    asked.push({ op, args, journalled: Object.keys(JSON.parse(text ?? '{"moves":{}}').moves).length });
    if (!script[op]) throw new Error(`unexpected request ${op}`);
    return script[op](args);
  };
  const home = createSignerHome({
    name: "sui",
    def: { wormhole: 21, cctpDomain: 8 },
    coins,
    floatId: "USDC",
    journal,
    cfg,
    verifyVaa: async () => ({ valid: true }),
    ask,
  });
  return { home, journal, asked };
}

const SIGNED = { raw: "raw-bytes", signature: "digest-1", expiry: '{"epoch":"9"}' };
const INFO = { wallet: "0xab", walletWord: `0x${"ab".repeat(32)}`, emitter: `0x${"cc".repeat(32)}`, accounts: { "0x2::sui::SUI": { address: "0xab", word: `0x${"ab".repeat(32)}` } } };

test("a signer home reads the signer's addresses; without a token account the wallet is the CCTP recipient", async () => {
  const { home } = rig({ info: () => INFO });
  await home.check();
  assert.equal(home.address, "0xab");
  assert.equal(home.emitter, INFO.emitter);
  assert.equal(home.cctpSender, INFO.walletWord);
  assert.equal(home.cctpRecipient, INFO.walletWord, "Sui and Aptos mint to the wallet itself");
  assert.equal(home.recipientFor({ home: "0x2::sui::SUI" }), INFO.walletWord);
});

test("a move is journalled before the signer is asked to send it, and lands as sent", async () => {
  const { home, journal, asked } = rig({
    buildBridgeIn: () => SIGNED,
    send: () => "digest-1",
    status: () => ({ state: "landed", at: "77" }),
    sequenceOf: () => "42",
  });
  await home.bridgeIn({ kind: "bridgeIn", coin: "SUI", copy: "0xcopy", chain: "sui", amount: 1_000n, usd: 5 }, { home: "0x2::sui::SUI" }, `0x${"ee".repeat(32)}`);
  const send = asked.find((a) => a.op === "send");
  assert.equal(send.journalled, 1, "the journal held the move when it was sent");
  assert.equal(send.args.raw, "raw-bytes");
  const [move] = journal.find(() => true);
  assert.equal(move.stage, "sent");
  assert.equal(move.data.status, "success");
  assert.equal(move.data.expiry, SIGNED.expiry, "the signer's expiry is kept for its next look");
  assert.equal(move.data.sequence, "42");
});

test("resume: an expired move is dropped, a pending one sent again, a reverted one marked so", async () => {
  for (const [state, expect] of [
    ["expired", (m) => assert.equal(m.stage, "dropped")],
    ["pending", (m) => assert.equal(m.stage, "signed")],
    ["reverted", (m) => assert.equal(m.data.status, "reverted")],
  ]) {
    const { home, journal, asked } = rig({ send: () => null, status: () => ({ state, reason: "why" }) });
    const id = journal.open({ kind: "sweep", chain: "sui", amount: 5n }, { chain: "sui", raw: "r", hash: "d", expiry: "e" });
    await home.resume(journal.get(id));
    expect(journal.get(id));
    const resent = asked.filter((a) => a.op === "send").length;
    assert.equal(resent, state === "pending" ? 1 : 0, `${state}: sent again only while it may still land`);
  }
});

test("a swap halves while no route pays its share of the floor, down to the minimum trade, and journals what was spent", async () => {
  const tried = [];
  const { home, journal } = rig({
    buildSwap: ({ amount, minOut }) => {
      tried.push([amount, minOut]);
      return BigInt(amount) > 300n ? { refused: "loss", outAmount: "0" } : { ...SIGNED, spent: String(BigInt(amount) - 1n) };
    },
    send: () => null,
    status: () => ({ state: "landed" }),
  });
  // 400 SUI at $1.
  const a = { kind: "buy", coin: "SUI", copy: "0xcopy", chain: "sui", usd: 400, amountIn: 1_200n, maxIn: 1_212n, amountOut: 400n * 10n ** 9n, minOut: 800n };
  const done = await home.buy(a, SUI_COIN, 1);
  assert.deepEqual(tried, [["1200", "800"], ["600", "400"], ["300", "200"]]);
  const [move] = journal.find(() => true);
  assert.equal(move.amount, "299", "the amount the route spent");
  assert.ok(Math.abs(done.usd - (100 * 299) / 300) < 1e-9, "and its value");
  const { home: thin } = rig({ buildSwap: () => ({ refused: "loss", outAmount: "0" }) });
  assert.equal(await thin.buy(a, SUI_COIN, 1), null, "none pays above the minimum trade: no buy");
});

test("a sweep names the treasury as a word, and keeps the burn's event account for the rent's reclaim", async () => {
  let treasury = null;
  const { home, journal } = rig({
    buildSweep: (args) => ((treasury = args.treasury), { ...SIGNED, eventAccount: "Ev3nt" }),
    send: () => null,
    status: () => ({ state: "landed" }),
  });
  await home.sweep({ kind: "sweep", chain: "sui", amount: 7n }, "0x88A5b9350c722D25579a5EF1C5C613f923460c04");
  assert.equal(treasury, evmWord("0x88A5b9350c722D25579a5EF1C5C613f923460c04"));
  assert.equal(journal.find(() => true)[0].data.eventAccount, "Ev3nt");
});

test("PD-6: a move goes to the signer with its digest and expiry, so the signer holds it in flight from the moment it is sent", async () => {
  const { home, asked } = rig({
    buildSweep: () => SIGNED,
    send: () => null,
    status: () => ({ state: "landed" }),
  });
  await home.sweep({ kind: "sweep", chain: "sui", amount: 7n }, "0x88A5b9350c722D25579a5EF1C5C613f923460c04", 3n);
  const send = asked.find((a) => a.op === "send");
  assert.deepEqual(send.args, { raw: SIGNED.raw, signature: SIGNED.signature, expiry: SIGNED.expiry });
  assert.equal(asked.find((a) => a.op === "buildSweep").args.maxFee, "3", "the route's fee bound goes with the sweep (PD-12)");
});

test("PD-8: a move whose fate the node cannot show stays signed, is not sent again, and the reason is reported", async () => {
  const { home, journal, asked } = rig({ send: () => null, status: () => ({ state: "unknown", reason: "the node keeps slots from 401 only" }) });
  const id = journal.open({ kind: "sweep", chain: "sui", amount: 5n }, { chain: "sui", raw: "r", hash: "d", expiry: "e" });
  await assert.rejects(home.resume(journal.get(id)), /whether it landed is unknown: the node keeps slots from 401 only/);
  assert.equal(journal.get(id).stage, "signed");
  assert.equal(asked.filter((a) => a.op === "send").length, 0);
});

test("PD-11: a signer whose input closed under a write fails what is waiting, and the service goes on", async () => {
  const dir = mkdtempSync(join(tmpdir(), "signer-"));
  const path = join(dir, "closes-input.mjs");
  writeFileSync(path, 'import { closeSync } from "node:fs";\ncloseSync(0);\nsetTimeout(() => {}, 3000);\n');
  const ask = startSigner({ env: { PATH: process.env.PATH ?? "" }, path, label: "test", timeoutMs: 10_000 });
  const first = ask("info");
  await new Promise((r) => setTimeout(r, 500)); // the signer has closed its input by now
  const second = ask("info");
  // Unheard, the EPIPE of the second write would end this process here.
  await assert.rejects(second, /the test signer failed: .*EPIPE|the test signer (failed|exited)/);
  await assert.rejects(first, /the test signer/);
});

test("CA-L8: a signer is launched by its file's path, which a URL's pathname is not", async () => {
  const { readFileSync } = await import("node:fs");
  const { fileURLToPath, pathToFileURL } = await import("node:url");
  // A checkout under a folder with a space or an accent: the pathname keeps both percent-encoded and names no file.
  const path = "/srv/Xindex audit/é/signer.mjs";
  assert.equal(pathToFileURL(path).pathname, "/srv/Xindex%20audit/%C3%A9/signer.mjs");
  assert.equal(fileURLToPath(pathToFileURL(path)), path);
  for (const chain of ["solana", "sui", "aptos", "algorand"]) {
    const source = readFileSync(new URL(`../../restock/${chain}.mjs`, import.meta.url), "utf8");
    assert.ok(source.includes(`fileURLToPath(new URL("./${chain}/signer.mjs", import.meta.url))`), `${chain}'s launcher`);
    assert.ok(!source.includes(".pathname;"), `${chain}'s launcher still takes a pathname`);
  }
});

test("CA-M14: a chain's own gas coin is sold or bridged only while the wallet keeps the chain's gas minimum", async () => {
  const MIST = 10n ** 9n;
  const GAS_SUI = { symbol: "SUI", chain: "sui", home: "0x2::sui::SUI", decimals: 9, isGas: true };
  const withGasMin = { minUsd: 100, gasMin: new Map([["sui", MIST]]) };
  // A build that is asked for stands for the move going ahead: what follows it is the other tests'.
  const at = (gas, cfg = withGasMin) =>
    rig(
      {
        balances: ({ mints }) => (assert.deepEqual(mints, [], "the gas coin's balance"), { gas: String(gas), tokens: {} }),
        buildBridgeIn: () => {
          throw new Error("built");
        },
        buildSwap: () => {
          throw new Error("built");
        },
      },
      { coins: [GAS_SUI], cfg },
    );
  const bridge = { kind: "bridgeIn", coin: "SUI", copy: "0xcopy", chain: "sui", amount: 5n * MIST, usd: 15 };
  const sale = { kind: "sell", coin: "SUI", copy: "0xcopy", chain: "sui", amount: 50n * MIST, minOut: 1n };
  const word = `0x${"ee".repeat(32)}`;
  const ops = (asked) => asked.map((a) => a.op);

  const dry = at(6n * MIST - 1n);
  await assert.rejects(dry.home.bridgeIn(bridge, GAS_SUI, word), /5000000000 would leave the wallet 999999999 of its gas coin, under its minimum 1000000000/);
  await assert.rejects(dry.home.sell(sale, GAS_SUI, 3), /under its minimum/);
  assert.deepEqual(ops(dry.asked), ["balances", "balances"], "refused before anything is built or signed");
  assert.equal(dry.journal.find(() => true).length, 0);

  const wet = at(51n * MIST);
  await assert.rejects(wet.home.bridgeIn(bridge, GAS_SUI, word), /built/, "5 SUI out of 51: the minimum stays");
  await assert.rejects(wet.home.sell(sale, GAS_SUI, 3), /built/, "50 SUI out of 51: the minimum stays");
  assert.deepEqual(ops(wet.asked), ["balances", "buildBridgeIn", "balances", "buildSwap"]);

  const unset = at(1_000n * MIST, { minUsd: 100 });
  await assert.rejects(unset.home.bridgeIn(bridge, GAS_SUI, word), /under its minimum \(none set\)/, "no minimum known for the chain: none of its gas coin leaves");

  // A coin that is not its chain's gas coin is not held to it, and its sale reads no gas balance.
  const other = at(0n);
  await assert.rejects(other.home.sell(sale, SUI_COIN, 3), /built/);
  assert.deepEqual(ops(other.asked), ["buildSwap"]);
});

test("CA-R2-12: a buy the plan sized at RESTOCK_MIN_USD is tried, though its worth in floats is a millionth under it; one below it is not", async () => {
  const { plan } = await import("../../restock/plan.mjs");
  const { COINS } = await import("../../restock/coins.mjs");
  const SUI = COINS.find((c) => c.symbol === "SUI");
  const price = 3.07;
  const cfg = { bufferBps: 1000, minUsd: 100, dailyUsd: 50_000, keepUsd: 500, maxTransferUsd: 20_000, floatTargetUsd: 5_000, treasuryTargetUsd: 10_000, maxLossBps: 100, gasMin: new Map([["sui", 10n ** 9n]]) };
  // A need of one MIST, nothing anywhere: the plan buys the smallest trade it makes.
  const { actions } = plan({
    coins: [SUI],
    needs: new Map([[SUI.copy, 1n]]),
    stock: new Map(),
    inflight: new Map(),
    home: { coins: new Map(), floats: new Map([["sui", 1_000n * 10n ** 6n]]), gas: new Map([["sui", 10n * 10n ** 9n]]), funding: new Map() },
    treasury: { usdc: 0n, allowance: 0n },
    prices: new Map([["SUI", price]]),
    spentUsd: 0,
    restockAllowance: new Map([[SUI.copy, 10n ** 30n]]),
    cfg,
  });
  const [buy] = actions;
  assert.equal(buy.kind, "buy");
  assert.ok(buy.usd < cfg.minUsd, `the plan's minimum buy is worth ${buy.usd} in floats: the case`);
  assert.equal(buy.amountIn, 99_999_999n, "and spends 99.999999 USDC");

  // The route refuses: what is asked for is what the signer home tried.
  const tried = [];
  const { home } = rig({ buildSwap: ({ amount }) => (tried.push(amount), { refused: "loss", outAmount: "0" }) }, { coins: [SUI], cfg });
  assert.equal(await home.buy(buy, SUI, price), null);
  assert.deepEqual(tried, [String(buy.amountIn)], "the whole buy is tried, and no half of it, which is under the minimum");

  // One unit of SUI under the plan's minimum is a buy under RESTOCK_MIN_USD, and so is a buy with no price.
  const { home: strict, asked } = rig({ buildSwap: () => ({ refused: "loss", outAmount: "0" }) }, { coins: [SUI], cfg });
  assert.equal(await strict.buy({ ...buy, amountOut: buy.amountOut - 1n }, SUI, price), null);
  assert.equal(await strict.buy(buy, SUI, undefined), null);
  assert.deepEqual(asked, [], "neither is asked for");
});

test("CA-L7: the signer ends when the run does, so a one-shot run exits once its round is over", async () => {
  const { spawnSync } = await import("node:child_process");
  const { readFileSync } = await import("node:fs");
  const dir = mkdtempSync(join(tmpdir(), "signer-"));
  const protocol = new URL("../../restock/signer-protocol.mjs", import.meta.url).href;
  const signerHome = new URL("../../restock/signer-home.mjs", import.meta.url).href;
  // A signer as the real ones are: it answers through the protocol, and holds a handle open as a chain library does.
  const signer = join(dir, "signer.mjs");
  writeFileSync(
    signer,
    `import { serve } from ${JSON.stringify(protocol)};\nsetInterval(() => {}, 1000);\nserve({ info: () => ({ wallet: "w", walletWord: "0x01", emitter: "0x02", accounts: {} }) }, {});\n`,
  );
  // A run as restock.mjs makes one: a home whose signer it starts, a request, its homes closed, and nothing more.
  const run = join(dir, "run.mjs");
  writeFileSync(
    run,
    [
      `import { createSignerHome } from ${JSON.stringify(signerHome)};`,
      `const home = createSignerHome({ name: "sui", def: { wormhole: 21, cctpDomain: 8 }, signerPath: ${JSON.stringify(signer)}, env: { PATH: process.env.PATH ?? "" }, coins: [], floatId: "USDC", journal: null, cfg: { minUsd: 1 } });`,
      "await home.check();",
      "console.log(JSON.stringify(await home.close(60_000)));",
      "",
    ].join("\n"),
  );
  const done = spawnSync(process.execPath, [run], { encoding: "utf8", timeout: 20_000 });
  assert.equal(done.signal, null, `the run ended by itself, not by the test's timeout: ${done.stderr}`);
  assert.equal(done.status, 0, done.stderr);
  assert.deepEqual(JSON.parse(done.stdout.trim()), { code: 0, signal: null }, "the signer exited on its own once its input closed, not killed");

  // A signer that does not end with its input is killed once the grace is over.
  const deaf = join(dir, "deaf.mjs");
  writeFileSync(deaf, "process.stdin.resume();\nsetInterval(() => {}, 1000);\n");
  const ask = startSigner({ env: { PATH: process.env.PATH ?? "" }, path: deaf, label: "deaf", timeoutMs: 500 });
  await assert.rejects(ask("info"), /did not answer info/);
  assert.deepEqual(await ask.close(300), { code: null, signal: "SIGKILL" });
  assert.equal(await ask.close(300), null, "nothing left to end");

  // restock.mjs ends every home's signer after its loop, a `--once` run's single round and a stopped service's last.
  const source = readFileSync(new URL("../../restock.mjs", import.meta.url), "utf8");
  const loop = source.indexOf("while (!stopping) {");
  const close = source.indexOf("await Promise.all(Object.values(homes).map((h) => h.close?.()));");
  assert.ok(loop > 0 && close > loop, "the homes are closed after the loop");
});
