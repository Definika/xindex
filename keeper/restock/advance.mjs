// Taking a journalled move one step further each round (`restock.mjs`), with its chains and the two attestation
// services injected, so the keeper's unit tests cover it with no dependency (keeper/test/unit/restock-advance.test.mjs).
// A move's transaction is mined; a bridge transfer is signed by Wormhole's guardians and redeemed on the other side; a
// CCTP transfer is attested by Circle and received. Each step reads what the chains say first, so a step that already
// happened is never taken twice.
//
// A signature the move waits on can go stale while it waits (PD-10). Circle encodes an expiry in the message it signs,
// which the receiving transmitter enforces ("If the burn expires, it must be re-signed", Circle's technical guide):
// such a message is re-attested and fetched again. A guardian set Wormhole replaces stays valid a day: a VAA it signed
// that no longer verifies is fetched again, in case the guardians signed it anew.

import { CHAINS } from "./coins.mjs";
import { cctpFields } from "./attestations.mjs";

/// How often a move asks Circle to sign its message again while the old signature does not verify.
export const REATTEST_EVERY_SECONDS = 3600;

/// `deps`: the journal; `eth` and `homes` (chain adapters, `restock/evm.mjs` and the signer homes); `wormholescan` and
/// `iris`; `redeemIn(vaa, copy)`, the executor's `redeemBridged` sent by the treasury; `coinOf(symbol)`; `log`; and
/// `now()`, the clock in seconds.
export function createAdvance({ journal, eth, homes, wormholescan, iris, redeemIn, coinOf, log, now = () => Math.floor(Date.now() / 1000) }) {
  const chainOf = (move) => (move.data.chain === "ethereum" ? eth : homes[move.data.chain]);

  /// Circle's attested message for CCTP move `move`, burned on `fromDomain` for `to`: `{message, attestation}` once
  /// `to` would receive it (or has), null while Circle has not signed it, or has been asked to sign it again. A message
  /// whose signature `to` refuses is never stored for the move; one with an expiry is re-attested, at most once an hour.
  async function attested(move, fromDomain, expect, to) {
    const m = await iris.message(fromDomain, move.data.hash, expect);
    if (!m) return null;
    if (await to.cctpReceived(m.message)) return m;
    const { valid, reason } = await to.verifyCctp(m.message, m.attestation);
    if (valid) return m;
    const fields = cctpFields(m.message);
    if (!fields || fields.expirationBlock === 0n) throw new Error(`Circle's attestation does not verify on the receiving chain: ${reason}`);
    if (now() - (move.data.reattestedAt ?? 0) < REATTEST_EVERY_SECONDS) return null;
    await iris.reattest(fields.nonce);
    journal.note(move.id, { reattestedAt: now() });
    log(`move ${move.id}`, `Circle's signature does not verify (${reason}), likely past its expiry; asked Circle to sign it again`);
    return null;
  }

  /// Takes `move` one step further, as far as its chains and the attestation services allow this round.
  return async function advance(move) {
    if (move.stage === "signed") {
      const adapter = chainOf(move);
      if (!adapter) return log(`move ${move.id}`, `waits: ${move.data.chain} is not served now`);
      if (!(await adapter.resume(move))) return;
      move = journal.get(move.id);
      if (move.stage !== "sent") return;
    }
    if (move.stage === "sent" && move.data.status === "reverted") {
      journal.drop(move.id, "its transaction reverted");
      return log(`move ${move.id}`, `${move.kind} reverted on ${move.data.chain}; dropped`);
    }
    if (["buy", "sell", "draw", "repay"].includes(move.kind)) return journal.advance(move.id, "done");

    if (move.kind === "bridgeIn" || move.kind === "bridgeOut") {
      const into = move.kind === "bridgeIn";
      const from = into ? homes[move.chain] : eth;
      const to = into ? eth : homes[move.chain];
      if (!from || !to) return log(`move ${move.id}`, `waits: ${move.chain} is not served now`);
      if (move.stage === "sent") {
        if (move.data.sequence === undefined) journal.note(move.id, { sequence: (await from.sequenceOfTx(move.data.hash)).toString() });
        const vaa = await wormholescan.vaa(from.def.wormhole, from.emitter, journal.get(move.id).data.sequence, to.verifyVaa);
        if (!vaa) return;
        journal.advance(move.id, "attested", { vaa });
      }
      let { vaa } = journal.get(move.id).data;
      if (!(await to.transferCompleted(vaa))) {
        const check = await to.verifyVaa(vaa);
        if (!check.valid) {
          // Signed by a guardian set since replaced: fetched again, in case the guardians signed it anew (PD-10).
          const fresh = await wormholescan.vaa(from.def.wormhole, from.emitter, journal.get(move.id).data.sequence, to.verifyVaa);
          if (!fresh || fresh === vaa) throw new Error(`the transfer's VAA no longer verifies (${check.reason}) and Wormholescan has no newer one`);
          journal.note(move.id, { vaa: fresh });
          vaa = fresh;
        }
        // The copy the journal recorded when the move opened, so a coin dropped from RESTOCK_COINS while its transfer
        // was on its way is still redeemed (RZ-18).
        if (into) await redeemIn(vaa, move.copy ?? coinOf(move.coin).copy);
        else await to.redeem(vaa);
      }
      journal.advance(move.id, "redeemed");
      return log(`move ${move.id}`, `${move.kind} of ${move.coin} landed`);
    }

    // A CCTP move: burned on one side, attested by Circle, received on the other.
    const funding = move.kind === "fund";
    const from = funding ? eth : homes[move.chain];
    const to = funding ? homes[move.chain] : eth;
    if (!from || !to) return log(`move ${move.id}`, `waits: ${move.chain} is not served now`);
    const [fromDomain, toDomain] = funding ? [0, CHAINS[move.chain].cctpDomain] : [CHAINS[move.chain].cctpDomain, 0];
    const expect = { destinationDomain: toDomain, recipient: to.cctpRecipient, sender: from.cctpSender, amount: BigInt(move.amount) };
    if (move.stage === "sent") {
      const m = await attested(move, fromDomain, expect, to);
      if (!m) return;
      journal.advance(move.id, "attested", m);
    }
    const { message, attestation } = journal.get(move.id).data;
    if (!(await to.cctpReceived(message))) {
      let signed = { message, attestation };
      const { valid } = await to.verifyCctp(message, attestation);
      if (!valid) {
        // Its signature went stale while it waited (PD-10): signed again, or not yet.
        const m = await attested(journal.get(move.id), fromDomain, expect, to);
        if (!m) return;
        journal.note(move.id, m);
        signed = m;
      }
      await to.receive(signed.message, signed.attestation);
    }
    journal.advance(move.id, "received");
    log(`move ${move.id}`, `${move.kind} of ${Number(move.amount) / 1e6} USDC landed on ${funding ? move.chain : "ethereum"}`);
  };
}
