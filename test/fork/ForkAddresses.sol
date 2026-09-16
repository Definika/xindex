// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @notice The pool read the fork tests use to size a listing's minimum liquidity.
interface IPoolLiquidity {
    function liquidity() external view returns (uint128);
}

/// @notice Ethereum mainnet addresses the fork tests use: the scripts' `MainnetAddresses` re-exported, plus contracts
///         and pools only the tests need.
library ForkAddresses {
    address internal constant USDC = MainnetAddresses.USDC;
    address internal constant USDT = MainnetAddresses.USDT;
    address internal constant WETH = MainnetAddresses.WETH;
    address internal constant WBTC = MainnetAddresses.WBTC;
    address internal constant LINK = MainnetAddresses.LINK;
    address internal constant UNI = MainnetAddresses.UNI;
    address internal constant TBTC = MainnetAddresses.TBTC;
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9; // checked on 2026-09-16: symbol AAVE, 18 decimals

    address internal constant SWAP_ROUTER_02 = MainnetAddresses.SWAP_ROUTER_02;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant UNISWAP_V3_FACTORY = MainnetAddresses.UNISWAP_V3_FACTORY;

    /// @dev Uniswap V3 WETH pools, each checked on 2026-09-16 with UNISWAP_V3_FACTORY.getPool and its token0/token1.
    ///      Observation slots on that day: USDC 723, WBTC 300, LINK 360, UNI 300, AAVE 1000, tBTC 60 (too few for the rule).
    address internal constant USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant WBTC_WETH_500 = 0x4585FE77225b41b697C938B018E2Ac67Ac5a20c0;
    address internal constant LINK_WETH_3000 = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;
    address internal constant UNI_WETH_3000 = 0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801;
    address internal constant TBTC_WETH_3000 = 0x97944213D2caeeA773DA1c9B11B0525F25b749CC;
    address internal constant AAVE_WETH_3000 = 0x5aB53EE1d50eeF2C1DD3d5402789cd27bB52c1bB;

    /// @dev The reference supplies of the default whitelist.
    uint256 internal constant BTC_SUPPLY = MainnetAddresses.BTC_SUPPLY;
    uint256 internal constant ETH_SUPPLY = MainnetAddresses.ETH_SUPPLY;
    uint256 internal constant LINK_SUPPLY = MainnetAddresses.LINK_SUPPLY;
    uint256 internal constant UNI_SUPPLY = MainnetAddresses.UNI_SUPPLY;

    /// @dev Block the fork tests pin to. Bump deliberately; a pinned block keeps quotes deterministic
    ///      and lets the RPC cache.
    uint256 internal constant FORK_BLOCK = 25_978_000;
}
