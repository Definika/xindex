// The keeper's settings, read from the environment and checked before anything runs. No dependencies, so the unit
// tests run without `npm install`.

import { MAINNET_PRICE_IDS } from "./price-ids.mjs";

const WETH_ID = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";
/// BNB/USD, the gas coin's price on BNB Chain (script/PythIds.sol `BNB`).
const BNB_ID = "0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f";

/// The chains the keeper runs on, by chain id (`CHAIN_ID`): the addresses it trades through on each, and the keeper's
/// own price source there. `pyth` is Pyth's contract, which the keeper asks to confirm that a price Hermes served is
/// the signed one (RX-9, RY-7), and through which its executor posts the update a fill on a factory with an oracle
/// carries. `priceIds` maps each coin the keeper can value to its Pyth id, a coin without an entry being one it leaves
/// alone; with `feedsFromFactory` the ids are instead each token's feed as the factory records it (`priceFeedOf`),
/// the very feed its hubs check a fill against. Each entry also says:
/// - `usdcDecimals`: the float's decimals (USDC's six, eighteen for BNB Chain's Binance-Peg USDC);
/// - `ethPriceId`: the gas coin's Pyth id (ETH's, BNB's on BNB Chain), at which gas is valued;
/// - `blockMs`, `fillWindowSeconds`: how often a block comes, and how long a fill sent now may take to land, past
///   which it reverts on its deadline (`M.landing`); windows the bot keeps in blocks scale with `blockMs`;
/// - `l1FeeOracle`: on an OP Stack chain, the predeploy that prices a transaction's data posted to Ethereum, which the
///   chain charges on top of its gas;
/// - `maxFeeGwei`, `priorityFeeGwei`: the defaults of MAX_FEE_GWEI and PRIORITY_FEE_GWEI there.
/// Every address of BNB Chain's and Base's entries was read on chain on 2026-11-24: SwapRouter02 and QuoterV2 answer
/// `factory()` with the address book's Uniswap V3 factory and `WETH9()` with its wrapped gas coin, and the Token
/// Bridge answers `chainId()` with Wormhole's id for the chain (4, 30); `test/unit/chains.test.mjs` pins the rest
/// against `script/BnbChainAddresses.sol` and `script/BaseAddresses.sol`.
export const CHAINS = Object.freeze({
  1: Object.freeze({
    name: "Ethereum",
    chainId: 1,
    swapRouter02: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
    quoterV2: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
    v3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
    weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    // Wormhole's Token Bridge, through which the restock service bridges the copies in and out.
    tokenBridge: "0x3ee18B2214AFF97000D974cf647E7C347E8fa585",
    ethPriceId: WETH_ID,
    pyth: "0x4305FB66699C3B2702D4d05CF36551390A4c69C6",
    priceIds: MAINNET_PRICE_IDS,
    feedsFromFactory: false,
    usdcDecimals: 6,
    blockMs: 12_000,
    fillWindowSeconds: 12,
    l1FeeOracle: null,
    maxFeeGwei: "100",
    priorityFeeGwei: "2",
  }),
  // The test deployment's market (docs/deployment.md, "Testnet (Sepolia)"): Uniswap V3 pools against tUSDC, the
  // FaucetToken the deployment mints with. Read on chain on 2026-10-31: SwapRouter02 and QuoterV2 answer factory()
  // with the V3 factory, SwapRouter02's WETH9() is WETH, and the Token Bridge's chainId() is Sepolia's Wormhole id,
  // 10002. Its hub is the build of 07aeae1, which rebalances at Pyth's prices, so until a deployment of the
  // oracle-free build replaces it the keeper serves it with FILL_AUCTIONS=0: requests only. The test tokens are priced
  // at their mainnet counterparts' ids, as that deployment listed them.
  11155111: Object.freeze({
    name: "Sepolia",
    chainId: 11155111,
    swapRouter02: "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E",
    quoterV2: "0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3",
    v3Factory: "0x0227628f3F023bb0B980b67D528571c95c6DaC1c",
    weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    usdc: "0xD1aF4223B129071f7a1a27ED367E4D72cd7cF8D3",
    tokenBridge: "0xDB5492265f6038831E89f495670FF909aDe94bd9",
    ethPriceId: WETH_ID,
    pyth: "0xDd24F84d36BF92C65F92307595335bdFab5Bbd21",
    priceIds: Object.freeze({
      "0xfff9976782d46cc05630d1f6ebab18b2324d6b14": WETH_ID, // WETH
      "0x656c9999ad6092f813996c30a2dbe89ff2f670a9": "0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33", // tWBTC
      "0xc02f993785fc45cf48bf61c24dcbb11f9085a4e4": "0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221", // tLINK
      "0xc34fe6c23897ae506368cf3acb0db96d6d63bf85": "0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501", // tUNI
    }),
    feedsFromFactory: false,
    usdcDecimals: 6,
    blockMs: 12_000,
    fillWindowSeconds: 12,
    l1FeeOracle: null,
    maxFeeGwei: "100",
    priorityFeeGwei: "2",
  }),
  // BNB Chain: a block every 450 ms (measured 2026-11-24: 200 blocks in 90 s), no base fee and a gas price of 0.05
  // gwei, gas paid in BNB. Uniswap V3 is the keeper's venue as on Ethereum; it routes six of the twelve coins of 2026-11-13
  // and the rest are served from stock. Both stablecoins have eighteen decimals. The Token Bridge is Wormhole's,
  // which the executor's constructor requires and nothing here uses: the restock serves Ethereum alone.
  56: Object.freeze({
    name: "BNB Chain",
    chainId: 56,
    swapRouter02: "0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2",
    quoterV2: "0x78D78E420Da98ad378D7799bE8f4AF69033EB077",
    v3Factory: "0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7",
    weth: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB, the routing hub
    usdc: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",
    tokenBridge: "0xB6F6D86a8f9879A9c87f643768d9efc38c1Da6E7",
    ethPriceId: BNB_ID,
    pyth: "0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594",
    priceIds: Object.freeze({}),
    feedsFromFactory: true,
    usdcDecimals: 18,
    blockMs: 450,
    fillWindowSeconds: 3,
    l1FeeOracle: null,
    maxFeeGwei: "1",
    priorityFeeGwei: "0.1",
  }),
  // Base: a block every 200 ms (measured 2026-11-24: 200 blocks in 40 s), gas paid in ETH, and the L1 data fee on top,
  // which GasPriceOracle prices (OP Stack's predeploy at 0x42…0F).
  8453: Object.freeze({
    name: "Base",
    chainId: 8453,
    swapRouter02: "0x2626664c2603336E57B271c5C0b26F421741e481",
    quoterV2: "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a",
    v3Factory: "0x33128a8fC17869897dcE68Ed026d694621f6FDfD",
    weth: "0x4200000000000000000000000000000000000006",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    tokenBridge: "0x8d2de8d2f73F1F4cAB472AC9A881C9b123C79627",
    ethPriceId: WETH_ID,
    pyth: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a",
    priceIds: Object.freeze({}),
    feedsFromFactory: true,
    usdcDecimals: 6,
    blockMs: 200,
    fillWindowSeconds: 3,
    l1FeeOracle: "0x420000000000000000000000000000000000000F",
    maxFeeGwei: "1",
    priorityFeeGwei: "0.01",
  }),
});

/// Ethereum's entry, which the restock service, mainnet-only, uses throughout.
export const MAINNET = CHAINS[1];

/// WeightedHub's storage slots for the pending auction (`forge inspect WeightedHub storageLayout`), which the start
/// check overrides to simulate an auction before opening one; `quoteProposal` is set to {NO_QUOTE_PROPOSAL} there,
/// since a start of the keeper's posts no quote and a past proposal's must not bind the simulation. The keeper
/// verifies them at startup, and `test_XS8_theBotsHubSlotsAreTheHubs` (keeper/test/KeeperExecutor.t.sol) pins them
/// against a real hub.
export const HUB_SLOTS = Object.freeze({ eta: 6n, keepMask: 7n, quoteProposal: 14n });

/// What the start check writes into the hub's `quoteProposal` slot: a proposal id no index reaches, so the simulated
/// auction carries no quote. The hub holds a fill to a quote when that slot equals `proposalCount`, and the
/// simulation opens an auction without counting a proposal, so zero, the slot's own empty value, named the proposal
/// of an index never started: every first start then simulated as quoted at no prices and failed with Panic(50).
/// `test_theBotsNoQuoteValueBindsNoProposal` pins it.
export const NO_QUOTE_PROPOSAL = 2n ** 256n - 1n;

/// WeightedHub's slots for the recorded units and scale, which no view returns: `components()` reports units at the
/// scale an accrual now would leave. The invariant checker (invariants.mjs) reads them to evaluate the backing
/// invariant exactly, cross-checks them against the views every round, and `test_theCheckersHubSlotsAreTheHubs`
/// (keeper/test/KeeperExecutor.t.sol) pins them against a real hub. Slot 0 holds the length of `_components`, whose
/// element `i` is the word at keccak256(slot 0) + i: the token in its low 20 bytes, the units in the 12 above. Slot 3
/// holds `_scale` (uint128), then `_lastAccrual` (uint40) and `_maskedFill` (bool).
export const HUB_STATE_SLOTS = Object.freeze({ components: 0n, scale: 3n });

/// EIP-7825's cap on a transaction's gas.
export const TX_GAS_CAP = 16_777_216n;

/// A price older than this many seconds is a closed or quiet feed (US-hours stock feeds): the keeper values nothing at
/// it, so it moves no such leg and fills no request priced at it (RX-1).
export const FRESH_SECONDS = 60n;

/// The widest confidence interval a price the bot values anything at may carry, in basis points of the price (RX-1).
export const MAX_CONF_BPS = 200n;

/// The 343 Ondo legs whose Pyth feed prices the share, while each token is worth sValue shares (script/PythIds.sol,
/// CF-3). The bot cannot read sValue, so it never values these at Pyth: it names no new units for them, delivers none
/// from stock and counts any it keeps as nothing (RX-2). `test/unit/config.test.mjs` pins the list against PythIds.sol.
export const SHARE_PRICED_IDS = Object.freeze(
  [
    "0x329635cf9e705e01ed2d842fafbb6c426d7e5630e75847740d89957222fd68b8", // AMZNon, Equity.Index.AMZN/USD
    "0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4", // TSMon, Equity.US.TSM/USD
    "0x2dbfb1791e75725227a90dbd23c6bdd83b80cc9d13011973c948b6aeacdf17b9", // SPCXon, Equity.Index.SPCX/USD
    "0x2cc0c022f7f37920485a5947f3cea8633783b6cb7fff6d94ee52f48687b7783d", // METAon, Equity.Index.META/USD
    "0xd0c9aef79b28308b256db7742a0a9b08aaa5009db67a52ea7fa30ed6853f243b", // AVGOon, Equity.US.AVGO/USD
    "0xb196587ca694ea231cd8710321f4f62ed08794c6a096759d5c63616730042ae0", // SKHYon, Equity.Index.SKHY/USD
    "0x27e65b49e4572601374c5bde284411c20f49eb74845cc7f7801f9d27fba2b4b2", // MUon, Equity.Index.MU/USD
    "0x70dcf5fd56553d0023693e4b590336a8c9bcfd0d98dd9f093b1f697820d98325", // LLYon, Equity.US.LLY/USD
    "0xfa1a3697811ac1b36846b4de42ad1b4d3c7b50b556eed405dbefbf4e4a0c7c07", // AMDon, Equity.Index.AMD/USD
    "0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e", // JPMon, Equity.US.JPM/USD
    "0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc", // WMTon, Equity.US.WMT/USD
    "0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90", // Von, Equity.US.V/USD
    "0xe65ff435be42630439c96396653a342829e877e2aafaeaf1a10d0ee5fd2cf3f2", // GOOGon, Equity.US.GOOG/USD
    "0x5967c196ca33171a0b2d140ddc6334b998dd71c2ddd85ba7920c35fd6ed20fe9", // IVVon, Equity.US.IVV/USD
    "0xf32c3fbdd20b846bb53395bf175c42955e00b1bffb5a778bb624982b318f5461", // SPYon, Equity.Index.SPY/USD
    "0x26c67e91769aeba33a09469c705a1863794014dac416e4270661f489309ae862", // VTIon, Equity.US.VTI/USD
    "0x4a1a12070192e8db9a89ac235bb032342a390dde39389b4ee1ba8e41e7eae5d8", // XOMon, Equity.US.XOM/USD
    "0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63", // JNJon, Equity.US.JNJ/USD
    "0x639db3fe6951d2465bd722768242e68eb0285f279cb4fa97f677ee8f80f1f1c0", // MAon, Equity.US.MA/USD
    "0x1a6e324589a0e355919fb1c0389edc3fdf4c46034626bd82aad4e47714cfa94f", // ASMLon, Equity.US.ASML/USD
    "0x019ae7cb58ee716ebdd1288b057373d60224fc98a9a43ee373c6b0df1f3ffdf5", // ABBVon, Equity.US.ABBV/USD
    "0x163f6a6406d65305e8e27965b9081ac79b0cf9529f0fcdc14fe37e65e3b6b5cb", // COSTon, Equity.US.COST/USD
    "0x6d595efb30db0e0139f254eb40985c8695e7ed7e5856287cb5084d2d7794b7eb", // QQQon, Equity.Index.QQQ/USD
    "0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d", // KOon, Equity.US.KO/USD
    "0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5", // CVXon, Equity.US.CVX/USD
    "0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4", // PGon, Equity.US.PG/USD
    "0x52c7c6b70032b7151c8d0febf684f14318e1e13315976e171267639955400bb9", // PLTRon, Equity.Index.PLTR/USD
    "0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481", // CSCOon, Equity.US.CSCO/USD
    "0x98aacad2adc9ffa8949da73015a5b623b0c062bd7f07b6f4dfda244b9b672c39", // ORCLon, Equity.Index.ORCL/USD
    "0xe1d3115c6e7ac649faca875b3102f1000ab5e06b03f6903e0d699f0f5315ba86", // GEon, Equity.US.GE/USD
    "0x21debc1718a4b76ff74dadf801c261d76c46afaafb74d9645b65e00b80f5ee3e", // BACon, Equity.US.BAC/USD
    "0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5", // HDon, Equity.US.HD/USD
    "0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46", // MRKon, Equity.US.MRK/USD
    "0xcecbc86ad1adfa72b78b573375dc36eb4664e096252c0a3e55e625ea838685f1", // INTCon, Equity.Index.INTC/USD
    "0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd", // UNHon, Equity.US.UNH/USD
    "0x3b00df0661ccb3109d11ff301c1aa4e88b8d647cb477b089ba225149e6e1b7bb", // PANWon, Equity.US.PANW/USD
    "0xb9bc74cc1243b706efacf664ed206d08ab1dda79e8b87752c7c44b3bdf1b9e08", // AMATon, Equity.US.AMAT/USD
    "0x01a67883f58bd0f0e9cf8f52f21d7cf78c144d7e7ae32ce9256420834b33fb75", // LRCXon, Equity.US.LRCX/USD
    "0xc5b94c7ece9c3ac984e1439a8fac86270d0f988bbbcc838b456e2d7311754bdc", // TXNon, Equity.US.TXN/USD
    "0x97c483cc4172de7ac1a3cc0814f442e4747e64008723f2705d6e9fdff3ba4d3d", // RTXon, Equity.US.RTX/USD
    "0x244fdf268ed7ecfad2cf84529c46d0fcef7a643428ff4ef8b16e8dbb63e0f2d9", // TMOon, Equity.US.TMO/USD
    "0xbaed936d3c6c2e34104e92c6b015b97ce96adc5ab4f04230c1270e1162e7a270", // CRWDon, Equity.US.CRWD/USD
    "0xad04597ba688c350a97265fcb60585d6a80ebd37e147b817c94f101a32e58b4c", // CATon, Equity.US.CAT/USD
    "0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554", // GSon, Equity.US.GS/USD
    "0x31cc7558642dc348a3e2894146a998031438de8ccc56b7af2171bcd5e5d83eda", // ANETon, Equity.US.ANET/USD
    "0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2", // NFLXon, Equity.US.NFLX/USD
    "0x67ac585d05128c7b6a88660be04acd18b2bddd6308e98b71b9f3ba0f0e781296", // WFCon, Equity.US.WFC/USD
    "0x0ee2e3f1c7689e1abf957009f747228a30b47678c8e5844cb033cbcf790fa20b", // SAPon, Equity.US.SAP/USD
    "0x10946973bfcc936b423d52ee2c5a538d96427626fe6d1a7dae14b1c401d1e794", // AMGNon, Equity.US.AMGN/USD
    "0x9146c5c900d9aea9579819cf50d1ae18b54dea58eea3c9a198102e4e458e652b", // LINon, Equity.US.LIN/USD
    "0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef", // IBMon, Equity.US.IBM/USD
    "0xe18423cdff0e892a5338bad2047550d21ceb7f3c13ba6dfa6911c63326451c44", // BABAon, Equity.Index.BABA/USD
    "0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710", // AXPon, Equity.US.AXP/USD
    "0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0", // DISon, Equity.US.DIS/USD
    "0x57e28b0f0ab18923f5c987629c0c714b9b46c87e729ed95ed6e23e466e8d1e0c", // GEVon, Equity.US.GEV/USD
    "0xa2950270a22ce39a22cb3488ba91e60474cd93c6d01da2ecc5a97c1dd40f4995", // DELLon, Equity.US.DELL/USD
    "0x957bf692b35cc62f222dbf4dc6929130df42fe17c9f03373f44c01f78b05391e", // ARMon, Equity.US.ARM/USD
    "0xe7e7aac1ac0524cd3666fae4ecafae5e1fee880c11f3a7b4b7ea61bd6e434a63", // Con, Equity.US.C/USD
    "0xd0723436221cd8ca5f2f11c38920271d77950e7ed0cec1a764459b465cb88651", // APHon, Equity.US.APH/USD
    "0xd3178156b7c0f6ce10d6da7d347952a672467b51708baaf1a57ffe1fb005824a", // MCDon, Equity.US.MCD/USD
    "0x9c27675f282bfe54b5d0a7b187b29b09184d32d4462de7e3060629c7b8895aad", // KLACon, Equity.US.KLAC/USD
    "0xbe230eddb16aad5ad273a85e581e74eb615ebf67d378f885768d9b047df0c843", // PEPon, Equity.US.PEP/USD
    "0x1105e1af4587e6555349533492904782f6a4d0dc6b828938e98e1715b6b32315", // VTVon, Equity.US.VTV/USD
    "0x6672325a220c0ee1166add709d5ba2e51c185888360c01edc76293257ef68b58", // VZon, Equity.US.VZ/USD
    "0xa388977cbd7b063e456a31267919d86395af058a7558e892dde3c6b38c6240bb", // ADIon, Equity.US.ADI/USD
    "0x3e959410e8daa7941a4d2179332a3ab1d38e78dd8d83134996e65a3f4352f828", // IEFAon, Equity.US.IEFA/USD
    "0x4aac40f432e039ab06236eb9bd3c58347f953d8f05b29aaac295b99cc47ee429", // ABTon, Equity.US.ABT/USD
    "0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08", // BLKon, Equity.US.BLK/USD
    "0x54350ebf587c3f14857efcfec50e5c4f6e10220770c2266e9fe85bd5e42e4022", // QCOMon, Equity.US.QCOM/USD
    "0xc9034e8c405ba92888887bc76962b619d0f8e8bf3e12aba972af0cf64e814d5d", // SHOPon, Equity.US.SHOP/USD
    "0xb058f7874b57f820aa7ff6034a8515add8095b5831e83fc8d02c1dccd4ac099c", // NEEon, Equity.US.NEE/USD
    "0xb095647f688415d4102a858e1b25c1af15750f0e516a0d561cb35ebe30deb183", // UNPon, Equity.US.UNP/USD
    "0x8dde322496e031d942b9eee8ca769d618cd2e69b18196644369379f5a1e7c23d", // NVOon, Equity.US.NVO/USD
    "0x0b231ca4307d25e4600067bfb06f576474bcabd74fb50eeaa0906ac1b457f365", // TMUSon, Equity.US.TMUS/USD
    "0xc2d23f236142a519929b147c4dbe8720475724918c8b8473db0283f8cf044184", // DEon, Equity.US.DE/USD
    "0xd437b2f1470d5f007f18a5565eaab1ed182d97204d80b7dd3dac29839f61c9e6", // SCHWon, Equity.US.SCHW/USD
    "0xd54d8d4e3774ea53660e660ecd03aa9daa31eed9b7e67d1a2aed3095b3e6720d", // COPon, Equity.US.COP/USD
    "0x0704ad7547b3dfee329266ee53276349d48e4587cb08264a2818288f356efd1d", // PFEon, Equity.US.PFE/USD
    "0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8", // CRMon, Equity.US.CRM/USD
    "0xad4dc1db82c47e0822afef9d9eca7bf693cdad20dd61fcd5aa1b6895b1b90190", // ISRGon, Equity.US.ISRG/USD
    "0x66e2456d8f7fae8b1421538b10c868b89a6e23b727f290ac062cc6809c96ea9a", // AGGon, Equity.US.AGG/USD
    "0x96b1207c795f31283f5e44c527a1db18cacfb68de745a0de326611b0b5af3fc3", // IEMGon, Equity.US.IEMG/USD
    "0xc04665f62a0eabf427a834bb5da5f27773ef7422e462d40c7468ef3e4d39d8f1", // UBERon, Equity.US.UBER/USD
    "0xac9de86ae3dcff03514bde733f5793f1446b2cd31f1539a1c449acc3e76cacc1", // VRTXon, Equity.US.VRTX/USD
    "0x880d96a272d5ccbb3cd6f6aacb881a996cb4976b3f252b58c595cd2a418b6ea9", // LMTon, Equity.US.LMT/USD
    "0x84cabacd3323b6e9accca97366beea9fc21260e6c0b7830848e9e1259bc5cef2", // MRVLon, Equity.Index.MRVL/USD
    "0xb1cf984febc32fbd98f0c5d31fed29d050d56a272406bae9de64dd94ba7e5e1e", // ETNon, Equity.US.ETN/USD
    "0x68848984b74a7766ad23cdccd8e78e9ef339dcfb86b7e96990f27447c20967ed", // ACNon, Equity.US.ACN/USD
    "0xe7268062e142570f97cfba327f14e3153d1d4d8f6a4f84e59b72940ee87ecdb9", // SPGIon, Equity.US.SPGI/USD
    "0x54f128939505878cf4412abc5a533255ce07e85833849170deb67deff0533aa7", // APPon, Equity.US.APP/USD
    "0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae", // BAon, Equity.US.BA/USD
    "0x0b7fc35cea4acfa65e49a718292e0b31b453072e3af39afbfd2925da5c3ab65d", // STXon, Equity.US.STX/USD
    "0xa00be224b07426d688475926b6a7a8b007f1420734629b596ae6132c75bc5976", // SCCOon, Equity.US.SCCO/USD
    "0xae69f62081eb15ae4f077397871a1cf29cacf75e7b1db740aed9074c1efd3fa4", // PDDon, Equity.US.PDD/USD
    "0xe190f467043db04548200354889dfe0d9d314c08b8d4e62fabf4d5a3140fecca", // GLDon, Equity.US.GLD/USD
    "0xab31ec9dbcacacfb26e5ea6c249d69f5ae8b9c691aac6ccc5919b6107efa1c3a", // LOWon, Equity.US.LOW/USD
    "0x547ef6a2ea7db9baf50788876d3c062facaecfc896d898f37ba12efd0a13383a", // SPOTon, Equity.US.SPOT/USD
    "0x86cd9abb315081b136afc72829058cf3aaf1100d4650acb2edb6a8e39f03ef75", // SBUXon, Equity.US.SBUX/USD
    "0xab4b0a2fad7f23125a7a94eec46204fcf1ba69bb81d32778db0ba3e66df6772a", // IJHon, Equity.US.IJH/USD
    "0x8d6a29bb5ed522931d711bb12c4bbf92af986936e52af582032913b5ffcbf4d5", // SGOVon, Equity.US.SGOV/USD
    "0x37a782cf9bb6061d4cca34a419fb1ae5a8edf71ae8843206ea88b4ba696d4706", // WDCon, Equity.US.WDC/USD
    "0x9a972ccd0df577006dda1679dc39e00f370e330c318f21bdcb34e83fa5a70002", // SNDKon, Equity.Index.SNDK/USD
    "0xefc46125a2063f8662815a3c5d78f20aa0c4e6dde0862364a6f5d2f47d862ac1", // IWFon, Equity.US.IWF/USD
    "0xd3a9e76862950b2f21a7037fd64df913794b14d0e2938a9d383b0b7387ca0081", // NETon, Equity.US.NET/USD
    "0x857c3a552953250d5b19db7341f3deaed12ff623f2db451e30581c266b23ab58", // COFon, Equity.US.COF/USD
    "0x650293cd51d63cac28ecb03823af05d8192dad724156af6ed4a90b1708057bf2", // SOon, Equity.US.SO/USD
    "0x146f8290eb9b56e6e19338902f7b975e7f9e50f9fe40b35a127c6ee7992f5102", // PBRon, Equity.US.PBR/USD
    "0x29caf4d900d3080e56306ac41a9856735b89cb4df6813dd7b83e9eb96c04700d", // NEMon, Equity.US.NEM/USD
    "0xccab508da0999d36e1ac429391d67b3ac5abf1900978ea1a56dab6b1b932168e", // ABNBon, Equity.US.ABNB/USD
    "0x5ede535f959e6184f24815c1d7819ab8bf79d850afbd73151bc994e1935de686", // ENBon, Equity.US.ENB/USD
    "0x66eb6cfa3a28e8e7cad538a55872ac0e41a2741ca66a29c1dc5540f2b1fb6fb6", // EQIXon, Equity.US.EQIX/USD
    "0x14291d2651ecf1f9105729bdc59553c1ce73fb3d6c931dd98a9d2adddc37e00f", // SNOWon, Equity.US.SNOW/USD
    "0x2a45d16204f3588259fddf5a81a1129efab873571a4cef38641e16bfeac364ef", // REGNon, Equity.US.REGN/USD
    "0x69d2eebcc3c62889f1c0105ff347f296eb435cba8d2e4705a486fd47a8fe1a1b", // NOWon, Equity.US.NOW/USD
    "0x6ef62b860055ef6819af274064e5aa597aa9d0963ce3109c51d996264844776e", // GLWon, Equity.US.GLW/USD
    "0x7f78c101ca799a5b63f5e5c1e56a43b3a361233900160c172e2ec2980e91b4eb", // WMon, Equity.US.WM/USD
    "0x894e9c429f83fe4f35fda679568348418bafe5a0a68e1cccc8e51a137e879ce9", // GDon, Equity.US.GD/USD
    "0xde7279ce7d805c43c4893239b77aa07525df93c9f8ede0bd8b3d87609dd80415", // ITOTon, Equity.US.ITOT/USD
    "0xa541bc5c4b69961442e45e9198c7cce151ff9c2a1003f620c6d4a9785c77a4d9", // CEGon, Equity.US.CEG/USD
    "0xa189b9eee6d023e3b79a726804aeb748d54e52cf6ebcebe0f7d5c8dae4988357", // PWRon, Equity.US.PWR/USD
    "0x0c9385e9109703f9cef4872dc1d6abaa7a630c1b524757141f79d42159768307", // TTon, Equity.US.TT/USD
    "0xe1c0e5aaf1842d3efb806d14a7cd21160d4b7c0f96746e0fa1227ae961bf3929", // EMRon, Equity.US.EMR/USD
    "0xdf82dc88ea742bb42bdb845e5fc3ca4eef2354c67357d338221e8a696891b4ca", // ADBEon, Equity.US.ADBE/USD
    "0x43ef64ff6af44e0648f0328ee56e88fee57943b0aa077c24ef175bb9ecd37133", // INTUon, Equity.US.INTU/USD
    "0x6921035babdc51587962f9a1350a2c2ca5840b64bbf9057ab75a20cc663b32c3", // WMBon, Equity.US.WMB/USD
    "0x8cbd009149f28a8f19d01de7f31d85d48c7f2d35a9ae40c03930712d84fbd92a", // CVNAon, Equity.US.CVNA/USD
    "0x4083b0b1471123cf4d3e8edee7890940cafad866f06cadae638c23e555a1f4fc", // MRNAon, Equity.US.MRNA/USD
    "0x5f848f61c44e1c9b21ddac0fcac5536344e80ad21df3271c2f069f57229fab81", // NOCon, Equity.US.NOC/USD
    "0x84dad6b760396a7904d04a3d83039a3fc18f10819fd97d023ac5535997d70108", // VRTon, Equity.US.VRT/USD
    "0x3b7ef6c95ceedbffbb66bff3d6135a200c5d0a0466b0c90812510ceaedebaf04", // EFAon, Equity.US.EFA/USD
    "0xeff690a187797aa225723345d4612abec0bf0cec1ae62347c0e7b1905d730879", // IWMon, Equity.US.IWM/USD
    "0x2b5735ead9b057b3fb96a422740ab26bdfcb1f2b5d4cd9d052f45311ef0f2952", // FCXon, Equity.US.FCX/USD
    "0x8042b087e06b64b7a40056782d48c8add189943d8354c56726e655f46e65320f", // SLBon, Equity.US.SLB/USD
    "0xaf9f76555c0147ec660100ff1639eb128e48c4f16b0aec229b736c04e082de23", // DASHon, Equity.US.DASH/USD
    "0x40176a5dd12a53bb1f31e848c9363863dd6f8e755f35ef56d2182fc7f1d03853", // APOon, Equity.US.APO/USD
    "0x5c149158ad0cca240ab13e45d93f43d7eb747a25acf5a9313b5b03c0aa87251b", // MELIon, Equity.US.MELI/USD
    "0x63e9f918ab91507c3574cca011da4dccda30cf54d46124d03b70279142ff81f3", // Ton (AT&T), Equity.US.T/USD
    "0xb10d624c07226d795e9211c9ac95baf43b4a4234ac89cd319e3c72b20de92f99", // LIon, Equity.US.LI/USD
    "0x664fc65e3f9ffb458e7144959ed8d5c86e923eb7ca283efeadb79bd6c1e4b9ce", // NTESon, Equity.US.NTES/USD
    "0x069b87074893c37fd250990df7409d7e19cd649bea8e28904a0fd49915f4e53a", // HPEon, Equity.US.HPE/USD
    "0x5cbf183213af0c63f896b908770e684cb0dfb6634e42bd6e8ea7b273eb61a342", // TELon, Equity.US.TEL/USD
    "0x7e535de06269b98ea0dfd8b238b80254a41be0092acf72c4464b269cd500716e", // NUEon, Equity.US.NUE/USD
    "0xf703fbded84f7da4bd9ff4661b5d1ffefa8a9c90b7fa12f247edc8251efac914", // IAUon, Equity.US.IAU/USD
    "0x79adceba85771f08b71af57b027e0cf98a040738bca2a70ed3f89736a718f77c", // AMEon, Equity.US.AME/USD
    "0x54ba7b095dfa286f556cd41d4bfefe956ebd4df3d9eec8fe0188d0727f07e344", // OXYon, Equity.US.OXY/USD
    "0xa955f59cec6006d55ac21ab009c92662f2d9250bc22b86fcce16e7962c129c4f", // BEon, Equity.US.BE/USD
    "0x67649450b4ca4bfff97cbaf96d2fd9e40f6db148cb65999140154415e4378e14", // NKEon, Equity.US.NKE/USD
    "0xfd7141d35093fb93e84d82507cc6a97775fe263bd8ecd8b7e2b940a6ae487979", // LITEon, Equity.US.LITE/USD
    "0x0a89d9c67435e8563fbf1bd1d3da9578fd07edfc2af55e92acf532cc9951a90a", // KEYSon, Equity.US.KEYS/USD
    "0x9db6bc1e6e9e5e60f6884e1cd8e4399cca9d0454c6e7234ad79680cf139748f5", // IBITon, Equity.US.IBIT/USD
    "0x6050efb3d94369697e5cdebf4b7a14f0f503bf8cd880e24ef85f9fbc0a68feb2", // BILon, Equity.US.BIL/USD
    "0x773c3b11f6be58e8151966a9f5832696d8cd08884ccc43ac8965a7ebea911533", // PYPLon, Equity.US.PYPL/USD
    "0x9f383d612ac09c7e6ffda24deca1502fce72e0ba58ff473fea411d9727401cc1", // TLTon, Equity.US.TLT/USD
    "0x6d64b1981512c242162d6ba54f6bda35c59f726f2e075a42994fc9a33c6c2d55", // XYZon, Equity.US.XYZ/USD
    "0xc1046358a2b78d92a2ad45b9d3c271350ab9335b478df21a390b8924cad91563", // CMGon, Equity.US.CMG/USD
    "0x6c267962d46cec4a5baf6105de67ef08e1306f75973ce6eb8db8527f06e28f33", // Fon, Equity.US.F/USD
    "0xfae9f16801d1249999bf7a9e6e57ae7b512f88cce663251da2dee9fadddfc31a", // COHRon, Equity.US.COHR/USD
    "0xff1717bc1de364c8473f9c1928dad930a9ecc952d91f26133a7f94eb03166316", // NOKon, Equity.US.NOK/USD
    "0xb21a229944b7008c9e0efeb591030198acd5a676e7c84c3a13927af9764456b0", // NTRAon, Equity.US.NTRA/USD
    "0x034626d18bc711c55c71e27319f8851f483bc08a7f97be2dee9ea8f7ccd59248", // IEFon, Equity.US.IEF/USD
    "0x665d46c8142ca4486ebcdcfc0bbb913dee5255e0be63b6f971933620a7f69045", // VSTon, Equity.US.VST/USD
    "0xc531c5d85ae89ad23e0f455be0a9170e2924a4b6922d62d5b1e076023f7b7235", // ROKon, Equity.US.ROK/USD
    "0x3c3973e95c24fab3808a8fd9f25fb06ee92422fea20d814c1a850b307cbf31b9", // SOXXon, Equity.US.SOXX/USD
    "0x14aed40d5a17de04d65a0a54e956f6bce322122e621d8278300331ab02deb6e7", // DYNFon, Equity.US.DYNF/USD
    "0x46a20d321a432ff821d19bc459c7c6170efef48cb8244dff075d63c90e551481", // STMon, Equity.US.STM/USD
    "0x782a6a261306f01ab2ad004062a2832107360eefdcf8c83223e0ff7ca7ebde8d", // TTWOon, Equity.US.TTWO/USD
    "0xa1227a13d6b81354acdff9ae22a1878ee0dcdc2668e0a3f8c15700ddf5d50fbb", // CIENon, Equity.US.CIEN/USD
    "0xa2c896238e03d8126369b445ed0157a9cfaccf095510a68b9100beb8885c0e47", // ALABon, Equity.US.ALAB/USD
    "0x1feb5bc35d3a601d1e39c4d1dd65de285a04f5e7923fdaba1d87359d8c14a9ae", // VNQon, Equity.US.VNQ/USD
    "0x58ab181e7512766728d2cc3581839bbb913e6cd24457ba422cbe2a33df64416e", // TERon, Equity.US.TER/USD
    "0x40589e289317e4fbd997b1a267606e20a1cc7c3e4689f9e5a5992957917816c8", // RKLBon, Equity.US.RKLB/USD
    "0x63d83a9822f1098d7ff7eddc94a156b4e45d6fb43cbcbd1030dd0262ad0fea3d", // UMCon, Equity.US.UMC/USD
    "0x4c45e26d5253283ab4736b4f4ba9d0e6517679f8425ef07722dacc4b6da90750", // JDon, Equity.US.JD/USD
    "0x01ce9758cabc32e7344032cc921433cdf194a31c2e4b11e42d6fc3217cc94871", // JAAAon, Equity.US.JAAA/USD
    "0x5b1adfefbe3f69cf8c5dc02d521a9f49eb5887d19f4bf1f4170959428d9d6a21", // CLSon, Equity.US.CLS/USD
    "0x3bc436e6c024059b3493e4332b32d0cbdd2b8ecf84544261838137eb1f299525", // STLDon, Equity.US.STLD/USD
    "0xad81a87631f8ab7f09897d7001e46e206afa727c419d93f31591a8edefdf37cb", // EQTon, Equity.US.EQT/USD
    "0xc8d8050cde18920d0274f296a7589620c67a9898a73c93d0a91fddde6f3cdf6b", // NBISon, Equity.Index.NBIS/USD
    "0x48a9a69fa2947734f12d1840c51d36fc30be106fc40c624054faec9783463831", // INSMon, Equity.US.INSM/USD
    "0x026e4a35b33c438e4c75b2bf8f5f8298b26165eff133b1da2b4559985ecab11e", // PCGon, Equity.US.PCG/USD
    "0x5aa9f82dc2e0f5f8271fd163e980010101517da59f4b72b71c7056a5950b2f9d", // TQQQon, Equity.US.TQQQ/USD
    "0x21fff87cf866f73c13887a254ec2395e178967fcc8c6a5a6471c26392119c82d", // EFVon, Equity.US.EFV/USD
    "0x68799c6196bad6e233c747cfa4a92897a88375268b406a81ca47df277e839d50", // FLEXon, Equity.US.FLEX/USD
    "0xa48b0216da455c8f33edc75d5c82290f63180a41646df873b393450bb3218c0c", // SHYon, Equity.US.SHY/USD
    "0xc7ae3c077945639c2e0ed7199d1e6655f8c76027e07bccea53d9b6f79d8075fd", // VRSNon, Equity.US.VRSN/USD
    "0x8c92b96bf7ec66766d7400f91eee36370df38ec751ec48933396760f8c73cc78", // CCJon, Equity.US.CCJ/USD
    "0x2a78b78189d6d6eff30a825e4698fd14a0b1ca659bb0079bb7e80521c0e8c75d", // CRWVon, Equity.US.CRWV/USD
    "0x37527d726792538d5b968b8d5777044cda4413f7814e24978d9a3a9094157c2b", // TCOMon, Equity.US.TCOM/USD
    "0xd407e68cec58205be82a6140a668dc42f8d9079bcf3be4aa4b41f41f7b983035", // EEMon, Equity.US.EEM/USD
    "0x35f08f92f05ab4fd2117f8d857238f5eb25213fefe95e7ba042babea512a0a5b", // ONon, Equity.US.ON/USD
    "0x8ecca7012d5cd82620c1222acd6296cb4a34fea7dae4bf93bc51ddc471830a53", // HALon, Equity.US.HAL/USD
    "0x5557d206aa0dd037fc082f03bbd78653f01465d280ea930bc93251f0eb60c707", // CPNGon, Equity.US.CPNG/USD
    "0xd8226a5920c7fbfe9bf9b159ab25855fb07c66b28c0941c1d36b247e382add95", // JBLon, Equity.US.JBL/USD
    "0x9bdee8cb689424d01f6eaf7217adfcff65b51a30774a77fff8006c21c7059350", // BIDUon, Equity.US.BIDU/USD
    "0x70223a069575a95493bd4a473c47554ac8b333af557e2264eb0d0236e2838fc2", // CRDOon, Equity.US.CRDO/USD
    "0x7b6809a00a53228f74622e4909750c0d86a2081032955e02c8e3503b1b93829a", // CBRSon, Equity.US.CBRS/USD
    "0x6fc08c9963d266069cbd9780d98383dabf2668322a5bef0b9491e11d67e5d7e7", // SLVon, Equity.US.SLV/USD
    "0x492f2b794efb3721b4243406d73cf68f34097b103ba690d0dbcafddb5a10cb7e", // HUBBon, Equity.US.HUBB/USD
    "0xb4279985dec1ff91bc9bd6d8b44ed96da6f0446cfca6bc613d23296182f4fdcf", // IYWon, Equity.US.IYW/USD
    "0x73560d1ee6daf7f322314d58dd8d0eed720fffcab390c1c1d54b5088d92497a2", // EWJon, Equity.US.EWJ/USD
    "0x8cbec525dd085e025e7a4cb0fa5041a9db203ff0ed5919d9f14e61fff8bfe062", // GFSon, Equity.US.GFS/USD
    "0xe552acc27d7d790ea13d79a37a1da3e9bdf52630f3056a97a15660653f3f50f7", // ENTGon, Equity.US.ENTG/USD
    "0x98b3bc80a9e8ea755e29ef29575c3de9d5ae8213450c66e8f0759d5a7c0d8aad", // USFRon, Equity.US.USFR/USD
    "0x2a7acae7e6da804f5857d10040693e42fb345203a974fff725caa1f0b1998357", // EWYon, Equity.Index.EWY/USD
    "0x431349b17e1ee2605695615baffd31e44290477089c02536bb2926dfa36850b8", // SWKSon, Equity.US.SWKS/USD
    "0x72fae0e0683c186f5ce9444afac9909cf5d60b499f4f9569dd75442f19c625c8", // SOFIon, Equity.US.SOFI/USD
    "0x2077043ee3b67b9a70949c8396c110f6cf43de8e6d9e6efdcbd557a152cf2c6e", // HYGon, Equity.US.HYG/USD
    "0x20bae488aba426a5825ce76b2be9706787ffcdd685d5e1b1778acb0d3db1664f", // NVTon, Equity.US.NVT/USD
    "0xc0ece6b9254797f4384bda1ba3f2c33259f552c7849a86b3029e811be5ea9227", // RDDTon, Equity.US.RDDT/USD
    "0x6d1085fb5e5bd8f830a47d6d2cf38af3ed0415e208a5d8f717b01d1674b89bea", // MTSIon, Equity.US.MTSI/USD
    "0x1e59e3164331ce560683eae0c69efe9650ff1bc834225772ddb330aa808f72f0", // RIVNon, Equity.US.RIVN/USD
    "0x134837b42e99cde7e5b85cc795dd06a658326098c35bd298274763619b577121", // LSCCon, Equity.US.LSCC/USD
    "0x8f34132a42f8bb7a47568d77a910f97174a30719e16904e9f2915d5b2c6c2d52", // SMCIon, Equity.US.SMCI/USD
    "0x05ff869230bb56bf2df26342880f6a2b9cab2f2eb4c1b59f00ec38e405d65db0", // TLNon, Equity.US.TLN/USD
    "0xab550fd8d8635e32090a5ed31d7e4fd182df26e479cfa679ac31e8b9578cad3b", // WCCon, Equity.US.WCC/USD
    "0xcf3f93bef4432759b7e0224e33604df001963c8660a64551dbd90fd38c3a6a9c", // TSEMon, Equity.US.TSEM/USD
    "0xa08f897997f4223014aea76709b4236f2d89c132e6f45373ed65e029805cd9fc", // LECOon, Equity.US.LECO/USD
    "0x43c438c61f1500581a1f05b5932548c9d8b7881e69d49b4b931e89d960af0601", // MKSIon, Equity.US.MKSI/USD
    "0x8acba411efb415896ba97afbb6995385ab25e7056422f239c9e513f1acfc9aca", // TIPon, Equity.US.TIP/USD
    "0x82d6544c7729f245a15798f5abdc407cebf1fd93bfcc811a76b26873a47fe004", // MTZon, Equity.US.MTZ/USD
    "0xa8b8aec1b1b1e492b14570d24fe63fcd98aec1a648570c4543afa286eca4dc3e", // IWNon, Equity.US.IWN/USD
    "0xd54eccd2ce6b1fa72125abe1f88866470320fa44960fa1d1cf8761f9cfca8def", // GMEon, Equity.Index.GME/USD
    "0x5b4183fbbab47c0508c39db436e6b0a0376e50650e79c9f836677a04d65d592f", // SOXLon, Equity.Index.SOXL/USD
    "0x4c2e4cf5dc8426f6e54d0de8020d2a7e9b6754b7089bd71a75cf6b3da46e747e", // PAVEon, Equity.US.PAVE/USD
    "0xe6d51d83a2d18919bf5c57604bf3bf581d65efe34d232ba1d0ef33eca03c983f", // FUTUon, Equity.US.FUTU/USD
    "0x43b0e3663be6fe9e5f098eb3b2826f053d182682944717cb0f8c57b04db90867", // IGVon, Equity.US.IGV/USD
    "0xbe0e2b42aa0859682609decb790cd51832700fef549f59b5eb595221b6c3833c", // GRABon, Equity.US.GRAB/USD
    "0x27514c8e57a0fad5e095546852c0903319b66ab07f7526b5ac1540886d6d944e", // GNRCon, Equity.US.GNRC/USD
    "0x2132dbe12a6d7520b29553bafb7c81c178bcc7583112dec25aacfcac99b9049f", // FNon, Equity.US.FN/USD
    "0x79f7f0b79a6b7fdc0d7d9e8b6337fd709b8eea9dc6f57b6174c84816cae88bfd", // ITAon, Equity.US.ITA/USD
    "0x659c675091db659251f2077293bf9e71aef2c978dd729c2be66cec0d41c1d671", // HIIon, Equity.US.HII/USD
    "0x6af68a227de372e5d19183679911e468e06d85c013f56c376a78a4d942f8f269", // IONQon, Equity.US.IONQ/USD
    "0x4db91e379e36addcdb1cc75dcb03022bd95d5d95148c41d268348d12cbd27c18", // ALBon, Equity.US.ALB/USD
    "0xc4db80e9a68aca4575714c9f5387368239d63965850a359b68b676355a799d7d", // ONTOon, Equity.US.ONTO/USD
    "0x05b0a4d52786320f28d1389ed8f236c3eca5854376431cfdf7ce37b6326402d2", // PINSon, Equity.US.PINS/USD
    "0x3e707ff33b5d0e1491423de340a4d15151d9a94f260eab441a88481dd3fcc4a4", // NVMIon, Equity.US.NVMI/USD
    "0x54e2e127c93950de5a710100fd1cd387aba1ec8920850efdb05da5fee57d2e32", // BMNRon, Equity.US.BMNR/USD
    "0xa23dd397c4f7a2187d00c1973e58ff6e8a681658b1105d1bd42a8fccbbd068f7", // SNAPon, Equity.US.SNAP/USD
    "0xe6af4d828b88cd3b40cb34686e61157d3fa37c1aa20ca2b99453aae62619b351", // FIGon, Equity.US.FIG/USD
    "0x0e55d7b951e87860cf6188aea1626dc8dafb0d37ab716f815677bd5188d3a5b7", // AIQon, Equity.US.AIQ/USD
    "0xf8208ffb5822c912f596ac3df95514222eb1adaa0dd341408b41fed15821c414", // AMKRon, Equity.US.AMKR/USD
    "0xd5399c95ddc3219ab8b03bd51ca81560bc92a648950bf964eef67bfd9783654a", // AALon, Equity.US.AAL/USD
    "0x97100fdc597c8a56b5ed629c0b66dc4409c5839778e5c494c3a1d58081364f7b", // RMBSon, Equity.US.RMBS/USD
    "0x4af609fcabd2fc48ac3c17232d00dc6ecf8e6ca7f6561976826174c19240f0cc", // OSCRon, Equity.US.OSCR/USD
    "0x9721a76ee064f0f569cb19219c82de4278f033fb659abb1739c9008b6f66b64e", // TWSTon, Equity.US.TWST/USD
    "0x9fe0d98811d27c1f484d140a22b2a2cca6280d8ffb63a5c899432ff68293737b", // EWZon, Equity.Index.EWZ/USD
    "0x17f979e1f6b7c429e4b9ecee96633dbecdc5378566ddfd3d220b0ef8d874e4bd", // ASTSon, Equity.US.ASTS/USD
    "0x91d942b363c77592a40d4590a96283e9ad95c55ec40a06f57d9a840229786715", // AURon, Equity.US.AUR/USD
    "0xf645c9aa24431545d435746258771dde072dd9d63f71f876b9d2c4d0eb573f84", // TTMIon, Equity.US.TTMI/USD
    "0xfb88ad7526f97f7ca6f43aaa7d3b620f412968db2cbcfac1e906362def8456f3", // HUTon, Equity.US.HUT/USD
    "0x872c1525e06d841dab75d710af2b34feebb5a3547466ff712a655b52fcbe5d3c", // VICRon, Equity.US.VICR/USD
    "0x207d13ab09f413c8855f5c14b7650a2235f37c60eb6274b8a3eb80c2b85fb81c", // INDAon, Equity.US.INDA/USD
    "0x8f3a268ae8d3f99160d889c0ad05c5ccf926a67aa86ce530e76e82454e8b31c7", // CLFon, Equity.US.CLF/USD
    "0xc8916a12ca17ed0883e37a10c8962370fbd2878a35bb70f6902a0f52be73338c", // NIOon, Equity.US.NIO/USD
    "0x46417522a59b245c5af35c33c13426d991b36514c4c85aaefe1cf787e7daad90", // RIOTon, Equity.US.RIOT/USD
    "0x92e03dac647ec6733f61f208a89115ecee4442653736a66008032f4ae588f304", // MPon, Equity.US.MP/USD
    "0x0e7569b870edec883f44b54ba4a63cb50bece2704a215448cadad7913ce5e1d6", // FORMon, Equity.US.FORM/USD
    "0xba20f6d5532c07da494da803db2523719d339226e69ade6436e7d2f1047138a5", // IRENon, Equity.US.IREN/USD
    "0x7717b73c7f19ffb1e6e5da542836fa3464559ec971df475455471433a005e2a6", // WULFon, Equity.US.WULF/USD
    "0xa98d4a82473c0a85d2416c185df4845ef8b1e7ed8606717ad1c4485c7a1b2840", // FPSon, Equity.US.FPS/USD
    "0xed3eb3353fd34a90ee3613defda80c11ae2b58c04ddcfd4ff351c3c66e9629b3", // FIGRon, Equity.US.FIGR/USD
    "0xdd3857f9265d3be5cecd44d80aca8e1e9c55a9127c971eb6ceac5e80a8ff8fea", // POWLon, Equity.US.POWL/USD
    "0x6b971ce35cfc0f144200bf5aa184863af1522312fad078fc6d5b7743501eae51", // SHLDon, Equity.US.SHLD/USD
    "0x7f50344390e79dc231fc08c3789b2e332bdd344751bc18842ac53f953f44d7f2", // AGon, Equity.US.AG/USD
    "0x4de569a337968a84a8447e579aad7c4eef9be8106dfd8e807756bb19724c0650", // CAIon, Equity.US.CAI/USD
    "0x188bdefa94c2f8b3878ebcd98f65551dbc2091f250ae6780719184821b1a0e1c", // ETHAon, Equity.US.ETHA/USD
    "0x8bbaca50510ba7108093fd89100523a01d4eee8087de21c9ca807292933e5479", // COPXon, Equity.US.COPX/USD
    "0x214fc87a8f0f5adc797fc1f7927e1040650366e8f943e20caf13ad0d6e806956", // CORZon, Equity.US.CORZ/USD
    "0x006d336e4cd222530a057ed307c619af1379a4dedfc4839dcbab413df956fbaa", // BILIon, Equity.US.BILI/USD
    "0xbff80b6f6e2e1ec46691a50f83d61aba1b8fa4ce59567a80ae6a0ec7e1769d55", // MXLon, Equity.US.MXL/USD
    "0x7fc1e64946aff450748e8f60644d052ae787e5708dc48c6c73c546ee94218cc3", // APLDon, Equity.US.APLD/USD
    "0x562e632de00dd4ad4a70b024afc3e2a220c1b05116d58cf96089825303f94762", // PLon, Equity.US.PL/USD
    "0x8a11c9ba1c8a59571188ff14ca1cc096520eae277de4ff8bc5a6b58939efb096", // KWEBon, Equity.US.KWEB/USD
    "0x0d283a095e94dff4d4e607614ed686eb53e548238fb3af231148c276ecefe83e", // OKLOon, Equity.US.OKLO/USD
    "0xc22a2dd9ebde1ca2658926fc2579e9e4086c14cb63c789337c86295f09e68de5", // URAon, Equity.US.URA/USD
    "0x1062b0f61c3bbf6bdb79120e6a8826d36c1f3f8b0bc1990804e53770d38c3ca2", // VSHon, Equity.US.VSH/USD
    "0xe1ec83d83a2e0eb8c0b8c4a505264785ee6676473452697a03f2322c73879bcf", // HIMSon, Equity.Index.HIMS/USD
    "0xff68be691d07c6513247fd4e93a6d52b31e0ef7e4899acc43e59cb5c95b3fa76", // AAOIon, Equity.US.AAOI/USD
    "0x978c107498c949190c0b9bb1ad408eb643b7317ad43539ff43897cab967d7fd3", // FXIon, Equity.US.FXI/USD
    "0xdf2a490455eb1f5ae07ea6a58c16218648d5c4b9c29e1a18ad6942fb48f3d946", // PRIMon, Equity.US.PRIM/USD
    "0x55a91bd14858a0039cb21d56ac87bd796fb257a78786d3a81d64e8dff2373af3", // CIFRon, Equity.US.CIFR/USD
    "0x5ec583659f690a921cd7a5be9dd2730d67b2541528ca5b1ff99df3e5d44bbedb", // ENPHon, Equity.US.ENPH/USD
    "0xdf68956522c14482f38841a1105220f9e32c35e48a3fd517cc955a4580ab1cae", // BLSHon, Equity.US.BLSH/USD
    "0x517ad3e4bd0c7851b9526172474625575529328c330d558df03a336d5ec6c082", // QBTSon, Equity.US.QBTS/USD
    "0xb913007c5d32d88a882832b16dfb8a93665ff52e6da2c02d94b6eee717b97941", // UECon, Equity.US.UEC/USD
    "0x20aead6dcd4da8321806ce377107952863632fb25f43ec03c36ffd575ac7e708", // RGTIon, Equity.US.RGTI/USD
    "0x38e8dd9b74943ce63b08b4b3f897f128ece558ea61cd7e00c9c77a6d64cd8265", // BOTZon, Equity.US.BOTZ/USD
    "0xe35e3fa2164c7b0ef15d904c231939e799ee683437ca0aa362133bafaf540ae6", // PENGon, Equity.US.PENG/USD
    "0x2373578c1c42c6a46f39e1cd7c5e37204b9394027415333891d2cb85ca842041", // ONDSon, Equity.US.ONDS/USD
    "0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1", // AMCon, Equity.US.AMC/USD
    "0x1bf5216f1a4ec4beb87e22110dbca2a62825bb1216d24a17e913164e4f8ec602", // USARon, Equity.US.USAR/USD
    "0x916f99d33c702bb925e90d86452bed7a3d1fee416030ccc284f142f5fc25f112", // SOXQon, Equity.US.SOXQ/USD
    "0xca320d73da49ed89083480db02fbe5cd352d8bd98c9c7310336c82c32f9dbbd6", // GRNDon, Equity.US.GRND/USD
    "0x641c99f709570911f4ce41237b56092ae86b792e7dcce15317fb3175e81f8eb9", // ACHRon, Equity.US.ACHR/USD
    "0x0fc2ad77a9ab75bcbc3ebd7a9ff60facd08c517309e2d684baa979c910a0e43e", // MARAon, Equity.US.MARA/USD
    "0x67e031d1723e5c89e4a826d80b2f3b41a91b05ef6122d523b8829a02e0f563aa", // GLXYon, Equity.US.GLXY/USD
    "0x56b6d6619fbd0b81ae09dbb8ccca77877b78aebf098b2fb95432a926af8e384c", // AXTIon, Equity.US.AXTI/USD
    "0x33e337a21f74f02e0a5aa4a6ca8bcac777456865d1a27cc3e0495bd25d8d1b07", // OUSTon, Equity.US.OUST/USD
    "0xf695dfcfeb1e71dc0c2e1eef64df6076236a55ab45c46c444ef13e558b6f48d7", // NVTSon, Equity.US.NVTS/USD
    "0xd00bd77d97dc5769de77f96d0e1a79cbf1364e14d0dbf046e221bce2e89710dd", // USOon, Equity.US.USO/USD
    "0xf207c5d325e44579b12965394d9a4dd988567de635a494694bfb0b46c20a06ec", // SQQQon, Equity.US.SQQQ/USD
    "0x303e2b3c5ca84d33cad4b179ff2ee5a53cc2070b72655b0db4170ec19d799f82", // RXRXon, Equity.US.RXRX/USD
    "0x071f452ec5a5f4fa8ea8e585222c2f65890724374a2af16aec0bc70b4cd1c669", // SOXSon, Equity.Index.SOXS/USD
    "0xd5385d0f9a7b6268a357094c841bec5834b02265cb3ac439e53963a55defb38f", // LUNRon, Equity.US.LUNR/USD
    "0x64c24c75ad871df257440cafa78fbd8aaad18ac41ac04fc3f50a90d346855473", // OIHon, Equity.US.OIH/USD
    "0x24799168878b008a944098996a0bfbe6cb980fcd93fd28bf5e24511850be8d10", // RDWon, Equity.US.RDW/USD
    "0xb95c77565b8fcf080abfaee5fbd966e6732d9bb05ed7e839222c6352066929d8", // PURRon, Equity.US.PURR/USD
    "0xb4a8298d774980d697165333606303c12c46c0bcec62bb0df3fda11162bb2194", // DNNon, Equity.US.DNN/USD
    "0xafb12c5ccf50495c7a7b04447410d7feb4b3218a663ecbd96aa82e676d3c4f1e", // AIon, Equity.US.AI/USD
    "0xaa27f6a84dd364fd2956e350b12f4d698b57793f9a1d7ab5e8b575b3cfa50d8d", // AEHRon, Equity.US.AEHR/USD
    "0xc6101ee4f14af5581a3995438bf0e80a574dd28fd497685988b526ae9ba34749", // WENon, Equity.US.WEN/USD
    "0x782410278b6c8aa2d437812281526012808404aa14c243f73fb9939eeb88d430", // PPLTon, Equity.US.PPLT/USD
    "0x69155365daba71df19c2c0416467b64581052cfa75f44b77f352a92698b81639", // SMRon, Equity.US.SMR/USD
    "0x62be4863d61681d4b4393cde876fd92696c7c01c2792abcd06c0f3716b06f4bd", // URNMon, Equity.US.URNM/USD
    "0x1d27fb8230f11104a8bd4ed3ae44d0d61559261512c6508863d7af2c3f2059af", // UUUUon, Equity.US.UUUU/USD
    "0x88232bfe2ca44449224f24fc862d4b4fed9144e53f6cf9f0a939f88b82b4f8cd", // SOUNon, Equity.US.SOUN/USD
    "0x8f2af61cd4f049bce70d454e7a23c78760c68fff9d547d6144d9ae95a76a8913", // PLUGon, Equity.US.PLUG/USD
    "0xbb3bf79b043e09da5afc161b0e061971f020c6a31983308a3028bde5675e701a", // IGEBon, Equity.US.IGEB/USD
    "0x8adefab8e9d47055c1487bf2f962ee15ce29c5e3542044047147956621c43cf7", // SEDGon, Equity.US.SEDG/USD
    "0xf23c1137cf7d21fb6b6387e155536f25feea7a81ae4345407c2629ee397aa490", // WOLFon, Equity.US.WOLF/USD
    "0xb4ef19d348a726dad5a655bcac5fe6e09c83af142bf1006b45d0f9ca4d5a46b5", // OPENon, Equity.US.OPEN/USD
    "0x35df6acc91ade17065f757233443edee7b5046a4cd65748641f48d1c78e031b3", // QUBTon, Equity.US.QUBT/USD
    "0xbbea8136728ebb190eb529248350944c0e15dde357963a9ee32bab84ab754b7f", // KEELon, Equity.US.KEEL/USD
    "0xa8fe5f1e9d6c295e134f3314065c0110be9137d31e8f5959552a1694b0050910", // INODon, Equity.US.INOD/USD
    "0x6b5bedda9e9d6354c5b93659cba6747d21b527437022da6e5f32e3b53e485a04", // SBETon, Equity.US.SBET/USD
    "0xeda74e4c405a1f8d8d1c6004a197c20e620f5580e855ec66cf167f8d5f5ec7a3", // BTDRon, Equity.US.BTDR/USD
    "0xd66fd5fb5d53b65340d1772cf658d451eb9dd8f528f6433743cd87f51f43638c", // BBAIon, Equity.US.BBAI/USD
    "0x3488e477571c3c8aa861d02044a96a71fd81299cf0d915aa019af96335498874", // BNOon, Equity.US.BNO/USD
    "0x52d75219bbd61a396f93a964b830fc1362f3208701dd4fb80b501b603312bc8c", // PSQon, Equity.US.PSQ/USD
    "0x34b7613ec0b7388fc491162ef6d2b211ef311ea90d35863a7f03017d259c3cd4", // CPERon, Equity.US.CPER/USD
    "0x06f2079da8284ccb8810c0af9ca66fb608fcbcb90288754e42a0101dc5d34f9b", // FCELon, Equity.US.FCEL/USD
    "0x800415fb1fa6bac6bd13888d85843015a9cf35df23769314eb2ccad6b198ac4f", // FLNCon, Equity.US.FLNC/USD
    "0xa6fa5a4d8c9b0eb54f314df24f62382d0fd7817a0aebba8bcf5a8de833cac21d", // NNEon, Equity.US.NNE/USD
    "0x0aa20f6c96a0f30e7c78e4c4f45a0db36ee9126b1ae34851a2c37720e075a500", // BOTon, Equity.US.BOT/USD
    "0xfeeb371f721e75853604c47104967f0ab3fa92b988837013f5004f749a8a0599", // PALLon, Equity.US.PALL/USD
    "0x6540ed0004047d446b252bc49bff9e23e667c5c7d0437ad0db8e120e7b19c311", // BTGOon, Equity.US.BTGO/USD
    "0xb87e0ca977ca87d774ed3e22a3bb47d2123d152222efaa5a0aafb703728c71f6", // LPTHon, Equity.US.LPTH/USD
    "0xeb177413dfa4a455737b1427643ad43842f054625f85379eb154a3c790745d18", // EXODon, Equity.US.EXOD/USD
    "0xf6ea2fcdec548d7f3fe4d194866e59bebc5a7795e6cc7ec55a6b36fef0ca2526", // BWETon, Equity.US.BWET/USD
    "0xd0805a15ab9b061a858417e37281424fade678dd7a68d9d36ea18a55889652d7", // BAIon, Equity.US.BAI/USD
    "0x71a19a2d91626d9d184ba85c4a9d21289640013a7dacc113d007847ea1a09ec8", // DRAMon, Equity.US.DRAM/USD
    "0xb89885277fd07887353cb63d641afe432a5231256f844b3b993f8fe1764fdfca", // SATAon, Equity.US.SATA/USD
    "0x27c7bbc9755d847f7fc63620c2edcc6a91d2c0c67a28c7999907b59c505b3c17", // STRCon, Equity.US.STRC/USD
  ].map((id) => id.toLowerCase()),
);

export const ID = /^0x[0-9a-fA-F]{64}$/;
export const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
export const KEY = /^0x[0-9a-fA-F]{64}$/;

const DEFAULTS = {
  HERMES_URL: "https://pyth.dourolabs.app/hermes",
  MIN_PROFIT_USD: "5",
  MIN_TVL_USD: "1000",
  SLIPPAGE_BPS: "30",
  SUPPLY_TOLERANCE_BPS: "10",
  ROUTE_MAX_LOSS_BPS: "100",
  TRADE_COST_BPS: "30",
  FILL_REQUESTS: "1",
  FILL_AUCTIONS: "1",
  CHAIN_ID: "1",
  SUBSIDY_BUDGET_USD: "0",
  SHARE_STOCK_USD: "0",
  PRESTOCK_LEAD_SECONDS: "86400",
  RPC_TIMEOUT_MS: "15000",
};

/// The checks every setting of `env` goes through, with `defaults` for the ones left unset. Each records what is wrong
/// in `problems` rather than throwing, so a caller can name every problem at once.
export function envReader(env, defaults) {
  const problems = [];
  const get = (name) => {
    const raw = env[name] ?? defaults[name];
    return typeof raw === "string" ? raw.trim() : raw;
  };
  const required = (name, pattern, what) => {
    const value = get(name);
    if (!value) problems.push(`${name} is required`);
    else if (!pattern.test(value)) problems.push(`${name} must be ${what}`);
    return value;
  };
  const number = (name, { min = -Infinity, integer = false, positive = false } = {}) => {
    const raw = get(name);
    const value = raw === "" || raw === undefined ? NaN : Number(raw);
    if (!Number.isFinite(value)) problems.push(`${name} must be a number`);
    else if (integer && !Number.isInteger(value)) problems.push(`${name} must be an integer`);
    else if (value < min) problems.push(`${name} must be at least ${min}`);
    else if (positive && value <= 0) problems.push(`${name} must be positive`);
    return value;
  };
  const bps = (name) => {
    const value = number(name, { min: 0, integer: true });
    if (value > 10_000) problems.push(`${name} must be at most 10000`);
    return value;
  };

  return { problems, get, required, number, bps };
}

/// Parses and checks `env`. Throws one Error naming every problem, so a misconfigured keeper never starts.
export function parseConfig(env) {
  // The gas defaults are the chain's own: Ethereum's 100 and 2 gwei would pay a BNB Chain or Base fill dozens of
  // times what its block asks.
  const named = CHAINS[(env.CHAIN_ID ?? DEFAULTS.CHAIN_ID).trim()];
  const defaults = { ...DEFAULTS, MAX_FEE_GWEI: named?.maxFeeGwei ?? "100", PRIORITY_FEE_GWEI: named?.priorityFeeGwei ?? "2" };
  const { problems, get, required, number, bps } = envReader(env, defaults);

  const config = {
    rpcUrl: required("RPC_URL", /^https?:\/\/\S+$/, "an http(s) URL"),
    // How long one RPC request may take before it fails, and the round with it: fifteen seconds, the most a fill on
    // Ethereum can wait; longer for an RPC that is slow but sound, as a fork with a cold cache is.
    rpcTimeoutMs: number("RPC_TIMEOUT_MS", { integer: true, positive: true }),
    keeperKey: required("KEEPER_KEY", KEY, "a 32-byte hex private key"),
    factory: required("FACTORY", ADDRESS, "an address"),
    executor: required("EXECUTOR", ADDRESS, "an address"),
    pythApiKey: required("PYTH_API_KEY", /^\S+$/, "Pyth's Hermes API key"),
    hermesUrl: required("HERMES_URL", /^https?:\/\/\S+$/, "an http(s) URL")?.replace(/\/+$/, ""),
    indexes: null,
    minProfitUsd: number("MIN_PROFIT_USD"),
    minTvlUsd: number("MIN_TVL_USD", { min: 0 }),
    slippageBps: bps("SLIPPAGE_BPS"),
    supplyToleranceBps: bps("SUPPLY_TOLERANCE_BPS"),
    routeMaxLossBps: bps("ROUTE_MAX_LOSS_BPS"),
    // What trading a leg is taken to cost when the bot names a fill's units: a leg within this of its weight is left
    // alone rather than traded for nothing (bot/units.mjs).
    tradeCostBps: bps("TRADE_COST_BPS"),
    priceIds: null,
    maxFeeGwei: number("MAX_FEE_GWEI", { positive: true }),
    priorityFeeGwei: number("PRIORITY_FEE_GWEI", { min: 0 }),
    chain: CHAINS[get("CHAIN_ID")] ?? null,
    fillRequests: get("FILL_REQUESTS") === "1",
    fillAuctions: get("FILL_AUCTIONS") === "1",
    // What fills below zero profit may cost in all, per rolling day, when MIN_PROFIT_USD is negative; requests are never
    // subsidised (RX-16).
    subsidyBudgetUsd: number("SUBSIDY_BUDGET_USD", { min: 0 }),
    // The dollars of each index's own shares the request filler aims to hold as stock: a batch keeps what its
    // sellers bring up to this instead of redeeming it, and delivers it to buyers within the owner's stock allowance
    // for that index, so a cross between requests made at different times trades no basket. Zero holds none.
    shareStockUsd: number("SHARE_STOCK_USD", { min: 0 }),
    // Where to write the coins fills are short of, for the restock service; unset, nothing is written.
    needsFile: get("NEEDS_FILE") || null,
    // How long before an index may be started its auction's needs go on that board, so the restock brings the stock
    // in before the auction rather than during it. Zero reports an auction only once it can be started.
    prestockLeadSeconds: number("PRESTOCK_LEAD_SECONDS", { min: 0, integer: true }),
  };
  if (!["0", "1"].includes(get("FILL_REQUESTS"))) problems.push("FILL_REQUESTS must be 0 or 1");
  if (!["0", "1"].includes(get("FILL_AUCTIONS"))) problems.push("FILL_AUCTIONS must be 0 or 1");
  else if (get("FILL_AUCTIONS") === "0" && get("FILL_REQUESTS") === "0") problems.push("FILL_AUCTIONS and FILL_REQUESTS are both off: nothing to do");
  if (!config.chain) problems.push(`CHAIN_ID must be one of ${Object.keys(CHAINS).join(", ")}`);

  const list = get("INDEXES");
  if (list) {
    const entries = list.split(",").map((s) => s.trim()).filter(Boolean);
    const bad = entries.filter((s) => !ADDRESS.test(s));
    if (bad.length) problems.push(`INDEXES has entries that are not addresses: ${bad.join(", ")}`);
    else if (entries.length === 0) problems.push("INDEXES is set but names no index");
    else config.indexes = [...new Set(entries.map((s) => s.toLowerCase()))];
  }

  // The coins the keeper can value: the chain's own, and PRICE_IDS, `token=id` pairs, for a deployment whose coins
  // the catalogue does not hold (a testnet's) or to change one's feed.
  const priceIds = { ...(config.chain?.priceIds ?? {}) };
  for (const pair of (get("PRICE_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    const [token, id, ...rest] = pair.split("=").map((s) => s.trim());
    if (rest.length || !ADDRESS.test(token ?? "") || !ID.test(id ?? "")) problems.push(`PRICE_IDS has an entry that is not token=id: ${pair}`);
    else priceIds[token.toLowerCase()] = id.toLowerCase();
  }
  config.priceIds = Object.freeze(priceIds);

  if (problems.length) throw new Error(`keeper configuration:\n  ${problems.join("\n  ")}`);
  return Object.freeze(config);
}
