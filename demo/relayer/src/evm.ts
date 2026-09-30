// TESTNETS ONLY: Sepolia and the HyperEVM vault, through viem. The stubs' digests are read from their own views, so
// what the relayer signs is exactly what they check.
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { abi, deployments, key, need } from "./env.js";
import { type Log } from "./messages.js";

export const sepolia = defineChain({
  id: 11_155_111,
  name: "Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.SEPOLIA_RPC ?? ""] } },
});

export const hyperevm = defineChain({
  id: 998,
  name: "HyperEVM testnet",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: [process.env.HYPEREVM_RPC ?? ""] } },
});

export const sepoliaClient = () => createPublicClient({ chain: sepolia, transport: http(need("SEPOLIA_RPC")) });
export const hyperClient = () => createPublicClient({ chain: hyperevm, transport: http(need("HYPEREVM_RPC")) });

export function wallet(chain: typeof sepolia | typeof hyperevm, keyName: string) {
  const account = privateKeyToAccount(key(keyName));
  const url = chain.id === sepolia.id ? need("SEPOLIA_RPC") : need("HYPEREVM_RPC");
  return createWalletClient({ account, chain, transport: http(url) });
}

/** Sends a contract call and waits for its receipt; throws if it reverted. */
export async function send(
  client: PublicClient,
  w: ReturnType<typeof wallet>,
  address: Address,
  contract: string,
  functionName: string,
  args: unknown[],
  value?: bigint,
) {
  const hash = await w.writeContract({
    address,
    abi: abi(contract),
    functionName,
    args,
    value,
    chain: w.chain,
    account: w.account!,
  } as any);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  return receipt;
}

export async function read(client: PublicClient, address: Address, contract: string, functionName: string, args: unknown[] = []) {
  return client.readContract({ address, abi: abi(contract), functionName, args } as any) as Promise<any>;
}

// ---------------------------------------------------------------------
// Ethereum → HyperEVM: messages and checkpoints, signed as StubEventVerifier checks
// ---------------------------------------------------------------------

async function eventProof(client: PublicClient, verifier: Address, keyName: string, log: Log): Promise<Hex> {
  const digest = (await read(client, verifier, "StubEventVerifier", "eventDigest", [
    log.blockNumber,
    log.emitter,
    EVENT_TOPIC_HEX,
    log.topic1,
    keccak256(log.data),
  ])) as Hex;
  const signature = await privateKeyToAccount(key(keyName)).signMessage({ message: { raw: digest } });
  return encodeAbiParameters(parseAbiParameters("uint256, address, bytes32, bytes32, bytes, bytes"), [
    log.blockNumber,
    log.emitter,
    EVENT_TOPIC_HEX,
    log.topic1,
    log.data,
    signature,
  ]);
}

const EVENT_TOPIC_HEX = keccak256(new TextEncoder().encode("VaultMessage(bytes32,bytes)"));

/** Delivers one message to the HyperEVM vault with both stub proofs, unless it already ran there. */
export async function deliverHyper(log: Log): Promise<"delivered" | "done"> {
  const h = deployments.hyperevm();
  const client = hyperClient();
  if (await read(client, h.vault, "XindexVault", "used", [log.topic1])) return "done";
  const proof1 = await eventProof(client, h.p1, "RELAYER1_KEY", log);
  const proof2 = await eventProof(client, h.p2, "RELAYER2_KEY", log);
  await send(client, wallet(hyperevm, "SENDER_KEY"), h.vault, "XindexVault", "deliver", [proof1, proof2]);
  return "delivered";
}

/** Keeps the HyperEVM vault out of a stall: Sepolia's latest finalized block as a checkpoint both stubs sign. */
export async function checkpointHyper(): Promise<bigint | undefined> {
  const h = deployments.hyperevm();
  const client = hyperClient();
  const finalized = await sepoliaClient().getBlock({ blockTag: "finalized" });
  const last = await read(client, h.vault, "XindexVault", "checkpoint");
  if (BigInt(last.blockNumber) >= finalized.number) return undefined;
  const c = { blockNumber: finalized.number, timestamp: finalized.timestamp, stateRoot: finalized.stateRoot };
  const proofs: Hex[] = [];
  for (const [verifier, keyName] of [
    [h.p1, "RELAYER1_KEY"],
    [h.p2, "RELAYER2_KEY"],
  ] as const) {
    const digest = (await read(client, verifier, "StubEventVerifier", "checkpointDigest", [c])) as Hex;
    const signature = await privateKeyToAccount(key(keyName)).signMessage({ message: { raw: digest } });
    proofs.push(
      encodeAbiParameters(parseAbiParameters("(uint64 blockNumber, uint64 timestamp, bytes32 stateRoot), bytes"), [
        c,
        signature,
      ]),
    );
  }
  await send(client, wallet(hyperevm, "SENDER_KEY"), h.vault, "XindexVault", "advanceCheckpoint", proofs);
  return finalized.number;
}

// ---------------------------------------------------------------------
// HyperEVM → Ethereum: an intake's digest, signed as StubStateVerifier checks
// ---------------------------------------------------------------------

/** The slot of an intake's digest, as the hub's `_provenIntake` computes it for any vault chain. */
export function intakeSlot(index: Address, intakeId: bigint): Hex {
  const inner = keccak256(encodeAbiParameters(parseAbiParameters("address, uint256"), [index, 15n]));
  return keccak256(encodeAbiParameters(parseAbiParameters("uint256, bytes32"), [intakeId, inner]));
}

/** A stub state proof: the relayer's signature over the Sepolia verifier's digest of the reading. */
export async function stateProof(
  verifier: Address,
  account: Address,
  slot: Hex,
  value: Hex,
  blockNumber: bigint,
  timestamp: bigint,
): Promise<Hex> {
  const digest = (await read(sepoliaClient(), verifier, "StubStateVerifier", "stateDigest", [
    account,
    [slot],
    [value],
    blockNumber,
    timestamp,
  ])) as Hex;
  const signature = await privateKeyToAccount(key("STATE_RELAYER_KEY")).signMessage({ message: { raw: digest } });
  return encodeAbiParameters(parseAbiParameters("uint256, uint256, bytes32[], bytes"), [
    blockNumber,
    timestamp,
    [value],
    signature,
  ]);
}

/** The HyperEVM vault's intake, read at its latest block: the digest in storage, and its tokens and totals. */
export async function hyperIntake(index: Address, intakeId: bigint) {
  const h = deployments.hyperevm();
  const client = hyperClient();
  const block = await client.getBlock({ blockTag: "latest" });
  const slot = intakeSlot(index, intakeId);
  const value = (await client.getStorageAt({ address: h.vault, slot, blockNumber: block.number })) ?? "0x";
  const tokens = (await read(client, h.vault, "XindexVault", "intakeTokens", [index, intakeId])) as Address[];
  const totals: bigint[] = [];
  for (const t of tokens) totals.push(await read(client, h.vault, "XindexVault", "intakeTotal", [index, intakeId, t]));
  return { account: h.vault, slot, value: value as Hex, blockNumber: block.number, timestamp: block.timestamp, tokens, totals };
}
