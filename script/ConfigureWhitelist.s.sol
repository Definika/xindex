// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3Factory.sol";

/// @notice Drives the two-step flow that lists tokens and sets their market-data configs. It never re-proposes a
///         token on its own: proposing is a separate, explicit run by the owner, so a listing the guardian cancelled
///         stays cancelled.
///
///   Propose, as the factory owner:
///     LISTING_MODE=propose FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet --account deployer --sender <owner> --broadcast
///   Execute, from any account, between LISTING_DELAY and LISTING_DELAY + PROPOSAL_WINDOW later:
///     LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet --account deployer --sender <any account> --broadcast
///
///   Propose for an owner that is a Safe: log the `proposeListing` calldata to sign in the Safe app, one transaction per
///   line, each to the factory with no value. Any account can run it, and nothing is broadcast:
///     LISTING_MODE=safe FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol --rpc-url mainnet
///
/// Env:
///   LISTING_MODE  `propose`, `execute` or `safe`.
///   FACTORY       Deployed IndexFactory.
///   WHITELIST     `default` for the mainnet list below (chain 1 only), or comma-separated entries
///                 `token:fee[:referenceSupply[:excluded|excluded...]]`. `fee` is the Uniswap V3 fee tier of the token's
///                 WETH pool, or 0 for WETH itself. An empty or missing referenceSupply means on-chain supply.
contract ConfigureWhitelist is Script {
    /// @notice A token and the config to list it with. The pool is looked up from `fee` at proposal time.
    struct Entry {
        address token;
        uint24 fee;
        uint256 referenceSupply;
        address[] excluded;
    }

    uint24 public constant POOL_FEE_LOW = 500;
    uint24 public constant POOL_FEE_MEDIUM = 3000;

    error UnknownMode(string mode);
    error DefaultListOnlyOnMainnet();
    error MalformedEntry(string entry);

    /// @notice Default mainnet components. Reference supplies are circulating supplies reported by CoinGecko on
    ///         2026-09-15, rounded down to whole tokens; propose a config change when they drift. WBTC and WETH count the
    ///         whole bitcoin and ether supply, because their on-chain supply is only the wrapped float. tBTC uses its
    ///         own on-chain supply. WBTC can be paused by its custodian, so the app must label it.
    function defaultMainnetList() public pure returns (Entry[] memory list) {
        address[] memory none = new address[](0);
        list = new Entry[](5);
        list[0] = Entry({
            token: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,
            fee: POOL_FEE_LOW,
            referenceSupply: 20_084_784e8,
            excluded: none
        }); // WBTC, bitcoin supply
        list[1] = Entry({
            token: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, fee: 0, referenceSupply: 122_050_160e18, excluded: none
        }); // WETH, ether supply
        list[2] = Entry({
            token: 0x514910771AF9Ca656af840dff83E8264EcF986CA,
            fee: POOL_FEE_MEDIUM,
            referenceSupply: 748_099_970e18,
            excluded: none
        }); // LINK
        list[3] = Entry({
            token: 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984,
            fee: POOL_FEE_MEDIUM,
            referenceSupply: 623_212_423e18,
            excluded: none
        }); // UNI
        list[4] = Entry({
            token: 0x18084fbA666a33d37592fA2633fD49a74DD93a88, fee: POOL_FEE_MEDIUM, referenceSupply: 0, excluded: none
        }); // tBTC v2
    }

    function run() external {
        IndexFactory factory = IndexFactory(vm.envAddress("FACTORY"));
        Entry[] memory list = resolveList(vm.envString("WHITELIST"));
        string memory mode = vm.envString("LISTING_MODE");
        if (_same(mode, "propose")) {
            propose(factory, list);
        } else if (_same(mode, "execute")) {
            execute(factory, list);
        } else if (_same(mode, "safe")) {
            bytes[] memory calls = safeCalldata(factory, list);
            console2.log("Safe transactions to the factory, value 0:", address(factory));
            for (uint256 i = 0; i < calls.length; ++i) {
                console2.logBytes(calls[i]);
            }
        } else {
            revert UnknownMode(mode);
        }
    }

    /// @notice `default` means the mainnet list and is only accepted on chain 1; anything else is parsed as
    ///         comma-separated entries.
    function resolveList(string memory raw) public view returns (Entry[] memory list) {
        if (_same(raw, "default")) {
            if (block.chainid != 1) revert DefaultListOnlyOnMainnet();
            return defaultMainnetList();
        }
        string[] memory parts = vm.split(raw, ",");
        list = new Entry[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            list[i] = parseEntry(vm.trim(parts[i]));
        }
    }

    /// @notice Parses `token:fee[:referenceSupply[:excluded|excluded...]]`.
    function parseEntry(string memory raw) public pure returns (Entry memory entry) {
        string[] memory fields = vm.split(raw, ":");
        if (fields.length < 2 || fields.length > 4) revert MalformedEntry(raw);
        entry.token = vm.parseAddress(fields[0]);
        entry.fee = SafeCast.toUint24(vm.parseUint(fields[1]));
        if (fields.length > 2 && bytes(fields[2]).length != 0) entry.referenceSupply = vm.parseUint(fields[2]);
        if (fields.length > 3 && bytes(fields[3]).length != 0) {
            string[] memory excluded = vm.split(fields[3], "|");
            entry.excluded = new address[](excluded.length);
            for (uint256 i = 0; i < excluded.length; ++i) {
                entry.excluded[i] = vm.parseAddress(excluded[i]);
            }
        }
    }

    /// @notice The config `entry` proposes: its pool is the Uniswap V3 factory's WETH pool at `entry.fee`, or none for
    ///         a zero fee.
    function configFor(Entry memory entry, address weth, address uniswapV3Factory)
        public
        view
        returns (IIndexFactory.TokenConfig memory config)
    {
        config.referenceSupply = entry.referenceSupply;
        config.excluded = entry.excluded;
        if (entry.fee != 0) config.pool = IUniswapV3Factory(uniswapV3Factory).getPool(entry.token, weth, entry.fee);
    }

    /// @notice Owner only. Proposes every entry that is not pending and not already listed with exactly its config; an
    ///         expired proposal is proposed again. An entry the rule rejects, for example because its pool keeps too
    ///         little price history, is skipped and the reason logged.
    function propose(IndexFactory factory, Entry[] memory list) public {
        IIndexRule rule = IIndexRule(factory.RULE());
        address weth = rule.WETH();
        address uniswapV3Factory = rule.UNISWAP_V3_FACTORY();
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            IIndexFactory.TokenConfig memory config = configFor(list[i], weth, uniswapV3Factory);
            if (!_shouldPropose(factory, rule, token, config)) continue;
            factory.proposeListing(token, config);
            console2.log("proposed", token);
        }
        vm.stopBroadcast();
    }

    /// @notice Any account, nothing is broadcast. For an owner that is a Safe: the `proposeListing` calldata of every
    ///         entry `propose` would submit, each to be sent to the factory with no value.
    function safeCalldata(IndexFactory factory, Entry[] memory list) public view returns (bytes[] memory calls) {
        IIndexRule rule = IIndexRule(factory.RULE());
        address weth = rule.WETH();
        address uniswapV3Factory = rule.UNISWAP_V3_FACTORY();
        bytes[] memory all = new bytes[](list.length);
        uint256 count = 0;
        for (uint256 i = 0; i < list.length; ++i) {
            IIndexFactory.TokenConfig memory config = configFor(list[i], weth, uniswapV3Factory);
            if (!_shouldPropose(factory, rule, list[i].token, config)) continue;
            all[count++] = abi.encodeCall(IIndexFactory.proposeListing, (list[i].token, config));
        }
        calls = new bytes[](count);
        for (uint256 i = 0; i < count; ++i) {
            calls[i] = all[i];
        }
    }

    /// @notice Any account. Executes every proposal that is due and skips everything else.
    function execute(IndexFactory factory, Entry[] memory list) public {
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i].token;
            uint256 eta = factory.listingEta(token);
            if (eta == 0) continue; // nothing pending: listed with this config already, never proposed, or cancelled
            if (block.timestamp < eta) {
                console2.log("not ready yet", token);
            } else if (block.timestamp > eta + factory.PROPOSAL_WINDOW()) {
                console2.log("expired, propose again", token);
            } else {
                factory.executeListing(token);
                console2.log("listed", token);
            }
        }
        vm.stopBroadcast();
    }

    /// @dev False, with the reason logged, for an entry that is pending, already listed with exactly `config`, or rejected
    ///      by the rule.
    function _shouldPropose(
        IndexFactory factory,
        IIndexRule rule,
        address token,
        IIndexFactory.TokenConfig memory config
    ) private view returns (bool) {
        uint256 eta = factory.listingEta(token);
        if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
            console2.log("already pending", token);
            return false;
        }
        if (factory.isWhitelisted(token) && _sameConfig(factory.tokenConfig(token), config)) return false;
        try rule.checkConfig(token, config) {
            return true;
        } catch (bytes memory reason) {
            console2.log("skipped, the rule rejects this config", token);
            console2.logBytes(reason);
            return false;
        }
    }

    function _sameConfig(IIndexFactory.TokenConfig memory a, IIndexFactory.TokenConfig memory b)
        private
        pure
        returns (bool)
    {
        return a.pool == b.pool && a.referenceSupply == b.referenceSupply
            && keccak256(abi.encode(a.excluded)) == keccak256(abi.encode(b.excluded));
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
