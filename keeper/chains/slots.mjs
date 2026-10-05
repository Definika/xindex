// The vault slot every chain's proof opens for a fill: the intake digest of (index, intakeId), which the hub computes
// as keccak256(abi.encode(intakeId, keccak256(abi.encode(index, 15)))) (`HybridHubStorage._provenIntake`).
import { encodeAbiParameters, keccak256, parseAbiParameters } from "viem";

export function intakeSlot(index, intakeId) {
  const inner = keccak256(encodeAbiParameters(parseAbiParameters("address, uint256"), [index, 15n]));
  return keccak256(encodeAbiParameters(parseAbiParameters("uint256, bytes32"), [intakeId, inner]));
}
