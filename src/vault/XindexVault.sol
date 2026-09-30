// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IXindexVault} from "../interfaces/IXindexVault.sol";
import {IEthereumEventVerifier} from "../interfaces/IEthereumEventVerifier.sol";
import {VaultMessages} from "../libraries/VaultMessages.sol";

/// @title XindexVault
/// @notice The vault an EVM chain (BNB Chain, HyperEVM, Tron) runs for every index whose shares live on Ethereum. It
///         holds the chain's native coin in a separate balance per index, takes coins in only as deposits to an intake,
///         and lets them out only on messages that P1 and P2, two independent proofs of Ethereum's finality, show were
///         sent by that index or by the factory. Payouts stay within a speed limit, exact over any 24 hours.
/// @dev No owner, no upgrade. Every coin the vault accounts for is in `held`: settled balances plus the deposits of
///      open and failed intakes not yet refunded. State is written before any coin moves, and every entry point that
///      can move a coin shares one reentrancy guard.
contract XindexVault is IXindexVault, ReentrancyGuard {
    /// @inheritdoc IXindexVault
    uint256 public constant SPEED_LIMIT = 0.04e18;
    /// @inheritdoc IXindexVault
    uint256 public constant FREEZE_DURATION = 14 days;
    /// @inheritdoc IXindexVault
    uint256 public constant MAX_INTAKE_LIFE = 7 days;

    uint256 private constant WAD = 1e18;
    /// @dev The current hour and the 24 before it: every real 24-hour span lies inside them.
    uint256 private constant BUCKETS = 25;
    uint256 private constant HOUR = 1 hours;
    address private constant NATIVE = address(0);
    bytes32 private constant INDEX_DIGEST_DOMAIN = keccak256("xindex.v4.vault.index-digest");
    bytes32 private constant INTAKE_DIGEST_DOMAIN = keccak256("xindex.v4.vault.intake-digest");

    /// @inheritdoc IXindexVault
    uint256 public immutable SOURCE_CHAIN_ID;
    /// @inheritdoc IXindexVault
    address public immutable FACTORY;
    /// @inheritdoc IXindexVault
    address public immutable HUB_IMPLEMENTATION;

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

    /// @param sourceChainId Ethereum's chain id, which every message must name.
    /// @param factory The factory on Ethereum.
    /// @param hubImplementation The hub template on Ethereum that every index is a clone of.
    /// @param verifier1 P1, the first Ethereum-event verifier on this chain.
    /// @param verifier2 P2, the second, independent one.
    /// @param freezer_ The guardian's freeze address on this chain.
    /// @param nativeCap The quantity cap on the native coin across all indexes.
    /// @param nativeFloor The native coin's outflow floor (section 1, proposal 5 of the Stage B spec).
    constructor(
        uint256 sourceChainId,
        address factory,
        address hubImplementation,
        IEthereumEventVerifier verifier1,
        IEthereumEventVerifier verifier2,
        address freezer_,
        uint256 nativeCap,
        uint256 nativeFloor
    ) {
        if (
            factory == address(0) || hubImplementation == address(0) || address(verifier1) == address(0)
                || address(verifier2) == address(0) || freezer_ == address(0)
        ) revert ZeroAddress();
        if (address(verifier1).code.length == 0) revert NotAContract(address(verifier1));
        if (address(verifier2).code.length == 0) revert NotAContract(address(verifier2));
        SOURCE_CHAIN_ID = sourceChainId;
        FACTORY = factory;
        HUB_IMPLEMENTATION = hubImplementation;
        p1 = verifier1;
        p2 = verifier2;
        freezer = freezer_;
        cap[NATIVE] = nativeCap;
        outflowFloor[NATIVE] = nativeFloor;
        emit CapSet(NATIVE, nativeCap, nativeFloor);
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
        (address emitter, bytes memory payload, bool both) = _prove(proof1, proof2);
        bytes32 id = keccak256(payload);
        VaultMessages.Message memory m = VaultMessages.decode(payload);
        // Checked before anything reads the kind: dispatch below treats every kind it does not name as the last one.
        if (m.kind == 0 || m.kind > VaultMessages.VERIFIER_ROTATION) revert UnknownKind(m.kind);
        if (
            m.sourceChainId != SOURCE_CHAIN_ID || m.destChainId != block.chainid
                || m.vault != bytes32(uint256(uint160(address(this))))
        ) revert WrongRoute();
        bool governance = m.kind >= VaultMessages.CAP_UPDATE;
        if (governance ? (emitter != FACTORY || m.index != FACTORY) : emitter != m.index) revert WrongEmitter(emitter);
        // Any Ethereum contract can emit a VaultMessage naming itself; only the factory's clones of the hub are indexes.
        if (!governance && !isIndex[m.index]) revert NotAnIndex(m.index);
        if (!both && _needsBoth(m)) revert BothProofsRequired(m.kind);
        if (used[id]) revert AlreadyDelivered(id);
        used[id] = true;
        emit MessageDelivered(id, m.kind, m.index);

        if (m.kind < VaultMessages.CAP_UPDATE) _indexMessage(m, id);
        else _governanceMessage(m);
    }

    function _indexMessage(VaultMessages.Message memory m, bytes32 id) private {
        if (m.kind == VaultMessages.BURN) {
            _burn(m.index, id, m.body);
        } else if (m.kind == VaultMessages.INTAKE_SETTLED) {
            _settleIntake(m.index, abi.decode(m.body, (uint256)));
        } else if (m.kind == VaultMessages.INTAKE_FAILED) {
            _failIntake(m.index, abi.decode(m.body, (uint256)));
        } else {
            _migrate(m.index, m.body);
        }
    }

    function _governanceMessage(VaultMessages.Message memory m) private {
        if (m.kind == VaultMessages.CAP_UPDATE) {
            (bytes32 token, uint256 newCap, uint256 newFloor) = abi.decode(m.body, (bytes32, uint256, uint256));
            address t = _toAddress(token);
            cap[t] = newCap;
            outflowFloor[t] = newFloor;
            emit CapSet(t, newCap, newFloor);
        } else if (m.kind == VaultMessages.FREEZE) {
            _freeze(FACTORY);
        } else if (m.kind == VaultMessages.FREEZER_CHANGE) {
            address newFreezer = _toAddress(abi.decode(m.body, (bytes32)));
            if (newFreezer == address(0)) revert ZeroAddress();
            freezer = newFreezer;
            emit FreezerChanged(newFreezer);
        } else {
            (bytes32 a, bytes32 b) = abi.decode(m.body, (bytes32, bytes32));
            (address newP1, address newP2) = (_toAddress(a), _toAddress(b));
            if (newP1.code.length == 0) revert NotAContract(newP1);
            if (newP2.code.length == 0) revert NotAContract(newP2);
            p1 = IEthereumEventVerifier(newP1);
            p2 = IEthereumEventVerifier(newP2);
            emit VerifiersRotated(newP1, newP2);
        }
    }

    /// @dev Verifies one or both proofs and returns the log's emitter and the message payload. With both, P1 and P2 must
    ///      prove the same log.
    function _prove(bytes calldata proof1, bytes calldata proof2)
        private
        view
        returns (address emitter, bytes memory payload, bool both)
    {
        both = proof1.length != 0 && proof2.length != 0;
        if (proof1.length != 0) {
            (emitter, payload) = _verify(p1, proof1);
            if (both) {
                (address emitter2, bytes memory payload2) = _verify(p2, proof2);
                if (emitter2 != emitter || keccak256(payload2) != keccak256(payload)) revert ProofsDisagree();
            }
        } else if (proof2.length != 0) {
            (emitter, payload) = _verify(p2, proof2);
        } else {
            revert NoProof();
        }
    }

    function _verify(IEthereumEventVerifier verifier, bytes calldata proof)
        private
        view
        returns (address emitter, bytes memory payload)
    {
        (address e, bytes32 topic0, bytes32 topic1, bytes memory data) = verifier.verifyEvent(proof);
        if (topic0 != VaultMessages.EVENT_TOPIC) revert NotAVaultMessage(topic0);
        payload = abi.decode(data, (bytes));
        if (keccak256(payload) != topic1) revert IdMismatch(topic1);
        emitter = e;
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
        _owed[index][id] = Owed({token: t, recipient: to, remaining: amount});
        emit BurnAccepted(index, id, t, amount, to);
        _release(index, id, false);
    }

    /// @inheritdoc IXindexVault
    function release(address index, bytes32 id) external nonReentrant {
        _release(index, id, true);
    }

    /// @dev Pays what the speed limit, the index's balance and a freeze allow of an owed burn. `strict` is set for an
    ///      explicit release, which reverts when it can pay nothing; a burn just delivered keeps waiting instead.
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
        o.remaining = remaining - pay;
        balance[index][token] -= pay;
        paidTotal[index][token] += pay;
        held[token] -= pay;
        _recordOutflow(index, token, pay);
        emit Paid(index, id, recipient, pay, remaining - pay);
        _refreshIndexDigest(index);
        _send(recipient, pay);
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
        emit IntakeSettled(index, intakeId);
        _refreshIntakeDigest(index, intakeId);
        _refreshIndexDigest(index);
    }

    function _failIntake(address index, uint256 intakeId) private {
        IntakeState state = intakeState[index][intakeId];
        if (state == IntakeState.Settled || state == IntakeState.Failed) revert IntakeNotOpen(index, intakeId);
        intakeState[index][intakeId] = IntakeState.Failed;
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

    function _migrate(address index, bytes memory body) private {
        _checkNotFrozen();
        (address newIndex, bytes32 token, uint256 amount) = abi.decode(body, (address, bytes32, uint256));
        if (!isIndex[newIndex] || newIndex == index) revert NotAnIndex(newIndex);
        address t = _toAddress(token);
        uint256 bal = balance[index][t];
        if (amount == 0) revert ZeroAmount();
        if (amount > bal) revert InsufficientBalance(index, t, bal, amount);
        balance[index][t] = bal - amount;
        _credit(newIndex, t, amount);
        emit Migrated(index, newIndex, t, amount);
        _refreshIndexDigest(index);
        _refreshIndexDigest(newIndex);
    }

    /// @inheritdoc IXindexVault
    function freeze() external {
        if (msg.sender != freezer) revert NotFreezer(msg.sender);
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
