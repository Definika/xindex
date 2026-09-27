// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIndexFactory} from "./IIndexFactory.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

/// @title IIndexRule
/// @notice Reads each token's reference supply and Chainlink USD price and applies an index's weighting rule. It is
///         stateless and view-only: it computes rebalance targets for `IIndexToken.startRebalance` and index prices for
///         display, and never moves funds. No supply is read live: a token's market cap is the reference supply its
///         timelocked config names, so nothing done inside a snapshot's own transaction can move it (CR-M01).
/// @dev Prices are USD with 18 decimals ("USD-WAD", 1e18 = one dollar) per 1e18 raw units of a token, from the token's
///      configured feed. They shape rebalance targets, and the auction that settles a rebalance sets the level. A
///      snapshot price read low by a factor f on a component the rebalance sells, or high on one it buys, moves the
///      auction's fair multiplier to about 1/f, and below f = 2/3 the first executor takes value from the index. What
///      bounds that is no longer the cost of holding a pool off-market: it is Chainlink's aggregation, plus the
///      freshness bound each token carries and the guardian's power to cancel a snapshot during the notice period.
///
///      Every price is checked the same way wherever it is read, for display and for a snapshot alike: a positive
///      answer, no older than the token's `maxStaleness`, from a feed and a token of at most 18 decimals each, and
///      below MAX_PRICE once converted. There is no looser view path. Nothing about a feed can be griefed by a third
///      party, so a view that skipped the checks would only ever show a dead price as if it were current.
///
///      A listed token's decimals are the ones `IIndexFactory.tokenDecimals` recorded when its config came into force,
///      so only `checkConfig` ever calls a token itself: a component whose contract stops answering is still priced
///      from its feed, and a keep mask routes around it under both methodologies (RT-01).
///
///      A token that was never listed has no feed, and every function that prices it reverts InvalidFeed.
interface IIndexRule is IXindexErrors {
    /// @notice `feed` is unusable for `token`: it is zero or has no code. A contract that has code but does not answer
    ///         as an aggregator is refused too, with its own revert or with none, since the rule cannot tell why a call
    ///         it makes to an arbitrary contract failed (CR-I10).
    error InvalidFeed(address token, address feed);
    /// @notice `maxStaleness` is zero or above MAX_FEED_STALENESS.
    error InvalidStaleness(address token, uint32 maxStaleness);
    /// @notice The token or its feed reports more than 18 decimals, which the WAD conversion cannot express.
    error InvalidDecimals(address token, uint8 tokenDecimals, uint8 feedDecimals);
    /// @notice The feed's latest answer is zero or negative, so no price can be formed from it.
    error InvalidPrice(address token, int256 answer);
    /// @notice The feed's latest answer was written at `updatedAt`, further back than the token's `maxStaleness`, or
    ///         in the future. Nothing on-chain can clear it: the feed has to publish again.
    error StalePrice(address token, uint256 updatedAt);
    /// @notice The feed's answer converts to more than MAX_PRICE, which no real asset reaches and which the rule's
    ///         value arithmetic is not proved for.
    error PriceTooHigh(address token, int256 answer);
    /// @notice The config names no reference supply for `token`. Every token needs one: zero used to mean the token's
    ///         own total supply, read live, which anyone able to mint or burn it could move inside the transaction that
    ///         snapshots it (CR-M01).
    error ZeroSupply(address token);
    /// @notice At `startPriceUsd` an index token would hold less than one raw unit of `token`, so the basket cannot
    ///         be described at that price. Pick a higher one; see the starting-price guidance in the README.
    error StartPriceTooLow(address token, uint256 startPriceUsd);
    /// @notice Nothing is left to weight or rebalance: every market cap is zero, the constituents of a capped basket
    ///         still under the 20% cap have none, or the components being rebalanced hold no value, as when the keep
    ///         mask keeps every one.
    error DegenerateBasket();

    /// @notice Largest USD-WAD price the rule will accept for a component. One raw unit worth this much is far past
    ///         any real asset; the bound keeps every value product inside 256 bits.
    function MAX_PRICE() external view returns (uint256);

    /// @notice Longest staleness bound a token's config may carry.
    function MAX_FEED_STALENESS() external view returns (uint32);

    /// @notice Largest units the rule raises a component to, so an auction's premium on the increase still fits the
    ///         index's uint96 units. A component whose units already exceed it, or that is kept, can keep larger units;
    ///         its target is then never above its current units, and the multiplier applies only to increases.
    function MAX_TARGET_UNITS() external view returns (uint256);

    /// @notice Factory whose token configs the rule reads.
    function FACTORY() external view returns (address);

    /// @notice Reverts unless `config` is usable for `token`: a feed with code that answers as an aggregator, a
    ///         `maxStaleness` between one second and MAX_FEED_STALENESS, a price that passes every check the rule
    ///         applies when it prices the token, and a non-zero reference supply.
    /// @param token Token the config is for.
    /// @param config Config to check, as it would be proposed to the factory.
    function checkConfig(address token, IIndexFactory.TokenConfig calldata config) external view;

    /// @notice USD value of the two sides of a rebalance settlement, priced the way every other path prices a
    ///         component. A component that neither sends nor receives anything is not priced at all, so a keep mask
    ///         still routes around a component whose feed cannot be read.
    /// @param tokens The index's components, in order.
    /// @param amountsOut What leaves the index, one per component.
    /// @param amountsIn What arrives, one per component.
    /// @return outValue USD-WAD value of `amountsOut`.
    /// @return inValue USD-WAD value of `amountsIn`.
    function settlementValues(address[] calldata tokens, uint256[] calldata amountsOut, uint256[] calldata amountsIn)
        external
        view
        returns (uint256 outValue, uint256 inValue);

    /// @notice USD-WAD per 1e18 raw units of `token`, from its configured feed.
    /// @param token A token with a config in force.
    /// @return The USD-WAD price.
    function price(address token) external view returns (uint256);

    /// @notice Supply the rule uses for `token`: the reference supply its config names, and nothing else. Zero for a
    ///         token with no config; the token's own `totalSupply` is never read.
    /// @param token Token whose config is read.
    /// @return Supply in the token's raw units.
    function supply(address token) external view returns (uint256);

    /// @notice Weights, with 1e18 meaning 100%, for market caps under `methodology`. Each weight is rounded down, so
    ///         the sum is at most 1e18 and within `caps.length` wei of it.
    /// @param caps Market caps in any common unit, one per component.
    /// @param methodology `Methodology` id.
    /// @return Weight per component, in the order of `caps`.
    function weightsFromCaps(uint256[] calldata caps, uint8 methodology) external pure returns (uint256[] memory);

    /// @notice Current weights, prices and supplies of `tokens` under `methodology`.
    /// @param tokens Configured tokens, in the order of the returned arrays.
    /// @param methodology `Methodology` id.
    /// @return w Weight per token (1e18 = 100%).
    /// @return prices USD-WAD price per token (per 1e18 raw units).
    /// @return supplies Supply per token, in its raw units.
    function weights(address[] calldata tokens, uint8 methodology)
        external
        view
        returns (uint256[] memory w, uint256[] memory prices, uint256[] memory supplies);

    /// @notice Rebalance targets for a basket holding `units` of `tokens`. Components whose bit is set in `keepMask`
    ///         keep their units; the others move toward `methodology`'s weights at an unchanged total value at
    ///         snapshot prices, each clipped to half and double its current units. The targets are a water-filling:
    ///         each pass shares the value not yet pinned among the components still free, by weight, clips every
    ///         share to that component's bounds, and pins the side the clips prove, the floors when they add at least
    ///         as much value as the ceilings remove and the ceilings otherwise. A pinned component never moves again,
    ///         so a component the rule wants to shrink past its floor is never handed value back. Shares round up
    ///         into units, so the target basket is never worth less than the basket it replaces.
    ///         Every component the snapshot reads needs a price its feed can serve: positive, no older than the
    ///         token's `maxStaleness` (else StalePrice), and within the decimal and MAX_PRICE bounds. Kept components
    ///         are not read at all under the uncapped methodology; under the capped methodology they are read, and
    ///         checked the same way, because their market cap scales every other component's weight. A kept cap moves
    ///         nothing while no ceiling binds, since every weight is then the component's own; where one binds, the
    ///         kept cap still decides which components the excess is shared with and how large the top ceiling is,
    ///         so a keep mask is a lever over the targets and not only over which component trades (VR-02).
    /// @param tokens Components, in index order.
    /// @param units Current raw units per 1e18 shares, one per component.
    /// @param methodology `Methodology` id.
    /// @param keepMask Bit i set keeps component i's units; bits at or above `tokens.length` are ignored.
    /// @return targets Target units per component.
    /// @return turnover Value the rebalance trades, the smaller of what it sells and what it buys, as a share of the
    ///         rebalanced components' value (1e18 = 100%) (DA-08).
    function targetUnits(address[] calldata tokens, uint256[] calldata units, uint8 methodology, uint256 keepMask)
        external
        view
        returns (uint256[] memory targets, uint256 turnover);

    /// @notice How far a basket holding `units` of `tokens` sits from `methodology`'s weights, before the
    ///         half-to-double band: the value the rule wants moved out of the rebalanced components that hold more than
    ///         their weight's share and can still shrink, as a share of the rebalanced components' value (1e18 = 100%).
    ///         A component held at one raw unit cannot shrink, so an excess it holds is not counted. The band lets a
    ///         growing component at most double per rebalance, so a basket far from its rule can move only in small
    ///         steps; `IIndexToken.startRebalance` accepts such a step when this distance clears MIN_TURNOVER (RT-04).
    ///         Same inputs, snapshot and price checks as {targetUnits}.
    /// @param tokens Components, in index order.
    /// @param units Current raw units per 1e18 shares, one per component.
    /// @param methodology `Methodology` id.
    /// @param keepMask Bit i set keeps component i out of the measure; bits at or above `tokens.length` are ignored.
    /// @return distance The value the rule wants moved, as a share of the rebalanced value.
    function shortfall(address[] calldata tokens, uint256[] calldata units, uint8 methodology, uint256 keepMask)
        external
        view
        returns (uint256 distance);

    /// @notice Value of one whole index token at current prices, in USD-WAD. For display and integrations only;
    ///         nothing in Xindex reads it. It reverts while any component's feed is stale, so an app must handle
    ///         StalePrice rather than show the last good number.
    /// @param index An index the factory deployed, else NotIndex.
    /// @return usdValue USD-WAD per 1e18 shares.
    function navPerToken(address index) external view returns (uint256 usdValue);

    /// @notice Starting units that follow `methodology` at current prices for an index worth `startPriceUsd` per
    ///         token. Each unit is at least 1.
    /// @param tokens Configured tokens, in the order `IIndexFactory.createIndex` will receive them.
    /// @param methodology `Methodology` id.
    /// @param startPriceUsd Value of one whole index token in USD-WAD, for example 100e18 for 100 dollars.
    /// @return units Raw units per 1e18 shares, one per token, for `IIndexFactory.createIndex`.
    function initialUnits(address[] calldata tokens, uint8 methodology, uint256 startPriceUsd)
        external
        view
        returns (uint256[] memory units);
}
