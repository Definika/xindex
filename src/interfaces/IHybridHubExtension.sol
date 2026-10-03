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
    /// @notice How long after a freeze that holds an order has ended its minter must wait to give up the order: 7 days.
    function HELD_ORDER_GRACE() external view returns (uint256);

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
    ///         each vault component on its way inside its vault. Refused while a fill is accepted, while a chain of
    ///         this index is frozen, or beyond this index's mint room, which only its creator's migration into it empty
    ///         escapes.
    function acceptMigration(
        address holder,
        address to,
        uint256 shares,
        uint256[] calldata ethIn,
        uint256[] calldata vaultIn
    ) external;

    /// @notice Anyone. Proves `chainId`'s vault records for this index, `record`, and shows that it paid out more of a
    ///         token than this index ever sent out. Freezes the chain, for every index and on the vault. Refused on an
    ///         exited chain, as `voidOrder` is: a vault in its exit pays holders this index never sent anything.
    function reportOutflow(uint256 chainId, IndexRecord calldata record, bytes calldata proof) external;

    /// @notice The holder, for itself. Where `chainId`'s vault pays it on a snapshot exit, if it cannot sign there, as a
    ///         contract cannot; zero clears it. The vault reads it from Ethereum's state at its snapshot.
    function setRecoveryAddress(uint256 chainId, bytes32 recipient) external;

    /// @notice Anyone. Proves that `chainId`'s vault began its snapshot exit. From then on the chain counts as frozen
    ///         for good here: nothing mints on it, and its holders were paid there.
    function recordExit(uint256 chainId, bytes calldata proof) external;

    /// @notice Fails a locked order, its escrow booked as its minter's claims and its intake refunded by every vault.
    ///         Anyone, once `chainId`'s snapshot exit keeps the order from its claim for good; or its minter, once a
    ///         freeze of `chainId` that holds it has been over for HELD_ORDER_GRACE without a re-confirmation.
    function failHeldOrder(uint256 orderId, uint256 chainId) external;

    /// @notice `holder`'s recovery address on `chainId`.
    function recoveryAddress(address holder, uint256 chainId) external view returns (bytes32);

    /// @notice Whether this index sent the settle message of `intakeId`.
    function intakeSettled(uint256 intakeId) external view returns (bool);

    /// @notice When `chainId`'s snapshot exit was recorded here; zero if it was not.
    function exitedAt(uint256 chainId) external view returns (uint256);

    /// @notice Whether this index sent the vault message with id `id`. A vault reads it at its snapshot to pay a burn
    ///         or migration still in flight then.
    function messageSent(bytes32 id) external view returns (bool);

    /// @notice Anyone. Emits a message this index sent again, unchanged, in a transaction of the caller's own. Whoever
    ///         sends a transaction shapes its receipt, and a receipt can be made too large for a vault chain's verifier
    ///         to prove; the copy's receipt is the caller's. A vault runs a message once, by its id, so a second copy
    ///         changes nothing (LG-1). Reverts `NotSent` for any payload this index never sent.
    function resendMessage(bytes calldata payload) external;

    /// @notice Anyone. Proves that claimed order `orderId`'s intake on `chainId` is, after its deadline, neither the
    ///         deposits the order was claimed on (`proof.tokens`, `proof.totals`) still open nor the same deposits
    ///         settled. Freezes the chain's mints, for every index; the vault keeps paying. Refused on an exited
    ///         chain, as `voidOrder` is.
    function reportForgedDeposit(uint256 orderId, uint256 chainId, ChainProof calldata proof) external;
}
