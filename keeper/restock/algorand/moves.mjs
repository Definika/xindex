// The Algorand signer's answers (`signer.mjs`), the same requests as every signer's (`signer-home.mjs`), in plain JSON
// (amounts as decimal strings, addresses as base32 and words as 0x-hex). A move that commits funds (a swap, a bridge
// transfer) comes back built, checked by simulation and signed, never sent: the parent journals it, then asks for it to
// be sent. A redeem, which only completes a move, is sent here, since the bridge counts each transfer once.
//
// Wormhole's Token Bridge through Wormhole's own SDK, which pins algosdk 2.7.0 and imports it undeclared, so this
// package holds that one copy; swaps through Tinyman v2's USDC/ALGO pool, a two-transaction group whose app enforces
// the minimum output (`assert(output_amount >= min_output)`), built here at the plan's floor and quoted by simulating
// it. Algorand has no CCTP: the USDC float here is kept by hand, so the planner never asks for a burn or a receipt.
// A group is valid until its last round: one transaction in flight at a time keeps the moves from racing over balances.

import algosdk from "algosdk";
import { contracts, deserialize, toUniversal } from "@wormhole-foundation/sdk-connect";
import { AlgorandWormholeCore } from "@wormhole-foundation/sdk-algorand-core";
import { AlgorandTokenBridge } from "@wormhole-foundation/sdk-algorand-tokenbridge";
import { createInflight, refusedOutright } from "../inflight.mjs";

/// Algorand mainnet's genesis hash: the RPC must serve this chain.
export const MAINNET_GENESIS_HASH = "wGHE2Pwdvd7S12BL5FaOP20EGYesN73ktiC1qzkkit8=";
export const ALGO = "0";
export const USDC = "31566704";
/// Who Algorand's Token Bridge publishes as: its app's address (Ethereum's Token Bridge names it for chain 8).
export const TOKEN_BRIDGE_EMITTER = "0x67e93fa6c8ac5c819990aa7340c0c16b508abb1178be9b30d024b8ac25193d45";
/// Tinyman v2's app and its USDC/ALGO pool, the only ones a swap may call; checked at startup.
export const TINYMAN_APP = 1002541853;
export const TINYMAN_POOL = "2PIFZW53RHCSFSYMCFUBW4XOCXOMB7XOYQSQ6KGT3KVGJTL4HM6COZRNMM";
/// The most a move's fees may cost, in microALGO, and the storage a redeem may lock: the first transfer redeemed in a
/// new bucket of the bridge's message ids pays about 1.004 ALGO for it, for good.
export const MAX_FEES = 20_000n;
export const MAX_STORAGE = 1_010_000n;

const hexBytes = (hex) => Uint8Array.from(Buffer.from(hex.replace(/^0x/, ""), "hex"));
const same = (a, b) => a && b && Buffer.from(a).equals(Buffer.from(b));
const text = (s) => new TextEncoder().encode(s);

export function createMoves({ algod, indexerUrl, account, fetchImpl = fetch }) {
  const me = algosdk.decodeAddress(account.addr).publicKey;
  const word = `0x${Buffer.from(me).toString("hex")}`;
  const ids = { coreBridge: contracts.coreBridge("Mainnet", "Algorand"), tokenBridge: contracts.tokenBridge("Mainnet", "Algorand") };
  const bridge = new AlgorandTokenBridge("Mainnet", "Algorand", algod, ids);
  const core = new AlgorandWormholeCore("Mainnet", "Algorand", algod, ids);
  /// The one group sent that may still commit: `{id (its key transaction's id), lastValid}`.
  const inflight = createInflight((e) => fate(e.id, e.lastValid));

  const idx = async (path) => {
    const r = await fetchImpl(`${indexerUrl.replace(/\/+$/, "")}${path}`, { signal: AbortSignal.timeout(15_000) });
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`indexer ${r.status} on ${path}`);
    return r.json();
  };

  /// What became of transaction `txid`, valid until round `lastValid`: landed, pending, or expired once both algod and
  /// the indexer are past that round with no such transaction. Algorand commits a group whole or not at all.
  async function fate(txid, lastValid) {
    try {
      const p = await algod.pendingTransactionInformation(txid).do();
      if (Number(p["confirmed-round"] ?? p.confirmedRound ?? 0) > 0) return { state: "landed", at: String(p["confirmed-round"] ?? p.confirmedRound) };
    } catch (error) {
      if (error?.status !== 404 && error?.response?.status !== 404) throw error;
    }
    const found = await idx(`/v2/transactions/${txid}`);
    if (found?.transaction?.["confirmed-round"]) return { state: "landed", at: String(found.transaction["confirmed-round"]) };
    const [status, health] = await Promise.all([algod.status().do(), idx("/health")]);
    const algodRound = BigInt(status["last-round"] ?? status.lastRound);
    const indexed = BigInt(health?.round ?? 0);
    if (algodRound > BigInt(lastValid) && indexed > BigInt(lastValid)) return { state: "expired", reason: `its last valid round ${lastValid} passed` };
    return { state: "pending" };
  }

  const params = async (fee) => ({ ...(await algod.getTransactionParams().do()), flatFee: true, fee });

  /// The wallet's change of ALGO and of each asset in simulated group `group` of `txns`: its own top-level payments,
  /// transfers and fees, and every inner payment or transfer to or from it.
  function changesOf(txns, group) {
    const out = new Map();
    const add = (asset, x) => out.set(asset, (out.get(asset) ?? 0n) + x);
    txns.forEach((t, i) => {
      const fromMe = same(t.from?.publicKey, me);
      const toMe = same(t.to?.publicKey, me);
      if (fromMe) add(ALGO, -BigInt(t.fee));
      if (t.type === "pay") {
        if (fromMe) add(ALGO, -BigInt(t.amount ?? 0));
        if (toMe) add(ALGO, BigInt(t.amount ?? 0));
        if (fromMe && t.closeRemainderTo) throw new Error("a payment that closes the wallet");
      }
      if (t.type === "axfer") {
        const asset = String(t.assetIndex);
        if (fromMe) add(asset, -BigInt(t.amount ?? 0));
        if (toMe) add(asset, BigInt(t.amount ?? 0));
        if (fromMe && t.closeRemainderTo) throw new Error("an asset transfer that closes the wallet's holding");
      }
      const walk = (inner) => {
        for (const it of inner ?? []) {
          const x = it.txn?.txn ?? {};
          if (x.type === "pay") {
            if (same(x.rcv, me)) add(ALGO, BigInt(x.amt ?? 0));
            if (same(x.snd, me)) add(ALGO, -BigInt(x.amt ?? 0));
            if (same(x.close, me)) add(ALGO, BigInt(it.closingAmount ?? 0));
          }
          if (x.type === "axfer") {
            if (same(x.arcv, me)) add(String(x.xaid), BigInt(x.aamt ?? 0));
            if (same(x.snd, me)) add(String(x.xaid), -BigInt(x.aamt ?? 0));
          }
          walk(it.innerTxns);
        }
      };
      walk(group.txnResults?.[i]?.txnResult?.innerTxns);
    });
    return out;
  }

  /// Simulates `txns` (grouped, unsigned) and returns the group's result; a failure comes back as `{failure}`.
  async function simulate(txns) {
    const req = new algosdk.modelsv2.SimulateRequest({
      txnGroups: [new algosdk.modelsv2.SimulateRequestTransactionGroup({ txns: txns.map((t) => algosdk.decodeObj(algosdk.encodeUnsignedSimulateTransaction(t))) })],
      allowEmptySignatures: true,
    });
    const group = (await algod.simulateTransactions(req).do()).txnGroups[0];
    return group.failureMessage ? { failure: group.failureMessage, failedAt: group.failedAt, group } : { group };
  }

  /// Checks `changes` against `bounds` (asset -> {min, max}); any other asset of the wallet's moving is refused.
  function check(changes, bounds) {
    for (const [asset, change] of changes) {
      if (!bounds[asset] && change !== 0n) throw new Error(`the group would change the wallet's ${asset === ALGO ? "ALGO" : `asset ${asset}`} by ${change}`);
    }
    for (const [asset, { min, max }] of Object.entries(bounds)) {
      const change = changes.get(asset) ?? 0n;
      if (change < min || change > max) throw new Error(`the group would change the wallet's ${asset === ALGO ? "ALGO" : `asset ${asset}`} by ${change}, outside [${min}, ${max}]`);
    }
  }

  /// `pairs` ({tx, signer?}) grouped, simulated, checked against `bounds`, and signed: the logic signatures the SDK
  /// supplies sign their own transactions, the wallet the rest. Returns the move's signed form and the simulation.
  async function signedGroup(pairs, bounds) {
    await inflight.idle();
    const txns = pairs.map((p) => p.tx);
    algosdk.assignGroupID(txns);
    const sim = await simulate(txns);
    if (sim.failure) throw new Error(`simulation failed: ${sim.failure}`);
    const changes = changesOf(txns, sim.group);
    check(changes, bounds);
    const bytes = [];
    for (const p of pairs) bytes.push(p.signer ? await p.signer.signTxn(p.tx) : p.tx.signTxn(account.sk));
    const key = txns[txns.length - 1];
    const lastValid = String(Math.max(...txns.map((t) => Number(t.lastRound))));
    // Signing puts nothing in flight: only sending does (PD-6).
    return {
      signed: { raw: JSON.stringify(bytes.map((b) => Buffer.from(b).toString("base64"))), signature: key.txID(), expiry: lastValid },
      changes,
    };
  }

  /// Sends group `bytes`, a step that only completes a move, and waits for its key transaction `txid`. A group algod
  /// refuses outright is forgotten: it is in no pool, and a completing step that ran after all would only find its
  /// work done (PD-6).
  async function complete(signed) {
    const bytes = JSON.parse(signed.raw).map((b) => Buffer.from(b, "base64"));
    const resend = () => algod.sendRawTransaction(bytes).do().catch(() => {});
    inflight.sent({ id: signed.signature, lastValid: signed.expiry, resend });
    try {
      await algod.sendRawTransaction(bytes).do();
    } catch (error) {
      if (refusedOutright(error)) inflight.clear(signed.signature);
      throw error;
    }
    await algosdk.waitForConfirmation(algod, signed.signature, 20);
    inflight.clear(signed.signature);
    return signed.signature;
  }

  /// `vaa` as the SDK reads a transfer, after checking it pays this wallet with Algorand's ALGO.
  function transferToMe(vaa) {
    const transfer = deserialize("TokenBridge:Transfer", hexBytes(vaa));
    if (transfer.payload.to.chain !== "Algorand" || !same(transfer.payload.to.address.toUint8Array(), me)) throw new Error("the transfer does not pay this wallet");
    if (transfer.payload.token.chain !== "Algorand") throw new Error(`the transfer carries a token of ${transfer.payload.token.chain}`);
    return transfer;
  }

  return {
    /// The wallet and the addresses the parent needs, after checking the RPC serves Algorand mainnet, the coins are the
    /// one this signer serves, and Tinyman's pool is the USDC/ALGO pool: the executor pins the wallet itself.
    async info({ mints }) {
      const sp = await algod.getTransactionParams().do();
      if (sp.genesisHash !== MAINNET_GENESIS_HASH) throw new Error(`the RPC serves genesis ${sp.genesisHash}, not Algorand mainnet`);
      for (const m of mints) if (m !== ALGO) throw new Error(`${m} is not a coin this signer serves`);
      const local = await algod.accountApplicationInformation(TINYMAN_POOL, TINYMAN_APP).do();
      const kv = Object.fromEntries((local["app-local-state"]?.["key-value"] ?? []).map((e) => [Buffer.from(e.key, "base64").toString(), e.value.uint]));
      if (Number(kv.asset_1_id) !== Number(USDC) || Number(kv.asset_2_id) !== 0) throw new Error("Tinyman's pool is not the USDC/ALGO pool");
      return { wallet: account.addr, walletWord: word, emitter: TOKEN_BRIDGE_EMITTER, accounts: Object.fromEntries(mints.map((m) => [m, { address: account.addr, word }])) };
    },
    /// The wallet's ALGO, in microALGO, and its balance of each coin (`0` is ALGO, a number an asset id).
    async balances({ mints }) {
      const info = await algod.accountInformation(account.addr).do();
      const of = (m) => (m === ALGO ? BigInt(info.amount) : BigInt((info.assets ?? []).find((a) => String(a["asset-id"]) === m)?.amount ?? 0));
      return { gas: String(BigInt(info.amount)), tokens: Object.fromEntries(mints.map((m) => [m, String(of(m))])) };
    },
    /// A Tinyman swap of `amount` of `inputMint` for at least `minOut` of `outputMint` (ALGO and USDC), its minimum
    /// output the plan's floor, which the pool's app enforces; signed, or `{refused: "loss"}` when the simulation shows
    /// the pool would pay less.
    async buildSwap({ inputMint, outputMint, amount, minOut }) {
      if (!((inputMint === ALGO && outputMint === USDC) || (inputMint === USDC && outputMint === ALGO))) throw new Error(`no Tinyman pool for ${inputMint} -> ${outputMint}`);
      const amountIn = BigInt(amount);
      const floor = BigInt(minOut);
      const input = inputMint === ALGO
        ? algosdk.makePaymentTxnWithSuggestedParamsFromObject({ from: account.addr, to: TINYMAN_POOL, amount: amountIn, suggestedParams: await params(1000) })
        : algosdk.makeAssetTransferTxnWithSuggestedParamsFromObject({ from: account.addr, to: TINYMAN_POOL, amount: amountIn, assetIndex: Number(USDC), suggestedParams: await params(1000) });
      const call = algosdk.makeApplicationNoOpTxnFromObject({
        from: account.addr,
        appIndex: TINYMAN_APP,
        appArgs: [text("swap"), text("fixed-input"), algosdk.encodeUint64(floor)],
        accounts: [TINYMAN_POOL],
        foreignAssets: [Number(USDC), 0],
        suggestedParams: await params(2000),
      });
      const fees = 3000n;
      const bounds = inputMint === ALGO
        ? { [ALGO]: { min: -(amountIn + fees), max: -(amountIn + fees) }, [USDC]: { min: floor, max: 2n ** 63n } }
        : { [USDC]: { min: -amountIn, max: -amountIn }, [ALGO]: { min: floor - fees, max: 2n ** 63n } };
      // The quote is the group itself, simulated: the pool's app fails it (an assert) when it would pay below the floor.
      try {
        const { signed, changes } = await signedGroup([{ tx: input }, { tx: call }], bounds);
        const out = changes.get(outputMint) ?? 0n;
        return { ...signed, outAmount: String(outputMint === ALGO ? out + fees : out), minOut: String(floor) };
      } catch (error) {
        if (/simulation failed: .*assert failed/.test(String(error?.message))) return { refused: "loss", outAmount: "0" };
        throw error;
      }
    },
    /// The Token Bridge transfer of `amount` of ALGO to `executor` (a word, an Ethereum address) on Ethereum, with the
    /// payload 0x01, as Wormhole's SDK builds it, signed: it must take exactly `amount` and the fees. ALGO has six
    /// decimals on both sides, so none of it is cut.
    async buildBridgeIn({ mint, amount, executor }) {
      if (mint !== ALGO) throw new Error(`${mint} is not a coin this signer bridges`);
      const value = BigInt(amount);
      const recipient = { chain: "Ethereum", address: toUniversal("Ethereum", `0x${executor.replace(/^0x/, "").slice(24)}`) };
      const pairs = [];
      for await (const u of bridge.transfer(account.addr, recipient, "native", value, new Uint8Array([1]))) pairs.push(u.transaction);
      const { signed } = await signedGroup(pairs, { [ALGO]: { min: -(value + MAX_FEES), max: -value } });
      return signed;
    },
    /// Sends signed group `raw` as it is; Algorand commits a transaction once, so sending it again is safe.
    async send({ raw, signature, expiry }) {
      // From here it is in flight (PD-6).
      inflight.sent({ id: signature, lastValid: expiry });
      const bytes = JSON.parse(raw).map((b) => Buffer.from(b, "base64"));
      const r = await algod.sendRawTransaction(bytes).do().catch((error) => ({ error: String(error?.message ?? error) }));
      return r.txId ?? r.txid ?? null;
    },
    /// What became of group `signature` with `expiry`. One that may still commit is in flight again, so after a restart
    /// nothing else is sent before it settles (PD-9).
    async status({ signature, expiry }) {
      const s = await fate(signature, expiry);
      if (s.state === "pending") inflight.sent({ id: signature, lastValid: expiry });
      else inflight.clear(signature);
      return s;
    },
    /// The sequence the Token Bridge published in transaction `signature`: from algod while it remembers it, or from
    /// the indexer, which keeps the core's log of it.
    async sequenceOf({ signature }) {
      try {
        const mine = (await core.parseTransaction(signature)).filter((m) => `0x${Buffer.from(m.emitter.toUint8Array()).toString("hex")}` === TOKEN_BRIDGE_EMITTER);
        if (mine.length === 1) return String(mine[0].sequence);
      } catch {}
      const found = await idx(`/v2/transactions/${signature}`);
      const walk = (txs) => {
        for (const t of txs ?? []) {
          const app = t["application-transaction"];
          if (app && Number(app["application-id"]) === Number(ids.coreBridge) && Buffer.from(app["application-args"]?.[0] ?? "", "base64").toString() === "publishMessage") {
            return Buffer.from(t.logs[0], "base64").readBigUInt64BE(0);
          }
          const deeper = walk(t["inner-txns"]);
          if (deeper !== null) return deeper;
        }
        return null;
      };
      const sequence = walk(found?.transaction?.["inner-txns"]);
      if (sequence === null) throw new Error(`transaction ${signature} carries no Token Bridge message`);
      return String(sequence);
    },
    transferCompleted: ({ vaa }) => bridge.isTransferCompleted(deserialize("TokenBridge:Transfer", hexBytes(vaa))),
    /// Completes transfer `vaa` to this wallet: what it pays must reach the wallet, less fees and the storage the first
    /// transfer of a new message bucket locks, and nothing else of the wallet's may move.
    async redeem({ vaa, mints }) {
      const transfer = transferToMe(vaa);
      if (!mints.includes(ALGO)) throw new Error("this signer serves no coin");
      const pairs = [];
      for await (const u of bridge.redeem(account.addr, transfer)) pairs.push(u.transaction);
      const paid = transfer.payload.token.amount; // six decimals on both sides
      const { signed } = await signedGroup(pairs, { [ALGO]: { min: paid - MAX_FEES - MAX_STORAGE, max: paid } });
      return complete(signed);
    },
    buildSweep: () => {
      throw new Error("Algorand has no CCTP: its float is kept by hand");
    },
    receive: () => {
      throw new Error("Algorand has no CCTP");
    },
    cctpReceived: () => {
      throw new Error("Algorand has no CCTP");
    },
    verifyCctp: () => {
      throw new Error("Algorand has no CCTP");
    },
  };
}
