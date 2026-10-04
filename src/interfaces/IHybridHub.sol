// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IHybridHubTypes} from "./IHybridHubTypes.sol";

/// @title IHybridHub
/// @notice An index whose basket holds tokens on Ethereum and coins in vaults on other chains. 1e18 shares are backed
///         by `units_i` raw units of each component: an Ethereum component in the hub's own balance, as in Stage A, and a
///         vault component in the vault of its chain, which pays it out only on messages the hub sends. Nothing reads a
///         price.
/// @dev Minting goes through orders. A minter opens one, escrowing the Ethereum components; deposits the vault
///      components on their chains under the order's intake id before its deadline; anyone settles it with a proof of
///      each vault's intake at a block after the deadline; and after MINT_LOCK the shares are claimable. In that lock a
///      proof of the same intake showing anything else voids the order and freezes the chain's mints: the deposit was
///      forged or the proof system is unsound. Redeeming pays the Ethereum components at once and sends each vault a
///      `BURN` message, which the vault pays within its speed limit once P1 and P2 prove it. Invariants, for every
///      component with S the total supply:
///          Ethereum: balanceOf(hub) >= floor(S * units / 1e18) + totalClaims + escrowed
///          vault:    vaultBacking   >= floor(S * units / 1e18) + totalClaims
///      where `vaultBacking` is the hub's own book of what the vault holds for it: the proven deposits of every claimed
///      order, the proven deliveries of every settled fill and the vault legs a migration brings in, less every amount
///      burned or migrated out. The rarer paths, voids, re-confirmations, stray intakes and the rebalance, run in the
///      module the hub delegates to: {IHybridHubModule}. Integrators call an index through {IHybridIndex}, which has
///      both.
interface IHybridHub is IHybridHubTypes, IERC20, IERC20Permit {
    /// @notice The factory this template and its clones belong to.
    function FACTORY() external view returns (address);

    /// @notice The module this hub delegates the rest of {IHybridIndex} to, fixed with the template.
    function MODULE() external view returns (address);

    /// @notice How long a settled order waits before its shares can be claimed: 24 hours.
    function MINT_LOCK() external view returns (uint256);
    /// @notice The latest an order's deadline may be, after opening it: 6 hours.
    function MAX_ORDER_LIFE() external view returns (uint256);
    /// @notice After its deadline, how long an unsettled order is left to its minter before anyone may fail it: 6 hours.
    function SETTLE_GRACE() external view returns (uint256);
    /// @notice The most of the supply that may become claimable in any 24 hours: 4%.
    function MINT_CAP() external view returns (uint256);
    /// @notice How long a freeze of a chain lasts: 14 days. The factory keeps every freeze, so one holds every index's
    ///         mints on that chain, whoever began it.
    function FREEZE_DURATION() external view returns (uint256);

    /// @notice The factory only, once. `placements` is per component; an Ethereum component's is all zero.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units,
        Placement[] calldata placements
    ) external;

    /// @notice Anyone. Opens an order for `shares` whose deposits close at `deadline`, escrowing the Ethereum
    ///         components now. Deposit each vault component on its chain with `deposit(index, intakeId)`.
    function openOrder(uint256 shares, uint256 deadline) external returns (uint256 orderId, uint256 intakeId);

    /// @notice Anyone. Settles an open order with one proof per vault chain, in {chains} order, each of a block after
    ///         the deadline showing the intake's deposits at least what the order needs.
    function settleOrder(uint256 orderId, ChainProof[] calldata proofs) external;

    /// @notice Anyone, after the lock. Mints the order's shares to its minter and tells each vault the deposits joined
    ///         the index; or, if its escrow or deposits no longer cover its shares at the units now in force, fails it.
    ///         Waits while a rebalance fill is accepted.
    function claimOrder(uint256 orderId) external;

    /// @notice An open order's minter at any time, or anyone SETTLE_GRACE after its deadline. The escrow is booked as
    ///         the minter's claims, and each vault is told to refund the deposits.
    function failOrder(uint256 orderId) external;

    /// @notice Burns `shares` from the caller. Ethereum components go to `to`, and each vault component is burned toward
    ///         `recipients[j]` on the `j`-th of {chains}. A component in `skipMask`, or on a chain whose recipient is
    ///         zero, is booked as a claim of `to` instead.
    function redeem(uint256 shares, address to, bytes32[] calldata recipients, uint256 skipMask) external;

    /// @notice Pays the caller's claim of Ethereum component `token` to `to`.
    function claim(address token, address to) external returns (uint256 amount);

    /// @notice Burns the caller's claim of vault component `token` toward `recipient` on its chain.
    function claimToVault(address token, bytes32 recipient) external returns (uint256 amount);

    function components()
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory units,
            uint256[] memory chainIds,
            bytes32[] memory vaultTokens
        );
    function chains() external view returns (uint256[] memory chainIds, bytes32[] memory vaults);
    function order(uint256 orderId) external view returns (Order memory);
    function orderAmounts(uint256 orderId) external view returns (uint256[] memory amounts, uint256[] memory deposits);
    function intakeIdOf(uint256 orderId) external view returns (uint256);
    function previewOrder(uint256 shares) external view returns (uint256[] memory amounts);
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts);
    /// @notice Shares that could become claimable now without breaking MINT_CAP, by an order or a migration: none on an
    ///         empty index, which only its creator may seed.
    function mintRoom() external view returns (uint256);
    /// @notice When the factory's latest freeze of `chainId` began and when it ends, whether the owner, the guardian or
    ///         an index's evidence froze it: an order settled at or before `start` needs re-confirming before it can be
    ///         claimed.
    function chainFreeze(uint256 chainId) external view returns (uint256 start, uint256 until);
    function vaultBacking(address token) external view returns (uint256);
    function escrowed(address token) external view returns (uint256);
    function claimOf(address account, address token) external view returns (uint256);
    function totalClaims(address token) external view returns (uint256);
    function orderCount() external view returns (uint256);
    function messageNonce() external view returns (uint256);
}
