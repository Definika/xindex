// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVeChainStaker} from "../interfaces/IVeChainStaker.sol";

/// @title VeChainStakerAttester
/// @notice On VeChain: attests the validators' weights VIP-220 counts, so that Ethereum can follow VeChain's finality
///         without a state proof (`proofs/vechain`). A transaction whose one clause calls `attest(table)`, and whose
///         receipt shows it did not revert, proves that the Staker's active validators and weights, in its block, hash
///         to `table`. Weights change only at an epoch's first block, before its transactions run, so that is the
///         table of the whole 180-block epoch the transaction lies in.
/// @dev No owner, no state, no upgrade: its master, VeChain's Prototype `master`, is cleared at deployment. The table is
///      a hash chain over the Staker's own answers, `h0 = keccak256(abi.encode(totalWeight))`, then
///      `h = keccak256(abi.encode(h, validator, weight))` for each active validator in list order, weights in wei as
///      the Staker gives them. `VeChainStateVerifier`'s statement computes the same chain from the table it is given.
contract VeChainStakerAttester {
    /// @notice VeChain's builtin Staker.
    IVeChainStaker public constant STAKER = IVeChainStaker(0x00000000000000000000000000005374616B6572);

    /// @notice The Staker's table is `table`, not the one attested.
    error NotAttested(bytes32 table);

    /// @notice The hash chain over the total weight and each active validator's weight, as the Staker answers now.
    function currentTable() public view returns (bytes32 hash) {
        // Only the weight counts: the VET locked weighs as its multipliers make it.
        // forge-lint: disable-next-line(unused-return)
        (, uint256 totalWeight) = STAKER.totalStake();
        hash = keccak256(abi.encode(totalWeight));
        // The list holds at most the chain's maximum of block proposers, 101 today.
        for (address v = STAKER.firstActive(); v != address(0); v = STAKER.next(v)) {
            // Only the weight counts, as thor's `bft` package reads it for a signer.
            // forge-lint: disable-next-line(unused-return)
            (,, uint256 weight,,,) = STAKER.getValidation(v);
            hash = keccak256(abi.encode(hash, v, weight));
        }
    }

    /// @notice Returns only if the Staker's table is `expected`.
    function attest(bytes32 expected) external view {
        bytes32 actual = currentTable();
        if (actual != expected) revert NotAttested(actual);
    }
}
