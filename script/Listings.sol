// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MainnetAddresses as M} from "./MainnetAddresses.sol";

/// @notice The Ethereum coins Xindex lists, in listing order, and each one's trust tier. No coin carries a price feed:
///         an index rebalances through an auction on units alone and nothing reads a price
///         (`design/2026-11-10-oracle-free-rebalance.md`). The owner's calls behind the list:
///         - 2026-10-06: GRAM is out, its bridge closed; so are OKB, being retired on Ethereum, and BGB and GT, which
///           no Uniswap route trades (design/2026-10-05-wide-asset-support.md, section 6).
///         - 2026-10-10: INJ, SHIB and PEPE joined, from CoinGecko's top 100 of that day, SHIB and PEPE on the owner's
///           call; Wormhole's SOL, in place of BNB Chain's Binance-Peg SOL; Tether Gold and 17 Ondo stock tokens; and
///           the hundred-coin list (design/2026-10-10-one-index-wormhole-legs.md): 31 Ethereum-issued coins and 13
///           Wormhole copies.
///         - 2026-10-14: DOGE's copy left (`MainnetAddresses`).
///         - 2026-10-18: Wormhole's copies of BNB, SUI and SEI, which the count of 2026-10-10 missed, joined; SAND and
///           RLB left after the source reading (design/2026-10-18-token-source-reading.md).
///         - 2026-10-19: BTT and SEI's copy left, the red team's RX-28 and RX-32: the bridge behind each has closed or
///           is closing.
///         - 2026-11-13: Wormhole's copies of the six coins BNB Chain's deployment holds in kind left (XRP, ADA, LTC,
///           DOT, ATOM and BNB, each wrapped from BNB Chain): those coins are on `BnbChainAddresses`' list, with no
///           bridge under them (design/2026-11-13-bnb-chain-deployment.md). The nine copies from other chains stay.
///         - 2026-11-18: Wormhole's copies of JUP, PYTH, SUI, APT and ALGO left: no Ethereum pool trades them, so a
///           rebalance can buy them only from stock bridged in from Solana, Sui, Aptos or Algorand, and the restock
///           that would bridge them has never run (design/2026-11-18-bridged-coins-in-a-rebalance.md). SOL's copy,
///           which a Uniswap pool trades, and AVAX's, OP's and AERO's, which the EVM restock serves, stay.
///         - 2026-11-19: every Ondo stock and ETF Pyth has a feed for joined, 335 beside the 17 listed on
///           2026-10-10, each `Custodial` (the owner's call, design/2026-11-22-ondo-stocks-and-etfs.md). The 127
///           without a feed join as Pyth publishes one; USDY and OUSG, cash tokens, are not listed.
///         - 2026-11-21: Wormhole's copy of OP left (the owner's call: "remove op for now"). No Ethereum pool trades
///           it, and the restock that would buy it on Optimism found no route that day: Uniswap v3's deepest OP pool
///           there held about $35,000 of USDC, and $1,430 of OP cost 4.7% over the pools' price. Its address stays in
///           `MainnetAddresses` for a relisting. AVAX's and AERO's copies, which the restock bought and bridged in a
///           test of the same day, stay, and so does SOL's.
///         - 2026-11-21: the Ondo stocks left for 109 of Backed's wrapped xStocks, and on 2026-11-22 the owner
///           reversed it ("delete everything releated to xtokcs and leave only ondo"): no xStock is listed, and every
///           Ondo stock and ETF above is, as of 2026-11-19.
///         - 2026-11-25: Ondo's ANTon, Anthropic's token, joined (the owner's call: "both to eth and bnb"), at Pyth's
///           24/7 price for the share, Pyth having no feed for the token; on BNB Chain too.
library Listings {
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 415;

    /// @notice A token's trust tier (design/2026-10-05-wide-asset-support.md, section 1), shown by the app beside every
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
    ///         table. No copy of a Binance-Peg coin is listed since 2026-11-13: those were the `Custodial` copies.
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
                || token == M.AERO
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
    ///         list: the 45 of 2026-10-06 and 2026-10-10's first additions, then the hundred-coin list's 28
    ///         Ethereum-issued coins (31, less SAND, RLB and BTT) and 2 Wormhole copies (12, less the five from BNB
    ///         Chain, the four from Solana, Aptos and Algorand, and OP's), each group by market cap. The copy found on
    ///         2026-10-18 that stayed until 2026-11-18, SUI's, has left too.
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
        tokens[78] = M.AERO;
        tokens[79] = M.GOOGON;
        tokens[80] = M.IVVON;
        tokens[81] = M.SPYON;
        tokens[82] = M.VTION;
        tokens[83] = M.XOMON;
        tokens[84] = M.JNJON;
        tokens[85] = M.MAON;
        tokens[86] = M.ASMLON;
        tokens[87] = M.ABBVON;
        tokens[88] = M.COSTON;
        tokens[89] = M.QQQON;
        tokens[90] = M.KOON;
        tokens[91] = M.CVXON;
        tokens[92] = M.PGON;
        tokens[93] = M.PLTRON;
        tokens[94] = M.CSCOON;
        tokens[95] = M.ORCLON;
        tokens[96] = M.GEON;
        tokens[97] = M.BACON;
        tokens[98] = M.HDON;
        tokens[99] = M.MRKON;
        tokens[100] = M.INTCON;
        tokens[101] = M.UNHON;
        tokens[102] = M.PANWON;
        tokens[103] = M.AMATON;
        tokens[104] = M.LRCXON;
        tokens[105] = M.TXNON;
        tokens[106] = M.RTXON;
        tokens[107] = M.TMOON;
        tokens[108] = M.CRWDON;
        tokens[109] = M.CATON;
        tokens[110] = M.GSON;
        tokens[111] = M.ANETON;
        tokens[112] = M.NFLXON;
        tokens[113] = M.WFCON;
        tokens[114] = M.SAPON;
        tokens[115] = M.AMGNON;
        tokens[116] = M.LINON;
        tokens[117] = M.IBMON;
        tokens[118] = M.BABAON;
        tokens[119] = M.AXPON;
        tokens[120] = M.DISON;
        tokens[121] = M.GEVON;
        tokens[122] = M.DELLON;
        tokens[123] = M.ARMON;
        tokens[124] = M.CON;
        tokens[125] = M.APHON;
        tokens[126] = M.MCDON;
        tokens[127] = M.KLACON;
        tokens[128] = M.PEPON;
        tokens[129] = M.VTVON;
        tokens[130] = M.VZON;
        tokens[131] = M.ADION;
        tokens[132] = M.IEFAON;
        tokens[133] = M.ABTON;
        tokens[134] = M.BLKON;
        tokens[135] = M.QCOMON;
        tokens[136] = M.SHOPON;
        tokens[137] = M.NEEON;
        tokens[138] = M.UNPON;
        tokens[139] = M.NVOON;
        tokens[140] = M.TMUSON;
        tokens[141] = M.DEON;
        tokens[142] = M.SCHWON;
        tokens[143] = M.COPON;
        tokens[144] = M.PFEON;
        tokens[145] = M.CRMON;
        tokens[146] = M.TON;
        tokens[147] = M.ISRGON;
        tokens[148] = M.AGGON;
        tokens[149] = M.IEMGON;
        tokens[150] = M.UBERON;
        tokens[151] = M.VRTXON;
        tokens[152] = M.LMTON;
        tokens[153] = M.MRVLON;
        tokens[154] = M.ETNON;
        tokens[155] = M.ACNON;
        tokens[156] = M.SPGION;
        tokens[157] = M.APPON;
        tokens[158] = M.BAON;
        tokens[159] = M.STXON;
        tokens[160] = M.SCCOON;
        tokens[161] = M.PDDON;
        tokens[162] = M.GLDON;
        tokens[163] = M.LOWON;
        tokens[164] = M.SPOTON;
        tokens[165] = M.SBUXON;
        tokens[166] = M.IJHON;
        tokens[167] = M.SGOVON;
        tokens[168] = M.WDCON;
        tokens[169] = M.SNDKON;
        tokens[170] = M.IWFON;
        tokens[171] = M.NETON;
        tokens[172] = M.COFON;
        tokens[173] = M.SOON;
        tokens[174] = M.PBRON;
        tokens[175] = M.NEMON;
        tokens[176] = M.ABNBON;
        tokens[177] = M.ENBON;
        tokens[178] = M.EQIXON;
        tokens[179] = M.SNOWON;
        tokens[180] = M.REGNON;
        tokens[181] = M.NOWON;
        tokens[182] = M.GLWON;
        tokens[183] = M.WMON;
        tokens[184] = M.GDON;
        tokens[185] = M.ITOTON;
        tokens[186] = M.CEGON;
        tokens[187] = M.PWRON;
        tokens[188] = M.TTON;
        tokens[189] = M.EMRON;
        tokens[190] = M.ADBEON;
        tokens[191] = M.INTUON;
        tokens[192] = M.WMBON;
        tokens[193] = M.CVNAON;
        tokens[194] = M.MRNAON;
        tokens[195] = M.NOCON;
        tokens[196] = M.VRTON;
        tokens[197] = M.EFAON;
        tokens[198] = M.IWMON;
        tokens[199] = M.FCXON;
        tokens[200] = M.SLBON;
        tokens[201] = M.DASHON;
        tokens[202] = M.APOON;
        tokens[203] = M.MELION;
        tokens[204] = M.NTESON;
        tokens[205] = M.HOODON;
        tokens[206] = M.HPEON;
        tokens[207] = M.TELON;
        tokens[208] = M.NUEON;
        tokens[209] = M.IAUON;
        tokens[210] = M.AMEON;
        tokens[211] = M.OXYON;
        tokens[212] = M.BEON;
        tokens[213] = M.NKEON;
        tokens[214] = M.LITEON;
        tokens[215] = M.KEYSON;
        tokens[216] = M.IBITON;
        tokens[217] = M.BILON;
        tokens[218] = M.PYPLON;
        tokens[219] = M.TLTON;
        tokens[220] = M.XYZON;
        tokens[221] = M.CMGON;
        tokens[222] = M.FON;
        tokens[223] = M.COHRON;
        tokens[224] = M.NOKON;
        tokens[225] = M.NTRAON;
        tokens[226] = M.IEFON;
        tokens[227] = M.VSTON;
        tokens[228] = M.ROKON;
        tokens[229] = M.SOXXON;
        tokens[230] = M.DYNFON;
        tokens[231] = M.STMON;
        tokens[232] = M.TTWOON;
        tokens[233] = M.CIENON;
        tokens[234] = M.ALABON;
        tokens[235] = M.MSTRON;
        tokens[236] = M.VNQON;
        tokens[237] = M.TERON;
        tokens[238] = M.RKLBON;
        tokens[239] = M.UMCON;
        tokens[240] = M.JDON;
        tokens[241] = M.JAAAON;
        tokens[242] = M.CLSON;
        tokens[243] = M.STLDON;
        tokens[244] = M.EQTON;
        tokens[245] = M.NBISON;
        tokens[246] = M.INSMON;
        tokens[247] = M.PCGON;
        tokens[248] = M.COINON;
        tokens[249] = M.TQQQON;
        tokens[250] = M.EFVON;
        tokens[251] = M.FLEXON;
        tokens[252] = M.SHYON;
        tokens[253] = M.VRSNON;
        tokens[254] = M.CCJON;
        tokens[255] = M.CRWVON;
        tokens[256] = M.TCOMON;
        tokens[257] = M.EEMON;
        tokens[258] = M.ONON;
        tokens[259] = M.HALON;
        tokens[260] = M.CPNGON;
        tokens[261] = M.JBLON;
        tokens[262] = M.BIDUON;
        tokens[263] = M.CRDOON;
        tokens[264] = M.CBRSON;
        tokens[265] = M.SLVON;
        tokens[266] = M.HUBBON;
        tokens[267] = M.IYWON;
        tokens[268] = M.EWJON;
        tokens[269] = M.GFSON;
        tokens[270] = M.ENTGON;
        tokens[271] = M.USFRON;
        tokens[272] = M.EWYON;
        tokens[273] = M.SWKSON;
        tokens[274] = M.SOFION;
        tokens[275] = M.HYGON;
        tokens[276] = M.NVTON;
        tokens[277] = M.RDDTON;
        tokens[278] = M.MTSION;
        tokens[279] = M.RIVNON;
        tokens[280] = M.LSCCON;
        tokens[281] = M.SMCION;
        tokens[282] = M.TLNON;
        tokens[283] = M.WCCON;
        tokens[284] = M.TSEMON;
        tokens[285] = M.LECOON;
        tokens[286] = M.MKSION;
        tokens[287] = M.TIPON;
        tokens[288] = M.CRCLON;
        tokens[289] = M.MTZON;
        tokens[290] = M.IWNON;
        tokens[291] = M.GMEON;
        tokens[292] = M.SOXLON;
        tokens[293] = M.PAVEON;
        tokens[294] = M.FUTUON;
        tokens[295] = M.IGVON;
        tokens[296] = M.GRABON;
        tokens[297] = M.GNRCON;
        tokens[298] = M.FNON;
        tokens[299] = M.ITAON;
        tokens[300] = M.HIION;
        tokens[301] = M.IONQON;
        tokens[302] = M.LION;
        tokens[303] = M.ALBON;
        tokens[304] = M.ONTOON;
        tokens[305] = M.PINSON;
        tokens[306] = M.NVMION;
        tokens[307] = M.BMNRON;
        tokens[308] = M.SNAPON;
        tokens[309] = M.FIGON;
        tokens[310] = M.AIQON;
        tokens[311] = M.AMKRON;
        tokens[312] = M.AALON;
        tokens[313] = M.RMBSON;
        tokens[314] = M.OSCRON;
        tokens[315] = M.TWSTON;
        tokens[316] = M.EWZON;
        tokens[317] = M.ASTSON;
        tokens[318] = M.AURON;
        tokens[319] = M.TTMION;
        tokens[320] = M.HUTON;
        tokens[321] = M.VICRON;
        tokens[322] = M.INDAON;
        tokens[323] = M.CLFON;
        tokens[324] = M.NIOON;
        tokens[325] = M.RIOTON;
        tokens[326] = M.MPON;
        tokens[327] = M.FORMON;
        tokens[328] = M.IRENON;
        tokens[329] = M.WULFON;
        tokens[330] = M.FPSON;
        tokens[331] = M.FIGRON;
        tokens[332] = M.POWLON;
        tokens[333] = M.SHLDON;
        tokens[334] = M.AGON;
        tokens[335] = M.CAION;
        tokens[336] = M.ETHAON;
        tokens[337] = M.COPXON;
        tokens[338] = M.CORZON;
        tokens[339] = M.BILION;
        tokens[340] = M.MXLON;
        tokens[341] = M.APLDON;
        tokens[342] = M.PLON;
        tokens[343] = M.KWEBON;
        tokens[344] = M.OKLOON;
        tokens[345] = M.URAON;
        tokens[346] = M.VSHON;
        tokens[347] = M.HIMSON;
        tokens[348] = M.AAOION;
        tokens[349] = M.FXION;
        tokens[350] = M.PRIMON;
        tokens[351] = M.CIFRON;
        tokens[352] = M.ENPHON;
        tokens[353] = M.BLSHON;
        tokens[354] = M.QBTSON;
        tokens[355] = M.UECON;
        tokens[356] = M.RGTION;
        tokens[357] = M.BOTZON;
        tokens[358] = M.PENGON;
        tokens[359] = M.ONDSON;
        tokens[360] = M.AMCON;
        tokens[361] = M.USARON;
        tokens[362] = M.SOXQON;
        tokens[363] = M.GRNDON;
        tokens[364] = M.ACHRON;
        tokens[365] = M.MARAON;
        tokens[366] = M.GLXYON;
        tokens[367] = M.AXTION;
        tokens[368] = M.OUSTON;
        tokens[369] = M.NVTSON;
        tokens[370] = M.USOON;
        tokens[371] = M.SQQQON;
        tokens[372] = M.RXRXON;
        tokens[373] = M.SOXSON;
        tokens[374] = M.LUNRON;
        tokens[375] = M.OIHON;
        tokens[376] = M.RDWON;
        tokens[377] = M.PURRON;
        tokens[378] = M.DNNON;
        tokens[379] = M.AION;
        tokens[380] = M.AEHRON;
        tokens[381] = M.WENON;
        tokens[382] = M.PPLTON;
        tokens[383] = M.SMRON;
        tokens[384] = M.URNMON;
        tokens[385] = M.UUUUON;
        tokens[386] = M.SOUNON;
        tokens[387] = M.PLUGON;
        tokens[388] = M.IGEBON;
        tokens[389] = M.SEDGON;
        tokens[390] = M.WOLFON;
        tokens[391] = M.OPENON;
        tokens[392] = M.QUBTON;
        tokens[393] = M.KEELON;
        tokens[394] = M.INODON;
        tokens[395] = M.SBETON;
        tokens[396] = M.BTDRON;
        tokens[397] = M.BBAION;
        tokens[398] = M.BNOON;
        tokens[399] = M.PSQON;
        tokens[400] = M.CPERON;
        tokens[401] = M.FCELON;
        tokens[402] = M.FLNCON;
        tokens[403] = M.NNEON;
        tokens[404] = M.BOTON;
        tokens[405] = M.PALLON;
        tokens[406] = M.BTGOON;
        tokens[407] = M.LPTHON;
        tokens[408] = M.EXODON;
        tokens[409] = M.BWETON;
        tokens[410] = M.BAION;
        tokens[411] = M.DRAMON;
        tokens[412] = M.SATAON;
        tokens[413] = M.STRCON;
        tokens[414] = M.ANTON;
    }
}
