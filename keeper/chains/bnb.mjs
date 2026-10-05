// The filler's BNB Chain adapter. DRAFT, untested on mainnet (2026-10-06): ported from demo/relayer/src/bnb.ts, which
// runs on BNB testnet against BnbStateVerifier, with the chain, the RPC and the addresses made parameters.
//
// It deposits a fill's bought BNB Chain legs into the vault under the fill's intake, keeps BnbStateVerifier on Ethereum
// following BNB Chain's validator sets (anyone may advance it), and proves the vault's intake digest from BNB Chain's
// own finality votes: the `ChainProof` that `settleRebalance` takes for this chain.
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
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { abi } from "../artifacts.mjs";

const EPOCH = 1000n;
const MAX_STEPS = 4;
const FIELDS = [
  "parentHash", "sha3Uncles", "miner", "stateRoot", "transactionsRoot", "receiptsRoot", "logsBloom", "difficulty",
  "number", "gasLimit", "gasUsed", "timestamp", "extraData", "mixHash", "nonce", "baseFeePerGas",
  "withdrawalsRoot", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "requestsHash",
];
const INTS = new Set(["difficulty", "number", "gasLimit", "gasUsed", "timestamp", "baseFeePerGas", "blobGasUsed", "excessBlobGas"]);

/// The adapter for one BNB-style chain: `chainId` 56 on mainnet, 97 on testnet.
export function bnbChain({ chainId, rpc, key, ethClient, ethWallet }) {
  const chain = defineChain({
    id: chainId,
    name: `BNB ${chainId}`,
    nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const client = createPublicClient({ chain, transport: http(rpc) });
  const wallet = createWalletClient({ account: privateKeyToAccount(key), chain, transport: http(rpc) });
  const blocks = new Map();

  async function send(c, w, address, contract, functionName, args, value) {
    const hash = await w.writeContract({ address, abi: abi(contract), functionName, args, value, chain: w.chain, account: w.account });
    const receipt = await c.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
    return receipt;
  }

  async function block(n) {
    for (let i = 0; i < 60; ++i) {
      const cached = blocks.get(n);
      if (cached) return cached;
      const b = await client.request({ method: "eth_getBlockByNumber", params: [numberToHex(n), false] });
      if (b) {
        blocks.set(n, b);
        return b;
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    throw new Error(`BNB block ${n} did not appear`);
  }

  async function headerRlp(n) {
    const b = await block(n);
    const items = FIELDS.filter((f) => b[f] !== undefined && b[f] !== null).map((f) =>
      INTS.has(f) ? (hexToBigInt(b[f]) === 0n ? "0x" : numberToHex(hexToBigInt(b[f]))) : b[f],
    );
    const rlp = toRlp(items);
    if (keccak256(rlp) !== b.hash) throw new Error(`BNB header ${n} does not hash to its block hash`);
    return rlp;
  }

  const extra = async (n) => hexToBytes((await block(n)).extraData);

  async function validators(n) {
    if (n % EPOCH !== 0n) throw new Error(`${n} is not an epoch block`);
    const ex = await extra(n);
    const count = ex[32];
    const entries = [];
    for (let i = 0; i < count; ++i) {
      entries.push({ address: ex.slice(33 + 68 * i, 53 + 68 * i), key: ex.slice(53 + 68 * i, 33 + 68 * (i + 1)) });
    }
    return { entries, turnLength: ex[33 + 68 * count] };
  }

  const fp = (v) => pad(numberToHex(v), { size: 64 });
  const g1 = (compressed) => {
    const p = bls12_381.G1.ProjectivePoint.fromHex(compressed).toAffine();
    return `0x${fp(p.x).slice(2)}${fp(p.y).slice(2)}`;
  };
  const g2 = (compressed) => {
    const p = bls12_381.G2.ProjectivePoint.fromHex(compressed).toAffine();
    return `0x${[p.x.c0, p.x.c1, p.y.c0, p.y.c1].map((v) => fp(v).slice(2)).join("")}`;
  };
  const bytesToBig = (b) => (b === "0x" ? 0n : hexToBigInt(b));

  async function attestation(n) {
    const ex = await extra(n);
    const att = n % EPOCH === 0n ? ex.slice(33 + 68 * ex[32] + 1, ex.length - 65) : ex.slice(32, ex.length - 65);
    if (att.length === 0) return undefined;
    const [bitset, sig, data] = fromRlp(toHex(att));
    return { bitset: bytesToBig(bitset), sig: hexToBytes(sig), sn: bytesToBig(data[0]), sh: data[1], tn: bytesToBig(data[2]), th: data[3] };
  }

  async function finalityVote(n, count) {
    for (let h = n + 2n; h < n + 12n; ++h) {
      const a = await attestation(h);
      if (a && a.sn === n && a.tn === n + 1n) {
        if (a.sh !== (await block(n)).hash) throw new Error(`the vote on ${n} names another block`);
        if (a.bitset >> BigInt(count) !== 0n) throw new Error(`the vote on ${n} names a voter outside the set`);
        return { targetHash: a.th, bitset: a.bitset, signature: g2(a.sig) };
      }
    }
    throw new Error(`no attestation finalizes BNB block ${n} through its child yet`);
  }

  /// Records BNB Chain's next finalized epoch blocks in `verifier` on Ethereum, a few a transaction, so it stays within
  /// its day. Returns the latest epoch recorded.
  async function follow(verifier) {
    let latest = await ethClient.readContract({ address: verifier, abi: abi("BnbStateVerifier"), functionName: "latestEpoch" });
    const finalized = (await client.getBlock({ blockTag: "finalized" })).number;
    for (;;) {
      const voters = (await validators(latest)).entries;
      const steps = [];
      let previous = voters;
      for (let e = latest + EPOCH; e + 1n < finalized && steps.length < MAX_STEPS; e += EPOCH) {
        const next = await validators(e);
        const sources = [];
        const fresh = [];
        for (const v of next.entries) {
          const at = previous.findIndex((p) => toHex(p.key) === toHex(v.key));
          sources.push(at >= 0 ? at : 255);
          if (at < 0) fresh.push(g1(v.key));
        }
        steps.push({ header: await headerRlp(e), vote: await finalityVote(e, previous.length), keySources: toHex(Uint8Array.from(sources)), newKeys: fresh });
        previous = next.entries;
      }
      if (steps.length === 0) return latest;
      await send(ethClient, ethWallet, verifier, "BnbStateVerifier", "advance", [voters.map((v) => g1(v.key)), steps]);
      latest += BigInt(steps.length) * EPOCH;
    }
  }

  /// The vault's slot holding (index, intakeId)'s digest: mapping at slot 15 of index, then intake id.
  function intakeSlot(index, intakeId) {
    const inner = keccak256(encodeAbiParameters(parseAbiParameters("address, uint256"), [index, 15n]));
    return keccak256(encodeAbiParameters(parseAbiParameters("uint256, bytes32"), [intakeId, inner]));
  }

  /// `slots` of `account` at a final block near the head, as BnbStateVerifier's `verifySlots` takes them.
  async function slotsProof(verifier, account, slots) {
    let proof;
    let number;
    for (let attempt = 0; attempt < 10 && number === undefined; ++attempt) {
      proof = await client.request({ method: "eth_getProof", params: [account, slots, "latest"] });
      const root = keccak256(proof.accountProof[0]);
      const near = await client.getBlockNumber();
      for (let n = near - 8n; n <= near + 2n && number === undefined; ++n) {
        if ((await block(n)).stateRoot === root) number = n;
      }
    }
    if (number === undefined) throw new Error("no BNB block near the head has the proof's state root");
    await follow(verifier);
    let epoch = (number / EPOCH) * EPOCH;
    const set = await ethClient.readContract({ address: verifier, abi: abi("BnbStateVerifier"), functionName: "validatorSet", args: [epoch] });
    if (Number(set.count) === 0 || BigInt(set.firstTarget) > number + 1n) epoch -= EPOCH;
    const { entries } = await validators(epoch);
    const vote = await finalityVote(number, entries.length);
    const encoded = encodeAbiParameters(
      parseAbiParameters(
        "(bytes header, uint256 epoch, (bytes32 targetHash, uint256 bitset, bytes signature) vote, bytes[] keys, bytes[] accountProof, bytes[][] storageProofs)",
      ),
      [{
        header: await headerRlp(number),
        epoch,
        vote,
        keys: entries.map((x) => g1(x.key)),
        accountProof: proof.accountProof,
        storageProofs: proof.storageProof.map((p) => p.proof),
      }],
    );
    return { proof: encoded, number, timestamp: hexToBigInt((await block(number)).timestamp) };
  }

  return {
    chainId: BigInt(chainId),

    /// Keeps `verifier` within its day; the vault is not needed here.
    follow: (verifier) => follow(verifier),

    /// Deposits `amount` of `token` (the zero address for BNB itself) into `vault` under `intakeId` for `index`.
    async deposit(vault, index, intakeId, token, amount) {
      if (token === "0x0000000000000000000000000000000000000000") {
        return send(client, wallet, vault, "XindexVault", "deposit", [index, intakeId], amount);
      }
      await send(client, wallet, token, "IERC20", "approve", [vault, amount]);
      return send(client, wallet, vault, "XindexVault", "depositToken", [index, intakeId, token, amount]);
    },

    /// The `ChainProof` of `index`'s intake on `vault`, proven through `verifier` on Ethereum.
    async intakeProof(verifier, vault, index, intakeId) {
      const p = await slotsProof(verifier, vault, [intakeSlot(index, intakeId)]);
      const tokens = await client.readContract({ address: vault, abi: abi("XindexVault"), functionName: "intakeTokens", args: [index, intakeId] });
      const totals = [];
      for (const t of tokens) {
        totals.push(await client.readContract({ address: vault, abi: abi("XindexVault"), functionName: "intakeTotal", args: [index, intakeId, t] }));
      }
      return { proof: p.proof, tokens, totals };
    },

    /// How much of `token` (zero for BNB) this filler deposited into `vault` under `intakeId` for `index`.
    async readDeposited(vault, index, intakeId, token, depositor) {
      return client.readContract({ address: vault, abi: abi("XindexVault"), functionName: "deposited", args: [index, intakeId, token, depositor] });
    },

    /// The filler's balance of `token` (zero for BNB) on this chain, to check before it commits to a delivery.
    async holds(token) {
      if (token === "0x0000000000000000000000000000000000000000") return client.getBalance({ address: wallet.account.address });
      return client.readContract({ address: token, abi: abi("IERC20"), functionName: "balanceOf", args: [wallet.account.address] });
    },

    /// The filler's address on this chain, as a recipient word for the sold legs.
    recipient() {
      return pad(wallet.account.address, { size: 32 });
    },
  };
}
