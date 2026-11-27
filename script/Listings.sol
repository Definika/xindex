// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MainnetAddresses as M} from "./MainnetAddresses.sol";

/// @notice The Ethereum tokens Xindex lists, in listing order, and each one's trust tier. Each token's Pyth feed is in
///         `PriceFeeds`, for the check that can only refuse a fill (`docs/design/pyth-check.md`). What the list holds:
///         - The issuer's own contract for each coin Ethereum has, Bitcoin as WBTC, and Tether Gold.
///         - Wormhole's copies of SOL and AVAX, labelled Bridged (docs/design/wormhole-legs.md).
///         - Every Ondo stock and ETF Pyth has a feed for, ANTon among them, each `Custodial`
///           (docs/design/ondo-stocks.md). One without a feed joins when Pyth publishes one; USDY and OUSG, Ondo's
///           cash tokens, are not listed, nor are Backed's xStocks.
///         What it leaves out, by the owner's decisions:
///         - GRAM, its bridge closed; OKB, being retired on Ethereum; BGB and GT, which no Uniswap route trades
///           (docs/design/wide-asset-support.md, section 6). DOGE's copy (`MainnetAddresses`). SAND and RLB, after
///           their source reading (docs/design/token-source-reading.md).
///         - A Wormhole copy whose bridge has closed or is closing: BTT's and SEI's (RX-28, RX-32).
///         - A copy of a coin BNB Chain's deployment holds in kind: XRP, ADA, LTC, DOT, ATOM and BNB, each wrapped
///           from BNB Chain (docs/design/bnb-chain.md).
///         - A copy no Ethereum pool trades and no restock route serves: JUP, PYTH, SUI, APT and ALGO
///           (docs/design/bridged-coins.md), and OP, whose deepest pool on Optimism holds about $35,000 of USDC.
///         - Wormhole's copy of Aerodrome's old AERO, which Aero replaced with a token of its own: the copy redeems to
///           the old token alone. Base lists Aero's token (docs/design/chain-venues.md).
///         The addresses of what left stay in `MainnetAddresses` for a relisting, and `CHANGELOG.md` records how the
///         list came to be.
library Listings {
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 414;

    /// @notice A token's trust tier (docs/design/wide-asset-support.md, section 1), shown by the app beside every
    ///         index that holds it and by `ConfigureWeighted`'s safe mode beside every listing.
    enum Tier {
        Unrecorded,
        Native,
        Bridged,
        Custodial
    }

    /// @notice The tier of a token in the table: `Custodial` for WBTC (BitGo holds the bitcoin), Tether Gold and the
    ///         Ondo stocks; `Bridged` for a bridge's copy of a coin issued elsewhere, Wormhole's copies among them;
    ///         `Native` for a token issued on Ethereum, ether's WETH among them; and `Unrecorded` for any token off the
    ///         table. No copy of a Binance-Peg coin is listed: those were the `Custodial` copies.
    function tierOf(address token) internal pure returns (Tier) {
        if (
            token == M.WBTC || token == M.XAUT || token == M.NVDAON || token == M.AAPLON || token == M.GOOGLON
                || token == M.MSFTON || token == M.AMZNON || token == M.TSMON || token == M.SPCXON || token == M.METAON
                || token == M.AVGOON || token == M.TSLAON || token == M.SKHYON || token == M.MUON || token == M.LLYON
                || token == M.AMDON || token == M.JPMON || token == M.WMTON || token == M.VON
        ) return Tier.Custodial;
        if (
            token == M.GOOGON || token == M.IVVON || token == M.SPYON || token == M.VTION || token == M.XOMON
                || token == M.JNJON || token == M.MAON || token == M.ASMLON || token == M.ABBVON || token == M.COSTON
                || token == M.QQQON || token == M.KOON || token == M.CVXON || token == M.PGON || token == M.PLTRON
                || token == M.CSCOON || token == M.ORCLON || token == M.GEON || token == M.BACON || token == M.HDON
                || token == M.MRKON || token == M.INTCON || token == M.UNHON || token == M.PANWON || token == M.AMATON
                || token == M.LRCXON || token == M.TXNON || token == M.RTXON || token == M.TMOON || token == M.CRWDON
                || token == M.CATON || token == M.GSON || token == M.ANETON || token == M.NFLXON || token == M.WFCON
                || token == M.SAPON || token == M.AMGNON || token == M.LINON || token == M.IBMON || token == M.BABAON
                || token == M.AXPON || token == M.DISON || token == M.GEVON || token == M.DELLON || token == M.ARMON
                || token == M.CON || token == M.APHON || token == M.MCDON || token == M.KLACON || token == M.PEPON
                || token == M.VTVON || token == M.VZON || token == M.ADION || token == M.IEFAON || token == M.ABTON
                || token == M.BLKON || token == M.QCOMON || token == M.SHOPON || token == M.NEEON || token == M.UNPON
                || token == M.NVOON || token == M.TMUSON || token == M.DEON || token == M.SCHWON || token == M.COPON
                || token == M.PFEON || token == M.CRMON || token == M.TON || token == M.ISRGON || token == M.AGGON
                || token == M.IEMGON || token == M.UBERON || token == M.VRTXON || token == M.LMTON || token == M.MRVLON
                || token == M.ETNON || token == M.ACNON || token == M.SPGION || token == M.APPON || token == M.BAON
                || token == M.STXON || token == M.SCCOON || token == M.PDDON || token == M.GLDON || token == M.LOWON
                || token == M.SPOTON || token == M.SBUXON || token == M.IJHON || token == M.SGOVON || token == M.WDCON
                || token == M.SNDKON || token == M.IWFON || token == M.NETON || token == M.COFON || token == M.SOON
                || token == M.PBRON || token == M.NEMON || token == M.ABNBON || token == M.ENBON || token == M.EQIXON
                || token == M.SNOWON || token == M.REGNON || token == M.NOWON || token == M.GLWON || token == M.WMON
                || token == M.GDON || token == M.ITOTON || token == M.CEGON || token == M.PWRON || token == M.TTON
                || token == M.EMRON || token == M.ADBEON || token == M.INTUON || token == M.WMBON || token == M.CVNAON
                || token == M.MRNAON || token == M.NOCON || token == M.VRTON || token == M.EFAON || token == M.IWMON
                || token == M.FCXON || token == M.SLBON || token == M.DASHON || token == M.APOON || token == M.MELION
                || token == M.NTESON || token == M.HOODON || token == M.HPEON || token == M.TELON || token == M.NUEON
                || token == M.IAUON || token == M.AMEON || token == M.OXYON || token == M.BEON || token == M.NKEON
                || token == M.LITEON || token == M.KEYSON || token == M.IBITON || token == M.BILON || token == M.PYPLON
                || token == M.TLTON || token == M.XYZON || token == M.CMGON || token == M.FON || token == M.COHRON
                || token == M.NOKON || token == M.NTRAON || token == M.IEFON || token == M.VSTON || token == M.ROKON
                || token == M.SOXXON || token == M.DYNFON || token == M.STMON || token == M.TTWOON || token == M.CIENON
                || token == M.ALABON || token == M.MSTRON || token == M.VNQON || token == M.TERON || token == M.RKLBON
                || token == M.UMCON || token == M.JDON || token == M.JAAAON || token == M.CLSON || token == M.STLDON
                || token == M.EQTON || token == M.NBISON || token == M.INSMON || token == M.PCGON || token == M.COINON
                || token == M.TQQQON || token == M.EFVON || token == M.FLEXON || token == M.SHYON || token == M.VRSNON
                || token == M.CCJON || token == M.CRWVON || token == M.TCOMON || token == M.EEMON || token == M.ONON
                || token == M.HALON || token == M.CPNGON || token == M.JBLON || token == M.BIDUON || token == M.CRDOON
                || token == M.CBRSON || token == M.SLVON || token == M.HUBBON || token == M.IYWON || token == M.EWJON
                || token == M.GFSON || token == M.ENTGON || token == M.USFRON || token == M.EWYON || token == M.SWKSON
                || token == M.SOFION || token == M.HYGON || token == M.NVTON || token == M.RDDTON || token == M.MTSION
                || token == M.RIVNON || token == M.LSCCON || token == M.SMCION || token == M.TLNON || token == M.WCCON
                || token == M.TSEMON || token == M.LECOON || token == M.MKSION || token == M.TIPON || token == M.CRCLON
                || token == M.MTZON || token == M.IWNON || token == M.GMEON || token == M.SOXLON || token == M.PAVEON
                || token == M.FUTUON || token == M.IGVON || token == M.GRABON || token == M.GNRCON || token == M.FNON
                || token == M.ITAON || token == M.HIION || token == M.IONQON || token == M.LION || token == M.ALBON
                || token == M.ONTOON || token == M.PINSON || token == M.NVMION || token == M.BMNRON || token == M.SNAPON
                || token == M.FIGON || token == M.AIQON || token == M.AMKRON || token == M.AALON || token == M.RMBSON
                || token == M.OSCRON || token == M.TWSTON || token == M.EWZON || token == M.ASTSON || token == M.AURON
                || token == M.TTMION || token == M.HUTON || token == M.VICRON || token == M.INDAON || token == M.CLFON
                || token == M.NIOON || token == M.RIOTON || token == M.MPON || token == M.FORMON || token == M.IRENON
                || token == M.WULFON || token == M.FPSON || token == M.FIGRON || token == M.POWLON || token == M.SHLDON
                || token == M.AGON || token == M.CAION || token == M.ETHAON || token == M.COPXON || token == M.CORZON
                || token == M.BILION || token == M.MXLON || token == M.APLDON || token == M.PLON || token == M.KWEBON
                || token == M.OKLOON || token == M.URAON || token == M.VSHON || token == M.HIMSON || token == M.AAOION
                || token == M.FXION || token == M.PRIMON || token == M.CIFRON || token == M.ENPHON || token == M.BLSHON
                || token == M.QBTSON || token == M.UECON || token == M.RGTION || token == M.BOTZON || token == M.PENGON
                || token == M.ONDSON || token == M.AMCON || token == M.USARON || token == M.SOXQON || token == M.GRNDON
                || token == M.ACHRON || token == M.MARAON || token == M.GLXYON || token == M.AXTION || token == M.OUSTON
                || token == M.NVTSON || token == M.USOON || token == M.SQQQON || token == M.RXRXON || token == M.SOXSON
                || token == M.LUNRON || token == M.OIHON || token == M.RDWON || token == M.PURRON || token == M.DNNON
                || token == M.AION || token == M.AEHRON || token == M.WENON || token == M.PPLTON || token == M.SMRON
                || token == M.URNMON || token == M.UUUUON || token == M.SOUNON || token == M.PLUGON || token == M.IGEBON
                || token == M.SEDGON || token == M.WOLFON || token == M.OPENON || token == M.QUBTON || token == M.KEELON
                || token == M.INODON || token == M.SBETON || token == M.BTDRON || token == M.BBAION || token == M.BNOON
                || token == M.PSQON || token == M.CPERON || token == M.FCELON || token == M.FLNCON || token == M.NNEON
                || token == M.BOTON || token == M.PALLON || token == M.BTGOON || token == M.LPTHON || token == M.EXODON
                || token == M.BWETON || token == M.BAION || token == M.DRAMON || token == M.SATAON || token == M.STRCON
                || token == M.ANTON
        ) return Tier.Custodial;
        if (
            token == M.CRO || token == M.ICP || token == M.ARB || token == M.RENDER || token == M.CAKE || token == M.ZRO
                || token == M.INJ || token == M.SOL || token == M.W || token == M.ZK || token == M.AVAX
        ) return Tier.Bridged;
        if (
            token == M.WETH || token == M.LINK || token == M.UNI || token == M.QNT || token == M.AAVE || token == M.ENA
                || token == M.ONDO || token == M.SKY || token == M.WLD || token == M.MNT || token == M.MORPHO
                || token == M.POL || token == M.LIT || token == M.ETHFI || token == M.FET || token == M.CRV
                || token == M.NEXO || token == M.VIRTUAL || token == M.STRK || token == M.PENDLE || token == M.SHIB
                || token == M.PEPE || token == M.FF || token == M.GNO || token == M.OHM || token == M.GRT
                || token == M.SYRUP || token == M.ENS || token == M.JASMY || token == M.COMP || token == M.EIGEN
                || token == M.AXS || token == M.BAT || token == M.CVX || token == M.MANA || token == M.IMX
                || token == M.FLUID || token == M.CHZ || token == M.APE || token == M.SENT || token == M.SNX
                || token == M.ONEINCH || token == M.GLM || token == M.ATH || token == M.H || token == M.PLUME
                || token == M.GALA || token == M.RSR
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

    /// @notice Every coin of the list: WETH, WBTC, LINK and UNI first, the `default` list, then the wide
    ///         list's first 45 coins and its first additions, then the hundred-coin list's 28 Ethereum-issued coins and
    ///         its one Wormhole copy, each group by market cap, then Ondo's tokens.
    function all() internal pure returns (address[] memory tokens) {
        tokens = new address[](COUNT);
        tokens[0] = M.WETH;
        tokens[1] = M.WBTC;
        tokens[2] = M.LINK;
        tokens[3] = M.UNI;
        tokens[4] = M.QNT;
        tokens[5] = M.AAVE;
        tokens[6] = M.ENA;
        tokens[7] = M.ONDO;
        tokens[8] = M.SKY;
        tokens[9] = M.WLD;
        tokens[10] = M.MNT;
        tokens[11] = M.MORPHO;
        tokens[12] = M.POL;
        tokens[13] = M.LIT;
        tokens[14] = M.ETHFI;
        tokens[15] = M.FET;
        tokens[16] = M.CRV;
        tokens[17] = M.NEXO;
        tokens[18] = M.VIRTUAL;
        tokens[19] = M.STRK;
        tokens[20] = M.PENDLE;
        tokens[21] = M.CRO;
        tokens[22] = M.ICP;
        tokens[23] = M.ARB;
        tokens[24] = M.RENDER;
        tokens[25] = M.CAKE;
        tokens[26] = M.ZRO;
        tokens[27] = M.INJ;
        tokens[28] = M.SHIB;
        tokens[29] = M.PEPE;
        tokens[30] = M.SOL;
        tokens[31] = M.XAUT;
        tokens[32] = M.NVDAON;
        tokens[33] = M.AAPLON;
        tokens[34] = M.GOOGLON;
        tokens[35] = M.MSFTON;
        tokens[36] = M.AMZNON;
        tokens[37] = M.TSMON;
        tokens[38] = M.SPCXON;
        tokens[39] = M.METAON;
        tokens[40] = M.AVGOON;
        tokens[41] = M.TSLAON;
        tokens[42] = M.SKHYON;
        tokens[43] = M.MUON;
        tokens[44] = M.LLYON;
        tokens[45] = M.AMDON;
        tokens[46] = M.JPMON;
        tokens[47] = M.WMTON;
        tokens[48] = M.VON;
        tokens[49] = M.FF;
        tokens[50] = M.GNO;
        tokens[51] = M.OHM;
        tokens[52] = M.GRT;
        tokens[53] = M.SYRUP;
        tokens[54] = M.ENS;
        tokens[55] = M.JASMY;
        tokens[56] = M.COMP;
        tokens[57] = M.EIGEN;
        tokens[58] = M.AXS;
        tokens[59] = M.BAT;
        tokens[60] = M.CVX;
        tokens[61] = M.MANA;
        tokens[62] = M.IMX;
        tokens[63] = M.FLUID;
        tokens[64] = M.CHZ;
        tokens[65] = M.ZK;
        tokens[66] = M.APE;
        tokens[67] = M.SENT;
        tokens[68] = M.SNX;
        tokens[69] = M.ONEINCH;
        tokens[70] = M.GLM;
        tokens[71] = M.ATH;
        tokens[72] = M.H;
        tokens[73] = M.PLUME;
        tokens[74] = M.GALA;
        tokens[75] = M.W;
        tokens[76] = M.RSR;
        tokens[77] = M.AVAX;
        tokens[78] = M.GOOGON;
        tokens[79] = M.IVVON;
        tokens[80] = M.SPYON;
        tokens[81] = M.VTION;
        tokens[82] = M.XOMON;
        tokens[83] = M.JNJON;
        tokens[84] = M.MAON;
        tokens[85] = M.ASMLON;
        tokens[86] = M.ABBVON;
        tokens[87] = M.COSTON;
        tokens[88] = M.QQQON;
        tokens[89] = M.KOON;
        tokens[90] = M.CVXON;
        tokens[91] = M.PGON;
        tokens[92] = M.PLTRON;
        tokens[93] = M.CSCOON;
        tokens[94] = M.ORCLON;
        tokens[95] = M.GEON;
        tokens[96] = M.BACON;
        tokens[97] = M.HDON;
        tokens[98] = M.MRKON;
        tokens[99] = M.INTCON;
        tokens[100] = M.UNHON;
        tokens[101] = M.PANWON;
        tokens[102] = M.AMATON;
        tokens[103] = M.LRCXON;
        tokens[104] = M.TXNON;
        tokens[105] = M.RTXON;
        tokens[106] = M.TMOON;
        tokens[107] = M.CRWDON;
        tokens[108] = M.CATON;
        tokens[109] = M.GSON;
        tokens[110] = M.ANETON;
        tokens[111] = M.NFLXON;
        tokens[112] = M.WFCON;
        tokens[113] = M.SAPON;
        tokens[114] = M.AMGNON;
        tokens[115] = M.LINON;
        tokens[116] = M.IBMON;
        tokens[117] = M.BABAON;
        tokens[118] = M.AXPON;
        tokens[119] = M.DISON;
        tokens[120] = M.GEVON;
        tokens[121] = M.DELLON;
        tokens[122] = M.ARMON;
        tokens[123] = M.CON;
        tokens[124] = M.APHON;
        tokens[125] = M.MCDON;
        tokens[126] = M.KLACON;
        tokens[127] = M.PEPON;
        tokens[128] = M.VTVON;
        tokens[129] = M.VZON;
        tokens[130] = M.ADION;
        tokens[131] = M.IEFAON;
        tokens[132] = M.ABTON;
        tokens[133] = M.BLKON;
        tokens[134] = M.QCOMON;
        tokens[135] = M.SHOPON;
        tokens[136] = M.NEEON;
        tokens[137] = M.UNPON;
        tokens[138] = M.NVOON;
        tokens[139] = M.TMUSON;
        tokens[140] = M.DEON;
        tokens[141] = M.SCHWON;
        tokens[142] = M.COPON;
        tokens[143] = M.PFEON;
        tokens[144] = M.CRMON;
        tokens[145] = M.TON;
        tokens[146] = M.ISRGON;
        tokens[147] = M.AGGON;
        tokens[148] = M.IEMGON;
        tokens[149] = M.UBERON;
        tokens[150] = M.VRTXON;
        tokens[151] = M.LMTON;
        tokens[152] = M.MRVLON;
        tokens[153] = M.ETNON;
        tokens[154] = M.ACNON;
        tokens[155] = M.SPGION;
        tokens[156] = M.APPON;
        tokens[157] = M.BAON;
        tokens[158] = M.STXON;
        tokens[159] = M.SCCOON;
        tokens[160] = M.PDDON;
        tokens[161] = M.GLDON;
        tokens[162] = M.LOWON;
        tokens[163] = M.SPOTON;
        tokens[164] = M.SBUXON;
        tokens[165] = M.IJHON;
        tokens[166] = M.SGOVON;
        tokens[167] = M.WDCON;
        tokens[168] = M.SNDKON;
        tokens[169] = M.IWFON;
        tokens[170] = M.NETON;
        tokens[171] = M.COFON;
        tokens[172] = M.SOON;
        tokens[173] = M.PBRON;
        tokens[174] = M.NEMON;
        tokens[175] = M.ABNBON;
        tokens[176] = M.ENBON;
        tokens[177] = M.EQIXON;
        tokens[178] = M.SNOWON;
        tokens[179] = M.REGNON;
        tokens[180] = M.NOWON;
        tokens[181] = M.GLWON;
        tokens[182] = M.WMON;
        tokens[183] = M.GDON;
        tokens[184] = M.ITOTON;
        tokens[185] = M.CEGON;
        tokens[186] = M.PWRON;
        tokens[187] = M.TTON;
        tokens[188] = M.EMRON;
        tokens[189] = M.ADBEON;
        tokens[190] = M.INTUON;
        tokens[191] = M.WMBON;
        tokens[192] = M.CVNAON;
        tokens[193] = M.MRNAON;
        tokens[194] = M.NOCON;
        tokens[195] = M.VRTON;
        tokens[196] = M.EFAON;
        tokens[197] = M.IWMON;
        tokens[198] = M.FCXON;
        tokens[199] = M.SLBON;
        tokens[200] = M.DASHON;
        tokens[201] = M.APOON;
        tokens[202] = M.MELION;
        tokens[203] = M.NTESON;
        tokens[204] = M.HOODON;
        tokens[205] = M.HPEON;
        tokens[206] = M.TELON;
        tokens[207] = M.NUEON;
        tokens[208] = M.IAUON;
        tokens[209] = M.AMEON;
        tokens[210] = M.OXYON;
        tokens[211] = M.BEON;
        tokens[212] = M.NKEON;
        tokens[213] = M.LITEON;
        tokens[214] = M.KEYSON;
        tokens[215] = M.IBITON;
        tokens[216] = M.BILON;
        tokens[217] = M.PYPLON;
        tokens[218] = M.TLTON;
        tokens[219] = M.XYZON;
        tokens[220] = M.CMGON;
        tokens[221] = M.FON;
        tokens[222] = M.COHRON;
        tokens[223] = M.NOKON;
        tokens[224] = M.NTRAON;
        tokens[225] = M.IEFON;
        tokens[226] = M.VSTON;
        tokens[227] = M.ROKON;
        tokens[228] = M.SOXXON;
        tokens[229] = M.DYNFON;
        tokens[230] = M.STMON;
        tokens[231] = M.TTWOON;
        tokens[232] = M.CIENON;
        tokens[233] = M.ALABON;
        tokens[234] = M.MSTRON;
        tokens[235] = M.VNQON;
        tokens[236] = M.TERON;
        tokens[237] = M.RKLBON;
        tokens[238] = M.UMCON;
        tokens[239] = M.JDON;
        tokens[240] = M.JAAAON;
        tokens[241] = M.CLSON;
        tokens[242] = M.STLDON;
        tokens[243] = M.EQTON;
        tokens[244] = M.NBISON;
        tokens[245] = M.INSMON;
        tokens[246] = M.PCGON;
        tokens[247] = M.COINON;
        tokens[248] = M.TQQQON;
        tokens[249] = M.EFVON;
        tokens[250] = M.FLEXON;
        tokens[251] = M.SHYON;
        tokens[252] = M.VRSNON;
        tokens[253] = M.CCJON;
        tokens[254] = M.CRWVON;
        tokens[255] = M.TCOMON;
        tokens[256] = M.EEMON;
        tokens[257] = M.ONON;
        tokens[258] = M.HALON;
        tokens[259] = M.CPNGON;
        tokens[260] = M.JBLON;
        tokens[261] = M.BIDUON;
        tokens[262] = M.CRDOON;
        tokens[263] = M.CBRSON;
        tokens[264] = M.SLVON;
        tokens[265] = M.HUBBON;
        tokens[266] = M.IYWON;
        tokens[267] = M.EWJON;
        tokens[268] = M.GFSON;
        tokens[269] = M.ENTGON;
        tokens[270] = M.USFRON;
        tokens[271] = M.EWYON;
        tokens[272] = M.SWKSON;
        tokens[273] = M.SOFION;
        tokens[274] = M.HYGON;
        tokens[275] = M.NVTON;
        tokens[276] = M.RDDTON;
        tokens[277] = M.MTSION;
        tokens[278] = M.RIVNON;
        tokens[279] = M.LSCCON;
        tokens[280] = M.SMCION;
        tokens[281] = M.TLNON;
        tokens[282] = M.WCCON;
        tokens[283] = M.TSEMON;
        tokens[284] = M.LECOON;
        tokens[285] = M.MKSION;
        tokens[286] = M.TIPON;
        tokens[287] = M.CRCLON;
        tokens[288] = M.MTZON;
        tokens[289] = M.IWNON;
        tokens[290] = M.GMEON;
        tokens[291] = M.SOXLON;
        tokens[292] = M.PAVEON;
        tokens[293] = M.FUTUON;
        tokens[294] = M.IGVON;
        tokens[295] = M.GRABON;
        tokens[296] = M.GNRCON;
        tokens[297] = M.FNON;
        tokens[298] = M.ITAON;
        tokens[299] = M.HIION;
        tokens[300] = M.IONQON;
        tokens[301] = M.LION;
        tokens[302] = M.ALBON;
        tokens[303] = M.ONTOON;
        tokens[304] = M.PINSON;
        tokens[305] = M.NVMION;
        tokens[306] = M.BMNRON;
        tokens[307] = M.SNAPON;
        tokens[308] = M.FIGON;
        tokens[309] = M.AIQON;
        tokens[310] = M.AMKRON;
        tokens[311] = M.AALON;
        tokens[312] = M.RMBSON;
        tokens[313] = M.OSCRON;
        tokens[314] = M.TWSTON;
        tokens[315] = M.EWZON;
        tokens[316] = M.ASTSON;
        tokens[317] = M.AURON;
        tokens[318] = M.TTMION;
        tokens[319] = M.HUTON;
        tokens[320] = M.VICRON;
        tokens[321] = M.INDAON;
        tokens[322] = M.CLFON;
        tokens[323] = M.NIOON;
        tokens[324] = M.RIOTON;
        tokens[325] = M.MPON;
        tokens[326] = M.FORMON;
        tokens[327] = M.IRENON;
        tokens[328] = M.WULFON;
        tokens[329] = M.FPSON;
        tokens[330] = M.FIGRON;
        tokens[331] = M.POWLON;
        tokens[332] = M.SHLDON;
        tokens[333] = M.AGON;
        tokens[334] = M.CAION;
        tokens[335] = M.ETHAON;
        tokens[336] = M.COPXON;
        tokens[337] = M.CORZON;
        tokens[338] = M.BILION;
        tokens[339] = M.MXLON;
        tokens[340] = M.APLDON;
        tokens[341] = M.PLON;
        tokens[342] = M.KWEBON;
        tokens[343] = M.OKLOON;
        tokens[344] = M.URAON;
        tokens[345] = M.VSHON;
        tokens[346] = M.HIMSON;
        tokens[347] = M.AAOION;
        tokens[348] = M.FXION;
        tokens[349] = M.PRIMON;
        tokens[350] = M.CIFRON;
        tokens[351] = M.ENPHON;
        tokens[352] = M.BLSHON;
        tokens[353] = M.QBTSON;
        tokens[354] = M.UECON;
        tokens[355] = M.RGTION;
        tokens[356] = M.BOTZON;
        tokens[357] = M.PENGON;
        tokens[358] = M.ONDSON;
        tokens[359] = M.AMCON;
        tokens[360] = M.USARON;
        tokens[361] = M.SOXQON;
        tokens[362] = M.GRNDON;
        tokens[363] = M.ACHRON;
        tokens[364] = M.MARAON;
        tokens[365] = M.GLXYON;
        tokens[366] = M.AXTION;
        tokens[367] = M.OUSTON;
        tokens[368] = M.NVTSON;
        tokens[369] = M.USOON;
        tokens[370] = M.SQQQON;
        tokens[371] = M.RXRXON;
        tokens[372] = M.SOXSON;
        tokens[373] = M.LUNRON;
        tokens[374] = M.OIHON;
        tokens[375] = M.RDWON;
        tokens[376] = M.PURRON;
        tokens[377] = M.DNNON;
        tokens[378] = M.AION;
        tokens[379] = M.AEHRON;
        tokens[380] = M.WENON;
        tokens[381] = M.PPLTON;
        tokens[382] = M.SMRON;
        tokens[383] = M.URNMON;
        tokens[384] = M.UUUUON;
        tokens[385] = M.SOUNON;
        tokens[386] = M.PLUGON;
        tokens[387] = M.IGEBON;
        tokens[388] = M.SEDGON;
        tokens[389] = M.WOLFON;
        tokens[390] = M.OPENON;
        tokens[391] = M.QUBTON;
        tokens[392] = M.KEELON;
        tokens[393] = M.INODON;
        tokens[394] = M.SBETON;
        tokens[395] = M.BTDRON;
        tokens[396] = M.BBAION;
        tokens[397] = M.BNOON;
        tokens[398] = M.PSQON;
        tokens[399] = M.CPERON;
        tokens[400] = M.FCELON;
        tokens[401] = M.FLNCON;
        tokens[402] = M.NNEON;
        tokens[403] = M.BOTON;
        tokens[404] = M.PALLON;
        tokens[405] = M.BTGOON;
        tokens[406] = M.LPTHON;
        tokens[407] = M.EXODON;
        tokens[408] = M.BWETON;
        tokens[409] = M.BAION;
        tokens[410] = M.DRAMON;
        tokens[411] = M.SATAON;
        tokens[412] = M.STRCON;
        tokens[413] = M.ANTON;
    }
}
