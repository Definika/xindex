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
    /// @dev The DeFi tokens of the default list, each checked on 2026-09-17 by symbol and decimals (OHM has 9).
    address internal constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
    address internal constant ONDO = 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3;
    address internal constant ENA = 0x57e114B691Db790C35207b2e685D4A43181e6061;
    address internal constant MORPHO = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2;
    address internal constant ETHFI = 0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB;
    address internal constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address internal constant PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
    address internal constant OHM = 0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5;
    address internal constant LDO = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
    address internal constant SYRUP = 0x643C4E15d7d62Ad0aBeC4a9BD4b001aA3Ef52d66;
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
    /// @dev Circulating supplies of the DeFi tokens reported by CoinGecko on 2026-09-17, rounded down to whole tokens,
    ///      in raw units. Their on-chain supplies include locked and unvested tokens, which would overweight them.
    uint256 internal constant AAVE_SUPPLY = 15_427_833e18;
    uint256 internal constant ONDO_SUPPLY = 4_869_330_647e18;
    uint256 internal constant ENA_SUPPLY = 10_095_312_500e18;
    uint256 internal constant MORPHO_SUPPLY = 698_774_851e18;
    uint256 internal constant ETHFI_SUPPLY = 965_350_000e18;
    uint256 internal constant CRV_SUPPLY = 1_560_277_795e18;
    uint256 internal constant PENDLE_SUPPLY = 173_573_832e18;
    uint256 internal constant OHM_SUPPLY = 14_920_338e9;
    uint256 internal constant LDO_SUPPLY = 834_151_322e18;
    uint256 internal constant SYRUP_SUPPLY = 1_167_271_959e18;

    /// @dev A third of the lowest 30-minute harmonic-mean liquidity each WETH pool's own oracle reports over the
    ///      windows it still holds (4 to 12 hours), read at block 26,019,190 (2026-09-20) and rounded down to two
    ///      significant digits. Each pool is the token's WETH pool holding the most WETH: WBTC 0.05%, SYRUP 1%, the
    ///      rest 0.3%. Pools are compared by the WETH they hold, not by `liquidity()`, which an abandoned pool parked
    ///      at an extreme tick can report large while holding nothing.
    ///
    ///      A third, not the tenth used through 2026-09-17: the floor is the only thing that prices a manipulation
    ///      held across the whole window, since no statistic inside the window can see one (DA-03), and raising it
    ///      raises that cost in proportion. It is not higher because the floor also has to survive ordinary liquidity
    ///      drift: UNI's pool lost 54% of its harmonic-mean liquidity between 2026-09-17 and 2026-09-20, while the
    ///      spread within any one day stayed inside 13%. A third leaves room for a repeat of that and still refuses a
    ///      window three times thinner than the pool really is. Re-measure before mainnet and when a pool's depth
    ///      moves for good; a floor the pool no longer meets blocks that component's snapshots until a config change
    ///      lowers it, which takes the listing delay.
    uint128 internal constant WBTC_MIN_LIQUIDITY = 4.6e16;
    uint128 internal constant LINK_MIN_LIQUIDITY = 1.1e23;
    uint128 internal constant UNI_MIN_LIQUIDITY = 4.4e22;
    uint128 internal constant TBTC_MIN_LIQUIDITY = 2.3e19;
    uint128 internal constant AAVE_MIN_LIQUIDITY = 7.6e21;
    uint128 internal constant ONDO_MIN_LIQUIDITY = 1.5e22;
    uint128 internal constant ENA_MIN_LIQUIDITY = 3.2e22;
    uint128 internal constant MORPHO_MIN_LIQUIDITY = 8e20;
    uint128 internal constant ETHFI_MIN_LIQUIDITY = 3.6e21;
    uint128 internal constant CRV_MIN_LIQUIDITY = 1.1e22;
    uint128 internal constant PENDLE_MIN_LIQUIDITY = 2.8e21;
    uint128 internal constant OHM_MIN_LIQUIDITY = 1.1e17;
    uint128 internal constant LDO_MIN_LIQUIDITY = 4.4e21;
    uint128 internal constant SYRUP_MIN_LIQUIDITY = 3.3e22;
}
