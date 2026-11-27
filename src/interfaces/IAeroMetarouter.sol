// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAeroMetarouter
/// @notice The part of Aero's Metarouter on Base the swap engine calls. Aero's pool lookups are {IAeroCLFactory} and
///         {IAeroPoolFactory}.
/// @dev Declarations of our own, read from the Metarouter's verified source on Base (`0x0fEf9e88A7b76BCDBF451780C6774FE32965Ee98`,
///      Dromos Labs' `metadex-public`, `V3/src/interfaces/metarouter/IMetarouter.sol`): the structs below are
///      ABI-identical to the ones its swap commands decode. The command bytes are in {AeroCommands}.
interface IAeroMetarouter {
    /// @notice How a command spends a balance the router holds: an exact amount, or millionths of the balance.
    enum SpendMode {
        Amount,
        Pips
    }

    /// @notice A spend of the router's own balance.
    struct BalanceSpend {
        SpendMode mode;
        uint256 value;
    }

    /// @notice An exact-input swap along `pools`, forward from `tokenIn`. With `payerIsUser` false the router spends
    ///         its own balance of `tokenIn`.
    struct SwapExactInParams {
        address[] pools;
        address tokenIn;
        BalanceSpend amountIn;
        bool payerIsUser;
        uint256 minAmountOut;
        address recipient;
    }

    /// @notice An exact-output swap along `pools`, forward from `tokenIn`, delivering exactly `amountOut` to
    ///         `recipient`. With `payerIsUser` false the router pays from its own balance, at most `maxAmountIn`.
    struct SwapExactOutParams {
        address[] pools;
        address tokenIn;
        uint256 amountOut;
        bool payerIsUser;
        uint256 maxAmountIn;
        address recipient;
    }

    /// @notice Runs `commands`, one byte each, with their `inputs`, then returns the whole balance of every token the
    ///         batch touched to the caller. Reverts after `deadline`.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
