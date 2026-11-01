// The restock service's home on Solana: the same moves as an EVM home (`evm.mjs` createEvmHome), made through the
// Solana signer, a child process of its own (`solana/signer.mjs`, D3 of design/2026-11-01-non-evm-restock.md) that
// alone holds the Solana key and loads the Solana libraries. This side has no dependency: it starts the signer with an
// environment that names only what the signer needs, never the treasury's key, journals every move the signer signs
// before sending it, sends and confirms it through Solana's JSON-RPC, and resumes it after a restart as Solana
// recommends (`solana-sending.mjs`).

import { spawn } from "node:child_process";
import { CHAINS } from "./coins.mjs";
import { createSolanaRpc, evmWord, resumeDecision } from "./solana-sending.mjs";

const SIGNER = new URL("./solana/signer.mjs", import.meta.url).pathname;
/// How long a move's transaction is watched for confirmation before it is left to the next round's resume.
const CONFIRM_SECONDS = 90;

/// The Solana signer at `path` as a request-answer channel: `ask(op, args)` resolves with the answer's result. The
/// signer starts with `env` and nothing else of this process's environment, and starts again on the next request after
/// it exits.
export function startSigner({ env, path = SIGNER, timeoutMs = 120_000 }) {
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
    child = spawn(process.execPath, [path], { env, stdio: ["pipe", "pipe", "inherit"] });
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
          continue; // not an answer: libraries print to stderr, but a stray line must not break the channel
        }
        const waiting = pending.get(message?.id);
        if (!waiting) continue;
        pending.delete(message.id);
        clearTimeout(waiting.timer);
        if (message.ok) waiting.resolve(message.result);
        else waiting.reject(new Error(`solana: ${message.error}`));
      }
    });
    child.on("exit", (code) => {
      child = null;
      failAll(new Error(`the Solana signer exited (${code})`));
    });
  }
  return function ask(op, args = {}, ms = timeoutMs) {
    if (!child) start();
    const id = next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`the Solana signer did not answer ${op} in ${ms / 1000} s`));
      }, ms);
      pending.set(id, { resolve, reject, timer });
      child.stdin.write(`${JSON.stringify({ id, op, args })}\n`);
    });
  };
}

/// The Solana signer's whole environment, from the chain's settings: never this process's, which holds the treasury's
/// key (D3).
export function signerEnv(settings) {
  const env = { PATH: process.env.PATH ?? "", SOLANA_RPC_URL: settings.rpcUrl, SOLANA_KEY: settings.key, JUPITER_API_KEY: settings.jupiterApiKey };
  const optional = { JUPITER_URL: settings.jupiterUrl, JUPITER_PROGRAMS: settings.jupiterPrograms, SOLANA_MAX_UNIT_PRICE: settings.maxUnitPrice };
  for (const [key, value] of Object.entries(optional)) if (value) env[key] = value;
  return env;
}

/// The restock service's home on Solana. `settings` is the chain's configuration (`config.mjs`): its RPC, its key,
/// Jupiter's key and the signer's options. `coins` are the coins served here; `verifyVaa` is Ethereum's core check,
/// which also vouches for the VAAs redeemed here (D5); `cfg` is the plan's `{minUsd}`. The signer's environment holds
/// exactly PATH, SOLANA_RPC_URL, SOLANA_KEY and JUPITER_API_KEY, and the optional settings set (`signerEnv`).
export function createSolanaHome({ settings, coins, journal, cfg, verifyVaa, signerPath = SIGNER }) {
  const name = "solana";
  const rpc = createSolanaRpc({ url: settings.rpcUrl });
  const ask = startSigner({ env: signerEnv(settings), path: signerPath });
  const mints = coins.map((c) => c.home);
  const usdc = CHAINS.solana.float.id;
  let info = null;
  const home = {
    name,
    def: { wormhole: CHAINS.solana.wormhole, cctpDomain: CHAINS.solana.cctpDomain },
  };

  /// Records the signed move `action` in the journal, sends it, and watches it to confirmation; a move not confirmed in
  /// time is left signed, for {resume}. Returns its id and `{status}` once confirmed, or null.
  async function commit(action, signed) {
    const id = journal.open(action, { chain: name, raw: signed.raw, hash: signed.signature, lastValidBlockHeight: signed.lastValidBlockHeight });
    await rpc("sendTransaction", [signed.raw, { encoding: "base64", preflightCommitment: "confirmed", maxRetries: 0 }]).catch(() => {});
    for (let s = 0; s < CONFIRM_SECONDS; s += 2) {
      await new Promise((r) => setTimeout(r, 2000));
      const settled = await resume(journal.get(id));
      if (settled) return { id, receipt: settled };
      if (!journal.get(id) || journal.get(id).stage !== "signed") return { id, receipt: null };
    }
    return { id, receipt: null };
  }

  /// A move left signed: `{status}` if it landed, the move moved to "sent"; otherwise it is sent again while it can
  /// still land, or dropped once it cannot (`resumeDecision`). Returns `{status}` or null.
  async function resume(move) {
    const [statuses, finalizedHeight] = await Promise.all([
      rpc("getSignatureStatuses", [[move.data.hash], { searchTransactionHistory: true }]),
      rpc("getBlockHeight", [{ commitment: "finalized" }]),
    ]);
    const status = statuses?.value?.[0] ?? null;
    const decision = resumeDecision({ status, finalizedHeight, lastValidBlockHeight: move.data.lastValidBlockHeight });
    if (decision.sent) {
      journal.advance(move.id, "sent", { slot: String(status.slot), status: decision.sent });
      return { status: decision.sent };
    }
    if (decision.drop) {
      journal.drop(move.id, decision.drop);
      return null;
    }
    await rpc("sendTransaction", [move.data.raw, { encoding: "base64", skipPreflight: true, maxRetries: 0 }]).catch(() => {});
    return null;
  }

  /// Swaps through the signer in the largest batch, halving down to RESTOCK_MIN_USD, whose route pays the batch's
  /// share of `minOut`: `{amount, signed}` or null.
  async function batch({ inputMint, outputMint, amount, minOut, usd }) {
    for (let a = amount, m = minOut, u = usd; a > 0n && u >= cfg.minUsd; a /= 2n, m /= 2n, u /= 2) {
      const r = await ask("buildSwap", { inputMint, outputMint, amount: String(a), minOut: String(m) });
      if (!r.refused) return { amount: a, usd: u, signed: r };
    }
    return null;
  }

  return Object.assign(home, {
    /// Starts the signer and checks the chain and the mints, reading the addresses the service and the executor use.
    async check() {
      info = await ask("info", { mints });
      Object.assign(home, { address: info.wallet, emitter: info.emitter, cctpSender: info.walletWord, cctpRecipient: info.usdcAccountWord });
    },
    /// What the executor must pin for coin `c` here: the wallet's token account for its mint, which Solana's bridge pays.
    recipientFor: (c) => info.accounts[c.home].word,
    forgetRoutes: () => {},
    /// The wallet's balance of mint `token`, or its SOL for null.
    async balance(token) {
      const b = await ask("balances", { mints: token === null ? [] : [token] });
      return BigInt(token === null ? b.sol : b.tokens[token]);
    },
    /// Buys action `a`'s coin `c`: spends `a.amountIn` of USDC for at least `a.minOut`, or the largest batch of it a
    /// route pays; null when none does.
    async buy(a, c) {
      const pick = await batch({ inputMint: usdc, outputMint: c.home, amount: a.amountIn, minOut: a.minOut, usd: a.usd });
      if (!pick) return null;
      await commit({ ...a, usd: pick.usd, amountIn: pick.amount }, pick.signed);
      return { usd: pick.usd };
    },
    /// Sells action `a`'s `a.amount` of coin `c` for at least `a.minOut` of USDC, or the largest batch a route pays.
    async sell(a, c, price) {
      const usd = (Number(a.amount) / 10 ** c.decimals) * price;
      const pick = await batch({ inputMint: c.home, outputMint: usdc, amount: a.amount, minOut: a.minOut, usd });
      if (!pick) return null;
      await commit({ ...a, amount: pick.amount }, pick.signed);
      return { usd: pick.usd };
    },
    /// Bridges action `a`'s `a.amount` of coin `c` to `executor` (a word) on Ethereum, with its payload.
    async bridgeIn(a, c, executor) {
      const signed = await ask("buildBridgeIn", { mint: c.home, amount: String(a.amount), executor });
      const { id, receipt } = await commit(a, signed);
      // The sequence is read from the confirmed transaction; a node that does not serve it yet leaves it to the next
      // round's look (restock.mjs advance), as the move is already sent.
      if (receipt?.status === "success") {
        const sequence = await home.sequenceOfTx(signed.signature).catch(() => null);
        if (sequence !== null) journal.note(id, { sequence: String(sequence) });
      }
    },
    sequenceOfTx: async (signature) => BigInt(await ask("sequenceOf", { signature })),
    /// Completes transfer `vaa`, which the executor bridged out to the wallet's token account.
    redeem: (vaa) => ask("redeem", { vaa, mints }, 300_000),
    transferCompleted: (vaa) => ask("transferCompleted", { vaa }),
    /// Burns action `a`'s `a.amount` of USDC by CCTP for `treasury` (an address) on Ethereum.
    async sweep(a, treasury) {
      const signed = await ask("buildSweep", { amount: String(a.amount), treasury: evmWord(treasury) });
      await commit({ ...a, eventAccount: signed.eventAccount }, signed);
    },
    receive: (message, attestation) => ask("receive", { message, attestation }, 300_000),
    cctpReceived: (message) => ask("cctpReceived", { message }),
    verifyVaa,
    verifyCctp: (message, attestation) => ask("verifyCctp", { message, attestation }),
    resume,
  });
}
