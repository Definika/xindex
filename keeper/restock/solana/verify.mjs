// What a move's transaction must do to the wallet, checked by simulation before it is signed: every transaction the
// signer signs was built by a library or an API (Wormhole's SDK, Circle's programs, Jupiter's Swap API), and the key is
// hot, so none is trusted to do only what it says. The simulation reports the wallet's accounts after the transaction:
// its SOL, the accounts the move names, and every other token account it owns, which must not move at all (PD-1).

import { TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { ComputeBudgetProgram, PublicKey, TransactionMessage, VersionedTransaction } from "@solana/web3.js";
import { checkChanges, MAX_COMPUTE_UNITS, simulateInChunks, unitLimit, withEveryAccount } from "./checks.mjs";

export { MAX_COMPUTE_UNITS, unitLimit };

/// The most SOL one move's transaction may take from the wallet: fees, and rent for the accounts it opens (a Wormhole
/// message, a CCTP event, an associated token account), each a few thousandths of a SOL.
export const MAX_LAMPORTS_SPENT = 20_000_000n;

/// Every token account `wallet` owns, under either token program, in base58.
async function ownedTokenAccounts(connection, wallet) {
  const lists = await Promise.all(
    [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID].map((programId) => connection.getTokenAccountsByOwner(wallet, { programId }, "confirmed")),
  );
  return lists.flatMap((l) => l.value.map((a) => a.pubkey.toBase58()));
}

/// Simulates `tx` (a VersionedTransaction, unsigned) over `connection` and checks the wallet's accounts after it:
/// `wallet` (a PublicKey) and `accounts`, a list of `{address, min, max}` with `address` a token account (a PublicKey)
/// and the change it may show bounded by `min` and `max` (bigints, negative for a decrease). Every other token account
/// the wallet owns must not change. SOL may fall by at most MAX_LAMPORTS_SPENT and never rise. Throws on a failed
/// simulation or a change out of bounds; returns the compute units the simulation consumed.
export async function simulateAndCheck(connection, tx, wallet, accounts) {
  const named = accounts.map((a) => ({ ...a, address: a.address.toBase58() }));
  const bounds = withEveryAccount(named, await ownedTokenAccounts(connection, wallet));
  const addresses = [wallet.toBase58(), ...bounds.map((b) => b.address)];
  const before = (await connection.getMultipleAccountsInfo(addresses.map((a) => new PublicKey(a)), "confirmed")).map((s) =>
    s ? { lamports: s.lamports, data: s.data } : null,
  );
  const sim = await simulateInChunks(
    (list) => connection.simulateTransaction(tx, { sigVerify: false, replaceRecentBlockhash: true, commitment: "confirmed", accounts: { encoding: "base64", addresses: list } }),
    addresses,
  );
  if (sim.err) throw new Error(`simulation failed: ${JSON.stringify(sim.err)}; ${sim.logs.slice(-3).join(" | ")}`);
  const after = sim.accounts.map((s) => (s ? { lamports: s.lamports, data: Buffer.from(s.data[0], "base64") } : null));
  checkChanges({ walletKey: wallet.toBuffer(), bounds, before, after, maxSpent: MAX_LAMPORTS_SPENT });
  return sim.unitsConsumed ?? MAX_COMPUTE_UNITS;
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
