// THORChain on the Xindex swap rail: app-side only, always from the user's own wallets (the owner's call on
// 2026-10-06; design/2026-10-06-swap-venues.md). A reference implementation for the web app, which lives in its own
// repository. No Xindex contract calls THORChain, and nothing here signs or sends: it plans a swap, checks it, and
// returns what the user's wallet should sign.
//
// Two flows:
//   planExitFromEthereum   after a burn to USDC, USDT, ETH or WBTC, swap it from the user's Ethereum account to another
//                          chain's coin at the user's own address there, such as BTC.
//   planFundToEthereum     before a mint, swap a UTXO chain's coin (BTC, LTC, BCH, DOGE) to USDC, USDT, ETH or WBTC
//                          at the user's own Ethereum account; the user then mints with the zap.
//
// Why not from a contract: THORChain attributes a deposit to the transaction's signer, reads a deposit made inside any
// contract but its router only while EVMDISABLECONTRACTWHITELIST is 1 and only in a transaction of at most 200 logs, and
// otherwise ignores it, losing the funds. Its vaults rotate every few days and its Ethereum router is due to migrate.
// So the deposit is always the user's own transaction to the router, never the zap's.
//
// Every plan fails closed. It refuses when:
//   - fewer than two THORNode endpoints agree on the chain's router and vaults, or either reports a halt or pause;
//   - the Ethereum router is not one this module pins (THORChain_Router v4.1);
//   - the quote's vault is not an active Asgard vault on both nodes, or its router is not the pinned one;
//   - a destination or the depositing account is a contract (THORChain: "Do not swap to smart contract addresses");
//     an EIP-7702 delegated account counts as a contract;
//   - the quote resolves the memo's asset to anything but the asset asked for, has expired or expires within
//     MIN_QUOTE_LIFE, charges more than maxFeeBps, or the amount is under its recommended minimum;
//   - the memo, which this module writes itself rather than taking THORNode's, exceeds the source chain's limit.
// The memo always carries a limit (the quote's expected output less slippageBps), so a swap that would pay less is
// refunded rather than filled, and from Ethereum it always names the user as the refund address.

/// THORChain_Router v4.1 on Ethereum mainnet: the router in `/thorchain/inbound_addresses`, Blockscout-verified
/// (code hash 0x7f7ad482...68cc), checked 2026-10-06. Router v6.1 (0x00dc6100103BC402d490aEE3F9a5560cBd91f1d4) is
/// deployed but not yet Ethereum's; it credits ERC-20s to the vault directly and treats an expiry of 0 as none, so it is
/// added here only after its deposit semantics are reviewed again. Until then a migration makes every Ethereum plan
/// refuse, which is the intended failure.
export const ETHEREUM_ROUTERS = new Set(["0xd37bbe5744d730a1d98d8dc97c42f0ca46ad7146"]);

/// The Ethereum assets the rail moves, with their token contracts (null for ether) and decimals. All four have
/// THORChain pools; the index's own components do not, so THORChain only ever bridges these.
export const ETHEREUM_ASSETS = {
  "ETH.ETH": { token: null, decimals: 18 },
  "ETH.USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48": { token: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6 },
  "ETH.USDT-0XDAC17F958D2EE523A2206206994597C13D831EC7": { token: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6 },
  "ETH.WBTC-0X2260FAC5E5542A773AA44FBCFEDF7C193BC2C599": { token: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bC2C599", decimals: 8 },
};

/// UTXO chains carry the memo in OP_RETURN, 80 bytes; THORChain refuses any memo over 250 bytes elsewhere.
const UTXO_CHAINS = new Set(["BTC", "LTC", "BCH", "DOGE"]);
const MAX_MEMO = 250;
const UTXO_MEMO = 80;
/// A quote must still have this long to live when the plan is made, so the user has time to sign.
export const MIN_QUOTE_LIFE = 300;
/// `depositWithExpiry(address,address,uint256,string,uint256)` and `approve(address,uint256)`.
const DEPOSIT_WITH_EXPIRY = "0x44bc937b";
const APPROVE = "0x095ea7b3";

export class RailError extends Error {}
const refuse = (why) => {
  throw new RailError(why);
};

const lower = (a) => a.toLowerCase();
const chainOf = (asset) => asset.split(".")[0];

/// THORChain amounts are in 1e8 units whatever the coin's decimals.
export function toThorUnits(raw, decimals) {
  return decimals >= 8 ? raw / 10n ** BigInt(decimals - 8) : raw * 10n ** BigInt(8 - decimals);
}

/// A swap memo, `=:ASSET:DEST[/REFUND]:LIM/INTERVAL/QUANTITY`, written here from typed fields. The full asset id is used
/// when it fits the source chain's limit, and `CHAIN.TICKER` otherwise, whose resolution the quote then proves.
export function swapMemo({ asset, destination, refund, limit, sourceChain, interval = 1, quantity = 0 }) {
  if (limit <= 0n) refuse("a swap memo needs a positive limit");
  const max = UTXO_CHAINS.has(sourceChain) ? UTXO_MEMO : MAX_MEMO;
  const dest = refund ? `${destination}/${refund}` : destination;
  const tail = `${dest}:${limit}/${interval}/${quantity}`;
  for (const name of [asset, asset.split("-")[0]]) {
    const memo = `=:${name}:${tail}`;
    if (new TextEncoder().encode(memo).length <= max) return memo;
  }
  refuse(`the memo does not fit ${sourceChain}'s ${max} bytes`);
}

// ---------------------------------------------------------------------------------------------------------------
// THORNode
// ---------------------------------------------------------------------------------------------------------------

async function getJson(fetchImpl, url) {
  const response = await fetchImpl(url);
  if (!response.ok) refuse(`THORNode ${response.status} on ${url}`);
  return response.json();
}

/// What every node must agree on for `chains`: none halted or paused, the same router, and the active vault addresses.
export async function networkState(nodes, fetchImpl, chains) {
  if (!Array.isArray(nodes) || nodes.length < 2) refuse("two independent THORNode endpoints are required");
  const states = [];
  for (const node of nodes) {
    const inbound = await getJson(fetchImpl, `${node}/thorchain/inbound_addresses`);
    const vaults = await getJson(fetchImpl, `${node}/thorchain/vaults/asgard`);
    const state = {};
    for (const chain of chains) {
      const entry = inbound.find((c) => c.chain === chain);
      if (!entry) refuse(`${node} lists no ${chain}`);
      if (entry.halted || entry.global_trading_paused || entry.chain_trading_paused) refuse(`${chain} is halted or paused`);
      const active = vaults.filter((v) => v.status === "ActiveVault");
      state[chain] = {
        router: entry.router ? lower(entry.router) : null,
        vaults: new Set(active.flatMap((v) => (v.addresses ?? []).filter((a) => a.chain === chain).map((a) => lower(a.address)))),
        dust: BigInt(entry.dust_threshold ?? "0"),
      };
    }
    states.push(state);
  }
  for (const chain of chains) {
    const routers = new Set(states.map((s) => s[chain].router));
    if (routers.size !== 1) refuse(`the nodes disagree on ${chain}'s router`);
  }
  return states;
}

function checkQuote(quote, { states, sourceChain, buyAsset, amount1e8, maxFeeBps, now }) {
  const vault = lower(quote.inbound_address ?? "");
  for (const state of states) {
    if (!state[sourceChain].vaults.has(vault)) refuse(`the quote's vault ${vault} is not an active vault on every node`);
  }
  if (sourceChain === "ETH") {
    const router = lower(quote.router ?? "");
    if (!ETHEREUM_ROUTERS.has(router)) refuse(`router ${quote.router} is not pinned`);
    if (router !== states[0].ETH.router) refuse("the quote's router is not the network's");
  }
  if (lower(quote.fees?.asset ?? "") !== lower(buyAsset)) refuse(`the quote resolves the output to ${quote.fees?.asset}, not ${buyAsset}`);
  if (BigInt(quote.expiry) < BigInt(now + MIN_QUOTE_LIFE)) refuse("the quote expires too soon");
  if (Number(quote.fees.total_bps) > maxFeeBps) refuse(`fees of ${quote.fees.total_bps} bps exceed ${maxFeeBps}`);
  if (amount1e8 < BigInt(quote.recommended_min_amount_in ?? "0")) refuse("the amount is under THORChain's recommended minimum");
  for (const state of states) {
    if (amount1e8 <= state[sourceChain].dust) refuse("the amount is under the dust threshold");
  }
  const expected = BigInt(quote.expected_amount_out);
  if (expected <= 0n) refuse("the quote expects nothing out");
}

function quoteUrl(node, { sellAsset, buyAsset, amount1e8, destination, refund }) {
  const q = new URLSearchParams({
    from_asset: sellAsset,
    to_asset: buyAsset,
    amount: amount1e8.toString(),
    destination,
    streaming_interval: "1",
    streaming_quantity: "0",
  });
  if (refund) q.set("refund_address", refund);
  return `${node}/thorchain/quote/swap?${q}`;
}

const limitFrom = (expected, slippageBps) => (BigInt(expected) * BigInt(10_000 - slippageBps)) / 10_000n;

// ---------------------------------------------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------------------------------------------

const word = (hex) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const uint = (n) => word(BigInt(n).toString(16));

/// `router.depositWithExpiry(vault, asset, amount, memo, expiry)`, ABI-encoded.
export function encodeDeposit(vault, asset, amount, memo, expiry) {
  const bytes = new TextEncoder().encode(memo);
  const data = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  const padded = data.padEnd(Math.ceil(data.length / 64) * 64, "0");
  return `${DEPOSIT_WITH_EXPIRY}${word(vault)}${word(asset)}${uint(amount)}${uint(0xa0)}${uint(expiry)}${uint(bytes.length)}${padded}`;
}

const encodeApprove = (spender, amount) => `${APPROVE}${word(spender)}${uint(amount)}`;

// ---------------------------------------------------------------------------------------------------------------
// The two flows
// ---------------------------------------------------------------------------------------------------------------

/// Plans a swap from the user's own Ethereum account to `buyAsset` on another chain at the user's `destination` there.
/// `isContract(chain, address)` reports whether an EVM address holds code, EIP-7702 delegations included; it is asked
/// about the sender and, on an EVM destination chain, about the destination. Returns the transactions for the user's
/// wallet to send, in order, from `from`, plus what to show the user.
export async function planExitFromEthereum({
  nodes,
  fetchImpl = fetch,
  from,
  sellAsset,
  amount,
  buyAsset,
  destination,
  slippageBps = 100,
  maxFeeBps = 100,
  now = Math.floor(Date.now() / 1000),
  isContract,
}) {
  const sell = ETHEREUM_ASSETS[sellAsset];
  if (!sell) refuse(`${sellAsset} is not an Ethereum asset the rail moves`);
  if (chainOf(buyAsset) === "ETH") refuse("an Ethereum-to-Ethereum swap belongs on the zap, not THORChain");
  if (typeof isContract !== "function") refuse("isContract is required");
  if (await isContract("ETH", from)) refuse("the sender must be an externally owned account: THORChain may ignore a contract's deposit");
  const destChain = chainOf(buyAsset);
  if (/^0x[0-9a-fA-F]{40}$/.test(destination) && (await isContract(destChain, destination))) {
    refuse("the destination must be the user's own account, not a contract");
  }
  if (amount <= 0n) refuse("nothing to swap");

  const states = await networkState(nodes, fetchImpl, ["ETH", destChain]);
  const amount1e8 = toThorUnits(amount, sell.decimals);
  const quote = await getJson(fetchImpl, quoteUrl(nodes[0], { sellAsset, buyAsset, amount1e8, destination, refund: from }));
  checkQuote(quote, { states, sourceChain: "ETH", buyAsset, amount1e8, maxFeeBps, now });

  const limit = limitFrom(quote.expected_amount_out, slippageBps);
  const memo = swapMemo({ asset: buyAsset, destination, refund: from, limit, sourceChain: "ETH" });
  const router = lower(quote.router);
  const vault = lower(quote.inbound_address);
  const expiry = BigInt(quote.expiry);
  const transactions = [];
  if (sell.token) {
    // USDT refuses to change a non-zero allowance, so its approval is reset first; for the others it is harmless.
    transactions.push({ to: sell.token, value: 0n, data: encodeApprove(router, 0n) });
    transactions.push({ to: sell.token, value: 0n, data: encodeApprove(router, amount) });
  }
  transactions.push({
    to: router,
    value: sell.token ? 0n : amount,
    data: encodeDeposit(vault, sell.token ?? "0x0000000000000000000000000000000000000000", amount, memo, expiry),
  });
  return { flow: "exit", from, memo, limit, expectedOut: BigInt(quote.expected_amount_out), expiry, router, vault, transactions, quote };
}

/// Plans a swap from a UTXO chain's coin to `buyAsset` on Ethereum at the user's own Ethereum `destination`, where the
/// user then mints with the zap. The user's wallet on the source chain sends `amount` to `vault` with `memo` in
/// OP_RETURN, from its own address; THORChain refunds to that address, or to `refund` when given.
export async function planFundToEthereum({
  nodes,
  fetchImpl = fetch,
  sellAsset,
  amount,
  buyAsset,
  destination,
  refund,
  slippageBps = 100,
  maxFeeBps = 100,
  now = Math.floor(Date.now() / 1000),
  isContract,
}) {
  const sourceChain = chainOf(sellAsset);
  if (!UTXO_CHAINS.has(sourceChain)) refuse(`${sellAsset} is not a UTXO chain's coin; fund from a wallet on that chain`);
  if (!ETHEREUM_ASSETS[buyAsset]) refuse(`${buyAsset} is not an Ethereum asset the zap mints with`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(destination)) refuse("the destination must be an Ethereum address");
  if (typeof isContract !== "function") refuse("isContract is required");
  if (await isContract("ETH", destination)) {
    refuse("the destination must be the user's own account: THORChain pays a contract by plain transfer, and the zap, an index or MintRequests would strand it");
  }
  if (amount <= 0n) refuse("nothing to swap");

  const states = await networkState(nodes, fetchImpl, [sourceChain, "ETH"]);
  const quote = await getJson(fetchImpl, quoteUrl(nodes[0], { sellAsset, buyAsset, amount1e8: amount, destination, refund }));
  checkQuote(quote, { states, sourceChain, buyAsset, amount1e8: amount, maxFeeBps, now });

  const limit = limitFrom(quote.expected_amount_out, slippageBps);
  const memo = swapMemo({ asset: buyAsset, destination, refund, limit, sourceChain });
  return {
    flow: "fund",
    vault: quote.inbound_address,
    amount,
    memo,
    limit,
    expectedOut: BigInt(quote.expected_amount_out),
    expiry: BigInt(quote.expiry),
    quote,
  };
}
