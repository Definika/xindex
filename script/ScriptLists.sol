// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BnbChainAddresses} from "./BnbChainAddresses.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {Listings} from "./Listings.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice The token lists V5_WHITELIST and CHECK name, for the listing script and the admission check alike.
/// @dev Internal functions, so `ConfigureWeighted` and `CheckToken` each carry them and neither creates the other.
///      `CheckToken` once created a `ConfigureWeighted` to resolve its tokens. A `forge script` run
///      against an OP Stack chain (Foundry 1.8.1, seen on Base and on Optimism) fails a state-changing call
///      or a creation by an account that holds no ether before it runs, where a run against Ethereum or BNB Chain
///      does not; the script contract holds none and a script may not fund itself, so every CHECK on Base reverted
///      before it read a token, `CHECK=base` among them. Broadcast calls, and calls from a funded account, run.
library ScriptLists {
    /// @notice How many coins the `default` list holds: the first four of `Listings`.
    uint256 internal constant DEFAULT_COUNT = 4;

    /// @dev Foundry's cheatcode address, as forge-std's `VM_ADDRESS`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice A chain's list is named on another chain: `default` or `wide` off chain 1, `bnb` off chain 56, `base`
    ///         off chain 8453.
    error ListOffItsChain(string list, uint256 chainId);
    /// @notice The list names `token` twice (RT-24).
    error DuplicateEntry(address token);

    /// @notice The first four of `Listings`: WETH, WBTC, LINK and UNI.
    function defaultMainnet() internal pure returns (address[] memory list) {
        return _slice(0, DEFAULT_COUNT);
    }

    /// @notice The rest of `Listings`: the wide list.
    function wideMainnet() internal pure returns (address[] memory list) {
        return _slice(DEFAULT_COUNT, Listings.COUNT);
    }

    function _slice(uint256 from, uint256 to) private pure returns (address[] memory list) {
        address[] memory tokens = Listings.all();
        list = new address[](to - from);
        for (uint256 i = from; i < to; ++i) {
            list[i - from] = tokens[i];
        }
    }

    /// @notice Whether `raw` names a chain's list rather than addresses.
    function isNamed(string memory raw) internal pure returns (bool) {
        return ScriptUtils.same(raw, "default") || ScriptUtils.same(raw, "wide") || ScriptUtils.same(raw, "bnb")
            || ScriptUtils.same(raw, "base");
    }

    /// @notice `default` and `wide` on chain 1 only, `bnb` on chain 56 only, `base` on chain 8453 only; anything else
    ///         is parsed as comma-separated token addresses. Reverts on a token named twice (RT-24).
    function resolve(string memory raw) internal view returns (address[] memory list) {
        bool isDefault = ScriptUtils.same(raw, "default");
        if (isDefault || ScriptUtils.same(raw, "wide")) {
            if (block.chainid != 1) revert ListOffItsChain(raw, block.chainid);
            list = isDefault ? defaultMainnet() : wideMainnet();
        } else if (ScriptUtils.same(raw, "bnb")) {
            if (block.chainid != BnbChainAddresses.CHAIN_ID) revert ListOffItsChain(raw, block.chainid);
            list = BnbChainAddresses.all();
        } else if (ScriptUtils.same(raw, "base")) {
            if (block.chainid != BaseAddresses.CHAIN_ID) revert ListOffItsChain(raw, block.chainid);
            list = BaseAddresses.all();
        } else {
            list = parse(raw);
        }
        requireUnique(list);
    }

    /// @notice Comma-separated addresses; an empty string is an empty list.
    function parse(string memory raw) internal pure returns (address[] memory addresses) {
        if (bytes(raw).length == 0) return addresses;
        string[] memory parts = VM.split(raw, ",");
        addresses = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            addresses[i] = VM.parseAddress(VM.trim(parts[i]));
        }
    }

    /// @notice Reverts when `list` names a token twice (RT-24).
    function requireUnique(address[] memory list) internal pure {
        for (uint256 i = 1; i < list.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (list[j] == list[i]) revert DuplicateEntry(list[i]);
            }
        }
    }
}
