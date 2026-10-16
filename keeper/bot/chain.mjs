// The keeper's view of Ethereum, through viem: pinned reads, calls with state and block overrides, revert names,
// and signed sends. ABIs come from the repo's committed `abi/` and from the executor's own build (`keeper/out`).

import { readFileSync } from "node:fs";
import {
  createPublicClient,
  decodeErrorResult,
  decodeFunctionResult,
  encodeFunctionData,
  http,
  keccak256,
  numberToHex,
  pad,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { HUB_SLOTS, MAINNET } from "./config.mjs";

const load = (path) => JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8"));

function executorAbi() {
  try {
    return load("../out/KeeperExecutor.sol/KeeperExecutor.json").abi;
  } catch {
    throw new Error("keeper/out has no KeeperExecutor build: run `forge build --root keeper` first");
  }
}

export const ABI = {
  hub: load("../../abi/WeightedHub.json"),
  factory: load("../../abi/WeightedIndexFactory.json"),
  requests: load("../../abi/MintRequests.json"),
  executor: executorAbi(),
  erc20: parseAbi(["function balanceOf(address) view returns (uint256)", "function symbol() view returns (string)"]),
  quoter: parseAbi([
    "function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[], uint32[], uint256)",
    "function quoteExactOutput(bytes path, uint256 amountOut) returns (uint256 amountIn, uint160[], uint32[], uint256)",
  ]),
  v3Factory: parseAbi(["function getPool(address, address, uint24) view returns (address)"]),
  pyth: parseAbi([
    "function getUpdateFee(bytes[] updateData) view returns (uint256)",
    "error InsufficientFee()",
    "error InvalidUpdateData()",
    "error InvalidUpdateDataSource()",
    "error InvalidWormholeVaa()",
    "error PriceFeedNotFoundWithinRange()",
    "error PriceFeedNotFound()",
  ]),
};
const ERRORS = [...ABI.hub, ...ABI.factory, ...ABI.requests, ...ABI.executor, ...ABI.pyth].filter((x) => x.type === "error");

/// The revert data inside a viem error, if any.
function revertData(error) {
  for (let e = error; e; e = e.cause) {
    for (const d of [e.data, e.data?.data, e.raw]) if (typeof d === "string" && /^0x[0-9a-fA-F]*$/.test(d)) return d;
  }
  return null;
}

/// A readable name for why a call reverted: the decoded custom error, the raw selector, or the node's message.
export function revertReason(error) {
  const data = revertData(error);
  if (data && data.length >= 10) {
    try {
      const d = decodeErrorResult({ abi: ERRORS, data });
      return d.args?.length ? `${d.errorName}(${d.args.map(String).join(", ")})` : d.errorName;
    } catch {
      return `revert ${data.slice(0, 10)}`;
    }
  }
  return String(error?.shortMessage ?? error?.details ?? error?.message ?? error).split("\n")[0];
}

const hex = (x) => numberToHex(x);
const word = (x) => pad(numberToHex(x), { size: 32 });

export function createChain(cfg) {
  const client = createPublicClient({ chain: mainnet, transport: http(cfg.rpcUrl, { timeout: 15_000, retryCount: 2 }) });
  const account = privateKeyToAccount(cfg.keeperKey);

  const read = (address, abi, functionName, args, blockNumber) =>
    client.readContract({ address, abi, functionName, args, blockNumber });

  const multicall = (contracts, blockNumber) => client.multicall({ contracts, blockNumber, allowFailure: true });

  /// A call at `blockNumber` with optional overrides: `state` maps an address to `{slot: value}` (stateDiff), and
  /// `block` = {number, time} runs it as if in that block. Returns the decoded outputs of `functionName`.
  async function call({ to, abi, functionName, args, value = 0n, from = account.address }, blockNumber, over = {}) {
    const data = encodeFunctionData({ abi, functionName, args });
    const state = {};
    for (const [address, slots] of Object.entries(over.state ?? {})) {
      state[address] = { stateDiff: Object.fromEntries(Object.entries(slots).map(([s, v]) => [word(BigInt(s)), word(v)])) };
    }
    const block = over.block ? { number: hex(over.block.number), time: hex(over.block.time) } : {};
    const result = await client.request({
      method: "eth_call",
      params: [{ from, to, data, value: hex(value) }, hex(blockNumber), state, block],
    });
    return decodeFunctionResult({ abi, functionName, data: result });
  }

  /// Signs and broadcasts `tx` (see TxTracker), returning its hash. A node that already holds it reports the hash.
  async function send(tx) {
    const serialized = await account.signTransaction({
      chainId: MAINNET.chainId,
      type: "eip1559",
      nonce: Number(tx.nonce),
      to: tx.to,
      data: tx.data,
      value: tx.value,
      gas: tx.gas,
      maxFeePerGas: tx.maxFeePerGas,
      maxPriorityFeePerGas: tx.maxPriorityFeePerGas,
    });
    const hash = keccak256(serialized);
    try {
      await client.request({ method: "eth_sendRawTransaction", params: [serialized] });
    } catch (error) {
      const message = String(error?.details ?? error?.message ?? error);
      throw Object.assign(new Error(message), { hash });
    }
    return hash;
  }

  const txIo = {
    address: account.address,
    latestNonce: async () => BigInt(await client.getTransactionCount({ address: account.address, blockTag: "latest" })),
    pendingNonce: async () => BigInt(await client.getTransactionCount({ address: account.address, blockTag: "pending" })),
    receipt: async (hash) => {
      try {
        return await client.getTransactionReceipt({ hash });
      } catch {
        return null;
      }
    },
    send,
  };

  /// Refuses to run against anything but the deployment and RPC this keeper is built for.
  async function checkSetup() {
    const chainId = await client.getChainId();
    if (chainId !== MAINNET.chainId) throw new Error(`chain ${chainId} is not Ethereum`);
    const at = await client.getBlockNumber();
    const ex = (fn) => read(cfg.executor, ABI.executor, fn, [], at);
    const [keeper, router, usdc, factory, requests] =
      await Promise.all([ex("keeper"), ex("ROUTER"), ex("USDC"), ex("FACTORY"), ex("REQUESTS")]);
    const same = (a, b) => a.toLowerCase() === b.toLowerCase();
    if (!same(keeper, account.address)) throw new Error(`the executor's keeper is ${keeper}, not this bot's ${account.address}`);
    if (!same(router, MAINNET.swapRouter02)) throw new Error(`the executor routes through ${router}, not SwapRouter02`);
    if (!same(usdc, MAINNET.usdc)) throw new Error(`the executor's float is ${usdc}, not USDC`);
    if (!same(factory, cfg.factory)) throw new Error(`the executor fills ${factory}'s indexes, not FACTORY's`);
    const requestsFactory = await read(requests, ABI.requests, "FACTORY", [], at);
    if (!same(requestsFactory, factory)) throw new Error(`the executor's request escrow ${requests} is on another factory`);

    const implementation = await read(cfg.factory, ABI.factory, "IMPLEMENTATION", [], at);
    const pyth = await read(cfg.factory, ABI.factory, "PYTH", [], at);
    const duration = await read(implementation, ABI.hub, "AUCTION_DURATION", [], at);
    const block = await client.getBlock({ blockNumber: at });
    const time = block.timestamp + 1000n;
    const priceTime = await call({ to: implementation, abi: ABI.hub, functionName: "priceTime", args: [] }, at, {
      block: { number: at + 1n, time },
    });
    if (priceTime !== time - 12n) throw new Error("the RPC ignores eth_call block overrides: the keeper needs them");
    const [eta, keepMask] = await call({ to: implementation, abi: ABI.hub, functionName: "pendingRebalance", args: [] }, at, {
      state: { [implementation]: { [HUB_SLOTS.eta]: 1234n, [HUB_SLOTS.keepMask]: 5n } },
    });
    if (eta !== 1234n || keepMask !== 5n) throw new Error("WeightedHub's storage layout is not the one the keeper knows");
    return { implementation, pyth, duration, requests };
  }

  return {
    client,
    account,
    read,
    multicall,
    call,
    txIo,
    checkSetup,
    blockNumber: () => client.getBlockNumber({ cacheTime: 0 }),
    block: (blockNumber) => client.getBlock({ blockNumber }),
  };
}
