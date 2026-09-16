// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Ethereum mainnet addresses used by the fork tests and deploy scripts.
library ForkAddresses {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88; // tBTC v2, 18 decimals
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9; // checked on 2026-09-16: symbol AAVE, 18 decimals

    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @dev Uniswap V3 WETH pools, each checked on 2026-09-16 with UNISWAP_V3_FACTORY.getPool and its token0/token1.
    ///      Observation slots on that day: USDC 723, WBTC 300, LINK 360, UNI 300, AAVE 1000, tBTC 60 (too few for the rule).
    address internal constant USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant WBTC_WETH_500 = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address internal constant LINK_WETH_3000 = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;
    address internal constant UNI_WETH_3000 = 0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801;
    address internal constant TBTC_WETH_3000 = 0x97944213D2caeeA773DA1c9B11B0525F25b749CC;
    address internal constant AAVE_WETH_3000 = 0x5aB53EE1d50eeF2C1DD3d5402789cd27bB52c1bB;

    /// @dev Circulating supplies reported by CoinGecko on 2026-09-15, as in the default whitelist.
    uint256 internal constant BTC_SUPPLY = 20_084_784e8;
    uint256 internal constant ETH_SUPPLY = 122_050_160e18;
    uint256 internal constant LINK_SUPPLY = 748_099_970e18;
    uint256 internal constant UNI_SUPPLY = 623_212_423e18;

    /// @dev Block the fork tests pin to. Bump deliberately; a pinned block keeps quotes deterministic
    ///      and lets the RPC cache.
    uint256 internal constant FORK_BLOCK = 25_978_000;
}
