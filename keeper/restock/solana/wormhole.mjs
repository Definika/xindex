// Wormhole's Token Bridge on Solana, through Wormhole's own TypeScript SDK, as its docs recommend
// (wormhole.com/docs/products/token-transfers/wrapped-token-transfers/get-started): `transfer` with a payload sends a
// native SPL token (`transferNativeWithPayload`) to the executor on Ethereum, which alone may complete it; `redeem`
// posts a VAA, opens the wallet's token account for the mint if missing, and completes a transfer the executor bridged
// out to that account. The transfer is built here and signed by the caller, which journals it before it is sent; the
// redeem's transactions only complete a move, each counted once by the bridge, so they are signed and sent here.

import { contracts, deserialize, toUniversal } from "@wormhole-foundation/sdk-connect";
import { SolanaWormholeCore } from "@wormhole-foundation/sdk-solana-core";
import { SolanaTokenBridge } from "@wormhole-foundation/sdk-solana-tokenbridge";
import { getAssociatedTokenAddressSync } from "@solana/spl-token";
import { PublicKey } from "@solana/web3.js";

/// Wormhole's chain id for Ethereum, where every transfer from here goes.
const ETHEREUM = "Ethereum";

const hexBytes = (hex) => Buffer.from(hex.replace(/^0x/, ""), "hex");

/// The Token Bridge and core on Solana mainnet over `connection`, for `wallet` (a Keypair).
export function createWormhole({ connection, wallet }) {
  const addresses = { coreBridge: contracts.coreBridge("Mainnet", "Solana"), tokenBridge: contracts.tokenBridge("Mainnet", "Solana") };
  const bridge = new SolanaTokenBridge("Mainnet", "Solana", connection, addresses);
  const core = new SolanaWormholeCore("Mainnet", "Solana", connection, addresses);
  const tokenBridgeId = new PublicKey(addresses.tokenBridge);
  /// Who the Token Bridge publishes as: its program address derived from "emitter".
  const emitter = PublicKey.findProgramAddressSync([Buffer.from("emitter")], tokenBridgeId)[0];

  /// `vaa` (0x-hex) as the SDK's transfer, refusing any other kind of message.
  const transferOf = (vaa) => deserialize("TokenBridge:Transfer", hexBytes(vaa));

  return {
    tokenBridgeId,
    emitter,
    /// The transfer of `amount` of native SPL token `mint` to `executor` (a 32-byte hex word, an Ethereum address) on
    /// Ethereum, with the payload 0x01, as the SDK builds it: one transaction and its extra signers (the message
    /// account's keypair). Refuses anything but exactly one transaction.
    async transferTransaction(mint, amount, executor) {
      const recipient = { chain: ETHEREUM, address: toUniversal(ETHEREUM, `0x${executor.replace(/^0x/, "").slice(24)}`) };
      const built = [];
      for await (const unsigned of bridge.transfer(wallet.publicKey, recipient, mint, amount, new Uint8Array([1]))) built.push(unsigned);
      if (built.length !== 1) throw new Error(`the SDK built ${built.length} transactions for one transfer`);
      const { transaction, signers = [] } = built[0].transaction;
      return { instructions: transaction.instructions, signers };
    },
    /// The sequence the Token Bridge published in transaction `signature`, from the core's own record of it.
    async sequenceOf(signature) {
      const ids = await core.parseTransaction(signature);
      const mine = ids.filter((m) => Buffer.from(m.emitter.toUint8Array()).equals(emitter.toBuffer()));
      if (mine.length !== 1) throw new Error(`transaction ${signature} carries ${mine.length} Token Bridge messages`);
      return mine[0].sequence;
    },
    /// The Solana mint transfer `vaa` carries home; refuses a token from another chain.
    mintOf(vaa) {
      const { token } = transferOf(vaa).payload;
      if (token.chain !== "Solana") throw new Error(`the transfer carries a token of ${token.chain}`);
      return new PublicKey(token.address.toUint8Array());
    },
    /// Whether transfer `vaa` was completed already.
    transferCompleted: (vaa) => bridge.isTransferCompleted(transferOf(vaa)),
    /// The redeem of transfer `vaa`, as the SDK builds it, after checking it pays the wallet's own token account for
    /// `mint` (a PublicKey): the transactions to sign and send in order.
    async redeemTransactions(vaa, mint) {
      const transfer = transferOf(vaa);
      const token = transfer.payload.token;
      if (token.chain !== "Solana" || !Buffer.from(token.address.toUint8Array()).equals(mint.toBuffer())) {
        throw new Error(`the transfer carries ${token.chain}'s ${token.address}, not ${mint.toBase58()}`);
      }
      const to = Buffer.from(transfer.payload.to.address.toUint8Array());
      const own = getAssociatedTokenAddressSync(mint, wallet.publicKey);
      if (!to.equals(own.toBuffer())) throw new Error(`the transfer pays ${new PublicKey(to).toBase58()}, not the wallet's account ${own.toBase58()}`);
      const built = [];
      for await (const unsigned of bridge.redeem(wallet.publicKey, transfer, false)) built.push(unsigned.transaction);
      return built;
    },
  };
}
