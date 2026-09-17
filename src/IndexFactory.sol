// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndexRule} from "./interfaces/IIndexRule.sol";
import {IIndexToken} from "./interfaces/IIndexToken.sol";
import {Methodology} from "./libraries/Methodology.sol";
import {IndexRule} from "./IndexRule.sol";
import {IndexToken} from "./IndexToken.sol";

/// @title IndexFactory
/// @notice Permissionless index creation with a curated component whitelist. See {IIndexFactory}.
/// @dev Roles. The owner proposes listings, token config changes and guardian changes, delists, and hands over
///      ownership. A listing or config change takes effect only LISTING_DELAY after it is proposed and a guardian change
///      only GUARDIAN_DELAY after, and either proposal must be executed within PROPOSAL_WINDOW of becoming ready or
///      proposed again. The guardian can cancel pending listings and delist, and keeps that power for the whole time its
///      replacement is pending; it can also cancel its own removal, so the factory is never left without a guardian
///      unless the guardian agrees, though the owner can still replace it with another address. Owner and guardian can also cancel a pending rebalance on any index and start one that
///      leaves chosen components untouched. Neither role can pause, upgrade, set units or prices, or touch funds held by
///      any index, and ownership cannot be renounced.
///
///      Token configs. Each listed token carries the Uniswap V3 WETH pool and the supply definition the rebalance rule
///      reads. A config shapes future rebalances of every index holding the token, so it changes only through the same
///      delayed, cancellable proposal as a listing. Delisting keeps it, because existing indexes still rebalance with it.
///
///      Addresses. Each index is deployed with CREATE2 from a salt over the creator, the name, the symbol, the
///      constituents, the starting units and the methodology, so an address can never hold a different basket or follow
///      a different rule, even after a re-org, and an app can show the address before the transaction confirms.
///
///      Whitelist policy (enforced socially, not on-chain): standard ERC-20s only. No fee-on-transfer, rebasing or
///      callback (ERC-777 style) tokens; 6-18 decimals; fixed-supply or governance-minted supply; a WETH pool with at least
///      200 observation slots. Components that an issuer can pause or blacklist, such as WBTC, must be labelled in the
///      app; while one is frozen, holders can still take the other components out with `IndexToken.redeemSkipping`.
contract IndexFactory is IIndexFactory, Ownable2Step, ReentrancyGuard {
    uint256 public constant MAX_COMPONENTS = 20;
    uint256 public constant MIN_CAPPED_COMPONENTS = Methodology.MIN_CAPPED_COMPONENTS;
    uint256 public constant LISTING_DELAY = 2 days;
    uint256 public constant GUARDIAN_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;
    address public immutable RULE;
    address public immutable IMPLEMENTATION;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingGuardianEta;

    mapping(address => bool) public isWhitelisted;
    address[] private _whitelist;
    /// @dev position in `_whitelist` + 1 (0 = absent), for O(1) removal.
    mapping(address => uint256) private _whitelistPos;
    mapping(address => uint256) public listingEta;
    mapping(address token => TokenConfig config) private _tokenConfig;
    mapping(address token => TokenConfig config) private _pendingConfig;
    /// @inheritdoc IIndexFactory
    mapping(address token => bool listing) public pendingIsListing;

    mapping(address => bool) public isIndex;
    mapping(address => address) public creatorOf;
    address[] public allIndexes;

    modifier onlyOwnerOrGuardian() {
        _checkOwnerOrGuardian();
        _;
    }

    // A zero guardian is allowed on purpose: it means the factory starts without one. The rule rejects zero market
    // addresses.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address initialOwner, address initialGuardian, address weth, address uniswapV3Factory, address usdc)
        Ownable(initialOwner)
    {
        guardian = initialGuardian;
        emit GuardianSet(address(0), initialGuardian);
        address rule = address(new IndexRule(weth, uniswapV3Factory, usdc));
        RULE = rule;
        IMPLEMENTATION = address(new IndexToken(rule));
    }

    // ---------------------------------------------------------------------
    // Index creation
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexFactory
    function createIndex(
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology
    ) external nonReentrant returns (address index) {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        _validateComponents(tokens, units);
        _validateMethodology(tokens.length, methodology);

        bytes32 salt = _salt(msg.sender, name, symbol, tokens, units, methodology);
        address predicted = Clones.predictDeterministicAddress(IMPLEMENTATION, salt);
        if (predicted.code.length != 0) revert IndexAlreadyExists(predicted);

        // Effects before interaction: register the clone, then initialize it in the same tx.
        index = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        isIndex[index] = true;
        creatorOf[index] = msg.sender;
        allIndexes.push(index);
        emit IndexCreated(index, msg.sender, name, symbol, tokens, units, methodology);

        IIndexToken(index).initialize(name, symbol, tokens, units, methodology);
    }

    /// @inheritdoc IIndexFactory
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology
    ) external view returns (address) {
        return Clones.predictDeterministicAddress(
            IMPLEMENTATION, _salt(creator, name, symbol, tokens, units, methodology)
        );
    }

    /// @inheritdoc IIndexFactory
    function isOwnerOrGuardian(address account) public view returns (bool) {
        return account == owner() || (account == guardian && account != address(0));
    }

    function _checkOwnerOrGuardian() private view {
        if (!isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
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

    function _validateMethodology(uint256 count, uint8 methodology) private pure {
        if (methodology >= Methodology.COUNT) revert InvalidMethodology(methodology);
        if (methodology == Methodology.CAPPED && count < MIN_CAPPED_COMPONENTS) {
            revert TooFewComponentsForCapped(count);
        }
    }

    function _salt(
        address creator,
        string calldata name,
        string calldata symbol,
        address[] calldata tokens,
        uint256[] calldata units,
        uint8 methodology
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                creator,
                keccak256(bytes(name)),
                keccak256(bytes(symbol)),
                keccak256(abi.encode(tokens)),
                keccak256(abi.encode(units)),
                methodology
            )
        );
    }

    // ---------------------------------------------------------------------
    // Whitelist and token configs
    // ---------------------------------------------------------------------

    /// @inheritdoc IIndexFactory
    function proposeListing(address token, TokenConfig calldata config) external onlyOwner {
        _propose(token, config, true);
    }

    /// @inheritdoc IIndexFactory
    function proposeConfig(address token, TokenConfig calldata config) external onlyOwner {
        TokenConfig storage current = _tokenConfig[token];
        // Every config in force has a pool or a reference supply: the rule accepts no other.
        if (current.pool == address(0) && current.referenceSupply == 0) revert NotConfigured(token);
        _propose(token, config, false);
    }

    function _propose(address token, TokenConfig calldata config, bool listing) private {
        if (token.code.length == 0) revert NotAContract(token);
        uint256 pending = listingEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ListingPending(token, pending);
        IIndexRule(RULE).checkConfig(token, config);

        uint256 eta = block.timestamp + LISTING_DELAY;
        listingEta[token] = eta;
        pendingIsListing[token] = listing;
        TokenConfig storage next = _pendingConfig[token];
        next.pool = config.pool;
        next.minLiquidity = config.minLiquidity;
        next.referenceSupply = config.referenceSupply;
        next.excluded = config.excluded;
        // The rule call above is a view on a contract this factory deployed; nothing external can run in between.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ListingProposed(
            token, eta, listing, config.pool, config.minLiquidity, config.referenceSupply, config.excluded
        );
    }

    /// @inheritdoc IIndexFactory
    function cancelListing(address token) external onlyOwnerOrGuardian {
        if (listingEta[token] == 0) revert NoPendingListing(token);
        _dropProposal(token);
    }

    function _dropProposal(address token) private {
        delete listingEta[token];
        delete pendingIsListing[token];
        delete _pendingConfig[token];
        emit ListingCancelled(token);
    }

    /// @inheritdoc IIndexFactory
    function executeListing(address token) external {
        uint256 eta = listingEta[token];
        if (eta == 0) revert NoPendingListing(token);
        if (block.timestamp < eta) revert ListingNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert ListingExpired(token, eta + PROPOSAL_WINDOW);

        bool listing = pendingIsListing[token];
        delete listingEta[token];
        delete pendingIsListing[token];
        TokenConfig storage next = _pendingConfig[token];
        TokenConfig storage current = _tokenConfig[token];
        current.pool = next.pool;
        current.minLiquidity = next.minLiquidity;
        current.referenceSupply = next.referenceSupply;
        current.excluded = next.excluded;
        delete _pendingConfig[token];
        emit TokenConfigured(token, current.pool, current.minLiquidity, current.referenceSupply, current.excluded);

        if (listing && !isWhitelisted[token]) {
            isWhitelisted[token] = true;
            _whitelist.push(token);
            _whitelistPos[token] = _whitelist.length;
            emit TokenWhitelisted(token, true);
        }
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
        // A listing proposal would undo the delist once executed; a config-only change would not.
        if (listingEta[token] != 0 && pendingIsListing[token]) _dropProposal(token);
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

    /// @inheritdoc IIndexFactory
    function tokenConfig(address token) external view returns (TokenConfig memory) {
        return _tokenConfig[token];
    }

    /// @inheritdoc IIndexFactory
    function pendingTokenConfig(address token) external view returns (TokenConfig memory) {
        return _pendingConfig[token];
    }

    function allIndexesLength() external view returns (uint256) {
        return allIndexes.length;
    }
}
