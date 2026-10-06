// Read-only: plans both flows against live THORNode and an Ethereum RPC, and prints the plans. Sends nothing, signs
// nothing. Run before trusting a THORChain upgrade or a router migration:
//   THORNODES=https://a,https://b ETH_RPC=https://... node swaprail/check-live.mjs
// THORNODES must name two independent endpoints; the same one twice checks the shapes, not the independence.
import { planExitFromEthereum, planFundToEthereum } from "./thorchain.mjs";

const nodes = (process.env.THORNODES ?? "").split(",").filter(Boolean);
const rpc = process.env.ETH_RPC;
if (nodes.length < 2 || !rpc) throw new Error("THORNODES (two, comma-separated) and ETH_RPC are required");
if (new Set(nodes).size < nodes.length) console.log("warning: the same THORNode twice checks the shapes, not the independence\n");

/// An EVM address holds code, an EIP-7702 delegation included. Only Ethereum is asked here.
async function isContract(chain, address) {
  if (chain !== "ETH") throw new Error(`no RPC for ${chain}`);
  const response = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [address, "latest"] }),
  });
  const { result } = await response.json();
  return result !== "0x";
}

// Addresses that hold nothing and are no one's: the plans are printed, never sent.
const user = "0x1111111111111111111111111111111111111111";
const btc = "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh";
const show = (plan) =>
  JSON.stringify(plan, (k, v) => (typeof v === "bigint" ? v.toString() : k === "quote" ? undefined : v), 1);

console.log("exit: 1,000 USDC to BTC");
console.log(show(await planExitFromEthereum({ nodes, from: user, sellAsset: "ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48", amount: 1_000_000_000n, buyAsset: "BTC.BTC", destination: btc, isContract })));
console.log("\nfund: 0.1 BTC to USDC");
console.log(show(await planFundToEthereum({ nodes, sellAsset: "BTC.BTC", amount: 10_000_000n, buyAsset: "ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48", destination: user, isContract })));
console.log("\nrefused, as it must be: a contract destination (Uniswap's router)");
try {
  await planFundToEthereum({ nodes, sellAsset: "BTC.BTC", amount: 10_000_000n, buyAsset: "ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48", destination: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af", isContract });
  console.log("NOT REFUSED");
  process.exitCode = 1;
} catch (e) {
  console.log(`refused: ${e.message}`);
}
