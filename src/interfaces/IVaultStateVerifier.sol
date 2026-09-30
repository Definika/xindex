// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Proves the storage of a contract on another chain at one of that chain's final blocks: how Ethereum reads a
///         vault's digests. One implementation per chain, each named in the factory's chain registry.
interface IVaultStateVerifier {
    /// @notice The values of `slots` in `account`'s storage at the block `proof` shows final; reverts on any proof that
    ///         does not show it.
    /// @return blockNumber The block's number on its chain.
    /// @return timestamp The block's timestamp, in seconds. A caller comparing it with a deadline must also refuse a
    ///         state older than one it already accepted.
    /// @return values The slots' values, in the order of `slots`; zero for a slot or an account the proof shows absent.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values);
}
