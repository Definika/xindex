// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Listings} from "./Listings.sol";

/// @notice The BNB Chain contracts the deploy and listing scripts use for the BNB Chain deployment
///         (`design/2026-11-13-bnb-chain-deployment.md`): the tokens its indexes may hold, each with its trust tier,
///         the mint currencies and Uniswap's contracts there. This is the only copy: `DeployChecks`,
///         `ConfigureWeighted` and `CheckToken` read it on chain 56, and `test/fork/BnbChainAddresses.fork.t.sol`
///         checks it on chain (tokens by symbol and decimals, the router, the PoolManager and the V3 factory by their
///         runtime code). No coin carries a price feed: an index rebalances on units alone
///         (`design/2026-11-10-oracle-free-rebalance.md`). Every address here was read on chain 56 on 2026-11-13.
/// @dev The list is the BNB Chain list of 2026-10-07, deleted on 2026-10-13 and restored on 2026-11-13 (the owner's
///      call), less what the owner's later rulings exclude:
///      - DOGE (0xbA2aE424d960c26247Dd6c32edC70B295c744C43), AVAX (0x1CE0c2827e2eF14D5C4f29a091d735A204794041) and
///        FIL (0x0D8Ce2A99Bb6e3B7Db580eD848240e4a0F9aE153): each is a proxy whose admin, one externally owned key
///        (0xD2f93484f2D319194cBa95C5171B18C1d8cfD6C4), can replace its code. That is the reason DOGE left the
///        Ethereum list on 2026-10-14 and FIL is held (RX-64); the read of 2026-11-13 found the same admin on all
///        three.
///      - TRX (0xCE7de646e7208a4Ef112cb6ed5038FA6cC6b12e3): TRON closed its BTTC bridge on 2026-06-18, the reason
///        BTT left the Ethereum list (RX-28).
///      - Binance-Peg SOL (0x570A5D26f7765Ecb712C0924E4De545B89fD43dF): SOL is held on Ethereum as Wormhole's copy
///        (the owner's call of 2026-10-10).
///      - NIGHT (0xFe930c2d63AeD9b82fC4DBC801920dD2c1a3224F) is refused (the owner's call of 2026-10-06).
library BnbChainAddresses {
    /// @notice BNB Chain's chain id.
    uint256 internal constant CHAIN_ID = 56;
    /// @notice How many coins the list names.
    uint256 internal constant COUNT = 12;

    // ---------------------------------------------------------------------
    // BNB Chain's own coin, wrapped as WETH wraps ether, and the two majors as Binance holds them: BTCB and "ETH" are
    // Binance-Peg tokens, `Custodial`, 18 decimals each.
    // ---------------------------------------------------------------------
    /// @dev "Wrapped BNB", symbol WBNB, 18 decimals: the WETH9 wrapper, `Native`. The zap's wrapped coin here, which
    ///      its ether entry points wrap and unwrap as they do WETH on Ethereum.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev "BTCB Token", symbol BTCB, 18 decimals: Binance's bitcoin, as WBTC is BitGo's.
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    /// @dev "Ethereum Token", symbol ETH, 18 decimals: Binance-Peg ether.
    address internal constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // ---------------------------------------------------------------------
    // Binance-Peg tokens: custodial copies Binance mints with a single key (0xF68a4b64162906efF0fF6aE34E2bB1Cd42FEf62d,
    // each one's `owner()`), the trust tier `Custodial`. None of these seven is a proxy: no key can replace its code.
    // 18 decimals each.
    // ---------------------------------------------------------------------
    address internal constant XRP = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;
    address internal constant ZEC = 0x1Ba42e5193dfA8B03D15dd1B86a3113bbBEF8Eeb;
    address internal constant ADA = 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47;
    address internal constant BCH = 0x8fF795a6F4D97E7887C79beA79aba5cc76444aDf;
    address internal constant LTC = 0x4338665CBB7B2485A8855A139b75D5e34AB0DB94;
    address internal constant DOT = 0x7083609fCE4d1d8Dc0C979AAb8c869Ea2C873402;
    address internal constant ATOM = 0x0Eb3a705fc54725037CC9e008bDede697f62F335;

    // ---------------------------------------------------------------------
    // Tokens issued for BNB Chain: ASTER, `Native`, with a fixed supply and no admin power found; STABLE, `Bridged`,
    // a LayerZero OFT behind a proxy whose admin contract (0x386f92606b2D5E0A992ECc3704c31eF39Ff56392) answers to a
    // 3-of-5 Safe (0x2548B8D0FD9277cD4f4b78c79172caEfc46Fd2E6), which sets its peers and upgrades it.
    // ---------------------------------------------------------------------
    address internal constant ASTER = 0x000Ae314E2A2172a039B26378814C252734f556A;
    address internal constant STABLE = 0x011EBe7d75E2C9D1E0bD0be0bEf5C36f0A90075F;

    // ---------------------------------------------------------------------
    // Mint and burn currencies, 18 decimals each on BNB Chain ("Tether USD" and "USD Coin", Binance-Peg). Never
    // components; see the whitelist policy. Nothing in the zap or `MintRequests` assumes a currency's decimals.
    // Binance-Peg USDC is a proxy under the key that holds DOGE's (above): that key can replace its code, which
    // reaches what `MintRequests` holds in USDC escrows and nothing an index holds. USDT is no proxy.
    // ---------------------------------------------------------------------
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    // ---------------------------------------------------------------------
    // Execution. The router is the same build as the Ethereum one the zap is pinned to, byte for byte but for its
    // immutables (compared on 2026-10-07), so the command inputs the zap encodes hold here. The runtime code hashes
    // are pinned by `test/fork/BnbChainAddresses.fork.t.sol`.
    //
    // Ethereum's router address, `MainnetAddresses.UNIVERSAL_ROUTER`, has code on BNB Chain too: a byte-identical
    // replay of Ethereum's deployment, wired to Ethereum's PoolManager address and so to no market here. It is not
    // this book's router. Both routers are CREATE2 deployments anyone can replay onto the other chain, so
    // `DeployChecks` tells chains 1 and 56 by their chain id, and reads a router's code only under any other id.
    // ---------------------------------------------------------------------
    /// @dev Uniswap Universal Router 2.0.0 on BNB Chain, which routes both V3 and V4 pools; answers {POOL_MANAGER}.
    address internal constant UNIVERSAL_ROUTER = 0x1906c1d672b88cD1B9aC7593301cA990F94Eae07;
    /// @dev Uniswap V4's PoolManager on BNB Chain, which the zap reads off the router.
    address internal constant POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    /// @dev Uniswap V3's factory on BNB Chain, where `CheckToken` looks up a token's Uniswap pools. Most BNB Chain
    ///      depth sits on PancakeSwap, which neither the zap nor `CheckToken` reads, so the depth recorded here is
    ///      what the zap can reach and not the coin's market.
    address internal constant UNISWAP_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;

    /// @notice Every coin of the list: WBNB, BTCB and ETH first, then the Binance-Peg coins, then BNB Chain's own
    ///         tokens.
    function all() internal pure returns (address[] memory tokens) {
        tokens = new address[](COUNT);
        tokens[0] = WBNB;
        tokens[1] = BTCB;
        tokens[2] = ETH;
        tokens[3] = XRP;
        tokens[4] = ZEC;
        tokens[5] = ADA;
        tokens[6] = BCH;
        tokens[7] = LTC;
        tokens[8] = DOT;
        tokens[9] = ATOM;
        tokens[10] = ASTER;
        tokens[11] = STABLE;
    }

    /// @notice The tier of a token in the list, as `Listings.tierOf` gives Ethereum's: `Custodial` for every
    ///         Binance-Peg token, BTCB and ETH among them; `Bridged` for STABLE; `Native` for WBNB and ASTER;
    ///         `Unrecorded` for any token off the list.
    function tierOf(address token) internal pure returns (Listings.Tier) {
        if (token == WBNB || token == ASTER) return Listings.Tier.Native;
        if (token == STABLE) return Listings.Tier.Bridged;
        if (
            token == BTCB || token == ETH || token == XRP || token == ZEC || token == ADA || token == BCH
                || token == LTC || token == DOT || token == ATOM
        ) return Listings.Tier.Custodial;
        return Listings.Tier.Unrecorded;
    }
}
