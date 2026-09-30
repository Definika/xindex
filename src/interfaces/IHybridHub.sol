// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IXindexErrors} from "./IXindexErrors.sol";

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
///      where `vaultBacking` is the hub's own book of what the vault holds for it: the deposits of every claimed order,
///      less every amount burned. Stage B layer 1: this hub does not rebalance yet.
interface IHybridHub is IERC20, IERC20Permit, IXindexErrors {
    enum OrderStatus {
        None,
        Open,
        Locked,
        Claimed,
        Failed
    }

    /// @notice One vault chain's intake for an order: the state verifier's proof of the vault's intake digest, and the
    ///         digest's preimage, the tokens deposited and their totals.
    struct ChainProof {
        bytes proof;
        address[] tokens;
        uint256[] totals;
    }

    /// @notice Where a component is held: its chain, its token id there and that chain's vault; all zero on Ethereum.
    struct Placement {
        uint256 chainId;
        bytes32 vaultToken;
        bytes32 vault;
    }

    /// @notice An order as stored: its minter, shares, the intake deadline (on the vault chains' clocks), the end of
    ///         its lock, when it was last settled or re-confirmed, and its status.
    struct Order {
        address minter;
        uint256 shares;
        uint256 deadline;
        uint256 lockEnds;
        uint256 settledAt;
        OrderStatus status;
    }

    event OrderOpened(
        uint256 indexed orderId, address indexed minter, uint256 shares, uint256 intakeId, uint256[] amounts
    );
    event OrderSettled(uint256 indexed orderId, uint256 lockEnds, uint256[] deposits);
    event OrderReconfirmed(uint256 indexed orderId);
    event OrderClaimed(uint256 indexed orderId, address indexed minter, uint256 shares);
    event OrderFailed(uint256 indexed orderId, address indexed by);
    /// @notice A proof of `chainId`'s intake showed `proven` where the order rests on `recorded`.
    event OrderVoided(uint256 indexed orderId, uint256 indexed chainId, bytes32 proven, bytes32 recorded);
    /// @notice A contradiction froze this index's mints on `chainId` until `until`.
    event ChainFrozen(uint256 indexed chainId, uint256 until);
    /// @notice An intake of no order was failed, so its depositors can take their coins back.
    event IntakeFailed(uint256 indexed chainId, uint256 intakeId);
    event Redeemed(address indexed sender, address indexed to, uint256 shares, uint256[] amounts);
    event ClaimRecorded(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);
    /// @notice `amount` of vault token `token` is burned toward `recipient` on `chainId` by message `messageId`.
    event BurnSent(
        address indexed token, uint256 indexed chainId, bytes32 recipient, uint256 amount, bytes32 messageId
    );

    error NotFactory();
    error NotInitialized();
    error InvalidComponents();
    error ZeroShares();
    error InvalidSkipMask(uint256 skipMask);
    error NothingToClaim(address token);
    error TransferAmountMismatch(address token);
    /// @notice An order's deadline must lie after now and at most MAX_ORDER_LIFE ahead.
    error BadDeadline(uint256 deadline);
    error WrongStatus(uint256 orderId, OrderStatus status);
    error NotYet(uint256 until);
    error ChainIsFrozen(uint256 chainId, uint256 until);
    /// @notice Settling `shares` would make more than MINT_CAP of the supply claimable in 24 hours; `room` is left.
    error MintCapExceeded(uint256 shares, uint256 room);
    error DepositShort(address token, uint256 deposited, uint256 required);
    /// @notice A proof of `chainId`'s vault is of a block at `time`, not after `after`.
    error ProofTooEarly(uint256 chainId, uint256 time, uint256 after_);
    error DigestMismatch(uint256 chainId, bytes32 proven, bytes32 expected);
    error NotAContradiction(uint256 chainId);
    error NotAVaultChain(uint256 chainId);
    error IntakeOfAnOrder(uint256 intakeId);
    error IntakeStillOpen(uint256 deadline);
    error IntakeAlreadyFailed(uint256 intakeId);
    /// @notice `chainId` froze after the order settled: a fresh proof from after the freeze must re-confirm it.
    error NeedsReconfirmation(uint256 orderId, uint256 chainId);
    error NotAnEthereumToken(address token);
    error NotAVaultToken(address token);

    /// @notice The factory this template and its clones belong to.
    function FACTORY() external view returns (address);

    /// @notice How long a settled order waits before its shares can be claimed: 24 hours.
    function MINT_LOCK() external view returns (uint256);
    /// @notice The latest an order's deadline may be, after opening it: 6 hours.
    function MAX_ORDER_LIFE() external view returns (uint256);
    /// @notice After its deadline, how long an unsettled order is left to its minter before anyone may fail it: 6 hours.
    function SETTLE_GRACE() external view returns (uint256);
    /// @notice The most of the supply that may become claimable in any 24 hours: 4%.
    function MINT_CAP() external view returns (uint256);
    /// @notice How long a contradiction freezes this index's mints on a chain: 14 days.
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

    /// @notice Anyone. For a locked order whose chain froze after it settled: proofs from after each such freeze that
    ///         the intake is unchanged. Chains that did not freeze take an empty proof.
    function reconfirmOrder(uint256 orderId, bytes[] calldata proofs) external;

    /// @notice Anyone, after the lock. Mints the order's shares to its minter and tells each vault the deposits joined
    ///         the index.
    function claimOrder(uint256 orderId) external;

    /// @notice An open order's minter at any time, or anyone SETTLE_GRACE after its deadline. The escrow is booked as
    ///         the minter's claims, and each vault is told to refund the deposits.
    function failOrder(uint256 orderId) external;

    /// @notice Anyone, during a locked order's lock. `proof` shows `chainId`'s intake at a block after the deadline
    ///         other than the order rests on: the order fails as {failOrder} does, and the chain's mints freeze.
    function voidOrder(uint256 orderId, uint256 chainId, bytes calldata proof) external;

    /// @notice Anyone, after an intake's deadline, for an intake that belongs to no order: tells the vault to refund
    ///         whatever was deposited there.
    function failIntake(uint256 chainId, uint256 intakeId) external;

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
    /// @notice Shares that could become claimable now without breaking MINT_CAP.
    function mintRoom() external view returns (uint256);
    /// @notice When the latest freeze of `chainId` began and when it ends, the factory's or this index's own: an order
    ///         settled before `start` needs re-confirming before it can be claimed.
    function chainFreeze(uint256 chainId) external view returns (uint256 start, uint256 until);
    function vaultBacking(address token) external view returns (uint256);
    function escrowed(address token) external view returns (uint256);
    function claimOf(address account, address token) external view returns (uint256);
    function totalClaims(address token) external view returns (uint256);
    function orderCount() external view returns (uint256);
    function messageNonce() external view returns (uint256);
}
