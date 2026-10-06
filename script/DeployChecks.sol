// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice The checks every deployment of a factory runs before it broadcasts: the owner, the guardian, the roles
///         against the market, and the market addresses themselves. `Deploy` (v4) and `DeployWeighted` (v5) share
///         them, so the rules on who may own a factory exist once.
abstract contract DeployChecks is Script {
    /// @notice Mainnet default {resolveRouter} uses on chain 1, from `MainnetAddresses`.
    address public constant MAINNET_UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
    /// @notice Mainnet default {resolvePancakeRouter} uses on chain 1, from `MainnetAddresses`.
    address public constant MAINNET_PANCAKE_ROUTER = MainnetAddresses.PANCAKE_UNIVERSAL_ROUTER;
    /// @notice Fewest signatures a Safe owner may need on mainnet: the design's 3-of-5 hardware wallets held by
    ///         separate people (the owner's call on 2026-09-30).
    uint256 public constant MIN_OWNER_THRESHOLD = 3;
    /// @notice Start of a Safe's module list.
    address public constant SENTINEL_MODULES = address(0x1);

    /// @notice OWNER is zero or Foundry's default sender.
    error OwnerRequired();
    /// @notice On mainnet, the owner has no code or is an EIP-7702 delegated account.
    error OwnerMustBeContract(address owner);
    /// @notice The owner is a Safe that needs fewer than MIN_OWNER_THRESHOLD signatures.
    error OwnerThresholdTooLow(address owner, uint256 threshold);
    /// @notice The owner is a Safe with `module` enabled, which could act for it without signatures.
    error OwnerHasModules(address owner, address module);
    /// @notice The owner is a Safe whose module list cannot be read with `getModulesPaginated`.
    error OwnerModulesUnknown(address owner);
    /// @notice GUARDIAN is zero, Foundry's default sender, or the owner.
    error GuardianRequired();
    /// @notice The guardian is the key broadcasting the deployment.
    error GuardianIsBroadcaster(address guardian);
    /// @notice The guardian signs for the owner Safe, so one key would both act as the owner and hold its veto (SA-06).
    error GuardianSignsForOwner(address guardian);
    /// @notice The key broadcasting the deployment signs for the owner Safe (SA-06).
    error BroadcasterSignsForOwner(address broadcaster);
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

    /// @notice Rejects a missing owner and Foundry's default sender. On mainnet the owner must be a contract, not
    ///         an EIP-7702 delegated account, and a Safe must need at least MIN_OWNER_THRESHOLD (3) signatures, the
    ///         owner's call on 2026-09-30 to match the design's 3-of-5, and have no enabled module,
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
            if (threshold < MIN_OWNER_THRESHOLD) revert OwnerThresholdTooLow(owner, threshold);
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
    ///         broadcasting the deployment (the script's msg.sender), which must hold no role in the factory. When the
    ///         owner is a Safe, neither the guardian nor the broadcasting key may be one of its signers: the guardian is
    ///         the owner's veto, and a key that signs for both weakens both (SA-06).
    /// @param owner The intended factory owner.
    /// @param guardian The intended guardian.
    function checkGuardian(address owner, address guardian) public view {
        if (guardian == address(0) || guardian == DEFAULT_SENDER || guardian == owner) revert GuardianRequired();
        if (guardian == msg.sender) revert GuardianIsBroadcaster(guardian);
        // A static call, as for the threshold: an owner that is a key or a contract other than a Safe answers nothing.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = owner.staticcall(abi.encodeCall(ISafeThreshold.getOwners, ()));
        // A well-formed answer holds at least the array offset and its length.
        if (!ok || data.length < 64) return;
        address[] memory signers = abi.decode(data, (address[]));
        for (uint256 i = 0; i < signers.length; ++i) {
            if (signers[i] == guardian) revert GuardianSignsForOwner(guardian);
            if (signers[i] == msg.sender) revert BroadcasterSignsForOwner(msg.sender);
        }
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

    /// @notice Fills a zero PancakeSwap router with mainnet's on chain 1, refuses any other there, and requires code.
    ///         Off mainnet a zero router is accepted and deploys a zap that refuses every PancakeSwap leg, since a
    ///         testnet has no PancakeSwap to route to.
    /// @param given Address from the environment.
    /// @return The resolved router, or zero off mainnet for none.
    function resolvePancakeRouter(address given) public view returns (address) {
        if (block.chainid != 1 && given == address(0)) return address(0);
        return _resolve("PANCAKE_ROUTER", given, MAINNET_PANCAKE_ROUTER);
    }

    /// @notice Neither role may be PancakeSwap's router either: anyone can sweep a router's balance (CR-I37).
    /// @param pancakeRouter The resolved router, or zero for none.
    function checkRolesAreNotPancake(address owner, address guardian, address pancakeRouter) public pure {
        if (pancakeRouter != address(0) && (owner == pancakeRouter || guardian == pancakeRouter)) {
            revert RoleIsMarketContract(pancakeRouter);
        }
    }

    /// @notice Fills a zero stablecoin with mainnet's on chain 1 only, refuses any other there, and requires code, as
    ///         {resolveRouter} does for the router.
    /// @param name "USDC" or "USDT", for the error.
    /// @param given Address from the environment; zero takes the mainnet default on chain 1.
    /// @param mainnetDefault Mainnet's address of that stablecoin.
    /// @return The resolved stablecoin.
    function resolveStable(string memory name, address given, address mainnetDefault) public view returns (address) {
        return _resolve(name, given, mainnetDefault);
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
