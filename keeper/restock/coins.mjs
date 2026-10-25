// The coins the restock service serves and the chains they come from. No dependencies, so the unit tests run without
// `npm install`. `test/unit/restock-coins.test.mjs` pins every coin against script/MainnetAddresses.sol and
// script/PythIds.sol; the home-chain addresses are checked on their own chains before the service sends anything.

/// Each home chain: its Wormhole chain id, its platform, its gas coin, the stablecoin its float is kept in, and its
/// CCTP domain (null where Circle's CCTP does not run, so its float is topped up by hand).
export const CHAINS = Object.freeze({
  bsc: {
    wormhole: 4,
    platform: "evm",
    evmChainId: 56,
    gas: { symbol: "BNB", decimals: 18 },
    // BNB Chain's Binance-Peg coins trade against Binance-Peg USDT; BNB Chain has no CCTP.
    float: { symbol: "USDT", id: "0x55d398326f99059fF775485246999027B3197955", decimals: 18 },
    cctpDomain: null,
  },
  avalanche: {
    wormhole: 6,
    platform: "evm",
    evmChainId: 43114,
    gas: { symbol: "AVAX", decimals: 18 },
    float: { symbol: "USDC", id: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", decimals: 6 },
    cctpDomain: 1,
  },
  optimism: {
    wormhole: 24,
    platform: "evm",
    evmChainId: 10,
    gas: { symbol: "ETH", decimals: 18 },
    float: { symbol: "USDC", id: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", decimals: 6 },
    cctpDomain: 2,
  },
  base: {
    wormhole: 30,
    platform: "evm",
    evmChainId: 8453,
    gas: { symbol: "ETH", decimals: 18 },
    float: { symbol: "USDC", id: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6 },
    cctpDomain: 6,
  },
  solana: {
    wormhole: 1,
    platform: "solana",
    gas: { symbol: "SOL", decimals: 9 },
    float: { symbol: "USDC", id: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6 },
    cctpDomain: 5,
  },
  sui: {
    wormhole: 21,
    platform: "sui",
    gas: { symbol: "SUI", decimals: 9 },
    float: { symbol: "USDC", id: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC", decimals: 6 },
    cctpDomain: 8,
  },
  aptos: {
    wormhole: 22,
    platform: "aptos",
    gas: { symbol: "APT", decimals: 8 },
    float: { symbol: "USDC", id: "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b", decimals: 6 },
    cctpDomain: 9,
  },
  algorand: {
    wormhole: 8,
    platform: "algorand",
    gas: { symbol: "ALGO", decimals: 6 },
    // Algorand's USDC is Circle's own asset, but Algorand has no CCTP.
    float: { symbol: "USDC", id: "31566704", decimals: 6 },
    cctpDomain: null,
  },
});

/// The thirteen coins: the Ethereum copy (`MainnetAddresses`' constant `name`), its home chain and the token there,
/// its decimals (the copy's and the home token's are the same), its Pyth feed, and the venue the service trades it on.
/// `isGas` marks a coin that is its home chain's gas coin, of which the service always keeps a reserve.
export const COINS = Object.freeze(
  [
    { symbol: "XRP", name: "XRP", copy: "0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535", chain: "bsc", home: "0x1d2f0da169ceb9fc7b3144628db156f3f6c60dbe", decimals: 18, venue: "pancakeswap-v3" },
    { symbol: "ADA", name: "ADA", copy: "0x8EfFbF747d4A60Bc6b68D9A1bE4c4188bA8A3a0b", chain: "bsc", home: "0x3ee2200efb3400fabb9aacf31297cbdd1d435d47", decimals: 18, venue: "pancakeswap-v3" },
    { symbol: "LTC", name: "LTC", copy: "0x1cA1Ef3fB8Ff4a480C0ae7eea5f91A24a5BB3344", chain: "bsc", home: "0x4338665cbb7b2485a8855a139b75d5e34ab0db94", decimals: 18, venue: "pancakeswap-v3" },
    { symbol: "DOT", name: "DOT", copy: "0x1839a38E59536D88C25e8E6e0D0f59e05b143ab2", chain: "bsc", home: "0x7083609fce4d1d8dc0c979aab8c869ea2c873402", decimals: 18, venue: "pancakeswap-v3" },
    { symbol: "ATOM", name: "ATOM", copy: "0x7845167B54253269624dBA0cA5Fee87933107b34", chain: "bsc", home: "0x0eb3a705fc54725037cc9e008bdede697f62f335", decimals: 18, venue: "pancakeswap-v3" },
    { symbol: "AVAX", name: "AVAX", copy: "0x85f138bfEE4ef8e540890CFb48F620571d67Eda3", chain: "avalanche", home: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", decimals: 18, venue: "uniswap-v3" },
    { symbol: "OP", name: "OP", copy: "0x1df721D242E0783F8fCab4A9FfE4F35bdf329909", chain: "optimism", home: "0x4200000000000000000000000000000000000042", decimals: 18, venue: "uniswap-v3" },
    { symbol: "AERO", name: "AERO", copy: "0x750525C1877E30304F1E22b1b49b4C9DdE674ddF", chain: "base", home: "0x940181a94a35a4569e4529a3cdfb74e38fd98631", decimals: 18, venue: "uniswap-v3" },
    { symbol: "JUP", name: "JUP", copy: "0x8687a10BCa6F139B25eb31020FCABB5782214764", chain: "solana", home: "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN", decimals: 6, venue: "jupiter" },
    { symbol: "PYTH", name: "PYTH_TOKEN", copy: "0xeFc0CED4B3D536103e76a1c4c74F0385C8F4Bdd3", chain: "solana", home: "HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3", decimals: 6, venue: "jupiter" },
    { symbol: "SUI", name: "SUI", copy: "0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6", chain: "sui", home: "0x2::sui::SUI", decimals: 9, venue: "cetus", isGas: true },
    { symbol: "APT", name: "APT", copy: "0x8CDf7AF57E4c8B930e1B23c477c22f076530585e", chain: "aptos", home: "0x1::aptos_coin::AptosCoin", decimals: 8, venue: "panora", isGas: true },
    { symbol: "ALGO", name: "ALGO", copy: "0xe31Cfcd36FeD044ae4Cf9405B577fe875762194F", chain: "algorand", home: "0", decimals: 6, venue: "tinyman", isGas: true },
  ].map((c) => Object.freeze({ isGas: false, ...c, copy: c.copy.toLowerCase() })),
);

/// Each coin's Pyth feed, which the restock prices every trade against (the ids `script/PythIds.sol` lists the copies
/// with, so a copy is priced as the coin it wraps).
export const PRICE_IDS = Object.freeze({
  XRP: "0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8",
  ADA: "0x2a01deaec9e51a579277b34b122399984d0bbf57e2458a7e42fecd2829867a0d",
  LTC: "0x6e3f3fa8253588df9326580180233eb791e03b443a3ba7a1d892e73874e19a54",
  DOT: "0xca3eed9b267293f6595901c734c7525ce8ef49adafe8284606ceb307afa2ca5b",
  ATOM: "0xb00b60f88b03a6a625a8d1c048c3f66653edf217439983d037e7222c4e612819",
  AVAX: "0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7",
  OP: "0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf",
  AERO: "0x9db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f",
  JUP: "0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996",
  PYTH: "0x0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff",
  SUI: "0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744",
  APT: "0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5",
  ALGO: "0xfa17ceaf30d19ba51112fdcc750cc83454776f47fb0112e4af07f15f4bb1ebc0",
});

/// The coins served when `RESTOCK_COINS` is unset: those whose chain has an adapter and whose home market can take a
/// restock within the loss bound. ATOM is left out, the owner's call of 2026-10-20: Binance-Peg ATOM, the only source its
/// copy redeems for, has almost no market on BNB Chain (read on 2026-10-19: selling $500 lost 305 bps on PancakeSwap
/// v3). JUP, PYTH, SUI, APT and ALGO wait for their chains' adapters.
export const DEFAULT_COINS = Object.freeze(["XRP", "ADA", "LTC", "DOT", "AVAX", "OP", "AERO"]);

/// The coins of `symbols` (`DEFAULT_COINS` when null), refusing a symbol the table does not know.
export function coinsOf(symbols) {
  if (symbols === null) return COINS.filter((c) => DEFAULT_COINS.includes(c.symbol));
  const unknown = symbols.filter((s) => !COINS.some((c) => c.symbol === s));
  if (unknown.length) throw new Error(`unknown restock coins: ${unknown.join(", ")}`);
  return COINS.filter((c) => symbols.includes(c.symbol));
}
