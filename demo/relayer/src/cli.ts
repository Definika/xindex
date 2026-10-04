// TESTNETS ONLY: the demo's command line. `npm run cli -- <command>`; see demo/README.md for the order of play.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PublicKey } from "@solana/web3.js";
import { hexToBytes, pad, parseAbiItem, toHex, zeroAddress, type Address, type Hex } from "viem";
import { DEMO, deployments, keypair, pubkey } from "./env.js";
import {
  checkpointHyper,
  deliverHyper,
  hyperClient,
  hyperevm,
  hyperIntake,
  intakeSlot,
  read,
  send,
  sepolia,
  sepoliaClient,
  stateProof,
  wallet,
} from "./evm.js";
import { decode, type Log } from "./messages.js";
import * as sol from "./solana.js";
import * as bnb from "./bnb.js";
import * as p1 from "./p1.js";

const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 19), ...a);
/** The index a command acts on: the WETH, SOL and HYPE one, or with `--bnb` the WETH and BNB one, on real proofs. */
const pick = (args: string[]) => (args.includes("--bnb") ? bnb.bnbDeployments.index() : deployments.index());
const plain = (args: string[]) => args.filter((a) => !a.startsWith("--"));
const BNB_TESTNET = 97n;
const intakeBytes = (intakeId: bigint) => hexToBytes(pad(toHex(intakeId), { size: 32 }));

// ---------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------

/** The Solana vault's `config` account, the 32-byte vault the factory registers: run before `sepolia0`. */
function solanaVault() {
  console.log(`SOLANA_VAULT=${toHex(sol.configPda().toBytes())}`);
}

async function solanaInit() {
  const s = deployments.sepolia();
  const deployer = keypair("SOLANA_DEPLOYER");
  const [r1, r2] = [keypair("SOLANA_RELAYER1"), keypair("SOLANA_RELAYER2")];
  const [p1, p2] = [pubkey("SOLANA_P1_PROGRAM"), pubkey("SOLANA_P2_PROGRAM")];
  const c = sol.connection();
  for (const [p, r] of [
    [p1, r1],
    [p2, r2],
  ] as const) {
    if (await c.getAccountInfo(sol.stubState(p))) log("stub", p.toBase58(), "already initialized");
    else log("stub", p.toBase58(), await sol.initStub(p, r.publicKey, deployer));
  }
  if (await c.getAccountInfo(sol.configPda())) return log("vault already initialized");
  // The vault takes only verifiers nobody can upgrade (SOL-2): the stubs are made final once their relayers are set.
  for (const p of [p1, p2]) {
    if (await sol.upgradeable(p)) {
      return log(`stub ${p.toBase58()} can still be upgraded: run`, `solana program set-upgrade-authority ${p.toBase58()} --final --url devnet`, "then solana-init again");
    }
  }
  log(
    "vault",
    await sol.initVault(deployer, p1, p2, {
      sourceChainId: BigInt(sepolia.id),
      chainId: BigInt(s.solanaChainId),
      factory: s.factory,
      hubImplementation: s.template,
      freezer: pubkey("SOLANA_FREEZER"),
      nativeCap: 1_000_000_000_000n, // 1,000 SOL
      nativeFloor: 1_000_000_000n, // 1 SOL
      recoveryProposer: solanaRecovery(),
    }),
  );
}

/** The Solana vault's recovery proposer: `SOLANA_RECOVERY`, a Squads vault's address, or else an address derived from the
 *  vault program that nobody can sign for, so the devnet vault has no stall recovery and its upgrade authority stands
 *  in. Either is off the curve, as the vault requires. */
function solanaRecovery() {
  if (process.env.SOLANA_RECOVERY) return pubkey("SOLANA_RECOVERY");
  return PublicKey.findProgramAddressSync([new TextEncoder().encode("demo recovery")], sol.vaultProgram())[0];
}

/** Advances the Solana vault's checkpoint to Sepolia's latest finalized block, unless it is there already. */
async function checkpointSolana(): Promise<bigint | undefined> {
  const finalized = await sepoliaClient().getBlock({ blockTag: "finalized" });
  if ((await sol.checkpointBlock()) >= finalized.number) return undefined;
  await sol.advanceCheckpoint(
    finalized.number,
    finalized.timestamp,
    finalized.stateRoot,
    keypair("SOLANA_RELAYER1"),
    keypair("SOLANA_RELAYER2"),
    pubkey("SOLANA_P1_PROGRAM"),
    pubkey("SOLANA_P2_PROGRAM"),
  );
  return finalized.number;
}

/** Registers the demo index on both vaults. */
async function register(args: string[]) {
  if (args.includes("--bnb")) {
    const { index, salt } = bnb.bnbDeployments.index();
    log("BNB testnet:", await bnb.register(index, salt));
    return;
  }
  const { index, salt } = deployments.index();
  const h = deployments.hyperevm();
  const client = hyperClient();
  if (await read(client, h.vault, "XindexVault", "isIndex", [index])) log("HyperEVM: registered already");
  else await send(client, wallet(hyperevm, "SENDER_KEY"), h.vault, "XindexVault", "registerIndex", [index, salt]);
  log("Solana:", await sol.registerIndex(index, salt, keypair("SOLANA_DEPLOYER")));
}

// ---------------------------------------------------------------------
// relaying
// ---------------------------------------------------------------------

const STATE = join(DEMO, "relayer", "state");
const exists = (name: string) => existsSync(join(DEMO, "deployments", name));
const cursorFile = join(STATE, "cursor.json");

function cursor(fallback: bigint): bigint {
  try {
    return BigInt(JSON.parse(readFileSync(cursorFile, "utf8")).next);
  } catch {
    return fallback;
  }
}

async function head(): Promise<bigint> {
  const client = sepoliaClient();
  const depth = process.env.CONFIRMATIONS ?? "finalized";
  if (depth === "finalized") return (await client.getBlock({ blockTag: "finalized" })).number;
  return (await client.getBlockNumber()) - BigInt(depth);
}

const event = parseAbiItem("event VaultMessage(bytes32 indexed id, bytes payload)");

/** Carries every VaultMessage the factory or its hybrid indexes emitted, up to Sepolia's finalized head, to its vault. */
async function relayOnce(from: bigint): Promise<bigint> {
  const s = deployments.sepolia();
  const client = sepoliaClient();
  const to = await head();
  const emitters = new Map<Address, boolean>();
  for (let start = from; start <= to; start += 1000n) {
    const end = start + 999n < to ? start + 999n : to;
    const logs = await client.getLogs({ event, fromBlock: start, toBlock: end });
    for (const l of logs) {
      const emitter = l.address.toLowerCase() as Address;
      if (!emitters.has(emitter)) {
        const isOurs =
          emitter === s.factory.toLowerCase() ||
          (await read(client, s.factory, "HybridIndexFactory", "indexSalt", [emitter])) !== pad("0x0", { size: 32 });
        emitters.set(emitter, isOurs);
      }
      if (!emitters.get(emitter)) continue;
      const m = decode(l.args.payload as Hex);
      const entry: Log = { blockNumber: l.blockNumber!, emitter: l.address, topic1: l.topics[1] as Hex, data: l.data };
      try {
        if (m.destChainId === BNB_TESTNET) {
          const outcome = await bnb.deliver({ ...entry, txHash: l.transactionHash!, logIndex: l.logIndex! });
          log("BNB testnet", m.id.slice(0, 10), "kind", m.kind, outcome);
        } else if (m.destChainId === BigInt(s.hyperChainId)) {
          log("HyperEVM", m.id.slice(0, 10), "kind", m.kind, await deliverHyper(entry));
        } else if (m.destChainId === BigInt(s.solanaChainId)) {
          // As on HyperEVM, a message that moves coins runs only from a block the vault's checkpoint covers (VLT-3).
          if ((await sol.checkpointBlock()) < l.blockNumber!) await checkpointSolana();
          const outcome = await sol.deliverSolana(
            m,
            l.blockNumber!,
            keypair("SOLANA_RELAYER1"),
            keypair("SOLANA_RELAYER2"),
            pubkey("SOLANA_P1_PROGRAM"),
            pubkey("SOLANA_P2_PROGRAM"),
          );
          log("Solana", m.id.slice(0, 10), "kind", m.kind, outcome);
        }
      } catch (e) {
        // A message a vault cannot run yet (frozen, not registered, a recipient without rent) stays for the next pass.
        log("waiting:", m.id.slice(0, 10), "kind", m.kind, String(e).split("\n")[0]);
        return l.blockNumber!;
      }
    }
  }
  return to + 1n;
}

async function relay(args: string[]) {
  mkdirSync(STATE, { recursive: true });
  const start = args.find((a) => !a.startsWith("--"));
  const recent = (await head()) - 5000n;
  let next = cursor(start !== undefined ? BigInt(start) : recent > 0n ? recent : 0n);
  let lastCheckpoint = 0;
  const bnbOn = exists("sepolia-bnb.json");
  for (;;) {
    next = await relayOnce(next);
    writeFileSync(cursorFile, JSON.stringify({ next: next.toString() }));
    if (bnbOn) {
      // BnbStateVerifier stops for good a day behind, so it is walked forward on every pass.
      const e = await bnb.follow().catch((err) => log("BNB follow:", String(err).split("\n")[0]));
      if (e) log("BNB testnet followed to epoch", e);
    }
    if (Date.now() - lastCheckpoint > 3_600_000) {
      const c = await checkpointHyper().catch((e) => log("checkpoint:", String(e).split("\n")[0]));
      if (c) log("HyperEVM checkpoint", c);
      // A week without a checkpoint stalls the Solana vault, which then takes no deposit.
      const k = await checkpointSolana().catch((e) => log("Solana checkpoint:", String(e).split("\n")[0]));
      if (k) log("Solana checkpoint", k);
      if (bnbOn && process.env.SP1_PROVER) {
        // P1 must move within a day of its anchor, and the BNB vault's checkpoint with it.
        const u = await bnb.updateP1().catch((err) => log("P1:", String(err).split("\n")[0]));
        if (u) log("P1 on BNB testnet at Sepolia epoch", u);
        const k = await bnb.checkpoint().catch((err) => log("BNB checkpoint:", String(err).split("\n")[0]));
        if (k) log("BNB testnet checkpoint", k);
      }
      lastCheckpoint = Date.now();
    }
    if (args.includes("--once")) return;
    await new Promise((r) => setTimeout(r, 15_000));
  }
}

// ---------------------------------------------------------------------
// the demo's mint and redeem
// ---------------------------------------------------------------------

async function components(index: Address) {
  const [tokens] = await read(sepoliaClient(), index, "IHybridIndex", "components");
  return tokens as Address[];
}

/** Mints demo WETH to the sender, approves the index and opens an order for `shares` whole shares. */
async function open(all: string[]) {
  const { index } = pick(all);
  const args = plain(all);
  const s = deployments.sepolia();
  const client = sepoliaClient();
  const w = wallet(sepolia, "SENDER_KEY");
  // Only an index's creator may seed it (HUB-2): sepolia4 must be broadcast from SENDER_KEY's account.
  const supply = (await read(client, index, "IHybridIndex", "totalSupply")) as bigint;
  const creator = (await read(client, s.factory, "HybridIndexFactory", "creatorOf", [index])) as Address;
  if (supply === 0n && creator.toLowerCase() !== w.account.address.toLowerCase()) {
    throw new Error(`the index is empty and only its creator ${creator} may seed it; SENDER_KEY is ${w.account.address}`);
  }
  const shares = BigInt(Math.round(Number(args[0] ?? "10") * 1e6)) * 10n ** 12n;
  const minutes = BigInt(args[1] ?? "10");
  const amounts = (await read(client, index, "IHybridIndex", "previewOrder", [shares])) as bigint[];
  const tokens = await components(index);
  const wethAt = tokens.findIndex((t) => t.toLowerCase() === s.weth.toLowerCase());
  await send(client, w, s.weth, "DemoToken", "mint", [w.account.address, amounts[wethAt]]);
  await send(client, w, s.weth, "DemoToken", "approve", [index, amounts[wethAt]]);
  const deadline = (await client.getBlock()).timestamp + minutes * 60n;
  const receipt = await send(client, w, index, "IHybridIndex", "openOrder", [shares, deadline]);
  const orderId = (await read(client, index, "IHybridIndex", "orderCount")) as bigint;
  log("order", orderId, "for", args[0] ?? "10", "shares, deposits due by", new Date(Number(deadline) * 1000).toISOString());
  log("amounts", amounts, "tx", receipt.transactionHash);
}

/** Deposits the order's HYPE on HyperEVM and its SOL on Solana, from the demo's wallets. */
async function depositFor(all: string[]) {
  const { index } = pick(all);
  const args = plain(all);
  const s = deployments.sepolia();
  const orderId = BigInt(args[0]);
  const client = sepoliaClient();
  const intakeId = (await read(client, index, "IHybridIndex", "intakeIdOf", [orderId])) as bigint;
  const [amounts] = await read(client, index, "IHybridIndex", "orderAmounts", [orderId]);
  const tokens = await components(index);
  for (let i = 0; i < tokens.length; ++i) {
    const [chainId] = await read(client, s.factory, "HybridIndexFactory", "vaultToken", [tokens[i]]);
    if (chainId === BNB_TESTNET) {
      const receipt = await bnb.deposit(index, intakeId, amounts[i]);
      log("BNB testnet deposit", amounts[i], receipt.transactionHash);
    } else if (chainId === BigInt(s.hyperChainId)) {
      const h = deployments.hyperevm();
      await send(hyperClient(), wallet(hyperevm, "SENDER_KEY"), h.vault, "XindexVault", "deposit", [index, intakeId], amounts[i]);
      log("HyperEVM deposit", amounts[i]);
    } else if (chainId === BigInt(s.solanaChainId)) {
      log("Solana deposit", amounts[i], await sol.deposit(index, intakeBytes(intakeId), amounts[i], keypair("SOLANA_DEPOSITOR")));
    }
  }
}

/** Proves each vault's intake to Sepolia and settles the order; run after its deadline. */
async function settle(all: string[]) {
  const { index } = pick(all);
  const args = plain(all);
  const s = deployments.sepolia();
  const orderId = BigInt(args[0]);
  const client = sepoliaClient();
  const intakeId = (await read(client, index, "IHybridIndex", "intakeIdOf", [orderId])) as bigint;
  const deadline = intakeId >> 192n;
  const [chainIds] = await read(client, index, "IHybridIndex", "chains");
  const proofs = [];
  // Deposits are final only after the deadline, so the hub takes only a state read at a block after it.
  const after = (chain: string, t: bigint) => {
    if (t <= deadline) throw new Error(`${chain}'s latest readable block (${t}) is not yet after the deadline (${deadline}): wait`);
  };
  for (const chainId of chainIds as bigint[]) {
    if (chainId === BNB_TESTNET) {
      // A real proof: the vault's storage at a final BNB testnet block, shown final by its validators' vote.
      const r = await bnb.intakeProof(index, intakeId);
      after("BNB testnet", r.timestamp);
      proofs.push({ proof: r.proof, tokens: r.tokens, totals: r.totals });
    } else if (chainId === BigInt(s.hyperChainId)) {
      const r = await hyperIntake(index, intakeId);
      after("HyperEVM", r.timestamp);
      const proof = await stateProof(s.hyperStateVerifier, r.account, r.slot, r.value, r.blockNumber, r.timestamp);
      proofs.push({ proof, tokens: r.tokens, totals: r.totals });
    } else {
      const r = await sol.solanaIntake(index, intakeBytes(intakeId));
      after("Solana", r.timestamp);
      const slot = intakeSlot(index, intakeId);
      const proof = await stateProof(s.solanaStateVerifier, sol.solanaVaultAddress(), slot, r.digest, BigInt(r.slot), r.timestamp);
      proofs.push({ proof, tokens: r.hasNative ? [zeroAddress] : [], totals: r.hasNative ? [r.total] : [] });
    }
  }
  const receipt = await send(client, wallet(sepolia, "SENDER_KEY"), index, "IHybridIndex", "settleOrder", [orderId, proofs]);
  log("settled", orderId, receipt.transactionHash, "- claimable after the 24-hour lock");
}

async function claim(all: string[]) {
  const { index } = pick(all);
  const args = plain(all);
  const receipt = await send(sepoliaClient(), wallet(sepolia, "SENDER_KEY"), index, "IHybridIndex", "claimOrder", [BigInt(args[0])]);
  log("claimed", args[0], receipt.transactionHash, "- the relayer carries the settle messages to the vaults");
}

/** Redeems `shares` whole shares: WETH now, HYPE and SOL burned toward the recipients on their chains. With `--bnb`,
 *  `redeem <shares> <BNB testnet recipient>`: WETH now, BNB burned toward the recipient. */
async function redeem(all: string[]) {
  const { index } = pick(all);
  const args = plain(all);
  const s = deployments.sepolia();
  const client = sepoliaClient();
  const w = wallet(sepolia, "SENDER_KEY");
  const shares = BigInt(Math.round(Number(args[0]) * 1e6)) * 10n ** 12n;
  const evmRecipient = args[1] as Address;
  const [chainIds] = await read(client, index, "IHybridIndex", "chains");
  const recipients = (chainIds as bigint[]).map((id) =>
    id === BigInt(s.hyperChainId) || id === BNB_TESTNET ? pad(evmRecipient, { size: 32 }) : toHex(new PublicKey(args[2]).toBytes()),
  );
  const receipt = await send(client, w, index, "IHybridIndex", "redeem", [shares, w.account.address, recipients, 0n]);
  log("redeemed", args[0], "shares", receipt.transactionHash, "- the relayer carries the burns");
}

/** The index's shares on Sepolia and its balances in both vaults: what the demo shows between steps. */
async function balances(all: string[]) {
  const args = plain(all);
  if (all.includes("--bnb")) {
    const { index } = bnb.bnbDeployments.index();
    const vault = bnb.bnbDeployments.bnb().vault;
    const holder = (args[0] as Address | undefined) ?? wallet(sepolia, "SENDER_KEY").account.address;
    const shares = (await read(sepoliaClient(), index, "IHybridIndex", "balanceOf", [holder])) as bigint;
    const supply = (await read(sepoliaClient(), index, "IHybridIndex", "totalSupply")) as bigint;
    const balance = (await read(bnb.bnbClient(), vault, "XindexVault", "balance", [index, zeroAddress])) as bigint;
    const paid = (await read(bnb.bnbClient(), vault, "XindexVault", "paidTotal", [index, zeroAddress])) as bigint;
    console.log({ holder, shares, supply, bnbTestnet: { balance, paid } });
    return;
  }
  const { index } = deployments.index();
  const h = deployments.hyperevm();
  const holder = (args[0] as Address | undefined) ?? wallet(sepolia, "SENDER_KEY").account.address;
  const shares = (await read(sepoliaClient(), index, "IHybridIndex", "balanceOf", [holder])) as bigint;
  const supply = (await read(sepoliaClient(), index, "IHybridIndex", "totalSupply")) as bigint;
  const hyper = (await read(hyperClient(), h.vault, "XindexVault", "balance", [index, zeroAddress])) as bigint;
  const hyperPaid = (await read(hyperClient(), h.vault, "XindexVault", "paidTotal", [index, zeroAddress])) as bigint;
  const account = await sol.connection().getAccountInfo(sol.indexPda(index));
  let solBalance = 0n;
  let solPaid = 0n;
  if (account) {
    const d = account.data;
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    // IndexState: discriminator (8), index (20), has_native (1), balance, paid_total.
    solBalance = view.getBigUint64(29, true);
    solPaid = view.getBigUint64(37, true);
  }
  console.log({ holder, shares, supply, hyperevm: { balance: hyper, paid: hyperPaid }, solana: { balance: solBalance, paid: solPaid } });
}

async function status() {
  const s = deployments.sepolia();
  console.log({
    sepolia: s,
    solanaConfig: sol.configPda().toBase58(),
    solanaVaultAccountForStateProofs: sol.solanaVaultAddress(),
    solanaTreasury: sol.treasuryPda().toBase58(),
  });
}

/** Day 0, before `bnb0`: keeps Sepolia's latest finalized state as P1's first anchor and prints the deploy's
 *  `P1_KEY`, `P1_ANCHOR` and `P1_EPOCH`. Needs `proofs/` built for Sepolia. */
async function p1Anchor() {
  for (const [k, v] of Object.entries(await p1.firstAnchor())) console.log(`${k}=${v}`);
}

/** Day 0, before `sepoliaBnb0`: writes BNB testnet's latest finalized epoch block and its keys for the verifier. */
async function bnbEpoch() {
  const e = await bnb.epochForDeploy();
  writeFileSync(join(DEMO, "deployments", "bnb-epoch.json"), JSON.stringify(e, null, 1));
  log("BNB testnet epoch", e.number, "with", e.keys.length, "validators: deployments/bnb-epoch.json");
}

const commands: Record<string, (args: string[]) => unknown> = {
  "p1-anchor": p1Anchor,
  "bnb-epoch": bnbEpoch,
  "bnb-follow": async () => log("BNB testnet followed to epoch", await bnb.follow()),
  "p1-update": async () => log("P1 on BNB testnet at Sepolia epoch", (await bnb.updateP1()) ?? "current"),
  "bnb-checkpoint": async () => log("BNB testnet checkpoint", (await bnb.checkpoint()) ?? "current"),
  "solana-vault": solanaVault,
  "solana-init": solanaInit,
  register,
  relay,
  checkpoint: async () => log("HyperEVM checkpoint", (await checkpointHyper()) ?? "current"),
  "solana-checkpoint": async () => log("Solana checkpoint", (await checkpointSolana()) ?? "current"),
  open,
  deposit: depositFor,
  settle,
  claim,
  redeem,
  balances,
  status,
};

const [command, ...rest] = process.argv.slice(2);
if (!command || !commands[command]) {
  console.log(`commands: ${Object.keys(commands).join(", ")}`);
  process.exit(command ? 1 : 0);
}
Promise.resolve(commands[command](rest)).catch((e) => {
  console.error(e);
  process.exit(1);
});
