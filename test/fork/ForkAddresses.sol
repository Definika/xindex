// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @notice Ethereum mainnet addresses the fork tests use: the scripts' `MainnetAddresses` re-exported, plus contracts
///         and pools only the tests need.
library ForkAddresses {
    address internal constant USDC = MainnetAddresses.USDC;
    address internal constant USDT = MainnetAddresses.USDT;
    address internal constant WETH = MainnetAddresses.WETH;
    address internal constant WBTC = MainnetAddresses.WBTC;
    address internal constant LINK = MainnetAddresses.LINK;
    address internal constant UNI = MainnetAddresses.UNI;
    address internal constant AAVE = MainnetAddresses.AAVE;
    address internal constant WSTETH = MainnetAddresses.WSTETH;
    address internal constant WSOL = MainnetAddresses.WSOL;
    /// @dev tBTC is not on the launch whitelist; the zap fork tests still route through its pool.
    address internal constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;

    /// @dev Chainlink aggregator proxies, re-exported from the scripts' one copy.
    address internal constant ETH_USD_FEED = MainnetAddresses.ETH_USD_FEED;
    address internal constant WSTETH_USD_FEED = MainnetAddresses.WSTETH_USD_FEED;
    address internal constant BTC_USD_FEED = MainnetAddresses.BTC_USD_FEED;
    address internal constant WBTC_BTC_FEED = MainnetAddresses.WBTC_BTC_FEED;
    address internal constant SOL_USD_FEED = MainnetAddresses.SOL_USD_FEED;
    address internal constant UNI_USD_FEED = MainnetAddresses.UNI_USD_FEED;
    address internal constant LINK_USD_FEED = MainnetAddresses.LINK_USD_FEED;
    address internal constant AAVE_USD_FEED = MainnetAddresses.AAVE_USD_FEED;
    /// @dev "TBTC / USD", 24-hour heartbeat. tBTC is not on the launch whitelist; the zap fork tests list it to
    ///      exercise a two-hop route, so its feed lives here rather than in the scripts' address book.
    address internal constant TBTC_USD_FEED = 0x8350b7De6a6a2C1368E7D4Bd968190e13E354297;
    uint32 internal constant STALENESS_1H = MainnetAddresses.STALENESS_1H;
    uint32 internal constant STALENESS_24H = MainnetAddresses.STALENESS_24H;

    /// @dev Reference supplies the fork tests list with.
    uint256 internal constant SOL_SUPPLY = MainnetAddresses.SOL_SUPPLY;
    uint256 internal constant AAVE_SUPPLY = MainnetAddresses.AAVE_SUPPLY;

    /// @dev Uniswap SwapRouter02. The zap swaps through the Universal Router now; this is only the fork tests' own
    ///      rebalance executor, a fixture whose venue is independent of anything Xindex deploys.
    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
    address internal constant POOL_MANAGER = MainnetAddresses.POOL_MANAGER;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    /// @dev The Uniswap V3 factory, which only the zap's V3 routes still need; the rule reads no pool.
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @dev Uniswap V3 WETH pools, each checked on 2026-09-16 with UNISWAP_V3_FACTORY.getPool and its token0/token1.
    ///      Observation slots on that day: USDC 723, WBTC 300, LINK 360, UNI 300, AAVE 1000, tBTC 60 (too few for the rule).
    address internal constant USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant WBTC_WETH_500 = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address internal constant LINK_WETH_3000 = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;
    address internal constant UNI_WETH_3000 = 0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801;
    address internal constant TBTC_WETH_3000 = 0x97944213D2caeeA773DA1c9B11B0525F25b749CC;
    address internal constant AAVE_WETH_3000 = 0x5aB53EE1d50eeF2C1DD3d5402789cd27bB52c1bB;
    /// @dev The default list's DeFi tokens: each token's WETH pool holding the most WETH on 2026-09-17, checked with
    ///      UNISWAP_V3_FACTORY.getPool. Observation slots that day: ONDO 128, ENA 600, MORPHO 51, ETHFI 300, CRV 180,
    ///      PENDLE 100, OHM 128, LDO 180, SYRUP 100; only ENA's and ETHFI's (and AAVE's 1000) reach the rule's 200.
    address internal constant ONDO_WETH_3000 = 0x7b1E5D984A43eE732de195628d20d05CFaBc3cC7;
    address internal constant ENA_WETH_3000 = 0xc3Db44ADC1fCdFd5671f555236eae49f4A8EEa18;
    address internal constant MORPHO_WETH_3000 = 0xc8219b876753A85025156b22176c2eDEA17aAC53;
    address internal constant ETHFI_WETH_3000 = 0x06f00544C0bc62E6db10F46D370dFCcDC23d8189;
    address internal constant CRV_WETH_3000 = 0x919Fa96e88d67499339577Fa202345436bcDaf79;
    address internal constant PENDLE_WETH_3000 = 0x57aF956d3E2cCa3B86f3D8C6772C03ddca3eAacB;
    address internal constant OHM_WETH_3000 = 0x88051B0eea095007D3bEf21aB287Be961f3d8598;
    address internal constant LDO_WETH_3000 = 0xa3f558aebAecAf0e11cA4b2199cC5Ed341edfd74;
    address internal constant SYRUP_WETH_10000 = 0x27941A235804f33D81aDaBb2d56589c5f6Ea6556;

    /// @dev The reference supplies of the default whitelist.
    uint256 internal constant BTC_SUPPLY = MainnetAddresses.BTC_SUPPLY;
    uint256 internal constant ETH_SUPPLY = MainnetAddresses.ETH_SUPPLY;
    uint256 internal constant LINK_SUPPLY = MainnetAddresses.LINK_SUPPLY;
    uint256 internal constant UNI_SUPPLY = MainnetAddresses.UNI_SUPPLY;

    /// @dev Block the fork tests pin to. Bump deliberately; a pinned block keeps quotes deterministic
    ///      and lets the RPC cache.
    uint256 internal constant FORK_BLOCK = 26033838;
}
