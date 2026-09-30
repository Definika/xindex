// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHybridHub} from "./interfaces/IHybridHub.sol";
import {IHybridIndexFactory} from "./interfaces/IHybridIndexFactory.sol";
import {IVaultStateVerifier} from "./interfaces/IVaultStateVerifier.sol";
import {VaultMessages} from "./libraries/VaultMessages.sol";

/// @title HybridHub
/// @notice An index holding tokens on Ethereum and coins in vaults on other chains. See {IHybridHub}.
/// @dev Deployed as an EIP-1167 clone by {HybridIndexFactory}, from a template built for that factory. Stage A's
///      `IndexHub` stays as it is for indexes held entirely on Ethereum (Stage B spec, proposal 1).
///
///      The hub's book of each vault component, `vaultBacking`, is exact by construction: it grows by the proven
///      deposits of every claimed order and falls by every amount burned, both derived from supply and units. What the
///      vault really holds is the vault's own business and the watchers': a proof contradicting an order in its lock
///      voids the order at once, and freezes the chain's mints.
///
///      Orders span the whole basket, so every order touches every vault chain. An intake id carries its deadline in
///      its top 64 bits and the order id below, as the vault expects: `(deadline << 192) | orderId`.
///
///      Every function that mints, burns, pays a claim or moves an order shares one reentrancy guard. The only calls out
///      are to Ethereum components (escrow and payouts) and views: the factory's registry and the chains' state
///      verifiers.
contract HybridHub is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ReentrancyGuard, IHybridHub {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;
    /// @inheritdoc IHybridHub
    uint256 public constant MINT_LOCK = 24 hours;
    /// @inheritdoc IHybridHub
    uint256 public constant MAX_ORDER_LIFE = 6 hours;
    /// @inheritdoc IHybridHub
    uint256 public constant SETTLE_GRACE = 6 hours;
    /// @inheritdoc IHybridHub
    uint256 public constant MINT_CAP = 0.04e18;
    /// @inheritdoc IHybridHub
    uint256 public constant FREEZE_DURATION = 14 days;
    /// @inheritdoc IHybridHub
    address public immutable FACTORY;

    uint256 private constant WAD = 1e18;
    /// @dev The mint cap counts the current hour and the 24 before it, so it holds over any real 24 hours.
    uint256 private constant BUCKETS = 25;
    uint256 private constant HOUR = 1 hours;
    uint256 private constant DEADLINE_SHIFT = 192;
    uint256 private constant ORDER_ID_MASK = (1 << DEADLINE_SHIFT) - 1;
    /// @dev The vault's storage (`XindexVault`): `intakeDigest` is the mapping at slot 15, and an intake's digest is the
    ///      hash of this domain, the vault chain's id, the vault, the index, the intake id, its state and its deposits.
    ///      `test_theVaultLayoutIsPinned` checks both against a deployed vault.
    uint256 private constant VAULT_INTAKE_DIGEST_SLOT = 15;
    bytes32 private constant INTAKE_DIGEST_DOMAIN = keccak256("xindex.v4.vault.intake-digest");
    uint8 private constant INTAKE_OPEN = 1;

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

    Component[] private _components;
    /// @dev Per component: 0 for an Ethereum token, else 1 + its chain's position in `_chains`.
    uint256[] private _slotOf;
    /// @dev Per component: the token's id on its vault chain, zero for an Ethereum token.
    bytes32[] private _vaultTokenOf;
    /// @dev Per token: 1 + its position among the components.
    mapping(address token => uint256) private _position;
    VaultChain[] private _chains;

    mapping(uint256 orderId => StoredOrder) private _orders;
    /// @dev Per order and component: the escrow of an Ethereum token, what a vault token needs deposited.
    mapping(uint256 orderId => uint256[]) private _amounts;
    /// @dev Per order and component: the proven deposit of a vault token.
    mapping(uint256 orderId => uint256[]) private _deposits;
    /// @dev Per order and chain: the intake digest the order was settled on.
    mapping(uint256 orderId => bytes32[]) private _digests;

    /// @inheritdoc IHybridHub
    mapping(address token => uint256) public vaultBacking;
    /// @inheritdoc IHybridHub
    mapping(address token => uint256) public escrowed;
    /// @inheritdoc IHybridHub
    mapping(address account => mapping(address token => uint256)) public claimOf;
    /// @inheritdoc IHybridHub
    mapping(address token => uint256) public totalClaims;
    mapping(uint256 chainId => IHybridIndexFactory.Freeze) private _freezes;
    mapping(uint256 chainId => mapping(uint256 intakeId => bool)) private _intakeFailed;
    Bucket[BUCKETS] private _minted;
    uint256 private _lockedShares;

    /// @inheritdoc IHybridHub
    uint256 public orderCount;
    /// @inheritdoc IHybridHub
    uint256 public messageNonce;

    modifier onlyInitialized() {
        _checkInitialized();
        _;
    }

    /// @param factory The factory whose clones this template serves; it checks this when it is deployed.
    constructor(address factory) {
        if (factory == address(0)) revert ZeroAddress();
        FACTORY = factory;
        _disableInitializers();
    }

    /// @inheritdoc IHybridHub
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units,
        Placement[] calldata placements
    ) external initializer {
        if (msg.sender != FACTORY) revert NotFactory();
        _addComponents(tokens, units, placements);
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
    }

    function _addComponents(address[] calldata tokens, uint256[] calldata units, Placement[] calldata placements)
        private
    {
        uint256 n = tokens.length;
        if (n == 0 || units.length != n || placements.length != n) revert InvalidComponents();
        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == address(0) || units[i] == 0) revert InvalidComponents();
            _components.push(Component({token: tokens[i], units: SafeCast.toUint96(units[i])}));
            _position[tokens[i]] = i + 1;
            Placement calldata p = placements[i];
            _vaultTokenOf.push(p.vaultToken);
            _slotOf.push(p.chainId == 0 ? 0 : _chainSlot(p.chainId, p.vault) + 1);
        }
        // The factory uses this template only for a basket holding a vault token.
        if (_chains.length == 0) revert InvalidComponents();
    }

    /// @dev The position of `chainId` in `_chains`, added on first sight.
    function _chainSlot(uint256 chainId, bytes32 vault) private returns (uint256) {
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            if (_chains[j].chainId == chainId) return j;
        }
        if (vault == bytes32(0)) revert InvalidComponents();
        _chains.push(VaultChain({chainId: chainId, vault: vault}));
        return m;
    }

    // ---------------------------------------------------------------------
    // Orders
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHub
    function openOrder(uint256 shares, uint256 deadline)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 orderId, uint256 intakeId)
    {
        if (shares == 0) revert ZeroShares();
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_ORDER_LIFE) revert BadDeadline(deadline);
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            _checkNotFrozen(_chains[j].chainId);
        }

        orderId = ++orderCount;
        intakeId = (deadline << DEADLINE_SHIFT) | orderId;
        uint256[] memory amounts = _amountsFor(shares, Math.Rounding.Ceil);
        _orders[orderId] = StoredOrder({
            minter: msg.sender,
            deadline: SafeCast.toUint40(deadline),
            lockEnds: 0,
            status: OrderStatus.Open,
            settledAt: 0,
            shares: shares
        });
        _amounts[orderId] = amounts;
        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] == 0) escrowed[_components[i].token] += amounts[i];
        }
        // The calls before this are views on the factory's freeze record.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderOpened(orderId, msg.sender, shares, intakeId, amounts);

        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != 0) continue;
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            // Rejects fee-on-transfer tokens even if a listed token changes behaviour.
            if (token.balanceOf(address(this)) - before < amounts[i]) revert TransferAmountMismatch(address(token));
        }
    }

    /// @inheritdoc IHybridHub
    function settleOrder(uint256 orderId, ChainProof[] calldata proofs) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Open);
        uint256 m = _chains.length;
        if (proofs.length != m) revert LengthMismatch();
        uint256 intakeId = _intakeIdOf(orderId, o.deadline);
        uint256[] memory required = _amounts[orderId];
        uint256[] memory deposits = new uint256[](required.length);
        bytes32[] memory digests = new bytes32[](m);
        for (uint256 j = 0; j < m; ++j) {
            _checkNotFrozen(_chains[j].chainId);
            digests[j] = _settleChain(j, intakeId, o.deadline, proofs[j], required, deposits);
        }
        _useMintRoom(o.shares);

        uint256 lockEnds = block.timestamp + MINT_LOCK;
        o.status = OrderStatus.Locked;
        o.lockEnds = SafeCast.toUint40(lockEnds);
        o.settledAt = SafeCast.toUint40(block.timestamp);
        _lockedShares += o.shares;
        _deposits[orderId] = deposits;
        _digests[orderId] = digests;
        // The calls before this are views: the factory's registry and the state verifiers.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderSettled(orderId, lockEnds, deposits);
    }

    /// @dev Proves one chain's intake from its digest's preimage, and records the deposit of each component there,
    ///      which must cover what the order needs. Tokens in the intake that are not components are left alone.
    function _settleChain(
        uint256 j,
        uint256 intakeId,
        uint256 deadline,
        ChainProof calldata p,
        uint256[] memory required,
        uint256[] memory deposits
    ) private view returns (bytes32 digest) {
        if (p.tokens.length != p.totals.length) revert LengthMismatch();
        VaultChain memory c = _chains[j];
        digest = keccak256(
            abi.encode(
                INTAKE_DIGEST_DOMAIN,
                c.chainId,
                _vaultAddress(c.vault),
                address(this),
                intakeId,
                INTAKE_OPEN,
                p.tokens,
                p.totals
            )
        );
        bytes32 proven = _provenIntake(j, intakeId, deadline, p.proof);
        if (proven != digest) revert DigestMismatch(c.chainId, proven, digest);
        uint256 n = required.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != j + 1) continue;
            address token = _vaultAddress(_vaultTokenOf[i]);
            uint256 total = 0;
            for (uint256 t = 0; t < p.tokens.length; ++t) {
                if (p.tokens[t] == token) total = p.totals[t];
            }
            if (total < required[i]) revert DepositShort(_components[i].token, total, required[i]);
            deposits[i] = total;
        }
    }

    /// @inheritdoc IHybridHub
    function reconfirmOrder(uint256 orderId, bytes[] calldata proofs) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Locked);
        uint256 m = _chains.length;
        if (proofs.length != m) revert LengthMismatch();
        uint256 intakeId = _intakeIdOf(orderId, o.deadline);
        for (uint256 j = 0; j < m; ++j) {
            uint256 chainId = _chains[j].chainId;
            IHybridIndexFactory.Freeze memory f = _freeze(chainId);
            if (f.start < o.settledAt) continue;
            if (block.timestamp < f.until) revert ChainIsFrozen(chainId, f.until);
            // A proof from after the freeze ended: whatever the vault did while frozen is behind it.
            bytes32 proven = _provenIntake(j, intakeId, f.until, proofs[j]);
            bytes32 recorded = _digests[orderId][j];
            if (proven != recorded) revert DigestMismatch(chainId, proven, recorded);
        }
        o.settledAt = SafeCast.toUint40(block.timestamp);
        // The calls before this are views: the factory's registry and the state verifiers.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderReconfirmed(orderId);
    }

    /// @inheritdoc IHybridHub
    function claimOrder(uint256 orderId) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Locked);
        if (block.timestamp < o.lockEnds) revert NotYet(o.lockEnds);
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            uint256 chainId = _chains[j].chainId;
            IHybridIndexFactory.Freeze memory f = _freeze(chainId);
            if (block.timestamp < f.until) revert ChainIsFrozen(chainId, f.until);
            // A freeze that began after the order settled holds it until a fresh proof re-confirms it, so an expiring
            // freeze never releases shares by itself (design 6.3). One that began in the same second came after the
            // settlement in its block, since nothing settles while frozen.
            if (f.start >= o.settledAt) revert NeedsReconfirmation(orderId, chainId);
        }

        o.status = OrderStatus.Claimed;
        uint256 shares = o.shares;
        _lockedShares -= shares;
        uint256[] memory amounts = _amounts[orderId];
        uint256[] memory deposits = _deposits[orderId];
        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = _components[i].token;
            if (_slotOf[i] == 0) escrowed[token] -= amounts[i];
            // The whole deposit joins the index, surplus included, so any surplus stays with the holders.
            else vaultBacking[token] += deposits[i];
        }
        address minter = o.minter;
        _mint(minter, shares);
        // The calls before this are views on the factory's freeze record; `_mint` is internal.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderClaimed(orderId, minter, shares);
        uint256 intakeId = _intakeIdOf(orderId, o.deadline);
        for (uint256 j = 0; j < m; ++j) {
            _send(j, VaultMessages.INTAKE_SETTLED, abi.encode(intakeId));
        }
    }

    /// @inheritdoc IHybridHub
    function failOrder(uint256 orderId) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Open);
        uint256 openTo = o.deadline + SETTLE_GRACE;
        if (msg.sender != o.minter && block.timestamp <= openTo) revert NotYet(openTo);
        _fail(orderId, o);
    }

    /// @inheritdoc IHybridHub
    function voidOrder(uint256 orderId, uint256 chainId, bytes calldata proof) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Locked);
        uint256 j = _slotIndex(chainId);
        bytes32 proven = _provenIntake(j, _intakeIdOf(orderId, o.deadline), o.deadline, proof);
        bytes32 recorded = _digests[orderId][j];
        // After the deadline an intake's deposits are final, and it stays open until the hub settles or fails it, so a
        // proof showing anything else means the deposit or the proof that settled the order was false.
        if (proven == recorded) revert NotAContradiction(chainId);

        _lockedShares -= o.shares;
        uint256 until = block.timestamp + FREEZE_DURATION;
        _freezes[chainId] =
            IHybridIndexFactory.Freeze({start: SafeCast.toUint64(block.timestamp), until: SafeCast.toUint64(until)});
        // The calls before this are views: the factory's registry and a state verifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderVoided(orderId, chainId, proven, recorded);
        // forge-lint: disable-next-line(reentrancy-events)
        emit ChainFrozen(chainId, until);
        _fail(orderId, o);
    }

    /// @dev Fails an open or locked order: its escrow is booked as its minter's claims, never sent here, so a paused
    ///      Ethereum token cannot keep a vault's depositors from their refund.
    function _fail(uint256 orderId, StoredOrder storage o) private {
        o.status = OrderStatus.Failed;
        address minter = o.minter;
        uint256[] memory amounts = _amounts[orderId];
        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != 0 || amounts[i] == 0) continue;
            address token = _components[i].token;
            escrowed[token] -= amounts[i];
            claimOf[minter][token] += amounts[i];
            totalClaims[token] += amounts[i];
            // A void reaches here after views only: the factory's registry and a state verifier.
            // forge-lint: disable-next-line(reentrancy-events)
            emit ClaimRecorded(minter, token, amounts[i]);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderFailed(orderId, msg.sender);
        uint256 intakeId = _intakeIdOf(orderId, o.deadline);
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            _send(j, VaultMessages.INTAKE_FAILED, abi.encode(intakeId));
        }
    }

    /// @inheritdoc IHybridHub
    function failIntake(uint256 chainId, uint256 intakeId) external nonReentrant onlyInitialized {
        uint256 j = _slotIndex(chainId);
        uint256 deadline = intakeId >> DEADLINE_SHIFT;
        // No order can ever take an intake whose deadline has passed, since an order's deadline lies in the future.
        if (deadline >= block.timestamp) revert IntakeStillOpen(deadline);
        uint256 orderId = intakeId & ORDER_ID_MASK;
        if (orderId != 0 && orderId <= orderCount && _orders[orderId].deadline == deadline) {
            revert IntakeOfAnOrder(intakeId);
        }
        if (_intakeFailed[chainId][intakeId]) revert IntakeAlreadyFailed(intakeId);
        _intakeFailed[chainId][intakeId] = true;
        // No external call precedes this; the lint reads internal library calls, such as the guard's, as external.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IntakeFailed(chainId, intakeId);
        _send(j, VaultMessages.INTAKE_FAILED, abi.encode(intakeId));
    }

    // ---------------------------------------------------------------------
    // Redeem and claims
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHub
    function redeem(uint256 shares, address to, bytes32[] calldata recipients, uint256 skipMask)
        external
        nonReentrant
        onlyInitialized
    {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);
        uint256 n = _components.length;
        if (recipients.length != _chains.length) revert LengthMismatch();
        if (skipMask >> n != 0) revert InvalidSkipMask(skipMask);

        uint256[] memory amounts = _amountsFor(shares, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        // `_burn` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, shares, amounts);

        for (uint256 i = 0; i < n; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            uint256 slot = _slotOf[i];
            address token = _components[i].token;
            bool skipped = skipMask & (1 << i) != 0;
            if (skipped || (slot != 0 && recipients[slot - 1] == bytes32(0))) {
                // Booked to `to`, which receives every other component of this redemption (DA-17).
                claimOf[to][token] += amount;
                totalClaims[token] += amount;
                // forge-lint: disable-next-line(reentrancy-events)
                emit ClaimRecorded(to, token, amount);
            } else if (slot != 0) {
                _burnToVault(i, amount, recipients[slot - 1]);
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] == 0 || _slotOf[i] != 0 || skipMask & (1 << i) != 0) continue;
            IERC20(_components[i].token).safeTransfer(to, amounts[i]);
        }
    }

    /// @inheritdoc IHybridHub
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        uint256 position = _position[token];
        if (position != 0 && _slotOf[position - 1] != 0) revert NotAnEthereumToken(token);
        amount = _takeClaim(token);
        emit Claimed(msg.sender, to, token, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @inheritdoc IHybridHub
    function claimToVault(address token, bytes32 recipient) external nonReentrant returns (uint256 amount) {
        uint256 position = _position[token];
        if (position == 0 || _slotOf[position - 1] == 0) revert NotAVaultToken(token);
        if (recipient == bytes32(0)) revert ZeroAddress();
        amount = _takeClaim(token);
        // `to` is zero for a vault claim: it is burned toward `recipient`, as BurnSent records.
        emit Claimed(msg.sender, address(0), token, amount);
        _burnToVault(position - 1, amount, recipient);
    }

    function _takeClaim(address token) private returns (uint256 amount) {
        amount = claimOf[msg.sender][token];
        if (amount == 0) revert NothingToClaim(token);
        delete claimOf[msg.sender][token];
        totalClaims[token] -= amount;
    }

    /// @dev Burns `amount` of vault component `i` toward `recipient` on its chain: the hub's book falls now, and the
    ///      vault pays once P1 and P2 prove the message, within its speed limit. Nothing expires.
    function _burnToVault(uint256 i, uint256 amount, bytes32 recipient) private {
        address token = _components[i].token;
        uint256 j = _slotOf[i] - 1;
        vaultBacking[token] -= amount;
        bytes memory payload = _payload(j, VaultMessages.BURN, abi.encode(_vaultTokenOf[i], amount, recipient));
        bytes32 id = keccak256(payload);
        // `_payload` only encodes; the lint reads its internal library call as an external one.
        // forge-lint: disable-next-line(reentrancy-events)
        emit VaultMessages.VaultMessage(id, payload);
        // forge-lint: disable-next-line(reentrancy-events)
        emit BurnSent(token, _chains[j].chainId, recipient, amount, id);
    }

    // ---------------------------------------------------------------------
    // Messages, proofs, freezes, the mint cap
    // ---------------------------------------------------------------------

    /// @dev Emits a message to the `j`-th chain's vault: an event on Ethereum, which P1 and P2 prove final there.
    function _send(uint256 j, uint8 kind, bytes memory body) private {
        bytes memory payload = _payload(j, kind, body);
        // `_payload` only encodes; the lint reads its internal library call as an external one.
        // forge-lint: disable-next-line(reentrancy-events)
        emit VaultMessages.VaultMessage(keccak256(payload), payload);
    }

    /// @dev A message to the `j`-th chain's vault, under the next nonce, so no two messages share an id.
    function _payload(uint256 j, uint8 kind, bytes memory body) private returns (bytes memory) {
        VaultChain memory c = _chains[j];
        return VaultMessages.encode(
            VaultMessages.Message({
                sourceChainId: block.chainid,
                kind: kind,
                destChainId: c.chainId,
                vault: c.vault,
                index: address(this),
                nonce: ++messageNonce,
                body: body
            })
        );
    }

    /// @dev The `j`-th chain's intake digest for `intakeId`, proven by the chain's state verifier, which the factory
    ///      names and can rotate, at a block whose timestamp is after `notBefore`.
    function _provenIntake(uint256 j, uint256 intakeId, uint256 notBefore, bytes calldata proof)
        private
        view
        returns (bytes32)
    {
        VaultChain memory c = _chains[j];
        bytes32[] memory slots = new bytes32[](1);
        slots[0] = keccak256(abi.encode(intakeId, keccak256(abi.encode(address(this), VAULT_INTAKE_DIGEST_SLOT))));
        address verifier = IHybridIndexFactory(FACTORY).stateVerifier(c.chainId);
        uint256 time;
        bytes32[] memory values;
        // The block number is not needed: the timestamp bounds the proof, and the value is the whole claim.
        // forge-lint: disable-next-line(unused-return)
        (, time, values) = IVaultStateVerifier(verifier).verifySlots(_vaultAddress(c.vault), slots, proof);
        if (time <= notBefore) revert ProofTooEarly(c.chainId, time, notBefore);
        return values[0];
    }

    /// @dev The later of the factory's freeze of `chainId` and this index's own.
    function _freeze(uint256 chainId) private view returns (IHybridIndexFactory.Freeze memory f) {
        f = IHybridIndexFactory(FACTORY).chainFreeze(chainId);
        IHybridIndexFactory.Freeze memory own = _freezes[chainId];
        if (own.start > f.start) f.start = own.start;
        if (own.until > f.until) f.until = own.until;
    }

    function _checkNotFrozen(uint256 chainId) private view {
        uint256 until = _freeze(chainId).until;
        if (block.timestamp < until) revert ChainIsFrozen(chainId, until);
    }

    /// @dev Records `shares` as claimable in the current hour, within MINT_CAP of the supply over the last 25 hourly
    ///      buckets. The first order of an empty index, with nothing locked either, is the seed and has no cap.
    function _useMintRoom(uint256 shares) private {
        uint256 room = mintRoom();
        if (shares > room) revert MintCapExceeded(shares, room);
        uint256 hour = block.timestamp / HOUR;
        Bucket storage b = _minted[hour % BUCKETS];
        uint256 total = b.hour == hour ? b.amount + shares : shares;
        b.hour = SafeCast.toUint64(hour);
        b.amount = SafeCast.toUint192(total);
    }

    function _openOrder(uint256 orderId, OrderStatus expected) private view returns (StoredOrder storage o) {
        o = _orders[orderId];
        if (o.status != expected) revert WrongStatus(orderId, o.status);
    }

    function _intakeIdOf(uint256 orderId, uint256 deadline) private pure returns (uint256) {
        return (deadline << DEADLINE_SHIFT) | orderId;
    }

    function _slotIndex(uint256 chainId) private view returns (uint256) {
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            if (_chains[j].chainId == chainId) return j;
        }
        revert NotAVaultChain(chainId);
    }

    /// @dev An EVM vault chain's address in its 32-byte form; Stage B's vaults all run on EVM chains.
    function _vaultAddress(bytes32 value) private pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function _checkInitialized() private view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (_isTrap(to)) revert InvalidRecipient(to);
    }

    /// @dev Shares or tokens sent to the index or its factory could never move on (CR-I01, RT-21).
    function _update(address from, address to, uint256 value) internal override {
        if (_isTrap(to)) revert InvalidRecipient(to);
        super._update(from, to, value);
    }

    function _isTrap(address to) private view returns (bool) {
        return to == address(this) || to == FACTORY;
    }

    /// @dev Every component's amount for `shares`, rounded as asked: up for what comes in, down for what goes out.
    function _amountsFor(uint256 shares, Math.Rounding rounding) private view returns (uint256[] memory amounts) {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = Math.mulDiv(shares, _components[i].units, SHARE_UNIT, rounding);
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHub
    function components()
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory units,
            uint256[] memory chainIds,
            bytes32[] memory vaultTokens
        )
    {
        uint256 n = _components.length;
        tokens = new address[](n);
        units = new uint256[](n);
        chainIds = new uint256[](n);
        vaultTokens = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
            units[i] = _components[i].units;
            uint256 slot = _slotOf[i];
            if (slot != 0) chainIds[i] = _chains[slot - 1].chainId;
            vaultTokens[i] = _vaultTokenOf[i];
        }
    }

    /// @inheritdoc IHybridHub
    function chains() external view returns (uint256[] memory chainIds, bytes32[] memory vaults) {
        uint256 m = _chains.length;
        chainIds = new uint256[](m);
        vaults = new bytes32[](m);
        for (uint256 j = 0; j < m; ++j) {
            chainIds[j] = _chains[j].chainId;
            vaults[j] = _chains[j].vault;
        }
    }

    /// @inheritdoc IHybridHub
    function order(uint256 orderId) external view returns (Order memory) {
        StoredOrder memory o = _orders[orderId];
        return Order({
            minter: o.minter,
            shares: o.shares,
            deadline: o.deadline,
            lockEnds: o.lockEnds,
            settledAt: o.settledAt,
            status: o.status
        });
    }

    /// @inheritdoc IHybridHub
    function orderAmounts(uint256 orderId) external view returns (uint256[] memory amounts, uint256[] memory deposits) {
        return (_amounts[orderId], _deposits[orderId]);
    }

    /// @inheritdoc IHybridHub
    function intakeIdOf(uint256 orderId) external view returns (uint256) {
        return _intakeIdOf(orderId, _orders[orderId].deadline);
    }

    /// @inheritdoc IHybridHub
    function previewOrder(uint256 shares) external view returns (uint256[] memory amounts) {
        return _amountsFor(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IHybridHub
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts) {
        return _amountsFor(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IHybridHub
    function mintRoom() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 && _lockedShares == 0) return type(uint256).max;
        uint256 hour = block.timestamp / HOUR;
        uint256 recent = 0;
        for (uint256 i = 0; i < BUCKETS; ++i) {
            Bucket memory b = _minted[i];
            if (b.hour + BUCKETS > hour) recent += b.amount;
        }
        uint256 limit = supply * MINT_CAP / WAD;
        return limit > recent ? limit - recent : 0;
    }

    /// @inheritdoc IHybridHub
    function chainFreeze(uint256 chainId) external view returns (uint256 start, uint256 until) {
        IHybridIndexFactory.Freeze memory f = _freeze(chainId);
        return (f.start, f.until);
    }

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
