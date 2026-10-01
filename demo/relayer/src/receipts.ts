// TESTNETS ONLY: a block's receipts trie, rebuilt from its receipts, and a receipt's Merkle-Patricia proof in the
// node-list form `eth_getProof` uses, which src/libraries/MerklePatricia.sol walks. The trie's root is checked against
// the block's `receiptsRoot` before any proof leaves this file, so a proof is the chain's own.
import { bytesToHex, concat, hexToBytes, keccak256, numberToHex, toRlp, type Hex, type PublicClient } from "viem";

type Rlp = Hex | Rlp[];

/** An integer as RLP wants it: big-endian with no leading zero, and zero as the empty string. */
const int = (n: bigint | number): Hex => (BigInt(n) === 0n ? "0x" : numberToHex(BigInt(n)));

const TYPES: Record<string, number> = { legacy: 0, eip2930: 1, eip1559: 2, eip4844: 3, eip7702: 4 };

/** A receipt's consensus encoding: `rlp([status, cumulativeGasUsed, logsBloom, logs])`, after its type byte when it
 *  has one (EIP-2718). */
function encodeReceipt(r: any): Hex {
  const status = r.status === "success" || r.status === "0x1" || r.status === 1 ? "0x01" : "0x";
  const logs: Rlp[] = r.logs.map((l: any) => [l.address, l.topics, l.data]);
  const body = toRlp([status, int(r.cumulativeGasUsed), r.logsBloom, logs] as Rlp[]);
  const type = typeof r.type === "string" && r.type.startsWith("0x") ? Number(BigInt(r.type)) : (TYPES[r.type] ?? 0);
  return type === 0 ? body : concat([numberToHex(type, { size: 1 }), body]);
}

const nibbles = (b: Uint8Array): number[] => [...b].flatMap((x) => [x >> 4, x & 15]);

/** Hex-prefix encoding of a path: flag 2 for a leaf, 0 for an extension, plus one when the path is odd. */
function hexPrefix(path: number[], leaf: boolean): Hex {
  const flag = (leaf ? 2 : 0) + (path.length % 2);
  const all = path.length % 2 ? [flag, ...path] : [flag, 0, ...path];
  const out = new Uint8Array(all.length / 2);
  for (let i = 0; i < out.length; ++i) out[i] = (all[2 * i] << 4) | all[2 * i + 1];
  return bytesToHex(out);
}

interface Node {
  rlp: Hex;
  /** What a parent stores: the node itself when its encoding is under 32 bytes, else its hash. */
  ref: Rlp;
}

function node(items: Rlp[]): Node {
  const rlp = toRlp(items);
  return { rlp, ref: hexToBytes(rlp).length < 32 ? (items as Rlp) : keccak256(rlp) };
}

type Entry = { key: number[]; value: Hex };

/** Builds the trie of `entries` from nibble `depth` on, recording into `path` the encoded nodes a proof of `target`
 *  passes through. No key is a prefix of another (receipt keys are RLP), so no branch holds a value. */
function build(entries: Entry[], depth: number, target: number[] | undefined, path: Hex[]): Node {
  if (entries.length === 1) {
    const n = node([hexPrefix(entries[0].key.slice(depth), true), entries[0].value]);
    if (target) path.push(n.rlp);
    return n;
  }
  let shared = 0;
  for (;;) {
    const at = depth + shared;
    if (entries.some((e) => e.key.length <= at) || entries.some((e) => e.key[at] !== entries[0].key[at])) break;
    ++shared;
  }
  if (shared > 0) {
    const mark = path.length;
    const child = build(entries, depth + shared, target, path);
    const n = node([hexPrefix(entries[0].key.slice(depth, depth + shared), false), child.ref]);
    if (target) path.splice(mark, 0, n.rlp);
    return n;
  }
  const children: Rlp[] = [];
  const mark = path.length;
  for (let i = 0; i < 16; ++i) {
    const group = entries.filter((e) => e.key[depth] === i);
    const onPath = target !== undefined && target[depth] === i;
    children.push(group.length === 0 ? "0x" : build(group, depth + 1, onPath ? target : undefined, path).ref);
  }
  const n = node([...children, "0x"]);
  if (target) path.splice(mark, 0, n.rlp);
  return n;
}

export interface ReceiptProof {
  receiptsRoot: Hex;
  proof: Hex[];
  txIndex: bigint;
  logIndex: bigint;
}

/** The proof of the receipt that carries `log` in its block, with the log's place in that receipt. Only the nodes a
 *  parent refers to by hash are listed; one under 32 bytes stays inside its parent, as in `eth_getProof`. */
export async function receiptProof(client: PublicClient, blockNumber: bigint, txHash: Hex, logIndexInBlock: number): Promise<ReceiptProof> {
  const block = await client.getBlock({ blockNumber });
  const receipts: any[] = await client.request({ method: "eth_getBlockReceipts" as any, params: [numberToHex(blockNumber)] as any });
  const entries = receipts.map((r: any, i: number) => ({ key: nibbles(hexToBytes(toRlp(int(i)))), value: encodeReceipt(r) }));
  const txIndex = receipts.findIndex((r: any) => r.transactionHash.toLowerCase() === txHash.toLowerCase());
  if (txIndex < 0) throw new Error(`transaction ${txHash} is not in block ${blockNumber}`);
  const path: Hex[] = [];
  const root = build(entries, 0, entries[txIndex].key, path);
  const rootHash = keccak256(root.rlp);
  if (rootHash !== block.receiptsRoot) throw new Error(`block ${blockNumber}'s receipts rebuild to ${rootHash}, not ${block.receiptsRoot}`);
  // The proof lists hashed nodes only: the root, then every child its parent names by hash.
  const proof = path.filter((p, i) => i === 0 || hexToBytes(p).length >= 32);
  const receipt = receipts[txIndex];
  const logIndex = receipt.logs.findIndex((l: any) => Number(BigInt(l.logIndex)) === logIndexInBlock);
  if (logIndex < 0) throw new Error(`log ${logIndexInBlock} is not in transaction ${txHash}`);
  return { receiptsRoot: block.receiptsRoot, proof, txIndex: BigInt(txIndex), logIndex: BigInt(logIndex) };
}
