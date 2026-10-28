// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice WETH and USDC for tests, and the reference supplies tests list tokens with. Nothing in Xindex reads a price,
///         so the market carries none.
contract MockMarket {
    /// @notice Reference supply tests list WETH with, ether's.
    uint256 public constant ETH_SUPPLY = 120_000_000e18;
    /// @notice Reference supply tests list every other token with, so they can list tokens nobody has minted yet.
    uint256 public constant DEFAULT_SUPPLY = 1e30;

    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;

    constructor() {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    /// @notice The supply tests list `token` with: ether's for WETH, DEFAULT_SUPPLY for anything else.
    function supplyOf(address token) external view returns (uint256) {
        return token == address(weth) ? ETH_SUPPLY : DEFAULT_SUPPLY;
    }
}
