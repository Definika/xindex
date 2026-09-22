// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {CompositeFeed} from "../src/CompositeFeed.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Deploys the factory (which deploys the rule and the IndexToken implementation) and the zap.
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/Deploy.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER               Required. Factory owner. On mainnet it must be a contract that is not an EIP-7702 delegated
///                       account, and a Safe must require at least two signatures and have no enabled module.
///   GUARDIAN            Required. Can cancel pending listings and rebalances, start a rebalance that leaves a paused
///                       component untouched, and delist tokens. Must differ from OWNER; replacing it later takes 7 days.
///   SWAP_ROUTER         Uniswap SwapRouter02 the zap swaps through. Required off mainnet; defaults on chain 1.
contract Deploy is Script {
    /// @notice Mainnet default {resolveRouter} uses on chain 1, from `MainnetAddresses`.
    address public constant MAINNET_SWAP_ROUTER_02 = MainnetAddresses.SWAP_ROUTER_02;
    /// @notice Start of a Safe's module list.
    address public constant SENTINEL_MODULES = address(0x1);

    /// @notice OWNER is zero or Foundry's default sender.
    error OwnerRequired();
    /// @notice On mainnet, the owner has no code or is an EIP-7702 delegated account.
    error OwnerMustBeContract(address owner);
    /// @notice The owner is a Safe that needs fewer than two signatures.
    error OwnerThresholdTooLow(address owner, uint256 threshold);
    /// @notice The owner is a Safe with `module` enabled, which could act for it without signatures.
    error OwnerHasModules(address owner, address module);
    /// @notice The owner is a Safe whose module list cannot be read with `getModulesPaginated`.
    error OwnerModulesUnknown(address owner);
    /// @notice GUARDIAN is zero, Foundry's default sender, or the owner.
    error GuardianRequired();
    /// @notice The guardian is the key broadcasting the deployment.
    error GuardianIsBroadcaster(address guardian);
    /// @notice The owner or guardian is one of the market contracts.
    error RoleIsMarketContract(address account);
    /// @notice On mainnet, the market address `name` was set to `given` instead of the default.
    error MainnetOverride(string name, address given);
    /// @notice Off mainnet, the market address `name` must be set.
    error AddressRequired(string name);
    /// @notice The market address `name` has no code.
    error AddressHasNoCode(string name, address account);
    /// @notice `name` points at `actual` instead of `expected`, so these contracts are not one deployment.
    error WrongWiring(string name, address expected, address actual);

    /// @notice Reads OWNER, GUARDIAN and the optional market addresses from the environment and calls {deploy}.
    function run() external returns (IndexFactory factory, IndexZap zap, CompositeFeed wbtcFeed) {
        return deploy(vm.envAddress("OWNER"), vm.envAddress("GUARDIAN"), vm.envOr("SWAP_ROUTER", address(0)));
    }

    /// @notice Checks the owner and guardian, resolves the market, and broadcasts the factory (which deploys the rule
    ///         and the IndexToken implementation) and the zap. Logs every address.
    /// @param owner Factory owner; see {checkOwner}.
    /// @param guardian Initial guardian; see {checkGuardian}.
    /// @param router Uniswap SwapRouter02 the zap swaps through; see {resolveRouter}.
    /// @return factory The deployed factory.
    /// @return zap The deployed zap.
    /// @return wbtcFeed The composite BTC/USD times WBTC/BTC feed, deployed on chain 1 only, else zero. It takes no
    ///         owner and no arguments beyond its two legs, so a later run deploys an identical one.
    function deploy(address owner, address guardian, address router)
        public
        returns (IndexFactory factory, IndexZap zap, CompositeFeed wbtcFeed)
    {
        checkOwner(owner);
        checkGuardian(owner, guardian);
        router = resolveRouter(router);
        checkRolesAreNotMarket(owner, guardian, router);

        vm.startBroadcast();
        factory = new IndexFactory(owner, guardian);
        zap = new IndexZap(factory, ISwapRouter02(router));
        if (block.chainid == 1) {
            wbtcFeed = new CompositeFeed(
                IAggregatorV3(MainnetAddresses.BTC_USD_FEED),
                IAggregatorV3(MainnetAddresses.WBTC_BTC_FEED),
                MainnetAddresses.STALENESS_1H,
                MainnetAddresses.STALENESS_24H
            );
        }
        vm.stopBroadcast();

        console2.log("IndexFactory:            ", address(factory));
        console2.log("IndexRule:               ", factory.RULE());
        console2.log("IndexToken impl:         ", factory.IMPLEMENTATION());
        console2.log("IndexZap:                ", address(zap));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Swap router:             ", router);
        if (address(wbtcFeed) != address(0)) console2.log("WBTC_FEED (composite):   ", address(wbtcFeed));

        // The release record: the addresses above plus the code they ended up with, so a later run of
        // {checkDeployment} against the recorded addresses proves a deployment is this build.
        bytes32[4] memory codehashes = checkDeployment(factory, zap);
        console2.log("IndexFactory codehash:   ", vm.toString(codehashes[0]));
        console2.log("IndexRule codehash:      ", vm.toString(codehashes[1]));
        console2.log("IndexToken impl codehash:", vm.toString(codehashes[2]));
        console2.log("IndexZap codehash:       ", vm.toString(codehashes[3]));
    }

    /// @notice Checks that a factory and a zap are one deployment and returns the runtime code hashes to freeze in the
    ///         release record (README, "Deployment record"). Run it again later against the recorded addresses: equal
    ///         hashes prove the deployed code is unchanged and still the build the record names.
    /// @param factory The deployed factory, which names the rule and the IndexToken implementation.
    /// @param zap The deployed zap, which must point back at `factory`.
    /// @return codehashes keccak256 of the runtime code of the factory, the rule, the implementation and the zap.
    function checkDeployment(IndexFactory factory, IndexZap zap) public view returns (bytes32[4] memory codehashes) {
        address rule = factory.RULE();
        address implementation = factory.IMPLEMENTATION();
        address zapFactory = address(zap.FACTORY());
        if (zapFactory != address(factory)) revert WrongWiring("IndexZap.FACTORY", address(factory), zapFactory);
        codehashes = [address(factory).codehash, rule.codehash, implementation.codehash, address(zap).codehash];
    }

    /// @notice Rejects a missing owner and Foundry's default sender. On mainnet the owner must be a contract, not
    ///         an EIP-7702 delegated account, and a Safe must need at least two signatures and have no enabled module,
    ///         because a module acts as the Safe without signatures. Modules or guards added later are not checked, so
    ///         the Safe must keep none.
    /// @param owner The intended factory owner.
    function checkOwner(address owner) public view {
        if (owner == address(0) || owner == DEFAULT_SENDER) revert OwnerRequired();
        if (block.chainid != 1) return;

        bytes memory code = owner.code;
        if (code.length == 0 || ScriptUtils.isDelegatedAccount(code)) revert OwnerMustBeContract(owner);
        // A Safe answers getThreshold with one word. A contract that does not, such as a timelock, is accepted as it
        // is. A static call is used because a typed try/catch would revert on an empty answer from a fallback.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = owner.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ()));
        if (ok && data.length == 32) {
            uint256 threshold = abi.decode(data, (uint256));
            if (threshold < 2) revert OwnerThresholdTooLow(owner, threshold);
            _checkNoModules(owner);
        }
    }

    /// @dev Reads the first page of the Safe's module list. A multisig that cannot show one is rejected rather than
    ///      trusted, and so is any enabled module.
    function _checkNoModules(address owner) private view {
        bytes memory query = abi.encodeCall(ISafeThreshold.getModulesPaginated, (SENTINEL_MODULES, 1));
        // A static call keeps a missing function or a short answer from reverting without a named error.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = owner.staticcall(query);
        // A well-formed answer holds at least the array offset, the next cursor and the array length.
        if (!ok || data.length < 96) revert OwnerModulesUnknown(owner);
        (address[] memory modules,) = abi.decode(data, (address[], address));
        if (modules.length != 0) revert OwnerHasModules(owner, modules[0]);
    }

    /// @notice Requires a guardian that is set, is not Foundry's default sender, is not the owner, and is not the key
    ///         broadcasting the deployment (the script's msg.sender), which must hold no role in the factory.
    /// @param owner The intended factory owner.
    /// @param guardian The intended guardian.
    function checkGuardian(address owner, address guardian) public view {
        if (guardian == address(0) || guardian == DEFAULT_SENDER || guardian == owner) revert GuardianRequired();
        if (guardian == msg.sender) revert GuardianIsBroadcaster(guardian);
    }

    /// @notice Rejects an owner or guardian that is the router, such as it pasted as OWNER.
    /// @param owner The intended factory owner.
    /// @param guardian The intended guardian.
    /// @param router The resolved router.
    function checkRolesAreNotMarket(address owner, address guardian, address router) public pure {
        if (owner == router || guardian == router) revert RoleIsMarketContract(router);
    }

    /// @notice Fills a zero router with the mainnet default on chain 1 only, and requires it to have code. On chain 1
    ///         a given address must be the default, because the market is fixed there.
    /// @param router Address from the environment; zero takes the mainnet default on chain 1.
    /// @return The resolved router.
    function resolveRouter(address router) public view returns (address) {
        return _resolve("SWAP_ROUTER", router, MAINNET_SWAP_ROUTER_02);
    }

    function _resolve(string memory name, address given, address mainnetDefault) private view returns (address) {
        if (given == address(0)) {
            if (block.chainid != 1) revert AddressRequired(name);
            given = mainnetDefault;
        } else if (block.chainid == 1 && given != mainnetDefault) {
            revert MainnetOverride(name, given);
        }
        if (given.code.length == 0) revert AddressHasNoCode(name, given);
        return given;
    }
}
