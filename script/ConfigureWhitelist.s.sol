// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {CompositeFeed} from "../src/CompositeFeed.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Drives the two-step flow that lists tokens and sets their market-data configs. It never lists a token on its
///         own: a token never listed gets a first-listing proposal only when named in LIST, and one the guardian
///         delisted is listed again only when named in RELIST; any other token listed before gets config changes only.
///         Nothing on chain records that the guardian cancelled a first listing, so without LIST a routine run proposed
///         the vetoed listing again, unlabelled among the refreshes, and one missed veto window listed it (RT-06): a
///         routine run leaves LIST unset. Execute mode never proposes, and runs only proposals whose pending config is
///         exactly the entry's.
///
///   Propose, as a factory owner that is a key you hold, delegated under EIP-7702 or not (testnets and local forks; a
///   contract owner, such as the mainnet Safe, cannot sign, and propose mode then reverts with OwnerIsContract: use
///   safe mode below):
///     LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> LIST=<tokens to list> \
///       forge script script/ConfigureWhitelist.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
///   Execute, from any account, between LISTING_DELAY and LISTING_DELAY + PROPOSAL_WINDOW later:
///     LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet --account deployer --sender <any account> --broadcast
///
///   Propose for an owner that is a Safe: log the `proposeListing` / `proposeConfig` calldata to sign in the Safe app,
///   one transaction per calldata line, each to the factory with no value, under a line naming the call, the token's
///   symbol and its address. Any account can run it, and nothing is broadcast (add LIST to propose first listings):
///     LISTING_MODE=safe FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
///
/// Env:
///   LISTING_MODE  `propose`, `execute`, `safe`, or `status` (read-only: what is listed, pending and due, per entry).
///   FACTORY       Deployed IndexFactory.
///   WHITELIST     `default` for the mainnet list below (chain 1 only), or comma-separated entries
///                 `token:feed:maxStaleness:referenceSupply`, all four fields required. `feed` is the token's
///                 Chainlink-shaped USD aggregator, or a `CompositeFeed` over two of them. `maxStaleness` is the oldest
///                 answer the rule will price the token from, in seconds; the policy is the feed's heartbeat plus half
///                 an hour. `referenceSupply` is in the token's raw units (with its decimals) and must be non-zero: the
///                 rule reads no supply live (CR-M01). It used to be optional, and a missing one meant the token's own
///                 supply, so a routine feed refresh written as three fields silently moved WBTC's supply 173-fold past
///                 the DA-18 bound (CR-L03).
///   WBTC_FEED     Required with WHITELIST=default: the deployed `CompositeFeed` over BTC/USD and WBTC/BTC that
///                 `Deploy` logs. Its code is checked against an adapter this run builds before it is proposed.
///   LIST          Optional. Tokens propose and safe mode may propose something for that no entry field asks
///                 for: a first listing for a token never listed, or the config in force again for a token whose
///                 decimals moved, to record them (RT-22). Comma-separated addresses, or `all` for every entry of
///                 WHITELIST. A token it does not name is skipped with its reason, which is what keeps a first listing
///                 or a decimals refresh the guardian cancelled cancelled (RT-06). Set it on the run that means to,
///                 and leave it unset on a routine refresh. It never lists a delisted token again; that takes RELIST.
///   RELIST        Optional. Comma-separated delisted tokens that propose and safe mode may list again; any other
///                 delisted token only gets config changes.
contract ConfigureWhitelist is Script {
    /// @notice A token and the config to list it with.
    /// @param token Token to list or configure.
    /// @param feed The token's USD price feed, read as an {IAggregatorV3}.
    /// @param maxStaleness Oldest answer the rule will price the token from, in seconds.
    /// @param referenceSupply Reference supply in the token's raw units; required and non-zero (CR-M01).
    struct Entry {
        address token;
        address feed;
        uint32 maxStaleness;
        uint256 referenceSupply;
    }

    /// @notice What `status` found for one entry.
    /// @param token The entry's token.
    /// @param listed Whether it is whitelisted.
    /// @param inForce Whether the config in force is the entry's.
    /// @param eta When the pending proposal becomes executable, or 0 when nothing is pending; it expires
    ///        `PROPOSAL_WINDOW` later.
    /// @param pendingIsListing Whether the pending proposal lists the token rather than only changing its config.
    /// @param pendingMatches Whether the pending config is the entry's.
    /// @param recordedDecimals Decimals the factory recorded when the token's config came into force, which the rule
    ///        prices it with; 0 for a token never listed.
    /// @param liveDecimals What the token's `decimals()` answers now; 0 when it answers nothing that decodes as a
    ///        uint8. A token listed before whose two differ is priced a power of ten off until a config for it is
    ///        executed again, which records the new ones (RT-22).
    /// @param pendingDecimals Decimals the pending proposal pinned; a proposal whose token answers others now cannot be
    ///        executed and has to be cancelled and proposed again (RT-23). 0 with nothing pending.
    struct Report {
        address token;
        bool listed;
        bool inForce;
        uint256 eta;
        bool pendingIsListing;
        bool pendingMatches;
        uint8 recordedDecimals;
        uint8 liveDecimals;
        uint8 pendingDecimals;
    }

    /// @notice Fewest and most decimals the whitelist policy accepts for a component.
    uint8 public constant MIN_DECIMALS = 6;
    uint8 public constant MAX_DECIMALS = 18;

    /// @dev Positions of the fields after token and feed in a WHITELIST entry, and how many an entry has.
    uint256 private constant MAX_STALENESS_FIELD = 2;
    uint256 private constant REFERENCE_SUPPLY_FIELD = 3;
    uint256 private constant ENTRY_FIELDS = 4;

    /// @dev Bytes in an ABI word.
    uint256 private constant WORD = 32;

    /// @notice What `propose` does for an entry: nothing, `proposeListing`, or `proposeConfig`.
    enum Action {
        Skip,
        List,
        ChangeConfig
    }

    /// @notice LISTING_MODE is not `propose`, `execute`, `safe` or `status`.
    error UnknownMode(string mode);
    /// @notice WHITELIST=default off chain 1.
    error DefaultListOnlyOnMainnet();
    /// @notice A WHITELIST entry does not have exactly four fields, or leaves its reference supply empty.
    error MalformedEntry(string entry);
    /// @notice WBTC_FEED is not this build's CompositeFeed over BTC/USD and WBTC/BTC with their policy staleness
    ///         bounds.
    error WrongCompositeFeed(address feed);
    /// @notice Propose mode needs an owner that can sign transactions, and this factory's owner is a contract (a Safe
    ///         on mainnet). Use `LISTING_MODE=safe` and submit the calldata it logs from the owner.
    error OwnerIsContract(address owner);
    /// @notice The entries name `token` twice. Safe mode decides every entry against the same state, so it emitted a
    ///         proposal for each copy, and the second reverted the whole Safe batch with ListingPending (RT-24).
    error DuplicateEntry(address token);

    /// @notice Default mainnet components, from `MainnetAddresses`. Every entry carries a reference supply, because the
    ///         rule reads none live (CR-M01): CoinGecko's circulating supplies, and wstETH's own total supply read
    ///         on-chain on a stated day (propose a config change when they drift). Staleness bounds are each feed's
    ///         heartbeat plus half an hour; `MainnetAddresses` dates both and names every feed's heartbeat and
    ///         category. WETH, WBTC and wrapped SOL count the whole ether, bitcoin and solana supply, because their
    ///         on-chain supply is only the wrapped or bridged float; wstETH counts its own, because each one is a claim
    ///         on staked ether rather than a copy of a supply held elsewhere. WBTC has no USD feed of its own and is
    ///         priced through `wbtcFeed`, a `CompositeFeed` over BTC/USD and WBTC/BTC. WBTC can be paused by its
    ///         custodian, wrapped SOL depends on the Wormhole bridge and is priced at par with SOL, and wstETH depends
    ///         on Lido, so the app must label all three; an index holding both WETH and wstETH holds two claims on
    ///         ether, which it must label too.
    /// @param wbtcFeed The deployed composite feed for WBTC; {checkWbtcFeed} validates it.
    /// @return list WETH, wstETH, WBTC, wrapped SOL, LINK, UNI and AAVE, in that order.
    function defaultMainnetList(address wbtcFeed) public pure returns (Entry[] memory list) {
        list = new Entry[](7);
        list[0] = Entry({
            token: MainnetAddresses.WETH,
            feed: MainnetAddresses.ETH_USD_FEED,
            maxStaleness: MainnetAddresses.STALENESS_1H,
            referenceSupply: MainnetAddresses.ETH_SUPPLY
        });
        list[1] = Entry({
            token: MainnetAddresses.WSTETH,
            feed: MainnetAddresses.WSTETH_USD_FEED,
            maxStaleness: MainnetAddresses.STALENESS_24H,
            referenceSupply: MainnetAddresses.WSTETH_SUPPLY
        });
        list[2] = Entry({
            token: MainnetAddresses.WBTC,
            feed: wbtcFeed,
            maxStaleness: MainnetAddresses.STALENESS_24H,
            referenceSupply: MainnetAddresses.BTC_SUPPLY
        });
        list[3] = Entry({
            token: MainnetAddresses.WSOL,
            feed: MainnetAddresses.SOL_USD_FEED,
            maxStaleness: MainnetAddresses.STALENESS_24H,
            referenceSupply: MainnetAddresses.SOL_SUPPLY
        });
        list[4] = Entry({
            token: MainnetAddresses.LINK,
            feed: MainnetAddresses.LINK_USD_FEED,
            maxStaleness: MainnetAddresses.STALENESS_1H,
            referenceSupply: MainnetAddresses.LINK_SUPPLY
        });
        list[5] = Entry({
            token: MainnetAddresses.UNI,
            feed: MainnetAddresses.UNI_USD_FEED,
            maxStaleness: MainnetAddresses.STALENESS_1H,
            referenceSupply: MainnetAddresses.UNI_SUPPLY
        });
        list[6] = Entry({
            token: MainnetAddresses.AAVE,
            feed: MainnetAddresses.AAVE_USD_FEED,
            maxStaleness: MainnetAddresses.STALENESS_1H,
            referenceSupply: MainnetAddresses.AAVE_SUPPLY
        });
    }

    /// @notice Reverts unless `feed` is a `CompositeFeed` over exactly BTC/USD and WBTC/BTC with the policy bounds on
    ///         each leg. The composite is deployed rather than constant, so this is what ties the address an operator
    ///         passes to the two feeds it is supposed to multiply. It compares code, not answers: `feed` must run the
    ///         same executable code, immutables and all, as an adapter this run deploys with the policy arguments, in
    ///         its own simulation and never broadcast. Reading the adapter's four getters was not enough, since a proxy
    ///         whose first implementation was a genuine adapter answered every one of them, passed, and let its
    ///         controller reprice WBTC for every index afterwards (CR-L04).
    /// @param feed The WBTC_FEED value.
    function checkWbtcFeed(address feed) public {
        CompositeFeed genuine = new CompositeFeed(
            IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
            IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
            MainnetAddresses.STALENESS_1H,
            MainnetAddresses.STALENESS_24H
        );
        if (executableCodeHash(feed) != executableCodeHash(address(genuine))) revert WrongCompositeFeed(feed);
    }

    /// @notice keccak256 of `account`'s runtime code without the metadata the compiler appends to it, whose length the
    ///         last two bytes give. What remains is the executable code with its immutables, which is all that decides
    ///         what a contract does. The metadata hashes source text, so leaving it in would fail a genuine adapter
    ///         deployed from an earlier commit over nothing but an edited comment. Code with no room for metadata is
    ///         hashed whole, so it can only match itself.
    /// @param account Contract whose code is hashed.
    /// @return hash The hash; that of empty code for an account without any.
    function executableCodeHash(address account) public view returns (bytes32 hash) {
        bytes memory code = account.code;
        uint256 length = code.length;
        uint256 metadata =
            length < 2 ? length + 1 : (uint256(uint8(code[length - 2])) << 8 | uint8(code[length - 1])) + 2;
        bytes memory executable = new bytes(metadata > length ? length : length - metadata);
        for (uint256 i = 0; i < executable.length; ++i) {
            executable[i] = code[i];
        }
        hash = keccak256(executable);
    }

    /// @notice Reads FACTORY, WHITELIST, LIST, RELIST and LISTING_MODE from the environment and runs that mode.
    function run() external {
        IIndexFactory factory = IIndexFactory(vm.envAddress("FACTORY"));
        Entry[] memory list = resolveList(vm.envString("WHITELIST"), vm.envOr("WBTC_FEED", address(0)));
        address[] memory firstListings = resolveFirstListings(vm.envOr("LIST", string("")), list);
        address[] memory relist = parseAddresses(vm.envOr("RELIST", string("")));
        string memory mode = vm.envString("LISTING_MODE");
        if (ScriptUtils.same(mode, "propose")) {
            propose(factory, list, firstListings, relist);
        } else if (ScriptUtils.same(mode, "execute")) {
            execute(factory, list);
        } else if (ScriptUtils.same(mode, "safe")) {
            (bytes[] memory calls, string[] memory labels) = safeCalldata(factory, list, firstListings, relist);
            console2.log("Safe transactions to the factory, value 0:", address(factory));
            for (uint256 i = 0; i < calls.length; ++i) {
                // Which call, for which token: among lines of hex a listing read as one more routine refresh (RT-06).
                console2.log(labels[i]);
                console2.logBytes(calls[i]);
            }
        } else if (ScriptUtils.same(mode, "status")) {
            status(factory, list);
        } else {
            revert UnknownMode(mode);
        }
    }

    /// @notice Comma-separated addresses; an empty string is an empty list.
    /// @param raw The environment value, such as RELIST.
    /// @return addresses The parsed addresses, in order.
    function parseAddresses(string memory raw) public pure returns (address[] memory addresses) {
        if (bytes(raw).length == 0) return addresses;
        string[] memory parts = vm.split(raw, ",");
        addresses = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            addresses[i] = vm.parseAddress(vm.trim(parts[i]));
        }
    }

    /// @notice The LIST value: `all` names the token of every entry in `list`, and anything else is parsed as
    ///         comma-separated addresses, so an empty value names none and no first listing is proposed unless the
    ///         operator asks for it (RT-06).
    /// @param raw The LIST value.
    /// @param list This run's entries.
    /// @return tokens Tokens never listed that may be proposed for a first listing.
    function resolveFirstListings(string memory raw, Entry[] memory list)
        public
        pure
        returns (address[] memory tokens)
    {
        if (!ScriptUtils.same(raw, "all")) return parseAddresses(raw);
        tokens = new address[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            tokens[i] = list[i].token;
        }
    }

    /// @notice `default` means the mainnet list and is only accepted on chain 1; anything else is parsed as
    ///         comma-separated entries. The default list needs `wbtcFeed`, which is checked before it is used. Reverts
    ///         DuplicateEntry for a list that names a token twice, whatever mode would run on it (RT-24).
    /// @param raw The WHITELIST value.
    /// @param wbtcFeed The WBTC_FEED value; only read for the default list.
    /// @return list The entries, in order.
    function resolveList(string memory raw, address wbtcFeed) public returns (Entry[] memory list) {
        if (ScriptUtils.same(raw, "default")) {
            if (block.chainid != 1) revert DefaultListOnlyOnMainnet();
            checkWbtcFeed(wbtcFeed);
            list = defaultMainnetList(wbtcFeed);
        } else {
            string[] memory parts = vm.split(raw, ",");
            list = new Entry[](parts.length);
            for (uint256 i = 0; i < parts.length; ++i) {
                list[i] = parseEntry(vm.trim(parts[i]));
            }
        }
        _requireUnique(list);
    }

    /// @notice Parses `token:feed:maxStaleness:referenceSupply`. Every field is required: a reference supply left out
    ///         used to parse as 0 and switch the token to its own live supply (CR-L03).
    /// @param raw One entry, without surrounding spaces.
    /// @return entry The parsed entry.
    function parseEntry(string memory raw) public pure returns (Entry memory entry) {
        string[] memory fields = vm.split(raw, ":");
        if (fields.length != ENTRY_FIELDS || bytes(fields[REFERENCE_SUPPLY_FIELD]).length == 0) {
            revert MalformedEntry(raw);
        }
        entry.token = vm.parseAddress(fields[0]);
        entry.feed = vm.parseAddress(fields[1]);
        entry.maxStaleness = SafeCast.toUint32(vm.parseUint(fields[MAX_STALENESS_FIELD]));
        entry.referenceSupply = vm.parseUint(fields[REFERENCE_SUPPLY_FIELD]);
    }

    /// @notice The config `entry` proposes. Every field is the entry's: nothing is looked up, so what an operator
    ///         reads in WHITELIST is exactly what the factory is asked to store.
    /// @param entry The entry.
    /// @return config The token config.
    function configFor(Entry memory entry) public pure returns (IIndexFactory.TokenConfig memory config) {
        config.feed = entry.feed;
        config.maxStaleness = entry.maxStaleness;
        config.referenceSupply = entry.referenceSupply;
    }

    /// @notice Owner only. For every entry with nothing pending, proposes a listing for a token never listed that is
    ///         named in `firstListings`, or a delisted one named in `relist`, and a config change for any other token
    ///         listed before whose config differs from the entry, or whose decimals moved since its config came into
    ///         force when `firstListings` names it. A token the guardian delisted, or whose first listing or decimals
    ///         refresh it cancelled, is therefore never proposed again by a routine run. An expired proposal is
    ///         proposed again, a first listing only when named. An entry the rule rejects is skipped and the reason
    ///         logged. Reverts DuplicateEntry for a list that names a token twice. Reverts with OwnerIsContract when
    ///         the owner cannot sign, which is always the case on mainnet: safe mode logs the same calls as calldata
    ///         instead.
    /// @param factory The deployed factory; the broadcasting key must be its owner.
    /// @param list Entries to propose.
    /// @param firstListings Tokens that may get a first listing, or their config again to record moved decimals (LIST).
    /// @param relist Delisted tokens that may be listed again (RELIST).
    function propose(
        IIndexFactory factory,
        Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist
    ) public {
        _requireUnique(list);
        address factoryOwner = Ownable(address(factory)).owner();
        // A key that delegated its account under EIP-7702 has code and still signs, so it is not a contract owner.
        bytes memory ownerCode = factoryOwner.code;
        if (ownerCode.length != 0 && !ScriptUtils.isDelegatedAccount(ownerCode)) revert OwnerIsContract(factoryOwner);
        IIndexRule rule = IIndexRule(factory.RULE());
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            IIndexFactory.TokenConfig memory config = configFor(list[i]);
            Action action = _action(factory, rule, token, config, firstListings, relist);
            if (action == Action.List) {
                factory.proposeListing(token, config);
                console2.log("proposed a listing", token);
            } else if (action == Action.ChangeConfig) {
                factory.proposeConfig(token, config);
                console2.log("proposed a config change", token);
            }
        }
        vm.stopBroadcast();
    }

    /// @notice Any account, nothing is broadcast. For an owner that is a Safe: the `proposeListing` or `proposeConfig`
    ///         calldata of every entry `propose` would submit, each to be sent to the factory with no value, and the
    ///         line safe mode prints above each. Reverts DuplicateEntry for a list that names a token twice: every
    ///         entry is decided against the same state, so each copy got a proposal, and the Safe batch, one
    ///         transaction, reverted at the second (RT-24).
    /// @param factory The deployed factory, owned by the Safe.
    /// @param list Entries to propose.
    /// @param firstListings Tokens that may get a first listing, or their config again to record moved decimals (LIST).
    /// @param relist Delisted tokens that may be listed again (RELIST).
    /// @return calls One call per proposal, in entry order.
    /// @return labels For each call, `proposeListing` or `proposeConfig`, the token's symbol and its address (RT-06).
    function safeCalldata(
        IIndexFactory factory,
        Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist
    ) public view returns (bytes[] memory calls, string[] memory labels) {
        _requireUnique(list);
        IIndexRule rule = IIndexRule(factory.RULE());
        Action[] memory actions = new Action[](list.length);
        uint256 count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            actions[i] = _action(factory, rule, list[i].token, configFor(list[i]), firstListings, relist);
            if (actions[i] != Action.Skip) ++count;
        }
        calls = new bytes[](count);
        labels = new string[](count);
        count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            if (actions[i] == Action.Skip) continue;
            (calls[count], labels[count]) = _proposal(factory, actions[i], list[i]);
            ++count;
        }
    }

    /// @dev The call that carries out `action` for `entry`, a listing or a config change, and its label. A config
    ///      change that also records decimals the token moved to says so, since it reprices the token by a power of ten
    ///      (RT-22).
    function _proposal(IIndexFactory factory, Action action, Entry memory entry)
        private
        view
        returns (bytes memory call, string memory label)
    {
        IIndexFactory.TokenConfig memory config = configFor(entry);
        bool listing = action == Action.List;
        call = listing
            ? abi.encodeCall(IIndexFactory.proposeListing, (entry.token, config))
            : abi.encodeCall(IIndexFactory.proposeConfig, (entry.token, config));
        string memory kind = listing ? "proposeListing " : "proposeConfig ";
        uint8 recorded = factory.tokenDecimals(entry.token);
        (bool answered, uint8 decimals) = _decimalsOf(entry.token);
        if (!listing && answered && decimals != recorded) {
            kind = string.concat(
                "proposeConfig (records decimals ", vm.toString(recorded), " -> ", vm.toString(decimals), ") "
            );
        }
        label = string.concat(kind, _symbolOf(entry.token), " ", vm.toString(entry.token));
    }

    /// @dev Reverts DuplicateEntry at the first token `list` names twice (RT-24).
    function _requireUnique(Entry[] memory list) private pure {
        for (uint256 i = 1; i < list.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (list[j].token == list[i].token) revert DuplicateEntry(list[i].token);
            }
        }
    }

    /// @notice Any account. Executes every due proposal whose pending config is exactly the entry's config, and skips
    ///         everything else with the reason logged: nothing pending, not ready, expired, a pending config the entry
    ///         does not name, one the rule now rejects, as it does a feed that has gone stale since the proposal, or
    ///         one whose token changed its decimals since the proposal, which the factory refuses (RT-23) and which has
    ///         to be cancelled and proposed again. `executeListing` checks both, so asking first keeps one such entry
    ///         from aborting the whole run and leaving every other due proposal unexecuted (CR-I38, RT-22).
    /// @param factory The deployed factory.
    /// @param list Entries whose proposals to execute.
    function execute(IIndexFactory factory, Entry[] memory list) public {
        IIndexRule rule = IIndexRule(factory.RULE());
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            uint256 eta = factory.listingEta(token);
            if (eta == 0) continue; // nothing is pending for this token
            if (!_sameConfig(factory.pendingTokenConfig(token), configFor(list[i]))) {
                console2.log("not executed, the pending config differs from the entry", token);
            } else if (block.timestamp < eta) {
                console2.log("not ready yet", token);
            } else if (block.timestamp > eta + factory.PROPOSAL_WINDOW()) {
                console2.log("expired, propose again", token);
            } else {
                _executeDue(factory, rule, token, configFor(list[i]));
            }
        }
        vm.stopBroadcast();
    }

    /// @dev Executes a due proposal carrying `config`, unless the rule now rejects it or the token's decimals moved
    ///      since it was proposed; the reason is logged either way. Both checks are static calls, so asking first
    ///      broadcasts nothing.
    function _executeDue(IIndexFactory factory, IIndexRule rule, address token, IIndexFactory.TokenConfig memory config)
        private
    {
        try rule.checkConfig(token, config) {}
        catch (bytes memory reason) {
            console2.log("not executed, the rule now rejects the pending config", token);
            console2.logBytes(reason);
            return;
        }
        // The factory pinned the token's decimals with the proposal and refuses to execute it once they moved (RT-23).
        if (_pinnedDecimalsMoved(factory, token)) {
            console2.log(
                "not executed, the token's decimals changed since the proposal; cancel it, propose again", token
            );
            return;
        }
        bool relisting = factory.pendingIsListing(token);
        factory.executeListing(token);
        // A config change executes cleanly but leaves a delisted token delisted; say so rather than let
        // "executed" read as a relisting (DA-20).
        if (!relisting && !factory.isWhitelisted(token)) {
            console2.log("executed the config change; the token is still delisted", token);
        } else {
            console2.log("executed", token);
        }
    }

    /// @dev Skip, with the reason logged, for an entry that is pending, whose token's listing state leaves nothing to
    ///      propose ({_intent}), outside the policy, moving a reference supply past the factory's bound, or rejected by
    ///      the rule. Otherwise what the listing state calls for: a listing or a config change.
    function _action(
        IIndexFactory factory,
        IIndexRule rule,
        address token,
        IIndexFactory.TokenConfig memory config,
        address[] memory firstListings,
        address[] memory relist
    ) private view returns (Action) {
        uint256 eta = factory.listingEta(token);
        if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
            // A config-only proposal never whitelists, so it cannot carry out a relisting however long it waits.
            // Reporting it as "already pending" left the operator believing RELIST had been acted on (DA-20).
            if (!factory.isWhitelisted(token) && _contains(relist, token) && !factory.pendingIsListing(token)) {
                console2.log("skipped, RELIST needs a listing but a config change is pending; cancel it first", token);
            } else if (_pinnedDecimalsMoved(factory, token)) {
                // Reporting it as "already pending" would leave a proposal the factory can never execute (RT-23).
                console2.log("skipped, pending but its token's decimals changed since; cancel it first", token);
            } else if (_sameConfig(factory.pendingTokenConfig(token), config)) {
                console2.log("already pending", token);
            } else {
                console2.log("skipped, a different config is pending; cancel it first", token);
            }
            return Action.Skip;
        }
        IIndexFactory.TokenConfig memory current = factory.tokenConfig(token);
        Action action = _intent(factory, token, current, config, firstListings, relist);
        if (action == Action.Skip) return Action.Skip;
        if (!_followsPolicy(token, config.feed, config.referenceSupply)) return Action.Skip;
        if (!_withinSupplyBound(factory, token, current.referenceSupply, config.referenceSupply)) return Action.Skip;
        try rule.checkConfig(token, config) {
            return action;
        } catch (bytes memory reason) {
            console2.log("skipped, the rule rejects this config", token);
            console2.logBytes(reason);
            return Action.Skip;
        }
    }

    /// @dev What `token`'s listing state calls for, before the policy, the supply bound and the rule have their say: a
    ///      listing for a token never listed that `firstListings` names or a delisted one that `relist` names, and a
    ///      config change for any other token listed before whose config in force is not `config`, or whose decimals
    ///      moved when `firstListings` names it. Skip, with the reason logged, for a token never listed or with moved
    ///      decimals that is not named, and for one listed before with nothing to change.
    function _intent(
        IIndexFactory factory,
        address token,
        IIndexFactory.TokenConfig memory current,
        IIndexFactory.TokenConfig memory config,
        address[] memory firstListings,
        address[] memory relist
    ) private view returns (Action) {
        // Every config in force names a feed, so an empty one means the token was never listed.
        if (current.feed == address(0)) {
            // Nothing on chain records that the guardian cancelled a first listing, so only the operator naming the
            // token tells a new listing from a vetoed one proposed again (RT-06).
            if (_contains(firstListings, token)) return Action.List;
            console2.log("skipped, never listed; name it in LIST to propose its first listing", token);
            return Action.Skip;
        }
        // Checked, and logged, whatever the entry proposes: any proposal executed for the token records the decimals it
        // answers, and new ones reprice it by a power of ten.
        bool decimalsMoved = _decimalsMoved(factory, token);
        bool listed = factory.isWhitelisted(token);
        if (!listed && _contains(relist, token)) return Action.List;
        if (!_sameConfig(current, config)) return Action.ChangeConfig;
        // The config in force proposed again is how the record catches up with the token (RT-22). No entry field asks
        // for it, and nothing on chain records that the guardian vetoed the last one, so, like a first listing, it is
        // proposed only when the operator names the token; otherwise a vetoed refresh came back on every run (RT-06).
        if (decimalsMoved) {
            if (_contains(firstListings, token)) return Action.ChangeConfig;
            console2.log("skipped, name it in LIST to propose its config again and record its new decimals", token);
            return Action.Skip;
        }
        if (!listed) console2.log("skipped, delisted; name it in RELIST to list it again", token);
        return Action.Skip;
    }

    /// @dev The factory's DA-18 bound, applied here so an entry that moves a reference supply further than
    ///      MAX_SUPPLY_CHANGE from the one in force is skipped with its reason rather than proposed. A Safe batch sends
    ///      every proposal in one transaction, and one the factory refuses would take all the others down with it
    ///      (CR-I38). `inForce` is zero only for a token never listed, which has nothing to compare against.
    function _withinSupplyBound(IIndexFactory factory, address token, uint256 inForce, uint256 proposed)
        private
        view
        returns (bool)
    {
        if (inForce == 0) return true;
        uint256 low = proposed < inForce ? proposed : inForce;
        uint256 high = proposed < inForce ? inForce : proposed;
        if (high / factory.MAX_SUPPLY_CHANGE() <= low) return true;
        console2.log(
            "skipped, the supply moves past MAX_SUPPLY_CHANGE from the one in force; revise it in steps", token
        );
        return false;
    }

    /// @dev The parts of the whitelist policy a script can check: a token with code and 6 to 18 decimals, no mint
    ///      currency as a component, a feed that answers, and a reference supply. Logs the token's symbol beside its
    ///      feed's own description, so an operator reading the run sees which pair each address really is and whether
    ///      it belongs to that token rather than trusting the entry (CR-L08), and the reference supply in whole tokens,
    ///      where a decimals slip shows.
    function _followsPolicy(address token, address feed, uint256 referenceSupply) private view returns (bool) {
        if (token == MainnetAddresses.USDC || token == MainnetAddresses.USDT) {
            console2.log("skipped, a mint currency is not a component", token);
            return false;
        }
        // The factory refuses a token without code, and a call to one would stop the whole run rather than be caught.
        if (token.code.length == 0) {
            console2.log("skipped, the token has no code", token);
            return false;
        }
        if (feed.code.length == 0) {
            console2.log("skipped, the entry names no feed with code", token, feed);
            return false;
        }
        try IAggregatorV3(feed).description() returns (string memory pair) {
            console2.log(string.concat(_symbolOf(token), " is priced by ", pair, ", feed"), feed);
        } catch {
            console2.log("skipped, the feed does not answer as an aggregator", token, feed);
            return false;
        }
        (bool answered, uint8 decimals) = _decimalsOf(token);
        if (!answered) {
            console2.log("skipped, the token reports no decimals", token);
            return false;
        }
        if (decimals < MIN_DECIMALS || decimals > MAX_DECIMALS) {
            console2.log("skipped, the whitelist policy needs 6 to 18 decimals", token, decimals);
            return false;
        }
        // The rule refuses zero as well; skipping here says why instead of logging a raw revert (CR-M01).
        if (referenceSupply == 0) {
            console2.log("skipped, every entry needs a reference supply", token);
            return false;
        }
        console2.log("reference supply in whole tokens", token, referenceSupply / 10 ** decimals);
        return true;
    }

    /// @dev `token`'s ERC-20 symbol for the log and safe mode's labels, or "?" when it has none that decodes as a
    ///      string: the symbol is optional in ERC-20, and some tokens return it as bytes32.
    function _symbolOf(address token) private view returns (string memory) {
        // A static call, so a token without the function, or one answering in another shape, cannot stop the run.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        // A string answer holds at least its offset and its length; anything shorter, a bytes32 among them, is not one.
        if (!ok || data.length < 2 * WORD) return "?";
        // Nor is an answer whose offset or length points past its end, which `abi.decode` refuses by reverting, and
        // that reverted the whole run (RT-25). The offset is checked first, so the length is read inside the answer.
        uint256 offset = _wordAt(data, 0);
        if (offset > data.length - WORD || _wordAt(data, offset) > data.length - WORD - offset) return "?";
        return abi.decode(data, (string));
    }

    /// @dev What `token.decimals()` answers, when it answers a uint8 at all. A static call whose answer is checked
    ///      before it is read, so a token without the function, or one answering in another shape, cannot stop the
    ///      run: decoding a `try` call's answer happens in the caller, where no `catch` reaches a failure.
    function _decimalsOf(address token) private view returns (bool answered, uint8 decimals) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        // A failed call, or an answer shorter than a word, reads as a word no uint8 fits.
        uint256 word = ok && data.length >= WORD ? _wordAt(data, 0) : type(uint256).max;
        answered = word <= type(uint8).max;
        if (answered) decimals = SafeCast.toUint8(word);
    }

    /// @dev Whether `token` now answers other decimals than the ones its pending proposal pinned, with the two logged
    ///      when it does. The factory refuses to execute such a proposal (RT-23); a token that answers none is left to
    ///      the rule's own check, which refuses it too.
    function _pinnedDecimalsMoved(IIndexFactory factory, address token) private view returns (bool) {
        uint8 pinned = factory.pendingTokenDecimals(token);
        (bool answered, uint8 decimals) = _decimalsOf(token);
        if (!answered || decimals == pinned) return false;
        console2.log("  pinned %s, now %s", uint256(pinned), uint256(decimals));
        return true;
    }

    /// @dev Whether `token` now answers other decimals than the factory recorded when its config came into force, with
    ///      the two logged when it does. The rule prices it with the record, a power of ten off, until a config for it
    ///      is executed again; the script skipped the config in force as already there, so the recourse had to be
    ///      built by hand (RT-22). A token that answers no decimals has nothing to record, and the rule refuses any
    ///      config for it, so it has not moved in this sense.
    function _decimalsMoved(IIndexFactory factory, address token) private view returns (bool) {
        uint8 recorded = factory.tokenDecimals(token);
        (bool answered, uint8 decimals) = _decimalsOf(token);
        if (!answered || decimals == recorded) return false;
        console2.log("the token's decimals moved; a config executed now records them and reprices it", token);
        console2.log("  recorded %s, now %s", uint256(recorded), uint256(decimals));
        return true;
    }

    /// @dev The word of `data` that starts at byte `at`, read big-endian; the caller keeps it inside `data`.
    function _wordAt(bytes memory data, uint256 at) private pure returns (uint256 word) {
        for (uint256 i = 0; i < WORD; ++i) {
            word = word << 8 | uint8(data[at + i]);
        }
    }

    /// @notice Any account, read-only. Reports and logs for every entry whether the token is listed, whether the config
    ///         in force is the entry's, the decimals the rule prices it with beside those it answers now, and any
    ///         pending proposal with its window, so nothing due expires unnoticed.
    /// @param factory The deployed factory.
    /// @param list Entries to report on.
    /// @return reports One report per entry, in entry order; the log lines say the same.
    function status(IIndexFactory factory, Entry[] memory list) public view returns (Report[] memory reports) {
        uint256 window = factory.PROPOSAL_WINDOW();
        reports = new Report[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            IIndexFactory.TokenConfig memory config = configFor(list[i]);
            IIndexFactory.TokenConfig memory current = factory.tokenConfig(token);
            Report memory report = reports[i];
            report.token = token;
            report.listed = factory.isWhitelisted(token);
            report.inForce = _sameConfig(current, config);
            report.eta = factory.listingEta(token);
            report.recordedDecimals = factory.tokenDecimals(token);
            (, report.liveDecimals) = _decimalsOf(token);
            console2.log(token, report.listed ? "listed" : "not listed");
            if (!report.inForce) console2.log("  the config in force is not the entry's");
            // The config fields can all match while the rule prices the token a power of ten off; propose and safe mode
            // then propose the config in force again, which records the new decimals (RT-22).
            if (current.feed != address(0) && report.liveDecimals != report.recordedDecimals) {
                console2.log(
                    "  decimals moved: the rule prices it at %s, the token answers %s (0 for no answer)",
                    uint256(report.recordedDecimals),
                    uint256(report.liveDecimals)
                );
            }
            if (report.eta == 0) continue;
            report.pendingIsListing = factory.pendingIsListing(token);
            report.pendingMatches = _sameConfig(factory.pendingTokenConfig(token), config);
            report.pendingDecimals = factory.pendingTokenDecimals(token);
            console2.log("  pending from %s until %s", report.eta, report.eta + window);
            console2.log(report.pendingIsListing ? "  a listing" : "  a config change");
            if (!report.pendingMatches) console2.log("  it differs from the entry");
            if (report.pendingDecimals != report.liveDecimals) {
                console2.log("  its token's decimals changed since it was proposed: it cannot be executed (RT-23)");
            }
        }
    }

    function _contains(address[] memory list, address token) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == token) return true;
        }
        return false;
    }

    function _sameConfig(IIndexFactory.TokenConfig memory a, IIndexFactory.TokenConfig memory b)
        private
        pure
        returns (bool)
    {
        return a.feed == b.feed && a.maxStaleness == b.maxStaleness && a.referenceSupply == b.referenceSupply;
    }
}
