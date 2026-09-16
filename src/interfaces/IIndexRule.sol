// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IIndexRule
/// @notice Reads on-chain supplies and Uniswap V3 time-weighted prices and applies an index's weighting rule. It is
///         stateless and view-only: it computes rebalance targets for `IIndexToken.startRebalance` and index prices for
///         display, and never moves funds.
/// @dev Prices are 30-minute time-weighted averages against WETH, expressed as WETH wei per 1e18 raw units of a token
///      ("WAD prices"). They shape rebalance targets, and the auction that settles a rebalance sets the level. A
///      snapshot price read low by a factor f on a component the rebalance sells, or high on one it buys, moves the
///      auction's fair multiplier to about 1/f, and below f = 2/3 the first executor takes value from the index.
///      {targetUnits} therefore rejects windows whose liquidity fell below the token's configured minimum or whose
///      sub-window mean ticks disagree. Sustained manipulation through deep liquidity, for example by a validator
///      holding many consecutive slots, is not excluded; the guardian can cancel a snapshot during the notice period.
///      {navPerToken} lags fast moves and can be nudged by multi-block manipulation, so never use it as a collateral
///      oracle.
///
///      Every function that prices a token reads its configured pool, so a token that was never listed has no pool to
///      read and the call reverts without a reason. Uniswap V3 pools revert with "OLD" while they hold less than
///      TWAP_WINDOW of history.
interface IIndexRule is IXindexErrors {
    /// @notice `pool` is not usable for `token`: it has no code, is not the Uniswap V3 factory's WETH pool for `token`
    ///         at its own fee tier, or is set for WETH itself.
    error InvalidPool(address token, address pool);
    /// @notice `pool` keeps `cardinality` observation slots, fewer than MIN_OBSERVATION_CARDINALITY. Anyone can reserve
    ///         more with the pool's `increaseObservationCardinalityNext`; they come into use as the pool writes new
    ///         observations.
    error PoolHistoryTooShort(address pool, uint16 cardinality);
    /// @notice WETH without a reference supply, more than MAX_EXCLUDED or duplicate exclusions, or exclusions together
    ///         with a reference supply.
    error InvalidSupplyConfig(address token);
    /// @notice `minLiquidity` is zero for a token with a pool, or non-zero for WETH.
    error InvalidMinLiquidity(address token);
    /// @notice The pool's harmonic-mean liquidity over TWAP_WINDOW is below the token's configured minimum.
    error ThinPriceHistory(address pool, uint256 harmonicMeanLiquidity, uint256 minLiquidity);
    /// @notice The mean ticks of the window's TWAP_SUB_WINDOWS parts are more than MAX_TICK_DEVIATION apart.
    error PriceHistoryDeviates(address pool, uint256 spread);
    /// @notice The window's mean tick quotes `token` at zero WETH wei per 1e18 raw units.
    error ZeroPrice(address token);
    /// @notice The supply the rule uses for `token` is zero.
    error ZeroSupply(address token);
    /// @notice Nothing is left to weight or rebalance: every market cap is zero, ranks 3 and below of a capped basket
    ///         have none, or the components being rebalanced hold no value, as when the keep mask keeps every one.
    error DegenerateBasket();

    /// @notice Length of the time-weighted average price window.
    function TWAP_WINDOW() external view returns (uint32);

    /// @notice Equal parts of TWAP_WINDOW whose mean ticks a rebalance snapshot compares.
    function TWAP_SUB_WINDOWS() external view returns (uint32);

    /// @notice Largest spread, in ticks, between the highest and lowest sub-window mean tick of a snapshot price.
    function MAX_TICK_DEVIATION() external view returns (uint256);

    /// @notice Observation slots a pool needs so that its filled ring still covers TWAP_WINDOW while blocks are at least
    ///         9.05 seconds apart (a pool writes at most one observation per block). A ring that was just grown holds
    ///         only the history written so far.
    function MIN_OBSERVATION_CARDINALITY() external view returns (uint16);

    /// @notice Most excluded addresses a token config can list.
    function MAX_EXCLUDED() external view returns (uint256);

    /// @notice Largest units the rule raises a component to, so an auction's premium on the increase still fits the
    ///         index's uint96 units. A component whose units already exceed it, or that is kept, can keep larger units;
    ///         its target is then never above its current units, and the multiplier applies only to increases.
    function MAX_TARGET_UNITS() external view returns (uint256);

    /// @notice Fee tier of the USDC/WETH pool used for dollar prices.
    function USD_POOL_FEE() external view returns (uint24);

    /// @notice Factory whose token configs the rule reads.
    function FACTORY() external view returns (address);

    /// @notice Wrapped ether, the currency every WAD price is quoted in. Its own price is 1e18 and needs no pool.
    function WETH() external view returns (address);

    /// @notice Uniswap V3 factory that must have deployed every configured pool.
    function UNISWAP_V3_FACTORY() external view returns (address);

    /// @notice The dollar stablecoin that dollar prices are quoted in, priced from USD_POOL.
    function USDC() external view returns (address);

    /// @notice USDC/WETH pool behind dollar prices.
    function USD_POOL() external view returns (address);

    /// @notice Reverts unless `config` is usable for `token`. WETH needs a reference supply, no pool and no minimum
    ///         liquidity. Any other token needs its WETH pool registered in the Uniswap V3 factory, at least
    ///         MIN_OBSERVATION_CARDINALITY observation slots, enough history for a TWAP_WINDOW average, a non-zero
    ///         `minLiquidity` that the pool's current window meets, and a non-zero supply. A config lists at most
    ///         MAX_EXCLUDED distinct exclusions, and none together with a reference supply.
    /// @param token Token the config is for.
    /// @param config Config to check, as it would be proposed to the factory.
    function checkConfig(address token, IIndexFactory.TokenConfig calldata config) external view;

    /// @notice WETH wei per 1e18 raw units of `token` from its configured pool, averaged over TWAP_WINDOW. WETH is
    ///         1e18 and USDC is priced from USD_POOL. It runs none of the snapshot checks {targetUnits} applies.
    /// @param token A token with a config in force, WETH or USDC.
    /// @return The WAD price.
    function price(address token) external view returns (uint256);

    /// @notice Supply the rule uses for `token`: its reference supply, or its total supply minus excluded balances,
    ///         floored at zero. For a token with no config this is its plain total supply.
    /// @param token Token whose config is read.
    /// @return Supply in the token's raw units.
    function supply(address token) external view returns (uint256);

    /// @notice Weights, with 1e18 meaning 100%, for market caps under `methodology`. Each weight is rounded down, so
    ///         the sum is at most 1e18 and within `caps.length` wei of it.
    /// @param caps Market caps in any common unit, one per component.
    /// @param methodology `Methodology` id.
    /// @return Weight per component, in the order of `caps`.
    function weightsFromCaps(uint256[] calldata caps, uint8 methodology) external pure returns (uint256[] memory);

    /// @notice Current weights, prices and supplies of `tokens` under `methodology`, from plain TWAP prices.
    /// @param tokens Configured tokens, in the order of the returned arrays.
    /// @param methodology `Methodology` id.
    /// @return w Weight per token (1e18 = 100%).
    /// @return prices WAD price per token (WETH wei per 1e18 raw units).
    /// @return supplies Supply per token, in its raw units.
    function weights(address[] calldata tokens, uint8 methodology)
        external
        view
        returns (uint256[] memory w, uint256[] memory prices, uint256[] memory supplies);

    /// @notice Rebalance targets for a basket holding `units` of `tokens`. Components whose bit is set in `keepMask`
    ///         keep their units; the others move toward `methodology`'s weights, rescaled to their share, at an
    ///         unchanged total value at current prices, each clipped to half and double its current units. Every
    ///         component that moves needs a snapshot price: its window's harmonic-mean liquidity at least its
    ///         `minLiquidity` (else ThinPriceHistory) and sub-window mean ticks within MAX_TICK_DEVIATION (else
    ///         PriceHistoryDeviates). Kept components are not read under the uncapped methodology; the capped
    ///         methodology ranks them from a plain TWAP price.
    /// @param tokens Components, in index order.
    /// @param units Current raw units per 1e18 shares, one per component.
    /// @param methodology `Methodology` id.
    /// @param keepMask Bit i set keeps component i's units; bits at or above `tokens.length` are ignored.
    /// @return targets Target units per component.
    /// @return turnover Value the rebalance sells, as a share of the rebalanced components' value (1e18 = 100%).
    function targetUnits(address[] calldata tokens, uint256[] calldata units, uint8 methodology, uint256 keepMask)
        external
        view
        returns (uint256[] memory targets, uint256 turnover);

    /// @notice Value of one whole index token at current time-weighted prices: in WETH wei, and in raw USDC units.
    ///         For display and integrations only; nothing in Xindex reads it.
    /// @param index An index the factory deployed, else NotIndex.
    /// @return wethValue WETH wei per 1e18 shares.
    /// @return usdcValue Raw USDC units (6 decimals) per 1e18 shares.
    function navPerToken(address index) external view returns (uint256 wethValue, uint256 usdcValue);

    /// @notice Starting units that follow `methodology` at current prices for an index worth `startPriceUsdc` raw USDC
    ///         units per token. Each unit is at least 1.
    /// @param tokens Configured tokens, in the order `IIndexFactory.createIndex` will receive them.
    /// @param methodology `Methodology` id.
    /// @param startPriceUsdc Value of one whole index token in raw USDC units, for example 100e6 for 100 dollars.
    /// @return units Raw units per 1e18 shares, one per token, for `IIndexFactory.createIndex`.
    function initialUnits(address[] calldata tokens, uint8 methodology, uint256 startPriceUsdc)
        external
        view
        returns (uint256[] memory units);
}
