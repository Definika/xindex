// The coins the restock service serves and the chains they come from. No dependencies, so the unit tests run without
// `npm install`. `test/unit/restock-coins.test.mjs` pins every coin against script/MainnetAddresses.sol and
// script/PythIds.sol; the home-chain addresses are checked on their own chains before the service sends anything.

/// Each home chain: its Wormhole chain id, its platform, its gas coin, the stablecoin its float is kept in, and its
/// CCTP domain. Every one of them runs CCTP V2 (read on 2026-11-01; Circle retires V1 by 2026-12-01).
export const CHAINS = Object.freeze({
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
});

/// The three coins: the Ethereum copy (`MainnetAddresses`' constant `name`), its home chain and the token there, its
/// decimals (the copy's and the home token's are the same), its Pyth feed, and the venue the service trades it on.
export const COINS = Object.freeze(
  [
    // BNB's copy wraps WBNB, an ERC-20 like the others here; the gas reserve is native BNB, so it is no gas coin (RZ-5).
    { symbol: "AVAX", name: "AVAX", copy: "0x85f138bfEE4ef8e540890CFb48F620571d67Eda3", chain: "avalanche", home: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", decimals: 18, venue: "uniswap-v3" },
    { symbol: "OP", name: "OP", copy: "0x1df721D242E0783F8fCab4A9FfE4F35bdf329909", chain: "optimism", home: "0x4200000000000000000000000000000000000042", decimals: 18, venue: "uniswap-v3" },
    { symbol: "AERO", name: "AERO", copy: "0x750525C1877E30304F1E22b1b49b4C9DdE674ddF", chain: "base", home: "0x940181a94a35a4569e4529a3cdfb74e38fd98631", decimals: 18, venue: "uniswap-v3" },
  ].map((c) => Object.freeze({ local: false, ...c, copy: c.copy.toLowerCase() })),
);

/// The coins Ethereum issues itself that the service buys on Ethereum, through UniswapX, rather than bridges in: the
/// nine Ondo stocks Pyth prices at the token's own feed, which the keeper values and so delivers from stock (the other
/// 343 Ondo legs it never values, `bot/config.mjs` SHARE_PRICED_IDS, RX-2, so stock of them would serve no fill). Few
/// have a Uniswap pool; UniswapX's fillers, Ondo's minting desk among them, sell them for USDC. `copy` is the token
/// itself, as the executor holds it, and `local` marks the coin: no home chain, no bridge, no sale; the treasury buys
/// it and deposits it into the executor (`depositStock`), credited within the owner's restock allowance (RS-1).
/// `test/unit/restock-coins.test.mjs` pins each against script/MainnetAddresses.sol and script/PythIds.sol; symbol and
/// decimals were read on chain on 2026-11-24.
export const LOCAL_COINS = Object.freeze(
  [
    { symbol: "NVDAON", name: "NVDAON", copy: "0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE" },
    { symbol: "AAPLON", name: "AAPLON", copy: "0x14c3abF95Cb9C93a8b82C1CdCB76D72Cb87b2d4c" },
    { symbol: "GOOGLON", name: "GOOGLON", copy: "0xbA47214eDd2bb43099611b208f75E4b42FDcfEDc" },
    { symbol: "MSFTON", name: "MSFTON", copy: "0xB812837b81a3a6b81d7CD74CfB19A7f2784555E5" },
    { symbol: "TSLAON", name: "TSLAON", copy: "0xf6b1117ec07684D3958caD8BEb1b302bfD21103f" },
    { symbol: "HOODON", name: "HOODON", copy: "0x998f02A9E343EF6E3E6f28700d5A20F839fD74E6" },
    { symbol: "MSTRON", name: "MSTRON", copy: "0xCabD955322dfbf94C084929ac5E9Eca3fEB5556F" },
    { symbol: "COINON", name: "COINON", copy: "0xF042cfa86cf1D598a75Bdb55c3507a1F39f9493b" },
    { symbol: "CRCLON", name: "CRCLON", copy: "0x3632DEa96A953C11dac2f00b4A05a32CD1063fAE" },
  ].map((c) =>
    Object.freeze({ ...c, copy: c.copy.toLowerCase(), home: c.copy.toLowerCase(), chain: "ethereum", decimals: 18, venue: "uniswapx", local: true }),
  ),
);

/// Each coin's Pyth feed, which the restock prices every trade against (the ids `script/PythIds.sol` lists the copies
/// with, so a copy is priced as the coin it wraps, and each Ondo stock at its token's own feed).
export const PRICE_IDS = Object.freeze({
  AVAX: "0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7",
  OP: "0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf",
  AERO: "0x9db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f",
  NVDAON: "0x207ddea2a443d30b7e13a7c88a9e3f106765deb97049afc65a18cede50fffc82",
  AAPLON: "0xe6734de88a83d9d2fb33072adab319004700aefd069653aba30ba9e3cac056f2",
  GOOGLON: "0xad79b3487bef87ff8f8ab31c0b779ad08d931fdfa5436f7e92a234bb82bff7e4",
  MSFTON: "0x29b228e9fd72bbd306bcca3b10c165d8dba5d535ef8d5aab6c6e4bc18912d150",
  TSLAON: "0xc09ef687ed07091c047da444f1499f2da52cdc1c085104643ec565a9eb1af514",
  HOODON: "0x8d61af9bd7c39d9503d7d99b7e9e59cc7b0bd707341ecc3ed3e3eda1a411f4de",
  MSTRON: "0x89a131faf74b5298981e3d25bbce60a25c6f452004da31ddd3c5805cdaa9b6ab",
  COINON: "0x8c56635a4257942fabf7ce5dd861dbe91375c370e6b5feac3fb8ba7206a30e46",
  CRCLON: "0x25edf380836977c4fea6d1e8df3567192c4e11deeeb566c8e0bd8022068860df",
});

/// The coins served when `RESTOCK_COINS` is unset: those whose home market can take a restock within the loss bound.
/// OP left Ethereum's list on 2026-11-21 (the owner's call): that day no route bought it on Optimism within
/// ROUTE_MAX_LOSS_BPS, its deepest Uniswap v3 pool there holding about $35,000 of USDC. It stays in the table, as its
/// address stays in `MainnetAddresses`, for a relisting, and `RESTOCK_COINS` can still name it. The copies of XRP, ADA,
/// LTC, DOT, ATOM, BNB, JUP, PYTH, SUI, APT and ALGO, which left the list on 2026-11-13 and 2026-11-18, went from the
/// table on 2026-11-25 (audit/2026-11-25-non-evm-restock-retirement.md). AERO's copy left on 2026-11-26 (the owner's
/// call): it is a copy of Aerodrome's AERO, which Aero replaced with a token of its own, so its home token's depth is
/// leaving and its conversion is Aero's to end. It stays in the table, as OP does, and `RESTOCK_COINS` can name it.
export const DEFAULT_COINS = Object.freeze(["AVAX"]);

/// The coins of `symbols`, bridged or local, refusing a symbol neither table knows. When null: `DEFAULT_COINS`, and
/// with `uniswapx` (the service has a UniswapX API key) every local coin too, since only UniswapX buys them.
export function coinsOf(symbols, { uniswapx = false } = {}) {
  const all = [...COINS, ...LOCAL_COINS];
  if (symbols === null) return all.filter((c) => DEFAULT_COINS.includes(c.symbol) || (uniswapx && c.local));
  const unknown = symbols.filter((s) => !all.some((c) => c.symbol === s));
  if (unknown.length) throw new Error(`unknown restock coins: ${unknown.join(", ")}`);
  return all.filter((c) => symbols.includes(c.symbol));
}
