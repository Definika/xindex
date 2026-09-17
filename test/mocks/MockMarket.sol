// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIndexFactory} from "../../src/interfaces/IIndexFactory.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./MockUniswapV3.sol";

/// @dev Minimum liquidity `MockMarket.configWith` gives a pooled token: a tenth of a mock pool's default liquidity, the
///      policy the mainnet list uses. File-level so pure test helpers can use it.
uint128 constant DEFAULT_MIN_LIQUIDITY = 1e17;

/// @notice WETH, USDC, a Uniswap V3 factory and pools for tests. Prices are set as ticks in token terms:
///         `tick` means 1.0001^tick raw WETH units per raw unit of the token, whichever side of its pool it sits on.
contract MockMarket {
    uint24 public constant TOKEN_POOL_FEE = 3000;
    uint24 public constant USD_POOL_FEE = 500;
    /// @notice Reference supply `config` gives WETH, which needs one.
    uint256 public constant ETH_SUPPLY = 120_000_000e18;
    /// @notice Reference supply `config` gives every other token, so tests can list tokens nobody has minted yet.
    uint256 public constant DEFAULT_SUPPLY = 1e30;
    /// @notice About 3,000 USDC per ETH: 1.0001^196_257 is close to 1e18 / 3000e6 raw WETH per raw USDC.
    int24 public constant USDC_TICK = 196_257;
    /// @notice Minimum liquidity `configWith` gives a pooled token.
    uint128 public constant MIN_LIQUIDITY = DEFAULT_MIN_LIQUIDITY;

    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;
    MockUniswapV3Factory public immutable uniswapV3Factory;
    MockUniswapV3Pool public immutable usdPool;

    constructor() {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        uniswapV3Factory = new MockUniswapV3Factory();
        usdPool = MockUniswapV3Pool(uniswapV3Factory.createPool(address(usdc), address(weth), USD_POOL_FEE));
        _setTick(usdPool, address(usdc), USDC_TICK);
    }

    /// @notice `token`'s 0.3% WETH pool, or zero before `config` created it.
    function tokenPool(address token) public view returns (MockUniswapV3Pool) {
        return MockUniswapV3Pool(uniswapV3Factory.getPool(token, address(weth), TOKEN_POOL_FEE));
    }

    /// @notice Sets `token`'s price in its 0.3% WETH pool, in token terms.
    function setPriceTick(address token, int24 tick) public {
        _setTick(tokenPool(token), token, tick);
    }

    /// @notice Sets USDC's price in the USD pool, in token terms.
    function setUsdcTick(int24 tick) external {
        _setTick(usdPool, address(usdc), tick);
    }

    /// @notice A listing config for `token` priced at `tick`, with a reference supply.
    function config(address token, int24 tick) external returns (IIndexFactory.TokenConfig memory) {
        return configWith(token, tick, token == address(weth) ? ETH_SUPPLY : DEFAULT_SUPPLY, new address[](0));
    }

    /// @notice A listing config with an explicit supply definition. Any token but WETH gets its 0.3% WETH pool, created
    ///         on first use and priced at `tick`.
    function configWith(address token, int24 tick, uint256 referenceSupply, address[] memory excluded)
        public
        returns (IIndexFactory.TokenConfig memory c)
    {
        c.referenceSupply = referenceSupply;
        c.excluded = excluded;
        if (token == address(weth)) return c;
        if (address(tokenPool(token)) == address(0)) {
            uniswapV3Factory.createPool(token, address(weth), TOKEN_POOL_FEE);
        }
        setPriceTick(token, tick);
        c.pool = address(tokenPool(token));
        c.minLiquidity = MIN_LIQUIDITY;
    }

    function _setTick(MockUniswapV3Pool pool, address token, int24 tick) private {
        pool.setTick(token < address(weth) ? tick : -tick);
    }
}
