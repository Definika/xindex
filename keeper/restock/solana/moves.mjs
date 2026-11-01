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
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash("confirmed");
    const draft = compile({ instructions, payer: wallet.publicKey, blockhash, units: MAX_COMPUTE_UNITS, unitPrice: price });
    const units = await simulateAndCheck(connection, draft, wallet.publicKey, bounds);
    const tx = compile({ instructions, payer: wallet.publicKey, blockhash, units: unitLimit(units), unitPrice: price });
    return signed(tx, signers, lastValidBlockHeight);
  }

  function signed(tx, signers, lastValidBlockHeight) {
    tx.sign([wallet, ...signers]);
    return {
      raw: Buffer.from(tx.serialize()).toString("base64"),
      signature: utils.bytes.bs58.encode(tx.signatures[0]),
      lastValidBlockHeight: String(lastValidBlockHeight),
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
    /// The wallet's SOL, in lamports, and its balance of each token: `{sol, tokens: {mint: amount}}`.
    async balances({ mints }) {
      const tokens = {};
      for (const m of mints) tokens[m] = String(await tokenBalance(ata(new PublicKey(m))));
      return { sol: String(await connection.getBalance(wallet.publicKey, "confirmed")), tokens };
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
      return { ...signed(r.transaction, [], r.lastValidBlockHeight), outAmount: String(r.outAmount), minOut: String(r.minOut) };
    },
    /// The Token Bridge transfer of `amount` of `mint` to `executor` (a word) on Ethereum, with its payload, signed:
    /// it must take exactly `amount` of the coin, which the bridge carries whole at its six decimals.
    async buildBridgeIn({ mint, amount, executor }) {
      const coin = new PublicKey(mint);
      await checkMint(coin);
      const { instructions, signers } = await wormhole.transferTransaction(coin, big(amount), executor);
      return checkedAndSigned(instructions, signers, [{ address: ata(coin), min: -big(amount), max: -big(amount) }]);
    },
    /// The CCTP burn of `amount` of USDC for `treasury` (a word) on Ethereum, signed: it must take exactly `amount`.
    /// `eventAccount` is kept for the rent's reclaim.
    async buildSweep({ amount, treasury }) {
      const { transaction, signers, eventAccount } = await cctp.burnTransaction(big(amount), treasury);
      const out = await checkedAndSigned(transaction.instructions, signers, [{ address: cctp.usdcAccount, min: -big(amount), max: -big(amount) }]);
      return { ...out, eventAccount: eventAccount.toBase58() };
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
  };
}
