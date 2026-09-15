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

    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @dev Block the fork tests pin to. Bump deliberately; a pinned block keeps quotes deterministic
    ///      and lets the RPC cache.
    uint256 internal constant FORK_BLOCK = 25_978_000;
}
