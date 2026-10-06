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
    /// @dev The two top-100 Ethereum coins the WBT rule keeps off the wide list (design/2026-10-05-token-admission-
    ///      report.md): LEO, whose MiniMe controller destroys any balance and approves every transfer, and WLFI, whose
    ///      owner blacklists and reallocates any holder's balance.
    address internal constant LEO = 0x2AF5D2aD76741191D15Dfe7bF6aC92d4Bd912Ca3;
    address internal constant WLFI = 0xdA5e1988097297dCdc1f90D4dFE7909e847CBeF6;

    /// @dev Uniswap SwapRouter02. The zap swaps through the Universal Router; this is only the fork tests' own rebalance
    ///      executor, a fixture whose venue is independent of anything Xindex deploys.
    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
    address internal constant POOL_MANAGER = MainnetAddresses.POOL_MANAGER;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    /// @dev PancakeSwap's v3 Universal Router, through which the zap runs a leg that names a PancakeSwap V3 path, and
    ///      PancakeSwap's QuoterV2, which only the fork tests use to size such a leg. CAKE is PancakeSwap's own coin and
    ///      the one listed coin whose deepest Ethereum pool is PancakeSwap's.
    address internal constant PANCAKE_UNIVERSAL_ROUTER = MainnetAddresses.PANCAKE_UNIVERSAL_ROUTER;
    address internal constant PANCAKE_QUOTER_V2 = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address internal constant CAKE = MainnetAddresses.CAKE;
    /// @dev Pyth's proxy, which a v5 factory needs at construction; the zap suites never ask it for a price.
    address internal constant PYTH = MainnetAddresses.PYTH;

    /// @dev Block the fork tests pin to. Bump deliberately; a pinned block keeps quotes deterministic
    ///      and lets the RPC cache.
    uint256 internal constant FORK_BLOCK = 26033838;
}
