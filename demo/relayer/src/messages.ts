// TESTNETS ONLY: VaultMessages, as src/libraries/VaultMessages.sol encodes them.
import { decodeAbiParameters, keccak256, parseAbiParameters, toHex, type Address, type Hex } from "viem";

export const EVENT_TOPIC = keccak256(toHex("VaultMessage(bytes32,bytes)"));
export const KIND = {
  BURN: 1,
  INTAKE_SETTLED: 2,
  INTAKE_FAILED: 3,
  MIGRATE: 4,
  CAP_UPDATE: 5,
  FREEZE: 6,
  FREEZER_CHANGE: 7,
  VERIFIER_ROTATION: 8,
} as const;

export interface Message {
  payload: Hex;
  id: Hex;
  sourceChainId: bigint;
  kind: number;
  destChainId: bigint;
  vault: Hex;
  index: Address;
  nonce: bigint;
  body: Hex;
}

export function decode(payload: Hex): Message {
  const [, sourceChainId, kind, destChainId, vault, index, nonce, body] = decodeAbiParameters(
    parseAbiParameters("bytes32, uint256, uint8, uint256, bytes32, address, uint256, bytes"),
    payload,
  );
  return { payload, id: keccak256(payload), sourceChainId, kind, destChainId, vault, index, nonce, body };
}

/** The log a message travels in: the block, the emitter, its two topics and its data. */
export interface Log {
  blockNumber: bigint;
  emitter: Address;
  topic1: Hex;
  data: Hex;
}
