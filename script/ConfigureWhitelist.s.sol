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

/// @notice Drives the two-step flow that lists tokens and sets their market-data configs. It never re-proposes a token
///         on its own: proposing is a separate, explicit run by the owner, so a listing the guardian cancelled stays
///         cancelled. A token the guardian delisted gets config changes only; it is listed again only when named in
///         RELIST. Execute mode runs only proposals whose pending config is exactly the entry's.
///
///   Propose, as a factory owner that is a key you hold, delegated under EIP-7702 or not (testnets and local forks; a
///   contract owner, such as the mainnet Safe, cannot sign, and propose mode then reverts with OwnerIsContract: use
///   safe mode below):
///     LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
///   Execute, from any account, between LISTING_DELAY and LISTING_DELAY + PROPOSAL_WINDOW later:
///     LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet --account deployer --sender <any account> --broadcast
///
///   Propose for an owner that is a Safe: log the `proposeListing` / `proposeConfig` calldata to sign in the Safe app,
///   one transaction per line, each to the factory with no value. Any account can run it, and nothing is broadcast:
///     LISTING_MODE=safe FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
///
/// Env:
///   LISTING_MODE  `propose`, `execute`, `safe`, or `status` (read-only: what is listed, pending and due, per entry).
///   FACTORY       Deployed IndexFactory.
///   WHITELIST     `default` for the mainnet list below (chain 1 only), or comma-separated entries
///                 `token:feed:maxStaleness[:referenceSupply]`. `feed` is the token's Chainlink-shaped USD aggregator,
///                 or a `CompositeFeed` over two of them. `maxStaleness` is the oldest answer the rule will price the
///                 token from, in seconds; the policy is the feed's heartbeat plus half an hour. `referenceSupply` is
///                 in the token's raw units (with its decimals); an empty or missing one means on-chain supply.
///   WBTC_FEED     Required with WHITELIST=default: the deployed `CompositeFeed` over BTC/USD and WBTC/BTC that
///                 `Deploy` logs. It is checked against both legs before it is proposed.
///   RELIST        Optional. Comma-separated delisted tokens that propose and safe mode may list again; any other
///                 delisted token only gets config changes.
contract ConfigureWhitelist is Script {
    /// @notice A token and the config to list it with.
    /// @param token Token to list or configure.
    /// @param feed The token's USD price feed, read as an {IAggregatorV3}.
    /// @param maxStaleness Oldest answer the rule will price the token from, in seconds.
    /// @param referenceSupply Supply in the token's raw units, or 0 for on-chain supply.
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
    struct Report {
        address token;
        bool listed;
        bool inForce;
        uint256 eta;
        bool pendingIsListing;
        bool pendingMatches;
    }

    /// @notice Fewest and most decimals the whitelist policy accepts for a component.
    uint8 public constant MIN_DECIMALS = 6;
    uint8 public constant MAX_DECIMALS = 18;

    /// @dev Positions of the optional-length fields in a WHITELIST entry; token and feed come first.
    uint256 private constant MAX_STALENESS_FIELD = 2;
    uint256 private constant REFERENCE_SUPPLY_FIELD = 3;

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
    /// @notice A WHITELIST entry has fewer than three or more than four fields.
    error MalformedEntry(string entry);
    /// @notice WBTC_FEED is not a CompositeFeed over BTC/USD and WBTC/BTC with their policy staleness bounds.
    error WrongCompositeFeed(address feed);
    /// @notice Propose mode needs an owner that can sign transactions, and this factory's owner is a contract (a Safe
    ///         on mainnet). Use `LISTING_MODE=safe` and submit the calldata it logs from the owner.
    error OwnerIsContract(address owner);

    /// @notice Default mainnet components, from `MainnetAddresses`. Reference supplies are CoinGecko's circulating
    ///         supplies (propose a config change when they drift) and staleness bounds each feed's heartbeat plus half
    ///         an hour; `MainnetAddresses` dates both and names every feed's heartbeat. WETH, WBTC and wrapped SOL
    ///         count the whole ether, bitcoin and solana supply, because their on-chain supply is only the wrapped or
    ///         bridged float; wstETH counts its own, because each one is a claim on staked ether rather than a copy of
    ///         a supply held elsewhere. WBTC has no USD feed of its own and is priced through `wbtcFeed`, a
    ///         `CompositeFeed` over BTC/USD and WBTC/BTC. WBTC can be paused by its custodian, wrapped SOL depends on
    ///         the Wormhole bridge and wstETH on Lido, so the app must label all three; an index holding both WETH and
    ///         wstETH holds two claims on ether, which it must label too.
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
    ///         passes to the two feeds it is supposed to multiply.
    /// @param feed The WBTC_FEED value.
    function checkWbtcFeed(address feed) public view {
        if (feed.code.length == 0) revert WrongCompositeFeed(feed);
        try CompositeFeed(feed).FEED_A() returns (IAggregatorV3 a) {
            if (address(a) != MainnetAddresses.BTC_USD_FEED) revert WrongCompositeFeed(feed);
        } catch {
            revert WrongCompositeFeed(feed);
        }
        if (address(CompositeFeed(feed).FEED_B()) != MainnetAddresses.WBTC_BTC_FEED) revert WrongCompositeFeed(feed);
        if (CompositeFeed(feed).MAX_AGE_A() != MainnetAddresses.STALENESS_1H) revert WrongCompositeFeed(feed);
        if (CompositeFeed(feed).MAX_AGE_B() != MainnetAddresses.STALENESS_24H) revert WrongCompositeFeed(feed);
    }

    /// @notice Reads FACTORY, WHITELIST, RELIST and LISTING_MODE from the environment and runs that mode.
    function run() external {
        IIndexFactory factory = IIndexFactory(vm.envAddress("FACTORY"));
        Entry[] memory list = resolveList(vm.envString("WHITELIST"), vm.envOr("WBTC_FEED", address(0)));
        address[] memory relist = parseAddresses(vm.envOr("RELIST", string("")));
        string memory mode = vm.envString("LISTING_MODE");
        if (ScriptUtils.same(mode, "propose")) {
            propose(factory, list, relist);
        } else if (ScriptUtils.same(mode, "execute")) {
            execute(factory, list);
        } else if (ScriptUtils.same(mode, "safe")) {
            bytes[] memory calls = safeCalldata(factory, list, relist);
            console2.log("Safe transactions to the factory, value 0:", address(factory));
            for (uint256 i = 0; i < calls.length; ++i) {
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

    /// @notice `default` means the mainnet list and is only accepted on chain 1; anything else is parsed as
    ///         comma-separated entries. The default list needs `wbtcFeed`, which is checked before it is used.
    /// @param raw The WHITELIST value.
    /// @param wbtcFeed The WBTC_FEED value; only read for the default list.
    /// @return list The entries, in order.
    function resolveList(string memory raw, address wbtcFeed) public view returns (Entry[] memory list) {
        if (ScriptUtils.same(raw, "default")) {
            if (block.chainid != 1) revert DefaultListOnlyOnMainnet();
            checkWbtcFeed(wbtcFeed);
            return defaultMainnetList(wbtcFeed);
        }
        string[] memory parts = vm.split(raw, ",");
        list = new Entry[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            list[i] = parseEntry(vm.trim(parts[i]));
        }
    }

    /// @notice Parses `token:feed:maxStaleness[:referenceSupply]`.
    /// @param raw One entry, without surrounding spaces.
    /// @return entry The parsed entry; an empty or missing reference supply is 0.
    function parseEntry(string memory raw) public pure returns (Entry memory entry) {
        string[] memory fields = vm.split(raw, ":");
        if (fields.length <= MAX_STALENESS_FIELD || fields.length > REFERENCE_SUPPLY_FIELD + 1) {
            revert MalformedEntry(raw);
        }
        entry.token = vm.parseAddress(fields[0]);
        entry.feed = vm.parseAddress(fields[1]);
        entry.maxStaleness = SafeCast.toUint32(vm.parseUint(fields[MAX_STALENESS_FIELD]));
        if (fields.length > REFERENCE_SUPPLY_FIELD && bytes(fields[REFERENCE_SUPPLY_FIELD]).length != 0) {
            entry.referenceSupply = vm.parseUint(fields[REFERENCE_SUPPLY_FIELD]);
        }
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

    /// @notice Owner only. For every entry with nothing pending, proposes a listing for a token that was never listed
    ///         or is named in `relist`, and a config change for any other token whose config differs from the entry. A
    ///         token the guardian delisted is therefore never listed again by a routine run. An expired proposal is
    ///         proposed again. An entry the rule rejects is skipped and the reason logged.
    ///         Reverts with OwnerIsContract when the owner cannot sign, which is always the case on mainnet: safe mode
    ///         logs the same calls as calldata instead.
    /// @param factory The deployed factory; the broadcasting key must be its owner.
    /// @param list Entries to propose.
    /// @param relist Delisted tokens that may be listed again.
    function propose(IIndexFactory factory, Entry[] memory list, address[] memory relist) public {
        address factoryOwner = Ownable(address(factory)).owner();
        // A key that delegated its account under EIP-7702 has code and still signs, so it is not a contract owner.
        bytes memory ownerCode = factoryOwner.code;
        if (ownerCode.length != 0 && !ScriptUtils.isDelegatedAccount(ownerCode)) revert OwnerIsContract(factoryOwner);
        IIndexRule rule = IIndexRule(factory.RULE());
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            IIndexFactory.TokenConfig memory config = configFor(list[i]);
            Action action = _action(factory, rule, token, config, relist);
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
    ///         calldata of every entry `propose` would submit, each to be sent to the factory with no value.
    /// @param factory The deployed factory, owned by the Safe.
    /// @param list Entries to propose.
    /// @param relist Delisted tokens that may be listed again.
    /// @return calls One call per proposal, in entry order.
    function safeCalldata(IIndexFactory factory, Entry[] memory list, address[] memory relist)
        public
        view
        returns (bytes[] memory calls)
    {
        IIndexRule rule = IIndexRule(factory.RULE());
        bytes[] memory all = new bytes[](list.length);
        uint256 count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            IIndexFactory.TokenConfig memory config = configFor(list[i]);
            Action action = _action(factory, rule, token, config, relist);
            if (action == Action.List) {
                all[count++] = abi.encodeCall(IIndexFactory.proposeListing, (token, config));
            } else if (action == Action.ChangeConfig) {
                all[count++] = abi.encodeCall(IIndexFactory.proposeConfig, (token, config));
            }
        }
        calls = new bytes[](count);
        for (uint256 i = 0; i < count; ++i) {
            calls[i] = all[i];
        }
    }

    /// @notice Any account. Executes every due proposal whose pending config is exactly the entry's config, and skips
    ///         everything else with the reason logged: nothing pending, not ready, expired, or a pending config the
    ///         entry does not name.
    /// @param factory The deployed factory.
    /// @param list Entries whose proposals to execute.
    function execute(IIndexFactory factory, Entry[] memory list) public {
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
        }
        vm.stopBroadcast();
    }

    /// @dev Skip, with the reason logged, for an entry that is pending, already in force, delisted with an unchanged
    ///      config and not named in `relist`, or rejected by the rule. Otherwise a listing for a token never listed or
    ///      named in `relist`, and a config change for any other token.
    function _action(
        IIndexFactory factory,
        IIndexRule rule,
        address token,
        IIndexFactory.TokenConfig memory config,
        address[] memory relist
    ) private view returns (Action) {
        uint256 eta = factory.listingEta(token);
        if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
            // A config-only proposal never whitelists, so it cannot carry out a relisting however long it waits.
            // Reporting it as "already pending" left the operator believing RELIST had been acted on (DA-20).
            if (!factory.isWhitelisted(token) && _contains(relist, token) && !factory.pendingIsListing(token)) {
                console2.log("skipped, RELIST needs a listing but a config change is pending; cancel it first", token);
            } else if (_sameConfig(factory.pendingTokenConfig(token), config)) {
                console2.log("already pending", token);
            } else {
                console2.log("skipped, a different config is pending; cancel it first", token);
            }
            return Action.Skip;
        }
        IIndexFactory.TokenConfig memory current = factory.tokenConfig(token);
        bool listed = factory.isWhitelisted(token);
        // Every config in force names a feed, so an empty one means the token was never listed.
        bool configured = current.feed != address(0);
        Action action = Action.List;
        if (configured && (listed || !_contains(relist, token))) {
            if (_sameConfig(current, config)) {
                if (!listed) console2.log("skipped, delisted; name it in RELIST to list it again", token);
                return Action.Skip;
            }
            action = Action.ChangeConfig;
        }
        if (!_followsPolicy(token, config.feed, config.referenceSupply)) return Action.Skip;
        try rule.checkConfig(token, config) {
            return action;
        } catch (bytes memory reason) {
            console2.log("skipped, the rule rejects this config", token);
            console2.logBytes(reason);
            return Action.Skip;
        }
    }

    /// @dev The parts of the whitelist policy a script can check: 6 to 18 decimals, no mint currency as a component,
    ///      and a feed that answers. Logs the feed's own description, so an operator reading the run sees which pair
    ///      each address really is rather than trusting the entry, and a reference supply in whole tokens, where a
    ///      decimals slip shows.
    function _followsPolicy(address token, address feed, uint256 referenceSupply) private view returns (bool) {
        if (token == MainnetAddresses.USDC || token == MainnetAddresses.USDT) {
            console2.log("skipped, a mint currency is not a component", token);
            return false;
        }
        if (feed.code.length == 0) {
            console2.log("skipped, the entry names no feed with code", token, feed);
            return false;
        }
        try IAggregatorV3(feed).description() returns (string memory pair) {
            console2.log("feed", feed, pair);
        } catch {
            console2.log("skipped, the feed does not answer as an aggregator", token, feed);
            return false;
        }
        uint8 decimals = 0;
        try IERC20Metadata(token).decimals() returns (uint8 value) {
            decimals = value;
        } catch {
            console2.log("skipped, the token reports no decimals", token);
            return false;
        }
        if (decimals < MIN_DECIMALS || decimals > MAX_DECIMALS) {
            console2.log("skipped, the whitelist policy needs 6 to 18 decimals", token, decimals);
            return false;
        }
        if (referenceSupply != 0) {
            console2.log("reference supply in whole tokens", token, referenceSupply / 10 ** decimals);
        }
        return true;
    }

    /// @notice Any account, read-only. Reports and logs for every entry whether the token is listed, whether the config
    ///         in force is the entry's, and any pending proposal with its window, so nothing due expires unnoticed.
    /// @param factory The deployed factory.
    /// @param list Entries to report on.
    /// @return reports One report per entry, in entry order; the log lines say the same.
    function status(IIndexFactory factory, Entry[] memory list) public view returns (Report[] memory reports) {
        uint256 window = factory.PROPOSAL_WINDOW();
        reports = new Report[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            IIndexFactory.TokenConfig memory config = configFor(list[i]);
            Report memory report = reports[i];
            report.token = token;
            report.listed = factory.isWhitelisted(token);
            report.inForce = _sameConfig(factory.tokenConfig(token), config);
            report.eta = factory.listingEta(token);
            console2.log(token, report.listed ? "listed" : "not listed");
            if (!report.inForce) console2.log("  the config in force is not the entry's");
            if (report.eta == 0) continue;
            report.pendingIsListing = factory.pendingIsListing(token);
            report.pendingMatches = _sameConfig(factory.pendingTokenConfig(token), config);
            console2.log("  pending from %s until %s", report.eta, report.eta + window);
            console2.log(report.pendingIsListing ? "  a listing" : "  a config change");
            if (!report.pendingMatches) console2.log("  it differs from the entry");
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
