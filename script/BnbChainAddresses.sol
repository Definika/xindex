// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice BNB Chain tokens the vault there may hold (design/2026-10-05-wide-asset-support.md, section 3), each read on
///         chain 56 by symbol, name and decimals on 2026-10-05, and checked by `CheckToken`
///         (design/2026-10-05-token-admission-report.md). A token here is listed on Ethereum as a vault coin,
///         `vaultTokenId(56, bytes32(token))`, by `ConfigureChains`' `VAULT_TOKENS=bnb`; the vault takes it only once a
///         `CAP_UPDATE` gives it a cap.
/// @dev NIGHT (0xFe930c2d63AeD9b82fC4DBC801920dD2c1a3224F) is left out pending the owner's word: its owner burns any
///      holder's balance with no allowance, and its bridge's treasury was reported drained on 2026-07-20.
library BnbChainAddresses {
    /// @notice BNB Chain's chain id.
    uint256 internal constant CHAIN_ID = 56;

    // ---------------------------------------------------------------------
    // Binance-Peg tokens: custodial copies Binance mints with a single key (`0xF68a…f62d`), the trust tier
    // `Custodial`. SOL, DOGE, AVAX and FIL also sit behind a proxy a single key upgrades.
    // ---------------------------------------------------------------------
    address internal constant XRP = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;
    address internal constant SOL = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;
    address internal constant ZEC = 0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb;
    /// @dev 8 decimals, the only one here that is not 18.
    address internal constant DOGE = 0xbA2aE424d960c26247Dd6c32edC70B295c744C43;
    address internal constant ADA = 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47;
    address internal constant BCH = 0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf;
    address internal constant LTC = 0x4338665CBB7B2485A8855A139b75D5e34AB0DB94;
    address internal constant AVAX = 0x1CE0c2827e2eF14D5C4f29a091d735A204794041;
    address internal constant DOT = 0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402;
    address internal constant FIL = 0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153;
    address internal constant ATOM = 0x0Eb3a705fc54725037CC9e008bDede697f62F335;

    // ---------------------------------------------------------------------
    // Tokens issued for BNB Chain: ASTER, `Native`, with a fixed supply and no admin power found; STABLE, `Bridged`,
    // a LayerZero OFT whose 3-of-5 Safe owner sets its peers and upgrades it.
    // ---------------------------------------------------------------------
    address internal constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;
    address internal constant STABLE = 0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F;

    // ---------------------------------------------------------------------
    // Reference supplies: the coin's circulating supply reported by CoinGecko on 2026-10-05 (04:44 to 04:56 UTC),
    // rounded down to whole tokens, in the BNB Chain token's raw units; beside each, the second source the admission
    // report took. A Binance-Peg token carries its coin's whole circulating supply, as WBTC carries bitcoin's.
    // ---------------------------------------------------------------------
    /// @dev CoinMarketCap, the same.
    uint256 internal constant XRP_SUPPLY = 63_092_975_951e18;
    /// @dev CoinMarketCap 588,314,062.
    uint256 internal constant SOL_SUPPLY = 588_314_090e18;
    /// @dev CoinMarketCap 16,901,419 (+0.4%).
    uint256 internal constant ZEC_SUPPLY = 16_966_725e18;
    /// @dev Blockchair 156,193,796,383. 8 decimals.
    uint256 internal constant DOGE_SUPPLY = 156_193_186_383e8;
    /// @dev CoinMarketCap 36,786,187,631 (+2.0%).
    uint256 internal constant ADA_SUPPLY = 37_541_298_084e18;
    /// @dev CoinMarketCap 20,098,593.
    uint256 internal constant BCH_SUPPLY = 20_098_553e18;
    /// @dev CoinMarketCap 77,684,523.
    uint256 internal constant LTC_SUPPLY = 77_681_660e18;
    /// @dev CoinMarketCap 443,237,725.
    uint256 internal constant AVAX_SUPPLY = 443_237_655e18;
    /// @dev CoinMarketCap 1,705,891,826.
    uint256 internal constant DOT_SUPPLY = 1_705_877_534e18;
    /// @dev CoinMarketCap, the same.
    uint256 internal constant FIL_SUPPLY = 833_303_530e18;
    /// @dev CoinMarketCap 534,079,426.
    uint256 internal constant ATOM_SUPPLY = 534_279_412e18;
    /// @dev CoinMarketCap 2,704,529,094 (+0.2%).
    uint256 internal constant ASTER_SUPPLY = 2_710_487_455e18;
    /// @dev CoinMarketCap 26,923,983,196.
    uint256 internal constant STABLE_SUPPLY = 26_924_041_495e18;

    // ---------------------------------------------------------------------
    // Pyth price ids for v5 (Hermes catalogue, 2026-10-05): a Binance-Peg token is priced at its coin, as nothing quotes
    // the peg itself; its custodian is labelled in the app. Decimals are 18 but DOGE's 8.
    // ---------------------------------------------------------------------
    /// @dev RIPPLE / US DOLLAR.
    bytes32 internal constant XRP_PRICE_ID = 0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8;
    /// @dev SOLANA / US DOLLAR.
    bytes32 internal constant SOL_PRICE_ID = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    /// @dev ZCASH / US DOLLAR.
    bytes32 internal constant ZEC_PRICE_ID = 0xbe9b59d178f0d6a97ab4c343bff2aa69caa1eaae3e9048a65788c529b125bb24;
    /// @dev DOGECOIN / US DOLLAR.
    bytes32 internal constant DOGE_PRICE_ID = 0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c;
    /// @dev CARDANO / US DOLLAR.
    bytes32 internal constant ADA_PRICE_ID = 0x2a01deaec9e51a579277b34b122399984d0bbf57e2458a7e42fecd2829867a0d;
    /// @dev BITCOIN CASH / US DOLLAR.
    bytes32 internal constant BCH_PRICE_ID = 0x3dd2b63686a450ec7290df3a1e0b583c0481f651351edfa7636f39aed55cf8a3;
    /// @dev LITECOIN / US DOLLAR.
    bytes32 internal constant LTC_PRICE_ID = 0x6e3f3fa8253588df9326580180233eb791e03b443a3ba7a1d892e73874e19a54;
    /// @dev AVALANCHE / US DOLLAR.
    bytes32 internal constant AVAX_PRICE_ID = 0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7;
    /// @dev POLKADOT / US DOLLAR.
    bytes32 internal constant DOT_PRICE_ID = 0xca3eed9b267293f6595901c734c7525ce8ef49adafe8284606ceb307afa2ca5b;
    /// @dev FILECOIN / US DOLLAR.
    bytes32 internal constant FIL_PRICE_ID = 0x150ac9b959aee0051e4091f0ef5216d941f590e1c5e7f91cf7635b5c11628c0e;
    /// @dev COSMOS / US DOLLAR.
    bytes32 internal constant ATOM_PRICE_ID = 0xb00b60f88b03a6a625a8d1c048c3f66653edf217439983d037e7222c4e612819;
    /// @dev ASTER DEX / US DOLLAR.
    bytes32 internal constant ASTER_PRICE_ID = 0xa903b5a82cb572397e3d47595d2889cf80513f5b4cf7a36b513ae10cc8b1e338;
    /// @dev STABLE / US DOLLAR.
    bytes32 internal constant STABLE_PRICE_ID = 0x98d7f32f2c26ea94c79a15df45239b7c2e04368e46f49fdbf06dd5e449374e64;
}
