// SPDX-License-Identifier: MIT
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
/// @notice The swap engine `IndexZap` and `BasketBuilder` share: an exact-output buy of a component for a mint and an
///         exact-input sale of a component for a burn, through Uniswap's Universal Router, V3 or V4 per leg. It was the
///         zap's own private functions until 2026-10-16; the zap's design notes below are its.
/// @dev Design notes
///      - Each leg names its venue. Depth still favours V3 for some components and V4 for others, so the app chooses
///        per leg and the engine builds the router commands for whichever it finds.
///      - The engine builds every command itself and forwards nothing a caller supplied. The router's command set
///        includes sweeps and Permit2 transfers, so passing calldata through would hand a caller its permissions.
///      - Nothing is approved to the router and Permit2 is never used. A leg pre-funds the router with exactly what it
///        may spend, swaps with the router paying from its own balance, and sweeps the remainder back in the same
///        `execute`. The sweep's minimum is zero, so it checks nothing and can never come up short (CR-I14). What bounds
///        a leg is the pre-fund, since the router can pay out only what it holds, and what checks it is the caller's
///        own balance measurement plus `ShortFill` on a buy. The pre-fund is the operative bound, not a backstop: the
///        pinned V4 router checks `amountInMaximum` against the last hop it executed only, so an exact-output route
///        that passes back through `tokenIn` could otherwise spend past it (upstream v4-periphery #564, CR-I06). Never
///        approve the router or pre-fund more than a leg's cap.
///      - A buy is an exact-output swap, so it delivers precisely what the basket needs and the only leftover is
///        `tokenIn`. The V4 router at the pinned version does not check that an exact-output swap delivered, so the
///        engine measures each leg's component balance and raises `ShortFill` if it did not.
///      - Every route is checked to start at the component and end at the user's token, so a malformed route cannot
///        leave funds in a third token. A V4 route must additionally be hookless: a hook is arbitrary code that runs
///        inside the swap and can move the deltas, and refusing hooks is one equality rather than a list of flags.
///        It also rules out a dynamic fee, which only a hooked pool can carry.
///      - What a swap took and produced is measured as balance changes inside the call, never from the router's own
///        reports. Anything the router did not spend comes back through the sweep. A balance the router happened to be
///        holding comes back with it: on a buy it enlarges the caller's refund, and on a sale it is returned with the
///        unsold input. Neither side may treat it as a shortfall. A sale hop therefore measures what the sweep brought
///        back, not what the swap sold, which a stray larger than the sale used to underflow: anyone could revert a
///        public burn by donating to the router and sweeping the donation back (CR-L02).
///      - A V3 sale is swapped one hop at a time, because a V3 pool can stop at its price limit and a multi-hop call
///        would leave the unsold middle in the router. A V4 sale is one swap: an intermediate hop that fills short
///        leaves the pool manager unsettled and reverts the whole leg, unless its input is the component or `tokenOut`
///        again, whose leftover nets into the settle or the take and is returned or paid out (CR-I07). So on a route
///        that never revisits them only the first hop can leave unsold input. Native ether never reaches the engine,
///        which has no way to receive it: the take only ever takes `tokenOut`.
///      - What a hop did not sell goes to {_unsold}, which the zap pays to the burn's recipient and the builder credits
///        back to the user's escrow; unsold `tokenOut` stays with the proceeds.
abstract contract UniversalRouterSwaps is IUniversalRouterSwaps {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    /// @inheritdoc IUniversalRouterSwaps
    IUniversalRouter public immutable ROUTER;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable POOL_MANAGER;

    /// @dev The engine sweeps whatever the router did not spend and accepts any amount, including none: the leg's own
    ///      limits already bound what it could have spent, and the swap's delivery is checked separately.
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
    ///      The router is pre-funded with the cap and swept clean in the same call, so it is never left holding
    ///      anything and never has an allowance here to spend later. `amountOut` must never be zero, which matters
    ///      because zero is the V4 router's open-delta sentinel in the swap-amount position too, meaning "the full
    ///      debt": a basket's amounts are `ceil(shares * units / 1e18)` with non-zero shares, and every component's
    ///      units are at least one raw unit, since they start at MIN_RAW_UNITS or more and a rebalance rounds every
    ///      new unit up (CR-I05).
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
        // Every entry point of the zap and the builder is nonReentrant, which the lint does not model; the builder
        // credits its escrow only from what is measured once the router has returned.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        ROUTER.execute(commands, inputs);

        // The router reports nothing, so both sides are measured here. The pinned V4 router does not check that an
        // exact-output swap delivered, and a short fill would otherwise surface as an opaque failure inside issue().
        uint256 delivered = IERC20(component).balanceOf(address(this)) - outBefore;
        if (delivered < amountOut) revert ShortFill(i, delivered, amountOut);
        amountIn = Math.saturatingSub(inBefore, token.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------
    // Selling
    // ---------------------------------------------------------------------

    /// @dev Sells `amountIn` of `component` into `tokenOut` along the leg's route, which must be valid even when
    ///      there is nothing to sell. The proceeds stay here, for the caller to measure as its `tokenOut` balance
    ///      change; what a hop did not sell goes to {_unsold} with `ctx`. A leg that sells nothing but names a minimum
    ///      reverts InsufficientOutput.
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

    /// @dev Sells `amountIn` of `component` along the leg's V3 path, one hop at a time. A V3 pool can stop at its
    ///      price limit and take less than the input of any hop. A multi-hop call would hide that on every hop after
    ///      the first, so each hop is swapped on its own and its unsold input is measured and returned. The leg's
    ///      minimum applies to the last hop's output; the caller's overall minimum bounds the whole sale.
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
            uint256 produced = _v3Hop(
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

    /// @dev One V3 hop: pre-fund the router, swap, sweep it clean, and return what arrived. The unsold input goes back
    ///      through {_unsold} rather than staying where anyone could sweep it. What the sweep brought back is measured
    ///      directly, as the balance above what was left once the router had been pre-funded: the sweep only ever adds
    ///      to it, so this cannot underflow whatever the router held beforehand (CR-L02).
    function _v3Hop(
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

    /// @dev Sells `amountIn` of `component` along the leg's V4 route as one swap. Every intermediate currency, native
    ///      ether included, nets inside the pool manager: an intermediate hop that filled short would leave a credit
    ///      the unlock refuses to close, so the leg reverts whole rather than stranding a middle token here. The first
    ///      hop can leave unsold input, and so can a later hop whose input is the component again, whose leftover nets
    ///      against the leg's own debt (CR-I07); the sweep returns both, measured as in `_v3Hop` (CR-L02).
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

    /// @dev Hands what a hop did not sell, together with any balance of it the router already held, to {_unsold}.
    ///      Unsold `tokenOut` stays here: the proceeds are measured as the caller's `tokenOut` balance change, so it
    ///      reaches the recipient with the rest instead of being paid out twice.
    function _returnUnsold(address tokenOut, address token, uint256 unsold, bytes memory ctx) private {
        if (unsold == 0 || token == tokenOut) return;
        _unsold(token, unsold, ctx);
    }

    /// @dev Receives `amount` of `token` a sale hop did not sell, already in this contract's balance, with the `ctx`
    ///      the sale was called with.
    function _unsold(address token, uint256 amount, bytes memory ctx) internal virtual;

    // ---------------------------------------------------------------------
    // Routes
    // ---------------------------------------------------------------------

    /// @dev A leg names exactly one venue, and its route has to reach from the component to the user's token. The
    ///      `component` end of a V4 route is the engine's own argument rather than the caller's, so only the far end
    ///      needs checking; which entry that is depends on the direction the router walks the route, from the front
    ///      for an exact input and from the back for an exact output.
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
        // A hook is arbitrary code running inside the swap, able to move the deltas the engine is measuring; a
        // hookless key also cannot carry a dynamic fee, so this one equality is the whole check. Native ether is
        // allowed as an intermediate currency and never as an endpoint, which the equality below settles.
        for (uint256 h = 0; h < v4Path.length; ++h) {
            if (v4Path[h].hooks != address(0) || v4Path[h].hookData.length != 0) revert BadRoute(i);
        }
        uint256 far = exactOut ? 0 : v4Path.length - 1;
        if (v4Path[far].intermediateCurrency != userToken) revert BadRoute(i);
    }
}
