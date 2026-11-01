// What a move's transaction must do to the wallet, checked by simulation before it is signed: every transaction the
// signer signs was built by a library or an API (Wormhole's SDK, Circle's programs, Jupiter's Swap API), and the key is
// hot, so none is trusted to do only what it says. The simulation reports the wallet's accounts after the transaction;
// each must have moved only as the move allows.

import { ComputeBudgetProgram, TransactionMessage, VersionedTransaction } from "@solana/web3.js";
import { foreignControl, MAX_COMPUTE_UNITS, tokenAmount, unitLimit } from "./checks.mjs";

export { MAX_COMPUTE_UNITS, unitLimit };

/// The most SOL one move's transaction may take from the wallet: fees, and rent for the accounts it opens (a Wormhole
/// message, a CCTP event, an associated token account), each a few thousandths of a SOL.
export const MAX_LAMPORTS_SPENT = 20_000_000n;

/// Simulates `tx` (a VersionedTransaction, unsigned) over `connection` and checks the wallet's accounts after it:
/// `wallet` (a PublicKey) and `accounts`, a list of `{address, min, max}` with `address` a token account and the change
/// it may show bounded by `min` and `max` (bigints, negative for a decrease). SOL may fall by at most
/// MAX_LAMPORTS_SPENT and never rise. Throws on a failed simulation or a change out of bounds; returns the compute units
/// the simulation consumed.
export async function simulateAndCheck(connection, tx, wallet, accounts) {
  const addresses = [wallet, ...accounts.map((a) => a.address)];
  const before = await connection.getMultipleAccountsInfo(addresses, "confirmed");
  const sim = await connection.simulateTransaction(tx, {
    sigVerify: false,
    replaceRecentBlockhash: true,
    commitment: "confirmed",
    accounts: { encoding: "base64", addresses: addresses.map((a) => a.toBase58()) },
  });
  if (sim.value.err) throw new Error(`simulation failed: ${JSON.stringify(sim.value.err)}; ${(sim.value.logs ?? []).slice(-3).join(" | ")}`);
  const after = sim.value.accounts ?? [];
  if (after.length !== addresses.length) throw new Error("simulation returned no account states");
  const lamports = (i, state) => BigInt(state?.lamports ?? 0);
  const spent = lamports(0, before[0]) - lamports(0, after[0]);
  if (spent < 0n || spent > MAX_LAMPORTS_SPENT) throw new Error(`the transaction would move ${spent} lamports of the wallet's SOL`);
  accounts.forEach((a, k) => {
    const pre = tokenAmount(before[k + 1]?.data);
    const postData = after[k + 1]?.data ? Buffer.from(after[k + 1].data[0], "base64") : null;
    const change = tokenAmount(postData) - pre;
    if (change < a.min || change > a.max) {
      throw new Error(`the transaction would change ${a.address.toBase58()} by ${change}, outside [${a.min}, ${a.max}]`);
    }
    const foreign = foreignControl(postData, wallet.toBuffer());
    if (foreign) throw new Error(`after the transaction ${a.address.toBase58()} would not be the wallet's alone: ${foreign}`);
  });
  return sim.value.unitsConsumed ?? MAX_COMPUTE_UNITS;
}

/// The programs a move's instructions may call; anything else is refused before simulation.
export function checkPrograms(instructions, allowed) {
  const names = new Set(allowed.map((p) => p.toBase58()));
  for (const ix of instructions) {
    if (!names.has(ix.programId.toBase58())) throw new Error(`instruction for an unexpected program, ${ix.programId.toBase58()}`);
  }
}

/// `instructions` as a v0 transaction paid by `payer` at `blockhash`, with `lookupTables`, a compute unit limit of
/// `units` first and `unitPrice` micro-lamports (none when null).
export function compile({ instructions, payer, blockhash, lookupTables = [], units, unitPrice = null }) {
  const budget = [ComputeBudgetProgram.setComputeUnitLimit({ units })];
  if (unitPrice !== null) budget.push(ComputeBudgetProgram.setComputeUnitPrice({ microLamports: unitPrice }));
  const message = new TransactionMessage({ payerKey: payer, recentBlockhash: blockhash, instructions: [...budget, ...instructions] });
  return new VersionedTransaction(message.compileToV0Message(lookupTables));
}

