// TESTNETS ONLY: the Solana vault program's client. Instructions are Anchor's (an 8-byte discriminator, then Borsh);
// accounts are derived from the message, as the program derives them.
import { sha256 } from "@noble/hashes/sha256";
import {
  Connection,
  Keypair,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
  sendAndConfirmTransaction,
  type AccountMeta,
} from "@solana/web3.js";
import { hexToBytes, keccak256, type Address, type Hex } from "viem";
import { need } from "./env.js";
import { KIND, type Message } from "./messages.js";

export const connection = () => new Connection(need("SOLANA_RPC"), "confirmed");
export const vaultProgram = () => new PublicKey(need("SOLANA_VAULT_PROGRAM"));
const UPGRADEABLE_LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");

const utf8 = (s: string) => new TextEncoder().encode(s);
const pda = (seeds: Uint8Array[], program = vaultProgram()) => PublicKey.findProgramAddressSync(seeds, program)[0];

export const configPda = () => pda([utf8("config")]);
export const treasuryPda = () => pda([utf8("treasury")]);
export const indexPda = (index: Address) => pda([utf8("index"), hexToBytes(index)]);
export const intakePda = (index: Address, intakeId: Uint8Array) => pda([utf8("intake"), hexToBytes(index), intakeId]);
export const usedPda = (id: Hex) => pda([utf8("used"), hexToBytes(id)]);
export const owedPda = (index: Address, id: Hex) => pda([utf8("owed"), hexToBytes(index), hexToBytes(id)]);
export const depositPda = (index: Address, intakeId: Uint8Array, depositor: PublicKey) =>
  pda([utf8("deposit"), hexToBytes(index), intakeId, depositor.toBytes()]);
export const stubState = (program: PublicKey) => pda([utf8("verifier")], program);
/** A program's ProgramData account under the upgradeable loader. */
export const programData = (program: PublicKey) =>
  PublicKey.findProgramAddressSync([program.toBytes()], UPGRADEABLE_LOADER)[0];

/** Whether `program` can still be upgraded: its ProgramData names an upgrade authority. */
export async function upgradeable(program: PublicKey) {
  const data = (await connection().getAccountInfo(programData(program)))?.data;
  return data !== undefined && data.length >= 13 && data[12] === 1;
}

/** Anchor's instruction discriminator: the first 8 bytes of sha256("global:<name>"). */
export const discriminator = (name: string) => sha256(utf8(`global:${name}`)).slice(0, 8);

// ---------------------------------------------------------------------
// Borsh, for the few types the vault's instructions take
// ---------------------------------------------------------------------

const u64 = (x: bigint) => {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, x, true);
  return b;
};
const u32 = (x: number) => {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, x, true);
  return b;
};
const vec = (bytes: Uint8Array) => concat(u32(bytes.length), bytes);
const some = (bytes: Uint8Array) => concat(new Uint8Array([1]), vec(bytes));
export function concat(...parts: Uint8Array[]) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** `Proofs { block, proof1: Some(empty), proof2: Some(empty), p1_accounts: 2 }`: each stub needs only its relayer. */
const bothStubProofs = (block: bigint) =>
  concat(u64(block), some(new Uint8Array()), some(new Uint8Array()), new Uint8Array([2]));

const meta = (pubkey: PublicKey, isWritable: boolean, isSigner = false): AccountMeta => ({ pubkey, isWritable, isSigner });

// ---------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------

/** Sets a stub verifier's relayer key, once, from the stub's upgrade authority (SOL-1). */
export async function initStub(program: PublicKey, relayer: PublicKey, authority: Keypair) {
  const ix = new TransactionInstruction({
    programId: program,
    keys: [
      meta(stubState(program), true),
      meta(authority.publicKey, true, true),
      meta(SystemProgram.programId, false),
      meta(programData(program), false),
    ],
    data: Buffer.from(concat(new Uint8Array([1]), relayer.toBytes())),
  });
  return sendAndConfirmTransaction(connection(), new Transaction().add(ix), [authority]);
}

export interface InitArgs {
  sourceChainId: bigint;
  chainId: bigint;
  factory: Address;
  hubImplementation: Address;
  freezer: PublicKey;
  nativeCap: bigint;
  nativeFloor: bigint;
}

/** Initializes the vault, from its upgrade authority. P1 and P2 must be programs nobody can upgrade (SOL-2). */
export async function initVault(authority: Keypair, p1: PublicKey, p2: PublicKey, args: InitArgs) {
  const program = vaultProgram();
  const data = concat(
    discriminator("initialize"),
    u64(args.sourceChainId),
    u64(args.chainId),
    hexToBytes(args.factory),
    hexToBytes(args.hubImplementation),
    args.freezer.toBytes(),
    u64(args.nativeCap),
    u64(args.nativeFloor),
  );
  const ix = new TransactionInstruction({
    programId: program,
    keys: [
      meta(authority.publicKey, true, true),
      meta(configPda(), true),
      meta(treasuryPda(), true),
      meta(p1, false),
      meta(p2, false),
      meta(program, false),
      meta(programData(program), false),
      meta(SystemProgram.programId, false),
      meta(programData(p1), false),
      meta(programData(p2), false),
    ],
    data: Buffer.from(data),
  });
  return sendAndConfirmTransaction(connection(), new Transaction().add(ix), [authority]);
}

export async function registerIndex(index: Address, salt: Hex, payer: Keypair) {
  const ix = new TransactionInstruction({
    programId: vaultProgram(),
    keys: [
      meta(payer.publicKey, true, true),
      meta(configPda(), false),
      meta(indexPda(index), true),
      meta(SystemProgram.programId, false),
    ],
    data: Buffer.from(concat(discriminator("register_index"), hexToBytes(index), hexToBytes(salt))),
  });
  return sendAndConfirmTransaction(connection(), new Transaction().add(ix), [payer]);
}

export async function deposit(index: Address, intakeId: Uint8Array, lamports: bigint, depositor: Keypair) {
  const ix = new TransactionInstruction({
    programId: vaultProgram(),
    keys: [
      meta(depositor.publicKey, true, true),
      meta(configPda(), true),
      meta(indexPda(index), false),
      meta(intakePda(index, intakeId), true),
      meta(depositPda(index, intakeId, depositor.publicKey), true),
      meta(treasuryPda(), true),
      meta(SystemProgram.programId, false),
    ],
    data: Buffer.from(concat(discriminator("deposit"), hexToBytes(index), intakeId, u64(lamports))),
  });
  return sendAndConfirmTransaction(connection(), new Transaction().add(ix), [depositor]);
}

// ---------------------------------------------------------------------
// delivery
// ---------------------------------------------------------------------

/** Delivers one message to the Solana vault, both stubs signing through their relayers, unless it already ran there. */
export async function deliverSolana(m: Message, block: bigint, relayer1: Keypair, relayer2: Keypair, p1: PublicKey, p2: PublicKey) {
  const c = connection();
  if (await c.getAccountInfo(usedPda(m.id))) return "done";
  const payload = hexToBytes(m.payload);
  const body = hexToBytes(m.body);
  const system = meta(SystemProgram.programId, false);
  let name: string;
  let keys: AccountMeta[];
  const payer = meta(relayer1.publicKey, true, true);
  if (m.kind === KIND.BURN) {
    const recipient = new PublicKey(body.slice(64, 96));
    name = "deliver_burn";
    keys = [
      payer,
      meta(configPda(), true),
      meta(usedPda(m.id), true),
      meta(indexPda(m.index), true),
      meta(owedPda(m.index, m.id), true),
      meta(recipient, true),
      meta(treasuryPda(), true),
      system,
    ];
  } else if (m.kind === KIND.INTAKE_SETTLED || m.kind === KIND.INTAKE_FAILED) {
    name = "deliver_intake";
    keys = [
      payer,
      meta(configPda(), false),
      meta(usedPda(m.id), true),
      meta(indexPda(m.index), true),
      meta(intakePda(m.index, body.slice(0, 32)), true),
      system,
    ];
  } else if (m.kind === KIND.MIGRATE) {
    const newIndex = `0x${Buffer.from(body.slice(12, 32)).toString("hex")}` as Address;
    name = "deliver_migrate";
    keys = [
      payer,
      meta(configPda(), false),
      meta(usedPda(m.id), true),
      meta(indexPda(m.index), true),
      meta(indexPda(newIndex), true),
      meta(owedPda(m.index, m.id), true),
      system,
    ];
  } else {
    // A raise, a new freezer or new verifiers then wait a week on the vault before anyone applies them (VLT-2).
    name = "deliver_governance";
    keys = [payer, meta(configPda(), true), meta(usedPda(m.id), true), system];
  }
  keys.push(
    meta(p1, false),
    meta(stubState(p1), false),
    meta(relayer1.publicKey, false, true),
    meta(p2, false),
    meta(stubState(p2), false),
    meta(relayer2.publicKey, false, true),
  );
  const data = concat(discriminator(name), vec(payload), bothStubProofs(block));
  const ix = new TransactionInstruction({ programId: vaultProgram(), keys, data: Buffer.from(data) });
  await sendAndConfirmTransaction(c, new Transaction().add(ix), [relayer1, relayer2]);
  return "delivered";
}

// ---------------------------------------------------------------------
// state, for Ethereum
// ---------------------------------------------------------------------

/** The vault's intake account: `Intake { index, intake_id, state, has_native, total, digest, bump }` after Anchor's
 *  8-byte discriminator. */
export async function solanaIntake(index: Address, intakeId: Uint8Array) {
  const c = connection();
  const slot = await c.getSlot("finalized");
  const account = await c.getAccountInfo(intakePda(index, intakeId), { commitment: "finalized" });
  const timestamp = BigInt((await c.getBlockTime(slot)) ?? 0);
  if (!account) return { exists: false, digest: ("0x" + "00".repeat(32)) as Hex, hasNative: false, total: 0n, state: 0, slot, timestamp };
  const d = account.data;
  const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
  return {
    exists: true,
    state: d[60],
    hasNative: d[61] === 1,
    total: view.getBigUint64(62, true),
    digest: `0x${Buffer.from(d.subarray(70, 102)).toString("hex")}` as Hex,
    slot,
    timestamp,
  };
}

/** The vault's address in the digests Ethereum proves: the last 20 bytes of its `config` key. */
export const solanaVaultAddress = () => `0x${Buffer.from(configPda().toBytes().slice(12)).toString("hex")}` as Address;

/** A message id, for logs. */
export const idOf = (payload: Hex) => keccak256(payload);
