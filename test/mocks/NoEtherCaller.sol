// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPancakeUniversalRouter} from "../../src/interfaces/IPancakeUniversalRouter.sol";

/// @notice Calls a router with no way to receive ether, as the zap is: the shape of SV-1's victim.
contract NoEtherCaller {
    function run(IPancakeUniversalRouter router, bytes calldata commands, bytes[] calldata inputs) external {
        router.execute(commands, inputs);
    }
}
