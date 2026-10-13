// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWeightedHub} from "xindex/src/interfaces/IWeightedHub.sol";
import {IWeightedIndexFactory} from "xindex/src/interfaces/IWeightedIndexFactory.sol";
import {IRebalanceExecutor} from "xindex/src/interfaces/IRebalanceExecutor.sol";
import {PathLib} from "xindex/src/libraries/PathLib.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";

/// @title KeeperExecutor
/// @notice The keeper bot's executor for `WeightedHub` auctions. It sells what an index sends out into USDC and buys
///         what the index needs with USDC, through Uniswap V3 along the routes the bot passes with each fill, and it
///         serves a coin with no route from its own inventory: it delivers that coin from stock and keeps that coin
///         when the index sells it. A fill reverts unless the USDC float ends at least `minUsdcDelta` above where it
///         started, so a swap moved against the bot's simulation cannot cost more than the bot accepted.
/// @dev Two keys. The keeper, a hot key, only fills: it can reach no index the factory did not create, so it cannot
///      route the inventory to a contract of its own, but it can trade the float badly within the floor it sets.
///      The owner, a cold key, withdraws and rotates the keeper. The executor holds no role in the protocol: filling
///      an auction is open to anyone.
contract KeeperExecutor is IRebalanceExecutor {
    /// @notice Uniswap's SwapRouter02.
    IV3SwapRouter public immutable ROUTER;
    /// @notice The float's currency, and the end of every route.
    address public immutable USDC;
    /// @notice The factory whose indexes this executor fills.
    IWeightedIndexFactory public immutable FACTORY;
    /// @notice Withdraws and rotates the keeper.
    address public immutable OWNER;
    /// @notice The only account that fills.
    address public keeper;
    /// @dev The index being filled, for its callback only.
    address private transient _filling;

    /// @notice The keeper changed from `previous` to `next`.
    event KeeperSet(address indexed previous, address indexed next);

    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice `caller` is not the owner.
    error NotOwner(address caller);
    /// @notice `caller` is not the keeper.
    error NotKeeper(address caller);
    /// @notice The fill was mined after `deadline`, the one block its price update is valid in.
    error Expired(uint256 deadline);
    /// @notice `index` was not created by the factory.
    error NotIndex(address index);
    /// @notice The routes do not number one per component.
    error LengthMismatch();
    /// @notice `token`'s route is not a path from `token` to USDC, or names USDC itself.
    error BadRoute(address token);
    /// @notice The index needs more of `token` than the executor holds, and `token` has no route to buy the rest.
    error NoRoute(address token);
    /// @notice `caller` called back outside a fill of its own.
    error UnexpectedCaller(address caller);
    /// @notice The fill changed the float by `usdcDelta`, below `minUsdcDelta`.
    error TooCostly(int256 usdcDelta, int256 minUsdcDelta);

    constructor(IV3SwapRouter router, address usdc, IWeightedIndexFactory factory, address owner, address keeper_) {
        if (
            address(router) == address(0) || usdc == address(0) || address(factory) == address(0) || owner == address(0)
                || keeper_ == address(0)
        ) revert ZeroAddress();
        ROUTER = router;
        USDC = usdc;
        FACTORY = factory;
        OWNER = owner;
        keeper = keeper_;
        emit KeeperSet(address(0), keeper_);
        SafeERC20.forceApprove(IERC20(usdc), address(router), type(uint256).max);
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /// @notice Owner only. Makes `next` the keeper.
    function setKeeper(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        address previous = keeper;
        keeper = next;
        emit KeeperSet(previous, next);
    }

    /// @notice Owner only. Sends `amount` of `token`, float or inventory, to `to`.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    /// @notice Keeper only. Fills `index`'s auction with `priceUpdate`, forwarding all of msg.value to Pyth as its fee.
    /// @param routes One per component: an exact-input Uniswap V3 path from the component to USDC, which read as an
    ///        exact-output path buys the component with USDC; empty for a coin served from inventory, and for USDC.
    /// @param maxAmountsIn Passed to the hub: the fill reverts if the index asks for more of any component.
    /// @param minUsdcDelta The least the USDC float may change by: negative accepts a cost, positive requires a gain.
    /// @param deadline The latest block timestamp the fill may be mined at.
    /// @return usdcDelta What the fill changed the float by.
    /// @return gasUsed The gas the call used inside this function, for the bot's simulation.
    function fill(
        IWeightedHub index,
        bytes[] calldata priceUpdate,
        bytes[] calldata routes,
        uint256[] calldata maxAmountsIn,
        int256 minUsdcDelta,
        uint256 deadline
    ) external payable returns (int256 usdcDelta, uint256 gasUsed) {
        uint256 gasStart = gasleft();
        _checkKeeper();
        if (block.timestamp > deadline) revert Expired(deadline);
        if (!FACTORY.isIndex(address(index))) revert NotIndex(address(index));
        _checkRoutes(index.componentTokens(), routes);

        uint256 before = IERC20(USDC).balanceOf(address(this));
        // Transient, for this transaction's callback only: an event per fill would say nothing the hub's does not.
        // forge-lint: disable-next-line(missing-events-access-control)
        _filling = address(index);
        // `index` is one the factory created, checked above, and msg.value is Pyth's fee, which the hub forwards whole.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        index.executeRebalance{value: msg.value}(abi.encode(routes), priceUpdate, maxAmountsIn);
        // forge-lint: disable-next-line(missing-events-access-control)
        _filling = address(0);
        usdcDelta = SafeCast.toInt256(IERC20(USDC).balanceOf(address(this))) - SafeCast.toInt256(before);
        if (usdcDelta < minUsdcDelta) revert TooCostly(usdcDelta, minUsdcDelta);
        gasUsed = gasStart - gasleft();
    }

    /// @inheritdoc IRebalanceExecutor
    /// @dev Sells each routed component the index sent out, keeps each unrouted one, then delivers each component the
    ///      index needs from stock, buying only the shortfall. A USDC component, which no listing allows today, comes
    ///      out of and goes into the float itself.
    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata data)
        external
    {
        if (msg.sender != _filling) revert UnexpectedCaller(msg.sender);
        bytes[] memory routes = abi.decode(data, (bytes[]));
        address[] memory tokens = IWeightedHub(msg.sender).componentTokens();
        uint256 n = tokens.length;

        for (uint256 i = 0; i < n; ++i) {
            uint256 out = amountsOut[i];
            // A zero amountIn would make the router swap its own balance instead.
            if (out == 0 || routes[i].length == 0) continue;
            SafeERC20.forceApprove(IERC20(tokens[i]), address(ROUTER), out);
            // What a swap returns is not needed: the fill measures the float as a whole against its floor.
            // forge-lint: disable-next-item(unused-return)
            ROUTER.exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: routes[i], recipient: address(this), amountIn: out, amountOutMinimum: 0
                })
            );
        }

        for (uint256 i = 0; i < n; ++i) {
            uint256 need = amountsIn[i];
            if (need == 0) continue;
            address token = tokens[i];
            uint256 held = IERC20(token).balanceOf(address(this));
            if (held < need) {
                // USDC has no route, so a float too short for a USDC component also ends here.
                if (routes[i].length == 0) revert NoRoute(token);
                // forge-lint: disable-next-item(unused-return)
                ROUTER.exactOutput(
                    IV3SwapRouter.ExactOutputParams({
                        path: routes[i],
                        recipient: address(this),
                        amountOut: need - held,
                        amountInMaximum: IERC20(USDC).balanceOf(address(this))
                    })
                );
            }
            SafeERC20.safeTransfer(IERC20(token), msg.sender, need);
        }
    }

    /// @dev One route per component, each empty or a well-formed path from its component to USDC; USDC takes none.
    function _checkRoutes(address[] memory tokens, bytes[] calldata routes) private view {
        uint256 n = tokens.length;
        if (routes.length != n) revert LengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            bytes calldata route = routes[i];
            if (route.length == 0) continue;
            if (
                tokens[i] == USDC || !PathLib.isValidShape(route) || PathLib.firstToken(route) != tokens[i]
                    || PathLib.lastToken(route) != USDC
            ) revert BadRoute(tokens[i]);
        }
    }

    function _checkOwner() private view {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
    }

    function _checkKeeper() private view {
        if (msg.sender != keeper) revert NotKeeper(msg.sender);
    }
}
