// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The Ethereum mainnet contracts and market data the deploy and listing scripts use. This is the only copy:
///         the scripts, the testnet market and the fork tests read it, and `test/fork/MainnetAddresses.fork.t.sol`
///         checks it on-chain (tokens by symbol and decimals, the router and the PoolManager by their code).
library MainnetAddresses {
    // ---------------------------------------------------------------------
    // The `default` list's four, first listed for v4's floor and kept for v5. Checked on 2026-09-22 by symbol and
    // decimals. WBT stays off after its check: a single key can blacklist a holder and destroy its balance, and no
    // Uniswap pool holds it (design/2026-09-30-wbt-check.md, the owner's call on 2026-09-30).
    // ---------------------------------------------------------------------
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    // ---------------------------------------------------------------------
    // The wide list: every coin of CoinMarketCap's top 100 on 2026-10-05 with a contract on Ethereum, less
    // stablecoins, gold tokens and memecoins (design/2026-10-05-wide-asset-support.md, section 2), for creators'
    // indexes. Each address was taken from CoinGecko and cross-checked against CoinMarketCap and CoinPaprika (or the
    // issuer), then read on chain on 2026-10-05 by symbol and decimals; each passed `CheckToken`
    // (design/2026-10-05-token-admission-report.md). Two of the 29 are left out by the WBT rule: LEO
    // (0x2AF5D2aD76741191D15Dfe7bF6aC92d4Bd912Ca3), whose MiniMe controller destroys any balance and approves every
    // transfer, and WLFI (0xdA5e1988097297dCdc1f90D4dFE7909e847CBeF6), whose owner blacklists and reallocates any
    // holder's balance. The owner's calls of 2026-10-06 left out four more: OKB, being retired on Ethereum, BGB and
    // GT, which no Uniswap route trades, and the bridged GRAM, whose bridge closed. On 2026-10-10 CoinGecko's top 100
    // was read again (design/2026-10-05-token-admission-report.md, "Top 100 of 2026-10-10"): INJ is added; BTW
    // (0x3A63DE3572c69a1307ff08394f3Ee7702C16d25d) has no Pyth feed and no Uniswap pool, and HTX
    // (0x61EC85aB89377db65762E234C946b5c25A56E99e) no Uniswap liquidity, so no fill could rebalance either. SHIB and
    // PEPE, which passed the check, are added on the owner's call of 2026-10-10, which lifts the memecoin exclusion of
    // 4 October for these two. Issued on Ethereum:
    // ---------------------------------------------------------------------
    address internal constant QNT = 0x4a220E6096B25EADb88358cb44068A3248254675;
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address internal constant ENA = 0x57e114B691Db790C35207b2e685D4A43181e6061;
    address internal constant ONDO = 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3;
    /// @dev Sky, Maker's successor; not MKR.
    address internal constant SKY = 0x56072C95FAA701256059aa122697B133aDEd9279;
    address internal constant WLD = 0x163f8C2467924be0ae7B5347228CABF260318753;
    address internal constant MNT = 0x3c3a81e81dc49A522A592e7622A7E711c06bf354;
    address internal constant MORPHO = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2;
    /// @dev The Polygon Ecosystem Token; not MATIC.
    address internal constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    /// @dev Lighter.
    address internal constant LIT = 0x232CE3bd40fCd6f80f3d55A522d03f25Df784Ee2;
    address internal constant ETHFI = 0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB;
    /// @dev The Artificial Superintelligence Alliance's FET; the old FET at 0x1D287CC25dAD7cCaF76a26bc660c5F7C8E2a05BD
    ///      answers the same symbol.
    address internal constant FET = 0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85;
    address internal constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant NEXO = 0xB62132e35a6c13ee1EE0f84dC5d40bad8d815206;
    address internal constant VIRTUAL = 0x44ff8620b8cA30902395A7bD3F2407e1A091BF73;
    address internal constant STRK = 0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766;
    address internal constant PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
    /// @dev Shiba Inu, a fixed supply with no owner and no admin function (2026-10-10).
    address internal constant SHIB = 0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE;
    /// @dev Pepe, a fixed supply whose owner is renounced (2026-10-10).
    address internal constant PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;

    // ---------------------------------------------------------------------
    // The wide list, bridged copies of coins issued elsewhere.
    // ---------------------------------------------------------------------
    /// @dev Cronos's original 2018 ERC-20, 8 decimals; Crypto.com's migration to the native coin runs one way.
    address internal constant CRO = 0xA0b73E1Ff0B80914AB6fe0444E65848C4C34450b;
    /// @dev Internet Computer's copy from the OneSec bridge, 8 decimals, minted by a single key.
    address internal constant ICP = 0x00f3C42833C3170159af4E92dbb451Fb3F708917;
    /// @dev Arbitrum's token on Ethereum, from Arbitrum's own gateway.
    address internal constant ARB = 0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1;
    /// @dev Render's Ethereum token, symbol RNDR; most of it is locked in Wormhole for Solana's RENDER.
    address internal constant RENDER = 0x6De037ef9aD2725EB40118Bb1702EBb27e4Aeb24;
    /// @dev PancakeSwap's LayerZero copy, symbol Cake.
    address internal constant CAKE = 0x152649eA73beAb28c5b49B26eb48f7EAD6d4c898;
    /// @dev LayerZero's ZRO, one peer of its burn-and-mint mesh.
    address internal constant ZRO = 0x6985884C4392D348587B19cb9eAAf157F13271cd;
    /// @dev Injective's original 2020 ERC-20, a fixed supply of 100,000,000 minted once at deployment, with no owner,
    ///      mint, pause or upgrade (verified source, `InjectiveToken`). Added on 2026-10-10 from CoinGecko's top 100,
    ///      read on chain by symbol and decimals and passed by `CheckToken`. Bridged: the coin lives on Injective's own
    ///      chain, and the Peggy bridge's validators tie this token to it.
    address internal constant INJ = 0xe28b3B32B6c345A34Ff64674606124Dd5Aceca30;
    /// @dev Solana's SOL as Wormhole's token bridge wraps it, symbol SOL, name "Wrapped SOL", 9 decimals: the bridge
    ///      (0x3ee18B2214AFF97000D974cf647E7C347E8fa585, Wormhole chain 2) owns it, mints it against SOL locked on
    ///      Solana and burns it on the way back, and is upgraded by the guardians' governance messages. No blacklist.
    ///      Moved here from BNB Chain's Binance-Peg SOL on 2026-10-10 (the owner's call): the only Ethereum copy of a
    ///      Binance-Peg coin that passed `CheckToken` with a Uniswap route.
    address internal constant SOL = 0xD31a59c85aE9D8edEFeC411D448f90841571b89c;

    // ---------------------------------------------------------------------
    // Real-world assets, `Custodial`, added on 2026-10-10 on the owner's call that a blacklist is no bar to listing
    // (design/2026-10-05-token-admission-report.md, "Real-world assets of 2026-10-10"). Each issuer holds the asset and
    // can block and burn any holder's tokens; `CheckToken` refuses XAUT under the WBT rule, and the owner admits it
    // anyway. Read on chain on 2026-10-10 by symbol and decimals.
    // ---------------------------------------------------------------------
    /// @dev Tether Gold, symbol XAUt, 6 decimals: one fine troy ounce of gold Tether holds per token. Tether can
    ///      blacklist a holder and destroy its balance (`destroyBlackFunds`).
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    /// @dev Ondo Global Markets tokens, symbol `<ticker>on`, 18 decimals, one share each, the shares held by Ondo's
    ///      custodian. One implementation (`GMToken`) behind each proxy, upgraded through a timelock: a compliance
    ///      contract may block any sender or receiver, `BURNER_ROLE` burns any holder's balance, and a pause manager can
    ///      stop transfers. Most have no Uniswap liquidity: they mint in kind or through `MintRequests`, and a rebalance
    ///      needs an executor that holds them or mints them with Ondo.
    address internal constant NVDAON = 0x2D1F7226Bd1F780AF6B9A49DCC0aE00E8Df4bDEE;
    address internal constant AAPLON = 0x14c3abF95Cb9C93a8b82C1CdCB76D72Cb87b2d4c;
    address internal constant GOOGLON = 0xbA47214eDd2bb43099611b208f75E4b42FDcfEDc;
    address internal constant MSFTON = 0xB812837b81a3a6b81d7CD74CfB19A7f2784555E5;
    address internal constant AMZNON = 0xbb8774FB97436d23d74C1b882E8E9A69322cFD31;
    address internal constant TSMON = 0x3Cafdbfe682aec17d5acE2f97A2f3ab3dCf6a4A9;
    address internal constant SPCXON = 0xc9eef266834730340A55B6CC24621B31BAF55581;
    address internal constant METAON = 0x59644165402b611b350645555B50Afb581C71EB2;
    address internal constant AVGOON = 0x0d54D4279B9E8c54cD8547c2C75A8Ee81A0BcaE8;
    address internal constant TSLAON = 0xf6b1117ec07684D3958caD8BEb1b302bfD21103f;
    address internal constant SKHYON = 0xc0fE36F4FFBDf1B38E192215073590a68f9A2Af7;
    address internal constant MUON = 0x050362Ab1072Cb2Ce74d74770E22A3203Ad04ee5;
    address internal constant LLYON = 0xf192957AE52dB3eb088654403CC2eDeD014ae556;
    address internal constant AMDON = 0x0C1f3412A44Ff99E40bF14e06e5Ea321aE7B3938;
    address internal constant JPMON = 0x03C1EC4CA9DBb168E6Db0DeF827c085999CBffaF;
    address internal constant WMTON = 0x82106347dDbB23cE44Cf4cE4053Ef1adf8b9323B;
    address internal constant VON = 0xaC37c20C1d0E5285035e056101a64e263Ff94a41;
    /// @dev The Ondo stocks and ETFs listed on 2026-11-19 (the owner's call: every Ondo stock and ETF Pyth has a
    ///      feed for, design/2026-11-22-ondo-stocks-and-etfs.md), each the same `GMToken` behind the same beacon as
    ///      the 17 above (0x985462C9aA4D6c3Ad59Ae6e1e9c0C11347ED1598), read from Ondo's app on 2026-11-19 and on
    ///      chain at block 26,450,299 by symbol and decimals; by the underlying's market cap.
    address internal constant GOOGON = 0x36B90aDcDC99Be31BF39A3c031288bAa0B457E10;
    address internal constant IVVON = 0x62cA254a363dc3c748e7E955c20447aB5bF06fF7;
    address internal constant SPYON = 0xFeDC5f4a6c38211c1338aa411018DFAf26612c08;
    address internal constant VTION = 0x57B392146848C6321bb2A3D4358DF1bDEACdc62A;
    address internal constant XOMON = 0xF05Ad9840924EA6f977EBccb3b1da87e31DcD0B4;
    address internal constant JNJON = 0xdd0E1e6162666a210905fFE8d368661B313c00e9;
    address internal constant MAON = 0xA29dC2102dfc2a0A4A5dCb84Af984315567c9858;
    address internal constant ASMLON = 0xE51bA774ebF6392c45Bf1d9E6b334d07992460d3;
    address internal constant ABBVON = 0x7c7378143a9c8839e0502e2178F058F46c6ea504;
    address internal constant COSTON = 0x0c8276E4FeC072cf7854Be69c70F7773D1610857;
    address internal constant QQQON = 0x0e397938C1Aa0680954093495B70A9F5e2249aBa;
    address internal constant KOON = 0x74a03d741226f738098C35da8188E57acA50d146;
    address internal constant CVXON = 0x8F3E41b378ae010c46d255F36bFC1D303b52dceb;
    address internal constant PGON = 0x339ce23a355ed6D513DD3e1462975C4eCD86823a;
    address internal constant PLTRON = 0x0c666485b02F7A87d21AdD7AEb9F5e64975AA490;
    address internal constant CSCOON = 0x980a1001ee94e54142b231f44C7CA7c9DF71FBe1;
    address internal constant ORCLON = 0x8a23C6BaadB88512b30475C83Df6A63881e33e1E;
    address internal constant GEON = 0xD904bCf89B7CedF5c89f9Df7e829191D695F847E;
    address internal constant BACON = 0x576E9CA70e3a040c00d8139b0665a2b7b7B64844;
    address internal constant HDON = 0x7DBd435aa4eCAB5471CFCeF4527a022feF0b7e1C;
    address internal constant MRKON = 0xdc8a7Db05EA704227D56F5D4a4b77A2d1bbA29c0;
    address internal constant INTCON = 0xFdA09936DbD717368De0835bA441d9E62069d36f;
    address internal constant UNHON = 0x075756F3b6381a79633438fAA8964946bf40163d;
    address internal constant PANWON = 0x34bfdFF25F0fdA6d3ad0c33F1e06c0D40bD68885;
    address internal constant AMATON = 0x6bE935eaDc71c49c414b1175985946ee40365c67;
    address internal constant LRCXON = 0x21bE23f5bF87A749670c088F6DEe26760F1Ab80F;
    address internal constant TXNON = 0x58fC9d573Ea773ef9a25c3DE66F990B87Ee5f50E;
    address internal constant RTXON = 0x67c5902F5210F62f37157cd9C735c693164c1378;
    address internal constant TMOON = 0x60808f2a0d035e16F57e9043842BD1BFBda24fA2;
    address internal constant CRWDON = 0xCaC9AAfb2cf51645Ae1ab4Fb1F35F07d42437f80;
    address internal constant CATON = 0xF719b02079E0FaA5450392DA2D3e11a1e5b0EADB;
    address internal constant GSON = 0xdB57d9C14e357Fc01E49035a808779Df41E9B4e2;
    address internal constant ANETON = 0x20e113E9235dF6A2A9BFc6f244c2ccC380c8f546;
    address internal constant NFLXON = 0x032deC3372F25C41EA8054B4987a7c4832CDB338;
    address internal constant WFCON = 0x4AD2118Da8a65eaa81402A3d583FEF6eE76BDf3F;
    address internal constant SAPON = 0xCAfD1c0EE8B392cb446e3E745A4ADEfF7A861995;
    address internal constant AMGNON = 0x1c5FA55eAdE69ae98571059332520F73733C2D82;
    address internal constant LINON = 0x01B19c68f8A9eE3a480dA788ba401cFAbdf19B93;
    address internal constant IBMON = 0x25d3f236B2d61656eebdeA86Ac6D42168e340011;
    address internal constant BABAON = 0x41765F0FCddC276309195166C7A62AE522FA09ef;
    address internal constant AXPON = 0x2Bc7Ff0C5dA9F1a4A51F96e77C5b0F7165DC06d2;
    address internal constant DISON = 0xc3D93B45249E8E06cfeB01d25A96337E8893265d;
    address internal constant GEVON = 0xA043FDc5A6E2E381e3532d5A97404b82fb7A0af8;
    address internal constant DELLON = 0xeE9f43476C5b7292b114bA1b280A42A8746792d4;
    address internal constant ARMON = 0x5Bf1b2A808598C0eF4Af1673a5457d86fE6d7B3d;
    address internal constant CON = 0xC46e7eF70d7Cf8C17863a6B0b9be2aF6a4C41aBe;
    address internal constant APHON = 0xD9C1b5df94063177CF168680b695A417919aE1ae;
    address internal constant MCDON = 0x4C82c8cD9a218612DCe60b156B73A36705645e3b;
    address internal constant KLACON = 0xa637ae510cB50E61236a89AC480B93B8c3bcCc46;
    address internal constant PEPON = 0x3cE219D498D807317F840f4CB0f03FA27dd65046;
    address internal constant VTVON = 0x84E8f1b9b40DD1832925702459D12FFb14d97bF3;
    address internal constant VZON = 0x0e3D889D5B857C3e6eb361B9C9aE35bb7DdbD254;
    address internal constant ADION = 0x2dDc2391CC89E3e716A938F089AE755174cfDf1f;
    address internal constant IEFAON = 0xFEFf7a377A86462F5a2A872009722C154707F09e;
    address internal constant ABTON = 0x3859385363f7BB4Dfe42811cCF3F294FcD41dd1D;
    address internal constant BLKON = 0x7a0F89c1606f71499950AA2590d547c3975B728E;
    address internal constant QCOMON = 0xE3419710c1f77D44B4DaB02316d3f048818C4E59;
    address internal constant SHOPON = 0x908266C1192628371Cff7AD2F5Eba4dE061a0ac5;
    address internal constant NEEON = 0xF46BA88694cd7933Ca28Be84EE787Ad5732e856B;
    address internal constant UNPON = 0x39930751d4569F7DD45d1bA46E82CD3680EC2e0a;
    address internal constant NVOON = 0x28151F5888833D3d767C4d6945a0Ee50D1B193E3;
    address internal constant TMUSON = 0xdEb3C23f93349229823A006657CfE1a6552B6340;
    address internal constant DEON = 0x32d7c413fD3477E86b8eC6B0BB8F3Ac510eAfaae;
    address internal constant SCHWON = 0xe737f948bDFe3bEAe9423292853EC0579173cebB;
    address internal constant COPON = 0x8E6A5338eaC4B6fE8D51a7653Fad3B9DA755Eea6;
    address internal constant PFEON = 0x06954faa913fA14c28Eb1b2e459594F22f33f3dE;
    address internal constant CRMON = 0x55720eF5b023Fd043AE5F8D2e526030207978950;
    address internal constant TON = 0x3361A73262199873b74D6835760a59B8817fa592;
    address internal constant ISRGON = 0x2691b13fca1E02322685b9554B5ae0F5F3f05C55;
    address internal constant AGGON = 0xfF7CF16aA2fFc463b996DB2f7B7cf0130336899D;
    address internal constant IEMGON = 0xcDD60D15125bf3362b6838D2506b0Fa33bc1a515;
    address internal constant UBERON = 0x5Bcd8195E3Ef58f677aeF9eBC276B5087c027050;
    address internal constant VRTXON = 0xFC003a764a7B5054Cc6fDb6b511F35deC8022751;
    address internal constant LMTON = 0x691b126cF619707Ed5d16CaB1B27C000aa8De300;
    address internal constant MRVLON = 0xF404E5f887dBd5508e16a1198fCDD5DE1A4296B8;
    address internal constant ETNON = 0x9b56f5ED5A94Ae3266b7FF21953e6626F94008F1;
    address internal constant ACNON = 0xAbA9Ae731Aad63335C604E5f6E6A5db2e05f549d;
    address internal constant SPGION = 0xbc843b147DB4C7E00721d76037b8b92e13AfE13f;
    address internal constant APPON = 0xd5C5B2883735Fa9B658Dd52e2FCC8d7c0f1A42Ce;
    address internal constant BAON = 0x57270D35A840BC5C094da6FBeCA033FB71eA6Ab0;
    address internal constant STXON = 0xB53894f82a6B2d3B7365f24932B5bDE1c5Fb51FF;
    address internal constant SCCOON = 0xdA81DA76070a7377eAEEB2978F0E13C5d57FaDb7;
    address internal constant PDDON = 0xcC40965d3621362C3EE1dD946bA98d6A708ea86B;
    address internal constant GLDON = 0x423D42E505e64F99b6E277eb7ED324CC5606F139;
    address internal constant LOWON = 0x84328D8B85019FdCeCf4c82FBE076Bf350FC0cab;
    address internal constant SPOTON = 0x590F21186489cA1612f49a4B1ff5c66acD6796A9;
    address internal constant SBUXON = 0xf15FbC1349ab99ABAd63db3f9A510BF413bE3BeF;
    address internal constant IJHON = 0xFd50Fc4E3686a8DA814c5C3D6121d8aB98a537F0;
    address internal constant SGOVON = 0x8De5D49725550f7b318b2FA0f1B1F118E98E8D0F;
    address internal constant WDCON = 0x44e89d34601b8D0155e16634d2553EF7F54DBab2;
    address internal constant SNDKON = 0x71E2400CF1Cb83204f33794eD326636A71a9AAfC;
    address internal constant IWFON = 0x8d05432C2786e3F93f1a9A62b9572DBf54f3ea06;
    address internal constant NETON = 0x4f5A3B3E184b1424816D9107448314ba0aAd63e1;
    address internal constant COFON = 0x3D07c3161F355Cb9E5B524beF8d113c96e0263AB;
    address internal constant SOON = 0x99aA107e55250a9fE52bB4b5541A59239EB6D974;
    address internal constant PBRON = 0xD08DDb436e731f32455Fe302723eE0FD2E9E8706;
    address internal constant NEMON = 0x0C802aCB21Cb2AadB2EB5E5090868E1361B26B69;
    address internal constant ABNBON = 0xb035c3d5083bdc80074F380aeBc9Fcb68aBa0A28;
    address internal constant ENBON = 0xB2e9Ec5c62f78596cA4a21a21570b9a00c6D226c;
    address internal constant EQIXON = 0x73d2ccEE12C120E7DA265a2dE9d9f952a0101b4f;
    address internal constant SNOWON = 0x5D1a9a9B118fF19721e0111f094f2360b6Ef7A2f;
    address internal constant REGNON = 0x33aC34DA58168De69cE74a66fbaD81a88F974BD5;
    address internal constant NOWON = 0x8bCF9012f4b0c1C3D359eDb7133C294f82f80790;
    address internal constant GLWON = 0xE45575b8895664DEdf7bEfFEe98b078F2Cf1A192;
    address internal constant WMON = 0x1fb5a8DCd70bE750a97Eaf8a47bBe74Ab7d3183e;
    address internal constant GDON = 0xD68fa0978C257aace5BEc5246b201B56E838D45d;
    address internal constant ITOTON = 0x0692481C369E2BDc728A69ae31b848343a4567Be;
    address internal constant CEGON = 0x060505527C83E8BfEb9b4Ff08248B82e688800F1;
    address internal constant PWRON = 0xB4d71137656150E97f3ed2C18d4a30bE138D8f2e;
    address internal constant TTON = 0x26E78f7170d8Cc3bd3865d37CE4c554B65B1C9ba;
    address internal constant EMRON = 0x26719965000A3DCAcc1451F836FbB9c883CCDe85;
    address internal constant ADBEON = 0x7042a8fFc7c7049684BfBc2fcb41b72380755a43;
    address internal constant INTUON = 0x6cc0afD51CE4Cb6920B775F3D6376Ab82b9A93Bb;
    address internal constant WMBON = 0xfB6d594CccfDEd3606e1500b92a26b8B43a35071;
    address internal constant CVNAON = 0xFe4eC50E0413148021d2f50d114CC44De6fFBF23;
    address internal constant MRNAON = 0xA2C1c0b4683a871187d4565Eb63ABF9AEF5947Ee;
    address internal constant NOCON = 0x8Ce34F749796F82A6990fFa2d80622ef75CA7aD5;
    address internal constant VRTON = 0x0752163d221d3D5d4B6e98bD616B22bd2b453964;
    address internal constant EFAON = 0x4111b60bc87F2Bd1e81E783E271D7F0ec6EE088B;
    address internal constant IWMON = 0x070D79021dD7e841123cB0CF554993bF683c511D;
    address internal constant FCXON = 0xeb08d539Be0f6a6C90eA24276196E348f5688A02;
    address internal constant SLBON = 0xCEA4290d6578f0253308304F7184eA2E8F5EB0E4;
    address internal constant DASHON = 0x241958c86c7744d15d5f6314BA1Ea4c81DDA2896;
    address internal constant APOON = 0x4D21aFfD27183B07335935F81A5C26b6A5A15355;
    address internal constant MELION = 0x2816169A49953C548BfEb3948dCF05c4A0E4657D;
    address internal constant NTESON = 0x3d1cF8692A6f2Fc9048A9cc1A06aBF77F3465f0a;
    address internal constant HOODON = 0x998f02A9E343EF6E3E6f28700d5A20F839fD74E6;
    address internal constant HPEON = 0xE67AbcA57E1504a26bd2eD209F2e0C09543Fd7Eb;
    address internal constant TELON = 0x7C17a5423200246EAFdd9fa0f5d70eAde3067Dd6;
    address internal constant NUEON = 0x167f8D6B357FA9fff9B1286E519Bd32d4504757E;
    address internal constant IAUON = 0x4f0CA3df1c2e6b943cf82E649d576ffe7B2fABCF;
    address internal constant AMEON = 0x113faE6e1103A4C09250C8697a6a4BE6Ca987d06;
    address internal constant OXYON = 0xeedC48205852E9D83Ea5cA92fa8656597788601f;
    address internal constant BEON = 0x92e04b1fCC2b16347820241D226853Cf01C9eBAB;
    address internal constant NKEON = 0xD8e26FcC879b30cB0a0B543925a2B3500f074D81;
    address internal constant LITEON = 0xbF5ab848efff75D897a3DBE4647B939C59D3cdb0;
    address internal constant KEYSON = 0x1E328BBCd67e1bbEE198bb3F90e764812e6E0AC9;
    address internal constant IBITON = 0x122940c4C5F9cCFAe7Fa86455a42D3EC140855cE;
    address internal constant BILON = 0x2710E30d84B376c34a3B3036aa196b26a83A321b;
    address internal constant PYPLON = 0x4EFD92F372898B57F292De69fCe377dd7D912bDd;
    address internal constant TLTON = 0x992651BFeB9A0DCC4457610E284ba66D86489d4d;
    address internal constant XYZON = 0x6cC41275ef02B4EecCC04fC4424849A96f3272aa;
    address internal constant CMGON = 0x25018520138bbaB60684AD7983D4432E8B8E926B;
    address internal constant FON = 0xf72936FA8afC808c99eb76E620A98DDC6a7A53d1;
    address internal constant COHRON = 0x2B7727076B9C9B1834a2f95B81f12EEdD30db9f1;
    address internal constant NOKON = 0x01E7eaF05Be1d0c2D1834fC65080188376026d07;
    address internal constant NTRAON = 0x3F5331EC2B6DFd249BE361f4626eAe442D1e5432;
    address internal constant IEFON = 0xA2eC76139028F279A1C790d323c57Cc4158098d6;
    address internal constant VSTON = 0xf1573EdDDB75BF7Ce165f142A17Ed6b5E7f5aA13;
    address internal constant ROKON = 0x4ef7A9145e7B3C92E23A97FB41A9F4E9856288CB;
    address internal constant SOXXON = 0x1fE2126bC05E4BB0468C4a198e930c889e1054a3;
    address internal constant DYNFON = 0xa32847395b007ee4a40407E3DD2f8F9bF56Ca6aB;
    address internal constant STMON = 0xF5852886Fff060dF3Af99a4246456fCa26445e8c;
    address internal constant TTWOON = 0x6C190f0b8f7525244C6dcf0363A1241a99509101;
    address internal constant CIENON = 0x1ffAc2Df9696868D06F9fe8d72fEE9e1452eeF76;
    address internal constant ALABON = 0xd6D09189B6fD611A75435e4a123e373A56Ab0e41;
    address internal constant MSTRON = 0xCabD955322dfbf94C084929ac5E9Eca3fEB5556F;
    address internal constant VNQON = 0xcCAe8843E26259278C200C6506F6E5A3bdD524cd;
    address internal constant TERON = 0x1d1b9ae25722d0B27dB23171CFeE0C269B203695;
    address internal constant RKLBON = 0x36E3b8d9aAd0e51aC08E56a75A8f6005bF68535B;
    address internal constant UMCON = 0x9784508a0758cBb43eCb9b62F4CF4b1b3a36480c;
    address internal constant JDON = 0xdeB6B89088cA9B7d7756087c8a0F7C6DF46f319C;
    address internal constant JAAAON = 0x219a1b27baA08D72fAC836665a3B752F3C9aCBBC;
    address internal constant CLSON = 0x1630281079eBaC2E873FB1F1cB41df3D0e451E23;
    address internal constant STLDON = 0xf9D5aF26E1B96625dBC86609463A06602bE42966;
    address internal constant EQTON = 0x05d2d23398756821dC3DE359ffCe8EBbD50af8c5;
    address internal constant NBISON = 0xE4babaa960bA7D37860f3fe00D7b95D3868e8EDc;
    address internal constant INSMON = 0x0431067992F312B40D30C476fc11f8AFDD1E0E90;
    address internal constant PCGON = 0x193Fdf644451CC394b28B9Cec2F5D32E2b4dE515;
    address internal constant COINON = 0xF042cfa86cf1D598a75Bdb55c3507a1F39f9493b;
    address internal constant TQQQON = 0xa45cd7ac9865b9539166ebaf2aBc362Df4736580;
    address internal constant EFVON = 0x1252c5fa0a4031F6843D5Cf8d4986Ba99a8A9b42;
    address internal constant FLEXON = 0x4493E670F5a077D46Eb3389fFA9Af19999Ea54eD;
    address internal constant SHYON = 0x5C424B9b60383FCE7fE7069D2a2B1047BCd04a73;
    address internal constant VRSNON = 0xc5a72B01Cc9e2721DC6dE1A35Ab8d92A6AA273e6;
    address internal constant CCJON = 0xA9F9BE37b19F261AB067C5f7DEDA2c969Ec66944;
    address internal constant CRWVON = 0x66908813cd7676269494B2c6F6DBAB8B4f9E95df;
    address internal constant TCOMON = 0x398f7f759380F3d309B9fC0E6cB3D36E0D67818d;
    address internal constant EEMON = 0x77A1a02e4a888ADA8620b93C30dE8a41E621126c;
    address internal constant ONON = 0xa52B2D6cA1CD9B1E8b931645428380c340cAEF9A;
    address internal constant HALON = 0x596b790CceE1032F6658Ac2c78a119cCE69727FC;
    address internal constant CPNGON = 0xFA9f0Bf8baa9A3D5E0a8E5c0AeAF186ACaBef63D;
    address internal constant JBLON = 0xD9584f80CCE13afC96BfD0188fd5C81E08f18C85;
    address internal constant BIDUON = 0x9d4C6AD12B55E4645b585209F90Cc26614061E91;
    address internal constant CRDOON = 0xB348a4Bce7FaE890d2d37Ea104e59fb3881757c2;
    address internal constant CBRSON = 0x61882Bb63aF8e6A39531175CdfDe1Fcd98346503;
    address internal constant SLVON = 0xF3e4872e6a4cF365888D93b6146a2bAA7348F1A4;
    address internal constant HUBBON = 0x24e7504246DFdd7E866936e2816BFbEa73bd890a;
    address internal constant IYWON = 0x1577D4ae114B6F217453b754AeaC164db44832DA;
    address internal constant EWJON = 0x625Fb557cAD6D4638dae420626F3F08A485b43a8;
    address internal constant GFSON = 0xB326821B68313082F00A1A4d6Fa3f924D3E826Dc;
    address internal constant ENTGON = 0x44Abf03ca01B8e7877bC3Dbc37b132F6f25E9450;
    address internal constant USFRON = 0xFb82561A955bF59B9263301126AF490D3799e231;
    address internal constant EWYON = 0xbd660e96D45e7C175512d1ed0cCc119Cb980b81a;
    address internal constant SWKSON = 0xC15F11599828b0afB0C071994679EF9E685F9E2E;
    address internal constant SOFION = 0x9f2e3EB0160117c56b07652Fe66a08a48b5bD7B5;
    address internal constant HYGON = 0xeD3618Bb8778F8eBBe2f241Da532227591771D04;
    address internal constant NVTON = 0x38cBBBF83Ab583E231960B5c112145324Bef55ae;
    address internal constant RDDTON = 0xA9431d354cFAD3c6B76E50f0e73b43D48Be80CD0;
    address internal constant MTSION = 0x6e9C4BcEDDd057D66b65794A0093ad95c5fa0Cc4;
    address internal constant RIVNON = 0x04d94914Cd1D7FF749eFedEe764335777225b962;
    address internal constant LSCCON = 0xa0Db1eCa4AaEBCa03A3c04ed221b036Dd3CcB025;
    address internal constant SMCION = 0x2ca12a3F9635fD69C21580def14F25C210cA9612;
    address internal constant TLNON = 0xc80C91BC6215E1333eA98314b8671d6e26c58470;
    address internal constant WCCON = 0xF87efCA06f6Af53Cb096847bA092ccd04395A192;
    address internal constant TSEMON = 0xEbe0D1B1d50bC68458Fcdc45C3c276d57CDC422B;
    address internal constant LECOON = 0xD62C0Bf1e1dD6F4FEe1b3D042A9E479Ad1Fb1BCb;
    address internal constant MKSION = 0xDc4F9c9CAa96046816255Bc6c10fd6433863128E;
    address internal constant TIPON = 0x2Df38cA485D01fC15e4FD85847ed26b7EF871c1c;
    address internal constant CRCLON = 0x3632DEa96A953C11dac2f00b4A05a32CD1063fAE;
    address internal constant MTZON = 0x5cb95099a2C7e3C8187fbca6eFe5ba222b5bA820;
    address internal constant IWNON = 0x9DCf7f739B8C0270E2FC0Cc8D0DaBe355a150dBa;
    address internal constant GMEON = 0x71d24Baeb0A033ec5F90FF65C4210545AF378D97;
    address internal constant SOXLON = 0xd318bBBE6B6E83F74e7aCAEb5e94C08ddbDb44c0;
    address internal constant PAVEON = 0xD4c6CCE0Cadf2fe4C0AF9eE6777989EFD8fB7670;
    address internal constant FUTUON = 0x5Ce215d9c37a195DF88e294a06B8396C296B4e15;
    address internal constant IGVON = 0xa9E5c59f34397fe6Baa9E4dA139bA4E63Bd84324;
    address internal constant GRABON = 0x1C174711f3FD63C4165d6F296b3eB19D17fde94a;
    address internal constant GNRCON = 0xD120f60FeC8189ed4a2346E10107B0F1F61354Cb;
    address internal constant FNON = 0x93A96721a624822A6aB6461A7891a5C6b154102F;
    address internal constant ITAON = 0x68622855dcf14ced1B0Cc2A69cc34843708e2E0f;
    address internal constant HIION = 0x10bd54f1F4DC19bE0c46B1Ea7E5f38FD2eaFeE26;
    address internal constant IONQON = 0x2F2e4b09B99fbf018F600e031aAfD9Da6347Cc75;
    address internal constant LION = 0xb6E362a39db703f0F7cF582C9fc043A51624e53d;
    address internal constant ALBON = 0x1b468d5535Ed7C19Ce42f0073db7Fdf441028131;
    address internal constant ONTOON = 0xC29FF16a7B0a895E9fE05c32Ce3f26c44e8eca3D;
    address internal constant PINSON = 0xC017C622cd05698580E2decD0F97d4A17DaB70F9;
    address internal constant NVMION = 0x80d04221eC124850C4B9ba8f625b9a12AD609200;
    address internal constant BMNRON = 0x33483A58079b4225b10e57958Ca28ad7b9CDbAF7;
    address internal constant SNAPON = 0xB2924278cc92E60DB9b673d6A311d7a331dD703D;
    address internal constant FIGON = 0x073E7a0669833d356fa88ca65CC6D454EFaAa3c5;
    address internal constant AIQON = 0x2A5ae1BdE731cb8732fD762073DD0bBE151360B9;
    address internal constant AMKRON = 0xF02b8309df07641dDcFd1DABCeFFDde3d30915De;
    address internal constant AALON = 0xBE8eb7b51a08f9d52Bb6C8c7EcA699f0f89BfC02;
    address internal constant RMBSON = 0xae1c6E353cdc9Dc3CC01124FFB62a0d0Ce64a401;
    address internal constant OSCRON = 0x244EFb92f76a57da49B5F71045dcE3E546E13106;
    address internal constant TWSTON = 0x9ba8789ab8A3AD1502814c375f0b18A03fc3634E;
    address internal constant EWZON = 0x54021fDe36B7c4C4F9C35b02fb9A153eD8F5938A;
    address internal constant ASTSON = 0x0D1fa4E1E3719945899Ef7b02840627Df46aF44A;
    address internal constant AURON = 0xFc9D0eBBd17d3aAa336a50488795806c69EA4b32;
    address internal constant TTMION = 0xDEbb8E6F581655759e3D64f769247a007AF0aE36;
    address internal constant HUTON = 0xdf3F2315D124F7F8b714Ba031d6e69aA16a61FA2;
    address internal constant VICRON = 0x6c51001149c7782820c107ADcE650692aB6c5378;
    address internal constant INDAON = 0xa6CdB19b22B03e03EA89e133A8a46aDc3017aa6d;
    address internal constant CLFON = 0xa95837130Bcbc0AD99e188E22F674E4eC6925be2;
    address internal constant NIOON = 0xEe2542F442a5ed8008e2fe3590e14F90DB69f70d;
    address internal constant RIOTON = 0x21deafD91116FCe9fE87C8f15Bde03f99a309b72;
    address internal constant MPON = 0x75846A2b2Eeee6575Ac775f9984be54fd1D08189;
    address internal constant FORMON = 0x6401365aA495ca96Bcfcf9c6c47Bd4a590336b00;
    address internal constant IRENON = 0x0b59fDb1A233A7477ea14061004b9DD776e73CB3;
    address internal constant WULFON = 0x110CAe53912C2Ed9bF279CD70B3b699e26C79E58;
    address internal constant FPSON = 0x410e7D6B6303E531753D4fbe3e50e35EfBcFf53c;
    address internal constant FIGRON = 0xc2dBFE026f17e7BbC17a9e41F9b8D69531887d47;
    address internal constant POWLON = 0x1b8085e78877dfBA98692Cb918809b35f6280015;
    address internal constant SHLDON = 0xFb4Aa24c9c4E65f82d57d268dA8a65a0dE0DC43B;
    address internal constant AGON = 0xaa26e62e51bc5da24ED2B6Fc6491e137d68824B9;
    address internal constant CAION = 0x4a0A962E5b3df711AFab01fFFE34C4F31e452697;
    address internal constant ETHAON = 0x98284FbC11eDD7540E29b896a49817Bbe52DdCBd;
    address internal constant COPXON = 0x423A63dfE8d82CD9C6568C92210AA537d8Ef6885;
    address internal constant CORZON = 0xddAf7945093ad7457228c185783FDf6aB25022B2;
    address internal constant BILION = 0x7e08cE07acA80CefE61ebbFA0CedFe5C7b07eDB9;
    address internal constant MXLON = 0xD1C3bF5DdE6ee17Ae2a472a8C4f0258e0B350cb4;
    address internal constant APLDON = 0x318Dcb4f07C3e6ccEcc12A252100Fb3Bf76Eeb02;
    address internal constant PLON = 0xa656C5Dd6B64b3AcB6E32aF8A876a48B5748f858;
    address internal constant KWEBON = 0xeAA2287290544eD9F481012aa348619A4D2F9e51;
    address internal constant OKLOON = 0xF0372e226553aF4F343b44111A789f87A9fa427A;
    address internal constant URAON = 0xf98Ec282300892b3518B5cB996012b18d9B7D435;
    address internal constant VSHON = 0x6987F17A188c3B64F4892f0E31C2ccd88F54FCFd;
    address internal constant HIMSON = 0xCa468554e5C0423Ee858fe3942c9568C51FcAa79;
    address internal constant AAOION = 0x99888f2CCD08258eD5F66e94bA59d7E75016900F;
    address internal constant FXION = 0x2dD57b497c777D9825A5902114BE81dF98eDE958;
    address internal constant PRIMON = 0xBa6FF85f4595a3E71F3a965E6B528bBcf51A2c79;
    address internal constant CIFRON = 0x24E5Bc45d5b6Cef6F38989AC33dF587a3FC850cf;
    address internal constant ENPHON = 0x4F3B49aC895a29c0908c57538932967Cdc8e3c80;
    address internal constant BLSHON = 0x334ccd8Df4013bac99Af8C5C61d3605B315302a0;
    address internal constant QBTSON = 0x3807562A482B824C08A564DFefcc471806d3E00a;
    address internal constant UECON = 0x0F8887772262c449793890DCD3Bf320308dB423B;
    address internal constant RGTION = 0xfDFDf5db2F4A72cb754FfA8896EA012dC2cc0F5e;
    address internal constant BOTZON = 0x7AbeC847A3f9820397C82E1DAd231721Bf5a6732;
    address internal constant PENGON = 0x41fA6d32917E17cF29a5e93940471492D7c301C8;
    address internal constant ONDSON = 0x818234860A647D480b9BBCC9a47A23889f2Ec900;
    address internal constant AMCON = 0x592643a667633bCa51Cb2387C98B6dE6CE549A45;
    address internal constant USARON = 0xE2c149FA719d43912BfE584c71c9a6a018a5e916;
    address internal constant SOXQON = 0x4032d3076974b89238adfe61085EC57fC4522646;
    address internal constant GRNDON = 0xe5b26BA77E6a4d79a7c54a5296d81254269D9700;
    address internal constant ACHRON = 0x9cFA08002d606e638Fe91941bE725e1b970B84a6;
    address internal constant MARAON = 0x4604b0b581269843ac7a6b70A5FC019E7762e511;
    address internal constant GLXYON = 0xE668e08a6f5792CEF0e63E9D98524968fDB5882f;
    address internal constant AXTION = 0x6a3E77d984e22bed6A036D3DA79D7857936a593f;
    address internal constant OUSTON = 0x67A47353D5449fC24088190c44247d4D4E296073;
    address internal constant NVTSON = 0x2D9fc6C5dD136658ab6190f356ae3186c4Daa7D5;
    address internal constant USOON = 0x1F5fc5c3c8B0F15c7E21AF623936FF2b210b6415;
    address internal constant SQQQON = 0x0a00c19246Fc41B2524d56C87EC44Ce8b30Ba0f8;
    address internal constant RXRXON = 0xDaA3b81a3ACFcB60b875eBA1D26852376BC38486;
    address internal constant SOXSON = 0x01eb2eE6Ec05C304666210133B762088FF9965aC;
    address internal constant LUNRON = 0x58a2EDF0169eDE82904e47a0E2a3a4008eDebB60;
    address internal constant OIHON = 0xBcA31049ab4782f0FfA9CfFCB2cF48e8D6dE4fb8;
    address internal constant RDWON = 0x3a16aF9Ef328D087cc781053A2a2a27549aE6768;
    address internal constant PURRON = 0x211d1d372E6A782e9786b045004382834bDB224e;
    address internal constant DNNON = 0x7AA59A63d1D0C435a08bC96E11bef2E95aB66c40;
    address internal constant AION = 0x4554ad55ccA5e7CB97B77813f486aAf6D4D9AB62;
    address internal constant AEHRON = 0xeB48e68F01c0C76735dc6F1dcC0F151A973BD9d2;
    address internal constant WENON = 0x613518b520241f90c3E023Bb6006c63A5019CA7B;
    address internal constant PPLTON = 0xf1883461Ec7BD883A3668749c5CF5f351080d059;
    address internal constant SMRON = 0x0a600856eEDCe367eD49C3cd399775DC95d8BB5a;
    address internal constant URNMON = 0xa65db7879774BD6758ABaF583A91177AfD96D5A3;
    address internal constant UUUUON = 0xF14d47AeD45e16BF1f6E06904ac7f852FCe6cdf4;
    address internal constant SOUNON = 0x966dB065199A3edEa2228C6E5Eb6Ac49FF251AcC;
    address internal constant PLUGON = 0xe7ee911172bDD557B9Ab6Be7701F86BBc8FD772E;
    address internal constant IGEBON = 0x65513b741541025731124408DEb1A714699E3ee8;
    address internal constant SEDGON = 0x8E82a0d7347329703FB6c6A745B1C2b3aBB1658c;
    address internal constant WOLFON = 0x995584539633F7d28757B6329A42439BD8aeCEde;
    address internal constant OPENON = 0xB22d83E228c4266075Ec75c32aCc3BC059B6f248;
    address internal constant QUBTON = 0xc95c9e3fA311664b5e744B3C2716547BEc2Ba7dA;
    address internal constant KEELON = 0x96c662b152BEC886fAcab388bd98470FD3Aa9737;
    address internal constant INODON = 0x1C99a152e00a5dc40f8c3e893C1d04b0F6a48B0f;
    address internal constant SBETON = 0xfDb46864A7C476F0914c5E82CdED3364a9F56F8a;
    address internal constant BTDRON = 0x0683154c33B7563ed39951B4d7C0470EA28D93e9;
    address internal constant BBAION = 0x1b8d3e59b31981385C066eE0916Ec964628ff1f9;
    address internal constant BNOON = 0x9ddb2524782684942FAD28b44E76552cB7f3F548;
    address internal constant PSQON = 0x9ebd34d99Cc3a45B39CAFc14Ad7994263fa2Be56;
    address internal constant CPERON = 0x22a684E0A3cc9B74596719F722cf4e597AAFA3bA;
    address internal constant FCELON = 0xb71c4EBB4eDbAd867290206239C19DBb59eD55E1;
    address internal constant FLNCON = 0xf6C9C6b33BD3df0d761702db7075f89e561A54D8;
    address internal constant NNEON = 0xb5dd7ff8E2e4019cA7a55f10C13282071a5775D4;
    address internal constant BOTON = 0x0e05BA0756C504B69AAA642f7379CD1AF7C63969;
    address internal constant PALLON = 0x0cE36d199bd6851788e03392568849394cBdE722;
    address internal constant BTGOON = 0x510Dd21055188Eda378714DE3bb5591Ffa0CC468;
    address internal constant LPTHON = 0x9A73A9CC7c5889C521423870e896904F71562504;
    address internal constant EXODON = 0x185E5FA1B84F94D46ef2A33052aD39bD5f326fd8;
    address internal constant BWETON = 0xEcA55ac71f83931B7e074228AEBc9104F13d8c02;
    address internal constant BAION = 0x9463b0EE32c1b40B7fdA6459e815F0790159bC3A;
    address internal constant DRAMON = 0xdB5a8f5B4C17f2Ee2e7192A150687E48eB3C415d;
    address internal constant SATAON = 0x141196732cE4BB20010E4149704C0F278d5d3CEA;
    address internal constant STRCON = 0xECABE1Ff8a9e1dC55899cf58dac8497ecE5Ae84c;

    // ---------------------------------------------------------------------
    // The hundred-coin list, Ethereum-issued: CoinGecko's top 300 on 2026-10-10, less stablecoins, gold, stocks,
    // wrapped or staked derivatives, memecoins beyond SHIB, PEPE and DOGE, and the refused exchange tokens, keeping
    // only coins with a Pyth feed (design/2026-10-10-one-index-wormhole-legs.md, section 2). Each address is
    // CoinGecko's, read on chain on 2026-10-10 by symbol and decimals, and each passed `CheckToken` on a fork at block
    // 26,163,788. Refused by the check that day: LDO (the WBT rule: its MiniMe controller destroys any balance), ZAMA
    // (ERC-1363 callbacks) and NEAR's Rainbow bridge copy (24 decimals). Left for the owner's call: Binance's 2017 BNB
    // ERC-20 (0xB8c77482e45F1F44dE1745F52C74426C631bDD52), which Binance alone redeems; U (United Stables, which may
    // be a stablecoin); and EDGE and BEAM, whose Pyth feeds (EDGEX, BEAM) may name other coins. LEO, WLFI and GRAM
    // stay out under the earlier calls. Two of the 31 left on 2026-10-18, the owner's call after the source reading
    // (design/2026-10-18-token-source-reading.md): The Sandbox's SAND (0x3845badAde8e6dFF049820680d1F14bD3903a5d0),
    // whose two multisig admins and 22 operator contracts can move or burn any holder's balance with no timelock, and
    // Rollbit's RLB (0x046EeE2cc3188071C02BfC1745A6b17c656e3f3d), whose implementation is unverified and upgradeable by
    // one externally owned key. BitTorrent's BTT (0xC669928185DbCE49d2230CC9B0979BE6DC797957), as BTTC's bridge issued
    // it, left on 2026-10-19, the owner's call: that bridge closed in June 2026, so the copy redeems for nothing while
    // it would be priced as native BTT (audit/2026-10-18-red-team.md, RX-28).
    // ---------------------------------------------------------------------
    /// @dev Falcon Finance; no owner and no admin power.
    address internal constant FF = 0xFA1C09fC8B491B6A4d3Ff53A10CAd29381b3F949;
    /// @dev Gnosis; no owner.
    address internal constant GNO = 0x6810e776880C02933D47DB1b9fc05908e5386b96;
    /// @dev Olympus's OHM, 9 decimals.
    address internal constant OHM = 0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5;
    /// @dev The Graph.
    address internal constant GRT = 0xc944E90C64B2c07662A292be6244BDf05Cda44a7;
    /// @dev Maple Finance's SYRUP, priced at Pyth's MAPLE FINANCE feed.
    address internal constant SYRUP = 0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66;
    /// @dev Ethereum Name Service; owned by a timelock with a 2-day delay.
    address internal constant ENS = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
    /// @dev JasmyCoin.
    address internal constant JASMY = 0x7420B4b9a0110cdC71fB720908340C03F9Bc03EC;
    /// @dev Compound.
    address internal constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    /// @dev EigenLayer's EIGEN, a proxy upgraded by a 1-of-2 Safe whose owners are a 10-day timelock and a 9-of-13
    ///      Safe, either able to change the token's code alone (read on 2026-10-18).
    address internal constant EIGEN = 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;
    /// @dev Axie Infinity.
    address internal constant AXS = 0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b;
    /// @dev Basic Attention Token.
    address internal constant BAT = 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
    /// @dev Convex Finance.
    address internal constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    /// @dev Decentraland's MANA; its minter contract is owned by one externally owned key.
    address internal constant MANA = 0x0F5D2fB29fb7d3CFeE444a200298f468908cC942;
    /// @dev Immutable.
    address internal constant IMX = 0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF;
    /// @dev Fluid.
    address internal constant FLUID = 0x6f40d4A6237C257fff2dB00FA0510DeEECd303eb;
    /// @dev Chiliz, symbol CHZ.
    address internal constant CHZ = 0x3506424F91fD33084466F402d5D97f05F8e3b4AF;
    /// @dev ZKsync's ZK, a proxy upgraded by a contract, whose only minter is ZKsync's L1 Native Token Vault: ZK is
    ///      issued on ZKsync Era, so this is the bridge's copy, tiered Bridged, with ZKsync's bridge as its party (RX-19).
    address internal constant ZK = 0x66A5cFB2e9c529f14FE6364Ad1075dF3a649C0A5;
    /// @dev ApeCoin.
    address internal constant APE = 0x4d224452801ACEd8B2F0aebE155379bb5D594381;
    /// @dev Sentient.
    address internal constant SENT = 0x56A3BA04E95d34268A19b2a4474DC979baBDaf76;
    /// @dev Synthetix, owned by a 4-of-7 Safe.
    address internal constant SNX = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    /// @dev 1inch, symbol 1INCH (the identifier cannot start with a digit).
    address internal constant ONEINCH = 0x111111111117dC0aa78b770fA6A738034120C302;
    /// @dev Golem.
    address internal constant GLM = 0x7DD9c5Cba05E151C895FDe1CF355C9A1D5DA6429;
    /// @dev Aethir, owned by a 2-of-3 Safe.
    address internal constant ATH = 0xbe0Ed4138121EcFC5c0E56B40517da27E6c5226B;
    /// @dev Humanity's H, a proxy upgraded by a contract owned by a 4-of-7 Safe.
    address internal constant H = 0xE76c5b78f93909d34404E9eb4C1f19e7582a5dE1;
    /// @dev Plume Network.
    address internal constant PLUME = 0x4C1746A800D224393fE2470C70A35717eD4eA5F1;
    /// @dev Gala, 8 decimals.
    address internal constant GALA = 0xd1d2Eb1B1e90B638588728b4130137D262C87cae;
    /// @dev Wormhole's W, the Ethereum peer of its native-token-transfer mesh, owned by its transfer manager; the coin's home is Solana.
    address internal constant W = 0xB0fFa8000886e57F86dd5264b9582b2Ad87b2b91;
    /// @dev Reserve Rights.
    address internal constant RSR = 0x320623b8E4fF03373931769A31Fc52A4E78B5d70;

    // ---------------------------------------------------------------------
    // Wormhole's copies: coins Ethereum does not have, as Wormhole's token bridge (`WORMHOLE_TOKEN_BRIDGE`) wraps them
    // from the chain that has them (the owner's decision of 2026-10-10). The bridge owns each: it mints against the
    // source token locked on the home chain, burns on the way back, and its guardians' governance can upgrade every
    // copy's code at once, with no timelock. Each is priced at its coin's Pyth feed. `Custodial` when the source is a
    // Binance-Peg BEP-20, since Binance's custody stands under the bridge's; `Bridged` otherwise. None has Uniswap
    // depth: they mint in kind or through `MintRequests`, and a fill needs an executor that bridged them beforehand.
    // Each address was read on 2026-10-10 from the bridge's `wrappedAsset(chain, source)`, which
    // `test/fork/MainnetAddresses.fork.t.sol` repeats, and each passed `CheckToken` at block 26,163,788. BNB's, SUI's
    // and SEI's copies, which that day's count missed, were read the same way on 2026-10-18 and passed `CheckToken` at
    // block 26,215,111; Sui names a coin by its CoinMetadata object, and Sei's bridge a native denom by its keccak256
    // with the first byte set to 1. DOGE's copy
    // (0xd881A7F17Ed2c71FD671AfbA3A9b30Eb914Aea5F, from Binance-Peg DOGE 0xba2ae424d960c26247dd6c32edc70b295c744c43 on
    // BNB Chain) was taken off the list on 2026-10-14, the owner's call, for now: Pyth prices DOGE, not the copy, so
    // a broken peg or bridge leaves the copy priced as DOGE, and the source is a proxy whose admin, one externally
    // owned key, can replace its code (read on BNB Chain that day).
    //
    // The six copies wrapped from BNB Chain (XRP, ADA, LTC, DOT, ATOM and BNB, Wormhole chain 4) were taken off the
    // list on 2026-11-13, the owner's call: BNB Chain's deployment holds those coins in kind (`BnbChainAddresses`),
    // with no bridge under them. Their addresses stay recorded here for a relisting, and
    // `test/fork/MainnetAddresses.fork.t.sol` still checks each against its source.
    //
    // JUP, PYTH, SUI, APT and ALGO were taken off the list on 2026-11-18, the owner's call: with no Ethereum pool, a
    // rebalance can buy them only from stock bridged in from Solana, Sui, Aptos or Algorand, whose restock has never
    // run (design/2026-11-18-bridged-coins-in-a-rebalance.md). Their addresses stay here too, for a relisting.
    // ---------------------------------------------------------------------
    /// @dev XRP as the bridge wraps Binance-Peg XRP (0x1d2f0da169ceb9fc7b3144628db156f3f6c60dbe on BNB Chain, Wormhole chain 4): symbol XRP, 18 decimals.
    address internal constant XRP = 0xc730d8256B8A1030eEA67f1Bc7ebed3898f7A535;
    /// @dev ADA as the bridge wraps Binance-Peg ADA (0x3ee2200efb3400fabb9aacf31297cbdd1d435d47 on BNB Chain, Wormhole chain 4): symbol ADA, 18 decimals.
    address internal constant ADA = 0x8EfFbF747d4A60Bc6b68D9A1bE4c4188bA8A3a0b;
    /// @dev LTC as the bridge wraps Binance-Peg LTC (0x4338665cbb7b2485a8855a139b75d5e34ab0db94 on BNB Chain, Wormhole chain 4): symbol LTC, 18 decimals.
    address internal constant LTC = 0x1cA1Ef3fB8Ff4a480C0ae7eea5f91A24a5BB3344;
    /// @dev AVAX as the bridge wraps Avalanche's WAVAX (0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, Wormhole chain 6): symbol WAVAX, 18 decimals.
    address internal constant AVAX = 0x85f138bfEE4ef8e540890CFb48F620571d67Eda3;
    /// @dev DOT as the bridge wraps Binance-Peg DOT (0x7083609fce4d1d8dc0c979aab8c869ea2c873402 on BNB Chain, Wormhole chain 4): symbol DOT, 18 decimals.
    address internal constant DOT = 0x1839a38E59536D88C25e8E6e0D0f59e05b143ab2;
    /// @dev JUP as the bridge wraps Solana's mint JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN (Wormhole chain 1): symbol JUP, 6 decimals.
    address internal constant JUP = 0x8687a10BCa6F139B25eb31020FCABB5782214764;
    /// @dev ALGO as the bridge wraps Algorand's ALGO itself (asset 0, Wormhole chain 8): symbol ALGO, 6 decimals.
    address internal constant ALGO = 0xe31Cfcd36FeD044ae4Cf9405B577fe875762194F;
    /// @dev ATOM as the bridge wraps Binance-Peg ATOM (0x0eb3a705fc54725037cc9e008bdede697f62f335 on BNB Chain, Wormhole chain 4): symbol ATOM, 18 decimals.
    address internal constant ATOM = 0x7845167B54253269624dBA0cA5Fee87933107b34;
    /// @dev AERO as the bridge wraps Base's 0x940181a94a35a4569e4529a3cdfb74e38fd98631 (Wormhole chain 30): symbol AERO, 18 decimals.
    address internal constant AERO = 0x750525C1877E30304F1E22b1b49b4C9DdE674ddF;
    /// @dev APT as the bridge wraps Aptos's APT itself (0x1::aptos_coin::AptosCoin, Wormhole chain 22): symbol APT, 8 decimals.
    address internal constant APT = 0x8CDf7AF57E4c8B930e1B23c477c22f076530585e;
    /// @dev Pyth Network's PYTH (`PYTH_TOKEN`, since `PYTH` is Pyth's price contract below) as the bridge wraps Solana's mint HZ1JovNiVvGrGNiiYvEozEVgZ58xaU3RKwX8eACQBCt3 (Wormhole chain 1): symbol PYTH, 6 decimals.
    address internal constant PYTH_TOKEN = 0xeFc0CED4B3D536103e76a1c4c74F0385C8F4Bdd3;
    // OP's copy is off the list since 2026-11-21 (the owner's call), and kept here for a relisting: OP's pools on
    // Optimism were too thin that day for the restock to buy it.
    /// @dev OP as the bridge wraps Optimism's 0x4200000000000000000000000000000000000042 (Wormhole chain 24): symbol OP, 18 decimals.
    address internal constant OP = 0x1df721D242E0783F8fCab4A9FfE4F35bdf329909;
    /// @dev BNB as the bridge wraps BNB Chain's WBNB (0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, Wormhole chain 4), the wrapper of BNB itself rather than a Binance-Peg token: symbol WBNB, 18 decimals.
    address internal constant BNB = 0x418D75f65a02b3D53B2418FB8E1fe493759c7605;
    /// @dev SUI as the bridge wraps Sui's SUI itself (0x2::sui::SUI, its CoinMetadata object 0x9258181f5ceac8dbffb7030890243caed69a9599d2886d957a9cb7656af3bdb3, Wormhole chain 21): symbol SUI, 9 decimals.
    address internal constant SUI = 0x84074EA631dEc7a4edcD5303d164D5dEa4c653D6;
    // SEI's copy (0xf91e605af079384cc7077B3914A4a36019a89EE8, Sei's usei from Wormhole chain 32) left on 2026-10-19, the
    // owner's call: it redeems only through Sei's CosmWasm side, which Sei is shutting down (RX-32).

    // ---------------------------------------------------------------------
    // Mint and burn currencies. Never components; see the whitelist policy.
    // ---------------------------------------------------------------------
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // ---------------------------------------------------------------------
    // Execution.
    // ---------------------------------------------------------------------
    /// @dev Uniswap Universal Router 2.0.0, which routes both V3 and V4 pools. Pinned to this deployment rather than
    ///      the 2.1.x line, whose V3 inputs carry an extra per-hop price array (`minHopPriceX36`) the zap does not
    ///      encode: a 2.0.0-shaped input reverts SliceOutOfBounds on the labelled 2.1.1 and 2.1.2 releases. One
    ///      unlabelled 2.1-line deployment, 0x0542093271A31f6FC1DADB232bd59eeb27de780F, also carried #491 and #497,
    ///      which upstream later reverted; the labelled releases carry neither (CR-I19). Its runtime code hash is
    ///      pinned by `test/fork/MainnetAddresses.fork.t.sol`, since every build answers `poolManager()` the same way.
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// @dev Uniswap V4 singleton the Universal Router settles V4 legs against. The zap reads it from the router
    ///      rather than taking it as an argument, so the two can never be wired to different deployments.
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @dev Uniswap V3's factory, where `CheckToken` looks up a token's pools to record its depth before a listing. No
    ///      contract reads it. Its runtime code hash is pinned by `test/fork/MainnetAddresses.fork.t.sol`.
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /// @dev Pyth's price contract, a proxy, through which the factory's `PythPrices` reads the price a fill is checked
    ///      against (the owner's call of 2026-11-22). A filler posts a fresh update to it in its own transaction. Read
    ///      on chain that day: it answers `priceFeedExists` for ETH/USD, and `DeployChecks` resolves it as it does the
    ///      router.
    address internal constant PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    // ---------------------------------------------------------------------
    // Bridges. No contract calls one; the app and the fillers do.
    // ---------------------------------------------------------------------
    /// @dev Wormhole's token bridge on Ethereum (Portal), which owns every Wormhole copy above: `wrappedAsset(chain,
    ///      source)` names the copy of a source token, and `isWrappedAsset(token)` says whether a token is one. An
    ///      ERC-1967 proxy the guardians' governance upgrades; its proxy code hash is pinned by
    ///      `test/fork/MainnetAddresses.fork.t.sol`. Anyone attests a new source token on its home chain,
    ///      and the bridge deploys its copy here (design/2026-10-10-one-index-wormhole-legs.md, section 5).
    address internal constant WORMHOLE_TOKEN_BRIDGE = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;
}
