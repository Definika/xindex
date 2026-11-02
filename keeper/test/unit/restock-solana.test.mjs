import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseRestockConfig } from "../../restock/config.mjs";
import { resumeDecision, solanaExpiry } from "../../restock/solana-sending.mjs";
import { evmWord, startSigner } from "../../restock/signer-home.mjs";
import { signerEnv } from "../../restock/solana.mjs";
import {
  checkChanges,
  checkJupiterSwap,
  foreignControl,
  JUPITER_ROUTES,
  MAX_WALLET_ACCOUNTS,
  simulateInChunks,
  slippageFor,
  tokenAmount,
  unitLimit,
  unitPriceOf,
  withEveryAccount,
  MAX_COMPUTE_UNITS,
} from "../../restock/solana/checks.mjs";
import { decodeInstruction } from "../../restock/solana/idl-decode.mjs";

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

/// A node that has seen the finalized slot and keeps the ledger back to the send, which answered no transaction.
const CAUGHT_UP = { finalizedSlot: 500, statusSlot: 510, firstAvailableSlot: 100, sentSlot: 400, transaction: null };

test("a journalled Solana transaction lands, is sent again, or is dropped once it can never land", () => {
  const at = (status, finalizedHeight, lastValidBlockHeight = "1000") => resumeDecision({ ...CAUGHT_UP, status, finalizedHeight, lastValidBlockHeight });
  assert.deepEqual(at({ confirmationStatus: "confirmed", err: null, slot: 5 }, 900), { sent: "success" });
  assert.deepEqual(at({ confirmationStatus: "finalized", err: null }, 2000), { sent: "success" }, "landed, however late we look");
  assert.deepEqual(at({ confirmationStatus: "confirmed", err: { InstructionError: [0, "Custom"] } }, 900), { sent: "reverted" });
  assert.deepEqual(at(null, 1000), { resend: true }, "at its last valid height it may still land");
  assert.deepEqual(at({ confirmationStatus: "processed", err: null }, 999), { resend: true });
  assert.match(at(null, 1001).drop, /expired at block height 1000/, "past it, never");
  assert.ok(at({ confirmationStatus: "processed", err: null }, 1001).drop, "processed on a fork that was not finalized");
  assert.deepEqual(at(null, "5000000000000", "4999999999999").drop !== undefined, true, "heights as strings, compared as integers");
});

test("PD-8: a null status drops a move only from a node caught up to the finalized slot that keeps the slots since the send", () => {
  const expired = { status: null, finalizedHeight: 1001, lastValidBlockHeight: "1000" };
  assert.ok(resumeDecision({ ...expired, ...CAUGHT_UP }).drop, "a caught-up node with the history, and no transaction: dropped");
  assert.match(resumeDecision({ ...expired, ...CAUGHT_UP, statusSlot: 499 }).unknown, /behind the finalized slot/, "a node behind says nothing");
  assert.match(resumeDecision({ ...expired, ...CAUGHT_UP, firstAvailableSlot: 401 }).unknown, /keeps slots from 401/, "a node without the history says nothing");
  assert.match(resumeDecision({ ...expired, ...CAUGHT_UP, sentSlot: null }).unknown, /keeps slots/, "an expiry naming no slot proves nothing");
  assert.match(resumeDecision({ ...expired, ...CAUGHT_UP, transaction: "unavailable" }).unknown, /no transaction history/);
  assert.deepEqual(resumeDecision({ ...expired, ...CAUGHT_UP, transaction: { err: null } }), { sent: "success" }, "the transaction found: it landed");
  assert.deepEqual(resumeDecision({ ...expired, ...CAUGHT_UP, transaction: { err: { Custom: 1 } } }), { sent: "reverted" });
  assert.deepEqual(resumeDecision({ ...expired, finalizedHeight: 1000, statusSlot: 1 }), { resend: true }, "before the blockhash expires, sent again whatever the node");
  assert.deepEqual(solanaExpiry('{"lastValidBlockHeight":"1000","sentSlot":"400"}'), { lastValidBlockHeight: "1000", sentSlot: "400" });
  assert.deepEqual(solanaExpiry("1000"), { lastValidBlockHeight: "1000", sentSlot: null }, "a bare height names no slot");
});

// ---------------------------------------------------------------------
// Jupiter's swap read by its IDL (PD-1, PD-2)
// ---------------------------------------------------------------------

/// Anchor's discriminator of instruction `name`: the first 8 bytes of sha256("global:<name>").
const discriminator = async (name) => Array.from((await import("node:crypto")).createHash("sha256").update(`global:${name}`).digest().subarray(0, 8));

/// An IDL of our own in Jupiter's shape (Anchor 0.30), for the four routes the signer checks: a route plan of steps,
/// each a venue (an enum whose variants carry fields of their own) and three bytes, then the amounts (v1) or the
/// amounts first (v2).
async function routeIdl() {
  const plan = { name: "route_plan", type: { vec: { defined: { name: "Step" } } } };
  const v1Tail = [
    { name: "in_amount", type: "u64" },
    { name: "quoted_out_amount", type: "u64" },
    { name: "slippage_bps", type: "u16" },
    { name: "platform_fee_bps", type: "u8" },
  ];
  const v2Head = [
    { name: "in_amount", type: "u64" },
    { name: "quoted_out_amount", type: "u64" },
    { name: "slippage_bps", type: "u16" },
    { name: "platform_fee_bps", type: "u16" },
    { name: "positive_slippage_bps", type: "u16" },
  ];
  const ix = async (name, args) => ({ name, discriminator: await discriminator(name), accounts: [], args });
  return {
    instructions: [
      await ix("route", [plan, ...v1Tail]),
      await ix("shared_accounts_route", [{ name: "id", type: "u8" }, plan, ...v1Tail]),
      await ix("route_v2", [...v2Head, plan]),
      await ix("shared_accounts_route_v2", [{ name: "id", type: "u8" }, ...v2Head, plan]),
      await ix("claim", [{ name: "id", type: "u8" }]),
    ],
    types: [
      {
        name: "Step",
        type: { kind: "struct", fields: [{ name: "swap", type: { defined: { name: "Venue" } } }, { name: "percent", type: "u8" }, { name: "input_index", type: "u8" }, { name: "output_index", type: "u8" }] },
      },
      {
        name: "Venue",
        type: {
          kind: "enum",
          variants: [{ name: "Plain" }, { name: "Sided", fields: [{ name: "a_to_b", type: "bool" }] }, { name: "Pair", fields: ["u64", { option: "u32" }] }],
        },
      },
    ],
  };
}

const u64 = (x) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(x));
  return b;
};
const u16 = (x) => Buffer.from([x & 0xff, x >> 8]);
/// A route plan of three steps over the three venue shapes: Plain; Sided(true); Pair(7, Some(9)).
const PLAN = Buffer.concat([
  Buffer.from([3, 0, 0, 0]),
  Buffer.from([0, 100, 0, 1]),
  Buffer.from([1, 1, 100, 1, 2]),
  Buffer.concat([Buffer.from([2]), u64(7), Buffer.from([1, 9, 0, 0, 0]), Buffer.from([100, 2, 3])]),
]);

/// The data of route `name` (v1 or v2 layout), spending `inAmount` for `quoted` at `slippage` and `fee` bps.
async function routeData(name, { inAmount, quoted, slippage, fee = 0, kept = 0 }) {
  const d = Buffer.from(await discriminator(name));
  const id = name.startsWith("shared") ? Buffer.from([4]) : Buffer.alloc(0);
  if (name.endsWith("_v2")) return Buffer.concat([d, id, u64(inAmount), u64(quoted), u16(slippage), u16(fee), u16(kept), PLAN]);
  return Buffer.concat([d, id, PLAN, u64(inAmount), u64(quoted), u16(slippage), Buffer.from([fee])]);
}

const JUP = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4";
const W = { wallet: "Wa11et1111111111111111111111111111111111111", inAccount: "InAcc11111111111111111111111111111111111111", outAccount: "OutAcc1111111111111111111111111111111111111", inputMint: "InMint111111111111111111111111111111111111", outputMint: "OutMint11111111111111111111111111111111111" };

/// Route `name`'s instruction as Jupiter's answer carries it, its named accounts set to the swap asked for, or as
/// `override` (position -> key) has them.
async function routeIx(name, values, override = {}) {
  const at = JUPITER_ROUTES[name];
  const keys = Array.from({ length: 14 }, (_, i) => ({ pubkey: `Pool${i}`.padEnd(43, "1"), isSigner: false, isWritable: true }));
  keys[at.authority] = { pubkey: W.wallet, isSigner: true, isWritable: false };
  keys[at.source].pubkey = W.inAccount;
  keys[at.destination].pubkey = W.outAccount;
  if (at.destinationOverride !== undefined) keys[at.destinationOverride].pubkey = JUP;
  if (at.platformFee !== undefined) keys[at.platformFee].pubkey = JUP;
  if (at.inputMint !== undefined) keys[at.inputMint].pubkey = W.inputMint;
  if (at.outputMint !== undefined) keys[at.outputMint].pubkey = W.outputMint;
  for (const [i, k] of Object.entries(override)) keys[i] = { ...keys[i], pubkey: k };
  return { programId: JUP, accounts: keys, data: (await routeData(name, values)).toString("base64") };
}

test("PD-2: the swap's arguments are read from the front by its IDL, through every venue shape, and bytes after them are refused", async () => {
  const idl = await routeIdl();
  for (const name of Object.keys(JUPITER_ROUTES)) {
    const d = decodeInstruction(idl, await routeData(name, { inAmount: 1_000_000, quoted: 5_000, slippage: 50 }));
    assert.equal(d.name, name);
    assert.equal(d.args.in_amount, 1_000_000n);
    assert.equal(d.args.quoted_out_amount, 5_000n);
    assert.equal(d.args.slippage_bps, 50);
    assert.deepEqual(d.args.route_plan.map((s) => Object.keys(s.swap)[0]), ["Plain", "Sided", "Pair"]);
    assert.deepEqual(d.args.route_plan[2].swap.Pair, [7n, 9]);
  }
  // A decoy: the real amounts say slippage 10000 (no minimum); 19 bytes appended after them say 50. The program reads
  // the real ones, from the front, and so must the signer; an instruction with bytes after its arguments is refused.
  const real = await routeData("route", { inAmount: 1_000_000, quoted: 5_000, slippage: 10_000 });
  const decoy = Buffer.concat([real, u64(1_000_000), u64(5_000), u16(50), Buffer.from([0])]);
  assert.equal(decodeInstruction(idl, real).args.slippage_bps, 10_000);
  assert.throws(() => decodeInstruction(idl, decoy), /19 bytes after its arguments/);
  assert.throws(() => decodeInstruction(idl, real.subarray(0, real.length - 1)), /ends inside its arguments/);
  assert.equal(decodeInstruction(idl, Buffer.alloc(16)), null, "an unknown discriminator names nothing");
});

test("PD-2: Jupiter's on-chain minimum, the quoted output less its slippage, must reach the floor; fees and kept surplus refused", async () => {
  const idl = await routeIdl();
  const check = async (name, values, extra = {}) =>
    checkJupiterSwap({ instructions: [await routeIx(name, values)], programs: [JUP], decode: (d) => decodeInstruction(idl, d), ...W, amount: 1_000_000n, minOut: 4_950n, ...extra });
  for (const name of Object.keys(JUPITER_ROUTES)) {
    assert.equal(await check(name, { inAmount: 1_000_000, quoted: 5_000, slippage: 100 }), 4_950n, `${name}: 5000 less 1% is the floor`);
    await assert.rejects(check(name, { inAmount: 1_000_000, quoted: 5_000, slippage: 101 }), /under the floor of 4950/, `${name}: a lax slippage`);
    await assert.rejects(check(name, { inAmount: 1_000_000, quoted: 5_000, slippage: 10_000 }), /would accept 0/, `${name}: no minimum at all`);
    await assert.rejects(check(name, { inAmount: 999_999, quoted: 5_000, slippage: 0 }), /spends 999999, not 1000000/);
  }
  await assert.rejects(check("route", { inAmount: 1_000_000, quoted: 5_000, slippage: 0, fee: 1 }), /charges a fee of 1 bps/);
  await assert.rejects(check("route_v2", { inAmount: 1_000_000, quoted: 5_000, slippage: 0, kept: 1 }), /keeps 1 bps of the surplus/);
  await assert.rejects(check("route_v2", { inAmount: 1_000_000, quoted: 5_000, slippage: 0, fee: 25 }), /charges a fee of 25 bps/);
});

test("PD-1: one Jupiter instruction, spending the wallet's input account and paying its output account, under the wallet's signature", async () => {
  const idl = await routeIdl();
  const ok = { inAmount: 1_000_000, quoted: 5_000, slippage: 0 };
  const run = (instructions) => checkJupiterSwap({ instructions, programs: [JUP], decode: (d) => decodeInstruction(idl, d), ...W, amount: 1_000_000n, minOut: 4_950n });
  const atOf = (name) => JUPITER_ROUTES[name];
  // A second route that sells another of the wallet's coins into someone else's account: refused before simulation.
  const thief = await routeIx("route", ok, { [atOf("route").source]: "Pyth11111111111111111111111111111111111111", [atOf("route").destination]: "Thief111111111111111111111111111111111111" });
  assert.throws(() => run([...[]]), /calls its program 0 times/);
  await assert.rejects(async () => run([await routeIx("route", ok), thief]), /calls its program 2 times, not once/);
  for (const name of Object.keys(JUPITER_ROUTES)) {
    const at = atOf(name);
    await assert.rejects(async () => run([await routeIx(name, ok, { [at.source]: "Pyth11111111111111111111111111111111111111" })]), /spends from Pyth/, `${name}: another source`);
    await assert.rejects(async () => run([await routeIx(name, ok, { [at.destination]: "Thief111111111111111111111111111111111111" })]), /pays Thief/, `${name}: another destination`);
    await assert.rejects(async () => run([await routeIx(name, ok, { [at.authority]: "Other111111111111111111111111111111111111" })]), /wallet's signature/, `${name}: another authority`);
    if (at.destinationOverride !== undefined) {
      await assert.rejects(async () => run([await routeIx(name, ok, { [at.destinationOverride]: "Thief111111111111111111111111111111111111" })]), /output elsewhere/);
      assert.equal(run([await routeIx(name, ok, { [at.destinationOverride]: W.outAccount })]), 5_000n, `${name}: the override may name the output account`);
    }
    if (at.platformFee !== undefined) await assert.rejects(async () => run([await routeIx(name, ok, { [at.platformFee]: "Fee11111111111111111111111111111111111111" })]), /platform fee account/);
    if (at.inputMint !== undefined) await assert.rejects(async () => run([await routeIx(name, ok, { [at.inputMint]: "Other111111111111111111111111111111111111" })]), /spends another coin/);
    if (at.outputMint !== undefined) await assert.rejects(async () => run([await routeIx(name, ok, { [at.outputMint]: "Other111111111111111111111111111111111111" })]), /buys another coin/);
  }
  const claim = { programId: JUP, accounts: [], data: Buffer.concat([Buffer.from(await discriminator("claim")), Buffer.from([1])]).toString("base64") };
  assert.throws(() => run([claim]), /claim, not a route this signer checks/);
});

/// An SPL token account's data: `amount` at byte 64, owned by `owner` (32 bytes), with a delegate when `delegate`.
const tokenData = (amount, owner, delegate = false) => {
  const d = Buffer.alloc(165);
  owner.copy(d, 32);
  d.writeBigUInt64LE(BigInt(amount), 64);
  if (delegate) d.writeUInt32LE(1, 72);
  return d;
};

test("PD-1: every other token account the wallet owns is held to no change, so a coin the move does not name cannot leave", () => {
  const wallet = Buffer.alloc(32, 7);
  const bounds = withEveryAccount([{ address: "In", min: -100n, max: 0n }, { address: "Out", min: 50n, max: 200n }], ["In", "Out", "Pyth", "Spam"]);
  assert.deepEqual(bounds.map((b) => [b.address, b.min, b.max, b.held ?? false]), [["In", -100n, 0n, false], ["Out", 50n, 200n, false], ["Pyth", 0n, 0n, true], ["Spam", 0n, 0n, true]]);
  const acct = (amount, delegate) => ({ lamports: 2_039_280, data: tokenData(amount, wallet, delegate) });
  const before = [{ lamports: 1_000_000_000, data: null }, acct(1_000), acct(0), acct(5_000), acct(9, true)];
  const run = (after) => checkChanges({ walletKey: wallet, bounds, before, after, maxSpent: 20_000_000n });
  // The spam account carried a delegate from before the move, which the move leaves as it was: no refusal.
  const honest = [{ lamports: 999_995_000, data: null }, acct(900), acct(60), acct(5_000), acct(9, true)];
  run(honest);
  // The swap moves only its two accounts within bounds, but the PYTH account empties: refused.
  assert.throws(() => run([honest[0], honest[1], honest[2], acct(0), honest[4]]), /change Pyth by -5000, outside \[0, 0\]/);
  assert.throws(() => run([honest[0], honest[1], honest[2], acct(5_000, true), honest[4]]), /change who controls Pyth/, "a delegate approved over it");
  assert.throws(() => run([honest[0], honest[1], acct(60, true), honest[3], honest[4]]), /Out would not be the wallet's alone: it has a delegate/);
  assert.throws(() => run([{ lamports: 900_000_000, data: null }, ...honest.slice(1)]), /move 100000000 lamports/);
  assert.throws(() => run(honest.slice(0, 4)), /did not return every account/);
  assert.throws(() => withEveryAccount([], Array.from({ length: MAX_WALLET_ACCOUNTS + 1 }, (_, i) => `A${i}`)), /owns 65 token accounts, over 64/);
});

test("PD-1: a node that caps the accounts one simulation returns is asked again in chunks, the accounts kept in order", async () => {
  const calls = [];
  const simulate = async (list) => {
    calls.push(list.length);
    if (list.length > 3) throw new Error("failed to simulate transaction: Too many accounts provided; max 3");
    return { value: { err: null, logs: [], unitsConsumed: 777, accounts: list.map((a) => ({ a })) } };
  };
  const addresses = ["w", "a", "b", "c", "d", "e", "f"];
  const out = await simulateInChunks(simulate, addresses);
  assert.deepEqual(calls, [7, 3, 3, 1]);
  assert.deepEqual(out.accounts.map((x) => x.a), addresses);
  assert.equal(out.unitsConsumed, 777);
  assert.equal(out.err, null);
  const failing = await simulateInChunks(async (list) => ({ value: { err: { Custom: 1 }, logs: ["boom"], accounts: list } }), ["w"]);
  assert.deepEqual([failing.err, failing.logs], [{ Custom: 1 }, ["boom"]]);
  await assert.rejects(simulateInChunks(async () => Promise.reject(new Error("socket hang up")), ["w"]), /socket hang up/, "any other failure is not chunked");
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
  const ask = startSigner({ env: { PATH: process.env.PATH, ONLY: "this" }, path: fake, label: "solana", timeoutMs: 5_000 });
  const [slow, fast] = await Promise.all([ask("echo", { wait: 50, n: 1 }), ask("echo", { wait: 0, n: 2 })]);
  assert.equal(slow.n, 1, "each answer reaches its own request");
  assert.equal(fast.n, 2);
  const keys = await ask("env");
  assert.ok(keys.includes("ONLY") && !keys.includes("TREASURY_KEY"), "the child sees only the environment it was given");
  await assert.rejects(ask("boom"), /solana: no route/);
  await assert.rejects(ask("exit"), /the solana signer exited \(3\)/);
  assert.equal((await ask("echo", { wait: 0, n: 3 })).n, 3, "started again on the next request");
  await assert.rejects(ask("echo", { wait: 60_000 }, 100), /did not answer echo/);
  await ask("exit").catch(() => {});
});
