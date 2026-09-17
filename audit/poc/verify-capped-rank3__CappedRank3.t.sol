// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {console} from "forge-std/Test.sol";
import {IndexRuleTest} from "../IndexRule.t.sol";
contract CappedRank3 is IndexRuleTest {
    function test_poc_rank3() public view {
        uint256[] memory c = new uint256[](5);
        c[0]=2000e9; c[1]=488e9; c[2]=15e9; c[3]=6e9; c[4]=0.5e9;
        uint256[] memory w = rule.weightsFromCaps(c, 1);
        for (uint i=0;i<5;i++) console.log(w[i]);
        assertGt(w[2], w[0]);
        c[0]=100; c[1]=99; c[2]=98; c[3]=1; c[4]=1;
        w = rule.weightsFromCaps(c, 1);
        console.log("synthetic rank3", w[2]);
    }
}
