// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {PythIds} from "./PythIds.sol";
import {ScriptUtils} from "./ScriptUtils.sol";

/// @notice The checks every deployment of a factory runs before it broadcasts: the owner, the guardian, the roles
///         against the market, and the market addresses themselves. `DeployWeighted` runs them on each chain it
///         deploys to, so the rules on who may own a factory exist once. Ethereum (1) is pinned to its address book,
///         `MainnetAddresses`: there the market addresses are the book's and nothing else; elsewhere they come from the
///         environment.
abstract contract DeployChecks is Script {
    /// @notice Default {resolveRouter} uses on chain 1, from `MainnetAddresses`.
    address public constant MAINNET_UNIVERSAL_ROUTER = MainnetAddresses.UNIVERSAL_ROUTER;
    /// @notice Fewest signatures a Safe owner may need on a mainnet: the design's 3-of-5 hardware wallets held by
    ///         separate people (the owner's call on 2026-09-30).
    uint256 public constant MIN_OWNER_THRESHOLD = 3;
    /// @notice Start of a Safe's module list.
    address public constant SENTINEL_MODULES = address(0x1);

    /// @notice OWNER is zero or Foundry's default sender.
    error OwnerRequired();
    /// @notice On a pinned chain, the owner has no code or is an EIP-7702 delegated account.
    error OwnerMustBeContract(address owner);
    /// @notice The owner is a Safe that needs fewer than MIN_OWNER_THRESHOLD signatures.
    error OwnerThresholdTooLow(address owner, uint256 threshold);
    /// @notice The owner is a Safe with `module` enabled, which could act for it without signatures.
    error OwnerHasModules(address owner, address module);
    /// @notice The owner is a Safe whose module list cannot be read with `getModulesPaginated`.
    error OwnerModulesUnknown(address owner);
    /// @notice The owner answers no Safe threshold, and OWNER_IS_NOT_A_SAFE does not name it.
    error OwnerNotASafe(address owner);
    /// @notice GUARDIAN is zero, Foundry's default sender, or the owner.
    error GuardianRequired();
    /// @notice The guardian is the key broadcasting the deployment, or a Safe that key signs for.
    error GuardianIsBroadcaster(address guardian);
    /// @notice The guardian signs for the owner Safe, so one key would both act as the owner and hold its veto (SA-06).
    error GuardianSignsForOwner(address guardian);
    /// @notice The guardian is a Safe that shares `signer` with the owner Safe, directly or through a signer that is
    ///         itself a Safe, so one key would sign on both sides (SA-06).
    error GuardianSharesOwnerSigner(address guardian, address signer);
    /// @notice The key broadcasting the deployment signs for the owner Safe (SA-06).
    error BroadcasterSignsForOwner(address broadcaster);
    /// @notice The owner or guardian is one of the market contracts.
    error RoleIsMarketContract(address account);
    /// @notice On a pinned chain, the market address `name` was set to `given` instead of that chain's default.
    error MainnetOverride(string name, address given);
    /// @notice Off the pinned chain, the market address `name` must be set.
    error AddressRequired(string name);
    /// @notice The market address `name` has no code.
    error AddressHasNoCode(string name, address account);
    /// @notice `name` points at `actual` instead of `expected`, so these contracts are not one deployment.
    error WrongWiring(string name, address expected, address actual);
    /// @notice A mainnet run's broadcaster is Foundry's default sender: pass `--sender` with the signing key's address.
    error BroadcasterRequired();

    /// @notice {checkOwner} with no acknowledgment: on a pinned chain only a Safe passes.
    /// @param owner The intended factory owner.
    function checkOwner(address owner) public view {
        checkOwner(owner, address(0));
    }

    /// @notice Rejects a missing owner and Foundry's default sender. On a pinned chain, a mainnet, the owner must be a
    ///         contract, not an EIP-7702 delegated account. A Safe must need at least MIN_OWNER_THRESHOLD (3)
    ///         signatures, the owner's call on 2026-09-30 to match the design's 3-of-5, and have no enabled module,
    ///         because a module acts as the Safe without signatures. Modules or guards added later are not checked, so
    ///         the Safe must keep none. Any other contract, a timelock as much as a smart account with one key, is
    ///         refused unless the operator acknowledges it (A7-08): nothing here can tell who signs for it.
    /// @param owner The intended factory owner.
    /// @param acknowledged The owner the operator acknowledges is deliberately a contract that is not a Safe, from
    ///        OWNER_IS_NOT_A_SAFE, or address(0) for none. Only `owner` itself acknowledges `owner`, so one left from
    ///        an earlier run acknowledges no other owner. It lowers no Safe rule; the owner's code hash is logged.
    function checkOwner(address owner, address acknowledged) public view {
        if (owner == address(0) || owner == DEFAULT_SENDER) revert OwnerRequired();
        if (!isPinnedChain()) return;

        bytes memory code = owner.code;
        if (code.length == 0 || ScriptUtils.isDelegatedAccount(code)) revert OwnerMustBeContract(owner);
        // A Safe answers getThreshold with one word. A static call is used because a typed try/catch would revert on an
        // empty answer from a fallback.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = owner.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ()));
        if (ok && data.length == 32) {
            uint256 threshold = abi.decode(data, (uint256));
            if (threshold < MIN_OWNER_THRESHOLD) revert OwnerThresholdTooLow(owner, threshold);
            _checkNoModules(owner);
            return;
        }
        if (acknowledged != owner) revert OwnerNotASafe(owner);
        console2.log("OWNER is not a Safe, as OWNER_IS_NOT_A_SAFE acknowledges. Its code hash:");
        console2.logBytes32(owner.codehash);
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
    ///         broadcasting the deployment (the script's msg.sender), which must hold no role in the factory, neither
    ///         as the guardian nor as a signer of a guardian Safe. When the owner is a Safe, neither the guardian nor
    ///         the broadcasting key may be one of its signers, and a guardian Safe may share no signer with it: the
    ///         guardian is the owner's veto, and a key that signs for both weakens both (SA-06). Signers are compared
    ///         one level deep on each side, so a signer that is itself a Safe, such as a treasury, brings in its own.
    /// @param owner The intended factory owner.
    /// @param guardian The intended guardian.
    function checkGuardian(address owner, address guardian) public view {
        if (guardian == address(0) || guardian == DEFAULT_SENDER || guardian == owner) revert GuardianRequired();
        if (guardian == msg.sender) revert GuardianIsBroadcaster(guardian);
        address[] memory guardianKeys = _signerKeys(guardian);
        for (uint256 j = 0; j < guardianKeys.length; ++j) {
            if (guardianKeys[j] == msg.sender) revert GuardianIsBroadcaster(guardian);
        }
        address[] memory ownerKeys = _signerKeys(owner);
        for (uint256 i = 0; i < ownerKeys.length; ++i) {
            address key = ownerKeys[i];
            if (key == guardian) revert GuardianSignsForOwner(guardian);
            if (key == msg.sender) revert BroadcasterSignsForOwner(msg.sender);
            for (uint256 j = 0; j < guardianKeys.length; ++j) {
                if (guardianKeys[j] == key) revert GuardianSharesOwnerSigner(guardian, key);
            }
        }
    }

    /// @dev `account`'s signers, each followed by its own signers when it is a Safe too: one level down, so a treasury
    ///      Safe that signs for the owner, or for a guardian Safe, brings in its keys. Empty for a key or for a contract
    ///      that is not a Safe.
    function _signerKeys(address account) private view returns (address[] memory keys) {
        address[] memory signers = _signers(account);
        address[][] memory nested = new address[][](signers.length);
        uint256 total = signers.length;
        for (uint256 i = 0; i < signers.length; ++i) {
            nested[i] = _signers(signers[i]);
            total += nested[i].length;
        }
        keys = new address[](total);
        uint256 k = 0;
        for (uint256 i = 0; i < signers.length; ++i) {
            keys[k++] = signers[i];
            for (uint256 j = 0; j < nested[i].length; ++j) {
                keys[k++] = nested[i][j];
            }
        }
    }

    /// @dev `account`'s signers if it answers Safe's `getOwners`, else none. A static call, as for the threshold: a key,
    ///      or a contract other than a Safe, answers nothing.
    function _signers(address account) private view returns (address[] memory signers) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = account.staticcall(abi.encodeCall(ISafeThreshold.getOwners, ()));
        // A well-formed answer holds at least the array offset and its length.
        if (ok && data.length >= 64) signers = abi.decode(data, (address[]));
    }

    /// @notice Rejects an owner or guardian that is one of the market contracts, such as one pasted as OWNER. None of
    ///         them answers `getThreshold`, so {checkOwner} would accept any as a contract owner, and a factory owned
    ///         by one could never be administered: no listing, no guardian change, and a redeploy. An earlier version had
    ///         narrowed this to the router alone (XA-39, CR-I37), and a later one, on Ethereum, to the `default` list.
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
    /// @return list The router and the PoolManager it settles against, then, on Ethereum, every token and mint currency
    ///         in its address book.
    function marketContracts(address router) public view returns (address[] memory list) {
        address[] memory book = isPinnedChain() ? _mainnetMarket() : new address[](0);
        list = new address[](book.length + 2);
        list[0] = router;
        list[1] = IUniversalRouter(router).poolManager();
        for (uint256 i = 0; i < book.length; ++i) {
            list[i + 2] = book[i];
        }
    }

    /// @dev Every token the Ethereum address book lists, the whole `PythIds` table, then its two mint currencies.
    function _mainnetMarket() private pure returns (address[] memory list) {
        (address[] memory tokens,) = PythIds.all();
        uint256 n = tokens.length;
        list = new address[](n + 2);
        for (uint256 i = 0; i < n; ++i) {
            list[i] = tokens[i];
        }
        (list[n], list[n + 1]) = (MainnetAddresses.USDC, MainnetAddresses.USDT);
    }

    /// @notice Whether this chain's market addresses are pinned to an address book: Ethereum's alone. Keyed on the chain
    ///         id and, which a chain-id override (`--chain-id`, FOUNDRY_CHAIN_ID, `chain_id` in foundry.toml) cannot
    ///         change, on Ethereum's router having code here: a run against Ethereum's state keeps every mainnet check
    ///         however the script's chain id is set, while forge still signs for chain 1 (RX-23).
    function isPinnedChain() public view returns (bool) {
        return block.chainid == 1 || MAINNET_UNIVERSAL_ROUTER.code.length != 0;
    }

    /// @notice On a pinned chain, refuses Foundry's default sender as the broadcaster: with `--account` but no
    ///         `--sender` the keystore signs while the script's msg.sender is that default, and every check of the
    ///         broadcasting key would compare against the wrong address (RX-37). Pass `--sender` with the keystore's
    ///         address.
    function checkBroadcaster() public view {
        if (isPinnedChain() && msg.sender == DEFAULT_SENDER) revert BroadcasterRequired();
    }

    /// @notice Ethereum's Universal Router, the default on the pinned chain.
    function pinnedRouter() public pure returns (address) {
        return MAINNET_UNIVERSAL_ROUTER;
    }

    /// @notice Ethereum's USDC, the default on the pinned chain.
    function pinnedUsdc() public pure returns (address) {
        return MainnetAddresses.USDC;
    }

    /// @notice Ethereum's USDT, the default on the pinned chain.
    function pinnedUsdt() public pure returns (address) {
        return MainnetAddresses.USDT;
    }

    /// @notice Ethereum's Pyth contract, the default on the pinned chain.
    function pinnedPyth() public pure returns (address) {
        return MainnetAddresses.PYTH;
    }

    /// @notice Ethereum's WETH, the default on the pinned chain.
    function pinnedWeth() public pure returns (address) {
        return MainnetAddresses.WETH;
    }

    /// @notice Fills a zero router with the chain's default on a pinned chain only, and requires it to have code. On a
    ///         pinned chain a given address must be the default, because the router is pinned there: the zap encodes
    ///         against one version's command inputs, and a later line changed them.
    /// @param router Address from the environment; zero takes the default on a pinned chain.
    /// @return The resolved router.
    function resolveRouter(address router) public view returns (address) {
        return _resolve("UNIVERSAL_ROUTER", router, pinnedRouter());
    }

    /// @notice Fills a zero address with the pinned chain's default, refuses any other there, and requires code, as
    ///         {resolveRouter} does for the router. For the stablecoins and, in `DeployWeighted`, Pyth and WETH.
    /// @param name "USDC", "USDT", "PYTH" or "WETH", for the error.
    /// @param given Address from the environment; zero takes the default on a pinned chain.
    /// @param pinnedDefault The pinned chain's address, from {pinnedUsdc}, {pinnedUsdt}, {pinnedPyth} or {pinnedWeth}.
    /// @return The resolved address.
    function resolveStable(string memory name, address given, address pinnedDefault) public view returns (address) {
        return _resolve(name, given, pinnedDefault);
    }

    function _resolve(string memory name, address given, address pinnedDefault) private view returns (address) {
        if (given == address(0)) {
            if (!isPinnedChain()) revert AddressRequired(name);
            given = pinnedDefault;
        } else if (isPinnedChain() && given != pinnedDefault) {
            revert MainnetOverride(name, given);
        }
        if (given.code.length == 0) revert AddressHasNoCode(name, given);
        return given;
    }
}
