// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISP1Groth16Identity} from "./interfaces/ISP1Groth16Identity.sol";
import {ISafeThreshold} from "./interfaces/ISafeThreshold.sol";

/// @notice Constants and helpers the deploy, listing and test-market scripts share.
library ScriptUtils {
    /// @notice SP1's Groth16 verifier v6.0.0 names itself by this hash, the circuit its proofs come from.
    bytes32 internal constant SP1_VERIFIER_HASH = 0x0e78f4db7a6771a3a6a7d9c3b0de6fe73d58781368967a7fe84d87aefffec896;
    string internal constant SP1_VERSION = "v6.0.0";

    /// @notice Fewest signatures a Safe may need to hold a role that must not rest on one key: the design's 3-of-5 hardware
    ///         wallets held by separate people (the owner's call on 2026-09-30).
    uint256 internal constant MIN_MULTISIG_THRESHOLD = 3;
    /// @notice Start of a Safe's module list.
    address internal constant SENTINEL_MODULES = address(0x1);

    /// @notice What {reviewSafe} found of an account that must be a Safe holding no module.
    enum SafeFinding {
        Ok,
        NotASafe,
        ThresholdTooLow,
        HasModules,
        ModulesUnknown
    }

    /// @notice Uniswap V3 fee tiers the listed WETH pools use.
    uint24 internal constant POOL_FEE_LOW = 500;
    uint24 internal constant POOL_FEE_MEDIUM = 3000;

    /// @notice Whether `code` is an EIP-7702 delegation: 0xef0100 followed by the delegate address. Such an account is
    ///         still a key that signs transactions, not a contract. Since EIP-3541 no contract can deploy code that
    ///         starts with 0xef, so the 0xef01 prefix alone identifies a delegation.
    function isDelegatedAccount(bytes memory code) internal pure returns (bool) {
        return code.length >= 2 && code[0] == 0xef && code[1] == 0x01;
    }

    /// @notice Whether two strings are equal, for mode and symbol checks.
    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice Whether `a` comes strictly after `b`, byte by byte, both of `a`'s length; equal is not after.
    function above(bytes memory a, bytes memory b) internal pure returns (bool) {
        for (uint256 i = 0; i < a.length; ++i) {
            if (a[i] != b[i]) return a[i] > b[i];
        }
        return false;
    }

    /// @notice Whether `target` answers `query` with exactly `expected`. A static call, compared byte for byte, so a
    ///         missing function, a fallback or a short answer is a no rather than a revert.
    function answers(address target, bytes memory query, bytes memory expected) internal view returns (bool) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory answer) = target.staticcall(query);
        return ok && keccak256(answer) == keccak256(expected);
    }

    /// @notice Whether `verifier` names itself SP1's Groth16 verifier v6.0.0. An owned gateway answers neither, so it
    ///         is refused too.
    function isSp1Verifier(address verifier) internal view returns (bool) {
        return answers(verifier, abi.encodeCall(ISP1Groth16Identity.VERIFIER_HASH, ()), abi.encode(SP1_VERIFIER_HASH))
            && answers(verifier, abi.encodeCall(ISP1Groth16Identity.VERSION, ()), abi.encode(SP1_VERSION));
    }

    /// @notice Reviews `account` as a Safe that must need at least `minThreshold` signatures and have no enabled module,
    ///         which would act as the Safe without any: the owner's rule, shared by every role that is meant to be a
    ///         multisig (A7-09). Every read is a static call whose answer is checked before it is decoded, so a contract
    ///         that is not a Safe, a missing function or a call that reverted with a word that looks like an answer
    ///         is a finding, never a revert or an answer (CR-I36).
    /// @param account The role's account.
    /// @param minThreshold Fewest signatures it may need.
    /// @return finding What is wrong with it, or `Ok`.
    /// @return threshold Its signature threshold, for `ThresholdTooLow`.
    /// @return module The first enabled module, for `HasModules`.
    function reviewSafe(address account, uint256 minThreshold)
        internal
        view
        returns (SafeFinding finding, uint256 threshold, address module)
    {
        // A Safe answers getThreshold with one word. A static call is used because a typed try/catch would revert on an
        // empty answer from a fallback.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = account.staticcall(abi.encodeCall(ISafeThreshold.getThreshold, ()));
        if (!ok || data.length != 32) return (SafeFinding.NotASafe, 0, address(0));
        threshold = abi.decode(data, (uint256));
        if (threshold < minThreshold) return (SafeFinding.ThresholdTooLow, threshold, address(0));
        // The first page of the Safe's module list. A multisig that cannot show one is rejected rather than trusted, and
        // so is any enabled module.
        // forge-lint: disable-next-line(low-level-calls)
        (ok, data) = account.staticcall(abi.encodeCall(ISafeThreshold.getModulesPaginated, (SENTINEL_MODULES, 1)));
        // A well-formed answer holds at least the array offset, the next cursor and the array length.
        if (!ok || data.length < 96) return (SafeFinding.ModulesUnknown, threshold, address(0));
        (address[] memory modules,) = abi.decode(data, (address[], address));
        if (modules.length != 0) return (SafeFinding.HasModules, threshold, modules[0]);
        return (SafeFinding.Ok, threshold, address(0));
    }

    /// @notice The signers of `account` when it is a Safe, and none otherwise: a key, or a contract that answers no signer
    ///         list, has none to name.
    function signersOf(address account) internal view returns (address[] memory signers) {
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok, bytes memory data) = account.staticcall(abi.encodeCall(ISafeThreshold.getOwners, ()));
        // A well-formed answer holds at least the array offset and its length.
        if (!ok || data.length < 64) return signers;
        return abi.decode(data, (address[]));
    }
}
