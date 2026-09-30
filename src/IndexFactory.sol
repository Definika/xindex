// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexHub} from "./interfaces/IIndexHub.sol";
import {IndexHub} from "./IndexHub.sol";

/// @title IndexFactory
/// @notice Permissionless index creation with a curated component whitelist and timelocked reference supplies. See
///         {IIndexFactory}.
/// @dev Roles. The owner proposes listings, supply batches and guardian changes, delists, and hands over ownership. A
///      listing or supply batch takes effect only LISTING_DELAY after it is proposed and a guardian change only
///      GUARDIAN_DELAY after, and either must be executed within PROPOSAL_WINDOW of becoming ready or proposed again.
///      The guardian can cancel pending listings and supply batches and delist, and keeps that power for the whole time
///      its replacement is pending; it can also cancel its own removal, so the factory is never left without a
///      guardian unless the guardian agrees, though the owner can still replace it with another address. Owner and
///      guardian can also cancel a pending rebalance on any index and start one that leaves chosen components
///      untouched. Neither role can pause, upgrade, set units or touch funds held by any index, and ownership cannot be
///      renounced.
///
///      Reference supplies. Each listed token carries the supply of what it represents, which every index holding it
///      follows: units are proportional to reference supplies, so a market-cap index trades only when a supply
///      changes, never on a price move. Nothing reads a supply live, so no transaction can move one (CR-M01). After the
///      first listing a supply moves only in a batch, by at most MAX_SUPPLY_STEP, and each index clamps every rebalance
///      to the same step. Delisting keeps the supply, because existing indexes still rebalance with it.
///
///      Addresses. Each index is deployed with CREATE2 from a salt over the creator, the name, the symbol, the
///      constituents and the starting units computed from `k`, so an address can never hold a different basket, even
///      after a re-org, and an app can show the address before the transaction confirms.
///
///      Whitelist policy (enforced socially, not on-chain): standard ERC-20s only. No fee-on-transfer, rebasing or
///      callback (ERC-777 style) tokens; 6-18 decimals; a dated reference supply. Components that an issuer can pause or
///      blacklist, such as WBTC, must be labelled in the app; while one is frozen, holders can still take the other
///      components out with `IndexHub.redeemSkipping`.
contract IndexFactory is IIndexFactory, Ownable2Step, ReentrancyGuard {
    uint256 public constant MAX_COMPONENTS = 100;
    uint256 public constant MAX_BATCH = 256;
    uint256 public constant MAX_SUPPLY_STEP = 0.005e18;
    uint256 public constant MAX_SUPPLY = type(uint128).max;
    uint256 public constant MIN_RAW_UNITS = 10_000;
    uint256 public constant MAX_UNITS = type(uint96).max >> 10;
    uint256 public constant K_SCALE = 1e36;
    uint256 public constant LISTING_DELAY = 2 days;
    uint256 public constant GUARDIAN_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;
    address public immutable IMPLEMENTATION;

    uint256 private constant WAD = 1e18;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingGuardianEta;

    mapping(address => bool) public isWhitelisted;
    address[] private _whitelist;
    /// @dev position in `_whitelist` + 1 (0 = absent), for O(1) removal.
    mapping(address => uint256) private _whitelistPos;
    /// @inheritdoc IIndexFactory
    mapping(address token => uint256 supply) public referenceSupply;
    mapping(address => uint256) public listingEta;
    /// @inheritdoc IIndexFactory
    mapping(address token => uint256 supply) public pendingReferenceSupply;

    /// @inheritdoc IIndexFactory
    uint256 public supplyBatchCount;
    uint256 private _batchEta;
    address[] private _batchTokens;
    uint256[] private _batchSupplies;
    /// @dev The id of the last batch that named the token; it is in the live batch when that is the current id and the
    ///      batch is live.
    mapping(address token => uint256 batchId) private _batchOf;

    mapping(address => bool) public isIndex;
    mapping(address => address) public creatorOf;
    address[] public allIndexes;

    modifier onlyOwnerOrGuardian() {
        _checkOwnerOrGuardian();
        _;
    }

    // A zero guardian is allowed on purpose: it means the factory starts without one.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address initialOwner, address initialGuardian) Ownable(initialOwner) {
        guardian = initialGuardian;
        emit GuardianSet(address(0), initialGuardian);
        IMPLEMENTATION = address(new IndexHub());
    }

    // ---------------------------------------------------------------------
    // Index creation
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexFactory
    function createIndex(string calldata name, string calldata symbol, address[] calldata tokens, uint256 k)
        external
        nonReentrant
        returns (address index)
    {
        // The guard is defensive: nothing here runs untrusted code, since validation reads storage and `initialize` of
        // an EIP-1167 clone of our own implementation makes no external call (RT-18).
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        uint256[] memory units = _validateComponents(tokens, k);

        bytes32 salt = _salt(msg.sender, name, symbol, tokens, units);
        address predicted = Clones.predictDeterministicAddress(IMPLEMENTATION, salt);
        if (predicted.code.length != 0) revert IndexAlreadyExists(predicted);

        // Effects before interaction: register the clone, then initialize it in the same tx.
        index = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        isIndex[index] = true;
        creatorOf[index] = msg.sender;
        allIndexes.push(index);
        // The lint reads `Math.mulDiv` in `_units`, an internal library call, as an external one; only the clone's
        // CREATE2, which runs no code, precedes this.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IndexCreated(index, msg.sender, name, symbol, tokens, units);

        IIndexHub(index).initialize(name, symbol, tokens, units);
    }

    /// @inheritdoc IIndexFactory
    function previewUnits(address[] calldata tokens, uint256 k) external view returns (uint256[] memory units) {
        return _units(tokens, k);
    }

    function _units(address[] calldata tokens, uint256 k) private view returns (uint256[] memory units) {
        uint256 n = tokens.length;
        units = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            units[i] = Math.mulDiv(k, referenceSupply[tokens[i]], K_SCALE);
        }
    }

    /// @inheritdoc IIndexFactory
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256 k
    ) external view returns (address) {
        return Clones.predictDeterministicAddress(
            IMPLEMENTATION, _salt(creator, name, symbol, tokens, _units(tokens, k))
        );
    }

    /// @inheritdoc IIndexFactory
    function isOwnerOrGuardian(address account) public view returns (bool) {
        return account == owner() || (account == guardian && account != address(0));
    }

    function _checkOwnerOrGuardian() private view {
        if (!isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
    }

    function _validateComponents(address[] calldata tokens, uint256 k) private view returns (uint256[] memory units) {
        uint256 n = tokens.length;
        if (n == 0 || n > MAX_COMPONENTS) revert InvalidComponentCount(n);

        units = _units(tokens, k);
        for (uint256 i = 0; i < n; ++i) {
            address token = tokens[i];
            if (!isWhitelisted[token]) revert TokenNotWhitelisted(token);
            if (units[i] < MIN_RAW_UNITS || units[i] > MAX_UNITS) revert UnitsOutOfRange(token, units[i]);
            for (uint256 j = 0; j < i; ++j) {
                if (tokens[j] == token) revert DuplicateToken(token);
            }
        }
    }

    function _salt(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] memory units
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                creator,
                keccak256(bytes(name)),
                keccak256(bytes(symbol)),
                keccak256(abi.encode(tokens)),
                keccak256(abi.encode(units))
            )
        );
    }

    // ---------------------------------------------------------------------
    // Whitelist
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexFactory
    function proposeListing(address token, uint256 supply) external onlyOwner {
        if (token.code.length == 0) revert NotAContract(token);
        if (isWhitelisted[token]) revert AlreadyListed(token);
        uint256 pending = listingEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ListingPending(token, pending);
        if (_batchOf[token] == supplyBatchCount && _batchLive()) revert TokenInBatch(token);
        _checkSupply(token, supply);
        // A first listing has nothing to compare against. A relisting does: the indexes still holding the token
        // follow its supply, so it moves no further than a batch could move it (DA-18, CR-L03).
        uint256 inForce = referenceSupply[token];
        if (inForce != 0) _checkStep(token, inForce, supply);

        uint256 eta = block.timestamp + LISTING_DELAY;
        listingEta[token] = eta;
        pendingReferenceSupply[token] = supply;
        emit ListingProposed(token, eta, supply);
    }

    /// @inheritdoc IIndexFactory
    function cancelListing(address token) external onlyOwnerOrGuardian {
        if (listingEta[token] == 0) revert NoPendingListing(token);
        _dropListing(token);
    }

    function _dropListing(address token) private {
        delete listingEta[token];
        delete pendingReferenceSupply[token];
        emit ListingCancelled(token);
    }

    /// @inheritdoc IIndexFactory
    function executeListing(address token) external {
        uint256 eta = listingEta[token];
        if (eta == 0) revert NoPendingListing(token);
        if (block.timestamp < eta) revert ListingNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert ListingExpired(token, eta + PROPOSAL_WINDOW);

        uint256 supply = pendingReferenceSupply[token];
        delete listingEta[token];
        delete pendingReferenceSupply[token];
        _setSupply(token, supply);

        // A proposal is refused for a whitelisted token, and delist drops a pending one, so the token is never already
        // whitelisted here.
        isWhitelisted[token] = true;
        _whitelist.push(token);
        _whitelistPos[token] = _whitelist.length;
        emit TokenWhitelisted(token, true);
    }

    /// @inheritdoc IIndexFactory
    function delist(address token) external onlyOwnerOrGuardian {
        if (!isWhitelisted[token]) revert NotWhitelisted(token);

        isWhitelisted[token] = false;
        uint256 pos = _whitelistPos[token] - 1;
        uint256 last = _whitelist.length - 1;
        if (pos != last) {
            address moved = _whitelist[last];
            _whitelist[pos] = moved;
            _whitelistPos[moved] = pos + 1;
        }
        _whitelist.pop();
        delete _whitelistPos[token];
        emit TokenWhitelisted(token, false);
    }

    // ---------------------------------------------------------------------
    // Reference supplies
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexFactory
    function proposeSupplies(address[] calldata tokens, uint256[] calldata supplies) external onlyOwner {
        uint256 n = tokens.length;
        if (n != supplies.length) revert LengthMismatch();
        if (n == 0 || n > MAX_BATCH) revert InvalidBatch(address(0));
        if (_batchLive()) revert SuppliesPending(_batchEta);

        uint256 id = ++supplyBatchCount;
        address previous = address(0);
        for (uint256 i = 0; i < n; ++i) {
            address token = tokens[i];
            // Strictly ascending, so no token appears twice and the batch reads the same whichever way it is listed.
            if (token <= previous) revert InvalidBatch(token);
            previous = token;
            uint256 inForce = referenceSupply[token];
            if (inForce == 0) revert NotConfigured(token);
            uint256 listing = listingEta[token];
            if (listing != 0 && block.timestamp <= listing + PROPOSAL_WINDOW) revert ListingPending(token, listing);
            _checkSupply(token, supplies[i]);
            _checkStep(token, inForce, supplies[i]);
            _batchOf[token] = id;
        }

        uint256 eta = block.timestamp + LISTING_DELAY;
        _batchEta = eta;
        _batchTokens = tokens;
        _batchSupplies = supplies;
        emit SuppliesProposed(id, eta, tokens, supplies);
    }

    /// @inheritdoc IIndexFactory
    function cancelSupplies() external onlyOwnerOrGuardian {
        if (_batchEta == 0) revert NoPendingSupplies();
        _clearBatch();
        emit SuppliesCancelled(supplyBatchCount);
    }

    /// @inheritdoc IIndexFactory
    function executeSupplies() external {
        uint256 eta = _batchEta;
        if (eta == 0) revert NoPendingSupplies();
        if (block.timestamp < eta) revert SuppliesNotReady(eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert SuppliesExpired(eta + PROPOSAL_WINDOW);

        // The batch was checked against the supplies in force when it was proposed, and nothing else can change those
        // while it is live: a listing is refused for a token in it, and it is refused for a token with a live listing.
        uint256 n = _batchTokens.length;
        for (uint256 i = 0; i < n; ++i) {
            _setSupply(_batchTokens[i], _batchSupplies[i]);
        }
        _clearBatch();
        emit SuppliesExecuted(supplyBatchCount);
    }

    function _batchLive() private view returns (bool) {
        uint256 eta = _batchEta;
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    function _clearBatch() private {
        delete _batchEta;
        delete _batchTokens;
        delete _batchSupplies;
    }

    function _checkSupply(address token, uint256 supply) private pure {
        if (supply == 0 || supply > MAX_SUPPLY) revert SupplyOutOfRange(token, supply);
    }

    /// @dev At most MAX_SUPPLY_STEP of the supply in force either way, the allowance rounded down. A supply is at most
    ///      MAX_SUPPLY, so the product cannot overflow.
    function _checkStep(address token, uint256 inForce, uint256 proposed) private pure {
        uint256 allowance = inForce * MAX_SUPPLY_STEP / WAD;
        if (proposed > inForce + allowance || proposed + allowance < inForce) {
            revert SupplyStepTooLarge(token, inForce, proposed);
        }
    }

    function _setSupply(address token, uint256 supply) private {
        uint256 previous = referenceSupply[token];
        referenceSupply[token] = supply;
        emit ReferenceSupplySet(token, previous, supply);
    }

    // ---------------------------------------------------------------------
    // Guardian
    // ---------------------------------------------------------------------

    // Zero is allowed on purpose: once executed, it removes the guardian role.
    // forge-lint: disable-next-item(missing-zero-check)
    /// @inheritdoc IIndexFactory
    function proposeGuardian(address newGuardian) external onlyOwner {
        if (pendingGuardianEta != 0) emit GuardianChangeCancelled(pendingGuardian);
        uint256 eta = block.timestamp + GUARDIAN_DELAY;
        pendingGuardian = newGuardian;
        pendingGuardianEta = eta;
        emit GuardianProposed(newGuardian, eta);
    }

    /// @inheritdoc IIndexFactory
    function cancelGuardianChange() external {
        if (pendingGuardianEta == 0) revert NoPendingGuardianChange();
        address cancelled = pendingGuardian;
        // The owner can cancel any guardian change. The guardian can cancel only its own removal: the owner must stay
        // able to replace a guardian that turned hostile or lost its keys, but it cannot leave the factory without one
        // over the guardian's objection.
        if (msg.sender != owner() && !(cancelled == address(0) && msg.sender == guardian && msg.sender != address(0))) {
            revert Unauthorized(msg.sender);
        }
        delete pendingGuardian;
        delete pendingGuardianEta;
        emit GuardianChangeCancelled(cancelled);
    }

    /// @inheritdoc IIndexFactory
    function executeGuardianChange() external {
        uint256 eta = pendingGuardianEta;
        if (eta == 0) revert NoPendingGuardianChange();
        if (block.timestamp < eta) revert GuardianChangeNotReady(eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert GuardianChangeExpired(eta + PROPOSAL_WINDOW);

        address previous = guardian;
        address next = pendingGuardian;
        guardian = next;
        delete pendingGuardian;
        delete pendingGuardianEta;
        emit GuardianSet(previous, next);
    }

    /// @notice Disabled: without an owner, listings and reference supplies could never change again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function whitelistedTokens() external view returns (address[] memory) {
        return _whitelist;
    }

    /// @inheritdoc IIndexFactory
    function referenceSupplies(address[] calldata tokens) external view returns (uint256[] memory supplies) {
        uint256 n = tokens.length;
        supplies = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            supplies[i] = referenceSupply[tokens[i]];
        }
    }

    /// @inheritdoc IIndexFactory
    function pendingSupplies()
        external
        view
        returns (uint256 batchId, uint256 eta, address[] memory tokens, uint256[] memory supplies)
    {
        return (supplyBatchCount, _batchEta, _batchTokens, _batchSupplies);
    }

    /// @inheritdoc IIndexFactory
    function suppliesPending() external view returns (bool) {
        return _batchLive();
    }

    /// @inheritdoc IIndexFactory
    function guardianChangePending() external view returns (bool) {
        uint256 eta = pendingGuardianEta;
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    /// @inheritdoc IIndexFactory
    function listingPending(address token) external view returns (bool) {
        uint256 eta = listingEta[token];
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    function allIndexesLength() external view returns (uint256) {
        return allIndexes.length;
    }
}
