// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Proves the storage of a contract on another chain at one of that chain's final blocks: how Ethereum reads a
///         vault's digests. One implementation per chain, each named in the factory's chain registry.
interface IVaultStateVerifier {
    /// @notice The values of `slots` in `account`'s storage at the block `proof` shows final; reverts on any proof that
    ///         does not show it.
    /// @return blockNumber The block's number on its chain.
    /// @return timestamp The block's timestamp, in seconds. A caller bounds it below by its own deadline or freeze, as
    ///         the hub does on every read; nothing refuses a state older than one already accepted (A2-04). Every
    ///         verifier's MAX_LAG is inclusive at its edge by design: exactly MAX_LAG after the time it counts from, a
    ///         proof still passes (A6-07).
    /// @return values The slots' values, in the order of `slots`; zero for a slot or an account the proof shows absent.
    function verifySlots(address account, bytes32[] calldata slots, bytes calldata proof)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp, bytes32[] memory values);
}
