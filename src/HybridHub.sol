// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHybridHub} from "./interfaces/IHybridHub.sol";
import {IHybridIndexFactory} from "./interfaces/IHybridIndexFactory.sol";
import {HybridHubStorage} from "./hybrid/HybridHubStorage.sol";
import {VaultMessages} from "./libraries/VaultMessages.sol";

/// @title HybridHub
/// @notice An index holding tokens on Ethereum and coins in vaults on other chains. See {IHybridHub}, and
///         {IHybridIndex} for everything an index answers.
/// @dev Deployed as an EIP-1167 clone by {HybridIndexFactory}, from a template built for that factory. Stage A's
///      `IndexHub` stays as it is for indexes held entirely on Ethereum (Stage B spec, proposal 1).
///
///      The hub keeps the common paths: orders from opening to claim, redemption and claims. The rest, voids,
///      re-confirmations, stray intakes and the rebalance, runs in MODULE, which the fallback reaches by
///      DELEGATECALL on this index's own storage. The two share {HybridHubStorage} and nothing else, and MODULE is
///      fixed in the template's constructor, so it is one contract's code split in two for size, not an upgrade path.
///
///      The hub's book of each vault component, `_vaultBacking`, is exact by construction: it grows by the proven
///      deposits of every claimed order and the deliveries of every settled fill, and falls by every amount burned, all
///      derived from supply and units. Orders span the whole basket, so every order touches every vault chain.
///
///      Every function that mints, burns, pays a claim or moves an order or a fill shares one reentrancy guard. The
///      only calls out are to Ethereum components (escrow and payouts), to views (the factory's registry and the
///      chains' state verifiers), and to MODULE.
contract HybridHub is HybridHubStorage, ERC20Upgradeable, ERC20PermitUpgradeable, ReentrancyGuard, IHybridHub {
    using SafeERC20 for IERC20;

    uint256 public constant SHARE_UNIT = ONE_SHARE;
    /// @inheritdoc IHybridHub
    uint256 public constant MINT_LOCK = 24 hours;
    /// @inheritdoc IHybridHub
    uint256 public constant MAX_ORDER_LIFE = 6 hours;
    /// @inheritdoc IHybridHub
    uint256 public constant SETTLE_GRACE = GRACE;
    /// @inheritdoc IHybridHub
    uint256 public constant MINT_CAP = MINT_LIMIT;
    /// @inheritdoc IHybridHub
    uint256 public constant FREEZE_DURATION = FREEZE_LENGTH;
    /// @inheritdoc IHybridHub
    address public immutable FACTORY;
    /// @inheritdoc IHybridHub
    address public immutable MODULE;

    /// @param factory The factory whose clones this template serves; it checks this when it is deployed.
    /// @param module The module built for the same factory, which the fallback delegates to.
    constructor(address factory, address module) {
        if (factory == address(0) || module == address(0)) revert ZeroAddress();
        FACTORY = factory;
        MODULE = module;
        if (IHybridHub(module).FACTORY() != factory) revert WrongModule(module);
        _disableInitializers();
    }

    function _factory() internal view override returns (address) {
        return FACTORY;
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
        // Set once at creation: the first rebalance waits MIN_REBALANCE_INTERVAL, as in Stage A.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        _lastRebalance = block.timestamp;
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

    /// @notice Everything else an index answers ({IHybridHubModule}) runs in MODULE, on this index's storage.
    fallback(bytes calldata data) external returns (bytes memory) {
        return Address.functionDelegateCall(MODULE, data);
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

        orderId = ++_orderCount;
        intakeId = _intakeIdOf(orderId, deadline);
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
            if (_slotOf[i] == 0) _escrowed[_components[i].token] += amounts[i];
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
        _useMintRoom(o.shares, totalSupply(), o.minter);

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
        digest = _intakeDigest(j, intakeId, INTAKE_OPEN, p.tokens, p.totals);
        bytes32 proven = _provenIntake(j, intakeId, deadline, p.proof);
        if (proven != digest) revert DigestMismatch(_chains[j].chainId, proven, digest);
        uint256 n = required.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != j + 1) continue;
            uint256 total = _totalOf(i, p.tokens, p.totals);
            if (total < required[i]) revert DepositShort(_components[i].token, total, required[i]);
            deposits[i] = total;
        }
    }

    /// @inheritdoc IHybridHub
    function claimOrder(uint256 orderId) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Locked);
        if (block.timestamp < o.lockEnds) revert NotYet(o.lockEnds);
        // A fill sized for the supply at its acceptance settles at the supply of its settling block; minting in
        // between would put shares under a settlement that did not count them.
        if (_fill.status == FillStatus.Accepted) revert RebalanceInProgress();
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

        uint256 shares = o.shares;
        _lockedShares -= shares;
        // A settled rebalance may have moved units since the order opened: it claims only if what it holds still
        // covers its shares at the units in force, and otherwise fails, returning its escrow and deposits.
        if (!_covered(orderId, shares)) {
            _fail(orderId, o);
            return;
        }
        o.status = OrderStatus.Claimed;
        uint256[] memory amounts = _amounts[orderId];
        uint256[] memory deposits = _deposits[orderId];
        uint256 n = amounts.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = _components[i].token;
            if (_slotOf[i] == 0) _escrowed[token] -= amounts[i];
            // The whole deposit joins the index, surplus included, so any surplus stays with the holders.
            else _vaultBacking[token] += deposits[i];
        }
        address minter = o.minter;
        _mint(minter, shares);
        // The calls before this are views on the factory's freeze record; `_mint` is internal.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderClaimed(orderId, minter, shares);
        uint256 intakeId = _intakeIdOf(orderId, o.deadline);
        _settledIntakes[intakeId] = true;
        _sendAll(VaultMessages.INTAKE_SETTLED, abi.encode(intakeId));
    }

    /// @dev Whether an order's escrow and deposits cover its shares at the units in force.
    function _covered(uint256 orderId, uint256 shares) private view returns (bool) {
        uint256[] memory held = _amounts[orderId];
        uint256[] memory deposits = _deposits[orderId];
        uint256 n = held.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 have = _slotOf[i] == 0 ? held[i] : deposits[i];
            if (have < _backing(shares, _components[i].units, Math.Rounding.Ceil)) return false;
        }
        return true;
    }

    /// @inheritdoc IHybridHub
    function failOrder(uint256 orderId) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Open);
        uint256 openTo = o.deadline + GRACE;
        if (msg.sender != o.minter && block.timestamp <= openTo) revert NotYet(openTo);
        _fail(orderId, o);
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
            bool skipped = skipMask & (1 << i) != 0;
            // Booked to `to`, which receives every other component of this redemption (DA-17).
            if (skipped || (slot != 0 && recipients[slot - 1] == bytes32(0))) {
                _bookClaim(to, _components[i].token, amount);
            } else if (slot != 0) {
                _sendBurn(i, amount, recipients[slot - 1]);
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
        _sendBurn(position - 1, amount, recipient);
    }

    function _takeClaim(address token) private returns (uint256 amount) {
        amount = _claimOf[msg.sender][token];
        if (amount == 0) revert NothingToClaim(token);
        delete _claimOf[msg.sender][token];
        _totalClaims[token] -= amount;
    }

    // ---------------------------------------------------------------------
    // The mint cap, recipients
    // ---------------------------------------------------------------------

    function _checkRecipient(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (_isTrap(to)) revert InvalidRecipient(to);
    }

    /// @dev Shares or tokens sent to the index or its factory could never move on (CR-I01, RT-21). A fill's bond is
    ///      the one holding of the index's own shares, and the module moves it without this check.
    function _update(address from, address to, uint256 value) internal override {
        if (_isTrap(to)) revert InvalidRecipient(to);
        super._update(from, to, value);
    }

    function _isTrap(address to) private view returns (bool) {
        return to == address(this) || to == FACTORY;
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
    function mintRoom() external view returns (uint256) {
        return _mintRoom(totalSupply());
    }

    /// @inheritdoc IHybridHub
    function vaultBacking(address token) external view returns (uint256) {
        return _vaultBacking[token];
    }

    /// @inheritdoc IHybridHub
    function escrowed(address token) external view returns (uint256) {
        return _escrowed[token];
    }

    /// @inheritdoc IHybridHub
    function claimOf(address account, address token) external view returns (uint256) {
        return _claimOf[account][token];
    }

    /// @inheritdoc IHybridHub
    function totalClaims(address token) external view returns (uint256) {
        return _totalClaims[token];
    }

    /// @inheritdoc IHybridHub
    function orderCount() external view returns (uint256) {
        return _orderCount;
    }

    /// @inheritdoc IHybridHub
    function messageNonce() external view returns (uint256) {
        return _messageNonce;
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
