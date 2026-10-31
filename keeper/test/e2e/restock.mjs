// End-to-end test of the restock service on anvil forks of Ethereum and each EVM home chain (BNB Chain, Base,
// Optimism, Avalanche): the real Wormhole Token Bridge and core on every chain, Circle's real CCTP V2 contracts, the
// home chains' real DEX pools and tokens, the Wormhole copies on Ethereum, and the protocol's KeeperExecutor, with
// restock.mjs running as its own process, one round at a time.
//
// No guardian or attester signs for a test, so each fork's Wormhole core gets one test key as its whole guardian set,
// and each fork's CCTP message transmitter one test attester with a threshold of one; a fake Wormholescan signs what
// each fork's core published, as the guardians would, and a fake Iris finalizes and attests each CCTP burn, as Circle
// would (it fills the nonce, the finality and fee executed, and the expiry, as Iris does, read on 2026-10-19 against a
// real Base message). Hermes is faked too, at each coin's own pool price.
//
// Opt-in: needs an Ethereum archive RPC; the home chains are forked near their heads (BSC_RPC_URL, BASE_RPC_URL,
// OPTIMISM_RPC_URL, AVALANCHE_RPC_URL, with archive-serving public defaults).
//   forge build && forge build --root keeper        # at the repo root
//   MAINNET_RPC_URL=https://... npm run e2e:restock  # in keeper/; RESTOCK_E2E_CHAINS=bsc,base to run fewer
//
// For each chain, the keeper reports a need for about $1,300 of its coin. The service buys it on the home chain,
// bridges it in and redeems it into the executor, whose allowance rises by what arrived; then the need goes away and
// it bridges the spare stock back out and sells it there. On the three chains CCTP serves, the home wallet starts with
// no float: the treasury draws USDC from the executor and funds the chain by CCTP before the buy, and after the sale
// sweeps the idle float back and repays the executor. BNB Chain's float is dealt, as an operator tops it up by hand.
// Last, a move signed but never broadcast is resumed by the next round, and one whose nonce went elsewhere is dropped.

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
  decodeEventLog,
  encodeFunctionData,
  http as transport,
  keccak256,
  numberToHex,
  pad,
  parseAbi,
  toHex,
} from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";
import { avalanche, base, bsc, mainnet, optimism } from "viem/chains";
import { createNeeds } from "../../bot/needs.mjs";
import { EVM_CHAINS } from "../../restock/evm.mjs";
import { ORPHAN_SECONDS } from "../../restock/sending.mjs";

const UPSTREAM = process.env.MAINNET_RPC_URL;
if (!UPSTREAM) {
  console.log("MAINNET_RPC_URL is unset: the restock end-to-end test is skipped");
  process.exit(0);
}
const KEEPER_DIR = new URL("../../", import.meta.url).pathname;
const ROOT = new URL("../../../", import.meta.url).pathname;
const json = (path) => JSON.parse(readFileSync(path, "utf8"));
const E18 = 10n ** 18n;
const HERMES_PORT = 8792;
const SCAN_PORT = 8793;
const IRIS_PORT = 8794;
const MT = "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64"; // CCTP V2's message transmitter, on every chain
const MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d"; // and its token messenger
const ETH_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const ETH_BRIDGE = "0x3ee18B2214AFF97000D974cf647E7C347E8fa585";

/// Each home chain: its fork's upstream, its coin (the home token, the Ethereum copy, its Pyth id, the restock's
/// symbol), its float, its Uniswap V3 fork's quoter, fee tiers and wrapped gas coin, its Wormhole chain and bridge, its
/// CCTP domain.
const HOMES = {
  bsc: {
    viem: bsc,
    upstream: process.env.BSC_RPC_URL ?? "https://bsc-mainnet.public.blastapi.io",
    symbol: "XRP",
    home: "0x1d2f0da169ceb9fc7b3144628db156f3f6c60dbe",
    copy: "0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535",
    id: "ec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8",
    float: "0x55d398326f99059fF775485246999027B3197955",
    floatDecimals: 18,
    quoter: "0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997",
    fees: [100, 500, 2500, 10000],
    wnative: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    wnativeFee: 100,
    wormhole: 4,
    bridge: "0xB6F6D86a8f9879A9c87f643768d9efc38c1Da6E7",
    cctp: null,
  },
  base: {
    viem: base,
    upstream: process.env.BASE_RPC_URL ?? "https://base.gateway.tenderly.co",
    symbol: "AERO",
    home: "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
    copy: "0x750525C1877E30304F1E22b1b49b4C9DdE674ddF",
    id: "9db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f",
    float: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    floatDecimals: 6,
    quoter: "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a",
    fees: [100, 500, 3000, 10000],
    wnative: "0x4200000000000000000000000000000000000006",
    wnativeFee: 500,
    wormhole: 30,
    bridge: "0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627",
    cctp: 6,
  },
  optimism: {
    viem: optimism,
    upstream: process.env.OPTIMISM_RPC_URL ?? "https://optimism.gateway.tenderly.co",
    symbol: "OP",
    home: "0x4200000000000000000000000000000000000042",
    copy: "0x1df721D242E0783F8fCab4A9FfE4F35bdf329909",
    id: "385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf",
    float: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    floatDecimals: 6,
    quoter: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
    fees: [100, 500, 3000, 10000],
    wnative: "0x4200000000000000000000000000000000000006",
    wnativeFee: 3000,
    wormhole: 24,
    bridge: "0x1D68124e65faFC907325e3EDbF8c4d84499DAa8b",
    cctp: 2,
  },
  avalanche: {
    viem: avalanche,
    upstream: process.env.AVALANCHE_RPC_URL ?? "https://avalanche.gateway.tenderly.co",
    symbol: "AVAX",
    home: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7",
    copy: "0x85f138bfEE4ef8e540890CFb48F620571d67Eda3",
    id: "93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7",
    float: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    floatDecimals: 6,
    quoter: "0xbe0F5544EC67e9B3b2D979aaA43f18Fd87E6257F",
    fees: [100, 500, 3000, 10000],
    wnative: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7",
    wnativeFee: 500,
    wormhole: 6,
    bridge: "0x0e082F06FF657D94310cB8cE8B0D9a04541d8052",
    cctp: 1,
  },
};
const CHAINS_RUN = (process.env.RESTOCK_E2E_CHAINS ?? "bsc,base,optimism,avalanche").split(",").map((s) => s.trim());

const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
  "function allowance(address, address) view returns (uint256)",
]);
const bridgeAbi = parseAbi(["function wormhole() view returns (address)"]);
const core = parseAbi([
  "function getCurrentGuardianSetIndex() view returns (uint32)",
  "event LogMessagePublished(address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel)",
]);
const transmitter = parseAbi([
  "function attesterManager() view returns (address)",
  "function enableAttester(address)",
  "function setSignatureThreshold(uint256)",
  "event MessageSent(bytes message)",
]);
const quoter = parseAbi([
  "function quoteExactInput(bytes path, uint256 amountIn) returns (uint256, uint160[], uint32[], uint256)",
  "function quoteExactOutput(bytes path, uint256 amountOut) returns (uint256, uint160[], uint32[], uint256)",
]);
const executorAbi = json(`${KEEPER_DIR}out/KeeperExecutor.sol/KeeperExecutor.json`).abi;

let passed = 0;
let failed = 0;
function ok(condition, what) {
  if (condition) passed++;
  else failed++;
  console.log(`  ${condition ? "PASS" : "FAIL"} ${what}`);
}
const step = (s) => console.log(`\n== ${s}`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const key = (name) => keccak256(toHex(`xindex-restock-e2e-${name}`));
const u = (v, bytes) => pad(numberToHex(BigInt.asUintN(bytes * 8, BigInt(v))), { size: bytes });
const path = (...h) => `0x${h.map((x, i) => (i % 2 ? x.toString(16).padStart(6, "0") : x.slice(2).toLowerCase())).join("")}`;
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

let nextPort = 8655;
/// An anvil fork of `upstream` near its head, with the clients this test drives it through.
async function fork(upstream, viemChain) {
  const port = nextPort++;
  const head = await createPublicClient({ transport: transport(upstream) }).getBlockNumber();
  const forkBlock = head - 8n;
  const anvil = spawn("anvil", ["--fork-url", upstream, "--fork-block-number", String(forkBlock), "--port", String(port), "--auto-impersonate", "--silent"], {
    stdio: ["ignore", "inherit", "inherit"],
  });
  children.push(anvil);
  const rpc = `http://127.0.0.1:${port}`;
  const chain = { ...viemChain, rpcUrls: { default: { http: [rpc] } } };
  const pub = createPublicClient({ chain, transport: transport(rpc, { timeout: 600_000 }), pollingInterval: 500 });
  for (let i = 0; ; i++) {
    try {
      await pub.getChainId();
      break;
    } catch {
      if (i > 120) throw new Error(`anvil on ${port} did not start`);
      await sleep(500);
    }
  }
  const test = createTestClient({ chain, mode: "anvil", transport: transport(rpc, { timeout: 600_000 }) });
  const wallet = createWalletClient({ chain, transport: transport(rpc, { timeout: 600_000 }) });
  return { rpc, chain, pub, test, wallet, forkBlock, anvil };
}
const read = (f, address, abi, functionName, args = []) => f.pub.readContract({ address, abi, functionName, args });
async function send(f, from, address, abi, functionName, args = []) {
  const hash = await f.wallet.writeContract({ account: from, address, abi, functionName, args, chain: f.chain });
  const receipt = await f.pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted (${hash})`);
  return receipt;
}
async function deploy(f, from, artifact, args) {
  const hash = await f.wallet.deployContract({ account: from, abi: artifact.abi, bytecode: artifact.bytecode.object, args, chain: f.chain });
  return (await f.pub.waitForTransactionReceipt({ hash })).contractAddress;
}

const guardian = key("guardian");
const attester = key("attester");
/// One test key as the fork's Wormhole core's whole current guardian set (its `guardianSets` mapping sits at slot 2),
/// and one test attester, with a threshold of one, on its CCTP message transmitter when it has one.
async function installSigners(f, coreAddress, cctp) {
  const index = await read(f, coreAddress, core, "getCurrentGuardianSetIndex");
  const set = keccak256(concat([u(index, 32), u(2, 32)]));
  await f.test.setStorageAt({ address: coreAddress, index: set, value: u(1, 32) });
  await f.test.setStorageAt({ address: coreAddress, index: keccak256(set), value: pad(privateKeyToAccount(guardian).address, { size: 32 }) });
  f.core = coreAddress;
  f.guardianIndex = index;
  if (cctp) {
    const manager = await read(f, MT, transmitter, "attesterManager");
    await f.test.setBalance({ address: manager, value: E18 });
    await send(f, manager, MT, transmitter, "enableAttester", [privateKeyToAccount(attester).address]);
    await send(f, manager, MT, transmitter, "setSignatureThreshold", [1n]);
  }
}

step("Ethereum fork and executor");
const eth = await fork(UPSTREAM, mainnet);
await installSigners(eth, await read(eth, ETH_BRIDGE, bridgeAbi, "wormhole"), true);
const deployer = privateKeyToAccount(key("deployer")).address;
const execOwner = privateKeyToAccount(key("owner")).address;
const treasury = privateKeyToAccount(key("treasury"));
for (const a of [deployer, execOwner, treasury.address]) await eth.test.setBalance({ address: a, value: 10n ** 21n });
const factory = await deploy(eth, deployer, json(`${ROOT}out/WeightedIndexFactory.sol/WeightedIndexFactory.json`), [
  execOwner,
  deployer,
  "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
]);
const requests = await deploy(eth, deployer, json(`${ROOT}out/MintRequests.sol/MintRequests.json`), [factory, ETH_USDC, "0xdAC17F958D2ee523a2206206994597C13D831ec7"]);
const executor = await deploy(eth, deployer, json(`${KEEPER_DIR}out/KeeperExecutor.sol/KeeperExecutor.json`), [
  "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
  ETH_USDC,
  factory,
  requests,
  ETH_BRIDGE,
  execOwner,
  privateKeyToAccount(key("keeper")).address,
]);
await send(eth, execOwner, executor, executorAbi, "setTreasury", [treasury.address]);
await send(eth, execOwner, executor, executorAbi, "setTreasuryUsdcAllowance", [100_000n * 10n ** 6n]);
for (const h of Object.values(HOMES)) await send(eth, execOwner, executor, executorAbi, "setHomeRecipient", [h.wormhole, pad(treasury.address, { size: 32 })]);
// RS-1: the restocking the owner allows of each coin, ample here; every arrival spends what it earns.
const RESTOCK_GRANT = 10n ** 30n;
for (const h of Object.values(HOMES)) await send(eth, execOwner, executor, executorAbi, "setRestockAllowance", [h.copy, RESTOCK_GRANT]);
await eth.test.request({ method: "anvil_dealERC20", params: [executor, ETH_USDC, numberToHex(200_000n * 10n ** 6n)] });
console.log(`  forked at ${eth.forkBlock}; executor ${executor}, treasury ${treasury.address}`);

// ---------------------------------------------------------------------
// Fake Hermes, Wormholescan and Iris
// ---------------------------------------------------------------------

const forks = { 2: eth }; // Wormhole chain id -> fork
const byDomain = { 0: eth }; // CCTP domain -> fork
const prices = new Map(); // Pyth id -> USD

function serve(port, handler) {
  servers.push(
    http
      .createServer(async (req, res) => {
        try {
          const [status, body] = await handler(new URL(req.url, "http://x"), req);
          res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
        } catch (error) {
          res.writeHead(500).end(String(error.message));
        }
      })
      .listen(port),
  );
}

serve(HERMES_PORT, async (url, req) => {
  if (req.headers.authorization !== "Bearer e2e") return [401, { error: "no key" }];
  const parsed = url.searchParams
    .getAll("ids[]")
    .map((id) => id.replace(/^0x/, "").toLowerCase())
    .filter((id) => prices.has(id))
    .map((id) => {
      const price = BigInt(Math.round(prices.get(id) * 1e8));
      const at = { price: String(price), conf: String(price / 2000n), expo: -8, publish_time: Math.floor(Date.now() / 1000) };
      return { id, price: at, ema_price: at };
    });
  return [200, { parsed, binary: { encoding: "hex", data: [] } }];
});

/// The VAA the guardians would sign for what `emitter` published as `sequence` on Wormhole chain `chain`, for the
/// other side's core: a home chain's message goes to Ethereum, an Ethereum message to the home chain its transfer names.
serve(SCAN_PORT, async (url) => {
  const m = url.pathname.match(/^\/api\/v1\/vaas\/(\d+)\/([0-9a-f]{64})\/(\d+)$/);
  if (!m) return [404, { error: "no route" }];
  const [, chainId, emitterHex, sequence] = m;
  const from = forks[chainId];
  const emitter = `0x${emitterHex.slice(24)}`;
  const logs = await from.pub.getLogs({ address: from.core, event: core[1], fromBlock: from.forkBlock + 1n });
  const log = logs.find((l) => l.args.sender.toLowerCase() === emitter && l.args.sequence === BigInt(sequence));
  if (!log) return [404, { error: "not found" }];
  // A transfer's payload: its id, amount, token address, token chain and recipient (1 + 32 + 32 + 2 + 32 bytes), then
  // the recipient's chain.
  const toChain = Number(BigInt(`0x${log.args.payload.slice(2 + 2 * 99, 2 + 2 * 101)}`));
  const verifier = chainId === "2" ? forks[toChain] : eth;
  const block = await from.pub.getBlock({ blockNumber: log.blockNumber });
  const body = concat([
    u(block.timestamp, 4),
    u(log.args.nonce, 4),
    u(chainId, 2),
    pad(emitter, { size: 32 }),
    u(log.args.sequence, 8),
    u(log.args.consistencyLevel, 1),
    log.args.payload,
  ]);
  const sig = await sign({ hash: keccak256(keccak256(body)), privateKey: guardian });
  const vaa = concat([u(1, 1), u(verifier.guardianIndex, 4), u(1, 1), u(0, 1), sig.r, sig.s, u(Number(sig.yParity), 1), body]);
  return [200, { data: { vaa: Buffer.from(vaa.slice(2), "hex").toString("base64") } }];
});

/// Circle's attestation of the CCTP burn in transaction `transactionHash` on domain `domain`: the message as emitted,
/// with the nonce, finality executed, fee executed and expiry Iris fills, signed by the test attester.
serve(IRIS_PORT, async (url) => {
  const m = url.pathname.match(/^\/v2\/messages\/(\d+)$/);
  const hash = url.searchParams.get("transactionHash");
  const from = m && byDomain[m[1]];
  if (!from || !hash) return [404, { error: "not found" }];
  const receipt = await from.pub.getTransactionReceipt({ hash }).catch(() => null);
  const log = receipt?.logs.find((l) => l.address.toLowerCase() === MT.toLowerCase());
  if (!log) return [404, { error: "not found" }];
  const emitted = decodeEventLog({ abi: transmitter, data: log.data, topics: log.topics }).args.message.slice(2);
  // The header: version and both domains (24 hex), the nonce (64), sender, recipient, destination caller and minimum
  // finality (200), then the finality executed (8); the burn message after it: its version, token, recipient, amount,
  // sender and maximum fee (8 + 64 * 5), then the fee executed and the expiry (64 each), then any hook data.
  const header = `${emitted.slice(0, 24)}${keccak256(hash).slice(2)}${emitted.slice(88, 288)}${u(2000, 4).slice(2)}`;
  const burn = emitted.slice(296);
  const filled = `${burn.slice(0, 8 + 64 * 5)}${u(0, 32).slice(2)}${u(0, 32).slice(2)}${burn.slice(8 + 64 * 7)}`;
  const message = `0x${header}${filled}`;
  const sig = await sign({ hash: keccak256(message), privateKey: attester });
  const attestation = concat([sig.r, sig.s, u(Number(sig.yParity) + 27, 1)]);
  return [200, { messages: [{ status: "complete", message, attestation }] }];
});

// ---------------------------------------------------------------------
// The service, round by round
// ---------------------------------------------------------------------

const run = promisify(execFile);
const dir = mkdtempSync(join(tmpdir(), "restock-e2e-"));
const needsFile = join(dir, "needs.json");
const needs = createNeeds({ write: (text) => writeFileSync(needsFile, text) });
let env;
/// One round of the service, as its own process; asynchronous, so this process's fake services answer it.
async function round(label) {
  needs.flush(); // the keeper writes its board every block; a board it stopped writing is unknown (RS-8)
  const { stdout: out } = await run("node", [`${KEEPER_DIR}restock.mjs`, "--once"], { env, cwd: KEEPER_DIR });
  for (const line of out.trim().split("\n").filter(Boolean)) console.log(`  [${label}] ${line.replace(/^\S+ /, "")}`);
  return out;
}
/// Rounds until their output matches `pattern`, at most `max`; returns everything they printed.
async function until(label, pattern, max = 4) {
  let all = "";
  for (let i = 1; i <= max; i++) {
    all += await round(`${label}.${i}`);
    if (pattern.test(all)) break;
  }
  return all;
}

/// The best quote of `amount` of the chain's coin into its float along a direct or a two-hop path; reading every
/// candidate also warms the pools the service's route search will read.
async function bestQuote(h, f, functionName, amount) {
  let best = null;
  for (const fee of h.fees) {
    const paths = [path(h.home, fee, h.float)];
    if (h.home.toLowerCase() !== h.wnative.toLowerCase()) paths.push(path(h.home, fee, h.wnative, h.wnativeFee, h.float));
    for (const p of paths) {
      const r = await f.pub.simulateContract({ address: h.quoter, abi: quoter, functionName, args: [p, amount] }).catch(() => null);
      if (!r) continue;
      const q = r.result[0];
      if (best === null || (functionName === "quoteExactInput" ? q > best : q < best)) best = q;
    }
  }
  return best;
}

for (const name of CHAINS_RUN) {
  const h = HOMES[name];
  step(`${name}: ${h.symbol}`);
  const f = await fork(h.upstream, h.viem);
  forks[h.wormhole] = f;
  if (h.cctp !== null) byDomain[h.cctp] = f;
  await installSigners(f, await read(f, h.bridge, bridgeAbi, "wormhole"), h.cctp !== null);
  await f.test.setBalance({ address: treasury.address, value: 10n ** 20n });
  if (h.cctp === null) {
    await f.test.request({ method: "anvil_dealERC20", params: [treasury.address, h.float, numberToHex(10_000n * 10n ** BigInt(h.floatDecimals))] });
  }
  const usd = units(await bestQuote(h, f, "quoteExactInput", E18), h.floatDecimals);
  prices.set(h.id, usd);
  const need = BigInt(Math.floor((1_300 / usd) * 1e18));
  console.log(`  forked at ${f.forkBlock}; ${h.symbol} at ${usd.toFixed(4)} on its pools; a need of ${units(need, 18).toFixed(2)}`);
  for (const amount of [(need * 11n) / 10n, need]) {
    await bestQuote(h, f, "quoteExactOutput", amount);
    await bestQuote(h, f, "quoteExactInput", amount);
  }

  env = {
    ...process.env,
    RPC_URL: eth.rpc,
    [`${name === "bsc" ? "BSC" : name.toUpperCase()}_RPC_URL`]: f.rpc,
    EXECUTOR: executor,
    TREASURY_KEY: key("treasury"),
    PYTH_API_KEY: "e2e",
    HERMES_URL: `http://127.0.0.1:${HERMES_PORT}`,
    WORMHOLESCAN_URL: `http://127.0.0.1:${SCAN_PORT}`,
    IRIS_URL: `http://127.0.0.1:${IRIS_PORT}`,
    NEEDS_FILE: needsFile,
    JOURNAL_FILE: join(dir, `journal-${name}.json`),
    RESTOCK_COINS: h.symbol,
    RESTOCK_KEEP_USD: "300",
    RESTOCK_FLOAT_TARGET_USD: "500",
    RESTOCK_TREASURY_TARGET_USD: "500",
  };
  const coin = () => read(f, h.home, erc20, "balanceOf", [treasury.address]);
  const stock = () => read(eth, h.copy, erc20, "balanceOf", [executor]);
  const allowance = () => read(eth, executor, executorAbi, "stockAllowance", [h.copy]);
  const restockLeft = () => read(eth, executor, executorAbi, "restockAllowance", [h.copy]);
  const homeFloat = () => read(f, h.float, erc20, "balanceOf", [treasury.address]);
  const treasuryUsdc = () => read(eth, ETH_USDC, erc20, "balanceOf", [treasury.address]);

  needs.report(`${name}:1`, "fill", [{ token: h.copy, amount: need }]);
  needs.flush();
  if (h.cctp !== null) {
    ok((await homeFloat()) === 0n, `the ${name} wallet starts with no float`);
    const funded = await until(`${name} fund`, /bought \d+ USD/);
    ok(/drew [\d.]+ USDC from the executor/.test(funded), "the treasury draws USDC from the executor");
    ok(/funding its float with [\d.]+ USDC/.test(funded), `and funds ${name} by CCTP`);
    ok(/fund of [\d.]+ USDC landed on/.test(funded), `the CCTP message is received on ${name}`);
    ok(/bought \d+ USD on/.test(funded), "and the buy follows");
  } else {
    ok(/bought \d+ USD on/.test(await round(`${name} buy`)), `the service buys ${h.symbol} on ${name}`);
  }
  const bought = await coin();
  ok(bought >= (need * 11n) / 10n, `the home wallet holds ${units(bought, 18).toFixed(2)} ${h.symbol}: the need and its 10% buffer`);
  const landed = await until(`${name} in`, /bridgeIn of \w+ landed/, 3);
  ok(/bridging \d+ USD in from/.test(landed), "it bridges the coin in");
  ok(/bridgeIn of \w+ landed/.test(landed), "and redeems the signed transfer into the executor");
  const held = await stock();
  ok(held >= (need * 11n) / 10n - 10n ** 10n && held <= bought, `the executor holds ${units(held, 18).toFixed(2)} ${h.symbol}`);
  ok((await allowance()) === held, "and may deliver exactly what arrived");
  ok((await restockLeft()) === RESTOCK_GRANT - held, "which spent the owner's restock allowance by as much (RS-1)");

  needs.report(`${name}:1`, "fill", []);
  needs.flush();
  const out = await until(`${name} out`, /sold \d+ USD on/);
  ok(/bridging \d+ USD out to/.test(out), "with no need left, the spare stock is bridged out");
  const left = await stock();
  ok(Math.abs(units(left, 18) * usd - 300) < 2, `${units(left, 18).toFixed(2)} ${h.symbol} stays: the $300 keep`);
  ok((await allowance()) === left, "the allowance capped at what is left");
  ok(/bridgeOut of \w+ landed/.test(out), `the transfer completes on ${name}`);
  ok(/sold \d+ USD on/.test(out), "and the coins that came home are sold");
  ok((await coin()) < 10n ** 15n, "none left in the home wallet");

  if (h.cctp !== null) {
    const back = await until(`${name} sweep`, /repaid [\d.]+ USDC/);
    ok(/bringing [\d.]+ USDC home to the treasury/.test(back), `the idle float on ${name} goes back by CCTP`);
    ok(/sweep of [\d.]+ USDC landed on ethereum/.test(back), "and is received on Ethereum");
    ok(/repaid [\d.]+ USDC to the executor/.test(back), "and the treasury repays the executor beyond its target");
    ok((await treasuryUsdc()) <= 1_000n * 10n ** 6n, "keeping no more than twice its target");
    ok(
      (await read(eth, executor, executorAbi, "treasuryUsdcAllowance")) <= 100_000n * 10n ** 6n,
      "and repaying raised nothing above the owner's cap (RS-2)",
    );
  }

  // Every approval was for what its call took (RS-12): none stands beyond what a buy left of its bound.
  const allowed = (fork, token, spender) => read(fork, token, erc20, "allowance", [treasury.address, spender]);
  const venue = EVM_CHAINS[name];
  ok((await allowed(f, h.home, venue.router)) === 0n && (await allowed(f, h.home, venue.tokenBridge)) === 0n,
    `no ${h.symbol} allowance left to the router or the bridge (RS-12)`);
  ok((await allowed(f, h.float, venue.router)) < 2_000n * 10n ** BigInt(h.floatDecimals), "and the float's to the router within a buy's slack");
  if (h.cctp !== null) {
    const cctpLeft = (await allowed(f, h.float, MESSENGER)) + (await allowed(eth, ETH_USDC, MESSENGER));
    ok(cctpLeft === 0n && (await allowed(eth, ETH_USDC, executor)) === 0n, "no USDC allowance left to CCTP or the executor");
  }
}

// ---------------------------------------------------------------------
// A restart: a move signed but never broadcast is broadcast again; one whose nonce went elsewhere is dropped
// ---------------------------------------------------------------------

step("restart: a move signed and recorded but never broadcast");
const journalFile = env.JOURNAL_FILE;
async function signedDraw(amount, nonce) {
  const request = await eth.pub.prepareTransactionRequest({
    account: treasury,
    to: executor,
    data: encodeFunctionData({ abi: executorAbi, functionName: "drawUsdc", args: [amount] }),
    nonce,
    chain: eth.chain,
  });
  const raw = await treasury.signTransaction(request);
  return { raw, hash: keccak256(raw), nonce };
}
/// Writes a draw into the journal as the service would just before broadcasting it, as if it had stopped there.
function inject(data) {
  const j = json(journalFile);
  const id = String(j.next++);
  const t = Math.floor(Date.now() / 1000);
  j.moves[id] = { id, kind: "draw", coin: null, copy: null, chain: null, amount: "1000000", usd: null, stage: "signed", data: { chain: "ethereum", ...data }, at: t, updatedAt: t };
  writeFileSync(journalFile, JSON.stringify(j));
  return id;
}
const unsent = inject(await signedDraw(10n ** 6n, await eth.pub.getTransactionCount({ address: treasury.address })));
const usdcBefore = await read(eth, ETH_USDC, erc20, "balanceOf", [treasury.address]);
await round("resume.1");
await round("resume.2");
ok(json(journalFile).moves[unsent].stage === "done", "the next rounds broadcast the very transaction recorded, and settle it");
ok((await read(eth, ETH_USDC, erc20, "balanceOf", [treasury.address])) - usdcBefore === 10n ** 6n, "and the draw it signed happened once");

step("restart: a move whose nonce another transaction took");
const orphan = inject(await signedDraw(2n * 10n ** 6n, await eth.pub.getTransactionCount({ address: treasury.address })));
await send(eth, treasury.address, ETH_USDC, erc20, "approve", [executor, 0n]); // another transaction at that nonce
await round("orphan.1");
ok(json(journalFile).moves[orphan].stage === "signed", "a first look keeps it: a node behind may not have its receipt yet (RS-5)");
await new Promise((r) => setTimeout(r, (ORPHAN_SECONDS + 1) * 1000));
await round("orphan.2");
ok(json(journalFile).moves[orphan].stage === "dropped", "the move is dropped, never broadcast in a second form");

console.log(`\n${passed} passed, ${failed} failed`);
shutdown(failed === 0 ? 0 : 1);
