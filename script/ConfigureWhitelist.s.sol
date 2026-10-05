// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IHybridIndexFactory} from "../src/interfaces/IHybridIndexFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Drives the two timelocked flows the factory owner runs: listing tokens, and the weekly batch of reference
///         supplies. It never lists a token on its own: a token never listed gets a listing proposal only when named in
///         LIST, and one the guardian delisted only when named in RELIST. Nothing on chain records that the guardian
///         cancelled a first listing, so without LIST a routine run would propose the vetoed listing again (RT-06).
///         Execute modes never propose, and run only proposals that are exactly what the entries say.
///
///   Listings, for an owner that is a key you hold (testnets and local forks; a contract owner cannot sign, and this
///   reverts with OwnerIsContract: use `safe` below):
///     LISTING_MODE=propose FACTORY=0x... WHITELIST=<entries> LIST=<tokens> forge script \
///       script/ConfigureWhitelist.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
///   Listings for a Safe owner: log each `proposeListing` calldata to sign in the Safe app, each to the factory with no
///   value, under a line naming the token's symbol and address. Nothing is broadcast:
///     LISTING_MODE=safe FACTORY=0x... WHITELIST=default LIST=all forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet
///   The weekly supply batch, one `proposeSupplies` call with every entry whose supply differs from the one in force,
///   sorted by address; `supplies` broadcasts it from an owner key, `supplies-safe` logs its calldata for a Safe:
///     LISTING_MODE=supplies-safe FACTORY=0x... WHITELIST=<this week's entries> forge script \
///       script/ConfigureWhitelist.s.sol --rpc-url mainnet
///   Execute, from any account, between LISTING_DELAY and LISTING_DELAY + PROPOSAL_WINDOW later: `execute` runs every
///   due listing whose supply is the entry's; `execute-supplies` runs the due batch if every one of its supplies is the
///   entry's.
///
/// Env:
///   LISTING_MODE  `propose`, `safe`, `execute`, `supplies`, `supplies-safe`, `execute-supplies`, or `status`
///                 (read-only: what is listed, pending and due, per entry).
///   FACTORY       Deployed IndexFactory.
///   WHITELIST     `default` for the mainnet list below (chain 1 only), or comma-separated entries
///                 `token:referenceSupply`, both required. `referenceSupply` is in the token's raw units (with its
///                 decimals) and is the supply of what the token represents; nothing reads a supply live (CR-M01).
///   LIST          Optional. Tokens never listed that propose and safe mode may propose a listing for: comma-separated
///                 addresses, or `all` for every entry of WHITELIST. A token it does not name is skipped with its
///                 reason, which keeps a listing the guardian cancelled cancelled (RT-06). Leave it unset on a routine
///                 run.
///   RELIST        Optional. Comma-separated delisted tokens that propose and safe mode may list again.
contract ConfigureWhitelist is Script {
    /// @notice A token and its reference supply.
    /// @param token Token to list, or whose supply to revise.
    /// @param referenceSupply Reference supply in the token's raw units; required and non-zero (CR-M01).
    struct Entry {
        address token;
        uint256 referenceSupply;
    }

    /// @notice What `status` found for one entry.
    /// @param token The entry's token.
    /// @param listed Whether it is whitelisted.
    /// @param inForce Whether the reference supply in force is the entry's.
    /// @param eta When its pending listing becomes executable, or 0 when none is pending; it expires
    ///        `PROPOSAL_WINDOW` later.
    /// @param pendingMatches Whether the pending listing carries the entry's supply.
    /// @param inBatch Whether the live supply batch names the token.
    struct Report {
        address token;
        bool listed;
        bool inForce;
        uint256 eta;
        bool pendingMatches;
        bool inBatch;
    }

    /// @notice Fewest and most decimals the whitelist policy accepts for a component.
    uint8 public constant MIN_DECIMALS = 6;
    uint8 public constant MAX_DECIMALS = 18;

    /// @dev Fields in a WHITELIST entry.
    uint256 private constant ENTRY_FIELDS = 2;

    uint256 private constant WAD = 1e18;

    /// @notice LISTING_MODE is not one of the modes above.
    error UnknownMode(string mode);
    /// @notice WHITELIST=default off chain 1.
    error DefaultListOnlyOnMainnet();
    /// @notice A WHITELIST entry does not have exactly two fields, or leaves its reference supply empty.
    error MalformedEntry(string entry);
    /// @notice A broadcasting mode needs an owner that can sign transactions, and this factory's owner is a contract (a
    ///         Safe on mainnet). Use `safe` or `supplies-safe` and submit the calldata it logs from the owner.
    error OwnerIsContract(address owner);
    /// @notice The entries name `token` twice. Safe mode decides every entry against the same state, so it emitted a
    ///         proposal for each copy, and the second reverted the whole Safe batch (RT-24).
    error DuplicateEntry(address token);
    /// @notice No entry's supply differs from the one in force within one step, so there is no batch to propose.
    error NothingToBatch();
    /// @notice A supply batch is still live until `deadline`; execute or cancel it before proposing the next (SA-05).
    error BatchStillLive(uint256 deadline);

    /// @notice Default mainnet components, from `MainnetAddresses`: the Stage A list, the floor list's Ethereum tokens
    ///         that pass the liquidity screen. Each carries a dated reference supply. WETH and WBTC count the whole
    ///         ether and bitcoin supply, because their on-chain supply is only the wrapped float. WBTC can be paused by
    ///         its custodian, so the app must label it.
    /// @return list WETH, WBTC, LINK and UNI, in that order.
    function defaultMainnetList() public pure returns (Entry[] memory list) {
        list = new Entry[](4);
        list[0] = Entry({token: MainnetAddresses.WETH, referenceSupply: MainnetAddresses.ETH_SUPPLY});
        list[1] = Entry({token: MainnetAddresses.WBTC, referenceSupply: MainnetAddresses.BTC_SUPPLY});
        list[2] = Entry({token: MainnetAddresses.LINK, referenceSupply: MainnetAddresses.LINK_SUPPLY});
        list[3] = Entry({token: MainnetAddresses.UNI, referenceSupply: MainnetAddresses.UNI_SUPPLY});
    }

    /// @notice Reads FACTORY, WHITELIST, LIST, RELIST and LISTING_MODE from the environment and runs that mode.
    function run() external {
        IIndexFactory factory = IIndexFactory(vm.envAddress("FACTORY"));
        Entry[] memory list = resolveList(vm.envString("WHITELIST"));
        address[] memory firstListings = resolveFirstListings(vm.envOr("LIST", string("")), list);
        address[] memory relist = parseAddresses(vm.envOr("RELIST", string("")));
        string memory mode = vm.envString("LISTING_MODE");
        if (ScriptUtils.same(mode, "propose")) {
            propose(factory, list, firstListings, relist);
        } else if (ScriptUtils.same(mode, "safe")) {
            (bytes[] memory calls, string[] memory labels) = safeCalldata(factory, list, firstListings, relist);
            console2.log("Safe transactions to the factory, value 0:", address(factory));
            for (uint256 i = 0; i < calls.length; ++i) {
                // Which token each call lists: among lines of hex a listing reads as one more routine call (RT-06).
                console2.log(labels[i]);
                console2.logBytes(calls[i]);
            }
        } else if (ScriptUtils.same(mode, "execute")) {
            execute(factory, list);
        } else if (ScriptUtils.same(mode, "supplies")) {
            proposeSupplies(factory, list);
        } else if (ScriptUtils.same(mode, "supplies-safe")) {
            console2.log("Safe transaction to the factory, value 0:", address(factory));
            console2.logBytes(supplyCalldata(factory, list));
        } else if (ScriptUtils.same(mode, "execute-supplies")) {
            executeSupplies(factory, list);
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
    ///         comma-separated addresses, so an empty value names none and no listing is proposed unless the operator
    ///         asks for it (RT-06).
    /// @param raw The LIST value.
    /// @param list This run's entries.
    /// @return tokens Tokens never listed that may be proposed for a listing.
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
    ///         comma-separated entries. Reverts DuplicateEntry for a list that names a token twice, whatever mode would
    ///         run on it (RT-24).
    /// @param raw The WHITELIST value.
    /// @return list The entries, in order.
    function resolveList(string memory raw) public view returns (Entry[] memory list) {
        if (ScriptUtils.same(raw, "default")) {
            if (block.chainid != 1) revert DefaultListOnlyOnMainnet();
            list = defaultMainnetList();
        } else {
            string[] memory parts = vm.split(raw, ",");
            list = new Entry[](parts.length);
            for (uint256 i = 0; i < parts.length; ++i) {
                list[i] = parseEntry(vm.trim(parts[i]));
            }
        }
        _requireUnique(list);
    }

    /// @notice Parses `token:referenceSupply`. Both fields are required (CR-L03).
    /// @param raw One entry, without surrounding spaces.
    /// @return entry The parsed entry.
    function parseEntry(string memory raw) public pure returns (Entry memory entry) {
        string[] memory fields = vm.split(raw, ":");
        if (fields.length != ENTRY_FIELDS || bytes(fields[1]).length == 0) revert MalformedEntry(raw);
        entry.token = vm.parseAddress(fields[0]);
        entry.referenceSupply = vm.parseUint(fields[1]);
    }

    // ---------------------------------------------------------------------
    // Listings
    // ---------------------------------------------------------------------

    /// @notice Owner only. Proposes a listing for every entry whose token is never listed and named in `firstListings`,
    ///         or delisted and named in `relist`, with nothing pending for it; anything else is skipped with its reason
    ///         logged. Reverts OwnerIsContract when the owner cannot sign, which is always the case on mainnet.
    /// @param factory The deployed factory; the broadcasting key must be its owner.
    /// @param list Entries to propose.
    /// @param firstListings Tokens never listed that may get a listing (LIST).
    /// @param relist Delisted tokens that may be listed again (RELIST).
    function propose(
        IIndexFactory factory,
        Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist
    ) public {
        _requireUnique(list);
        _requireSigningOwner(factory);
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            if (!_shouldList(factory, list[i], firstListings, relist)) continue;
            factory.proposeListing(list[i].token, listingSupply(factory, list[i]));
            console2.log("proposed a listing", list[i].token);
        }
        vm.stopBroadcast();
    }

    /// @notice Any account, nothing is broadcast. For an owner that is a Safe: the `proposeListing` calldata of every
    ///         entry `propose` would submit, each to be sent to the factory with no value, and the line safe mode
    ///         prints above each. Reverts DuplicateEntry for a list that names a token twice (RT-24).
    /// @param factory The deployed factory, owned by the Safe.
    /// @param list Entries to propose.
    /// @param firstListings Tokens never listed that may get a listing (LIST).
    /// @param relist Delisted tokens that may be listed again (RELIST).
    /// @return calls One call per proposal, in entry order.
    /// @return labels For each call, `proposeListing`, the token's symbol and its address (RT-06).
    function safeCalldata(
        IIndexFactory factory,
        Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist
    ) public view returns (bytes[] memory calls, string[] memory labels) {
        _requireUnique(list);
        bool[] memory chosen = new bool[](list.length);
        uint256 count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            chosen[i] = _shouldList(factory, list[i], firstListings, relist);
            if (chosen[i]) ++count;
        }
        calls = new bytes[](count);
        labels = new string[](count);
        count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            if (!chosen[i]) continue;
            calls[count] =
                abi.encodeCall(IIndexFactory.proposeListing, (list[i].token, listingSupply(factory, list[i])));
            labels[count] =
                string.concat("proposeListing ", ScriptUtils.symbolOf(list[i].token), " ", vm.toString(list[i].token));
            ++count;
        }
    }

    /// @notice Any account. Executes every due listing whose pending supply is exactly the entry's, and skips everything
    ///         else with the reason logged: nothing pending, not ready, expired, or a pending supply the entry does not
    ///         name.
    /// @param factory The deployed factory.
    /// @param list Entries whose listings to execute.
    function execute(IIndexFactory factory, Entry[] memory list) public {
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            uint256 eta = factory.listingEta(token);
            if (eta == 0) continue; // nothing is pending for this token
            if (factory.pendingReferenceSupply(token) != listingSupply(factory, list[i])) {
                console2.log("not executed, the pending supply differs from the entry", token);
            } else if (block.timestamp < eta) {
                console2.log("not ready yet", token);
            } else if (block.timestamp > eta + factory.PROPOSAL_WINDOW()) {
                console2.log("expired, propose again", token);
            } else {
                factory.executeListing(token);
                console2.log("executed", token);
            }
        }
        vm.stopBroadcast();
    }

    /// @dev Whether `entry` gets a listing proposal: nothing pending for it, never listed and named in LIST or delisted
    ///      and named in RELIST, not in the live batch, and inside the whitelist policy. A relisting proposes the supply
    ///      in force, whatever the entry says (SA-02). The reason is logged for everything skipped, and the factory would refuse each of those, which in
    ///      a Safe batch takes every other proposal down with it (CR-I38).
    function _shouldList(
        IIndexFactory factory,
        Entry memory entry,
        address[] memory firstListings,
        address[] memory relist
    ) private view returns (bool) {
        address token = entry.token;
        if (factory.isWhitelisted(token)) {
            // A listed token's supply changes only in a batch: `supplies` mode.
            return false;
        }
        uint256 eta = factory.listingEta(token);
        if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
            console2.log(
                factory.pendingReferenceSupply(token) == listingSupply(factory, entry)
                    ? "already pending"
                    : "skipped, a different listing is pending; cancel it first",
                token
            );
            return false;
        }
        if (_isVaultToken(factory, token)) {
            // proposeListing refuses a token without code; a vault token is listed by its chain and id.
            console2.log("skipped, a vault token: list it with HybridIndexFactory.proposeVaultListing", token);
            return false;
        }
        uint256 inForce = factory.referenceSupply(token);
        if (inForce == 0 && !_contains(firstListings, token)) {
            console2.log("skipped, never listed; name it in LIST to propose its listing", token);
            return false;
        }
        if (inForce != 0 && !_contains(relist, token)) {
            console2.log("skipped, delisted; name it in RELIST to list it again", token);
            return false;
        }
        if (_inLiveBatch(factory, token)) {
            console2.log("skipped, the pending supply batch names it; relist it once the batch is gone", token);
            return false;
        }
        if (!_followsPolicy(factory, token, listingSupply(factory, entry))) return false;
        if (inForce != 0 && inForce != entry.referenceSupply) {
            console2.log("relisted at the supply in force; supplies mode revises it once it is listed (SA-02)", token);
        }
        return true;
    }

    /// @notice The supply a listing of `entry` proposes: the entry's for a first listing, and the one in force for a
    ///         relisting, which the factory requires; a batch then revises it (SA-02).
    /// @param factory The deployed factory.
    /// @param entry The entry to list.
    /// @return The supply to propose.
    function listingSupply(IIndexFactory factory, Entry memory entry) public view returns (uint256) {
        uint256 inForce = factory.referenceSupply(entry.token);
        return inForce != 0 ? inForce : entry.referenceSupply;
    }

    /// @dev Whether the live supply batch names `token`, whose listing the factory refuses (TokenInBatch) until the batch
    ///      executes, is cancelled or expires (DA-20).
    function _inLiveBatch(IIndexFactory factory, address token) private view returns (bool) {
        if (!factory.suppliesPending()) return false;
        // forge-lint: disable-next-line(unused-return) only the batch's tokens matter here
        (,, address[] memory batch,) = factory.pendingSupplies();
        return _contains(batch, token);
    }

    // ---------------------------------------------------------------------
    // Supply batches
    // ---------------------------------------------------------------------

    /// @notice The weekly batch: every entry whose token carries a supply that differs from the entry's, within one step
    ///         of it and inside the policy, sorted by address as the factory requires. Entries beyond one step are
    ///         skipped with the reason logged: a revision larger than the step goes in several weekly steps (CR-I38).
    ///         Reverts NothingToBatch when no entry qualifies, and BatchStillLive while another batch is live, which the
    ///         factory would refuse and whose supplies are about to replace the ones this batch is measured from.
    /// @param factory The deployed factory.
    /// @param list This week's entries.
    /// @return tokens The batch's tokens, ascending.
    /// @return supplies Their new reference supplies, in the same order.
    function supplyBatch(IIndexFactory factory, Entry[] memory list)
        public
        view
        returns (address[] memory tokens, uint256[] memory supplies)
    {
        _requireUnique(list);
        if (factory.suppliesPending()) {
            // forge-lint: disable-next-line(unused-return) only the live batch's eta matters here
            (, uint256 eta,,) = factory.pendingSupplies();
            revert BatchStillLive(eta + factory.PROPOSAL_WINDOW());
        }
        Entry[] memory sorted = _sorted(list);
        bool[] memory chosen = new bool[](sorted.length);
        uint256 count = 0;
        for (uint256 i = 0; i < sorted.length; ++i) {
            chosen[i] = _shouldRevise(factory, sorted[i]);
            if (chosen[i]) ++count;
        }
        if (count == 0) revert NothingToBatch();
        tokens = new address[](count);
        supplies = new uint256[](count);
        count = 0;
        for (uint256 i = 0; i < sorted.length; ++i) {
            if (!chosen[i]) continue;
            (tokens[count], supplies[count]) = (sorted[i].token, sorted[i].referenceSupply);
            ++count;
        }
    }

    /// @notice The `proposeSupplies` calldata of {supplyBatch}, to send to the factory from a Safe with no value.
    function supplyCalldata(IIndexFactory factory, Entry[] memory list) public view returns (bytes memory) {
        (address[] memory tokens, uint256[] memory supplies) = supplyBatch(factory, list);
        return abi.encodeCall(IIndexFactory.proposeSupplies, (tokens, supplies));
    }

    /// @notice Owner only. Proposes {supplyBatch}. Reverts OwnerIsContract when the owner cannot sign.
    function proposeSupplies(IIndexFactory factory, Entry[] memory list) public {
        _requireSigningOwner(factory);
        (address[] memory tokens, uint256[] memory supplies) = supplyBatch(factory, list);
        vm.startBroadcast();
        factory.proposeSupplies(tokens, supplies);
        vm.stopBroadcast();
        console2.log("proposed a supply batch of tokens:", tokens.length);
    }

    /// @notice Any account. Executes the pending supply batch if it is due and every one of its supplies is the one the
    ///         entries give for its token; otherwise logs why not and executes nothing.
    /// @param factory The deployed factory.
    /// @param list The entries the batch was proposed from.
    function executeSupplies(IIndexFactory factory, Entry[] memory list) public {
        (uint256 batchId, uint256 eta, address[] memory tokens, uint256[] memory supplies) = factory.pendingSupplies();
        if (eta == 0) {
            console2.log("no supply batch is pending");
            return;
        }
        console2.log("supply batch", batchId);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (bool found, uint256 supply) = _entrySupply(list, tokens[i]);
            if (!found || supply != supplies[i]) {
                console2.log("not executed, the batch differs from the entries at", tokens[i]);
                return;
            }
        }
        if (block.timestamp < eta) {
            console2.log("not ready yet, executable from", eta);
        } else if (block.timestamp > eta + factory.PROPOSAL_WINDOW()) {
            console2.log("expired, propose it again");
        } else {
            vm.startBroadcast();
            factory.executeSupplies();
            vm.stopBroadcast();
            console2.log("executed the supply batch of tokens:", tokens.length);
        }
    }

    /// @dev Whether `entry` belongs in this week's batch: the token carries a supply other than the entry's, has no live
    ///      listing, and the new one is inside the policy and within one step.
    function _shouldRevise(IIndexFactory factory, Entry memory entry) private view returns (bool) {
        address token = entry.token;
        uint256 inForce = factory.referenceSupply(token);
        if (inForce == 0) {
            console2.log("skipped, never listed; list it first", token);
            return false;
        }
        if (inForce == entry.referenceSupply) return false;
        uint256 eta = factory.listingEta(token);
        if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
            console2.log("skipped, a listing is pending for it", token);
            return false;
        }
        return _followsPolicy(factory, token, entry.referenceSupply)
            && _withinStep(factory, token, inForce, entry.referenceSupply);
    }

    /// @dev The factory's step, applied here so an entry that moves a supply further is skipped with its reason rather
    ///      than proposed and refused (CR-I38).
    function _withinStep(IIndexFactory factory, address token, uint256 inForce, uint256 proposed)
        private
        view
        returns (bool)
    {
        uint256 allowance = inForce * factory.MAX_SUPPLY_STEP() / WAD;
        if (proposed <= inForce + allowance && proposed + allowance >= inForce) return true;
        console2.log("skipped, the supply moves more than MAX_SUPPLY_STEP; revise it in weekly steps", token);
        return false;
    }

    function _entrySupply(Entry[] memory list, address token) private pure returns (bool found, uint256 supply) {
        for (uint256 i = 0; i < list.length && !found; ++i) {
            found = list[i].token == token;
            if (found) supply = list[i].referenceSupply;
        }
    }

    /// @dev `list` sorted by token address, ascending (insertion sort; a batch names a handful of tokens).
    function _sorted(Entry[] memory list) private pure returns (Entry[] memory sorted) {
        sorted = new Entry[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            Entry memory entry = list[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1].token > entry.token) {
                sorted[j] = sorted[j - 1];
                --j;
            }
            sorted[j] = entry;
        }
    }

    // ---------------------------------------------------------------------
    // Shared checks
    // ---------------------------------------------------------------------

    function _requireSigningOwner(IIndexFactory factory) private view {
        address factoryOwner = Ownable(address(factory)).owner();
        // A key that delegated its account under EIP-7702 has code and still signs, so it is not a contract owner.
        bytes memory ownerCode = factoryOwner.code;
        if (ownerCode.length != 0 && !ScriptUtils.isDelegatedAccount(ownerCode)) revert OwnerIsContract(factoryOwner);
    }

    /// @dev Reverts DuplicateEntry at the first token `list` names twice (RT-24).
    function _requireUnique(Entry[] memory list) private pure {
        for (uint256 i = 1; i < list.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (list[j].token == list[i].token) revert DuplicateEntry(list[i].token);
            }
        }
    }

    /// @dev The parts of the whitelist policy a script can check: a token with code and 6 to 18 decimals, no mint
    ///      currency as a component, and a reference supply from 1 to the factory's MAX_SUPPLY. Logs the token's
    ///      symbol and the supply in whole tokens, where a decimals slip shows.
    function _followsPolicy(IIndexFactory factory, address token, uint256 referenceSupply) private view returns (bool) {
        if (referenceSupply == 0 || referenceSupply > factory.MAX_SUPPLY()) {
            console2.log("skipped, the reference supply must be from 1 to MAX_SUPPLY", token);
            return false;
        }
        if (_isVaultToken(factory, token)) {
            // A coin held in a vault on its own chain: an id with no code here, so no ERC-20 check applies. Its decimals
            // are the chain's native unit's, which the reference supply is written in.
            console2.log("vault token reference supply in its chain's smallest unit", referenceSupply);
            return true;
        }
        if (token == MainnetAddresses.USDC || token == MainnetAddresses.USDT) {
            console2.log("skipped, a mint currency is not a component", token);
            return false;
        }
        // The factory refuses a token without code, and a call to one would stop the whole run rather than be caught.
        if (token.code.length == 0) {
            console2.log("skipped, the token has no code", token);
            return false;
        }
        (bool answered, uint8 decimals) = ScriptUtils.decimalsOf(token);
        if (!answered) {
            console2.log("skipped, the token reports no decimals", token);
            return false;
        }
        if (decimals < MIN_DECIMALS || decimals > MAX_DECIMALS) {
            console2.log("skipped, the whitelist policy needs 6 to 18 decimals", token, decimals);
            return false;
        }
        console2.log(
            string.concat(ScriptUtils.symbolOf(token), " reference supply in whole tokens"),
            referenceSupply / 10 ** decimals
        );
        return true;
    }

    /// @dev Whether `token` is a hybrid factory's vault token. A Stage A factory has no `vaultToken`, so the static call
    ///      fails and the answer is no.
    function _isVaultToken(IIndexFactory factory, address token) private view returns (bool) {
        bytes memory query = abi.encodeCall(IHybridIndexFactory.vaultToken, (token));
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = address(factory).staticcall(query);
        return ok && data.length == 64 && abi.decode(data, (uint256)) != 0;
    }

    // ---------------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------------

    /// @notice Any account, read-only. Reports and logs for every entry whether the token is listed, whether the supply
    ///         in force is the entry's, any pending listing with its window, and whether the live batch names it, so
    ///         nothing due expires unnoticed.
    /// @param factory The deployed factory.
    /// @param list Entries to report on.
    /// @return reports One report per entry, in entry order; the log lines say the same.
    function status(IIndexFactory factory, Entry[] memory list) public view returns (Report[] memory reports) {
        uint256 window = factory.PROPOSAL_WINDOW();
        // forge-lint: disable-next-line(unused-return) the report needs only the batch's timing and tokens
        (, uint256 batchEta, address[] memory batchTokens,) = factory.pendingSupplies();
        bool batchLive = factory.suppliesPending();
        if (batchLive) console2.log("a supply batch is pending from %s until %s", batchEta, batchEta + window);
        reports = new Report[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            Report memory report = reports[i];
            report.token = token;
            report.listed = factory.isWhitelisted(token);
            report.inForce = factory.referenceSupply(token) == list[i].referenceSupply;
            report.inBatch = batchLive && _contains(batchTokens, token);
            console2.log(token, report.listed ? "listed" : "not listed");
            if (!report.inForce) console2.log("  the supply in force is not the entry's");
            if (report.inBatch) console2.log("  in the pending supply batch");
            report.eta = factory.listingEta(token);
            if (report.eta == 0) continue;
            report.pendingMatches = factory.pendingReferenceSupply(token) == listingSupply(factory, list[i]);
            console2.log("  listing pending from %s until %s", report.eta, report.eta + window);
            if (!report.pendingMatches) console2.log("  its supply differs from the entry");
        }
    }

    function _contains(address[] memory list, address token) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == token) return true;
        }
        return false;
    }
}
