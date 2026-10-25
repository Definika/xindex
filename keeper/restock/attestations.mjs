// The signatures a cross-chain move waits for: Wormhole's guardians' signed transfer (a VAA), fetched from
// Wormholescan, and Circle's attestation of a CCTP burn, fetched from Iris. Each is asked once a round; "not yet" is
// null, and only an answer that cannot change (the move is not there and never will be) is an error worth stopping
// on, which neither service gives, so any failure throws and the next round asks again. Native fetch only.

const hex = (s) => s.toLowerCase().replace(/^0x/, "");
/// An address as a 32-byte word, in hex: how Wormhole names an emitter and CCTP a recipient or a sender.
const word = (address) => hex(address).padStart(64, "0");

/// A VAA's emitter chain, emitter (a word) and sequence, read from its body, which starts after the header and the
/// signatures; null when `bytes` are too short to be one.
function vaaOrigin(bytes) {
  if (bytes.length < 6) return null;
  const body = 6 + 66 * bytes[5];
  if (bytes.length < body + 51) return null;
  return {
    chain: bytes.readUInt16BE(body + 8),
    emitter: bytes.subarray(body + 10, body + 42).toString("hex"),
    sequence: bytes.readBigUInt64BE(body + 42),
  };
}

/// A CCTP V2 message's domains, from its header (148 bytes), and its burn message's mint recipient, amount and sender
/// (words), which follow; null when `message` is too short to be a burn.
function cctpBurn(message) {
  const m = hex(typeof message === "string" ? message : "");
  const at = (byte, bytes) => m.slice(2 * byte, 2 * (byte + bytes));
  if (m.length < 2 * (148 + 132)) return null;
  return {
    source: Number.parseInt(at(4, 4), 16),
    destination: Number.parseInt(at(8, 4), 16),
    recipient: at(148 + 36, 32),
    amount: BigInt(`0x${at(148 + 68, 32)}`),
    sender: at(148 + 100, 32),
  };
}

/// Wormholescan's API (https://api.wormholescan.io). `fetchImpl` is injectable for tests.
export function createWormholescan({ url = "https://api.wormholescan.io", fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const base = url.replace(/\/+$/, "");
  return {
    /// The signed transfer that `emitter` (an address, 20 or 32 bytes) on Wormhole chain `chain` published as
    /// `sequence`, as 0x-hex; null until the guardians have signed it. An answer that is another message, or that
    /// `verify(vaa)` (the receiving chain's core: `{valid, reason}`) refuses, is thrown, never stored for the move,
    /// which would wait on it for good: the next round fetches it again (RS-14).
    async vaa(chain, emitter, sequence, verify = null) {
      const id = `${chain}/${hex(emitter).padStart(64, "0")}/${BigInt(sequence)}`;
      const response = await fetchImpl(`${base}/api/v1/vaas/${id}`, { signal: AbortSignal.timeout(timeoutMs) });
      if (response.status === 404) return null;
      if (!response.ok) throw new Error(`Wormholescan ${response.status} on ${id}`);
      const body = await response.json();
      const vaa = body?.data?.vaa;
      if (typeof vaa !== "string" || vaa.length === 0) throw new Error(`Wormholescan gave no VAA for ${id}`);
      const bytes = Buffer.from(vaa, "base64");
      const origin = vaaOrigin(bytes);
      if (!origin) throw new Error(`Wormholescan gave ${id} something that is not a VAA`);
      if (origin.chain !== Number(chain) || origin.emitter !== word(emitter) || origin.sequence !== BigInt(sequence)) {
        throw new Error(`Wormholescan answered ${id} with another message, ${origin.chain}/${origin.emitter}/${origin.sequence}`);
      }
      const signed = `0x${bytes.toString("hex")}`;
      if (verify) {
        const { valid, reason } = await verify(signed);
        if (!valid) throw new Error(`the VAA ${id} does not verify on the receiving chain: ${reason}`);
      }
      return signed;
    },
  };
}

/// Circle's Iris API, CCTP V2 (https://iris-api.circle.com). `fetchImpl` is injectable for tests.
export function createIris({ url = "https://iris-api.circle.com", fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const base = url.replace(/\/+$/, "");
  return {
    /// The message the CCTP burn in transaction `hash` on CCTP domain `domain` sent, with Circle's attestation of it;
    /// null until Circle has attested it. `expect` is the move's: `{destinationDomain, recipient, sender, amount}`; a
    /// message that is not its burn is never taken for it, an answer with none is thrown, and so is the move's when
    /// `verify(message, attestation)` (the other chain's transmitter: `{valid, reason}`) refuses it (RS-14).
    async message(domain, hash, expect, verify = null) {
      const path = `/v2/messages/${domain}?transactionHash=${hash}`;
      const response = await fetchImpl(`${base}${path}`, { signal: AbortSignal.timeout(timeoutMs) });
      if (response.status === 404) return null;
      if (!response.ok) throw new Error(`Iris ${response.status} on ${path}`);
      const body = await response.json();
      const messages = Array.isArray(body?.messages) ? body.messages : [];
      let pending = messages.length === 0;
      for (const m of messages) {
        if (m.status !== "complete" || !m.attestation || m.attestation === "PENDING") {
          pending = true;
          continue;
        }
        const burn = cctpBurn(m.message);
        if (
          burn?.source === domain &&
          burn.destination === expect.destinationDomain &&
          burn.recipient === word(expect.recipient) &&
          burn.sender === word(expect.sender) &&
          burn.amount === expect.amount
        ) {
          if (verify) {
            const { valid, reason } = await verify(m.message, m.attestation);
            if (!valid) throw new Error(`Circle's attestation for ${path} does not verify on the receiving chain: ${reason}`);
          }
          return { message: m.message, attestation: m.attestation };
        }
      }
      if (pending) return null;
      throw new Error(`Iris answered ${path} with no message of this move`);
    },
  };
}

/// The sequence of the Wormhole message `emitter` published, among a receipt's `logs`: only the Wormhole core's own
/// log counts, not one any other contract of the transaction, a token among them, emits in its form (RS-14).
/// `decode(log)` is viem's decodeEventLog over the core's ABI. Null when there is none.
export function sequenceIn(logs, { core, emitter, decode }) {
  for (const log of logs) {
    if (log.address?.toLowerCase() !== core.toLowerCase()) continue;
    try {
      const e = decode(log);
      if (e.eventName === "LogMessagePublished" && e.args.sender.toLowerCase() === emitter.toLowerCase()) return e.args.sequence;
    } catch {}
  }
  return null;
}
