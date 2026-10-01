// TESTNETS ONLY: BNB testnet, with real proofs both ways but P2's. BNB testnet's state reaches Sepolia through
// BnbStateVerifier, from the chain's own finality votes; Sepolia's messages reach the BNB vault through P1
// (EthereumFinalityVerifier, `p1.ts`) and the P2 stub. The header and vote handling follows
// test/fixtures/bnb/generate.py, which the verifier's tests run on.
import { bls12_381 } from "@noble/curves/bls12-381";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  fromRlp,
  hexToBigInt,
  hexToBytes,
  http,
  keccak256,
  numberToHex,
  pad,
  parseAbiParameters,
  toHex,
  toRlp,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { abi, DEMO, key, need } from "./env.js";
import { intakeSlot, read, sepolia, sepoliaClient, wallet as sepoliaWallet } from "./evm.js";
import { type Log } from "./messages.js";
import * as p1 from "./p1.js";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const bnbTestnet = defineChain({
  id: 97,
  name: "BNB Smart Chain testnet",
  nativeCurrency: { name: "tBNB", symbol: "tBNB", decimals: 18 },
  rpcUrls: { default: { http: [process.env.BNB_RPC ?? ""] } },
});

export const bnbClient = () => createPublicClient({ chain: bnbTestnet, transport: http(need("BNB_RPC")) }) as PublicClient;

export function bnbWallet(keyName: string) {
  return createWalletClient({ account: privateKeyToAccount(key(keyName)), chain: bnbTestnet, transport: http(need("BNB_RPC")) });
}

const file = (name: string) => JSON.parse(readFileSync(join(DEMO, "deployments", name), "utf8"));
export const bnbDeployments = {
  bnb: () => file("bnb.json") as { sp1: Address; p1: Address; p2: Address; vault: Address; fromBlock: number },
  sepolia: () => file("sepolia-bnb.json") as { bnbStateVerifier: Address },
  index: () => file("index-bnb.json") as { index: Address; salt: Hex; bnb: Address },
};

async function sendTx(client: PublicClient, w: any, address: Address, contract: string, functionName: string, args: unknown[], value?: bigint) {
  const hash = await w.writeContract({ address, abi: abi(contract), functionName, args, value, chain: w.chain, account: w.account });
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  return receipt;
}

// ---------------------------------------------------------------------
// BNB testnet's blocks, sets and votes
// ---------------------------------------------------------------------

const EPOCH = 1000n;
const FIELDS = [
  "parentHash", "sha3Uncles", "miner", "stateRoot", "transactionsRoot", "receiptsRoot", "logsBloom", "difficulty",
  "number", "gasLimit", "gasUsed", "timestamp", "extraData", "mixHash", "nonce", "baseFeePerGas",
  "withdrawalsRoot", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "requestsHash",
];
const INTS = new Set(["difficulty", "number", "gasLimit", "gasUsed", "timestamp", "baseFeePerGas", "blobGasUsed", "excessBlobGas"]);

const blocks = new Map<bigint, any>();

/** Block `n` as the node gives it; one not produced yet is waited for, since a vote arrives a few blocks on. */
async function block(n: bigint): Promise<any> {
  for (let i = 0; i < 60; ++i) {
    const cached = blocks.get(n);
    if (cached) return cached;
    const b = await bnbClient().request({ method: "eth_getBlockByNumber", params: [numberToHex(n), false] });
    if (b) {
      blocks.set(n, b);
      return b;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`BNB testnet block ${n} did not appear`);
}

/** A header's RLP, checked against its hash. */
async function headerRlp(n: bigint): Promise<Hex> {
  const b = await block(n);
  const items = FIELDS.filter((f) => b[f] !== undefined && b[f] !== null).map((f) =>
    INTS.has(f) ? (hexToBigInt(b[f]) === 0n ? "0x" : numberToHex(hexToBigInt(b[f]))) : (b[f] as Hex),
  );
  const rlp = toRlp(items as Hex[]);
  if (keccak256(rlp) !== b.hash) throw new Error(`BNB testnet header ${n} does not hash to its block hash`);
  return rlp;
}

const extra = async (n: bigint) => hexToBytes((await block(n)).extraData);

interface Entry {
  address: Uint8Array;
  key: Uint8Array;
}

/** Epoch block `n`'s set: its (address, compressed BLS key) entries and its turn length. */
async function validators(n: bigint): Promise<{ entries: Entry[]; turnLength: number }> {
  if (n % EPOCH !== 0n) throw new Error(`${n} is not an epoch block`);
  const ex = await extra(n);
  const count = ex[32];
  const entries: Entry[] = [];
  for (let i = 0; i < count; ++i) {
    entries.push({ address: ex.slice(33 + 68 * i, 53 + 68 * i), key: ex.slice(53 + 68 * i, 33 + 68 * (i + 1)) });
  }
  return { entries, turnLength: ex[33 + 68 * count] };
}

const fp = (v: bigint) => pad(numberToHex(v), { size: 64 });

/** A compressed G1 key, uncompressed as the EIP-2537 precompiles take it: x and y, each in 64 bytes. */
function g1(compressed: Uint8Array): Hex {
  const p = bls12_381.G1.ProjectivePoint.fromHex(compressed).toAffine();
  return `0x${fp(p.x).slice(2)}${fp(p.y).slice(2)}`;
}

/** A compressed G2 signature, uncompressed: x.c0, x.c1, y.c0, y.c1, each in 64 bytes. */
function g2(compressed: Uint8Array): Hex {
  const p = bls12_381.G2.ProjectivePoint.fromHex(compressed).toAffine();
  return `0x${[p.x.c0, p.x.c1, p.y.c0, p.y.c1].map((v) => fp(v).slice(2)).join("")}`;
}

const bytesToBig = (b: Hex) => (b === "0x" ? 0n : hexToBigInt(b));

/** The vote attestation a header's extra data carries, if any. */
async function attestation(n: bigint) {
  const ex = await extra(n);
  const att = n % EPOCH === 0n ? ex.slice(33 + 68 * ex[32] + 1, ex.length - 65) : ex.slice(32, ex.length - 65);
  if (att.length === 0) return undefined;
  const [bitset, sig, data] = fromRlp(toHex(att)) as [Hex, Hex, Hex[]];
  return { bitset: bytesToBig(bitset), sig: hexToBytes(sig), sn: bytesToBig(data[0]), sh: data[1], tn: bytesToBig(data[2]), th: data[3] };
}

/** The vote, carried by a later header, whose source is block `n` and target its child: what shows `n` final. */
async function finalityVote(n: bigint, count: number) {
  for (let h = n + 2n; h < n + 12n; ++h) {
    const a = await attestation(h);
    if (a && a.sn === n && a.tn === n + 1n) {
      if (a.sh !== (await block(n)).hash) throw new Error(`the vote on ${n} names another block`);
      if (a.bitset >> BigInt(count) !== 0n) throw new Error(`the vote on ${n} names a voter outside the set`);
      return { targetHash: a.th, bitset: a.bitset, signature: g2(a.sig) };
    }
  }
  throw new Error(`no attestation finalizes BNB testnet block ${n} through its child yet`);
}

/** Day 0: the latest finalized epoch block's RLP and its set's keys, which `sepoliaBnb0` builds the verifier from. */
export async function epochForDeploy() {
  const finalized = (await bnbClient().getBlock({ blockTag: "finalized" })).number;
  const e = (finalized - 2n) / EPOCH * EPOCH;
  const { entries } = await validators(e);
  return { number: e.toString(), rlp: await headerRlp(e), keys: entries.map((x) => g1(x.key)) };
}

// ---------------------------------------------------------------------
// following BNB testnet on Sepolia
// ---------------------------------------------------------------------

const MAX_STEPS = 4;

/** Records BNB testnet's next finalized epoch blocks in BnbStateVerifier, a few a transaction, so it stays within its
 *  day. Returns the latest epoch recorded. */
export async function follow(): Promise<bigint> {
  const verifier = bnbDeployments.sepolia().bnbStateVerifier;
  const client = sepoliaClient();
  let latest = (await read(client, verifier, "BnbStateVerifier", "latestEpoch")) as bigint;
  const finalized = (await bnbClient().getBlock({ blockTag: "finalized" })).number;
  for (;;) {
    const voters = (await validators(latest)).entries;
    const steps = [];
    let previous = voters;
    for (let e = latest + EPOCH; e + 1n < finalized && steps.length < MAX_STEPS; e += EPOCH) {
      const next = await validators(e);
      const sources: number[] = [];
      const fresh: Hex[] = [];
      for (const v of next.entries) {
        const at = previous.findIndex((p) => toHex(p.key) === toHex(v.key));
        sources.push(at >= 0 ? at : 255);
        if (at < 0) fresh.push(g1(v.key));
      }
      steps.push({
        header: await headerRlp(e),
        vote: await finalityVote(e, previous.length), // signed by the set it replaces
        keySources: toHex(Uint8Array.from(sources)),
        newKeys: fresh,
      });
      previous = next.entries;
    }
    if (steps.length === 0) return latest;
    await sendTx(client, sepoliaWallet(sepolia, "SENDER_KEY"), verifier, "BnbStateVerifier", "advance", [voters.map((v) => g1(v.key)), steps]);
    latest += BigInt(steps.length) * EPOCH;
  }
}

// ---------------------------------------------------------------------
// BNB testnet → Sepolia: a vault's intake, proven from BNB testnet's votes
// ---------------------------------------------------------------------

/** `slots` of `account`, proven at a BNB testnet block near the head once that block is final: BnbStateVerifier's
 *  `verifySlots` proof. Public nodes serve `eth_getProof` only at their head, so the block is found by the proof's
 *  root. */
export async function slotsProof(account: Address, slots: Hex[]) {
  const client = bnbClient();
  let proof: any;
  let number: bigint | undefined;
  for (let attempt = 0; attempt < 10 && number === undefined; ++attempt) {
    proof = await client.request({ method: "eth_getProof", params: [account, slots, "latest"] });
    const root = keccak256(proof.accountProof[0]);
    const near = await client.getBlockNumber();
    for (let n = near - 8n; n <= near + 2n && number === undefined; ++n) {
      if ((await block(n)).stateRoot === root) number = n;
    }
  }
  if (number === undefined) throw new Error("no BNB testnet block near the head has the proof's state root");
  await follow();
  const verifier = bnbDeployments.sepolia().bnbStateVerifier;
  // The set that signs the vote on `number`'s child: the latest recorded one whose window holds that target. An epoch
  // block so recent that its set is not recorded yet has not started signing either: the switch comes at least
  // (n / 2 + 1) * turnLength blocks after it.
  let epoch = number / EPOCH * EPOCH;
  const set = (await read(sepoliaClient(), verifier, "BnbStateVerifier", "validatorSet", [epoch])) as any;
  if (Number(set.count) === 0 || BigInt(set.firstTarget) > number + 1n) epoch -= EPOCH;
  const { entries } = await validators(epoch);
  const vote = await finalityVote(number, entries.length);
  const encoded = encodeAbiParameters(
    parseAbiParameters(
      "(bytes header, uint256 epoch, (bytes32 targetHash, uint256 bitset, bytes signature) vote, bytes[] keys, bytes[] accountProof, bytes[][] storageProofs)",
    ),
    [
      {
        header: await headerRlp(number),
        epoch,
        vote,
        keys: entries.map((x) => g1(x.key)),
        accountProof: proof.accountProof,
        storageProofs: proof.storageProof.map((p: any) => p.proof),
      },
    ],
  );
  return { proof: encoded, number, timestamp: hexToBigInt((await block(number)).timestamp) };
}

/** The BNB vault's intake digest, proven from BNB testnet's votes: what `settleOrder` takes for this chain. */
export async function intakeProof(index: Address, intakeId: bigint) {
  const b = bnbDeployments.bnb();
  const client = bnbClient();
  const p = await slotsProof(b.vault, [intakeSlot(index, intakeId)]);
  const tokens = (await read(client as any, b.vault, "XindexVault", "intakeTokens", [index, intakeId])) as Address[];
  const totals: bigint[] = [];
  for (const t of tokens) totals.push(await read(client as any, b.vault, "XindexVault", "intakeTotal", [index, intakeId, t]));
  return { proof: p.proof, tokens, totals, timestamp: p.timestamp };
}

export async function deposit(index: Address, intakeId: bigint, amount: bigint) {
  const b = bnbDeployments.bnb();
  return sendTx(bnbClient(), bnbWallet("SENDER_KEY"), b.vault, "XindexVault", "deposit", [index, intakeId], amount);
}

export async function register(index: Address, salt: Hex) {
  const b = bnbDeployments.bnb();
  if (await read(bnbClient() as any, b.vault, "XindexVault", "isIndex", [index])) return "registered already";
  await sendTx(bnbClient(), bnbWallet("SENDER_KEY"), b.vault, "XindexVault", "registerIndex", [index, salt]);
  return "registered";
}

// ---------------------------------------------------------------------
// Sepolia → BNB testnet: P1's proof, and the stub's signature for P2
// ---------------------------------------------------------------------

const EVENT_TOPIC = keccak256(new TextEncoder().encode("VaultMessage(bytes32,bytes)"));
const advanced = { type: "event", name: "Advanced", inputs: [
  { name: "epoch", type: "uint64", indexed: true },
  { name: "anchor", type: "bytes32", indexed: false },
  { name: "headersRoot", type: "bytes32", indexed: false },
  { name: "first", type: "uint64", indexed: false },
  { name: "last", type: "uint64", indexed: false },
] } as const;

const rangesFile = join(p1.P1_STATE, "ranges.json");

/** The ranges P1's verifier on BNB testnet recorded, newest last, from its `Advanced` events since `bnb0`'s block.
 *  What was scanned is kept in the relayer's state, so each call reads only the blocks since. */
async function ranges(): Promise<p1.Range[]> {
  const b = bnbDeployments.bnb();
  const client = bnbClient();
  let kept: { next: string; ranges: { headersRoot: Hex; first: string; last: string }[] } = { next: String(b.fromBlock), ranges: [] };
  try {
    kept = JSON.parse(readFileSync(rangesFile, "utf8"));
  } catch {}
  const to = await client.getBlockNumber();
  for (let start = BigInt(kept.next); start <= to; start += 5000n) {
    const end = start + 4999n < to ? start + 4999n : to;
    const logs = await client.getLogs({ address: b.p1, event: advanced as any, fromBlock: start, toBlock: end });
    for (const l of logs as any[]) kept.ranges.push({ headersRoot: l.args.headersRoot, first: String(l.args.first), last: String(l.args.last) });
    kept.next = String(end + 1n);
  }
  mkdirSync(p1.P1_STATE, { recursive: true });
  writeFileSync(rangesFile, JSON.stringify(kept));
  return kept.ranges.map((r) => ({ headersRoot: r.headersRoot, first: BigInt(r.first), last: BigInt(r.last) }));
}

/** Proves Sepolia's latest finalized checkpoint to P1's verifier on BNB testnet, if it is newer than the anchor. */
export async function updateP1(): Promise<bigint | undefined> {
  const b = bnbDeployments.bnb();
  const held = (await read(bnbClient() as any, b.p1, "EthereumFinalityVerifier", "anchor")) as Hex;
  const u = await p1.prove(held);
  if (!u) return undefined;
  await sendTx(bnbClient(), bnbWallet("SENDER_KEY"), b.p1, "EthereumFinalityVerifier", "update", [u.publicValues, u.proof]);
  p1.advanceAnchor(u);
  return u.epoch;
}

/** The newest recorded range that covers block `n`, proving a newer checkpoint first when none does. */
async function rangeFor(n: bigint): Promise<p1.Range> {
  let found = (await ranges()).reverse().find((r) => r.first <= n && n <= r.last);
  if (!found) {
    await updateP1();
    found = (await ranges()).reverse().find((r) => r.first <= n && n <= r.last);
  }
  if (!found) throw new Error(`P1 covers no range with Sepolia block ${n} yet: it is newer than Sepolia's finalized head`);
  return found;
}

async function stubDigestSignature(digestFn: string, args: unknown[]): Promise<Hex> {
  const b = bnbDeployments.bnb();
  const digest = (await read(bnbClient() as any, b.p2, "StubEventVerifier", digestFn, args)) as Hex;
  return privateKeyToAccount(key("RELAYER2_KEY")).signMessage({ message: { raw: digest } });
}

/** The BNB vault's checkpoint, moved to the newest block P1 covers, with P1's proof and P2's stub signature. */
export async function checkpoint(): Promise<bigint | undefined> {
  const b = bnbDeployments.bnb();
  const all = await ranges();
  if (all.length === 0) return undefined;
  const r = all[all.length - 1];
  const last = (await read(bnbClient() as any, b.vault, "XindexVault", "checkpoint")).blockNumber as bigint;
  if (BigInt(last) >= r.last) return undefined;
  const sepoliaRead = sepoliaClient();
  const proof1 = await p1.checkpointProof(sepoliaRead, r, r.last);
  const blk = await sepoliaRead.getBlock({ blockNumber: r.last });
  const c = { blockNumber: r.last, timestamp: blk.timestamp, stateRoot: blk.stateRoot };
  const signature = await stubDigestSignature("checkpointDigest", [c]);
  const proof2 = encodeAbiParameters(parseAbiParameters("(uint64 blockNumber, uint64 timestamp, bytes32 stateRoot), bytes"), [c, signature]);
  await sendTx(bnbClient(), bnbWallet("SENDER_KEY"), b.vault, "XindexVault", "advanceCheckpoint", [proof1, proof2]);
  return r.last;
}

/** Delivers one message to the BNB vault: P1's proof of its log, and the P2 stub's signature. */
export async function deliver(entry: Log & { txHash: Hex; logIndex: number }): Promise<"delivered" | "done"> {
  const b = bnbDeployments.bnb();
  const client = bnbClient();
  if (await read(client as any, b.vault, "XindexVault", "used", [entry.topic1])) return "done";
  const r = await rangeFor(entry.blockNumber);
  // The vault runs a message that moves coins only from a block its checkpoint covers (VLT-3).
  const covered = (await read(client as any, b.vault, "XindexVault", "checkpoint")).blockNumber as bigint;
  if (BigInt(covered) < entry.blockNumber) await checkpoint();
  const proof1 = await p1.eventProof(sepoliaClient(), r, entry.blockNumber, entry.txHash, entry.logIndex);
  const signature = await stubDigestSignature("eventDigest", [entry.blockNumber, entry.emitter, EVENT_TOPIC, entry.topic1, keccak256(entry.data)]);
  const proof2 = encodeAbiParameters(parseAbiParameters("uint256, address, bytes32, bytes32, bytes, bytes"), [
    entry.blockNumber,
    entry.emitter,
    EVENT_TOPIC,
    entry.topic1,
    entry.data,
    signature,
  ]);
  await sendTx(client, bnbWallet("SENDER_KEY"), b.vault, "XindexVault", "deliver", [proof1, proof2]);
  return "delivered";
}
