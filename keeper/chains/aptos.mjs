// The filler's Aptos adapter. DRAFT, untested (2026-10-06).
//
// Aptos's vault is the Move twin (`aptos/`), holding APT only. A slot reaches Ethereum as on NEAR and Stellar: the
// vault's entry function `attest` emits one `Attested` event whose record holds the slots and values, and
// `proofs/aptos` proves that transaction successful under a ledger info signed by more than two thirds of a set the
// verifier trusts, crossing epochs from it. Aptos's REST API serves no signatures or accumulator proofs, so the input
// comes from Aptos Labs' public database backups, which cover a version two to four hours after it ran; this adapter
// waits for them, within the fill's 6-hour delivery window. `follow` keeps the verifier's trusted set within its day.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  Account,
  AccountAddress,
  Aptos,
  AptosConfig,
  Ed25519PrivateKey,
  Network,
  PrivateKey,
  PrivateKeyVariants,
} from "@aptos-labs/ts-sdk";
import { encodeAbiParameters, hexToBytes, numberToHex, parseAbiParameters } from "viem";
import { abi } from "../artifacts.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, prove, workdir } from "./sp1.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const WAIT = 3; // input.py's exit status while the backup does not cover the version yet
const BACKUP_POLL = 20 * 60 * 1000;
const BACKUP_POLLS = 18; // six hours
const DAY_US = 86_400_000_000n;
const REFRESH_AFTER_US = 18n * 3_600_000_000n;
const SLOTS_PROOF = parseAbiParameters("(bytes publicValues, bytes proof, bytes32[] values)");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function aptosChain({ network = "mainnet", key, vault, packageAddress, ethClient, ethWallet, chainId = 549304973309166888n }) {
  const aptos = new Aptos(new AptosConfig({ network: network === "mainnet" ? Network.MAINNET : Network.TESTNET }));
  const account = Account.fromPrivateKey({
    privateKey: new Ed25519PrivateKey(PrivateKey.formatPrivateKey(key, PrivateKeyVariants.Ed25519)),
  });
  const me = account.accountAddress.toStringLong();
  // Long forms throughout: the proof writes the package's 32 bytes, and the views return the vault id so.
  vault = AccountAddress.from(vault).toStringLong();
  packageAddress = AccountAddress.from(packageAddress).toStringLong();
  const fn = (name) => `${packageAddress}::vault::${name}`;
  const index20 = (index) => hexToBytes(index);
  const intake32 = (intakeId) => hexToBytes(numberToHex(intakeId, { size: 32 }));

  const view = (name, args) => aptos.view({ payload: { function: fn(name), functionArguments: args } });

  async function submit(name, args) {
    const transaction = await aptos.transaction.build.simple({ sender: account.accountAddress, data: { function: fn(name), functionArguments: args } });
    const pending = await aptos.signAndSubmitTransaction({ signer: account, transaction });
    const done = await aptos.waitForTransaction({ transactionHash: pending.hash });
    if (!done.success) throw new Error(`${name} failed on Aptos: ${pending.hash} ${done.vm_status}`);
    return done;
  }

  const verifierRead = (verifier, functionName, args = []) =>
    ethClient.readContract({ address: verifier, abi: abi("AptosStateVerifier"), functionName, args });

  /// Runs `input.py`; returns the input file, or undefined while the backup does not cover what it needs.
  function buildInput(args) {
    const path = join(workdir("aptos"), "input.json");
    try {
      execFileSync("python3", ["input.py", network, ...args.map(String), path], {
        cwd: join(ROOT, "proofs", "aptos", "fixtures"),
        stdio: ["ignore", "inherit", "inherit"],
      });
      return path;
    } catch (error) {
      if (error.status === WAIT) return undefined;
      throw error;
    }
  }

  async function update(verifier) {
    const epoch = await verifierRead(verifier, "latestEpoch");
    const t = await verifierRead(verifier, "trusted", [epoch]);
    const path = buildInput(["update", epoch, t.set]);
    if (!path) return;
    const p = prove("aptos", "aptos", ["update", path]);
    const hash = await ethWallet.writeContract({ address: verifier, abi: abi("AptosStateVerifier"), functionName: "update", args: [p.publicValues, p.proof] });
    const receipt = await ethClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`Aptos update reverted: ${hash}`);
  }

  /// The verifier's latest trusted epoch at or before `epoch`, still within its day for a proof landing in `margin`.
  async function trustedAtOrBefore(verifier, epoch, marginUs) {
    const now = BigInt(Date.now()) * 1000n;
    let e = await verifierRead(verifier, "latestEpoch");
    if (e > epoch) e = epoch;
    for (; e > 0n; --e) {
      const t = await verifierRead(verifier, "trusted", [e]);
      if (t.set === `0x${"0".repeat(64)}`) continue;
      if (BigInt(t.time) + DAY_US < now + marginUs) break;
      return { epoch: e, set: t.set };
    }
    throw new Error(`the verifier trusts no set at or before epoch ${epoch} young enough`);
  }

  return {
    chainId,

    /// Deposits `amount` of APT (in octas) into the vault under `intakeId` for `index`. The vault holds APT only.
    async deposit(_vault, index, intakeId, token, amount) {
      if (token !== ZERO) throw new Error(`the Aptos vault holds APT only, not ${token}`);
      return submit("deposit", [vault, index20(index), intake32(intakeId), amount]);
    },

    /// What this filler deposited: the depositor the filler passes is cut to 20 bytes, so the adapter's own address
    /// is used.
    async readDeposited(_vault, index, intakeId) {
      const [amount] = await view("deposited", [vault, index20(index), intake32(intakeId), me]);
      return BigInt(amount);
    },

    async holds(token) {
      if (token !== ZERO) return 0n;
      return BigInt(await aptos.getAccountAPTAmount({ accountAddress: account.accountAddress }));
    },

    /// The filler's Aptos address, a whole word.
    recipient() {
      return me;
    },

    async follow(verifier) {
      const t = await verifierRead(verifier, "trusted", [await verifierRead(verifier, "latestEpoch")]);
      if (BigInt(Date.now()) * 1000n >= BigInt(t.time) + REFRESH_AFTER_US) await update(verifier);
    },

    /// The `ChainProof` of `index`'s intake: `abi.encode(SlotsProof{publicValues, proof, values})` of a fresh attest of
    /// its digest, with the vault's one token, APT as the zero address, and its total.
    async intakeProof(verifier, hubVault, index, intakeId) {
      const [vid] = await view("vault_id", [vault]);
      if (vid !== (await verifierRead(verifier, "VAULT_ID")) || hubVault.toLowerCase() !== `0x${vid.slice(-40)}`) {
        throw new Error("the adapter's vault is not the verifier's or the index's");
      }
      const slot = intakeSlot(index, intakeId);
      const [, total, digest] = await view("intake", [vault, index20(index), intake32(intakeId)]);
      const [epochNow] = await aptos.view({ payload: { function: "0x1::reconfiguration::current_epoch", functionArguments: [] } });
      const done = await submit("attest", [vault, [hexToBytes(slot)], [hexToBytes(digest)]]);

      let path;
      for (let i = 0; i < BACKUP_POLLS && !path; ++i) {
        const t = await trustedAtOrBefore(verifier, BigInt(epochNow), 3_600_000_000n);
        path = buildInput(["slots", t.epoch, t.set, done.version, packageAddress, vid]);
        if (!path) await sleep(BACKUP_POLL);
      }
      if (!path) throw new Error(`the backup does not cover version ${done.version} after six hours`);
      const input = JSON.parse(readFileSync(path, "utf8"));
      if (input.slots.slots[0] !== slot || input.slots.values[0] !== digest) throw new Error("the attest records another slot");
      const p = prove("aptos", "aptos", ["slots", path]);
      const proof = encodeAbiParameters(SLOTS_PROOF, [{ publicValues: p.publicValues, proof: p.proof, values: input.slots.values }]);
      return { proof, tokens: total === "0" ? [] : [ZERO], totals: total === "0" ? [] : [BigInt(total)] };
    },
  };
}
