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
///         closed or is closing, so the copy would be priced as a coin it no longer redeems for.
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
    /// @dev ALPHABET INC CLASS C / US DOLLAR (Equity.US.GOOG/USD): US market hours only.
    bytes32 internal constant GOOGON = 0xe65ff435be42630439c96396653a342829e877e2aafaeaf1a10d0ee5fd2cf3f2;
    /// @dev ISHARES CORE S&P 500 ETF / US DOLLAR (Equity.US.IVV/USD): US market hours only.
    bytes32 internal constant IVVON = 0x5967c196ca33171a0b2d140ddc6334b998dd71c2ddd85ba7920c35fd6ed20fe9;
    /// @dev PYTH PRICE IN USD FOR SPY 24/7 (Equity.Index.SPY/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant SPYON = 0xf32c3fbdd20b846bb53395bf175c42955e00b1bffb5a778bb624982b318f5461;
    /// @dev VANGUARD TOTAL STOCK MKT ETF / US DOLLAR (Equity.US.VTI/USD): US market hours only.
    bytes32 internal constant VTION = 0x26c67e91769aeba33a09469c705a1863794014dac416e4270661f489309ae862;
    /// @dev EXXON MOBIL CORPORATION / US DOLLAR (Equity.US.XOM/USD): US market hours only.
    bytes32 internal constant XOMON = 0x4a1a12070192e8db9a89ac235bb032342a390dde39389b4ee1ba8e41e7eae5d8;
    /// @dev JOHNSON & JOHNSON / US DOLLAR (Equity.US.JNJ/USD): US market hours only.
    bytes32 internal constant JNJON = 0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63;
    /// @dev MASTERCARD INCORPORATED / US DOLLAR (Equity.US.MA/USD): US market hours only.
    bytes32 internal constant MAON = 0x639db3fe6951d2465bd722768242e68eb0285f279cb4fa97f677ee8f80f1f1c0;
    /// @dev ASML HOLDING NV / US DOLLAR (Equity.US.ASML/USD): US market hours only.
    bytes32 internal constant ASMLON = 0x1a6e324589a0e355919fb1c0389edc3fdf4c46034626bd82aad4e47714cfa94f;
    /// @dev ABBVIE INC / US DOLLAR (Equity.US.ABBV/USD): US market hours only.
    bytes32 internal constant ABBVON = 0x019ae7cb58ee716ebdd1288b057373d60224fc98a9a43ee373c6b0df1f3ffdf5;
    /// @dev COSTCO WHOLESALE CORPORATION / US DOLLAR (Equity.US.COST/USD): US market hours only.
    bytes32 internal constant COSTON = 0x163f6a6406d65305e8e27965b9081ac79b0cf9529f0fcdc14fe37e65e3b6b5cb;
    /// @dev PYTH PRICE IN USD FOR QQQ 24/7 (Equity.Index.QQQ/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant QQQON = 0x6d595efb30db0e0139f254eb40985c8695e7ed7e5856287cb5084d2d7794b7eb;
    /// @dev COCA-COLA CO / US DOLLAR (Equity.US.KO/USD): US market hours only.
    bytes32 internal constant KOON = 0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d;
    /// @dev CHEVRON CORPORATION / US DOLLAR (Equity.US.CVX/USD): US market hours only.
    bytes32 internal constant CVXON = 0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5;
    /// @dev PROCTER & GAMBLE CO / US DOLLAR (Equity.US.PG/USD): US market hours only.
    bytes32 internal constant PGON = 0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4;
    /// @dev PYTH PRICE IN USD FOR PALANTIR 24/7 (Equity.Index.PLTR/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant PLTRON = 0x52c7c6b70032b7151c8d0febf684f14318e1e13315976e171267639955400bb9;
    /// @dev CISCO SYSTEMS INC / US DOLLAR (Equity.US.CSCO/USD): US market hours only.
    bytes32 internal constant CSCOON = 0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481;
    /// @dev PYTH PRICE IN USD FOR ORACLE 24/7 (Equity.Index.ORCL/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant ORCLON = 0x98aacad2adc9ffa8949da73015a5b623b0c062bd7f07b6f4dfda244b9b672c39;
    /// @dev GENERAL ELECTRIC COMPANY / US DOLLAR (Equity.US.GE/USD): US market hours only.
    bytes32 internal constant GEON = 0xe1d3115c6e7ac649faca875b3102f1000ab5e06b03f6903e0d699f0f5315ba86;
    /// @dev BANK OF AMERICA CORPORATION / US DOLLAR (Equity.US.BAC/USD): US market hours only.
    bytes32 internal constant BACON = 0x21debc1718a4b76ff74dadf801c261d76c46afaafb74d9645b65e00b80f5ee3e;
    /// @dev HOME DEPOT INC / US DOLLAR (Equity.US.HD/USD): US market hours only.
    bytes32 internal constant HDON = 0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5;
    /// @dev MERCK & CO INC / US DOLLAR (Equity.US.MRK/USD): US market hours only.
    bytes32 internal constant MRKON = 0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46;
    /// @dev PYTH PRICE IN USD FOR INTEL 24/7 (Equity.Index.INTC/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant INTCON = 0xcecbc86ad1adfa72b78b573375dc36eb4664e096252c0a3e55e625ea838685f1;
    /// @dev UNITEDHEALTH GROUP INC / US DOLLAR (Equity.US.UNH/USD): US market hours only.
    bytes32 internal constant UNHON = 0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd;
    /// @dev PALO ALTO NETWORKS INC / US DOLLAR (Equity.US.PANW/USD): US market hours only.
    bytes32 internal constant PANWON = 0x3b00df0661ccb3109d11ff301c1aa4e88b8d647cb477b089ba225149e6e1b7bb;
    /// @dev APPLIED MATERIALS INC / US DOLLAR (Equity.US.AMAT/USD): US market hours only.
    bytes32 internal constant AMATON = 0xb9bc74cc1243b706efacf664ed206d08ab1dda79e8b87752c7c44b3bdf1b9e08;
    /// @dev LAM RESEARCH CORPORATION / US DOLLAR (Equity.US.LRCX/USD): US market hours only.
    bytes32 internal constant LRCXON = 0x01a67883f58bd0f0e9cf8f52f21d7cf78c144d7e7ae32ce9256420834b33fb75;
    /// @dev TEXAS INSTRUMENTS INCORPORATED / US DOLLAR (Equity.US.TXN/USD): US market hours only.
    bytes32 internal constant TXNON = 0xc5b94c7ece9c3ac984e1439a8fac86270d0f988bbbcc838b456e2d7311754bdc;
    /// @dev RTX CORPORATION / US DOLLAR (Equity.US.RTX/USD): US market hours only.
    bytes32 internal constant RTXON = 0x97c483cc4172de7ac1a3cc0814f442e4747e64008723f2705d6e9fdff3ba4d3d;
    /// @dev THERMO FISHER SCIENTIFIC INC / US DOLLAR (Equity.US.TMO/USD): US market hours only.
    bytes32 internal constant TMOON = 0x244fdf268ed7ecfad2cf84529c46d0fcef7a643428ff4ef8b16e8dbb63e0f2d9;
    /// @dev CROWDSTRIKE HOLDINGS INC / US DOLLAR (Equity.US.CRWD/USD): US market hours only.
    bytes32 internal constant CRWDON = 0xbaed936d3c6c2e34104e92c6b015b97ce96adc5ab4f04230c1270e1162e7a270;
    /// @dev CATERPILLAR INC. / US DOLLAR (Equity.US.CAT/USD): US market hours only.
    bytes32 internal constant CATON = 0xad04597ba688c350a97265fcb60585d6a80ebd37e147b817c94f101a32e58b4c;
    /// @dev GOLDMAN SACHS GROUP INC / US DOLLAR (Equity.US.GS/USD): US market hours only.
    bytes32 internal constant GSON = 0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554;
    /// @dev ARISTA NETWORKS INC / US DOLLAR (Equity.US.ANET/USD): US market hours only.
    bytes32 internal constant ANETON = 0x31cc7558642dc348a3e2894146a998031438de8ccc56b7af2171bcd5e5d83eda;
    /// @dev NETFLIX INC / US DOLLAR (Equity.US.NFLX/USD): US market hours only.
    bytes32 internal constant NFLXON = 0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2;
    /// @dev WELLS FARGO & COMPANY / US DOLLAR (Equity.US.WFC/USD): US market hours only.
    bytes32 internal constant WFCON = 0x67ac585d05128c7b6a88660be04acd18b2bddd6308e98b71b9f3ba0f0e781296;
    /// @dev SAP SE (Equity.US.SAP/USD): US market hours only.
    bytes32 internal constant SAPON = 0x0ee2e3f1c7689e1abf957009f747228a30b47678c8e5844cb033cbcf790fa20b;
    /// @dev AMGEN, INC. / US DOLLAR (Equity.US.AMGN/USD): US market hours only.
    bytes32 internal constant AMGNON = 0x10946973bfcc936b423d52ee2c5a538d96427626fe6d1a7dae14b1c401d1e794;
    /// @dev LINDE PLC / US DOLLAR (Equity.US.LIN/USD): US market hours only.
    bytes32 internal constant LINON = 0x9146c5c900d9aea9579819cf50d1ae18b54dea58eea3c9a198102e4e458e652b;
    /// @dev INTERNATIONAL BUSINESS MACHINES CORP / US DOLLAR (Equity.US.IBM/USD): US market hours only.
    bytes32 internal constant IBMON = 0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef;
    /// @dev PYTH PRICE IN USD FOR ALIBABA 24/7 (Equity.Index.BABA/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant BABAON = 0xe18423cdff0e892a5338bad2047550d21ceb7f3c13ba6dfa6911c63326451c44;
    /// @dev AMERICAN EXPRESS COMPANY / US DOLLAR (Equity.US.AXP/USD): US market hours only.
    bytes32 internal constant AXPON = 0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710;
    /// @dev WALT DISNEY CO / US DOLLAR (Equity.US.DIS/USD): US market hours only.
    bytes32 internal constant DISON = 0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0;
    /// @dev GE VERNOVA INC / US DOLLAR (Equity.US.GEV/USD): US market hours only.
    bytes32 internal constant GEVON = 0x57e28b0f0ab18923f5c987629c0c714b9b46c87e729ed95ed6e23e466e8d1e0c;
    /// @dev DELL TECHNOLOGIES INC / US DOLLAR (Equity.US.DELL/USD): US market hours only.
    bytes32 internal constant DELLON = 0xa2950270a22ce39a22cb3488ba91e60474cd93c6d01da2ecc5a97c1dd40f4995;
    /// @dev ARM HOLDINGS PLC / US DOLLAR (Equity.US.ARM/USD): US market hours only.
    bytes32 internal constant ARMON = 0x957bf692b35cc62f222dbf4dc6929130df42fe17c9f03373f44c01f78b05391e;
    /// @dev CITIGROUP INC / US DOLLAR (Equity.US.C/USD): US market hours only.
    bytes32 internal constant CON = 0xe7e7aac1ac0524cd3666fae4ecafae5e1fee880c11f3a7b4b7ea61bd6e434a63;
    /// @dev AMPHENOL CORPORATION / US DOLLAR (Equity.US.APH/USD): US market hours only.
    bytes32 internal constant APHON = 0xd0723436221cd8ca5f2f11c38920271d77950e7ed0cec1a764459b465cb88651;
    /// @dev MCDONALD'S CORP / US DOLLAR (Equity.US.MCD/USD): US market hours only.
    bytes32 internal constant MCDON = 0xd3178156b7c0f6ce10d6da7d347952a672467b51708baaf1a57ffe1fb005824a;
    /// @dev KLA CORPORATION / US DOLLAR (Equity.US.KLAC/USD): US market hours only.
    bytes32 internal constant KLACON = 0x9c27675f282bfe54b5d0a7b187b29b09184d32d4462de7e3060629c7b8895aad;
    /// @dev PEPSICO INC / US DOLLAR (Equity.US.PEP/USD): US market hours only.
    bytes32 internal constant PEPON = 0xbe230eddb16aad5ad273a85e581e74eb615ebf67d378f885768d9b047df0c843;
    /// @dev VANGUARD VALUE ETF / US DOLLAR (Equity.US.VTV/USD): US market hours only.
    bytes32 internal constant VTVON = 0x1105e1af4587e6555349533492904782f6a4d0dc6b828938e98e1715b6b32315;
    /// @dev VERIZON COMMUNICATIONS INC / US DOLLAR (Equity.US.VZ/USD): US market hours only.
    bytes32 internal constant VZON = 0x6672325a220c0ee1166add709d5ba2e51c185888360c01edc76293257ef68b58;
    /// @dev ANALOG DEVICES INC / US DOLLAR (Equity.US.ADI/USD): US market hours only.
    bytes32 internal constant ADION = 0xa388977cbd7b063e456a31267919d86395af058a7558e892dde3c6b38c6240bb;
    /// @dev ISHARES CORE MSCI EAFE ETF / US DOLLAR (Equity.US.IEFA/USD): US market hours only.
    bytes32 internal constant IEFAON = 0x3e959410e8daa7941a4d2179332a3ab1d38e78dd8d83134996e65a3f4352f828;
    /// @dev ABBOTT LABORATORIES / US DOLLAR (Equity.US.ABT/USD): US market hours only.
    bytes32 internal constant ABTON = 0x4aac40f432e039ab06236eb9bd3c58347f953d8f05b29aaac295b99cc47ee429;
    /// @dev BLACKROCK INC / US DOLLAR (Equity.US.BLK/USD): US market hours only.
    bytes32 internal constant BLKON = 0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08;
    /// @dev QUALCOMM INCORPORATED / US DOLLAR (Equity.US.QCOM/USD): US market hours only.
    bytes32 internal constant QCOMON = 0x54350ebf587c3f14857efcfec50e5c4f6e10220770c2266e9fe85bd5e42e4022;
    /// @dev SHOPIFY INC / US DOLLAR (Equity.US.SHOP/USD): US market hours only.
    bytes32 internal constant SHOPON = 0xc9034e8c405ba92888887bc76962b619d0f8e8bf3e12aba972af0cf64e814d5d;
    /// @dev NEXTERA ENERGY INC / US DOLLAR (Equity.US.NEE/USD): US market hours only.
    bytes32 internal constant NEEON = 0xb058f7874b57f820aa7ff6034a8515add8095b5831e83fc8d02c1dccd4ac099c;
    /// @dev UNION PACIFIC CORPORATION / US DOLLAR (Equity.US.UNP/USD): US market hours only.
    bytes32 internal constant UNPON = 0xb095647f688415d4102a858e1b25c1af15750f0e516a0d561cb35ebe30deb183;
    /// @dev NOVO NORDISK AS / US DOLLAR (Equity.US.NVO/USD): US market hours only.
    bytes32 internal constant NVOON = 0x8dde322496e031d942b9eee8ca769d618cd2e69b18196644369379f5a1e7c23d;
    /// @dev T-MOBILE US INC / US DOLLAR (Equity.US.TMUS/USD): US market hours only.
    bytes32 internal constant TMUSON = 0x0b231ca4307d25e4600067bfb06f576474bcabd74fb50eeaa0906ac1b457f365;
    /// @dev DEERE & COMPANY / US DOLLAR (Equity.US.DE/USD): US market hours only.
    bytes32 internal constant DEON = 0xc2d23f236142a519929b147c4dbe8720475724918c8b8473db0283f8cf044184;
    /// @dev THE CHARLES SCHWAB CORPORATION / US DOLLAR (Equity.US.SCHW/USD): US market hours only.
    bytes32 internal constant SCHWON = 0xd437b2f1470d5f007f18a5565eaab1ed182d97204d80b7dd3dac29839f61c9e6;
    /// @dev CONOCOPHILLIPS / US DOLLAR (Equity.US.COP/USD): US market hours only.
    bytes32 internal constant COPON = 0xd54d8d4e3774ea53660e660ecd03aa9daa31eed9b7e67d1a2aed3095b3e6720d;
    /// @dev PFIZER INC / US DOLLAR (Equity.US.PFE/USD): US market hours only.
    bytes32 internal constant PFEON = 0x0704ad7547b3dfee329266ee53276349d48e4587cb08264a2818288f356efd1d;
    /// @dev SALESFORCE INC / US DOLLAR (Equity.US.CRM/USD): US market hours only.
    bytes32 internal constant CRMON = 0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8;
    // Corrected 2026-11-22: the listing of 2026-11-19 took Crypto.TON/USD, Toncoin's, for this token's own feed.
    /// @dev AT&T INC / US DOLLAR (Equity.US.T/USD): US market hours only.
    bytes32 internal constant TON = 0x63e9f918ab91507c3574cca011da4dccda30cf54d46124d03b70279142ff81f3;
    /// @dev INTUITIVE SURGICAL INC / US DOLLAR (Equity.US.ISRG/USD): US market hours only.
    bytes32 internal constant ISRGON = 0xad4dc1db82c47e0822afef9d9eca7bf693cdad20dd61fcd5aa1b6895b1b90190;
    /// @dev ISHARES CORE US AGGREGATE BOND ETF / US DOLLAR (Equity.US.AGG/USD): US market hours only.
    bytes32 internal constant AGGON = 0x66e2456d8f7fae8b1421538b10c868b89a6e23b727f290ac062cc6809c96ea9a;
    /// @dev ISHARES CORE MSCI EMERGING MKTS ETF / US DOLLAR (Equity.US.IEMG/USD): US market hours only.
    bytes32 internal constant IEMGON = 0x96b1207c795f31283f5e44c527a1db18cacfb68de745a0de326611b0b5af3fc3;
    /// @dev UBER TECHNOLOGIES INC / US DOLLAR (Equity.US.UBER/USD): US market hours only.
    bytes32 internal constant UBERON = 0xc04665f62a0eabf427a834bb5da5f27773ef7422e462d40c7468ef3e4d39d8f1;
    /// @dev VERTEX PHARMACEUTICALS INCORPORATED / US DOLLAR (Equity.US.VRTX/USD): US market hours only.
    bytes32 internal constant VRTXON = 0xac9de86ae3dcff03514bde733f5793f1446b2cd31f1539a1c449acc3e76cacc1;
    /// @dev LOCKHEED MARTIN CORP / US DOLLAR (Equity.US.LMT/USD): US market hours only.
    bytes32 internal constant LMTON = 0x880d96a272d5ccbb3cd6f6aacb881a996cb4976b3f252b58c595cd2a418b6ea9;
    /// @dev PYTH PRICE IN USD FOR MARVELL 24/7 (Equity.Index.MRVL/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant MRVLON = 0x84cabacd3323b6e9accca97366beea9fc21260e6c0b7830848e9e1259bc5cef2;
    /// @dev EATON CORPORATION PLC / US DOLLAR (Equity.US.ETN/USD): US market hours only.
    bytes32 internal constant ETNON = 0xb1cf984febc32fbd98f0c5d31fed29d050d56a272406bae9de64dd94ba7e5e1e;
    /// @dev ACCENTURE PLC / US DOLLAR (Equity.US.ACN/USD): US market hours only.
    bytes32 internal constant ACNON = 0x68848984b74a7766ad23cdccd8e78e9ef339dcfb86b7e96990f27447c20967ed;
    /// @dev S&P GLOBAL INC / US DOLLAR (Equity.US.SPGI/USD): US market hours only.
    bytes32 internal constant SPGION = 0xe7268062e142570f97cfba327f14e3153d1d4d8f6a4f84e59b72940ee87ecdb9;
    /// @dev APPLOVIN CORPORATION / US DOLLAR (Equity.US.APP/USD): US market hours only.
    bytes32 internal constant APPON = 0x54f128939505878cf4412abc5a533255ce07e85833849170deb67deff0533aa7;
    /// @dev BOEING CO / US DOLLAR (Equity.US.BA/USD): US market hours only.
    bytes32 internal constant BAON = 0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae;
    /// @dev SEAGATE TECHNOLOGY HOLDINGS PLC / US DOLLAR (Equity.US.STX/USD): US market hours only.
    bytes32 internal constant STXON = 0x0b7fc35cea4acfa65e49a718292e0b31b453072e3af39afbfd2925da5c3ab65d;
    /// @dev SOUTHERN COPPER / US DOLLAR (Equity.US.SCCO/USD): US market hours only.
    bytes32 internal constant SCCOON = 0xa00be224b07426d688475926b6a7a8b007f1420734629b596ae6132c75bc5976;
    /// @dev PDD HOLDINGS INC / US DOLLAR (Equity.US.PDD/USD): US market hours only.
    bytes32 internal constant PDDON = 0xae69f62081eb15ae4f077397871a1cf29cacf75e7b1db740aed9074c1efd3fa4;
    /// @dev SPDR GOLD SHARES ETF / US DOLLAR (Equity.US.GLD/USD): US market hours only.
    bytes32 internal constant GLDON = 0xe190f467043db04548200354889dfe0d9d314c08b8d4e62fabf4d5a3140fecca;
    /// @dev LOWE'S COMPANIES INC / US DOLLAR (Equity.US.LOW/USD): US market hours only.
    bytes32 internal constant LOWON = 0xab31ec9dbcacacfb26e5ea6c249d69f5ae8b9c691aac6ccc5919b6107efa1c3a;
    /// @dev SPOTIFY TECHNOLOGY SA (Equity.US.SPOT/USD): US market hours only.
    bytes32 internal constant SPOTON = 0x547ef6a2ea7db9baf50788876d3c062facaecfc896d898f37ba12efd0a13383a;
    /// @dev STARBUCKS CORPORATION / US DOLLAR (Equity.US.SBUX/USD): US market hours only.
    bytes32 internal constant SBUXON = 0x86cd9abb315081b136afc72829058cf3aaf1100d4650acb2edb6a8e39f03ef75;
    /// @dev ISHARES CORE S&P MID-CAP ETF / US DOLLAR (Equity.US.IJH/USD): US market hours only.
    bytes32 internal constant IJHON = 0xab4b0a2fad7f23125a7a94eec46204fcf1ba69bb81d32778db0ba3e66df6772a;
    /// @dev ISHARES 0-3 MONTH TREASURY BOND ETF / US DOLLAR (Equity.US.SGOV/USD): US market hours only.
    bytes32 internal constant SGOVON = 0x8d6a29bb5ed522931d711bb12c4bbf92af986936e52af582032913b5ffcbf4d5;
    /// @dev WESTERN DIGITAL CORPORATION / US DOLLAR (Equity.US.WDC/USD): US market hours only.
    bytes32 internal constant WDCON = 0x37a782cf9bb6061d4cca34a419fb1ae5a8edf71ae8843206ea88b4ba696d4706;
    /// @dev PYTH PRICE IN USD FOR SANDISK 24/7 (Equity.Index.SNDK/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant SNDKON = 0x9a972ccd0df577006dda1679dc39e00f370e330c318f21bdcb34e83fa5a70002;
    /// @dev ISHARES RUSSELL 1000 GROWTH ETF / US DOLLAR (Equity.US.IWF/USD): US market hours only.
    bytes32 internal constant IWFON = 0xefc46125a2063f8662815a3c5d78f20aa0c4e6dde0862364a6f5d2f47d862ac1;
    /// @dev CLOUDFLARE INC / US DOLLAR (Equity.US.NET/USD): US market hours only.
    bytes32 internal constant NETON = 0xd3a9e76862950b2f21a7037fd64df913794b14d0e2938a9d383b0b7387ca0081;
    /// @dev CAPITAL ONE FINANCIAL CORPORATION / US DOLLAR (Equity.US.COF/USD): US market hours only.
    bytes32 internal constant COFON = 0x857c3a552953250d5b19db7341f3deaed12ff623f2db451e30581c266b23ab58;
    /// @dev THE SOUTHERN COMPANY / US DOLLAR (Equity.US.SO/USD): US market hours only.
    bytes32 internal constant SOON = 0x650293cd51d63cac28ecb03823af05d8192dad724156af6ed4a90b1708057bf2;
    /// @dev PETROLEO BRASILEIRO S.A.-PETROBRAS ADS (REP 1 COMMON SHARE) / US DOLLAR
    ///      (Equity.US.PBR/USD): US market hours only.
    bytes32 internal constant PBRON = 0x146f8290eb9b56e6e19338902f7b975e7f9e50f9fe40b35a127c6ee7992f5102;
    /// @dev NEWMONT CORPORATION / US DOLLAR (Equity.US.NEM/USD): US market hours only.
    bytes32 internal constant NEMON = 0x29caf4d900d3080e56306ac41a9856735b89cb4df6813dd7b83e9eb96c04700d;
    /// @dev AIRBNB INC / US DOLLAR (Equity.US.ABNB/USD): US market hours only.
    bytes32 internal constant ABNBON = 0xccab508da0999d36e1ac429391d67b3ac5abf1900978ea1a56dab6b1b932168e;
    /// @dev ENBRIDGE, INC / US DOLLAR (Equity.US.ENB/USD): US market hours only.
    bytes32 internal constant ENBON = 0x5ede535f959e6184f24815c1d7819ab8bf79d850afbd73151bc994e1935de686;
    /// @dev EQUINIX INC / US DOLLAR (Equity.US.EQIX/USD): US market hours only.
    bytes32 internal constant EQIXON = 0x66eb6cfa3a28e8e7cad538a55872ac0e41a2741ca66a29c1dc5540f2b1fb6fb6;
    /// @dev SNOWFLAKE INC (Equity.US.SNOW/USD): US market hours only.
    bytes32 internal constant SNOWON = 0x14291d2651ecf1f9105729bdc59553c1ce73fb3d6c931dd98a9d2adddc37e00f;
    /// @dev REGENERON PHARMACEUTICALS INC / US DOLLAR (Equity.US.REGN/USD): US market hours only.
    bytes32 internal constant REGNON = 0x2a45d16204f3588259fddf5a81a1129efab873571a4cef38641e16bfeac364ef;
    /// @dev SERVICENOW INC / US DOLLAR (Equity.US.NOW/USD): US market hours only.
    bytes32 internal constant NOWON = 0x69d2eebcc3c62889f1c0105ff347f296eb435cba8d2e4705a486fd47a8fe1a1b;
    /// @dev CORNING INCORPORATED / US DOLLAR (Equity.US.GLW/USD): US market hours only.
    bytes32 internal constant GLWON = 0x6ef62b860055ef6819af274064e5aa597aa9d0963ce3109c51d996264844776e;
    /// @dev WASTE MANAGEMENT INC / US DOLLAR (Equity.US.WM/USD): US market hours only.
    bytes32 internal constant WMON = 0x7f78c101ca799a5b63f5e5c1e56a43b3a361233900160c172e2ec2980e91b4eb;
    /// @dev GENERAL DYNAMICS CORPORATION / US DOLLAR (Equity.US.GD/USD): US market hours only.
    bytes32 internal constant GDON = 0x894e9c429f83fe4f35fda679568348418bafe5a0a68e1cccc8e51a137e879ce9;
    /// @dev ISHARES CORE S&P TOTAL US STOCK MKT ETF / US DOLLAR (Equity.US.ITOT/USD): US market hours only.
    bytes32 internal constant ITOTON = 0xde7279ce7d805c43c4893239b77aa07525df93c9f8ede0bd8b3d87609dd80415;
    /// @dev CONSTELLATION ENERGY CORPORATION / US DOLLAR (Equity.US.CEG/USD): US market hours only.
    bytes32 internal constant CEGON = 0xa541bc5c4b69961442e45e9198c7cce151ff9c2a1003f620c6d4a9785c77a4d9;
    /// @dev QUANTA SERVICES INC / US DOLLAR (Equity.US.PWR/USD): US market hours only.
    bytes32 internal constant PWRON = 0xa189b9eee6d023e3b79a726804aeb748d54e52cf6ebcebe0f7d5c8dae4988357;
    /// @dev TRANE TECHNOLOGIES PLC / US DOLLAR (Equity.US.TT/USD): US market hours only.
    bytes32 internal constant TTON = 0x0c9385e9109703f9cef4872dc1d6abaa7a630c1b524757141f79d42159768307;
    /// @dev EMERSON ELECTRIC CO / US DOLLAR (Equity.US.EMR/USD): US market hours only.
    bytes32 internal constant EMRON = 0xe1c0e5aaf1842d3efb806d14a7cd21160d4b7c0f96746e0fa1227ae961bf3929;
    /// @dev ADOBE INC / US DOLLAR (Equity.US.ADBE/USD): US market hours only.
    bytes32 internal constant ADBEON = 0xdf82dc88ea742bb42bdb845e5fc3ca4eef2354c67357d338221e8a696891b4ca;
    /// @dev INTUIT INC / US DOLLAR (Equity.US.INTU/USD): US market hours only.
    bytes32 internal constant INTUON = 0x43ef64ff6af44e0648f0328ee56e88fee57943b0aa077c24ef175bb9ecd37133;
    /// @dev THE WILLIAMS COMPANIES INC / US DOLLAR (Equity.US.WMB/USD): US market hours only.
    bytes32 internal constant WMBON = 0x6921035babdc51587962f9a1350a2c2ca5840b64bbf9057ab75a20cc663b32c3;
    /// @dev CARVANA CO CL A / US DOLLAR (Equity.US.CVNA/USD): US market hours only.
    bytes32 internal constant CVNAON = 0x8cbd009149f28a8f19d01de7f31d85d48c7f2d35a9ae40c03930712d84fbd92a;
    /// @dev MODERNA INC / US DOLLAR (Equity.US.MRNA/USD): US market hours only.
    bytes32 internal constant MRNAON = 0x4083b0b1471123cf4d3e8edee7890940cafad866f06cadae638c23e555a1f4fc;
    /// @dev NORTHROP GRUMMAN CORPORATION / US DOLLAR (Equity.US.NOC/USD): US market hours only.
    bytes32 internal constant NOCON = 0x5f848f61c44e1c9b21ddac0fcac5536344e80ad21df3271c2f069f57229fab81;
    /// @dev VERTIV HOLDINGS CO (Equity.US.VRT/USD): US market hours only.
    bytes32 internal constant VRTON = 0x84dad6b760396a7904d04a3d83039a3fc18f10819fd97d023ac5535997d70108;
    /// @dev ISHARES MSCI EAFE ETF / US DOLLAR (Equity.US.EFA/USD): US market hours only.
    bytes32 internal constant EFAON = 0x3b7ef6c95ceedbffbb66bff3d6135a200c5d0a0466b0c90812510ceaedebaf04;
    /// @dev ISHARES RUSSELL 2000 ETF / US DOLLAR (Equity.US.IWM/USD): US market hours only.
    bytes32 internal constant IWMON = 0xeff690a187797aa225723345d4612abec0bf0cec1ae62347c0e7b1905d730879;
    /// @dev FREEPORT-MCMORAN INC / US DOLLAR (Equity.US.FCX/USD): US market hours only.
    bytes32 internal constant FCXON = 0x2b5735ead9b057b3fb96a422740ab26bdfcb1f2b5d4cd9d052f45311ef0f2952;
    /// @dev SCHLUMBERGER LIMITED / US DOLLAR (Equity.US.SLB/USD): US market hours only.
    bytes32 internal constant SLBON = 0x8042b087e06b64b7a40056782d48c8add189943d8354c56726e655f46e65320f;
    /// @dev DOORDASH INC / US DOLLAR (Equity.US.DASH/USD): US market hours only.
    bytes32 internal constant DASHON = 0xaf9f76555c0147ec660100ff1639eb128e48c4f16b0aec229b736c04e082de23;
    /// @dev APOLLO GLOBAL MANAGEMENT INC / US DOLLAR (Equity.US.APO/USD): US market hours only.
    bytes32 internal constant APOON = 0x40176a5dd12a53bb1f31e848c9363863dd6f8e755f35ef56d2182fc7f1d03853;
    /// @dev MERCADOLIBRE INC / US DOLLAR (Equity.US.MELI/USD): US market hours only.
    bytes32 internal constant MELION = 0x5c149158ad0cca240ab13e45d93f43d7eb747a25acf5a9313b5b03c0aa87251b;
    /// @dev NETEASE INC ADR / US DOLLAR (Equity.US.NTES/USD): US market hours only.
    bytes32 internal constant NTESON = 0x664fc65e3f9ffb458e7144959ed8d5c86e923eb7ca283efeadb79bd6c1e4b9ce;
    /// @dev ROBINHOOD ONDO TOKENIZED STOCK / US DOLLAR (Crypto.HOODON/USD): the Ondo token's own feed.
    bytes32 internal constant HOODON = 0x8d61af9bd7c39d9503d7d99b7e9e59cc7b0bd707341ecc3ed3e3eda1a411f4de;
    /// @dev HEWLETT PACKARD ENTERPRISE COMPANY / US DOLLAR (Equity.US.HPE/USD): US market hours only.
    bytes32 internal constant HPEON = 0x069b87074893c37fd250990df7409d7e19cd649bea8e28904a0fd49915f4e53a;
    /// @dev TE CONNECTIVITY PLC / US DOLLAR (Equity.US.TEL/USD): US market hours only.
    bytes32 internal constant TELON = 0x5cbf183213af0c63f896b908770e684cb0dfb6634e42bd6e8ea7b273eb61a342;
    /// @dev NUCOR CORPORATION / US DOLLAR (Equity.US.NUE/USD): US market hours only.
    bytes32 internal constant NUEON = 0x7e535de06269b98ea0dfd8b238b80254a41be0092acf72c4464b269cd500716e;
    /// @dev ISHARES GOLD TRUST / US DOLLAR (Equity.US.IAU/USD): US market hours only.
    bytes32 internal constant IAUON = 0xf703fbded84f7da4bd9ff4661b5d1ffefa8a9c90b7fa12f247edc8251efac914;
    /// @dev AMETEK INC / US DOLLAR (Equity.US.AME/USD): US market hours only.
    bytes32 internal constant AMEON = 0x79adceba85771f08b71af57b027e0cf98a040738bca2a70ed3f89736a718f77c;
    /// @dev OCCIDENTAL PETROLEUM CORPORATION / US DOLLAR (Equity.US.OXY/USD): US market hours only.
    bytes32 internal constant OXYON = 0x54ba7b095dfa286f556cd41d4bfefe956ebd4df3d9eec8fe0188d0727f07e344;
    /// @dev BLOOM ENERGY CORP (Equity.US.BE/USD): US market hours only.
    bytes32 internal constant BEON = 0xa955f59cec6006d55ac21ab009c92662f2d9250bc22b86fcce16e7962c129c4f;
    /// @dev NIKE INC / US DOLLAR (Equity.US.NKE/USD): US market hours only.
    bytes32 internal constant NKEON = 0x67649450b4ca4bfff97cbaf96d2fd9e40f6db148cb65999140154415e4378e14;
    /// @dev LUMENTUM HLDGS INC COM (Equity.US.LITE/USD): US market hours only.
    bytes32 internal constant LITEON = 0xfd7141d35093fb93e84d82507cc6a97775fe263bd8ecd8b7e2b940a6ae487979;
    /// @dev KEYSIGHT TECHNOLOGIES INC / US DOLLAR (Equity.US.KEYS/USD): US market hours only.
    bytes32 internal constant KEYSON = 0x0a89d9c67435e8563fbf1bd1d3da9578fd07edfc2af55e92acf532cc9951a90a;
    /// @dev ISHARES BITCOIN TRUST / US DOLLAR (Equity.US.IBIT/USD): US market hours only.
    bytes32 internal constant IBITON = 0x9db6bc1e6e9e5e60f6884e1cd8e4399cca9d0454c6e7234ad79680cf139748f5;
    /// @dev SPDR BLOOMBERG 1-3 MONTH T-BILL ETF / US DOLLAR (Equity.US.BIL/USD): US market hours only.
    bytes32 internal constant BILON = 0x6050efb3d94369697e5cdebf4b7a14f0f503bf8cd880e24ef85f9fbc0a68feb2;
    /// @dev PAYPAL HOLDINGS INC / US DOLLAR (Equity.US.PYPL/USD): US market hours only.
    bytes32 internal constant PYPLON = 0x773c3b11f6be58e8151966a9f5832696d8cd08884ccc43ac8965a7ebea911533;
    /// @dev ISHARES 20+ YEAR TREASURY BOND ETF / US DOLLAR (Equity.US.TLT/USD): US market hours only.
    bytes32 internal constant TLTON = 0x9f383d612ac09c7e6ffda24deca1502fce72e0ba58ff473fea411d9727401cc1;
    /// @dev BLOCK INC / US DOLLAR (Equity.US.XYZ/USD): US market hours only.
    bytes32 internal constant XYZON = 0x6d64b1981512c242162d6ba54f6bda35c59f726f2e075a42994fc9a33c6c2d55;
    /// @dev CHIPOTLE MEXICAN GRILL INC / US DOLLAR (Equity.US.CMG/USD): US market hours only.
    bytes32 internal constant CMGON = 0xc1046358a2b78d92a2ad45b9d3c271350ab9335b478df21a390b8924cad91563;
    /// @dev FORD MOTOR COMPANY / US DOLLAR (Equity.US.F/USD): US market hours only.
    bytes32 internal constant FON = 0x6c267962d46cec4a5baf6105de67ef08e1306f75973ce6eb8db8527f06e28f33;
    /// @dev COHERENT CORP / US DOLLAR (Equity.US.COHR/USD): US market hours only.
    bytes32 internal constant COHRON = 0xfae9f16801d1249999bf7a9e6e57ae7b512f88cce663251da2dee9fadddfc31a;
    /// @dev NOKIA OYJ / US DOLLAR (Equity.US.NOK/USD): US market hours only.
    bytes32 internal constant NOKON = 0xff1717bc1de364c8473f9c1928dad930a9ecc952d91f26133a7f94eb03166316;
    /// @dev NATERA INC / US DOLLAR (Equity.US.NTRA/USD): US market hours only.
    bytes32 internal constant NTRAON = 0xb21a229944b7008c9e0efeb591030198acd5a676e7c84c3a13927af9764456b0;
    /// @dev ISHARES 7-10 YEAR TREASURY BOND ETF / US DOLLAR (Equity.US.IEF/USD): US market hours only.
    bytes32 internal constant IEFON = 0x034626d18bc711c55c71e27319f8851f483bc08a7f97be2dee9ea8f7ccd59248;
    /// @dev VISTRA CORP / US DOLLAR (Equity.US.VST/USD): US market hours only.
    bytes32 internal constant VSTON = 0x665d46c8142ca4486ebcdcfc0bbb913dee5255e0be63b6f971933620a7f69045;
    /// @dev ROCKWELL AUTOMATION INC / US DOLLAR (Equity.US.ROK/USD): US market hours only.
    bytes32 internal constant ROKON = 0xc531c5d85ae89ad23e0f455be0a9170e2924a4b6922d62d5b1e076023f7b7235;
    /// @dev ISHARES SEMICONDUCTOR ETF / US DOLLAR (Equity.US.SOXX/USD): US market hours only.
    bytes32 internal constant SOXXON = 0x3c3973e95c24fab3808a8fd9f25fb06ee92422fea20d814c1a850b307cbf31b9;
    /// @dev ISHARES U.S. EQUITY FACTOR ROTATION ACTIVE ETF / US DOLLAR (Equity.US.DYNF/USD): US market hours only.
    bytes32 internal constant DYNFON = 0x14aed40d5a17de04d65a0a54e956f6bce322122e621d8278300331ab02deb6e7;
    /// @dev STMICROELECTRONICS N.V. / US DOLLAR (Equity.US.STM/USD): US market hours only.
    bytes32 internal constant STMON = 0x46a20d321a432ff821d19bc459c7c6170efef48cb8244dff075d63c90e551481;
    /// @dev TAKE-TWO INTERACTIVE SOFTWARE INC / US DOLLAR (Equity.US.TTWO/USD): US market hours only.
    bytes32 internal constant TTWOON = 0x782a6a261306f01ab2ad004062a2832107360eefdcf8c83223e0ff7ca7ebde8d;
    /// @dev CIENA CORP / US DOLLAR (Equity.US.CIEN/USD): US market hours only.
    bytes32 internal constant CIENON = 0xa1227a13d6b81354acdff9ae22a1878ee0dcdc2668e0a3f8c15700ddf5d50fbb;
    /// @dev ASTERA LABS INC (Equity.US.ALAB/USD): US market hours only.
    bytes32 internal constant ALABON = 0xa2c896238e03d8126369b445ed0157a9cfaccf095510a68b9100beb8885c0e47;
    /// @dev MICROSTRATEGY ONDO TOKENIZED STOCK / US DOLLAR (Crypto.MSTRON/USD): the Ondo token's own feed.
    bytes32 internal constant MSTRON = 0x89a131faf74b5298981e3d25bbce60a25c6f452004da31ddd3c5805cdaa9b6ab;
    /// @dev VANGUARD REAL ESTATE ETF / US DOLLAR (Equity.US.VNQ/USD): US market hours only.
    bytes32 internal constant VNQON = 0x1feb5bc35d3a601d1e39c4d1dd65de285a04f5e7923fdaba1d87359d8c14a9ae;
    /// @dev TERADYNE INC / US DOLLAR (Equity.US.TER/USD): US market hours only.
    bytes32 internal constant TERON = 0x58ab181e7512766728d2cc3581839bbb913e6cd24457ba422cbe2a33df64416e;
    /// @dev ROCKET LAB USA INC / US DOLLAR (Equity.US.RKLB/USD): US market hours only.
    bytes32 internal constant RKLBON = 0x40589e289317e4fbd997b1a267606e20a1cc7c3e4689f9e5a5992957917816c8;
    /// @dev UNITED MICROELECTRONICS CORPORATION (Equity.US.UMC/USD): US market hours only.
    bytes32 internal constant UMCON = 0x63d83a9822f1098d7ff7eddc94a156b4e45d6fb43cbcbd1030dd0262ad0fea3d;
    /// @dev JD.COM INC / US DOLLAR (Equity.US.JD/USD): US market hours only.
    bytes32 internal constant JDON = 0x4c45e26d5253283ab4736b4f4ba9d0e6517679f8425ef07722dacc4b6da90750;
    /// @dev JANUS HENDERSON AAA CLO ETF / US DOLLAR (Equity.US.JAAA/USD): US market hours only.
    bytes32 internal constant JAAAON = 0x01ce9758cabc32e7344032cc921433cdf194a31c2e4b11e42d6fc3217cc94871;
    /// @dev CELESTICA INC / US DOLLAR (Equity.US.CLS/USD): US market hours only.
    bytes32 internal constant CLSON = 0x5b1adfefbe3f69cf8c5dc02d521a9f49eb5887d19f4bf1f4170959428d9d6a21;
    /// @dev STEEL DYNAMICS INC / US DOLLAR (Equity.US.STLD/USD): US market hours only.
    bytes32 internal constant STLDON = 0x3bc436e6c024059b3493e4332b32d0cbdd2b8ecf84544261838137eb1f299525;
    /// @dev EQT CORPORATION / US DOLLAR (Equity.US.EQT/USD): US market hours only.
    bytes32 internal constant EQTON = 0xad81a87631f8ab7f09897d7001e46e206afa727c419d93f31591a8edefdf37cb;
    /// @dev PYTH PRICE IN USD FOR NEBIUS 24/7 (Equity.Index.NBIS/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant NBISON = 0xc8d8050cde18920d0274f296a7589620c67a9898a73c93d0a91fddde6f3cdf6b;
    /// @dev INSMED INC / US DOLLAR (Equity.US.INSM/USD): US market hours only.
    bytes32 internal constant INSMON = 0x48a9a69fa2947734f12d1840c51d36fc30be106fc40c624054faec9783463831;
    /// @dev PG&E CORPORATION / US DOLLAR (Equity.US.PCG/USD): US market hours only.
    bytes32 internal constant PCGON = 0x026e4a35b33c438e4c75b2bf8f5f8298b26165eff133b1da2b4559985ecab11e;
    /// @dev COINBASE ONDO TOKENIZED STOCK / US DOLLAR (Crypto.COINON/USD): the Ondo token's own feed.
    bytes32 internal constant COINON = 0x8c56635a4257942fabf7ce5dd861dbe91375c370e6b5feac3fb8ba7206a30e46;
    /// @dev PROSHARES ULTRAPRO QQQ / US DOLLAR (Equity.US.TQQQ/USD): US market hours only.
    bytes32 internal constant TQQQON = 0x5aa9f82dc2e0f5f8271fd163e980010101517da59f4b72b71c7056a5950b2f9d;
    /// @dev ISHARES MSCI EAFE VALUE ETF (Equity.US.EFV/USD): US market hours only.
    bytes32 internal constant EFVON = 0x21fff87cf866f73c13887a254ec2395e178967fcc8c6a5a6471c26392119c82d;
    /// @dev FLEXTRONICS INTERNATIONAL LTD / US DOLLAR (Equity.US.FLEX/USD): US market hours only.
    bytes32 internal constant FLEXON = 0x68799c6196bad6e233c747cfa4a92897a88375268b406a81ca47df277e839d50;
    /// @dev ISHARES 1-3 YEAR TREASURY BOND ETF / US DOLLAR (Equity.US.SHY/USD): US market hours only.
    bytes32 internal constant SHYON = 0xa48b0216da455c8f33edc75d5c82290f63180a41646df873b393450bb3218c0c;
    /// @dev VERISIGN INC / US DOLLAR (Equity.US.VRSN/USD): US market hours only.
    bytes32 internal constant VRSNON = 0xc7ae3c077945639c2e0ed7199d1e6655f8c76027e07bccea53d9b6f79d8075fd;
    /// @dev CAMECO CORP / US DOLLAR (Equity.US.CCJ/USD): US market hours only.
    bytes32 internal constant CCJON = 0x8c92b96bf7ec66766d7400f91eee36370df38ec751ec48933396760f8c73cc78;
    /// @dev COREWEAVE INC (Equity.US.CRWV/USD): US market hours only.
    bytes32 internal constant CRWVON = 0x2a78b78189d6d6eff30a825e4698fd14a0b1ca659bb0079bb7e80521c0e8c75d;
    /// @dev TRIPCOM GROUP LTD (Equity.US.TCOM/USD): US market hours only.
    bytes32 internal constant TCOMON = 0x37527d726792538d5b968b8d5777044cda4413f7814e24978d9a3a9094157c2b;
    /// @dev ISHARES MSCI EMERGING MARKETS ETF / US DOLLAR (Equity.US.EEM/USD): US market hours only.
    bytes32 internal constant EEMON = 0xd407e68cec58205be82a6140a668dc42f8d9079bcf3be4aa4b41f41f7b983035;
    /// @dev ON SEMICONDUCTOR CORPORATION / US DOLLAR (Equity.US.ON/USD): US market hours only.
    bytes32 internal constant ONON = 0x35f08f92f05ab4fd2117f8d857238f5eb25213fefe95e7ba042babea512a0a5b;
    /// @dev HALLIBURTON COMPANY / US DOLLAR (Equity.US.HAL/USD): US market hours only.
    bytes32 internal constant HALON = 0x8ecca7012d5cd82620c1222acd6296cb4a34fea7dae4bf93bc51ddc471830a53;
    /// @dev COUPANG INC - CLASS A / US DOLLAR (Equity.US.CPNG/USD): US market hours only.
    bytes32 internal constant CPNGON = 0x5557d206aa0dd037fc082f03bbd78653f01465d280ea930bc93251f0eb60c707;
    /// @dev JABIL INC / US DOLLAR (Equity.US.JBL/USD): US market hours only.
    bytes32 internal constant JBLON = 0xd8226a5920c7fbfe9bf9b159ab25855fb07c66b28c0941c1d36b247e382add95;
    /// @dev BAIDU INC (Equity.US.BIDU/USD): US market hours only.
    bytes32 internal constant BIDUON = 0x9bdee8cb689424d01f6eaf7217adfcff65b51a30774a77fff8006c21c7059350;
    /// @dev CREDO TECHNOLOGY GROUP HOLDING LTD (Equity.US.CRDO/USD): US market hours only.
    bytes32 internal constant CRDOON = 0x70223a069575a95493bd4a473c47554ac8b333af557e2264eb0d0236e2838fc2;
    /// @dev CEREBRAS SYSTEMS / US DOLLAR (Equity.US.CBRS/USD): US market hours only.
    bytes32 internal constant CBRSON = 0x7b6809a00a53228f74622e4909750c0d86a2081032955e02c8e3503b1b93829a;
    /// @dev ISHARES SILVER TRUST (Equity.US.SLV/USD): US market hours only.
    bytes32 internal constant SLVON = 0x6fc08c9963d266069cbd9780d98383dabf2668322a5bef0b9491e11d67e5d7e7;
    /// @dev HUBBELL INCORPORATED / US DOLLAR (Equity.US.HUBB/USD): US market hours only.
    bytes32 internal constant HUBBON = 0x492f2b794efb3721b4243406d73cf68f34097b103ba690d0dbcafddb5a10cb7e;
    /// @dev ISHARES US TECHNOLOGY ETF / US DOLLAR (Equity.US.IYW/USD): US market hours only.
    bytes32 internal constant IYWON = 0xb4279985dec1ff91bc9bd6d8b44ed96da6f0446cfca6bc613d23296182f4fdcf;
    /// @dev ISHARES MSCI JAPAN ETF / US DOLLAR (Equity.US.EWJ/USD): US market hours only.
    bytes32 internal constant EWJON = 0x73560d1ee6daf7f322314d58dd8d0eed720fffcab390c1c1d54b5088d92497a2;
    /// @dev GLOBALFOUNDRIES INC / US DOLLAR (Equity.US.GFS/USD): US market hours only.
    bytes32 internal constant GFSON = 0x8cbec525dd085e025e7a4cb0fa5041a9db203ff0ed5919d9f14e61fff8bfe062;
    /// @dev ENTEGRIS INC COM / US DOLLAR (Equity.US.ENTG/USD): US market hours only.
    bytes32 internal constant ENTGON = 0xe552acc27d7d790ea13d79a37a1da3e9bdf52630f3056a97a15660653f3f50f7;
    /// @dev WISDOMTREE FLOATING RATE TREASURY FUND / US DOLLAR (Equity.US.USFR/USD): US market hours only.
    bytes32 internal constant USFRON = 0x98b3bc80a9e8ea755e29ef29575c3de9d5ae8213450c66e8f0759d5a7c0d8aad;
    /// @dev PYTH PRICE IN USD FOR EWY 24/7 (Equity.Index.EWY/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant EWYON = 0x2a7acae7e6da804f5857d10040693e42fb345203a974fff725caa1f0b1998357;
    /// @dev SKYWORKS SOLUTIONS INC / US DOLLAR (Equity.US.SWKS/USD): US market hours only.
    bytes32 internal constant SWKSON = 0x431349b17e1ee2605695615baffd31e44290477089c02536bb2926dfa36850b8;
    /// @dev SOFI TECHNOLOGIES INC (Equity.US.SOFI/USD): US market hours only.
    bytes32 internal constant SOFION = 0x72fae0e0683c186f5ce9444afac9909cf5d60b499f4f9569dd75442f19c625c8;
    /// @dev ISHARES IBOXX $ HIGH YIELD CORPORATE BOND ETF / US DOLLAR (Equity.US.HYG/USD): US market hours only.
    bytes32 internal constant HYGON = 0x2077043ee3b67b9a70949c8396c110f6cf43de8e6d9e6efdcbd557a152cf2c6e;
    /// @dev NVENT ELEC PLC SHS / US DOLLAR (Equity.US.NVT/USD): US market hours only.
    bytes32 internal constant NVTON = 0x20bae488aba426a5825ce76b2be9706787ffcdd685d5e1b1778acb0d3db1664f;
    /// @dev REDDIT INC / US DOLLAR (Equity.US.RDDT/USD): US market hours only.
    bytes32 internal constant RDDTON = 0xc0ece6b9254797f4384bda1ba3f2c33259f552c7849a86b3029e811be5ea9227;
    /// @dev MACOM TECH SOLUTIONS HLDGS INC COM / US DOLLAR (Equity.US.MTSI/USD): US market hours only.
    bytes32 internal constant MTSION = 0x6d1085fb5e5bd8f830a47d6d2cf38af3ed0415e208a5d8f717b01d1674b89bea;
    /// @dev RIVIAN AUTOMOTIVE INC / US DOLLAR (Equity.US.RIVN/USD): US market hours only.
    bytes32 internal constant RIVNON = 0x1e59e3164331ce560683eae0c69efe9650ff1bc834225772ddb330aa808f72f0;
    /// @dev LATTICE SEMICONDUCTOR CORP / US DOLLAR (Equity.US.LSCC/USD): US market hours only.
    bytes32 internal constant LSCCON = 0x134837b42e99cde7e5b85cc795dd06a658326098c35bd298274763619b577121;
    /// @dev SUPER MICRO COMPUTER INC / US DOLLAR (Equity.US.SMCI/USD): US market hours only.
    bytes32 internal constant SMCION = 0x8f34132a42f8bb7a47568d77a910f97174a30719e16904e9f2915d5b2c6c2d52;
    /// @dev TALEN ENERGY CORP / US DOLLAR (Equity.US.TLN/USD): US market hours only.
    bytes32 internal constant TLNON = 0x05ff869230bb56bf2df26342880f6a2b9cab2f2eb4c1b59f00ec38e405d65db0;
    /// @dev WESCO INTERNATIONAL INC / US DOLLAR (Equity.US.WCC/USD): US market hours only.
    bytes32 internal constant WCCON = 0xab550fd8d8635e32090a5ed31d7e4fd182df26e479cfa679ac31e8b9578cad3b;
    /// @dev TOWER SEMICONDUCTOR LTD. (Equity.US.TSEM/USD): US market hours only.
    bytes32 internal constant TSEMON = 0xcf3f93bef4432759b7e0224e33604df001963c8660a64551dbd90fd38c3a6a9c;
    /// @dev LINCOLN ELEC HLDGS INC COM / US DOLLAR (Equity.US.LECO/USD): US market hours only.
    bytes32 internal constant LECOON = 0xa08f897997f4223014aea76709b4236f2d89c132e6f45373ed65e029805cd9fc;
    /// @dev MKS INC / US DOLLAR (Equity.US.MKSI/USD): US market hours only.
    bytes32 internal constant MKSION = 0x43c438c61f1500581a1f05b5932548c9d8b7881e69d49b4b931e89d960af0601;
    /// @dev ISHARES TIPS BOND ETF / US DOLLAR (Equity.US.TIP/USD): US market hours only.
    bytes32 internal constant TIPON = 0x8acba411efb415896ba97afbb6995385ab25e7056422f239c9e513f1acfc9aca;
    /// @dev CIRCLE INTERNET GROUP ONDO TOKENIZED STOCK / US DOLLAR (Crypto.CRCLON/USD): the Ondo token's own feed.
    bytes32 internal constant CRCLON = 0x25edf380836977c4fea6d1e8df3567192c4e11deeeb566c8e0bd8022068860df;
    /// @dev MASTEC INC COM / US DOLLAR (Equity.US.MTZ/USD): US market hours only.
    bytes32 internal constant MTZON = 0x82d6544c7729f245a15798f5abdc407cebf1fd93bfcc811a76b26873a47fe004;
    /// @dev ISHARES RUSSELL 2000 VALUE ETF / US DOLLAR (Equity.US.IWN/USD): US market hours only.
    bytes32 internal constant IWNON = 0xa8b8aec1b1b1e492b14570d24fe63fcd98aec1a648570c4543afa286eca4dc3e;
    /// @dev PYTH PRICE IN USD FOR GAMESTOP 24/7 (Equity.Index.GME/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant GMEON = 0xd54eccd2ce6b1fa72125abe1f88866470320fa44960fa1d1cf8761f9cfca8def;
    /// @dev PYTH PRICE IN USD FOR SOXL 24/7 (Equity.Index.SOXL/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant SOXLON = 0x5b4183fbbab47c0508c39db436e6b0a0376e50650e79c9f836677a04d65d592f;
    /// @dev GLOBAL X US INFRA DEVELOPMENTS UCITS ETF USD ACC / US DOLLAR (Equity.US.PAVE/USD): US market hours only.
    bytes32 internal constant PAVEON = 0x4c2e4cf5dc8426f6e54d0de8020d2a7e9b6754b7089bd71a75cf6b3da46e747e;
    /// @dev FUTU HOLDINGS LTD / US DOLLAR (Equity.US.FUTU/USD): US market hours only.
    bytes32 internal constant FUTUON = 0xe6d51d83a2d18919bf5c57604bf3bf581d65efe34d232ba1d0ef33eca03c983f;
    /// @dev ISHARES EXPANDED TECH-SOFTWARE SECTOR ETF / US DOLLAR (Equity.US.IGV/USD): US market hours only.
    bytes32 internal constant IGVON = 0x43b0e3663be6fe9e5f098eb3b2826f053d182682944717cb0f8c57b04db90867;
    /// @dev GRAB HOLDINGS LTD (Equity.US.GRAB/USD): US market hours only.
    bytes32 internal constant GRABON = 0xbe0e2b42aa0859682609decb790cd51832700fef549f59b5eb595221b6c3833c;
    /// @dev GENERAC HOLDINGS INC / US DOLLAR (Equity.US.GNRC/USD): US market hours only.
    bytes32 internal constant GNRCON = 0x27514c8e57a0fad5e095546852c0903319b66ab07f7526b5ac1540886d6d944e;
    /// @dev FABRINET / US DOLLAR (Equity.US.FN/USD): US market hours only.
    bytes32 internal constant FNON = 0x2132dbe12a6d7520b29553bafb7c81c178bcc7583112dec25aacfcac99b9049f;
    /// @dev ISHARES US AEROSPACE & DEFENSE ETF / US DOLLAR (Equity.US.ITA/USD): US market hours only.
    bytes32 internal constant ITAON = 0x79f7f0b79a6b7fdc0d7d9e8b6337fd709b8eea9dc6f57b6174c84816cae88bfd;
    /// @dev HUNTINGTON INGALLS INDUSTRIES INC / US DOLLAR (Equity.US.HII/USD): US market hours only.
    bytes32 internal constant HIION = 0x659c675091db659251f2077293bf9e71aef2c978dd729c2be66cec0d41c1d671;
    /// @dev IONQ INC (Equity.US.IONQ/USD): US market hours only.
    bytes32 internal constant IONQON = 0x6af68a227de372e5d19183679911e468e06d85c013f56c376a78a4d942f8f269;
    // Corrected 2026-11-22: the listing of 2026-11-19 took Crypto.LION/USD, a token called Loaded Lions, for this
    // token's own feed.
    /// @dev LI AUTO INC SPONSORED ADS / US DOLLAR (Equity.US.LI/USD): US market hours only.
    bytes32 internal constant LION = 0xb10d624c07226d795e9211c9ac95baf43b4a4234ac89cd319e3c72b20de92f99;
    /// @dev ALBEMARLE CORPORATION / US DOLLAR (Equity.US.ALB/USD): US market hours only.
    bytes32 internal constant ALBON = 0x4db91e379e36addcdb1cc75dcb03022bd95d5d95148c41d268348d12cbd27c18;
    /// @dev ONTO INNOVATION INC / US DOLLAR (Equity.US.ONTO/USD): US market hours only.
    bytes32 internal constant ONTOON = 0xc4db80e9a68aca4575714c9f5387368239d63965850a359b68b676355a799d7d;
    /// @dev PINTEREST, INC / US DOLLAR (Equity.US.PINS/USD): US market hours only.
    bytes32 internal constant PINSON = 0x05b0a4d52786320f28d1389ed8f236c3eca5854376431cfdf7ce37b6326402d2;
    /// @dev NOVA LTD. / US DOLLAR (Equity.US.NVMI/USD): US market hours only.
    bytes32 internal constant NVMION = 0x3e707ff33b5d0e1491423de340a4d15151d9a94f260eab441a88481dd3fcc4a4;
    /// @dev BITMINE IMMERSION TECHNOLOGIES INC / US DOLLAR (Equity.US.BMNR/USD): US market hours only.
    bytes32 internal constant BMNRON = 0x54e2e127c93950de5a710100fd1cd387aba1ec8920850efdb05da5fee57d2e32;
    /// @dev SNAP INC / US DOLLAR (Equity.US.SNAP/USD): US market hours only.
    bytes32 internal constant SNAPON = 0xa23dd397c4f7a2187d00c1973e58ff6e8a681658b1105d1bd42a8fccbbd068f7;
    /// @dev FIGMA INC / US DOLLAR (Equity.US.FIG/USD): US market hours only.
    bytes32 internal constant FIGON = 0xe6af4d828b88cd3b40cb34686e61157d3fa37c1aa20ca2b99453aae62619b351;
    /// @dev GLOBAL X AI & TECHNOLOGY ETF / US DOLLAR (Equity.US.AIQ/USD): US market hours only.
    bytes32 internal constant AIQON = 0x0e55d7b951e87860cf6188aea1626dc8dafb0d37ab716f815677bd5188d3a5b7;
    /// @dev AMKOR TECHNOLOGY INC / US DOLLAR (Equity.US.AMKR/USD): US market hours only.
    bytes32 internal constant AMKRON = 0xf8208ffb5822c912f596ac3df95514222eb1adaa0dd341408b41fed15821c414;
    /// @dev AMERICAN AIRLINES GROUP INC / US DOLLAR (Equity.US.AAL/USD): US market hours only.
    bytes32 internal constant AALON = 0xd5399c95ddc3219ab8b03bd51ca81560bc92a648950bf964eef67bfd9783654a;
    /// @dev RAMBUS INC / US DOLLAR (Equity.US.RMBS/USD): US market hours only.
    bytes32 internal constant RMBSON = 0x97100fdc597c8a56b5ed629c0b66dc4409c5839778e5c494c3a1d58081364f7b;
    /// @dev OSCAR HEALTH, INC / US DOLLAR (Equity.US.OSCR/USD): US market hours only.
    bytes32 internal constant OSCRON = 0x4af609fcabd2fc48ac3c17232d00dc6ecf8e6ca7f6561976826174c19240f0cc;
    /// @dev TWIST BIOSCIENCE CORP / US DOLLAR (Equity.US.TWST/USD): US market hours only.
    bytes32 internal constant TWSTON = 0x9721a76ee064f0f569cb19219c82de4278f033fb659abb1739c9008b6f66b64e;
    /// @dev PYTH PRICE IN USD FOR EWZ 24/7 (Equity.Index.EWZ/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant EWZON = 0x9fe0d98811d27c1f484d140a22b2a2cca6280d8ffb63a5c899432ff68293737b;
    /// @dev AST SPACEMOBILE INC / US DOLLAR (Equity.US.ASTS/USD): US market hours only.
    bytes32 internal constant ASTSON = 0x17f979e1f6b7c429e4b9ecee96633dbecdc5378566ddfd3d220b0ef8d874e4bd;
    /// @dev AURORA INNOVATION, INC / US DOLLAR (Equity.US.AUR/USD): US market hours only.
    bytes32 internal constant AURON = 0x91d942b363c77592a40d4590a96283e9ad95c55ec40a06f57d9a840229786715;
    /// @dev TTM TECHNOLOGIES INC / US DOLLAR (Equity.US.TTMI/USD): US market hours only.
    bytes32 internal constant TTMION = 0xf645c9aa24431545d435746258771dde072dd9d63f71f876b9d2c4d0eb573f84;
    /// @dev HUT 8 CORP. / US DOLLAR (Equity.US.HUT/USD): US market hours only.
    bytes32 internal constant HUTON = 0xfb88ad7526f97f7ca6f43aaa7d3b620f412968db2cbcfac1e906362def8456f3;
    /// @dev VICOR CORP / US DOLLAR (Equity.US.VICR/USD): US market hours only.
    bytes32 internal constant VICRON = 0x872c1525e06d841dab75d710af2b34feebb5a3547466ff712a655b52fcbe5d3c;
    /// @dev ISHARES MSCI INDIA ETF (Equity.US.INDA/USD): US market hours only.
    bytes32 internal constant INDAON = 0x207d13ab09f413c8855f5c14b7650a2235f37c60eb6274b8a3eb80c2b85fb81c;
    /// @dev CLEVELAND-CLIFFS INC / US DOLLAR (Equity.US.CLF/USD): US market hours only.
    bytes32 internal constant CLFON = 0x8f3a268ae8d3f99160d889c0ad05c5ccf926a67aa86ce530e76e82454e8b31c7;
    /// @dev NIO INC / US DOLLAR (Equity.US.NIO/USD): US market hours only.
    bytes32 internal constant NIOON = 0xc8916a12ca17ed0883e37a10c8962370fbd2878a35bb70f6902a0f52be73338c;
    /// @dev RIOT PLATFORMS INC / US DOLLAR (Equity.US.RIOT/USD): US market hours only.
    bytes32 internal constant RIOTON = 0x46417522a59b245c5af35c33c13426d991b36514c4c85aaefe1cf787e7daad90;
    /// @dev MP MATERIALS CORP / US DOLLAR (Equity.US.MP/USD): US market hours only.
    bytes32 internal constant MPON = 0x92e03dac647ec6733f61f208a89115ecee4442653736a66008032f4ae588f304;
    /// @dev FORMFACTOR INC / US DOLLAR (Equity.US.FORM/USD): US market hours only.
    bytes32 internal constant FORMON = 0x0e7569b870edec883f44b54ba4a63cb50bece2704a215448cadad7913ce5e1d6;
    /// @dev IREN LTD / US DOLLAR (Equity.US.IREN/USD): US market hours only.
    bytes32 internal constant IRENON = 0xba20f6d5532c07da494da803db2523719d339226e69ade6436e7d2f1047138a5;
    /// @dev TERAWULF INC / US DOLLAR (Equity.US.WULF/USD): US market hours only.
    bytes32 internal constant WULFON = 0x7717b73c7f19ffb1e6e5da542836fa3464559ec971df475455471433a005e2a6;
    /// @dev FORGENT POWER SOLUTIONS, INC / US DOLLAR (Equity.US.FPS/USD): US market hours only.
    bytes32 internal constant FPSON = 0xa98d4a82473c0a85d2416c185df4845ef8b1e7ed8606717ad1c4485c7a1b2840;
    /// @dev FIGURE TECHNOLOGY SOLUTIONS INC / US DOLLAR (Equity.US.FIGR/USD): US market hours only.
    bytes32 internal constant FIGRON = 0xed3eb3353fd34a90ee3613defda80c11ae2b58c04ddcfd4ff351c3c66e9629b3;
    /// @dev POWELL INDUSTRIES INC / US DOLLAR (Equity.US.POWL/USD): US market hours only.
    bytes32 internal constant POWLON = 0xdd3857f9265d3be5cecd44d80aca8e1e9c55a9127c971eb6ceac5e80a8ff8fea;
    /// @dev GLOBAL X DEFENSE TECH ETF / US DOLLAR (Equity.US.SHLD/USD): US market hours only.
    bytes32 internal constant SHLDON = 0x6b971ce35cfc0f144200bf5aa184863af1522312fad078fc6d5b7743501eae51;
    /// @dev FIRST MAJESTIC SILVER CORP / US DOLLAR (Equity.US.AG/USD): US market hours only.
    bytes32 internal constant AGON = 0x7f50344390e79dc231fc08c3789b2e332bdd344751bc18842ac53f953f44d7f2;
    /// @dev CARIS LIFE SCIENCES INC / US DOLLAR (Equity.US.CAI/USD): US market hours only.
    bytes32 internal constant CAION = 0x4de569a337968a84a8447e579aad7c4eef9be8106dfd8e807756bb19724c0650;
    /// @dev ISHARES ETHEREUM TRUST ETF (Equity.US.ETHA/USD): US market hours only.
    bytes32 internal constant ETHAON = 0x188bdefa94c2f8b3878ebcd98f65551dbc2091f250ae6780719184821b1a0e1c;
    /// @dev GLOBAL X COPPER MINERS ETF / US DOLLAR (Equity.US.COPX/USD): US market hours only.
    bytes32 internal constant COPXON = 0x8bbaca50510ba7108093fd89100523a01d4eee8087de21c9ca807292933e5479;
    /// @dev CORE SCIENTIFIC, INC / US DOLLAR (Equity.US.CORZ/USD): US market hours only.
    bytes32 internal constant CORZON = 0x214fc87a8f0f5adc797fc1f7927e1040650366e8f943e20caf13ad0d6e806956;
    /// @dev BILIBILI INC ADR / US DOLLAR (Equity.US.BILI/USD): US market hours only.
    bytes32 internal constant BILION = 0x006d336e4cd222530a057ed307c619af1379a4dedfc4839dcbab413df956fbaa;
    /// @dev MAXLINEAR INC. (Equity.US.MXL/USD): US market hours only.
    bytes32 internal constant MXLON = 0xbff80b6f6e2e1ec46691a50f83d61aba1b8fa4ce59567a80ae6a0ec7e1769d55;
    /// @dev APPLIED DIGITAL CORP (Equity.US.APLD/USD): US market hours only.
    bytes32 internal constant APLDON = 0x7fc1e64946aff450748e8f60644d052ae787e5708dc48c6c73c546ee94218cc3;
    /// @dev PLANET LABS PBC / US DOLLAR (Equity.US.PL/USD): US market hours only.
    bytes32 internal constant PLON = 0x562e632de00dd4ad4a70b024afc3e2a220c1b05116d58cf96089825303f94762;
    /// @dev KRANESHARES CSI CHINA INTERNET ETF (Equity.US.KWEB/USD): US market hours only.
    bytes32 internal constant KWEBON = 0x8a11c9ba1c8a59571188ff14ca1cc096520eae277de4ff8bc5a6b58939efb096;
    /// @dev OKLO INC / US DOLLAR (Equity.US.OKLO/USD): US market hours only.
    bytes32 internal constant OKLOON = 0x0d283a095e94dff4d4e607614ed686eb53e548238fb3af231148c276ecefe83e;
    /// @dev GLOBAL X URANIUM ETF / US DOLLAR (Equity.US.URA/USD): US market hours only.
    bytes32 internal constant URAON = 0xc22a2dd9ebde1ca2658926fc2579e9e4086c14cb63c789337c86295f09e68de5;
    /// @dev VISHAY INTERTECHNOLOGY, INC / US DOLLAR (Equity.US.VSH/USD): US market hours only.
    bytes32 internal constant VSHON = 0x1062b0f61c3bbf6bdb79120e6a8826d36c1f3f8b0bc1990804e53770d38c3ca2;
    /// @dev PYTH PRICE IN USD FOR HIMS & HERS 24/7 (Equity.Index.HIMS/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant HIMSON = 0xe1ec83d83a2e0eb8c0b8c4a505264785ee6676473452697a03f2322c73879bcf;
    /// @dev APPLIED OPTOELECTRONICS INC / US DOLLAR (Equity.US.AAOI/USD): US market hours only.
    bytes32 internal constant AAOION = 0xff68be691d07c6513247fd4e93a6d52b31e0ef7e4899acc43e59cb5c95b3fa76;
    /// @dev ISHARES CHINA LARGE-CAP ETF / US DOLLAR (Equity.US.FXI/USD): US market hours only.
    bytes32 internal constant FXION = 0x978c107498c949190c0b9bb1ad408eb643b7317ad43539ff43897cab967d7fd3;
    /// @dev PRIMORIS SERVICES CORP / US DOLLAR (Equity.US.PRIM/USD): US market hours only.
    bytes32 internal constant PRIMON = 0xdf2a490455eb1f5ae07ea6a58c16218648d5c4b9c29e1a18ad6942fb48f3d946;
    /// @dev CIPHER DIGITAL INC / US DOLLAR (Equity.US.CIFR/USD): US market hours only.
    bytes32 internal constant CIFRON = 0x55a91bd14858a0039cb21d56ac87bd796fb257a78786d3a81d64e8dff2373af3;
    /// @dev ENPHASE ENERGY INC / US DOLLAR (Equity.US.ENPH/USD): US market hours only.
    bytes32 internal constant ENPHON = 0x5ec583659f690a921cd7a5be9dd2730d67b2541528ca5b1ff99df3e5d44bbedb;
    /// @dev BULLISH / US DOLLAR (Equity.US.BLSH/USD): US market hours only.
    bytes32 internal constant BLSHON = 0xdf68956522c14482f38841a1105220f9e32c35e48a3fd517cc955a4580ab1cae;
    /// @dev D-WAVE QUANTUM INC / US DOLLAR (Equity.US.QBTS/USD): US market hours only.
    bytes32 internal constant QBTSON = 0x517ad3e4bd0c7851b9526172474625575529328c330d558df03a336d5ec6c082;
    /// @dev URANIUM ENERGY CORP. / US DOLLAR (Equity.US.UEC/USD): US market hours only.
    bytes32 internal constant UECON = 0xb913007c5d32d88a882832b16dfb8a93665ff52e6da2c02d94b6eee717b97941;
    /// @dev RIGETTI COMPUTING INC / US DOLLAR (Equity.US.RGTI/USD): US market hours only.
    bytes32 internal constant RGTION = 0x20aead6dcd4da8321806ce377107952863632fb25f43ec03c36ffd575ac7e708;
    /// @dev GLOBAL X ROBOTICS & ARTIFICIAL INTELLIGENCE ETF (Equity.US.BOTZ/USD): US market hours only.
    bytes32 internal constant BOTZON = 0x38e8dd9b74943ce63b08b4b3f897f128ece558ea61cd7e00c9c77a6d64cd8265;
    /// @dev PENGUIN SOLUTIONS INC. (Equity.US.PENG/USD): US market hours only.
    bytes32 internal constant PENGON = 0xe35e3fa2164c7b0ef15d904c231939e799ee683437ca0aa362133bafaf540ae6;
    /// @dev ONDAS INC / US DOLLAR (Equity.US.ONDS/USD): US market hours only.
    bytes32 internal constant ONDSON = 0x2373578c1c42c6a46f39e1cd7c5e37204b9394027415333891d2cb85ca842041;
    /// @dev AMC ENTERTAINMENT HOLDINGS INC / US DOLLAR (Equity.US.AMC/USD): US market hours only.
    bytes32 internal constant AMCON = 0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1;
    /// @dev USA RARE EARTH INC / US DOLLAR (Equity.US.USAR/USD): US market hours only.
    bytes32 internal constant USARON = 0x1bf5216f1a4ec4beb87e22110dbca2a62825bb1216d24a17e913164e4f8ec602;
    /// @dev INVESCO PHLX SEMICONDUCTOR ETF / US DOLLAR (Equity.US.SOXQ/USD): US market hours only.
    bytes32 internal constant SOXQON = 0x916f99d33c702bb925e90d86452bed7a3d1fee416030ccc284f142f5fc25f112;
    /// @dev GRINDR INC / US DOLLAR (Equity.US.GRND/USD): US market hours only.
    bytes32 internal constant GRNDON = 0xca320d73da49ed89083480db02fbe5cd352d8bd98c9c7310336c82c32f9dbbd6;
    /// @dev ARCHER AVIATION INC / US DOLLAR (Equity.US.ACHR/USD): US market hours only.
    bytes32 internal constant ACHRON = 0x641c99f709570911f4ce41237b56092ae86b792e7dcce15317fb3175e81f8eb9;
    /// @dev MARATHON DIGITAL HOLDINGS INC / US DOLLAR (Equity.US.MARA/USD): US market hours only.
    bytes32 internal constant MARAON = 0x0fc2ad77a9ab75bcbc3ebd7a9ff60facd08c517309e2d684baa979c910a0e43e;
    /// @dev GALAXY DIGITAL / US DOLLAR (Equity.US.GLXY/USD): US market hours only.
    bytes32 internal constant GLXYON = 0x67e031d1723e5c89e4a826d80b2f3b41a91b05ef6122d523b8829a02e0f563aa;
    /// @dev AXT INC / US DOLLAR (Equity.US.AXTI/USD): US market hours only.
    bytes32 internal constant AXTION = 0x56b6d6619fbd0b81ae09dbb8ccca77877b78aebf098b2fb95432a926af8e384c;
    /// @dev OUSTER, INC / US DOLLAR (Equity.US.OUST/USD): US market hours only.
    bytes32 internal constant OUSTON = 0x33e337a21f74f02e0a5aa4a6ca8bcac777456865d1a27cc3e0495bd25d8d1b07;
    /// @dev NAVITAS SEMICONDUCTOR CORPORATION (Equity.US.NVTS/USD): US market hours only.
    bytes32 internal constant NVTSON = 0xf695dfcfeb1e71dc0c2e1eef64df6076236a55ab45c46c444ef13e558b6f48d7;
    /// @dev UNITED STATES OIL FUND LP / US DOLLAR (Equity.US.USO/USD): US market hours only.
    bytes32 internal constant USOON = 0xd00bd77d97dc5769de77f96d0e1a79cbf1364e14d0dbf046e221bce2e89710dd;
    /// @dev PROSHARES ULTRAPRO SHORT QQQ / US DOLLAR (Equity.US.SQQQ/USD): US market hours only.
    bytes32 internal constant SQQQON = 0xf207c5d325e44579b12965394d9a4dd988567de635a494694bfb0b46c20a06ec;
    /// @dev RECURSION PHARMACEUTICALS INC / US DOLLAR (Equity.US.RXRX/USD): US market hours only.
    bytes32 internal constant RXRXON = 0x303e2b3c5ca84d33cad4b179ff2ee5a53cc2070b72655b0db4170ec19d799f82;
    /// @dev PYTH PRICE IN USD FOR SOXS 24/7 (Equity.Index.SOXS/USD): Pyth's 24/7 price for the share.
    bytes32 internal constant SOXSON = 0x071f452ec5a5f4fa8ea8e585222c2f65890724374a2af16aec0bc70b4cd1c669;
    /// @dev INTUITIVE MACHINES INC / US DOLLAR (Equity.US.LUNR/USD): US market hours only.
    bytes32 internal constant LUNRON = 0xd5385d0f9a7b6268a357094c841bec5834b02265cb3ac439e53963a55defb38f;
    /// @dev VANECK OIL SERVICES ETF / US DOLLAR (Equity.US.OIH/USD): US market hours only.
    bytes32 internal constant OIHON = 0x64c24c75ad871df257440cafa78fbd8aaad18ac41ac04fc3f50a90d346855473;
    /// @dev REDWIRE  CORP / US DOLLAR (Equity.US.RDW/USD): US market hours only.
    bytes32 internal constant RDWON = 0x24799168878b008a944098996a0bfbe6cb980fcd93fd28bf5e24511850be8d10;
    /// @dev HYPERLIQUID STRATEGIES INC (Equity.US.PURR/USD): US market hours only.
    bytes32 internal constant PURRON = 0xb95c77565b8fcf080abfaee5fbd966e6732d9bb05ed7e839222c6352066929d8;
    /// @dev DENISON MINES CORP / US DOLLAR (Equity.US.DNN/USD): US market hours only.
    bytes32 internal constant DNNON = 0xb4a8298d774980d697165333606303c12c46c0bcec62bb0df3fda11162bb2194;
    /// @dev C3.AI INC / US DOLLAR (Equity.US.AI/USD): US market hours only.
    bytes32 internal constant AION = 0xafb12c5ccf50495c7a7b04447410d7feb4b3218a663ecbd96aa82e676d3c4f1e;
    /// @dev AEHR TEST SYSTEMS / US DOLLAR (Equity.US.AEHR/USD): US market hours only.
    bytes32 internal constant AEHRON = 0xaa27f6a84dd364fd2956e350b12f4d698b57793f9a1d7ab5e8b575b3cfa50d8d;
    /// @dev WENDY'S CO / US DOLLAR (Equity.US.WEN/USD): US market hours only.
    bytes32 internal constant WENON = 0xc6101ee4f14af5581a3995438bf0e80a574dd28fd497685988b526ae9ba34749;
    /// @dev ABERDEEN PHYSICAL PLATINUM SHARES ETF / US DOLLAR (Equity.US.PPLT/USD): US market hours only.
    bytes32 internal constant PPLTON = 0x782410278b6c8aa2d437812281526012808404aa14c243f73fb9939eeb88d430;
    /// @dev NUSCALE POWER CORP (Equity.US.SMR/USD): US market hours only.
    bytes32 internal constant SMRON = 0x69155365daba71df19c2c0416467b64581052cfa75f44b77f352a92698b81639;
    /// @dev SPROTT URANIUM MINERS ETF/ US DOLLAR (Equity.US.URNM/USD): US market hours only.
    bytes32 internal constant URNMON = 0x62be4863d61681d4b4393cde876fd92696c7c01c2792abcd06c0f3716b06f4bd;
    /// @dev ENERGY FUELS INC / US DOLLAR (Equity.US.UUUU/USD): US market hours only.
    bytes32 internal constant UUUUON = 0x1d27fb8230f11104a8bd4ed3ae44d0d61559261512c6508863d7af2c3f2059af;
    /// @dev SOUNDHOUND AI INC / US DOLLAR (Equity.US.SOUN/USD): US market hours only.
    bytes32 internal constant SOUNON = 0x88232bfe2ca44449224f24fc862d4b4fed9144e53f6cf9f0a939f88b82b4f8cd;
    /// @dev PLUG POWER INC / US DOLLAR (Equity.US.PLUG/USD): US market hours only.
    bytes32 internal constant PLUGON = 0x8f2af61cd4f049bce70d454e7a23c78760c68fff9d547d6144d9ae95a76a8913;
    /// @dev ISHARES INVESTMENT GRADE SYSTEMATIC BOND ETF / US DOLLAR (Equity.US.IGEB/USD): US market hours only.
    bytes32 internal constant IGEBON = 0xbb3bf79b043e09da5afc161b0e061971f020c6a31983308a3028bde5675e701a;
    /// @dev SOLAREDGE TECHNOLOGIES, INC / US DOLLAR (Equity.US.SEDG/USD): US market hours only.
    bytes32 internal constant SEDGON = 0x8adefab8e9d47055c1487bf2f962ee15ce29c5e3542044047147956621c43cf7;
    /// @dev WOLFSPEED INC / US DOLLAR (Equity.US.WOLF/USD): US market hours only.
    bytes32 internal constant WOLFON = 0xf23c1137cf7d21fb6b6387e155536f25feea7a81ae4345407c2629ee397aa490;
    /// @dev OPENDOOR TECHNOLOGIES INC / US DOLLAR (Equity.US.OPEN/USD): US market hours only.
    bytes32 internal constant OPENON = 0xb4ef19d348a726dad5a655bcac5fe6e09c83af142bf1006b45d0f9ca4d5a46b5;
    /// @dev QUANTUM COMPUTING INC. (Equity.US.QUBT/USD): US market hours only.
    bytes32 internal constant QUBTON = 0x35df6acc91ade17065f757233443edee7b5046a4cd65748641f48d1c78e031b3;
    /// @dev KEEL INFRASTRUCTURE CORP. / US DOLLAR (Equity.US.KEEL/USD): US market hours only.
    bytes32 internal constant KEELON = 0xbbea8136728ebb190eb529248350944c0e15dde357963a9ee32bab84ab754b7f;
    /// @dev INNODATA INC. (Equity.US.INOD/USD): US market hours only.
    bytes32 internal constant INODON = 0xa8fe5f1e9d6c295e134f3314065c0110be9137d31e8f5959552a1694b0050910;
    /// @dev SHARPLINK GAMING INC / US DOLLAR (Equity.US.SBET/USD): US market hours only.
    bytes32 internal constant SBETON = 0x6b5bedda9e9d6354c5b93659cba6747d21b527437022da6e5f32e3b53e485a04;
    /// @dev BITDEER / US DOLLAR (Equity.US.BTDR/USD): US market hours only.
    bytes32 internal constant BTDRON = 0xeda74e4c405a1f8d8d1c6004a197c20e620f5580e855ec66cf167f8d5f5ec7a3;
    /// @dev BIGBEARAI HOLDINGS INC / US DOLLAR (Equity.US.BBAI/USD): US market hours only.
    bytes32 internal constant BBAION = 0xd66fd5fb5d53b65340d1772cf658d451eb9dd8f528f6433743cd87f51f43638c;
    /// @dev UNITED STATES BRENT OIL FUND, LP / US DOLLAR (Equity.US.BNO/USD): US market hours only.
    bytes32 internal constant BNOON = 0x3488e477571c3c8aa861d02044a96a71fd81299cf0d915aa019af96335498874;
    /// @dev PROSHARES SHORT QQQ / US DOLLAR (Equity.US.PSQ/USD): US market hours only.
    bytes32 internal constant PSQON = 0x52d75219bbd61a396f93a964b830fc1362f3208701dd4fb80b501b603312bc8c;
    /// @dev UNITED STATES COPPER INDEX FUND / US DOLLAR (Equity.US.CPER/USD): US market hours only.
    bytes32 internal constant CPERON = 0x34b7613ec0b7388fc491162ef6d2b211ef311ea90d35863a7f03017d259c3cd4;
    /// @dev FUELCELL ENERGY INC / US DOLLAR (Equity.US.FCEL/USD): US market hours only.
    bytes32 internal constant FCELON = 0x06f2079da8284ccb8810c0af9ca66fb608fcbcb90288754e42a0101dc5d34f9b;
    /// @dev FLUENCE ENERGY INC / US DOLLAR (Equity.US.FLNC/USD): US market hours only.
    bytes32 internal constant FLNCON = 0x800415fb1fa6bac6bd13888d85843015a9cf35df23769314eb2ccad6b198ac4f;
    /// @dev NANO NUCLEAR ENERGY INC. (Equity.US.NNE/USD): US market hours only.
    bytes32 internal constant NNEON = 0xa6fa5a4d8c9b0eb54f314df24f62382d0fd7817a0aebba8bcf5a8de833cac21d;
    /// @dev ROBOSTRATEGY INC / US DOLLAR (Equity.US.BOT/USD): US market hours only.
    bytes32 internal constant BOTON = 0x0aa20f6c96a0f30e7c78e4c4f45a0db36ee9126b1ae34851a2c37720e075a500;
    /// @dev ABERDEEN PHYSICAL PALLADIUM SHARES ETF / US DOLLAR (Equity.US.PALL/USD): US market hours only.
    bytes32 internal constant PALLON = 0xfeeb371f721e75853604c47104967f0ab3fa92b988837013f5004f749a8a0599;
    /// @dev BITGO HOLDINGS INC / US DOLLAR (Equity.US.BTGO/USD): US market hours only.
    bytes32 internal constant BTGOON = 0x6540ed0004047d446b252bc49bff9e23e667c5c7d0437ad0db8e120e7b19c311;
    /// @dev LIGHTPATH TECHNOLOGIES INC / US DOLLAR (Equity.US.LPTH/USD): US market hours only.
    bytes32 internal constant LPTHON = 0xb87e0ca977ca87d774ed3e22a3bb47d2123d152222efaa5a0aafb703728c71f6;
    /// @dev EXODUS MOVEMENT INC / US DOLLAR (Equity.US.EXOD/USD): US market hours only.
    bytes32 internal constant EXODON = 0xeb177413dfa4a455737b1427643ad43842f054625f85379eb154a3c790745d18;
    /// @dev BREAKWAVE TANKER SHIPPING ETF / US DOLLAR (Equity.US.BWET/USD): US market hours only.
    bytes32 internal constant BWETON = 0xf6ea2fcdec548d7f3fe4d194866e59bebc5a7795e6cc7ec55a6b36fef0ca2526;
    /// @dev ISHARES A.I. INNOVATION AND TECH ACTIVE ETF / US DOLLAR (Equity.US.BAI/USD): US market hours only.
    bytes32 internal constant BAION = 0xd0805a15ab9b061a858417e37281424fade678dd7a68d9d36ea18a55889652d7;
    /// @dev ROUNDHILL MEMORY ETF / US DOLLAR (Equity.US.DRAM/USD): US market hours only.
    bytes32 internal constant DRAMON = 0x71a19a2d91626d9d184ba85c4a9d21289640013a7dacc113d007847ea1a09ec8;
    /// @dev STRIVE INC / US DOLLAR (Equity.US.SATA/USD): US market hours only.
    bytes32 internal constant SATAON = 0xb89885277fd07887353cb63d641afe432a5231256f844b3b993f8fe1764fdfca;
    /// @dev STRATEGY INC VARIABLE RATE SERIES A PERPETUAL STRETCH PREFERRED STOCK / US DOLLAR
    ///      (Equity.US.STRC/USD): US market hours only.
    bytes32 internal constant STRCON = 0x27c7bbc9755d847f7fc63620c2edcc6a91d2c0c67a28c7999907b59c505b3c17;
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
}
