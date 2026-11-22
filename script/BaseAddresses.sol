// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Listings} from "./Listings.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice The Base contracts the deploy and listing scripts use for the Base deployment (the owner's call of
///         2026-11-21, `design/2026-11-21-base-deployment.md`): the tokens its indexes may hold, each with its trust
///         tier, the mint currencies and Uniswap's contracts there. This is the only copy: `DeployChecks`,
///         `ConfigureWeighted` and `CheckToken` read it on chain 8453, and `test/fork/BaseAddresses.fork.t.sol` checks
///         it on chain (tokens by symbol and decimals, each bridged copy by the Ethereum token and the bridge it
///         names, the router, the PoolManager and the V3 factory by their runtime code). No coin carries a price
///         feed: an index rebalances on units alone (`design/2026-11-10-oracle-free-rebalance.md`). Every address
///         here was read on chain 8453 on 2026-11-21, at block 60,490,874, and Coinbase's coins and stocks on
///         2026-11-22 (`design/2026-11-22-coinbase-on-base.md`).
/// @dev The list is the owner's rules of those two days: the coins issued on Base itself, each coin of Ethereum's
///      list whose copy Base's own bridge mints, proven on chain, and every coin and stock Coinbase issues on Base. Proven means three readings: the copy's `remoteToken()`
///      is the coin's address in `MainnetAddresses`, its `bridge()` is Base's standard bridge ({STANDARD_BRIDGE}),
///      and on Ethereum the other half of that bridge ({L1_STANDARD_BRIDGE}) holds the copy's backing
///      (`deposits(remote, copy)`, at or above the copy's supply on Base for every one listed).
///      - Thirteen coins pass: UNI, AAVE, MORPHO, FET, CRV, VIRTUAL, PENDLE, PEPE, GRT, COMP, SNX, 1INCH and RSR.
///      - SHIB and EIGEN have a balance in the bridge on Ethereum and no copy was found for them: not listed.
///      - LINK on Base is Chainlink's own cross-chain token, not the bridge's copy: not listed.
///      - No Ondo stock is listed: Ondo's list of 2026-11-22 is Ethereum's and BNB Chain's. Backed's wrapper factory
///        has deployed four wrappers of its older tokens here (wbCOIN, wbMSTR, wbNVDA, wbTSLA), which no list holds:
///        no Pyth feed names their tokens.
///      - The stocks a Base index holds are Coinbase's ten, and cbBTC, refused on 2026-11-21 as a custodian the lists
///        did not have, is listed with the other Coinbase Wrapped coins (the owner's call of 2026-11-22).
library BaseAddresses {
    /// @notice Base's chain id.
    uint256 internal constant CHAIN_ID = 8453;
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 32;
    /// @notice How many of them are copies Base's bridge mints of coins on Ethereum's list.
    uint256 internal constant BRIDGED = 13;
    /// @notice How many of them are Coinbase Wrapped coins.
    uint256 internal constant CB_COINS = 6;
    /// @notice How many of them are Coinbase's stock tokens.
    uint256 internal constant STOCKS = 10;
    /// @notice The decimals each stock token answers on Base's node, where alone it answers.
    uint8 internal constant STOCK_DECIMALS = 8;

    // ---------------------------------------------------------------------
    // Coins issued on Base, `Native`: ether wrapped as on Ethereum, and Aerodrome's AERO, minted by its own Minter
    // contract (`minter()`), which no bridge stands behind. On Ethereum AERO is held as Wormhole's copy of this token.
    // 18 decimals each.
    // ---------------------------------------------------------------------
    /// @dev "Wrapped Ether", symbol WETH, 18 decimals: the WETH9 predeploy every OP Stack chain has at this address.
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    /// @dev "Aerodrome", symbol AERO, 18 decimals.
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // ---------------------------------------------------------------------
    // LayerZero's ZRO, `Bridged` as on Ethereum: the issuer's own omnichain token, at the address it has on every
    // chain, minted here on a message through LayerZero's endpoint (`endpoint()`), which its owner configures.
    // ---------------------------------------------------------------------
    /// @dev "LayerZero", symbol ZRO, 18 decimals.
    address internal constant ZRO = 0x6985884C4392D348587B19cb9eAAf157F13271cd;

    // ---------------------------------------------------------------------
    // Copies Base's standard bridge mints of coins on Ethereum's list, `Bridged`: a deposit into the bridge on
    // Ethereum mints the copy here and a withdrawal burns it, so each rests on that bridge and on Base's own
    // security, whose keys can upgrade both halves. Each names its Ethereum token ({remoteOf}) and the bridge;
    // 18 decimals each, as on Ethereum. MORPHO's is not the bridge factory's token: it answers `owner()`, which the
    // admission check reports.
    // ---------------------------------------------------------------------
    /// @dev Symbol UNI.
    address internal constant UNI = 0xc3De830EA07524a0761646a6a4e4be0e114a3C83;
    /// @dev Symbol AAVE.
    address internal constant AAVE = 0x63706e401c06ac8513145b7687A14804d17f814b;
    /// @dev Symbol MORPHO.
    address internal constant MORPHO = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
    /// @dev Symbol FET.
    address internal constant FET = 0x74F804B4140ee70830B3Eef4e690325841575F89;
    /// @dev Symbol CRV.
    address internal constant CRV = 0x8Ee73c484A26e0A5df2Ee2a4960B789967dd0415;
    /// @dev Symbol VIRTUAL. 498 million VIRTUAL sat in the bridge on Ethereum that day: the coin trades here.
    address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    /// @dev Symbol PENDLE.
    address internal constant PENDLE = 0xA99F6e6785Da0F5d6fB42495Fe424BCE029Eeb3E;
    /// @dev Symbol PEPE.
    address internal constant PEPE = 0xB4fDe59a779991bfB6a52253B51947828b982be3;
    /// @dev Symbol GRT.
    address internal constant GRT = 0x0F4d237B09Cb37d207BA60353Dc254d4530D4dF1;
    /// @dev Symbol COMP.
    address internal constant COMP = 0x9e1028F5F1D5eDE59748FFceE5532509976840E0;
    /// @dev Symbol SNX.
    address internal constant SNX = 0x22e6966B799c4D5B13BE962E1D117b56327FDa66;
    /// @dev Symbol 1INCH.
    address internal constant ONEINCH = 0xc5fecC3a29Fb57B5024eEc8a2239d4621e111CBE;
    /// @dev Symbol RSR.
    address internal constant RSR = 0xaB36452DbAC151bE02b16Ca17d8919826072f64a;

    // ---------------------------------------------------------------------
    // Coinbase Wrapped coins, `Custodial`: Coinbase holds the coin and mints the token (the owner's call of
    // 2026-11-22, "add all coinbase wrapped tokens in base", which lifts the refusal of cbBTC of the day before).
    // Five are issued on Base, each a proxy Coinbase upgrades, with a blocklist and a pause. cbETH is Base's bridge's
    // copy of Ethereum's cbETH (`0xBe9895146f7AF43049ca1c1AE358B0541Ea49704`), Coinbase's staked ether, whose value
    // rises against ether while every balance stays as it was.
    // ---------------------------------------------------------------------
    /// @dev "Coinbase Wrapped BTC", symbol cbBTC, 8 decimals.
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    /// @dev "Coinbase Wrapped Staked ETH", symbol cbETH, 18 decimals.
    address internal constant CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    /// @dev "Coinbase Wrapped XRP", symbol cbXRP, 6 decimals.
    address internal constant CBXRP = 0xcb585250f852C6c6bf90434AB21A00f02833a4af;
    /// @dev "Coinbase Wrapped DOGE", symbol cbDOGE, 8 decimals.
    address internal constant CBDOGE = 0xcbD06E5A2B0C65597161de254AA074E489dEb510;
    /// @dev "Coinbase Wrapped LTC", symbol cbLTC, 8 decimals.
    address internal constant CBLTC = 0xcb17C9Db87B595717C857a08468793f5bAb6445F;
    /// @dev "Coinbase Wrapped ADA", symbol cbADA, 6 decimals.
    address internal constant CBADA = 0xcbADA732173e39521CDBE8bf59a6Dc85A9fc7b8c;

    // ---------------------------------------------------------------------
    // Coinbase's stock tokens, `Custodial` (the same call): one token is a claim on shares Coinbase's custodian
    // holds, times the token's `multiplier()`, which a dividend raises while every balance stays as it was. 8
    // decimals each. Each is a B20 token: a precompile of Base at a fixed address, whose only code is the byte
    // 0xef. An EVM without Base's precompiles cannot execute one, Foundry's before v1.8.4 among them, so the fork
    // suite drives these on Base's own node (`test/fork/BaseStocks.fork.t.sol`), and `CheckToken` does not read
    // them. The issuer's roles can block an address, pause, and seize a balance no policy exempts.
    // ---------------------------------------------------------------------
    /// @dev "NVIDIA Corporation", symbol NVDAc.
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    /// @dev Symbol METAc.
    address internal constant METAC = 0xb2000000000000000000008bC8786B856E61707C;
    /// @dev "Apple Inc.", symbol AAPLc.
    address internal constant AAPLC = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    /// @dev Symbol GOOGLc.
    address internal constant GOOGLC = 0xb2000000000000000000002D0BA3164cc74f58B7;
    /// @dev Symbol AMZNc.
    address internal constant AMZNC = 0xb200000000000000000000d9192b6B456483C2E8;
    /// @dev Symbol MSFTc.
    address internal constant MSFTC = 0xB200000000000000000000Ab99cFa739E253872B;
    /// @dev Symbol MSTRc.
    address internal constant MSTRC = 0xb2000000000000000000004884b426556b92883d;
    /// @dev Symbol SNDKc.
    address internal constant SNDKC = 0xb200000000000000000000397293Cb8cda9a10c5;
    /// @dev "Space Exploration Technologies Corp.", symbol SPCXc.
    address internal constant SPCXC = 0xb2000000000000000000007b9fcbd005511aCBd5;
    /// @dev "Tesla Inc.", symbol TSLAc.
    address internal constant TSLAC = 0xb2000000000000000000001e800a7f5189430cD0;

    // ---------------------------------------------------------------------
    // The mint currencies, never components: Circle's USDC, issued on Base, and the token that answers "Tether USD"
    // and USDT there, which is no copy of the standard bridge's (it names no bridge); who can mint it and replace
    // its code was not read on 2026-11-21, and is to be read before a deployment. Six decimals each, as on Ethereum.
    // ---------------------------------------------------------------------
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;

    // ---------------------------------------------------------------------
    // The bridge the copies above name, and its other half on Ethereum, which holds their backing.
    // ---------------------------------------------------------------------
    /// @dev Base's L2StandardBridge, a predeploy: what every listed copy answers to `bridge()`.
    address internal constant STANDARD_BRIDGE = 0x4200000000000000000000000000000000000010;
    /// @dev Base's L1StandardBridge, on Ethereum: `deposits(remote, copy)` is the backing it holds for a copy.
    address internal constant L1_STANDARD_BRIDGE = 0x3154Cf16ccdb4C6d922629664174b904d80F2C35;

    // ---------------------------------------------------------------------
    // Uniswap on Base, the zap's and the builder's one venue. Most of Base's depth sits on Aerodrome, which neither
    // the zap nor `CheckToken` reads. `DeployChecks` tells chain 8453 by its chain id: Ethereum's and BNB Chain's
    // router addresses both have code on Base, replays that settle against nothing here.
    // ---------------------------------------------------------------------
    /// @dev Uniswap's Universal Router on Base, which routes both V3 and V4 pools; answers {POOL_MANAGER}.
    address internal constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    /// @dev Uniswap V4's PoolManager on Base, which the zap reads off the router.
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    /// @dev Uniswap V3's factory on Base, where `CheckToken` looks up a token's Uniswap pools.
    address internal constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    /// @notice Every coin of the list: the two issued on Base, ZRO, the bridge's copies in the order Ethereum's list
    ///         holds their coins, the Coinbase Wrapped coins, then Coinbase's stocks.
    function all() internal pure returns (address[] memory tokens) {
        tokens = new address[](COUNT);
        tokens[0] = WETH;
        tokens[1] = AERO;
        tokens[2] = ZRO;
        tokens[3] = UNI;
        tokens[4] = AAVE;
        tokens[5] = MORPHO;
        tokens[6] = FET;
        tokens[7] = CRV;
        tokens[8] = VIRTUAL;
        tokens[9] = PENDLE;
        tokens[10] = PEPE;
        tokens[11] = GRT;
        tokens[12] = COMP;
        tokens[13] = SNX;
        tokens[14] = ONEINCH;
        tokens[15] = RSR;
        tokens[16] = CBBTC;
        tokens[17] = CBETH;
        tokens[18] = CBXRP;
        tokens[19] = CBDOGE;
        tokens[20] = CBLTC;
        tokens[21] = CBADA;
        address[STOCKS] memory stockTokens = stocks();
        for (uint256 i = 0; i < STOCKS; ++i) {
            tokens[BRIDGED + 3 + CB_COINS + i] = stockTokens[i];
        }
    }

    /// @notice Coinbase's ten stock tokens, the B20 precompiles no EVM without Base's own can execute.
    function stocks() internal pure returns (address[STOCKS] memory) {
        return [NVDAC, METAC, AAPLC, GOOGLC, AMZNC, MSFTC, MSTRC, SNDKC, SPCXC, TSLAC];
    }

    /// @notice Whether `token` is one of Coinbase's stock tokens.
    function isStock(address token) internal pure returns (bool) {
        address[STOCKS] memory stockTokens = stocks();
        for (uint256 i = 0; i < STOCKS; ++i) {
            if (token == stockTokens[i]) return true;
        }
        return false;
    }

    /// @notice Whether `token` is one of the Coinbase Wrapped coins.
    function isCoinbaseWrapped(address token) internal pure returns (bool) {
        return token == CBBTC || token == CBETH || token == CBXRP || token == CBDOGE || token == CBLTC || token == CBADA;
    }

    /// @notice The tier of a token in the list, as `Listings.tierOf` gives Ethereum's: `Native` for WETH and AERO,
    ///         `Bridged` for ZRO and every copy the bridge mints of a coin on Ethereum's list, `Custodial` for every
    ///         coin and stock Coinbase issues, cbETH among them though the bridge mints it, and `Unrecorded` for any
    ///         token off the list.
    function tierOf(address token) internal pure returns (Listings.Tier) {
        if (token == WETH || token == AERO) return Listings.Tier.Native;
        if (token == ZRO || remoteOf(token) != address(0)) return Listings.Tier.Bridged;
        if (isCoinbaseWrapped(token) || isStock(token)) return Listings.Tier.Custodial;
        return Listings.Tier.Unrecorded;
    }

    /// @notice The Ethereum token a listed copy of the bridge's names (`remoteToken()`), from `MainnetAddresses`;
    ///         zero for a token the bridge does not mint, the two issued on Base and ZRO among them.
    function remoteOf(address token) internal pure returns (address) {
        (address[BRIDGED] memory copies, address[BRIDGED] memory remotes) = bridged();
        for (uint256 i = 0; i < copies.length; ++i) {
            if (token == copies[i]) return remotes[i];
        }
        return address(0);
    }

    /// @notice The thirteen copies the bridge mints, each with the Ethereum token it names, in the list's order.
    function bridged() internal pure returns (address[BRIDGED] memory copies, address[BRIDGED] memory remotes) {
        copies = [UNI, AAVE, MORPHO, FET, CRV, VIRTUAL, PENDLE, PEPE, GRT, COMP, SNX, ONEINCH, RSR];
        remotes = [
            MainnetAddresses.UNI,
            MainnetAddresses.AAVE,
            MainnetAddresses.MORPHO,
            MainnetAddresses.FET,
            MainnetAddresses.CRV,
            MainnetAddresses.VIRTUAL,
            MainnetAddresses.PENDLE,
            MainnetAddresses.PEPE,
            MainnetAddresses.GRT,
            MainnetAddresses.COMP,
            MainnetAddresses.SNX,
            MainnetAddresses.ONEINCH,
            MainnetAddresses.RSR
        ];
    }
}
