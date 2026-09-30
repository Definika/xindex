// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEthereumEventVerifier} from "./IEthereumEventVerifier.sol";
import {IStateReader} from "./IStateReader.sol";

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

    /// @notice A vault's settings, fixed at deployment but for what governance messages change.
    /// @param sourceChainId Ethereum's chain id, which every message must name.
    /// @param factory The factory on Ethereum.
    /// @param hubImplementation The hub template on Ethereum that every index is a clone of.
    /// @param verifier1 P1, the first Ethereum-event verifier on this chain.
    /// @param verifier2 P2, the second, independent one.
    /// @param freezer The guardian's freeze address on this chain.
    /// @param recoveryProposer The owner's emergency multisig on this chain, which can propose a successor pair of
    ///        verifiers only while the vault is stalled.
    /// @param stateReader Reads Ethereum's state under a checkpoint's root, for a snapshot exit.
    /// @param nativeCap The quantity cap on the native coin across all indexes.
    /// @param nativeFloor The native coin's outflow floor (section 1, proposal 5 of the Stage B spec).
    struct Config {
        uint256 sourceChainId;
        address factory;
        address hubImplementation;
        IEthereumEventVerifier verifier1;
        IEthereumEventVerifier verifier2;
        address freezer;
        address recoveryProposer;
        IStateReader stateReader;
        uint256 nativeCap;
        uint256 nativeFloor;
    }

    /// @notice A successor pair of verifiers under review, adoptable from `reviewEnds`.
    struct Successor {
        address p1;
        address p2;
        uint64 reviewEnds;
    }

    /// @notice A successor pair's continuity test: each of the two proves the vault's last checkpoint, a recent one, and
    ///         the last message the vault delivered.
    struct Continuity {
        bytes last1;
        bytes last2;
        bytes recent1;
        bytes recent2;
        bytes message1;
        bytes message2;
    }

    /// @notice A burn or a migration accepted from Ethereum and not yet paid in full. A migration's recipient is the
    ///         new index, whose balance it is paid into (`toIndex`).
    struct Owed {
        address token;
        bool toIndex;
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
    event MigrationAccepted(
        address indexed index, bytes32 indexed id, address token, uint256 amount, address indexed newIndex
    );
    event CapSet(address indexed token, uint256 cap, uint256 outflowFloor);
    event Frozen(uint256 until, address indexed by);
    event FreezerChanged(address indexed freezer);
    event VerifiersRotated(address indexed p1, address indexed p2);
    event CheckpointAdvanced(uint256 blockNumber, uint256 timestamp, bytes32 stateRoot);
    event SuccessorProposed(address indexed p1, address indexed p2, uint256 reviewEnds);
    event SuccessorVetoed(uint256 vetoes);
    event SuccessorLapsed();
    event SuccessorAdopted(address indexed p1, address indexed p2);
    event SnapshotBegun(uint256 blockNumber, uint256 timestamp, bytes32 stateRoot);
    event SnapshotClaimed(address indexed index, address indexed holder, address recipient, uint256 amount, bytes32 id);
    event IntakeResolved(address indexed index, uint256 indexed intakeId, bool settled);
    event ChangeQueued(bytes32 indexed key, uint8 kind, bytes body, uint256 readyAt);
    event ChangeApplied(bytes32 indexed key);
    event ChangeCancelled(bytes32 indexed key);

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
    error NothingOwed(address index, bytes32 id);
    error NothingPayable(address index, bytes32 id);
    error PaymentFailed(address recipient);
    error NothingToRefund();
    error NotFreezer(address caller);
    error NotAContract(address account);
    error OutflowOverflow();
    /// @notice P1 and P2 must be two different verifiers, or "P1 and P2" would be one proof.
    error VerifiersNotDistinct();
    /// @notice The vault has seen no new checkpoint since `since`, less STALL_PERIOD: it takes no deposit.
    error VaultStalled(uint256 since);
    /// @notice A checkpoint must be newer than the last in blocks and time, not in the future, and carry a state.
    error NotNewer(uint256 blockNumber, uint256 timestamp);
    /// @notice A successor must prove a checkpoint within STALL_PERIOD of now.
    error NotRecent(uint256 timestamp);
    /// @notice Only the owner's emergency multisig proposes a successor.
    error NotRecoveryProposer(address caller);
    /// @notice A successor can be proposed only once the vault has stalled, from `since`.
    error NotStalled(uint256 since);
    error SuccessorPending(uint256 reviewEnds);
    error NoSuccessor();
    /// @notice The successor does not prove what the pair in force last accepted.
    error Discontinuous();
    error VetoesExhausted();
    error ReviewNotOver(uint256 reviewEnds);
    error SnapshotTaken();
    error NoSnapshot();
    error SnapshotNotDue(uint256 due);
    error NoCheckpoint();
    /// @notice After a snapshot exit, a message from a block after its checkpoint never runs.
    error IssuedAfterSnapshot(uint256 blockNumber);
    error AlreadyClaimed(address index, address holder);
    /// @notice The component at that position of the index is not this chain's coin.
    error WrongComponent(uint256 component);
    /// @notice The holder registered `registered` as its recovery address on this chain, and is paid only there.
    error WrongRecipient(address registered);
    error BadSignature();
    /// @notice A governance message no newer than the last of its kind the vault took.
    error StaleGovernance(uint256 nonce, uint256 last);
    /// @notice A message that moves coins or loosens a rule, from a block after the vault's checkpoint: advance it first.
    error NotCheckpointed(uint256 blockNumber, uint256 checkpoint);
    error NoPendingChange(bytes32 key);
    error ChangeNotReady(bytes32 key, uint256 readyAt);

    /// @notice Largest share of an index's balance of a token that may leave in any 24 hours: 4%.
    function SPEED_LIMIT() external view returns (uint256);

    /// @notice How long a freeze lasts: 14 days.
    function FREEZE_DURATION() external view returns (uint256);

    /// @notice How far ahead a first deposit may set an intake's deadline: 7 days.
    function MAX_INTAKE_LIFE() external view returns (uint256);

    /// @notice A week without a new checkpoint stalls the vault (design 6.9).
    function STALL_PERIOD() external view returns (uint256);

    /// @notice How long a successor pair is reviewed before it can be adopted: 30 days.
    function RECOVERY_DELAY() external view returns (uint256);

    /// @notice How many successors the freezer can veto in one stall: 2.
    function MAX_RECOVERY_VETOES() external view returns (uint256);

    /// @notice How long after a stall began the snapshot exit may begin, if no successor was adopted: 180 days.
    function SNAPSHOT_EXIT_DELAY() external view returns (uint256);

    /// @notice How long a raised cap or floor, a new freezer or new verifiers wait on the vault before they apply: 7 days,
    ///         during which the freezer can cancel a raise or a rotation and watchers compare it with Ethereum.
    function GOVERNANCE_DELAY() external view returns (uint256);

    /// @notice The owner's emergency multisig on this chain: it can do nothing but propose a successor in a stall.
    function RECOVERY_PROPOSER() external view returns (address);

    /// @notice The reader of Ethereum's state a snapshot exit pays from.
    function STATE_READER() external view returns (IStateReader);

    /// @notice The last final Ethereum block P1 and P2 both proved.
    function checkpoint() external view returns (IEthereumEventVerifier.Checkpoint memory);

    /// @notice The checkpoint of the snapshot exit; zero until it begins.
    function snapshot() external view returns (IEthereumEventVerifier.Checkpoint memory);

    /// @notice The successor pair under review, if any.
    function successor() external view returns (Successor memory);

    /// @notice The id of the last message delivered, which a successor must prove again.
    function lastMessage() external view returns (bytes32);

    /// @notice The freezer's vetoes in the current stall, while the checkpoint it began after is unchanged.
    function vetoes() external view returns (uint256);

    /// @notice The factory's nonce of the last governance message taken on both proofs for `key`: its kind shifted
    ///         above the token's address, the token being a cap's and zero otherwise.
    function governanceNonce(bytes32 key) external view returns (uint256);

    /// @notice The hash of the change waiting under `key`, `keccak256(abi.encode(body, readyAt))`, or zero.
    function pendingChange(bytes32 key) external view returns (bytes32);

    /// @notice Anyone, from `readyAt` and, but for a freezer change, while not frozen: applies the waiting change that
    ///         `ChangeQueued` announced.
    function applyChange(uint8 kind, bytes calldata body, uint256 readyAt) external;

    /// @notice The freezer only: drops a waiting cap raise or rotation. It cannot drop its own replacement.
    function cancelChange(bytes32 key) external;

    /// @notice Whether `holder` has claimed its snapshot share of `index`.
    function snapshotClaimed(address index, address holder) external view returns (bool);

    /// @notice Whether a week has passed since the last checkpoint.
    function stalled() external view returns (bool);

    /// @notice When the vault stalls, or stalled: STALL_PERIOD after the last checkpoint.
    function stallStart() external view returns (uint256);

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
    /// @notice Everything paid out of the index's balance of `token`: to burn recipients, and into other indexes'
    ///         balances by migration. It can never exceed what the index sent out in BURN and MIGRATE messages.
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

    /// @notice Anyone, while not frozen. Pays what the speed limit now allows of an owed burn or migration.
    function release(address index, bytes32 id) external;

    /// @notice A depositor of a failed intake, while not frozen. Takes their deposit back.
    function refund(address index, uint256 intakeId) external;

    /// @notice The guardian's freeze address only, before any snapshot exit. Freezes the vault for FREEZE_DURATION.
    function freeze() external;

    /// @notice Anyone, before a snapshot exit. Records a final Ethereum block both P1 and P2 prove, newer than the last:
    ///         what keeps the vault out of a stall. Lapses any successor under review.
    function advanceCheckpoint(bytes calldata proof1, bytes calldata proof2) external;

    /// @notice RECOVERY_PROPOSER only, while stalled, before a snapshot exit, with none under review. Proposes a
    ///         successor pair, which must prove the last checkpoint, a recent one, and the last message delivered.
    function proposeSuccessor(IEthereumEventVerifier newP1, IEthereumEventVerifier newP2, Continuity calldata proofs)
        external;

    /// @notice The freezer only, at most MAX_RECOVERY_VETOES times a stall. Drops the successor under review.
    function vetoSuccessor() external;

    /// @notice Anyone, once the review is over, with a recent checkpoint the successor proves. Makes it P1 and P2.
    function adoptSuccessor(bytes calldata proof1, bytes calldata proof2) external;

    /// @notice Anyone, SNAPSHOT_EXIT_DELAY after the stall began. Takes the last checkpoint as the snapshot for good:
    ///         from then on no message from a later Ethereum block runs, and holders at it claim directly.
    function beginSnapshot() external;

    /// @notice Anyone, after the snapshot. Pays `holder`'s share of this chain's coin in `index` at the snapshot, its
    ///         shares at the units then in force plus its claim, to `recipient`: the recovery address it registered in
    ///         the hub for this chain, or else the one it signed for. Within the speed limit, as every payout.
    /// @param component The coin's position among the index's components.
    /// @param proof The state reader's proof of the holder's balance, the component, the claim and the recovery address.
    /// @param signature The holder's EIP-712 `SnapshotClaim(index, holder, recipient)`, if it registered none.
    function claimSnapshot(
        address index,
        address holder,
        address recipient,
        uint256 component,
        bytes calldata proof,
        bytes calldata signature
    ) external;

    /// @notice Anyone, after the snapshot. Settles an open intake if the hub had sent its settle message by the snapshot,
    ///         and otherwise fails it so its depositors can take their coins back.
    function resolveIntake(address index, uint256 intakeId, bytes calldata proof) external;
}
