// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniversalRouter} from "./IUniversalRouter.sol";
import {IXindexErrors} from "./IXindexErrors.sol";
import {PathKey} from "../libraries/UniswapV4Types.sol";

/// @title IUniversalRouterSwaps
/// @notice What every contract built on the shared swap engine exposes: the leg formats, the routers it swaps through,
///         and the V4 singleton Uniswap's router settles against. `IIndexZap` and `IBasketBuilder` extend it, so the
///         app encodes a leg the same way for both.
/// @dev A leg names one venue: Uniswap V3 (`v3Path`), Uniswap V4 (`v4Path`), or the chain's own DEX (`localRoute`),
///      which the deployment fixes ({LOCAL_DEX}): PancakeSwap on BNB Chain, Aero on Base, none on Ethereum. A
///      `localRoute` is one byte naming the pool family, `0` for concentrated liquidity and `1` for constant-function
///      pools, followed by a path of Uniswap V3's shape, `token (20) | uint24 (3) | token (20) | ...`, in the leg's
///      direction. The three bytes are, per DEX and family:
///      - PancakeSwap, concentrated: the V3 pool's fee tier (100, 500, 2,500 or 10,000).
///      - PancakeSwap, constant-function: zero, for its V2 pair.
///      - Aero, concentrated: the CL pool's tick spacing.
///      - Aero, constant-function: zero for the volatile basic pool, one for the stable one.
///      A route names tokens, never pools: PancakeSwap's router computes its pools, and the engine looks Aero's up in
///      the factories the deployment pins.
interface IUniversalRouterSwaps is IXindexErrors {
    /// @notice The chain's own DEX was named with addresses that do not fit it: a router for none, none for one, Aero's
    ///         factories for any other DEX or missing for Aero, or Uniswap's router named again.
    error InvalidLocalVenue();

    /// @notice The DEX a deployment adds beside Uniswap.
    enum LocalDex {
        None,
        PancakeSwap,
        Aero
    }

    /// @notice The chain's own DEX, fixed at construction.
    /// @param dex Which DEX, or None.
    /// @param router PancakeSwap's Universal Router, or Aero's Metarouter. Zero for None.
    /// @param clFactory Aero's concentrated-liquidity pool factory. Zero for any other DEX.
    /// @param volatileFactory Aero's volatile basic-pool factory. Zero for any other DEX.
    /// @param stableFactory Aero's stable basic-pool factory. Zero for any other DEX.
    struct LocalVenue {
        LocalDex dex;
        address router;
        address clFactory;
        address volatileFactory;
        address stableFactory;
    }

    /// @param v3Path Exact-output Uniswap V3 path from the component back to `tokenIn`. Empty for any other venue, and
    ///        for the pass-through leg whose component is `tokenIn` itself.
    /// @param v4Path Uniswap V4 route. Its first entry names `tokenIn`, because an exact-output route is walked from
    ///        the component backwards. Empty for any other venue and for the pass-through leg. Native ether may be a
    ///        middle currency but never an endpoint. Every hop must be hookless.
    /// @param localRoute Route through the chain's own DEX, from the component back to `tokenIn` (see the interface's
    ///        notes). Empty for any other venue, for the pass-through leg, and always on a deployment without one.
    /// @param maxAmountIn Most `tokenIn` this leg may spend, or 0 for the overall limit only.
    struct MintLeg {
        bytes v3Path;
        PathKey[] v4Path;
        bytes localRoute;
        uint256 maxAmountIn;
    }

    /// @param v3Path Exact-input Uniswap V3 path from the component to `tokenOut`. Empty for any other venue, and for
    ///        the pass-through leg whose component is `tokenOut` itself. Checked even when the component redeems to
    ///        zero. Each hop is swapped alone, so the unsold input of any hop comes back: to the burn's `to` from the
    ///        zap, to the seller's escrow in the builder. A middle hop that sells nothing reverts with
    ///        InsufficientOutput.
    /// @param v4Path Uniswap V4 route. Its last entry names `tokenOut`. Empty for any other venue and for the
    ///        pass-through leg. The whole route is one swap: a middle hop that fills short reverts the leg. The
    ///        exception is a hop whose input is the component or `tokenOut` again. A leftover component nets against
    ///        the leg's debt and comes back as a V3 hop's does; a leftover `tokenOut` is paid out. On a route that
    ///        revisits neither, only the first hop can leave unsold input, which comes back the same way (RX-53).
    /// @param localRoute Route through the chain's own DEX, from the component to `tokenOut`. Empty for any other
    ///        venue and for the pass-through leg. Swapped one hop at a time, as a V3 path is, with the same returns.
    /// @param minAmountOut Least `tokenOut` this leg must return, or 0 for the overall limit only. It applies to the
    ///        leg's final output. It reverts when non-zero on a leg whose redeemed amount rounds to zero. A middle hop
    ///        that produces nothing reverts too, whatever the minimum (RT-11).
    struct BurnLeg {
        bytes v3Path;
        PathKey[] v4Path;
        bytes localRoute;
        uint256 minAmountOut;
    }

    /// @notice Uniswap's Universal Router, through which every Uniswap swap runs.
    function ROUTER() external view returns (IUniversalRouter);

    /// @notice The Uniswap V4 singleton the router settles V4 legs against, read from the router at construction. It
    ///         is never a valid recipient: anything sent there is a donation to the protocol.
    function POOL_MANAGER() external view returns (address);

    /// @notice The chain's own DEX, or None.
    function LOCAL_DEX() external view returns (LocalDex);

    /// @notice The chain's own DEX's router: PancakeSwap's Universal Router or Aero's Metarouter, or zero. Never a
    ///         valid recipient: anyone can sweep what it holds.
    function LOCAL_ROUTER() external view returns (address);

    /// @notice Aero's concentrated-liquidity pool factory, or zero on any other DEX.
    function AERO_CL_FACTORY() external view returns (address);

    /// @notice Aero's volatile basic-pool factory, or zero on any other DEX.
    function AERO_VOLATILE_FACTORY() external view returns (address);

    /// @notice Aero's stable basic-pool factory, or zero on any other DEX.
    function AERO_STABLE_FACTORY() external view returns (address);
}
