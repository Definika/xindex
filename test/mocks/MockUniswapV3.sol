// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Uniswap V3 pool stand-in for the Sepolia test-market script, which still creates real V3 pools for the
///         zap's V3 routes. The rule no longer reads a pool at all, so nothing here models an oracle: there is no
///         observation ring, no cumulative accumulator and no cardinality.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    uint160 public sqrtPriceX96;
    int24 public tick;
    /// @notice The liquidity active at the price, which `CheckToken` reads to record depth.
    uint128 public liquidity;

    constructor(address tokenA, address tokenB, uint24 fee_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    /// @notice Pool tick: log base 1.0001 of token1 raw units per token0 raw unit.
    function setTick(int24 tick_) external {
        tick = tick_;
    }

    /// @notice Moves the current price, as a swap through the pool would; the tick stays whatever `setTick` set.
    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    /// @notice Records the starting price once, like the real pool; the tick stays whatever `setTick` set.
    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "AI");
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

/// @notice Registry of mock pools that answers `getPool` in either token order, like the real factory.
contract MockUniswapV3Factory {
    mapping(address tokenA => mapping(address tokenB => mapping(uint24 fee => address pool))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        pool = address(new MockUniswapV3Pool(tokenA, tokenB, fee));
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}
