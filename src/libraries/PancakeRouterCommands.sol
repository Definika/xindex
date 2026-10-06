// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title PancakeRouterCommands
/// @notice The PancakeSwap v3 Universal Router command bytes and sentinels the zap emits, and the input each one takes.
/// @dev From the verified source of PancakeSwap's v3 Universal Router on Ethereum mainnet,
///      0x65b382653f7C31bC0Af67f188122035461ec9C76 (runtime code hash
///      0xdb8dfdb9e10400c36fae415f58c5d4a6a573b28e2bd1e25a6328623a2112d3f6): `contracts/libraries/Commands.sol`,
///      `contracts/libraries/Constants.sol` and `contracts/base/Dispatcher.sol`, GPL-3.0-or-later. No public repository
///      holds that version (PancakeSwap's `pancake-v3-contracts` deleted its router at 98684794), so the deployed source
///      is the reference, and the mainnet fork suites check these values against the deployed router.
///
///      The bytes below 0x10 are Uniswap's too; from 0x10 up the two sets differ (0x10 is OWNER_CHECK_721 here and
///      V4_SWAP at Uniswap), which is why the Pancake legs never use `UniversalRouterCommands`. As with Uniswap's set,
///      the commands the zap never emits matter as much as the ones it does: TRANSFER, PAY_PORTION, the Permit2
///      transfers and EXECUTE_SUB_PLAN can move a payer's funds, so the zap builds every command itself.
library PancakeRouterCommands {
    /// @notice Exact-input swap through PancakeSwap V3.
    /// @dev Input: `abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool
    ///      payerIsUser)`, Uniswap's layout. The router computes each pool from PancakeSwap's V3 deployer and init code
    ///      hash, so a path can reach only PancakeSwap V3 pools. `payerIsUser` false pays from the router's balance.
    uint8 internal constant V3_SWAP_EXACT_IN = 0x00;
    /// @notice Exact-output swap through PancakeSwap V3.
    /// @dev Input: `abi.encode(address recipient, uint256 amountOut, uint256 amountInMax, bytes path, bool
    ///      payerIsUser)`. The path is reversed, from the output token back to the input token. The router checks both
    ///      that the swap delivered exactly `amountOut` (`V3InvalidAmountOut`) and that the last hop stayed within
    ///      `amountInMax` (`V3TooMuchRequested`).
    uint8 internal constant V3_SWAP_EXACT_OUT = 0x01;
    /// @notice Sends the router's whole balance of a token to a recipient, reverting below a minimum.
    /// @dev Input: `abi.encode(address token, address recipient, uint256 amountMin)`.
    uint8 internal constant SWEEP = 0x04;
    /// @notice Wraps ether the router holds into WETH.
    /// @dev Input: `abi.encode(address recipient, uint256 amount)`; `CONTRACT_BALANCE` wraps the whole balance, none
    ///      included, and `ADDRESS_THIS` keeps the WETH in the router. The zap ends every Pancake call with it, because
    ///      the router's `execute` sends its whole ether balance to the caller after the last command and reverts if
    ///      that send fails, and its `receive` takes ether from anyone: one wei sent there would otherwise revert every
    ///      Pancake leg of a zap, which cannot receive ether (SV-1).
    uint8 internal constant WRAP_ETH = 0x0b;

    /// @notice The router's sentinel for itself as a recipient.
    address internal constant ADDRESS_THIS = address(2);
    /// @notice The router's sentinel for "the whole balance it holds".
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;
}
