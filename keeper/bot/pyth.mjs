// What a fill on a factory with an oracle posts to Pyth, and what Pyth's check will make of its legs. The hub values
// every leg a fill moves at Pyth's price of the last minute, and a price reaches Pyth's contract only when someone
// posts it, so the keeper's fill carries Pyth's signed update and its executor posts it first.
//
// No dependencies: the chain, Hermes and the ABIs are passed in, so this is unit-tested on its own against fakes.

/// Makes `pythFor(st, L, over, movable)`.
/// - `chain`: `{multicall, read, callAfter}` as `createChain` makes them.
/// - `hermes`: `{latestSigned}` as `createHermes` makes it.
/// - `factory`: the factory's address, which names each token's feed (`priceFeedOf`).
/// - `abi`: `{factory, pyth, prices}`.
/// - `hermesMs`: how long a Hermes request may take.
/// - `revertReason`: names an error that carries a call's revert data.
export function createPythFor({ chain, hermes, factory, abi, hermesMs, revertReason, now = Date.now }) {
  /// For index statics `st` (`{tokens, reader, pyth}`) at block `L`, with the overrides `over` the fill is simulated
  /// under: the update for the feeds the factory names for the legs the keeper may move (`movable[i]`), Pyth's fee
  /// for it, the call that posts it, and each such leg's value per raw unit as the hub's reader reports it once that
  /// update is posted, for a leg that leaves and for one that arrives. A leg without a feed, or one the reader
  /// cannot value even then (a stale or unusable price), has none, both ways, and the keeper leaves it alone. Null
  /// on a factory without an oracle. Throws when a feed cannot be read, Hermes serves nothing, or Pyth refuses the
  /// update: the round is then made again, not valued at a guess.
  return async function pythFor(st, L, over, movable) {
    if (!st.reader) return null;
    const none = () => st.tokens.map(() => null);
    const asked = movable.map((m, i) => (m ? i : -1)).filter((i) => i >= 0);
    const feeds = await chain.multicall(
      asked.map((i) => ({ address: factory, abi: abi.factory, functionName: "priceFeedOf", args: [st.tokens[i]] })),
      L.number,
    );
    if (feeds.some((r) => r.status !== "success")) throw new Error("a price feed read failed");
    // Kind 0 is `None`: no feed, and a fill that moves that leg reverts.
    const fed = asked.map((i, k) => ({ i, id: feeds[k].result.id, kind: Number(feeds[k].result.kind) })).filter((f) => f.kind !== 0);
    if (fed.length === 0) return { updates: [], fee: 0n, post: null, leaving: none(), arriving: none() };
    const { updates } = await hermes.latestSigned([...new Set(fed.map((f) => f.id))], now() + hermesMs);
    if (updates.length === 0) throw new Error("Hermes served no update for the feeds this index is checked against");
    const fee = await chain.read(st.pyth, abi.pyth, "getUpdateFee", [updates], L.number);
    const post = { to: st.pyth, abi: abi.pyth, functionName: "updatePriceFeeds", args: [updates], value: fee };
    const valueOf = (i, leaving) => ({ to: st.reader, abi: abi.prices, functionName: "valueOf", args: [st.tokens[i], leaving] });
    const [posted, ...values] = await chain.callAfter([post, ...fed.flatMap((f) => [valueOf(f.i, true), valueOf(f.i, false)])], L.number, over);
    if (!posted.ok) throw new Error(`Pyth refused the update Hermes served: ${revertReason(posted.error)}`);
    const leaving = none();
    const arriving = none();
    fed.forEach((f, k) => {
      const [out, into] = [values[2 * k], values[2 * k + 1]];
      if (out.ok && into.ok) [leaving[f.i], arriving[f.i]] = [out.result, into.result];
    });
    return { updates, fee, post, leaving, arriving };
  };
}
