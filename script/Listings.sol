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
library Listings {
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 91;

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
                || token == M.ADA || token == M.LTC || token == M.DOT || token == M.ATOM
        ) return Tier.Custodial;
        if (
            token == M.CRO || token == M.ICP || token == M.ARB || token == M.RENDER || token == M.CAKE || token == M.ZRO
                || token == M.INJ || token == M.SOL || token == M.W || token == M.ZK || token == M.AVAX
                || token == M.JUP || token == M.ALGO || token == M.AERO || token == M.APT || token == M.PYTH_TOKEN
                || token == M.OP || token == M.BNB || token == M.SUI
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
    ///         Ethereum-issued coins (31, less SAND, RLB and BTT) and 12 Wormhole copies, then the 2 copies found on
    ///         2026-10-18 that stayed (BNB and SUI), each group by market cap.
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
        tokens[77] = M.XRP;
        tokens[78] = M.ADA;
        tokens[79] = M.LTC;
        tokens[80] = M.AVAX;
        tokens[81] = M.DOT;
        tokens[82] = M.JUP;
        tokens[83] = M.ALGO;
        tokens[84] = M.ATOM;
        tokens[85] = M.AERO;
        tokens[86] = M.APT;
        tokens[87] = M.PYTH_TOKEN;
        tokens[88] = M.OP;
        tokens[89] = M.BNB;
        tokens[90] = M.SUI;
    }
}
