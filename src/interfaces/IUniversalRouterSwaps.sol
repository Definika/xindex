// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniversalRouter} from "./IUniversalRouter.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {PathKey} from "../libraries/UniswapV4Types.sol";

/// @title IUniversalRouterSwaps
/// @notice What every contract built on the shared swap engine exposes: the leg formats, the router it swaps through,
///         and the V4 singleton that router settles against. `IIndexZap` and `IBasketBuilder` extend it, so the app
///         encodes a leg the same way for both.
interface IUniversalRouterSwaps is IXindexErrors {
    /// @param v3Path Exact-output Uniswap V3 path from the component back to `tokenIn`. Empty for a V4 leg, and for
    ///        the pass-through leg whose component is `tokenIn` itself.
    /// @param v4Path Uniswap V4 route. Its first entry names `tokenIn`, because an exact-output route is walked from
    ///        the component backwards. Empty for a V3 leg and for the pass-through leg. Native ether may be a middle
    ///        currency but never an endpoint. Every hop must be hookless.
    /// @param maxAmountIn Most `tokenIn` this leg may spend, or 0 for the overall limit only.
    struct MintLeg {
        bytes v3Path;
        PathKey[] v4Path;
        uint256 maxAmountIn;
    }

    /// @param v3Path Exact-input Uniswap V3 path from the component to `tokenOut`. Empty for a V4 leg, and for the
    ///        pass-through leg whose component is `tokenOut` itself. Checked even when the component redeems to zero.
    ///        Each hop is swapped alone, so the unsold input of any hop comes back: to the burn's `to` from the zap, to
    ///        the seller's escrow in the builder. A middle hop that sells nothing reverts with InsufficientOutput.
    /// @param v4Path Uniswap V4 route. Its last entry names `tokenOut`. Empty for a V3 leg and for the pass-through
    ///        leg. The whole route is one swap: a middle hop that fills short reverts the leg. The exception is a hop
    ///        whose input is the component or `tokenOut` again. A leftover component nets against the leg's debt and
    ///        comes back as a V3 hop's does; a leftover `tokenOut` is paid out. On a route that revisits neither, only
    ///        the first hop can leave unsold input, which comes back the same way (RX-53).
    /// @param minAmountOut Least `tokenOut` this leg must return, or 0 for the overall limit only. It applies to the
    ///        leg's final output. It reverts when non-zero on a leg whose redeemed amount rounds to zero. A middle V3
    ///        hop that produces nothing reverts too, whatever the minimum (RT-11).
    struct BurnLeg {
        bytes v3Path;
        PathKey[] v4Path;
        uint256 minAmountOut;
    }

    /// @notice Uniswap's Universal Router, through which every swap runs.
    function ROUTER() external view returns (IUniversalRouter);

    /// @notice The Uniswap V4 singleton the router settles V4 legs against, read from the router at construction. It
    ///         is never a valid recipient: anything sent there is a donation to the protocol.
    function POOL_MANAGER() external view returns (address);
}
