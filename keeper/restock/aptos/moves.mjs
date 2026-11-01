// The Aptos signer's answers (`signer.mjs`), the same requests as every signer's (`signer-home.mjs`), in plain JSON
// (amounts as decimal strings, addresses as 0x-hex). A move that commits funds (a swap, a bridge transfer, a CCTP
// burn) comes back built, checked by simulation and signed, never sent: the parent journals it, then asks for it to be
// sent. Steps that only complete a move (a redeem, a CCTP receipt) are sent here, since their modules count each once.
//
// Wormhole's Token Bridge through Wormhole's own SDK; CCTP V2 through Circle's precompiled Move scripts
// (circlefin/aptos-cctp, typescript/example/precompiled-move-scripts/mainnet/v2, commit 440599d; ./scripts, NOTICE),
// since V2's functions return receipts a script must consume in the same transaction; swaps through Panora, whose router
// enforces the minimum output on chain. An account's transactions run in sequence-number order, so this signer keeps
// one transaction in flight at a time (`idle`): one that expired would leave every later one waiting behind it.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  AccountAddress,
  AccountAuthenticator,
  Deserializer,
  generateSignedTransaction,
  generateUserTransactionHash,
  MoveVector,
  SimpleTransaction,
  U32,
  U64,
} from "@aptos-labs/ts-sdk";
import { contracts, deserialize, keccak256, toUniversal } from "@wormhole-foundation/sdk-connect";
import { AptosTokenBridge } from "@wormhole-foundation/sdk-aptos-tokenbridge";
import { AptosWormholeCore } from "@wormhole-foundation/sdk-aptos-core";

/// Aptos mainnet's chain id: the RPC must serve this chain.
export const MAINNET_CHAIN_ID = 1;
export const APT_COIN = "0x1::aptos_coin::AptosCoin";
/// APT's and USDC's fungible asset metadata objects.
export const APT_METADATA = "0x000000000000000000000000000000000000000000000000000000000000000a";
export const USDC_METADATA = "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b";
/// Who Aptos's Token Bridge publishes as (its state's emitter; Ethereum's Token Bridge names it for chain 22).
export const TOKEN_BRIDGE_EMITTER = `0x${"0".repeat(63)}1`;
/// Circle's CCTP V2 on Aptos, domain 9 (developers.circle.com, checked on chain on 2026-11-01).
export const MESSAGE_TRANSMITTER_V2 = "0x1b3f6d749cb835451202f9a1932e49014266f7e3d51611a9a763d156cb4bdaf6";
/// Panora's router, whose `router_entry` is the only function a swap may call; its 17th argument is the minimum output,
/// which it enforces (E_OUTPUT_LESS_THAN_MINIMUM_TRY_INCREASING_SLIPPAGE).
export const PANORA_ROUTER = "0x1c3206329806286fd2223647c9f9b130e66baeb6d7224a18c1f642ffe48f3b4c::panora_swap::router_entry";
/// The most gas units a transaction may use, at the network's price: what the wallet's APT must cover beyond the move.
export const MAX_GAS_UNITS = 200_000n;
const GAS_UNIT_PRICE = 100n;
export const MAX_GAS_OCTAS = MAX_GAS_UNITS * GAS_UNIT_PRICE;
/// How long a signed transaction may wait to commit, in seconds; past it, it never will.
const EXPIRY_SECONDS = 600n;
const ETHEREUM_DOMAIN = 0;
const STANDARD_FINALITY = 2000;

const script = (name) => readFileSync(new URL(`./scripts/${name}.mv`, import.meta.url));
const hexBytes = (hex) => Uint8Array.from(Buffer.from(hex.replace(/^0x/, ""), "hex"));
const norm = (address) => AccountAddress.from(address).toStringLong();

/// The address of `owner`'s primary store of fungible asset `metadata`: the object derived from both, as Aptos's
/// object module derives one (sha3_256 of owner, metadata and the derived-object scheme byte 0xFC).
export function primaryStore(owner, metadata) {
  const h = createHash("sha3-256");
  h.update(Buffer.from(norm(owner).slice(2), "hex"));
  h.update(Buffer.from(norm(metadata).slice(2), "hex"));
  h.update(Buffer.from([0xfc]));
  return `0x${h.digest("hex")}`;
}

/// Decimal string `text` (Panora's human units) as base units at `decimals`, exactly; digits past `decimals` are cut.
export function baseUnits(text, decimals) {
  const m = /^(\d+)(?:\.(\d*))?$/.exec(String(text).trim());
  if (!m) throw new Error(`not a decimal amount: ${text}`);
  return BigInt(m[1]) * 10n ** BigInt(decimals) + BigInt((m[2] ?? "").slice(0, decimals).padEnd(decimals, "0") || "0");
}

/// `amount` base units at `decimals` as the decimal string Panora reads.
export function humanUnits(amount, decimals) {
  const s = amount.toString().padStart(decimals + 1, "0");
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

export function createMoves({ aptos, account, panora, fetchImpl = fetch }) {
  const address = norm(account.accountAddress.toString());
  const ids = { coreBridge: contracts.coreBridge("Mainnet", "Aptos"), tokenBridge: contracts.tokenBridge("Mainnet", "Aptos") };
  const bridge = new AptosTokenBridge("Mainnet", "Aptos", aptos, ids);
  const core = new AptosWormholeCore("Mainnet", "Aptos", aptos, ids);
  let consumed = null; // the bridge's table of completed transfers, read once
  let inflight = null;

  const view = async (fn, typeArguments, functionArguments) => (await aptos.view({ payload: { function: fn, typeArguments, functionArguments } }))[0];
  /// The wallet's balance of fungible asset `metadata` (APT counted with any coins not yet moved to its store).
  const balanceOf = async (metadata) =>
    BigInt(
      norm(metadata) === APT_METADATA
        ? await view("0x1::coin::balance", [APT_COIN], [address])
        : await view("0x1::primary_fungible_store::balance", ["0x1::fungible_asset::Metadata"], [address, metadata]),
    );

  /// What became of transaction `hash`, the wallet's `sequence` and expiring at `expire` (unix seconds): landed,
  /// reverted, pending, or expired once the account's sequence number passed it or the ledger's clock reached its
  /// expiry with no transaction of that hash.
  async function fate(hash, sequence, expire) {
    try {
      const t = await aptos.getTransactionByHash({ transactionHash: hash });
      if (t.type === "pending_transaction") return { state: "pending" };
      return { state: t.success ? "landed" : "reverted", at: String(t.version ?? "") };
    } catch (error) {
      if (error?.status !== 404) throw error;
    }
    const [{ sequence_number }, { ledger_timestamp }] = await Promise.all([aptos.getAccountInfo({ accountAddress: address }), aptos.getLedgerInfo()]);
    if (BigInt(sequence_number) > BigInt(sequence)) return { state: "expired", reason: `its sequence number ${sequence} went to another transaction` };
    if (BigInt(ledger_timestamp) >= BigInt(expire) * 1_000_000n) return { state: "expired", reason: `it expired at ${expire}` };
    return { state: "pending" };
  }

  async function idle() {
    if (!inflight) return;
    const s = await fate(inflight.hash, inflight.sequence, inflight.expire);
    if (s.state === "pending") {
      // Only a completing step is sent again here; a move is the parent's to send, once it is in its journal.
      if (inflight.resend) await inflight.resend();
      throw new Error(`transaction ${inflight.hash} is still in flight; waiting for it`);
    }
    inflight = null;
  }

  /// The wallet's balance changes in simulation `result`, by metadata: the primary stores' balances after it, against
  /// their balances now (APT's coin store too, for coins not moved to the store).
  async function changes(result, metadatas) {
    const out = new Map();
    for (const metadata of metadatas) {
      const store = primaryStore(address, metadata);
      let after = null;
      for (const c of result.changes ?? []) {
        if (c.type !== "write_resource") continue;
        if (norm(c.address) === store && c.data?.type === "0x1::fungible_asset::FungibleStore") after = (after ?? 0n) + BigInt(c.data.data.balance);
        if (norm(metadata) === APT_METADATA && norm(c.address) === address && c.data?.type === `0x1::coin::CoinStore<${APT_COIN}>`) {
          after = (after ?? 0n) + BigInt(c.data.data.coin.value);
        }
      }
      if (after === null) continue; // untouched
      out.set(norm(metadata), after - (await balanceOf(metadata)));
    }
    return out;
  }

  /// Builds `data` for the wallet with explicit gas, price, sequence number and expiry, and checks by simulation that it
  /// succeeds and moves the wallet's APT and USDC only within `bounds` (metadata -> {min, max}, APT's including gas).
  async function build(data, bounds) {
    await idle();
    const [{ sequence_number }, { ledger_timestamp }] = await Promise.all([aptos.getAccountInfo({ accountAddress: address }), aptos.getLedgerInfo()]);
    const expire = BigInt(ledger_timestamp) / 1_000_000n + EXPIRY_SECONDS;
    const transaction = await aptos.transaction.build.simple({
      sender: address,
      data,
      options: { maxGasAmount: Number(MAX_GAS_UNITS), gasUnitPrice: Number(GAS_UNIT_PRICE), expireTimestamp: Number(expire), accountSequenceNumber: BigInt(sequence_number) },
    });
    const [result] = await aptos.transaction.simulate.simple({ signerPublicKey: account.publicKey, transaction });
    if (!result.success) throw new Error(`simulation failed: ${result.vm_status}`);
    const moved = await changes(result, [APT_METADATA, USDC_METADATA]);
    for (const [metadata, change] of moved) {
      const bound = bounds[metadata];
      if (!bound && change !== 0n) throw new Error(`the transaction would change the wallet's ${metadata} by ${change}`);
      if (bound && (change < bound.min || change > bound.max)) throw new Error(`the transaction would change the wallet's ${metadata} by ${change}, outside [${bound.min}, ${bound.max}]`);
    }
    for (const [metadata, bound] of Object.entries(bounds)) {
      if (!moved.has(metadata) && (0n < bound.min || 0n > bound.max)) throw new Error(`the transaction would not move the wallet's ${metadata} as the move needs`);
    }
    return { transaction, sequence: BigInt(sequence_number), expire };
  }

  /// `built` signed: the transaction and its authenticator as `raw`, its hash, and its expiry (sequence and time).
  function signed({ transaction, sequence, expire }) {
    const senderAuthenticator = aptos.transaction.sign({ signer: account, transaction });
    const hash = generateUserTransactionHash({ transaction, senderAuthenticator });
    inflight = { hash, sequence: String(sequence), expire: String(expire), submit: { transaction, senderAuthenticator }, resend: null };
    return {
      raw: JSON.stringify({ transaction: Buffer.from(transaction.bcsToBytes()).toString("base64"), auth: Buffer.from(senderAuthenticator.bcsToBytes()).toString("base64") }),
      signature: hash,
      expiry: JSON.stringify({ sequence: String(sequence), expire: String(expire) }),
    };
  }

  /// Signs and submits `built`, a step that only completes a move, and waits for it; throws if it fails.
  async function execute(built) {
    const s = signed(built);
    const submit = inflight.submit;
    inflight.resend = () => aptos.transaction.submit.simple(submit).catch(() => {});
    await aptos.transaction.submit.simple(submit);
    const t = await aptos.waitForTransaction({ transactionHash: s.signature });
    inflight = null;
    if (!t.success) throw new Error(`${s.signature} failed: ${t.vm_status}`);
    return s.signature;
  }

  const decode = (raw) => {
    const { transaction, auth } = JSON.parse(raw);
    return {
      transaction: SimpleTransaction.deserialize(new Deserializer(Buffer.from(transaction, "base64"))),
      senderAuthenticator: AccountAuthenticator.deserialize(new Deserializer(Buffer.from(auth, "base64"))),
    };
  };

  /// Whether CCTP's transmitter recorded `message`'s nonce (bytes 12..44, a u256) used.
  const received = async (message) => view(`${MESSAGE_TRANSMITTER_V2}::message_transmitter::is_nonce_used`, [], [BigInt(`0x${message.replace(/^0x/, "").slice(24, 88)}`).toString()]);

  /// Whether transfer `vaa` was completed: its key in the bridge's table of consumed transfers, keccak256 of its hash.
  async function transferCompleted(vaa) {
    const transfer = deserialize("TokenBridge:Transfer", hexBytes(vaa));
    consumed ??= (await aptos.getAccountResource({ accountAddress: ids.tokenBridge, resourceType: `${ids.tokenBridge}::state::State` })).consumed_vaas.elems.handle;
    const key = `0x${Buffer.from(keccak256(transfer.hash)).toString("hex")}`;
    try {
      await aptos.getTableItem({ handle: consumed, data: { key_type: "vector<u8>", value_type: "u8", key } });
      return true;
    } catch (error) {
      if (error?.status === 404) return false;
      throw error;
    }
  }

  /// `vaa` as the SDK reads a transfer, after checking it pays this wallet with Aptos's APT.
  function transferToMe(vaa) {
    const transfer = deserialize("TokenBridge:Transfer", hexBytes(vaa));
    const to = norm(`0x${Buffer.from(transfer.payload.to.address.toUint8Array()).toString("hex")}`);
    if (transfer.payload.to.chain !== "Aptos" || to !== address) throw new Error(`the transfer pays ${to} on ${transfer.payload.to.chain}, not this wallet`);
    if (transfer.payload.token.chain !== "Aptos") throw new Error(`the transfer carries a token of ${transfer.payload.token.chain}`);
    return transfer;
  }

  return {
    /// The wallet and the addresses the parent needs, after checking the RPC serves Aptos mainnet and the coins are the
    /// one this signer serves: the executor pins the wallet itself, since Aptos's bridge pays accounts.
    async info({ mints }) {
      const { chain_id } = await aptos.getLedgerInfo();
      if (Number(chain_id) !== MAINNET_CHAIN_ID) throw new Error(`the RPC serves chain ${chain_id}, not Aptos mainnet`);
      for (const m of mints) if (m !== APT_COIN) throw new Error(`${m} is not a coin this signer serves`);
      return { wallet: address, walletWord: address, emitter: TOKEN_BRIDGE_EMITTER, accounts: Object.fromEntries(mints.map((m) => [m, { address, word: address }])) };
    },
    /// The wallet's APT, in octas, and its balance of each coin: `{gas, tokens: {coin: amount}}`.
    async balances({ mints }) {
      const tokens = {};
      for (const m of mints) tokens[m] = String(await balanceOf(m === APT_COIN ? APT_METADATA : m));
      return { gas: String(await balanceOf(APT_METADATA)), tokens };
    },
    /// A swap of `amount` of `inputMint` for at least `minOut` of `outputMint` through Panora, its minimum output set
    /// to `minOut` on chain, signed; or `{refused: "loss", outAmount}` when Panora's quote is below it.
    async buildSwap({ inputMint, outputMint, amount, minOut }) {
      const from = inputMint === APT_COIN ? APT_METADATA : norm(inputMint);
      const to = outputMint === APT_COIN ? APT_METADATA : norm(outputMint);
      const decimals = (m) => (m === APT_METADATA ? 8 : 6);
      const amountIn = BigInt(amount);
      const floor = BigInt(minOut);
      const query = new URLSearchParams({
        fromTokenAddress: from === APT_METADATA ? "0xa" : from,
        toTokenAddress: to === APT_METADATA ? "0xa" : to,
        fromTokenAmount: humanUnits(amountIn, decimals(from)),
        toWalletAddress: address,
        slippagePercentage: "1",
      });
      const response = await fetchImpl(`${panora.url}/swap?${query}`, { method: "POST", headers: { "x-api-key": panora.apiKey }, signal: AbortSignal.timeout(15_000) });
      if (!response.ok) throw new Error(`Panora ${response.status}: ${(await response.text()).slice(0, 200)}`);
      const quote = (await response.json())?.quotes?.[0];
      if (!quote?.txData) return { refused: "loss", outAmount: "0" };
      const { function: fn, type_arguments: typeArguments, arguments: args } = quote.txData;
      if (fn !== PANORA_ROUTER) throw new Error(`Panora's swap calls ${fn}, not its router`);
      if (norm(args[1]) !== address) throw new Error("Panora's swap pays someone else");
      if (norm(args[15]) !== to) throw new Error("Panora's swap buys another token");
      if (!Array.isArray(args[16]) || args[16].length !== 1 || BigInt(args[16][0]) !== amountIn) throw new Error("Panora's swap spends another amount");
      const out = baseUnits(quote.toTokenAmount, decimals(to));
      if (out < floor) return { refused: "loss", outAmount: String(out) };
      const functionArguments = [...args];
      functionArguments[17] = floor.toString(); // the floor, which the router enforces
      const bounds = {
        [from]: { min: -(amountIn + (from === APT_METADATA ? MAX_GAS_OCTAS : 0n)), max: 0n },
        [to]: { min: floor - (to === APT_METADATA ? MAX_GAS_OCTAS : 0n), max: out * 2n },
      };
      const built = await build({ function: fn, typeArguments, functionArguments }, bounds);
      return { ...signed(built), outAmount: String(out), minOut: String(floor) };
    },
    /// The Token Bridge transfer of `amount` of APT to `executor` (a word) on Ethereum, with the payload 0x01, as the
    /// SDK builds it, signed: it must take exactly `amount` and the gas. APT's eight decimals cross the bridge whole.
    async buildBridgeIn({ mint, amount, executor }) {
      if (mint !== APT_COIN) throw new Error(`${mint} is not a coin this signer bridges`);
      const value = BigInt(amount);
      const recipient = { chain: "Ethereum", address: toUniversal("Ethereum", `0x${executor.replace(/^0x/, "").slice(24)}`) };
      const payloads = [];
      for await (const u of bridge.transfer(address, recipient, APT_COIN, value, new Uint8Array([1]))) payloads.push(u.transaction);
      if (payloads.length !== 1) throw new Error(`the SDK built ${payloads.length} transactions for one transfer`);
      return signed(await build(payloads[0], { [APT_METADATA]: { min: -(value + MAX_GAS_OCTAS), max: -value } }));
    },
    /// The CCTP V2 burn of `amount` of USDC for `treasury` (a word) on Ethereum, with no fee and standard finality,
    /// through Circle's script, signed: it must take exactly `amount`.
    async buildSweep({ amount, treasury }) {
      const value = BigInt(amount);
      const data = {
        bytecode: script("deposit_for_burn"),
        functionArguments: [new U64(value), new U32(ETHEREUM_DOMAIN), AccountAddress.from(treasury), AccountAddress.from("0x0"), AccountAddress.from(USDC_METADATA), new U64(0n), new U32(STANDARD_FINALITY)],
      };
      return signed(await build(data, { [USDC_METADATA]: { min: -value, max: -value }, [APT_METADATA]: { min: -MAX_GAS_OCTAS, max: 0n } }));
    },
    /// Sends signed move `raw`; resubmitting the same transaction has no further effect.
    async send({ raw }) {
      const r = await aptos.transaction.submit.simple(decode(raw)).catch((error) => ({ error: String(error?.message ?? error) }));
      return r.hash ?? null;
    },
    async status({ signature, expiry }) {
      const { sequence, expire } = JSON.parse(expiry);
      const s = await fate(signature, sequence, expire);
      if (s.state !== "pending" && inflight?.hash === signature) inflight = null;
      return s;
    },
    /// The sequence the Token Bridge published in transaction `signature`.
    async sequenceOf({ signature }) {
      const ids_ = (await core.parseTransaction(signature)).filter((m) => `0x${Buffer.from(m.emitter.toUint8Array()).toString("hex")}` === TOKEN_BRIDGE_EMITTER);
      if (ids_.length !== 1) throw new Error(`transaction ${signature} carries ${ids_.length} Token Bridge messages`);
      return String(ids_[0].sequence);
    },
    transferCompleted: ({ vaa }) => transferCompleted(vaa),
    /// Completes transfer `vaa` to this wallet: what it pays must reach the wallet, and nothing else move but gas.
    async redeem({ vaa, mints }) {
      const transfer = transferToMe(vaa);
      if (!mints.includes(APT_COIN)) throw new Error("this signer serves no coin");
      const payloads = [];
      for await (const u of bridge.redeem(address, transfer)) payloads.push(u.transaction);
      if (payloads.length !== 1) throw new Error(`the SDK built ${payloads.length} transactions for one redeem`);
      const paid = transfer.payload.token.amount; // APT's eight decimals are the bridge's
      return execute(await build(payloads[0], { [APT_METADATA]: { min: paid - MAX_GAS_OCTAS, max: paid } }));
    },
    cctpReceived: ({ message }) => received(message),
    /// Whether this chain would receive CCTP `message` with `attestation`: a simulation, or the message received.
    async verifyCctp({ message, attestation }) {
      if (await received(message)) return { valid: true, reason: "" };
      const transaction = await aptos.transaction.build.simple({ sender: address, data: { bytecode: script("receive_message"), functionArguments: [MoveVector.U8(hexBytes(message)), MoveVector.U8(hexBytes(attestation))] } });
      const [result] = await aptos.transaction.simulate.simple({ signerPublicKey: account.publicKey, transaction });
      return result.success ? { valid: true, reason: "" } : { valid: false, reason: result.vm_status };
    },
    /// Receives CCTP `message` with `attestation` into the wallet; the hash, or null when it was received already.
    async receive({ message, attestation }) {
      if (await received(message)) return null;
      const amount = BigInt(`0x${message.replace(/^0x/, "").slice(2 * (148 + 68), 2 * (148 + 100))}`);
      const data = { bytecode: script("receive_message"), functionArguments: [MoveVector.U8(hexBytes(message)), MoveVector.U8(hexBytes(attestation))] };
      return execute(await build(data, { [USDC_METADATA]: { min: 0n, max: amount }, [APT_METADATA]: { min: -MAX_GAS_OCTAS, max: 0n } }));
    },
  };
}
