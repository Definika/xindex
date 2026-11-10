// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWeightedIndexFactory} from "./interfaces/IWeightedIndexFactory.sol";
import {IWeightedHub} from "./interfaces/IWeightedHub.sol";
import {WeightedHub} from "./WeightedHub.sol";
import {WeightedMath} from "./WeightedMath.sol";

/// @title WeightedIndexFactory
/// @notice An account the owner approved creates an index here, choosing each component's weight. Components come
///         from a curated whitelist. See {IWeightedIndexFactory}.
/// @dev Roles
///      - The owner proposes listings and guardian changes, approves who may create an index, delists, and hands over
///        ownership.
///      - A listing takes effect LISTING_DELAY after it is proposed; a guardian change, GUARDIAN_DELAY after. Either
///        must be executed within PROPOSAL_WINDOW of becoming ready, or proposed again.
///      - The guardian can cancel pending listings and delist. It keeps that power while its replacement is pending.
///        It can cancel its own removal, but the owner can still replace it with another address.
///      - Owner and guardian can cancel a pending rebalance on any index, and start one that leaves chosen components
///        untouched.
///      - Neither role can pause, upgrade, set units or weights, or touch funds held by any index. Ownership cannot
///        be renounced.
///
///      Prices
///      - There are none: neither the factory nor an index reads a price, and a listing carries no feed.
///      - A listing records the token's decimals, which only bound the units an index may start with. An index's
///        components, units and weights are fixed at creation, so no later listing or delisting reaches it.
///
///      Addresses
///      - Each index is deployed with CREATE2. The salt covers the creator, the name, the symbol, every component's
///        token, starting units and weight, and the index's config (fee rates, referral share, rebalance interval).
///        The gate and the listed flag are not in it.
///      - So an address can never hold a different basket or different terms, even after a re-org. An app can show
///        the address before the transaction confirms, unless a policy change lands first: it changes the salt, and
///        the index deploys at another address (RZ-28).
///
///      Fees
///      - The owner sets a policy: the platform's fee, the referrer's share of it, the recipient, and a creation fee
///        in ether.
///      - An index copies the rates in force at creation and keeps them. A later policy reaches only later indexes.
///      - A creator names the highest platform fee and streaming fee it accepts. So no higher rate can land between
///        its quote and its creation. The referral share is not bounded: it only splits the platform's part, so it
///        costs neither the creator nor a minter (RZ-28).
///      - The recipients are read live, through `feeTerms`, so changing a recipient strands nothing.
///      - The creation fee is forwarded to the recipient in the same call. The factory holds no ether.
///
///      Creators
///      - Only an account the owner approved creates an index. No contract reads a price, so none can tell whether
///        the units a creator names match its weights, and an index created off its weights loses that distance to
///        whoever fills its auctions: the approval is what keeps a stranger from creating one. It is read at creation
///        and nowhere else: an approved creator is bound by the whitelist and the fee caps, and withdrawing an
///        approval reaches no index that exists.
///      - The factory records each index's creator. The creator receives the creator's fee shares and can hand the
///        role on, to any account: taking the role needs no approval.
///      - On a gated index, the creator keeps the allowlist of who may receive new shares, and can open the index for
///        good. The creator has no power over components or rates.
///
///      Whitelist policy (enforced by the listing process, not on chain)
///      - Standard ERC-20s only: no fee-on-transfer, rebasing or callback (ERC-777 style) tokens; 6 to 18 decimals.
///      - Components an issuer can pause or blacklist, such as WBTC, must be labelled in the app. While one is frozen,
///        holders can still take the other components out with `WeightedHub.redeemSkipping`.
// The one payable entry point, `createIndex`, forwards all of msg.value to the platform recipient in the same call
// (`test_theCreationFeeIsForwardedWhole`), so no ether stays here.
// aderyn-fp-next-line(contract-locks-ether)
contract WeightedIndexFactory is IWeightedIndexFactory, Ownable2Step, ReentrancyGuard {
    uint256 public constant MIN_COMPONENTS = 2;
    uint256 public constant MAX_COMPONENTS = 100;
    uint256 public constant TOTAL_WEIGHT = 1e4;
    uint256 public constant MIN_RAW_UNITS = 1e4;
    uint256 public constant MAX_UNITS = type(uint96).max >> 10;
    uint256 public constant MAX_WHOLE_TOKENS = 1e9;
    uint256 public constant LISTING_DELAY = 2 days;
    uint256 public constant GUARDIAN_DELAY = 7 days;
    uint256 public constant PROPOSAL_WINDOW = 7 days;
    uint256 public constant MAX_CREATOR_FEE_BPS = 100;
    uint256 public constant MAX_PLATFORM_FEE_BPS = 25;
    uint256 public constant MAX_CREATOR_STREAMING_BPS = 500;
    uint256 public constant MAX_PLATFORM_STREAMING_BPS = 100;
    uint256 public constant MIN_REBALANCE_INTERVAL = 7 days;
    uint256 public constant MAX_REBALANCE_INTERVAL = 91 days;
    address public immutable IMPLEMENTATION;

    uint8 private constant MAX_DECIMALS = 18;
    uint256 private constant BPS = 1e4;

    address public guardian;
    address public pendingGuardian;
    uint256 public pendingGuardianEta;

    mapping(address => bool) public isWhitelisted;
    address[] private _whitelist;
    /// @dev Position in `_whitelist` plus one (0 = absent), for O(1) removal.
    mapping(address => uint256) private _whitelistPos;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address token => uint8 decimals) public decimalsOf;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address token => uint256 eta) public listingEta;
    /// @dev The decimals a pending listing read from its token when it was proposed.
    mapping(address token => uint8 decimals) private _pendingDecimals;

    /// @inheritdoc IWeightedIndexFactory
    mapping(address account => bool approved) public isApprovedCreator;
    mapping(address => bool) public isIndex;
    mapping(address => address) public creatorOf;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => address account) public pendingCreatorOf;
    address[] public allIndexes;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => bool gated) public isGated;
    /// @inheritdoc IWeightedIndexFactory
    mapping(address index => mapping(address account => bool allowed)) public isAllowedMinter;

    /// @inheritdoc IWeightedIndexFactory
    uint16 public platformFeeBps;
    /// @inheritdoc IWeightedIndexFactory
    uint16 public platformStreamingBps;
    /// @inheritdoc IWeightedIndexFactory
    uint16 public referralShareBps;
    /// @inheritdoc IWeightedIndexFactory
    address public platformFeeRecipient;
    /// @inheritdoc IWeightedIndexFactory
    uint256 public creationFee;

    modifier onlyOwnerOrGuardian() {
        _checkOwnerOrGuardian();
        _;
    }

    // A zero guardian is allowed on purpose: it means the factory starts without one.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address initialOwner, address initialGuardian) Ownable(initialOwner) {
        // A zero guardian is allowed on purpose, as above.
        // aderyn-fp-next-line(state-no-address-check)
        guardian = initialGuardian;
        emit GuardianSet(address(0), initialGuardian);
        IMPLEMENTATION = address(new WeightedHub(address(new WeightedMath())));
    }

    // ---------------------------------------------------------------------
    // Index creation
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function createIndex(
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external payable nonReentrant returns (address index) {
        if (!isApprovedCreator[msg.sender]) revert CreatorNotApproved(msg.sender);
        // The reentrancy guard covers the creation fee's transfer at the end: the only call here into an address the
        // factory did not deploy. Validation only reads storage, and initializing our own clone makes no external call.
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyString();
        if (msg.value != creationFee) revert WrongCreationFee(msg.value, creationFee);
        // Read before the clone is initialized, so no factory state is read after an external call.
        address recipient = platformFeeRecipient;
        IWeightedHub.ComponentInit[] memory inits = _componentInits(components);
        _validateComponents(components, inits);
        IWeightedHub.Config memory config = _checkedConfig(params);

        bytes32 salt = _salt(msg.sender, keccak256(bytes(name)), keccak256(bytes(symbol)), _contentsHash(inits, config));
        // Effects before interaction: register the clone, then initialize it in the same transaction.
        index = _deployClone(_template(components), salt);
        if (params.gated) isGated[index] = true;
        // Only the clone's CREATE2, which runs no code, precedes this.
        // forge-lint: disable-next-line(reentrancy-events)
        emit IndexCreated(index, msg.sender, name, symbol, inits, config, params.listed);

        _initializeIndex(index, salt, name, symbol, inits, config);

        // Last, and only if the policy charges a fee. The owner picks the recipient. One that refuses ether
        // (OpenZeppelin's FailedCall) blocks only creation, until the owner names another.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        if (msg.value != 0) Address.sendValue(payable(recipient), msg.value);
    }

    /// @dev Deploys the clone at `salt` and registers it. Reverts if that address already holds one.
    function _deployClone(address template, bytes32 salt) private returns (address index) {
        address predicted = Clones.predictDeterministicAddress(template, salt);
        if (predicted.code.length != 0) revert IndexAlreadyExists(predicted);
        index = Clones.cloneDeterministic(template, salt);
        // IndexCreated, which createIndex emits next, records the new index and its creator.
        // forge-lint: disable-next-line(missing-events-access-control)
        isIndex[index] = true;
        // IndexCreated, as above.
        // forge-lint: disable-next-line(missing-events-access-control)
        creatorOf[index] = msg.sender;
        allIndexes.push(index);
    }

    /// @dev Builds the index's config from the creator's params and the current policy, checking each against its
    ///      bound.
    function _checkedConfig(IndexParams calldata params) private view returns (IWeightedHub.Config memory) {
        if (params.creatorFeeBps > MAX_CREATOR_FEE_BPS) revert CreatorFeeTooHigh(params.creatorFeeBps);
        if (params.creatorStreamingBps > MAX_CREATOR_STREAMING_BPS) {
            revert StreamingFeeTooHigh(params.creatorStreamingBps);
        }
        if (params.rebalanceInterval < MIN_REBALANCE_INTERVAL || params.rebalanceInterval > MAX_REBALANCE_INTERVAL) {
            revert IntervalOutOfRange(params.rebalanceInterval);
        }
        uint16 platform = platformFeeBps;
        if (platform > params.maxPlatformFeeBps) revert PlatformFeeTooHigh(platform, params.maxPlatformFeeBps);
        uint16 streaming = platformStreamingBps;
        if (streaming > params.maxPlatformStreamingBps) {
            revert PlatformStreamingFeeTooHigh(streaming, params.maxPlatformStreamingBps);
        }
        return IWeightedHub.Config({
            creatorFeeBps: params.creatorFeeBps,
            platformFeeBps: platform,
            referralShareBps: referralShareBps,
            creatorStreamingBps: params.creatorStreamingBps,
            platformStreamingBps: streaming,
            rebalanceInterval: params.rebalanceInterval
        });
    }

    // ---------------------------------------------------------------------
    // Creators
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function setApprovedCreator(address account, bool approved) external onlyOwner {
        // CreatorApprovalSet, on the next line, records the change the lint asks an event for.
        // forge-lint: disable-next-line(missing-events-access-control)
        isApprovedCreator[account] = approved;
        emit CreatorApprovalSet(account, approved);
    }

    /// @inheritdoc IWeightedIndexFactory
    function transferCreator(address index, address newCreator) external {
        _checkCreator(index);
        if (newCreator == address(0)) revert ZeroAddress();
        if (newCreator == address(this) || isIndex[newCreator]) revert InvalidRecipient(newCreator);
        // CreatorTransferStarted, two lines down, records the change the lint asks an event for.
        // forge-lint: disable-next-line(missing-events-access-control)
        pendingCreatorOf[index] = newCreator;
        emit CreatorTransferStarted(index, msg.sender, newCreator);
    }

    /// @inheritdoc IWeightedIndexFactory
    function acceptCreator(address index) external {
        // The new creator accepts, so creatorOf never names an account that did not agree to it (RX-22).
        if (pendingCreatorOf[index] != msg.sender) revert Unauthorized(msg.sender);
        address previous = creatorOf[index];
        // CreatorTransferred, two lines down, records the change the lint asks an event for.
        // forge-lint: disable-next-line(missing-events-access-control)
        creatorOf[index] = msg.sender;
        // CreatorTransferred, on the next line, records the offer taken.
        // forge-lint: disable-next-line(missing-events-access-control)
        delete pendingCreatorOf[index];
        emit CreatorTransferred(index, previous, msg.sender);
    }

    /// @inheritdoc IWeightedIndexFactory
    function setAllowedMinter(address index, address account, bool allowed) external {
        _checkCreator(index);
        isAllowedMinter[index][account] = allowed;
        emit MinterAllowed(index, account, allowed);
    }

    /// @inheritdoc IWeightedIndexFactory
    function openMinting(address index) external {
        _checkCreator(index);
        if (!isGated[index]) revert NotGated(index);
        isGated[index] = false;
        emit MintingOpened(index);
    }

    /// @dev Reverts unless the caller is `index`'s creator. An address the factory did not deploy has no creator, so it
    ///      is refused first.
    function _checkCreator(address index) private view {
        if (!isIndex[index]) revert NotIndex(index);
        if (msg.sender != creatorOf[index]) revert Unauthorized(msg.sender);
    }

    /// @inheritdoc IWeightedIndexFactory
    function feeTerms(address index, address to)
        external
        view
        returns (bool allowed, address creator, address platform)
    {
        creator = creatorOf[index];
        // A gated index's creator mints it without an allowlist entry, which it could give itself anyway.
        allowed = !isGated[index] || to == creator || isAllowedMinter[index][to];
        platform = platformFeeRecipient;
    }

    /// @inheritdoc IWeightedIndexFactory
    function setFeePolicy(
        uint16 platformFeeBps_,
        uint16 platformStreamingBps_,
        uint16 referralShareBps_,
        address recipient,
        uint256 creationFee_
    ) external onlyOwner {
        if (
            platformFeeBps_ > MAX_PLATFORM_FEE_BPS || platformStreamingBps_ > MAX_PLATFORM_STREAMING_BPS
                || referralShareBps_ > BPS || recipient == address(0) || recipient == address(this)
                || isIndex[recipient]
        ) revert InvalidFeePolicy();
        platformFeeBps = platformFeeBps_;
        platformStreamingBps = platformStreamingBps_;
        referralShareBps = referralShareBps_;
        platformFeeRecipient = recipient;
        creationFee = creationFee_;
        emit FeePolicySet(platformFeeBps_, platformStreamingBps_, referralShareBps_, recipient, creationFee_);
    }

    /// @dev The implementation an index of `components` clones: `WeightedHub`. A factory for another kind of component
    ///      would override this and `_initializeIndex`.
    function _template(ComponentSpec[] calldata) internal view virtual returns (address) {
        return IMPLEMENTATION;
    }

    /// @dev Initializes a fresh clone. The salt is unused here; it is kept for an override that records it.
    function _initializeIndex(
        address index,
        bytes32,
        string calldata name,
        string calldata symbol,
        IWeightedHub.ComponentInit[] memory inits,
        IWeightedHub.Config memory config
    ) internal virtual {
        // Safe: `createIndex` is nonReentrant, the clone runs this factory's own implementation, and the only later
        // interaction (the creation fee's transfer) reads no state. Wake's reentrancy detector does not model the
        // guard.
        // wake-disable-next-line reentrancy
        IWeightedHub(index).initialize(name, symbol, inits, config);
    }

    /// @inheritdoc IWeightedIndexFactory
    function predictIndexAddress(
        address creator,
        string calldata name,
        string calldata symbol,
        ComponentSpec[] calldata components,
        IndexParams calldata params
    ) external view returns (address) {
        return _predictAddress(
            creator, keccak256(bytes(name)), keccak256(bytes(symbol)), components, _checkedConfig(params)
        );
    }

    /// @dev {predictIndexAddress} with the name and symbol already hashed, to save stack slots.
    function _predictAddress(
        address creator,
        bytes32 nameHash,
        bytes32 symbolHash,
        ComponentSpec[] calldata components,
        IWeightedHub.Config memory config
    ) private view returns (address) {
        bytes32 contents = _contentsHash(_componentInits(components), config);
        return Clones.predictDeterministicAddress(_template(components), _salt(creator, nameHash, symbolHash, contents));
    }

    /// @inheritdoc IWeightedIndexFactory
    function isOwnerOrGuardian(address account) public view returns (bool) {
        return account == owner() || (account == guardian && account != address(0));
    }

    function _checkOwnerOrGuardian() private view {
        if (!isOwnerOrGuardian(msg.sender)) revert Unauthorized(msg.sender);
    }

    /// @dev Validates `components` against the whitelist, the unit and weight bounds and the duplicate rule. The
    ///      duplicate check compares `inits` in memory: comparing calldata structs cost 1.9M gas at a hundred
    ///      components.
    function _validateComponents(ComponentSpec[] calldata components, IWeightedHub.ComponentInit[] memory inits)
        private
        view
    {
        uint256 n = components.length;
        if (n < MIN_COMPONENTS || n > MAX_COMPONENTS) revert InvalidComponentCount(n);

        uint256 total = 0;
        for (uint256 i = 0; i < n; ++i) {
            ComponentSpec calldata c = components[i];
            IWeightedHub.ComponentInit memory init = inits[i];
            address token = init.token;
            if (!isWhitelisted[token]) revert TokenNotWhitelisted(token);
            if (c.units < MIN_RAW_UNITS || c.units > _maxUnits(decimalsOf[token])) {
                revert UnitsOutOfRange(token, c.units);
            }
            if (c.weight == 0 || c.weight > TOTAL_WEIGHT) revert InvalidWeights();
            total += c.weight;
            for (uint256 j = 0; j < i; ++j) {
                if (inits[j].token == token) revert DuplicateToken(token);
            }
        }
        if (total != TOTAL_WEIGHT) revert InvalidWeights();
    }

    /// @dev The most units a component of `decimals` may start with: MAX_WHOLE_TOKENS whole tokens per share, and never
    ///      above MAX_UNITS. So one wei-share backs a negligible amount of every component, and no fee's rounding to
    ///      whole wei-shares is worth anything (RX-5).
    function _maxUnits(uint8 decimals) private pure returns (uint256) {
        uint256 whole = MAX_WHOLE_TOKENS * 10 ** decimals;
        return whole < MAX_UNITS ? whole : MAX_UNITS;
    }

    /// @dev The components in the form the index's initializer takes.
    function _componentInits(ComponentSpec[] calldata components)
        private
        pure
        returns (IWeightedHub.ComponentInit[] memory inits)
    {
        uint256 n = components.length;
        inits = new IWeightedHub.ComponentInit[](n);
        for (uint256 i = 0; i < n; ++i) {
            ComponentSpec calldata c = components[i];
            inits[i] = IWeightedHub.ComponentInit({token: c.token, units: c.units, weight: c.weight});
        }
    }

    /// @dev The CREATE2 salt: a hash of the creator, the hashed name and symbol, and {_contentsHash}.
    function _salt(address creator, bytes32 nameHash, bytes32 symbolHash, bytes32 contents)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(creator, nameHash, symbolHash, contents));
    }

    /// @dev The hash of the index's terms: every component's token, units and weight, and the config (fee rates,
    ///      referral share, rebalance interval).
    function _contentsHash(IWeightedHub.ComponentInit[] memory inits, IWeightedHub.Config memory config)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(keccak256(abi.encode(inits)), keccak256(abi.encode(config))));
    }

    // ---------------------------------------------------------------------
    // Whitelist
    // ---------------------------------------------------------------------

    /// @inheritdoc IWeightedIndexFactory
    function proposeListing(address token) external onlyOwner {
        if (token.code.length == 0) revert NotAContract(token);
        // Read once, here, and never again: it bounds the units an index may start this token with, and the factory
        // calls no token after this (RT-01). The proposal's delay makes it public before it counts.
        // aderyn-fp-next-line(reentrancy-state-change)
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals > MAX_DECIMALS) revert InvalidDecimals(token, decimals);
        _proposeListing(token, decimals);
    }

    /// @dev Records a listing proposal, with the decimals the caller just read from the token.
    function _proposeListing(address token, uint8 decimals) internal {
        if (isWhitelisted[token]) revert AlreadyListed(token);
        uint256 pending = listingEta[token];
        if (pending != 0 && block.timestamp <= pending + PROPOSAL_WINDOW) revert ListingPending(token, pending);

        uint256 eta = block.timestamp + LISTING_DELAY;
        listingEta[token] = eta;
        _pendingDecimals[token] = decimals;
        emit ListingProposed(token, eta, decimals);
    }

    /// @inheritdoc IWeightedIndexFactory
    function cancelListing(address token) external onlyOwnerOrGuardian {
        if (listingEta[token] == 0) revert NoPendingListing(token);
        delete listingEta[token];
        delete _pendingDecimals[token];
        emit ListingCancelled(token);
    }

    /// @inheritdoc IWeightedIndexFactory
    function executeListing(address token) external {
        uint256 eta = listingEta[token];
        if (eta == 0) revert NoPendingListing(token);
        if (block.timestamp < eta) revert ListingNotReady(token, eta);
        if (block.timestamp > eta + PROPOSAL_WINDOW) revert ListingExpired(token, eta + PROPOSAL_WINDOW);

        uint8 decimals = _pendingDecimals[token];
        delete listingEta[token];
        delete _pendingDecimals[token];
        decimalsOf[token] = decimals;
        emit TokenDecimalsSet(token, decimals);

        // The token is never already whitelisted here: a proposal is refused for a whitelisted token (AlreadyListed),
        // and only this function whitelists one, clearing its proposal as it does.
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
        // The owner can cancel any guardian change. The guardian can cancel only its own removal. So the owner can
        // still replace a hostile or keyless guardian, but cannot leave the factory with no guardian over its
        // objection.
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
    function maxUnitsOf(address token) external view returns (uint256) {
        return _maxUnits(decimalsOf[token]);
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
