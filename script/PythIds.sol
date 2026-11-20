// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The Pyth price id of each listed coin. No contract and no script reads it since 2026-11-10: an index
///         rebalances through an auction on units alone (`design/2026-11-10-oracle-free-rebalance.md`), and a listing
///         carries no feed. It stays as the keeper's price catalogue, which its own tests pin (`keeper/`): the keeper
///         values its own trades at these feeds, off chain, at its own risk. Read from Pyth's Hermes
///         catalogue (`/v2/price_feeds`) on 2026-10-05, each checked to name its coin by the feed's description, given
///         beside it. WETH takes ETH/USD: it redeems one for one on chain, and ETH/USD is Pyth's deepest feed. WBTC takes
///         WBTC/USD, not BTC/USD: it is custodial, so its own price is what catches a depeg. GRAM is left out until the
///         owner confirms whether Pyth's "GRAM / US DOLLAR" or "TONCOIN / US DOLLAR" is the coin it bridges
///         (design/2026-10-05-custom-weights.md, section 2). The owner's calls of 2026-10-06 keep GRAM out, its bridge
///         closed, and drop OKB, being retired on Ethereum, and BGB and GT, which no Uniswap route trades, so no fill
///         could rebalance them (design/2026-10-05-wide-asset-support.md, section 6). INJ, SHIB and PEPE joined on
///         2026-10-10, from CoinGecko's top 100 of that day, SHIB and PEPE on the owner's call; Wormhole's SOL the same
///         day, in place of BNB Chain's Binance-Peg SOL. Tether Gold and 17 Ondo stock tokens joined the same day, on
///         the owner's call; a stock is priced at its Ondo token's own feed where Pyth has one, else at Pyth's 24/7
///         price for the share, else at the US-hours feed, which publishes nothing while the market is closed. Pyth's
///         catalogue, read on 2026-10-19, gives the "24/7" share feeds the same regular-hours schedule as the US-hours
///         ones, so all twelve are treated as session-limited until Hermes' data says otherwise (RX-31). The
///         hundred-coin list of 2026-10-10 (design/2026-10-10-one-index-wormhole-legs.md) adds 31 Ethereum-issued
///         coins and 13 Wormhole copies, each at its coin's feed, read from Hermes that day; a Wormhole copy is priced
///         as the coin it wraps, as SOL's is. DOGE's copy left on 2026-10-14, the owner's call (`MainnetAddresses`).
///         Wormhole's copies of BNB, SUI and SEI, which the count of 2026-10-10 missed, joined on 2026-10-18, each at
///         its coin's feed, read from Pyth's catalogue (Benchmarks' `/v1/price_feeds`) that day; SAND and RLB left the
///         same day, the owner's call after the source reading (design/2026-10-18-token-source-reading.md). BTT and
///         SEI's copy left on 2026-10-19, the owner's call on the red team's RX-28 and RX-32: the bridge behind each has
///         closed or is closing, so the copy would be priced as a coin it no longer redeems for. Backed's wrapped
///         xStocks joined on 2026-11-21, in place of the Ondo tokens, which left the list (their ids stay for a
///         relisting). Each wrapper takes its xStock's own feed where Pyth has one (18 of them, around the clock),
///         and else its share's US-hours feed; each was read from Hermes' catalogue that day and checked to name
///         the share. A feed prices one xStock, which is one share; a wrapper is worth `convertToAssets` xStocks,
///         which the keeper must read on chain to value it (`SHARE_PRICED_IDS` in keeper/bot/config.mjs).
library PythIds {
    /// @dev ETHEREUM / US DOLLAR.
    bytes32 internal constant WETH = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    /// @dev WRAPPED BITCOIN / US DOLLAR.
    bytes32 internal constant WBTC = 0xc9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33;
    /// @dev UNISWAP / US DOLLAR.
    bytes32 internal constant UNI = 0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501;
    /// @dev CHAINLINK / US DOLLAR.
    bytes32 internal constant LINK = 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221;
    /// @dev QUANT / US DOLLAR.
    bytes32 internal constant QNT = 0x19ab139032007c8bd7d1fd3842ef392a5434569a72b555504a5aee47df2a0a35;
    /// @dev AAVE / US DOLLAR.
    bytes32 internal constant AAVE = 0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445;
    /// @dev ETHENA / US DOLLAR.
    bytes32 internal constant ENA = 0xb7910ba7322db020416fcac28b48c01212fd9cc8fbcbaf7d30477ed8605f6bd4;
    /// @dev ONDO / US DOLLAR.
    bytes32 internal constant ONDO = 0xd40472610abe56d36d065a0cf889fc8f1dd9f3b7f2a478231a5fc6df07ea5ce3;
    /// @dev SKY PROTOCOL / US DOLLAR.
    bytes32 internal constant SKY = 0xa483243eed64ca27a1f6e26385b7d1e0d07e9fe264bb6903efb3efc4689d3fe7;
    /// @dev WORLDCOIN / US DOLLAR.
    bytes32 internal constant WLD = 0xd6835ad1f773de4a378115eb6824bd0c0e42d84d1c84d9750e853fb6b6c7794a;
    /// @dev MANTLE / US DOLLAR.
    bytes32 internal constant MNT = 0x4e3037c822d852d79af3ac80e35eb420ee3b870dca49f9344a38ef4773fb0585;
    /// @dev MORPHO / US DOLLAR.
    bytes32 internal constant MORPHO = 0x5b2a4c542d4a74dd11784079ef337c0403685e3114ba0d9909b5c7a7e06fdc42;
    /// @dev POLYGON ECOSYSTEM TOKEN / US DOLLAR.
    bytes32 internal constant POL = 0xffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472;
    /// @dev LIGHTER / US DOLLAR.
    bytes32 internal constant LIT = 0xc0c83f00c39165892d55dcd17ade2191e289697e2ac132d9ab721e20834e2a9e;
    /// @dev ETHER.FI / US DOLLAR.
    bytes32 internal constant ETHFI = 0xb27578a9654246cb0a2950842b92330e9ace141c52b63829cc72d5c45a5a595a;
    /// @dev ARTIFICIAL SUPERINTELLIGENCE ALLIANCE / US DOLLAR.
    bytes32 internal constant FET = 0x7da003ada32eabbac855af3d22fcf0fe692cc589f0cfd5ced63cf0bdcc742efe;
    /// @dev CURVE DAO / US DOLLAR.
    bytes32 internal constant CRV = 0xa19d04ac696c7a6616d291c7e5d1377cc8be437c327b75adb5dc1bad745fcae8;
    /// @dev NEXO / US DOLLAR.
    bytes32 internal constant NEXO = 0xe5f406d97d7fa159c21647912b72aa8c669e24d7bd59bcd518587bbde027c531;
    /// @dev VIRTUAL PROTOCOL / US DOLLAR.
    bytes32 internal constant VIRTUAL = 0x8132e3eb1dac3e56939a16ff83848d194345f6688bff97eb1c8bd462d558802b;
    /// @dev STARKNET / US DOLLAR.
    bytes32 internal constant STRK = 0x6a182399ff70ccf3e06024898942028204125a819e519a335ffa4579e66cd870;
    /// @dev PENDLE / US DOLLAR.
    bytes32 internal constant PENDLE = 0x9a4df90b25497f66b1afb012467e316e801ca3d839456db028892fe8c70c8016;
    /// @dev CRONOS / US DOLLAR.
    bytes32 internal constant CRO = 0x23199c2bcb1303f667e733b9934db9eca5991e765b45f5ed18bc4b231415f2fe;
    /// @dev INTERNET COMPUTER / US DOLLAR.
    bytes32 internal constant ICP = 0xc9907d786c5821547777780a1e4f89484f3417cb14dd244f2b0a34ea7a554d67;
    /// @dev ARBITRUM / US DOLLAR.
    bytes32 internal constant ARB = 0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5;
    /// @dev RENDER / US DOLLAR.
    bytes32 internal constant RENDER = 0x3d4a2bd9535be6ce8059d75eadeba507b043257321aa544717c56fa19b49e35d;
    /// @dev PANCAKESWAP / US DOLLAR.
    bytes32 internal constant CAKE = 0x2356af9529a1064d41e32d617e2ce1dca5733afa901daba9e2b68dee5d53ecf9;
    /// @dev LAYER ZERO / US DOLLAR.
    bytes32 internal constant ZRO = 0x3bd860bea28bf982fa06bcf358118064bb114086cc03993bd76197eaab0b8018;
    /// @dev INJECTIVE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant INJ = 0x7a5bc1d2b56ad029048cd63964b3ad2776eadf812edc1a43a31406cb54bff592;
    /// @dev SHIBA INU / US DOLLAR, read from Hermes on 2026-10-10; exponent -10 on Pyth's Ethereum contract.
    bytes32 internal constant SHIB = 0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a;
    /// @dev PEPE / US DOLLAR, read from Hermes on 2026-10-10; exponent -10. Not "1000 PEPE / US DOLLAR" (KPEPE),
    ///      which prices a thousand tokens.
    bytes32 internal constant PEPE = 0xd69731a2e74ac1ce884fc3890f7ee324b6deb66147055249568869ed700882e4;
    /// @dev SOLANA / US DOLLAR, the coin's feed: nothing prices Wormhole's copy apart.
    bytes32 internal constant SOL = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    /// @dev TETHER GOLD / US DOLLAR, the token's own feed.
    bytes32 internal constant XAUT = 0x44465e17d2e9d390e70c999d5a11fda4f092847fcd2e3e5aa089d96c98a30e67;
    /// @dev NVIDIA ONDO TOKENIZED STOCK / US DOLLAR (Crypto.NVDAON/USD): the Ondo token's own feed.
    bytes32 internal constant NVDAON = 0x207ddea2a443d30b7e13a7c88a9e3f106765deb97049afc65a18cede50fffc82;
    /// @dev APPLE ONDO TOKENIZED STOCK / US DOLLAR (Crypto.AAPLON/USD): the Ondo token's own feed.
    bytes32 internal constant AAPLON = 0xe6734de88a83d9d2fb33072adab319004700aefd069653aba30ba9e3cac056f2;
    /// @dev GOOGLE ONDO TOKENIZED STOCK / US DOLLAR (Crypto.GOOGLON/USD): the Ondo token's own feed.
    bytes32 internal constant GOOGLON = 0xad79b3487bef87ff8f8ab31c0b779ad08d931fdfa5436f7e92a234bb82bff7e4;
    /// @dev MICROSOFT ONDO TOKENIZED STOCK / US DOLLAR (Crypto.MSFTON/USD): the Ondo token's own feed.
    bytes32 internal constant MSFTON = 0x29b228e9fd72bbd306bcca3b10c165d8dba5d535ef8d5aab6c6e4bc18912d150;
    /// @dev PYTH PRICE IN USD FOR AMZN 24/7 (Equity.Index.AMZN/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant AMZNON = 0x329635cf9e705e01ed2d842fafbb6c426d7e5630e75847740d89957222fd68b8;
    /// @dev TAIWAN SEMICONDUCTOR MANUFACTURING CO LIMITED / US DOLLAR (Equity.US.TSM/USD): US market hours only.
    bytes32 internal constant TSMON = 0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4;
    /// @dev PYTH PRICE IN USD FOR SPCX 24/7 (Equity.Index.SPCX/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant SPCXON = 0x2dbfb1791e75725227a90dbd23c6bdd83b80cc9d13011973c948b6aeacdf17b9;
    /// @dev PYTH PRICE IN USD FOR META 24/7 (Equity.Index.META/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant METAON = 0x2cc0c022f7f37920485a5947f3cea8633783b6cb7fff6d94ee52f48687b7783d;
    /// @dev BROADCOM INC / US DOLLAR (Equity.US.AVGO/USD): US market hours only.
    bytes32 internal constant AVGOON = 0xd0c9aef79b28308b256db7742a0a9b08aaa5009db67a52ea7fa30ed6853f243b;
    /// @dev TESLA ONDO TOKENIZED STOCK / US DOLLAR (Crypto.TSLAON/USD): the Ondo token's own feed.
    bytes32 internal constant TSLAON = 0xc09ef687ed07091c047da444f1499f2da52cdc1c085104643ec565a9eb1af514;
    /// @dev PYTH PRICE IN USD FOR SKHY 24/7 (Equity.Index.SKHY/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant SKHYON = 0xb196587ca694ea231cd8710321f4f62ed08794c6a096759d5c63616730042ae0;
    /// @dev PYTH PRICE IN USD FOR MU 24/7 (Equity.Index.MU/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant MUON = 0x27e65b49e4572601374c5bde284411c20f49eb74845cc7f7801f9d27fba2b4b2;
    /// @dev ELI LILLY AND COMPANY / US DOLLAR (Equity.US.LLY/USD): US market hours only.
    bytes32 internal constant LLYON = 0x70dcf5fd56553d0023693e4b590336a8c9bcfd0d98dd9f093b1f697820d98325;
    /// @dev PYTH PRICE IN USD FOR AMD 24/7 (Equity.Index.AMD/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant AMDON = 0xfa1a3697811ac1b36846b4de42ad1b4d3c7b50b556eed405dbefbf4e4a0c7c07;
    /// @dev JPMORGAN CHASE & CO / US DOLLAR (Equity.US.JPM/USD): US market hours only.
    bytes32 internal constant JPMON = 0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e;
    /// @dev WALMART INC / US DOLLAR (Equity.US.WMT/USD): US market hours only.
    bytes32 internal constant WMTON = 0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc;
    /// @dev VISA INC / US DOLLAR (Equity.US.V/USD): US market hours only.
    bytes32 internal constant VON = 0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90;
    /// @dev FALCON FINANCE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant FF = 0xf9597faf41a8d91fcc4dc95e9b4f408ea391cf17ec26955ae2055b6dbda5ec89;
    /// @dev GNOSIS / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant GNO = 0xc5f60d00d926ee369ded32a38a6bd5c1e0faa936f91b987a5d0dcf3c5d8afab0;
    /// @dev OLYMPUS DAO / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant OHM = 0x3a8c0214e4fb7f1dd7792ed4d5b2971372e52f088fcd9cc02309253cbdc4a70e;
    /// @dev THE GRAPH / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant GRT = 0x4d1f8dae0d96236fb98e8f47471a366ec3b1732b47041781934ca3a9bb2f35e7;
    /// @dev MAPLE FINANCE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant SYRUP = 0xed86e0c6321d790302e5d88751995ebc9079273e549005d68a83ba72e48ff1ce;
    /// @dev ETHEREUM NAME SERVICE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ENS = 0xb98ab6023650bd2edc026b983fb7c2f8fa1020286f1ba6ecf3f4322cd83b72a6;
    /// @dev JASMYCOIN / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant JASMY = 0x2b386bdca7fda5cf3c3975f70318593bf144104cb00742592ecff60dd798972f;
    /// @dev COMPOUND / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant COMP = 0x4a8e42861cabc5ecb50996f92e7cfa2bce3fd0a2423b0c44c9b423fb2bd25478;
    /// @dev EIGENLAYER / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant EIGEN = 0xc65db025687356496e8653d0d6608eec64ce2d96e2e28c530e574f0e4f712380;
    /// @dev AXIE INFINITY / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant AXS = 0xb7e3904c08ddd9c0c10c6d207d390fd19e87eb6aab96304f571ed94caebdefa0;
    /// @dev BASIC ATTENTION / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant BAT = 0x8e860fb74e60e5736b455d82f60b3728049c348e94961add5f961b02fdee2535;
    /// @dev CONVEX FINANCE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant CVX = 0x6aac625e125ada0d2a6b98316493256ca733a5808cd34ccef79b0e28c64d1e76;
    /// @dev DECENTRALAND / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant MANA = 0x1dfffdcbc958d732750f53ff7f06d24bb01364b3f62abea511a390c74b8d16a5;
    /// @dev IMMUTABLE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant IMX = 0x941320a8989414874de5aa2fc340a75d5ed91fdff1613dd55f83844d52ea63a2;
    /// @dev FLUID / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant FLUID = 0x47d462d8bac4c29b6ae1792029b9b92c8adea12ed22155bfc22f481287f1e349;
    /// @dev CHILIZ / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant CHZ = 0xe799f456b358a2534aa1b45141d454ac04b444ed23b1440b778549bb758f2b5c;
    /// @dev ZKSYNC / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ZK = 0xcc03dc09298fb447e0bf9afdb760d5b24340fd2167fd33d8967dd8f9a141a2e8;
    /// @dev APECOIN / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant APE = 0x15add95022ae13563a11992e727c91bdb6b55bc183d9d747436c80a483d8c864;
    /// @dev SENTIENT / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant SENT = 0xc1c19f04619dbca4343d76f240b4d944551bbbb56883051e874a8d0533bce644;
    /// @dev SYNTHETIX NETWORK / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant SNX = 0x39d020f60982ed892abbcd4a06a276a9f9b7bfbce003204c110b6e488f502da3;
    /// @dev 1INCH / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ONEINCH = 0x63f341689d98a12ef60a5cff1d7f85c70a9e17bf1575f0e7c0b2512d48b1c8b3;
    /// @dev GOLEM / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant GLM = 0x01a09cbc99b1894271cfd90d6e5aab527cafa66b19d651b441b84e84f671de33;
    /// @dev AETHIR / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ATH = 0xf6b551a947e7990089e2d5149b1e44b369fcc6ad3627cb822362a2b19d24ad4a;
    /// @dev HUMANITY / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant H = 0x807df1ed343907c4d97790334338c5df6e360036b3c95f880450d078569b5481;
    /// @dev PLUME NETWORK / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant PLUME = 0xded84d57dbf810bf86b97936f12e1f01b8d6d01c251a4d6eac592147988d475c;
    /// @dev GALA GAMES / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant GALA = 0x0781209c28fda797616212b7f94d77af3a01f3e94a5d421760aef020cf2bcb51;
    /// @dev WORMHOLE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant W = 0xeff7446475e218517566ea99e72a4abec2e1bd8498b43b7d8331e29dcb059389;
    /// @dev RESERVE RIGHTS / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant RSR = 0xfb7565b77267ba3f6ef770bed5d7f9b22b8542db676dbd9b934a2fcf945f4371;
    /// @dev RIPPLE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant XRP = 0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8;
    /// @dev CARDANO / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ADA = 0x2a01deaec9e51a579277b34b122399984d0bbf57e2458a7e42fecd2829867a0d;
    /// @dev LITECOIN / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant LTC = 0x6e3f3fa8253588df9326580180233eb791e03b443a3ba7a1d892e73874e19a54;
    /// @dev AVALANCHE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant AVAX = 0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7;
    /// @dev POLKADOT / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant DOT = 0xca3eed9b267293f6595901c734c7525ce8ef49adafe8284606ceb307afa2ca5b;
    /// @dev JUPITER / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant JUP = 0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996;
    /// @dev ALGORAND / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ALGO = 0xfa17ceaf30d19ba51112fdcc750cc83454776f47fb0112e4af07f15f4bb1ebc0;
    /// @dev COSMOS / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant ATOM = 0xb00b60f88b03a6a625a8d1c048c3f66653edf217439983d037e7222c4e612819;
    /// @dev AERODROME FINANCE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant AERO = 0x9db37f4d5654aad3e37e2e14ffd8d53265fb3026d1d8f91146539eebaa2ef45f;
    /// @dev APTOS / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant APT = 0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5;
    /// @dev PYTH NETWORK / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant PYTH_TOKEN = 0x0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff;
    /// @dev OPTIMISM / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant OP = 0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf;
    /// @dev BNB / US DOLLAR, read from Pyth's catalogue on 2026-10-18.
    bytes32 internal constant BNB = 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f;
    /// @dev SUI / US DOLLAR, read from Pyth's catalogue on 2026-10-18.
    bytes32 internal constant SUI = 0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744;
    /// @dev wAAPLx: APPLE XSTOCK / US DOLLAR (Crypto.AAPLX/USD), the xStock's own feed.
    bytes32 internal constant WAAPLX = 0x978e6cc68a119ce066aa830017318563a9ed04ec3a0a6439010fc11296a58675;
    /// @dev wABBVx: ABBVIE INC / US DOLLAR (Equity.US.ABBV/USD), the share's feed.
    bytes32 internal constant WABBVX = 0x019ae7cb58ee716ebdd1288b057373d60224fc98a9a43ee373c6b0df1f3ffdf5;
    /// @dev wABTx: ABBOTT LABORATORIES / US DOLLAR (Equity.US.ABT/USD), the share's feed.
    bytes32 internal constant WABTX = 0x4aac40f432e039ab06236eb9bd3c58347f953d8f05b29aaac295b99cc47ee429;
    /// @dev wACNx: ACCENTURE PLC / US DOLLAR (Equity.US.ACN/USD), the share's feed.
    bytes32 internal constant WACNX = 0x68848984b74a7766ad23cdccd8e78e9ef339dcfb86b7e96990f27447c20967ed;
    /// @dev wADBEx: ADOBE INC / US DOLLAR (Equity.US.ADBE/USD), the share's feed.
    bytes32 internal constant WADBEX = 0xdf82dc88ea742bb42bdb845e5fc3ca4eef2354c67357d338221e8a696891b4ca;
    /// @dev wAMDx: ADVANCED MICRO DEVICES INC / US DOLLAR (Equity.US.AMD/USD), the share's feed.
    bytes32 internal constant WAMDX = 0x3622e381dbca2efd1859253763b1adc63f7f9abb8e76da1aa8e638a57ccde93e;
    /// @dev wAMZNx: AMAZON XSTOCK / US DOLLAR (Crypto.AMZNX/USD), the xStock's own feed.
    bytes32 internal constant WAMZNX = 0x7148fbe6e493ff2580305c92a8d7f8628c9943b11b9b253aebc24863fec290e8;
    /// @dev wAPPx: APPLOVIN CORPORATION / US DOLLAR (Equity.US.APP/USD), the share's feed.
    bytes32 internal constant WAPPX = 0x54f128939505878cf4412abc5a533255ce07e85833849170deb67deff0533aa7;
    /// @dev wASMLx: ASML HOLDING NV / US DOLLAR (Equity.US.ASML/USD), the share's feed.
    bytes32 internal constant WASMLX = 0x1a6e324589a0e355919fb1c0389edc3fdf4c46034626bd82aad4e47714cfa94f;
    /// @dev wASTSx: AST SPACEMOBILE INC / US DOLLAR (Equity.US.ASTS/USD), the share's feed.
    bytes32 internal constant WASTSX = 0x17f979e1f6b7c429e4b9ecee96633dbecdc5378566ddfd3d220b0ef8d874e4bd;
    /// @dev wAVGOx: BROADCOM INC / US DOLLAR (Equity.US.AVGO/USD), the share's feed.
    bytes32 internal constant WAVGOX = 0xd0c9aef79b28308b256db7742a0a9b08aaa5009db67a52ea7fa30ed6853f243b;
    /// @dev wAXPx: AMERICAN EXPRESS COMPANY / US DOLLAR (Equity.US.AXP/USD), the share's feed.
    bytes32 internal constant WAXPX = 0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710;
    /// @dev wAZNx: ASTRAZENECA PLC / US DOLLAR (Equity.US.AZN/USD), the share's feed.
    bytes32 internal constant WAZNX = 0x7fb3b27d9039f8ca0a435fe0fdf724a3a5a2309ab62ad07ca775e5ab2100c1be;
    /// @dev wBACx: BANK OF AMERICA CORPORATION / US DOLLAR (Equity.US.BAC/USD), the share's feed.
    bytes32 internal constant WBACX = 0x21debc1718a4b76ff74dadf801c261d76c46afaafb74d9645b65e00b80f5ee3e;
    /// @dev wBKNGx: BOOKING HOLDINGS INC / US DOLLAR (Equity.US.BKNG/USD), the share's feed.
    bytes32 internal constant WBKNGX = 0xe90b679a7e4ca0d591abb634959d38a535c2036c6b121c520a82cff111ff7d12;
    /// @dev wBLKx: BLACKROCK INC / US DOLLAR (Equity.US.BLK/USD), the share's feed.
    bytes32 internal constant WBLKX = 0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08;
    /// @dev wBLSHx: BULLISH / US DOLLAR (Equity.US.BLSH/USD), the share's feed.
    bytes32 internal constant WBLSHX = 0xdf68956522c14482f38841a1105220f9e32c35e48a3fd517cc955a4580ab1cae;
    /// @dev wBMNRx: BITMINE IMMERSION TECHNOLOGIES INC / US DOLLAR (Equity.US.BMNR/USD), the share's feed.
    bytes32 internal constant WBMNRX = 0x54e2e127c93950de5a710100fd1cd387aba1ec8920850efdb05da5fee57d2e32;
    /// @dev wBRK.Bx: BERKSHIRE HATHAWAY INC CLASS B / US DOLLAR (Equity.US.BRK-B/USD), the share's feed.
    bytes32 internal constant WBRKBX = 0xe21c688b7fc65b4606a50f3635f466f6986db129bf16979875d160f9c508e8c7;
    /// @dev wBTBTx: BIT DIGITAL INC / US DOLLAR (Equity.US.BTBT/USD), the share's feed.
    bytes32 internal constant WBTBTX = 0xff62267568a8f48ec7b1805eb989a8c96da713b335caf20275def485da7984c9;
    /// @dev wCLSKx: CLEANSPARK INC (Equity.US.CLSK/USD), the share's feed.
    bytes32 internal constant WCLSKX = 0x79e935bc10c55f2c36a08df1564afc5b33425c8dc80829dd954c67e63ed3374a;
    /// @dev wCMCSAx: COMCAST CORPORATION / US DOLLAR (Equity.US.CMCSA/USD), the share's feed.
    bytes32 internal constant WCMCSAX = 0x1bd6720eea4df323c076c9bbc1e98e8f5fe4bd16584e56468c5fb6b1a6072725;
    /// @dev wCOINx: COINBASE XSTOCK / US DOLLAR (Crypto.COINX/USD), the xStock's own feed.
    bytes32 internal constant WCOINX = 0x641435d5dffb5311140b480517c79986d8488d5cf08a11eec53b83ad02cab33f;
    /// @dev wCORZx: CORE SCIENTIFIC, INC / US DOLLAR (Equity.US.CORZ/USD), the share's feed.
    bytes32 internal constant WCORZX = 0x214fc87a8f0f5adc797fc1f7927e1040650366e8f943e20caf13ad0d6e806956;
    /// @dev wCOSTx: COSTCO WHOLESALE CORPORATION / US DOLLAR (Equity.US.COST/USD), the share's feed.
    bytes32 internal constant WCOSTX = 0x163f6a6406d65305e8e27965b9081ac79b0cf9529f0fcdc14fe37e65e3b6b5cb;
    /// @dev wCRCLx: CIRCLE XSTOCK / US DOLLAR (Crypto.CRCLX/USD), the xStock's own feed.
    bytes32 internal constant WCRCLX = 0xc13184461c0c80d98ffcd89be627c2220b94a96c7c67f0c4b16bc12fd3b17758;
    /// @dev wCRMx: SALESFORCE INC / US DOLLAR (Equity.US.CRM/USD), the share's feed.
    bytes32 internal constant WCRMX = 0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8;
    /// @dev wCRWDx: CROWDSTRIKE HOLDINGS INC / US DOLLAR (Equity.US.CRWD/USD), the share's feed.
    bytes32 internal constant WCRWDX = 0xbaed936d3c6c2e34104e92c6b015b97ce96adc5ab4f04230c1270e1162e7a270;
    /// @dev wCSCOx: CISCO SYSTEMS INC / US DOLLAR (Equity.US.CSCO/USD), the share's feed.
    bytes32 internal constant WCSCOX = 0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481;
    /// @dev wCVXx: CHEVRON CORPORATION / US DOLLAR (Equity.US.CVX/USD), the share's feed.
    bytes32 internal constant WCVXX = 0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5;
    /// @dev wDHRx: DANAHER CORPORATION / US DOLLAR (Equity.US.DHR/USD), the share's feed.
    bytes32 internal constant WDHRX = 0x725ae6c67201359f9601d6ee8228c821f0abc93fef5cc509acfcee3f7bc2a388;
    /// @dev wEBAYx: EBAY INC / US DOLLAR (Equity.US.EBAY/USD), the share's feed.
    bytes32 internal constant WEBAYX = 0x6264a259e2cc90dfd3207f5831949eced2da6bf53965834c9160e4ceb9240947;
    /// @dev wEXPEx: EXPEDIA GROUP INC / US DOLLAR (Equity.US.EXPE/USD), the share's feed.
    bytes32 internal constant WEXPEX = 0x1aed988d2a3349d64e8a34c0d71535e01d17bf6b80c4d99138288af251822552;
    /// @dev wFIGx: FIGMA INC / US DOLLAR (Equity.US.FIG/USD), the share's feed.
    bytes32 internal constant WFIGX = 0xe6af4d828b88cd3b40cb34686e61157d3fa37c1aa20ca2b99453aae62619b351;
    /// @dev wGLDx: GOLD XSTOCK / US DOLLAR (Crypto.GLDX/USD), the xStock's own feed.
    bytes32 internal constant WGLDX = 0xe7d1138d0083368634087268c64b7bea0b4101a6365f83915cba9e76a8364b96;
    /// @dev wGLXYx: GALAXY DIGITAL / US DOLLAR (Equity.US.GLXY/USD), the share's feed.
    bytes32 internal constant WGLXYX = 0x67e031d1723e5c89e4a826d80b2f3b41a91b05ef6122d523b8829a02e0f563aa;
    /// @dev wGMEx: GAMESTOP CORP. / US DOLLAR (Equity.US.GME/USD), the share's feed.
    bytes32 internal constant WGMEX = 0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6;
    /// @dev wGOOGLx: ALPHABET XSTOCK / US DOLLAR (Crypto.GOOGLX/USD), the xStock's own feed.
    bytes32 internal constant WGOOGLX = 0xb911b0329028cd0283e4259c33809d62942bd2716a58084e5f31d64c00b5424e;
    /// @dev wGSx: GOLDMAN SACHS GROUP INC / US DOLLAR (Equity.US.GS/USD), the share's feed.
    bytes32 internal constant WGSX = 0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554;
    /// @dev wHDx: HOME DEPOT INC / US DOLLAR (Equity.US.HD/USD), the share's feed.
    bytes32 internal constant WHDX = 0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5;
    /// @dev wHONx: HONEYWELL INTERNATIONAL INC / US DOLLAR (Equity.US.HON/USD), the share's feed.
    bytes32 internal constant WHONX = 0x107918baaaafb79cd9df1c8369e44ac21136d95f3ca33f2373b78f24ba1e3e6a;
    /// @dev wHOODx: ROBINHOOD XSTOCK / US DOLLAR (Crypto.HOODX/USD), the xStock's own feed.
    bytes32 internal constant WHOODX = 0xdd49a9ac6df5cbfa9d8fc6371f7ae927a74d5c6763c1c01b4220d70314c647f9;
    /// @dev wHSDTx: SOLANA CO / US DOLLAR (Equity.US.HSDT/USD), the share's feed.
    bytes32 internal constant WHSDTX = 0x0f62d775396f303a630eec361709b5eb3126a89e6a73820f3c356d3a9b33dd8f;
    /// @dev wHUTx: HUT 8 CORP. / US DOLLAR (Equity.US.HUT/USD), the share's feed.
    bytes32 internal constant WHUTX = 0xfb88ad7526f97f7ca6f43aaa7d3b620f412968db2cbcfac1e906362def8456f3;
    /// @dev wIBMx: INTERNATIONAL BUSINESS MACHINES CORP / US DOLLAR (Equity.US.IBM/USD), the share's feed.
    bytes32 internal constant WIBMX = 0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef;
    /// @dev wIEMGx: ISHARES CORE MSCI EMERGING MKTS ETF / US DOLLAR (Equity.US.IEMG/USD), the share's feed.
    bytes32 internal constant WIEMGX = 0x96b1207c795f31283f5e44c527a1db18cacfb68de745a0de326611b0b5af3fc3;
    /// @dev wIJRx: ISHARES CORE S&P SMALL-CAP ETF / US DOLLAR (Equity.US.IJR/USD), the share's feed.
    bytes32 internal constant WIJRX = 0xca0bac9d1826b4a222320f58d47ed66bdc95722124578ed50803674ccd99a775;
    /// @dev wINTCx: INTEL CORPORATION / US DOLLAR (Equity.US.INTC/USD), the share's feed.
    bytes32 internal constant WINTCX = 0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff;
    /// @dev wIWMx: ISHARES RUSSELL 2000 ETF / US DOLLAR (Equity.US.IWM/USD), the share's feed.
    bytes32 internal constant WIWMX = 0xeff690a187797aa225723345d4612abec0bf0cec1ae62347c0e7b1905d730879;
    /// @dev wJNJx: JOHNSON & JOHNSON / US DOLLAR (Equity.US.JNJ/USD), the share's feed.
    bytes32 internal constant WJNJX = 0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63;
    /// @dev wJPMx: JPMORGAN CHASE & CO / US DOLLAR (Equity.US.JPM/USD), the share's feed.
    bytes32 internal constant WJPMX = 0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e;
    /// @dev wKOx: COCA-COLA CO / US DOLLAR (Equity.US.KO/USD), the share's feed.
    bytes32 internal constant WKOX = 0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d;
    /// @dev wLINx: LINDE PLC / US DOLLAR (Equity.US.LIN/USD), the share's feed.
    bytes32 internal constant WLINX = 0x9146c5c900d9aea9579819cf50d1ae18b54dea58eea3c9a198102e4e458e652b;
    /// @dev wLLYx: ELI LILLY AND COMPANY / US DOLLAR (Equity.US.LLY/USD), the share's feed.
    bytes32 internal constant WLLYX = 0x70dcf5fd56553d0023693e4b590336a8c9bcfd0d98dd9f093b1f697820d98325;
    /// @dev wLULUx: LULULEMON ATHLETICA INC / US DOLLAR (Equity.US.LULU/USD), the share's feed.
    bytes32 internal constant WLULUX = 0x13a19eb6a936a8c7020fe675687979b44e991efbfb4d3d2ca91425ce57b9e6f8;
    /// @dev wMAx: MASTERCARD INCORPORATED / US DOLLAR (Equity.US.MA/USD), the share's feed.
    bytes32 internal constant WMAX = 0x639db3fe6951d2465bd722768242e68eb0285f279cb4fa97f677ee8f80f1f1c0;
    /// @dev wMARAx: MARATHON DIGITAL HOLDINGS INC / US DOLLAR (Equity.US.MARA/USD), the share's feed.
    bytes32 internal constant WMARAX = 0x0fc2ad77a9ab75bcbc3ebd7a9ff60facd08c517309e2d684baa979c910a0e43e;
    /// @dev wMCDx: MCDONALDS XSTOCK  / US DOLLAR (Crypto.MCDX/USD), the xStock's own feed.
    bytes32 internal constant WMCDX = 0x27cac3c00ed32285b8686611bbc4a654279c1ea11ab4dc90822c2edd20734bca;
    /// @dev wMDTx: MEDTRONIC PLC / US DOLLAR (Equity.US.MDT/USD), the share's feed.
    bytes32 internal constant WMDTX = 0x1d762c633d4166a8d061518e187047afda1868cc524990262d8144e39dbb815f;
    /// @dev wMETAx: META XSTOCK / US DOLLAR (Crypto.METAX/USD), the xStock's own feed.
    bytes32 internal constant WMETAX = 0xbf3e5871be3f80ab7a4d1f1fd039145179fb58569e159aee1ccd472868ea5900;
    /// @dev wMNSTx: MONSTER BEVERAGE CORPORATION / US DOLLAR (Equity.US.MNST/USD), the share's feed.
    bytes32 internal constant WMNSTX = 0x579e60cbba314226de0f602f770113aa007bf1786ee37b923800028dc203d1e5;
    /// @dev wMRKx: MERCK & CO INC / US DOLLAR (Equity.US.MRK/USD), the share's feed.
    bytes32 internal constant WMRKX = 0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46;
    /// @dev wMRVLx: MARVELL TECHNOLOGY INC / US DOLLAR (Equity.US.MRVL/USD), the share's feed.
    bytes32 internal constant WMRVLX = 0x7aef4e90557add5289266340ccd1e1aa7a225f1220206b07aaf98e53101ce116;
    /// @dev wMSFTx: MICROSOFT XSTOCK / US DOLLAR (Crypto.MSFTX/USD), the xStock's own feed.
    bytes32 internal constant WMSFTX = 0xbb723a70af731ab56b9a650eb7e8ac22b7bc07ea77f8670bd1fa9a37bf6df3f5;
    /// @dev wMSTRx: MICROSTRATEGY XSTOCK / US DOLLAR (Crypto.MSTRX/USD), the xStock's own feed.
    bytes32 internal constant WMSTRX = 0x53f95ba4e23ed15ea56083e2ee9a5eec48055d6f59033d4bb95f1ca2a2349c28;
    /// @dev wMUx: MICRON TECHNOLOGY XSTOCK / US DOLLAR (Crypto.MUX/USD), the xStock's own feed.
    bytes32 internal constant WMUX = 0x0ce20662c616102659948a2e6ccf7ce05c930366af42b71240086eafb7cfa860;
    /// @dev wNFLXx: NETFLIX INC XSTOCK / US DOLLAR (Crypto.NFLXX/USD), the xStock's own feed.
    bytes32 internal constant WNFLXX = 0x02a67e6184e6c9dd65e14745a2a80df8b2b3d2ca91b4b191404936003d9929ae;
    /// @dev wNVDAx: NVIDIA XSTOCK / US DOLLAR (Crypto.NVDAX/USD), the xStock's own feed.
    bytes32 internal constant WNVDAX = 0x4244d07890e4610f46bbde67de8f43a4bf8b569eebe904f136b469f148503b7f;
    /// @dev wNVOx: NOVO NORDISK AS / US DOLLAR (Equity.US.NVO/USD), the share's feed.
    bytes32 internal constant WNVOX = 0x8dde322496e031d942b9eee8ca769d618cd2e69b18196644369379f5a1e7c23d;
    /// @dev wOKLOx: OKLO INC / US DOLLAR (Equity.US.OKLO/USD), the share's feed.
    bytes32 internal constant WOKLOX = 0x0d283a095e94dff4d4e607614ed686eb53e548238fb3af231148c276ecefe83e;
    /// @dev wOPENx: OPENDOOR TECHNOLOGIES INC / US DOLLAR (Equity.US.OPEN/USD), the share's feed.
    bytes32 internal constant WOPENX = 0xb4ef19d348a726dad5a655bcac5fe6e09c83af142bf1006b45d0f9ca4d5a46b5;
    /// @dev wORCLx: ORACLE CORPORATION / US DOLLAR (Equity.US.ORCL/USD), the share's feed.
    bytes32 internal constant WORCLX = 0xe47ff732eaeb6b4163902bdee61572659ddf326511917b1423bae93fcdf3153c;
    /// @dev wPANWx: PALO ALTO NETWORKS INC / US DOLLAR (Equity.US.PANW/USD), the share's feed.
    bytes32 internal constant WPANWX = 0x3b00df0661ccb3109d11ff301c1aa4e88b8d647cb477b089ba225149e6e1b7bb;
    /// @dev wPEPx: PEPSICO INC / US DOLLAR (Equity.US.PEP/USD), the share's feed.
    bytes32 internal constant WPEPX = 0xbe230eddb16aad5ad273a85e581e74eb615ebf67d378f885768d9b047df0c843;
    /// @dev wPFEx: PFIZER INC / US DOLLAR (Equity.US.PFE/USD), the share's feed.
    bytes32 internal constant WPFEX = 0x0704ad7547b3dfee329266ee53276349d48e4587cb08264a2818288f356efd1d;
    /// @dev wPGx: PROCTER & GAMBLE CO / US DOLLAR (Equity.US.PG/USD), the share's feed.
    bytes32 internal constant WPGX = 0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4;
    /// @dev wPLx: PLANET LABS PBC / US DOLLAR (Equity.US.PL/USD), the share's feed.
    bytes32 internal constant WPLX = 0x562e632de00dd4ad4a70b024afc3e2a220c1b05116d58cf96089825303f94762;
    /// @dev wPLTRx: PALANTIR TECHNOLOGIES INC / US DOLLAR (Equity.US.PLTR/USD), the share's feed.
    bytes32 internal constant WPLTRX = 0x11a70634863ddffb71f2b11f2cff29f73f3db8f6d0b78c49f2b5f4ad36e885f0;
    /// @dev wPMx: PHILIP MORRIS INTERNATIONAL INC / US DOLLAR (Equity.US.PM/USD), the share's feed.
    bytes32 internal constant WPMX = 0xa32f875eb39e23f087ea0db141b00857630c2c5011bfbe53a2a4d186f37cb583;
    /// @dev wPYPLx: PAYPAL HOLDINGS INC / US DOLLAR (Equity.US.PYPL/USD), the share's feed.
    bytes32 internal constant WPYPLX = 0x773c3b11f6be58e8151966a9f5832696d8cd08884ccc43ac8965a7ebea911533;
    /// @dev wQQQx: NASDAQ XSTOCK / US DOLLAR (Crypto.QQQX/USD), the xStock's own feed.
    bytes32 internal constant WQQQX = 0x178a6f73a5aede9d0d682e86b0047c9f333ed0efe5c6537ca937565219c4054d;
    /// @dev wRBLXx: ROBLOX CORP / US DOLLAR (Equity.US.RBLX/USD), the share's feed.
    bytes32 internal constant WRBLXX = 0xd62134a195739141d0649991f11fe0f9cd9eb83fd890bc3ba41dfdd18c1a49f4;
    /// @dev wRIOTx: RIOT PLATFORMS INC / US DOLLAR (Equity.US.RIOT/USD), the share's feed.
    bytes32 internal constant WRIOTX = 0x46417522a59b245c5af35c33c13426d991b36514c4c85aaefe1cf787e7daad90;
    /// @dev wRKLBx: ROCKET LAB USA INC / US DOLLAR (Equity.US.RKLB/USD), the share's feed.
    bytes32 internal constant WRKLBX = 0x40589e289317e4fbd997b1a267606e20a1cc7c3e4689f9e5a5992957917816c8;
    /// @dev wSBETx: SHARPLINK GAMING INC / US DOLLAR (Equity.US.SBET/USD), the share's feed.
    bytes32 internal constant WSBETX = 0x6b5bedda9e9d6354c5b93659cba6747d21b527437022da6e5f32e3b53e485a04;
    /// @dev wSCHFx: SCHWAB INTL EQUITY ETF / US DOLLAR (Equity.US.SCHF/USD), the share's feed.
    bytes32 internal constant WSCHFX = 0x601671d8a16a9f456d9a16d0bf203dd80d5076cc95ddca29cb5c7f8024dbeba6;
    /// @dev wSLVx: ISHARES SILVER TRUST (Equity.US.SLV/USD), the share's feed.
    bytes32 internal constant WSLVX = 0x6fc08c9963d266069cbd9780d98383dabf2668322a5bef0b9491e11d67e5d7e7;
    /// @dev wSPCEx: VIRGIN GALACTIC HOLDINGS, INC / US DOLLAR (Equity.US.SPCE/USD), the share's feed.
    bytes32 internal constant WSPCEX = 0xfce02687a8a49f19f78f7f97bd686c779135221429206bbd8735d5ad4c782130;
    /// @dev wSPGIx: S&P GLOBAL INC / US DOLLAR (Equity.US.SPGI/USD), the share's feed.
    bytes32 internal constant WSPGIX = 0xe7268062e142570f97cfba327f14e3153d1d4d8f6a4f84e59b72940ee87ecdb9;
    /// @dev wSPYx: SP500 XSTOCK / US DOLLAR (Crypto.SPYX/USD), the xStock's own feed.
    bytes32 internal constant WSPYX = 0x2817b78438c769357182c04346fddaad1178c82f4048828fe0997c3c64624e14;
    /// @dev wSTRCx: STRATEGY VARIABLE RATE PERPETUAL STRETCH XSTOCK / US DOLLAR (Crypto.STRCX/USD), the xStock's
    ///      own feed.
    bytes32 internal constant WSTRCX = 0x5f5193ed44dd1f4b0732dbffa2e27caf953e16a2d911854c8c3766d8bc609a47;
    /// @dev wTx: AT&T INC / US DOLLAR (Equity.US.T/USD), the share's feed.
    bytes32 internal constant WTX = 0x63e9f918ab91507c3574cca011da4dccda30cf54d46124d03b70279142ff81f3;
    /// @dev wTEMx: TEMPUS AI INC / US DOLLAR (Equity.US.TEM/USD), the share's feed.
    bytes32 internal constant WTEMX = 0x79c4582b9dd2d5f9a32c54654f3db995353a0e57a8094bacb8fb55a7190ca9a3;
    /// @dev wTGTx: TARGET CORPORATION / US DOLLAR (Equity.US.TGT/USD), the share's feed.
    bytes32 internal constant WTGTX = 0x13537ceb2df5af0b8cdf8032561b0a71430b51297375bbfdc6ed209df1da0d65;
    /// @dev wTMOx: THERMO FISHER SCIENTIFIC INC / US DOLLAR (Equity.US.TMO/USD), the share's feed.
    bytes32 internal constant WTMOX = 0x244fdf268ed7ecfad2cf84529c46d0fcef7a643428ff4ef8b16e8dbb63e0f2d9;
    /// @dev wTMUSx: T-MOBILE US INC / US DOLLAR (Equity.US.TMUS/USD), the share's feed.
    bytes32 internal constant WTMUSX = 0x0b231ca4307d25e4600067bfb06f576474bcabd74fb50eeaa0906ac1b457f365;
    /// @dev wTQQQx: PROSHARES ULTRAPRO QQQ / US DOLLAR (Equity.US.TQQQ/USD), the share's feed.
    bytes32 internal constant WTQQQX = 0x5aa9f82dc2e0f5f8271fd163e980010101517da59f4b72b71c7056a5950b2f9d;
    /// @dev wTSLAx: TESLA XSTOCK / US DOLLAR (Crypto.TSLAX/USD), the xStock's own feed.
    bytes32 internal constant WTSLAX = 0x47a156470288850a440df3a6ce85a55917b813a19bb5b31128a33a986566a362;
    /// @dev wTSMx: TAIWAN SEMICONDUCTOR MANUFACTURING CO LIMITED / US DOLLAR (Equity.US.TSM/USD), the share's feed.
    bytes32 internal constant WTSMX = 0xe722560a66e4ab00522ef20a38fa2ba5d1b41f1c5404723ed895d202a7af7cc4;
    /// @dev wUBERx: UBER TECHNOLOGIES INC / US DOLLAR (Equity.US.UBER/USD), the share's feed.
    bytes32 internal constant WUBERX = 0xc04665f62a0eabf427a834bb5da5f27773ef7422e462d40c7468ef3e4d39d8f1;
    /// @dev wUNHx: UNITEDHEALTH GROUP INC / US DOLLAR (Equity.US.UNH/USD), the share's feed.
    bytes32 internal constant WUNHX = 0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd;
    /// @dev wVx: VISA INC / US DOLLAR (Equity.US.V/USD), the share's feed.
    bytes32 internal constant WVX = 0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90;
    /// @dev wVSTx: VISTRA CORP / US DOLLAR (Equity.US.VST/USD), the share's feed.
    bytes32 internal constant WVSTX = 0x665d46c8142ca4486ebcdcfc0bbb913dee5255e0be63b6f971933620a7f69045;
    /// @dev wVTx: VANGUARD TOTAL WORLD STOCK INDEX ETF / US DOLLAR (Equity.US.VT/USD), the share's feed.
    bytes32 internal constant WVTX = 0xb167b163565d841b1477cb942bf3b2d28214f3eedf343de7536d6e5b6250d45b;
    /// @dev wVTIx: VANGUARD TOTAL STOCK MKT ETF / US DOLLAR (Equity.US.VTI/USD), the share's feed.
    bytes32 internal constant WVTIX = 0x26c67e91769aeba33a09469c705a1863794014dac416e4270661f489309ae862;
    /// @dev wWENx: WENDY'S CO / US DOLLAR (Equity.US.WEN/USD), the share's feed.
    bytes32 internal constant WWENX = 0xc6101ee4f14af5581a3995438bf0e80a574dd28fd497685988b526ae9ba34749;
    /// @dev wWMTx: WALMART INC / US DOLLAR (Equity.US.WMT/USD), the share's feed.
    bytes32 internal constant WWMTX = 0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc;
    /// @dev wWULFx: TERAWULF INC / US DOLLAR (Equity.US.WULF/USD), the share's feed.
    bytes32 internal constant WWULFX = 0x7717b73c7f19ffb1e6e5da542836fa3464559ec971df475455471433a005e2a6;
    /// @dev wXOMx: EXXON MOBIL CORPORATION / US DOLLAR (Equity.US.XOM/USD), the share's feed.
    bytes32 internal constant WXOMX = 0x4a1a12070192e8db9a89ac235bb032342a390dde39389b4ee1ba8e41e7eae5d8;
}
