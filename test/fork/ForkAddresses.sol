// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MainnetAddresses} from "../../script/MainnetAddresses.sol";

/// @notice Ethereum mainnet addresses the fork tests use: the scripts' `MainnetAddresses` re-exported, plus contracts
///         only the tests need.
library ForkAddresses {
    address internal constant USDC = MainnetAddresses.USDC;
    address internal constant USDT = MainnetAddresses.USDT;
    address internal constant WETH = MainnetAddresses.WETH;
    address internal constant WBTC = MainnetAddresses.WBTC;
    address internal constant LINK = MainnetAddresses.LINK;
    address internal constant UNI = MainnetAddresses.UNI;
    /// @dev tBTC is not on the Stage A whitelist; the zap fork tests still route through its pool.
    address internal constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;
    /// @dev WhiteBIT's WBT, kept off every list by the WBT rule (design/2026-09-30-wbt-check.md); the admission check's
    ///      fork test proves the check refuses it.
    address internal constant WBT = 0x925206b8a707096Ed26ae47C84747fE0bb734F59;

    /// @dev Uniswap SwapRouter02. The zap swaps through the Universal Router; this is only the fork tests' own rebalance
    ///      executor, a fixture whose venue is independent of anything Xindex deploys.
    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
    address internal constant POOL_MANAGER = MainnetAddresses.POOL_MANAGER;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    /// @dev The reference supplies of the default whitelist.
    uint256 internal constant BTC_SUPPLY = MainnetAddresses.BTC_SUPPLY;
    uint256 internal constant ETH_SUPPLY = MainnetAddresses.ETH_SUPPLY;
    uint256 internal constant LINK_SUPPLY = MainnetAddresses.LINK_SUPPLY;
    uint256 internal constant UNI_SUPPLY = MainnetAddresses.UNI_SUPPLY;

    /// @dev Block the fork tests pin to. Bump deliberately; a pinned block keeps quotes deterministic
    ///      and lets the RPC cache.
    uint256 internal constant FORK_BLOCK = 26033838;
}
