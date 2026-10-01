// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {IIndexHub} from "../../src/interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "../../src/interfaces/IRebalanceExecutor.sol";
import {ISwapRouter02} from "../mocks/ISwapRouter02.sol";

/// @notice Fills rebalance auctions through Uniswap V3 on a mainnet fork, the way a searcher would: it sells what the
///         index sends into WETH, buys what the index needs with WETH, and settles the difference from a WETH float.
/// @dev Test fixture, not a production executor. Its swaps have no slippage limits, so a sandwich takes the float:
///      never fund it on mainnet. Only its deployer starts a fill or sets fee tiers, `fill` settles only an index the
///      factory registered, and the callback is accepted only from the index that fill is settling. A contract posing
///      as an index therefore cannot pull the float, neither by calling back on its own nor by having `fill` pointed
///      at it (LR-04).
contract RebalanceExecutorV3 is IRebalanceExecutor {
    using SafeERC20 for IERC20;

    IIndexFactory public immutable FACTORY;
    ISwapRouter02 public immutable ROUTER;
    address public immutable WETH;
    address public immutable OWNER;
    mapping(address token => uint24 fee) public feeOf;

    /// @dev The index `fill` is settling, zero outside a fill.
    address private _filling;

    error NotOwner(address caller);
    error NotIndex(address index);
    error UnexpectedCaller(address caller);

    constructor(IIndexFactory factory, ISwapRouter02 router, address weth) {
        FACTORY = factory;
        ROUTER = router;
        WETH = weth;
        OWNER = msg.sender;
        IERC20(weth).forceApprove(address(router), type(uint256).max);
    }

    /// @notice Deployer only. Fee tier of `token`'s WETH pool to trade through.
    function setFee(address token, uint24 fee) external {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        feeOf[token] = fee;
        IERC20(token).forceApprove(address(ROUTER), type(uint256).max);
    }

    /// @notice Deployer only. Settles the auction of `index`, one of the factory's indexes, at the current λ.
    function fill(IIndexHub index) external {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        if (!FACTORY.isIndex(address(index))) revert NotIndex(address(index));
        _filling = address(index);
        index.executeRebalance("");
        _filling = address(0);
    }

    function onXindexRebalance(uint256[] calldata amountsOut, uint256[] calldata amountsIn, bytes calldata) external {
        if (msg.sender != _filling) revert UnexpectedCaller(msg.sender);
        address[] memory tokens = IIndexHub(msg.sender).componentTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsOut[i] == 0 || tokens[i] == WETH) continue;
            ROUTER.exactInput(
                ISwapRouter02.ExactInputParams({
                    path: abi.encodePacked(tokens[i], feeOf[tokens[i]], WETH),
                    recipient: address(this),
                    amountIn: amountsOut[i],
                    amountOutMinimum: 0
                })
            );
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (amountsIn[i] == 0) continue;
            if (tokens[i] != WETH) {
                ROUTER.exactOutput(
                    ISwapRouter02.ExactOutputParams({
                        path: abi.encodePacked(tokens[i], feeOf[tokens[i]], WETH),
                        recipient: address(this),
                        amountOut: amountsIn[i],
                        amountInMaximum: IERC20(WETH).balanceOf(address(this))
                    })
                );
            }
            IERC20(tokens[i]).safeTransfer(msg.sender, amountsIn[i]);
        }
    }
}
