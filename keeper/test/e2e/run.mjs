// End-to-end test of the keeper on an anvil fork of Ethereum: real tokens and Uniswap V3 pools, the real Pyth
// contract (verifying updates against five keys this test installs, see pnau.mjs), the protocol's own factory and
// hubs, KeeperExecutor, and keeper.mjs running as its own process against a fake Hermes this file serves.
//
// Opt-in, like the repo's fork suites: needs an archive RPC.
//   forge build && forge build --root keeper        # at the repo root
//   MAINNET_RPC_URL=https://... npm run e2e          # in keeper/; FORK_BLOCK optional (default: head - 8)
//
// Four indexes, each a scenario:
//   LQ   WETH/WBTC/LINK/UNI. LINK's own pool is pushed up 12%. Held back while WBTC's feed is quiet; then started,
//        filled only once the auction pays, through routes that include a two-hop buy. Its first fill is mined one
//        slot late on purpose: it must revert cheaply (Expired) and be sent again.
//   MIX  WETH/SOL/NVDAon. SOL up 20%: the index sells SOL, which has no route (kept as stock), and buys NVDAon, which
//        has none either: not started until the executor holds NVDAon, then filled from that stock.
//   DRY  WETH/APT. APT down 20%: the index would buy APT, which nobody routes or holds: never started.
//   SHR  WETH/JUP. JUP up 20%: the index sells JUP, kept as stock, and buys WETH: started and filled.

import { execFileSync, spawn } from "node:child_process";
import http from "node:http";
import { readFileSync } from "node:fs";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  decodeEventLog,
  decodeFunctionData,
  http as transport,
  keccak256,
  numberToHex,
  parseAbi,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { encodeUpdate, guardianSlots, RECEIVER } from "./pnau.mjs";

const UPSTREAM = process.env.MAINNET_RPC_URL;
if (!UPSTREAM) {
  console.log("MAINNET_RPC_URL is unset: the keeper's end-to-end test is skipped");
  process.exit(0);
}
const PORT = 8555;
const HERMES_PORT = 8791;
const RPC = `http://127.0.0.1:${PORT}`;
const KEEPER_DIR = new URL("../../", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const json = (path) => JSON.parse(readFileSync(path, "utf8"));

const PYTH = "0x4305FB66699C3B2702D4d05CF36551390A4c69C6";
const SWAP_ROUTER02 = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45";
const V3_FACTORY = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const T = {
  WETH: { a: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", id: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace", d: 18 },
  WBTC: { a: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", id: "0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33", d: 8 },
  LINK: { a: "0x514910771AF9Ca656af840dff83E8264EcF986CA", id: "0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221", d: 18 },
  UNI: { a: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984", id: "0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501", d: 18 },
  SOL: { a: "0xD31a59c85aE9D8edEFeC411D448f90841571b89c", id: "0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d", d: 9, usd: 150 },
  NVDAON: { a: "0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE", id: "0x207ddea2a443d30b7e13a7c88a9e3f106765deb97049afc65a18cede50fffc82", d: 18, usd: 180 },
  APT: { a: "0x8CDf7AF57E4c8B930e1B23c477c22f076530585e", id: "0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5", d: 8, usd: 5 },
  JUP: { a: "0x8687a10BCa6F139B25eb31020FCABB5782214764", id: "0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996", d: 6, usd: 0.5 },
};

const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
  "function decimals() view returns (uint8)",
]);
const v3 = parseAbi(["function getPool(address, address, uint24) view returns (address)"]);
const pool = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool)",
  "function token0() view returns (address)",
]);
const router = parseAbi([
  "struct P { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }",
  "function exactInputSingle(P params) payable returns (uint256)",
]);

// ---------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------

let passed = 0;
let failed = 0;
function ok(condition, what) {
  if (condition) passed++;
  else failed++;
  console.log(`  ${condition ? "PASS" : "FAIL"} ${what}`);
}
const step = (s) => console.log(`\n== ${s}`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const key = (name) => keccak256(toHex(`xindex-keeper-e2e-${name}`));
const addr = (name) => privateKeyToAccount(key(name)).address;

const children = [];
let hermesServer;
function shutdown(code) {
  hermesServer?.close();
  process.exit(code);
}
// However this process ends, anvil and the keeper end with it.
process.on("exit", () => {
  for (const c of children) c.kill("SIGTERM");
});
process.on("SIGINT", () => shutdown(130));
process.on("uncaughtException", (error) => {
  console.log(`\n  FAIL ${error.stack ?? error}`);
  shutdown(1);
});

const chain = { ...mainnet, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: transport(RPC, { timeout: 120_000 }) });
const test = createTestClient({ chain, mode: "anvil", transport: transport(RPC, { timeout: 120_000 }) });
const wallet = createWalletClient({ chain, transport: transport(RPC, { timeout: 120_000 }) });

async function send(from, address, abi, functionName, args = []) {
  const hash = await wallet.writeContract({ account: from, address, abi, functionName, args, chain, gas: 16_000_000n });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} on ${address} reverted (${hash})`);
  return receipt;
}
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
const now = async () => (await pub.getBlock({ blockTag: "latest" })).timestamp;
const deal = (token, who, amount) =>
  test.request({ method: "anvil_dealERC20", params: [who, token, numberToHex(amount)] });

// ---------------------------------------------------------------------
// Fork
// ---------------------------------------------------------------------

// Build both projects first: a stale artifact (an executor left over from a mutation run, say) must never be the one
// deployed here.
step("build");
for (const args of [["build"], ["build", "--root", KEEPER_DIR]]) {
  try {
    execFileSync("forge", args, { cwd: ROOT, stdio: "pipe" });
  } catch (error) {
    console.log(`${error.stdout ?? ""}${error.stderr ?? ""}`);
    throw error;
  }
}
const FACTORY = json(`${ROOT}out/WeightedIndexFactory.sol/WeightedIndexFactory.json`);
const HUB = json(`${ROOT}abi/WeightedHub.json`);
const EXECUTOR = json(`${KEEPER_DIR}out/KeeperExecutor.sol/KeeperExecutor.json`);
const REQUESTS = json(`${ROOT}out/MintRequests.sol/MintRequests.json`);

step("anvil fork");
const head = await createPublicClient({ transport: transport(UPSTREAM) }).getBlockNumber();
const forkBlock = process.env.FORK_BLOCK ?? String(head - 8n);
const anvil = spawn(
  "anvil",
  ["--fork-url", UPSTREAM, "--fork-block-number", forkBlock, "--port", String(PORT), "--auto-impersonate", "--silent"],
  { stdio: ["ignore", "inherit", "inherit"] },
);
children.push(anvil);
for (let i = 0; ; i++) {
  try {
    await pub.getChainId();
    break;
  } catch {
    if (i > 60) throw new Error("anvil did not start");
    await sleep(500);
  }
}
console.log(`  forked at ${forkBlock}`);

const owner = addr("owner");
const guardian = addr("guardian");
const creator = addr("creator");
const deployer = addr("deployer");
const execOwner = addr("executor-owner");
const trader = addr("trader");
const keeperAccount = privateKeyToAccount(key("keeper"));
for (const a of [owner, guardian, creator, deployer, execOwner, trader, keeperAccount.address]) {
  await test.setBalance({ address: a, value: 10n ** 21n });
}
for (const [slot, value] of guardianSlots()) await test.setStorageAt({ address: RECEIVER, index: slot, value });

// ---------------------------------------------------------------------
// Prices: Uniswap mids for the liquid coins, chosen ones for the rest; served by the fake Hermes
// ---------------------------------------------------------------------

async function mid(token, quote, decT, decQ) {
  let best = null;
  for (const fee of [100, 500, 3000, 10000]) {
    const p = await read(V3_FACTORY, v3, "getPool", [token, quote, fee]);
    if (p === "0x0000000000000000000000000000000000000000") continue;
    const depth = await read(quote, erc20, "balanceOf", [p]);
    if (!best || depth > best.depth) best = { p, depth };
  }
  const [sqrt] = await read(best.p, pool, "slot0");
  const t0 = (await read(best.p, pool, "token0")).toLowerCase() === token.toLowerCase();
  const raw = (Number(sqrt) / 2 ** 96) ** 2;
  return { perToken: (t0 ? raw : 1 / raw) * 10 ** (decT - decQ), pool: best.p };
}
const prices = new Map(); // id without 0x -> {price, conf, expo}
const quiet = new Set();
const setUsd = (coin, usd) => {
  const price = BigInt(Math.round(usd * 1e8));
  prices.set(coin.id.slice(2).toLowerCase(), { price, conf: price / 2000n, expo: -8 });
};
const usdOf = (coin) => Number(prices.get(coin.id.slice(2).toLowerCase()).price) / 1e8;
const ethUsd = (await mid(T.WETH.a, USDC, 18, 6)).perToken;
setUsd(T.WETH, ethUsd);
for (const c of ["WBTC", "LINK", "UNI"]) setUsd(T[c], (await mid(T[c].a, T.WETH.a, T[c].d, 18)).perToken * ethUsd);
for (const c of ["SOL", "NVDAON", "APT", "JUP"]) setUsd(T[c], T[c].usd);

hermesServer = http
  .createServer(async (req, res) => {
    try {
      if (req.headers.authorization !== "Bearer e2e") return res.writeHead(401).end("no key");
      const url = new URL(req.url, "http://x");
      const ids = url.searchParams.getAll("ids[]").map((id) => id.replace(/^0x/, "").toLowerCase());
      const m = url.pathname.match(/^\/v2\/updates\/price\/(latest|\d+)$/);
      if (!m) return res.writeHead(404).end("no route");
      const latest = m[1] === "latest";
      const t = latest ? Number(await now()) - 12 : Number(m[1]);
      const feeds = ids.map((id) => {
        const p = prices.get(id);
        if (!p) throw new Error(`unknown id ${id}`);
        return { id: `0x${id}`, ...p };
      });
      const body = {
        parsed: feeds.map((f) => ({
          id: f.id.slice(2),
          price: { price: String(f.price), conf: String(f.conf), expo: f.expo, publish_time: latest && quiet.has(f.id.slice(2)) ? t - 3600 : t },
        })),
      };
      if (!latest) body.binary = { encoding: "hex", data: [(await encodeUpdate(feeds, t)).slice(2)] };
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
    } catch (error) {
      res.writeHead(400).end(String(error.message));
    }
  })
  .listen(HERMES_PORT);

// ---------------------------------------------------------------------
// Protocol: the factory, listings, four indexes, the executor
// ---------------------------------------------------------------------

step("protocol");
const factoryHash = await wallet.deployContract({
  account: deployer,
  abi: FACTORY.abi,
  bytecode: FACTORY.bytecode.object,
  args: [owner, guardian, PYTH],
  chain,
});
const factory = (await pub.waitForTransactionReceipt({ hash: factoryHash })).contractAddress;
for (const c of Object.values(T)) await send(owner, factory, FACTORY.abi, "proposeListing", [c.a, c.id]);
await test.setNextBlockTimestamp({ timestamp: (await now()) + 2n * 86_400n + 1n });
await test.mine({ blocks: 1 });
for (const c of Object.values(T)) await send(owner, factory, FACTORY.abi, "executeListing", [c.a]);

/// An index of `coins` with `weights` (bps), `shares` of it issued in kind, each share worth `value` dollars.
async function createIndex(name, coins, weights, value, shares) {
  const specs = coins.map((c, i) => ({
    token: c.a,
    weight: BigInt(weights[i]),
    units: BigInt(Math.max(10_000, Math.ceil(((weights[i] / 1e4) * value * 10 ** c.d) / usdOf(c)))),
  }));
  // No creator fee, any platform fee the policy charges, the shortest interval, open and listed.
  const params = {
    creatorFeeBps: 0,
    creatorStreamingBps: 0,
    maxPlatformFeeBps: 25,
    maxPlatformStreamingBps: 100,
    rebalanceInterval: 7 * 24 * 3600,
    gated: false,
    listed: true,
  };
  const receipt = await send(creator, factory, FACTORY.abi, "createIndex", [name, name, specs, params]);
  const index = receipt.logs
    .map((l) => {
      try {
        return decodeEventLog({ abi: FACTORY.abi, ...l });
      } catch {
        return null;
      }
    })
    .find((e) => e?.eventName === "IndexCreated").args.index;
  const need = await read(index, HUB, "previewIssue", [shares]);
  for (let i = 0; i < coins.length; i++) {
    await deal(coins[i].a, creator, need[i]);
    await send(creator, coins[i].a, erc20, "approve", [index, need[i]]);
  }
  await send(creator, index, HUB, "issue", [shares, creator]);
  return index;
}
const LQ = await createIndex("LQ", [T.WETH, T.WBTC, T.LINK, T.UNI], [4000, 3000, 1500, 1500], 1000, 1000n * 10n ** 18n);
const MIX = await createIndex("MIX", [T.WETH, T.SOL, T.NVDAON], [5000, 2500, 2500], 1000, 200n * 10n ** 18n);
const DRY = await createIndex("DRY", [T.WETH, T.APT], [5000, 5000], 1000, 100n * 10n ** 18n);
const SHR = await createIndex("SHR", [T.WETH, T.JUP], [5000, 5000], 1000, 100n * 10n ** 18n);
const names = { [LQ]: "LQ", [MIX]: "MIX", [DRY]: "DRY", [SHR]: "SHR" };
console.log(`  factory ${factory}; LQ ${LQ}, MIX ${MIX}, DRY ${DRY}, SHR ${SHR}`);

const requestsHash = await wallet.deployContract({
  account: deployer,
  abi: REQUESTS.abi,
  bytecode: REQUESTS.bytecode.object,
  args: [factory, USDC, USDT],
  chain,
});
const requests = (await pub.waitForTransactionReceipt({ hash: requestsHash })).contractAddress;
const exHash = await wallet.deployContract({
  account: deployer,
  abi: EXECUTOR.abi,
  bytecode: EXECUTOR.bytecode.object,
  args: [SWAP_ROUTER02, USDC, factory, requests, execOwner, keeperAccount.address],
  chain,
});
const executor = (await pub.waitForTransactionReceipt({ hash: exHash })).contractAddress;
await deal(USDC, executor, 200_000n * 10n ** 6n);

// The market moves: LINK's own pool up 12% (and Pyth with it), SOL and JUP up 20%, APT down 20%.
const link = await mid(T.LINK.a, T.WETH.a, 18, 18);
let linkNow = link.perToken;
for (let amount = 20n * 10n ** 18n; linkNow < link.perToken * 1.12; ) {
  await deal(T.WETH.a, trader, amount);
  await send(trader, T.WETH.a, erc20, "approve", [SWAP_ROUTER02, amount]);
  await send(trader, SWAP_ROUTER02, router, "exactInputSingle", [
    { tokenIn: T.WETH.a, tokenOut: T.LINK.a, fee: 3000, recipient: trader, amountIn: amount, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n },
  ]);
  linkNow = (await mid(T.LINK.a, T.WETH.a, 18, 18)).perToken;
}
setUsd(T.LINK, linkNow * ethUsd);
setUsd(T.SOL, 180);
setUsd(T.JUP, 0.6);
setUsd(T.APT, 4);
quiet.add(T.WBTC.id.slice(2).toLowerCase());

await test.setNextBlockTimestamp({ timestamp: (await now()) + 7n * 86_400n + 1n });
await test.mine({ blocks: 1 });
await test.request({ method: "anvil_setBlockTimestampInterval", params: [12] });

// ---------------------------------------------------------------------
// The keeper
// ---------------------------------------------------------------------

const logLines = [];
let lastDone = -1n;
const keeper = spawn(process.execPath, ["keeper.mjs"], {
  cwd: KEEPER_DIR,
  env: {
    ...process.env,
    RPC_URL: RPC,
    KEEPER_KEY: key("keeper"),
    FACTORY: factory,
    EXECUTOR: executor,
    REQUESTS: requests,
    PYTH_API_KEY: "e2e",
    HERMES_URL: `http://127.0.0.1:${HERMES_PORT}`,
    INDEXES: "",
    MIN_PROFIT_USD: "1",
    MIN_TVL_USD: "1000",
    KEEPER_DEBUG: "1",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
children.push(keeper);
let buffer = "";
const onOutput = (chunk) => {
  buffer += chunk;
  const lines = buffer.split("\n");
  buffer = lines.pop();
  for (let line of lines) {
    for (const [a, n] of Object.entries(names)) line = line.replaceAll(a, n);
    logLines.push(line);
    const done = line.match(/ block (\d+) done$/);
    if (done) lastDone = BigInt(done[1]);
    else console.log(`    keeper| ${line.slice(25)}`);
  }
};
keeper.stdout.on("data", onOutput);
keeper.stderr.on("data", onOutput);
keeper.on("exit", (code) => {
  if (code !== null && code !== 0) console.log(`    keeper exited with ${code}`);
});

/// Waits until the keeper has handled the chain's head, including any block its own transactions mined.
async function settle(timeoutMs = 240_000) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const at = await pub.getBlockNumber({ cacheTime: 0 });
    if (lastDone >= at) {
      await sleep(500);
      if ((await pub.getBlockNumber({ cacheTime: 0 })) === at && lastDone >= at) return at;
      continue;
    }
    if (Date.now() > end) throw new Error(`the keeper did not handle block ${at} (last ${lastDone})`);
    if (keeper.exitCode !== null) throw new Error("the keeper exited");
    await sleep(250);
  }
}
const mineAt = async (timestamp) => {
  await test.setNextBlockTimestamp({ timestamp });
  await test.mine({ blocks: 1 });
  return settle();
};
const mineBlocks = async (n) => {
  await test.mine({ blocks: n });
  return settle();
};
const proposals = async (index) => read(index, HUB, "proposalCount");
const nonceOf = async (index) => read(index, HUB, "rebalanceNonce");
const logged = (text) => logLines.some((l) => l.includes(text));

// ---------------------------------------------------------------------
// Starts
// ---------------------------------------------------------------------

step("first start check: only SHR may start");
await settle();
ok((await proposals(LQ)) === 0n && logged("LQ not starting: feed closed or quiet"), "LQ held back while WBTC's feed is quiet");
ok((await proposals(MIX)) === 0n && logged("MIX not starting: restock"), "MIX held back: no route and no stock of NVDAon");
ok((await proposals(DRY)) === 0n && logged("DRY not starting: restock"), "DRY held back: no route and no stock of APT");
ok((await proposals(SHR)) === 1n, "SHR started: its sold JUP is kept, its WETH bought");

step("WBTC's feed resumes; the executor gets NVDAon stock");
quiet.clear();
const [mixTokens, mixUnits] = await read(MIX, HUB, "components");
const mixSupply = await read(MIX, HUB, "totalSupply");
const nvdaStock = (mixSupply * mixUnits[2]) / 10n ** 18n / 2n;
await deal(T.NVDAON.a, executor, nvdaStock);
await mineBlocks(25);
ok((await proposals(LQ)) === 1n, "LQ started");
await mineBlocks(25);
ok((await proposals(MIX)) === 1n, "MIX started from stock");
await mineBlocks(25);
ok((await proposals(DRY)) === 0n, "DRY still not started");

// ---------------------------------------------------------------------
// Fills
// ---------------------------------------------------------------------

step("auctions: every block a step further; one fill mined a slot late on purpose");
const [shrEta] = await read(SHR, HUB, "pendingRebalance");
const balances = async (coins) => Promise.all(coins.map((c) => read(c.a, erc20, "balanceOf", [executor])));
const [jup0, sol0, nvda0] = await balances([T.JUP, T.SOL, T.NVDAON]);
const usdc0 = await read(USDC, erc20, "balanceOf", [executor]);
await test.request({ method: "evm_setAutomine", params: [false] });
let lateHash = null;
const filled = new Set();
for (let t = shrEta; t <= shrEta + 30n * 3600n && filled.size < 3; t += 3600n) {
  await mineAt(t);
  // A transaction of the keeper's waits in the pool: mine it, the first fill one slot late.
  for (;;) {
    const pool = await test.request({ method: "txpool_content", params: [] });
    const mine = Object.entries(pool.pending ?? {}).find(([a]) => a.toLowerCase() === keeperAccount.address.toLowerCase());
    if (!mine) break;
    const [hash] = Object.values(mine[1]).map((tx) => tx.hash);
    const latest = await pub.getBlock({ blockTag: "latest" });
    const late = lateHash === null && Object.values(mine[1])[0].to?.toLowerCase() === executor.toLowerCase();
    if (late) lateHash = hash;
    await mineAt(latest.timestamp + (late ? 24n : 12n));
  }
  for (const index of [LQ, MIX, SHR]) if ((await nonceOf(index)) === 1n) filled.add(index);
}
await test.request({ method: "evm_setAutomine", params: [true] });

const late = lateHash && (await pub.getTransactionReceipt({ hash: lateHash }));
ok(late && late.status === "reverted" && late.gasUsed < 150_000n, `a fill mined a slot late reverts early (${late?.gasUsed} gas)`);
for (const index of [LQ, MIX, SHR]) ok((await nonceOf(index)) === 1n, `${names[index]} filled`);
ok((await nonceOf(DRY)) === 0n && (await proposals(DRY)) === 0n, "DRY never started");

/// The settlement of `index`'s fill, from its Rebalanced event, and the keeper's transaction that made it.
async function settlement(index) {
  const logs = await pub.getContractEvents({ address: index, abi: HUB, eventName: "Rebalanced", fromBlock: BigInt(forkBlock) + 1n });
  const event = logs[logs.length - 1];
  const tx = await pub.getTransaction({ hash: event.transactionHash });
  return { ...event.args, from: tx.from, call: decodeFunctionData({ abi: EXECUTOR.abi, data: tx.input }) };
}
const MU_MAX = 1_020_000_000_000_000_000n;
for (const index of [LQ, MIX, SHR]) {
  const s = await settlement(index);
  ok(s.from.toLowerCase() === keeperAccount.address.toLowerCase() && s.mu < MU_MAX, `${names[index]} filled by the keeper at mu ${Number(s.mu) / 1e18}, below MU_MAX`);
}
const lq = await settlement(LQ);
const [, , routes] = lq.call.args;
ok(
  routes.some((r, i) => lq.amountsIn[i] > 0n && (r.length - 2) / 2 === 66),
  "LQ's fill bought a coin along a two-hop route",
);
const mix = await settlement(MIX);
const shr = await settlement(SHR);
const [jup1, sol1, nvda1] = await balances([T.JUP, T.SOL, T.NVDAON]);
ok(jup1 - jup0 === shr.amountsOut[1], "SHR's JUP is kept as stock");
ok(sol1 - sol0 === mix.amountsOut[1], "MIX's SOL is kept as stock");
ok(nvda0 - nvda1 === mix.amountsIn[2], "MIX's NVDAon came out of stock");
const usdc1 = await read(USDC, erc20, "balanceOf", [executor]);
console.log(`  executor USDC float ${Number(usdc0) / 1e6} -> ${Number(usdc1) / 1e6}`);

step(`done: ${passed} passed, ${failed} failed`);
shutdown(failed === 0 ? 0 : 1);
