// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHybridHub} from "../interfaces/IHybridHub.sol";
import {IHybridHubExtension} from "../interfaces/IHybridHubExtension.sol";
import {IHybridIndexFactory} from "../interfaces/IHybridIndexFactory.sol";
import {VaultMessages} from "../libraries/VaultMessages.sol";
import {WeightedPricing} from "../libraries/WeightedPricing.sol";
import {PythStructs} from "../interfaces/pyth/PythStructs.sol";
import {HybridHubStorage} from "./HybridHubStorage.sol";
import {HubShares} from "./HubShares.sol";

/// @title HybridHubExtension
/// @notice The part of a HybridHub index its module delegates to: migration between versions, and evidence against a
///         chain. See {IHybridHubExtension}.
/// @dev Runs only by DELEGATECALL, from a hub clone through its module, on the clone's storage: called directly it is
///      never initialized, so every path that moves anything refuses. Migration trusts the other index only because it
///      is a clone of the same template, which the factory records by its salt; everything it says it sent is checked
///      against real balances, or is a vault amount the other index has just taken off its own book.
contract HybridHubExtension is HybridHubStorage, HubShares, ReentrancyGuard, IHybridHubExtension {
    /// @inheritdoc IHybridHubExtension
    uint256 public constant HELD_ORDER_GRACE = 7 days;

    using SafeERC20 for IERC20;

    /// @notice The factory the hubs this extension serves belong to.
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
    // Migration
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubExtension
    function migrate(address newIndex, uint256 shares, uint256 newShares, address to, bytes32[] calldata recipients)
        external
        nonReentrant
        onlyInitialized
    {
        if (shares == 0 || newShares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this) || to == FACTORY) revert InvalidRecipient(to);
        if (recipients.length != _chains.length) revert LengthMismatch();
        _checkVersion(newIndex);
        uint256[] memory out = _amountsFor(shares, Math.Rounding.Floor);
        _burnShares(msg.sender, shares);
        (address[] memory tokens, uint256[] memory ethIn, uint256[] memory vaultIn) =
            _coverNewShares(newIndex, newShares, out);
        _bookRest(out, to, recipients);
        // `_burnShares` and the messages are internal; the only external call so far is the new index's view.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MigratedOut(msg.sender, newIndex, to, shares, newShares);

        uint256 m = tokens.length;
        for (uint256 k = 0; k < m; ++k) {
            if (ethIn[k] != 0) IERC20(tokens[k]).safeTransfer(newIndex, ethIn[k]);
        }
        uint256 n = out.length;
        for (uint256 i = 0; i < n; ++i) {
            if (out[i] != 0 && _slotOf[i] == 0) IERC20(_components[i].token).safeTransfer(to, out[i]);
        }
        IHybridHubExtension(newIndex).acceptMigration(msg.sender, to, newShares, ethIn, vaultIn);
    }

    /// @dev Each component of `newIndex` takes what `newShares` need from `out`, the old shares' backing of the same
    ///      token: a vault token all of it, sent inside its vault, an Ethereum token what there is. `out` keeps the rest.
    function _coverNewShares(address newIndex, uint256 newShares, uint256[] memory out)
        private
        returns (address[] memory tokens, uint256[] memory ethIn, uint256[] memory vaultIn)
    {
        uint256[] memory units;
        // A token's address names its chain and its id there, so the new index's chains and vault tokens add nothing.
        // forge-lint: disable-next-line(unused-return)
        (tokens, units,,) = IHybridHub(newIndex).components();
        uint256 m = tokens.length;
        ethIn = new uint256[](m);
        vaultIn = new uint256[](m);
        for (uint256 k = 0; k < m; ++k) {
            uint256 position = _position[tokens[k]];
            if (position == 0) continue;
            uint256 i = position - 1;
            uint256 need = _backing(newShares, units[k], Math.Rounding.Ceil);
            uint256 have = out[i];
            if (_slotOf[i] != 0) {
                // The new index refuses less than it needs; checking here names the token in the revert.
                if (have < need) revert MigrationShort(tokens[k], have, need);
                out[i] = have - need;
                vaultIn[k] = need;
                _sendMigrate(i, newIndex, need);
            } else {
                uint256 give = Math.min(have, need);
                out[i] = have - give;
                ethIn[k] = give;
            }
        }
    }

    /// @dev What the old shares back beyond the new ones goes to `to`, as a redemption's would (DA-17): a vault token
    ///      burned toward its chain's recipient, or booked as `to`'s claim where that is zero. Ethereum tokens are sent
    ///      last, by the caller.
    function _bookRest(uint256[] memory out, address to, bytes32[] calldata recipients) private {
        uint256 n = out.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 slot = _slotOf[i];
            if (out[i] == 0 || slot == 0) continue;
            if (recipients[slot - 1] == bytes32(0)) _bookClaim(to, _components[i].token, out[i]);
            else _sendBurn(i, out[i], recipients[slot - 1]);
        }
    }

    /// @dev Moves `amount` of vault component `i` from this index's balance to `newIndex`'s inside the vault: the book
    ///      falls now, and the vault moves it within its speed limit once P1 and P2 prove the message.
    function _sendMigrate(uint256 i, address newIndex, uint256 amount) private {
        address token = _components[i].token;
        uint256 j = _slotOf[i] - 1;
        _vaultBacking[token] -= amount;
        _sentOut[token] += amount;
        bytes memory payload = _payload(j, VaultMessages.MIGRATE, abi.encode(newIndex, _vaultTokenOf[i], amount));
        _post(payload);
        // forge-lint: disable-next-line(reentrancy-events)
        emit MigrateSent(token, _chains[j].chainId, newIndex, amount, keccak256(payload));
    }

    /// @inheritdoc IHybridHubExtension
    function acceptMigration(
        address holder,
        address to,
        uint256 shares,
        uint256[] calldata ethIn,
        uint256[] calldata vaultIn
    ) external nonReentrant onlyInitialized {
        _checkVersion(msg.sender);
        if (to == address(this) || to == FACTORY) revert InvalidRecipient(to);
        // Supply must not grow under a settlement sized for it, as for mint claims.
        if (_fill.status == FillStatus.Accepted) revert RebalanceInProgress();
        uint256 n = _components.length;
        if (ethIn.length != n || vaultIn.length != n) revert LengthMismatch();
        uint256[] memory owed = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 need = _backing(shares, _components[i].units, Math.Rounding.Ceil);
            uint256 slot = _slotOf[i];
            if (slot == 0) {
                if (need > ethIn[i]) owed[i] = need - ethIn[i];
                continue;
            }
            // A frozen chain's records are in doubt: no backing on it joins this index, as no mint would.
            _checkNotFrozen(_chains[slot - 1].chainId);
            address token = _components[i].token;
            if (vaultIn[i] < need) revert MigrationShort(token, vaultIn[i], need);
            _vaultBacking[token] += vaultIn[i];
        }
        _useMintRoom(shares, _shareSupply(), holder);
        _mintShares(to, shares);
        // The calls before this are views: the factory's freeze records.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MigratedIn(msg.sender, to, shares);

        for (uint256 i = 0; i < n; ++i) {
            if (owed[i] == 0) continue;
            IERC20 token = IERC20(_components[i].token);
            uint256 before = token.balanceOf(address(this));
            // `holder` is the caller of another version's `migrate`, the only caller `_checkVersion` lets in, and that
            // code names no one but its own caller.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            token.safeTransferFrom(holder, address(this), owed[i]);
            if (token.balanceOf(address(this)) - before < owed[i]) revert TransferAmountMismatch(address(token));
        }
        // What the old index says it sent is checked here, in real balances, with everything else the index owes.
        _checkBacking(_shareSupply());
    }

    /// @dev `chainId` is one of this index's vault chains.
    function _checkChain(uint256 chainId) private view {
        uint256 m = _chains.length;
        for (uint256 j = 0; j < m; ++j) {
            if (_chains[j].chainId == chainId) return;
        }
        revert NotAVaultChain(chainId);
    }

    /// @dev Only another HybridHub index of this factory: the factory records a salt for its clones of the template, and
    ///      for nothing else.
    function _checkVersion(address index) private view {
        if (index == address(this) || IHybridIndexFactory(FACTORY).indexSalt(index) == bytes32(0)) {
            revert NotAVersion(index);
        }
    }

    // ---------------------------------------------------------------------
    // Evidence
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubExtension
    function reportOutflow(uint256 chainId, IndexRecord calldata record, bytes calldata proof)
        external
        nonReentrant
        onlyInitialized
    {
        uint256 j = _slotIndex(chainId);
        // After the snapshot exit, the vault's paid totals include the holders' claims, which this index never sent.
        if (_exitedAt[chainId] != 0) revert ChainExited(chainId);
        if (record.balances.length != record.tokens.length || record.paid.length != record.tokens.length) {
            revert LengthMismatch();
        }
        bytes32 slot = keccak256(abi.encode(address(this), VAULT_INDEX_DIGEST_SLOT));
        // Paid totals only grow, and so does what this index sent: a proof from any height will do.
        bytes32 proven = _provenSlot(j, slot, 0, true, proof);
        bytes32 digest = keccak256(
            abi.encode(
                INDEX_DIGEST_DOMAIN,
                chainId,
                _chains[j].vault,
                address(this),
                record.tokens,
                record.balances,
                record.paid
            )
        );
        if (proven != digest) revert DigestMismatch(chainId, proven, digest);

        bool exceeded = false;
        uint256 n = _components.length;
        for (uint256 i = 0; i < n; ++i) {
            if (_slotOf[i] != j + 1) continue;
            address token = _components[i].token;
            uint256 paid = _totalOf(i, record.tokens, record.paid);
            uint256 sent = _sentOut[token];
            if (paid <= sent) continue;
            exceeded = true;
            // The calls before this are views: the factory's registry and a state verifier.
            // forge-lint: disable-next-line(reentrancy-events)
            emit OutflowDisproved(chainId, token, paid, sent);
        }
        if (!exceeded) revert NotAContradiction(chainId);
        // Payouts Ethereum never sent mean both Ethereum-side proofs are broken: the vault stops paying too.
        _freezeOnEvidence(chainId, true);
    }

    /// @inheritdoc IHybridHubExtension
    function reportForgedDeposit(uint256 orderId, uint256 chainId, ChainProof calldata proof)
        external
        nonReentrant
        onlyInitialized
    {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Claimed);
        uint256 j = _slotIndex(chainId);
        // After the snapshot exit, the vault resolves every intake itself, and the chain is frozen for good anyway.
        if (_exitedAt[chainId] != 0) revert ChainExited(chainId);
        uint256 intakeId = _intakeIdOf(orderId, o.deadline);
        bytes32 recorded = _digests[orderId][j];
        bytes32 open = _intakeDigest(j, intakeId, INTAKE_OPEN, proof.tokens, proof.totals);
        if (open != recorded) revert DigestMismatch(chainId, open, recorded);
        // After its deadline an intake's deposits are final, and a claimed order's is only ever settled, so it can be
        // open or settled with those deposits, and nothing else.
        bytes32 proven = _provenIntake(j, intakeId, o.deadline, true, proof.proof);
        if (proven == recorded || proven == _intakeDigest(j, intakeId, INTAKE_SETTLED, proof.tokens, proof.totals)) {
            revert NotAContradiction(chainId);
        }
        // The calls before this are views: the factory's registry and a state verifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit DepositDisproved(orderId, chainId, proven);
        _freezeOnEvidence(chainId, false);
    }

    // ---------------------------------------------------------------------
    // The snapshot exit (design 6.9, layer 4)
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubExtension
    function setRecoveryAddress(uint256 chainId, bytes32 recipient) external onlyInitialized {
        _checkChain(chainId);
        _recovery[msg.sender][chainId] = recipient;
        // No external call precedes this; the lint reads the initializer's internal read as one.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RecoveryAddressSet(msg.sender, chainId, recipient);
    }

    /// @inheritdoc IHybridHubExtension
    function recordExit(uint256 chainId, bytes calldata proof) external nonReentrant onlyInitialized {
        uint256 j = _slotIndex(chainId);
        if (_exitedAt[chainId] != 0) revert ChainExited(chainId);
        // The vault's own state shows its snapshot: this direction of proof still works when Ethereum's does not.
        bytes32 root = _provenSlot(j, bytes32(VAULT_SNAPSHOT_ROOT_SLOT), 0, false, proof);
        if (root == bytes32(0)) revert NotAContradiction(chainId);
        _exitedAt[chainId] = block.timestamp;
        // The call before this is a view of a state verifier.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ChainExitRecorded(chainId, root);
    }

    /// @inheritdoc IHybridHubExtension
    function failHeldOrder(uint256 orderId, uint256 chainId) external nonReentrant onlyInitialized {
        StoredOrder storage o = _openOrder(orderId, OrderStatus.Locked);
        _checkChain(chainId);
        if (_exitedAt[chainId] == 0) {
            // Short of an exit, only its minter may give up an order a freeze holds, once the freeze has been over for
            // HELD_ORDER_GRACE with nobody re-confirming it: the proof that could may never come (HUB-3).
            IHybridIndexFactory.Freeze memory f = _freeze(chainId);
            if (msg.sender != o.minter || f.start < o.settledAt) revert ChainNotExited(chainId);
            uint256 openAt = f.until + HELD_ORDER_GRACE;
            if (block.timestamp < openAt) revert NotYet(openAt);
        }
        _lockedShares -= o.shares;
        // Its chain's vault settles or refunds the order's intake from its snapshot, where it was never settled.
        _fail(orderId, o);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubExtension
    function recoveryAddress(address holder, uint256 chainId) external view returns (bytes32) {
        return _recovery[holder][chainId];
    }

    /// @inheritdoc IHybridHubExtension
    function intakeSettled(uint256 intakeId) external view returns (bool) {
        return _settledIntakes[intakeId];
    }

    /// @inheritdoc IHybridHubExtension
    function exitedAt(uint256 chainId) external view returns (uint256) {
        return _exitedAt[chainId];
    }

    /// @inheritdoc IHybridHubExtension
    function messageSent(bytes32 id) external view returns (bool) {
        return _sentMessages[id];
    }

    /// @inheritdoc IHybridHubExtension
    function resendMessage(bytes calldata payload) external {
        bytes32 id = keccak256(payload);
        if (!_sentMessages[id]) revert NotSent(id);
        emit VaultMessages.VaultMessage(id, payload);
    }

    /// @inheritdoc IHybridHubExtension
    function sentOut(address token) external view returns (uint256) {
        return _sentOut[token];
    }

    // ---------------------------------------------------------------------
    // v5 views (DRAFT)
    // ---------------------------------------------------------------------

    /// @inheritdoc IHybridHubExtension
    function componentTerms()
        external
        view
        returns (uint256[] memory weights, bytes32[] memory priceIds, uint8[] memory decimals)
    {
        uint256 n = _terms.length;
        weights = new uint256[](n);
        priceIds = new bytes32[](n);
        decimals = new uint8[](n);
        for (uint256 i = 0; i < n; ++i) {
            (weights[i], priceIds[i], decimals[i]) = (_terms[i].weight, _terms[i].priceId, _terms[i].decimals);
        }
    }

    /// @inheritdoc IHybridHubExtension
    function previewRebalance(PythStructs.Price[] calldata prices)
        external
        view
        returns (uint256 mu, uint256[] memory units, uint256[] memory amountsOut, uint256[] memory amountsIn)
    {
        uint256 n = _components.length;
        if (prices.length != n) revert LengthMismatch();
        uint256 eta = _pending.eta;
        if (eta == 0) revert NoPendingRebalance();
        if (block.timestamp < eta) revert RebalanceNotReady(eta);
        if (block.timestamp > eta + AUCTION_LENGTH) revert RebalanceExpired(eta + AUCTION_LENGTH);
        uint256 keepMask = _keepMask;
        uint256[] memory read = new uint256[](n);
        uint256[] memory current = new uint256[](n);
        uint256[] memory weights = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            current[i] = _components[i].units;
            weights[i] = _terms[i].weight;
            if ((keepMask & (1 << i)) == 0) {
                read[i] = WeightedPricing.price(prices[i], _terms[i].decimals, _components[i].token);
            }
        }
        return WeightedPricing.settle(
            WeightedPricing.Basket({
                current: current,
                prices: read,
                weights: weights,
                keepMask: keepMask,
                elapsed: block.timestamp - eta,
                duration: AUCTION_LENGTH,
                supply: _shareSupply()
            })
        );
    }
}
