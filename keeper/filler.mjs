// Xindex v5 cross-chain filler for indexes holding vault coins (HybridHub). DRAFT, untested (2026-10-06).
//
// A hybrid rebalance settles in three steps, since vault legs cannot settle in one transaction:
//   accept   the filler posts a bond in the index's own shares (0.1% of the supply), delivers the bought Ethereum legs,
//            names its address on each vault chain for the sold vault legs, and brings Pyth's update for the block;
//   deliver  on each vault chain it deposits the bought legs into the vault under the fill's intake id, within the
//            delivery window;
//   settle   it proves each chain's deliveries on Ethereum, through that chain's state verifier; the index then sends it
//            the sold Ethereum legs, and burns the sold vault legs toward its addresses there, which the vaults pay
//            once the message relayers carry the burns.
// The bond comes back BOND_HOLD after settlement (or with the next accept), and burns if a delivery proves forged.
//
// Each pass resumes a fill this filler accepted, so a restart loses nothing, and first keeps every adapter's state
// verifier on Ethereum within its day (`follow`). Chains: BNB Chain (`chains/bnb.mjs`), Injective
// (`chains/injective.mjs`), TRON (`chains/tron.mjs`), VeChain (`chains/vechain.mjs`), Sui (`chains/sui.mjs`) and Aptos
// (`chains/aptos.mjs`). Every other vault chain needs its adapter (deposit, intake proof,
// recipient) before an index holding its coins can be filled here; until then such an auction is logged and left to
// other executors.
//
// Env: RPC_URL, KEEPER_KEY, FACTORY, PYTH_API_KEY, HERMES_URL, MIN_PROFIT_USD, MAX_SUBSIDY_USD, SWAP_COST_BPS and
// POLL_SECONDS as for keeper.mjs, plus:
//   BNB_RPC, BNB_KEY       BNB Chain's RPC and the filler's key there, holding the coins it delivers. BNB_CHAIN_ID
//                          defaults to 56 (97 for BNB testnet).
//   INJECTIVE_RPC, INJECTIVE_KEY   Injective's EVM RPC and the filler's key there; proving needs SP1's prover network.
//   TRON_API, TRON_KEY     TronGrid's API (https://api.trongrid.io) and the filler's key on TRON, holding TRX for its
//                          deliveries and its energy. TRON_CHAIN_ID defaults to mainnet's, 728126428.
//   VECHAIN_KEY            The filler's key on VeChain, holding VET for its deliveries and VTHO for gas. VECHAIN_NETWORK
//                          is mainnet (the default), testnet or solo; VECHAIN_NODE another node of that network.
//   SUI_KEY, SUI_VAULT, SUI_PACKAGE   The filler's Sui key (suiprivkey...), the vault's 32-byte object id and its
//                          package. SUI_RPC (gRPC) and SUI_GRAPHQL default to Sui's public mainnet services.
//   APTOS_KEY, APTOS_VAULT, APTOS_PACKAGE   The filler's Aptos key, the vault's object address and its package.
//                          APTOS_NETWORK is mainnet (the default) or testnet.
// The filler's Ethereum account must hold the bond's shares and the Ethereum legs it delivers: it buys nothing itself.

import { createPublicClient, createWalletClient, http, formatUnits, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { abi } from "./artifacts.mjs";
import { aptosChain } from "./chains/aptos.mjs";
import { bnbChain } from "./chains/bnb.mjs";
import { injectiveChain } from "./chains/injective.mjs";
import { tronChain } from "./chains/tron.mjs";
import { suiChain } from "./chains/sui.mjs";
import { vechainChain } from "./chains/vechain.mjs";

const env = (name, fallback) => {
  const value = process.env[name] ?? fallback;
  if (value === undefined) throw new Error(`${name} is required`);
  return value;
};

const RPC_URL = env("RPC_URL");
const FACTORY = env("FACTORY");
const PYTH_API_KEY = env("PYTH_API_KEY");
const HERMES_URL = env("HERMES_URL", "https://hermes.pyth.network");
const MIN_PROFIT_USD = Number(env("MIN_PROFIT_USD", "5"));
const MAX_SUBSIDY_USD = Number(env("MAX_SUBSIDY_USD", "0"));
const SWAP_COST_BPS = Number(env("SWAP_COST_BPS", "30"));
const POLL_SECONDS = Number(env("POLL_SECONDS", "120"));
const PRICE_LAG = 12n;
const SLOT = 12n;
const ZERO = "0x0000000000000000000000000000000000000000";
const FILL = { None: 0, Accepted: 1, Settled: 2 };

const account = privateKeyToAccount(env("KEEPER_KEY"));
const eth = createPublicClient({ transport: http(RPC_URL) });
const ethChainId = await eth.getChainId();
const ethChain = { id: ethChainId, name: "ethereum", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: {} };
const ethWallet = createWalletClient({ account, chain: ethChain, transport: http(RPC_URL) });

/// The vault chains this filler can deliver on, by chain id.
const adapters = new Map();
if (process.env.BNB_RPC) {
  const bnb = bnbChain({
    chainId: Number(env("BNB_CHAIN_ID", "56")),
    rpc: env("BNB_RPC"),
    key: env("BNB_KEY"),
    ethClient: eth,
    ethWallet,
  });
  adapters.set(bnb.chainId, bnb);
}
if (process.env.INJECTIVE_RPC) {
  const injective = injectiveChain({ rpc: env("INJECTIVE_RPC"), key: env("INJECTIVE_KEY"), ethClient: eth, ethWallet });
  adapters.set(injective.chainId, injective);
}
if (process.env.TRON_API) {
  const tron = tronChain({
    api: env("TRON_API"),
    key: env("TRON_KEY"),
    ethClient: eth,
    ethWallet,
    chainId: BigInt(env("TRON_CHAIN_ID", "728126428")),
  });
  adapters.set(tron.chainId, tron);
}
if (process.env.SUI_KEY) {
  const sui = suiChain({
    rpc: process.env.SUI_RPC,
    graphql: process.env.SUI_GRAPHQL,
    key: env("SUI_KEY"),
    vaultId: env("SUI_VAULT"),
    packageId: env("SUI_PACKAGE"),
    ethClient: eth,
    ethWallet,
  });
  adapters.set(sui.chainId, sui);
}
if (process.env.APTOS_KEY) {
  const aptos = aptosChain({
    network: env("APTOS_NETWORK", "mainnet"),
    key: env("APTOS_KEY"),
    vault: env("APTOS_VAULT"),
    packageAddress: env("APTOS_PACKAGE"),
    ethClient: eth,
    ethWallet,
  });
  adapters.set(aptos.chainId, aptos);
}
if (process.env.VECHAIN_KEY) {
  const vechain = await vechainChain({
    network: env("VECHAIN_NETWORK", "mainnet"),
    host: process.env.VECHAIN_NODE,
    key: env("VECHAIN_KEY"),
    ethClient: eth,
    ethWallet,
  });
  adapters.set(vechain.chainId, vechain);
}

const log = (...args) => console.log(new Date().toISOString(), ...args);
const read = (address, contract, functionName, args = []) => eth.readContract({ address, abi: abi(contract), functionName, args });
async function write(address, contract, functionName, args, value) {
  const hash = await ethWallet.writeContract({ address, abi: abi(contract), functionName, args, value });
  const receipt = await eth.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  log(functionName, address, hash);
  return receipt;
}

// ---------------------------------------------------------------------
// Hermes
// ---------------------------------------------------------------------

async function hermes(path) {
  const response = await fetch(`${HERMES_URL}${path}`, { headers: { Authorization: `Bearer ${PYTH_API_KEY}` } });
  if (!response.ok) throw new Error(`Hermes ${response.status} on ${path}: ${await response.text()}`);
  return response.json();
}
const idsQuery = (ids) => ids.map((id) => `ids[]=${id}`).join("&");

// ---------------------------------------------------------------------
// One hybrid index
// ---------------------------------------------------------------------

const wordToAddress = (word) => getAddress(`0x${word.slice(-40)}`);

async function layout(index) {
  const [tokens, units, chainIds, vaultTokens] = await read(index, "IHybridIndex", "components");
  const [chains, vaults] = await read(index, "IHybridIndex", "chains");
  const [, priceIds, decimals] = await read(index, "IHybridIndex", "componentTerms");
  return { tokens, units, chainIds, vaultTokens, chains, vaults, priceIds, decimals };
}

/// Accepts the open auction when it pays, or when the loss stays within the subsidy.
async function accept(index, l) {
  const pending = await read(index, "IHybridIndex", "pendingRebalance");
  const [eta, keepMask] = [pending[0], pending[1]];
  if (eta === 0n) return;
  const block = await eth.getBlock();
  const duration = await read(index, "IHybridIndex", "AUCTION_DURATION");
  if (block.timestamp < eta || block.timestamp > eta + duration) return;

  const moving = (i) => ((keepMask >> BigInt(i)) & 1n) === 0n;
  for (let i = 0; i < l.tokens.length; ++i) {
    if (moving(i) && l.chainIds[i] !== 0n && !adapters.has(l.chainIds[i])) {
      log("no adapter for chain", l.chainIds[i], "- left to other executors:", index);
      return;
    }
  }

  const ids = l.priceIds.filter((_, i) => moving(i));
  const latest = new Map();
  for (const p of (await hermes(`/v2/updates/price/latest?${idsQuery(ids)}&parsed=true`)).parsed) latest.set(`0x${p.id.replace(/^0x/, "")}`, p.price);
  const prices = l.priceIds.map((id, i) => {
    if (!moving(i)) return { price: 0n, conf: 0n, expo: 0, publishTime: 0n };
    const p = latest.get(id);
    return { price: BigInt(p.price), conf: BigInt(p.conf), expo: Number(p.expo), publishTime: BigInt(p.publish_time) };
  });
  let preview;
  try {
    preview = await read(index, "IHybridIndex", "previewRebalance", [prices]);
  } catch (error) {
    log("no fill for", index, error.shortMessage ?? error.message);
    return;
  }
  const [, , amountsOut, amountsIn] = preview;
  const value = (amounts) =>
    amounts.reduce((sum, a, i) => sum + (a === 0n ? 0 : Number(formatUnits(a, l.decimals[i])) * Number(prices[i].price) * 10 ** prices[i].expo), 0);
  const out = value(amountsOut);
  const inn = value(amountsIn);
  const profit = out - inn - (out + inn) * (SWAP_COST_BPS / 10_000);
  log(index, `out $${out.toFixed(2)}`, `in $${inn.toFixed(2)}`, `profit before gas $${profit.toFixed(2)}`);
  if (profit < MIN_PROFIT_USD && -profit > MAX_SUBSIDY_USD) return;

  // The bond, in the index's own shares, and the Ethereum legs: the filler must already hold both.
  const supply = await read(index, "IHybridIndex", "totalSupply");
  const bond = (supply * (await read(index, "IHybridIndex", "REBALANCE_BOND")) + 10n ** 18n - 1n) / 10n ** 18n;
  const shares = await read(index, "IHybridIndex", "balanceOf", [account.address]);
  if (shares < bond) {
    log("needs", bond, "shares as a bond, holds", shares, "- not accepting", index);
    return;
  }
  for (let i = 0; i < l.tokens.length; ++i) {
    if (l.chainIds[i] !== 0n || amountsIn[i] === 0n) continue;
    const held = await read(l.tokens[i], "IERC20", "balanceOf", [account.address]);
    if (held < amountsIn[i]) {
      log("holds", held, "of", l.tokens[i], "needs", amountsIn[i], "- not accepting", index);
      return;
    }
    // A margin over the preview: the settlement is recomputed at the accepting block's supply.
    await write(l.tokens[i], "IERC20", "approve", [index, amountsIn[i] * 2n]);
  }

  // The vault legs it must deliver after accepting: an undelivered fill costs the bond, so it commits only to what it
  // already holds on each chain (gas aside).
  for (let i = 0; i < l.tokens.length; ++i) {
    if (l.chainIds[i] === 0n || amountsIn[i] === 0n) continue;
    const token = l.vaultTokens[i] === `0x${"0".repeat(64)}` ? ZERO : wordToAddress(l.vaultTokens[i]);
    const held = await adapters.get(l.chainIds[i]).holds(token);
    if (held < amountsIn[i]) {
      log("holds", held, "of", token, "on chain", l.chainIds[i], "needs", amountsIn[i], "- not accepting", index);
      return;
    }
  }

  const recipients = l.chains.map((chainId) => (adapters.has(chainId) ? adapters.get(chainId).recipient() : `0x${"0".repeat(64)}`));
  const next = (await eth.getBlock()).timestamp + SLOT;
  const update = (await hermes(`/v2/updates/price/${Number(next - PRICE_LAG)}?${idsQuery(ids)}&encoding=hex`)).binary.data.map(
    (h) => (h.startsWith("0x") ? h : `0x${h}`),
  );
  const pyth = await read(FACTORY, "HybridIndexFactory", "PYTH");
  const fee = await eth.readContract({ address: pyth, abi: abi("IPyth"), functionName: "getUpdateFee", args: [update] });
  const bounds = amountsIn.map((a) => a * 2n);
  try {
    await write(index, "IHybridIndex", "acceptRebalance", [recipients, bounds, update], fee);
  } catch (error) {
    log("accept failed", index, error.shortMessage ?? error.message);
  }
}

/// Deposits every bought vault leg not yet deposited, then settles once every chain's deliveries are in.
async function deliverAndSettle(index, l) {
  const intakeId = await read(index, "IHybridIndex", "fillIntakeId");
  const [, deliveries] = await read(index, "IHybridIndex", "fillAmounts");
  const vaultOf = (chainId) => wordToAddress(l.vaults[l.chains.findIndex((c) => c === chainId)]);

  for (let i = 0; i < l.tokens.length; ++i) {
    if (l.chainIds[i] === 0n || deliveries[i] === 0n) continue;
    const adapter = adapters.get(l.chainIds[i]);
    const vault = vaultOf(l.chainIds[i]);
    const token = l.vaultTokens[i] === `0x${"0".repeat(64)}` ? ZERO : wordToAddress(l.vaultTokens[i]);
    const recipient = wordToAddress(adapter.recipient());
    // Already deposited by this filler: skip, so a restart never pays twice.
    const done = await adapter.readDeposited(vault, index, intakeId, token, recipient);
    if (done >= deliveries[i]) continue;
    log("depositing", deliveries[i] - done, "of", token, "on chain", l.chainIds[i]);
    await adapter.deposit(vault, index, intakeId, token, deliveries[i] - done);
  }

  const proofs = [];
  for (let j = 0; j < l.chains.length; ++j) {
    const chainId = l.chains[j];
    const needed = l.tokens.some((_, i) => l.chainIds[i] === chainId && deliveries[i] !== 0n);
    if (!needed) {
      proofs.push({ proof: "0x", tokens: [], totals: [] });
      continue;
    }
    const verifier = await read(FACTORY, "HybridIndexFactory", "stateVerifier", [chainId]);
    proofs.push(await adapters.get(chainId).intakeProof(verifier, wordToAddress(l.vaults[j]), index, intakeId));
  }
  await write(index, "IHybridIndex", "settleRebalance", [proofs]);
}

/// Keeps each adapter's state verifier on Ethereum within its day, so a fill can always be proven.
async function follow() {
  for (const [chainId, adapter] of adapters) {
    if (!adapter.follow) continue;
    try {
      const { vault, stateVerifier } = await read(FACTORY, "HybridIndexFactory", "chain", [chainId]);
      if (stateVerifier === ZERO) continue;
      await adapter.follow(stateVerifier, wordToAddress(vault));
    } catch (error) {
      log("follow failed on chain", chainId, error.shortMessage ?? error.message);
    }
  }
}

async function pass() {
  await follow();
  const count = await read(FACTORY, "HybridIndexFactory", "allIndexesLength");
  for (let k = 0n; k < count; k++) {
    const index = await read(FACTORY, "HybridIndexFactory", "allIndexes", [k]);
    try {
      if ((await read(FACTORY, "HybridIndexFactory", "indexSalt", [index])) === `0x${"0".repeat(64)}`) continue; // not hybrid
      if (await read(index, "IHybridIndex", "canStartRebalance")) await write(index, "IHybridIndex", "startRebalance", [0n]);
      const fill = await read(index, "IHybridIndex", "fill");
      const l = await layout(index);
      if (fill.status === FILL.Accepted && getAddress(fill.executor) === account.address) {
        await deliverAndSettle(index, l);
      } else if (fill.status === FILL.Settled && getAddress(fill.executor) === account.address) {
        if ((await eth.getBlock()).timestamp >= fill.bondRelease) await write(index, "IHybridIndex", "releaseBond", []);
      } else if (fill.status !== FILL.Accepted) {
        await accept(index, l);
      }
    } catch (error) {
      log("error on", index, error.shortMessage ?? error.message);
    }
  }
}

log("filler", account.address, "factory", FACTORY, "chains", [...adapters.keys()].join(",") || "none");
do {
  await pass();
  if (process.argv.includes("--once")) break;
  await new Promise((resolve) => setTimeout(resolve, POLL_SECONDS * 1000));
} while (true);
