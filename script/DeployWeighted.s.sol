// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {BasketBuilder} from "../src/BasketBuilder.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {DeployChecks} from "./DeployChecks.sol";

/// @notice Deploys Xindex: `WeightedIndexFactory`, which deploys the `WeightedHub` implementation every index is a
///         clone of, then a zap, a basket builder and MintRequests for that factory. Run once on Ethereum and once
///         on BNB Chain, each with that chain's owner Safe and guardian's Safe: two deployments that share nothing,
///         each holding its chain's coins in kind (`design/2026-11-13-bnb-chain-deployment.md`). The owner, the
///         guardian and the market are checked by `DeployChecks`. No oracle is deployed, named or read: an index
///         rebalances through an auction on units alone (`design/2026-11-10-oracle-free-rebalance.md`).
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/DeployWeighted.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER               Required. Factory owner. On Ethereum and BNB Chain it must be a contract that is not an
///                       EIP-7702 delegated account, and a Safe must require at least three signatures and have no
///                       enabled module. Any other contract needs OWNER_IS_NOT_A_SAFE.
///   OWNER_IS_NOT_A_SAFE Optional, OWNER's address again or unset. On those two chains, the operator's acknowledgment that
///                       OWNER is a contract but not a Safe, such as a timelock; without it such an owner is refused
///                       (A7-08). Only OWNER's own address acknowledges OWNER, so one left in `.env` from an earlier
///                       run acknowledges no other owner. It lowers no Safe rule, and the owner's code hash is logged.
///   GUARDIAN            Required. The guardian's Safe, the factory's guardian. It cancels pending listings and
///                       rebalances, delists tokens, and starts a rebalance that leaves chosen components untouched.
///                       Must differ from OWNER; replacing the guardian later takes 7 days.
///   UNIVERSAL_ROUTER    Uniswap's Universal Router, through which the zap swaps. Required off Ethereum and BNB
///                       Chain; on those two it defaults to the chain's address book, and nothing else is accepted.
///   USDC, USDT          The two stablecoins, the only currencies the zap and the basket builder take and pay and
///                       MintRequests escrows. Resolved like the router.
contract DeployWeighted is DeployChecks {
    /// @notice keccak256 of `WeightedIndexFactory`'s init code, which embeds the `WeightedHub` implementation's, as this
    ///         commit builds it with this repository's foundry.toml. With the two below, this is the release record a
    ///         mainnet broadcast is bound to (CF-5): `deploy` refuses to broadcast on a pinned chain from any other build (a
    ///         local edit, a lib/ checkout off foundry.lock, a FOUNDRY_* override), and `test_CF5_*` in
    ///         test/Scripts.t.sol fails until these equal the build, so only a reviewed, CI-green commit moves them.
    bytes32 public constant FACTORY_INITCODE_HASH = 0xa598d1316b59812a8b21bf4d3563987b2063fc1dde0537cb6f8631fc96a1f78f;
    /// @notice keccak256 of `IndexZap`'s init code, as above.
    bytes32 public constant ZAP_INITCODE_HASH = 0x9e7dc1ebb691c9447274d704da2c7235c2a08d37d9b424c3b79d60a5a1de62f6;
    /// @notice keccak256 of `BasketBuilder`'s init code, as above.
    bytes32 public constant BUILDER_INITCODE_HASH = 0xfefe7932b18456b13f2c217bb2461096e2a23d4bff029061fdccad2b17ba65a0;
    /// @notice keccak256 of `MintRequests`' init code, as above.
    bytes32 public constant REQUESTS_INITCODE_HASH = 0x0b1cb66be1ad289c36bed6eda4183b82ae5814852bdb94ee9232739a344b39d9;

    /// @dev How many contracts the release record covers: the factory, the zap, the builder and MintRequests.
    uint256 private constant RELEASED = 4;

    /// @notice The local build of `name` is not the one this commit records: its init code hashes to `actual`.
    error BuildNotReleased(string name, bytes32 expected, bytes32 actual);

    /// @notice Reads OWNER, GUARDIAN and the market addresses from the environment and calls {deploy}.
    function run()
        external
        returns (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
    {
        return deploy(
            vm.envAddress("OWNER"),
            vm.envAddress("GUARDIAN"),
            vm.envOr("UNIVERSAL_ROUTER", address(0)),
            vm.envOr("USDC", address(0)),
            vm.envOr("USDT", address(0)),
            vm.envOr("OWNER_IS_NOT_A_SAFE", address(0))
        );
    }

    /// @notice Checks the owner and guardian, resolves the market, and broadcasts the factory (which deploys the
    ///         `WeightedHub` implementation), the zap, the basket builder and MintRequests. Logs every address and the
    ///         release record's code hashes.
    /// @param owner Factory owner; see {checkOwner}.
    /// @param guardian The guardian's Safe; see {checkGuardian}.
    /// @param router Uniswap's Universal Router, through which the zap and the builder swap; see {resolveRouter}.
    /// @param usdc USDC for the zap, the builder and MintRequests; see {resolveStable}.
    /// @param usdt USDT for the zap, the builder and MintRequests; see {resolveStable}.
    /// @param acknowledged The owner the operator acknowledges is a contract but not a Safe; see {checkOwner}.
    /// @return factory The deployed factory.
    /// @return zap The deployed zap.
    /// @return builder The deployed basket builder.
    /// @return requests The deployed MintRequests.
    function deploy(address owner, address guardian, address router, address usdc, address usdt, address acknowledged)
        public
        returns (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
    {
        checkBroadcaster();
        checkOwner(owner, acknowledged);
        checkGuardian(owner, guardian);
        router = resolveRouter(router);
        usdc = resolveStable("USDC", usdc, pinnedUsdc());
        usdt = resolveStable("USDT", usdt, pinnedUsdt());
        checkRolesAreNotMarket(owner, guardian, router);
        // What is broadcast on a mainnet is the build this commit records, never whatever the local tree compiles (CF-5).
        if (isPinnedChain()) checkBuild(releaseInitCodeHashes());

        vm.startBroadcast();
        factory = new WeightedIndexFactory(owner, guardian);
        // The zap types its factory as `IIndexFactory`, and calls only `isIndex` on it, which this factory answers.
        zap = new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(router), usdc, usdt);
        builder = new BasketBuilder(IIndexFactory(address(factory)), IUniversalRouter(router), usdc, usdt);
        requests = new MintRequests(address(factory), usdc, usdt);
        vm.stopBroadcast();

        console2.log("WeightedIndexFactory:    ", address(factory));
        console2.log("WeightedHub impl:        ", factory.IMPLEMENTATION());
        console2.log("IndexZap:                ", address(zap));
        console2.log("BasketBuilder:           ", address(builder));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Universal Router:        ", router);
        console2.log("PoolManager:             ", zap.POOL_MANAGER());
        console2.log("MintRequests:            ", address(requests));
        console2.log("USDC:                    ", usdc);
        console2.log("USDT:                    ", usdt);

        bytes32[5] memory codehashes = checkDeployment(factory, zap, builder, requests);
        console2.log("WeightedIndexFactory hash:", vm.toString(codehashes[0]));
        console2.log("WeightedHub impl hash:   ", vm.toString(codehashes[1]));
        console2.log("IndexZap hash:           ", vm.toString(codehashes[2]));
        console2.log("BasketBuilder hash:      ", vm.toString(codehashes[3]));
        console2.log("MintRequests hash:       ", vm.toString(codehashes[4]));
    }

    /// @notice Checks that a factory, its implementation, a zap, a basket builder and MintRequests are one deployment,
    ///         and returns the runtime code hashes to freeze in the release record. Run it again later against the
    ///         recorded addresses: equal hashes prove the deployed code is unchanged.
    /// @return codehashes keccak256 of the runtime code of the factory, the `WeightedHub` implementation, the zap, the
    ///         builder and MintRequests.
    function checkDeployment(WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
        public
        view
        returns (bytes32[5] memory codehashes)
    {
        WeightedHub implementation = WeightedHub(factory.IMPLEMENTATION());
        address implementationFactory = implementation.FACTORY();
        if (implementationFactory != address(factory)) {
            revert WrongWiring("WeightedHub.FACTORY", address(factory), implementationFactory);
        }
        address zapFactory = address(zap.FACTORY());
        if (zapFactory != address(factory)) revert WrongWiring("IndexZap.FACTORY", address(factory), zapFactory);
        address builderFactory = address(builder.FACTORY());
        if (builderFactory != address(factory)) {
            revert WrongWiring("BasketBuilder.FACTORY", address(factory), builderFactory);
        }
        if (address(builder.ROUTER()) != address(zap.ROUTER())) {
            revert WrongWiring("BasketBuilder.ROUTER", address(zap.ROUTER()), address(builder.ROUTER()));
        }
        address requestsFactory = requests.FACTORY();
        if (requestsFactory != address(factory)) {
            revert WrongWiring("MintRequests.FACTORY", address(factory), requestsFactory);
        }
        // The three take and pay the same two stablecoins.
        _checkStables("IndexZap", zap.USDC(), zap.USDT(), requests);
        _checkStables("BasketBuilder", builder.USDC(), builder.USDT(), requests);
        codehashes = [
            address(factory).codehash,
            address(implementation).codehash,
            address(zap).codehash,
            address(builder).codehash,
            address(requests).codehash
        ];
    }

    /// @dev Reverts WrongWiring unless `name`'s stablecoins are MintRequests'.
    function _checkStables(string memory name, address usdc, address usdt, MintRequests requests) private view {
        if (usdc != requests.USDC()) revert WrongWiring(string.concat(name, ".USDC"), requests.USDC(), usdc);
        if (usdt != requests.USDT()) revert WrongWiring(string.concat(name, ".USDT"), requests.USDT(), usdt);
    }

    /// @notice The init-code hashes a mainnet broadcast must match: the factory's, the zap's, the builder's and
    ///         MintRequests'.
    function releaseInitCodeHashes() public pure virtual returns (bytes32[RELEASED] memory) {
        return [FACTORY_INITCODE_HASH, ZAP_INITCODE_HASH, BUILDER_INITCODE_HASH, REQUESTS_INITCODE_HASH];
    }

    /// @notice The init-code hashes of the factory, the zap, the builder and MintRequests as this build compiled them.
    function buildInitCodeHashes() public pure returns (bytes32[RELEASED] memory) {
        return [
            keccak256(type(WeightedIndexFactory).creationCode),
            keccak256(type(IndexZap).creationCode),
            keccak256(type(BasketBuilder).creationCode),
            keccak256(type(MintRequests).creationCode)
        ];
    }

    /// @notice Reverts BuildNotReleased unless this build's init-code hashes equal `expected`, in the order of
    ///         {releaseInitCodeHashes}.
    function checkBuild(bytes32[RELEASED] memory expected) public pure {
        bytes32[RELEASED] memory actual = buildInitCodeHashes();
        string[RELEASED] memory names = ["WeightedIndexFactory", "IndexZap", "BasketBuilder", "MintRequests"];
        for (uint256 i = 0; i < actual.length; ++i) {
            if (actual[i] != expected[i]) revert BuildNotReleased(names[i], expected[i], actual[i]);
        }
    }
}
