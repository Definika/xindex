// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice One hop of a Uniswap V4 route.
/// @dev Vendored from Uniswap's v4-periphery (MIT), `src/libraries/PathKey.sol` at commit
///      444c526b77d804590f0d7bc5a481af5a3277c952, the commit Universal Router's 2.0.0 tag pins. The mainnet deployment
///      0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af predates that tag and was compiled from v4-periphery 3796e9c; the
///      files vendored here are identical at both commits, the four that differ are non-behavioural, and the pinned
///      sources rebuild the deployed runtime byte for byte (CR-I19). The upstream fields are typed `Currency` and
///      `IHooks`, both of which are `address` underneath, so this is abi-identical while needing none of their
///      libraries.
///
///      `intermediateCurrency` is the currency on the far side of this hop. Its meaning depends on the direction the
///      router walks the path: an exact-input route reads it as where that hop arrives, so the last entry names the
///      output; an exact-output route walks backwards, so the first entry names the input.
///
///      `hooks` is arbitrary code that runs on the swap. The zap rejects any route whose hops are not hookless, so
///      it is always zero in what Xindex builds.
struct PathKey {
    address intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
    bytes hookData;
}

/// @notice Parameters of a multi-hop exact-input V4 swap.
/// @dev `IV4Router.ExactInputParams` at the same commit. `path[path.length - 1].intermediateCurrency` is the output.
struct V4ExactInputParams {
    address currencyIn;
    PathKey[] path;
    uint128 amountIn;
    uint128 amountOutMinimum;
}

/// @notice Parameters of a multi-hop exact-output V4 swap.
/// @dev `IV4Router.ExactOutputParams` at the same commit. `path[0].intermediateCurrency` is the input.
struct V4ExactOutputParams {
    address currencyOut;
    PathKey[] path;
    uint128 amountOut;
    uint128 amountInMaximum;
}

/// @title UniswapV4Types
/// @notice The V4 router actions the zap emits, and the sentinels it must never emit by accident.
/// @dev Vendored from Uniswap's v4-periphery (MIT), `src/libraries/Actions.sol` and `src/libraries/
///      ActionConstants.sol` at commit 444c526b77d804590f0d7bc5a481af5a3277c952.
library UniswapV4Types {
    /// @notice Swap an exact input along a path. Parameter: `abi.encode(V4ExactInputParams)`.
    uint8 internal constant SWAP_EXACT_IN = 0x07;

    /// @notice Swap for an exact output along a path. Parameter: `abi.encode(V4ExactOutputParams)`.
    uint8 internal constant SWAP_EXACT_OUT = 0x09;

    /// @notice Pay what the swap owes. Parameter: `abi.encode(address currency, uint256 amount, bool payerIsUser)`.
    ///         `payerIsUser` false pays from the router's own balance, which is what the zap pre-funds.
    uint8 internal constant SETTLE = 0x0b;

    /// @notice Collect what the swap produced. Parameter: `abi.encode(address currency, address recipient,
    ///         uint256 amount)`.
    uint8 internal constant TAKE = 0x0e;

    /// @notice As an amount, "the whole of it": the full debt on a settle, the full credit on a take. The zap uses it
    ///         on both sides so a leg settles and collects exactly what the swap moved, with nothing left over for the
    ///         unlock to revert on. It is a sentinel in the swap-amount position as well: an exact-input swap of zero
    ///         sells the full credit and an exact-output swap of zero buys the full debt. The zap never encodes a zero
    ///         swap amount, because a burn leg that redeems nothing is skipped and a mint leg always needs at least one
    ///         raw unit (CR-I05).
    uint256 internal constant OPEN_DELTA = 0;

    /// @notice As an amount, "the router's whole balance of this currency". The zap never emits it: every amount it
    ///         encodes is one the index asked for, and a sentinel slipping into that position would swap a balance
    ///         nobody sized. Kept named so the prohibition is legible rather than implicit.
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;

    /// @notice As a recipient, "whoever called the router". The zap always names an address instead, for the same
    ///         reason it never emits CONTRACT_BALANCE.
    address internal constant MSG_SENDER = address(1);

    /// @notice As a recipient, "the router itself".
    address internal constant ADDRESS_THIS = address(2);
}
