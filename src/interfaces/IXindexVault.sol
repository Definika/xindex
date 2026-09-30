// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEthereumEventVerifier} from "./IEthereumEventVerifier.sol";

/// @notice A vault on another chain holding that chain's native coin for every index whose shares live on Ethereum.
///         No owner, no upgrade. Coins come in only as deposits to an intake (a mint order or a rebalance delivery)
///         and leave only on messages proven to be final on Ethereum, within a speed limit.
interface IXindexVault {
    /// @notice The life of an intake: None until its first deposit, then Open, then Settled or Failed for good.
    enum IntakeState {
        None,
        Open,
        Settled,
        Failed
    }

    /// @notice A burn accepted from Ethereum and not yet paid in full.
    struct Owed {
        address token;
        address recipient;
        uint256 remaining;
    }

    event IndexRegistered(address indexed index, bytes32 salt);
    event Deposited(
        address indexed index, uint256 indexed intakeId, address indexed depositor, address token, uint256 amount
    );
    event MessageDelivered(bytes32 indexed id, uint8 kind, address indexed index);
    event BurnAccepted(address indexed index, bytes32 indexed id, address token, uint256 amount, address recipient);
    event Paid(address indexed index, bytes32 indexed id, address recipient, uint256 amount, uint256 remaining);
    event IntakeSettled(address indexed index, uint256 indexed intakeId);
    event IntakeFailed(address indexed index, uint256 indexed intakeId);
    event Refunded(
        address indexed index, uint256 indexed intakeId, address indexed depositor, address token, uint256 amount
    );
    event Migrated(address indexed from, address indexed to, address token, uint256 amount);
    event CapSet(address indexed token, uint256 cap, uint256 outflowFloor);
    event Frozen(uint256 until, address indexed by);
    event FreezerChanged(address indexed freezer);
    event VerifiersRotated(address indexed p1, address indexed p2);

    error ZeroAddress();
    error ZeroAmount();
    error NotAnIndex(address index);
    error VaultFrozen(uint256 until);
    error IntakeClosed(address index, uint256 intakeId);
    error IntakeTooLong(uint256 deadline);
    error CapExceeded(address token, uint256 held, uint256 cap);
    error NoProof();
    error ProofsDisagree();
    error NotAVaultMessage(bytes32 topic0);
    error IdMismatch(bytes32 id);
    error WrongRoute();
    error WrongEmitter(address emitter);
    error BothProofsRequired(uint8 kind);
    error UnknownKind(uint8 kind);
    error AlreadyDelivered(bytes32 id);
    error NotAnAddress(bytes32 value);
    error IntakeNotOpen(address index, uint256 intakeId);
    error InsufficientBalance(address index, address token, uint256 balance, uint256 amount);
    error NothingOwed(address index, bytes32 id);
    error NothingPayable(address index, bytes32 id);
    error PaymentFailed(address recipient);
    error NothingToRefund();
    error NotFreezer(address caller);
    error NotAContract(address account);
    error OutflowOverflow();
    /// @notice P1 and P2 must be two different verifiers, or "P1 and P2" would be one proof.
    error VerifiersNotDistinct();

    /// @notice Largest share of an index's balance of a token that may leave in any 24 hours: 4%.
    function SPEED_LIMIT() external view returns (uint256);

    /// @notice How long a freeze lasts: 14 days.
    function FREEZE_DURATION() external view returns (uint256);

    /// @notice How far ahead a first deposit may set an intake's deadline: 7 days.
    function MAX_INTAKE_LIFE() external view returns (uint256);

    /// @notice The chain id messages must come from: Ethereum's.
    function SOURCE_CHAIN_ID() external view returns (uint256);

    /// @notice The factory on Ethereum: the emitter of governance messages and the deployer of every index.
    function FACTORY() external view returns (address);

    /// @notice The hub template on Ethereum every index is a clone of.
    function HUB_IMPLEMENTATION() external view returns (address);

    function p1() external view returns (IEthereumEventVerifier);
    function p2() external view returns (IEthereumEventVerifier);
    function freezer() external view returns (address);
    function frozenUntil() external view returns (uint256);

    function isIndex(address index) external view returns (bool);
    function balance(address index, address token) external view returns (uint256);
    function paidTotal(address index, address token) external view returns (uint256);
    function held(address token) external view returns (uint256);
    function cap(address token) external view returns (uint256);
    function outflowFloor(address token) external view returns (uint256);
    function used(bytes32 id) external view returns (bool);
    function intakeState(address index, uint256 intakeId) external view returns (IntakeState);
    function intakeTotal(address index, uint256 intakeId, address token) external view returns (uint256);
    function deposited(address index, uint256 intakeId, address token, address depositor)
        external
        view
        returns (uint256);

    /// @notice The 32-byte commitment to an index's balances and paid totals that Ethereum proves.
    function indexDigest(address index) external view returns (bytes32);

    /// @notice The 32-byte commitment to an intake's state and deposit totals that Ethereum proves.
    function intakeDigest(address index, uint256 intakeId) external view returns (bytes32);

    function owed(address index, bytes32 id) external view returns (Owed memory);
    function indexTokens(address index) external view returns (address[] memory);
    function intakeTokens(address index, uint256 intakeId) external view returns (address[] memory);

    /// @notice What the index's payouts of `token` have used of the speed limit over the last 25 hourly buckets.
    function recentOutflow(address index, address token) external view returns (uint256);

    /// @notice What more of `token` the index may pay out now under the speed limit.
    function available(address index, address token) external view returns (uint256);

    /// @notice Anyone. Records `index` as an index once its address is shown to be the factory's clone of the hub
    ///         template under `salt`. Only a registered index takes deposits.
    function registerIndex(address index, bytes32 salt) external;

    /// @notice Anyone, while not frozen. Deposits the native coin sent into intake `intakeId` of `index`.
    function deposit(address index, uint256 intakeId) external payable;

    /// @notice Anyone. Runs one message proven final on Ethereum by P1 (`proof1`), P2 (`proof2`) or both.
    function deliver(bytes calldata proof1, bytes calldata proof2) external;

    /// @notice Anyone, while not frozen. Pays what the speed limit now allows of an owed burn.
    function release(address index, bytes32 id) external;

    /// @notice A depositor of a failed intake, while not frozen. Takes their deposit back.
    function refund(address index, uint256 intakeId) external;

    /// @notice The guardian's freeze address only. Freezes the vault for FREEZE_DURATION from now.
    function freeze() external;
}
