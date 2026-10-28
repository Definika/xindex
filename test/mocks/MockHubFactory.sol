// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {WeightedHub} from "../../src/WeightedHub.sol";
import {WeightedMath} from "../../src/WeightedMath.sol";
import {IWeightedHub} from "../../src/interfaces/IWeightedHub.sol";

/// @notice A factory stand-in that deploys the real hub and answers `feeTerms` with whatever a test sets, so the hub's
///         fallbacks for a recipient that could not hold shares, which the real factory never produces, can be
///         reached, and so can its own config check.
contract MockHubFactory {
    WeightedHub public immutable IMPLEMENTATION;
    bool public allowed = true;
    address public creator;
    address public platform;

    constructor(address pyth) {
        IMPLEMENTATION = new WeightedHub(pyth, address(new WeightedMath()));
    }

    function create(IWeightedHub.ComponentInit[] memory inits, IWeightedHub.Config memory cfg)
        external
        returns (WeightedHub index)
    {
        index = WeightedHub(Clones.clone(address(IMPLEMENTATION)));
        index.initialize("Mock", "MOCK", inits, cfg);
    }

    function set(bool allowed_, address creator_, address platform_) external {
        allowed = allowed_;
        creator = creator_;
        platform = platform_;
    }

    function feeTerms(address, address) external view returns (bool, address, address) {
        return (allowed, creator, platform);
    }
}
