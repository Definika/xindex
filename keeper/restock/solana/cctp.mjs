// CCTP V2 on Solana, as Circle's own examples build it (circlefin/solana-cctp-contracts, examples/v2/solana.ts and
// utilsV2.ts, commit ec16e95): the burn that sends the float home to the treasury on Ethereum, and the receipt of a burn
// the treasury sent here. The programs' interface definitions are Circle's (./idl, NOTICE). Transactions are built
// here and signed by the caller, never sent from here: the restock journals a burn before it is broadcast.

import anchor from "@coral-xyz/anchor";
import { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { Keypair, PublicKey, SystemProgram } from "@solana/web3.js";
import { readFileSync } from "node:fs";

const idl = (name) => JSON.parse(readFileSync(new URL(`./idl/${name}.json`, import.meta.url), "utf8"));

/// CCTP's domain for Solana, and for Ethereum, where every burn from here goes.
export const SOLANA_DOMAIN = 5;
export const ETHEREUM_DOMAIN = 0;
/// A standard transfer: finalized on the source chain, with no fee (CCTP V2's `minFinalityThreshold` of 2000).
export const STANDARD_FINALITY = 2000;
/// Circle's USDC on Solana.
export const USDC_MINT = new PublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");

/// A program address with `label` and `extra` seeds, as Circle's `findProgramAddress` derives it: strings as UTF-8,
/// buffers as they are, keys as their bytes.
export function pda(label, programId, extra = []) {
  const seeds = [Buffer.from(label, "utf8")];
  for (const seed of extra) {
    if (typeof seed === "string") seeds.push(Buffer.from(seed, "utf8"));
    else if (Buffer.isBuffer(seed)) seeds.push(seed);
    else seeds.push(seed.toBuffer());
  }
  return PublicKey.findProgramAddressSync(seeds, programId)[0];
}

const hexBytes = (hex) => Buffer.from(hex.replace(/^0x/, ""), "hex");

/// A CCTP V2 message's fields this module needs: its source domain (bytes 4..8), its nonce (bytes 12..44, Circle's
/// `decodeEventNonceFromMessageV2`), and its burn message's burn token (32 bytes after the 148-byte header and the
/// burn message's 4-byte version).
export function messageFields(message) {
  const bytes = hexBytes(message);
  if (bytes.length < 148 + 36) throw new Error("not a CCTP V2 burn message");
  return {
    sourceDomain: bytes.readUInt32BE(4),
    nonce: bytes.subarray(12, 44),
    burnToken: new PublicKey(bytes.subarray(148 + 4, 148 + 36)),
  };
}

/// The CCTP V2 programs over `connection`, signing as `wallet` (a Keypair).
export function createCctp({ connection, wallet }) {
  const provider = new anchor.AnchorProvider(connection, new anchor.Wallet(wallet), { commitment: "confirmed" });
  const transmitter = new anchor.Program(idl("message_transmitter_v2"), provider);
  const messenger = new anchor.Program(idl("token_messenger_minter_v2"), provider);
  const usdcAccount = getAssociatedTokenAddressSync(USDC_MINT, wallet.publicKey);

  /// The account `receiveMessage` marks a message's nonce used in: its existence is the message received.
  const usedNonce = (message) => pda("used_nonce", transmitter.programId, [messageFields(message).nonce]);

  /// The burn of `amount` (raw USDC) from the wallet's USDC account, minted on Ethereum to `recipient` (a 32-byte hex
  /// word), with no destination caller, no fee and standard finality, as an unsigned transaction and the event account
  /// keypair it must also be signed by. The event account's rent can be reclaimed five days on.
  async function burnTransaction(amount, recipient) {
    const event = Keypair.generate();
    const accounts = {
      owner: wallet.publicKey,
      eventRentPayer: wallet.publicKey,
      senderAuthorityPda: pda("sender_authority", messenger.programId),
      burnTokenAccount: usdcAccount,
      messageTransmitter: pda("message_transmitter", transmitter.programId),
      tokenMessenger: pda("token_messenger", messenger.programId),
      remoteTokenMessenger: pda("remote_token_messenger", messenger.programId, [ETHEREUM_DOMAIN.toString()]),
      tokenMinter: pda("token_minter", messenger.programId),
      localToken: pda("local_token", messenger.programId, [USDC_MINT]),
      burnTokenMint: USDC_MINT,
      messageSentEventData: event.publicKey,
      messageTransmitterProgram: transmitter.programId,
      tokenMessengerMinterProgram: messenger.programId,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
    };
    const params = {
      amount: new anchor.BN(amount.toString()),
      destinationDomain: ETHEREUM_DOMAIN,
      mintRecipient: new PublicKey(hexBytes(recipient)),
      maxFee: new anchor.BN(0),
      minFinalityThreshold: STANDARD_FINALITY,
      destinationCaller: PublicKey.default,
    };
    const transaction = await messenger.methods.depositForBurn(params).accountsPartial(accounts).transaction();
    return { transaction, signers: [event], eventAccount: event.publicKey };
  }

  /// The receipt of `message` with `attestation`, minting to the wallet's USDC account, as an unsigned transaction.
  async function receiveTransaction(message, attestation) {
    const { sourceDomain, nonce, burnToken } = messageFields(message);
    const domain = sourceDomain.toString();
    const tokenMessenger = pda("token_messenger", messenger.programId);
    const { feeRecipient } = await messenger.account.tokenMessenger.fetch(tokenMessenger);
    const remaining = [
      [tokenMessenger, false],
      [pda("remote_token_messenger", messenger.programId, [domain]), false],
      [pda("token_minter", messenger.programId), true],
      [pda("local_token", messenger.programId, [USDC_MINT]), true],
      [pda("token_pair", messenger.programId, [domain, burnToken]), false],
      [getAssociatedTokenAddressSync(USDC_MINT, feeRecipient), true],
      [usdcAccount, true],
      [pda("custody", messenger.programId, [USDC_MINT]), true],
      [TOKEN_PROGRAM_ID, false],
      [pda("__event_authority", messenger.programId), false],
      [messenger.programId, false],
    ].map(([pubkey, isWritable]) => ({ pubkey, isWritable, isSigner: false }));
    return transmitter.methods
      .receiveMessage({ message: hexBytes(message), attestation: hexBytes(attestation) })
      .accountsPartial({
        payer: wallet.publicKey,
        caller: wallet.publicKey,
        authorityPda: pda("message_transmitter_authority", transmitter.programId, [messenger.programId]),
        messageTransmitter: pda("message_transmitter", transmitter.programId),
        usedNonce: pda("used_nonce", transmitter.programId, [nonce]),
        receiver: messenger.programId,
        systemProgram: SystemProgram.programId,
      })
      .remainingAccounts(remaining)
      .transaction();
  }

  /// The reclaim of burn event account `eventAccount`'s rent, with the burn's `message` and its `attestation`, as
  /// Circle's `reclaimEventAccount` example builds it: allowed five days after the burn.
  const reclaimTransaction = (eventAccount, message, attestation) =>
    transmitter.methods
      .reclaimEventAccount({ attestation: hexBytes(attestation), destinationMessage: hexBytes(message) })
      .accountsPartial({ payee: wallet.publicKey, messageTransmitter: pda("message_transmitter", transmitter.programId), messageSentEventData: eventAccount })
      .transaction();

  return {
    usdcAccount,
    reclaimTransaction,
    transmitterId: transmitter.programId,
    messengerId: messenger.programId,
    burnTransaction,
    receiveTransaction,
    /// Whether `message` was received here already.
    received: async (message) => (await connection.getAccountInfo(usedNonce(message))) !== null,
  };
}
