// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {HybridIndexFactory} from "../src/HybridIndexFactory.sol";
import {HybridHub} from "../src/HybridHub.sol";
import {HybridHubModule} from "../src/hybrid/HybridHubModule.sol";
import {HybridHubExtension} from "../src/hybrid/HybridHubExtension.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {MintRequests} from "../src/MintRequests.sol";
import {IIndexFactory} from "../src/interfaces/IIndexFactory.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {MainnetAddresses} from "./MainnetAddresses.sol";
import {DeployChecks} from "./DeployChecks.sol";

/// @notice Deploys v5's one factory, `HybridIndexFactory`, with the `HybridHub` template and its module and extension,
///         then the zap and MintRequests. The factory deploys the `WeightedHub` implementation itself: an index of
///         Ethereum tokens only is a `WeightedHub` clone, and one holding any vault token is a `HybridHub` clone. Both
///         rebalance to the creator's weights at Pyth prices. DRAFT for v5 (2026-10-06): its tests wait on the safety
///         pass.
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/Deploy.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER               Required. Factory owner. On mainnet it must be a contract that is not an EIP-7702 delegated
///                       account, and a Safe must require at least three signatures and have no enabled module.
///   GUARDIAN            Required. Can cancel pending listings, supply batches and rebalances, start a rebalance
///                       that leaves a paused component untouched, and delist tokens; on vault chains, cancel a pending
///                       chain and any vault proposal but a freezer change, and freeze a chain for 14 days. Must differ
///                       from OWNER; replacing it later takes 7 days.
///   UNIVERSAL_ROUTER    Uniswap's Universal Router, through which the zap swaps. Required off mainnet; defaults on
///                       chain 1 to the 2.0.0 deployment.
///   USDC, USDT          The two stablecoins MintRequests escrows. Required off mainnet; default on chain 1 to
///                       mainnet's.
///   PYTH                The Pyth contract every index reads its prices from. Required off mainnet; defaults on chain
///                       1 to `MainnetAddresses.PYTH`, and nothing else is accepted there.
contract Deploy is DeployChecks {
    /// @notice Reads OWNER, GUARDIAN and the optional market addresses from the environment and calls {deploy}.
    function run() external returns (HybridIndexFactory factory, IndexZap zap, MintRequests requests) {
        return deploy(
            vm.envAddress("OWNER"),
            vm.envAddress("GUARDIAN"),
            vm.envOr("UNIVERSAL_ROUTER", address(0)),
            vm.envOr("USDC", address(0)),
            vm.envOr("USDT", address(0)),
            vm.envOr("PYTH", address(0))
        );
    }

    /// @notice Fills a zero Pyth with mainnet's on chain 1 only, refuses any other there, and requires code.
    function resolvePyth(address given) public view returns (address) {
        return resolveStable("PYTH", given, MainnetAddresses.PYTH);
    }

    /// @notice Checks the owner and guardian, resolves the market, and broadcasts the `HybridHub` template's three
    ///         parts, the factory (which deploys the WeightedHub implementation), the zap and MintRequests. Logs every
    ///         address and the release record's code hashes.
    /// @param owner Factory owner; see {checkOwner}.
    /// @param guardian Initial guardian; see {checkGuardian}.
    /// @param router Uniswap's Universal Router, through which the zap swaps; see {resolveRouter}.
    /// @param usdc USDC for MintRequests; see {resolveStable}.
    /// @param usdt USDT for MintRequests; see {resolveStable}.
    /// @return factory The deployed factory.
    /// @return zap The deployed zap.
    /// @return requests The deployed MintRequests.
    function deploy(address owner, address guardian, address router, address usdc, address usdt, address pyth)
        public
        returns (HybridIndexFactory factory, IndexZap zap, MintRequests requests)
    {
        checkOwner(owner);
        checkGuardian(owner, guardian);
        router = resolveRouter(router);
        usdc = resolveStable("USDC", usdc, MainnetAddresses.USDC);
        usdt = resolveStable("USDT", usdt, MainnetAddresses.USDT);
        pyth = resolvePyth(pyth);
        checkRolesAreNotMarket(owner, guardian, router);
        if (owner == pyth || guardian == pyth) revert RoleIsMarketContract(pyth);

        vm.startBroadcast();
        // Each part of the template names the factory, and the factory's constructor refuses a template built for
        // another, so the three are deployed first for the address the factory's CREATE will take: the broadcaster's
        // fourth transaction from here.
        // Only the broadcaster is needed, not the caller mode or tx.origin; the script's own msg.sender differs in tests.
        // forge-lint: disable-next-line(unused-return)
        (, address broadcaster,) = vm.readCallers();
        address predicted = vm.computeCreateAddress(broadcaster, vm.getNonce(broadcaster) + 3);
        HybridHubExtension extension = new HybridHubExtension(predicted);
        HybridHubModule module = new HybridHubModule(predicted, address(extension));
        HybridHub template = new HybridHub(predicted, address(module));
        factory = new HybridIndexFactory(owner, guardian, pyth, address(template));
        zap = new IndexZap(IIndexFactory(address(factory)), IUniversalRouter(router));
        requests = new MintRequests(address(factory), usdc, usdt);
        vm.stopBroadcast();

        console2.log("HybridIndexFactory:      ", address(factory));
        console2.log("WeightedHub impl:        ", factory.IMPLEMENTATION());
        console2.log("Pyth:                    ", pyth);
        console2.log("HybridHub template:      ", address(template));
        console2.log("HybridHubModule:         ", address(module));
        console2.log("HybridHubExtension:      ", address(extension));
        console2.log("IndexZap:                ", address(zap));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Universal Router:        ", router);
        console2.log("PoolManager:             ", zap.POOL_MANAGER());
        console2.log("MintRequests:            ", address(requests));
        console2.log("USDC:                    ", usdc);
        console2.log("USDT:                    ", usdt);

        // The release record: the addresses above plus the code they ended up with, so a later run of
        // {checkDeployment} against the recorded addresses proves a deployment is this build.
        bytes32[7] memory codehashes = checkDeployment(factory, zap, requests);
        console2.log("HybridIndexFactory hash: ", vm.toString(codehashes[0]));
        console2.log("WeightedHub impl hash:   ", vm.toString(codehashes[1]));
        console2.log("HybridHub template hash: ", vm.toString(codehashes[2]));
        console2.log("HybridHubModule hash:    ", vm.toString(codehashes[3]));
        console2.log("HybridHubExtension hash: ", vm.toString(codehashes[4]));
        console2.log("IndexZap hash:           ", vm.toString(codehashes[5]));
        console2.log("MintRequests hash:       ", vm.toString(codehashes[6]));
    }

    /// @notice Checks that a factory, a zap and MintRequests are one deployment and returns the runtime code hashes to
    ///         freeze in the release record (README, "Deployment record"). Run it again later against the recorded
    ///         addresses: equal hashes prove the deployed code is unchanged and still the build the record names. The
    ///         template's parts need no wiring check: each constructor refuses a part built for another factory.
    /// @param factory The deployed factory, which names both templates; the `HybridHub` template names its module,
    ///        and the module its extension.
    /// @param zap The deployed zap, which must point back at `factory`.
    /// @param requests The deployed MintRequests, which must point back at `factory`.
    /// @return codehashes keccak256 of the runtime code of the factory, the WeightedHub implementation, the HybridHub
    ///         template, its module and its extension, the zap and MintRequests.
    function checkDeployment(HybridIndexFactory factory, IndexZap zap, MintRequests requests)
        public
        view
        returns (bytes32[7] memory codehashes)
    {
        address template = factory.HYBRID_IMPLEMENTATION();
        address module = HybridHub(payable(template)).MODULE();
        address extension = HybridHubModule(module).EXTENSION();
        address zapFactory = address(zap.FACTORY());
        if (zapFactory != address(factory)) revert WrongWiring("IndexZap.FACTORY", address(factory), zapFactory);
        address requestsFactory = requests.FACTORY();
        if (requestsFactory != address(factory)) {
            revert WrongWiring("MintRequests.FACTORY", address(factory), requestsFactory);
        }
        codehashes = [
            address(factory).codehash,
            factory.IMPLEMENTATION().codehash,
            template.codehash,
            module.codehash,
            extension.codehash,
            address(zap).codehash,
            address(requests).codehash
        ];
    }
}
