// TESTNETS ONLY: P1 on the BNB testnet vault, with the proof system in proofs/ built for Sepolia
// (`cargo build --release -p xindex-p1-script -p xindex-p1-input --features sepolia`). This file only drives it: the
// proof is P1's own, checked on BNB testnet by EthereumFinalityVerifier through SP1's Groth16 verifier.
//
// P1 moves its verifier from one finalized Sepolia checkpoint, the anchor, to a later one, C1, and records the
// execution blocks between them under a headers root. A message is then proven by its block's place under that root
// and its receipt under the block's receipts root. The relayer keeps the anchor's state, as P1's next input needs it.
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { encodeAbiParameters, keccak256, parseAbiParameters, type Hex, type PublicClient } from "viem";
import { DEMO, need } from "./env.js";
import { receiptProof } from "./receipts.js";

const PROOFS = resolve(DEMO, "..", "proofs");
const BIN = join(PROOFS, "target", "release");
export const P1_STATE = join(DEMO, "relayer", "state", "p1");
/** The finalized checkpoint P1's verifier holds as its anchor: the state the next input is built from. */
export const ANCHOR_STATE = join(P1_STATE, "anchor.ssz");

const HEADER = "(bytes32 headersRoot, uint64 number, uint64 timestamp, bytes32 stateRoot, bytes32 receiptsRoot, bytes32[] path)";

function run(binary: string, args: string[]): string {
  const path = join(BIN, binary);
  if (!existsSync(path)) throw new Error(`build ${binary} for Sepolia first: proofs/README.md, "Sepolia"`);
  const out = execFileSync(path, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 26 });
  return out;
}

/** What `p1-input check-state` reads from a state: its epoch and the anchor a verifier starting there holds. */
export function checkState(path: string): { epoch: bigint; anchor: Hex; execNumber: bigint } {
  const out = run("p1-input", ["check-state", path]);
  const epoch = BigInt(/^epoch (\d+)/m.exec(out)![1]);
  const anchor = /^anchor (0x[0-9a-f]{64})/m.exec(out)![1] as Hex;
  const execNumber = BigInt(/^execution block (\d+)/m.exec(out)![1]);
  return { epoch, anchor, execNumber };
}

/** Downloads Sepolia's latest finalized checkpoint state from a checkpoint-sync server. */
export async function fetchFinalizedState(to: string): Promise<void> {
  const base = process.env.SEPOLIA_CHECKPOINT_SYNC ?? "https://checkpoint-sync.sepolia.ethpandaops.io";
  const res = await fetch(`${base}/eth/v2/debug/beacon/states/finalized`, { headers: { Accept: "application/octet-stream" } });
  if (!res.ok) throw new Error(`checkpoint sync answered ${res.status}`);
  mkdirSync(P1_STATE, { recursive: true });
  writeFileSync(to, Buffer.from(await res.arrayBuffer()));
}

/** Day 0: keeps the latest finalized state as P1's first anchor and prints what `bnb0` deploys the verifier with. */
export async function firstAnchor() {
  await fetchFinalizedState(ANCHOR_STATE);
  const a = checkState(ANCHOR_STATE);
  const key = /^(0x[0-9a-f]{64})$/m.exec(run("p1", ["vkey"]))![1];
  return { P1_KEY: key, P1_ANCHOR: a.anchor, P1_EPOCH: a.epoch.toString() };
}

export interface Update {
  publicValues: Hex;
  proof: Hex;
  epoch: bigint;
  anchorOut: Hex;
}

/** Proves Sepolia's latest finalized checkpoint from the held anchor: builds the input, which `p1-input` checks by
 *  running the statement natively, then proves it on SP1's network or a GPU. `held` is the verifier's anchor, which
 *  the kept state must be. Returns nothing when Sepolia has finalized nothing newer. */
export async function prove(held: Hex): Promise<Update | undefined> {
  const mode = process.env.SP1_PROVER;
  if (mode !== "network" && mode !== "cuda") throw new Error("set SP1_PROVER to network (with NETWORK_PRIVATE_KEY) or cuda to prove P1");
  const anchor = checkState(ANCHOR_STATE);
  if (anchor.anchor !== held) throw new Error(`the kept anchor state is ${anchor.anchor}, the verifier holds ${held}`);
  const c1Path = join(P1_STATE, "c1.ssz");
  await fetchFinalizedState(c1Path);
  const c1 = checkState(c1Path);
  if (c1.epoch <= anchor.epoch) return undefined;
  const input = join(P1_STATE, `input-${c1.epoch}.bin`);
  const proofFile = join(P1_STATE, `proof-${c1.epoch}.json`);
  run("p1-input", ["build", need("SEPOLIA_BEACON"), need("SEPOLIA_RPC"), ANCHOR_STATE, c1Path, input]);
  run("p1", ["prove", input, proofFile]);
  const p = JSON.parse(readFileSync(proofFile, "utf8"));
  copyFileSync(c1Path, join(P1_STATE, `anchor-${c1.epoch}.ssz`));
  return { publicValues: p.publicValues, proof: p.proof, epoch: c1.epoch, anchorOut: c1.anchor };
}

/** After the verifier took `u`: C1 is the anchor from now on. */
export function advanceAnchor(u: Update) {
  copyFileSync(join(P1_STATE, `anchor-${u.epoch}.ssz`), ANCHOR_STATE);
}

// ---------------------------------------------------------------------
// proofs against a recorded headers root
// ---------------------------------------------------------------------

export interface Range {
  headersRoot: Hex;
  first: bigint;
  last: bigint;
}

/** The leaf of one execution block, as P1 commits it: `keccak256(abi.encode(number, timestamp, stateRoot,
 *  receiptsRoot))`. */
function leaf(b: { number: bigint; timestamp: bigint; stateRoot: Hex; receiptsRoot: Hex }): Hex {
  return keccak256(
    encodeAbiParameters(parseAbiParameters("uint256, uint256, bytes32, bytes32"), [b.number, b.timestamp, b.stateRoot, b.receiptsRoot]),
  );
}

const pair = (a: Hex, b: Hex) => keccak256(encodeAbiParameters(parseAbiParameters("bytes32, bytes32"), [a, b]));
const ZERO = `0x${"00".repeat(32)}` as Hex;

/** The `Header` struct EthereumFinalityVerifier checks for `number`: the block's leaf fields and its path to the range's
 *  root, rebuilt from Sepolia's blocks and checked against the recorded root. */
export async function header(sepolia: PublicClient, r: Range, number: bigint) {
  if (number < r.first || number > r.last) throw new Error(`block ${number} is outside ${r.first}..${r.last}`);
  const blocks = [];
  for (let n = r.first; n <= r.last; ++n) blocks.push(sepolia.getBlock({ blockNumber: n }));
  let layer = (await Promise.all(blocks)).map((b) => leaf(b as any));
  const target = Number(number - r.first);
  const b = await sepolia.getBlock({ blockNumber: number });
  const path: Hex[] = [];
  let index = target;
  while (layer.length > 1) {
    path.push((index ^ 1) < layer.length ? layer[index ^ 1] : ZERO);
    const up: Hex[] = [];
    for (let i = 0; i < layer.length; i += 2) up.push(pair(layer[i], i + 1 < layer.length ? layer[i + 1] : ZERO));
    layer = up;
    index >>= 1;
  }
  if (layer[0] !== r.headersRoot) throw new Error(`Sepolia's blocks ${r.first}..${r.last} rebuild to ${layer[0]}, not ${r.headersRoot}`);
  return { headersRoot: r.headersRoot, number, timestamp: b.timestamp, stateRoot: b.stateRoot, receiptsRoot: b.receiptsRoot, path };
}

/** `verifyEvent`'s proof of the log at `logIndex` in block `blockNumber`, sent by transaction `txHash`. */
export async function eventProof(sepolia: PublicClient, r: Range, blockNumber: bigint, txHash: Hex, logIndex: number): Promise<Hex> {
  const h = await header(sepolia, r, blockNumber);
  const p = await receiptProof(sepolia, blockNumber, txHash, logIndex);
  return encodeAbiParameters(parseAbiParameters(`${HEADER}, bytes[], uint256, uint256`), [h, p.proof, p.txIndex, p.logIndex]);
}

/** `verifyCheckpoint`'s proof of block `number`: its header alone. */
export async function checkpointProof(sepolia: PublicClient, r: Range, number: bigint): Promise<Hex> {
  return encodeAbiParameters(parseAbiParameters(HEADER), [await header(sepolia, r, number)]);
}
