// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice Deploys the factory (which deploys the IndexHub implementation) and the zap.
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/Deploy.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER               Required. Factory owner. On mainnet it must be a contract that is not an EIP-7702 delegated
///                       account, and a Safe must require at least two signatures and have no enabled module.
///   GUARDIAN            Required. Can cancel pending listings, supply batches and rebalances, start a rebalance
///                       that leaves a paused component untouched, and delist tokens. Must differ from OWNER; replacing
///                       it later takes 7 days.
///   UNIVERSAL_ROUTER    Uniswap's Universal Router, through which the zap swaps. Required off mainnet; defaults on
///                       chain 1 to the 2.0.0 deployment.
contract Deploy is Script {
    /// @notice Mainnet default {resolveRouter} uses on chain 1, from `MainnetAddresses`.
    address public constant MAINNET_UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
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
    function run() external returns (IndexFactory factory, IndexZap zap) {
        return deploy(vm.envAddress("OWNER"), vm.envAddress("GUARDIAN"), vm.envOr("UNIVERSAL_ROUTER", address(0)));
    }

    /// @notice Checks the owner and guardian, resolves the market, and broadcasts the factory (which deploys the
    ///         IndexHub implementation) and the zap. Logs every address.
    /// @param owner Factory owner; see {checkOwner}.
    /// @param guardian Initial guardian; see {checkGuardian}.
    /// @param router Uniswap's Universal Router, through which the zap swaps; see {resolveRouter}.
    /// @return factory The deployed factory.
    /// @return zap The deployed zap.
    function deploy(address owner, address guardian, address router)
        public
        returns (IndexFactory factory, IndexZap zap)
    {
        checkOwner(owner);
        checkGuardian(owner, guardian);
        router = resolveRouter(router);
        checkRolesAreNotMarket(owner, guardian, router);

        vm.startBroadcast();
        factory = new IndexFactory(owner, guardian);
        zap = new IndexZap(factory, IUniversalRouter(router));
        vm.stopBroadcast();

        console2.log("IndexFactory:            ", address(factory));
        console2.log("IndexHub impl:           ", factory.IMPLEMENTATION());
        console2.log("IndexZap:                ", address(zap));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Universal Router:        ", router);
        console2.log("PoolManager:             ", zap.POOL_MANAGER());

        // The release record: the addresses above plus the code they ended up with, so a later run of
        // {checkDeployment} against the recorded addresses proves a deployment is this build.
        bytes32[3] memory codehashes = checkDeployment(factory, zap);
        console2.log("IndexFactory codehash:   ", vm.toString(codehashes[0]));
        console2.log("IndexHub impl codehash:  ", vm.toString(codehashes[1]));
        console2.log("IndexZap codehash:       ", vm.toString(codehashes[2]));
    }

    /// @notice Checks that a factory and a zap are one deployment and returns the runtime code hashes to freeze in the
    ///         release record (README, "Deployment record"). Run it again later against the recorded addresses: equal
    ///         hashes prove the deployed code is unchanged and still the build the record names.
    /// @param factory The deployed factory, which names the IndexHub implementation.
    /// @param zap The deployed zap, which must point back at `factory`.
    /// @return codehashes keccak256 of the runtime code of the factory, the implementation and the zap.
    function checkDeployment(IndexFactory factory, IndexZap zap) public view returns (bytes32[3] memory codehashes) {
        address implementation = factory.IMPLEMENTATION();
        address zapFactory = address(zap.FACTORY());
        if (zapFactory != address(factory)) revert WrongWiring("IndexZap.FACTORY", address(factory), zapFactory);
        codehashes = [address(factory).codehash, implementation.codehash, address(zap).codehash];
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

    /// @notice Rejects an owner or guardian that is one of the market contracts, such as one pasted as OWNER. None of
    ///         them answers `getThreshold`, so {checkOwner} would accept any as a contract owner, and a factory owned
    ///         by one could never be administered: no listing, no supply batch, and a redeploy. An earlier version had
    ///         narrowed this to the router alone (XA-39, CR-I37).
    /// @param owner The intended factory owner.
    /// @param guardian The intended guardian.
    /// @param router The resolved router.
    function checkRolesAreNotMarket(address owner, address guardian, address router) public view {
        address[] memory market = marketContracts(router);
        for (uint256 i = 0; i < market.length; ++i) {
            if (owner == market[i] || guardian == market[i]) revert RoleIsMarketContract(market[i]);
        }
    }

    /// @notice The contracts a deployment on this chain trades or prices through, none of which may hold a role.
    /// @param router The resolved Universal Router.
    /// @return list The router and the PoolManager it settles against, then, on chain 1, every token in
    ///         `MainnetAddresses`.
    function marketContracts(address router) public view returns (address[] memory list) {
        address[] memory mainnet = block.chainid == 1 ? _mainnetMarket() : new address[](0);
        list = new address[](mainnet.length + 2);
        list[0] = router;
        list[1] = IUniversalRouter(router).poolManager();
        for (uint256 i = 0; i < mainnet.length; ++i) {
            list[i + 2] = mainnet[i];
        }
    }

    /// @dev Every token the mainnet address book names.
    function _mainnetMarket() private pure returns (address[] memory list) {
        list = new address[](6);
        (list[0], list[1], list[2], list[3]) =
        (MainnetAddresses.WETH, MainnetAddresses.WBTC, MainnetAddresses.UNI, MainnetAddresses.LINK);
        (list[4], list[5]) = (MainnetAddresses.USDC, MainnetAddresses.USDT);
    }

    /// @notice Fills a zero router with the mainnet default on chain 1 only, and requires it to have code. On chain 1
    ///         a given address must be the default, because the router is pinned there: the zap encodes against one
    ///         version's command inputs, and a later line changed them.
    /// @param router Address from the environment; zero takes the mainnet default on chain 1.
    /// @return The resolved router.
    function resolveRouter(address router) public view returns (address) {
        return _resolve("UNIVERSAL_ROUTER", router, MAINNET_UNIVERSAL_ROUTER);
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
