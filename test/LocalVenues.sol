// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";

/// @title LocalVenues
/// @notice The chain's own DEX a test builds the zap or the builder with.
library LocalVenues {
    /// @notice No DEX beside Uniswap, as on Ethereum.
    function none() internal pure returns (IUniversalRouterSwaps.LocalVenue memory) {
        return IUniversalRouterSwaps.LocalVenue({
            dex: IUniversalRouterSwaps.LocalDex.None,
            router: address(0),
            clFactory: address(0),
            volatileFactory: address(0),
            stableFactory: address(0)
        });
    }

    /// @notice PancakeSwap's router.
    function pancake(address router) internal pure returns (IUniversalRouterSwaps.LocalVenue memory) {
        return IUniversalRouterSwaps.LocalVenue({
            dex: IUniversalRouterSwaps.LocalDex.PancakeSwap,
            router: router,
            clFactory: address(0),
            volatileFactory: address(0),
            stableFactory: address(0)
        });
    }

    /// @notice Aero's Metarouter and its three factories.
    function aero(address router, address clFactory, address volatileFactory, address stableFactory)
        internal
        pure
        returns (IUniversalRouterSwaps.LocalVenue memory)
    {
        return IUniversalRouterSwaps.LocalVenue({
            dex: IUniversalRouterSwaps.LocalDex.Aero,
            router: router,
            clFactory: clFactory,
            volatileFactory: volatileFactory,
            stableFactory: stableFactory
        });
    }
}
