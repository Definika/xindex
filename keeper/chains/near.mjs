// The filler's NEAR adapter. DRAFT, untested (2026-10-06).
//
// NEAR's vault (`near/`) holds NEAR, in yoctoNEAR, at a keyless account. Its 32-byte id is keccak256 of that account
// id, and the hub names it by the id's low 20 bytes. A fill's NEAR leg is deposited with `deposit(index, intake_id,
// amount)`, the call's attached NEAR covering the amount and the storage it adds; the vault refunds the rest.
//
// The vault's intake digest reaches Ethereum through `NearStateVerifier`, which proves a successful `attest` receipt
// under a head it recorded. So the adapter has the vault attest the digest's slot and its value, then builds the
// receipt's `AttestProof` with `proofs/near/fixtures/attest_input.py`. When no recorded head lies above the receipt's
// outcome, the same builder writes the `near` SP1 host's input for an update that records one, which this adapter
// proves and sends first. `follow` keeps the verifier within its day between fills.
import { Account, JsonRpcProvider, KeyPair, KeyPairSigner, KeyType } from "near-api-js";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { encodeAbiParameters, keccak256, pad, parseAbiParameters, stringToBytes, toHex } from "viem";
import { abi } from "../artifacts.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, prove, run, workdir } from "./sp1.mjs";

/// The factory's registry ids of NEAR's networks (`design/2026-10-03-near-stellar-interfaces.md`,
/// `DeployStateVerifier.NEAR_MAINNET` and `NEAR_TESTNET`).
export const NEAR_MAINNET = 339_552_387_624_818_629n;
export const NEAR_TESTNET = 4_078_699_518_750_379_172n;

const ZERO = "0x0000000000000000000000000000000000000000";
/// `HybridHubStorage.INTAKE_DIGEST_DOMAIN` and `INTAKE_OPEN`.
const INTAKE_DIGEST_DOMAIN = keccak256(stringToBytes("xindex.v4.vault.intake-digest"));
const INTAKE_OPEN = 1;
const TGAS = 10n ** 12n;
const ONE_NEAR = 10n ** 24n;
/// Attached to a deposit beyond its amount, for the storage it adds: three records at most, well under a kilobyte at
/// 1e19 yoctoNEAR a byte. The vault refunds what it does not charge.
const STORAGE = ONE_NEAR / 20n;
/// Kept back from `holds` for that storage and for gas.
const RESERVE = ONE_NEAR / 10n;
const NS = 10n ** 9n;
/// Update the verifier once the producers in force were named this long ago; it stops at a day (`MAX_LAG`). A set is
/// named an epoch (about 7.2 hours) before it serves, so a verifier this far behind is an epoch or more behind NEAR,
/// and an update moves `namedAt` to within an epoch of now.
const REFRESH_AFTER = 16n * 3600n;
/// How far back the verifier's `Advanced` events are searched for a recorded head, in Ethereum blocks (two hours).
/// The receipt is minutes old, so an older head never lies above it.
const HEAD_LOOKBACK = 600n;
const PATH = "(bytes32 hash, bool left)[]";
/// `INearStateVerifier.AttestProof`, field by field, which `verifySlots` decodes with `abi.decode(proof, (AttestProof))`.
const ATTEST_PROOF = parseAbiParameters(
  `(bytes32 head, bytes32 receiptId, bytes32[] receiptIds, uint64 gasBurnt, uint128 tokensBurnt, bytes[] logs, ${PATH} outcomePath, ${PATH} outcomeRootPath, ((uint64 height, bytes32 epochId, bytes32 nextEpochId, bytes32 prevStateRoot, bytes32 outcomeRoot, uint64 timestamp, bytes32 nextBpHash, bytes32 blockMerkleRoot) innerLite, bytes32 innerRestHash, bytes32 prevBlockHash) blockHeader, ${PATH} blockPath, uint64 height, uint64 timestamp, bytes32[] values)`,
);
const DIGEST = parseAbiParameters("bytes32, uint256, bytes32, address, uint256, uint8, address[], uint256[]");

/// The adapter for NEAR. `accountId` is the filler's account, whose key (`privateKey`, `ed25519:...`, or a near-cli
/// credentials file at `keyPath`) signs its deposits and `attest` calls; `vaultId` is the vault's account id;
/// `network` is `mainnet` or `testnet`.
export function nearChain({ rpc, accountId, keyPath, privateKey, vaultId, network = "mainnet", ethClient, ethWallet }) {
  const secret = privateKey ?? (() => {
    const file = JSON.parse(readFileSync(keyPath, "utf8"));
    return file.private_key ?? file.secret_key;
  })();
  if (!secret) throw new Error("NEAR: a privateKey or a keyPath holding one is required");
  const keyPair = KeyPair.fromString(secret);
  const provider = new JsonRpcProvider({ url: rpc });
  const account = new Account(accountId, provider, KeyPairSigner.fromSecretKey(secret));
  const chainId = network === "testnet" ? NEAR_TESTNET : NEAR_MAINNET;
  const vaultWord = keccak256(stringToBytes(vaultId));
  const vaultAddress = `0x${vaultWord.slice(-40)}`;

  const hex20 = (address) => address.toLowerCase();
  const hex32 = (n) => pad(toHex(n), { size: 32 });
  const readV = (verifier, functionName, args = []) =>
    ethClient.readContract({ address: verifier, abi: abi("NearStateVerifier"), functionName, args });

  /// The filler's 32-byte recipient word: the ed25519 key whose implicit account the vault pays (the interfaces doc's
  /// encoding: top 12 bytes non-zero, so the vault reads it as `hex(key)`). An implicit filler account is that account;
  /// a named one is paid through its own key's implicit account, which the same key controls.
  const publicKey = keyPair.getPublicKey();
  if (publicKey.keyType !== KeyType.ED25519) throw new Error("NEAR: the filler's key must be ed25519");
  const recipientWord = toHex(publicKey.data);
  if (/^[0-9a-f]{64}$/.test(accountId) && `0x${accountId}` !== recipientWord) {
    throw new Error(`NEAR: ${accountId} is an implicit account of another key`);
  }
  // Not checked: a key whose top 12 bytes are all zero would be read as an ETH-implicit account instead (`types.rs`
  // `account_of`), a 2^-96 chance for a random ed25519 key.

  function checkVault(vault) {
    if (vault.toLowerCase() !== vaultAddress) throw new Error(`NEAR: vault ${vault} is not ${vaultId} (${vaultAddress})`);
  }

  /// A view of the vault, at the optimistic head, so a deposit just made is seen and never repeated.
  async function viewText(method, args) {
    const { result } = await provider.callFunctionRaw({ contractId: vaultId, method, args, blockQuery: { finality: "optimistic" } });
    return new TextDecoder().decode(Uint8Array.from(result));
  }
  const view = async (method, args) => JSON.parse(await viewText(method, args));

  let configChecked = false;
  /// The vault's own `config`: its registry id and vault id must be the ones this adapter proves against. Read as text,
  /// since `chain_id` is a JSON number past 2^53.
  async function checkConfig() {
    if (configChecked) return;
    const text = await viewText("config", {});
    const id = /"chain_id":(\d+)/.exec(text);
    const vid = /"vault_id":"(0x[0-9a-f]{64})"/.exec(text);
    if (!id || BigInt(id[1]) !== chainId || !vid || vid[1] !== vaultWord) {
      throw new Error(`NEAR: ${vaultId}'s config names another chain or vault id`);
    }
    configChecked = true;
  }

  async function send(methodName, args, deposit, gas) {
    // Throws on a failed receipt (`throwOnFailure`); waits until the blocks are final, so the outcome can be proven.
    return account.callFunctionRaw({ contractId: vaultId, methodName, args, deposit, gas, waitUntil: "FINAL" });
  }

  /// The intake's digest slot value and the `tokens` and `totals` it commits to, checked against the digest the hub
  /// computes (`HybridHubStorage._intakeDigest`): NEAR's vault holds only NEAR, `address(0)` on Ethereum.
  async function intakeState(index, intakeId, slot) {
    const value = await view("slot", { slot });
    const intake = await view("intake", { index: hex20(index), intake_id: hex32(intakeId) });
    if (!intake || intake.state !== INTAKE_OPEN) throw new Error(`NEAR: intake ${hex32(intakeId)} is not open`);
    const total = BigInt(intake.total);
    // An open intake holds NEAR exactly when its total is not zero; both forms are tried for a zero total.
    const forms = total === 0n ? [[[], []], [[ZERO], [0n]]] : [[[ZERO], [total]]];
    for (const [tokens, totals] of forms) {
      const digest = keccak256(encodeAbiParameters(DIGEST, [INTAKE_DIGEST_DOMAIN, chainId, vaultWord, index, intakeId, INTAKE_OPEN, tokens, totals]));
      if (digest === value && intake.digest === value) return { value, tokens, totals };
    }
    throw new Error(`NEAR: the vault's digest ${value} for intake ${hex32(intakeId)} is not the one the hub computes`);
  }

  /// Heads the verifier recorded lately, as the builder's `--head` takes them.
  async function recordedHeads(verifier) {
    const latest = await ethClient.getBlockNumber();
    const events = await ethClient.getContractEvents({
      address: verifier,
      abi: abi("NearStateVerifier"),
      eventName: "Advanced",
      fromBlock: latest > HEAD_LOOKBACK ? latest - HEAD_LOOKBACK : 0n,
      toBlock: latest,
    });
    return events.map((e) => `${e.args.blockMerkleRoot}:${e.args.height}`);
  }

  /// `attest_input.py`, from `proofs/near/fixtures`, which imports the generator's checks beside it.
  function builder(args) {
    return run("uv", ["run", "--with", "pynacl", "--with", "pycryptodome", "python3", "attest_input.py", ...args], join(ROOT, "proofs", "near", "fixtures"));
  }

  /// Proves `update.input` with the `near` host and records its head in the verifier.
  async function proveUpdate(verifier, update) {
    const [named, lag] = await Promise.all([readV(verifier, "namedAt"), readV(verifier, "MAX_LAG")]);
    const now = (await ethClient.getBlock()).timestamp;
    if (now > BigInt(named) / NS + lag) {
      throw new Error(`NearStateVerifier ${verifier} is past its day: no update can move it, and the chain registry must replace it`);
    }
    const p = prove("near", "near", [update.input]);
    if (p.publicValues.toLowerCase() !== update.publicValues.toLowerCase()) {
      throw new Error("NEAR: the proof commits other public values than the statement computed");
    }
    const hash = await ethWallet.writeContract({ address: verifier, abi: abi("NearStateVerifier"), functionName: "update", args: [p.publicValues, p.proof] });
    const receipt = await ethClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`NearStateVerifier.update reverted: ${hash}`);
  }

  /// The builder's `attestProof`, its decimal strings as integers.
  function attestProof(a) {
    const lite = a.blockHeader.innerLite;
    return {
      ...a,
      gasBurnt: BigInt(a.gasBurnt),
      tokensBurnt: BigInt(a.tokensBurnt),
      blockHeader: { ...a.blockHeader, innerLite: { ...lite, height: BigInt(lite.height), timestamp: BigInt(lite.timestamp) } },
      height: BigInt(a.height),
      timestamp: BigInt(a.timestamp),
    };
  }

  return {
    chainId,

    /// Keeps `verifier` within its day: once the producers in force were named REFRESH_AFTER ago, proves an update to
    /// NEAR's final head, which crosses into a later epoch and so moves `namedAt`.
    async follow(verifier, vault) {
      checkVault(vault);
      const named = BigInt(await readV(verifier, "namedAt"));
      const now = (await ethClient.getBlock()).timestamp;
      if (now < named / NS + REFRESH_AFTER) return;
      const [epoch, producers] = await Promise.all([readV(verifier, "epochId"), readV(verifier, "producersHash")]);
      const path = join(workdir("near"), "update.json");
      const update = JSON.parse(builder(["update", "--rpc", rpc, "--epoch", epoch, "--producers", producers, "--out", path]));
      // The fifth public word is `namedAt`: zero when the update stays in the verifier's epoch, which moves nothing.
      if (BigInt(`0x${update.publicValues.slice(2 + 4 * 64, 2 + 5 * 64)}`) === 0n) return;
      await proveUpdate(verifier, update);
    },

    /// Deposits `amount` yoctoNEAR into `vault` under `intakeId` for `index`.
    async deposit(vault, index, intakeId, token, amount) {
      checkVault(vault);
      if (token !== ZERO) throw new Error("NEAR's vault holds NEAR only");
      await checkConfig();
      return send("deposit", { index: hex20(index), intake_id: hex32(intakeId), amount: amount.toString() }, amount + STORAGE, 30n * TGAS);
    },

    /// What this filler's NEAR account deposited under `intakeId`. The vault books a deposit by the depositing account
    /// id, so the depositor the filler passes, an Ethereum address, is not used.
    async readDeposited(vault, index, intakeId, token, _depositor) {
      checkVault(vault);
      if (token !== ZERO) return 0n;
      return BigInt(await view("deposited", { index: hex20(index), intake_id: hex32(intakeId), depositor: accountId }));
    },

    /// The filler's available NEAR, less RESERVE for storage and gas.
    async holds(token) {
      if (token !== ZERO) return 0n;
      const available = await account.getBalance();
      return available > RESERVE ? available - RESERVE : 0n;
    },

    recipient() {
      return recipientWord;
    },

    /// The `ChainProof` of `index`'s intake on `vault`: `abi.encode(AttestProof)` for `NearStateVerifier.verifySlots`,
    /// with the vault's tokens and totals.
    async intakeProof(verifier, vault, index, intakeId) {
      checkVault(vault);
      await checkConfig();
      const [vid, cid] = await Promise.all([readV(verifier, "VAULT_ID"), readV(verifier, "CHAIN_ID")]);
      if (vid !== vaultWord || cid !== chainId) throw new Error(`NEAR: verifier ${verifier} serves another vault or chain`);

      // 1. The vault attests the intake digest's slot and value. A deposit landing in between fails the call
      //    (`NotAttested`); the next pass reads again.
      const slot = intakeSlot(index, intakeId);
      const { value, tokens, totals } = await intakeState(index, intakeId, slot);
      const tx = await send("attest", { slots: [slot], values: [value] }, 0n, 10n * TGAS);

      // 2. The receipt's proof under a recorded head, or under a new one with the update that records it.
      const [epoch, producers, heads] = await Promise.all([readV(verifier, "epochId"), readV(verifier, "producersHash"), recordedHeads(verifier)]);
      const path = join(workdir("near"), "attest.json");
      builder([
        "attest", "--rpc", rpc, "--vault", vaultId, "--chain-id", chainId.toString(), "--tx", tx.transaction.hash,
        "--signer", accountId, "--slots", slot, "--values", value, "--epoch", epoch, "--producers", producers,
        ...heads.flatMap((h) => ["--head", h]), "--out", path,
      ]);
      const out = JSON.parse(readFileSync(path, "utf8"));
      if (out.update) await proveUpdate(verifier, out.update);
      if ((await readV(verifier, "head", [out.attestProof.head])).height === 0n) {
        throw new Error(`NEAR: head ${out.attestProof.head} is not recorded`);
      }

      // 3. The proof, checked through the verifier's own view before the hub sees it.
      const proof = encodeAbiParameters(ATTEST_PROOF, [attestProof(out.attestProof)]);
      const [, , values] = await readV(verifier, "verifySlots", [vault, [slot], proof]);
      if (values[0] !== value) throw new Error(`NEAR: the verifier reads ${values[0]}, the vault attested ${value}`);
      return { proof, tokens, totals };
    },
  };
}
