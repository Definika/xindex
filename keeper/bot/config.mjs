// The keeper's settings, read from the environment and checked before anything runs. No dependencies, so the unit
// tests run without `npm install`.

import { MAINNET_PRICE_IDS, MAINNET_WRAPPED } from "./price-ids.mjs";

const WETH_ID = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";

/// The chains the keeper runs on, by chain id (`CHAIN_ID`): the addresses it trades through on each, and the keeper's
/// own price source there. No contract reads a price (since 2026-11-10): `pyth` is Pyth's contract, which the keeper
/// alone asks to confirm that a price Hermes served is the signed one (RX-9, RY-7), and `priceIds` maps each coin the
/// keeper can value to its Pyth id. A coin without an entry is one the keeper leaves alone. `wrapped` names the coins
/// whose feed prices what they wrap: each is valued at its feed times the rate read from the wrapper (bot/rates.mjs).
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
    wrapped: MAINNET_WRAPPED,
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
    wrapped: Object.freeze([]),
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

/// The feeds that price one share, or one xStock, while a token priced at them is worth some other number of those
/// (script/PythIds.sol): every wrapped xStock's, worth `convertToAssets` xStocks, and the twelve Ondo legs priced at
/// the share's feed, each worth sValue shares (CF-3), which left the list on 2026-11-21 and stay here for a relisting.
/// A token at one of these is valued only when it is a wrapped coin whose rate the bot reads (`wrapped`, above, and
/// WRAPPED_TOKENS). Any other is a share-priced leg: the bot names no new units for it, delivers none from stock and
/// counts any it keeps as nothing (RX-2). So a wrapper the catalogue does not hold, added through PRICE_IDS alone, is
/// left alone rather than valued at its feed as if it were one xStock. `test/unit/config.test.mjs` pins the list
/// against PythIds.sol.
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
    "0x978e6cc68a119ce066aa830017318563a9ed04ec3a0a6439010fc11296a58675", // wAAPLx, Crypto.AAPLX/USD
    "0x019ae7cb58ee716ebdd1288b057373d60224fc98a9a43ee373c6b0df1f3ffdf5", // wABBVx, Equity.US.ABBV/USD
    "0x4aac40f432e039ab06236eb9bd3c58347f953d8f05b29aaac295b99cc47ee429", // wABTx, Equity.US.ABT/USD
    "0x68848984b74a7766ad23cdccd8e78e9ef339dcfb86b7e96990f27447c20967ed", // wACNx, Equity.US.ACN/USD
    "0xdf82dc88ea742bb42bdb845e5fc3ca4eef2354c67357d338221e8a696891b4ca", // wADBEx, Equity.US.ADBE/USD
    "0x3622e381dbca2efd1859253763b1adc63f7f9abb8e76da1aa8e638a57ccde93e", // wAMDx, Equity.US.AMD/USD
    "0x7148fbe6e493ff2580305c92a8d7f8628c9943b11b9b253aebc24863fec290e8", // wAMZNx, Crypto.AMZNX/USD
    "0x54f128939505878cf4412abc5a533255ce07e85833849170deb67deff0533aa7", // wAPPx, Equity.US.APP/USD
    "0x1a6e324589a0e355919fb1c0389edc3fdf4c46034626bd82aad4e47714cfa94f", // wASMLx, Equity.US.ASML/USD
    "0x17f979e1f6b7c429e4b9ecee96633dbecdc5378566ddfd3d220b0ef8d874e4bd", // wASTSx, Equity.US.ASTS/USD
    "0xd0c9aef79b28308b256db7742a0a9b08aaa5009db67a52ea7fa30ed6853f243b", // wAVGOx, Equity.US.AVGO/USD
    "0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710", // wAXPx, Equity.US.AXP/USD
    "0x7fb3b27d9039f8ca0a435fe0fdf724a3a5a2309ab62ad07ca775e5ab2100c1be", // wAZNx, Equity.US.AZN/USD
    "0x21debc1718a4b76ff74dadf801c261d76c46afaafb74d9645b65e00b80f5ee3e", // wBACx, Equity.US.BAC/USD
    "0xe90b679a7e4ca0d591abb634959d38a535c2036c6b121c520a82cff111ff7d12", // wBKNGx, Equity.US.BKNG/USD
    "0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08", // wBLKx, Equity.US.BLK/USD
    "0xdf68956522c14482f38841a1105220f9e32c35e48a3fd517cc955a4580ab1cae", // wBLSHx, Equity.US.BLSH/USD
    "0x54e2e127c93950de5a710100fd1cd387aba1ec8920850efdb05da5fee57d2e32", // wBMNRx, Equity.US.BMNR/USD
    "0xe21c688b7fc65b4606a50f3635f466f6986db129bf16979875d160f9c508e8c7", // wBRK.Bx, Equity.US.BRK-B/USD
    "0xff62267568a8f48ec7b1805eb989a8c96da713b335caf20275def485da7984c9", // wBTBTx, Equity.US.BTBT/USD
    "0x79e935bc10c55f2c36a08df1564afc5b33425c8dc80829dd954c67e63ed3374a", // wCLSKx, Equity.US.CLSK/USD
    "0x1bd6720eea4df323c076c9bbc1e98e8f5fe4bd16584e56468c5fb6b1a6072725", // wCMCSAx, Equity.US.CMCSA/USD
    "0x641435d5dffb5311140b480517c79986d8488d5cf08a11eec53b83ad02cab33f", // wCOINx, Crypto.COINX/USD
    "0x214fc87a8f0f5adc797fc1f7927e1040650366e8f943e20caf13ad0d6e806956", // wCORZx, Equity.US.CORZ/USD
    "0x163f6a6406d65305e8e27965b9081ac79b0cf9529f0fcdc14fe37e65e3b6b5cb", // wCOSTx, Equity.US.COST/USD
    "0xc13184461c0c80d98ffcd89be627c2220b94a96c7c67f0c4b16bc12fd3b17758", // wCRCLx, Crypto.CRCLX/USD
    "0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8", // wCRMx, Equity.US.CRM/USD
    "0xbaed936d3c6c2e34104e92c6b015b97ce96adc5ab4f04230c1270e1162e7a270", // wCRWDx, Equity.US.CRWD/USD
    "0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481", // wCSCOx, Equity.US.CSCO/USD
    "0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5", // wCVXx, Equity.US.CVX/USD
    "0x725ae6c67201359f9601d6ee8228c821f0abc93fef5cc509acfcee3f7bc2a388", // wDHRx, Equity.US.DHR/USD
    "0x6264a259e2cc90dfd3207f5831949eced2da6bf53965834c9160e4ceb9240947", // wEBAYx, Equity.US.EBAY/USD
    "0x1aed988d2a3349d64e8a34c0d71535e01d17bf6b80c4d99138288af251822552", // wEXPEx, Equity.US.EXPE/USD
    "0xe6af4d828b88cd3b40cb34686e61157d3fa37c1aa20ca2b99453aae62619b351", // wFIGx, Equity.US.FIG/USD
    "0xe7d1138d0083368634087268c64b7bea0b4101a6365f83915cba9e76a8364b96", // wGLDx, Crypto.GLDX/USD
    "0x67e031d1723e5c89e4a826d80b2f3b41a91b05ef6122d523b8829a02e0f563aa", // wGLXYx, Equity.US.GLXY/USD
    "0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6", // wGMEx, Equity.US.GME/USD
    "0xb911b0329028cd0283e4259c33809d62942bd2716a58084e5f31d64c00b5424e", // wGOOGLx, Crypto.GOOGLX/USD
    "0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554", // wGSx, Equity.US.GS/USD
    "0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5", // wHDx, Equity.US.HD/USD
    "0x107918baaaafb79cd9df1c8369e44ac21136d95f3ca33f2373b78f24ba1e3e6a", // wHONx, Equity.US.HON/USD
    "0xdd49a9ac6df5cbfa9d8fc6371f7ae927a74d5c6763c1c01b4220d70314c647f9", // wHOODx, Crypto.HOODX/USD
    "0x0f62d775396f303a630eec361709b5eb3126a89e6a73820f3c356d3a9b33dd8f", // wHSDTx, Equity.US.HSDT/USD
    "0xfb88ad7526f97f7ca6f43aaa7d3b620f412968db2cbcfac1e906362def8456f3", // wHUTx, Equity.US.HUT/USD
    "0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef", // wIBMx, Equity.US.IBM/USD
    "0x96b1207c795f31283f5e44c527a1db18cacfb68de745a0de326611b0b5af3fc3", // wIEMGx, Equity.US.IEMG/USD
    "0xca0bac9d1826b4a222320f58d47ed66bdc95722124578ed50803674ccd99a775", // wIJRx, Equity.US.IJR/USD
    "0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff", // wINTCx, Equity.US.INTC/USD
    "0xeff690a187797aa225723345d4612abec0bf0cec1ae62347c0e7b1905d730879", // wIWMx, Equity.US.IWM/USD
    "0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63", // wJNJx, Equity.US.JNJ/USD
    "0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e", // wJPMx, Equity.US.JPM/USD
    "0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d", // wKOx, Equity.US.KO/USD
    "0x9146c5c900d9aea9579819cf50d1ae18b54dea58eea3c9a198102e4e458e652b", // wLINx, Equity.US.LIN/USD
    "0x70dcf5fd56553d0023693e4b590336a8c9bcfd0d98dd9f093b1f697820d98325", // wLLYx, Equity.US.LLY/USD
    "0x13a19eb6a936a8c7020fe675687979b44e991efbfb4d3d2ca91425ce57b9e6f8", // wLULUx, Equity.US.LULU/USD
    "0x639db3fe6951d2465bd722768242e68eb0285f279cb4fa97f677ee8f80f1f1c0", // wMAx, Equity.US.MA/USD
    "0x0fc2ad77a9ab75bcbc3ebd7a9ff60facd08c517309e2d684baa979c910a0e43e", // wMARAx, Equity.US.MARA/USD
    "0x27cac3c00ed32285b8686611bbc4a654279c1ea11ab4dc90822c2edd20734bca", // wMCDx, Crypto.MCDX/USD
    "0x1d762c633d4166a8d061518e187047afda1868cc524990262d8144e39dbb815f", // wMDTx, Equity.US.MDT/USD
    "0xbf3e5871be3f80ab7a4d1f1fd039145179fb58569e159aee1ccd472868ea5900", // wMETAx, Crypto.METAX/USD
    "0x579e60cbba314226de0f602f770113aa007bf1786ee37b923800028dc203d1e5", // wMNSTx, Equity.US.MNST/USD
    "0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46", // wMRKx, Equity.US.MRK/USD
    "0x7aef4e90557add5289266340ccd1e1aa7a225f1220206b07aaf98e53101ce116", // wMRVLx, Equity.US.MRVL/USD
    "0xbb723a70af731ab56b9a650eb7e8ac22b7bc07ea77f8670bd1fa9a37bf6df3f5", // wMSFTx, Crypto.MSFTX/USD
    "0x53f95ba4e23ed15ea56083e2ee9a5eec48055d6f59033d4bb95f1ca2a2349c28", // wMSTRx, Crypto.MSTRX/USD
    "0x0ce20662c616102659948a2e6ccf7ce05c930366af42b71240086eafb7cfa860", // wMUx, Crypto.MUX/USD
    "0x02a67e6184e6c9dd65e14745a2a80df8b2b3d2ca91b4b191404936003d9929ae", // wNFLXx, Crypto.NFLXX/USD
    "0x4244d07890e4610f46bbde67de8f43a4bf8b569eebe904f136b469f148503b7f", // wNVDAx, Crypto.NVDAX/USD
    "0x8dde322496e031d942b9eee8ca769d618cd2e69b18196644369379f5a1e7c23d", // wNVOx, Equity.US.NVO/USD
    "0x0d283a095e94dff4d4e607614ed686eb53e548238fb3af231148c276ecefe83e", // wOKLOx, Equity.US.OKLO/USD
    "0xb4ef19d348a726dad5a655bcac5fe6e09c83af142bf1006b45d0f9ca4d5a46b5", // wOPENx, Equity.US.OPEN/USD
    "0xe47ff732eaeb6b4163902bdee61572659ddf326511917b1423bae93fcdf3153c", // wORCLx, Equity.US.ORCL/USD
    "0x3b00df0661ccb3109d11ff301c1aa4e88b8d647cb477b089ba225149e6e1b7bb", // wPANWx, Equity.US.PANW/USD
    "0xbe230eddb16aad5ad273a85e581e74eb615ebf67d378f885768d9b047df0c843", // wPEPx, Equity.US.PEP/USD
    "0x0704ad7547b3dfee329266ee53276349d48e4587cb08264a2818288f356efd1d", // wPFEx, Equity.US.PFE/USD
    "0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4", // wPGx, Equity.US.PG/USD
    "0x562e632de00dd4ad4a70b024afc3e2a220c1b05116d58cf96089825303f94762", // wPLx, Equity.US.PL/USD
    "0x11a70634863ddffb71f2b11f2cff29f73f3db8f6d0b78c49f2b5f4ad36e885f0", // wPLTRx, Equity.US.PLTR/USD
    "0xa32f875eb39e23f087ea0db141b00857630c2c5011bfbe53a2a4d186f37cb583", // wPMx, Equity.US.PM/USD
    "0x773c3b11f6be58e8151966a9f5832696d8cd08884ccc43ac8965a7ebea911533", // wPYPLx, Equity.US.PYPL/USD
    "0x178a6f73a5aede9d0d682e86b0047c9f333ed0efe5c6537ca937565219c4054d", // wQQQx, Crypto.QQQX/USD
    "0xd62134a195739141d0649991f11fe0f9cd9eb83fd890bc3ba41dfdd18c1a49f4", // wRBLXx, Equity.US.RBLX/USD
    "0x46417522a59b245c5af35c33c13426d991b36514c4c85aaefe1cf787e7daad90", // wRIOTx, Equity.US.RIOT/USD
    "0x40589e289317e4fbd997b1a267606e20a1cc7c3e4689f9e5a5992957917816c8", // wRKLBx, Equity.US.RKLB/USD
    "0x6b5bedda9e9d6354c5b93659cba6747d21b527437022da6e5f32e3b53e485a04", // wSBETx, Equity.US.SBET/USD
    "0x601671d8a16a9f456d9a16d0bf203dd80d5076cc95ddca29cb5c7f8024dbeba6", // wSCHFx, Equity.US.SCHF/USD
    "0x6fc08c9963d266069cbd9780d98383dabf2668322a5bef0b9491e11d67e5d7e7", // wSLVx, Equity.US.SLV/USD
    "0xfce02687a8a49f19f78f7f97bd686c779135221429206bbd8735d5ad4c782130", // wSPCEx, Equity.US.SPCE/USD
    "0xe7268062e142570f97cfba327f14e3153d1d4d8f6a4f84e59b72940ee87ecdb9", // wSPGIx, Equity.US.SPGI/USD
    "0x2817b78438c769357182c04346fddaad1178c82f4048828fe0997c3c64624e14", // wSPYx, Crypto.SPYX/USD
    "0x5f5193ed44dd1f4b0732dbffa2e27caf953e16a2d911854c8c3766d8bc609a47", // wSTRCx, Crypto.STRCX/USD
    "0x63e9f918ab91507c3574cca011da4dccda30cf54d46124d03b70279142ff81f3", // wTx, Equity.US.T/USD
    "0x79c4582b9dd2d5f9a32c54654f3db995353a0e57a8094bacb8fb55a7190ca9a3", // wTEMx, Equity.US.TEM/USD
    "0x13537ceb2df5af0b8cdf8032561b0a71430b51297375bbfdc6ed209df1da0d65", // wTGTx, Equity.US.TGT/USD
    "0x244fdf268ed7ecfad2cf84529c46d0fcef7a643428ff4ef8b16e8dbb63e0f2d9", // wTMOx, Equity.US.TMO/USD
    "0x0b231ca4307d25e4600067bfb06f576474bcabd74fb50eeaa0906ac1b457f365", // wTMUSx, Equity.US.TMUS/USD
    "0x5aa9f82dc2e0f5f8271fd163e980010101517da59f4b72b71c7056a5950b2f9d", // wTQQQx, Equity.US.TQQQ/USD
    "0x47a156470288850a440df3a6ce85a55917b813a19bb5b31128a33a986566a362", // wTSLAx, Crypto.TSLAX/USD
    "0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4", // wTSMx, Equity.US.TSM/USD
    "0xc04665f62a0eabf427a834bb5da5f27773ef7422e462d40c7468ef3e4d39d8f1", // wUBERx, Equity.US.UBER/USD
    "0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd", // wUNHx, Equity.US.UNH/USD
    "0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90", // wVx, Equity.US.V/USD
    "0x665d46c8142ca4486ebcdcfc0bbb913dee5255e0be63b6f971933620a7f69045", // wVSTx, Equity.US.VST/USD
    "0xb167b163565d841b1477cb942bf3b2d28214f3eedf343de7536d6e5b6250d45b", // wVTx, Equity.US.VT/USD
    "0x26c67e91769aeba33a09469c705a1863794014dac416e4270661f489309ae862", // wVTIx, Equity.US.VTI/USD
    "0xc6101ee4f14af5581a3995438bf0e80a574dd28fd497685988b526ae9ba34749", // wWENx, Equity.US.WEN/USD
    "0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc", // wWMTx, Equity.US.WMT/USD
    "0x7717b73c7f19ffb1e6e5da542836fa3464559ec971df475455471433a005e2a6", // wWULFx, Equity.US.WULF/USD
    "0x4a1a12070192e8db9a89ac235bb032342a390dde39389b4ee1ba8e41e7eae5d8", // wXOMx, Equity.US.XOM/USD
  ].map((id) => id.toLowerCase()),
);

/// How far back the keeper reads a wrapper's rate again before it values anything at the rate now, in blocks: about
/// twenty minutes on Ethereum, and inside the recent state a full node keeps (geth's 128 blocks). A node that cannot
/// serve that block fails the read, and the wrapper is then not valued, which the log says.
export const RATE_LOOKBACK_BLOCKS = 100n;

/// The furthest a wrapper's rate may have moved over RATE_LOOKBACK_BLOCKS for the keeper to value the wrapper, in
/// basis points. A dividend moves an xStock's multiplier, and so its wrapper's rate, by a percent or less; one key of
/// the issuer's can set any multiplier, and a split moves it by the split's factor at a moment the share's feed need not
/// share. A rate that moved further values nothing, so the keeper leaves that leg alone, fills no request on an index
/// holding it and counts none of it as stock, until the move is that many blocks old: time for an operator to look,
/// not a judgment that the new rate is right.
export const MAX_RATE_MOVE_BPS = 100n;

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
  MAX_FEE_GWEI: "100",
  PRIORITY_FEE_GWEI: "2",
  FILL_REQUESTS: "1",
  FILL_AUCTIONS: "1",
  CHAIN_ID: "1",
  SUBSIDY_BUDGET_USD: "0",
  SHARE_STOCK_USD: "0",
  PRESTOCK_LEAD_SECONDS: "86400",
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
  const { problems, get, required, number, bps } = envReader(env, DEFAULTS);

  const config = {
    rpcUrl: required("RPC_URL", /^https?:\/\/\S+$/, "an http(s) URL"),
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
    wrapped: null,
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
  // The wrapped coins, lowercased (bot/rates.mjs): the chain's own, and WRAPPED_TOKENS, addresses, for a wrapper the
  // catalogue does not hold. Each needs a price id, the feed of what it wraps: a wrapper named here without one would
  // be read every round and valued by nothing.
  const wrapped = new Set((config.chain?.wrapped ?? []).map((t) => t.toLowerCase()));
  for (const token of (get("WRAPPED_TOKENS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)) {
    if (!ADDRESS.test(token)) problems.push(`WRAPPED_TOKENS has an entry that is not an address: ${token}`);
    else if (!priceIds[token.toLowerCase()]) problems.push(`WRAPPED_TOKENS names ${token}, which has no price id: add the feed of what it wraps to PRICE_IDS`);
    else wrapped.add(token.toLowerCase());
  }
  config.wrapped = wrapped;

  if (problems.length) throw new Error(`keeper configuration:\n  ${problems.join("\n  ")}`);
  return Object.freeze(config);
}
