// The restock service's EVM chains: Ethereum, where the treasury redeems into the executor, bridges stock out and
// moves USDC, and BNB Chain, Avalanche, Optimism and Base, home to eight of the coins. viem only. A move's first
// transaction, the one that commits funds, is signed, recorded in the journal, and only then broadcast, so a restart
// broadcasts the same bytes again rather than signing a second transaction; the transactions that complete a move
// (redeeming a transfer, receiving a CCTP message) are each counted once by the contract they call, so they are simply
// sent again until that contract says it is done.

import { createPublicClient, createWalletClient, decodeEventLog, encodeFunctionData, http, keccak256, pad, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { avalanche, base, bsc, mainnet, optimism } from "viem/chains";
import { MAINNET } from "../bot/config.mjs";
import { ABI as KEEPER_ABI, isRevert, revertReason } from "../bot/chain.mjs";
import { sequenceIn } from "./attestations.mjs";
import { allowExactly, noPendingTransaction, resumeMove, settleCommit, withFeeHeadroom } from "./sending.mjs";

const TOKEN_MESSENGER_V2 = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d";
const MESSAGE_TRANSMITTER_V2 = "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64";
/// CCTP V2's finality for a standard transfer: the source chain's own finality, and no fee.
const STANDARD_FINALITY = 2000;

/// Each chain's Wormhole Token Bridge, CCTP domain, and, on a home chain, the Uniswap V3 fork its coins trade on, in
/// the route search's terms (`bot/routes.mjs`): its float as "usdc", its wrapped gas coin as "weth". Every address was
/// read on its chain on 2026-10-19: each bridge's chain id and its registered Ethereum peer, each quoter's and router's
/// factory, each token's symbol and decimals, and each CCTP contract's domain and the USDC it mints.
export const EVM_CHAINS = Object.freeze({
  ethereum: { viem: mainnet, wormhole: 2, tokenBridge: MAINNET.tokenBridge, cctpDomain: 0, usdc: MAINNET.usdc },
  bsc: {
    viem: bsc,
    wormhole: 4,
    tokenBridge: "0xB6F6D86a8f9879A9c87f643768d9efc38c1Da6E7",
    cctpDomain: null,
    // PancakeSwap v3, whose SmartRouter takes SwapRouter02's exact-input and exact-output calls.
    router: "0x13f4EA83D0bd40E75C8222255bc855a974568Dd4",
    market: {
      usdc: "0x55d398326f99059fF775485246999027B3197955",
      usdcDecimals: 18,
      weth: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
      v3Factory: "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865",
      quoterV2: "0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997",
      directFees: [100, 500, 2500, 10000],
      viaWethFees: [100, 500, 2500, 10000],
      wethUsdcFee: 100,
    },
  },
  avalanche: {
    viem: avalanche,
    wormhole: 6,
    tokenBridge: "0x0e082F06FF657D94310cB8cE8B0D9a04541d8052",
    cctpDomain: 1,
    router: "0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE",
    market: {
      usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
      usdcDecimals: 6,
      weth: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7",
      v3Factory: "0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD",
      quoterV2: "0xbe0F5544EC67e9B3b2D979aaA43f18Fd87E6257F",
      directFees: [100, 500, 3000, 10000],
      viaWethFees: [500, 3000, 10000],
      wethUsdcFee: 500,
    },
  },
  optimism: {
    viem: optimism,
    wormhole: 24,
    tokenBridge: "0x1D68124e65faFC907325e3EDbF8c4d84499DAa8b",
    cctpDomain: 2,
    router: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
    market: {
      usdc: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
      usdcDecimals: 6,
      weth: "0x4200000000000000000000000000000000000006",
      v3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
      quoterV2: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
      directFees: [100, 500, 3000, 10000],
      viaWethFees: [500, 3000, 10000],
      wethUsdcFee: 3000,
    },
  },
  base: {
    viem: base,
    wormhole: 30,
    tokenBridge: "0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627",
    cctpDomain: 6,
    router: "0x2626664c2603336E57B271c5C0b26F421741e481",
    market: {
      usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      usdcDecimals: 6,
      weth: "0x4200000000000000000000000000000000000006",
      v3Factory: "0x33128a8fC17869897dcE68Ed026d694621f6FDfD",
      quoterV2: "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a",
      directFees: [100, 500, 3000, 10000],
      viaWethFees: [500, 3000, 10000],
      wethUsdcFee: 500,
    },
  },
});

export const ABI = Object.freeze({
  ...KEEPER_ABI,
  erc20: parseAbi([
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address, address) view returns (uint256)",
    "function approve(address, uint256) returns (bool)",
  ]),
  tokenBridge: parseAbi([
    "function wormhole() view returns (address)",
    "function transferTokensWithPayload(address token, uint256 amount, uint16 recipientChain, bytes32 recipient, uint32 nonce, bytes payload) payable returns (uint64)",
    "function completeTransfer(bytes encodedVm)",
    "function isTransferCompleted(bytes32 hash) view returns (bool)",
  ]),
  core: parseAbi([
    "function messageFee() view returns (uint256)",
    "function parseAndVerifyVM(bytes encodedVM) view returns ((uint8 version, uint32 timestamp, uint32 nonce, uint16 emitterChainId, bytes32 emitterAddress, uint64 sequence, uint8 consistencyLevel, bytes payload, uint32 guardianSetIndex, (bytes32 r, bytes32 s, uint8 v, uint8 guardianIndex)[] signatures, bytes32 hash) vm, bool valid, string reason)",
    "event LogMessagePublished(address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel)",
  ]),
  router: parseAbi([
    "function exactInput((bytes path, address recipient, uint256 amountIn, uint256 amountOutMinimum)) payable returns (uint256)",
    "function exactOutput((bytes path, address recipient, uint256 amountOut, uint256 amountInMaximum)) payable returns (uint256)",
  ]),
  tokenMessenger: parseAbi([
    "function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken, bytes32 destinationCaller, uint256 maxFee, uint32 minFinalityThreshold)",
  ]),
  messageTransmitter: parseAbi([
    "function receiveMessage(bytes message, bytes attestation) returns (bool)",
    "function usedNonces(bytes32 nonce) view returns (uint256)",
  ]),
});

/// A signed transfer's hash, as the Token Bridge records a completed one: the double keccak of its body, which starts
/// after the header and the signatures.
export function vaaHash(vaa) {
  const bytes = Buffer.from(vaa.slice(2), "hex");
  const body = bytes.subarray(6 + 66 * bytes[5]);
  return keccak256(keccak256(body));
}

/// A CCTP V2 message's nonce: 32 bytes after its version and its two domains.
export const cctpNonce = (message) => `0x${message.slice(2 + 24, 2 + 24 + 64)}`;

/// An EVM address as Wormhole and CCTP encode a recipient: left-padded to 32 bytes.
export const word = (address) => pad(address, { size: 32 });

/// The restock service's wallet on EVM chain `name` (a key of `EVM_CHAINS`), with `key`, over `rpcUrl`.
export function createEvm({ name, rpcUrl, key, journal }) {
  const def = EVM_CHAINS[name];
  const chain = withFeeHeadroom(def.viem);
  const transport = http(rpcUrl, { timeout: 60_000, retryCount: 2 });
  const client = createPublicClient({ chain, transport });
  const account = privateKeyToAccount(key);
  const wallet = createWalletClient({ account, chain, transport });
  const idle = () => noPendingTransaction({ client, address: account.address, name });
  let core = null; // the Wormhole core the chain's Token Bridge publishes through, read once
  const coreAddress = async () => (core ??= await read(def.tokenBridge, ABI.tokenBridge, "wormhole"));
  const read = (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args });
  const tx = ({ to, abi, functionName, args, value = 0n }) => ({ to, data: encodeFunctionData({ abi, functionName, args }), value });

  /// Signs `request`, records it as move `action` in the journal, broadcasts it and waits for it to be mined, then
  /// moves the move to "sent" (`sending.mjs` settleCommit). Returns the move's id and the receipt; a receipt that did not
  /// come in time leaves the move signed, for {resume}. Nothing is signed while another transaction is pending.
  async function commit(action, request) {
    await idle();
    const call = tx(request);
    const prepared = await client.prepareTransactionRequest({ account, chain, ...call });
    const raw = await account.signTransaction(prepared);
    const hash = keccak256(raw);
    const id = journal.open(action, { chain: name, raw, hash, nonce: prepared.nonce });
    await client.sendRawTransaction({ serializedTransaction: raw });
    const receipt = await client.waitForTransactionReceipt({ hash, timeout: 180_000 }).catch(() => null);
    const getTransaction = (q) => client.getTransaction(q);
    return { id, receipt: await settleCommit({ journal, id, hash, request: call, receipt, getTransaction }) };
  }

  /// A move left signed by a restart or a slow chain: its receipt if it was mined; otherwise its transaction is sent
  /// again, or, when its nonce went to another transaction, the move is dropped (`sending.mjs`). Returns the receipt or
  /// null.
  function resume(move) {
    return resumeMove({ client, address: account.address, journal, move });
  }

  /// Sends a transaction that completes a move, and waits for it: no journal entry, since the contract it calls counts
  /// it once.
  async function complete(request) {
    await idle();
    const hash = await wallet.sendTransaction(tx(request));
    const receipt = await client.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (receipt.status !== "success") throw new Error(`${name}: ${hash} reverted`);
    return receipt;
  }

  /// Lets `spender` take exactly `amount` of `token`, what the next call takes, unless it may already (RS-12).
  async function allow(token, spender, amount) {
    await allowExactly({
      allowance: () => read(token, ABI.erc20, "allowance", [account.address, spender]),
      approve: (x) => complete({ to: token, abi: ABI.erc20, functionName: "approve", args: [spender, x] }),
      amount,
    });
  }

  /// The sequence the chain's Wormhole core published in `receipt` for `emitter`, from the core's own
  /// LogMessagePublished (`attestations.mjs` sequenceIn, RS-14).
  async function sequenceOf(receipt, emitter = def.tokenBridge) {
    const decode = (log) => decodeEventLog({ abi: ABI.core, data: log.data, topics: log.topics });
    const sequence = sequenceIn(receipt.logs, { core: await coreAddress(), emitter, decode });
    if (sequence === null) throw new Error(`${name}: no Wormhole message from ${emitter} in ${receipt.transactionHash}`);
    return sequence;
  }

  return {
    name,
    def,
    client,
    address: account.address,
    read,
    commit,
    resume,
    complete,
    allow,
    sequenceOf,
    balance: (token) => (token ? read(token, ABI.erc20, "balanceOf", [account.address]) : client.getBalance({ address: account.address })),
    messageFee: async () => read(await coreAddress(), ABI.core, "messageFee"),
    /// Whether this chain's Wormhole core accepts `vaa`'s signatures, before the move stores it (RS-14).
    verifyVaa: async (vaa) => {
      const [, valid, reason] = await read(await coreAddress(), ABI.core, "parseAndVerifyVM", [vaa]);
      return { valid, reason };
    },
    /// Whether this chain's CCTP transmitter would receive `message` with `attestation`, before the move stores them: a
    /// simulation, or the message received already (RS-14).
    verifyCctp: async (message, attestation) => {
      const r = { to: MESSAGE_TRANSMITTER_V2, abi: ABI.messageTransmitter, functionName: "receiveMessage", args: [message, attestation] };
      try {
        await client.simulateContract({ account, address: r.to, abi: r.abi, functionName: r.functionName, args: r.args });
        return { valid: true, reason: "" };
      } catch (error) {
        if (!isRevert(error)) throw error;
        const used = (await read(MESSAGE_TRANSMITTER_V2, ABI.messageTransmitter, "usedNonces", [cctpNonce(message)])) !== 0n;
        return { valid: used, reason: used ? "" : revertReason(error) };
      }
    },
    transferCompleted: (vaa) => read(def.tokenBridge, ABI.tokenBridge, "isTransferCompleted", [vaaHash(vaa)]),
    cctpReceived: async (message) => (await read(MESSAGE_TRANSMITTER_V2, ABI.messageTransmitter, "usedNonces", [cctpNonce(message)])) !== 0n,
    /// The CCTP burn of `amount` USDC to `recipient` on `domain`, as a request for {commit}.
    burnRequest: (amount, domain, recipient) => ({
      to: TOKEN_MESSENGER_V2,
      abi: ABI.tokenMessenger,
      functionName: "depositForBurn",
      args: [amount, domain, word(recipient), def.usdc ?? def.market.usdc, `0x${"00".repeat(32)}`, 0n, STANDARD_FINALITY],
    }),
    receiveRequest: (message, attestation) => ({
      to: MESSAGE_TRANSMITTER_V2,
      abi: ABI.messageTransmitter,
      functionName: "receiveMessage",
      args: [message, attestation],
    }),
    tokenMessenger: TOKEN_MESSENGER_V2,
  };
}
