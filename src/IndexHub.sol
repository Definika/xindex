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
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexHub} from "./interfaces/IIndexHub.sol";
import {IRebalanceExecutor} from "./interfaces/IRebalanceExecutor.sol";

/// @title IndexHub
/// @notice Fully collateralized index token with fixed constituents whose units follow their reference supplies.
///         See {IIndexHub}.
/// @dev Deployed as an EIP-1167 clone by {IndexFactory}. The implementation is deployed from the factory constructor,
///      so `FACTORY` can be an immutable (immutables live in bytecode, which clones delegate to, so every clone sees the
///      same value).
///
///      The storage-based {ReentrancyGuard} is used deliberately: its namespaced slot reads as "not entered" when zero,
///      so it needs no initializer and is safe in a clone. Every function that mints, burns, pays a claim or changes a
///      rebalance shares it.
///
///      Only an initialized clone can issue, redeem or rebalance. The implementation and any clone deployed outside the
///      factory have no components and would otherwise mint unbacked shares.
///
///      Invariant, for every component i:
///          token_i.balanceOf(index) >= floor(totalSupply * units_i / 1e18) + totalClaims[token_i]
///      Issue rounds up and redeem rounds down, so rounding drift is at most one raw unit per call and is always in
///      favour of the remaining holders. A claim is recorded only for an amount that stayed in the index, so claims
///      never dilute other holders. Nothing is ever computed from balances, so there is no share price to manipulate
///      and no first-depositor attack.
///
///      Rebalancing, with no price anywhere. Units should be proportional to reference supplies, so a market-cap
///      index never trades on a price move. Once MIN_REBALANCE_INTERVAL has passed, anyone can snapshot the band: for
///      each moving component, ρ = units / reference supply, and its ratio r = 2ρ / (ρmin + ρmax), clamped to
///      [1 − MAX_SUPPLY_STEP, 1 + MAX_SUPPLY_STEP]. After REBALANCE_DELAY of notice, λ falls linearly from the
///      largest ratio to the smallest over AUCTION_DURATION, and a fill at λ sets each moving component's units to
///      ceil(λ · u / r). At any prices the value-neutral λ, Σ u·p / Σ (u/r)·p, is a weighted average of the ratios, so
///      it lies inside the band: a fill leaves holders at least λmin / λmax of the moving value, at most 0.995% less,
///      whatever the market does between the snapshot and the fill. A full fill makes units proportional to supplies
///      again, so the skew a keep mask leaves and rounding drift heal instead of compounding. Transfer amounts come
///      from supply and units alone, and the settlement stands only if the invariant holds with the new units.
contract IndexHub is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, ReentrancyGuard, IIndexHub {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = 1e18;
    uint256 public constant REBALANCE_DELAY = 2 days;
    uint256 public constant MIN_REBALANCE_INTERVAL = 7 days;
    uint256 public constant AUCTION_DURATION = 24 hours;
    uint256 public constant MAX_SUPPLY_STEP = 0.005e18;
    /// @dev Twice the widest rounding gap between two freshly anchored components held at 10,000 raw units, and a tenth
    ///      of the widest band, so a band this narrow means units already follow supplies to within rounding.
    uint256 public constant MIN_BAND = 0.001e18;
    address public immutable FACTORY;

    uint256 private constant WAD = 1e18;

    struct Component {
        address token;
        uint96 units;
    }

    /// @dev `eta == 0` means no rebalance is pending. Both ends of the band lie within 1e18 ± MAX_SUPPLY_STEP.
    struct PendingRebalance {
        uint40 eta;
        uint64 lambdaMax;
        uint64 lambdaMin;
    }

    Component[] private _components;

    /// @inheritdoc IIndexHub
    mapping(address account => mapping(address token => uint256 amount)) public claimOf;

    /// @inheritdoc IIndexHub
    mapping(address token => uint256 amount) public totalClaims;

    PendingRebalance private _pending;
    uint256 private _keepMask;
    /// @dev The pending band's ratio per component, zero for a kept one; empty when nothing is pending.
    uint64[] private _ratios;

    /// @inheritdoc IIndexHub
    uint256 public proposalCount;

    /// @inheritdoc IIndexHub
    uint256 public rebalanceNonce;

    /// @inheritdoc IIndexHub
    uint256 public lastRebalance;

    /// @inheritdoc IIndexHub
    uint256 public restartAllowedAt;

    modifier onlyInitialized() {
        _checkInitialized();
        _;
    }

    constructor() {
        FACTORY = msg.sender;
        _disableInitializers();
    }

    /// @inheritdoc IIndexHub
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address[] calldata tokens,
        uint256[] calldata units
    ) external initializer {
        if (msg.sender != FACTORY) revert NotFactory();
        uint256 n = tokens.length;
        if (n == 0 || n != units.length) revert InvalidComponents();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        for (uint256 i = 0; i < n; ++i) {
            if (tokens[i] == address(0) || units[i] == 0) revert InvalidComponents();
            _components.push(Component({token: tokens[i], units: SafeCast.toUint96(units[i])}));
        }
        // Set once at creation, in the same transaction as the factory's IndexCreated event.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        lastRebalance = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Issue / redeem / claim
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexHub
    function issue(uint256 shares, address to) external nonReentrant onlyInitialized {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);

        // Effects and event first, then pull the basket. The transfer check below makes the
        // mint conditional on receiving every component in full.
        uint256[] memory amounts = _amounts(shares, Math.Rounding.Ceil);
        _mint(to, shares);
        // `_mint` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Issued(msg.sender, to, shares, amounts);

        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            // Rejects fee-on-transfer / deflationary tokens even if a whitelisted token changes behaviour.
            if (token.balanceOf(address(this)) - before < amounts[i]) {
                revert TransferAmountMismatch(address(token));
            }
        }
    }

    /// @inheritdoc IIndexHub
    function redeem(uint256 shares, address to) external nonReentrant onlyInitialized {
        _redeem(shares, to, 0);
    }

    /// @inheritdoc IIndexHub
    function redeemSkipping(uint256 shares, address to, uint256 skipMask) external nonReentrant onlyInitialized {
        if (skipMask == 0 || skipMask >> _components.length != 0) revert InvalidSkipMask(skipMask);
        _redeem(shares, to, skipMask);
    }

    /// @inheritdoc IIndexHub
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        _checkRecipient(to);
        amount = claimOf[msg.sender][token];
        if (amount == 0) revert NothingToClaim(token);

        delete claimOf[msg.sender][token];
        totalClaims[token] -= amount;
        emit Claimed(msg.sender, to, token, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Burns first, books every skipped component as a claim, then transfers the rest.
    function _redeem(uint256 shares, address to, uint256 skipMask) private {
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);

        uint256[] memory amounts = _amounts(shares, Math.Rounding.Floor);
        _burn(msg.sender, shares);
        // `_burn` is internal (OpenZeppelin); no external call precedes this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, to, shares, amounts);

        uint256 n = amounts.length;
        if (skipMask != 0) {
            for (uint256 i = 0; i < n; ++i) {
                uint256 amount = amounts[i];
                if (amount == 0 || (skipMask & (1 << i)) == 0) continue;
                address token = _components[i].token;
                // Booked to `to`, which receives every other component of this redemption. Booking it to msg.sender
                // stranded the skipped components whenever a router redeemed on a holder's behalf, because only the
                // router could ever collect them (DA-17).
                claimOf[to][token] += amount;
                totalClaims[token] += amount;
                // forge-lint: disable-next-line(reentrancy-events)
                emit ClaimRecorded(to, token, amount);
            }
        }

        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] == 0 || (skipMask & (1 << i)) != 0) continue;
            IERC20(_components[i].token).safeTransfer(to, amounts[i]);
        }
    }

    // ---------------------------------------------------------------------
    // Rebalance
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexHub
    function startRebalance(uint256 keepMask) external nonReentrant onlyInitialized {
        uint256 earliest = lastRebalance + MIN_REBALANCE_INTERVAL;
        if (block.timestamp < earliest) revert RebalanceTooSoon(earliest);
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
        // Nothing to trade: every moving component's units already follow its supply to within rounding, which covers
        // no supply changing, every supply changing alike and a single moving component.
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
        uint256 proposalId = ++proposalCount;
        // The calls above are views on the factory; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceStarted(proposalId, rebalanceNonce + 1, msg.sender, keepMask, lambdaMin, lambdaMax, ratios, eta);
    }

    /// @dev First moment anyone may start a rebalance. A cancel holds strangers off for REBALANCE_DELAY, and so does an
    ///      auction that expired unfilled (`pendingEta` is then the expired proposal's): that gives the owner and the
    ///      guardian the first move after an expiry, so a griefer cannot take every restart with a snapshot nobody can
    ///      fill. The owner and guardian are never held off.
    function _permissionlessAt(uint256 pendingEta) private view returns (uint256) {
        uint256 afterExpiry = pendingEta == 0 ? 0 : pendingEta + AUCTION_DURATION + REBALANCE_DELAY;
        return Math.max(restartAllowedAt, afterExpiry);
    }

    /// @inheritdoc IIndexHub
    function cancelRebalance() external nonReentrant onlyInitialized {
        uint256 eta = _pending.eta;
        if (eta == 0) revert NoPendingRebalance();
        if (!IIndexFactory(FACTORY).isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
        // Cancelling an auction that already expired only clears the stale proposal the views still report: that
        // expiry holds strangers off until its own deadline plus REBALANCE_DELAY anyway, so re-arming the cooldown
        // from here would push the hold-off further out for nothing. `_permissionlessAt` keeps whichever of the two
        // runs longer. A live auction still costs a full REBALANCE_DELAY from now (VR-04).
        uint256 restartAt =
            block.timestamp <= eta + AUCTION_DURATION ? block.timestamp + REBALANCE_DELAY : _permissionlessAt(eta);
        _clearPending();
        restartAllowedAt = restartAt;
        // The factory call above is a view; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebalanceCancelled(proposalCount, msg.sender, restartAt);
    }

    /// @inheritdoc IIndexHub
    function executeRebalance(bytes calldata data) external nonReentrant onlyInitialized {
        _settle(data, new uint256[](0));
    }

    /// @inheritdoc IIndexHub
    function executeRebalance(bytes calldata data, uint256[] calldata maxAmountsIn)
        external
        nonReentrant
        onlyInitialized
    {
        _settle(data, maxAmountsIn);
    }

    function _settle(bytes calldata data, uint256[] memory maxAmountsIn) private {
        (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn) =
            _previewRebalance(totalSupply());

        // Settlement amounts scale with the supply at execution time, and issue stays open through the auction, so a
        // stranger can enlarge them between an executor's quote and its transaction. An executor that funded itself
        // from a simulation binds the fill to what it quoted (DA-13); passing nothing keeps the open settlement.
        uint256 bounds = maxAmountsIn.length;
        if (bounds != 0) {
            if (bounds != amountsIn.length) revert LengthMismatch();
            for (uint256 i = 0; i < bounds; ++i) {
                if (amountsIn[i] > maxAmountsIn[i]) {
                    revert RebalanceMovedOn(_components[i].token, amountsIn[i], maxAmountsIn[i]);
                }
            }
        }

        // What the index holds before it pays out, so the check afterwards can require the whole of `amountsIn` back:
        // surplus from rounding or a donation belongs to the holders, not to the executor.
        // A component that neither sends nor receives anything is not read at all: `amountsOut` and `amountsIn` are
        // exactly the change in its required backing, so both being zero means the requirement and the balance are
        // both unchanged and the invariant still holds from before. Skipping it keeps a keep mask working around a
        // component whose `balanceOf` reverts, not only one whose `transfer` does (DA-14).
        uint256 n = units.length;
        uint256[] memory held = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            held[i] = IERC20(_components[i].token).balanceOf(address(this));
        }

        // Effects: the new units, the nonce and the cleared proposal are in place before any token moves.
        uint256 proposalId = proposalCount;
        uint256 id = _applyRebalance(units);
        // No external call precedes this event: the transfers and the executor callback come after it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Rebalanced(proposalId, id, msg.sender, lambda, units, amountsOut, amountsIn);

        for (uint256 i = 0; i < n; ++i) {
            if (amountsOut[i] != 0) IERC20(_components[i].token).safeTransfer(msg.sender, amountsOut[i]);
        }
        // The executor has to be called back to deliver the growing components, so this cannot be the last interaction.
        // Every function that mints, burns, pays a claim or rebalances shares the guard, and the backing check below
        // reads only the final state. Wake's reentrancy detector does not model the guard, hence the suppression.
        // wake-disable-next-line reentrancy
        IRebalanceExecutor(msg.sender).onXindexRebalance(amountsOut, amountsIn, data);
        _checkBacking(units, amountsOut, amountsIn, held);
    }

    function _applyRebalance(uint256[] memory units) private returns (uint256 id) {
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            _components[i].units = SafeCast.toUint96(units[i]);
        }
        id = ++rebalanceNonce;
        lastRebalance = block.timestamp;
        _clearPending();
    }

    function _clearPending() private {
        delete _pending;
        delete _keepMask;
        delete _ratios;
    }

    /// @dev The backing invariant with the new units, and the whole of `amountsIn` on top of what the index held
    ///      before it paid out, checked after the executor has returned. The second bound is the stricter one whenever
    ///      the index held a surplus, from rounding or a donation: it keeps that surplus with the holders instead of
    ///      letting the executor deliver that much less.
    function _checkBacking(
        uint256[] memory units,
        uint256[] memory amountsOut,
        uint256[] memory amountsIn,
        uint256[] memory held
    ) private view {
        uint256 supply = totalSupply();
        uint256 n = units.length;
        for (uint256 i = 0; i < n; ++i) {
            // Nothing moved and nothing was required to: see the note in executeRebalance (DA-14).
            if (amountsOut[i] == 0 && amountsIn[i] == 0) continue;
            address token = _components[i].token;
            uint256 required = _backing(supply, units[i], Math.Rounding.Floor) + totalClaims[token];
            uint256 delivered = held[i] - amountsOut[i] + amountsIn[i];
            if (delivered > required) required = delivered;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < required) revert RebalanceUnderfunded(token, balance, required);
        }
    }

    /// @dev Settlement for the current block at the current λ. Every moving component's units become
    ///      ceil(λ · u / r); a kept one keeps its units. Amounts are the change in required backing, so they depend only
    ///      on supply and units: the index never sends out rounding dust or donations, and the executor has to deliver
    ///      every amount in full. A settlement that would send nothing out, as on an empty index or one so small that
    ///      every shrinking leg rounds to zero, is taken at λmax instead, so the units never depend on timing when
    ///      nothing is paid for: at λmax nothing shrinks, since no ratio exceeds it.
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

        lambda = _lambda(pending);
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
            uint256 before = _backing(supply, current, Math.Rounding.Floor);
            uint256 later = _backing(supply, next, Math.Rounding.Floor);
            if (later < before) {
                amountsOut[i] = before - later;
                sells = true;
            } else {
                amountsIn[i] = later - before;
            }
        }
    }

    /// @dev Linear decay from λmax at `eta` to λmin at `eta + AUCTION_DURATION`; the decrement rounds down, so λ rounds
    ///      up, towards the holders.
    function _lambda(PendingRebalance memory pending) private view returns (uint256) {
        uint256 lambdaMax = pending.lambdaMax;
        return lambdaMax - Math.mulDiv(lambdaMax - pending.lambdaMin, block.timestamp - pending.eta, AUCTION_DURATION);
    }

    /// @dev The band over the components not in `keepMask`. With ρ_i = units_i / supply_i, each moving component's
    ///      ratio is r_i = 2ρ_i / (ρmin + ρmax), clamped to 1e18 ± MAX_SUPPLY_STEP. It is computed through
    ///      R_i = ρ_i / ρ_a for the first moving component a, which cancels a's own figures exactly: the products fit,
    ///      since units are below 2^96 and supplies below 2^128. Centring before clamping means a wide band narrows to
    ///      exactly [1 − STEP, 1 + STEP] and never collapses, so no gap between the factory's supplies and the index's
    ///      units can stall it. Kept components are not read, from the factory or anywhere else.
    function _band(uint256 keepMask)
        private
        view
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax)
    {
        (uint256[] memory relative, uint256 low, uint256 high) = _relatives(keepMask, _supplies(keepMask));
        ratios = relative;
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

    /// @dev The reference supply of every component not in `keepMask`, in component order, zero for a kept one. Only
    ///      the moving components' supplies are asked for.
    function _supplies(uint256 keepMask) private view returns (uint256[] memory supplies) {
        uint256 n = _components.length;
        uint256 moving = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) ++moving;
        }
        address[] memory tokens = new address[](moving);
        uint256 k = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) tokens[k++] = _components[i].token;
        }
        uint256[] memory read = IIndexFactory(FACTORY).referenceSupplies(tokens);
        supplies = new uint256[](n);
        k = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) == 0) supplies[i] = read[k++];
        }
    }

    /// @dev ρ_i / ρ_a in WAD for every moving component, where ρ = units / supply and a is the first moving component,
    ///      with the smallest and largest of them.
    function _relatives(uint256 keepMask, uint256[] memory supplies)
        private
        view
        returns (uint256[] memory relative, uint256 low, uint256 high)
    {
        uint256 n = supplies.length;
        relative = new uint256[](n);
        low = type(uint256).max;
        high = 0;
        uint256 anchorUnits = 0;
        uint256 anchorSupply = 0;
        for (uint256 i = 0; i < n; ++i) {
            if ((keepMask & (1 << i)) != 0) continue;
            uint256 units = _components[i].units;
            if (anchorUnits == 0) {
                anchorUnits = units;
                anchorSupply = supplies[i];
            }
            uint256 r = Math.mulDiv(units * anchorSupply, WAD, supplies[i] * anchorUnits);
            relative[i] = r;
            if (r < low) low = r;
            if (r > high) high = r;
        }
    }

    function _checkInitialized() private view {
        if (_getInitializedVersion() != 1) revert NotInitialized();
    }

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (_isTrap(to)) revert InvalidRecipient(to);
    }

    /// @dev Shares sent to the index itself could never leave again: it never approves, transfers or redeems its own
    ///      shares and cannot sign a permit, so a `transfer(index, x)`, a common wallet slip, burned them for good and
    ///      left their backing stranded beside them. Every transfer and `transferFrom` refuses that recipient, as
    ///      issue, redeem and claim already did (CR-I01). Mints go to a recipient `_checkRecipient` has already
    ///      accepted, and burns go to address(0), so neither is affected.
    function _update(address from, address to, uint256 value) internal override {
        if (_isTrap(to)) revert InvalidRecipient(to);
        super._update(from, to, value);
    }

    /// @dev The addresses this index knows can never move a share or a component on: itself, and the factory, which
    ///      has no transfer or arbitrary-call function. The factory is the contract a user deals with to create
    ///      indexes, so it is the likeliest wrong paste after the index (RT-21, extending CR-I01). Both are known
    ///      without a storage read.
    function _isTrap(address to) private view returns (bool) {
        return to == address(this) || to == FACTORY;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    /// @inheritdoc IIndexHub
    function componentTokens() external view returns (address[] memory tokens) {
        uint256 n = _components.length;
        tokens = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
        }
    }

    /// @inheritdoc IIndexHub
    function components() external view returns (address[] memory tokens, uint256[] memory units) {
        return _componentArrays();
    }

    /// @inheritdoc IIndexHub
    function previewIssue(uint256 shares) external view returns (uint256[] memory amountsIn) {
        return _amounts(shares, Math.Rounding.Ceil);
    }

    /// @inheritdoc IIndexHub
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amountsOut) {
        return _amounts(shares, Math.Rounding.Floor);
    }

    /// @inheritdoc IIndexHub
    function previewBand(uint256 keepMask)
        external
        view
        returns (uint256[] memory ratios, uint256 lambdaMin, uint256 lambdaMax)
    {
        return _band(keepMask);
    }

    /// @inheritdoc IIndexHub
    function pendingRebalance()
        external
        view
        returns (uint256 eta, uint256 keepMask, uint256 lambdaMin, uint256 lambdaMax, uint256[] memory ratios)
    {
        PendingRebalance memory pending = _pending;
        eta = pending.eta;
        keepMask = _keepMask;
        lambdaMin = pending.lambdaMin;
        lambdaMax = pending.lambdaMax;
        uint256 n = _ratios.length;
        ratios = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            ratios[i] = _ratios[i];
        }
    }

    /// @inheritdoc IIndexHub
    function currentLambda() external view returns (uint256 lambda) {
        uint256 eta = _pending.eta;
        if (eta == 0 || block.timestamp < eta || block.timestamp > eta + AUCTION_DURATION) return 0;
        (lambda,,,) = _previewRebalance(totalSupply());
    }

    /// @inheritdoc IIndexHub
    function canStartRebalance() external view returns (bool) {
        // The implementation and any clone deployed outside the factory hold no components and cannot rebalance at
        // all; without this they answered true, because their `lastRebalance` is zero (DA-22).
        if (_getInitializedVersion() != 1) return false;
        if (block.timestamp < lastRebalance + MIN_REBALANCE_INTERVAL) return false;
        uint256 pendingEta = _pending.eta;
        // Defensive: the line after it already answers false during a live auction, since a pending eta puts
        // `_permissionlessAt` past its end. Kept so the view states each condition `startRebalance` checks (RT-18).
        if (pendingEta != 0 && block.timestamp <= pendingEta + AUCTION_DURATION) return false;
        return block.timestamp >= _permissionlessAt(pendingEta);
    }

    /// @inheritdoc IIndexHub
    function previewRebalance()
        external
        view
        returns (uint256 lambda, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        return _previewRebalance(totalSupply());
    }

    function _componentArrays() private view returns (address[] memory tokens, uint256[] memory units) {
        uint256 n = _components.length;
        tokens = new address[](n);
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokens[i] = _components[i].token;
            units[i] = _components[i].units;
        }
    }

    /// @dev Raw amount of every component corresponding to `shares`, with the given rounding.
    function _amounts(uint256 shares, Math.Rounding rounding) private view returns (uint256[] memory amounts) {
        uint256 n = _components.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            amounts[i] = _backing(shares, _components[i].units, rounding);
        }
    }

    /// @dev The one place a share count turns into an amount of a component: issue, redeem, the settlement and its
    ///      backing check all go through it, so a fee model changes this and its callers and nothing else.
    function _backing(uint256 shares, uint256 units, Math.Rounding rounding) private pure returns (uint256) {
        return Math.mulDiv(shares, units, SHARE_UNIT, rounding);
    }

    // ---------------------------------------------------------------------
    // Overrides
    // ---------------------------------------------------------------------

    /// @inheritdoc IERC20Permit
    function nonces(address owner) public view override(IERC20Permit, ERC20PermitUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
