// End-to-end test of the restock's UniswapX buys of a local coin (`restock/uniswapx.mjs`), on an anvil fork of
// Ethereum: UniswapX's real V2 Dutch order reactor, Permit2, USDC and Ondo's NVDAon, the protocol's KeeperExecutor, and
// restock.mjs running as its own process, one round at a time. Uniswap's Trading API is faked, as are its cosigner and
// its filler: the API builds the order a real quote would, the test cosigns it with a key of its own (the order names
// its cosigner) and fills it through the reactor, as a filler would. Hermes is faked as in the restock's own test, its
// updates signed with keys the fork's Pyth receiver is given.
//
// What it proves: the typed data the service signs is the one the real reactor and Permit2 verify, so a signed order
// settles; the coin it buys lands in the treasury and is deposited into the executor, credited within the owner's
// restock allowance (RS-1); an order nobody fills is given up after its deadline and the finality margin, its USDC never
// taken; and an order the API altered against the treasury, paying someone else or paying too little, is never signed.
//
// Opt-in: needs an Ethereum RPC that serves the state near its head (a public node does; the test forks 8 blocks back).
//   forge build && forge build --root keeper              # at the repo root
//   UNISWAPX_E2E_RPC_URL=https://... node test/e2e/uniswapx.mjs   # in keeper/; MAINNET_RPC_URL serves too

import { execFile, execFileSync, spawn } from "node:child_process";
import http from "node:http";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import {
  concat,
  createPublicClient,
  createTestClient,
  createWalletClient,
  encodeAbiParameters,
  encodeFunctionData,
  http as transport,
  keccak256,
  numberToHex,
  pad,
  parseAbi,
  parseAbiParameters,
  toHex,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";
import { mainnet } from "viem/chains";
import { createNeeds } from "../../bot/needs.mjs";
import { PRICE_IDS } from "../../restock/coins.mjs";
import { EXPIRY_MARGIN_SECONDS, PERMIT2, REACTOR } from "../../restock/uniswapx.mjs";
import { decodeV2Order, orderHash } from "../../restock/uniswapx-chain.mjs";
import { encodeUpdate, guardianSlots, RECEIVER } from "./pnau.mjs";

const UPSTREAM = process.env.UNISWAPX_E2E_RPC_URL ?? process.env.MAINNET_RPC_URL;
if (!UPSTREAM) {
  console.log("UNISWAPX_E2E_RPC_URL and MAINNET_RPC_URL are unset: the UniswapX end-to-end test is skipped");
  process.exit(0);
}
const KEEPER_DIR = new URL("../../", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const json = (path) => JSON.parse(readFileSync(path, "utf8"));
const run = promisify(execFile);
const E18 = 10n ** 18n;
const ANVIL_PORT = 8661;
const HERMES_PORT = 8797;
const UX_PORT = 8796;
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const BRIDGE = "0x3ee18B2214AFF97000D974cf647E7C347E8fa585";
const NVDA = "0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE";
const NVDA_ID = PRICE_IDS.NVDAON.slice(2);
const PRICE = 180; // NVDAon, in USD, as the fake Hermes and the fake API both quote it

const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address, address) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
]);
const reactorAbi = parseAbi(["function execute((bytes order, bytes sig) order) payable"]);
const permit2Abi = parseAbi(["function nonceBitmap(address, uint256) view returns (uint256)"]);
const V2_ORDER = parseAbiParameters(
  "((address reactor, address swapper, uint256 nonce, uint256 deadline, address additionalValidationContract, bytes additionalValidationData) info, address cosigner, (address token, uint256 startAmount, uint256 endAmount) baseInput, (address token, uint256 startAmount, uint256 endAmount, address recipient)[] baseOutputs, (uint256 decayStartTime, uint256 decayEndTime, address exclusiveFiller, uint256 exclusivityOverrideBps, uint256 inputAmount, uint256[] outputAmounts) cosignerData, bytes cosignature)",
);
const COSIGNER_DATA = parseAbiParameters("(uint256 decayStartTime, uint256 decayEndTime, address exclusiveFiller, uint256 exclusivityOverrideBps, uint256 inputAmount, uint256[] outputAmounts)");

let passed = 0;
let failed = 0;
function ok(condition, what) {
  if (condition) passed++;
  else failed++;
  console.log(`  ${condition ? "PASS" : "FAIL"} ${what}`);
}
const step = (s) => console.log(`\n== ${s}`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const key = (name) => keccak256(toHex(`xindex-uniswapx-e2e-${name}`));
const units = (x, decimals) => Number(x) / 10 ** decimals;

const children = [];
const servers = [];
function shutdown(code) {
  for (const s of servers) s.close();
  process.exit(code);
}
process.on("exit", () => {
  for (const c of children) c.kill("SIGTERM");
});
process.on("SIGINT", () => shutdown(130));
process.on("uncaughtException", (error) => {
  console.log(`\n  FAIL ${error.stack ?? error}`);
  shutdown(1);
});

step("build");
for (const args of [["build"], ["build", "--root", KEEPER_DIR]]) execFileSync("forge", args, { cwd: ROOT, stdio: "pipe" });

step("Ethereum fork and executor");
// Nothing may already answer on the fork's port: a run would otherwise talk to that chain.
if (await fetch(`http://127.0.0.1:${ANVIL_PORT}`).then(() => true, () => false)) throw new Error(`something already answers on ${ANVIL_PORT}`);
const head = await createPublicClient({ transport: transport(UPSTREAM) }).getBlockNumber();
const forkBlock = head - 8n;
const anvil = spawn("anvil", ["--fork-url", UPSTREAM, "--fork-block-number", String(forkBlock), "--port", String(ANVIL_PORT), "--auto-impersonate", "--silent"], {
  stdio: ["ignore", "inherit", "inherit"],
});
children.push(anvil);
const rpc = `http://127.0.0.1:${ANVIL_PORT}`;
const chain = { ...mainnet, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: transport(rpc, { timeout: 600_000 }), pollingInterval: 500 });
for (let i = 0; ; i++) {
  try {
    await pub.getChainId();
    break;
  } catch {
    if (i > 120) throw new Error("anvil did not start");
    await sleep(500);
  }
}
const test = createTestClient({ chain, mode: "anvil", transport: transport(rpc, { timeout: 600_000 }) });
const wallet = createWalletClient({ chain, transport: transport(rpc, { timeout: 600_000 }) });
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
async function send(from, address, abi, functionName, args = []) {
  const hash = await wallet.writeContract({ account: from, address, abi, functionName, args, chain });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted (${hash})`);
  return receipt;
}
async function deploy(from, artifact, args) {
  const hash = await wallet.deployContract({ account: from, abi: artifact.abi, bytecode: artifact.bytecode.object, args, chain });
  return (await pub.waitForTransactionReceipt({ hash })).contractAddress;
}
const chainTime = async () => Number((await pub.getBlock()).timestamp);

for (const [slot, value] of guardianSlots()) await test.setStorageAt({ address: RECEIVER, index: slot, value });
const deployer = privateKeyToAccount(key("deployer")).address;
const execOwner = privateKeyToAccount(key("owner")).address;
const treasury = privateKeyToAccount(key("treasury"));
const filler = privateKeyToAccount(key("filler")).address;
const cosigner = privateKeyToAccount(key("cosigner"));
const thief = privateKeyToAccount(key("thief")).address;
for (const a of [deployer, execOwner, treasury.address, filler]) await test.setBalance({ address: a, value: 10n ** 21n });
const executorAbi = json(`${KEEPER_DIR}out/KeeperExecutor.sol/KeeperExecutor.json`).abi;
const math = await deploy(deployer, json(`${ROOT}out/WeightedMath.sol/WeightedMath.json`), []);
const factory = await deploy(deployer, json(`${ROOT}out/WeightedIndexFactory.sol/WeightedIndexFactory.json`), [
  execOwner,
  deployer,
  "0x0000000000000000000000000000000000000000",
  math,
  "0x0000000000000000000000000000000000000000",
]);
const requests = await deploy(deployer, json(`${ROOT}out/MintRequests.sol/MintRequests.json`), [factory, USDC, "0xdAC17F958D2ee523a2206206994597C13D831ec7"]);
const executor = await deploy(deployer, json(`${KEEPER_DIR}out/KeeperExecutor.sol/KeeperExecutor.json`), [
  "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
  USDC,
  factory,
  requests,
  BRIDGE,
  execOwner,
  privateKeyToAccount(key("keeper")).address,
  "0x0000000000000000000000000000000000000000",
  0,
]);
await send(execOwner, executor, executorAbi, "setTreasury", [treasury.address]);
await send(execOwner, executor, executorAbi, "setTreasuryUsdcAllowance", [100_000n * 10n ** 6n]);
const RESTOCK_GRANT = 100n * E18; // RS-1: the most NVDAon deposits may earn allowance for
await send(execOwner, executor, executorAbi, "setRestockAllowance", [NVDA, RESTOCK_GRANT]);
await test.request({ method: "anvil_dealERC20", params: [executor, USDC, numberToHex(200_000n * 10n ** 6n)] });
// The filler holds NVDAon, as Ondo's desk mints it, and lets the reactor take what it pays out.
await test.request({ method: "anvil_dealERC20", params: [filler, NVDA, numberToHex(1_000n * E18)] });
await send(filler, NVDA, erc20, "approve", [REACTOR, 2n ** 255n]);
ok((await read(NVDA, erc20, "balanceOf", [filler])) === 1_000n * E18, "the filler holds 1,000 NVDAon on the fork");
console.log(`  forked at ${forkBlock}; executor ${executor}, treasury ${treasury.address}`);

// ---------------------------------------------------------------------
// Fake Hermes and the fake Trading API
// ---------------------------------------------------------------------

function serve(port, handler) {
  servers.push(
    http
      .createServer((req, res) => {
        let body = "";
        req.on("data", (d) => (body += d));
        req.on("end", async () => {
          try {
            const [status, out] = await handler(new URL(req.url, "http://x"), req, body);
            res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(out));
          } catch (error) {
            res.writeHead(500).end(String(error.message));
          }
        });
      })
      .listen(port),
  );
}

serve(HERMES_PORT, async (url, req) => {
  if (req.headers.authorization !== "Bearer e2e") return [401, { error: "no key" }];
  const publishTime = Math.floor(Date.now() / 1000);
  const wanted = url.searchParams.getAll("ids[]").map((id) => id.replace(/^0x/, "").toLowerCase());
  const price = BigInt(PRICE * 1e8);
  const feeds = wanted.includes(NVDA_ID) ? [{ id: `0x${NVDA_ID}`, price, conf: price / 2000n, expo: -8 }] : [];
  const at = { price: String(price), conf: String(price / 2000n), expo: -8, publish_time: publishTime };
  const parsed = feeds.map((f) => ({ id: f.id.slice(2), price: at, ema_price: at }));
  const data = feeds.length === 0 ? [] : [(await encodeUpdate(feeds, publishTime)).slice(2)];
  return [200, { parsed, binary: { encoding: "hex", data } }];
});

/// How the fake API answers: "honest" quotes at PRICE less 0.2% to 0.5%; "thief" pays the coin to someone else;
/// "short" pays half the coin. Every quote and every posted order is recorded.
let mode = "honest";
const quotes = [];
const posted = [];
let nextNonce = BigInt(keccak256(toHex("nonces"))) >> 8n << 8n; // a fresh word of Permit2's bitmap
serve(UX_PORT, async (url, req, raw) => {
  if (req.headers["x-api-key"] !== "e2e") return [401, { errorCode: "Unauthorized" }];
  const body = JSON.parse(raw);
  if (url.pathname === "/v1/quote") {
    quotes.push(body);
    const coins = (BigInt(body.amount) * 10n ** 12n * E18) / BigInt(PRICE * 1e18);
    const now = await chainTime();
    const order = {
      info: { reactor: REACTOR, swapper: body.swapper, nonce: nextNonce++, deadline: BigInt(now + 180), additionalValidationContract: "0x0000000000000000000000000000000000000000", additionalValidationData: "0x" },
      cosigner: cosigner.address,
      baseInput: { token: body.tokenIn, startAmount: BigInt(body.amount), endAmount: BigInt(body.amount) },
      baseOutputs: [
        {
          token: body.tokenOut,
          startAmount: mode === "short" ? coins / 2n : (coins * 998n) / 1000n,
          endAmount: mode === "short" ? coins / 2n : (coins * 995n) / 1000n,
          recipient: mode === "thief" ? thief : body.swapper,
        },
      ],
      cosignerData: { decayStartTime: 0n, decayEndTime: 0n, exclusiveFiller: "0x0000000000000000000000000000000000000000", exclusivityOverrideBps: 0n, inputAmount: 0n, outputAmounts: [0n] },
      cosignature: "0x",
    };
    const encodedOrder = encodeAbiParameters(V2_ORDER, [order]);
    return [200, { requestId: "e2e", routing: "DUTCH_V2", quote: { encodedOrder, orderId: orderHash(order, 1), quoteId: "e2e" }, permitData: {} }];
  }
  if (url.pathname === "/v1/order") {
    posted.push(body);
    return [201, { requestId: "e2e", orderId: body.quote.orderId, orderStatus: "open" }];
  }
  return [404, { errorCode: "ResourceNotFound" }];
});

/// Fills posted order `p` through the real reactor, as a filler would: cosigned by the order's cosigner over its hash
/// and decay window, then executed by the filler, who pays the coin and takes the USDC.
async function fill(p) {
  const order = decodeV2Order(p.quote.encodedOrder);
  const now = await chainTime();
  const cosignerData = { decayStartTime: BigInt(now), decayEndTime: BigInt(now + 60), exclusiveFiller: "0x0000000000000000000000000000000000000000", exclusivityOverrideBps: 0n, inputAmount: 0n, outputAmounts: [0n] };
  const digest = keccak256(concat([orderHash(order, 1), encodeAbiParameters(COSIGNER_DATA, [cosignerData])]));
  const s = await sign({ hash: digest, privateKey: key("cosigner") });
  const cosignature = concat([s.r, s.s, numberToHex(s.v, { size: 1 })]);
  const encoded = encodeAbiParameters(V2_ORDER, [{ ...order, cosignerData, cosignature }]);
  // Simulated first, so a refusal names its error rather than a mined revert.
  await pub
    .call({ account: filler, to: REACTOR, data: encodeFunctionData({ abi: reactorAbi, functionName: "execute", args: [{ order: encoded, sig: p.signature }] }) })
    .catch((error) => {
      throw new Error(`the reactor refuses the fill: ${error.cause?.data ?? error.data ?? ""} ${error.shortMessage ?? error.message}`);
    });
  // A fixed limit: viem's estimate of the reactor's fill falls short on the fork and the fill runs out of gas, a
  // filler's own concern, not the order's.
  const hash = await wallet.writeContract({ account: filler, address: REACTOR, abi: reactorAbi, functionName: "execute", args: [{ order: encoded, sig: p.signature }], chain, gas: 3_000_000n });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    const trace = await test.request({ method: "debug_traceTransaction", params: [hash, { tracer: "callTracer" }] }).catch((e) => ({ error: e.message }));
    throw new Error(`execute reverted (${hash}), gas used ${receipt.gasUsed}: ${JSON.stringify(trace).slice(0, 3000)}`);
  }
  return receipt;
}

// ---------------------------------------------------------------------
// Rounds
// ---------------------------------------------------------------------

const dir = mkdtempSync(join(tmpdir(), "uniswapx-e2e-"));
const needsFile = join(dir, "needs.json");
const needs = createNeeds({ write: (text) => writeFileSync(needsFile, text) });
const env = {
  ...process.env,
  RPC_URL: rpc,
  EXECUTOR: executor,
  TREASURY_KEY: key("treasury"),
  PYTH_API_KEY: "e2e",
  HERMES_URL: `http://127.0.0.1:${HERMES_PORT}`,
  UNISWAP_API_KEY: "e2e",
  UNISWAP_API_URL: `http://127.0.0.1:${UX_PORT}/v1`,
  NEEDS_FILE: needsFile,
  JOURNAL_FILE: join(dir, "journal.json"),
  RESTOCK_COINS: "NVDAON",
  RESTOCK_TREASURY_TARGET_USD: "500",
};
async function round(label) {
  needs.flush();
  const { stdout: out } = await run("node", [`${KEEPER_DIR}restock.mjs`, "--once"], { env, cwd: KEEPER_DIR });
  for (const line of out.trim().split("\n").filter(Boolean)) console.log(`  [${label}] ${line.replace(/^\S+ /, "")}`);
  return out;
}
const journal = () => json(env.JOURNAL_FILE);
const orders = () => Object.values(journal().moves).filter((m) => m.kind === "order");
const treasuryNvda = () => read(NVDA, erc20, "balanceOf", [treasury.address]);
const treasuryUsdc = () => read(USDC, erc20, "balanceOf", [treasury.address]);
const stock = () => read(NVDA, erc20, "balanceOf", [executor]);
const allowance = () => read(executor, executorAbi, "stockAllowance", [NVDA]);
const restockLeft = () => read(executor, executorAbi, "restockAllowance", [NVDA]);
const nonceSpent = async (nonce) => ((await read(PERMIT2, permit2Abi, "nonceBitmap", [treasury.address, BigInt(nonce) >> 8n])) >> (BigInt(nonce) & 0xffn)) & 1n;

step("a need is bought through a UniswapX order the real reactor settles, and deposited");
const need = 8n * E18; // 1,440 USD of NVDAon
needs.report("index:1", "fill", [{ token: NVDA, amount: need }]);
const first = await round("order");
ok(/drew [\d.]+ USDC from the executor/.test(first), "the treasury draws the order's USDC first");
ok(/UniswapX order \d+ signed and posted/.test(first), "it signs the order and posts it");
ok(quotes.length === 1 && quotes[0].type === "EXACT_INPUT" && quotes[0].tokenOut.toLowerCase() === NVDA.toLowerCase(), "the API was asked for an exact USDC spend on NVDAon");
ok(posted.length === 1, "the API received one signed order");
const [o1] = orders();
ok(o1?.stage === "sent" && o1.data.posted === true, "the journal holds it, posted");
ok((await read(USDC, erc20, "allowance", [treasury.address, PERMIT2])) === BigInt(o1.data.maxIn), "Permit2 may take exactly what the order may spend");
const usdcBefore = await treasuryUsdc();
const receipt = await fill(posted[0]);
ok(receipt.status === "success", "the real V2 reactor settles the order: the signature is over the typed data it verifies");
const bought = await treasuryNvda();
ok(bought >= BigInt(o1.data.minOut), `the treasury received ${units(bought, 18).toFixed(4)} NVDAon, at least the order's least`);
ok(usdcBefore - (await treasuryUsdc()) === BigInt(o1.data.maxIn), "and paid exactly the order's USDC");
ok((await nonceSpent(o1.data.nonce)) === 1n, "Permit2 shows the order's nonce spent");
const second = await round("filled");
ok(/UniswapX order for NVDAON filled/.test(second), "the next round reads the order filled from Permit2");
const third = await round("deposit");
ok(/deposited \d+ USD of it into the executor/.test(third), "and the one after deposits the coin");
ok((await stock()) === bought && (await treasuryNvda()) === 0n, "the executor holds what was bought, the treasury none");
ok((await allowance()) === bought, "the keeper may deliver exactly that");
ok((await restockLeft()) === RESTOCK_GRANT - bought, "which spent the owner's restock allowance by as much (RS-1)");
const quiet = await round("covered");
ok(!/UniswapX order \d+ signed/.test(quiet) && posted.length === 1, "covered, it orders nothing more");

step("an order nobody fills is given up after its deadline and Ethereum's finality, its USDC untouched");
needs.report("index:1", "fill", [{ token: NVDA, amount: 20n * E18 }]);
await round("unfilled order");
const o2 = orders().find((m) => m.id !== o1.id);
ok(o2?.stage === "sent" && posted.length === 2, "a second order is signed and posted");
const held = await treasuryUsdc();
const waiting = await round("waiting");
ok(!/signed and posted/.test(waiting), "while it is open the treasury orders nothing else");
await test.increaseTime({ seconds: o2.data.deadline - (await chainTime()) + EXPIRY_MARGIN_SECONDS - 30 });
await test.mine({ blocks: 1 });
await round("inside the margin");
ok(orders().find((m) => m.id === o2.id).stage === "sent", "inside the finality margin it is still held");
await test.increaseTime({ seconds: 60 });
await test.mine({ blocks: 1 });
const expired = await round("expired");
ok(/UniswapX order for NVDAON expired unfilled; dropped/.test(expired), "past it, the order is dropped");
ok((await nonceSpent(o2.data.nonce)) === 0n && (await treasuryUsdc()) >= held, "nothing was taken: its nonce unspent, the USDC still the treasury's");

step("an order the API altered against the treasury is never signed");
for (const [m, why] of [
  ["thief", /UniswapX's order refused, nothing signed: it pays 0x[0-9a-fA-F]{40}, not the treasury/],
  ["short", /UniswapX's order refused, nothing signed: it may pay \d+, below the \d+ the loss bound allows/],
]) {
  mode = m;
  const before = posted.length;
  const out = await round(m);
  ok(why.test(out), `${m}: refused, with its reason`);
  ok(posted.length === before, `${m}: nothing posted`);
  ok(!orders().some((x) => x.stage === "sent" || x.stage === "signed"), `${m}: nothing in the journal waits`);
}

console.log(`\n${passed} passed, ${failed} failed`);
shutdown(failed === 0 ? 0 : 1);
