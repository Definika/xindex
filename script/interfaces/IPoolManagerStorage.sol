// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The Uniswap V4 PoolManager's raw storage read (v4-core's `IExtsload`), which v4's own StateLibrary reads a
///         pool's state through and `CheckToken` reads depth through.
/// @dev Mainnet: 0x000000000004444c5dc75cB358380D2e3dE08A90
interface IPoolManagerStorage {
    /// @notice The word in the PoolManager's storage at `slot`.
    function extsload(bytes32 slot) external view returns (bytes32);
}
