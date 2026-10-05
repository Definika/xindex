// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";

/// @notice Fills a `WeightedHub` rebalance through Uniswap V3 on a mainnet fork, the way a searcher would: it sells
///         what the index sends into USDC along each component's route, buys what the index needs with USDC along the
///         same route, and settles the difference from a USDC float.
/// @dev Test fixture, not a production executor: its swaps have no slippage limits, so never fund it on mainnet. A
///      route is an exact-input path from the component to USDC; read backwards, the same bytes are the exact-output
///      path that buys the component with USDC. Only its deployer sets routes or starts a fill, and the callback is
///      accepted only from the index being filled.
contract WeightedExecutorV3 is IRebalanceExecutor {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable ROUTER;
    address public immutable USDC;
    address public immutable OWNER;
    mapping(address token => bytes path) public routeOf;
    address private _filling;

    error NotOwner(address caller);
    error UnexpectedCaller(address caller);

    constructor(ISwapRouter02 router, address usdc) {
        ROUTER = router;
        USDC = usdc;
        OWNER = msg.sender;
        IERC20(usdc).forceApprove(address(router), type(uint256).max);
    }

    /// @notice Deployer only. `token`'s exact-input path to USDC.
    function setRoute(address token, bytes calldata path) external {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        routeOf[token] = path;
        IERC20(token).forceApprove(address(ROUTER), type(uint256).max);
    }

    /// @notice Deployer only. Settles `index`'s auction with `priceUpdate`.
    function fill(IWeightedHub index, bytes[] calldata priceUpdate) external payable {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        _filling = address(index);
        index.executeRebalance{value: msg.value}("", priceUpdate);
        _filling = address(0);
    }

    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata) external {
        if (msg.sender != _filling) revert UnexpectedCaller(msg.sender);
        address[] memory tokens = IWeightedHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsOut[i] == 0) continue;
            ROUTER.exactInput(
                ISwapRouter02.ExactInputParams({
                    path: routeOf[tokens[i]], recipient: address(this), amountIn: amountsOut[i], amountOutMinimum: 0
                })
            );
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] == 0) continue;
            ROUTER.exactOutput(
                ISwapRouter02.ExactOutputParams({
                    path: routeOf[tokens[i]],
                    recipient: address(this),
                    amountOut: amountsIn[i],
                    amountInMaximum: IERC20(USDC).balanceOf(address(this))
                })
            );
            IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}
