// UniswapX's V2 Dutch order in viem's terms: the API's encodedOrder decoded into the fields `uniswapx.mjs` checks, and
// the order's hash, as the reactor emits it in its Fill event. viem only.
//
// The decoding is no safety boundary: the service signs typed data it builds from the decoded fields after checking
// them (`uniswapx.mjs` permitTypedData), and the reactor recomputes the order's hash from the bytes it is given. Bytes
// that decode here to something other than what the reactor reads fail the signature on chain and move nothing.

import { decodeAbiParameters, hashStruct, parseAbiParameters } from "viem";
import { permitTypedData } from "./uniswapx.mjs";

/// V2DutchOrder, as UniswapX's V2DutchOrderLib declares it, ABI-encoded whole by the Trading API.
const V2_ORDER = parseAbiParameters(
  "((address reactor, address swapper, uint256 nonce, uint256 deadline, address additionalValidationContract, bytes additionalValidationData) info, address cosigner, (address token, uint256 startAmount, uint256 endAmount) baseInput, (address token, uint256 startAmount, uint256 endAmount, address recipient)[] baseOutputs, (uint256 decayStartTime, uint256 decayEndTime, address exclusiveFiller, uint256 exclusivityOverrideBps, uint256 inputAmount, uint256[] outputAmounts) cosignerData, bytes cosignature)",
);

/// The order `encoded` (hex) carries, or throws when it is not one.
export function decodeV2Order(encoded) {
  if (typeof encoded !== "string" || !/^0x([0-9a-fA-F]{2})+$/.test(encoded)) throw new Error("the API's encodedOrder is no hex");
  const [order] = decodeAbiParameters(V2_ORDER, encoded);
  return order;
}

/// The order's EIP-712 hash, its id on chain: what the reactor's Fill event and the Trading API name it by.
export function orderHash(order, chainId) {
  const { types, message } = permitTypedData(order, chainId);
  return hashStruct({ data: message.witness, primaryType: "V2DutchOrder", types });
}
