// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice A Safe as `CheckToken` reads one: its threshold and its owners. Built not to list owners, it stands for a
///         multisig that reports a threshold only.
contract MockSafeOwner {
    uint256 public getThreshold;
    uint256 internal immutable _SIGNERS;
    bool internal immutable _LISTS_OWNERS;

    constructor(uint256 threshold, uint256 signers, bool listsOwners) {
        getThreshold = threshold;
        _SIGNERS = signers;
        _LISTS_OWNERS = listsOwners;
    }

    function getOwners() external view returns (address[] memory owners) {
        if (!_LISTS_OWNERS) revert();
        owners = new address[](_SIGNERS);
        for (uint256 i = 0; i < _SIGNERS; ++i) {
            owners[i] = address(uint160(i + 1));
        }
    }
}

/// @notice A multisig whose `getOwners` announces five owners and returns none of them: an answer cut short, as a
///         proxy with a bounded return buffer gives. `CheckToken` must not print the announced length as a count
///         (CA-R2-18).
contract MockTruncatedSafeOwner {
    uint256 public constant getThreshold = 3;

    function getOwners() external pure {
        bytes memory cut = abi.encode(uint256(0x20), uint256(5));
        // forge-lint: disable-next-line(inline-assembly)
        assembly ("memory-safe") {
            return(add(cut, 0x20), mload(cut))
        }
    }
}

/// @notice OpenZeppelin's TimelockController as `CheckToken` reads one: its minimum delay.
contract MockTimelockOwner {
    uint256 public getMinDelay;

    constructor(uint256 minDelay) {
        getMinDelay = minDelay;
    }
}

/// @notice Compound's Timelock as `CheckToken` reads one: its delay.
contract MockDelayOwner {
    uint256 public delay;

    constructor(uint256 delay_) {
        delay = delay_;
    }
}
