// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {DeployChecks} from "./DeployChecks.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";

/// @notice Deploys Xindex: `WeightedIndexFactory`, which deploys the `WeightedHub` implementation every index is a
///         clone of, then a zap and MintRequests for that factory. Run once, on Ethereum, with the owner Safe and the
///         guardian (`design/2026-10-10-one-index-wormhole-legs.md`). The owner, the guardian and the market are
///         checked by `DeployChecks`, and neither role may be the Pyth contract.
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/DeployWeighted.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER               Required. Factory owner. On Ethereum it must be a contract that is not an
///                       EIP-7702 delegated account, and a Safe must require at least three signatures and have no
///                       enabled module.
///   GUARDIAN            Required. Can cancel pending listings and rebalances, start a rebalance that leaves a paused
///                       component or one whose price feed stopped untouched, and delist tokens. Must differ from OWNER;
///                       replacing it later takes 7 days.
///   PYTH                The Pyth contract every index reads its prices from. Required off Ethereum; on Ethereum
///                       it defaults to the address book, and nothing else is accepted there.
///   UNIVERSAL_ROUTER    Uniswap's Universal Router, through which the zap swaps. Resolved like PYTH.
///   USDC, USDT          The two stablecoins MintRequests escrows. Resolved like PYTH.
contract DeployWeighted is DeployChecks {
    /// @notice Default {resolvePyth} uses on chain 1, from `MainnetAddresses`.
    address public constant MAINNET_PYTH = MainnetAddresses.PYTH;

    /// @notice keccak256 of `WeightedIndexFactory`'s init code, which embeds the `WeightedHub` implementation's, as this
    ///         commit builds it with this repository's foundry.toml. With the two below, this is the release record a
    ///         mainnet broadcast is bound to (CF-5): `deploy` refuses to broadcast on Ethereum from any other build (a
    ///         local edit, a lib/ checkout off foundry.lock, a FOUNDRY_* override), and `test_CF5_*` in
    ///         test/Scripts.t.sol fails until these equal the build, so only a reviewed, CI-green commit moves them.
    bytes32 public constant FACTORY_INITCODE_HASH = 0x861f26a723d77ea886c5cb410dddc28f3eb20245d0c3402914d043913b6a63b0;
    /// @notice keccak256 of `IndexZap`'s init code, as above.
    bytes32 public constant ZAP_INITCODE_HASH = 0xefd5c70921786723ddb4ade5681787fe722e5753f977534143a8dcb2becfe38d;
    /// @notice keccak256 of `MintRequests`' init code, as above.
    bytes32 public constant REQUESTS_INITCODE_HASH = 0xac5cf69355ae8a1c008e465e5a8bb980e8ae060b123f2851c4fd7914f74d7d4e;

    /// @dev How many contracts the release record covers: the factory, the zap and MintRequests.
    uint256 private constant RELEASED = 3;

    /// @notice The local build of `name` is not the one this commit records: its init code hashes to `actual`.
    error BuildNotReleased(string name, bytes32 expected, bytes32 actual);

    /// @notice Reads OWNER, GUARDIAN, PYTH and the optional market addresses from the environment and calls {deploy}.
    function run() external returns (WeightedIndexFactory factory, IndexZap zap, MintRequests requests) {
        return deploy(
            vm.envAddress("OWNER"),
            vm.envAddress("GUARDIAN"),
            vm.envOr("PYTH", address(0)),
            vm.envOr("UNIVERSAL_ROUTER", address(0)),
            vm.envOr("USDC", address(0)),
            vm.envOr("USDT", address(0))
        );
    }

    /// @notice Checks the owner and guardian, resolves Pyth and the market, and broadcasts the factory (which deploys
    ///         the `WeightedHub` implementation), the zap and MintRequests. Logs every address and the release record's
    ///         code hashes.
    /// @param owner Factory owner; see {checkOwner}.
    /// @param guardian Initial guardian; see {checkGuardian}.
    /// @param pyth Pyth's contract; see {resolvePyth}.
    /// @param router Uniswap's Universal Router, through which the zap swaps; see {resolveRouter}.
    /// @param usdc USDC for MintRequests; see {resolveStable}.
    /// @param usdt USDT for MintRequests; see {resolveStable}.
    /// @return factory The deployed factory.
    /// @return zap The deployed zap.
    /// @return requests The deployed MintRequests.
    function deploy(address owner, address guardian, address pyth, address router, address usdc, address usdt)
        public
        returns (WeightedIndexFactory factory, IndexZap zap, MintRequests requests)
    {
        checkOwner(owner);
        checkGuardian(owner, guardian);
        pyth = resolvePyth(pyth);
        router = resolveRouter(router);
        usdc = resolveStable("USDC", usdc, pinnedUsdc());
        usdt = resolveStable("USDT", usdt, pinnedUsdt());
        checkRolesAreNotMarket(owner, guardian, router);
        // A factory owned by Pyth could never be administered, and Pyth as guardian would veto for nobody.
        if (owner == pyth || guardian == pyth) revert RoleIsMarketContract(pyth);
        // What is broadcast on Ethereum is the build this commit records, never whatever the local tree compiles (CF-5).
        if (isPinnedChain()) checkBuild(releaseInitCodeHashes());

        vm.startBroadcast();
        factory = new WeightedIndexFactory(owner, guardian, pyth);
        // The zap types its factory as `IIndexFactory`, and calls only `isIndex` on it, which this factory answers.
        zap = new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(router));
        requests = new MintRequests(address(factory), usdc, usdt);
        vm.stopBroadcast();

        console2.log("WeightedIndexFactory:    ", address(factory));
        console2.log("WeightedHub impl:        ", factory.IMPLEMENTATION());
        console2.log("Pyth:                    ", pyth);
        console2.log("IndexZap:                ", address(zap));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Universal Router:        ", router);
        console2.log("PoolManager:             ", zap.POOL_MANAGER());
        console2.log("MintRequests:            ", address(requests));
        console2.log("USDC:                    ", usdc);
        console2.log("USDT:                    ", usdt);

        bytes32[4] memory codehashes = checkDeployment(factory, zap, requests);
        console2.log("WeightedIndexFactory hash:", vm.toString(codehashes[0]));
        console2.log("WeightedHub impl hash:   ", vm.toString(codehashes[1]));
        console2.log("IndexZap hash:           ", vm.toString(codehashes[2]));
        console2.log("MintRequests hash:       ", vm.toString(codehashes[3]));
    }

    /// @notice Checks that a factory, its implementation, a zap and MintRequests are one deployment reading one Pyth,
    ///         and returns the runtime code hashes to freeze in the release record. Run it again later against the
    ///         recorded addresses: equal hashes prove the deployed code is unchanged.
    /// @return codehashes keccak256 of the runtime code of the factory, the `WeightedHub` implementation, the zap and
    ///         MintRequests.
    function checkDeployment(WeightedIndexFactory factory, IndexZap zap, MintRequests requests)
        public
        view
        returns (bytes32[4] memory codehashes)
    {
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        address implementationFactory = implementation.FACTORY();
        if (implementationFactory != address(factory)) {
            revert WrongWiring("WeightedHub.FACTORY", address(factory), implementationFactory);
        }
        address implementationPyth = implementation.PYTH();
        if (implementationPyth != factory.PYTH()) {
            revert WrongWiring("WeightedHub.PYTH", factory.PYTH(), implementationPyth);
        }
        address zapFactory = address(zap.FACTORY());
        if (zapFactory != address(factory)) revert WrongWiring("IndexZap.FACTORY", address(factory), zapFactory);
        address requestsFactory = requests.FACTORY();
        if (requestsFactory != address(factory)) {
            revert WrongWiring("MintRequests.FACTORY", address(factory), requestsFactory);
        }
        codehashes = [
            address(factory).codehash,
            address(implementation).codehash,
            address(zap).codehash,
            address(requests).codehash
        ];
    }

    /// @notice The init-code hashes a mainnet broadcast must match: the factory's, the zap's and MintRequests'.
    function releaseInitCodeHashes() public pure virtual returns (bytes32[RELEASED] memory) {
        return [FACTORY_INITCODE_HASH, ZAP_INITCODE_HASH, REQUESTS_INITCODE_HASH];
    }

    /// @notice The init-code hashes of the factory, the zap and MintRequests as this build compiled them.
    function buildInitCodeHashes() public pure returns (bytes32[RELEASED] memory) {
        return [
            keccak256(type(WeightedIndexFactory).creationCode),
            keccak256(type(IndexZap).creationCode),
            keccak256(type(MintRequests).creationCode)
        ];
    }

    /// @notice Reverts BuildNotReleased unless this build's init-code hashes equal `expected`, in the order of
    ///         {releaseInitCodeHashes}.
    function checkBuild(bytes32[RELEASED] memory expected) public pure {
        bytes32[RELEASED] memory actual = buildInitCodeHashes();
        string[RELEASED] memory names = ["WeightedIndexFactory", "IndexZap", "MintRequests"];
        for (uint256 i = 0; i < actual.length; ++i) {
            if (actual[i] != expected[i]) revert BuildNotReleased(names[i], expected[i], actual[i]);
        }
    }

    /// @notice Fills a zero Pyth with mainnet's on chain 1 only, refuses any other there, and requires code, as
    ///         {resolveRouter} does for the router: on mainnet the prices every index settles at come from the one
    ///         contract the release names.
    /// @param given Address from the environment; zero takes the mainnet default on chain 1.
    /// @return The resolved Pyth.
    function resolvePyth(address given) public view returns (address) {
        return resolveStable("PYTH", given, pinnedPyth());
    }
}
