// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexZap} from "../src/IndexZap.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";

/// @notice Deploys the factory (which deploys the IndexToken implementation) and the zap.
///
///   OWNER=<safe address> GUARDIAN=<guardian address> forge script script/Deploy.s.sol --rpc-url mainnet \
///     --account deployer --sender <deployer address> --broadcast --verify
///
/// Env:
///   OWNER        Required. Factory owner. On mainnet it must be a contract that is not an EIP-7702 delegated
///                account, and a Safe must require at least two signatures.
///   GUARDIAN     Required. Can cancel pending listings and delist tokens. Must differ from OWNER; replacing it
///                later takes 7 days.
///   SWAP_ROUTER  Uniswap SwapRouter02. Required off mainnet; defaults to the mainnet router on chain 1.
contract Deploy is Script {
    address public constant MAINNET_SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    error OwnerRequired();
    error OwnerMustBeContract(address owner);
    error OwnerThresholdTooLow(address owner, uint256 threshold);
    error GuardianRequired();
    error RouterRequired();
    error RouterHasNoCode(address router);

    function run() external returns (IndexFactory factory, IndexZap zap) {
        return deploy(vm.envAddress("OWNER"), vm.envAddress("GUARDIAN"), vm.envOr("SWAP_ROUTER", address(0)));
    }

    function deploy(address owner, address guardian, address router)
        public
        returns (IndexFactory factory, IndexZap zap)
    {
        checkOwner(owner);
        checkGuardian(owner, guardian);
        router = resolveRouter(router);

        vm.startBroadcast();
        factory = new IndexFactory(owner, guardian);
        zap = new IndexZap(factory, ISwapRouter02(router));
        vm.stopBroadcast();

        console2.log("IndexFactory:            ", address(factory));
        console2.log("IndexToken impl:         ", factory.IMPLEMENTATION());
        console2.log("IndexZap:                ", address(zap));
        console2.log("Factory owner:           ", owner);
        console2.log("Guardian:                ", guardian);
        console2.log("Swap router:             ", router);
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

    /// @notice Uses the mainnet router only on chain 1 and requires the router to have code.
    function resolveRouter(address router) public view returns (address) {
        if (router == address(0)) {
            if (block.chainid != 1) revert RouterRequired();
            router = MAINNET_SWAP_ROUTER_02;
        }
        if (router.code.length == 0) revert RouterHasNoCode(router);
        return router;
    }

    /// @dev EIP-7702 sets an account's code to 0xef0100 followed by the delegate address. Since EIP-3541 no contract
    ///      can deploy code that starts with 0xef, so the 0xef01 prefix alone identifies a delegation.
    function _isDelegatedAccount(bytes memory code) private pure returns (bool) {
        return code.length >= 2 && code[0] == 0xef && code[1] == 0x01;
    }
}
