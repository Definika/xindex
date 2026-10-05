// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ForkAddresses as A} from "./ForkAddresses.sol";

/// @notice The admission check on real tokens: WBTC and LINK, which the Stage A list holds, pass it with their powers
///         recorded, and WhiteBIT's WBT, which the WBT rule keeps off, is refused by it. Skips when MAINNET_RPC_URL is
///         unset.
contract CheckTokenForkTest is Test {
    CheckToken checker;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", A.FORK_BLOCK);
        try vm.createSelectFork(url, forkBlock) returns (uint256) {}
        catch {
            revert(
                string.concat(
                    "MAINNET_RPC_URL cannot serve block ",
                    vm.toString(forkBlock),
                    ": use an archive node, set FORK_BLOCK near the chain head, or run forge test --no-match-path 'test/fork/*'"
                )
            );
        }
        checker = new CheckToken();
    }

    function _check(address token, uint256 supply) internal returns (CheckToken.Report memory r) {
        r = checker.check(token, supply, address(0), checker.markets());
        checker.log(r);
    }

    /// @dev WBTC: its custodian mints and pauses, a contract holds the keys, and it trades in standard pools.
    function testFork_wbtcIsListableWithItsPowersRecorded() public {
        CheckToken.Report memory r = _check(A.WBTC, A.BTC_SUPPLY);
        assertEq(r.symbol, "WBTC");
        assertEq(r.decimals, 8);
        assertEq(r.totalSupply, IERC20Metadata(A.WBTC).totalSupply());
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact));
        assertFalse(r.erc777);
        assertFalse(r.erc1363);
        assertEq(r.implementation, address(0), "no proxy");
        assertEq(r.powers, checker.MINT() | checker.PAUSE());
        assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Contract));
        assertGt(r.pools.length, 0, "WBTC has standard pools against WETH and USDC");
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable));
    }

    /// @dev LINK: no owner and no admin power; `transferAndCall` (ERC-677) is recorded, and is no ERC-1363.
    function testFork_linkIsListableWithNoAdmin() public {
        CheckToken.Report memory r = _check(A.LINK, A.LINK_SUPPLY);
        assertEq(r.symbol, "LINK");
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact));
        assertTrue(r.registry, "the ERC-1820 registry is on mainnet");
        assertFalse(r.erc777);
        assertFalse(r.erc1363);
        assertEq(r.powers, checker.CALLBACK());
        assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.None));
        assertGt(r.pools.length, 0);
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable));
    }

    /// @dev WBT: a single key can pause, blacklist and destroy a blacklisted balance, which the WBT rule refuses.
    function testFork_theWbtRuleRefusesWbt() public {
        CheckToken.Report memory r = _check(A.WBT, 118_900_000e8);
        assertEq(r.symbol, "WBT");
        assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), "its transfers are standard");
        assertEq(r.powers, checker.PAUSE() | checker.BLACKLIST() | checker.DESTROY());
        assertEq(uint8(r.owner.kind), uint8(CheckToken.Kind.Key));
        assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Refused));
        assertEq(r.reason, "the WBT rule: it can blacklist a holder and destroy its balance");
    }
}
