// The restock service's home on a chain whose libraries and key live in a signer process of their own (D3 of
// design/2026-11-01-non-evm-restock.md): Solana (`solana/`), Sui (`sui/`), Aptos (`aptos/`) and Algorand
// (`algorand/`). The same moves as an EVM home (`evm.mjs` createEvmHome). This side has no dependency and no chain
// logic: it starts the signer with an environment that names only what the signer needs, never the treasury's key,
// records every move the signer signs in the journal before asking the signer to send it, and asks the signer what has
// become of it, in that chain's own terms (`status`: landed, reverted, pending, or expired, when it can never land).
//
// Every signer answers the same requests (`solana/moves.mjs` is the first): info, balances, buildSwap, buildBridgeIn,
// buildSweep (on a chain CCTP serves), send, status, sequenceOf, transferCompleted, redeem, cctpReceived, verifyCctp,
// receive, reclaim where a burn leaves rent to take back, and attest where the owner attests tokens for copies
// (Solana and Sui, PD-7).

import { spawn } from "node:child_process";

/// How long a move's transaction is watched before it is left to the next round's resume.
const CONFIRM_SECONDS = 90;

/// A 20-byte EVM address as a 32-byte word, as the bridges encode a recipient.
export const evmWord = (address) => `0x${address.toLowerCase().replace(/^0x/, "").padStart(64, "0")}`;

/// The signer at `path` as a request-answer channel: `ask(op, args)` resolves with the answer's result. The signer
/// starts with `env` and nothing else of this process's environment, and starts again on the next request after it
/// exits. Lines that are not answers are skipped: libraries print to stderr, but a stray line must not break it.
export function startSigner({ env, path, label = "signer", timeoutMs = 120_000 }) {
  let child = null;
  let next = 1;
  const pending = new Map();
  let buffer = "";
  const failAll = (error) => {
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    pending.clear();
  };
  function start() {
    const self = spawn(process.execPath, [path], { env, stdio: ["pipe", "pipe", "inherit"] });
    child = self;
    // A signer that cannot start, or whose input closes under a write (EPIPE, when it has just died), reports it as an
    // 'error' event; unheard, Node would end the whole service with it (PD-11). Either fails what is waiting, and the
    // next request starts the signer again.
    const fail = (error) => {
      if (child === self) child = null;
      failAll(new Error(`the ${label} signer failed: ${error?.message ?? error}`));
      self.kill();
    };
    self.on("error", fail);
    self.stdin.on("error", fail);
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }
        const waiting = pending.get(message?.id);
        if (!waiting) continue;
        pending.delete(message.id);
        clearTimeout(waiting.timer);
        if (message.ok) waiting.resolve(message.result);
        else waiting.reject(new Error(`${label}: ${message.error}`));
      }
    });
    self.on("exit", (code) => {
      if (child === self) child = null;
      failAll(new Error(`the ${label} signer exited (${code})`));
    });
  }
  return function ask(op, args = {}, ms = timeoutMs) {
    if (!child) start();
    const id = next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`the ${label} signer did not answer ${op} in ${ms / 1000} s`));
      }, ms);
      pending.set(id, { resolve, reject, timer });
      child.stdin.write(`${JSON.stringify({ id, op, args })}\n`);
    });
  };
}

/// The home on chain `name` (a key of `coins.mjs` CHAINS, `def` its entry), through the signer at `signerPath` with
/// `env`. `coins` are the coins served there; `floatId` the float's token as the chain names it; `verifyVaa` is
/// Ethereum's core check, which vouches for the VAAs redeemed here too, the guardian set being the same (D5); `cfg` is
/// the plan's `{minUsd}`.
export function createSignerHome({ name, def, signerPath, env, coins, floatId, journal, cfg, verifyVaa, ask: given = null }) {
  const ask = given ?? startSigner({ env, path: signerPath, label: name });
  const mints = coins.map((c) => c.home);
  let info = null;
  const home = { name, def: { wormhole: def.wormhole, cctpDomain: def.cctpDomain } };

  /// The signer's request to send journalled move `data` (`{raw, hash, expiry}`): the digest and expiry go with it, so
  /// the signer holds it in flight from the moment it is sent (PD-6).
  const sendRequest = (data) => ({ raw: data.raw, signature: data.hash, expiry: data.expiry });

  /// What the signer says of journalled move `move`: landed (the move goes to "sent"), expired (dropped: nothing it
  /// would have moved left the wallet), pending (the same bytes are sent again), or unknown, when the node at hand
  /// cannot show whether it landed, which leaves it signed and is reported (PD-8). Returns `{status}` or null.
  async function resume(move) {
    const s = await ask("status", { signature: move.data.hash, expiry: move.data.expiry });
    if (s.state === "landed" || s.state === "reverted") {
      journal.advance(move.id, "sent", { at: s.at ?? null, status: s.state === "landed" ? "success" : "reverted" });
      return { status: s.state === "landed" ? "success" : "reverted" };
    }
    if (s.state === "expired") {
      journal.drop(move.id, s.reason ?? "it expired before it landed");
      return null;
    }
    if (s.state === "unknown") throw new Error(`whether it landed is unknown: ${s.reason}`);
    await ask("send", sendRequest(move.data)).catch(() => {});
    return null;
  }

  /// Records the signed move `action` in the journal, with `extra` in its data, has the signer send it, and watches it
  /// until it lands; one not landed in time is left signed, for {resume}. Returns its id and `{status}`, or null.
  async function commit(action, signed, extra = {}) {
    const id = journal.open(action, { chain: name, raw: signed.raw, hash: signed.signature, expiry: signed.expiry, ...extra });
    await ask("send", sendRequest(journal.get(id).data)).catch(() => {});
    for (let s = 0; s < CONFIRM_SECONDS; s += 3) {
      await new Promise((r) => setTimeout(r, 3000));
      const move = journal.get(id);
      if (!move || move.stage !== "signed") return { id, receipt: null };
      const settled = await resume(move);
      if (settled) return { id, receipt: settled };
    }
    return { id, receipt: null };
  }

  /// A swap through the signer in the largest batch, halving down to RESTOCK_MIN_USD, whose route pays the batch's
  /// share of `minOut`: `{amount, usd, signed}` or null.
  async function batch({ inputMint, outputMint, amount, minOut, usd }) {
    for (let a = amount, m = minOut, u = usd; a > 0n && u >= cfg.minUsd; a /= 2n, m /= 2n, u /= 2) {
      const r = await ask("buildSwap", { inputMint, outputMint, amount: String(a), minOut: String(m) });
      // A venue whose route takes a little less than asked says what it spends (Sui's aggregator).
      const spent = r.spent === undefined ? a : BigInt(r.spent);
      if (!r.refused) return { amount: spent, usd: (u * Number(spent)) / Number(a), signed: r };
    }
    return null;
  }

  return Object.assign(home, {
    /// Starts the signer, which checks its chain and the coins, and reads the addresses the service and the executor use.
    async check() {
      info = await ask("info", { mints });
      Object.assign(home, { address: info.wallet, emitter: info.emitter, cctpSender: info.walletWord, cctpRecipient: info.usdcAccountWord ?? info.walletWord });
    },
    /// What the executor must pin for coin `c` here, as the signer derives it: the wallet, or its account for the coin.
    recipientFor: (c) => info.accounts[c.home].word,
    forgetRoutes: () => {},
    /// The wallet's balance of `token`, or of the gas coin for null.
    async balance(token) {
      const b = await ask("balances", { mints: token === null ? [] : [token] });
      return BigInt(token === null ? b.gas : b.tokens[token]);
    },
    /// Spends `a.amountIn` of the float for at least `a.minOut` of coin `c`, or the largest batch of it a route pays.
    async buy(a, c) {
      const pick = await batch({ inputMint: floatId, outputMint: c.home, amount: a.amountIn, minOut: a.minOut, usd: a.usd });
      if (!pick) return null;
      await commit({ ...a, usd: pick.usd, amountIn: pick.amount }, pick.signed);
      return { usd: pick.usd };
    },
    /// Sells `a.amount` of coin `c` for at least `a.minOut` of the float, or the largest batch a route pays.
    async sell(a, c, price) {
      const usd = (Number(a.amount) / 10 ** c.decimals) * price;
      const pick = await batch({ inputMint: c.home, outputMint: floatId, amount: a.amount, minOut: a.minOut, usd });
      if (!pick) return null;
      await commit({ ...a, amount: pick.amount }, pick.signed);
      return { usd: pick.usd };
    },
    /// Bridges `a.amount` of coin `c` to `executor` (a word) on Ethereum, as a transfer with a payload.
    async bridgeIn(a, c, executor) {
      const signed = await ask("buildBridgeIn", { mint: c.home, amount: String(a.amount), executor });
      const { id, receipt } = await commit(a, signed);
      // A node that does not serve the landed transaction yet leaves the sequence to the next round (restock.mjs).
      if (receipt?.status === "success") {
        const sequence = await home.sequenceOfTx(signed.signature).catch(() => null);
        if (sequence !== null) journal.note(id, { sequence: String(sequence) });
      }
    },
    sequenceOfTx: async (signature) => BigInt(await ask("sequenceOf", { signature })),
    /// Completes transfer `vaa`, which the executor bridged out to the pinned recipient here.
    redeem: (vaa) => ask("redeem", { vaa, mints }, 300_000),
    transferCompleted: (vaa) => ask("transferCompleted", { vaa }),
    /// Burns `a.amount` of the float by CCTP for `treasury` (an address) on Ethereum, paying Circle at most `maxFee`.
    async sweep(a, treasury, maxFee = 0n) {
      const signed = await ask("buildSweep", { amount: String(a.amount), treasury: evmWord(treasury), maxFee: String(maxFee) });
      await commit(a, signed, signed.eventAccount ? { eventAccount: signed.eventAccount } : {});
    },
    /// Attests token `token` (its address or coin type here) to the Token Bridge, for a copy on Ethereum (PD-7):
    /// `{signature, sequence}`.
    attest: (token) => ask("attest", { token }, 600_000),
    receive: (message, attestation) => ask("receive", { message, attestation }, 300_000),
    cctpReceived: (message) => ask("cctpReceived", { message }),
    verifyVaa,
    verifyCctp: (message, attestation) => ask("verifyCctp", { message, attestation }),
    /// Takes back the rent a burn's event account holds (Solana), with the burn's `message` and `attestation`.
    reclaim: (eventAccount, message, attestation) => ask("reclaim", { eventAccount, message, attestation }),
    resume,
  });
}
