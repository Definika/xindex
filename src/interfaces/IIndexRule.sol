// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";

/// @title IIndexRule
/// @notice Reads on-chain supplies and Uniswap V3 time-weighted prices and applies an index's weighting rule. It is
///         stateless and view-only: it computes rebalance targets for `IIndexToken.startRebalance` and index prices for
///         display, and never moves funds.
/// @dev Prices are 30-minute time-weighted averages against WETH, expressed as WETH wei per 1e18 raw units of a token
///      ("WAD prices"). They only shape rebalance targets: the auction that settles a rebalance sets the level, so no
///      price reading can move value. {navPerToken} lags fast moves and can be nudged by multi-block manipulation, so
///      never use it as a collateral oracle.
interface IIndexRule {
    error ZeroAddress();
    error InvalidPool(address token, address pool);
    error PoolHistoryTooShort(address pool, uint16 cardinality);
    error InvalidSupplyConfig(address token);
    error ZeroPrice(address token);
    error ZeroSupply(address token);
    error InvalidMethodology(uint8 methodology);
    error TooFewComponentsForCapped(uint256 count);
    error DegenerateBasket();
    error LengthMismatch();
    error NotIndex(address index);

    /// @notice Length of the time-weighted average price window.
    function TWAP_WINDOW() external view returns (uint32);

    /// @notice Observation slots a pool needs so a TWAP_WINDOW average can never run out of history.
    function MIN_OBSERVATION_CARDINALITY() external view returns (uint16);

    /// @notice Most excluded addresses a token config can list.
    function MAX_EXCLUDED() external view returns (uint256);

    /// @notice Largest target units the rule returns, so an auction's premium still fits the index's uint96 units.
    function MAX_TARGET_UNITS() external view returns (uint256);

    /// @notice Fee tier of the USDC/WETH pool used for dollar prices.
    function USD_POOL_FEE() external view returns (uint24);

    /// @notice Factory whose token configs the rule reads.
    function FACTORY() external view returns (address);

    function WETH() external view returns (address);
    function UNISWAP_V3_FACTORY() external view returns (address);
    function USDC() external view returns (address);

    /// @notice USDC/WETH pool behind dollar prices.
    function USD_POOL() external view returns (address);

    /// @notice Reverts unless `config` is usable for `token`. WETH needs a reference supply and no pool. Any other token
    ///         needs its WETH pool registered in the Uniswap V3 factory, at least MIN_OBSERVATION_CARDINALITY observation
    ///         slots, enough history for a TWAP_WINDOW average and a non-zero supply. A config lists at most MAX_EXCLUDED
    ///         distinct exclusions, and none together with a reference supply.
    function checkConfig(address token, IIndexFactory.TokenConfig calldata config) external view;

    /// @notice WETH wei per 1e18 raw units of `token` from its configured pool. USDC is priced from USD_POOL.
    function price(address token) external view returns (uint256);

    /// @notice Supply the rule uses for `token`: its reference supply, or its total supply minus excluded balances.
    function supply(address token) external view returns (uint256);

    /// @notice Weights, with 1e18 meaning 100%, for market caps under `methodology`. Each weight is rounded down, so
    ///         the sum is at most 1e18 and within `caps.length` wei of it.
    function weightsFromCaps(uint256[] calldata caps, uint8 methodology) external pure returns (uint256[] memory);

    /// @notice Current weights, prices and supplies of `tokens` under `methodology`.
    function weights(address[] calldata tokens, uint8 methodology)
        external
        view
        returns (uint256[] memory w, uint256[] memory prices, uint256[] memory supplies);

    /// @notice Rebalance targets for a basket holding `units` of `tokens`. Components whose bit is set in `keepMask` keep
    ///         their units; the others move toward `methodology`'s weights, rescaled to their share, at an unchanged
    ///         total value at current prices, each clipped to half and double its current units.
    /// @return targets Target units per component.
    /// @return turnover Value the rebalance sells, as a share of the rebalanced components' value (1e18 = 100%).
    function targetUnits(address[] calldata tokens, uint256[] calldata units, uint8 methodology, uint256 keepMask)
        external
        view
        returns (uint256[] memory targets, uint256 turnover);

    /// @notice Value of one whole index token at current time-weighted prices: in WETH wei, and in raw USDC units.
    ///         For display and integrations only; nothing in Xindex reads it.
    function navPerToken(address index) external view returns (uint256 wethValue, uint256 usdcValue);

    /// @notice Starting units that follow `methodology` at current prices for an index worth `startPriceUsdc` raw USDC
    ///         units per token. Each unit is at least 1.
    function initialUnits(address[] calldata tokens, uint8 methodology, uint256 startPriceUsdc)
        external
        view
        returns (uint256[] memory units);
}
