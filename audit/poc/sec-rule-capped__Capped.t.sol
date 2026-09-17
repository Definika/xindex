// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console} from "forge-std/Test.sol";
import {IndexRule} from "../../src/IndexRule.sol";
contract CappedPoc is Test {
    function test_rank3Exceeds() public {
        // weightsFromCaps is pure; deploy code-less via vm.etch of runtime is complex, so call through a harness copy
        IndexRule r = IndexRule(address(0));
        uint256[] memory caps = new uint256[](5);
        caps[0] = 2_000e9; caps[1] = 488e9; caps[2] = 15e9; caps[3] = 6e9; caps[4] = 0.5e9;
        bytes memory code = vm.getDeployedCode("IndexRule.sol:IndexRule");
        vm.etch(address(0xBEEF), code);
        r = IndexRule(address(0xBEEF));
        uint256[] memory w = r.weightsFromCaps(caps, 1);
        for (uint256 i; i < 5; ++i) console.log(w[i]);
    }
}
