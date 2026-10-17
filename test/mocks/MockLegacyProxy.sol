// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A proxy that keeps its implementation, and its admin if it has one, in slots of the caller's choosing: the
///         zeppelinos slots of OpenZeppelin's proxies before EIP-1967, or EIP-1822's. It names an owner through
///         `proxyOwner()`, as an OwnedUpgradeabilityProxy (OKB's) does, and forwards every other call.
contract MockLegacyProxy {
    address public immutable proxyOwner;
    address internal immutable _IMPLEMENTATION;

    constructor(bytes32 implementationSlot, address implementation, bytes32 adminSlot, address admin, address owner_) {
        _IMPLEMENTATION = implementation;
        proxyOwner = owner_;
        assembly ("memory-safe") {
            sstore(implementationSlot, implementation)
        }
        if (adminSlot != bytes32(0)) {
            assembly ("memory-safe") {
                sstore(adminSlot, admin)
            }
        }
    }

    fallback() external {
        (bool ok, bytes memory answer) = _IMPLEMENTATION.delegatecall(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
        assembly ("memory-safe") {
            return(add(answer, 0x20), mload(answer))
        }
    }
}
