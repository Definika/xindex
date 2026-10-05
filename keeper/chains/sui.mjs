// The filler's Sui adapter. DRAFT, untested (2026-10-06).
//
// Sui's vault is the Move twin (`sui/`), holding SUI only. A slot reaches Ethereum with no zkVM: the vault's `attest`
// freezes an `Attestation` object whose record holds the slots and values, and `SuiStateVerifier` checks the
// checkpoint that wrote it, certified by its epoch's committee (BLS12-381 on EIP-2537), and the object's leaf in the
// checkpoint's artifacts tree. The verifier follows one committee at a time, epoch by epoch, from each epoch's last
// checkpoint; `follow` keeps it on the epoch in progress, and `intakeProof` brings it to the attestation's epoch first.
// `sui/proof.py` builds every proof from Sui's GraphQL.
//
// The hub knows the vault by the low 20 bytes of its 32-byte object id, so the adapter is given the whole id, and the
// package, and checks both against the verifier.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { bcs } from "@mysten/sui/bcs";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { encodeAbiParameters, hexToBytes, numberToHex, parseAbiParameters, toHex } from "viem";
import { abi } from "../artifacts.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, run, workdir } from "./sp1.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const RETRIES = 10;
const ATTEST_PROOF = parseAbiParameters([
  "AttestProof",
  "struct AttestProof { Committee committee; Checkpoint checkpoint; Certificate certificate; bytes32 objectId; uint64 version; bytes32 previousTransaction; uint64 storageRebate; uint64 timestampMs; bytes32[] values; uint256 leafIndex; bytes32[] path; }",
  "struct Committee { bytes keys; uint64[] powers; }",
  "struct Checkpoint { uint64 epoch; uint64 sequenceNumber; uint64 networkTotalTransactions; bytes32 contentDigest; bytes32 previousDigest; uint64[4] epochRollingGasCostSummary; uint64 timestampMs; Commitment[] checkpointCommitments; bytes rest; }",
  "struct Commitment { uint8 kind; bytes32 digest; }",
  "struct Certificate { bytes signature; uint256[] signers; }",
]);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const bytes = (hex) => Array.from(hexToBytes(hex));

const committeeArg = (c) => ({ keys: c.keys, powers: c.powers.map(BigInt) });
const checkpointArg = (c) => ({
  epoch: BigInt(c.epoch),
  sequenceNumber: BigInt(c.sequenceNumber),
  networkTotalTransactions: BigInt(c.networkTotalTransactions),
  contentDigest: c.contentDigest,
  previousDigest: c.previousDigest,
  epochRollingGasCostSummary: c.gas.map(BigInt),
  timestampMs: BigInt(c.timestampMs),
  checkpointCommitments: c.commitmentKinds.map((kind, i) => ({ kind, digest: c.commitmentDigests[i] })),
  rest: c.rest,
});
const certificateArg = (c) => ({ signature: c.signature, signers: c.signers.map(BigInt) });

export function suiChain({ rpc, graphql, key, vaultId, packageId, ethClient, ethWallet, chainId = 13762264207064992463n }) {
  // Sui's public full nodes serve gRPC; their JSON-RPC is retired.
  rpc ??= "https://fullnode.mainnet.sui.io:443";
  graphql ??= "https://graphql.mainnet.sui.io/graphql";
  const client = new SuiGrpcClient({ network: "mainnet", baseUrl: rpc });
  const signer = Ed25519Keypair.fromSecretKey(decodeSuiPrivateKey(key).secretKey);
  const me = signer.toSuiAddress();
  const target = (fn) => `${packageId}::vault::${fn}`;

  /// The BCS return values of a view, run read-only.
  async function view(fn, args) {
    const tx = new Transaction();
    tx.setSender(me);
    tx.moveCall({ target: target(fn), arguments: args(tx) });
    const r = await client.simulateTransaction({ transaction: tx, include: { commandResults: true } });
    if (r.$kind !== "Transaction") throw new Error(`${fn} failed on Sui: ${JSON.stringify(r.FailedTransaction.status)}`);
    return r.commandResults.at(-1).returnValues.map((v) => v.bcs);
  }

  async function execute(tx, label) {
    const r = await client.signAndExecuteTransaction({ transaction: tx, signer });
    if (r.$kind !== "Transaction") throw new Error(`${label} failed on Sui: ${r.FailedTransaction.digest} ${JSON.stringify(r.FailedTransaction.status)}`);
    const digest = r.Transaction.digest;
    // Until a checkpoint holds it, a transaction has no checkpoint to prove.
    for (let i = 0; i < RETRIES; ++i) {
      const done = await client.waitForTransaction({ digest, include: { effects: true, objectTypes: true } });
      if (done.Transaction?.checkpoint) return done.Transaction;
      await sleep(2000);
    }
    throw new Error(`${label}: ${digest} is in no checkpoint yet`);
  }

  const indexArg = (tx, index) => tx.pure.vector("u8", bytes(index));
  const intakeArg = (tx, intakeId) => tx.pure.vector("u8", bytes(numberToHex(intakeId, { size: 32 })));

  async function intake(index, intakeId) {
    const [state, total, digest] = await view("intake", (tx) => [tx.object(vaultId), indexArg(tx, index), intakeArg(tx, intakeId)]);
    return { state: state[0], total: bcs.u64().parse(total), digest: toHex(bcs.vector(bcs.u8()).parse(digest)) };
  }

  const verifierRead = (verifier, functionName) => ethClient.readContract({ address: verifier, abi: abi("SuiStateVerifier"), functionName });

  function proofPy(args) {
    const out = join(workdir("sui"), "out.json");
    for (let i = 0; ; ++i) {
      try {
        run("python3", [join("sui", "proof.py"), graphql, ...args.map(String), out], ROOT);
        return JSON.parse(readFileSync(out, "utf8"));
      } catch (error) {
        // The GraphQL service indexes a checkpoint shortly after it is certified.
        if (i + 1 >= 3) throw error;
      }
    }
  }

  /// Moves the verifier on, one epoch at a time, until it is in `epoch`.
  async function advanceTo(verifier, epoch) {
    for (let e = BigInt(await verifierRead(verifier, "epoch")); e < epoch; ++e) {
      const u = proofPy(["update", e]);
      const hash = await ethWallet.writeContract({
        address: verifier,
        abi: abi("SuiStateVerifier"),
        functionName: "update",
        args: [committeeArg(u.current), checkpointArg(u.checkpoint), certificateArg(u.certificate), { sources: u.next.sources, newKeys: u.next.newKeys, powers: u.next.powers.map(BigInt) }],
      });
      const receipt = await ethClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error(`Sui update reverted: ${hash}`);
    }
  }

  return {
    chainId,

    /// Deposits `amount` of SUI (in MIST) into the vault under `intakeId` for `index`. The vault holds SUI only.
    async deposit(_vault, index, intakeId, token, amount) {
      if (token !== ZERO) throw new Error(`the Sui vault holds SUI only, not ${token}`);
      const tx = new Transaction();
      const [coin] = tx.splitCoins(tx.gas, [amount]);
      tx.moveCall({ target: target("deposit"), arguments: [tx.object(vaultId), indexArg(tx, index), intakeArg(tx, intakeId), coin, tx.object.clock()] });
      return execute(tx, "deposit");
    },

    /// What this filler deposited: the depositor the filler passes is cut to 20 bytes, so the adapter's own address
    /// is used.
    async readDeposited(_vault, index, intakeId) {
      const [amount] = await view("deposited", (tx) => [tx.object(vaultId), indexArg(tx, index), intakeArg(tx, intakeId), tx.pure.address(me)]);
      return BigInt(bcs.u64().parse(amount));
    },

    async holds(token) {
      if (token !== ZERO) return 0n;
      return BigInt((await client.getBalance({ owner: me })).balance.balance);
    },

    /// The filler's Sui address, a whole word.
    recipient() {
      return me;
    },

    async follow(verifier) {
      const current = BigInt((await client.getCurrentSystemState()).systemState.epoch);
      await advanceTo(verifier, current);
    },

    /// The `ChainProof` of `index`'s intake: the `AttestProof` of a fresh attestation of its digest, with the vault's
    /// one token, SUI as the zero address, and its total.
    async intakeProof(verifier, vault, index, intakeId) {
      const [vid, pkg] = [await verifierRead(verifier, "VAULT_ID"), await verifierRead(verifier, "PACKAGE_ID")];
      if (vid !== vaultId || pkg !== packageId) throw new Error("the adapter's vault or package is not the verifier's");
      if (vault.toLowerCase() !== `0x${vaultId.slice(-40)}`) throw new Error("the index's vault is not this one");

      const slot = intakeSlot(index, intakeId);
      const { total, digest } = await intake(index, intakeId);
      const tx = new Transaction();
      tx.moveCall({
        target: target("attest"),
        arguments: [
          tx.object(vaultId),
          tx.pure(bcs.vector(bcs.vector(bcs.u8())).serialize([bytes(slot)])),
          tx.pure(bcs.vector(bcs.vector(bcs.u8())).serialize([bytes(digest)])),
          tx.object.clock(),
        ],
      });
      const done = await execute(tx, "attest");
      const created = done.effects.changedObjects.find(
        (c) => c.idOperation === "Created" && done.objectTypes[c.objectId] === `${packageId}::vault::Attestation`,
      );
      if (!created) throw new Error(`attest ${done.digest} froze no attestation`);
      await advanceTo(verifier, BigInt(done.epoch));

      const a = proofPy(["attest", done.checkpoint, created.objectId]);
      if (a.slots[0] !== slot || a.values[0] !== digest) throw new Error("the attestation records another slot");
      const proof = encodeAbiParameters(ATTEST_PROOF, [{
        committee: committeeArg(a.committee),
        checkpoint: checkpointArg(a.checkpoint),
        certificate: certificateArg(a.certificate),
        objectId: a.objectId,
        version: BigInt(a.version),
        previousTransaction: a.previousTransaction,
        storageRebate: BigInt(a.storageRebate),
        timestampMs: BigInt(a.timestampMs),
        values: a.values,
        leafIndex: BigInt(a.leafIndex),
        path: a.path,
      }]);
      return { proof, tokens: total === "0" ? [] : [ZERO], totals: total === "0" ? [] : [BigInt(total)] };
    },
  };
}
