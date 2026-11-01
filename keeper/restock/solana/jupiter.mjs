// Jupiter's Swap V2, used as its docs recommend for a caller that sends through its own RPC
// (developers.jup.ag/docs/swap/build): `GET /swap/v2/build` answers with a quote and the instructions; the caller adds
// the compute unit limit from a simulation, checks the compute unit price, compiles the v0 transaction with the lookup
// tables, and signs it. Exact input only, which the restock's plan allows for: a buy spends `amountIn` of the float for
// at least `minOut` of the coin, a sale sells `amount` of the coin for at least `minOut` of the float, both bounded at
// Pyth's price. The answer is not trusted (`verify.mjs`): the instructions may call only the expected programs, and the
// simulation must move the wallet's accounts only as the swap allows.

import { getAssociatedTokenAddressSync, ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { ComputeBudgetProgram, PublicKey, TransactionInstruction } from "@solana/web3.js";
import { slippageFor, unitPriceOf } from "./checks.mjs";
import { checkPrograms, compile, MAX_COMPUTE_UNITS, simulateAndCheck, unitLimit } from "./verify.mjs";

/// Jupiter's aggregator program (v6), which `/build`'s swap instruction calls; JUPITER_PROGRAMS adds others, should
/// Jupiter move its routing to another program (to confirm on the first live build).
export const JUPITER_PROGRAM = new PublicKey("JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4");
/// The associated token program's `CreateIdempotent` instruction, the only setup a swap may carry: it opens one of the
/// wallet's own token accounts if missing (accounts: payer, account, owner, mint, system program, token program).
const CREATE_IDEMPOTENT = 1;

const toInstruction = (ix) =>
  new TransactionInstruction({
    programId: new PublicKey(ix.programId),
    keys: ix.accounts.map((a) => ({ pubkey: new PublicKey(a.pubkey), isSigner: a.isSigner, isWritable: a.isWritable })),
    data: Buffer.from(ix.data, "base64"),
  });

/// Jupiter over `url` with `apiKey`, building for `wallet` (a Keypair) over `connection`.
export function createJupiter({ url, apiKey, connection, wallet, programs = [], fetchImpl = fetch }) {
  const base = url.replace(/\/+$/, "");
  const jupiterPrograms = [JUPITER_PROGRAM, ...programs];

  /// Refuses any instruction but Jupiter's and the creation of one of the wallet's own token accounts: a top-level
  /// token instruction could approve a delegate, which moves no balance a simulation would show.
  function checkInstructions(instructions) {
    checkPrograms(instructions, [...jupiterPrograms, ASSOCIATED_TOKEN_PROGRAM_ID]);
    for (const ix of instructions) {
      if (!ix.programId.equals(ASSOCIATED_TOKEN_PROGRAM_ID)) continue;
      const [payer, account, owner, mint] = ix.keys.map((k) => k.pubkey);
      const own = payer?.equals(wallet.publicKey) && owner?.equals(wallet.publicKey);
      if (ix.data.length !== 1 || ix.data[0] !== CREATE_IDEMPOTENT || !own || !account?.equals(getAssociatedTokenAddressSync(mint, wallet.publicKey))) {
        throw new Error("a setup instruction that is not the creation of the wallet's own token account");
      }
    }
  }

  async function build({ inputMint, outputMint, amount, slippageBps }) {
    const query = new URLSearchParams({
      inputMint: inputMint.toBase58(),
      outputMint: outputMint.toBase58(),
      amount: amount.toString(),
      taker: wallet.publicKey.toBase58(),
      slippageBps: String(slippageBps),
      wrapAndUnwrapSol: "false",
    });
    const response = await fetchImpl(`${base}/swap/v2/build?${query}`, {
      headers: { "x-api-key": apiKey },
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error(`Jupiter ${response.status}: ${(await response.text()).slice(0, 200)}`);
    const quote = await response.json();
    // The quote is for exactly this swap, exact input.
    if (quote.inputMint !== inputMint.toBase58() || quote.outputMint !== outputMint.toBase58()) throw new Error("Jupiter quoted other mints");
    if (BigInt(quote.inAmount) !== amount) throw new Error(`Jupiter quoted ${quote.inAmount} in, not ${amount}`);
    if (quote.swapMode !== undefined && quote.swapMode !== "ExactIn") throw new Error(`Jupiter quoted ${quote.swapMode}`);
    return quote;
  }

  /// The swap of `amount` of `inputMint` for at least `minOut` of `outputMint` (PublicKeys and bigints), signed by the
  /// wallet, at a compute unit price of at most `maxUnitPrice` micro-lamports: `{transaction, outAmount, minOut}`
  /// unsigned, or `{refused: "loss", outAmount}` when the best route pays less than `minOut`.
  async function swapTransaction({ inputMint, outputMint, amount, minOut, maxUnitPrice }) {
    const probe = await build({ inputMint, outputMint, amount, slippageBps: 0 });
    const slippageBps = slippageFor(BigInt(probe.outAmount), minOut);
    if (slippageBps === null) return { refused: "loss", outAmount: BigInt(probe.outAmount) };
    const quote = await build({ inputMint, outputMint, amount, slippageBps });
    if (BigInt(quote.otherAmountThreshold) < minOut) return { refused: "loss", outAmount: BigInt(quote.outAmount) };

    const instructions = [
      ...(quote.setupInstructions ?? []),
      quote.swapInstruction,
      ...(quote.cleanupInstruction ? [quote.cleanupInstruction] : []),
      ...(quote.otherInstructions ?? []),
    ].map(toInstruction);
    checkInstructions(instructions);
    const swapProgram = toInstruction(quote.swapInstruction).programId;
    if (!jupiterPrograms.some((p) => p.equals(swapProgram))) throw new Error("the swap is not Jupiter's");
    // Jupiter's price, within the operator's cap (its docs warn it spikes when recent blocks bid extreme values).
    let unitPrice = 0n;
    for (const ix of quote.computeBudgetInstructions ?? []) {
      const price = unitPriceOf(Buffer.from(ix.data, "base64"));
      if (price !== null && new PublicKey(ix.programId).equals(ComputeBudgetProgram.programId)) unitPrice = price;
    }
    if (unitPrice > maxUnitPrice) unitPrice = maxUnitPrice;

    const lookupTables = [];
    for (const key of Object.keys(quote.addressesByLookupTableAddress ?? {})) {
      const table = (await connection.getAddressLookupTable(new PublicKey(key))).value;
      if (!table) throw new Error(`lookup table ${key} not found`);
      const listed = quote.addressesByLookupTableAddress[key];
      const onChain = table.state.addresses.map((a) => a.toBase58());
      if (listed.some((a, i) => onChain[i] !== a)) throw new Error(`lookup table ${key} differs from Jupiter's`);
      lookupTables.push(table);
    }
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash("confirmed");
    const inAccount = getAssociatedTokenAddressSync(inputMint, wallet.publicKey);
    const outAccount = getAssociatedTokenAddressSync(outputMint, wallet.publicKey);
    const bounds = [
      { address: inAccount, min: -amount, max: 0n },
      { address: outAccount, min: minOut, max: BigInt(quote.outAmount) * 2n },
    ];
    const draft = compile({ instructions, payer: wallet.publicKey, blockhash, lookupTables, units: MAX_COMPUTE_UNITS, unitPrice });
    const units = await simulateAndCheck(connection, draft, wallet.publicKey, bounds);
    const transaction = compile({ instructions, payer: wallet.publicKey, blockhash, lookupTables, units: unitLimit(units), unitPrice });
    return { transaction, lastValidBlockHeight, outAmount: BigInt(quote.outAmount), minOut: BigInt(quote.otherAmountThreshold) };
  }

  return { swapTransaction };
}
