// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHybridHubTypes} from "./IHybridHubTypes.sol";

/// @title IHybridHubExtension
/// @notice The part of a HybridHub index that runs in its module's extension: migration between versions, and the
///         evidence that a chain's records or proofs are false. Call it on the index itself (see {IHybridIndex}).
/// @dev Migration moves a holder from this index to another HybridHub index of the same factory in one Ethereum
///      transaction. Shares are burned here; each vault token both versions hold moves inside its vault, as a
///      `MIGRATE` message, within the vault's speed limit; Ethereum tokens both hold move from index to index; the new
///      index mints against those and against the Ethereum tokens only it holds, which the holder pays. A vault token
///      only the new index holds needs fresh deposits, and so an order, not a migration.
interface IHybridHubExtension is IHybridHubTypes {
    /// @notice Everything this index ever sent out of its vault balance of `token`, in BURN and MIGRATE messages.
    function sentOut(address token) external view returns (uint256);

    /// @notice The holder. Burns `shares` and mints `newShares` of `newIndex`, another HybridHub index of this factory,
    ///         to `to`. Every component of the new index must be covered: a vault token by the old shares' backing of
    ///         it, an Ethereum token by that backing and, for the rest, by the holder, who approves `newIndex`
    ///         beforehand. What the old shares back beyond that goes to `to`, a vault token's burned toward
    ///         `recipients[j]` on its chain, or booked as `to`'s claim where that is zero, as in `redeem`.
    function migrate(address newIndex, uint256 shares, uint256 newShares, address to, bytes32[] calldata recipients)
        external;

    /// @notice Another HybridHub index of this factory only, from its `migrate`. Mints `shares` to `to` against
    ///         `ethIn` of each Ethereum component already sent here, what `holder` pays of the rest, and `vaultIn` of
    ///         each vault component on its way inside its vault. Refused while a fill is accepted, or while a chain of
    ///         this index is frozen.
    function acceptMigration(
        address holder,
        address to,
        uint256 shares,
        uint256[] calldata ethIn,
        uint256[] calldata vaultIn
    ) external;

    /// @notice Anyone. Proves `chainId`'s vault records for this index, `record`, and shows that it paid out more of a
    ///         token than this index ever sent out. Freezes the chain, for every index and on the vault.
    function reportOutflow(uint256 chainId, IndexRecord calldata record, bytes calldata proof) external;

    /// @notice Anyone. Proves that claimed order `orderId`'s intake on `chainId` is, after its deadline, neither the
    ///         deposits the order was claimed on (`proof.tokens`, `proof.totals`) still open nor the same deposits
    ///         settled. Freezes the chain, for every index and on the vault.
    function reportForgedDeposit(uint256 orderId, uint256 chainId, ChainProof calldata proof) external;
}
