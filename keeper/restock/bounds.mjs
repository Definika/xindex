// The swap bound every signer applies, with no dependency (`solana/checks.mjs`, `sui/moves.mjs`, ...): the slippage
// that keeps a venue's on-chain minimum at the plan's floor or above.

/// The slippage, in basis points, that leaves a quote of `out` with an on-chain minimum of `minOut` at least, rounded
/// down; null when the quote is below `minOut` already.
export function slippageFor(out, minOut) {
  if (out < minOut || out === 0n) return null;
  return Number(((out - minOut) * 10_000n) / out);
}
