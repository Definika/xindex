// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPythPrices
/// @notice What one raw unit of a component is worth at Pyth's price, for the check that can only refuse a
///         rebalance fill. The factory deploys one with itself and the chain's Pyth contract, and every index of that
///         factory reads it. Nothing else reads it: no issue, redeem or claim, so no price, stale, missing or hostile,
///         can block an exit or misprice a mint.
/// @dev Each value leans against the executor: a leg the fill takes out is valued at Pyth's price plus its confidence,
///      rounded up, and a leg it brings in at the price less the confidence, rounded down. A price older than
///      MAX_PRICE_AGE, not positive, or no wider than its confidence values nothing, and the fill that needs it
///      reverts. A filler posts a fresh Pyth update in its own transaction, before it fills.
interface IPythPrices {
    /// @notice How a token's Pyth feed values it.
    /// - None: no feed. A fill that moves the token reverts.
    /// - Token: the feed prices one whole token.
    /// - Vault: the token is an ERC-4626 vault and the feed prices one whole asset. One whole token is worth
    ///   `convertToAssets` of one whole token, read from the vault at the fill, as a wrapped xStock is.
    /// - Multiplier: the feed prices one share, and one token stands for `multiplier()` shares (1e18 = one), read from
    ///   the token at the fill, as Coinbase's stock tokens on Base do.
    enum FeedKind {
        None,
        Token,
        Vault,
        Multiplier
    }

    /// @notice A token's feed: Pyth's price id and how it values the token.
    struct PriceFeed {
        bytes32 id;
        FeedKind kind;
    }

    /// @notice A fill moves `token`, and it has no feed.
    error NoPriceFeed(address token);
    /// @notice `token`'s price was published at `publishTime`, more than MAX_PRICE_AGE ago.
    error StalePrice(address token, uint256 publishTime);
    /// @notice `token`'s price is not positive, no wider than its confidence, or out of the range a value can take:
    ///         too large for the check's sums, or so small, or at a rate or multiplier of zero, that one raw unit
    ///         would be worth nothing.
    error UnusablePrice(address token);

    /// @notice Pyth's price contract on this chain.
    function PYTH() external view returns (address);

    /// @notice The factory whose listings name each token's feed.
    function FACTORY() external view returns (address);

    /// @notice The oldest a price may be, in seconds, when a fill reads it.
    function MAX_PRICE_AGE() external view returns (uint256);

    /// @notice The scale of every value: one raw unit's worth in dollars times 1e36.
    function VALUE_SCALE() external view returns (uint256);

    /// @notice What one raw unit of each component is worth, for a fill from `currentUnits` to `newUnits`: a leg that
    ///         falls is valued as leaving and one that rises as arriving, both against the executor; a leg that keeps
    ///         its units is valued at zero and not read. One entry per token, in order.
    function legValues(address[] memory tokens, uint256[] memory currentUnits, uint256[] memory newUnits)
        external
        view
        returns (uint256[] memory values);

    /// @notice What one raw unit of `token` is worth, as a leg leaving the index (`leaving`) or arriving in it.
    function valueOf(address token, bool leaving) external view returns (uint256);

    /// @notice What one raw unit of each of `tokens` is worth at the feed and the decimals given for it, all leaving
    ///         or all arriving: {valueOf} for a caller that holds each token's feed and decimals itself, as the factory
    ///         does when it checks a new index's weights, in one call instead of three a token.
    function valuesWith(address[] calldata tokens, PriceFeed[] calldata feeds, uint8[] calldata decimals, bool leaving)
        external
        view
        returns (uint256[] memory values);
}
