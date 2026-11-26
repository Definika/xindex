// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {WeightedIndexFactory} from "../src/WeightedIndexFactory.sol";
import {WeightedHub} from "../src/WeightedHub.sol";
import {WeightedMath} from "../src/WeightedMath.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {BasketBuilder} from "../src/BasketBuilder.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IUniversalRouterSwaps} from "../src/interfaces/IUniversalRouterSwaps.sol";
import {IPythPrices} from "../src/interfaces/IPythPrices.sol";
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
///   PYTH                Pyth's price contract, which every rebalance fill of the factory is checked against. On
///                       Ethereum, BNB Chain and Base it is the address book's, and nothing else is accepted; elsewhere
///                       unset builds a factory whose fills no price checks.
contract DeployWeighted is DeployChecks {
    /// @notice keccak256 of `WeightedIndexFactory`'s init code, which embeds the `WeightedHub` implementation's and
    ///         `PythPrices`', as this
    ///         commit builds it with this repository's foundry.toml. With the two below, this is the release record a
    ///         mainnet broadcast is bound to (CF-5): `deploy` refuses to broadcast on a pinned chain from any other build (a
    ///         local edit, a lib/ checkout off foundry.lock, a FOUNDRY_* override), and `test_CF5_*` in
    ///         test/Scripts.t.sol fails until these equal the build, so only a reviewed, CI-green commit moves them.
    bytes32 public constant FACTORY_INITCODE_HASH = 0xbefe3599e77acdc2f1b38727c1a260d83cec48f136b42480099bd2ff10058ea9;
    /// @notice keccak256 of `IndexZap`'s init code, as above.
    bytes32 public constant ZAP_INITCODE_HASH = 0x6d07e0ce44108c62a6135fb3b08d1dc50694b92575e74303146d021a43f47966;
    /// @notice keccak256 of `BasketBuilder`'s init code, as above.
    bytes32 public constant BUILDER_INITCODE_HASH = 0x33f9a6bf792f320275cdd0a4ab2b018aa0d4e11545b3e6b8e2b547ec32d5ff2d;
    /// @notice keccak256 of `WeightedMath`'s init code, as above: deployed on its own since 2026-11-23, before the
    ///         factory, which the factory's init code no longer has room to embed (EIP-3860).
    bytes32 public constant MATH_INITCODE_HASH = 0x549b47e8001ddecbf0c40c630a2d2f39439601a439ea0564efdcbc9b87f9a911;
    /// @notice keccak256 of `MintRequests`' init code, as above.
    bytes32 public constant REQUESTS_INITCODE_HASH = 0x41e888e2c8f02f0e76301ef6b8b614e6494aa70bac20f07590979ddc448047dc;

    /// @dev How many contracts the release record covers: the factory, the zap, the builder, MintRequests and the math.
    uint256 private constant RELEASED = 5;

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
            vm.envOr("PYTH", address(0)),
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
    /// @param pyth Pyth's contract, which the factory's fills are checked against; see {resolvePyth}.
    /// @param acknowledged The owner the operator acknowledges is a contract but not a Safe; see {checkOwner}.
    /// @return factory The deployed factory.
    /// @return zap The deployed zap.
    /// @return builder The deployed basket builder.
    /// @return requests The deployed MintRequests.
    function deploy(
        address owner,
        address guardian,
        address router,
        address usdc,
        address usdt,
        address pyth,
        address acknowledged
    ) public returns (WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests) {
        checkBroadcaster();
        checkOwner(owner, acknowledged);
        checkGuardian(owner, guardian);
        router = resolveRouter(router);
        usdc = resolveStable("USDC", usdc, pinnedUsdc());
        usdt = resolveStable("USDT", usdt, pinnedUsdt());
        pyth = resolvePyth(pyth);
        checkRolesAreNotMarket(owner, guardian, router);
        // What is broadcast on a mainnet is the build this commit records, never whatever the local tree compiles (CF-5).
        if (isPinnedChain()) checkBuild(releaseInitCodeHashes());

        vm.startBroadcast();
        // The math first: the factory takes it for the implementation it deploys.
        factory = new WeightedIndexFactory(owner, guardian, pyth, address(new WeightedMath()));
        // The zap types its factory as `IIndexFactory`, and calls only `isIndex` on it, which this factory answers.
        zap = new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(router), resolveLocalVenue(), usdc, usdt);
        builder = new BasketBuilder(
            IIndexFactory(address(factory)), IUniversalRouter(router), resolveLocalVenue(), usdc, usdt
        );
        requests = new MintRequests(address(factory), usdc, usdt);
        vm.stopBroadcast();

        console2.log("WeightedIndexFactory:    ", address(factory));
        console2.log("WeightedHub impl:        ", factory.IMPLEMENTATION());
        console2.log("WeightedMath:            ", WeightedHub(factory.IMPLEMENTATION()).MATH());
        console2.log("IndexZap:                ", address(zap));
        console2.log("BasketBuilder:           ", address(builder));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Universal Router:        ", router);
        console2.log("PoolManager:             ", zap.POOL_MANAGER());
        console2.log("Chain's own DEX router:  ", zap.LOCAL_ROUTER());
        console2.log("MintRequests:            ", address(requests));
        console2.log("USDC:                    ", usdc);
        console2.log("USDT:                    ", usdt);
        console2.log("Pyth:                    ", pyth);
        console2.log("PythPrices:              ", factory.PRICES());

        bytes32[6] memory codehashes = checkDeployment(factory, zap, builder, requests);
        console2.log("WeightedIndexFactory hash:", vm.toString(codehashes[0]));
        console2.log("WeightedHub impl hash:   ", vm.toString(codehashes[1]));
        console2.log("IndexZap hash:           ", vm.toString(codehashes[2]));
        console2.log("BasketBuilder hash:      ", vm.toString(codehashes[3]));
        console2.log("MintRequests hash:       ", vm.toString(codehashes[4]));
        console2.log("WeightedMath hash:       ", vm.toString(codehashes[5]));
    }

    /// @notice Checks that a factory, its implementation, a zap, a basket builder and MintRequests are one deployment,
    ///         and returns the runtime code hashes to freeze in the release record. Run it again later against the
    ///         recorded addresses: equal hashes prove the deployed code is unchanged.
    /// @return codehashes keccak256 of the runtime code of the factory, the `WeightedHub` implementation, the zap, the
    ///         builder, MintRequests and the implementation's `WeightedMath`.
    function checkDeployment(WeightedIndexFactory factory, IndexZap zap, BasketBuilder builder, MintRequests requests)
        public
        view
        returns (bytes32[6] memory codehashes)
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
        _checkLocalVenue(zap, builder);
        address requestsFactory = requests.FACTORY();
        if (requestsFactory != address(factory)) {
            revert WrongWiring("MintRequests.FACTORY", address(factory), requestsFactory);
        }
        // On a pinned chain the factory checks its fills against the chain's own Pyth.
        address prices = factory.PRICES();
        if (implementation.PRICES() != prices) {
            revert WrongWiring("WeightedHub.PRICES", prices, implementation.PRICES());
        }
        if (isPinnedChain()) {
            address pyth = prices == address(0) ? address(0) : IPythPrices(prices).PYTH();
            if (pyth != pinnedPyth()) revert WrongWiring("PythPrices.PYTH", pinnedPyth(), pyth);
        }
        // The three take and pay the same two stablecoins.
        _checkStables("IndexZap", zap.USDC(), zap.USDT(), requests);
        _checkStables("BasketBuilder", builder.USDC(), builder.USDT(), requests);
        codehashes = [
            address(factory).codehash,
            address(implementation).codehash,
            address(zap).codehash,
            address(builder).codehash,
            address(requests).codehash,
            implementation.MATH().codehash
        ];
    }

    /// @dev Reverts WrongWiring unless the zap and the builder name the same DEX beside Uniswap, and on a pinned chain
    ///      the one its address book names (the owner's call of 2026-11-26). The addresses alone are compared: the
    ///      engine's constructor ties each DEX to the addresses it uses, so the same addresses are the same DEX.
    function _checkLocalVenue(IndexZap zap, BasketBuilder builder) private view {
        address[DEX_ADDRESSES] memory zaps =
            [zap.LOCAL_ROUTER(), zap.AERO_CL_FACTORY(), zap.AERO_VOLATILE_FACTORY(), zap.AERO_STABLE_FACTORY()];
        address[DEX_ADDRESSES] memory builders = [
            builder.LOCAL_ROUTER(),
            builder.AERO_CL_FACTORY(),
            builder.AERO_VOLATILE_FACTORY(),
            builder.AERO_STABLE_FACTORY()
        ];
        IUniversalRouterSwaps.LocalVenue memory pinned = pinnedLocalVenue();
        address[DEX_ADDRESSES] memory book =
            [pinned.router, pinned.clFactory, pinned.volatileFactory, pinned.stableFactory];
        string[DEX_ADDRESSES] memory names =
            ["LOCAL_ROUTER", "AERO_CL_FACTORY", "AERO_VOLATILE_FACTORY", "AERO_STABLE_FACTORY"];
        for (uint256 i = 0; i < DEX_ADDRESSES; ++i) {
            if (builders[i] != zaps[i]) {
                revert WrongWiring(string.concat("BasketBuilder.", names[i]), zaps[i], builders[i]);
            }
            if (isPinnedChain() && zaps[i] != book[i]) {
                revert WrongWiring(string.concat("IndexZap.", names[i]), book[i], zaps[i]);
            }
        }
    }

    /// @dev Reverts WrongWiring unless `name`'s stablecoins are MintRequests'.
    function _checkStables(string memory name, address usdc, address usdt, MintRequests requests) private view {
        if (usdc != requests.USDC()) revert WrongWiring(string.concat(name, ".USDC"), requests.USDC(), usdc);
        if (usdt != requests.USDT()) revert WrongWiring(string.concat(name, ".USDT"), requests.USDT(), usdt);
    }

    /// @notice The init-code hashes a mainnet broadcast must match: the factory's, the zap's, the builder's,
    ///         MintRequests' and the math's.
    function releaseInitCodeHashes() public pure virtual returns (bytes32[RELEASED] memory) {
        return
            [
                FACTORY_INITCODE_HASH,
                ZAP_INITCODE_HASH,
                BUILDER_INITCODE_HASH,
                REQUESTS_INITCODE_HASH,
                MATH_INITCODE_HASH
            ];
    }

    /// @notice The init-code hashes of the factory, the zap, the builder, MintRequests and the math as this build compiled
    ///         them.
    function buildInitCodeHashes() public pure returns (bytes32[RELEASED] memory) {
        return [
            keccak256(type(WeightedIndexFactory).creationCode),
            keccak256(type(IndexZap).creationCode),
            keccak256(type(BasketBuilder).creationCode),
            keccak256(type(MintRequests).creationCode),
            keccak256(type(WeightedMath).creationCode)
        ];
    }

    /// @notice Reverts BuildNotReleased unless this build's init-code hashes equal `expected`, in the order of
    ///         {releaseInitCodeHashes}.
    function checkBuild(bytes32[RELEASED] memory expected) public pure {
        bytes32[RELEASED] memory actual = buildInitCodeHashes();
        string[RELEASED] memory names =
            ["WeightedIndexFactory", "IndexZap", "BasketBuilder", "MintRequests", "WeightedMath"];
        for (uint256 i = 0; i < actual.length; ++i) {
            if (actual[i] != expected[i]) revert BuildNotReleased(names[i], expected[i], actual[i]);
        }
    }
}
