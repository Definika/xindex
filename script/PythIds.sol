// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MainnetAddresses as M} from "./MainnetAddresses.sol";

/// @notice The Pyth price id each listed Ethereum coin is listed with for v5's weighted indexes, read from Pyth's Hermes
///         catalogue (`/v2/price_feeds`) on 2026-10-05, each checked to name its coin by the feed's description, given
///         beside it. WETH takes ETH/USD: it redeems one for one on chain, and ETH/USD is Pyth's deepest feed. WBTC takes
///         WBTC/USD, not BTC/USD: it is custodial, so its own price is what catches a depeg. GRAM is left out until the
///         owner confirms whether Pyth's "GRAM / US DOLLAR" or "TONCOIN / US DOLLAR" is the coin it bridges
///         (design/2026-10-05-custom-weights.md, section 2).
library PythIds {
    /// @notice How many coins the table names.
    uint256 internal constant COUNT = 30;

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
    /// @dev OKB / US DOLLAR.
    bytes32 internal constant OKB = 0xd6f83dfeaff95d596ddec26af2ee32f391c206a183b161b7980821860eeef2f5;
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
    /// @dev BITGET TOKEN / US DOLLAR.
    bytes32 internal constant BGB = 0x708bfcf418ead52a408407b039f2c33ce24ddc80d6dcb6d1cffef91c156c80fa;
    /// @dev POLYGON ECOSYSTEM TOKEN / US DOLLAR.
    bytes32 internal constant POL = 0xffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472;
    /// @dev GATETOKEN / US DOLLAR.
    bytes32 internal constant GT = 0x051ee6cdd581106d0291dfd9b0ee13e6b4dde8fb251afd262c2ba5444257daa8;
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

    /// @notice Every coin of the table and its id: the flagship's four in `ConfigureWhitelist.defaultMainnetList`'s order,
    ///         then the wide list in `wideMainnetList`'s, GRAM aside.
    function all() internal pure returns (address[] memory tokens, bytes32[] memory ids) {
        tokens = new address[](COUNT);
        ids = new bytes32[](COUNT);
        (tokens[0], ids[0]) = (M.WETH, WETH);
        (tokens[1], ids[1]) = (M.WBTC, WBTC);
        (tokens[2], ids[2]) = (M.LINK, LINK);
        (tokens[3], ids[3]) = (M.UNI, UNI);
        (tokens[4], ids[4]) = (M.QNT, QNT);
        (tokens[5], ids[5]) = (M.AAVE, AAVE);
        (tokens[6], ids[6]) = (M.OKB, OKB);
        (tokens[7], ids[7]) = (M.ENA, ENA);
        (tokens[8], ids[8]) = (M.ONDO, ONDO);
        (tokens[9], ids[9]) = (M.SKY, SKY);
        (tokens[10], ids[10]) = (M.WLD, WLD);
        (tokens[11], ids[11]) = (M.MNT, MNT);
        (tokens[12], ids[12]) = (M.MORPHO, MORPHO);
        (tokens[13], ids[13]) = (M.BGB, BGB);
        (tokens[14], ids[14]) = (M.POL, POL);
        (tokens[15], ids[15]) = (M.GT, GT);
        (tokens[16], ids[16]) = (M.LIT, LIT);
        (tokens[17], ids[17]) = (M.ETHFI, ETHFI);
        (tokens[18], ids[18]) = (M.FET, FET);
        (tokens[19], ids[19]) = (M.CRV, CRV);
        (tokens[20], ids[20]) = (M.NEXO, NEXO);
        (tokens[21], ids[21]) = (M.VIRTUAL, VIRTUAL);
        (tokens[22], ids[22]) = (M.STRK, STRK);
        (tokens[23], ids[23]) = (M.PENDLE, PENDLE);
        (tokens[24], ids[24]) = (M.CRO, CRO);
        (tokens[25], ids[25]) = (M.ICP, ICP);
        (tokens[26], ids[26]) = (M.ARB, ARB);
        (tokens[27], ids[27]) = (M.RENDER, RENDER);
        (tokens[28], ids[28]) = (M.CAKE, CAKE);
        (tokens[29], ids[29]) = (M.ZRO, ZRO);
    }
}
