// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MainnetAddresses as M} from "./MainnetAddresses.sol";

/// @notice The Pyth price id each listed Ethereum coin is listed with for v5's weighted indexes, read from Pyth's Hermes
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
///         price for the share, else at the US-hours feed, which publishes nothing while the market is closed. The
///         hundred-coin list of 2026-10-10 (design/2026-10-10-one-index-wormhole-legs.md) adds 31 Ethereum-issued
///         coins and 13 Wormhole copies, each at its coin's feed, read from Hermes that day; a Wormhole copy is priced
///         as the coin it wraps, as SOL's is.
library PythIds {
    /// @notice How many coins the table names.
    uint256 internal constant COUNT = 93;

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
    /// @dev BITTORRENT / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant BTT = 0x097d687437374051c75160d648800f021086bc8edf469f11284491fda8192315;
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
    /// @dev THE SANDBOX / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant SAND = 0xcb7a1d45139117f8d3da0a4b67264579aa905e3b124efede272634f094e1e9d1;
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
    /// @dev ROLLBIT COIN / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant RLB = 0x2f2d17abbc1e781bd87b4a5d52c8b2856886f5c482fa3593cebf6795040ab0b6;
    /// @dev WORMHOLE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant W = 0xeff7446475e218517566ea99e72a4abec2e1bd8498b43b7d8331e29dcb059389;
    /// @dev RESERVE RIGHTS / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant RSR = 0xfb7565b77267ba3f6ef770bed5d7f9b22b8542db676dbd9b934a2fcf945f4371;
    /// @dev RIPPLE / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant XRP = 0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8;
    /// @dev DOGECOIN / US DOLLAR, read from Hermes on 2026-10-10.
    bytes32 internal constant DOGE = 0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c;
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

    /// @notice A token's trust tier (design/2026-10-05-wide-asset-support.md, section 1), shown by the app beside every
    ///         index that holds it and by `ConfigureWeighted`'s safe mode beside every listing.
    enum Tier {
        Unrecorded,
        Native,
        Bridged,
        Custodial
    }

    /// @notice The tier of a token in the table: `Custodial` for WBTC (BitGo holds the bitcoin), Tether Gold, the
    ///         Ondo stocks, and Wormhole's copies of Binance-Peg coins, which carry Binance's custody under the
    ///         bridge's; `Bridged` for a bridge's copy of a coin issued elsewhere, Wormhole's other copies among them;
    ///         `Native` for a token issued on Ethereum, ether's WETH among them; and `Unrecorded` for any token off the
    ///         table.
    function tierOf(address token) internal pure returns (Tier) {
        if (
            token == M.WBTC || token == M.XAUT || token == M.NVDAON || token == M.AAPLON || token == M.GOOGLON
                || token == M.MSFTON || token == M.AMZNON || token == M.TSMON || token == M.SPCXON || token == M.METAON
                || token == M.AVGOON || token == M.TSLAON || token == M.SKHYON || token == M.MUON || token == M.LLYON
                || token == M.AMDON || token == M.JPMON || token == M.WMTON || token == M.VON || token == M.XRP
                || token == M.DOGE || token == M.ADA || token == M.LTC || token == M.DOT || token == M.ATOM
        ) return Tier.Custodial;
        if (
            token == M.CRO || token == M.ICP || token == M.ARB || token == M.RENDER || token == M.CAKE || token == M.ZRO
                || token == M.INJ || token == M.SOL || token == M.W || token == M.BTT || token == M.AVAX
                || token == M.JUP || token == M.ALGO || token == M.AERO || token == M.APT || token == M.PYTH_TOKEN
                || token == M.OP
        ) return Tier.Bridged;
        if (
            token == M.WETH || token == M.LINK || token == M.UNI || token == M.QNT || token == M.AAVE || token == M.ENA
                || token == M.ONDO || token == M.SKY || token == M.WLD || token == M.MNT || token == M.MORPHO
                || token == M.POL || token == M.LIT || token == M.ETHFI || token == M.FET || token == M.CRV
                || token == M.NEXO || token == M.VIRTUAL || token == M.STRK || token == M.PENDLE || token == M.SHIB
                || token == M.PEPE || token == M.FF || token == M.GNO || token == M.OHM || token == M.GRT
                || token == M.SYRUP || token == M.ENS || token == M.JASMY || token == M.COMP || token == M.EIGEN
                || token == M.AXS || token == M.SAND || token == M.BAT || token == M.CVX || token == M.MANA
                || token == M.IMX || token == M.FLUID || token == M.CHZ || token == M.ZK || token == M.APE
                || token == M.SENT || token == M.SNX || token == M.ONEINCH || token == M.GLM || token == M.ATH
                || token == M.H || token == M.PLUME || token == M.GALA || token == M.RLB || token == M.RSR
        ) return Tier.Native;
        return Tier.Unrecorded;
    }

    /// @notice A tier's name, as safe mode's labels and the app show it.
    function tierName(Tier tier) internal pure returns (string memory) {
        if (tier == Tier.Native) return "Native";
        if (tier == Tier.Bridged) return "Bridged";
        if (tier == Tier.Custodial) return "Custodial";
        return "Unrecorded";
    }

    /// @notice Every coin of the table and its id: WETH, WBTC, LINK and UNI first, the `default` list, then the wide
    ///         list: the 45 of 2026-10-06 and 2026-10-10's first additions, then the hundred-coin list's 31
    ///         Ethereum-issued coins and 13 Wormhole copies, each group by market cap.
    function all() internal pure returns (address[] memory tokens, bytes32[] memory ids) {
        tokens = new address[](COUNT);
        ids = new bytes32[](COUNT);
        (tokens[0], ids[0]) = (M.WETH, WETH);
        (tokens[1], ids[1]) = (M.WBTC, WBTC);
        (tokens[2], ids[2]) = (M.LINK, LINK);
        (tokens[3], ids[3]) = (M.UNI, UNI);
        (tokens[4], ids[4]) = (M.QNT, QNT);
        (tokens[5], ids[5]) = (M.AAVE, AAVE);
        (tokens[6], ids[6]) = (M.ENA, ENA);
        (tokens[7], ids[7]) = (M.ONDO, ONDO);
        (tokens[8], ids[8]) = (M.SKY, SKY);
        (tokens[9], ids[9]) = (M.WLD, WLD);
        (tokens[10], ids[10]) = (M.MNT, MNT);
        (tokens[11], ids[11]) = (M.MORPHO, MORPHO);
        (tokens[12], ids[12]) = (M.POL, POL);
        (tokens[13], ids[13]) = (M.LIT, LIT);
        (tokens[14], ids[14]) = (M.ETHFI, ETHFI);
        (tokens[15], ids[15]) = (M.FET, FET);
        (tokens[16], ids[16]) = (M.CRV, CRV);
        (tokens[17], ids[17]) = (M.NEXO, NEXO);
        (tokens[18], ids[18]) = (M.VIRTUAL, VIRTUAL);
        (tokens[19], ids[19]) = (M.STRK, STRK);
        (tokens[20], ids[20]) = (M.PENDLE, PENDLE);
        (tokens[21], ids[21]) = (M.CRO, CRO);
        (tokens[22], ids[22]) = (M.ICP, ICP);
        (tokens[23], ids[23]) = (M.ARB, ARB);
        (tokens[24], ids[24]) = (M.RENDER, RENDER);
        (tokens[25], ids[25]) = (M.CAKE, CAKE);
        (tokens[26], ids[26]) = (M.ZRO, ZRO);
        (tokens[27], ids[27]) = (M.INJ, INJ);
        (tokens[28], ids[28]) = (M.SHIB, SHIB);
        (tokens[29], ids[29]) = (M.PEPE, PEPE);
        (tokens[30], ids[30]) = (M.SOL, SOL);
        (tokens[31], ids[31]) = (M.XAUT, XAUT);
        (tokens[32], ids[32]) = (M.NVDAON, NVDAON);
        (tokens[33], ids[33]) = (M.AAPLON, AAPLON);
        (tokens[34], ids[34]) = (M.GOOGLON, GOOGLON);
        (tokens[35], ids[35]) = (M.MSFTON, MSFTON);
        (tokens[36], ids[36]) = (M.AMZNON, AMZNON);
        (tokens[37], ids[37]) = (M.TSMON, TSMON);
        (tokens[38], ids[38]) = (M.SPCXON, SPCXON);
        (tokens[39], ids[39]) = (M.METAON, METAON);
        (tokens[40], ids[40]) = (M.AVGOON, AVGOON);
        (tokens[41], ids[41]) = (M.TSLAON, TSLAON);
        (tokens[42], ids[42]) = (M.SKHYON, SKHYON);
        (tokens[43], ids[43]) = (M.MUON, MUON);
        (tokens[44], ids[44]) = (M.LLYON, LLYON);
        (tokens[45], ids[45]) = (M.AMDON, AMDON);
        (tokens[46], ids[46]) = (M.JPMON, JPMON);
        (tokens[47], ids[47]) = (M.WMTON, WMTON);
        (tokens[48], ids[48]) = (M.VON, VON);
        (tokens[49], ids[49]) = (M.FF, FF);
        (tokens[50], ids[50]) = (M.BTT, BTT);
        (tokens[51], ids[51]) = (M.GNO, GNO);
        (tokens[52], ids[52]) = (M.OHM, OHM);
        (tokens[53], ids[53]) = (M.GRT, GRT);
        (tokens[54], ids[54]) = (M.SYRUP, SYRUP);
        (tokens[55], ids[55]) = (M.ENS, ENS);
        (tokens[56], ids[56]) = (M.JASMY, JASMY);
        (tokens[57], ids[57]) = (M.COMP, COMP);
        (tokens[58], ids[58]) = (M.EIGEN, EIGEN);
        (tokens[59], ids[59]) = (M.AXS, AXS);
        (tokens[60], ids[60]) = (M.SAND, SAND);
        (tokens[61], ids[61]) = (M.BAT, BAT);
        (tokens[62], ids[62]) = (M.CVX, CVX);
        (tokens[63], ids[63]) = (M.MANA, MANA);
        (tokens[64], ids[64]) = (M.IMX, IMX);
        (tokens[65], ids[65]) = (M.FLUID, FLUID);
        (tokens[66], ids[66]) = (M.CHZ, CHZ);
        (tokens[67], ids[67]) = (M.ZK, ZK);
        (tokens[68], ids[68]) = (M.APE, APE);
        (tokens[69], ids[69]) = (M.SENT, SENT);
        (tokens[70], ids[70]) = (M.SNX, SNX);
        (tokens[71], ids[71]) = (M.ONEINCH, ONEINCH);
        (tokens[72], ids[72]) = (M.GLM, GLM);
        (tokens[73], ids[73]) = (M.ATH, ATH);
        (tokens[74], ids[74]) = (M.H, H);
        (tokens[75], ids[75]) = (M.PLUME, PLUME);
        (tokens[76], ids[76]) = (M.GALA, GALA);
        (tokens[77], ids[77]) = (M.RLB, RLB);
        (tokens[78], ids[78]) = (M.W, W);
        (tokens[79], ids[79]) = (M.RSR, RSR);
        (tokens[80], ids[80]) = (M.XRP, XRP);
        (tokens[81], ids[81]) = (M.DOGE, DOGE);
        (tokens[82], ids[82]) = (M.ADA, ADA);
        (tokens[83], ids[83]) = (M.LTC, LTC);
        (tokens[84], ids[84]) = (M.AVAX, AVAX);
        (tokens[85], ids[85]) = (M.DOT, DOT);
        (tokens[86], ids[86]) = (M.JUP, JUP);
        (tokens[87], ids[87]) = (M.ALGO, ALGO);
        (tokens[88], ids[88]) = (M.ATOM, ATOM);
        (tokens[89], ids[89]) = (M.AERO, AERO);
        (tokens[90], ids[90]) = (M.APT, APT);
        (tokens[91], ids[91]) = (M.PYTH_TOKEN, PYTH_TOKEN);
        (tokens[92], ids[92]) = (M.OP, OP);
    }
}
