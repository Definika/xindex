// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWeightedHub} from "xindex/src/interfaces/IWeightedHub.sol";
import {IRebalanceExecutor} from "xindex/src/interfaces/IRebalanceExecutor.sol";
import {ISwapRouter02} from "xindex/test/mocks/ISwapRouter02.sol";

/// @title KeeperExecutor
/// @notice The rebalancer bot's executor for v5's Ethereum-only indexes (`WeightedHub`): it fills an auction through
///         Uniswap V3, selling what the index sends out into USDC and buying what it needs with USDC, each along the
///         route its owner set, and refuses the whole fill when it would cost its USDC float more than the bot allowed.
/// @dev DRAFT, untested (2026-10-06). Only its owner fills, sets routes or withdraws; the callback is accepted only from
///      the index being filled. The swaps carry no limit of their own: `maxCost` bounds the fill as a whole, so a
///      sandwich can cost at most that before the fill reverts. Keep the float small.
contract KeeperExecutor is IRebalanceExecutor {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable ROUTER;
    address public immutable USDC;
    address public immutable OWNER;
    /// @notice A token's exact-input path to USDC; read backwards, the same bytes buy it with USDC.
    mapping(address token => bytes path) public routeOf;
    address private _filling;

    error NotOwner(address caller);
    error UnexpectedCaller(address caller);
    error NoRoute(address token);
    /// @notice The fill cost the float `cost` of USDC, more than `maxCost`.
    error TooCostly(uint256 cost, uint256 maxCost);

    constructor(ISwapRouter02 router, address usdc) {
        ROUTER = router;
        USDC = usdc;
        OWNER = msg.sender;
        IERC20(usdc).forceApprove(address(router), type(uint256).max);
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Owner only. `token`'s exact-input path to USDC.
    function setRoute(address token, bytes calldata path) external onlyOwner {
        routeOf[token] = path;
        IERC20(token).forceApprove(address(ROUTER), type(uint256).max);
    }

    /// @notice Owner only. Takes `amount` of `token` out, the float included.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Owner only. Fills `index`'s auction with `priceUpdate`, paying Pyth's fee from msg.value, and reverts
    ///         when the float ends more than `maxCost` USDC lower than it started; a profit is kept.
    function fill(IWeightedHub index, bytes[] calldata priceUpdate, uint256 maxCost) external payable onlyOwner {
        uint256 before = IERC20(USDC).balanceOf(address(this));
        _filling = address(index);
        index.executeRebalance{value: msg.value}("", priceUpdate);
        _filling = address(0);
        uint256 afterwards = IERC20(USDC).balanceOf(address(this));
        if (afterwards < before && before - afterwards > maxCost) revert TooCostly(before - afterwards, maxCost);
    }

    /// @inheritdoc IRebalanceExecutor
    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata) external {
        if (msg.sender != _filling) revert UnexpectedCaller(msg.sender);
        address[] memory tokens = IWeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsOut[i] == 0 || tokens[i] == USDC) continue;
            bytes memory path = routeOf[tokens[i]];
            if (path.length == 0) revert NoRoute(tokens[i]);
            ROUTER.exactInput(
                ISwapRouter02.ExactInputParams({
                    path: path, recipient: address(this), amountIn: amountsOut[i], amountOutMinimum: 0
                })
            );
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] == 0) continue;
            if (tokens[i] != USDC) {
                bytes memory path = routeOf[tokens[i]];
                if (path.length == 0) revert NoRoute(tokens[i]);
                ROUTER.exactOutput(
                    ISwapRouter02.ExactOutputParams({
                        path: path,
                        recipient: address(this),
                        amountOut: amountsIn[i],
                        amountInMaximum: IERC20(USDC).balanceOf(address(this))
                    })
                );
            }
            IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}
