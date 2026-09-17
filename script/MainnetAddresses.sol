// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The Ethereum mainnet contracts and market data the deploy and listing scripts use. This is the only copy:
///         the scripts, the testnet market and the fork tests read it, and `test/fork/MainnetAddresses.fork.t.sol`
///         checks it on-chain (tokens by symbol and decimals, pools with the Uniswap V3 factory's `getPool`).
library MainnetAddresses {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    /// @dev tBTC v2, 18 decimals.
    address internal constant TBTC = 0x18084fbA666a33d37592fA2633fD49a74DD93a88;

    address internal constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @dev Circulating supplies reported by CoinGecko on 2026-09-15, rounded down to whole tokens, in raw units. WBTC
    ///      and WETH are listed with bitcoin's and ether's supply, because their on-chain supply is only the wrapped
    ///      float.
    uint256 internal constant BTC_SUPPLY = 20_084_784e8;
    uint256 internal constant ETH_SUPPLY = 122_050_160e18;
    uint256 internal constant LINK_SUPPLY = 748_099_970e18;
    uint256 internal constant UNI_SUPPLY = 623_212_423e18;

    /// @dev A tenth of each WETH pool's 30-minute harmonic-mean liquidity at block 25,992,129 (2026-09-16), rounded
    ///      down to two significant digits: WBTC 0.05%, LINK, UNI and tBTC 0.3%.
    uint128 internal constant WBTC_MIN_LIQUIDITY = 1.4e16;
    uint128 internal constant LINK_MIN_LIQUIDITY = 3.4e22;
    uint128 internal constant UNI_MIN_LIQUIDITY = 2.9e22;
    uint128 internal constant TBTC_MIN_LIQUIDITY = 7e18;
}
