// Pyth price updates the real Pyth contract accepts on a fork: the end-to-end test installs its own five keys as the
// guardian set of Pyth's receiver (since OP-PIP-132, 2026-08-26, Pyth on Ethereum verifies with the 5-key Pyth Pro set
// at `RECEIVER`) and signs accumulator updates (PNAU, Wormhole Merkle) for whatever prices it chooses. Layout as Pyth's
// PythAccumulator.sol and MerkleTree.sol and Wormhole's Messages.sol; checked on a fork of 2026-10-12 against Pyth 1.4.6.
import { concat, hexToBytes, keccak256, numberToHex, pad, toHex } from "viem";
import { privateKeyToAccount, sign } from "viem/accounts";

export const RECEIVER = "0x3a2DD09B4739D905183D503d594c8FB3e3D41820";
const GUARDIAN_SET_INDEX = 1;
const EMITTER_CHAIN = 26;
const EMITTER = "0x507974686e6574507974686e6574507974686e6574507974686e657450797468";
const KEYS = [0, 1, 2, 3, 4].map((i) => keccak256(toHex(`xindex-e2e-guardian-${i}`)));
const ADDRESSES = KEYS.map((k) => privateKeyToAccount(k).address);
const DEPTH = 12; // a slot's tree holds a few thousand messages: proofs as long as real ones

const u = (v, bytes) => pad(numberToHex(BigInt.asUintN(bytes * 8, BigInt(v))), { size: bytes });
const h160 = (data) => keccak256(data).slice(0, 42);
const leafHash = (msg) => h160(concat(["0x00", msg]));
const nodeHash = (a, b) => (BigInt(a) > BigInt(b) ? h160(concat(["0x01", b, a])) : h160(concat(["0x01", a, b])));

/// A price feed message: type 0, id, price, conf, expo, publish time, previous publish time, EMA price and conf.
const message = (f, publishTime) =>
  concat([
    "0x00",
    f.id,
    u(f.price, 8),
    u(f.conf, 8),
    u(f.expo, 4),
    u(publishTime, 8),
    u(f.prev ?? publishTime - 1, 8),
    u(f.price, 8),
    u(f.conf, 8),
  ]);

/// The storage writes that make ADDRESSES guardian set GUARDIAN_SET_INDEX of the receiver (`guardianSets` at slot 2).
export function guardianSlots() {
  const length = keccak256(concat([u(GUARDIAN_SET_INDEX, 32), u(2, 32)]));
  const first = BigInt(keccak256(length));
  return [[length, u(ADDRESSES.length, 32)], ...ADDRESSES.map((a, i) => [u(first + BigInt(i), 32), pad(a, { size: 32 })])];
}

/// One accumulator update holding every feed in `feeds` ({id, price, conf, expo, prev?}) published at `publishTime`.
export async function encodeUpdate(feeds, publishTime) {
  const msgs = feeds.map((f) => message(f, publishTime));
  let level = msgs.map(leafHash);
  for (let i = level.length; i < 1 << DEPTH; i++) level.push(h160(u(i, 32)));
  const levels = [level];
  while (level.length > 1) {
    const next = [];
    for (let i = 0; i < level.length; i += 2) next.push(nodeHash(level[i], level[i + 1]));
    levels.push(next);
    level = next;
  }
  const proof = (i) => levels.slice(0, -1).map((lv, d) => lv[(i >> d) ^ 1]);
  const payload = concat(["0x41555756", "0x00", u(publishTime, 8), u(10000, 4), level[0]]);
  const body = concat([u(publishTime, 4), u(0, 4), u(EMITTER_CHAIN, 2), EMITTER, u(publishTime, 8), "0x01", payload]);
  const digest = keccak256(keccak256(body));
  const sigs = [];
  for (let i = 0; i < KEYS.length; i++) {
    const s = await sign({ hash: digest, privateKey: KEYS[i] });
    sigs.push(concat([u(i, 1), s.r, s.s, u(s.yParity, 1)]));
  }
  const vaa = concat(["0x01", u(GUARDIAN_SET_INDEX, 4), u(KEYS.length, 1), ...sigs, body]);
  const parts = ["0x504e4155", "0x01", "0x00", "0x00", "0x00", u(hexToBytes(vaa).length, 2), vaa, u(msgs.length, 1)];
  msgs.forEach((m, i) => parts.push(u(hexToBytes(m).length, 2), m, u(DEPTH, 1), ...proof(i)));
  return concat(parts);
}
