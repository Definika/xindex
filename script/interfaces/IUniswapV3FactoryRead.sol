// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IUniswapV3FactoryRead
/// @notice Minimal subset of the Uniswap V3 factory: the lookup the Sepolia test-market script and `CheckToken` make.
/// @dev Mainnet: 0x1F98431c8aD98523631AE4a59f267346ea31F984
interface IUniswapV3FactoryRead {
    /// @notice The pool for a token pair and fee tier, or zero if none exists. Token order does not matter.
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token.
    /// @param fee Fee tier in hundredths of a basis point.
    /// @return pool The pool this factory deployed, or zero.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
