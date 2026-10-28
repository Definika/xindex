// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWeightedIndexFactory} from "../src/interfaces/IWeightedIndexFactory.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {PythIds} from "./PythIds.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Drives v5's listing flow on `WeightedIndexFactory`: each token with the Pyth price id its indexes will be
///         rebalanced at. It never lists a token on its own: a token never listed gets a proposal only when named in
///         V5_LIST, and a delisted one only when named in V5_RELIST, so a listing the guardian cancelled is not proposed
///         again by a routine run (RT-06). Execute mode never proposes, and runs only proposals that carry exactly the
///         entry's id.
///
///   Listings, for an owner that is a key you hold (testnets and local forks; a contract owner cannot sign, and this
///   reverts with OwnerIsContract: use `safe`):
///     V5_MODE=propose V5_FACTORY=0x... V5_WHITELIST=<entries> V5_LIST=<tokens> V5_USDC=0x... V5_USDT=0x... \
///       forge script script/ConfigureWeighted.s.sol --rpc-url <rpc> --account <owner key> --sender <owner> --broadcast
///   Listings for a Safe owner: log each `proposeListing` calldata to sign in the Safe app, each to the factory with no
///   value, under a line naming the token, its address and its price id. Nothing is broadcast:
///     V5_MODE=safe V5_FACTORY=0x... V5_WHITELIST=default V5_LIST=all forge script script/ConfigureWeighted.s.sol \
///       --rpc-url mainnet
///   Execute, from any account, between LISTING_DELAY and LISTING_DELAY + PROPOSAL_WINDOW later: `execute` runs every
///   due listing whose pending id is the entry's.
///
/// Env:
///   V5_MODE       `propose`, `safe`, `execute`, or `status` (read-only: what is listed and pending, per entry).
///   V5_FACTORY    Deployed WeightedIndexFactory.
///   V5_WHITELIST  `default` for the first four of `PythIds`, `wide` for the rest (both chain 1 only), or
///                 comma-separated entries `token:priceId`, both required. Check a feed's description names the coin
///                 before its first listing, as `PythIds` records.
///   V5_LIST       Optional. Tokens never listed that propose and safe mode may propose: comma-separated addresses, or
///                 `all` for every entry. Leave it unset on a routine run.
///   V5_RELIST     Optional. Comma-separated delisted tokens that propose and safe mode may list again.
///   V5_USDC, V5_USDT  The deployment's mint currencies, the USDC and USDT DeployWeighted was given, which propose and
///                 safe mode never propose as components (A7-22). Required off Ethereum; on Ethereum they default to
///                 the address book's, and nothing else is accepted there.
contract ConfigureWeighted is Script {
    /// @notice A token and the Pyth price id it is listed with.
    struct Entry {
        address token;
        bytes32 priceId;
    }

    /// @notice What `status` found for one entry.
    /// @param token The entry's token.
    /// @param listed Whether it is whitelisted.
    /// @param idInForce Whether the price id in force is the entry's; a delisted token keeps its id.
    /// @param eta When its pending listing becomes executable, or 0 when none is pending.
    /// @param pendingMatches Whether the pending listing carries the entry's id.
    struct Report {
        address token;
        bool listed;
        bool idInForce;
        uint256 eta;
        bool pendingMatches;
    }

    /// @notice Fewest and most decimals the whitelist policy accepts for a component.
    uint8 public constant MIN_DECIMALS = 6;
    uint8 public constant MAX_DECIMALS = 18;
    /// @notice How many of `PythIds`' coins the `default` list takes, listed first there: WETH, WBTC, LINK and UNI.
    uint256 public constant DEFAULT_COUNT = 4;

    /// @dev Fields in a V5_WHITELIST entry.
    uint256 private constant ENTRY_FIELDS = 2;

    /// @notice V5_MODE is not one of the modes above.
    error UnknownMode(string mode);
    /// @notice V5_WHITELIST names Ethereum's `default` or `wide` list on another chain.
    error ListOffItsChain(string list, uint256 chainId);
    /// @notice A V5_WHITELIST entry does not have exactly two fields, or its price id is zero.
    error MalformedEntry(string entry);
    /// @notice A broadcasting mode needs an owner that can sign, and this factory's owner is a contract (a Safe on
    ///         mainnet). Use `safe` and submit the calldata it logs from the owner.
    error OwnerIsContract(address owner);
    /// @notice The entries name `token` twice (RT-24).
    error DuplicateEntry(address token);
    /// @notice Two entries name one price id: no index could hold both, since Pyth fills only the first of two equal
    ///         ids (V5-M1). Listing both is allowed by the factory, but a list that does so is almost always a slip.
    error DuplicatePriceId(bytes32 priceId);
    /// @notice Off Ethereum the mint currency `name` must be given: only the deployment knows it.
    error MintCurrencyRequired(string name);
    /// @notice On Ethereum the mint currencies are the address book's; `name` named another.
    error MintCurrencyOverride(string name, address given);

    /// @notice Reads the V5_ variables and runs the mode.
    function run() external {
        IWeightedIndexFactory factory = IWeightedIndexFactory(vm.envAddress("V5_FACTORY"));
        Entry[] memory list = resolveList(vm.envString("V5_WHITELIST"));
        address[] memory firstListings = resolveFirstListings(vm.envOr("V5_LIST", string("")), list);
        address[] memory relist = parseAddresses(vm.envOr("V5_RELIST", string("")));
        string memory mode = vm.envString("V5_MODE");
        bool proposes = ScriptUtils.same(mode, "propose");
        if (proposes || ScriptUtils.same(mode, "safe")) {
            // Both modes propose, so both refuse the same mint currencies as components (A7-22).
            address[2] memory currencies = _mintCurrencies();
            if (proposes) {
                propose(factory, list, firstListings, relist, currencies);
                return;
            }
            (bytes[] memory calls, string[] memory labels) =
                safeCalldata(factory, list, firstListings, relist, currencies);
            console2.log("Safe transactions to the factory, value 0:", address(factory));
            for (uint256 i = 0; i < calls.length; ++i) {
                console2.log(labels[i]);
                console2.logBytes(calls[i]);
            }
        } else if (ScriptUtils.same(mode, "execute")) {
            execute(factory, list);
        } else if (ScriptUtils.same(mode, "status")) {
            status(factory, list);
        } else {
            revert UnknownMode(mode);
        }
    }

    // ---------------------------------------------------------------------
    // Lists
    // ---------------------------------------------------------------------

    /// @notice The first four of `PythIds`: WETH, WBTC, LINK and UNI.
    function defaultMainnetList() public pure returns (Entry[] memory list) {
        return _slice(0, DEFAULT_COUNT);
    }

    /// @notice The rest of `PythIds`: the wide list.
    function wideMainnetList() public pure returns (Entry[] memory list) {
        return _slice(DEFAULT_COUNT, PythIds.COUNT);
    }

    function _slice(uint256 from, uint256 to) private pure returns (Entry[] memory list) {
        (address[] memory tokens, bytes32[] memory ids) = PythIds.all();
        list = new Entry[](to - from);
        for (uint256 i = from; i < to; ++i) {
            list[i - from] = Entry({token: tokens[i], priceId: ids[i]});
        }
    }

    /// @notice `default` and `wide` on chain 1 only; anything else is parsed as comma-separated entries. Reverts on a token or a price id named twice (RT-24, V5-M1).
    function resolveList(string memory raw) public view returns (Entry[] memory list) {
        bool isDefault = ScriptUtils.same(raw, "default");
        if (isDefault || ScriptUtils.same(raw, "wide")) {
            if (block.chainid != 1) revert ListOffItsChain(raw, block.chainid);
            list = isDefault ? defaultMainnetList() : wideMainnetList();
        } else {
            string[] memory parts = vm.split(raw, ",");
            list = new Entry[](parts.length);
            for (uint256 i = 0; i < parts.length; ++i) {
                list[i] = parseEntry(vm.trim(parts[i]));
            }
        }
        _requireUnique(list);
    }

    /// @notice Parses `token:priceId`. Both fields are required, and the id must not be zero.
    function parseEntry(string memory raw) public pure returns (Entry memory entry) {
        string[] memory fields = vm.split(raw, ":");
        if (fields.length != ENTRY_FIELDS || bytes(fields[1]).length == 0) revert MalformedEntry(raw);
        entry.token = vm.parseAddress(fields[0]);
        entry.priceId = vm.parseBytes32(fields[1]);
        if (entry.priceId == bytes32(0)) revert MalformedEntry(raw);
    }

    /// @notice Comma-separated addresses; an empty string is an empty list.
    function parseAddresses(string memory raw) public pure returns (address[] memory addresses) {
        if (bytes(raw).length == 0) return addresses;
        string[] memory parts = vm.split(raw, ",");
        addresses = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            addresses[i] = vm.parseAddress(vm.trim(parts[i]));
        }
    }

    /// @notice V5_LIST: `all` names every entry's token; anything else is parsed as addresses (RT-06).
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

    // ---------------------------------------------------------------------
    // Listings
    // ---------------------------------------------------------------------

    /// @notice Owner only. Proposes a listing for every entry whose token is never listed and named in
    ///         `firstListings`, or delisted and named in `relist`, with nothing pending for it; anything else is skipped
    ///         with its reason logged. Reverts OwnerIsContract when the owner cannot sign.
    function propose(
        IWeightedIndexFactory factory,
        Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist,
        address[2] memory currencies
    ) public {
        _requireUnique(list);
        _requireSigningOwner(factory);
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            if (!_shouldList(factory, list[i], firstListings, relist, currencies)) continue;
            factory.proposeListing(list[i].token, list[i].priceId);
            console2.log("proposed a listing", list[i].token);
        }
        vm.stopBroadcast();
    }

    /// @notice Any account, nothing broadcast. For a Safe owner: the `proposeListing` calldata of every entry `propose`
    ///         would submit, and a label for each naming the token's symbol, its tier, its address and its price id
    ///         (RT-06).
    function safeCalldata(
        IWeightedIndexFactory factory,
        Entry[] memory list,
        address[] memory firstListings,
        address[] memory relist,
        address[2] memory currencies
    ) public view returns (bytes[] memory calls, string[] memory labels) {
        _requireUnique(list);
        bool[] memory chosen = new bool[](list.length);
        uint256 count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            chosen[i] = _shouldList(factory, list[i], firstListings, relist, currencies);
            if (chosen[i]) ++count;
        }
        calls = new bytes[](count);
        labels = new string[](count);
        count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            if (!chosen[i]) continue;
            calls[count] = abi.encodeCall(IWeightedIndexFactory.proposeListing, (list[i].token, list[i].priceId));
            labels[count] = string.concat(
                "proposeListing ",
                ScriptUtils.symbolOf(list[i].token),
                tierLabel(list[i].token),
                " ",
                vm.toString(list[i].token),
                " price id ",
                vm.toString(list[i].priceId)
            );
            ++count;
        }
    }

    /// @notice ` (<tier>)` for a token `PythIds` records a tier for, and nothing for any other.
    function tierLabel(address token) public pure returns (string memory) {
        PythIds.Tier tier = PythIds.tierOf(token);
        return tier == PythIds.Tier.Unrecorded ? "" : string.concat(" (", PythIds.tierName(tier), ")");
    }

    /// @notice Any account. Executes every due listing whose pending id is exactly the entry's; skips everything else
    ///         with the reason logged.
    function execute(IWeightedIndexFactory factory, Entry[] memory list) public {
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            uint256 eta = factory.listingEta(token);
            if (eta == 0) continue;
            // forge-lint: disable-next-line(unused-return) only the pending id matters here
            (bytes32 pendingId,) = factory.pendingTerms(token);
            if (pendingId != list[i].priceId) {
                console2.log("not executed, the pending price id differs from the entry", token);
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

    /// @dev Whether `entry` gets a proposal: not listed, nothing pending, named in V5_LIST if never listed or in
    ///      V5_RELIST if delisted, and inside the policy. The reason is logged for everything skipped.
    function _shouldList(
        IWeightedIndexFactory factory,
        Entry memory entry,
        address[] memory firstListings,
        address[] memory relist,
        address[2] memory currencies
    ) private view returns (bool) {
        address token = entry.token;
        if (factory.isWhitelisted(token)) return false;
        uint256 eta = factory.listingEta(token);
        if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
            // forge-lint: disable-next-line(unused-return) only the pending id matters here
            (bytes32 pendingId,) = factory.pendingTerms(token);
            console2.log(
                pendingId == entry.priceId
                    ? "already pending"
                    : "skipped, a different listing is pending; cancel it first",
                token
            );
            return false;
        }
        bool everListed = factory.priceIdOf(token) != bytes32(0);
        // A proposal that expired unexecuted leaves its eta set, where a cancel clears it. So an expired first listing
        // is proposed again without V5_LIST, while one the guardian cancelled still needs it (RT-06, RX-39).
        if (!everListed && eta != 0) {
            console2.log("expired unexecuted, proposing again", token);
            return _followsPolicy(token, currencies);
        }
        if (!everListed && !_contains(firstListings, token)) {
            console2.log("skipped, never listed; name it in V5_LIST to propose its listing", token);
            return false;
        }
        if (everListed && !_contains(relist, token)) {
            console2.log("skipped, delisted; name it in V5_RELIST to list it again", token);
            return false;
        }
        return _followsPolicy(token, currencies);
    }

    /// @dev The parts of the whitelist policy a script can check: a token with code and 6 to 18 decimals, and no mint
    ///      currency as a component, neither the deployment's (`currencies`) nor Ethereum's.
    function _followsPolicy(address token, address[2] memory currencies) private view returns (bool) {
        if (
            token == currencies[0] || token == currencies[1] || token == MainnetAddresses.USDC
                || token == MainnetAddresses.USDT
        ) {
            console2.log("skipped, a mint currency is not a component", token);
            return false;
        }
        if (token.code.length == 0) {
            console2.log("skipped, the token has no code", token);
            return false;
        }
        (bool answered, uint8 decimals) = ScriptUtils.decimalsOf(token);
        if (!answered || decimals < MIN_DECIMALS || decimals > MAX_DECIMALS) {
            console2.log("skipped, the whitelist policy needs 6 to 18 decimals", token);
            return false;
        }
        return true;
    }

    /// @notice The deployment's two mint currencies, which no whitelist entry may name as a component (A7-22): on
    ///         Ethereum the address book's USDC and USDT, which may be named but not replaced; elsewhere `usdc` and
    ///         `usdt`, the V5_USDC and V5_USDT that DeployWeighted was given as USDC and USDT, both required.
    function mintCurrencies(address usdc, address usdt) public view returns (address[2] memory currencies) {
        currencies[0] = _mintCurrency("V5_USDC", usdc, MainnetAddresses.USDC);
        currencies[1] = _mintCurrency("V5_USDT", usdt, MainnetAddresses.USDT);
    }

    function _mintCurrency(string memory name, address given, address pinned) private view returns (address) {
        if (block.chainid == 1) {
            if (given != address(0) && given != pinned) revert MintCurrencyOverride(name, given);
            return pinned;
        }
        if (given == address(0)) revert MintCurrencyRequired(name);
        return given;
    }

    /// @dev {mintCurrencies} from V5_USDC and V5_USDT.
    function _mintCurrencies() private view returns (address[2] memory) {
        return mintCurrencies(vm.envOr("V5_USDC", address(0)), vm.envOr("V5_USDT", address(0)));
    }

    function _requireSigningOwner(IWeightedIndexFactory factory) private view {
        address factoryOwner = Ownable(address(factory)).owner();
        bytes memory ownerCode = factoryOwner.code;
        if (ownerCode.length != 0 && !ScriptUtils.isDelegatedAccount(ownerCode)) revert OwnerIsContract(factoryOwner);
    }

    function _requireUnique(Entry[] memory list) private pure {
        for (uint256 i = 1; i < list.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (list[j].token == list[i].token) revert DuplicateEntry(list[i].token);
                if (list[j].priceId == list[i].priceId) revert DuplicatePriceId(list[i].priceId);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------------

    /// @notice Any account, read-only. For every entry: listed or not, whether its id is in force, and any pending
    ///         listing with its window.
    function status(IWeightedIndexFactory factory, Entry[] memory list) public view returns (Report[] memory reports) {
        uint256 window = factory.PROPOSAL_WINDOW();
        reports = new Report[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            Report memory report = reports[i];
            report.token = token;
            report.listed = factory.isWhitelisted(token);
            report.idInForce = factory.priceIdOf(token) == list[i].priceId;
            console2.log(token, report.listed ? "listed" : "not listed");
            if (!report.idInForce) console2.log("  the price id in force is not the entry's");
            report.eta = factory.listingEta(token);
            if (report.eta == 0) continue;
            // forge-lint: disable-next-line(unused-return) only the pending id matters here
            (bytes32 pendingId,) = factory.pendingTerms(token);
            report.pendingMatches = pendingId == list[i].priceId;
            console2.log("  listing pending from %s until %s", report.eta, report.eta + window);
            if (!report.pendingMatches) console2.log("  its price id differs from the entry");
        }
    }

    function _contains(address[] memory list, address token) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == token) return true;
        }
        return false;
    }
}
