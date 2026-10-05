// The filler's TRON adapter. DRAFT, untested (2026-10-06).
//
// TRON runs `XindexVault` (built with Tron's compiler, `tron/`), so deposits, balances and the intake's tokens and totals
// are the EVM vault's, called through TronWeb. No TRON header commits to contract storage, so the intake digest reaches
// Ethereum as a call: the filler sends the vault's `attest([slot], [digest])` as a top-level TriggerSmartContract, which
// succeeds only while the vault holds that digest, and `TronStateVerifier` checks the transaction, its SUCCESS result,
// its block and the 19 producers of the period's list who built on it (`ITronStateVerifier.CallProof`).
//
// The verifier follows TRON's producer lists, one per 6-hour period, and stops for good a day after its latest list's
// period began; `follow` advances it, and `intakeProof` advances it to the attest's period first when needed. The
// verifier records only a list's hash, so the producers are learned again from the period's own blocks and kept only
// when they hash to the record. `tron/proof.py` builds every proof, from TronGrid, with the checks of the fixture
// generator it reuses.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  getAbiItem,
  getAddress,
  keccak256,
  pad,
  parseAbiParameters,
  toFunctionSignature,
} from "viem";
import { abi } from "../artifacts.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, run, workdir, writeJson } from "./sp1.mjs";

const require = createRequire(import.meta.url);
const { TronWeb } = require("tronweb");

const ZERO = "0x0000000000000000000000000000000000000000";
const FEE_LIMIT = 200_000_000; // sun: at most 200 TRX of energy per call
const INTERVAL = 6n * 3600n * 1000n; // a producer list's period, in Tron's milliseconds
// No attest within this of a period's end, so 19 of its producers build on it inside the period, nor this soon after a
// period's start, so the period's learning round and its vouchers exist when the verifier is advanced to it.
const BEFORE_END = 3n * 60n * 1000n;
const AFTER_START = 5n * 60n * 1000n;
// Advance the verifier once its latest list's period began this long ago; it stops for good at a day.
const REFRESH_AFTER = 12n * 3600n * 1000n;
const SOLIDIFY_POLLS = 100; // three seconds apart: five minutes

const PRODUCERS = parseAbiParameters("(address witness, address key)[]");
const PROOF = parseAbiParameters([
  "(uint256 list, Producer[] producers, Transaction transaction, bytes32[] path, uint256 sides, Header[] headers), bytes32[]",
  "struct Producer { address witness; address key; }",
  "struct Transaction { address owner; bytes refBlockBytes; bytes refBlockHash; uint64 expiration; uint64 timestamp; uint64 feeLimit; uint32 permissionId; bytes[] signatures; uint64 fee; }",
  "struct Header { uint64 timestamp; bytes32 txTrieRoot; bytes32 parentHash; uint64 number; uint64 witnessId; address witness; int32 version; bytes accountStateRoot; bytes extra; bytes32 r; bytes32 s; uint8 v; uint8 producer; }",
]);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function tronChain({ api, key, ethClient, ethWallet, chainId = 728126428n }) {
  const tw = new TronWeb({ fullHost: api, privateKey: key.replace(/^0x/, "") });
  const me = tw.defaultAddress.base58;
  const meHex = getAddress(`0x${tw.defaultAddress.hex.slice(2)}`);
  const tron = (address) => TronWeb.address.fromHex(`41${address.slice(2)}`);
  const lists = new Map(); // list id => its producers, once checked against the verifier's record

  // ---------------------------------------------------------------------
  // TRON calls, ABI-encoded by viem from the repo's own build
  // ---------------------------------------------------------------------

  function encode(contract, functionName, args) {
    const item = getAbiItem({ abi: abi(contract), name: functionName, args });
    const data = encodeFunctionData({ abi: [item], functionName, args });
    return { signature: toFunctionSignature(item), rawParameter: data.slice(10), data };
  }

  async function read(address, contract, functionName, args) {
    const { signature, rawParameter } = encode(contract, functionName, args);
    const r = await tw.transactionBuilder.triggerConstantContract(tron(address), signature, { rawParameter }, [], me);
    if (!r.result?.result || !r.constant_result) throw new Error(`${functionName} failed on TRON: ${JSON.stringify(r.result)}`);
    return decodeFunctionResult({ abi: abi(contract), functionName, data: `0x${r.constant_result[0]}` });
  }

  /// The transaction's info once a solidified block holds it (TronWeb reads it from the solidity node).
  async function solidified(txid) {
    for (let i = 0; i < SOLIDIFY_POLLS; ++i) {
      const info = await tw.trx.getTransactionInfo(txid);
      if (info?.blockNumber) return info;
      await sleep(3000);
    }
    throw new Error(`${txid} was not solidified in five minutes`);
  }

  async function send(address, contract, functionName, args, callValue = 0n) {
    if (callValue > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error(`a call value of ${callValue} sun`);
    const { signature, rawParameter } = encode(contract, functionName, args);
    const built = await tw.transactionBuilder.triggerSmartContract(
      tron(address),
      signature,
      { feeLimit: FEE_LIMIT, callValue: Number(callValue), rawParameter },
      [],
      me,
    );
    if (!built.result?.result) throw new Error(`${functionName} not built on TRON: ${JSON.stringify(built.result)}`);
    const sent = await tw.trx.sendRawTransaction(await tw.trx.sign(built.transaction));
    if (!sent.result) throw new Error(`${functionName} not accepted on TRON: ${JSON.stringify(sent)}`);
    const txid = built.transaction.txID;
    const info = await solidified(txid);
    if (info.receipt?.result !== "SUCCESS") throw new Error(`${functionName} failed on TRON: ${txid} ${info.receipt?.result}`);
    return { txid, info };
  }

  // ---------------------------------------------------------------------
  // The verifier's producer lists
  // ---------------------------------------------------------------------

  const verifierRead = (verifier, functionName, args = []) =>
    ethClient.readContract({ address: verifier, abi: abi("TronStateVerifier"), functionName, args });

  function proofPy(args) {
    run("uv", ["run", "--with", "pycryptodome", "python3", join("tron", "proof.py"), api, ...args.map(String)], ROOT);
  }

  /// List `id`'s producers, learned from its period's blocks and checked against the verifier's record.
  async function producersOf(verifier, id) {
    if (lists.has(id)) return lists.get(id);
    const record = await verifierRead(verifier, "producerList", [id]);
    if (record.producersHash === `0x${"0".repeat(64)}`) throw new Error(`the verifier has no list ${id}`);
    const out = join(workdir("tron"), "producers.json");
    proofPy(["producers", record.start, record.end, out]);
    const learned = JSON.parse(readFileSync(out, "utf8"));
    for (const candidate of [learned.round, learned.rounds]) {
      if (keccak256(encodeAbiParameters(PRODUCERS, [candidate])) === record.producersHash) {
        lists.set(id, candidate);
        return candidate;
      }
    }
    throw new Error(`no learned list of period ${record.start}..${record.end} hashes to list ${id}'s record`);
  }

  /// Records the list of the period holding `target` (Tron's milliseconds), vouched for by the latest list.
  async function advanceTo(verifier, target) {
    const id = await verifierRead(verifier, "latestList");
    const latest = await verifierRead(verifier, "producerList", [id]);
    if (target < latest.end) return id;
    const current = await producersOf(verifier, id);
    const dir = workdir("tron");
    const currentPath = writeJson(dir, "current.json", current);
    const out = join(dir, "advance.json");
    proofPy(["advance", currentPath, latest.end, target, out]);
    const a = JSON.parse(readFileSync(out, "utf8"));
    const hash = await ethWallet.writeContract({
      address: verifier,
      abi: abi("TronStateVerifier"),
      functionName: "advance",
      args: [current, a.nextList, a.headers, BigInt(a.learnFrom), BigInt(a.vouchFrom)],
    });
    const receipt = await ethClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`advance reverted: ${hash}`);
    lists.set(id + 1n, a.nextList);
    return id + 1n;
  }

  /// The id of the recorded list whose period holds `at`, advancing the verifier to it when it lies ahead.
  async function listFor(verifier, at) {
    let id = await advanceTo(verifier, at);
    for (;;) {
      const record = await verifierRead(verifier, "producerList", [id]);
      if (at >= record.start && at < record.end) return { id, record };
      if (at >= record.end || id === 0n) throw new Error(`no list of the verifier covers ${at}`);
      id -= 1n;
    }
  }

  /// Waits until now lies clear of a period's ends, on the grid of the verifier's latest list.
  async function clearOfBoundary(verifier) {
    const latest = await verifierRead(verifier, "producerList", [await verifierRead(verifier, "latestList")]);
    for (;;) {
      const now = BigInt(Date.now());
      const into = (((now - latest.end) % INTERVAL) + INTERVAL) % INTERVAL;
      if (into >= AFTER_START && into < INTERVAL - BEFORE_END) return;
      const wait = into < AFTER_START ? AFTER_START - into : INTERVAL - into + AFTER_START;
      await sleep(Number(wait));
    }
  }

  return {
    chainId,

    /// Deposits `amount` of `token` (the zero address for TRX, in sun) into `vault` under `intakeId` for `index`.
    async deposit(vault, index, intakeId, token, amount) {
      if (token === ZERO) return send(vault, "XindexVault", "deposit", [index, intakeId], amount);
      await send(token, "IERC20", "approve", [vault, amount]);
      return send(vault, "XindexVault", "depositToken", [index, intakeId, token, amount]);
    },

    readDeposited(vault, index, intakeId, token, depositor) {
      return read(vault, "XindexVault", "deposited", [index, intakeId, token, depositor]);
    },

    async holds(token) {
      if (token === ZERO) return BigInt(await tw.trx.getBalance(me));
      return read(token, "IERC20", "balanceOf", [meHex]);
    },

    recipient() {
      return pad(meHex, { size: 32 });
    },

    /// Keeps the verifier within its day: records the list of the period in progress once the latest is half a day old.
    async follow(verifier) {
      const latest = await verifierRead(verifier, "producerList", [await verifierRead(verifier, "latestList")]);
      const now = BigInt(Date.now());
      if (now < latest.start + REFRESH_AFTER) return;
      // The period in progress, unless it began too recently for its round to be read: then the one before.
      return advanceTo(verifier, now - AFTER_START);
    },

    /// The `ChainProof` of `index`'s intake on `vault`: an attest of its digest, proven as a call, with its tokens and
    /// totals. `TronStateVerifier.verifySlots` takes `abi.encode(CallProof, values)` and writes the attest's calldata
    /// from the slots and values itself.
    async intakeProof(verifier, vault, index, intakeId) {
      const slot = intakeSlot(index, intakeId);
      const digest = await read(vault, "XindexVault", "intakeDigest", [index, intakeId]);
      await clearOfBoundary(verifier);
      const { txid, info } = await send(vault, "XindexVault", "attest", [[slot], [digest]]);
      const { id, record } = await listFor(verifier, BigInt(info.blockTimeStamp));
      const producers = await producersOf(verifier, id);

      const dir = workdir("tron");
      const out = join(dir, "call.json");
      proofPy(["call", txid, writeJson(dir, "list.json", producers), record.start, record.end, out]);
      const p = JSON.parse(readFileSync(out, "utf8"));
      const expected = encode("XindexVault", "attest", [[slot], [digest]]).data;
      if (p.data !== expected.toLowerCase() || getAddress(p.target) !== getAddress(vault)) {
        throw new Error(`transaction ${txid} is not the attest sent`);
      }
      const proof = encodeAbiParameters(PROOF, [
        { list: id, producers, transaction: p.transaction, path: p.path, sides: BigInt(p.sides), headers: p.headers },
        [digest],
      ]);

      const tokens = await read(vault, "XindexVault", "intakeTokens", [index, intakeId]);
      const totals = [];
      for (const t of tokens) totals.push(await read(vault, "XindexVault", "intakeTotal", [index, intakeId, t]));
      return { proof, tokens, totals };
    },
  };
}
