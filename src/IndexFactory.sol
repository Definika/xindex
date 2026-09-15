// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {IndexToken} from "./IndexToken.sol";

/// @title IndexFactory
/// @notice Permissionless index creation with a curated component whitelist. See {IIndexFactory}.
/// @dev Roles. The owner proposes listings and guardian changes, delists, and hands over ownership. A listing takes
///      effect only LISTING_DELAY after it is proposed and a guardian change only GUARDIAN_DELAY after, and either
///      proposal must be executed within PROPOSAL_WINDOW of becoming ready or proposed again. The guardian can
///      cancel pending listings and delist, and keeps that power for the whole time its replacement is pending.
///      Neither role can pause, upgrade, or touch funds held by any index, and ownership cannot be renounced.
///
///      Addresses. Each index is deployed with CREATE2 from a salt over the creator and the full composition,
///      so an address can never hold a different basket, even after a re-org, and an app can show the address
///      before the transaction confirms.
///
///      Whitelist policy (enforced socially, not on-chain): standard ERC-20s only. No fee-on-transfer,
///      rebasing or callback (ERC-777 style) tokens; 6-18 decimals. Components that an issuer can pause or
///      blacklist, such as WBTC, must be labelled in the app; while one is frozen, holders can still take the
///      other components out with `IndexToken.redeemSkipping`.
contract IndexFactory is IIndexFactory, Ownable2Step, ReentrancyGuard {
    uint256 public constant MAX_COMPONENTS = 20;
    uint256 public constant LISTING_DELAY = 2 days;
    uint256 public constant GUARDIAN_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;
    address public immutable IMPLEMENTATION;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingGuardianEta;

    mapping(address => bool) public isWhitelisted;
    address[] private _whitelist;
    /// @dev position in `_whitelist` + 1 (0 = absent), for O(1) removal.
    mapping(address => uint256) private _whitelistPos;
    mapping(address => uint256) public listingEta;

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
        IMPLEMENTATION = address(new IndexToken());
    }

    // ---------------------------------------------------------------------
    // Index creation
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexFactory
    function createIndex(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units
    ) external nonReentrant returns (address index) {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        _validateComponents(tokens, units);

        bytes32 salt = _salt(msg.sender, name, symbol, tokens, units);
        address predicted = Clones.predictDeterministicAddress(IMPLEMENTATION, salt);
        if (predicted.code.length != 0) revert IndexAlreadyExists(predicted);

        // Effects before interaction: register the clone, then initialize it in the same tx.
        index = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        isIndex[index] = true;
        creatorOf[index] = msg.sender;
        allIndexes.push(index);
        emit IndexCreated(index, msg.sender, name, symbol, tokens, units);

        IIndexToken(index).initialize(name, symbol, tokens, units);
    }

    /// @inheritdoc IIndexFactory
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units
    ) external view returns (address) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, _salt(creator, name, symbol, tokens, units));
    }

    function _checkOwnerOrGuardian() private view {
        if (msg.sender != owner() && msg.sender != guardian) revert Unauthorized(msg.sender);
    }

    function _validateComponents(address[] calldata tokens, uint256[] calldata units) private view {
        uint256 n = tokens.length;
        if (n == 0 || n > MAX_COMPONENTS) revert InvalidComponentCount(n);
        if (n != units.length) revert LengthMismatch();

        for (uint256 i = 0; i < n; ++i) {
            address token = tokens[i];
            if (!isWhitelisted[token]) revert TokenNotWhitelisted(token);
            if (units[i] == 0 || units[i] > type(uint96).max) revert InvalidUnits(token, units[i]);
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
        uint256[] calldata units
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
    function proposeListing(address token) external onlyOwner {
        if (token.code.length == 0) revert NotAContract(token);
        if (isWhitelisted[token]) revert AlreadyWhitelisted(token);
        uint256 pending = listingEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ListingPending(token, pending);

        uint256 eta = block.timestamp + LISTING_DELAY;
        listingEta[token] = eta;
        emit ListingProposed(token, eta);
    }

    /// @inheritdoc IIndexFactory
    function cancelListing(address token) external onlyOwnerOrGuardian {
        if (listingEta[token] == 0) revert NoPendingListing(token);
        delete listingEta[token];
        emit ListingCancelled(token);
    }

    /// @inheritdoc IIndexFactory
    function executeListing(address token) external {
        uint256 eta = listingEta[token];
        if (eta == 0) revert NoPendingListing(token);
        if (block.timestamp < eta) revert ListingNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert ListingExpired(token, eta + PROPOSAL_WINDOW);

        delete listingEta[token];
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
    // Guardian
    // ---------------------------------------------------------------------

    // Zero is allowed on purpose: once executed, it removes the guardian role.
    // forge-lint: disable-next-item(missing-zero-check)
    /// @inheritdoc IIndexFactory
    function proposeGuardian(address newGuardian) external onlyOwner {
        uint256 eta = block.timestamp + GUARDIAN_DELAY;
        pendingGuardian = newGuardian;
        pendingGuardianEta = eta;
        emit GuardianProposed(newGuardian, eta);
    }

    /// @inheritdoc IIndexFactory
    function cancelGuardianChange() external onlyOwner {
        if (pendingGuardianEta == 0) revert NoPendingGuardianChange();
        address cancelled = pendingGuardian;
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

    /// @notice Disabled: without an owner, listings could never change again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function whitelistedTokens() external view returns (address[] memory) {
        return _whitelist;
    }

    function allIndexesLength() external view returns (uint256) {
        return allIndexes.length;
    }
}
