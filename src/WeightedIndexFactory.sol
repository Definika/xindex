// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWeightedIndexFactory} from "./interfaces/IWeightedIndexFactory.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {WeightedHub} from "./WeightedHub.sol";

/// @title WeightedIndexFactory
/// @notice Permissionless creation of indexes whose creators choose each component's weight, from a curated whitelist
///         whose tokens each carry a Pyth price id. See {IWeightedIndexFactory}.
/// @dev Roles. The owner proposes listings and guardian changes, delists, and hands over ownership. A listing takes
///      effect only LISTING_DELAY after it is proposed and a guardian change only GUARDIAN_DELAY after, and either must
///      be executed within PROPOSAL_WINDOW of becoming ready or proposed again. The guardian can cancel pending listings
///      and delist, and keeps that power for the whole time its replacement is pending; it can also cancel its own
///      removal, though the owner can still replace it with another address. Owner and guardian can also cancel a
///      pending rebalance on any index and start one that leaves chosen components untouched. Neither role can pause,
///      upgrade, set units, weights or prices, or touch funds held by any index, and ownership cannot be renounced.
///
///      Prices. The factory never reads one. A listing records the token's Pyth price id and its decimals, and an index
///      copies both at creation, so no later listing, relisting or delisting can repoint an existing index's prices:
///      its executors bring Pyth's signed updates and it checks them itself.
///
///      Addresses. Each index is deployed with CREATE2 from a salt over the creator, the name, the symbol and every
///      component's token, starting units, weight, price id and decimals, so an address can never hold a different
///      basket, even after a re-org, and an app can show the address before the transaction confirms.
///
///      Whitelist policy (enforced socially, not on-chain): standard ERC-20s only. No fee-on-transfer, rebasing or
///      callback (ERC-777 style) tokens; 6-18 decimals; a Pyth feed checked to name the same asset. Components that an
///      issuer can pause or blacklist, such as WBTC, must be labelled in the app; while one is frozen, holders can still
///      take the other components out with `WeightedHub.redeemSkipping`.
contract WeightedIndexFactory is IWeightedIndexFactory, Ownable2Step, ReentrancyGuard {
    uint256 public constant MIN_COMPONENTS = 2;
    uint256 public constant MAX_COMPONENTS = 100;
    uint256 public constant TOTAL_WEIGHT = 1e4;
    uint256 public constant MIN_RAW_UNITS = 1e4;
    uint256 public constant MAX_UNITS = type(uint96).max >> 10;
    uint256 public constant LISTING_DELAY = 2 days;
    uint256 public constant GUARDIAN_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;
    address public immutable IMPLEMENTATION;
    address public immutable PYTH;

    uint8 private constant MAX_DECIMALS = 18;

    /// @dev A token's Pyth price id and its decimals, as an index copies them.
    struct Terms {
        bytes32 priceId;
        uint8 decimals;
    }

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingGuardianEta;

    mapping(address => bool) public isWhitelisted;
    address[] private _whitelist;
    /// @dev position in `_whitelist` + 1 (0 = absent), for O(1) removal.
    mapping(address => uint256) private _whitelistPos;
    mapping(address token => Terms) private _terms;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address token => uint256 eta) public listingEta;
    mapping(address token => Terms) private _pendingTerms;

    mapping(address => bool) public isIndex;
    mapping(address => address) public creatorOf;
    address[] public allIndexes;

    modifier onlyOwnerOrGuardian() {
        _checkOwnerOrGuardian();
        _;
    }

    /// @param pyth The Pyth contract every index reads its prices from; it is fixed in the implementation.
    // A zero guardian is allowed on purpose: it means the factory starts without one.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address initialOwner, address initialGuardian, address pyth) Ownable(initialOwner) {
        if (pyth.code.length == 0) revert NotAContract(pyth);
        // A zero guardian is allowed on purpose, as above.
        // aderyn-fp-next-line(state-no-address-check)
        guardian = initialGuardian;
        emit GuardianSet(address(0), initialGuardian);
        PYTH = pyth;
        IMPLEMENTATION = address(new WeightedHub(pyth));
    }

    // ---------------------------------------------------------------------
    // Index creation
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function createIndex(string calldata name, string calldata symbol, ComponentSpec[] calldata components)
        external
        nonReentrant
        returns (address index)
    {
        // The guard is defensive: nothing here runs untrusted code, since validation reads storage and `initialize` of
        // an EIP-1167 clone of our own implementation makes no external call.
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        _validateComponents(components);
        IWeightedHub.ComponentInit[] memory inits = _inits(components);

        bytes32 salt = _salt(msg.sender, name, symbol, inits);
        address predicted = Clones.predictDeterministicAddress(IMPLEMENTATION, salt);
        if (predicted.code.length != 0) revert IndexAlreadyExists(predicted);

        // Effects before interaction: register the clone, then initialize it in the same tx.
        index = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        isIndex[index] = true;
        creatorOf[index] = msg.sender;
        allIndexes.push(index);
        // Only the clone's CREATE2, which runs no code, precedes this.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IndexCreated(index, msg.sender, name, symbol, inits);

        IWeightedHub(index).initialize(name, symbol, inits);
    }

    /// @inheritdoc IWeightedIndexFactory
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components
    ) external view returns (address) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, _salt(creator, name, symbol, _inits(components)));
    }

    /// @inheritdoc IWeightedIndexFactory
    function isOwnerOrGuardian(address account) public view returns (bool) {
        return account == owner() || (account == guardian && account != address(0));
    }

    function _checkOwnerOrGuardian() internal view {
        if (!isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
    }

    function _validateComponents(ComponentSpec[] calldata components) private view {
        uint256 n = components.length;
        if (n < MIN_COMPONENTS || n > MAX_COMPONENTS) revert InvalidComponentCount(n);

        uint256 total = 0;
        bytes32[] memory priceIds = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            ComponentSpec calldata c = components[i];
            address token = c.token;
            if (!isWhitelisted[token]) revert TokenNotWhitelisted(token);
            if (c.units < MIN_RAW_UNITS || c.units > MAX_UNITS) revert UnitsOutOfRange(token, c.units);
            if (c.weight == 0 || c.weight > TOTAL_WEIGHT) revert InvalidWeights();
            total += c.weight;
            bytes32 priceId = _terms[token].priceId;
            priceIds[i] = priceId;
            for (uint256 j = 0; j < i; ++j) {
                if (components[j].token == token) revert DuplicateToken(token);
                // Pyth fills only the first of two equal ids, so two components on one feed, such as two wrappers of
                // one coin, would make every fill revert (V5-M1).
                if (priceIds[j] == priceId) revert DuplicatePriceId(token);
            }
        }
        if (total != TOTAL_WEIGHT) revert InvalidWeights();
    }

    /// @dev The components as the index's initializer takes them, with each token's price id and decimals in force.
    function _inits(ComponentSpec[] calldata components)
        private
        view
        returns (IWeightedHub.ComponentInit[] memory inits)
    {
        uint256 n = components.length;
        inits = new IWeightedHub.ComponentInit[](n);
        for (uint256 i = 0; i < n; ++i) {
            ComponentSpec calldata c = components[i];
            Terms memory terms = _terms[c.token];
            inits[i] = IWeightedHub.ComponentInit({
                token: c.token, units: c.units, weight: c.weight, priceId: terms.priceId, decimals: terms.decimals
            });
        }
    }

    /// @dev Over the creator, the name, the symbol and every component's token, units, weight, price id and decimals.
    function _salt(
        address creator,
        string calldata name,
        string calldata symbol,
        IWeightedHub.ComponentInit[] memory inits
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(creator, keccak256(bytes(name)), keccak256(bytes(symbol)), keccak256(abi.encode(inits)))
        );
    }

    // ---------------------------------------------------------------------
    // Whitelist
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function proposeListing(address token, bytes32 priceId) external onlyOwner {
        if (token.code.length == 0) revert NotAContract(token);
        if (priceId == bytes32(0)) revert InvalidPriceId(token);
        if (isWhitelisted[token]) revert AlreadyListed(token);
        uint256 pending = listingEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ListingPending(token, pending);
        // Read once, here, and never again: every price of this token is scaled by this figure, so no index ever calls
        // the token to price it (RT-01). The owner's proposal and the delay put it in public view before it counts.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals > MAX_DECIMALS) revert InvalidDecimals(token, decimals);

        uint256 eta = block.timestamp + LISTING_DELAY;
        listingEta[token] = eta;
        _pendingTerms[token] = Terms({priceId: priceId, decimals: decimals});
        emit ListingProposed(token, eta, priceId, decimals);
    }

    /// @inheritdoc IWeightedIndexFactory
    function cancelListing(address token) external onlyOwnerOrGuardian {
        if (listingEta[token] == 0) revert NoPendingListing(token);
        delete listingEta[token];
        delete _pendingTerms[token];
        emit ListingCancelled(token);
    }

    /// @inheritdoc IWeightedIndexFactory
    function executeListing(address token) external {
        uint256 eta = listingEta[token];
        if (eta == 0) revert NoPendingListing(token);
        if (block.timestamp < eta) revert ListingNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert ListingExpired(token, eta + PROPOSAL_WINDOW);

        Terms memory terms = _pendingTerms[token];
        delete listingEta[token];
        delete _pendingTerms[token];
        _terms[token] = terms;
        emit TokenTermsSet(token, terms.priceId, terms.decimals);

        // A proposal is refused for a whitelisted token (AlreadyListed), and nothing whitelists a token but this
        // function, which clears the proposal, so the token is never already whitelisted here.
        isWhitelisted[token] = true;
        _whitelist.push(token);
        _whitelistPos[token] = _whitelist.length;
        emit TokenWhitelisted(token, true);
    }

    /// @inheritdoc IWeightedIndexFactory
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
    // Guardian
    // ---------------------------------------------------------------------

    // Zero is allowed on purpose: once executed, it removes the guardian role.
    // forge-lint: disable-next-item(missing-zero-check)
    /// @inheritdoc IWeightedIndexFactory
    function proposeGuardian(address newGuardian) external onlyOwner {
        if (pendingGuardianEta != 0) emit GuardianChangeCancelled(pendingGuardian);
        uint256 eta = block.timestamp + GUARDIAN_DELAY;
        // Zero is allowed on purpose, as above.
        // aderyn-fp-next-line(state-no-address-check)
        pendingGuardian = newGuardian;
        pendingGuardianEta = eta;
        emit GuardianProposed(newGuardian, eta);
    }

    /// @inheritdoc IWeightedIndexFactory
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

    /// @inheritdoc IWeightedIndexFactory
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

    /// @notice Disabled: without an owner, the whitelist could never change again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function whitelistedTokens() external view returns (address[] memory) {
        return _whitelist;
    }

    /// @inheritdoc IWeightedIndexFactory
    function priceIdOf(address token) external view returns (bytes32) {
        return _terms[token].priceId;
    }

    /// @inheritdoc IWeightedIndexFactory
    function decimalsOf(address token) external view returns (uint8) {
        return _terms[token].decimals;
    }

    /// @inheritdoc IWeightedIndexFactory
    function pendingTerms(address token) external view returns (bytes32 priceId, uint8 decimals) {
        Terms memory terms = _pendingTerms[token];
        return (terms.priceId, terms.decimals);
    }

    /// @inheritdoc IWeightedIndexFactory
    function listingPending(address token) external view returns (bool) {
        uint256 eta = listingEta[token];
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    /// @inheritdoc IWeightedIndexFactory
    function guardianChangePending() external view returns (bool) {
        uint256 eta = pendingGuardianEta;
        return eta != 0 && block.timestamp <= eta + PROPOSAL_WINDOW;
    }

    /// @inheritdoc IWeightedIndexFactory
    function allIndexesLength() external view returns (uint256) {
        return allIndexes.length;
    }
}
