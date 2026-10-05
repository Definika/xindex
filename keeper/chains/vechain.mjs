// The filler's VeChain adapter. DRAFT, untested (2026-10-06).
//
// VeChain runs `XindexVault` unchanged, but its transactions are VeChain's own (clauses, blockRef, VTHO), so this sends
// them with `vechain/deploy.mjs`'s `connect` and `send`, the deployment's checked path. A slot reaches Ethereum as on
// TRON, by a call: the vault's `attest([slot], [digest])` in block Y, then `VeChainStakerAttester.attest(table)` in a
// round k with Y at or before k's checkpoint, and again in a later round r. Once r is over, `proofs/vechain` proves that
// k was justified and r committed under those tables (VIP-220), each vouched for by the verifier's trusted table, so Y
// is final. That takes an hour to ninety minutes of VeChain's time, within the fill's 6-hour delivery window; this
// adapter waits it out. `follow` keeps the verifier's trusted table within its day with an update proof.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeFunctionResult, encodeAbiParameters, encodeFunctionData, getAddress, hexToBytes, pad, parseAbiParameters } from "viem";
import { addressOf, connect, send as vechainSend } from "../../vechain/deploy.mjs";
import { abi } from "../artifacts.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, prove, run, workdir } from "./sp1.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const EPOCH = 180n; // blocks in a VIP-220 round
const BLOCK_SECONDS = 10;
// Update the verifier once its trusted table is this old; it stops for good at a day. A slots proof also needs a
// trusted table still within its day when it lands, two hours after it starts.
const REFRESH_AFTER = 18n * 3600n;
const SLOTS_TAKE = 2n * 3600n;
const VOUCH_BLOCKS = 110n; // blocks after an attester call before its vouching is read: 101 validators sign in turn
const RETRIES = 6;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const ATTESTER_ABI = [
  { type: "function", name: "currentTable", inputs: [], outputs: [{ name: "hash", type: "bytes32" }], stateMutability: "view" },
  { type: "function", name: "attest", inputs: [{ name: "expected", type: "bytes32" }], outputs: [], stateMutability: "view" },
];
const SLOTS_PROOF = parseAbiParameters("(bytes publicValues, bytes proof, bytes32[] values)");

export async function vechainChain({ network = "mainnet", host, key, ethClient, ethWallet }) {
  const chain = await connect(network, host);
  const secret = hexToBytes(key.startsWith("0x") ? key : `0x${key}`);
  const me = getAddress(addressOf(secret));
  const node = chain.url;

  async function read(address, contractAbi, functionName, args = []) {
    const data = encodeFunctionData({ abi: contractAbi, functionName, args });
    const out = await chain.view(address, data);
    if (out === undefined) throw new Error(`${functionName} reverted on VeChain`);
    return decodeFunctionResult({ abi: contractAbi, functionName, data: out });
  }

  async function send(address, contractAbi, functionName, args, value = 0n) {
    const data = encodeFunctionData({ abi: contractAbi, functionName, args });
    const clause = { to: address.toLowerCase(), value: `0x${value.toString(16)}`, data };
    return vechainSend(chain, secret, [clause], { label: functionName, log: () => {} });
  }

  const blockOf = async (id) => BigInt((await chain.request(`/transactions/${id}/receipt`)).meta.blockNumber);
  const best = async () => BigInt((await chain.best()).number);
  async function untilBlock(n) {
    for (let b = await best(); b < n; b = await best()) await sleep(Number(n - b) * BLOCK_SECONDS * 1000);
  }

  /// Sends the attester's `attest` of the Staker's table in the round of the next block; retries when a round's
  /// housekeeping changes the table between the read and the call.
  async function attestTable(attester) {
    for (let i = 0; ; ++i) {
      try {
        const table = await read(attester, ATTESTER_ABI, "currentTable");
        const { id } = await send(attester, ATTESTER_ABI, "attest", [table]);
        return { id, number: await blockOf(id) };
      } catch (error) {
        if (i + 1 >= RETRIES) throw error;
      }
    }
  }

  const verifierRead = (verifier, functionName, args = []) =>
    ethClient.readContract({ address: verifier, abi: abi("VeChainStateVerifier"), functionName, args });

  async function trustedOf(verifier) {
    const id = await verifierRead(verifier, "latestId");
    return { id, ...(await verifierRead(verifier, "trusted", [id])) };
  }

  /// Runs `input.py` and returns the input file, retrying while the chain has not yet reached what it needs.
  async function buildInput(args) {
    const path = join(workdir("vechain"), "input.json");
    for (let i = 0; ; ++i) {
      try {
        run("python3", ["input.py", node, ...args, path], join(ROOT, "proofs", "vechain", "fixtures"));
        return path;
      } catch (error) {
        if (i + 1 >= RETRIES) throw error;
        await sleep(5 * 60 * 1000);
      }
    }
  }

  async function update(verifier) {
    const attester = await verifierRead(verifier, "ATTESTER");
    const t = await trustedOf(verifier);
    const call = await attestTable(attester);
    await untilBlock(call.number + VOUCH_BLOCKS);
    const path = await buildInput(["update", attester, t.id, t.table, call.id]);
    const p = prove("vechain", "vechain", ["update", path]);
    const hash = await ethWallet.writeContract({ address: verifier, abi: abi("VeChainStateVerifier"), functionName: "update", args: [p.publicValues, p.proof] });
    const receipt = await ethClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`VeChain update reverted: ${hash}`);
  }

  return {
    chainId: chain.chainId,

    async deposit(vault, index, intakeId, token, amount) {
      if (token === ZERO) return send(vault, abi("XindexVault"), "deposit", [index, intakeId], amount);
      await send(token, abi("IERC20"), "approve", [vault, amount]);
      return send(vault, abi("XindexVault"), "depositToken", [index, intakeId, token, amount]);
    },

    readDeposited(vault, index, intakeId, token, depositor) {
      return read(vault, abi("XindexVault"), "deposited", [index, intakeId, token, depositor]);
    },

    async holds(token) {
      if (token === ZERO) return BigInt((await chain.account(me)).balance);
      return read(token, abi("IERC20"), "balanceOf", [me]);
    },

    recipient() {
      return pad(me, { size: 32 });
    },

    /// Keeps the verifier's trusted table within its day.
    async follow(verifier) {
      const t = await trustedOf(verifier);
      const now = (await ethClient.getBlock()).timestamp;
      if (now >= BigInt(t.time) + REFRESH_AFTER) await update(verifier);
    },

    /// The `ChainProof` of `index`'s intake on `vault`: `abi.encode(SlotsProof{publicValues, proof, values})` for
    /// `VeChainStateVerifier.verifySlots`, with the vault's tokens and totals.
    async intakeProof(verifier, vault, index, intakeId) {
      const now = (await ethClient.getBlock()).timestamp;
      if (now + SLOTS_TAKE >= BigInt((await trustedOf(verifier)).time) + 86_400n) await update(verifier);
      const t = await trustedOf(verifier);
      const attester = await verifierRead(verifier, "ATTESTER");

      const slot = intakeSlot(index, intakeId);
      const digest = await read(vault, abi("XindexVault"), "intakeDigest", [index, intakeId]);
      const { id: vaultTx } = await send(vault, abi("XindexVault"), "attest", [[slot], [digest]]);
      const y = await blockOf(vaultTx);

      // Round k's table, attested in round k, which starts after Y; then round r's, in a later round.
      await untilBlock((y / EPOCH + 1n) * EPOCH);
      const k = await attestTable(attester);
      await untilBlock((k.number / EPOCH + 1n) * EPOCH);
      const r = await attestTable(attester);
      await untilBlock((r.number / EPOCH + 1n) * EPOCH + VOUCH_BLOCKS);

      const path = await buildInput(["slots", attester, t.id, t.table, vault, vaultTx, k.id, r.id, slot, digest]);
      const input = JSON.parse(readFileSync(path, "utf8"));
      const p = prove("vechain", "vechain", ["slots", path]);
      const proof = encodeAbiParameters(SLOTS_PROOF, [{ publicValues: p.publicValues, proof: p.proof, values: input.slots.values }]);

      const tokens = await read(vault, abi("XindexVault"), "intakeTokens", [index, intakeId]);
      const totals = [];
      for (const token of tokens) totals.push(await read(vault, abi("XindexVault"), "intakeTotal", [index, intakeId, token]));
      return { proof, tokens, totals };
    },
  };
}
