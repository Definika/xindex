// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHybridHubModule} from "../interfaces/IHybridHubModule.sol";
import {IHybridIndexFactory} from "../interfaces/IHybridIndexFactory.sol";
import {IIndexFactory} from "../interfaces/IIndexFactory.sol";
import {VaultMessages} from "../libraries/VaultMessages.sol";
import {HybridHubStorage} from "./HybridHubStorage.sol";
import {HubShares} from "./HubShares.sol";

/// @title HybridHubModule
/// @notice The half of a HybridHub index its hub delegates to: voids, re-confirmations and stray intakes of orders, and
///         the rebalance. See {IHybridHubModule}.
/// @dev Runs only by DELEGATECALL from a hub clone, on the clone's storage: called directly it is never initialized,
///      so every path that moves anything refuses. The rebalance's start, band, notice, keep mask and cancel are Stage
///      A's `IndexHub`'s, unchanged; its fill takes three steps, since vault legs cannot settle in one transaction:
///      accept (bond and Ethereum deliveries), the vault deliveries under the fill's intake, and settle on their proofs,
///      at the supply of the settling block. The bond is held BOND_HOLD after settlement and burned if a delivery
///      proves forged (Stage B spec, section 5.3).
contract HybridHubModule is HybridHubStorage, HubShares, ReentrancyGuard, IHybridHubModule {
    using SafeERC20 for IERC20;

    /// @inheritdoc IHybridHubModule
    uint256 public constant MIN_REBALANCE_INTERVAL = 7 days;
    /// @inheritdoc IHybridHubModule
    uint256 public constant REBALANCE_DELAY = 2 days;
    /// @inheritdoc IHybridHubModule
    uint256 public constant AUCTION_DURATION = 24 hours;
    /// @inheritdoc IHybridHubModule
    uint256 public constant MAX_SUPPLY_STEP = 0.005e18;
    /// @inheritdoc IHybridHubModule
    uint256 public constant MIN_BAND = 0.001e18;
    /// @inheritdoc IHybridHubModule
    uint256 public constant REBALANCE_BOND = 0.001e18;
    /// @inheritdoc IHybridHubModule
    uint256 public constant BOND_HOLD = 24 hours;
    /// @inheritdoc IHybridHubModule
    uint256 public constant DELIVERY_WINDOW = 6 hours;
    /// @notice The factory the hubs this module serves belong to.
    address public immutable FACTORY;

    constructor(address factory) {
        if (factory == address(0)) revert ZeroAddress();
        FACTORY = factory;
        _disableInitializers();
    }

    function _factory() internal view override returns (address) {
        return FACTORY;
    }

    // ---------------------------------------------------------------------
    // Orders: voids, re-confirmations, stray intakes
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubModule
    function voidOrder(uint256 orderId, uint256 chainId, bytes calldata proof) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Locked);
        uint256 j = _slotIndex(chainId);
        bytes32 proven = _provenIntake(j, _intakeIdOf(orderId, o.deadline), o.deadline, proof);
        bytes32 recorded = _digests[orderId][j];
        // After the deadline an intake's deposits are final, and it stays open until the hub settles or fails it, so a
        // proof showing anything else means the deposit or the proof that settled the order was false.
        if (proven == recorded) revert NotAContradiction(chainId);

        _lockedShares -= o.shares;
        // The calls before this are views: the factory's registry and a state verifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderVoided(orderId, chainId, proven, recorded);
        _freezeOwn(chainId);
        _fail(orderId, o);
    }

    /// @inheritdoc IHybridHubModule
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

    /// @inheritdoc IHybridHubModule
    function failIntake(uint256 chainId, uint256 intakeId) external nonReentrant onlyInitialized {
        uint256 j = _slotIndex(chainId);
        uint256 deadline = intakeId >> DEADLINE_SHIFT;
        // No order or fill can ever take an intake whose deadline has passed, since theirs lie in the future.
        if (deadline >= block.timestamp) revert IntakeStillOpen(deadline);
        if (_fillIntakes[intakeId]) revert IntakeOfARebalance(intakeId);
        uint256 orderId = intakeId & ORDER_ID_MASK;
        if (orderId != 0 && orderId <= _orderCount && _orders[orderId].deadline == deadline) {
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
    // The rebalance: start and cancel, as Stage A
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubModule
    function startRebalance(uint256 keepMask) external nonReentrant onlyInitialized {
        uint256 earliest = _lastRebalance + MIN_REBALANCE_INTERVAL;
        if (block.timestamp < earliest) revert RebalanceTooSoon(earliest);
        if (_fill.status == FillStatus.Accepted) revert RebalancePending(_fill.deadline + GRACE);
        uint256 pendingEta = _pending.eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) {
            revert RebalancePending(pendingEta + AUCTION_DURATION);
        }
        uint256 n = _components.length;
        if (keepMask >> n != 0 || keepMask == (1 << n) - 1) revert InvalidKeepMask(keepMask);
        if (
            (keepMask != 0 || block.timestamp < _permissionlessAt(pendingEta))
                && !IIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)
        ) revert Unauthorized(msg.sender);

        (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax) = _band(keepMask);
        if (lambdaMax * WAD < lambdaMin * (WAD + MIN_BAND)) revert BandTooNarrow(lambdaMin, lambdaMax);

        delete _ratios;
        for (uint256 i = 0; i < n; ++i) {
            _ratios.push(SafeCast.toUint64(ratios[i]));
        }
        uint256 eta = block.timestamp + REBALANCE_DELAY;
        _pending = PendingRebalance({
            eta: SafeCast.toUint40(eta),
            lambdaMax: SafeCast.toUint64(lambdaMax),
            lambdaMin: SafeCast.toUint64(lambdaMin)
        });
        _keepMask = keepMask;
        uint256 proposalId = ++_proposalCount;
        // The calls above are views on the factory; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceStarted(proposalId, _rebalanceNonce + 1, msg.sender, keepMask, lambdaMin, lambdaMax, ratios, eta);
    }

    /// @dev As Stage A: a cancel, or an auction that expired unfilled, holds strangers off for REBALANCE_DELAY.
    function _permissionlessAt(uint256 pendingEta) private view returns (uint256) {
        uint256 afterExpiry = pendingEta == 0 ? 0 : pendingEta + AUCTION_DURATION + REBALANCE_DELAY;
        return Math.max(_restartAllowedAt, afterExpiry);
    }

    /// @inheritdoc IHybridHubModule
    function cancelRebalance() external nonReentrant onlyInitialized {
        if (!IIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
        uint256 restartAt;
        if (_fill.status == FillStatus.Accepted) {
            // The executor did nothing wrong: its bond comes back, and the rest unwinds as a failure.
            restartAt = block.timestamp + REBALANCE_DELAY;
            _unwind(false);
        } else {
            uint256 eta = _pending.eta;
            if (eta == 0) revert NoPendingRebalance();
            restartAt =
                block.timestamp <= eta + AUCTION_DURATION ? block.timestamp + REBALANCE_DELAY : _permissionlessAt(eta);
            _clearPending();
        }
        _restartAllowedAt = restartAt;
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceCancelled(_proposalCount, msg.sender, restartAt);
    }

    function _clearPending() private {
        delete _pending;
        delete _keepMask;
        delete _ratios;
    }

    // ---------------------------------------------------------------------
    // The fill: accept, settle, fail, bond
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubModule
    function acceptRebalance(bytes32[] calldata recipients, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        onlyInitialized
    {
        if (recipients.length != _chains.length) revert LengthMismatch();
        // The last fill's bond is released on the way: its hold is always over, since a fill settles no sooner than
        // MIN_REBALANCE_INTERVAL and REBALANCE_DELAY after the last, and both outlast BOND_HOLD
        // (`test_theLastHoldIsAlwaysOverByTheNextAuction`).
        if (_fill.status == FillStatus.Settled) _releaseBond();
        if (_fill.status != FillStatus.None) revert WrongFillStatus(_fill.status);
        uint256 supply = _shareSupply();
        (uint256 lambda, uint256[] memory units,, uint256[] memory amountsIn) = _previewRebalance(supply);
        _checkBounds(amountsIn, maxAmountsIn);
        _checkMovingChains(units);

        uint256 bond = Math.mulDiv(supply, REBALANCE_BOND, WAD, Math.Rounding.Ceil);
        uint256 nonce = _rebalanceNonce + 1;
        uint256 deadline = block.timestamp + DELIVERY_WINDOW;
        uint256 intakeId = (deadline << DEADLINE_SHIFT) | FILL_FLAG | nonce;
        _fill = StoredFill({
            executor: msg.sender,
            status: FillStatus.Accepted,
            deadline: SafeCast.toUint40(deadline),
            bondRelease: 0,
            lambda: SafeCast.toUint64(lambda),
            bond: bond,
            nonce: nonce
        });
        _fillUnits = units;
        _fillIn = amountsIn;
        delete _fillDelivered;
        _fillRecipients = recipients;
        _fillIntakes[intakeId] = true;
        _clearPending();
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] == 0) _escrowed[_components[i].token] += amountsIn[i];
        }
        // The calls before this are views: the factory's supplies and freeze records.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceAccepted(nonce, msg.sender, lambda, units, amountsIn, intakeId, deadline, bond);

        // The bond is held as the index's own shares, the one holding of them there is.
        _moveShares(msg.sender, address(this), bond);
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != 0 || amountsIn[i] == 0) continue;
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amountsIn[i]);
            if (token.balanceOf(address(this)) - before < amountsIn[i]) revert TransferAmountMismatch(address(token));
        }
    }

    /// @dev DA-13's bound: an executor sized from a simulation binds the fill to what it quoted.
    function _checkBounds(uint256[] memory amountsIn, uint256[] calldata maxAmountsIn) private view {
        uint256 bounds = maxAmountsIn.length;
        if (bounds == 0) return;
        if (bounds != amountsIn.length) revert LengthMismatch();
        for (uint256 i = 0; i < bounds; ++i) {
            if (amountsIn[i] > maxAmountsIn[i]) {
                revert RebalanceMovedOn(_components[i].token, amountsIn[i], maxAmountsIn[i]);
            }
        }
    }

    /// @dev A chain with a moving vault leg must not be frozen: its vault takes no deposit and pays nothing while it is.
    function _checkMovingChains(uint256[] memory units) private view {
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 slot = _slotOf[i];
            if (slot != 0 && units[i] != _components[i].units) _checkNotFrozen(_chains[slot - 1].chainId);
        }
    }

    /// @inheritdoc IHybridHubModule
    function settleRebalance(ChainProof[] calldata proofs) external nonReentrant onlyInitialized {
        StoredFill memory f = _fill;
        if (f.status != FillStatus.Accepted) revert WrongFillStatus(f.status);
        uint256 m = _chains.length;
        if (proofs.length != m) revert LengthMismatch();
        uint256 supply = _shareSupply();
        (uint256[] memory out, uint256[] memory need) = _fillSettlement(supply);
        uint256 intakeId = _fillIntakeIdOf(f);
        uint256[] memory delivered = new uint256[](need.length);
        for (uint256 j = 0; j < m; ++j) {
            _proveDeliveries(j, intakeId, proofs[j], need, delivered);
        }

        uint256 n = need.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = _components[i].token;
            if (_slotOf[i] == 0) {
                // Taken at acceptance, at that block's supply, which no settlement's exceeds.
                delivered[i] = _fillIn[i];
                _escrowed[token] -= _fillIn[i];
            } else {
                _vaultBacking[token] += delivered[i];
            }
            _components[i].units = SafeCast.toUint96(_fillUnits[i]);
        }
        _rebalanceNonce = f.nonce;
        _lastRebalance = block.timestamp;
        _fill.status = FillStatus.Settled;
        _fill.bondRelease = SafeCast.toUint40(block.timestamp + BOND_HOLD);
        _fillDelivered = delivered;
        // The calls before this are views: the factory's registry and the state verifiers.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Rebalanced(f.nonce, f.executor, _fillUnits, out, delivered);

        for (uint256 i = 0; i < n; ++i) {
            uint256 slot = _slotOf[i];
            if (out[i] == 0 || slot == 0) continue;
            _sendBurn(i, out[i], _fillRecipients[slot - 1]);
        }
        _sendAll(VaultMessages.INTAKE_SETTLED, abi.encode(intakeId));
        for (uint256 i = 0; i < n; ++i) {
            if (out[i] != 0 && _slotOf[i] == 0) IERC20(_components[i].token).safeTransfer(f.executor, out[i]);
        }
        _checkBacking(supply);
    }

    /// @dev Each component's payout and needed delivery for the live fill at `supply`: the change in required backing,
    ///      rounded the holders' way, down when it leaves and up when it comes back (SA-07).
    function _fillSettlement(uint256 supply) private view returns (uint256[] memory out, uint256[] memory need) {
        uint256 n = _components.length;
        out = new uint256[](n);
        need = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = _components[i].units;
            uint256 next = _fillUnits[i];
            if (next < current) out[i] = _backing(supply, current - next, Math.Rounding.Floor);
            else need[i] = _backing(supply, next - current, Math.Rounding.Ceil);
        }
    }

    /// @dev Proves the `j`-th chain's delivery intake, if any component there needs a delivery, and records what each
    ///      delivered, which must cover what it needs. A chain with nothing to deliver takes an empty proof.
    function _proveDeliveries(
        uint256 j,
        uint256 intakeId,
        ChainProof calldata p,
        uint256[] memory need,
        uint256[] memory delivered
    ) private view {
        uint256 n = need.length;
        bool any = false;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] == j + 1 && need[i] != 0) any = true;
        }
        if (!any) return;
        bytes32 digest = _intakeDigest(j, intakeId, INTAKE_OPEN, p.tokens, p.totals);
        // Deliveries only grow until the deadline, so a proof from before it is as good as one after.
        bytes32 proven = _provenIntake(j, intakeId, 0, p.proof);
        if (proven != digest) revert DigestMismatch(_chains[j].chainId, proven, digest);
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != j + 1) continue;
            uint256 total = _totalOf(i, p.tokens, p.totals);
            if (total < need[i]) revert DeliveryShort(_components[i].token, total, need[i]);
            delivered[i] = total;
        }
    }

    /// @dev The invariants with the new units, for every component: Ethereum balances cover the backing, claims and
    ///      escrow, and the book of each vault covers its backing and claims.
    function _checkBacking(uint256 supply) private view {
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

    /// @inheritdoc IHybridHubModule
    function failRebalance() external nonReentrant onlyInitialized {
        StoredFill memory f = _fill;
        if (f.status != FillStatus.Accepted) revert WrongFillStatus(f.status);
        uint256 openTo = f.deadline + GRACE;
        if (msg.sender != f.executor && block.timestamp <= openTo) revert NotYet(openTo);
        _unwind(true);
        uint256 restartAt = block.timestamp + REBALANCE_DELAY;
        if (restartAt > _restartAllowedAt) _restartAllowedAt = restartAt;
    }

    /// @dev Unwinds an accepted fill: its Ethereum deliveries become the executor's claims, every vault refunds its
    ///      deliveries, and its bond is burned, raising every share's backing, or returned.
    function _unwind(bool burnBond) private {
        StoredFill memory f = _fill;
        delete _fill;
        uint256[] memory taken = _fillIn;
        uint256 n = taken.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != 0 || taken[i] == 0) continue;
            address token = _components[i].token;
            _escrowed[token] -= taken[i];
            _bookClaim(f.executor, token, taken[i]);
        }
        _clearFill();
        if (burnBond) _burnShares(address(this), f.bond);
        else _moveShares(address(this), f.executor, f.bond);
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceFailed(f.nonce, msg.sender, burnBond);
        _sendAll(VaultMessages.INTAKE_FAILED, abi.encode(_fillIntakeIdOf(f)));
    }

    /// @inheritdoc IHybridHubModule
    function releaseBond() external nonReentrant onlyInitialized {
        if (_fill.status != FillStatus.Settled) revert WrongFillStatus(_fill.status);
        if (block.timestamp < _fill.bondRelease) revert NotYet(_fill.bondRelease);
        _releaseBond();
    }

    function _releaseBond() private {
        StoredFill memory f = _fill;
        delete _fill;
        _clearFill();
        _moveShares(address(this), f.executor, f.bond);
        // `_moveShares` is internal; no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BondReleased(f.nonce, f.executor, f.bond);
    }

    /// @inheritdoc IHybridHubModule
    function slashRebalance(uint256 chainId, uint8 state, ChainProof calldata proof)
        external
        nonReentrant
        onlyInitialized
    {
        StoredFill memory f = _fill;
        if (f.status != FillStatus.Settled) revert WrongFillStatus(f.status);
        if (block.timestamp >= f.bondRelease) revert NotYet(f.bondRelease);
        uint256 j = _slotIndex(chainId);
        uint256 intakeId = _fillIntakeIdOf(f);
        bytes32 proven = _provenIntake(j, intakeId, 0, proof.proof);
        if (!_isForged(j, intakeId, proven, state, proof)) revert NotAContradiction(chainId);

        delete _fill;
        _clearFill();
        _burnShares(address(this), f.bond);
        // The calls before this are views: the factory's registry and a state verifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceSlashed(f.nonce, chainId, f.bond);
        _freezeOwn(chainId);
    }

    /// @dev A delivery intake after settlement is honestly open or settled, with at least what the fill recorded, for
    ///      deliveries only grow and the settle message moves them whole. Anything else, an intake the vault never had
    ///      (an empty slot) included, shows a delivery was forged.
    function _isForged(uint256 j, uint256 intakeId, bytes32 proven, uint8 state, ChainProof calldata p)
        private
        view
        returns (bool)
    {
        if (proven == bytes32(0)) return true;
        bytes32 digest = _intakeDigest(j, intakeId, state, p.tokens, p.totals);
        if (proven != digest) revert DigestMismatch(_chains[j].chainId, proven, digest);
        if (state != INTAKE_OPEN && state != INTAKE_SETTLED) return true;
        uint256 n = _components.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] == j + 1 && _totalOf(i, p.tokens, p.totals) < _fillDelivered[i]) return true;
        }
        return false;
    }

    function _clearFill() private {
        delete _fillUnits;
        delete _fillIn;
        delete _fillDelivered;
        delete _fillRecipients;
    }

    function _fillIntakeIdOf(StoredFill memory f) private pure returns (uint256) {
        return (uint256(f.deadline) << DEADLINE_SHIFT) | FILL_FLAG | f.nonce;
    }

    // ---------------------------------------------------------------------
    // The band and the settlement, as Stage A
    // ---------------------------------------------------------------------

    /// @dev Settlement for the current block at the current λ, as Stage A's `_previewRebalance`: a settlement that
    ///      would send nothing out is taken at λmax, so the units never depend on timing when nothing is paid for.
    function _previewRebalance(uint256 supply)
        private
        view
        returns (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        PendingRebalance memory pending = _pending;
        uint256 eta = pending.eta;
        if (eta == 0) revert NoPendingRebalance();
        if (block.timestamp < eta) revert RebalanceNotReady(eta);
        if (block.timestamp > eta + AUCTION_DURATION) revert RebalanceExpired(eta + AUCTION_DURATION);

        lambda = pending.lambdaMax
            - Math.mulDiv(pending.lambdaMax - pending.lambdaMin, block.timestamp - eta, AUCTION_DURATION);
        bool sells;
        (units, amountsOut, amountsIn, sells) = _settlementAt(lambda, supply);
        if (!sells && lambda != pending.lambdaMax) {
            lambda = pending.lambdaMax;
            (units, amountsOut, amountsIn,) = _settlementAt(lambda, supply);
        }
    }

    function _settlementAt(uint256 lambda, uint256 supply)
        private
        view
        returns (uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn, bool sells)
    {
        uint256 n = _components.length;
        units = new uint256[](n);
        amountsOut = new uint256[](n);
        amountsIn = new uint256[](n);
        sells = false;
        uint256 keepMask = _keepMask;
        for (uint256 i = 0; i < n; ++i) {
            uint256 current = _components[i].units;
            if ((keepMask & (1 << i)) != 0) {
                units[i] = current;
                continue;
            }
            uint256 next = Math.mulDiv(lambda, current, _ratios[i], Math.Rounding.Ceil);
            units[i] = next;
            if (next < current) {
                uint256 out = _backing(supply, current - next, Math.Rounding.Floor);
                amountsOut[i] = out;
                if (out != 0) sells = true;
            } else {
                amountsIn[i] = _backing(supply, next - current, Math.Rounding.Ceil);
            }
        }
    }

    /// @dev Stage A's band over the components not in `keepMask`, from the factory's reference supplies, a vault
    ///      token's included: each moving component's ρ relative to the first one's, centred, then clamped to
    ///      1e18 ± MAX_SUPPLY_STEP.
    function _band(uint256 keepMask)
        private
        view
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax)
    {
        uint256 low;
        uint256 high;
        (ratios, low, high) = _relatives(keepMask);
        uint256 centre = (low + high) / 2;
        lambdaMin = type(uint256).max;
        lambdaMax = 0;
        uint256 n = ratios.length;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            uint256 r = Math.mulDiv(ratios[i], WAD, centre);
            if (r < WAD - MAX_SUPPLY_STEP) r = WAD - MAX_SUPPLY_STEP;
            else if (r > WAD + MAX_SUPPLY_STEP) r = WAD + MAX_SUPPLY_STEP;
            ratios[i] = r;
            if (r < lambdaMin) lambdaMin = r;
            if (r > lambdaMax) lambdaMax = r;
        }
    }

    /// @dev ρ_i / ρ_a in WAD for every moving component, where ρ = units / supply and a is the first moving component,
    ///      which cancels a's own figures exactly; with the smallest and largest of them. Units are below 2^96 and
    ///      supplies below 2^128, so the products fit.
    function _relatives(uint256 keepMask) private view returns (uint256[] memory relative, uint256 low, uint256 high) {
        uint256 n = _components.length;
        address[] memory tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
        uint256[] memory supplies = IIndexFactory(FACTORY).referenceSupplies(tokens);
        relative = new uint256[](n);
        low = type(uint256).max;
        high = 0;
        uint256 anchorUnits = 0;
        uint256 anchorSupply = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            uint256 units = _components[i].units;
            if (anchorUnits == 0) (anchorUnits, anchorSupply) = (units, supplies[i]);
            uint256 r = Math.mulDiv(units * anchorSupply, WAD, supplies[i] * anchorUnits);
            relative[i] = r;
            if (r < low) low = r;
            if (r > high) high = r;
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubModule
    function fill() external view returns (Fill memory) {
        StoredFill memory f = _fill;
        return Fill({
            executor: f.executor,
            status: f.status,
            nonce: f.nonce,
            lambda: f.lambda,
            bond: f.bond,
            deadline: f.deadline,
            bondRelease: f.bondRelease
        });
    }

    /// @inheritdoc IHybridHubModule
    function fillIntakeId() external view returns (uint256) {
        return _fill.status == FillStatus.None ? 0 : _fillIntakeIdOf(_fill);
    }

    /// @inheritdoc IHybridHubModule
    function fillAmounts()
        external
        view
        returns (uint256[] memory units, uint256[] memory deliveries, uint256[] memory delivered)
    {
        return (_fillUnits, _fillIn, _fillDelivered);
    }

    /// @inheritdoc IHybridHubModule
    function previewBand(uint256 keepMask)
        external
        view
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax)
    {
        return _band(keepMask);
    }

    /// @inheritdoc IHybridHubModule
    function pendingRebalance()
        external
        view
        returns (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios)
    {
        PendingRebalance memory pending = _pending;
        uint256 n = _ratios.length;
        ratios = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            ratios[i] = _ratios[i];
        }
        return (pending.eta, _keepMask, pending.lambdaMin, pending.lambdaMax, ratios);
    }

    /// @inheritdoc IHybridHubModule
    function previewRebalance()
        external
        view
        returns (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        return _previewRebalance(_shareSupply());
    }

    /// @inheritdoc IHybridHubModule
    function canStartRebalance() external view returns (bool) {
        if (_getInitializedVersion() != 1) return false;
        if (block.timestamp < _lastRebalance + MIN_REBALANCE_INTERVAL) return false;
        if (_fill.status == FillStatus.Accepted) return false;
        uint256 pendingEta = _pending.eta;
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) return false;
        return block.timestamp >= _permissionlessAt(pendingEta);
    }

    /// @inheritdoc IHybridHubModule
    function proposalCount() external view returns (uint256) {
        return _proposalCount;
    }

    /// @inheritdoc IHybridHubModule
    function rebalanceNonce() external view returns (uint256) {
        return _rebalanceNonce;
    }

    /// @inheritdoc IHybridHubModule
    function lastRebalance() external view returns (uint256) {
        return _lastRebalance;
    }

    /// @inheritdoc IHybridHubModule
    function restartAllowedAt() external view returns (uint256) {
        return _restartAllowedAt;
    }
}
