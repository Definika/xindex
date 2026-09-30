// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IXindexVault} from "../interfaces/IXindexVault.sol";
import {IEthereumEventVerifier} from "../interfaces/IEthereumEventVerifier.sol";
import {IStateReader} from "../interfaces/IStateReader.sol";
import {VaultMessages} from "../libraries/VaultMessages.sol";
import {VaultSnapshot} from "./VaultSnapshot.sol";

/// @title XindexVault
/// @notice The vault an EVM chain (BNB Chain, HyperEVM, Tron) runs for every index whose shares live on Ethereum. It
///         holds the chain's native coin in a separate balance per index, takes coins in only as deposits to an intake,
///         and lets them out only on messages that P1 and P2, two independent proofs of Ethereum's finality, show were
///         sent by that index or by the factory. Payouts stay within a speed limit, exact over any 24 hours.
/// @dev No owner, no upgrade. Every coin the vault accounts for is in `held`: settled balances plus the deposits of
///      open and failed intakes not yet refunded. State is written before any coin moves, and every entry point that
///      can move a coin shares one reentrancy guard. If Ethereum's formats change unannounced and P1 and P2 stop
///      working, the vault stalls, may adopt a successor pair after a continuity test and 30 days of review, and after
///      180 days pays each index's holders at its last checkpoint directly (design 6.9).
contract XindexVault is IXindexVault, ReentrancyGuard {
    /// @inheritdoc IXindexVault
    uint256 public constant SPEED_LIMIT = 0.04e18;
    /// @inheritdoc IXindexVault
    uint256 public constant FREEZE_DURATION = 14 days;
    /// @inheritdoc IXindexVault
    uint256 public constant MAX_INTAKE_LIFE = 7 days;
    /// @inheritdoc IXindexVault
    uint256 public constant STALL_PERIOD = 7 days;
    /// @inheritdoc IXindexVault
    uint256 public constant RECOVERY_DELAY = 30 days;
    /// @inheritdoc IXindexVault
    uint256 public constant MAX_RECOVERY_VETOES = 2;
    /// @inheritdoc IXindexVault
    uint256 public constant SNAPSHOT_EXIT_DELAY = 180 days;
    /// @inheritdoc IXindexVault
    uint256 public constant GOVERNANCE_DELAY = 7 days;

    uint256 private constant WAD = 1e18;
    /// @dev The current hour and the 24 before it: every real 24-hour span lies inside them.
    uint256 private constant BUCKETS = 25;
    uint256 private constant HOUR = 1 hours;
    address private constant NATIVE = address(0);
    bytes32 private constant INDEX_DIGEST_DOMAIN = keccak256("xindex.v4.vault.index-digest");
    bytes32 private constant INTAKE_DIGEST_DOMAIN = keccak256("xindex.v4.vault.intake-digest");

    /// @dev The hub's storage the vault itself reads at its snapshot (`HybridHubStorage`), pinned by
    ///      `test_theHubLayoutIsPinned` against the compiler's layout: `_settledIntakes` (60) and `_sentMessages` (62).
    ///      A holder's claim reads more, in `VaultSnapshot`.
    uint256 private constant HUB_SETTLED_INTAKES_SLOT = 60;
    uint256 private constant HUB_SENT_MESSAGES_SLOT = 62;
    /// @dev The key of a waiting freezer change, which the freezer may not cancel and a freeze does not hold.
    bytes32 private constant FREEZER_KEY = bytes32(uint256(VaultMessages.FREEZER_CHANGE) << 160);
    bytes32 private constant SNAPSHOT_CLAIM_TYPEHASH =
        keccak256("SnapshotClaim(address index,address holder,address recipient)");

    /// @inheritdoc IXindexVault
    uint256 public immutable SOURCE_CHAIN_ID;
    /// @inheritdoc IXindexVault
    address public immutable FACTORY;
    /// @inheritdoc IXindexVault
    address public immutable HUB_IMPLEMENTATION;
    /// @inheritdoc IXindexVault
    address public immutable RECOVERY_PROPOSER;
    /// @inheritdoc IXindexVault
    IStateReader public immutable STATE_READER;

    /// @inheritdoc IXindexVault
    IEthereumEventVerifier public p1;
    /// @inheritdoc IXindexVault
    IEthereumEventVerifier public p2;
    /// @inheritdoc IXindexVault
    address public freezer;
    /// @inheritdoc IXindexVault
    uint256 public frozenUntil;

    /// @inheritdoc IXindexVault
    mapping(address index => bool) public isIndex;
    /// @inheritdoc IXindexVault
    mapping(address index => mapping(address token => uint256)) public balance;
    /// @inheritdoc IXindexVault
    mapping(address index => mapping(address token => uint256)) public paidTotal;
    /// @inheritdoc IXindexVault
    mapping(address token => uint256) public held;
    /// @inheritdoc IXindexVault
    mapping(address token => uint256) public cap;
    /// @inheritdoc IXindexVault
    mapping(address token => uint256) public outflowFloor;
    /// @inheritdoc IXindexVault
    mapping(bytes32 id => bool) public used;
    /// @inheritdoc IXindexVault
    mapping(address index => mapping(uint256 intakeId => IntakeState)) public intakeState;
    /// @inheritdoc IXindexVault
    mapping(address index => mapping(uint256 intakeId => mapping(address token => uint256))) public intakeTotal;
    /// @inheritdoc IXindexVault
    mapping(
        address index => mapping(uint256 intakeId => mapping(address token => mapping(address depositor => uint256)))
    ) public deposited;
    /// @inheritdoc IXindexVault
    mapping(address index => bytes32) public indexDigest;
    /// @inheritdoc IXindexVault
    mapping(address index => mapping(uint256 intakeId => bytes32)) public intakeDigest;

    mapping(address index => address[]) private _indexTokens;
    mapping(address index => mapping(address token => bool)) private _indexHasToken;
    mapping(address index => mapping(uint256 intakeId => address[])) private _intakeTokens;
    mapping(address index => mapping(uint256 intakeId => mapping(address token => bool))) private _intakeHasToken;
    mapping(address index => mapping(bytes32 id => Owed)) private _owed;

    /// @dev One hour's payouts, tagged with the hour so a stale slot reads as empty.
    struct Bucket {
        uint64 hour;
        uint192 amount;
    }

    mapping(address index => mapping(address token => Bucket[BUCKETS])) private _outflow;

    IEthereumEventVerifier.Checkpoint private _checkpoint;
    IEthereumEventVerifier.Checkpoint private _snapshot;
    Successor private _successor;
    /// @inheritdoc IXindexVault
    bytes32 public lastMessage;
    /// @inheritdoc IXindexVault
    uint256 public vetoes;
    /// @dev The checkpoint whose stall `vetoes` counts, by its block: a new checkpoint begins a new count.
    uint256 private _vetoStall;
    /// @inheritdoc IXindexVault
    mapping(address index => mapping(address holder => bool)) public snapshotClaimed;
    /// @inheritdoc IXindexVault
    mapping(bytes32 key => uint256) public governanceNonce;
    /// @inheritdoc IXindexVault
    mapping(bytes32 key => bytes32) public pendingChange;

    /// @param config The vault's settings: see {Config}.
    constructor(Config memory config) {
        if (
            config.factory == address(0) || config.hubImplementation == address(0)
                || address(config.verifier1) == address(0) || address(config.verifier2) == address(0)
                || config.freezer == address(0) || config.recoveryProposer == address(0)
        ) revert ZeroAddress();
        _checkPair(address(config.verifier1), address(config.verifier2));
        if (address(config.stateReader).code.length == 0) revert NotAContract(address(config.stateReader));
        SOURCE_CHAIN_ID = config.sourceChainId;
        FACTORY = config.factory;
        HUB_IMPLEMENTATION = config.hubImplementation;
        RECOVERY_PROPOSER = config.recoveryProposer;
        STATE_READER = config.stateReader;
        p1 = config.verifier1;
        p2 = config.verifier2;
        freezer = config.freezer;
        cap[NATIVE] = config.nativeCap;
        outflowFloor[NATIVE] = config.nativeFloor;
        // Its first week's grace: a stall is a week without a new checkpoint, counted from deployment until the first.
        // A block timestamp fits 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        _checkpoint.timestamp = uint64(block.timestamp);
        emit CapSet(NATIVE, config.nativeCap, config.nativeFloor);
    }

    // ---------------------------------------------------------------------
    // Indexes and deposits
    // ---------------------------------------------------------------------

    /// @inheritdoc IXindexVault
    function registerIndex(address index, bytes32 salt) external {
        if (Clones.predictDeterministicAddress(HUB_IMPLEMENTATION, salt, FACTORY) != index) revert NotAnIndex(index);
        if (isIndex[index]) return;
        isIndex[index] = true;
        emit IndexRegistered(index, salt);
        _refreshIndexDigest(index);
    }

    /// @inheritdoc IXindexVault
    function deposit(address index, uint256 intakeId) external payable nonReentrant {
        if (!isIndex[index]) revert NotAnIndex(index);
        _checkNotFrozen();
        // A stalled vault may never again see the message that would settle or fail an intake.
        if (stalled()) revert VaultStalled(stallStart());
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();
        uint256 deadline = intakeId >> 192; // an intake id is `(deadline << 192) | nonce` (VaultMessages)
        if (block.timestamp > deadline) revert IntakeClosed(index, intakeId);
        IntakeState state = intakeState[index][intakeId];
        if (state == IntakeState.None) {
            if (deadline > block.timestamp + MAX_INTAKE_LIFE) revert IntakeTooLong(deadline);
            intakeState[index][intakeId] = IntakeState.Open;
        } else if (state != IntakeState.Open) {
            revert IntakeClosed(index, intakeId);
        }
        uint256 newHeld = held[NATIVE] + amount;
        if (newHeld > cap[NATIVE]) revert CapExceeded(NATIVE, newHeld, cap[NATIVE]);
        held[NATIVE] = newHeld;
        deposited[index][intakeId][NATIVE][msg.sender] += amount;
        intakeTotal[index][intakeId][NATIVE] += amount;
        if (!_intakeHasToken[index][intakeId][NATIVE]) {
            _intakeHasToken[index][intakeId][NATIVE] = true;
            _intakeTokens[index][intakeId].push(NATIVE);
        }
        emit Deposited(index, intakeId, msg.sender, NATIVE, amount);
        _refreshIntakeDigest(index, intakeId);
    }

    // ---------------------------------------------------------------------
    // Messages from Ethereum
    // ---------------------------------------------------------------------

    /// @inheritdoc IXindexVault
    function deliver(bytes calldata proof1, bytes calldata proof2) external nonReentrant {
        (uint256 blockNumber, address emitter, bytes memory payload, bool both) = _prove(proof1, proof2);
        // After a snapshot exit, only what Ethereum sent by its checkpoint may run: the holders at it are paid directly.
        uint256 snapshotBlock = _snapshot.blockNumber;
        if (snapshotBlock != 0 && blockNumber > snapshotBlock) revert IssuedAfterSnapshot(blockNumber);
        bytes32 id = keccak256(payload);
        VaultMessages.Message memory m = VaultMessages.decode(payload);
        // Checked before anything reads the kind: dispatch below treats every kind it does not name as the last one.
        if (m.kind == 0 || m.kind > VaultMessages.VERIFIER_ROTATION) revert UnknownKind(m.kind);
        _checkRoute(m);
        bool governance = m.kind >= VaultMessages.CAP_UPDATE;
        if (governance ? (emitter != FACTORY || m.index != FACTORY) : emitter != m.index) revert WrongEmitter(emitter);
        // Any Ethereum contract can emit a VaultMessage naming itself; only the factory's clones of the hub are indexes.
        if (!governance && !isIndex[m.index]) revert NotAnIndex(m.index);
        bool loosening = _needsBoth(m);
        if (!both && loosening) revert BothProofsRequired(m.kind);
        // A message that moves coins or loosens a rule runs only from a block the vault's checkpoint covers, so a
        // snapshot at that checkpoint never pays twice what such a message already paid (VLT-3).
        if (loosening && blockNumber > _checkpoint.blockNumber) {
            revert NotCheckpointed(blockNumber, _checkpoint.blockNumber);
        }
        if (used[id]) revert AlreadyDelivered(id);
        used[id] = true;
        lastMessage = id;
        emit MessageDelivered(id, m.kind, m.index);

        if (m.kind < VaultMessages.CAP_UPDATE) _indexMessage(m, id);
        else _governanceMessage(m, loosening, both);
    }

    /// @inheritdoc IXindexVault
    function deliverRecorded(bytes calldata payload, bytes calldata proof) external nonReentrant {
        bytes32 id = keccak256(payload);
        VaultMessages.Message memory m = VaultMessages.decode(payload);
        // Every other kind in flight at the snapshot resolves without one: an intake's through `resolveIntake`, and
        // governance not at all.
        if (m.kind != VaultMessages.BURN && m.kind != VaultMessages.MIGRATE) revert UnknownKind(m.kind);
        _checkRoute(m);
        if (!isIndex[m.index]) revert NotAnIndex(m.index);
        // The index marks each burn and migration in the transaction that sends it, and only it writes its storage, so
        // its mark at the snapshot shows the index sent this message by then.
        if (_readHub(m.index, keccak256(abi.encode(id, HUB_SENT_MESSAGES_SLOT)), proof) == bytes32(0)) {
            revert NotRecorded(id);
        }
        if (used[id]) revert AlreadyDelivered(id);
        used[id] = true;
        // forge-lint: disable-next-line(reentrancy-events)
        emit MessageDelivered(id, m.kind, m.index);
        _indexMessage(m, id);
    }

    function _checkRoute(VaultMessages.Message memory m) private view {
        if (
            m.sourceChainId != SOURCE_CHAIN_ID || m.destChainId != block.chainid
                || m.vault != bytes32(uint256(uint160(address(this))))
        ) revert WrongRoute();
    }

    function _indexMessage(VaultMessages.Message memory m, bytes32 id) private {
        if (m.kind == VaultMessages.BURN) {
            _burn(m.index, id, m.body);
        } else if (m.kind == VaultMessages.INTAKE_SETTLED) {
            _settleIntake(m.index, abi.decode(m.body, (uint256)));
        } else if (m.kind == VaultMessages.INTAKE_FAILED) {
            _failIntake(m.index, abi.decode(m.body, (uint256)));
        } else {
            _migrate(m.index, id, m.body);
        }
    }

    /// @dev A freeze runs at once, always, but not after a snapshot: nothing could then replace the freezer, and nothing
    ///      may hold the exit off (VLT-5). Every other governance message must be newer than the last of its key taken on
    ///      both proofs, and only one taken on both proofs moves that mark, so one broken proof system cannot lock the
    ///      factory out with a forged nonce (VLT-4). A message that loosens nothing applies at once. One that loosens
    ///      waits GOVERNANCE_DELAY here, on the vault, where the freezer can see it and stop it however its proofs were
    ///      obtained (VLT-2).
    function _governanceMessage(VaultMessages.Message memory m, bool loosening, bool both) private {
        if (m.kind == VaultMessages.FREEZE) {
            _checkNoSnapshot();
            _freeze(FACTORY);
            return;
        }
        bytes32 key = _changeKey(m.kind, m.body);
        uint256 last = governanceNonce[key];
        if (m.nonce <= last) revert StaleGovernance(m.nonce, last);
        if (both) governanceNonce[key] = m.nonce;
        // Newer than whatever waits under its key, so it replaces that.
        if (loosening) {
            uint256 readyAt = block.timestamp + GOVERNANCE_DELAY;
            pendingChange[key] = keccak256(abi.encode(m.body, readyAt));
            emit ChangeQueued(key, m.kind, m.body, readyAt);
        } else {
            delete pendingChange[key];
            _applyChange(m.kind, m.body);
        }
    }

    /// @dev One mark and one waiting change per kind, and per token for a cap: the kind above the token's address.
    function _changeKey(uint8 kind, bytes memory body) private pure returns (bytes32) {
        address token = kind == VaultMessages.CAP_UPDATE ? _toAddress(abi.decode(body, (bytes32))) : address(0);
        return bytes32(uint256(kind) << 160 | uint160(token));
    }

    /// @inheritdoc IXindexVault
    function applyChange(uint8 kind, bytes calldata body, uint256 readyAt) external {
        bytes32 key = _changeKey(kind, body);
        if (pendingChange[key] != keccak256(abi.encode(body, readyAt))) revert NoPendingChange(key);
        if (block.timestamp < readyAt) revert ChangeNotReady(key, readyAt);
        // A freeze in force holds every change but the freezer's own replacement: a freezer that froze again and again
        // must not be able to keep itself in place.
        if (key != FREEZER_KEY) _checkNotFrozen();
        delete pendingChange[key];
        emit ChangeApplied(key);
        _applyChange(kind, body);
    }

    /// @inheritdoc IXindexVault
    function cancelChange(bytes32 key) external {
        // The freezer cannot block its own replacement.
        if (msg.sender != freezer || key == FREEZER_KEY) revert NotFreezer(msg.sender);
        if (pendingChange[key] == bytes32(0)) revert NoPendingChange(key);
        delete pendingChange[key];
        emit ChangeCancelled(key);
    }

    function _applyChange(uint8 kind, bytes memory body) private {
        if (kind == VaultMessages.CAP_UPDATE) {
            (bytes32 token, uint256 newCap, uint256 newFloor) = abi.decode(body, (bytes32, uint256, uint256));
            address t = _toAddress(token);
            cap[t] = newCap;
            outflowFloor[t] = newFloor;
            emit CapSet(t, newCap, newFloor);
        } else if (kind == VaultMessages.FREEZER_CHANGE) {
            address newFreezer = _toAddress(abi.decode(body, (bytes32)));
            if (newFreezer == address(0)) revert ZeroAddress();
            freezer = newFreezer;
            emit FreezerChanged(newFreezer);
        } else {
            (bytes32 a, bytes32 b) = abi.decode(body, (bytes32, bytes32));
            (address newP1, address newP2) = (_toAddress(a), _toAddress(b));
            _checkPair(newP1, newP2);
            p1 = IEthereumEventVerifier(newP1);
            p2 = IEthereumEventVerifier(newP2);
            emit VerifiersRotated(newP1, newP2);
        }
    }

    /// @dev Verifies one or both proofs and returns the log's block, its emitter and the message payload. With both,
    ///      P1 and P2 must prove the same log in the same block.
    function _prove(bytes calldata proof1, bytes calldata proof2)
        private
        view
        returns (uint256 blockNumber, address emitter, bytes memory payload, bool both)
    {
        both = proof1.length != 0 && proof2.length != 0;
        if (proof1.length != 0) {
            (blockNumber, emitter, payload) = _verify(p1, proof1);
            if (both) {
                (uint256 block2, address emitter2, bytes memory payload2) = _verify(p2, proof2);
                if (block2 != blockNumber || emitter2 != emitter || keccak256(payload2) != keccak256(payload)) {
                    revert ProofsDisagree();
                }
            }
        } else if (proof2.length != 0) {
            (blockNumber, emitter, payload) = _verify(p2, proof2);
        } else {
            revert NoProof();
        }
    }

    function _verify(IEthereumEventVerifier verifier, bytes calldata proof)
        private
        view
        returns (uint256 blockNumber, address emitter, bytes memory payload)
    {
        bytes32 topic0;
        bytes32 topic1;
        bytes memory data;
        (blockNumber, emitter, topic0, topic1, data) = verifier.verifyEvent(proof);
        if (topic0 != VaultMessages.EVENT_TOPIC) revert NotAVaultMessage(topic0);
        payload = abi.decode(data, (bytes));
        if (keccak256(payload) != topic1) revert IdMismatch(topic1);
    }

    /// @dev Whether a message needs both proofs: everything that moves coins or changes governance does. Only a freeze,
    ///      and a cap update that raises neither the cap nor the floor, may rest on one.
    function _needsBoth(VaultMessages.Message memory m) private view returns (bool) {
        if (m.kind == VaultMessages.FREEZE) return false;
        if (m.kind == VaultMessages.CAP_UPDATE) {
            (bytes32 token, uint256 newCap, uint256 newFloor) = abi.decode(m.body, (bytes32, uint256, uint256));
            address t = _toAddress(token);
            return newCap > cap[t] || newFloor > outflowFloor[t];
        }
        return true;
    }

    // ---------------------------------------------------------------------
    // Burns and the speed limit
    // ---------------------------------------------------------------------

    function _burn(address index, bytes32 id, bytes memory body) private {
        (bytes32 token, uint256 amount, bytes32 recipient) = abi.decode(body, (bytes32, uint256, bytes32));
        address t = _toAddress(token);
        address to = _toAddress(recipient);
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        _owed[index][id] = Owed({token: t, toIndex: false, recipient: to, remaining: amount});
        // Any call before this is a view: a verifier's, or the fixed state reader's in `deliverRecorded`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BurnAccepted(index, id, t, amount, to);
        _release(index, id, false);
    }

    /// @inheritdoc IXindexVault
    function release(address index, bytes32 id) external nonReentrant {
        _release(index, id, true);
    }

    /// @dev Pays what the speed limit, the index's balance and a freeze allow of an owed burn or migration. `strict`
    ///      is set for an explicit release, which reverts when it can pay nothing; a message just delivered keeps waiting
    ///      instead. A migration is paid into the new index's balance, so the coins stay in the vault and `held` stays.
    function _release(address index, bytes32 id, bool strict) private {
        Owed storage o = _owed[index][id];
        uint256 remaining = o.remaining;
        if (remaining == 0) revert NothingOwed(index, id);
        address token = o.token;
        uint256 pay =
            block.timestamp < frozenUntil ? 0 : _min(_min(remaining, available(index, token)), balance[index][token]);
        if (pay == 0) {
            if (strict) revert NothingPayable(index, id);
            return;
        }
        address recipient = o.recipient;
        bool toIndex = o.toIndex;
        o.remaining = remaining - pay;
        balance[index][token] -= pay;
        paidTotal[index][token] += pay;
        _recordOutflow(index, token, pay);
        // Only views precede a payout: the verifiers, or the fixed state reader of a snapshot claim, by staticcall.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Paid(index, id, recipient, pay, remaining - pay);
        _refreshIndexDigest(index);
        if (toIndex) {
            _credit(recipient, token, pay);
            _refreshIndexDigest(recipient);
        } else {
            held[token] -= pay;
            _send(recipient, pay);
        }
    }

    /// @inheritdoc IXindexVault
    function recentOutflow(address index, address token) public view returns (uint256 total) {
        total = 0;
        uint256 hour = block.timestamp / HOUR;
        Bucket[BUCKETS] storage buckets = _outflow[index][token];
        for (uint256 i = 0; i < BUCKETS; ++i) {
            Bucket memory b = buckets[i];
            if (b.hour + BUCKETS > hour) total += b.amount;
        }
    }

    /// @inheritdoc IXindexVault
    function available(address index, address token) public view returns (uint256) {
        uint256 recent = recentOutflow(index, token);
        uint256 limit = (balance[index][token] + recent) * SPEED_LIMIT / WAD;
        uint256 floor_ = outflowFloor[token];
        if (limit < floor_) limit = floor_;
        return limit > recent ? limit - recent : 0;
    }

    /// @dev An hour fits 64 bits for billions of years, and an amount is at most the vault's holdings, far below 2^192;
    ///      both bounds are checked anyway, so a wrapped bucket can never understate the outflow.
    function _recordOutflow(address index, address token, uint256 amount) private {
        uint256 hour = block.timestamp / HOUR;
        Bucket storage b = _outflow[index][token][hour % BUCKETS];
        uint256 total = b.hour == hour ? b.amount + amount : amount;
        if (hour > type(uint64).max || total > type(uint192).max) revert OutflowOverflow();
        // Both casts are bounded by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.hour = uint64(hour);
        // forge-lint: disable-next-line(unsafe-typecast)
        b.amount = uint192(total);
    }

    // ---------------------------------------------------------------------
    // Intakes
    // ---------------------------------------------------------------------

    function _settleIntake(address index, uint256 intakeId) private {
        IntakeState state = intakeState[index][intakeId];
        if (state == IntakeState.Settled || state == IntakeState.Failed) revert IntakeNotOpen(index, intakeId);
        intakeState[index][intakeId] = IntakeState.Settled;
        address[] storage tokens = _intakeTokens[index][intakeId];
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = tokens[i];
            _credit(index, t, intakeTotal[index][intakeId][t]);
        }
        // Only views precede this: the verifiers, or the fixed state reader of a snapshot, by staticcall.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IntakeSettled(index, intakeId);
        _refreshIntakeDigest(index, intakeId);
        _refreshIndexDigest(index);
    }

    function _failIntake(address index, uint256 intakeId) private {
        IntakeState state = intakeState[index][intakeId];
        if (state == IntakeState.Settled || state == IntakeState.Failed) revert IntakeNotOpen(index, intakeId);
        intakeState[index][intakeId] = IntakeState.Failed;
        // Only views precede this: the verifiers, or the fixed state reader of a snapshot, by staticcall.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IntakeFailed(index, intakeId);
        _refreshIntakeDigest(index, intakeId);
    }

    /// @inheritdoc IXindexVault
    function refund(address index, uint256 intakeId) external nonReentrant {
        if (intakeState[index][intakeId] != IntakeState.Failed) revert IntakeNotOpen(index, intakeId);
        _checkNotFrozen();
        uint256 amount = deposited[index][intakeId][NATIVE][msg.sender];
        if (amount == 0) revert NothingToRefund();
        deposited[index][intakeId][NATIVE][msg.sender] = 0;
        intakeTotal[index][intakeId][NATIVE] -= amount;
        held[NATIVE] -= amount;
        emit Refunded(index, intakeId, msg.sender, NATIVE, amount);
        _refreshIntakeDigest(index, intakeId);
        _send(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Migration and freeze
    // ---------------------------------------------------------------------

    /// @dev A migration leaves the old index's balance as a burn does, within the speed limit, so no message, forged or
    ///      not, can empty an index faster than its redeemers could (design invariant I5).
    function _migrate(address index, bytes32 id, bytes memory body) private {
        (address newIndex, bytes32 token, uint256 amount) = abi.decode(body, (address, bytes32, uint256));
        if (!isIndex[newIndex] || newIndex == index) revert NotAnIndex(newIndex);
        address t = _toAddress(token);
        if (amount == 0) revert ZeroAmount();
        _owed[index][id] = Owed({token: t, toIndex: true, recipient: newIndex, remaining: amount});
        // Any call before this is a view: a verifier's, or the fixed state reader's in `deliverRecorded`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MigrationAccepted(index, id, t, amount, newIndex);
        _release(index, id, false);
    }

    /// @inheritdoc IXindexVault
    function freeze() external {
        if (msg.sender != freezer) revert NotFreezer(msg.sender);
        // Nothing could replace the freezer after a snapshot, so it must not be able to hold the exit off for good.
        _checkNoSnapshot();
        _freeze(msg.sender);
    }

    function _freeze(address by) private {
        uint256 until = block.timestamp + FREEZE_DURATION;
        if (until > frozenUntil) frozenUntil = until;
        emit Frozen(frozenUntil, by);
    }

    function _checkNotFrozen() private view {
        if (block.timestamp < frozenUntil) revert VaultFrozen(frozenUntil);
    }

    // ---------------------------------------------------------------------
    // Checkpoints, stall recovery and the snapshot exit (design 6.9)
    // ---------------------------------------------------------------------

    /// @inheritdoc IXindexVault
    function advanceCheckpoint(bytes calldata proof1, bytes calldata proof2) external {
        _checkNoSnapshot();
        IEthereumEventVerifier.Checkpoint memory c = _agreed(p1, p2, proof1, proof2);
        _checkNewer(c);
        _checkpoint = c;
        emit CheckpointAdvanced(c.blockNumber, c.timestamp, c.stateRoot);
        // The pair in force works again: whatever stall a successor was proposed for is over.
        if (_successor.reviewEnds != 0) {
            delete _successor;
            emit SuccessorLapsed();
        }
    }

    /// @inheritdoc IXindexVault
    function stalled() public view returns (bool) {
        return block.timestamp > stallStart();
    }

    /// @inheritdoc IXindexVault
    function stallStart() public view returns (uint256) {
        return uint256(_checkpoint.timestamp) + STALL_PERIOD;
    }

    /// @inheritdoc IXindexVault
    function proposeSuccessor(IEthereumEventVerifier newP1, IEthereumEventVerifier newP2, Continuity calldata proofs)
        external
    {
        if (msg.sender != RECOVERY_PROPOSER) revert NotRecoveryProposer(msg.sender);
        _checkNoSnapshot();
        if (!stalled()) revert NotStalled(stallStart());
        if (_successor.reviewEnds != 0) revert SuccessorPending(_successor.reviewEnds);
        _checkPair(address(newP1), address(newP2));
        // (a) The last checkpoint the pair in force accepted.
        IEthereumEventVerifier.Checkpoint memory last = _agreed(newP1, newP2, proofs.last1, proofs.last2);
        if (keccak256(abi.encode(last)) != keccak256(abi.encode(_checkpoint))) revert Discontinuous();
        // (b) A recent one, which the successor's proof shows descends from it.
        _checkRecent(_agreed(newP1, newP2, proofs.recent1, proofs.recent2));
        // (c) The last message the pair in force delivered, if there was one.
        bytes32 last_ = lastMessage;
        if (last_ != bytes32(0)) {
            (,, bytes memory payload1) = _verify(newP1, proofs.message1);
            (,, bytes memory payload2) = _verify(newP2, proofs.message2);
            if (keccak256(payload1) != last_ || keccak256(payload2) != last_) revert Discontinuous();
        }
        uint256 reviewEnds = block.timestamp + RECOVERY_DELAY;
        // A timestamp 30 days ahead fits 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        _successor = Successor({p1: address(newP1), p2: address(newP2), reviewEnds: uint64(reviewEnds)});
        emit SuccessorProposed(address(newP1), address(newP2), reviewEnds);
    }

    /// @inheritdoc IXindexVault
    function vetoSuccessor() external {
        if (msg.sender != freezer) revert NotFreezer(msg.sender);
        if (_successor.reviewEnds == 0) revert NoSuccessor();
        uint256 stall = _checkpoint.blockNumber;
        uint256 count = _vetoStall == stall ? vetoes : 0;
        if (count >= MAX_RECOVERY_VETOES) revert VetoesExhausted();
        (vetoes, _vetoStall) = (count + 1, stall);
        delete _successor;
        emit SuccessorVetoed(count + 1);
    }

    /// @inheritdoc IXindexVault
    function adoptSuccessor(bytes calldata proof1, bytes calldata proof2) external {
        Successor memory s = _successor;
        // A snapshot clears any successor, and a new checkpoint lapses it, so a pending one is still in its stall.
        if (s.reviewEnds == 0) revert NoSuccessor();
        if (block.timestamp < s.reviewEnds) revert ReviewNotOver(s.reviewEnds);
        IEthereumEventVerifier.Checkpoint memory c =
            _agreed(IEthereumEventVerifier(s.p1), IEthereumEventVerifier(s.p2), proof1, proof2);
        _checkRecent(c);
        delete _successor;
        p1 = IEthereumEventVerifier(s.p1);
        p2 = IEthereumEventVerifier(s.p2);
        _checkpoint = c;
        emit SuccessorAdopted(s.p1, s.p2);
        emit CheckpointAdvanced(c.blockNumber, c.timestamp, c.stateRoot);
    }

    /// @inheritdoc IXindexVault
    function beginSnapshot() external {
        _checkNoSnapshot();
        IEthereumEventVerifier.Checkpoint memory last = _checkpoint;
        uint256 due = stallStart() + SNAPSHOT_EXIT_DELAY;
        if (block.timestamp < due) revert SnapshotNotDue(due);
        // Without a checkpoint there is no state to pay from, and no index could have been minted into here.
        if (last.stateRoot == bytes32(0)) revert NoCheckpoint();
        _snapshot = last;
        emit SnapshotBegun(last.blockNumber, last.timestamp, last.stateRoot);
        if (_successor.reviewEnds != 0) {
            delete _successor;
            emit SuccessorLapsed();
        }
    }

    /// @inheritdoc IXindexVault
    function claimSnapshot(
        address index,
        address holder,
        address recipient,
        uint256 component,
        bytes calldata proof,
        bytes calldata signature
    ) external nonReentrant {
        if (!isIndex[index]) revert NotAnIndex(index);
        if (recipient == address(0)) revert ZeroAddress();
        if (snapshotClaimed[index][holder]) revert AlreadyClaimed(index, holder);
        (uint256 amount, address registered) =
            VaultSnapshot.share(STATE_READER, _snapshotRoot(), index, holder, component, proof);
        if (registered != address(0)) {
            // A holder that registered a recovery address, such as a contract, is paid there and nowhere else.
            if (recipient != registered) revert WrongRecipient(registered);
        } else {
            VaultSnapshot.checkSignature(address(this), index, holder, recipient, signature);
        }
        snapshotClaimed[index][holder] = true;
        bytes32 id = keccak256(abi.encode(SNAPSHOT_CLAIM_TYPEHASH, index, holder));
        _owed[index][id] = Owed({token: NATIVE, toIndex: false, recipient: recipient, remaining: amount});
        // The only call before this is a view of the fixed state reader, by staticcall.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SnapshotClaimed(index, holder, recipient, amount, id);
        // Paid within the speed limit, as any payout: a snapshot of a forged checkpoint takes no more than a forged burn.
        _release(index, id, false);
    }

    /// @inheritdoc IXindexVault
    function resolveIntake(address index, uint256 intakeId, bytes calldata proof) external nonReentrant {
        if (intakeState[index][intakeId] != IntakeState.Open) revert IntakeNotOpen(index, intakeId);
        // The hub marks an intake settled in the transaction that sends its settle message, so its mark at the
        // checkpoint says whether that message was sent by then: nothing sent later will ever run here.
        bool settled = _readHub(index, keccak256(abi.encode(intakeId, HUB_SETTLED_INTAKES_SLOT)), proof) != bytes32(0);
        // forge-lint: disable-next-line(reentrancy-events)
        emit IntakeResolved(index, intakeId, settled);
        if (settled) _settleIntake(index, intakeId);
        else _failIntake(index, intakeId);
    }

    /// @inheritdoc IXindexVault
    function checkpoint() external view returns (IEthereumEventVerifier.Checkpoint memory) {
        return _checkpoint;
    }

    /// @inheritdoc IXindexVault
    function snapshot() external view returns (IEthereumEventVerifier.Checkpoint memory) {
        return _snapshot;
    }

    /// @inheritdoc IXindexVault
    function successor() external view returns (Successor memory) {
        return _successor;
    }

    /// @dev The checkpoint `a` and `b` both prove.
    function _agreed(IEthereumEventVerifier a, IEthereumEventVerifier b, bytes calldata proofA, bytes calldata proofB)
        private
        view
        returns (IEthereumEventVerifier.Checkpoint memory c)
    {
        c = a.verifyCheckpoint(proofA);
        if (keccak256(abi.encode(c)) != keccak256(abi.encode(b.verifyCheckpoint(proofB)))) revert ProofsDisagree();
    }

    /// @dev A checkpoint after the last, in blocks and in time, not in the future, and with a state to read.
    function _checkNewer(IEthereumEventVerifier.Checkpoint memory c) private view {
        IEthereumEventVerifier.Checkpoint memory last = _checkpoint;
        if (
            c.blockNumber <= last.blockNumber || c.timestamp <= last.timestamp || c.timestamp > block.timestamp
                || c.stateRoot == bytes32(0)
        ) revert NotNewer(c.blockNumber, c.timestamp);
    }

    /// @dev A newer checkpoint within STALL_PERIOD of now: one that would not leave the vault stalled.
    function _checkRecent(IEthereumEventVerifier.Checkpoint memory c) private view {
        _checkNewer(c);
        if (uint256(c.timestamp) + STALL_PERIOD < block.timestamp) revert NotRecent(c.timestamp);
    }

    function _checkPair(address a, address b) private view {
        if (a.code.length == 0) revert NotAContract(a);
        if (b.code.length == 0) revert NotAContract(b);
        if (a == b) revert VerifiersNotDistinct();
    }

    function _checkNoSnapshot() private view {
        if (_snapshot.stateRoot != bytes32(0)) revert SnapshotTaken();
    }

    /// @dev One slot of `index`'s storage in Ethereum's state at the snapshot.
    function _readHub(address index, bytes32 slot, bytes calldata proof) private view returns (bytes32) {
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;
        return STATE_READER.readSlots(_snapshotRoot(), index, slots, proof)[0];
    }

    function _snapshotRoot() private view returns (bytes32 root) {
        root = _snapshot.stateRoot;
        if (root == bytes32(0)) revert NoSnapshot();
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _credit(address index, address token, uint256 amount) private {
        balance[index][token] += amount;
        if (!_indexHasToken[index][token]) {
            _indexHasToken[index][token] = true;
            _indexTokens[index].push(token);
        }
    }

    function _refreshIndexDigest(address index) private {
        address[] memory tokens = _indexTokens[index];
        uint256[] memory balances = new uint256[](tokens.length);
        uint256[] memory paid = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            balances[i] = balance[index][tokens[i]];
            paid[i] = paidTotal[index][tokens[i]];
        }
        indexDigest[index] =
            keccak256(abi.encode(INDEX_DIGEST_DOMAIN, block.chainid, address(this), index, tokens, balances, paid));
    }

    function _refreshIntakeDigest(address index, uint256 intakeId) private {
        address[] memory tokens = _intakeTokens[index][intakeId];
        uint256[] memory totals = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            totals[i] = intakeTotal[index][intakeId][tokens[i]];
        }
        intakeDigest[index][intakeId] = keccak256(
            abi.encode(
                INTAKE_DIGEST_DOMAIN,
                block.chainid,
                address(this),
                index,
                intakeId,
                intakeState[index][intakeId],
                tokens,
                totals
            )
        );
    }

    /// @dev Native coin only in Stage B; a listed ERC-20 would come with measured deposits, as MintRequests takes them.
    function _toAddress(bytes32 value) private pure returns (address a) {
        if (uint256(value) >> 160 != 0) revert NotAnAddress(value);
        a = address(uint160(uint256(value)));
    }

    function _send(address to, uint256 amount) private {
        // A recipient that refuses reverts the payout, so a burn to it stays deliverable, or owed, for a later try.
        // The destination is deliberate: a burn's recipient named by a proven message, or a failed intake's depositor.
        // forge-lint: disable-next-line(low-level-calls,arbitrary-send-eth)
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed(to);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IXindexVault
    function owed(address index, bytes32 id) external view returns (Owed memory) {
        return _owed[index][id];
    }

    /// @inheritdoc IXindexVault
    function indexTokens(address index) external view returns (address[] memory) {
        return _indexTokens[index];
    }

    /// @inheritdoc IXindexVault
    function intakeTokens(address index, uint256 intakeId) external view returns (address[] memory) {
        return _intakeTokens[index][intakeId];
    }
}
