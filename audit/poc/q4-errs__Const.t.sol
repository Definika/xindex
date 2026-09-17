// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
contract ConstT is Test { uint32 constant W = 30 minutes; int56 constant S = int56(uint56(W)); function test_c() public pure { assertEq(S, 1800);} }
