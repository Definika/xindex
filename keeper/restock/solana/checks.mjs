// The Solana signer's arithmetic and byte checks, with no dependency, so the keeper's unit tests cover them without
// installing the signer's libraries (keeper/test/unit/restock-solana.test.mjs).

/// The most compute a transaction may ask for.
export const MAX_COMPUTE_UNITS = 1_400_000;

/// The final compute unit limit for a transaction that consumed `units` in simulation: 1.2 times, as Jupiter's docs
/// recommend, within the cap.
export const unitLimit = (units) => Math.min(MAX_COMPUTE_UNITS, Math.ceil(units * 1.2));

/// The micro-lamports a compute budget `SetComputeUnitPrice` instruction (index 3, then a u64) sets, from its data, or
/// null for any other instruction.
export function unitPriceOf(data) {
  const bytes = Buffer.from(data);
  return bytes.length === 9 && bytes[0] === 3 ? bytes.readBigUInt64LE(1) : null;
}

export { slippageFor } from "../bounds.mjs";

/// An SPL token account's balance, from its data (the amount is the u64 at byte 64), or zero for no account.
export function tokenAmount(data) {
  if (!data || data.length < 72) return 0n;
  return Buffer.from(data).readBigUInt64LE(64);
}

/// What could let anyone but the wallet (its 32 key bytes, `wallet`) move a token account's coins later, which no
/// balance shows: an owner other than the wallet (bytes 32..64), a delegate (the COption tag at byte 72) or a close
/// authority (the tag at byte 129). Null when the account is the wallet's alone, or when there is no account.
export function foreignControl(data, wallet) {
  if (!data || data.length < 165) return null;
  const bytes = Buffer.from(data);
  if (!bytes.subarray(32, 64).equals(Buffer.from(wallet))) return "its owner is not the wallet";
  if (bytes.readUInt32LE(72) !== 0) return "it has a delegate";
  if (bytes.readUInt32LE(129) !== 0) return "it has a close authority";
  return null;
}

/// The most token accounts of the wallet a transaction's simulation reads back: past it, someone has opened accounts
/// for the wallet to swell every simulation, and the operator closes them before the signer signs anything again.
export const MAX_WALLET_ACCOUNTS = 64;

/// The bounds a transaction is held to: `bounds` ({address, min, max}, addresses in base58) for the accounts the move
/// may change, and no change at all for every other token account the wallet owns (`owned`, base58), so no instruction
/// can move a coin the move does not name (PD-1).
export function withEveryAccount(bounds, owned) {
  const named = new Set(bounds.map((b) => b.address));
  const all = [...bounds, ...owned.filter((a) => !named.has(a)).map((address) => ({ address, min: 0n, max: 0n, held: true }))];
  if (all.length > MAX_WALLET_ACCOUNTS) throw new Error(`the wallet owns ${all.length} token accounts, over ${MAX_WALLET_ACCOUNTS}: close the ones it does not use`);
  return all;
}

/// The accounts after a transaction, by simulation, for `addresses` in their order: `simulate(list)` runs one
/// simulation returning those of `list`. A node caps how many accounts one simulation returns, and answers more with
/// "Too many accounts provided; max N" (Solana's public RPC: 3), so the list is then simulated again in chunks of N.
/// Returns `{err, logs, unitsConsumed, accounts}`: the first failure's error and logs, if any, and every account.
export async function simulateInChunks(simulate, addresses) {
  let sims;
  try {
    sims = [await simulate(addresses)];
  } catch (error) {
    const max = Number(/Too many accounts provided; max (\d+)/.exec(String(error?.message))?.[1]);
    if (!(max > 0)) throw error;
    sims = [];
    for (let i = 0; i < addresses.length; i += max) sims.push(await simulate(addresses.slice(i, i + max)));
  }
  const failed = sims.find((s) => s.value.err);
  return {
    err: failed?.value.err ?? null,
    logs: (failed ?? sims[0]).value.logs ?? [],
    unitsConsumed: sims[0].value.unitsConsumed,
    accounts: sims.flatMap((s) => s.value.accounts ?? []),
  };
}

/// The bytes of an SPL token account that say who may move its coins: its owner (32..64), its delegate (the COption at
/// 72..108) and its close authority (129..165); null for no account.
const controlOf = (data) => (data && data.length >= 165 ? Buffer.concat([data.subarray(32, 64), data.subarray(72, 108), data.subarray(129, 165)]).toString("hex") : null);

/// Checks a simulation's accounts against what the move allows: the wallet's lamports may fall by at most `maxSpent`
/// and never rise, and each of `bounds` ({address, min, max, held}) may change only within them. An account the move
/// names must be the wallet's alone after it (`walletKey`, its 32 bytes); one it does not (`held`) must keep whoever
/// controlled it before, since an account the wallet holds may carry another's authority from before the move.
/// `before` and `after` hold `{lamports, data}` (data bytes, or null for no account), the wallet's first, then one per
/// bound, in order. Throws on the first change out of bounds.
export function checkChanges({ walletKey, bounds, before, after, maxSpent }) {
  if (before.length !== bounds.length + 1 || after.length !== bounds.length + 1) throw new Error("the simulation did not return every account asked for");
  const spent = BigInt(before[0]?.lamports ?? 0) - BigInt(after[0]?.lamports ?? 0);
  if (spent < 0n || spent > maxSpent) throw new Error(`the transaction would move ${spent} lamports of the wallet's SOL`);
  bounds.forEach((b, k) => {
    const [was, is] = [before[k + 1]?.data, after[k + 1]?.data];
    const change = tokenAmount(is) - tokenAmount(was);
    if (change < b.min || change > b.max) throw new Error(`the transaction would change ${b.address} by ${change}, outside [${b.min}, ${b.max}]`);
    if (b.held) {
      if (controlOf(is) !== controlOf(was)) throw new Error(`the transaction would change who controls ${b.address}`);
      return;
    }
    const foreign = foreignControl(is, walletKey);
    if (foreign) throw new Error(`after the transaction ${b.address} would not be the wallet's alone: ${foreign}`);
  });
}

/// The routes of Jupiter's v6 program this signer signs, by instruction name, with the position in each one's account
/// list of every account the check names (its IDL, read on chain on 2026-11-02). An optional account a route leaves
/// out holds the program's own address, Anchor's convention.
export const JUPITER_ROUTES = Object.freeze({
  route: { authority: 1, source: 2, destination: 3, destinationOverride: 4, outputMint: 5, platformFee: 6 },
  shared_accounts_route: { authority: 2, source: 3, destination: 6, inputMint: 7, outputMint: 8, platformFee: 9 },
  route_v2: { authority: 0, source: 1, destination: 2, inputMint: 3, outputMint: 4, destinationOverride: 7 },
  shared_accounts_route_v2: { authority: 1, source: 2, destination: 5, inputMint: 6, outputMint: 7 },
});

/// Checks Jupiter's instructions (its answer's JSON: program and account keys in base58, data in base64) against the
/// swap asked for, with every key in base58: exactly one instruction may call one of `programs`, and it must be a
/// route of JUPITER_ROUTES, read by `decode(data)` ({name, args} from the program's IDL, `idl-decode.mjs`), that spends
/// exactly `amount` of `inputMint` from `inAccount` under the wallet's signature, pays `outAccount` in `outputMint`,
/// charges no platform fee and keeps none of the surplus, and whose on-chain minimum, the quoted output less its
/// slippage, is `minOut` or more (PD-1, PD-2). Returns that minimum; throws otherwise.
export function checkJupiterSwap({ instructions, programs, decode, wallet, inAccount, outAccount, inputMint, outputMint, amount, minOut }) {
  const calls = instructions.filter((ix) => programs.includes(ix.programId));
  if (calls.length !== 1) throw new Error(`Jupiter's answer calls its program ${calls.length} times, not once`);
  const [ix] = calls;
  const decoded = decode(Buffer.from(ix.data, "base64"));
  const at = decoded ? JUPITER_ROUTES[decoded.name] : undefined;
  if (!at) throw new Error(`Jupiter's swap is ${decoded?.name ?? "an instruction its IDL does not name"}, not a route this signer checks`);
  const key = (i) => ix.accounts[i]?.pubkey;
  if (key(at.authority) !== wallet || !ix.accounts[at.authority].isSigner) throw new Error("Jupiter's swap is not under the wallet's signature");
  if (key(at.source) !== inAccount) throw new Error(`Jupiter's swap spends from ${key(at.source)}, not the wallet's ${inAccount}`);
  if (key(at.destination) !== outAccount) throw new Error(`Jupiter's swap pays ${key(at.destination)}, not the wallet's ${outAccount}`);
  if (at.destinationOverride !== undefined && ![ix.programId, outAccount].includes(key(at.destinationOverride))) throw new Error("Jupiter's swap pays its output elsewhere");
  if (at.platformFee !== undefined && key(at.platformFee) !== ix.programId) throw new Error("Jupiter's swap names a platform fee account");
  if (at.inputMint !== undefined && key(at.inputMint) !== inputMint) throw new Error("Jupiter's swap spends another coin");
  if (at.outputMint !== undefined && key(at.outputMint) !== outputMint) throw new Error("Jupiter's swap buys another coin");
  const { in_amount: inAmount, quoted_out_amount: quoted, slippage_bps: slippage, platform_fee_bps: fee, positive_slippage_bps: kept = 0 } = decoded.args;
  if (BigInt(inAmount) !== amount) throw new Error(`Jupiter's swap spends ${inAmount}, not ${amount}`);
  if (Number(fee) !== 0 || Number(kept) !== 0) throw new Error(`Jupiter's swap charges a fee of ${fee} bps and keeps ${kept} bps of the surplus`);
  if (Number(slippage) > 10_000) throw new Error(`Jupiter's swap has a slippage of ${slippage} bps`);
  const onChainMin = (BigInt(quoted) * BigInt(10_000 - Number(slippage))) / 10_000n;
  if (onChainMin < minOut) throw new Error(`Jupiter's swap would accept ${onChainMin}, under the floor of ${minOut}`);
  return onChainMin;
}
