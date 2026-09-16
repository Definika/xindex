// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {IIndexRule} from "../src/interfaces/IIndexRule.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";

/// @notice Deploys the factory (which deploys the rule and the IndexToken implementation) and the zap.
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/Deploy.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER               Required. Factory owner. On mainnet it must be a contract that is not an EIP-7702 delegated
///                       account, and a Safe must require at least two signatures.
///   GUARDIAN            Required. Can cancel pending listings and rebalances, start a rebalance that leaves a paused
///                       component untouched, and delist tokens. Must differ from OWNER; replacing it later takes 7 days.
///   SWAP_ROUTER         Uniswap SwapRouter02. Required off mainnet; defaults to the mainnet router on chain 1.
///   WETH                Wrapped ether, the rule's pricing currency. Required off mainnet; defaults on chain 1.
///   UNISWAP_V3_FACTORY  Registry that proves each token pool is genuine. Required off mainnet; defaults on chain 1.
///   USDC                Dollar currency; its 0.05% WETH pool prices indexes in dollars. Required off mainnet; defaults
///                       on chain 1.
contract Deploy is Script {
    address public constant MAINNET_SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address public constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MAINNET_UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice External contracts the deployment depends on. A zero field means the mainnet default on chain 1.
    struct Market {
        address router;
        address weth;
        address uniswapV3Factory;
        address usdc;
    }

    error OwnerRequired();
    error OwnerMustBeContract(address owner);
    error OwnerThresholdTooLow(address owner, uint256 threshold);
    error GuardianRequired();
    error AddressRequired(string name);
    error AddressHasNoCode(string name, address account);

    function run() external returns (IndexFactory factory, IndexZap zap) {
        Market memory market = Market({
            router: vm.envOr("SWAP_ROUTER", address(0)),
            weth: vm.envOr("WETH", address(0)),
            uniswapV3Factory: vm.envOr("UNISWAP_V3_FACTORY", address(0)),
            usdc: vm.envOr("USDC", address(0))
        });
        return deploy(vm.envAddress("OWNER"), vm.envAddress("GUARDIAN"), market);
    }

    function deploy(address owner, address guardian, Market memory market)
        public
        returns (IndexFactory factory, IndexZap zap)
    {
        checkOwner(owner);
        checkGuardian(owner, guardian);
        market = resolveMarket(market);

        vm.startBroadcast();
        factory = new IndexFactory(owner, guardian, market.weth, market.uniswapV3Factory, market.usdc);
        zap = new IndexZap(factory, ISwapRouter02(market.router));
        vm.stopBroadcast();

        console2.log("IndexFactory:            ", address(factory));
        console2.log("IndexRule:               ", factory.RULE());
        console2.log("IndexToken impl:         ", factory.IMPLEMENTATION());
        console2.log("IndexZap:                ", address(zap));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Swap router:             ", market.router);
        console2.log("USDC/WETH pool:          ", IIndexRule(factory.RULE()).USD_POOL());
    }

    /// @notice Rejects a missing owner and Foundry's default sender. On mainnet the owner must be a contract, not
    ///         an EIP-7702 delegated account, and a Safe must need at least two signatures.
    function checkOwner(address owner) public view {
        if (owner == address(0) || owner == DEFAULT_SENDER) revert OwnerRequired();
        if (block.chainid != 1) return;

        bytes memory code = owner.code;
        if (code.length == 0 || _isDelegatedAccount(code)) revert OwnerMustBeContract(owner);
        // A Safe answers getThreshold with one word. A contract that does not, such as a timelock, is accepted as it
        // is. A static call is used because a typed try/catch would revert on an empty answer from a fallback.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = owner.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ()));
        if (ok && data.length == 32) {
            uint256 threshold = abi.decode(data, (uint256));
            if (threshold < 2) revert OwnerThresholdTooLow(owner, threshold);
        }
    }

    /// @notice Requires a guardian that is set, is not Foundry's default sender, and is not the owner.
    function checkGuardian(address owner, address guardian) public pure {
        if (guardian == address(0) || guardian == DEFAULT_SENDER || guardian == owner) revert GuardianRequired();
    }

    /// @notice Fills zero addresses with the mainnet defaults on chain 1 only, and requires every address to have code.
    function resolveMarket(Market memory market) public view returns (Market memory) {
        market.router = _resolve("SWAP_ROUTER", market.router, MAINNET_SWAP_ROUTER_02);
        market.weth = _resolve("WETH", market.weth, MAINNET_WETH);
        market.uniswapV3Factory = _resolve("UNISWAP_V3_FACTORY", market.uniswapV3Factory, MAINNET_UNISWAP_V3_FACTORY);
        market.usdc = _resolve("USDC", market.usdc, MAINNET_USDC);
        return market;
    }

    function _resolve(string memory name, address given, address mainnetDefault) private view returns (address) {
        if (given == address(0)) {
            if (block.chainid != 1) revert AddressRequired(name);
            given = mainnetDefault;
        }
        if (given.code.length == 0) revert AddressHasNoCode(name, given);
        return given;
    }

    /// @dev EIP-7702 sets an account's code to 0xef0100 followed by the delegate address. Since EIP-3541 no contract
    ///      can deploy code that starts with 0xef, so the 0xef01 prefix alone identifies a delegation.
    function _isDelegatedAccount(bytes memory code) private pure returns (bool) {
        return code.length >= 2 && code[0] == 0xef && code[1] == 0x01;
    }
}
