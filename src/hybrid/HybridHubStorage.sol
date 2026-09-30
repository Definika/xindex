// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHybridHubTypes} from "../interfaces/IHybridHubTypes.sol";
import {IHybridIndexFactory} from "../interfaces/IHybridIndexFactory.sol";
import {IVaultStateVerifier} from "../interfaces/IVaultStateVerifier.sol";
import {VaultMessages} from "../libraries/VaultMessages.sol";

/// @title HybridHubStorage
/// @notice The state a HybridHub index keeps, and the helpers its three parts share: the hub, the module it
///         delegates to, and the module's extension. Each inherits this contract first and declares no state of its
///         own, so their layouts are the same by construction; every OpenZeppelin part they use keeps its state in its
///         own namespaced slot.
/// @dev Append new state at the end, never between: the three must agree slot for slot, which
///      `test_theHubAndTheModuleShareOneLayout` checks.
// Read alone, this contract uses little of its state: the hub and the module that inherit it read and write the rest.
// forge-lint: disable-next-item(unused-state-variables)
abstract contract HybridHubStorage is Initializable, IHybridHubTypes {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_SHARE = 1e18;
    uint256 internal constant FREEZE_LENGTH = 14 days;
    uint256 internal constant GRACE = 6 hours;
    /// @dev The mint cap counts the current hour and the 24 before it, so it holds over any real 24 hours.
    uint256 internal constant BUCKETS = 25;
    uint256 internal constant HOUR = 1 hours;
    uint256 internal constant DEADLINE_SHIFT = 192;
    uint256 internal constant ORDER_ID_MASK = (1 << DEADLINE_SHIFT) - 1;
    /// @dev Set in a rebalance fill's delivery intake id, never in an order's, whose ids stay far below it.
    uint256 internal constant FILL_FLAG = 1 << 191;
    /// @dev The vault's storage (`XindexVault`): `intakeDigest` is the mapping at slot 15, and an intake's digest is the
    ///      hash of this domain, the vault chain's id, the vault, the index, the intake id, its state and its deposits.
    ///      `test_theVaultLayoutIsPinned` checks both against a deployed vault.
    uint256 internal constant VAULT_INTAKE_DIGEST_SLOT = 15;
    bytes32 internal constant INTAKE_DIGEST_DOMAIN = keccak256("xindex.v4.vault.intake-digest");
    /// @dev Likewise `indexDigest`, the mapping at slot 14: the hash of this domain, the vault chain's id, the vault,
    ///      the index, and its tokens, balances and paid totals.
    uint256 internal constant VAULT_INDEX_DIGEST_SLOT = 14;
    bytes32 internal constant INDEX_DIGEST_DOMAIN = keccak256("xindex.v4.vault.index-digest");
    uint8 internal constant INTAKE_OPEN = 1;
    uint8 internal constant INTAKE_SETTLED = 2;

    struct Component {
        address token;
        uint96 units;
    }

    struct VaultChain {
        uint256 chainId;
        bytes32 vault;
    }

    struct StoredOrder {
        address minter;
        uint40 deadline;
        uint40 lockEnds;
        OrderStatus status;
        uint40 settledAt;
        uint256 shares;
    }

    /// @dev One hour's newly claimable shares, tagged with the hour so a stale slot reads as empty.
    struct Bucket {
        uint64 hour;
        uint192 amount;
    }

    /// @dev `eta == 0` means no rebalance is proposed. Both ends of the band lie within 1e18 ± MAX_SUPPLY_STEP.
    struct PendingRebalance {
        uint40 eta;
        uint64 lambdaMax;
        uint64 lambdaMin;
    }

    struct StoredFill {
        address executor;
        FillStatus status;
        uint40 deadline;
        uint40 bondRelease;
        uint64 lambda;
        uint256 bond;
        uint256 nonce;
    }

    // ---------------------------------------------------------------------
    // Layer 1: components, orders, the book, claims, freezes, the mint cap
    // ---------------------------------------------------------------------

    Component[] internal _components;
    /// @dev Per component: 0 for an Ethereum token, else 1 + its chain's position in `_chains`.
    uint256[] internal _slotOf;
    /// @dev Per component: the token's id on its vault chain, zero for an Ethereum token.
    bytes32[] internal _vaultTokenOf;
    /// @dev Per token: 1 + its position among the components.
    mapping(address token => uint256) internal _position;
    VaultChain[] internal _chains;

    mapping(uint256 orderId => StoredOrder) internal _orders;
    /// @dev Per order and component: the escrow of an Ethereum token, what a vault token needs deposited.
    mapping(uint256 orderId => uint256[]) internal _amounts;
    /// @dev Per order and component: the proven deposit of a vault token.
    mapping(uint256 orderId => uint256[]) internal _deposits;
    /// @dev Per order and chain: the intake digest the order was settled on.
    mapping(uint256 orderId => bytes32[]) internal _digests;

    /// @dev The hub's book of what each vault holds for it: claimed deposits and deliveries, less every burn.
    mapping(address token => uint256) internal _vaultBacking;
    /// @dev Ethereum tokens held for orders and fills not yet claimed or settled.
    mapping(address token => uint256) internal _escrowed;
    mapping(address account => mapping(address token => uint256)) internal _claimOf;
    mapping(address token => uint256) internal _totalClaims;
    mapping(uint256 chainId => mapping(uint256 intakeId => bool)) internal _intakeFailed;
    Bucket[BUCKETS] internal _minted;
    uint256 internal _lockedShares;
    uint256 internal _orderCount;
    uint256 internal _messageNonce;

    // ---------------------------------------------------------------------
    // Layer 2: the rebalance
    // ---------------------------------------------------------------------

    PendingRebalance internal _pending;
    uint256 internal _keepMask;
    /// @dev The pending band's ratio per component, zero for a kept one; empty when nothing is proposed.
    uint64[] internal _ratios;
    uint256 internal _proposalCount;
    uint256 internal _rebalanceNonce;
    uint256 internal _lastRebalance;
    uint256 internal _restartAllowedAt;
    StoredFill internal _fill;
    /// @dev Per component, for the live fill: the new units, what the executor delivers (Ethereum legs _escrowed at
    ///      acceptance), and, once settled, the proven vault deliveries a slash is measured against.
    uint256[] internal _fillUnits;
    uint256[] internal _fillIn;
    uint256[] internal _fillDelivered;
    /// @dev Per chain: where the sold vault legs of the live fill are burned to.
    bytes32[] internal _fillRecipients;
    /// @dev Every delivery intake id a fill ever took, so none can be failed as a stray.
    mapping(uint256 intakeId => bool) internal _fillIntakes;

    // ---------------------------------------------------------------------
    // Layer 3: migration and evidence
    // ---------------------------------------------------------------------

    /// @dev Per vault token: everything this index ever sent out of its vault balance, in BURN and MIGRATE messages.
    ///      A vault can never have paid out more (section 5.5 of the Stage B spec).
    mapping(address token => uint256) internal _sentOut;

    modifier onlyInitialized() {
        _checkInitialized();
        _;
    }

    /// @dev The factory: each of the two contracts keeps it as an immutable of its own.
    function _factory() internal view virtual returns (address);

    function _checkInitialized() internal view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    // ---------------------------------------------------------------------
    // Amounts and ids
    // ---------------------------------------------------------------------

    /// @dev `shares`' amount of `units`, rounded as asked: up for what comes in, down for what goes out.
    function _backing(uint256 shares, uint256 units, Math.Rounding rounding) internal pure returns (uint256) {
        return Math.mulDiv(shares, units, ONE_SHARE, rounding);
    }

    function _amountsFor(uint256 shares, Math.Rounding rounding) internal view returns (uint256[] memory amounts) {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = _backing(shares, _components[i].units, rounding);
        }
    }

    function _intakeIdOf(uint256 orderId, uint256 deadline) internal pure returns (uint256) {
        return (deadline << DEADLINE_SHIFT) | orderId;
    }

    function _openOrder(uint256 orderId, OrderStatus expected) internal view returns (StoredOrder storage o) {
        o = _orders[orderId];
        if (o.status != expected) revert WrongStatus(orderId, o.status);
    }

    function _slotIndex(uint256 chainId) internal view returns (uint256) {
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            if (_chains[j].chainId == chainId) return j;
        }
        revert NotAVaultChain(chainId);
    }

    /// @dev An EVM vault chain's address in its 32-byte form; Stage B's vaults all run on EVM chains.
    function _vaultAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    // ---------------------------------------------------------------------
    // Freezes and proofs
    // ---------------------------------------------------------------------

    /// @dev The factory's freeze of `chainId`, by the owner, the guardian, or an index's evidence.
    function _freeze(uint256 chainId) internal view returns (IHybridIndexFactory.Freeze memory) {
        return IHybridIndexFactory(_factory()).chainFreeze(chainId);
    }

    function _checkNotFrozen(uint256 chainId) internal view {
        uint256 until = _freeze(chainId).until;
        if (block.timestamp < until) revert ChainIsFrozen(chainId, until);
    }

    /// @dev The `j`-th chain's intake digest for `intakeId`, proven by the chain's state verifier, which the factory
    ///      names and can rotate, at a block whose timestamp is after `notBefore`.
    function _provenIntake(uint256 j, uint256 intakeId, uint256 notBefore, bytes calldata proof)
        internal
        view
        returns (bytes32)
    {
        bytes32 slot = keccak256(abi.encode(intakeId, keccak256(abi.encode(address(this), VAULT_INTAKE_DIGEST_SLOT))));
        return _provenSlot(j, slot, notBefore, proof);
    }

    /// @dev One storage slot of the `j`-th chain's vault, proven as `_provenIntake` proves an intake's.
    function _provenSlot(uint256 j, bytes32 slot, uint256 notBefore, bytes calldata proof)
        internal
        view
        returns (bytes32)
    {
        VaultChain memory c = _chains[j];
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = slot;
        address verifier = IHybridIndexFactory(_factory()).stateVerifier(c.chainId);
        uint256 time;
        bytes32[] memory values;
        // The block number is not needed: the timestamp bounds the proof, and the value is the whole claim.
        // forge-lint: disable-next-line(unused-return)
        (, time, values) = IVaultStateVerifier(verifier).verifySlots(_vaultAddress(c.vault), slots, proof);
        if (time <= notBefore) revert ProofTooEarly(c.chainId, time, notBefore);
        return values[0];
    }

    /// @dev The digest the `j`-th chain's vault keeps for an intake in `state` with these deposits.
    function _intakeDigest(
        uint256 j,
        uint256 intakeId,
        uint8 state,
        address[] calldata tokens,
        uint256[] calldata totals
    ) internal view returns (bytes32) {
        if (tokens.length != totals.length) revert LengthMismatch();
        VaultChain memory c = _chains[j];
        return keccak256(
            abi.encode(
                INTAKE_DIGEST_DOMAIN, c.chainId, _vaultAddress(c.vault), address(this), intakeId, state, tokens, totals
            )
        );
    }

    /// @dev The `i`-th component's total in an intake's preimage; zero if it has none.
    function _totalOf(uint256 i, address[] calldata tokens, uint256[] calldata totals)
        internal
        view
        returns (uint256 total)
    {
        address token = _vaultAddress(_vaultTokenOf[i]);
        total = 0;
        for (uint256 t = 0; t < tokens.length; ++t) {
            if (tokens[t] == token) total = totals[t];
        }
    }

    // ---------------------------------------------------------------------
    // Messages, claims, failures
    // ---------------------------------------------------------------------

    /// @dev Emits a message to the `j`-th chain's vault: an event on Ethereum, which P1 and P2 prove final there.
    function _send(uint256 j, uint8 kind, bytes memory body) internal {
        bytes memory payload = _payload(j, kind, body);
        // `_payload` only encodes; the lint reads its internal library call as an external one.
        // forge-lint: disable-next-line(reentrancy-events)
        emit VaultMessages.VaultMessage(keccak256(payload), payload);
    }

    /// @dev Sends every vault of this index the same message.
    function _sendAll(uint8 kind, bytes memory body) internal {
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            _send(j, kind, body);
        }
    }

    /// @dev A message to the `j`-th chain's vault, under the next nonce, so no two messages share an id.
    function _payload(uint256 j, uint8 kind, bytes memory body) internal returns (bytes memory) {
        VaultChain memory c = _chains[j];
        return VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: block.chainid,
                kind: kind,
                destChainId: c.chainId,
                vault: c.vault,
                index: address(this),
                nonce: ++_messageNonce,
                body: body
            })
        );
    }

    /// @dev Burns `amount` of vault component `i` toward `recipient` on its chain: the book falls now, and the vault pays
    ///      once P1 and P2 prove the message, within its speed limit. Nothing expires.
    function _sendBurn(uint256 i, uint256 amount, bytes32 recipient) internal {
        address token = _components[i].token;
        uint256 j = _slotOf[i] - 1;
        _vaultBacking[token] -= amount;
        _sentOut[token] += amount;
        bytes memory payload = _payload(j, VaultMessages.BURN, abi.encode(_vaultTokenOf[i], amount, recipient));
        bytes32 id = keccak256(payload);
        // `_payload` only encodes; the lint reads its internal library call as an external one.
        // forge-lint: disable-next-line(reentrancy-events)
        emit VaultMessages.VaultMessage(id, payload);
        // forge-lint: disable-next-line(reentrancy-events)
        emit BurnSent(token, _chains[j].chainId, recipient, amount, id);
    }

    function _bookClaim(address account, address token, uint256 amount) internal {
        _claimOf[account][token] += amount;
        _totalClaims[token] += amount;
        // A claim is booked after views only, or after internal library calls the lint reads as external ones.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ClaimRecorded(account, token, amount);
    }

    /// @dev Fails an open or locked order: its escrow is booked as its minter's claims, never sent here, so a paused
    ///      Ethereum token cannot keep a vault's depositors from their refund.
    function _fail(uint256 orderId, StoredOrder storage o) internal {
        o.status = OrderStatus.Failed;
        address minter = o.minter;
        uint256[] memory amounts = _amounts[orderId];
        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != 0 || amounts[i] == 0) continue;
            address token = _components[i].token;
            _escrowed[token] -= amounts[i];
            _bookClaim(minter, token, amounts[i]);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderFailed(orderId, msg.sender);
        _sendAll(VaultMessages.INTAKE_FAILED, abi.encode(_intakeIdOf(orderId, o.deadline)));
    }

    /// @dev Freezes `chainId`'s mints at the factory, for every index, and with `payouts` its vault too: evidence this
    ///      index has just checked showed the chain's records or proofs false. The factory is the last call of every
    ///      path that makes it.
    function _freezeOnEvidence(uint256 chainId, bool payouts) internal {
        IHybridIndexFactory(_factory()).freezeOnEvidence(chainId, payouts);
    }

    /// @dev The invariants at `supply`, for every component: Ethereum balances cover the backing, claims and escrow,
    ///      and the book of each vault covers its backing and claims.
    function _checkBacking(uint256 supply) internal view {
        uint256 n = _components.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = _components[i].token;
            uint256 required = _backing(supply, _components[i].units, Math.Rounding.Floor) + _totalClaims[token];
            uint256 held;
            if (_slotOf[i] == 0) {
                required += _escrowed[token];
                held = IERC20(token).balanceOf(address(this));
            } else {
                held = _vaultBacking[token];
            }
            if (held < required) revert RebalanceUnderfunded(token, held, required);
        }
    }
}
