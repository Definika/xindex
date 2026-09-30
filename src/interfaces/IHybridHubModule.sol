// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHybridHubTypes} from "./IHybridHubTypes.sol";

/// @title IHybridHubModule
/// @notice The part of a HybridHub index that runs in its module: voids, re-confirmations and stray intakes of orders,
///         and the rebalance. Call it on the index itself, which delegates here (see {IHybridIndex}).
/// @dev The rebalance is Stage A's, with a fill in three steps, since vault legs cannot settle in one transaction:
///      `acceptRebalance` at the current λ takes a bond and the Ethereum deliveries; the executor deposits the vault
///      deliveries under the fill's intake; `settleRebalance` proves them and settles at the supply of the settling
///      block. The bond is held BOND_HOLD after settlement, and burned if a delivery proves forged.
interface IHybridHubModule is IHybridHubTypes {
    /// @notice As Stage A: 7 days between fills, 2 days of notice, a 24-hour auction, a 0.5% step, a 0.1% band.
    function MIN_REBALANCE_INTERVAL() external view returns (uint256);
    function REBALANCE_DELAY() external view returns (uint256);
    function AUCTION_DURATION() external view returns (uint256);
    function MAX_SUPPLY_STEP() external view returns (uint256);
    function MIN_BAND() external view returns (uint256);
    /// @notice An executor's bond: 0.1% of the supply, in shares.
    function REBALANCE_BOND() external view returns (uint256);
    /// @notice How long a settled fill's bond is held against a forged delivery: 24 hours.
    function BOND_HOLD() external view returns (uint256);
    /// @notice How long an executor has to deposit the vault deliveries after accepting: 6 hours.
    function DELIVERY_WINDOW() external view returns (uint256);

    /// @notice Anyone, during a locked order's lock. `proof` shows `chainId`'s intake at a block after the deadline
    ///         other than the order rests on: the order fails and the chain's mints freeze.
    function voidOrder(uint256 orderId, uint256 chainId, bytes calldata proof) external;

    /// @notice Anyone. For a locked order whose chain froze at or after it settled: proofs from after each such freeze
    ///         that the intake is unchanged. Chains that did not freeze take an empty proof.
    function reconfirmOrder(uint256 orderId, bytes[] calldata proofs) external;

    /// @notice Anyone, after an intake's deadline, for an intake that belongs to no order and no fill: tells the vault
    ///         to refund whatever was deposited there.
    function failIntake(uint256 chainId, uint256 intakeId) external;

    /// @notice As Stage A's `startRebalance`: the band over every component not in `keepMask`, whose supplies, vault
    ///         tokens' included, the factory keeps.
    function startRebalance(uint256 keepMask) external;

    /// @notice The owner or guardian. Cancels the proposal, or an accepted fill, which unwinds with its bond returned.
    function cancelRebalance() external;

    /// @notice Anyone, while the auction is live. Takes it at the current λ: posts the bond, delivers the bought
    ///         Ethereum components now, and names a recipient per vault chain for the sold vault legs. `maxAmountsIn`,
    ///         if not empty, bounds each component's delivery.
    function acceptRebalance(bytes32[] calldata recipients, uint256[] calldata maxAmountsIn) external;

    /// @notice Anyone, while a fill is accepted. Settles it with a proof of each vault chain's delivery intake; a chain
    ///         with no bought leg takes an empty proof.
    function settleRebalance(ChainProof[] calldata proofs) external;

    /// @notice The executor at any time before settlement, or anyone SETTLE_GRACE after the delivery deadline: the
    ///         bond is burned and the deliveries are returned.
    function failRebalance() external;

    /// @notice Anyone, BOND_HOLD after a settlement: returns the bond to its executor.
    function releaseBond() external;

    /// @notice Anyone, while a settled fill's bond is held. `proof` of `chainId`'s delivery intake, with its preimage
    ///         `state`, tokens and totals, shows it neither open nor settled, or below what the fill recorded: the bond
    ///         is burned and the chain's mints freeze.
    function slashRebalance(uint256 chainId, uint8 state, ChainProof calldata proof) external;

    function fill() external view returns (Fill memory);
    /// @notice The intake id a fill's vault deliveries go under; zero when no fill is live.
    function fillIntakeId() external view returns (uint256);
    function fillAmounts()
        external
        view
        returns (uint256[] memory units, uint256[] memory deliveries, uint256[] memory delivered);
    function previewBand(uint256 keepMask)
        external
        view
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax);
    function pendingRebalance()
        external
        view
        returns (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios);
    /// @notice The settlement a fill accepted now would take: λ, the new units, and each component's payout and
    ///         delivery at the current supply.
    function previewRebalance()
        external
        view
        returns (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn);
    function canStartRebalance() external view returns (bool);
    function proposalCount() external view returns (uint256);
    function rebalanceNonce() external view returns (uint256);
    function lastRebalance() external view returns (uint256);
    function restartAllowedAt() external view returns (uint256);
}
