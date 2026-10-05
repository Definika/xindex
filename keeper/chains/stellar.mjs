// The filler's Stellar adapter. DRAFT, untested (2026-10-06).
//
// Stellar's vault (`stellar/contracts/xindex-vault`) is a Soroban contract holding XLM, in stroops, through the native
// asset's contract. Its 32-byte id is its contract id, the hash its `C...` address encodes, and the hub names it by the
// id's low 20 bytes. A fill's XLM leg is deposited with `deposit(from, index, intake_id, amount)`, `from` being the
// filler's account, which authorizes the native asset's transfer as the transaction's source.
//
// The vault's intake digest reaches Ethereum through `StellarStateVerifier`, which holds no state: each proof is an SP1
// proof that the vault's `attest` succeeded in a ledger the pinned Tier 1 quorum set externalized. So the adapter has
// the vault attest the digest's slot and its value, builds `stellar-proof prove`'s input for that transaction with
// `proofs/stellar/statement/examples/attest_input.rs` (from the RPC and SDF's history archive), proves it, and encodes
// the verifier's `SlotsProof`. The verifier refuses a ledger more than a day old, so the proof goes to `settleRebalance`
// as soon as it is made; nothing needs following between fills.
import {
  Account,
  Address,
  Asset,
  BASE_FEE,
  Contract,
  Keypair,
  Networks,
  StrKey,
  TransactionBuilder,
  nativeToScVal,
  rpc,
  scValToNative,
  xdr,
} from "@stellar/stellar-sdk";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { encodeAbiParameters, keccak256, parseAbiParameters, sha256, stringToBytes, toHex } from "viem";
import { abi } from "../artifacts.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, prove, run, workdir } from "./sp1.mjs";

/// The factory's registry ids of Stellar's networks (`design/2026-10-03-near-stellar-interfaces.md`,
/// `DeployStateVerifier.STELLAR_PUBNET` and `STELLAR_TESTNET`).
export const STELLAR_PUBNET = 839_718_837_228_939_926n;
export const STELLAR_TESTNET = 17_667_989_177_921_016_935n;

/// SDF's history archives, which keep every ledger's headers, transaction sets, results and SCP messages.
// TODO(verify): the testnet archive's path; the pubnet one is `generate.rs`'s.
const ARCHIVES = {
  pubnet: "https://history.stellar.org/prd/core-live/core_live_001",
  testnet: "https://history.stellar.org/prd/core-testnet/core_testnet_001",
};

const ZERO = "0x0000000000000000000000000000000000000000";
/// `HybridHubStorage.INTAKE_DIGEST_DOMAIN` and `INTAKE_OPEN`, and the verifier's `ATTEST_DOMAIN`.
const INTAKE_DIGEST_DOMAIN = keccak256(stringToBytes("xindex.v4.vault.intake-digest"));
const INTAKE_OPEN = 1;
const ATTEST_DOMAIN = keccak256(stringToBytes("xindex.v4.vault-attest"));
/// The vault books a deposit as a `u64` of stroops.
const MAX_DEPOSIT = 2n ** 64n - 1n;
/// Kept back from `holds` for fees: a Soroban call's resource fee is a fraction of an XLM.
const FEE_RESERVE = 20_000_000n;
/// The network's base reserve, 0.5 XLM: an account must keep two, and one more per subentry it holds or sponsors.
// TODO(verify): read from the latest ledger header if the network ever changes it; 0.5 XLM since protocol 10.
const BASE_RESERVE = 5_000_000n;
/// How long a submitted transaction is polled for, at a second's sleep: about two minutes.
const POLL_ATTEMPTS = 120;
const DIGEST = parseAbiParameters("bytes32, uint256, bytes32, address, uint256, uint8, address[], uint256[]");
const RECORD = parseAbiParameters("bytes32, uint256, bytes32, bytes32[], bytes32[]");
const SLOTS_PROOF = parseAbiParameters("(bytes publicValues, bytes proof, bytes32[] values)");

/// The adapter for Stellar. `secret` is the filler's account seed (`S...`), which signs and pays for its deposits and
/// `attest` calls; `vaultId` is the vault's contract address (`C...`); `network` is `pubnet` or `testnet`;
/// `quorumSetFile`, optional, holds the pinned quorum set's XDR as hex, for when the archive does not carry it.
export function stellarChain({ rpc: rpcUrl, secret, vaultId, network = "pubnet", archive, quorumSetFile, ethClient, ethWallet }) {
  const keypair = Keypair.fromSecret(secret);
  const server = new rpc.Server(rpcUrl, { allowHttp: rpcUrl.startsWith("http://") });
  const passphrase = network === "testnet" ? Networks.TESTNET : Networks.PUBLIC;
  const chainId = network === "testnet" ? STELLAR_TESTNET : STELLAR_PUBNET;
  const history = archive ?? ARCHIVES[network];
  const vaultWord = toHex(StrKey.decodeContract(vaultId));
  const vaultAddress = `0x${vaultWord.slice(-40)}`;
  const xlm = Asset.native().contractId(passphrase);

  const bytes = (hex) => xdr.ScVal.scvBytes(Buffer.from(hex.slice(2), "hex"));
  const hex20 = (address) => bytes(address.toLowerCase());
  const hex32 = (n) => bytes(toHex(n, { size: 32 }));
  const me = () => new Address(keypair.publicKey()).toScVal();
  const readV = (verifier, functionName, args = []) =>
    ethClient.readContract({ address: verifier, abi: abi("StellarStateVerifier"), functionName, args });

  function checkVault(vault) {
    if (vault.toLowerCase() !== vaultAddress) throw new Error(`Stellar: vault ${vault} is not ${vaultId} (${vaultAddress})`);
  }

  /// A read-only call, simulated: no signature, no fee, no sequence number.
  async function view(contractId, method, args) {
    const tx = new TransactionBuilder(new Account(keypair.publicKey(), "0"), { fee: BASE_FEE, networkPassphrase: passphrase })
      .addOperation(new Contract(contractId).call(method, ...args))
      .setTimeout(30)
      .build();
    const sim = await server.simulateTransaction(tx);
    if (rpc.Api.isSimulationError(sim)) throw new Error(`Stellar: ${method} failed in simulation: ${sim.error}`);
    return scValToNative(sim.result.retval);
  }

  /// A call signed by the filler's account: simulated for its footprint, resources and the source account's
  /// authorization, then submitted and polled until it lands.
  async function invoke(contractId, method, args) {
    const source = await server.getAccount(keypair.publicKey());
    const tx = new TransactionBuilder(source, { fee: BASE_FEE, networkPassphrase: passphrase })
      .addOperation(new Contract(contractId).call(method, ...args))
      .setTimeout(120)
      .build();
    const prepared = await server.prepareTransaction(tx);
    prepared.sign(keypair);
    const sent = await server.sendTransaction(prepared);
    if (sent.status !== "PENDING") throw new Error(`Stellar: ${method} not accepted (${sent.status}): ${sent.hash}`);
    const landed = await server.pollTransaction(sent.hash, { attempts: POLL_ATTEMPTS, sleepStrategy: rpc.BasicSleepStrategy });
    if (landed.status !== "SUCCESS") throw new Error(`Stellar: ${method} ${landed.status}: ${sent.hash}`);
    return { hash: sent.hash, ledger: landed.ledger };
  }

  let configChecked = false;
  /// The vault's own `config` and id: the registry id and vault id this adapter proves against.
  async function checkConfig() {
    if (configChecked) return;
    const [config, id] = await Promise.all([view(vaultId, "config", []), view(vaultId, "vault_id", [])]);
    if (BigInt(config.chain_id) !== chainId || toHex(id) !== vaultWord || config.xlm !== xlm) {
      throw new Error(`Stellar: ${vaultId}'s config names another chain, vault id or native asset`);
    }
    configChecked = true;
  }

  /// The intake's digest slot value and the `tokens` and `totals` it commits to, checked against the digest the hub
  /// computes (`HybridHubStorage._intakeDigest`): Stellar's vault holds only XLM, `address(0)` on Ethereum.
  async function intakeState(index, intakeId, slot) {
    const value = toHex(await view(vaultId, "slot", [bytes(slot)]));
    const intake = await view(vaultId, "intake", [hex20(index), hex32(intakeId)]);
    if (!intake || Number(intake.state) !== INTAKE_OPEN) throw new Error(`Stellar: intake ${toHex(intakeId, { size: 32 })} is not open`);
    const tokens = intake.has_native ? [ZERO] : [];
    const totals = intake.has_native ? [BigInt(intake.total)] : [];
    const digest = keccak256(encodeAbiParameters(DIGEST, [INTAKE_DIGEST_DOMAIN, chainId, vaultWord, index, intakeId, INTAKE_OPEN, tokens, totals]));
    if (digest !== value) throw new Error(`Stellar: the vault's digest ${value} is not the one the hub computes, ${digest}`);
    return { value, tokens, totals };
  }

  return {
    chainId,

    /// Deposits `amount` stroops into `vault` under `intakeId` for `index`.
    async deposit(vault, index, intakeId, token, amount) {
      checkVault(vault);
      if (token !== ZERO) throw new Error("Stellar's vault holds XLM only");
      if (amount > MAX_DEPOSIT) throw new Error(`Stellar: ${amount} stroops do not fit the vault's book`);
      await checkConfig();
      return invoke(vaultId, "deposit", [me(), hex20(index), hex32(intakeId), nativeToScVal(amount, { type: "i128" })]);
    },

    /// What this filler's account deposited under `intakeId`. The vault books a deposit by the Stellar account that
    /// made it, so the depositor the filler passes, an Ethereum address, is not used.
    async readDeposited(vault, index, intakeId, token, _depositor) {
      checkVault(vault);
      if (token !== ZERO) return 0n;
      return BigInt(await view(vaultId, "deposited", [hex20(index), hex32(intakeId), me()]));
    },

    /// The XLM the filler's account can spend: its balance less its minimum balance (two base reserves, one per
    /// subentry and sponsored entry), its selling liabilities and FEE_RESERVE. The native asset contract's `balance`
    /// is the gross figure (checked on mainnet, 2026-10-06), so it is not used here.
    async holds(token) {
      if (token !== ZERO) return 0n;
      const e = await server.getAccountEntry(keypair.publicKey());
      const v1 = e.ext?.v1;
      const v2 = v1?.ext?.v2;
      // stellar-sdk 17's `AccountEntry`: camelCase fields, the extensions' arms as properties.
      const entries = 2n + BigInt(e.numSubEntries) + BigInt(v2?.numSponsoring ?? 0) - BigInt(v2?.numSponsored ?? 0);
      const locked = entries * BASE_RESERVE + BigInt(v1?.liabilities?.selling ?? 0) + FEE_RESERVE;
      const balance = BigInt(e.balance);
      return balance > locked ? balance - locked : 0n;
    },

    /// The filler's account's ed25519 key: a burn pays the Stellar account (`G...`) it names (interfaces doc).
    recipient() {
      return toHex(keypair.rawPublicKey());
    },

    /// The `ChainProof` of `index`'s intake on `vault`: `abi.encode(SlotsProof{publicValues, proof, values})` for
    /// `StellarStateVerifier.verifySlots`, with the vault's tokens and totals.
    async intakeProof(verifier, vault, index, intakeId) {
      checkVault(vault);
      await checkConfig();
      const [vid, cid, networkId, quorumSetHash] = await Promise.all([
        readV(verifier, "VAULT_ID"),
        readV(verifier, "CHAIN_ID"),
        readV(verifier, "NETWORK_ID"),
        readV(verifier, "QUORUM_SET_HASH"),
      ]);
      if (vid !== vaultWord || cid !== chainId || networkId !== sha256(stringToBytes(passphrase))) {
        throw new Error(`Stellar: verifier ${verifier} serves another vault, chain or network`);
      }

      // 1. The vault attests the intake digest's slot and value, in one event. A deposit landing in between fails the
      //    call (`NotAttested`); the next pass reads again.
      const slot = intakeSlot(index, intakeId);
      const { value, tokens, totals } = await intakeState(index, intakeId, slot);
      const tx = await invoke(vaultId, "attest", [xdr.ScVal.scvVec([bytes(slot)]), xdr.ScVal.scvVec([bytes(value)])]);

      // 2. The prover's input for that transaction, once the archive has published its ledger's checkpoint, checked by
      //    the statement natively; then the proof.
      const path = join(workdir("stellar"), "input.json");
      run(
        "cargo",
        [
          "run", "--release", "-q", "-p", "xindex-stellar", "--example", "attest_input", "--",
          rpcUrl, history, passphrase, tx.hash, vaultWord, quorumSetHash, path, quorumSetFile ?? "",
        ],
        join(ROOT, "proofs", "stellar"),
      );
      const input = JSON.parse(readFileSync(path, "utf8"));
      const record = encodeAbiParameters(RECORD, [ATTEST_DOMAIN, chainId, vaultWord, [slot], [value]]);
      if (`0x${input.record}` !== record) throw new Error("Stellar: the attested record is not this intake's");
      const p = prove("stellar", "stellar-proof", [path]);
      if (p.publicValues.toLowerCase() !== input.publicValues.toLowerCase()) {
        throw new Error("Stellar: the proof commits other public values than the statement computed");
      }

      // 3. The proof, checked through the verifier's own view before the hub sees it.
      const proof = encodeAbiParameters(SLOTS_PROOF, [{ publicValues: p.publicValues, proof: p.proof, values: [value] }]);
      const [, , values] = await readV(verifier, "verifySlots", [vault, [slot], proof]);
      if (values[0] !== value) throw new Error(`Stellar: the verifier reads ${values[0]}, the vault attested ${value}`);
      return { proof, tokens, totals };
    },
  };
}
