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
///         - 2026-11-21: Wormhole's copy of OP left (the owner's call: "remove op for now"). No Ethereum pool trades
///           it, and the restock that would buy it on Optimism found no route that day: Uniswap v3's deepest OP pool
///           there held about $35,000 of USDC, and $1,430 of OP cost 4.7% over the pools' price. Its address stays in
///           `MainnetAddresses` for a relisting. AVAX's and AERO's copies, which the restock bought and bridged in a
///           test of the same day, stay, and so does SOL's.
///         - 2026-11-21: the 17 Ondo stocks left, and 109 of Backed's wrapped xStocks joined, each `Custodial` (the
///           owner's call: xStocks in place of Ondo, design/2026-11-21-xstocks.md). They are every wrapper Backed's
///           factory has deployed less the nine whose share has no Pyth feed that names it. An xStock itself is never
///           listed: its balances move with a multiplier, and only its wrapper's stay fixed.
library Listings {
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 171;

    /// @notice A token's trust tier (design/2026-10-05-wide-asset-support.md, section 1), shown by the app beside every
    ///         index that holds it and by `ConfigureWeighted`'s safe mode beside every listing.
    enum Tier {
        Unrecorded,
        Native,
        Bridged,
        Custodial
    }

    /// @notice The tier of a token in the table: `Custodial` for WBTC (BitGo holds the bitcoin), Tether Gold and the
    ///         wrapped xStocks (Backed's custodian holds the shares); `Bridged` for a bridge's copy of a coin issued
    ///         elsewhere, Wormhole's copies among them; `Native` for a token issued on Ethereum, ether's WETH among
    ///         them; and `Unrecorded` for any token off the table. No copy of a Binance-Peg coin is listed since
    ///         2026-11-13: those were the `Custodial` copies.
    function tierOf(address token) internal pure returns (Tier) {
        if (
            token == M.WBTC || token == M.XAUT || token == M.WAAPLX || token == M.WABBVX || token == M.WABTX
                || token == M.WACNX || token == M.WADBEX || token == M.WAMDX || token == M.WAMZNX || token == M.WAPPX
                || token == M.WASMLX || token == M.WASTSX || token == M.WAVGOX || token == M.WAXPX || token == M.WAZNX
                || token == M.WBACX || token == M.WBKNGX || token == M.WBLKX || token == M.WBLSHX || token == M.WBMNRX
                || token == M.WBRKBX || token == M.WBTBTX || token == M.WCLSKX || token == M.WCMCSAX
                || token == M.WCOINX || token == M.WCORZX || token == M.WCOSTX || token == M.WCRCLX || token == M.WCRMX
                || token == M.WCRWDX || token == M.WCSCOX || token == M.WCVXX || token == M.WDHRX || token == M.WEBAYX
                || token == M.WEXPEX || token == M.WFIGX || token == M.WGLDX || token == M.WGLXYX || token == M.WGMEX
                || token == M.WGOOGLX || token == M.WGSX || token == M.WHDX || token == M.WHONX || token == M.WHOODX
                || token == M.WHSDTX || token == M.WHUTX || token == M.WIBMX || token == M.WIEMGX || token == M.WIJRX
                || token == M.WINTCX || token == M.WIWMX || token == M.WJNJX || token == M.WJPMX || token == M.WKOX
                || token == M.WLINX || token == M.WLLYX || token == M.WLULUX || token == M.WMAX || token == M.WMARAX
                || token == M.WMCDX || token == M.WMDTX || token == M.WMETAX || token == M.WMNSTX || token == M.WMRKX
                || token == M.WMRVLX || token == M.WMSFTX || token == M.WMSTRX || token == M.WMUX || token == M.WNFLXX
                || token == M.WNVDAX || token == M.WNVOX || token == M.WOKLOX || token == M.WOPENX || token == M.WORCLX
                || token == M.WPANWX || token == M.WPEPX || token == M.WPFEX || token == M.WPGX || token == M.WPLX
                || token == M.WPLTRX || token == M.WPMX || token == M.WPYPLX || token == M.WQQQX || token == M.WRBLXX
                || token == M.WRIOTX || token == M.WRKLBX || token == M.WSBETX || token == M.WSCHFX || token == M.WSLVX
                || token == M.WSPCEX || token == M.WSPGIX || token == M.WSPYX || token == M.WSTRCX || token == M.WTX
                || token == M.WTEMX || token == M.WTGTX || token == M.WTMOX || token == M.WTMUSX || token == M.WTQQQX
                || token == M.WTSLAX || token == M.WTSMX || token == M.WUBERX || token == M.WUNHX || token == M.WVX
                || token == M.WVSTX || token == M.WVTX || token == M.WVTIX || token == M.WWENX || token == M.WWMTX
                || token == M.WWULFX || token == M.WXOMX
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
    ///         list: the 28 of 2026-10-06 and 2026-10-10's first additions that stay (the 17 Ondo stocks left on
    ///         2026-11-21), then the hundred-coin list's 28
    ///         Ethereum-issued coins (31, less SAND, RLB and BTT) and 2 Wormhole copies (12, less the five from BNB
    ///         Chain, the four from Solana, Aptos and Algorand, and OP's), each group by market cap. The copy found on
    ///         2026-10-18 that stayed until 2026-11-18, SUI's, has left too. Last, the 109 wrapped xStocks of
    ///         2026-11-21, by ticker.
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
        tokens[32] = M.FF;
        tokens[33] = M.GNO;
        tokens[34] = M.OHM;
        tokens[35] = M.GRT;
        tokens[36] = M.SYRUP;
        tokens[37] = M.ENS;
        tokens[38] = M.JASMY;
        tokens[39] = M.COMP;
        tokens[40] = M.EIGEN;
        tokens[41] = M.AXS;
        tokens[42] = M.BAT;
        tokens[43] = M.CVX;
        tokens[44] = M.MANA;
        tokens[45] = M.IMX;
        tokens[46] = M.FLUID;
        tokens[47] = M.CHZ;
        tokens[48] = M.ZK;
        tokens[49] = M.APE;
        tokens[50] = M.SENT;
        tokens[51] = M.SNX;
        tokens[52] = M.ONEINCH;
        tokens[53] = M.GLM;
        tokens[54] = M.ATH;
        tokens[55] = M.H;
        tokens[56] = M.PLUME;
        tokens[57] = M.GALA;
        tokens[58] = M.W;
        tokens[59] = M.RSR;
        tokens[60] = M.AVAX;
        tokens[61] = M.AERO;
        tokens[62] = M.WAAPLX;
        tokens[63] = M.WABBVX;
        tokens[64] = M.WABTX;
        tokens[65] = M.WACNX;
        tokens[66] = M.WADBEX;
        tokens[67] = M.WAMDX;
        tokens[68] = M.WAMZNX;
        tokens[69] = M.WAPPX;
        tokens[70] = M.WASMLX;
        tokens[71] = M.WASTSX;
        tokens[72] = M.WAVGOX;
        tokens[73] = M.WAXPX;
        tokens[74] = M.WAZNX;
        tokens[75] = M.WBACX;
        tokens[76] = M.WBKNGX;
        tokens[77] = M.WBLKX;
        tokens[78] = M.WBLSHX;
        tokens[79] = M.WBMNRX;
        tokens[80] = M.WBRKBX;
        tokens[81] = M.WBTBTX;
        tokens[82] = M.WCLSKX;
        tokens[83] = M.WCMCSAX;
        tokens[84] = M.WCOINX;
        tokens[85] = M.WCORZX;
        tokens[86] = M.WCOSTX;
        tokens[87] = M.WCRCLX;
        tokens[88] = M.WCRMX;
        tokens[89] = M.WCRWDX;
        tokens[90] = M.WCSCOX;
        tokens[91] = M.WCVXX;
        tokens[92] = M.WDHRX;
        tokens[93] = M.WEBAYX;
        tokens[94] = M.WEXPEX;
        tokens[95] = M.WFIGX;
        tokens[96] = M.WGLDX;
        tokens[97] = M.WGLXYX;
        tokens[98] = M.WGMEX;
        tokens[99] = M.WGOOGLX;
        tokens[100] = M.WGSX;
        tokens[101] = M.WHDX;
        tokens[102] = M.WHONX;
        tokens[103] = M.WHOODX;
        tokens[104] = M.WHSDTX;
        tokens[105] = M.WHUTX;
        tokens[106] = M.WIBMX;
        tokens[107] = M.WIEMGX;
        tokens[108] = M.WIJRX;
        tokens[109] = M.WINTCX;
        tokens[110] = M.WIWMX;
        tokens[111] = M.WJNJX;
        tokens[112] = M.WJPMX;
        tokens[113] = M.WKOX;
        tokens[114] = M.WLINX;
        tokens[115] = M.WLLYX;
        tokens[116] = M.WLULUX;
        tokens[117] = M.WMAX;
        tokens[118] = M.WMARAX;
        tokens[119] = M.WMCDX;
        tokens[120] = M.WMDTX;
        tokens[121] = M.WMETAX;
        tokens[122] = M.WMNSTX;
        tokens[123] = M.WMRKX;
        tokens[124] = M.WMRVLX;
        tokens[125] = M.WMSFTX;
        tokens[126] = M.WMSTRX;
        tokens[127] = M.WMUX;
        tokens[128] = M.WNFLXX;
        tokens[129] = M.WNVDAX;
        tokens[130] = M.WNVOX;
        tokens[131] = M.WOKLOX;
        tokens[132] = M.WOPENX;
        tokens[133] = M.WORCLX;
        tokens[134] = M.WPANWX;
        tokens[135] = M.WPEPX;
        tokens[136] = M.WPFEX;
        tokens[137] = M.WPGX;
        tokens[138] = M.WPLX;
        tokens[139] = M.WPLTRX;
        tokens[140] = M.WPMX;
        tokens[141] = M.WPYPLX;
        tokens[142] = M.WQQQX;
        tokens[143] = M.WRBLXX;
        tokens[144] = M.WRIOTX;
        tokens[145] = M.WRKLBX;
        tokens[146] = M.WSBETX;
        tokens[147] = M.WSCHFX;
        tokens[148] = M.WSLVX;
        tokens[149] = M.WSPCEX;
        tokens[150] = M.WSPGIX;
        tokens[151] = M.WSPYX;
        tokens[152] = M.WSTRCX;
        tokens[153] = M.WTX;
        tokens[154] = M.WTEMX;
        tokens[155] = M.WTGTX;
        tokens[156] = M.WTMOX;
        tokens[157] = M.WTMUSX;
        tokens[158] = M.WTQQQX;
        tokens[159] = M.WTSLAX;
        tokens[160] = M.WTSMX;
        tokens[161] = M.WUBERX;
        tokens[162] = M.WUNHX;
        tokens[163] = M.WVX;
        tokens[164] = M.WVSTX;
        tokens[165] = M.WVTX;
        tokens[166] = M.WVTIX;
        tokens[167] = M.WWENX;
        tokens[168] = M.WWMTX;
        tokens[169] = M.WWULFX;
        tokens[170] = M.WXOMX;
    }
}
