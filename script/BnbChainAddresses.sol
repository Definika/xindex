// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PythIds} from "./PythIds.sol";

/// @notice The BNB Chain contracts and market data the deploy and listing scripts use for the BNB Chain deployment
///         (`design/2026-10-07-two-chain-deployment.md`): the tokens its indexes may hold, each with the Pyth price id
///         it is listed with and its trust tier, the mint currencies, the routers and Pyth. This is the only copy:
///         `DeployWeighted` and `ConfigureWeighted` read it on chain 56, and `test/fork/BnbChainAddresses.fork.t.sol`
///         checks it on chain (tokens by symbol and decimals, the routers, the PoolManager and Pyth's proxy by their
///         runtime code). Every token here is read on chain 56 by symbol, name and decimals; the fourteen of the
///         2026-10-05 list passed `CheckToken` then (`design/2026-10-05-token-admission-report.md`), and WBNB, BTCB and
///         ETH are checked by the fork suite.
/// @dev Binance-Peg SOL (0x570A5D26f7765Ecb712C0924E4De545B89fD43dF) left this list on 2026-10-10 (the owner's call):
///      SOL is held on Ethereum instead, as Wormhole's copy (`MainnetAddresses.SOL`). Of the other Binance-Peg coins,
///      none has an Ethereum copy that passes `CheckToken` with a Uniswap route
///      (`design/2026-10-05-token-admission-report.md`, "Binance-Peg coins on Ethereum").
///      NIGHT (0xFe930c2d63AeD9b82fC4DBC801920dD2c1a3224F) is refused (the owner's call on 2026-10-06): its owner burns
///      any holder's balance with no allowance, and its bridge's treasury was reported drained on 2026-07-20.
library BnbChainAddresses {
    /// @notice BNB Chain's chain id.
    uint256 internal constant CHAIN_ID = 56;
    /// @notice How many coins the table names.
    uint256 internal constant COUNT = 16;

    // ---------------------------------------------------------------------
    // BNB Chain's own coin, wrapped as WETH wraps ether, and the two majors as Binance holds them: BTCB and "ETH" are
    // Binance-Peg tokens, `Custodial`, 18 decimals each. Read on chain 56 on 2026-10-07 at block 126,305,003.
    // ---------------------------------------------------------------------
    /// @dev "Wrapped BNB", symbol WBNB, 18 decimals: the WETH9 wrapper, `Native`.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev "BTCB Token", symbol BTCB, 18 decimals: Binance's bitcoin, as WBTC is BitGo's.
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    /// @dev "Ethereum Token", symbol ETH, 18 decimals: Binance-Peg ether.
    address internal constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // ---------------------------------------------------------------------
    // Binance-Peg tokens: custodial copies Binance mints with a single key (`0xF68a…f62d`), the trust tier
    // `Custodial`. DOGE, AVAX and FIL also sit behind a proxy a single key upgrades. Read on chain 56 on
    // 2026-10-05.
    // ---------------------------------------------------------------------
    address internal constant XRP = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;
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
    // TRON's TRX as its BTTC bridge minted it, read on chain 56 on 2026-10-06 (the owner's call that day): `Custodial`,
    // since TRON closed that bridge on 2026-06-18 and holders now redeem through its partner exchanges. Its one minter
    // is the bridge's predicate, 0xCa266910d92a313E5F9eb1AfFC462bcbb7d9c4A9, a proxy whose owner, a 3-of-5 Safe at
    // 0x7dEf28fDD268e7Fd496cE0c834186fa5ffbfDBbb, upgrades it. 6 decimals.
    // ---------------------------------------------------------------------
    address internal constant TRX = 0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3;

    // ---------------------------------------------------------------------
    // Mint and burn currencies, 18 decimals each on BNB Chain ("Tether USD" and "USD Coin", Binance-Peg). Never
    // components; see the whitelist policy. Nothing in the zap or `MintRequests` assumes a currency's decimals.
    // ---------------------------------------------------------------------
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    // ---------------------------------------------------------------------
    // Execution. Both routers are the same builds as the Ethereum ones the zap is pinned to, byte for byte but for
    // their immutables (compared on 2026-10-07: 22 differing 20-byte runs in Uniswap's, 19 of 20 and 32 bytes in
    // PancakeSwap's), so the command inputs the zap encodes hold here. Their runtime code hashes are pinned by
    // `test/fork/BnbChainAddresses.fork.t.sol`.
    // ---------------------------------------------------------------------
    /// @dev Uniswap Universal Router 2.0.0 on BNB Chain, which routes both V3 and V4 pools; answers {POOL_MANAGER}.
    address internal constant UNIVERSAL_ROUTER = 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07;
    /// @dev Uniswap V4's PoolManager on BNB Chain, which the zap reads off the router.
    address internal constant POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    /// @dev Uniswap V3's factory on BNB Chain, where `CheckToken` looks up a token's Uniswap pools. Most BNB Chain
    ///      depth sits on PancakeSwap, which `CheckToken` does not read, so the depth it records here understates.
    address internal constant UNISWAP_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    /// @dev PancakeSwap's v3 Universal Router on BNB Chain, the same build as Ethereum's
    ///      `MainnetAddresses.PANCAKE_UNIVERSAL_ROUTER`, wired to PancakeSwap's BNB Chain deployer, Permit2 and WBNB.
    address internal constant PANCAKE_UNIVERSAL_ROUTER = 0x1A0A18AC4BECDDbd6389559687d1A73d8927E416;

    // ---------------------------------------------------------------------
    // Prices.
    // ---------------------------------------------------------------------
    /// @dev Pyth's contract on BNB Chain, from which `WeightedHub` reads every settlement's prices there: an ERC-1967
    ///      proxy with the same code as Ethereum's, read on 2026-10-07 at block 126,305,003: version 1.4.6, Wormhole
    ///      chain id 4, update fee 0.
    address internal constant PYTH = 0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594;

    // ---------------------------------------------------------------------
    // Pyth price ids (Hermes catalogue, 2026-10-05 and 2026-10-07): a Binance-Peg token is priced at its coin, as
    // nothing quotes the peg itself, so a rebalance would not see it lose its peg; its custodian is labelled in the
    // app. No two entries share an id (V5-M1): the BNB Chain list holds one bitcoin and one ether.
    // ---------------------------------------------------------------------
    /// @dev BNB / US DOLLAR.
    bytes32 internal constant WBNB_PRICE_ID = 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f;
    /// @dev BITCOIN / US DOLLAR: Pyth has no BTCB feed, unlike WBTC's on Ethereum.
    bytes32 internal constant BTCB_PRICE_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    /// @dev ETHEREUM / US DOLLAR.
    bytes32 internal constant ETH_PRICE_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    /// @dev RIPPLE / US DOLLAR.
    bytes32 internal constant XRP_PRICE_ID = 0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8;
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
    /// @dev TRON / US DOLLAR, native TRX's feed: nothing prices the bridged copy apart.
    bytes32 internal constant TRX_PRICE_ID = 0x67aed5a24fdad045475e7195c98a98aea119c763f272d4523f5bac93a4f33c2b;

    /// @notice Every coin of the table and its id: WBNB, BTCB and ETH first, then the Binance-Peg coins, BNB Chain's
    ///         own tokens and TRX.
    function all() internal pure returns (address[] memory tokens, bytes32[] memory ids) {
        tokens = new address[](COUNT);
        ids = new bytes32[](COUNT);
        (tokens[0], ids[0]) = (WBNB, WBNB_PRICE_ID);
        (tokens[1], ids[1]) = (BTCB, BTCB_PRICE_ID);
        (tokens[2], ids[2]) = (ETH, ETH_PRICE_ID);
        (tokens[3], ids[3]) = (XRP, XRP_PRICE_ID);
        (tokens[4], ids[4]) = (ZEC, ZEC_PRICE_ID);
        (tokens[5], ids[5]) = (DOGE, DOGE_PRICE_ID);
        (tokens[6], ids[6]) = (ADA, ADA_PRICE_ID);
        (tokens[7], ids[7]) = (BCH, BCH_PRICE_ID);
        (tokens[8], ids[8]) = (LTC, LTC_PRICE_ID);
        (tokens[9], ids[9]) = (AVAX, AVAX_PRICE_ID);
        (tokens[10], ids[10]) = (DOT, DOT_PRICE_ID);
        (tokens[11], ids[11]) = (FIL, FIL_PRICE_ID);
        (tokens[12], ids[12]) = (ATOM, ATOM_PRICE_ID);
        (tokens[13], ids[13]) = (ASTER, ASTER_PRICE_ID);
        (tokens[14], ids[14]) = (STABLE, STABLE_PRICE_ID);
        (tokens[15], ids[15]) = (TRX, TRX_PRICE_ID);
    }

    /// @notice The tier of a token in the table, as `PythIds.tierOf` gives Ethereum's: `Custodial` for every
    ///         Binance-Peg token, BTCB and ETH among them, and for the bridge's TRX; `Bridged` for STABLE; `Native` for
    ///         WBNB and ASTER; `Unrecorded` for any token off the table.
    function tierOf(address token) internal pure returns (PythIds.Tier) {
        if (token == WBNB || token == ASTER) return PythIds.Tier.Native;
        if (token == STABLE) return PythIds.Tier.Bridged;
        if (
            token == BTCB || token == ETH || token == XRP || token == ZEC || token == DOGE || token == ADA
                || token == BCH || token == LTC || token == AVAX || token == DOT || token == FIL || token == ATOM
                || token == TRX
        ) return PythIds.Tier.Custodial;
        return PythIds.Tier.Unrecorded;
    }
}
