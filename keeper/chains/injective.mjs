// The filler's Injective adapter. DRAFT, untested (2026-10-06).
//
// Injective runs `XindexVault` unchanged in its EVM (chain 1776), so deposits are as on BNB Chain. The vault's slots
// reach Ethereum through `CometBftStateVerifier`: an SP1 proof of CometBFT light-client hops from a header the verifier
// trusts, and ICS-23 proofs of the slots under the next header's app hash. This adapter builds the input with
// `proofs/cometbft/fixtures/input.py`, proves it with the `cometbft` host on the prover network, and keeps the verifier
// within its day by proving updates as it goes.
import { createPublicClient, createWalletClient, defineChain, encodeAbiParameters, http, parseAbiParameters } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { abi } from "../artifacts.mjs";
import { evmVaultOps } from "./evmvault.mjs";
import { intakeSlot } from "./slots.mjs";
import { ROOT, prove, run, workdir } from "./sp1.mjs";

const REFRESH_AFTER = 20n * 3600n; // update the verifier once its trusted header is this old; it stops at a day

export function injectiveChain({ rpc, key, ethClient, ethWallet }) {
  const chain = defineChain({
    id: 1776,
    name: "Injective EVM",
    nativeCurrency: { name: "Injective", symbol: "INJ", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const client = createPublicClient({ chain, transport: http(rpc) });
  const wallet = createWalletClient({ account: privateKeyToAccount(key), chain, transport: http(rpc) });
  const ops = evmVaultOps(client, wallet);

  async function trustedHeight(verifier) {
    const hash = await ethClient.readContract({ address: verifier, abi: abi("CometBftStateVerifier"), functionName: "latestHash" });
    const t = await ethClient.readContract({ address: verifier, abi: abi("CometBftStateVerifier"), functionName: "trusted", args: [hash] });
    return { height: BigInt(t.height), time: BigInt(t.time) };
  }

  /// The input for `cometbft prove`, from the verifier's trusted header to a recent one, with `slots` of `vault`.
  function buildInput(vault, trusted, slots) {
    const dir = workdir("injective");
    const path = join(dir, "input.json");
    run("uv", ["run", "--with", "pynacl", "--with", "pycryptodome", "python3", "input.py", vault, trusted.toString(), path, ...slots],
      join(ROOT, "proofs", "cometbft", "fixtures"));
    return { path, input: JSON.parse(readFileSync(path, "utf8")) };
  }

  /// Moves the verifier's trusted header forward when it is near its day, so a slots proof can start from it.
  async function keepFresh(verifier, vault) {
    const t = await trustedHeight(verifier);
    const now = (await ethClient.getBlock()).timestamp;
    if (now < t.time + REFRESH_AFTER) return t;
    const { path } = buildInput(vault, t.height, [intakeSlot(vault, 0n)]);
    const p = prove("cometbft", "cometbft", ["update", path]);
    const hash = await ethWallet.writeContract({ address: verifier, abi: abi("CometBftStateVerifier"), functionName: "update", args: [p.publicValues, p.proof] });
    await ethClient.waitForTransactionReceipt({ hash });
    return trustedHeight(verifier);
  }

  return {
    chainId: 1776n,
    deposit: ops.deposit,
    readDeposited: ops.readDeposited,
    holds: ops.holds,
    recipient: ops.recipient,

    /// The `ChainProof` of `index`'s intake on `vault`: `abi.encode(SlotsProof{publicValues, proof, values})` for
    /// `CometBftStateVerifier.verifySlots`, with the vault's tokens and totals.
    async intakeProof(verifier, vault, index, intakeId) {
      const t = await keepFresh(verifier, vault);
      const { path, input } = buildInput(vault, t.height, [intakeSlot(index, intakeId)]);
      const p = prove("cometbft", "cometbft", ["slots", path]);
      const proof = encodeAbiParameters(parseAbiParameters("(bytes publicValues, bytes proof, bytes32[] values)"), [
        { publicValues: p.publicValues, proof: p.proof, values: input.values },
      ]);
      return { proof, ...(await ops.intakeTotals(vault, index, intakeId)) };
    },
  };
}
