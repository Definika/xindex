// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexHub} from "./interfaces/IIndexHub.sol";
import {IIndexZap} from "./interfaces/IIndexZap.sol";
import {IPancakeUniversalRouter} from "./interfaces/IPancakeUniversalRouter.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";
import {PancakeRouterCommands as PCmd} from "./libraries/PancakeRouterCommands.sol";
import {PathLib} from "./libraries/PathLib.sol";
import {UniversalRouterCommands as Cmd} from "./libraries/UniversalRouterCommands.sol";
import {PathKey, UniswapV4Types as V4, V4ExactInputParams, V4ExactOutputParams} from "./libraries/UniswapV4Types.sol";

/// @title IndexZap
/// @notice Stateless convenience router: mint any index with a single token (USDC, USDT, ...) and burn any index
///         straight into a single token, swapping through Uniswap's Universal Router and, leg by leg, PancakeSwap's.
/// @dev Design notes
///      - The contract holds no state and no funds between transactions. Anyone can deploy a competing zap; the index
///        contracts do not know or care about this one.
///      - Each leg names its venue: a Uniswap V3 path, a Uniswap V4 route or a PancakeSwap V3 path, exactly one.
///        Depth favours Uniswap V3 for some components, V4 for others and PancakeSwap V3 for a few, CAKE above all, so
///        the app chooses per leg and the zap builds the router commands for whichever it finds. A PancakeSwap leg runs
///        through PancakeSwap's own v3 Universal Router with exactly the pattern below; only its command set and its
///        ether refund differ, and both are handled where the commands are built.
///      - The zap builds every command itself and forwards nothing a caller supplied. The router's command set
///        includes sweeps and Permit2 transfers, so passing calldata through would hand a caller its permissions.
///      - Nothing is approved to the router and Permit2 is never used. A leg pre-funds the router with exactly what it
///        may spend, swaps with the router paying from its own balance, and sweeps the remainder back in the same
///        `execute`. The sweep's minimum is zero, so it checks nothing and can never come up short (CR-I14). What bounds
///        a leg is the pre-fund, since the router can pay out only what it holds, and what checks it is the zap's own
///        balance measurement plus `ShortFill` on a mint. The pre-fund is the operative bound, not a backstop: the
///        pinned V4 router checks `amountInMaximum` against the last hop it executed only, so an exact-output route
///        that passes back through `tokenIn` could otherwise spend past it (upstream v4-periphery #564, CR-I06). Never
///        approve either router or pre-fund more than a leg's cap.
///      - PancakeSwap's router sends its whole ether balance to the caller after its last command, reverting if the
///        send fails, and accepts ether from anyone. This contract cannot receive ether, so one wei sent to that router
///        would revert every PancakeSwap leg until someone else's call carried it off. Every PancakeSwap call therefore
///        ends with WRAP_ETH of the router's whole balance, kept in the router, which leaves nothing to send (SV-1).
///        Accepting the ether here instead would break the rule that native ether never reaches the zap.
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
///        the recipient rather than being stranded. A balance the router happened to be holding comes back with it:
///        on a mint it enlarges the refund, and on a burn it is returned with the unsold input. Neither side may treat
///        it as a shortfall. A burn hop therefore measures what the sweep brought back, not what the swap sold, which a
///        stray larger than the sale used to underflow: anyone could revert a public burn by donating to the router and
///        sweeping the donation back (CR-L02).
///      - A V3 burn leg is swapped one hop at a time, because a V3 pool can stop at its price limit and a multi-hop
///        call would leave the unsold middle in the router. A V4 burn leg is one swap: an intermediate hop that fills
///        short leaves the pool manager unsettled and reverts the whole leg, unless its input is the component or
///        `tokenOut` again, whose leftover nets into the settle or the take and is returned or paid out (CR-I07). So
///        on a route that never revisits them only the first hop can leave unsold input. Native ether never reaches
///        this contract, which has no way to receive it: the take only ever takes `tokenOut`.
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
    /// @inheritdoc IIndexZap
    IPancakeUniversalRouter public immutable PANCAKE_ROUTER;

    /// @dev The zap sweeps whatever the router did not spend and accepts any amount, including none: the leg's own
    ///      limits already bound what it could have spent, and the swap's delivery is checked separately.
    uint256 private constant SWEEP_NO_MINIMUM = 0;
    /// @dev Every V4 leg is the same three actions: swap, settle what it owes, take what it produced.
    uint256 private constant V4_ACTIONS = 3;
    /// @dev Every PancakeSwap call is the same three commands: swap, sweep, and wrap the router's ether (SV-1).
    uint256 private constant PANCAKE_COMMANDS = 3;

    /// @dev Where a leg swaps.
    enum Venue {
        UniswapV3,
        UniswapV4,
        PancakeV3
    }

    /// @dev One V3 hop of a burn leg: what it sells, into what, and the least it must produce.
    struct Hop {
        address tokenIn;
        address tokenOut;
        uint256 given;
        uint256 minOut;
    }

    /// @param pancakeRouter PancakeSwap's v3 Universal Router, or zero for a zap without PancakeSwap legs (a testnet
    ///        has none). The deployment scripts pin mainnet's.
    constructor(IIndexFactory factory, IUniversalRouter router, IPancakeUniversalRouter pancakeRouter) {
        if (address(factory) == address(0) || address(router) == address(0)) revert ZeroAddress();
        FACTORY = factory;
        ROUTER = router;
        PANCAKE_ROUTER = pancakeRouter;
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
        IIndexHub(p.index).issue(p.shares, p.to);
    }

    /// @dev Buys every component that is not `tokenIn`, approves the index for the whole basket and
    ///      returns the amount of `tokenIn` that the basket holds directly.
    function _buyBasket(MintParams calldata p) private returns (uint256) {
        address[] memory tokens = IIndexHub(p.index).componentTokens();
        uint256 n = tokens.length;
        if (p.legs.length != n) revert LegCountMismatch();
        uint256[] memory need = IIndexHub(p.index).previewIssue(p.shares);

        uint256 reserved = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == p.tokenIn) reserved = need[i];
        }
        if (reserved > p.maxAmountIn) revert InsufficientBudget(reserved, p.maxAmountIn);

        uint256 spent = reserved;
        for (uint256 i = 0; i < n; ++i) {
            address component = tokens[i];
            if (component == p.tokenIn) {
                if (_namesAVenue(p.legs[i].v3Path, p.legs[i].v4Path, p.legs[i].pancakePath)) revert BadRoute(i);
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
    ///      anything and never has an allowance here to spend later. `amountOut` is never zero, which matters because
    ///      zero is the V4 router's open-delta sentinel in the swap-amount position too, meaning "the full debt": it
    ///      is `ceil(shares * units / 1e18)` with non-zero shares, and every component's units are at least one raw
    ///      unit, since they start at MIN_RAW_UNITS or more and a rebalance rounds every new unit up (CR-I05).
    function _buy(MintParams calldata p, address component, uint256 amountOut, uint256 budget, uint256 i)
        private
        returns (uint256 amountIn)
    {
        MintLeg calldata leg = p.legs[i];
        Venue venue = _checkRoute(leg.v3Path, leg.v4Path, leg.pancakePath, component, p.tokenIn, true, i);
        uint256 cap = leg.maxAmountIn != 0 && leg.maxAmountIn < budget ? leg.maxAmountIn : budget;

        IERC20 tokenIn = IERC20(p.tokenIn);
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = IERC20(component).balanceOf(address(this));
        _swapExactOut(leg, venue, p.tokenIn, component, amountOut, cap);

        // The router reports nothing, so both sides are measured here. The pinned V4 router does not check that an
        // exact-output swap delivered, and a short fill would otherwise surface as an opaque failure inside issue().
        uint256 delivered = IERC20(component).balanceOf(address(this)) - outBefore;
        if (delivered < amountOut) revert ShortFill(i, delivered, amountOut);
        amountIn = Math.saturatingSub(inBefore, tokenIn.balanceOf(address(this)));
    }

    /// @dev Pre-funds the leg's router with `cap` of `tokenIn` and buys exactly `amountOut` of `component` on `venue`,
    ///      sweeping back in the same call whatever the swap did not spend.
    function _swapExactOut(
        MintLeg calldata leg,
        Venue venue,
        address tokenIn,
        address component,
        uint256 amountOut,
        uint256 cap
    ) private {
        bool pancake = venue == Venue.PancakeV3;
        IERC20(tokenIn).safeTransfer(_routerFor(pancake), cap);
        if (venue != Venue.UniswapV4) {
            bytes calldata path = pancake ? leg.pancakePath : leg.v3Path;
            _swapV3(pancake, true, abi.encode(address(this), amountOut, cap, path, false), tokenIn);
            return;
        }
        bytes[] memory inputs = new bytes[](2);
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
        inputs[1] = abi.encode(tokenIn, address(this), SWEEP_NO_MINIMUM);
        ROUTER.execute(abi.encodePacked(Cmd.V4_SWAP, Cmd.SWEEP), inputs);
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
        address[] memory tokens = IIndexHub(p.index).componentTokens();
        if (p.legs.length != tokens.length) revert LegCountMismatch();

        IERC20 tokenOut = IERC20(p.tokenOut);
        uint256 outBefore = tokenOut.balanceOf(address(this));
        IERC20(p.index).safeTransferFrom(msg.sender, address(this), p.shares);
        // redeem() rounds down deterministically, so the preview is the exact amount received.
        uint256[] memory got = IIndexHub(p.index).previewRedeem(p.shares);
        // The basket has to be in hand before it can be sold, so this interaction cannot be the last
        // one. The function is nonReentrant and the zap keeps no state; Wake's reentrancy detector
        // does not model reentrancy guards, hence the suppression.
        // wake-disable-next-line reentrancy
        IIndexHub(p.index).redeem(p.shares, address(this));

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
                if (_namesAVenue(p.legs[i].v3Path, p.legs[i].v4Path, p.legs[i].pancakePath)) revert BadRoute(i);
                // The pass-through leg carries no swap, but its limit is still the caller's and is still checked, so
                // every leg honours the limit its NatSpec promises (DA-15).
                if (got[i] < p.legs[i].minAmountOut) revert InsufficientOutput(got[i], p.legs[i].minAmountOut);
                continue;
            }
            // Every leg is validated, including one that sells nothing, whose minimum then cannot be met.
            BurnLeg calldata leg = p.legs[i];
            Venue venue = _checkRoute(leg.v3Path, leg.v4Path, leg.pancakePath, component, p.tokenOut, false, i);
            if (got[i] != 0) {
                if (venue == Venue.UniswapV4) {
                    _sellV4(p, component, got[i], i);
                } else {
                    _sellV3(p, component, got[i], i, venue == Venue.PancakeV3);
                }
            } else if (p.legs[i].minAmountOut != 0) {
                revert InsufficientOutput(0, p.legs[i].minAmountOut);
            }
        }
    }

    /// @dev Sells `amountIn` of `component` along the leg's V3 path, Uniswap's or PancakeSwap's, one hop at a time. A
    ///      V3 pool can stop at its price limit and take less than the input of any hop. A multi-hop call would hide
    ///      that on every hop after the first, so each hop is swapped on its own and its unsold input is measured and
    ///      returned. The leg's minimum applies to the last hop's output; the overall minimum bounds the whole burn.
    function _sellV3(BurnParams calldata p, address component, uint256 amountIn, uint256 i, bool pancake) private {
        BurnLeg calldata leg = p.legs[i];
        bytes calldata path = pancake ? leg.pancakePath : leg.v3Path;
        address hopIn = component;
        uint256 given = amountIn;
        while (true) {
            bool last = path.length == PathLib.ADDR_SIZE + PathLib.HOP_SIZE;
            address hopOut = address(bytes20(path[PathLib.HOP_SIZE:PathLib.HOP_SIZE + PathLib.ADDR_SIZE]));
            uint256 produced = _v3Hop(
                p,
                path[:PathLib.ADDR_SIZE + PathLib.HOP_SIZE],
                Hop({tokenIn: hopIn, tokenOut: hopOut, given: given, minOut: last ? leg.minAmountOut : 0}),
                pancake
            );
            if (last) return;
            // A hop that produced nothing has nothing to hand the next one, and the leg cannot complete.
            if (produced == 0) revert InsufficientOutput(0, leg.minAmountOut);
            (hopIn, given) = (hopOut, produced);
            path = path[PathLib.HOP_SIZE:];
        }
    }

    /// @dev One V3 hop: pre-fund the router, swap, sweep it clean, and return what arrived. The unsold input goes back
    ///      to the recipient rather than staying where anyone could sweep it. What the sweep brought back is measured
    ///      directly, as the balance above what was left once the router had been pre-funded: the sweep only ever adds
    ///      to it, so this cannot underflow whatever the router held beforehand (CR-L02).
    function _v3Hop(BurnParams calldata p, bytes calldata hopPath, Hop memory hop, bool pancake)
        private
        returns (uint256 produced)
    {
        IERC20 token = IERC20(hop.tokenIn);
        uint256 inBefore = token.balanceOf(address(this));
        uint256 outBefore = IERC20(hop.tokenOut).balanceOf(address(this));
        token.safeTransfer(_routerFor(pancake), hop.given);

        _swapV3(pancake, false, abi.encode(address(this), hop.given, hop.minOut, hopPath, false), hop.tokenIn);

        produced = IERC20(hop.tokenOut).balanceOf(address(this)) - outBefore;
        _returnUnsold(p, hop.tokenIn, token.balanceOf(address(this)) + hop.given - inBefore);
    }

    /// @dev Runs one V3 swap, whose input `swapInput` has the layout both routers share, on Uniswap's router or
    ///      PancakeSwap's, then sweeps `sweepToken` back here. On PancakeSwap's router the call ends with WRAP_ETH of the
    ///      router's whole ether balance, kept there, so its end-of-call ether refund has nothing to send to this
    ///      contract, which cannot receive it (SV-1). The router was pre-funded with exactly what the swap may spend.
    function _swapV3(bool pancake, bool exactOut, bytes memory swapInput, address sweepToken) private {
        bytes memory sweep = abi.encode(sweepToken, address(this), SWEEP_NO_MINIMUM);
        if (!pancake) {
            bytes[] memory inputs = new bytes[](2);
            (inputs[0], inputs[1]) = (swapInput, sweep);
            ROUTER.execute(abi.encodePacked(exactOut ? Cmd.V3_SWAP_EXACT_OUT : Cmd.V3_SWAP_EXACT_IN, Cmd.SWEEP), inputs);
            return;
        }
        bytes[] memory pancakeInputs = new bytes[](PANCAKE_COMMANDS);
        (pancakeInputs[0], pancakeInputs[1]) = (swapInput, sweep);
        pancakeInputs[2] = abi.encode(PCmd.ADDRESS_THIS, PCmd.CONTRACT_BALANCE);
        PANCAKE_ROUTER.execute(
            abi.encodePacked(exactOut ? PCmd.V3_SWAP_EXACT_OUT : PCmd.V3_SWAP_EXACT_IN, PCmd.SWEEP, PCmd.WRAP_ETH),
            pancakeInputs
        );
    }

    /// @dev The router a V3 leg runs through.
    function _routerFor(bool pancake) private view returns (address) {
        return pancake ? address(PANCAKE_ROUTER) : address(ROUTER);
    }

    /// @dev Sells `amountIn` of `component` along the leg's V4 route as one swap. Every intermediate currency, native
    ///      ether included, nets inside the pool manager: an intermediate hop that filled short would leave a credit
    ///      the unlock refuses to close, so the leg reverts whole rather than stranding a middle token here. The first
    ///      hop can leave unsold input, and so can a later hop whose input is the component again, whose leftover nets
    ///      against the leg's own debt (CR-I07); the sweep returns both, measured as in `_v3Hop` (CR-L02).
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

        _returnUnsold(p, component, token.balanceOf(address(this)) + amountIn - inBefore);
    }

    /// @dev Sends back what a hop did not sell, together with any balance of it the router already held. Unsold
    ///      `tokenOut` stays here: the payout is measured as this contract's `tokenOut` balance change, so it reaches
    ///      the recipient with the rest of the proceeds instead of being paid out twice.
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
        // Tokens left in either router can be swept by anyone, and anything sent to the pool manager is a donation. The
        // factory can never move a token on either, so a burn paid to it is lost (RT-21). A zero PancakeSwap router
        // adds nothing here: a zero recipient was refused above.
        if (
            to == address(this) || to == index || to == address(ROUTER) || to == POOL_MANAGER || to == address(FACTORY)
                || to == address(PANCAKE_ROUTER)
        ) revert InvalidRecipient(to);
    }

    function _checkNonce(address index, uint256 expectedNonce) private view {
        uint256 nonce = IIndexHub(index).rebalanceNonce();
        if (nonce != expectedNonce) revert StaleRebalanceNonce(expectedNonce, nonce);
    }

    /// @dev Whether a leg names any venue at all; the pass-through leg must name none.
    function _namesAVenue(bytes calldata v3Path, PathKey[] calldata v4Path, bytes calldata pancakePath)
        private
        pure
        returns (bool)
    {
        return v3Path.length != 0 || v4Path.length != 0 || pancakePath.length != 0;
    }

    /// @dev A leg names exactly one venue, and its route has to reach from the component to the user's token. A V3
    ///      path, Uniswap's or PancakeSwap's, is checked at both ends. The `component` end of a V4 route is the zap's
    ///      own argument rather than the caller's, so only the far end needs checking; which entry that is depends on
    ///      the direction the router walks the route, from the front for an exact input and from the back for an exact
    ///      output. A PancakeSwap path needs a PancakeSwap router, which a testnet zap may not have.
    /// @param exactOut True for a mint leg, whose route the router walks backwards.
    /// @return venue Where the leg swaps.
    function _checkRoute(
        bytes calldata v3Path,
        PathKey[] calldata v4Path,
        bytes calldata pancakePath,
        address component,
        address userToken,
        bool exactOut,
        uint256 i
    ) private view returns (Venue venue) {
        bool isV3 = v3Path.length != 0;
        bool isV4 = v4Path.length != 0;
        bool isPancake = pancakePath.length != 0;
        // Exactly one: not none, and not two or three.
        if ((isV3 ? 1 : 0) + (isV4 ? 1 : 0) + (isPancake ? 1 : 0) != 1) revert BadRoute(i);
        if (isV4) {
            _checkV4Route(v4Path, userToken, exactOut, i);
            return Venue.UniswapV4;
        }
        if (isPancake && address(PANCAKE_ROUTER) == address(0)) revert BadRoute(i);
        _checkV3Path(isPancake ? pancakePath : v3Path, component, userToken, i);
        return isPancake ? Venue.PancakeV3 : Venue.UniswapV3;
    }

    /// @dev A packed V3 path, Uniswap's or PancakeSwap's, runs from the component to the user's token.
    function _checkV3Path(bytes calldata path, address component, address userToken, uint256 i) private pure {
        if (!path.isValidShape() || path.firstToken() != component || path.lastToken() != userToken) {
            revert BadRoute(i);
        }
    }

    /// @dev A hook is arbitrary code running inside the swap, able to move the deltas the zap is measuring; a hookless
    ///      key also cannot carry a dynamic fee, so this one equality is the whole check. Native ether is allowed as an
    ///      intermediate currency and never as an endpoint, which the far end's equality settles.
    function _checkV4Route(PathKey[] calldata v4Path, address userToken, bool exactOut, uint256 i) private pure {
        for (uint256 h = 0; h < v4Path.length; ++h) {
            if (v4Path[h].hooks != address(0) || v4Path[h].hookData.length != 0) revert BadRoute(i);
        }
        uint256 far = exactOut ? 0 : v4Path.length - 1;
        if (v4Path[far].intermediateCurrency != userToken) revert BadRoute(i);
    }
}
