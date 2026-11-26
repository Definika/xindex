// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAeroCLFactory} from "./interfaces/IAeroCLFactory.sol";
import {IAeroMetarouter} from "./interfaces/IAeroMetarouter.sol";
import {IAeroPoolFactory} from "./interfaces/IAeroPoolFactory.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {IUniversalRouterSwaps} from "./interfaces/IUniversalRouterSwaps.sol";
import {PathLib} from "./libraries/PathLib.sol";
import {AeroCommands as Aero} from "./libraries/AeroCommands.sol";
import {UniversalRouterCommands as Cmd} from "./libraries/UniversalRouterCommands.sol";
import {PathKey, UniswapV4Types as V4, V4ExactInputParams, V4ExactOutputParams} from "./libraries/UniswapV4Types.sol";

/// @title UniversalRouterSwaps
/// @notice The swap engine shared by `IndexZap` and `BasketBuilder`, through Uniswap's Universal Router (V3 or V4 per
///         leg) or the chain's own DEX (PancakeSwap on BNB Chain, Aero on Base). A mint buys each component with an
///         exact-output swap. A burn sells each with an exact-input swap.
/// @dev Design notes
///      - Venue: each leg names one: Uniswap V3, Uniswap V4, or the chain's own DEX, which the deployment fixes. Depth
///        favours each for some components, so the app chooses per leg (`design/2026-11-26-chain-venues.md`). The
///        rules below hold for every venue: the chain's DEX is reached through a router of the same kind,
///        PancakeSwap's Universal Router (a fork of Uniswap's) or Aero's Metarouter, which both spend their own
///        balance when the payer is not the user, and both return it in the same call.
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
///        sweep also returns any balance the router already held. On a buy that enlarges the refund; on a sale it
///        comes back with the unsold input, and is told apart from it: a hop never spends more than its pre-fund,
///        so it is the part of the sweep the router held before the pre-fund. Neither is a shortfall. So a sale hop
///        measures what the sweep brought back, not what the swap sold. Do not measure what was sold: a donation to
///        the router larger than the sale would underflow, and anyone could revert a public burn (CR-L02).
///      - One balance, one address: every measurement here assumes that moving one token leaves the balance of
///        another alone. With one balance behind two addresses it does not, and the same tokens would be counted
///        twice: as a hop's output and as input its sweep brought back, as a sale's proceeds and as unsold input, or
///        as a component delivered and as `tokenIn` not spent. So each pre-fund that sends anything checks that it
///        did not lower the balance it is about to be measured against, and the leg reverts `SharedBalance` if it
///        did. A buy leg with nothing left to spend sends nothing, so nothing is checked there; with plain tokens
///        and one address of the balance listed, such a leg cannot be filled.
///      - V3 sales go one hop at a time, because a V3 pool can stop at its price limit, and a multi-hop call would
///        leave the unsold middle token in the router. A sale through the chain's DEX goes one hop at a time too,
///        whatever its pools: one rule, and each hop's unsold input measured where it comes back.
///      - A V4 sale is one swap. If a middle hop fills short, the pool manager is left unsettled and the whole leg
///        reverts. The exception is a hop whose input is the component or `tokenOut` again: its leftover nets into
///        the settle or the take (CR-I07). So, on a route that never revisits them, only the first hop can leave
///        unsold input.
///      - Native ether never reaches the engine, which cannot receive it: the take only ever takes the leg's far end,
///        the component on a buy and `tokenOut` on a sale, neither of which may be native ether (RX-53). PancakeSwap's
///        router takes ether only from WETH and its vault and sends none back; Aero's returns a batch's ether to its
///        caller, so ether sent into it during a leg, which only a token of the caller's own route could do, reverts
///        that leg alone.
///      - The chain's DEX: a route names tokens, never pools. PancakeSwap's router computes its pools from its
///        factories; Aero's pools are looked up in the factories the deployment pins, and the Metarouter checks each
///        against Aero's factory registry again. A pool's own fee modules (PancakeSwap's farm contracts, Aero's
///        dynamic fee and MEV tax) can make a leg cost more, within the caller's limits, never take what it pre-funds.
///      - What a hop did not sell goes to {_onUnsold}, with what the router already held named apart. The builder
///        credits both to the user's escrow. The zap pays the first to the burn's recipient and only offers the
///        second: a stranger's wei left in the router must not force a transfer the recipient may refuse. Unsold
///        `tokenOut` stays with the proceeds.
abstract contract UniversalRouterSwaps is IUniversalRouterSwaps {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    /// @dev The venue a leg names; on the chain's own DEX, with its pool family.
    enum Venue {
        UniswapV3,
        UniswapV4,
        LocalConcentrated,
        LocalConstantFunction
    }

    /// @inheritdoc IUniversalRouterSwaps
    IUniversalRouter public immutable ROUTER;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable POOL_MANAGER;
    /// @inheritdoc IUniversalRouterSwaps
    LocalDex public immutable LOCAL_DEX;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable LOCAL_ROUTER;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable AERO_CL_FACTORY;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable AERO_VOLATILE_FACTORY;
    /// @inheritdoc IUniversalRouterSwaps
    address public immutable AERO_STABLE_FACTORY;

    /// @dev The sweep returns whatever the router did not spend, and accepts any amount, including none. The leg's
    ///      pre-fund already bounds its spend, and delivery is checked separately.
    uint256 private constant SWEEP_NO_MINIMUM = 0;
    /// @dev Every V4 leg is the same three actions: swap, settle what it owes, take what it produced.
    uint256 private constant V4_ACTIONS = 3;
    /// @dev A `localRoute`'s first byte: concentrated-liquidity pools (PancakeSwap V3, Aero CL), or constant-function
    ///      pools (PancakeSwap V2, Aero's basic pools).
    uint8 private constant CONCENTRATED = 0;
    uint8 private constant CONSTANT_FUNCTION = 1;
    /// @dev Bytes of a `localRoute` before its path: the family.
    uint256 private constant FAMILY_SIZE = 1;

    constructor(IUniversalRouter router, LocalVenue memory local) {
        if (address(router) == address(0)) revert ZeroAddress();
        ROUTER = router;
        // Read from the router rather than passed in, so the two can never be wired to different deployments.
        POOL_MANAGER = router.poolManager();
        // Each DEX names what it uses and nothing else: a router for either, Aero's three factories for Aero alone.
        // Uniswap's router named again would make one venue look like two.
        bool aero = local.dex == LocalDex.Aero;
        if (
            (local.dex == LocalDex.None) != (local.router == address(0)) || local.router == address(router)
                || aero != (local.clFactory != address(0)) || aero != (local.volatileFactory != address(0))
                || aero != (local.stableFactory != address(0))
        ) revert InvalidLocalVenue();
        LOCAL_DEX = local.dex;
        LOCAL_ROUTER = local.router;
        AERO_CL_FACTORY = local.clFactory;
        AERO_VOLATILE_FACTORY = local.volatileFactory;
        AERO_STABLE_FACTORY = local.stableFactory;
    }

    // ---------------------------------------------------------------------
    // Buying
    // ---------------------------------------------------------------------

    /// @dev Buys exactly `amountOut` of `component` with `tokenIn`, paying at most `cap`, and returns what it cost.
    ///      The leg's router is pre-funded with `cap` and swept clean in the same call. So it never keeps anything,
    ///      and never holds an allowance from here.
    ///      `amountOut` is never zero. This matters: for the V4 router, zero in the amount position means "the full
    ///      debt" (open delta). A basket's amounts are `ceil(gross * units * scale / 1e36)` with non-zero shares, and
    ///      units are always at least one raw unit: they start at MIN_RAW_UNITS or more, a rebalance rounds new units
    ///      up, and the scale never reaches zero (CR-I05).
    /// @param i The leg's position, named by the errors.
    function _buy(address tokenIn, address component, uint256 amountOut, uint256 cap, MintLeg calldata leg, uint256 i)
        internal
        returns (uint256 amountIn)
    {
        Venue venue = _checkRoute(leg.v3Path, leg.v4Path, leg.localRoute, component, tokenIn, true, i);

        IERC20 token = IERC20(tokenIn);
        uint256 inBefore = token.balanceOf(address(this));
        uint256 outBefore = IERC20(component).balanceOf(address(this));
        token.safeTransfer(_routerOf(venue), cap);
        // One balance behind both addresses: the component delivered would also count as `tokenIn` the swap did not
        // spend, and be refunded on top of being delivered. A cap of zero sends nothing and so shows nothing.
        if (IERC20(component).balanceOf(address(this)) < outBefore) revert SharedBalance(component, tokenIn);

        bytes memory commands;
        bytes[] memory inputs = new bytes[](2);
        if (venue == Venue.UniswapV4) {
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
        } else if (venue == Venue.UniswapV3) {
            commands = abi.encodePacked(Cmd.V3_SWAP_EXACT_OUT, Cmd.SWEEP);
            inputs[0] = abi.encode(address(this), amountOut, cap, leg.v3Path, false);
        } else {
            (commands, inputs[0]) = _localBuyInput(venue, tokenIn, amountOut, cap, leg.localRoute[FAMILY_SIZE:]);
        }
        // Every router's sweep, Aero's included, takes `(token, recipient, minimum)` under the same byte.
        inputs[1] = abi.encode(tokenIn, address(this), SWEEP_NO_MINIMUM);
        _execute(venue, commands, inputs);

        // The routers report nothing, so both sides are measured here. The pinned V4 router does not check
        // exact-output delivery; without this check, a short fill would surface as an opaque failure inside issue().
        uint256 delivered = IERC20(component).balanceOf(address(this)) - outBefore;
        if (delivered < amountOut) revert ShortFill(i, delivered, amountOut);
        amountIn = Math.saturatingSub(inBefore, token.balanceOf(address(this)));
    }

    /// @dev The first command of a buy through the chain's DEX, and its input, for a route from the component back to
    ///      `tokenIn`. PancakeSwap's V3 legs take the path as it is, reversed, as Uniswap's do; its V2 legs and every
    ///      Aero leg run forward from `tokenIn`.
    function _localBuyInput(Venue venue, address tokenIn, uint256 amountOut, uint256 cap, bytes calldata path)
        private
        view
        returns (bytes memory commands, bytes memory input)
    {
        bool concentrated = venue == Venue.LocalConcentrated;
        if (LOCAL_DEX == LocalDex.PancakeSwap) {
            if (concentrated) {
                return (
                    abi.encodePacked(Cmd.V3_SWAP_EXACT_OUT, Cmd.SWEEP),
                    abi.encode(address(this), amountOut, cap, path, false)
                );
            }
            return (
                abi.encodePacked(Cmd.V2_SWAP_EXACT_OUT, Cmd.SWEEP),
                abi.encode(address(this), amountOut, cap, _forwardTokens(path), false)
            );
        }
        IAeroMetarouter.SwapExactOutParams memory params = IAeroMetarouter.SwapExactOutParams({
            pools: _forwardAeroPools(concentrated, path),
            tokenIn: tokenIn,
            amountOut: amountOut,
            payerIsUser: false,
            maxAmountIn: cap,
            recipient: address(this)
        });
        commands = abi.encodePacked(concentrated ? Aero.CL_SWAP_EXACT_OUT : Aero.V2_SWAP_EXACT_OUT, Aero.SWEEP);
        input = abi.encode(params);
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
        Venue venue = _checkRoute(leg.v3Path, leg.v4Path, leg.localRoute, component, tokenOut, false, i);
        if (amountIn == 0) {
            if (leg.minAmountOut != 0) revert InsufficientOutput(0, leg.minAmountOut);
            return;
        }
        if (venue == Venue.UniswapV4) {
            _sellV4(tokenOut, component, amountIn, leg.v4Path, leg.minAmountOut, ctx);
        } else if (venue == Venue.UniswapV3) {
            _sellByHop(venue, tokenOut, amountIn, leg.v3Path, leg.minAmountOut, ctx);
        } else {
            _sellByHop(venue, tokenOut, amountIn, leg.localRoute[FAMILY_SIZE:], leg.minAmountOut, ctx);
        }
    }

    /// @dev Sells `amountIn` of the path's first token, the component, along a path of V3's shape, one hop at a time.
    ///      A V3 pool can stop at its price limit and take less than a hop's input, and a multi-hop call would hide
    ///      that after the first hop. So each hop is swapped alone, and its unsold input is measured and returned. The
    ///      leg's minimum applies to the last hop's output; the caller's overall minimum bounds the whole sale. The
    ///      chain's DEX is sold the same way, whatever its pool family.
    function _sellByHop(
        Venue venue,
        address tokenOut,
        uint256 amountIn,
        bytes calldata path,
        uint256 minAmountOut,
        bytes memory ctx
    ) private {
        uint256 given = amountIn;
        while (true) {
            bool last = path.length == PathLib.ADDR_SIZE + PathLib.HOP_SIZE;
            uint256 produced = _sellHop(
                venue, tokenOut, path[:PathLib.ADDR_SIZE + PathLib.HOP_SIZE], given, last ? minAmountOut : 0, ctx
            );
            if (last) return;
            // A hop that produced nothing has nothing to hand the next one, and the leg cannot complete.
            if (produced == 0) revert InsufficientOutput(0, minAmountOut);
            given = produced;
            path = path[PathLib.HOP_SIZE:];
        }
    }

    /// @dev One hop `hopIn | uint24 | hopOut` on the leg's venue.
    function _sellHop(
        Venue venue,
        address tokenOut,
        bytes calldata hopPath,
        uint256 given,
        uint256 minOut,
        bytes memory ctx
    ) private returns (uint256 produced) {
        bytes[] memory inputs = new bytes[](2);
        bytes memory commands;
        if (venue == Venue.UniswapV3) {
            commands = abi.encodePacked(Cmd.V3_SWAP_EXACT_IN, Cmd.SWEEP);
            inputs[0] = abi.encode(address(this), given, minOut, hopPath, false);
        } else {
            (commands, inputs[0]) = _localSellInput(venue, hopPath, given, minOut);
        }
        inputs[1] = abi.encode(hopPath.firstToken(), address(this), SWEEP_NO_MINIMUM);
        return _runHop(venue, tokenOut, hopPath.firstToken(), hopPath.lastToken(), given, ctx, commands, inputs);
    }

    /// @dev Pre-funds the venue's router with `given` of `hopIn`, runs the hop, and returns what arrived of `hopOut`.
    ///      What the sweep brought back goes to {_onUnsold}, not left where anyone could sweep it. It is measured as
    ///      the balance above what remained after the pre-fund. The sweep only adds to that, so it cannot underflow,
    ///      whatever the router held before (CR-L02).
    function _runHop(
        Venue venue,
        address tokenOut,
        address hopIn,
        address hopOut,
        uint256 given,
        bytes memory ctx,
        bytes memory commands,
        bytes[] memory inputs
    ) private returns (uint256 produced) {
        (uint256 inBefore, uint256 outBefore, uint256 stray) =
            _prefund(_routerOf(venue), tokenOut, hopIn, hopOut, given);
        _execute(venue, commands, inputs);

        produced = IERC20(hopOut).balanceOf(address(this)) - outBefore;
        _returnUnsold(tokenOut, hopIn, IERC20(hopIn).balanceOf(address(this)) + given - inBefore, stray, ctx);
    }

    /// @dev The first command of one sale hop through the chain's DEX, and its input.
    function _localSellInput(Venue venue, bytes calldata hopPath, uint256 given, uint256 minOut)
        private
        view
        returns (bytes memory commands, bytes memory input)
    {
        bool concentrated = venue == Venue.LocalConcentrated;
        if (LOCAL_DEX == LocalDex.PancakeSwap) {
            if (concentrated) {
                return (
                    abi.encodePacked(Cmd.V3_SWAP_EXACT_IN, Cmd.SWEEP),
                    abi.encode(address(this), given, minOut, hopPath, false)
                );
            }
            address[] memory pair = new address[](2);
            (pair[0], pair[1]) = (hopPath.firstToken(), hopPath.lastToken());
            return
                (
                    abi.encodePacked(Cmd.V2_SWAP_EXACT_IN, Cmd.SWEEP),
                    abi.encode(address(this), given, minOut, pair, false)
                );
        }
        address[] memory pools = new address[](1);
        pools[0] = _aeroPool(concentrated, hopPath);
        IAeroMetarouter.SwapExactInParams memory params = IAeroMetarouter.SwapExactInParams({
            pools: pools,
            tokenIn: hopPath.firstToken(),
            amountIn: IAeroMetarouter.BalanceSpend({mode: IAeroMetarouter.SpendMode.Amount, value: given}),
            payerIsUser: false,
            minAmountOut: minOut,
            recipient: address(this)
        });
        commands = abi.encodePacked(concentrated ? Aero.CL_SWAP_EXACT_IN : Aero.V2_SWAP_EXACT_IN, Aero.SWEEP);
        input = abi.encode(params);
    }

    /// @dev Sells `amountIn` of `component` along the leg's V4 route as one swap.
    ///      Every middle currency, native ether included, nets inside the pool manager. If a middle hop fills short,
    ///      the pool manager refuses to close, so the whole leg reverts instead of stranding a middle token here.
    ///      Unsold input can come from the first hop, or from a later hop whose input is the component again, since
    ///      its leftover nets against the leg's own debt (CR-I07). The sweep returns both, measured as in
    ///      `_sellByHop` (CR-L02).
    function _sellV4(
        address tokenOut,
        address component,
        uint256 amountIn,
        PathKey[] calldata v4Path,
        uint256 minAmountOut,
        bytes memory ctx
    ) private {
        (uint256 inBefore,, uint256 stray) = _prefund(address(ROUTER), tokenOut, component, tokenOut, amountIn);

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

        _returnUnsold(tokenOut, component, IERC20(component).balanceOf(address(this)) + amountIn - inBefore, stray, ctx);
    }

    /// @dev Pre-funds `router` with `amount` of `token` for one sale hop into `out`, on a leg that ends in `end`.
    ///      Returns what the hop is measured against: this contract's balance of `token` and of `out` before, and the
    ///      router's own balance of `token`.
    ///      Sending `token` must not lower this contract's balance of `out` or of `end`. If it does, two addresses
    ///      share one balance, and what the sweep brings back of `token` would be counted twice: handed to
    ///      {_onUnsold}, and again as the hop's output or as the leg's proceeds. In the builder the seller would be
    ///      credited tokens that are other users' escrow.
    function _prefund(address router, address end, address token, address out, uint256 amount)
        private
        returns (uint256 inBefore, uint256 outBefore, uint256 stray)
    {
        inBefore = IERC20(token).balanceOf(address(this));
        outBefore = IERC20(out).balanceOf(address(this));
        // A hop that spends `end` itself hands none of it to {_onUnsold}: its leftover stays with the proceeds.
        bool probeEnd = end != out && end != token;
        uint256 endBefore = probeEnd ? IERC20(end).balanceOf(address(this)) : 0;
        stray = IERC20(token).balanceOf(router);
        IERC20(token).safeTransfer(router, amount);
        if (IERC20(out).balanceOf(address(this)) < outBefore) revert SharedBalance(out, token);
        if (probeEnd && IERC20(end).balanceOf(address(this)) < endBefore) revert SharedBalance(end, token);
    }

    /// @dev Hands what the sweep of `token` brought back to {_onUnsold}: `returned` in all, of which the router held
    ///      `stray` before the hop. A hop never spends more than its pre-fund, so that part is a stranger's leftover,
    ///      not input the hop did not sell.
    ///      Unsold `tokenOut` stays here. It is counted in the caller's `tokenOut` balance change and reaches the
    ///      recipient with the proceeds, so it is not paid out twice.
    function _returnUnsold(address tokenOut, address token, uint256 returned, uint256 stray, bytes memory ctx) private {
        if (returned == 0 || token == tokenOut) return;
        // Never more than came back: a token that delivers short makes the router pay partly out of what it held.
        stray = Math.min(stray, returned);
        _onUnsold(token, returned - stray, stray, ctx);
    }

    /// @dev Hook for what a sale hop's sweep brought back of its input `token`: `unsold`, which the hop did not sell,
    ///      and `stray`, which the router already held. At least one is not zero, and both are already in this
    ///      contract's balance. `ctx` is what the sale was called with.
    function _onUnsold(address token, uint256 unsold, uint256 stray, bytes memory ctx) internal virtual;

    // ---------------------------------------------------------------------
    // Routers
    // ---------------------------------------------------------------------

    /// @dev The router a venue's legs are pre-funded and run on.
    function _routerOf(Venue venue) private view returns (address) {
        return _isLocal(venue) ? LOCAL_ROUTER : address(ROUTER);
    }

    /// @dev True for a venue on the chain's own DEX.
    function _isLocal(Venue venue) private pure returns (bool) {
        return venue == Venue.LocalConcentrated || venue == Venue.LocalConstantFunction;
    }

    /// @dev Runs a leg's commands on its venue's router. Aero's Metarouter takes a deadline, this block's.
    function _execute(Venue venue, bytes memory commands, bytes[] memory inputs) private {
        // Safe: every entry point of the zap and the builder is nonReentrant, which the lint does not model. The
        // builder credits its escrow only from what it measures after the router returns.
        // Each call names its router by an immutable, never by an address computed at the call.
        if (!_isLocal(venue)) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            ROUTER.execute(commands, inputs);
        } else if (LOCAL_DEX == LocalDex.Aero) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            IAeroMetarouter(LOCAL_ROUTER).execute(commands, inputs, block.timestamp);
        } else {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            IUniversalRouter(LOCAL_ROUTER).execute(commands, inputs);
        }
    }

    /// @dev The tokens of a reversed path, forward: a buy's route runs from the component back to `tokenIn`, and a V2
    ///      pair path runs from the input.
    function _forwardTokens(bytes calldata path) private pure returns (address[] memory tokens) {
        uint256 n = (path.length - PathLib.ADDR_SIZE) / PathLib.HOP_SIZE + 1;
        tokens = new address[](n);
        for (uint256 k = 0; k < n; ++k) {
            uint256 at = k * PathLib.HOP_SIZE;
            tokens[n - 1 - k] = address(bytes20(path[at:at + PathLib.ADDR_SIZE]));
        }
    }

    /// @dev Aero's pools of a reversed path, forward from the input.
    function _forwardAeroPools(bool concentrated, bytes calldata path) private view returns (address[] memory pools) {
        uint256 n = (path.length - PathLib.ADDR_SIZE) / PathLib.HOP_SIZE;
        pools = new address[](n);
        for (uint256 k = 0; k < n; ++k) {
            uint256 at = k * PathLib.HOP_SIZE;
            pools[n - 1 - k] = _aeroPool(concentrated, path[at:at + PathLib.ADDR_SIZE + PathLib.HOP_SIZE]);
        }
    }

    /// @dev Aero's pool for one hop `token | uint24 | token`, from the factories the deployment pins. A pair with no
    ///      such pool gives zero, which the Metarouter refuses as no pool of Aero's.
    function _aeroPool(bool concentrated, bytes calldata hop) private view returns (address) {
        address a = address(bytes20(hop[:PathLib.ADDR_SIZE]));
        uint24 param = uint24(bytes3(hop[PathLib.ADDR_SIZE:PathLib.ADDR_SIZE + PathLib.FEE_SIZE]));
        address b = address(bytes20(hop[PathLib.HOP_SIZE:PathLib.HOP_SIZE + PathLib.ADDR_SIZE]));
        if (concentrated) return IAeroCLFactory(AERO_CL_FACTORY).getPool(a, b, param);
        return IAeroPoolFactory(param == 0 ? AERO_VOLATILE_FACTORY : AERO_STABLE_FACTORY).getPool(a, b);
    }

    // ---------------------------------------------------------------------
    // Routes
    // ---------------------------------------------------------------------

    /// @dev True when a leg names a route, which the pass-through leg, whose component is the user's token, must not.
    function _namesRoute(bytes calldata v3Path, PathKey[] calldata v4Path, bytes calldata localRoute)
        internal
        pure
        returns (bool)
    {
        return v3Path.length != 0 || v4Path.length != 0 || localRoute.length != 0;
    }

    /// @dev Checks that a leg names exactly one venue, and that its route runs from the component to the user's token.
    ///      On a V4 route, the `component` end is the engine's own argument, not the caller's, so only the far end is
    ///      checked. Which entry that is depends on direction: the router walks an exact-input route from the front,
    ///      and an exact-output route from the back.
    /// @param exactOut True for a buy, whose route the router walks backwards.
    /// @return venue The venue the leg named.
    function _checkRoute(
        bytes calldata v3Path,
        PathKey[] calldata v4Path,
        bytes calldata localRoute,
        address component,
        address userToken,
        bool exactOut,
        uint256 i
    ) internal view returns (Venue venue) {
        uint256 named = (v3Path.length != 0 ? 1 : 0) + (v4Path.length != 0 ? 1 : 0) + (localRoute.length != 0 ? 1 : 0);
        if (named != 1) revert BadRoute(i); // none, or more than one
        if (v3Path.length != 0) {
            _checkPath(v3Path, component, userToken, i);
            return Venue.UniswapV3;
        }
        if (localRoute.length != 0) {
            return _checkLocalRoute(localRoute, component, userToken, i);
        }
        // A hook is arbitrary code running inside the swap, able to move the deltas the engine measures. A hookless
        // key cannot carry a dynamic fee either, so this one check covers both. Native ether may be a middle currency
        // but never an endpoint; the far-end check below ensures that.
        for (uint256 h = 0; h < v4Path.length; ++h) {
            if (v4Path[h].hooks != address(0) || v4Path[h].hookData.length != 0) revert BadRoute(i);
        }
        uint256 far = exactOut ? 0 : v4Path.length - 1;
        if (v4Path[far].intermediateCurrency != userToken) revert BadRoute(i);
        return Venue.UniswapV4;
    }

    /// @dev A path of V3's shape from `component` to `userToken`.
    function _checkPath(bytes calldata path, address component, address userToken, uint256 i) private pure {
        if (!path.isValidShape() || path.firstToken() != component || path.lastToken() != userToken) {
            revert BadRoute(i);
        }
    }

    /// @dev A route through the chain's DEX: a deployment that has one, a family it knows, a path from `component` to
    ///      `userToken`, and on constant-function pools a parameter the DEX has (PancakeSwap's V2 pair has none;
    ///      Aero's basic pool is volatile, zero, or stable, one). A concentrated pool's fee tier or tick spacing is
    ///      the DEX's to refuse: a pool that does not exist reverts the swap.
    function _checkLocalRoute(bytes calldata route, address component, address userToken, uint256 i)
        private
        view
        returns (Venue venue)
    {
        uint8 family = uint8(route[0]);
        if (LOCAL_DEX == LocalDex.None || family > CONSTANT_FUNCTION) revert BadRoute(i);
        bytes calldata path = route[FAMILY_SIZE:];
        _checkPath(path, component, userToken, i);
        if (family == CONCENTRATED) return Venue.LocalConcentrated;
        uint24 most = LOCAL_DEX == LocalDex.Aero ? 1 : 0;
        for (uint256 at = PathLib.ADDR_SIZE; at < path.length; at += PathLib.HOP_SIZE) {
            if (uint24(bytes3(path[at:at + PathLib.FEE_SIZE])) > most) revert BadRoute(i);
        }
        return Venue.LocalConstantFunction;
    }
}
