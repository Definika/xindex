// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CheckToken} from "../../script/CheckToken.s.sol";
import {ConfigureWhitelist} from "../../script/ConfigureWhitelist.s.sol";
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

    /// @dev The wide list is what passed the check: no entry is refused, and none is left for review.
    function testFork_everyWideTokenPassesTheCheck() public {
        ConfigureWhitelist.Entry[] memory list = new ConfigureWhitelist().wideMainnetList();
        for (uint256 i = 0; i < list.length; ++i) {
            CheckToken.Report memory r = _check(list[i].token, list[i].referenceSupply);
            assertEq(uint8(r.transfers), uint8(CheckToken.Transfers.Exact), r.symbol);
            assertEq(uint8(r.verdict), uint8(CheckToken.Verdict.Listable), r.symbol);
        }
    }

    /// @dev The two the WBT rule kept off the wide list. LEO is a MiniMe token: its controller destroys any balance
    ///      and approves every transfer. WLFI's owner, a Safe, blacklists and reallocates any holder's balance.
    function testFork_theWbtRuleRefusesLeoAndWlfi() public {
        CheckToken.Report memory leo = _check(A.LEO, 919_857_851e18);
        assertEq(leo.symbol, "LEO");
        assertEq(leo.powers & (checker.BLACKLIST() | checker.DESTROY()), checker.BLACKLIST() | checker.DESTROY());
        assertEq(uint8(leo.owner.kind), uint8(CheckToken.Kind.Contract), "the controller");
        assertEq(uint8(leo.verdict), uint8(CheckToken.Verdict.Refused));
        CheckToken.Report memory wlfi = _check(A.WLFI, 31_778_337_976e18);
        assertEq(wlfi.symbol, "WLFI");
        assertEq(wlfi.powers & (checker.BLACKLIST() | checker.DESTROY()), checker.BLACKLIST() | checker.DESTROY());
        assertEq(uint8(wlfi.owner.kind), uint8(CheckToken.Kind.Safe));
        assertEq(uint8(wlfi.verdict), uint8(CheckToken.Verdict.Refused));
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
