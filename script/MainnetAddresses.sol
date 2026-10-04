// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The Ethereum mainnet contracts and market data the deploy and listing scripts use. This is the only copy:
///         the scripts, the testnet market and the fork tests read it, and `test/fork/MainnetAddresses.fork.t.sol`
///         checks it on-chain (tokens by symbol and decimals, the router and the PoolManager by their code).
library MainnetAddresses {
    // ---------------------------------------------------------------------
    // Components: the Stage A list, the Ethereum tokens of the design's 0.2% weight floor that pass its liquidity
    // screen (design/2026-09-29-v4-hybrid-architecture.md, section 2.1). Checked on 2026-09-22 by symbol and decimals.
    // WBT, also on the floor list, stays off after its check: a single key can blacklist a holder and destroy its
    // balance, and no Uniswap pool holds it (design/2026-09-30-wbt-check.md, the owner's call on 2026-09-30).
    // ---------------------------------------------------------------------
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    // ---------------------------------------------------------------------
    // Mint and burn currencies. Never components; see the whitelist policy.
    // ---------------------------------------------------------------------
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // ---------------------------------------------------------------------
    // Execution.
    // ---------------------------------------------------------------------
    /// @dev Uniswap Universal Router 2.0.0, which routes both V3 and V4 pools. Pinned to this deployment rather than
    ///      the 2.1.x line, whose V3 inputs carry an extra per-hop price array (`minHopPriceX36`) the zap does not
    ///      encode: a 2.0.0-shaped input reverts SliceOutOfBounds on the labelled 2.1.1 and 2.1.2 releases. One
    ///      unlabelled 2.1-line deployment, 0x0542093271A31f6FC1DADB232bd59eeb27de780F, also carried #491 and #497,
    ///      which upstream later reverted; the labelled releases carry neither (CR-I19). Its runtime code hash is
    ///      pinned by `test/fork/MainnetAddresses.fork.t.sol`, since every build answers `poolManager()` the same way.
    address internal constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// @dev Uniswap V4 singleton the Universal Router settles V4 legs against. The zap reads it from the router
    ///      rather than taking it as an argument, so the two can never be wired to different deployments.
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // ---------------------------------------------------------------------
    // Reference supplies. Every token carries one, and nothing reads a supply live (CR-M01). Circulating supplies
    // reported by CoinGecko on 2026-09-22, rounded down to whole tokens, in raw units. WBTC and WETH are listed with
    // bitcoin's and ether's supply, because their on-chain supply is only the wrapped float. Revised weekly through a
    // supply batch (`ConfigureWhitelist` supplies mode), each within 0.5% of the figure in force.
    // ---------------------------------------------------------------------
    // A launch listing carries these figures and a first figure moves by at most half a percent a week, so they are
    // refreshed from their sources the day before it is proposed, with `test_CRL08_theDefaultListIsTheReleaseRecord`
    // (README, "Deploy", A7-20).
    uint256 internal constant BTC_SUPPLY = 20_087_871e8; // CoinGecko circulating supply of bitcoin, 2026-09-22
    uint256 internal constant ETH_SUPPLY = 122_070_499e18; // CoinGecko circulating supply of ether, 2026-09-22
    uint256 internal constant LINK_SUPPLY = 748_099_970e18; // CoinGecko circulating supply of LINK, 2026-09-22
    uint256 internal constant UNI_SUPPLY = 620_716_422e18; // CoinGecko circulating supply of UNI, 2026-09-22
}
