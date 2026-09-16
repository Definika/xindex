// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @notice The Uniswap V3 factory call the testnet market script uses to create pools.
interface IUniswapV3FactorySetup {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}
