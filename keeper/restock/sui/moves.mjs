// The Sui signer's answers (`signer.mjs`), the same requests as every signer's (`signer-home.mjs`): each in plain JSON
// (amounts as decimal strings, addresses as 0x-hex). A move that commits funds (a swap, a bridge transfer, a CCTP
// burn) comes back built, checked by simulation and signed, never sent: the parent journals it, then asks for it to be
// sent. Steps that only complete a move (a redeem, a CCTP receipt) are sent here, since their packages count each once.
//
// Sui through gRPC (Mysten's public fullnodes no longer serve JSON-RPC); Wormhole's Token Bridge through Wormhole's own
// SDK; CCTP V2 as Circle's Sui scripts build it (circlefin/sui-cctp, scripts/sui/ptbV2.ts); swaps through Cetus's
// aggregator. A signed Sui transaction names its owned inputs at their versions: two that share a gas coin cannot
// both execute, so this signer keeps one transaction in flight at a time (`busy`), as the EVM side waits for its
// pending nonce (RS-15).

import { AggregatorClient, Env, getProvidersExcluding, PYTH_ORACLE_BASED_DEXES } from "@cetusprotocol/aggregator-sdk";
import { coinWithBalance, Transaction, TransactionDataBuilder } from "@mysten/sui/transactions";
import { normalizeStructTag, normalizeSuiAddress } from "@mysten/sui/utils";
import { contracts, deserialize, toUniversal } from "@wormhole-foundation/sdk-connect";
import { SuiWormholeCore } from "@wormhole-foundation/sdk-sui-core";
import { SuiTokenBridge } from "@wormhole-foundation/sdk-sui-tokenbridge";
import { slippageFor } from "../bounds.mjs";

/// Sui mainnet's chain identifier: the RPC must serve this chain.
export const MAINNET_CHAIN = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S";
export const SUI = normalizeStructTag("0x2::sui::SUI");
export const USDC = normalizeStructTag("0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC");
/// Who Sui's Token Bridge publishes as (its state's emitter cap; Ethereum's Token Bridge names it for chain 21).
export const TOKEN_BRIDGE_EMITTER = "0xccceeb29348f71bdd22ffef43a2a19c1f5b5e17c5cca5411529120182672ade5";
/// Circle's CCTP V2 on Sui, domain 8 (developers.circle.com/cctp/references/sui-packages, checked on chain).
export const CCTP = Object.freeze({
  mtPackage: "0x16bcfcfc465f96281663a344641c017de84529370e11aa3879d0dce43ad6db87",
  mtState: "0x0c067f7d325e5b60e3179712e7783534ba1556cbb3d359d8161497e37689230c",
  tmmPackage: "0xeb14978abfe93a37c5d5bf86a0623b923553a5f0e794daac7724f1e2fdbfb830",
  tmmState: "0x06fb166941cd7bc095edc019d054a753ec3f1e4c25f28f2ecc4a6cfa0a9b1167",
  handlerPackage: "0x185ed207c4d64fc594882ab927f9f3c6ff957aad03df8a731ba64378faeeb2bf",
  handlerState: "0xa32de8a6dd0178fb05f662929d55cddb69a25c26bde4b83f89e36d17ead94c41",
  treasury: "0x57d6725e7a8b49a7b2a612f6bd66ab5f39fc95332ca48be421c3229d514a6de7",
  denyList: "0x403",
  clock: "0x6",
});
/// Ethereum's CCTP domain, where every burn from here goes, and a standard transfer's finality.
const ETHEREUM_DOMAIN = 0;
const STANDARD_FINALITY = 2000;
/// The most gas, in MIST, one transaction may cost: what the wallet's SUI must cover beyond what the move spends.
export const MAX_GAS_BUDGET = 500_000_000n;

const hexBytes = (hex) => Uint8Array.from(Buffer.from(hex.replace(/^0x/, ""), "hex"));

export function createMoves({ client, keypair, genesis = MAINNET_CHAIN }) {
  const address = normalizeSuiAddress(keypair.toSuiAddress());
  const ids = { coreBridge: contracts.coreBridge("Mainnet", "Sui"), tokenBridge: contracts.tokenBridge("Mainnet", "Sui") };
  const bridge = new SuiTokenBridge("Mainnet", "Sui", client, ids);
  const core = new SuiWormholeCore("Mainnet", "Sui", client, ids);
  const aggregator = new AggregatorClient({ client, signer: address, env: Env.Mainnet });
  /// The one transaction in flight: `{digest, gas, epoch}`, until it lands or can no longer.
  let inflight = null;

  const epochNow = async () => BigInt((await client.getCurrentSystemState()).systemState.epoch);
  const balanceOf = async (coinType) => BigInt((await client.getBalance({ owner: address, coinType })).balance.balance);

  /// What became of transaction `digest`, signed with gas coins `gas` at their versions and valid until `epoch`.
  async function fate(digest, gas, epoch) {
    try {
      const r = await client.getTransaction({ digest, include: { effects: true } });
      const t = r.Transaction ?? r.FailedTransaction;
      return { state: t.status.success ? "landed" : "reverted", at: String(t.checkpoint ?? "") };
    } catch (error) {
      if (!/not found/i.test(String(error?.message))) throw error;
    }
    for (const g of gas) {
      const o = await client.getObject({ objectId: g.objectId, include: { previousTransaction: true } }).catch(() => null);
      // A gas coin our own transaction moved: it executed, and the node has not served it yet.
      if (o?.object?.previousTransaction === digest) return { state: "pending" };
      if (!o || String(o.object.version) !== g.version) return { state: "expired", reason: `its gas coin ${g.objectId} moved to another version` };
    }
    if ((await epochNow()) > BigInt(epoch)) return { state: "expired", reason: `its expiry epoch ${epoch} ended` };
    return { state: "pending" };
  }

  /// Refuses to build while the transaction in flight may still execute.
  async function idle() {
    if (!inflight) return;
    const s = await fate(inflight.digest, inflight.gas, inflight.epoch);
    if (s.state === "pending") throw new Error(`transaction ${inflight.digest} is still in flight; waiting for it`);
    inflight = null;
  }

  /// The wallet's SUI coins whose total covers `need` MIST, the largest first, none of the one in flight's.
  async function gasCoins(need) {
    const coins = [];
    let cursor = null;
    do {
      const page = await client.listCoins({ owner: address, coinType: SUI, cursor, limit: 50 });
      coins.push(...page.objects);
      cursor = page.hasNextPage ? page.cursor : null;
    } while (cursor && coins.length < 500);
    coins.sort((a, b) => (BigInt(b.balance) > BigInt(a.balance) ? 1 : BigInt(b.balance) < BigInt(a.balance) ? -1 : 0));
    const picked = [];
    let total = 0n;
    for (const c of coins) {
      picked.push(c);
      total += BigInt(c.balance);
      if (total >= need) return picked;
    }
    throw new Error(`the wallet's SUI coins (${total} MIST) do not cover ${need}`);
  }

  /// Sets `tx`'s sender, gas price, gas coins (covering `spend` of SUI the move takes from the gas coin, and the
  /// budget), budget and expiry (the next epoch), builds it, and checks by simulation that it moves the wallet's coins
  /// only within `bounds` (coin type -> {min, max}, SUI's including the gas). Returns the bytes and what `fate` needs.
  async function build(tx, spend, bounds) {
    await idle();
    const [price, epoch] = await Promise.all([client.getReferenceGasPrice(), epochNow()]);
    const coins = await gasCoins(spend + MAX_GAS_BUDGET);
    tx.setSender(address);
    tx.setGasPrice(BigInt(price.referenceGasPrice));
    tx.setGasPayment(coins.map((c) => ({ objectId: c.objectId, version: c.version, digest: c.digest })));
    tx.setGasBudget(MAX_GAS_BUDGET);
    tx.setExpiration({ Epoch: Number(epoch + 1n) });
    const bytes = await tx.build({ client });
    const sim = await client.simulateTransaction({ transaction: bytes, include: { effects: true, balanceChanges: true } });
    const t = sim.Transaction ?? sim.FailedTransaction;
    if (!t.status.success) throw new Error(`simulation failed: ${JSON.stringify(t.status.error)}`);
    const changes = new Map();
    for (const b of t.balanceChanges ?? []) {
      if (normalizeSuiAddress(b.address) === address) changes.set(normalizeStructTag(b.coinType), BigInt(b.amount));
    }
    for (const [type, change] of changes) {
      if (!bounds[type]) throw new Error(`the transaction would change the wallet's ${type} by ${change}`);
    }
    for (const [type, { min, max }] of Object.entries(bounds)) {
      const change = changes.get(type) ?? 0n;
      if (change < min || change > max) throw new Error(`the transaction would change the wallet's ${type} by ${change}, outside [${min}, ${max}]`);
    }
    return { bytes, gas: coins.map((c) => ({ objectId: c.objectId, version: String(c.version) })), epoch: epoch + 1n };
  }

  /// `built` signed: the bytes and signature (as `raw`), its digest, and its expiry (gas coins and epoch).
  async function signed({ bytes, gas, epoch }) {
    const { signature } = await keypair.signTransaction(bytes);
    const digest = TransactionDataBuilder.getDigestFromBytes(bytes);
    inflight = { digest, gas, epoch: String(epoch) };
    return {
      raw: JSON.stringify({ bytes: Buffer.from(bytes).toString("base64"), signature }),
      signature: digest,
      expiry: JSON.stringify({ epoch: String(epoch), gas }),
    };
  }

  /// Signs and executes `built`, a step that only completes a move, and waits for it; throws if it fails.
  async function execute(built) {
    const s = await signed(built);
    const { bytes, signature } = JSON.parse(s.raw);
    const r = await client.executeTransaction({ transaction: Buffer.from(bytes, "base64"), signatures: [signature], include: { effects: true } });
    const t = r.Transaction ?? r.FailedTransaction;
    if (!t.status.success) throw new Error(`${s.signature} failed: ${JSON.stringify(t.status.error)}`);
    await client.waitForTransaction({ digest: s.signature });
    inflight = null;
    return s.signature;
  }

  /// The CCTP V2 receipt of `message` with `attestation`, minting to the wallet (Circle's addReceiveV2).
  function receiveTransaction(message, attestation) {
    const tx = new Transaction();
    const [receipt] = tx.moveCall({
      target: `${CCTP.mtPackage}::receive_message::receive_message`,
      arguments: [tx.pure.vector("u8", Array.from(hexBytes(message))), tx.pure.vector("u8", Array.from(hexBytes(attestation))), tx.object(CCTP.mtState)],
    });
    const [mintReceipt] = tx.moveCall({
      target: `${CCTP.tmmPackage}::handle_receive_message::prepare_mint`,
      arguments: [receipt, tx.object(CCTP.tmmState), tx.object(CCTP.clock)],
      typeArguments: [USDC],
    });
    const [ticket] = tx.moveCall({
      target: `${CCTP.handlerPackage}::handler::mint`,
      arguments: [tx.object(CCTP.handlerState), mintReceipt, tx.object(CCTP.tmmState), tx.object(CCTP.treasury), tx.object(CCTP.denyList)],
    });
    tx.moveCall({
      target: `${CCTP.tmmPackage}::handle_receive_message::complete_mint`,
      arguments: [ticket, tx.object(CCTP.tmmState), tx.object(CCTP.mtState)],
      typeArguments: [USDC, `${CCTP.handlerPackage}::handler::Auth`],
    });
    return tx;
  }

  /// Whether CCTP's transmitter recorded `message`'s nonce (bytes 12..44, a u256) used, read by simulation.
  async function received(message) {
    const nonce = BigInt(`0x${message.replace(/^0x/, "").slice(24, 88)}`);
    const tx = new Transaction();
    tx.moveCall({ target: `${CCTP.mtPackage}::state::is_nonce_used`, arguments: [tx.object(CCTP.mtState), tx.pure.u256(nonce)] });
    tx.setSender(address);
    const sim = await client.simulateTransaction({ transaction: tx, include: { commandResults: true } });
    const value = sim.commandResults?.[0]?.returnValues?.[0]?.bcs;
    if (!value) throw new Error("could not read the transmitter's used nonce");
    return value[0] === 1;
  }

  /// `vaa` as Wormhole's SDK reads a transfer, after checking it pays this wallet.
  function transferToMe(vaa) {
    const transfer = deserialize("TokenBridge:Transfer", hexBytes(vaa));
    const to = `0x${Buffer.from(transfer.payload.to.address.toUint8Array()).toString("hex")}`;
    if (transfer.payload.to.chain !== "Sui" || normalizeSuiAddress(to) !== address) throw new Error(`the transfer pays ${to} on ${transfer.payload.to.chain}, not this wallet`);
    if (transfer.payload.token.chain !== "Sui") throw new Error(`the transfer carries a token of ${transfer.payload.token.chain}`);
    return transfer;
  }

  return {
    /// The wallet and the addresses the parent needs, after checking the RPC serves Sui mainnet and every coin is one
    /// this signer serves: the executor pins the wallet itself for each, since Sui's bridge pays addresses.
    async info({ mints }) {
      const { chainIdentifier } = await client.getChainIdentifier();
      if (chainIdentifier !== genesis) throw new Error(`the RPC serves chain ${chainIdentifier}, not Sui mainnet`);
      for (const m of mints) if (normalizeStructTag(m) !== SUI) throw new Error(`${m} is not a coin this signer serves`);
      return {
        wallet: address,
        walletWord: address,
        emitter: TOKEN_BRIDGE_EMITTER,
        accounts: Object.fromEntries(mints.map((m) => [m, { address, word: address }])),
      };
    },
    /// The wallet's SUI, in MIST, and its balance of each coin type: `{gas, tokens: {coinType: amount}}`.
    async balances({ mints }) {
      const tokens = {};
      for (const m of mints) tokens[m] = String(await balanceOf(normalizeStructTag(m)));
      return { gas: String(await balanceOf(SUI)), tokens };
    },
    /// A swap of `amount` of `inputMint` for at least `minOut` of `outputMint` through Cetus's aggregator, signed; or
    /// `{refused: "loss", outAmount}` when no route pays `minOut`. Oracle-priced pools are left out, so no price feed is
    /// fetched here.
    async buildSwap({ inputMint, outputMint, amount, minOut }) {
      const from = normalizeStructTag(inputMint);
      const target = normalizeStructTag(outputMint);
      const amountIn = BigInt(amount);
      const floor = BigInt(minOut);
      const router = await aggregator.findRouters({ from, target, amount: amountIn.toString(), byAmountIn: true, providers: getProvidersExcluding(PYTH_ORACLE_BASED_DEXES) });
      if (!router || router.insufficientLiquidity || router.error) return { refused: "loss", outAmount: "0" };
      // The route may take a little less than asked (its splits' granularity): spend what it takes, never more than
      // asked nor under 99% of it, for the floor's share of it, rounded up.
      const spend = BigInt(router.amountIn.toString());
      if (spend > amountIn || spend * 100n < amountIn * 99n) throw new Error(`Cetus routed ${spend} of ${amountIn}`);
      const share = (floor * spend + amountIn - 1n) / amountIn;
      const out = BigInt(router.amountOut.toString());
      const bps = slippageFor(out, share);
      if (bps === null) return { refused: "loss", outAmount: String(out) };
      const tx = new Transaction();
      const inputCoin = from === SUI ? tx.splitCoins(tx.gas, [tx.pure.u64(spend)])[0] : coinWithBalance({ type: from, balance: spend })(tx);
      const output = await aggregator.routerSwap({ router, inputCoin, slippage: bps / 10_000, txb: tx });
      tx.transferObjects([output], address);
      const bounds = from === SUI
        ? { [SUI]: { min: -(spend + MAX_GAS_BUDGET), max: 0n }, [target]: { min: share, max: out * 2n } }
        : { [from]: { min: -spend, max: 0n }, [target]: { min: target === SUI ? share - MAX_GAS_BUDGET : share, max: out * 2n } };
      if (target !== SUI && from !== SUI) bounds[SUI] = { min: -MAX_GAS_BUDGET, max: 0n };
      const built = await build(tx, from === SUI ? spend : 0n, bounds);
      return { ...(await signed(built)), spent: String(spend), outAmount: String(out), minOut: String(share) };
    },
    /// The Token Bridge transfer of `amount` of SUI to `executor` (a word, an Ethereum address) on Ethereum, with the
    /// payload 0x01, as Wormhole's SDK builds it, signed. The bridge carries eight decimals: `amount` is a multiple of
    /// ten MIST (the plan's `bridgeable`), so none of it comes back as dust.
    async buildBridgeIn({ mint, amount, executor }) {
      if (normalizeStructTag(mint) !== SUI) throw new Error(`${mint} is not a coin this signer bridges`);
      const value = BigInt(amount);
      if (value % 10n !== 0n) throw new Error(`${amount} MIST is not whole at the bridge's eight decimals`);
      const recipient = { chain: "Ethereum", address: toUniversal("Ethereum", `0x${executor.replace(/^0x/, "").slice(24)}`) };
      const txs = [];
      for await (const u of bridge.transfer(address, recipient, "0x2::sui::SUI", value, new Uint8Array([1]))) txs.push(u.transaction);
      if (txs.length !== 1) throw new Error(`the SDK built ${txs.length} transactions for one transfer`);
      return signed(await build(txs[0], value, { [SUI]: { min: -(value + MAX_GAS_BUDGET), max: -value } }));
    },
    /// The CCTP V2 burn of `amount` of USDC for `treasury` (a word) on Ethereum, with no fee and standard finality,
    /// signed: it must take exactly `amount` (Circle's addDepositForBurnV2).
    async buildSweep({ amount, treasury }) {
      const value = BigInt(amount);
      const tx = new Transaction();
      const coin = coinWithBalance({ type: USDC, balance: value })(tx);
      const [burnReceipt, returned] = tx.moveCall({
        target: `${CCTP.tmmPackage}::deposit_for_burn::deposit_for_burn`,
        arguments: [
          coin,
          tx.pure.u32(ETHEREUM_DOMAIN),
          tx.pure.address(treasury),
          tx.pure.address("0x0"),
          tx.pure.u256(0n),
          tx.pure.u32(STANDARD_FINALITY),
          tx.pure.vector("u8", []),
          tx.object(CCTP.tmmState),
        ],
        typeArguments: [USDC],
      });
      const [ticket] = tx.moveCall({
        target: `${CCTP.handlerPackage}::handler::burn`,
        arguments: [tx.object(CCTP.handlerState), burnReceipt, returned, tx.object(CCTP.denyList), tx.object(CCTP.treasury)],
      });
      tx.moveCall({
        target: `${CCTP.tmmPackage}::deposit_for_burn::complete_burn`,
        arguments: [ticket, tx.object(CCTP.tmmState), tx.object(CCTP.mtState)],
        typeArguments: [USDC, `${CCTP.handlerPackage}::handler::Auth`],
      });
      return signed(await build(tx, 0n, { [USDC]: { min: -value, max: -value }, [SUI]: { min: -MAX_GAS_BUDGET, max: 0n } }));
    },
    /// Sends signed move `raw` as it is; Sui runs a transaction once, so sending it again is safe.
    async send({ raw }) {
      const { bytes, signature } = JSON.parse(raw);
      const r = await client.executeTransaction({ transaction: Buffer.from(bytes, "base64"), signatures: [signature] });
      return (r.Transaction ?? r.FailedTransaction)?.digest ?? null;
    },
    /// What became of transaction `signature` (its digest) with `expiry`: landed, reverted, pending, or expired once a
    /// gas coin it names moved on without it, or its epoch ended.
    async status({ signature, expiry }) {
      const { epoch, gas } = JSON.parse(expiry);
      const s = await fate(signature, gas, epoch);
      if (s.state === "pending") inflight = { digest: signature, gas, epoch };
      else if (inflight?.digest === signature) inflight = null;
      return s;
    },
    /// The sequence the Token Bridge published in transaction `signature`.
    async sequenceOf({ signature }) {
      const ids = (await core.parseTransaction(signature)).filter((m) => `0x${Buffer.from(m.emitter.toUint8Array()).toString("hex")}` === TOKEN_BRIDGE_EMITTER);
      if (ids.length !== 1) throw new Error(`transaction ${signature} carries ${ids.length} Token Bridge messages`);
      return String(ids[0].sequence);
    },
    transferCompleted: ({ vaa }) => bridge.isTransferCompleted(deserialize("TokenBridge:Transfer", hexBytes(vaa))),
    /// Completes transfer `vaa` to this wallet, of a coin among `mints`: what it pays, at nine decimals, must reach the
    /// wallet, and nothing else of the wallet's may move but the gas.
    async redeem({ vaa, mints }) {
      const transfer = transferToMe(vaa);
      if (!mints.some((m) => normalizeStructTag(m) === SUI)) throw new Error("this signer serves no coin");
      const txs = [];
      for await (const u of bridge.redeem(address, transfer)) txs.push(u.transaction);
      if (txs.length !== 1) throw new Error(`the SDK built ${txs.length} transactions for one redeem`);
      const paid = transfer.payload.token.amount * 10n; // eight decimals on the bridge, nine for SUI
      return execute(await build(txs[0], 0n, { [SUI]: { min: paid - MAX_GAS_BUDGET, max: paid } }));
    },
    cctpReceived: ({ message }) => received(message),
    /// Whether this chain would receive CCTP `message` with `attestation`: a simulation, or the message received
    /// already.
    async verifyCctp({ message, attestation }) {
      if (await received(message)) return { valid: true, reason: "" };
      const tx = receiveTransaction(message, attestation);
      tx.setSender(address);
      const sim = await client.simulateTransaction({ transaction: tx, include: { effects: true } });
      const t = sim.Transaction ?? sim.FailedTransaction;
      return t.status.success ? { valid: true, reason: "" } : { valid: false, reason: JSON.stringify(t.status.error) };
    },
    /// Receives CCTP `message` with `attestation` into the wallet; the digest, or null when it was received already.
    async receive({ message, attestation }) {
      if (await received(message)) return null;
      const amount = BigInt(`0x${message.replace(/^0x/, "").slice(2 * (148 + 68), 2 * (148 + 100))}`);
      return execute(await build(receiveTransaction(message, attestation), 0n, { [USDC]: { min: 0n, max: amount }, [SUI]: { min: -MAX_GAS_BUDGET, max: 0n } }));
    },
  };
}
