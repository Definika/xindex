// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IndexFactory} from "../src/IndexFactory.sol";

/// @notice Drives the two-step listing flow. It never re-proposes a token on its own: proposing is a separate,
///         explicit run by the owner, so a listing the guardian cancelled stays cancelled.
///
///   Propose, as the factory owner:
///     LISTING_MODE=propose FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet --account deployer --sender <owner> --broadcast
///   Execute, from any account, between LISTING_DELAY and LISTING_DELAY + PROPOSAL_WINDOW later:
///     LISTING_MODE=execute FACTORY=0x... WHITELIST=default forge script script/ConfigureWhitelist.s.sol \
///       --rpc-url mainnet --account deployer --sender <any account> --broadcast
///
/// When the owner is a Safe, submit `proposeListing` through the Safe; `executeListing` is permissionless.
///
/// Env:
///   LISTING_MODE  `propose` or `execute`.
///   FACTORY       Deployed IndexFactory.
///   WHITELIST     Comma-separated token addresses, or `default` for the mainnet list below (chain 1 only).
contract ConfigureWhitelist is Script {
    error UnknownMode(string mode);
    error DefaultListOnlyOnMainnet();

    /// @notice Default mainnet components. WBTC can be paused by its custodian, so the app must label it.
    function defaultMainnetList() public pure returns (address[] memory list) {
        list = new address[](5);
        list[0] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC
        list[1] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
        list[2] = 0x514910771AF9Ca656af840dff83E8264EcF986CA; // LINK
        list[3] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNI
        list[4] = 0x18084fbA666a33d37592fA2633fD49a74DD93a88; // tBTC v2
    }

    function run() external {
        IndexFactory factory = IndexFactory(vm.envAddress("FACTORY"));
        address[] memory list = resolveList(vm.envString("WHITELIST"));
        string memory mode = vm.envString("LISTING_MODE");
        if (_same(mode, "propose")) {
            propose(factory, list);
        } else if (_same(mode, "execute")) {
            execute(factory, list);
        } else {
            revert UnknownMode(mode);
        }
    }

    /// @notice `default` means the mainnet list and is only accepted on chain 1; anything else is parsed as
    ///         comma-separated addresses.
    function resolveList(string memory raw) public view returns (address[] memory list) {
        if (_same(raw, "default")) {
            if (block.chainid != 1) revert DefaultListOnlyOnMainnet();
            return defaultMainnetList();
        }
        string[] memory parts = vm.split(raw, ",");
        list = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; ++i) {
            list[i] = vm.parseAddress(vm.trim(parts[i]));
        }
    }

    /// @notice Owner only. Proposes every token that is neither listed nor pending; an expired proposal is
    ///         proposed again.
    function propose(IndexFactory factory, address[] memory list) public {
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i];
            if (factory.isWhitelisted(token)) continue;
            uint256 eta = factory.listingEta(token);
            if (eta != 0 && block.timestamp <= eta + factory.PROPOSAL_WINDOW()) {
                console2.log("already pending", token);
                continue;
            }
            factory.proposeListing(token);
            console2.log("proposed", token);
        }
        vm.stopBroadcast();
    }

    /// @notice Any account. Executes every proposal that is due and skips everything else.
    function execute(IndexFactory factory, address[] memory list) public {
        vm.startBroadcast();
        for (uint256 i = 0; i < list.length; ++i) {
            address token = list[i];
            uint256 eta = factory.listingEta(token);
            if (eta == 0) continue; // listed already, never proposed, or cancelled
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

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
