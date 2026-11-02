// The Solana signer's answers (`signer.mjs`): what the restock service's parent process asks of Solana, each in plain
// JSON (amounts as decimal strings, words as 0x-hex, transactions as base64). A move that commits funds (a swap, a
// bridge transfer, a CCTP burn) comes back built, checked by simulation and signed, never sent: the parent records it
// in its journal first, then sends it. Steps that only complete a move (a redeem, a CCTP receipt) are sent here, since
// their programs count each once.

import {
  createAssociatedTokenAccountIdempotentInstruction,
  getAssociatedTokenAddressSync,
  TOKEN_2022_PROGRAM_ID,
} from "@solana/spl-token";
import { PublicKey, Transaction } from "@solana/web3.js";
import { utils } from "@coral-xyz/anchor";
import { resumeDecision, solanaExpiry } from "../solana-sending.mjs";
import { USDC_MINT } from "./cctp.mjs";
import { compile, MAX_COMPUTE_UNITS, simulateAndCheck, unitLimit } from "./verify.mjs";

/// Solana mainnet's genesis hash: the RPC must serve this chain.
export const MAINNET_GENESIS = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d";

const word = (key) => `0x${key.toBuffer().toString("hex")}`;
const big = (x) => BigInt(x);

export function createMoves({ connection, wallet, jupiter, cctp, wormhole, maxUnitPrice, genesis = MAINNET_GENESIS }) {
  const ata = (mint) => getAssociatedTokenAddressSync(mint, wallet.publicKey);
  const tokenBalance = async (account) => {
    const info = await connection.getAccountInfo(account, "confirmed");
    return info ? info.data.readBigUInt64LE(64) : 0n;
  };

  /// A compute unit price for a transaction writing `accounts`: the median of the recent non-zero prices paid for
  /// them, within the operator's cap.
  async function unitPrice(accounts) {
    const recent = (await connection.getRecentPrioritizationFees({ lockedWritableAccounts: accounts }))
      .map((f) => BigInt(f.prioritizationFee))
      .filter((p) => p > 0n)
      .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const median = recent.length ? recent[Math.floor(recent.length / 2)] : 1n;
    return median > maxUnitPrice ? maxUnitPrice : median;
  }

  /// `instructions` signed by the wallet and `signers`, after a simulation that moves the wallet's accounts only within
  /// `bounds` ({address, min, max}): the base64 transaction, its signature and the block height past which it can no
  /// longer land.
  async function checkedAndSigned(instructions, signers, bounds) {
    const writable = [...new Set(instructions.flatMap((ix) => ix.keys.filter((k) => k.isWritable).map((k) => k.pubkey.toBase58())))]
      .slice(0, 128)
      .map((k) => new PublicKey(k));
    const price = await unitPrice(writable);
    const {
      context: { slot },
      value: { blockhash, lastValidBlockHeight },
    } = await connection.getLatestBlockhashAndContext("confirmed");
    const draft = compile({ instructions, payer: wallet.publicKey, blockhash, units: MAX_COMPUTE_UNITS, unitPrice: price });
    const units = await simulateAndCheck(connection, draft, wallet.publicKey, bounds);
    const tx = compile({ instructions, payer: wallet.publicKey, blockhash, units: unitLimit(units), unitPrice: price });
    return signed(tx, signers, lastValidBlockHeight, slot);
  }

  /// `tx` signed: its bytes in base64, its signature, and its expiry: the block height past which it cannot land, and
  /// the slot it was built at, before which it cannot have landed (`solanaExpiry`).
  function signed(tx, signers, lastValidBlockHeight, sentSlot) {
    tx.sign([wallet, ...signers]);
    return {
      raw: Buffer.from(tx.serialize()).toString("base64"),
      signature: utils.bytes.bs58.encode(tx.signatures[0]),
      expiry: JSON.stringify({ lastValidBlockHeight: String(lastValidBlockHeight), sentSlot: String(sentSlot) }),
    };
  }

  /// Signs and sends `tx` (a legacy Transaction the SDK built, with its extra `signers`), and waits for it to be
  /// confirmed; throws if it fails. For the steps that only complete a move.
  async function sendLegacy({ transaction, signers = [] }) {
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash("confirmed");
    transaction.recentBlockhash = blockhash;
    transaction.feePayer = wallet.publicKey;
    transaction.sign(wallet, ...signers);
    const signature = await connection.sendRawTransaction(transaction.serialize(), { preflightCommitment: "confirmed" });
    const { value } = await connection.confirmTransaction({ signature, blockhash, lastValidBlockHeight }, "confirmed");
    if (value.err) throw new Error(`${signature} failed: ${JSON.stringify(value.err)}`);
    return signature;
  }

  /// Waits until `signature` is confirmed; throws if it failed, or once the block height passes `lastValidBlockHeight`
  /// with it unconfirmed.
  async function confirmed(signature, lastValidBlockHeight) {
    for (;;) {
      const s = (await connection.getSignatureStatuses([signature])).value[0];
      if (s?.confirmationStatus === "confirmed" || s?.confirmationStatus === "finalized") {
        if (s.err) throw new Error(`${signature} failed: ${JSON.stringify(s.err)}`);
        return;
      }
      if ((await connection.getBlockHeight("confirmed")) > Number(lastValidBlockHeight)) throw new Error(`${signature} expired unconfirmed`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }

  /// Refuses a mint the manual Token Bridge route cannot carry (Token-2022), or that does not exist.
  async function checkMint(mint) {
    const info = await connection.getAccountInfo(mint, "confirmed");
    if (!info) throw new Error(`mint ${mint.toBase58()} does not exist`);
    if (info.owner.equals(TOKEN_2022_PROGRAM_ID)) throw new Error(`mint ${mint.toBase58()} is a Token-2022 mint, which the Token Bridge's manual route refuses`);
  }

  return {
    /// The wallet and the addresses the parent needs, after checking the RPC serves mainnet and every mint is one the
    /// bridge carries: `accounts` holds each mint's token account of the wallet, which the executor must pin for it.
    async info({ mints }) {
      const served = await connection.getGenesisHash();
      if (served !== genesis) throw new Error(`the RPC serves genesis ${served}, not Solana mainnet's`);
      for (const m of mints) await checkMint(new PublicKey(m));
      const accounts = Object.fromEntries(mints.map((m) => [m, { address: ata(new PublicKey(m)).toBase58(), word: word(ata(new PublicKey(m))) }]));
      return {
        wallet: wallet.publicKey.toBase58(),
        walletWord: word(wallet.publicKey),
        emitter: word(wormhole.emitter),
        usdcAccount: cctp.usdcAccount.toBase58(),
        usdcAccountWord: word(cctp.usdcAccount),
        accounts,
      };
    },
    /// The wallet's SOL, in lamports, and its balance of each token: `{gas, tokens: {mint: amount}}`.
    async balances({ mints }) {
      const tokens = {};
      for (const m of mints) tokens[m] = String(await tokenBalance(ata(new PublicKey(m))));
      return { gas: String(await connection.getBalance(wallet.publicKey, "confirmed")), tokens };
    },
    /// Sends signed transaction `raw` (base64) as it is: a move the parent journalled, sent once or sent again.
    send: async ({ raw }) => connection.sendRawTransaction(Buffer.from(raw, "base64"), { skipPreflight: true, maxRetries: 0 }),
    /// What became of transaction `signature` with `expiry` (`solanaExpiry`): landed, reverted, pending, expired once
    /// the finalized height has passed it with no status from a node that has seen that far and keeps the slots since
    /// the transaction was built, or unknown while no node at hand can say (`resumeDecision`, PD-8).
    async status({ signature, expiry }) {
      const { lastValidBlockHeight, sentSlot } = solanaExpiry(expiry);
      const [{ context, value }, epoch, firstAvailableSlot] = await Promise.all([
        connection.getSignatureStatuses([signature], { searchTransactionHistory: true }),
        connection.getEpochInfo("finalized"),
        connection.getFirstAvailableBlock(),
      ]);
      const facts = {
        status: value[0],
        finalizedHeight: epoch.blockHeight,
        finalizedSlot: epoch.absoluteSlot,
        statusSlot: context.slot,
        firstAvailableSlot,
        lastValidBlockHeight,
        sentSlot,
      };
      let decision = resumeDecision(facts);
      let at = value[0]?.slot;
      if (decision.unknown || decision.drop) {
        // A second witness before a drop: the transaction itself, from a node that keeps the history.
        const transaction = await connection
          .getTransaction(signature, { commitment: "confirmed", maxSupportedTransactionVersion: 0 })
          .then((t) => (t ? { err: t.meta?.err ?? null, slot: t.slot } : null))
          .catch((error) => (/history is not available/i.test(String(error?.message)) ? "unavailable" : Promise.reject(error)));
        decision = resumeDecision({ ...facts, transaction });
        at = transaction?.slot ?? at;
      }
      if (decision.sent) return { state: decision.sent === "success" ? "landed" : "reverted", at: String(at) };
      if (decision.drop) return { state: "expired", reason: decision.drop };
      if (decision.unknown) return { state: "unknown", reason: decision.unknown };
      return { state: "pending" };
    },
    /// A swap of `amount` of `inputMint` for at least `minOut` of `outputMint` through Jupiter, signed; or
    /// `{refused: "loss", outAmount}` when no route pays `minOut`.
    async buildSwap({ inputMint, outputMint, amount, minOut }) {
      const r = await jupiter.swapTransaction({
        inputMint: new PublicKey(inputMint),
        outputMint: new PublicKey(outputMint),
        amount: big(amount),
        minOut: big(minOut),
        maxUnitPrice,
      });
      if (r.refused) return { refused: r.refused, outAmount: String(r.outAmount) };
      return { ...signed(r.transaction, [], r.lastValidBlockHeight, r.sentSlot), outAmount: String(r.outAmount), minOut: String(r.minOut) };
    },
    /// The Token Bridge transfer of `amount` of `mint` to `executor` (a word) on Ethereum, with its payload, signed:
    /// it must take exactly `amount` of the coin, which the bridge carries whole at its six decimals.
    async buildBridgeIn({ mint, amount, executor }) {
      const coin = new PublicKey(mint);
      await checkMint(coin);
      const { instructions, signers } = await wormhole.transferTransaction(coin, big(amount), executor);
      return checkedAndSigned(instructions, signers, [{ address: ata(coin), min: -big(amount), max: -big(amount) }]);
    },
    /// The CCTP burn of `amount` of USDC for `treasury` (a word) on Ethereum, paying Circle at most `maxFee` (PD-12),
    /// signed: it must take exactly `amount`. `eventAccount` is kept for the rent's reclaim.
    async buildSweep({ amount, treasury, maxFee = "0" }) {
      const { transaction, signers, eventAccount } = await cctp.burnTransaction(big(amount), treasury, big(maxFee));
      const out = await checkedAndSigned(transaction.instructions, signers, [{ address: cctp.usdcAccount, min: -big(amount), max: -big(amount) }]);
      return { ...out, eventAccount: eventAccount.toBase58() };
    },
    /// Attests SPL token `token` to the Token Bridge, which publishes its decimals, symbol and name for a copy on
    /// Ethereum (PD-7). It commits no funds, only fees, so it is signed and sent here, after a simulation in which no
    /// token of the wallet moves: the signature and the sequence the bridge published.
    async attest({ token }) {
      const mint = new PublicKey(token);
      await checkMint(mint);
      const { instructions, signers } = await wormhole.attestTransaction(mint);
      const s = await checkedAndSigned(instructions, signers, []);
      await connection.sendRawTransaction(Buffer.from(s.raw, "base64"), { maxRetries: 5 });
      await confirmed(s.signature, solanaExpiry(s.expiry).lastValidBlockHeight);
      return { signature: s.signature, sequence: String(await wormhole.sequenceOf(s.signature)) };
    },
    /// The sequence the Token Bridge published in transaction `signature`.
    sequenceOf: async ({ signature }) => String(await wormhole.sequenceOf(signature)),
    transferCompleted: ({ vaa }) => wormhole.transferCompleted(vaa),
    /// Completes transfer `vaa`, of a coin among `mints`, to the wallet's token account for it; the signatures sent.
    async redeem({ vaa, mints }) {
      const mint = wormhole.mintOf(vaa);
      if (!mints.includes(mint.toBase58())) throw new Error(`the transfer carries ${mint.toBase58()}, which the service does not serve`);
      const txs = await wormhole.redeemTransactions(vaa, mint);
      const sent = [];
      for (const t of txs) sent.push(await sendLegacy(t));
      return sent;
    },
    cctpReceived: ({ message }) => cctp.received(message),
    /// Whether this chain would receive CCTP `message` with `attestation`: a simulation, or the message received
    /// already.
    async verifyCctp({ message, attestation }) {
      if (await cctp.received(message)) return { valid: true, reason: "" };
      const ready = await connection.getAccountInfo(cctp.usdcAccount, "confirmed");
      if (!ready) return { valid: true, reason: "" }; // opened by `receive` itself, before the receipt
      const transaction = await cctp.receiveTransaction(message, attestation);
      const { blockhash } = await connection.getLatestBlockhash("confirmed");
      const tx = compile({ instructions: transaction.instructions, payer: wallet.publicKey, blockhash, units: MAX_COMPUTE_UNITS });
      const sim = await connection.simulateTransaction(tx, { sigVerify: false, replaceRecentBlockhash: true, commitment: "confirmed" });
      return sim.value.err ? { valid: false, reason: JSON.stringify(sim.value.err) } : { valid: true, reason: "" };
    },
    /// Receives CCTP `message` with `attestation` into the wallet's USDC account, opening the account first if missing
    /// (the receipt reverts without it); the signature, or null when it was received already.
    async receive({ message, attestation }) {
      if (await cctp.received(message)) return null;
      if (!(await connection.getAccountInfo(cctp.usdcAccount, "confirmed"))) {
        const open = createAssociatedTokenAccountIdempotentInstruction(wallet.publicKey, cctp.usdcAccount, wallet.publicKey, USDC_MINT);
        await sendLegacy({ transaction: new Transaction().add(open) });
      }
      return sendLegacy({ transaction: await cctp.receiveTransaction(message, attestation) });
    },
    /// Takes back the rent of burn event account `eventAccount`, five days after its burn, with the burn's `message`
    /// and `attestation`; null when the account is gone already.
    async reclaim({ eventAccount, message, attestation }) {
      const account = new PublicKey(eventAccount);
      if (!(await connection.getAccountInfo(account, "confirmed"))) return null;
      return sendLegacy({ transaction: await cctp.reclaimTransaction(account, message, attestation) });
    },
  };
}
