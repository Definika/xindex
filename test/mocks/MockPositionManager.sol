// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager} from "../../script/interfaces/INonfungiblePositionManager.sol";

/// @notice NonfungiblePositionManager stand-in: `mint` takes both desired amounts in full and records the call.
contract MockPositionManager {
    using SafeERC20 for IERC20;

    uint256 public mints;
    mapping(uint256 tokenId => INonfungiblePositionManager.MintParams params) internal _positions;

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
        tokenId = ++mints;
        _positions[tokenId] = params;
        return (tokenId, 1, params.amount0Desired, params.amount1Desired);
    }

    /// @notice The parameters position `tokenId` was minted with.
    function position(uint256 tokenId) external view returns (INonfungiblePositionManager.MintParams memory) {
        return _positions[tokenId];
    }
}
