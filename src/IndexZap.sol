// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {IIndexZap} from "./interfaces/IIndexZap.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {PathLib} from "./libraries/PathLib.sol";
import {UniversalRouterCommands as Cmd} from "./libraries/UniversalRouterCommands.sol";
import {PathKey, UniswapV4Types as V4, V4ExactInputParams, V4ExactOutputParams} from "./libraries/UniswapV4Types.sol";

/// @title IndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and burn any index
///         straight into a single token, swapping through Uniswap's Universal Router.
/// @dev Design notes
///      - The contract holds no state and no funds between transactions. Anyone can deploy a competing zap; the index
///        contracts do not know or care about this one.
///      - Each leg names its venue. Depth still favours V3 for some components and V4 for others, so the app chooses
///        per leg and the zap builds the router commands for whichever it finds.
///      - The zap builds every command itself and forwards nothing a caller supplied. The router's command set
///        includes sweeps and Permit2 transfers, so passing calldata through would hand a caller its permissions.
///      - Nothing is approved to the router and Permit2 is never used. A leg pre-funds the router with exactly what it
///        may spend, swaps with the router paying from its own balance, and sweeps the remainder back in the same
///        call. Every part of that is one atomic `execute`: a sweep that came up short would fail the swap with it.
///      - Minting uses exact-output swaps so the zap buys precisely the basket for `shares` and the only leftover is
///        `tokenIn`, refunded in one transfer. The V4 router at the pinned version does not check that an exact-output
///        swap delivered, so the zap measures each leg's component balance and raises `ShortFill` if it did not.
///      - Every route is checked to start at the component and end at the user's token, so a malformed route cannot
///        leave funds in a third token. A V4 route must additionally be hookless: a hook is arbitrary code that runs
///        inside the swap and can move the deltas, and refusing hooks is one equality rather than a list of flags.
///        It also rules out a dynamic fee, which only a hooked pool can carry.
///      - Each leg can carry its own limit on top of the overall `maxAmountIn` / `minAmountOut`, so a sandwich cannot
///        spend the whole tolerance on one thin pool. A zero leg limit means "overall limit only". The overall burn
///        limit must be non-zero.
///      - What the user pays and receives is measured as balance changes inside the call, so tokens already sitting in
///        the zap are never used, and the router's own reports are never the accounting. A fee-on-transfer currency
///        reverts with `TransferShortfall`. Anything the router did not spend comes back through the sweep and reaches
///        the recipient rather than being stranded; a balance the router happened to be holding comes back with it,
///        which is a refund to the caller and never a shortfall, hence the saturating arithmetic.
///      - A V3 burn leg is swapped one hop at a time, because a V3 pool can stop at its price limit and a multi-hop
///        call would leave the unsold middle in the router. A V4 burn leg is one swap: an intermediate hop that fills
///        short leaves the pool manager unsettled and reverts the whole leg, so only its first hop can leave unsold
///        input. Native ether therefore never reaches this contract, which has no way to receive it.
///      - The zap never calls `redeemSkipping`: a claim recorded for the zap could never be collected. While a
///        component is frozen, holders exit directly through the index.
///      - Every call names the index's `rebalanceNonce` its quote was taken at. A rebalance changes the units, so a
///        stale quote reverts with `StaleRebalanceNonce` instead of buying or selling a different basket.
///      - The zap never calls `executeRebalance`.
contract IndexZap is ReentrancyGuard, IIndexZap {
    using SafeERC20 for IERC20;
    using PathLib for bytes;

    /// @inheritdoc IIndexZap
    IIndexFactory public immutable FACTORY;
    /// @inheritdoc IIndexZap
    IUniversalRouter public immutable ROUTER;
    /// @inheritdoc IIndexZap
    address public immutable POOL_MANAGER;

    /// @dev The zap sweeps whatever the router did not spend and accepts any amount, including none: the leg's own
    ///      limits already bound what it could have spent, and the swap's delivery is checked separately.
    uint256 private constant SWEEP_NO_MINIMUM = 0;
    /// @dev Every V4 leg is the same three actions: swap, settle what it owes, take what it produced.
    uint256 private constant V4_ACTIONS = 3;

    constructor(IIndexFactory factory, IUniversalRouter router) {
        if (address(factory) == address(0) || address(router) == address(0)) revert ZeroAddress();
        FACTORY = factory;
        ROUTER = router;
        // Read from the router rather than passed in, so the two can never be wired to different deployments.
        POOL_MANAGER = router.poolManager();
    }

    // ---------------------------------------------------------------------
    // Mint
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexZap
    function mintWithToken(MintParams calldata p) external nonReentrant returns (uint256 amountSpent) {
        _checkCommon(p.index, p.expectedNonce, p.to, p.deadline);
        if (p.tokenIn == address(0)) revert ZeroAddress();
        if (p.shares == 0 || p.maxAmountIn == 0) revert ZeroAmount();

        IERC20 tokenIn = IERC20(p.tokenIn);
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), p.maxAmountIn);
        uint256 received = tokenIn.balanceOf(address(this)) - balanceBefore;
        if (received < p.maxAmountIn) revert TransferShortfall(p.tokenIn);

        uint256 reserved = _buyBasket(p);

        // Whatever of this call's tokenIn the swaps did not take goes back, except the part the basket itself holds,
        // which issue() pulls below. A balance the router happened to hold arrives through the sweep and enlarges the
        // refund rather than underflowing it.
        uint256 refund = Math.saturatingSub(tokenIn.balanceOf(address(this)) - balanceBefore, reserved);
        amountSpent = Math.saturatingSub(received, refund);
        if (refund != 0) tokenIn.safeTransfer(msg.sender, refund);

        // The amount is only known after the swaps; the function is nonReentrant so the log cannot
        // be reordered by a reentrant call.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ZapMint(p.index, msg.sender, p.to, p.tokenIn, amountSpent, p.shares);

        // The swaps and the refund run outside the index's guard, so a token callback could have settled a rebalance
        // since the check on entry; issuing then would buy a basket the legs were not quoted for.
        _checkNonce(p.index, p.expectedNonce);
        IIndexToken(p.index).issue(p.shares, p.to);
    }

    /// @dev Buys every component that is not `tokenIn`, approves the index for the whole basket and
    ///      returns the amount of `tokenIn` that the basket holds directly.
    function _buyBasket(MintParams calldata p) private returns (uint256) {
        address[] memory tokens = IIndexToken(p.index).componentTokens();
        uint256 n = tokens.length;
        if (p.legs.length != n) revert LegCountMismatch();
        uint256[] memory need = IIndexToken(p.index).previewIssue(p.shares);

        uint256 reserved = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == p.tokenIn) reserved = need[i];
        }
        if (reserved > p.maxAmountIn) revert InsufficientBudget(reserved, p.maxAmountIn);

        uint256 spent = reserved;
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenIn) {
                if (p.legs[i].v3Path.length != 0 || p.legs[i].v4Path.length != 0) revert BadRoute(i);
                // As on the burn side, the leg that carries no swap still honours its own limit (DA-15).
                uint256 legCap = p.legs[i].maxAmountIn;
                if (legCap != 0 && need[i] > legCap) revert InsufficientBudget(need[i], legCap);
            } else {
                spent += _buy(p, component, need[i], p.maxAmountIn - spent, i);
            }
            IERC20(component).forceApprove(p.index, need[i]);
        }
        return reserved;
    }

    /// @dev Buys exactly `amountOut` of `component`, paying at most the leg's cap out of `budget`, and returns what it
    ///      cost. The router is pre-funded with the cap and swept clean in the same call, so it is never left holding
    ///      anything and never has an allowance here to spend later.
    function _buy(MintParams calldata p, address component, uint256 amountOut, uint256 budget, uint256 i)
        private
        returns (uint256 amountIn)
    {
        MintLeg calldata leg = p.legs[i];
        bool isV4 = _checkRoute(leg.v3Path, leg.v4Path, component, p.tokenIn, true, i);
        uint256 cap = leg.maxAmountIn != 0 && leg.maxAmountIn < budget ? leg.maxAmountIn : budget;

        IERC20 tokenIn = IERC20(p.tokenIn);
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = IERC20(component).balanceOf(address(this));
        tokenIn.safeTransfer(address(ROUTER), cap);

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
            params[1] = abi.encode(p.tokenIn, V4.OPEN_DELTA, false);
            params[2] = abi.encode(component, address(this), V4.OPEN_DELTA);
            inputs[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_OUT, V4.SETTLE, V4.TAKE), params);
        } else {
            commands = abi.encodePacked(Cmd.V3_SWAP_EXACT_OUT, Cmd.SWEEP);
            inputs[0] = abi.encode(address(this), amountOut, cap, leg.v3Path, false);
        }
        inputs[1] = abi.encode(p.tokenIn, address(this), SWEEP_NO_MINIMUM);
        ROUTER.execute(commands, inputs);

        // The router reports nothing, so both sides are measured here. The pinned V4 router does not check that an
        // exact-output swap delivered, and a short fill would otherwise surface as an opaque failure inside issue().
        uint256 delivered = IERC20(component).balanceOf(address(this)) - outBefore;
        if (delivered < amountOut) revert ShortFill(i, delivered, amountOut);
        amountIn = Math.saturatingSub(inBefore, tokenIn.balanceOf(address(this)));
    }

    // ---------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexZap
    function burnToToken(BurnParams calldata p) external nonReentrant returns (uint256 amountOut) {
        _checkBurn(p);
        return _burnBasket(p);
    }

    /// @inheritdoc IIndexZap
    function burnToTokenWithPermit(BurnParams calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkBurn(p);
        // A permit front-run by someone else leaves the allowance already set, which is the state this needed anyway,
        // so a failed permit is not a failed burn. The transfer below is what actually enforces the approval, and the
        // checks above have already run.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        // wake-disable-next-line reentrancy
        try IERC20Permit(p.index).permit(msg.sender, address(this), p.shares, p.deadline, v, r, s) {} catch {}
        return _burnBasket(p);
    }

    function _burnBasket(BurnParams calldata p) private returns (uint256 amountOut) {
        address[] memory tokens = IIndexToken(p.index).componentTokens();
        if (p.legs.length != tokens.length) revert LegCountMismatch();

        IERC20 tokenOut = IERC20(p.tokenOut);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        IERC20(p.index).safeTransferFrom(msg.sender, address(this), p.shares);
        // redeem() rounds down deterministically, so the preview is the exact amount received.
        uint256[] memory got = IIndexToken(p.index).previewRedeem(p.shares);
        // The basket has to be in hand before it can be sold, so this interaction cannot be the last
        // one. The function is nonReentrant and the zap keeps no state; Wake's reentrancy detector
        // does not model reentrancy guards, hence the suppression.
        // wake-disable-next-line reentrancy
        IIndexToken(p.index).redeem(p.shares, address(this));

        _sellBasket(p, tokens, got);
        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < p.minAmountOut) revert InsufficientOutput(amountOut, p.minAmountOut);

        // forge-lint: disable-next-line(reentrancy-events)
        emit ZapBurn(p.index, msg.sender, p.to, p.tokenOut, p.shares, amountOut);
        uint256 paidBefore = tokenOut.balanceOf(p.to);
        tokenOut.safeTransfer(p.to, amountOut);
        // A fee-on-transfer payout would leave the recipient short of what this call reported paying them.
        if (tokenOut.balanceOf(p.to) - paidBefore < amountOut) revert TransferShortfall(p.tokenOut);
    }

    /// @dev Sells every component held by this contract into `tokenOut`, counting components that already are
    ///      `tokenOut`. Nothing is returned: the payout is the contract's own `tokenOut` balance change.
    function _sellBasket(BurnParams calldata p, address[] memory tokens, uint256[] memory got) private {
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenOut) {
                if (p.legs[i].v3Path.length != 0 || p.legs[i].v4Path.length != 0) revert BadRoute(i);
                // The pass-through leg carries no swap, but its limit is still the caller's and is still checked, so
                // every leg honours the limit its NatSpec promises (DA-15).
                if (got[i] < p.legs[i].minAmountOut) revert InsufficientOutput(got[i], p.legs[i].minAmountOut);
                continue;
            }
            // Every leg is validated, including one that sells nothing, whose minimum then cannot be met.
            bool isV4 = _checkRoute(p.legs[i].v3Path, p.legs[i].v4Path, component, p.tokenOut, false, i);
            if (got[i] != 0) {
                if (isV4) {
                    _sellV4(p, component, got[i], i);
                } else {
                    _sellV3(p, component, got[i], i);
                }
            } else if (p.legs[i].minAmountOut != 0) {
                revert InsufficientOutput(0, p.legs[i].minAmountOut);
            }
        }
    }

    /// @dev Sells `amountIn` of `component` along the leg's V3 path, one hop at a time. A V3 pool can stop at its
    ///      price limit and take less than the input of any hop. A multi-hop call would hide that on every hop after
    ///      the first, so each hop is swapped on its own and its unsold input is measured and returned. The leg's
    ///      minimum applies to the last hop's output; the overall minimum bounds the whole burn.
    function _sellV3(BurnParams calldata p, address component, uint256 amountIn, uint256 i) private {
        BurnLeg calldata leg = p.legs[i];
        bytes calldata path = leg.v3Path;
        address hopIn = component;
        uint256 given = amountIn;
        while (true) {
            bool last = path.length == PathLib.ADDR_SIZE + PathLib.HOP_SIZE;
            address hopOut = address(bytes20(path[PathLib.HOP_SIZE:PathLib.HOP_SIZE + PathLib.ADDR_SIZE]));
            uint256 produced = _v3Hop(
                p, path[:PathLib.ADDR_SIZE + PathLib.HOP_SIZE], hopIn, hopOut, given, last ? leg.minAmountOut : 0
            );
            if (last) return;
            // A hop that produced nothing has nothing to hand the next one, and the leg cannot complete.
            if (produced == 0) revert InsufficientOutput(0, leg.minAmountOut);
            (hopIn, given) = (hopOut, produced);
            path = path[PathLib.HOP_SIZE:];
        }
    }

    /// @dev One V3 hop: pre-fund the router, swap, sweep it clean, and return what arrived. The unsold input goes back
    ///      to the recipient rather than staying where anyone could sweep it.
    function _v3Hop(
        BurnParams calldata p,
        bytes calldata hopPath,
        address hopIn,
        address hopOut,
        uint256 given,
        uint256 minOut
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
        _returnUnsold(p, hopIn, Math.saturatingSub(given, inBefore - token.balanceOf(address(this))));
    }

    /// @dev Sells `amountIn` of `component` along the leg's V4 route as one swap. Every intermediate currency, native
    ///      ether included, nets inside the pool manager: an intermediate hop that filled short would leave a credit
    ///      the unlock refuses to close, so the leg reverts whole rather than stranding a middle token here. Only the
    ///      first hop can leave unsold input, which the sweep returns.
    function _sellV4(BurnParams calldata p, address component, uint256 amountIn, uint256 i) private {
        BurnLeg calldata leg = p.legs[i];
        IERC20 token = IERC20(component);
        uint256 inBefore = token.balanceOf(address(this));
        token.safeTransfer(address(ROUTER), amountIn);

        bytes[] memory params = new bytes[](V4_ACTIONS);
        params[0] = abi.encode(
            V4ExactInputParams({
                currencyIn: component,
                path: leg.v4Path,
                amountIn: SafeCast.toUint128(amountIn),
                amountOutMinimum: SafeCast.toUint128(leg.minAmountOut)
            })
        );
        params[1] = abi.encode(component, V4.OPEN_DELTA, false);
        params[2] = abi.encode(p.tokenOut, address(this), V4.OPEN_DELTA);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(abi.encodePacked(V4.SWAP_EXACT_IN, V4.SETTLE, V4.TAKE), params);
        inputs[1] = abi.encode(component, address(this), SWEEP_NO_MINIMUM);
        ROUTER.execute(abi.encodePacked(Cmd.V4_SWAP, Cmd.SWEEP), inputs);

        _returnUnsold(p, component, Math.saturatingSub(amountIn, inBefore - token.balanceOf(address(this))));
    }

    /// @dev Sends back what a hop did not sell. Unsold `tokenOut` stays here: the payout is measured as this
    ///      contract's `tokenOut` balance change, so it reaches the recipient with the rest of the proceeds instead of
    ///      being paid out twice.
    function _returnUnsold(BurnParams calldata p, address token, uint256 unsold) private {
        if (unsold == 0 || token == p.tokenOut) return;
        // forge-lint: disable-next-line(reentrancy-events)
        emit ComponentReturned(p.index, p.to, token, unsold);
        IERC20(token).safeTransfer(p.to, unsold);
    }

    // ---------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------

    function _checkBurn(BurnParams calldata p) private view {
        _checkCommon(p.index, p.expectedNonce, p.to, p.deadline);
        if (p.tokenOut == address(0)) revert ZeroAddress();
        if (p.shares == 0 || p.minAmountOut == 0) revert ZeroAmount();
    }

    function _checkCommon(address index, uint256 expectedNonce, address to, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!FACTORY.isIndex(index)) revert NotIndex(index);
        _checkNonce(index, expectedNonce);
        if (to == address(0)) revert ZeroAddress();
        // Tokens left in the router can be swept by anyone, and anything sent to the pool manager is a donation.
        if (to == address(this) || to == index || to == address(ROUTER) || to == POOL_MANAGER) {
            revert InvalidRecipient(to);
        }
    }

    function _checkNonce(address index, uint256 expectedNonce) private view {
        uint256 nonce = IIndexToken(index).rebalanceNonce();
        if (nonce != expectedNonce) revert StaleRebalanceNonce(expectedNonce, nonce);
    }

    /// @dev A leg names exactly one venue, and its route has to reach from the component to the user's token. The
    ///      `component` end of a V4 route is the zap's own argument rather than the caller's, so only the far end
    ///      needs checking; which entry that is depends on the direction the router walks the route, from the front
    ///      for an exact input and from the back for an exact output.
    /// @param exactOut True for a mint leg, whose route the router walks backwards.
    /// @return isV4 Whether the leg named a V4 route.
    function _checkRoute(
        bytes calldata v3Path,
        PathKey[] calldata v4Path,
        address component,
        address userToken,
        bool exactOut,
        uint256 i
    ) private pure returns (bool isV4) {
        isV4 = v4Path.length != 0;
        if (isV4 == (v3Path.length != 0)) revert BadRoute(i); // both, or neither
        if (!isV4) {
            if (!v3Path.isValidShape() || v3Path.firstToken() != component || v3Path.lastToken() != userToken) {
                revert BadRoute(i);
            }
            return false;
        }
        // A hook is arbitrary code running inside the swap, able to move the deltas the zap is measuring; a hookless
        // key also cannot carry a dynamic fee, so this one equality is the whole check. Native ether is allowed as an
        // intermediate currency and never as an endpoint, which the equality below settles.
        for (uint256 h = 0; h < v4Path.length; ++h) {
            if (v4Path[h].hooks != address(0) || v4Path[h].hookData.length != 0) revert BadRoute(i);
        }
        uint256 far = exactOut ? 0 : v4Path.length - 1;
        if (v4Path[far].intermediateCurrency != userToken) revert BadRoute(i);
    }
}
