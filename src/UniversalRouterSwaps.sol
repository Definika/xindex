// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {IUniversalRouterSwaps} from "./interfaces/IUniversalRouterSwaps.sol";
import {PathLib} from "./libraries/PathLib.sol";
import {UniversalRouterCommands as Cmd} from "./libraries/UniversalRouterCommands.sol";
import {PathKey, UniswapV4Types as V4, V4ExactInputParams, V4ExactOutputParams} from "./libraries/UniswapV4Types.sol";

/// @title UniversalRouterSwaps
/// @notice The swap engine shared by `IndexZap` and `BasketBuilder`, through Uniswap's Universal Router (V3 or V4 per
///         leg). A mint buys each component with an exact-output swap. A burn sells each with an exact-input swap.
/// @dev Design notes
///      - Venue: each leg names V3 or V4. Depth favours V3 for some components and V4 for others, so the app chooses
///        per leg.
///      - Commands: the engine builds every router command itself and forwards nothing a caller supplied. The router
///        can also sweep and do Permit2 transfers, so passing calldata through would hand a caller its permissions.
///      - Payment: nothing is approved to the router, and Permit2 is never used. A leg pre-funds the router with
///        exactly what it may spend, swaps, and sweeps the rest back in the same `execute`.
///      - Spend bound: the sweep's minimum is zero, so the sweep never fails (CR-I14). The pre-fund is what bounds a
///        leg, since the router can only pay out what it holds. It is the real bound, not a backstop: the pinned V4
///        router checks `amountInMaximum` only on the last hop, so a route passing back through `tokenIn` could
///        spend more (upstream v4-periphery #564, CR-I06). Never approve the router or pre-fund more than a leg's cap.
///      - Buys: an exact-output swap delivers exactly what the basket needs; the only leftover is `tokenIn`. The
///        pinned V4 router does not check exact-output delivery, so the engine measures each leg's component balance
///        and reverts `ShortFill` if short.
///      - Routes: every route must start at the component and end at the user's token, so funds cannot end up in a
///        third token. A V4 route must be hookless: a hook is arbitrary code that runs inside the swap and can move
///        the deltas. Hookless also rules out a dynamic fee, which only a hooked pool can carry.
///      - Measuring: what a swap took and produced is measured as balance changes, never from router reports. The
///        sweep also returns any balance the router already held. On a buy that enlarges the refund; on a sale it is
///        returned with the unsold input. Neither is a shortfall. So a sale hop measures what the sweep brought back,
///        not what the swap sold. Do not measure what was sold: a donation to the router larger than the sale would
///        underflow, and anyone could revert a public burn (CR-L02).
///      - V3 sales go one hop at a time, because a V3 pool can stop at its price limit, and a multi-hop call would
///        leave the unsold middle token in the router.
///      - A V4 sale is one swap. If a middle hop fills short, the pool manager is left unsettled and the whole leg
///        reverts. The exception is a hop whose input is the component or `tokenOut` again: its leftover nets into
///        the settle or the take (CR-I07). So, on a route that never revisits them, only the first hop can leave
///        unsold input.
///      - Native ether never reaches the engine, which cannot receive it: the take only ever takes the leg's far end,
///        the component on a buy and `tokenOut` on a sale, neither of which may be native ether (RX-53).
///      - What a hop did not sell goes to {_onUnsold}. The zap pays it to the burn's recipient; the builder credits it
///        to the user's escrow. Unsold `tokenOut` stays with the proceeds.
abstract contract UniversalRouterSwaps is IUniversalRouterSwaps {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    /// @inheritdoc IUniversalRouterSwaps
    IUniversalRouter public immutable ROUTER;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable POOL_MANAGER;

    /// @dev The sweep returns whatever the router did not spend, and accepts any amount, including none. The leg's
    ///      pre-fund already bounds its spend, and delivery is checked separately.
    uint256 private constant SWEEP_NO_MINIMUM = 0;
    /// @dev Every V4 leg is the same three actions: swap, settle what it owes, take what it produced.
    uint256 private constant V4_ACTIONS = 3;

    constructor(IUniversalRouter router) {
        if (address(router) == address(0)) revert ZeroAddress();
        ROUTER = router;
        // Read from the router rather than passed in, so the two can never be wired to different deployments.
        POOL_MANAGER = router.poolManager();
    }

    // ---------------------------------------------------------------------
    // Buying
    // ---------------------------------------------------------------------

    /// @dev Buys exactly `amountOut` of `component` with `tokenIn`, paying at most `cap`, and returns what it cost.
    ///      The router is pre-funded with `cap` and swept clean in the same call. So it never keeps anything, and never
    ///      holds an allowance from here.
    ///      `amountOut` is never zero. This matters: for the V4 router, zero in the amount position means "the full
    ///      debt" (open delta). A basket's amounts are `ceil(gross * units * scale / 1e36)` with non-zero shares, and
    ///      units are always at least one raw unit: they start at MIN_RAW_UNITS or more, a rebalance rounds new units
    ///      up, and the scale never reaches zero (CR-I05).
    /// @param i The leg's position, named by the errors.
    function _buy(address tokenIn, address component, uint256 amountOut, uint256 cap, MintLeg calldata leg, uint256 i)
        internal
        returns (uint256 amountIn)
    {
        bool isV4 = _checkRoute(leg.v3Path, leg.v4Path, component, tokenIn, true, i);

        IERC20 token = IERC20(tokenIn);
        uint256 inBefore = token.balanceOf(address(this));
        uint256 outBefore = IERC20(component).balanceOf(address(this));
        token.safeTransfer(address(ROUTER), cap);

        bytes memory commands;
        bytes[] memory inputs = new bytes[](2);
        if (isV4) {
            commands = abi.encodePacked(Cmd.V4_SWAP, Cmd.SWEEP);
            bytes[] memory params = new bytes[](V4_ACTIONS);
            params[0] = abi.encode(
                V4ExactOutputParams({
                    currencyOut: component,
                    path: leg.v4Path,
                    amountOut: SafeCast.toUint128(amountOut),
                    amountInMaximum: SafeCast.toUint128(cap)
                })
            );
            params[1] = abi.encode(tokenIn, V4.OPEN_DELTA, false);
            params[2] = abi.encode(component, address(this), V4.OPEN_DELTA);
            inputs[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_OUT, V4.SETTLE, V4.TAKE), params);
        } else {
            commands = abi.encodePacked(Cmd.V3_SWAP_EXACT_OUT, Cmd.SWEEP);
            inputs[0] = abi.encode(address(this), amountOut, cap, leg.v3Path, false);
        }
        inputs[1] = abi.encode(tokenIn, address(this), SWEEP_NO_MINIMUM);
        // Safe: every entry point of the zap and the builder is nonReentrant, which the lint does not model. The
        // builder credits its escrow only from what it measures after the router returns.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        ROUTER.execute(commands, inputs);

        // The router reports nothing, so both sides are measured here. The pinned V4 router does not check exact-output
        // delivery; without this check, a short fill would surface as an opaque failure inside issue().
        uint256 delivered = IERC20(component).balanceOf(address(this)) - outBefore;
        if (delivered < amountOut) revert ShortFill(i, delivered, amountOut);
        amountIn = Math.saturatingSub(inBefore, token.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------
    // Selling
    // ---------------------------------------------------------------------

    /// @dev Sells `amountIn` of `component` into `tokenOut` along the leg's route.
    ///      - The route must be valid even when there is nothing to sell.
    ///      - The proceeds stay here; the caller measures them as its `tokenOut` balance change.
    ///      - What a hop did not sell goes to {_onUnsold}, with `ctx`.
    ///      - A leg with nothing to sell but a non-zero minimum reverts InsufficientOutput.
    function _sell(
        address tokenOut,
        address component,
        uint256 amountIn,
        BurnLeg calldata leg,
        uint256 i,
        bytes memory ctx
    ) internal {
        bool isV4 = _checkRoute(leg.v3Path, leg.v4Path, component, tokenOut, false, i);
        if (amountIn == 0) {
            if (leg.minAmountOut != 0) revert InsufficientOutput(0, leg.minAmountOut);
            return;
        }
        if (isV4) _sellV4(tokenOut, component, amountIn, leg.v4Path, leg.minAmountOut, ctx);
        else _sellV3(tokenOut, component, amountIn, leg.v3Path, leg.minAmountOut, ctx);
    }

    /// @dev Sells `amountIn` of `component` along the leg's V3 path, one hop at a time. A V3 pool can stop at its price
    ///      limit and take less than a hop's input, and a multi-hop call would hide that after the first hop. So each
    ///      hop is swapped alone, and its unsold input is measured and returned. The leg's minimum applies to the last
    ///      hop's output; the caller's overall minimum bounds the whole sale.
    function _sellV3(
        address tokenOut,
        address component,
        uint256 amountIn,
        bytes calldata path,
        uint256 minAmountOut,
        bytes memory ctx
    ) private {
        address hopIn = component;
        uint256 given = amountIn;
        while (true) {
            bool last = path.length == PathLib.ADDR_SIZE + PathLib.HOP_SIZE;
            address hopOut = address(bytes20(path[PathLib.HOP_SIZE:PathLib.HOP_SIZE + PathLib.ADDR_SIZE]));
            uint256 produced = _sellV3Hop(
                tokenOut,
                path[:PathLib.ADDR_SIZE + PathLib.HOP_SIZE],
                hopIn,
                hopOut,
                given,
                last ? minAmountOut : 0,
                ctx
            );
            if (last) return;
            // A hop that produced nothing has nothing to hand the next one, and the leg cannot complete.
            if (produced == 0) revert InsufficientOutput(0, minAmountOut);
            (hopIn, given) = (hopOut, produced);
            path = path[PathLib.HOP_SIZE:];
        }
    }

    /// @dev One V3 hop: pre-fund the router, swap, sweep it clean, and return what arrived. The unsold input goes to
    ///      {_onUnsold}, not left where anyone could sweep it. It is measured as what the sweep brought back: the
    ///      balance above what remained after the pre-fund. The sweep only adds to that, so it cannot underflow,
    ///      whatever the router held before (CR-L02).
    function _sellV3Hop(
        address tokenOut,
        bytes calldata hopPath,
        address hopIn,
        address hopOut,
        uint256 given,
        uint256 minOut,
        bytes memory ctx
    ) private returns (uint256 produced) {
        IERC20 token = IERC20(hopIn);
        uint256 inBefore = token.balanceOf(address(this));
        uint256 outBefore = IERC20(hopOut).balanceOf(address(this));
        token.safeTransfer(address(ROUTER), given);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(this), given, minOut, hopPath, false);
        inputs[1] = abi.encode(hopIn, address(this), SWEEP_NO_MINIMUM);
        ROUTER.execute(abi.encodePacked(Cmd.V3_SWAP_EXACT_IN, Cmd.SWEEP), inputs);

        produced = IERC20(hopOut).balanceOf(address(this)) - outBefore;
        _returnUnsold(tokenOut, hopIn, token.balanceOf(address(this)) + given - inBefore, ctx);
    }

    /// @dev Sells `amountIn` of `component` along the leg's V4 route as one swap.
    ///      Every middle currency, native ether included, nets inside the pool manager. If a middle hop fills short,
    ///      the pool manager refuses to close, so the whole leg reverts instead of stranding a middle token here.
    ///      Unsold input can come from the first hop, or from a later hop whose input is the component again, since
    ///      its leftover nets against the leg's own debt (CR-I07). The sweep returns both, measured as in
    ///      `_sellV3Hop` (CR-L02).
    function _sellV4(
        address tokenOut,
        address component,
        uint256 amountIn,
        PathKey[] calldata v4Path,
        uint256 minAmountOut,
        bytes memory ctx
    ) private {
        IERC20 token = IERC20(component);
        uint256 inBefore = token.balanceOf(address(this));
        token.safeTransfer(address(ROUTER), amountIn);

        bytes[] memory params = new bytes[](V4_ACTIONS);
        params[0] = abi.encode(
            V4ExactInputParams({
                currencyIn: component,
                path: v4Path,
                amountIn: SafeCast.toUint128(amountIn),
                amountOutMinimum: SafeCast.toUint128(minAmountOut)
            })
        );
        params[1] = abi.encode(component, V4.OPEN_DELTA, false);
        params[2] = abi.encode(tokenOut, address(this), V4.OPEN_DELTA);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), params);
        inputs[1] = abi.encode(component, address(this), SWEEP_NO_MINIMUM);
        ROUTER.execute(abi.encodePacked(Cmd.V4_SWAP, Cmd.SWEEP), inputs);

        _returnUnsold(tokenOut, component, token.balanceOf(address(this)) + amountIn - inBefore, ctx);
    }

    /// @dev Hands what a hop did not sell (plus any balance of it the router already held) to {_onUnsold}.
    ///      Unsold `tokenOut` stays here. It is counted in the caller's `tokenOut` balance change and reaches the
    ///      recipient with the proceeds, so it is not paid out twice.
    function _returnUnsold(address tokenOut, address token, uint256 unsold, bytes memory ctx) private {
        if (unsold == 0 || token == tokenOut) return;
        _onUnsold(token, unsold, ctx);
    }

    /// @dev Hook for `amount` of `token` that a sale hop did not sell. The tokens are already in this contract's
    ///      balance. `ctx` is what the sale was called with.
    function _onUnsold(address token, uint256 amount, bytes memory ctx) internal virtual;

    // ---------------------------------------------------------------------
    // Routes
    // ---------------------------------------------------------------------

    /// @dev Checks that a leg names exactly one venue, and that its route runs from the component to the user's token.
    ///      On a V4 route, the `component` end is the engine's own argument, not the caller's, so only the far end is
    ///      checked. Which entry that is depends on direction: the router walks an exact-input route from the front,
    ///      and an exact-output route from the back.
    /// @param exactOut True for a buy, whose route the router walks backwards.
    /// @return isV4 Whether the leg named a V4 route.
    function _checkRoute(
        bytes calldata v3Path,
        PathKey[] calldata v4Path,
        address component,
        address userToken,
        bool exactOut,
        uint256 i
    ) internal pure returns (bool isV4) {
        isV4 = v4Path.length != 0;
        if (isV4 == (v3Path.length != 0)) revert BadRoute(i); // both, or neither
        if (!isV4) {
            if (!v3Path.isValidShape() || v3Path.firstToken() != component || v3Path.lastToken() != userToken) {
                revert BadRoute(i);
            }
            return false;
        }
        // A hook is arbitrary code running inside the swap, able to move the deltas the engine measures. A hookless
        // key cannot carry a dynamic fee either, so this one check covers both. Native ether may be a middle currency
        // but never an endpoint; the far-end check below ensures that.
        for (uint256 h = 0; h < v4Path.length; ++h) {
            if (v4Path[h].hooks != address(0) || v4Path[h].hookData.length != 0) revert BadRoute(i);
        }
        uint256 far = exactOut ? 0 : v4Path.length - 1;
        if (v4Path[far].intermediateCurrency != userToken) revert BadRoute(i);
    }
}
